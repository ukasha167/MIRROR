//! `continuity-core`: UniFFI-ready Rust facade, Keychain/Keystore bridge,
//! paired device store, resource budget monitor, and session multiplexer.

pub mod engine;
pub mod error;
pub mod ffi;
pub mod keystore;
pub mod resource;

pub use continuity_proto as proto;
pub use engine::{ContinuityEngine, ContinuityEvent, ControlStreamId};
pub use error::{CoreError, CoreResult};
pub use ffi::{
    continuity_core_uniffi_contract_version, continuity_engine_create, continuity_engine_free,
    continuity_engine_pending_frame_count, continuity_paired_store_create_in_memory,
    continuity_paired_store_free, continuity_paired_store_local_fingerprint,
    continuity_resource_monitor_create, continuity_resource_monitor_free,
    continuity_resource_monitor_preferred_codec, continuity_resource_monitor_verify,
    ContinuityEngineHandle, PairedDeviceStoreHandle, ResourceBudgetMonitorHandle,
    UNIFFI_UDL_DEFINITION,
};
pub use keystore::{InMemoryKeystoreBridge, KeystoreBridge, PairedDeviceStore};
pub use resource::{
    AppleSiliconGeneration, ResourceBudgetMonitor, ResourceSnapshot, StreamThermalBudget,
    VideoCodecPreference, MAX_MACOS_IDLE_CPU_PERCENT, MAX_MACOS_IDLE_RAM_BYTES,
    MAX_MIRRORING_CPU_PERCENT_M1,
};

#[cfg(test)]
mod tests {
    use super::*;
    use continuity_proto::{
        compute_cert_sha256, ClipboardDataChunk, ClipboardOffer, ControlPacket, DragOutOffer,
        LanEndpoint, OtpCodeDetected, PowerStateUpdate, ThermalState,
    };
    use std::sync::Arc;

    fn make_engine(id: &str, name: &str, cert: &[u8]) -> ContinuityEngine {
        let ks = Arc::new(InMemoryKeystoreBridge::new(cert.to_vec()));
        ContinuityEngine::new(
            id.to_string(),
            name.to_string(),
            AppleSiliconGeneration::M1,
            ks,
        )
        .expect("engine init")
    }

    #[test]
    fn end_to_end_qr_pairing_and_zero_prompt_reconnect() {
        let mac_cert = b"mac-m1-ed25519-cert-der";
        let phone_cert = b"android-pixel-9-cert-der";
        let phone_fp = compute_cert_sha256(phone_cert);

        let mut mac_engine = make_engine("mac-01", "MacBook Pro M1", mac_cert);
        let qr = mac_engine
            .start_qr_pairing_session(
                "adb-pair-service".to_string(),
                "839201".to_string(),
                vec![LanEndpoint {
                    addr: "192.168.1.10:53318".parse().expect("valid addr"),
                    is_usb_ncm: false,
                }],
                1_762_000_000,
                300,
            )
            .expect("qr generated");

        assert_eq!(qr.to_adb_wifi_qr(), "WIFI:T:ADB;S:adb-pair-service;P:839201;;");

        let evt = mac_engine
            .complete_qr_pairing(
                "pixel-9".to_string(),
                "Pixel 9 Pro".to_string(),
                phone_cert,
                &phone_fp,
                1_762_000_005,
            )
            .expect("pairing complete");

        match evt {
            ContinuityEvent::PeerPaired(peer) => {
                assert_eq!(peer.device_id, "pixel-9");
            }
            other => panic!("unexpected event: {other:?}"),
        }

        // Zero-prompt reconnect succeeds with matching cert
        let verified = mac_engine
            .verify_zero_prompt_reconnect("pixel-9", phone_cert)
            .expect("zero-prompt verified");
        assert_eq!(verified.device_name, "Pixel 9 Pro");

        // Unpaired device is rejected
        assert!(matches!(
            mac_engine.verify_zero_prompt_reconnect("unknown-phone", phone_cert),
            Err(CoreError::DeviceNotPaired { .. })
        ));
    }

