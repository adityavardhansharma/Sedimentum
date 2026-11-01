//! An in-memory B+tree from byte keys to values, ordered by `std.mem.order`.
//!
//! Leaves are linked in both directions, so cursors can walk forward and
//! backward without going back through the tree. Deletes remove the key
//! from its leaf but never merge nodes: lookups stay correct because
//! separators remain valid bounds, and empty leaves are skipped by cursors.
//! Space from heavy delete churn is reclaimed when the map is rebuilt.
//!
//! The map owns copies of every key it stores.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const fanout = 64;

pub fn OrderedMap(comptime V: type) type {
    return struct {
        const Self = @This();

        pub const Leaf = struct {
            len: u16 = 0,
            keys: [fanout][]const u8 = undefined,
            vals: [fanout]V = undefined,
            next: ?*Leaf = null,
            prev: ?*Leaf = null,
        };

        const Inner = struct {
            len: u16 = 0,
            /// children[i] holds keys k with keys[i-1] <= k < keys[i].
            keys: [fanout][]const u8 = undefined,
            children: [fanout + 1]*anyopaque = undefined,
        };

        gpa: Allocator,
        root: *anyopaque,
        /// 0 means the root is a leaf.
        height: u32 = 0,
        count: usize = 0,
        /// Bytes of key data owned by leaves (separator copies excluded).
        key_bytes: usize = 0,

        pub fn init(gpa: Allocator) Allocator.Error!Self {
            const leaf = try gpa.create(Leaf);
            leaf.* = .{};
            return .{ .gpa = gpa, .root = leaf };
        }

        pub fn deinit(self: *Self) void {
            self.freeNode(self.root, self.height);
            self.* = undefined;
        }

        fn freeNode(self: *Self, node: *anyopaque, height: u32) void {
            if (height == 0) {
                const leaf: *Leaf = @ptrCast(@alignCast(node));
                for (leaf.keys[0..leaf.len]) |k| self.gpa.free(k);
                self.gpa.destroy(leaf);
                return;
            }
            const inner: *Inner = @ptrCast(@alignCast(node));
            for (inner.children[0 .. inner.len + 1]) |child| self.freeNode(child, height - 1);
            for (inner.keys[0..inner.len]) |k| self.gpa.free(k);
            self.gpa.destroy(inner);
        }

        // ------------------------------------------------------------ search

        /// Index of the first key in `keys` that is >= `key`.
        fn lowerBound(keys: []const []const u8, key: []const u8) usize {
            var lo: usize = 0;
            var hi: usize = keys.len;
            while (lo < hi) {
                const mid = lo + (hi - lo) / 2;
                if (std.mem.order(u8, keys[mid], key) == .lt) lo = mid + 1 else hi = mid;
            }
            return lo;
        }

        /// Index of the first key in `keys` that is > `key`.
        fn upperBound(keys: []const []const u8, key: []const u8) usize {
            var lo: usize = 0;
            var hi: usize = keys.len;
            while (lo < hi) {
                const mid = lo + (hi - lo) / 2;
                if (std.mem.order(u8, keys[mid], key) == .gt) hi = mid else lo = mid + 1;
            }
            return lo;
        }

        fn findLeaf(self: *const Self, key: []const u8) *Leaf {
            var node = self.root;
            var h = self.height;
            while (h > 0) : (h -= 1) {
                const inner: *Inner = @ptrCast(@alignCast(node));
                node = inner.children[upperBound(inner.keys[0..inner.len], key)];
            }
            return @ptrCast(@alignCast(node));
        }

        pub fn getPtr(self: *const Self, key: []const u8) ?*V {
            const leaf = self.findLeaf(key);
            const i = lowerBound(leaf.keys[0..leaf.len], key);
            if (i < leaf.len and std.mem.eql(u8, leaf.keys[i], key)) return &leaf.vals[i];
            return null;
        }

        pub fn get(self: *const Self, key: []const u8) ?V {
            return if (self.getPtr(key)) |p| p.* else null;
        }

        // ------------------------------------------------------------ insert

        pub const GetOrPutResult = struct {
            value_ptr: *V,
            /// The map's own copy of the key.
            key: []const u8,
            found_existing: bool,
        };

        const Split = struct { sep: []const u8, right: *anyopaque };

        /// Deeper than any tree that fits in memory (fanout 64).
        const max_height = 24;

        /// Finds `key` or inserts it with an undefined value the caller must set.
        pub fn getOrPut(self: *Self, key: []const u8) Allocator.Error!GetOrPutResult {
            {
                const leaf = self.findLeaf(key);
                const i = lowerBound(leaf.keys[0..leaf.len], key);
                if (i < leaf.len and std.mem.eql(u8, leaf.keys[i], key)) {
                    return .{ .value_ptr = &leaf.vals[i], .key = leaf.keys[i], .found_existing = true };
                }
            }
            const owned = try self.gpa.dupe(u8, key);
            errdefer self.gpa.free(owned);
            return self.insertNewOwned(owned);
        }

        pub fn put(self: *Self, key: []const u8, value: V) Allocator.Error!void {
            const r = try self.getOrPut(key);
            r.value_ptr.* = value;
        }

        /// Inserts a key the caller knows is absent, taking ownership of
        /// `owned` (allocated with this map's allocator) on success. Skips
        /// the lookup `getOrPut` does first.
        ///
        /// Every node a split needs is allocated before the tree changes,
        /// so a failed allocation leaves the tree exactly as it was.
        pub fn insertNewOwned(self: *Self, owned: []const u8) Allocator.Error!GetOrPutResult {
            // Walk down, remembering the path.
            var path: [max_height]*Inner = undefined;
            var slots: [max_height]usize = undefined;
            var node = self.root;
            var depth: usize = 0;
            while (depth < self.height) : (depth += 1) {
                const inner: *Inner = @ptrCast(@alignCast(node));
                const ci = upperBound(inner.keys[0..inner.len], owned);
                path[depth] = inner;
                slots[depth] = ci;
                node = inner.children[ci];
            }
            const leaf: *Leaf = @ptrCast(@alignCast(node));
            const pos = lowerBound(leaf.keys[0..leaf.len], owned);
            if (leaf.len < fanout) return self.inserted(insertAt(leaf, pos, owned));

            // Count the full inner nodes above the leaf that will split too.
            var full: usize = 0;
            while (full < depth and path[depth - 1 - full].len == fanout) full += 1;
            const new_root = full == depth;

            // Allocate everything up front.
            const mid = fanout / 2;
            const sep = try self.gpa.dupe(u8, leaf.keys[mid]);
            errdefer self.gpa.free(sep);
            const right_leaf = try self.gpa.create(Leaf);
            errdefer self.gpa.destroy(right_leaf);
            var rights: [max_height]*Inner = undefined;
            var made: usize = 0;
            errdefer for (rights[0..made]) |r| self.gpa.destroy(r);
            while (made < full) : (made += 1) rights[made] = try self.gpa.create(Inner);
            const root: ?*Inner = if (new_root) try self.gpa.create(Inner) else null;

            // From here on nothing can fail. Split the leaf; the first key of
            // the new right leaf is the old key at `mid` whichever side the
            // new key lands on.
            right_leaf.* = .{ .len = fanout - mid, .next = leaf.next, .prev = leaf };
            @memcpy(right_leaf.keys[0..right_leaf.len], leaf.keys[mid..fanout]);
            @memcpy(right_leaf.vals[0..right_leaf.len], leaf.vals[mid..fanout]);
            leaf.len = mid;
            const result = if (pos <= mid) insertAt(leaf, pos, owned) else insertAt(right_leaf, pos - mid, owned);
            if (leaf.next) |n| n.prev = right_leaf;
            leaf.next = right_leaf;

            // Carry the split up the path.
            var split: ?Split = .{ .sep = sep, .right = right_leaf };
            var d = depth;
            var used: usize = 0;
            while (d > 0 and split != null) {
                d -= 1;
                const inner = path[d];
                const ci = slots[d];
                const sp = split.?;
                if (inner.len < fanout) {
                    insertIntoInner(inner, ci, sp);
                    split = null;
                    break;
                }
                const right = rights[used];
                used += 1;
                const up = inner.keys[mid];
                right.* = .{ .len = @intCast(fanout - mid - 1) };
                @memcpy(right.keys[0..right.len], inner.keys[mid + 1 .. fanout]);
                @memcpy(right.children[0 .. right.len + 1], inner.children[mid + 1 .. fanout + 1]);
                inner.len = mid;
                if (ci <= mid) insertIntoInner(inner, ci, sp) else insertIntoInner(right, ci - mid - 1, sp);
                split = .{ .sep = up, .right = right };
            }
            std.debug.assert(used == full);
            if (split) |sp| {
                const r = root.?;
                r.* = .{ .len = 1 };
                r.keys[0] = sp.sep;
                r.children[0] = self.root;
                r.children[1] = sp.right;
                self.root = r;
                self.height += 1;
            } else std.debug.assert(root == null);
            return self.inserted(result);
        }

        fn inserted(self: *Self, r: GetOrPutResult) GetOrPutResult {
            self.count += 1;
            self.key_bytes += r.key.len;
            return r;
        }

        /// Replaces an empty map with `keys` (sorted, unique) and `vals`,
        /// filling leaves to 3/4. Linear time: no searches. The map takes
        /// ownership of the keys only on success; on failure it is empty
        /// again and the caller still owns them.
        pub fn buildSorted(self: *Self, keys: []const []const u8, vals: []const V) Allocator.Error!void {
            std.debug.assert(self.count == 0 and self.height == 0);
            std.debug.assert(keys.len == vals.len);
            if (keys.len == 0) return;
            const fill = fanout * 3 / 4;
            const gpa = self.gpa;
            const first_leaf: *Leaf = @ptrCast(@alignCast(self.root));
            const leaf_count = (keys.len + fill - 1) / fill;

            // Bookkeeping is sized up front so only node allocations can fail.
            var level: std.ArrayList(*anyopaque) = try .initCapacity(gpa, leaf_count);
            defer level.deinit(gpa);
            var firsts: std.ArrayList([]const u8) = try .initCapacity(gpa, leaf_count);
            defer firsts.deinit(gpa);
            var next_level: std.ArrayList(*anyopaque) = try .initCapacity(gpa, leaf_count);
            defer next_level.deinit(gpa);
            var next_firsts: std.ArrayList([]const u8) = try .initCapacity(gpa, leaf_count);
            defer next_firsts.deinit(gpa);
            var inners: std.ArrayList(*Inner) = try .initCapacity(gpa, leaf_count + max_height);
            defer inners.deinit(gpa);
            errdefer {
                for (inners.items) |inner| {
                    for (inner.keys[0..inner.len]) |k| gpa.free(k);
                    gpa.destroy(inner);
                }
                var l = first_leaf.next;
                while (l) |n| {
                    l = n.next;
                    gpa.destroy(n);
                }
                first_leaf.* = .{};
            }

            // Leaves.
            var leaf = first_leaf;
            var i: usize = 0;
            while (i < keys.len) {
                if (i > 0) {
                    const next = try gpa.create(Leaf);
                    next.* = .{ .prev = leaf };
                    leaf.next = next;
                    leaf = next;
                }
                const n = @min(fill, keys.len - i);
                @memcpy(leaf.keys[0..n], keys[i..][0..n]);
                @memcpy(leaf.vals[0..n], vals[i..][0..n]);
                leaf.len = @intCast(n);
                level.appendAssumeCapacity(leaf);
                firsts.appendAssumeCapacity(keys[i]);
                i += n;
            }

            // Inner levels: children[j] starts at firsts[j]; separators are
            // copies of firsts[1..] within each node.
            var height: u32 = 0;
            while (level.items.len > 1) {
                next_level.clearRetainingCapacity();
                next_firsts.clearRetainingCapacity();
                var j: usize = 0;
                while (j < level.items.len) {
                    const n = @min(fill + 1, level.items.len - j);
                    const inner = try gpa.create(Inner);
                    inner.* = .{ .len = 0 };
                    inners.appendAssumeCapacity(inner);
                    @memcpy(inner.children[0..n], level.items[j..][0..n]);
                    for (1..n) |c| {
                        inner.keys[c - 1] = try gpa.dupe(u8, firsts.items[j + c]);
                        inner.len += 1;
                    }
                    next_level.appendAssumeCapacity(inner);
                    next_firsts.appendAssumeCapacity(firsts.items[j]);
                    j += n;
                }
                std.mem.swap(std.ArrayList(*anyopaque), &level, &next_level);
                std.mem.swap(std.ArrayList([]const u8), &firsts, &next_firsts);
                height += 1;
            }
            self.root = level.items[0];
            self.height = height;
            self.count = keys.len;
            for (keys) |k| self.key_bytes += k.len;
        }

        fn insertIntoInner(inner: *Inner, ci: usize, s: Split) void {
            const n = inner.len;
            std.mem.copyBackwards([]const u8, inner.keys[ci + 1 .. n + 1], inner.keys[ci..n]);
            std.mem.copyBackwards(*anyopaque, inner.children[ci + 2 .. n + 2], inner.children[ci + 1 .. n + 1]);
            inner.keys[ci] = s.sep;
            inner.children[ci + 1] = s.right;
            inner.len = n + 1;
        }

        fn insertAt(leaf: *Leaf, pos: usize, owned: []const u8) GetOrPutResult {
            const n = leaf.len;
            std.mem.copyBackwards([]const u8, leaf.keys[pos + 1 .. n + 1], leaf.keys[pos..n]);
            std.mem.copyBackwards(V, leaf.vals[pos + 1 .. n + 1], leaf.vals[pos..n]);
            leaf.keys[pos] = owned;
            leaf.len = n + 1;
            return .{ .value_ptr = &leaf.vals[pos], .key = owned, .found_existing = false };
        }

        fn removeAt(leaf: *Leaf, pos: usize) struct { key: []const u8, val: V } {
            const key = leaf.keys[pos];
            const val = leaf.vals[pos];
            const n = leaf.len;
            std.mem.copyForwards([]const u8, leaf.keys[pos .. n - 1], leaf.keys[pos + 1 .. n]);
            std.mem.copyForwards(V, leaf.vals[pos .. n - 1], leaf.vals[pos + 1 .. n]);
            leaf.len = n - 1;
            return .{ .key = key, .val = val };
        }

        // ------------------------------------------------------------ delete

        /// Removes `key` and returns its value, or null if it was absent.
        pub fn remove(self: *Self, key: []const u8) ?V {
            const leaf = self.findLeaf(key);
            const i = lowerBound(leaf.keys[0..leaf.len], key);
            if (i >= leaf.len or !std.mem.eql(u8, leaf.keys[i], key)) return null;
            const r = removeAt(leaf, i);
            self.count -= 1;
            self.key_bytes -= r.key.len;
            self.gpa.free(r.key);
            return r.val;
        }

        // ------------------------------------------------------------ cursors

        pub const Cursor = struct {
            leaf: ?*Leaf,
            idx: usize,

            pub fn valid(c: Cursor) bool {
                return c.leaf != null;
            }

            pub fn key(c: Cursor) []const u8 {
                return c.leaf.?.keys[c.idx];
            }

            pub fn valuePtr(c: Cursor) *V {
                return &c.leaf.?.vals[c.idx];
            }

            /// Moves to the next key, or becomes invalid.
            pub fn next(c: *Cursor) void {
                var leaf = c.leaf orelse return;
                if (c.idx + 1 < leaf.len) {
                    c.idx += 1;
                    return;
                }
                while (leaf.next) |n| {
                    if (n.len > 0) {
                        c.* = .{ .leaf = n, .idx = 0 };
                        return;
                    }
                    leaf = n;
                }
                c.leaf = null;
            }

            /// Moves to the previous key, or becomes invalid.
            pub fn prev(c: *Cursor) void {
                var leaf = c.leaf orelse return;
                if (c.idx > 0) {
                    c.idx -= 1;
                    return;
                }
                while (leaf.prev) |p| {
                    if (p.len > 0) {
                        c.* = .{ .leaf = p, .idx = p.len - 1 };
                        return;
                    }
                    leaf = p;
                }
                c.leaf = null;
            }
        };

        /// Cursor at the first key >= `key`.
        pub fn seek(self: *const Self, key: []const u8) Cursor {
            const leaf = self.findLeaf(key);
            const i = lowerBound(leaf.keys[0..leaf.len], key);
            if (i < leaf.len) return .{ .leaf = leaf, .idx = i };
            var c: Cursor = .{ .leaf = leaf, .idx = if (leaf.len == 0) 0 else leaf.len - 1 };
            if (leaf.len == 0) {
                // Walk forward to the first non-empty leaf.
                var l = leaf.next;
                while (l) |n| : (l = n.next) if (n.len > 0) return .{ .leaf = n, .idx = 0 };
                return .{ .leaf = null, .idx = 0 };
            }
            c.next();
            return c;
        }

        /// Cursor at the last key < `key`.
        pub fn seekBefore(self: *const Self, key: []const u8) Cursor {
            const leaf = self.findLeaf(key);
            const i = lowerBound(leaf.keys[0..leaf.len], key);
            if (i > 0) return .{ .leaf = leaf, .idx = i - 1 };
            var l = leaf.prev;
            while (l) |p| : (l = p.prev) if (p.len > 0) return .{ .leaf = p, .idx = p.len - 1 };
            return .{ .leaf = null, .idx = 0 };
        }

        pub fn first(self: *const Self) Cursor {
            return self.seek("");
        }

        pub fn last(self: *const Self) Cursor {
            var node = self.root;
            var h = self.height;
            while (h > 0) : (h -= 1) {
                const inner: *Inner = @ptrCast(@alignCast(node));
                node = inner.children[inner.len];
            }
            var leaf: ?*Leaf = @ptrCast(@alignCast(node));
            while (leaf) |l| : (leaf = l.prev) if (l.len > 0) return .{ .leaf = l, .idx = l.len - 1 };
            return .{ .leaf = null, .idx = 0 };
        }
    };
}

