//! Holo: agent memory that answers "what do I need to know right now?"
//!
//! Agents don't want records, they want the right few thousand tokens in
//! their context window. Holo stores memories (text in a scope such as
//! `ledger/chat/42`, with an optional subject such as `auth-decision`) and
//! answers three questions fast:
//!
//!   recent(scope, n)            what just happened here
//!   recall(about, scope, ...)   what do we know about this, ranked
//!   brief(situation, budget)    a packed briefing that fits a token budget
//!
//! How it works:
//!
//!   * Fingerprints. Each memory keeps up to 32 of its rarest terms as
//!     16-bit tags in a 96-byte row on disk. Every 128 rows form a page,
//!     and the page's fingerprint (4096 bits, all its terms added together)
//!     is the only per-memory structure in RAM: about 4 bytes per memory.
//!     A query checks a page fingerprint with a few bit tests and only
//!     opens pages that could score high enough to matter.
//!   * Sedimentation. A newer memory with the same subject buries the old
//!     one; a near-copy of a recent memory in the same scope does too.
//!     Buried memories are kept (recall `deep` finds them) but drop out of
//!     normal answers. `settle` adds a summary and sinks what it covers.
//!     Pages that get recalled heat up and rank a little higher.
//!   * Storage. Memory text lives in a v3 stream store (compressed blocks,
//!     group commit, crash safe). Rows, page fingerprints and the rest are
//!     derived data: checkpointed, and rebuilt from the store after a crash.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Crc32c = std.hash.crc.@"CRC-32/ISCSI";
const streams = @import("../streams/Store.zig");
const record = @import("../record.zig");
const text = @import("text.zig");
pub const Meaning = @import("Meaning.zig");

const Holo = @This();

pub const Kv = streams.V3;

pub const page_rows = 128;
pub const max_terms = 32;
const bloom_words = 64; // 4096 bits
/// Terms per memory that go into its page fingerprint.
const none: u32 = std.math.maxInt(u32);
const map_reserve: usize = 1 << 38;
const page_align = std.heap.page_size_min;
/// Checkpoint after this many new rows.
const checkpoint_every: u32 = 1 << 18;
/// Count-min sketch: 2 rows of 256k counters, 2 MB. Two rows halve the
/// cache misses per word; conservative update keeps them accurate.
const cms_bits = 18;
const cms_rows = 2;

/// One memory's searchable summary. Fixed size, stored by id.
pub const Row = extern struct {
    terms: [max_terms]u16,
    time: u64,
    subj: u32,
    scope: u32,
    prev: u32,
    len: u32,
    sim: u32,
    nterms: u16,
    kind: u16,

    comptime {
        std.debug.assert(@sizeOf(Row) == 96);
    }
};

const Page = extern struct {
    bloom: [bloom_words]u64,
    tmax: u64,
    /// One bit per scope id modulo 64.
    smask: u64,
};

pub const Options = struct {
    /// Every write is durable before it returns. Off: call `sync`.
    sync_writes: bool = true,
    /// How fast recency fades in ranking. It breaks ties between equally
    /// good matches (newest version wins); old memories keep 85% of their score.
    half_life_ms: u64 = 7 * 24 * 3600 * 1000,
    shards: ?usize = null,
    /// Word meanings (see `Meaning`). With it, recall also finds memories
    /// that say the same thing in other words. Owned by the caller.
    meaning: ?*const Meaning = null,
};

pub const RememberOptions = struct {
    /// A newer memory with the same subject in the same scope replaces this one.
    subject: ?[]const u8 = null,
    /// Milliseconds since the epoch. Null: now.
    time: ?u64 = null,
};

pub const Memory = struct {
    id: u32,
    time: u64,
    scope: []const u8,
    subject: []const u8,
    text: []const u8,
    /// The whole stored value; `scope`, `subject` and `text` point into it.
    raw: []u8,

    pub fn deinit(m: Memory, gpa: Allocator) void {
        gpa.free(m.raw);
    }
};

pub const Hit = struct {
    memory: Memory,
    score: f32,
    /// Replaced or settled (only with `deep`), or an older copy of a newer
    /// hit that matched the question the same way.
    buried: bool,
    /// Which query terms it matched (bit per term, rarest first).
    matched: u8 = 0,
    /// With meaning: the memory's words that best answer the question
    /// (meaning-table index + 1; 0 for none).
    topics: Topics = @splat(0),
};

pub const Topics = [4]u32;

pub fn freeMemories(gpa: Allocator, ms: []const Memory) void {
    for (ms) |m| m.deinit(gpa);
    gpa.free(ms);
}

pub fn freeHits(gpa: Allocator, hs: []const Hit) void {
    for (hs) |h| h.memory.deinit(gpa);
    gpa.free(hs);
}

pub const Query = struct {
    /// What to look for. Empty: newest first.
    about: []const u8 = "",
    /// Only memories in this scope or below it ("ledger" covers "ledger/chat/42").
    scope: []const u8 = "",
    /// Only memories at or after this time (ms).
    since: u64 = 0,
    limit: usize = 10,
    /// Include buried (replaced or settled) memories.
    deep: bool = false,
    /// Use word meanings, when the store has them: related words count
    /// as partial matches and the closest in meaning ranks first.
    expand: bool = true,
};

pub const Brief = struct {
    text: []u8,
    tokens: usize,
    items: usize,
    buried_skipped: usize,

    pub fn deinit(b: Brief, gpa: Allocator) void {
        gpa.free(b.text);
    }
};

const Bits = struct {
    words: std.ArrayList(u64) = .empty,

    fn ensure(b: *Bits, gpa: Allocator, n: usize) !void {
        const need = (n + 63) / 64;
        while (b.words.items.len < need) try b.words.append(gpa, 0);
    }
    fn set(b: *Bits, i: usize) void {
        b.words.items[i / 64] |= @as(u64, 1) << @intCast(i % 64);
    }
    fn get(b: *const Bits, i: usize) bool {
        if (i / 64 >= b.words.items.len) return false;
        return b.words.items[i / 64] & (@as(u64, 1) << @intCast(i % 64)) != 0;
    }
};

gpa: Allocator,
io: Io,
dir: Io.Dir,
lock_file: Io.File,
kv: *Kv,
options: Options,
clock_override: ?u64 = null,

lock: Io.RwLock = .init,

rows_file: Io.File,
rows_map: []align(page_align) const u8,
pages_file: Io.File,

count: u32 = 0,
/// Rows below this id are in `rows_file`; the rest are in `cur`.
sealed: u32 = 0,
cur: [page_rows]Row = undefined,
pages: std.ArrayList(Page) = .empty,
heat: std.ArrayList(u32) = .empty,
pages_on_disk: u32 = 0,

/// Count-min sketch of how many memories hold each term (4 x 64k).
cms: []u32,
total_terms: u64 = 0,

scope_names: std.ArrayList(u8) = .empty,
scope_offs: std.ArrayList(u32) = .empty,
scope_map: std.AutoHashMapUnmanaged(u64, u32) = .empty,
heads: std.ArrayList(u32) = .empty,
scope_counts: std.ArrayList(u32) = .empty,
/// hash(scope id, subject) -> newest id with that subject.
subjects: std.AutoHashMapUnmanaged(u64, u32) = .empty,

buried: Bits = .{},
forgotten: Bits = .{},

ops_seq: u64 = 0,
ckpt_count: u32 = 0,
batch_unsynced: std.atomic.Value(bool) = .init(false),
/// Rows added whose text is not in the store yet. A checkpoint waits for
/// zero, so it never saves a row without its text.
inflight: std.atomic.Value(u32) = .init(0),

// ------------------------------------------------------------------ open

pub fn open(gpa: Allocator, io: Io, parent: Io.Dir, sub_path: []const u8, options: Options) !*Holo {
    var dir = try parent.createDirPathOpen(io, sub_path, .{ .open_options = .{ .iterate = true } });
    errdefer dir.close(io);
    const lock_file = dir.createFile(io, "HOLO.LOCK", .{ .truncate = false, .lock = .exclusive, .lock_nonblocking = true }) catch |err| switch (err) {
        error.WouldBlock => return error.Locked,
        else => |e| return e,
    };
    errdefer lock_file.close(io);
    const kv = try Kv.open(gpa, io, dir, "kv", .{ .sync_writes = false, .shards = options.shards });
    errdefer kv.close();
    const rows_file = try dir.createFile(io, "ROWS", .{ .read = true, .truncate = false });
    errdefer rows_file.close(io);
    const pages_file = try dir.createFile(io, "PAGES", .{ .read = true, .truncate = false });
    errdefer pages_file.close(io);
    const rows_map = try std.posix.mmap(null, map_reserve, .{ .READ = true }, .{ .TYPE = .SHARED }, rows_file.handle, 0);
    errdefer std.posix.munmap(rows_map);
    const cms = try gpa.alloc(u32, cms_rows << cms_bits);
    @memset(cms, 0);
    errdefer gpa.free(cms);

    const h = try gpa.create(Holo);
    errdefer gpa.destroy(h);
    h.* = .{
        .gpa = gpa,
        .io = io,
        .dir = dir,
        .lock_file = lock_file,
        .kv = kv,
        .options = options,
        .rows_file = rows_file,
        .rows_map = rows_map,
        .pages_file = pages_file,
        .cms = cms,
    };
    errdefer h.freeState();
    try h.loadCheckpoint();
    const replayed = try h.replay();
    if (replayed) try h.checkpoint();
    return h;
}

fn freeState(h: *Holo) void {
    const gpa = h.gpa;
    h.pages.deinit(gpa);
    h.heat.deinit(gpa);
    h.scope_names.deinit(gpa);
    h.scope_offs.deinit(gpa);
    h.scope_map.deinit(gpa);
    h.heads.deinit(gpa);
    h.scope_counts.deinit(gpa);
    h.subjects.deinit(gpa);
    h.buried.words.deinit(gpa);
    h.forgotten.words.deinit(gpa);
}

pub fn close(h: *Holo) void {
    h.checkpoint() catch {};
    const gpa = h.gpa;
    h.freeState();
    gpa.free(h.cms);
    std.posix.munmap(h.rows_map);
    h.rows_file.close(h.io);
    h.pages_file.close(h.io);
    h.kv.close();
    h.lock_file.close(h.io);
    h.dir.close(h.io);
    gpa.destroy(h);
}

pub fn setClockForTest(h: *Holo, ms: ?u64) void {
    h.clock_override = ms;
}

fn nowMs(h: *const Holo) u64 {
    if (h.clock_override) |t| return t;
    const ns = Io.Clock.real.now(h.io).nanoseconds;
    return @intCast(@divTrunc(ns, std.time.ns_per_ms));
}

// ---------------------------------------------------------------- scopes

fn scopeHash(name: []const u8) u64 {
    return std.hash.Wyhash.hash(0x5c09e, name);
}

