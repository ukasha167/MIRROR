//! `continuity-wireless` — Dual-protocol wireless engine for Android ↔ macOS Continuity.
//!
//! Combines:
//! 1. **Enhanced LocalSend v2.1** (`localsend`) with pinned mTLS certificate auto-accept.
//! 2. **Fast-Stream Upgrade** (`fast_stream`, `/api/localsend/v2/fast-stream`) over 4 parallel
//!    async TCP+TLS streams with in-flight tar streaming and SHA-256 verification for `<1 MiB` files.
//! 3. **Embedded Google Quick Share Receiver** (`quickshare`, ported from public-domain `NearDrop`).
//! 4. **Zero-Config Discovery** (`discovery`) across hardware-offloaded mDNS and UDP multicast,
//!    respecting Android 17 `ACCESS_LOCAL_NETWORK` and zero idle `MulticastLock`.

pub mod discovery;
pub mod error;
pub mod fast_stream;
pub mod localsend;
pub mod quickshare;

#[cfg(test)]
mod tests {
    use std::collections::BTreeMap;
    use std::future::Future;
    use std::net::{IpAddr, Ipv4Addr};
    use std::sync::Arc;
    use std::task::{Context, Poll, Wake, Waker};

    use sha2::{Digest, Sha256};

    use crate::discovery::{
        DiscoveryController, DiscoveryPowerMode, LocalNetworkPermissionState,
        LocalSendMulticastPacket, MdnsServiceDescriptor, ResolvedWirelessEndpoint,
        LOCALSEND_DEFAULT_PORT,
    };
    use crate::error::WirelessError;
    use crate::fast_stream::{
        execute_parallel_fast_stream, unpack_and_verify_tar_entries, StreamFrameHeader,
        StreamFrameKind, TransferFile, PARALLEL_STREAM_COUNT, SMALL_FILE_THRESHOLD_BYTES,
    };
    use crate::localsend::{
        DeviceType, FileDto, LocalSendSessionManager, PinnedPeerStore, PrepareUploadRequestDto,
        ProtocolType, RegisterDto,
    };
    use crate::quickshare::{
        PairedKeyFrameCodec, QuickShareDeviceType, QuickShareEndpointInfo, QuickShareFrameCodec,
        QuickSharePayloadReassembler, Ukey2HandshakeMachine, Ukey2State,
    };

    struct NoopWake;
    impl Wake for NoopWake {
        fn wake(self: Arc<Self>) {}
    }

    fn block_on<F: Future>(fut: F) -> F::Output {
        let waker = Waker::from(Arc::new(NoopWake));
        let mut cx = Context::from_waker(&waker);
        let mut pinned = Box::pin(fut);
        loop {
            if let Poll::Ready(val) = pinned.as_mut().poll(&mut cx) {
                return val;
            }
        }
    }

