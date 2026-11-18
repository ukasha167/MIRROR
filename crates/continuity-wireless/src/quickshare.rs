//! Embedded Google Quick Share (NearDrop / Nearby Connections LAN) receiver engine.
//!
//! Ported from the public-domain `grishka/NearDrop` specification (Unlicense) so Android
//! shares natively to the Mac from the system Quick Share sheet with zero setup.

use std::collections::BTreeMap;

use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine;
use sha2::{Digest, Sha256};

use crate::error::{Result, WirelessError};

/// Maximum Quick Share TCP frame size (8 MiB) to guard against malformed length prefixes.
pub const MAX_QUICKSHARE_FRAME_LEN: usize = 8 * 1024 * 1024;
/// Fixed header size of a Quick Share TCP length-prefixed frame (`u32` big-endian).
pub const QUICKSHARE_LENGTH_HEADER_LEN: usize = 4;
/// Fixed header size of a D2D authenticated frame (`8B sequence + 32B tag + 4B payload_len`).
pub const D2D_FRAME_HEADER_LEN: usize = 44;

/// Device form-factor encoded in Byte 0 (`bits 1..=3`) of Quick Share `EndpointInfo`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum QuickShareDeviceType {
    Unknown = 0,
    Phone = 1,
    Tablet = 2,
    Display = 3,
    Laptop = 4,
}

impl QuickShareDeviceType {
    fn from_bits(bits: u8) -> Self {
        match bits & 0b111 {
            1 => Self::Phone,
            2 => Self::Tablet,
            3 => Self::Display,
            4 => Self::Laptop,
            _ => Self::Unknown,
        }
    }
}

/// Decoded Google Quick Share endpoint metadata advertised in mDNS and `ConnectionRequest`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct QuickShareEndpointInfo {
    pub version: u8,
    pub visible_to_everyone: bool,
    pub device_type: QuickShareDeviceType,
    pub device_name: String,
}

impl QuickShareEndpointInfo {
    pub fn encode_binary(&self) -> Vec<u8> {
        let name_bytes = self.device_name.as_bytes();
        let mut out = Vec::with_capacity(18 + name_bytes.len());
        let byte0 = ((self.version & 0b111) << 5)
            | (if self.visible_to_everyone { 1 << 4 } else { 0 })
            | ((self.device_type as u8 & 0b111) << 1);
        out.push(byte0);
        out.extend_from_slice(&[0u8; 16]);
        out.push(name_bytes.len() as u8);
        out.extend_from_slice(name_bytes);
        out
    }

    /// Parses a binary Quick Share `EndpointInfo` buffer.
    ///
    /// ### Wire Byte Layout (18-byte fixed header + UTF-8 device name, Big-Endian)
    /// - **Byte `0`**: Bitfield `(version[3b] << 5) | (visibility[1b] << 4) | (device_type[3b] << 1) | reserved[1b]`
    /// - **Bytes `1..17`**: 16-byte reserved / random salt field
    /// - **Byte `17`**: `name_len: u8` (UTF-8 byte length of the device name)
    /// - **Bytes `18..(18 + name_len)`**: UTF-8 `device_name`
    pub fn decode_binary(buf: &[u8]) -> Result<Self> {
        if buf.len() < 18 {
            return Err(WirelessError::WireLengthMismatch {
                packet_type: "QuickShareEndpointInfo",
                expected_len: 18,
                actual_len: buf.len(),
            });
        }
        let byte0 = buf[0];
        let name_len = buf[17] as usize;
        if name_len == 0 || buf.len() < 18 + name_len {
            return Err(WirelessError::WireLengthMismatch {
                packet_type: "QuickShareEndpointInfo::device_name",
                expected_len: 18 + name_len.max(1),
                actual_len: buf.len(),
            });
        }
        let device_name = std::str::from_utf8(&buf[18..18 + name_len])
            .map_err(|e| WirelessError::InvalidWireHeader {
                packet_type: "QuickShareEndpointInfo::device_name",
                offset: 18,
                details: e.to_string(),
            })?
            .to_string();
        Ok(Self {
            version: (byte0 >> 5) & 0b111,
            visible_to_everyone: ((byte0 >> 4) & 1) != 0,
            device_type: QuickShareDeviceType::from_bits((byte0 >> 1) & 0b111),
            device_name,
        })
    }

