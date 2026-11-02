//! kiban side of the Sedimentum benchmark. Keep the workloads in step with
//! `src/bench.zig`: same keys, values, order and phases.

use kiban::db::{KibanOptions, SharedKiban};
use std::path::Path;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
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

/// Total size of every file under `dir`, subdirectories included.
fn dir_bytes(dir: &Path) -> u64 {
    let Ok(rd) = std::fs::read_dir(dir) else { return 0 };
    rd.filter_map(|e| e.ok())
        .map(|e| match e.metadata() {
            Ok(m) if m.is_file() => m.len(),
            Ok(m) if m.is_dir() => dir_bytes(&e.path()),
            _ => 0,
        })
        .sum()
}

fn anon_kb() -> u64 {
    status_kb("RssAnon:")
}

fn status_kb(field: &str) -> u64 {
    std::fs::read_to_string("/proc/self/status")
        .ok()
        .and_then(|s| s.lines().find(|l| l.starts_with(field)).map(|l| l.split_whitespace().nth(1).unwrap().parse().unwrap()))
        .unwrap_or(0)
}

// Progress on stderr about once a second, so a run cut off by a time
// limit still shows how far it got. Same format as the Zig side.
static PROG_DONE: AtomicU64 = AtomicU64::new(0);
static PROG_LAST_MS: AtomicU64 = AtomicU64::new(0);
static PROG: Mutex<(String, u32, u32, u64)> = Mutex::new((String::new(), 0, 0, 0));
static START: std::sync::OnceLock<Instant> = std::sync::OnceLock::new();

fn phase_start(name: &str, total: u64) {
    {
        let mut p = PROG.lock().unwrap();
        p.0 = name.to_string();
        p.1 += 1;
        p.3 = total;
    }
    PROG_DONE.store(0, Ordering::Relaxed);
    progress_line(0);
}

fn set_phases(n: u32) {
    PROG.lock().unwrap().2 = n;
}

fn tick() {
    let d = PROG_DONE.fetch_add(1, Ordering::Relaxed) + 1;
    if d & 255 != 0 {
        return;
    }
    let now = START.get().unwrap().elapsed().as_millis() as u64;
    let last = PROG_LAST_MS.load(Ordering::Relaxed);
    if now < last + 1000 {
        return;
    }
    if PROG_LAST_MS.compare_exchange(last, now, Ordering::Relaxed, Ordering::Relaxed).is_err() {
        return;
    }
    progress_line(d);
}

