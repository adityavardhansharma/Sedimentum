//! The append-only log: a directory of segment files plus a `LOCK` file.
//!
//! Records are only ever appended to the newest ("active") segment. When it
//! reaches `Options.segment_bytes` it is synced, sealed, and a new segment is
//! started. Opening a log replays every record in order to a visitor, which
//! is how the in-memory index will be rebuilt.
//!
//! Recovery rules:
//! - A sealed segment was synced before the next one was created, so any
//!   damage in it is reported as `error.Corrupt`.
//! - The active segment may end in a torn write. That tail is truncated.
//! - Damage in the active segment that is followed by valid records means
//!   data in the middle was lost; that is `error.Corrupt`, never truncated.

const Log = @This();

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const record = @import("record.zig");
const segment = @import("segment.zig");

pub const Options = struct {
    /// A segment is sealed once appending would grow it past this size.
    segment_bytes: u64 = 64 * 1024 * 1024,
};

/// Where a record lives on disk. The index stores this per key.
pub const Location = struct {
    segment: u64,
    offset: u64,
    len: u32,
};

pub const OpenError = error{ Locked, Corrupt, OutOfOrder };
pub const WriteError = error{ Poisoned, SequenceNotIncreasing };

gpa: Allocator,
io: Io,
options: Options,
dir: Io.Dir,
lock_file: Io.File,
active: Io.File,
active_id: u64,
active_end: u64,
/// Read handles for sealed segments, opened on first use.
readers: std.AutoHashMapUnmanaged(u64, Io.File) = .empty,
/// Every live segment id, oldest first. The last one is `active_id`.
segments: std.ArrayList(u64) = .empty,
scratch: std.ArrayList(u8) = .empty,
last_seq: u64 = 0,
/// Set after a failed write or sync. The file may hold a partial record,
/// so further appends would bury it in the middle of the log.
poisoned: bool = false,

/// A visitor that ignores every record.
pub const NoVisitor = struct {
    pub fn onRecord(_: NoVisitor, _: Location, _: record.Record) !void {}
};

/// Opens or creates the log at `sub_path` and replays every record to
/// `visitor.onRecord(location, record)` in write order.
pub fn open(
    gpa: Allocator,
    io: Io,
    parent: Io.Dir,
    sub_path: []const u8,
    options: Options,
    visitor: anytype,
) !Log {
    var dir = try parent.createDirPathOpen(io, sub_path, .{ .open_options = .{ .iterate = true } });
    errdefer dir.close(io);

    const lock_file = dir.createFile(io, "LOCK", .{
        .truncate = false,
        .lock = .exclusive,
        .lock_nonblocking = true,
    }) catch |err| switch (err) {
        error.WouldBlock => return error.Locked,
        else => |e| return e,
    };
    errdefer lock_file.close(io);

    var log: Log = .{
        .gpa = gpa,
        .io = io,
        .options = options,
        .dir = dir,
        .lock_file = lock_file,
        .active = undefined,
        .active_id = 0,
        .active_end = 0,
    };
    errdefer {
        log.segments.deinit(gpa);
        log.scratch.deinit(gpa);
    }

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (segment.parseFileName(entry.name)) |id| try log.segments.append(gpa, id);
    }
    std.mem.sortUnstable(u64, log.segments.items, {}, std.sort.asc(u64));

    if (log.segments.items.len == 0) {
        log.active_id = 1;
        log.active = try log.createSegment(1);
        try log.segments.append(gpa, 1);
        return log;
    }

    const last_index = log.segments.items.len - 1;
    for (log.segments.items, 0..) |id, i| {
        const is_active = i == last_index;
        var name_buf: [segment.name_len]u8 = undefined;
        const file = try dir.openFile(io, segment.fileName(&name_buf, id), .{
            .mode = if (is_active) .read_write else .read_only,
        });
        var keep_open = false;
        defer if (!keep_open) file.close(io);

        const end = try log.replaySegment(file, id, is_active, visitor);
        if (is_active) {
            log.active = file;
            log.active_id = id;
            log.active_end = end;
            keep_open = true;
        }
    }
    return log;
}

fn replaySegment(log: *Log, file: Io.File, id: u64, is_active: bool, visitor: anytype) !u64 {
    var scanner = try segment.Scanner.init(log.gpa, log.io, file);
    defer scanner.deinit();
    while (try scanner.next()) |item| {
        if (item.record.seq <= log.last_seq) return error.OutOfOrder;
        log.last_seq = item.record.seq;
        try visitor.onRecord(Location{
            .segment = id,
            .offset = item.offset,
            .len = @intCast(record.encodedLen(item.record)),
        }, item.record);
    }
    switch (scanner.stop) {
        .end => {},
        .corrupt => return error.Corrupt,
        .torn => {
            if (!is_active) return error.Corrupt;
            try file.setLength(log.io, scanner.pos);
            try file.sync(log.io);
        },
    }
    return scanner.pos;
}

