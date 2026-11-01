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

fn isStop(w: []const u8) bool {
    if (w.len > 6) return false;
    for (stopwords) |s| if (std.mem.eql(u8, s, w)) return true;
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
    if (isStop(w)) return;
    sink.term(hashTerm(stem(w)));
}

/// Unique term hashes of one text, up to `cap`. Repeats are counted.
pub const TermSet = struct {
    pub const cap = 512;
    hashes: [cap]u64 = undefined,
    tf: [cap]u16 = undefined,
    len: usize = 0,
    total: usize = 0,

    pub fn term(s: *TermSet, h: u64) void {
        s.total += 1;
        for (s.hashes[0..s.len], 0..) |x, i| if (x == h) {
            s.tf[i] +|= 1;
            return;
        };
        if (s.len == cap) return;
        s.hashes[s.len] = h;
        s.tf[s.len] = 1;
        s.len += 1;
    }

    pub fn fill(s: *TermSet, text: []const u8) void {
        s.len = 0;
        s.total = 0;
        forEachTerm(text, s);
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
