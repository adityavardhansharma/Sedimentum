//! Benchmarks for Holo. Prints one JSON object per phase on stdout, like
//! `src/bench.zig`, and progress on stderr.
//!
//!   zig build -Doptimize=ReleaseFast
//!   zig-out/bin/sedimentum-holo-bench agent  <new-dir>
//!   zig-out/bin/sedimentum-holo-bench recall <new-dir> [memories]
//!
//! agent:  the same agent workload as `sedimentum-bench ... agent` (same
//!         messages, chats, facts and turn mix), but through Holo's memory
//!         calls: recent() for the context window, current() for facts,
//!         brief() where the others read a whole chat, forgetScope() for
//!         deleted chats.
//! recall: can an agent find a fact it learned long ago, and does it get
//!         the newest version? Plants facts in a large stream of chat
//!         messages, changes some of them later, then asks.

const std = @import("std");
const Io = std.Io;
const sdm = @import("sedimentum");
const Holo = sdm.Holo;

var io_g: Io = undefined;

fn splitmix(state: *u64) u64 {
    state.* +%= 0x9E3779B97F4A7C15;
    var z = state.*;
    z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
    z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
    return z ^ (z >> 31);
}

fn nowNs(io: Io) i96 {
    return Io.Clock.awake.now(io).nanoseconds;
}

fn secondsSince(io: Io, start: i96) f64 {
    return @as(f64, @floatFromInt(nowNs(io) - start)) / 1e9;
}

fn dirBytes(io: Io, path: []const u8) u64 {
    var dir = Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return 0;
    defer dir.close(io);
    return dirBytesIn(io, dir);
}

fn dirBytesIn(io: Io, dir: Io.Dir) u64 {
    var total: u64 = 0;
    var it = dir.iterate();
    while (it.next(io) catch null) |e| switch (e.kind) {
        .file => {
            const st = dir.statFile(io, e.name, .{}) catch continue;
            total += st.size;
        },
        .directory => {
            var sub = dir.openDir(io, e.name, .{ .iterate = true }) catch continue;
            defer sub.close(io);
            total += dirBytesIn(io, sub);
        },
        else => {},
    };
    return total;
}

fn statusKb(io: Io, field: []const u8) u64 {
    var buf: [4096]u8 = undefined;
    const t = Io.Dir.cwd().readFile(io, "/proc/self/status", &buf) catch return 0;
    var lines = std.mem.splitScalar(u8, t, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, field)) continue;
        var parts = std.mem.tokenizeAny(u8, line[field.len..], " \t");
        return std.fmt.parseInt(u64, parts.next() orelse return 0, 10) catch 0;
    }
    return 0;
}
fn maxRssKb(io: Io) u64 {
    return statusKb(io, "VmHWM:");
}
fn anonKb(io: Io) u64 {
    return statusKb(io, "RssAnon:");
}

const Lat = struct {
    ns: std.ArrayList(u64) = .empty,
    fn pct(l: *Lat, p: f64) u64 {
        if (l.ns.items.len == 0) return 0;
        std.mem.sortUnstable(u64, l.ns.items, {}, std.sort.asc(u64));
        const i: usize = @intFromFloat(@as(f64, @floatFromInt(l.ns.items.len - 1)) * p);
        return l.ns.items[i];
    }
};

var out_buf: [16 * 1024]u8 = undefined;
var out: Io.File.Writer = undefined;

fn report(phase: []const u8, ops: u64, secs: f64, lat: ?*Lat, comptime extra_fmt: []const u8, extra: anytype) !void {
    const p50 = if (lat) |l| l.pct(0.50) else 0;
    const p99 = if (lat) |l| l.pct(0.99) else 0;
    const w = &out.interface;
    try w.print("{{\"engine\":\"holo\",\"phase\":\"{s}\",\"ops\":{d},\"seconds\":{d:.6},\"ops_per_sec\":{d:.1},\"p50_ns\":{d},\"p99_ns\":{d}", .{
        phase, ops, secs, @as(f64, @floatFromInt(ops)) / secs, p50, p99,
    });
    try w.print(extra_fmt, extra);
    try w.print(",\"heap_live_bytes\":{d},\"heap_peak_bytes\":{d}}}\n", .{ live_bytes.load(.monotonic), peak_bytes.load(.monotonic) });
    try w.flush();
}

