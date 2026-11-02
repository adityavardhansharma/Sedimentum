//! Stratum: the memory structure behind Sedimentum.
//!
//! A stratum is one fact over its whole life. Its newest version is what a
//! question gets back; every older version stays underneath it as history;
//! and the words of every version lead to it. So a question asked in the
//! words of an old version ("billing runs on postgres 15") lands on the
//! current fact ("payments moved to postgres 16"), and a brief never holds
//! two versions of one fact.
//!
//! Layout. Each writer (agent process) appends to its own lane file; no two
//! writers share a byte. A record carries its text and up to 24 "threads":
//! a thread names one of the record's rarest words (24 bits of its hash)
//! and points back to the previous record in the same lane whose word fell
//! in the same one of 2^20 buckets. So every word's records form chains
//! through the lanes, newest first, and the files are their own index.
//!
//! A record also carries the id of its stratum's first version (`root`).
//! Versions join a stratum when they are written: by an explicit subject,
//! or by sharing at least three rare words with a memory in the same scope.
//! RAM holds a table from root to newest version for the strata that have
//! more than one version, and nothing at all for the rest.
//!
//! Everything in RAM (chain heads, word counts, scopes, subjects, strata)
//! can be rebuilt from the lane files, which are the only source of truth.
//! Records carry checksums: one for the metadata and one for the text, so
//! erasing text in place (forget) can never make a record unreadable.

const std = @import("std");
const Io = std.Io;
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Crc = std.hash.crc.@"CRC-32/ISCSI";
const text = @import("../holo/text.zig");
pub const Meaning = @import("../holo/Meaning.zig");
const tables = @import("tables.zig");

const Stratum = @This();

// ------------------------------------------------------------------ format

const bucket_bits = 20;
const nbuckets = 1 << bucket_bits;
/// Rarest words threaded per memory.
const term_threads = 24;
const data_start = 4096;
pub const max_lanes = 64;
/// Record offsets are u32 counts of 8 bytes, so a lane holds at most 32 GiB.
const map_reserve: usize = 1 << 35;
const snapshot_every: u64 = 256 << 20;
const close_snapshot_after: u64 = 32 << 20;
const cms_bits = 18;
const cms_rows = 2;
const lane_shift = 40;
/// Where a lane's header holds its published end.
const pub_end_at = 128;
/// Lanes grow in steps of a quarter of their size, 4 MB to 256 MB.
const grow_min: u64 = 4 << 20;
const grow_max: u64 = 256 << 20;

const Kind = enum(u8) { memory = 1, erased = 2, snapshot = 3, forget_scope = 4, settle = 5, forget_one = 6, _ };

/// Record header. Records start on 8-byte boundaries inside a lane.
const Hdr = extern struct {
    len: u32,
    /// CRC-32C of the header (but not `kind`), threads, scope and subject.
    crc: u32,
    kind: Kind,
    nthreads: u8,
    scope_len: u16,
    subject_len: u16,
    flags: u16,
    text_len: u32,
    nterms: u32,
    /// Write order across writers (microseconds of the real clock, never
    /// repeats, never goes back in one writer). Forget and settle cutoffs
    /// compare it, so a backdated `time` cannot slip under a cutoff.
    stamp: u64,
    /// When it happened (ms since the epoch), as the caller gave it.
    time: u64,
    scope_hash: u64,
    /// First version of this record's stratum; 0: it is the first.
    root: u64,
    /// Markers: the record or cutoff they apply to.
    target: u64,
    /// Previous record of the same scope in this lane (off8), 0: none.
    prev_scope: u32,
    /// CRC-32C of the text. A mismatch means the text was erased.
    text_crc: u32,
};
const hdr_len = @sizeOf(Hdr);
comptime {
    std.debug.assert(hdr_len == 72);
}

fn threadKey(t: u64) u32 {
    return @intCast(t & 0xff_ffff);
}
fn threadPrev(t: u64) u32 {
    return @intCast(t >> 24);
}
fn bucketOf(key: u32) u32 {
    return key & (nbuckets - 1);
}
fn termKey(h: u64) u32 {
    return @intCast(h >> 40);
}
fn idOf(lane: usize, off8: u32) u64 {
    return (@as(u64, lane) << lane_shift) | off8;
}
fn laneOf(id: u64) usize {
    return @intCast(id >> lane_shift);
}
fn offOf(id: u64) u32 {
    return @intCast(id & ((1 << lane_shift) - 1));
}

fn recordLen(nthreads: usize, scope: usize, subject: usize, body: usize) usize {
    return std.mem.alignForward(usize, hdr_len + nthreads * 8 + scope + subject + body, 8);
}

fn textStart(h: *const Hdr) usize {
    return hdr_len + @as(usize, h.nthreads) * 8 + h.scope_len + h.subject_len;
}

fn metaCrc(rec: []const u8, h: *const Hdr) u32 {
    var c = Crc.init();
    c.update(rec[0..4]);
    c.update(rec[9..textStart(h)]);
    return c.final();
}

fn scopeHash(name: []const u8) u64 {
    return std.hash.Wyhash.hash(0x5c09e, name);
}
fn subjectKey(scope_hash: u64, subject: []const u8) u64 {
    return std.hash.Wyhash.hash(scope_hash, subject);
}

// ------------------------------------------------------------------- state

pub const Options = struct {
    /// Every write is durable before it returns. Off: call `sync`.
    sync_writes: bool = true,
    /// How fast recency fades in ranking (old memories keep 85%).
    half_life_ms: u64 = 7 * 24 * 3600 * 1000,
    /// Word meanings; with them, questions in other words find memories.
    meaning: ?*const Meaning = null,
};

const Lane = struct {
    file: Io.File,
    map: []align(std.heap.page_size_min) const u8,
    /// Records before this offset are applied to the RAM tables.
    end: u64 = data_start,
    heads: []u32,

    /// The end its writer published: readers never look past it, so they
    /// never see a record that is still being written.
    fn published(l: *const Lane) u64 {
        const p: *const u64 = @ptrCast(@alignCast(l.map[pub_end_at..][0..8]));
        return @atomicLoad(u64, p, .acquire);
    }
};

/// A forget or settle that applies to a scope and everything below it.
const Rule = struct { kind: Kind, cutoff: u64, name: []u8 };

gpa: Allocator,
io: Io,
dir: Io.Dir,
options: Options,
clock_override: ?u64 = null,

/// One writer at a time (appends, refresh, forget).
wlock: tables.Lock = .{},
/// Readers take no lock: they only announce themselves here.
readers: tables.Readers = .{},
lanes: [max_lanes]Lane = undefined,
nlanes: usize = 0,
/// The lane this handle writes.
me: usize = 0,
/// End of our lane (bytes written).
end: std.atomic.Value(u64) = .init(data_start),
synced: std.atomic.Value(u64) = .init(data_start),

syncs: std.atomic.Value(u64) = .init(0),
last_refresh: std.atomic.Value(u64) = .init(0),
/// A failed write could not be undone: further writes are refused.
broken: bool = false,
/// Size of our lane file: space past `end` is reserved ahead, so writes
/// go straight into the map and a flush has no size change to record.
alloc: u64 = data_start,

cms: []u32,
count: u64 = 0,
total_terms: u64 = 0,
last_stamp: u64 = 0,
merges: u64 = 0,
snap_gen: u64 = 0,
/// Sum of lane ends at the last snapshot.
snap_progress: u64 = 0,
snap_end: u64 = data_start,

scopes: tables.Scopes = .{},
/// Scope name hash -> scope id.
scope_map: tables.Map = .{},
/// (scope id << 8 | lane) -> newest record of the scope in that lane.
scope_heads: tables.Map = .{},
rules: std.ArrayList(Rule) = .empty,
/// (scope, subject) -> newest record with that subject.
subjects: tables.Map = .{},
/// Stratum root -> its newest version, for strata with two or more.
strata: tables.Map = .{},
/// Single memories forgotten by id (value unused).
forgotten: tables.Map = .{},

fn laneName(buf: *[32]u8, i: usize) []const u8 {
    return std.fmt.bufPrint(buf, "lane-{d:0>3}.sdm", .{i}) catch unreachable;
}

pub fn open(gpa: Allocator, io: Io, parent: Io.Dir, sub_path: []const u8, options: Options) !*Stratum {
    var dir = try parent.createDirPathOpen(io, sub_path, .{});
    errdefer dir.close(io);
    const cms = try gpa.alloc(u32, cms_rows << cms_bits);
    errdefer gpa.free(cms);
    @memset(cms, 0);
    const w = try gpa.create(Stratum);
    errdefer gpa.destroy(w);
    w.* = .{ .gpa = gpa, .io = io, .dir = dir, .options = options, .cms = cms };
    errdefer w.freeAll();

    // Claim the first lane no other writer holds. The OS drops the lock if
    // its holder dies, so a crashed writer's lane is reused.
    var me: ?usize = null;
    var own: Io.File = undefined;
    for (0..max_lanes) |i| {
        var nb: [32]u8 = undefined;
        own = dir.createFile(io, laneName(&nb, i), .{ .read = true, .truncate = false, .lock = .exclusive, .lock_nonblocking = true }) catch |err| switch (err) {
            error.WouldBlock => continue,
            else => |e| return e,
        };
        me = i;
        break;
    }
    w.me = me orelse return error.TooManyWriters;
    {
        errdefer own.close(io);
        var len = try own.length(io);
        if (len < data_start) {
            const zeros: [data_start]u8 = @splat(0);
            try own.writePositionalAll(io, &zeros, 0);
            try own.sync(io);
            len = data_start;
        }
    }
    // Open every lane that exists (lanes are created in order, no gaps).
    var i: usize = 0;
    while (i < max_lanes) : (i += 1) {
        if (i == w.me) {
            try w.addLane(own, true);
            continue;
        }
        if (!try w.openLane(i)) break;
    }
    if (w.nlanes <= w.me) return error.Corrupt;
    w.alloc = try own.length(io);
    try w.loadTables();
    return w;
}

/// Builds the RAM tables from the newest snapshot and the records after it.
fn loadTables(w: *Stratum) !void {
    const from = w.loadSnapshot() catch blk: {
        // An unreadable snapshot is only lost speed: replay everything.
        w.resetTables();
        break :blk null;
    };
    // Our own lane first, so markers from other lanes can erase in it.
    try w.replayLane(w.me, if (from) |f| f[w.me] else data_start, true);
    for (0..w.laneCount()) |l| if (l != w.me) try w.replayLane(l, if (from) |f| f[l] else data_start, false);
    if (from != null) {
        // Markers inside the snapshot were never replayed here. Their
        // erasures in this lane may not have happened (its writer was
        // gone), so redo them; erasing is idempotent.
        for (w.rules.items) |r| if (r.kind == .forget_scope) try w.eraseScopeInOwnLane(r.name, r.cutoff);
        var it = w.forgotten.iterator();
        while (it.next()) |e| if (laneOf(e.key) == w.me) try w.eraseOwn(offOf(e.key));
    }
    w.end.store(w.lanes[w.me].end, .release);
    w.synced.store(w.lanes[w.me].end, .release);
    @atomicStore(u64, &w.snap_end, if (from) |f| @min(f[w.me], w.lanes[w.me].end) else data_start, .release);
}

/// After a write failed halfway, the RAM tables may point at records that
/// never reached the file: drop what was written of the batch and rebuild
/// the tables from disk. If that fails too, the handle refuses writes.
/// Caller holds the write lock.
fn recoverFailedWrite(w: *Stratum, start: u64, len: u64) void {
    @memset(w.ownBytes()[start..][0..len], 0);
    // Bytes before `start` that were never flushed must still be flushed
    // by the next sync.
    const synced = w.synced.load(.acquire);
    // Rebuilding changes the tables in place: keep readers out meanwhile.
    w.readers.close(w.io);
    defer w.readers.open(w.io);
    w.resetTables();
    w.loadTables() catch {
        w.broken = true;
    };
    w.synced.store(@min(synced, w.end.load(.acquire)), .release);
}

fn addLane(w: *Stratum, file: Io.File, writable: bool) !void {
    const map = try std.posix.mmap(null, map_reserve, .{ .READ = true, .WRITE = writable }, .{ .TYPE = .SHARED }, file.handle, 0);
    errdefer std.posix.munmap(map);
    const heads = try w.gpa.alloc(u32, nbuckets);
    @memset(heads, 0);
    w.lanes[w.nlanes] = .{ .file = file, .map = map, .heads = heads };
    @atomicStore(usize, &w.nlanes, w.nlanes + 1, .release);
}

