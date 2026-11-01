//! The database: an append-only log on disk plus an ordered index in memory.
//!
//! The index maps every live key to the location of its newest record, so a
//! point read is one tree lookup plus one read of the record. Deleted keys
//! are removed from the index; their tombstones stay in the log until
//! compaction.
//!
//! Compaction rewrites the live records of a mostly dead sealed segment to
//! the end of the log, keeping their sequence numbers, then deletes the old
//! file. Recovery therefore resolves each key by the highest sequence
//! number seen, not by file order.
//!
//! Snapshots are sequence numbers. Taking one copies nothing. While any
//! snapshot is open, an overwrite or delete keeps the replaced version in
//! a short chain on the index entry, and compaction pauses. Releasing the
//! last snapshot frees the chains.
//!
//! With `memory_budget` set, the index can be bigger than RAM. When it
//! outgrows the budget, the entries for sealed segments are merged into a
//! sorted file on disk (the cold index, see `cold.zig`) and dropped from
//! memory. Lookups check memory first, then the cold index through its
//! bloom filter. A write to a key that only the cold index knows first
//! copies its entry into memory ("faulting it in"), so every write path
//! works on memory alone. Deleting such a key leaves a deletion marker in
//! memory until the next merge drops the key from the cold index. On
//! open, segments the cold index covers are not replayed.
//!
//! A `Db` is used from one thread at a time. See `Shared` for threads.

const Db = @This();

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const record = @import("record.zig");
const Log = @import("Log.zig");
const ordered = @import("index.zig");
const coldfile = @import("cold.zig");

pub const Options = struct {
    log: Log.Options = .{},
    /// Sync after every write so a successful `put` or `delete` is durable.
    /// Turn off to batch writes and call `sync` yourself.
    sync_writes: bool = true,
    /// Compact a sealed segment once at least this fraction of it is dead.
    compact_dead_ratio: f64 = 0.3,
    /// Check for segments to compact whenever the log starts a new segment.
    auto_compact: bool = true,
    /// Approximate bytes the in-memory index may use before entries for
    /// sealed segments move to the cold index on disk. 0 keeps everything
    /// in memory.
    memory_budget: usize = 0,
};

/// Estimated memory per index entry besides its key: the entry, its hash
/// slot and its tree slot. Measured at about 160 bytes.
pub const entry_overhead = 160;

/// What the index stores per key: the newest version, plus older versions
/// that open snapshots can still see.
pub const Entry = struct {
    seq: u64,
    segment: u32,
    offset: u32,
    /// Record length; 0 for a deletion kept only for snapshots.
    len: u32,
    /// Unix seconds after which the value no longer counts; 0 for never.
    expires: u64 = 0,
    deleted: bool = false,
    /// The cold index also has this key, so the entry must stay in memory
    /// (as a deletion marker if deleted) until the next merge.
    in_cold: bool = false,
    older: ?*Entry = null,

    pub fn location(e: Entry) Log.Location {
        return .{ .segment = e.segment, .offset = e.offset, .len = e.len };
    }

    fn at(loc: Log.Location, rec: record.Record) Entry {
        return .{
            .segment = @intCast(loc.segment),
            .offset = @intCast(loc.offset),
            .len = loc.len,
            .seq = rec.seq,
            .expires = rec.expires,
        };
    }

    fn fromCold(c: coldfile.Entry) Entry {
        return .{ .seq = c.seq, .segment = c.segment, .offset = c.offset, .len = c.len, .expires = c.expires, .in_cold = true };
    }

    fn toCold(e: Entry) coldfile.Entry {
        return .{ .seq = e.seq, .segment = e.segment, .offset = e.offset, .len = e.len, .expires = e.expires };
    }

    pub fn expiredAt(e: *const Entry, now_s: u64) bool {
        return e.expires != 0 and e.expires <= now_s;
    }

    /// The version visible at sequence `seq`, or null if none, deleted or
    /// expired at `now`.
    pub fn resolve(e: *const Entry, seq: u64, now_s: u64) ?*const Entry {
        var v: ?*const Entry = e;
        while (v) |cur| : (v = cur.older) {
            if (cur.seq <= seq) return if (cur.deleted or cur.expiredAt(now_s)) null else cur;
        }
        return null;
    }
};

pub const Index = ordered.HashedIndex(Entry);

/// Per-segment bookkeeping for compaction.
const SegStat = struct {
    /// Bytes of records the index still points to.
    live: u64 = 0,
    /// Lowest sequence number of any record in the segment.
    min_seq: u64 = std.math.maxInt(u64),
    /// Part of `live` that belongs to expiring values.
    ttl_live: u64 = 0,
    /// Latest expiry of any expiring value written to the segment. Once
    /// it has passed, all of `ttl_live` is dead too.
    max_expiry: u64 = 0,

    fn add(st: *SegStat, e: Entry) void {
        st.live += e.len;
        if (e.expires != 0) {
            st.ttl_live += e.len;
            st.max_expiry = @max(st.max_expiry, e.expires);
        }
    }
};

pub const Snapshot = struct { seq: u64 };

pub const Op = union(enum) {
    put: struct {
        key: []const u8,
        value: []const u8,
        /// Seconds until the value expires; 0 for never.
        ttl: u32 = 0,
    },
    delete: []const u8,
};

pub const Expect = union(enum) {
    /// The key must not exist.
    absent,
    /// The key must exist with exactly this sequence number.
    seq: u64,
};

gpa: Allocator,
options: Options,
log: Log,
index: Index,
seg_stats: std.AutoHashMapUnmanaged(u64, SegStat) = .empty,
/// Open snapshot sequence numbers (a multiset).
snapshots: std.ArrayList(u64) = .empty,
/// Index entries that are deletions kept for snapshots.
tombstone_entries: usize = 0,
/// Older versions currently held in chains.
retained_versions: usize = 0,
/// Scratch space for reading records.
read_buf: std.ArrayList(u8) = .empty,
compactions: u64 = 0,
/// The on-disk index for keys not held in memory, if any.
cold: ?coldfile.Reader = null,
/// In-memory entries whose key the cold index also has.
cold_shadowed: usize = 0,
merges: u64 = 0,
/// Fixed clock for tests, in unix seconds.
clock_override: ?u64 = null,

pub fn open(gpa: Allocator, io: Io, parent: Io.Dir, sub_path: []const u8, options: Options) !Db {
    // Index entries store offsets as u32.
    if (options.log.segment_bytes > std.math.maxInt(u32)) return error.SegmentTooLarge;
    var idx = try Index.init(gpa);
    errdefer idx.deinit();
    // Replay fills only the hash table; the ordered tree is built once at
    // the end, which is much faster than inserting keys in log order.
    idx.bulk = true;
    var loader: Loader = .{ .gpa = gpa, .io = io, .index = &idx };
    defer loader.deinit();
    var log = try Log.open(gpa, io, parent, sub_path, options.log, &loader);
    errdefer log.close();
    try idx.finishBulk();

    var db: Db = .{ .gpa = gpa, .options = options, .log = log, .index = idx, .seg_stats = loader.stats, .cold = loader.cold };
    loader.stats = .empty;
    loader.cold = null;
    errdefer {
        if (db.cold) |*c| c.close();
        db.seg_stats.deinit(gpa);
    }
    if (db.cold) |*c| {
        db.log.last_seq = @max(db.log.last_seq, c.last_seq);
        // Segments the cold index covers were not replayed; their stats
        // were saved with it.
        for (0..c.statCount()) |i| {
            const st = c.stat(i);
            if (db.log.segs.get(st.id) == null) continue;
            (try db.statFor(st.id)).* = .{ .live = st.live, .min_seq = st.min_seq, .ttl_live = st.ttl_live, .max_expiry = st.max_expiry };
        }
    }
    // Live bytes come from what the index ended up pointing to.
    var cur = db.index.first();
    while (cur.valid()) : (cur.next()) {
        const e = cur.valuePtr().*;
        if (e.in_cold) {
            db.cold_shadowed += 1;
            // The cold entry this one replaced is no longer live.
            if (try db.cold.?.get(cur.key())) |old| db.releaseBytes(Entry.fromCold(old));
        }
        if (e.deleted) {
            db.tombstone_entries += 1;
            continue;
        }
        (try db.statFor(e.segment)).add(e);
    }
    return db;
}

pub fn close(db: *Db) void {
    db.freeAllVersions();
    db.snapshots.deinit(db.gpa);
    db.read_buf.deinit(db.gpa);
    db.seg_stats.deinit(db.gpa);
    db.index.deinit();
    if (db.cold) |*c| c.close();
    db.log.close();
    db.* = undefined;
}

