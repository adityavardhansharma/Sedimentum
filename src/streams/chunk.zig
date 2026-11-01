//! The on-disk chunk: one sorted, immutable piece of a stream.
//!
//!   blocks | block index | first keys | footer
//!
//! Entries are sorted by key, newest version first. A key's versions never
//! straddle two blocks or two chunks, so "the last block whose first key is
//! <= k" is the only block that can hold k. Each block carries a hash that
//! is checked on every read. v3 front-codes keys and LZ4-compresses blocks;
//! a block that does not shrink by a tenth is stored raw.

const std = @import("std");
const Allocator = std.mem.Allocator;
const lz4 = @import("lz4.zig");

pub const Kind = enum(u8) { put = 1, del = 2, _ };

pub const Entry = struct {
    key: []const u8,
    value: []const u8 = &.{},
    seq: u64,
    kind: Kind = .put,
};

pub const Format = struct {
    block_bytes: usize,
    front_coding: bool,
    compress: bool,
};

const magic: u32 = 0x5344_4d43; // "SDMC"
const index_entry = 20;
const footer_len = 24;
const compressed_bit: u32 = 1 << 31;

pub fn keyHash(key: []const u8) u64 {
    return std.hash.Wyhash.hash(0x51ed, key);
}

fn blockHash(bytes: []const u8) u32 {
    return @truncate(std.hash.Wyhash.hash(0xb10c, bytes));
}

// ------------------------------------------------------------------ bloom

const bloom_probes = 7;

pub fn bloomWords(keys: usize) usize {
    return @max(1, (keys * 10 + 63) / 64);
}

fn probe(h: u64, i: u64, bits: u64) u64 {
    const x = (h +% i *% ((h >> 32) | 1)) *% 0x9E3779B97F4A7C15;
    return @truncate((@as(u128, x) * bits) >> 64);
}

pub fn bloomAdd(words: []u64, h: u64) void {
    const bits: u64 = words.len * 64;
    for (0..bloom_probes) |i| {
        const b = probe(h, i, bits);
        words[b >> 6] |= @as(u64, 1) << @intCast(b & 63);
    }
}

pub fn bloomHas(words: []const u64, h: u64) bool {
    const bits: u64 = words.len * 64;
    for (0..bloom_probes) |i| {
        const b = probe(h, i, bits);
        if (words[b >> 6] & (@as(u64, 1) << @intCast(b & 63)) == 0) return false;
    }
    return true;
}

// ---------------------------------------------------------------- varints

fn putVar(list: *std.ArrayList(u8), gpa: Allocator, v: u64) !void {
    var x = v;
    while (x >= 0x80) : (x >>= 7) try list.append(gpa, @as(u8, @truncate(x)) | 0x80);
    try list.append(gpa, @truncate(x));
}

fn getVar(b: []const u8, pos: *usize) error{Corrupt}!u64 {
    var x: u64 = 0;
    var shift: u6 = 0;
    while (true) {
        if (pos.* >= b.len) return error.Corrupt;
        const c = b[pos.*];
        pos.* += 1;
        x |= @as(u64, c & 0x7f) << shift;
        if (c < 0x80) return x;
        if (shift >= 63) return error.Corrupt;
        shift += 7;
    }
}

// ---------------------------------------------------------------- builder