pub fn scopeName(h: *const Holo, id: u32) []const u8 {
    const start = h.scope_offs.items[id];
    const end: u32 = if (id + 1 < h.scope_offs.items.len) h.scope_offs.items[id + 1] else @intCast(h.scope_names.items.len);
    return h.scope_names.items[start..end];
}

fn findScope(h: *const Holo, name: []const u8) ?u32 {
    var k = scopeHash(name);
    while (h.scope_map.get(k)) |id| : (k +%= 1) {
        if (std.mem.eql(u8, h.scopeName(id), name)) return id;
    }
    return null;
}

fn intern(h: *Holo, name: []const u8) !u32 {
    if (h.findScope(name)) |id| return id;
    const gpa = h.gpa;
    const id: u32 = @intCast(h.scope_offs.items.len);
    var k = scopeHash(name);
    while (h.scope_map.contains(k)) k +%= 1;
    try h.scope_map.put(gpa, k, id);
    try h.scope_offs.append(gpa, @intCast(h.scope_names.items.len));
    try h.scope_names.appendSlice(gpa, name);
    try h.heads.append(gpa, none);
    try h.scope_counts.append(gpa, 0);
    return id;
}

fn inScope(name: []const u8, filter: []const u8) bool {
    if (filter.len == 0) return true;
    if (!std.mem.startsWith(u8, name, filter)) return false;
    return name.len == filter.len or filter[filter.len - 1] == '/' or name[filter.len] == '/';
}

/// Scope ids matching a filter, as a bitset plus a 64-bit page mask.
const ScopeSet = struct {
    all: bool,
    bits: Bits = .{},
    mask: u64 = 0,
    n: usize = 0,
    single: u32 = none,

    fn has(s: *const ScopeSet, id: u32) bool {
        return s.all or s.bits.get(id);
    }
    fn deinit(s: *ScopeSet, gpa: Allocator) void {
        s.bits.words.deinit(gpa);
    }
};

fn scopeSet(h: *const Holo, gpa: Allocator, filter: []const u8) !ScopeSet {
    if (filter.len == 0) return .{ .all = true, .mask = std.math.maxInt(u64) };
    var s: ScopeSet = .{ .all = false };
    errdefer s.deinit(gpa);
    try s.bits.ensure(gpa, h.scope_offs.items.len);
    // Exact match first: the common case is one chat.
    if (h.findScope(filter)) |id| {
        s.bits.set(id);
        s.mask |= @as(u64, 1) << @intCast(id % 64);
        s.n = 1;
        s.single = id;
    }
    const nscopes = h.scope_offs.items.len;
    for (0..nscopes) |i| {
        const id: u32 = @intCast(i);
        if (id == s.single) continue;
        const name = h.scopeName(id);
        if (name.len <= filter.len or !inScope(name, filter)) continue;
        s.bits.set(id);
        s.mask |= @as(u64, 1) << @intCast(id % 64);
        s.n += 1;
        s.single = none;
    }
    if (s.n > 1) s.single = none;
    return s;
}

// ------------------------------------------------------------------ rows

pub fn row(h: *const Holo, id: u32) *const Row {
    if (id >= h.sealed) return &h.cur[id - h.sealed];
    const off = @as(usize, id) * @sizeOf(Row);
    return @ptrCast(@alignCast(h.rows_map[off..][0..@sizeOf(Row)].ptr));
}

fn cmsSlots(x: u64) [cms_rows]usize {
    const mask = (1 << cms_bits) - 1;
    var out: [cms_rows]usize = undefined;
    inline for (0..cms_rows) |r| out[r] = (r << cms_bits) | @as(usize, @intCast((x >> (r * 24 + 8)) & mask));
    return out;
}

fn df(h: *const Holo, x: u64) u32 {
    const sl = cmsSlots(x);
    var m: u32 = std.math.maxInt(u32);
    inline for (0..cms_rows) |r| m = @min(m, h.cms[sl[r]]);
    return m;
}

/// Conservative update: only the counters at the current minimum grow, so
/// common words don't inflate the counts of rare ones.
fn bumpDf(h: *Holo, x: u64) void {
    const sl = cmsSlots(x);
    var m: u32 = std.math.maxInt(u32);
    inline for (0..cms_rows) |r| m = @min(m, h.cms[sl[r]]);
    inline for (0..cms_rows) |r| {
        if (h.cms[sl[r]] == m) h.cms[sl[r]] = m +| 1;
    }
}

fn idf(h: *const Holo, x: u64) f32 {
    const n: f32 = @floatFromInt(@max(h.count, 1));
    const d: f32 = @floatFromInt(h.df(x));
    return @log(1.0 + (n - d + 0.5) / (d + 0.5));
}

fn subjectKey(scope: u32, subject: []const u8) u64 {
    return std.hash.Wyhash.hash(scope, subject);
}

/// 32-bit similarity hash over a memory's kept terms: near-copies land
/// within a bit or two of each other.
fn simhash(hashes: []const u64, order: []const u16) u32 {
    const V = @Vector(32, i16);
    var acc: V = @splat(0);
    const shifts = std.simd.iota(u32, 32);
    for (order) |o| {
        const x: u32 = @truncate(hashes[o]);
        const bits = (@as(@Vector(32, u32), @splat(x)) >> shifts) & @as(@Vector(32, u32), @splat(1));
        acc += @as(V, @intCast(bits)) * @as(V, @splat(2)) - @as(V, @splat(1));
    }
    const pos: @Vector(32, bool) = acc > @as(V, @splat(0));
    return @bitCast(pos);
}

/// Adds one memory's row. Caller holds the write lock. Same code for new
/// writes and for replay, so a rebuilt index matches the original.
fn applyRow(h: *Holo, scope_name: []const u8, subject: []const u8, time: u64, body_len: usize, terms: text.Terms) !u32 {
    const gpa = h.gpa;
    const id = h.count;
    if (id == none) return error.Full;
    const scope = try h.intern(scope_name);

    // Keep the rarest terms: they are what tells memories apart.
    var dfs: [text.TermSet.cap]u32 = undefined;
    var order: [text.TermSet.cap]u16 = undefined;
    for (terms.hashes, 0..) |x, i| {
        order[i] = @intCast(i);
        dfs[i] = h.df(x);
    }
    const nt = @min(terms.hashes.len, max_terms);
    {
        const Ctx = struct {
            d: []const u32,
            fn lt(c: @This(), a: u16, b: u16) bool {
                return c.d[a] < c.d[b];
            }
        };
        std.mem.sortUnstable(u16, order[0..terms.hashes.len], Ctx{ .d = dfs[0..terms.hashes.len] }, Ctx.lt);
    }

    var r: Row = .{
        .terms = @splat(0),
        .time = time,
        .subj = if (subject.len > 0) @truncate(std.hash.Wyhash.hash(1, subject)) else 0,
        .scope = scope,
        .prev = h.heads.items[scope],
        .len = @intCast(body_len),
        .sim = simhash(terms.hashes, order[0..nt]),
        .nterms = @intCast(nt),
        .kind = 0,
    };
    for (0..nt) |i| r.terms[i] = text.tag(terms.hashes[order[i]]);
    for (terms.hashes) |x| h.bumpDf(x);
    h.total_terms += terms.total;

    try h.buried.ensure(gpa, id + 1);
    try h.forgotten.ensure(gpa, id + 1);

    // Sedimentation: the newest version of a subject buries older ones;
    // a near-copy of a recent memory in this scope buries the copy.
    if (subject.len > 0) {
        const k = subjectKey(scope, subject);
        const gop = try h.subjects.getOrPut(gpa, k);
        if (gop.found_existing) h.buried.set(gop.value_ptr.*);
        gop.value_ptr.* = id;
    } else if (nt >= 3) {
        var p = r.prev;
        var steps: usize = 0;
        while (p != none and steps < 8) : (steps += 1) {
            const pr = h.row(p);
            if (pr.subj == 0 and pr.nterms >= 3 and @popCount(pr.sim ^ r.sim) <= 1 and !h.buried.get(p)) {
                h.buried.set(p);
                break;
            }
            p = pr.prev;
        }
    }

    h.heads.items[scope] = id;
    h.scope_counts.items[scope] += 1;

    // Row into the open page; seal the page when it fills.
    const slot = id - h.sealed;
    if (slot == 0) {
        try h.pages.append(gpa, .{ .bloom = @splat(0), .tmax = 0, .smask = 0 });
        try h.heat.append(gpa, 0);
    }
    h.cur[slot] = r;
    const pg = &h.pages.items[h.pages.items.len - 1];
    // Every searchable term goes into the page fingerprint: recall skips a
    // page when a term's bit is missing.
    for (0..nt) |i| {
        const bit = text.bloomBit(terms.hashes[order[i]]);
        pg.bloom[bit / 64] |= @as(u64, 1) << @intCast(bit % 64);
    }
    pg.tmax = @max(pg.tmax, time);
    pg.smask |= @as(u64, 1) << @intCast(scope % 64);
    h.count = id + 1;
    if (slot + 1 == page_rows) try h.sealPage();
    return id;
}

fn sealPage(h: *Holo) !void {
    const n = h.count - h.sealed;
    const bytes = std.mem.sliceAsBytes(h.cur[0..n]);
    try h.rows_file.writePositionalAll(h.io, bytes, @as(u64, h.sealed) * @sizeOf(Row));
    h.sealed += n;
}

// ---------------------------------------------------------------- values

/// Memories are keyed by id, in blocks of 65536 ids. Each block is split
/// into 8 lanes (streams) by scope, so one chat's writes share a sync and
/// different chats spread over the store's shards and sync in parallel.
const lanes = 8;
const block_shift = 16;

/// A scope's lane comes from its name, so a rebuilt index (where scope ids
/// can come out in another order) finds the same keys.
fn laneOf(h: *const Holo, scope: u32) u32 {
    return @intCast(scopeHash(h.scopeName(scope)) % lanes);
}

fn memKey(buf: *[24]u8, id: u32, lane: u32) []const u8 {
    return std.fmt.bufPrint(buf, "~m/{x:0>4}{x}/{x:0>8}", .{ id >> block_shift, lane, id }) catch unreachable;
}

/// Store key of a memory, from its row.
fn keyOf(h: *const Holo, buf: *[24]u8, id: u32) []const u8 {
    return memKey(buf, id, h.laneOf(h.row(id).scope));
}

fn opKey(buf: *[32]u8, seq: u64) []const u8 {
    return std.fmt.bufPrint(buf, "~o/{x:0>10}/{x:0>16}", .{ seq >> 12, seq }) catch unreachable;
}

fn valueLen(scope: []const u8, subject: []const u8, body: []const u8) usize {
    return 2 + scope.len + 2 + subject.len + 8 + body.len;
}