/// Opens lane `i` for reading. False when it does not exist.
fn openLane(w: *Stratum, i: usize) !bool {
    var nb: [32]u8 = undefined;
    const f = w.dir.openFile(w.io, laneName(&nb, i), .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => |e| return e,
    };
    errdefer f.close(w.io);
    try w.addLane(f, false);
    return true;
}

fn resetTables(w: *Stratum) void {
    const gpa = w.gpa;
    for (w.lanes[0..w.nlanes]) |*l| {
        @memset(l.heads, 0);
        l.end = data_start;
    }
    @memset(w.cms, 0);
    w.count = 0;
    w.total_terms = 0;
    w.last_stamp = 0;
    w.merges = 0;
    w.scopes.clear(gpa);
    w.scope_map.clearRetainingCapacity(gpa);
    w.scope_heads.clearRetainingCapacity(gpa);
    for (w.rules.items) |r| gpa.free(r.name);
    w.rules.clearRetainingCapacity();
    w.subjects.clearRetainingCapacity(gpa);
    w.strata.clearRetainingCapacity(gpa);
    w.forgotten.clearRetainingCapacity(gpa);
}

fn freeAll(w: *Stratum) void {
    const gpa = w.gpa;
    for (w.lanes[0..w.nlanes]) |l| {
        gpa.free(l.heads);
        std.posix.munmap(l.map);
        l.file.close(w.io);
    }
    w.nlanes = 0;
    w.scopes.deinit(gpa);
    w.scope_map.deinit(gpa);
    w.scope_heads.deinit(gpa);
    for (w.rules.items) |r| gpa.free(r.name);
    w.rules.deinit(gpa);
    w.subjects.deinit(gpa);
    w.strata.deinit(gpa);
    w.forgotten.deinit(gpa);
}

pub fn close(w: *Stratum) void {
    // A snapshot holds every lane's chain heads (4 MB a lane): only worth
    // writing when this writer added a lot that reopening would replay.
    w.snapshotIfGrew(close_snapshot_after) catch {};
    // Give back the space reserved ahead. Readers never look past the
    // published end, which is at or before this.
    if (w.nlanes > w.me and !w.broken) w.lanes[w.me].file.setLength(w.io, w.lanes[w.me].end) catch {};
    const gpa = w.gpa;
    const cms = w.cms;
    w.freeAll();
    gpa.free(cms);
    w.dir.close(w.io);
    gpa.destroy(w);
}

fn progress(w: *const Stratum) u64 {
    var s: u64 = 0;
    for (w.lanes[0..w.nlanes]) |l| s += l.end;
    return s;
}

pub fn setClockForTest(w: *Stratum, ms: ?u64) void {
    w.clock_override = ms;
}

/// The next write stamp. Caller holds the write lock.
fn nextStamp(w: *const Stratum) u64 {
    const ns = Io.Clock.real.now(w.io).nanoseconds;
    const us: u64 = @intCast(@divTrunc(ns, std.time.ns_per_us));
    return @max(us, w.last_stamp + 1);
}

fn nowMs(w: *const Stratum) u64 {
    if (w.clock_override) |t| return t;
    const ns = Io.Clock.real.now(w.io).nanoseconds;
    return @intCast(@divTrunc(ns, std.time.ns_per_ms));
}

/// Bytes from a record's start: from its lane, or, for records of the
/// batch being written, from that batch's buffer.
fn bytesAt(w: *const Stratum, id: u64) []const u8 {
    const off = @as(usize, offOf(id)) << 3;
    return w.lanes[laneOf(id)].map[off..];
}
fn hdrAt(w: *const Stratum, id: u64) *const Hdr {
    return @ptrCast(@alignCast(w.bytesAt(id)[0..hdr_len]));
}
fn recBytes(w: *const Stratum, id: u64, h: *const Hdr) []const u8 {
    return w.bytesAt(id)[0..h.len];
}
fn threadsOf(w: *const Stratum, id: u64, h: *const Hdr) []align(1) const u64 {
    return std.mem.bytesAsSlice(u64, w.recBytes(id, h)[hdr_len..][0 .. @as(usize, h.nthreads) * 8]);
}
fn scopeOf(w: *const Stratum, id: u64, h: *const Hdr) []const u8 {
    return w.recBytes(id, h)[hdr_len + @as(usize, h.nthreads) * 8 ..][0..h.scope_len];
}
fn subjectOf(w: *const Stratum, id: u64, h: *const Hdr) []const u8 {
    return w.recBytes(id, h)[hdr_len + @as(usize, h.nthreads) * 8 + h.scope_len ..][0..h.subject_len];
}
fn textOf(w: *const Stratum, id: u64, h: *const Hdr) []const u8 {
    return w.recBytes(id, h)[textStart(h)..][0..h.text_len];
}

/// Is a record newer than another? By event time, then write order.
fn newer(w: *const Stratum, a: u64, b: u64) bool {
    const ha = w.hdrAt(a);
    const hb = w.hdrAt(b);
    if (ha.time != hb.time) return ha.time > hb.time;
    return ha.stamp > hb.stamp or (ha.stamp == hb.stamp and a > b);
}

/// Was a record written later than another? Each lane's chains are in
/// this order, so merging lanes by it is exact.
fn laterWrite(w: *const Stratum, a: u64, b: u64) bool {
    const sa = w.hdrAt(a).stamp;
    const sb = w.hdrAt(b).stamp;
    return sa > sb or (sa == sb and a > b);
}

fn rootOf(h: *const Hdr, id: u64) u64 {
    return if (h.root != 0) h.root else id;
}

// ------------------------------------------------------------------ scopes

pub fn scopeName(w: *const Stratum, id: u32) []const u8 {
    return w.scopes.name(id);
}

fn findScope(w: *const Stratum, name: []const u8) ?u32 {
    return if (w.scope_map.get(scopeHash(name))) |v| @intCast(v) else null;
}

fn laneCount(w: *const Stratum) usize {
    return @atomicLoad(usize, &w.nlanes, .acquire);
}

fn sidOf(w: *const Stratum, hash: u64) ?u32 {
    return if (w.scope_map.get(hash)) |v| @intCast(v) else null;
}

fn scopeHead(w: *const Stratum, sid: usize, lane: usize) u32 {
    return @intCast(w.scope_heads.get((@as(u64, sid) << 8) | lane) orelse 0);
}

/// Writer only: a table update that may free memory readers held.
fn mput(w: *Stratum, m: *tables.Map, k: u64, v: u64) !void {
    try m.put(w.gpa, &w.readers, w.io, k, v);
}

/// "a" covers "a" and everything under "a/".
fn inScope(name: []const u8, filter: []const u8) bool {
    if (filter.len == 0) return true;
    if (!std.mem.startsWith(u8, name, filter)) return false;
    return name.len == filter.len or name[filter.len] == '/';
}

fn intern(w: *Stratum, name: []const u8, hash: u64) !u32 {
    if (w.sidOf(hash)) |id| return id;
    // The scope first, then the map entry that leads readers to it.
    const id = try w.scopes.append(w.gpa, name, hash);
    try w.mput(&w.scope_map, hash, id);
    // Rules written before this scope was first seen still apply to it.
    for (w.rules.items) |r| if (inScope(name, r.name)) w.applyRule(id, r.kind, r.cutoff);
    return id;
}

fn applyRule(w: *Stratum, sid: u32, kind: Kind, cutoff: u64) void {
    switch (kind) {
        .forget_scope => w.scopes.raiseForgot(sid, cutoff),
        .settle => w.scopes.raiseSettled(sid, cutoff),
        else => {},
    }
}

fn addRule(w: *Stratum, kind: Kind, cutoff: u64, name: []const u8) !void {
    const copy = try w.gpa.dupe(u8, name);
    errdefer w.gpa.free(copy);
    try w.rules.append(w.gpa, .{ .kind = kind, .cutoff = cutoff, .name = copy });
    for (0..w.scopes.len()) |i| {
        const sid: u32 = @intCast(i);
        if (inScope(w.scopeName(sid), name)) w.applyRule(sid, kind, cutoff);
    }
}

const ScopeSet = struct {
    all: bool = false,
    bits: std.DynamicBitSetUnmanaged = .{},
    n: usize = 0,
    total: u64 = 0,

    fn has(s: *const ScopeSet, id: u32) bool {
        return s.all or (id < s.bits.bit_length and s.bits.isSet(id));
    }
    fn deinit(s: *ScopeSet, gpa: Allocator) void {
        s.bits.deinit(gpa);
    }
};

fn scopeSet(w: *const Stratum, gpa: Allocator, filter: []const u8) !ScopeSet {
    if (filter.len == 0) return .{ .all = true, .total = w.count };
    const ns = w.scopes.len();
    var s: ScopeSet = .{ .bits = try .initEmpty(gpa, ns) };
    for (0..ns) |i| {
        const id: u32 = @intCast(i);
        if (inScope(w.scopeName(id), filter)) {
            s.bits.set(i);
            s.n += 1;
            s.total += w.scopes.countOf(i);
        }
    }
    return s;
}

// ------------------------------------------------------------- statistics

fn cmsSlots(x: u64) [cms_rows]usize {
    var out: [cms_rows]usize = undefined;
    for (&out, 0..) |*o, r| o.* = (r << cms_bits) | @as(usize, @intCast((x >> @intCast(r * 21 + 3)) & ((1 << cms_bits) - 1)));
    return out;
}

fn df(w: *const Stratum, x: u64) u32 {
    // (Counts change without the write lock: see `bumpDf`.)
    var m: u32 = std.math.maxInt(u32);
    for (cmsSlots(x)) |s| m = @min(m, @atomicLoad(u32, &w.cms[s], .monotonic));
    return m;
}

/// Counts one more memory with this word. Safe without the write lock: a
/// count that moved meanwhile is left alone (counts are estimates).
fn bumpDf(w: *Stratum, x: u64) void {
    const slots = cmsSlots(x);
    const m = w.df(x);
    if (m == std.math.maxInt(u32)) return;
    for (slots) |s| {
        _ = @cmpxchgStrong(u32, &w.cms[s], m, m + 1, .monotonic, .monotonic);
    }
}

fn idf(w: *const Stratum, x: u64) f32 {
    const n: f32 = @floatFromInt(@max(w.count, 1));
    const d: f32 = @floatFromInt(w.df(x));
    return @log(1.0 + (n - d + 0.5) / (d + 0.5));
}

// ------------------------------------------------------- applying records

/// Is this memory readable: not erased, not forgotten?
fn alive(w: *const Stratum, id: u64, h: *const Hdr) bool {
    if (h.kind != .memory) return false;
    if (w.forgotten.contains(id)) return false;
    const sid = w.sidOf(h.scope_hash) orelse return false;
    if (h.stamp < w.scopes.forgot(sid)) return false;
    return Crc.hash(w.textOf(id, h)) == h.text_crc;
}

/// Replaced by a newer version of its fact, or settled.
fn isBuried(w: *const Stratum, id: u64, h: *const Hdr) bool {
    const sid = w.sidOf(h.scope_hash) orelse return false;
    if (h.stamp < w.scopes.settled(sid)) return true;
    const head = w.headOf(id, h);
    return head != id;
}

/// The newest live version of a memory's fact: through its subject (which
/// links versions even when two writers wrote them without seeing each
/// other) and its stratum. The memory itself when it is the newest, or
/// when the newer one was forgotten.
fn headOf(w: *const Stratum, id: u64, h: *const Hdr) u64 {
    var head = id;
    if (h.subject_len > 0) {
        if (w.subjects.get(subjectKey(h.scope_hash, w.subjectOf(id, h)))) |s| {
            if (s != id and w.alive(s, w.hdrAt(s)) and w.newer(s, id)) head = s;
        }
    }
    const hh = w.hdrAt(head);
    const sh = w.strata.get(rootOf(hh, head)) orelse return head;
    if (sh == head or !w.alive(sh, w.hdrAt(sh)) or !w.newer(sh, head)) return head;
    return sh;
}