/// An `OrderedMap` plus a hash table over the same keys. Point lookups go
/// through the hash table (a couple of cache misses instead of one per
/// tree comparison); ordered scans use the tree. Values live in a pool so
/// both structures can point at them.
pub fn HashedIndex(comptime V: type) type {
    return struct {
        const Self = @This();
        const Tree = OrderedMap(*V);

        gpa: Allocator,
        tree: Tree,
        /// Keys borrow the tree's own copies, which never move.
        hash: std.StringHashMapUnmanaged(*V) = .empty,
        pool: std.heap.MemoryPool(V) = .empty,
        /// While bulk loading, only the hash table is maintained (it owns
        /// the keys) and `finishBulk` builds the tree in one pass.
        bulk: bool = false,

        pub fn init(gpa: Allocator) Allocator.Error!Self {
            return .{ .gpa = gpa, .tree = try Tree.init(gpa) };
        }

        pub fn deinit(self: *Self) void {
            if (self.bulk) {
                var it = self.hash.keyIterator();
                while (it.next()) |k| self.gpa.free(k.*);
            }
            self.hash.deinit(self.gpa);
            self.pool.deinit(self.gpa);
            self.tree.deinit();
            self.* = undefined;
        }

        pub fn len(self: *const Self) usize {
            return self.tree.count;
        }

        /// Bytes of key data stored.
        pub fn keyBytes(self: *const Self) usize {
            return self.tree.key_bytes;
        }

        pub fn getPtr(self: *const Self, key: []const u8) ?*V {
            return self.hash.get(key);
        }

        pub fn get(self: *const Self, key: []const u8) ?V {
            return if (self.hash.get(key)) |p| p.* else null;
        }

        pub const GetOrPutResult = struct {
            value_ptr: *V,
            key: []const u8,
            found_existing: bool,
        };

        /// Finds `key` or inserts it with an undefined value the caller must set.
        pub fn getOrPut(self: *Self, key: []const u8) Allocator.Error!GetOrPutResult {
            if (self.bulk) return self.getOrPutBulk(key);
            if (self.hash.getEntry(key)) |e| {
                return .{ .value_ptr = e.value_ptr.*, .key = e.key_ptr.*, .found_existing = true };
            }
            try self.hash.ensureUnusedCapacity(self.gpa, 1);
            const v = try self.pool.create(self.gpa);
            errdefer self.pool.destroy(v);
            const owned = try self.gpa.dupe(u8, key);
            if (self.bulk) {
                self.hash.putAssumeCapacityNoClobber(owned, v);
                return .{ .value_ptr = v, .key = owned, .found_existing = false };
            }
            errdefer self.gpa.free(owned);
            const r = try self.tree.insertNewOwned(owned);
            r.value_ptr.* = v;
            self.hash.putAssumeCapacityNoClobber(r.key, v);
            return .{ .value_ptr = v, .key = r.key, .found_existing = false };
        }

        pub fn put(self: *Self, key: []const u8, value: V) Allocator.Error!void {
            const r = try self.getOrPut(key);
            r.value_ptr.* = value;
        }

        fn getOrPutBulk(self: *Self, key: []const u8) Allocator.Error!GetOrPutResult {
            const gop = try self.hash.getOrPut(self.gpa, key);
            if (gop.found_existing) {
                return .{ .value_ptr = gop.value_ptr.*, .key = gop.key_ptr.*, .found_existing = true };
            }
            errdefer self.hash.removeByPtr(gop.key_ptr);
            const v = try self.pool.create(self.gpa);
            errdefer self.pool.destroy(v);
            const owned = try self.gpa.dupe(u8, key);
            gop.key_ptr.* = owned;
            gop.value_ptr.* = v;
            return .{ .value_ptr = v, .key = owned, .found_existing = false };
        }

        pub fn remove(self: *Self, key: []const u8) ?V {
            // Drop the hash entry first: it borrows the key the tree frees.
            const kv = self.hash.fetchRemove(key) orelse return null;
            const value = kv.value.*;
            if (self.bulk) self.gpa.free(kv.key) else _ = self.tree.remove(key);
            self.pool.destroy(kv.value);
            return value;
        }

        /// Builds the tree from the hash table after a bulk load.
        pub fn finishBulk(self: *Self) Allocator.Error!void {
            std.debug.assert(self.bulk);
            const n = self.hash.count();
            const items = try self.gpa.alloc(SortItem(V), n);
            defer self.gpa.free(items);
            var it = self.hash.iterator();
            var i: usize = 0;
            while (it.next()) |e| : (i += 1) items[i] = .{ .key = e.key_ptr.*, .val = e.value_ptr.* };
            sortKeys(V, items, 0);
            const keys = try self.gpa.alloc([]const u8, n);
            defer self.gpa.free(keys);
            const vals = try self.gpa.alloc(*V, n);
            defer self.gpa.free(vals);
            for (items, keys, vals) |kv, *k, *v| {
                k.* = kv.key;
                v.* = kv.val;
            }
            // The tree takes ownership of the key copies the hash made.
            try self.tree.buildSorted(keys, vals);
            self.bulk = false;
        }

        pub const Cursor = struct {
            inner: Tree.Cursor,

            pub fn valid(c: Cursor) bool {
                return c.inner.valid();
            }
            pub fn key(c: Cursor) []const u8 {
                return c.inner.key();
            }
            pub fn valuePtr(c: Cursor) *V {
                return c.inner.valuePtr().*;
            }
            pub fn next(c: *Cursor) void {
                c.inner.next();
            }
            pub fn prev(c: *Cursor) void {
                c.inner.prev();
            }
            pub fn invalidate(c: *Cursor) void {
                c.inner.leaf = null;
            }
        };

        pub fn seek(self: *const Self, key: []const u8) Cursor {
            return .{ .inner = self.tree.seek(key) };
        }
        pub fn seekBefore(self: *const Self, key: []const u8) Cursor {
            return .{ .inner = self.tree.seekBefore(key) };
        }
        pub fn first(self: *const Self) Cursor {
            return .{ .inner = self.tree.first() };
        }
        pub fn last(self: *const Self) Cursor {
            return .{ .inner = self.tree.last() };
        }
    };
}

