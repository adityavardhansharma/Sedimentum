//! Benchmark driver for every Sedimentum engine (v1, v2, v3). Keep the
//! workloads in step with `bench/kiban-bench/src/main.rs`: same keys,
//! values, order and phases. Prints one JSON object per phase on stdout and
//! a progress line on stderr about once a second, so a run cut off by a
//! time limit still shows how far it got.
//!
//!   zig build -Doptimize=ReleaseFast
//!   zig-out/bin/sedimentum-bench <v1|v2|v3> <std|agent> <new-dir> [records] [v1-memory-budget-mb]

const std = @import("std");
const Io = std.Io;
const sdm = @import("sedimentum");
const Db = sdm.Db;
const Shared = sdm.Shared;
const streams = sdm.streams;

const agents: u64 = 64;
const value_len = 200;

var io_g: Io = undefined;
var engine_name: []const u8 = "v1";

fn splitmix(state: *u64) u64 {
    state.* +%= 0x9E3779B97F4A7C15;
    var z = state.*;
    z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
    z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
    return z ^ (z >> 31);
}

/// kiban's own agent-memory key: newest memory sorts first in its agent.
fn key(buf: *[48]u8, id: u64) []const u8 {
    return std.fmt.bufPrint(buf, "agent/{d:0>4}/memory/{d:0>20}", .{ id % agents, std.math.maxInt(u64) - id }) catch unreachable;
}

fn agentPrefix(buf: *[16]u8, agent: u64) []const u8 {
    return std.fmt.bufPrint(buf, "agent/{d:0>4}/", .{agent}) catch unreachable;
}

fn value(buf: *[value_len]u8, id: u64, round: u64) []const u8 {
    var s = id *% 31 +% round;
    var i: usize = 0;
    while (i < value_len) : (i += 8) {
        var word: [8]u8 = undefined;
        std.mem.writeInt(u64, &word, splitmix(&s), .little);
        const n = @min(8, value_len - i);
        @memcpy(buf[i..][0..n], word[0..n]);
    }
    return buf;
}

fn shuffled(a: std.mem.Allocator, n: u64, seed: u64) ![]u64 {
    const ids = try a.alloc(u64, n);
    for (ids, 0..) |*v, i| v.* = i;
    var s = seed;
    var i: usize = ids.len - 1;
    while (i > 0) : (i -= 1) {
        const j: usize = @intCast(splitmix(&s) % (i + 1));
        std.mem.swap(u64, &ids[i], &ids[j]);
    }
    return ids;
}

fn nowNs(io: Io) i96 {
    return Io.Clock.awake.now(io).nanoseconds;
}

fn secondsSince(io: Io, start: i96) f64 {
    return @as(f64, @floatFromInt(nowNs(io) - start)) / 1e9;
}

/// Total size of every file under `path`, subdirectories included.
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

fn maxRssKb(io: Io) u64 {
    return statusKb(io, "VmHWM:");
}

/// Current private memory (heap), leaving out file pages the OS can drop.
fn anonKb(io: Io) u64 {
    return statusKb(io, "RssAnon:");
}

fn statusKb(io: Io, field: []const u8) u64 {
    var buf: [4096]u8 = undefined;
    const text = Io.Dir.cwd().readFile(io, "/proc/self/status", &buf) catch return 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, field)) continue;
        var parts = std.mem.tokenizeAny(u8, line[field.len..], " \t");
        return std.fmt.parseInt(u64, parts.next() orelse return 0, 10) catch 0;
    }
    return 0;
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
    try w.print("{{\"engine\":\"{s}\",\"phase\":\"{s}\",\"ops\":{d},\"seconds\":{d:.6},\"ops_per_sec\":{d:.1},\"p50_ns\":{d},\"p99_ns\":{d}", .{
        engine_name, phase, ops, secs, @as(f64, @floatFromInt(ops)) / secs, p50, p99,
    });
    try w.print(extra_fmt, extra);
    try w.print(",\"heap_live_bytes\":{d},\"heap_peak_bytes\":{d}}}\n", .{ live_bytes.load(.monotonic), peak_bytes.load(.monotonic) });
    try w.flush();
}

// ---------------------------------------------------------------- progress

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

fn fatal(io: Io, msg: []const u8) !void {
    try Io.File.stderr().writeStreamingAll(io, msg);
    std.process.exit(2);
}

// ----------------------------------------------------------------- engines

var live_bytes: std.atomic.Value(i64) = .init(0);
var peak_bytes: std.atomic.Value(i64) = .init(0);

