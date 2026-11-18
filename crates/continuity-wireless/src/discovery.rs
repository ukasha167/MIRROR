//! Dual-protocol zero-config discovery for LocalSend v2.1 and Google Quick Share.
//!
//! Supports LocalSend UDP multicast (`224.0.0.167:53317`), hardware-offloaded mDNS
//! (`_localsend._tcp.local.` and `_FC9F5ED42C8A._tcp.local.`), and Android 17
//! (`API 37`) `ACCESS_LOCAL_NETWORK` permission state tracking.

use std::collections::BTreeMap;
use std::net::IpAddr;

use serde::{Deserialize, Serialize};

use crate::error::{Result, WirelessError};
use crate::localsend::{DeviceType, ProtocolType};
use crate::quickshare::QuickShareEndpointInfo;

/// Standard LocalSend v2.1 IPv4 multicast group address.
pub const LOCALSEND_MULTICAST_IPV4: &str = "224.0.0.167";
/// Standard LocalSend v2.1 UDP multicast and HTTP/HTTPS default port.
pub const LOCALSEND_DEFAULT_PORT: u16 = 53317;
/// mDNS service type for LocalSend v2.1 hardware-offloaded discovery.
pub const LOCALSEND_MDNS_SERVICE_TYPE: &str = "_localsend._tcp.local.";
/// mDNS service type for Google Quick Share (Nearby Connections over Wi-Fi LAN).
pub const QUICKSHARE_MDNS_SERVICE_TYPE: &str = "_FC9F5ED42C8A._tcp.local.";

/// Android 17 (`API 37`) `android.permission.ACCESS_LOCAL_NETWORK` state.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum LocalNetworkPermissionState {
    NotRequiredOrImplicit,
    Undetermined,
    Granted,
    Denied,
}

impl LocalNetworkPermissionState {
    pub fn is_allowed(self) -> bool {
        matches!(self, Self::NotRequiredOrImplicit | Self::Granted)
    }

    pub fn ensure_allowed(self) -> Result<()> {
        if self.is_allowed() {
            Ok(())
        } else {
            Err(WirelessError::LocalNetworkPermissionDenied {
                state: format!("{self:?}"),
            })
        }
    }
}

/// Battery-aware discovery power mode.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum DiscoveryPowerMode {
    /// Uses OS-offloaded mDNS (`NsdManager.registerServiceInfoCallback` / `NWListener`) with zero `MulticastLock`.
    IdleHardwareOffloadedMdns,
    /// Active foreground Send sheet mode: permits pulsing UDP multicast to `224.0.0.167:53317`.
    ActiveSendSheetPulse,
}

/// LocalSend v2.1 UDP multicast announcement packet sent to `224.0.0.167:53317`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LocalSendMulticastPacket {
    pub alias: String,
    pub version: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub device_model: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub device_type: Option<DeviceType>,
    pub fingerprint: String,
    pub port: u16,
    pub protocol: ProtocolType,
    #[serde(default)]
    pub download: bool,
    pub announce: bool,
}

impl LocalSendMulticastPacket {
    pub fn to_json_bytes(&self) -> Result<Vec<u8>> {
        serde_json::to_vec(self).map_err(|err| WirelessError::JsonCodec {
            context: "LocalSendMulticastPacket::to_json_bytes",
            details: err.to_string(),
        })
    }

    pub fn from_json_bytes(bytes: &[u8]) -> Result<Self> {
        let pkt: Self = serde_json::from_slice(bytes).map_err(|err| WirelessError::JsonCodec {
            context: "LocalSendMulticastPacket::from_json_bytes",
            details: err.to_string(),
        })?;
        if pkt.alias.trim().is_empty() || pkt.fingerprint.trim().is_empty() || pkt.port == 0 {
            return Err(WirelessError::InvalidDiscoveryDescriptor {
                protocol: "localsend-multicast",
                reason: "alias, fingerprint, and non-zero port are required".to_string(),
            });
        }
        if !pkt.version.starts_with("2.") {
            return Err(WirelessError::UnsupportedLocalSendVersion {
                version: pkt.version,
            });
        }
        Ok(pkt)
    }
}