    #[test]
    fn multiplexer_streams_clipboard_otp_dragout_and_thermal_events() {
        let mut phone_engine = make_engine("pixel-9", "Pixel 9", b"phone-cert");
        let mut mac_engine = make_engine("mac-01", "MacBook Pro", b"mac-cert");

        // 1. Concealed 1Password clipboard item is blocked by default
        let secret_offer = ClipboardOffer {
            offer_id: 10,
            mime_type: "text/plain".to_string(),
            byte_length: 24,
            sha256: [0x11; 32],
            preview_thumb: Vec::new(),
            is_concealed: true,
            is_transient: false,
        };
        assert!(matches!(
            phone_engine.send_clipboard_offer(secret_offer),
            Err(CoreError::ClipboardPrivacyBlocked { offer_id: 10, .. })
        ));

        // 2. Normal image clipboard offer + chunk
        let img_offer = ClipboardOffer {
            offer_id: 11,
            mime_type: "image/png".to_string(),
            byte_length: 4,
            sha256: [0x22; 32],
            preview_thumb: vec![1, 2],
            is_concealed: false,
            is_transient: false,
        };
        phone_engine
            .send_clipboard_offer(img_offer.clone())
            .expect("offer queued");
        phone_engine
            .send_clipboard_chunk(ClipboardDataChunk {
                offer_id: 11,
                chunk_index: 0,
                total_chunks: 1,
                is_last: true,
                data: vec![0x89, b'P', b'N', b'G'],
            })
            .expect("chunk queued");

        // 3. 2FA OTP pill event + DragOutOffer + Serious ThermalState
        phone_engine
            .send_control_packet(ControlPacket::OtpCodeDetected(OtpCodeDetected {
                code: "739204".to_string(),
                issuer: "Stripe".to_string(),
                expires_in_secs: 60,
            }))
            .expect("otp queued");

        phone_engine
            .send_control_packet(ControlPacket::DragOutOffer(DragOutOffer {
                drag_id: 500,
                content_uri: "content://media/external/images/media/42".to_string(),
                filename: "photo.jpg".to_string(),
                mime_type: "image/jpeg".to_string(),
                size: 512_000,
                cursor_exit_x: 12,
                cursor_exit_y: 400,
            }))
            .expect("drag queued");

        phone_engine
            .send_control_packet(ControlPacket::PowerStateUpdate(PowerStateUpdate {
                battery_percent: 62,
                is_charging: false,
                thermal_state: ThermalState::Serious,
                oled_screen_off: true,
            }))
            .expect("power queued");

        let wire_frames = phone_engine.drain_outbound_frames();
        assert_eq!(wire_frames.len(), 5);

        let ev0 = mac_engine.ingest_wire_frame(&wire_frames[0]).expect("ev0");
        assert_eq!(ev0, ContinuityEvent::ClipboardLazyPromiseReady(img_offer));

        let ev1 = mac_engine.ingest_wire_frame(&wire_frames[1]).expect("ev1");
        assert!(matches!(ev1, ContinuityEvent::ClipboardChunkReceived(_)));

        let ev2 = mac_engine.ingest_wire_frame(&wire_frames[2]).expect("ev2");
        assert_eq!(
            ev2,
            ContinuityEvent::OtpPillReady(OtpCodeDetected {
                code: "739204".to_string(),
                issuer: "Stripe".to_string(),
                expires_in_secs: 60,
            })
        );

        let ev3 = mac_engine.ingest_wire_frame(&wire_frames[3]).expect("ev3");
        assert!(matches!(ev3, ContinuityEvent::DragOutPromiseStarted(_)));

        let ev4 = mac_engine.ingest_wire_frame(&wire_frames[4]).expect("ev4");
        match ev4 {
            ContinuityEvent::PowerAndThermalUpdated {
                state,
                thermal_budget,
            } => {
                assert!(state.oled_screen_off);
                assert_eq!(thermal_budget.max_fps, 30);
                assert!(thermal_budget.pause_background_sync);
            }
            other => panic!("unexpected event: {other:?}"),
        }
    }

    #[test]
    fn resource_budget_monitor_enforces_ram_cpu_and_m1_h265_limits() {
        let mut engine = make_engine("mac-01", "MacBook Pro M1", b"cert");
        assert_eq!(
            engine.resource_monitor().preferred_video_codec(),
            VideoCodecPreference::H265
        );

        // Valid idle snapshot (19 MiB RAM, 0.0% CPU/GPU, 0 wakelocks)
        engine
            .check_resource_budget(ResourceSnapshot {
                macos_rss_bytes: 19 * 1024 * 1024,
                macos_cpu_percent: 0.0,
                macos_gpu_percent: 0.0,
                is_session_active: false,
                android_idle_wakelocks: 0,
                android_idle_multicast_locks: 0,
            })
            .expect("idle within budget");

        // Exceeding 28 MiB idle RAM fails
        assert!(matches!(
            engine.check_resource_budget(ResourceSnapshot {
                macos_rss_bytes: 30 * 1024 * 1024,
                macos_cpu_percent: 0.0,
                macos_gpu_percent: 0.0,
                is_session_active: false,
                android_idle_wakelocks: 0,
                android_idle_multicast_locks: 0,
            }),
            Err(CoreError::ResourceBudgetExceeded {
                metric: "macos_idle_ram_bytes",
                ..
            })
        ));

        // Active 1080p60 mirroring under 2.5% CPU succeeds
        engine
            .check_resource_budget(ResourceSnapshot {
                macos_rss_bytes: 38 * 1024 * 1024,
                macos_cpu_percent: 1.8,
                macos_gpu_percent: 4.0,
                is_session_active: true,
                android_idle_wakelocks: 0,
                android_idle_multicast_locks: 0,
            })
            .expect("active mirroring within 2.5% M1 CPU budget");
    }

    #[test]
    fn uniffi_and_c_ffi_exports_lifecycle() {
        assert_eq!(continuity_core_uniffi_contract_version(), 1);
        assert!(UNIFFI_UDL_DEFINITION.contains("interface ContinuityEngine"));

        unsafe {
            let mon = continuity_resource_monitor_create(0);
            assert!(!mon.is_null());
            assert_eq!(continuity_resource_monitor_preferred_codec(mon), 0);
            assert_eq!(
                continuity_resource_monitor_verify(mon, 20 * 1024 * 1024, 0.0, 0.0, false, 0, 0),
                0
            );
            continuity_resource_monitor_free(mon);

            let cert = b"host-x509-der";
            let store = continuity_paired_store_create_in_memory(cert.as_ptr(), cert.len());
            assert!(!store.is_null());
            let mut fp = [0u8; 32];
            assert_eq!(
                continuity_paired_store_local_fingerprint(store, fp.as_mut_ptr()),
                0
            );
            assert_eq!(fp, compute_cert_sha256(cert));
            continuity_paired_store_free(store);

            let id = b"mac-m1";
            let name = b"MacBook Pro";
            let eng = continuity_engine_create(
                id.as_ptr(),
                id.len(),
                name.as_ptr(),
                name.len(),
                0,
                cert.as_ptr(),
                cert.len(),
            );
            assert!(!eng.is_null());
            assert_eq!(continuity_engine_pending_frame_count(eng), 0);
            continuity_engine_free(eng);
        }
    }
}
