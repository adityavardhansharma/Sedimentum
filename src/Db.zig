//! The database: an append-only log on disk plus an ordered index in memory.
//!
//! The index maps every live key to the location of its newest record, so a
//! point read is one tree lookup plus one read of the record. Deleted keys
//! are removed from the index; their tombstones stay in the log until
//! compaction.
//!
//! A `Db` is used from one thread at a time.

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

gpa: Allocator,
options: Options,
log: Log,
index: Index,
/// Scratch space for reading records.
read_buf: std.ArrayList(u8) = .empty,

pub fn open(gpa: Allocator, io: Io, parent: Io.Dir, sub_path: []const u8, options: Options) !Db {
    var idx = try Index.init(gpa);
    errdefer idx.deinit();
    var loader: Loader = .{ .index = &idx };
    var log = try Log.open(gpa, io, parent, sub_path, options.log, &loader);
    errdefer log.close();
    return .{ .gpa = gpa, .options = options, .log = log, .index = idx };
}

pub fn close(db: *Db) void {
    db.read_buf.deinit(db.gpa);
    db.index.deinit();
    db.log.close();
    db.* = undefined;
}

const Loader = struct {
    index: *Index,

    pub fn onRecord(l: *Loader, loc: Log.Location, rec: record.Record) !void {
        switch (rec.kind) {
            .put => try l.index.put(rec.key, Entry.from(loc, rec.seq)),
            .delete => _ = l.index.remove(rec.key),
            _ => return error.Corrupt,
        }
    }
};

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
    // Reserve the index slot first so a failed allocation can't leave a
    // record in the log that the index never saw.
    const slot = try db.index.getOrPut(key);
    const seq = db.log.last_seq + 1;
    const loc = db.log.append(.{ .seq = seq, .kind = .put, .key = key, .value = value }) catch |err| {
        if (!slot.found_existing) _ = db.index.remove(key);
        return err;
    };
    slot.value_ptr.* = Entry.from(loc, seq);
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
    _ = try db.log.append(.{ .seq = db.log.last_seq + 1, .kind = .delete, .key = key });
    _ = db.index.remove(key);
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