/// Updates the RAM tables for one valid record. `hashes`: the text's terms,
/// when the caller already has them.
fn apply(w: *Stratum, lane: usize, off8: u32, h: *const Hdr, hashes: ?[]const u64) !void {
    const id = idOf(lane, off8);
    w.last_stamp = @max(w.last_stamp, h.stamp);
    switch (h.kind) {
        .memory, .erased => {
            const sid = try w.intern(w.scopeOf(id, h), h.scope_hash);
            for (w.threadsOf(id, h)) |t| @atomicStore(u32, &w.lanes[lane].heads[bucketOf(threadKey(t))], off8, .release);
            try w.mput(&w.scope_heads, (@as(u64, sid) << 8) | lane, off8);
            w.scopes.bump(sid);
            try w.linkVersions(id, h, w.subjectOf(id, h));
            if (h.kind == .memory) {
                if (hashes) |hs| {
                    for (hs) |x| w.bumpDf(x);
                } else {
                    var ts: text.TermSet = .{};
                    ts.fill(w.textOf(id, h));
                    for (ts.hashes[0..ts.len]) |x| w.bumpDf(x);
                }
            }
            w.count += 1;
            w.total_terms += h.nterms;
        },
        .forget_scope, .settle => {
            const name = w.recBytes(id, h)[hdr_len..][0..h.scope_len];
            try w.addRule(h.kind, h.target, name);
            // Erasing is idempotent: redo it, in case the erase was cut
            // short by a crash, or the marker came from another writer.
            if (h.kind == .forget_scope) try w.eraseScopeInOwnLane(name, h.target);
        },
        .forget_one => {
            try w.mput(&w.forgotten, h.target, 1);
            if (laneOf(h.target) == w.me) try w.eraseOwn(offOf(h.target));
        },
        .snapshot => {},
        _ => {},
    }
}

/// The record at `pos` if it is complete and its metadata checks out.
fn validAt(w: *const Stratum, lane: usize, pos: u64, len: u64) ?*const Hdr {
    if (pos + hdr_len > len) return null;
    const m = w.lanes[lane].map;
    const h: *const Hdr = @ptrCast(@alignCast(m[pos..][0..hdr_len]));
    if (h.len < hdr_len or h.len % 8 != 0 or pos + h.len > len) return null;
    if (textStart(h) + h.text_len > h.len) return null;
    if (metaCrc(m[pos..][0..h.len], h) != h.crc) return null;
    return h;
}

/// Applies a lane's records from `from` on. Our own lane is cut at the
/// first bad record (a write torn by a crash); another writer's lane is
/// read up to there and picked up again later.
fn replayLane(w: *Stratum, lane: usize, from: u64, own: bool) !void {
    const size = try w.lanes[lane].file.length(w.io);
    // Another writer's lane: only what it published (it may be writing
    // past that). A lane that never published is read by its records.
    const published = if (own) 0 else w.lanes[lane].published();
    const len = if (published >= data_start) @min(published, size) else size;
    var pos = @max(from, data_start);
    while (w.validAt(lane, pos, len)) |h| {
        try w.apply(lane, @intCast(pos >> 3), h, null);
        pos += h.len;
        @atomicStore(u64, &w.lanes[lane].end, pos, .release);
    }
    @atomicStore(u64, &w.lanes[lane].end, pos, .release);
    if (own) {
        // A crash can leave a torn record: zero it, up to the reserved
        // space that was never written.
        const m = w.ownBytes();
        var p = pos;
        while (p < size) {
            const n = @min(size - p, 64 << 10);
            const chunk = m[p..][0..n];
            if (std.mem.allEqual(u8, chunk, 0)) break;
            @memset(chunk, 0);
            p += n;
        }
        w.publish();
    }
}

/// Picks up what other writers appended since we last looked, and lanes
/// that appeared since. Cheap when nothing changed.
pub fn refresh(w: *Stratum) !void {
    w.wlock.lockUncancelable(w.io);
    defer w.wlock.unlock(w.io);
    try w.refreshLocked();
}

fn refreshLocked(w: *Stratum) !void {
    while (w.nlanes < max_lanes) {
        if (!try w.openLane(w.nlanes)) break;
    }
    for (0..w.laneCount()) |l| if (l != w.me) try w.replayLane(l, w.lanes[l].end, false);
}

/// Picks up other writers' new records as soon as they are published, and
/// looks for new writers at most every 20 ms.
fn maybeRefresh(w: *Stratum) !void {
    // Another writer published more: pick it up now (a few loads).
    const n = @atomicLoad(usize, &w.nlanes, .acquire);
    for (0..n) |l| {
        if (l != w.me and w.lanes[l].published() > @atomicLoad(u64, &w.lanes[l].end, .acquire)) return w.refresh();
    }
    // New lanes need a look at the directory: at most every 20 ms.
    const now = w.nowMsReal();
    const last = w.last_refresh.load(.monotonic);
    if (now -% last < 20 and now >= last) return;
    if (w.last_refresh.cmpxchgStrong(last, now, .monotonic, .monotonic) != null) return;
    try w.refresh();
}

fn nowMsReal(w: *const Stratum) u64 {
    const ns = Io.Clock.awake.now(w.io).nanoseconds;
    return @intCast(@divTrunc(ns, std.time.ns_per_ms));
}

// ------------------------------------------------------------------ writes

pub const RememberOptions = struct {
    /// A newer memory with the same subject in the same scope is a newer
    /// version of the same fact.
    subject: ?[]const u8 = null,
    /// Milliseconds since the epoch. Null: now.
    time: ?u64 = null,
};

pub const Item = struct {
    scope: []const u8,
    text: []const u8,
    subject: ?[]const u8 = null,
    time: ?u64 = null,
};

fn validate(scope: []const u8, subject: []const u8, body: []const u8) !void {
    if (scope.len == 0 or scope.len > 1024) return error.InvalidScope;
    if (subject.len > 1024) return error.InvalidSubject;
    if (body.len > 64 << 20) return error.TooLarge;
}

/// A memory's threads: its rarest words, rarest first. Caller holds the
/// write lock (df reads).
fn chooseThreads(w: *const Stratum, hashes: []const u64, keys: *[term_threads]u32, dfs: *[term_threads]u32) usize {
    var order: [text.TermSet.cap]u16 = undefined;
    var all: [text.TermSet.cap]u32 = undefined;
    for (hashes, 0..) |x, i| {
        order[i] = @intCast(i);
        all[i] = w.df(x);
    }
    const Ctx = struct {
        d: []const u32,
        fn lt(c: @This(), a: u16, b: u16) bool {
            return c.d[a] < c.d[b];
        }
    };
    std.mem.sortUnstable(u16, order[0..hashes.len], Ctx{ .d = all[0..hashes.len] }, Ctx.lt);
    const n = @min(hashes.len, term_threads);
    for (order[0..n], 0..) |i, k| {
        keys[k] = termKey(hashes[i]);
        dfs[k] = all[i];
    }
    return n;
}

/// Rare enough that sharing three such words is not chance.
fn rareLimit(w: *const Stratum) u32 {
    return @intCast(@max(2, w.count / 2000));
}

/// The stratum a new memory without a subject continues, if any: a live
/// memory in the same scope that shares at least three of its rare words
/// and at least half of them. Caller holds the write lock.
fn findLineage(w: *const Stratum, scope_hash: u64, keys: []const u32, dfs: []const u32) ?u64 {
    // In a nearly empty store every word looks rare.
    if (w.count < 1000) return null;
    const lim = w.rareLimit();
    var nrare: usize = 0;
    while (nrare < keys.len and dfs[nrare] <= lim) nrare += 1;
    if (nrare < 3) return null;
    const rare = keys[0..nrare];
    var best: ?u64 = null;
    var best_shared: usize = 0;
    // Follow the two rarest words seen before (brand-new words have no
    // chain yet).
    var walked: usize = 0;
    for (rare, dfs[0..nrare]) |key, d| {
        if (d == 0) continue;
        if (walked == 2) break;
        walked += 1;
        const b = bucketOf(key);
        for (0..w.laneCount()) |lane| {
            var p = w.lanes[lane].heads[b];
            var steps: usize = 0;
            while (p != 0 and steps < 64) : (steps += 1) {
                const id = idOf(lane, p);
                const h = w.hdrAt(id);
                const ts = w.threadsOf(id, h);
                var next: u32 = 0;
                for (ts) |t| if (bucketOf(threadKey(t)) == b) {
                    next = threadPrev(t);
                    break;
                };
                if (h.kind == .memory and h.scope_hash == scope_hash) {
                    var shared: usize = 0;
                    for (rare) |k| {
                        for (ts) |t| if (threadKey(t) == k) {
                            shared += 1;
                            break;
                        };
                    }
                    if (shared >= 3 and shared * 2 >= nrare and (shared > best_shared or (shared == best_shared and best != null and w.newer(id, best.?)))) {
                        if (w.alive(id, h)) {
                            best = id;
                            best_shared = shared;
                        }
                    }
                }
                p = next;
            }
        }
    }
    return best;
}

/// Encodes one memory at `off` of our lane into `buf`, picks its stratum
/// and applies it. Caller holds the write lock, then writes `buf` at `off`.
/// `lineage`: the version this memory continues, when the caller already
/// looked it up (null: look it up now).
/// `hashes`: the memory's words, counted here unless null (counted by the
/// caller outside the lock).
fn encode(w: *Stratum, buf: []u8, off: u64, it: Item, now: u64, hashes: ?[]const u64, total: u32, keys: []const u32, dfs: []const u32, lineage: ??u64) !void {
    const subject = it.subject orelse "";
    const sh = scopeHash(it.scope);
    const nk = keys.len;

    var root: u64 = 0;
    if (subject.len > 0) {
        if (w.subjects.get(subjectKey(sh, subject))) |prev| root = rootOf(w.hdrAt(prev), prev);
    } else if (lineage orelse w.findLineage(sh, keys, dfs)) |prev| {
        root = rootOf(w.hdrAt(prev), prev);
        w.merges += 1;
    }

    const off8: u32 = @intCast(off >> 3);
    const stamp = w.nextStamp();
    const sid = try w.intern(it.scope, sh);
    const h: *Hdr = @ptrCast(@alignCast(buf[0..hdr_len]));
    h.* = .{
        .len = @intCast(buf.len),
        .crc = 0,
        .kind = .memory,
        .nthreads = @intCast(nk),
        .scope_len = @intCast(it.scope.len),
        .subject_len = @intCast(subject.len),
        .flags = 0,
        .text_len = @intCast(it.text.len),
        .nterms = total,
        .stamp = stamp,
        .time = it.time orelse now,
        .scope_hash = sh,
        .root = root,
        .target = 0,
        .prev_scope = w.scopeHead(sid, w.me),
        .text_crc = Crc.hash(it.text),
    };
    const ts = std.mem.bytesAsSlice(u64, buf[hdr_len..][0 .. nk * 8]);
    const heads = w.lanes[w.me].heads;
    for (keys, 0..) |k, i| {
        const b = bucketOf(k);
        var prev = heads[b];
        // An earlier thread of this record in the same bucket: share its link.
        for (0..i) |j| if (bucketOf(keys[j]) == b) {
            prev = threadPrev(ts[j]);
            break;
        };
        ts[i] = (@as(u64, prev) << 24) | k;
    }
    var p: usize = hdr_len + nk * 8;
    @memcpy(buf[p..][0..it.scope.len], it.scope);
    p += it.scope.len;
    @memcpy(buf[p..][0..subject.len], subject);
    p += subject.len;
    @memcpy(buf[p..][0..it.text.len], it.text);
    p += it.text.len;
    @memset(buf[p..], 0);
    h.crc = metaCrc(buf, h);
    // Only now, with the record complete, may readers reach it.
    for (keys) |k| @atomicStore(u32, &heads[bucketOf(k)], off8, .release);
    try w.applyWritten(off8, h);
    if (hashes) |hs| for (hs) |x| w.bumpDf(x);
}

/// `apply` for a record we just encoded (its threads are already linked).
fn applyWritten(w: *Stratum, off8: u32, h: *const Hdr) !void {
    const id = idOf(w.me, off8);
    w.last_stamp = @max(w.last_stamp, h.stamp);
    const buf: []const u8 = @as([*]const u8, @ptrCast(h))[0..h.len];
    const scope = buf[hdr_len + @as(usize, h.nthreads) * 8 ..][0..h.scope_len];
    const subject = buf[hdr_len + @as(usize, h.nthreads) * 8 + h.scope_len ..][0..h.subject_len];
    const sid = try w.intern(scope, h.scope_hash);
    try w.mput(&w.scope_heads, (@as(u64, sid) << 8) | w.me, off8);
    w.scopes.bump(sid);
    try w.linkVersions(id, h, subject);
    w.count += 1;
    w.total_terms += h.nterms;
}

/// Points the subject and the stratum at this version if it is the newest
/// (live writes and replay use the same rule, so importing an older
/// version never changes the current answer). Writer only.
fn linkVersions(w: *Stratum, id: u64, h: *const Hdr, subject: []const u8) !void {
    if (subject.len > 0) {
        const k = subjectKey(h.scope_hash, subject);
        const cur = w.subjects.get(k);
        if (cur == null or w.newer(id, cur.?)) try w.mput(&w.subjects, k, id);
    }
    if (h.root != 0) {
        const cur = w.strata.get(h.root) orelse h.root;
        if (w.newer(id, cur)) try w.mput(&w.strata, h.root, id) else if (w.strata.get(h.root) == null) try w.mput(&w.strata, h.root, cur);
    }
}

