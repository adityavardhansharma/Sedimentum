//! Loom: agent memory that learns the shape of what it is told.
//!
//! Most memory stores keep text and an index of its words, and leave it to
//! the reader to work out which memories say the same thing. Loom learns
//! that from the memories themselves. Every memory that names something
//! rare next to a value is a claim; from all claims together the store
//! learns how claims are worded (frames), which wordings state the same
//! attribute (slots), and lays every claim into a grid of names x slots
//! whose cells hold an attribute's versions, newest on top (Weave.zig).
//! What one name teaches carries over to every other name.
//!
//! Underneath, the plumbing is Loom's, kept as it was:
//!
//!   Lexicon   word (a u64, see words.zig) -> term id; per term its count
//!             and its postings.
//!   Postings  per term (and per scope), the ordinals that contain it.
//!   Timeline  per ordinal: where its record is, its scope and flags.
//!   Subjects  versions a writer tied together with a subject share a cell.
//!   Lanes     one append-only file per writer process, the only source of
//!             truth, text entropy-coded with the lane's own word model
//!             (ans.zig), mapped back from a snapshot written at close.
//!
//! New in Loom:
//!
//!   Claims    a flag on the memories that state something, set when they
//!             are written (no other per-claim state is kept, on disk or in
//!             RAM). The weave reads the newest claims' words back from
//!             their text when it is rebuilt.
//!   Weave     the frames, slots and grid, rebuilt from the claims when
//!             they have grown by an eighth (Weave.zig). Recall answers
//!             with a cell's newest claim, and matches questions against
//!             a slot's pooled wording instead of one memory's words.
//!   Write     nothing is linked when written: no lookups, no reads.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Crc = std.hash.crc.@"CRC-32/ISCSI";
const words = @import("words.zig");
const ans = @import("ans.zig");
pub const Meaning = @import("Meaning.zig");
pub const Weave = @import("Weave.zig");

const Loom = @This();
const page = std.heap.page_size_min;

// ------------------------------------------------------------------ format

pub const max_lanes = 64;
const data_start: u64 = 4096;
const map_reserve: usize = 1 << 36;
const lane_magic = "LOOMLN01";
const format_version: u32 = 1;
const pub_end_at = 128;
const lane_shift = 40;
const grow_min: u64 = 4 << 20;
const grow_max: u64 = 32 << 20;
const max_models = 255;
const max_text = 64 << 20;

const Kind = enum(u8) { memory = 1, scope = 2, model = 3, forget_scope = 4, forget_one = 5, settle = 6, _ };
const erased_bit: u8 = 0x80;

fn idOf(lane: usize, off: u64) u64 {
    return (@as(u64, lane) << lane_shift) | off;
}
fn laneOf(id: u64) usize {
    return @intCast(id >> lane_shift);
}
fn offOf(id: u64) u64 {
    return id & ((@as(u64, 1) << lane_shift) - 1);
}

/// A record as stored: u32 length, u32 CRC-32C (over the length and every
/// byte from 9 up to the text), a kind byte (its top bit marks erased text,
/// so erasing never breaks the checksum), then the kind's fields.
/// A memory: varint time, scope ref, subject length, model, text length,
/// link (target id + 1, 0 none), then u32 text CRC, subject, coded text.
const Rec = struct {
    len: u32,
    kind: Kind,
    erased: bool,
    body: []const u8,
    time: u64 = 0,
    scope_ref: u32 = 0,
    model: u32 = 0,
    raw_len: u32 = 0,
    link: u64 = 0,
    text_crc: u32 = 0,
    subject: []const u8 = "",
    text: []const u8 = "",
    text_at: u32 = 0,
};

fn parseRec(b: []const u8) ?Rec {
    if (b.len < 9) return null;
    const len = std.mem.readInt(u32, b[0..4], .little);
    if (len < 9 or len > b.len) return null;
    const r = b[0..len];
    const kb = r[8];
    var rec: Rec = .{ .len = len, .kind = @fromBackingInt(@intCast(kb & 0x7f)), .erased = kb & erased_bit != 0, .body = r[9..] };
    var meta_end: usize = len;
    if (rec.kind == .memory) {
        var p: usize = 9;
        rec.time = ans.getVarint(r, &p) catch return null;
        rec.scope_ref = std.math.cast(u32, ans.getVarint(r, &p) catch return null) orelse return null;
        const sl = ans.getVarint(r, &p) catch return null;
        rec.model = std.math.cast(u32, ans.getVarint(r, &p) catch return null) orelse return null;
        rec.raw_len = std.math.cast(u32, ans.getVarint(r, &p) catch return null) orelse return null;
        rec.link = ans.getVarint(r, &p) catch return null;
        if (p + 4 > len or sl > len - p - 4) return null;
        rec.text_crc = std.mem.readInt(u32, r[p..][0..4], .little);
        p += 4;
        rec.subject = r[p..][0..@intCast(sl)];
        p += @intCast(sl);
        meta_end = p;
        rec.text_at = @intCast(p);
        rec.text = r[p..];
        if (rec.raw_len > max_text) return null;
    }
    var c = Crc.init();
    c.update(r[0..4]);
    c.update(r[9..meta_end]);
    if (c.final() != std.mem.readInt(u32, r[4..8], .little)) return null;
    return rec;
}

/// Writes the length and checksum of a record built in `r`.
fn seal(r: []u8, meta_end: usize) void {
    std.mem.writeInt(u32, r[0..4], @intCast(r.len), .little);
    var c = Crc.init();
    c.update(r[0..4]);
    c.update(r[9..meta_end]);
    std.mem.writeInt(u32, r[4..8], c.final(), .little);
}

// ------------------------------------------------------------ flat arrays

/// An array in its own reserved stretch of address space: it never moves,
/// so readers index it without locks while one writer appends. Pages are
/// committed when touched; a snapshot maps its prefix straight from disk.
fn Vec(comptime T: type) type {
    return struct {
        const Self = @This();
        mem: []align(page) u8 = &.{},
        len: usize = 0,

        fn init(v: *Self, b: *Backing, cap: usize) !void {
            v.mem = try b.reserve(null, cap * @sizeOf(T));
            v.len = 0;
        }
        fn deinit(v: *Self, b: *Backing) void {
            if (v.mem.len > 0) b.release(v.mem);
            v.mem = &.{};
            v.len = 0;
        }
        /// Empties it, giving back its pages (also pages mapped from disk).
        fn reset(v: *Self, b: *Backing) !void {
            if (v.mem.len == 0) return;
            _ = try b.reserve(v.mem.ptr, v.mem.len);
            @atomicStore(usize, &v.len, 0, .release);
        }
        inline fn ptr(v: *const Self) [*]T {
            return @ptrCast(@alignCast(v.mem.ptr));
        }
        inline fn count(v: *const Self) usize {
            return @atomicLoad(usize, &v.len, .acquire);
        }
        inline fn at(v: *const Self, i: usize) *T {
            return &v.ptr()[i];
        }
        inline fn get(v: *const Self, i: usize) T {
            return v.ptr()[i];
        }
        fn push(v: *Self, x: T) !u32 {
            const n = v.len;
            if ((n + 1) * @sizeOf(T) > v.mem.len) return error.IndexFull;
            v.ptr()[n] = x;
            @atomicStore(usize, &v.len, n + 1, .release);
            return @intCast(n);
        }
        /// Adds `k` zeroed elements; returns the first.
        fn extend(v: *Self, k: usize) !u32 {
            const n = v.len;
            if ((n + k) * @sizeOf(T) > v.mem.len) return error.IndexFull;
            @memset(v.ptr()[n .. n + k], std.mem.zeroes(T));
            @atomicStore(usize, &v.len, n + k, .release);
            return @intCast(n);
        }
        fn items(v: *const Self) []T {
            return v.ptr()[0..v.count()];
        }
        fn any(v: *Self) AnyVec {
            return .{ .mem = &v.mem, .len = &v.len, .size = @sizeOf(T) };
        }
    };
}

/// Address space for an array, committed a 4 KB page at a time as it is
/// touched (never a 2 MB huge page for a few bytes).
fn reserveAnon(at: ?[*]align(page) u8, len: usize) ![]align(page) u8 {
    const m = try std.posix.mmap(at, len, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .NORESERVE = true, .FIXED = at != null }, -1, 0);
    if (builtin.os.tag == .linux) std.posix.madvise(m.ptr, m.len, std.os.linux.MADV.NOHUGEPAGE) catch {};
    return m;
}

/// Where a writer's index pages live while it runs. Each reservation has
/// a stretch of an unnamed scratch file (in the store's folder, gone with
/// the process) set aside, but starts as anonymous memory: a small index
/// is fastest there. Once the index grows past `spill_bytes`, or a
/// reopened index is first written, `Loom.adopt` moves every reservation
/// into its stretch of the file (`shared`), and from then on the pages are
/// the file's: the kernel writes them out and drops them as it needs to,
/// so a large index is not held in anonymous memory. Without O_TMPFILE
/// there, it stays anonymous memory throughout. Only the writer, under its
/// lock, reserves, releases and moves.
const Backing = struct {
    const Res = struct { off: u64, len: usize };
    fd: i32 = -1,
    /// Reservations are mapped from the file (after `Loom.adopt`).
    shared: bool = false,
    /// End of the file, where the next reservation goes.
    end: u64 = 0,
    /// Start address -> its stretch of the file.
    offs: std.AutoHashMapUnmanaged(usize, Res) = .empty,
    gpa: Allocator = undefined,

    const align_to: u64 = 1 << 21;

    fn open(b: *Backing, gpa: Allocator, dir_fd: i32) void {
        b.gpa = gpa;
        if (builtin.os.tag != .linux) return;
        const linux = std.os.linux;
        const rc = linux.openat(dir_fd, ".", .{ .ACCMODE = .RDWR, .TMPFILE = true, .DIRECTORY = true, .CLOEXEC = true }, 0o600);
        if (linux.errno(rc) != .SUCCESS) return;
        b.fd = @intCast(rc);
    }

    fn close(b: *Backing) void {
        b.offs.deinit(b.gpa);
        if (b.fd >= 0) _ = std.os.linux.close(b.fd);
        b.fd = -1;
    }

    /// Zeroed pages for `len` bytes, at `at` (which then holds zeros
    /// again) or anywhere.
    fn reserve(b: *Backing, at: ?[*]align(page) u8, len: usize) ![]align(page) u8 {
        if (b.fd < 0) return reserveAnon(at, len);
        const linux = std.os.linux;
        if (at) |p| {
            const r = b.offs.get(@intFromPtr(p)) orelse return reserveAnon(at, len);
            b.punch(r.off, len);
            if (!b.shared) return reserveAnon(at, len);
            return b.mapShared(p, r);
        }
        const off = b.end;
        const next = off + std.mem.alignForward(u64, len, align_to);
        if (linux.errno(linux.ftruncate(b.fd, @intCast(next))) != .SUCCESS) return reserveAnon(null, len);
        b.end = next;
        const m = if (b.shared)
            std.posix.mmap(null, len, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED, .NORESERVE = true }, b.fd, off) catch return reserveAnon(null, len)
        else
            try reserveAnon(null, len);
        if (b.shared) std.posix.madvise(m.ptr, m.len, linux.MADV.NOHUGEPAGE) catch {};
        b.offs.put(b.gpa, @intFromPtr(m.ptr), .{ .off = off, .len = len }) catch {
            std.posix.munmap(m);
            return reserveAnon(null, len);
        };
        return m;
    }

    /// Maps reservation `r` at `p` from the file.
    fn mapShared(b: *Backing, p: [*]align(page) u8, r: Res) ![]align(page) u8 {
        const m = try std.posix.mmap(p, r.len, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED, .NORESERVE = true, .FIXED = true }, b.fd, r.off);
        std.posix.madvise(m.ptr, m.len, std.os.linux.MADV.NOHUGEPAGE) catch {};
        return m;
    }

    /// Moves the first `used` bytes of the reservation at `p` into the
    /// file, and maps all of it from there. False if it is not one of
    /// ours or the file could not take it (it is then left as it was).
    fn move(b: *Backing, p: [*]align(page) u8, used: usize) bool {
        const r = b.offs.get(@intFromPtr(p)) orelse return false;
        const n = @min(std.mem.alignForward(usize, used, page), r.len);
        var done: usize = 0;
        while (done < n) {
            const rc = std.os.linux.pwrite(b.fd, p + done, n - done, @intCast(r.off + done));
            if (std.os.linux.errno(rc) != .SUCCESS or rc == 0) return false;
            done += rc;
        }
        _ = b.mapShared(p, r) catch return false;
        return true;
    }

    /// Unmaps a reservation and gives its disk space back.
    fn release(b: *Backing, mem: []align(page) u8) void {
        std.posix.munmap(mem);
        if (b.fd < 0) return;
        if (b.offs.fetchRemove(@intFromPtr(mem.ptr))) |kv| b.punch(kv.value.off, kv.value.len);
    }

    fn punch(b: *Backing, off: u64, len: usize) void {
        const linux = std.os.linux;
        _ = linux.fallocate(b.fd, linux.FALLOC.FL_PUNCH_HOLE | linux.FALLOC.FL_KEEP_SIZE, @intCast(off), @intCast(std.mem.alignForward(usize, len, page)));
    }
};

const AnyVec = struct { mem: *[]align(page) u8, len: *usize, size: usize };

/// u64 -> u64, insert and update. Readers: `get`, lock-free. One writer.
/// Tables live in their own mapped memory, so a snapshot maps them back
/// from disk. A table that grows is replaced; the old one is freed once no
/// reader can still hold it (see `Readers`).
const Map = struct {
    const Table = struct {
        shift: u6,
        cap: usize,
        mem: []align(page) u8,
        fn keys(t: *const Table) []u64 {
            return @as([*]u64, @ptrCast(@alignCast(t.mem.ptr)))[0..t.cap];
        }
        fn vals(t: *const Table) []u64 {
            return @as([*]u64, @ptrCast(@alignCast(t.mem.ptr)))[t.cap .. 2 * t.cap];
        }
    };
    table: ?*Table = null,
    len: usize = 0,
    retired: std.ArrayList(*Table) = .empty,
    back: *Backing = undefined,

    inline fn enc(k: u64) u64 {
        return if (k == std.math.maxInt(u64)) k else k + 1;
    }
    inline fn slotOf(t: *const Table, e: u64) usize {
        return @intCast((e *% 0x9E3779B97F4A7C15) >> t.shift);
    }

    fn get(m: *const Map, k: u64) ?u64 {
        const t = @atomicLoad(?*Table, &m.table, .acquire) orelse return null;
        const e = enc(k);
        const mask = t.cap - 1;
        const ks = t.keys();
        var i = slotOf(t, e);
        while (true) : (i = (i + 1) & mask) {
            const x = @atomicLoad(u64, &ks[i], .acquire);
            if (x == 0) return null;
            if (x == e) return @atomicLoad(u64, &t.vals()[i], .acquire);
        }
    }

    fn put(m: *Map, gpa: Allocator, k: u64, v: u64) !void {
        if (m.table == null or (m.len + 1) * 4 > m.table.?.cap * 3) try m.grow(gpa, if (m.table) |t| t.cap * 2 else 64);
        const t = m.table.?;
        const e = enc(k);
        const mask = t.cap - 1;
        const ks = t.keys();
        var i = slotOf(t, e);
        while (true) : (i = (i + 1) & mask) {
            const x = ks[i];
            if (x == e) {
                @atomicStore(u64, &t.vals()[i], v, .release);
                return;
            }
            if (x == 0) {
                t.vals()[i] = v;
                @atomicStore(u64, &ks[i], e, .release);
                m.len += 1;
                return;
            }
        }
    }

    fn newTable(m: *Map, gpa: Allocator, cap: usize) !*Table {
        const t = try gpa.create(Table);
        errdefer gpa.destroy(t);
        t.* = .{ .shift = @intCast(64 - @as(u7, std.math.log2_int(usize, cap))), .cap = cap, .mem = try m.back.reserve(null, std.mem.alignForward(usize, cap * 16, page)) };
        return t;
    }

    fn grow(m: *Map, gpa: Allocator, cap: usize) !void {
        const t = try m.newTable(gpa, cap);
        const mask = cap - 1;
        if (m.table) |o| {
            const ks = t.keys();
            const vs = t.vals();
            for (o.keys(), o.vals()) |e, v| {
                if (e == 0) continue;
                var i = slotOf(t, e);
                while (ks[i] != 0) i = (i + 1) & mask;
                ks[i] = e;
                vs[i] = v;
            }
            try m.retired.append(gpa, o);
        }
        @atomicStore(?*Table, &m.table, t, .seq_cst);
    }

    fn freeTable(m: *Map, gpa: Allocator, t: *Table) void {
        m.back.release(t.mem);
        gpa.destroy(t);
    }

    /// Frees replaced tables, when no reader is inside a read.
    fn reclaim(m: *Map, gpa: Allocator, readers: *const Readers) void {
        if (m.retired.items.len == 0 or !readers.quiet()) return;
        for (m.retired.items) |t| m.freeTable(gpa, t);
        m.retired.clearRetainingCapacity();
    }

    fn clear(m: *Map, gpa: Allocator) !void {
        if (m.table) |t| try m.retired.append(gpa, t);
        @atomicStore(?*Table, &m.table, null, .seq_cst);
        m.len = 0;
    }

    fn deinit(m: *Map, gpa: Allocator) void {
        if (m.table) |t| m.freeTable(gpa, t);
        for (m.retired.items) |t| m.freeTable(gpa, t);
        m.retired.deinit(gpa);
        m.table = null;
        m.len = 0;
    }

    fn bytes(m: *const Map) usize {
        return if (m.table) |t| t.cap * 16 else 0;
    }
};

/// Readers announce themselves in slots of their own (a cache line each).
/// Memory a writer unlinked is freed only after it has seen every slot
/// empty: a reader that comes later can only find the new memory.
const Readers = struct {
    const nslots = 64;
    const Slot = struct { n: std.atomic.Value(u32) align(std.atomic.cache_line) = .init(0) };
    slots: [nslots]Slot = @splat(.{}),

    threadlocal var my_slot: ?u8 = null;
    var next_slot: std.atomic.Value(u32) = .init(0);

    fn slot(r: *Readers) *std.atomic.Value(u32) {
        const s = my_slot orelse blk: {
            const x: u8 = @intCast(next_slot.fetchAdd(1, .monotonic) % nslots);
            my_slot = x;
            break :blk x;
        };
        return &r.slots[s].n;
    }
    fn enter(r: *Readers) void {
        _ = r.slot().fetchAdd(1, .seq_cst);
    }
    fn leave(r: *Readers) void {
        _ = r.slot().fetchSub(1, .release);
    }
    fn quiet(r: *const Readers) bool {
        for (&r.slots) |*sl| if (sl.n.load(.seq_cst) != 0) return false;
        return true;
    }
};

/// A mutex for short sections: spins a little before sleeping.
const Lock = struct {
    state: std.atomic.Value(u32) = .init(0),

    fn lock(l: *Lock, io: Io) void {
        var spins: usize = 0;
        while (spins < 200) : (spins += 1) {
            if (l.state.load(.monotonic) == 0 and l.state.cmpxchgWeak(0, 1, .acquire, .monotonic) == null) return;
            std.atomic.spinLoopHint();
        }
        while (l.state.swap(2, .acquire) != 0) io.futexWaitUncancelable(u32, &l.state.raw, 2);
    }

    fn unlock(l: *Lock, io: Io) void {
        if (l.state.swap(0, .release) == 2) io.futexWake(u32, &l.state.raw, 1);
    }
};

