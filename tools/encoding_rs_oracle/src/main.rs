// Reference traces for Fathom's multi-byte decoders (src/fathom/whatwg/decoders.cr).
//
// Replays encoding_rs exactly the way chardetng drives its decoders: one byte per
// decode_to_utf16_without_replacement call into a two-unit buffer, then an empty
// final call with last=true. Every step is recorded as InputEmpty / Malformed(len,
// good) / OutputFull, whether the byte was consumed (`read`; shown as `~` when it
// wasn't, not recorded for the final call) and the UTF-16 units written.
//
//   cargo run --release -- fixture > ../../spec/fixtures/decoder_traces.tsv
//   cargo run --release -- hash ENC 3        # per-first-byte hash of all <=3-byte sequences
//   cargo run --release -- gb4               # per-lead hash of four-byte gb18030 sequences
//   cargo run --release -- dump ENC 3 81     # traces of all <=3-byte sequences starting with 0x81
//   cargo run --release -- trace ENC < hex   # one hex sequence per line
//
// ENC is SHIFT_JIS, EUC-JP, EUC-KR, BIG5, GBK or ISO-2022-JP.
use encoding_rs::*;
use std::io::{BufRead, Write};

fn enc(name: &str) -> &'static Encoding {
    match name {
        "SHIFT_JIS" => SHIFT_JIS, "EUC-JP" => EUC_JP, "EUC-KR" => EUC_KR,
        "BIG5" => BIG5, "GBK" => GBK, "ISO-2022-JP" => ISO_2022_JP,
        _ => panic!("unknown encoding {}", name),
    }
}

// One step: kind (0 empty, 1 malformed, 2 output full), malformed len, good len,
// written, two units, consumed (always 1 for the final call, which has no input).
fn step(d: &mut Decoder, src: &[u8], last: bool, out: &mut Vec<u8>) {
    let mut dst = [0u16; 2];
    let (r, read, written) = d.decode_to_utf16_without_replacement(src, &mut dst, last);
    let (k, a, b) = match r {
        DecoderResult::InputEmpty => (0u8, 0u8, 0u8),
        DecoderResult::Malformed(a, b) => (1, a, b),
        DecoderResult::OutputFull => (2, 0, 0),
    };
    out.extend_from_slice(&[k, a, b, written as u8]);
    for i in 0..2 { let u = if i < written { dst[i] } else { 0 }; out.extend_from_slice(&u.to_le_bytes()); }
    out.push(if last || read == src.len() { 1 } else { 0 });
}

fn trace(e: &'static Encoding, bytes: &[u8]) -> Vec<u8> {
    let mut d = e.new_decoder_without_bom_handling();
    let mut out = Vec::new();
    for &b in bytes { step(&mut d, &[b], false, &mut out); }
    step(&mut d, b"", true, &mut out);
    out
}

fn fnv(h: &mut u64, data: &[u8]) { for &x in data { *h ^= x as u64; *h = h.wrapping_mul(0x100000001b3); } }

fn text(t: &[u8]) -> String {
    t.chunks(9).map(|c| {
        let w = c[3] as usize;
        let units: Vec<String> = (0..w).map(|i| format!("{:04X}", u16::from_le_bytes([c[4 + 2 * i], c[5 + 2 * i]]))).collect();
        let unread = if c[8] == 0 { "~" } else { "" };
        match c[0] { 0 => format!("E{}[{}]", unread, units.join(",")), 1 => format!("M{}/{}{}[{}]", c[1], c[2], unread, units.join(",")), _ => format!("F{}", unread) }
    }).collect::<Vec<_>>().join(" ")
}

// All sequences of length 1..=len starting with `first`, in a fixed order.
fn each_seq(first: u8, len: usize, f: &mut dyn FnMut(&[u8])) {
    let mut seq = vec![first];
    fn rec(seq: &mut Vec<u8>, len: usize, f: &mut dyn FnMut(&[u8])) {
        f(seq);
        if seq.len() == len { return; }
        for b in 0..=255u8 { seq.push(b); rec(seq, len, f); seq.pop(); }
    }
    rec(&mut seq, len, f);
}


