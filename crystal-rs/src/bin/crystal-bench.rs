//! Benchmarks for the Rust Crystal: the same driver as `crystal/src/bench.zig`
//! (the Holo/Stratum driver), ported line by line, so every workload is byte
//! for byte the same. One JSON object per phase on stdout, progress on stderr.
//!
//!   cargo build --release
//!   target/release/crystal-bench agent  <new-dir>
//!   target/release/crystal-bench recall <new-dir> [memories]
//!   target/release/crystal-bench hard   <new-dir> [memories] [meaning-model]
//!   target/release/crystal-bench jargon <new-dir> [memories] [meaning-model]
//!   target/release/crystal-bench lanes  <new-dir>

use crystal::{Crystal, Item, Meaning, Options, Query, RememberOptions};
use std::alloc::{GlobalAlloc, Layout, System};
use std::fmt::Write as _;
use std::io::Write as _;
use std::sync::atomic::{AtomicI64, AtomicU64, Ordering::Relaxed};
use std::sync::{Arc, LazyLock};
use std::time::{Duration, Instant};

// ------------------------------------------------------------ heap counter

static LIVE: AtomicI64 = AtomicI64::new(0);
static PEAK: AtomicI64 = AtomicI64::new(0);

struct Counting;
fn add(d: i64) {
    let now = LIVE.fetch_add(d, Relaxed) + d;
    let mut peak = PEAK.load(Relaxed);
    while now > peak {
        match PEAK.compare_exchange_weak(peak, now, Relaxed, Relaxed) {
            Ok(_) => break,
            Err(p) => peak = p,
        }
    }
}
unsafe impl GlobalAlloc for Counting {
    unsafe fn alloc(&self, l: Layout) -> *mut u8 {
        let p = System.alloc(l);
        if !p.is_null() {
            add(l.size() as i64);
        }
        p
    }
    unsafe fn dealloc(&self, p: *mut u8, l: Layout) {
        System.dealloc(p, l);
        add(-(l.size() as i64));
    }
    unsafe fn realloc(&self, p: *mut u8, l: Layout, n: usize) -> *mut u8 {
        let q = System.realloc(p, l, n);
        if !q.is_null() {
            add(n as i64 - l.size() as i64);
        }
        q
    }
}
#[global_allocator]
static GLOBAL: Counting = Counting;

// ------------------------------------------------------------------ helpers

const ENGINE: &str = "crystal-rs";

fn splitmix(state: &mut u64) -> u64 {
    *state = state.wrapping_add(0x9E37_79B9_7F4A_7C15);
    let mut z = *state;
    z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
    z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
    z ^ (z >> 31)
}

static START: LazyLock<Instant> = LazyLock::new(Instant::now);
fn now_ns() -> u64 {
    START.elapsed().as_nanos() as u64
}
fn secs_since(t: u64) -> f64 {
    (now_ns() - t) as f64 / 1e9
}

fn dir_bytes(path: &std::path::Path) -> u64 {
    let Ok(rd) = std::fs::read_dir(path) else { return 0 };
    let mut total = 0;
    for e in rd.flatten() {
        let Ok(md) = e.metadata() else { continue };
        if md.is_dir() {
            total += dir_bytes(&e.path());
        } else if md.is_file() {
            total += md.len();
        }
    }
    total
}

fn status_kb(field: &str) -> u64 {
    let t = std::fs::read_to_string("/proc/self/status").unwrap_or_default();
    for line in t.lines() {
        if let Some(rest) = line.strip_prefix(field) {
            return rest.split_whitespace().next().and_then(|v| v.parse().ok()).unwrap_or(0);
        }
    }
    0
}
fn max_rss_kb() -> u64 {
    status_kb("VmHWM:")
}
fn anon_kb() -> u64 {
    status_kb("RssAnon:")
}

#[derive(Default)]
struct Lat {
    ns: Vec<u64>,
}
impl Lat {
    fn pct(&mut self, p: f64) -> u64 {
        if self.ns.is_empty() {
            return 0;
        }
        self.ns.sort_unstable();
        let i = ((self.ns.len() - 1) as f64 * p) as usize;
        self.ns[i]
    }
}

fn report(phase: &str, ops: u64, secs: f64, lat: Option<&mut Lat>, extra: &str) {
    let (p50, p99) = match lat {
        Some(l) => (l.pct(0.5), l.pct(0.99)),
        None => (0, 0),
    };
    let line = format!(
        "{{\"engine\":\"{}\",\"phase\":\"{}\",\"ops\":{},\"seconds\":{:.6},\"ops_per_sec\":{:.1},\"p50_ns\":{},\"p99_ns\":{}{},\"heap_live_bytes\":{},\"heap_peak_bytes\":{}}}\n",
        ENGINE,
        phase,
        ops,
        secs,
        ops as f64 / secs,
        p50,
        p99,
        extra,
        LIVE.load(Relaxed),
        PEAK.load(Relaxed)
    );
    let mut out = std::io::stdout().lock();
    let _ = out.write_all(line.as_bytes());
    let _ = out.flush();
}

struct Progress {
    phase: std::sync::Mutex<String>,
    index: AtomicU64,
    phases: AtomicU64,
    total: AtomicU64,
    done: AtomicU64,
    last: AtomicI64,
}
static PROG: LazyLock<Progress> = LazyLock::new(|| Progress { phase: std::sync::Mutex::new(String::new()), index: AtomicU64::new(0), phases: AtomicU64::new(0), total: AtomicU64::new(0), done: AtomicU64::new(0), last: AtomicI64::new(0) });

fn phase_start(name: &str, total: u64) {
    *PROG.phase.lock().unwrap() = name.to_string();
    PROG.index.fetch_add(1, Relaxed);
    PROG.total.store(total, Relaxed);
    PROG.done.store(0, Relaxed);
    progress_line(0);
}

fn tick() {
    let d = PROG.done.fetch_add(1, Relaxed) + 1;
    if d & 255 != 0 {
        return;
    }
    let now = (now_ns() / 1_000_000) as i64;
    let last = PROG.last.load(Relaxed);
    if now - last < 1000 {
        return;
    }
    if PROG.last.compare_exchange(last, now, Relaxed, Relaxed).is_err() {
        return;
    }
    progress_line(d);
}

fn progress_line(done: u64) {
    let total = PROG.total.load(Relaxed);
    let pct = if total == 0 { 0.0 } else { done as f64 * 100.0 / total as f64 };
    let line = format!(
        "{{\"progress\":\"{}\",\"phase_index\":{},\"phases\":{},\"done\":{},\"total\":{},\"pct\":{:.1},\"elapsed\":{:.1}}}\n",
        PROG.phase.lock().unwrap(),
        PROG.index.load(Relaxed),
        PROG.phases.load(Relaxed),
        done,
        total,
        pct,
        secs_since(0)
    );
    let _ = std::io::stderr().write_all(line.as_bytes());
}

fn fatal(msg: &str) -> ! {
    eprint!("{}", msg);
    std::process::exit(2);
}

fn ratio(a: u64, b: u64) -> f64 {
    a as f64 / b.max(1) as f64
}

/// Substring search (libc memmem, like Zig's std.mem.indexOf in speed).
fn contains(hay: &[u8], needle: &[u8]) -> bool {
    needle.is_empty() || !unsafe { libc::memmem(hay.as_ptr() as *const libc::c_void, hay.len(), needle.as_ptr() as *const libc::c_void, needle.len()) }.is_null()
}

