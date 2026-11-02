//! On-disk record encoding.
//!
//! Every record is a fixed 21-byte header followed by the key and value:
//!
//!   offset  size  field
//!   0       4     crc32c of bytes 4.. (rest of header + key + value)
//!   4       8     seq       (u64, little endian, starts at 1)
//!   12      1     kind      (1 = put, 2 = delete)
//!   13      4     key_len   (u32, little endian)
//!   17      4     value_len (u32, little endian, 0 for delete)
//!   21      ...   key bytes, then value bytes
//!
//! A batch record (kind 3) has a 4-byte key holding the operation count and
//! a value made of complete put/delete records. One outer checksum covers
//! the whole batch, so after a crash it is applied entirely or not at all.

const std = @import("std");

pub const Crc32c = std.hash.crc.@"CRC-32/ISCSI";

pub const header_len = 21;
pub const max_key_len: u32 = 64 * 1024;
pub const max_value_len: u32 = 16 * 1024 * 1024;

pub const Kind = enum(u8) {
    put = 1,
    delete = 2,
    batch = 3,
    /// Operations inside a batch use their own kinds so that a scan of
    /// the file never mistakes one for a top-level record. That keeps a
    /// torn batch looking like a torn tail instead of mid-file damage.
    batch_put = 4,
    batch_delete = 5,
    /// A put that expires. The value starts with the expiry time as a
    /// u64 of unix seconds (little endian), followed by the user value.
    put_ttl = 6,
    batch_put_ttl = 7,
    _,
};

pub const Record = struct {
    seq: u64,
    kind: Kind,
    key: []const u8,
    value: []const u8 = &.{},
    /// Unix seconds after which a `put_ttl` record no longer counts.
    expires: u64 = 0,
};

pub const ttl_prefix_len = 8;

fn hasTtl(kind: Kind) bool {
    return kind == .put_ttl or kind == .batch_put_ttl;
}

pub const Header = struct {
    crc: u32,
    seq: u64,
    kind: Kind,
    key_len: u32,
    value_len: u32,

    pub fn bodyLen(h: Header) usize {
        return @as(usize, h.key_len) + h.value_len;
    }

    pub fn totalLen(h: Header) usize {
        return header_len + h.bodyLen();
    }

    /// Structural checks that do not need the body. A header that fails
    /// these can never have been written by us.
    pub fn isPlausible(h: Header) bool {
        if (h.seq == 0) return false;
        if (h.key_len == 0 or h.key_len > max_key_len) return false;
        if (h.value_len > max_value_len) return false;
        return switch (h.kind) {
            .put => true,
            .put_ttl => h.value_len >= ttl_prefix_len,
            .delete => h.value_len == 0,
            .batch => h.key_len == 4 and h.value_len >= header_len,
            .batch_put, .batch_delete, .batch_put_ttl, _ => false,
        };
    }

    /// Structural checks for an operation inside a batch.
    pub fn isPlausibleInBatch(h: Header) bool {
        if (h.seq == 0) return false;
        if (h.key_len == 0 or h.key_len > max_key_len) return false;
        if (h.value_len > max_value_len) return false;
        return switch (h.kind) {
            .batch_put => true,
            .batch_put_ttl => h.value_len >= ttl_prefix_len,
            .batch_delete => h.value_len == 0,
            else => false,
        };
    }
};

pub const ValidateError = error{ EmptyKey, KeyTooLarge, ValueTooLarge, DeleteWithValue, MissingExpiry, InvalidKind };

/// Checks a top-level record before it is written, so that everything
/// `append` accepts is something recovery will read back.
pub fn validate(rec: Record) ValidateError!void {
    switch (rec.kind) {
        .put, .delete, .put_ttl => {},
        else => return error.InvalidKind,
    }
    if (rec.key.len == 0) return error.EmptyKey;
    if (rec.key.len > max_key_len) return error.KeyTooLarge;
    const ttl: usize = if (hasTtl(rec.kind)) ttl_prefix_len else 0;
    if (rec.value.len + ttl > max_value_len) return error.ValueTooLarge;
    if (rec.kind == .delete and rec.value.len != 0) return error.DeleteWithValue;
    if (rec.kind == .put_ttl and rec.expires == 0) return error.MissingExpiry;
}

