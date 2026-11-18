//! 3-Tier USB Interface Classifier for automatic high-speed path selection.
//!
//! Inspects USB device and interface descriptors to pick the highest-throughput
//! transport tier without user intervention:
//! - **Tier 1A (`CdcNcm`)**: USB CDC-NCM (`0x02/0x0D`) Virtual Ethernet over macOS `AppleUserECM` (200–350+ MB/s, 4–8 parallel TCP streams).
//! - **Tier 1B (`AdbMultiplex`)**: ADB USB Interface (`0xFF/0x42/0x01`) with Burst Mode + Sync v2 LZ4 (150–250+ MB/s, 8 parallel channels).
//! - **Tier 2 (`MtpPipelined`)**: Standard MTP/PTP (`0x06/0x01/0x01` or Android `"MTP"` string descriptor) with pipelined USB bulk URBs (40–120 MB/s, 1 session).

use crate::error::{Result, UsbError};

/// Standard USB Interface Descriptor size in bytes.
pub const USB_INTERFACE_DESCRIPTOR_LEN: usize = 9;
/// USB Descriptor Type constant for an Interface Descriptor (`0x04`).
pub const USB_DT_INTERFACE: u8 = 0x04;

/// Communications and CDC Control class (`0x02`).
pub const USB_CLASS_CDC: u8 = 0x02;
/// CDC Network Control Model (NCM) subclass (`0x0D`).
pub const USB_SUBCLASS_CDC_NCM: u8 = 0x0D;

/// Vendor-Specific USB class (`0xFF`).
pub const USB_CLASS_VENDOR_SPECIFIC: u8 = 0xFF;
/// Android ADB USB subclass (`0x42`).
pub const USB_SUBCLASS_ADB: u8 = 0x42;
/// Android ADB USB protocol (`0x01`).
pub const USB_PROTOCOL_ADB: u8 = 0x01;

/// Still Imaging class used by MTP and PTP (`0x06`).
pub const USB_CLASS_STILL_IMAGE: u8 = 0x06;
/// Still Image capture subclass (`0x01`).
pub const USB_SUBCLASS_STILL_IMAGE: u8 = 0x01;
/// Picture Transfer Protocol / Media Transfer Protocol bulk-only protocol (`0x01`).
pub const USB_PROTOCOL_MTP_PTP: u8 = 0x01;

/// Ranked wired transfer tier in order of preference (Tier 1A > Tier 1B > Tier 2).
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum WiredTransferTier {
    /// Tier 1A: USB CDC-NCM Virtual Ethernet (`0x02/0x0D`) over `AppleUserECM` (200–350+ MB/s).
    Tier1ACdcNcm,
    /// Tier 1B: Pure-Rust ADB USB Interface (`0xFF/0x42/0x01`) with Burst Mode + Sync v2 LZ4 (150–250+ MB/s).
    Tier1BAdbMultiplex,
    /// Tier 2: Pure-Rust MTP/PTP Interface (`0x06/0x01/0x01`) with pipelined bulk URBs (40–120 MB/s).
    Tier2MtpPipelined,
}

impl WiredTransferTier {
    /// Expected sustained throughput range in megabytes per second on USB 3.x.
    pub const fn expected_speed_mbps_range(self) -> (u32, u32) {
        match self {
            Self::Tier1ACdcNcm => (200, 350),
            Self::Tier1BAdbMultiplex => (150, 250),
            Self::Tier2MtpPipelined => (40, 120),
        }
    }

    /// Maximum number of concurrent file streams supported by this tier.
    pub const fn max_parallel_streams(self) -> usize {
        match self {
            Self::Tier1ACdcNcm => 8,
            Self::Tier1BAdbMultiplex => 8,
            Self::Tier2MtpPipelined => 1,
        }
    }
}

/// Parsed representation of a USB interface descriptor and optional endpoint addresses.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UsbInterfaceDescriptor {
    pub interface_number: u8,
    pub alternate_setting: u8,
    pub num_endpoints: u8,
    pub interface_class: u8,
    pub interface_subclass: u8,
    pub interface_protocol: u8,
    pub interface_name: Option<String>,
    pub bulk_in_endpoint: Option<u8>,
    pub bulk_out_endpoint: Option<u8>,
}