fn main() {
    let _ = *START;
    let args: Vec<String> = std::env::args().collect();
    let usage = "usage: crystal-bench <agent|recall|hard|jargon|lanes> <new-dir> [memories] [meaning-model]\n";
    if args.len() < 3 {
        fatal(usage);
    }
    let mode = args[1].as_str();
    let dir = args[2].as_str();
    let n: u64 = if args.len() > 3 { args[3].parse().unwrap_or(0) } else { 1_000_000 };
    if mode == "lane-child" {
        run_lane_child(dir, args[3].parse().unwrap_or(0), args[4].parse().unwrap_or(0));
        return;
    }
    if let Ok(mut rd) = std::fs::read_dir(dir) {
        if rd.next().is_some() {
            fatal("the benchmark directory must be new or empty\n");
        }
    }
    let model = || if args.len() > 4 { args[4].clone() } else { "models/holo-words.bin".to_string() };
    match mode {
        "agent" => run_agent(dir),
        "recall" => run_recall(dir, n),
        "hard" => run_hard(dir, n, &model()),
        "jargon" => run_jargon(dir, n, &model()),
        "lanes" => run_lanes(dir),
        _ => fatal(usage),
    }
}

// ---------------------------------------------------------- agent workload

const CHATS: u64 = 5000;
const HOT_CHATS: u64 = 500;
const SEED_MESSAGES: u64 = 1_000_000;
const FACT_AGENTS: u64 = 16;
const FACTS_PER_AGENT: u64 = 256;
const TURN_THREADS: u64 = 8;
const TURNS_TOTAL: u64 = 40_000;
const CONTEXT_LEN: usize = 20;

const WORDS: [&str; 64] = [
    "the", "user", "wants", "to", "deploy", "service", "on", "friday", "because", "tests", "pass", "and", "billing", "invoice", "for", "march", "is", "late", "please", "check", "memory", "agent", "said", "we", "should", "retry", "with", "backoff", "error", "timeout", "in", "region", "eu", "west", "budget", "approved", "meeting", "moved", "tuesday", "notes", "summary", "of", "call", "customer", "asked", "about", "refund", "policy", "next", "steps", "draft", "email", "reply", "ledger", "entry", "matches", "bank", "export", "csv", "column", "date", "amount", "total", "pending",
];

fn message(buf: &mut String, t: u64, role: &str) {
    buf.clear();
    let mut s = t.wrapping_mul(0x2545_F491_4F6C_DD1D).wrapping_add(11);
    let target = 60 + splitmix(&mut s) % 840;
    let _ = write!(buf, "{{\"role\":\"{}\",\"t\":{},\"text\":\"", role, t);
    while (buf.len() as u64) < target {
        buf.push_str(WORDS[(splitmix(&mut s) % WORDS.len() as u64) as usize]);
        buf.push(' ');
    }
    buf.push_str("\"}");
}

fn fact(buf: &mut String, agent: u64, f: u64, version: u64) {
    buf.clear();
    let mut s = (agent * 1000 + f).wrapping_mul(0x9E37).wrapping_add(version);
    let _ = write!(buf, "{{\"fact\":{},\"v\":{},\"text\":\"", f, version);
    for _ in 0..12 {
        buf.push_str(WORDS[(splitmix(&mut s) % WORDS.len() as u64) as usize]);
        buf.push(' ');
    }
    buf.push_str("\"}");
}

fn chat_scope(chat: u64) -> String {
    format!("chat/{:05}", chat)
}
fn agent_scope(agent: u64) -> String {
    format!("mem/{:03}", agent)
}
fn fact_subject(f: u64) -> String {
    format!("fact/{:04}", f)
}

static CLOCK: AtomicU64 = AtomicU64::new(0);
const T0_MS: u64 = 1_700_000_000_000;

fn ro(subject: Option<&str>, time: u64) -> RememberOptions<'_> {
    RememberOptions { subject: subject.map(|s| s.as_bytes()), time: Some(time) }
}

#[derive(Default)]
struct AgentStats {
    lat: Lat,
    deletes: u64,
    briefs: u64,
    brief_ns: Lat,
    context_msgs: u64,
    step_ns: [u64; 6],
    durable_lat: Lat,
}

fn agent_work(d: &Crystal, th: u64, promised: bool) -> AgentStats {
    let mut me = AgentStats::default();
    let mut st: u64 = 1000 + th;
    let mut pend: Vec<(u64, u64)> = Vec::new();
    let mut ph = 0usize;
    let mut buf = String::new();
    let agent = th % FACT_AGENTS;
    let ascope = agent_scope(agent);
    for _ in 0..TURNS_TOTAL / TURN_THREADS {
        let a = now_ns();
        let roll = splitmix(&mut st) % 100;
        let chat = if roll < 80 { splitmix(&mut st) % HOT_CHATS } else { splitmix(&mut st) % CHATS };
        let cs = chat_scope(chat);
        let mut s0 = now_ns();
        let ctx = d.recent(cs.as_bytes(), CONTEXT_LEN).unwrap();
        me.context_msgs += ctx.len() as u64;
        drop(ctx);
        let mut s1 = now_ns();
        me.step_ns[0] += s1 - s0;
        for _ in 0..3 {
            let _ = d.current(ascope.as_bytes(), fact_subject(splitmix(&mut st) % FACTS_PER_AGENT).as_bytes()).unwrap();
        }
        s0 = now_ns();
        me.step_ns[1] += s0 - s1;
        if splitmix(&mut st) % 100 < 3 {
            let t1 = CLOCK.load(Relaxed);
            message(&mut buf, t1.wrapping_mul(7).wrapping_add(th), "user");
            let b0 = now_ns();
            let br = d.brief(buf.as_bytes(), cs.as_bytes(), 2000).unwrap();
            me.brief_ns.ns.push(now_ns() - b0);
            drop(br);
            me.briefs += 1;
        }
        s1 = now_ns();
        me.step_ns[2] += s1 - s0;
        let t1 = CLOCK.fetch_add(2, Relaxed);
        message(&mut buf, t1, "user");
        d.remember(cs.as_bytes(), buf.as_bytes(), ro(None, T0_MS + t1 * 100)).unwrap();
        message(&mut buf, t1 + 1, "assistant");
        d.remember(cs.as_bytes(), buf.as_bytes(), ro(None, T0_MS + t1 * 100 + 100)).unwrap();
        if splitmix(&mut st) % 100 < 10 {
            let f = splitmix(&mut st) % FACTS_PER_AGENT;
            fact(&mut buf, agent, f, t1);
            let fs = fact_subject(f);
            d.remember(ascope.as_bytes(), buf.as_bytes(), ro(Some(&fs), T0_MS + t1 * 100)).unwrap();
        }
        s0 = now_ns();
        me.step_ns[3] += s0 - s1;
        if splitmix(&mut st) % 1000 < 10 {
            let victim = HOT_CHATS + splitmix(&mut st) % (CHATS - HOT_CHATS);
            d.forget_scope(chat_scope(victim).as_bytes()).unwrap();
            me.deletes += 1;
        }
        s1 = now_ns();
        me.step_ns[4] += s1 - s0;
        if promised {
            pend.push((d.promise(), s1));
            let now = now_ns();
            while ph < pend.len() && d.is_durable(pend[ph].0) {
                me.durable_lat.ns.push(now - pend[ph].1);
                ph += 1;
            }
        } else {
            d.sync().unwrap();
        }
        me.step_ns[5] += now_ns() - s1;
        me.lat.ns.push(now_ns() - a);
        tick();
    }
    if promised && !pend.is_empty() {
        // Every promise is kept before the thread is done.
        d.wait_durable(pend[pend.len() - 1].0).unwrap();
        let now = now_ns();
        for x in &pend[ph..] {
            me.durable_lat.ns.push(now - x.1);
        }
    }
    me
}

