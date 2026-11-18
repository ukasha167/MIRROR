//! Pure-Rust ADB Wire Protocol, Burst Mode ASB Window Controller, and Sync v2 Engine.
//!
//! Implements the 24-byte ADB message framing (`A_CNXN`, `A_AUTH`, `A_OPEN`, `A_OKAY`,
//! `A_WRTE`, `A_CLSE`), the `ADB_BURST_MODE` sliding Available Send Bytes (ASB) controller,
//! and the 8-channel multiplexed `sync:` v2 protocol (`STA2`, `LIS2`, `SND2`, `RCV2`,
//! `DATA`, `DONE`) with in-flight LZ4 block compression (`lz4_flex` block format).

use crate::error::{Result, UsbError};
pub use crate::lz4::{lz4_compress_block, lz4_decompress_block};

/// Fixed size of an ADB wire protocol header in bytes.
pub const ADB_HEADER_LEN: usize = 24;
/// Maximum ADB payload size negotiated on modern USB 3.x hosts (1 MiB).
pub const ADB_MAX_DATA: u32 = 1024 * 1024;
/// Default `ADB_BURST_MODE` Available Send Bytes (ASB) window size (4 MiB).
pub const ADB_DEFAULT_BURST_WINDOW: u32 = 4 * 1024 * 1024;
/// Maximum concurrent `sync:` streams scheduled in parallel over a single ADB USB connection.
pub const ADB_PARALLEL_SYNC_CHANNELS: usize = 8;
/// Sync v2 flag bit indicating in-flight LZ4 block compression (`kSyncFlagLz4 = 2`).
pub const ADB_SYNC_FLAG_LZ4: u32 = 0x0000_0002;

/// 32-bit little-endian command identifiers in the 24-byte ADB header.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u32)]
pub enum AdbCommand {
    Cnxn = 0x4e58_4e43,
    Auth = 0x4854_5541,
    Open = 0x4e45_504f,
    Okay = 0x5941_4b4f,
    Wrte = 0x4554_5257,
    Clse = 0x4553_4c43,
}

impl AdbCommand {
    /// Convert a raw 32-bit little-endian command code into an [`AdbCommand`].
    pub const fn from_raw(raw: u32) -> Result<Self> {
        match raw {
            0x4e58_4e43 => Ok(Self::Cnxn),
            0x4854_5541 => Ok(Self::Auth),
            0x4e45_504f => Ok(Self::Open),
            0x5941_4b4f => Ok(Self::Okay),
            0x4554_5257 => Ok(Self::Wrte),
            0x4553_4c43 => Ok(Self::Clse),
            _ => Err(UsbError::AdbUnknownCommand { raw_command: raw }),
        }
    }

    /// Compute the ADB header `magic` field (`command ^ 0xFFFF_FFFF`).
    pub const fn magic(self) -> u32 {
        (self as u32) ^ 0xFFFF_FFFF
    }
}

/// Compute the ADB payload checksum (`data_crc32` in AOSP `amessage`, defined as
/// the 32-bit wrapping sum of all payload bytes).
pub fn compute_adb_checksum(payload: &[u8]) -> u32 {
    payload.iter().fold(0u32, |acc, &b| acc.wrapping_add(u32::from(b)))
}

/// Parsed 24-byte ADB wire message header.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct AdbHeader {
    pub command: AdbCommand,
    pub arg0: u32,
    pub arg1: u32,
    pub data_length: u32,
    pub data_crc32: u32,
    pub magic: u32,
}

impl AdbHeader {
    /// Construct a valid 24-byte ADB header for `command`, arguments, and `payload`.
    pub fn new(command: AdbCommand, arg0: u32, arg1: u32, payload: &[u8]) -> Self {
        Self {
            command,
            arg0,
            arg1,
            data_length: payload.len() as u32,
            data_crc32: compute_adb_checksum(payload),
            magic: command.magic(),
        }
    }

    /// Encode this header into its 24-byte little-endian wire representation.
    pub fn to_bytes(&self) -> [u8; ADB_HEADER_LEN] {
        let mut out = [0u8; ADB_HEADER_LEN];
        out[0..4].copy_from_slice(&(self.command as u32).to_le_bytes());
        out[4..8].copy_from_slice(&self.arg0.to_le_bytes());
        out[8..12].copy_from_slice(&self.arg1.to_le_bytes());
        out[12..16].copy_from_slice(&self.data_length.to_le_bytes());
        out[16..20].copy_from_slice(&self.data_crc32.to_le_bytes());
        out[20..24].copy_from_slice(&self.magic.to_le_bytes());
        out
    }

