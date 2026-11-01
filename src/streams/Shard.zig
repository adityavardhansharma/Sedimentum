//! One shard of a stream store: a set of streams with their own files,
//! lock and group commit. v2 runs one shard; v3 runs one per core.
//!
//! A stream is every key that shares the text up to its second `/`, such as
//! `chat/42/`. Keys with fewer than two slashes share the stream "". Each
//! stream keeps:
//!   - a tail: its newest writes, in memory (v2) or in a 16 KB page that is
//!     written in place in the data file (v3), sorted by key;
//!   - runs: sorted, non-overlapping chunk lists, oldest first, merged eight
//!     at a time. When the runs don't overlap (keys that grow with time) a
//!     merge just links the chunk lists without rewriting anything.
//!
//! Only chunk fences and bloom filters stay in RAM. A get checks the tail,
//! then each run's bloom and fences, then one block.
//!
//! Files in a shard directory:
//!   data      chunks (and v3 pages), allocated from a free list
//!   MANIFEST  an append-only log of which chunks each stream owns
//!   wal/      (v2) the write-ahead log, reusing the v1 segment log
//!
//! Crash rules: a chunk is synced before the manifest names it, and space
//! a chunk gave up is reused only after a synced manifest stops naming it.
//! v2 replays WAL records newer than each stream's `floor`. v3 has no WAL:
//! its page records carry a sequence and a checksum, and recovery keeps
//! the run of valid records newer than the page's `floor`.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const chunk = @import("chunk.zig");
const Log = @import("../Log.zig");
const record = @import("../record.zig");

pub const Config = struct {
    /// v2: a write-ahead log and tails in memory. v3: in-place pages.
    wal: bool,
    /// The tail is sealed into a chunk when it would grow past this.
    tail_limit: usize,
    fmt: chunk.Format,
    chunk_target: usize,
    fanout: usize = 8,
};

pub const Pair = struct { key: []const u8, value: []const u8 };

pub const Range = struct {
    /// Inclusive lower bound.
    start: []const u8 = "",
    /// Exclusive upper bound, or null for none.
    end: ?[]const u8 = null,
    reverse: bool = false,
};

/// Keys that start with these two bytes are reserved for internal records.
pub const reserved_prefix = "\xff\xff";
const drop_prefix = reserved_prefix ++ "drop:";

/// The stream a key belongs to: the key up to and including its second
/// slash, or "" when it has fewer than two.
pub fn streamName(key: []const u8) []const u8 {
    const a = std.mem.indexOfScalar(u8, key, '/') orelse return "";
    const b = std.mem.indexOfScalarPos(u8, key, a + 1, '/') orelse return "";
    return key[0 .. b + 1];
}

pub fn prefixEnd(prefix: []const u8, buf: []u8) ?[]const u8 {
    var n = prefix.len;
    while (n > 0) : (n -= 1) {
        if (prefix[n - 1] != 0xff) {
            @memcpy(buf[0..n], prefix[0..n]);
            buf[n - 1] = prefix[n - 1] + 1;
            return buf[0..n];
        }
    }
    return null;
}

const page_align = std.heap.page_size_min;
const map_reserve: usize = 1 << 37;
const alloc_align = 256;
const rec_header = 19;
const max_seq = std.math.maxInt(u64);

