//! Fuzz and property tests for the agent's hand-written parsers (it has no JSON library): nothing the
//! host or the guest's own tools print may make them panic, and what the host encodes must come back
//! out unchanged. `TANDEM_FUZZ_SCALE=200 cargo test fuzz` for long runs, `TANDEM_FUZZ_SEED` to replay.
use crate::{activity, exec, filedrop, platform, shares, timeconv};

struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^ (z >> 31)
    }
    fn below(&mut self, n: usize) -> usize { if n == 0 { 0 } else { (self.next() % n as u64) as usize } }
    fn chance(&mut self, percent: u64) -> bool { self.next() % 100 < percent }

    /// Text that trips parsers: quotes, escapes (some broken), tabs, control characters, non-ASCII.
    fn awkward(&mut self, max: usize) -> String {
        const PIECES: [&str; 34] = ["\"", "\\", "\\\"", "\\u", "\\u00", "\\uD800", "\\uDBFF\\uDC00", "\\uD800\\u0041", "\\uZZZZ", "\\n",
            "\t", "\r\n", "\n", ":", ",", "{", "}", "[", "]", "%", "%2", "%zz", "%2F", "%00", "..", "/", "é", "日本", "🙂", "\u{feff}",
            "\u{0}", "tandem-drop 1", "999999999999999999999", "-1"];
        let mut s = String::new();
        for _ in 0..self.below(max + 1) {
            if self.chance(50) { s.push_str(PIECES[self.below(PIECES.len())]); } else { s.push((0x20 + self.below(0x5F) as u8) as char); }
        }
        s
    }

    fn mutate(&mut self, text: &str) -> String {
        let mut chars: Vec<char> = text.chars().collect();
        for _ in 0..1 + self.below(4) {
            match self.below(4) {
                0 if !chars.is_empty() => { let i = self.below(chars.len()); chars.remove(i); }
                1 => { let i = self.below(chars.len() + 1); let extra: Vec<char> = self.awkward(4).chars().collect(); chars.splice(i..i, extra); }
                2 => { let n = self.below(chars.len() + 1); chars.truncate(n); }
                _ if !chars.is_empty() => { let i = self.below(chars.len()); let j = self.below(chars.len()); chars.swap(i, j); }
                _ => {}
            }
        }
        chars.into_iter().collect()
    }
}

fn cases(base: usize, mut body: impl FnMut(&mut Rng, u64)) {
    let scale: usize = std::env::var("TANDEM_FUZZ_SCALE").ok().and_then(|s| s.parse().ok()).unwrap_or(1).max(1);
    let seed: u64 = std::env::var("TANDEM_FUZZ_SEED").ok().and_then(|s| s.parse().ok()).unwrap_or(0x7A4D_2026);
    for i in 0..base * scale {
        let case_seed = seed.wrapping_add((i as u64).wrapping_mul(0x2545_F491_4F6C_DD1D));
        body(&mut Rng(case_seed), case_seed);
    }
}

const EXEC_SAMPLE: &str = r#"{"command":"dir \"C:\\Program Files\"","maxOutput":65536,"timeout":30,"user":"u"}"#;
const SHARES_SAMPLE: &str = r#"{"kind":"webdav","port":8123,"shares":["Documents","My \"Files\"","日本"]}"#;
const DROP_SAMPLE: &str = "tandem-drop 1\nab12\t8123\tTandemDrop\nf\t11\tab12/a%20b.txt\nd\tab12/sub\nf\t0\tab12/sub/c.txt\n";

/// Every parser, on mutated samples and on noise: no panic.
#[test]
fn fuzz_parsers_never_panic() {
    cases(3000, |rng, _| {
        let text = match rng.below(5) {
            0 => rng.mutate(EXEC_SAMPLE),
            1 => rng.mutate(SHARES_SAMPLE),
            2 => rng.mutate(DROP_SAMPLE),
            3 => rng.awkward(60),
            _ => String::from_utf8_lossy(&(0..rng.below(200)).map(|_| rng.next() as u8).collect::<Vec<u8>>()).into_owned(),
        };
        let _ = exec::parse(&text, rng.next() as u32);
        let _ = shares::parse(&text);
        let _ = filedrop::parse(&text);
        let _ = filedrop::percent_decode(&text);
        let _ = platform::ProgramInfo::parse(&text);
        let _ = platform::parse_launch_steps(&text);
        let _ = platform::parse_program_lines(&text);
        let _ = activity::parse_power_requests(&text);
        let _ = activity::parse_proc_stat(&text);
        let _ = activity::parse_inhibitors(&text);
    });
}

