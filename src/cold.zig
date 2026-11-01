//! The cold index: a sorted, immutable file that maps keys to record
//! locations for data whose index no longer lives in memory.
//!
//! Layout:
//!
//!     blocks   each: crc u32 | body_len u32 | count u16 | entries
//!              entry: key_len u32 | seq u64 | segment u32 | offset u32 |
//!                     len u32 | expires u64 | key
//!     sparse   per block: offset u64 | first_key_len u32 | first_key
//!     bloom    k u32 | nbits u64 | bits
//!     stats    n u32 | n * (id, live, min_seq, ttl_live, max_expiry) u64
//!     footer   see `Footer`
//!
//! Only the sparse index (one key per block) and the bloom filter are
//! touched on open; blocks are read through a memory map as lookups need
//! them, so the file costs page cache, not heap. Each block carries a
//! CRC-32C that `verify` and merges check. Lookups bounds-check every field,
//! and the caller verifies the record it points to (key and checksum).

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Crc32c = std.hash.crc.@"CRC-32/ISCSI";

pub const file_name = "cold.idx";
const tmp_name = "cold.idx.tmp";
const magic = "SDMCOLD1";

/// Target size of a block. A block holding one huge key may be larger.
const block_target = 4096;
pub const max_block_entries = 255;
const block_header = 10;
const entry_fixed = 32;
const bloom_bits_per_key = 10;
const bloom_k = 7;

pub const Entry = struct {
    seq: u64,
    segment: u32,
    offset: u32,
    len: u32,
    expires: u64,
};

/// Per-segment bookkeeping saved with the file, as of the merge.
pub const SegStat = struct {
    id: u64,
    live: u64,
    min_seq: u64,
    ttl_live: u64,
    max_expiry: u64,
};

const Footer = struct {
    /// Segments with ids up to here are fully described by this file.
    covered_through: u64,
    last_seq: u64,
    entries: u64,
    blocks: u64,
    sparse_off: u64,
    bloom_off: u64,
    stats_off: u64,
    /// CRC-32C of everything from `sparse_off` to the end, this field
    /// excluded.
    meta_crc: u32,

    const len = magic.len + 7 * 8 + 8;

    fn encode(f: Footer, out: *[len]u8) void {
        @memcpy(out[0..magic.len], magic);
        var p: usize = magic.len;
        inline for (.{ f.covered_through, f.last_seq, f.entries, f.blocks, f.sparse_off, f.bloom_off, f.stats_off }) |v| {
            std.mem.writeInt(u64, out[p..][0..8], v, .little);
            p += 8;
        }
        std.mem.writeInt(u32, out[p..][0..4], f.meta_crc, .little);
        std.mem.writeInt(u32, out[p + 4 ..][0..4], 0, .little);
    }

    fn decode(b: *const [len]u8) !Footer {
        if (!std.mem.eql(u8, b[0..magic.len], magic)) return error.Corrupt;
        var vals: [7]u64 = undefined;
        for (&vals, 0..) |*v, i| v.* = std.mem.readInt(u64, b[magic.len + i * 8 ..][0..8], .little);
        return .{
            .covered_through = vals[0],
            .last_seq = vals[1],
            .entries = vals[2],
            .blocks = vals[3],
            .sparse_off = vals[4],
            .bloom_off = vals[5],
            .stats_off = vals[6],
            .meta_crc = std.mem.readInt(u32, b[magic.len + 56 ..][0..4], .little),
        };
    }
};

fn bloomHashes(key: []const u8) [2]u64 {
    const h = std.hash.Wyhash.hash(0x5ed1_3e47, key);
    // An odd step visits distinct bits for any power-of-two-free size.
    return .{ h, (h >> 32 | h << 32) | 1 };
}

// ------------------------------------------------------------------ writer