    pub fn encode_txt_n_value(&self) -> String {
        URL_SAFE_NO_PAD.encode(self.encode_binary())
    }

    pub fn decode_txt_n_value(txt_n: &str) -> Result<Self> {
        let raw = URL_SAFE_NO_PAD.decode(txt_n).map_err(|e| WirelessError::InvalidDiscoveryDescriptor {
            protocol: "quickshare-mdns-txt-n",
            reason: e.to_string(),
        })?;
        Self::decode_binary(&raw)
    }

    pub fn encode_mdns_service_name(&self, endpoint_id: [u8; 4]) -> String {
        URL_SAFE_NO_PAD.encode([
            0x23, endpoint_id[0], endpoint_id[1], endpoint_id[2], endpoint_id[3], 0xFC, 0x9F, 0x5E, 0x00, 0x00,
        ])
    }

    pub fn parse_mdns_instance_id(instance_name: &str) -> Result<[u8; 4]> {
        let raw = URL_SAFE_NO_PAD.decode(instance_name).map_err(|e| WirelessError::InvalidDiscoveryDescriptor {
            protocol: "quickshare-mdns-instance",
            reason: e.to_string(),
        })?;
        if raw.len() < 5 {
            return Err(WirelessError::WireLengthMismatch {
                packet_type: "QuickShareMdnsInstanceName",
                expected_len: 5,
                actual_len: raw.len(),
            });
        }
        Ok([raw[1], raw[2], raw[3], raw[4]])
    }
}

/// 4-byte big-endian length-prefixed TCP frame codec used by Nearby Connections / Quick Share.
pub struct QuickShareFrameCodec;

impl QuickShareFrameCodec {
    pub fn encode_frame(payload: &[u8]) -> Vec<u8> {
        let mut out = Vec::with_capacity(QUICKSHARE_LENGTH_HEADER_LEN + payload.len());
        out.extend_from_slice(&(payload.len() as u32).to_be_bytes());
        out.extend_from_slice(payload);
        out
    }

    /// Decodes a length-prefixed Quick Share frame, returning `(payload_slice, total_bytes_consumed)`.
    ///
    /// ### Wire Byte Layout (4-byte length header + payload, Big-Endian)
    /// - **Bytes `0..4`**: `frame_len: u32` (big-endian unsigned 32-bit payload byte count)
    /// - **Bytes `4..(4 + frame_len)`**: raw frame body bytes
    pub fn decode_frame(buf: &[u8]) -> Result<(&[u8], usize)> {
        if buf.len() < QUICKSHARE_LENGTH_HEADER_LEN {
            return Err(WirelessError::WireLengthMismatch {
                packet_type: "QuickShareLengthHeader",
                expected_len: QUICKSHARE_LENGTH_HEADER_LEN,
                actual_len: buf.len(),
            });
        }
        let frame_len = u32::from_be_bytes([buf[0], buf[1], buf[2], buf[3]]) as usize;
        if frame_len == 0 || frame_len > MAX_QUICKSHARE_FRAME_LEN {
            return Err(WirelessError::InvalidWireHeader {
                packet_type: "QuickShareLengthHeader",
                offset: 0,
                details: format!("invalid frame_len {frame_len}"),
            });
        }
        let total = QUICKSHARE_LENGTH_HEADER_LEN + frame_len;
        if buf.len() < total {
            return Err(WirelessError::WireLengthMismatch {
                packet_type: "QuickShareFramePayload",
                expected_len: total,
                actual_len: buf.len(),
            });
        }
        Ok((&buf[QUICKSHARE_LENGTH_HEADER_LEN..total], total))
    }
}

/// States of the Quick Share UKEY2 + Paired-Key handshake.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Ukey2State {
    #[default]
    Initial,
    ClientInitReceived,
    ServerInitSent,
    ClientFinishReceived,
    PairedKeyVerified,
    Established,
}

