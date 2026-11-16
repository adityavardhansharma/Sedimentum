//! The weave: the schema a store learns from its own claims.
//!
//! A claim is a memory that names something rare: a word the store has
//! seen only a few times (a name) next to a word it has rarely or never
//! seen (a value). Loom keeps the words around those rare words for every
//! claim, and from all claims together it learns three things, with no
//! model and no labels beyond what the writer already gives:
//!
//!   Frames  the ways claims are worded ("<name> is deployed in the <value>
//!           region"). A word belongs to a frame's wording when it recurs
//!           across the frame's claims; the names and values change from
//!           claim to claim, so they fall out of the wording on their own.
//!   Slots   frames that state the same attribute ("... moved over to the
//!           <value> region" is a newer version of "... is deployed in the
//!           <value> region"). Frames join a slot on evidence: versions the
//!           writer tied together with a subject, or, for frames that say
//!           something changed, the one frame that, for every name, was
//!           always stated before them.
//!   Grid    names x slots. Every claim lands in the cell of its name and
//!           its slot; the newest claim of a cell is the current value of
//!           that attribute of that name, and every older one is a past
//!           version. A name is a rare word that is not part of any frame's
//!           wording; when a claim has several, the one stated under the
//!           most slots is the name and the others are values.
//!
//! What one name teaches carries over to every other: a slot learned from
//! the facts a writer tagged links the versions of facts nobody tagged,
//! and a question about a name is matched against the slot's pooled
//! wording, which no single memory's filler words can blur.
//!
//! The weave is rebuilt from scratch (it is cheap: only claims take part)
//! whenever the claims have grown by an eighth, so it always uses the
//! store's current word counts.

const std = @import("std");
const Allocator = std.mem.Allocator;
const words = @import("words.zig");

/// Words kept per claim (the claim's rare words and their neighbours).
pub const max_words = 24;
/// Wording words kept per slot for matching questions.
pub const profile_len = 12;

/// How much more often than chance a word must turn up in claims to count
/// as part of a claim at all (as wording, name or value), on a log scale
/// where 1 means "only ever in claims".
const min_claimness: f32 = 0.35;
/// Cosine a claim needs with a frame to join it.
const join_sim: f32 = 0.5;
/// A word is wording of a frame when at least this share of the frame's
/// claims hold it.
const wording_share: f32 = 0.25;
/// A frame needs this many claims before its wording counts.
const min_frame: u32 = 4;

pub const Slot = struct {
    keys: [profile_len]u64 = @splat(0),
    share: [profile_len]f32 = @splat(0),
    len: u8 = 0,
    claims: u32 = 0,
    frames: u32 = 0,

    pub fn wording(s: *const Slot) []const u64 {
        return s.keys[0..s.len];
    }
};

pub const Cell = struct {
    slot: u32,
    /// The name (a packed word).
    name: u64,
    /// Newest live claim (an ordinal).
    head: u32,
    members: u32,
};

/// Where a claim sits: its cell, and the newest claim it is a version of.
pub const Fact = struct { cell: u32, head: u32, slot: u32 };

pub const Woven = struct {
    arena: std.heap.ArenaAllocator,
    /// Claims given to the weave (live or not).
    claims: usize,
    /// Claims that took part (live, enough words).
    woven: usize = 0,
    frames: usize = 0,
    slots: []Slot = &.{},
    cells: []Cell = &.{},
    facts: std.AutoHashMapUnmanaged(u32, Fact) = .empty,
    /// Name -> its cells.
    names: std.AutoHashMapUnmanaged(u64, []const u32) = .empty,
    /// Claims whose newest version is another claim.
    linked: usize = 0,
    /// Frames joined into another frame's slot, by kind of evidence.
    joined_by_subject: usize = 0,

    pub fn deinit(wv: *Woven, gpa: Allocator) void {
        wv.arena.deinit();
        gpa.destroy(wv);
    }

    pub fn factOf(wv: *const Woven, ord: u32) ?Fact {
        return wv.facts.get(ord);
    }

    pub fn cellsOf(wv: *const Woven, name: u64) []const u32 {
        return wv.names.get(name) orelse &.{};
    }

    pub fn bytes(wv: *const Woven) usize {
        return wv.arena.queryCapacity();
    }
};

