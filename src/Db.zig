//! The database: an append-only log on disk plus an ordered index in memory.
//!
//! The index maps every live key to the location of its newest record, so a
//! point read is one tree lookup plus one read of the record. Deleted keys
//! are removed from the index; their tombstones stay in the log until
//! compaction.
//!
//! Compaction rewrites the live records of a mostly dead sealed segment to
//! the end of the log, keeping their sequence numbers, then deletes the old
//! file. Recovery therefore resolves each key by the highest sequence
//! number seen, not by file order.
//!
//! A `Db` is used from one thread at a time. See `Shared` for threads.

const Db = @This();

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const record = @import("record.zig");
const Log = @import("Log.zig");
const ordered = @import("index.zig");

pub const Options = struct {
    log: Log.Options = .{},
    /// Sync after every write so a successful `put` or `delete` is durable.
    /// Turn off to batch writes and call `sync` yourself.
    sync_writes: bool = true,
    /// Compact a sealed segment once at least this fraction of it is dead.
    compact_dead_ratio: f64 = 0.5,
    /// Check for segments to compact whenever the log starts a new segment.
    auto_compact: bool = true,
};

/// What the index stores per key.
pub const Entry = struct {
    segment: u32,
    offset: u32,
    len: u32,
    seq: u64,

    pub fn location(e: Entry) Log.Location {
        return .{ .segment = e.segment, .offset = e.offset, .len = e.len };
    }

    fn from(loc: Log.Location, seq: u64) Entry {
        return .{
            .segment = @intCast(loc.segment),
            .offset = @intCast(loc.offset),
            .len = loc.len,
            .seq = seq,
        };
    }
};

pub const Index = ordered.OrderedMap(Entry);

/// Per-segment bookkeeping for compaction.
const SegStat = struct {
    /// Bytes of records the index still points to.
    live: u64 = 0,
    /// Lowest sequence number of any record in the segment.
    min_seq: u64 = std.math.maxInt(u64),
};

gpa: Allocator,
options: Options,
log: Log,
index: Index,
seg_stats: std.AutoHashMapUnmanaged(u64, SegStat) = .empty,
/// Scratch space for reading records.
read_buf: std.ArrayList(u8) = .empty,
compactions: u64 = 0,

pub fn open(gpa: Allocator, io: Io, parent: Io.Dir, sub_path: []const u8, options: Options) !Db {
    var idx = try Index.init(gpa);
    errdefer idx.deinit();
    var loader: Loader = .{ .gpa = gpa, .index = &idx };
    defer loader.deinit();
    var log = try Log.open(gpa, io, parent, sub_path, options.log, &loader);
    errdefer log.close();

    var db: Db = .{ .gpa = gpa, .options = options, .log = log, .index = idx, .seg_stats = loader.stats };
    loader.stats = .empty;
    errdefer db.seg_stats.deinit(gpa);
    // Live bytes come from what the index ended up pointing to.
    var c = db.index.first();
    while (c.valid()) : (c.next()) {
        const e = c.valuePtr().*;
        (try db.statFor(e.segment)).live += e.len;
    }
    return db;
}

pub fn close(db: *Db) void {
    db.read_buf.deinit(db.gpa);
    db.seg_stats.deinit(db.gpa);
    db.index.deinit();
    db.log.close();
    db.* = undefined;
}

/// Rebuilds the index during open. The highest sequence number wins.
const Loader = struct {
    gpa: Allocator,
    index: *Index,
    /// Sequence of the newest tombstone seen per deleted key.
    dead: std.StringHashMapUnmanaged(u64) = .empty,
    stats: std.AutoHashMapUnmanaged(u64, SegStat) = .empty,

    fn deinit(l: *Loader) void {
        var it = l.dead.keyIterator();
        while (it.next()) |k| l.gpa.free(k.*);
        l.dead.deinit(l.gpa);
        l.stats.deinit(l.gpa);
    }

    pub fn onRecord(l: *Loader, loc: Log.Location, rec: record.Record) !void {
        const st = try l.stats.getOrPut(l.gpa, loc.segment);
        if (!st.found_existing) st.value_ptr.* = .{};
        st.value_ptr.min_seq = @min(st.value_ptr.min_seq, rec.seq);

        switch (rec.kind) {
            .put => {
                if (l.dead.get(rec.key)) |dseq| if (dseq > rec.seq) return;
                const slot = try l.index.getOrPut(rec.key);
                if (slot.found_existing and slot.value_ptr.seq > rec.seq) return;
                slot.value_ptr.* = Entry.from(loc, rec.seq);
            },
            .delete => {
                if (l.index.getPtr(rec.key)) |e| {
                    if (e.seq > rec.seq) return;
                    _ = l.index.remove(rec.key);
                }
                const gop = try l.dead.getOrPut(l.gpa, rec.key);
                if (!gop.found_existing) {
                    gop.key_ptr.* = l.gpa.dupe(u8, rec.key) catch |err| {
                        l.dead.removeByPtr(gop.key_ptr);
                        return err;
                    };
                    gop.value_ptr.* = rec.seq;
                } else gop.value_ptr.* = @max(gop.value_ptr.*, rec.seq);
            },
            _ => return error.Corrupt,
        }
    }
};

