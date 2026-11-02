//! v3 batch journal: makes a batch that spans several streams (or shards)
//! atomic even though v3 has no write-ahead log.
//!
//! A batch is written here first, then applied to the shards' tails. Before
//! any shard writes a page or a manifest, it syncs this file, so a batch
//! record is durable before any part of the batch can be. On open, every
//! record still here is replayed: each operation that its stream does not
//! already hold (by sequence number) goes back into the stream's tail.
//!
//! Once every shard has synced past every record, the file is emptied.
//!
//! Record: [u32 body_len][u32 crc32c(body)][body]
//! Body:   u32 op count, then per op:
//!         u8 shard, u8 kind, u64 seq, u16 key_len, u32 value_len, key, value
//! Values are stored as the tail holds them (TTL values keep their prefix).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Crc32c = std.hash.crc.@"CRC-32/ISCSI";

const Journal = @This();

pub const file_name = "BATCHES";
/// Empty the file once it grows past this.
pub const reset_bytes = 1 << 20;

io: Io,
file: Io.File,
/// Held from writing a batch record until the batch is applied, and while
/// the file is emptied, so emptying never drops an unapplied batch.
batch_mutex: Io.Mutex = .init,
/// Guards `len`, `synced_len` and the file itself.
file_mutex: Io.Mutex = .init,
len: u64 = 0,
synced_len: u64 = 0,

pub const Op = struct {
    shard: u8,
    kind: u8,
    seq: u64,
    key: []const u8,
    value: []const u8,
};

pub fn open(io: Io, dir: Io.Dir) !Journal {
    const file = try dir.createFile(io, file_name, .{ .read = true, .truncate = false });
    const len = try file.length(io);
    return .{ .io = io, .file = file, .len = len, .synced_len = len };
}

pub fn close(j: *Journal) void {
    j.file.close(j.io);
}

/// Appends one encoded record (see `Encoder`). Not synced yet.
pub fn append(j: *Journal, rec: []const u8) !void {
    j.file_mutex.lockUncancelable(j.io);
    defer j.file_mutex.unlock(j.io);
    try j.file.writePositionalAll(j.io, rec, j.len);
    j.len += rec.len;
}

/// Makes every appended record durable. Shards call this before writing
/// pages or a manifest.
pub fn syncIfNeeded(j: *Journal) !void {
    j.file_mutex.lockUncancelable(j.io);
    defer j.file_mutex.unlock(j.io);
    if (j.synced_len >= j.len) return;
    try j.file.sync(j.io);
    j.synced_len = j.len;
}

/// Empties the file. Only call it once every shard has synced past every
/// record, with `batch_mutex` held.
pub fn reset(j: *Journal) !void {
    j.file_mutex.lockUncancelable(j.io);
    defer j.file_mutex.unlock(j.io);
    if (j.len == 0) return;
    try j.file.setLength(j.io, 0);
    try j.file.sync(j.io);
    j.len = 0;
    j.synced_len = 0;
}

/// Reads every intact record, oldest first. A torn or damaged record and
/// everything after it is ignored: those batches never became durable.
pub fn readAll(j: *Journal, gpa: Allocator) ![]u8 {
    const bytes = try gpa.alloc(u8, j.len);
    errdefer gpa.free(bytes);
    if (try j.file.readPositionalAll(j.io, bytes, 0) != bytes.len) return error.Corrupt;
    var pos: usize = 0;
    while (pos + 8 <= bytes.len) {
        const body_len = std.mem.readInt(u32, bytes[pos..][0..4], .little);
        if (body_len < 4 or pos + 8 + body_len > bytes.len) break;
        const body = bytes[pos + 8 ..][0..body_len];
        if (Crc32c.hash(body) != std.mem.readInt(u32, bytes[pos + 4 ..][0..4], .little)) break;
        if (!validBody(body)) break;
        pos += 8 + body_len;
    }
    return gpa.realloc(bytes, pos);
}

fn validBody(body: []const u8) bool {
    var it: Iterator = .{ .bytes = body[4..], .remaining = std.mem.readInt(u32, body[0..4], .little) };
    while (it.next() catch return false) |_| {}
    return it.pos == it.bytes.len;
}

/// Walks the ops of records returned by `readAll`.
pub const RecordIterator = struct {
    bytes: []const u8,
    pos: usize = 0,

    pub fn next(r: *RecordIterator) ?Iterator {
        if (r.pos + 8 > r.bytes.len) return null;
        const body_len = std.mem.readInt(u32, r.bytes[r.pos..][0..4], .little);
        const body = r.bytes[r.pos + 8 ..][0..body_len];
        r.pos += 8 + body_len;
        return .{ .bytes = body[4..], .remaining = std.mem.readInt(u32, body[0..4], .little) };
    }
};

