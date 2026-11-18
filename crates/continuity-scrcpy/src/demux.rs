//! Zero-allocation / low-copy `scrcpy` v3.x-v5.0 wire protocol parser and stream demuxer.
//! All multi-byte integer fields on the `scrcpy` wire are encoded in **big-endian** byte order.

use crate::error::{Result, ScrcpyError};

/// Size of the `adb forward` tunnel dummy byte (`1` byte).
pub const DUMMY_BYTE_LEN: usize = 1;
/// Size of the NUL-padded UTF-8 device name header (`64` bytes).
pub const DEVICE_NAME_HEADER_LEN: usize = 64;
/// Size of the stream codec metadata header (`12` bytes).
pub const STREAM_CODEC_HEADER_LEN: usize = 12;
/// Size of the per-frame packet header (`12` bytes).
pub const FRAME_HEADER_LEN: usize = 12;
/// Default maximum allowed single-frame payload size (`32 MiB`).
pub const DEFAULT_MAX_FRAME_SIZE: u32 = 32 * 1024 * 1024;

/// Bit 63 in `pts_and_flags`: marks a codec configuration packet (SPS/PPS/VPS or Opus header).
pub const PACKET_FLAG_CONFIG: u64 = 1 << 63;
/// Bit 62 in `pts_and_flags`: marks an IDR / keyframe packet.
pub const PACKET_FLAG_KEY_FRAME: u64 = 1 << 62;
/// Bitmask for Bits `0..=61`: presentation timestamp (PTS) in microseconds.
pub const PACKET_PTS_MASK: u64 = (1 << 62) - 1;

/// Supported `scrcpy` video and audio stream codec identifiers.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum CodecId {
    /// H.265 / HEVC video (`"h265"`, `0x68323635`). Primary codec for Apple Silicon M1/M2.
    H265,
    /// H.264 / AVC video (`"h264"`, `0x68323634`).
    H264,
    /// Opus audio (`"opus"`, `0x6F707573`).
    Opus,
    /// Raw PCM S16LE audio (`"\0raw"` `0x00726177` or `"raw\0"` `0x72617700`).
    Raw,
    /// FLAC lossless audio (`"flac"`, `0x666C6163`).
    Flac,
}

impl CodecId {
    /// Canonical 4-byte big-endian ASCII wire representation.
    #[must_use]
    pub const fn to_u32(self) -> u32 {
        match self {
            Self::H265 => u32::from_be_bytes(*b"h265"),
            Self::H264 => u32::from_be_bytes(*b"h264"),
            Self::Opus => u32::from_be_bytes(*b"opus"),
            Self::Raw => 0x0072_6177,
            Self::Flac => u32::from_be_bytes(*b"flac"),
        }
    }

    /// Parses a big-endian `u32` codec identifier at `offset`.
    pub fn from_u32(raw: u32, offset: usize) -> Result<Self> {
        match raw {
            0x6832_3635 => Ok(Self::H265),
            0x6832_3634 => Ok(Self::H264),
            0x6F70_7573 => Ok(Self::Opus),
            0x0072_6177 | 0x7261_7700 | 0x7261_7720 => Ok(Self::Raw),
            0x666C_6163 => Ok(Self::Flac),
            _ => {
                let bytes = raw.to_be_bytes();
                let ascii = String::from_utf8_lossy(&bytes).into_owned();
                Err(ScrcpyError::UnsupportedCodecId {
                    offset,
                    raw_codec_id: raw,
                    ascii,
                })
            }
        }
    }

    /// Returns `true` if this codec represents a video stream (`h265` or `h264`).
    #[must_use]
    pub const fn is_video(self) -> bool {
        matches!(self, Self::H265 | Self::H264)
    }

    /// Returns `true` if this codec represents an audio stream (`opus`, `raw`, or `flac`).
    #[must_use]
    pub const fn is_audio(self) -> bool {
        matches!(self, Self::Opus | Self::Raw | Self::Flac)
    }
}

/// Zero-allocation view over the 64-byte UTF-8 NUL-padded device name header.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DeviceNameHeader<'a> {
    name: &'a str,
}

impl<'a> DeviceNameHeader<'a> {
    /// Returns the trimmed UTF-8 device model name without trailing NUL bytes.
    #[must_use]
    pub const fn as_str(&self) -> &'a str {
        self.name
    }
}

/// Parsed 12-byte stream codec header emitted at the start of a video or audio stream.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct StreamCodecHeader {
    /// Stream codec (`h265`, `h264`, `opus`, `raw`, `flac`).
    pub codec_id: CodecId,
    /// Initial video width in pixels (`0` for audio streams).
    pub width: u32,
    /// Initial video height in pixels (`0` for audio streams).
    pub height: u32,
}

