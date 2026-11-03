//! The append-only log: a directory of segment files plus a `LOCK` file.
//!
//! Records are only ever appended to the newest ("active") segment. When it
//! reaches `Options.segment_bytes` it is synced, sealed, and a new segment is
//! started. Opening a log replays every record in order to a visitor, which
//! is how the in-memory index is rebuilt.
//!
//! Appends go into a user-space buffer first and reach the file when the
//! buffer fills, on `flush`, or on `sync`. Reads see buffered records too.
//! Segments are memory-mapped for reading when `Options.mmap` is on, so a
//! read of a flushed record needs no system call.
//!
//! Recovery rules:
//! - A sealed segment was synced before the next one was created, so any
//!   damage in it is reported as `error.Corrupt`.
//! - The active segment may end in a torn write. That tail is truncated.
//! - Damage in the active segment that is followed by valid records means
//!   data in the middle was lost; that is `error.Corrupt`, never truncated.

const Log = @This();

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const record = @import("record.zig");
const segment = @import("segment.zig");
const cold = @import("cold.zig");

const page_align = std.heap.page_size_min;
const Map = []align(page_align) const u8;

pub const Options = struct {
    /// A segment is sealed once appending would grow it past this size.
    segment_bytes: u64 = 64 * 1024 * 1024,
    /// Appends are written to the file once this many bytes are buffered.
    write_buffer_bytes: usize = 256 * 1024,
    /// Memory-map segments for reads. Falls back to `pread` when off or
    /// when mapping fails.
    mmap: bool = true,
};

/// Where a record lives on disk. The index stores this per key.
pub const Location = struct {
    segment: u64,
    offset: u64,
    len: u32,
};

pub const OpenError = error{ Locked, Corrupt };
pub const WriteError = error{ Poisoned, SequenceNotIncreasing };

const Seg = struct {
    /// Open handle. A sealed segment that is fully mapped drops its handle,
    /// so the number of open files does not grow with the number of
    /// segments. Without a mapping (mmap off or failed) the handle stays.
    file: ?Io.File,
    map: ?Map = null,
    /// Final size once sealed. Unused for the active segment.
    size: u64 = 0,
};

gpa: Allocator,
io: Io,
options: Options,
dir: Io.Dir,
lock_file: Io.File,
active: Io.File,
active_id: u64,
/// Logical end of the active segment, including buffered bytes.
active_end: u64,
/// How much of the active segment has been written to the file.
flushed_end: u64,
/// Appended records not yet written to the file.
wbuf: std.ArrayList(u8) = .empty,
/// Optional handle and mapping for every live segment, active included.
segs: std.AutoHashMapUnmanaged(u64, Seg) = .empty,
/// Every live segment id, oldest first. The last one is `active_id`.
segments: std.ArrayList(u64) = .empty,
last_seq: u64 = 0,
/// Set after a failed write or sync. The file may hold a partial record,
/// so further appends would bury it in the middle of the log.
poisoned: bool = false,
/// A segment whose handle an unlocked sync is still using. Rollover keeps
/// that handle open until `unpinSync` runs.
sync_pin: ?u64 = null,

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
    // The directory itself may be new. Sync its parent so the entry
    // survives a power loss along with the segments inside it.
    try syncParentDir(io, dir);

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
        .flushed_end = 0,
    };
    errdefer log.releaseSegs();

    // A visitor with `prepare(dir) !u64` can name the last segment it
    // already knows about from elsewhere; those sealed segments are mapped
    // but not replayed.
    const V = @TypeOf(visitor);
    const T = switch (@typeInfo(V)) {
        .pointer => |ptr| ptr.child,
        else => V,
    };
    const skip_through: u64 = if (@hasDecl(T, "prepare")) try visitor.prepare(dir) else 0;

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (segment.parseFileName(entry.name)) |id| try log.segments.append(gpa, id);
    }
    std.mem.sortUnstable(u64, log.segments.items, {}, std.sort.asc(u64));

    if (log.segments.items.len == 0) {
        try log.segments.ensureUnusedCapacity(gpa, 1);
        const file = try log.createSegment(1);
        log.addSeg(1, file, true) catch |err| {
            file.close(io);
            log.deleteSegmentFile(1);
            return err;
        };
        log.segments.appendAssumeCapacity(1);
        log.active = file;
        log.active_id = 1;
        return log;
    }

    const last_index = log.segments.items.len - 1;
    for (log.segments.items, 0..) |id, i| {
        const is_active = i == last_index;
        var name_buf: [segment.name_len]u8 = undefined;
        const file = try dir.openFile(io, segment.fileName(&name_buf, id), .{
            .mode = if (is_active) .read_write else .read_only,
        });
        const skip = !is_active and id <= skip_through;
        const end = (if (skip) file.length(io) else log.replaySegment(file, id, is_active, visitor)) catch |err| {
            file.close(io);
            return err;
        };
        log.addSeg(id, file, is_active) catch |err| {
            file.close(io);
            return err;
        };
        const seg = log.segs.getPtr(id).?;
        seg.size = end;
        if (!is_active) dropHandleIfMapped(io, seg);
        if (is_active) {
            log.active = file;
            log.active_id = id;
            log.active_end = end;
            log.flushed_end = end;
        }
    }
    return log;
}