// ------------------------------------------------------------------- state

pub const Options = struct {
    /// Every write is durable before it returns. Off: call `sync`.
    sync_writes: bool = true,
    /// How fast recency fades in ranking (old memories keep 85%).
    half_life_ms: u64 = 7 * 24 * 3600 * 1000,
    /// Word meanings; with them, questions in other words find memories.
    meaning: ?*const Meaning = null,
    /// A background thread makes writes durable as they come. Writers take
    /// a `promise` and wait on it only before acting outside the machine.
    flusher: bool = false,
};

const Lane = struct {
    file: Io.File,
    map: []align(page) u8,
    /// Records before this offset are in the index.
    end: u64 = data_start,
    idle: bool = false,
    models: [max_models]*ans.Model = undefined,
    nmodels: usize = 0,
    model_offs: std.ArrayList(u64) = .empty,
    /// Lane scope ref -> scope id.
    scope_refs: std.ArrayList(u32) = .empty,
    /// Ordinals of this lane's memories, in record order.
    ords: Vec(u32) = .{},

    fn published(l: *const Lane) u64 {
        const p: *const u64 = @ptrCast(@alignCast(l.map[pub_end_at..][0..8]));
        return @atomicLoad(u64, p, .acquire);
    }
    fn model(l: *const Lane, id: u32) ?*ans.Model {
        if (id == 0 or id > @atomicLoad(usize, &l.nmodels, .acquire)) return null;
        return l.models[id - 1];
    }
};

const Cell = extern struct { head: u32, root: u32, nver: u32 };

const no_posts: u32 = std.math.maxInt(u32);
const flag_forgotten: u32 = 1 << 24;
const flag_subject: u32 = 1 << 25;
/// The memory states something (a claim the weave reads).
const flag_claim: u32 = 1 << 26;
const scope_mask: u32 = (1 << 24) - 1;
const vc_len = max_lanes;

gpa: Allocator,
io: Io,
dir: Io.Dir,
options: Options,
clock_override: ?u64 = null,

wlock: Lock = .{},
readers: Readers = .{},
lanes: [max_lanes]Lane = undefined,
nlanes: usize = 0,
me: usize = 0,
end: std.atomic.Value(u64) = .init(data_start),
synced: std.atomic.Value(u64) = .init(data_start),
alloc: u64 = data_start,
syncs: std.atomic.Value(u64) = .init(0),
wseq: std.atomic.Value(u32) = .init(0),
dseq: std.atomic.Value(u32) = .init(0),
flusher_waiting: std.atomic.Value(bool) = .init(false),
flusher_stop: std.atomic.Value(bool) = .init(false),
flusher_err: std.atomic.Value(u16) = .init(0),
flusher_thread: ?std.Thread = null,
erase_pending: bool = false,
erase_lo: u64 = std.math.maxInt(u64),
erase_hi: u64 = 0,
last_refresh: std.atomic.Value(i64) = .init(0),
broken: bool = false,
dirty: bool = false,

/// Where the index pages live while this writer runs.
back: Backing = .{},
/// The index has moved into `back`'s file (`adopt`).
adopted: bool = false,
/// The index is the snapshot, mapped copy-on-write: move it before the
/// first write.
spill_now: bool = false,
// Lexicon.
lex: Map = .{},
t_key: Vec(u64) = .{},
t_df: Vec(u32) = .{},
t_p0: Vec(u32) = .{},
t_tail: Vec(u32) = .{},
// Postings blocks: [prev, len | log2(cap) << 16, entries...].
post: Vec(u32) = .{},
// Timeline.
tl_loc: Vec(u64) = .{},
tl_sf: Vec(u32) = .{},
// Facts.
fact_of: Map = .{},
cells: Vec(Cell) = .{},
subjects: Map = .{},
// Scopes: a tree by '/', each with its own postings.
sc_map: Map = .{},
sc_name_off: Vec(u32) = .{},
sc_name_len: Vec(u16) = .{},
sc_names: Vec(u8) = .{},
sc_parent: Vec(u32) = .{},
sc_child: Vec(u32) = .{},
sc_sib: Vec(u32) = .{},
sc_p0: Vec(u32) = .{},
sc_tail: Vec(u32) = .{},
sc_forget: Vec(u32) = .{},
sc_settle: Vec(u32) = .{},
/// Scope id -> our lane's ref + 1.
own_ref: Vec(u32) = .{},
/// Lane-end vectors of forgets and settles, `vc_len` each.
vcs: Vec(u64) = .{},
// Claims: their ordinals. The weave reads their words from the lanes.
// The weave over the claims (Weave.zig). Replaced whole when rebuilt;
// a replaced weave is freed once no reader can hold it.
woven: std.atomic.Value(?*Weave.Woven) = .init(null),
weaving: std.atomic.Value(bool) = .init(false),
/// Claims in the store, counted from the flags when first needed.
nclaims: std.atomic.Value(usize) = .init(0),
nclaims_ready: std.atomic.Value(bool) = .init(false),
retired: std.ArrayList(*Weave.Woven) = .empty,

total_terms: u64 = 0,
merges: u64 = 0,

// Writer state.
counter: ans.Counter,
written: u64 = 0,
next_model_at: u64 = 64,
rec_buf: std.ArrayList(u8) = .empty,
dec_buf: std.ArrayList(u8) = .empty,

fn laneName(buf: *[32]u8, i: usize) []const u8 {
    return std.fmt.bufPrint(buf, "lane-{d:0>3}.lm", .{i}) catch unreachable;
}

fn initVecs(w: *Loom) !void {
    const big: usize = 1 << 30;
    try w.t_key.init(&w.back, 1 << 28);
    try w.t_df.init(&w.back, 1 << 28);
    try w.t_p0.init(&w.back, 1 << 28);
    try w.t_tail.init(&w.back, 1 << 28);
    try w.post.init(&w.back, 1 << 32);
    try w.tl_loc.init(&w.back, big);
    try w.tl_sf.init(&w.back, big);
    try w.cells.init(&w.back, 1 << 28);
    try w.sc_name_off.init(&w.back, 1 << 24);
    try w.sc_name_len.init(&w.back, 1 << 24);
    try w.sc_names.init(&w.back, 1 << 32);
    try w.sc_parent.init(&w.back, 1 << 24);
    try w.sc_child.init(&w.back, 1 << 24);
    try w.sc_sib.init(&w.back, 1 << 24);
    try w.sc_p0.init(&w.back, 1 << 24);
    try w.sc_tail.init(&w.back, 1 << 24);
    try w.sc_forget.init(&w.back, 1 << 24);
    try w.sc_settle.init(&w.back, 1 << 24);
    try w.own_ref.init(&w.back, 1 << 24);
    try w.vcs.init(&w.back, 1 << 26);
}

fn scopeVecs(w: *Loom) [11]AnyVec {
    return .{ w.sc_name_off.any(), w.sc_name_len.any(), w.sc_names.any(), w.sc_parent.any(), w.sc_child.any(), w.sc_sib.any(), w.sc_p0.any(), w.sc_tail.any(), w.sc_forget.any(), w.sc_settle.any(), w.own_ref.any() };
}

/// Every index array, in snapshot order.
fn indexVecs(w: *Loom) [20]AnyVec {
    const s = w.scopeVecs();
    return [_]AnyVec{ w.t_key.any(), w.t_df.any(), w.t_p0.any(), w.t_tail.any(), w.post.any(), w.tl_loc.any(), w.tl_sf.any(), w.cells.any(), w.vcs.any() } ++ s;
}

/// Empty index with its reserved zero entries.
fn resetIndex(w: *Loom) !void {
    for (w.indexVecs()) |v| {
        _ = try w.back.reserve(v.mem.*.ptr, v.mem.*.len);
        @atomicStore(usize, v.len, 0, .release);
    }
    for (w.lanes[0..w.nlanes]) |*l| {
        try l.ords.reset(&w.back);
        l.end = data_start;
        for (l.models[0..l.nmodels]) |m| m.deinit(w.gpa);
        l.nmodels = 0;
        l.model_offs.clearRetainingCapacity();
        l.scope_refs.clearRetainingCapacity();
    }
    try w.lex.clear(w.gpa);
    try w.fact_of.clear(w.gpa);
    try w.subjects.clear(w.gpa);
    try w.sc_map.clear(w.gpa);
    _ = try w.t_key.push(0);
    _ = try w.t_df.push(0);
    _ = try w.t_p0.push(0);
    _ = try w.t_tail.push(0);
    _ = try w.post.push(0);
    _ = try w.cells.push(.{ .head = 0, .root = 0, .nver = 0 });
    _ = try w.vcs.extend(vc_len);
    _ = try w.pushScope("", 0);
    w.total_terms = 0;
    w.merges = 0;
}

pub fn open(gpa: Allocator, io: Io, parent: Io.Dir, sub_path: []const u8, options: Options) !*Loom {
    var dir = try parent.createDirPathOpen(io, sub_path, .{});
    errdefer dir.close(io);
    const w = try gpa.create(Loom);
    errdefer gpa.destroy(w);
    w.* = .{ .gpa = gpa, .io = io, .dir = dir, .options = options, .counter = .init(gpa) };
    errdefer w.freeAll();
    w.back.open(gpa, dir.handle);
    for ([_]*Map{ &w.lex, &w.fact_of, &w.subjects, &w.sc_map }) |m| m.back = &w.back;
    try w.initVecs();

    // Claim the first lane no other writer holds. The OS drops the lock
    // when its holder dies, so a crashed writer's lane is reused.
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
        const len = try own.length(io);
        if (len < data_start) {
            var head: [data_start]u8 = @splat(0);
            @memcpy(head[0..8], lane_magic);
            std.mem.writeInt(u32, head[8..12], format_version, .little);
            std.mem.writeInt(u64, head[pub_end_at..][0..8], data_start, .little);
            try own.writePositionalAll(io, &head, 0);
            try own.sync(io);
        } else {
            var h: [12]u8 = undefined;
            if (try own.readPositionalAll(io, &h, 0) != 12) return error.Corrupt;
            if (!std.mem.eql(u8, h[0..8], lane_magic)) return error.Corrupt;
            if (std.mem.readInt(u32, h[8..12], .little) != format_version) return error.UnsupportedFormat;
        }
    }
    var i: usize = 0;
    while (i < max_lanes) : (i += 1) {
        if (i == w.me) {
            try w.addLane(own, true, false);
            continue;
        }
        if (!try w.openLane(i)) break;
    }
    if (w.nlanes <= w.me) return error.Corrupt;
    w.alloc = try own.length(w.io);
    try w.loadIndex();
    if (options.flusher) w.flusher_thread = try std.Thread.spawn(.{}, flusherLoop, .{w});
    return w;
}

fn addLane(w: *Loom, file: Io.File, writable: bool, idle: bool) !void {
    const map = try std.posix.mmap(null, map_reserve, .{ .READ = true, .WRITE = writable }, .{ .TYPE = .SHARED }, file.handle, 0);
    errdefer std.posix.munmap(map);
    var l: Lane = .{ .file = file, .map = map, .idle = idle };
    try l.ords.init(&w.back, 1 << 28);
    w.lanes[w.nlanes] = l;
    @atomicStore(usize, &w.nlanes, w.nlanes + 1, .release);
}

/// Opens lane `i` for reading. False when it does not exist (yet).
fn openLane(w: *Loom, i: usize) !bool {
    var nb: [32]u8 = undefined;
    // A lane no writer holds may have records past the end it published:
    // hold its lock until it has been read by its records.
    var idle = true;
    const f = w.dir.openFile(w.io, laneName(&nb, i), .{ .lock = .exclusive, .lock_nonblocking = true }) catch |err| switch (err) {
        error.FileNotFound => return false,
        error.WouldBlock => blk: {
            idle = false;
            break :blk w.dir.openFile(w.io, laneName(&nb, i), .{}) catch |e2| switch (e2) {
                error.FileNotFound => return false,
                else => |e| return e,
            };
        },
        else => |e| return e,
    };
    errdefer f.close(w.io);
    // Being created by its writer right now: look again later.
    if (try f.length(w.io) < data_start) {
        f.close(w.io);
        return false;
    }
    var h: [12]u8 = undefined;
    if (try f.readPositionalAll(w.io, &h, 0) != 12) return error.Corrupt;
    if (!std.mem.eql(u8, h[0..8], lane_magic)) return error.Corrupt;
    if (std.mem.readInt(u32, h[8..12], .little) != format_version) return error.UnsupportedFormat;
    try w.addLane(f, false, idle);
    return true;
}

fn freeAll(w: *Loom) void {
    const gpa = w.gpa;
    for (w.lanes[0..w.nlanes]) |*l| {
        for (l.models[0..l.nmodels]) |m| m.deinit(gpa);
        l.model_offs.deinit(gpa);
        l.scope_refs.deinit(gpa);
        l.ords.deinit(&w.back);
        std.posix.munmap(l.map);
        l.file.close(w.io);
    }
    w.nlanes = 0;
    for (w.indexVecs()) |v| if (v.mem.*.len > 0) {
        w.back.release(v.mem.*);
        v.mem.* = &.{};
    };
    w.lex.deinit(gpa);
    w.fact_of.deinit(gpa);
    w.subjects.deinit(gpa);
    w.sc_map.deinit(gpa);
    if (w.woven.load(.acquire)) |wv| wv.deinit(gpa);
    w.woven.store(null, .release);
    for (w.retired.items) |wv| wv.deinit(gpa);
    w.retired.deinit(gpa);
    w.counter.deinit(gpa);
    w.back.close();
    w.rec_buf.deinit(gpa);
    w.dec_buf.deinit(gpa);
}

pub fn close(w: *Loom) void {
    if (w.flusher_thread) |t| {
        w.flusher_stop.store(true, .release);
        _ = w.wseq.fetchAdd(1, .release);
        w.io.futexWake(u32, &w.wseq.raw, 1);
        t.join();
        w.flusher_thread = null;
    }
    w.wlock.lock(w.io);
    if (w.dirty and !w.broken) w.writeSnapshot() catch {};
    // Give back the space reserved ahead.
    if (!w.broken) w.lanes[w.me].file.setLength(w.io, w.end.load(.acquire)) catch {};
    w.wlock.unlock(w.io);
    const gpa = w.gpa;
    w.freeAll();
    w.dir.close(w.io);
    gpa.destroy(w);
}

pub fn setClockForTest(w: *Loom, ms: ?u64) void {
    w.clock_override = ms;
}

fn nowMs(w: *const Loom) u64 {
    if (w.clock_override) |t| return t;
    const ns = Io.Clock.real.now(w.io).nanoseconds;
    return @intCast(@divTrunc(ns, std.time.ns_per_ms));
}

fn monoMs(w: *const Loom) i64 {
    return @intCast(@divTrunc(Io.Clock.awake.now(w.io).nanoseconds, std.time.ns_per_ms));
}

// ------------------------------------------------------------------ scopes

fn scopeHash(name: []const u8) u64 {
    return std.hash.Wyhash.hash(0x5c09e, name);
}

pub fn scopeName(w: *const Loom, sid: u32) []const u8 {
    const off = w.sc_name_off.get(sid);
    return w.sc_names.ptr()[off..][0..w.sc_name_len.get(sid)];
}

fn scopeId(w: *const Loom, name: []const u8) ?u32 {
    const v = w.sc_map.get(scopeHash(name)) orelse return null;
    const sid: u32 = @intCast(v);
    if (!std.mem.eql(u8, w.scopeName(sid), name)) return null;
    return sid;
}

fn pushScope(w: *Loom, name: []const u8, parent: u32) !u32 {
    const off = try w.sc_names.extend(name.len);
    @memcpy(w.sc_names.ptr()[off..][0..name.len], name);
    _ = try w.sc_name_off.push(off);
    _ = try w.sc_name_len.push(@intCast(name.len));
    _ = try w.sc_parent.push(parent);
    _ = try w.sc_child.push(0);
    _ = try w.sc_sib.push(if (parent != 0 or name.len > 0) w.sc_child.get(parent) else 0);
    _ = try w.sc_p0.push(0);
    _ = try w.sc_tail.push(0);
    _ = try w.sc_forget.push(0);
    _ = try w.sc_settle.push(0);
    const sid = try w.own_ref.push(0);
    if (name.len > 0) {
        @atomicStore(u32, w.sc_child.at(parent), sid, .release);
        try w.sc_map.put(w.gpa, scopeHash(name), sid);
    }
    return sid;
}

/// The scope's id, made (with its parents) if new. Writer only.
fn ensureScope(w: *Loom, name: []const u8) !u32 {
    if (w.scopeId(name)) |s| return s;
    const parent: u32 = if (std.mem.lastIndexOfScalar(u8, name, '/')) |i| (if (i > 0) try w.ensureScope(name[0..i]) else 0) else 0;
    return w.pushScope(name, parent);
}

fn underScope(w: *const Loom, sid: u32, root: u32) bool {
    var s = sid;
    var depth: usize = 0;
    while (s != 0 and depth < 256) : (depth += 1) {
        if (s == root) return true;
        s = w.sc_parent.get(s);
    }
    return false;
}

/// Ids of a scope and every scope below it.
fn subtree(w: *const Loom, gpa: Allocator, root: u32, out: *std.ArrayList(u32)) !void {
    try out.append(gpa, root);
    var i: usize = out.items.len - 1;
    while (i < out.items.len) : (i += 1) {
        var c = @atomicLoad(u32, w.sc_child.at(out.items[i]), .acquire);
        while (c != 0) : (c = w.sc_sib.get(c)) try out.append(gpa, c);
    }
}

const ScopeSet = struct {
    all: bool,
    root: u32 = 0,
    fn has(s: ScopeSet, w: *const Loom, sid: u32) bool {
        return s.all or w.underScope(sid, s.root);
    }
};

fn scopeSet(w: *const Loom, scope: []const u8) ?ScopeSet {
    if (scope.len == 0) return .{ .all = true };
    return .{ .all = false, .root = w.scopeId(scope) orelse return null };
}

// ---------------------------------------------------------------- postings

fn structLimit(n: usize) u32 {
    return @intCast(@max(1024, n >> 10));
}

fn appendPost(w: *Loom, p0: *u32, tail: *u32, ord: u32) !void {
    if (p0.* == 0) {
        @atomicStore(u32, p0, ord + 1, .release);
        return;
    }
    const t = tail.*;
    var cap_log: u5 = 1;
    if (t != 0) {
        const meta = w.post.get(t + 1);
        const len = meta & 0xffff;
        cap_log = @intCast(meta >> 16);
        if (len < (@as(u32, 1) << cap_log)) {
            w.post.at(t + 2 + len).* = ord;
            @atomicStore(u32, w.post.at(t + 1), meta + 1, .release);
            return;
        }
        cap_log = @min(cap_log + 1, 10);
    }
    const b = try w.post.extend(2 + (@as(usize, 1) << cap_log));
    w.post.at(b).* = t;
    w.post.at(b + 2).* = ord;
    @atomicStore(u32, w.post.at(b + 1), 1 | (@as(u32, cap_log) << 16), .release);
    @atomicStore(u32, tail, b, .release);
}

