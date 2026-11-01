//! Sedimentum side of the head-to-head benchmark with kiban. Keep the
//! workloads in step with `bench/kiban-bench/src/main.rs`: same keys,
//! values, order and phases. Prints one JSON object per phase.
//!
//!   zig build -Doptimize=ReleaseFast && zig-out/bin/sedimentum-bench <dir> [records]

const std = @import("std");
const Io = std.Io;
const sdm = @import("sedimentum");
const Db = sdm.Db;
const Shared = sdm.Shared;

const agents: u64 = 64;
const value_len = 200;

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

fn shuffled(gpa: std.mem.Allocator, n: u64, seed: u64) ![]u64 {
    const ids = try gpa.alloc(u64, n);
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

fn dirBytes(io: Io, path: []const u8) u64 {
    var dir = Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return 0;
    defer dir.close(io);
    var total: u64 = 0;
    var it = dir.iterate();
    while (it.next(io) catch null) |e| {
        if (e.kind != .file) continue;
        const st = dir.statFile(io, e.name, .{}) catch continue;
        total += st.size;
    }
    return total;
}

fn maxRssKb(io: Io) u64 {
    var buf: [4096]u8 = undefined;
    const text = Io.Dir.cwd().readFile(io, "/proc/self/status", &buf) catch return 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "VmHWM:")) continue;
        var parts = std.mem.tokenizeAny(u8, line[6..], " \t");
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
    try w.print("{{\"engine\":\"sedimentum\",\"phase\":\"{s}\",\"ops\":{d},\"seconds\":{d:.6},\"ops_per_sec\":{d:.1},\"p50_ns\":{d},\"p99_ns\":{d}", .{
        phase, ops, secs, @as(f64, @floatFromInt(ops)) / secs, p50, p99,
    });
    try w.print(extra_fmt ++ "}}\n", extra);
    try w.flush();
}

