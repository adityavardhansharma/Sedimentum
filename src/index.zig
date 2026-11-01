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

        const InsertOut = struct {
            result: GetOrPutResult,
            split: ?Split = null,
        };

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
            const out = try self.insertRec(self.root, self.height, owned);
            if (out.split) |s| {
                errdefer self.gpa.free(s.sep);
                const root = try self.gpa.create(Inner);
                root.* = .{ .len = 1 };
                root.keys[0] = s.sep;
                root.children[0] = self.root;
                root.children[1] = s.right;
                self.root = root;
                self.height += 1;
            }
            self.count += 1;
            self.key_bytes += owned.len;
            return out.result;
        }

        pub fn put(self: *Self, key: []const u8, value: V) Allocator.Error!void {
            const r = try self.getOrPut(key);
            r.value_ptr.* = value;
        }

        /// `owned` is known to be absent from the map.
        fn insertRec(self: *Self, node: *anyopaque, height: u32, owned: []const u8) Allocator.Error!InsertOut {
            if (height == 0) return self.insertLeaf(@ptrCast(@alignCast(node)), owned);

            const inner: *Inner = @ptrCast(@alignCast(node));
            const ci = upperBound(inner.keys[0..inner.len], owned);
            var out = try self.insertRec(inner.children[ci], height - 1, owned);
            const s = out.split orelse return out;
            out.split = null;

            if (inner.len < fanout) {
                insertIntoInner(inner, ci, s);
                return out;
            }
            // Split this inner node, then place the child's split on the right side.
            const right = try self.gpa.create(Inner);
            const mid = fanout / 2;
            const up = inner.keys[mid];
            right.* = .{ .len = @intCast(fanout - mid - 1) };
            @memcpy(right.keys[0..right.len], inner.keys[mid + 1 .. fanout]);
            @memcpy(right.children[0 .. right.len + 1], inner.children[mid + 1 .. fanout + 1]);
            inner.len = mid;
            if (ci <= mid) insertIntoInner(inner, ci, s) else insertIntoInner(right, ci - mid - 1, s);
            out.split = .{ .sep = up, .right = right };
            return out;
        }

        fn insertIntoInner(inner: *Inner, ci: usize, s: Split) void {
            const n = inner.len;
            std.mem.copyBackwards([]const u8, inner.keys[ci + 1 .. n + 1], inner.keys[ci..n]);
            std.mem.copyBackwards(*anyopaque, inner.children[ci + 2 .. n + 2], inner.children[ci + 1 .. n + 1]);
            inner.keys[ci] = s.sep;
            inner.children[ci + 1] = s.right;
            inner.len = n + 1;
        }

        fn insertLeaf(self: *Self, leaf: *Leaf, owned: []const u8) Allocator.Error!InsertOut {
            const pos = lowerBound(leaf.keys[0..leaf.len], owned);
            if (leaf.len < fanout) {
                return .{ .result = insertAt(leaf, pos, owned) };
            }
            // The first key of the new right leaf is the old key at `mid`
            // whichever side the new key lands on.
            const mid = fanout / 2;
            const sep = try self.gpa.dupe(u8, leaf.keys[mid]);
            errdefer self.gpa.free(sep);
            const right = try self.gpa.create(Leaf);
            right.* = .{ .len = fanout - mid, .next = leaf.next, .prev = leaf };
            @memcpy(right.keys[0..right.len], leaf.keys[mid..fanout]);
            @memcpy(right.vals[0..right.len], leaf.vals[mid..fanout]);
            leaf.len = mid;
            const result = if (pos <= mid) insertAt(leaf, pos, owned) else insertAt(right, pos - mid, owned);
            if (leaf.next) |n| n.prev = right;
            leaf.next = right;
            return .{ .result = result, .split = .{ .sep = sep, .right = right } };
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