/// Builds a cold index file. Add keys in strictly increasing order, then
/// call `finish`, which syncs the file and moves it into place.
pub const Writer = struct {
    gpa: Allocator,
    io: Io,
    dir: Io.Dir,
    file: Io.File,
    /// Bytes waiting to be written at `flushed`.
    out: std.ArrayList(u8) = .empty,
    flushed: u64 = 0,
    block: std.ArrayList(u8) = .empty,
    block_count: u16 = 0,
    block_start: u64 = 0,
    sparse: std.ArrayList(u8) = .empty,
    blocks: u64 = 0,
    entries: u64 = 0,
    bloom: []u8,
    last_key: std.ArrayList(u8) = .empty,

    /// `expected` is an upper bound on the number of keys, used to size the
    /// bloom filter.
    pub fn init(gpa: Allocator, io: Io, dir: Io.Dir, expected: usize) !Writer {
        const nbits = @max(64, expected * bloom_bits_per_key);
        const bloom = try gpa.alloc(u8, (nbits + 7) / 8);
        errdefer gpa.free(bloom);
        @memset(bloom, 0);
        const file = try dir.createFile(io, tmp_name, .{ .read = true, .truncate = true });
        return .{ .gpa = gpa, .io = io, .dir = dir, .file = file, .bloom = bloom };
    }

    /// Abandons the file. Safe to call after `finish` too.
    pub fn deinit(w: *Writer) void {
        w.out.deinit(w.gpa);
        w.block.deinit(w.gpa);
        w.sparse.deinit(w.gpa);
        w.last_key.deinit(w.gpa);
        w.gpa.free(w.bloom);
        if (w.entries != std.math.maxInt(u64)) {
            w.file.close(w.io);
            w.dir.deleteFile(w.io, tmp_name) catch {};
        }
        w.* = undefined;
    }

    pub fn add(w: *Writer, key: []const u8, e: Entry) !void {
        std.debug.assert(key.len > 0);
        if (w.entries > 0) std.debug.assert(std.mem.order(u8, w.last_key.items, key) == .lt);
        if (w.block_count == max_block_entries or
            (w.block_count > 0 and w.block.items.len + entry_fixed + key.len > block_target))
        {
            try w.flushBlock();
        }
        if (w.block_count == 0) {
            try w.block.appendNTimes(w.gpa, 0, block_header);
            var head: [12]u8 = undefined;
            std.mem.writeInt(u64, head[0..8], w.flushed + w.out.items.len, .little);
            std.mem.writeInt(u32, head[8..12], @intCast(key.len), .little);
            try w.sparse.appendSlice(w.gpa, &head);
            try w.sparse.appendSlice(w.gpa, key);
        }
        var fixed: [entry_fixed]u8 = undefined;
        std.mem.writeInt(u32, fixed[0..4], @intCast(key.len), .little);
        std.mem.writeInt(u64, fixed[4..12], e.seq, .little);
        std.mem.writeInt(u32, fixed[12..16], e.segment, .little);
        std.mem.writeInt(u32, fixed[16..20], e.offset, .little);
        std.mem.writeInt(u32, fixed[20..24], e.len, .little);
        std.mem.writeInt(u64, fixed[24..32], e.expires, .little);
        try w.block.appendSlice(w.gpa, &fixed);
        try w.block.appendSlice(w.gpa, key);
        w.block_count += 1;
        w.entries += 1;

        const nbits: u64 = @as(u64, w.bloom.len) * 8;
        const h = bloomHashes(key);
        for (0..bloom_k) |i| {
            const bit = (h[0] +% i *% h[1]) % nbits;
            w.bloom[@intCast(bit / 8)] |= @as(u8, 1) << @intCast(bit % 8);
        }
        w.last_key.clearRetainingCapacity();
        try w.last_key.appendSlice(w.gpa, key);
    }

    fn flushBlock(w: *Writer) !void {
        if (w.block_count == 0) return;
        const b = w.block.items;
        std.mem.writeInt(u32, b[4..8], @intCast(b.len - block_header), .little);
        std.mem.writeInt(u16, b[8..10], w.block_count, .little);
        std.mem.writeInt(u32, b[0..4], Crc32c.hash(b[4..]), .little);
        try w.emit(b);
        w.block.clearRetainingCapacity();
        w.block_count = 0;
        w.blocks += 1;
    }

    fn emit(w: *Writer, bytes: []const u8) !void {
        try w.out.appendSlice(w.gpa, bytes);
        if (w.out.items.len >= 1 << 20) try w.drain();
    }

    fn drain(w: *Writer) !void {
        try w.file.writePositionalAll(w.io, w.out.items, w.flushed);
        w.flushed += w.out.items.len;
        w.out.clearRetainingCapacity();
    }

    /// Writes the metadata, syncs, and atomically replaces any previous
    /// cold index in the directory.
    pub fn finish(w: *Writer, covered_through: u64, last_seq: u64, stats: []const SegStat) !void {
        try w.flushBlock();
        const sparse_off = w.flushed + w.out.items.len;
        // Everything from here on is covered by the meta checksum.
        try w.drain();
        var crc = Crc32c.init();
        try w.emitMeta(&crc, w.sparse.items);
        const bloom_off = w.flushed + w.out.items.len;
        var head: [12]u8 = undefined;
        std.mem.writeInt(u32, head[0..4], bloom_k, .little);
        std.mem.writeInt(u64, head[4..12], @as(u64, w.bloom.len) * 8, .little);
        try w.emitMeta(&crc, &head);
        try w.emitMeta(&crc, w.bloom);
        const stats_off = w.flushed + w.out.items.len;
        var n: [4]u8 = undefined;
        std.mem.writeInt(u32, &n, @intCast(stats.len), .little);
        try w.emitMeta(&crc, &n);
        for (stats) |s| {
            var b: [40]u8 = undefined;
            inline for (.{ s.id, s.live, s.min_seq, s.ttl_live, s.max_expiry }, 0..) |v, i| {
                std.mem.writeInt(u64, b[i * 8 ..][0..8], v, .little);
            }
            try w.emitMeta(&crc, &b);
        }
        var footer: Footer = .{
            .covered_through = covered_through,
            .last_seq = last_seq,
            .entries = w.entries,
            .blocks = w.blocks,
            .sparse_off = sparse_off,
            .bloom_off = bloom_off,
            .stats_off = stats_off,
            .meta_crc = 0,
        };
        var fb: [Footer.len]u8 = undefined;
        footer.encode(&fb);
        crc.update(fb[0 .. Footer.len - 8]);
        footer.meta_crc = crc.final();
        footer.encode(&fb);
        try w.emit(&fb);
        try w.drain();
        try w.file.sync(w.io);
        w.file.close(w.io);
        w.entries = std.math.maxInt(u64);
        try w.dir.rename(tmp_name, w.dir, file_name, w.io);
        try syncDir(w.io, w.dir);
    }

    fn emitMeta(w: *Writer, crc: *Crc32c, bytes: []const u8) !void {
        crc.update(bytes);
        try w.emit(bytes);
    }
};

