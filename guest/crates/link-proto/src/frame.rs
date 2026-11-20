//! Frame codec. Mirrors `host/Sources/GuestLink/Frame.swift`; both are tested on `protocol/vectors.json`.

pub const MAGIC: u32 = 0x4B4E_4C42;
pub const HEADER_SIZE: usize = 32;
pub const MAX_FRAME_SIZE: usize = 16 << 20;
pub const MAX_BUFFERS: usize = 16;
pub const FLAG_IN: u32 = 1;
pub const FLAG_OUT: u32 = 2;
pub const KIND_REQUEST: u16 = 1;
pub const KIND_REPLY: u16 = 2;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Buffer {
    pub flags: u32,
    /// Payload size when a payload is present, otherwise the capacity offered.
    pub length: u32,
    pub data: Option<Vec<u8>>,
}

impl Buffer {
    pub fn input(data: &[u8]) -> Buffer {
        Buffer { flags: FLAG_IN, length: data.len() as u32, data: Some(data.to_vec()) }
    }
    pub fn output(capacity: usize) -> Buffer {
        Buffer { flags: FLAG_OUT, length: capacity as u32, data: None }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Frame {
    pub request_id: u64,
    pub kind: u16,
    pub opcode: u16,
    pub status: u32,
    pub inline: Vec<u8>,
    pub buffers: Vec<Buffer>,
}

impl Frame {
    pub fn request(request_id: u64, opcode: u16, inline: Vec<u8>, buffers: Vec<Buffer>) -> Frame {
        Frame { request_id, kind: KIND_REQUEST, opcode, status: crate::status::PENDING, inline, buffers }
    }

    fn payload_flag(kind: u16) -> u32 {
        if kind == KIND_REPLY { FLAG_OUT } else { FLAG_IN }
    }

    pub fn encode(&self) -> Vec<u8> {
        let flag = Self::payload_flag(self.kind);
        let pad = (8 - self.inline.len() % 8) % 8;
        let mut descriptors = Vec::with_capacity(self.buffers.len() * 8);
        let mut payloads = Vec::new();
        for b in &self.buffers {
            let present = b.flags & flag != 0;
            let data: &[u8] = if present { b.data.as_deref().unwrap_or(&[]) } else { &[] };
            let length = if present { data.len() as u32 } else { b.length };
            descriptors.extend_from_slice(&length.to_le_bytes());
            descriptors.extend_from_slice(&b.flags.to_le_bytes());
            payloads.extend_from_slice(data);
        }
        let total = HEADER_SIZE + self.inline.len() + pad + descriptors.len() + payloads.len() + 4;
        let mut out = Vec::with_capacity(total);
        out.extend_from_slice(&MAGIC.to_le_bytes());
        out.extend_from_slice(&(total as u32).to_le_bytes());
        out.extend_from_slice(&self.request_id.to_le_bytes());
        out.extend_from_slice(&self.kind.to_le_bytes());
        out.extend_from_slice(&self.opcode.to_le_bytes());
        out.extend_from_slice(&self.status.to_le_bytes());
        out.extend_from_slice(&(self.inline.len() as u32).to_le_bytes());
        out.extend_from_slice(&(self.buffers.len() as u16).to_le_bytes());
        out.extend_from_slice(&0u16.to_le_bytes());
        out.extend_from_slice(&self.inline);
        out.resize(out.len() + pad, 0);
        out.extend_from_slice(&descriptors);
        out.extend_from_slice(&payloads);
        let crc = crc32(&out);
        out.extend_from_slice(&crc.to_le_bytes());
        out
    }
}

/// CRC-32 (IEEE 802.3), the same function as zlib's `crc32`.
pub fn crc32(data: &[u8]) -> u32 {
    let mut crc = 0xFFFF_FFFFu32;
    for &byte in data {
        crc ^= byte as u32;
        for _ in 0..8 {
            let mask = (crc & 1).wrapping_neg();
            crc = (crc >> 1) ^ (0xEDB8_8320 & mask);
        }
    }
    !crc
}

fn u16_at(b: &[u8], o: usize) -> u16 { u16::from_le_bytes([b[o], b[o + 1]]) }
fn u32_at(b: &[u8], o: usize) -> u32 { u32::from_le_bytes([b[o], b[o + 1], b[o + 2], b[o + 3]]) }
fn u64_at(b: &[u8], o: usize) -> u64 {
    let mut a = [0u8; 8];
    a.copy_from_slice(&b[o..o + 8]);
    u64::from_le_bytes(a)
}

enum Parse { Frame(Frame, usize), NeedMore, Garbage }

/// Incremental decoder that resynchronises on garbage (PROTOCOL.md §2).
#[derive(Default)]
pub struct Decoder {
    pending: Vec<u8>,
    pub discarded_bytes: usize,
}

impl Decoder {
    pub fn new() -> Decoder { Decoder::default() }

    pub fn has_partial_frame(&self) -> bool { !self.pending.is_empty() }

    pub fn feed(&mut self, data: &[u8]) -> Vec<Frame> {
        self.pending.extend_from_slice(data);
        let mut frames = Vec::new();
        loop {
            match self.parse_one() {
                Parse::Frame(frame, size) => {
                    frames.push(frame);
                    self.pending.drain(..size);
                }
                Parse::NeedMore => return frames,
                Parse::Garbage => {
                    self.pending.drain(..1);
                    self.discarded_bytes += 1;
                    self.skip_to_magic();
                }
            }
        }
    }

    /// The stall rule: give up on an incomplete frame and search for the next one.
    pub fn resync_after_stall(&mut self) -> Vec<Frame> {
        if self.pending.is_empty() { return Vec::new(); }
        self.pending.drain(..1);
        self.discarded_bytes += 1;
        self.skip_to_magic();
        self.feed(&[])
    }

    fn skip_to_magic(&mut self) {
        let magic = MAGIC.to_le_bytes();
        match self.pending.windows(4).position(|w| w == magic) {
            Some(pos) => {
                self.discarded_bytes += pos;
                self.pending.drain(..pos);
            }
            None => {
                // Keep the last 3 bytes: they may start a magic split across reads.
                let keep = self.pending.len().min(3);
                let drop = self.pending.len() - keep;
                self.discarded_bytes += drop;
                self.pending.drain(..drop);
            }
        }
    }

    fn parse_one(&self) -> Parse {
        let p = &self.pending;
        if p.len() < 4 { return Parse::NeedMore; }
        if u32_at(p, 0) != MAGIC { return Parse::Garbage; }
        if p.len() < HEADER_SIZE { return Parse::NeedMore; }
        let total = u32_at(p, 4) as usize;
        let kind = u16_at(p, 16);
        let inline_len = u32_at(p, 24) as usize;
        let count = u16_at(p, 28) as usize;
        if (kind != KIND_REQUEST && kind != KIND_REPLY) || total < HEADER_SIZE + 4 || total > MAX_FRAME_SIZE || count > MAX_BUFFERS {
            return Parse::Garbage;
        }
        let descriptors_at = HEADER_SIZE + inline_len + (8 - inline_len % 8) % 8;
        let payloads_at = descriptors_at + 8 * count;
        if payloads_at + 4 > total { return Parse::Garbage; }
        if p.len() < total { return Parse::NeedMore; }
        let body_end = total - 4;
        if crc32(&p[..body_end]) != u32_at(p, body_end) { return Parse::Garbage; }

        let flag = Frame::payload_flag(kind);
        let mut buffers = Vec::with_capacity(count);
        let mut offset = payloads_at;
        for i in 0..count {
            let length = u32_at(p, descriptors_at + 8 * i);
            let flags = u32_at(p, descriptors_at + 8 * i + 4);
            let mut data = None;
            if flags & flag != 0 {
                let end = offset + length as usize;
                if end > body_end { return Parse::Garbage; }
                data = Some(p[offset..end].to_vec());
                offset = end;
            }
            buffers.push(Buffer { flags, length, data });
        }
        if offset != body_end { return Parse::Garbage; }
        let frame = Frame {
            request_id: u64_at(p, 8),
            kind,
            opcode: u16_at(p, 18),
            status: u32_at(p, 20),
            inline: p[HEADER_SIZE..HEADER_SIZE + inline_len].to_vec(),
            buffers,
        };
        Parse::Frame(frame, total)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn unhex(s: &str) -> Vec<u8> {
        (0..s.len()).step_by(2).map(|i| u8::from_str_radix(&s[i..i + 2], 16).unwrap()).collect()
    }

    /// The shared vectors produced by protocol/gen_vectors.py.
    fn vectors() -> Vec<(String, Frame, Vec<u8>)> {
        let path = concat!(env!("CARGO_MANIFEST_DIR"), "/../../../protocol/vectors.json");
        let raw: serde_json::Value = serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap();
        raw.as_array().unwrap().iter().map(|v| {
            let f = &v["frame"];
            let kind = f["kind"].as_u64().unwrap() as u16;
            let flag = Frame::payload_flag(kind);
            let buffers = f["buffers"].as_array().unwrap().iter().map(|b| {
                let flags = b["flags"].as_u64().unwrap() as u32;
                let present = flags & flag != 0;
                Buffer {
                    flags,
                    length: b["length"].as_u64().unwrap() as u32,
                    data: if present { Some(unhex(b["data"].as_str().unwrap_or(""))) } else { None },
                }
            }).collect();
            let frame = Frame {
                request_id: f["requestId"].as_u64().unwrap(),
                kind,
                opcode: f["opcode"].as_u64().unwrap() as u16,
                status: f["status"].as_u64().unwrap() as u32,
                inline: unhex(f["inline"].as_str().unwrap()),
                buffers,
            };
            (v["name"].as_str().unwrap().to_string(), frame, unhex(v["hex"].as_str().unwrap()))
        }).collect()
    }

    #[test]
    fn crc_matches_zlib_check_value() {
        assert_eq!(crc32(b"123456789"), 0xCBF4_3926);
    }

    #[test]
    fn encode_matches_golden_vectors() {
        let v = vectors();
        assert_eq!(v.len(), 12);
        for (name, frame, bytes) in v { assert_eq!(frame.encode(), bytes, "{name}"); }
    }

    #[test]
    fn decode_matches_golden_vectors() {
        for (name, frame, bytes) in vectors() {
            let mut d = Decoder::new();
            assert_eq!(d.feed(&bytes), vec![frame], "{name}");
            assert_eq!(d.discarded_bytes, 0);
        }
    }

    #[test]
    fn decode_byte_at_a_time_and_concatenated() {
        let v = vectors();
        let all: Vec<u8> = v.iter().flat_map(|x| x.2.clone()).collect();
        let expected: Vec<Frame> = v.iter().map(|x| x.1.clone()).collect();
        assert_eq!(Decoder::new().feed(&all), expected);
        let mut d = Decoder::new();
        let mut frames = Vec::new();
        for b in &all { frames.extend(d.feed(&[*b])); }
        assert_eq!(frames, expected);
    }

    #[test]
    fn resync_after_garbage() {
        let v = vectors();
        let junk = [0xDE, 0xAD, 0xBE, 0xEF, 0x42, 0x4C];
        let mut stream = junk.to_vec();
        stream.extend(&v[1].2);
        stream.extend(junk);
        stream.extend(&v[2].2);
        let mut d = Decoder::new();
        assert_eq!(d.feed(&stream), vec![v[1].1.clone(), v[2].1.clone()]);
        assert_eq!(d.discarded_bytes, 12);
    }

    #[test]
    fn truncated_frame_recovers_by_stall_rule() {
        let v = vectors();
        let mut stream = v[6].2[..40].to_vec();
        stream.extend(&v[1].2);
        let mut d = Decoder::new();
        assert!(d.feed(&stream).is_empty());
        assert!(d.has_partial_frame());
        assert_eq!(d.resync_after_stall(), vec![v[1].1.clone()]);
        assert!(!d.has_partial_frame());
    }

    #[test]
    fn truncated_frame_recovers_by_crc() {
        let v = vectors();
        let mut stream = v[1].2[..40].to_vec();
        stream.extend(&v[2].2);
        stream.extend(&v[3].2);
        assert_eq!(Decoder::new().feed(&stream), vec![v[2].1.clone(), v[3].1.clone()]);
    }

    #[test]
    fn corrupted_byte_is_rejected() {
        let v = vectors();
        let mut bytes = v[5].2.clone();
        let n = bytes.len();
        bytes[n - 6] ^= 1;
        bytes.extend(&v[0].2);
        assert_eq!(Decoder::new().feed(&bytes), vec![v[0].1.clone()]);
    }

    #[test]
    fn oversize_frame_is_rejected() {
        let mut bytes = Frame::request(1, 1, vec![], vec![]).encode();
        bytes[4..8].copy_from_slice(&((16u32 << 20) + 1).to_le_bytes());
        let mut d = Decoder::new();
        assert!(d.feed(&bytes).is_empty());
        assert!(d.discarded_bytes > 0);
    }
}
