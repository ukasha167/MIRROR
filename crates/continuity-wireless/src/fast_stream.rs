//! LocalSend v2.1 Fast-Stream upgrade (`/api/localsend/v2/fast-stream`).
//!
//! Partitions batches across **4 parallel async TCP+TLS streams** and packs small files
//! (`< 1 MiB`) into an in-flight streaming tar container with SHA-256 verification.

use std::collections::BTreeMap;
use std::future::Future;
use std::pin::Pin;

use futures_util::future::try_join_all;
use sha2::{Digest, Sha256};

use crate::error::{Result, WirelessError};

/// Upgrade endpoint negotiated in `PrepareUploadResponseDto`.
pub const FAST_STREAM_ENDPOINT: &str = "/api/localsend/v2/fast-stream";
/// Number of parallel TCP+TLS streams opened for a Fast-Stream transfer session.
pub const PARALLEL_STREAM_COUNT: usize = 4;
/// Files strictly smaller than 1 MiB (`1_048_576` bytes) are packed into an in-flight tar stream.
pub const SMALL_FILE_THRESHOLD_BYTES: u64 = 1_048_576;
/// Fixed byte length of a `StreamFrameHeader`.
pub const STREAM_FRAME_HEADER_LEN: usize = 16;
/// Fixed byte length of a `TarEntryHeader` prefix.
pub const TAR_ENTRY_HEADER_LEN: usize = 48;

/// Frame payload discriminator inside a Fast-Stream TCP lane.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum StreamFrameKind {
    LargeFileSingle = 0x01,
    SmallFileTarArchive = 0x02,
    StreamFin = 0x03,
}

impl StreamFrameKind {
    fn from_u8(raw: u8) -> Result<Self> {
        match raw {
            0x01 => Ok(Self::LargeFileSingle),
            0x02 => Ok(Self::SmallFileTarArchive),
            0x03 => Ok(Self::StreamFin),
            other => Err(WirelessError::InvalidWireHeader {
                packet_type: "StreamFrameHeader",
                offset: 5,
                details: format!("unknown frame_kind 0x{other:02x}"),
            }),
        }
    }
}

/// 16-byte wire frame header sent on each of the 4 parallel TCP+TLS lanes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct StreamFrameHeader {
    pub stream_index: u8,
    pub frame_kind: StreamFrameKind,
    pub item_count: u16,
    pub payload_len: u64,
}

impl StreamFrameHeader {
    pub fn encode(&self) -> [u8; STREAM_FRAME_HEADER_LEN] {
        let mut out = [0u8; STREAM_FRAME_HEADER_LEN];
        out[0..4].copy_from_slice(b"LSFS");
        out[4] = self.stream_index;
        out[5] = self.frame_kind as u8;
        out[6..8].copy_from_slice(&self.item_count.to_be_bytes());
        out[8..16].copy_from_slice(&self.payload_len.to_be_bytes());
        out
    }

    /// Parses a 16-byte `StreamFrameHeader`.
    ///
    /// ### Wire Byte Layout (16 bytes, Big-Endian)
    /// - **Bytes `0..4`**: ASCII magic `b"LSFS"` (`[0x4C, 0x53, 0x46, 0x53]`)
    /// - **Byte `4`**: `stream_index: u8` (`0..PARALLEL_STREAM_COUNT`)
    /// - **Byte `5`**: `frame_kind: u8` (`0x01` = LargeFileSingle, `0x02` = SmallFileTarArchive, `0x03` = StreamFin)
    /// - **Bytes `6..8`**: `item_count: u16` (big-endian unsigned 16-bit integer)
    /// - **Bytes `8..16`**: `payload_len: u64` (big-endian unsigned 64-bit integer)
    pub fn decode(buf: &[u8]) -> Result<Self> {
        if buf.len() < STREAM_FRAME_HEADER_LEN {
            return Err(WirelessError::WireLengthMismatch {
                packet_type: "StreamFrameHeader",
                expected_len: STREAM_FRAME_HEADER_LEN,
                actual_len: buf.len(),
            });
        }
        if &buf[0..4] != b"LSFS" {
            return Err(WirelessError::InvalidWireHeader {
                packet_type: "StreamFrameHeader",
                offset: 0,
                details: format!("expected magic b\"LSFS\", got {:02x?}", &buf[0..4]),
            });
        }
        let stream_index = buf[4];
        if (stream_index as usize) >= PARALLEL_STREAM_COUNT {
            return Err(WirelessError::StreamIndexOutOfBounds { stream_index, max_lanes: PARALLEL_STREAM_COUNT });
        }
        Ok(Self {
            stream_index,
            frame_kind: StreamFrameKind::from_u8(buf[5])?,
            item_count: u16::from_be_bytes([buf[6], buf[7]]),
            payload_len: u64::from_be_bytes(buf[8..16].try_into().unwrap_or([0; 8])),
        })
    }
}

