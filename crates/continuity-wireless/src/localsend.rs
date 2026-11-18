//! LocalSend v2.1 control protocol DTOs, session state machine, and pinned-certificate auto-accept.
//!
//! Compatible with upstream `localsend/protocol` v2.1 (`/api/localsend/v2/register`,
//! `/api/localsend/v2/prepare-upload`, `/api/localsend/v2/upload`) plus our optional
//! `/api/localsend/v2/fast-stream` capability negotiation between Continuity peers.

use std::collections::{BTreeMap, BTreeSet};

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::error::{Result, WirelessError};
use crate::fast_stream::{FAST_STREAM_ENDPOINT, PARALLEL_STREAM_COUNT, SMALL_FILE_THRESHOLD_BYTES};

/// REST endpoint for LocalSend v2.1 peer registration.
pub const LOCALSEND_REGISTER_PATH: &str = "/api/localsend/v2/register";
/// REST endpoint for LocalSend v2.1 upload preparation.
pub const LOCALSEND_PREPARE_UPLOAD_PATH: &str = "/api/localsend/v2/prepare-upload";
/// REST endpoint for standard LocalSend v2.1 single-file upload.
pub const LOCALSEND_UPLOAD_PATH: &str = "/api/localsend/v2/upload";

/// Device form-factor reported in LocalSend v2.1 discovery and registration.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum DeviceType {
    Mobile,
    Desktop,
    Web,
    Headless,
    Server,
}

/// Transport security mode advertised by a LocalSend v2.1 peer.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ProtocolType {
    Http,
    Https,
}

/// LocalSend v2.1 `/api/localsend/v2/register` and `/api/localsend/v2/info` payload.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RegisterDto {
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
    #[serde(default)]
    pub fast_stream_capable: bool,
}

impl RegisterDto {
    pub fn validate(&self) -> Result<()> {
        if !self.version.starts_with("2.") {
            return Err(WirelessError::UnsupportedLocalSendVersion {
                version: self.version.clone(),
            });
        }
        if self.alias.trim().is_empty() || self.fingerprint.trim().is_empty() || self.port == 0 {
            return Err(WirelessError::InvalidDiscoveryDescriptor {
                protocol: "localsend-register",
                reason: "alias, fingerprint, and non-zero port are required".into(),
            });
        }
        Ok(())
    }
}

/// Optional file timestamps in LocalSend v2.1 `FileDto`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FileMetadataDto {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub modified: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub accessed: Option<String>,
}

/// File descriptor sent inside `PrepareUploadRequestDto`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FileDto {
    pub id: String,
    pub file_name: String,
    pub size: u64,
    pub file_type: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub sha256: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub preview: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub metadata: Option<FileMetadataDto>,
}

/// Request body for `POST /api/localsend/v2/prepare-upload`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PrepareUploadRequestDto {
    pub info: RegisterDto,
    pub files: BTreeMap<String, FileDto>,
}

/// Optional upgrade descriptor returned in `PrepareUploadResponseDto` when both
/// endpoints support our 4-stream parallel TCP + streaming tar fast path.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FastStreamOfferDto {
    pub endpoint: String,
    pub parallel_streams: usize,
    pub small_file_tar_threshold_bytes: u64,
}

impl Default for FastStreamOfferDto {
    fn default() -> Self {
        Self {
            endpoint: FAST_STREAM_ENDPOINT.into(),
            parallel_streams: PARALLEL_STREAM_COUNT,
            small_file_tar_threshold_bytes: SMALL_FILE_THRESHOLD_BYTES,
        }
    }
}

/// Response body for `POST /api/localsend/v2/prepare-upload`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PrepareUploadResponseDto {
    pub session_id: String,
    pub files: BTreeMap<String, String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub fast_stream: Option<FastStreamOfferDto>,
}

/// Store of pinned TLS certificate fingerprints for paired devices that auto-accept transfers.
#[derive(Debug, Clone, Default)]
pub struct PinnedPeerStore {
    pinned_fingerprints: BTreeSet<String>,
}

impl PinnedPeerStore {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn fingerprint_from_der_cert(der_bytes: &[u8]) -> String {
        hex::encode(Sha256::digest(der_bytes))
    }

    pub fn pin_fingerprint(&mut self, fingerprint: impl Into<String>) {
        self.pinned_fingerprints.insert(fingerprint.into().to_ascii_lowercase());
    }