fn rusage() -> (i64, i64) {
    let mut ru: libc::rusage = unsafe { std::mem::zeroed() };
    unsafe { libc::getrusage(libc::RUSAGE_SELF, &mut ru) };
    (ru.ru_utime.tv_sec * 1_000_000 + ru.ru_utime.tv_usec, ru.ru_stime.tv_sec * 1_000_000 + ru.ru_stime.tv_usec)
}

fn agent_turns(h: &Crystal, dir: &str, name: &str, promised: bool) {
    phase_start(name, TURNS_TOTAL);
    h.set_clock_for_test(Some(T0_MS + CLOCK.load(Relaxed) * 100));
    let syncs_before = h.sync_count();
    let t = now_ns();
    let (u0, s0) = rusage();
    let stats: Vec<AgentStats> = std::thread::scope(|s| {
        let hs: Vec<_> = (0..TURN_THREADS).map(|th| s.spawn(move || agent_work(h, th, promised))).collect();
        hs.into_iter().map(|x| x.join().unwrap()).collect()
    });
    let secs = secs_since(t);
    let (u1, s1) = rusage();
    let user_us = u1 - u0;
    let sys_us = s1 - s0;
    let mut all = Lat::default();
    let mut briefs = Lat::default();
    let mut dur = Lat::default();
    let (mut deletes, mut nbriefs, mut ctx) = (0, 0, 0);
    let mut steps = [0u64; 6];
    for ag in stats {
        dur.ns.extend(ag.durable_lat.ns);
        for (x, y) in steps.iter_mut().zip(ag.step_ns) {
            *x += y;
        }
        all.ns.extend(ag.lat.ns);
        briefs.ns.extend(ag.brief_ns.ns);
        deletes += ag.deletes;
        nbriefs += ag.briefs;
        ctx += ag.context_msgs;
    }
    let tt = TURNS_TOTAL;
    let extra = format!(
        ",\"durable_p50_ns\":{},\"durable_p99_ns\":{},\"cpu_us_per_turn\":{{\"user\":{},\"sys\":{}}},\"step_us_per_turn\":{{\"recent\":{},\"current\":{},\"brief\":{},\"remember\":{},\"forget\":{},\"sync\":{}}},\"fsyncs\":{},\"chat_deletes\":{},\"briefs\":{},\"brief_p50_ns\":{},\"brief_p99_ns\":{},\"context_msgs\":{},\"disk_bytes\":{},\"rss_kb\":{},\"anon_kb\":{},\"index_bytes\":{}",
        dur.pct(0.5),
        dur.pct(0.99),
        user_us / tt as i64,
        sys_us / tt as i64,
        steps[0] / tt / 1000,
        steps[1] / tt / 1000,
        steps[2] / tt / 1000,
        steps[3] / tt / 1000,
        steps[4] / tt / 1000,
        steps[5] / tt / 1000,
        h.sync_count() - syncs_before,
        deletes,
        nbriefs,
        briefs.pct(0.5),
        briefs.pct(0.99),
        ctx,
        dir_bytes(dir.as_ref()),
        max_rss_kb(),
        anon_kb(),
        h.info().index_bytes
    );
    report(name, TURNS_TOTAL, secs, Some(&mut all), &extra);
}

fn run_agent(dir: &str) {
    PROG.phases.store(4, Relaxed);
    let mut h = Crystal::open(dir, Options { sync_writes: false, ..Default::default() }).unwrap();
    let mut mb = String::new();

    phase_start("agent_seed", SEED_MESSAGES + FACT_AGENTS * FACTS_PER_AGENT);
    let mut t = now_ns();
    let mut s: u64 = 99;
    let mut raw_bytes = 0u64;
    for _ in 0..SEED_MESSAGES {
        let tm = CLOCK.fetch_add(1, Relaxed);
        message(&mut mb, tm, if tm % 2 == 0 { "user" } else { "assistant" });
        raw_bytes += mb.len() as u64;
        h.remember(chat_scope(splitmix(&mut s) % CHATS).as_bytes(), mb.as_bytes(), ro(None, T0_MS + tm * 100)).unwrap();
        tick();
    }
    for a in 0..FACT_AGENTS {
        for f in 0..FACTS_PER_AGENT {
            fact(&mut mb, a, f, 0);
            raw_bytes += mb.len() as u64;
            let fs = fact_subject(f);
            h.remember(agent_scope(a).as_bytes(), mb.as_bytes(), ro(Some(&fs), T0_MS + CLOCK.load(Relaxed) * 100)).unwrap();
            tick();
        }
    }
    h.sync().unwrap();
    let extra = format!(",\"raw_bytes\":{},\"disk_bytes\":{},\"rss_kb\":{},\"anon_kb\":{},\"index_bytes\":{}", raw_bytes, dir_bytes(dir.as_ref()), max_rss_kb(), anon_kb(), h.info().index_bytes);
    report("agent_seed", SEED_MESSAGES + FACT_AGENTS * FACTS_PER_AGENT, secs_since(t), None, &extra);

    agent_turns(&h, dir, "agent_turns", false);
    // Same store, now with promised turns.
    h.close();
    h = Crystal::open(dir, Options { sync_writes: false, flusher: true, ..Default::default() }).unwrap();
    agent_turns(&h, dir, "agent_turns_promised", true);

    phase_start("agent_reopen", 1);
    t = now_ns();
    h.close();
    let close_s = secs_since(t);
    let h = Crystal::open(dir, Options { sync_writes: false, ..Default::default() }).unwrap();
    let reopen_secs = secs_since(t);
    let a = now_ns();
    let _ = h.recent(chat_scope(7).as_bytes(), CONTEXT_LEN).unwrap();
    let first_ns = now_ns() - a;
    report("agent_reopen", 1, reopen_secs, None, &format!(",\"first_context_ns\":{},\"anon_kb\":{},\"disk_bytes\":{},\"close_s\":{:.3}", first_ns, anon_kb(), dir_bytes(dir.as_ref()), close_s));
    h.close();
}

// --------------------------------------------------------- recall workload

const SYL_A: [&str; 16] = ["ka", "lo", "mi", "ne", "ru", "sa", "te", "vo", "zi", "pa", "do", "fe", "gu", "ha", "ji", "bo"];
const SYL_B: [&str; 8] = ["rn", "x", "th", "q", "zz", "kt", "vr", "yl"];

/// A filler word: common ones far more often, like real text.
fn filler_word(out: &mut String, idx: u64) {
    let mut s = idx.wrapping_mul(0x51ed27).wrapping_add(3);
    let parts = 2 + splitmix(&mut s) % 2;
    for _ in 0..parts {
        out.push_str(SYL_A[(splitmix(&mut s) % SYL_A.len() as u64) as usize]);
    }
}

/// A rare name: entities and values never collide with filler words.
fn rare_word(kind: u8, idx: u64) -> String {
    let mut s = idx.wrapping_mul(0x9e37_79b1).wrapping_add(kind as u64);
    let mut b = String::with_capacity(24);
    b.push(kind as char);
    for _ in 0..3 {
        b.push_str(SYL_A[(splitmix(&mut s) % SYL_A.len() as u64) as usize]);
        b.push_str(SYL_B[(splitmix(&mut s) % SYL_B.len() as u64) as usize]);
    }
    b
}

const ATTRS: [&str; 20] = [
    "deploy region", "database engine", "oncall owner", "release date", "rate limit", "cache ttl", "billing currency", "auth provider", "primary language", "log retention", "queue backend", "cdn vendor", "error budget", "backup schedule", "feature flag", "test runner", "cloud account", "ci system", "docs site", "design tool",
];

const PROJECTS: u64 = 200;
const CHATS_PER_PROJECT: u64 = 25;
const VOCAB: u64 = 3000;