/// Rebuilds the index during open. The highest sequence number wins.
const Loader = struct {
    gpa: Allocator,
    io: Io,
    index: *Index,
    cold: ?coldfile.Reader = null,
    /// Sequence of the newest tombstone seen per deleted key.
    dead: std.StringHashMapUnmanaged(u64) = .empty,
    stats: std.AutoHashMapUnmanaged(u64, SegStat) = .empty,
    /// Records arrive one segment at a time; cache that segment's stats.
    /// Safe because no other segment is added to `stats` meanwhile.
    last_segment: u64 = 0,
    last_stat: *SegStat = undefined,

    fn deinit(l: *Loader) void {
        var it = l.dead.keyIterator();
        while (it.next()) |k| l.gpa.free(k.*);
        l.dead.deinit(l.gpa);
        l.stats.deinit(l.gpa);
        if (l.cold) |*c| c.close();
    }

    /// Called by `Log.open` once it holds the directory lock. Returns the
    /// last segment the cold index covers, which replay skips.
    pub fn prepare(l: *Loader, dir: Io.Dir) !u64 {
        coldfile.removeLeftovers(l.io, dir);
        l.cold = try coldfile.Reader.open(l.gpa, l.io, dir);
        return if (l.cold) |c| c.covered_through else 0;
    }

    /// The sequence number the cold index holds for `key`, if any.
    fn coldSeq(l: *const Loader, key: []const u8) !?u64 {
        const c = &(l.cold orelse return null);
        return if (try c.get(key)) |e| e.seq else null;
    }

    pub fn onRecord(l: *Loader, loc: Log.Location, rec: record.Record) !void {
        if (l.last_segment != loc.segment) {
            const st = try l.stats.getOrPut(l.gpa, loc.segment);
            if (!st.found_existing) st.value_ptr.* = .{};
            l.last_stat = st.value_ptr;
            l.last_segment = loc.segment;
        }
        l.last_stat.min_seq = @min(l.last_stat.min_seq, rec.seq);

        switch (rec.kind) {
            .put, .put_ttl => {
                if (l.dead.count() > 0) if (l.dead.get(rec.key)) |dseq| if (dseq > rec.seq) return;
                if (l.index.getPtr(rec.key)) |e| {
                    if (e.seq > rec.seq) return;
                    const in_cold = e.in_cold;
                    e.* = Entry.at(loc, rec);
                    e.in_cold = in_cold;
                    return;
                }
                const cseq = try l.coldSeq(rec.key);
                if (cseq) |cs| if (cs > rec.seq) return;
                const slot = try l.index.getOrPut(rec.key);
                slot.value_ptr.* = Entry.at(loc, rec);
                slot.value_ptr.in_cold = cseq != null;
            },
            .delete => {
                var in_cold = false;
                if (l.index.getPtr(rec.key)) |e| {
                    if (e.seq > rec.seq) return;
                    in_cold = e.in_cold;
                    if (!in_cold) _ = l.index.remove(rec.key);
                } else if (try l.coldSeq(rec.key)) |cs| {
                    if (cs > rec.seq) return;
                    in_cold = true;
                }
                if (in_cold) {
                    // Keep a marker so the cold entry stays hidden.
                    const slot = try l.index.getOrPut(rec.key);
                    slot.value_ptr.* = .{ .seq = rec.seq, .segment = @intCast(loc.segment), .offset = 0, .len = 0, .deleted = true, .in_cold = true };
                }
                const gop = try l.dead.getOrPut(l.gpa, rec.key);
                if (!gop.found_existing) {
                    gop.key_ptr.* = l.gpa.dupe(u8, rec.key) catch |err| {
                        l.dead.removeByPtr(gop.key_ptr);
                        return err;
                    };
                    gop.value_ptr.* = rec.seq;
                } else gop.value_ptr.* = @max(gop.value_ptr.*, rec.seq);
            },
            else => return error.Corrupt,
        }
    }
};

fn statFor(db: *Db, segment: u64) !*SegStat {
    const gop = try db.seg_stats.getOrPut(db.gpa, segment);
    if (!gop.found_existing) gop.value_ptr.* = .{};
    return gop.value_ptr;
}

/// Records that the record behind `e` is no longer the live version.
fn releaseBytes(db: *Db, e: Entry) void {
    if (e.deleted) return;
    if (db.seg_stats.getPtr(e.segment)) |st| {
        st.live -|= e.len;
        if (e.expires != 0) st.ttl_live -|= e.len;
    }
}

/// Bookkeeping for a record just appended. `live` is the index entry that
/// now points at it, or null for a tombstone.
fn noteAppended(db: *Db, loc: Log.Location, seq: u64, live: ?Entry) void {
    // Stats exist for every segment the log can append to: `reserveStats`
    // runs before each append.
    const st = db.seg_stats.getPtr(loc.segment).?;
    st.min_seq = @min(st.min_seq, seq);
    if (live) |e| st.add(e);
}

/// Makes sure the active segment and the one a rollover would create both
/// have stats, so bookkeeping after an append can't fail.
fn reserveStats(db: *Db) !void {
    _ = try db.statFor(db.log.active_id);
    _ = try db.statFor(db.log.active_id + 1);
}

/// Whether an open snapshot can see the version written at `seq`.
fn snapshotNeeds(db: *const Db, seq: u64) bool {
    for (db.snapshots.items) |s| if (s >= seq) return true;
    return false;
}

/// Number of keys, in memory and in the cold index. Expired keys count
/// until compaction, a merge or a later write removes them.
pub fn count(db: *const Db) usize {
    const cold_only: usize = if (db.cold) |c| @as(usize, @intCast(c.entries)) - db.cold_shadowed else 0;
    return db.index.len() - db.tombstone_entries + cold_only;
}

/// Approximate heap bytes used by the in-memory index and the cold index's
/// summary. Compared against `memory_budget`.
pub fn memoryUsed(db: *const Db) usize {
    const cold_bytes = if (db.cold) |*c| c.heapBytes() else 0;
    return db.index.keyBytes() + db.index.len() * entry_overhead + cold_bytes;
}

/// The sequence number of the newest write.
pub fn lastSeq(db: *const Db) u64 {
    return db.log.last_seq;
}

/// Current time in unix seconds.
pub fn now(db: *const Db) u64 {
    if (db.clock_override) |t| return t;
    const ns = Io.Clock.real.now(db.log.io).nanoseconds;
    return if (ns <= 0) 0 else @intCast(@divFloor(ns, std.time.ns_per_s));
}

/// The live in-memory entry for `key`, if any. Expired entries are not
/// live. Does not look at the cold index; see `find`.
fn lookup(db: *const Db, key: []const u8) ?*Entry {
    const e = db.index.getPtr(key) orelse return null;
    if (e.deleted) return null;
    if (e.expires != 0 and e.expiredAt(db.now())) return null;
    return e;
}

/// The live entry for `key`, from memory or the cold index.
pub fn find(db: *const Db, key: []const u8) !?Entry {
    if (db.index.getPtr(key)) |e| {
        if (e.deleted or e.expiredAt(db.now())) return null;
        return e.*;
    }
    const c = &(db.cold orelse return null);
    const ce = (try c.get(key)) orelse return null;
    const e = Entry.fromCold(ce);
    return if (e.expiredAt(db.now())) null else e;
}

/// The entry visible to `snap` for `key`, if any.
pub fn findAt(db: *const Db, snap: Snapshot, key: []const u8) !?Entry {
    if (db.index.getPtr(key)) |e| {
        const v = e.resolve(snap.seq, db.now()) orelse return null;
        return v.*;
    }
    const c = &(db.cold orelse return null);
    const ce = (try c.get(key)) orelse return null;
    const e = Entry.fromCold(ce);
    return if (e.seq > snap.seq or e.expiredAt(db.now())) null else e;
}

/// Copies the cold index's entry for `key` into memory, so a write can
/// update it there. Does nothing if memory already has the key.
fn faultIn(db: *Db, key: []const u8) !void {
    if (db.index.getPtr(key) != null) return;
    const c = &(db.cold orelse return);
    const ce = (try c.get(key)) orelse return;
    try db.index.put(key, Entry.fromCold(ce));
    db.cold_shadowed += 1;
}

/// The sequence number of the live version of `key`, for `putIf`.
pub fn seqOf(db: *const Db, key: []const u8) !?u64 {
    return if (try db.find(key)) |e| e.seq else null;
}

pub fn contains(db: *const Db, key: []const u8) !bool {
    return try db.find(key) != null;
}

// ---------------------------------------------------------------- writes

pub fn put(db: *Db, key: []const u8, value: []const u8) !void {
    try db.putBuffered(key, value);
    if (db.options.sync_writes) try db.log.sync();
}

/// Like `put`, but the value disappears after `ttl` seconds. Expired
/// records are dropped by compaction.
pub fn putTtl(db: *Db, key: []const u8, value: []const u8, ttl: u32) !void {
    try db.putTtlBuffered(key, value, ttl);
    if (db.options.sync_writes) try db.log.sync();
}

pub fn putTtlBuffered(db: *Db, key: []const u8, value: []const u8, ttl: u32) !void {
    const segments_before = db.log.segments.items.len;
    try db.putCore(db.putRecord(key, value, ttl));
    try db.afterAppend(segments_before);
}

fn putRecord(db: *const Db, key: []const u8, value: []const u8, ttl: u32) record.Record {
    if (ttl == 0) return .{ .seq = 0, .kind = .put, .key = key, .value = value };
    return .{ .seq = 0, .kind = .put_ttl, .key = key, .value = value, .expires = db.now() + ttl };
}

/// Writes `key` only if its current state matches `expect`, otherwise
/// returns `error.Conflict` and writes nothing.
pub fn putIf(db: *Db, key: []const u8, value: []const u8, expect: Expect) !void {
    const current = try db.seqOf(key);
    const ok = switch (expect) {
        .absent => current == null,
        .seq => |s| current != null and current.? == s,
    };
    if (!ok) return error.Conflict;
    try db.put(key, value);
}

/// Applies a put without syncing, whatever `sync_writes` says.
pub fn putBuffered(db: *Db, key: []const u8, value: []const u8) !void {
    const segments_before = db.log.segments.items.len;
    try db.putCore(db.putRecord(key, value, 0));
    try db.afterAppend(segments_before);
}

