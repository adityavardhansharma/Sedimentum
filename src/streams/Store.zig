//! The stream stores: v2 and v3 (Lean).
//!
//! Both keep data per stream (a chat, an agent) instead of in one global
//! index, so RAM holds only chunk fences and bloom filters.
//!
//! v2: a write-ahead log plus 64 KB tails in RAM, plain 4 KB blocks, one
//!     lock with group commit.
//! v3: no write-ahead log; each stream's 16 KB tail lives in a page that is
//!     rewritten in place, keys are front-coded, blocks are LZ4 compressed,
//!     and streams are spread over one shard per core, each with its own
//!     lock, files and group commit.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const shard = @import("Shard.zig");

pub const Pair = shard.Pair;
pub const Range = shard.Range;
pub const streamName = shard.streamName;
pub const prefixEnd = shard.prefixEnd;

pub const Flavor = enum { v2, v3 };

pub const Options = struct {
    /// Every write is durable before it returns. Off: call `sync`.
    sync_writes: bool = true,
    /// v3 only: shard count for a new store. Null means one per CPU, at
    /// most 16. An existing store keeps the count it was created with.
    shards: ?usize = null,
};

pub const max_shards = 16;

/// Shards this thread wrote to since its last `sync`, per store handle.
/// A handle that finds no free slot falls back to syncing every shard.
const Touched = struct { owner: u64 = 0, mask: u32 = 0 };
threadlocal var touched: [8]Touched = @splat(.{});
/// Set for good once this thread finds no free slot. Kept per thread, so
/// another thread's sync can never consume it before this thread's write.
threadlocal var touched_overflow: bool = false;
var next_handle_id: std.atomic.Value(u64) = .init(1);

fn touchedSlot(id: u64, create: bool) ?*Touched {
    for (&touched) |*t| if (t.owner == id) return t;
    if (!create) return null;
    for (&touched) |*t| if (t.owner == 0) {
        t.* = .{ .owner = id };
        return t;
    };
    return null;
}