/// smp_allocator with a count of live bytes, so reports can tell what the
/// engine holds from what the allocator keeps cached.
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

/// v1: one ordered index in RAM over append-only segments.
const V1 = struct {
    db: *Shared,
    var memory_budget: usize = 0;

    fn open(io: Io, dir: []const u8) !V1 {
        return .{ .db = try Shared.open(gpa, io, Io.Dir.cwd(), dir, .{ .sync_writes = false, .memory_budget = memory_budget }) };
    }
    fn close(e: *V1) void {
        e.db.close();
    }
    fn put(e: *V1, k: []const u8, v: []const u8) !void {
        try e.db.put(k, v);
    }
    fn get(e: *V1, k: []const u8) !?[]u8 {
        return e.db.get(gpa, k);
    }
    fn scanCount(e: *V1, prefix: []const u8, reverse: bool, limit: usize) !usize {
        var eb: [64]u8 = undefined;
        const got = try e.db.scan(gpa, Db.prefixRange(prefix, reverse, &eb), null, limit);
        defer Db.freePairs(gpa, got);
        return got.len;
    }
    fn scanAll(e: *V1, io: Io) ![2]u64 {
        e.db.lock.lockSharedUncancelable(io);
        defer e.db.lock.unlockShared(io);
        var it = try e.db.db.iterator(.{});
        var count: u64 = 0;
        var bytes: u64 = 0;
        while (try it.next()) |p| {
            bytes += p.key.len + p.value.len;
            count += 1;
            tick();
        }
        return .{ count, bytes };
    }
    fn setDurable(e: *V1, on: bool) void {
        e.db.db.options.sync_writes = on;
    }
    fn syncs(e: *V1) u64 {
        return e.db.stats.syncs.load(.monotonic);
    }
    fn sync(e: *V1) !void {
        try e.db.sync();
    }
    fn compact(e: *V1) !void {
        _ = try e.db.compact();
    }
    fn snapGet(e: *V1, k: []const u8) !?[]u8 {
        const snap = try e.db.snapshot();
        defer e.db.release(snap);
        return e.db.getAt(gpa, snap, k);
    }
    fn deletePrefix(e: *V1, p: []const u8) !void {
        _ = try e.db.deletePrefix(p);
    }
    fn extra(e: *V1) u64 {
        return if (e.db.db.cold) |c| c.entries else 0;
    }
};

/// v2 and v3: stream stores.
fn StreamEngine(comptime S: type) type {
    return struct {
        const E = @This();
        db: *S,

        fn open(io: Io, dir: []const u8) !E {
            return .{ .db = try S.open(gpa, io, Io.Dir.cwd(), dir, .{ .sync_writes = false }) };
        }
        fn close(e: *E) void {
            e.db.close();
        }
        fn put(e: *E, k: []const u8, v: []const u8) !void {
            try e.db.put(k, v);
        }
        fn get(e: *E, k: []const u8) !?[]u8 {
            return e.db.get(gpa, k);
        }
        fn scanCount(e: *E, prefix: []const u8, reverse: bool, limit: usize) !usize {
            var eb: [64]u8 = undefined;
            const got = try e.db.scan(gpa, .{ .start = prefix, .end = streams.prefixEnd(prefix, &eb), .reverse = reverse }, null, limit);
            defer streams.freePairs(gpa, got);
            return got.len;
        }
        fn scanAll(e: *E, io: Io) ![2]u64 {
            _ = io;
            var it = try e.db.iterator(.{}, null);
            defer it.deinit();
            var count: u64 = 0;
            var bytes: u64 = 0;
            while (try it.next()) |p| {
                bytes += p.key.len + p.value.len;
                count += 1;
                tick();
            }
            return .{ count, bytes };
        }
        fn setDurable(e: *E, on: bool) void {
            for (e.db.shards) |sh| sh.sync_writes = on;
        }
        fn syncs(e: *E) u64 {
            return e.db.syncCount();
        }
        fn sync(e: *E) !void {
            try e.db.sync();
        }
        fn compact(e: *E) !void {
            try e.db.compact();
        }
        fn snapGet(e: *E, k: []const u8) !?[]u8 {
            const snap = try e.db.snapshot();
            defer e.db.release(snap);
            return e.db.getAt(gpa, snap, k);
        }
        fn deletePrefix(e: *E, p: []const u8) !void {
            try e.db.deletePrefix(p);
        }
        fn extra(e: *E) u64 {
            return e.db.info().meta_bytes;
        }
    };
}