/// Saves a memory and returns its id.
pub fn remember(w: *Stratum, scope: []const u8, body: []const u8, opts: RememberOptions) !u64 {
    const items = [1]Item{.{ .scope = scope, .text = body, .subject = opts.subject, .time = opts.time }};
    return w.rememberMany(&items);
}

const max_workers = 8;

/// Saves many memories at once and returns the first id. Words are found
/// on every core; the records go to the file in one write.
pub fn rememberMany(w: *Stratum, items: []const Item) !u64 {
    if (items.len == 0) return idOf(w.me, @intCast(w.end.load(.acquire) >> 3));
    for (items) |it| try validate(it.scope, it.subject orelse "", it.text);
    const gpa = w.gpa;
    const now = w.nowMs();
    const nw: usize = if (items.len <= 256) 1 else @min(max_workers, @max(1, std.Thread.getCpuCount() catch 1), (items.len + 255) / 256);

    const Span = struct { start: u32, len: u32, total: u32 };
    const spans = try gpa.alloc(Span, items.len);
    defer gpa.free(spans);
    var pools: [max_workers]std.ArrayList(u64) = @splat(.empty);
    defer for (&pools) |*p| p.deinit(gpa);
    var errs: [max_workers]?anyerror = @splat(null);
    const per = (items.len + nw - 1) / nw;
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
    if (nw == 1) {
        Tok.run(items, spans, &pools[0], gpa, &errs[0]);
    } else {
        var threads: [max_workers]?std.Thread = @splat(null);
        for (0..nw) |i| {
            const lo = @min(items.len, i * per);
            const hi = @min(items.len, lo + per);
            const args = .{ items[lo..hi], spans[lo..hi], &pools[i], gpa, &errs[i] };
            threads[i] = std.Thread.spawn(.{}, Tok.run, args) catch null;
            if (threads[i] == null) @call(.auto, Tok.run, args);
        }
        for (threads[0..nw]) |t| if (t) |x| x.join();
    }
    for (errs) |e| if (e) |x| return x;

    var total: usize = 0;
    for (items) |it| total += recordLen(term_threads, it.scope.len, if (it.subject) |s| s.len else 0, it.text.len);
    // One memory (an agent's turn): pick its threads and find the fact it
    // continues before taking the write lock, as a reader. A batch does
    // this under the lock, so its memories can continue each other.
    const Pre = struct { keys: [term_threads]u32, dfs: [term_threads]u32, nk: usize, lineage: ?u64 };
    var pre: ?Pre = null;
    if (items.len == 1) {
        w.readers.enter(w.io);
        defer w.readers.leave(w.io);
        var x: Pre = undefined;
        const hashes = pools[0].items[spans[0].start..][0..spans[0].len];
        x.nk = w.chooseThreads(hashes, &x.keys, &x.dfs);
        x.lineage = if (items[0].subject == null) w.findLineage(scopeHash(items[0].scope), x.keys[0..x.nk], x.dfs[0..x.nk]) else null;
        pre = x;
    }

    const first = blk: {
        w.wlock.lockUncancelable(w.io);
        defer w.wlock.unlock(w.io);
        if (w.broken) return error.Broken;
        // Records are encoded in place, in the map: no copy, no system call.
        const start = try w.reserve(total);
        errdefer w.recoverFailedWrite(start, total);
        const buf = w.ownBytes()[start..][0..total];
        var pos: usize = 0;
        for (items, spans, 0..) |it, sp, i| {
            const hashes = pools[i / per].items[sp.start..][0..sp.len];
            var keys: [term_threads]u32 = undefined;
            var dfs: [term_threads]u32 = undefined;
            var nk: usize = undefined;
            var lineage: ??u64 = null;
            if (pre) |x| {
                keys = x.keys;
                dfs = x.dfs;
                nk = x.nk;
                lineage = x.lineage;
            } else nk = w.chooseThreads(hashes, &keys, &dfs);
            const len = recordLen(nk, it.scope.len, if (it.subject) |s| s.len else 0, it.text.len);
            // A batch counts words as it goes, so its later memories see
            // its earlier ones; a single memory counts after the lock.
            try w.encode(buf[pos..][0..len], start + pos, it, now, if (pre == null) hashes else null, sp.total, keys[0..nk], dfs[0..nk], lineage);
            pos += len;
        }
        w.commitAppend(start + pos);
        break :blk idOf(w.me, @intCast(start >> 3));
    };
    // Word counts last, outside the lock.
    if (pre != null) for (pools[0].items[spans[0].start..][0..spans[0].len]) |x| w.bumpDf(x);
    if (w.options.sync_writes) try w.sync();
    try w.maybeSnapshot();
    return first;
}

/// Makes every write so far durable. Each caller flushes the range from
/// the last durable byte to its own last write, so callers flush side by
/// side (the disk runs several flushes at once) and none is acknowledged
/// before everything written ahead of it is on disk.
pub fn sync(w: *Stratum) !void {
    const target = w.end.load(.acquire);
    const floor = w.synced.load(.acquire);
    if (floor >= target) return;
    try w.flushOwn(floor, target);
    _ = w.syncs.fetchAdd(1, .monotonic);
    _ = w.synced.fetchMax(target, .release);
}

/// Our lane's bytes, writable.
fn ownBytes(w: *const Stratum) []u8 {
    return @constCast(w.lanes[w.me].map);
}

/// Space for `len` bytes at the end of our lane. Grows the file ahead when
/// needed. Caller holds the write lock.
fn reserve(w: *Stratum, len: u64) !u64 {
    const off = w.end.load(.acquire);
    if (off + len >= map_reserve) return error.LaneFull;
    if (off + len > w.alloc) {
        const step = std.math.clamp(w.alloc / 4, grow_min, grow_max);
        const want = std.mem.alignForward(u64, @max(off + len, w.alloc + step), 4096);
        const size = @min(want, map_reserve);
        try w.lanes[w.me].file.setLength(w.io, size);
        {
            var z: [1 << 16]u8 = @splat(0);
            var o = w.alloc;
            while (o < size) : (o += z.len) try w.lanes[w.me].file.writePositionalAll(w.io, z[0..@min(z.len, size - o)], o);
            try w.lanes[w.me].file.sync(w.io);
        }
        w.alloc = size;
    }
    return off;
}

/// Makes appended bytes up to `new_end` part of our lane and visible to
/// other writers. Caller holds the write lock.
fn commitAppend(w: *Stratum, new_end: u64) void {
    w.end.store(new_end, .release);
    @atomicStore(u64, &w.lanes[w.me].end, new_end, .release);
    w.publish();
}

fn publish(w: *Stratum) void {
    const p: *u64 = @ptrCast(@alignCast(w.ownBytes()[pub_end_at..][0..8]));
    @atomicStore(u64, p, w.lanes[w.me].end, .release);
}

/// Flushes our lane's bytes in [from, to) to disk. The file's size only
/// changes when the lane grows, which syncs it then, so this is a range
/// flush of data alone.
fn flushOwn(w: *Stratum, from: u64, to: u64) !void {
    const page = std.heap.pageSize();
    const lo = std.mem.alignBackward(u64, @min(from, to), page);
    const m = w.ownBytes();
    if (to > lo) try std.posix.msync(@alignCast(m[lo..to]), std.posix.MSF.SYNC);
    if (builtin.os.tag != .linux) try w.lanes[w.me].file.sync(w.io);
}

pub fn syncCount(w: *const Stratum) u64 {
    return w.syncs.load(.monotonic);
}

/// Appends a marker record to our lane and applies it. Caller holds the
/// write lock.
fn appendMarker(w: *Stratum, kind: Kind, scope: []const u8, target: u64) !void {
    const len = recordLen(0, scope.len, 0, 0);
    var stack: [1200]u8 align(8) = undefined;
    const buf = stack[0..len];
    const h: *Hdr = @ptrCast(@alignCast(buf[0..hdr_len]));
    const stamp = w.nextStamp();
    h.* = .{ .len = @intCast(len), .crc = 0, .kind = kind, .nthreads = 0, .scope_len = @intCast(scope.len), .subject_len = 0, .flags = 0, .text_len = 0, .nterms = 0, .stamp = stamp, .time = w.nowMs(), .scope_hash = 0, .root = 0, .target = target, .prev_scope = 0, .text_crc = Crc.hash("") };
    @memcpy(buf[hdr_len..][0..scope.len], scope);
    @memset(buf[hdr_len + scope.len ..], 0);
    h.crc = metaCrc(buf, h);
    if (w.broken) return error.Broken;
    const off = try w.reserve(len);
    @memcpy(w.ownBytes()[off..][0..len], buf);
    w.commitAppend(off + len);
    w.last_stamp = stamp;
    switch (kind) {
        .forget_scope, .settle => try w.addRule(kind, target, scope),
        .forget_one => try w.mput(&w.forgotten, target, 1),
        else => {},
    }
}

/// Erases a record's text in our lane: zeroes the text, then marks it
/// erased. The metadata checksum does not cover either, so a crash halfway
/// leaves a readable record whose text no longer checks out, which reads
/// as erased. Caller holds the write lock.
fn eraseOwn(w: *Stratum, off8: u32) !void {
    const id = idOf(w.me, off8);
    if ((@as(u64, off8) << 3) + hdr_len > w.lanes[w.me].end) return;
    const h = w.hdrAt(id);
    if (h.kind != .memory) return;
    const n = h.text_len;
    const at = (@as(u64, off8) << 3) + textStart(h);
    var zeros: [4096]u8 = @splat(0);
    var done: usize = 0;
    while (done < n) {
        const k = @min(zeros.len, n - done);
        try w.lanes[w.me].file.writePositionalAll(w.io, zeros[0..k], at + done);
        done += k;
    }
    const kind = [1]u8{@backingInt(Kind.erased)};
    try w.lanes[w.me].file.writePositionalAll(w.io, &kind, (@as(u64, off8) << 3) + @offsetOf(Hdr, "kind"));
}

/// Erases our lane's memories in a scope (and below) older than `cutoff`.
fn eraseScopeInOwnLane(w: *Stratum, name: []const u8, cutoff: u64) !void {
    for (0..w.scopes.len()) |i| {
        const sid: u32 = @intCast(i);
        if (!inScope(w.scopeName(sid), name)) continue;
        var p = w.scopeHead(sid, w.me);
        while (p != 0) {
            const h = w.hdrAt(idOf(w.me, p));
            const prev = h.prev_scope;
            if (h.stamp < cutoff and h.kind == .memory) try w.eraseOwn(p);
            p = prev;
        }
    }
}

/// Forgets every memory in a scope and below it, in every lane. Our own
/// lane's text is erased now; other writers erase theirs when they see the
/// marker. Returns how many memories were forgotten.
pub fn forgetScope(w: *Stratum, scope: []const u8) !usize {
    if (scope.len == 0 or scope.len > 1024) return error.InvalidScope;
    const n = blk: {
        w.wlock.lockUncancelable(w.io);
        defer w.wlock.unlock(w.io);
        try w.refreshLocked();
        const cutoff = w.last_stamp + 1;
        var n: usize = 0;
        for (0..w.scopes.len()) |i| {
            const sid: u32 = @intCast(i);
            if (!inScope(w.scopeName(sid), scope)) continue;
            for (0..w.laneCount()) |lane| {
                var p = w.scopeHead(sid, lane);
                while (p != 0) {
                    const id = idOf(lane, p);
                    const h = w.hdrAt(id);
                    if (w.alive(id, h)) n += 1;
                    p = h.prev_scope;
                }
            }
        }
        try w.appendMarker(.forget_scope, scope, cutoff);
        try w.eraseScopeInOwnLane(scope, cutoff);
        break :blk n;
    };
    if (w.options.sync_writes) try w.sync();
    return n;
}

/// Forgets one memory.
pub fn forget(w: *Stratum, id: u64) !void {
    {
        w.wlock.lockUncancelable(w.io);
        defer w.wlock.unlock(w.io);
        if (laneOf(id) >= w.nlanes) return error.NotFound;
        if ((@as(u64, offOf(id)) << 3) + hdr_len > w.lanes[laneOf(id)].end or offOf(id) < data_start >> 3) return error.NotFound;
        try w.appendMarker(.forget_one, "", id);
        if (laneOf(id) == w.me) try w.eraseOwn(offOf(id));
    }
    if (w.options.sync_writes) try w.sync();
}

/// Adds a summary of a scope and settles everything before it: older
/// memories stay in `deep` recall, normal answers use the summary.
pub fn settle(w: *Stratum, scope: []const u8, summary: []const u8) !u64 {
    const id = try w.remember(scope, summary, .{ .subject = "summary" });
    {
        w.wlock.lockUncancelable(w.io);
        defer w.wlock.unlock(w.io);
        try w.appendMarker(.settle, scope, w.hdrAt(id).stamp);
    }
    if (w.options.sync_writes) try w.sync();
    return id;
}