/// `template.seq` is ignored; the next sequence number is used.
fn putCore(db: *Db, template: record.Record) !void {
    const key = template.key;
    var rec = template;
    rec.seq = 1;
    try record.validate(rec);
    try db.reserveStats();
    try db.faultIn(key);
    // Reserve the index slot and any history version before appending, so
    // nothing can fail between the log write and the index update.
    const slot = try db.index.getOrPut(key);
    errdefer if (!slot.found_existing) {
        _ = db.index.remove(key);
    };
    const keep_old = slot.found_existing and db.snapshotNeeds(slot.value_ptr.seq);
    const old_copy: ?*Entry = if (keep_old) try db.gpa.create(Entry) else null;
    errdefer if (old_copy) |c| db.gpa.destroy(c);

    rec.seq = db.log.last_seq + 1;
    const loc = try db.log.append(rec);
    var new = Entry.at(loc, rec);
    db.noteAppended(loc, rec.seq, new);

    if (slot.found_existing) {
        const old = slot.value_ptr.*;
        db.releaseBytes(old);
        new.in_cold = old.in_cold;
        if (old.deleted) db.tombstone_entries -= 1;
        if (old_copy) |c| {
            c.* = old;
            new.older = c;
            db.retained_versions += 1;
        } else {
            // Older versions may still be needed; they are pruned when the
            // last snapshot is released.
            new.older = old.older;
        }
    }
    slot.value_ptr.* = new;
}

fn afterAppend(db: *Db, segments_before: usize) !void {
    if (db.log.segments.items.len <= segments_before) return;
    if (db.options.memory_budget > 0 and db.memoryUsed() > db.options.memory_budget) {
        _ = try db.spill();
    }
    if (db.options.auto_compact) _ = try db.compact();
}

/// Deletes `key`. Returns whether it existed. Deleting a missing key
/// writes nothing.
pub fn delete(db: *Db, key: []const u8) !bool {
    const existed = try db.deleteBuffered(key);
    if (existed and db.options.sync_writes) try db.log.sync();
    return existed;
}

/// Applies a delete without syncing, whatever `sync_writes` says.
pub fn deleteBuffered(db: *Db, key: []const u8) !bool {
    if (key.len == 0) return error.EmptyKey;
    try db.faultIn(key);
    const e = db.lookup(key) orelse return false;
    const segments_before = db.log.segments.items.len;
    try db.deleteCore(key, e);
    try db.afterAppend(segments_before);
    return true;
}

fn deleteCore(db: *Db, key: []const u8, e: *Entry) !void {
    try db.reserveStats();
    const keep_old = db.snapshotNeeds(e.seq);
    const old_copy: ?*Entry = if (keep_old) try db.gpa.create(Entry) else null;
    errdefer if (old_copy) |c| db.gpa.destroy(c);

    const seq = db.log.last_seq + 1;
    const loc = try db.log.append(.{ .seq = seq, .kind = .delete, .key = key });
    db.noteAppended(loc, seq, null);
    db.applyDelete(key, e, seq, @intCast(loc.segment), old_copy);
}

/// Updates the index for a delete already in the log.
fn applyDelete(db: *Db, key: []const u8, e: *Entry, seq: u64, segment: u32, old_copy: ?*Entry) void {
    db.releaseBytes(e.*);
    const older: ?*Entry = if (old_copy) |c| blk: {
        c.* = e.*;
        db.retained_versions += 1;
        break :blk c;
    } else e.older;
    if (older != null or e.in_cold) {
        // Snapshots can still see this key, or the cold index still has
        // it; keep a deletion marker that hides it and carries the history.
        e.* = .{ .seq = seq, .segment = segment, .offset = 0, .len = 0, .deleted = true, .in_cold = e.in_cold, .older = older };
        db.tombstone_entries += 1;
    } else {
        _ = db.index.remove(key);
    }
}

/// Applies `ops` atomically: after a crash, either all of them are in the
/// database or none are. Later operations on the same key win.
pub fn write(db: *Db, ops: []const Op) !void {
    try db.writeBuffered(ops);
    if (db.options.sync_writes) try db.log.sync();
}

/// Like `write` without syncing, whatever `sync_writes` says.
pub fn writeBuffered(db: *Db, ops: []const Op) !void {
    if (ops.len == 0) return;
    const segments_before = db.log.segments.items.len;
    try db.writeCore(ops);
    try db.afterAppend(segments_before);
}

fn writeCore(db: *Db, ops: []const Op) !void {
    const gpa = db.gpa;
    const recs = try gpa.alloc(record.Record, ops.len);
    defer gpa.free(recs);
    const locs = try gpa.alloc(Log.Location, ops.len);
    defer gpa.free(locs);
    var seq = db.log.last_seq;
    for (ops, recs) |op, *rec| {
        seq += 1;
        rec.* = switch (op) {
            .put => |p| db.putRecord(p.key, p.value, p.ttl),
            .delete => |k| .{ .seq = 0, .kind = .delete, .key = k },
        };
        rec.seq = seq;
        try record.validate(rec.*);
    }

    try db.reserveStats();
    for (ops) |op| try db.faultIn(switch (op) {
        .put => |p| p.key,
        .delete => |k| k,
    });

    // Reserve every index slot a put needs, and a history version per
    // operation if snapshots are open, so applying can't fail.
    var reserved: std.ArrayList([]const u8) = .empty;
    defer reserved.deinit(gpa);
    var appended = false;
    errdefer if (!appended) {
        for (reserved.items) |k| _ = db.index.remove(k);
        db.tombstone_entries -= reserved.items.len;
    };
    for (ops) |op| switch (op) {
        .put => |p| {
            const slot = try db.index.getOrPut(p.key);
            if (!slot.found_existing) {
                slot.value_ptr.* = .{ .seq = 0, .segment = 0, .offset = 0, .len = 0, .deleted = true };
                // Count it as a tombstone so `count` stays right meanwhile.
                db.tombstone_entries += 1;
                reserved.append(gpa, p.key) catch |err| {
                    db.tombstone_entries -= 1;
                    _ = db.index.remove(p.key);
                    return err;
                };
            }
        },
        .delete => {},
    };
    var spare: std.ArrayList(*Entry) = .empty;
    defer {
        for (spare.items) |c| gpa.destroy(c);
        spare.deinit(gpa);
    }
    if (db.snapshots.items.len > 0) {
        try spare.ensureTotalCapacity(gpa, ops.len);
        for (0..ops.len) |_| spare.appendAssumeCapacity(try gpa.create(Entry));
    }

    // Keys whose entry may end up as an unused placeholder.
    var cleanup: std.ArrayList([]const u8) = try .initCapacity(gpa, ops.len + reserved.items.len);
    defer cleanup.deinit(gpa);

    try db.log.appendBatch(recs, locs);
    appended = true;

    // Nothing below allocates. Deletes turn entries into placeholders
    // instead of removing them, so every later put in the batch still
    // finds its slot; placeholders are removed once all ops are applied.
    for (ops, recs, locs) |op, rec, loc| switch (op) {
        .put => |p| {
            const slot = db.index.getPtr(p.key).?;
            var new = Entry.at(loc, rec);
            db.noteAppended(loc, rec.seq, new);
            const old = slot.*;
            const placeholder = old.seq == 0;
            db.releaseBytes(old);
            new.in_cold = old.in_cold;
            if (old.deleted) db.tombstone_entries -= 1;
            if (!placeholder and db.snapshotNeeds(old.seq) and spare.items.len > 0) {
                const c = spare.pop().?;
                c.* = old;
                new.older = c;
                db.retained_versions += 1;
            } else new.older = old.older;
            slot.* = new;
        },
        .delete => |k| {
            db.noteAppended(loc, rec.seq, null);
            cleanup.appendAssumeCapacity(k);
            const e = db.index.getPtr(k) orelse continue;
            if (e.deleted) continue;
            const copy: ?*Entry = if (db.snapshotNeeds(e.seq) and spare.items.len > 0) spare.pop().? else null;
            db.releaseBytes(e.*);
            const older: ?*Entry = if (copy) |c| blk: {
                c.* = e.*;
                db.retained_versions += 1;
                break :blk c;
            } else e.older;
            // With history, or a cold entry to hide, this is a deletion
            // marker; without, a placeholder removed below.
            const keep = older != null or e.in_cold;
            e.* = .{ .seq = if (keep) rec.seq else 0, .segment = @intCast(loc.segment), .offset = 0, .len = 0, .deleted = true, .in_cold = e.in_cold, .older = older };
            db.tombstone_entries += 1;
        },
    };
    for (reserved.items) |k| cleanup.appendAssumeCapacity(k);
    for (cleanup.items) |k| {
        const e = db.index.getPtr(k) orelse continue;
        if (e.deleted and e.seq == 0) {
            _ = db.index.remove(k);
            db.tombstone_entries -= 1;
        }
    }
}

/// Deletes every key that starts with `prefix` and returns how many there
/// were. Up to `delete_prefix_chunk` deletions are written per atomic batch.
pub fn deletePrefix(db: *Db, prefix: []const u8) !usize {
    const n = try db.deletePrefixBuffered(prefix);
    if (n > 0 and db.options.sync_writes) try db.log.sync();
    return n;
}

pub const delete_prefix_chunk = 10_000;

