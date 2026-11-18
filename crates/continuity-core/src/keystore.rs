//! Keychain (macOS) and Keystore (Android) trait bridge and paired device store.
//!
//! Designed for Mozilla UniFFI callback interfaces so Swift (`SecItemCopyMatching`)
//! and Kotlin (`AndroidKeyStore`) can persist pinned X.509 SHA-256 identities while
//! unit tests run against [`InMemoryKeystoreBridge`] with zero hardware dependencies.

use std::collections::HashMap;
use std::sync::{Arc, RwLock};

use continuity_proto::{
    compute_cert_sha256, PairingStateMachine, PinnedPeerIdentity,
};

use crate::error::{CoreError, CoreResult};

/// UniFFI-compatible platform bridge for persisting certificates and pinned peer fingerprints.
pub trait KeystoreBridge: Send + Sync {
    /// Returns the local device's DER-encoded X.509 certificate, generating it if absent.
    fn load_or_create_host_cert_der(&self) -> Result<Vec<u8>, String>;

    /// Persists a verified [`PinnedPeerIdentity`] in Keychain or Android Keystore.
    fn save_pinned_peer(&self, peer: &PinnedPeerIdentity) -> Result<(), String>;

    /// Loads a previously pinned peer by its `device_id`.
    fn load_pinned_peer(&self, device_id: &str) -> Result<Option<PinnedPeerIdentity>, String>;

    /// Removes a pinned peer when unpairing.
    fn remove_pinned_peer(&self, device_id: &str) -> Result<bool, String>;

    /// Lists all pinned peer identities stored on this device.
    fn list_pinned_peers(&self) -> Result<Vec<PinnedPeerIdentity>, String>;
}

/// Deterministic in-memory [`KeystoreBridge`] for unit tests and headless simulations.
#[derive(Debug, Default)]
pub struct InMemoryKeystoreBridge {
    host_cert_der: Vec<u8>,
    peers: RwLock<HashMap<String, PinnedPeerIdentity>>,
}

impl InMemoryKeystoreBridge {
    /// Creates an in-memory keystore seeded with the given DER certificate bytes.
    pub fn new(host_cert_der: Vec<u8>) -> Self {
        Self {
            host_cert_der,
            peers: RwLock::new(HashMap::new()),
        }
    }
}

impl KeystoreBridge for InMemoryKeystoreBridge {
    fn load_or_create_host_cert_der(&self) -> Result<Vec<u8>, String> {
        Ok(self.host_cert_der.clone())
    }

    fn save_pinned_peer(&self, peer: &PinnedPeerIdentity) -> Result<(), String> {
        let mut map = self
            .peers
            .write()
            .map_err(|_| "keystore RwLock poisoned".to_string())?;
        map.insert(peer.device_id.clone(), peer.clone());
        Ok(())
    }

    fn load_pinned_peer(&self, device_id: &str) -> Result<Option<PinnedPeerIdentity>, String> {
        let map = self
            .peers
            .read()
            .map_err(|_| "keystore RwLock poisoned".to_string())?;
        Ok(map.get(device_id).cloned())
    }

    fn remove_pinned_peer(&self, device_id: &str) -> Result<bool, String> {
        let mut map = self
            .peers
            .write()
            .map_err(|_| "keystore RwLock poisoned".to_string())?;
        Ok(map.remove(device_id).is_some())
    }

    fn list_pinned_peers(&self) -> Result<Vec<PinnedPeerIdentity>, String> {
        let map = self
            .peers
            .read()
            .map_err(|_| "keystore RwLock poisoned".to_string())?;
        let mut list: Vec<PinnedPeerIdentity> = map.values().cloned().collect();
        list.sort_by(|a, b| a.device_id.cmp(&b.device_id));
        Ok(list)
    }
}

/// Manages paired devices and enforces zero-prompt mutual TLS verification.
#[derive(Clone)]
pub struct PairedDeviceStore {
    bridge: Arc<dyn KeystoreBridge>,
    local_cert_sha256: [u8; 32],
}

impl PairedDeviceStore {
    /// Initializes the store by loading the local host certificate from `bridge`.
    pub fn new(bridge: Arc<dyn KeystoreBridge>) -> CoreResult<Self> {
        let host_der =
            bridge
                .load_or_create_host_cert_der()
                .map_err(|reason| CoreError::Keystore {
                    operation: "load_or_create_host_cert_der",
                    reason,
                })?;
        let local_cert_sha256 = compute_cert_sha256(&host_der);
        Ok(Self {
            bridge,
            local_cert_sha256,
        })
    }

    /// Returns the SHA-256 fingerprint of our local host X.509 certificate.
    pub fn local_cert_sha256(&self) -> [u8; 32] {
        self.local_cert_sha256
    }

    /// Stores a newly verified peer identity in the underlying Keychain/Keystore.
    pub fn record_paired_peer(&self, peer: &PinnedPeerIdentity) -> CoreResult<()> {
        self.bridge
            .save_pinned_peer(peer)
            .map_err(|reason| CoreError::Keystore {
                operation: "save_pinned_peer",
                reason,
            })
    }

    /// Looks up a pinned peer by `device_id`.
    pub fn get_peer(&self, device_id: &str) -> CoreResult<Option<PinnedPeerIdentity>> {
        self.bridge
            .load_pinned_peer(device_id)
            .map_err(|reason| CoreError::Keystore {
                operation: "load_pinned_peer",
                reason,
            })
    }

    /// Lists all paired peers in deterministic order.
    pub fn list_peers(&self) -> CoreResult<Vec<PinnedPeerIdentity>> {
        self.bridge
            .list_pinned_peers()
            .map_err(|reason| CoreError::Keystore {
                operation: "list_pinned_peers",
                reason,
            })
    }

    /// Unpairs and removes a peer from the trusted store.
    pub fn unpair_peer(&self, device_id: &str) -> CoreResult<bool> {
        self.bridge
            .remove_pinned_peer(device_id)
            .map_err(|reason| CoreError::Keystore {
                operation: "remove_pinned_peer",
                reason,
            })
    }

    /// Verifies that `device_id` is paired and that its presented X.509 DER certificate
    /// matches the pinned SHA-256 fingerprint, enabling zero-prompt file drops,
    /// clipboard sync, and 2FA OTP notifications.
    pub fn verify_zero_prompt_peer(
        &self,
        device_id: &str,
        presented_cert_der: &[u8],
    ) -> CoreResult<PinnedPeerIdentity> {
        let pinned = self
            .get_peer(device_id)?
            .ok_or_else(|| CoreError::DeviceNotPaired {
                device_id: device_id.to_string(),
            })?;
        PairingStateMachine::verify_pinned_reconnect(&pinned, presented_cert_der)?;
        Ok(pinned)
    }
}
