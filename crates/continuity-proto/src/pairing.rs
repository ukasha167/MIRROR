//! Unified QR-code pairing URI codec and mTLS pinned peer verification state machine.
//!
//! Combines Android 11–17 Wireless Debugging (`WIFI:T:ADB;S:<service>;P:<pass>;;`)
//! with Mirror Continuity's mTLS Ed25519/ECDSA X.509 certificate SHA-256 fingerprint,
//! device identifier, and LAN socket endpoints in a single scan.

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::net::SocketAddr;

use crate::error::{ProtoError, ProtoResult};

/// A reachable LAN socket endpoint advertised during pairing.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LanEndpoint {
    /// IPv4 or IPv6 socket address for the TLS control/transfer listener.
    pub addr: SocketAddr,
    /// Whether this endpoint is over USB CDC-NCM virtual Ethernet (`AppleUserECM`).
    pub is_usb_ncm: bool,
}

/// Complete QR pairing payload bridging Android Wireless ADB and Continuity mTLS.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ContinuityPairingQr {
    /// Android Wireless Debugging mDNS service name (`S:` field in `WIFI:T:ADB`).
    pub adb_service_name: String,
    /// Android Wireless Debugging 6-digit or alphanumeric pairing password (`P:` field).
    pub adb_password: String,
    /// Unique Continuity device UUID or persistent hardware identifier.
    pub device_id: String,
    /// Human-readable device name (e.g., `"MacBook Pro M1"`).
    pub device_name: String,
    /// 32-byte SHA-256 fingerprint of the host's Ed25519/ECDSA X.509 DER certificate.
    pub cert_sha256: [u8; 32],
    /// Reachable LAN / USB-NCM endpoints where the host is listening for mTLS.
    pub endpoints: Vec<LanEndpoint>,
    /// Expiration timestamp in Unix seconds.
    pub expires_at_secs: u64,
}

impl ContinuityPairingQr {
    /// Formats the strict AOSP Wireless Debugging QR string (`WIFI:T:ADB;S:<ssid>;P:<pass>;;`).
    pub fn to_adb_wifi_qr(&self) -> String {
        format!(
            "WIFI:T:ADB;S:{};P:{};;",
            escape_qr_token(&self.adb_service_name),
            escape_qr_token(&self.adb_password)
        )
    }

    /// Formats the unified Continuity + Wireless ADB QR payload string.
    ///
    /// Wire format:
    /// `WIFI:T:ADB;S:<service>;P:<pass>;ID:<id>;NAME:<name>;FP:<hex_sha256>;EP:<addr|ncm,...>;EXP:<ts>;;`
    pub fn to_combined_qr(&self) -> String {
        let fp_hex = hex::encode(self.cert_sha256);
        let ep_joined = self
            .endpoints
            .iter()
            .map(|ep| {
                let tag = if ep.is_usb_ncm { "ncm" } else { "lan" };
                format!("{}@{}", ep.addr, tag)
            })
            .collect::<Vec<_>>()
            .join(",");

        format!(
            "WIFI:T:ADB;S:{};P:{};ID:{};NAME:{};FP:{};EP:{};EXP:{};;",
            escape_qr_token(&self.adb_service_name),
            escape_qr_token(&self.adb_password),
            escape_qr_token(&self.device_id),
            escape_qr_token(&self.device_name),
            fp_hex,
            ep_joined,
            self.expires_at_secs
        )
    }