// ------------------------------------------------------------------- reads

pub const Memory = struct {
    id: u64,
    time: u64,
    scope: []const u8,
    subject: []const u8,
    text: []const u8,
    raw: []u8,

    pub fn deinit(m: Memory, gpa: Allocator) void {
        gpa.free(m.raw);
    }
};

pub fn freeMemories(gpa: Allocator, ms: []const Memory) void {
    for (ms) |m| m.deinit(gpa);
    gpa.free(ms);
}

/// Copies a live memory out of its lane. Caller holds a lock.
fn load(w: *const Stratum, gpa: Allocator, id: u64) !?Memory {
    const h = w.hdrAt(id);
    if (!w.alive(id, h)) return null;
    const body = w.recBytes(id, h)[hdr_len + @as(usize, h.nthreads) * 8 ..][0 .. @as(usize, h.scope_len) + h.subject_len + h.text_len];
    const raw = try gpa.dupe(u8, body);
    return .{
        .id = id,
        .time = h.time,
        .scope = raw[0..h.scope_len],
        .subject = raw[h.scope_len..][0..h.subject_len],
        .text = raw[@as(usize, h.scope_len) + h.subject_len ..],
        .raw = raw,
    };
}

fn validId(w: *const Stratum, id: u64) bool {
    const lane = laneOf(id);
    if (lane >= w.nlanes) return false;
    const off = @as(u64, offOf(id)) << 3;
    return off >= data_start and off + hdr_len <= w.lanes[lane].end;
}

pub fn get(w: *Stratum, gpa: Allocator, id: u64) !?Memory {
    try w.maybeRefresh();
    w.readers.enter(w.io);
    defer w.readers.leave(w.io);
    if (!w.validId(id)) return null;
    return w.load(gpa, id);
}

/// The `n` memories most recently written to one scope, newest first, from
/// every writer.
pub fn recent(w: *Stratum, gpa: Allocator, scope: []const u8, n: usize) ![]Memory {
    return w.recentFiltered(gpa, scope, n, false);
}

fn recentFiltered(w: *Stratum, gpa: Allocator, scope: []const u8, n: usize, skip_buried: bool) ![]Memory {
    try w.maybeRefresh();
    var out: std.ArrayList(Memory) = .empty;
    errdefer {
        for (out.items) |m| m.deinit(gpa);
        out.deinit(gpa);
    }
    w.readers.enter(w.io);
    defer w.readers.leave(w.io);
    const sid = w.findScope(scope) orelse return out.toOwnedSlice(gpa);
    var cur: [max_lanes]u32 = undefined;
    for (0..w.laneCount()) |l| cur[l] = w.scopeHead(sid, l);
    while (out.items.len < n) {
        // Most recently written across lanes.
        var bl: ?usize = null;
        for (0..w.laneCount()) |l| {
            if (cur[l] == 0) continue;
            if (bl == null or w.laterWrite(idOf(l, cur[l]), idOf(bl.?, cur[bl.?]))) bl = l;
        }
        const l = bl orelse break;
        const id = idOf(l, cur[l]);
        const h = w.hdrAt(id);
        cur[l] = h.prev_scope;
        if (skip_buried and w.isBuried(id, h)) continue;
        if (try w.load(gpa, id)) |m| {
            errdefer m.deinit(gpa);
            try out.append(gpa, m);
        }
    }
    return out.toOwnedSlice(gpa);
}

/// The current memory for a subject in a scope.
pub fn current(w: *Stratum, gpa: Allocator, scope: []const u8, subject: []const u8) !?Memory {
    try w.maybeRefresh();
    w.readers.enter(w.io);
    defer w.readers.leave(w.io);
    const id = w.subjects.get(subjectKey(scopeHash(scope), subject)) orelse return null;
    return w.load(gpa, w.headOf(id, w.hdrAt(id)));
}

// ------------------------------------------------------------------ recall

pub const Query = struct {
    /// What to look for. Empty: newest first.
    about: []const u8 = "",
    /// Only memories in this scope or below it.
    scope: []const u8 = "",
    /// Only memories at or after this time (ms).
    since: u64 = 0,
    limit: usize = 10,
    /// Every version of every fact, not just the newest.
    deep: bool = false,
    /// Use word meanings, when the store has them.
    expand: bool = true,
};

pub const Hit = struct {
    memory: Memory,
    score: f32,
    /// An older version (only with `deep`) or settled.
    buried: bool,
    /// Which question words it contains (bit per word group).
    matched: u8 = 0,
};

pub fn freeHits(gpa: Allocator, hs: []const Hit) void {
    for (hs) |h| h.memory.deinit(gpa);
    gpa.free(hs);
}

/// A question word, or a word related in meaning to one. Words of one
/// `group` count once, by their best match.
const QTerm = struct { key: u32, idf: f32, hash: u64, group: u8 };
const max_groups = 8;
const max_related = 4;
const min_related_sim = 0.45;
const anchor_weight = 2.0;
const semantic_weight = 8.0;
const near_words = 4;
const sim_floor = 0.15;

/// A candidate fact: its best-matching version and score so far.
const Cand = struct { root: u64, id: u64, score: f32 };

fn recency(w: *const Stratum, now: u64, t: u64) f32 {
    const age: f32 = @floatFromInt(now -| t);
    const hl: f32 = @floatFromInt(@max(w.options.half_life_ms, 1));
    return 0.85 + 0.15 * @exp2(-age / hl);
}

fn coverage(s: f32, qsum: f32) f32 {
    if (qsum <= 0) return s;
    const c = s / qsum;
    return s * c * c;
}

/// Score on threads alone: per word group, the best word the record has.
fn threadScore(qt: []const QTerm, ts: []align(1) const u64) f32 {
    var best: [max_groups]f32 = @splat(0);
    for (ts) |t| {
        const k = threadKey(t);
        for (qt) |q| if (q.key == k) {
            best[q.group] = @max(best[q.group], q.idf);
        };
    }
    var s: f32 = 0;
    for (best) |b| s += b;
    return s;
}

const Search = struct {
    w: *const Stratum,
    gpa: Allocator,
    qt: []const QTerm,
    qsum: f32,
    q: Query,
    set: *const ScopeSet,
    now: u64,
    /// root -> index into `cands`
    seen: std.AutoHashMapUnmanaged(u64, u32) = .empty,
    cands: std.ArrayList(Cand) = .empty,

    fn deinit(c: *Search) void {
        c.seen.deinit(c.gpa);
        c.cands.deinit(c.gpa);
    }

    /// Scores one record and files it under its fact (its stratum).
    fn consider(c: *Search, id: u64, h: *const Hdr) !void {
        const w = c.w;
        if (h.kind != .memory) return;
        const sid = w.sidOf(h.scope_hash) orelse return;
        if (!c.set.has(sid)) return;
        if (w.forgotten.contains(id) or h.stamp < w.scopes.forgot(sid)) return;
        const base = threadScore(c.qt, w.threadsOf(id, h));
        if (base == 0) return;
        if (!c.q.deep and h.stamp < w.scopes.settled(sid)) return;
        // `since` applies to the version the answer will be.
        if (c.q.since > 0) {
            const shown = if (c.q.deep) id else w.headOf(id, h);
            if (w.hdrAt(shown).time < c.q.since) return;
        }
        // The fact this version belongs to; with `deep`, every version
        // stands for itself.
        const root = if (c.q.deep) id else rootOf(h, id);
        const subj: f32 = if (h.subject_len > 0) 1.1 else 1.0;
        const s = coverage(base, c.qsum) * w.recency(c.now, h.time) * subj;
        const gop = try c.seen.getOrPut(c.gpa, root);
        if (gop.found_existing) {
            const e = &c.cands.items[gop.value_ptr.*];
            if (s > e.score) {
                e.score = s;
                e.id = id;
            }
        } else {
            gop.value_ptr.* = @intCast(c.cands.items.len);
            try c.cands.append(c.gpa, .{ .root = root, .id = id, .score = s });
        }
    }

    /// Follows one word's chain in every lane, newest first, up to `budget`
    /// records per lane.
    fn walk(c: *Search, key: u32, budget: usize) !void {
        const w = c.w;
        const b = bucketOf(key);
        for (0..w.laneCount()) |lane| {
            var p = @atomicLoad(u32, &w.lanes[lane].heads[b], .acquire);
            var steps: usize = 0;
            while (p != 0 and steps < budget) : (steps += 1) {
                const id = idOf(lane, p);
                const h = w.hdrAt(id);
                var next: u32 = 0;
                var found = false;
                var has_key = false;
                for (w.threadsOf(id, h)) |t| {
                    const k = threadKey(t);
                    if (!found and bucketOf(k) == b) {
                        next = threadPrev(t);
                        found = true;
                    }
                    if (k == key) has_key = true;
                }
                if (!found) break;
                if (has_key) try c.consider(id, h);
                p = next;
            }
        }
    }
};

/// Facts ranked by how well any of their versions matches `about` (words
/// and meaning), answered with each fact's newest version.
pub fn recall(w: *Stratum, gpa: Allocator, q: Query) ![]Hit {
    try w.maybeRefresh();
    const limit = @max(q.limit, 1);
    var ts: text.TermSet = .{};
    ts.fill(q.about);
    const meaning: ?*const Meaning = if (q.expand) w.options.meaning else null;
    var hits: std.ArrayList(Hit) = .empty;
    errdefer {
        for (hits.items) |x| x.memory.deinit(gpa);
        hits.deinit(gpa);
    }
    const now = w.nowMs();

    w.readers.enter(w.io);
    defer w.readers.leave(w.io);
    if (w.count == 0) return hits.toOwnedSlice(gpa);
    var set = try w.scopeSet(gpa, q.scope);
    defer set.deinit(gpa);
    if (!set.all and set.n == 0) return hits.toOwnedSlice(gpa);
    if (ts.len == 0) {
        try w.newestInto(gpa, &set, q, limit, &hits);
        return hits.toOwnedSlice(gpa);
    }

    // Question words, rarest first; names (words the meaning table does
    // not know) weigh double when meaning is on.
    var all: [text.TermSet.cap]QTerm = undefined;
    for (ts.hashes[0..ts.len], 0..) |x, i| {
        var wt = w.idf(x);
        if (meaning) |mn| if (mn.index(x) == null) {
            wt *= anchor_weight;
        };
        all[i] = .{ .key = termKey(x), .idf = wt, .hash = x, .group = 0 };
    }
    std.mem.sortUnstable(QTerm, all[0..ts.len], {}, struct {
        fn gt(_: void, a: QTerm, b: QTerm) bool {
            return a.idf > b.idf;
        }
    }.gt);
    var qt_buf: [max_groups * (1 + max_related)]QTerm = undefined;
    var nq: usize = @min(ts.len, max_groups);
    @memcpy(qt_buf[0..nq], all[0..nq]);
    var qsum: f32 = 0;
    for (qt_buf[0..nq], 0..) |*t, g| {
        t.group = @intCast(g);
        qsum += t.idf;
    }
    const ngroups = nq;
    if (meaning) |mn| {
        for (0..ngroups) |g| {
            var rel: [max_related]Meaning.Related = undefined;
            const n = mn.related(qt_buf[g].hash, min_related_sim, &rel);
            outer: for (rel[0..n]) |rw| {
                for (qt_buf[0..nq]) |t| if (t.hash == rw.hash) continue :outer;
                qt_buf[nq] = .{ .key = termKey(rw.hash), .idf = rw.sim * rw.sim * @min(qt_buf[g].idf, w.idf(rw.hash)), .hash = rw.hash, .group = @intCast(g) };
                nq += 1;
            }
        }
    }
    const qt = qt_buf[0..nq];

    var ctx: Search = .{ .w = w, .gpa = gpa, .qt = qt, .qsum = qsum, .q = q, .set = &set, .now = now };
    defer ctx.deinit();

    // Candidates: walk a small scope whole, or follow the chains of the
    // rarest words (and, with meaning, of words related to the rarest).
    // Walk the scope when it is smaller than the rarest word's chain would
    // be (with slack), else follow chains and filter by scope.
    const est_chain: u64 = @as(u64, w.df(qt[0].hash)) + 1;
    if (!set.all and set.total <= 65536 and set.total <= @max(est_chain * 4, 4096)) {
        for (0..w.scopes.len()) |i| {
            if (!set.bits.isSet(i)) continue;
            for (0..w.laneCount()) |lane| {
                var p = w.scopeHead(i, lane);
                while (p != 0) {
                    const id = idOf(lane, p);
                    const h = w.hdrAt(id);
                    try ctx.consider(id, h);
                    p = h.prev_scope;
                }
            }
        }
    } else {
        for (0..@min(ngroups, 3)) |g| try ctx.walk(qt[g].key, if (g == 0) 8192 else 2048);
        for (qt[ngroups..]) |t| if (t.group == 0) try ctx.walk(t.key, 1024);
    }

    // The best candidates go to the rerank.
    const pool_n = @min(ctx.cands.items.len, if (meaning != null) @max(limit * 8, 64) else @max(limit * 4, 16));
    std.mem.sortUnstable(Cand, ctx.cands.items, {}, struct {
        fn gt(_: void, a: Cand, b: Cand) bool {
            return a.score > b.score;
        }
    }.gt);

    // Rerank on full text. A fact scores by its best version (the words of
    // every version lead to it) and answers with its newest.
    const avg_len: f32 = @as(f32, @floatFromInt(w.total_terms)) / @as(f32, @floatFromInt(@max(w.count, 1)));
    // Two strata can share a head (two writers started the same subject
    // without seeing each other): answer it once, with its best score.
    var by_head: std.AutoHashMapUnmanaged(u64, u32) = .empty;
    defer by_head.deinit(gpa);
    for (ctx.cands.items[0..pool_n]) |c| {
        const vh = w.hdrAt(c.id);
        const head = if (q.deep) c.id else w.headOf(c.id, vh);
        const hh = w.hdrAt(head);
        const dup = try by_head.getOrPut(gpa, head);
        if (dup.found_existing) {
            const prev = &hits.items[dup.value_ptr.*];
            const other = textScore(qt, qsum, avg_len, meaning, w.textOf(c.id, vh));
            const subj0: f32 = if (hh.subject_len > 0) 1.1 else 1.0;
            const sc = other.score * w.recency(now, hh.time) * subj0;
            if (sc > prev.score) {
                prev.score = sc;
                prev.matched = other.mask;
            }
            continue;
        }
        const m = (try w.load(gpa, head)) orelse {
            _ = by_head.remove(head);
            continue;
        };
        var best = textScore(qt, qsum, avg_len, meaning, m.text);
        if (head != c.id) {
            const other = textScore(qt, qsum, avg_len, meaning, w.textOf(c.id, vh));
            if (other.score > best.score) best = other;
        }
        if (best.score == 0) {
            m.deinit(gpa);
            _ = by_head.remove(head);
            continue;
        }
        const subj: f32 = if (hh.subject_len > 0) 1.1 else 1.0;
        const score = best.score * w.recency(now, hh.time) * subj;
        dup.value_ptr.* = @intCast(hits.items.len);
        try hits.append(gpa, .{ .memory = m, .score = score, .buried = q.deep and w.isBuried(head, hh), .matched = best.mask });
    }
    std.mem.sortUnstable(Hit, hits.items, {}, struct {
        fn gt(_: void, a: Hit, b: Hit) bool {
            return a.score > b.score;
        }
    }.gt);
    if (!q.deep) sedimentHits(hits.items);
    while (hits.items.len > limit) hits.pop().?.memory.deinit(gpa);
    return hits.toOwnedSlice(gpa);
}