fn SortItem(comptime V: type) type {
    return struct {
        key: []const u8,
        val: *V,
        /// Next 8 key bytes at the current depth, big endian, zero padded.
        head: u64 = 0,
        /// Key length if the key ends within this chunk, else maxInt.
        tie: usize = 0,
    };
}

/// Sorts unique keys by comparing 8-byte chunks held inline, one depth at a
/// time, so each level touches each key's bytes once instead of on every
/// comparison. Much faster than a comparison sort on scattered keys.
fn sortKeys(comptime V: type, items: []SortItem(V), depth: usize) void {
    if (items.len < 2) return;
    for (items) |*it| {
        var chunk: [8]u8 = @splat(0);
        if (it.key.len > depth) {
            const n = @min(8, it.key.len - depth);
            @memcpy(chunk[0..n], it.key[depth..][0..n]);
        }
        it.head = std.mem.readInt(u64, &chunk, .big);
        it.tie = if (it.key.len <= depth + 8) it.key.len else std.math.maxInt(usize);
    }
    const Item = SortItem(V);
    std.mem.sortUnstable(Item, items, {}, struct {
        fn lt(_: void, a: Item, b: Item) bool {
            if (a.head != b.head) return a.head < b.head;
            return a.tie < b.tie;
        }
    }.lt);
    var start: usize = 0;
    while (start < items.len) {
        var end = start + 1;
        while (end < items.len and items[end].head == items[start].head and items[end].tie == items[start].tie) end += 1;
        // Keys that end in this chunk are unique by length; only longer
        // keys with equal chunks need the next level.
        if (end - start > 1 and items[start].tie == std.math.maxInt(usize)) {
            sortKeys(V, items[start..end], depth + 8);
        }
        start = end;
    }
}