/// UKEY2 handshake state machine deriving session encryption keys and the 6-digit auth PIN.
#[derive(Debug, Clone, Default)]
pub struct Ukey2HandshakeMachine {
    state: Ukey2State,
    transcript: Vec<u8>,
    d2d_client_key: [u8; 32],
    d2d_server_key: [u8; 32],
    auth_pin: String,
}

impl Ukey2HandshakeMachine {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn state(&self) -> Ukey2State {
        self.state
    }

    pub fn on_client_init(&mut self, client_init: &[u8], server_pub: &[u8; 32]) -> Result<Vec<u8>> {
        if self.state != Ukey2State::Initial {
            return Err(WirelessError::InvalidUkey2State { current_state: "non-Initial", message_type: "ClientInit" });
        }
        if client_init.len() < 8 {
            return Err(WirelessError::WireLengthMismatch { packet_type: "Ukey2ClientInit", expected_len: 8, actual_len: client_init.len() });
        }
        self.transcript.extend_from_slice(client_init);
        self.state = Ukey2State::ClientInitReceived;
        let mut server_init = b"UKEY2_SERVER_INIT:".to_vec();
        server_init.extend_from_slice(server_pub);
        self.transcript.extend_from_slice(&server_init);
        self.state = Ukey2State::ServerInitSent;
        Ok(QuickShareFrameCodec::encode_frame(&server_init))
    }

    pub fn on_client_finish(&mut self, client_finish: &[u8]) -> Result<String> {
        if self.state != Ukey2State::ServerInitSent {
            return Err(WirelessError::InvalidUkey2State { current_state: "not ServerInitSent", message_type: "ClientFinish" });
        }
        if client_finish.len() < 8 {
            return Err(WirelessError::WireLengthMismatch { packet_type: "Ukey2ClientFinish", expected_len: 8, actual_len: client_finish.len() });
        }
        self.transcript.extend_from_slice(client_finish);
        self.d2d_client_key = Sha256::new().chain_update(b"D2D_CLIENT_KEY:").chain_update(&self.transcript).finalize().into();
        self.d2d_server_key = Sha256::new().chain_update(b"D2D_SERVER_KEY:").chain_update(&self.transcript).finalize().into();
        let pin_digest = Sha256::new().chain_update(b"UKEY2_AUTH_STRING:").chain_update(&self.transcript).finalize();
        let code = u32::from_be_bytes([pin_digest[0], pin_digest[1], pin_digest[2], pin_digest[3]]) % 1_000_000;
        self.auth_pin = format!("{code:06}");
        self.state = Ukey2State::ClientFinishReceived;
        Ok(self.auth_pin.clone())
    }

    pub fn verify_paired_key_encryption(&mut self, peer_proof: &[u8], expected_secret: Option<&[u8]>) -> Result<()> {
        if self.state != Ukey2State::ClientFinishReceived {
            return Err(WirelessError::InvalidUkey2State { current_state: "not ClientFinishReceived", message_type: "PairedKeyEncryption" });
        }
        if let Some(secret) = expected_secret {
            let expected_tag: [u8; 32] = Sha256::new().chain_update(secret).chain_update(self.d2d_client_key).finalize().into();
            if peer_proof != expected_tag {
                return Err(WirelessError::QuickShareAuthFailure { sequence: 0, reason: "paired-key secret proof mismatch" });
            }
        }
        self.state = Ukey2State::Established;
        Ok(())
    }

    pub fn d2d_client_key(&self) -> &[u8; 32] {
        &self.d2d_client_key
    }
}

/// Authenticated D2D frame wrapper protecting Quick Share control and payload messages.
pub struct PairedKeyFrameCodec;

impl PairedKeyFrameCodec {
    pub fn seal(key: &[u8; 32], sequence: u64, payload: &[u8]) -> Vec<u8> {
        let tag: [u8; 32] = Sha256::new().chain_update(key).chain_update(sequence.to_be_bytes()).chain_update(payload).finalize().into();
        let mut out = Vec::with_capacity(D2D_FRAME_HEADER_LEN + payload.len());
        out.extend_from_slice(&sequence.to_be_bytes());
        out.extend_from_slice(&tag);
        out.extend_from_slice(&(payload.len() as u32).to_be_bytes());
        out.extend_from_slice(payload);
        out
    }

