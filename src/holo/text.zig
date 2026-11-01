//! Turning text into terms for Holo: lowercase words, a short stopword
//! list, light suffix stripping, and 64-bit term hashes.
//!
//! The same function runs on memories and on queries, so "deploying" in a
//! question finds "deployed" in a memory.

const std = @import("std");

pub const max_word = 32;

const stopwords = [_][]const u8{
    "a",    "an",    "and",   "are",  "as",    "at",     "be",    "but",   "by",     "can",
    "did",  "do",    "does",  "for",  "from",  "had",    "has",   "have",  "he",     "her",
    "his",  "how",   "i",     "if",   "in",    "into",   "is",    "it",    "its",    "me",
    "my",   "no",    "not",   "of",   "on",    "or",     "our",   "she",   "so",     "that",
    "the",  "their", "them",  "then", "there", "these",  "they",  "this",  "to",     "too",
    "us",   "was",   "we",    "were", "what",  "when",   "where", "which", "who",    "why",
    "will", "with",  "would", "you",  "your",  "should", "could", "about", "please", "just",
};

/// Stopword hashes, sorted, built at compile time: one binary search per word.
const stop_hashes = blk: {
    @setEvalBranchQuota(100_000);
    var hs: [stopwords.len]u64 = undefined;
    for (stopwords, 0..) |w, i| hs[i] = hashTerm(w);
    std.mem.sortUnstable(u64, &hs, {}, std.sort.asc(u64));
    break :blk hs;
};

fn isStop(h: u64) bool {
    var lo: usize = 0;
    var hi: usize = stop_hashes.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        if (stop_hashes[mid] == h) return true;
        if (stop_hashes[mid] < h) lo = mid + 1 else hi = mid;
    }
    return false;
}

/// Strips common English endings: "deploying" and "deployed" both become
/// "deploy", "policies" becomes "policy".
pub fn stem(buf: []u8) []u8 {
    var w = buf;
    if (w.len > 5 and std.mem.endsWith(u8, w, "ing")) {
        w = w[0 .. w.len - 3];
    } else if (w.len > 4 and std.mem.endsWith(u8, w, "ies")) {
        w = w[0 .. w.len - 2];
        w[w.len - 1] = 'y';
    } else if (w.len > 4 and std.mem.endsWith(u8, w, "ed")) {
        w = w[0 .. w.len - 2];
    } else if (w.len > 3 and w[w.len - 1] == 's' and w[w.len - 2] != 's' and w[w.len - 2] != 'u' and w[w.len - 2] != 'i') {
        w = w[0 .. w.len - 1];
    }
    return w;
}

pub fn hashTerm(w: []const u8) u64 {
    return std.hash.Wyhash.hash(0x7e57_a11c, w);
}

/// Walks the terms of a text, calling `sink.term(hash)` for each one.
pub fn forEachTerm(text: []const u8, sink: anytype) void {
    var buf: [max_word]u8 = undefined;
    var n: usize = 0;
    var too_long = false;
    for (text) |c0| {
        const c = std.ascii.toLower(c0);
        if (std.ascii.isAlphanumeric(c)) {
            if (n < max_word) {
                buf[n] = c;
                n += 1;
            } else too_long = true;
            continue;
        }
        emit(buf[0..n], too_long, sink);
        n = 0;
        too_long = false;
    }
    emit(buf[0..n], too_long, sink);
}

fn emit(w: []u8, too_long: bool, sink: anytype) void {
    if (too_long or w.len < 2) return;
    const raw = hashTerm(w);
    if (w.len <= 6 and isStop(raw)) return;
    const st = stem(w);
    sink.term(if (st.len == w.len) raw else hashTerm(st));
}

/// Unique term hashes of one text, up to `cap`. Repeats are counted.
pub const TermSet = struct {
    pub const cap = 512;
    const slots = 1024;
    hashes: [cap]u64 = undefined,
    tf: [cap]u16 = undefined,
    len: usize = 0,
    total: usize = 0,
    /// Open-addressing table: index + 1 into `hashes`, 0 for empty.
    table: [slots]u16 = @splat(0),

    pub fn term(s: *TermSet, h: u64) void {
        s.total += 1;
        var i: usize = @intCast(h & (slots - 1));
        while (true) : (i = (i + 1) & (slots - 1)) {
            const e = s.table[i];
            if (e == 0) break;
            if (s.hashes[e - 1] == h) {
                s.tf[e - 1] +|= 1;
                return;
            }
        }
        if (s.len == cap) return;
        s.hashes[s.len] = h;
        s.tf[s.len] = 1;
        s.len += 1;
        s.table[i] = @intCast(s.len);
    }

    pub fn fill(s: *TermSet, t: []const u8) void {
        @memset(&s.table, 0);
        s.len = 0;
        s.total = 0;
        forEachTerm(t, s);
    }
};

/// The 16-bit tag a row stores for a term. Never 0, which marks an empty slot.
pub fn tag(h: u64) u16 {
    const t: u16 = @truncate(h >> 48);
    return if (t == 0) 1 else t;
}

/// Bit of a page fingerprint that a term sets.
pub fn bloomBit(h: u64) u12 {
    return @truncate(h);
}

const testing = std.testing;

test "terms ignore case, stopwords and simple endings" {
    var a: TermSet = .{};
    a.fill("We DEPLOYED the billing-service on Fridays");
    var b: TermSet = .{};
    b.fill("deploying billing services friday");
    try testing.expectEqual(@as(usize, 4), a.len);
    try testing.expectEqual(@as(usize, 4), b.len);
    for (a.hashes[0..a.len]) |h| {
        var found = false;
        for (b.hashes[0..b.len]) |x| found = found or x == h;
        try testing.expect(found);
    }
}

test "repeated terms are counted once with a frequency" {
    var a: TermSet = .{};
    a.fill("auth auth auth token");
    try testing.expectEqual(@as(usize, 2), a.len);
    try testing.expectEqual(@as(u16, 3), a.tf[0]);
    try testing.expectEqual(@as(usize, 4), a.total);
}