/// The smallest key greater than every key starting with `prefix`, written
/// into `buf`, or null if no such key exists (prefix is all 0xff or empty).
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

// -------------------------------------------------------------------- tests

const testing = std.testing;

test "basic put, get, remove" {
    var m = try OrderedMap(u32).init(testing.allocator);
    defer m.deinit();
    try m.put("b", 2);
    try m.put("a", 1);
    try m.put("c", 3);
    try m.put("b", 20);
    try testing.expectEqual(@as(usize, 3), m.count);
    try testing.expectEqual(@as(?u32, 20), m.get("b"));
    try testing.expectEqual(@as(?u32, null), m.get("d"));
    try testing.expectEqual(@as(?u32, 1), m.remove("a"));
    try testing.expectEqual(@as(?u32, null), m.remove("a"));
    try testing.expectEqual(@as(usize, 2), m.count);
}

test "prefixEnd" {
    var buf: [8]u8 = undefined;
    try testing.expectEqualStrings("ab", prefixEnd("aa", &buf).?);
    try testing.expectEqualStrings("b", prefixEnd("a\xff", &buf).?);
    try testing.expect(prefixEnd("\xff\xff", &buf) == null);
    try testing.expect(prefixEnd("", &buf) == null);
}

test "randomized against a sorted reference" {
    const gpa = testing.allocator;
    var m = try OrderedMap(u64).init(gpa);
    defer m.deinit();
    var ref = std.StringHashMap(u64).init(gpa);
    defer {
        var it = ref.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        ref.deinit();
    }

    var prng = std.Random.DefaultPrng.init(0x5ed1);
    const rand = prng.random();
    var i: u64 = 0;
    while (i < 20_000) : (i += 1) {
        var kb: [12]u8 = undefined;
        const key = std.fmt.bufPrint(&kb, "k{d}", .{rand.uintLessThan(u32, 3000)}) catch unreachable;
        if (rand.uintLessThan(u8, 4) == 0) {
            const a = m.remove(key);
            const b = ref.fetchRemove(key);
            try testing.expectEqual(b != null, a != null);
            if (b) |kv| {
                try testing.expectEqual(kv.value, a.?);
                gpa.free(kv.key);
            }
        } else {
            try m.put(key, i);
            const gop = try ref.getOrPut(key);
            if (!gop.found_existing) gop.key_ptr.* = try gpa.dupe(u8, key);
            gop.value_ptr.* = i;
        }
    }
    try testing.expectEqual(ref.count(), m.count);

    // Collect and sort the reference keys.
    var keys: std.ArrayList([]const u8) = .empty;
    defer keys.deinit(gpa);
    var it = ref.keyIterator();
    while (it.next()) |k| try keys.append(gpa, k.*);
    std.mem.sortUnstable([]const u8, keys.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);

    // Forward.
    var c = m.first();
    for (keys.items) |k| {
        try testing.expect(c.valid());
        try testing.expectEqualStrings(k, c.key());
        try testing.expectEqual(ref.get(k).?, c.valuePtr().*);
        c.next();
    }
    try testing.expect(!c.valid());

    // Backward.
    c = m.last();
    var j = keys.items.len;
    while (j > 0) : (j -= 1) {
        try testing.expectEqualStrings(keys.items[j - 1], c.key());
        c.prev();
    }
    try testing.expect(!c.valid());

    // Seeks.
    for ([_][]const u8{ "", "k1", "k15", "k2999", "k5", "z" }) |probe| {
        const s = m.seek(probe);
        const b = m.seekBefore(probe);
        var lb: usize = 0;
        while (lb < keys.items.len and std.mem.order(u8, keys.items[lb], probe) == .lt) lb += 1;
        if (lb < keys.items.len) try testing.expectEqualStrings(keys.items[lb], s.key()) else try testing.expect(!s.valid());
        if (lb > 0) try testing.expectEqualStrings(keys.items[lb - 1], b.key()) else try testing.expect(!b.valid());
    }
}