fn syncDir(io: Io, dir: Io.Dir) !void {
    if (builtin.os.tag == .windows) return;
    const handle = try dir.openFile(io, ".", .{});
    defer handle.close(io);
    try handle.sync(io);
}

/// Removes a half-written file left by a crash during a merge.
pub fn removeLeftovers(io: Io, dir: Io.Dir) void {
    dir.deleteFile(io, tmp_name) catch {};
}

// ------------------------------------------------------------------ reader

const page_align = std.heap.page_size_min;

pub const Reader = struct {
    gpa: Allocator,
    data: []align(page_align) const u8,
    mapped: bool,
    /// File offset of each block.
    block_offsets: []u64,
    /// First key of each block, borrowed from `data`.
    first_keys: [][]const u8,
    bloom: []const u8,
    bloom_bits: u64,
    bloom_hashes: u32,
    stats_raw: []const u8,
    covered_through: u64,
    last_seq: u64,
    entries: u64,

    /// Opens the cold index in `dir`, or returns null if there is none.
    pub fn open(gpa: Allocator, io: Io, dir: Io.Dir) !?Reader {
        const file = dir.openFile(io, file_name, .{}) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => |e| return e,
        };
        defer file.close(io);
        const len = try file.length(io);
        if (len < Footer.len or len > std.math.maxInt(usize)) return error.Corrupt;
        var mapped = true;
        const data: []align(page_align) const u8 = mapFile(file, len) orelse blk: {
            mapped = false;
            const buf = try gpa.alignedAlloc(u8, .fromByteUnits(page_align), @intCast(len));
            errdefer gpa.free(buf);
            if (try file.readPositionalAll(io, buf, 0) != len) return error.Corrupt;
            break :blk buf;
        };
        errdefer release(gpa, data, mapped);

        const f = try Footer.decode(data[data.len - Footer.len ..][0..Footer.len]);
        const meta_end = data.len - Footer.len;
        if (f.sparse_off > f.bloom_off or f.bloom_off > f.stats_off or f.stats_off > meta_end) return error.Corrupt;
        var crc = Crc32c.init();
        crc.update(data[@intCast(f.sparse_off)..meta_end]);
        crc.update(data[meta_end..][0 .. Footer.len - 8]);
        if (crc.final() != f.meta_crc) return error.Corrupt;
        if (f.blocks > (f.sparse_off / block_header) + 1) return error.Corrupt;

        const n: usize = @intCast(f.blocks);
        const offsets = try gpa.alloc(u64, n);
        errdefer gpa.free(offsets);
        const keys = try gpa.alloc([]const u8, n);
        errdefer gpa.free(keys);
        var p: usize = @intCast(f.sparse_off);
        const sparse_end: usize = @intCast(f.bloom_off);
        for (offsets, keys) |*o, *k| {
            if (sparse_end - p < 12) return error.Corrupt;
            o.* = std.mem.readInt(u64, data[p..][0..8], .little);
            const kl = std.mem.readInt(u32, data[p + 8 ..][0..4], .little);
            p += 12;
            if (sparse_end - p < kl or o.* >= f.sparse_off) return error.Corrupt;
            k.* = data[p..][0..kl];
            p += kl;
        }
        if (p != sparse_end) return error.Corrupt;

        var b: usize = @intCast(f.bloom_off);
        const stats_off: usize = @intCast(f.stats_off);
        if (stats_off - b < 12) return error.Corrupt;
        const k = std.mem.readInt(u32, data[b..][0..4], .little);
        const nbits = std.mem.readInt(u64, data[b + 4 ..][0..8], .little);
        b += 12;
        if (nbits == 0 or nbits % 8 != 0 or nbits / 8 != stats_off - b or k == 0 or k > 32) return error.Corrupt;

        const stats_raw = data[stats_off..meta_end];
        if (stats_raw.len < 4) return error.Corrupt;
        const ns = std.mem.readInt(u32, stats_raw[0..4], .little);
        if (stats_raw.len != 4 + @as(usize, ns) * 40) return error.Corrupt;

        return .{
            .gpa = gpa,
            .data = data,
            .mapped = mapped,
            .block_offsets = offsets,
            .first_keys = keys,
            .bloom = data[b..stats_off],
            .bloom_bits = nbits,
            .bloom_hashes = k,
            .stats_raw = stats_raw[4..],
            .covered_through = f.covered_through,
            .last_seq = f.last_seq,
            .entries = f.entries,
        };
    }

    pub fn close(r: *Reader) void {
        r.gpa.free(r.block_offsets);
        r.gpa.free(r.first_keys);
        release(r.gpa, r.data, r.mapped);
        r.* = undefined;
    }

    fn release(gpa: Allocator, data: []align(page_align) const u8, mapped: bool) void {
        if (mapped) std.posix.munmap(data) else gpa.free(data);
    }

    /// Heap bytes held, not counting the mapped file.
    pub fn heapBytes(r: *const Reader) usize {
        return r.block_offsets.len * (@sizeOf(u64) + @sizeOf([]const u8));
    }

    pub fn statCount(r: *const Reader) usize {
        return r.stats_raw.len / 40;
    }

    pub fn stat(r: *const Reader, i: usize) SegStat {
        const b = r.stats_raw[i * 40 ..][0..40];
        return .{
            .id = std.mem.readInt(u64, b[0..8], .little),
            .live = std.mem.readInt(u64, b[8..16], .little),
            .min_seq = std.mem.readInt(u64, b[16..24], .little),
            .ttl_live = std.mem.readInt(u64, b[24..32], .little),
            .max_expiry = std.mem.readInt(u64, b[32..40], .little),
        };
    }

    /// False means `key` is definitely not in the file.
    pub fn mayContain(r: *const Reader, key: []const u8) bool {
        const h = bloomHashes(key);
        for (0..r.bloom_hashes) |i| {
            const bit = (h[0] +% i *% h[1]) % r.bloom_bits;
            if (r.bloom[@intCast(bit / 8)] & (@as(u8, 1) << @intCast(bit % 8)) == 0) return false;
        }
        return true;
    }

    pub fn get(r: *const Reader, key: []const u8) !?Entry {
        if (!r.mayContain(key)) return null;
        const bi = r.blockFor(key) orelse return null;
        var blk = try r.loadBlock(bi);
        while (try blk.next()) |item| {
            switch (std.mem.order(u8, item.key, key)) {
                .lt => continue,
                .eq => return item.entry,
                .gt => return null,
            }
        }
        return null;
    }

    /// The last block whose first key is <= `key`.
    fn blockFor(r: *const Reader, key: []const u8) ?usize {
        var lo: usize = 0;
        var hi: usize = r.first_keys.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (std.mem.order(u8, r.first_keys[mid], key) == .gt) hi = mid else lo = mid + 1;
        }
        return if (lo == 0) null else lo - 1;
    }

    const Block = struct {
        body: []const u8,
        remaining: u16,
        pos: usize = 0,

        fn next(b: *Block) !?Item {
            if (b.remaining == 0) return null;
            if (b.body.len - b.pos < entry_fixed) return error.Corrupt;
            const f = b.body[b.pos..][0..entry_fixed];
            const kl = std.mem.readInt(u32, f[0..4], .little);
            if (kl == 0 or b.body.len - b.pos - entry_fixed < kl) return error.Corrupt;
            const item: Item = .{
                .key = b.body[b.pos + entry_fixed ..][0..kl],
                .entry = .{
                    .seq = std.mem.readInt(u64, f[4..12], .little),
                    .segment = std.mem.readInt(u32, f[12..16], .little),
                    .offset = std.mem.readInt(u32, f[16..20], .little),
                    .len = std.mem.readInt(u32, f[20..24], .little),
                    .expires = std.mem.readInt(u64, f[24..32], .little),
                },
            };
            b.pos += entry_fixed + kl;
            b.remaining -= 1;
            return item;
        }
    };

    pub const Item = struct { key: []const u8, entry: Entry };

    fn loadBlock(r: *const Reader, i: usize) !Block {
        const off: usize = @intCast(r.block_offsets[i]);
        const limit = r.data.len - Footer.len;
        if (limit - off < block_header) return error.Corrupt;
        const body_len = std.mem.readInt(u32, r.data[off + 4 ..][0..4], .little);
        const count = std.mem.readInt(u16, r.data[off + 8 ..][0..2], .little);
        if (limit - off - block_header < body_len or count == 0 or count > max_block_entries) return error.Corrupt;
        return .{ .body = r.data[off + block_header ..][0..body_len], .remaining = count };
    }

    /// Checks every block's checksum and that keys are strictly increasing.
    pub fn verify(r: *const Reader) !void {
        var it = r.first();
        var prev: []const u8 = "";
        var n: u64 = 0;
        for (r.block_offsets) |o| {
            const off: usize = @intCast(o);
            const limit = r.data.len - Footer.len;
            if (limit - off < block_header) return error.Corrupt;
            const body_len = std.mem.readInt(u32, r.data[off + 4 ..][0..4], .little);
            if (limit - off - block_header < body_len) return error.Corrupt;
            const crc = std.mem.readInt(u32, r.data[off..][0..4], .little);
            if (Crc32c.hash(r.data[off + 4 ..][0 .. block_header - 4 + body_len]) != crc) return error.Corrupt;
        }
        while (try it.current()) |item| : (try it.next()) {
            if (n > 0 and std.mem.order(u8, prev, item.key) != .lt) return error.Corrupt;
            prev = item.key;
            n += 1;
        }
        if (n != r.entries) return error.Corrupt;
    }

    // ------------------------------------------------------------ cursor

    /// A position in the file, walkable in both directions. Copyable.
    pub const Cursor = struct {
        r: *const Reader,
        /// Current block, or `blocks.len` when past the end.
        block: usize,
        /// Offsets of the current block's entries inside its body.
        offs: [max_block_entries]u32 = undefined,
        n: u16 = 0,
        /// Index into `offs`; `n` means past the end of the block.
        i: u16 = 0,
        body: []const u8 = "",
        is_valid: bool = false,

        fn enter(c: *Cursor, block: usize) !void {
            c.block = block;
            c.is_valid = false;
            if (block >= c.r.block_offsets.len) return;
            var b = try c.r.loadBlock(block);
            c.body = b.body;
            c.n = 0;
            while (true) {
                const pos = b.pos;
                if (try b.next() == null) break;
                c.offs[c.n] = @intCast(pos);
                c.n += 1;
            }
            c.i = 0;
            c.is_valid = c.n > 0;
        }

        pub fn valid(c: *const Cursor) bool {
            return c.is_valid;
        }

        /// The entry under the cursor, or null when not valid.
        pub fn current(c: *const Cursor) !?Item {
            if (!c.is_valid) return null;
            var b: Block = .{ .body = c.body, .remaining = 1, .pos = c.offs[c.i] };
            return try b.next();
        }

        pub fn next(c: *Cursor) !void {
            if (!c.is_valid) return;
            if (c.i + 1 < c.n) {
                c.i += 1;
                return;
            }
            try c.enter(c.block + 1);
        }

        pub fn prev(c: *Cursor) !void {
            if (!c.is_valid) return;
            if (c.i > 0) {
                c.i -= 1;
                return;
            }
            if (c.block == 0) {
                c.is_valid = false;
                return;
            }
            try c.enter(c.block - 1);
            if (c.is_valid) c.i = c.n - 1;
        }
    };

    pub fn first(r: *const Reader) Cursor {
        var c: Cursor = .{ .r = r, .block = 0 };
        c.enter(0) catch {};
        return c;
    }

    /// The first entry with a key >= `key`.
    pub fn seek(r: *const Reader, key: []const u8) !Cursor {
        var c: Cursor = .{ .r = r, .block = 0 };
        try c.enter(r.blockFor(key) orelse 0);
        while (try c.current()) |item| {
            if (std.mem.order(u8, item.key, key) != .lt) break;
            try c.next();
        }
        return c;
    }

    /// The last entry with a key < `key`.
    pub fn seekBefore(r: *const Reader, key: []const u8) !Cursor {
        var c = try r.seek(key);
        if (c.valid()) {
            try c.prev();
        } else {
            c = try r.last();
        }
        return c;
    }

    pub fn last(r: *const Reader) !Cursor {
        var c: Cursor = .{ .r = r, .block = 0 };
        if (r.block_offsets.len == 0) return c;
        try c.enter(r.block_offsets.len - 1);
        if (c.is_valid) c.i = c.n - 1;
        return c;
    }
};