fn encodeValue(gpa: Allocator, scope: []const u8, subject: []const u8, time: u64, body: []const u8) ![]u8 {
    const v = try gpa.alloc(u8, valueLen(scope, subject, body));
    encodeInto(v, scope, subject, time, body);
    return v;
}

fn encodeInto(v: []u8, scope: []const u8, subject: []const u8, time: u64, body: []const u8) void {
    var p: usize = 0;
    std.mem.writeInt(u16, v[p..][0..2], @intCast(scope.len), .little);
    p += 2;
    @memcpy(v[p..][0..scope.len], scope);
    p += scope.len;
    std.mem.writeInt(u16, v[p..][0..2], @intCast(subject.len), .little);
    p += 2;
    @memcpy(v[p..][0..subject.len], subject);
    p += subject.len;
    std.mem.writeInt(u64, v[p..][0..8], time, .little);
    p += 8;
    @memcpy(v[p..], body);
}

fn decodeValue(id: u32, raw: []u8) !Memory {
    if (raw.len < 12) return error.Corrupt;
    var p: usize = 0;
    const sl = std.mem.readInt(u16, raw[0..2], .little);
    p = 2;
    if (p + sl + 2 > raw.len) return error.Corrupt;
    const scope = raw[p..][0..sl];
    p += sl;
    const bl = std.mem.readInt(u16, raw[p..][0..2], .little);
    p += 2;
    if (p + bl + 8 > raw.len) return error.Corrupt;
    const subject = raw[p..][0..bl];
    p += bl;
    const time = std.mem.readInt(u64, raw[p..][0..8], .little);
    p += 8;
    return .{ .id = id, .time = time, .scope = scope, .subject = subject, .text = raw[p..], .raw = raw };
}

// ---------------------------------------------------------------- writes

/// Saves a memory and returns its id.
pub fn remember(h: *Holo, scope: []const u8, body: []const u8, opts: RememberOptions) !u32 {
    if (scope.len == 0 or scope.len > 1024) return error.InvalidScope;
    const subject = opts.subject orelse "";
    if (subject.len > 1024) return error.InvalidSubject;
    const time = opts.time orelse h.nowMs();
    const vlen = valueLen(scope, subject, body);
    // Checked before the index changes: a failed write must not bury
    // the memory it would have replaced.
    if (vlen + 8 > record.max_value_len) return error.TooLarge;
    var ts: text.TermSet = .{};
    ts.fill(body);
    var stack: [4096]u8 = undefined;
    const value = if (vlen <= stack.len) stack[0..vlen] else try h.gpa.alloc(u8, vlen);
    defer if (vlen > stack.len) h.gpa.free(value);
    encodeInto(value, scope, subject, time, body);

    h.lock.lockUncancelable(h.io);
    const id = h.applyRow(scope, subject, time, body.len, ts.terms()) catch |e| {
        h.lock.unlock(h.io);
        return e;
    };
    const want_ckpt = h.count - h.ckpt_count >= checkpoint_every;
    var kb: [24]u8 = undefined;
    const key = h.keyOf(&kb, id);
    _ = h.inflight.fetchAdd(1, .acq_rel);
    h.lock.unlock(h.io);
    // Text goes to the store outside the lock, so writers run in parallel.
    // A reader that finds a row before its text simply skips it.
    const put_result = h.kv.put(key, value);
    _ = h.inflight.fetchSub(1, .acq_rel);
    try put_result;
    try h.dropIfForgotten(id);
    if (h.options.sync_writes) try h.kv.sync();
    if (want_ckpt) try h.checkpoint();
    return id;
}

/// A forget that ran between adding a row and storing its text deleted a
/// key that was not there yet: delete the text now.
fn dropIfForgotten(h: *Holo, id: u32) !void {
    var kb: [24]u8 = undefined;
    const key = blk: {
        h.lock.lockSharedUncancelable(h.io);
        defer h.lock.unlockShared(h.io);
        if (!h.forgotten.get(id)) return;
        break :blk h.keyOf(&kb, id);
    };
    try h.kv.delete(key);
}

pub const Item = struct {
    scope: []const u8,
    text: []const u8,
    subject: ?[]const u8 = null,
    time: ?u64 = null,
};

/// Saves many memories at once and returns the first id; the rest follow
/// in order. Tokenizing and storing run on every core; only adding the
/// rows to the index is serial. Use it for imports and bulk loads.
pub fn rememberMany(h: *Holo, items: []const Item) !u32 {
    if (items.len == 0) return h.count;
    for (items) |it| {
        if (it.scope.len == 0 or it.scope.len > 1024) return error.InvalidScope;
        if (it.subject) |sj| if (sj.len > 1024) return error.InvalidSubject;
        if (valueLen(it.scope, it.subject orelse "", it.text) + 8 > record.max_value_len) return error.TooLarge;
    }
    const gpa = h.gpa;
    const now = h.nowMs();
    const nw: usize = @min(max_workers, @max(1, std.Thread.getCpuCount() catch 1), (items.len + 63) / 64);

    // 1. Tokenize in parallel: each worker fills its own slice of spans.
    const Span = struct { start: u32, len: u32, total: u32 };
    const spans = try gpa.alloc(Span, items.len);
    defer gpa.free(spans);
    var pools: [max_workers]std.ArrayList(u64) = @splat(.empty);
    defer for (&pools) |*p| p.deinit(gpa);
    const Tok = struct {
        fn run(its: []const Item, sp: []Span, pool: *std.ArrayList(u64), a: Allocator, err: *?anyerror) void {
            var ts: text.TermSet = .{};
            for (its, sp) |it, *o| {
                ts.fill(it.text);
                o.* = .{ .start = @intCast(pool.items.len), .len = @intCast(ts.len), .total = @intCast(ts.total) };
                pool.appendSlice(a, ts.hashes[0..ts.len]) catch |e| {
                    err.* = e;
                    return;
                };
            }
        }
    };
    var errs: [max_workers]?anyerror = @splat(null);
    const per = (items.len + nw - 1) / nw;
    {
        var threads: [max_workers]?std.Thread = @splat(null);
        for (0..nw) |w| {
            const lo = @min(items.len, w * per);
            const hi = @min(items.len, lo + per);
            const args = .{ items[lo..hi], spans[lo..hi], &pools[w], gpa, &errs[w] };
            threads[w] = std.Thread.spawn(.{}, Tok.run, args) catch null;
            if (threads[w] == null) @call(.auto, Tok.run, args);
        }
        for (threads[0..nw]) |t| if (t) |x| x.join();
    }
    for (errs) |e| if (e) |x| return x;

    // 2. Add rows, in order, under the lock.
    const lanes_of = try gpa.alloc(u8, items.len);
    defer gpa.free(lanes_of);
    var first: u32 = 0;
    {
        h.lock.lockUncancelable(h.io);
        defer h.lock.unlock(h.io);
        first = h.count;
        for (items, spans, 0..) |it, sp, i| {
            const w = i / per;
            const terms: text.Terms = .{ .hashes = pools[w].items[sp.start..][0..sp.len], .total = sp.total };
            const id = try h.applyRow(it.scope, it.subject orelse "", it.time orelse now, it.text.len, terms);
            lanes_of[i] = @intCast(h.laneOf(h.row(id).scope));
        }
        _ = h.inflight.fetchAdd(1, .acq_rel);
    }

    // 3. Store the text in parallel, each worker owning some lanes so
    // workers rarely share a shard.
    const Put = struct {
        fn run(hh: *Holo, its: []const Item, lanes_: []const u8, first_id: u32, now_: u64, w: usize, n: usize, err: *?anyerror) void {
            var buf: std.ArrayList(u8) = .empty;
            defer buf.deinit(hh.gpa);
            for (its, 0..) |it, i| {
                if (lanes_[i] % n != w) continue;
                const subject = it.subject orelse "";
                buf.resize(hh.gpa, valueLen(it.scope, subject, it.text)) catch |e| {
                    err.* = e;
                    return;
                };
                encodeInto(buf.items, it.scope, subject, it.time orelse now_, it.text);
                var kb: [24]u8 = undefined;
                const id = first_id + @as(u32, @intCast(i));
                hh.kv.put(memKey(&kb, id, lanes_[i]), buf.items) catch |e| {
                    err.* = e;
                    return;
                };
            }
        }
    };
    errs = @splat(null);
    var threads: [max_workers]?std.Thread = @splat(null);
    for (0..nw) |w| {
        threads[w] = std.Thread.spawn(.{}, Put.run, .{ h, items, lanes_of, first, now, w, nw, &errs[w] }) catch null;
        if (threads[w] == null) Put.run(h, items, lanes_of, first, now, w, nw, &errs[w]);
    }
    for (threads[0..nw]) |t| if (t) |x| x.join();
    _ = h.inflight.fetchSub(1, .acq_rel);
    for (errs) |e| if (e) |x| return x;
    for (0..items.len) |i| try h.dropIfForgotten(first + @as(u32, @intCast(i)));
    if (h.options.sync_writes) try h.kv.syncAll() else h.batch_unsynced.store(true, .release);
    if (h.count - h.ckpt_count >= checkpoint_every) try h.checkpoint();
    return first;
}

const max_workers = 8;

/// Makes every write so far durable.
pub fn sync(h: *Holo) !void {
    // Batch writes store text from worker threads, which this thread's
    // own sync would not cover.
    if (h.batch_unsynced.swap(false, .acq_rel)) return h.kv.syncAll();
    try h.kv.sync();
}

fn logOp(h: *Holo, op: []const u8) !void {
    h.ops_seq += 1;
    var kb: [32]u8 = undefined;
    try h.kv.put(opKey(&kb, h.ops_seq), op);
    if (h.options.sync_writes) try h.kv.syncAll();
}

/// Forgets one memory: it never comes back in any answer, and its text is
/// deleted from disk.
pub fn forget(h: *Holo, id: u32) !void {
    h.lock.lockUncancelable(h.io);
    defer h.lock.unlock(h.io);
    if (id >= h.count) return error.NotFound;
    try h.forgetLocked(id);
    var op: [5]u8 = undefined;
    op[0] = 1;
    std.mem.writeInt(u32, op[1..5], id, .little);
    try h.logOp(&op);
}

fn forgetLocked(h: *Holo, id: u32) !void {
    if (h.forgotten.get(id)) return;
    h.forgotten.set(id);
    var kb: [24]u8 = undefined;
    try h.kv.delete(h.keyOf(&kb, id));
}

/// Forgets every memory in a scope and below it. Returns how many.
pub fn forgetScope(h: *Holo, scope: []const u8) !usize {
    if (scope.len == 0) return error.InvalidScope;
    h.lock.lockUncancelable(h.io);
    defer h.lock.unlock(h.io);
    const n = try h.forgetScopeLocked(scope, h.count);
    // The op records where it stopped, so replay leaves later memories alone.
    const op = try h.gpa.alloc(u8, 5 + scope.len);
    defer h.gpa.free(op);
    op[0] = 2;
    std.mem.writeInt(u32, op[1..5], h.count, .little);
    @memcpy(op[5..], scope);
    try h.logOp(op);
    return n;
}