fn unit(s: &mut u64) -> f64 {
    (splitmix(s) >> 11) as f64 / (1u64 << 53) as f64
}

fn filler_text(buf: &mut String, seed: u64, nwords: u64) {
    let mut s = seed;
    for _ in 0..nwords {
        let u = unit(&mut s);
        let idx = (VOCAB as f64 * u * u * u) as u64;
        filler_word(buf, idx);
        buf.push(' ');
    }
}

#[derive(Clone, Copy)]
struct Fact {
    project: u64,
    chat: u64,
    attr: usize,
    tagged: bool,
    at: [u64; 2],
    versions: u8,
}

fn entity(f: u64) -> String {
    rare_word(b'e', f)
}
fn value_word(f: u64, ver: u64) -> String {
    rare_word(b'v', f * 4 + ver)
}

fn fact_text(buf: &mut String, fi: u64, fct: &Fact, ver: u64) {
    buf.clear();
    filler_text(buf, fi.wrapping_mul(77).wrapping_add(ver), 6);
    if ver == 0 {
        let _ = write!(buf, "decision: the {} for {} is {}. ", ATTRS[fct.attr], entity(fi), value_word(fi, 0));
    } else {
        let _ = write!(buf, "update: we changed the {} for {} to {}. ", ATTRS[fct.attr], entity(fi), value_word(fi, ver));
    }
    filler_text(buf, fi.wrapping_mul(91).wrapping_add(ver), 6);
}

fn scope_of(f: &Fact) -> String {
    if f.tagged {
        format!("proj/{:03}/decisions", f.project)
    } else {
        format!("proj/{:03}/chat/{:02}", f.project, f.chat)
    }
}

fn subject_of(fi: u64, f: &Fact) -> String {
    format!("{}/{}", entity(fi), ATTRS[f.attr])
}

/// Collects memories and saves them with `remember_many`, 4096 at a time.
#[derive(Default)]
struct Batch {
    bytes: Vec<u8>,
    ents: Vec<([usize; 2], [usize; 2], Option<[usize; 2]>, u64)>,
}
impl Batch {
    fn put(&mut self, s: &[u8]) -> [usize; 2] {
        let off = self.bytes.len();
        self.bytes.extend_from_slice(s);
        [off, s.len()]
    }
    fn add(&mut self, h: &Crystal, scope: &str, body: &str, subject: Option<&str>, time: u64) {
        let sc = self.put(scope.as_bytes());
        let tx = self.put(body.as_bytes());
        let sj = subject.map(|s| self.put(s.as_bytes()));
        self.ents.push((sc, tx, sj, time));
        if self.ents.len() == 4096 {
            self.flush(h);
        }
    }
    fn flush(&mut self, h: &Crystal) {
        if self.ents.is_empty() {
            return;
        }
        let by = &self.bytes;
        let sl = |r: [usize; 2]| &by[r[0]..r[0] + r[1]];
        let items: Vec<Item> = self.ents.iter().map(|e| Item { scope: sl(e.0), text: sl(e.1), subject: e.2.map(sl), time: Some(e.3) }).collect();
        h.remember_many(&items).unwrap();
        for _ in 0..self.ents.len() {
            tick();
        }
        self.ents.clear();
        self.bytes.clear();
    }
}

fn plan_events(facts: &[(u8, [u64; 5])], by_ver: bool) -> Vec<(u64, u32, u8)> {
    let mut evs = Vec::new();
    for (i, f) in facts.iter().enumerate() {
        for v in 0..f.0 {
            evs.push((f.1[v as usize], i as u32, v));
        }
    }
    if by_ver {
        evs.sort_unstable_by(|a, b| a.0.cmp(&b.0).then(a.2.cmp(&b.2)));
    } else {
        // Zig's unstable sort by position only: ties keep an unspecified
        // order there; here they are ordered by fact then version.
        evs.sort_unstable_by(|a, b| a.0.cmp(&b.0).then(a.1.cmp(&b.1)).then(a.2.cmp(&b.2)));
    }
    evs
}

