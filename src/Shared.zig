//! A thread-safe handle to a `Db`.
//!
//! Reads take a shared lock and run in parallel. Writes take the exclusive
//! lock only long enough to append to the log buffer and update the index.
//! Durable writes then go through group commit: one thread writes the
//! buffer and calls fsync for everyone waiting, so N concurrent writers
//! share one fsync instead of paying for N.

const Shared = @This();

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Db = @import("Db.zig");

gpa: Allocator,
io: Io,
db: Db,
/// Guards `db` (index and log buffer).
lock: Io.RwLock = .init,
/// Guards `synced_seq` and `syncing`. Held only briefly, never across fsync.
commit_mutex: Io.Mutex = .init,
/// Signaled when a group commit finishes.
commit_done: Io.Condition = .init,
/// Every write with seq <= this is durable. Guarded by `commit_mutex`.
synced_seq: u64 = 0,
/// Whether some thread is currently leading a group commit.
syncing: bool = false,
/// Held by the commit leader and by compaction, which closes files.
file_mutex: Io.Mutex = .init,
/// Compaction runs here rather than inside `Db` so it can hold the
/// commit lock: it closes files a group commit might be syncing.
auto_compact: bool = true,
stats: Stats = .{},

pub const Stats = struct {
    /// Number of fsyncs done by group commit.
    syncs: std.atomic.Value(u64) = .init(0),
};

pub fn open(gpa: Allocator, io: Io, parent: Io.Dir, sub_path: []const u8, options: Db.Options) !*Shared {
    const s = try gpa.create(Shared);
    errdefer gpa.destroy(s);
    var db_options = options;
    db_options.auto_compact = false;
    s.* = .{
        .gpa = gpa,
        .io = io,
        .db = try Db.open(gpa, io, parent, sub_path, db_options),
        .auto_compact = options.auto_compact,
    };
    errdefer s.db.close();
    // Recovered records may still be only in the OS cache if the last
    // process died before syncing. Sync before calling them durable.
    try s.db.log.sync();
    s.synced_seq = s.db.lastSeq();
    return s;
}

pub fn close(s: *Shared) void {
    const gpa = s.gpa;
    s.db.close();
    gpa.destroy(s);
}

pub fn put(s: *Shared, key: []const u8, value: []const u8) !void {
    var rolled = false;
    const seq = blk: {
        s.lock.lockUncancelable(s.io);
        defer s.lock.unlock(s.io);
        const before = s.db.log.segments.items.len;
        try s.db.putBuffered(key, value);
        rolled = s.db.log.segments.items.len > before;
        break :blk s.db.lastSeq();
    };
    if (s.db.options.sync_writes) try s.commit(seq);
    if (rolled and s.auto_compact) _ = try s.compact();
}

/// Like `put`, but the value expires after `ttl` seconds.
pub fn putTtl(s: *Shared, key: []const u8, value: []const u8, ttl: u32) !void {
    var rolled = false;
    const seq = blk: {
        s.lock.lockUncancelable(s.io);
        defer s.lock.unlock(s.io);
        const before = s.db.log.segments.items.len;
        try s.db.putTtlBuffered(key, value, ttl);
        rolled = s.db.log.segments.items.len > before;
        break :blk s.db.lastSeq();
    };
    if (s.db.options.sync_writes) try s.commit(seq);
    if (rolled and s.auto_compact) _ = try s.compact();
}

/// Deletes every key under `prefix`. See `Db.deletePrefix`.
pub fn deletePrefix(s: *Shared, prefix: []const u8) !usize {
    var rolled = false;
    var seq: u64 = 0;
    const n = blk: {
        s.lock.lockUncancelable(s.io);
        defer s.lock.unlock(s.io);
        const before = s.db.log.segments.items.len;
        const n = try s.db.deletePrefixBuffered(prefix);
        rolled = s.db.log.segments.items.len > before;
        seq = s.db.lastSeq();
        break :blk n;
    };
    if (n > 0 and s.db.options.sync_writes) try s.commit(seq);
    if (rolled and s.auto_compact) _ = try s.compact();
    return n;
}