/// Forgets the memories in `scope` and below with ids before `before`.
fn forgetScopeLocked(h: *Holo, scope: []const u8, before: u32) !usize {
    var set = try h.scopeSet(h.gpa, scope);
    defer set.deinit(h.gpa);
    var n: usize = 0;
    for (0..h.scope_offs.items.len) |i| {
        const sid: u32 = @intCast(i);
        if (!set.has(sid)) continue;
        var p = h.heads.items[sid];
        while (p != none) : (p = h.row(p).prev) {
            if (p >= before or h.forgotten.get(p)) continue;
            try h.forgetLocked(p);
            n += 1;
        }
    }
    return n;
}

/// Adds a summary of a scope and sinks every memory it covers: they stay
/// on disk and in `deep` recall, but normal answers use the summary.
pub fn settle(h: *Holo, scope: []const u8, summary: []const u8) !u32 {
    const id = try h.remember(scope, summary, .{ .subject = "summary" });
    h.lock.lockUncancelable(h.io);
    defer h.lock.unlock(h.io);
    h.sinkLocked(scope, id);
    // Scope and boundary, not just the summary: the summary itself may be
    // forgotten later, and replay must still sink the same memories.
    const op = try h.gpa.alloc(u8, 5 + scope.len);
    defer h.gpa.free(op);
    op[0] = 4;
    std.mem.writeInt(u32, op[1..5], id, .little);
    @memcpy(op[5..], scope);
    try h.logOp(op);
    return id;
}

/// Buries the memories of exactly `scope` with ids before `before`.
fn sinkLocked(h: *Holo, scope: []const u8, before: u32) void {
    const sid = h.findScope(scope) orelse return;
    var p = h.heads.items[sid];
    while (p != none) : (p = h.row(p).prev) {
        if (p < before) h.buried.set(p);
    }
}

// ----------------------------------------------------------------- reads

/// One memory by id, or null if it was forgotten.
pub fn get(h: *Holo, gpa: Allocator, id: u32) !?Memory {
    var kb: [24]u8 = undefined;
    const key = blk: {
        h.lock.lockSharedUncancelable(h.io);
        defer h.lock.unlockShared(h.io);
        if (id >= h.count or h.forgotten.get(id)) return null;
        break :blk h.keyOf(&kb, id);
    };
    const raw = (try h.kv.get(gpa, key)) orelse return null;
    errdefer gpa.free(raw);
    return try decodeValue(id, raw);
}

fn fetch(h: *Holo, gpa: Allocator, ids: []const u32, out: *std.ArrayList(Memory)) !void {
    for (ids) |id| {
        if (try h.get(gpa, id)) |m| {
            errdefer m.deinit(gpa);
            try out.append(gpa, m);
        }
    }
}

/// The newest `n` memories in one scope, newest first.
pub fn recent(h: *Holo, gpa: Allocator, scope: []const u8, n: usize) ![]Memory {
    return h.recentFiltered(gpa, scope, n, false);
}

fn recentFiltered(h: *Holo, gpa: Allocator, scope: []const u8, n: usize, skip_buried: bool) ![]Memory {
    var ids: std.ArrayList(u32) = .empty;
    defer ids.deinit(gpa);
    {
        h.lock.lockSharedUncancelable(h.io);
        defer h.lock.unlockShared(h.io);
        if (h.findScope(scope)) |sid| {
            try ids.ensureTotalCapacity(gpa, @min(n, h.scope_counts.items[sid]));
            var p = h.heads.items[sid];
            while (p != none and ids.items.len < n) : (p = h.row(p).prev) {
                if (h.forgotten.get(p) or (skip_buried and h.buried.get(p))) continue;
                ids.appendAssumeCapacity(p);
            }
        }
    }
    var out: std.ArrayList(Memory) = .empty;
    errdefer {
        for (out.items) |m| m.deinit(gpa);
        out.deinit(gpa);
    }
    try h.fetch(gpa, ids.items, &out);
    return out.toOwnedSlice(gpa);
}

/// The current memory for a subject in a scope.
pub fn current(h: *Holo, gpa: Allocator, scope: []const u8, subject: []const u8) !?Memory {
    const id = blk: {
        h.lock.lockSharedUncancelable(h.io);
        defer h.lock.unlockShared(h.io);
        const sid = h.findScope(scope) orelse return null;
        const id = h.subjects.get(subjectKey(sid, subject)) orelse return null;
        if (h.forgotten.get(id)) return null;
        break :blk id;
    };
    return h.get(gpa, id);
}

/// A query word or a word related in meaning to one. `idf` is what a match
/// is worth; words of one `group` count once, by their best match.
const QTerm = struct { tag: u16, bit: u12, idf: f32, hash: u64, group: u8 = 0 };
const max_groups = 8;
const max_related = 4;
const min_related_sim = 0.45;
const anchor_weight = 2.0;

const Cand = struct { id: u32, score: f32 };

fn recency(h: *const Holo, now: u64, t: u64) f32 {
    const age: f32 = @floatFromInt(now -| t);
    const hl: f32 = @floatFromInt(@max(h.options.half_life_ms, 1));
    return 0.85 + 0.15 * @exp2(-age / hl);
}

fn heatBoost(heat: u32) f32 {
    return 1.0 + 0.05 * @min(@log2(1.0 + @as(f32, @floatFromInt(heat))), 6.0);
}

const TopK = struct {
    items: []Cand,
    len: usize = 0,

    fn floor(t: *const TopK) f32 {
        if (t.len < t.items.len) return 0;
        var m: f32 = std.math.inf(f32);
        for (t.items) |c| m = @min(m, c.score);
        return m;
    }
    /// The k-th best score so far, or 0 with fewer than k.
    fn kth(t: *const TopK, k: usize) f32 {
        if (t.len < k) return 0;
        var best: [16]f32 = @splat(-1);
        const kk = @min(k, best.len);
        for (t.items[0..t.len]) |c| {
            if (c.score <= best[kk - 1]) continue;
            var i = kk - 1;
            while (i > 0 and best[i - 1] < c.score) : (i -= 1) best[i] = best[i - 1];
            best[i] = c.score;
        }
        return best[kk - 1];
    }
    fn push(t: *TopK, c: Cand) void {
        if (t.len < t.items.len) {
            t.items[t.len] = c;
            t.len += 1;
            return;
        }
        var mi: usize = 0;
        for (t.items, 0..) |x, i| if (x.score < t.items[mi].score) {
            mi = i;
        };
        if (c.score > t.items[mi].score) t.items[mi] = c;
    }
};

/// Rewards matching all of a question over matching part of it: the score
/// times the squared share of the question's weight it covers.
fn coverage(s: f32, qsum: f32) f32 {
    if (qsum <= 0) return s;
    const c = s / qsum;
    return s * c * c;
}

fn rowScore(r: *const Row, q: []const QTerm) f32 {
    const V = @Vector(max_terms, u16);
    const tags: V = r.terms;
    var best: [max_groups]f32 = @splat(0);
    for (q) |t| {
        const hit = tags == @as(V, @splat(t.tag));
        if (@reduce(.Or, hit)) best[t.group] = @max(best[t.group], t.idf);
    }
    var s: f32 = 0;
    for (best) |b| s += b;
    return s;
}

/// Best possible score of any row on a page, from its bloom filter.
fn pageBound(pg: *const Page, q: []const QTerm) f32 {
    var best: [max_groups]f32 = @splat(0);
    for (q) |t| {
        if (pg.bloom[t.bit / 64] & (@as(u64, 1) << @intCast(t.bit % 64)) != 0) best[t.group] = @max(best[t.group], t.idf);
    }
    var s: f32 = 0;
    for (best) |b| s += b;
    return s;
}

fn passes(h: *const Holo, id: u32, r: *const Row, set: *const ScopeSet, q: Query) bool {
    if (h.forgotten.get(id)) return false;
    if (!q.deep and h.buried.get(id)) return false;
    if (r.time < q.since) return false;
    return set.has(r.scope);
}