const Scored = struct { score: f32, mask: u8 };

/// BM25 over word groups, times the squared share of the question covered,
/// times closeness in meaning.
fn textScore(qt: []const QTerm, qsum: f32, avg_len: f32, meaning: ?*const Meaning, body: []const u8) Scored {
    var mt: text.TermSet = .{};
    mt.fill(body);
    var gbm: [max_groups]f32 = @splat(0);
    var gcov: [max_groups]f32 = @splat(0);
    var mask: u8 = 0;
    const dl: f32 = @floatFromInt(mt.total);
    for (qt) |t| {
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
    if (bm == 0) return .{ .score = 0, .mask = 0 };
    var near: f32 = 0;
    if (meaning) |mn| near = closeness(mn, qt, body);
    const cov = covered / @max(qsum, 1e-6);
    return .{ .score = bm * cov * cov * (1.0 + semantic_weight * near), .mask = mask };
}

/// How close a text is in meaning to the question: for each question word,
/// its best match among the text's words, weighted by rarity. Words near a
/// name the question asks about count fully; farther ones fade.
fn closeness(mn: *const Meaning, qt: []const QTerm, body: []const u8) f32 {
    const Seq = struct {
        hashes: [256]u64 = undefined,
        len: usize = 0,
        pub fn term(s: *@This(), x: u64) void {
            if (s.len < s.hashes.len) {
                s.hashes[s.len] = x;
                s.len += 1;
            }
        }
    };
    var seq: Seq = .{};
    text.forEachTerm(body, &seq);
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
        var wt: f32 = 1;
        if (na > 0) {
            var dist: usize = std.math.maxInt(usize);
            for (anchors[0..na]) |ap| dist = @min(dist, if (ap > i) ap - i else i - ap);
            if (dist > near_words) wt = @exp2(-@as(f32, @floatFromInt(dist - near_words)) / near_words);
        }
        di[nd] = wi;
        dw[nd] = wt;
        nd += 1;
    }
    var sum: f32 = 0;
    var wsum: f32 = 0;
    for (qt) |t| {
        if (t.hash != qt[t.group].hash) continue;
        const qi = mn.index(t.hash) orelse continue;
        wsum += t.idf;
        var best: f32 = 0;
        for (di[0..nd], dw[0..nd]) |d, wt| best = @max(best, wt * mn.similarity(qi, d));
        if (best < sim_floor) continue;
        sum += t.idf * (best - sim_floor) / (1 - sim_floor);
    }
    return if (wsum > 0) sum / wsum else 0;
}

/// For versions the store could not link when they were written (no
/// subject, too few shared rare words): among hits that matched the same
/// question words (two or more) about equally well, the newest comes first
/// and the older ones are marked buried.
fn sedimentHits(hits: []Hit) void {
    var changed = true;
    var rounds: usize = 0;
    while (changed and rounds < hits.len) : (rounds += 1) {
        changed = false;
        for (0..hits.len) |i| for (i + 1..hits.len) |j| {
            if (sameFact(&hits[i], &hits[j]) and hits[j].memory.time > hits[i].memory.time) {
                std.mem.swap(Hit, &hits[i], &hits[j]);
                changed = true;
            }
        };
    }
    for (0..hits.len) |j| for (0..j) |i| {
        if (sameFact(&hits[i], &hits[j]) and hits[i].memory.time > hits[j].memory.time) {
            hits[j].buried = true;
            break;
        }
    };
}

fn sameFact(a: *const Hit, b: *const Hit) bool {
    return a.matched == b.matched and @popCount(a.matched) >= 2 and b.score >= a.score * 0.9;
}

/// The most recently written memories across the scope set, for questions
/// with no words.
fn newestInto(w: *const Stratum, gpa: Allocator, set: *const ScopeSet, q: Query, limit: usize, hits: *std.ArrayList(Hit)) !void {
    const Cur = struct { lane: usize, off8: u32 };
    var cursors: std.ArrayList(Cur) = .empty;
    defer cursors.deinit(gpa);
    for (0..w.scopes.len()) |i| {
        if (!set.has(@intCast(i))) continue;
        for (0..w.laneCount()) |lane| {
            const p = w.scopeHead(i, lane);
            if (p != 0) try cursors.append(gpa, .{ .lane = lane, .off8 = p });
        }
    }
    while (hits.items.len < limit) {
        var bi: ?usize = null;
        for (cursors.items, 0..) |c, i| {
            if (c.off8 == 0) continue;
            if (bi == null or w.laterWrite(idOf(c.lane, c.off8), idOf(cursors.items[bi.?].lane, cursors.items[bi.?].off8))) bi = i;
        }
        const i = bi orelse break;
        const id = idOf(cursors.items[i].lane, cursors.items[i].off8);
        const h = w.hdrAt(id);
        cursors.items[i].off8 = h.prev_scope;
        if (h.time < q.since) continue;
        const buried = w.isBuried(id, h);
        if (buried and !q.deep) continue;
        const m = (try w.load(gpa, id)) orelse continue;
        errdefer m.deinit(gpa);
        try hits.append(gpa, .{ .memory = m, .score = @floatFromInt(h.stamp), .buried = buried });
    }
}

// ------------------------------------------------------------------- brief

pub const Brief = struct {
    text: []u8,
    tokens: usize,
    items: usize,
    buried_skipped: usize,

    pub fn deinit(b: Brief, gpa: Allocator) void {
        gpa.free(b.text);
    }
};