    #[test]
    fn test_discovery_android17_permission_and_idle_multicast_guard() {
        let mut ctrl = DiscoveryController::new(LocalNetworkPermissionState::Denied);
        let ip = IpAddr::V4(Ipv4Addr::new(192, 168, 1, 42));
        let ls_adv = MdnsServiceDescriptor::new_localsend_advertisement(
            "Pixel 10 Pro",
            "abcdef0123456789",
            "Pixel 10 Pro",
            vec![ip],
            LOCALSEND_DEFAULT_PORT,
            true,
        );
        assert!(matches!(
            ctrl.on_mdns_service_resolved(&ls_adv),
            Err(WirelessError::LocalNetworkPermissionDenied { .. })
        ));
        assert!(!ctrl.requires_multicast_lock());

        ctrl.set_permission_state(LocalNetworkPermissionState::Granted);
        assert!(!ctrl.requires_multicast_lock());

        let mcast_pkt = LocalSendMulticastPacket {
            alias: "MacBook Air M1".into(),
            version: "2.1".into(),
            device_model: Some("MacBookAir10,1".into()),
            device_type: Some(DeviceType::Desktop),
            fingerprint: "fedcba9876543210".into(),
            port: LOCALSEND_DEFAULT_PORT,
            protocol: ProtocolType::Https,
            download: false,
            announce: true,
        };
        assert_eq!(
            ctrl.prepare_multicast_pulse(&mcast_pkt),
            Err(WirelessError::MulticastForbiddenWhileIdle)
        );

        ctrl.set_power_mode(DiscoveryPowerMode::ActiveSendSheetPulse);
        assert!(ctrl.requires_multicast_lock());
        let raw_udp = ctrl.prepare_multicast_pulse(&mcast_pkt).expect("pulse allowed");
        let resolved_udp = ctrl.on_multicast_datagram(&raw_udp, ip).expect("parse udp");
        assert!(matches!(
            resolved_udp,
            ResolvedWirelessEndpoint::LocalSend { alias, .. } if alias == "MacBook Air M1"
        ));

        let qs_info = QuickShareEndpointInfo {
            version: 0,
            visible_to_everyone: true,
            device_type: QuickShareDeviceType::Laptop,
            device_name: "Ukasha Mac M1".into(),
        };
        let qs_adv = MdnsServiceDescriptor::new_quickshare_advertisement(
            *b"M1MC",
            &qs_info,
            vec![ip],
            54321,
        );
        let resolved_qs = ctrl.on_mdns_service_resolved(&qs_adv).expect("resolve qs");
        assert_eq!(
            resolved_qs,
            ResolvedWirelessEndpoint::QuickShare {
                endpoint_id: *b"M1MC",
                endpoint_info: qs_info,
                addresses: vec![ip],
                port: 54321,
            }
        );
        assert_eq!(ctrl.discovered_endpoints().len(), 2);
    }

    #[test]
    fn test_localsend_pinned_certificate_auto_accept_and_token_validation() {
        let cert_der = b"mock-ed25519-x509-certificate-der-bytes";
        let pinned_fp = PinnedPeerStore::fingerprint_from_der_cert(cert_der);

        let mut store = PinnedPeerStore::new();
        store.pin_fingerprint(&pinned_fp);
        let mut mgr = LocalSendSessionManager::new(store);

        let mut files = BTreeMap::new();
        files.insert(
            "f1".into(),
            FileDto {
                id: "f1".into(),
                file_name: "notes.txt".into(),
                size: 128,
                file_type: "text/plain".into(),
                sha256: None,
                preview: Some("Hello Continuity".into()),
                metadata: None,
            },
        );

        let req = PrepareUploadRequestDto {
            info: RegisterDto {
                alias: "Pixel 10".into(),
                version: "2.1".into(),
                device_model: Some("Pixel 10".into()),
                device_type: Some(DeviceType::Mobile),
                fingerprint: pinned_fp.clone(),
                port: LOCALSEND_DEFAULT_PORT,
                protocol: ProtocolType::Https,
                download: false,
                fast_stream_capable: true,
            },
            files,
        };

        let resp = mgr.prepare_upload(&req, &pinned_fp, false).expect("auto-accept paired");
        let session = mgr.get_session(&resp.session_id).expect("session stored");
        assert!(session.auto_accepted);
        assert!(resp.fast_stream.is_some());

        let token = resp.files.get("f1").expect("token issued");
        let dto = mgr
            .validate_upload_token(&resp.session_id, "f1", token)
            .expect("valid token");
        assert_eq!(dto.file_name, "notes.txt");
        assert!(mgr.validate_upload_token(&resp.session_id, "f1", "bad-token").is_err());

        let unpinned_err = mgr.prepare_upload(&req, "0000unpinned", false);
        assert!(matches!(unpinned_err, Err(WirelessError::UntrustedPeerFingerprint { .. })));
    }

