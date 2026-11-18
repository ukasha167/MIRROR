//! Typed errors for the `continuity-wireless` crate.
//!
//! Includes explicit protocol context (`packet_type`, `expected_len`, `actual_len`)
//! so test failures and runtime logs pinpoint protocol framing bugs immediately.

use thiserror::Error;

/// Unified error type for wireless discovery, LocalSend v2.1, Fast-Stream, and Quick Share.
#[derive(Debug, Error, Clone, PartialEq, Eq)]
pub enum WirelessError {
    /// Android 17+ (`API 37`) `ACCESS_LOCAL_NETWORK` permission has not been granted.
    #[error("local network permission denied or not yet granted on Android 17+ (state: {state})")]
    LocalNetworkPermissionDenied {
        /// Human-readable state description.
        state: String,
    },

    /// Attempted to send raw UDP multicast while in idle hardware-offloaded mDNS power mode.
    #[error("raw UDP multicast is forbidden in idle power mode ( avoids holding Android MulticastLock)")]
    MulticastForbiddenWhileIdle,

    /// Malformed discovery announcement or mDNS TXT record.
    #[error("invalid discovery descriptor ({protocol}): {reason}")]
    InvalidDiscoveryDescriptor {
        /// Discovery protocol (`localsend-multicast`, `localsend-mdns`, or `quickshare-mdns`).
        protocol: &'static str,
        /// Explanation of what failed validation.
        reason: String,
    },

    /// JSON serialization or deserialization failure in control DTOs.
    #[error("JSON codec error in {context}: {details}")]
    JsonCodec {
        /// Protocol stage or DTO name.
        context: &'static str,
        /// Underlying parser message.
        details: String,
    },

    /// Unsupported or mismatched LocalSend protocol version.
    #[error("unsupported LocalSend protocol version: expected 2.x, got '{version}'")]
    UnsupportedLocalSendVersion {
        /// Version string received from peer.
        version: String,
    },

    /// TLS certificate fingerprint did not match the pinned identity for a paired device,
    /// or an unpinned peer required manual confirmation / PIN.
    #[error("untrusted or unpinned peer certificate fingerprint '{fingerprint}': {reason}")]
    UntrustedPeerFingerprint {
        /// Peer certificate SHA-256 fingerprint.
        fingerprint: String,
        /// Reason auto-accept or verification failed.
        reason: &'static str,
    },

    /// Upload session ID or per-file token was rejected by the LocalSend session state machine.
    #[error("invalid LocalSend upload session '{session_id}' or token for file '{file_id}'")]
    InvalidUploadToken {
        /// Session identifier.
        session_id: String,
        /// File identifier inside the session.
        file_id: String,
    },

    /// Binary packet or frame was shorter or longer than required by its wire specification.
    #[error("wire length mismatch for {packet_type}: expected at least {expected_len} bytes, got {actual_len} bytes")]
    WireLengthMismatch {
        /// Name of the binary frame or header being parsed.
        packet_type: &'static str,
        /// Minimum or exact expected byte count.
        expected_len: usize,
        /// Actual byte count available.
        actual_len: usize,
    },

    /// Binary magic bytes or version tag did not match the wire format specification.
    #[error("invalid wire header in {packet_type} at byte offset {offset}: {details}")]
    InvalidWireHeader {
        /// Name of the binary frame or header.
        packet_type: &'static str,
        /// Byte offset where validation failed.
        offset: usize,
        /// Detailed diagnostic string.
        details: String,
    },

    /// Parallel stream lane index exceeded the negotiated lane count (`0..4`).
    #[error("parallel stream lane index {stream_index} out of bounds (max lanes: {max_lanes})")]
    StreamIndexOutOfBounds {
        /// Stream lane index from frame header.
        stream_index: u8,
        /// Negotiated parallel lane count.
        max_lanes: usize,
    },

    /// SHA-256 integrity check failed after receiving a large file or unpacking a tar entry.
    #[error("SHA-256 checksum mismatch for file '{file_id}': expected {expected_sha256}, got {actual_sha256}")]
    ChecksumMismatch {
        /// Identifier or path of the corrupted file.
        file_id: String,
        /// Lowercase hex expected SHA-256 digest.
        expected_sha256: String,
        /// Lowercase hex actual SHA-256 digest computed from payload bytes.
        actual_sha256: String,
    },

    /// Quick Share UKEY2 state machine received an out-of-order message.
    #[error("invalid Quick Share UKEY2 transition: cannot process '{message_type}' while in state '{current_state}'")]
    InvalidUkey2State {
        /// Current handshake state name.
        current_state: &'static str,
        /// Incoming message type description.
        message_type: &'static str,
    },

    /// Quick Share D2D encrypted frame failed authentication tag or sequence verification.
    #[error("Quick Share frame authentication failed at sequence {sequence}: {reason}")]
    QuickShareAuthFailure {
        /// Frame sequence number.
        sequence: u64,
        /// Verification failure reason.
        reason: &'static str,
    },

    /// Quick Share payload reassembly encountered an unknown payload ID, bad offset, or size mismatch.
    #[error("Quick Share payload reassembly error for payload {payload_id} ({packet_type}): expected {expected_len} bytes, got {actual_len} bytes")]
    PayloadReassemblyError {
        /// Numeric payload ID assigned by sender.
        payload_id: i64,
        /// Frame stage (`DataChunk` or `FinalVerify`).
        packet_type: &'static str,
        /// Expected byte offset or total size.
        expected_len: usize,
        /// Actual byte offset or accumulated size.
        actual_len: usize,
    },
}

/// Convenience result alias for `continuity-wireless`.
pub type Result<T> = std::result::Result<T, WirelessError>;
