//! Fuzz and property tests for the frame codec: random, truncated, oversized and damaged frames must
//! never panic, and every frame the decoder accepts must be one the encoder could have written.
//! Short by default; `TANDEM_FUZZ_SCALE=200 cargo test fuzz` for long runs, `TANDEM_FUZZ_SEED` to replay.
use crate::frame::{crc32, Buffer, Decoder, Frame, FLAG_IN, FLAG_OUT, HEADER_SIZE, KIND_REPLY, KIND_REQUEST, MAGIC, MAX_BUFFERS, MAX_FRAME_SIZE};

pub(crate) struct Rng(u64);

impl Rng {
    pub fn new(seed: u64) -> Rng { Rng(seed) }
    /// SplitMix64, as the host's tests use.
    pub fn next(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^ (z >> 31)
    }
    pub fn below(&mut self, n: usize) -> usize { if n == 0 { 0 } else { (self.next() % n as u64) as usize } }
    pub fn chance(&mut self, percent: u64) -> bool { self.next() % 100 < percent }
    pub fn bytes(&mut self, n: usize) -> Vec<u8> { (0..n).map(|_| self.next() as u8).collect() }
    pub fn interesting32(&mut self) -> u32 {
        const V: [u32; 16] = [0, 1, 3, 4, 7, 8, 16, 255, 256, 65535, 65536, 0x7FFF_FFFF, 0x8000_0000, 0xFFFF_FFFF, 16 << 20, (16 << 20) + 1];
        if self.chance(70) { V[self.below(V.len())] } else { self.next() as u32 }
    }
}

pub(crate) fn scale() -> usize {
    std::env::var("TANDEM_FUZZ_SCALE").ok().and_then(|s| s.parse().ok()).unwrap_or(1).max(1)
}

pub(crate) fn seed() -> u64 {
    std::env::var("TANDEM_FUZZ_SEED").ok().and_then(|s| s.parse().ok()).unwrap_or(0x7A4D_2026)
}

/// Runs `body` `base × TANDEM_FUZZ_SCALE` times, each with its own generator.
pub(crate) fn cases(base: usize, mut body: impl FnMut(&mut Rng, u64)) {
    for i in 0..base * scale() {
        let case_seed = seed().wrapping_add((i as u64).wrapping_mul(0x2545_F491_4F6C_DD1D));
        body(&mut Rng::new(case_seed), case_seed);
    }
}

fn random_frame(rng: &mut Rng) -> Frame {
    let kind = if rng.chance(50) { KIND_REQUEST } else { KIND_REPLY };
    let payload_flag = if kind == KIND_REPLY { FLAG_OUT } else { FLAG_IN };
    let buffers = (0..rng.below(MAX_BUFFERS + 1)).map(|_| {
        let flags = [FLAG_IN, FLAG_OUT, 0, 3, rng.interesting32()][rng.below(5)];
        if flags & payload_flag != 0 {
            let n = rng.below(300); let data = rng.bytes(n);
            Buffer { flags, length: data.len() as u32, data: Some(data) }
        } else {
            Buffer { flags, length: rng.interesting32(), data: None }
        }
    }).collect();
    Frame { request_id: rng.next(), kind, opcode: rng.next() as u16, status: rng.interesting32(), inline: { let n = rng.below(41); rng.bytes(n) }, buffers }
}

fn feed_in_pieces(d: &mut Decoder, data: &[u8], rng: &mut Rng, stalls: bool) -> Vec<Frame> {
    let mut frames = Vec::new();
    let mut at = 0;
    while at < data.len() {
        let max = if rng.chance(30) { 7 } else { 4096 };
        let n = (1 + rng.below(max)).min(data.len() - at);
        frames.extend(d.feed(&data[at..at + n]));
        at += n;
        if stalls && rng.chance(2) { frames.extend(d.resync_after_stall()); }
    }
    frames
}

