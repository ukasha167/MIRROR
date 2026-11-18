//! Pure-Rust Async MTP Initiator Engine, 12-Byte Container Codec, and Pipelined Bulk Planner.
//!
//! Implements the USB-IF Still Image / Media Transfer Protocol (MTP) 12-byte bulk container
//! header codec (including `GetPartialObject64` `0x95C1` for >4 GB files), single-session
//! `DEVICE_BUSY` (`0x2019`) protection, per-vendor stabilization quirk profiles (Xiaomi,
//! OnePlus, Samsung, Pixel), and the pipelined USB bulk URB queue planner.

use crate::error::{Result, UsbError, MTP_RESPONSE_DEVICE_BUSY, MTP_RESPONSE_OK};

/// Fixed byte length of an MTP bulk container header.
pub const MTP_HEADER_LEN: usize = 12;

/// 16-bit MTP container type field values.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u16)]
pub enum MtpContainerType {
    /// Command block (`0x0001`).
    Command = 0x0001,
    /// Data block (`0x0002`).
    Data = 0x0002,
    /// Response block (`0x0003`).
    Response = 0x0003,
    /// Asynchronous event block (`0x0004`).
    Event = 0x0004,
}

impl MtpContainerType {
    /// Parse a raw 16-bit little-endian MTP container type.
    pub const fn from_raw(raw: u16, actual_len: usize) -> Result<Self> {
        match raw {
            0x0001 => Ok(Self::Command),
            0x0002 => Ok(Self::Data),
            0x0003 => Ok(Self::Response),
            0x0004 => Ok(Self::Event),
            _ => Err(UsbError::MtpInvalidContainerType {
                raw_type: raw,
                expected_len: MTP_HEADER_LEN,
                actual_len,
            }),
        }
    }
}

/// Standard and Android-extended 16-bit MTP operation codes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u16)]
pub enum MtpOperationCode {
    /// `OpenSession` (`0x1002`).
    OpenSession = 0x1002,
    /// `GetStorageIDs` (`0x1004`).
    GetStorageIDs = 0x1004,
    /// `GetObjectHandles` (`0x1007`).
    GetObjectHandles = 0x1007,
    /// `GetObjectInfo` (`0x1008`).
    GetObjectInfo = 0x1008,
    /// `GetObject` (`0x1009`).
    GetObject = 0x1009,
    /// `SendObjectInfo` (`0x100C`).
    SendObjectInfo = 0x100C,
    /// `SendObject` (`0x100D`).
    SendObject = 0x100D,
    /// `GetPartialObject64` (`0x95C1`, Android extension for >4 GiB file reads).
    GetPartialObject64 = 0x95C1,
}

/// Parsed 12-byte MTP USB bulk container header.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct MtpContainerHeader {
    pub length: u32,
    pub container_type: MtpContainerType,
    pub code: u16,
    pub transaction_id: u32,
}

impl MtpContainerHeader {
    /// Create a new 12-byte MTP container header.
    pub const fn new(
        payload_len: usize,
        container_type: MtpContainerType,
        code: u16,
        transaction_id: u32,
    ) -> Self {
        Self {
            length: (MTP_HEADER_LEN + payload_len) as u32,
            container_type,
            code,
            transaction_id,
        }
    }

    /// Serialize this header into its 12-byte little-endian wire layout.
    pub fn to_bytes(&self) -> [u8; MTP_HEADER_LEN] {
        let mut out = [0u8; MTP_HEADER_LEN];
        out[0..4].copy_from_slice(&self.length.to_le_bytes());
        out[4..6].copy_from_slice(&(self.container_type as u16).to_le_bytes());
        out[6..8].copy_from_slice(&self.code.to_le_bytes());
        out[8..12].copy_from_slice(&self.transaction_id.to_le_bytes());
        out
    }

