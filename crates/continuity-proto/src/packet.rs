//! Control Multiplexer packet types, binary header layout, and privacy-aware metadata.
//!
//! All control packets share a deterministic 24-byte big-endian frame header
//! protected by an IEEE 802.3 CRC32 / AEAD integrity tag.

use serde::{Deserialize, Serialize};

use crate::codec::{decode_frame_bytes, encode_frame_bytes};
use crate::error::{ProtoError, ProtoResult};

/// 4-byte ASCII magic header identifying a Mirror Continuity control frame (`"CNTY"`).
pub const FRAME_MAGIC: [u8; 4] = *b"CNTY";
/// Current wire protocol version (`1`).
pub const PROTOCOL_VERSION: u8 = 1;
/// Fixed byte length of [`ControlFrameHeader`].
pub const HEADER_LEN: usize = 24;
/// Maximum permitted payload size for a single control frame (4 MiB).
pub const MAX_CONTROL_PAYLOAD_LEN: usize = 4 * 1024 * 1024;

/// Wire discriminant for [`ControlPacket`] variants.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[repr(u8)]
pub enum PacketType {
    ClipboardOffer = 0x01,
    ClipboardDataChunk = 0x02,
    NotificationMirror = 0x03,
    NotificationInlineReply = 0x04,
    OtpCodeDetected = 0x05,
    MediaSessionUpdate = 0x06,
    MediaControlCommand = 0x07,
    DragOutOffer = 0x08,
    Heartbeat = 0x09,
    PowerStateUpdate = 0x0A,
}

impl PacketType {
    /// Converts a raw byte discriminant into a [`PacketType`].
    pub fn from_u8(byte: u8, stream_id: u32) -> ProtoResult<Self> {
        match byte {
            0x01 => Ok(Self::ClipboardOffer),
            0x02 => Ok(Self::ClipboardDataChunk),
            0x03 => Ok(Self::NotificationMirror),
            0x04 => Ok(Self::NotificationInlineReply),
            0x05 => Ok(Self::OtpCodeDetected),
            0x06 => Ok(Self::MediaSessionUpdate),
            0x07 => Ok(Self::MediaControlCommand),
            0x08 => Ok(Self::DragOutOffer),
            0x09 => Ok(Self::Heartbeat),
            0x0A => Ok(Self::PowerStateUpdate),
            other => Err(ProtoError::UnknownPacketType {
                packet_type: other,
                stream_id,
            }),
        }
    }
}

/// Fixed 24-byte control multiplexer frame header.
///
/// ### Binary Byte Layout (Big-Endian / Network Byte Order)
/// ```text
/// Offset  Length  Type     Description
/// ------  ------  -------  ----------------------------------------------------
/// 0..4    4B      [u8; 4]  Magic bytes: b"CNTY" (0x43, 0x4E, 0x54, 0x59)
/// 4..5    1B      u8       Protocol version (0x01)
/// 5..6    1B      u8       PacketType discriminant (0x01..=0x0A)
/// 6..8    2B      u16 BE   Frame flags (reserved / compression / priority bits)
/// 8..12   4B      u32 BE   Multiplexer stream ID
/// 12..16  4B      u32 BE   Monotonic sequence number per stream
/// 16..20  4B      u32 BE   Payload byte length (0..=4_194_304)
/// 20..24  4B      u32 BE   CRC32 / AEAD integrity tag over header[0..20] + payload
/// ```
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ControlFrameHeader {
    pub version: u8,
    pub packet_type: PacketType,
    pub flags: u16,
    pub stream_id: u32,
    pub sequence: u32,
    pub payload_len: u32,
    pub integrity_tag: u32,
}