fn addSeg(log: *Log, id: u64, file: Io.File, is_active: bool) !void {
    try log.segs.ensureUnusedCapacity(log.gpa, 1);
    var seg: Seg = .{ .file = file };
    if (log.options.mmap) {
        const len = if (is_active)
            @max(log.options.segment_bytes, try file.length(log.io))
        else
            try file.length(log.io);
        if (len > 0) seg.map = mapFile(file, len);
    }
    log.segs.putAssumeCapacity(id, seg);
}

/// Closes a sealed segment's handle when its mapping covers the whole file.
fn dropHandleIfMapped(io: Io, seg: *Seg) void {
    const map = seg.map orelse return;
    if (map.len < seg.size) return;
    if (seg.file) |f| f.close(io);
    seg.file = null;
}

/// Opens a sealed segment for reading when it has no open handle.
fn openSegment(log: *const Log, id: u64) !Io.File {
    var name_buf: [segment.name_len]u8 = undefined;
    return log.dir.openFile(log.io, segment.fileName(&name_buf, id), .{});
}

fn deleteSegmentFile(log: *Log, id: u64) void {
    var name_buf: [segment.name_len]u8 = undefined;
    log.dir.deleteFile(log.io, segment.fileName(&name_buf, id)) catch {};
}

fn mapFile(file: Io.File, len: u64) ?Map {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return null;
    return std.posix.mmap(null, @intCast(len), .{ .READ = true }, .{ .TYPE = .SHARED }, file.handle, 0) catch null;
}

fn releaseSegs(log: *Log) void {
    const io = log.io;
    var it = log.segs.valueIterator();
    while (it.next()) |s| {
        if (s.map) |m| std.posix.munmap(m);
        if (s.file) |f| f.close(io);
    }
    log.segs.deinit(log.gpa);
    log.segments.deinit(log.gpa);
    log.wbuf.deinit(log.gpa);
}