var prog_phase: []const u8 = "";
var prog_index: u32 = 0;
var prog_phases: u32 = 0;
var prog_total: u64 = 0;
var prog_done: std.atomic.Value(u64) = .init(0);
var prog_last: std.atomic.Value(i64) = .init(0);
var prog_start: i96 = 0;

fn phaseStart(name: []const u8, total: u64) void {
    prog_phase = name;
    prog_index += 1;
    prog_total = total;
    prog_done.store(0, .monotonic);
    progressLine(0);
}

fn tick() void {
    const d = prog_done.fetchAdd(1, .monotonic) + 1;
    if (d & 255 != 0) return;
    const now: i64 = @intCast(@divTrunc(nowNs(io_g), std.time.ns_per_ms));
    const last = prog_last.load(.monotonic);
    if (now - last < 1000) return;
    if (prog_last.cmpxchgStrong(last, now, .monotonic, .monotonic) != null) return;
    progressLine(d);
}

fn progressLine(done: u64) void {
    var buf: [256]u8 = undefined;
    const pct = if (prog_total == 0) 0 else @as(f64, @floatFromInt(done)) * 100 / @as(f64, @floatFromInt(prog_total));
    const line = std.fmt.bufPrint(&buf, "{{\"progress\":\"{s}\",\"phase_index\":{d},\"phases\":{d},\"done\":{d},\"total\":{d},\"pct\":{d:.1},\"elapsed\":{d:.1}}}\n", .{
        prog_phase, prog_index, prog_phases, done, prog_total, pct, secondsSince(io_g, prog_start),
    }) catch return;
    Io.File.stderr().writeStreamingAll(io_g, line) catch {};
}

var live_bytes: std.atomic.Value(i64) = .init(0);
var peak_bytes: std.atomic.Value(i64) = .init(0);

const Counting = struct {
    fn alloc(_: *anyopaque, len: usize, a: std.mem.Alignment, ra: usize) ?[*]u8 {
        const p = std.heap.c_allocator.rawAlloc(len, a, ra) orelse return null;
        add(@intCast(len));
        return p;
    }
    fn resize(_: *anyopaque, m: []u8, a: std.mem.Alignment, n: usize, ra: usize) bool {
        if (!std.heap.c_allocator.rawResize(m, a, n, ra)) return false;
        add(@as(i64, @intCast(n)) - @as(i64, @intCast(m.len)));
        return true;
    }
    fn remap(_: *anyopaque, m: []u8, a: std.mem.Alignment, n: usize, ra: usize) ?[*]u8 {
        const p = std.heap.c_allocator.rawRemap(m, a, n, ra) orelse return null;
        add(@as(i64, @intCast(n)) - @as(i64, @intCast(m.len)));
        return p;
    }
    fn free(_: *anyopaque, m: []u8, a: std.mem.Alignment, ra: usize) void {
        std.heap.c_allocator.rawFree(m, a, ra);
        add(-@as(i64, @intCast(m.len)));
    }
    fn add(d: i64) void {
        const now = live_bytes.fetchAdd(d, .monotonic) + d;
        var peak = peak_bytes.load(.monotonic);
        while (now > peak) peak = peak_bytes.cmpxchgWeak(peak, now, .monotonic, .monotonic) orelse break;
    }
};
const gpa: std.mem.Allocator = .{ .ptr = undefined, .vtable = &.{ .alloc = Counting.alloc, .resize = Counting.resize, .remap = Counting.remap, .free = Counting.free } };
const driver = std.heap.c_allocator;

fn fatal(io: Io, msg: []const u8) !void {
    try Io.File.stderr().writeStreamingAll(io, msg);
    std.process.exit(2);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    io_g = io;
    prog_start = nowNs(io);
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const usage = "usage: sedimentum-holo-bench <agent|recall> <new-dir> [memories]\n";
    if (args.len < 3) return fatal(io, usage);
    const mode = args[1];
    const dir = args[2];
    const n: u64 = if (args.len > 3) std.fmt.parseInt(u64, args[3], 10) catch 0 else 1_000_000;
    out = Io.File.stdout().writerStreaming(io, &out_buf);
    if (Io.Dir.cwd().openDir(io, dir, .{ .iterate = true })) |existing| {
        var d = existing;
        defer d.close(io);
        var it = d.iterate();
        if (try it.next(io) != null) return fatal(io, "the benchmark directory must be new or empty\n");
    } else |_| {}
    if (std.mem.eql(u8, mode, "agent")) return runAgent(io, dir);
    if (std.mem.eql(u8, mode, "recall")) return runRecall(io, dir, n);
    return fatal(io, usage);
}