impl ControlFrameHeader {
    /// Parses the 24-byte big-endian control frame header from `buf`.
    ///
    /// Byte layout: `[0..4]` magic `b"CNTY"`, `[4]` version, `[5]` packet_type,
    /// `[6..8]` flags BE, `[8..12]` stream_id BE, `[12..16]` sequence BE,
    /// `[16..20]` payload_len BE, `[20..24]` integrity_tag BE.
    pub fn parse(buf: &[u8]) -> ProtoResult<Self> {
        if buf.len() < HEADER_LEN {
            return Err(ProtoError::TruncatedHeader {
                expected: HEADER_LEN,
                actual: buf.len(),
            });
        }
        let magic: [u8; 4] = [buf[0], buf[1], buf[2], buf[3]];
        if magic != FRAME_MAGIC {
            return Err(ProtoError::InvalidMagic {
                expected: FRAME_MAGIC,
                actual: magic,
            });
        }
        let version = buf[4];
        if version != PROTOCOL_VERSION {
            return Err(ProtoError::UnsupportedVersion {
                version,
                supported: PROTOCOL_VERSION,
            });
        }
        let raw_type = buf[5];
        let flags = u16::from_be_bytes([buf[6], buf[7]]);
        let stream_id = u32::from_be_bytes([buf[8], buf[9], buf[10], buf[11]]);
        let sequence = u32::from_be_bytes([buf[12], buf[13], buf[14], buf[15]]);
        let payload_len = u32::from_be_bytes([buf[16], buf[17], buf[18], buf[19]]);
        let integrity_tag = u32::from_be_bytes([buf[20], buf[21], buf[22], buf[23]]);

        let packet_type = PacketType::from_u8(raw_type, stream_id)?;
        if (payload_len as usize) > MAX_CONTROL_PAYLOAD_LEN {
            return Err(ProtoError::PayloadTooLarge {
                packet_type: raw_type,
                length: payload_len as usize,
                max: MAX_CONTROL_PAYLOAD_LEN,
            });
        }

        Ok(Self {
            version,
            packet_type,
            flags,
            stream_id,
            sequence,
            payload_len,
            integrity_tag,
        })
    }
}

/// Lazy clipboard promise metadata (`NSPasteboardItemDataProvider` / `IClipboard`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ClipboardOffer {
    pub offer_id: u64,
    pub mime_type: String,
    pub byte_length: u64,
    pub sha256: [u8; 32],
    pub preview_thumb: Vec<u8>,
    pub is_concealed: bool,
    pub is_transient: bool,
}

impl ClipboardOffer {
    /// Enforces 1Password (`ConcealedType`) and Maccy (`TransientType`) privacy compliance.
    pub fn should_auto_sync(&self, allow_concealed: bool) -> bool {
        !self.is_transient && (!self.is_concealed || allow_concealed)
    }
}

/// Streamed data chunk fulfilling a lazy [`ClipboardOffer`].
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ClipboardDataChunk {
    pub offer_id: u64,
    pub chunk_index: u32,
    pub total_chunks: u32,
    pub is_last: bool,
    pub data: Vec<u8>,
}

/// Mirrored Android notification captured by `NotificationListenerService`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct NotificationMirror {
    pub notification_id: String,
    pub package_name: String,
    pub app_name: String,
    pub title: String,
    pub body: String,
    pub timestamp_ms: u64,
    pub can_reply_inline: bool,
    pub icon_png: Vec<u8>,
}

/// Inline reply sent from macOS `UNUserNotificationCenter` back to Android `RemoteInput`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct NotificationInlineReply {
    pub notification_id: String,
    pub reply_text: String,
    pub dismiss_after_reply: bool,
}

/// Extracted 2FA OTP verification code (`Mr-vero/hop` pattern).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct OtpCodeDetected {
    pub code: String,
    pub issuer: String,
    pub expires_in_secs: u16,
}

/// Now Playing media metadata from Android `MediaSessionManager`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct MediaSessionUpdate {
    pub package_name: String,
    pub title: String,
    pub artist: String,
    pub album: String,
    pub is_playing: bool,
    pub position_ms: u64,
    pub duration_ms: u64,
    pub album_art_thumb: Vec<u8>,
}

