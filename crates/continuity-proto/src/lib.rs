//! `continuity-proto`: Wire protocol, QR/mTLS pairing state machine, and binary
//! control packet multiplexer for the Mirror Continuity suite.

pub mod codec;
pub mod error;
pub mod packet;
pub mod pairing;

pub use codec::{compute_crc32_tag, decode_frame_bytes, encode_frame_bytes};
pub use error::{ProtoError, ProtoResult};
pub use packet::{
    ClipboardDataChunk, ClipboardOffer, ControlFrame, ControlFrameHeader, ControlPacket,
    DragOutOffer, Heartbeat, MediaAction, MediaControlCommand, MediaSessionUpdate,
    NotificationInlineReply, NotificationMirror, OtpCodeDetected, PacketType, PowerStateUpdate,
    ThermalState, FRAME_MAGIC, HEADER_LEN, MAX_CONTROL_PAYLOAD_LEN, PROTOCOL_VERSION,
};
pub use pairing::{
    compute_cert_sha256, constant_time_eq_32, ContinuityPairingQr, LanEndpoint, PairingState,
    PairingStateMachine, PinnedPeerIdentity,
};

#[cfg(test)]
mod tests {
    use super::*;

    fn sample_qr() -> ContinuityPairingQr {
        ContinuityPairingQr {
            adb_service_name: "studio-adb-wifi;01".to_string(),
            adb_password: "secret:pass\\99".to_string(),
            device_id: "mac-m1-uuid-001".to_string(),
            device_name: "Ukasha's MacBook Pro".to_string(),
            cert_sha256: compute_cert_sha256(b"host-ed25519-cert-der"),
            endpoints: vec![
                LanEndpoint {
                    addr: "192.168.1.42:53318".parse().expect("valid ip"),
                    is_usb_ncm: false,
                },
                LanEndpoint {
                    addr: "169.254.10.1:53318".parse().expect("valid ip"),
                    is_usb_ncm: true,
                },
            ],
            expires_at_secs: 1_900_000_300,
        }
    }

    #[test]
    fn qr_combined_and_adb_uri_round_trip() {
        let qr = sample_qr();
        let adb_only = qr.to_adb_wifi_qr();
        assert_eq!(
            adb_only,
            r"WIFI:T:ADB;S:studio-adb-wifi\;01;P:secret\:pass\\99;;"
        );

        let combined = qr.to_combined_qr();
        let decoded = ContinuityPairingQr::from_combined_qr(&combined).expect("valid qr");
        assert_eq!(decoded, qr);
    }

    #[test]
    fn qr_rejects_malformed_uris() {
        assert!(matches!(
            ContinuityPairingQr::from_combined_qr("HTTP://wrong"),
            Err(ProtoError::InvalidPairingUri { .. })
        ));
        assert!(matches!(
            ContinuityPairingQr::from_combined_qr("WIFI:T:ADB;S:test;;"),
            Err(ProtoError::InvalidPairingUri { .. })
        ));
    }

    #[test]
    fn pairing_state_machine_pins_and_verifies_mtls_certs() {
        let host_fp = compute_cert_sha256(b"host-ed25519-cert-der");
        let peer_cert = b"android-pixel-9-pro-ecdsa-cert-der";
        let peer_fp = compute_cert_sha256(peer_cert);

        let mut sm = PairingStateMachine::new(host_fp);
        assert_eq!(sm.state(), &PairingState::Unpaired);

        let qr = sample_qr();
        // Expired check
        assert!(matches!(
            sm.begin_with_qr(qr.clone(), 1_900_000_500),
            Err(ProtoError::PairingExpired { .. })
        ));

        sm.begin_with_qr(qr, 1_900_000_000).expect("not expired");

        // Wrong peer cert must fail
        let bad_res = sm.verify_peer_certificate(
            "pixel-9".to_string(),
            "Pixel 9 Pro".to_string(),
            b"mitm-attacker-cert",
            &peer_fp,
            1_900_000_010,
        );
        assert!(matches!(
            bad_res,
            Err(ProtoError::CertificateFingerprintMismatch { .. })
        ));

        // Valid peer cert transitions to MutualTlsVerified
        let pinned = sm
            .verify_peer_certificate(
                "pixel-9".to_string(),
                "Pixel 9 Pro".to_string(),
                peer_cert,
                &peer_fp,
                1_900_000_010,
            )
            .expect("peer cert verified");

        assert_eq!(pinned.device_id, "pixel-9");
        assert!(
            PairingStateMachine::verify_pinned_reconnect(&pinned, peer_cert).is_ok()
        );
        assert!(matches!(
            PairingStateMachine::verify_pinned_reconnect(&pinned, b"wrong-cert"),
            Err(ProtoError::CertificateFingerprintMismatch { .. })
        ));
    }