pub fn Store(comptime flavor: Flavor) type {
    const cfg: shard.Config = switch (flavor) {
        .v2 => .{
            .wal = true,
            .tail_limit = 64 * 1024,
            .fmt = .{ .block_bytes = 4096, .front_coding = false, .compress = false },
            .chunk_target = 64 * 1024,
        },
        .v3 => .{
            .wal = false,
            .tail_limit = 16 * 1024,
            .fmt = .{ .block_bytes = 8192, .front_coding = true, .compress = true },
            .chunk_target = 64 * 1024,
            // Per shard; one shard per core.
            .tail_budget = 4 * 1024 * 1024,
        },
    };
    return struct {
        const Self = @This();
        pub const Shard = shard.Shard(cfg);
        pub const config = cfg;

        /// One sequence number per shard.
        pub const Snapshot = struct { seqs: [max_shards]u64 = @splat(0) };

        gpa: Allocator,
        io: Io,
        shards: []*Shard,
        lock_file: Io.File,
        /// Unique per open handle; keys this handle's touched-shard bits.
        id: u64,

        pub fn open(gpa: Allocator, io: Io, parent: Io.Dir, sub_path: []const u8, options: Options) !*Self {
            var dir = try parent.createDirPathOpen(io, sub_path, .{});
            defer dir.close(io);
            // One process at a time, taken before reading or creating any
            // store-level file.
            const lock_file = dir.createFile(io, "LOCK", .{ .truncate = false, .lock = .exclusive, .lock_nonblocking = true }) catch |err| switch (err) {
                error.WouldBlock => return error.Locked,
                else => |e| return e,
            };
            errdefer lock_file.close(io);
            try checkFormat(io, dir);
            const n = try shardCount(io, dir, options);
            const self = try gpa.create(Self);
            errdefer gpa.destroy(self);
            const shards = try gpa.alloc(*Shard, n);
            errdefer gpa.free(shards);
            var opened: usize = 0;
            errdefer for (shards[0..opened]) |sh| sh.close();
            for (shards, 0..) |*sh, i| {
                var name_buf: [16]u8 = undefined;
                const name = std.fmt.bufPrint(&name_buf, "shard-{d}", .{i}) catch unreachable;
                sh.* = try Shard.open(gpa, io, dir, name, options.sync_writes);
                opened += 1;
            }
            self.* = .{ .gpa = gpa, .io = io, .shards = shards, .lock_file = lock_file, .id = next_handle_id.fetchAdd(1, .monotonic) };
            return self;
        }

        const format_text = switch (flavor) {
            .v2 => "v2\n",
            .v3 => "v3\n",
        };

        /// Refuses a directory made by the other engine before touching
        /// any of its files: v2 would cut off v3's pages as unowned space.
        fn checkFormat(io: Io, dir: Io.Dir) !void {
            if (try detectIn(io, dir)) |f| {
                if (f != flavor) return error.WrongEngine;
            }
            var buf: [8]u8 = undefined;
            _ = dir.readFile(io, "FORMAT", &buf) catch |err| switch (err) {
                error.FileNotFound => {
                    try writeFileAtomic(io, dir, "FORMAT", format_text);
                    return;
                },
                else => |e| return e,
            };
        }

        fn shardCount(io: Io, dir: Io.Dir, options: Options) !usize {
            var buf: [16]u8 = undefined;
            if (dir.readFile(io, "SHARDS", &buf)) |text| {
                const n = std.fmt.parseInt(usize, std.mem.trim(u8, text, " \n"), 10) catch return error.Corrupt;
                if (n == 0 or n > max_shards) return error.Corrupt;
                return n;
            } else |err| switch (err) {
                error.FileNotFound => {},
                else => |e| return e,
            }
            if (options.shards) |want| if (want == 0 or want > max_shards) return error.InvalidArgument;
            const n: usize = switch (flavor) {
                .v2 => 1,
                .v3 => options.shards orelse @max(1, @min(max_shards, std.Thread.getCpuCount() catch 4)),
            };
            const text = std.fmt.bufPrint(&buf, "{d}\n", .{n}) catch unreachable;
            try writeFileAtomic(io, dir, "SHARDS", text);
            return n;
        }

        pub fn close(self: *Self) void {
            for (self.shards) |sh| sh.close();
            if (touchedSlot(self.id, false)) |t| t.* = .{};
            self.lock_file.close(self.io);
            self.gpa.free(self.shards);
            self.gpa.destroy(self);
        }

        fn shardOf(self: *const Self, key: []const u8) *Shard {
            if (self.shards.len == 1) return self.shards[0];
            const h = std.hash.Wyhash.hash(0x5a, streamName(key));
            return self.shards[h % self.shards.len];
        }

        pub fn put(self: *Self, key: []const u8, value: []const u8) !void {
            const sh = self.shardOf(key);
            self.touch(sh);
            return sh.put(key, value);
        }

        pub fn delete(self: *Self, key: []const u8) !void {
            const sh = self.shardOf(key);
            self.touch(sh);
            return sh.delete(key);
        }

        /// Deletes every key under `prefix`. A prefix that covers whole
        /// streams (like `chat/42/`) drops them without reading anything.
        pub fn deletePrefix(self: *Self, prefix: []const u8) !void {
            for (self.shards) |sh| {
                if (try sh.deletePrefix(prefix)) self.touch(sh);
            }
        }

        pub fn get(self: *Self, gpa: Allocator, key: []const u8) !?[]u8 {
            return self.shardOf(key).get(gpa, key, std.math.maxInt(u64));
        }

        pub fn getAt(self: *Self, gpa: Allocator, snap: Snapshot, key: []const u8) !?[]u8 {
            const sh = self.shardOf(key);
            const i = std.mem.indexOfScalar(*Shard, self.shards, sh).?;
            return sh.get(gpa, key, snap.seqs[i]);
        }

        /// A point-in-time view across every shard: all shard locks are
        /// held while the sequence numbers are taken.
        pub fn snapshot(self: *Self) !Snapshot {
            for (self.shards) |sh| sh.lock.lockUncancelable(self.io);
            defer for (self.shards) |sh| sh.lock.unlock(self.io);
            var snap: Snapshot = .{};
            var taken: usize = 0;
            errdefer for (self.shards[0..taken]) |sh| sh.releaseLocked(sh.seq);
            for (self.shards, 0..) |sh, i| {
                try sh.snaps.append(self.gpa, sh.seq);
                snap.seqs[i] = sh.seq;
                taken += 1;
            }
            return snap;
        }

        pub fn release(self: *Self, snap: Snapshot) void {
            for (self.shards, 0..) |sh, i| sh.release(snap.seqs[i]);
        }

        /// Makes every write this thread made durable (on every shard it
        /// wrote to). Writes from other threads are covered by their own
        /// `sync`, or by `syncAll`.
        pub fn sync(self: *Self) !void {
            // This thread wrote through more handles than it can track:
            // every sync from it covers every shard from now on.
            if (touched_overflow) return self.syncAll();
            const t = touchedSlot(self.id, false) orelse return;
            for (self.shards, 0..) |sh, i| {
                const bit = @as(u32, 1) << @intCast(i);
                if (t.mask & bit == 0) continue;
                // A bit is cleared only once its shard synced, so a retry
                // after an error covers what is still pending.
                try sh.sync();
                t.mask &= ~bit;
            }
            t.* = .{};
        }

        /// Makes every write accepted so far durable, from any thread.
        pub fn syncAll(self: *Self) !void {
            for (self.shards) |sh| try sh.sync();
            if (touchedSlot(self.id, false)) |t| t.* = .{};
        }

        fn touch(self: *Self, sh: *Shard) void {
            const i = std.mem.indexOfScalar(*Shard, self.shards, sh).?;
            if (touchedSlot(self.id, true)) |t| {
                t.mask |= @as(u32, 1) << @intCast(i);
            } else touched_overflow = true;
        }

        /// Rewrites every stream into a single run.
        pub fn compact(self: *Self) !void {
            for (self.shards) |sh| try sh.compact();
        }

        pub fn syncCount(self: *const Self) u64 {
            var n: u64 = 0;
            for (self.shards) |sh| n += sh.stats.syncs.load(.monotonic);
            return n;
        }

        pub fn info(self: *Self) Shard.Info {
            var out: Shard.Info = .{};
            for (self.shards) |sh| {
                const i = sh.info();
                out.streams += i.streams;
                out.runs += i.runs;
                out.chunks += i.chunks;
                out.tail_bytes += i.tail_bytes;
                out.meta_bytes += i.meta_bytes;
                out.data_bytes += i.data_bytes;
            }
            return out;
        }

        /// Walks live pairs in key order. Holds every shard's read lock until
        /// `deinit`, so don't write from the same thread meanwhile.
        pub const Iterator = struct {
            self: *Self,
            its: []Shard.Iter,
            cur: []?Pair,
            started: bool = false,
            last: ?usize = null,
            reverse: bool,

            pub fn next(it: *Iterator) !?Pair {
                if (!it.started) {
                    it.started = true;
                    for (it.its, it.cur) |*s, *c| c.* = try s.next();
                } else if (it.last) |l| {
                    it.cur[l] = try it.its[l].next();
                }
                var pick: ?usize = null;
                for (it.cur, 0..) |c, i| {
                    const p = c orelse continue;
                    if (pick) |b| {
                        const o = std.mem.order(u8, p.key, it.cur[b].?.key);
                        if ((!it.reverse and o == .lt) or (it.reverse and o == .gt)) pick = i;
                    } else pick = i;
                }
                it.last = pick;
                return if (pick) |b| it.cur[b] else null;
            }

            pub fn deinit(it: *Iterator) void {
                const gpa = it.self.gpa;
                for (it.its) |*s| s.deinit();
                for (it.self.shards) |sh| sh.lock.unlockShared(it.self.io);
                gpa.free(it.its);
                gpa.free(it.cur);
            }
        };

        pub fn iterator(self: *Self, range: Range, snap: ?Snapshot) !Iterator {
            const gpa = self.gpa;
            const n = self.shards.len;
            const its = try gpa.alloc(Shard.Iter, n);
            errdefer gpa.free(its);
            const cur = try gpa.alloc(?Pair, n);
            errdefer gpa.free(cur);
            var locked: usize = 0;
            errdefer for (self.shards[0..locked]) |sh| sh.lock.unlockShared(self.io);
            var made: usize = 0;
            errdefer for (its[0..made]) |*s| s.deinit();
            for (self.shards, 0..) |sh, i| {
                sh.lock.lockSharedUncancelable(self.io);
                locked += 1;
                its[i] = try Shard.Iter.init(sh, range, if (snap) |s| s.seqs[i] else std.math.maxInt(u64));
                made += 1;
            }
            return .{ .self = self, .its = its, .cur = cur, .reverse = range.reverse };
        }

        /// Copies up to `limit` pairs of `range`. Free with `freePairs`.
        pub fn scan(self: *Self, gpa: Allocator, range: Range, snap: ?Snapshot, limit: usize) ![]Pair {
            // A range inside one stream needs only that stream's shard.
            if (self.shards.len > 1 and range.start.len > 0) {
                const name = streamName(range.start);
                if (name.len > 0) if (range.end) |e| {
                    if (std.mem.startsWith(u8, e, name) or isPrefixEnd(name, e)) {
                        const sh = self.shardOf(range.start);
                        const i = std.mem.indexOfScalar(*Shard, self.shards, sh).?;
                        sh.lock.lockSharedUncancelable(self.io);
                        defer sh.lock.unlockShared(self.io);
                        var it = try Shard.Iter.init(sh, range, if (snap) |s| s.seqs[i] else std.math.maxInt(u64));
                        defer it.deinit();
                        return collect(gpa, &it, limit);
                    }
                };
            }
            var it = try self.iterator(range, snap);
            defer it.deinit();
            return collect(gpa, &it, limit);
        }

        fn isPrefixEnd(name: []const u8, end: []const u8) bool {
            var buf: [256]u8 = undefined;
            if (name.len > buf.len) return false;
            const pe = prefixEnd(name, &buf) orelse return false;
            return std.mem.eql(u8, pe, end);
        }

        /// The newest `n` pairs under `prefix`, greatest key first.
        pub fn latest(self: *Self, gpa: Allocator, prefix: []const u8, n: usize) ![]Pair {
            const end_buf = try gpa.alloc(u8, prefix.len);
            defer gpa.free(end_buf);
            return self.scan(gpa, .{ .start = prefix, .end = prefixEnd(prefix, end_buf), .reverse = true }, null, n);
        }
    };
}