/// 48-byte fixed header prefix for an entry inside the in-flight streaming tar container.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TarEntryHeader {
    pub file_id: String,
    pub file_name: String,
    pub file_size: u64,
    pub sha256: [u8; 32],
}

impl TarEntryHeader {
    pub fn encode_into(&self, dst: &mut Vec<u8>) {
        let (id_b, name_b) = (self.file_id.as_bytes(), self.file_name.as_bytes());
        dst.extend_from_slice(b"UTAR");
        dst.extend_from_slice(&(id_b.len() as u16).to_be_bytes());
        dst.extend_from_slice(&(name_b.len() as u16).to_be_bytes());
        dst.extend_from_slice(&self.file_size.to_be_bytes());
        dst.extend_from_slice(&self.sha256);
        dst.extend_from_slice(id_b);
        dst.extend_from_slice(name_b);
    }

    /// Decodes a `TarEntryHeader` from `buf`, returning `(header, total_header_bytes_consumed)`.
    ///
    /// ### Wire Byte Layout (48-byte fixed prefix + variable UTF-8 strings, Big-Endian)
    /// - **Bytes `0..4`**: ASCII magic `b"UTAR"` (`[0x55, 0x54, 0x41, 0x52]`)
    /// - **Bytes `4..6`**: `id_len: u16`, **Bytes `6..8`**: `name_len: u16`, **Bytes `8..16`**: `file_size: u64`
    /// - **Bytes `16..48`**: `sha256: [u8; 32]`, **Bytes `48..`**: `file_id` + `file_name` (UTF-8)
    pub fn decode(buf: &[u8]) -> Result<(Self, usize)> {
        if buf.len() < TAR_ENTRY_HEADER_LEN {
            return Err(WirelessError::WireLengthMismatch { packet_type: "TarEntryHeader", expected_len: TAR_ENTRY_HEADER_LEN, actual_len: buf.len() });
        }
        if &buf[0..4] != b"UTAR" {
            return Err(WirelessError::InvalidWireHeader { packet_type: "TarEntryHeader", offset: 0, details: "bad magic".into() });
        }
        let (id_len, name_len) = (u16::from_be_bytes([buf[4], buf[5]]) as usize, u16::from_be_bytes([buf[6], buf[7]]) as usize);
        let file_size = u64::from_be_bytes(buf[8..16].try_into().unwrap_or([0; 8]));
        let mut sha256 = [0u8; 32];
        sha256.copy_from_slice(&buf[16..48]);
        let total_len = TAR_ENTRY_HEADER_LEN + id_len + name_len;
        if buf.len() < total_len {
            return Err(WirelessError::WireLengthMismatch { packet_type: "TarEntryHeader::strings", expected_len: total_len, actual_len: buf.len() });
        }
        let parse_str = |slice: &[u8], off: usize| {
            std::str::from_utf8(slice).map(str::to_string).map_err(|e| WirelessError::InvalidWireHeader {
                packet_type: "TarEntryHeader::utf8",
                offset: off,
                details: e.to_string(),
            })
        };
        Ok((Self { file_id: parse_str(&buf[48..48 + id_len], 48)?, file_name: parse_str(&buf[48 + id_len..total_len], 48 + id_len)?, file_size, sha256 }, total_len))
    }
}