fn mapFile(file: Io.File, len: u64) ?[]align(page_align) const u8 {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return null;
    return std.posix.mmap(null, @intCast(len), .{ .READ = true }, .{ .TYPE = .SHARED }, file.handle, 0) catch null;
}

// ------------------------------------------------------------------- tests

const testing = std.testing;

fn testEntry(i: u64) Entry {
    return .{ .seq = i + 1, .segment = @intCast(i % 7 + 1), .offset = @intCast(i * 10), .len = 30, .expires = 0 };
}

fn testKey(buf: []u8, i: usize) []const u8 {
    return std.fmt.bufPrint(buf, "agent/{d:0>3}/m{d:0>6}", .{ i % 13, i }) catch unreachable;
}

test "write, reopen, look up and walk both ways" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const n = 5000;
    // Sorted keys: zero-padded numbers sort like the numbers.
    var keys: std.ArrayList([]u8) = .empty;
    defer {
        for (keys.items) |k| testing.allocator.free(k);
        keys.deinit(testing.allocator);
    }
    for (0..n) |i| {
        var buf: [32]u8 = undefined;
        try keys.append(testing.allocator, try testing.allocator.dupe(u8, testKey(&buf, i)));
    }
    std.mem.sortUnstable([]u8, keys.items, {}, struct {
        fn lt(_: void, a: []u8, b: []u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
    {
        var w = try Writer.init(testing.allocator, io, tmp.dir, n);
        defer w.deinit();
        for (keys.items, 0..) |k, i| try w.add(k, testEntry(i));
        try w.finish(9, 12345, &.{.{ .id = 3, .live = 100, .min_seq = 4, .ttl_live = 0, .max_expiry = 0 }});
    }
    var r = (try Reader.open(testing.allocator, io, tmp.dir)).?;
    defer r.close();
    try r.verify();
    try testing.expectEqual(@as(u64, 9), r.covered_through);
    try testing.expectEqual(@as(u64, 12345), r.last_seq);
    try testing.expectEqual(@as(u64, n), r.entries);
    try testing.expectEqual(@as(usize, 1), r.statCount());
    try testing.expectEqual(@as(u64, 100), r.stat(0).live);
    for (keys.items, 0..) |k, i| {
        const e = (try r.get(k)).?;
        try testing.expectEqual(testEntry(i), e);
    }
    try testing.expect(try r.get("agent/") == null);
    try testing.expect(try r.get("zzz") == null);
    try testing.expect(try r.get("agent/000/m0000001") == null);

    var c = r.first();
    var i: usize = 0;
    while (try c.current()) |item| : (try c.next()) {
        try testing.expectEqualStrings(keys.items[i], item.key);
        i += 1;
    }
    try testing.expectEqual(@as(usize, n), i);
    c = try r.last();
    while (try c.current()) |item| : (try c.prev()) {
        i -= 1;
        try testing.expectEqualStrings(keys.items[i], item.key);
    }
    try testing.expectEqual(@as(usize, 0), i);

    c = try r.seek("agent/005/");
    try testing.expect(std.mem.startsWith(u8, (try c.current()).?.key, "agent/005/"));
    c = try r.seekBefore("agent/005/");
    try testing.expect(std.mem.startsWith(u8, (try c.current()).?.key, "agent/004/"));
    c = try r.seekBefore("a");
    try testing.expect(!c.valid());
    c = try r.seekBefore("zzz");
    try testing.expectEqualStrings(keys.items[n - 1], (try c.current()).?.key);
}

test "a damaged block fails verification and a damaged footer fails open" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        var w = try Writer.init(testing.allocator, io, tmp.dir, 10);
        defer w.deinit();
        try w.add("a", testEntry(0));
        try w.add("b", testEntry(1));
        try w.finish(1, 2, &.{});
    }
    const f = try tmp.dir.openFile(io, file_name, .{ .mode = .read_write });
    defer f.close(io);
    try f.writePositionalAll(io, "X", block_header + entry_fixed);
    {
        var r = (try Reader.open(testing.allocator, io, tmp.dir)).?;
        defer r.close();
        try testing.expectError(error.Corrupt, r.verify());
    }
    const len = try f.length(io);
    try f.writePositionalAll(io, "X", len - 20);
    try testing.expectError(error.Corrupt, Reader.open(testing.allocator, io, tmp.dir));
}

test "no file means no cold index" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try testing.expect(try Reader.open(testing.allocator, testing.io, tmp.dir) == null);
}