fn replaySegment(log: *Log, file: Io.File, id: u64, is_active: bool, visitor: anytype) !u64 {
    var scanner = try segment.Scanner.init(log.gpa, log.io, file);
    defer scanner.deinit();
    while (try scanner.next()) |item| {
        // Compaction copies live records forward with their original
        // sequence numbers, so file order is not sequence order.
        log.last_seq = @max(log.last_seq, item.record.seq);
        if (item.record.kind == .batch) {
            const body_offset = item.offset + record.header_len + 4;
            var ops = record.BatchIterator.init(item.record);
            while (try ops.next()) |op| {
                log.last_seq = @max(log.last_seq, op.record.seq);
                try visitor.onRecord(Location{
                    .segment = id,
                    .offset = body_offset + op.offset,
                    .len = @intCast(op.bytes.len),
                }, op.record);
            }
            continue;
        }
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

/// Writes buffered records, syncs, and releases everything.
pub fn close(log: *Log) void {
    if (!log.poisoned) log.sync() catch {};
    log.releaseSegs();
    log.lock_file.close(log.io);
    log.dir.close(log.io);
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

    const start = log.wbuf.items.len;
    try log.wbuf.resize(log.gpa, start + len);
    record.encode(log.wbuf.items[start..], rec);

    const loc: Location = .{ .segment = log.active_id, .offset = log.active_end, .len = @intCast(len) };
    log.active_end += len;
    log.last_seq = rec.seq;

    if (log.wbuf.items.len >= log.options.write_buffer_bytes) try log.flush();
    return loc;
}

/// Appends several records as one batch that recovery applies entirely or
/// not at all. Sequence numbers must increase. Writes each record's
/// location to `locs`.
pub fn appendBatch(log: *Log, recs: []const record.Record, locs: []Location) !void {
    std.debug.assert(recs.len == locs.len and recs.len > 0);
    if (log.poisoned) return error.Poisoned;
    var body_len: usize = 0;
    var prev_seq = log.last_seq;
    for (recs) |rec| {
        try record.validate(rec);
        if (rec.seq <= prev_seq) return error.SequenceNotIncreasing;
        prev_seq = rec.seq;
        body_len += record.encodedLen(rec);
    }
    if (body_len > record.max_value_len) return error.BatchTooLarge;
    const total = record.header_len + 4 + body_len;
    if (log.active_end > 0 and log.active_end + total > log.options.segment_bytes) {
        try log.rollover();
    }

    const start = log.wbuf.items.len;
    try log.wbuf.resize(log.gpa, start + total);
    const out = log.wbuf.items[start..];
    std.mem.writeInt(u32, out[record.header_len..][0..4], @intCast(recs.len), .little);
    var pos: usize = record.header_len + 4;
    for (recs, locs) |rec, *loc| {
        const len = record.encodedLen(rec);
        var inner = rec;
        inner.kind = record.inBatch(rec.kind);
        record.encode(out[pos..][0..len], inner);
        loc.* = .{ .segment = log.active_id, .offset = log.active_end + pos, .len = @intCast(len) };
        pos += len;
    }
    record.finish(out, prev_seq, .batch, 4, @intCast(body_len));

    log.active_end += total;
    log.last_seq = prev_seq;
    if (log.wbuf.items.len >= log.options.write_buffer_bytes) try log.flush();
}

/// Appends a copy of an existing record with its original sequence number.
/// Used by compaction to move live records out of old segments.
pub fn appendCopy(log: *Log, rec: record.Record) !Location {
    if (log.poisoned) return error.Poisoned;
    const len = record.encodedLen(rec);
    if (log.active_end > 0 and log.active_end + len > log.options.segment_bytes) {
        try log.rollover();
    }
    const start = log.wbuf.items.len;
    try log.wbuf.resize(log.gpa, start + len);
    record.encode(log.wbuf.items[start..], rec);
    const loc: Location = .{ .segment = log.active_id, .offset = log.active_end, .len = @intCast(len) };
    log.active_end += len;
    if (log.wbuf.items.len >= log.options.write_buffer_bytes) try log.flush();
    return loc;
}

/// Size in bytes of a segment, including buffered bytes for the active one.
pub fn segmentSize(log: *const Log, id: u64) u64 {
    if (id == log.active_id) return log.active_end;
    return if (log.segs.get(id)) |seg| seg.size else 0;
}

/// Starts a checksum-verifying scan of a sealed segment. The scanner owns
/// its own file handle; `deinit` closes it.
pub fn scanSegment(log: *const Log, id: u64) !segment.Scanner {
    std.debug.assert(id != log.active_id);
    if (!log.segs.contains(id)) return error.Corrupt;
    const file = try log.openSegment(id);
    errdefer file.close(log.io);
    var scanner = try segment.Scanner.init(log.gpa, log.io, file);
    scanner.owns_file = true;
    return scanner;
}

/// Returns the active handle for a sync that runs without the caller's lock,
/// and keeps rollover from closing it until `unpinSync`.
pub fn pinSyncHandle(log: *Log) Io.File {
    std.debug.assert(log.sync_pin == null);
    log.sync_pin = log.active_id;
    return log.active;
}

/// Ends a pin from `pinSyncHandle`. If the pinned segment was sealed in the
/// meantime, its handle is dropped now.
pub fn unpinSync(log: *Log) void {
    const id = log.sync_pin orelse return;
    log.sync_pin = null;
    if (id == log.active_id) return;
    if (log.segs.getPtr(id)) |seg| dropHandleIfMapped(log.io, seg);
}

/// One problem `check` found in a segment file.
pub const Problem = struct {
    segment: u64,
    kind: Kind,
    /// Byte offset of the first bad record.
    offset: u64,
    file_len: u64,

    pub const Kind = enum {
        /// A partial record at the end of the newest segment. Opening cuts it off.
        torn_tail,
        /// A partial record at the end of a sealed segment. Opening refuses it.
        torn_sealed,
        /// A bad record followed by valid ones. Opening refuses it.
        corrupt,
        /// A batch whose checksum matches but whose contents are invalid.
        bad_batch,
        /// The cold index file is damaged. `segment` and `offset` are 0.
        bad_cold_index,
    };
};

pub const CheckReport = struct {
    records: u64 = 0,
    segments: usize = 0,
    problems: std.ArrayList(Problem) = .empty,

    pub fn deinit(r: *CheckReport, gpa: Allocator) void {
        r.problems.deinit(gpa);
    }
};

/// Verifies every segment in `sub_path` read-only, without repairing
/// anything. Holds the directory lock while it runs, so it fails with
/// `error.Locked` instead of racing a writer or compaction.
pub fn check(gpa: Allocator, io: Io, parent: Io.Dir, sub_path: []const u8) !CheckReport {
    var dir = try parent.openDir(io, sub_path, .{ .iterate = true });
    defer dir.close(io);
    // Open the lock read-only so a read-only backup can still be checked.
    // With no LOCK file, no writer has the directory open.
    const lock_file: ?Io.File = dir.openFile(io, "LOCK", .{
        .lock = .exclusive,
        .lock_nonblocking = true,
    }) catch |err| switch (err) {
        error.WouldBlock => return error.Locked,
        error.FileNotFound => null,
        else => |e| return e,
    };
    defer if (lock_file) |f| f.close(io);

    var ids: std.ArrayList(u64) = .empty;
    defer ids.deinit(gpa);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (segment.parseFileName(entry.name)) |id| try ids.append(gpa, id);
    }
    std.mem.sortUnstable(u64, ids.items, {}, std.sort.asc(u64));

    var report: CheckReport = .{ .segments = ids.items.len };
    errdefer report.deinit(gpa);
    for (ids.items, 0..) |id, i| {
        const newest = i + 1 == ids.items.len;
        var name_buf: [segment.name_len]u8 = undefined;
        const file = try dir.openFile(io, segment.fileName(&name_buf, id), .{});
        defer file.close(io);
        var scanner = try segment.Scanner.init(gpa, io, file);
        defer scanner.deinit();
        var bad_batch: ?u64 = null;
        while (try scanner.next()) |item| {
            report.records += 1;
            if (item.record.kind != .batch or bad_batch != null) continue;
            var ops = record.BatchIterator.init(item.record);
            while (true) {
                const op = ops.next() catch {
                    bad_batch = item.offset;
                    break;
                };
                if (op == null) break;
            }
        }
        if (bad_batch) |off| try report.problems.append(gpa, .{
            .segment = id,
            .kind = .bad_batch,
            .offset = off,
            .file_len = scanner.file_len,
        });
        const kind: ?Problem.Kind = switch (scanner.stop) {
            .end => null,
            .torn => if (newest) .torn_tail else .torn_sealed,
            .corrupt => .corrupt,
        };
        if (kind) |k| try report.problems.append(gpa, .{
            .segment = id,
            .kind = k,
            .offset = scanner.pos,
            .file_len = scanner.file_len,
        });
    }
    var damaged = false;
    if (cold.Reader.open(gpa, io, dir)) |maybe| {
        if (maybe) |r| {
            var reader = r;
            defer reader.close();
            reader.verify() catch {
                damaged = true;
            };
        }
    } else |_| damaged = true;
    if (damaged) try report.problems.append(gpa, .{ .segment = 0, .kind = .bad_cold_index, .offset = 0, .file_len = 0 });
    return report;
}

/// Deletes a sealed segment. The caller must have made every record it
/// still needs durable elsewhere first.
pub fn removeSegment(log: *Log, id: u64) !void {
    std.debug.assert(id != log.active_id);
    if (!log.segs.contains(id)) return;
    // Delete the file before forgetting the segment. If deleting fails the
    // segment stays tracked, so compaction keeps treating its records as
    // possibly live and never drops a tombstone that still shadows them.
    var name_buf: [segment.name_len]u8 = undefined;
    try log.dir.deleteFile(log.io, segment.fileName(&name_buf, id));
    const kv = log.segs.fetchRemove(id).?;
    if (kv.value.map) |m| std.posix.munmap(m);
    if (kv.value.file) |f| f.close(log.io);
    for (log.segments.items, 0..) |sid, i| if (sid == id) {
        _ = log.segments.orderedRemove(i);
        break;
    };
    try syncDir(log.io, log.dir);
}

/// Writes buffered records to the file without syncing.
pub fn flush(log: *Log) !void {
    if (log.poisoned) return error.Poisoned;
    if (log.wbuf.items.len == 0) return;
    log.active.writePositionalAll(log.io, log.wbuf.items, log.flushed_end) catch |err| {
        log.poisoned = true;
        return err;
    };
    log.flushed_end = log.active_end;
    log.wbuf.clearRetainingCapacity();
}

/// Makes every appended record durable.
pub fn sync(log: *Log) !void {
    try log.flush();
    log.active.sync(log.io) catch |err| {
        log.poisoned = true;
        return err;
    };
}

/// Returns the record at `loc` without copying when it is buffered or
/// mapped, or null when it must be read with `read`. The result stays
/// valid until the next append or until the segment is removed.
pub fn view(log: *const Log, loc: Location) !?record.Record {
    const full = (try log.rawView(loc)) orelse return null;
    return try verify(full);
}

fn rawView(log: *const Log, loc: Location) !?[]const u8 {
    if (loc.segment == log.active_id and loc.offset >= log.flushed_end) {
        const start: usize = @intCast(loc.offset - log.flushed_end);
        return log.wbuf.items[start..][0..loc.len];
    }
    const seg = log.segs.get(loc.segment) orelse return error.Corrupt;
    const map = seg.map orelse return null;
    if (loc.offset + loc.len > map.len) return null;
    return map[@intCast(loc.offset)..][0..loc.len];
}

/// Reads and verifies the record at `loc`. The result borrows `buf`,
/// which must be at least `loc.len` bytes.
pub fn read(log: *const Log, loc: Location, buf: []u8) !record.Record {
    const full = buf[0..loc.len];
    if (try log.rawView(loc)) |raw| {
        @memcpy(full, raw);
    } else {
        const seg = log.segs.get(loc.segment) orelse return error.Corrupt;
        const got = if (seg.file) |f|
            try f.readPositionalAll(log.io, full, loc.offset)
        else blk: {
            const f = try log.openSegment(loc.segment);
            defer f.close(log.io);
            break :blk try f.readPositionalAll(log.io, full, loc.offset);
        };
        if (got != full.len) return error.Corrupt;
    }
    return try verify(full);
}

fn verify(full: []const u8) !record.Record {
    if (full.len < record.header_len) return error.Corrupt;
    const h = record.decodeHeader(full[0..record.header_len]);
    const plausible = h.isPlausible() or h.isPlausibleInBatch();
    if (!plausible or h.totalLen() != full.len or !record.checksumMatches(h, full)) {
        return error.Corrupt;
    }
    return record.view(h, full);
}

/// Seals the active segment, if it holds anything, and starts a new one.
/// Lets a caller that no longer needs the records delete every old segment.
pub fn rotate(log: *Log) !void {
    if (log.poisoned) return error.Poisoned;
    if (log.active_end == 0) return;
    try log.rollover();
}

fn rollover(log: *Log) !void {
    try log.sync();
    // Reserve list space first so nothing can fail after the file exists.
    try log.segments.ensureUnusedCapacity(log.gpa, 1);
    const next_id = log.active_id + 1;
    const next = log.createSegment(next_id) catch |err| {
        log.poisoned = true;
        return err;
    };
    log.addSeg(next_id, next, true) catch |err| {
        next.close(log.io);
        log.deleteSegmentFile(next_id);
        return err;
    };
    log.segments.appendAssumeCapacity(next_id);
    // The sealed segment keeps its mapping in `segs` for reads.
    const sealed = log.segs.getPtr(log.active_id).?;
    sealed.size = log.active_end;
    if (log.sync_pin != log.active_id) dropHandleIfMapped(log.io, sealed);
    log.active = next;
    log.active_id = next_id;
    log.active_end = 0;
    log.flushed_end = 0;
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

fn syncParentDir(io: Io, dir: Io.Dir) !void {
    if (builtin.os.tag == .windows) return;
    const parent = try dir.openFile(io, "..", .{});
    defer parent.close(io);
    try parent.sync(io);
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
        try log.flush();
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
    for ([_]bool{ true, false }) |use_mmap| {
        try readDetectsDamage(io, tmp.dir, use_mmap);
    }
}

fn readDetectsDamage(io: Io, parent: Io.Dir, use_mmap: bool) !void {
    const sub = if (use_mmap) "mapped" else "plain";
    var log = try Log.open(testing.allocator, io, parent, sub, .{ .mmap = use_mmap }, NoVisitor{});
    defer log.close();
    const loc = try log.append(.{ .seq = 1, .kind = .put, .key = "a", .value = "hello" });
    try log.flush();
    try log.active.writePositionalAll(io, "J", loc.offset + loc.len - 1);
    var buf: [64]u8 = undefined;
    try testing.expectError(error.Corrupt, log.read(loc, &buf));
}

test "buffered, flushed and mapped reads all see the same records" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var log = try Log.open(testing.allocator, io, tmp.dir, "db", .{ .write_buffer_bytes = 100, .segment_bytes = 4096 }, NoVisitor{});
    defer log.close();

    var locs: std.ArrayList(Location) = .empty;
    defer locs.deinit(testing.allocator);
    for (0..200) |i| {
        var kb: [16]u8 = undefined;
        try locs.append(testing.allocator, try log.append(.{ .seq = i + 1, .kind = .put, .key = try std.fmt.bufPrint(&kb, "key{d}", .{i}), .value = "some value bytes" }));
    }
    try testing.expect(log.segments.items.len > 1);
    try testing.expect(log.wbuf.items.len > 0);

    var buf: [128]u8 = undefined;
    for (locs.items, 0..) |loc, i| {
        var kb: [16]u8 = undefined;
        const want = try std.fmt.bufPrint(&kb, "key{d}", .{i});
        const rec = try log.read(loc, &buf);
        try testing.expectEqualStrings(want, rec.key);
        if (try log.view(loc)) |v| try testing.expectEqualStrings(want, v.key);
    }
}

test "batches replay as their individual records" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var locs: [3]Location = undefined;
    {
        var log = try Log.open(testing.allocator, io, tmp.dir, "db", .{}, NoVisitor{});
        defer log.close();
        _ = try log.append(.{ .seq = 1, .kind = .put, .key = "x", .value = "0" });
        try log.appendBatch(&.{
            .{ .seq = 2, .kind = .put, .key = "a", .value = "1" },
            .{ .seq = 3, .kind = .delete, .key = "x" },
            .{ .seq = 4, .kind = .put, .key = "b", .value = "2" },
        }, &locs);
        var buf: [64]u8 = undefined;
        try testing.expectEqualStrings("b", (try log.read(locs[2], &buf)).key);
        try log.sync();
    }
    var c: Collector = .{};
    defer c.deinit();
    var log = try Log.open(testing.allocator, io, tmp.dir, "db", .{}, &c);
    defer log.close();
    try testing.expectEqual(@as(usize, 4), c.keys.items.len);
    try testing.expectEqualSlices(Location, &locs, c.locs.items[1..]);
    try testing.expectEqual(@as(u64, 4), log.last_seq);
}