pub fn Shard(comptime cfg: Config) type {
    return struct {
        const Self = @This();

        pub const ChunkMeta = struct {
            off: u64,
            len: u32,
            count: u32,
            min_seq: u64,
            max_seq: u64,
            first: []u8,
            last: []u8,
            bloom: []u64,

            fn deinit(c: *ChunkMeta, gpa: Allocator) void {
                gpa.free(c.first);
                gpa.free(c.last);
                gpa.free(c.bloom);
            }
        };

        pub const Run = struct {
            chunks: std.ArrayList(ChunkMeta) = .empty,
            tier: u8 = 0,
            bytes: u64 = 0,
            /// No shadowed versions or tombstones inside (not persisted).
            clean: bool = false,

            fn first(r: *const Run) []const u8 {
                return r.chunks.items[0].first;
            }
            fn last(r: *const Run) []const u8 {
                return r.chunks.items[r.chunks.items.len - 1].last;
            }
        };

        pub const Stream = struct {
            name: []u8,
            /// Tail records in page format, oldest first. Replaced versions
            /// stay here as garbage until the tail is sealed.
            buf: std.ArrayList(u8) = .empty,
            /// Offsets into `buf`, sorted by key, newest version first.
            idx: std.ArrayList(u32) = .empty,
            runs: std.ArrayList(Run) = .empty,
            /// Every write to this stream with seq <= floor is in `runs`
            /// (or was dropped). Replay ignores those.
            floor: u64 = 0,
            /// v3: where this stream's page lives, and how much of `buf`
            /// has been written there.
            page_off: u64 = 0,
            written: usize = 0,
            dirty: bool = false,

            fn recKey(st: *const Stream, off: u32) []const u8 {
                const h = st.buf.items[off..];
                const kl = std.mem.readInt(u16, h[13..15], .little);
                return h[rec_header..][0..kl];
            }
            fn entry(st: *const Stream, off: u32) chunk.Entry {
                const h = st.buf.items[off..];
                const kl = std.mem.readInt(u16, h[13..15], .little);
                const vl = std.mem.readInt(u32, h[15..19], .little);
                return .{
                    .key = h[rec_header..][0..kl],
                    .value = h[rec_header + kl ..][0..vl],
                    .seq = std.mem.readInt(u64, h[4..12], .little),
                    .kind = @enumFromInt(h[12]),
                };
            }
            /// First idx position whose key is >= `key`.
            fn lowerBound(st: *const Stream, key: []const u8) usize {
                var lo: usize = 0;
                var hi: usize = st.idx.items.len;
                while (lo < hi) {
                    const mid = (lo + hi) / 2;
                    if (std.mem.order(u8, st.recKey(st.idx.items[mid]), key) == .lt) lo = mid + 1 else hi = mid;
                }
                return lo;
            }
        };

        const Extent = struct { off: u64, len: u64 };

        pub const Stats = struct {
            syncs: std.atomic.Value(u64) = .init(0),
            seals: u64 = 0,
            merges: u64 = 0,
            linked_merges: u64 = 0,
            bytes_written: u64 = 0,
        };

        gpa: Allocator,
        io: Io,
        sync_writes: bool,
        dir: Io.Dir,
        lock_file: Io.File,
        data: Io.File,
        map: []align(page_align) const u8,
        data_end: u64 = 0,
        free: std.ArrayList(Extent) = .empty,
        free_hint: usize = 0,
        pending_free: std.ArrayList(Extent) = .empty,
        pending_bytes: u64 = 0,
        manifest: Io.File,
        man_buf: std.ArrayList(u8) = .empty,
        man_len: u64 = 0,
        man_base: u64 = 0,
        streams: std.StringHashMapUnmanaged(*Stream) = .empty,
        /// Streams with a name, sorted by name. Their key ranges never overlap.
        named: std.ArrayList(*Stream) = .empty,
        dirty: std.ArrayList(*Stream) = .empty,
        seq: u64 = 0,
        snaps: std.ArrayList(u64) = .empty,
        wal: if (cfg.wal) Log else void = undefined,
        needs_checkpoint: bool = false,
        builder: chunk.Builder,
        stats: Stats = .{},

        lock: Io.RwLock = .init,
        commit_mutex: Io.Mutex = .init,
        commit_done: Io.Condition = .init,
        synced_seq: u64 = 0,
        syncing: bool = false,
        file_mutex: Io.Mutex = .init,

        // ------------------------------------------------------------ open

        pub fn open(gpa: Allocator, io: Io, parent: Io.Dir, sub_path: []const u8, sync_writes: bool) !*Self {
            var dir = try parent.createDirPathOpen(io, sub_path, .{ .open_options = .{ .iterate = true } });
            errdefer dir.close(io);
            const lock_file = dir.createFile(io, "LOCK", .{ .truncate = false, .lock = .exclusive, .lock_nonblocking = true }) catch |err| switch (err) {
                error.WouldBlock => return error.Locked,
                else => |e| return e,
            };
            errdefer lock_file.close(io);
            const data = try dir.createFile(io, "data", .{ .read = true, .truncate = false });
            errdefer data.close(io);
            const manifest = try dir.createFile(io, "MANIFEST", .{ .read = true, .truncate = false });
            errdefer manifest.close(io);
            const map = try std.posix.mmap(null, map_reserve, .{ .READ = true }, .{ .TYPE = .SHARED }, data.handle, 0);
            errdefer std.posix.munmap(map);

            const s = try gpa.create(Self);
            errdefer gpa.destroy(s);
            s.* = .{
                .gpa = gpa,
                .io = io,
                .sync_writes = sync_writes,
                .dir = dir,
                .lock_file = lock_file,
                .data = data,
                .map = map,
                .manifest = manifest,
                .builder = chunk.Builder.init(gpa, cfg.fmt),
            };
            errdefer s.freeMemory();
            s.data_end = try data.length(io);
            try s.replayManifest();
            try s.rebuildFreeList();
            if (cfg.wal) {
                var replay: WalReplay = .{ .s = s };
                s.wal = try Log.open(gpa, io, dir, "wal", .{ .segment_bytes = 32 * 1024 * 1024 }, &replay);
                if (replay.err) |e| return e;
                s.seq = @max(s.seq, s.wal.last_seq);
            } else {
                try s.loadPages();
            }
            // Start from a clean, compact manifest and a synced state.
            try s.durablePoint(true);
            if (cfg.wal) try s.wal.sync();
            s.synced_seq = s.seq;
            return s;
        }

        pub fn close(s: *Self) void {
            s.file_mutex.lockUncancelable(s.io);
            s.lock.lockUncancelable(s.io);
            if (cfg.wal) {
                s.checkpoint() catch {};
            } else {
                s.writePages(true) catch {};
                s.data.sync(s.io) catch {};
            }
            s.lock.unlock(s.io);
            s.file_mutex.unlock(s.io);
            if (cfg.wal) s.wal.close();
            s.freeMemory();
            std.posix.munmap(s.map);
            s.manifest.close(s.io);
            s.data.close(s.io);
            s.lock_file.close(s.io);
            s.dir.close(s.io);
            s.gpa.destroy(s);
        }

        /// Tests only: drops everything without writing, like a crash.
        pub fn freeMemoryForTest(s: *Self) void {
            if (cfg.wal) s.wal.close();
            s.freeMemory();
            std.posix.munmap(s.map);
            s.manifest.close(s.io);
            s.data.close(s.io);
            s.lock_file.close(s.io);
            s.dir.close(s.io);
            s.gpa.destroy(s);
        }

        fn freeMemory(s: *Self) void {
            const gpa = s.gpa;
            var it = s.streams.valueIterator();
            while (it.next()) |p| {
                const st = p.*;
                for (st.runs.items) |*r| freeRun(gpa, r);
                st.runs.deinit(gpa);
                st.buf.deinit(gpa);
                st.idx.deinit(gpa);
                gpa.free(st.name);
                gpa.destroy(st);
            }
            s.streams.deinit(gpa);
            s.named.deinit(gpa);
            s.dirty.deinit(gpa);
            s.free.deinit(gpa);
            s.pending_free.deinit(gpa);
            s.man_buf.deinit(gpa);
            s.snaps.deinit(gpa);
            s.builder.deinit();
        }

        fn freeRun(gpa: Allocator, r: *Run) void {
            for (r.chunks.items) |*c| c.deinit(gpa);
            r.chunks.deinit(gpa);
        }

        // --------------------------------------------------------- streams

        fn findStream(s: *Self, key: []const u8) ?*Stream {
            return s.streams.get(streamName(key));
        }

        fn streamFor(s: *Self, key: []const u8) !*Stream {
            return s.streamNamed(streamName(key), true);
        }

        fn streamNamed(s: *Self, name: []const u8, log_it: bool) !*Stream {
            if (s.streams.get(name)) |st| return st;
            const gpa = s.gpa;
            const st = try gpa.create(Stream);
            errdefer gpa.destroy(st);
            st.* = .{ .name = try gpa.dupe(u8, name) };
            errdefer gpa.free(st.name);
            try s.streams.put(gpa, st.name, st);
            if (name.len > 0) {
                var lo: usize = 0;
                var hi: usize = s.named.items.len;
                while (lo < hi) {
                    const mid = (lo + hi) / 2;
                    if (std.mem.order(u8, s.named.items[mid].name, name) == .lt) lo = mid + 1 else hi = mid;
                }
                try s.named.insert(gpa, lo, st);
            }
            if (!cfg.wal) {
                // v3: every stream gets a page, aligned so in-place writes
                // don't straddle more disk pages than needed.
                st.page_off = s.allocPage();
                try st.buf.ensureTotalCapacity(gpa, 1024);
            }
            if (log_it) try s.manStreamNew(st);
            return st;
        }

        // ------------------------------------------------------- space

        fn alloc(s: *Self, len: u64) !u64 {
            const n = std.mem.alignForward(u64, len, alloc_align);
            const items = s.free.items;
            var tries: usize = 0;
            var i = if (s.free_hint < items.len) s.free_hint else 0;
            while (tries < items.len) : (tries += 1) {
                if (items[i].len >= n) {
                    const off = items[i].off;
                    items[i].off += n;
                    items[i].len -= n;
                    if (items[i].len == 0) _ = s.free.orderedRemove(i);
                    s.free_hint = i;
                    return off;
                }
                i += 1;
                if (i == items.len) i = 0;
            }
            const off = std.mem.alignForward(u64, s.data_end, alloc_align);
            if (off + n > map_reserve) return error.DataFileFull;
            s.data_end = off + n;
            return off;
        }

        fn allocPage(s: *Self) u64 {
            const off = std.mem.alignForward(u64, s.data_end, 4096);
            if (off > s.data_end) s.releaseNow(.{ .off = s.data_end, .len = off - s.data_end });
            s.data_end = off + cfg.tail_limit;
            return off;
        }

        fn releaseLater(s: *Self, e: Extent) !void {
            try s.pending_free.append(s.gpa, e);
            s.pending_bytes += e.len;
        }

        fn releaseNow(s: *Self, e: Extent) void {
            if (e.len == 0) return;
            const items = s.free.items;
            var lo: usize = 0;
            var hi: usize = items.len;
            while (lo < hi) {
                const mid = (lo + hi) / 2;
                if (items[mid].off < e.off) lo = mid + 1 else hi = mid;
            }
            // Merge with neighbours when they touch.
            if (lo > 0 and items[lo - 1].off + items[lo - 1].len == e.off) {
                items[lo - 1].len += e.len;
                if (lo < items.len and items[lo - 1].off + items[lo - 1].len == items[lo].off) {
                    items[lo - 1].len += items[lo].len;
                    _ = s.free.orderedRemove(lo);
                }
                return;
            }
            if (lo < items.len and e.off + e.len == items[lo].off) {
                items[lo].off = e.off;
                items[lo].len += e.len;
                return;
            }
            s.free.insert(s.gpa, lo, e) catch {}; // Losing a free extent only wastes space.
        }

        fn chunkExtent(c: *const ChunkMeta) Extent {
            return .{ .off = c.off, .len = std.mem.alignForward(u64, c.len, alloc_align) };
        }

        /// Everything not used by a chunk or a page is free.
        fn rebuildFreeList(s: *Self) !void {
            const gpa = s.gpa;
            var used: std.ArrayList(Extent) = .empty;
            defer used.deinit(gpa);
            var it = s.streams.valueIterator();
            while (it.next()) |p| {
                const st = p.*;
                if (!cfg.wal) try used.append(gpa, .{ .off = st.page_off, .len = cfg.tail_limit });
                for (st.runs.items) |r| for (r.chunks.items) |*c| try used.append(gpa, chunkExtent(c));
            }
            std.mem.sortUnstable(Extent, used.items, {}, struct {
                fn lt(_: void, a: Extent, b: Extent) bool {
                    return a.off < b.off;
                }
            }.lt);
            var end: u64 = 0;
            for (used.items) |u| {
                if (u.off < end) return error.Corrupt; // Two owners for one byte.
                if (u.off > end) try s.free.append(gpa, .{ .off = end, .len = u.off - end });
                end = u.off + u.len;
            }
            // Space past the last owner is cut off.
            s.data_end = end;
            try s.data.setLength(s.io, end);
        }

        fn writeAt(s: *Self, bytes: []const u8, off: u64) !void {
            try s.data.writePositionalAll(s.io, bytes, off);
            s.stats.bytes_written += bytes.len;
        }

        fn chunkView(s: *const Self, c: *const ChunkMeta) !chunk.View {
            return chunk.View.open(s.map[c.off..][0..c.len]);
        }

        // ------------------------------------------------------- writing

        fn snapshotsOpen(s: *const Self) bool {
            return s.snaps.items.len > 0;
        }

        pub fn put(s: *Self, key: []const u8, value: []const u8) !void {
            return s.write(key, value, .put);
        }

        pub fn delete(s: *Self, key: []const u8) !void {
            return s.write(key, "", .del);
        }

        fn write(s: *Self, key: []const u8, value: []const u8, kind: chunk.Kind) !void {
            if (key.len == 0) return error.EmptyKey;
            if (key.len > std.math.maxInt(u16) - 64) return error.KeyTooLarge;
            if (value.len > record.max_value_len) return error.ValueTooLarge;
            if (std.mem.startsWith(u8, key, reserved_prefix)) return error.ReservedKey;
            const seq = blk: {
                s.lock.lockUncancelable(s.io);
                defer s.lock.unlock(s.io);
                try s.writeLocked(key, value, kind);
                break :blk s.seq;
            };
            try s.afterWrite(seq);
        }

        fn afterWrite(s: *Self, seq: u64) !void {
            if (s.sync_writes) try s.commit(seq);
            if (s.needs_checkpoint) {
                s.file_mutex.lockUncancelable(s.io);
                defer s.file_mutex.unlock(s.io);
                s.lock.lockUncancelable(s.io);
                defer s.lock.unlock(s.io);
                if (s.needs_checkpoint) try s.checkpoint();
            }
        }

        fn writeLocked(s: *Self, key: []const u8, value: []const u8, kind: chunk.Kind) !void {
            const st = try s.streamFor(key);
            const seq = s.seq + 1;
            if (cfg.wal) _ = try s.wal.append(.{ .seq = seq, .kind = if (kind == .put) .put else .delete, .key = key, .value = value });
            // The seq moves only after the tail takes the record: a seal it
            // triggers must not count this record as already sealed.
            errdefer s.seq = seq;
            try s.tailAdd(st, key, value, seq, kind);
            s.seq = seq;
            if (cfg.wal) {
                if (s.wal.segments.items.len > 2) s.needs_checkpoint = true;
            }
            if (s.pending_bytes > 64 * 1024 * 1024 or s.man_buf.items.len > 4 * 1024 * 1024) s.needs_checkpoint = true;
        }

        fn tailAdd(s: *Self, st: *Stream, key: []const u8, value: []const u8, seq: u64, kind: chunk.Kind) !void {
            const len = rec_header + key.len + value.len;
            if (len > cfg.tail_limit) {
                // Too big for any tail: seal what is there, then give this
                // record a chunk of its own, newer than every run.
                try s.seal(st);
                var w = s.runWriter();
                try w.add(.{ .key = key, .value = value, .seq = seq, .kind = kind });
                try s.addRun(st, try w.finish());
                return;
            }
            if (st.buf.items.len + len > cfg.tail_limit) try s.seal(st);
            const gpa = s.gpa;
            const off: u32 = @intCast(st.buf.items.len);
            const h = try st.buf.addManyAsSlice(gpa, len);
            std.mem.writeInt(u64, h[4..12], seq, .little);
            h[12] = @intFromEnum(kind);
            std.mem.writeInt(u16, h[13..15], @intCast(key.len), .little);
            std.mem.writeInt(u32, h[15..19], @intCast(value.len), .little);
            @memcpy(h[rec_header..][0..key.len], key);
            @memcpy(h[rec_header + key.len ..][0..value.len], value);
            std.mem.writeInt(u32, h[0..4], record.Crc32c.hash(h[4..]), .little);
            try s.tailIndex(st, off);
            if (!cfg.wal and !st.dirty) {
                st.dirty = true;
                try s.dirty.append(gpa, st);
            }
        }

        fn tailIndex(s: *Self, st: *Stream, off: u32) !void {
            const key = st.recKey(off);
            const pos = st.lowerBound(key);
            if (pos < st.idx.items.len and std.mem.eql(u8, st.recKey(st.idx.items[pos]), key) and !s.snapshotsOpen()) {
                st.idx.items[pos] = off;
            } else {
                try st.idx.insert(s.gpa, pos, off);
            }
        }

        fn resetTail(s: *Self, st: *Stream) void {
            _ = s;
            st.buf.clearRetainingCapacity();
            st.idx.clearRetainingCapacity();
            st.written = 0;
        }

        /// Moves the tail into a new run.
        fn seal(s: *Self, st: *Stream) !void {
            if (st.idx.items.len == 0) {
                if (st.buf.items.len > 0) {
                    st.floor = s.seq;
                    s.resetTail(st);
                    try s.manFloor(st);
                }
                return;
            }
            const drop_tombstones = st.runs.items.len == 0 and !s.snapshotsOpen();
            var w = s.runWriter();
            for (st.idx.items) |off| {
                const e = st.entry(off);
                if (drop_tombstones and e.kind == .del) continue;
                try w.add(e);
            }
            var run = try w.finish();
            run.clean = drop_tombstones;
            st.floor = s.seq;
            s.resetTail(st);
            s.stats.seals += 1;
            if (run.chunks.items.len == 0) {
                try s.manFloor(st);
                return;
            }
            try s.addRun(st, run);
        }

        fn addRun(s: *Self, st: *Stream, run: Run) !void {
            for (run.chunks.items) |c| st.floor = @max(st.floor, c.max_seq);
            var r = run;
            errdefer freeRun(s.gpa, &r);
            try st.runs.append(s.gpa, r);
            try s.manAddRun(st, &st.runs.items[st.runs.items.len - 1]);
            try s.maybeMerge(st);
        }

        const RunWriter = struct {
            s: *Self,
            run: Run = .{},

            fn add(w: *RunWriter, e: chunk.Entry) !void {
                const b = &w.s.builder;
                if (!b.isEmpty() and b.size() >= cfg.chunk_target and b.isNewKey(e.key)) try w.flush();
                try b.add(e);
            }

            fn flush(w: *RunWriter) !void {
                const s = w.s;
                const gpa = s.gpa;
                const b = &s.builder;
                const bytes = try b.finish();
                const off = try s.alloc(bytes.len);
                errdefer s.releaseNow(.{ .off = off, .len = std.mem.alignForward(u64, bytes.len, alloc_align) });
                try s.writeAt(bytes, off);
                const first = try gpa.dupe(u8, b.firstKey());
                errdefer gpa.free(first);
                const last = try gpa.dupe(u8, b.lastKey());
                errdefer gpa.free(last);
                const bloom = try b.bloom(gpa);
                errdefer gpa.free(bloom);
                try w.run.chunks.append(gpa, .{
                    .off = off,
                    .len = @intCast(bytes.len),
                    .count = b.count,
                    .min_seq = b.min_seq,
                    .max_seq = b.max_seq,
                    .first = first,
                    .last = last,
                    .bloom = bloom,
                });
                w.run.bytes += bytes.len;
                b.reset();
            }

            fn finish(w: *RunWriter) !Run {
                if (!w.s.builder.isEmpty()) try w.flush();
                return w.run;
            }
        };

        fn runWriter(s: *Self) RunWriter {
            s.builder.reset();
            return .{ .s = s };
        }

        // --------------------------------------------------------- merges

        fn maybeMerge(s: *Self, st: *Stream) !void {
            while (st.runs.items.len >= cfg.fanout) {
                const n = st.runs.items.len;
                const tier = st.runs.items[n - 1].tier;
                var same = true;
                for (st.runs.items[n - cfg.fanout ..]) |r| {
                    if (r.tier != tier) same = false;
                }
                if (!same) return;
                try s.mergeRuns(st, n - cfg.fanout, cfg.fanout, tier + 1);
            }
        }

        fn mergeRuns(s: *Self, st: *Stream, first: usize, count: usize, tier: u8) !void {
            const gpa = s.gpa;
            const runs = st.runs.items[first..][0..count];
            var merged: Run = .{ .tier = tier };
            errdefer freeRun(gpa, &merged);

            // Disjoint runs (time-ordered keys) are linked, not rewritten.
            const order = try gpa.alloc(usize, count);
            defer gpa.free(order);
            for (order, 0..) |*o, i| o.* = i;
            std.mem.sortUnstable(usize, order, runs, struct {
                fn lt(rs: []Run, a: usize, b: usize) bool {
                    return std.mem.order(u8, rs[a].first(), rs[b].first()) == .lt;
                }
            }.lt);
            var disjoint = true;
            for (order[1..], 0..) |o, i| {
                if (std.mem.order(u8, runs[order[i]].last(), runs[o].first()) != .lt) disjoint = false;
            }
            if (disjoint) {
                for (order) |o| {
                    try merged.chunks.appendSlice(gpa, runs[o].chunks.items);
                    merged.bytes += runs[o].bytes;
                }
                for (runs) |*r| r.chunks.deinit(gpa); // Chunks now belong to `merged`.
                s.stats.linked_merges += 1;
            } else {
                merged.chunks.deinit(gpa);
                return s.mergeRunsRewrite(st, first, count, tier);
            }
            const has_chunks = merged.chunks.items.len > 0;
            if (has_chunks) {
                st.runs.items[first] = merged;
                st.runs.replaceRangeAssumeCapacity(first + 1, count - 1, &.{});
            } else {
                st.runs.replaceRangeAssumeCapacity(first, count, &.{});
            }
            try s.manMerge(st, first, count, if (has_chunks) &st.runs.items[first] else null);
        }

        /// Walks several runs at once in key order, every version of each
        /// key newest first. For merges.
        const MergeCursor = struct {
            s: *Self,
            curs: []RunCursor,
            key: std.ArrayList(u8) = .empty,
            versions_seen: usize = 0,
            value: std.ArrayList(u8) = .empty,

            fn init(s: *Self, runs: []Run) !MergeCursor {
                const curs = try s.gpa.alloc(RunCursor, runs.len);
                for (curs, runs) |*c, *r| c.* = .{ .s = s, .run = r };
                for (curs) |*c| try c.seekFirst(true);
                return .{ .s = s, .curs = curs };
            }

            fn deinit(m: *MergeCursor) void {
                for (m.curs) |*c| c.deinit();
                m.s.gpa.free(m.curs);
                m.key.deinit(m.s.gpa);
                m.value.deinit(m.s.gpa);
            }

            /// The next entry. Versions of one key come out newest first;
            /// `versions_seen` counts how many of that key came before.
            fn nextKey(m: *MergeCursor) !?chunk.Entry {
                var best: ?usize = null;
                for (m.curs, 0..) |*c, i| {
                    if (!c.valid) continue;
                    if (best) |b| {
                        const be = m.curs[b].cur();
                        const ce = c.cur();
                        switch (std.mem.order(u8, ce.key, be.key)) {
                            .lt => best = i,
                            .eq => if (ce.seq > be.seq) {
                                best = i;
                            },
                            .gt => {},
                        }
                    } else best = i;
                }
                const b = best orelse return null;
                const e = m.curs[b].cur();
                const gpa = m.s.gpa;
                if (m.versions_seen > 0 and std.mem.eql(u8, m.key.items, e.key)) m.versions_seen += 1 else m.versions_seen = 1;
                m.key.clearRetainingCapacity();
                try m.key.appendSlice(gpa, e.key);
                m.value.clearRetainingCapacity();
                try m.value.appendSlice(gpa, e.value);
                const out: chunk.Entry = .{ .key = m.key.items, .value = m.value.items, .seq = e.seq, .kind = e.kind };
                try m.curs[b].step(true);
                return out;
            }
        };

        /// Rewrites each stream into one run and drops dead versions.
        pub fn compact(s: *Self) !void {
            s.file_mutex.lockUncancelable(s.io);
            defer s.file_mutex.unlock(s.io);
            s.lock.lockUncancelable(s.io);
            defer s.lock.unlock(s.io);
            var it = s.streams.valueIterator();
            while (it.next()) |p| {
                const st = p.*;
                try s.seal(st);
                if (st.runs.items.len > 1 or (st.runs.items.len == 1 and !s.snapshotsOpen())) {
                    try s.forceRewrite(st, st.runs.items.len);
                }
                if (s.pending_bytes > 64 * 1024 * 1024) try s.durablePoint(false);
            }
            if (cfg.wal) try s.checkpoint() else try s.durablePoint(true);
            // Give back free space at the end of the file.
            while (s.free.items.len > 0) {
                const last = s.free.items[s.free.items.len - 1];
                if (last.off + last.len < s.data_end) break;
                s.data_end = last.off;
                _ = s.free.pop();
            }
            try s.data.setLength(s.io, s.data_end);
        }

        fn forceRewrite(s: *Self, st: *Stream, n: usize) !void {
            // A run already rewritten with nothing older to keep is clean.
            if (n == 1 and st.runs.items[0].clean) return;
            try s.mergeRunsRewrite(st, 0, n, st.runs.items[n - 1].tier);
        }

        fn mergeRunsRewrite(s: *Self, st: *Stream, first: usize, count: usize, tier: u8) !void {
            const gpa = s.gpa;
            const runs = st.runs.items[first..][0..count];
            const drop = !s.snapshotsOpen();
            var w = s.runWriter();
            var it = try MergeCursor.init(s, runs);
            var ok = false;
            defer if (!ok) it.deinit();
            while (try it.nextKey()) |e| {
                if (it.versions_seen > 1 and drop) continue;
                if (drop and first == 0 and e.kind == .del) continue;
                try w.add(e);
            }
            it.deinit();
            ok = true;
            var merged = try w.finish();
            merged.tier = tier;
            merged.clean = drop and first == 0;
            for (runs) |*r| {
                for (r.chunks.items) |*c| try s.releaseLater(chunkExtent(c));
                freeRun(gpa, r);
            }
            s.stats.merges += 1;
            const has_chunks = merged.chunks.items.len > 0;
            if (has_chunks) {
                st.runs.items[first] = merged;
                st.runs.replaceRangeAssumeCapacity(first + 1, count - 1, &.{});
            } else {
                st.runs.replaceRangeAssumeCapacity(first, count, &.{});
            }
            try s.manMerge(st, first, count, if (has_chunks) &st.runs.items[first] else null);
        }

        // ---------------------------------------------------- drop prefix

        /// Deletes every key under `prefix`. Whole streams are dropped in
        /// one step; partial ones get a tombstone per key.
        pub fn deletePrefix(s: *Self, prefix: []const u8) !void {
            const seq = blk: {
                s.lock.lockUncancelable(s.io);
                defer s.lock.unlock(s.io);
                const gpa = s.gpa;
                var keys: std.ArrayList([]u8) = .empty;
                defer {
                    for (keys.items) |k| gpa.free(k);
                    keys.deinit(gpa);
                }
                var victims: std.ArrayList(*Stream) = .empty;
                defer victims.deinit(gpa);
                var it = s.streams.valueIterator();
                while (it.next()) |p| {
                    const st = p.*;
                    if (st.name.len > 0 and std.mem.startsWith(u8, st.name, prefix) and !s.snapshotsOpen()) {
                        try victims.append(gpa, st);
                    } else if (std.mem.startsWith(u8, prefix, st.name) or std.mem.startsWith(u8, st.name, prefix)) {
                        var end_buf: [1024]u8 = undefined;
                        const end = if (prefix.len <= end_buf.len) prefixEnd(prefix, &end_buf) else null;
                        var si = try StreamIter.init(s, st, .{ .start = prefix, .end = end }, max_seq);
                        defer si.deinit();
                        while (try si.next()) |pair| {
                            if (!std.mem.startsWith(u8, pair.key, prefix)) break;
                            try keys.append(gpa, try gpa.dupe(u8, pair.key));
                        }
                    }
                }
                for (victims.items) |st| try s.dropStream(st);
                for (keys.items) |k| try s.writeLocked(k, "", .del);
                break :blk s.seq;
            };
            try s.afterWrite(seq);
        }

        fn dropStream(s: *Self, st: *Stream) !void {
            s.seq += 1;
            if (cfg.wal) {
                var kb: std.ArrayList(u8) = .empty;
                defer kb.deinit(s.gpa);
                try kb.appendSlice(s.gpa, drop_prefix);
                try kb.appendSlice(s.gpa, st.name);
                _ = try s.wal.append(.{ .seq = s.seq, .kind = .delete, .key = kb.items });
            }
            s.applyDrop(st);
            try s.manDrop(st);
        }

        fn applyDrop(s: *Self, st: *Stream) void {
            for (st.runs.items) |*r| {
                for (r.chunks.items) |*c| s.releaseLater(chunkExtent(c)) catch {};
                freeRun(s.gpa, r);
            }
            st.runs.clearRetainingCapacity();
            s.resetTail(st);
            st.floor = s.seq;
        }

        // ---------------------------------------------------------- reads

        /// The newest visible version of `key` at `at`, copied for the caller.
        pub fn get(s: *Self, gpa: Allocator, key: []const u8, at: u64) !?[]u8 {
            s.lock.lockSharedUncancelable(s.io);
            defer s.lock.unlockShared(s.io);
            return s.getLocked(gpa, key, at);
        }

        fn getLocked(s: *Self, gpa: Allocator, key: []const u8, at: u64) !?[]u8 {
            const st = s.findStream(key) orelse return null;
            // Tail first: it holds the newest writes.
            var pos = st.lowerBound(key);
            while (pos < st.idx.items.len) : (pos += 1) {
                const e = st.entry(st.idx.items[pos]);
                if (!std.mem.eql(u8, e.key, key)) break;
                if (e.seq <= at) return if (e.kind == .put) try gpa.dupe(u8, e.value) else null;
            }
            var stack: [cfg.fmt.block_bytes * 2 + 2048]u8 = undefined;
            var bfa = std.heap.BufferFirstAllocator.init(&stack, gpa);
            const a = bfa.allocator();
            var scratch: std.ArrayList(u8) = .empty;
            defer scratch.deinit(a);
            var kb: std.ArrayList(u8) = .empty;
            defer kb.deinit(a);
            const h = chunk.keyHash(key);
            var ri = st.runs.items.len;
            while (ri > 0) {
                ri -= 1;
                const r = &st.runs.items[ri];
                const c = findChunk(r, key) orelse continue;
                if (c.min_seq > at) continue;
                if (!chunk.bloomHas(c.bloom, h)) continue;
                const v = try s.chunkView(c);
                if (try chunk.get(v, a, key, at, &scratch, &kb)) |e| {
                    return if (e.kind == .put) try gpa.dupe(u8, e.value) else null;
                }
            }
            return null;
        }

        fn findChunk(r: *const Run, key: []const u8) ?*const ChunkMeta {
            const cs = r.chunks.items;
            var lo: usize = 0;
            var hi: usize = cs.len;
            while (lo < hi) {
                const mid = (lo + hi) / 2;
                if (std.mem.order(u8, cs[mid].last, key) == .lt) lo = mid + 1 else hi = mid;
            }
            if (lo == cs.len) return null;
            if (std.mem.order(u8, cs[lo].first, key) == .gt) return null;
            return &cs[lo];
        }

        pub fn snapshot(s: *Self) !u64 {
            s.lock.lockUncancelable(s.io);
            defer s.lock.unlock(s.io);
            try s.snaps.append(s.gpa, s.seq);
            return s.seq;
        }

        pub fn release(s: *Self, at: u64) void {
            s.lock.lockUncancelable(s.io);
            defer s.lock.unlock(s.io);
            for (s.snaps.items, 0..) |v, i| if (v == at) {
                _ = s.snaps.swapRemove(i);
                return;
            };
        }

        // ------------------------------------------------------ cursors

        /// Walks one run in either direction, one decoded block at a time.
        pub const RunCursor = struct {
            s: *const Self,
            run: *const Run,
            ci: usize = 0,
            bi: usize = 0,
            ei: usize = 0,
            view: chunk.View = undefined,
            parsed: chunk.Parsed = .{},
            valid: bool = false,

            fn deinit(c: *RunCursor) void {
                c.parsed.deinit(c.s.gpa);
            }

            fn cur(c: *const RunCursor) chunk.Entry {
                return c.parsed.entries.items[c.ei];
            }

            fn enterChunk(c: *RunCursor, ci: usize) !void {
                c.ci = ci;
                c.view = try c.s.chunkView(&c.run.chunks.items[ci]);
            }

            fn loadBlock(c: *RunCursor, bi: usize) !void {
                c.bi = bi;
                try c.parsed.load(c.s.gpa, c.view, bi);
                if (c.parsed.entries.items.len == 0) return error.Corrupt;
            }

            fn seekFirst(c: *RunCursor, forward: bool) !void {
                const n = c.run.chunks.items.len;
                c.valid = n > 0;
                if (!c.valid) return;
                try c.enterChunk(if (forward) 0 else n - 1);
                try c.loadBlock(if (forward) 0 else c.view.nblocks - 1);
                c.ei = if (forward) 0 else c.parsed.entries.items.len - 1;
            }

            /// First entry with key >= `key`.
            fn seekGE(c: *RunCursor, key: []const u8) !void {
                const cs = c.run.chunks.items;
                var lo: usize = 0;
                var hi: usize = cs.len;
                while (lo < hi) {
                    const mid = (lo + hi) / 2;
                    if (std.mem.order(u8, cs[mid].last, key) == .lt) lo = mid + 1 else hi = mid;
                }
                c.valid = lo < cs.len;
                if (!c.valid) return;
                try c.enterChunk(lo);
                try c.loadBlock((try c.view.findBlock(key)) orelse 0);
                const es = c.parsed.entries.items;
                var i: usize = 0;
                while (i < es.len and std.mem.order(u8, es[i].key, key) == .lt) i += 1;
                if (i < es.len) {
                    c.ei = i;
                } else {
                    c.ei = es.len - 1;
                    try c.step(true);
                }
            }

            /// Last entry with key < `key`.
            fn seekLT(c: *RunCursor, key: []const u8) !void {
                const cs = c.run.chunks.items;
                var lo: usize = 0;
                var hi: usize = cs.len;
                while (lo < hi) {
                    const mid = (lo + hi) / 2;
                    if (std.mem.order(u8, cs[mid].first, key) == .lt) lo = mid + 1 else hi = mid;
                }
                c.valid = lo > 0;
                if (!c.valid) return;
                try c.enterChunk(lo - 1);
                try c.loadBlock((try c.view.findBlockBefore(key)) orelse 0);
                const es = c.parsed.entries.items;
                var i: usize = es.len;
                while (i > 0 and std.mem.order(u8, es[i - 1].key, key) != .lt) i -= 1;
                if (i > 0) {
                    c.ei = i - 1;
                } else {
                    c.ei = 0;
                    try c.step(false);
                }
            }

            fn step(c: *RunCursor, forward: bool) !void {
                if (forward) {
                    if (c.ei + 1 < c.parsed.entries.items.len) {
                        c.ei += 1;
                        return;
                    }
                    if (c.bi + 1 < c.view.nblocks) {
                        try c.loadBlock(c.bi + 1);
                        c.ei = 0;
                        return;
                    }
                    if (c.ci + 1 < c.run.chunks.items.len) {
                        try c.enterChunk(c.ci + 1);
                        try c.loadBlock(0);
                        c.ei = 0;
                        return;
                    }
                } else {
                    if (c.ei > 0) {
                        c.ei -= 1;
                        return;
                    }
                    if (c.bi > 0) {
                        try c.loadBlock(c.bi - 1);
                        c.ei = c.parsed.entries.items.len - 1;
                        return;
                    }
                    if (c.ci > 0) {
                        try c.enterChunk(c.ci - 1);
                        try c.loadBlock(c.view.nblocks - 1);
                        c.ei = c.parsed.entries.items.len - 1;
                        return;
                    }
                }
                c.valid = false;
            }
        };

        const TailCursor = struct {
            st: *const Stream,
            i: usize = 0,
            valid: bool = false,

            fn cur(c: *const TailCursor) chunk.Entry {
                return c.st.entry(c.st.idx.items[c.i]);
            }
            fn step(c: *TailCursor, forward: bool) void {
                if (forward) {
                    c.i += 1;
                    c.valid = c.i < c.st.idx.items.len;
                } else if (c.i == 0) {
                    c.valid = false;
                } else c.i -= 1;
            }
        };

        const Source = union(enum) {
            tail: TailCursor,
            run: RunCursor,

            fn valid(src: *const Source) bool {
                return switch (src.*) {
                    inline else => |*c| c.valid,
                };
            }
            fn cur(src: *const Source) chunk.Entry {
                return switch (src.*) {
                    inline else => |*c| c.cur(),
                };
            }
            fn step(src: *Source, forward: bool) !void {
                switch (src.*) {
                    .tail => |*c| c.step(forward),
                    .run => |*c| try c.step(forward),
                }
            }
        };

        /// Live pairs of one stream in key order, as of `at`.
        pub const StreamIter = struct {
            s: *const Self,
            sources: std.ArrayList(Source) = .empty,
            range: Range,
            at: u64,
            key: std.ArrayList(u8) = .empty,
            value: std.ArrayList(u8) = .empty,

            pub fn init(s: *const Self, st: *const Stream, range: Range, at: u64) !StreamIter {
                const gpa = s.gpa;
                var it: StreamIter = .{ .s = s, .range = range, .at = at };
                errdefer it.deinit();
                try it.sources.ensureTotalCapacity(gpa, st.runs.items.len + 1);
                var tail: TailCursor = .{ .st = st };
                if (!range.reverse) {
                    tail.i = st.lowerBound(range.start);
                    tail.valid = tail.i < st.idx.items.len;
                } else {
                    const lb = if (range.end) |e| st.lowerBound(e) else st.idx.items.len;
                    tail.valid = lb > 0;
                    tail.i = if (lb > 0) lb - 1 else 0;
                }
                it.sources.appendAssumeCapacity(.{ .tail = tail });
                for (st.runs.items) |*r| {
                    it.sources.appendAssumeCapacity(.{ .run = .{ .s = s, .run = r } });
                    const c = &it.sources.items[it.sources.items.len - 1].run;
                    if (!range.reverse) {
                        try c.seekGE(range.start);
                    } else if (range.end) |e| {
                        try c.seekLT(e);
                    } else try c.seekFirst(false);
                }
                return it;
            }

            pub fn deinit(it: *StreamIter) void {
                const gpa = it.s.gpa;
                for (it.sources.items) |*src| switch (src.*) {
                    .run => |*c| c.deinit(),
                    .tail => {},
                };
                it.sources.deinit(gpa);
                it.key.deinit(gpa);
                it.value.deinit(gpa);
            }

            /// The next live pair. Valid until the next call.
            pub fn next(it: *StreamIter) !?Pair {
                const gpa = it.s.gpa;
                const fwd = !it.range.reverse;
                while (true) {
                    var pick: ?usize = null;
                    for (it.sources.items, 0..) |*src, i| {
                        if (!src.valid()) continue;
                        if (pick) |p| {
                            const o = std.mem.order(u8, src.cur().key, it.sources.items[p].cur().key);
                            if ((fwd and o == .lt) or (!fwd and o == .gt)) pick = i;
                        } else pick = i;
                    }
                    const p = pick orelse return null;
                    const k = it.sources.items[p].cur().key;
                    if (fwd) {
                        if (it.range.end) |e| if (std.mem.order(u8, k, e) != .lt) return null;
                    } else if (std.mem.order(u8, k, it.range.start) == .lt) return null;
                    it.key.clearRetainingCapacity();
                    try it.key.appendSlice(gpa, k);
                    var best_seq: u64 = 0;
                    var best_kind: ?chunk.Kind = null;
                    for (it.sources.items) |*src| {
                        while (src.valid()) {
                            const e = src.cur();
                            if (!std.mem.eql(u8, e.key, it.key.items)) break;
                            if (e.seq <= it.at and (best_kind == null or e.seq > best_seq)) {
                                best_seq = e.seq;
                                best_kind = e.kind;
                                it.value.clearRetainingCapacity();
                                try it.value.appendSlice(gpa, e.value);
                            }
                            try src.step(fwd);
                        }
                    }
                    if (best_kind == .put) return .{ .key = it.key.items, .value = it.value.items };
                }
            }
        };

        /// Live pairs of the whole shard in key order. Hold the shard's
        /// shared lock while using it.
        pub const Iter = struct {
            s: *const Self,
            range: Range,
            at: u64,
            misc: ?StreamIter = null,
            misc_cur: ?Pair = null,
            named: ?StreamIter = null,
            named_cur: ?Pair = null,
            /// Next index into `s.named` to open (forward), or one past it (reverse).
            ni: usize = 0,
            started: bool = false,
            advance_misc: bool = false,
            advance_named: bool = false,

            pub fn init(s: *const Self, range: Range, at: u64) !Iter {
                var it: Iter = .{ .s = s, .range = range, .at = at };
                errdefer it.deinit();
                if (s.streams.get("")) |st| it.misc = try StreamIter.init(s, st, range, at);
                const ns = s.named.items;
                if (!range.reverse) {
                    var lo = lowerBound(ns, range.start);
                    if (lo > 0 and std.mem.startsWith(u8, range.start, ns[lo - 1].name)) lo -= 1;
                    it.ni = lo;
                } else {
                    it.ni = if (range.end) |e| lowerBound(ns, e) else ns.len;
                }
                return it;
            }

            fn lowerBound(ns: []const *Stream, key: []const u8) usize {
                var lo: usize = 0;
                var hi: usize = ns.len;
                while (lo < hi) {
                    const mid = (lo + hi) / 2;
                    if (std.mem.order(u8, ns[mid].name, key) == .lt) lo = mid + 1 else hi = mid;
                }
                return lo;
            }

            pub fn deinit(it: *Iter) void {
                if (it.misc) |*m| m.deinit();
                if (it.named) |*n| n.deinit();
            }

            fn nextNamed(it: *Iter) !?Pair {
                const ns = it.s.named.items;
                while (true) {
                    if (it.named) |*n| {
                        if (try n.next()) |p| return p;
                        n.deinit();
                        it.named = null;
                    }
                    if (!it.range.reverse) {
                        if (it.ni >= ns.len) return null;
                        const st = ns[it.ni];
                        if (it.range.end) |e| if (std.mem.order(u8, st.name, e) != .lt) return null;
                        it.ni += 1;
                        it.named = try StreamIter.init(it.s, st, it.range, it.at);
                    } else {
                        if (it.ni == 0) return null;
                        const st = ns[it.ni - 1];
                        if (std.mem.order(u8, st.name, it.range.start) == .lt and !std.mem.startsWith(u8, it.range.start, st.name)) return null;
                        it.ni -= 1;
                        it.named = try StreamIter.init(it.s, st, it.range, it.at);
                    }
                }
            }

            pub fn next(it: *Iter) !?Pair {
                if (!it.started) {
                    it.started = true;
                    if (it.misc) |*m| it.misc_cur = try m.next();
                    it.named_cur = try it.nextNamed();
                } else {
                    if (it.advance_misc) it.misc_cur = try it.misc.?.next();
                    if (it.advance_named) it.named_cur = try it.nextNamed();
                }
                it.advance_misc = false;
                it.advance_named = false;
                const m = it.misc_cur;
                const n = it.named_cur;
                if (m == null and n == null) return null;
                const take_misc = if (m == null) false else if (n == null) true else blk: {
                    const o = std.mem.order(u8, m.?.key, n.?.key);
                    break :blk if (it.range.reverse) o == .gt else o == .lt;
                };
                if (take_misc) {
                    it.advance_misc = true;
                    return m;
                }
                it.advance_named = true;
                return n;
            }
        };

        // ---------------------------------------------------------- sync

        /// Makes every write accepted so far durable.
        pub fn sync(s: *Self) !void {
            const seq = blk: {
                s.lock.lockSharedUncancelable(s.io);
                defer s.lock.unlockShared(s.io);
                break :blk s.seq;
            };
            try s.commit(seq);
        }

        /// Group commit: the first waiter syncs for everyone.
        fn commit(s: *Self, seq: u64) !void {
            s.commit_mutex.lockUncancelable(s.io);
            defer s.commit_mutex.unlock(s.io);
            while (s.synced_seq < seq) {
                if (s.syncing) {
                    s.commit_done.waitUncancelable(s.io, &s.commit_mutex);
                    continue;
                }
                s.syncing = true;
                s.commit_mutex.unlock(s.io);
                const result = s.syncNow();
                s.commit_mutex.lockUncancelable(s.io);
                s.syncing = false;
                if (result) |target| {
                    s.synced_seq = @max(s.synced_seq, target);
                } else |_| {}
                s.commit_done.broadcast(s.io);
                _ = try result;
            }
        }

        fn syncNow(s: *Self) !u64 {
            s.file_mutex.lockUncancelable(s.io);
            defer s.file_mutex.unlock(s.io);
            var target: u64 = undefined;
            var file: Io.File = undefined;
            {
                s.lock.lockUncancelable(s.io);
                defer s.lock.unlock(s.io);
                target = s.seq;
                if (cfg.wal) {
                    try s.wal.flush();
                    file = s.wal.pinSyncHandle();
                } else {
                    try s.writePages(false);
                    file = s.data;
                }
            }
            const result = file.sync(s.io);
            if (cfg.wal) {
                s.lock.lockUncancelable(s.io);
                s.wal.unpinSync();
                if (result) |_| {} else |_| s.wal.poisoned = true;
                s.lock.unlock(s.io);
            }
            try result;
            _ = s.stats.syncs.fetchAdd(1, .monotonic);
            return target;
        }

        /// v3: writes each dirty tail into its page. Pages of streams that
        /// were sealed restart at offset 0, so the manifest that moved
        /// their old records into chunks must be durable first.
        fn writePages(s: *Self, sync_data: bool) !void {
            if (s.man_buf.items.len > 0) try s.durablePoint(false);
            for (s.dirty.items) |st| {
                if (st.written < st.buf.items.len) {
                    try s.writeAt(st.buf.items[st.written..], st.page_off + st.written);
                    st.written = st.buf.items.len;
                }
                st.dirty = false;
            }
            s.dirty.clearRetainingCapacity();
            if (sync_data) try s.data.sync(s.io);
        }

        /// v2: seals every tail so the whole WAL is covered by chunks, makes
        /// the manifest durable, then deletes the sealed WAL segments.
        fn checkpoint(s: *Self) !void {
            s.needs_checkpoint = false;
            if (!cfg.wal) return s.durablePoint(false);
            var it = s.streams.valueIterator();
            while (it.next()) |p| try s.seal(p.*);
            try s.durablePoint(false);
            try s.wal.sync();
            const segs = try s.gpa.dupe(u64, s.wal.segments.items);
            defer s.gpa.free(segs);
            for (segs) |id| {
                if (id == s.wal.active_id) continue;
                if (s.wal.sync_pin == id) continue;
                try s.wal.removeSegment(id);
            }
        }

        /// Syncs chunk data, then appends and syncs the manifest, then lets
        /// go of space no durable manifest names any more.
        fn durablePoint(s: *Self, force_rewrite: bool) !void {
            s.needs_checkpoint = false;
            if (s.man_buf.items.len == 0 and !force_rewrite and s.pending_free.items.len == 0) return;
            try s.data.sync(s.io);
            try s.manSeq();
            if (force_rewrite or s.man_len > 2 * s.man_base + 8 * 1024 * 1024) {
                try s.rewriteManifest();
            } else {
                try s.manifest.writePositionalAll(s.io, s.man_buf.items, s.man_len);
                try s.manifest.sync(s.io);
                s.man_len += s.man_buf.items.len;
            }
            s.man_buf.clearRetainingCapacity();
            for (s.pending_free.items) |e| s.releaseNow(e);
            s.pending_free.clearRetainingCapacity();
            s.pending_bytes = 0;
        }

        // ------------------------------------------------------ manifest

        const Op = enum(u8) { stream = 1, add_run = 2, merge = 3, drop = 4, floor = 5, seq = 6, _ };

        fn manBegin(s: *Self, op: Op) !usize {
            const start = s.man_buf.items.len;
            try s.man_buf.appendNTimes(s.gpa, 0, 8);
            try s.man_buf.append(s.gpa, @intFromEnum(op));
            return start;
        }

        fn manEnd(s: *Self, start: usize) void {
            const rec = s.man_buf.items[start..];
            std.mem.writeInt(u32, rec[0..4], @intCast(rec.len - 8), .little);
            std.mem.writeInt(u32, rec[4..8], record.Crc32c.hash(rec[8..]), .little);
        }

        fn putU(s: *Self, comptime T: type, v: T) !void {
            std.mem.writeInt(T, try s.man_buf.addManyAsArray(s.gpa, @sizeOf(T)), v, .little);
        }

        fn putStr(s: *Self, b: []const u8) !void {
            try s.putU(u16, @intCast(b.len));
            try s.man_buf.appendSlice(s.gpa, b);
        }

        fn putRun(s: *Self, r: *const Run) !void {
            try s.man_buf.append(s.gpa, r.tier);
            try s.putU(u32, @intCast(r.chunks.items.len));
            for (r.chunks.items) |c| {
                try s.putU(u64, c.off);
                try s.putU(u32, c.len);
                try s.putU(u32, c.count);
                try s.putU(u64, c.min_seq);
                try s.putU(u64, c.max_seq);
                try s.putStr(c.first);
                try s.putStr(c.last);
                try s.putU(u32, @intCast(c.bloom.len));
                try s.man_buf.appendSlice(s.gpa, std.mem.sliceAsBytes(c.bloom));
            }
        }

        fn manStreamNew(s: *Self, st: *const Stream) !void {
            const m = try s.manBegin(.stream);
            try s.putStr(st.name);
            try s.putU(u64, st.page_off);
            try s.putU(u64, st.floor);
            s.manEnd(m);
        }

        fn manAddRun(s: *Self, st: *const Stream, r: *const Run) !void {
            const m = try s.manBegin(.add_run);
            try s.putStr(st.name);
            try s.putU(u64, st.floor);
            try s.putRun(r);
            s.manEnd(m);
        }

        fn manMerge(s: *Self, st: *const Stream, first: usize, count: usize, r: ?*const Run) !void {
            const m = try s.manBegin(.merge);
            try s.putStr(st.name);
            try s.putU(u32, @intCast(first));
            try s.putU(u32, @intCast(count));
            try s.man_buf.append(s.gpa, @intFromBool(r != null));
            if (r) |run| try s.putRun(run);
            s.manEnd(m);
        }

        fn manDrop(s: *Self, st: *const Stream) !void {
            const m = try s.manBegin(.drop);
            try s.putStr(st.name);
            try s.putU(u64, st.floor);
            s.manEnd(m);
        }

        fn manFloor(s: *Self, st: *const Stream) !void {
            const m = try s.manBegin(.floor);
            try s.putStr(st.name);
            try s.putU(u64, st.floor);
            s.manEnd(m);
        }

        fn manSeq(s: *Self) !void {
            const m = try s.manBegin(.seq);
            try s.putU(u64, s.seq);
            s.manEnd(m);
        }

        /// Writes the full state to a new manifest and swaps it in.
        fn rewriteManifest(s: *Self) !void {
            const gpa = s.gpa;
            var saved = s.man_buf;
            s.man_buf = .empty;
            defer {
                s.man_buf.deinit(gpa);
                s.man_buf = saved;
            }
            try s.manSeq();
            var it = s.streams.valueIterator();
            while (it.next()) |p| {
                const st = p.*;
                try s.manStreamNew(st);
                for (st.runs.items) |*r| try s.manAddRun(st, r);
            }
            const tmp = try s.dir.createFile(s.io, "MANIFEST.tmp", .{ .read = true, .truncate = true });
            var tmp_ok = false;
            defer if (!tmp_ok) tmp.close(s.io);
            try tmp.writePositionalAll(s.io, s.man_buf.items, 0);
            try tmp.sync(s.io);
            try s.dir.rename("MANIFEST.tmp", s.dir, "MANIFEST", s.io);
            try syncDir(s.io, s.dir);
            s.manifest.close(s.io);
            s.manifest = tmp;
            tmp_ok = true;
            s.man_len = s.man_buf.items.len;
            s.man_base = s.man_len;
            saved.clearRetainingCapacity();
        }

        const Reader = struct {
            b: []const u8,
            pos: usize = 0,

            fn u(r: *Reader, comptime T: type) !T {
                if (r.pos + @sizeOf(T) > r.b.len) return error.Corrupt;
                const v = std.mem.readInt(T, r.b[r.pos..][0..@sizeOf(T)], .little);
                r.pos += @sizeOf(T);
                return v;
            }
            fn str(r: *Reader) ![]const u8 {
                const n = try r.u(u16);
                if (r.pos + n > r.b.len) return error.Corrupt;
                defer r.pos += n;
                return r.b[r.pos..][0..n];
            }
        };

        fn readRun(s: *Self, r: *Reader) !Run {
            const gpa = s.gpa;
            var run: Run = .{ .tier = try r.u(u8) };
            errdefer freeRun(gpa, &run);
            const n = try r.u(u32);
            for (0..n) |_| {
                var c: ChunkMeta = .{
                    .off = try r.u(u64),
                    .len = try r.u(u32),
                    .count = try r.u(u32),
                    .min_seq = try r.u(u64),
                    .max_seq = try r.u(u64),
                    .first = &.{},
                    .last = &.{},
                    .bloom = &.{},
                };
                c.first = try gpa.dupe(u8, try r.str());
                errdefer gpa.free(c.first);
                c.last = try gpa.dupe(u8, try r.str());
                errdefer gpa.free(c.last);
                const words = try r.u(u32);
                if (r.pos + @as(usize, words) * 8 > r.b.len) return error.Corrupt;
                c.bloom = try gpa.alloc(u64, words);
                errdefer gpa.free(c.bloom);
                @memcpy(std.mem.sliceAsBytes(c.bloom), r.b[r.pos..][0 .. @as(usize, words) * 8]);
                r.pos += @as(usize, words) * 8;
                if (c.off + c.len > s.data_end) return error.Corrupt;
                s.seq = @max(s.seq, c.max_seq);
                try run.chunks.append(gpa, c);
                run.bytes += c.len;
            }
            return run;
        }

        fn replayManifest(s: *Self) !void {
            const gpa = s.gpa;
            const len = try s.manifest.length(s.io);
            const bytes = try gpa.alloc(u8, len);
            defer gpa.free(bytes);
            if (try s.manifest.readPositionalAll(s.io, bytes, 0) != len) return error.Corrupt;
            var pos: usize = 0;
            while (pos + 9 <= len) {
                const body_len = std.mem.readInt(u32, bytes[pos..][0..4], .little);
                if (pos + 8 + body_len > len or body_len == 0) break;
                const body = bytes[pos + 8 ..][0..body_len];
                if (record.Crc32c.hash(body) != std.mem.readInt(u32, bytes[pos + 4 ..][0..4], .little)) break;
                try s.applyManifest(body);
                pos += 8 + body_len;
            }
            // A torn tail is cut off; the next append lands after the good part.
            s.man_len = pos;
            s.man_base = pos;
        }

        fn applyManifest(s: *Self, body: []const u8) !void {
            const gpa = s.gpa;
            var r: Reader = .{ .b = body, .pos = 1 };
            switch (@as(Op, @enumFromInt(body[0]))) {
                .stream => {
                    const name = try r.str();
                    const exists = s.streams.contains(name);
                    const st = try s.streamNamedReplay(name);
                    if (!exists) {
                        st.page_off = try r.u(u64);
                        st.floor = try r.u(u64);
                    } else {
                        _ = try r.u(u64);
                        st.floor = @max(st.floor, try r.u(u64));
                    }
                    s.seq = @max(s.seq, st.floor);
                },
                .add_run => {
                    const st = try s.streamNamedReplay(try r.str());
                    st.floor = @max(st.floor, try r.u(u64));
                    s.seq = @max(s.seq, st.floor);
                    var run = try s.readRun(&r);
                    errdefer freeRun(gpa, &run);
                    try st.runs.append(gpa, run);
                },
                .merge => {
                    const st = try s.streamNamedReplay(try r.str());
                    const first = try r.u(u32);
                    const count = try r.u(u32);
                    const has = try r.u(u8);
                    if (first + count > st.runs.items.len or count == 0) return error.Corrupt;
                    var run: ?Run = if (has != 0) try s.readRun(&r) else null;
                    errdefer if (run) |*x| freeRun(gpa, x);
                    // Linked merges move chunks; only free metadata that no
                    // longer appears in the merged run.
                    const old = st.runs.items[first..][0..count];
                    for (old) |*o| {
                        for (o.chunks.items) |*c| c.deinit(gpa);
                        o.chunks.deinit(gpa);
                    }
                    if (run) |x| {
                        st.runs.items[first] = x;
                        run = null;
                        st.runs.replaceRangeAssumeCapacity(first + 1, count - 1, &.{});
                    } else {
                        st.runs.replaceRangeAssumeCapacity(first, count, &.{});
                    }
                },
                .drop => {
                    const st = try s.streamNamedReplay(try r.str());
                    for (st.runs.items) |*x| freeRun(gpa, x);
                    st.runs.clearRetainingCapacity();
                    st.floor = @max(st.floor, try r.u(u64));
                    s.seq = @max(s.seq, st.floor);
                },
                .floor => {
                    const st = try s.streamNamedReplay(try r.str());
                    st.floor = @max(st.floor, try r.u(u64));
                    s.seq = @max(s.seq, st.floor);
                },
                .seq => s.seq = @max(s.seq, try r.u(u64)),
                _ => return error.Corrupt,
            }
        }

        fn streamNamedReplay(s: *Self, name: []const u8) !*Stream {
            if (s.streams.get(name)) |st| return st;
            const gpa = s.gpa;
            const st = try gpa.create(Stream);
            errdefer gpa.destroy(st);
            st.* = .{ .name = try gpa.dupe(u8, name) };
            errdefer gpa.free(st.name);
            try s.streams.put(gpa, st.name, st);
            if (name.len > 0) {
                var lo: usize = 0;
                var hi: usize = s.named.items.len;
                while (lo < hi) {
                    const mid = (lo + hi) / 2;
                    if (std.mem.order(u8, s.named.items[mid].name, name) == .lt) lo = mid + 1 else hi = mid;
                }
                try s.named.insert(gpa, lo, st);
            }
            return st;
        }

        // ------------------------------------------------------- recovery

        const WalReplay = struct {
            s: *Self,
            err: ?anyerror = null,

            pub fn onRecord(r: *WalReplay, _: Log.Location, rec: record.Record) !void {
                const s = r.s;
                if (std.mem.startsWith(u8, rec.key, drop_prefix)) {
                    const st = try s.streamNamed(rec.key[drop_prefix.len..], true);
                    if (rec.seq <= st.floor) return;
                    s.seq = @max(s.seq, rec.seq);
                    s.applyDrop(st);
                    try s.manDrop(st);
                    return;
                }
                const st = try s.streamFor(rec.key);
                if (rec.seq <= st.floor) return;
                const kind: chunk.Kind = switch (rec.kind) {
                    .put => .put,
                    .delete => .del,
                    else => return error.Corrupt,
                };
                try s.tailAdd(st, rec.key, rec.value, rec.seq, kind);
                s.seq = @max(s.seq, rec.seq);
            }
        };

        /// v3: reads each page back. Records newer than the stream's floor,
        /// with good checksums and rising sequence numbers, are its tail.
        fn loadPages(s: *Self) !void {
            const gpa = s.gpa;
            const page = try gpa.alloc(u8, cfg.tail_limit);
            defer gpa.free(page);
            var it = s.streams.valueIterator();
            while (it.next()) |p| {
                const st = p.*;
                try st.buf.ensureTotalCapacity(gpa, 1024);
                const n = try s.data.readPositionalAll(s.io, page, st.page_off);
                var pos: usize = 0;
                var prev = st.floor;
                while (pos + rec_header <= n) {
                    const h = page[pos..n];
                    const kl = std.mem.readInt(u16, h[13..15], .little);
                    const vl = std.mem.readInt(u32, h[15..19], .little);
                    const len = rec_header + @as(usize, kl) + vl;
                    if (len > h.len or kl == 0) break;
                    if (record.Crc32c.hash(h[4..len]) != std.mem.readInt(u32, h[0..4], .little)) break;
                    const seq = std.mem.readInt(u64, h[4..12], .little);
                    if (seq <= prev) break;
                    prev = seq;
                    const off: u32 = @intCast(st.buf.items.len);
                    try st.buf.appendSlice(gpa, h[0..len]);
                    try s.tailIndex(st, off);
                    pos += len;
                }
                st.written = pos;
                s.seq = @max(s.seq, prev);
            }
        }

        // --------------------------------------------------------- info

        pub const Info = struct {
            streams: usize = 0,
            runs: usize = 0,
            chunks: usize = 0,
            tail_bytes: usize = 0,
            /// Fences and blooms held in RAM.
            meta_bytes: usize = 0,
            data_bytes: u64 = 0,
        };

        pub fn info(s: *Self) Info {
            s.lock.lockSharedUncancelable(s.io);
            defer s.lock.unlockShared(s.io);
            var out: Info = .{ .data_bytes = s.data_end };
            var it = s.streams.valueIterator();
            while (it.next()) |p| {
                const st = p.*;
                out.streams += 1;
                out.runs += st.runs.items.len;
                out.tail_bytes += st.buf.capacity;
                for (st.runs.items) |r| for (r.chunks.items) |c| {
                    out.chunks += 1;
                    out.meta_bytes += @sizeOf(ChunkMeta) + c.first.len + c.last.len + c.bloom.len * 8;
                };
            }
            return out;
        }
    };
}

fn syncDir(io: Io, dir: Io.Dir) !void {
    if (builtin.os.tag == .windows) return;
    const handle = try dir.openFile(io, ".", .{});
    defer handle.close(io);
    try handle.sync(io);
}