const Word = struct {
    key: u64,
    cdf: u32 = 0,
    df: u32 = 0,
    claimness: f32 = 0,
    /// Weight in clustering: recurring words weigh most, words seen in one
    /// claim only (fresh values) weigh nothing.
    wt: f32 = 0,
    /// Frames the word turned up in (first pass).
    spread: u32 = 1,
    /// Wording of some frame with enough claims.
    wording: bool = false,
    /// Slots in which it is a name or value.
    slots: u32 = 0,
    last_slot: u32 = std.math.maxInt(u32),
};

const UnionFind = struct {
    parent: []u32,
    fn init(a: Allocator, n: usize) !UnionFind {
        const p = try a.alloc(u32, n);
        for (p, 0..) |*x, i| x.* = @intCast(i);
        return .{ .parent = p };
    }
    fn find(u: *UnionFind, x0: u32) u32 {
        var x = x0;
        while (u.parent[x] != x) {
            u.parent[x] = u.parent[u.parent[x]];
            x = u.parent[x];
        }
        return x;
    }
    fn join(u: *UnionFind, a: u32, b: u32) bool {
        const ra = u.find(a);
        const rb = u.find(b);
        if (ra == rb) return false;
        // The older frame (lower number) stays the root.
        if (ra < rb) u.parent[rb] = ra else u.parent[ra] = rb;
        return true;
    }
};

fn pairKey(a: u32, b: u32) u64 {
    const lo = @min(a, b);
    const hi = @max(a, b);
    return (@as(u64, lo) << 32) | hi;
}

/// One live claim during the weave.
const C = struct {
    ord: u32,
    group: u64,
    cue: bool,
    /// Word indexes of its marked words.
    w0: u32,
    wn: u32,
    frame: u32 = 0,
};

