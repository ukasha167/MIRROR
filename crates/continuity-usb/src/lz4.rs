//! Pure-Rust `lz4_flex`-compatible LZ4 block compressor and decompressor for ADB Sync v2.
//!
//! Used by ADB Sync v2 (`SND2`, `RCV2`, `DATA`) when `ADB_SYNC_FLAG_LZ4` is negotiated.

use crate::error::{Result, UsbError};

fn push_lz4_ext_len(out: &mut Vec<u8>, mut rem: usize) {
    while rem >= 255 {
        out.push(255);
        rem -= 255;
    }
    out.push(rem as u8);
}

/// Pure-Rust `lz4_flex`-compatible LZ4 block compressor for `SND2` / `RCV2` `DATA` frames.
pub fn lz4_compress_block(input: &[u8]) -> Vec<u8> {
    if input.is_empty() {
        return Vec::new();
    }
    let mut out = Vec::with_capacity(input.len() + (input.len() / 255) + 16);
    let mut dict = [0usize; 4096];
    let (mut anchor, mut ip, limit) = (0usize, 0usize, input.len().saturating_sub(12));
    while ip < limit {
        let seq = u32::from_le_bytes([input[ip], input[ip + 1], input[ip + 2], input[ip + 3]]);
        let hash = ((seq.wrapping_mul(2654435761)) >> 20) as usize & 0xFFF;
        let ref_pos = dict[hash];
        dict[hash] = ip;
        let offset = ip.saturating_sub(ref_pos);
        if offset > 0 && offset <= 0xFFFF && input[ref_pos..ref_pos + 4] == input[ip..ip + 4] {
            let lit_len = ip - anchor;
            let max_match = input.len().saturating_sub(5) - ip;
            let mut match_len = 4usize;
            while match_len < max_match && input[ref_pos + match_len] == input[ip + match_len] {
                match_len += 1;
            }
            out.push(((lit_len.min(15) as u8) << 4) | ((match_len - 4).min(15) as u8));
            if lit_len >= 15 {
                push_lz4_ext_len(&mut out, lit_len - 15);
            }
            out.extend_from_slice(&input[anchor..ip]);
            out.extend_from_slice(&(offset as u16).to_le_bytes());
            if match_len - 4 >= 15 {
                push_lz4_ext_len(&mut out, (match_len - 4) - 15);
            }
            ip += match_len;
            anchor = ip;
        } else {
            ip += 1;
        }
    }
    let tail_lit = input.len() - anchor;
    out.push((tail_lit.min(15) as u8) << 4);
    if tail_lit >= 15 {
        push_lz4_ext_len(&mut out, tail_lit - 15);
    }
    out.extend_from_slice(&input[anchor..]);
    out
}

fn read_lz4_ext_len(
    compressed: &[u8],
    ip: &mut usize,
    base: usize,
    reason: &'static str,
) -> Result<usize> {
    let mut len = base;
    if base == 15 {
        loop {
            if *ip >= compressed.len() {
                return Err(UsbError::Lz4FrameError {
                    reason,
                    offset: *ip,
                    expected_len: *ip + 1,
                    actual_len: compressed.len(),
                });
            }
            let s = usize::from(compressed[*ip]);
            *ip += 1;
            len += s;
            if s != 255 {
                break;
            }
        }
    }
    Ok(len)
}

/// Pure-Rust `lz4_flex`-compatible LZ4 block decompressor with strict bounds validation.
pub fn lz4_decompress_block(compressed: &[u8], max_output_len: usize) -> Result<Vec<u8>> {
    let mut out = Vec::with_capacity(max_output_len.min(65536));
    let mut ip = 0usize;
    while ip < compressed.len() {
        let token = compressed[ip];
        ip += 1;
        let lit_len = read_lz4_ext_len(
            compressed,
            &mut ip,
            usize::from(token >> 4),
            "truncated literal length",
        )?;
        if ip + lit_len > compressed.len() || out.len() + lit_len > max_output_len {
            return Err(UsbError::Lz4FrameError {
                reason: "literal run exceeds block bounds",
                offset: ip,
                expected_len: ip + lit_len,
                actual_len: compressed.len(),
            });
        }
        out.extend_from_slice(&compressed[ip..ip + lit_len]);
        ip += lit_len;
        if ip == compressed.len() {
            break;
        }
        if ip + 2 > compressed.len() {
            return Err(UsbError::Lz4FrameError {
                reason: "truncated 16-bit match offset",
                offset: ip,
                expected_len: ip + 2,
                actual_len: compressed.len(),
            });
        }
        let offset = usize::from(u16::from_le_bytes([compressed[ip], compressed[ip + 1]]));
        ip += 2;
        if offset == 0 || offset > out.len() {
            return Err(UsbError::Lz4FrameError {
                reason: "invalid match offset",
                offset: ip - 2,
                expected_len: offset,
                actual_len: out.len(),
            });
        }
        let match_len = read_lz4_ext_len(
            compressed,
            &mut ip,
            usize::from(token & 0x0F),
            "truncated match length",
        )? + 4;
        if out.len() + match_len > max_output_len {
            return Err(UsbError::Lz4FrameError {
                reason: "decompressed output exceeds max_output_len",
                offset: ip,
                expected_len: max_output_len,
                actual_len: out.len() + match_len,
            });
        }
        let match_start = out.len() - offset;
        for i in 0..match_len {
            out.push(out[match_start + i]);
        }
    }
    Ok(out)
}