fn collect(gpa: Allocator, it: anytype, limit: usize) ![]Pair {
    var out: std.ArrayList(Pair) = .empty;
    errdefer freePairs(gpa, out.items);
    while (out.items.len < limit) {
        const p = (try it.next()) orelse break;
        const k = try gpa.dupe(u8, p.key);
        errdefer gpa.free(k);
        const v = try gpa.dupe(u8, p.value);
        errdefer gpa.free(v);
        try out.append(gpa, .{ .key = k, .value = v });
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

/// Writes a small file so that a crash leaves either no file or the whole
/// one: write a temporary file, sync it, rename it into place, sync the
/// directory.
fn writeFileAtomic(io: Io, dir: Io.Dir, name: []const u8, text: []const u8) !void {
    var tmp_buf: [32]u8 = undefined;
    const tmp = std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{name}) catch unreachable;
    {
        const f = try dir.createFile(io, tmp, .{ .truncate = true });
        defer f.close(io);
        try f.writePositionalAll(io, text, 0);
        try f.sync(io);
    }
    try dir.rename(tmp, dir, name, io);
    if (@import("builtin").os.tag != .windows) {
        const d = try dir.openFile(io, ".", .{});
        defer d.close(io);
        try d.sync(io);
    }
}

/// Which engine made the store at `sub_path`, or null when it is not a
/// stream store (or does not exist).
pub fn detect(io: Io, parent: Io.Dir, sub_path: []const u8) !?Flavor {
    var dir = parent.openDir(io, sub_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => |e| return e,
    };
    defer dir.close(io);
    return detectIn(io, dir);
}

fn detectIn(io: Io, dir: Io.Dir) !?Flavor {
    var buf: [8]u8 = undefined;
    if (dir.readFile(io, "FORMAT", &buf)) |text| {
        const t = std.mem.trim(u8, text, " \n");
        if (std.mem.eql(u8, t, "v2")) return .v2;
        if (std.mem.eql(u8, t, "v3")) return .v3;
        return error.Corrupt;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => |e| return e,
    }
    // Stores made before FORMAT existed: v2 shards have a WAL directory.
    _ = dir.readFile(io, "SHARDS", &buf) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => |e| return e,
    };
    var wal = dir.openDir(io, "shard-0/wal", .{}) catch |err| switch (err) {
        error.FileNotFound => return .v3,
        else => |e| return e,
    };
    wal.close(io);
    return .v2;
}

