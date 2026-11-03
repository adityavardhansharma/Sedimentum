//! Text coding: rANS (range asymmetric numeral systems) over a lane's own
//! words.
//!
//! A model holds up to `max_tokens` frequent words (each with or without
//! the space after it) plus all 256 byte values, with frequencies summing
//! to 2^16. A text is cut into symbols greedily (a known word, else its
//! bytes), and each symbol costs about log2(2^16 / freq) bits: a common
//! word costs a few bits, a never-seen name costs its letters. Every text
//! decodes on its own given its lane's model; models are written into the
//! lane once and never change, so any reader decodes exactly what the
//! writer encoded.

const std = @import("std");
const Allocator = std.mem.Allocator;
const words = @import("words.zig");

pub const scale_bits = 16;
const M: u32 = 1 << scale_bits;
const L: u32 = 1 << 23;
pub const max_tokens = 3840;
pub const max_token_len = words.max_word + 1;

/// Bytes `encode` may write for `n` bytes of text.
pub fn bound(n: usize) usize {
    return 2 * n + 16;
}

pub const Model = struct {
    nsym: u32,
    freq: []u32,
    cum: []u32,
    /// Symbol of every slot of the 2^16 range.
    slot: []u16,
    tok_off: []u32,
    tok_len: []u8,
    tok_bytes: []u8,
    /// Token lookup for the encoder: hash -> symbol + 1.
    enc: []u32,

    pub fn deinit(m: *Model, gpa: Allocator) void {
        gpa.free(m.freq);
        gpa.free(m.cum);
        gpa.free(m.slot);
        gpa.free(m.tok_off);
        gpa.free(m.tok_len);
        gpa.free(m.tok_bytes);
        gpa.free(m.enc);
        gpa.destroy(m);
    }

    pub fn token(m: *const Model, s: u32) []const u8 {
        const i = s - 256;
        return m.tok_bytes[m.tok_off[i]..][0..m.tok_len[i]];
    }

    fn hashOf(b: []const u8) u64 {
        return std.hash.Wyhash.hash(0xa115, b);
    }

    /// The symbol for a token, if the model has it.
    pub fn find(m: *const Model, b: []const u8) ?u32 {
        if (m.enc.len == 0) return null;
        const mask = m.enc.len - 1;
        var i: usize = @intCast(hashOf(b) & mask);
        while (true) : (i = (i + 1) & mask) {
            const e = m.enc[i];
            if (e == 0) return null;
            if (std.mem.eql(u8, m.token(e - 1), b)) return e - 1;
        }
    }

    /// Bytes the model takes in RAM.
    pub fn ramBytes(m: *const Model) usize {
        return m.freq.len * 8 + m.slot.len * 2 + m.tok_off.len * 5 + m.tok_bytes.len + m.enc.len * 4;
    }
};

/// Builds a model from token and byte counts. `toks` and `counts` pair up;
/// only the first `max_tokens` are used.
pub fn build(gpa: Allocator, toks: []const []const u8, counts: []const u64, byte_counts: *const [256]u64) !*Model {
    const ntok: usize = @min(toks.len, max_tokens);
    const nsym: usize = 256 + ntok;
    var raw = try gpa.alloc(u64, nsym);
    defer gpa.free(raw);
    for (0..256) |b| raw[b] = byte_counts[b] + 1;
    for (0..ntok) |i| raw[256 + i] = @max(counts[i], 1);
    var tok_bytes: usize = 0;
    for (toks[0..ntok]) |t| tok_bytes += t.len;

    const m = try gpa.create(Model);
    errdefer gpa.destroy(m);
    m.nsym = @intCast(nsym);
    m.freq = try gpa.alloc(u32, nsym);
    errdefer gpa.free(m.freq);
    m.cum = try gpa.alloc(u32, nsym);
    errdefer gpa.free(m.cum);
    m.slot = try gpa.alloc(u16, M);
    errdefer gpa.free(m.slot);
    m.tok_off = try gpa.alloc(u32, ntok);
    errdefer gpa.free(m.tok_off);
    m.tok_len = try gpa.alloc(u8, ntok);
    errdefer gpa.free(m.tok_len);
    m.tok_bytes = try gpa.alloc(u8, tok_bytes);
    errdefer gpa.free(m.tok_bytes);
    var cap: usize = 16;
    while (cap < ntok * 2) cap <<= 1;
    m.enc = try gpa.alloc(u32, if (ntok == 0) 0 else cap);
    errdefer gpa.free(m.enc);

    quantize(raw, m.freq);
    var o: u32 = 0;
    for (toks[0..ntok], 0..) |t, i| {
        m.tok_off[i] = o;
        m.tok_len[i] = @intCast(t.len);
        @memcpy(m.tok_bytes[o..][0..t.len], t);
        o += @intCast(t.len);
    }
    finish(m);
    return m;
}

