//! Integration and stream-demux tests for `continuity-scrcpy`.

use continuity_scrcpy::*;

fn build_handshake_bytes(device_name: &str, codec: CodecId, width: u32, height: u32) -> Vec<u8> {
    let mut wire = Vec::with_capacity(1 + 64 + 12);
    wire.push(0x00); // 1-byte dummy byte
    let mut name_buf = [0u8; 64];
    let name_bytes = device_name.as_bytes();
    name_buf[..name_bytes.len()].copy_from_slice(name_bytes);
    wire.extend_from_slice(&name_buf);
    let codec_hdr = StreamCodecHeader {
        codec_id: codec,
        width,
        height,
    };
    wire.extend_from_slice(&codec_hdr.to_bytes());
    wire
}

#[test]
fn test_demux_dummy_device_codec_and_frames_zero_copy() {
    let mut wire = build_handshake_bytes("Pixel 9 Pro XL", CodecId::H265, 1080, 2400);

    // Frame 1: Config packet (Bit 63 = 1, Bit 62 = 0, PTS = 0, 6 bytes VPS/SPS/PPS)
    let cfg_payload = [0x00, 0x00, 0x00, 0x01, 0x40, 0x01];
    let cfg_hdr = FrameHeader::new(true, false, 0, cfg_payload.len() as u32);
    wire.extend_from_slice(&cfg_hdr.to_bytes());
    wire.extend_from_slice(&cfg_payload);

    // Frame 2: Keyframe (Bit 63 = 0, Bit 62 = 1, PTS = 16_666 us, 4 bytes IDR slice)
    let idr_payload = [0x00, 0x00, 0x01, 0x26];
    let idr_hdr = FrameHeader::new(false, true, 16_666, idr_payload.len() as u32);
    wire.extend_from_slice(&idr_hdr.to_bytes());
    wire.extend_from_slice(&idr_payload);

    // Frame 3: P-frame (Bit 63 = 0, Bit 62 = 0, PTS = 33_333 us, 3 bytes slice)
    let p_payload = [0x02, 0x01, 0xFF];
    let p_hdr = FrameHeader::new(false, false, 33_333, p_payload.len() as u32);
    wire.extend_from_slice(&p_hdr.to_bytes());
    wire.extend_from_slice(&p_payload);

    let rest = parse_dummy_byte(&wire, 0).expect("valid dummy byte");
    let (dev, rest) = parse_device_name_header(rest, 1).expect("valid device name");
    assert_eq!(dev.as_str(), "Pixel 9 Pro XL");

    let (codec_hdr, rest) = parse_stream_codec_header(rest, 65).expect("valid codec header");
    assert_eq!(codec_hdr.codec_id, CodecId::H265);
    assert_eq!(codec_hdr.width, 1080);
    assert_eq!(codec_hdr.height, 2400);

    let (f1, rest) =
        parse_frame_packet(rest, 77, demux::DEFAULT_MAX_FRAME_SIZE).expect("frame 1");
    assert!(f1.header.is_config);
    assert!(!f1.header.is_keyframe);
    assert_eq!(f1.header.pts_us, 0);
    assert_eq!(f1.payload, &cfg_payload);

    let (f2, rest) =
        parse_frame_packet(rest, 95, demux::DEFAULT_MAX_FRAME_SIZE).expect("frame 2");
    assert!(!f2.header.is_config);
    assert!(f2.header.is_keyframe);
    assert_eq!(f2.header.pts_us, 16_666);
    assert_eq!(f2.payload, &idr_payload);

    let (f3, rest) =
        parse_frame_packet(rest, 111, demux::DEFAULT_MAX_FRAME_SIZE).expect("frame 3");
    assert!(!f3.header.is_config);
    assert!(!f3.header.is_keyframe);
    assert_eq!(f3.header.pts_us, 33_333);
    assert_eq!(f3.payload, &p_payload);
    assert!(rest.is_empty());
}

#[test]
fn test_all_supported_codecs_and_errors() {
    for (codec, raw) in [
        (CodecId::H265, u32::from_be_bytes(*b"h265")),
        (CodecId::H264, u32::from_be_bytes(*b"h264")),
        (CodecId::Opus, u32::from_be_bytes(*b"opus")),
        (CodecId::Raw, 0x0072_6177),
        (CodecId::Flac, u32::from_be_bytes(*b"flac")),
    ] {
        assert_eq!(CodecId::from_u32(raw, 0).expect("codec"), codec);
    }
    assert_eq!(
        CodecId::from_u32(u32::from_be_bytes(*b"raw\0"), 0).expect("raw padded"),
        CodecId::Raw
    );

    let mut bad_codec = [0u8; 12];
    bad_codec[..4].copy_from_slice(b"vp90");
    assert_eq!(
        parse_stream_codec_header(&bad_codec, 65),
        Err(ScrcpyError::UnsupportedCodecId {
            offset: 65,
            raw_codec_id: 0x7670_3930,
            ascii: "vp90".to_owned(),
        })
    );

    assert_eq!(
        parse_dummy_byte(&[0x42], 0),
        Err(ScrcpyError::InvalidDummyByte {
            offset: 0,
            actual_byte: 0x42,
        })
    );

    let big_hdr = FrameHeader::new(false, true, 500, 10_000).to_bytes();
    assert_eq!(
        parse_frame_header(&big_hdr, 128, 4096),
        Err(ScrcpyError::FramePayloadTooLarge {
            offset: 136,
            payload_size: 10_000,
            max_allowed: 4096,
            pts_and_flags: (1 << 62) | 500,
        })
    );
}