pub fn close(log: *Log) void {
    const io = log.io;
    if (!log.poisoned) log.active.sync(io) catch {};
    log.active.close(io);
    var it = log.readers.valueIterator();
    while (it.next()) |f| f.close(io);
    log.readers.deinit(log.gpa);
    log.segments.deinit(log.gpa);
    log.scratch.deinit(log.gpa);
    log.lock_file.close(io);
    log.dir.close(io);
    log.* = undefined;
}

/// Appends one record. Not durable until `sync` succeeds.
pub fn append(log: *Log, rec: record.Record) !Location {
    if (log.poisoned) return error.Poisoned;
    try record.validate(rec);
    if (rec.seq <= log.last_seq) return error.SequenceNotIncreasing;

    const len = record.encodedLen(rec);
    if (log.active_end > 0 and log.active_end + len > log.options.segment_bytes) {
        try log.rollover();
    }

    try log.scratch.resize(log.gpa, len);
    record.encode(log.scratch.items, rec);
    log.active.writePositionalAll(log.io, log.scratch.items, log.active_end) catch |err| {
        log.poisoned = true;
        return err;
    };

    const loc: Location = .{ .segment = log.active_id, .offset = log.active_end, .len = @intCast(len) };
    log.active_end += len;
    log.last_seq = rec.seq;
    return loc;
}

/// Makes every appended record durable.
pub fn sync(log: *Log) !void {
    if (log.poisoned) return error.Poisoned;
    log.active.sync(log.io) catch |err| {
        log.poisoned = true;
        return err;
    };
}

/// Reads and verifies the record at `loc`. The result borrows `buf`,
/// which must be at least `loc.len` bytes.
pub fn read(log: *Log, loc: Location, buf: []u8) !record.Record {
    const full = buf[0..loc.len];
    const file = try log.fileFor(loc.segment);
    const got = try file.readPositionalAll(log.io, full, loc.offset);
    if (got != full.len) return error.Corrupt;
    const h = record.decodeHeader(full[0..record.header_len]);
    if (!h.isPlausible() or h.totalLen() != full.len or !record.checksumMatches(h, full)) {
        return error.Corrupt;
    }
    return record.view(h, full);
}

fn fileFor(log: *Log, id: u64) !Io.File {
    if (id == log.active_id) return log.active;
    const gop = try log.readers.getOrPut(log.gpa, id);
    if (!gop.found_existing) {
        var name_buf: [segment.name_len]u8 = undefined;
        gop.value_ptr.* = log.dir.openFile(log.io, segment.fileName(&name_buf, id), .{}) catch |err| {
            log.readers.removeByPtr(gop.key_ptr);
            return err;
        };
    }
    return gop.value_ptr.*;
}

fn rollover(log: *Log) !void {
    log.sync() catch |err| return err;
    const next_id = log.active_id + 1;
    const next = log.createSegment(next_id) catch |err| {
        log.poisoned = true;
        return err;
    };
    try log.segments.append(log.gpa, next_id);
    // Keep the sealed file open for reads instead of reopening it.
    log.readers.put(log.gpa, log.active_id, log.active) catch |err| {
        log.active.close(log.io);
        log.active = next;
        log.active_id = next_id;
        log.active_end = 0;
        return err;
    };
    log.active = next;
    log.active_id = next_id;
    log.active_end = 0;
}

/// Creates an empty segment and makes its directory entry durable.
fn createSegment(log: *Log, id: u64) !Io.File {
    var name_buf: [segment.name_len]u8 = undefined;
    const file = try log.dir.createFile(log.io, segment.fileName(&name_buf, id), .{
        .read = true,
        .exclusive = true,
    });
    errdefer file.close(log.io);
    try syncDir(log.io, log.dir);
    return file;
}

fn syncDir(io: Io, dir: Io.Dir) !void {
    const handle = try dir.openFile(io, ".", .{});
    defer handle.close(io);
    try handle.sync(io);
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

const Collector = struct {
    keys: std.ArrayList([]u8) = .empty,
    locs: std.ArrayList(Location) = .empty,

    fn deinit(c: *Collector) void {
        for (c.keys.items) |k| testing.allocator.free(k);
        c.keys.deinit(testing.allocator);
        c.locs.deinit(testing.allocator);
    }

    pub fn onRecord(c: *Collector, loc: Location, rec: record.Record) !void {
        try c.keys.append(testing.allocator, try testing.allocator.dupe(u8, rec.key));
        try c.locs.append(testing.allocator, loc);
    }
};

test "append, reopen, replay and read back" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var locs: [3]Location = undefined;
    {
        var log = try Log.open(testing.allocator, io, tmp.dir, "db", .{}, NoVisitor{});
        defer log.close();
        locs[0] = try log.append(.{ .seq = 1, .kind = .put, .key = "a", .value = "1" });
        locs[1] = try log.append(.{ .seq = 2, .kind = .put, .key = "b", .value = "2" });
        locs[2] = try log.append(.{ .seq = 3, .kind = .delete, .key = "a" });
        try log.sync();
    }

    var c: Collector = .{};
    defer c.deinit();
    var log = try Log.open(testing.allocator, io, tmp.dir, "db", .{}, &c);
    defer log.close();

    try testing.expectEqual(@as(usize, 3), c.keys.items.len);
    try testing.expectEqualStrings("a", c.keys.items[0]);
    try testing.expectEqualStrings("b", c.keys.items[1]);
    try testing.expectEqualSlices(Location, &locs, c.locs.items);
    try testing.expectEqual(@as(u64, 3), log.last_seq);

    var buf: [64]u8 = undefined;
    const rec = try log.read(locs[1], &buf);
    try testing.expectEqualStrings("b", rec.key);
    try testing.expectEqualStrings("2", rec.value);

    try testing.expectError(error.SequenceNotIncreasing, log.append(.{ .seq = 3, .kind = .put, .key = "c" }));
}