pub fn deletePrefixBuffered(db: *Db, prefix: []const u8) !usize {
    const gpa = db.gpa;
    var total: usize = 0;
    var keys: std.ArrayList([]u8) = .empty;
    defer keys.deinit(gpa);
    var ops: std.ArrayList(Op) = .empty;
    defer ops.deinit(gpa);
    const end_buf = try gpa.alloc(u8, prefix.len);
    defer gpa.free(end_buf);

    while (true) {
        defer {
            for (keys.items) |k| gpa.free(k);
            keys.clearRetainingCapacity();
            ops.clearRetainingCapacity();
        }
        // Collect a chunk first: writing while iterating would invalidate
        // the cursor.
        var it = try db.prefixIterator(prefix, false, end_buf);
        // A batch body holds one delete record per key and must stay
        // within the record size limit.
        var bytes: usize = 0;
        while (keys.items.len < delete_prefix_chunk) {
            const k = (try it.peekKey()) orelse break;
            const len = record.header_len + k.len;
            if (bytes + len > record.max_value_len) break;
            bytes += len;
            _ = try it.nextKey();
            const copy = try gpa.dupe(u8, k);
            keys.append(gpa, copy) catch |err| {
                gpa.free(copy);
                return err;
            };
        }
        if (keys.items.len == 0) return total;
        for (keys.items) |k| try ops.append(gpa, .{ .delete = k });
        try db.writeBuffered(ops.items);
        total += keys.items.len;
    }
}

/// Makes every accepted write durable.
pub fn sync(db: *Db) !void {
    try db.log.sync();
}

// ----------------------------------------------------------------- reads

/// Returns a copy of the value for `key`, owned by the caller.
pub fn get(db: *Db, gpa: Allocator, key: []const u8) !?[]u8 {
    const value = (try db.getView(key)) orelse return null;
    return try gpa.dupe(u8, value);
}

/// Returns the value for `key` without copying. The slice is valid until
/// the next call on this `Db`.
pub fn getView(db: *Db, key: []const u8) !?[]const u8 {
    const e = (try db.find(key)) orelse return null;
    return try db.readValue(key, e);
}

/// Reads the value of `key` stored at `e`.
pub fn readValue(db: *Db, key: []const u8, e: Entry) ![]const u8 {
    return db.readValueInto(db.gpa, key, e, &db.read_buf);
}

/// Like `readValue`, but a value that has to be read from the file goes
/// into `buf` instead of the `Db`'s own scratch space. Does not modify the
/// `Db`, so several threads holding a shared lock can call it at once.
/// Fails with `error.Corrupt` if the record there belongs to another key.
pub fn readValueInto(db: *const Db, gpa: Allocator, key: []const u8, e: Entry, buf: *std.ArrayList(u8)) ![]const u8 {
    const rec = if (try db.log.view(e.location())) |r| r else blk: {
        try buf.resize(gpa, e.len);
        break :blk try db.log.read(e.location(), buf.items);
    };
    if (!std.mem.eql(u8, rec.key, key)) return error.Corrupt;
    return rec.value;
}

// ------------------------------------------------------------- snapshots

/// Captures the current state. Release it with `release`.
pub fn snapshot(db: *Db) !Snapshot {
    try db.snapshots.append(db.gpa, db.log.last_seq);
    return .{ .seq = db.log.last_seq };
}

pub fn release(db: *Db, snap: Snapshot) void {
    for (db.snapshots.items, 0..) |s, i| if (s == snap.seq) {
        _ = db.snapshots.swapRemove(i);
        break;
    };
    if (db.snapshots.items.len == 0) db.dropHistory();
}

/// The value of `key` as of `snap`, without copying.
pub fn getAt(db: *Db, snap: Snapshot, key: []const u8) !?[]const u8 {
    const e = (try db.findAt(snap, key)) orelse return null;
    return try db.readValue(key, e);
}

fn freeChain(db: *Db, first: ?*Entry) void {
    var v = first;
    while (v) |cur| {
        v = cur.older;
        db.gpa.destroy(cur);
        db.retained_versions -= 1;
    }
}

/// Frees every retained version and drops deletion entries. Runs when the
/// last snapshot is released.
fn dropHistory(db: *Db) void {
    if (db.retained_versions == 0 and db.tombstone_entries == 0) return;
    var dead: std.ArrayList([]const u8) = .empty;
    defer {
        for (dead.items) |k| db.gpa.free(k);
        dead.deinit(db.gpa);
    }
    var c = db.index.first();
    while (c.valid()) : (c.next()) {
        const e = c.valuePtr();
        db.freeChain(e.older);
        e.older = null;
        // Markers hiding a cold entry stay until the next merge.
        if (e.deleted and !e.in_cold) {
            // Removing during the walk would shift the leaf under the
            // cursor, so collect keys first. If that fails, the entry just
            // stays as a harmless deletion marker.
            const k = db.gpa.dupe(u8, c.key()) catch continue;
            dead.append(db.gpa, k) catch {
                db.gpa.free(k);
                continue;
            };
        }
    }
    for (dead.items) |k| {
        _ = db.index.remove(k);
        db.tombstone_entries -= 1;
    }
}

fn freeAllVersions(db: *Db) void {
    var c = db.index.first();
    while (c.valid()) : (c.next()) {
        const e = c.valuePtr();
        db.freeChain(e.older);
        e.older = null;
    }
}

// ------------------------------------------------------------ compaction

pub const SpaceStats = struct {
    segments: usize,
    total_bytes: u64,
    live_bytes: u64,
};

pub fn spaceStats(db: *const Db) SpaceStats {
    var total: u64 = 0;
    var live: u64 = 0;
    for (db.log.segments.items) |id| {
        total += db.log.segmentSize(id);
        if (db.seg_stats.get(id)) |st| live += st.live;
    }
    return .{ .segments = db.log.segments.items.len, .total_bytes = total, .live_bytes = live };
}

/// Compacts every sealed segment that is at least `compact_dead_ratio`
/// dead. Returns how many segments were rewritten. Does nothing while a
/// snapshot is open, since snapshots may read old versions anywhere.
pub fn compact(db: *Db) !usize {
    return db.compactWithRatio(db.options.compact_dead_ratio);
}

/// Like `compact`, with an explicit threshold. 0 compacts every sealed
/// segment that has any dead bytes.
pub fn compactWithRatio(db: *Db, dead_ratio: f64) !usize {
    if (db.snapshots.items.len > 0) return 0;
    const now_s = db.now();
    // Copy the candidate list: compaction changes `segments`.
    var candidates: std.ArrayList(u64) = .empty;
    defer candidates.deinit(db.gpa);
    for (db.log.segments.items) |id| {
        if (id == db.log.active_id) continue;
        const size = db.log.segmentSize(id);
        if (size == 0) {
            try candidates.append(db.gpa, id);
            continue;
        }
        var live: u64 = 0;
        if (db.seg_stats.get(id)) |st| {
            live = st.live;
            // Expired values still count as live in the index until
            // compaction drops them.
            if (st.ttl_live > 0 and st.max_expiry <= now_s) live -|= st.ttl_live;
        }
        const dead = 1.0 - @as(f64, @floatFromInt(live)) / @as(f64, @floatFromInt(size));
        if (dead > 0 and dead >= dead_ratio) try candidates.append(db.gpa, id);
    }
    for (candidates.items) |id| try db.compactSegment(id);
    return candidates.items.len;
}

fn compactSegment(db: *Db, id: u64) !void {
    // Records copied out of this segment can't hide anything, so judge
    // "older data elsewhere" by the other segments as they are now.
    const floor = db.oldestSeqOutside(id);
    var scanner = try db.log.scanSegment(id);
    defer scanner.deinit();
    while (try scanner.next()) |item| {
        if (item.record.kind == .batch) {
            const body_offset = item.offset + record.header_len + 4;
            var ops = record.BatchIterator.init(item.record);
            while (try ops.next()) |op| {
                try db.compactRecord(id, floor, body_offset + op.offset, op.record);
            }
        } else {
            try db.compactRecord(id, floor, item.offset, item.record);
        }
    }
    if (scanner.stop != .end) return error.Corrupt;
    // Copies must be durable before the originals disappear.
    try db.log.sync();
    try db.log.removeSegment(id);
    _ = db.seg_stats.remove(id);
    db.compactions += 1;
}

/// `floor` is the lowest sequence number in any other segment. A record
/// older than `rec` can only exist elsewhere if `floor < rec.seq`.
fn compactRecord(db: *Db, id: u64, floor: u64, offset: u64, rec: record.Record) !void {
    switch (rec.kind) {
        .put, .put_ttl => {
            if (db.index.getPtr(rec.key) == null) {
                // Live only in the cold index: bring it into memory so the
                // new location is recorded.
                const c = &(db.cold orelse return);
                const ce = (try c.get(rec.key)) orelse return;
                if (ce.segment != id or ce.offset != offset) return;
                try db.faultIn(rec.key);
            }
            const e = db.index.getPtr(rec.key).?;
            if (e.deleted or e.segment != id or e.offset != offset) return;
            if (e.expiredAt(db.now()) and floor >= rec.seq and !e.in_cold) {
                // Nothing older can resurface, so the expired record can go.
                db.releaseBytes(e.*);
                _ = db.index.remove(rec.key);
                return;
            }
            try db.reserveStats();
            const loc = try db.log.appendCopy(rec);
            // Move the live bytes too, so a failure part way through leaves
            // every segment's count right.
            db.releaseBytes(e.*);
            var moved = Entry.at(loc, rec);
            moved.in_cold = e.in_cold;
            db.noteAppended(loc, rec.seq, moved);
            e.* = moved;
        },
        .delete => {
            // A marker hiding a cold entry needs its tombstone kept, or the
            // cold entry would come back after a restart.
            const marker = db.index.getPtr(rec.key);
            const hides_cold = if (marker) |m| m.deleted and m.in_cold and m.seq == rec.seq else false;
            if (!hides_cold) {
                // A newer put already shadows anything older.
                if (try db.find(rec.key) != null) return;
                if (floor >= rec.seq) return;
            }
            try db.reserveStats();
            const loc = try db.log.appendCopy(rec);
            db.noteAppended(loc, rec.seq, null);
            if (hides_cold) marker.?.segment = @intCast(loc.segment);
        },
        else => return error.Corrupt,
    }
}