/// Memories ranked by how well they match `about`, how recent they are,
/// and how often their page gets recalled. Buried memories only with `deep`.
pub fn recall(h: *Holo, gpa: Allocator, q: Query) ![]Hit {
    const limit = @max(q.limit, 1);
    // Query terms, rarest first, at most 8.
    var ts: text.TermSet = .{};
    ts.fill(q.about);
    var qt_buf: [max_groups * (1 + max_related)]QTerm = undefined;
    var cands_buf: [256]Cand = undefined;
    const meaning: ?*const Meaning = if (q.expand) h.options.meaning else null;
    const pool = @min(cands_buf.len, if (meaning != null) @max(limit * 8, 64) else @max(limit * 4, 16));
    var top: TopK = .{ .items = cands_buf[0..pool] };
    var nq: usize = 0;
    var avg_len: f32 = 1;
    var qsum: f32 = 0;
    const now = h.nowMs();
    {
        h.lock.lockSharedUncancelable(h.io);
        defer h.lock.unlockShared(h.io);
        if (h.count == 0) return gpa.alloc(Hit, 0);
        avg_len = @as(f32, @floatFromInt(h.total_terms)) / @as(f32, @floatFromInt(h.count));
        var all: [text.TermSet.cap]QTerm = undefined;
        for (ts.hashes[0..ts.len], 0..) |x, i| all[i] = .{ .tag = text.tag(x), .bit = text.bloomBit(x), .idf = h.idf(x), .hash = x };
        const Ctx = struct {
            fn lt(_: void, a: QTerm, b: QTerm) bool {
                return a.idf > b.idf;
            }
        };
        std.mem.sortUnstable(QTerm, all[0..ts.len], {}, Ctx.lt);
        // Names and ids (words the meaning table does not know) are what a
        // question is about: with meaning on, they weigh double.
        if (meaning) |mn| {
            for (all[0..ts.len]) |*t| if (mn.index(t.hash) == null) {
                t.idf *= anchor_weight;
            };
            std.mem.sortUnstable(QTerm, all[0..ts.len], {}, Ctx.lt);
        }
        nq = @min(ts.len, max_groups);
        @memcpy(qt_buf[0..nq], all[0..nq]);
        for (qt_buf[0..nq], 0..) |*t, g| {
            t.group = @intCast(g);
            qsum += t.idf;
        }
        // Words related in meaning join their word's group, worth their
        // squared similarity times the lower of the two rarities.
        if (meaning) |mn| {
            const ng = nq;
            for (0..ng) |g| {
                var rel: [max_related]Meaning.Related = undefined;
                const n = mn.related(qt_buf[g].hash, min_related_sim, &rel);
                outer: for (rel[0..n]) |rw| {
                    for (qt_buf[0..nq]) |t| if (t.hash == rw.hash) continue :outer;
                    const vi = h.idf(rw.hash);
                    qt_buf[nq] = .{
                        .tag = text.tag(rw.hash),
                        .bit = text.bloomBit(rw.hash),
                        .idf = rw.sim * rw.sim * @min(qt_buf[g].idf, vi),
                        .hash = rw.hash,
                        .group = @intCast(g),
                    };
                    nq += 1;
                }
            }
        }
        const qt = qt_buf[0..nq];

        var set = try h.scopeSet(gpa, q.scope);
        defer set.deinit(gpa);
        if (!set.all and set.n == 0) return gpa.alloc(Hit, 0);

        // A few small scopes (one chat, one project): walk their chains
        // instead of scanning pages.
        var chain_ids: [256]u32 = undefined;
        var nchains: usize = 0;
        if (!set.all and set.n <= chain_ids.len) {
            var total: u64 = 0;
            if (set.single != none) {
                chain_ids[0] = set.single;
                nchains = 1;
            } else {
                for (set.bits.words.items, 0..) |w0, wi| {
                    var w = w0;
                    while (w != 0) : (w &= w - 1) {
                        chain_ids[nchains] = @intCast(wi * 64 + @ctz(w));
                        nchains += 1;
                    }
                }
            }
            for (chain_ids[0..nchains]) |sid| total += h.scope_counts.items[sid];
            if (total > 65536) nchains = 0;
        }
        if (nchains > 0) {
            for (chain_ids[0..nchains]) |sid| {
                var p = h.heads.items[sid];
                var taken: usize = 0;
                while (p != none) : (p = h.row(p).prev) {
                    const r = h.row(p);
                    if (!h.passes(p, r, &set, q)) continue;
                    if (nq == 0) {
                        top.push(.{ .id = p, .score = @floatFromInt(p) });
                        taken += 1;
                        if (taken == top.items.len) break;
                        continue;
                    }
                    const base = coverage(rowScore(r, qt), qsum);
                    if (base == 0) continue;
                    const pg = p / page_rows;
                    top.push(.{ .id = p, .score = base * h.recency(now, r.time) * heatBoost(@atomicLoad(u32, &h.heat.items[pg], .monotonic)) * subjBoost(r) });
                }
            }
        } else {
            var pi = h.pages.items.len;
            while (pi > 0) {
                pi -= 1;
                const pg = &h.pages.items[pi];
                if (pg.smask & set.mask == 0) continue;
                if (pg.tmax < q.since) continue;
                const best_rec = h.recency(now, pg.tmax) * 1.1 * 1.3;
                // Prune against the limit-th best (with slack for the rerank),
                // not the whole pool.
                const fl = @max(top.floor(), top.kth(limit) * 0.75);
                if (nq == 0) {
                    if (top.len == top.items.len) break;
                } else {
                    // Nothing older can beat the current top: stop.
                    if (top.len == top.items.len and qsum * best_rec <= fl) break;
                    const bound = pageBound(pg, qt);
                    if (bound == 0 or coverage(bound, qsum) * best_rec * heatBoost(@atomicLoad(u32, &h.heat.items[pi], .monotonic)) <= fl) continue;
                }
                const first: u32 = @intCast(pi * page_rows);
                const last: u32 = @min(h.count, first + page_rows);
                var id = last;
                while (id > first) {
                    id -= 1;
                    const r = h.row(id);
                    if (!h.passes(id, r, &set, q)) continue;
                    if (nq == 0) {
                        top.push(.{ .id = id, .score = @floatFromInt(id) });
                        if (top.len == top.items.len) break;
                        continue;
                    }
                    const base = coverage(rowScore(r, qt), qsum);
                    if (base == 0) continue;
                    top.push(.{ .id = id, .score = base * h.recency(now, r.time) * heatBoost(@atomicLoad(u32, &h.heat.items[pi], .monotonic)) * subjBoost(r) });
                }
            }
        }
    }

    // Rerank the pool on full text (BM25 with recency), then keep `limit`.
    const cands = top.items[0..top.len];
    std.mem.sortUnstable(Cand, cands, {}, struct {
        fn gt(_: void, a: Cand, b: Cand) bool {
            return a.score > b.score;
        }
    }.gt);
    var hits: std.ArrayList(Hit) = .empty;
    errdefer {
        for (hits.items) |x| x.memory.deinit(gpa);
        hits.deinit(gpa);
    }
    for (cands) |c| {
        // Newest-first answers need no rerank: stop at the limit.
        if (nq == 0 and hits.items.len == limit) break;
        const m = (try h.get(gpa, c.id)) orelse continue;
        var score = c.score;
        var matched: u8 = 0;
        var topics: Topics = @splat(0);
        if (nq > 0) {
            var mt: text.TermSet = .{};
            mt.fill(m.text);
            var gbm: [max_groups]f32 = @splat(0);
            var gcov: [max_groups]f32 = @splat(0);
            var mask: u8 = 0;
            const dl: f32 = @floatFromInt(mt.total);
            for (qt_buf[0..nq]) |t| {
                for (mt.hashes[0..mt.len], 0..) |x, i| if (x == t.hash) {
                    if (t.idf <= gcov[t.group]) break;
                    const tf: f32 = @floatFromInt(mt.tf[i]);
                    gbm[t.group] = t.idf * tf * 2.2 / (tf + 1.2 * (0.25 + 0.75 * dl / @max(avg_len, 1)));
                    gcov[t.group] = t.idf;
                    mask |= @as(u8, 1) << @intCast(t.group);
                    break;
                };
            }
            var bm: f32 = 0;
            var covered: f32 = 0;
            for (gbm, gcov) |b, cv| {
                bm += b;
                covered += cv;
            }
            if (bm == 0) {
                m.deinit(gpa);
                continue;
            }
            var near: f32 = 0;
            if (meaning) |mn| near, topics = closeness(mn, qt_buf[0..nq], m.text);
            const r = blk: {
                h.lock.lockSharedUncancelable(h.io);
                defer h.lock.unlockShared(h.io);
                break :blk h.row(c.id).*;
            };
            const cov = covered / @max(qsum, 1e-6);
            score = bm * cov * cov * (1.0 + semantic_weight * near) * h.recency(now, m.time) * subjBoost(&r);
            matched = mask;
        }
        const buried = blk: {
            h.lock.lockSharedUncancelable(h.io);
            defer h.lock.unlockShared(h.io);
            break :blk h.buried.get(c.id);
        };
        try hits.append(gpa, .{ .memory = m, .score = score, .buried = buried, .matched = matched, .topics = topics });
    }
    const Ctx = struct {
        fn gt(_: void, a: Hit, b: Hit) bool {
            return a.score > b.score;
        }
    };
    std.mem.sortUnstable(Hit, hits.items, {}, Ctx.gt);
    if (nq > 0) sedimentHits(hits.items);
    while (hits.items.len > limit) hits.pop().?.memory.deinit(gpa);
    // Recalled pages heat up.
    for (hits.items) |x| {
        const pg = x.memory.id / page_rows;
        h.lock.lockSharedUncancelable(h.io);
        defer h.lock.unlockShared(h.io);
        if (pg < h.heat.items.len) _ = @atomicRmw(u32, &h.heat.items[pg], .Add, 1, .monotonic);
    }
    return hits.toOwnedSlice(gpa);
}

/// Read-time sedimentation: among hits that matched the same query terms
/// (at least two of them) about equally well (within 10%), the newest comes
/// first and the older ones are marked buried. "We changed X to B" then
/// outranks "X is A". Hits that share only one word, such as a name, are
/// different facts about it and are left alone.
fn sedimentHits(hits: []Hit) void {
    var changed = true;
    var rounds: usize = 0;
    while (changed and rounds < hits.len) : (rounds += 1) {
        changed = false;
        for (0..hits.len) |i| for (i + 1..hits.len) |j| {
            const a = &hits[i];
            const b = &hits[j];
            if (!sameFact(a, b)) continue;
            if (b.memory.time > a.memory.time) {
                std.mem.swap(Hit, a, b);
                changed = true;
            }
        };
    }
    for (0..hits.len) |j| for (0..j) |i| {
        const a = &hits[i];
        const b = &hits[j];
        if (sameFact(a, b) and a.memory.time > b.memory.time) {
            b.buried = true;
            break;
        }
    };
}

/// `b` (ranked below `a`) looks like another version of the same fact:
/// it matched the same question words (two or more) about as well, or,
/// with meaning, it shares the question's name and answers it with a
/// same word ("moved to the X region" after "deployed in the Y region").
fn sameFact(a: *const Hit, b: *const Hit) bool {
    if (a.matched == b.matched and @popCount(a.matched) >= 2 and b.score >= a.score * 0.9) return true;
    if (a.matched & b.matched & 1 == 0 or b.score < a.score * 0.5) return false;
    for (a.topics) |x| {
        if (x == 0) break;
        for (b.topics) |y| if (x == y) return true;
    }
    return false;
}
/// How much the closest-in-meaning candidate gains over an unrelated one.
const semantic_weight = 8.0;

/// How close a memory is in meaning to the question: for each question
/// word, its best match among the memory's words (1 for the word itself,
/// less for related words, nothing below `sim_floor`), weighted by rarity.
/// Words near a name the question asks about count fully; farther ones
/// fade, so chatter around the answer does not drown it.
fn closeness(mn: *const Meaning, qt: []const QTerm, body: []const u8) struct { f32, Topics } {
    const Seq = struct {
        hashes: [256]u64 = undefined,
        len: usize = 0,
        pub fn term(q: *@This(), x: u64) void {
            if (q.len < q.hashes.len) {
                q.hashes[q.len] = x;
                q.len += 1;
            }
        }
    };
    var seq: Seq = .{};
    text.forEachTerm(body, &seq);
    // Positions of the question's names (words with no meaning entry).
    var anchors: [32]u16 = undefined;
    var na: usize = 0;
    for (seq.hashes[0..seq.len], 0..) |x, i| {
        for (qt) |t| if (t.hash == x and t.hash == qt[t.group].hash and mn.index(x) == null) {
            if (na < anchors.len) {
                anchors[na] = @intCast(i);
                na += 1;
            }
            break;
        };
    }
    var di: [256]u32 = undefined;
    var dw: [256]f32 = undefined;
    var nd: usize = 0;
    for (seq.hashes[0..seq.len], 0..) |x, i| {
        const wi = mn.index(x) orelse continue;
        var w: f32 = 1;
        if (na > 0) {
            var dist: usize = std.math.maxInt(usize);
            for (anchors[0..na]) |ap| dist = @min(dist, if (ap > i) ap - i else i - ap);
            if (dist > near_words) w = @exp2(-@as(f32, @floatFromInt(dist - near_words)) / near_words);
        }
        di[nd] = wi;
        dw[nd] = w;
        nd += 1;
    }
    var sum: f32 = 0;
    var wsum: f32 = 0;
    var topics: Topics = @splat(0);
    var nt: usize = 0;
    for (qt) |t| {
        if (t.hash != qt[t.group].hash) continue;
        const qi = mn.index(t.hash) orelse continue;
        wsum += t.idf;
        var best: f32 = 0;
        var best_d: u32 = 0;
        for (di[0..nd], dw[0..nd]) |d, w| {
            const sm = w * mn.similarity(qi, d);
            if (sm > best) {
                best = sm;
                best_d = d;
            }
        }
        if (best < sim_floor) continue;
        sum += t.idf * (best - sim_floor) / (1 - sim_floor);
        if (best >= topic_sim and nt < topics.len) {
            topics[nt] = best_d + 1;
            nt += 1;
        }
    }
    return .{ if (wsum > 0) sum / wsum else 0, topics };
}