pub const V2 = Store(.v2);
pub const V3 = Store(.v3);

// ------------------------------------------------------------------ tests

const testing = std.testing;

fn expectValue(db: anytype, key: []const u8, want: ?[]const u8) !void {
    const got = try db.get(testing.allocator, key);
    defer if (got) |g| testing.allocator.free(g);
    if (want) |w| {
        try testing.expect(got != null);
        try testing.expectEqualStrings(w, got.?);
    } else try testing.expect(got == null);
}

fn basicRoundTrip(comptime S: type) !void {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        var db = try S.open(testing.allocator, io, tmp.dir, "db", .{ .sync_writes = false, .shards = 3 });
        defer db.close();
        try db.put("chat/1/a", "one");
        try db.put("chat/1/b", "two");
        try db.put("chat/2/a", "three");
        try db.put("loose", "misc");
        try db.put("chat/1/a", "one again");
        try db.delete("chat/1/b");
        try expectValue(db, "chat/1/a", "one again");
        try expectValue(db, "chat/1/b", null);
        try expectValue(db, "chat/2/a", "three");
        try expectValue(db, "loose", "misc");
        try expectValue(db, "chat/3/x", null);
        try db.syncAll();
    }
    {
        var db = try S.open(testing.allocator, io, tmp.dir, "db", .{ .sync_writes = false });
        defer db.close();
        try expectValue(db, "chat/1/a", "one again");
        try expectValue(db, "chat/1/b", null);
        try expectValue(db, "chat/2/a", "three");
        try expectValue(db, "loose", "misc");
        try testing.expectEqual(@as(usize, if (S == V2) 1 else 3), db.shards.len);
    }
}