// Deterministic inputs for spec/fixtures/decoder_traces.tsv: lead/trail edge
// pairs, gb18030 four-byte edges, ISO-2022-JP escape fragments and biased
// pseudo-random sequences.
fn fixture_inputs(name: &str) -> Vec<Vec<u8>> {
    let mut v: Vec<Vec<u8>> = Vec::new();
    let leads = [0x00u8, 0x41, 0x7F, 0x80, 0x81, 0x87, 0x88, 0x8E, 0x8F, 0x9F, 0xA0, 0xA1, 0xA4, 0xC6, 0xC9, 0xDF, 0xE0, 0xEF, 0xF0, 0xF9, 0xFC, 0xFD, 0xFE, 0xFF];
    let trails = [0x00u8, 0x21, 0x30, 0x39, 0x3F, 0x40, 0x41, 0x5A, 0x62, 0x66, 0x7E, 0x7F, 0x80, 0x9F, 0xA0, 0xA1, 0xA2, 0xAF, 0xDF, 0xE0, 0xFC, 0xFD, 0xFE, 0xFF];
    for &l in &leads { v.push(vec![l]); for &t in &trails { v.push(vec![l, t]); v.push(vec![l, t, 0x41]); } }
    if name == "GBK" {
        for &a in &[0x81u8, 0x84, 0x90, 0xE3, 0xFE] { for &b in &[0x2Fu8, 0x30, 0x31, 0x39, 0x3A] {
            for &c in &[0x30u8, 0x80, 0x81, 0x87, 0x9A, 0xFE, 0xFF] { for &d in &[0x2Fu8, 0x30, 0x35, 0x39, 0x3A, 0x41] {
                v.push(vec![a, b, c, d]);
            }}
        }}
    }
    if name == "ISO-2022-JP" {
        let frags: [&[u8]; 12] = [b"\x1b$B", b"\x1b$@", b"\x1b(B", b"\x1b(J", b"\x1b(I", b"\x1b", b"\x1b$", b"\x1b(", b"$\"", b"\x0e", b"\x7e\x5c", b"!"];
        for a in frags.iter() { for b in frags.iter() { for c in frags[..8].iter() {
            let mut s = Vec::new(); s.extend_from_slice(a); s.extend_from_slice(b); s.extend_from_slice(c); v.push(s);
        }}}
    }
    let mut x: u64 = 0x9E3779B97F4A7C15 ^ (name.len() as u64);
    for _ in 0..250 {
        x ^= x << 13; x ^= x >> 7; x ^= x << 17;
        let n = 1 + (x % 24) as usize;
        let mut s = Vec::with_capacity(n);
        for _ in 0..n {
            x ^= x << 13; x ^= x >> 7; x ^= x << 17;
            let r = x % 100;
            s.push(if r < 40 { 0x20 + (x >> 8) as u8 % 0x5F } else if r < 85 { 0x81 + (x >> 8) as u8 % 0x7E } else if r < 93 { 0x30 + (x >> 8) as u8 % 10 } else { [0x80u8, 0xFF, 0x8E, 0x8F, 0xA0, 0x1B][(x >> 8) as usize % 6] });
        }
        v.push(s);
    }
    v
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let out = std::io::stdout();
    let mut out = std::io::BufWriter::new(out.lock());
    match args[1].as_str() {
        "hash" => {
            let e = enc(&args[2]); let len: usize = args[3].parse().unwrap();
            for first in 0..=255u8 {
                let mut h = 0xcbf29ce484222325u64;
                each_seq(first, len, &mut |s| { let t = trace(e, s); fnv(&mut h, &[s.len() as u8]); fnv(&mut h, &t); });
                writeln!(out, "{:02X} {:016X}", first, h).unwrap();
            }
        }
        "dump" => {
            let e = enc(&args[2]); let len: usize = args[3].parse().unwrap();
            let first = u8::from_str_radix(&args[4], 16).unwrap();
            each_seq(first, len, &mut |s| {
                let hex: String = s.iter().map(|b| format!("{:02X}", b)).collect();
                writeln!(out, "{} {}", hex, text(&trace(e, s))).unwrap();
            });
        }
        "gb4" => {
            let e = GBK;
            for first in 0x81..=0xFEu8 {
                let mut h = 0xcbf29ce484222325u64;
                for second in 0x2F..=0x3Au8 { for third in 0..=255u8 { for fourth in 0..=255u8 {
                    let t = trace(e, &[first, second, third, fourth]); fnv(&mut h, &t);
                }}}
                writeln!(out, "{:02X} {:016X}", first, h).unwrap();
            }
        }
        "fixture" => {
            for name in ["SHIFT_JIS", "EUC-JP", "EUC-KR", "BIG5", "GBK", "ISO-2022-JP"] {
                let e = enc(name);
                for s in fixture_inputs(name) {
                    let hex: String = s.iter().map(|b| format!("{:02X}", b)).collect();
                    writeln!(out, "{}	{}	{}", name, hex, text(&trace(e, &s))).unwrap();
                }
            }
        }
        "trace" => {
            let e = enc(&args[2]);
            for line in std::io::stdin().lock().lines() {
                let line = line.unwrap();
                let bytes: Vec<u8> = (0..line.len()).step_by(2).map(|i| u8::from_str_radix(&line[i..i + 2], 16).unwrap()).collect();
                writeln!(out, "{}", text(&trace(e, &bytes))).unwrap();
            }
        }
        _ => panic!("usage: fixture|hash|gb4|dump|trace"),
    }
}