pub const Iterator = struct {
    bytes: []const u8,
    remaining: u32,
    pos: usize = 0,

    pub fn next(it: *Iterator) error{Corrupt}!?Op {
        if (it.remaining == 0) return null;
        const b = it.bytes;
        if (it.pos + 16 > b.len) return error.Corrupt;
        const shard = b[it.pos];
        const kind = b[it.pos + 1];
        const seq = std.mem.readInt(u64, b[it.pos + 2 ..][0..8], .little);
        const kl = std.mem.readInt(u16, b[it.pos + 10 ..][0..2], .little);
        const vl = std.mem.readInt(u32, b[it.pos + 12 ..][0..4], .little);
        it.pos += 16;
        if (kl == 0 or it.pos + kl + vl > b.len) return error.Corrupt;
        const key = b[it.pos..][0..kl];
        const value = b[it.pos + kl ..][0..vl];
        it.pos += kl + vl;
        it.remaining -= 1;
        return .{ .shard = shard, .kind = kind, .seq = seq, .key = key, .value = value };
    }
};

/// Builds one record in memory.
pub const Encoder = struct {
    buf: std.ArrayList(u8) = .empty,
    count: u32 = 0,

    pub fn begin(e: *Encoder, gpa: Allocator) !void {
        e.buf.clearRetainingCapacity();
        e.count = 0;
        try e.buf.appendNTimes(gpa, 0, 12);
    }

    pub fn add(e: *Encoder, gpa: Allocator, op: Op, value_prefix: ?u64) !void {
        const vl = op.value.len + @as(usize, if (value_prefix != null) 8 else 0);
        const h = try e.buf.addManyAsSlice(gpa, 16);
        h[0] = op.shard;
        h[1] = op.kind;
        std.mem.writeInt(u64, h[2..10], op.seq, .little);
        std.mem.writeInt(u16, h[10..12], @intCast(op.key.len), .little);
        std.mem.writeInt(u32, h[12..16], @intCast(vl), .little);
        try e.buf.appendSlice(gpa, op.key);
        if (value_prefix) |p| std.mem.writeInt(u64, try e.buf.addManyAsArray(gpa, 8), p, .little);
        try e.buf.appendSlice(gpa, op.value);
        e.count += 1;
    }

    pub fn finish(e: *Encoder) []const u8 {
        const b = e.buf.items;
        std.mem.writeInt(u32, b[8..12], e.count, .little);
        std.mem.writeInt(u32, b[0..4], @intCast(b.len - 8), .little);
        std.mem.writeInt(u32, b[4..8], Crc32c.hash(b[8..]), .little);
        return b;
    }

    pub fn deinit(e: *Encoder, gpa: Allocator) void {
        e.buf.deinit(gpa);
    }
};

test "records round trip and a torn tail is dropped" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var j = try Journal.open(io, tmp.dir);
    defer j.close();
    var enc: Encoder = .{};
    defer enc.deinit(gpa);
    try enc.begin(gpa);
    try enc.add(gpa, .{ .shard = 1, .kind = 1, .seq = 7, .key = "a/b/c", .value = "v" }, null);
    try enc.add(gpa, .{ .shard = 0, .kind = 3, .seq = 9, .key = "x", .value = "w" }, 42);
    try j.append(enc.finish());
    try enc.begin(gpa);
    try enc.add(gpa, .{ .shard = 0, .kind = 2, .seq = 10, .key = "y", .value = "" }, null);
    const second = enc.finish();
    try j.append(second[0 .. second.len - 3]); // torn
    try j.syncIfNeeded();

    const all = try j.readAll(gpa);
    defer gpa.free(all);
    var recs: RecordIterator = .{ .bytes = all };
    var it = recs.next().?;
    const a = (try it.next()).?;
    try std.testing.expectEqualStrings("a/b/c", a.key);
    try std.testing.expectEqual(@as(u64, 7), a.seq);
    const b = (try it.next()).?;
    try std.testing.expectEqual(@as(u64, 42), std.mem.readInt(u64, b.value[0..8], .little));
    try std.testing.expectEqualStrings("w", b.value[8..]);
    try std.testing.expect((try it.next()) == null);
    try std.testing.expect(recs.next() == null);

    try j.reset();
    try std.testing.expectEqual(@as(u64, 0), try j.file.length(io));
}