impl StreamCodecHeader {
    /// Serializes this 12-byte codec header into big-endian wire bytes.
    #[must_use]
    pub const fn to_bytes(self) -> [u8; STREAM_CODEC_HEADER_LEN] {
        let c = self.codec_id.to_u32().to_be_bytes();
        let w = self.width.to_be_bytes();
        let h = self.height.to_be_bytes();
        [c[0], c[1], c[2], c[3], w[0], w[1], w[2], w[3], h[0], h[1], h[2], h[3]]
    }
}

/// Parsed 12-byte per-frame packet header preceding each encoded video or audio frame.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct FrameHeader {
    /// Raw 64-bit `pts_and_flags` big-endian value.
    pub pts_and_flags: u64,
    /// Whether Bit 63 (`PACKET_FLAG_CONFIG`) is set (SPS/PPS/VPS or audio config header).
    pub is_config: bool,
    /// Whether Bit 62 (`PACKET_FLAG_KEY_FRAME`) is set (IDR / keyframe).
    pub is_keyframe: bool,
    /// Presentation timestamp in microseconds (`Bits 0..=61`).
    pub pts_us: u64,
    /// Encoded frame payload length in bytes (`Bytes 8..12`).
    pub payload_size: u32,
}

impl FrameHeader {
    /// Constructs a `FrameHeader` from explicit flags, PTS in microseconds, and payload size.
    #[must_use]
    pub const fn new(is_config: bool, is_keyframe: bool, pts_us: u64, payload_size: u32) -> Self {
        let mut pts_and_flags = pts_us & PACKET_PTS_MASK;
        if is_config {
            pts_and_flags |= PACKET_FLAG_CONFIG;
        }
        if is_keyframe {
            pts_and_flags |= PACKET_FLAG_KEY_FRAME;
        }
        Self {
            pts_and_flags,
            is_config,
            is_keyframe,
            pts_us: pts_us & PACKET_PTS_MASK,
            payload_size,
        }
    }

    /// Serializes this 12-byte frame header into big-endian wire bytes.
    #[must_use]
    pub const fn to_bytes(self) -> [u8; FRAME_HEADER_LEN] {
        let pf = self.pts_and_flags.to_be_bytes();
        let sz = self.payload_size.to_be_bytes();
        [pf[0], pf[1], pf[2], pf[3], pf[4], pf[5], pf[6], pf[7], sz[0], sz[1], sz[2], sz[3]]
    }
}

/// Zero-copy borrowed frame packet combining a parsed [`FrameHeader`] with its payload slice.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct FramePacket<'a> {
    /// Parsed 12-byte frame metadata header.
    pub header: FrameHeader,
    /// Borrowed slice of encoded NAL / audio frame bytes (`header.payload_size` bytes).
    pub payload: &'a [u8],
}

/// Parses the 1-byte dummy handshake byte sent on an `adb forward` tunnel.
///
/// # Binary Wire Layout (1 Byte)
/// - `0x00..0x01` (`1B u8`): Tunnel readiness dummy byte (`0x00`).
pub fn parse_dummy_byte(buf: &[u8], base_offset: usize) -> Result<&[u8]> {
    if buf.len() < DUMMY_BYTE_LEN {
        return Err(ScrcpyError::TruncatedPacket {
            packet_type: "dummy_byte",
            offset: base_offset,
            expected_len: DUMMY_BYTE_LEN,
            actual_len: buf.len(),
        });
    }
    if buf[0] != 0x00 {
        return Err(ScrcpyError::InvalidDummyByte {
            offset: base_offset,
            actual_byte: buf[0],
        });
    }
    Ok(&buf[DUMMY_BYTE_LEN..])
}

/// Parses the 64-byte NUL-padded UTF-8 device name header without heap allocation.
///
/// # Binary Wire Layout (64 Bytes)
/// - `0x00..0x40` (`64B [u8; 64]`): UTF-8 device model name padded with trailing `0x00` bytes.
pub fn parse_device_name_header(
    buf: &[u8],
    base_offset: usize,
) -> Result<(DeviceNameHeader<'_>, &[u8])> {
    if buf.len() < DEVICE_NAME_HEADER_LEN {
        return Err(ScrcpyError::TruncatedPacket {
            packet_type: "device_name_header",
            offset: base_offset,
            expected_len: DEVICE_NAME_HEADER_LEN,
            actual_len: buf.len(),
        });
    }
    let raw_field = &buf[..DEVICE_NAME_HEADER_LEN];
    let str_len = raw_field.iter().position(|&b| b == 0).unwrap_or(DEVICE_NAME_HEADER_LEN);
    let name = std::str::from_utf8(&raw_field[..str_len]).map_err(|err| {
        ScrcpyError::InvalidDeviceNameUtf8 {
            offset: base_offset + err.valid_up_to(),
        }
    })?;
    Ok((DeviceNameHeader { name }, &buf[DEVICE_NAME_HEADER_LEN..]))
}