/// A briefing for an agent: the facts that matter for `situation`, each in
/// its newest version only, then the newest in the scope, never over
/// `budget` tokens (4 bytes a token).
pub fn brief(w: *Stratum, gpa: Allocator, situation: []const u8, scope: []const u8, budget: usize) !Brief {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    const hits = try w.recall(gpa, .{ .about = situation, .scope = scope, .limit = 16 });
    defer freeHits(gpa, hits);
    const exact = blk: {
        w.readers.enter(w.io);
        defer w.readers.leave(w.io);
        break :blk scope.len > 0 and w.findScope(scope) != null;
    };
    const rec_ms = if (exact) try w.recentFiltered(gpa, scope, 6, true) else try gpa.alloc(Memory, 0);
    defer freeMemories(gpa, rec_ms);

    var used: usize = 0;
    var items: usize = 0;
    var seen: [64]u64 = undefined;
    var nseen: usize = 0;
    var rel: [24]Memory = undefined;
    var nrel: usize = 0;
    var skipped: usize = 0;
    for (hits) |x| {
        if (x.buried) {
            skipped += 1;
            if (nseen < seen.len) {
                seen[nseen] = x.memory.id;
                nseen += 1;
            }
            continue;
        }
        rel[nrel] = x.memory;
        nrel += 1;
    }
    const now = w.nowMs();
    const Section = struct { title: []const u8, mems: []const Memory };
    const sections = [_]Section{
        .{ .title = "Relevant memory", .mems = rel[0..nrel] },
        .{ .title = "Recent in this scope", .mems = rec_ms },
    };
    for (sections) |sec| {
        var header_done = false;
        for (sec.mems) |m| {
            if (std.mem.indexOfScalar(u64, seen[0..nseen], m.id) != null) continue;
            const snippet = m.text[0..@min(m.text.len, 600)];
            const cost = (snippet.len + m.scope.len + 40 + 3) / 4;
            if (used + cost > budget) continue;
            if (!header_done) {
                try out.print(gpa, "## {s}\n", .{sec.title});
                header_done = true;
            }
            const age_s = (now -| m.time) / 1000;
            const v, const u = if (age_s < 3600) .{ age_s / 60, "m" } else if (age_s < 86400) .{ age_s / 3600, "h" } else .{ age_s / 86400, "d" };
            try out.print(gpa, "- [{d}{s} ago {s}] {s}{s}\n", .{ v, u, m.scope, snippet, if (snippet.len < m.text.len) "..." else "" });
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

// -------------------------------------------------------------------- info

pub const Info = struct {
    memories: u64,
    scopes: usize,
    subjects: usize,
    /// Facts with more than one version.
    strata: usize,
    /// Versions linked by shared rare words rather than a subject.
    auto_merges: u64,
    lanes: usize,
    file_bytes: u64,
    /// RAM held by the tables: chain heads, word counts, scopes, subjects,
    /// strata.
    index_bytes: usize,
};

pub fn info(w: *Stratum) Info {
    w.readers.enter(w.io);
    defer w.readers.leave(w.io);
    const scopes = w.scopes.len();
    var bytes: u64 = 0;
    for (w.lanes[0..w.nlanes]) |l| bytes += l.end;
    return .{
        .memories = w.count,
        .scopes = scopes,
        .subjects = w.subjects.count(),
        .strata = w.strata.count(),
        .auto_merges = w.merges,
        .lanes = w.nlanes,
        .file_bytes = bytes,
        .index_bytes = w.nlanes * nbuckets * 4 + w.cms.len * 4 + w.scopes.name_bytes + scopes * 48 + (w.scope_map.capacity() + w.scope_heads.capacity() + w.subjects.capacity() + w.strata.capacity() + w.forgotten.capacity()) * 16,
    };
}

/// Calls `f(ctx, record_bytes, time)` for every live memory: the cost of
/// answering without an index.
pub fn scanAll(w: *Stratum, ctx: anytype, comptime f: anytype) !void {
    w.readers.enter(w.io);
    defer w.readers.leave(w.io);
    for (0..w.laneCount()) |lane| {
        var pos: u64 = data_start;
        const end = w.lanes[lane].end;
        while (pos + hdr_len <= end) {
            const id = idOf(lane, @intCast(pos >> 3));
            const h = w.hdrAt(id);
            if (h.kind == .memory and w.alive(id, h)) f(ctx, w.recBytes(id, h)[hdr_len + @as(usize, h.nthreads) * 8 ..][0 .. @as(usize, h.scope_len) + h.subject_len + h.text_len], h.time);
            pos += h.len;
        }
    }
}

// ------------------------------------------------------- snapshot, recovery

const Super = extern struct {
    magic: [8]u8,
    gen: u64,
    snap_off: u64,
    progress: u64,
    crc: u32,
    pad: u32 = 0,
};

/// Writes a snapshot when our lane grew by `every` bytes since the last
/// one. Both ends are read under the write lock.
fn snapshotIfGrew(w: *Stratum, every: u64) !void {
    w.wlock.lockUncancelable(w.io);
    defer w.wlock.unlock(w.io);
    if (w.end.load(.acquire) -| w.snap_end < every) return;
    try w.snapshotLocked();
}

fn maybeSnapshot(w: *Stratum) !void {
    if (w.end.load(.acquire) -| @atomicLoad(u64, &w.snap_end, .acquire) < snapshot_every) return;
    try w.snapshotIfGrew(snapshot_every);
}

fn putInt(gpa: Allocator, b: *std.ArrayList(u8), comptime T: type, v: T) !void {
    var x: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &x, v, .little);
    try b.appendSlice(gpa, &x);
}

/// Writes the RAM tables into our lane as one record and points our lane's
/// superblock at it. Reopening (by any writer) loads it and replays only
/// the records after it, lane by lane.
pub fn snapshot(w: *Stratum) !void {
    w.wlock.lockUncancelable(w.io);
    defer w.wlock.unlock(w.io);
    try w.snapshotLocked();
}

fn snapshotLocked(w: *Stratum) !void {
    const gpa = w.gpa;
    var b: std.ArrayList(u8) = .empty;
    defer b.deinit(gpa);
    try b.appendNTimes(gpa, 0, hdr_len);
    const body_start = b.items.len;
    try putInt(gpa, &b, u32, 1);
    try putInt(gpa, &b, u32, @intCast(w.nlanes));
    for (w.lanes[0..w.nlanes]) |l| {
        try putInt(gpa, &b, u64, l.end);
        try b.appendSlice(gpa, std.mem.sliceAsBytes(l.heads));
    }
    try b.appendSlice(gpa, std.mem.sliceAsBytes(w.cms));
    try putInt(gpa, &b, u64, w.count);
    try putInt(gpa, &b, u64, w.total_terms);
    try putInt(gpa, &b, u64, w.last_stamp);
    try putInt(gpa, &b, u64, w.merges);
    const ns: u32 = @intCast(w.scopes.len());
    try putInt(gpa, &b, u32, ns);
    for (0..ns) |i| {
        const name = w.scopeName(@intCast(i));
        try putInt(gpa, &b, u16, @intCast(name.len));
        try b.appendSlice(gpa, name);
        try putInt(gpa, &b, u32, w.scopes.countOf(i));
        try putInt(gpa, &b, u64, w.scopes.settled(i));
        try putInt(gpa, &b, u64, w.scopes.forgot(i));
    }
    try putInt(gpa, &b, u32, @intCast(w.rules.items.len));
    for (w.rules.items) |r| {
        try putInt(gpa, &b, u8, @backingInt(r.kind));
        try putInt(gpa, &b, u64, r.cutoff);
        try putInt(gpa, &b, u16, @intCast(r.name.len));
        try b.appendSlice(gpa, r.name);
    }
    const maps = [_]*const tables.Map{ &w.subjects, &w.strata };
    try putInt(gpa, &b, u32, @intCast(w.scope_heads.count()));
    var hit = w.scope_heads.iterator();
    while (hit.next()) |e| {
        try putInt(gpa, &b, u64, e.key);
        try putInt(gpa, &b, u32, @intCast(e.value));
    }
    for (maps) |m| {
        try putInt(gpa, &b, u32, @intCast(m.count()));
        var it = m.iterator();
        while (it.next()) |e| {
            try putInt(gpa, &b, u64, e.key);
            try putInt(gpa, &b, u64, e.value);
        }
    }
    try putInt(gpa, &b, u32, @intCast(w.forgotten.count()));
    var fit = w.forgotten.iterator();
    while (fit.next()) |e| try putInt(gpa, &b, u64, e.key);
    const payload = b.items.len - body_start;
    const len = std.mem.alignForward(usize, b.items.len, 8);
    try b.appendNTimes(gpa, 0, len - b.items.len);
    const h: *align(1) Hdr = @ptrCast(b.items[0..hdr_len]);
    const stamp = w.last_stamp;
    h.* = .{ .len = @intCast(len), .crc = 0, .kind = .snapshot, .nthreads = 0, .scope_len = 0, .subject_len = 0, .flags = 0, .text_len = @intCast(payload), .nterms = 0, .stamp = stamp, .time = w.nowMs(), .scope_hash = 0, .root = 0, .target = 0, .prev_scope = 0, .text_crc = Crc.hash(b.items[body_start..][0..payload]) };
    var hcopy = h.*;
    h.crc = metaCrc(b.items, &hcopy);
    const off = try w.reserve(len);
    @memcpy(w.ownBytes()[off..][0..len], b.items);
    const new_end = off + len;
    w.commitAppend(new_end);
    try w.flushOwn(w.synced.load(.acquire), new_end);
    _ = w.synced.fetchMax(new_end, .release);

    const prog = w.progress() - len; // the snapshot itself is not progress
    w.snap_gen += 1;
    var sb: Super = .{ .magic = "STRATSB1".*, .gen = w.snap_gen, .snap_off = off, .progress = prog, .crc = 0 };
    sb.crc = Crc.hash(std.mem.asBytes(&sb)[0..32]);
    try w.lanes[w.me].file.writePositionalAll(w.io, std.mem.asBytes(&sb), (w.snap_gen & 1) * 64);
    try w.lanes[w.me].file.sync(w.io);
    @atomicStore(u64, &w.snap_end, new_end, .release);
    w.snap_progress = w.progress();
}

/// Loads the most advanced valid snapshot found in any lane. Returns where
/// each lane's replay starts, or null when there is none.
fn loadSnapshot(w: *Stratum) !?[max_lanes]u64 {
    const Pick = struct { lane: usize, sb: Super };
    var best: ?Pick = null;
    for (0..w.laneCount()) |lane| {
        const len = try w.lanes[lane].file.length(w.io);
        if (len < data_start) continue;
        for (0..2) |i| {
            const sb: *align(1) const Super = @ptrCast(w.lanes[lane].map[i * 64 ..][0..@sizeOf(Super)]);
            if (!std.mem.eql(u8, &sb.magic, "STRATSB1")) continue;
            if (Crc.hash(std.mem.asBytes(sb)[0..32]) != sb.crc) continue;
            if (w.validAt(lane, sb.snap_off, len) == null) continue;
            if (lane == w.me and sb.gen > w.snap_gen) w.snap_gen = sb.gen;
            if (best == null or sb.progress > best.?.sb.progress) best = .{ .lane = lane, .sb = sb.* };
        }
    }
    const pick = best orelse return null;
    const h = w.validAt(pick.lane, pick.sb.snap_off, try w.lanes[pick.lane].file.length(w.io)) orelse return null;
    if (h.kind != .snapshot) return error.Corrupt;
    const snap_id = idOf(pick.lane, @intCast(pick.sb.snap_off >> 3));
    const data = w.textOf(snap_id, h);
    if (Crc.hash(data) != h.text_crc) return error.Corrupt;
    const gpa = w.gpa;
    var p: usize = 0;
    const rd = struct {
        fn int(d: []const u8, pp: *usize, comptime T: type) !T {
            if (pp.* + @sizeOf(T) > d.len) return error.Corrupt;
            const v = std.mem.readInt(T, d[pp.*..][0..@sizeOf(T)], .little);
            pp.* += @sizeOf(T);
            return v;
        }
        fn bytes(d: []const u8, pp: *usize, n: usize) ![]const u8 {
            if (pp.* + n > d.len) return error.Corrupt;
            const s = d[pp.*..][0..n];
            pp.* += n;
            return s;
        }
    };
    if (try rd.int(data, &p, u32) != 1) return error.Corrupt;
    const nl = try rd.int(data, &p, u32);
    if (nl > w.nlanes) return error.Corrupt;
    var from: [max_lanes]u64 = @splat(data_start);
    for (0..nl) |l| {
        from[l] = try rd.int(data, &p, u64);
        const hb = try rd.bytes(data, &p, nbuckets * 4);
        @memcpy(std.mem.sliceAsBytes(w.lanes[l].heads), hb);
        if (from[l] > try w.lanes[l].file.length(w.io)) return error.Corrupt;
    }
    @memcpy(std.mem.sliceAsBytes(w.cms), try rd.bytes(data, &p, w.cms.len * 4));
    w.count = try rd.int(data, &p, u64);
    w.total_terms = try rd.int(data, &p, u64);
    w.last_stamp = try rd.int(data, &p, u64);
    w.merges = try rd.int(data, &p, u64);
    const ns = try rd.int(data, &p, u32);
    for (0..ns) |_| {
        const nlen = try rd.int(data, &p, u16);
        const name = try rd.bytes(data, &p, nlen);
        const id = try w.intern(name, scopeHash(name));
        const sc = w.scopes.at(id);
        sc.count = try rd.int(data, &p, u32);
        sc.settled = try rd.int(data, &p, u64);
        sc.forgot = try rd.int(data, &p, u64);
    }
    const nr = try rd.int(data, &p, u32);
    for (0..nr) |_| {
        const kind: Kind = @fromBackingInt(@intCast(try rd.int(data, &p, u8)));
        const cutoff = try rd.int(data, &p, u64);
        const nlen = try rd.int(data, &p, u16);
        const copy = try gpa.dupe(u8, try rd.bytes(data, &p, nlen));
        errdefer gpa.free(copy);
        try w.rules.append(gpa, .{ .kind = kind, .cutoff = cutoff, .name = copy });
    }
    const nh = try rd.int(data, &p, u32);
    try w.scope_heads.ensureTotalCapacity(gpa, &w.readers, w.io, nh);
    for (0..nh) |_| {
        const k = try rd.int(data, &p, u64);
        try w.mput(&w.scope_heads, k, try rd.int(data, &p, u32));
    }
    const maps = [_]*tables.Map{ &w.subjects, &w.strata };
    for (maps) |m| {
        const n = try rd.int(data, &p, u32);
        try m.ensureTotalCapacity(gpa, &w.readers, w.io, n);
        for (0..n) |_| {
            const k = try rd.int(data, &p, u64);
            try w.mput(m, k, try rd.int(data, &p, u64));
        }
    }
    const nf = try rd.int(data, &p, u32);
    try w.forgotten.ensureTotalCapacity(gpa, &w.readers, w.io, nf);
    for (0..nf) |_| try w.mput(&w.forgotten, try rd.int(data, &p, u64), 1);
    for (0..w.laneCount()) |l| w.lanes[l].end = from[l];
    w.snap_progress = pick.sb.progress;
    return from;
}

// ------------------------------------------------------------------- tests

const testing = std.testing;

fn tmpStore(tmp: *testing.TmpDir, meaning: ?*const Meaning) !*Stratum {
    return Stratum.open(testing.allocator, testing.io, tmp.dir, "s", .{ .sync_writes = false, .meaning = meaning });
}

test "remember, recent, current" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const w = try tmpStore(&tmp, null);
    defer w.close();
    _ = try w.remember("chat/1", "hello there", .{});
    _ = try w.remember("chat/1", "deploy is on friday", .{});
    _ = try w.remember("mem", "plan A", .{ .subject = "plan" });
    _ = try w.remember("mem", "plan B", .{ .subject = "plan" });
    const r = try w.recent(testing.allocator, "chat/1", 10);
    defer freeMemories(testing.allocator, r);
    try testing.expectEqual(@as(usize, 2), r.len);
    try testing.expectEqualStrings("deploy is on friday", r[0].text);
    const c = (try w.current(testing.allocator, "mem", "plan")).?;
    defer c.deinit(testing.allocator);
    try testing.expectEqualStrings("plan B", c.text);
}

test "an old wording reaches the newest version of its fact" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const w = try tmpStore(&tmp, null);
    defer w.close();
    w.setClockForTest(10_000_000);
    for (0..2000) |i| {
        var b: [64]u8 = undefined;
        _ = try w.remember("p/chat", try std.fmt.bufPrint(&b, "filler {d} about lunch and coffee", .{i}), .{});
    }
    _ = try w.remember("p", "billing runs on postgres fifteen", .{ .subject = "billing-db" });
    for (0..300) |i| {
        var b: [64]u8 = undefined;
        _ = try w.remember("p/chat", try std.fmt.bufPrint(&b, "more filler {d}", .{i}), .{});
    }
    _ = try w.remember("p", "payments service moved to cockroach", .{ .subject = "billing-db" });
    // Asked in the old words: the answer is the current version, once.
    const hits = try w.recall(testing.allocator, .{ .about = "what does billing run on, postgres?", .limit = 5 });
    defer freeHits(testing.allocator, hits);
    try testing.expect(hits.len >= 1);
    try testing.expectEqualStrings("payments service moved to cockroach", hits[0].memory.text);
    for (hits) |x| try testing.expect(std.mem.indexOf(u8, x.memory.text, "fifteen") == null);
    const deep = try w.recall(testing.allocator, .{ .about = "billing postgres cockroach payments", .limit = 5, .deep = true });
    defer freeHits(testing.allocator, deep);
    try testing.expectEqual(@as(usize, 2), deep.len);
}