pub fn encodedLen(rec: Record) usize {
    const ttl: usize = if (hasTtl(rec.kind)) ttl_prefix_len else 0;
    return header_len + rec.key.len + ttl + rec.value.len;
}

/// Writes `rec` into `out`, which must be exactly `encodedLen(rec)` bytes.
/// The record must already pass `validate`.
pub fn encode(out: []u8, rec: Record) void {
    std.debug.assert(out.len == encodedLen(rec));
    std.mem.writeInt(u64, out[4..12], rec.seq, .little);
    out[12] = @backingInt(rec.kind);
    std.mem.writeInt(u32, out[13..17], @intCast(rec.key.len), .little);
    const value_len = out.len - header_len - rec.key.len;
    std.mem.writeInt(u32, out[17..21], @intCast(value_len), .little);
    @memcpy(out[header_len..][0..rec.key.len], rec.key);
    var pos = header_len + rec.key.len;
    if (hasTtl(rec.kind)) {
        std.mem.writeInt(u64, out[pos..][0..8], rec.expires, .little);
        pos += ttl_prefix_len;
    }
    @memcpy(out[pos..], rec.value);
    std.mem.writeInt(u32, out[0..4], Crc32c.hash(out[4..]), .little);
}

/// Fills in the header and checksum of a record whose key and value bytes
/// are already in place in `out`.
pub fn finish(out: []u8, seq: u64, kind: Kind, key_len: u32, value_len: u32) void {
    std.debug.assert(out.len == header_len + @as(usize, key_len) + value_len);
    std.mem.writeInt(u64, out[4..12], seq, .little);
    out[12] = @backingInt(kind);
    std.mem.writeInt(u32, out[13..17], key_len, .little);
    std.mem.writeInt(u32, out[17..21], value_len, .little);
    std.mem.writeInt(u32, out[0..4], Crc32c.hash(out[4..]), .little);
}

/// Walks the operations inside a verified batch record.
pub const BatchIterator = struct {
    /// The batch record's value: the encoded operations.
    body: []const u8,
    remaining: u32,
    pos: usize = 0,

    pub const Item = struct {
        /// Offset of the operation inside `body`.
        offset: usize,
        bytes: []const u8,
        record: Record,
    };

    pub fn init(batch: Record) BatchIterator {
        std.debug.assert(batch.kind == .batch);
        return .{ .body = batch.value, .remaining = std.mem.readInt(u32, batch.key[0..4], .little) };
    }

    pub fn next(it: *BatchIterator) error{Corrupt}!?Item {
        if (it.remaining == 0) {
            if (it.pos != it.body.len) return error.Corrupt;
            return null;
        }
        if (it.body.len - it.pos < header_len) return error.Corrupt;
        const h = decodeHeader(it.body[it.pos..][0..header_len]);
        if (!h.isPlausibleInBatch()) return error.Corrupt;
        if (it.body.len - it.pos < h.totalLen()) return error.Corrupt;
        const full = it.body[it.pos..][0..h.totalLen()];
        if (!checksumMatches(h, full)) return error.Corrupt;
        const item: Item = .{ .offset = it.pos, .bytes = full, .record = view(h, full) };
        it.pos += full.len;
        it.remaining -= 1;
        return item;
    }
};

pub fn decodeHeader(bytes: *const [header_len]u8) Header {
    return .{
        .crc = std.mem.readInt(u32, bytes[0..4], .little),
        .seq = std.mem.readInt(u64, bytes[4..12], .little),
        .kind = @fromBackingInt(@intCast(bytes[12])),
        .key_len = std.mem.readInt(u32, bytes[13..17], .little),
        .value_len = std.mem.readInt(u32, bytes[17..21], .little),
    };
}

/// Checks the CRC of a complete encoded record (header + body).
pub fn checksumMatches(h: Header, full: []const u8) bool {
    std.debug.assert(full.len == h.totalLen());
    return Crc32c.hash(full[4..]) == h.crc;
}