/// Parses the 12-byte big-endian video or audio stream codec header.
///
/// # Binary Wire Layout (12 Bytes, Big-Endian)
/// - `0x00..0x04` (`4B u32 BE`): ASCII Codec ID (`"h265"`, `"h264"`, `"opus"`, `"\0raw"`, `"flac"`).
/// - `0x04..0x08` (`4B u32 BE`): Video width in pixels (`0` for audio streams).
/// - `0x08..0x0C` (`4B u32 BE`): Video height in pixels (`0` for audio streams).
pub fn parse_stream_codec_header(
    buf: &[u8],
    base_offset: usize,
) -> Result<(StreamCodecHeader, &[u8])> {
    if buf.len() < STREAM_CODEC_HEADER_LEN {
        return Err(ScrcpyError::TruncatedPacket {
            packet_type: "stream_codec_header",
            offset: base_offset,
            expected_len: STREAM_CODEC_HEADER_LEN,
            actual_len: buf.len(),
        });
    }
    let raw_codec = u32::from_be_bytes([buf[0], buf[1], buf[2], buf[3]]);
    let codec_id = CodecId::from_u32(raw_codec, base_offset)?;
    let width = u32::from_be_bytes([buf[4], buf[5], buf[6], buf[7]]);
    let height = u32::from_be_bytes([buf[8], buf[9], buf[10], buf[11]]);

    if codec_id.is_video() && (width == 0 || height == 0) {
        return Err(ScrcpyError::InvalidDimensions {
            context: "stream_codec_header",
            offset: base_offset + 4,
            width,
            height,
        });
    }
    Ok((StreamCodecHeader { codec_id, width, height }, &buf[STREAM_CODEC_HEADER_LEN..]))
}

/// Parses the 12-byte big-endian per-frame packet header.
///
/// # Binary Wire Layout (12 Bytes, Big-Endian)
/// - `0x00..0x08` (`8B u64 BE`): `pts_and_flags` (`Bit 63` = config SPS/PPS/VPS, `Bit 62` = keyframe, `Bits 0..=61` = PTS in microseconds).
/// - `0x08..0x0C` (`4B u32 BE`): Payload byte length (`N`).
pub fn parse_frame_header(
    buf: &[u8],
    base_offset: usize,
    max_payload_size: u32,
) -> Result<(FrameHeader, &[u8])> {
    if buf.len() < FRAME_HEADER_LEN {
        return Err(ScrcpyError::TruncatedPacket {
            packet_type: "frame_header",
            offset: base_offset,
            expected_len: FRAME_HEADER_LEN,
            actual_len: buf.len(),
        });
    }
    let pts_and_flags = u64::from_be_bytes([
        buf[0], buf[1], buf[2], buf[3], buf[4], buf[5], buf[6], buf[7],
    ]);
    let payload_size = u32::from_be_bytes([buf[8], buf[9], buf[10], buf[11]]);

    if payload_size > max_payload_size {
        return Err(ScrcpyError::FramePayloadTooLarge {
            offset: base_offset + 8,
            payload_size,
            max_allowed: max_payload_size,
            pts_and_flags,
        });
    }
    Ok((
        FrameHeader {
            pts_and_flags,
            is_config: (pts_and_flags & PACKET_FLAG_CONFIG) != 0,
            is_keyframe: (pts_and_flags & PACKET_FLAG_KEY_FRAME) != 0,
            pts_us: pts_and_flags & PACKET_PTS_MASK,
            payload_size,
        },
        &buf[FRAME_HEADER_LEN..],
    ))
}

/// Parses a complete frame (`12B FrameHeader + N-byte payload` slice) with zero heap allocations.
///
/// # Binary Wire Layout (`12 + N` Bytes, Big-Endian)
/// - `0x00..0x0C` (`12B`): [`FrameHeader`] (`u64 BE pts_and_flags`, `u32 BE payload_size = N`).
/// - `0x0C..0x0C+N` (`NB`): Encoded video NAL units or audio frame bytes.
pub fn parse_frame_packet<'a>(
    buf: &'a [u8],
    base_offset: usize,
    max_payload_size: u32,
) -> Result<(FramePacket<'a>, &'a [u8])> {
    let (header, rest) = parse_frame_header(buf, base_offset, max_payload_size)?;
    let payload_len = header.payload_size as usize;
    if rest.len() < payload_len {
        return Err(ScrcpyError::TruncatedPacket {
            packet_type: "frame_payload",
            offset: base_offset + FRAME_HEADER_LEN,
            expected_len: payload_len,
            actual_len: rest.len(),
        });
    }
    let (payload, remaining) = rest.split_at(payload_len);
    Ok((FramePacket { header, payload }, remaining))
}