test "versions without a subject join a stratum by shared rare words" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const w = try tmpStore(&tmp, null);
    defer w.close();
    for (0..5000) |i| {
        var b: [80]u8 = undefined;
        _ = try w.remember("p", try std.fmt.bufPrint(&b, "the team talked about the plan {d} today", .{i}), .{});
    }
    _ = try w.remember("p", "zorblat quuxcache ttl is ninety seconds", .{});
    _ = try w.remember("p", "zorblat quuxcache ttl raised to hundredtwenty", .{});
    // A different fact about the same name stays its own stratum.
    _ = try w.remember("p", "zorblat owner is mirela", .{});
    try testing.expectEqual(@as(u64, 1), w.info().auto_merges);
    const hits = try w.recall(testing.allocator, .{ .about = "zorblat quuxcache ttl ninety", .limit = 5 });
    defer freeHits(testing.allocator, hits);
    try testing.expectEqualStrings("zorblat quuxcache ttl raised to hundredtwenty", hits[0].memory.text);
    for (hits) |x| try testing.expect(std.mem.indexOf(u8, x.memory.text, "ninety") == null);
    const o = try w.recall(testing.allocator, .{ .about = "zorblat owner", .limit = 5 });
    defer freeHits(testing.allocator, o);
    try testing.expectEqualStrings("zorblat owner is mirela", o[0].memory.text);
}

test "meaning reaches a memory in other words" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const mn = try Meaning.testModel(testing.allocator);
    defer mn.deinit(testing.allocator);
    const w = try tmpStore(&tmp, mn);
    defer w.close();
    _ = try w.remember("p", "the service had an outage on friday", .{});
    _ = try w.remember("p", "lunch was good", .{});
    const hits = try w.recall(testing.allocator, .{ .about = "downtime", .limit = 2 });
    defer freeHits(testing.allocator, hits);
    try testing.expect(hits.len >= 1);
    try testing.expectEqualStrings("the service had an outage on friday", hits[0].memory.text);
}

test "forget erases text, chains survive" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const w = try tmpStore(&tmp, null);
    defer w.close();
    _ = try w.remember("a", "zebra one", .{});
    const two = try w.remember("gone", "zebra two secret", .{});
    _ = try w.remember("a", "zebra three", .{});
    const four = try w.remember("a", "zebra four private", .{});
    try testing.expectEqual(@as(usize, 1), try w.forgetScope("gone"));
    try w.forget(four);
    const hits = try w.recall(testing.allocator, .{ .about = "zebra", .limit = 10 });
    defer freeHits(testing.allocator, hits);
    try testing.expectEqual(@as(usize, 2), hits.len);
    try testing.expect((try w.get(testing.allocator, two)) == null);
    try w.sync();
    const bytes = try tmp.dir.readFileAlloc(testing.io, "s/lane-000.sdm", testing.allocator, .unlimited);
    defer testing.allocator.free(bytes);
    try testing.expect(std.mem.indexOf(u8, bytes, "secret") == null);
    try testing.expect(std.mem.indexOf(u8, bytes, "private") == null);
}

test "reopen from snapshot, and after a crash with a torn tail" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        const w = try tmpStore(&tmp, null);
        defer w.close();
        for (0..200) |i| {
            var b: [64]u8 = undefined;
            _ = try w.remember("s", try std.fmt.bufPrint(&b, "memory {d} zebra{d}", .{ i, i % 7 }), .{ .subject = if (i % 50 == 0) "pinned" else null });
        }
        _ = try w.forgetScope("nothing/here");
    }
    {
        const w = try tmpStore(&tmp, null);
        defer w.close();
        try testing.expectEqual(@as(u64, 200), w.count);
        const hits = try w.recall(testing.allocator, .{ .about = "zebra3", .limit = 100 });
        defer freeHits(testing.allocator, hits);
        try testing.expect(hits.len > 20);
        for (0..10) |i| {
            var b: [64]u8 = undefined;
            _ = try w.remember("s", try std.fmt.bufPrint(&b, "late {d} zebra3", .{i}), .{});
        }
        try w.sync();
        // As a crash would: no closing snapshot.
        w.snap_progress = w.progress();
    }
    {
        // And a torn record at the end.
        var sub = try tmp.dir.openDir(testing.io, "s", .{});
        defer sub.close(testing.io);
        var f = try sub.openFile(testing.io, "lane-000.sdm", .{ .mode = .read_write });
        defer f.close(testing.io);
        const garbage: [40]u8 = @splat(0xab);
        try f.writePositionalAll(testing.io, &garbage, try f.length(testing.io));
    }
    const w = try tmpStore(&tmp, null);
    defer w.close();
    try testing.expectEqual(@as(u64, 210), w.count);
    const cur = (try w.current(testing.allocator, "s", "pinned")).?;
    defer cur.deinit(testing.allocator);
    try testing.expectEqualStrings("memory 150 zebra3", cur.text);
    const late = try w.recall(testing.allocator, .{ .about = "late zebra3", .limit = 20 });
    defer freeHits(testing.allocator, late);
    for (late[0..10]) |x| try testing.expect(std.mem.startsWith(u8, x.memory.text, "late "));
}

test "two writers, one store: each has its lane and sees the other" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = try tmpStore(&tmp, null);
    defer a.close();
    const b = try tmpStore(&tmp, null);
    defer b.close();
    try testing.expect(a.me != b.me);
    _ = try a.remember("p", "alpha wrote quokka notes", .{ .subject = "notes" });
    _ = try b.remember("p", "beta wrote quokka summary", .{});
    try a.sync();
    try b.sync();
    try a.refresh();
    try b.refresh();
    for ([_]*Stratum{ a, b }) |s| {
        const hits = try s.recall(testing.allocator, .{ .about = "quokka", .limit = 10 });
        defer freeHits(testing.allocator, hits);
        try testing.expectEqual(@as(usize, 2), hits.len);
    }
    // A newer version written by the other writer replaces the fact for both.
    _ = try b.remember("p", "beta replaced quokka notes", .{ .subject = "notes" });
    try b.sync();
    try a.refresh();
    const c = (try a.current(testing.allocator, "p", "notes")).?;
    defer c.deinit(testing.allocator);
    try testing.expectEqualStrings("beta replaced quokka notes", c.text);
    // Forgetting through one writer hides the other writer's memory too.
    _ = try a.forgetScope("p");
    try a.sync();
    try b.refresh();
    const none = try b.recall(testing.allocator, .{ .about = "quokka", .limit = 10 });
    defer freeHits(testing.allocator, none);
    try testing.expectEqual(@as(usize, 0), none.len);
}

test "writers that have not seen each other: get, backdated writes, one answer per head" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = try tmpStore(&tmp, null);
    defer a.close();
    const b = try tmpStore(&tmp, null);
    defer b.close();
    // `get` picks up the other writer's new memory.
    const bid = try b.remember("q", "beta wrote this", .{});
    const got = (try a.get(testing.allocator, bid)).?;
    got.deinit(testing.allocator);
    // A backdated write made after another writer's forget survives it.
    _ = try a.forgetScope("p");
    _ = try b.remember("p", "imported walrus history", .{ .time = 1 });
    try b.refresh();
    const kept = try b.recall(testing.allocator, .{ .about = "walrus", .limit = 10 });
    defer freeHits(testing.allocator, kept);
    try testing.expectEqual(@as(usize, 1), kept.len);
    // Both start the same subject; a later version answers once.
    _ = try a.remember("r", "zeta gadget first draft", .{ .subject = "gadget", .time = 100 });
    _ = try b.remember("r", "zeta gadget second draft", .{ .subject = "gadget", .time = 200 });
    try a.refresh();
    _ = try a.remember("r", "zeta gadget final", .{ .subject = "gadget", .time = 300 });
    const hits = try a.recall(testing.allocator, .{ .about = "zeta gadget draft", .limit = 10 });
    defer freeHits(testing.allocator, hits);
    try testing.expectEqual(@as(usize, 1), hits.len);
    try testing.expectEqualStrings("zeta gadget final", hits[0].memory.text);
}

test "importing an older version changes nothing, before or after reopening" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        const w = try tmpStore(&tmp, null);
        defer w.close();
        _ = try w.remember("m", "plan is blue", .{ .subject = "plan", .time = 300 });
        _ = try w.remember("m", "plan was red", .{ .subject = "plan", .time = 100 });
        const c = (try w.current(testing.allocator, "m", "plan")).?;
        defer c.deinit(testing.allocator);
        try testing.expectEqualStrings("plan is blue", c.text);
        // Recent lists by when memories were written.
        const r = try w.recent(testing.allocator, "m", 1);
        defer freeMemories(testing.allocator, r);
        try testing.expectEqualStrings("plan was red", r[0].text);
    }
    const w = try tmpStore(&tmp, null);
    defer w.close();
    const c = (try w.current(testing.allocator, "m", "plan")).?;
    defer c.deinit(testing.allocator);
    try testing.expectEqualStrings("plan is blue", c.text);
}

test "since applies to the version returned" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const w = try tmpStore(&tmp, null);
    defer w.close();
    _ = try w.remember("m", "kumquat price is three", .{ .subject = "price", .time = 100 });
    _ = try w.remember("m", "now it costs five", .{ .subject = "price", .time = 300 });
    const hits = try w.recall(testing.allocator, .{ .about = "kumquat price", .since = 200, .limit = 5 });
    defer freeHits(testing.allocator, hits);
    try testing.expectEqual(@as(usize, 1), hits.len);
    try testing.expectEqualStrings("now it costs five", hits[0].memory.text);
}

test "a lane taken over after a snapshot still erases forgotten text" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = try tmpStore(&tmp, null);
    defer a.close();
    {
        const b = try tmpStore(&tmp, null);
        defer b.close();
        _ = try b.remember("s", "secret zebracode", .{});
    }
    _ = try a.forgetScope("s");
    try a.snapshot();
    const c = try tmpStore(&tmp, null);
    c.close();
    var sub = try tmp.dir.openDir(testing.io, "s", .{});
    defer sub.close(testing.io);
    const bytes = try sub.readFileAlloc(testing.io, "lane-001.sdm", testing.allocator, .unlimited);
    defer testing.allocator.free(bytes);
    try testing.expect(std.mem.indexOf(u8, bytes, "zebracode") == null);
}

test "rememberMany matches one-by-one writes" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const w = try tmpStore(&tmp, null);
    defer w.close();
    var items: [600]Item = undefined;
    var bufs: [600][48]u8 = undefined;
    for (&items, 0..) |*it, i| it.* = .{ .scope = if (i % 2 == 0) "x" else "y", .text = try std.fmt.bufPrint(&bufs[i], "bulk item {d} kiwi{d}", .{ i, i % 5 }) };
    _ = try w.rememberMany(&items);
    const hits = try w.recall(testing.allocator, .{ .about = "kiwi3", .scope = "y", .limit = 100 });
    defer freeHits(testing.allocator, hits);
    try testing.expectEqual(@as(usize, 60), hits.len);
}

test "brief fits the budget and holds one version per fact" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const w = try tmpStore(&tmp, null);
    defer w.close();
    _ = try w.remember("p", "deploy target is staging", .{ .subject = "target" });
    _ = try w.remember("p", "deploy target is production", .{ .subject = "target" });
    for (0..50) |i| {
        var b: [64]u8 = undefined;
        _ = try w.remember("p", try std.fmt.bufPrint(&b, "chatter {d} about the weather", .{i}), .{});
    }
    const b = try w.brief(testing.allocator, "where do we deploy?", "p", 120);
    defer b.deinit(testing.allocator);
    try testing.expect(b.tokens <= 120);
    try testing.expect(std.mem.indexOf(u8, b.text, "production") != null);
    try testing.expect(std.mem.indexOf(u8, b.text, "staging") == null);
}

test {
    _ = tables;
}