/// A memory's answer word must be at least this close to count as a topic.
const topic_sim = 0.5;
/// Words this close to a name count fully in `closeness`.
const near_words = 4;
const sim_floor = 0.15;

fn subjBoost(r: *const Row) f32 {
    return if (r.subj != 0) 1.1 else 1.0;
}

/// A briefing for an agent: the memories that matter for `situation`,
/// newest decisions first, near-copies merged, never over `budget` tokens
/// (estimated at 4 bytes per token).
pub fn brief(h: *Holo, gpa: Allocator, situation: []const u8, scope: []const u8, budget: usize) !Brief {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    const hits = try h.recall(gpa, .{ .about = situation, .scope = scope, .limit = 16 });
    defer freeHits(gpa, hits);
    const rec = if (h.isExactScope(scope)) try h.recentFiltered(gpa, scope, 6, true) else try gpa.alloc(Memory, 0);
    defer freeMemories(gpa, rec);

    var used: usize = 0;
    var items: usize = 0;
    var seen: [64]u32 = undefined;
    var nseen: usize = 0;
    const now = h.nowMs();
    const Section = struct { title: []const u8, mems: []const Memory };
    var rel: [24]Memory = undefined;
    var nrel: usize = 0;
    var skipped: usize = 0;
    for (hits) |x| {
        if (x.buried) {
            skipped += 1;
            // An older version: keep it out of the recent section too.
            if (nseen < seen.len) {
                seen[nseen] = x.memory.id;
                nseen += 1;
            }
            continue;
        }
        rel[nrel] = x.memory;
        nrel += 1;
    }
    const sections = [_]Section{
        .{ .title = "Relevant memory", .mems = rel[0..nrel] },
        .{ .title = "Recent in this scope", .mems = rec },
    };
    for (sections) |sec| {
        var header_done = false;
        for (sec.mems) |m| {
            var dup = false;
            for (seen[0..nseen]) |s| dup = dup or s == m.id;
            if (dup) continue;
            const snippet = m.text[0..@min(m.text.len, 600)];
            const line_len = snippet.len + m.scope.len + 40;
            const cost = (line_len + 3) / 4;
            if (used + cost > budget) continue;
            if (!header_done) {
                try out.print(gpa, "## {s}\n", .{sec.title});
                header_done = true;
            }
            const age_s = (now -| m.time) / 1000;
            try out.print(gpa, "- [#{d} {d}{s} ago {s}] {s}{s}\n", .{
                m.id, ageValue(age_s), ageUnit(age_s), m.scope, snippet, if (snippet.len < m.text.len) "..." else "",
            });
            used += cost;
            items += 1;
            if (nseen < seen.len) {
                seen[nseen] = m.id;
                nseen += 1;
            }
        }
    }
    return .{ .text = try out.toOwnedSlice(gpa), .tokens = used, .items = items, .buried_skipped = skipped };
}

fn ageValue(s: u64) u64 {
    if (s < 3600) return s / 60;
    if (s < 86400) return s / 3600;
    return s / 86400;
}

fn ageUnit(s: u64) []const u8 {
    if (s < 3600) return "m";
    if (s < 86400) return "h";
    return "d";
}

fn isExactScope(h: *Holo, scope: []const u8) bool {
    if (scope.len == 0) return false;
    h.lock.lockSharedUncancelable(h.io);
    defer h.lock.unlockShared(h.io);
    return h.findScope(scope) != null;
}

pub const Info = struct {
    memories: u32,
    scopes: usize,
    subjects: usize,
    pages: usize,
    /// Bytes of RAM held by the index (pages, heat, sketch, scopes, bits).
    index_bytes: usize,
};

pub fn info(h: *Holo) Info {
    h.lock.lockSharedUncancelable(h.io);
    defer h.lock.unlockShared(h.io);
    const idx = h.pages.capacity * @sizeOf(Page) + h.heat.capacity * 4 + h.cms.len * 4 +
        h.scope_names.capacity + h.scope_offs.capacity * 4 + h.heads.capacity * 4 + h.scope_counts.capacity * 4 +
        h.scope_map.capacity() * 16 + h.subjects.capacity() * 16 +
        (h.buried.words.capacity + h.forgotten.words.capacity) * 8 + @sizeOf(Holo);
    return .{ .memories = h.count, .scopes = h.scope_offs.items.len, .subjects = h.subjects.count(), .pages = h.pages.items.len, .index_bytes = idx };
}

// ------------------------------------------------------------ checkpoint

const ckpt_magic: u32 = 0x484f4c4f; // "HOLO"
const ckpt_version: u32 = 1;

fn putSlice(gpa: Allocator, buf: *std.ArrayList(u8), bytes: []const u8) !void {
    var len: [8]u8 = undefined;
    std.mem.writeInt(u64, &len, bytes.len, .little);
    try buf.appendSlice(gpa, &len);
    try buf.appendSlice(gpa, bytes);
}

/// Writes everything derived to disk so the next open needs no rebuild.
pub fn checkpoint(h: *Holo) !void {
    // Wait until every added row has its text in the store; new rows
    // cannot start while the write lock is held.
    while (true) {
        h.lock.lockUncancelable(h.io);
        if (h.inflight.load(.acquire) == 0) break;
        h.lock.unlock(h.io);
        std.Thread.yield() catch {};
    }
    defer h.lock.unlock(h.io);
    const gpa = h.gpa;
    // Text first: a checkpoint must never claim rows the store could lose.
    try h.kv.syncAll();
    // Rows of the open page, then pages not yet on disk.
    if (h.count > h.sealed) {
        const bytes = std.mem.sliceAsBytes(h.cur[0 .. h.count - h.sealed]);
        try h.rows_file.writePositionalAll(h.io, bytes, @as(u64, h.sealed) * @sizeOf(Row));
    }
    const first_dirty = @min(h.pages_on_disk, @as(u32, @intCast(h.pages.items.len)) -| 1);
    if (h.pages.items.len > 0) {
        const bytes = std.mem.sliceAsBytes(h.pages.items[first_dirty..]);
        try h.pages_file.writePositionalAll(h.io, bytes, @as(u64, first_dirty) * @sizeOf(Page));
    }
    try h.rows_file.sync(h.io);
    try h.pages_file.sync(h.io);
    h.pages_on_disk = @intCast(h.pages.items.len);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var hdr: [32]u8 = undefined;
    std.mem.writeInt(u32, hdr[0..4], ckpt_magic, .little);
    std.mem.writeInt(u32, hdr[4..8], ckpt_version, .little);
    std.mem.writeInt(u32, hdr[8..12], h.count, .little);
    std.mem.writeInt(u32, hdr[12..16], @intCast(h.pages.items.len), .little);
    std.mem.writeInt(u64, hdr[16..24], h.ops_seq, .little);
    std.mem.writeInt(u64, hdr[24..32], h.total_terms, .little);
    try buf.appendSlice(gpa, &hdr);
    try putSlice(gpa, &buf, h.scope_names.items);
    try putSlice(gpa, &buf, std.mem.sliceAsBytes(h.scope_offs.items));
    try putSlice(gpa, &buf, std.mem.sliceAsBytes(h.heads.items));
    try putSlice(gpa, &buf, std.mem.sliceAsBytes(h.scope_counts.items));
    try putSlice(gpa, &buf, std.mem.sliceAsBytes(h.heat.items));
    try putSlice(gpa, &buf, std.mem.sliceAsBytes(h.buried.words.items));
    try putSlice(gpa, &buf, std.mem.sliceAsBytes(h.forgotten.words.items));
    try putSlice(gpa, &buf, std.mem.sliceAsBytes(h.cms));
    {
        var subj: std.ArrayList(u8) = .empty;
        defer subj.deinit(gpa);
        var it = h.subjects.iterator();
        while (it.next()) |e| {
            var b: [12]u8 = undefined;
            std.mem.writeInt(u64, b[0..8], e.key_ptr.*, .little);
            std.mem.writeInt(u32, b[8..12], e.value_ptr.*, .little);
            try subj.appendSlice(gpa, &b);
        }
        try putSlice(gpa, &buf, subj.items);
    }
    var crc: [4]u8 = undefined;
    std.mem.writeInt(u32, &crc, Crc32c.hash(buf.items), .little);
    try buf.appendSlice(gpa, &crc);
    {
        const f = try h.dir.createFile(h.io, "CKPT.tmp", .{ .truncate = true });
        defer f.close(h.io);
        try f.writePositionalAll(h.io, buf.items, 0);
        try f.sync(h.io);
    }
    try h.dir.rename("CKPT.tmp", h.dir, "CKPT", h.io);
    h.ckpt_count = h.count;
}

const Reader = struct {
    b: []const u8,
    p: usize = 0,
    fn slice(r: *Reader) ![]const u8 {
        if (r.p + 8 > r.b.len) return error.Corrupt;
        const n = std.mem.readInt(u64, r.b[r.p..][0..8], .little);
        r.p += 8;
        if (n > r.b.len - r.p) return error.Corrupt;
        const s = r.b[r.p..][0..n];
        r.p += n;
        return s;
    }
    fn into(r: *Reader, gpa: Allocator, comptime T: type, list: *std.ArrayList(T)) !void {
        const s = try r.slice();
        if (s.len % @sizeOf(T) != 0) return error.Corrupt;
        try list.resize(gpa, s.len / @sizeOf(T));
        @memcpy(std.mem.sliceAsBytes(list.items), s);
    }
};