// ---------------------------------------------------------- agent workload
// Generators copied from src/bench.zig so the data is byte for byte the same.

const chats: u64 = 5000;
const hot_chats: u64 = 500;
const seed_messages: u64 = 1_000_000;
const fact_agents: u64 = 16;
const facts_per_agent: u64 = 256;
const turn_threads = 8;
const turns_total: u64 = 40_000;
const context_len = 20;

const words = [_][]const u8{
    "the",     "user",   "wants",   "to",       "deploy", "service",  "on",      "friday",  "because", "tests",
    "pass",    "and",    "billing", "invoice",  "for",    "march",    "is",      "late",    "please",  "check",
    "memory",  "agent",  "said",    "we",       "should", "retry",    "with",    "backoff", "error",   "timeout",
    "in",      "region", "eu",      "west",     "budget", "approved", "meeting", "moved",   "tuesday", "notes",
    "summary", "of",     "call",    "customer", "asked",  "about",    "refund",  "policy",  "next",    "steps",
    "draft",   "email",  "reply",   "ledger",   "entry",  "matches",  "bank",    "export",  "csv",     "column",
    "date",    "amount", "total",   "pending",
};

fn message(buf: *std.ArrayList(u8), t: u64, role: []const u8) ![]const u8 {
    buf.clearRetainingCapacity();
    var s = t *% 0x2545F4914F6CDD1D +% 11;
    const target = 60 + splitmix(&s) % 840;
    try buf.print(gpa, "{{\"role\":\"{s}\",\"t\":{d},\"text\":\"", .{ role, t });
    while (buf.items.len < target) {
        try buf.appendSlice(gpa, words[splitmix(&s) % words.len]);
        try buf.append(gpa, ' ');
    }
    try buf.appendSlice(gpa, "\"}");
    return buf.items;
}

fn fact(buf: *std.ArrayList(u8), agent: u64, f: u64, version: u64) ![]const u8 {
    buf.clearRetainingCapacity();
    var s = (agent * 1000 + f) *% 0x9E37 +% version;
    try buf.print(gpa, "{{\"fact\":{d},\"v\":{d},\"text\":\"", .{ f, version });
    for (0..12) |_| {
        try buf.appendSlice(gpa, words[splitmix(&s) % words.len]);
        try buf.append(gpa, ' ');
    }
    try buf.appendSlice(gpa, "\"}");
    return buf.items;
}

fn chatScope(buf: *[32]u8, chat: u64) []const u8 {
    return std.fmt.bufPrint(buf, "chat/{d:0>5}", .{chat}) catch unreachable;
}
fn agentScope(buf: *[32]u8, agent: u64) []const u8 {
    return std.fmt.bufPrint(buf, "mem/{d:0>3}", .{agent}) catch unreachable;
}
fn factSubject(buf: *[32]u8, f: u64) []const u8 {
    return std.fmt.bufPrint(buf, "fact/{d:0>4}", .{f}) catch unreachable;
}

var clock: std.atomic.Value(u64) = .init(0);
const t0_ms: u64 = 1_700_000_000_000;