/// A posting list read newest first.
const Posts = struct {
    w: *const Loom,
    blk: u32,
    i: u32,
    p0: u32,

    fn init(w: *const Loom, p0: *const u32, tail: *const u32) Posts {
        const t = @atomicLoad(u32, tail, .acquire);
        const f = @atomicLoad(u32, p0, .acquire);
        if (t == no_posts) return .{ .w = w, .blk = 0, .i = 0, .p0 = 0 };
        var p: Posts = .{ .w = w, .blk = t, .i = 0, .p0 = f };
        if (t != 0) p.i = @atomicLoad(u32, w.post.at(t + 1), .acquire) & 0xffff;
        return p;
    }

    fn next(p: *Posts) ?u32 {
        while (p.blk != 0) {
            if (p.i > 0) {
                p.i -= 1;
                return p.w.post.get(p.blk + 2 + p.i);
            }
            p.blk = p.w.post.get(p.blk);
            if (p.blk != 0) p.i = @atomicLoad(u32, p.w.post.at(p.blk + 1), .acquire) & 0xffff;
        }
        if (p.p0 != 0) {
            const o = p.p0 - 1;
            p.p0 = 0;
            return o;
        }
        return null;
    }
};

fn termPosts(w: *const Loom, tid: u32) Posts {
    return Posts.init(w, w.t_p0.at(tid), w.t_tail.at(tid));
}
fn scopePosts(w: *const Loom, sid: u32) Posts {
    return Posts.init(w, w.sc_p0.at(sid), w.sc_tail.at(sid));
}

/// Several posting lists merged, newest first.
const Merge = struct {
    lists: std.ArrayList(Posts) = .empty,
    heads: std.ArrayList(?u32) = .empty,

    fn deinit(m: *Merge, gpa: Allocator) void {
        m.lists.deinit(gpa);
        m.heads.deinit(gpa);
    }
    fn add(m: *Merge, gpa: Allocator, p: Posts) !void {
        var q = p;
        try m.heads.append(gpa, q.next());
        try m.lists.append(gpa, q);
    }
    fn next(m: *Merge) ?u32 {
        var bi: ?usize = null;
        for (m.heads.items, 0..) |h, i| if (h) |v| {
            if (bi == null or v > m.heads.items[bi.?].?) bi = i;
        };
        const i = bi orelse return null;
        const v = m.heads.items[i].?;
        m.heads.items[i] = m.lists.items[i].next();
        return v;
    }
};

// ------------------------------------------------------------------ lookup

/// A lexicon value with this bit holds the one memory of a word seen once
/// (its ordinal), instead of a term id: most words are seen once, and they
/// cost one table slot and nothing else.
const once_bit: u64 = 1 << 63;

/// A word's term id; 0 for a word seen once or never.
fn termId(w: *const Loom, key: u64) u32 {
    const v = w.lex.get(key) orelse return 0;
    return if (v & once_bit != 0) 0 else @intCast(v);
}

fn df(w: *const Loom, tid: u32) u32 {
    return if (tid == 0) 0 else @atomicLoad(u32, w.t_df.at(tid), .monotonic);
}

/// How many memories a word is in.
fn dfOf(w: *const Loom, key: u64) u32 {
    const v = w.lex.get(key) orelse return 0;
    return if (v & once_bit != 0) 1 else w.df(@intCast(v));
}

/// A word's postings, newest first (empty for a word too common to keep any).
fn postsOf(w: *const Loom, key: u64) Posts {
    const v = w.lex.get(key) orelse return .{ .w = w, .blk = 0, .i = 0, .p0 = 0 };
    if (v & once_bit != 0) return .{ .w = w, .blk = 0, .i = 0, .p0 = @as(u32, @truncate(v)) + 1 };
    return w.termPosts(@intCast(v));
}

fn memCount(w: *const Loom) usize {
    return w.tl_loc.count();
}

/// Bits a word carries: log2 of how many memories per one that has it.
fn idf(w: *const Loom, d: u32) f32 {
    const n: f32 = @floatFromInt(w.memCount() + 1);
    return @max(0.0, std.math.log2(n / (@as(f32, @floatFromInt(d)) + 0.5)));
}

fn alive(w: *const Loom, ord: u32) bool {
    if (ord >= w.memCount()) return false;
    return @atomicLoad(u32, w.tl_sf.at(ord), .acquire) & flag_forgotten == 0;
}

fn sidOf(w: *const Loom, ord: u32) u32 {
    return @atomicLoad(u32, w.tl_sf.at(ord), .acquire) & scope_mask;
}

fn cellOf(w: *const Loom, ord: u32) u32 {
    return @intCast(w.fact_of.get(ord) orelse 0);
}

/// The newest version of the fact `ord` belongs to.
fn headOf(w: *const Loom, ord: u32) u32 {
    const c = w.cellOf(ord);
    if (c == 0) return ord;
    return @atomicLoad(u32, &w.cells.at(c).head, .acquire);
}

fn vcHas(w: *const Loom, v: u32, lane: usize, off: u64) bool {
    return v != 0 and off < w.vcs.get(@as(usize, v) * vc_len + lane);
}

fn settled(w: *const Loom, ord: u32) bool {
    const id = w.tl_loc.get(ord);
    var s = w.sidOf(ord);
    var depth: usize = 0;
    while (s != 0 and depth < 256) : (depth += 1) {
        if (w.vcHas(@atomicLoad(u32, w.sc_settle.at(s), .acquire), laneOf(id), offOf(id))) return true;
        s = w.sc_parent.get(s);
    }
    return false;
}

/// An older version of its fact, or settled under a summary.
/// The newest version of `ord`: by its subject, or by the weave's grid
/// (the newest live claim of its cell), whichever is newer.
fn newestOf(w: *const Loom, ord: u32) u32 {
    const wv = w.woven.load(.acquire) orelse return w.headOf(ord);
    return w.newestFrom(ord, w.factOf(wv, ord));
}

/// `newestOf`, with the weave's fact for `ord` already looked up.
fn newestFrom(w: *const Loom, ord: u32, fact: ?Weave.Fact) u32 {
    var h = w.headOf(ord);
    const wv = w.woven.load(.acquire) orelse return h;
    if (fact) |f| {
        if (f.head > h and w.alive(f.head)) h = f.head;
    }
    if (h != ord) if (w.factOf(wv, h)) |f| {
        if (f.head > h and w.alive(f.head)) h = f.head;
    };
    return h;
}

/// Which fact `ord` is a version of: the subject its writer gave it, else
/// its grid cell, else itself. Two facts can share a name by chance; a
/// subject is the writer's word.
fn factKey(w: *const Loom, ord: u32) u64 {
    const wv = w.woven.load(.acquire) orelse return w.factKeyOf(ord, null);
    return w.factKeyOf(ord, w.factOf(wv, ord));
}

/// `factKey` with the weave's fact for `ord` already looked up.
fn factKeyOf(w: *const Loom, ord: u32, fact: ?Weave.Fact) u64 {
    const c = w.cellOf(ord);
    if (c != 0) return (@as(u64, 1) << 32) | c;
    if (fact) |f| return (@as(u64, 2) << 32) | f.cell;
    return ord;
}

fn isBuried(w: *const Loom, ord: u32) bool {
    return w.newestOf(ord) != ord or w.settled(ord);
}

/// Bytes of lane `l` the index may read.
fn laneBytes(w: *const Loom, l: usize) []const u8 {
    const lane = &w.lanes[l];
    const e = if (l == w.me) w.end.load(.acquire) else @atomicLoad(u64, &lane.end, .acquire);
    return lane.map[0..@intCast(e)];
}

fn recOf(w: *const Loom, id: u64) ?Rec {
    const l = laneOf(id);
    if (l >= @atomicLoad(usize, &w.nlanes, .acquire)) return null;
    const b = w.laneBytes(l);
    const off: usize = @intCast(offOf(id));
    if (off < data_start or off >= b.len) return null;
    return parseRec(b[off..]);
}

/// Decodes a memory's text into `out` (exactly `r.raw_len` bytes).
fn decodeText(w: *const Loom, lane: usize, r: *const Rec, out: []u8) !void {
    if (r.model == 0) {
        if (r.text.len != out.len) return error.Corrupt;
        @memcpy(out, r.text);
        return;
    }
    const m = w.lanes[lane].model(r.model) orelse return error.Corrupt;
    try ans.decode(m, r.text, out);
}

fn textIntact(w: *const Loom, id: u64, r: *const Rec) bool {
    _ = w;
    _ = id;
    if (r.erased) return false;
    return Crc.hash(r.text) == r.text_crc;
}

/// Ordinal of a memory id, by binary search in its lane's record order.
fn ordOf(w: *const Loom, id: u64) ?u32 {
    const l = laneOf(id);
    if (l >= @atomicLoad(usize, &w.nlanes, .acquire)) return null;
    const ords = w.lanes[l].ords.items();
    const off = offOf(id);
    var lo: usize = 0;
    var hi: usize = ords.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        const o = offOf(w.tl_loc.get(ords[mid]));
        if (o == off) return ords[mid];
        if (o < off) lo = mid + 1 else hi = mid;
    }
    return null;
}

// ------------------------------------------------------------------ memory

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

/// Copies a live memory out of its lane.
fn load(w: *const Loom, gpa: Allocator, ord: u32) !?Memory {
    if (!w.alive(ord)) return null;
    const id = w.tl_loc.get(ord);
    const r = w.recOf(id) orelse return null;
    if (r.erased) return null;
    const scope = w.scopeName(w.sidOf(ord));
    const bytes = try gpa.alloc(u8, scope.len + r.subject.len + r.raw_len);
    errdefer gpa.free(bytes);
    @memcpy(bytes[0..scope.len], scope);
    @memcpy(bytes[scope.len..][0..r.subject.len], r.subject);
    const text = bytes[scope.len + r.subject.len ..];
    w.decodeText(laneOf(id), &r, text) catch |e| {
        if (!w.textIntact(id, &r)) {
            gpa.free(bytes);
            return null;
        }
        return e;
    };
    // Erased while we decoded: that is a forgotten memory.
    if (!w.textIntact(id, &r)) {
        gpa.free(bytes);
        return null;
    }
    return .{ .id = id, .time = r.time, .scope = bytes[0..scope.len], .subject = bytes[scope.len..][0..r.subject.len], .text = text, .raw = bytes };
}

threadlocal var tl_text: [16384]u8 = undefined;

/// A memory's text in a scratch buffer, or null when gone.
fn textOf(w: *const Loom, ord: u32, heap: *std.ArrayList(u8), gpa: Allocator) !?struct { text: []const u8, time: u64, subject: bool } {
    if (!w.alive(ord)) return null;
    const id = w.tl_loc.get(ord);
    const r = w.recOf(id) orelse return null;
    if (r.erased) return null;
    var out: []u8 = undefined;
    if (r.raw_len <= tl_text.len) {
        out = tl_text[0..r.raw_len];
    } else {
        try heap.resize(gpa, r.raw_len);
        out = heap.items;
    }
    w.decodeText(laneOf(id), &r, out) catch return null;
    return .{ .text = out, .time = r.time, .subject = r.subject.len > 0 };
}

// ------------------------------------------------------------------ index

const MemFields = struct {
    time: u64,
    sid: u32,
    subject: []const u8,
    link: u64,
    erased: bool,
};

fn subjectKey(sid: u32, subject: []const u8) u64 {
    return std.hash.Wyhash.hash(@as(u64, sid) *% 0x9E3779B97F4A7C15 +% 7, subject);
}

fn forgottenByVc(w: *const Loom, sid: u32, lane: usize, off: u64) bool {
    var s = sid;
    var depth: usize = 0;
    while (s != 0 and depth < 256) : (depth += 1) {
        if (w.vcHas(w.sc_forget.get(s), lane, off)) return true;
        s = w.sc_parent.get(s);
    }
    return false;
}