fn loadCheckpoint(h: *Holo) !void {
    const gpa = h.gpa;
    const f = h.dir.openFile(h.io, "CKPT", .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => |e| return e,
    };
    defer f.close(h.io);
    const len = try f.length(h.io);
    const bytes = try gpa.alloc(u8, len);
    defer gpa.free(bytes);
    if (try f.readPositionalAll(h.io, bytes, 0) != len) return error.Corrupt;
    if (len < 36) return error.Corrupt;
    const body = bytes[0 .. len - 4];
    if (Crc32c.hash(body) != std.mem.readInt(u32, bytes[len - 4 ..][0..4], .little)) return error.Corrupt;
    if (std.mem.readInt(u32, body[0..4], .little) != ckpt_magic) return error.Corrupt;
    if (std.mem.readInt(u32, body[4..8], .little) != ckpt_version) return error.UnsupportedVersion;
    const count = std.mem.readInt(u32, body[8..12], .little);
    const npages = std.mem.readInt(u32, body[12..16], .little);
    h.ops_seq = std.mem.readInt(u64, body[16..24], .little);
    h.total_terms = std.mem.readInt(u64, body[24..32], .little);
    var r: Reader = .{ .b = body, .p = 32 };
    try r.into(gpa, u8, &h.scope_names);
    try r.into(gpa, u32, &h.scope_offs);
    try r.into(gpa, u32, &h.heads);
    try r.into(gpa, u32, &h.scope_counts);
    try r.into(gpa, u32, &h.heat);
    try r.into(gpa, u64, &h.buried.words);
    try r.into(gpa, u64, &h.forgotten.words);
    {
        const s = try r.slice();
        if (s.len != h.cms.len * 4) return error.Corrupt;
        @memcpy(std.mem.sliceAsBytes(h.cms), s);
    }
    {
        const s = try r.slice();
        if (s.len % 12 != 0) return error.Corrupt;
        var i: usize = 0;
        while (i < s.len) : (i += 12) try h.subjects.put(gpa, std.mem.readInt(u64, s[i..][0..8], .little), std.mem.readInt(u32, s[i + 8 ..][0..4], .little));
    }
    if (h.heads.items.len != h.scope_offs.items.len or h.scope_counts.items.len != h.heads.items.len) return error.Corrupt;
    if (npages != (count + page_rows - 1) / page_rows or h.heat.items.len != npages) return error.Corrupt;
    for (0..h.scope_offs.items.len) |i| {
        const id: u32 = @intCast(i);
        var k = scopeHash(h.scopeName(id));
        while (h.scope_map.contains(k)) k +%= 1;
        try h.scope_map.put(gpa, k, id);
    }
    // Pages and the open page's rows.
    try h.pages.resize(gpa, npages);
    const pbytes = std.mem.sliceAsBytes(h.pages.items);
    if (try h.pages_file.readPositionalAll(h.io, pbytes, 0) != pbytes.len) return error.Corrupt;
    h.count = count;
    h.sealed = count - count % page_rows;
    if (count > h.sealed) {
        const cb = std.mem.sliceAsBytes(h.cur[0 .. count - h.sealed]);
        if (try h.rows_file.readPositionalAll(h.io, cb, @as(u64, h.sealed) * @sizeOf(Row)) != cb.len) return error.Corrupt;
    }
    if (try h.rows_file.length(h.io) < @as(u64, h.sealed) * @sizeOf(Row)) return error.Corrupt;
    h.pages_on_disk = npages;
    h.ckpt_count = count;
}

/// Brings the index up to date with the store: memories and operations
/// written after the last checkpoint. Returns whether anything changed.
fn replay(h: *Holo) !bool {
    const gpa = h.gpa;
    var changed = false;
    // Walk the id blocks from the one holding `count`; within a block the
    // lanes interleave, so sort each block by id before applying it.
    var sk: [16]u8 = undefined;
    const start = std.fmt.bufPrint(&sk, "~m/{x:0>4}", .{h.count >> block_shift}) catch unreachable;
    var it = try h.kv.iterator(.{ .start = start, .end = "~m0" }, null);
    var it_open = true;
    defer if (it_open) it.deinit();
    const Pending = struct { id: u32, value: []u8 };
    var block: std.ArrayList(Pending) = .empty;
    defer {
        for (block.items) |x| gpa.free(x.value);
        block.deinit(gpa);
    }
    var block_no: u32 = none;
    while (true) {
        const next = try it.next();
        var id: u32 = 0;
        if (next) |p| {
            const slash = std.mem.lastIndexOfScalar(u8, p.key, '/') orelse return error.Corrupt;
            id = std.fmt.parseInt(u32, p.key[slash + 1 ..], 16) catch return error.Corrupt;
        }
        if (next == null or (id >> block_shift) != block_no) {
            std.mem.sortUnstable(Pending, block.items, {}, struct {
                fn lt(_: void, a: Pending, b: Pending) bool {
                    return a.id < b.id;
                }
            }.lt);
            for (block.items) |x| {
                if (x.id < h.count) continue;
                while (h.count < x.id) try h.placeholder();
                const m = try decodeValue(x.id, x.value);
                var ts: text.TermSet = .{};
                ts.fill(m.text);
                _ = try h.applyRow(m.scope, m.subject, m.time, m.text.len, ts.terms());
                changed = true;
            }
            for (block.items) |x| gpa.free(x.value);
            block.clearRetainingCapacity();
            const p = next orelse break;
            block_no = id >> block_shift;
            _ = p;
        }
        const p = next.?;
        if (id < h.count) continue;
        const copy = try gpa.dupe(u8, p.value);
        errdefer gpa.free(copy);
        try block.append(gpa, .{ .id = id, .value = copy });
    }
    it.deinit();
    it_open = false;

    // Operations: copied out first, because applying them deletes keys,
    // which needs the store's write locks the iterator holds.
    var ops: std.ArrayList([]u8) = .empty;
    defer {
        for (ops.items) |o| gpa.free(o);
        ops.deinit(gpa);
    }
    {
        var ok: [32]u8 = undefined;
        const ostart = opKey(&ok, h.ops_seq + 1);
        var oit = try h.kv.iterator(.{ .start = ostart, .end = "~o0" }, null);
        defer oit.deinit();
        while (try oit.next()) |p| {
            const copy = try gpa.dupe(u8, p.value);
            errdefer gpa.free(copy);
            try ops.append(gpa, copy);
        }
    }
    for (ops.items) |v| {
        if (v.len == 0) return error.Corrupt;
        switch (v[0]) {
            1 => {
                if (v.len != 5) return error.Corrupt;
                const id = std.mem.readInt(u32, v[1..5], .little);
                while (h.count <= id) try h.placeholder();
                try h.forgetLocked(id);
            },
            2, 4 => {
                if (v.len < 5) return error.Corrupt;
                const before = std.mem.readInt(u32, v[1..5], .little);
                while (h.count < before) try h.placeholder();
                if (v[0] == 2) _ = try h.forgetScopeLocked(v[5..], before) else h.sinkLocked(v[5..], before);
            },
            else => return error.Corrupt,
        }
        h.ops_seq += 1;
        changed = true;
    }
    return changed;
}

/// A row for an id whose memory was forgotten before a checkpoint saw it.
fn placeholder(h: *Holo) !void {
    var ts: text.TermSet = .{};
    const id = try h.applyRow("~", "", 0, 0, ts.terms());
    h.forgotten.set(id);
}

// ----------------------------------------------------------------- tests

const testing = std.testing;

fn tmpHolo(tmp: *testing.TmpDir) !*Holo {
    return Holo.open(testing.allocator, testing.io, tmp.dir, "h", .{ .sync_writes = false, .shards = 2 });
}

test "remember, recent and get" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const h = try tmpHolo(&tmp);
    defer h.close();
    h.setClockForTest(1_000_000);
    _ = try h.remember("chat/1", "the deploy is on friday", .{});
    _ = try h.remember("chat/1", "billing invoice for march is late", .{});
    _ = try h.remember("chat/2", "unrelated note", .{});
    const r = try h.recent(testing.allocator, "chat/1", 10);
    defer freeMemories(testing.allocator, r);
    try testing.expectEqual(@as(usize, 2), r.len);
    try testing.expectEqualStrings("billing invoice for march is late", r[0].text);
    try testing.expectEqualStrings("chat/1", r[0].scope);
}

test "recall ranks by meaning words and buries replaced subjects" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const h = try tmpHolo(&tmp);
    defer h.close();
    h.setClockForTest(10_000_000);
    for (0..500) |i| {
        var b: [64]u8 = undefined;
        _ = try h.remember("proj/chat/1", try std.fmt.bufPrint(&b, "filler message number {d} about lunch", .{i}), .{});
    }
    _ = try h.remember("proj/decisions", "auth tokens refresh every 15 minutes", .{ .subject = "auth-refresh" });
    for (0..300) |i| {
        var b: [64]u8 = undefined;
        _ = try h.remember("proj/chat/2", try std.fmt.bufPrint(&b, "more filler {d} on coffee", .{i}), .{});
    }
    _ = try h.remember("proj/decisions", "auth tokens refresh every 60 minutes now", .{ .subject = "auth-refresh" });

    const hits = try h.recall(testing.allocator, .{ .about = "how often do auth tokens refresh?", .scope = "proj", .limit = 3 });
    defer freeHits(testing.allocator, hits);
    try testing.expect(hits.len >= 1);
    try testing.expectEqualStrings("auth tokens refresh every 60 minutes now", hits[0].memory.text);
    for (hits) |x| try testing.expect(!std.mem.eql(u8, x.memory.text, "auth tokens refresh every 15 minutes"));

    const deep = try h.recall(testing.allocator, .{ .about = "auth tokens refresh", .scope = "proj", .limit = 3, .deep = true });
    defer freeHits(testing.allocator, deep);
    try testing.expectEqual(@as(usize, 2), deep.len);

    const cur = (try h.current(testing.allocator, "proj/decisions", "auth-refresh")).?;
    defer cur.deinit(testing.allocator);
    try testing.expectEqualStrings("auth tokens refresh every 60 minutes now", cur.text);
}

test "rememberMany matches one-by-one writes" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const h = try tmpHolo(&tmp);
    defer h.close();
    var items: [1000]Item = undefined;
    var bufs: [1000][48]u8 = undefined;
    for (&items, 0..) |*it, i| {
        it.* = .{ .scope = if (i % 2 == 0) "a/x" else "b/y", .text = try std.fmt.bufPrint(&bufs[i], "note {d} about walrus{d}", .{ i, i % 10 }), .time = 1000 + i };
    }
    const first = try h.rememberMany(&items);
    try testing.expectEqual(@as(u32, 0), first);
    try testing.expectEqual(@as(u32, 1000), h.count);
    const m = (try h.get(testing.allocator, 777)).?;
    defer m.deinit(testing.allocator);
    try testing.expectEqualStrings("note 777 about walrus7", m.text);
    try testing.expectEqualStrings("b/y", m.scope);
    const r = try h.recent(testing.allocator, "a/x", 3);
    defer freeMemories(testing.allocator, r);
    try testing.expectEqual(@as(u32, 998), r[0].id);
    const hits = try h.recall(testing.allocator, .{ .about = "walrus3", .limit = 200 });
    defer freeHits(testing.allocator, hits);
    try testing.expectEqual(@as(usize, 100), hits.len);
}

