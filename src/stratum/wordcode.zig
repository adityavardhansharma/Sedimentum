//! A word code that each lane learns from its own memories. A word seen
//! before gets a code (one byte for the first 128 words, two bytes for the
//! next 16,384); a code stands for the word and the space after it.
//! Everything else is copied as literal runs. Each memory decodes on its
//! own: no blocks to unpack, nothing shared but the lane's word list.
//!
//! Ops:
//!   0x00..0x7F           word 0..127, then a space
//!   0x80..0xBF, b        word 128 + ((op & 0x3F) << 8 | b), then a space
//!   0xC0..0xFF, bytes    (op & 0x3F) + 1 literal bytes

const std = @import("std");
const Allocator = std.mem.Allocator;
const tables = @import("tables.zig");
const Vocab = tables.Vocab;

pub const max_word = 32;
/// Sightings sketch: two rows of byte counters.
pub const seen_bits = 15;
pub const seen_len = 2 << seen_bits;

/// Bytes `encode` may need for a text of `n` bytes.
pub fn bound(n: usize) usize {
    return n + n / 64 + 1;
}

fn isWordByte(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9');
}

fn seenSlots(word: []const u8) [2]usize {
    const h = std.hash.Wyhash.hash(0x5eed, word);
    const mask = (1 << seen_bits) - 1;
    return .{ h & mask, (1 << seen_bits) + ((h >> 32) & mask) };
}

/// Counts a sighting and says whether the word was seen before.
fn sighted(seen: []u8, word: []const u8) bool {
    const s = seenSlots(word);
    const before = @min(seen[s[0]], seen[s[1]]);
    for (s) |i| seen[i] +|= 1;
    return before > 0;
}

pub const Encoder = struct {
    gpa: Allocator,
    vocab: *Vocab,
    codes: *std.StringHashMapUnmanaged(u16),
    seen: []u8,
    /// Words that got a code during this call, to be written down first.
    new_words: std.ArrayList([]const u8) = .empty,

    pub fn deinit(e: *Encoder) void {
        e.new_words.deinit(e.gpa);
    }

    /// Encodes `text` into `out` (at least `bound(text.len)` bytes).
    /// Returns the bytes written.
    pub fn encode(e: *Encoder, text: []const u8, out: []u8) !usize {
        var o: usize = 0;
        var lit_start: usize = 0;
        var i: usize = 0;
        while (i < text.len) {
            if (!isWordByte(text[i]) or (i > 0 and isWordByte(text[i - 1]))) {
                i += 1;
                continue;
            }
            var j = i;
            while (j < text.len and isWordByte(text[j])) j += 1;
            const word = text[i..j];
            const coded = j < text.len and text[j] == ' ' and word.len >= 2 and word.len <= max_word;
            if (!coded) {
                i = j;
                continue;
            }
            const code = e.codes.get(word) orelse blk: {
                if (!sighted(e.seen, word) or e.vocab.len() >= Vocab.max) break :blk null;
                const c = try e.vocab.append(e.gpa, word);
                const stored = e.vocab.get(c).?;
                try e.codes.put(e.gpa, stored, c);
                try e.new_words.append(e.gpa, stored);
                break :blk c;
            };
            if (code) |c| {
                o = literal(out, o, text[lit_start..i]);
                if (c < 128) {
                    out[o] = @intCast(c);
                    o += 1;
                } else {
                    const x = c - 128;
                    out[o] = 0x80 | @as(u8, @intCast(x >> 8));
                    out[o + 1] = @truncate(x);
                    o += 2;
                }
                lit_start = j + 1;
                i = j + 1;
            } else i = j;
        }
        return literal(out, o, text[lit_start..]);
    }

    fn literal(out: []u8, start: usize, bytes: []const u8) usize {
        var o = start;
        var rest = bytes;
        while (rest.len > 0) {
            const n = @min(rest.len, 64);
            out[o] = 0xC0 | @as(u8, @intCast(n - 1));
            @memcpy(out[o + 1 ..][0..n], rest[0..n]);
            o += 1 + n;
            rest = rest[n..];
        }
        return o;
    }
};

/// Decodes into `out` (appending). error.Corrupt on a code the vocabulary
/// does not have or a run past the end.
pub fn decode(vocab: *const Vocab, enc: []const u8, gpa: Allocator, out: *std.ArrayList(u8)) !void {
    var i: usize = 0;
    while (i < enc.len) {
        const op = enc[i];
        if (op < 0xC0) {
            var code: usize = op;
            i += 1;
            if (op >= 0x80) {
                if (i >= enc.len) return error.Corrupt;
                code = 128 + ((@as(usize, op & 0x3F) << 8) | enc[i]);
                i += 1;
            }
            const word = vocab.get(code) orelse return error.Corrupt;
            try out.ensureUnusedCapacity(gpa, word.len + 1);
            out.appendSliceAssumeCapacity(word);
            out.appendAssumeCapacity(' ');
        } else {
            const n = @as(usize, op & 0x3F) + 1;
            if (i + 1 + n > enc.len) return error.Corrupt;
            try out.appendSlice(gpa, enc[i + 1 ..][0..n]);
            i += 1 + n;
        }
    }
}

test "round trip, words get codes on their second sighting" {
    const gpa = std.testing.allocator;
    var vocab: Vocab = .{};
    defer vocab.deinit(gpa);
    var codes: std.StringHashMapUnmanaged(u16) = .empty;
    defer codes.deinit(gpa);
    const seen = try gpa.alloc(u8, seen_len);
    defer gpa.free(seen);
    @memset(seen, 0);
    var e: Encoder = .{ .gpa = gpa, .vocab = &vocab, .codes = &codes, .seen = seen };
    defer e.deinit();
    const texts = [_][]const u8{
        "{\"role\":\"user\",\"text\":\"deploy the ledger on friday \"}",
        "deploy the ledger on friday please, Ledger X9 deploy",
        "deploy the ledger on friday please, Ledger X9 deploy",
        "",
        "a b  c\x00\xff end",
    };
    var buf: [256]u8 = undefined;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var last: usize = 0;
    for (texts) |t| {
        const n = try e.encode(t, &buf);
        try std.testing.expect(n <= bound(t.len));
        out.clearRetainingCapacity();
        try decode(&vocab, buf[0..n], gpa, &out);
        try std.testing.expectEqualStrings(t, out.items);
        last = n;
    }
    // The third text repeats the second and is coded.
    const n3 = try e.encode(texts[2], &buf);
    try std.testing.expect(n3 < texts[2].len);
    try std.testing.expect(vocab.len() > 0);
    // Zeros (an erased text) decode without crashing.
    const zeros: [8]u8 = @splat(0);
    out.clearRetainingCapacity();
    try decode(&vocab, &zeros, gpa, &out);
    const bad = [_]u8{0xBF};
    try std.testing.expectError(error.Corrupt, decode(&vocab, &bad, gpa, &out));
}