test "cursors skip leaves emptied by deletes" {
    var m = try OrderedMap(u32).init(testing.allocator);
    defer m.deinit();
    var kb: [8]u8 = undefined;
    var i: u32 = 0;
    while (i < 1000) : (i += 1) try m.put(std.fmt.bufPrint(&kb, "{d:0>5}", .{i}) catch unreachable, i);
    i = 100;
    while (i < 900) : (i += 1) _ = m.remove(std.fmt.bufPrint(&kb, "{d:0>5}", .{i}) catch unreachable);

    var c = m.seek("00099");
    try testing.expectEqualStrings("00099", c.key());
    c.next();
    try testing.expectEqualStrings("00900", c.key());
    c.prev();
    try testing.expectEqualStrings("00099", c.key());
    try testing.expectEqualStrings("00900", m.seek("00500").key());
    try testing.expectEqualStrings("00099", m.seekBefore("00500").key());
}

test "hashed index keeps the hash and the tree in step" {
    var m = try HashedIndex(u64).init(testing.allocator);
    defer m.deinit();
    var kb: [12]u8 = undefined;
    for (0..5000) |i| try m.put(std.fmt.bufPrint(&kb, "k{d:0>5}", .{i}) catch unreachable, i);
    for (0..5000) |i| if (i % 3 == 0) {
        try testing.expectEqual(@as(?u64, i), m.remove(std.fmt.bufPrint(&kb, "k{d:0>5}", .{i}) catch unreachable));
    };
    try testing.expectEqual(@as(?u64, 4), m.get("k00004"));
    try testing.expectEqual(@as(?u64, null), m.get("k00003"));
    var c = m.seek("k00003");
    try testing.expectEqualStrings("k00004", c.key());
    try testing.expectEqual(@as(u64, 4), c.valuePtr().*);
    c.prev();
    try testing.expectEqualStrings("k00002", c.key());
    try testing.expectEqual(m.tree.count, m.hash.count());
}