test "a torn batch is dropped as a whole" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        var log = try Log.open(testing.allocator, io, tmp.dir, "db", .{}, NoVisitor{});
        defer log.close();
        _ = try log.append(.{ .seq = 1, .kind = .put, .key = "x", .value = "0" });
        var locs: [2]Location = undefined;
        try log.appendBatch(&.{
            .{ .seq = 2, .kind = .put, .key = "a", .value = "1" },
            .{ .seq = 3, .kind = .put, .key = "b", .value = "2" },
        }, &locs);
        try log.sync();
        // Cut the batch in the middle of its second operation.
        try log.active.setLength(io, log.active_end - 5);
    }
    var c: Collector = .{};
    defer c.deinit();
    var log = try Log.open(testing.allocator, io, tmp.dir, "db", .{}, &c);
    defer log.close();
    try testing.expectEqual(@as(usize, 1), c.keys.items.len);
    try testing.expectEqual(@as(u64, 1), log.last_seq);
}

test "rollover keeps a pinned sync handle open" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var log = try Log.open(std.testing.allocator, io, tmp.dir, "log", .{ .segment_bytes = 128 }, NoVisitor{});
    defer log.close();
    _ = try log.append(.{ .seq = 1, .kind = .put, .key = "key", .value = "some value bytes" });
    try log.flush();
    const pinned_id = log.active_id;
    const file = log.pinSyncHandle();
    var seq: u64 = 2;
    while (log.active_id == pinned_id) : (seq += 1) {
        _ = try log.append(.{ .seq = seq, .kind = .put, .key = "key", .value = "some value bytes" });
    }
    // The sealed segment's handle is still open for the pending sync.
    try std.testing.expect(log.segs.get(pinned_id).?.file != null);
    try file.sync(io);
    log.unpinSync();
    if (builtin.os.tag != .windows and builtin.os.tag != .wasi) {
        try std.testing.expect(log.segs.get(pinned_id).?.file == null);
    }
}

