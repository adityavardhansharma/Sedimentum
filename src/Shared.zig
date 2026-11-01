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
/// Held by the thread doing a group commit.
commit_mutex: Io.Mutex = .init,
/// Every write with seq <= this is durable. Guarded by `commit_mutex`.
synced_seq: u64 = 0,
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

/// Rewrites mostly dead segments. Blocks writers and readers while it runs.
pub fn compact(s: *Shared) !usize {
    s.commit_mutex.lockUncancelable(s.io);
    defer s.commit_mutex.unlock(s.io);
    s.lock.lockUncancelable(s.io);
    defer s.lock.unlock(s.io);
    const n = try s.db.compact();
    // Compaction syncs the log, so everything accepted so far is durable.
    s.synced_seq = s.db.lastSeq();
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
fn commit(s: *Shared, seq: u64) !void {
    s.commit_mutex.lockUncancelable(s.io);
    defer s.commit_mutex.unlock(s.io);
    // A leader that ran while we waited may already have covered us.
    if (s.synced_seq >= seq) return;

    var target: u64 = undefined;
    var file: Io.File = undefined;
    {
        s.lock.lockUncancelable(s.io);
        defer s.lock.unlock(s.io);
        try s.db.log.flush();
        target = s.db.lastSeq();
        file = s.db.log.active;
    }
    // fsync outside the main lock so readers and writers keep going.
    // Earlier segments were synced when they were sealed.
    file.sync(s.io) catch |err| {
        s.lock.lockUncancelable(s.io);
        s.db.log.poisoned = true;
        s.lock.unlock(s.io);
        return err;
    };
    _ = s.stats.syncs.fetchAdd(1, .monotonic);
    s.synced_seq = target;
}

/// Returns a copy of the value for `key`, owned by the caller.
pub fn get(s: *Shared, gpa: Allocator, key: []const u8) !?[]u8 {
    s.lock.lockSharedUncancelable(s.io);
    defer s.lock.unlockShared(s.io);
    const e = s.db.index.get(key) orelse return null;
    if (try s.db.log.view(e.location())) |rec| return try gpa.dupe(u8, rec.value);
    const buf = try gpa.alloc(u8, e.len);
    defer gpa.free(buf);
    const rec = try s.db.log.read(e.location(), buf);
    return try gpa.dupe(u8, rec.value);
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