fn run_recall(dir: &str, n: u64) {
    PROG.phases.store(7, Relaxed);
    let nfacts = (n / 500).max(100);
    let mut facts = Vec::with_capacity(nfacts as usize);
    let mut s: u64 = 4242;
    for _ in 0..nfacts {
        let t0 = splitmix(&mut s) % (n * 8 / 10);
        let updated = splitmix(&mut s) % 100 < 30;
        let project = splitmix(&mut s) % PROJECTS;
        let chat = splitmix(&mut s) % CHATS_PER_PROJECT;
        let attr = (splitmix(&mut s) % ATTRS.len() as u64) as usize;
        let tagged = splitmix(&mut s) % 2 == 0;
        let t1 = if updated { t0 + 1 + splitmix(&mut s) % (n - t0 - 1) } else { 0 };
        facts.push(Fact { project, chat, attr, tagged, at: [t0, t1], versions: if updated { 2 } else { 1 } });
    }
    let plan: Vec<(u8, [u64; 5])> = facts.iter().map(|f| (f.versions, [f.at[0], f.at[1], 0, 0, 0])).collect();
    let evs = plan_events(&plan, false);
    let opts = || Options { sync_writes: false, half_life_ms: 3 * 24 * 3600 * 1000, ..Default::default() };
    let mut h = Crystal::open(dir, opts()).unwrap();
    let mut buf = String::new();
    let mut batch = Batch::default();
    phase_start("recall_load", n + evs.len() as u64);
    let mut t = now_ns();
    let mut ei = 0;
    let mut raw = 0u64;
    for i in 0..n {
        let tm = T0_MS + i * 1000;
        while ei < evs.len() && evs[ei].0 == i {
            let (_, fi, ver) = evs[ei];
            let f = facts[fi as usize];
            fact_text(&mut buf, fi as u64, &f, ver as u64);
            raw += buf.len() as u64;
            let subj = if f.tagged { Some(subject_of(fi as u64, &f)) } else { None };
            batch.add(&h, &scope_of(&f), &buf, subj.as_deref(), tm);
            ei += 1;
        }
        buf.clear();
        let mut ss = i.wrapping_mul(0x2545_F491_4F6C_DD1D).wrapping_add(5);
        let seed = splitmix(&mut ss);
        let nw = 20 + splitmix(&mut ss) % 60;
        filler_text(&mut buf, seed, nw);
        raw += buf.len() as u64;
        let p = splitmix(&mut ss) % PROJECTS;
        let c = splitmix(&mut ss) % CHATS_PER_PROJECT;
        batch.add(&h, &format!("proj/{:03}/chat/{:02}", p, c), &buf, None, tm);
    }
    batch.flush(&h);
    h.sync().unwrap();
    let load_secs = secs_since(t);
    let now_ms = T0_MS + n * 1000;
    h.set_clock_for_test(Some(now_ms));
    report("recall_load", n + evs.len() as u64, load_secs, None, &format!(",\"raw_bytes\":{},\"facts\":{},\"updated\":{},\"rss_kb\":{},\"anon_kb\":{},\"index_bytes\":{}", raw, nfacts, evs.len() as u64 - nfacts, max_rss_kb(), anon_kb(), h.info().index_bytes));

    phase_start("recall_reopen", 1);
    t = now_ns();
    h.close();
    let close_s = secs_since(t);
    h = Crystal::open(dir, opts()).unwrap();
    h.set_clock_for_test(Some(now_ms));
    report("recall_reopen", 1, secs_since(t), None, &format!(",\"anon_kb\":{},\"disk_bytes\":{},\"index_bytes\":{},\"close_s\":{:.3}", anon_kb(), dir_bytes(dir.as_ref()), h.info().index_bytes, close_s));

    let queries = nfacts.min(2000);
    for mode in 0..4 {
        let name = ["recall_global", "recall_project", "baseline_recent50", "brief_project_2000tok"][mode];
        phase_start(name, queries);
        let mut lat = Lat::default();
        let (mut hit1, mut hit5, mut stale1, mut found_any, mut stale_any, mut tokens) = (0u64, 0u64, 0u64, 0u64, 0u64, 0u64);
        let mut qs: u64 = 5;
        t = now_ns();
        for _ in 0..queries {
            let fi = splitmix(&mut qs) % nfacts;
            let f = facts[fi as usize];
            let ent = entity(fi);
            let want = value_word(fi, f.versions as u64 - 1);
            let old = if f.versions > 1 { Some(value_word(fi, 0)) } else { None };
            let question = format!("what is the {} for {}?", ATTRS[f.attr], ent);
            let proj = format!("proj/{:03}", f.project);
            let a = now_ns();
            match mode {
                0 | 1 => {
                    let hits = h.recall(&Query { about: question.as_bytes(), scope: if mode == 0 { b"" } else { proj.as_bytes() }, limit: 5, ..Default::default() }).unwrap();
                    lat.ns.push(now_ns() - a);
                    for (rank, x) in hits.iter().enumerate() {
                        let has = contains(x.memory.text(), want.as_bytes());
                        let has_old = old.as_ref().is_some_and(|o| contains(x.memory.text(), o.as_bytes()) && !has);
                        if rank == 0 && has {
                            hit1 += 1;
                        }
                        if rank == 0 && has_old {
                            stale1 += 1;
                        }
                        if has {
                            hit5 += 1;
                            break;
                        }
                    }
                }
                2 => {
                    let hits = h.recall(&Query { scope: proj.as_bytes(), limit: 50, ..Default::default() }).unwrap();
                    lat.ns.push(now_ns() - a);
                    if hits.iter().any(|x| contains(x.memory.text(), want.as_bytes())) {
                        hit5 += 1;
                    }
                }
                _ => {
                    let b = h.brief(question.as_bytes(), proj.as_bytes(), 2000).unwrap();
                    lat.ns.push(now_ns() - a);
                    tokens += b.tokens as u64;
                    if contains(&b.text, want.as_bytes()) {
                        found_any += 1;
                    }
                    if old.as_ref().is_some_and(|o| contains(&b.text, o.as_bytes())) {
                        stale_any += 1;
                    }
                }
            }
            tick();
        }
        let secs = secs_since(t);
        report(name, queries, secs, Some(&mut lat), &format!(",\"hit_at_1\":{:.4},\"hit_at_k\":{:.4},\"stale_at_1\":{:.4},\"brief_has_answer\":{:.4},\"brief_has_stale\":{:.4},\"avg_tokens\":{:.1},\"anon_kb\":{}", ratio(hit1, queries), ratio(hit5, queries), ratio(stale1, queries), ratio(found_any, queries), ratio(stale_any, queries), ratio(tokens, queries), anon_kb()));
    }

    // Ceiling and cost of not having an index: read every memory.
    {
        let sample: u64 = if n > 2_000_000 { 3 } else { 10 };
        phase_start("baseline_full_scan", sample);
        let mut lat = Lat::default();
        let mut hit1 = 0;
        let mut qs: u64 = 5;
        t = now_ns();
        for _ in 0..sample {
            let fi = splitmix(&mut qs) % nfacts;
            let f = facts[fi as usize];
            let ent = entity(fi);
            let want = value_word(fi, f.versions as u64 - 1);
            let a = now_ns();
            let mut best_t = 0u64;
            let mut best_has = false;
            h.scan_all(|body, tm| {
                if !contains(body, ent.as_bytes()) || !contains(body, ATTRS[f.attr].as_bytes()) {
                    return;
                }
                if tm >= best_t {
                    best_t = tm;
                    best_has = contains(body, want.as_bytes());
                }
            })
            .unwrap();
            lat.ns.push(now_ns() - a);
            if best_has {
                hit1 += 1;
            }
            tick();
        }
        report("baseline_full_scan", sample, secs_since(t), Some(&mut lat), &format!(",\"hit_at_1\":{:.4}", ratio(hit1, sample)));
    }
    h.close();
}

// -------------------------------------------------------------- hard test

struct HardAttr {
    fact: &'static str,
    update: &'static str,
    same: &'static str,
    para: &'static str,
}

const HARD_ATTRS: [HardAttr; 20] = [
    HardAttr { fact: "@ is deployed in the # region", update: "@ moved over to the # region", same: "which region is @ deployed in?", para: "which datacenter hosts @?" },
    HardAttr { fact: "@ keeps its records in #", update: "@ migrated its records into #", same: "where does @ keep its records?", para: "what database does @ use?" },
    HardAttr { fact: "# is on call for @", update: "# now carries the pager for @", same: "who is on call for @?", para: "who handles outages of @?" },
    HardAttr { fact: "@ ships on #", update: "@ launch slipped to #", same: "when does @ ship?", para: "when does @ go live?" },
    HardAttr { fact: "@ throttles traffic at # requests", update: "@ throttling raised to # requests", same: "at what traffic does @ throttle requests?", para: "how many calls per second can @ take?" },
    HardAttr { fact: "@ caches results for #", update: "@ cache expiry bumped to #", same: "how long does @ cache results?", para: "how long are @ responses stored?" },
    HardAttr { fact: "@ invoices customers in #", update: "@ invoicing switched to #", same: "what do @ invoices use?", para: "what money does @ bill in?" },
    HardAttr { fact: "@ signs users in through #", update: "@ login now goes through #", same: "how does @ sign users in?", para: "who handles authentication for @?" },
    HardAttr { fact: "@ is written in #", update: "@ got rewritten in #", same: "what is @ written in?", para: "what programming language is @ coded in?" },
    HardAttr { fact: "@ keeps logs for #", update: "@ log retention cut to #", same: "how long does @ keep logs?", para: "how long are @ records kept?" },
    HardAttr { fact: "@ passes messages through #", update: "@ messaging moved to #", same: "what does @ pass messages through?", para: "which broker does @ rely on?" },
    HardAttr { fact: "@ serves static files from #", update: "@ assets now served from #", same: "where does @ serve static files from?", para: "who delivers @ content to browsers?" },
    HardAttr { fact: "@ may fail # of requests", update: "@ failure allowance tightened to #", same: "how many requests may @ fail?", para: "how much downtime is @ allowed?" },
    HardAttr { fact: "@ is backed up every #", update: "@ backups now run every #", same: "how often is @ backed up?", para: "how often is @ snapshotted?" },
    HardAttr { fact: "@ new checkout is behind the # toggle", update: "@ toggle renamed to #", same: "which toggle is the @ checkout behind?", para: "what switch turns on the new @ checkout?" },
    HardAttr { fact: "@ tests run with #", update: "@ tests ported to #", same: "what do @ tests run with?", para: "which framework checks @ code?" },
    HardAttr { fact: "@ is billed to the # account", update: "@ charges moved to the # account", same: "which account is @ billed to?", para: "whose subscription pays for @?" },
    HardAttr { fact: "@ builds on #", update: "@ builds migrated to #", same: "where does @ build?", para: "what compiles @ on every commit?" },
    HardAttr { fact: "@ documentation lives on #", update: "@ docs moved to #", same: "where does @ documentation live?", para: "where is the @ manual?" },
    HardAttr { fact: "@ mockups are drawn in #", update: "@ mockups now made in #", same: "what are @ mockups drawn in?", para: "what tool sketches @ screens?" },
];

