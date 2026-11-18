//! Typed error definitions for the `scrcpy` v3.x-v5.0 wire protocol, control channel, and session builder.

use thiserror::Error;

/// Result alias for `continuity-scrcpy` operations.
pub type Result<T> = std::result::Result<T, ScrcpyError>;

/// Errors returned while parsing `scrcpy` stream headers, serializing control packets, or building launch sessions.
#[derive(Debug, Error, Clone, PartialEq, Eq)]
pub enum ScrcpyError {
    /// Input buffer is shorter than the required wire structure size.
    #[error(
        "truncated {packet_type} at byte offset {offset}: expected at least {expected_len} bytes, got {actual_len} bytes"
    )]
    TruncatedPacket {
        /// Name of the header or packet being parsed.
        packet_type: &'static str,
        /// Byte offset in the stream or buffer where truncation was detected.
        offset: usize,
        /// Minimum expected byte length from `offset`.
        expected_len: usize,
        /// Actual available byte length from `offset`.
        actual_len: usize,
    },

    /// The initial 1-byte dummy handshake on an `adb forward` tunnel did not match `0x00`.
    #[error("invalid adb forward dummy byte at offset {offset}: expected 0x00, got 0x{actual_byte:02X}")]
    InvalidDummyByte {
        /// Byte offset in the stream where the dummy byte was read.
        offset: usize,
        /// Actual byte value received.
        actual_byte: u8,
    },

    /// The 64-byte device name header contained invalid UTF-8 bytes before the first NUL terminator.
    #[error("invalid UTF-8 in 64-byte device name header at byte offset {offset}")]
    InvalidDeviceNameUtf8 {
        /// Exact byte offset where invalid UTF-8 occurred.
        offset: usize,
    },

    /// The 12-byte stream codec header contained an unrecognized 4-byte big-endian ASCII codec ID.
    #[error(
        "unsupported codec ID 0x{raw_codec_id:08X} ({ascii:?}) at byte offset {offset}"
    )]
    UnsupportedCodecId {
        /// Byte offset of the 4-byte codec ID field.
        offset: usize,
        /// Raw big-endian `u32` codec identifier.
        raw_codec_id: u32,
        /// Printable ASCII representation (or replacement characters) of the 4 bytes.
        ascii: String,
    },

    /// Video stream dimensions in the 12-byte codec header or session configuration are invalid.
    #[error("invalid video dimensions {width}x{height} at byte offset {offset} in {context}")]
    InvalidDimensions {
        /// Context where dimensions were validated.
        context: &'static str,
        /// Byte offset in header (0 for configuration parameters).
        offset: usize,
        /// Parsed or requested width in pixels.
        width: u32,
        /// Parsed or requested height in pixels.
        height: u32,
    },

    /// Frame payload size in the 12-byte packet header exceeds the configured safety limit.
    #[error(
        "frame payload size {payload_size} bytes at offset {offset} exceeds maximum allowed {max_allowed} bytes (pts_and_flags=0x{pts_and_flags:016X})"
    )]
    FramePayloadTooLarge {
        /// Byte offset of the `u32` packet length field.
        offset: usize,
        /// Declared payload size in bytes.
        payload_size: u32,
        /// Maximum configured frame size in bytes.
        max_allowed: u32,
        /// Raw 64-bit `pts_and_flags` header value for diagnostic context.
        pts_and_flags: u64,
    },

    /// Control message payload length exceeds the protocol wire limit for its length field.
    #[error(
        "control message {message_type} payload too large: expected at most {max_len} bytes, got {actual_len} bytes"
    )]
    ControlPayloadTooLarge {
        /// Name of the control message variant.
        message_type: &'static str,
        /// Maximum representable or allowed byte length in the protocol.
        max_len: usize,
        /// Actual payload length provided by caller.
        actual_len: usize,
    },

    /// Touch pressure float is outside the valid `[0.0, 1.0]` range or NaN.
    #[error("invalid touch pressure {pressure_bits:#010x}: must be finite within 0.0..=1.0")]
    InvalidTouchPressure {
        /// IEEE-754 bits of the invalid `f32` pressure value.
        pressure_bits: u32,
    },

    /// Invalid session configuration parameter (such as empty package name or invalid FPS/DPI).
    #[error("invalid session configuration for {field}: {reason}")]
    InvalidSessionConfig {
        /// Name of the invalid configuration field.
        field: &'static str,
        /// Explanation of why the configuration was rejected.
        reason: &'static str,
    },
}
