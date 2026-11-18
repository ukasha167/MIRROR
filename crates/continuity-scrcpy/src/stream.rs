//! Incremental streaming state machine and in-memory loopback transport for `scrcpy` sockets.

use crate::demux::{
    parse_device_name_header, parse_dummy_byte, parse_frame_packet, parse_stream_codec_header,
    StreamCodecHeader, DEFAULT_MAX_FRAME_SIZE, DEVICE_NAME_HEADER_LEN, DUMMY_BYTE_LEN,
    FRAME_HEADER_LEN, STREAM_CODEC_HEADER_LEN,
};
use crate::error::Result;

/// Owned frame packet emitted by [`ScrcpyStreamDemuxer`] across chunked socket reads.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OwnedFramePacket {
    /// Parsed 12-byte frame header (`pts_and_flags` and `payload_size`).
    pub header: crate::demux::FrameHeader,
    /// Frame payload bytes (`SPS/PPS/VPS`, H.265/H.264 NAL units, or Opus frame).
    pub payload: Vec<u8>,
}

/// Phase of the `scrcpy` video or audio stream handshake and frame loop.
#[derive(Debug, Clone, PartialEq, Eq)]
enum DemuxPhase {
    AwaitDummyByte,
    AwaitDeviceName,
    AwaitCodecHeader,
    StreamingFrames,
}

/// Stateful incremental demuxer that reassembles fragmented socket reads into handshake metadata
/// and [`OwnedFramePacket`] frames without panicking or losing byte-offset tracking.
#[derive(Debug, Clone)]
pub struct ScrcpyStreamDemuxer {
    phase: DemuxPhase,
    buffer: Vec<u8>,
    read_cursor: usize,
    stream_offset: usize,
    max_frame_size: u32,
    device_name: Option<String>,
    codec_header: Option<StreamCodecHeader>,
}

impl ScrcpyStreamDemuxer {
    /// Creates a new stream demuxer.
    ///
    /// Set `expect_dummy_byte` to `true` on `adb forward` tunnels where `send_dummy_byte=true`,
    /// and `expect_device_name` to `true` on the primary socket that receives the 64-byte device header.
    #[must_use]
    pub fn new(expect_dummy_byte: bool, expect_device_name: bool) -> Self {
        let initial_phase = if expect_dummy_byte {
            DemuxPhase::AwaitDummyByte
        } else if expect_device_name {
            DemuxPhase::AwaitDeviceName
        } else {
            DemuxPhase::AwaitCodecHeader
        };
        Self {
            phase: initial_phase,
            buffer: Vec::with_capacity(4096),
            read_cursor: 0,
            stream_offset: 0,
            max_frame_size: DEFAULT_MAX_FRAME_SIZE,
            device_name: None,
            codec_header: None,
        }
    }

    /// Overrides the maximum allowed single-frame payload size in bytes.
    #[must_use]
    pub const fn with_max_frame_size(mut self, max_frame_size: u32) -> Self {
        self.max_frame_size = max_frame_size;
        self
    }

    /// Returns the parsed UTF-8 device name once the 64-byte header has been received.
    #[must_use]
    pub fn device_name(&self) -> Option<&str> {
        self.device_name.as_deref()
    }

    /// Returns the parsed 12-byte [`StreamCodecHeader`] once the codec header has been received.
    #[must_use]
    pub const fn codec_header(&self) -> Option<StreamCodecHeader> {
        self.codec_header
    }

    /// Returns the total number of wire bytes consumed so far.
    #[must_use]
    pub const fn bytes_consumed(&self) -> usize {
        self.stream_offset
    }

    /// Appends newly received socket bytes and extracts all ready [`OwnedFramePacket`]s.
    pub fn push_bytes(&mut self, chunk: &[u8]) -> Result<Vec<OwnedFramePacket>> {
        self.buffer.extend_from_slice(chunk);
        let mut frames = Vec::new();

        loop {
            let unread = &self.buffer[self.read_cursor..];
            match self.phase {
                DemuxPhase::AwaitDummyByte => {
                    if unread.len() < DUMMY_BYTE_LEN {
                        break;
                    }
                    let _ = parse_dummy_byte(unread, self.stream_offset)?;
                    self.advance(DUMMY_BYTE_LEN);
                    self.phase = DemuxPhase::AwaitDeviceName;
                }
                DemuxPhase::AwaitDeviceName => {
                    if unread.len() < DEVICE_NAME_HEADER_LEN {
                        break;
                    }
                    let (dev, _) = parse_device_name_header(unread, self.stream_offset)?;
                    self.device_name = Some(dev.as_str().to_owned());
                    self.advance(DEVICE_NAME_HEADER_LEN);
                    self.phase = DemuxPhase::AwaitCodecHeader;
                }
                DemuxPhase::AwaitCodecHeader => {
                    if unread.len() < STREAM_CODEC_HEADER_LEN {
                        break;
                    }
                    let (hdr, _) = parse_stream_codec_header(unread, self.stream_offset)?;
                    self.codec_header = Some(hdr);
                    self.advance(STREAM_CODEC_HEADER_LEN);
                    self.phase = DemuxPhase::StreamingFrames;
                }
                DemuxPhase::StreamingFrames => {
                    if unread.len() < FRAME_HEADER_LEN {
                        break;
                    }
                    // Validate the 12-byte frame header first so oversized frames fail fast.
                    let (header, _) = crate::demux::parse_frame_header(
                        unread,
                        self.stream_offset,
                        self.max_frame_size,
                    )?;
                    let total_needed = FRAME_HEADER_LEN + (header.payload_size as usize);
                    if unread.len() < total_needed {
                        break;
                    }
                    let (packet, _) =
                        parse_frame_packet(unread, self.stream_offset, self.max_frame_size)?;
                    frames.push(OwnedFramePacket {
                        header: packet.header,
                        payload: packet.payload.to_vec(),
                    });
                    self.advance(total_needed);
                }
            }
        }

        self.compact_if_needed();
        Ok(frames)
    }

    fn advance(&mut self, count: usize) {
        self.read_cursor += count;
        self.stream_offset += count;
    }

    fn compact_if_needed(&mut self) {
        if self.read_cursor > 0 && (self.read_cursor >= 4096 || self.read_cursor == self.buffer.len())
        {
            self.buffer.drain(..self.read_cursor);
            self.read_cursor = 0;
        }
    }
}