fn mutate(data: &mut Vec<u8>, rng: &mut Rng) {
    for _ in 0..1 + rng.below(4) {
        match rng.below(6) {
            0 if !data.is_empty() => { let i = rng.below(data.len()); data[i] ^= 1 << rng.below(8); }
            1 if !data.is_empty() => { let i = rng.below(data.len()); data[i] = [0, 0xFF, 0x7F, 0x80][rng.below(4)]; }
            2 => { let at = rng.below(data.len() + 1); let n = 1 + rng.below(16); let extra = rng.bytes(n); data.splice(at..at, extra); }
            3 if !data.is_empty() => { let at = rng.below(data.len()); let n = (1 + rng.below(16)).min(data.len() - at); data.drain(at..at + n); }
            4 => { let n = rng.below(data.len() + 1); data.truncate(n); }
            5 if data.len() >= 4 => { let at = rng.below(data.len() - 3); data[at..at + 4].copy_from_slice(&rng.interesting32().to_le_bytes()); }
            _ => {}
        }
    }
}

#[test]
fn fuzz_random_frames_round_trip_in_any_pieces() {
    cases(400, |rng, seed| {
        let frames: Vec<Frame> = (0..1 + rng.below(4)).map(|_| random_frame(rng)).collect();
        let bytes: Vec<u8> = frames.iter().flat_map(|f| f.encode()).collect();
        let mut d = Decoder::new();
        assert_eq!(feed_in_pieces(&mut d, &bytes, rng, false), frames, "seed {seed}");
        assert_eq!(d.discarded_bytes, 0, "seed {seed}");
        assert!(!d.has_partial_frame(), "seed {seed}");
    });
}

#[test]
fn fuzz_random_bytes_never_panic() {
    cases(300, |rng, seed| {
        let n = rng.below(4000); let mut data = rng.bytes(n);
        for _ in 0..rng.below(7) {
            if data.len() >= 4 { let at = rng.below(data.len() - 3); data[at..at + 4].copy_from_slice(&MAGIC.to_le_bytes()); }
        }
        let mut d = Decoder::new();
        feed_in_pieces(&mut d, &data, rng, true);
        d.resync_after_stall();
        assert!(d.discarded_bytes <= data.len(), "seed {seed}");
    });
}

/// Damaged frames with a repaired CRC, so the structural checks behind it are the ones that must hold.
#[test]
fn fuzz_mutated_frames_with_repaired_crc() {
    cases(1500, |rng, seed| {
        let mut bytes = random_frame(rng).encode();
        if rng.chance(50) {
            let field = [4usize, 16, 24, 28][rng.below(4)];
            let value = rng.interesting32().to_le_bytes();
            let width = if field == 16 || field == 28 { 2 } else { 4 };
            bytes[field..field + width].copy_from_slice(&value[..width]);
        } else {
            mutate(&mut bytes, rng);
        }
        if bytes.len() >= HEADER_SIZE + 4 && rng.chance(90) {
            let total = u32::from_le_bytes([bytes[4], bytes[5], bytes[6], bytes[7]]) as usize;
            if total >= HEADER_SIZE + 4 && total <= bytes.len() {
                let crc = crc32(&bytes[..total - 4]);
                bytes[total - 4..total].copy_from_slice(&crc.to_le_bytes());
            }
        }
        let mut d = Decoder::new();
        for frame in feed_in_pieces(&mut d, &bytes, rng, true) {
            assert!(frame.buffers.len() <= MAX_BUFFERS, "seed {seed}");
            assert_eq!(Decoder::new().feed(&frame.encode()), vec![frame.clone()], "seed {seed}: a decoded frame must re-encode to itself");
        }
    });
}

/// A header claiming the largest frame keeps the decoder waiting until the stall rule lets it go.
#[test]
fn largest_claimed_frame_is_abandoned_by_the_stall_rule() {
    let mut header = Frame::request(1, 1, vec![], vec![]).encode();
    header[4..8].copy_from_slice(&(MAX_FRAME_SIZE as u32).to_le_bytes());
    let mut d = Decoder::new();
    assert!(d.feed(&header).is_empty());
    assert!(d.has_partial_frame());
    let good = Frame::request(2, 5, vec![], vec![]);
    let mut frames = d.resync_after_stall();
    frames.extend(d.feed(&good.encode()));
    assert_eq!(frames, vec![good]);
}