    /// Parse a 12-byte MTP bulk container header.
    ///
    /// ### Binary Header Layout (12 bytes, Little-Endian, USB Still Image / MTP 1.1 Spec)
    /// | Byte Offset | Type | Field | Description |
    /// | :--- | :--- | :--- | :--- |
    /// | `0..4` | `u32` (LE) | `length` | Total container byte length including this 12-byte header (`>= 12`) |
    /// | `4..6` | `u16` (LE) | `container_type` | `1` = Command, `2` = Data, `3` = Response, `4` = Event |
    /// | `6..8` | `u16` (LE) | `code` | Operation code (`0x1002`..`0x95C1`) or Response code (`0x2001` OK, `0x2019` Busy) |
    /// | `8..12` | `u32` (LE) | `transaction_id` | Monotonically increasing session transaction identifier |
    pub fn from_bytes(bytes: &[u8]) -> Result<Self> {
        if bytes.len() < MTP_HEADER_LEN {
            return Err(UsbError::TruncatedPacket {
                packet_type: "MtpContainerHeader",
                expected_len: MTP_HEADER_LEN,
                actual_len: bytes.len(),
            });
        }

        let length = u32::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]);
        if (length as usize) < MTP_HEADER_LEN {
            return Err(UsbError::TruncatedPacket {
                packet_type: "MtpContainerLengthField",
                expected_len: MTP_HEADER_LEN,
                actual_len: length as usize,
            });
        }

        let raw_type = u16::from_le_bytes([bytes[4], bytes[5]]);
        let container_type = MtpContainerType::from_raw(raw_type, bytes.len())?;
        let code = u16::from_le_bytes([bytes[6], bytes[7]]);
        let transaction_id = u32::from_le_bytes([bytes[8], bytes[9], bytes[10], bytes[11]]);

        Ok(Self {
            length,
            container_type,
            code,
            transaction_id,
        })
    }

    /// Check a parsed `Response` container header and translate `0x2019` into [`UsbError::MtpDeviceBusy`].
    pub fn check_response(&self) -> Result<()> {
        if self.container_type == MtpContainerType::Response {
            if self.code == MTP_RESPONSE_OK {
                return Ok(());
            }
            if self.code == MTP_RESPONSE_DEVICE_BUSY {
                return Err(UsbError::MtpDeviceBusy {
                    transaction_id: self.transaction_id,
                    response_code: self.code,
                });
            }
            return Err(UsbError::MtpUnexpectedResponse {
                transaction_id: self.transaction_id,
                response_code: self.code,
            });
        }
        Ok(())
    }
}

/// Encode a complete MTP command container with up to 5 `u32` operation parameters.
pub fn encode_mtp_command(
    op: MtpOperationCode,
    transaction_id: u32,
    params: &[u32],
) -> Vec<u8> {
    let payload_len = params.len() * 4;
    let header = MtpContainerHeader::new(
        payload_len,
        MtpContainerType::Command,
        op as u16,
        transaction_id,
    );
    let mut buf = Vec::with_capacity(MTP_HEADER_LEN + payload_len);
    buf.extend_from_slice(&header.to_bytes());
    for &param in params {
        buf.extend_from_slice(&param.to_le_bytes());
    }
    buf
}

/// Encode an Android `GetPartialObject64` (`0x95C1`) command supporting >4 GiB file offsets.
pub fn encode_get_partial_object64(
    transaction_id: u32,
    object_handle: u32,
    offset_64: u64,
    max_bytes: u32,
) -> Vec<u8> {
    let offset_lo = (offset_64 & 0xFFFF_FFFF) as u32;
    let offset_hi = (offset_64 >> 32) as u32;
    encode_mtp_command(
        MtpOperationCode::GetPartialObject64,
        transaction_id,
        &[object_handle, offset_lo, offset_hi, max_bytes],
    )
}

/// Android OEM vendor identifier for MTP quirk tuning.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MtpVendor {
    Xiaomi,
    OnePlus,
    Samsung,
    Pixel,
    Generic,
}

/// Per-vendor USB MTP stabilization and bulk pipeline profile.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct MtpVendorQuirkProfile {
    pub vendor: MtpVendor,
    /// Mandatory post-enumeration or post-session delay before firing pipelined bulk URBs.
    pub stabilization_delay_ms: u32,
    /// Maximum size of a single USB bulk URB transfer in bytes.
    pub max_bulk_transfer_size: usize,
    /// Number of asynchronous USB bulk URBs queued back-to-back within a single data phase.
    pub urb_pipeline_depth: usize,
    /// Whether zero-length packet (ZLP) termination is required on max-packet boundaries.
    pub requires_zlp_on_boundary: bool,
}