/// Rewrites mostly dead segments. Blocks writers and readers while it runs.
pub fn compact(s: *Shared) !usize {
    s.file_mutex.lockUncancelable(s.io);
    defer s.file_mutex.unlock(s.io);
    const n, const durable = blk: {
        s.lock.lockUncancelable(s.io);
        defer s.lock.unlock(s.io);
        const n = try s.db.compact();
        break :blk .{ n, s.db.lastSeq() };
    };
    if (n > 0) {
        // Compaction syncs the log, so everything accepted so far is durable.
        s.commit_mutex.lockUncancelable(s.io);
        s.synced_seq = @max(s.synced_seq, durable);
        s.commit_done.broadcast(s.io);
        s.commit_mutex.unlock(s.io);
    }
    return n;
}

pub fn delete(s: *Shared, key: []const u8) !bool {
    var seq: u64 = 0;
    var rolled = false;
    const existed = blk: {
        s.lock.lockUncancelable(s.io);
        defer s.lock.unlock(s.io);
        const before = s.db.log.segments.items.len;
        const existed = try s.db.deleteBuffered(key);
        rolled = s.db.log.segments.items.len > before;
        seq = s.db.lastSeq();
        break :blk existed;
    };
    if (existed and s.db.options.sync_writes) try s.commit(seq);
    if (rolled and s.auto_compact) _ = try s.compact();
    return existed;
}

/// Makes every write accepted so far durable.
pub fn sync(s: *Shared) !void {
    const seq = blk: {
        s.lock.lockSharedUncancelable(s.io);
        defer s.lock.unlockShared(s.io);
        break :blk s.db.lastSeq();
    };
    try s.commit(seq);
}

/// Returns once every write with sequence <= `seq` is durable.
///
/// The first waiter becomes the leader: it writes the log buffer and calls
/// fsync without holding any lock, so other writers keep appending in the
/// meantime. When it finishes, everyone it covered returns and one of the
/// rest leads the next round, which covers all of them at once.
fn commit(s: *Shared, seq: u64) !void {
    s.commit_mutex.lockUncancelable(s.io);
    defer s.commit_mutex.unlock(s.io);
    while (s.synced_seq < seq) {
        if (s.syncing) {
            s.commit_done.waitUncancelable(s.io, &s.commit_mutex);
            continue;
        }
        s.syncing = true;
        s.commit_mutex.unlock(s.io);
        const result = s.syncNow();
        s.commit_mutex.lockUncancelable(s.io);
        s.syncing = false;
        if (result) |target| {
            s.synced_seq = @max(s.synced_seq, target);
        } else |_| {}
        s.commit_done.broadcast(s.io);
        _ = try result;
    }
}

/// Writes the buffer and fsyncs. Returns the sequence number now durable.
fn syncNow(s: *Shared) !u64 {
    s.file_mutex.lockUncancelable(s.io);
    defer s.file_mutex.unlock(s.io);
    var target: u64 = undefined;
    var file: Io.File = undefined;
    {
        s.lock.lockUncancelable(s.io);
        defer s.lock.unlock(s.io);
        try s.db.log.flush();
        target = s.db.lastSeq();
        file = s.db.log.active;
    }
    // Earlier segments were synced when they were sealed.
    file.sync(s.io) catch |err| {
        s.lock.lockUncancelable(s.io);
        s.db.log.poisoned = true;
        s.lock.unlock(s.io);
        return err;
    };
    _ = s.stats.syncs.fetchAdd(1, .monotonic);
    return target;
}

/// Returns a copy of the value for `key`, owned by the caller.
pub fn get(s: *Shared, gpa: Allocator, key: []const u8) !?[]u8 {
    s.lock.lockSharedUncancelable(s.io);
    defer s.lock.unlockShared(s.io);
    const e = s.db.lookup(key) orelse return null;
    return try s.copyValue(gpa, e.*);
}

/// Reads a value without touching `Db`'s shared scratch buffer, so it is
/// safe under the shared lock.
fn copyValue(s: *Shared, gpa: Allocator, e: Db.Entry) ![]u8 {
    if (try s.db.log.view(e.location())) |rec| return try gpa.dupe(u8, rec.value);
    const buf = try gpa.alloc(u8, e.len);
    defer gpa.free(buf);
    const rec = try s.db.log.read(e.location(), buf);
    return try gpa.dupe(u8, rec.value);
}