    /// Parse and validate a 24-byte ADB wire protocol header.
    ///
    /// ### Binary Header Layout (24 bytes, Little-Endian, AOSP `transport.h` `struct amessage`)
    /// | Byte Offset | Type | Field | Description |
    /// | :--- | :--- | :--- | :--- |
    /// | `0..4` | `u32` (LE) | `command` | Command identifier (`A_CNXN`, `A_AUTH`, `A_OPEN`, `A_OKAY`, `A_WRTE`, `A_CLSE`) |
    /// | `4..8` | `u32` (LE) | `arg0` | First argument (`version` for `CNXN`, `local_id` for stream ops) |
    /// | `8..12` | `u32` (LE) | `arg1` | Second argument (`maxdata` for `CNXN`, `remote_id` or Burst ASB ack) |
    /// | `12..16` | `u32` (LE) | `data_length` | Length of following payload in bytes (`0..=ADB_MAX_DATA`) |
    /// | `16..20` | `u32` (LE) | `data_crc32` | 32-bit wrapping byte sum of payload bytes |
    /// | `20..24` | `u32` (LE) | `magic` | Bitwise inverse of command (`command ^ 0xFFFF_FFFF`) |
    pub fn from_bytes(bytes: &[u8]) -> Result<Self> {
        if bytes.len() < ADB_HEADER_LEN {
            return Err(UsbError::TruncatedPacket {
                packet_type: "AdbHeader",
                expected_len: ADB_HEADER_LEN,
                actual_len: bytes.len(),
            });
        }
        let raw_command = u32::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]);
        let arg0 = u32::from_le_bytes([bytes[4], bytes[5], bytes[6], bytes[7]]);
        let arg1 = u32::from_le_bytes([bytes[8], bytes[9], bytes[10], bytes[11]]);
        let data_length = u32::from_le_bytes([bytes[12], bytes[13], bytes[14], bytes[15]]);
        let data_crc32 = u32::from_le_bytes([bytes[16], bytes[17], bytes[18], bytes[19]]);
        let magic = u32::from_le_bytes([bytes[20], bytes[21], bytes[22], bytes[23]]);

        let expected_magic = raw_command ^ 0xFFFF_FFFF;
        if magic != expected_magic {
            return Err(UsbError::AdbInvalidMagic {
                command: raw_command,
                expected_magic,
                actual_magic: magic,
            });
        }
        Ok(Self {
            command: AdbCommand::from_raw(raw_command)?,
            arg0,
            arg1,
            data_length,
            data_crc32,
            magic,
        })
    }

    /// Validate that `payload` matches both `data_length` and `data_crc32`.
    pub fn validate_payload(&self, payload: &[u8]) -> Result<()> {
        let expected_len = self.data_length as usize;
        if payload.len() != expected_len {
            return Err(UsbError::AdbPayloadLengthMismatch {
                command: self.command as u32,
                expected_len,
                actual_len: payload.len(),
            });
        }
        let actual_crc = compute_adb_checksum(payload);
        if actual_crc != self.data_crc32 {
            return Err(UsbError::AdbChecksumMismatch {
                command: self.command as u32,
                expected_crc32: self.data_crc32,
                actual_crc32: actual_crc,
            });
        }
        Ok(())
    }
}

/// Complete ADB wire packet (24-byte header + variable payload).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AdbPacket {
    pub header: AdbHeader,
    pub payload: Vec<u8>,
}

impl AdbPacket {
    /// Create a new validated ADB packet.
    pub fn new(command: AdbCommand, arg0: u32, arg1: u32, payload: Vec<u8>) -> Self {
        Self { header: AdbHeader::new(command, arg0, arg1, &payload), payload }
    }
}

/// Sliding Available Send Bytes (ASB) window controller for `ADB_BURST_MODE`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AdbBurstWindowController {
    max_window_bytes: u32,
    available_send_bytes: u32,
    in_flight_bytes: u32,
    burst_packets_queued: u64,
}

impl AdbBurstWindowController {
    pub const fn new(max_window_bytes: u32) -> Self {
        Self { max_window_bytes, available_send_bytes: max_window_bytes, in_flight_bytes: 0, burst_packets_queued: 0 }
    }
    pub const fn available_send_bytes(&self) -> u32 { self.available_send_bytes }
    pub const fn in_flight_bytes(&self) -> u32 { self.in_flight_bytes }
    pub const fn burst_packets_queued(&self) -> u64 { self.burst_packets_queued }

    /// Consume `bytes` from the ASB window prior to queueing an `A_WRTE` bulk transfer.
    pub fn consume_send_window(&mut self, bytes: u32) -> Result<()> {
        if bytes > self.available_send_bytes {
            return Err(UsbError::AdbBurstWindowExhausted {
                requested_bytes: bytes,
                available_send_bytes: self.available_send_bytes,
            });
        }
        self.available_send_bytes -= bytes;
        self.in_flight_bytes = self.in_flight_bytes.saturating_add(bytes);
        self.burst_packets_queued += 1;
        Ok(())
    }