test "v2 and v3 put, get, delete, reopen" {
    try basicRoundTrip(V2);
    try basicRoundTrip(V3);
}

/// Random operations checked against a plain hash map, with reopens and
/// compactions in between. Small values and many keys force seals, merges
/// and multi-chunk runs.
fn modelTest(comptime S: type, seed: u64, time_ordered: bool) !void {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var model: std.StringHashMapUnmanaged([]u8) = .empty;
    defer {
        var it = model.iterator();
        while (it.next()) |e| {
            gpa.free(e.key_ptr.*);
            gpa.free(e.value_ptr.*);
        }
        model.deinit(gpa);
    }
    var prng = std.Random.DefaultPrng.init(seed);
    const r = prng.random();
    var db = try S.open(gpa, io, tmp.dir, "db", .{ .sync_writes = false, .shards = 2 });
    defer db.close();
    var kb: [64]u8 = undefined;
    var vb: [300]u8 = undefined;
    var counter: u64 = 0;
    for (0..40_000) |step| {
        const chat = r.uintLessThan(u64, 6);
        const id = if (time_ordered) blk: {
            counter += 1;
            break :blk if (r.uintLessThan(u8, 10) == 0) r.uintLessThan(u64, counter) else counter;
        } else r.uintLessThan(u64, 3000);
        const key = try std.fmt.bufPrint(&kb, "chat/{d}/m{d:0>8}", .{ chat, id });
        const roll = r.uintLessThan(u8, 100);
        if (roll < 75) {
            const vlen = r.uintLessThan(usize, 250);
            for (vb[0..vlen], 0..) |*c, i| c.* = @intCast((i * 7 + step) % 26 + 'a');
            const v = vb[0..vlen];
            try db.put(key, v);
            const gop = try model.getOrPut(gpa, key);
            if (gop.found_existing) gpa.free(gop.value_ptr.*) else gop.key_ptr.* = try gpa.dupe(u8, key);
            gop.value_ptr.* = try gpa.dupe(u8, v);
        } else if (roll < 90) {
            try db.delete(key);
            if (model.fetchRemove(key)) |kv| {
                gpa.free(kv.key);
                gpa.free(kv.value);
            }
        } else if (roll < 99) {
            const want = model.get(key);
            try expectValue(db, key, want);
        } else if (r.uintLessThan(u8, 20) == 0) {
            // Drop a whole chat now and then.
            const p = try std.fmt.bufPrint(&kb, "chat/{d}/", .{chat});
            try db.deletePrefix(p);
            var it = model.iterator();
            var dead: std.ArrayList([]const u8) = .empty;
            defer dead.deinit(gpa);
            while (it.next()) |e| if (std.mem.startsWith(u8, e.key_ptr.*, p)) try dead.append(gpa, e.key_ptr.*);
            for (dead.items) |k| {
                const kv = model.fetchRemove(k).?;
                gpa.free(kv.value);
                gpa.free(kv.key);
            }
        }
        if (step % 9_000 == 8_999) {
            if (step % 18_000 == 17_999) try db.compact();
            db.close();
            db = try S.open(gpa, io, tmp.dir, "db", .{ .sync_writes = false });
        }
    }
    // Full scan matches the model, in order, both ways.
    var keys: std.ArrayList([]const u8) = .empty;
    defer keys.deinit(gpa);
    var mit = model.keyIterator();
    while (mit.next()) |k| try keys.append(gpa, k.*);
    std.mem.sortUnstable([]const u8, keys.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
    for ([_]bool{ false, true }) |rev| {
        var it = try db.iterator(.{ .reverse = rev }, null);
        defer it.deinit();
        var i: usize = 0;
        while (try it.next()) |p| : (i += 1) {
            const want = if (rev) keys.items[keys.items.len - 1 - i] else keys.items[i];
            try testing.expectEqualStrings(want, p.key);
            try testing.expectEqualStrings(model.get(want).?, p.value);
        }
        try testing.expectEqual(keys.items.len, i);
    }
    // Prefix scans inside one chat, newest first.
    for (0..6) |chat| {
        var pb: [16]u8 = undefined;
        const p = try std.fmt.bufPrint(&pb, "chat/{d}/", .{chat});
        const got = try db.latest(gpa, p, 5);
        defer freePairs(gpa, got);
        var want: std.ArrayList([]const u8) = .empty;
        defer want.deinit(gpa);
        var j = keys.items.len;
        while (j > 0 and want.items.len < 5) {
            j -= 1;
            if (std.mem.startsWith(u8, keys.items[j], p)) try want.append(gpa, keys.items[j]);
        }
        try testing.expectEqual(want.items.len, got.len);
        for (want.items, got) |w, g| try testing.expectEqualStrings(w, g.key);
    }
}

test "v2 matches a model through seals, merges, drops and reopens" {
    try modelTest(V2, 1, false);
    try modelTest(V2, 2, true);
}

test "v3 matches a model through seals, merges, drops and reopens" {
    try modelTest(V3, 3, false);
    try modelTest(V3, 4, true);
}

fn snapshotTest(comptime S: type) !void {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try S.open(gpa, io, tmp.dir, "db", .{ .sync_writes = false });
    defer db.close();
    var kb: [32]u8 = undefined;
    var vb: [200]u8 = @splat('v');
    for (0..2000) |i| try db.put(try std.fmt.bufPrint(&kb, "a/b/{d:0>6}", .{i}), &vb);
    try db.put("a/b/target", "old");
    const snap = try db.snapshot();
    try db.put("a/b/target", "new");
    // Push the old version through seals and merges while the snapshot is open.
    for (0..5000) |i| try db.put(try std.fmt.bufPrint(&kb, "a/b/{d:0>6}", .{i}), &vb);
    try db.compact();
    const old = (try db.getAt(gpa, snap, "a/b/target")).?;
    defer gpa.free(old);
    try testing.expectEqualStrings("old", old);
    db.release(snap);
    try expectValue(db, "a/b/target", "new");
}

test "snapshots keep old versions through seals and merges" {
    try snapshotTest(V2);
    try snapshotTest(V3);
}

fn durableThreads(comptime S: type) !void {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        var db = try S.open(gpa, io, tmp.dir, "db", .{ .sync_writes = true, .shards = 2 });
        defer db.close();
        const W = struct {
            fn run(d: *S, t: usize) void {
                var b: [32]u8 = undefined;
                for (0..100) |i| d.put(std.fmt.bufPrint(&b, "t/{d}/{d:0>4}", .{ t, i }) catch unreachable, "x") catch unreachable;
            }
        };
        var hs: [4]std.Thread = undefined;
        for (&hs, 0..) |*h, t| h.* = try std.Thread.spawn(.{}, W.run, .{ db, t });
        for (hs) |h| h.join();
    }
    var db = try S.open(gpa, io, tmp.dir, "db", .{});
    defer db.close();
    var it = try db.iterator(.{}, null);
    defer it.deinit();
    var n: usize = 0;
    while (try it.next()) |_| n += 1;
    try testing.expectEqual(@as(usize, 400), n);
}

