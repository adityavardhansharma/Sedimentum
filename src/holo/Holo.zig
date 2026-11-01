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
const text = @import("text.zig");

const Holo = @This();

pub const Kv = streams.V3;

pub const page_rows = 128;
pub const max_terms = 32;
const bloom_words = 64; // 4096 bits
const none: u32 = std.math.maxInt(u32);
const map_reserve: usize = 1 << 38;
const page_align = std.heap.page_size_min;
/// Checkpoint after this many new rows.
const checkpoint_every: u32 = 1 << 18;
/// Width of each count-min row: 4 x 128k counters, 2 MB.
const cms_bits = 17;

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
    /// How fast recency fades in ranking. Old memories never drop below 60%.
    half_life_ms: u64 = 7 * 24 * 3600 * 1000,
    shards: ?usize = null,
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
    buried: bool,
};

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
    const cms = try gpa.alloc(u32, 4 << cms_bits);
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

fn cmsSlots(x: u64) [4]usize {
    const mask = (1 << cms_bits) - 1;
    var out: [4]usize = undefined;
    // Two hashes give four independent-enough rows (Kirsch-Mitzenmacher).
    const h1: u64 = x;
    const h2: u64 = (x >> 32) | (x << 32) | 1;
    inline for (0..4) |r| out[r] = (r << cms_bits) | @as(usize, @intCast((h1 +% r *% h2) >> 20 & mask));
    return out;
}

fn df(h: *const Holo, x: u64) u32 {
    const sl = cmsSlots(x);
    var m: u32 = std.math.maxInt(u32);
    inline for (0..4) |r| m = @min(m, h.cms[sl[r]]);
    return m;
}