fn statFor(db: *Db, segment: u64) !*SegStat {
    const gop = try db.seg_stats.getOrPut(db.gpa, segment);
    if (!gop.found_existing) gop.value_ptr.* = .{};
    return gop.value_ptr;
}

/// Records that `e` is no longer referenced by the index.
fn release(db: *Db, e: Entry) void {
    if (db.seg_stats.getPtr(e.segment)) |st| st.live -|= e.len;
}

/// Number of live keys.
pub fn count(db: *const Db) usize {
    return db.index.count;
}

/// The sequence number of the newest write.
pub fn lastSeq(db: *const Db) u64 {
    return db.log.last_seq;
}

pub fn put(db: *Db, key: []const u8, value: []const u8) !void {
    try db.putBuffered(key, value);
    if (db.options.sync_writes) try db.log.sync();
}

/// Applies a put without syncing, whatever `sync_writes` says.
pub fn putBuffered(db: *Db, key: []const u8, value: []const u8) !void {
    try record.validate(.{ .seq = 1, .kind = .put, .key = key, .value = value });
    const segments_before = db.log.segments.items.len;
    // Reserve the index slot and stats first so a failed allocation can't
    // leave a record in the log that the index never saw.
    const slot = try db.index.getOrPut(key);
    const seq = db.log.last_seq + 1;
    const loc = db.appendTracked(.{ .seq = seq, .kind = .put, .key = key, .value = value }) catch |err| {
        if (!slot.found_existing) _ = db.index.remove(key);
        return err;
    };
    if (slot.found_existing) db.release(slot.value_ptr.*);
    slot.value_ptr.* = Entry.from(loc, seq);
    (db.seg_stats.getPtr(loc.segment).?).live += loc.len;
    try db.afterAppend(segments_before);
}

/// Appends a record and makes sure its segment has stats.
fn appendTracked(db: *Db, rec: record.Record) !Log.Location {
    const loc = try db.log.append(rec);
    const st = db.statFor(loc.segment) catch |err| {
        // The record is in the log buffer but untracked. Poison so it
        // can't be acknowledged in a state the index disagrees with.
        db.log.poisoned = true;
        return err;
    };
    st.min_seq = @min(st.min_seq, rec.seq);
    return loc;
}

fn afterAppend(db: *Db, segments_before: usize) !void {
    if (db.options.auto_compact and db.log.segments.items.len > segments_before) {
        _ = try db.compact();
    }
}

/// Deletes `key`. Returns whether it existed. Deleting a missing key
/// writes nothing.
pub fn delete(db: *Db, key: []const u8) !bool {
    const existed = try db.deleteBuffered(key);
    if (existed and db.options.sync_writes) try db.log.sync();
    return existed;
}

/// Applies a delete without syncing, whatever `sync_writes` says.
pub fn deleteBuffered(db: *Db, key: []const u8) !bool {
    if (key.len == 0) return error.EmptyKey;
    if (db.index.getPtr(key) == null) return false;
    const segments_before = db.log.segments.items.len;
    _ = try db.appendTracked(.{ .seq = db.log.last_seq + 1, .kind = .delete, .key = key });
    db.release(db.index.remove(key).?);
    try db.afterAppend(segments_before);
    return true;
}

pub fn contains(db: *const Db, key: []const u8) bool {
    return db.index.getPtr(key) != null;
}

/// Returns a copy of the value for `key`, owned by the caller.
pub fn get(db: *Db, gpa: Allocator, key: []const u8) !?[]u8 {
    const value = (try db.getView(key)) orelse return null;
    return try gpa.dupe(u8, value);
}