/// Frequencies that sum to exactly 2^16, none below 1.
fn quantize(raw: []const u64, freq: []u32) void {
    var total: u64 = 0;
    for (raw) |r| total += r;
    var sum: i64 = 0;
    for (raw, freq) |r, *f| {
        f.* = @intCast(@max(1, (r * M) / total));
        sum += f.*;
    }
    var diff: i64 = @as(i64, M) - sum;
    // Too much: take from the largest, never below 1.
    while (diff < 0) {
        var best: usize = 0;
        for (freq, 0..) |f, i| if (f > freq[best]) {
            best = i;
        };
        const take: i64 = @min(-diff, @max(1, @divTrunc(@as(i64, freq[best]), 4)));
        freq[best] -= @intCast(take);
        diff += take;
    }
    if (diff > 0) {
        var best: usize = 0;
        for (freq, 0..) |f, i| if (f > freq[best]) {
            best = i;
        };
        freq[best] += @intCast(diff);
    }
}

fn finish(m: *Model) void {
    var c: u32 = 0;
    for (m.freq, m.cum, 0..) |f, *cu, s| {
        cu.* = c;
        @memset(m.slot[c..][0..f], @intCast(s));
        c += f;
    }
    std.debug.assert(c == M);
    @memset(m.enc, 0);
    if (m.enc.len == 0) return;
    const mask = m.enc.len - 1;
    for (0..m.tok_off.len) |i| {
        const s: u32 = @intCast(256 + i);
        var k: usize = @intCast(Model.hashOf(m.token(s)) & mask);
        while (m.enc[k] != 0) k = (k + 1) & mask;
        m.enc[k] = s + 1;
    }
}

/// The model as bytes: u16 token count, then per symbol a varint
/// frequency, then per token u8 length + bytes.
pub fn serialize(m: *const Model, gpa: Allocator, out: *std.ArrayList(u8)) !void {
    const ntok = m.nsym - 256;
    var b2: [2]u8 = undefined;
    std.mem.writeInt(u16, &b2, @intCast(ntok), .little);
    try out.appendSlice(gpa, &b2);
    for (m.freq) |f| try putVarint(gpa, out, f);
    for (0..ntok) |i| {
        const t = m.token(@intCast(256 + i));
        try out.append(gpa, @intCast(t.len));
        try out.appendSlice(gpa, t);
    }
}

pub fn parse(gpa: Allocator, bytes: []const u8) !*Model {
    if (bytes.len < 2) return error.Corrupt;
    const ntok: usize = std.mem.readInt(u16, bytes[0..2], .little);
    if (ntok > max_tokens) return error.Corrupt;
    const nsym = 256 + ntok;
    var p: usize = 2;
    const freq = try gpa.alloc(u32, nsym);
    defer gpa.free(freq);
    var sum: u64 = 0;
    for (freq) |*f| {
        f.* = @intCast(try getVarint(bytes, &p));
        if (f.* == 0) return error.Corrupt;
        sum += f.*;
    }
    if (sum != M) return error.Corrupt;
    var toks: [max_tokens][]const u8 = undefined;
    for (0..ntok) |i| {
        if (p >= bytes.len) return error.Corrupt;
        const l = bytes[p];
        p += 1;
        if (l == 0 or l > max_token_len or p + l > bytes.len) return error.Corrupt;
        toks[i] = bytes[p..][0..l];
        p += l;
    }
    const counts: [max_tokens]u64 = @splat(1);
    const bc: [256]u64 = @splat(0);
    const m = try build(gpa, toks[0..ntok], counts[0..ntok], &bc);
    @memcpy(m.freq, freq);
    finish(m);
    return m;
}

pub fn putVarint(gpa: Allocator, out: *std.ArrayList(u8), v0: u64) !void {
    var v = v0;
    while (v >= 0x80) : (v >>= 7) try out.append(gpa, @as(u8, @truncate(v)) | 0x80);
    try out.append(gpa, @intCast(v));
}