/// An outgoing or incoming file transferred over the Fast-Stream engine.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TransferFile {
    pub file_id: String,
    pub file_name: String,
    pub data: Vec<u8>,
    pub sha256: [u8; 32],
}

impl TransferFile {
    pub fn new(file_id: impl Into<String>, file_name: impl Into<String>, data: Vec<u8>) -> Self {
        let sha256: [u8; 32] = Sha256::digest(&data).into();
        Self { file_id: file_id.into(), file_name: file_name.into(), data, sha256 }
    }

    pub fn is_small_file(&self) -> bool {
        (self.data.len() as u64) < SMALL_FILE_THRESHOLD_BYTES
    }
}

/// Packs a slice of files into an in-flight streaming tar payload buffer.
pub fn pack_streaming_tar_entries(files: &[TransferFile]) -> Vec<u8> {
    let cap = files.iter().map(|f| 64 + f.data.len()).sum();
    let mut buf = Vec::with_capacity(cap);
    for f in files {
        let hdr = TarEntryHeader {
            file_id: f.file_id.clone(),
            file_name: f.file_name.clone(),
            file_size: f.data.len() as u64,
            sha256: f.sha256,
        };
        hdr.encode_into(&mut buf);
        buf.extend_from_slice(&f.data);
    }
    buf
}

/// Unpacks an in-flight streaming tar payload buffer and verifies every file's SHA-256 digest.
pub fn unpack_and_verify_tar_entries(buf: &[u8], expected_count: u16) -> Result<Vec<TransferFile>> {
    let (mut cursor, mut out) = (0usize, Vec::with_capacity(expected_count as usize));
    for _ in 0..expected_count {
        let (hdr, hdr_len) = TarEntryHeader::decode(&buf[cursor..])?;
        cursor += hdr_len;
        let end = cursor + (hdr.file_size as usize);
        if buf.len() < end {
            return Err(WirelessError::WireLengthMismatch {
                packet_type: "TarEntryPayload",
                expected_len: end,
                actual_len: buf.len(),
            });
        }
        let data = buf[cursor..end].to_vec();
        cursor = end;
        let actual_sha: [u8; 32] = Sha256::digest(&data).into();
        if actual_sha != hdr.sha256 {
            return Err(WirelessError::ChecksumMismatch {
                file_id: hdr.file_id,
                expected_sha256: hex::encode(hdr.sha256),
                actual_sha256: hex::encode(actual_sha),
            });
        }
        out.push(TransferFile { file_id: hdr.file_id, file_name: hdr.file_name, data, sha256: actual_sha });
    }
    Ok(out)
}

/// Partitions a batch of files across `PARALLEL_STREAM_COUNT` (`4`) wire lane buffers.
pub fn partition_batch_into_lanes(files: &[TransferFile]) -> [Vec<u8>; PARALLEL_STREAM_COUNT] {
    let mut lane_bytes: [Vec<u8>; PARALLEL_STREAM_COUNT] = std::array::from_fn(|_| Vec::new());
    let mut lane_weights = [0u64; PARALLEL_STREAM_COUNT];
    let mut small_buckets: [Vec<TransferFile>; PARALLEL_STREAM_COUNT] = std::array::from_fn(|_| Vec::new());

    for file in files {
        let lane = lane_weights.iter().enumerate().min_by_key(|(_, &w)| w).map(|(i, _)| i).unwrap_or(0);
        lane_weights[lane] += (file.data.len() as u64).max(64);
        if file.is_small_file() {
            small_buckets[lane].push(file.clone());
        } else {
            let payload = pack_streaming_tar_entries(std::slice::from_ref(file));
            let hdr = StreamFrameHeader {
                stream_index: lane as u8,
                frame_kind: StreamFrameKind::LargeFileSingle,
                item_count: 1,
                payload_len: payload.len() as u64,
            };
            lane_bytes[lane].extend_from_slice(&hdr.encode());
            lane_bytes[lane].extend_from_slice(&payload);
        }
    }

    for (lane, bucket) in small_buckets.into_iter().enumerate() {
        for chunk in bucket.chunks(2048) {
            let payload = pack_streaming_tar_entries(chunk);
            let hdr = StreamFrameHeader {
                stream_index: lane as u8,
                frame_kind: StreamFrameKind::SmallFileTarArchive,
                item_count: chunk.len() as u16,
                payload_len: payload.len() as u64,
            };
            lane_bytes[lane].extend_from_slice(&hdr.encode());
            lane_bytes[lane].extend_from_slice(&payload);
        }
        let fin = StreamFrameHeader {
            stream_index: lane as u8,
            frame_kind: StreamFrameKind::StreamFin,
            item_count: 0,
            payload_len: 0,
        };
        lane_bytes[lane].extend_from_slice(&fin.encode());
    }
    lane_bytes
}