test "bulk load builds the same ordered view" {
    var m = try HashedIndex(u64).init(testing.allocator);
    defer m.deinit();
    m.bulk = true;
    var prng = std.Random.DefaultPrng.init(3);
    var kb: [12]u8 = undefined;
    for (0..10_000) |i| try m.put(std.fmt.bufPrint(&kb, "k{d:0>6}", .{prng.random().uintLessThan(u32, 20_000)}) catch unreachable, i);
    for (0..2000) |i| _ = m.remove(std.fmt.bufPrint(&kb, "k{d:0>6}", .{i}) catch unreachable);
    try m.put("k0", 7);
    try m.put("k0\x00", 8);
    try m.put("k000000000000000000", 9);
    try m.finishBulk();
    try testing.expectEqual(m.hash.count(), m.len());
    var c = m.first();
    var prev: []const u8 = "";
    var n: usize = 0;
    while (c.valid()) : (c.next()) {
        try testing.expect(std.mem.order(u8, prev, c.key()) == .lt);
        try testing.expectEqual(m.get(c.key()).?, c.valuePtr().*);
        prev = c.key();
        n += 1;
    }
    try testing.expectEqual(m.len(), n);
    // Normal inserts and seeks keep working on the bulk-built tree.
    try m.put("k000000x", 1);
    try testing.expectEqualStrings("k000000x", m.seek("k000000x").key());
    try testing.expectEqual(m.len(), m.hash.count());
}