/// Frees replaced tables no reader can hold any more. Writer only.
fn reclaim(w: *Loom) void {
    for ([_]*Map{ &w.lex, &w.fact_of, &w.subjects, &w.sc_map }) |m| m.reclaim(w.gpa, &w.readers);
    // Replaced weaves, once no reader can hold one (and nobody is weaving).
    if (w.retired.items.len == 0) return;
    if (w.weaving.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return;
    defer w.weaving.store(false, .release);
    if (!w.readers.quiet()) return;
    for (w.retired.items) |wv| wv.deinit(w.gpa);
    w.retired.clearRetainingCapacity();
}

fn newCell(w: *Loom, ord: u32) !u32 {
    const c = try w.cells.push(.{ .head = ord, .root = ord, .nver = 1 });
    try w.fact_of.put(w.gpa, ord, c);
    return c;
}

fn linkInto(w: *Loom, c: u32, ord: u32) !void {
    try w.fact_of.put(w.gpa, ord, c);
    const cell = w.cells.at(c);
    if (ord > cell.head) @atomicStore(u32, &cell.head, ord, .release);
    cell.nver += 1;
}

/// Adds a memory to the index. `tids` are its terms' ids when known.
fn indexMemory(w: *Loom, lane: usize, off: u64, f: MemFields, terms: *const words.Terms, tids: ?[]const u32) !u32 {
    const ord: u32 = @intCast(w.tl_loc.count());
    if (!w.adopted and (w.spill_now or ord & 1023 == 0 and w.heldBytes() >= spill_bytes)) w.adopt();
    var sf: u32 = f.sid;
    if (f.subject.len > 0) sf |= flag_subject;
    const gone = f.erased or w.forgottenByVc(f.sid, lane, off);
    if (gone) sf |= flag_forgotten;
    _ = try w.tl_sf.push(sf);
    _ = try w.tl_loc.push(idOf(lane, off));
    _ = try w.lanes[lane].ords.push(ord);
    try w.appendPost(w.sc_p0.at(f.sid), w.sc_tail.at(f.sid), ord);
    const n = ord + 1;
    const limit = structLimit(n);
    // How many memories held each word before this one.
    var seen: [words.Terms.cap]u32 = undefined;
    for (terms.items(), 0..) |word, i| {
        w.total_terms += terms.tf[i];
        var tid: u32 = if (tids) |t| t[i] else 0;
        if (tid == 0) {
            const v = w.lex.get(word.key);
            if (v == null) {
                seen[i] = 0;
                try w.lex.put(w.gpa, word.key, once_bit | ord);
                continue;
            }
            if (v.? & once_bit != 0) {
                // Seen a second time: it becomes a term.
                tid = try w.t_key.push(word.key);
                _ = try w.t_df.push(1);
                _ = try w.t_p0.push(@as(u32, @truncate(v.?)) + 1);
                _ = try w.t_tail.push(0);
                try w.lex.put(w.gpa, word.key, tid);
            } else tid = @intCast(v.?);
        }
        const d = w.t_df.at(tid);
        seen[i] = d.*;
        @atomicStore(u32, d, d.* + 1, .monotonic);
        const tail = w.t_tail.at(tid);
        if (tail.* == no_posts) continue;
        if (d.* > limit) {
            // Too common to find anything: it keeps no postings.
            @atomicStore(u32, tail, no_posts, .release);
            continue;
        }
        try w.appendPost(w.t_p0.at(tid), tail, ord);
    }
    if (!gone) try w.pickClaim(ord, seen[0..terms.len], f.subject.len > 0);
    if (f.subject.len > 0) {
        const key = subjectKey(f.sid, f.subject);
        if (w.subjects.get(key)) |c| {
            try w.linkInto(@intCast(c), ord);
        } else {
            try w.subjects.put(w.gpa, key, try w.newCell(ord));
        }
    } else if (f.link != 0) {
        if (w.ordOf(f.link - 1)) |target| {
            const c = w.cellOf(target);
            try w.linkInto(if (c != 0) c else try w.newCell(target), ord);
            w.merges += 1;
        }
    }
    w.dirty = true;
    return ord;
}

/// A word is rare when at most this many memories held it before.
fn rareLimit(n: usize) u32 {
    return @intCast(@max(4, n >> 12));
}

/// Keeps a memory as a claim when it names something rare next to a value:
/// two rare words, or one with a subject. Only its ordinal is kept; the
/// weave reads its words back when it weaves. Writer only.
fn pickClaim(w: *Loom, ord: u32, seen: []const u32, subject: bool) !void {
    const lim = rareLimit(ord + 1);
    var rare: usize = 0;
    for (seen) |d| {
        if (d <= lim) rare += 1;
    }
    if (rare < 2 and !(subject and rare >= 1)) return;
    _ = @atomicRmw(u32, w.tl_sf.at(ord), .Or, flag_claim, .release);
    if (w.nclaims_ready.load(.acquire)) _ = w.nclaims.fetchAdd(1, .monotonic);
}

/// What the weave knows of `ord`, if it is a claim: one flag read for the
/// memories that are not.
fn factOf(w: *const Loom, wv: *const Weave.Woven, ord: u32) ?Weave.Fact {
    if (@atomicLoad(u32, w.tl_sf.at(ord), .acquire) & flag_claim == 0) return null;
    return wv.factOf(ord);
}

// ------------------------------------------------------------------- weave

/// What the weave asks of the store.
const WeaveCtx = struct {
    w: *const Loom,
    heap: *std.ArrayList(u8),
    pub fn df(c: WeaveCtx, key: u64) u32 {
        return c.w.dfOf(key);
    }
    pub fn alive(c: WeaveCtx, ord: u32) bool {
        return c.w.alive(ord);
    }
    /// Versions tied by a subject share a group: their subject cell.
    pub fn group(c: WeaveCtx, ord: u32) u64 {
        if (@atomicLoad(u32, c.w.tl_sf.at(ord), .acquire) & flag_subject == 0) return 0;
        return c.w.cellOf(ord);
    }
    pub fn count(c: WeaveCtx) u64 {
        return c.w.memCount();
    }
    /// A claim's rare words (at most max(4, N/4096) memories hold them)
    /// and every word within six places of one, in text order, repeats
    /// included (a word stated twice has two places); and `span`, the
    /// bytes from two words before its first rare word to two after its
    /// last, in the sentences that hold them.
    pub fn claimWords(c: WeaveCtx, ord: u32, out: *[Weave.max_words]u64, span: *Weave.Span) !usize {
        const t = (try c.w.textOf(ord, c.heap, c.w.gpa)) orelse return 0;
        const All = struct {
            ws: [256]words.Word = undefined,
            n: usize = 0,
            pub fn word(a: *@This(), x: words.Word) void {
                if (a.n == a.ws.len) return;
                a.ws[a.n] = x;
                a.n += 1;
            }
        };
        var all: All = .{};
        words.forEach(t.text, &all);
        const ws = all.ws[0..all.n];
        const lim = rareLimit(c.w.memCount());
        var rare: [Weave.max_words]u16 = undefined;
        var ri: [Weave.max_words]u16 = undefined;
        var nr: usize = 0;
        for (ws, 0..) |word, i| {
            if (nr < rare.len and c.w.dfOf(word.key) <= lim) {
                rare[nr] = word.pos;
                ri[nr] = @intCast(i);
                nr += 1;
            }
        }
        if (nr > 0) {
            const pad = 2;
            const f = ri[0];
            const l = ri[nr - 1];
            var lo: usize = f -| pad;
            while (ws[lo].sent != ws[f].sent) lo += 1;
            var hi: usize = @min(l + pad, ws.len - 1);
            while (ws[hi].sent != ws[l].sent) hi -= 1;
            var end: usize = ws[hi].end;
            if (end < t.text.len and isSentenceEnd(t.text[end])) end += 1;
            if (end <= std.math.maxInt(u16)) span.* = .{ .at = @intCast(ws[lo].at), .len = @intCast(end - ws[lo].at) };
        }
        var k: usize = 0;
        for (ws) |word| {
            if (k == out.len) break;
            for (rare[0..nr]) |p| if (absDiff(word.pos, p) <= 6) {
                out[k] = word.key;
                k += 1;
                break;
            };
        }
        return k;
    }
};

/// The current weave, rebuilt first when the claims have grown by an
/// eighth since it was woven (or at all, while there are fewer than 1024).
/// One thread weaves at a time; the others go on with the weave they have.
/// Call with the readers entered. The weave replaced is freed by the
/// writer when no reader is in (see `reclaim`).
/// How many of the newest claims the weave reads.
const max_woven = 1 << 17;

fn weave(w: *Loom) ?*const Weave.Woven {
    const nc = w.claimCount();
    const cur = w.woven.load(.acquire);
    const have = if (cur) |c| c.claims else 0;
    if (nc == have) return cur;
    if (cur != null and nc >= 1024 and nc < have + have / 8) return cur;
    if (w.weaving.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return cur;
    defer w.weaving.store(false, .release);
    const now = w.woven.load(.acquire);
    if (now != cur) return now;
    // The newest claims only: what a store is told lately is what it is
    // asked about, and the weave's memory stays bounded however large the
    // store grows. Older claims answer as themselves (and by subject).
    var ords: std.ArrayList(u32) = .empty;
    defer ords.deinit(w.gpa);
    var o = w.memCount();
    while (o > 0 and ords.items.len < max_woven) {
        o -= 1;
        if (@atomicLoad(u32, w.tl_sf.at(o), .acquire) & flag_claim != 0) ords.append(w.gpa, @intCast(o)) catch return cur;
    }
    std.mem.reverse(u32, ords.items);
    var heap: std.ArrayList(u8) = .empty;
    defer heap.deinit(w.gpa);
    const nw = Weave.build(w.gpa, ords.items, WeaveCtx{ .w = w, .heap = &heap }) catch return cur;
    nw.claims = nc;
    if (cur) |c| w.retired.append(w.gpa, c) catch {
        // Cannot keep it for later: better a little memory lost than a
        // reader reading freed memory.
    };
    w.woven.store(nw, .release);
    return nw;
}

/// Claims in the store: counted from the flags the first time, then kept
/// up as claims are written. Readers entered.
fn claimCount(w: *Loom) usize {
    if (w.nclaims_ready.load(.acquire)) return w.nclaims.load(.monotonic);
    var n: usize = 0;
    for (0..w.memCount()) |o| {
        if (@atomicLoad(u32, w.tl_sf.at(o), .acquire) & flag_claim != 0) n += 1;
    }
    // Claims written while counting may be counted twice or not at all;
    // that only moves the next rebuild a little.
    w.nclaims.store(n, .monotonic);
    w.nclaims_ready.store(true, .release);
    return n;
}

/// Reads a vector of lane ends: varint count, then the ends.
fn readVc(b: []const u8, p: *usize, out: *[vc_len]u64) !void {
    const n = try ans.getVarint(b, p);
    if (n > vc_len) return error.Corrupt;
    out.* = @splat(0);
    for (0..@intCast(n)) |i| out[i] = try ans.getVarint(b, p);
}

/// Folds a marker's lane ends into a scope's vector (newest wins).
fn mergeVc(w: *Loom, slot: *u32, vc: *const [vc_len]u64) !u32 {
    if (slot.* == 0) {
        const at = try w.vcs.extend(vc_len);
        @atomicStore(u32, slot, @intCast(at / vc_len), .release);
    }
    const base = @as(usize, slot.*) * vc_len;
    for (vc, 0..) |e, i| {
        const p = w.vcs.at(base + i);
        if (e > p.*) @atomicStore(u64, p, e, .release);
    }
    return slot.*;
}

fn setForgotten(w: *Loom, ord: u32) !void {
    if (!w.adopted and w.spill_now) w.adopt();
    const p = w.tl_sf.at(ord);
    const v = p.*;
    if (v & flag_forgotten != 0) return;
    @atomicStore(u32, p, v | flag_forgotten, .release);
    const id = w.tl_loc.get(ord);
    if (laneOf(id) == w.me) try w.eraseOwn(offOf(id));
}

fn applyForgetScope(w: *Loom, name: []const u8, vc: *const [vc_len]u64) !void {
    const sid = try w.ensureScope(name);
    const v = try w.mergeVc(w.sc_forget.at(sid), vc);
    var ids: std.ArrayList(u32) = .empty;
    defer ids.deinit(w.gpa);
    try w.subtree(w.gpa, sid, &ids);
    for (ids.items) |s| {
        var p = w.scopePosts(s);
        while (p.next()) |ord| {
            const id = w.tl_loc.get(ord);
            if (w.vcHas(v, laneOf(id), offOf(id))) try w.setForgotten(ord);
        }
    }
}

/// Puts one record into the index (replay, and other writers' records).
fn ingest(w: *Loom, lane: usize, off: u64, r: *const Rec) !void {
    switch (r.kind) {
        .memory => {
            const refs = w.lanes[lane].scope_refs.items;
            if (r.scope_ref >= refs.len) return error.Corrupt;
            const sid = refs[r.scope_ref];
            var terms: words.Terms = undefined;
            terms.len = 0;
            var erased = r.erased;
            if (!erased) {
                try w.dec_buf.resize(w.gpa, r.raw_len);
                w.decodeText(lane, r, w.dec_buf.items) catch {
                    erased = true;
                };
                if (!erased and Crc.hash(r.text) != r.text_crc) erased = true;
                if (!erased) terms.fill(w.dec_buf.items);
            }
            if (erased) terms.fill("");
            _ = try w.indexMemory(lane, off, .{ .time = r.time, .sid = sid, .subject = r.subject, .link = r.link, .erased = erased }, &terms, null);
        },
        .scope => {
            var p: usize = 0;
            const ref = try ans.getVarint(r.body, &p);
            const refs = &w.lanes[lane].scope_refs;
            if (ref != refs.items.len) return error.Corrupt;
            const sid = try w.ensureScope(r.body[p..]);
            try refs.append(w.gpa, sid);
            if (lane == w.me) w.own_ref.at(sid).* = @intCast(ref + 1);
        },
        .model => {
            const l = &w.lanes[lane];
            if (l.nmodels >= max_models) return error.Corrupt;
            const m = try ans.parse(w.gpa, r.body);
            l.models[l.nmodels] = m;
            try l.model_offs.append(w.gpa, off);
            @atomicStore(usize, &l.nmodels, l.nmodels + 1, .release);
        },
        .forget_scope, .settle => {
            var p: usize = 0;
            var vc: [vc_len]u64 = undefined;
            try readVc(r.body, &p, &vc);
            const name = r.body[p..];
            if (r.kind == .forget_scope) {
                try w.applyForgetScope(name, &vc);
            } else {
                const sid = try w.ensureScope(name);
                _ = try w.mergeVc(w.sc_settle.at(sid), &vc);
            }
            w.dirty = true;
        },
        .forget_one => {
            var p: usize = 0;
            const target = try ans.getVarint(r.body, &p);
            if (w.ordOf(target)) |ord| try w.setForgotten(ord);
            w.dirty = true;
        },
        _ => {},
    }
}

/// Indexes lane `l` from its current end up to `limit`, by records.
fn replayLane(w: *Loom, l: usize, limit: u64) !void {
    const lane = &w.lanes[l];
    var pos = lane.end;
    const m = lane.map;
    while (pos < limit) {
        const r = parseRec(m[@intCast(pos)..@intCast(limit)]) orelse break;
        try w.ingest(l, pos, &r);
        pos += r.len;
        @atomicStore(u64, &lane.end, pos, .release);
    }
}

fn loadIndex(w: *Loom) !void {
    const from = w.loadSnapshot() catch null;
    if (from == null) try w.resetIndex();
    for (0..w.nlanes) |l| {
        if (from) |f| w.lanes[l].end = @max(data_start, f[l]);
        const len = try w.lanes[l].file.length(w.io);
        const limit = if (l == w.me or w.lanes[l].idle) len else @min(len, w.lanes[l].published());
        try w.replayLane(l, limit);
        if (l != w.me and w.lanes[l].idle) {
            w.lanes[l].file.unlock(w.io);
            w.lanes[l].idle = false;
        }
    }
    // Our lane ends where its last whole record ends. Bytes after it (a
    // write cut off by a crash) are cleared, so nothing reads them later.
    const own = &w.lanes[w.me];
    const e = own.end;
    var o = e;
    var z: [1 << 16]u8 = @splat(0);
    while (o < w.alloc) {
        const n: usize = @intCast(@min(z.len, w.alloc - o));
        if (std.mem.allEqual(u8, own.map[@intCast(o)..][0..n], 0)) break;
        try own.file.writePositionalAll(w.io, z[0..n], o);
        o += n;
    }
    if (o > e) try own.file.sync(w.io);
    w.end.store(e, .release);
    w.synced.store(e, .release);
    w.publish();
    w.next_model_at = if (own.nmodels == 0) 64 else 16384;
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
    if (body.len > max_text) return error.TooLarge;
}

fn ownBytes(w: *const Loom) []u8 {
    return @constCast(w.lanes[w.me].map);
}

fn publish(w: *Loom) void {
    const p: *u64 = @ptrCast(@alignCast(w.ownBytes()[pub_end_at..][0..8]));
    @atomicStore(u64, p, w.end.load(.acquire), .release);
}

/// Space for `len` bytes at the end of our lane. Writer only.
fn reserve(w: *Loom, len: u64) !u64 {
    const off = w.end.load(.acquire);
    if (off + len >= map_reserve) return error.LaneFull;
    if (off + len > w.alloc) {
        const step = std.math.clamp(w.alloc / 4, grow_min, grow_max);
        const size = @min(std.mem.alignForward(u64, @max(off + len, w.alloc + step), 4096), map_reserve);
        const f = w.lanes[w.me].file;
        try f.setLength(w.io, size);
        var z: [1 << 16]u8 = @splat(0);
        var o = w.alloc;
        while (o < size) : (o += z.len) try f.writePositionalAll(w.io, z[0..@intCast(@min(z.len, size - o))], o);
        try f.sync(w.io);
        w.alloc = size;
    }
    return off;
}

/// Appends a sealed record to our lane and publishes it. Writer only.
fn appendRecord(w: *Loom, rec: []const u8) !u64 {
    const off = try w.reserve(rec.len);
    @memcpy(w.ownBytes()[@intCast(off)..][0..rec.len], rec);
    const e = off + rec.len;
    w.end.store(e, .release);
    @atomicStore(u64, &w.lanes[w.me].end, e, .release);
    w.publish();
    _ = w.wseq.fetchAdd(1, .release);
    return off;
}

fn appendSimple(w: *Loom, kind: Kind, body: []const u8) !u64 {
    const b = &w.rec_buf;
    b.clearRetainingCapacity();
    try b.appendNTimes(w.gpa, 0, 9);
    b.items[8] = @backingInt(kind);
    try b.appendSlice(w.gpa, body);
    seal(b.items, b.items.len);
    return w.appendRecord(b.items);
}

/// Our lane's ref for a scope, writing the scope down first if new.
fn ownRef(w: *Loom, sid: u32) !u32 {
    const r = w.own_ref.get(sid);
    if (r != 0) return r - 1;
    const refs = &w.lanes[w.me].scope_refs;
    const ref: u32 = @intCast(refs.items.len);
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(w.gpa);
    try ans.putVarint(w.gpa, &body, ref);
    try body.appendSlice(w.gpa, w.scopeName(sid));
    _ = try w.appendSimple(.scope, body.items);
    try refs.append(w.gpa, sid);
    w.own_ref.at(sid).* = ref + 1;
    return ref;
}

/// Text coded with our lane's current model, prepared outside the lock.
const Coded = struct {
    stored: []const u8,
    model: u32,
    crc: u32,
    /// Models our lane had when it was coded.
    gen: usize,
};

threadlocal var tl_syms: [16384]u16 = undefined;
threadlocal var tl_terms: words.Terms = undefined;
threadlocal var tl_enc: [ans.bound(16384)]u8 = undefined;

fn codeText(w: *const Loom, text: []const u8, gpa: Allocator, heap: *std.ArrayList(u8), syms: *std.ArrayList(u16)) !Coded {
    const nm: u32 = @intCast(@atomicLoad(usize, &w.lanes[w.me].nmodels, .acquire));
    if (nm == 0 or text.len == 0) return .{ .stored = text, .model = 0, .crc = Crc.hash(text), .gen = nm };
    const m = w.lanes[w.me].models[nm - 1];
    var sbuf: []u16 = &tl_syms;
    var ebuf: []u8 = &tl_enc;
    if (text.len > tl_syms.len) {
        try syms.resize(gpa, text.len);
        sbuf = syms.items;
        try heap.resize(gpa, ans.bound(text.len));
        ebuf = heap.items;
    }
    const n = ans.encode(m, text, sbuf, ebuf);
    if (n >= text.len) return .{ .stored = text, .model = 0, .crc = Crc.hash(text), .gen = nm };
    return .{ .stored = ebuf[0..n], .model = nm, .crc = Crc.hash(ebuf[0..n]), .gen = nm };
}

pub fn remember(w: *Loom, scope: []const u8, body: []const u8, opts: RememberOptions) !u64 {
    const it: Item = .{ .scope = scope, .text = body, .subject = opts.subject, .time = opts.time };
    return w.rememberMany(&.{it});
}

/// Saves memories in order. Returns the first one's id.
pub fn rememberMany(w: *Loom, items: []const Item) !u64 {
    for (items) |it| try validate(it.scope, it.subject orelse "", it.text);
    try w.maybeRefresh();
    const gpa = w.gpa;
    var heap: std.ArrayList(u8) = .empty;
    defer heap.deinit(gpa);
    var syms: std.ArrayList(u16) = .empty;
    defer syms.deinit(gpa);
    const terms = &tl_terms;
    var first: u64 = 0;
    var tids: [words.Terms.cap]u32 = undefined;
    for (items, 0..) |it, k| {
        // Everything that only reads the index is done before the lock:
        // the words and the coding. Nothing is linked when written: which
        // fact a claim continues is the weave's business (Weave.zig).
        terms.fill(it.text);
        var coded = try w.codeText(it.text, gpa, &heap, &syms);
        {
            w.readers.enter();
            defer w.readers.leave();
            for (terms.items(), 0..) |word, i| tids[i] = w.termId(word.key);
        }
        w.wlock.lock(w.io);
        defer w.wlock.unlock(w.io);
        if (w.broken) return error.Broken;
        // A new model came meanwhile: code again with it.
        if (coded.gen != w.lanes[w.me].nmodels) coded = try w.codeText(it.text, gpa, &heap, &syms);
        const id = try w.appendMemory(it, terms, coded, tids[0..terms.len]);
        if (k == 0) first = id;
    }
    if (w.options.sync_writes and !w.options.flusher) try w.sync();
    if (w.flusher_waiting.load(.acquire)) w.io.futexWake(u32, &w.wseq.raw, 1);
    return first;
}

/// Writer only (lock held).
fn appendMemory(w: *Loom, it: Item, terms: *const words.Terms, coded: Coded, tids: []const u32) !u64 {
    const gpa = w.gpa;
    const sid = try w.ensureScope(it.scope);
    const ref = try w.ownRef(sid);
    const subject = it.subject orelse "";
    const time = it.time orelse w.nowMs();

    const b = &w.rec_buf;
    b.clearRetainingCapacity();
    try b.appendNTimes(gpa, 0, 9);
    b.items[8] = @backingInt(Kind.memory);
    try ans.putVarint(gpa, b, time);
    try ans.putVarint(gpa, b, ref);
    try ans.putVarint(gpa, b, subject.len);
    try ans.putVarint(gpa, b, coded.model);
    try ans.putVarint(gpa, b, it.text.len);
    try ans.putVarint(gpa, b, 0); // link: unused, the weave links
    var c4: [4]u8 = undefined;
    std.mem.writeInt(u32, &c4, coded.crc, .little);
    try b.appendSlice(gpa, &c4);
    try b.appendSlice(gpa, subject);
    const meta_end = b.items.len;
    try b.appendSlice(gpa, coded.stored);
    seal(b.items, meta_end);
    const off = try w.appendRecord(b.items);
    _ = try w.indexMemory(w.me, off, .{ .time = time, .sid = sid, .subject = subject, .link = 0, .erased = false }, terms, tids);

    w.written += 1;
    if (w.written & 255 == 0) w.reclaim();
    // A writer learns its words: counts feed the next model.
    if (w.written + 65536 >= w.next_model_at) try w.counter.add(gpa, it.text);
    if (w.written >= w.next_model_at) {
        if (w.lanes[w.me].nmodels < max_models) try w.newModel();
        w.next_model_at = if (w.next_model_at < 262144) w.next_model_at * 16 else w.next_model_at + (1 << 20);
    }
    return idOf(w.me, off);
}

fn newModel(w: *Loom) !void {
    const gpa = w.gpa;
    const m = try w.counter.model(gpa);
    errdefer m.deinit(gpa);
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    try ans.serialize(m, gpa, &body);
    const off = try w.appendSimple(.model, body.items);
    const l = &w.lanes[w.me];
    l.models[l.nmodels] = m;
    try l.model_offs.append(gpa, off);
    @atomicStore(usize, &l.nmodels, l.nmodels + 1, .release);
    w.counter.reset(gpa);
}

// --------------------------------------------------------------- claim span

fn absDiff(a: u16, b: u16) u16 {
    return if (a > b) a - b else b - a;
}

/// How much a word belongs to the claim a memory makes about a name. A
/// claim names a thing and gives it a value (the memory's one-off word):
/// the words between the two are the claim, a word or two past either end
/// may be, and the rest of the sentence is chatter around it.
fn spanWeight(word: words.Word, name: words.Word, value: ?words.Word) f32 {
    if (word.sent != name.sent) return 0;
    if (value) |v| if (v.sent == name.sent) {
        const lo = @min(name.pos, v.pos);
        const hi = @max(name.pos, v.pos);
        if (word.pos >= lo and word.pos <= hi) return 1;
        const d = if (word.pos < lo) lo - word.pos else word.pos - hi;
        return if (d <= 2) 0.6 else 0.15;
    };
    const d = absDiff(word.pos, name.pos);
    return if (d <= 3) 1 else if (d <= 6) 0.5 else 0.15;
}

/// The value a memory gives a name: the nearest word in the name's
/// sentence that no other memory has (`new_dfs`: counts before the memory
/// was written, where its value is the word never seen).
fn valueOf(w: *const Loom, terms: *const words.Terms, name: words.Word, new_dfs: ?[]const u32) ?words.Word {
    var best: ?words.Word = null;
    for (terms.items(), 0..) |word, i| {
        if (word.key == name.key or word.sent != name.sent or words.isCue(word.key)) continue;
        const one_off = if (new_dfs) |d| d[i] == 0 else w.dfOf(word.key) == 1;
        if (!one_off) continue;
        if (best == null or absDiff(word.pos, name.pos) < absDiff(best.?.pos, name.pos)) best = word;
    }
    return best;
}

// ------------------------------------------------------------- durability

/// Makes every write so far durable. Each caller flushes from the last
/// durable byte to the end it sees, so callers flush side by side (the
/// file system commits flushes that overlap together) and none returns
/// before everything written ahead of it is on disk.
pub fn sync(w: *Loom) !void {
    if (@atomicLoad(bool, &w.erase_pending, .acquire)) {
        w.wlock.lock(w.io);
        const lo = w.erase_lo;
        const hi = w.erase_hi;
        w.erase_lo = std.math.maxInt(u64);
        w.erase_hi = 0;
        @atomicStore(bool, &w.erase_pending, false, .release);
        w.wlock.unlock(w.io);
        if (hi > lo) try w.flushOwn(lo, hi);
    }
    const target = w.end.load(.acquire);
    const from = w.synced.load(.acquire);
    if (from >= target) return;
    try w.flushOwn(from, target);
    _ = w.syncs.fetchAdd(1, .monotonic);
    _ = w.synced.fetchMax(target, .release);
}

fn flushOwn(w: *Loom, from: u64, to: u64) !void {
    const lo = std.mem.alignBackward(u64, @min(from, to), page);
    const m = w.ownBytes();
    if (to > lo) try std.posix.msync(@alignCast(m[@intCast(lo)..@intCast(to)]), std.posix.MSF.SYNC);
    if (builtin.os.tag != .linux) try w.lanes[w.me].file.sync(w.io);
}

/// A promise for everything written so far.
pub fn promise(w: *const Loom) u64 {
    return w.end.load(.acquire);
}

pub fn isDurable(w: *const Loom, p: u64) bool {
    return w.synced.load(.acquire) >= p;
}

pub fn waitDurable(w: *Loom, p: u64) !void {
    if (w.flusher_thread == null) return w.sync();
    const d0 = w.dseq.load(.acquire);
    while (w.synced.load(.acquire) < p) {
        const d = w.dseq.load(.acquire);
        if (d != d0 and w.flusher_err.load(.acquire) != 0) return error.FlushFailed;
        if (w.synced.load(.acquire) >= p) break;
        w.io.futexWaitTimeout(u32, &w.dseq.raw, d, .{ .duration = .{ .raw = .fromMilliseconds(5), .clock = .awake } }) catch {};
    }
}

fn flusherLoop(w: *Loom) void {
    while (true) {
        const seen = w.wseq.load(.acquire);
        const e = w.end.load(.acquire);
        const sy = w.synced.load(.acquire);
        const pending = e > sy or @atomicLoad(bool, &w.erase_pending, .acquire);
        if (pending) {
            // While writes keep coming, flush whole pages only: the page
            // being written to is left alone (a page being flushed cannot
            // be written to), and finishes when writes pause or it fills.
            const whole = std.mem.alignBackward(u64, e, page);
            if (whole > sy and !@atomicLoad(bool, &w.erase_pending, .acquire)) {
                if (w.flushOwn(sy, whole)) |_| {
                    _ = w.syncs.fetchAdd(1, .monotonic);
                    _ = w.synced.fetchMax(whole, .release);
                    w.flusher_err.store(0, .release);
                } else |_| w.flusher_err.store(1, .release);
                _ = w.dseq.fetchAdd(1, .release);
                w.io.futexWake(u32, &w.dseq.raw, std.math.maxInt(u32));
                continue;
            }
            if (whole <= sy and e > sy and !w.flusher_stop.load(.acquire)) {
                w.io.futexWaitTimeout(u32, &w.wseq.raw, seen, .{ .duration = .{ .raw = .fromMicroseconds(1000), .clock = .awake } }) catch {};
                if (w.wseq.load(.acquire) != seen) continue;
            }
            if (w.sync()) |_| {
                w.flusher_err.store(0, .release);
            } else |_| {
                w.flusher_err.store(1, .release);
            }
            _ = w.dseq.fetchAdd(1, .release);
            w.io.futexWake(u32, &w.dseq.raw, std.math.maxInt(u32));
            if (w.flusher_err.load(.acquire) == 0) continue;
            if (w.flusher_stop.load(.acquire)) return;
            w.io.futexWaitTimeout(u32, &w.wseq.raw, w.wseq.load(.acquire), .{ .duration = .{ .raw = .fromMilliseconds(10), .clock = .awake } }) catch {};
            continue;
        }
        if (w.flusher_stop.load(.acquire)) return;
        w.flusher_waiting.store(true, .seq_cst);
        if (w.wseq.load(.seq_cst) == seen and !w.flusher_stop.load(.acquire))
            w.io.futexWaitTimeout(u32, &w.wseq.raw, seen, .{ .duration = .{ .raw = .fromMilliseconds(10), .clock = .awake } }) catch {};
        w.flusher_waiting.store(false, .release);
    }
}

pub fn syncCount(w: *const Loom) u64 {
    return w.syncs.load(.monotonic);
}

// ----------------------------------------------------------- other lanes

fn maybeRefresh(w: *Loom) !void {
    const now = w.monoMs();
    const last = w.last_refresh.load(.monotonic);
    if (now - last < 20) return;
    if (w.last_refresh.cmpxchgStrong(last, now, .monotonic, .monotonic) != null) return;
    w.wlock.lock(w.io);
    defer w.wlock.unlock(w.io);
    try w.refreshLocked();
}

/// Reads what other writers added since we last looked. Writer only.
pub fn refresh(w: *Loom) !void {
    w.wlock.lock(w.io);
    defer w.wlock.unlock(w.io);
    try w.refreshLocked();
}

fn refreshLocked(w: *Loom) !void {
    while (w.nlanes < max_lanes) {
        if (!try w.openLane(w.nlanes)) break;
    }
    for (0..w.nlanes) |l| {
        if (l == w.me) continue;
        const lane = &w.lanes[l];
        if (lane.idle) {
            try w.replayLane(l, try lane.file.length(w.io));
            lane.file.unlock(w.io);
            lane.idle = false;
            continue;
        }
        const p = lane.published();
        if (p > lane.end) try w.replayLane(l, @min(p, try lane.file.length(w.io)));
    }
}

// ------------------------------------------------------------------ forget

/// Zeroes a memory's text in our lane and marks it erased. Writer only.
fn eraseOwn(w: *Loom, off: u64) !void {
    const b = w.ownBytes();
    const e = @atomicLoad(u64, &w.lanes[w.me].end, .acquire);
    if (off >= e) return;
    const r = parseRec(b[@intCast(off)..@intCast(e)]) orelse return;
    if (r.kind != .memory or r.erased) return;
    const lo = off + r.text_at;
    const hi = off + r.len;
    @memset(b[@intCast(lo)..@intCast(hi)], 0);
    @atomicStore(u8, &b[@intCast(off + 8)], b[@intCast(off + 8)] | erased_bit, .release);
    w.erase_lo = @min(w.erase_lo, off);
    w.erase_hi = @max(w.erase_hi, hi);
    @atomicStore(bool, &w.erase_pending, true, .release);
}

/// Lane ends this writer knows of: every record before them is covered.
fn knownEnds(w: *const Loom, out: *std.ArrayList(u8)) !void {
    try ans.putVarint(w.gpa, out, w.nlanes);
    for (0..w.nlanes) |l| try ans.putVarint(w.gpa, out, if (l == w.me) w.end.load(.acquire) else w.lanes[l].end);
}

/// Forgets a scope and everything below it, in every lane. Returns how
/// many memories were forgotten.
pub fn forgetScope(w: *Loom, scope: []const u8) !usize {
    if (scope.len == 0 or scope.len > 1024) return error.InvalidScope;
    const n = blk: {
        w.wlock.lock(w.io);
        defer w.wlock.unlock(w.io);
        try w.refreshLocked();
        var n: usize = 0;
        if (w.scopeId(scope)) |sid| {
            var ids: std.ArrayList(u32) = .empty;
            defer ids.deinit(w.gpa);
            try w.subtree(w.gpa, sid, &ids);
            for (ids.items) |s| {
                var p = w.scopePosts(s);
                while (p.next()) |ord| if (w.alive(ord)) {
                    n += 1;
                };
            }
        }
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(w.gpa);
        try w.knownEnds(&body);
        try body.appendSlice(w.gpa, scope);
        const off = try w.appendSimple(.forget_scope, body.items);
        const r = parseRec(w.ownBytes()[@intCast(off)..@intCast(w.end.load(.acquire))]).?;
        try w.ingest(w.me, off, &r);
        break :blk n;
    };
    if (w.options.sync_writes and !w.options.flusher) try w.sync();
    return n;
}

/// Forgets one memory.
pub fn forget(w: *Loom, id: u64) !void {
    {
        w.wlock.lock(w.io);
        defer w.wlock.unlock(w.io);
        _ = w.ordOf(id) orelse return error.NotFound;
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(w.gpa);
        try ans.putVarint(w.gpa, &body, id);
        const off = try w.appendSimple(.forget_one, body.items);
        const r = parseRec(w.ownBytes()[@intCast(off)..@intCast(w.end.load(.acquire))]).?;
        try w.ingest(w.me, off, &r);
    }
    if (w.options.sync_writes and !w.options.flusher) try w.sync();
}

/// Adds a summary of a scope and settles everything before it: older
/// memories stay in `deep` recall, normal answers use the summary.
pub fn settle(w: *Loom, scope: []const u8, summary: []const u8) !u64 {
    const id = try w.remember(scope, summary, .{ .subject = "summary" });
    {
        w.wlock.lock(w.io);
        defer w.wlock.unlock(w.io);
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(w.gpa);
        try ans.putVarint(w.gpa, &body, w.nlanes);
        for (0..w.nlanes) |l| try ans.putVarint(w.gpa, &body, if (l == w.me) offOf(id) else w.lanes[l].end);
        try body.appendSlice(w.gpa, scope);
        const off = try w.appendSimple(.settle, body.items);
        const r = parseRec(w.ownBytes()[@intCast(off)..@intCast(w.end.load(.acquire))]).?;
        try w.ingest(w.me, off, &r);
    }
    if (w.options.sync_writes and !w.options.flusher) try w.sync();
    return id;
}

// ------------------------------------------------------------------- reads

pub fn get(w: *Loom, gpa: Allocator, id: u64) !?Memory {
    try w.maybeRefresh();
    w.readers.enter();
    defer w.readers.leave();
    const ord = w.ordOf(id) orelse return null;
    return w.load(gpa, ord);
}

/// The `n` memories most recently written to one scope, newest first.
pub fn recent(w: *Loom, gpa: Allocator, scope: []const u8, n: usize) ![]Memory {
    return w.recentFiltered(gpa, scope, n, false);
}

fn recentFiltered(w: *Loom, gpa: Allocator, scope: []const u8, n: usize, skip_buried: bool) ![]Memory {
    try w.maybeRefresh();
    w.readers.enter();
    defer w.readers.leave();
    var out: std.ArrayList(Memory) = .empty;
    errdefer {
        for (out.items) |m| m.deinit(gpa);
        out.deinit(gpa);
    }
    const sid = w.scopeId(scope) orelse return out.toOwnedSlice(gpa);
    try out.ensureTotalCapacity(gpa, n);
    var p = w.scopePosts(sid);
    while (out.items.len < n) {
        const ord = p.next() orelse break;
        if (skip_buried and w.isBuried(ord)) continue;
        if (try w.load(gpa, ord)) |m| out.appendAssumeCapacity(m);
    }
    return out.toOwnedSlice(gpa);
}

/// The current memory for a subject in a scope.
pub fn current(w: *Loom, gpa: Allocator, scope: []const u8, subject: []const u8) !?Memory {
    try w.maybeRefresh();
    w.readers.enter();
    defer w.readers.leave();
    const sid = w.scopeId(scope) orelse return null;
    const c = w.subjects.get(subjectKey(sid, subject)) orelse return null;
    const head = @atomicLoad(u32, &w.cells.at(@intCast(c)).head, .acquire);
    return w.load(gpa, w.newestOf(head));
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
    /// Its ordinal in this store.
    ord: u32 = 0,
};

pub fn freeHits(gpa: Allocator, hs: []const Hit) void {
    for (hs) |h| h.memory.deinit(gpa);
    gpa.free(hs);
}

const max_groups = 8;
const max_related = 4;
const min_related_sim = 0.45;
const sim_floor = 0.15;

/// Two words that start with the same five letters or more: forms of one
/// word the stemmer does not join. Packed words are base 37, first letter
/// first, so the first five letters are the number over 37^7.
fn sameStem(a: u64, b: u64) bool {
    if (a & words.hashed_bit != 0 or b & words.hashed_bit != 0) return false;
    const p7: u64 = comptime std.math.pow(u64, 37, 7);
    const pa = a / p7;
    return pa % 37 != 0 and pa == b / p7;
}
const max_decode = 256;

/// A question word, or a word related in meaning to one. Words of one
/// group count once, by their best match.
const QTerm = struct { key: u64, tid: u32, group: u8, sim: f32, mi: ?u32 };

const Search = struct {
    w: *const Loom,
    gpa: Allocator,
    q: Query,
    set: ScopeSet,
    meaning: ?*const Meaning,
    wv: ?*const Weave.Woven,
    qt: [max_groups * (1 + max_related)]QTerm = undefined,
    nq: usize = 0,
    gw: [max_groups]f32 = @splat(0),
    gmi: [max_groups]?u32 = @splat(null),
    ng: usize = 0,
    wsum: f32 = 0,
    now: u64,
    terms: words.Terms = undefined,
    heap: std.ArrayList(u8) = .empty,
    /// Meaning index -> similarity to each group, for this question.
    memo_key: [1024]u32 = @splat(std.math.maxInt(u32)),
    memo_sim: [1024][max_groups]f32 = undefined,
    /// Per question word: a name (rare enough to tell facts apart).
    qrare: [max_groups * (1 + max_related)]bool = undefined,
    /// Per slot: how well its wording matches each question group.
    /// Direct-mapped by slot id; no allocation per question.
    sm_key: [64]u32 = @splat(std.math.maxInt(u32)),
    sm_val: [64][max_groups]f32 = undefined,
    /// Per group: its question word itself, and whether it is a name.
    gexact: [max_groups]?u64 = @splat(null),
    gexact_rare: [max_groups]bool = @splat(false),
    rare_ready: bool = false,

    /// Which question words are names, worked out when the first claim
    /// is scored (most questions over chat never score one).
    fn prepRare(s: *Search) void {
        if (s.rare_ready) return;
        s.rare_ready = true;
        const lim = rareLimit(s.w.memCount());
        for (s.qt[0..s.nq], 0..) |t, qi| {
            s.qrare[qi] = s.w.dfOf(t.key) <= lim;
            if (t.sim == 1 and s.gexact[t.group] == null) {
                s.gexact[t.group] = t.key;
                s.gexact_rare[t.group] = s.qrare[qi];
            }
        }
    }

    fn deinit(s: *Search) void {
        s.heap.deinit(s.gpa);
    }

    /// How well a slot's pooled wording matches each question group: a
    /// question word in it (weighted by how much of the slot says it), or
    /// with meaning on, the closest word in meaning.
    fn slotMatch(s: *Search, sid: u32) ![max_groups]f32 {
        const at: usize = @intCast(sid & 63);
        if (s.sm_key[at] == sid) return s.sm_val[at];
        const sl = &s.wv.?.slots[sid];
        var m: [max_groups]f32 = @splat(0);
        const top = sl.share[0];
        for (s.qt[0..s.nq]) |q| {
            for (sl.wording(), 0..) |k, j| {
                const wt = 0.6 + 0.4 * sl.share[j] / top;
                if (k == q.key) {
                    m[q.group] = @max(m[q.group], q.sim * wt);
                } else if (q.sim == 1 and sameStem(k, q.key)) {
                    // Another form of the word ("allowed", "allowance").
                    m[q.group] = @max(m[q.group], 0.8 * wt);
                }
            }
        }
        if (s.meaning) |mn| {
            var best: [max_groups]f32 = @splat(0);
            for (sl.wording(), 0..) |k, j| {
                const mi = mn.index(k) orelse continue;
                const wt = 0.5 + 0.5 * sl.share[j] / top;
                const sv = s.sims(mi);
                for (0..s.ng) |g| best[g] = @max(best[g], sv[g] * wt);
            }
            for (0..s.ng) |g| if (s.gmi[g] != null) {
                m[g] = @max(m[g], std.math.clamp((best[g] - sim_floor) / (1 - sim_floor), 0, 1));
            };
        }
        s.sm_key[at] = sid;
        s.sm_val[at] = m;
        return m;
    }

    fn recency(s: *const Search, t: u64) f32 {
        const age: f32 = @floatFromInt(s.now -| t);
        const hl: f32 = @floatFromInt(@max(s.w.options.half_life_ms, 1));
        return 0.85 + 0.15 * @exp2(-age / hl);
    }

    fn sims(s: *Search, mi: u32) *const [max_groups]f32 {
        const slot: usize = @intCast((@as(u64, mi) *% 0x9E3779B97F4A7C15) >> 54);
        if (s.memo_key[slot] != mi) {
            s.memo_key[slot] = mi;
            const m = s.meaning.?;
            for (0..s.ng) |g| s.memo_sim[slot][g] = if (s.gmi[g]) |gi| m.similarity(gi, mi) else 0;
        }
        return &s.memo_sim[slot];
    }

    /// Score of a whole memory: question bits it holds, by words or by
    /// meaning, times the share of the question covered (squared), times
    /// recency.
    fn score(s: *Search, ord: u32) !?Scored {
        // A claim is matched against its slot's wording: every way its
        // attribute was ever phrased, by any name, and none of the chatter
        // around this one memory.
        var slot_id: ?u32 = null;
        if (s.wv) |wv| if (s.w.factOf(wv, ord)) |f| {
            if (wv.slots[f.slot].len > 0) slot_id = f.slot;
        };
        return s.scoreText(ord, slot_id);
    }

    /// `score`, with the memory's slot (if it is a claim) known.
    fn scoreText(s: *Search, ord: u32, slot_id: ?u32) !?Scored {
        const t = (try s.w.textOf(ord, &s.heap, s.gpa)) orelse return null;
        if (t.time < s.q.since) return null;
        s.terms.fill(t.text);
        var m: [max_groups]f32 = @splat(0);
        var mask: u8 = 0;
        var lexpos: [max_groups]?usize = @splat(null);
        if (slot_id != null) s.prepRare();
        for (s.qt[0..s.nq], 0..) |q, qi| {
            // In a claim, only names (rare words) and its slot's wording
            // count (below); the chatter around it does not.
            if (slot_id) |sid| if (q.sim < 1 or (!s.qrare[qi] and !s.wv.?.slots[sid].holds(q.key))) continue;
            if (s.terms.find(q.key)) |i| {
                if (q.sim > m[q.group]) m[q.group] = q.sim;
                if (q.sim == 1) {
                    mask |= @as(u8, 1) << @intCast(q.group);
                    lexpos[q.group] = i;
                }
            }
        }
        if (slot_id) |sid| {
            const sm = try s.slotMatch(sid);
            for (0..s.ng) |g| if (m[g] < 1) {
                m[g] = @max(m[g], sm[g]);
            };
        }
        if (slot_id == null) if (s.meaning) |mn| {
            // The claim about the rarest name the question shares with
            // this memory: the words between the name and its value.
            var name: ?words.Word = null;
            for (lexpos[0..s.ng]) |lp| if (lp) |i| {
                name = s.terms.words[i];
                break;
            };
            const value = if (name) |nm| s.w.valueOf(&s.terms, nm, null) else null;
            var best: [max_groups]f32 = @splat(0);
            for (s.terms.items()) |word| {
                const mi = mn.index(word.key) orelse continue;
                var lexical = false;
                for (lexpos[0..s.ng]) |lp| if (lp) |i| {
                    if (s.terms.words[i].key == word.key) lexical = true;
                };
                if (lexical) continue;
                const wt: f32 = if (name) |nm| spanWeight(word, nm, value) else 0.5;
                if (wt == 0) continue;
                const sv = s.sims(mi);
                for (0..s.ng) |g| best[g] = @max(best[g], sv[g] * wt);
            }
            for (0..s.ng) |g| if (s.gmi[g] != null and m[g] < 1) {
                m[g] = @max(m[g], std.math.clamp((best[g] - sim_floor) / (1 - sim_floor), 0, 1));
            };
        };
        var base: f32 = 0;
        for (0..s.ng) |g| base += s.gw[g] * m[g];
        if (base <= 0) return null;
        const cov = base / s.wsum;
        const subj: f32 = if (t.subject) 1.1 else 1.0;
        return .{ .score = base * cov * cov * s.recency(t.time) * subj, .mask = mask };
    }

    /// Score from the postings alone, when every question word was
    /// findable and meaning is off: the text has nothing more to add, so
    /// only the record's time is read.
    fn scoreFromPosts(s: *Search, ord: u32, s1: f32, mask: u8) ?Scored {
        const r = s.w.recOf(s.w.tl_loc.get(ord)) orelse return null;
        if (r.erased or r.time < s.q.since or s1 <= 0) return null;
        const cov = s1 / s.wsum;
        const subj: f32 = if (r.subject.len > 0) 1.1 else 1.0;
        return .{ .score = s1 * cov * cov * s.recency(r.time) * subj, .mask = mask };
    }

    /// Score of a claim, without reading its text: in a claim only its
    /// names and its slot's wording count, and the postings already say
    /// which question words it holds; only the record's time is read.
    fn scoreClaim(s: *Search, ord: u32, sid: u32, cmask: u8) !?Scored {
        const r = s.w.recOf(s.w.tl_loc.get(ord)) orelse return null;
        if (r.erased or r.time < s.q.since) return null;
        s.prepRare();
        var m = try s.slotMatch(sid);
        var mask: u8 = 0;
        const sl = &s.wv.?.slots[sid];
        for (0..s.ng) |g| if (cmask & (@as(u8, 1) << @intCast(g)) != 0) {
            const k = s.gexact[g] orelse continue;
            if (s.gexact_rare[g] or sl.holds(k)) {
                m[g] = 1;
                mask |= @as(u8, 1) << @intCast(g);
            }
        };
        var base: f32 = 0;
        for (0..s.ng) |g| base += s.gw[g] * m[g];
        if (base <= 0) return null;
        const cov = base / s.wsum;
        const subj: f32 = if (r.subject.len > 0) 1.1 else 1.0;
        return .{ .score = base * cov * cov * s.recency(r.time) * subj, .mask = mask };
    }

    fn bound(s: *const Search, base: f32) f32 {
        const b = @min(base, s.wsum);
        const cov = b / s.wsum;
        return b * cov * cov * 1.1;
    }
};

const Cand = struct { ord: u32, s1: f32, mask: u8 = 0 };
const Scored = struct { score: f32, mask: u8 };
const FactHit = struct { key: u64, ord: u32, score: f32, mask: u8, fact: ?Weave.Fact = null };

/// Facts ranked by how well any of their versions matches `about`,
/// answered with each fact's newest version.
pub fn recall(w: *Loom, gpa: Allocator, q: Query) ![]Hit {
    try w.maybeRefresh();
    w.readers.enter();
    defer w.readers.leave();
    const limit = @max(q.limit, 1);
    var hits: std.ArrayList(Hit) = .empty;
    errdefer {
        for (hits.items) |x| x.memory.deinit(gpa);
        hits.deinit(gpa);
    }
    if (w.memCount() == 0) return hits.toOwnedSlice(gpa);
    const set = w.scopeSet(q.scope) orelse return hits.toOwnedSlice(gpa);
    const wv = w.weave();
    const s = try gpa.create(Search);
    defer gpa.destroy(s);
    s.* = .{ .w = w, .gpa = gpa, .q = q, .set = set, .meaning = if (q.expand) w.options.meaning else null, .wv = wv, .now = w.nowMs() };
    defer s.deinit();
    s.terms.fill(q.about);
    if (s.terms.len == 0) {
        try w.newestInto(gpa, set, q, limit, &hits);
        return hits.toOwnedSlice(gpa);
    }

    // Question words by the bits they carry. A word the store never saw
    // can only match by meaning.
    const n = w.memCount();
    const Gw = struct { key: u64, tid: u32, wt: f32, mi: ?u32 };
    var cand_g: [words.Terms.cap]Gw = undefined;
    var ncg: usize = 0;
    for (s.terms.items()) |word| {
        const tid = w.termId(word.key);
        const d = w.dfOf(word.key);
        const mi: ?u32 = if (s.meaning) |m| m.index(word.key) else null;
        if (d == 0 and mi == null) continue;
        const bits = if (d == 0) std.math.log2(@as(f32, @floatFromInt(n + 1))) else w.idf(d);
        cand_g[ncg] = .{ .key = word.key, .tid = tid, .wt = @min(bits, 20), .mi = mi };
        ncg += 1;
    }
    if (ncg == 0) return hits.toOwnedSlice(gpa);
    std.mem.sortUnstable(Gw, cand_g[0..ncg], {}, struct {
        fn gt(_: void, a: Gw, b: Gw) bool {
            return a.wt > b.wt;
        }
    }.gt);
    s.ng = @min(ncg, max_groups);
    for (cand_g[0..s.ng], 0..) |g, i| {
        s.gw[i] = g.wt;
        s.gmi[i] = g.mi;
        s.wsum += g.wt;
        s.qt[s.nq] = .{ .key = g.key, .tid = g.tid, .group = @intCast(i), .sim = 1, .mi = g.mi };
        s.nq += 1;
    }
    if (s.meaning) |m| {
        for (0..s.ng) |g| {
            var rel: [max_related]Meaning.Related = undefined;
            const k = m.related(cand_g[g].key, min_related_sim, &rel);
            outer: for (rel[0..k]) |r| {
                for (s.qt[0..s.nq]) |t| if (t.key == r.key) continue :outer;
                s.qt[s.nq] = .{ .key = r.key, .tid = w.termId(r.key), .group = @intCast(g), .sim = r.sim, .mi = null };
                s.nq += 1;
            }
        }
    }

    // Candidates: the postings of the question's findable words, newest
    // first; a word too common to keep postings only confirms.
    var pairs: std.ArrayList(u64) = .empty;
    defer pairs.deinit(gpa);
    var findable_w: f32 = 0;
    for (s.qt[0..s.nq], 0..) |t, qi| {
        var p = w.postsOf(t.key);
        if (p.blk == 0 and p.p0 == 0) continue;
        if (t.sim == 1) findable_w += s.gw[t.group];
        const budget: usize = if (t.sim == 1) 8192 else 1024;
        var steps: usize = 0;
        while (p.next()) |ord| : (steps += 1) {
            if (steps >= budget) break;
            try pairs.append(gpa, (@as(u64, ord) << 8) | qi);
        }
    }
    var cands: std.ArrayList(Cand) = .empty;
    defer cands.deinit(gpa);
    if (pairs.items.len > 0) {
        std.mem.sortUnstable(u64, pairs.items, {}, std.sort.desc(u64));
        var i: usize = 0;
        while (i < pairs.items.len) {
            const ord: u32 = @intCast(pairs.items[i] >> 8);
            var gbest: [max_groups]f32 = @splat(0);
            var mask: u8 = 0;
            while (i < pairs.items.len and (pairs.items[i] >> 8) == ord) : (i += 1) {
                const t = s.qt[@intCast(pairs.items[i] & 0xff)];
                gbest[t.group] = @max(gbest[t.group], t.sim);
                if (t.sim == 1) mask |= @as(u8, 1) << @intCast(t.group);
            }
            if (!w.alive(ord) or !set.has(w, w.sidOf(ord))) continue;
            var s1: f32 = 0;
            for (0..s.ng) |g| s1 += gbest[g] * s.gw[g];
            try cands.append(gpa, .{ .ord = ord, .s1 = s1, .mask = mask });
        }
    } else {
        // Nothing findable: the newest memories of the scope, read whole.
        try w.newestOrds(gpa, set, 64, &cands);
    }
    std.mem.sortUnstable(Cand, cands.items, {}, struct {
        fn gt(_: void, a: Cand, b: Cand) bool {
            return a.s1 > b.s1 or (a.s1 == b.s1 and a.ord > b.ord);
        }
    }.gt);

    // Read candidates best first; stop when no later one can enter the
    // top `limit` facts.
    const extra = if (s.meaning != null) s.wsum else s.wsum - findable_w;
    const posts_only = s.meaning == null and extra <= 0.001 and pairs.items.len > 0;
    var fhits: std.ArrayList(FactHit) = .empty;
    defer fhits.deinit(gpa);
    var decoded: usize = 0;
    for (cands.items) |c| {
        if (decoded >= max_decode) break;
        if (fhits.items.len >= limit) {
            const kth = kthScore(fhits.items, limit);
            if (s.bound(c.s1 + extra) < kth) break;
        }
        // One look into the weave per candidate: its slot, key and newest
        // version all come from it.
        const fact: ?Weave.Fact = if (wv) |x| w.factOf(x, c.ord) else null;
        var claim_slot: ?u32 = null;
        if (fact) |f| if (wv.?.slots[f.slot].len > 0) {
            claim_slot = f.slot;
        };
        const sc = (if (posts_only)
            s.scoreFromPosts(c.ord, c.s1, c.mask)
        else if (claim_slot) |sid|
            try s.scoreClaim(c.ord, sid, c.mask)
        else
            try s.scoreText(c.ord, null)) orelse continue;
        if (!posts_only and claim_slot == null) decoded += 1;
        const key: u64 = if (q.deep) c.ord else w.factKeyOf(c.ord, fact);
        var found = false;
        for (fhits.items) |*f| if (f.key == key) {
            found = true;
            if (sc.score > f.score) {
                f.score = sc.score;
                f.ord = c.ord;
                f.mask = sc.mask;
                f.fact = fact;
            }
        };
        if (!found) try fhits.append(gpa, .{ .key = key, .ord = c.ord, .score = sc.score, .mask = sc.mask, .fact = fact });
    }
    std.mem.sortUnstable(FactHit, fhits.items, {}, struct {
        fn gt(_: void, a: FactHit, b: FactHit) bool {
            return a.score > b.score or (a.score == b.score and a.ord > b.ord);
        }
    }.gt);

    // Answer with each fact's newest version.
    var pre: std.ArrayList(Pre) = .empty;
    defer pre.deinit(gpa);
    for (fhits.items) |f| {
        var ord = f.ord;
        if (!q.deep) {
            const h = w.newestFrom(f.ord, f.fact);
            // A newer version said in another scope is another place's
            // fact by the same name, not this one's answer.
            if (h != f.ord and w.alive(h) and set.has(w, w.sidOf(h))) ord = h;
            // Two keys can reach one fact (a subject cell and a grid cell).
            var dup = false;
            for (pre.items) |x| if (x.ord == ord) {
                dup = true;
            };
            if (dup) continue;
            if (w.settled(ord)) continue;
        }
        if (q.since > 0 and ord != f.ord) {
            const r = w.recOf(w.tl_loc.get(ord)) orelse continue;
            if (r.time < q.since) continue;
        }
        const r = w.recOf(w.tl_loc.get(ord)) orelse continue;
        try pre.append(gpa, .{ .ord = ord, .score = f.score, .mask = f.mask, .time = r.time, .buried = q.deep and w.isBuried(ord) });
        if (pre.items.len >= limit * 2 + 4) break;
    }
    if (!q.deep) sedimentHits(pre.items);
    for (pre.items) |x| {
        if (hits.items.len == limit) break;
        if (!q.deep and x.buried) continue;
        const m = (try w.load(gpa, x.ord)) orelse continue;
        errdefer m.deinit(gpa);
        try hits.append(gpa, .{ .memory = m, .score = x.score, .buried = x.buried, .matched = x.mask, .ord = x.ord });
    }
    return hits.toOwnedSlice(gpa);
}

const Pre = struct { ord: u32, score: f32, mask: u8, time: u64, buried: bool };

fn kthScore(fs: []const FactHit, k: usize) f32 {
    var top: [64]f32 = @splat(-1);
    const kk = @min(k, top.len);
    for (fs) |f| {
        if (f.score <= top[kk - 1]) continue;
        var i = kk - 1;
        while (i > 0 and top[i - 1] < f.score) : (i -= 1) top[i] = top[i - 1];
        top[i] = f.score;
    }
    return top[kk - 1];
}

/// Versions the store could not link when written: among hits that match
/// the same question words (two or more) about equally well, the newest
/// comes first and the older ones are buried.
fn sedimentHits(hits: []Pre) void {
    var changed = true;
    var rounds: usize = 0;
    while (changed and rounds < hits.len) : (rounds += 1) {
        changed = false;
        for (0..hits.len) |i| for (i + 1..hits.len) |j| {
            if (sameFact(&hits[i], &hits[j]) and hits[j].time > hits[i].time) {
                std.mem.swap(Pre, &hits[i], &hits[j]);
                changed = true;
            }
        };
    }
    for (0..hits.len) |j| for (0..j) |i| {
        if (sameFact(&hits[i], &hits[j]) and hits[i].time > hits[j].time) {
            hits[j].buried = true;
            break;
        }
    };
}

fn sameFact(a: *const Pre, b: *const Pre) bool {
    return a.mask == b.mask and @popCount(a.mask) >= 2 and b.score >= a.score * 0.9 and a.score >= b.score * 0.9;
}

/// The newest live ordinals in a scope set.
fn newestOrds(w: *const Loom, gpa: Allocator, set: ScopeSet, max: usize, out: *std.ArrayList(Cand)) !void {
    if (set.all) {
        var o = w.memCount();
        while (o > 0 and out.items.len < max) {
            o -= 1;
            if (w.alive(@intCast(o))) try out.append(gpa, .{ .ord = @intCast(o), .s1 = 0 });
        }
        return;
    }
    var ids: std.ArrayList(u32) = .empty;
    defer ids.deinit(gpa);
    try w.subtree(gpa, set.root, &ids);
    var mg: Merge = .{};
    defer mg.deinit(gpa);
    for (ids.items) |sid| try mg.add(gpa, w.scopePosts(sid));
    while (out.items.len < max) {
        const o = mg.next() orelse break;
        if (w.alive(o)) try out.append(gpa, .{ .ord = o, .s1 = 0 });
    }
}

fn newestInto(w: *const Loom, gpa: Allocator, set: ScopeSet, q: Query, limit: usize, hits: *std.ArrayList(Hit)) !void {
    var c: std.ArrayList(Cand) = .empty;
    defer c.deinit(gpa);
    try w.newestOrds(gpa, set, limit * 4 + 16, &c);
    for (c.items) |x| {
        if (hits.items.len == limit) break;
        const buried = w.isBuried(x.ord);
        if (buried and !q.deep) continue;
        const m = (try w.load(gpa, x.ord)) orelse continue;
        if (m.time < q.since) {
            m.deinit(gpa);
            continue;
        }
        errdefer m.deinit(gpa);
        try hits.append(gpa, .{ .memory = m, .score = @floatFromInt(x.ord), .buried = buried, .ord = x.ord });
    }
}

// ------------------------------------------------------------------ schema

/// An attribute the store learned: how its claims are worded (the words
/// most of them share, stems, most shared first), and how much it holds.
pub const SlotInfo = struct {
    wording: []u8,
    claims: u32,
    frames: u32,
    /// Names with this attribute.
    cells: u32,
};

pub fn freeSchema(gpa: Allocator, ss: []const SlotInfo) void {
    for (ss) |x| gpa.free(x.wording);
    gpa.free(ss);
}

fn wordingText(gpa: Allocator, keys: []const u64) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (keys, 0..) |k, i| {
        if (i > 0) try out.append(gpa, ' ');
        var b: [words.max_packed]u8 = undefined;
        try out.appendSlice(gpa, if (k & words.hashed_bit != 0) "#" else words.unpack(k, &b));
    }
    return out.toOwnedSlice(gpa);
}

/// The slots the weave has learned, biggest first.
pub fn schema(w: *Loom, gpa: Allocator) ![]SlotInfo {
    try w.maybeRefresh();
    w.readers.enter();
    defer w.readers.leave();
    const wv = w.weave() orelse return gpa.alloc(SlotInfo, 0);
    const cells = try gpa.alloc(u32, wv.slots.len);
    defer gpa.free(cells);
    @memset(cells, 0);
    for (wv.cells) |c| cells[c.slot] += 1;
    var out: std.ArrayList(SlotInfo) = .empty;
    errdefer freeSchema(gpa, out.items);
    for (wv.slots, 0..) |sl, i| {
        const t = try wordingText(gpa, sl.wording());
        errdefer gpa.free(t);
        try out.append(gpa, .{ .wording = t, .claims = sl.claims, .frames = sl.frames, .cells = cells[i] });
    }
    std.mem.sortUnstable(SlotInfo, out.items, {}, struct {
        fn gt(_: void, a: SlotInfo, b: SlotInfo) bool {
            return a.claims > b.claims;
        }
    }.gt);
    return out.toOwnedSlice(gpa);
}

/// One attribute of a name: the slot's wording, how many versions the
/// cell holds, and the newest.
pub const FactRow = struct {
    wording: []u8,
    versions: u32,
    memory: Memory,
    ord: u32 = 0,
};

pub fn freeFacts(gpa: Allocator, rows: []const FactRow) void {
    for (rows) |r| {
        gpa.free(r.wording);
        r.memory.deinit(gpa);
    }
    gpa.free(rows);
}

/// Everything the store knows about `name` (its first word), one row per
/// attribute, each in its newest version: a name's row of the grid.
pub fn facts(w: *Loom, gpa: Allocator, name: []const u8, scope: []const u8) ![]FactRow {
    try w.maybeRefresh();
    w.readers.enter();
    defer w.readers.leave();
    var out: std.ArrayList(FactRow) = .empty;
    errdefer freeFacts(gpa, out.items);
    const set = w.scopeSet(scope) orelse return out.toOwnedSlice(gpa);
    const wv = w.weave() orelse return out.toOwnedSlice(gpa);
    var t: words.Terms = .{};
    t.fill(name);
    if (t.len == 0) return out.toOwnedSlice(gpa);
    try w.rowInto(gpa, wv, set, t.words[0].key, &.{}, true, &out);
    return out.toOwnedSlice(gpa);
}

/// A name's row of the grid, newest version of each cell. Readers entered.
fn rowInto(w: *Loom, gpa: Allocator, wv: *const Weave.Woven, set: ScopeSet, name: u64, skip: []const u64, with_wording: bool, out: *std.ArrayList(FactRow)) !void {
    for (wv.cellsOf(name)) |ci| {
        const cell = wv.cells[ci];
        const ord = w.newestOf(cell.head);
        if (!w.alive(ord) or !set.has(w, w.sidOf(ord))) continue;
        // Memories the caller already has are not loaded again.
        if (std.mem.indexOfScalar(u64, skip, w.tl_loc.get(ord)) != null) continue;
        const m = (try w.load(gpa, ord)) orelse continue;
        errdefer m.deinit(gpa);
        const wording = if (with_wording) try wordingText(gpa, wv.slots[cell.slot].wording()) else try gpa.alloc(u8, 0);
        errdefer gpa.free(wording);
        try out.append(gpa, .{ .wording = wording, .versions = cell.members, .memory = m, .ord = ord });
    }
}

/// The rows of the names a text mentions (at most `max` names, rarest
/// first), as memories, leaving out the memories `skip` names by id.
fn namedRows(w: *Loom, gpa: Allocator, text: []const u8, scope: []const u8, max: usize, skip: []const u64) ![]FactRow {
    w.readers.enter();
    defer w.readers.leave();
    var out: std.ArrayList(FactRow) = .empty;
    errdefer freeFacts(gpa, out.items);
    const set = w.scopeSet(scope) orelse return out.toOwnedSlice(gpa);
    const wv = w.weave() orelse return out.toOwnedSlice(gpa);
    var t: words.Terms = .{};
    t.fill(text);
    var names: [8]u64 = undefined;
    var nn: usize = 0;
    for (t.items()) |word| {
        if (wv.cellsOf(word.key).len == 0 or nn == names.len) continue;
        names[nn] = word.key;
        nn += 1;
    }
    std.mem.sortUnstable(u64, names[0..nn], w, struct {
        fn lt(ww: *Loom, a: u64, b: u64) bool {
            return ww.dfOf(a) < ww.dfOf(b);
        }
    }.lt);
    for (names[0..@min(nn, max)]) |k| try w.rowInto(gpa, wv, set, k, skip, false, &out);
    return out.toOwnedSlice(gpa);
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
fn isSentenceEnd(c: u8) bool {
    return c == '.' or c == '!' or c == '?' or c == ';' or c == '\n';
}

/// Which of the question's words (the first 16) a text holds.
fn questionMask(q: *const words.Terms, text: []const u8) u16 {
    const S = struct {
        q: *const words.Terms,
        m: u16 = 0,
        pub fn word(st: *@This(), x: words.Word) void {
            if (st.q.find(x.key)) |i| if (i < 16) {
                st.m |= @as(u16, 1) << @intCast(i);
            };
        }
    };
    var st: S = .{ .q = q };
    words.forEach(text, &st);
    return st.m;
}

pub fn brief(w: *Loom, gpa: Allocator, situation: []const u8, scope: []const u8, budget: usize) !Brief {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    const hits = try w.recall(gpa, .{ .about = situation, .scope = scope, .limit = 16 });
    defer freeHits(gpa, hits);
    const exact = blk: {
        w.readers.enter();
        defer w.readers.leave();
        break :blk scope.len > 0 and w.scopeId(scope) != null;
    };
    const rec_ms = if (exact) try w.recentFiltered(gpa, scope, 6, true) else try gpa.alloc(Memory, 0);
    defer freeMemories(gpa, rec_ms);
    // Everything known about the names the situation mentions: their rows
    // of the grid, each attribute in its newest version only.
    var have: [16]u64 = undefined;
    for (hits, 0..) |x, i| have[i] = x.memory.id;
    const rows = try w.namedRows(gpa, situation, scope, 2, have[0..hits.len]);
    defer freeFacts(gpa, rows);
    var row_ms: [64]Memory = undefined;
    var row_ords: [64]u32 = undefined;
    var nrow: usize = 0;
    // A row the weave could not tie to its newer version (two wordings it
    // never joined) is still an old version when a newer hit says
    // exactly the same question words: leave it out, as recall buries
    // such versions.
    var qt: words.Terms = .{};
    qt.fill(situation);
    var hmask: [16]?u16 = @splat(null);
    rows: for (rows) |r| {
        if (nrow == row_ms.len) break;
        const rm = questionMask(&qt, r.memory.text);
        if (@popCount(rm) >= 2) for (hits, 0..) |x, hi| {
            if (x.memory.time <= r.memory.time) continue;
            if (hmask[hi] == null) hmask[hi] = questionMask(&qt, x.memory.text);
            if (hmask[hi].? == rm) continue :rows;
        };
        row_ms[nrow] = r.memory;
        row_ords[nrow] = r.ord;
        nrow += 1;
    }

    var used: usize = 0;
    var items: usize = 0;
    var seen: [64]u64 = undefined;
    var nseen: usize = 0;
    var rel: [16]Memory = undefined;
    var rel_ords: [16]u32 = undefined;
    var nrel: usize = 0;
    for (hits) |x| {
        rel[nrel] = x.memory;
        rel_ords[nrel] = x.ord;
        nrel += 1;
    }
    const now = w.nowMs();
    const Part = struct { title: []const u8, mems: []const Memory, ords: ?[]const u32 };
    // A claim shows what it states (its names and values, and the words
    // right around them); other memories, and the recent conversation,
    // are shown whole.
    const sections = [_]Part{
        .{ .title = "Relevant memory", .mems = rel[0..nrel], .ords = rel_ords[0..nrel] },
        .{ .title = "Also known about them", .mems = row_ms[0..nrow], .ords = row_ords[0..nrow] },
        .{ .title = "Recent in this scope", .mems = rec_ms, .ords = null },
    };
    w.readers.enter();
    defer w.readers.leave();
    const wv = w.weave();
    for (sections) |sec| {
        var header_done = false;
        for (sec.mems, 0..) |m, mi| {
            if (std.mem.indexOfScalar(u64, seen[0..nseen], m.id) != null) continue;
            var body = m.text;
            if (sec.ords) |os| if (wv) |x| if (w.factOf(x, os[mi])) |f| {
                if (f.len > 0 and @as(usize, f.at) + f.len <= m.text.len) body = m.text[f.at..][0..f.len];
            };
            const snippet = body[0..@min(body.len, 600)];
            const cost = (snippet.len + m.scope.len + 40 + 3) / 4;
            if (used + cost > budget) continue;
            if (!header_done) {
                try out.print(gpa, "## {s}\n", .{sec.title});
                header_done = true;
            }
            const age_s = (now -| m.time) / 1000;
            const v, const u = if (age_s < 3600) .{ age_s / 60, "m" } else if (age_s < 86400) .{ age_s / 3600, "h" } else .{ age_s / 86400, "d" };
            try out.print(gpa, "- [{d}{s} ago {s}] {s}{s}\n", .{ v, u, m.scope, snippet, if (snippet.len < body.len) "..." else "" });
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

// -------------------------------------------------------------------- info

pub const Info = struct {
    memories: u64,
    scopes: usize,
    subjects: usize,
    /// Facts with more than one version.
    strata: usize,
    /// Versions linked by the shape of their claim rather than a subject.
    auto_merges: u64,
    lanes: usize,
    file_bytes: u64,
    /// Bytes of the index arrays and tables.
    index_bytes: usize,
    /// Word models of all lanes.
    model_bytes: usize,
    /// Claims, and what the weave learned from them: frames (wordings),
    /// slots (attributes), cells (a name's attribute) and claims whose
    /// newest version is another claim.
    claims: usize = 0,
    frames: usize = 0,
    slots: usize = 0,
    cells: usize = 0,
    linked: usize = 0,
    joined_by_subject: usize = 0,
    joined_by_precedence: usize = 0,
    joined_one_off: usize = 0,
};

/// Learns the schema now if the claims have grown since it was last
/// learned (recall and briefs do this on their own when they need to).
pub fn learn(w: *Loom) void {
    w.readers.enter();
    defer w.readers.leave();
    _ = w.weave();
}

pub fn info(w: *Loom) Info {
    w.readers.enter();
    defer w.readers.leave();
    var bytes: u64 = 0;
    for (w.lanes[0..w.nlanes]) |l| bytes += l.end;
    var idx: usize = w.lex.bytes() + w.fact_of.bytes() + w.subjects.bytes() + w.sc_map.bytes();
    for (w.indexVecs()) |v| idx += v.len.* * v.size;
    var mb: usize = 0;
    for (w.lanes[0..w.nlanes]) |*l| {
        idx += l.ords.count() * 4;
        for (l.models[0..l.nmodels]) |m| mb += m.ramBytes();
    }
    var strata: usize = 0;
    for (w.cells.items()[1..]) |c| {
        if (c.nver > 1) strata += 1;
    }
    // Info reports the weave there is; it does not build one.
    const wv = w.woven.load(.acquire);
    if (wv) |x| idx += x.bytes();
    return .{
        .memories = w.memCount(),
        .scopes = w.sc_parent.count() - 1,
        .subjects = w.subjects.len,
        .strata = strata,
        .auto_merges = if (wv) |x| x.linked else 0,
        .claims = if (wv) |x| x.claims else 0,
        .frames = if (wv) |x| x.frames else 0,
        .slots = if (wv) |x| x.slots.len else 0,
        .cells = if (wv) |x| x.cells.len else 0,
        .linked = if (wv) |x| x.linked else 0,
        .joined_by_subject = if (wv) |x| x.joined_by_subject else 0,
        .joined_by_precedence = if (wv) |x| x.joined_by_precedence else 0,
        .joined_one_off = if (wv) |x| x.joined_one_off else 0,
        .lanes = w.nlanes,
        .file_bytes = bytes,
        .index_bytes = idx,
        .model_bytes = mb,
    };
}

/// Calls `f(ctx, scope ++ subject ++ text, time)` for every live memory:
/// the cost of answering without an index.
pub fn scanAll(w: *Loom, ctx: anytype, comptime f: anytype) !void {
    w.readers.enter();
    defer w.readers.leave();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(w.gpa);
    for (0..w.nlanes) |lane| {
        const b = w.laneBytes(lane);
        var pos: usize = data_start;
        while (pos < b.len) {
            const r = parseRec(b[pos..]) orelse break;
            defer pos += r.len;
            if (r.kind != .memory or r.erased) continue;
            const refs = w.lanes[lane].scope_refs.items;
            if (r.scope_ref >= refs.len) continue;
            const ord = w.ordOf(idOf(lane, pos)) orelse continue;
            if (!w.alive(ord)) continue;
            const scope = w.scopeName(refs[r.scope_ref]);
            buf.clearRetainingCapacity();
            try buf.appendSlice(w.gpa, scope);
            try buf.appendSlice(w.gpa, r.subject);
            const at = buf.items.len;
            try buf.resize(w.gpa, at + r.raw_len);
            w.decodeText(lane, &r, buf.items[at..]) catch continue;
            if (Crc.hash(r.text) != r.text_crc) continue;
            f(ctx, buf.items, r.time);
        }
    }
}

// ---------------------------------------------------------------- snapshot
//
// Written at close: every index array, page-aligned, so opening maps them
// straight back (copy-on-write) instead of rebuilding, then reads only the
// records added after. A snapshot covers every lane up to the ends in its
// header, which were flushed before it was written.

const snap_name = "index.lm";
const snap_magic = "LOOMIDX1";
const snap_version: u32 = 1;

const SnapHead = extern struct {
    magic: [8]u8,
    version: u32,
    nlanes: u32,
    total_terms: u64,
    merges: u64,
    ends: [max_lanes]u64,
    nsections: u32,
    crc: u32,
};

const SnapSection = extern struct { off: u64, bytes: u64, count: u64 };
const max_sections = 256;
/// Header and section table.
const head_bytes = 4 * page;

const SnapWriter = struct {
    w: *Loom,
    file: Io.File,
    pos: u64,
    secs: [max_sections]SnapSection = undefined,
    n: usize = 0,

    fn add(sw: *SnapWriter, bytes: []const u8, count: u64) !void {
        if (sw.n == max_sections) return error.TooManySections;
        try sw.file.writePositionalAll(sw.w.io, bytes, sw.pos);
        sw.secs[sw.n] = .{ .off = sw.pos, .bytes = bytes.len, .count = count };
        sw.n += 1;
        sw.pos = std.mem.alignForward(u64, sw.pos + bytes.len, page);
    }
    fn addVec(sw: *SnapWriter, v: AnyVec) !void {
        const n = v.len.*;
        try sw.add(v.mem.*[0 .. n * v.size], n);
    }
    fn addSlice(sw: *SnapWriter, comptime T: type, s: []const T) !void {
        try sw.add(std.mem.sliceAsBytes(s), s.len);
    }
    fn addMap(sw: *SnapWriter, m: *const Map) !void {
        if (m.table) |t| try sw.add(t.mem[0 .. t.cap * 16], t.cap) else try sw.add(&.{}, 0);
        try sw.addSlice(u64, &.{m.len});
    }
};

fn writeSnapshot(w: *Loom) !void {
    // Everything the snapshot covers must be on disk first.
    try w.flushOwn(data_start, w.end.load(.acquire));
    for (0..w.nlanes) |l| if (l != w.me) try w.lanes[l].file.sync(w.io);
    // Each writer writes its own temporary file: writers that close at the
    // same time must not write into one file.
    var tb: [32]u8 = undefined;
    const snap_tmp = std.fmt.bufPrint(&tb, "index-{d:0>3}.tmp", .{w.me}) catch unreachable;
    const f = try w.dir.createFile(w.io, snap_tmp, .{ .read = true, .truncate = true });
    var ok = false;
    defer {
        f.close(w.io);
        if (!ok) w.dir.deleteFile(w.io, snap_tmp) catch {};
    }
    var sw: SnapWriter = .{ .w = w, .file = f, .pos = head_bytes };
    for (w.indexVecs()) |v| try sw.addVec(v);
    try sw.addMap(&w.lex);
    try sw.addMap(&w.fact_of);
    try sw.addMap(&w.subjects);
    try sw.addMap(&w.sc_map);
    for (w.lanes[0..w.nlanes]) |*l| {
        try sw.addVec(l.ords.any());
        try sw.addSlice(u32, l.scope_refs.items);
        try sw.addSlice(u64, l.model_offs.items);
    }
    // Pad to a whole page so the last section maps.
    try f.setLength(w.io, sw.pos);
    var head: SnapHead = std.mem.zeroes(SnapHead);
    @memcpy(&head.magic, snap_magic);
    head.version = snap_version;
    head.nlanes = @intCast(w.nlanes);
    head.total_terms = w.total_terms;
    head.merges = w.merges;
    for (0..w.nlanes) |l| head.ends[l] = if (l == w.me) w.end.load(.acquire) else w.lanes[l].end;
    head.nsections = @intCast(sw.n);
    var hb: [head_bytes]u8 = @splat(0);
    @memcpy(hb[0..@sizeOf(SnapHead)], std.mem.asBytes(&head));
    @memcpy(hb[@sizeOf(SnapHead)..][0 .. sw.n * @sizeOf(SnapSection)], std.mem.sliceAsBytes(sw.secs[0..sw.n]));
    const crc = Crc.hash(hb[0..@offsetOf(SnapHead, "crc")]) ^ Crc.hash(hb[@sizeOf(SnapHead)..][0 .. sw.n * @sizeOf(SnapSection)]);
    std.mem.writeInt(u32, hb[@offsetOf(SnapHead, "crc")..][0..4], crc, .little);
    try f.writePositionalAll(w.io, &hb, 0);
    try f.sync(w.io);
    try w.dir.rename(snap_tmp, w.dir, snap_name, w.io);
    ok = true;
    w.dirty = false;
}

/// Maps the snapshot back. Returns each lane's covered end, or null when
/// there is none.
fn loadSnapshot(w: *Loom) !?[max_lanes]u64 {
    const f = w.dir.openFile(w.io, snap_name, .{}) catch |e| switch (e) {
        error.FileNotFound => return null,
        else => return e,
    };
    defer f.close(w.io);
    const flen = try f.length(w.io);
    var hb: [head_bytes]u8 = undefined;
    if (flen < head_bytes or try f.readPositionalAll(w.io, &hb, 0) != head_bytes) return error.Corrupt;
    const head = std.mem.bytesToValue(SnapHead, hb[0..@sizeOf(SnapHead)]);
    if (!std.mem.eql(u8, &head.magic, snap_magic) or head.version != snap_version) return error.Corrupt;
    if (head.nsections > max_sections or head.nlanes > w.nlanes) return error.Corrupt;
    const ns = head.nsections;
    if (@sizeOf(SnapHead) + ns * @sizeOf(SnapSection) > head_bytes) return error.Corrupt;
    const crc = Crc.hash(hb[0..@offsetOf(SnapHead, "crc")]) ^ Crc.hash(hb[@sizeOf(SnapHead)..][0 .. ns * @sizeOf(SnapSection)]);
    if (crc != head.crc) return error.Corrupt;
    var secs: [max_sections]SnapSection = undefined;
    @memcpy(std.mem.sliceAsBytes(secs[0..ns]), hb[@sizeOf(SnapHead)..][0 .. ns * @sizeOf(SnapSection)]);
    for (secs[0..ns]) |s| if (s.off % page != 0 or s.off + std.mem.alignForward(u64, s.bytes, page) > flen) return error.Corrupt;
    for (0..head.nlanes) |l| if (head.ends[l] > try w.lanes[l].file.length(w.io)) return error.Corrupt;
    const nvec = w.indexVecs().len;
    if (ns != nvec + 4 * 2 + head.nlanes * 3) return error.Corrupt;

    try w.resetIndex();
    errdefer w.resetIndex() catch {};
    var k: usize = 0;
    for (w.indexVecs()) |v| {
        try mapSection(f, secs[k], v);
        k += 1;
    }
    for ([_]*Map{ &w.lex, &w.fact_of, &w.subjects, &w.sc_map }) |m| {
        try readMap(w, f, secs[k], secs[k + 1], m);
        k += 2;
    }
    // Refs into our lane are ours alone: the snapshot's writer had its own.
    @memset(w.own_ref.items(), 0);
    for (0..head.nlanes) |l| {
        const lane = &w.lanes[l];
        try mapSection(f, secs[k], lane.ords.any());
        try readList(w, u32, f, secs[k + 1], &lane.scope_refs);
        var offs: std.ArrayList(u64) = .empty;
        defer offs.deinit(w.gpa);
        try readList(w, u64, f, secs[k + 2], &offs);
        k += 3;
        lane.end = head.ends[l];
        for (offs.items) |o| {
            if (o < data_start or o >= head.ends[l]) return error.Corrupt;
            const r = parseRec(lane.map[@intCast(o)..@intCast(head.ends[l])]) orelse return error.Corrupt;
            if (r.kind != .model or lane.nmodels >= max_models) return error.Corrupt;
            lane.models[lane.nmodels] = try ans.parse(w.gpa, r.body);
            lane.nmodels += 1;
            try lane.model_offs.append(w.gpa, o);
        }
        for (lane.scope_refs.items) |sid| if (sid >= w.own_ref.count()) return error.Corrupt;
        for (lane.ords.items()) |o| if (o >= w.tl_loc.count()) return error.Corrupt;
        if (l == w.me) {
            for (lane.scope_refs.items, 0..) |sid, ref| {
                if (sid >= w.own_ref.count()) return error.Corrupt;
                w.own_ref.at(sid).* = @intCast(ref + 1);
            }
        }
    }
    w.total_terms = head.total_terms;
    w.merges = head.merges;
    w.spill_now = true;
    var ends: [max_lanes]u64 = @splat(data_start);
    for (0..head.nlanes) |l| ends[l] = head.ends[l];
    return ends;
}

/// Moves the index into the scratch file (see `Backing`): when a fresh
/// index grows past `spill_bytes`, or before the first write to an index
/// mapped from the snapshot (whose written pages would otherwise become
/// anonymous copies). Readers see the same bytes throughout. A part that
/// cannot move stays where it is; that costs memory, never correctness.
fn adopt(w: *Loom) void {
    w.adopted = true;
    const b = &w.back;
    if (b.fd < 0) return;
    b.shared = true;
    const nidx = w.indexVecs().len;
    for (0..nidx + w.nlanes) |i| {
        const v = if (i < nidx) w.indexVecs()[i] else w.lanes[i - nidx].ords.any();
        if (v.mem.*.len == 0) continue;
        _ = b.move(v.mem.*.ptr, v.len.* * v.size);
    }
    for ([_]*Map{ &w.lex, &w.fact_of, &w.subjects, &w.sc_map }) |m| {
        const t = m.table orelse continue;
        if (b.move(t.mem.ptr, t.mem.len)) continue;
        // Mapped from the snapshot: copy it into a table of ours.
        const t2 = m.newTable(w.gpa, t.cap) catch continue;
        @memcpy(t2.mem[0 .. t.cap * 16], t.mem[0 .. t.cap * 16]);
        m.retired.append(w.gpa, t) catch {
            m.freeTable(w.gpa, t2);
            continue;
        };
        @atomicStore(?*Map.Table, &m.table, t2, .seq_cst);
    }
}

/// A fresh index moves into the scratch file past this size.
const spill_bytes: usize = 32 << 20;

/// Index bytes held now, arrays and tables.
fn heldBytes(w: *Loom) usize {
    var n: usize = 0;
    for (w.indexVecs()) |v| n += v.len.* * v.size;
    for ([_]*const Map{ &w.lex, &w.fact_of, &w.subjects, &w.sc_map }) |m| n += m.bytes();
    return n;
}

fn mapSection(f: Io.File, s: SnapSection, v: AnyVec) !void {
    if (s.count * v.size != s.bytes or s.bytes > v.mem.*.len) return error.Corrupt;
    if (s.bytes > 0) {
        const len = std.mem.alignForward(usize, @intCast(s.bytes), page);
        _ = try std.posix.mmap(v.mem.*.ptr, len, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .FIXED = true }, f.handle, s.off);
    }
    @atomicStore(usize, v.len, @intCast(s.count), .release);
}

fn readList(w: *Loom, comptime T: type, f: Io.File, s: SnapSection, out: *std.ArrayList(T)) !void {
    if (s.count * @sizeOf(T) != s.bytes) return error.Corrupt;
    try out.resize(w.gpa, @intCast(s.count));
    if (s.bytes > 0 and try f.readPositionalAll(w.io, std.mem.sliceAsBytes(out.items), s.off) != s.bytes) return error.Corrupt;
}

/// Maps a table back from the snapshot (copy-on-write).
fn readMap(w: *Loom, f: Io.File, ts: SnapSection, ls: SnapSection, m: *Map) !void {
    if (ls.count != 1) return error.Corrupt;
    var lb: [8]u8 = undefined;
    if (try f.readPositionalAll(w.io, &lb, ls.off) != 8) return error.Corrupt;
    try m.clear(w.gpa);
    if (ts.count == 0) return;
    if (!std.math.isPowerOfTwo(ts.count) or ts.bytes != ts.count * 16) return error.Corrupt;
    const t = try w.gpa.create(Map.Table);
    errdefer w.gpa.destroy(t);
    const len = std.mem.alignForward(usize, @intCast(ts.bytes), page);
    t.* = .{
        .shift = @intCast(64 - @as(u7, std.math.log2_int(usize, @intCast(ts.count)))),
        .cap = @intCast(ts.count),
        .mem = try std.posix.mmap(null, len, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE }, f.handle, ts.off),
    };
    m.len = @intCast(std.mem.readInt(u64, &lb, .little));
    @atomicStore(?*Map.Table, &m.table, t, .seq_cst);
}

// ------------------------------------------------------------------- tests

const testing = std.testing;

fn tmpStore(tmp: *testing.TmpDir, meaning: ?*const Meaning) !*Loom {
    return Loom.open(testing.allocator, testing.io, tmp.dir, "s", .{ .sync_writes = false, .meaning = meaning });
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
    try testing.expectEqualStrings("chat/1", r[0].scope);
    const c = (try w.current(testing.allocator, "mem", "plan")).?;
    defer c.deinit(testing.allocator);
    try testing.expectEqualStrings("plan B", c.text);
}

test "text is coded with the lane's model and reads back exactly" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const w = try tmpStore(&tmp, null);
    defer w.close();
    var ids: [3000]u64 = undefined;
    for (&ids, 0..) |*id, i| {
        var b: [128]u8 = undefined;
        id.* = try w.remember("chat/2", try std.fmt.bufPrint(&b, "the user wants to deploy the service on friday number {d}", .{i}), .{});
    }
    try testing.expect(w.lanes[w.me].nmodels >= 2);
    for ([_]usize{ 0, 63, 64, 1500, 2999 }) |i| {
        const m = (try w.get(testing.allocator, ids[i])).?;
        defer m.deinit(testing.allocator);
        var b: [128]u8 = undefined;
        try testing.expectEqualStrings(try std.fmt.bufPrint(&b, "the user wants to deploy the service on friday number {d}", .{i}), m.text);
    }
    // About 58 bytes of text each: stored in well under that, header included.
    try testing.expect(w.info().file_bytes < 3000 * 40);
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
    const hits = try w.recall(testing.allocator, .{ .about = "what does billing run on, postgres?", .limit = 5 });
    defer freeHits(testing.allocator, hits);
    try testing.expect(hits.len >= 1);
    try testing.expectEqualStrings("payments service moved to cockroach", hits[0].memory.text);
    for (hits) |x| try testing.expect(std.mem.indexOf(u8, x.memory.text, "fifteen") == null);
    const deep = try w.recall(testing.allocator, .{ .about = "billing postgres cockroach payments", .limit = 5, .deep = true });
    defer freeHits(testing.allocator, deep);
    try testing.expectEqual(@as(usize, 2), deep.len);
}

test "what tagged facts teach links the untagged versions of other names" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const w = try tmpStore(&tmp, null);
    defer w.close();
    const names = [_][]const u8{ "atlas", "borealis", "cygnus", "draco", "eridanus", "fornax", "gemini", "hydra" };
    var b: [128]u8 = undefined;
    var sb: [64]u8 = undefined;
    for (0..3000) |i| _ = try w.remember("p/chat", try std.fmt.bufPrint(&b, "the team talked about the plan {d} today", .{i % 97}), .{});
    for (names, 0..) |nm, i| {
        const subj: ?[]const u8 = if (i < 4) try std.fmt.bufPrint(&sb, "{s}-region", .{nm}) else null;
        _ = try w.remember("p", try std.fmt.bufPrint(&b, "{s} is deployed in the zq{d}old region", .{ nm, i }), .{ .subject = subj });
        _ = try w.remember("p", try std.fmt.bufPrint(&b, "{s} keeps its records in zr{d}db", .{ nm, i }), .{});
        for (0..40) |j| _ = try w.remember("p/chat", try std.fmt.bufPrint(&b, "lunch was fine {d}", .{j}), .{});
    }
    for (names, 0..) |nm, i| {
        const subj: ?[]const u8 = if (i < 4) try std.fmt.bufPrint(&sb, "{s}-region", .{nm}) else null;
        _ = try w.remember("p", try std.fmt.bufPrint(&b, "{s} moved over to the zq{d}new hosting", .{ nm, i }), .{ .subject = subj });
    }
    w.learn();
    const inf = w.info();
    try testing.expect(inf.joined_by_subject >= 1);
    try testing.expect(inf.linked >= names.len);
    for (names, 0..) |nm, i| {
        const hits = try w.recall(testing.allocator, .{ .about = try std.fmt.bufPrint(&b, "which region is {s} deployed in", .{nm}), .limit = 5 });
        defer freeHits(testing.allocator, hits);
        try testing.expect(hits.len >= 1);
        var want: [16]u8 = undefined;
        try testing.expect(std.mem.indexOf(u8, hits[0].memory.text, try std.fmt.bufPrint(&want, "zq{d}new", .{i})) != null);
        var old: [16]u8 = undefined;
        const o = try std.fmt.bufPrint(&old, "zq{d}old", .{i});
        for (hits) |x| try testing.expect(std.mem.indexOf(u8, x.memory.text, o) == null);
    }
}

test "a newer claim by the same name in another project does not answer for this one" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const w = try tmpStore(&tmp, null);
    defer w.close();
    const names = [_][]const u8{ "atlas", "borealis", "cygnus", "draco", "eridanus", "fornax" };
    var b: [128]u8 = undefined;
    for (0..3000) |i| _ = try w.remember("a/chat", try std.fmt.bufPrint(&b, "the team talked about the plan {d} today", .{i % 97}), .{});
    for (names, 0..) |nm, i| {
        _ = try w.remember("a", try std.fmt.bufPrint(&b, "decision: the backup schedule for {s} is zk{d}aa.", .{ nm, i }), .{});
        for (0..30) |j| _ = try w.remember("a/chat", try std.fmt.bufPrint(&b, "lunch was fine {d}", .{j}), .{});
    }
    // Project b happens to have its own atlas, stated later.
    _ = try w.remember("b", "decision: the backup schedule for atlas is zkbbother.", .{});
    w.learn();
    const hits = try w.recall(testing.allocator, .{ .about = "what is the backup schedule for atlas?", .scope = "a", .limit = 5 });
    defer freeHits(testing.allocator, hits);
    try testing.expect(hits.len >= 1);
    try testing.expect(std.mem.indexOf(u8, hits[0].memory.text, "zk0aa") != null);
    for (hits) |x| try testing.expect(std.mem.indexOf(u8, x.memory.text, "zkbbother") == null);
    const all = try w.recall(testing.allocator, .{ .about = "what is the backup schedule for atlas?", .limit = 5 });
    defer freeHits(testing.allocator, all);
    try testing.expect(all.len >= 1);
}