/// Applies `ops` atomically. See `Db.write`.
pub fn write(s: *Shared, ops: []const Db.Op) !void {
    var rolled = false;
    const seq = blk: {
        s.lock.lockUncancelable(s.io);
        defer s.lock.unlock(s.io);
        const before = s.db.log.segments.items.len;
        try s.db.writeBuffered(ops);
        rolled = s.db.log.segments.items.len > before;
        break :blk s.db.lastSeq();
    };
    if (s.db.options.sync_writes) try s.commit(seq);
    if (rolled and s.auto_compact) _ = try s.compact();
}

/// Compare-and-swap. See `Db.putIf`. The check and the write happen under
/// one lock, so concurrent callers can't both win.
pub fn putIf(s: *Shared, key: []const u8, value: []const u8, expect: Db.Expect) !void {
    var rolled = false;
    const seq = blk: {
        s.lock.lockUncancelable(s.io);
        defer s.lock.unlock(s.io);
        const current = s.db.seqOf(key);
        const ok = switch (expect) {
            .absent => current == null,
            .seq => |want| current != null and current.? == want,
        };
        if (!ok) return error.Conflict;
        const before = s.db.log.segments.items.len;
        try s.db.putBuffered(key, value);
        rolled = s.db.log.segments.items.len > before;
        break :blk s.db.lastSeq();
    };
    if (s.db.options.sync_writes) try s.commit(seq);
    if (rolled and s.auto_compact) _ = try s.compact();
}

pub fn seqOf(s: *Shared, key: []const u8) ?u64 {
    s.lock.lockSharedUncancelable(s.io);
    defer s.lock.unlockShared(s.io);
    return s.db.seqOf(key);
}

pub fn snapshot(s: *Shared) !Db.Snapshot {
    s.lock.lockUncancelable(s.io);
    defer s.lock.unlock(s.io);
    return s.db.snapshot();
}

pub fn release(s: *Shared, snap: Db.Snapshot) void {
    s.lock.lockUncancelable(s.io);
    defer s.lock.unlock(s.io);
    s.db.release(snap);
}

/// The value of `key` as of `snap`, copied for the caller.
pub fn getAt(s: *Shared, gpa: Allocator, snap: Db.Snapshot, key: []const u8) !?[]u8 {
    s.lock.lockSharedUncancelable(s.io);
    defer s.lock.unlockShared(s.io);
    const e = s.db.index.getPtr(key) orelse return null;
    const v = e.resolve(snap.seq, s.db.now()) orelse return null;
    return try s.copyValue(gpa, v.*);
}

/// Copies up to `limit` pairs from `range`, at `snap` if given. Free the
/// result with `Db.freePairs`.
pub fn scan(s: *Shared, gpa: Allocator, range: Db.Range, snap: ?Db.Snapshot, limit: usize) ![]Db.Pair {
    // Each scan reads into its own buffer, so scans can share the lock.
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    s.lock.lockSharedUncancelable(s.io);
    defer s.lock.unlockShared(s.io);
    var it = s.db.iterator(range);
    if (snap) |sn| it.at = sn.seq;
    it.buf = &buf;
    it.buf_gpa = gpa;
    return Db.collect(gpa, &it, limit);
}

/// The newest `n` entries under `prefix`. See `Db.latest`.
pub fn latest(s: *Shared, gpa: Allocator, prefix: []const u8, n: usize) ![]Db.Pair {
    const end_buf = try gpa.alloc(u8, prefix.len);
    defer gpa.free(end_buf);
    return s.scan(gpa, Db.prefixRange(prefix, true, end_buf), null, n);
}

pub fn contains(s: *Shared, key: []const u8) bool {
    s.lock.lockSharedUncancelable(s.io);
    defer s.lock.unlockShared(s.io);
    return s.db.contains(key);
}