fn open(gpa: std.mem.Allocator, io: Io, dir: []const u8) !*Shared {
    return Shared.open(gpa, io, Io.Dir.cwd(), dir, .{ .sync_writes = false });
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = std.heap.smp_allocator;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const dir = args[1];
    const n: u64 = if (args.len > 2) try std.fmt.parseInt(u64, args[2], 10) else 1_000_000;
    out = Io.File.stdout().writerStreaming(io, &out_buf);

    Io.Dir.cwd().deleteTree(io, dir) catch {};
    var db = try open(gpa, io, dir);

    var kb: [48]u8 = undefined;
    var vb: [value_len]u8 = undefined;

    // load: n buffered puts in random order, then one sync.
    const order = try shuffled(gpa, n, 1);
    defer gpa.free(order);
    var t = nowNs(io);
    for (order) |id| try db.put(key(&kb, id), value(&vb, id, 0));
    try db.sync();
    try report("load", n, secondsSince(io, t), null, ",\"rss_kb\":{d}", .{maxRssKb(io)});

    t = nowNs(io);
    _ = try db.compact();
    try report("settle", 1, secondsSince(io, t), null, ",\"disk_bytes\":{d}", .{dirBytes(io, dir)});

    t = nowNs(io);
    db.close();
    db = try open(gpa, io, dir);
    try report("reopen", 1, secondsSince(io, t), null, "", .{});

    var s: u64 = 7;
    {
        var lat: Lat = .{};
        defer lat.ns.deinit(gpa);
        try lat.ns.ensureTotalCapacity(gpa, n);
        t = nowNs(io);
        for (0..n) |_| {
            const k = key(&kb, splitmix(&s) % n);
            const a = nowNs(io);
            const v = (try db.get(gpa, k)) orelse return error.Missing;
            gpa.free(v);
            lat.ns.appendAssumeCapacity(@intCast(nowNs(io) - a));
        }
        try report("get_hit", n, secondsSince(io, t), &lat, "", .{});
    }
    {
        var lat: Lat = .{};
        defer lat.ns.deinit(gpa);
        try lat.ns.ensureTotalCapacity(gpa, n);
        t = nowNs(io);
        for (0..n) |_| {
            const k = key(&kb, n + splitmix(&s) % n);
            const a = nowNs(io);
            if (try db.get(gpa, k)) |v| {
                gpa.free(v);
                return error.Unexpected;
            }
            lat.ns.appendAssumeCapacity(@intCast(nowNs(io) - a));
        }
        try report("get_miss", n, secondsSince(io, t), &lat, "", .{});
    }

    var pb: [16]u8 = undefined;
    var eb: [16]u8 = undefined;
    {
        // latest10: newest 10 memories of a random agent (first 10 in key order).
        const queries = 100_000;
        var lat: Lat = .{};
        defer lat.ns.deinit(gpa);
        try lat.ns.ensureTotalCapacity(gpa, queries);
        t = nowNs(io);
        for (0..queries) |_| {
            const p = agentPrefix(&pb, splitmix(&s) % agents);
            const a = nowNs(io);
            const got = try db.scan(gpa, Db.prefixRange(p, false, &eb), null, 10);
            Db.freePairs(gpa, got);
            lat.ns.appendAssumeCapacity(@intCast(nowNs(io) - a));
            if (got.len != 10) return error.Short;
        }
        try report("latest10", queries, secondsSince(io, t), &lat, "", .{});
    }
    {
        // last10_by_key: the 10 greatest keys under an agent, via reverse scan.
        const queries = 200;
        var lat: Lat = .{};
        defer lat.ns.deinit(gpa);
        t = nowNs(io);
        for (0..queries) |_| {
            const p = agentPrefix(&pb, splitmix(&s) % agents);
            const a = nowNs(io);
            const got = try db.scan(gpa, Db.prefixRange(p, true, &eb), null, 10);
            Db.freePairs(gpa, got);
            try lat.ns.append(gpa, @intCast(nowNs(io) - a));
            if (got.len != 10) return error.Short;
        }
        try report("last10_by_key", queries, secondsSince(io, t), &lat, "", .{});
    }
    {
        t = nowNs(io);
        db.lock.lockSharedUncancelable(io);
        var it = db.db.iterator(.{});
        var count: u64 = 0;
        var bytes: usize = 0;
        while (try it.next()) |p| {
            bytes += p.key.len + p.value.len;
            count += 1;
        }
        db.lock.unlockShared(io);
        if (count != n) return error.Count;
        try report("scan_all", n, secondsSince(io, t), null, ",\"bytes\":{d}", .{bytes});
    }
    {
        const threads = 4;
        const per = n / threads;
        const Reader = struct {
            fn run(d: *Shared, seed: u64, count: u64, total: u64) void {
                var st = seed;
                var b: [48]u8 = undefined;
                for (0..count) |_| {
                    const v = (d.get(gpa, key(&b, splitmix(&st) % total)) catch unreachable) orelse unreachable;
                    gpa.free(v);
                }
            }
        };
        var hs: [threads]std.Thread = undefined;
        t = nowNs(io);
        for (&hs, 0..) |*h, th| h.* = try std.Thread.spawn(.{}, Reader.run, .{ db, 100 + th, per, n });
        for (hs) |h| h.join();
        try report("get_hit_4threads", per * threads, secondsSince(io, t), null, "", .{});
    }

    // Durable phases: every write is on disk before it returns.
    db.db.options.sync_writes = true;
    {
        const writes = 2000;
        var lat: Lat = .{};
        defer lat.ns.deinit(gpa);
        t = nowNs(io);
        for (0..writes) |i| {
            const id = 10 * n + i;
            const a = nowNs(io);
            try db.put(key(&kb, id), value(&vb, id, 0));
            try lat.ns.append(gpa, @intCast(nowNs(io) - a));
        }
        try report("durable_put_1thread", writes, secondsSince(io, t), &lat, "", .{});
    }
    {
        const threads = 16;
        const per = 250;
        const Writer = struct {
            fn run(d: *Shared, th: u64, total: u64) void {
                var b: [48]u8 = undefined;
                var v: [value_len]u8 = undefined;
                for (0..per) |i| {
                    const id = 20 * total + th * per + i;
                    d.put(key(&b, id), value(&v, id, 0)) catch unreachable;
                }
            }
        };
        const syncs_before = db.stats.syncs.load(.monotonic);
        var hs: [threads]std.Thread = undefined;
        t = nowNs(io);
        for (&hs, 0..) |*h, th| h.* = try std.Thread.spawn(.{}, Writer.run, .{ db, th, n });
        for (hs) |h| h.join();
        try report("durable_put_16threads", threads * per, secondsSince(io, t), null, ",\"fsyncs\":{d}", .{db.stats.syncs.load(.monotonic) - syncs_before});
    }
    db.db.options.sync_writes = false;

    {
        // snapshot_dirty: snapshots while recent writes are still buffered.
        for (0..10_000) |i| {
            const id = 30 * n + i;
            try db.put(key(&kb, id), value(&vb, id, 0));
        }
        const snaps = 1000;
        var probe_buf: [48]u8 = undefined;
        const probe = key(&probe_buf, 30 * n + 5);
        var lat: Lat = .{};
        defer lat.ns.deinit(gpa);
        t = nowNs(io);
        for (0..snaps) |_| {
            const a = nowNs(io);
            const snap = try db.snapshot();
            const v = (try db.getAt(gpa, snap, probe)) orelse return error.Missing;
            gpa.free(v);
            db.release(snap);
            try lat.ns.append(gpa, @intCast(nowNs(io) - a));
        }
        try report("snapshot_dirty", snaps, secondsSince(io, t), &lat, "", .{});
    }
    {
        // overwrite: half of the keys again, buffered, then settle.
        const over = n / 2;
        t = nowNs(io);
        for (0..over) |_| {
            const id = splitmix(&s) % n;
            try db.put(key(&kb, id), value(&vb, id, 1));
        }
        try db.sync();
        const write_secs = secondsSince(io, t);
        _ = try db.compact();
        const total = secondsSince(io, t);
        try report("overwrite", over, write_secs, null, ",\"settle_seconds\":{d:.6},\"disk_bytes\":{d},\"rss_kb\":{d}", .{
            total - write_secs, dirBytes(io, dir), maxRssKb(io),
        });
    }
    db.close();
}