/// Hardware-offloaded mDNS service advertisement / resolution record.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct MdnsServiceDescriptor {
    pub instance_name: String,
    pub service_type: String,
    pub addresses: Vec<IpAddr>,
    pub port: u16,
    pub txt_records: BTreeMap<String, String>,
}

/// Unified resolved endpoint ready for wireless pairing or file transfer.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ResolvedWirelessEndpoint {
    LocalSend {
        fingerprint: String,
        alias: String,
        device_model: Option<String>,
        addresses: Vec<IpAddr>,
        port: u16,
        protocol: ProtocolType,
        fast_stream_capable: bool,
    },
    QuickShare {
        endpoint_id: [u8; 4],
        endpoint_info: QuickShareEndpointInfo,
        addresses: Vec<IpAddr>,
        port: u16,
    },
}

impl MdnsServiceDescriptor {
    pub fn new_localsend_advertisement(
        alias: &str,
        fingerprint: &str,
        device_model: &str,
        addresses: Vec<IpAddr>,
        port: u16,
        fast_stream_capable: bool,
    ) -> Self {
        let mut txt = BTreeMap::new();
        txt.insert("alias".into(), alias.into());
        txt.insert("version".into(), "2.1".into());
        txt.insert("fingerprint".into(), fingerprint.into());
        txt.insert("model".into(), device_model.into());
        txt.insert("protocol".into(), "https".into());
        txt.insert("fast_stream".into(), if fast_stream_capable { "1" } else { "0" }.into());
        Self {
            instance_name: format!("localsend-{}", &fingerprint[..fingerprint.len().min(8)]),
            service_type: LOCALSEND_MDNS_SERVICE_TYPE.into(),
            addresses,
            port,
            txt_records: txt,
        }
    }

    pub fn new_quickshare_advertisement(
        endpoint_id: [u8; 4],
        endpoint_info: &QuickShareEndpointInfo,
        addresses: Vec<IpAddr>,
        port: u16,
    ) -> Self {
        let mut txt = BTreeMap::new();
        txt.insert("n".into(), endpoint_info.encode_txt_n_value());
        Self {
            instance_name: endpoint_info.encode_mdns_service_name(endpoint_id),
            service_type: QUICKSHARE_MDNS_SERVICE_TYPE.into(),
            addresses,
            port,
            txt_records: txt,
        }
    }

    pub fn resolve(&self) -> Result<ResolvedWirelessEndpoint> {
        if self.port == 0 || self.addresses.is_empty() {
            return Err(WirelessError::InvalidDiscoveryDescriptor {
                protocol: "mdns",
                reason: "non-zero port and at least one IP address required".into(),
            });
        }
        if self.service_type == LOCALSEND_MDNS_SERVICE_TYPE {
            let fingerprint = self
                .txt_records
                .get("fingerprint")
                .cloned()
                .filter(|s| !s.is_empty())
                .ok_or_else(|| WirelessError::InvalidDiscoveryDescriptor {
                    protocol: "localsend-mdns",
                    reason: "missing 'fingerprint' TXT record".into(),
                })?;
            let alias = self.txt_records.get("alias").cloned().unwrap_or_else(|| self.instance_name.clone());
            let protocol = match self.txt_records.get("protocol").map(String::as_str) {
                Some("http") => ProtocolType::Http,
                _ => ProtocolType::Https,
            };
            let fast_stream_capable = self
                .txt_records
                .get("fast_stream")
                .map(|v| v == "1" || v.eq_ignore_ascii_case("true"))
                .unwrap_or(false);
            Ok(ResolvedWirelessEndpoint::LocalSend {
                fingerprint,
                alias,
                device_model: self.txt_records.get("model").cloned(),
                addresses: self.addresses.clone(),
                port: self.port,
                protocol,
                fast_stream_capable,
            })
        } else if self.service_type == QUICKSHARE_MDNS_SERVICE_TYPE {
            let endpoint_id = QuickShareEndpointInfo::parse_mdns_instance_id(&self.instance_name)?;
            let endpoint_info = match self.txt_records.get("n") {
                Some(n) => QuickShareEndpointInfo::decode_txt_n_value(n)?,
                None => QuickShareEndpointInfo::decode_txt_n_value(&self.instance_name)?,
            };
            Ok(ResolvedWirelessEndpoint::QuickShare {
                endpoint_id,
                endpoint_info,
                addresses: self.addresses.clone(),
                port: self.port,
            })
        } else {
            Err(WirelessError::InvalidDiscoveryDescriptor {
                protocol: "mdns",
                reason: format!("unrecognized service type '{}'", self.service_type),
            })
        }
    }
}