fn runAgent(io: Io, dir: []const u8) !void {
    prog_phases = 3;
    var h = try Holo.open(gpa, io, Io.Dir.cwd(), dir, .{ .sync_writes = false });
    var mb: std.ArrayList(u8) = .empty;
    defer mb.deinit(gpa);
    var sb: [32]u8 = undefined;
    var fb: [32]u8 = undefined;

    phaseStart("agent_seed", seed_messages + fact_agents * facts_per_agent);
    var t = nowNs(io);
    var s: u64 = 99;
    var raw_bytes: u64 = 0;
    for (0..seed_messages) |_| {
        const tm = clock.fetchAdd(1, .monotonic);
        const v = try message(&mb, tm, if (tm % 2 == 0) "user" else "assistant");
        raw_bytes += v.len;
        _ = try h.remember(chatScope(&sb, splitmix(&s) % chats), v, .{ .time = t0_ms + tm * 100 });
        tick();
    }
    for (0..fact_agents) |a| for (0..facts_per_agent) |f| {
        const v = try fact(&mb, a, f, 0);
        raw_bytes += v.len;
        _ = try h.remember(agentScope(&sb, a), v, .{ .subject = factSubject(&fb, f), .time = t0_ms + clock.load(.monotonic) * 100 });
        tick();
    };
    try h.sync();
    try report("agent_seed", seed_messages + fact_agents * facts_per_agent, secondsSince(io, t), null, ",\"raw_bytes\":{d},\"disk_bytes\":{d},\"rss_kb\":{d},\"anon_kb\":{d},\"index_bytes\":{d}", .{
        raw_bytes, dirBytes(io, dir), maxRssKb(io), anonKb(io), h.info().index_bytes,
    });

    phaseStart("agent_turns", turns_total);
    const Agent = struct {
        lat: Lat = .{},
        deletes: u64 = 0,
        briefs: u64 = 0,
        brief_ns: Lat = .{},
        context_msgs: u64 = 0,
        failed: ?anyerror = null,

        fn run(self: *@This(), d: *Holo, th: u64) void {
            self.work(d, th) catch |e| {
                self.failed = e;
            };
        }

        fn work(self: *@This(), d: *Holo, th: u64) !void {
            var st: u64 = 1000 + th;
            var buf: std.ArrayList(u8) = .empty;
            defer buf.deinit(gpa);
            var b1: [32]u8 = undefined;
            var b2: [32]u8 = undefined;
            var b3: [32]u8 = undefined;
            const agent = th % fact_agents;
            const ascope = agentScope(&b2, agent);
            for (0..turns_total / turn_threads) |_| {
                const a = nowNs(io_g);
                const roll = splitmix(&st) % 100;
                const chat = if (roll < 80) splitmix(&st) % hot_chats else splitmix(&st) % chats;
                const cs = chatScope(&b1, chat);
                const ctx = try d.recent(gpa, cs, context_len);
                self.context_msgs += ctx.len;
                Holo.freeMemories(gpa, ctx);
                for (0..3) |_| {
                    if (try d.current(gpa, ascope, factSubject(&b3, splitmix(&st) % facts_per_agent))) |m| m.deinit(gpa);
                }
                if (splitmix(&st) % 100 < 3) {
                    // Where the KV engines read the whole chat, Holo briefs.
                    const t1 = clock.load(.monotonic);
                    const sit = try message(&buf, t1 *% 7 +% th, "user");
                    const b0 = nowNs(io_g);
                    const br = try d.brief(gpa, sit, cs, 2000);
                    try self.brief_ns.ns.append(driver, @intCast(nowNs(io_g) - b0));
                    br.deinit(gpa);
                    self.briefs += 1;
                }
                const t1 = clock.fetchAdd(2, .monotonic);
                _ = try d.remember(cs, try message(&buf, t1, "user"), .{ .time = t0_ms + t1 * 100 });
                _ = try d.remember(cs, try message(&buf, t1 + 1, "assistant"), .{ .time = t0_ms + t1 * 100 + 100 });
                if (splitmix(&st) % 100 < 10) {
                    const f = splitmix(&st) % facts_per_agent;
                    _ = try d.remember(ascope, try fact(&buf, agent, f, t1), .{ .subject = factSubject(&b3, f), .time = t0_ms + t1 * 100 });
                }
                if (splitmix(&st) % 1000 < 10) {
                    const victim = hot_chats + splitmix(&st) % (chats - hot_chats);
                    _ = try d.forgetScope(chatScope(&b3, victim));
                    self.deletes += 1;
                }
                try d.sync();
                try self.lat.ns.append(driver, @intCast(nowNs(io_g) - a));
                tick();
            }
        }
    };
    var ags: [turn_threads]Agent = @splat(.{});
    var hs: [turn_threads]std.Thread = undefined;
    h.setClockForTest(t0_ms + clock.load(.monotonic) * 100);
    const syncs_before = h.kv.syncCount();
    t = nowNs(io);
    for (&hs, 0..) |*hh, th| hh.* = try std.Thread.spawn(.{}, Agent.run, .{ &ags[th], h, th });
    for (hs) |hh| hh.join();
    const secs = secondsSince(io, t);
    var all: Lat = .{};
    var briefs: Lat = .{};
    var deletes: u64 = 0;
    var nbriefs: u64 = 0;
    var ctx: u64 = 0;
    for (&ags) |*ag| {
        if (ag.failed) |e| return e;
        try all.ns.appendSlice(driver, ag.lat.ns.items);
        try briefs.ns.appendSlice(driver, ag.brief_ns.ns.items);
        deletes += ag.deletes;
        nbriefs += ag.briefs;
        ctx += ag.context_msgs;
    }
    try report("agent_turns", turns_total, secs, &all, ",\"fsyncs\":{d},\"chat_deletes\":{d},\"briefs\":{d},\"brief_p50_ns\":{d},\"brief_p99_ns\":{d},\"context_msgs\":{d},\"disk_bytes\":{d},\"rss_kb\":{d},\"anon_kb\":{d},\"index_bytes\":{d}", .{
        h.kv.syncCount() - syncs_before, deletes, nbriefs, briefs.pct(0.5), briefs.pct(0.99), ctx, dirBytes(io, dir), maxRssKb(io), anonKb(io), h.info().index_bytes,
    });

    phaseStart("agent_reopen", 1);
    t = nowNs(io);
    h.close();
    h = try Holo.open(gpa, io, Io.Dir.cwd(), dir, .{ .sync_writes = false });
    const reopen_secs = secondsSince(io, t);
    const a = nowNs(io);
    const ctx7 = try h.recent(gpa, chatScope(&sb, 7), context_len);
    Holo.freeMemories(gpa, ctx7);
    const first_ns: u64 = @intCast(nowNs(io) - a);
    try report("agent_reopen", 1, reopen_secs, null, ",\"first_context_ns\":{d},\"anon_kb\":{d},\"disk_bytes\":{d}", .{ first_ns, anonKb(io), dirBytes(io, dir) });
    h.close();
}