/// Playback control action dispatched between macOS and Android.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum MediaAction {
    Play,
    Pause,
    TogglePlayPause,
    NextTrack,
    PreviousTrack,
    SeekToMs(u64),
    SetVolumePercent(u8),
}

/// Media playback command packet.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct MediaControlCommand {
    pub action: MediaAction,
}

/// Phone-to-Mac drag-out metadata intercepted from `View.startDragAndDrop`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DragOutOffer {
    pub drag_id: u64,
    pub content_uri: String,
    pub filename: String,
    pub mime_type: String,
    pub size: u64,
    pub cursor_exit_x: i32,
    pub cursor_exit_y: i32,
}

/// Multiplexer heartbeat and RTT measurement packet.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct Heartbeat {
    pub sequence: u64,
    pub timestamp_ms: u64,
    pub rtt_hint_us: u32,
}

/// Device thermal state matching Android `PowerManager` / macOS `ProcessInfo.ThermalState`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[repr(u8)]
pub enum ThermalState {
    Nominal = 0,
    Fair = 1,
    Serious = 2,
    Critical = 3,
}

impl ThermalState {
    pub fn from_u8(val: u8, packet_type: u8) -> ProtoResult<Self> {
        match val {
            0 => Ok(Self::Nominal),
            1 => Ok(Self::Fair),
            2 => Ok(Self::Serious),
            3 => Ok(Self::Critical),
            other => Err(ProtoError::InvalidEnumValue {
                packet_type,
                field: "thermal_state",
                raw_value: other,
            }),
        }
    }
}

/// Device battery, charging, thermal, and physical OLED display power state.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct PowerStateUpdate {
    pub battery_percent: u8,
    pub is_charging: bool,
    pub thermal_state: ThermalState,
    pub oled_screen_off: bool,
}

/// Unified control packet payload enum.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum ControlPacket {
    ClipboardOffer(ClipboardOffer),
    ClipboardDataChunk(ClipboardDataChunk),
    NotificationMirror(NotificationMirror),
    NotificationInlineReply(NotificationInlineReply),
    OtpCodeDetected(OtpCodeDetected),
    MediaSessionUpdate(MediaSessionUpdate),
    MediaControlCommand(MediaControlCommand),
    DragOutOffer(DragOutOffer),
    Heartbeat(Heartbeat),
    PowerStateUpdate(PowerStateUpdate),
}

impl ControlPacket {
    pub fn packet_type(&self) -> PacketType {
        match self {
            Self::ClipboardOffer(_) => PacketType::ClipboardOffer,
            Self::ClipboardDataChunk(_) => PacketType::ClipboardDataChunk,
            Self::NotificationMirror(_) => PacketType::NotificationMirror,
            Self::NotificationInlineReply(_) => PacketType::NotificationInlineReply,
            Self::OtpCodeDetected(_) => PacketType::OtpCodeDetected,
            Self::MediaSessionUpdate(_) => PacketType::MediaSessionUpdate,
            Self::MediaControlCommand(_) => PacketType::MediaControlCommand,
            Self::DragOutOffer(_) => PacketType::DragOutOffer,
            Self::Heartbeat(_) => PacketType::Heartbeat,
            Self::PowerStateUpdate(_) => PacketType::PowerStateUpdate,
        }
    }
}

/// Complete multiplexed control frame combining stream metadata and [`ControlPacket`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ControlFrame {
    pub stream_id: u32,
    pub flags: u16,
    pub sequence: u32,
    pub packet: ControlPacket,
}

impl ControlFrame {
    pub fn encode(&self) -> ProtoResult<Vec<u8>> {
        encode_frame_bytes(self)
    }

    pub fn decode(bytes: &[u8]) -> ProtoResult<Self> {
        decode_frame_bytes(bytes)
    }
}
