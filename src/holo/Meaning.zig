//! Word meaning for Holo, from a small table of word vectors
//! (`models/holo-words.bin`, built by `tools/export_words.py`).
//!
//! Two uses, neither of which costs anything per stored memory:
//!   * related words: "outage" also searches "downtime" and "disruption",
//!   * sentence meaning: candidates are reranked by how close their words
//!     are in meaning to the question, so "which datacenter hosts X?" can
//!     find "X runs in the eu-west region".
//!
//! Words are stored stemmed, the same way `text.zig` stems them, and are
//! looked up by the same term hash.

const std = @import("std");
const Allocator = std.mem.Allocator;
const text = @import("text.zig");

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
/// Open-addressing table from term hash to index + 1.
slots: []u32,
hashes: []u64,

pub const Related = struct { hash: u64, sim: f32 };

pub fn load(gpa: Allocator, bytes_in: []const u8) !*Meaning {
    const bytes = try gpa.dupe(u8, bytes_in);
    errdefer gpa.free(bytes);
    if (bytes.len < 16 or !std.mem.eql(u8, bytes[0..8], "HOLOWV1\x00")) return error.BadModel;
    const count = std.mem.readInt(u32, bytes[8..12], .little);
    const dims = std.mem.readInt(u16, bytes[12..14], .little);
    const nbrs = std.mem.readInt(u16, bytes[14..16], .little);
    if (dims == 0 or dims > max_dims or count == 0 or count >= none) return error.BadModel;
    const hashes = try gpa.alloc(u64, count);
    errdefer gpa.free(hashes);
    var p: usize = 16;
    for (hashes) |*hsh| {
        if (p >= bytes.len) return error.BadModel;
        const l = bytes[p];
        p += 1;
        if (p + l > bytes.len) return error.BadModel;
        hsh.* = text.hashTerm(bytes[p..][0..l]);
        p += l;
    }
    const vlen = @as(usize, count) * dims;
    const nlen = @as(usize, count) * nbrs * 3;
    if (p + vlen + nlen != bytes.len) return error.BadModel;
    const vectors: []const i8 = @ptrCast(bytes[p..][0..vlen]);
    const neighbours = bytes[p + vlen ..][0..nlen];

    var cap: usize = 1;
    while (cap < @as(usize, count) * 2) cap <<= 1;
    const slots = try gpa.alloc(u32, cap);
    errdefer gpa.free(slots);
    @memset(slots, 0);
    for (hashes, 0..) |hsh, i| {
        var s: usize = @intCast(hsh & (cap - 1));
        while (slots[s] != 0) : (s = (s + 1) & (cap - 1)) {}
        slots[s] = @intCast(i + 1);
    }
    const m = try gpa.create(Meaning);
    m.* = .{ .bytes = bytes, .count = count, .dims = dims, .nbrs = nbrs, .vectors = vectors, .neighbours = neighbours, .slots = slots, .hashes = hashes };
    return m;
}

pub fn deinit(m: *Meaning, gpa: Allocator) void {
    gpa.free(m.slots);
    gpa.free(m.hashes);
    gpa.free(m.bytes);
    gpa.destroy(m);
}

pub fn index(m: *const Meaning, hsh: u64) ?u32 {
    const mask = m.slots.len - 1;
    var s: usize = @intCast(hsh & mask);
    while (m.slots[s] != 0) : (s = (s + 1) & mask) {
        const i = m.slots[s] - 1;
        if (m.hashes[i] == hsh) return i;
    }
    return null;
}

/// Up to `out.len` related words with similarity at least `min_sim`.
pub fn related(m: *const Meaning, hsh: u64, min_sim: f32, out: []Related) usize {
    const i = m.index(hsh) orelse return 0;
    const row = m.neighbours[@as(usize, i) * m.nbrs * 3 ..][0 .. @as(usize, m.nbrs) * 3];
    var n: usize = 0;
    for (0..m.nbrs) |k| {
        if (n == out.len) break;
        const j = std.mem.readInt(u16, row[k * 3 ..][0..2], .little);
        if (j == none) break;
        const sim = @as(f32, @floatFromInt(row[k * 3 + 2])) / 255.0;
        if (sim < min_sim) break;
        out[n] = .{ .hash = m.hashes[j], .sim = sim };
        n += 1;
    }
    return n;
}