    /// Process a delayed `A_OKAY` acknowledgement replenishing `acked_bytes` of ASB credit.
    pub fn on_okay_ack(&mut self, acked_bytes: u32) {
        self.in_flight_bytes = self.in_flight_bytes.saturating_sub(acked_bytes);
        self.available_send_bytes = self.available_send_bytes.saturating_add(acked_bytes).min(self.max_window_bytes);
    }
}

/// 4-byte ASCII subpacket identifiers for ADB Sync v2 (`STA2`, `LIS2`, `SND2`, `RCV2`, `DATA`, `DONE`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AdbSyncId {
    Sta2,
    Lis2,
    Snd2,
    Rcv2,
    Data,
    Done,
    Fail,
}

impl AdbSyncId {
    pub const fn as_bytes(self) -> [u8; 4] {
        match self {
            Self::Sta2 => *b"STA2",
            Self::Lis2 => *b"LIS2",
            Self::Snd2 => *b"SND2",
            Self::Rcv2 => *b"RCV2",
            Self::Data => *b"DATA",
            Self::Done => *b"DONE",
            Self::Fail => *b"FAIL",
        }
    }

    pub const fn from_bytes(raw_id: [u8; 4]) -> Result<Self> {
        match &raw_id {
            b"STA2" => Ok(Self::Sta2),
            b"LIS2" => Ok(Self::Lis2),
            b"SND2" => Ok(Self::Snd2),
            b"RCV2" => Ok(Self::Rcv2),
            b"DATA" => Ok(Self::Data),
            b"DONE" => Ok(Self::Done),
            b"FAIL" => Ok(Self::Fail),
            _ => Err(UsbError::AdbSyncUnknownId { raw_id }),
        }
    }
}

/// Parse an 8-byte ADB Sync v2 subpacket header (`id` + `length_or_arg`).
///
/// ### Binary Header Layout (8 bytes, Little-Endian, AOSP `file_sync_protocol.h`)
/// | Byte Offset | Type | Field | Description |
/// | :--- | :--- | :--- | :--- |
/// | `0..4` | `[u8; 4]` | `id` | 4-byte ASCII request/response ID (`STA2`, `LIS2`, `SND2`, `RCV2`, `DATA`, `DONE`, `FAIL`) |
/// | `4..8` | `u32` (LE) | `arg` | Path length (`STA2`/`LIS2`/`SND2`/`RCV2`), chunk byte size (`DATA`), or mtime (`DONE`) |
pub fn parse_sync_subpacket_header(bytes: &[u8]) -> Result<(AdbSyncId, u32)> {
    if bytes.len() < 8 {
        return Err(UsbError::TruncatedPacket {
            packet_type: "AdbSyncSubpacketHeader",
            expected_len: 8,
            actual_len: bytes.len(),
        });
    }
    Ok((
        AdbSyncId::from_bytes([bytes[0], bytes[1], bytes[2], bytes[3]])?,
        u32::from_le_bytes([bytes[4], bytes[5], bytes[6], bytes[7]]),
    ))
}

/// Encode an 8-byte ADB Sync v2 subpacket header followed by `payload`.
pub fn encode_sync_subpacket(id: AdbSyncId, arg: u32, payload: &[u8]) -> Vec<u8> {
    let mut buf = Vec::with_capacity(8 + payload.len());
    buf.extend_from_slice(&id.as_bytes());
    buf.extend_from_slice(&arg.to_le_bytes());
    buf.extend_from_slice(payload);
    buf
}

/// 8-channel parallel stream scheduler for multiplexed `sync:` v2 file transfers.
#[derive(Debug, Clone)]
pub struct AdbSyncParallelScheduler {
    channel_local_ids: [u32; ADB_PARALLEL_SYNC_CHANNELS],
    assigned_bytes: [u64; ADB_PARALLEL_SYNC_CHANNELS],
}

impl AdbSyncParallelScheduler {
    pub const fn new(base_local_id: u32) -> Self {
        Self {
            channel_local_ids: [
                base_local_id, base_local_id + 1, base_local_id + 2, base_local_id + 3,
                base_local_id + 4, base_local_id + 5, base_local_id + 6, base_local_id + 7,
            ],
            assigned_bytes: [0; ADB_PARALLEL_SYNC_CHANNELS],
        }
    }

    pub fn schedule_file(&mut self, file_size: u64) -> (usize, u32) {
        let mut min_idx = 0usize;
        for idx in 1..ADB_PARALLEL_SYNC_CHANNELS {
            if self.assigned_bytes[idx] < self.assigned_bytes[min_idx] {
                min_idx = idx;
            }
        }
        self.assigned_bytes[min_idx] = self.assigned_bytes[min_idx].saturating_add(file_size);
        (min_idx, self.channel_local_ids[min_idx])
    }

    pub const fn channel_loads(&self) -> &[u64; ADB_PARALLEL_SYNC_CHANNELS] {
        &self.assigned_bytes
    }
}