test "a second open of the same directory is rejected" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var log = try Log.open(testing.allocator, io, tmp.dir, "db", .{}, NoVisitor{});
    defer log.close();
    try testing.expectError(error.Locked, Log.open(testing.allocator, io, tmp.dir, "db", .{}, NoVisitor{}));
}

test "segments roll over and stay readable" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var locs: [10]Location = undefined;
    {
        var log = try Log.open(testing.allocator, io, tmp.dir, "db", .{ .segment_bytes = 64 }, NoVisitor{});
        defer log.close();
        for (&locs, 0..) |*loc, i| {
            var key: [8]u8 = undefined;
            loc.* = try log.append(.{ .seq = i + 1, .kind = .put, .key = try std.fmt.bufPrint(&key, "k{d}", .{i}), .value = "value" });
        }
        try testing.expect(log.segments.items.len > 1);
        var buf: [64]u8 = undefined;
        const first = try log.read(locs[0], &buf);
        try testing.expectEqualStrings("k0", first.key);
        try log.sync();
    }

    var c: Collector = .{};
    defer c.deinit();
    var log = try Log.open(testing.allocator, io, tmp.dir, "db", .{ .segment_bytes = 64 }, &c);
    defer log.close();
    try testing.expectEqual(@as(usize, 10), c.keys.items.len);
    try testing.expectEqualSlices(Location, &locs, c.locs.items);
    try testing.expectEqualStrings("k9", c.keys.items[9]);
}

test "a torn tail in the active segment is truncated on open" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var end: u64 = 0;
    {
        var log = try Log.open(testing.allocator, io, tmp.dir, "db", .{}, NoVisitor{});
        defer log.close();
        _ = try log.append(.{ .seq = 1, .kind = .put, .key = "a", .value = "1" });
        end = log.active_end;
        _ = try log.append(.{ .seq = 2, .kind = .put, .key = "b", .value = "a longer value" });
        try log.sync();
        try log.active.setLength(io, log.active_end - 3);
    }

    var c: Collector = .{};
    defer c.deinit();
    var log = try Log.open(testing.allocator, io, tmp.dir, "db", .{}, &c);
    defer log.close();
    try testing.expectEqual(@as(usize, 1), c.keys.items.len);
    try testing.expectEqual(end, log.active_end);
    try testing.expectEqual(end, try log.active.length(io));

    // New writes continue right after the last good record.
    _ = try log.append(.{ .seq = 2, .kind = .put, .key = "c", .value = "3" });
}

test "damage in the middle of the active segment refuses to open" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        var log = try Log.open(testing.allocator, io, tmp.dir, "db", .{}, NoVisitor{});
        defer log.close();
        _ = try log.append(.{ .seq = 1, .kind = .put, .key = "a", .value = "1" });
        _ = try log.append(.{ .seq = 2, .kind = .put, .key = "b", .value = "2" });
        try log.active.writePositionalAll(io, "Z", record.header_len);
        try log.sync();
    }
    try testing.expectError(error.Corrupt, Log.open(testing.allocator, io, tmp.dir, "db", .{}, NoVisitor{}));
}

test "damage in a sealed segment refuses to open" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        var log = try Log.open(testing.allocator, io, tmp.dir, "db", .{ .segment_bytes = 40 }, NoVisitor{});
        defer log.close();
        _ = try log.append(.{ .seq = 1, .kind = .put, .key = "a", .value = "1" });
        _ = try log.append(.{ .seq = 2, .kind = .put, .key = "b", .value = "2" });
        try testing.expectEqual(@as(usize, 2), log.segments.items.len);
        try log.sync();
    }
    // Cut the sealed first segment short.
    {
        var db = try tmp.dir.openDir(io, "db", .{});
        defer db.close(io);
        const f = try db.openFile(io, "0000000001.log", .{ .mode = .read_write });
        defer f.close(io);
        try f.setLength(io, 5);
    }
    try testing.expectError(error.Corrupt, Log.open(testing.allocator, io, tmp.dir, "db", .{ .segment_bytes = 40 }, NoVisitor{}));
}

test "read detects a damaged record" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var log = try Log.open(testing.allocator, io, tmp.dir, "db", .{}, NoVisitor{});
    defer log.close();
    const loc = try log.append(.{ .seq = 1, .kind = .put, .key = "a", .value = "hello" });
    try log.active.writePositionalAll(io, "J", loc.offset + loc.len - 1);
    var buf: [64]u8 = undefined;
    try testing.expectError(error.Corrupt, log.read(loc, &buf));
}
