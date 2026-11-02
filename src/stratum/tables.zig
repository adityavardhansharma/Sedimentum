//! RAM tables that readers use without a lock while one writer at a time
//! changes them. Nothing is ever removed or moved while readers may look:
//! a map that grows publishes a new array and frees the old one only once
//! every reader that might hold it has left (see `Readers`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

/// Readers announce themselves in slots of their own (one cache line
/// each), so reading never writes a shared line. A writer that wants to
/// free memory readers might hold waits until every slot has been empty
/// once. A writer that must change the tables in place (rebuilding them)
/// closes the gate, which also keeps new readers out.
pub const Readers = struct {
    const nslots = 64;
    const Slot = struct {
        n: std.atomic.Value(u32) align(std.atomic.cache_line) = .init(0),
    };

    slots: [nslots]Slot = @splat(.{}),
    gate: std.atomic.Value(u32) align(std.atomic.cache_line) = .init(0),

    threadlocal var my_slot: ?u8 = null;
    var next_slot: std.atomic.Value(u32) = .init(0);

    fn slot() u8 {
        if (my_slot) |s| return s;
        const s: u8 = @intCast(next_slot.fetchAdd(1, .monotonic) % nslots);
        my_slot = s;
        return s;
    }

    pub fn enter(r: *Readers, io: Io) void {
        const s = &r.slots[slot()].n;
        while (true) {
            _ = s.fetchAdd(1, .seq_cst);
            if (r.gate.load(.seq_cst) == 0) return;
            if (s.fetchSub(1, .seq_cst) == 1) io.futexWake(u32, &s.raw, 1);
            while (r.gate.load(.acquire) != 0) io.futexWaitUncancelable(u32, &r.gate.raw, 1);
        }
    }

    pub fn leave(r: *Readers, io: Io) void {
        const s = &r.slots[slot()].n;
        if (s.fetchSub(1, .seq_cst) == 1) io.futexWake(u32, &s.raw, 1);
    }

    /// Returns once every slot has been empty at least once since the
    /// call: no reader can still hold memory unlinked before it.
    pub fn wait(r: *Readers, io: Io) void {
        for (&r.slots) |*sl| {
            var spins: usize = 0;
            while (true) {
                const n = sl.n.load(.seq_cst);
                if (n == 0) break;
                if (spins < 128) {
                    spins += 1;
                    std.atomic.spinLoopHint();
                } else io.futexWaitTimeout(u32, &sl.n.raw, n, .{ .duration = .{ .raw = .fromMilliseconds(1), .clock = .awake } }) catch {};
            }
        }
    }

    pub fn close(r: *Readers, io: Io) void {
        r.gate.store(1, .seq_cst);
        r.wait(io);
    }

    pub fn open(r: *Readers, io: Io) void {
        r.gate.store(0, .seq_cst);
        io.futexWake(u32, &r.gate.raw, std.math.maxInt(u32));
    }
};

/// A mutex for short sections: spins a little before sleeping, so a
/// handoff between writers rarely costs a sleep and a wake.
pub const Lock = struct {
    /// 0 free, 1 held, 2 held with sleepers.
    state: std.atomic.Value(u32) = .init(0),

    pub fn lockUncancelable(l: *Lock, io: Io) void {
        var spins: usize = 0;
        while (spins < 200) : (spins += 1) {
            if (l.state.load(.monotonic) == 0 and l.state.cmpxchgWeak(0, 1, .acquire, .monotonic) == null) return;
            std.atomic.spinLoopHint();
        }
        while (l.state.swap(2, .acquire) != 0) io.futexWaitUncancelable(u32, &l.state.raw, 2);
    }

    pub fn unlock(l: *Lock, io: Io) void {
        if (l.state.swap(0, .release) == 2) io.futexWake(u32, &l.state.raw, 1);
    }
};