pub fn getVarint(b: []const u8, p: *usize) !u64 {
    var v: u64 = 0;
    var shift: u6 = 0;
    while (true) {
        if (p.* >= b.len) return error.Corrupt;
        const c = b[p.*];
        p.* += 1;
        v |= @as(u64, c & 0x7f) << shift;
        if (c < 0x80) return v;
        if (shift >= 56) return error.Corrupt;
        shift += 7;
    }
}

/// Cuts `text` into symbols: a known token where one starts, else bytes.
fn symbols(m: *const Model, text: []const u8, out: []u16) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        if (words.isWordByte(c) and (i == 0 or !words.isWordByte(text[i - 1]))) {
            var j = i + 1;
            while (j < text.len and words.isWordByte(text[j])) j += 1;
            if (j - i < max_token_len) {
                if (j < text.len and text[j] == ' ') {
                    if (m.find(text[i .. j + 1])) |s| {
                        out[n] = @intCast(s);
                        n += 1;
                        i = j + 1;
                        continue;
                    }
                }
                if (m.find(text[i..j])) |s| {
                    out[n] = @intCast(s);
                    n += 1;
                    i = j;
                    continue;
                }
            }
            for (text[i..j]) |b| {
                out[n] = b;
                n += 1;
            }
            i = j;
            continue;
        }
        out[n] = c;
        n += 1;
        i += 1;
    }
    return n;
}

/// Encodes `text` into `out` (at least `bound(text.len)` bytes, and
/// `scratch` at least `text.len` symbols). Returns the bytes written, at
/// the start of `out`.
pub fn encode(m: *const Model, text: []const u8, scratch: []u16, out: []u8) usize {
    const ns = symbols(m, text, scratch);
    var p: usize = out.len;
    var x: u32 = L;
    var k = ns;
    while (k > 0) {
        k -= 1;
        const s = scratch[k];
        const f = m.freq[s];
        const x_max = ((L >> scale_bits) << 8) * f;
        while (x >= x_max) {
            p -= 1;
            out[p] = @truncate(x);
            x >>= 8;
        }
        x = ((x / f) << scale_bits) + (x % f) + m.cum[s];
    }
    p -= 4;
    std.mem.writeInt(u32, out[p..][0..4], x, .little);
    const len = out.len - p;
    std.mem.copyForwards(u8, out[0..len], out[p..]);
    return len;
}

/// Decodes `raw_len` bytes into `out`.
pub fn decode(m: *const Model, enc: []const u8, out: []u8) !void {
    if (enc.len < 4) return error.Corrupt;
    var x: u32 = std.mem.readInt(u32, enc[0..4], .little);
    var p: usize = 4;
    var o: usize = 0;
    const mask = M - 1;
    while (o < out.len) {
        const sl = x & mask;
        const s: u32 = m.slot[sl];
        x = m.freq[s] * (x >> scale_bits) + sl - m.cum[s];
        while (x < L) {
            if (p >= enc.len) return error.Corrupt;
            x = (x << 8) | enc[p];
            p += 1;
        }
        if (s < 256) {
            out[o] = @intCast(s);
            o += 1;
        } else {
            const t = m.token(s);
            if (o + t.len > out.len) return error.Corrupt;
            @memcpy(out[o..][0..t.len], t);
            o += t.len;
        }
    }
}