/// The lowest sequence number of any record outside segment `except`.
fn oldestSeqOutside(db: *const Db, except: u64) u64 {
    var floor: u64 = std.math.maxInt(u64);
    for (db.log.segments.items) |id| {
        if (id == except) continue;
        const st = db.seg_stats.get(id) orelse continue;
        floor = @min(floor, st.min_seq);
    }
    return floor;
}

// ----------------------------------------------------------- cold index

/// Moves the index entries for every sealed segment out of memory into the
/// cold index on disk, merging them with what it already holds. Returns
/// whether anything moved. Does nothing while a snapshot is open, since
/// version chains live only in memory. Blocks the `Db` while it runs: it
/// rewrites the whole cold index file.
pub fn spill(db: *Db) !bool {
    if (db.snapshots.items.len > 0) return false;
    const through = db.log.active_id - 1;
    if (through == 0) return false;
    // Rewriting the cold index is only worth it if something leaves memory.
    var movable: usize = 0;
    var scan = db.index.first();
    while (scan.valid()) : (scan.next()) {
        if (scan.valuePtr().segment <= through) movable += 1;
    }
    if (movable == 0) return false;
    const gpa = db.gpa;
    const io = db.log.io;
    const now_s = db.now();

    var survivors = try Index.init(gpa);
    var survivors_owned = true;
    defer if (survivors_owned) survivors.deinit();
    survivors.bulk = true;

    const old_entries: usize = if (db.cold) |c| @intCast(c.entries) else 0;
    var w = try coldfile.Writer.init(gpa, io, db.log.dir, old_entries + db.index.len());
    defer w.deinit();

    // Expired entries dropped from the cold index stop counting as live.
    var expired: std.ArrayList(Entry) = .empty;
    defer expired.deinit(gpa);

    var mem = db.index.first();
    var cc: ?coldfile.Reader.Cursor = if (db.cold) |*c| c.first() else null;
    while (true) {
        const mk: ?[]const u8 = if (mem.valid()) mem.key() else null;
        const ci: ?coldfile.Reader.Item = if (cc) |*c| try c.current() else null;
        if (mk == null and ci == null) break;
        const ord: std.math.Order = if (mk == null) .gt else if (ci == null) .lt else std.mem.order(u8, mk.?, ci.?.key);
        if (ord == .gt) {
            // Only the cold index has this key.
            const e = Entry.fromCold(ci.?.entry);
            if (e.expiredAt(now_s)) try expired.append(gpa, e) else try w.add(ci.?.key, ci.?.entry);
            try cc.?.next();
            continue;
        }
        const e = mem.valuePtr().*;
        if (e.segment <= through) {
            // Covered: the in-memory entry replaces the cold one.
            if (!e.deleted) {
                if (e.expiredAt(now_s)) try expired.append(gpa, e) else try w.add(mk.?, e.toCold());
            }
        } else {
            // Stays in memory; keep the cold entry it shadows, if any.
            if (ord == .eq) try w.add(ci.?.key, ci.?.entry);
            const slot = try survivors.getOrPut(mk.?);
            slot.value_ptr.* = e;
            slot.value_ptr.in_cold = ord == .eq;
        }
        mem.next();
        if (ord == .eq) try cc.?.next();
    }

    // Stats for the covered segments, adjusted for what was dropped.
    var stats: std.ArrayList(coldfile.SegStat) = .empty;
    defer stats.deinit(gpa);
    for (db.log.segments.items) |id| {
        if (id > through) continue;
        var st = db.seg_stats.get(id) orelse SegStat{};
        for (expired.items) |e| if (e.segment == id) {
            st.live -|= e.len;
            if (e.expires != 0) st.ttl_live -|= e.len;
        };
        try stats.append(gpa, .{ .id = id, .live = st.live, .min_seq = st.min_seq, .ttl_live = st.ttl_live, .max_expiry = st.max_expiry });
    }
    try survivors.finishBulk();
    try w.finish(through, db.log.last_seq, stats.items);

    // The new file is in place. If it can't be opened, the old reader and
    // full in-memory index still describe the same data.
    const reader = (try coldfile.Reader.open(gpa, io, db.log.dir)) orelse return error.Corrupt;
    for (expired.items) |e| db.releaseBytes(e);
    if (db.cold) |*c| c.close();
    db.cold = reader;
    db.index.deinit();
    db.index = survivors;
    survivors_owned = false;
    db.tombstone_entries = 0;
    db.cold_shadowed = 0;
    var cur = db.index.first();
    while (cur.valid()) : (cur.next()) {
        const e = cur.valuePtr();
        if (e.deleted) db.tombstone_entries += 1;
        if (e.in_cold) db.cold_shadowed += 1;
    }
    db.merges += 1;
    return true;
}

// ------------------------------------------------------------ iteration

pub const Range = struct {
    /// Inclusive lower bound. Empty means the first key.
    start: []const u8 = "",
    /// Exclusive upper bound. Null means no upper bound.
    end: ?[]const u8 = null,
    reverse: bool = false,
};

pub const Pair = struct { key: []const u8, value: []const u8 };

/// Walks keys in order (or reverse order), merging memory with the cold
/// index. Keys and values returned by `next` are valid until the next
/// call. Do not write to the `Db` while an iterator is in use.
pub const Iterator = struct {
    db: *Db,
    cursor: Index.Cursor,
    cold: ?coldfile.Reader.Cursor = null,
    range: Range,
    /// Snapshot sequence to read at, or null for the live state.
    at: ?u64 = null,
    /// Unix seconds used to hide expired values.
    now_s: u64,
    /// Scratch space for values read from files. Null uses the `Db`'s own,
    /// which makes the iterator unsafe to share across threads.
    buf: ?*std.ArrayList(u8) = null,
    buf_gpa: Allocator = undefined,

    const Hit = struct { key: []const u8, entry: Entry };

    fn inRange(it: *const Iterator, key: []const u8) bool {
        if (it.range.reverse) return std.mem.order(u8, key, it.range.start) != .lt;
        if (it.range.end) |end| return std.mem.order(u8, key, end) == .lt;
        return true;
    }

    fn memKey(it: *Iterator) ?[]const u8 {
        if (!it.cursor.valid()) return null;
        const key = it.cursor.key();
        if (!it.inRange(key)) {
            it.cursor.invalidate();
            return null;
        }
        return key;
    }

    fn coldItem(it: *Iterator) !?coldfile.Reader.Item {
        const c = &(it.cold orelse return null);
        const item = (try c.current()) orelse return null;
        if (!it.inRange(item.key)) {
            it.cold = null;
            return null;
        }
        return item;
    }

    fn stepMem(it: *Iterator) void {
        if (it.range.reverse) it.cursor.prev() else it.cursor.next();
    }

    fn stepCold(it: *Iterator) !void {
        const c = &(it.cold orelse return);
        if (it.range.reverse) try c.prev() else try c.next();
    }

    /// Advances to the next visible key and returns it with its version.
    fn advance(it: *Iterator) !?Hit {
        while (true) {
            const mk = it.memKey();
            const ci = try it.coldItem();
            if (mk == null and ci == null) return null;
            // Pick the key that comes first in walking order; on a tie the
            // in-memory entry wins and the cold one is skipped.
            const use_mem = if (mk == null) false else if (ci == null) true else blk: {
                const ord = std.mem.order(u8, mk.?, ci.?.key);
                if (ord == .eq) break :blk true;
                break :blk (ord == .lt) != it.range.reverse;
            };
            if (use_mem) {
                if (ci) |c| if (std.mem.eql(u8, c.key, mk.?)) try it.stepCold();
                const e = it.cursor.valuePtr();
                it.stepMem();
                const v: ?*const Entry = if (it.at) |seq|
                    e.resolve(seq, it.now_s)
                else if (e.deleted or e.expiredAt(it.now_s)) null else e;
                if (v) |found| return .{ .key = mk.?, .entry = found.* };
            } else {
                const item = ci.?;
                try it.stepCold();
                const e = Entry.fromCold(item.entry);
                const visible = !e.expiredAt(it.now_s) and (if (it.at) |seq| e.seq <= seq else true);
                if (visible) return .{ .key = item.key, .entry = e };
            }
        }
    }

    pub fn next(it: *Iterator) !?Pair {
        const hit = (try it.advance()) orelse return null;
        const value = if (it.buf) |b|
            try it.db.readValueInto(it.buf_gpa, hit.key, hit.entry, b)
        else
            try it.db.readValue(hit.key, hit.entry);
        return .{ .key = hit.key, .value = value };
    }

    /// Like `next` but skips reading the value.
    pub fn nextKey(it: *Iterator) !?[]const u8 {
        const hit = (try it.advance()) orelse return null;
        return hit.key;
    }

    /// The key `nextKey` would return, without moving.
    pub fn peekKey(it: *const Iterator) !?[]const u8 {
        var copy = it.*;
        return copy.nextKey();
    }
};