/// A command the host encodes as JSON comes back as typed, whatever is in it.
#[test]
fn fuzz_exec_command_round_trips() {
    cases(3000, |rng, seed| {
        let mut command = rng.awkward(40);
        if rng.chance(20) { command.push(char::from_u32(0x10000 + rng.below(0xF0000) as u32).unwrap_or('x')); }
        let json = serde_json::json!({ "command": command, "timeout": rng.next() % 5000, "maxOutput": rng.next() }).to_string();
        let parsed = exec::parse(&json, 0);
        if command.trim().is_empty() {
            assert!(parsed.is_none(), "seed {seed}");
        } else {
            let parsed = parsed.unwrap_or_else(|| panic!("seed {seed}: {json}"));
            assert_eq!(parsed.command, command, "seed {seed}");
            assert!(parsed.timeout.as_secs() >= 1 && parsed.timeout.as_secs() <= 3600, "seed {seed}");
        }
    });
}

/// Regression (fuzzer): a high surrogate followed by a \u that is not a low one subtracted below zero.
#[test]
fn broken_surrogate_pair_is_refused() {
    assert!(exec::parse(r#"{"command":"a\uD800\u0041"}"#, 0).is_none());
    assert!(exec::parse(r#"{"command":"a\uDC00"}"#, 0).is_none());
    assert_eq!(exec::parse(r#"{"command":"\uD83D\uDE42"}"#, 0).map(|r| r.command), Some("🙂".to_string()));
}

/// What the agent writes as JSON is JSON, and reads back as the text it was given.
#[test]
fn fuzz_json_string_round_trips() {
    cases(3000, |rng, seed| {
        let mut text = rng.awkward(40);
        for _ in 0..rng.below(3) { text.push(char::from_u32(rng.below(0x110000) as u32).unwrap_or('\u{7f}')); }
        let encoded = platform::json_string(&text);
        let back: String = serde_json::from_str(&encoded).unwrap_or_else(|e| panic!("seed {seed}: {e}: {encoded:?}"));
        assert_eq!(back, text, "seed {seed}");
    });
}

/// Percent-encoding and decoding are inverses, and no drop item climbs out of its drop.
#[test]
fn fuzz_drop_paths_stay_inside_the_drop() {
    cases(3000, |rng, seed| {
        let name = rng.awkward(20);
        assert_eq!(filedrop::percent_decode(&filedrop::percent_encode(&name)).as_deref(), Some(name.as_str()), "seed {seed}");
        let manifest = format!("tandem-drop 1\nab12\t8123\tTandemDrop\nf\t1\t{}\n", if rng.chance(50) { filedrop::percent_encode(&format!("ab12/{name}")) } else { name.clone() });
        if let Some(m) = filedrop::parse(&manifest) {
            for item in m.items {
                let decoded = filedrop::percent_decode(&item.path).unwrap();
                let mut parts = decoded.split('/');
                assert_eq!(parts.next(), Some("ab12"), "seed {seed}");
                assert!(parts.all(|p| !p.is_empty() && p != ".." && p != "." && !p.contains('\\') && !p.contains(':')), "seed {seed}: {decoded}");
            }
        }
    });
}

#[test]
fn fuzz_calendar_conversion_round_trips() {
    cases(5000, |rng, seed| {
        // Any time the host could send, and the extremes.
        let secs = if rng.chance(10) { [i64::MIN, i64::MAX, 0, -1][rng.below(4)] } else { (rng.next() % 20_000_000_000) as i64 - 5_000_000_000 };
        let c = timeconv::civil_from_unix(secs);
        if (-5_000_000_000..15_000_000_000).contains(&secs) {
            assert_eq!(timeconv::unix_from_civil(c.year, c.month, c.day, c.hour, c.minute, c.second), secs, "seed {seed}");
            assert!((1..=12).contains(&c.month) && (1..=31).contains(&c.day) && c.weekday < 7, "seed {seed}");
        }
    });
}