/// Counts a writer's words, to build its next model from.
pub const Counter = struct {
    const max_distinct = 1 << 16;
    counts: std.StringHashMapUnmanaged(u64) = .empty,
    arena: std.heap.ArenaAllocator,
    bytes: [256]u64 = @splat(0),

    pub fn init(gpa: Allocator) Counter {
        return .{ .arena = .init(gpa) };
    }

    pub fn deinit(c: *Counter, gpa: Allocator) void {
        c.counts.deinit(gpa);
        c.arena.deinit();
    }

    pub fn reset(c: *Counter, gpa: Allocator) void {
        c.counts.clearAndFree(gpa);
        _ = c.arena.reset(.free_all);
        c.bytes = @splat(0);
    }

    fn see(c: *Counter, gpa: Allocator, tok: []const u8) !void {
        if (c.counts.getPtr(tok)) |n| {
            n.* += 1;
            return;
        }
        // First sighting: a word no model knows yet is coded as bytes.
        for (tok) |b| c.bytes[b] += 1;
        if (c.counts.count() >= max_distinct) return;
        const owned = try c.arena.allocator().dupe(u8, tok);
        try c.counts.put(gpa, owned, 1);
    }

    pub fn add(c: *Counter, gpa: Allocator, text: []const u8) !void {
        var i: usize = 0;
        while (i < text.len) {
            const ch = text[i];
            if (words.isWordByte(ch)) {
                var j = i + 1;
                while (j < text.len and words.isWordByte(text[j])) j += 1;
                if (j - i < max_token_len) {
                    const with_space = j < text.len and text[j] == ' ';
                    try c.see(gpa, text[i..if (with_space) j + 1 else j]);
                    i = if (with_space) j + 1 else j;
                } else {
                    for (text[i..j]) |b| c.bytes[b] += 1;
                    i = j;
                }
                continue;
            }
            c.bytes[ch] += 1;
            i += 1;
        }
    }

    /// A model from the counts: the tokens seen at least twice, most
    /// frequent first.
    pub fn model(c: *Counter, gpa: Allocator) !*Model {
        const E = struct { t: []const u8, n: u64 };
        var es: std.ArrayList(E) = .empty;
        defer es.deinit(gpa);
        var it = c.counts.iterator();
        while (it.next()) |e| if (e.value_ptr.* >= 2) try es.append(gpa, .{ .t = e.key_ptr.*, .n = e.value_ptr.* });
        std.mem.sortUnstable(E, es.items, {}, struct {
            fn gt(_: void, a: E, b: E) bool {
                // Bits saved: count times length.
                const sa = a.n * a.t.len;
                const sb = b.n * b.t.len;
                return sa > sb or (sa == sb and std.mem.lessThan(u8, a.t, b.t));
            }
        }.gt);
        const n = @min(es.items.len, max_tokens);
        const toks = try gpa.alloc([]const u8, n);
        defer gpa.free(toks);
        const counts = try gpa.alloc(u64, n);
        defer gpa.free(counts);
        for (es.items[0..n], toks, counts) |e, *t, *k| {
            t.* = e.t;
            k.* = e.n;
        }
        // Tokens left out are coded as bytes.
        var bc = c.bytes;
        for (es.items[n..]) |e| for (e.t) |b| {
            bc[b] += e.n - 1;
        };
        return build(gpa, toks, counts, &bc);
    }
};

const testing = std.testing;

test "rANS round-trips text through a learned model" {
    const gpa = testing.allocator;
    var c = Counter.init(gpa);
    defer c.deinit(gpa);
    const sample = "the user wants to deploy the service on friday because tests pass and billing is late ";
    for (0..50) |_| try c.add(gpa, sample);
    const m = try c.model(gpa);
    defer m.deinit(gpa);

    const texts = [_][]const u8{
        sample,
        "{\"role\":\"user\",\"t\":12345,\"text\":\"the user wants zorblat42 \"}",
        "",
        "x",
        "Ünïcödé bytes \x00\xff and the service",
    };
    for (texts) |t| {
        var scratch: [512]u16 = undefined;
        var enc: [2048]u8 = undefined;
        const n = encode(m, t, &scratch, &enc);
        var dec: [512]u8 = undefined;
        try decode(m, enc[0..n], dec[0..t.len]);
        try testing.expectEqualStrings(t, dec[0..t.len]);
    }
    // Known words cost a few bits each.
    var scratch: [512]u16 = undefined;
    var enc: [2048]u8 = undefined;
    const n = encode(m, sample, &scratch, &enc);
    try testing.expect(n * 4 < sample.len);

    // Serialized and parsed back, it decodes the same.
    var ser: std.ArrayList(u8) = .empty;
    defer ser.deinit(gpa);
    try serialize(m, gpa, &ser);
    const m2 = try parse(gpa, ser.items);
    defer m2.deinit(gpa);
    var dec: [512]u8 = undefined;
    try decode(m2, enc[0..n], dec[0..sample.len]);
    try testing.expectEqualStrings(sample, dec[0..sample.len]);
}

test "a corrupt stream is an error, never a crash" {
    const gpa = testing.allocator;
    var c = Counter.init(gpa);
    defer c.deinit(gpa);
    try c.add(gpa, "alpha beta alpha beta gamma ");
    const m = try c.model(gpa);
    defer m.deinit(gpa);
    var out: [64]u8 = undefined;
    try testing.expectError(error.Corrupt, decode(m, &[_]u8{ 1, 2, 3 }, &out));
    _ = decode(m, &[_]u8{ 0xff, 0xff, 0xff, 0x7f, 1 }, &out) catch {};
}