const V2 = StreamEngine(streams.V2);
const V3 = StreamEngine(streams.V3);

// --------------------------------------------------------------------- main

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    io_g = io;
    prog_start = nowNs(io);
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const usage = "usage: sedimentum-bench <v1|v2|v3> <std|agent> <new-dir> [records] [v1-memory-budget-mb]\n";
    if (args.len < 4) return fatal(io, usage);
    const engine = args[1];
    const mode = args[2];
    const dir = args[3];
    const n: u64 = if (args.len > 4) std.fmt.parseInt(u64, args[4], 10) catch 0 else 1_000_000;
    if (args.len > 5) {
        const mb = std.fmt.parseInt(usize, args[5], 10) catch return fatal(io, "memory budget must be a number of megabytes\n");
        V1.memory_budget = mb << 20;
    }
    out = Io.File.stdout().writerStreaming(io, &out_buf);

    // Never delete anything: the benchmark needs a new or empty directory.
    if (Io.Dir.cwd().openDir(io, dir, .{ .iterate = true })) |existing| {
        var d = existing;
        defer d.close(io);
        var it = d.iterate();
        if (try it.next(io) != null) return fatal(io, "the benchmark directory must be new or empty\n");
    } else |_| {}

    const is_std = std.mem.eql(u8, mode, "std");
    if (!is_std and !std.mem.eql(u8, mode, "agent")) return fatal(io, usage);
    // latest10 needs at least 10 records per agent.
    if (is_std and n < 10 * agents) return fatal(io, "records must be a number of at least 640\n");

    if (std.mem.eql(u8, engine, "v1")) {
        engine_name = if (V1.memory_budget > 0) "v1-capped" else "v1";
        if (is_std) try runStd(V1, io, dir, n) else try runAgent(V1, io, dir);
    } else if (std.mem.eql(u8, engine, "v2")) {
        engine_name = "v2";
        if (is_std) try runStd(V2, io, dir, n) else try runAgent(V2, io, dir);
    } else if (std.mem.eql(u8, engine, "v3")) {
        engine_name = "v3";
        if (is_std) try runStd(V3, io, dir, n) else try runAgent(V3, io, dir);
    } else return fatal(io, usage);
}

// ------------------------------------------------------------ std workload