/// Builds the weave. `ords[i]` is claim i's ordinal and `keys[i *
/// max_words ..]` its words (0 padded). `ctx` answers `df(key) u32`
/// (memories holding the word), `alive(ord) bool`, `group(ord) u64` (the
/// claim's subject group, 0 for none) and `count() u64` (memories).
pub fn build(gpa: Allocator, ords: []const u32, keys: []const u64, ctx: anytype) !*Woven {
    const wv = try gpa.create(Woven);
    wv.* = .{ .arena = .init(gpa), .claims = ords.len };
    errdefer wv.deinit(gpa);
    const a = wv.arena.allocator();
    var tmp_arena: std.heap.ArenaAllocator = .init(gpa);
    defer tmp_arena.deinit();
    const t = tmp_arena.allocator();

    // Distinct words of live claims, and how many claims hold each.
    var widx: std.AutoHashMapUnmanaged(u64, u32) = .empty;
    var wl: std.ArrayList(Word) = .empty;
    var live: std.ArrayList(u32) = .empty;
    for (ords, 0..) |ord, i| {
        if (!ctx.alive(ord)) continue;
        try live.append(t, @intCast(i));
        for (keys[i * max_words ..][0..max_words]) |k| {
            if (k == 0) break;
            const gop = try widx.getOrPut(t, k);
            if (!gop.found_existing) {
                gop.value_ptr.* = @intCast(wl.items.len);
                try wl.append(t, .{ .key = k, .df = ctx.df(k) });
            }
            wl.items[gop.value_ptr.*].cdf += 1;
        }
    }
    const nc: f32 = @floatFromInt(@max(live.items.len, 1));
    const n: f32 = @floatFromInt(@max(ctx.count(), 1));
    // A store where nearly everything is a claim cannot tell wording from
    // chatter; then every word counts.
    const scale = @log(@max(n / nc, 1.0));
    for (wl.items) |*w| {
        const cdf: f32 = @floatFromInt(w.cdf);
        const df: f32 = @floatFromInt(@max(w.df, w.cdf));
        if (scale < 1.0) {
            w.claimness = 1;
        } else {
            const lift = (cdf / nc) / ((df + 1) / n);
            w.claimness = std.math.clamp(@log(@max(lift, 1e-9)) / scale, 0, 1);
        }
        w.wt = @log(cdf) * @log(1 + nc / cdf);
    }

    // Each claim keeps its marked words.
    var cs: std.ArrayList(C) = .empty;
    var mw: std.ArrayList(u32) = .empty;
    for (live.items) |i| {
        const w0: u32 = @intCast(mw.items.len);
        var cue = false;
        for (keys[i * max_words ..][0..max_words]) |k| {
            if (k == 0) break;
            const x = widx.get(k).?;
            if (wl.items[x].claimness < min_claimness) continue;
            try mw.append(t, x);
            if (words.isCue(k)) cue = true;
        }
        const wn: u32 = @as(u32, @intCast(mw.items.len)) - w0;
        if (wn < 2) {
            mw.shrinkRetainingCapacity(w0);
            continue;
        }
        try cs.append(t, .{ .ord = ords[i], .group = ctx.group(ords[i]), .cue = cue, .w0 = w0, .wn = wn });
    }
    wv.woven = cs.items.len;
    if (cs.items.len == 0) return wv;

    // Frames, in two passes: the second weighs down words that turned up
    // in many frames (names), so only the wording decides.
    var fr = try cluster(t, cs.items, mw.items, wl.items);
    for (wl.items) |*w| w.spread = 0;
    {
        var it = fr.word_frames.iterator();
        while (it.next()) |e| wl.items[e.key_ptr.*].spread = @intCast(e.value_ptr.items.len);
    }
    for (wl.items) |*w| w.wt /= @floatFromInt(@max(w.spread, 1));
    fr = try cluster(t, cs.items, mw.items, wl.items);
    const nf = fr.size.items.len;
    wv.frames = nf;

    // Wording: words most of a big enough frame's claims hold.
    for (cs.items) |c| {
        const sz = fr.size.items[c.frame];
        if (sz < min_frame) continue;
        for (mw.items[c.w0..][0..c.wn]) |x| {
            const cnt = fr.count(c.frame, x);
            if (@as(f32, @floatFromInt(cnt)) >= wording_share * @as(f32, @floatFromInt(sz))) wl.items[x].wording = true;
        }
    }

    // Names: a claim's marked words that are nobody's wording. Index the
    // claims by name.
    var by_name: std.AutoHashMapUnmanaged(u32, std.ArrayList(u32)) = .empty;
    for (cs.items, 0..) |c, ci| {
        for (mw.items[c.w0..][0..c.wn]) |x| {
            if (wl.items[x].wording) continue;
            const gop = try by_name.getOrPut(t, x);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(t, @intCast(ci));
        }
    }

    // Slots: frames joined on evidence.
    var uf = try UnionFind.init(t, nf);
    // 1. Subjects: the writer said these claims are versions of one fact.
    var groups: std.AutoHashMapUnmanaged(u64, std.ArrayList(u32)) = .empty;
    for (cs.items, 0..) |c, ci| if (c.group != 0) {
        const gop = try groups.getOrPut(t, c.group);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(t, @intCast(ci));
    };
    var evidence: std.AutoHashMapUnmanaged(u64, u32) = .empty;
    {
        var it = groups.valueIterator();
        while (it.next()) |list| {
            const l = list.items;
            for (1..l.len) |j| {
                const fa = cs.items[l[j - 1]].frame;
                const fb = cs.items[l[j]].frame;
                if (fa == fb) continue;
                const gop = try evidence.getOrPut(t, pairKey(fa, fb));
                if (!gop.found_existing) gop.value_ptr.* = 0;
                gop.value_ptr.* += 1;
            }
        }
    }
    // Against it: one name, two frames, two different subjects.
    var conflict: std.AutoHashMapUnmanaged(u64, u32) = .empty;
    {
        var it = by_name.valueIterator();
        while (it.next()) |list| {
            const l = list.items[0..@min(list.items.len, 256)];
            for (l, 0..) |ci, j| for (l[j + 1 ..]) |cj| {
                const x = cs.items[ci];
                const y = cs.items[cj];
                if (x.frame == y.frame or x.group == 0 or y.group == 0 or x.group == y.group) continue;
                const k = pairKey(x.frame, y.frame);
                if (!evidence.contains(k)) continue;
                const gop = try conflict.getOrPut(t, k);
                if (!gop.found_existing) gop.value_ptr.* = 0;
                gop.value_ptr.* += 1;
            };
        }
    }
    {
        const Ev = struct { k: u64, n: u32 };
        var evs: std.ArrayList(Ev) = .empty;
        var it = evidence.iterator();
        while (it.next()) |e| {
            const against = conflict.get(e.key_ptr.*) orelse 0;
            if (e.value_ptr.* > against) try evs.append(t, .{ .k = e.key_ptr.*, .n = e.value_ptr.* });
        }
        std.mem.sortUnstable(Ev, evs.items, {}, struct {
            fn gt(_: void, p: Ev, q: Ev) bool {
                return p.n > q.n or (p.n == q.n and p.k < q.k);
            }
        }.gt);
        for (evs.items) |e| {
            if (uf.join(@intCast(e.k >> 32), @truncate(e.k))) wv.joined_by_subject += 1;
        }
    }
    // Number the slots.
    const slot_of_frame = try t.alloc(u32, nf);
    var nslots: u32 = 0;
    {
        const id_of_root = try t.alloc(u32, nf);
        @memset(id_of_root, std.math.maxInt(u32));
        for (0..nf) |f| {
            const r = uf.find(@intCast(f));
            if (id_of_root[r] == std.math.maxInt(u32)) {
                id_of_root[r] = nslots;
                nslots += 1;
            }
            slot_of_frame[f] = id_of_root[r];
        }
    }
    wv.slots = try a.alloc(Slot, nslots);
    for (wv.slots) |*s| s.* = .{};
    for (0..nf) |f| wv.slots[slot_of_frame[f]].frames += 1;
    // Slot wording: wording words of its frames, by the share of the
    // slot's claims that hold them.
    {
        var counts: std.AutoHashMapUnmanaged(u64, u32) = .empty;
        for (cs.items) |c| {
            const s = slot_of_frame[c.frame];
            wv.slots[s].claims += 1;
            for (mw.items[c.w0..][0..c.wn]) |x| {
                if (!wl.items[x].wording) continue;
                const gop = try counts.getOrPut(t, (@as(u64, s) << 32) | x);
                if (!gop.found_existing) gop.value_ptr.* = 0;
                gop.value_ptr.* += 1;
            }
        }
        var it = counts.iterator();
        while (it.next()) |e| {
            const s: u32 = @intCast(e.key_ptr.* >> 32);
            const x: u32 = @truncate(e.key_ptr.*);
            const slot = &wv.slots[s];
            const share = @as(f32, @floatFromInt(e.value_ptr.*)) / @as(f32, @floatFromInt(slot.claims));
            if (share < 0.05) continue;
            // Keep the strongest wording, in order.
            var pos: usize = slot.len;
            while (pos > 0 and slot.share[pos - 1] < share) pos -= 1;
            if (pos >= profile_len) continue;
            var j: usize = @min(slot.len, profile_len - 1);
            while (j > pos) : (j -= 1) {
                slot.keys[j] = slot.keys[j - 1];
                slot.share[j] = slot.share[j - 1];
            }
            slot.keys[pos] = wl.items[x].key;
            slot.share[pos] = share;
            if (slot.len < profile_len) slot.len += 1;
        }
    }

    // Names and values: a claim's non-wording words; the ones stated under
    // the most slots are its names.
    for (cs.items) |c| {
        const s = slot_of_frame[c.frame];
        for (mw.items[c.w0..][0..c.wn]) |x| {
            const w = &wl.items[x];
            if (w.wording or w.last_slot == s) continue;
            w.last_slot = s;
            w.slots += 1;
        }
    }

    // The grid.
    var cell_of: std.AutoHashMapUnmanaged(u64, u32) = .empty;
    var cell_list: std.ArrayList(Cell) = .empty;
    var members: std.ArrayList(std.ArrayList(u32)) = .empty;
    const claim_cells = try t.alloc([4]u32, cs.items.len);
    for (cs.items, 0..) |c, ci| {
        const s = slot_of_frame[c.frame];
        var top: u32 = 0;
        for (mw.items[c.w0..][0..c.wn]) |x| {
            if (!wl.items[x].wording) top = @max(top, wl.items[x].slots);
        }
        var k: usize = 0;
        claim_cells[ci] = @splat(std.math.maxInt(u32));
        if (top == 0) continue;
        for (mw.items[c.w0..][0..c.wn]) |x| {
            const w = wl.items[x];
            if (w.wording or w.slots != top or k == 4) continue;
            const gop = try cell_of.getOrPut(t, (@as(u64, s) << 32) | x);
            if (!gop.found_existing) {
                gop.value_ptr.* = @intCast(cell_list.items.len);
                try cell_list.append(t, .{ .slot = s, .name = w.key, .head = c.ord, .members = 0 });
                try members.append(t, .empty);
            }
            const cell = gop.value_ptr.*;
            try members.items[cell].append(t, @intCast(ci));
            cell_list.items[cell].members += 1;
            claim_cells[ci][k] = cell;
            k += 1;
        }
    }
    wv.cells = try a.dupe(Cell, cell_list.items);
    for (wv.cells, members.items) |*cell, m| {
        for (m.items) |ci| cell.head = @max(cell.head, cs.items[ci].ord);
    }
    // Every claim's newest version: the newest claim of any of its cells
    // that is not a different fact by its writer's subject.
    for (cs.items, 0..) |c, ci| {
        var head = c.ord;
        var main: u32 = std.math.maxInt(u32);
        var main_n: u32 = 0;
        for (claim_cells[ci]) |cell| {
            if (cell == std.math.maxInt(u32)) break;
            if (wv.cells[cell].members > main_n) {
                main = cell;
                main_n = wv.cells[cell].members;
            }
            for (members.items[cell].items) |cj| {
                const o = cs.items[cj];
                if (o.ord <= head) continue;
                if (c.group != 0 and o.group != 0 and c.group != o.group) continue;
                head = o.ord;
            }
        }
        if (main == std.math.maxInt(u32)) continue;
        if (head != c.ord) wv.linked += 1;
        try wv.facts.put(a, c.ord, .{ .cell = main, .head = head, .slot = slot_of_frame[c.frame] });
    }
    // Name -> cells.
    {
        var lists: std.AutoHashMapUnmanaged(u64, std.ArrayList(u32)) = .empty;
        for (wv.cells, 0..) |cell, i| {
            const gop = try lists.getOrPut(t, cell.name);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(t, @intCast(i));
        }
        var it = lists.iterator();
        while (it.next()) |e| try wv.names.put(a, e.key_ptr.*, try a.dupe(u32, e.value_ptr.items));
    }
    return wv;
}