pub fn count(s: *Shared) usize {
    s.lock.lockSharedUncancelable(s.io);
    defer s.lock.unlockShared(s.io);
    return s.db.count();
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

const Writer = struct {
    fn run(s: *Shared, id: usize, n: usize, failed: *std.atomic.Value(bool)) void {
        for (0..n) |i| {
            var kb: [32]u8 = undefined;
            const key = std.fmt.bufPrint(&kb, "w{d}/{d:0>6}", .{ id, i }) catch unreachable;
            s.put(key, key) catch {
                failed.store(true, .seq_cst);
                return;
            };
        }
    }
};

test "concurrent durable writers share fsyncs and lose nothing" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const threads = 8;
    const per_thread = 50;
    {
        const s = try Shared.open(testing.allocator, io, tmp.dir, "db", .{});
        defer s.close();
        var failed: std.atomic.Value(bool) = .init(false);
        var handles: [threads]std.Thread = undefined;
        for (&handles, 0..) |*h, id| h.* = try std.Thread.spawn(.{}, Writer.run, .{ s, id, per_thread, &failed });
        for (handles) |h| h.join();
        try testing.expect(!failed.load(.seq_cst));
        try testing.expectEqual(@as(usize, threads * per_thread), s.count());
        // Group commit never needs more fsyncs than writes.
        try testing.expect(s.stats.syncs.load(.monotonic) <= threads * per_thread);
        try testing.expectEqual(s.db.lastSeq(), s.synced_seq);
    }

    const s = try Shared.open(testing.allocator, io, tmp.dir, "db", .{});
    defer s.close();
    try testing.expectEqual(@as(usize, threads * per_thread), s.count());
    const v = (try s.get(testing.allocator, "w3/000049")).?;
    defer testing.allocator.free(v);
    try testing.expectEqualStrings("w3/000049", v);
}

const Incrementer = struct {
    fn run(s: *Shared, n: usize, failed: *std.atomic.Value(bool)) void {
        var buf: [32]u8 = undefined;
        var done: usize = 0;
        while (done < n) {
            const cur = s.get(testing.allocator, "counter") catch return failed.store(true, .seq_cst);
            const value: u64 = if (cur) |c| std.fmt.parseInt(u64, c, 10) catch 0 else 0;
            if (cur) |c| testing.allocator.free(c);
            const expect: Db.Expect = if (s.seqOf("counter")) |sq| .{ .seq = sq } else .absent;
            // Re-read under the expectation: a stale value fails the swap.
            const fresh = s.get(testing.allocator, "counter") catch return failed.store(true, .seq_cst);
            const fresh_value: u64 = if (fresh) |c| std.fmt.parseInt(u64, c, 10) catch 0 else 0;
            if (fresh) |c| testing.allocator.free(c);
            if (fresh_value != value) continue;
            const next = std.fmt.bufPrint(&buf, "{d}", .{value + 1}) catch unreachable;
            s.putIf("counter", next, expect) catch |err| switch (err) {
                error.Conflict => continue,
                else => return failed.store(true, .seq_cst),
            };
            done += 1;
        }
    }
};

test "compare-and-swap counter under contention" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const s = try Shared.open(testing.allocator, io, tmp.dir, "db", .{ .sync_writes = false });
    defer s.close();

    var failed: std.atomic.Value(bool) = .init(false);
    var handles: [4]std.Thread = undefined;
    for (&handles) |*h| h.* = try std.Thread.spawn(.{}, Incrementer.run, .{ s, 200, &failed });
    for (handles) |h| h.join();
    try testing.expect(!failed.load(.seq_cst));
    const v = (try s.get(testing.allocator, "counter")).?;
    defer testing.allocator.free(v);
    try testing.expectEqualStrings("800", v);
}

test "shared snapshot and latest" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const s = try Shared.open(testing.allocator, io, tmp.dir, "db", .{ .sync_writes = false });
    defer s.close();
    try s.put("m/1", "one");
    try s.put("m/2", "two");
    const snap = try s.snapshot();
    try s.put("m/3", "three");
    _ = try s.delete("m/1");

    const now = try s.latest(testing.allocator, "m/", 10);
    defer Db.freePairs(testing.allocator, now);
    try testing.expectEqual(@as(usize, 2), now.len);
    try testing.expectEqualStrings("m/3", now[0].key);

    const then = try s.scan(testing.allocator, .{}, snap, 10);
    defer Db.freePairs(testing.allocator, then);
    try testing.expectEqual(@as(usize, 2), then.len);
    try testing.expectEqualStrings("one", then[0].value);

    const old = (try s.getAt(testing.allocator, snap, "m/1")).?;
    defer testing.allocator.free(old);
    try testing.expectEqualStrings("one", old);
    s.release(snap);
}
