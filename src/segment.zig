//! Segment files: append-only logs named `0000000001.log`, `0000000002.log`, ...
//!
//! This module names segments and scans them. Writing lives in `Log.zig`.

const std = @import("std");
const Io = std.Io;
const record = @import("record.zig");

pub const name_len = 14; // 10 digits + ".log"
const suffix = ".log";

pub fn fileName(buf: *[name_len]u8, id: u64) []const u8 {
    return std.fmt.bufPrint(buf, "{d:0>10}" ++ suffix, .{id}) catch unreachable;
}

/// Returns the segment id for a segment file name, or null for any other file.
pub fn parseFileName(name: []const u8) ?u64 {
    if (name.len != name_len or !std.mem.endsWith(u8, name, suffix)) return null;
    const id = std.fmt.parseInt(u64, name[0 .. name_len - suffix.len], 10) catch return null;
    return if (id == 0) null else id;
}

/// Why a scan stopped.
pub const Stop = enum {
    /// Every byte of the file was a valid record.
    end,
    /// The file ends in an incomplete or damaged record and no valid record
    /// follows it. This is what a crash in the middle of a write leaves.
    torn,
    /// A damaged record is followed by at least one valid record, so data
    /// in the middle of the file was lost. Never silently truncated.
    corrupt,
};

pub const Item = struct {
    offset: u64,
    /// Borrows the scanner's buffer; valid until the next call to `next`.
    record: record.Record,
};

/// Reads records from the start of a segment, verifying every checksum.
pub const Scanner = struct {
    gpa: std.mem.Allocator,
    io: Io,
    file: Io.File,
    file_len: u64,
    buf: []u8,
    buf_start: u64 = 0,
    buf_len: usize = 0,
    /// Offset of the next record. After `next` returns null this is the end
    /// of the last valid record.
    pos: u64 = 0,
    stop: Stop = .end,

    const initial_buf = 256 * 1024;

    pub fn init(gpa: std.mem.Allocator, io: Io, file: Io.File) !Scanner {
        const len = try file.length(io);
        return .{
            .gpa = gpa,
            .io = io,
            .file = file,
            .file_len = len,
            .buf = try gpa.alloc(u8, initial_buf),
        };
    }

    pub fn deinit(s: *Scanner) void {
        s.gpa.free(s.buf);
        s.* = undefined;
    }

    pub fn next(s: *Scanner) !?Item {
        if (s.pos == s.file_len) {
            s.stop = .end;
            return null;
        }
        if (try s.recordAt(s.pos)) |rec| {
            const item: Item = .{ .offset = s.pos, .record = rec };
            s.pos += record.encodedLen(rec);
            return item;
        }
        s.stop = try s.classify(s.pos);
        return null;
    }

    /// Returns the record at `offset` if a complete, checksummed record is there.
    fn recordAt(s: *Scanner, offset: u64) !?record.Record {
        if (s.file_len - offset < record.header_len) return null;
        const head = try s.window(offset, record.header_len);
        const h = record.decodeHeader(head[0..record.header_len]);
        if (!h.isPlausible()) return null;
        if (s.file_len - offset < h.totalLen()) return null;
        const full = try s.window(offset, h.totalLen());
        if (!record.checksumMatches(h, full)) return null;
        return record.view(h, full);
    }

    /// A bad record at `bad` is only a torn tail if nothing valid follows it.
    fn classify(s: *Scanner, bad: u64) !Stop {
        var off = bad + 1;
        while (off + record.header_len <= s.file_len) : (off += 1) {
            if (try s.recordAt(off) != null) return .corrupt;
        }
        return .torn;
    }

    /// Returns `len` bytes starting at `offset`, refilling the buffer if needed.
    /// The caller guarantees the range lies inside the file.
    fn window(s: *Scanner, offset: u64, len: usize) ![]const u8 {
        if (offset >= s.buf_start and offset + len <= s.buf_start + s.buf_len) {
            const start: usize = @intCast(offset - s.buf_start);
            return s.buf[start..][0..len];
        }
        if (len > s.buf.len) {
            s.gpa.free(s.buf);
            s.buf = try s.gpa.alloc(u8, len);
        }
        const want: usize = @intCast(@min(s.buf.len, s.file_len - offset));
        const got = try s.file.readPositionalAll(s.io, s.buf[0..want], offset);
        if (got < len) return error.UnexpectedEndOfFile;
        s.buf_start = offset;
        s.buf_len = got;
        return s.buf[0..len];
    }
};

test "file names round trip" {
    var buf: [name_len]u8 = undefined;
    const name = fileName(&buf, 7);
    try std.testing.expectEqualStrings("0000000007.log", name);
    try std.testing.expectEqual(@as(?u64, 7), parseFileName(name));
    try std.testing.expectEqual(@as(?u64, null), parseFileName("LOCK"));
    try std.testing.expectEqual(@as(?u64, null), parseFileName("0000000000.log"));
    try std.testing.expectEqual(@as(?u64, null), parseFileName("00000000x1.log"));
}

fn writeRecords(io: Io, file: Io.File, recs: []const record.Record) !u64 {
    var off: u64 = 0;
    var buf: [256]u8 = undefined;
    for (recs) |rec| {
        const out = buf[0..record.encodedLen(rec)];
        record.encode(out, rec);
        try file.writePositionalAll(io, out, off);
        off += out.len;
    }
    return off;
}

fn scanAll(io: Io, file: Io.File) !struct { count: usize, end: u64, stop: Stop } {
    var s = try Scanner.init(std.testing.allocator, io, file);
    defer s.deinit();
    var count: usize = 0;
    while (try s.next()) |_| count += 1;
    return .{ .count = count, .end = s.pos, .stop = s.stop };
}

const sample = [_]record.Record{
    .{ .seq = 1, .kind = .put, .key = "a", .value = "one" },
    .{ .seq = 2, .kind = .put, .key = "b", .value = "two" },
    .{ .seq = 3, .kind = .delete, .key = "a" },
};

test "scanner reads every record of a clean file" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(io, "s.log", .{ .read = true });
    defer file.close(io);
    const len = try writeRecords(io, file, &sample);

    const r = try scanAll(io, file);
    try std.testing.expectEqual(@as(usize, 3), r.count);
    try std.testing.expectEqual(len, r.end);
    try std.testing.expectEqual(Stop.end, r.stop);
}

test "a half-written last record is a torn tail" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(io, "s.log", .{ .read = true });
    defer file.close(io);
    const len = try writeRecords(io, file, &sample);
    try file.setLength(io, len - 2);

    const r = try scanAll(io, file);
    try std.testing.expectEqual(@as(usize, 2), r.count);
    try std.testing.expectEqual(Stop.torn, r.stop);
}

test "zero-filled tail is a torn tail" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(io, "s.log", .{ .read = true });
    defer file.close(io);
    const len = try writeRecords(io, file, &sample);
    try file.setLength(io, len + 4096);

    const r = try scanAll(io, file);
    try std.testing.expectEqual(@as(usize, 3), r.count);
    try std.testing.expectEqual(len, r.end);
    try std.testing.expectEqual(Stop.torn, r.stop);
}

test "damage followed by valid records is corruption, not a tail" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(io, "s.log", .{ .read = true });
    defer file.close(io);
    _ = try writeRecords(io, file, &sample);
    // Flip a byte inside the first record's value.
    try file.writePositionalAll(io, "X", record.header_len + 1);

    const r = try scanAll(io, file);
    try std.testing.expectEqual(@as(usize, 0), r.count);
    try std.testing.expectEqual(@as(u64, 0), r.end);
    try std.testing.expectEqual(Stop.corrupt, r.stop);
}