const Frames = struct {
    size: std.ArrayList(u32) = .empty,
    /// Per frame: sum over words of (weight * count)^2.
    sq: std.ArrayList(f32) = .empty,
    counts: std.AutoHashMapUnmanaged(u64, u32) = .empty,
    word_frames: std.AutoHashMapUnmanaged(u32, std.ArrayList(u32)) = .empty,

    fn count(f: *const Frames, frame: u32, x: u32) u32 {
        return f.counts.get((@as(u64, frame) << 32) | x) orelse 0;
    }
};

/// Leader clustering: each claim joins the frame whose word profile it is
/// most like (cosine, at least `join_sim`), or starts a new frame.
fn cluster(t: Allocator, cs: []C, mw: []const u32, wl: []const Word) !Frames {
    var fr: Frames = .{};
    var cand: std.AutoHashMapUnmanaged(u32, f32) = .empty;
    for (cs) |*c| {
        const ws = mw[c.w0..][0..c.wn];
        var norm: f32 = 0;
        for (ws) |x| norm += wl[x].wt * wl[x].wt;
        cand.clearRetainingCapacity();
        if (norm > 0) for (ws) |x| {
            const w = wl[x];
            if (w.wt <= 0) continue;
            const list = fr.word_frames.get(x) orelse continue;
            for (list.items) |f| {
                const cnt: f32 = @floatFromInt(fr.count(f, x));
                const gop = try cand.getOrPut(t, f);
                if (!gop.found_existing) gop.value_ptr.* = 0;
                gop.value_ptr.* += w.wt * w.wt * cnt;
            }
        };
        var best: u32 = std.math.maxInt(u32);
        var best_sim: f32 = join_sim;
        var it = cand.iterator();
        while (it.next()) |e| {
            const f = e.key_ptr.*;
            const sq = fr.sq.items[f];
            if (sq <= 0) continue;
            const sim = e.value_ptr.* / (@sqrt(norm) * @sqrt(sq));
            if (sim > best_sim or (sim == best_sim and f < best)) {
                best = f;
                best_sim = sim;
            }
        }
        if (best == std.math.maxInt(u32)) {
            best = @intCast(fr.size.items.len);
            try fr.size.append(t, 0);
            try fr.sq.append(t, 0);
        }
        c.frame = best;
        fr.size.items[best] += 1;
        for (ws) |x| {
            const gop = try fr.counts.getOrPut(t, (@as(u64, best) << 32) | x);
            if (!gop.found_existing) {
                gop.value_ptr.* = 0;
                const wf = try fr.word_frames.getOrPut(t, x);
                if (!wf.found_existing) wf.value_ptr.* = .empty;
                try wf.value_ptr.append(t, best);
            }
            const cnt: f32 = @floatFromInt(gop.value_ptr.*);
            fr.sq.items[best] += wl[x].wt * wl[x].wt * (2 * cnt + 1);
            gop.value_ptr.* += 1;
        }
    }
    return fr;
}

