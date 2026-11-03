//! Word meanings: a table of word vectors and nearest neighbours
//! (the `HOLOWV1` format: stems, int8 vectors, neighbour lists).
//!
//! Crystal looks words up by their packed number, so the table is an
//! open-addressing array of packed words, probed by a multiply-shift.
//! Nothing is stored per memory.

const std = @import("std");
const Allocator = std.mem.Allocator;
const words = @import("words.zig");

const Meaning = @This();

pub const max_dims = 320;
const none: u16 = 0xffff;

bytes: []u8,
count: u32,
dims: u16,
nbrs: u16,
vectors: []const i8,
/// count x nbrs x (u16 index, u8 similarity * 255)
neighbours: []const u8,
keys: []u64,
/// Slot -> index + 1.
slots: []u32,
shift: u6,

pub const Related = struct { key: u64, sim: f32 };

pub fn load(gpa: Allocator, bytes_in: []const u8) !*Meaning {
    const bytes = try gpa.dupe(u8, bytes_in);
    errdefer gpa.free(bytes);
    if (bytes.len < 16 or !std.mem.eql(u8, bytes[0..8], "HOLOWV1\x00")) return error.BadModel;
    const count = std.mem.readInt(u32, bytes[8..12], .little);
    const dims = std.mem.readInt(u16, bytes[12..14], .little);
    const nbrs = std.mem.readInt(u16, bytes[14..16], .little);
    if (dims == 0 or dims > max_dims or count == 0 or count >= none) return error.BadModel;
    const keys = try gpa.alloc(u64, count);
    errdefer gpa.free(keys);
    var p: usize = 16;
    for (keys) |*k| {
        if (p >= bytes.len) return error.BadModel;
        const l = bytes[p];
        p += 1;
        if (p + l > bytes.len or l == 0) return error.BadModel;
        k.* = words.pack(bytes[p..][0..l]);
        p += l;
    }
    const vlen = @as(usize, count) * dims;
    const nlen = @as(usize, count) * nbrs * 3;
    if (p + vlen + nlen != bytes.len) return error.BadModel;
    const neighbours = bytes[p + vlen ..][0..nlen];
    var k: usize = 0;
    while (k < nlen) : (k += 3) {
        const j = std.mem.readInt(u16, neighbours[k..][0..2], .little);
        if (j != none and j >= count) return error.BadModel;
    }
    var bits: u6 = 1;
    while ((@as(usize, 1) << bits) < @as(usize, count) * 2) bits += 1;
    const slots = try gpa.alloc(u32, @as(usize, 1) << bits);
    errdefer gpa.free(slots);
    @memset(slots, 0);
    const m = try gpa.create(Meaning);
    m.* = .{
        .bytes = bytes,
        .count = count,
        .dims = dims,
        .nbrs = nbrs,
        .vectors = @ptrCast(bytes[p..][0..vlen]),
        .neighbours = neighbours,
        .keys = keys,
        .slots = slots,
        .shift = @intCast(64 - @as(u7, bits)),
    };
    const mask = slots.len - 1;
    for (keys, 0..) |key, i| {
        var s = m.slotOf(key);
        while (slots[s] != 0) : (s = (s + 1) & mask) {
            // Two stems that pack the same (a long word hashed): first wins.
            if (keys[slots[s] - 1] == key) break;
        } else slots[s] = @intCast(i + 1);
    }
    return m;
}

pub fn deinit(m: *Meaning, gpa: Allocator) void {
    gpa.free(m.slots);
    gpa.free(m.keys);
    gpa.free(m.bytes);
    gpa.destroy(m);
}

inline fn slotOf(m: *const Meaning, key: u64) usize {
    return @intCast((key *% 0x9E3779B97F4A7C15) >> m.shift);
}

pub fn index(m: *const Meaning, key: u64) ?u32 {
    const mask = m.slots.len - 1;
    var s = m.slotOf(key);
    while (true) : (s = (s + 1) & mask) {
        const e = m.slots[s];
        if (e == 0) return null;
        if (m.keys[e - 1] == key) return e - 1;
    }
}

/// Up to `out.len` related words with similarity at least `min_sim`.
pub fn related(m: *const Meaning, key: u64, min_sim: f32, out: []Related) usize {
    const i = m.index(key) orelse return 0;
    const row = m.neighbours[@as(usize, i) * m.nbrs * 3 ..][0 .. @as(usize, m.nbrs) * 3];
    var n: usize = 0;
    for (0..m.nbrs) |k| {
        if (n == out.len) break;
        const j = std.mem.readInt(u16, row[k * 3 ..][0..2], .little);
        if (j == none) break;
        const sim = @as(f32, @floatFromInt(row[k * 3 + 2])) / 255.0;
        if (sim < min_sim) break;
        out[n] = .{ .key = m.keys[j], .sim = sim };
        n += 1;
    }
    return n;
}

/// Cosine similarity of two words by index.
pub fn similarity(m: *const Meaning, a: u32, b: u32) f32 {
    const va = m.vectors[@as(usize, a) * m.dims ..][0..m.dims];
    const vb = m.vectors[@as(usize, b) * m.dims ..][0..m.dims];
    const W = 32;
    var acc: @Vector(W, i32) = @splat(0);
    var d: usize = 0;
    while (d + W <= m.dims) : (d += W) {
        const x: @Vector(W, i32) = @as(@Vector(W, i8), va[d..][0..W].*);
        const y: @Vector(W, i32) = @as(@Vector(W, i8), vb[d..][0..W].*);
        acc += x * y;
    }
    var dot: i32 = @reduce(.Add, acc);
    while (d < m.dims) : (d += 1) dot += @as(i32, va[d]) * @as(i32, vb[d]);
    return @as(f32, @floatFromInt(dot)) / (127.0 * 127.0);
}
