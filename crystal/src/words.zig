//! Words as numbers.
//!
//! A word of up to 12 letters or digits is stored as its own base-37
//! number in a u64: exact, reversible, never colliding, and in the same
//! order as the words sort. Longer words (rare) are hashed into the upper
//! half of the u64 range, which packed words never reach. So a word is
//! compared, sorted and looked up as one integer everywhere in Crystal.
//!
//! Terms are lowercase, with a short stopword list and light suffix
//! stripping ("deploying", "deployed" -> "deploy"), the same stemming the
//! word-meaning table was built with.

const std = @import("std");

pub const max_word = 32;
/// Words this long or shorter pack exactly.
pub const max_packed = 12;
/// Hashed (too long to pack) words have this bit set.
pub const hashed_bit: u64 = 1 << 63;

/// 0 for separators, 1..10 for digits, 11..36 for letters (any case).
const code = blk: {
    var t: [256]u8 = @splat(0);
    for ('0'..'9' + 1, 1..) |c, i| t[c] = i;
    for ('a'..'z' + 1, 11..) |c, i| t[c] = i;
    for ('A'..'Z' + 1, 11..) |c, i| t[c] = i;
    break :blk t;
};

const lower = blk: {
    var t: [256]u8 = @splat(0);
    for ('a'..'z' + 1) |c| t[c] = c;
    for ('A'..'Z' + 1) |c| t[c] = c + 32;
    for ('0'..'9' + 1) |c| t[c] = c;
    break :blk t;
};

pub inline fn isWordByte(c: u8) bool {
    return code[c] != 0;
}

/// A lowercase word as a number. Never 0.
pub fn pack(w: []const u8) u64 {
    if (w.len > max_packed) return std.hash.Wyhash.hash(0xc4157a1, w) | hashed_bit;
    var v: u64 = 0;
    for (0..max_packed) |i| v = v * 37 + (if (i < w.len) code[w[i]] else 0);
    return v;
}

/// The word a packed number stands for (not for hashed words).
pub fn unpack(v: u64, buf: *[max_packed]u8) []const u8 {
    const alphabet = "?0123456789abcdefghijklmnopqrstuvwxyz";
    var x = v;
    var tmp: [max_packed]u8 = undefined;
    var i: usize = max_packed;
    while (i > 0) {
        i -= 1;
        tmp[i] = alphabet[@intCast(x % 37)];
        x /= 37;
    }
    var n: usize = 0;
    while (n < max_packed and tmp[n] != '?') : (n += 1) buf[n] = tmp[n];
    return buf[0..n];
}

const stopwords = [_][]const u8{
    "a",    "an",    "and",   "are",  "as",    "at",     "be",    "but",   "by",     "can",
    "did",  "do",    "does",  "for",  "from",  "had",    "has",   "have",  "he",     "her",
    "his",  "how",   "i",     "if",   "in",    "into",   "is",    "it",    "its",    "me",
    "my",   "no",    "not",   "of",   "on",    "or",     "our",   "she",   "so",     "that",
    "the",  "their", "them",  "then", "there", "these",  "they",  "this",  "to",     "too",
    "us",   "was",   "we",    "were", "what",  "when",   "where", "which", "who",    "why",
    "will", "with",  "would", "you",  "your",  "should", "could", "about", "please", "just",
};

/// Packed stopwords, sorted at compile time.
const stop_keys = blk: {
    @setEvalBranchQuota(200_000);
    var ks: [stopwords.len]u64 = undefined;
    for (stopwords, 0..) |w, i| ks[i] = pack(w);
    std.mem.sortUnstable(u64, &ks, {}, std.sort.asc(u64));
    break :blk ks;
};

pub fn isStop(key: u64) bool {
    var lo: usize = 0;
    var hi: usize = stop_keys.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        if (stop_keys[mid] == key) return true;
        if (stop_keys[mid] < key) lo = mid + 1 else hi = mid;
    }
    return false;
}

/// Words that say a fact changed. Stemmed and packed at compile time.
const cue_words = [_][]const u8{
    "now",      "changed",    "change",      "moved",      "move",      "migrated",   "migrate",   "switched",
    "switch",   "became",     "become",      "updated",    "update",    "replaced",   "replace",   "renamed",
    "raised",   "lowered",    "bumped",      "cut",        "increased", "reduced",    "decreased", "tightened",
    "loosened", "slipped",    "pushed",      "delayed",    "postponed", "ported",     "rewritten", "rewrote",
    "upgraded", "downgraded", "transferred", "shifted",    "swapped",   "reassigned", "revised",   "adjusted",
    "set",      "reset",      "converted",   "relocated",  "instead",   "anymore",    "longer",    "dropped",
    "extended", "shortened",  "retired",     "deprecated", "promoted",  "demoted",    "takes",     "took",
};

const cue_keys = blk: {
    @setEvalBranchQuota(400_000);
    var ks: [cue_words.len]u64 = undefined;
    for (cue_words, 0..) |w, i| {
        var b: [max_word]u8 = undefined;
        @memcpy(b[0..w.len], w);
        ks[i] = pack(stem(b[0..w.len]));
    }
    std.mem.sortUnstable(u64, &ks, {}, std.sort.asc(u64));
    break :blk ks;
};