/// Returns the value for `key` without copying. The slice is valid until
/// the next call on this `Db`.
pub fn getView(db: *Db, key: []const u8) !?[]const u8 {
    const e = db.index.get(key) orelse return null;
    return try db.readValue(e);
}

fn readValue(db: *Db, e: Entry) ![]const u8 {
    if (try db.log.view(e.location())) |rec| return rec.value;
    try db.read_buf.resize(db.gpa, e.len);
    const rec = try db.log.read(e.location(), db.read_buf.items);
    return rec.value;
}

/// Makes every accepted write durable.
pub fn sync(db: *Db) !void {
    try db.log.sync();
}

// ------------------------------------------------------------ compaction

pub const SpaceStats = struct {
    segments: usize,
    total_bytes: u64,
    live_bytes: u64,
};

pub fn spaceStats(db: *const Db) SpaceStats {
    var total: u64 = 0;
    var live: u64 = 0;
    for (db.log.segments.items) |id| {
        total += db.log.segmentSize(id);
        if (db.seg_stats.get(id)) |st| live += st.live;
    }
    return .{ .segments = db.log.segments.items.len, .total_bytes = total, .live_bytes = live };
}

/// Compacts every sealed segment that is at least `compact_dead_ratio`
/// dead. Returns how many segments were rewritten.
pub fn compact(db: *Db) !usize {
    return db.compactWithRatio(db.options.compact_dead_ratio);
}

/// Like `compact`, with an explicit threshold. 0 compacts every sealed
/// segment that has any dead bytes.
pub fn compactWithRatio(db: *Db, dead_ratio: f64) !usize {
    // Copy the candidate list: compaction changes `segments`.
    var candidates: std.ArrayList(u64) = .empty;
    defer candidates.deinit(db.gpa);
    for (db.log.segments.items) |id| {
        if (id == db.log.active_id) continue;
        const size = db.log.segmentSize(id);
        if (size == 0) {
            try candidates.append(db.gpa, id);
            continue;
        }
        const live = if (db.seg_stats.get(id)) |st| st.live else 0;
        const dead = 1.0 - @as(f64, @floatFromInt(live)) / @as(f64, @floatFromInt(size));
        if (dead > 0 and dead >= dead_ratio) try candidates.append(db.gpa, id);
    }
    for (candidates.items) |id| try db.compactSegment(id);
    return candidates.items.len;
}

fn compactSegment(db: *Db, id: u64) !void {
    var scanner = try db.log.scanSegment(id);
    defer scanner.deinit();
    while (try scanner.next()) |item| {
        const rec = item.record;
        switch (rec.kind) {
            .put => {
                const e = db.index.getPtr(rec.key) orelse continue;
                if (e.segment != id or e.offset != item.offset) continue;
                const loc = try db.log.appendRaw(scanner.lastBytes());
                const st = try db.statFor(loc.segment);
                st.min_seq = @min(st.min_seq, rec.seq);
                st.live += loc.len;
                e.* = Entry.from(loc, rec.seq);
            },
            .delete => {
                // A newer put already shadows anything older.
                if (db.index.getPtr(rec.key) != null) continue;
                if (!db.olderDataMayExist(id, rec.seq)) continue;
                const loc = try db.log.appendRaw(scanner.lastBytes());
                const st = try db.statFor(loc.segment);
                st.min_seq = @min(st.min_seq, rec.seq);
            },
            _ => return error.Corrupt,
        }
    }
    if (scanner.stop != .end) return error.Corrupt;
    // Copies must be durable before the originals disappear.
    try db.log.sync();
    try db.log.removeSegment(id);
    _ = db.seg_stats.remove(id);
    db.compactions += 1;
}

/// Whether a segment other than `except` might hold a record older than
/// `seq`, which a tombstone at `seq` would still need to hide.
fn olderDataMayExist(db: *const Db, except: u64, seq: u64) bool {
    for (db.log.segments.items) |id| {
        if (id == except) continue;
        const st = db.seg_stats.get(id) orelse continue;
        if (st.min_seq < seq) return true;
    }
    return false;
}

// ------------------------------------------------------------ iteration

pub const Range = struct {
    /// Inclusive lower bound. Empty means the first key.
    start: []const u8 = "",
    /// Exclusive upper bound. Null means no upper bound.
    end: ?[]const u8 = null,
    reverse: bool = false,
};

pub const Pair = struct { key: []const u8, value: []const u8 };

