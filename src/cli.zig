//! `sedimentum`: inspect and maintain a database from the command line.

const std = @import("std");
const Io = std.Io;
const sdm = @import("sedimentum");
const Db = sdm.Db;

const usage =
    \\usage: sedimentum <command> <dir> [args]
    \\
    \\  stats   <dir>                       keys, segments, disk and live bytes
    \\  check   <dir>                       verify every record's checksum
    \\  get     <dir> <key>                 print a value
    \\  put     <dir> <key> <value>         write a value (durably)
    \\  delete  <dir> <key>                 delete a key
    \\  scan    <dir> [prefix] [-r] [-n N]  list keys (and values) under a prefix
    \\  compact <dir>                       rewrite every segment with dead bytes
    \\
;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);

    var out_buf: [64 * 1024]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(io, &out_buf);
    const out = &stdout.interface;
    defer out.flush() catch {};

    if (args.len < 3) {
        try Io.File.stderr().writeStreamingAll(io, usage);
        std.process.exit(2);
    }
    const cmd = args[1];
    const dir = args[2];

    var db = Db.open(init.gpa, io, Io.Dir.cwd(), dir, .{ .auto_compact = false }) catch |err| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "sedimentum: cannot open {s}: {t}\n", .{ dir, err }) catch "sedimentum: cannot open\n";
        try Io.File.stderr().writeStreamingAll(io, msg);
        std.process.exit(1);
    };
    defer db.close();

    if (std.mem.eql(u8, cmd, "stats")) {
        const st = db.spaceStats();
        try out.print("keys        {d}\nlast seq    {d}\nsegments    {d}\ndisk bytes  {d}\nlive bytes  {d}\nindex keys  {d} bytes\n", .{
            db.count(), db.lastSeq(), st.segments, st.total_bytes, st.live_bytes, db.index.key_bytes,
        });
    } else if (std.mem.eql(u8, cmd, "check")) {
        // Opening already verified every record while replaying. Reading
        // each live value verifies the index points at intact records.
        var it = db.iterator(.{});
        var n: usize = 0;
        while (try it.next()) |_| n += 1;
        try out.print("ok: {d} live keys verified across {d} segments\n", .{ n, db.spaceStats().segments });
    } else if (std.mem.eql(u8, cmd, "get")) {
        if (args.len < 4) return usageExit(io);
        const v = (try db.getView(args[3])) orelse {
            try Io.File.stderr().writeStreamingAll(io, "not found\n");
            std.process.exit(1);
        };
        try out.print("{s}\n", .{v});
    } else if (std.mem.eql(u8, cmd, "put")) {
        if (args.len < 5) return usageExit(io);
        try db.put(args[3], args[4]);
    } else if (std.mem.eql(u8, cmd, "delete")) {
        if (args.len < 4) return usageExit(io);
        if (!try db.delete(args[3])) {
            try Io.File.stderr().writeStreamingAll(io, "not found\n");
            std.process.exit(1);
        }
    } else if (std.mem.eql(u8, cmd, "scan")) {
        var prefix: []const u8 = "";
        var reverse = false;
        var limit: usize = std.math.maxInt(usize);
        var i: usize = 3;
        while (i < args.len) : (i += 1) {
            const a = args[i];
            if (std.mem.eql(u8, a, "-r")) {
                reverse = true;
            } else if (std.mem.eql(u8, a, "-n") and i + 1 < args.len) {
                i += 1;
                limit = try std.fmt.parseInt(usize, args[i], 10);
            } else prefix = a;
        }
        const end_buf = try arena.alloc(u8, prefix.len);
        var it = db.prefixIterator(prefix, reverse, end_buf);
        var n: usize = 0;
        while (n < limit) : (n += 1) {
            const p = (try it.next()) orelse break;
            try out.print("{s}\t{s}\n", .{ p.key, p.value });
        }
    } else if (std.mem.eql(u8, cmd, "compact")) {
        const before = db.spaceStats();
        const n = try db.compactWithRatio(0);
        const after = db.spaceStats();
        try out.print("compacted {d} segments: {d} -> {d} bytes\n", .{ n, before.total_bytes, after.total_bytes });
    } else return usageExit(io);
}

fn usageExit(io: Io) !void {
    try Io.File.stderr().writeStreamingAll(io, usage);
    std.process.exit(2);
}