pub fn isCue(key: u64) bool {
    var lo: usize = 0;
    var hi: usize = cue_keys.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        if (cue_keys[mid] == key) return true;
        if (cue_keys[mid] < key) lo = mid + 1 else hi = mid;
    }
    return false;
}

/// Strips common English endings in place.
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

/// One word of a text, as the indexer sees it.
pub const Word = struct {
    key: u64,
    /// Word number in the text (stopwords count).
    pos: u16,
    /// Sentence number in the text.
    sent: u16,
    /// All digits.
    number: bool,
};

/// Calls `sink.word(Word)` for every term of `text` (stopwords and
/// one-letter words are skipped but still advance `pos`).
pub fn forEach(text: []const u8, sink: anytype) void {
    var buf: [max_word]u8 = undefined;
    var n: usize = 0;
    var too_long = false;
    var digits = true;
    var pos: u16 = 0;
    var sent: u16 = 0;
    var i: usize = 0;
    while (i <= text.len) : (i += 1) {
        const c0: u8 = if (i < text.len) text[i] else ' ';
        const c = lower[c0];
        if (c != 0) {
            if (n < max_word) {
                buf[n] = c;
                n += 1;
            } else too_long = true;
            if (c > '9') digits = false;
            continue;
        }
        if (n > 0) {
            if (!too_long and n >= 2) {
                const raw = pack(buf[0..n]);
                if (!(n <= 6 and isStop(raw))) {
                    const st = stem(buf[0..n]);
                    sink.word(.{ .key = if (st.len == n) raw else pack(st), .pos = pos, .sent = sent, .number = digits });
                }
            }
            pos +|= 1;
            n = 0;
            too_long = false;
            digits = true;
        }
        switch (c0) {
            '.', '!', '?', ';', '\n' => sent +|= 1,
            else => {},
        }
    }
}

/// Unique terms of one text, first occurrence kept, in text order.
pub const Terms = struct {
    pub const cap = 512;
    const slots = 1024;
    words: [cap]Word = undefined,
    tf: [cap]u16 = undefined,
    len: usize = 0,
    total: usize = 0,
    table: [slots]u16 = @splat(0),

    pub fn word(s: *Terms, w: Word) void {
        s.total += 1;
        var i: usize = @intCast((w.key *% 0x9E3779B97F4A7C15) >> 54);
        while (true) : (i = (i + 1) & (slots - 1)) {
            const e = s.table[i];
            if (e == 0) break;
            if (s.words[e - 1].key == w.key) {
                s.tf[e - 1] +|= 1;
                return;
            }
        }
        if (s.len == cap) return;
        s.words[s.len] = w;
        s.tf[s.len] = 1;
        s.len += 1;
        s.table[i] = @intCast(s.len);
    }

    pub fn fill(s: *Terms, text: []const u8) void {
        @memset(&s.table, 0);
        s.len = 0;
        s.total = 0;
        forEach(text, s);
    }

    pub fn find(s: *const Terms, key: u64) ?usize {
        var i: usize = @intCast((key *% 0x9E3779B97F4A7C15) >> 54);
        while (true) : (i = (i + 1) & (slots - 1)) {
            const e = s.table[i];
            if (e == 0) return null;
            if (s.words[e - 1].key == key) return e - 1;
        }
    }

    pub fn items(s: *const Terms) []const Word {
        return s.words[0..s.len];
    }
};

const testing = std.testing;

test "packed words are exact, ordered and reversible" {
    try testing.expect(pack("a") != 0);
    try testing.expect(pack("abc") < pack("abd"));
    try testing.expect(pack("ab") < pack("abc"));
    try testing.expect(pack("zzzzzzzzzzzz") < hashed_bit);
    try testing.expect(pack("abcdefghijklm") & hashed_bit != 0);
    var b: [max_packed]u8 = undefined;
    try testing.expectEqualStrings("deploy42", unpack(pack("deploy42"), &b));
    try testing.expectEqual(pack("Deploy"), pack("deploy"));
}

test "terms skip stopwords, stem, and keep positions and sentences" {
    var t: Terms = .{};
    t.fill("We moved the Deploying to Friday. Deployed again!");
    const ws = t.items();
    try testing.expectEqual(@as(usize, 4), ws.len);
    try testing.expectEqual(pack("mov"), ws[0].key);
    try testing.expect(isCue(ws[0].key));
    try testing.expectEqual(pack("deploy"), ws[1].key);
    try testing.expectEqual(@as(u16, 3), ws[1].pos);
    try testing.expectEqual(pack("friday"), ws[2].key);
    try testing.expectEqual(@as(u16, 2), t.tf[1]);
    try testing.expectEqual(@as(u16, 1), ws[3].sent);
    try testing.expect(isStop(pack("the")));
    try testing.expect(!isStop(pack("region")));
}
