//! `continuity-usb`: 3-Tier Wired High-Speed Transfer Engine for Android ↔ macOS Continuity.
//!
//! Automatically classifies connected Android USB interfaces into:
//! - **Tier 1A (`CDC-NCM` `0x02/0x0D`)**: Native macOS `AppleUserECM` virtual Ethernet (200–350+ MB/s).
//! - **Tier 1B (`ADB` `0xFF/0x42/0x01`)**: Pure-Rust ADB Burst Mode + 8-channel Sync v2 with LZ4 compression (150–250+ MB/s).
//! - **Tier 2 (`MTP` `0x06/0x01/0x01`)**: Pure-Rust pipelined MTP initiator with >4 GiB `GetPartialObject64` and vendor quirk profiles (40–120 MB/s).

pub mod adb;
pub mod classifier;
pub mod error;
pub mod lz4;
pub mod mtp;
pub mod transport;

pub use adb::{
    AdbBurstWindowController, AdbCommand, AdbHeader, AdbPacket, AdbSyncId,
    AdbSyncParallelScheduler, ADB_DEFAULT_BURST_WINDOW, ADB_HEADER_LEN, ADB_MAX_DATA,
    ADB_PARALLEL_SYNC_CHANNELS, ADB_SYNC_FLAG_LZ4,
};
pub use classifier::{
    classify_usb_device, ClassifiedUsbPath, UsbDeviceDescriptor, UsbInterfaceDescriptor,
    WiredTransferTier,
};
pub use error::{Result, UsbError, MTP_RESPONSE_DEVICE_BUSY, MTP_RESPONSE_OK};
pub use mtp::{
    encode_get_partial_object64, encode_mtp_command, MtpBulkPipelinePlanner, MtpContainerHeader,
    MtpContainerType, MtpOperationCode, MtpVendor, MtpVendorQuirkProfile, PlannedBulkUrb,
    MTP_HEADER_LEN,
};
pub use transport::{
    block_on_usb, send_adb_sync_v2_lz4_stream, BoxUsbFuture, InMemoryUsbDevice, UsbBulkTransport,
};

#[cfg(test)]
mod tests {
    use super::*;
    use crate::adb::{lz4_compress_block, lz4_decompress_block, parse_sync_subpacket_header};

    #[test]
    fn adb_header_validates_all_six_commands_and_magic_errors() -> Result<()> {
        let commands = [
            AdbCommand::Cnxn,
            AdbCommand::Auth,
            AdbCommand::Open,
            AdbCommand::Okay,
            AdbCommand::Wrte,
            AdbCommand::Clse,
        ];
        for cmd in commands {
            let payload = b"sync:\0";
            let hdr = AdbHeader::new(cmd, 1, 2, payload);
            let raw = hdr.to_bytes();
            let decoded = AdbHeader::from_bytes(&raw)?;
            assert_eq!(decoded, hdr);
            decoded.validate_payload(payload)?;
        }

        // Corrupt magic field
        let mut bad_magic = AdbHeader::new(AdbCommand::Cnxn, 1, 1024, b"host::").to_bytes();
        bad_magic[20] ^= 0xFF;
        assert!(matches!(
            AdbHeader::from_bytes(&bad_magic),
            Err(UsbError::AdbInvalidMagic { .. })
        ));

        // Corrupt payload checksum
        let hdr = AdbHeader::new(AdbCommand::Wrte, 1, 2, b"ABCD");
        assert!(matches!(
            hdr.validate_payload(b"ABCE"),
            Err(UsbError::AdbChecksumMismatch { .. })
        ));
        Ok(())
    }

    #[test]
    fn adb_sync_v2_subpackets_and_lz4_error_handling() -> Result<()> {
        for id in [
            AdbSyncId::Sta2,
            AdbSyncId::Lis2,
            AdbSyncId::Snd2,
            AdbSyncId::Rcv2,
            AdbSyncId::Data,
            AdbSyncId::Done,
        ] {
            let encoded = adb::encode_sync_subpacket(id, 64, b"payload");
            let (parsed_id, parsed_arg) = parse_sync_subpacket_header(&encoded)?;
            assert_eq!(parsed_id, id);
            assert_eq!(parsed_arg, 64);
        }

        let input = vec![0x5Au8; 4096];
        let compressed = lz4_compress_block(&input);
        assert!(compressed.len() < input.len() / 8);
        let decompressed = lz4_decompress_block(&compressed, 4096)?;
        assert_eq!(decompressed, input);

        // Corrupt LZ4 offset (0x0000 is illegal in LZ4)
        let bad_lz4 = [0x14u8, b'A', 0x00, 0x00];
        assert!(matches!(
            lz4_decompress_block(&bad_lz4, 1024),
            Err(UsbError::Lz4FrameError { .. })
        ));
        Ok(())
    }

    #[test]
    fn mtp_all_operations_and_vendor_quirks() -> Result<()> {
        let ops = [
            MtpOperationCode::OpenSession,
            MtpOperationCode::GetStorageIDs,
            MtpOperationCode::GetObjectHandles,
            MtpOperationCode::GetObjectInfo,
            MtpOperationCode::GetObject,
            MtpOperationCode::SendObjectInfo,
            MtpOperationCode::SendObject,
            MtpOperationCode::GetPartialObject64,
        ];
        for (idx, op) in ops.iter().enumerate() {
            let raw = encode_mtp_command(*op, (idx + 1) as u32, &[1, 2]);
            let hdr = MtpContainerHeader::from_bytes(&raw)?;
            assert_eq!(hdr.container_type, MtpContainerType::Command);
            assert_eq!(hdr.code, *op as u16);
            assert_eq!(hdr.length, 20);
        }

        let oneplus = MtpVendorQuirkProfile::for_vendor_id(0x2A70);
        assert_eq!(oneplus.vendor, MtpVendor::OnePlus);
        assert_eq!(oneplus.stabilization_delay_ms, 250);

        let samsung = MtpVendorQuirkProfile::for_vendor_id(0x04E8);
        assert_eq!(samsung.vendor, MtpVendor::Samsung);
        assert_eq!(samsung.urb_pipeline_depth, 8);
        Ok(())
    }
}