/// Builds one chunk from entries given in (key asc, seq desc) order.
pub const Builder = struct {
    gpa: Allocator,
    fmt: Format,
    out: std.ArrayList(u8) = .empty,
    block: std.ArrayList(u8) = .empty,
    index: std.ArrayList(u8) = .empty,
    keys: std.ArrayList(u8) = .empty,
    prev: std.ArrayList(u8) = .empty,
    first: std.ArrayList(u8) = .empty,
    scratch: std.ArrayList(u8) = .empty,
    hashes: std.ArrayList(u64) = .empty,
    nblocks: u32 = 0,
    count: u32 = 0,
    min_seq: u64 = std.math.maxInt(u64),
    max_seq: u64 = 0,
    block_entries: u32 = 0,
    misses: u8 = 0,

    pub fn init(gpa: Allocator, fmt: Format) Builder {
        return .{ .gpa = gpa, .fmt = fmt };
    }

    pub fn deinit(b: *Builder) void {
        inline for (.{ &b.out, &b.block, &b.index, &b.keys, &b.prev, &b.first, &b.scratch }) |l| l.deinit(b.gpa);
        b.hashes.deinit(b.gpa);
    }

    pub fn reset(b: *Builder) void {
        inline for (.{ &b.out, &b.block, &b.index, &b.keys, &b.prev, &b.first }) |l| l.clearRetainingCapacity();
        b.hashes.clearRetainingCapacity();
        b.nblocks = 0;
        b.count = 0;
        b.min_seq = std.math.maxInt(u64);
        b.max_seq = 0;
        b.block_entries = 0;
        b.misses = 0;
    }

    pub fn isEmpty(b: *const Builder) bool {
        return b.count == 0;
    }

    /// Bytes added so far, before compression.
    pub fn size(b: *const Builder) usize {
        return b.out.items.len + b.block.items.len;
    }

    /// Whether `key` starts a new key (so a chunk may end before it).
    pub fn isNewKey(b: *const Builder, key: []const u8) bool {
        return b.count == 0 or !std.mem.eql(u8, key, b.prev.items);
    }

    pub fn lastKey(b: *const Builder) []const u8 {
        return b.prev.items;
    }

    pub fn firstKey(b: *const Builder) []const u8 {
        return b.first.items;
    }

    pub fn add(b: *Builder, e: Entry) !void {
        const new_key = b.isNewKey(e.key);
        if (new_key and b.block_entries > 0 and b.block.items.len >= b.fmt.block_bytes) try b.flushBlock();
        const gpa = b.gpa;
        if (b.block_entries == 0) {
            if (e.key.len > std.math.maxInt(u16)) return error.KeyTooLarge;
            var kl: [2]u8 = undefined;
            std.mem.writeInt(u16, &kl, @intCast(e.key.len), .little);
            std.mem.writeInt(u32, try b.index.addManyAsArray(gpa, 4), @intCast(b.keys.items.len), .little);
            try b.keys.appendSlice(gpa, &kl);
            try b.keys.appendSlice(gpa, e.key);
        }
        const shared: usize = if (b.fmt.front_coding and b.block_entries > 0)
            std.mem.indexOfDiff(u8, b.prev.items, e.key) orelse @min(b.prev.items.len, e.key.len)
        else
            0;
        try putVar(&b.block, gpa, shared);
        try putVar(&b.block, gpa, e.key.len - shared);
        try putVar(&b.block, gpa, e.value.len);
        std.mem.writeInt(u64, try b.block.addManyAsArray(gpa, 8), e.seq, .little);
        try b.block.append(gpa, @intFromEnum(e.kind));
        try b.block.appendSlice(gpa, e.key[shared..]);
        try b.block.appendSlice(gpa, e.value);
        if (b.count == 0) try b.first.appendSlice(gpa, e.key);
        if (new_key) try b.hashes.append(gpa, keyHash(e.key));
        b.prev.clearRetainingCapacity();
        try b.prev.appendSlice(gpa, e.key);
        b.count += 1;
        b.block_entries += 1;
        b.min_seq = @min(b.min_seq, e.seq);
        b.max_seq = @max(b.max_seq, e.seq);
    }

    fn flushBlock(b: *Builder) !void {
        const gpa = b.gpa;
        const raw = b.block.items;
        var stored = raw;
        var flag: u32 = 0;
        // Data that didn't shrink twice in a row (random bytes, already
        // compressed media) is not tried again until the next chunk.
        if (b.fmt.compress and raw.len > 64 and b.misses < 2) {
            try b.scratch.resize(gpa, lz4.bound(raw.len));
            const n = lz4.compress(raw, b.scratch.items);
            if (n < raw.len - raw.len / 10) {
                stored = b.scratch.items[0..n];
                flag = compressed_bit;
                b.misses = 0;
            } else b.misses += 1;
        }
        const off: u32 = @intCast(b.out.items.len);
        try b.out.appendSlice(gpa, stored);
        // The key offset was written when the block started; finish its entry.
        const key_off = b.index.items[b.index.items.len - 4 ..][0..4].*;
        b.index.shrinkRetainingCapacity(b.index.items.len - 4);
        const ent = try b.index.addManyAsArray(gpa, index_entry);
        std.mem.writeInt(u32, ent[0..4], off, .little);
        std.mem.writeInt(u32, ent[4..8], @as(u32, @intCast(stored.len)) | flag, .little);
        std.mem.writeInt(u32, ent[8..12], @intCast(raw.len), .little);
        std.mem.writeInt(u32, ent[12..16], blockHash(stored), .little);
        ent[16..20].* = key_off;
        b.block.clearRetainingCapacity();
        b.block_entries = 0;
        b.nblocks += 1;
    }

    /// Ends the chunk. Returns its bytes, valid until the next `reset`.
    pub fn finish(b: *Builder) ![]const u8 {
        std.debug.assert(b.count > 0);
        if (b.block_entries > 0) try b.flushBlock();
        const gpa = b.gpa;
        const index_off: u32 = @intCast(b.out.items.len);
        try b.out.appendSlice(gpa, b.index.items);
        const keys_off: u32 = @intCast(b.out.items.len);
        try b.out.appendSlice(gpa, b.keys.items);
        const meta_hash = blockHash(b.out.items[index_off..]);
        const f = try b.out.addManyAsArray(gpa, footer_len);
        std.mem.writeInt(u32, f[0..4], index_off, .little);
        std.mem.writeInt(u32, f[4..8], b.nblocks, .little);
        std.mem.writeInt(u32, f[8..12], b.count, .little);
        std.mem.writeInt(u32, f[12..16], keys_off, .little);
        std.mem.writeInt(u32, f[16..20], meta_hash, .little);
        std.mem.writeInt(u32, f[20..24], magic, .little);
        return b.out.items;
    }

    /// A bloom filter over every distinct key added. Caller owns it.
    pub fn bloom(b: *const Builder, gpa: Allocator) ![]u64 {
        const words = try gpa.alloc(u64, bloomWords(b.hashes.items.len));
        @memset(words, 0);
        for (b.hashes.items) |h| bloomAdd(words, h);
        return words;
    }
};