// ------------------------------------------------------------------- tests

const testing = std.testing;

const TestStore = struct {
    df_map: std.AutoHashMapUnmanaged(u64, u32) = .empty,
    groups: std.AutoHashMapUnmanaged(u32, u64) = .empty,
    n: u64 = 0,
    ords: std.ArrayList(u32) = .empty,
    keys: std.ArrayList(u64) = .empty,

    fn deinit(s: *TestStore) void {
        s.df_map.deinit(testing.allocator);
        s.groups.deinit(testing.allocator);
        s.ords.deinit(testing.allocator);
        s.keys.deinit(testing.allocator);
    }
    pub fn df(s: *const TestStore, k: u64) u32 {
        return s.df_map.get(k) orelse 0;
    }
    pub fn alive(_: *const TestStore, _: u32) bool {
        return true;
    }
    pub fn group(s: *const TestStore, ord: u32) u64 {
        return s.groups.get(ord) orelse 0;
    }
    pub fn count(s: *const TestStore) u64 {
        return s.n;
    }
    fn add(s: *TestStore, text: []const u8, claim: bool, grp: u64) !u32 {
        const gpa = testing.allocator;
        var ts: words.Terms = .{};
        ts.fill(text);
        const ord: u32 = @intCast(s.n);
        s.n += 1;
        for (ts.items()) |w| {
            const gop = try s.df_map.getOrPut(gpa, w.key);
            if (!gop.found_existing) gop.value_ptr.* = 0;
            gop.value_ptr.* += 1;
        }
        if (claim) {
            try s.ords.append(gpa, ord);
            var k: usize = 0;
            for (ts.items()) |w| {
                if (k == max_words) break;
                try s.keys.append(gpa, w.key);
                k += 1;
            }
            while (k < max_words) : (k += 1) try s.keys.append(gpa, 0);
            if (grp != 0) try s.groups.put(gpa, ord, grp);
        }
        return ord;
    }
};

