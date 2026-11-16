//! The weave: the schema a store learns from its own claims.
//!
//! A claim is a memory that names something rare: a word the store has
//! seen only a few times (a name) next to a word it has rarely or never
//! seen (a value). Loom keeps the words around those rare words for every
//! claim, and from all claims together it learns three things, with no
//! model and no labels beyond what the writer already gives:
//!
//!   Frames  the ways claims are worded ("<name> is deployed in the <value>
//!           region"). A claim's value is its rarest word; a word is
//!           wording when it keeps its place next to values across claims
//!           ("deployed" two places before, "region" one after). Chatter
//!           around a claim lands anywhere and a name moves with the
//!           wording around it, so neither keeps a place. Claims join the
//!           frame whose wording they share (cosine of the words at their
//!           places, at least 0.75).
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
pub var debug = false;
/// Wording words kept per slot for matching questions.
pub const profile_len = 12;

/// Places before and after a claim's value that its wording may take.
const max_before = 6;
const max_after = 3;
/// A word at one place needs this many claims to be wording, and more in a
/// big store (one claim in 512), where chance alone puts a few chatter
/// words at the same place now and then.
const min_feature = 3;
const max_feature = 16;
/// Cosine a claim needs with a frame to join it. Wordings that share a
/// word ("keeps its records in", "keeps logs for") stay apart.
const join_sim: f32 = 0.75;
/// A word is wording of a frame when at least this share of the frame's
/// claims hold it.
const wording_share: f32 = 0.25;
/// A frame needs this many claims before its wording counts.
const min_frame: u32 = 4;
/// Precedence: share of a change frame's claims whose name was stated in
/// the chosen slot earlier, and its lead over the next slot.
const prec_share: f32 = 0.8;
const prec_lead: f32 = 0.2;

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
    joined_by_precedence: usize = 0,
    joined_one_off: usize = 0,

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
    /// Times it was near a claim's value.
    near: u32 = 0,
    /// It keeps its place next to values: it is how claims are worded.
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
    /// Word indexes of its words (names, values and wording).
    w0: u32,
    wn: u32,
    /// Its wording features.
    f0: u32,
    fnn: u32,
    /// Where its words are, and which of them is its value.
    src: u32,
    pv: u8,
    frame: u32 = 0,
};