/// Walks keys in order (or reverse order). Keys and values returned by
/// `next` are valid until the next call. Do not write to the `Db` while
/// an iterator is in use.
pub const Iterator = struct {
    db: *Db,
    cursor: Index.Cursor,
    range: Range,

    pub fn next(it: *Iterator) !?Pair {
        if (!it.cursor.valid()) return null;
        const key = it.cursor.key();
        if (it.range.reverse) {
            if (std.mem.order(u8, key, it.range.start) == .lt) return null;
        } else if (it.range.end) |end| {
            if (std.mem.order(u8, key, end) != .lt) return null;
        }
        const e = it.cursor.valuePtr().*;
        if (it.range.reverse) it.cursor.prev() else it.cursor.next();
        return .{ .key = key, .value = try it.db.readValue(e) };
    }

    /// Like `next` but skips reading the value.
    pub fn nextKey(it: *Iterator) ?[]const u8 {
        if (!it.cursor.valid()) return null;
        const key = it.cursor.key();
        if (it.range.reverse) {
            if (std.mem.order(u8, key, it.range.start) == .lt) return null;
        } else if (it.range.end) |end| {
            if (std.mem.order(u8, key, end) != .lt) return null;
        }
        if (it.range.reverse) it.cursor.prev() else it.cursor.next();
        return key;
    }
};

pub fn iterator(db: *Db, range: Range) Iterator {
    const cursor = if (range.reverse)
        (if (range.end) |end| db.index.seekBefore(end) else db.index.last())
    else
        db.index.seek(range.start);
    return .{ .db = db, .cursor = cursor, .range = range };
}

/// Iterates the keys that start with `prefix`. `buf` must outlive the
/// iterator and be at least `prefix.len` bytes.
pub fn prefixIterator(db: *Db, prefix: []const u8, reverse: bool, buf: []u8) Iterator {
    return db.iterator(.{ .start = prefix, .end = ordered.prefixEnd(prefix, buf), .reverse = reverse });
}

/// Returns up to `n` entries with the greatest keys under `prefix`, newest
/// key first. With keys like `agent/<id>/<timestamp>` this is "the latest
/// n memories". Everything returned is owned by the caller; free it with
/// `freePairs`.
pub fn latest(db: *Db, gpa: Allocator, prefix: []const u8, n: usize) ![]Pair {
    const end_buf = try gpa.alloc(u8, prefix.len);
    defer gpa.free(end_buf);
    var it = db.prefixIterator(prefix, true, end_buf);
    var out: std.ArrayList(Pair) = .empty;
    errdefer freePairs(gpa, out.items);
    errdefer out.deinit(gpa);
    while (out.items.len < n) {
        const p = (try it.next()) orelse break;
        const key = try gpa.dupe(u8, p.key);
        errdefer gpa.free(key);
        const value = try gpa.dupe(u8, p.value);
        errdefer gpa.free(value);
        try out.append(gpa, .{ .key = key, .value = value });
    }
    return out.toOwnedSlice(gpa);
}

pub fn freePairs(gpa: Allocator, pairs: []const Pair) void {
    for (pairs) |p| {
        gpa.free(p.key);
        gpa.free(p.value);
    }
    gpa.free(pairs);
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "put, get, delete and reopen" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        var db = try Db.open(testing.allocator, io, tmp.dir, "db", .{});
        defer db.close();
        try db.put("a", "1");
        try db.put("b", "2");
        try db.put("a", "one");
        try testing.expect(try db.delete("b"));
        try testing.expect(!try db.delete("b"));
        try db.put("c", "3");
        try testing.expectEqualStrings("one", (try db.getView("a")).?);
        try testing.expect((try db.getView("b")) == null);
        try db.sync();
    }
    var db = try Db.open(testing.allocator, io, tmp.dir, "db", .{});
    defer db.close();
    try testing.expectEqual(@as(usize, 2), db.count());
    const v = (try db.get(testing.allocator, "a")).?;
    defer testing.allocator.free(v);
    try testing.expectEqualStrings("one", v);
    try testing.expect(!db.contains("b"));
    try testing.expectEqualStrings("3", (try db.getView("c")).?);
    try testing.expectEqual(@as(u64, 5), db.lastSeq());
}