fn checkTree(map: anytype, want: usize) !void {
    try std.testing.expectEqual(want, map.count);
    var c = map.first();
    var n: usize = 0;
    var prev: []const u8 = "";
    while (c.valid()) : (c.next()) {
        if (n > 0) try std.testing.expect(std.mem.order(u8, prev, c.key()) == .lt);
        try std.testing.expect(map.getPtr(c.key()) != null);
        prev = c.key();
        n += 1;
    }
    try std.testing.expectEqual(want, n);
}

test "a failed insert leaves the tree unchanged" {
    const backing = std.testing.allocator;
    var fa = std.testing.FailingAllocator.init(backing, .{});
    var map = try OrderedMap(u32).init(fa.allocator());
    defer map.deinit();
    var buf: [16]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(3);
    const total = 6000;
    for (0..total) |i| {
        const k = std.fmt.bufPrint(&buf, "{d:0>12}", .{prng.random().int(u32)}) catch unreachable;
        if (map.getPtr(k) != null) continue;
        const owned = try backing.dupe(u8, k);
        var ok = false;
        for (0..4) |extra| {
            fa.fail_index = fa.alloc_index + extra;
            if (map.insertNewOwned(owned)) |r| {
                r.value_ptr.* = @intCast(i);
                ok = true;
                break;
            } else |_| {}
        }
        fa.fail_index = std.math.maxInt(usize);
        if (!ok) (try map.insertNewOwned(owned)).value_ptr.* = @intCast(i);
        if (i % 500 == 0) try checkTree(&map, map.count);
    }
    try checkTree(&map, map.count);
}

test "a failed bulk build leaves the hashed index usable" {
    const backing = std.testing.allocator;
    var buf: [16]u8 = undefined;
    var fail_at: usize = 0;
    while (true) : (fail_at += 1) {
        var fa = std.testing.FailingAllocator.init(backing, .{});
        var idx = try HashedIndex(u32).init(fa.allocator());
        defer idx.deinit();
        idx.bulk = true;
        for (0..3000) |i| try idx.put(std.fmt.bufPrint(&buf, "k{d}", .{i}) catch unreachable, @intCast(i));
        fa.fail_index = fa.alloc_index + fail_at;
        if (idx.finishBulk()) |_| {
            try checkTree(&idx.tree, 3000);
            break;
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expect(idx.bulk);
            try std.testing.expectEqual(@as(usize, 0), idx.tree.count);
        }
    }
    try std.testing.expect(fail_at > 3);
}
