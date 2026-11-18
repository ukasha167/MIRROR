//! Deterministic binary payload serializer, deserializer, and CRC32 integrity verifier.

use crate::error::{ProtoError, ProtoResult};
use crate::packet::{
    ClipboardDataChunk, ClipboardOffer, ControlFrame, ControlFrameHeader, ControlPacket,
    DragOutOffer, Heartbeat, MediaAction, MediaControlCommand, MediaSessionUpdate,
    NotificationInlineReply, NotificationMirror, OtpCodeDetected, PacketType, PowerStateUpdate,
    ThermalState, FRAME_MAGIC, HEADER_LEN, MAX_CONTROL_PAYLOAD_LEN, PROTOCOL_VERSION,
};

/// Computes the IEEE 802.3 CRC32 checksum over header prefix (`bytes[0..20]`) and `payload`.
pub fn compute_crc32_tag(header_prefix_20: &[u8], payload: &[u8]) -> u32 {
    let mut crc: u32 = 0xFFFF_FFFF;
    for &b in header_prefix_20.iter().chain(payload.iter()) {
        crc ^= u32::from(b);
        for _ in 0..8 {
            let mask = (crc & 1).wrapping_neg();
            crc = (crc >> 1) ^ (0xEDB8_8320 & mask);
        }
    }
    !crc
}

/// Encodes a [`ControlFrame`] into its 24-byte header + binary payload representation.
pub fn encode_frame_bytes(frame: &ControlFrame) -> ProtoResult<Vec<u8>> {
    let ptype = frame.packet.packet_type() as u8;
    let payload = encode_payload(&frame.packet)?;
    if payload.len() > MAX_CONTROL_PAYLOAD_LEN {
        return Err(ProtoError::PayloadTooLarge {
            packet_type: ptype,
            length: payload.len(),
            max: MAX_CONTROL_PAYLOAD_LEN,
        });
    }
    let mut out = Vec::with_capacity(HEADER_LEN + payload.len());
    out.extend_from_slice(&FRAME_MAGIC);
    out.push(PROTOCOL_VERSION);
    out.push(ptype);
    out.extend_from_slice(&frame.flags.to_be_bytes());
    out.extend_from_slice(&frame.stream_id.to_be_bytes());
    out.extend_from_slice(&frame.sequence.to_be_bytes());
    out.extend_from_slice(&(payload.len() as u32).to_be_bytes());

    let tag = compute_crc32_tag(&out[0..20], &payload);
    out.extend_from_slice(&tag.to_be_bytes());
    out.extend_from_slice(&payload);
    Ok(out)
}

/// Decodes a [`ControlFrame`] from `bytes`, verifying header fields and CRC32 integrity.
pub fn decode_frame_bytes(bytes: &[u8]) -> ProtoResult<ControlFrame> {
    let header = ControlFrameHeader::parse(bytes)?;
    let ptype = header.packet_type as u8;
    let expected_total = HEADER_LEN + (header.payload_len as usize);
    if bytes.len() < expected_total {
        return Err(ProtoError::TruncatedPayload {
            packet_type: ptype,
            expected: header.payload_len as usize,
            actual: bytes.len().saturating_sub(HEADER_LEN),
        });
    }
    let payload = &bytes[HEADER_LEN..expected_total];
    let actual_tag = compute_crc32_tag(&bytes[0..20], payload);
    if actual_tag != header.integrity_tag {
        return Err(ProtoError::IntegrityMismatch {
            packet_type: ptype,
            stream_id: header.stream_id,
            expected_tag: header.integrity_tag,
            actual_tag,
        });
    }
    let packet = decode_payload(header.packet_type, payload)?;
    Ok(ControlFrame {
        stream_id: header.stream_id,
        flags: header.flags,
        sequence: header.sequence,
        packet,
    })
}