    /// Parses a unified Continuity QR string and validates all mandatory fields.
    pub fn from_combined_qr(input: &str) -> ProtoResult<Self> {
        let trimmed = input.trim();
        if !trimmed.starts_with("WIFI:T:ADB;") || !trimmed.ends_with(";;") {
            return Err(ProtoError::InvalidPairingUri {
                reason: "must start with 'WIFI:T:ADB;' and end with ';;'".to_string(),
            });
        }
        let body = &trimmed["WIFI:T:ADB;".len()..trimmed.len() - 2];
        let mut adb_service_name = None;
        let mut adb_password = None;
        let mut device_id = None;
        let mut device_name = None;
        let mut cert_sha256 = None;
        let mut endpoints = Vec::new();
        let mut expires_at_secs = None;

        for part in split_unescaped_semicolons(body) {
            if part.is_empty() {
                continue;
            }
            let (key, raw_val) =
                part.split_once(':')
                    .ok_or_else(|| ProtoError::InvalidPairingUri {
                        reason: format!("missing ':' in token '{part}'"),
                    })?;
            let val = unescape_qr_token(raw_val);
            match key {
                "S" => adb_service_name = Some(val),
                "P" => adb_password = Some(val),
                "ID" => device_id = Some(val),
                "NAME" => device_name = Some(val),
                "FP" => {
                    let bytes =
                        hex::decode(&val).map_err(|_| ProtoError::InvalidPairingUri {
                            reason: "FP field is not valid hex".to_string(),
                        })?;
                    let arr: [u8; 32] =
                        bytes
                            .try_into()
                            .map_err(|_| ProtoError::InvalidPairingUri {
                                reason: "FP field must be 32 bytes (64 hex chars)".to_string(),
                            })?;
                    cert_sha256 = Some(arr);
                }
                "EP" if !val.is_empty() => {
                    for item in val.split(',') {
                        let (addr_str, mode) = item.split_once('@').unwrap_or((item, "lan"));
                        let addr: SocketAddr =
                            addr_str
                                .parse()
                                .map_err(|_| ProtoError::InvalidPairingUri {
                                    reason: format!("invalid socket address '{addr_str}'"),
                                })?;
                        endpoints.push(LanEndpoint {
                            addr,
                            is_usb_ncm: mode == "ncm",
                        });
                    }
                }
                "EXP" => {
                    expires_at_secs =
                        Some(val.parse().map_err(|_| ProtoError::InvalidPairingUri {
                            reason: format!("invalid EXP timestamp '{val}'"),
                        })?);
                }
                _ => {}
            }
        }

        let missing = |field: &str| ProtoError::InvalidPairingUri {
            reason: format!("missing '{field}'"),
        };
        let qr = Self {
            adb_service_name: adb_service_name.ok_or_else(|| missing("S"))?,
            adb_password: adb_password.ok_or_else(|| missing("P"))?,
            device_id: device_id.ok_or_else(|| missing("ID"))?,
            device_name: device_name.ok_or_else(|| missing("NAME"))?,
            cert_sha256: cert_sha256.ok_or_else(|| missing("FP"))?,
            endpoints,
            expires_at_secs: expires_at_secs.ok_or_else(|| missing("EXP"))?,
        };
        if qr.adb_service_name.is_empty() || qr.adb_password.is_empty() || qr.device_id.is_empty() {
            return Err(ProtoError::InvalidPairingUri {
                reason: "S, P, and ID fields must be non-empty".to_string(),
            });
        }
        Ok(qr)
    }
}

/// Computes the 32-byte SHA-256 digest of a DER-encoded X.509 certificate.
pub fn compute_cert_sha256(cert_der: &[u8]) -> [u8; 32] {
    let mut hasher = Sha256::new();
    hasher.update(cert_der);
    hasher.finalize().into()
}
/// Constant-time 32-byte equality comparison to prevent timing side-channels.
pub fn constant_time_eq_32(a: &[u8; 32], b: &[u8; 32]) -> bool {
    let mut diff = 0u8;
    for i in 0..32 {
        diff |= a[i] ^ b[i];
    }
    diff == 0
}

/// Verified peer identity persisted in macOS Keychain or Android Keystore.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PinnedPeerIdentity {
    pub device_id: String,
    pub device_name: String,
    pub peer_cert_sha256: [u8; 32],
    pub local_cert_sha256: [u8; 32],
    pub paired_at_secs: u64,
    pub endpoints: Vec<LanEndpoint>,
}

/// States of the mutual-TLS + Wireless ADB pairing state machine.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PairingState {
    Unpaired,
    AwaitingPeerHandshake { qr: ContinuityPairingQr },
    MutualTlsVerified { peer: PinnedPeerIdentity },
}

/// State machine enforcing QR expiration and mutual certificate pinning.
#[derive(Debug, Clone)]
pub struct PairingStateMachine {
    local_cert_sha256: [u8; 32],
    state: PairingState,
}

