//! A small LZ4 block codec (the raw block format, no frame). v3 uses it to
//! squeeze chunk blocks. Output is readable by any LZ4 block decoder.

const std = @import("std");

const min_match = 4;
/// The last five bytes of a block are always literals.
const last_literals = 5;
/// A match may not start in the last twelve bytes.
const mf_limit = 12;
const hash_log = 12;

/// The most bytes `compress` can write for `n` input bytes.
pub fn bound(n: usize) usize {
    return n + n / 255 + 16;
}

fn read32(b: []const u8, i: usize) u32 {
    return std.mem.readInt(u32, b[i..][0..4], .little);
}

fn hash(v: u32) usize {
    return @intCast((v *% 2654435761) >> (32 - hash_log));
}

fn writeLen(dst: []u8, op: *usize, n: usize) void {
    var rest = n;
    while (rest >= 255) : (rest -= 255) {
        dst[op.*] = 255;
        op.* += 1;
    }
    dst[op.*] = @intCast(rest);
    op.* += 1;
}

/// Compresses `src` into `dst` and returns the compressed length.
/// `dst` must hold at least `bound(src.len)` bytes.
pub fn compress(src: []const u8, dst: []u8) usize {
    std.debug.assert(dst.len >= bound(src.len));
    var table: [1 << hash_log]u32 = @splat(0);
    var ip: usize = 0;
    var anchor: usize = 0;
    var op: usize = 0;
    if (src.len > mf_limit) {
        const limit = src.len - mf_limit;
        const match_end = src.len - last_literals;
        while (ip < limit) {
            const seq = read32(src, ip);
            const h = hash(seq);
            const cand: usize = table[h];
            table[h] = @intCast(ip);
            if (cand < ip and ip - cand <= 65535 and read32(src, cand) == seq) {
                var s = ip;
                var c = cand;
                while (s > anchor and c > 0 and src[s - 1] == src[c - 1]) {
                    s -= 1;
                    c -= 1;
                }
                var len: usize = min_match;
                while (s + len < match_end and src[c + len] == src[s + len]) len += 1;
                emit(dst, &op, src[anchor..s], s - c, len);
                ip = s + len;
                anchor = ip;
                if (ip >= 2 and ip - 2 < limit) table[hash(read32(src, ip - 2))] = @intCast(ip - 2);
            } else {
                ip += 1 + ((ip - anchor) >> 6);
            }
        }
    }
    // Last literals.
    const lits = src[anchor..];
    const tok_lit: u8 = @intCast(@min(lits.len, 15));
    dst[op] = tok_lit << 4;
    op += 1;
    if (lits.len >= 15) writeLen(dst, &op, lits.len - 15);
    @memcpy(dst[op..][0..lits.len], lits);
    op += lits.len;
    return op;
}

fn emit(dst: []u8, op: *usize, lits: []const u8, offset: usize, len: usize) void {
    const ml = len - min_match;
    const tok_lit: u8 = @intCast(@min(lits.len, 15));
    const tok_ml: u8 = @intCast(@min(ml, 15));
    dst[op.*] = (tok_lit << 4) | tok_ml;
    op.* += 1;
    if (lits.len >= 15) writeLen(dst, op, lits.len - 15);
    @memcpy(dst[op.*..][0..lits.len], lits);
    op.* += lits.len;
    std.mem.writeInt(u16, dst[op.*..][0..2], @intCast(offset), .little);
    op.* += 2;
    if (ml >= 15) writeLen(dst, op, ml - 15);
}

/// Decompresses `src` into `dst`, which must be exactly the original size.
pub fn decompress(src: []const u8, dst: []u8) error{Corrupt}!void {
    var ip: usize = 0;
    var op: usize = 0;
    while (true) {
        if (ip >= src.len) return error.Corrupt;
        const tok = src[ip];
        ip += 1;
        var lit: usize = tok >> 4;
        if (lit == 15) lit += try readLen(src, &ip);
        if (ip + lit > src.len or op + lit > dst.len) return error.Corrupt;
        @memcpy(dst[op..][0..lit], src[ip..][0..lit]);
        ip += lit;
        op += lit;
        if (ip == src.len) break;
        if (ip + 2 > src.len) return error.Corrupt;
        const offset: usize = std.mem.readInt(u16, src[ip..][0..2], .little);
        ip += 2;
        if (offset == 0 or offset > op) return error.Corrupt;
        var ml: usize = tok & 15;
        if (ml == 15) ml += try readLen(src, &ip);
        ml += min_match;
        if (op + ml > dst.len) return error.Corrupt;
        var from = op - offset;
        if (offset >= ml) {
            @memcpy(dst[op..][0..ml], dst[from..][0..ml]);
            op += ml;
        } else {
            var i: usize = 0;
            while (i < ml) : (i += 1) {
                dst[op] = dst[from];
                op += 1;
                from += 1;
            }
        }
    }
    if (op != dst.len) return error.Corrupt;
}

fn readLen(src: []const u8, ip: *usize) error{Corrupt}!usize {
    var n: usize = 0;
    while (true) {
        if (ip.* >= src.len) return error.Corrupt;
        const b = src[ip.*];
        ip.* += 1;
        n += b;
        if (b != 255) return n;
    }
}

test "round trips text, runs, random bytes and edge sizes" {
    const gpa = std.testing.allocator;
    var inputs: std.ArrayList([]u8) = .empty;
    defer {
        for (inputs.items) |b| gpa.free(b);
        inputs.deinit(gpa);
    }
    try inputs.append(gpa, try gpa.dupe(u8, ""));
    try inputs.append(gpa, try gpa.dupe(u8, "a"));
    try inputs.append(gpa, try gpa.dupe(u8, "hello hello hello hello hello hello world"));
    const runs = try gpa.alloc(u8, 70000);
    @memset(runs, 'z');
    try inputs.append(gpa, runs);
    var prng = std.Random.DefaultPrng.init(7);
    const rnd = try gpa.alloc(u8, 20000);
    prng.random().bytes(rnd);
    try inputs.append(gpa, rnd);
    var text: std.ArrayList(u8) = .empty;
    for (0..500) |i| try text.print(gpa, "user said item {d} is due on day {d}; ", .{ i, i % 30 });
    try inputs.append(gpa, try text.toOwnedSlice(gpa));
    for (1..40) |n| {
        const b = try gpa.alloc(u8, n);
        for (b, 0..) |*c, i| c.* = @intCast(i % 3);
        try inputs.append(gpa, b);
    }
    for (inputs.items) |src| {
        const dst = try gpa.alloc(u8, bound(src.len));
        defer gpa.free(dst);
        const n = compress(src, dst);
        const back = try gpa.alloc(u8, src.len);
        defer gpa.free(back);
        try decompress(dst[0..n], back);
        try std.testing.expectEqualSlices(u8, src, back);
    }
    // Repetitive input actually shrinks.
    const dst = try gpa.alloc(u8, bound(runs.len));
    defer gpa.free(dst);
    try std.testing.expect(compress(runs, dst) < 1000);
}

test "rejects damaged input" {
    var out: [64]u8 = undefined;
    try std.testing.expectError(error.Corrupt, decompress(&.{0xF0}, &out));
    try std.testing.expectError(error.Corrupt, decompress(&.{ 0x11, 'a', 9, 0 }, &out));
}