// --------------------------------------------------------- recall workload

const syl_a = [_][]const u8{ "ka", "lo", "mi", "ne", "ru", "sa", "te", "vo", "zi", "pa", "do", "fe", "gu", "ha", "ji", "bo" };
const syl_b = [_][]const u8{ "rn", "x", "th", "q", "zz", "kt", "vr", "yl" };

/// A filler word: common ones far more often, like real text.
fn fillerWord(buf: *[16]u8, idx: u64) []const u8 {
    var s = idx *% 0x51ed27 +% 3;
    var n: usize = 0;
    const parts = 2 + splitmix(&s) % 2;
    for (0..parts) |_| {
        const sy = syl_a[splitmix(&s) % syl_a.len];
        @memcpy(buf[n..][0..sy.len], sy);
        n += sy.len;
    }
    return buf[0..n];
}

/// A rare name: entities and values never collide with filler words.
fn rareWord(buf: *[24]u8, kind: u8, idx: u64) []const u8 {
    var s = idx *% 0x9e3779b1 +% kind;
    var n: usize = 0;
    buf[n] = kind;
    n += 1;
    for (0..3) |_| {
        const a = syl_a[splitmix(&s) % syl_a.len];
        @memcpy(buf[n..][0..a.len], a);
        n += a.len;
        const b = syl_b[splitmix(&s) % syl_b.len];
        @memcpy(buf[n..][0..b.len], b);
        n += b.len;
    }
    return buf[0..n];
}

const attrs = [_][]const u8{
    "deploy region", "database engine",  "oncall owner",  "release date",     "rate limit",
    "cache ttl",     "billing currency", "auth provider", "primary language", "log retention",
    "queue backend", "cdn vendor",       "error budget",  "backup schedule",  "feature flag",
    "test runner",   "cloud account",    "ci system",     "docs site",        "design tool",
};

const projects: u64 = 200;
const chats_per_project: u64 = 25;
const vocab: u64 = 3000;