/// Cosine similarity of two words by index.
pub fn similarity(m: *const Meaning, a: u32, b: u32) f32 {
    const va = m.vectors[@as(usize, a) * m.dims ..][0..m.dims];
    const vb = m.vectors[@as(usize, b) * m.dims ..][0..m.dims];
    const L = 32;
    var acc: @Vector(L, i32) = @splat(0);
    var d: usize = 0;
    while (d + L <= m.dims) : (d += L) {
        const x: @Vector(L, i32) = @as(@Vector(L, i8), va[d..][0..L].*);
        const y: @Vector(L, i32) = @as(@Vector(L, i8), vb[d..][0..L].*);
        acc += x * y;
    }
    var dot: i32 = @reduce(.Add, acc);
    while (d < m.dims) : (d += 1) dot += @as(i32, va[d]) * @as(i32, vb[d]);
    return @as(f32, @floatFromInt(dot)) / (127.0 * 127.0);
}

pub const Vec = [max_dims]f32;

/// Adds `w` times a word's vector to `acc`. Returns false for unknown words.
pub fn add(m: *const Meaning, acc: *Vec, hsh: u64, w: f32) bool {
    const i = m.index(hsh) orelse return false;
    const v = m.vectors[@as(usize, i) * m.dims ..][0..m.dims];
    for (v, 0..) |x, d| acc[d] += w * @as(f32, @floatFromInt(x));
    return true;
}

pub fn cosine(m: *const Meaning, a: *const Vec, b: *const Vec) f32 {
    var dot: f32 = 0;
    var na: f32 = 0;
    var nb: f32 = 0;
    for (0..m.dims) |d| {
        dot += a[d] * b[d];
        na += a[d] * a[d];
        nb += b[d] * b[d];
    }
    if (na == 0 or nb == 0) return 0;
    return dot / @sqrt(na * nb);
}

const testing = std.testing;

/// A tiny model for tests: three words, two of them close.
pub fn testModel(gpa: Allocator) !*Meaning {
    var b: std.ArrayList(u8) = .empty;
    defer b.deinit(gpa);
    try b.appendSlice(gpa, "HOLOWV1\x00");
    var hdr: [8]u8 = undefined;
    std.mem.writeInt(u32, hdr[0..4], 3, .little);
    std.mem.writeInt(u16, hdr[4..6], 2, .little);
    std.mem.writeInt(u16, hdr[6..8], 1, .little);
    try b.appendSlice(gpa, &hdr);
    for ([_][]const u8{ "outage", "downtime", "banana" }) |w| {
        try b.append(gpa, @intCast(w.len));
        try b.appendSlice(gpa, w);
    }
    const vecs = [_]i8{ 127, 0, 120, 30, 0, 127 };
    try b.appendSlice(gpa, @ptrCast(&vecs));
    const nb = [_]u8{ 1, 0, 240, 0, 0, 240, 0xff, 0xff, 0 };
    try b.appendSlice(gpa, &nb);
    return load(gpa, b.items);
}

test "related words and vectors" {
    const m = try testModel(testing.allocator);
    defer m.deinit(testing.allocator);
    var out: [4]Related = undefined;
    const n = m.related(text.hashTerm("outage"), 0.5, &out);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqual(text.hashTerm("downtime"), out[0].hash);
    var a: Vec = @splat(0);
    var c: Vec = @splat(0);
    try testing.expect(m.add(&a, text.hashTerm("outage"), 1));
    try testing.expect(m.add(&c, text.hashTerm("downtime"), 1));
    try testing.expect(m.cosine(&a, &c) > 0.9);
    try testing.expect(!m.add(&a, text.hashTerm("kiwi"), 1));
    const io = m.index(text.hashTerm("outage")).?;
    const id = m.index(text.hashTerm("downtime")).?;
    const ib = m.index(text.hashTerm("banana")).?;
    try testing.expect(m.similarity(io, id) > 0.9);
    try testing.expect(m.similarity(io, ib) < 0.1);
}