// ------------------------------------------------------------------ reader

/// A parsed chunk over its stored bytes (usually a slice of a mapping).
pub const View = struct {
    bytes: []const u8,
    nblocks: u32,
    count: u32,
    index: []const u8,
    keys: []const u8,

    pub fn open(bytes: []const u8) error{Corrupt}!View {
        if (bytes.len < footer_len) return error.Corrupt;
        const f = bytes[bytes.len - footer_len ..];
        if (std.mem.readInt(u32, f[20..24], .little) != magic) return error.Corrupt;
        const index_off = std.mem.readInt(u32, f[0..4], .little);
        const nblocks = std.mem.readInt(u32, f[4..8], .little);
        const keys_off = std.mem.readInt(u32, f[12..16], .little);
        const meta_end = bytes.len - footer_len;
        if (index_off > keys_off or keys_off > meta_end) return error.Corrupt;
        if (@as(u64, nblocks) * index_entry != keys_off - index_off or nblocks == 0) return error.Corrupt;
        return .{
            .bytes = bytes,
            .nblocks = nblocks,
            .count = std.mem.readInt(u32, f[8..12], .little),
            .index = bytes[index_off..keys_off],
            .keys = bytes[keys_off..meta_end],
        };
    }

    /// Checks the metadata hash and every block hash.
    pub fn verify(v: View) error{Corrupt}!void {
        const f = v.bytes[v.bytes.len - footer_len ..];
        const index_off = std.mem.readInt(u32, f[0..4], .little);
        if (blockHash(v.bytes[index_off .. v.bytes.len - footer_len]) != std.mem.readInt(u32, f[16..20], .little)) return error.Corrupt;
        for (0..v.nblocks) |i| _ = try v.stored(i);
    }

    pub fn firstKey(v: View, i: usize) error{Corrupt}![]const u8 {
        const off = std.mem.readInt(u32, v.index[i * index_entry + 16 ..][0..4], .little);
        if (off + 2 > v.keys.len) return error.Corrupt;
        const len = std.mem.readInt(u16, v.keys[off..][0..2], .little);
        if (off + 2 + len > v.keys.len) return error.Corrupt;
        return v.keys[off + 2 ..][0..len];
    }

    /// The last block whose first key is <= `key`, or null.
    pub fn findBlock(v: View, key: []const u8) error{Corrupt}!?usize {
        var lo: usize = 0;
        var hi: usize = v.nblocks;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            if (std.mem.order(u8, try v.firstKey(mid), key) == .gt) hi = mid else lo = mid + 1;
        }
        return if (lo == 0) null else lo - 1;
    }

    /// The last block whose first key is < `key`, or null.
    pub fn findBlockBefore(v: View, key: []const u8) error{Corrupt}!?usize {
        var lo: usize = 0;
        var hi: usize = v.nblocks;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            if (std.mem.order(u8, try v.firstKey(mid), key) != .lt) hi = mid else lo = mid + 1;
        }
        return if (lo == 0) null else lo - 1;
    }

    const Stored = struct { bytes: []const u8, raw_len: u32, compressed: bool };

    fn stored(v: View, i: usize) error{Corrupt}!Stored {
        const e = v.index[i * index_entry ..][0..index_entry];
        const off = std.mem.readInt(u32, e[0..4], .little);
        const len_flag = std.mem.readInt(u32, e[4..8], .little);
        const len = len_flag & ~compressed_bit;
        const index_start = v.bytes.len - footer_len - v.keys.len - v.index.len;
        if (@as(u64, off) + len > index_start) return error.Corrupt;
        const bytes = v.bytes[off..][0..len];
        if (blockHash(bytes) != std.mem.readInt(u32, e[12..16], .little)) return error.Corrupt;
        return .{ .bytes = bytes, .raw_len = std.mem.readInt(u32, e[8..12], .little), .compressed = len_flag & compressed_bit != 0 };
    }

    /// The raw bytes of block `i`: the stored bytes, or decompressed into
    /// `scratch`.
    pub fn block(v: View, i: usize, gpa: Allocator, scratch: *std.ArrayList(u8)) ![]const u8 {
        const s = try v.stored(i);
        if (!s.compressed) return s.bytes;
        try scratch.resize(gpa, s.raw_len);
        try lz4.decompress(s.bytes, scratch.items);
        return scratch.items;
    }
};