impl MtpVendorQuirkProfile {
    /// Look up the stabilization and bulk-queue quirk profile for a USB `vendor_id`.
    pub const fn for_vendor_id(vendor_id: u16) -> Self {
        match vendor_id {
            // Xiaomi (0x2717): requires 350ms gadget stabilization delay and 512 KiB URBs
            0x2717 => Self {
                vendor: MtpVendor::Xiaomi,
                stabilization_delay_ms: 350,
                max_bulk_transfer_size: 512 * 1024,
                urb_pipeline_depth: 4,
                requires_zlp_on_boundary: true,
            },
            // OnePlus / OPPO (0x2A70 / 0x22D9): requires 250ms stabilization delay and 512 KiB URBs
            0x2A70 | 0x22D9 => Self {
                vendor: MtpVendor::OnePlus,
                stabilization_delay_ms: 250,
                max_bulk_transfer_size: 512 * 1024,
                urb_pipeline_depth: 4,
                requires_zlp_on_boundary: true,
            },
            // Samsung (0x04E8): 100ms stabilization delay and 1 MiB URBs with depth 8
            0x04E8 => Self {
                vendor: MtpVendor::Samsung,
                stabilization_delay_ms: 100,
                max_bulk_transfer_size: 1024 * 1024,
                urb_pipeline_depth: 8,
                requires_zlp_on_boundary: true,
            },
            // Google Pixel (0x18D1): fast 20ms stabilization and 1 MiB URBs with depth 8
            0x18D1 => Self {
                vendor: MtpVendor::Pixel,
                stabilization_delay_ms: 20,
                max_bulk_transfer_size: 1024 * 1024,
                urb_pipeline_depth: 8,
                requires_zlp_on_boundary: false,
            },
            _ => Self {
                vendor: MtpVendor::Generic,
                stabilization_delay_ms: 150,
                max_bulk_transfer_size: 512 * 1024,
                urb_pipeline_depth: 4,
                requires_zlp_on_boundary: true,
            },
        }
    }
}

/// Planned USB bulk URB descriptor within a pipelined MTP data phase.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PlannedBulkUrb {
    pub batch_index: usize,
    pub urb_index_in_batch: usize,
    pub file_offset: u64,
    pub transfer_bytes: usize,
}

/// Planner that slices large file transfers (including >4 GiB files) into pipelined
/// USB bulk URB batches according to the active [`MtpVendorQuirkProfile`].
#[derive(Debug, Clone)]
pub struct MtpBulkPipelinePlanner {
    profile: MtpVendorQuirkProfile,
}

impl MtpBulkPipelinePlanner {
    /// Create a pipeline planner for `profile`.
    pub const fn new(profile: MtpVendorQuirkProfile) -> Self {
        Self { profile }
    }

    /// Return the active vendor quirk profile.
    pub const fn profile(&self) -> MtpVendorQuirkProfile {
        self.profile
    }

    /// Plan back-to-back pipelined USB bulk URBs for a data transfer of `total_bytes`
    /// starting at `base_offset` (supports 64-bit offsets >4 GiB).
    pub fn plan_urb_queue(&self, base_offset: u64, total_bytes: u64) -> Vec<PlannedBulkUrb> {
        if total_bytes == 0 {
            return Vec::new();
        }
        let max_urb = self.profile.max_bulk_transfer_size as u64;
        let depth = self.profile.urb_pipeline_depth.max(1);
        let total_urbs = total_bytes.div_ceil(max_urb) as usize;
        let mut plan = Vec::with_capacity(total_urbs);

        let mut remaining = total_bytes;
        let mut current_offset = base_offset;
        let mut urb_idx = 0usize;

        while remaining > 0 {
            let chunk = remaining.min(max_urb) as usize;
            plan.push(PlannedBulkUrb {
                batch_index: urb_idx / depth,
                urb_index_in_batch: urb_idx % depth,
                file_offset: current_offset,
                transfer_bytes: chunk,
            });
            remaining -= chunk as u64;
            current_offset += chunk as u64;
            urb_idx += 1;
        }

        plan
    }
}
