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

const std = @import("std");

pub const Crc32c = std.hash.crc.@"CRC-32/ISCSI";

pub const header_len = 21;
pub const max_key_len: u32 = 64 * 1024;
pub const max_value_len: u32 = 16 * 1024 * 1024;

pub const Kind = enum(u8) {
    put = 1,
    delete = 2,
    _,
};

pub const Record = struct {
    seq: u64,
    kind: Kind,
    key: []const u8,
    value: []const u8 = &.{},
};

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
            .delete => h.value_len == 0,
            _ => false,
        };
    }
};

pub const ValidateError = error{ EmptyKey, KeyTooLarge, ValueTooLarge, DeleteWithValue };

pub fn validate(rec: Record) ValidateError!void {
    if (rec.key.len == 0) return error.EmptyKey;
    if (rec.key.len > max_key_len) return error.KeyTooLarge;
    if (rec.value.len > max_value_len) return error.ValueTooLarge;
    if (rec.kind == .delete and rec.value.len != 0) return error.DeleteWithValue;
}

pub fn encodedLen(rec: Record) usize {
    return header_len + rec.key.len + rec.value.len;
}

/// Writes `rec` into `out`, which must be exactly `encodedLen(rec)` bytes.
/// The record must already pass `validate`.
pub fn encode(out: []u8, rec: Record) void {
    std.debug.assert(out.len == encodedLen(rec));
    std.mem.writeInt(u64, out[4..12], rec.seq, .little);
    out[12] = @backingInt(rec.kind);
    std.mem.writeInt(u32, out[13..17], @intCast(rec.key.len), .little);
    std.mem.writeInt(u32, out[17..21], @intCast(rec.value.len), .little);
    @memcpy(out[header_len..][0..rec.key.len], rec.key);
    @memcpy(out[header_len + rec.key.len ..], rec.value);
    std.mem.writeInt(u32, out[0..4], Crc32c.hash(out[4..]), .little);
}

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
pub fn view(h: Header, full: []const u8) Record {
    const key = full[header_len..][0..h.key_len];
    const value = full[header_len + h.key_len ..][0..h.value_len];
    return .{ .seq = h.seq, .kind = h.kind, .key = key, .value = value };
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
