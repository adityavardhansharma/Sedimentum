//! Prints what a store's weave has learned: its slots (the attributes it
//! found, by their wording), how many claims and cells each holds, and the
//! cells of a name.
//!
//!   zig-out/bin/loom-schema <store-dir> [name] [slots-to-show]

const std = @import("std");
const Io = std.Io;
const loom = @import("loom");
const Loom = loom.Loom;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var buf: [16 * 1024]u8 = undefined;
    var out = Io.File.stdout().writerStreaming(io, &buf);
    const w = &out.interface;
    if (args.len < 2) {
        try w.writeAll("usage: loom-schema <store-dir> [name] [slots-to-show]\n");
        try w.flush();
        return;
    }
    if (std.c.getenv("LOOM_DEBUG") != null) loom.Weave.debug = true;
    const h = try Loom.open(gpa, io, Io.Dir.cwd(), args[1], .{ .sync_writes = false });
    defer h.close();
    h.learn();
    const inf = h.info();
    try w.print("memories {d}, claims {d}, frames {d}, slots {d}, cells {d}, linked {d} (slots joined: {d} by subject, {d} by precedence, {d} one-off)\n", .{
        inf.memories, inf.claims, inf.frames, inf.slots, inf.cells, inf.linked, inf.joined_by_subject, inf.joined_by_precedence, inf.joined_one_off,
    });
    const show: usize = if (args.len > 3) try std.fmt.parseInt(usize, args[3], 10) else 30;
    const slots = try h.schema(gpa);
    defer Loom.freeSchema(gpa, slots);
    for (slots[0..@min(show, slots.len)], 0..) |s, i| {
        try w.print("slot {d:>4}: {d:>6} claims {d:>3} frames {d:>6} cells  {s}\n", .{ i, s.claims, s.frames, s.cells, s.wording });
    }
    if (args.len > 2 and args[2].len > 0) {
        const rows = try h.facts(gpa, args[2], "");
        defer Loom.freeFacts(gpa, rows);
        try w.print("\n{s}: {d} facts\n", .{ args[2], rows.len });
        for (rows) |r| try w.print("  [{s}] {d} versions: {s}\n", .{ r.wording, r.versions, r.memory.text });
    }
    try w.flush();
}