/// u64 -> u64, insert and update only. Readers: `get`, lock-free. Writer
/// (one at a time): everything else.
pub const Map = struct {
    const Slot = struct { key: u64, val: u64 };
    const empty: u64 = 0;
    /// One allocation: readers load a single pointer and get a matching
    /// size and array.
    const Table = struct {
        cap: usize,
        slots: []Slot,
    };

    table: ?*Table = null,
    len: usize = 0,
    /// Tables replaced by a bigger one, freed after readers moved on.
    retired: std.ArrayList(*Table) = .empty,

    /// 0 marks an empty slot: keys are stored as k + 1 (and the one key
    /// that would wrap shares a slot with its neighbour).
    fn enc(k: u64) u64 {
        return if (k == std.math.maxInt(u64)) k else k + 1;
    }

    fn hash(k: u64) u64 {
        var x = k;
        x ^= x >> 33;
        x *%= 0xff51afd7ed558ccd;
        x ^= x >> 33;
        return x;
    }

    pub fn get(m: *const Map, k: u64) ?u64 {
        const t = @atomicLoad(?*Table, &m.table, .acquire) orelse return null;
        const cap = t.cap;
        const e = enc(k);
        var i = hash(e) & (cap - 1);
        while (true) : (i = (i + 1) & (cap - 1)) {
            const sk = @atomicLoad(u64, &t.slots[i].key, .acquire);
            if (sk == e) return @atomicLoad(u64, &t.slots[i].val, .acquire);
            if (sk == empty) return null;
        }
    }

    pub fn contains(m: *const Map, k: u64) bool {
        return m.get(k) != null;
    }

    pub fn count(m: *const Map) usize {
        return m.len;
    }

    pub fn capacity(m: *const Map) usize {
        return if (m.table) |t| t.cap else 0;
    }

    /// Writer only. `readers` lets a grown table's old one be freed.
    pub fn put(m: *Map, gpa: Allocator, readers: ?*Readers, io: Io, k: u64, v: u64) !void {
        if ((m.len + 1) * 2 > m.capacity()) try m.grow(gpa, readers, io, @max(16, m.capacity() * 2));
        const t = m.table.?;
        const e = enc(k);
        var i = hash(e) & (t.cap - 1);
        while (true) : (i = (i + 1) & (t.cap - 1)) {
            const sk = t.slots[i].key;
            if (sk == e) {
                @atomicStore(u64, &t.slots[i].val, v, .release);
                return;
            }
            if (sk == empty) {
                // The value first: a reader that sees the key sees it.
                @atomicStore(u64, &t.slots[i].val, v, .release);
                @atomicStore(u64, &t.slots[i].key, e, .release);
                m.len += 1;
                return;
            }
        }
    }

    pub fn ensureTotalCapacity(m: *Map, gpa: Allocator, readers: ?*Readers, io: Io, n: usize) !void {
        var cap: usize = @max(16, m.capacity());
        while (n * 2 > cap) cap *= 2;
        if (cap > m.capacity()) try m.grow(gpa, readers, io, cap);
    }

    fn grow(m: *Map, gpa: Allocator, readers: ?*Readers, io: Io, cap: usize) !void {
        const t = try gpa.create(Table);
        errdefer gpa.destroy(t);
        t.* = .{ .cap = cap, .slots = try gpa.alloc(Slot, cap) };
        @memset(t.slots, .{ .key = empty, .val = 0 });
        if (m.table) |old| {
            for (old.slots) |s| {
                if (s.key == empty) continue;
                var i = hash(s.key) & (cap - 1);
                while (t.slots[i].key != empty) i = (i + 1) & (cap - 1);
                t.slots[i] = s;
            }
            m.retired.append(gpa, old) catch |err| {
                gpa.free(t.slots);
                return err;
            };
        }
        @atomicStore(?*Table, &m.table, t, .release);
        if (readers) |r| {
            r.wait(io);
            m.freeRetired(gpa);
        }
    }

    fn freeTable(gpa: Allocator, t: *Table) void {
        gpa.free(t.slots);
        gpa.destroy(t);
    }

    fn freeRetired(m: *Map, gpa: Allocator) void {
        for (m.retired.items) |t| freeTable(gpa, t);
        m.retired.clearRetainingCapacity();
    }

    pub const Entry = struct { key: u64, value: u64 };

    pub const Iterator = struct {
        slots: []const Slot,
        i: usize = 0,
        pub fn next(it: *Iterator) ?Entry {
            while (it.i < it.slots.len) {
                const s = it.slots[it.i];
                it.i += 1;
                if (s.key != empty) return .{ .key = s.key - 1, .value = s.val };
            }
            return null;
        }
    };

    pub fn iterator(m: *const Map) Iterator {
        return .{ .slots = if (m.table) |t| t.slots else &.{} };
    }

    /// Only with readers kept out.
    pub fn clearRetainingCapacity(m: *Map, gpa: Allocator) void {
        if (m.table) |t| @memset(t.slots, .{ .key = empty, .val = 0 });
        m.len = 0;
        m.freeRetired(gpa);
    }

    pub fn deinit(m: *Map, gpa: Allocator) void {
        m.freeRetired(gpa);
        m.retired.deinit(gpa);
        if (m.table) |t| freeTable(gpa, t);
        m.* = .{};
    }
};