fn progress_line(done: u64) {
    let p = PROG.lock().unwrap();
    let pct = if p.3 == 0 { 0.0 } else { done as f64 * 100.0 / p.3 as f64 };
    eprintln!(
        "{{\"progress\":\"{}\",\"phase_index\":{},\"phases\":{},\"done\":{},\"total\":{},\"pct\":{:.1},\"elapsed\":{:.1}}}",
        p.0,
        p.1,
        p.2,
        done,
        p.3,
        pct,
        START.get().unwrap().elapsed().as_secs_f64()
    );
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

fn fatal(msg: &str) -> ! {
    eprintln!("{msg}");
    std::process::exit(2);
}

fn main() {
    START.get_or_init(Instant::now);
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 3 {
        fatal("usage: kiban-bench <std|agent> <new-dir> [records]");
    }
    let mode = args[1].as_str();
    let dir = Path::new(&args[2]).to_path_buf();
    let n: u64 = match args.get(3) {
        Some(s) => s.parse().unwrap_or(0),
        None => 1_000_000,
    };
    // Never delete anything: the benchmark needs a new or empty directory.
    if let Ok(mut entries) = std::fs::read_dir(&dir) {
        if entries.next().is_some() {
            fatal("the benchmark directory must be new or empty");
        }
    }
    match mode {
        "std" => {
            // latest10 needs at least 10 records per agent.
            if n < 10 * AGENTS {
                fatal("records must be a number of at least 640");
            }
            run_std(&dir, n)
        }
        "agent" => run_agent(&dir),
        _ => fatal("usage: kiban-bench <std|agent> <new-dir> [records]"),
    }
}

fn run_std(dir: &Path, n: u64) {
    let dir = dir.to_path_buf();
    set_phases(13);
    let mut db = open(&dir);

    // load: n buffered puts in random order, then one sync.
    let order = shuffled(n, 1);
    phase_start("load", n);
    let t = Instant::now();
    for &id in &order {
        db.put(key(id), value(id, 0)).unwrap();
        tick();
    }
    db.sync().unwrap();
    report("load", n, t.elapsed().as_secs_f64(), None, &format!(",\"rss_kb\":{},\"anon_kb\":{}", max_rss_kb(), anon_kb()));

    phase_start("settle", 1);
    let t = Instant::now();
    db.checkpoint().unwrap();
    report("settle", 1, t.elapsed().as_secs_f64(), None, &format!(",\"disk_bytes\":{}", dir_bytes(&dir)));

    phase_start("reopen", 1);
    let t = Instant::now();
    db.close().unwrap();
    db = open(&dir);
    report("reopen", 1, t.elapsed().as_secs_f64(), None, &format!(",\"anon_kb\":{}", anon_kb()));

    // get_hit / get_miss
    let mut s = 7u64;
    phase_start("get_hit", n);
    let mut lat = Lat(Vec::with_capacity(n as usize));
    let t = Instant::now();
    for _ in 0..n {
        let id = splitmix(&mut s) % n;
        let k = key(id);
        let a = Instant::now();
        let v = db.get(&k).unwrap();
        lat.0.push(a.elapsed().as_nanos() as u64);
        assert!(v.is_some());
        tick();
    }
    report("get_hit", n, t.elapsed().as_secs_f64(), Some(&mut lat), &format!(",\"anon_kb\":{}", anon_kb()));

    phase_start("get_miss", n);
    let mut lat = Lat(Vec::with_capacity(n as usize));
    let t = Instant::now();
    for _ in 0..n {
        let id = n + splitmix(&mut s) % n;
        let k = key(id);
        let a = Instant::now();
        let v = db.get(&k).unwrap();
        lat.0.push(a.elapsed().as_nanos() as u64);
        assert!(v.is_none());
        tick();
    }
    report("get_miss", n, t.elapsed().as_secs_f64(), Some(&mut lat), "");

    // latest10: newest 10 memories of a random agent (first 10 in key order).
    let queries = 100_000u64;
    phase_start("latest10", queries);
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
        tick();
    }
    report("latest10", queries, t.elapsed().as_secs_f64(), Some(&mut lat), "");

    // last10_by_key: the 10 greatest keys under an agent. kiban has no
    // reverse iterator, so it has to walk the whole agent range.
    let queries = 200u64;
    phase_start("last10_by_key", queries);
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
        tick();
    }
    report("last10_by_key", queries, t.elapsed().as_secs_f64(), Some(&mut lat), "");

    // scan_all: every key and value in order.
    phase_start("scan_all", n);
    let t = Instant::now();
    let snap = db.snapshot().unwrap();
    let mut count = 0u64;
    let mut bytes = 0usize;
    for e in snap.iter() {
        let (k, v) = e.unwrap();
        bytes += k.len() + v.len();
        count += 1;
        tick();
    }
    drop(snap);
    assert_eq!(count, n);
    report("scan_all", n, t.elapsed().as_secs_f64(), None, &format!(",\"bytes\":{bytes}"));

    // get_hit_4threads
    let threads = 4u64;
    let per = n / threads;
    let shared = Arc::new(db);
    phase_start("get_hit_4threads", per * threads);
    let t = Instant::now();
    let hs: Vec<_> = (0..threads)
        .map(|th| {
            let db = Arc::clone(&shared);
            std::thread::spawn(move || {
                let mut s = 100 + th;
                for _ in 0..per {
                    let id = splitmix(&mut s) % n;
                    assert!(db.get(key(id)).unwrap().is_some());
                    tick();
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
    phase_start("durable_put_1thread", writes);
    let mut lat = Lat(Vec::with_capacity(writes as usize));
    let t = Instant::now();
    for i in 0..writes {
        let id = 10 * n + i;
        let a = Instant::now();
        shared.put_durable(key(id), value(id, 0)).unwrap();
        lat.0.push(a.elapsed().as_nanos() as u64);
        tick();
    }
    report("durable_put_1thread", writes, t.elapsed().as_secs_f64(), Some(&mut lat), "");

    // durable_put_16threads: group commit.
    let threads = 16u64;
    let per = 250u64;
    phase_start("durable_put_16threads", threads * per);
    let t = Instant::now();
    let hs: Vec<_> = (0..threads)
        .map(|th| {
            let db = Arc::clone(&shared);
            std::thread::spawn(move || {
                for i in 0..per {
                    let id = 20 * n + th * per + i;
                    db.put_durable(key(id), value(id, 0)).unwrap();
                    tick();
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
    phase_start("snapshot_dirty", snaps);
    let probe = key(30 * n + 5);
    let mut lat = Lat(Vec::with_capacity(snaps as usize));
    let t = Instant::now();
    for _ in 0..snaps {
        let a = Instant::now();
        let snap = shared.snapshot().unwrap();
        assert!(snap.get(&probe).unwrap().is_some());
        drop(snap);
        lat.0.push(a.elapsed().as_nanos() as u64);
        tick();
    }
    report("snapshot_dirty", snaps, t.elapsed().as_secs_f64(), Some(&mut lat), "");

    // overwrite: half of the keys again, buffered, then settle.
    let over = n / 2;
    phase_start("overwrite", over);
    let t = Instant::now();
    for _ in 0..over {
        let id = splitmix(&mut s) % n;
        shared.put(key(id), value(id, 1)).unwrap();
        tick();
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
        &format!(",\"settle_seconds\":{:.6},\"disk_bytes\":{},\"rss_kb\":{},\"anon_kb\":{}", total - write_secs, dir_bytes(&dir), max_rss_kb(), anon_kb()),
    );

    match Arc::try_unwrap(shared) {
        Ok(db) => db.close().unwrap(),
        Err(_) => panic!("handle still shared"),
    }
}

// ---------------------------------------------------------- agent workload
//
// Same as `runAgent` in src/bench.zig: chats keyed newest first, agents
// with facts, 8 agents taking turns with one durable commit per turn.

const CHATS: u64 = 5000;
const HOT_CHATS: u64 = 500;
const SEED_MESSAGES: u64 = 1_000_000;
const FACT_AGENTS: u64 = 16;
const FACTS_PER_AGENT: u64 = 256;
const TURN_THREADS: u64 = 8;
const TURNS_TOTAL: u64 = 40_000;
const CONTEXT_LEN: usize = 20;

const WORDS: [&str; 64] = [
    "the", "user", "wants", "to", "deploy", "service", "on", "friday", "because", "tests", "pass", "and", "billing",
    "invoice", "for", "march", "is", "late", "please", "check", "memory", "agent", "said", "we", "should", "retry",
    "with", "backoff", "error", "timeout", "in", "region", "eu", "west", "budget", "approved", "meeting", "moved",
    "tuesday", "notes", "summary", "of", "call", "customer", "asked", "about", "refund", "policy", "next", "steps",
    "draft", "email", "reply", "ledger", "entry", "matches", "bank", "export", "csv", "column", "date", "amount",
    "total", "pending",
];

fn message(t: u64, role: &str) -> Vec<u8> {
    let mut s = t.wrapping_mul(0x2545F4914F6CDD1D).wrapping_add(11);
    let target = (60 + splitmix(&mut s) % 840) as usize;
    let mut out = format!("{{\"role\":\"{role}\",\"t\":{t},\"text\":\"");
    while out.len() < target {
        out.push_str(WORDS[(splitmix(&mut s) % WORDS.len() as u64) as usize]);
        out.push(' ');
    }
    out.push_str("\"}");
    out.into_bytes()
}

fn fact(agent: u64, f: u64, version: u64) -> Vec<u8> {
    let mut s = (agent * 1000 + f).wrapping_mul(0x9E37).wrapping_add(version);
    let mut out = format!("{{\"fact\":{f},\"v\":{version},\"text\":\"");
    for _ in 0..12 {
        out.push_str(WORDS[(splitmix(&mut s) % WORDS.len() as u64) as usize]);
        out.push(' ');
    }
    out.push_str("\"}");
    out.into_bytes()
}

fn msg_key(chat: u64, t: u64) -> Vec<u8> {
    format!("chat/{:05}/m/{:020}", chat, u64::MAX - t).into_bytes()
}

fn chat_prefix(chat: u64) -> Vec<u8> {
    format!("chat/{:05}/", chat).into_bytes()
}

fn fact_key(agent: u64, f: u64) -> Vec<u8> {
    format!("mem/{:03}/fact/{:04}", agent, f).into_bytes()
}

static CLOCK: AtomicU64 = AtomicU64::new(0);

fn scan_count(db: &SharedKiban, p: &[u8], limit: usize) -> usize {
    let end = prefix_end(p);
    db.snapshot().unwrap().range_values(p, &end, limit, |v| Ok::<_, kiban::db::DbError>(v.len())).unwrap().len()
}

fn run_agent(dir: &Path) {
    set_phases(3);
    let db = open(dir);

    let total_seed = SEED_MESSAGES + FACT_AGENTS * FACTS_PER_AGENT;
    phase_start("agent_seed", total_seed);
    let t = Instant::now();
    let mut s = 99u64;
    let mut raw_bytes = 0u64;
    for _ in 0..SEED_MESSAGES {
        let tm = CLOCK.fetch_add(1, Ordering::Relaxed);
        let v = message(tm, if tm % 2 == 0 { "user" } else { "assistant" });
        raw_bytes += v.len() as u64;
        db.put(msg_key(splitmix(&mut s) % CHATS, tm), v).unwrap();
        tick();
    }
    for a in 0..FACT_AGENTS {
        for f in 0..FACTS_PER_AGENT {
            let v = fact(a, f, 0);
            raw_bytes += v.len() as u64;
            db.put(fact_key(a, f), v).unwrap();
            tick();
        }
    }
    db.sync().unwrap();
    report(
        "agent_seed",
        total_seed,
        t.elapsed().as_secs_f64(),
        None,
        &format!(",\"raw_bytes\":{raw_bytes},\"disk_bytes\":{},\"rss_kb\":{},\"anon_kb\":{}", dir_bytes(dir), max_rss_kb(), anon_kb()),
    );

    phase_start("agent_turns", TURNS_TOTAL);
    let shared = Arc::new(db);
    let t = Instant::now();
    let hs: Vec<_> = (0..TURN_THREADS)
        .map(|th| {
            let db = Arc::clone(&shared);
            std::thread::spawn(move || {
                let mut st = 1000 + th;
                let agent = th % FACT_AGENTS;
                let mut lat = Vec::new();
                let (mut deletes, mut full_reads, mut ctx) = (0u64, 0u64, 0u64);
                for _ in 0..TURNS_TOTAL / TURN_THREADS {
                    let a = Instant::now();
                    let roll = splitmix(&mut st) % 100;
                    let chat = if roll < 80 { splitmix(&mut st) % HOT_CHATS } else { splitmix(&mut st) % CHATS };
                    let p = chat_prefix(chat);
                    ctx += scan_count(&db, &p, CONTEXT_LEN) as u64;
                    for _ in 0..3 {
                        let _ = db.get(fact_key(agent, splitmix(&mut st) % FACTS_PER_AGENT)).unwrap();
                    }
                    if splitmix(&mut st) % 100 < 3 {
                        scan_count(&db, &p, usize::MAX);
                        full_reads += 1;
                    }
                    let t1 = CLOCK.fetch_add(2, Ordering::Relaxed);
                    db.put(msg_key(chat, t1), message(t1, "user")).unwrap();
                    db.put(msg_key(chat, t1 + 1), message(t1 + 1, "assistant")).unwrap();
                    if splitmix(&mut st) % 100 < 10 {
                        let f = splitmix(&mut st) % FACTS_PER_AGENT;
                        db.put(fact_key(agent, f), fact(agent, f, t1)).unwrap();
                    }
                    if splitmix(&mut st) % 1000 < 10 {
                        // kiban has no range delete: read the chat's keys, delete each.
                        let victim = HOT_CHATS + splitmix(&mut st) % (CHATS - HOT_CHATS);
                        let vp = chat_prefix(victim);
                        let end = prefix_end(&vp);
                        let keys: Vec<Vec<u8>> = {
                            let snap = db.snapshot().unwrap();
                            snap.range(&vp, &end).map(|e| e.unwrap().0.to_vec()).collect()
                        };
                        for k in keys {
                            db.delete(k).unwrap();
                        }
                        deletes += 1;
                    }
                    db.sync().unwrap();
                    lat.push(a.elapsed().as_nanos() as u64);
                    tick();
                }
                (lat, deletes, full_reads, ctx)
            })
        })
        .collect();
    let mut all = Lat(Vec::new());
    let (mut deletes, mut full_reads, mut ctx) = (0u64, 0u64, 0u64);
    for h in hs {
        let (l, d, f, c) = h.join().unwrap();
        all.0.extend(l);
        deletes += d;
        full_reads += f;
        ctx += c;
    }
    let secs = t.elapsed().as_secs_f64();
    report(
        "agent_turns",
        TURNS_TOTAL,
        secs,
        Some(&mut all),
        &format!(
            ",\"chat_deletes\":{deletes},\"full_chat_reads\":{full_reads},\"context_msgs\":{ctx},\"disk_bytes\":{},\"rss_kb\":{},\"anon_kb\":{}",
            dir_bytes(dir),
            max_rss_kb(),
            anon_kb()
        ),
    );

    phase_start("agent_reopen", 1);
    let t = Instant::now();
    match Arc::try_unwrap(shared) {
        Ok(db) => db.close().unwrap(),
        Err(_) => panic!("handle still shared"),
    }
    let db = open(dir);
    let reopen_secs = t.elapsed().as_secs_f64();
    let a = Instant::now();
    scan_count(&db, &chat_prefix(7), CONTEXT_LEN);
    let first_ns = a.elapsed().as_nanos() as u64;
    report(
        "agent_reopen",
        1,
        reopen_secs,
        None,
        &format!(",\"first_context_ns\":{first_ns},\"anon_kb\":{},\"disk_bytes\":{}", anon_kb(), dir_bytes(dir)),
    );
    db.close().unwrap();
}