fn runStd(comptime E: type, io: Io, dir: []const u8, n: u64) !void {
    prog_phases = 13;
    var db = try E.open(io, dir);
    var kb: [48]u8 = undefined;
    var vb: [value_len]u8 = undefined;

    // load: n buffered puts in random order, then one sync.
    const order = try shuffled(gpa, n, 1);
    defer gpa.free(order);
    phaseStart("load", n);
    var t = nowNs(io);
    for (order) |id| {
        try db.put(key(&kb, id), value(&vb, id, 0));
        tick();
    }
    try db.sync();
    try report("load", n, secondsSince(io, t), null, ",\"rss_kb\":{d},\"anon_kb\":{d},\"extra\":{d}", .{ maxRssKb(io), anonKb(io), db.extra() });

    phaseStart("settle", 1);
    t = nowNs(io);
    try db.compact();
    try report("settle", 1, secondsSince(io, t), null, ",\"disk_bytes\":{d}", .{dirBytes(io, dir)});

    phaseStart("reopen", 1);
    t = nowNs(io);
    db.close();
    db = try E.open(io, dir);
    try report("reopen", 1, secondsSince(io, t), null, ",\"anon_kb\":{d}", .{anonKb(io)});

    var s: u64 = 7;
    {
        phaseStart("get_hit", n);
        var lat: Lat = .{};
        defer lat.ns.deinit(gpa);
        try lat.ns.ensureTotalCapacity(gpa, n);
        t = nowNs(io);
        for (0..n) |_| {
            const k = key(&kb, splitmix(&s) % n);
            const a = nowNs(io);
            const v = (try db.get(k)) orelse return error.Missing;
            gpa.free(v);
            lat.ns.appendAssumeCapacity(@intCast(nowNs(io) - a));
            tick();
        }
        try report("get_hit", n, secondsSince(io, t), &lat, ",\"anon_kb\":{d}", .{anonKb(io)});
    }
    {
        phaseStart("get_miss", n);
        var lat: Lat = .{};
        defer lat.ns.deinit(gpa);
        try lat.ns.ensureTotalCapacity(gpa, n);
        t = nowNs(io);
        for (0..n) |_| {
            const k = key(&kb, n + splitmix(&s) % n);
            const a = nowNs(io);
            if (try db.get(k)) |v| {
                gpa.free(v);
                return error.Unexpected;
            }
            lat.ns.appendAssumeCapacity(@intCast(nowNs(io) - a));
            tick();
        }
        try report("get_miss", n, secondsSince(io, t), &lat, "", .{});
    }

    var pb: [16]u8 = undefined;
    {
        // latest10: newest 10 memories of a random agent (first 10 in key order).
        const queries = 100_000;
        phaseStart("latest10", queries);
        var lat: Lat = .{};
        defer lat.ns.deinit(gpa);
        try lat.ns.ensureTotalCapacity(gpa, queries);
        t = nowNs(io);
        for (0..queries) |_| {
            const p = agentPrefix(&pb, splitmix(&s) % agents);
            const a = nowNs(io);
            const got = try db.scanCount(p, false, 10);
            lat.ns.appendAssumeCapacity(@intCast(nowNs(io) - a));
            if (got != 10) return error.Short;
            tick();
        }
        try report("latest10", queries, secondsSince(io, t), &lat, "", .{});
    }
    {
        // last10_by_key: the 10 greatest keys under an agent, via reverse scan.
        const queries = 200;
        phaseStart("last10_by_key", queries);
        var lat: Lat = .{};
        defer lat.ns.deinit(gpa);
        t = nowNs(io);
        for (0..queries) |_| {
            const p = agentPrefix(&pb, splitmix(&s) % agents);
            const a = nowNs(io);
            const got = try db.scanCount(p, true, 10);
            try lat.ns.append(gpa, @intCast(nowNs(io) - a));
            if (got != 10) return error.Short;
            tick();
        }
        try report("last10_by_key", queries, secondsSince(io, t), &lat, "", .{});
    }
    {
        phaseStart("scan_all", n);
        t = nowNs(io);
        const res = try db.scanAll(io);
        if (res[0] != n) return error.Count;
        try report("scan_all", n, secondsSince(io, t), null, ",\"bytes\":{d}", .{res[1]});
    }
    {
        const threads = 4;
        const per = n / threads;
        phaseStart("get_hit_4threads", per * threads);
        const Reader = struct {
            fn run(d: *E, seed: u64, count: u64, total: u64) void {
                var st = seed;
                var b: [48]u8 = undefined;
                for (0..count) |_| {
                    const v = (d.get(key(&b, splitmix(&st) % total)) catch unreachable) orelse unreachable;
                    gpa.free(v);
                    tick();
                }
            }
        };
        var hs: [threads]std.Thread = undefined;
        t = nowNs(io);
        for (&hs, 0..) |*h, th| h.* = try std.Thread.spawn(.{}, Reader.run, .{ &db, 100 + th, per, n });
        for (hs) |h| h.join();
        try report("get_hit_4threads", per * threads, secondsSince(io, t), null, "", .{});
    }

    // Durable phases: every write is on disk before it returns.
    db.setDurable(true);
    {
        const writes = 2000;
        phaseStart("durable_put_1thread", writes);
        var lat: Lat = .{};
        defer lat.ns.deinit(gpa);
        t = nowNs(io);
        for (0..writes) |i| {
            const id = 10 * n + i;
            const a = nowNs(io);
            try db.put(key(&kb, id), value(&vb, id, 0));
            try lat.ns.append(gpa, @intCast(nowNs(io) - a));
            tick();
        }
        try report("durable_put_1thread", writes, secondsSince(io, t), &lat, "", .{});
    }
    {
        const threads = 16;
        const per = 250;
        phaseStart("durable_put_16threads", threads * per);
        const Writer = struct {
            fn run(d: *E, th: u64, total: u64) void {
                var b: [48]u8 = undefined;
                var v: [value_len]u8 = undefined;
                for (0..per) |i| {
                    const id = 20 * total + th * per + i;
                    d.put(key(&b, id), value(&v, id, 0)) catch unreachable;
                    tick();
                }
            }
        };
        const syncs_before = db.syncs();
        var hs: [threads]std.Thread = undefined;
        t = nowNs(io);
        for (&hs, 0..) |*h, th| h.* = try std.Thread.spawn(.{}, Writer.run, .{ &db, th, n });
        for (hs) |h| h.join();
        try report("durable_put_16threads", threads * per, secondsSince(io, t), null, ",\"fsyncs\":{d}", .{db.syncs() - syncs_before});
    }
    db.setDurable(false);

    {
        // snapshot_dirty: snapshots while recent writes are still buffered.
        for (0..10_000) |i| {
            const id = 30 * n + i;
            try db.put(key(&kb, id), value(&vb, id, 0));
        }
        const snaps = 1000;
        phaseStart("snapshot_dirty", snaps);
        var probe_buf: [48]u8 = undefined;
        const probe = key(&probe_buf, 30 * n + 5);
        var lat: Lat = .{};
        defer lat.ns.deinit(gpa);
        t = nowNs(io);
        for (0..snaps) |_| {
            const a = nowNs(io);
            const v = (try db.snapGet(probe)) orelse return error.Missing;
            gpa.free(v);
            try lat.ns.append(gpa, @intCast(nowNs(io) - a));
            tick();
        }
        try report("snapshot_dirty", snaps, secondsSince(io, t), &lat, "", .{});
    }
    {
        // overwrite: half of the keys again, buffered, then settle.
        const over = n / 2;
        phaseStart("overwrite", over);
        t = nowNs(io);
        for (0..over) |_| {
            const id = splitmix(&s) % n;
            try db.put(key(&kb, id), value(&vb, id, 1));
            tick();
        }
        try db.sync();
        const write_secs = secondsSince(io, t);
        try db.compact();
        const total = secondsSince(io, t);
        try report("overwrite", over, write_secs, null, ",\"settle_seconds\":{d:.6},\"disk_bytes\":{d},\"rss_kb\":{d},\"anon_kb\":{d}", .{
            total - write_secs, dirBytes(io, dir), maxRssKb(io), anonKb(io),
        });
    }
    db.close();
}