test "durable writes from several threads survive reopen" {
    try durableThreads(V2);
    try durableThreads(V3);
}

fn crashTest(comptime S: type) !void {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        var db = try S.open(gpa, io, tmp.dir, "db", .{ .sync_writes = true, .shards = 1 });
        // Enough writes to seal pages a few times, then "crash": skip close
        // but release the lock and handles by hand.
        var kb: [32]u8 = undefined;
        var vb: [100]u8 = @splat('q');
        for (0..500) |i| try db.put(try std.fmt.bufPrint(&kb, "c/1/{d:0>5}", .{i}), &vb);
        const sh = db.shards[0];
        sh.freeMemoryForTest();
        db.lock_file.close(io);
        gpa.free(db.shards);
        gpa.destroy(db);
    }
    var db = try S.open(gpa, io, tmp.dir, "db", .{});
    defer db.close();
    var kb: [32]u8 = undefined;
    for (0..500) |i| {
        const v = (try db.get(gpa, try std.fmt.bufPrint(&kb, "c/1/{d:0>5}", .{i}))) orelse {
            std.debug.print("lost {d}\n", .{i});
            return error.Lost;
        };
        gpa.free(v);
    }
}

test "synced records survive a crash without close" {
    try crashTest(V2);
    try crashTest(V3);
}