test "a name's row of the grid, and the schema the store learned" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const w = try tmpStore(&tmp, null);
    defer w.close();
    const names = [_][]const u8{ "atlas", "borealis", "cygnus", "draco", "eridanus", "fornax" };
    var b: [128]u8 = undefined;
    var sb: [64]u8 = undefined;
    for (0..2000) |i| _ = try w.remember("p/chat", try std.fmt.bufPrint(&b, "the team talked about the plan {d} today", .{i % 89}), .{});
    for (names, 0..) |nm, i| {
        _ = try w.remember("p", try std.fmt.bufPrint(&b, "{s} is deployed in the zq{d}old region", .{ nm, i }), .{ .subject = try std.fmt.bufPrint(&sb, "{s}-region", .{nm}) });
        _ = try w.remember("p", try std.fmt.bufPrint(&b, "{s} keeps its records in zr{d}db", .{ nm, i }), .{});
        for (0..30) |j| _ = try w.remember("p/chat", try std.fmt.bufPrint(&b, "lunch was fine {d}", .{j}), .{});
    }
    for (names, 0..) |nm, i| {
        _ = try w.remember("p", try std.fmt.bufPrint(&b, "{s} moved over to the zq{d}new hosting", .{ nm, i }), .{ .subject = try std.fmt.bufPrint(&sb, "{s}-region", .{nm}) });
    }
    const rows = try w.facts(testing.allocator, "Atlas", "");
    defer freeFacts(testing.allocator, rows);
    try testing.expectEqual(@as(usize, 2), rows.len);
    var saw_new = false;
    var saw_db = false;
    for (rows) |r| {
        if (std.mem.indexOf(u8, r.memory.text, "zq0new") != null) {
            saw_new = true;
            try testing.expectEqual(@as(u32, 2), r.versions);
        }
        if (std.mem.indexOf(u8, r.memory.text, "zr0db") != null) saw_db = true;
        try testing.expect(std.mem.indexOf(u8, r.memory.text, "zq0old") == null);
    }
    try testing.expect(saw_new and saw_db);
    const slots = try w.schema(testing.allocator);
    defer freeSchema(testing.allocator, slots);
    try testing.expect(slots.len >= 2);
    var region = false;
    for (slots) |sl| {
        if (std.mem.indexOf(u8, sl.wording, "region") != null) {
            region = true;
            try testing.expectEqual(@as(u32, names.len), sl.cells);
        }
    }
    try testing.expect(region);
    // A brief about a name carries its whole row, newest versions only.
    const b2 = try w.brief(testing.allocator, "anything new about cygnus?", "p", 2000);
    defer b2.deinit(testing.allocator);
    try testing.expect(std.mem.indexOf(u8, b2.text, "zq2new") != null);
    try testing.expect(std.mem.indexOf(u8, b2.text, "zr2db") != null);
    try testing.expect(std.mem.indexOf(u8, b2.text, "zq2old") == null);
}