/// Walks the entries of one raw block in order.
pub const BlockIter = struct {
    raw: []const u8,
    pos: usize = 0,

    /// The next entry. Its key lives in `kb` and is valid until the next call.
    pub fn next(it: *BlockIter, gpa: Allocator, kb: *std.ArrayList(u8)) !?Entry {
        if (it.pos >= it.raw.len) return null;
        const r = it.raw;
        const shared = try getVar(r, &it.pos);
        const suffix = try getVar(r, &it.pos);
        const vlen = try getVar(r, &it.pos);
        if (it.pos + 9 > r.len) return error.Corrupt;
        const seq = std.mem.readInt(u64, r[it.pos..][0..8], .little);
        const kind: Kind = @enumFromInt(r[it.pos + 8]);
        it.pos += 9;
        if (shared > kb.items.len or suffix > r.len - it.pos or vlen > r.len - it.pos - suffix) return error.Corrupt;
        kb.shrinkRetainingCapacity(@intCast(shared));
        try kb.appendSlice(gpa, r[it.pos..][0..@intCast(suffix)]);
        it.pos += @intCast(suffix);
        const value = r[it.pos..][0..@intCast(vlen)];
        it.pos += @intCast(vlen);
        return .{ .key = kb.items, .value = value, .seq = seq, .kind = kind };
    }
};

/// One block decoded into entries with stable keys, for cursors.
pub const Parsed = struct {
    entries: std.ArrayList(Entry) = .empty,
    keys: std.ArrayList(u8) = .empty,
    scratch: std.ArrayList(u8) = .empty,
    kb: std.ArrayList(u8) = .empty,
    offs: std.ArrayList(u32) = .empty,

    pub fn deinit(p: *Parsed, gpa: Allocator) void {
        p.entries.deinit(gpa);
        p.keys.deinit(gpa);
        p.scratch.deinit(gpa);
        p.kb.deinit(gpa);
        p.offs.deinit(gpa);
    }

    pub fn load(p: *Parsed, gpa: Allocator, v: View, bi: usize) !void {
        p.entries.clearRetainingCapacity();
        p.keys.clearRetainingCapacity();
        p.offs.clearRetainingCapacity();
        p.kb.clearRetainingCapacity();
        const raw = try v.block(bi, gpa, &p.scratch);
        var it: BlockIter = .{ .raw = raw };
        while (try it.next(gpa, &p.kb)) |e| {
            try p.offs.append(gpa, @intCast(p.keys.items.len));
            try p.keys.appendSlice(gpa, e.key);
            try p.entries.append(gpa, e);
        }
        for (p.entries.items, 0..) |*e, i| {
            const end = if (i + 1 < p.offs.items.len) p.offs.items[i + 1] else p.keys.items.len;
            e.key = p.keys.items[p.offs.items[i]..end];
        }
    }
};