/// Splits a verified record's bytes into a `Record` that borrows them.
/// Batch operation kinds are reported as plain `put` and `delete`.
pub fn view(h: Header, full: []const u8) Record {
    const key = full[header_len..][0..h.key_len];
    var value = full[header_len + h.key_len ..][0..h.value_len];
    var expires: u64 = 0;
    if (hasTtl(h.kind)) {
        expires = std.mem.readInt(u64, value[0..8], .little);
        value = value[ttl_prefix_len..];
    }
    const kind: Kind = switch (h.kind) {
        .batch_put => .put,
        .batch_delete => .delete,
        .batch_put_ttl => .put_ttl,
        else => h.kind,
    };
    return .{ .seq = h.seq, .kind = kind, .key = key, .value = value, .expires = expires };
}

/// The kind an operation is stored with inside a batch.
pub fn inBatch(kind: Kind) Kind {
    return switch (kind) {
        .put => .batch_put,
        .put_ttl => .batch_put_ttl,
        .delete => .batch_delete,
        else => unreachable,
    };
}

test "encode and decode round trip" {
    const rec: Record = .{ .seq = 42, .kind = .put, .key = "agent/1/note", .value = "hello" };
    try validate(rec);
    var buf: [64]u8 = undefined;
    const out = buf[0..encodedLen(rec)];
    encode(out, rec);

    const h = decodeHeader(out[0..header_len]);
    try std.testing.expect(h.isPlausible());
    try std.testing.expectEqual(out.len, h.totalLen());
    try std.testing.expect(checksumMatches(h, out));

    const back = view(h, out);
    try std.testing.expectEqual(@as(u64, 42), back.seq);
    try std.testing.expectEqual(Kind.put, back.kind);
    try std.testing.expectEqualStrings("agent/1/note", back.key);
    try std.testing.expectEqualStrings("hello", back.value);
}

test "ttl records carry their expiry" {
    const rec: Record = .{ .seq = 9, .kind = .put_ttl, .key = "k", .value = "v", .expires = 1234 };
    try validate(rec);
    var buf: [64]u8 = undefined;
    const out = buf[0..encodedLen(rec)];
    encode(out, rec);
    const h = decodeHeader(out[0..header_len]);
    try std.testing.expect(h.isPlausible() and checksumMatches(h, out));
    const back = view(h, out);
    try std.testing.expectEqual(@as(u64, 1234), back.expires);
    try std.testing.expectEqualStrings("v", back.value);
    try std.testing.expectEqual(Kind.put_ttl, back.kind);
}

test "a flipped bit fails the checksum" {
    const rec: Record = .{ .seq = 1, .kind = .put, .key = "k", .value = "v" };
    var buf: [header_len + 2]u8 = undefined;
    encode(&buf, rec);
    buf[buf.len - 1] ^= 0x01;
    const h = decodeHeader(buf[0..header_len]);
    try std.testing.expect(!checksumMatches(h, &buf));
}

test "zeroed bytes never look like a record" {
    const zeros: [header_len]u8 = @splat(0);
    try std.testing.expect(!decodeHeader(&zeros).isPlausible());
}

test "validate rejects bad input" {
    try std.testing.expectError(error.EmptyKey, validate(.{ .seq = 1, .kind = .put, .key = "" }));
    try std.testing.expectError(error.DeleteWithValue, validate(.{ .seq = 1, .kind = .delete, .key = "k", .value = "x" }));
}

test "validate rejects what recovery would not read back" {
    try std.testing.expectError(error.InvalidKind, validate(.{ .seq = 1, .kind = @fromBackingInt(@intCast(9)), .key = "k" }));
    try std.testing.expectError(error.InvalidKind, validate(.{ .seq = 1, .kind = .batch_put, .key = "k" }));
    // validate only looks at the length, so the bytes are never read.
    var fake: [1]u8 = .{0};
    const too_big: []const u8 = (&fake).ptr[0 .. max_value_len - ttl_prefix_len + 1];
    try std.testing.expectError(error.ValueTooLarge, validate(.{ .seq = 1, .kind = .put_ttl, .key = "k", .value = too_big, .expires = 5 }));
}