test "a one-off change continues the claim it shares the most words with; another attribute is left alone" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const w = try tmpStore(&tmp, null);
    defer w.close();
    for (0..5000) |i| {
        var b: [80]u8 = undefined;
        _ = try w.remember("p", try std.fmt.bufPrint(&b, "the team talked about the plan {d} today", .{i}), .{});
    }
    _ = try w.remember("p", "zorblat cache ttl is ninety seconds", .{});
    _ = try w.remember("p", "zorblat owner is mallory", .{});
    _ = try w.remember("p", "update: zorblat cache ttl raised to hundredtwenty", .{});
    const hits = try w.recall(testing.allocator, .{ .about = "zorblat cache ttl", .limit = 5 });
    defer freeHits(testing.allocator, hits);
    try testing.expect(std.mem.indexOf(u8, hits[0].memory.text, "hundredtwenty") != null);
    for (hits) |x| try testing.expect(std.mem.indexOf(u8, x.memory.text, "ninety") == null);
    const own = try w.recall(testing.allocator, .{ .about = "who owns zorblat", .limit = 5 });
    defer freeHits(testing.allocator, own);
    var saw_owner = false;
    for (own) |x| {
        if (std.mem.indexOf(u8, x.memory.text, "mallory") != null) saw_owner = true;
    }
    try testing.expect(saw_owner);
}