fn encode_payload(packet: &ControlPacket) -> ProtoResult<Vec<u8>> {
    let mut buf = Vec::with_capacity(128);
    match packet {
        ControlPacket::ClipboardOffer(p) => {
            buf.extend_from_slice(&p.offer_id.to_be_bytes());
            write_str(&mut buf, &p.mime_type);
            buf.extend_from_slice(&p.byte_length.to_be_bytes());
            buf.extend_from_slice(&p.sha256);
            write_bytes(&mut buf, &p.preview_thumb);
            buf.push(u8::from(p.is_concealed));
            buf.push(u8::from(p.is_transient));
        }
        ControlPacket::ClipboardDataChunk(p) => {
            buf.extend_from_slice(&p.offer_id.to_be_bytes());
            buf.extend_from_slice(&p.chunk_index.to_be_bytes());
            buf.extend_from_slice(&p.total_chunks.to_be_bytes());
            buf.push(u8::from(p.is_last));
            write_bytes(&mut buf, &p.data);
        }
        ControlPacket::NotificationMirror(p) => {
            write_str(&mut buf, &p.notification_id);
            write_str(&mut buf, &p.package_name);
            write_str(&mut buf, &p.app_name);
            write_str(&mut buf, &p.title);
            write_str(&mut buf, &p.body);
            buf.extend_from_slice(&p.timestamp_ms.to_be_bytes());
            buf.push(u8::from(p.can_reply_inline));
            write_bytes(&mut buf, &p.icon_png);
        }
        ControlPacket::NotificationInlineReply(p) => {
            write_str(&mut buf, &p.notification_id);
            write_str(&mut buf, &p.reply_text);
            buf.push(u8::from(p.dismiss_after_reply));
        }
        ControlPacket::OtpCodeDetected(p) => {
            write_str(&mut buf, &p.code);
            write_str(&mut buf, &p.issuer);
            buf.extend_from_slice(&p.expires_in_secs.to_be_bytes());
        }
        ControlPacket::MediaSessionUpdate(p) => {
            write_str(&mut buf, &p.package_name);
            write_str(&mut buf, &p.title);
            write_str(&mut buf, &p.artist);
            write_str(&mut buf, &p.album);
            buf.push(u8::from(p.is_playing));
            buf.extend_from_slice(&p.position_ms.to_be_bytes());
            buf.extend_from_slice(&p.duration_ms.to_be_bytes());
            write_bytes(&mut buf, &p.album_art_thumb);
        }
        ControlPacket::MediaControlCommand(p) => match p.action {
            MediaAction::Play => buf.push(0),
            MediaAction::Pause => buf.push(1),
            MediaAction::TogglePlayPause => buf.push(2),
            MediaAction::NextTrack => buf.push(3),
            MediaAction::PreviousTrack => buf.push(4),
            MediaAction::SeekToMs(ms) => {
                buf.push(5);
                buf.extend_from_slice(&ms.to_be_bytes());
            }
            MediaAction::SetVolumePercent(vol) => {
                buf.push(6);
                buf.push(vol);
            }
        },
        ControlPacket::DragOutOffer(p) => {
            buf.extend_from_slice(&p.drag_id.to_be_bytes());
            write_str(&mut buf, &p.content_uri);
            write_str(&mut buf, &p.filename);
            write_str(&mut buf, &p.mime_type);
            buf.extend_from_slice(&p.size.to_be_bytes());
            buf.extend_from_slice(&p.cursor_exit_x.to_be_bytes());
            buf.extend_from_slice(&p.cursor_exit_y.to_be_bytes());
        }
        ControlPacket::Heartbeat(p) => {
            buf.extend_from_slice(&p.sequence.to_be_bytes());
            buf.extend_from_slice(&p.timestamp_ms.to_be_bytes());
            buf.extend_from_slice(&p.rtt_hint_us.to_be_bytes());
        }
        ControlPacket::PowerStateUpdate(p) => {
            buf.push(p.battery_percent);
            buf.push(u8::from(p.is_charging));
            buf.push(p.thermal_state as u8);
            buf.push(u8::from(p.oled_screen_off));
        }
    }
    Ok(buf)
}