fn fill_template(buf: &mut String, tmpl: &str, ent: &str, val: &str) {
    for c in tmpl.chars() {
        match c {
            '@' => buf.push_str(ent),
            '#' => buf.push_str(val),
            _ => buf.push(c),
        }
    }
}

/// The most common words of the meaning table, most common first.
fn load_chat_words(bytes: &[u8], want: usize) -> Vec<String> {
    let mut list = Vec::new();
    let mut p = 16;
    while list.len() < want && p < bytes.len() {
        let l = bytes[p] as usize;
        list.push(String::from_utf8_lossy(&bytes[p + 1..p + 1 + l]).into_owned());
        p += 1 + l;
    }
    list
}

fn chat_filler(buf: &mut String, cw: &[String], seed: u64, nwords: u64) {
    let mut s = seed;
    for _ in 0..nwords {
        let u = unit(&mut s);
        let idx = (cw.len() as f64 * u * u * u) as usize;
        buf.push_str(&cw[idx.min(cw.len() - 1)]);
        buf.push(' ');
    }
}

fn load_meaning(path: &str) -> (Arc<Meaning>, Vec<String>) {
    let bytes = std::fs::read(path).unwrap_or_else(|_| fatal("cannot read the meaning model\n"));
    let m = Meaning::load(&bytes).unwrap_or_else(|_| fatal("bad meaning model\n"));
    (Arc::new(m), load_chat_words(&bytes, 4000))
}

fn run_hard(dir: &str, n: u64, model_path: &str) {
    PROG.phases.store(10, Relaxed);
    let (meaning, cw) = load_meaning(model_path);
    let nents = (n / 10_000).max(10);
    let nfacts = nents * HARD_ATTRS.len() as u64;
    let mut facts = Vec::with_capacity(nfacts as usize);
    let mut s: u64 = 777;
    for i in 0..nfacts {
        let t0 = splitmix(&mut s) % (n * 8 / 10);
        let updated = splitmix(&mut s) % 100 < 30;
        let ent = i / HARD_ATTRS.len() as u64;
        let chat = splitmix(&mut s) % CHATS_PER_PROJECT;
        let tagged = splitmix(&mut s) % 2 == 0;
        let t1 = if updated { t0 + 1 + splitmix(&mut s) % (n - t0 - 1) } else { 0 };
        facts.push(Fact { project: ent % PROJECTS, chat, attr: (i % HARD_ATTRS.len() as u64) as usize, tagged, at: [t0, t1], versions: if updated { 2 } else { 1 } });
    }
    let plan: Vec<(u8, [u64; 5])> = facts.iter().map(|f| (f.versions, [f.at[0], f.at[1], 0, 0, 0])).collect();
    let evs = plan_events(&plan, false);
    let opts = || Options { sync_writes: false, half_life_ms: 3 * 24 * 3600 * 1000, meaning: Some(meaning.clone()), ..Default::default() };
    let mut h = Crystal::open(dir, opts()).unwrap();
    let mut buf = String::new();
    let mut batch = Batch::default();
    phase_start("hard_load", n + evs.len() as u64);
    let mut t = now_ns();
    let mut ei = 0;
    let mut raw = 0u64;
    for i in 0..n {
        let tm = T0_MS + i * 1000;
        while ei < evs.len() && evs[ei].0 == i {
            let (_, fi, ver) = evs[ei];
            let f = facts[fi as usize];
            let ent_i = fi as u64 / HARD_ATTRS.len() as u64;
            buf.clear();
            chat_filler(&mut buf, &cw, (fi as u64).wrapping_mul(77).wrapping_add(ver as u64), 4);
            let a = &HARD_ATTRS[f.attr];
            fill_template(&mut buf, if ver == 0 { a.fact } else { a.update }, &entity(ent_i), &value_word(fi as u64, ver as u64));
            buf.push_str(". ");
            chat_filler(&mut buf, &cw, (fi as u64).wrapping_mul(91).wrapping_add(ver as u64), 4);
            raw += buf.len() as u64;
            let subj = if f.tagged { Some(format!("{}/{}", entity(ent_i), f.attr)) } else { None };
            batch.add(&h, &scope_of(&f), &buf, subj.as_deref(), tm);
            ei += 1;
        }
        buf.clear();
        let mut ss = i.wrapping_mul(0x2545_F491_4F6C_DD1D).wrapping_add(5);
        let seed = splitmix(&mut ss);
        let nw = 8 + splitmix(&mut ss) % 30;
        chat_filler(&mut buf, &cw, seed, nw);
        raw += buf.len() as u64;
        let p = splitmix(&mut ss) % PROJECTS;
        let c = splitmix(&mut ss) % CHATS_PER_PROJECT;
        batch.add(&h, &format!("proj/{:03}/chat/{:02}", p, c), &buf, None, tm);
    }
    batch.flush(&h);
    h.sync().unwrap();
    let load_secs = secs_since(t);
    let now_ms = T0_MS + n * 1000;
    h.set_clock_for_test(Some(now_ms));
    report("hard_load", n + evs.len() as u64, load_secs, None, &format!(",\"raw_bytes\":{},\"entities\":{},\"facts\":{},\"updated\":{},\"rss_kb\":{},\"index_bytes\":{}", raw, nents, nfacts, evs.len() as u64 - nfacts, max_rss_kb(), h.info().index_bytes));

    phase_start("hard_reopen", 1);
    t = now_ns();
    h.close();
    h = Crystal::open(dir, opts()).unwrap();
    h.set_clock_for_test(Some(now_ms));
    report("hard_reopen", 1, secs_since(t), None, &format!(",\"disk_bytes\":{}", dir_bytes(dir.as_ref())));

    let queries = nfacts.min(2000);
    // name, para, expand, project, brief
    let cases: [(&str, bool, bool, bool, bool); 7] = [
        ("same_words_lexical", false, false, false, false),
        ("same_words_meaning", false, true, false, false),
        ("paraphrase_lexical", true, false, false, false),
        ("paraphrase_meaning", true, true, false, false),
        ("paraphrase_meaning_project", true, true, true, false),
        ("paraphrase_brief_2000tok", true, true, true, true),
        ("paraphrase_lexical_brief_2000tok", true, false, true, true),
    ];
    for (name, para, expand, project, brief) in cases {
        phase_start(name, queries);
        let mut lat = Lat::default();
        let (mut hit1, mut hit5, mut stale1, mut tokens) = (0u64, 0u64, 0u64, 0u64);
        let mut qs: u64 = 5;
        t = now_ns();
        for _ in 0..queries {
            let fi = splitmix(&mut qs) % nfacts;
            let f = facts[fi as usize];
            let ent = entity(fi / HARD_ATTRS.len() as u64);
            let want = value_word(fi, f.versions as u64 - 1);
            let old = if f.versions > 1 { Some(value_word(fi, 0)) } else { None };
            buf.clear();
            let a = &HARD_ATTRS[f.attr];
            fill_template(&mut buf, if para { a.para } else { a.same }, &ent, "");
            let proj = format!("proj/{:03}", f.project);
            let st = now_ns();
            if brief {
                if !expand {
                    // Lexical brief: same store, meaning switched off.
                    h.set_meaning_enabled(false);
                }
                let b = h.brief(buf.as_bytes(), proj.as_bytes(), 2000).unwrap();
                h.set_meaning_enabled(true);
                lat.ns.push(now_ns() - st);
                tokens += b.tokens as u64;
                if contains(&b.text, want.as_bytes()) {
                    hit5 += 1;
                }
                if old.as_ref().is_some_and(|o| contains(&b.text, o.as_bytes())) {
                    stale1 += 1;
                }
            } else {
                let hits = h.recall(&Query { about: buf.as_bytes(), scope: if project { proj.as_bytes() } else { b"" }, limit: 5, expand, ..Default::default() }).unwrap();
                lat.ns.push(now_ns() - st);
                for (rank, x) in hits.iter().enumerate() {
                    let has = contains(x.memory.text(), want.as_bytes());
                    let has_old = old.as_ref().is_some_and(|o| contains(x.memory.text(), o.as_bytes()) && !has);
                    if rank == 0 && has {
                        hit1 += 1;
                    }
                    if rank == 0 && has_old {
                        stale1 += 1;
                    }
                    if has {
                        hit5 += 1;
                        break;
                    }
                }
            }
            tick();
        }
        report(name, queries, secs_since(t), Some(&mut lat), &format!(",\"hit_at_1\":{:.4},\"hit_at_k\":{:.4},\"stale\":{:.4},\"avg_tokens\":{:.1}", ratio(hit1, queries), ratio(hit5, queries), ratio(stale1, queries), ratio(tokens, queries)));
    }
    h.close();
}