test "forget and forgetScope erase text, and survive reopening" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        const w = try tmpStore(&tmp, null);
        defer w.close();
        const a = try w.remember("chat/9", "secret token alpha", .{});
        _ = try w.remember("chat/9", "secret token beta", .{});
        _ = try w.remember("chat/10", "keep this one", .{});
        try w.forget(a);
        try testing.expectEqual(@as(usize, 1), try w.forgetScope("chat/9"));
        const r = try w.recent(testing.allocator, "chat/9", 10);
        defer freeMemories(testing.allocator, r);
        try testing.expectEqual(@as(usize, 0), r.len);
        try w.sync();
    }
    const w = try tmpStore(&tmp, null);
    defer w.close();
    const r = try w.recent(testing.allocator, "chat/9", 10);
    defer freeMemories(testing.allocator, r);
    try testing.expectEqual(@as(usize, 0), r.len);
    const k = try w.recent(testing.allocator, "chat/10", 10);
    defer freeMemories(testing.allocator, k);
    try testing.expectEqual(@as(usize, 1), k.len);
    // The text is gone from the file, not just hidden.
    const Scan = struct {
        found: bool = false,
        fn each(c: *@This(), body: []const u8, _: u64) void {
            if (std.mem.indexOf(u8, body, "secret") != null) c.found = true;
        }
    };
    var sc: Scan = .{};
    try w.scanAll(&sc, Scan.each);
    try testing.expect(!sc.found);
    const lane = w.lanes[w.me].map[0..@intCast(w.end.load(.acquire))];
    try testing.expect(std.mem.indexOf(u8, lane, "secret") == null);
}