test "sealed mapped segments hold no file handle" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var log = try Log.open(std.testing.allocator, io, tmp.dir, "log", .{ .segment_bytes = 128 }, NoVisitor{});
    defer log.close();
    var seq: u64 = 1;
    var first: Location = undefined;
    while (log.segments.items.len < 5) : (seq += 1) {
        const loc = try log.append(.{ .seq = seq, .kind = .put, .key = "key", .value = "some value bytes" });
        if (seq == 1) first = loc;
    }
    if (builtin.os.tag != .windows and builtin.os.tag != .wasi) {
        for (log.segments.items) |id| {
            const seg = log.segs.get(id).?;
            if (id == log.active_id) try std.testing.expect(seg.file != null) else try std.testing.expect(seg.file == null);
        }
    }
    var buf: [128]u8 = undefined;
    const rec = try log.read(first, &buf);
    try std.testing.expectEqualStrings("some value bytes", rec.value);
    var scanner = try log.scanSegment(log.segments.items[0]);
    defer scanner.deinit();
    try std.testing.expect(try scanner.next() != null);
}

test "check tells a repairable tail from a damaged sealed segment" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var first: u64 = undefined;
    var last: u64 = undefined;
    {
        var log = try Log.open(testing.allocator, io, tmp.dir, "db", .{ .segment_bytes = 128 }, NoVisitor{});
        defer log.close();
        var seq: u64 = 1;
        while (log.segments.items.len < 3) : (seq += 1) {
            _ = try log.append(.{ .seq = seq, .kind = .put, .key = "key", .value = "some value bytes" });
        }
        first = log.segments.items[0];
        last = log.active_id;
    }
    var report = try Log.check(testing.allocator, io, tmp.dir, "db");
    try testing.expectEqual(@as(usize, 0), report.problems.items.len);
    report.deinit(testing.allocator);

    var dir = try tmp.dir.openDir(io, "db", .{});
    defer dir.close(io);
    for ([_]u64{ first, last }) |id| {
        var name_buf: [segment.name_len]u8 = undefined;
        const f = try dir.openFile(io, segment.fileName(&name_buf, id), .{ .mode = .read_write });
        defer f.close(io);
        try f.setLength(io, try f.length(io) - 3);
    }
    report = try Log.check(testing.allocator, io, tmp.dir, "db");
    defer report.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), report.problems.items.len);
    try testing.expectEqual(Problem.Kind.torn_sealed, report.problems.items[0].kind);
    try testing.expectEqual(Problem.Kind.torn_tail, report.problems.items[1].kind);
}

