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
//! A `Db` is used from one thread at a time. See `Shared` for threads.

const Db = @This();

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const record = @import("record.zig");
const Log = @import("Log.zig");
const ordered = @import("index.zig");

pub const Options = struct {
    log: Log.Options = .{},
    /// Sync after every write so a successful `put` or `delete` is durable.
    /// Turn off to batch writes and call `sync` yourself.
    sync_writes: bool = true,
    /// Compact a sealed segment once at least this fraction of it is dead.
    compact_dead_ratio: f64 = 0.5,
    /// Check for segments to compact whenever the log starts a new segment.
    auto_compact: bool = true,
};

/// What the index stores per key: the newest version, plus older versions
/// that open snapshots can still see.
pub const Entry = struct {
    seq: u64,
    segment: u32,
    offset: u32,
    /// Record length; 0 for a deletion kept only for snapshots.
    len: u32,
    /// Unix seconds after which the value no longer counts; 0 for never.
    expires: u32 = 0,
    deleted: bool = false,
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
            .expires = @intCast(@min(rec.expires, std.math.maxInt(u32))),
        };
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

pub const Index = ordered.OrderedMap(Entry);

/// Per-segment bookkeeping for compaction.
const SegStat = struct {
    /// Bytes of records the index still points to.
    live: u64 = 0,
    /// Lowest sequence number of any record in the segment.
    min_seq: u64 = std.math.maxInt(u64),
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
/// Fixed clock for tests, in unix seconds.
clock_override: ?u64 = null,

pub fn open(gpa: Allocator, io: Io, parent: Io.Dir, sub_path: []const u8, options: Options) !Db {
    var idx = try Index.init(gpa);
    errdefer idx.deinit();
    var loader: Loader = .{ .gpa = gpa, .index = &idx };
    defer loader.deinit();
    var log = try Log.open(gpa, io, parent, sub_path, options.log, &loader);
    errdefer log.close();

    var db: Db = .{ .gpa = gpa, .options = options, .log = log, .index = idx, .seg_stats = loader.stats };
    loader.stats = .empty;
    errdefer db.seg_stats.deinit(gpa);
    // Live bytes come from what the index ended up pointing to.
    var c = db.index.first();
    while (c.valid()) : (c.next()) {
        const e = c.valuePtr().*;
        (try db.statFor(e.segment)).live += e.len;
    }
    return db;
}

pub fn close(db: *Db) void {
    db.freeAllVersions();
    db.snapshots.deinit(db.gpa);
    db.read_buf.deinit(db.gpa);
    db.seg_stats.deinit(db.gpa);
    db.index.deinit();
    db.log.close();
    db.* = undefined;
}

/// Rebuilds the index during open. The highest sequence number wins.
const Loader = struct {
    gpa: Allocator,
    index: *Index,
    /// Sequence of the newest tombstone seen per deleted key.
    dead: std.StringHashMapUnmanaged(u64) = .empty,
    stats: std.AutoHashMapUnmanaged(u64, SegStat) = .empty,

    fn deinit(l: *Loader) void {
        var it = l.dead.keyIterator();
        while (it.next()) |k| l.gpa.free(k.*);
        l.dead.deinit(l.gpa);
        l.stats.deinit(l.gpa);
    }

    pub fn onRecord(l: *Loader, loc: Log.Location, rec: record.Record) !void {
        const st = try l.stats.getOrPut(l.gpa, loc.segment);
        if (!st.found_existing) st.value_ptr.* = .{};
        st.value_ptr.min_seq = @min(st.value_ptr.min_seq, rec.seq);

        switch (rec.kind) {
            .put, .put_ttl => {
                if (l.dead.get(rec.key)) |dseq| if (dseq > rec.seq) return;
                const slot = try l.index.getOrPut(rec.key);
                if (slot.found_existing and slot.value_ptr.seq > rec.seq) return;
                slot.value_ptr.* = Entry.at(loc, rec);
            },
            .delete => {
                if (l.index.getPtr(rec.key)) |e| {
                    if (e.seq > rec.seq) return;
                    _ = l.index.remove(rec.key);
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
    if (db.seg_stats.getPtr(e.segment)) |st| st.live -|= e.len;
}

fn noteAppended(db: *Db, loc: Log.Location, seq: u64, live: bool) void {
    // Stats exist for every segment the log can append to: `reserveStats`
    // runs before each append.
    const st = db.seg_stats.getPtr(loc.segment).?;
    st.min_seq = @min(st.min_seq, seq);
    if (live) st.live += loc.len;
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

/// Number of keys in the index. Expired keys count until compaction or a
/// later write removes them.
pub fn count(db: *const Db) usize {
    return db.index.count - db.tombstone_entries;
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

/// The live entry for `key`, if any. Expired entries are not live.
pub fn lookup(db: *const Db, key: []const u8) ?*Entry {
    const e = db.index.getPtr(key) orelse return null;
    if (e.deleted) return null;
    if (e.expires != 0 and e.expiredAt(db.now())) return null;
    return e;
}

/// The sequence number of the live version of `key`, for `putIf`.
pub fn seqOf(db: *const Db, key: []const u8) ?u64 {
    return if (db.lookup(key)) |e| e.seq else null;
}

pub fn contains(db: *const Db, key: []const u8) bool {
    return db.lookup(key) != null;
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
    const current = db.seqOf(key);
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
    db.noteAppended(loc, rec.seq, true);

    var new = Entry.at(loc, rec);
    if (slot.found_existing) {
        const old = slot.value_ptr.*;
        db.releaseBytes(old);
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
    if (db.options.auto_compact and db.log.segments.items.len > segments_before) {
        _ = try db.compact();
    }
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
    db.noteAppended(loc, seq, false);
    db.applyDelete(key, e, seq, old_copy);
}

/// Updates the index for a delete already in the log.
fn applyDelete(db: *Db, key: []const u8, e: *Entry, seq: u64, old_copy: ?*Entry) void {
    db.releaseBytes(e.*);
    const older: ?*Entry = if (old_copy) |c| blk: {
        c.* = e.*;
        db.retained_versions += 1;
        break :blk c;
    } else e.older;
    if (older != null) {
        // Snapshots can still see this key; keep a deletion marker that
        // carries the history.
        e.* = .{ .seq = seq, .segment = 0, .offset = 0, .len = 0, .deleted = true, .older = older };
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

    try db.log.appendBatch(recs, locs);
    appended = true;

    for (ops, recs, locs) |op, rec, loc| switch (op) {
        .put => |p| {
            db.noteAppended(loc, rec.seq, true);
            const slot = db.index.getOrPut(p.key) catch |err| {
                // Only reachable when an earlier delete in this batch removed
                // the reserved slot. The log has the batch; stop accepting
                // writes so memory and disk can't drift apart.
                db.log.poisoned = true;
                return err;
            };
            var new = Entry.at(loc, rec);
            if (slot.found_existing) {
                const old = slot.value_ptr.*;
                const placeholder = old.seq == 0;
                db.releaseBytes(old);
                if (old.deleted) db.tombstone_entries -= 1;
                if (!placeholder and db.snapshotNeeds(old.seq) and spare.items.len > 0) {
                    const c = spare.pop().?;
                    c.* = old;
                    new.older = c;
                    db.retained_versions += 1;
                } else new.older = old.older;
            }
            slot.value_ptr.* = new;
        },
        .delete => |k| {
            db.noteAppended(loc, rec.seq, false);
            const e = db.index.getPtr(k) orelse continue;
            if (e.deleted) {
                if (e.seq == 0) {
                    // An unused placeholder from the reservation above.
                    db.tombstone_entries -= 1;
                    _ = db.index.remove(k);
                }
                continue;
            }
            const copy: ?*Entry = if (db.snapshotNeeds(e.seq) and spare.items.len > 0) spare.pop().? else null;
            db.applyDelete(k, e, rec.seq, copy);
        },
    };
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
        var it = db.prefixIterator(prefix, false, end_buf);
        while (keys.items.len < delete_prefix_chunk) {
            const k = it.nextKey() orelse break;
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
/// the next write or compaction.
pub fn getView(db: *Db, key: []const u8) !?[]const u8 {
    const e = db.lookup(key) orelse return null;
    return try db.readValue(e.*);
}

pub fn readValue(db: *Db, e: Entry) ![]const u8 {
    if (try db.log.view(e.location())) |rec| return rec.value;
    try db.read_buf.resize(db.gpa, e.len);
    const rec = try db.log.read(e.location(), db.read_buf.items);
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
    const e = db.index.getPtr(key) orelse return null;
    const v = e.resolve(snap.seq, db.now()) orelse return null;
    return try db.readValue(v.*);
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
        if (e.deleted) {
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
        const live = if (db.seg_stats.get(id)) |st| st.live else 0;
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
            const e = db.index.getPtr(rec.key) orelse return;
            if (e.deleted or e.segment != id or e.offset != offset) return;
            if (e.expiredAt(db.now()) and floor >= rec.seq) {
                // Nothing older can resurface, so the expired record can go.
                db.releaseBytes(e.*);
                _ = db.index.remove(rec.key);
                return;
            }
            try db.reserveStats();
            const loc = try db.log.appendCopy(rec);
            db.noteAppended(loc, rec.seq, true);
            e.* = Entry.at(loc, rec);
        },
        .delete => {
            // A newer put already shadows anything older.
            if (db.lookup(rec.key) != null) return;
            if (floor >= rec.seq) return;
            try db.reserveStats();
            const loc = try db.log.appendCopy(rec);
            db.noteAppended(loc, rec.seq, false);
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

// ------------------------------------------------------------ iteration

pub const Range = struct {
    /// Inclusive lower bound. Empty means the first key.
    start: []const u8 = "",
    /// Exclusive upper bound. Null means no upper bound.
    end: ?[]const u8 = null,
    reverse: bool = false,
};

pub const Pair = struct { key: []const u8, value: []const u8 };

/// Walks keys in order (or reverse order). Keys and values returned by
/// `next` are valid until the next call. Do not write to the `Db` while
/// an iterator is in use.
pub const Iterator = struct {
    db: *Db,
    cursor: Index.Cursor,
    range: Range,
    /// Snapshot sequence to read at, or null for the live state.
    at: ?u64 = null,
    /// Unix seconds used to hide expired values.
    now_s: u64,

    fn inRange(it: *const Iterator, key: []const u8) bool {
        if (it.range.reverse) return std.mem.order(u8, key, it.range.start) != .lt;
        if (it.range.end) |end| return std.mem.order(u8, key, end) == .lt;
        return true;
    }

    fn step(it: *Iterator) void {
        if (it.range.reverse) it.cursor.prev() else it.cursor.next();
    }

    /// Advances to the next visible key and returns it with its version.
    fn advance(it: *Iterator) ?struct { key: []const u8, entry: *const Entry } {
        while (it.cursor.valid()) {
            const key = it.cursor.key();
            if (!it.inRange(key)) {
                it.cursor.leaf = null;
                return null;
            }
            const e = it.cursor.valuePtr();
            it.step();
            const v: ?*const Entry = if (it.at) |seq|
                e.resolve(seq, it.now_s)
            else if (e.deleted or e.expiredAt(it.now_s)) null else e;
            if (v) |found| return .{ .key = key, .entry = found };
        }
        return null;
    }

    pub fn next(it: *Iterator) !?Pair {
        const hit = it.advance() orelse return null;
        return .{ .key = hit.key, .value = try it.db.readValue(hit.entry.*) };
    }

    /// Like `next` but skips reading the value.
    pub fn nextKey(it: *Iterator) ?[]const u8 {
        const hit = it.advance() orelse return null;
        return hit.key;
    }
};

pub fn iterator(db: *Db, range: Range) Iterator {
    const cursor = if (range.reverse)
        (if (range.end) |end| db.index.seekBefore(end) else db.index.last())
    else
        db.index.seek(range.start);
    return .{ .db = db, .cursor = cursor, .range = range, .now_s = db.now() };
}

/// Iterates `range` as of `snap`.
pub fn iteratorAt(db: *Db, snap: Snapshot, range: Range) Iterator {
    var it = db.iterator(range);
    it.at = snap.seq;
    return it;
}

/// Iterates the keys that start with `prefix`. `buf` must outlive the
/// iterator and be at least `prefix.len` bytes.
pub fn prefixIterator(db: *Db, prefix: []const u8, reverse: bool, buf: []u8) Iterator {
    return db.iterator(prefixRange(prefix, reverse, buf));
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
    var it = db.prefixIterator(prefix, true, end_buf);
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
    try testing.expect(!db.contains("b"));
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
    var it = db.prefixIterator("a/", false, &buf);
    try testing.expectEqualStrings("a/1", (try it.next()).?.key);
    try testing.expectEqualStrings("a/2", (try it.next()).?.key);
    const third = (try it.next()).?;
    try testing.expectEqualStrings("a/3", third.value);
    try testing.expect((try it.next()) == null);

    it = db.prefixIterator("b/", true, &buf);
    try testing.expectEqualStrings("b/2", it.nextKey().?);
    try testing.expectEqualStrings("b/1", it.nextKey().?);
    try testing.expect(it.nextKey() == null);

    it = db.iterator(.{ .start = "a/2", .end = "b/2" });
    var n: usize = 0;
    while (it.nextKey()) |_| n += 1;
    try testing.expectEqual(@as(usize, 3), n);

    it = db.iterator(.{ .reverse = true });
    try testing.expectEqualStrings("c", it.nextKey().?);
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

    var it = db.iteratorAt(snap, .{});
    try testing.expectEqualStrings("a", (try it.next()).?.key);
    const b = (try it.next()).?;
    try testing.expectEqualStrings("b1", b.value);
    try testing.expect((try it.next()) == null);

    // Live iteration skips the deletion kept for the snapshot.
    it = db.iterator(.{});
    try testing.expectEqualStrings("a", it.nextKey().?);
    try testing.expectEqualStrings("c", it.nextKey().?);
    try testing.expect(it.nextKey() == null);

    try testing.expectEqual(@as(usize, 0), try db.compactWithRatio(0));
    db.release(snap);
    try testing.expectEqual(@as(usize, 0), db.retained_versions);
    try testing.expectEqual(@as(usize, 0), db.tombstone_entries);
    try testing.expectEqual(@as(usize, 2), db.index.count);
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
    try testing.expect(!db.contains("x"));
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
    const s = db.seqOf("k").?;
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
        var it = db.iterator(.{});
        try testing.expectEqualStrings("forever", it.nextKey().?);
        try testing.expectEqualStrings("long", it.nextKey().?);
        try testing.expect(it.nextKey() == null);
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