/// Finds the newest version of `key` with seq <= `at` in a chunk. The value
/// borrows the chunk bytes or `scratch`.
pub fn get(v: View, gpa: Allocator, key: []const u8, at: u64, scratch: *std.ArrayList(u8), kb: *std.ArrayList(u8)) !?Entry {
    const bi = (try v.findBlock(key)) orelse return null;
    var it: BlockIter = .{ .raw = try v.block(bi, gpa, scratch) };
    kb.clearRetainingCapacity();
    while (try it.next(gpa, kb)) |e| {
        switch (std.mem.order(u8, e.key, key)) {
            .lt => continue,
            .gt => return null,
            .eq => if (e.seq <= at) return e,
        }
    }
    return null;
}

// ------------------------------------------------------------------ tests

const testing = std.testing;

fn buildAndCheck(fmt: Format) !void {
    const gpa = testing.allocator;
    var b = Builder.init(gpa, fmt);
    defer b.deinit();
    var kbuf: [32]u8 = undefined;
    var vbuf: [64]u8 = undefined;
    const n = 2000;
    for (0..n) |i| {
        const k = try std.fmt.bufPrint(&kbuf, "chat/1/m{d:0>6}", .{i});
        const v = try std.fmt.bufPrint(&vbuf, "message number {d} about lunch plans", .{i});
        // Two versions of every tenth key, newest first.
        if (i % 10 == 0) try b.add(.{ .key = k, .value = "newer", .seq = 10_000 + i });
        try b.add(.{ .key = k, .value = v, .seq = i + 1, .kind = if (i % 7 == 3) .del else .put });
    }
    const bytes = try gpa.dupe(u8, try b.finish());
    defer gpa.free(bytes);
    const view = try View.open(bytes);
    try view.verify();
    try testing.expectEqual(@as(u32, n + n / 10), view.count);
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(gpa);
    var kb: std.ArrayList(u8) = .empty;
    defer kb.deinit(gpa);
    for (0..n) |i| {
        const k = try std.fmt.bufPrint(&kbuf, "chat/1/m{d:0>6}", .{i});
        const e = (try get(view, gpa, k, std.math.maxInt(u64), &scratch, &kb)).?;
        if (i % 10 == 0) {
            try testing.expectEqualStrings("newer", e.value);
            const old = (try get(view, gpa, k, 9_999, &scratch, &kb)).?;
            try testing.expectEqual(@as(u64, i + 1), old.seq);
        } else {
            try testing.expectEqual(@as(u64, i + 1), e.seq);
        }
    }
    try testing.expect((try get(view, gpa, "chat/1/m9", std.math.maxInt(u64), &scratch, &kb)) == null);
    try testing.expect((try get(view, gpa, "a", std.math.maxInt(u64), &scratch, &kb)) == null);
    // Every block parses, in order.
    var p: Parsed = .{};
    defer p.deinit(gpa);
    var total: usize = 0;
    var prev: std.ArrayList(u8) = .empty;
    defer prev.deinit(gpa);
    for (0..view.nblocks) |bi| {
        try p.load(gpa, view, bi);
        for (p.entries.items) |e| {
            try testing.expect(std.mem.order(u8, prev.items, e.key) != .gt);
            prev.clearRetainingCapacity();
            try prev.appendSlice(gpa, e.key);
        }
        total += p.entries.items.len;
    }
    try testing.expectEqual(@as(usize, view.count), total);
    // Bloom finds every key.
    const bloom = try b.bloom(gpa);
    defer gpa.free(bloom);
    for (0..n) |i| try testing.expect(bloomHas(bloom, keyHash(try std.fmt.bufPrint(&kbuf, "chat/1/m{d:0>6}", .{i}))));
    var false_pos: usize = 0;
    for (0..10_000) |i| {
        if (bloomHas(bloom, keyHash(try std.fmt.bufPrint(&kbuf, "nope/{d}", .{i})))) false_pos += 1;
    }
    try testing.expect(false_pos < 300);
    // Damage is caught.
    bytes[10] ^= 0xff;
    try testing.expectError(error.Corrupt, view.verify());
}

test "chunks round trip with and without compression" {
    try buildAndCheck(.{ .block_bytes = 4096, .front_coding = false, .compress = false });
    try buildAndCheck(.{ .block_bytes = 8192, .front_coding = true, .compress = true });
}