    pub fn unpin_fingerprint(&mut self, fingerprint: &str) -> bool {
        self.pinned_fingerprints.remove(&fingerprint.to_ascii_lowercase())
    }

    pub fn verify_paired_peer(&self, claimed: &str, tls_verified: &str) -> Result<()> {
        let claimed = claimed.to_ascii_lowercase();
        let actual = tls_verified.to_ascii_lowercase();
        if claimed != actual {
            return Err(WirelessError::UntrustedPeerFingerprint {
                fingerprint: actual,
                reason: "TLS certificate fingerprint does not match RegisterDto claim",
            });
        }
        if !self.pinned_fingerprints.contains(&actual) {
            return Err(WirelessError::UntrustedPeerFingerprint {
                fingerprint: actual,
                reason: "peer certificate is not pinned in Keychain/Keystore",
            });
        }
        Ok(())
    }
}

/// Active upload session state tracked by `LocalSendSessionManager`.
#[derive(Debug, Clone)]
pub struct ActiveUploadSession {
    pub session_id: String,
    pub peer_fingerprint: String,
    pub files: BTreeMap<String, FileDto>,
    pub tokens: BTreeMap<String, String>,
    pub auto_accepted: bool,
    pub fast_stream_enabled: bool,
}

/// Session manager handling LocalSend v2.1 `prepare-upload` and pinned certificate auto-accept.
#[derive(Debug, Clone, Default)]
pub struct LocalSendSessionManager {
    pinned_peers: PinnedPeerStore,
    sessions: BTreeMap<String, ActiveUploadSession>,
    next_nonce: u64,
}

impl LocalSendSessionManager {
    pub fn new(pinned_peers: PinnedPeerStore) -> Self {
        Self {
            pinned_peers,
            sessions: BTreeMap::new(),
            next_nonce: 1,
        }
    }

    pub fn pinned_peers_mut(&mut self) -> &mut PinnedPeerStore {
        &mut self.pinned_peers
    }

    pub fn prepare_upload(
        &mut self,
        request: &PrepareUploadRequestDto,
        tls_peer_fingerprint: &str,
        manual_pin_approved: bool,
    ) -> Result<PrepareUploadResponseDto> {
        request.info.validate()?;
        if request.files.is_empty() {
            return Err(WirelessError::InvalidDiscoveryDescriptor {
                protocol: "localsend-prepare-upload",
                reason: "prepare-upload must contain at least one file".into(),
            });
        }
        let auto_accepted = match self
            .pinned_peers
            .verify_paired_peer(&request.info.fingerprint, tls_peer_fingerprint)
        {
            Ok(()) => true,
            Err(_) if manual_pin_approved => false,
            Err(err) => return Err(err),
        };

        let session_id = format!("ls-session-{:08x}", self.next_nonce);
        self.next_nonce += 1;

        let mut tokens = BTreeMap::new();
        for file_id in request.files.keys() {
            let digest = Sha256::new()
                .chain_update(session_id.as_bytes())
                .chain_update(b":")
                .chain_update(file_id.as_bytes())
                .chain_update(b":")
                .chain_update(tls_peer_fingerprint.as_bytes())
                .finalize();
            tokens.insert(file_id.clone(), hex::encode(&digest[..16]));
        }

        let fast_stream = request.info.fast_stream_capable.then(FastStreamOfferDto::default);
        self.sessions.insert(
            session_id.clone(),
            ActiveUploadSession {
                session_id: session_id.clone(),
                peer_fingerprint: tls_peer_fingerprint.to_ascii_lowercase(),
                files: request.files.clone(),
                tokens: tokens.clone(),
                auto_accepted,
                fast_stream_enabled: fast_stream.is_some(),
            },
        );
        Ok(PrepareUploadResponseDto {
            session_id,
            files: tokens,
            fast_stream,
        })
    }

    pub fn validate_upload_token<'a>(
        &'a self,
        session_id: &str,
        file_id: &str,
        token: &str,
    ) -> Result<&'a FileDto> {
        let err = || WirelessError::InvalidUploadToken {
            session_id: session_id.into(),
            file_id: file_id.into(),
        };
        let session = self.sessions.get(session_id).ok_or_else(err)?;
        let expected = session.tokens.get(file_id).ok_or_else(err)?;
        if expected != token {
            return Err(err());
        }
        session.files.get(file_id).ok_or_else(err)
    }

    pub fn get_session(&self, session_id: &str) -> Option<&ActiveUploadSession> {
        self.sessions.get(session_id)
    }
}