// ------------------------------------------------------------ jargon test

const JARGON_TEMPLATES: [&str; 4] = ["@ % is set to #", "we changed the @ % to #", "@ now runs % at #", "heads up: % for @ became #"];

fn jargon_syn(fi: u64, k: u64) -> String {
    rare_word(b'j', fi * 3 + k)
}
fn jargon_val(fi: u64, ver: u64) -> String {
    rare_word(b'w', fi * 8 + ver)
}

fn fill_jargon(buf: &mut String, tmpl: &str, ent: &str, syn: &str, val: &str) {
    for c in tmpl.chars() {
        match c {
            '@' => buf.push_str(ent),
            '%' => buf.push_str(syn),
            '#' => buf.push_str(val),
            _ => buf.push(c),
        }
    }
}

#[derive(Clone, Copy)]
struct JFact {
    project: u64,
    chat: u64,
    tagged: bool,
    versions: u8,
    at: [u64; 5],
}

fn run_jargon(dir: &str, n: u64, model_path: &str) {
    PROG.phases.store(6, Relaxed);
    let (meaning, cw) = load_meaning(model_path);
    let nfacts = (n / 500).max(100);
    let mut facts = Vec::with_capacity(nfacts as usize);
    let mut s: u64 = 4242;
    for _ in 0..nfacts {
        let nv = (2 + splitmix(&mut s) % 4) as usize;
        let mut at = [0u64; 5];
        for a in at.iter_mut().take(nv) {
            *a = splitmix(&mut s) % n;
        }
        at[..nv].sort_unstable();
        for v in 1..nv {
            at[v] = at[v].max(at[v - 1] + 1);
        }
        for a in at.iter_mut().take(nv) {
            *a = (*a).min(n - 1);
        }
        let project = splitmix(&mut s) % PROJECTS;
        let chat = splitmix(&mut s) % CHATS_PER_PROJECT;
        let tagged = splitmix(&mut s) % 2 == 0;
        facts.push(JFact { project, chat, tagged, versions: nv as u8, at });
    }
    let plan: Vec<(u8, [u64; 5])> = facts.iter().map(|f| (f.versions, f.at)).collect();
    let evs = plan_events(&plan, true);
    let h = Crystal::open(dir, Options { sync_writes: false, half_life_ms: 3 * 24 * 3600 * 1000, meaning: Some(meaning.clone()), ..Default::default() }).unwrap();
    let mut buf = String::new();
    let mut batch = Batch::default();
    phase_start("jargon_load", n + evs.len() as u64);
    let mut t = now_ns();
    let mut ei = 0;
    for i in 0..n {
        let tm = T0_MS + i * 1000;
        while ei < evs.len() && evs[ei].0 == i {
            let (_, fi, ver) = evs[ei];
            let f = facts[fi as usize];
            let ent = entity(fi as u64);
            buf.clear();
            chat_filler(&mut buf, &cw, (fi as u64).wrapping_mul(77).wrapping_add(ver as u64), 4);
            fill_jargon(&mut buf, JARGON_TEMPLATES[ver as usize % JARGON_TEMPLATES.len()], &ent, &jargon_syn(fi as u64, ver as u64 % 3), &jargon_val(fi as u64, ver as u64));
            buf.push_str(". ");
            chat_filler(&mut buf, &cw, (fi as u64).wrapping_mul(91).wrapping_add(ver as u64), 4);
            let subj = if f.tagged { Some(format!("{}/setting", ent)) } else { None };
            batch.add(&h, &format!("proj/{:03}/chat/{:02}", f.project, f.chat), &buf, subj.as_deref(), tm);
            ei += 1;
        }
        buf.clear();
        let mut ss = i.wrapping_mul(0x2545_F491_4F6C_DD1D).wrapping_add(5);
        let seed = splitmix(&mut ss);
        let nw = 8 + splitmix(&mut ss) % 30;
        chat_filler(&mut buf, &cw, seed, nw);
        let p = splitmix(&mut ss) % PROJECTS;
        let c = splitmix(&mut ss) % CHATS_PER_PROJECT;
        batch.add(&h, &format!("proj/{:03}/chat/{:02}", p, c), &buf, None, tm);
    }
    batch.flush(&h);
    h.sync().unwrap();
    let now_ms = T0_MS + n * 1000;
    h.set_clock_for_test(Some(now_ms));
    report("jargon_load", n + evs.len() as u64, secs_since(t), None, &format!(",\"facts\":{},\"versions\":{},\"anon_kb\":{},\"index_bytes\":{}", nfacts, evs.len(), anon_kb(), h.info().index_bytes));

    let queries = nfacts.min(2000);
    let cases: [(&str, Option<bool>, bool); 4] = [("jargon_all", None, false), ("jargon_with_subject", Some(true), false), ("jargon_no_subject", Some(false), false), ("jargon_brief_2000tok", None, true)];
    for (name, tagged, brief) in cases {
        phase_start(name, queries);
        let mut lat = Lat::default();
        let (mut asked, mut hit1, mut hit5, mut stale1) = (0u64, 0u64, 0u64, 0u64);
        let mut qs: u64 = 9;
        t = now_ns();
        let mut tries = 0;
        while asked < queries && tries < queries * 10 {
            tries += 1;
            let fi = splitmix(&mut qs) % nfacts;
            let f = facts[fi as usize];
            if let Some(tg) = tagged {
                if f.tagged != tg {
                    continue;
                }
            }
            asked += 1;
            let ent = entity(fi);
            let want = jargon_val(fi, f.versions as u64 - 1);
            let question = format!("what is the {} of {}?", jargon_syn(fi, 0), ent);
            let proj = format!("proj/{:03}", f.project);
            let st = now_ns();
            let olds: Vec<String> = (0..f.versions as u64 - 1).map(|v| jargon_val(fi, v)).collect();
            if brief {
                let b = h.brief(question.as_bytes(), proj.as_bytes(), 2000).unwrap();
                lat.ns.push(now_ns() - st);
                if contains(&b.text, want.as_bytes()) {
                    hit5 += 1;
                }
                if olds.iter().any(|o| contains(&b.text, o.as_bytes())) {
                    stale1 += 1;
                }
            } else {
                let hits = h.recall(&Query { about: question.as_bytes(), limit: 5, ..Default::default() }).unwrap();
                lat.ns.push(now_ns() - st);
                for (rank, x) in hits.iter().enumerate() {
                    let has = contains(x.memory.text(), want.as_bytes());
                    if rank == 0 && !has && olds.iter().any(|o| contains(x.memory.text(), o.as_bytes())) {
                        stale1 += 1;
                    }
                    if rank == 0 && has {
                        hit1 += 1;
                    }
                    if has {
                        hit5 += 1;
                        break;
                    }
                }
            }
            tick();
        }
        report(name, asked, secs_since(t), Some(&mut lat), &format!(",\"hit_at_1\":{:.4},\"hit_at_k\":{:.4},\"stale\":{:.4}", ratio(hit1, asked), ratio(hit5, asked), ratio(stale1, asked)));
    }
    h.close();
}