impl UsbInterfaceDescriptor {
    /// Parse a raw 9-byte standard USB Interface Descriptor.
    ///
    /// ### Binary Header Layout (9 bytes, USB 2.0/3.2 Specification Section 9.6.5)
    /// | Byte Offset | Type | Field | Description |
    /// | :--- | :--- | :--- | :--- |
    /// | `0` | `u8` | `bLength` | Size of this descriptor in bytes (`>= 9`) |
    /// | `1` | `u8` | `bDescriptorType` | INTERFACE Descriptor Type (`0x04`) |
    /// | `2` | `u8` | `bInterfaceNumber` | Zero-based index of this interface |
    /// | `3` | `u8` | `bAlternateSetting` | Value used to select this alternate setting |
    /// | `4` | `u8` | `bNumEndpoints` | Number of endpoints used by this interface |
    /// | `5` | `u8` | `bInterfaceClass` | Class code (`0x02` CDC, `0x06` Still Image, `0xFF` Vendor) |
    /// | `6` | `u8` | `bInterfaceSubClass` | Subclass code (`0x0D` NCM, `0x42` ADB, `0x01` MTP/PTP) |
    /// | `7` | `u8` | `bInterfaceProtocol` | Protocol code (`0x01` ADB / MTP, `0x00` NCM) |
    /// | `8` | `u8` | `iInterface` | Index of string descriptor describing this interface |
    pub fn from_raw_descriptor(raw: &[u8], interface_name: Option<String>) -> Result<Self> {
        if raw.len() < USB_INTERFACE_DESCRIPTOR_LEN {
            return Err(UsbError::TruncatedPacket {
                packet_type: "UsbInterfaceDescriptor",
                expected_len: USB_INTERFACE_DESCRIPTOR_LEN,
                actual_len: raw.len(),
            });
        }
        if usize::from(raw[0]) < USB_INTERFACE_DESCRIPTOR_LEN || raw[1] != USB_DT_INTERFACE {
            return Err(UsbError::TruncatedPacket {
                packet_type: "UsbInterfaceDescriptorType",
                expected_len: USB_INTERFACE_DESCRIPTOR_LEN,
                actual_len: usize::from(raw[0]),
            });
        }

        Ok(Self {
            interface_number: raw[2],
            alternate_setting: raw[3],
            num_endpoints: raw[4],
            interface_class: raw[5],
            interface_subclass: raw[6],
            interface_protocol: raw[7],
            interface_name,
            bulk_in_endpoint: Some(0x81),
            bulk_out_endpoint: Some(0x01),
        })
    }

    /// Classify a single USB interface into one of the three Continuity tiers if matched.
    pub fn classify_tier(&self) -> Option<WiredTransferTier> {
        // Tier 1A: USB CDC-NCM Virtual Ethernet (0x02 / 0x0D)
        if self.interface_class == USB_CLASS_CDC && self.interface_subclass == USB_SUBCLASS_CDC_NCM {
            return Some(WiredTransferTier::Tier1ACdcNcm);
        }

        // Tier 1B: ADB Interface (0xFF / 0x42 / 0x01) requiring at least 2 bulk endpoints
        if self.interface_class == USB_CLASS_VENDOR_SPECIFIC
            && self.interface_subclass == USB_SUBCLASS_ADB
            && self.interface_protocol == USB_PROTOCOL_ADB
            && self.num_endpoints >= 2
        {
            return Some(WiredTransferTier::Tier1BAdbMultiplex);
        }

        // Tier 2: Standard MTP or PTP Still Image Interface (0x06 / 0x01 / 0x01)
        if self.interface_class == USB_CLASS_STILL_IMAGE
            && self.interface_subclass == USB_SUBCLASS_STILL_IMAGE
            && self.interface_protocol == USB_PROTOCOL_MTP_PTP
        {
            return Some(WiredTransferTier::Tier2MtpPipelined);
        }

        // Tier 2 fallback: Android composite gadgets sometimes expose MTP as 0xFF/0xFF/0x00 with string "MTP"
        if self.interface_class == USB_CLASS_VENDOR_SPECIFIC
            && self.interface_subclass == 0xFF
            && self.interface_protocol == 0x00
        {
            if let Some(name) = &self.interface_name {
                if name.to_ascii_uppercase().contains("MTP") {
                    return Some(WiredTransferTier::Tier2MtpPipelined);
                }
            }
        }

        None
    }
}

/// Summary of a connected USB device and its active configuration's interfaces.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UsbDeviceDescriptor {
    pub vendor_id: u16,
    pub product_id: u16,
    pub usb_bcd: u16,
    pub product_name: Option<String>,
    pub interfaces: Vec<UsbInterfaceDescriptor>,
}

/// Result of classifying a USB device's exposed interfaces.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ClassifiedUsbPath {
    pub selected_tier: WiredTransferTier,
    pub selected_interface: UsbInterfaceDescriptor,
    pub available_tiers: Vec<(WiredTransferTier, u8)>,
    pub max_parallel_streams: usize,
    pub expected_speed_mbps: (u32, u32),
}