    #[test]
    fn all_control_packets_round_trip_binary_codec() {
        let samples = vec![
            ControlPacket::ClipboardOffer(ClipboardOffer {
                offer_id: 42,
                mime_type: "image/png".to_string(),
                byte_length: 1_048_576,
                sha256: [0xAB; 32],
                preview_thumb: vec![0x89, b'P', b'N', b'G'],
                is_concealed: false,
                is_transient: false,
            }),
            ControlPacket::ClipboardDataChunk(ClipboardDataChunk {
                offer_id: 42,
                chunk_index: 0,
                total_chunks: 1,
                is_last: true,
                data: vec![1, 2, 3, 4, 5],
            }),
            ControlPacket::NotificationMirror(NotificationMirror {
                notification_id: "0|com.whatsapp|1001".to_string(),
                package_name: "com.whatsapp".to_string(),
                app_name: "WhatsApp".to_string(),
                title: "Alice".to_string(),
                body: "Are you free for a call?".to_string(),
                timestamp_ms: 1_762_000_000_000,
                can_reply_inline: true,
                icon_png: vec![0x01, 0x02],
            }),
            ControlPacket::NotificationInlineReply(NotificationInlineReply {
                notification_id: "0|com.whatsapp|1001".to_string(),
                reply_text: "Give me 5 minutes".to_string(),
                dismiss_after_reply: true,
            }),
            ControlPacket::OtpCodeDetected(OtpCodeDetected {
                code: "482910".to_string(),
                issuer: "GitHub".to_string(),
                expires_in_secs: 60,
            }),
            ControlPacket::MediaSessionUpdate(MediaSessionUpdate {
                package_name: "com.spotify.music".to_string(),
                title: "Midnight City".to_string(),
                artist: "M83".to_string(),
                album: "Hurry Up, We're Dreaming".to_string(),
                is_playing: true,
                position_ms: 45_000,
                duration_ms: 243_000,
                album_art_thumb: vec![0xFF, 0xD8, 0xFF],
            }),
            ControlPacket::MediaControlCommand(MediaControlCommand {
                action: MediaAction::SeekToMs(120_000),
            }),
            ControlPacket::DragOutOffer(DragOutOffer {
                drag_id: 77,
                content_uri: "content://media/external/images/media/901".to_string(),
                filename: "IMG_20261111.heic".to_string(),
                mime_type: "image/heic".to_string(),
                size: 3_400_120,
                cursor_exit_x: 0,
                cursor_exit_y: 540,
            }),
            ControlPacket::Heartbeat(Heartbeat {
                sequence: 99,
                timestamp_ms: 1_762_000_123_456,
                rtt_hint_us: 1_250,
            }),
            ControlPacket::PowerStateUpdate(PowerStateUpdate {
                battery_percent: 84,
                is_charging: true,
                thermal_state: ThermalState::Nominal,
                oled_screen_off: true,
            }),
        ];

        for (idx, packet) in samples.into_iter().enumerate() {
            let frame = ControlFrame {
                stream_id: 1,
                flags: 0,
                sequence: idx as u32,
                packet,
            };
            let bytes = frame.encode().expect("encode succeeds");
            let decoded = ControlFrame::decode(&bytes).expect("decode succeeds");
            assert_eq!(decoded, frame);
        }
    }

    #[test]
    fn clipboard_privacy_filters_concealed_and_transient() {
        let mut offer = ClipboardOffer {
            offer_id: 1,
            mime_type: "text/plain".to_string(),
            byte_length: 16,
            sha256: [0; 32],
            preview_thumb: Vec::new(),
            is_concealed: true,
            is_transient: false,
        };
        assert!(!offer.should_auto_sync(false));
        assert!(offer.should_auto_sync(true));

        offer.is_transient = true;
        assert!(!offer.should_auto_sync(true));
    }

    #[test]
    fn codec_detects_tampering_and_truncation() {
        let frame = ControlFrame {
            stream_id: 7,
            flags: 0,
            sequence: 1,
            packet: ControlPacket::Heartbeat(Heartbeat {
                sequence: 1,
                timestamp_ms: 1000,
                rtt_hint_us: 500,
            }),
        };
        let mut encoded = frame.encode().expect("encode");

        // Truncated header
        assert_eq!(
            ControlFrame::decode(&encoded[..10]),
            Err(ProtoError::TruncatedHeader {
                expected: HEADER_LEN,
                actual: 10
            })
        );

        // Truncated payload
        assert!(matches!(
            ControlFrame::decode(&encoded[..HEADER_LEN + 4]),
            Err(ProtoError::TruncatedPayload { .. })
        ));

        // Flip a payload bit -> IntegrityMismatch
        let last = encoded.len() - 1;
        encoded[last] ^= 0x01;
        assert!(matches!(
            ControlFrame::decode(&encoded),
            Err(ProtoError::IntegrityMismatch { .. })
        ));
    }
}