test "a store refuses the other engine and bad shard counts" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        var db = try V3.open(gpa, io, tmp.dir, "db", .{ .shards = 2 });
        try db.put("a/b/c", "v");
        db.close();
    }
    try testing.expectError(error.WrongEngine, V2.open(gpa, io, tmp.dir, "db", .{}));
    try testing.expectEqual(Flavor.v3, (try detect(io, tmp.dir, "db")).?);
    try testing.expectError(error.InvalidArgument, V3.open(gpa, io, tmp.dir, "other", .{ .shards = 0 }));
    try testing.expectError(error.InvalidArgument, V3.open(gpa, io, tmp.dir, "other2", .{ .shards = 99 }));
    var db = try V3.open(gpa, io, tmp.dir, "db", .{});
    defer db.close();
    try testing.expectError(error.Locked, V3.open(gpa, io, tmp.dir, "db", .{}));
    const v = (try db.get(gpa, "a/b/c")).?;
    defer gpa.free(v);
    try testing.expectEqualStrings("v", v);
}

test "two handles on one thread keep their own pending syncs" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var a = try V3.open(gpa, io, tmp.dir, "a", .{ .sync_writes = false, .shards = 2 });
    defer a.close();
    var b = try V3.open(gpa, io, tmp.dir, "b", .{ .sync_writes = false, .shards = 2 });
    defer b.close();
    try a.put("x/y/1", "1");
    try b.sync();
    var pending = false;
    for (a.shards) |sh| pending = pending or sh.needsSync();
    try testing.expect(pending);
    try a.sync();
    for (a.shards) |sh| try testing.expect(!sh.needsSync());
}

test "deleting a whole stream then compacting keeps merges working" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try V3.open(gpa, io, tmp.dir, "db", .{ .sync_writes = false, .shards = 1 });
    defer db.close();
    var kb: [32]u8 = undefined;
    var vb: [600]u8 = @splat('z');
    for (0..200) |i| try db.put(try std.fmt.bufPrint(&kb, "s/1/{d:0>5}", .{i}), &vb);
    for (0..200) |i| try db.delete(try std.fmt.bufPrint(&kb, "s/1/{d:0>5}", .{i}));
    try db.compact();
    // Enough new runs to force a merge at the old tier.
    for (0..2000) |i| try db.put(try std.fmt.bufPrint(&kb, "s/1/{d:0>5}", .{i}), &vb);
    try db.compact();
    const got = try db.scan(gpa, .{ .start = "s/1/", .end = "s/10" }, null, 10);
    defer freePairs(gpa, got);
    try testing.expectEqual(@as(usize, 10), got.len);
}