test "reopening maps the snapshot and reads only what came after" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        const w = try tmpStore(&tmp, null);
        defer w.close();
        for (0..3000) |i| {
            var b: [80]u8 = undefined;
            _ = try w.remember("proj/1/chat", try std.fmt.bufPrint(&b, "message {d} about the quarterly roadmap", .{i}), .{});
        }
        _ = try w.remember("proj/1", "the vendor for kestrelpay is stripe", .{ .subject = "vendor" });
    }
    {
        const w = try tmpStore(&tmp, null);
        defer w.close();
        try testing.expectEqual(@as(u64, 3001), w.info().memories);
        _ = try w.remember("proj/1", "the vendor for kestrelpay is adyen now", .{ .subject = "vendor" });
    }
    const w = try tmpStore(&tmp, null);
    defer w.close();
    const hits = try w.recall(testing.allocator, .{ .about = "kestrelpay vendor", .scope = "proj/1" });
    defer freeHits(testing.allocator, hits);
    try testing.expectEqualStrings("the vendor for kestrelpay is adyen now", hits[0].memory.text);
    const r = try w.recent(testing.allocator, "proj/1/chat", 2);
    defer freeMemories(testing.allocator, r);
    try testing.expectEqualStrings("message 2999 about the quarterly roadmap", r[0].text);
}

test "a torn write at the end of the lane is cut off" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        const w = try tmpStore(&tmp, null);
        defer w.close();
        _ = try w.remember("a", "first", .{});
        _ = try w.remember("a", "second", .{});
        try w.sync();
        w.dirty = false;
    }
    {
        var sub = try tmp.dir.openDir(testing.io, "s", .{});
        defer sub.close(testing.io);
        var f = try sub.openFile(testing.io, "lane-000.lm", .{ .mode = .read_write });
        defer f.close(testing.io);
        const garbage = [_]u8{ 200, 0, 0, 0, 1, 2, 3, 4, 1, 9, 9 };
        try f.writePositionalAll(testing.io, &garbage, try f.length(testing.io));
    }
    const w = try tmpStore(&tmp, null);
    defer w.close();
    _ = try w.remember("a", "third", .{});
    const r = try w.recent(testing.allocator, "a", 10);
    defer freeMemories(testing.allocator, r);
    try testing.expectEqual(@as(usize, 3), r.len);
    try testing.expectEqualStrings("third", r[0].text);
}

test "two writers share a store through their own lanes" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = try tmpStore(&tmp, null);
    defer a.close();
    const b = try tmpStore(&tmp, null);
    defer b.close();
    try testing.expect(a.me != b.me);
    _ = try a.remember("team", "alpha wrote the release notes", .{});
    _ = try b.remember("team", "beta reviewed the release notes", .{});
    try a.sync();
    try b.sync();
    try a.refresh();
    try b.refresh();
    const ra = try a.recent(testing.allocator, "team", 10);
    defer freeMemories(testing.allocator, ra);
    const rb = try b.recent(testing.allocator, "team", 10);
    defer freeMemories(testing.allocator, rb);
    try testing.expectEqual(@as(usize, 2), ra.len);
    try testing.expectEqual(@as(usize, 2), rb.len);
    _ = try b.forgetScope("team");
    try a.refresh();
    const ra2 = try a.recent(testing.allocator, "team", 10);
    defer freeMemories(testing.allocator, ra2);
    try testing.expectEqual(@as(usize, 0), ra2.len);
}

test "promised writes become durable" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const w = try Loom.open(testing.allocator, testing.io, tmp.dir, "s", .{ .sync_writes = false, .flusher = true });
    defer w.close();
    _ = try w.remember("a", "promised", .{});
    const p = w.promise();
    try w.waitDurable(p);
    try testing.expect(w.isDurable(p));
}

test "brief holds the newest version only and fits its budget" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const w = try tmpStore(&tmp, null);
    defer w.close();
    _ = try w.remember("proj/7/decisions", "decision: the cache ttl for glimmer is fiftysec", .{ .subject = "glimmer/ttl" });
    for (0..50) |i| {
        var b: [64]u8 = undefined;
        _ = try w.remember("proj/7/chat/1", try std.fmt.bufPrint(&b, "chatter line {d} about lunch", .{i}), .{});
    }
    _ = try w.remember("proj/7/decisions", "update: the cache ttl for glimmer is ninetysec", .{ .subject = "glimmer/ttl" });
    const b = try w.brief(testing.allocator, "what is the cache ttl for glimmer?", "proj/7", 300);
    defer b.deinit(testing.allocator);
    try testing.expect(std.mem.indexOf(u8, b.text, "ninetysec") != null);
    try testing.expect(std.mem.indexOf(u8, b.text, "fiftysec") == null);
    try testing.expect(b.tokens <= 300);
}

test "forms of one word the stemmer does not join" {
    try testing.expect(sameStem(words.pack("allowed"), words.pack("allowance")));
    try testing.expect(sameStem(words.pack("deploy"), words.pack("deployment")));
    try testing.expect(!sameStem(words.pack("keep"), words.pack("kept")));
    try testing.expect(!sameStem(words.pack("record"), words.pack("region")));
    try testing.expect(!sameStem(words.pack("live"), words.pack("lives")));
}