/// Summary statistics from a 4-stream parallel transfer.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ParallelTransferResult {
    pub files: BTreeMap<String, TransferFile>,
    pub small_files_tar_unpacked: usize,
    pub large_files_streamed: usize,
    pub lane_wire_bytes: [usize; PARALLEL_STREAM_COUNT],
}

/// Decodes a single parallel TCP lane stream from start to `StreamFin`.
pub fn decode_stream_lane(expected_lane: u8, wire_bytes: &[u8]) -> Result<(Vec<TransferFile>, usize, usize)> {
    let (mut cursor, mut received, mut small_cnt, mut large_cnt) = (0, Vec::new(), 0, 0);
    while cursor < wire_bytes.len() {
        let hdr = StreamFrameHeader::decode(&wire_bytes[cursor..])?;
        if hdr.stream_index != expected_lane {
            return Err(WirelessError::InvalidWireHeader {
                packet_type: "StreamFrameHeader::stream_index",
                offset: cursor + 4,
                details: format!("expected lane {}, got {}", expected_lane, hdr.stream_index),
            });
        }
        cursor += STREAM_FRAME_HEADER_LEN;
        let end = cursor + (hdr.payload_len as usize);
        if wire_bytes.len() < end {
            return Err(WirelessError::WireLengthMismatch {
                packet_type: "StreamFramePayload",
                expected_len: end,
                actual_len: wire_bytes.len(),
            });
        }
        let payload = &wire_bytes[cursor..end];
        cursor = end;
        match hdr.frame_kind {
            StreamFrameKind::LargeFileSingle => {
                let mut unpacked = unpack_and_verify_tar_entries(payload, hdr.item_count)?;
                large_cnt += unpacked.len();
                received.append(&mut unpacked);
            }
            StreamFrameKind::SmallFileTarArchive => {
                let mut unpacked = unpack_and_verify_tar_entries(payload, hdr.item_count)?;
                small_cnt += unpacked.len();
                received.append(&mut unpacked);
            }
            StreamFrameKind::StreamFin => break,
        }
    }
    Ok((received, small_cnt, large_cnt))
}

/// Executes an async 4-stream parallel loopback transfer, running all 4 TCP lane futures concurrently.
pub async fn execute_parallel_fast_stream(files: &[TransferFile]) -> Result<ParallelTransferResult> {
    let lanes = partition_batch_into_lanes(files);
    let lane_wire_bytes = [lanes[0].len(), lanes[1].len(), lanes[2].len(), lanes[3].len()];
    let tasks: Vec<Pin<Box<dyn Future<Output = Result<(Vec<TransferFile>, usize, usize)>> + Send>>> = lanes
        .into_iter()
        .enumerate()
        .map(|(idx, wire)| -> Pin<Box<dyn Future<Output = _> + Send>> {
            Box::pin(async move { decode_stream_lane(idx as u8, &wire) })
        })
        .collect();
    let outputs = try_join_all(tasks).await?;
    let (mut files_map, mut small_files_tar_unpacked, mut large_files_streamed) = (BTreeMap::new(), 0, 0);
    for (lane_files, s_cnt, l_cnt) in outputs {
        small_files_tar_unpacked += s_cnt;
        large_files_streamed += l_cnt;
        for f in lane_files {
            files_map.insert(f.file_id.clone(), f);
        }
    }
    Ok(ParallelTransferResult { files: files_map, small_files_tar_unpacked, large_files_streamed, lane_wire_bytes })
}