fn fillerText(buf: *std.ArrayList(u8), seed: u64, nwords: u64) !void {
    var s = seed;
    var wb: [16]u8 = undefined;
    for (0..nwords) |_| {
        const u: f64 = @as(f64, @floatFromInt(splitmix(&s) >> 11)) / @as(f64, 1 << 53);
        const idx: u64 = @intFromFloat(@as(f64, @floatFromInt(vocab)) * u * u * u);
        try buf.appendSlice(gpa, fillerWord(&wb, idx));
        try buf.append(gpa, ' ');
    }
}

const Fact = struct {
    project: u64,
    chat: u64,
    attr: u8,
    tagged: bool,
    /// Version 0 written at `at[0]`; version 1 (if any) at `at[1]`.
    at: [2]u64,
    versions: u8,
};

fn entity(buf: *[24]u8, f: u64) []const u8 {
    return rareWord(buf, 'e', f);
}
fn valueWord(buf: *[24]u8, f: u64, ver: u64) []const u8 {
    return rareWord(buf, 'v', f * 4 + ver);
}

fn factText(buf: *std.ArrayList(u8), fi: u64, fct: Fact, ver: u64) !void {
    buf.clearRetainingCapacity();
    var eb: [24]u8 = undefined;
    var vb: [24]u8 = undefined;
    try fillerText(buf, fi *% 77 +% ver, 6);
    if (ver == 0) {
        try buf.print(gpa, "decision: the {s} for {s} is {s}. ", .{ attrs[fct.attr], entity(&eb, fi), valueWord(&vb, fi, 0) });
    } else {
        try buf.print(gpa, "update: we changed the {s} for {s} to {s}. ", .{ attrs[fct.attr], entity(&eb, fi), valueWord(&vb, fi, ver) });
    }
    try fillerText(buf, fi *% 91 +% ver, 6);
}

fn scopeOf(buf: *[48]u8, fct: Fact) []const u8 {
    if (fct.tagged) return std.fmt.bufPrint(buf, "proj/{d:0>3}/decisions", .{fct.project}) catch unreachable;
    return std.fmt.bufPrint(buf, "proj/{d:0>3}/chat/{d:0>2}", .{ fct.project, fct.chat }) catch unreachable;
}

fn subjectOf(buf: *[64]u8, fi: u64, fct: Fact) []const u8 {
    var eb: [24]u8 = undefined;
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ entity(&eb, fi), attrs[fct.attr] }) catch unreachable;
}