fn chatter(s: *TestStore, i: usize) !void {
    const fill = [_][]const u8{ "lunch", "coffee", "weather", "meeting", "standup", "weekend", "slides", "notes", "review", "budget" };
    var b: [128]u8 = undefined;
    const txt = try std.fmt.bufPrint(&b, "{s} {s} {s} talk", .{ fill[i % fill.len], fill[(i / 3) % fill.len], fill[(i / 7) % fill.len] });
    _ = try s.add(txt, false, 0);
}

test "frames, slots learned from subjects, and a grid that links untagged versions" {
    var s: TestStore = .{};
    defer s.deinit();
    const names = [_][]const u8{ "atlas", "borealis", "cygnus", "draco", "eridanus", "fornax", "gemini", "hydra" };
    var vb: [32]u8 = undefined;
    var tb: [128]u8 = undefined;
    var olds: [names.len]u32 = undefined;
    var news: [names.len]u32 = undefined;
    var v: usize = 0;
    for (0..400) |i| try chatter(&s, i);
    for (names, 0..) |nm, i| {
        // Two attributes per name, each worded its own way.
        v += 1;
        const val = try std.fmt.bufPrint(&vb, "zv{d}q", .{v});
        const t1 = try std.fmt.bufPrint(&tb, "{s} is deployed in the {s} region", .{ nm, val });
        olds[i] = try s.add(t1, true, if (i < 4) 100 + i else 0);
        for (0..50) |j| try chatter(&s, i * 50 + j);
        v += 1;
        const val2 = try std.fmt.bufPrint(&vb, "zv{d}q", .{v});
        const t2 = try std.fmt.bufPrint(&tb, "{s} keeps its records in {s}", .{ nm, val2 });
        _ = try s.add(t2, true, 0);
    }
    for (names, 0..) |nm, i| {
        for (0..50) |j| try chatter(&s, i * 31 + j);
        v += 1;
        const val = try std.fmt.bufPrint(&vb, "zv{d}q", .{v});
        // Half the updates carry the subject of their fact; the others
        // must be linked through what the tagged ones taught.
        const t = try std.fmt.bufPrint(&tb, "{s} moved over to the {s} hosting", .{ nm, val });
        news[i] = try s.add(t, true, if (i < 4) 100 + i else 0);
    }
    const wv = try build(testing.allocator, s.ords.items, s.keys.items, &s);
    defer wv.deinit(testing.allocator);
    try testing.expect(wv.frames >= 3);
    try testing.expect(wv.joined_by_subject >= 1);
    for (names, 0..) |_, i| {
        const f = wv.factOf(olds[i]) orelse return error.TestUnexpectedResult;
        try testing.expectEqual(news[i], f.head);
    }
    // The records fact of a name is a different slot: never superseded.
    var records_linked: usize = 0;
    var it = wv.facts.iterator();
    while (it.next()) |e| {
        const ord = e.key_ptr.*;
        var is_deploy = false;
        for (olds) |o| if (o == ord) {
            is_deploy = true;
        };
        for (news) |o| if (o == ord) {
            is_deploy = true;
        };
        if (!is_deploy and e.value_ptr.head != ord) records_linked += 1;
    }
    if (records_linked != 0) {
        for (s.ords.items) |o| if (wv.factOf(o)) |f| std.debug.print("ord {d} cell {d} head {d} slot {d} name {d}\n", .{ o, f.cell, f.head, f.slot, wv.cells[f.cell].name });
        std.debug.print("frames {d} slots {d} subj {d}\n", .{ wv.frames, wv.slots.len, wv.joined_by_subject });
    }
    try testing.expectEqual(@as(usize, 0), records_linked);
    // Names find their cells; the slot's wording pools both phrasings.
    try testing.expectEqual(@as(usize, 2), wv.cellsOf(words.pack("atla")).len);
    const slot = wv.slots[wv.factOf(olds[0]).?.slot];
    var has_region = false;
    var has_moved = false;
    for (slot.wording()) |k| {
        if (k == words.pack("region")) has_region = true;
        if (k == words.pack("mov")) has_moved = true;
    }
    try testing.expect(has_region and has_moved);
}