impl PairingStateMachine {
    /// Creates a new pairing state machine bound to the local certificate fingerprint.
    pub fn new(local_cert_sha256: [u8; 32]) -> Self {
        Self {
            local_cert_sha256,
            state: PairingState::Unpaired,
        }
    }

    /// Returns the current state of the pairing state machine.
    pub fn state(&self) -> &PairingState {
        &self.state
    }

    /// Begins a pairing session from a generated or scanned [`ContinuityPairingQr`].
    pub fn begin_with_qr(&mut self, qr: ContinuityPairingQr, now_secs: u64) -> ProtoResult<()> {
        if now_secs >= qr.expires_at_secs {
            return Err(ProtoError::PairingExpired {
                expires_at_secs: qr.expires_at_secs,
                now_secs,
            });
        }
        self.state = PairingState::AwaitingPeerHandshake { qr };
        Ok(())
    }

    /// Verifies the peer's presented X.509 certificate against the expected fingerprint.
    pub fn verify_peer_certificate(
        &mut self,
        peer_device_id: String,
        peer_device_name: String,
        presented_peer_cert_der: &[u8],
        expected_peer_sha256: &[u8; 32],
        now_secs: u64,
    ) -> ProtoResult<PinnedPeerIdentity> {
        let qr = match &self.state {
            PairingState::AwaitingPeerHandshake { qr } => qr.clone(),
            PairingState::Unpaired => {
                return Err(ProtoError::InvalidPairingTransition {
                    from: "Unpaired",
                    action: "verify_peer_certificate",
                })
            }
            PairingState::MutualTlsVerified { .. } => {
                return Err(ProtoError::InvalidPairingTransition {
                    from: "MutualTlsVerified",
                    action: "verify_peer_certificate",
                })
            }
        };
        if now_secs >= qr.expires_at_secs {
            return Err(ProtoError::PairingExpired {
                expires_at_secs: qr.expires_at_secs,
                now_secs,
            });
        }
        let actual_fp = compute_cert_sha256(presented_peer_cert_der);
        if !constant_time_eq_32(&actual_fp, expected_peer_sha256) {
            return Err(ProtoError::CertificateFingerprintMismatch {
                expected_hex: hex::encode(expected_peer_sha256),
                actual_hex: hex::encode(actual_fp),
            });
        }
        let pinned = PinnedPeerIdentity {
            device_id: peer_device_id,
            device_name: peer_device_name,
            peer_cert_sha256: actual_fp,
            local_cert_sha256: self.local_cert_sha256,
            paired_at_secs: now_secs,
            endpoints: qr.endpoints,
        };
        self.state = PairingState::MutualTlsVerified {
            peer: pinned.clone(),
        };
        Ok(pinned)
    }

    /// Verifies a subsequent reconnect from an already-pinned peer without prompting.
    pub fn verify_pinned_reconnect(
        pinned: &PinnedPeerIdentity,
        presented_cert_der: &[u8],
    ) -> ProtoResult<()> {
        let actual_fp = compute_cert_sha256(presented_cert_der);
        if !constant_time_eq_32(&actual_fp, &pinned.peer_cert_sha256) {
            return Err(ProtoError::CertificateFingerprintMismatch {
                expected_hex: hex::encode(pinned.peer_cert_sha256),
                actual_hex: hex::encode(actual_fp),
            });
        }
        Ok(())
    }
}

fn escape_qr_token(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for ch in s.chars() {
        if matches!(ch, '\\' | ';' | ':' | ',') {
            out.push('\\');
        }
        out.push(ch);
    }
    out
}

fn unescape_qr_token(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut escaped = false;
    for ch in s.chars() {
        if escaped {
            out.push(ch);
            escaped = false;
        } else if ch == '\\' {
            escaped = true;
        } else {
            out.push(ch);
        }
    }
    out
}

fn split_unescaped_semicolons(s: &str) -> Vec<&str> {
    let mut parts = Vec::new();
    let mut start = 0;
    let mut escaped = false;
    for (idx, ch) in s.char_indices() {
        if escaped {
            escaped = false;
        } else if ch == '\\' {
            escaped = true;
        } else if ch == ';' {
            parts.push(&s[start..idx]);
            start = idx + 1;
        }
    }
    if start <= s.len() {
        parts.push(&s[start..]);
    }
    parts
}