#[test]
fn test_incremental_stream_demuxer_single_byte_chunks() {
    let mut wire = build_handshake_bytes("Galaxy S25 Ultra", CodecId::Opus, 0, 0);
    let opus_cfg = [0x4F, 0x70, 0x75, 0x73, 0x48, 0x65, 0x61, 0x64];
    wire.extend_from_slice(&FrameHeader::new(true, false, 0, opus_cfg.len() as u32).to_bytes());
    wire.extend_from_slice(&opus_cfg);

    let audio_pkt = [0xAA, 0xBB, 0xCC, 0xDD];
    wire.extend_from_slice(
        &FrameHeader::new(false, true, 20_000, audio_pkt.len() as u32).to_bytes(),
    );
    wire.extend_from_slice(&audio_pkt);

    let mut demuxer = ScrcpyStreamDemuxer::new(true, true);
    let mut collected = Vec::new();
    for byte in &wire {
        let mut out = demuxer.push_bytes(std::slice::from_ref(byte)).expect("chunk parse");
        collected.append(&mut out);
    }

    assert_eq!(demuxer.device_name(), Some("Galaxy S25 Ultra"));
    assert_eq!(
        demuxer.codec_header(),
        Some(StreamCodecHeader { codec_id: CodecId::Opus, width: 0, height: 0 })
    );
    assert_eq!(collected.len(), 2);
    assert!(collected[0].header.is_config);
    assert_eq!(collected[0].payload, opus_cfg);
    assert!(collected[1].header.is_keyframe);
    assert_eq!(collected[1].header.pts_us, 20_000);
    assert_eq!(collected[1].payload, audio_pkt);
    assert_eq!(demuxer.bytes_consumed(), wire.len());
}

#[test]
fn test_control_message_serialization_all_variants() {
    let key_bytes = ControlMessage::InjectKeycode {
        action: KeyEventAction::Down, keycode: 66, repeat: 0, metastate: 0,
    }.to_bytes().expect("keycode");
    assert_eq!(key_bytes.len(), 14);
    assert_eq!(key_bytes[0], control::TYPE_INJECT_KEYCODE);
    assert_eq!(u32::from_be_bytes([key_bytes[2], key_bytes[3], key_bytes[4], key_bytes[5]]), 66);

    let txt_bytes = ControlMessage::InjectText { text: "Hello".to_owned() }.to_bytes().expect("text");
    assert_eq!(txt_bytes, &[1, 0, 0, 0, 5, b'H', b'e', b'l', b'l', b'o']);

    let touch_bytes = ControlMessage::InjectTouchEvent {
        action: MotionEventAction::Down,
        pointer_id: POINTER_ID_GENERIC_FINGER,
        position: ScreenPosition { x: 540, y: 1200, screen_width: 1080, screen_height: 2400 },
        pressure: 1.0,
        action_button: 1,
        buttons: 1,
    }.to_bytes().expect("touch");
    assert_eq!(touch_bytes.len(), 32);
    assert_eq!(touch_bytes[0], control::TYPE_INJECT_TOUCH_EVENT);
    assert_eq!(u16::from_be_bytes([touch_bytes[22], touch_bytes[23]]), 0xFFFF);

    let scroll_bytes = ControlMessage::InjectScrollEvent {
        position: ScreenPosition { x: 200, y: 300, screen_width: 1080, screen_height: 2400 },
        hscroll: 0, vscroll: -120, buttons: 0,
    }.to_bytes().expect("scroll");
    assert_eq!(scroll_bytes.len(), 21);
    assert_eq!(scroll_bytes[0], control::TYPE_INJECT_SCROLL_EVENT);

    assert_eq!(ControlMessage::BackOrScreenOn { action: KeyEventAction::Up }.to_bytes().expect("back"), &[4, 1]);
    assert_eq!(ControlMessage::ExpandNotificationPanel.to_bytes().expect("notif"), &[5]);
    assert_eq!(ControlMessage::ExpandSettingsPanel.to_bytes().expect("settings"), &[6]);
    assert_eq!(ControlMessage::CollapsePanels.to_bytes().expect("collapse"), &[7]);
    assert_eq!(ControlMessage::GetClipboard { copy_key: CopyKey::Copy }.to_bytes().expect("get_clip"), &[8, 1]);

    let clip_bytes = ControlMessage::SetClipboard {
        sequence: 42, paste: true, text: "OTP-482910".to_owned(),
    }.to_bytes().expect("set_clip");
    assert_eq!(clip_bytes.len(), 14 + 10);
    assert_eq!(clip_bytes[0], control::TYPE_SET_CLIPBOARD);
    assert_eq!(clip_bytes[9], 1);

    assert_eq!(ControlMessage::SetDisplayPower { on: false }.to_bytes().expect("power off"), &[10, 0]);

    let uhid_create = ControlMessage::UhidCreate {
        id: 1, vendor_id: 0x18D1, product_id: 0x4EE7,
        name: "ContinuityKVM".to_owned(),
        report_desc: vec![0x05, 0x01, 0x09, 0x02],
    }.to_bytes().expect("uhid create");
    assert_eq!(uhid_create[0], control::TYPE_UHID_CREATE);
    assert_eq!(uhid_create.len(), 10 + "ContinuityKVM".len() + 4);

    let uhid_in = ControlMessage::UhidInput { id: 1, data: vec![0x00, 0x05, 0xFB] }.to_bytes().expect("uhid input");
    assert_eq!(uhid_in, &[13, 0, 1, 0, 3, 0x00, 0x05, 0xFB]);
    assert_eq!(ControlMessage::UhidDestroy { id: 1 }.to_bytes().expect("uhid destroy"), &[14, 0, 1]);

    let app_bytes = ControlMessage::StartApp { package_name: "com.whatsapp".to_owned() }.to_bytes().expect("start app");
    assert_eq!(app_bytes[0], control::TYPE_START_APP);
    assert_eq!(app_bytes[1] as usize, "com.whatsapp".len());
    assert_eq!(ControlMessage::ResetVideo.to_bytes().expect("reset video"), &[17]);
}

