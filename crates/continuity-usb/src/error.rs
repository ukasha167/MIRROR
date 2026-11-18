//! Typed error definitions for the 3-tier wired USB transfer engine.
//!
//! All wire protocol parsers and USB transport operations return [`UsbError`]
//! with contextual fields (packet type, expected length, actual length, magic,
//! checksums, and MTP response codes) so protocol issues are self-diagnosing.

use thiserror::Error;

/// MTP response code for `Device_Busy` (`0x2019`), returned by Android's
/// single-session `MtpServer` when overlapping transactions arrive.
pub const MTP_RESPONSE_DEVICE_BUSY: u16 = 0x2019;

/// MTP response code for `OK` (`0x2001`).
pub const MTP_RESPONSE_OK: u16 = 0x2001;

/// Unified error type for USB interface classification, ADB Burst/Sync v2,
/// LZ4 block framing, and pipelined MTP transfers.
#[derive(Debug, Error, Clone, PartialEq, Eq)]
pub enum UsbError {
    /// A wire header or payload buffer was shorter than required.
    #[error("{packet_type} truncated: expected at least {expected_len} bytes, got {actual_len} bytes")]
    TruncatedPacket {
        packet_type: &'static str,
        expected_len: usize,
        actual_len: usize,
    },

    /// ADB 24-byte header `magic` field did not equal `command ^ 0xFFFF_FFFF`.
    #[error("ADB invalid header magic for command 0x{command:08x}: expected 0x{expected_magic:08x}, got 0x{actual_magic:08x}")]
    AdbInvalidMagic {
        command: u32,
        expected_magic: u32,
        actual_magic: u32,
    },

    /// ADB 24-byte header contained an unrecognized command identifier.
    #[error("ADB unknown command identifier: 0x{raw_command:08x}")]
    AdbUnknownCommand { raw_command: u32 },

    /// ADB payload checksum (`data_crc32`) did not match computed payload checksum.
    #[error("ADB checksum mismatch for command 0x{command:08x}: expected 0x{expected_crc32:08x}, got 0x{actual_crc32:08x}")]
    AdbChecksumMismatch {
        command: u32,
        expected_crc32: u32,
        actual_crc32: u32,
    },

    /// ADB payload length did not match header `data_length` or exceeded max payload limit.
    #[error("ADB payload length mismatch for command 0x{command:08x}: expected {expected_len} bytes, got {actual_len} bytes")]
    AdbPayloadLengthMismatch {
        command: u32,
        expected_len: usize,
        actual_len: usize,
    },

    /// Attempted to transmit more bytes than permitted by the ADB Burst Mode ASB window.
    #[error("ADB burst mode Available Send Bytes (ASB) window exhausted: requested {requested_bytes} bytes, available {available_send_bytes} bytes")]
    AdbBurstWindowExhausted {
        requested_bytes: u32,
        available_send_bytes: u32,
    },

    /// Unrecognized 4-byte ADB Sync v2 subpacket ID.
    #[error("ADB Sync v2 unknown subpacket ID: {raw_id:?}")]
    AdbSyncUnknownId { raw_id: [u8; 4] },

    /// Remote ADB Sync daemon returned a `FAIL` subpacket.
    #[error("ADB Sync v2 remote failure: {message}")]
    AdbSyncRemoteFail { message: String },

    /// In-flight LZ4 block compression or decompression framing error.
    #[error("LZ4 frame error ({reason}) at byte offset {offset}: expected {expected_len} bytes, actual {actual_len} bytes")]
    Lz4FrameError {
        reason: &'static str,
        offset: usize,
        expected_len: usize,
        actual_len: usize,
    },

    /// Android `MtpServer` returned `DEVICE_BUSY` (`0x2019`) due to concurrent session access.
    #[error("MTP device busy (0x{response_code:04x}) on transaction {transaction_id}: single-session protocol violation")]
    MtpDeviceBusy {
        transaction_id: u32,
        response_code: u16,
    },

    /// Invalid or unsupported 16-bit MTP container type.
    #[error("MTP invalid container type 0x{raw_type:04x} (expected length {expected_len}, actual {actual_len})")]
    MtpInvalidContainerType {
        raw_type: u16,
        expected_len: usize,
        actual_len: usize,
    },

    /// Non-OK MTP response code other than `DEVICE_BUSY`.
    #[error("MTP unexpected response code 0x{response_code:04x} on transaction {transaction_id}")]
    MtpUnexpectedResponse {
        transaction_id: u32,
        response_code: u16,
    },

    /// USB bulk endpoint stalled (`EPIPE` / halt condition) during transfer.
    #[error("USB bulk endpoint 0x{endpoint:02x} stalled after {transferred} of {expected_len} bytes")]
    UsbBulkStall {
        endpoint: u8,
        transferred: usize,
        expected_len: usize,
    },

    /// Physical or mock USB device disconnected mid-transfer.
    #[error("USB device disconnected during bulk transfer")]
    UsbDisconnected,

    /// No CDC-NCM, ADB, or MTP/PTP USB interface found on the inspected device.
    #[error("No supported Continuity USB interface (CDC-NCM, ADB, or MTP) on device {vendor_id:04x}:{product_id:04x}")]
    NoSupportedInterface { vendor_id: u16, product_id: u16 },
}

/// Convenience result alias for `continuity-usb`.
pub type Result<T> = std::result::Result<T, UsbError>;