// ---------------------------------------------------------- agent workload
//
// What an agent memory service does all day. Chats hold messages keyed
// newest first; agents hold small facts they rewrite. Each turn of an agent:
//   1. loads the newest 20 messages of its chat (the context window),
//   2. reads 3 of its facts,
//   3. now and then reads the whole chat (summarize / search),
//   4. writes the user message and the reply,
//   5. now and then rewrites a fact,
//   6. commits once (durable), like a real service would before answering.
// Now and then a whole old chat is deleted.

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

/// A chat message as JSON, 60 to ~900 bytes of plain words: text that
/// compresses like real chat logs do.
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

fn msgKey(buf: *[64]u8, chat: u64, t: u64) []const u8 {
    return std.fmt.bufPrint(buf, "chat/{d:0>5}/m/{d:0>20}", .{ chat, std.math.maxInt(u64) - t }) catch unreachable;
}

fn chatPrefix(buf: *[32]u8, chat: u64) []const u8 {
    return std.fmt.bufPrint(buf, "chat/{d:0>5}/", .{chat}) catch unreachable;
}

fn factKey(buf: *[64]u8, agent: u64, f: u64) []const u8 {
    return std.fmt.bufPrint(buf, "mem/{d:0>3}/fact/{d:0>4}", .{ agent, f }) catch unreachable;
}

var clock: std.atomic.Value(u64) = .init(0);