#[test]
fn test_session_builder_m1_h265_virtual_display_webcam_and_flag_secure_tiers() {
    let plan_m1 = ScrcpySessionBuilder::new(SessionMode::PrimaryDisplay {
        max_size: Some(1920),
        turn_screen_off: true,
    })
    .host_chip(AppleSiliconChip::M1)
    .video_codec(VideoCodec::Av1)
    .flag_secure_tier(FlagSecureTier::Tier1RootSu)
    .build()
    .expect("m1 primary plan");

    assert_eq!(plan_m1.effective_codec, VideoCodec::H265);
    assert!(plan_m1.server_args.iter().any(|a| a == "video_codec=h265"));
    assert!(plan_m1.cli_flags.iter().any(|f| f == "--turn-screen-off"));
    assert!(plan_m1.adb_shell_command.starts_with("su -c \"CLASSPATH="));
    assert!(plan_m1.adb_shell_command.contains("secure_display=true"));
    assert_eq!(plan_m1.virtual_display_flags, ROOT_SECURE_VIRTUAL_DISPLAY_FLAGS);

    let plan_app = ScrcpySessionBuilder::new(SessionMode::PerAppVirtualDisplay {
        width: 1080,
        height: 2340,
        dpi: 420,
        package_name: "com.whatsapp".to_owned(),
    })
    .flag_secure_tier(FlagSecureTier::Tier2LsposedActive)
    .build()
    .expect("per-app virtual display plan");

    for expected_flag in [
        "--new-display=1080x2340/420",
        "--start-app=com.whatsapp",
        "--no-vd-destroy-content",
        "--no-vd-system-decorations",
        "--display-ime-policy=local",
        "--flex-display",
    ] {
        assert!(
            plan_app.cli_flags.iter().any(|f| f == expected_flag),
            "missing flag {expected_flag}"
        );
    }
    assert!(plan_app
        .adb_shell_command
        .contains("lsposed_disable_flag_secure=active"));
    assert!(!plan_app.accessibility_wireframe_enabled);

    let plan_cam = ScrcpySessionBuilder::new(SessionMode::ContinuityWebcam {
        width: 1920,
        height: 1080,
        fps: 60,
        facing: CameraFacing::Back,
        audio_source: AudioSource::MicVoiceCommunication,
    })
    .flag_secure_tier(FlagSecureTier::Tier3NonRootAccessibilityWireframe)
    .build()
    .expect("webcam plan");

    for expected_flag in [
        "--video-source=camera",
        "--camera-size=1920x1080",
        "--camera-fps=60",
        "--camera-facing=back",
        "--audio-source=mic-voice-communication",
    ] {
        assert!(
            plan_cam.cli_flags.iter().any(|f| f == expected_flag),
            "missing webcam flag {expected_flag}"
        );
    }
    assert!(plan_cam.accessibility_wireframe_enabled);
    assert!(plan_cam
        .adb_shell_command
        .contains("accessibility_wireframe=true"));
}