/// Iterates `range`. Fails only if the cold index is damaged.
pub fn iterator(db: *Db, range: Range) !Iterator {
    const cursor = if (range.reverse)
        (if (range.end) |end| db.index.seekBefore(end) else db.index.last())
    else
        db.index.seek(range.start);
    var it: Iterator = .{ .db = db, .cursor = cursor, .range = range, .now_s = db.now() };
    if (db.cold) |*c| {
        it.cold = if (range.reverse)
            (if (range.end) |end| try c.seekBefore(end) else try c.last())
        else
            try c.seek(range.start);
    }
    return it;
}

/// Iterates `range` as of `snap`.
pub fn iteratorAt(db: *Db, snap: Snapshot, range: Range) !Iterator {
    var it = try db.iterator(range);
    it.at = snap.seq;
    return it;
}

/// Iterates the keys that start with `prefix`. `buf` must outlive the
/// iterator and be at least `prefix.len` bytes.
pub fn prefixIterator(db: *Db, prefix: []const u8, reverse: bool, buf: []u8) !Iterator {
    return try db.iterator(prefixRange(prefix, reverse, buf));
}

pub fn prefixRange(prefix: []const u8, reverse: bool, buf: []u8) Range {
    return .{ .start = prefix, .end = ordered.prefixEnd(prefix, buf), .reverse = reverse };
}

/// Returns up to `n` entries with the greatest keys under `prefix`, newest
/// key first. With keys like `agent/<id>/<timestamp>` this is "the latest
/// n memories". Everything returned is owned by the caller; free it with
/// `freePairs`.
pub fn latest(db: *Db, gpa: Allocator, prefix: []const u8, n: usize) ![]Pair {
    const end_buf = try gpa.alloc(u8, prefix.len);
    defer gpa.free(end_buf);
    var it = try db.prefixIterator(prefix, true, end_buf);
    return collect(gpa, &it, n);
}

/// Copies up to `limit` pairs out of an iterator.
pub fn collect(gpa: Allocator, it: *Iterator, limit: usize) ![]Pair {
    var out: std.ArrayList(Pair) = .empty;
    errdefer {
        for (out.items) |p| {
            gpa.free(p.key);
            gpa.free(p.value);
        }
        out.deinit(gpa);
    }
    while (out.items.len < limit) {
        const p = (try it.next()) orelse break;
        const key = try gpa.dupe(u8, p.key);
        errdefer gpa.free(key);
        const value = try gpa.dupe(u8, p.value);
        errdefer gpa.free(value);
        try out.append(gpa, .{ .key = key, .value = value });
    }
    return out.toOwnedSlice(gpa);
}

pub fn freePairs(gpa: Allocator, pairs: []const Pair) void {
    for (pairs) |p| {
        gpa.free(p.key);
        gpa.free(p.value);
    }
    gpa.free(pairs);
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "put, get, delete and reopen" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        var db = try Db.open(testing.allocator, io, tmp.dir, "db", .{});
        defer db.close();
        try db.put("a", "1");
        try db.put("b", "2");
        try db.put("a", "one");
        try testing.expect(try db.delete("b"));
        try testing.expect(!try db.delete("b"));
        try db.put("c", "3");
        try testing.expectEqualStrings("one", (try db.getView("a")).?);
        try testing.expect((try db.getView("b")) == null);
        try db.sync();
    }
    var db = try Db.open(testing.allocator, io, tmp.dir, "db", .{});
    defer db.close();
    try testing.expectEqual(@as(usize, 2), db.count());
    const v = (try db.get(testing.allocator, "a")).?;
    defer testing.allocator.free(v);
    try testing.expectEqualStrings("one", v);
    try testing.expect(!try db.contains("b"));
    try testing.expectEqualStrings("3", (try db.getView("c")).?);
    try testing.expectEqual(@as(u64, 5), db.lastSeq());
}

test "range, reverse and prefix iteration" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Db.open(testing.allocator, io, tmp.dir, "db", .{});
    defer db.close();

    for ([_][]const u8{ "a/1", "a/2", "a/3", "b/1", "b/2", "c" }) |k| try db.put(k, k);

    var buf: [8]u8 = undefined;
    var it = try db.prefixIterator("a/", false, &buf);
    try testing.expectEqualStrings("a/1", (try it.next()).?.key);
    try testing.expectEqualStrings("a/2", (try it.next()).?.key);
    const third = (try it.next()).?;
    try testing.expectEqualStrings("a/3", third.value);
    try testing.expect((try it.next()) == null);

    it = try db.prefixIterator("b/", true, &buf);
    try testing.expectEqualStrings("b/2", (try it.nextKey()).?);
    try testing.expectEqualStrings("b/1", (try it.nextKey()).?);
    try testing.expect(try it.nextKey() == null);

    it = try db.iterator(.{ .start = "a/2", .end = "b/2" });
    var n: usize = 0;
    while (try it.nextKey()) |_| n += 1;
    try testing.expectEqual(@as(usize, 3), n);

    it = try db.iterator(.{ .reverse = true });
    try testing.expectEqualStrings("c", (try it.nextKey()).?);
}

test "latest returns newest keys under a prefix" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Db.open(testing.allocator, io, tmp.dir, "db", .{});
    defer db.close();

    var kb: [32]u8 = undefined;
    for (0..50) |i| try db.put(try std.fmt.bufPrint(&kb, "agent/7/{d:0>8}", .{i}), "m");
    try db.put("agent/8/00000001", "other agent");

    const got = try db.latest(testing.allocator, "agent/7/", 3);
    defer freePairs(testing.allocator, got);
    try testing.expectEqual(@as(usize, 3), got.len);
    try testing.expectEqualStrings("agent/7/00000049", got[0].key);
    try testing.expectEqualStrings("agent/7/00000047", got[2].key);
}

test "invalid input is rejected without side effects" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Db.open(testing.allocator, io, tmp.dir, "db", .{});
    defer db.close();
    try testing.expectError(error.EmptyKey, db.put("", "x"));
    try testing.expectEqual(@as(usize, 0), db.count());
    try testing.expectEqual(@as(u64, 0), db.lastSeq());
}

test "compaction reclaims overwritten and deleted space and survives reopen" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const opts: Options = .{ .sync_writes = false, .auto_compact = false, .log = .{ .segment_bytes = 4096 } };

    var kb: [16]u8 = undefined;
    {
        var db = try Db.open(testing.allocator, io, tmp.dir, "db", opts);
        defer db.close();
        // 100 keys, each overwritten 10 times, then delete half.
        for (0..10) |round| {
            for (0..100) |k| {
                var vb: [32]u8 = undefined;
                try db.put(try std.fmt.bufPrint(&kb, "key{d:0>3}", .{k}), try std.fmt.bufPrint(&vb, "value-{d}-{d}", .{ k, round }));
            }
        }
        for (0..50) |k| _ = try db.delete(try std.fmt.bufPrint(&kb, "key{d:0>3}", .{k * 2}));

        const before = db.spaceStats();
        const n = try db.compactWithRatio(0);
        try testing.expect(n > 0);
        const after = db.spaceStats();
        try testing.expect(after.total_bytes < before.total_bytes / 3);
        try testing.expectEqual(before.live_bytes, after.live_bytes);
        try testing.expectEqual(@as(usize, 50), db.count());
        try testing.expectEqualStrings("value-1-9", (try db.getView("key001")).?);
        try testing.expect((try db.getView("key000")) == null);
        try db.sync();
    }

    var db = try Db.open(testing.allocator, io, tmp.dir, "db", opts);
    defer db.close();
    try testing.expectEqual(@as(usize, 50), db.count());
    try testing.expect((try db.getView("key002")) == null);
    try testing.expectEqualStrings("value-99-9", (try db.getView("key099")).?);
    // Writes after reopen get sequence numbers above every copied record.
    try db.put("key000", "back");
    try testing.expectEqualStrings("back", (try db.getView("key000")).?);
}

test "auto compaction keeps disk use bounded under overwrites" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Db.open(testing.allocator, io, tmp.dir, "db", .{ .sync_writes = false, .log = .{ .segment_bytes = 8192 } });
    defer db.close();
    var kb: [16]u8 = undefined;
    for (0..20_000) |i| try db.put(try std.fmt.bufPrint(&kb, "k{d}", .{i % 50}), "0123456789012345678901234567890123456789");
    try testing.expect(db.compactions > 0);
    try testing.expect(db.spaceStats().total_bytes < 64 * 1024);
    try testing.expectEqual(@as(usize, 50), db.count());
}

