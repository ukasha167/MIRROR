//! `continuity-scrcpy` — `scrcpy` v3.x-v5.0 wire protocol demuxer, control message serializer,
//! and server launch command builder for the Android ↔ macOS M1 Continuity Suite.
//!
//! # Modules
//! - [`error`]: Typed `thiserror` error variants with exact byte offsets and header values.
//! - [`demux`]: Zero-allocation wire parsers for the 1-byte dummy byte, 64-byte device name header,
//!   12-byte codec header, and 12-byte per-frame packet header.
//! - [`stream`]: Incremental chunked socket demuxer state machine ([`stream::ScrcpyStreamDemuxer`]).
//! - [`control`]: Binary serializer for all client-to-server `scrcpy` control messages (`UHID`, touch,
//!   clipboard, OLED display power, app launch, and video reset).
//! - [`session`]: Server launch command builder enforcing H.265 on Apple Silicon M1/M2, per-app virtual
//!   displays (`--new-display` + `--flex-display`), Continuity Webcam & Mic, and 3-Tier `FLAG_SECURE` handling.

#![forbid(unsafe_code)]
#![deny(missing_docs)]

pub mod control;
pub mod demux;
pub mod error;
pub mod session;
pub mod stream;

pub use control::{
    ControlMessage, CopyKey, KeyEventAction, MotionEventAction, ScreenPosition,
    POINTER_ID_GENERIC_FINGER, POINTER_ID_MOUSE,
};
pub use demux::{
    parse_device_name_header, parse_dummy_byte, parse_frame_header, parse_frame_packet,
    parse_stream_codec_header, CodecId, DeviceNameHeader, FrameHeader, FramePacket,
    StreamCodecHeader, PACKET_FLAG_CONFIG, PACKET_FLAG_KEY_FRAME, PACKET_PTS_MASK,
};
pub use error::{Result, ScrcpyError};
pub use session::{
    AppleSiliconChip, AudioSource, CameraFacing, FlagSecureTier, ScrcpyLaunchPlan,
    ScrcpySessionBuilder, SessionMode, VideoCodec, ROOT_SECURE_VIRTUAL_DISPLAY_FLAGS,
};
pub use stream::{OwnedFramePacket, ScrcpyStreamDemuxer};