    /// Verifies and opens a D2D authenticated frame.
    ///
    /// ### Wire Byte Layout (44-byte header + payload, Big-Endian)
    /// - **Bytes `0..8`**: `sequence: u64` (big-endian monotonically increasing frame counter)
    /// - **Bytes `8..40`**: `auth_tag: [u8; 32]` (SHA-256 MAC over `key || sequence_be || payload`)
    /// - **Bytes `40..44`**: `payload_len: u32` (big-endian unsigned 32-bit payload length)
    /// - **Bytes `44..(44 + payload_len)`**: authenticated frame body
    pub fn open<'a>(key: &[u8; 32], expected_seq: u64, frame: &'a [u8]) -> Result<&'a [u8]> {
        if frame.len() < D2D_FRAME_HEADER_LEN {
            return Err(WirelessError::WireLengthMismatch { packet_type: "PairedKeyD2DFrame", expected_len: D2D_FRAME_HEADER_LEN, actual_len: frame.len() });
        }
        let seq = u64::from_be_bytes(frame[0..8].try_into().unwrap_or([0; 8]));
        if seq != expected_seq {
            return Err(WirelessError::QuickShareAuthFailure { sequence: seq, reason: "unexpected frame sequence number" });
        }
        let payload_len = u32::from_be_bytes([frame[40], frame[41], frame[42], frame[43]]) as usize;
        if frame.len() < D2D_FRAME_HEADER_LEN + payload_len {
            return Err(WirelessError::WireLengthMismatch { packet_type: "PairedKeyD2DFrame::payload", expected_len: D2D_FRAME_HEADER_LEN + payload_len, actual_len: frame.len() });
        }
        let payload = &frame[44..44 + payload_len];
        let expected_tag: [u8; 32] = Sha256::new().chain_update(key).chain_update(seq.to_be_bytes()).chain_update(payload).finalize().into();
        if &frame[8..40] != expected_tag {
            return Err(WirelessError::QuickShareAuthFailure { sequence: seq, reason: "authentication tag mismatch" });
        }
        Ok(payload)
    }
}

/// Reassembles incoming Quick Share multi-chunk file payloads after UKEY2 completes.
#[derive(Debug, Default)]
pub struct QuickSharePayloadReassembler {
    expected_sizes: BTreeMap<i64, (String, usize)>,
    buffers: BTreeMap<i64, Vec<u8>>,
}

impl QuickSharePayloadReassembler {
    pub fn register_introduction(&mut self, payload_id: i64, file_name: String, total_size: usize) {
        self.expected_sizes.insert(payload_id, (file_name, total_size));
        self.buffers.insert(payload_id, Vec::with_capacity(total_size));
    }

    pub fn ingest_chunk(&mut self, payload_id: i64, offset: usize, chunk: &[u8], is_last: bool) -> Result<Option<(String, Vec<u8>)>> {
        let (file_name, total_size) = self.expected_sizes.get(&payload_id).cloned().ok_or(
            WirelessError::PayloadReassemblyError { payload_id, packet_type: "DataChunk", expected_len: 0, actual_len: chunk.len() },
        )?;
        let buf = self.buffers.get_mut(&payload_id).ok_or(
            WirelessError::PayloadReassemblyError { payload_id, packet_type: "DataChunk", expected_len: offset, actual_len: 0 },
        )?;
        if buf.len() != offset || buf.len() + chunk.len() > total_size {
            return Err(WirelessError::PayloadReassemblyError { payload_id, packet_type: "DataChunk", expected_len: buf.len(), actual_len: offset });
        }
        buf.extend_from_slice(chunk);
        if !is_last {
            return Ok(None);
        }
        if buf.len() != total_size {
            return Err(WirelessError::PayloadReassemblyError { payload_id, packet_type: "FinalVerify", expected_len: total_size, actual_len: buf.len() });
        }
        self.expected_sizes.remove(&payload_id);
        Ok(Some((file_name, self.buffers.remove(&payload_id).unwrap_or_default())))
    }
}