fn runRecall(io: Io, dir: []const u8, n: u64) !void {
    prog_phases = 7;
    const nfacts = @max(n / 500, 100);
    // Plan the facts: when each version lands in the stream.
    const facts = try driver.alloc(Fact, nfacts);
    defer driver.free(facts);
    var s: u64 = 4242;
    for (facts) |*f| {
        const t0 = splitmix(&s) % (n * 8 / 10);
        const updated = splitmix(&s) % 100 < 30;
        f.* = .{
            .project = splitmix(&s) % projects,
            .chat = splitmix(&s) % chats_per_project,
            .attr = @intCast(splitmix(&s) % attrs.len),
            .tagged = splitmix(&s) % 2 == 0,
            .at = .{ t0, if (updated) t0 + 1 + splitmix(&s) % (n - t0 - 1) else 0 },
            .versions = if (updated) 2 else 1,
        };
    }
    // Event list: (position in stream, fact, version), sorted by position.
    const Ev = struct { pos: u64, fact: u32, ver: u8 };
    var evs: std.ArrayList(Ev) = .empty;
    defer evs.deinit(driver);
    for (facts, 0..) |f, i| for (0..f.versions) |v| try evs.append(driver, .{ .pos = f.at[v], .fact = @intCast(i), .ver = @intCast(v) });
    std.mem.sortUnstable(Ev, evs.items, {}, struct {
        fn lt(_: void, a: Ev, b: Ev) bool {
            return a.pos < b.pos;
        }
    }.lt);

    var h = try Holo.open(gpa, io, Io.Dir.cwd(), dir, .{ .sync_writes = false, .half_life_ms = 3 * 24 * 3600 * 1000 });
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var scb: [48]u8 = undefined;
    var sjb: [64]u8 = undefined;

    phaseStart("recall_load", n + evs.items.len);
    var t = nowNs(io);
    var ei: usize = 0;
    var raw: u64 = 0;
    for (0..n) |i| {
        // One message a second of stream time.
        const tm = t0_ms + i * 1000;
        while (ei < evs.items.len and evs.items[ei].pos == i) : (ei += 1) {
            const e = evs.items[ei];
            const f = facts[e.fact];
            try factText(&buf, e.fact, f, e.ver);
            raw += buf.items.len;
            _ = try h.remember(scopeOf(&scb, f), buf.items, .{ .time = tm, .subject = if (f.tagged) subjectOf(&sjb, e.fact, f) else null });
            tick();
        }
        buf.clearRetainingCapacity();
        var ss = i *% 0x2545F4914F6CDD1D +% 5;
        try fillerText(&buf, splitmix(&ss), 20 + splitmix(&ss) % 60);
        raw += buf.items.len;
        const p = splitmix(&ss) % projects;
        const c = splitmix(&ss) % chats_per_project;
        const sc = std.fmt.bufPrint(&scb, "proj/{d:0>3}/chat/{d:0>2}", .{ p, c }) catch unreachable;
        _ = try h.remember(sc, buf.items, .{ .time = tm });
        tick();
    }
    try h.sync();
    const load_secs = secondsSince(io, t);
    const now_ms = t0_ms + n * 1000;
    h.setClockForTest(now_ms);
    try report("recall_load", n + evs.items.len, load_secs, null, ",\"raw_bytes\":{d},\"facts\":{d},\"updated\":{d},\"rss_kb\":{d},\"anon_kb\":{d},\"index_bytes\":{d}", .{
        raw, nfacts, evs.items.len - nfacts, maxRssKb(io), anonKb(io), h.info().index_bytes,
    });

    phaseStart("recall_reopen", 1);
    t = nowNs(io);
    h.close();
    h = try Holo.open(gpa, io, Io.Dir.cwd(), dir, .{ .sync_writes = false, .half_life_ms = 3 * 24 * 3600 * 1000 });
    h.setClockForTest(now_ms);
    try report("recall_reopen", 1, secondsSince(io, t), null, ",\"anon_kb\":{d},\"disk_bytes\":{d},\"index_bytes\":{d}", .{ anonKb(io), dirBytes(io, dir), h.info().index_bytes });

    const queries = @min(nfacts, 2000);
    const Mode = enum { global, project, window, brief };
    for ([_]Mode{ .global, .project, .window, .brief }) |mode| {
        const name = switch (mode) {
            .global => "recall_global",
            .project => "recall_project",
            .window => "baseline_recent50",
            .brief => "brief_project_2000tok",
        };
        phaseStart(name, queries);
        var lat: Lat = .{};
        defer lat.ns.deinit(driver);
        var hit1: u64 = 0;
        var hit5: u64 = 0;
        var stale1: u64 = 0;
        var found_any: u64 = 0;
        var stale_any: u64 = 0;
        var tokens: u64 = 0;
        var qs: u64 = 5;
        t = nowNs(io);
        for (0..queries) |_| {
            const fi = splitmix(&qs) % nfacts;
            const f = facts[fi];
            var eb: [24]u8 = undefined;
            var vb: [24]u8 = undefined;
            var ob: [24]u8 = undefined;
            const ent = entity(&eb, fi);
            const want = valueWord(&vb, fi, f.versions - 1);
            const old: ?[]const u8 = if (f.versions > 1) valueWord(&ob, fi, 0) else null;
            var qb: [128]u8 = undefined;
            const question = std.fmt.bufPrint(&qb, "what is the {s} for {s}?", .{ attrs[f.attr], ent }) catch unreachable;
            var pb: [16]u8 = undefined;
            const proj = std.fmt.bufPrint(&pb, "proj/{d:0>3}", .{f.project}) catch unreachable;
            const a = nowNs(io);
            switch (mode) {
                .global, .project => {
                    const hits = try h.recall(gpa, .{ .about = question, .scope = if (mode == .global) "" else proj, .limit = 5 });
                    lat.ns.append(driver, @intCast(nowNs(io) - a)) catch {};
                    defer Holo.freeHits(gpa, hits);
                    for (hits, 0..) |x, rank| {
                        const has = std.mem.indexOf(u8, x.memory.text, want) != null;
                        const has_old = if (old) |o| std.mem.indexOf(u8, x.memory.text, o) != null and !has else false;
                        if (rank == 0 and has) hit1 += 1;
                        if (rank == 0 and has_old) stale1 += 1;
                        if (has) {
                            hit5 += 1;
                            break;
                        }
                    }
                },
                .window => {
                    // What a key-value store hands an agent without search:
                    // the newest 50 memories of the project.
                    const hits = try h.recall(gpa, .{ .scope = proj, .limit = 50 });
                    lat.ns.append(driver, @intCast(nowNs(io) - a)) catch {};
                    defer Holo.freeHits(gpa, hits);
                    for (hits) |x| {
                        if (std.mem.indexOf(u8, x.memory.text, want) != null) {
                            hit5 += 1;
                            break;
                        }
                    }
                },
                .brief => {
                    const b = try h.brief(gpa, question, proj, 2000);
                    lat.ns.append(driver, @intCast(nowNs(io) - a)) catch {};
                    defer b.deinit(gpa);
                    tokens += b.tokens;
                    if (std.mem.indexOf(u8, b.text, want) != null) found_any += 1;
                    if (old) |o| if (std.mem.indexOf(u8, b.text, o) != null) {
                        stale_any += 1;
                    };
                },
            }
            tick();
        }
        const secs = secondsSince(io, t);
        try report(name, queries, secs, &lat, ",\"hit_at_1\":{d:.4},\"hit_at_k\":{d:.4},\"stale_at_1\":{d:.4},\"brief_has_answer\":{d:.4},\"brief_has_stale\":{d:.4},\"avg_tokens\":{d:.1},\"anon_kb\":{d}", .{
            ratio(hit1, queries), ratio(hit5, queries), ratio(stale1, queries), ratio(found_any, queries), ratio(stale_any, queries), ratio(tokens, queries), anonKb(io),
        });
    }

    // Ceiling and cost of not having an index: read every memory and score
    // it exactly, for a handful of questions.
    {
        const sample = 10;
        phaseStart("baseline_full_scan", sample);
        var lat: Lat = .{};
        defer lat.ns.deinit(driver);
        var hit1: u64 = 0;
        var qs: u64 = 5;
        t = nowNs(io);
        for (0..sample) |_| {
            const fi = splitmix(&qs) % nfacts;
            const f = facts[fi];
            var eb: [24]u8 = undefined;
            var vb: [24]u8 = undefined;
            const ent = entity(&eb, fi);
            const want = valueWord(&vb, fi, f.versions - 1);
            const a = nowNs(io);
            // Best exact match: contains the entity and the attribute,
            // newest wins. Generous: knows the exact phrasing.
            var best_t: u64 = 0;
            var best_has = false;
            var it = try h.kv.iterator(.{ .start = "~m/", .end = "~m0" }, null);
            defer it.deinit();
            while (try it.next()) |p| {
                if (std.mem.indexOf(u8, p.value, ent) == null) continue;
                if (std.mem.indexOf(u8, p.value, attrs[f.attr]) == null) continue;
                const tl = std.mem.readInt(u16, p.value[0..2], .little);
                const bl = std.mem.readInt(u16, p.value[2 + tl ..][0..2], .little);
                const tm = std.mem.readInt(u64, p.value[4 + tl + bl ..][0..8], .little);
                if (tm >= best_t) {
                    best_t = tm;
                    best_has = std.mem.indexOf(u8, p.value, want) != null;
                }
            }
            lat.ns.append(driver, @intCast(nowNs(io) - a)) catch {};
            if (best_has) hit1 += 1;
            tick();
        }
        try report("baseline_full_scan", sample, secondsSince(io, t), &lat, ",\"hit_at_1\":{d:.4}", .{ratio(hit1, sample)});
    }
    h.close();
}

fn ratio(a: u64, b: u64) f64 {
    return @as(f64, @floatFromInt(a)) / @as(f64, @floatFromInt(@max(b, 1)));
}