test "scope filters and forgetting" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const h = try tmpHolo(&tmp);
    defer h.close();
    _ = try h.remember("a/chat/1", "kafka cluster migration plan", .{});
    _ = try h.remember("b/chat/1", "kafka cluster migration plan too", .{});
    _ = try h.remember("ab/chat/1", "kafka cluster in ab", .{});
    {
        const hits = try h.recall(testing.allocator, .{ .about = "kafka migration", .scope = "a" });
        defer freeHits(testing.allocator, hits);
        try testing.expectEqual(@as(usize, 1), hits.len);
        try testing.expectEqualStrings("a/chat/1", hits[0].memory.scope);
    }
    try testing.expectEqual(@as(usize, 1), try h.forgetScope("b"));
    {
        const hits = try h.recall(testing.allocator, .{ .about = "kafka" });
        defer freeHits(testing.allocator, hits);
        try testing.expectEqual(@as(usize, 2), hits.len);
    }
    try testing.expect((try h.get(testing.allocator, 1)) == null);
}

test "near copies are buried, settle sinks a scope" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const h = try tmpHolo(&tmp);
    defer h.close();
    _ = try h.remember("c/1", "postgres replica lag alert fired in region eu", .{});
    _ = try h.remember("c/1", "postgres replica lag alert fired in region eu", .{});
    {
        const hits = try h.recall(testing.allocator, .{ .about = "postgres replica lag" });
        defer freeHits(testing.allocator, hits);
        try testing.expectEqual(@as(usize, 1), hits.len);
        try testing.expectEqual(@as(u32, 1), hits[0].memory.id);
    }
    _ = try h.settle("c/1", "summary: replica lag in eu was a false alarm");
    {
        const hits = try h.recall(testing.allocator, .{ .about = "replica lag" });
        defer freeHits(testing.allocator, hits);
        try testing.expectEqual(@as(usize, 1), hits.len);
        try testing.expect(std.mem.startsWith(u8, hits[0].memory.text, "summary"));
    }
}

test "brief fits the budget" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const h = try tmpHolo(&tmp);
    defer h.close();
    h.setClockForTest(50_000_000);
    for (0..200) |i| {
        var b: [128]u8 = undefined;
        _ = try h.remember("p/chat/9", try std.fmt.bufPrint(&b, "message {d}: the stripe webhook retries with backoff and logs every failure", .{i}), .{});
    }
    const b = try h.brief(testing.allocator, "why do stripe webhooks retry", "p/chat/9", 300);
    defer b.deinit(testing.allocator);
    try testing.expect(b.tokens <= 300);
    try testing.expect(b.items > 0);
    try testing.expect(std.mem.indexOf(u8, b.text, "stripe") != null);
}

test "reopen after clean close and after losing the checkpoint" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        const h = try tmpHolo(&tmp);
        defer h.close();
        for (0..300) |i| {
            var b: [64]u8 = undefined;
            _ = try h.remember("s/x", try std.fmt.bufPrint(&b, "memory {d} zebra{d}", .{ i, i % 7 }), .{ .subject = if (i % 50 == 0) "pinned" else null });
        }
        try h.forget(5);
    }
    {
        const h = try tmpHolo(&tmp);
        defer h.close();
        try testing.expectEqual(@as(u32, 300), h.count);
        try testing.expect(h.forgotten.get(5));
        const hits = try h.recall(testing.allocator, .{ .about = "zebra3", .limit = 100 });
        defer freeHits(testing.allocator, hits);
        try testing.expect(hits.len > 30);
    }
    // Simulate a crash before any checkpoint: the index is rebuilt.
    try tmp.dir.deleteFile(testing.io, "h/CKPT");
    {
        const h = try tmpHolo(&tmp);
        defer h.close();
        try testing.expectEqual(@as(u32, 300), h.count);
        try testing.expect(h.forgotten.get(5));
        const cur = (try h.current(testing.allocator, "s/x", "pinned")).?;
        defer cur.deinit(testing.allocator);
        try testing.expectEqual(@as(u32, 250), cur.id);
    }
}

test "meaning finds a memory that uses other words" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const mn = try Meaning.testModel(testing.allocator);
    defer mn.deinit(testing.allocator);
    const h = try Holo.open(testing.allocator, testing.io, tmp.dir, "h", .{ .sync_writes = false, .shards = 2, .meaning = mn });
    defer h.close();
    for (0..200) |i| {
        var b: [64]u8 = undefined;
        _ = try h.remember("p", try std.fmt.bufPrint(&b, "filler note {d} about a banana", .{i}), .{});
    }
    _ = try h.remember("p", "the billing service had downtime on friday", .{});
    const hits = try h.recall(testing.allocator, .{ .about = "billing outage", .limit = 2 });
    defer freeHits(testing.allocator, hits);
    try testing.expect(hits.len >= 1);
    try testing.expectEqualStrings("the billing service had downtime on friday", hits[0].memory.text);

    const lex = try h.recall(testing.allocator, .{ .about = "outage", .limit = 2, .expand = false });
    defer freeHits(testing.allocator, lex);
    try testing.expectEqual(@as(usize, 0), lex.len);
    const sem = try h.recall(testing.allocator, .{ .about = "outage", .limit = 2 });
    defer freeHits(testing.allocator, sem);
    try testing.expectEqual(@as(usize, 1), sem.len);
}

/// Opens, runs `body`, closes; then puts back the checkpoint from before
/// `body`, as if the process died before writing a new one.
fn crashAfter(tmp: *testing.TmpDir, body: *const fn (*Holo) anyerror!void) !void {
    const old = try tmp.dir.readFileAlloc(testing.io, "h/CKPT", testing.allocator, .unlimited);
    defer testing.allocator.free(old);
    {
        const h = try tmpHolo(tmp);
        defer h.close();
        try body(h);
    }
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "h/CKPT", .data = old });
}

test "replaying a forget after the checkpoint does not hang" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        const h = try tmpHolo(&tmp);
        defer h.close();
        for (0..20) |i| {
            var b: [32]u8 = undefined;
            _ = try h.remember("a", try std.fmt.bufPrint(&b, "note {d}", .{i}), .{});
        }
    }
    try crashAfter(&tmp, struct {
        fn f(h: *Holo) !void {
            try h.forget(3);
        }
    }.f);
    const h = try tmpHolo(&tmp);
    defer h.close();
    try testing.expect(h.forgotten.get(3));
    try testing.expect((try h.get(testing.allocator, 3)) == null);
}

test "replayed forgetScope leaves later memories, settle survives a forgotten summary" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        const h = try tmpHolo(&tmp);
        defer h.close();
        _ = try h.remember("keep", "anchor", .{});
    }
    try crashAfter(&tmp, struct {
        fn f(h: *Holo) !void {
            _ = try h.remember("gone", "first life", .{});
            _ = try h.forgetScope("gone");
            _ = try h.remember("gone", "second life", .{});
            _ = try h.remember("s", "old detail one", .{});
            _ = try h.remember("s", "old detail two", .{});
            const sum = try h.settle("s", "summary of s");
            try h.forget(sum);
            _ = try h.remember("s", "after the summary", .{});
        }
    }.f);
    try tmp.dir.deleteFile(testing.io, "h/CKPT");
    const h = try tmpHolo(&tmp);
    defer h.close();
    const g = try h.recent(testing.allocator, "gone", 10);
    defer freeMemories(testing.allocator, g);
    try testing.expectEqual(@as(usize, 1), g.len);
    try testing.expectEqualStrings("second life", g[0].text);
    const hits = try h.recall(testing.allocator, .{ .about = "old detail", .scope = "s" });
    defer freeHits(testing.allocator, hits);
    try testing.expectEqual(@as(usize, 0), hits.len);
    const after = try h.recall(testing.allocator, .{ .about = "after summary", .scope = "s" });
    defer freeHits(testing.allocator, after);
    try testing.expectEqual(@as(usize, 1), after.len);
}

test "rebuilt index finds text when forgotten gaps shift scope ids" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        const h = try tmpHolo(&tmp);
        defer h.close();
        _ = try h.remember("a", "one", .{});
        const two = try h.remember("a", "two", .{});
        try h.forget(two);
        _ = try h.remember("b", "three", .{});
    }
    try tmp.dir.deleteFile(testing.io, "h/CKPT");
    const h = try tmpHolo(&tmp);
    defer h.close();
    const m = (try h.get(testing.allocator, 2)).?;
    defer m.deinit(testing.allocator);
    try testing.expectEqualStrings("three", m.text);
}

test "global recall finds any kept term, recent returns more than 256" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const h = try tmpHolo(&tmp);
    defer h.close();
    for (0..400) |i| {
        var b: [32]u8 = undefined;
        _ = try h.remember("r", try std.fmt.bufPrint(&b, "row {d}", .{i}), .{});
    }
    // 20 distinct words: all kept, all searchable from a global query.
    _ = try h.remember("w", "alpha bravo charlie delta echo foxtrot golf hotel india juliet kilo lima mike november oscar papa quebec romeo sierra tango", .{});
    for ([_][]const u8{ "alpha", "november", "tango" }) |w| {
        const hits = try h.recall(testing.allocator, .{ .about = w });
        defer freeHits(testing.allocator, hits);
        try testing.expectEqual(@as(usize, 1), hits.len);
    }
    const all = try h.recent(testing.allocator, "r", 500);
    defer freeMemories(testing.allocator, all);
    try testing.expectEqual(@as(usize, 400), all.len);
}

test "a write that is too large changes nothing" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const h = try tmpHolo(&tmp);
    defer h.close();
    _ = try h.remember("p", "plan A", .{ .subject = "plan" });
    const big = try testing.allocator.alloc(u8, record.max_value_len);
    defer testing.allocator.free(big);
    @memset(big, 'x');
    try testing.expectError(error.TooLarge, h.remember("p", big, .{ .subject = "plan" }));
    const cur = (try h.current(testing.allocator, "p", "plan")).?;
    defer cur.deinit(testing.allocator);
    try testing.expectEqualStrings("plan A", cur.text);
}

test "brief leaves replaced memories out of the recent section" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const h = try tmpHolo(&tmp);
    defer h.close();
    _ = try h.remember("p", "deploy target is staging", .{ .subject = "target" });
    _ = try h.remember("p", "deploy target is production", .{ .subject = "target" });
    const b = try h.brief(testing.allocator, "unrelated question", "p", 2000);
    defer b.deinit(testing.allocator);
    try testing.expect(std.mem.indexOf(u8, b.text, "production") != null);
    try testing.expect(std.mem.indexOf(u8, b.text, "staging") == null);
}