/// Conservative update: only the counters at the current minimum grow, so
/// common words don't inflate the counts of rare ones.
fn bumpDf(h: *Holo, x: u64) void {
    const sl = cmsSlots(x);
    var m: u32 = std.math.maxInt(u32);
    inline for (0..4) |r| m = @min(m, h.cms[sl[r]]);
    inline for (0..4) |r| {
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
fn applyRow(h: *Holo, scope_name: []const u8, subject: []const u8, time: u64, body: []const u8, ts: *const text.TermSet) !u32 {
    const gpa = h.gpa;
    const id = h.count;
    if (id == none) return error.Full;
    const scope = try h.intern(scope_name);

    // Keep the rarest terms: they are what tells memories apart.
    var dfs: [text.TermSet.cap]u32 = undefined;
    var order: [text.TermSet.cap]u16 = undefined;
    for (ts.hashes[0..ts.len], 0..) |x, i| {
        order[i] = @intCast(i);
        if (ts.len > max_terms) dfs[i] = h.df(x);
    }
    const nt = @min(ts.len, max_terms);
    if (ts.len > max_terms) {
        const Ctx = struct {
            d: []const u32,
            fn lt(c: @This(), a: u16, b: u16) bool {
                return c.d[a] < c.d[b];
            }
        };
        std.mem.sortUnstable(u16, order[0..ts.len], Ctx{ .d = dfs[0..ts.len] }, Ctx.lt);
    }

    var r: Row = .{
        .terms = @splat(0),
        .time = time,
        .subj = if (subject.len > 0) @truncate(std.hash.Wyhash.hash(1, subject)) else 0,
        .scope = scope,
        .prev = h.heads.items[scope],
        .len = @intCast(body.len),
        .sim = simhash(&ts.hashes, order[0..nt]),
        .nterms = @intCast(nt),
        .kind = 0,
    };
    for (0..nt) |i| r.terms[i] = text.tag(ts.hashes[order[i]]);
    for (ts.hashes[0..ts.len]) |x| h.bumpDf(x);
    h.total_terms += ts.total;

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
    for (0..nt) |i| {
        const bit = text.bloomBit(ts.hashes[order[i]]);
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

fn memKey(buf: *[24]u8, id: u32) []const u8 {
    return std.fmt.bufPrint(buf, "~m/{x:0>6}/{x:0>8}", .{ id >> 12, id }) catch unreachable;
}

fn opKey(buf: *[32]u8, seq: u64) []const u8 {
    return std.fmt.bufPrint(buf, "~o/{x:0>10}/{x:0>16}", .{ seq >> 12, seq }) catch unreachable;
}

fn encodeValue(gpa: Allocator, scope: []const u8, subject: []const u8, time: u64, body: []const u8) ![]u8 {
    const v = try gpa.alloc(u8, 2 + scope.len + 2 + subject.len + 8 + body.len);
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
    return v;
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
    var ts: text.TermSet = .{};
    ts.fill(body);
    const value = try encodeValue(h.gpa, scope, subject, time, body);
    defer h.gpa.free(value);

    h.lock.lockUncancelable(h.io);
    const id = h.applyRow(scope, subject, time, body, &ts) catch |e| {
        h.lock.unlock(h.io);
        return e;
    };
    // The put happens under the lock so ids reach the store in order;
    // durable writes wait for their sync (group commit) after unlocking.
    var kb: [24]u8 = undefined;
    const want_ckpt = h.count - h.ckpt_count >= checkpoint_every;
    const put_err = h.kv.put(memKey(&kb, id), value);
    h.lock.unlock(h.io);
    try put_err;
    if (h.options.sync_writes) try h.kv.sync();
    if (want_ckpt) try h.checkpoint();
    return id;
}

/// Makes every write so far durable.
pub fn sync(h: *Holo) !void {
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
    try h.kv.delete(memKey(&kb, id));
}

/// Forgets every memory in a scope and below it. Returns how many.
pub fn forgetScope(h: *Holo, scope: []const u8) !usize {
    if (scope.len == 0) return error.InvalidScope;
    h.lock.lockUncancelable(h.io);
    defer h.lock.unlock(h.io);
    const n = try h.forgetScopeLocked(scope);
    const op = try h.gpa.alloc(u8, 1 + scope.len);
    defer h.gpa.free(op);
    op[0] = 2;
    @memcpy(op[1..], scope);
    try h.logOp(op);
    return n;
}

fn forgetScopeLocked(h: *Holo, scope: []const u8) !usize {
    var set = try h.scopeSet(h.gpa, scope);
    defer set.deinit(h.gpa);
    var n: usize = 0;
    for (0..h.scope_offs.items.len) |i| {
        const sid: u32 = @intCast(i);
        if (!set.has(sid)) continue;
        var p = h.heads.items[sid];
        while (p != none) : (p = h.row(p).prev) {
            if (h.forgotten.get(p)) continue;
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
    h.sinkLocked(id);
    const op = try h.gpa.alloc(u8, 5);
    defer h.gpa.free(op);
    op[0] = 3;
    std.mem.writeInt(u32, op[1..5], id, .little);
    try h.logOp(op);
    return id;
}

fn sinkLocked(h: *Holo, summary_id: u32) void {
    if (summary_id >= h.count) return;
    var p = h.row(summary_id).prev;
    while (p != none) : (p = h.row(p).prev) h.buried.set(p);
}

// ----------------------------------------------------------------- reads

/// One memory by id, or null if it was forgotten.
pub fn get(h: *Holo, gpa: Allocator, id: u32) !?Memory {
    var kb: [24]u8 = undefined;
    const raw = (try h.kv.get(gpa, memKey(&kb, id))) orelse return null;
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
    var ids_buf: [256]u32 = undefined;
    const want = @min(n, ids_buf.len);
    var k: usize = 0;
    {
        h.lock.lockSharedUncancelable(h.io);
        defer h.lock.unlockShared(h.io);
        if (h.findScope(scope)) |sid| {
            var p = h.heads.items[sid];
            while (p != none and k < want) : (p = h.row(p).prev) {
                if (h.forgotten.get(p)) continue;
                ids_buf[k] = p;
                k += 1;
            }
        }
    }
    var out: std.ArrayList(Memory) = .empty;
    errdefer {
        for (out.items) |m| m.deinit(gpa);
        out.deinit(gpa);
    }
    try h.fetch(gpa, ids_buf[0..k], &out);
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

const QTerm = struct { tag: u16, bit: u12, idf: f32, hash: u64 };

const Cand = struct { id: u32, score: f32 };

fn recency(h: *const Holo, now: u64, t: u64) f32 {
    const age: f32 = @floatFromInt(now -| t);
    const hl: f32 = @floatFromInt(@max(h.options.half_life_ms, 1));
    return 0.6 + 0.4 * @exp2(-age / hl);
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

fn rowScore(r: *const Row, q: []const QTerm) f32 {
    const V = @Vector(max_terms, u16);
    const tags: V = r.terms;
    var s: f32 = 0;
    for (q) |t| {
        const hit = tags == @as(V, @splat(t.tag));
        if (@reduce(.Or, hit)) s += t.idf;
    }
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
    var qt_buf: [8]QTerm = undefined;
    var cands_buf: [256]Cand = undefined;
    const pool = @min(cands_buf.len, @max(limit * 4, 16));
    var top: TopK = .{ .items = cands_buf[0..pool] };
    var nq: usize = 0;
    var avg_len: f32 = 1;
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
        nq = @min(ts.len, qt_buf.len);
        @memcpy(qt_buf[0..nq], all[0..nq]);
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
                    const base = rowScore(r, qt);
                    if (base == 0) continue;
                    const pg = p / page_rows;
                    top.push(.{ .id = p, .score = base * h.recency(now, r.time) * heatBoost(h.heat.items[pg]) * subjBoost(r) });
                }
            }
        } else {
            var qsum: f32 = 0;
            for (qt) |t| qsum += t.idf;
            var pi = h.pages.items.len;
            while (pi > 0) {
                pi -= 1;
                const pg = &h.pages.items[pi];
                if (pg.smask & set.mask == 0) continue;
                if (pg.tmax < q.since) continue;
                const best_rec = h.recency(now, pg.tmax) * 1.3 * 1.3;
                // Prune against the limit-th best (with slack for the rerank),
                // not the whole pool.
                const fl = @max(top.floor(), top.kth(limit) * 0.75);
                if (nq == 0) {
                    if (top.len == top.items.len) break;
                } else {
                    // Nothing older can beat the current top: stop.
                    if (top.len == top.items.len and qsum * best_rec <= fl) break;
                    var bound: f32 = 0;
                    for (qt) |t| {
                        if (pg.bloom[t.bit / 64] & (@as(u64, 1) << @intCast(t.bit % 64)) != 0) bound += t.idf;
                    }
                    if (bound == 0 or bound * best_rec * heatBoost(h.heat.items[pi]) <= fl) continue;
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
                    const base = rowScore(r, qt);
                    if (base == 0) continue;
                    top.push(.{ .id = id, .score = base * h.recency(now, r.time) * heatBoost(h.heat.items[pi]) * subjBoost(r) });
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
        if (nq > 0) {
            var mt: text.TermSet = .{};
            mt.fill(m.text);
            var bm: f32 = 0;
            const dl: f32 = @floatFromInt(mt.total);
            for (qt_buf[0..nq]) |t| {
                for (mt.hashes[0..mt.len], 0..) |x, i| if (x == t.hash) {
                    const tf: f32 = @floatFromInt(mt.tf[i]);
                    bm += t.idf * tf * 2.2 / (tf + 1.2 * (0.25 + 0.75 * dl / @max(avg_len, 1)));
                    break;
                };
            }
            if (bm == 0) {
                m.deinit(gpa);
                continue;
            }
            const r = blk: {
                h.lock.lockSharedUncancelable(h.io);
                defer h.lock.unlockShared(h.io);
                break :blk h.row(c.id).*;
            };
            score = bm * h.recency(now, m.time) * subjBoost(&r);
        }
        try hits.append(gpa, .{ .memory = m, .score = score, .buried = h.buried.get(c.id) });
    }
    const Ctx = struct {
        fn gt(_: void, a: Hit, b: Hit) bool {
            return a.score > b.score;
        }
    };
    std.mem.sortUnstable(Hit, hits.items, {}, Ctx.gt);
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

fn subjBoost(r: *const Row) f32 {
    return if (r.subj != 0) 1.3 else 1.0;
}

/// A briefing for an agent: the memories that matter for `situation`,
/// newest decisions first, near-copies merged, never over `budget` tokens
/// (estimated at 4 bytes per token).
pub fn brief(h: *Holo, gpa: Allocator, situation: []const u8, scope: []const u8, budget: usize) !Brief {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    const hits = try h.recall(gpa, .{ .about = situation, .scope = scope, .limit = 24 });
    defer freeHits(gpa, hits);
    const rec = if (h.isExactScope(scope)) try h.recent(gpa, scope, 6) else try gpa.alloc(Memory, 0);
    defer freeMemories(gpa, rec);

    var used: usize = 0;
    var items: usize = 0;
    var seen: [64]u32 = undefined;
    var nseen: usize = 0;
    const now = h.nowMs();
    const Section = struct { title: []const u8, mems: []const Memory };
    var rel: [24]Memory = undefined;
    for (hits, 0..) |x, i| rel[i] = x.memory;
    const sections = [_]Section{
        .{ .title = "Relevant memory", .mems = rel[0..hits.len] },
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
    return .{ .text = try out.toOwnedSlice(gpa), .tokens = used, .items = items, .buried_skipped = 0 };
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
    h.lock.lockUncancelable(h.io);
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
    var sk: [24]u8 = undefined;
    const start = memKey(&sk, h.count);
    var it = try h.kv.iterator(.{ .start = start, .end = "~m0" }, null);
    defer it.deinit();
    while (try it.next()) |p| {
        const slash = std.mem.lastIndexOfScalar(u8, p.key, '/') orelse return error.Corrupt;
        const id = std.fmt.parseInt(u32, p.key[slash + 1 ..], 16) catch return error.Corrupt;
        if (id < h.count) continue;
        while (h.count < id) try h.placeholder();
        const copy = try gpa.dupe(u8, p.value);
        defer gpa.free(copy);
        const m = try decodeValue(id, copy);
        var ts: text.TermSet = .{};
        ts.fill(m.text);
        _ = try h.applyRow(m.scope, m.subject, m.time, m.text, &ts);
        changed = true;
    }
    var ok: [32]u8 = undefined;
    const ostart = opKey(&ok, h.ops_seq + 1);
    var oit = try h.kv.iterator(.{ .start = ostart, .end = "~o0" }, null);
    defer oit.deinit();
    while (try oit.next()) |p| {
        const v = p.value;
        if (v.len == 0) return error.Corrupt;
        switch (v[0]) {
            1, 3 => {
                if (v.len != 5) return error.Corrupt;
                const id = std.mem.readInt(u32, v[1..5], .little);
                while (h.count <= id) try h.placeholder();
                if (v[0] == 1) try h.forgetLocked(id) else h.sinkLocked(id);
            },
            2 => _ = try h.forgetScopeLocked(v[1..]),
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
    const id = try h.applyRow("~", "", 0, "", &ts);
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
