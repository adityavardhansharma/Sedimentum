//! kiban side of the Sedimentum benchmark. Keep the workloads in step with
//! `src/bench.zig`: same keys, values, order and phases.

use kiban::db::{KibanOptions, SharedKiban};
use std::path::Path;
use std::sync::Arc;
use std::time::Instant;

const AGENTS: u64 = 64;
const VALUE_LEN: usize = 200;
const PREFIX_LEN: usize = "agent/0000/".len();

fn splitmix(state: &mut u64) -> u64 {
    *state = state.wrapping_add(0x9E3779B97F4A7C15);
    let mut z = *state;
    z = (z ^ (z >> 30)).wrapping_mul(0xBF58476D1CE4E5B9);
    z = (z ^ (z >> 27)).wrapping_mul(0x94D049BB133111EB);
    z ^ (z >> 31)
}

/// kiban's own agent-memory key: newest memory sorts first in its agent.
fn key(id: u64) -> Vec<u8> {
    format!("agent/{:04}/memory/{:020}", id % AGENTS, u64::MAX - id).into_bytes()
}

fn agent_prefix(agent: u64) -> Vec<u8> {
    format!("agent/{:04}/", agent).into_bytes()
}

fn prefix_end(prefix: &[u8]) -> Vec<u8> {
    let mut end = prefix.to_vec();
    *end.last_mut().unwrap() += 1;
    end
}

fn value(id: u64, round: u64) -> Vec<u8> {
    let mut s = id.wrapping_mul(31).wrapping_add(round);
    let mut v = Vec::with_capacity(VALUE_LEN);
    while v.len() < VALUE_LEN {
        v.extend_from_slice(&splitmix(&mut s).to_le_bytes());
    }
    v.truncate(VALUE_LEN);
    v
}

fn shuffled(n: u64, seed: u64) -> Vec<u64> {
    let mut ids: Vec<u64> = (0..n).collect();
    let mut s = seed;
    for i in (1..ids.len()).rev() {
        let j = (splitmix(&mut s) % (i as u64 + 1)) as usize;
        ids.swap(i, j);
    }
    ids
}

fn dir_bytes(dir: &Path) -> u64 {
    std::fs::read_dir(dir)
        .map(|rd| rd.filter_map(|e| e.ok()).filter_map(|e| e.metadata().ok()).filter(|m| m.is_file()).map(|m| m.len()).sum())
        .unwrap_or(0)
}

fn max_rss_kb() -> u64 {
    std::fs::read_to_string("/proc/self/status")
        .ok()
        .and_then(|s| s.lines().find(|l| l.starts_with("VmHWM:")).map(|l| l.split_whitespace().nth(1).unwrap().parse().unwrap()))
        .unwrap_or(0)
}

struct Lat(Vec<u64>);
impl Lat {
    fn pct(&mut self, p: f64) -> u64 {
        if self.0.is_empty() {
            return 0;
        }
        self.0.sort_unstable();
        self.0[((self.0.len() - 1) as f64 * p) as usize]
    }
}

fn report(phase: &str, ops: u64, secs: f64, lat: Option<&mut Lat>, extra: &str) {
    let (p50, p99) = match lat {
        Some(l) => (l.pct(0.50), l.pct(0.99)),
        None => (0, 0),
    };
    println!(
        "{{\"engine\":\"kiban\",\"phase\":\"{phase}\",\"ops\":{ops},\"seconds\":{secs:.6},\"ops_per_sec\":{:.1},\"p50_ns\":{p50},\"p99_ns\":{p99}{extra}}}",
        ops as f64 / secs
    );
}