test "snapshots see the past while writes continue" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Db.open(testing.allocator, io, tmp.dir, "db", .{ .sync_writes = false });
    defer db.close();

    try db.put("a", "a1");
    try db.put("b", "b1");
    const snap = try db.snapshot();
    try db.put("a", "a2");
    _ = try db.delete("b");
    try db.put("c", "c1");
    try db.put("a", "a3");

    try testing.expectEqualStrings("a1", (try db.getAt(snap, "a")).?);
    try testing.expectEqualStrings("b1", (try db.getAt(snap, "b")).?);
    try testing.expect((try db.getAt(snap, "c")) == null);
    try testing.expectEqualStrings("a3", (try db.getView("a")).?);
    try testing.expect((try db.getView("b")) == null);
    try testing.expectEqual(@as(usize, 2), db.count());

    var it = try db.iteratorAt(snap, .{});
    try testing.expectEqualStrings("a", (try it.next()).?.key);
    const b = (try it.next()).?;
    try testing.expectEqualStrings("b1", b.value);
    try testing.expect((try it.next()) == null);

    // Live iteration skips the deletion kept for the snapshot.
    it = try db.iterator(.{});
    try testing.expectEqualStrings("a", (try it.nextKey()).?);
    try testing.expectEqualStrings("c", (try it.nextKey()).?);
    try testing.expect(try it.nextKey() == null);

    try testing.expectEqual(@as(usize, 0), try db.compactWithRatio(0));
    db.release(snap);
    try testing.expectEqual(@as(usize, 0), db.retained_versions);
    try testing.expectEqual(@as(usize, 0), db.tombstone_entries);
    try testing.expectEqual(@as(usize, 2), db.index.len());
}

test "batches apply atomically and survive reopen" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        var db = try Db.open(testing.allocator, io, tmp.dir, "db", .{});
        defer db.close();
        try db.put("x", "0");
        try db.write(&.{
            .{ .put = .{ .key = "a", .value = "1" } },
            .{ .delete = "x" },
            .{ .put = .{ .key = "b", .value = "2" } },
            .{ .put = .{ .key = "a", .value = "1b" } },
            .{ .delete = "missing" },
        });
        try testing.expectEqual(@as(usize, 2), db.count());
        try testing.expectEqualStrings("1b", (try db.getView("a")).?);
    }
    var db = try Db.open(testing.allocator, io, tmp.dir, "db", .{});
    defer db.close();
    try testing.expectEqual(@as(usize, 2), db.count());
    try testing.expectEqualStrings("1b", (try db.getView("a")).?);
    try testing.expectEqualStrings("2", (try db.getView("b")).?);
    try testing.expect(!try db.contains("x"));
    // Batched records compact like any others.
    try db.put("a", "again");
    _ = try db.compactWithRatio(0);
    try testing.expectEqualStrings("2", (try db.getView("b")).?);
}

test "batch delete then put of a new key" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Db.open(testing.allocator, io, tmp.dir, "db", .{ .sync_writes = false });
    defer db.close();
    const snap = try db.snapshot();
    try db.write(&.{ .{ .delete = "k" }, .{ .put = .{ .key = "k", .value = "v" } } });
    try testing.expectEqualStrings("v", (try db.getView("k")).?);
    try testing.expectEqual(@as(usize, 1), db.count());
    try testing.expect((try db.getAt(snap, "k")) == null);
    db.release(snap);
    try testing.expectEqual(@as(usize, 1), db.count());
}

test "putIf enforces compare-and-swap" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Db.open(testing.allocator, io, tmp.dir, "db", .{ .sync_writes = false });
    defer db.close();
    try db.putIf("k", "v1", .absent);
    try testing.expectError(error.Conflict, db.putIf("k", "v2", .absent));
    const s = (try db.seqOf("k")).?;
    try db.putIf("k", "v2", .{ .seq = s });
    try testing.expectError(error.Conflict, db.putIf("k", "v3", .{ .seq = s }));
    try testing.expectEqualStrings("v2", (try db.getView("k")).?);
}

test "ttl values expire and compaction drops them" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const opts: Options = .{ .sync_writes = false, .auto_compact = false };
    {
        var db = try Db.open(testing.allocator, io, tmp.dir, "db", opts);
        defer db.close();
        db.clock_override = 1000;
        try db.putTtl("short", "s", 10);
        try db.putTtl("long", "l", 1000);
        try db.put("forever", "f");
        try db.write(&.{.{ .put = .{ .key = "batched", .value = "b", .ttl = 10 } }});
        try testing.expectEqualStrings("s", (try db.getView("short")).?);

        db.clock_override = 1010;
        try testing.expect((try db.getView("short")) == null);
        try testing.expect((try db.getView("batched")) == null);
        try testing.expectEqualStrings("l", (try db.getView("long")).?);
        var it = try db.iterator(.{});
        try testing.expectEqualStrings("forever", (try it.nextKey()).?);
        try testing.expectEqualStrings("long", (try it.nextKey()).?);
        try testing.expect(try it.nextKey() == null);
        try db.putIf("short", "again", .absent);
        try db.sync();
    }
    var db = try Db.open(testing.allocator, io, tmp.dir, "db", opts);
    defer db.close();
    db.clock_override = 1010;
    try testing.expectEqualStrings("again", (try db.getView("short")).?);
    try testing.expect((try db.getView("batched")) == null);
    try testing.expectEqualStrings("l", (try db.getView("long")).?);

    // Force the old segment to be sealed, then compact: "batched" is gone.
    db.log.options.segment_bytes = 1;
    try db.put("x", "y");
    _ = try db.compactWithRatio(0);
    try testing.expect(db.index.getPtr("batched") == null);
    try testing.expectEqualStrings("l", (try db.getView("long")).?);
}

test "deletePrefix forgets one agent" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Db.open(testing.allocator, io, tmp.dir, "db", .{ .sync_writes = false });
    defer db.close();
    var kb: [32]u8 = undefined;
    for (0..25_000) |i| try db.put(try std.fmt.bufPrint(&kb, "agent/1/{d}", .{i}), "m");
    for (0..10) |i| try db.put(try std.fmt.bufPrint(&kb, "agent/2/{d}", .{i}), "m");
    try testing.expectEqual(@as(usize, 25_000), try db.deletePrefix("agent/1/"));
    try testing.expectEqual(@as(usize, 10), db.count());
    try testing.expectEqual(@as(usize, 0), try db.deletePrefix("agent/1/"));
}

test "a batch that fails part way changes nothing" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const ops = [_]Op{
        .{ .put = .{ .key = "a", .value = "1" } },
        .{ .delete = "x" },
        .{ .put = .{ .key = "x", .value = "x2" } },
        .{ .delete = "missing" },
        .{ .put = .{ .key = "missing", .value = "m" } },
        .{ .put = .{ .key = "k", .value = "kv" } },
        .{ .delete = "k" },
    };
    var fail_at: usize = 0;
    while (true) : (fail_at += 1) {
        var fa = std.testing.FailingAllocator.init(testing.allocator, .{});
        var name_buf: [16]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "db{d}", .{fail_at});
        var db = try Db.open(fa.allocator(), io, tmp.dir, name, .{ .sync_writes = false });
        defer db.close();
        try db.put("x", "x1");
        const snap = try db.snapshot();
        defer db.release(snap);
        fa.fail_index = fa.alloc_index + fail_at;
        if (db.write(&ops)) |_| {
            fa.fail_index = std.math.maxInt(usize);
            try testing.expectEqualStrings("1", (try db.getView("a")).?);
            try testing.expectEqualStrings("x2", (try db.getView("x")).?);
            try testing.expectEqualStrings("m", (try db.getView("missing")).?);
            try testing.expect(!try db.contains("k"));
            try testing.expectEqual(@as(usize, 3), db.count());
            try testing.expectEqualStrings("x1", (try db.getAt(snap, "x")).?);
            break;
        } else |err| {
            fa.fail_index = std.math.maxInt(usize);
            try testing.expectEqual(error.OutOfMemory, err);
            try testing.expect(!try db.contains("a"));
            try testing.expectEqualStrings("x1", (try db.getView("x")).?);
            try testing.expect(!try db.contains("missing"));
            try testing.expectEqual(@as(usize, 1), db.count());
            try testing.expect(!db.log.poisoned);
        }
    }
}

test "segments holding only expired values get compacted" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Db.open(testing.allocator, io, tmp.dir, "db", .{
        .sync_writes = false,
        .auto_compact = false,
        .log = .{ .segment_bytes = 4096 },
    });
    defer db.close();
    db.clock_override = 1000;
    var kb: [16]u8 = undefined;
    for (0..500) |i| try db.putTtl(try std.fmt.bufPrint(&kb, "t{d:0>4}", .{i}), "value", 10);
    try db.put("keep", "k");
    try testing.expect(db.log.segments.items.len > 2);
    // Nothing has expired yet, so nothing is dead.
    try testing.expectEqual(@as(usize, 0), try db.compact());
    db.clock_override = 2000;
    try testing.expect(try db.compact() > 0);
    try testing.expect(db.index.getPtr("t0000") == null);
    try testing.expectEqualStrings("k", (try db.getView("keep")).?);
}

test "compaction rewrites batches that are still live" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const opts: Options = .{ .sync_writes = false, .auto_compact = false, .log = .{ .segment_bytes = 256 } };
    {
        var db = try Db.open(testing.allocator, io, tmp.dir, "db", opts);
        defer db.close();
        try db.write(&.{
            .{ .put = .{ .key = "a", .value = "1" } },
            .{ .put = .{ .key = "b", .value = "2" } },
            .{ .put = .{ .key = "c", .value = "3", .ttl = 1000 } },
        });
        const batch_segment = db.log.active_id;
        try db.put("a", "overwritten");
        // Fill until the batch's segment is sealed.
        while (db.log.active_id == batch_segment) try db.put("pad", "................................");
        try testing.expect(try db.compactWithRatio(0) > 0);
        try testing.expect(db.seg_stats.get(batch_segment) == null);
        try db.sync();
    }
    var db = try Db.open(testing.allocator, io, tmp.dir, "db", opts);
    defer db.close();
    try testing.expectEqualStrings("overwritten", (try db.getView("a")).?);
    try testing.expectEqualStrings("2", (try db.getView("b")).?);
    try testing.expectEqualStrings("3", (try db.getView("c")).?);
}