// ---------------------------------------------------------- several writers

const LANE_ACK_EVERY: u64 = 64;

fn lane_text(agent: u64, k: u64) -> String {
    format!("agent {} note {} tok{}x{} about the build", agent, k, agent, k)
}

fn spawn_lane_child(dir: &str, agent: u64, m: u64) -> std::process::Child {
    std::process::Command::new(std::env::current_exe().unwrap()).arg("lane-child").arg(dir).arg(agent.to_string()).arg(m.to_string()).spawn().unwrap()
}

fn ack_path(dir: &str, agent: u64) -> String {
    format!("{}-acks/{}", dir, agent)
}

/// One writer process: `m` memories, a sync every 64, and after each sync
/// the number of confirmed memories in its ack file.
fn run_lane_child(dir: &str, agent: u64, m: u64) {
    use std::os::unix::fs::FileExt;
    let h = Crystal::open(dir, Options { sync_writes: false, ..Default::default() }).unwrap();
    let ack = std::fs::OpenOptions::new().write(true).create(true).truncate(true).open(ack_path(dir, agent)).unwrap();
    let scope = format!("agent/{}", agent);
    let subj = format!("agent/{}/status", agent);
    for k in 0..m {
        h.remember(scope.as_bytes(), lane_text(agent, k).as_bytes(), RememberOptions { subject: if k % 10 == 0 { Some(subj.as_bytes()) } else { None }, time: None }).unwrap();
        if (k + 1) % LANE_ACK_EVERY == 0 || k + 1 == m {
            h.sync().unwrap();
            ack.write_all_at(&(k + 1).to_le_bytes(), 0).unwrap();
        }
    }
    h.close();
}

struct LaneCheck {
    seen: Vec<Vec<bool>>,
    bad: u64,
    lanes: usize,
    open_s: f64,
}

/// Opens the store as one more writer and counts which memories of each
/// agent are there.
fn check_lanes(dir: &str, agents: u64, cap: u64) -> LaneCheck {
    let t = now_ns();
    let h = Crystal::open(dir, Options { sync_writes: false, ..Default::default() }).unwrap();
    let open_s = secs_since(t);
    let mut seen = vec![vec![false; cap as usize]; agents as usize];
    let mut bad = 0;
    h.scan_all(|body, _| {
        let p = unsafe { libc::memmem(body.as_ptr() as *const libc::c_void, body.len(), b"agent ".as_ptr() as *const libc::c_void, 6) };
        if p.is_null() {
            return;
        }
        let at = p as usize - body.as_ptr() as usize;
        let rest = String::from_utf8_lossy(&body[at + 6..]);
        let mut it = rest.split(' ').filter(|s| !s.is_empty());
        let Some(a) = it.next().and_then(|x| x.parse::<usize>().ok()) else { return };
        it.next();
        let Some(k) = it.next().and_then(|x| x.parse::<usize>().ok()) else { return };
        if a >= seen.len() || k >= seen[a].len() {
            bad += 1;
            return;
        }
        seen[a][k] = true;
    })
    .unwrap();
    let lanes = h.info().lanes;
    h.close();
    LaneCheck { seen, bad, lanes, open_s }
}

fn read_ack(dir: &str, agent: u64) -> u64 {
    match std::fs::read(ack_path(dir, agent)) {
        Ok(b) if b.len() >= 8 => u64::from_le_bytes(b[..8].try_into().unwrap()),
        _ => 0,
    }
}

fn run_lanes(dir: &str) {
    PROG.phases.store(6, Relaxed);
    std::fs::create_dir_all(dir).unwrap();
    for nw in [1u64, 3, 8, 32] {
        let m: u64 = 20_000;
        let sub = format!("{}/w{}", dir, nw);
        std::fs::create_dir_all(format!("{}-acks", sub)).unwrap();
        let name = format!("writers_{}", nw);
        phase_start(&name, nw * m);
        let t = now_ns();
        let kids: Vec<_> = (0..nw).map(|a| spawn_lane_child(&sub, a, m)).collect();
        let mut failed = 0;
        for mut k in kids {
            if !k.wait().unwrap().success() {
                failed += 1;
            }
        }
        let secs = secs_since(t);
        let chk = check_lanes(&sub, nw, m);
        let lost: u64 = chk.seen.iter().map(|s| m - s.iter().filter(|&&b| b).count() as u64).sum();
        report(&name, nw * m, secs, None, &format!(",\"writers\":{},\"failed_writers\":{},\"lost\":{},\"garbled\":{},\"lanes\":{},\"reopen_s\":{:.3},\"disk_bytes\":{}", nw, failed, lost, chk.bad, chk.lanes, chk.open_s, dir_bytes(sub.as_ref())));
    }

    // Crash: 8 writers killed with SIGKILL at random moments.
    let nw: u64 = 8;
    let m: u64 = 2_000_000;
    let sub = format!("{}/crash", dir);
    std::fs::create_dir_all(format!("{}-acks", sub)).unwrap();
    phase_start("crash_kill9", nw);
    let t = now_ns();
    let kids: Vec<_> = (0..nw).map(|a| spawn_lane_child(&sub, a, m)).collect();
    let mut s: u64 = 99;
    for mut k in kids {
        let ms = 100 + splitmix(&mut s) % 500;
        std::thread::sleep(Duration::from_millis(ms));
        let _ = k.kill();
        let _ = k.wait();
        tick();
    }
    let secs = secs_since(t);
    let acks: Vec<u64> = (0..nw).map(|a| read_ack(&sub, a)).collect();
    let acked_total: u64 = acks.iter().sum();
    let chk = check_lanes(&sub, nw, m);
    let mut lost = 0u64;
    let mut extra = 0u64;
    for (a, bs) in chk.seen.iter().enumerate() {
        lost += (0..acks[a] as usize).filter(|&k| !bs[k]).count() as u64;
        extra += (bs.iter().filter(|&&b| b).count() as u64).saturating_sub(acks[a]);
    }
    report("crash_kill9", acked_total, secs, None, &format!(",\"writers\":{},\"confirmed\":{},\"confirmed_lost\":{},\"unconfirmed_kept\":{},\"garbled\":{},\"lanes\":{},\"reopen_s\":{:.3}", nw, acked_total, lost, extra, chk.bad, chk.lanes, chk.open_s));

    // New writers take over the dead writers' lanes and finish cleanly.
    phase_start("crash_takeover", nw);
    let t2 = now_ns();
    let m2: u64 = 5_000;
    let kids: Vec<_> = (0..nw).map(|a| spawn_lane_child(&sub, 100 + a, m2)).collect();
    let mut failed = 0;
    for mut k in kids {
        if !k.wait().unwrap().success() {
            failed += 1;
        }
        tick();
    }
    let secs2 = secs_since(t2);
    let chk2 = check_lanes(&sub, 108, m);
    let mut lost2 = 0u64;
    for a in 0..nw as usize {
        lost2 += (0..acks[a] as usize).filter(|&k| !chk2.seen[a][k]).count() as u64;
        lost2 += m2 - chk2.seen[100 + a].iter().filter(|&&b| b).count() as u64;
    }
    report("crash_takeover", nw * m2, secs2, None, &format!(",\"failed_writers\":{},\"lost\":{},\"garbled\":{},\"lanes\":{}", failed, lost2, chk2.bad, chk2.lanes));
}