fn decode_payload(packet_type: PacketType, payload: &[u8]) -> ProtoResult<ControlPacket> {
    let pt = packet_type as u8;
    let mut r = CursorReader {
        packet_type: pt,
        buf: payload,
        pos: 0,
    };
    match packet_type {
        PacketType::ClipboardOffer => Ok(ControlPacket::ClipboardOffer(ClipboardOffer {
            offer_id: r.read_u64("offer_id")?,
            mime_type: r.read_str("mime_type")?,
            byte_length: r.read_u64("byte_length")?,
            sha256: r.read_fixed_32("sha256")?,
            preview_thumb: r.read_bytes("preview_thumb")?,
            is_concealed: r.read_bool("is_concealed")?,
            is_transient: r.read_bool("is_transient")?,
        })),
        PacketType::ClipboardDataChunk => {
            Ok(ControlPacket::ClipboardDataChunk(ClipboardDataChunk {
                offer_id: r.read_u64("offer_id")?,
                chunk_index: r.read_u32("chunk_index")?,
                total_chunks: r.read_u32("total_chunks")?,
                is_last: r.read_bool("is_last")?,
                data: r.read_bytes("data")?,
            }))
        }
        PacketType::NotificationMirror => {
            Ok(ControlPacket::NotificationMirror(NotificationMirror {
                notification_id: r.read_str("notification_id")?,
                package_name: r.read_str("package_name")?,
                app_name: r.read_str("app_name")?,
                title: r.read_str("title")?,
                body: r.read_str("body")?,
                timestamp_ms: r.read_u64("timestamp_ms")?,
                can_reply_inline: r.read_bool("can_reply_inline")?,
                icon_png: r.read_bytes("icon_png")?,
            }))
        }
        PacketType::NotificationInlineReply => Ok(ControlPacket::NotificationInlineReply(
            NotificationInlineReply {
                notification_id: r.read_str("notification_id")?,
                reply_text: r.read_str("reply_text")?,
                dismiss_after_reply: r.read_bool("dismiss_after_reply")?,
            },
        )),
        PacketType::OtpCodeDetected => Ok(ControlPacket::OtpCodeDetected(OtpCodeDetected {
            code: r.read_str("code")?,
            issuer: r.read_str("issuer")?,
            expires_in_secs: r.read_u16("expires_in_secs")?,
        })),
        PacketType::MediaSessionUpdate => {
            Ok(ControlPacket::MediaSessionUpdate(MediaSessionUpdate {
                package_name: r.read_str("package_name")?,
                title: r.read_str("title")?,
                artist: r.read_str("artist")?,
                album: r.read_str("album")?,
                is_playing: r.read_bool("is_playing")?,
                position_ms: r.read_u64("position_ms")?,
                duration_ms: r.read_u64("duration_ms")?,
                album_art_thumb: r.read_bytes("album_art_thumb")?,
            }))
        }
        PacketType::MediaControlCommand => {
            let action = match r.read_u8("action")? {
                0 => MediaAction::Play,
                1 => MediaAction::Pause,
                2 => MediaAction::TogglePlayPause,
                3 => MediaAction::NextTrack,
                4 => MediaAction::PreviousTrack,
                5 => MediaAction::SeekToMs(r.read_u64("seek_to_ms")?),
                6 => MediaAction::SetVolumePercent(r.read_u8("volume_percent")?),
                other => {
                    return Err(ProtoError::InvalidEnumValue {
                        packet_type: pt,
                        field: "action",
                        raw_value: other,
                    })
                }
            };
            Ok(ControlPacket::MediaControlCommand(MediaControlCommand {
                action,
            }))
        }
        PacketType::DragOutOffer => Ok(ControlPacket::DragOutOffer(DragOutOffer {
            drag_id: r.read_u64("drag_id")?,
            content_uri: r.read_str("content_uri")?,
            filename: r.read_str("filename")?,
            mime_type: r.read_str("mime_type")?,
            size: r.read_u64("size")?,
            cursor_exit_x: r.read_i32("cursor_exit_x")?,
            cursor_exit_y: r.read_i32("cursor_exit_y")?,
        })),
        PacketType::Heartbeat => Ok(ControlPacket::Heartbeat(Heartbeat {
            sequence: r.read_u64("sequence")?,
            timestamp_ms: r.read_u64("timestamp_ms")?,
            rtt_hint_us: r.read_u32("rtt_hint_us")?,
        })),
        PacketType::PowerStateUpdate => Ok(ControlPacket::PowerStateUpdate(PowerStateUpdate {
            battery_percent: r.read_u8("battery_percent")?,
            is_charging: r.read_bool("is_charging")?,
            thermal_state: ThermalState::from_u8(r.read_u8("thermal_state")?, pt)?,
            oled_screen_off: r.read_bool("oled_screen_off")?,
        })),
    }
}