test "deletePrefix splits huge keys into batches that fit" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Db.open(testing.allocator, io, tmp.dir, "db", .{ .sync_writes = false, .auto_compact = false });
    defer db.close();
    var key: [2000]u8 = @splat('k');
    @memcpy(key[0..2], "p/");
    for (0..9000) |i| {
        _ = std.fmt.bufPrint(key[2..12], "{d:0>10}", .{i}) catch unreachable;
        try db.put(&key, "v");
    }
    try testing.expectEqual(@as(usize, 9000), try db.deletePrefix("p/"));
    try testing.expectEqual(@as(usize, 0), db.count());
}

test "segment sizes over 4 GiB are refused" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try testing.expectError(error.SegmentTooLarge, Db.open(testing.allocator, io, tmp.dir, "db", .{ .log = .{ .segment_bytes = 8 << 30 } }));
}

// ------------------------------------------------------ cold index tests

/// A reference model: key -> value, compared against the database.
const Model = struct {
    map: std.StringHashMapUnmanaged([]u8) = .empty,

    fn deinit(m: *Model) void {
        var it = m.map.iterator();
        while (it.next()) |e| {
            testing.allocator.free(e.key_ptr.*);
            testing.allocator.free(e.value_ptr.*);
        }
        m.map.deinit(testing.allocator);
    }

    fn put(m: *Model, k: []const u8, v: []const u8) !void {
        const gop = try m.map.getOrPut(testing.allocator, k);
        if (gop.found_existing) {
            testing.allocator.free(gop.value_ptr.*);
        } else gop.key_ptr.* = try testing.allocator.dupe(u8, k);
        gop.value_ptr.* = try testing.allocator.dupe(u8, v);
    }

    fn delete(m: *Model, k: []const u8) bool {
        const kv = m.map.fetchRemove(k) orelse return false;
        testing.allocator.free(kv.key);
        testing.allocator.free(kv.value);
        return true;
    }

    fn sortedKeys(m: *const Model) ![][]const u8 {
        const keys = try testing.allocator.alloc([]const u8, m.map.count());
        var it = m.map.keyIterator();
        var i: usize = 0;
        while (it.next()) |k| : (i += 1) keys[i] = k.*;
        std.mem.sortUnstable([]const u8, keys, {}, struct {
            fn lt(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.lt);
        return keys;
    }

    fn check(m: *const Model, db: *Db) !void {
        try testing.expectEqual(m.map.count(), db.count());
        var it = m.map.iterator();
        while (it.next()) |e| {
            const v = (try db.getView(e.key_ptr.*)) orelse {
                std.debug.print("missing {s}\n", .{e.key_ptr.*});
                return error.TestUnexpectedResult;
            };
            try testing.expectEqualStrings(e.value_ptr.*, v);
        }
        const keys = try m.sortedKeys();
        defer testing.allocator.free(keys);
        var fwd = try db.iterator(.{});
        for (keys) |k| {
            const p = (try fwd.next()).?;
            try testing.expectEqualStrings(k, p.key);
            try testing.expectEqualStrings(m.map.get(k).?, p.value);
        }
        try testing.expect(try fwd.next() == null);
        var rev = try db.iterator(.{ .reverse = true });
        var i = keys.len;
        while (i > 0) {
            i -= 1;
            try testing.expectEqualStrings(keys[i], (try rev.nextKey()).?);
        }
        try testing.expect(try rev.nextKey() == null);
    }
};

fn modelKey(buf: []u8, i: u64) []const u8 {
    return std.fmt.bufPrint(buf, "agent/{d}/m{d:0>5}", .{ i % 5, i }) catch unreachable;
}

test "the cold index keeps every key readable as memory is capped" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const opts: Options = .{
        .sync_writes = false,
        .memory_budget = 1,
        .compact_dead_ratio = 0.5,
        .log = .{ .segment_bytes = 4096 },
    };
    var model: Model = .{};
    defer model.deinit();
    var prng = std.Random.DefaultPrng.init(42);
    const rand = prng.random();
    var kbuf: [32]u8 = undefined;
    var vbuf: [64]u8 = undefined;

    for (0..4) |round| {
        var db = try Db.open(testing.allocator, io, tmp.dir, "db", opts);
        defer db.close();
        try model.check(&db);
        for (0..1500) |_| {
            const k = modelKey(&kbuf, rand.uintLessThan(u64, 1200));
            switch (rand.uintLessThan(u8, 10)) {
                0, 1 => {
                    const existed = try db.delete(k);
                    try testing.expectEqual(model.delete(k), existed);
                },
                2 => {
                    // A batch that deletes and rewrites keys, some of them cold.
                    const k2 = try testing.allocator.dupe(u8, modelKey(&kbuf, rand.uintLessThan(u64, 1200)));
                    defer testing.allocator.free(k2);
                    const k1 = try testing.allocator.dupe(u8, modelKey(&kbuf, rand.uintLessThan(u64, 1200)));
                    defer testing.allocator.free(k1);
                    try db.write(&.{ .{ .delete = k1 }, .{ .put = .{ .key = k2, .value = "batched" } }, .{ .delete = k2 }, .{ .put = .{ .key = k1, .value = "again" } } });
                    _ = model.delete(k2);
                    try model.put(k1, "again");
                },
                else => {
                    const v = std.fmt.bufPrint(&vbuf, "value {d} {d}", .{ round, rand.int(u32) }) catch unreachable;
                    try db.put(k, v);
                    try model.put(k, v);
                },
            }
            try testing.expectEqual(model.map.count(), db.count());
        }
        try model.check(&db);
        try testing.expect(db.merges > 0);
        // Most keys live on disk, not in memory.
        try testing.expect(db.index.len() < model.map.count());
        _ = try db.compactWithRatio(0);
        try model.check(&db);
        if (round == 2) {
            try testing.expectEqual(@as(usize, model.map.count()), blk: {
                var n: usize = 0;
                var it = model.map.keyIterator();
                while (it.next()) |k| {
                    if (std.mem.startsWith(u8, k.*, "agent/3/")) n += 1;
                }
                const removed = try db.deletePrefix("agent/3/");
                try testing.expectEqual(n, removed);
                break :blk model.map.count();
            });
            var dead: std.ArrayList([]const u8) = .empty;
            defer dead.deinit(testing.allocator);
            var it = model.map.keyIterator();
            while (it.next()) |k| if (std.mem.startsWith(u8, k.*, "agent/3/")) try dead.append(testing.allocator, k.*);
            for (dead.items) |k| _ = model.delete(k);
            try model.check(&db);
        }
    }
}

test "snapshots read cold keys and hold back merges" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Db.open(testing.allocator, io, tmp.dir, "db", .{ .sync_writes = false, .auto_compact = false, .log = .{ .segment_bytes = 256 } });
    defer db.close();
    var kbuf: [32]u8 = undefined;
    for (0..50) |i| try db.put(modelKey(&kbuf, i), "old");
    try testing.expect(try db.spill());
    try testing.expect(db.cold != null);
    const snap = try db.snapshot();
    try testing.expect(!try db.spill());
    try db.put(modelKey(&kbuf, 1), "new");
    try testing.expect(try db.delete(modelKey(&kbuf, 2)));
    try testing.expectEqualStrings("old", (try db.getAt(snap, modelKey(&kbuf, 1))).?);
    try testing.expectEqualStrings("old", (try db.getAt(snap, modelKey(&kbuf, 2))).?);
    try testing.expectEqualStrings("old", (try db.getAt(snap, modelKey(&kbuf, 3))).?);
    try testing.expectEqualStrings("new", (try db.getView(modelKey(&kbuf, 1))).?);
    try testing.expect(try db.getView(modelKey(&kbuf, 2)) == null);
    var it = try db.iteratorAt(snap, .{});
    var n: usize = 0;
    while (try it.next()) |p| : (n += 1) try testing.expectEqualStrings("old", p.value);
    try testing.expectEqual(@as(usize, 50), n);
    db.release(snap);
    try testing.expectEqual(@as(usize, 49), db.count());
    try db.put("z", "flush the active segment");
    for (0..20) |i| try db.put(modelKey(&kbuf, 100 + i), "pad");
    try testing.expect(try db.spill());
    try testing.expect(try db.getView(modelKey(&kbuf, 2)) == null);
    try testing.expectEqual(@as(usize, 70), db.count());
}

test "expired cold entries are dropped by the next merge" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Db.open(testing.allocator, io, tmp.dir, "db", .{ .sync_writes = false, .auto_compact = false, .log = .{ .segment_bytes = 256 } });
    defer db.close();
    db.clock_override = 1000;
    var kbuf: [32]u8 = undefined;
    for (0..30) |i| try db.putTtl(modelKey(&kbuf, i), "brief", 10);
    for (30..60) |i| try db.put(modelKey(&kbuf, i), "kept");
    try testing.expect(try db.spill());
    try testing.expectEqual(@as(usize, 60), db.count());
    db.clock_override = 2000;
    try testing.expect(try db.getView(modelKey(&kbuf, 0)) == null);
    try db.put("z", "roll");
    for (0..10) |i| try db.put(modelKey(&kbuf, 200 + i), "pad");
    try testing.expect(try db.spill());
    try testing.expectEqual(@as(usize, 41), db.count());
    try testing.expectEqualStrings("kept", (try db.getView(modelKey(&kbuf, 59))).?);
}