/// Stateful controller managing Android 17 `ACCESS_LOCAL_NETWORK` state and discovered endpoints.
#[derive(Debug, Clone)]
pub struct DiscoveryController {
    permission_state: LocalNetworkPermissionState,
    power_mode: DiscoveryPowerMode,
    endpoints: BTreeMap<String, ResolvedWirelessEndpoint>,
}

impl DiscoveryController {
    pub fn new(permission_state: LocalNetworkPermissionState) -> Self {
        Self {
            permission_state,
            power_mode: DiscoveryPowerMode::IdleHardwareOffloadedMdns,
            endpoints: BTreeMap::new(),
        }
    }

    pub fn set_permission_state(&mut self, state: LocalNetworkPermissionState) {
        self.permission_state = state;
        if !state.is_allowed() {
            self.endpoints.clear();
        }
    }

    pub fn permission_state(&self) -> LocalNetworkPermissionState {
        self.permission_state
    }

    pub fn set_power_mode(&mut self, mode: DiscoveryPowerMode) {
        self.power_mode = mode;
    }

    pub fn requires_multicast_lock(&self) -> bool {
        self.permission_state.is_allowed() && self.power_mode == DiscoveryPowerMode::ActiveSendSheetPulse
    }

    pub fn prepare_multicast_pulse(&self, packet: &LocalSendMulticastPacket) -> Result<Vec<u8>> {
        self.permission_state.ensure_allowed()?;
        if self.power_mode != DiscoveryPowerMode::ActiveSendSheetPulse {
            return Err(WirelessError::MulticastForbiddenWhileIdle);
        }
        packet.to_json_bytes()
    }

    pub fn on_mdns_service_resolved(&mut self, descriptor: &MdnsServiceDescriptor) -> Result<ResolvedWirelessEndpoint> {
        self.permission_state.ensure_allowed()?;
        let resolved = descriptor.resolve()?;
        let key = match &resolved {
            ResolvedWirelessEndpoint::LocalSend { fingerprint, .. } => format!("localsend:{fingerprint}"),
            ResolvedWirelessEndpoint::QuickShare { endpoint_id, .. } => format!("quickshare:{}", hex::encode(endpoint_id)),
        };
        self.endpoints.insert(key, resolved.clone());
        Ok(resolved)
    }

    pub fn on_multicast_datagram(&mut self, datagram: &[u8], source_ip: IpAddr) -> Result<ResolvedWirelessEndpoint> {
        self.permission_state.ensure_allowed()?;
        let pkt = LocalSendMulticastPacket::from_json_bytes(datagram)?;
        let endpoint = ResolvedWirelessEndpoint::LocalSend {
            fingerprint: pkt.fingerprint.clone(),
            alias: pkt.alias,
            device_model: pkt.device_model,
            addresses: vec![source_ip],
            port: pkt.port,
            protocol: pkt.protocol,
            fast_stream_capable: false,
        };
        self.endpoints.insert(format!("localsend:{}", pkt.fingerprint), endpoint.clone());
        Ok(endpoint)
    }

    pub fn discovered_endpoints(&self) -> Vec<ResolvedWirelessEndpoint> {
        self.endpoints.values().cloned().collect()
    }
}