fn runAgent(comptime E: type, io: Io, dir: []const u8) !void {
    prog_phases = 3;
    var db = try E.open(io, dir);
    var mb: std.ArrayList(u8) = .empty;
    defer mb.deinit(gpa);
    var kb: [64]u8 = undefined;

    // agent_seed: existing history, written in time order across chats.
    phaseStart("agent_seed", seed_messages + fact_agents * facts_per_agent);
    var t = nowNs(io);
    var s: u64 = 99;
    var raw_bytes: u64 = 0;
    for (0..seed_messages) |_| {
        const tm = clock.fetchAdd(1, .monotonic);
        const v = try message(&mb, tm, if (tm % 2 == 0) "user" else "assistant");
        raw_bytes += v.len;
        try db.put(msgKey(&kb, splitmix(&s) % chats, tm), v);
        tick();
    }
    for (0..fact_agents) |a| for (0..facts_per_agent) |f| {
        const v = try fact(&mb, a, f, 0);
        raw_bytes += v.len;
        try db.put(factKey(&kb, a, f), v);
        tick();
    };
    try db.sync();
    try report("agent_seed", seed_messages + fact_agents * facts_per_agent, secondsSince(io, t), null, ",\"raw_bytes\":{d},\"disk_bytes\":{d},\"rss_kb\":{d},\"anon_kb\":{d}", .{
        raw_bytes, dirBytes(io, dir), maxRssKb(io), anonKb(io),
    });

    // agent_turns: 8 agents working at once, one durable commit per turn.
    phaseStart("agent_turns", turns_total);
    const Agent = struct {
        lat: Lat = .{},
        deletes: u64 = 0,
        full_reads: u64 = 0,
        context_msgs: u64 = 0,
        failed: bool = false,

        fn run(self: *@This(), d: *E, th: u64) void {
            self.work(d, th) catch {
                self.failed = true;
            };
        }

        fn work(self: *@This(), d: *E, th: u64) !void {
            var st: u64 = 1000 + th;
            var buf: std.ArrayList(u8) = .empty;
            defer buf.deinit(gpa);
            var k: [64]u8 = undefined;
            var pb: [32]u8 = undefined;
            const agent = th % fact_agents;
            for (0..turns_total / turn_threads) |_| {
                const a = nowNs(io_g);
                const roll = splitmix(&st) % 100;
                const chat = if (roll < 80) splitmix(&st) % hot_chats else splitmix(&st) % chats;
                const p = chatPrefix(&pb, chat);
                self.context_msgs += try d.scanCount(p, false, context_len);
                for (0..3) |_| {
                    if (try d.get(factKey(&k, agent, splitmix(&st) % facts_per_agent))) |v| gpa.free(v);
                }
                if (splitmix(&st) % 100 < 3) {
                    _ = try d.scanCount(p, false, std.math.maxInt(usize));
                    self.full_reads += 1;
                }
                const t1 = clock.fetchAdd(2, .monotonic);
                try d.put(msgKey(&k, chat, t1), try message(&buf, t1, "user"));
                try d.put(msgKey(&k, chat, t1 + 1), try message(&buf, t1 + 1, "assistant"));
                if (splitmix(&st) % 100 < 10) {
                    const f = splitmix(&st) % facts_per_agent;
                    try d.put(factKey(&k, agent, f), try fact(&buf, agent, f, t1));
                }
                if (splitmix(&st) % 1000 < 10) {
                    // Delete an old, cold chat.
                    const victim = hot_chats + splitmix(&st) % (chats - hot_chats);
                    try d.deletePrefix(chatPrefix(&pb, victim));
                    self.deletes += 1;
                }
                try d.sync();
                try self.lat.ns.append(gpa, @intCast(nowNs(io_g) - a));
                tick();
            }
        }
    };
    var ags: [turn_threads]Agent = @splat(.{});
    var hs: [turn_threads]std.Thread = undefined;
    const syncs_before = db.syncs();
    t = nowNs(io);
    for (&hs, 0..) |*h, th| h.* = try std.Thread.spawn(.{}, Agent.run, .{ &ags[th], &db, th });
    for (hs) |h| h.join();
    const secs = secondsSince(io, t);
    var all: Lat = .{};
    defer all.ns.deinit(gpa);
    var deletes: u64 = 0;
    var full_reads: u64 = 0;
    var ctx: u64 = 0;
    for (&ags) |*ag| {
        if (ag.failed) return error.AgentFailed;
        try all.ns.appendSlice(gpa, ag.lat.ns.items);
        ag.lat.ns.deinit(gpa);
        deletes += ag.deletes;
        full_reads += ag.full_reads;
        ctx += ag.context_msgs;
    }
    try report("agent_turns", turns_total, secs, &all, ",\"fsyncs\":{d},\"chat_deletes\":{d},\"full_chat_reads\":{d},\"context_msgs\":{d},\"disk_bytes\":{d},\"rss_kb\":{d},\"anon_kb\":{d}", .{
        db.syncs() - syncs_before, deletes, full_reads, ctx, dirBytes(io, dir), maxRssKb(io), anonKb(io),
    });

    phaseStart("agent_reopen", 1);
    t = nowNs(io);
    db.close();
    db = try E.open(io, dir);
    const reopen_secs = secondsSince(io, t);
    // First turn after a restart: load one chat's context cold.
    const a = nowNs(io);
    var pb: [32]u8 = undefined;
    _ = try db.scanCount(chatPrefix(&pb, 7), false, context_len);
    const first_ns: u64 = @intCast(nowNs(io) - a);
    try report("agent_reopen", 1, reopen_secs, null, ",\"first_context_ns\":{d},\"anon_kb\":{d},\"disk_bytes\":{d}", .{ first_ns, anonKb(io), dirBytes(io, dir) });
    db.close();
}
