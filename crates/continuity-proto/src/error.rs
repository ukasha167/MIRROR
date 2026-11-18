//! Typed protocol and pairing errors with packet and byte-length context.
//!
//! Every parser and state-machine transition returns [`ProtoError`] rather than
//! panicking on untrusted network, USB, or socket inputs.

use thiserror::Error;

/// Errors produced by `continuity-proto` frame codecs and pairing state machines.
#[derive(Debug, Error, Clone, PartialEq, Eq)]
pub enum ProtoError {
    /// Input buffer is shorter than the fixed 24-byte control frame header.
    #[error("truncated control frame header: expected at least {expected} bytes, got {actual}")]
    TruncatedHeader {
        /// Minimum bytes required for the header.
        expected: usize,
        /// Actual bytes available in the input slice.
        actual: usize,
    },

    /// The 4-byte magic prefix did not match `CNTY` (`0x434E5459`).
    #[error("invalid frame magic: expected {expected:02X?}, got {actual:02X?}")]
    InvalidMagic {
        /// Expected magic bytes (`b"CNTY"`).
        expected: [u8; 4],
        /// Observed magic bytes.
        actual: [u8; 4],
    },

    /// Wire protocol version is unsupported by this build.
    #[error("unsupported protocol version: {version} (expected {supported})")]
    UnsupportedVersion {
        /// Version byte read from the frame header.
        version: u8,
        /// Version supported by this library.
        supported: u8,
    },

    /// Unrecognized control packet type discriminant.
    #[error("unknown packet type 0x{packet_type:02X} on stream {stream_id}")]
    UnknownPacketType {
        /// Raw packet type byte from offset 5.
        packet_type: u8,
        /// Multiplexed stream identifier from offsets 8..12.
        stream_id: u32,
    },

    /// Frame payload was shorter than declared in the header.
    #[error(
        "truncated payload for packet 0x{packet_type:02X}: expected {expected} bytes, got {actual}"
    )]
    TruncatedPayload {
        /// Packet type discriminant.
        packet_type: u8,
        /// Expected byte length from header or field prefix.
        expected: usize,
        /// Actual remaining byte count.
        actual: usize,
    },

    /// Declared payload length exceeds safety limits for control frames.
    #[error(
        "payload too large for packet 0x{packet_type:02X}: length {length} exceeds max {max}"
    )]
    PayloadTooLarge {
        /// Packet type discriminant.
        packet_type: u8,
        /// Declared payload byte length.
        length: usize,
        /// Maximum allowed payload byte length.
        max: usize,
    },

    /// CRC32 / AEAD integrity tag check failed over header + payload.
    #[error(
        "integrity tag mismatch for packet 0x{packet_type:02X} on stream {stream_id}: expected 0x{expected_tag:08X}, got 0x{actual_tag:08X}"
    )]
    IntegrityMismatch {
        /// Packet type discriminant.
        packet_type: u8,
        /// Stream identifier.
        stream_id: u32,
        /// Tag stored in the frame header.
        expected_tag: u32,
        /// Tag computed over the header and payload bytes.
        actual_tag: u32,
    },

    /// A structured binary field inside a packet payload was truncated or invalid.
    #[error(
        "malformed field '{field}' in packet 0x{packet_type:02X}: expected {expected} bytes, got {actual}"
    )]
    MalformedField {
        /// Packet type discriminant.
        packet_type: u8,
        /// Name of the field being decoded.
        field: &'static str,
        /// Expected minimum or exact byte length for the field.
        expected: usize,
        /// Actual remaining or provided byte length.
        actual: usize,
    },

    /// A string field inside a packet contained invalid UTF-8 bytes.
    #[error("invalid UTF-8 in field '{field}' of packet 0x{packet_type:02X}")]
    InvalidUtf8 {
        /// Packet type discriminant.
        packet_type: u8,
        /// Name of the string field.
        field: &'static str,
    },

    /// An enumeration discriminant inside a payload had an unrecognized value.
    #[error(
        "invalid enum value 0x{raw_value:02X} for field '{field}' in packet 0x{packet_type:02X}"
    )]
    InvalidEnumValue {
        /// Packet type discriminant.
        packet_type: u8,
        /// Field name.
        field: &'static str,
        /// Raw byte value encountered.
        raw_value: u8,
    },

    /// QR-code or URI pairing string failed syntax or parameter validation.
    #[error("invalid pairing URI: {reason}")]
    InvalidPairingUri {
        /// Human-readable diagnostic explaining which token failed validation.
        reason: String,
    },

    /// Peer TLS certificate SHA-256 fingerprint did not match the pinned or QR-announced value.
    #[error("certificate SHA-256 fingerprint mismatch: expected {expected_hex}, got {actual_hex}")]
    CertificateFingerprintMismatch {
        /// Expected lowercase hex SHA-256 fingerprint.
        expected_hex: String,
        /// Actual lowercase hex SHA-256 fingerprint.
        actual_hex: String,
    },

    /// Pairing state machine transition was invoked from an invalid state.
    #[error("invalid pairing state transition from '{from}' via action '{action}'")]
    InvalidPairingTransition {
        /// Current state name.
        from: &'static str,
        /// Action attempted.
        action: &'static str,
    },

    /// Pairing token or handshake challenge expired.
    #[error("pairing token expired at {expires_at_secs} (current time {now_secs})")]
    PairingExpired {
        /// Expiration timestamp in Unix seconds.
        expires_at_secs: u64,
        /// Current timestamp in Unix seconds.
        now_secs: u64,
    },
}

/// Convenience result alias for `continuity-proto`.
pub type ProtoResult<T> = Result<T, ProtoError>;