/// Scopes by id. Entries never move: they live in fixed chunks.
pub const Scopes = struct {
    pub const Scope = struct {
        name: []const u8,
        hash: u64,
        count: u32 = 0,
        /// Memories with a stamp below this were settled (summarised).
        settled: u64 = 0,
        /// Memories with a stamp below this were forgotten.
        forgot: u64 = 0,
    };
    const chunk_bits = 10;
    const chunk = 1 << chunk_bits;
    pub const max = 1 << 22;

    chunks: [max / chunk]?*[chunk]Scope = @splat(null),
    n: usize = 0,
    name_bytes: usize = 0,

    pub fn len(s: *const Scopes) usize {
        return @atomicLoad(usize, &s.n, .acquire);
    }

    pub fn at(s: *const Scopes, id: usize) *Scope {
        return &s.chunks[id >> chunk_bits].?[id & (chunk - 1)];
    }

    pub fn name(s: *const Scopes, id: usize) []const u8 {
        return s.at(id).name;
    }

    pub fn settled(s: *const Scopes, id: usize) u64 {
        return @atomicLoad(u64, &s.at(id).settled, .acquire);
    }

    pub fn forgot(s: *const Scopes, id: usize) u64 {
        return @atomicLoad(u64, &s.at(id).forgot, .acquire);
    }

    pub fn countOf(s: *const Scopes, id: usize) u32 {
        return @atomicLoad(u32, &s.at(id).count, .monotonic);
    }

    /// Writer only.
    pub fn append(s: *Scopes, gpa: Allocator, nm: []const u8, h: u64) !u32 {
        const id = s.n;
        if (id >= max) return error.TooManyScopes;
        if (s.chunks[id >> chunk_bits] == null) s.chunks[id >> chunk_bits] = try gpa.create([chunk]Scope);
        const copy = try gpa.dupe(u8, nm);
        s.at(id).* = .{ .name = copy, .hash = h };
        s.name_bytes += nm.len;
        @atomicStore(usize, &s.n, id + 1, .release);
        return @intCast(id);
    }

    pub fn raiseSettled(s: *Scopes, id: usize, v: u64) void {
        const p = &s.at(id).settled;
        if (v > p.*) @atomicStore(u64, p, v, .release);
    }

    pub fn raiseForgot(s: *Scopes, id: usize, v: u64) void {
        const p = &s.at(id).forgot;
        if (v > p.*) @atomicStore(u64, p, v, .release);
    }

    pub fn bump(s: *Scopes, id: usize) void {
        const p = &s.at(id).count;
        @atomicStore(u32, p, p.* + 1, .monotonic);
    }

    /// Only with readers kept out.
    pub fn clear(s: *Scopes, gpa: Allocator) void {
        for (0..s.n) |i| gpa.free(s.at(i).name);
        s.n = 0;
        s.name_bytes = 0;
    }

    pub fn deinit(s: *Scopes, gpa: Allocator) void {
        s.clear(gpa);
        for (&s.chunks) |*c| if (c.*) |p| {
            gpa.destroy(p);
            c.* = null;
        };
    }
};

test "map: put, get, grow, update" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var r: Readers = .{};
    var m: Map = .{};
    defer m.deinit(gpa);
    for (0..5000) |i| try m.put(gpa, &r, io, i, i * 3);
    try m.put(gpa, &r, io, 7, 1);
    try m.put(gpa, &r, io, std.math.maxInt(u64) - 1, 9);
    try std.testing.expectEqual(@as(?u64, 1), m.get(7));
    try std.testing.expectEqual(@as(?u64, 4999 * 3), m.get(4999));
    try std.testing.expectEqual(@as(?u64, 9), m.get(std.math.maxInt(u64) - 1));
    try std.testing.expectEqual(@as(?u64, null), m.get(5000));
    try std.testing.expectEqual(@as(usize, 5001), m.count());
    var n: usize = 0;
    var it = m.iterator();
    while (it.next()) |_| n += 1;
    try std.testing.expectEqual(@as(usize, 5001), n);
}

test "map: readers during growth" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var r: Readers = .{};
    var m: Map = .{};
    defer m.deinit(gpa);
    var done = std.atomic.Value(bool).init(false);
    const Ctx = struct {
        fn read(rr: *Readers, mm: *Map, d: *std.atomic.Value(bool)) void {
            var k: u64 = 0;
            while (!d.load(.acquire)) {
                rr.enter(std.testing.io);
                if (mm.get(k % 20000)) |v| std.debug.assert(v == (k % 20000) * 2);
                rr.leave(std.testing.io);
                k +%= 7;
            }
        }
    };
    var ths: [3]std.Thread = undefined;
    for (&ths) |*t| t.* = try std.Thread.spawn(.{}, Ctx.read, .{ &r, &m, &done });
    for (0..20000) |i| try m.put(gpa, &r, io, i, i * 2);
    done.store(true, .release);
    for (ths) |t| t.join();
    try std.testing.expectEqual(@as(?u64, 39998), m.get(19999));
}