test "check finds a batch with a valid checksum but bad contents" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir = try tmp.dir.createDirPathOpen(io, "db", .{});
    defer dir.close(io);
    const op: record.Record = .{ .seq = 1, .kind = .put, .key = "a", .value = "1" };
    var buf: [record.header_len + 4 + 64]u8 = undefined;
    const op_len = record.encodedLen(op);
    const total = record.header_len + 4 + op_len;
    // The batch claims two operations but holds one.
    std.mem.writeInt(u32, buf[record.header_len..][0..4], 2, .little);
    record.encode(buf[record.header_len + 4 ..][0..op_len], op);
    record.finish(buf[0..total], 1, .batch, 4, @intCast(op_len));
    var name_buf: [segment.name_len]u8 = undefined;
    const f = try dir.createFile(io, segment.fileName(&name_buf, 1), .{});
    defer f.close(io);
    try f.writePositionalAll(io, buf[0..total], 0);

    var report = try Log.check(testing.allocator, io, tmp.dir, "db");
    defer report.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), report.problems.items.len);
    try testing.expectEqual(Problem.Kind.bad_batch, report.problems.items[0].kind);
    try testing.expectError(error.Corrupt, Log.open(testing.allocator, io, tmp.dir, "db", .{}, NoVisitor{}));
}

test "check refuses a directory another handle has open" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var log = try Log.open(testing.allocator, io, tmp.dir, "db", .{}, NoVisitor{});
    defer log.close();
    try testing.expectError(error.Locked, Log.check(testing.allocator, io, tmp.dir, "db"));
}