/// Builds the weave over the claims `ords`. `ctx` answers `df(key) u32`
/// (memories holding the word), `alive(ord) bool`, `group(ord) u64` (the
/// claim's subject group, 0 for none), `count() u64` (memories) and
/// `claimWords(ord, *[max_words]u64) !usize` (the claim's words near its
/// rare ones, in text order).
pub fn build(gpa: Allocator, ords: []const u32, ctx: anytype) !*Woven {
    const wv = try gpa.create(Woven);
    wv.* = .{ .arena = .init(gpa), .claims = ords.len };
    errdefer wv.deinit(gpa);
    const a = wv.arena.allocator();
    var tmp_arena: std.heap.ArenaAllocator = .init(gpa);
    defer tmp_arena.deinit();
    const t = tmp_arena.allocator();

    // Each claim's words, read from the store now (so with today's counts).
    const keys = try t.alloc(u64, ords.len * max_words);
    @memset(keys, 0);
    for (ords, 0..) |ord, i| {
        if (!ctx.alive(ord)) continue;
        _ = try ctx.claimWords(ord, keys[i * max_words ..][0..max_words]);
    }

    // Distinct words of live claims, how many claims hold each, and each
    // claim's value: its rarest word (the later one on a tie).
    var widx: std.AutoHashMapUnmanaged(u64, u32) = .empty;
    var wl: std.ArrayList(Word) = .empty;
    var live: std.ArrayList(u32) = .empty;
    var pivots: std.ArrayList(u8) = .empty;
    for (ords, 0..) |ord, i| {
        if (!ctx.alive(ord)) continue;
        try live.append(t, @intCast(i));
        var pv: u8 = 0;
        var pv_df: u32 = std.math.maxInt(u32);
        for (keys[i * max_words ..][0..max_words], 0..) |k, j| {
            if (k == 0) break;
            const gop = try widx.getOrPut(t, k);
            if (!gop.found_existing) {
                gop.value_ptr.* = @intCast(wl.items.len);
                try wl.append(t, .{ .key = k, .df = ctx.df(k) });
            }
            const w = &wl.items[gop.value_ptr.*];
            w.cdf += 1;
            if (w.df <= pv_df) {
                pv_df = w.df;
                pv = @intCast(j);
            }
        }
        try pivots.append(t, pv);
    }
    const nc: f32 = @floatFromInt(@max(live.items.len, 1));
    const rare_lim: u32 = @intCast(@max(4, ctx.count() >> 12));

    // Features: a word at its place relative to the value (stopwords do
    // not count). Wording is a word that keeps its place: most of the
    // claims that hold it near a value hold it there. Chatter around a
    // claim lands anywhere; a name moves from claim to claim with the
    // wording around it.
    var fidx: std.AutoHashMapUnmanaged(u64, u32) = .empty;
    var fcount: std.ArrayList(u32) = .empty;
    var fword: std.ArrayList(u32) = .empty;
    for (live.items, pivots.items) |i, pv| {
        const ks = keys[i * max_words ..][0..max_words];
        for (ks, 0..) |k, j| {
            if (k == 0) break;
            const off = @as(i32, @intCast(j)) - pv;
            if (off == 0 or off < -max_before or off > max_after) continue;
            const x = widx.get(k).?;
            const fk = (@as(u64, x) << 8) | @as(u64, @intCast(off + 128));
            const gop = try fidx.getOrPut(t, fk);
            if (!gop.found_existing) {
                gop.value_ptr.* = @intCast(fcount.items.len);
                try fcount.append(t, 0);
                try fword.append(t, x);
            }
            fcount.items[gop.value_ptr.*] += 1;
            wl.items[x].near += 1;
        }
    }
    const min_cf: u32 = std.math.clamp(@as(u32, @intCast(live.items.len / 512)), min_feature, max_feature);
    const fwt = try t.alloc(f32, fcount.items.len);
    for (fcount.items, fword.items, fwt) |cf, x, *wt| {
        const w = &wl.items[x];
        const keep = @as(f32, @floatFromInt(cf)) / @as(f32, @floatFromInt(@max(w.near, 1)));
        // A rare word must keep its place nearly always to be wording (a
        // name keeps one place in a few of its claims at most).
        const need: f32 = if (w.df <= rare_lim) 0.7 else 0.3;
        wt.* = if (cf >= min_cf and keep >= need) @log(1 + @as(f32, @floatFromInt(cf))) else 0;
        if (wt.* > 0) w.wording = true;
    }

    // Each claim: its wording features, and its words (names, values and
    // wording). A name or value is a rare word that is nobody's wording
    // and turns up mostly in claims.
    var cs: std.ArrayList(C) = .empty;
    var mw: std.ArrayList(u32) = .empty;
    var fl: std.ArrayList(u32) = .empty;
    for (live.items, pivots.items) |i, pv| {
        const w0: u32 = @intCast(mw.items.len);
        const f0: u32 = @intCast(fl.items.len);
        var cue = false;
        var names: usize = 0;
        for (keys[i * max_words ..][0..max_words], 0..) |k, j| {
            if (k == 0) break;
            const x = widx.get(k).?;
            const w = wl.items[x];
            if (words.isCue(k)) cue = true;
            const off = @as(i32, @intCast(j)) - pv;
            if (off != 0 and off >= -max_before and off <= max_after) {
                const fk = (@as(u64, x) << 8) | @as(u64, @intCast(off + 128));
                const fi = fidx.get(fk).?;
                if (fwt[fi] > 0) {
                    try fl.append(t, fi);
                    try mw.append(t, x);
                    continue;
                }
            }
            if (w.wording or w.df > rare_lim or w.cdf * 2 < w.df) continue;
            try mw.append(t, x);
            names += 1;
        }
        const wn: u32 = @as(u32, @intCast(mw.items.len)) - w0;
        const fnn: u32 = @as(u32, @intCast(fl.items.len)) - f0;
        if (names == 0 or (fnn == 0 and names < 2)) {
            mw.shrinkRetainingCapacity(w0);
            fl.shrinkRetainingCapacity(f0);
            continue;
        }
        try cs.append(t, .{ .ord = ords[i], .group = ctx.group(ords[i]), .cue = cue, .w0 = w0, .wn = wn, .f0 = f0, .fnn = fnn, .src = i, .pv = pv });
    }
    wv.woven = cs.items.len;
    _ = nc;
    if (cs.items.len == 0) return wv;

    // Frames: claims worded alike, by leader clustering on their wording.
    const fr = try cluster(t, cs.items, fl.items, fwt);
    const nf0 = fr.size.items.len;
    if (debug) {
        var shown: usize = 0;
        for (cs.items) |c| {
            if (shown > 60) break;
            shown += 1;
            std.debug.print("claim {d} frame {d} (size {d}) cue {}:", .{ c.ord, c.frame, fr.size.items[c.frame], c.cue });
            for (mw.items[c.w0..][0..c.wn]) |x| {
                var b: [12]u8 = undefined;
                const wd = wl.items[x];
                std.debug.print(" {s}{s}[df {d}]", .{ if (wd.wording) "=" else "", if (wd.key & words.hashed_bit != 0) "#" else words.unpack(wd.key, &b), wd.df });
            }
            std.debug.print("\n", .{});
        }
    }

    if (debug) {
        var it = fr.counts.iterator();
        while (it.next()) |e| {
            const f: u32 = @intCast(e.key_ptr.* >> 32);
            const fi: u32 = @truncate(e.key_ptr.*);
            if (fr.size.items[f] < min_frame) continue;
            var b: [12]u8 = undefined;
            const wd = wl.items[fword.items[fi]];
            std.debug.print("frame {d} size {d}: {s} x{d} (cf {d} wt {d:.2})\n", .{ f, fr.size.items[f], if (wd.key & words.hashed_bit != 0) "#" else words.unpack(wd.key, &b), e.value_ptr.*, fcount.items[fi], fwt[fi] });
        }
    }
    // A frame with fewer claims than that has learned nothing from other
    // names: what its claims have in common may be no more than a name.
    // Each of its claims is a frame of its own, until evidence joins it.
    var nf: usize = nf0;
    for (fr.size.items) |sz| {
        if (sz >= min_frame) wv.frames += 1;
    }
    for (cs.items) |*c| if (fr.size.items[c.frame] < min_frame) {
        c.frame = @intCast(nf);
        nf += 1;
    };

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
            if (debug) std.debug.print("subject join {d} {d}: {d} for, {d} against\n", .{ e.k >> 32, @as(u32, @truncate(e.k)), e.n, conflict.get(e.k) orelse 0 });
            if (uf.join(@intCast(e.k >> 32), @truncate(e.k))) wv.joined_by_subject += 1;
        }
    }
    // 2. Precedence: a frame that says something changed ("moved", "now",
    //    "slipped") is a newer version of the one slot every one of its
    //    names was stated in before.
    {
        var cue_n = try t.alloc(u32, nf);
        @memset(cue_n, 0);
        var fclaims = try t.alloc(std.ArrayList(u32), nf);
        for (fclaims) |*l| l.* = .empty;
        for (cs.items, 0..) |c, ci| {
            if (c.cue) cue_n[c.frame] += 1;
            try fclaims[c.frame].append(t, @intCast(ci));
        }
        var tally: std.AutoHashMapUnmanaged(u32, u32) = .empty;
        var seen: std.AutoHashMapUnmanaged(u32, void) = .empty;
        for (0..2) |_| {
            for (0..nf) |f| {
                const sz = fclaims[f].items.len;
                if (sz < min_frame or cue_n[f] * 2 < sz) continue;
                const root = uf.find(@intCast(f));
                tally.clearRetainingCapacity();
                for (fclaims[f].items) |ci| {
                    const c = cs.items[ci];
                    seen.clearRetainingCapacity();
                    for (mw.items[c.w0..][0..c.wn]) |x| {
                        if (wl.items[x].wording) continue;
                        const list = by_name.get(x) orelse continue;
                        for (list.items) |cj| {
                            const o = cs.items[cj];
                            if (o.ord >= c.ord or o.frame == f) continue;
                            // The frame's own slot counts too: if its names
                            // were stated there before (a subject already
                            // joined them), nothing else is needed.
                            try seen.put(t, uf.find(o.frame), {});
                        }
                    }
                    var sit = seen.keyIterator();
                    while (sit.next()) |r| {
                        const gop = try tally.getOrPut(t, r.*);
                        if (!gop.found_existing) gop.value_ptr.* = 0;
                        gop.value_ptr.* += 1;
                    }
                }
                var best: u32 = 0;
                var best_n: u32 = 0;
                var second_n: u32 = 0;
                var tit = tally.iterator();
                while (tit.next()) |e| {
                    const v = e.value_ptr.*;
                    const k = e.key_ptr.*;
                    if (v > best_n) {
                        second_n = best_n;
                        best = k;
                        best_n = v;
                    } else if (v == best_n and k < best) {
                        second_n = best_n;
                        best = k;
                    } else if (v > second_n) second_n = v;
                }
                const szf: f32 = @floatFromInt(sz);
                if (@as(f32, @floatFromInt(best_n)) >= prec_share * szf and
                    @as(f32, @floatFromInt(best_n - second_n)) >= prec_lead * szf)
                {
                    if (best != root and uf.join(root, best)) wv.joined_by_precedence += 1;
                }
            }
        }
    }

    // 3. One-off claims: a claim no frame explains, and no subject placed,
    //    continues the earlier claim that shares the most of its words,
    //    when it is the only one that close: two words (the name and one
    //    more) when it says something changed, three when it does not.
    {
        var shared: std.AutoHashMapUnmanaged(u32, u32) = .empty;
        var by_root: std.AutoHashMapUnmanaged(u32, u32) = .empty;
        for (cs.items, 0..) |c, ci| {
            // A claim its writer's subject already placed in a slot stays
            // there: joining it again would join two slots through it.
            if (c.frame < nf0 or uf.find(c.frame) < nf0) continue;
            shared.clearRetainingCapacity();
            for (mw.items[c.w0..][0..c.wn]) |x| {
                const list = by_name.get(x) orelse continue;
                for (list.items[0..@min(list.items.len, 256)]) |cj| {
                    if (cj >= ci) continue;
                    const gop = try shared.getOrPut(t, cj);
                    if (!gop.found_existing) gop.value_ptr.* = 0;
                    gop.value_ptr.* += 1;
                }
            }
            // Per slot so far, the closest claim in it.
            by_root.clearRetainingCapacity();
            var it = shared.iterator();
            while (it.next()) |e| {
                const o = cs.items[e.key_ptr.*];
                if (c.group != 0 and o.group != 0 and c.group != o.group) continue;
                // Wording counts too, once the name is shared.
                var n_sh = e.value_ptr.*;
                for (mw.items[c.w0..][0..c.wn]) |x| if (wl.items[x].wording) {
                    for (mw.items[o.w0..][0..o.wn]) |y| if (y == x) {
                        n_sh += 1;
                    };
                };
                const gop = try by_root.getOrPut(t, uf.find(o.frame));
                if (!gop.found_existing) gop.value_ptr.* = 0;
                gop.value_ptr.* = @max(gop.value_ptr.*, n_sh);
            }
            var best: u32 = 0;
            var best_n: u32 = 0;
            var second_n: u32 = 0;
            var rit = by_root.iterator();
            while (rit.next()) |e| {
                const v = e.value_ptr.*;
                if (v > best_n) {
                    second_n = best_n;
                    best = e.key_ptr.*;
                    best_n = v;
                } else if (v > second_n) second_n = v;
            }
            const need: u32 = if (c.cue) 2 else 3;
            if (best_n >= need and second_n < best_n) {
                if (uf.join(c.frame, best)) wv.joined_one_off += 1;
            }
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
        var k: usize = 0;
        claim_cells[ci] = @splat(std.math.maxInt(u32));
        var top: u32 = 0;
        for (mw.items[c.w0..][0..c.wn]) |x| {
            if (!wl.items[x].wording) top = @max(top, wl.items[x].slots);
        }
        if (top == 0) continue;
        var picks: [4]u32 = undefined;
        var np: usize = 0;
        for (mw.items[c.w0..][0..c.wn]) |x| {
            const w = wl.items[x];
            if (w.wording or w.slots != top or np == picks.len) continue;
            picks[np] = x;
            np += 1;
        }
        for (picks[0..np]) |x| {
            const gop = try cell_of.getOrPut(t, (@as(u64, s) << 32) | x);
            if (!gop.found_existing) {
                gop.value_ptr.* = @intCast(cell_list.items.len);
                try cell_list.append(t, .{ .slot = s, .name = wl.items[x].key, .head = c.ord, .members = 0 });
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

/// Leader clustering: each claim joins the frame whose wording profile it
/// is most like (cosine, at least `join_sim`), or starts a new frame.
/// Claims with no wording features each start their own.
fn cluster(t: Allocator, cs: []C, fl: []const u32, wt: []const f32) !Frames {
    var fr: Frames = .{};
    var cand: std.AutoHashMapUnmanaged(u32, f32) = .empty;
    for (cs) |*c| {
        const fs = fl[c.f0..][0..c.fnn];
        var norm: f32 = 0;
        for (fs) |x| norm += wt[x] * wt[x];
        cand.clearRetainingCapacity();
        if (norm > 0) for (fs) |x| {
            const list = fr.word_frames.get(x) orelse continue;
            for (list.items) |f| {
                const cnt: f32 = @floatFromInt(fr.count(f, x));
                const gop = try cand.getOrPut(t, f);
                if (!gop.found_existing) gop.value_ptr.* = 0;
                gop.value_ptr.* += wt[x] * wt[x] * cnt;
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
        for (fs) |x| {
            const gop = try fr.counts.getOrPut(t, (@as(u64, best) << 32) | x);
            if (!gop.found_existing) {
                gop.value_ptr.* = 0;
                const wf = try fr.word_frames.getOrPut(t, x);
                if (!wf.found_existing) wf.value_ptr.* = .empty;
                try wf.value_ptr.append(t, best);
            }
            const cnt: f32 = @floatFromInt(gop.value_ptr.*);
            fr.sq.items[best] += wt[x] * wt[x] * (2 * cnt + 1);
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
    pub fn claimWords(s: *const TestStore, ord: u32, out: *[max_words]u64) !usize {
        const i = std.mem.indexOfScalar(u32, s.ords.items, ord).?;
        @memcpy(out, s.keys.items[i * max_words ..][0..max_words]);
        return max_words;
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
    const wv = try build(testing.allocator, s.ords.items, &s);
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

test "a change frame joins the slot its names were always stated in before" {
    var s: TestStore = .{};
    defer s.deinit();
    const names = [_][]const u8{ "atlas", "borealis", "cygnus", "draco", "eridanus", "fornax" };
    var vb: [32]u8 = undefined;
    var tb: [128]u8 = undefined;
    var olds: [names.len]u32 = undefined;
    var news: [names.len]u32 = undefined;
    var v: usize = 0;
    for (0..400) |i| try chatter(&s, i);
    for (names, 0..) |nm, i| {
        v += 1;
        olds[i] = try s.add(try std.fmt.bufPrint(&tb, "{s} ships on {s}", .{ nm, try std.fmt.bufPrint(&vb, "zv{d}q", .{v}) }), true, 0);
        for (0..30) |j| try chatter(&s, j + i);
    }
    for (names, 0..) |nm, i| {
        v += 1;
        news[i] = try s.add(try std.fmt.bufPrint(&tb, "{s} launch slipped to {s}", .{ nm, try std.fmt.bufPrint(&vb, "zv{d}q", .{v}) }), true, 0);
        for (0..30) |j| try chatter(&s, j * 3 + i);
        // Another attribute, stated after some of the slips only.
        if (i % 2 == 0) {
            v += 1;
            _ = try s.add(try std.fmt.bufPrint(&tb, "{s} invoices customers in {s}", .{ nm, try std.fmt.bufPrint(&vb, "zv{d}q", .{v}) }), true, 0);
        }
    }
    const wv = try build(testing.allocator, s.ords.items, &s);
    defer wv.deinit(testing.allocator);
    try testing.expect(wv.joined_by_precedence >= 1);
    for (names, 0..) |_, i| {
        const f = wv.factOf(olds[i]) orelse return error.TestUnexpectedResult;
        try testing.expectEqual(news[i], f.head);
    }
}