fn write_bytes(buf: &mut Vec<u8>, data: &[u8]) {
    buf.extend_from_slice(&(data.len() as u32).to_be_bytes());
    buf.extend_from_slice(data);
}
fn write_str(buf: &mut Vec<u8>, s: &str) {
    write_bytes(buf, s.as_bytes());
}
struct CursorReader<'a> {
    packet_type: u8,
    buf: &'a [u8],
    pos: usize,
}

impl<'a> CursorReader<'a> {
    fn take(&mut self, field: &'static str, len: usize) -> ProtoResult<&'a [u8]> {
        let rem = self.buf.len().saturating_sub(self.pos);
        if rem < len {
            return Err(ProtoError::MalformedField {
                packet_type: self.packet_type,
                field,
                expected: len,
                actual: rem,
            });
        }
        let slice = &self.buf[self.pos..self.pos + len];
        self.pos += len;
        Ok(slice)
    }
    fn read_u8(&mut self, field: &'static str) -> ProtoResult<u8> {
        Ok(self.take(field, 1)?[0])
    }
    fn read_bool(&mut self, field: &'static str) -> ProtoResult<bool> {
        match self.read_u8(field)? {
            0 => Ok(false),
            1 => Ok(true),
            other => Err(ProtoError::InvalidEnumValue {
                packet_type: self.packet_type,
                field,
                raw_value: other,
            }),
        }
    }
    fn read_u16(&mut self, field: &'static str) -> ProtoResult<u16> {
        let b = self.take(field, 2)?;
        Ok(u16::from_be_bytes([b[0], b[1]]))
    }
    fn read_u32(&mut self, field: &'static str) -> ProtoResult<u32> {
        let b = self.take(field, 4)?;
        Ok(u32::from_be_bytes([b[0], b[1], b[2], b[3]]))
    }
    fn read_i32(&mut self, field: &'static str) -> ProtoResult<i32> {
        let b = self.take(field, 4)?;
        Ok(i32::from_be_bytes([b[0], b[1], b[2], b[3]]))
    }
    fn read_u64(&mut self, field: &'static str) -> ProtoResult<u64> {
        let b = self.take(field, 8)?;
        Ok(u64::from_be_bytes([b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7]]))
    }
    fn read_fixed_32(&mut self, field: &'static str) -> ProtoResult<[u8; 32]> {
        let mut out = [0u8; 32];
        out.copy_from_slice(self.take(field, 32)?);
        Ok(out)
    }
    fn read_bytes(&mut self, field: &'static str) -> ProtoResult<Vec<u8>> {
        let len = self.read_u32(field)? as usize;
        Ok(self.take(field, len)?.to_vec())
    }
    fn read_str(&mut self, field: &'static str) -> ProtoResult<String> {
        String::from_utf8(self.read_bytes(field)?).map_err(|_| ProtoError::InvalidUtf8 {
            packet_type: self.packet_type,
            field,
        })
    }
}
