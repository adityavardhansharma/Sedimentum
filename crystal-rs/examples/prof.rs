//! A small workload for profiling: seed messages, then recent reads.
use crystal::{Crystal, Options, RememberOptions};
fn splitmix(state: &mut u64) -> u64 {
    *state = state.wrapping_add(0x9E37_79B9_7F4A_7C15);
    let mut z = *state;
    z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
    z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
    z ^ (z >> 31)
}
const W: [&str; 16] = ["the", "user", "wants", "to", "deploy", "service", "on", "friday", "because", "tests", "pass", "billing", "invoice", "march", "late", "check"];
fn main() {
    let dir = std::env::args().nth(1).unwrap();
    let n: u64 = std::env::args().nth(2).map(|v| v.parse().unwrap()).unwrap_or(100_000);
    let h = Crystal::open(&dir, Options { sync_writes: false, ..Default::default() }).unwrap();
    let mut s = 1u64;
    let mut buf = String::new();
    let t = std::time::Instant::now();
    for i in 0..n {
        buf.clear();
        let target = 60 + splitmix(&mut s) % 840;
        buf.push_str(&format!("{{\"role\":\"user\",\"t\":{},\"text\":\"", i));
        while (buf.len() as u64) < target {
            buf.push_str(W[(splitmix(&mut s) % 16) as usize]);
            buf.push(' ');
        }
        h.remember(format!("chat/{:05}", splitmix(&mut s) % 5000).as_bytes(), buf.as_bytes(), RememberOptions { subject: None, time: Some(1_700_000_000_000 + i) }).unwrap();
    }
    let w = t.elapsed();
    let t = std::time::Instant::now();
    let mut k = 0;
    for _ in 0..n / 10 {
        k += h.recent(format!("chat/{:05}", splitmix(&mut s) % 500).as_bytes(), 20).unwrap().len();
    }
    eprintln!("writes {:?} reads {:?} ({})", w, t.elapsed(), k);
}