    #[test]
    fn test_fast_stream_5000_small_files_and_parallel_large_files_loopback() {
        let mut batch = Vec::with_capacity(5004);
        for i in 0..5000 {
            let content = format!("small-file-payload-{i:04}-continuity").into_bytes();
            batch.push(TransferFile::new(
                format!("small-{i:04}"),
                format!("DCIM/burst/IMG_{i:04}.jpg"),
                content,
            ));
        }
        for i in 0..4 {
            let large_data = vec![(i as u8).wrapping_add(0x41); (SMALL_FILE_THRESHOLD_BYTES as usize) + 4096];
            batch.push(TransferFile::new(
                format!("large-{i}"),
                format!("Movies/clip_{i}.mp4"),
                large_data,
            ));
        }

        let result = block_on(execute_parallel_fast_stream(&batch)).expect("parallel transfer");
        assert_eq!(result.files.len(), 5004);
        assert_eq!(result.small_files_tar_unpacked, 5000);
        assert_eq!(result.large_files_streamed, 4);
        for lane_idx in 0..PARALLEL_STREAM_COUNT {
            assert!(result.lane_wire_bytes[lane_idx] > 0, "lane {lane_idx} was utilized");
        }
        assert_eq!(
            result.files.get("small-4999").expect("last small").data,
            b"small-file-payload-4999-continuity"
        );
    }

    #[test]
    fn test_fast_stream_detects_sha256_corruption_and_bad_headers() {
        let f = TransferFile::new("id-1", "test.bin", b"authentic-payload".to_vec());
        let mut packed = crate::fast_stream::pack_streaming_tar_entries(&[f]);
        let last_idx = packed.len() - 1;
        packed[last_idx] ^= 0xFF;
        let err = unpack_and_verify_tar_entries(&packed, 1);
        assert!(matches!(err, Err(WirelessError::ChecksumMismatch { .. })));

        let bad_hdr = StreamFrameHeader {
            stream_index: 9,
            frame_kind: StreamFrameKind::StreamFin,
            item_count: 0,
            payload_len: 0,
        };
        let encoded = bad_hdr.encode();
        assert!(matches!(
            StreamFrameHeader::decode(&encoded),
            Err(WirelessError::StreamIndexOutOfBounds { stream_index: 9, .. })
        ));
    }

    #[test]
    fn test_quickshare_ukey2_paired_key_and_payload_reassembly() {
        let mut ukey2 = Ukey2HandshakeMachine::new();
        assert_eq!(ukey2.state(), Ukey2State::Initial);

        let server_pub = [0x33u8; 32];
        let server_init_frame = ukey2
            .on_client_init(b"CLIENT_INIT_NONCE_AND_COMMIT", &server_pub)
            .expect("client init");
        let (decoded_init, _) = QuickShareFrameCodec::decode_frame(&server_init_frame).expect("frame");
        assert!(decoded_init.starts_with(b"UKEY2_SERVER_INIT:"));
        assert_eq!(ukey2.state(), Ukey2State::ServerInitSent);

        let pin = ukey2
            .on_client_finish(b"CLIENT_FINISH_P256_PUBKEY")
            .expect("client finish");
        assert_eq!(pin.len(), 6);
        assert_eq!(ukey2.state(), Ukey2State::ClientFinishReceived);

        let paired_secret = b"shared-paired-key-secret";
        let proof: [u8; 32] = Sha256::new()
            .chain_update(paired_secret)
            .chain_update(ukey2.d2d_client_key())
            .finalize()
            .into();
        ukey2
            .verify_paired_key_encryption(&proof, Some(paired_secret))
            .expect("paired key verified");
        assert_eq!(ukey2.state(), Ukey2State::Established);

        let key = *ukey2.d2d_client_key();
        let sealed = PairedKeyFrameCodec::seal(&key, 1, b"chunk-0-hello-");
        let opened = PairedKeyFrameCodec::open(&key, 1, &sealed).expect("open d2d frame");
        assert_eq!(opened, b"chunk-0-hello-");
        assert!(matches!(
            PairedKeyFrameCodec::open(&key, 2, &sealed),
            Err(WirelessError::QuickShareAuthFailure { .. })
        ));

        let mut reassembler = QuickSharePayloadReassembler::default();
        reassembler.register_introduction(77, "photo.heic".into(), 20);
        assert_eq!(reassembler.ingest_chunk(77, 0, opened, false).expect("chunk 0"), None);
        let done = reassembler
            .ingest_chunk(77, 14, b"world!", true)
            .expect("chunk 1")
            .expect("reassembled");
        assert_eq!(done.0, "photo.heic");
        assert_eq!(done.1, b"chunk-0-hello-world!");
    }
}