fn open(dir: &Path) -> SharedKiban {
    SharedKiban::open_with_options(dir, KibanOptions::agent_memory(PREFIX_LEN)).expect("open")
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let dir = Path::new(&args[1]).to_path_buf();
    let n: u64 = args.get(2).map(|s| s.parse().unwrap()).unwrap_or(1_000_000);
    let _ = std::fs::remove_dir_all(&dir);
    let mut db = open(&dir);

    // load: n buffered puts in random order, then one sync.
    let order = shuffled(n, 1);
    let t = Instant::now();
    for &id in &order {
        db.put(key(id), value(id, 0)).unwrap();
    }
    db.sync().unwrap();
    report("load", n, t.elapsed().as_secs_f64(), None, &format!(",\"rss_kb\":{}", max_rss_kb()));

    let t = Instant::now();
    db.checkpoint().unwrap();
    report("settle", 1, t.elapsed().as_secs_f64(), None, &format!(",\"disk_bytes\":{}", dir_bytes(&dir)));

    let t = Instant::now();
    db.close().unwrap();
    db = open(&dir);
    report("reopen", 1, t.elapsed().as_secs_f64(), None, "");

    // get_hit / get_miss
    let mut s = 7u64;
    let mut lat = Lat(Vec::with_capacity(n as usize));
    let t = Instant::now();
    for _ in 0..n {
        let id = splitmix(&mut s) % n;
        let k = key(id);
        let a = Instant::now();
        let v = db.get(&k).unwrap();
        lat.0.push(a.elapsed().as_nanos() as u64);
        assert!(v.is_some());
    }
    report("get_hit", n, t.elapsed().as_secs_f64(), Some(&mut lat), "");

    let mut lat = Lat(Vec::with_capacity(n as usize));
    let t = Instant::now();
    for _ in 0..n {
        let id = n + splitmix(&mut s) % n;
        let k = key(id);
        let a = Instant::now();
        let v = db.get(&k).unwrap();
        lat.0.push(a.elapsed().as_nanos() as u64);
        assert!(v.is_none());
    }
    report("get_miss", n, t.elapsed().as_secs_f64(), Some(&mut lat), "");

    // latest10: newest 10 memories of a random agent (first 10 in key order).
    let queries = 100_000u64;
    let mut lat = Lat(Vec::with_capacity(queries as usize));
    let t = Instant::now();
    for _ in 0..queries {
        let p = agent_prefix(splitmix(&mut s) % AGENTS);
        let end = prefix_end(&p);
        let a = Instant::now();
        let got: Vec<Vec<u8>> = db
            .snapshot()
            .unwrap()
            .range_values(&p, &end, 10, |v| Ok::<_, kiban::db::DbError>(v.to_vec()))
            .unwrap();
        lat.0.push(a.elapsed().as_nanos() as u64);
        assert_eq!(got.len(), 10);
    }
    report("latest10", queries, t.elapsed().as_secs_f64(), Some(&mut lat), "");

    // last10_by_key: the 10 greatest keys under an agent. kiban has no
    // reverse iterator, so it has to walk the whole agent range.
    let queries = 200u64;
    let mut lat = Lat(Vec::with_capacity(queries as usize));
    let t = Instant::now();
    for _ in 0..queries {
        let p = agent_prefix(splitmix(&mut s) % AGENTS);
        let end = prefix_end(&p);
        let a = Instant::now();
        let snap = db.snapshot().unwrap();
        let mut ring: std::collections::VecDeque<(Vec<u8>, Vec<u8>)> = std::collections::VecDeque::with_capacity(11);
        for e in snap.range(&p, &end) {
            let (k, v) = e.unwrap();
            ring.push_back((k.to_vec(), v.to_vec()));
            if ring.len() > 10 {
                ring.pop_front();
            }
        }
        lat.0.push(a.elapsed().as_nanos() as u64);
        assert_eq!(ring.len(), 10);
    }
    report("last10_by_key", queries, t.elapsed().as_secs_f64(), Some(&mut lat), "");

    // scan_all: every key and value in order.
    let t = Instant::now();
    let snap = db.snapshot().unwrap();
    let mut count = 0u64;
    let mut bytes = 0usize;
    for e in snap.iter() {
        let (k, v) = e.unwrap();
        bytes += k.len() + v.len();
        count += 1;
    }
    drop(snap);
    assert_eq!(count, n);
    report("scan_all", n, t.elapsed().as_secs_f64(), None, &format!(",\"bytes\":{bytes}"));

    // get_hit_4threads
    let threads = 4u64;
    let per = n / threads;
    let shared = Arc::new(db);
    let t = Instant::now();
    let hs: Vec<_> = (0..threads)
        .map(|th| {
            let db = Arc::clone(&shared);
            std::thread::spawn(move || {
                let mut s = 100 + th;
                for _ in 0..per {
                    let id = splitmix(&mut s) % n;
                    assert!(db.get(key(id)).unwrap().is_some());
                }
            })
        })
        .collect();
    for h in hs {
        h.join().unwrap();
    }
    report("get_hit_4threads", per * threads, t.elapsed().as_secs_f64(), None, "");

    // durable_put_1thread: each put is on disk before it returns.
    let writes = 2000u64;
    let mut lat = Lat(Vec::with_capacity(writes as usize));
    let t = Instant::now();
    for i in 0..writes {
        let id = 10 * n + i;
        let a = Instant::now();
        shared.put_durable(key(id), value(id, 0)).unwrap();
        lat.0.push(a.elapsed().as_nanos() as u64);
    }
    report("durable_put_1thread", writes, t.elapsed().as_secs_f64(), Some(&mut lat), "");

    // durable_put_16threads: group commit.
    let threads = 16u64;
    let per = 250u64;
    let t = Instant::now();
    let hs: Vec<_> = (0..threads)
        .map(|th| {
            let db = Arc::clone(&shared);
            std::thread::spawn(move || {
                for i in 0..per {
                    let id = 20 * n + th * per + i;
                    db.put_durable(key(id), value(id, 0)).unwrap();
                }
            })
        })
        .collect();
    for h in hs {
        h.join().unwrap();
    }
    report("durable_put_16threads", threads * per, t.elapsed().as_secs_f64(), None, "");

    // snapshot_dirty: snapshots while recent writes are still in memory.
    for i in 0..10_000u64 {
        let id = 30 * n + i;
        shared.put(key(id), value(id, 0)).unwrap();
    }
    let snaps = 1000u64;
    let probe = key(30 * n + 5);
    let mut lat = Lat(Vec::with_capacity(snaps as usize));
    let t = Instant::now();
    for _ in 0..snaps {
        let a = Instant::now();
        let snap = shared.snapshot().unwrap();
        assert!(snap.get(&probe).unwrap().is_some());
        drop(snap);
        lat.0.push(a.elapsed().as_nanos() as u64);
    }
    report("snapshot_dirty", snaps, t.elapsed().as_secs_f64(), Some(&mut lat), "");

    // overwrite: half of the keys again, buffered, then settle.
    let over = n / 2;
    let t = Instant::now();
    for _ in 0..over {
        let id = splitmix(&mut s) % n;
        shared.put(key(id), value(id, 1)).unwrap();
    }
    shared.sync().unwrap();
    let write_secs = t.elapsed().as_secs_f64();
    shared.checkpoint().unwrap();
    let total = t.elapsed().as_secs_f64();
    report(
        "overwrite",
        over,
        write_secs,
        None,
        &format!(",\"settle_seconds\":{:.6},\"disk_bytes\":{},\"rss_kb\":{}", total - write_secs, dir_bytes(&dir), max_rss_kb()),
    );

    match Arc::try_unwrap(shared) {
        Ok(db) => db.close().unwrap(),
        Err(_) => panic!("handle still shared"),
    }
}