/// Inspects all USB interfaces on `device` and automatically selects the fastest tier
/// (Tier 1A CDC-NCM > Tier 1B ADB Multiplex > Tier 2 MTP Pipelined).
pub fn classify_usb_device(device: &UsbDeviceDescriptor) -> Result<ClassifiedUsbPath> {
    let mut matched: Vec<(WiredTransferTier, &UsbInterfaceDescriptor)> = device
        .interfaces
        .iter()
        .filter_map(|iface| iface.classify_tier().map(|tier| (tier, iface)))
        .collect();

    if matched.is_empty() {
        return Err(UsbError::NoSupportedInterface {
            vendor_id: device.vendor_id,
            product_id: device.product_id,
        });
    }

    // Sort by WiredTransferTier enum order (Tier1ACdcNcm < Tier1BAdbMultiplex < Tier2MtpPipelined)
    matched.sort_by_key(|(tier, iface)| (*tier, iface.interface_number));

    let (best_tier, best_iface) = matched[0];
    let available_tiers = matched
        .iter()
        .map(|(tier, iface)| (*tier, iface.interface_number))
        .collect();

    Ok(ClassifiedUsbPath {
        selected_tier: best_tier,
        selected_interface: best_iface.clone(),
        available_tiers,
        max_parallel_streams: best_tier.max_parallel_streams(),
        expected_speed_mbps: best_tier.expected_speed_mbps_range(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn selects_tier_1a_cdc_ncm_over_adb_and_mtp() -> Result<()> {
        let mtp_raw = [9, USB_DT_INTERFACE, 0, 0, 3, 0x06, 0x01, 0x01, 0];
        let adb_raw = [9, USB_DT_INTERFACE, 1, 0, 2, 0xFF, 0x42, 0x01, 0];
        let ncm_raw = [9, USB_DT_INTERFACE, 2, 0, 1, 0x02, 0x0D, 0x00, 0];

        let dev = UsbDeviceDescriptor {
            vendor_id: 0x18D1,
            product_id: 0x4EE8,
            usb_bcd: 0x0320,
            product_name: Some("Pixel 9 Pro".to_string()),
            interfaces: vec![
                UsbInterfaceDescriptor::from_raw_descriptor(&mtp_raw, None)?,
                UsbInterfaceDescriptor::from_raw_descriptor(&adb_raw, None)?,
                UsbInterfaceDescriptor::from_raw_descriptor(&ncm_raw, None)?,
            ],
        };

        let classified = classify_usb_device(&dev)?;
        assert_eq!(classified.selected_tier, WiredTransferTier::Tier1ACdcNcm);
        assert_eq!(classified.selected_interface.interface_number, 2);
        assert_eq!(classified.max_parallel_streams, 8);
        assert_eq!(classified.expected_speed_mbps, (200, 350));
        assert_eq!(classified.available_tiers.len(), 3);
        Ok(())
    }

    #[test]
    fn selects_tier_1b_adb_over_mtp_when_tethering_off() -> Result<()> {
        let mtp_raw = [9, USB_DT_INTERFACE, 0, 0, 3, 0x06, 0x01, 0x01, 0];
        let adb_raw = [9, USB_DT_INTERFACE, 1, 0, 2, 0xFF, 0x42, 0x01, 0];

        let dev = UsbDeviceDescriptor {
            vendor_id: 0x18D1,
            product_id: 0x4EE2,
            usb_bcd: 0x0310,
            product_name: Some("Android ADB+MTP".to_string()),
            interfaces: vec![
                UsbInterfaceDescriptor::from_raw_descriptor(&mtp_raw, None)?,
                UsbInterfaceDescriptor::from_raw_descriptor(&adb_raw, None)?,
            ],
        };

        let classified = classify_usb_device(&dev)?;
        assert_eq!(classified.selected_tier, WiredTransferTier::Tier1BAdbMultiplex);
        assert_eq!(classified.selected_interface.interface_number, 1);
        assert_eq!(classified.max_parallel_streams, 8);
        assert_eq!(classified.expected_speed_mbps, (150, 250));
        Ok(())
    }

    #[test]
    fn selects_tier_2_mtp_when_debugging_disabled() -> Result<()> {
        let vendor_mtp_raw = [9, USB_DT_INTERFACE, 0, 0, 3, 0xFF, 0xFF, 0x00, 4];
        let dev = UsbDeviceDescriptor {
            vendor_id: 0x04E8,
            product_id: 0x6860,
            usb_bcd: 0x0300,
            product_name: Some("Galaxy S25".to_string()),
            interfaces: vec![UsbInterfaceDescriptor::from_raw_descriptor(
                &vendor_mtp_raw,
                Some("MTP".to_string()),
            )?],
        };

        let classified = classify_usb_device(&dev)?;
        assert_eq!(classified.selected_tier, WiredTransferTier::Tier2MtpPipelined);
        assert_eq!(classified.max_parallel_streams, 1);
        assert_eq!(classified.expected_speed_mbps, (40, 120));
        Ok(())
    }
}