test "range, reverse and prefix iteration" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Db.open(testing.allocator, io, tmp.dir, "db", .{});
    defer db.close();

    for ([_][]const u8{ "a/1", "a/2", "a/3", "b/1", "b/2", "c" }) |k| try db.put(k, k);

    var buf: [8]u8 = undefined;
    var it = db.prefixIterator("a/", false, &buf);
    try testing.expectEqualStrings("a/1", (try it.next()).?.key);
    try testing.expectEqualStrings("a/2", (try it.next()).?.key);
    const third = (try it.next()).?;
    try testing.expectEqualStrings("a/3", third.value);
    try testing.expect((try it.next()) == null);

    it = db.prefixIterator("b/", true, &buf);
    try testing.expectEqualStrings("b/2", it.nextKey().?);
    try testing.expectEqualStrings("b/1", it.nextKey().?);
    try testing.expect(it.nextKey() == null);

    it = db.iterator(.{ .start = "a/2", .end = "b/2" });
    var n: usize = 0;
    while (it.nextKey()) |_| n += 1;
    try testing.expectEqual(@as(usize, 3), n);

    it = db.iterator(.{ .reverse = true });
    try testing.expectEqualStrings("c", it.nextKey().?);
}

test "latest returns newest keys under a prefix" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Db.open(testing.allocator, io, tmp.dir, "db", .{});
    defer db.close();

    var kb: [32]u8 = undefined;
    for (0..50) |i| try db.put(try std.fmt.bufPrint(&kb, "agent/7/{d:0>8}", .{i}), "m");
    try db.put("agent/8/00000001", "other agent");

    const got = try db.latest(testing.allocator, "agent/7/", 3);
    defer freePairs(testing.allocator, got);
    try testing.expectEqual(@as(usize, 3), got.len);
    try testing.expectEqualStrings("agent/7/00000049", got[0].key);
    try testing.expectEqualStrings("agent/7/00000047", got[2].key);
}

test "invalid input is rejected without side effects" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Db.open(testing.allocator, io, tmp.dir, "db", .{});
    defer db.close();
    try testing.expectError(error.EmptyKey, db.put("", "x"));
    try testing.expectEqual(@as(usize, 0), db.count());
    try testing.expectEqual(@as(u64, 0), db.lastSeq());
}

test "compaction reclaims overwritten and deleted space and survives reopen" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const opts: Options = .{ .sync_writes = false, .auto_compact = false, .log = .{ .segment_bytes = 4096 } };

    var kb: [16]u8 = undefined;
    {
        var db = try Db.open(testing.allocator, io, tmp.dir, "db", opts);
        defer db.close();
        // 100 keys, each overwritten 10 times, then delete half.
        for (0..10) |round| {
            for (0..100) |k| {
                var vb: [32]u8 = undefined;
                try db.put(try std.fmt.bufPrint(&kb, "key{d:0>3}", .{k}), try std.fmt.bufPrint(&vb, "value-{d}-{d}", .{ k, round }));
            }
        }
        for (0..50) |k| _ = try db.delete(try std.fmt.bufPrint(&kb, "key{d:0>3}", .{k * 2}));

        const before = db.spaceStats();
        const n = try db.compactWithRatio(0);
        try testing.expect(n > 0);
        const after = db.spaceStats();
        try testing.expect(after.total_bytes < before.total_bytes / 3);
        try testing.expectEqual(before.live_bytes, after.live_bytes);
        try testing.expectEqual(@as(usize, 50), db.count());
        try testing.expectEqualStrings("value-1-9", (try db.getView("key001")).?);
        try testing.expect((try db.getView("key000")) == null);
        try db.sync();
    }

    var db = try Db.open(testing.allocator, io, tmp.dir, "db", opts);
    defer db.close();
    try testing.expectEqual(@as(usize, 50), db.count());
    try testing.expect((try db.getView("key002")) == null);
    try testing.expectEqualStrings("value-99-9", (try db.getView("key099")).?);
    // Writes after reopen get sequence numbers above every copied record.
    try db.put("key000", "back");
    try testing.expectEqualStrings("back", (try db.getView("key000")).?);
}

test "auto compaction keeps disk use bounded under overwrites" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Db.open(testing.allocator, io, tmp.dir, "db", .{ .sync_writes = false, .log = .{ .segment_bytes = 8192 } });
    defer db.close();
    var kb: [16]u8 = undefined;
    for (0..20_000) |i| try db.put(try std.fmt.bufPrint(&kb, "k{d}", .{i % 50}), "0123456789012345678901234567890123456789");
    try testing.expect(db.compactions > 0);
    try testing.expect(db.spaceStats().total_bytes < 64 * 1024);
    try testing.expectEqual(@as(usize, 50), db.count());
}
