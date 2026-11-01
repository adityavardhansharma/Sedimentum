//! `sedimentum`: inspect and maintain a database from the command line.

const std = @import("std");
const Io = std.Io;
const sdm = @import("sedimentum");
const Db = sdm.Db;

const usage =
    \\usage: sedimentum [--engine v1|v2|v3] <command> <dir> [args]
    \\
    \\  stats   <dir>                       keys, segments, disk and live bytes
    \\  check   <dir>                       verify every record's checksum
    \\  get     <dir> <key>                 print a value
    \\  put     <dir> <key> <value> [--ttl S]  write a value (durably)
    \\  delete  <dir> <key>                 delete a key
    \\  scan    <dir> [prefix] [-r] [-n N]  list keys (and values) under a prefix
    \\  compact <dir>                       rewrite every segment with dead bytes
    \\
    \\stream stores (v2, v3) also have:
    \\  streams    <dir>                    list streams with their sizes
    \\  incr       <dir> <key> [delta]      add to a counter, print the result
    \\  trim       <dir> <prefix> <keep> [--last]  keep only the first (or last) keys
    \\  backup     <dir> <dest>             write a consistent copy to a new directory
    \\  checkpoint <dir>                    make everything durable and fold it into chunks
    \\
    \\The engine of an existing directory is detected; --engine picks one
    \\for a new directory (default v1).
    \\
;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);

    var out_buf: [64 * 1024]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(io, &out_buf);
    const out = &stdout.interface;

    var rest = args[1..];
    var engine: ?[]const u8 = null;
    if (rest.len >= 2 and std.mem.eql(u8, rest[0], "--engine")) {
        engine = rest[1];
        rest = rest[2..];
    }
    if (rest.len < 2) {
        try Io.File.stderr().writeStreamingAll(io, usage);
        std.process.exit(2);
    }
    const cmd = rest[0];
    const dir = rest[1];

    const found = sdm.streams.detect(io, Io.Dir.cwd(), dir) catch null;
    const which: []const u8 = if (found) |f| @tagName(f) else engine orelse "v1";
    if (engine) |e| if (found != null and !std.mem.eql(u8, e, which)) {
        try Io.File.stderr().writeStreamingAll(io, "sedimentum: the directory holds a different engine\n");
        std.process.exit(1);
    };
    if (std.mem.eql(u8, which, "v2")) {
        try streamMain(sdm.streams.V2, init, rest, out);
        try out.flush();
        return;
    }
    if (std.mem.eql(u8, which, "v3")) {
        try streamMain(sdm.streams.V3, init, rest, out);
        try out.flush();
        return;
    }
    if (!std.mem.eql(u8, which, "v1")) return usageExit(io);
    const args_v1 = rest;

    if (std.mem.eql(u8, cmd, "check")) {
        // Check the files before opening the database: opening repairs a
        // torn tail, which would hide it from the check.
        const ok = try checkFiles(init.gpa, io, dir, out);
        try out.flush();
        if (!ok) std.process.exit(1);
        return;
    }

    var db = Db.open(init.gpa, io, Io.Dir.cwd(), dir, .{ .auto_compact = false }) catch |err| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "sedimentum: cannot open {s}: {t}\n", .{ dir, err }) catch "sedimentum: cannot open\n";
        try Io.File.stderr().writeStreamingAll(io, msg);
        std.process.exit(1);
    };
    defer db.close();

    if (std.mem.eql(u8, cmd, "stats")) {
        const st = db.spaceStats();
        const cold_keys: u64 = if (db.cold) |c| c.entries else 0;
        try out.print("keys        {d}\nlast seq    {d}\nsegments    {d}\ndisk bytes  {d}\nlive bytes  {d}\nin memory   {d} keys, about {d} bytes\non disk     {d} keys in the cold index\n", .{
            db.count(), db.lastSeq(), st.segments, st.total_bytes, st.live_bytes, db.index.len(), db.memoryUsed(), cold_keys,
        });
    } else if (std.mem.eql(u8, cmd, "get")) {
        if (args_v1.len < 3) return usageExit(io);
        const v = (try db.getView(args_v1[2])) orelse {
            try Io.File.stderr().writeStreamingAll(io, "not found\n");
            std.process.exit(1);
        };
        try out.print("{s}\n", .{v});
    } else if (std.mem.eql(u8, cmd, "put")) {
        if (args_v1.len < 4) return usageExit(io);
        const ttl = try ttlArg(args_v1[4..]);
        if (ttl > 0) try db.putTtl(args_v1[2], args_v1[3], ttl) else try db.put(args_v1[2], args_v1[3]);
    } else if (std.mem.eql(u8, cmd, "delete")) {
        if (args_v1.len < 3) return usageExit(io);
        if (!try db.delete(args_v1[2])) {
            try Io.File.stderr().writeStreamingAll(io, "not found\n");
            std.process.exit(1);
        }
    } else if (std.mem.eql(u8, cmd, "scan")) {
        var prefix: []const u8 = "";
        var reverse = false;
        var limit: usize = std.math.maxInt(usize);
        var i: usize = 2;
        while (i < args_v1.len) : (i += 1) {
            const a = args[i];
            if (std.mem.eql(u8, a, "-r")) {
                reverse = true;
            } else if (std.mem.eql(u8, a, "-n")) {
                if (i + 1 >= args_v1.len) return usageExit(io);
                i += 1;
                limit = try std.fmt.parseInt(usize, args[i], 10);
            } else prefix = a;
        }
        const end_buf = try arena.alloc(u8, prefix.len);
        var it = try db.prefixIterator(prefix, reverse, end_buf);
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
    // Report lost output as a failure instead of exiting 0.
    try out.flush();
}

/// Verifies every segment file read-only and reports damage without
/// repairing anything. Returns whether every file is clean.
fn checkFiles(gpa: std.mem.Allocator, io: Io, path: []const u8, out: *Io.Writer) !bool {
    var report = sdm.Log.check(gpa, io, Io.Dir.cwd(), path) catch |err| {
        switch (err) {
            error.Locked => try out.print("{s} is open in another process; close it before checking\n", .{path}),
            else => try out.print("cannot check {s}: {t}\n", .{ path, err }),
        }
        return false;
    };
    defer report.deinit(gpa);
    for (report.problems.items) |p| {
        var name_buf: [sdm.segment.name_len]u8 = undefined;
        const name = if (p.kind == .bad_cold_index) "" else sdm.segment.fileName(&name_buf, p.segment);
        switch (p.kind) {
            .torn_tail => try out.print("{s}: damaged tail at byte {d} of {d} (opening the database will cut it off)\n", .{ name, p.offset, p.file_len }),
            .torn_sealed => try out.print("{s}: damaged tail at byte {d} of {d} in a sealed segment (opening will fail)\n", .{ name, p.offset, p.file_len }),
            .corrupt => try out.print("{s}: damaged record at byte {d} followed by valid records (opening will fail)\n", .{ name, p.offset }),
            .bad_batch => try out.print("{s}: batch at byte {d} has invalid contents (opening will fail)\n", .{ name, p.offset }),
            .bad_cold_index => try out.print("{s}: damaged (opening may fail or reads may return errors)\n", .{sdm.cold.file_name}),
        }
    }
    const clean = report.problems.items.len == 0;
    if (clean) try out.print("ok: {d} records verified across {d} segments\n", .{ report.records, report.segments });
    return clean;
}

fn usageExit(io: Io) !void {
    try Io.File.stderr().writeStreamingAll(io, usage);
    std.process.exit(2);
}

fn ttlArg(extra: []const []const u8) !u32 {
    if (extra.len >= 2 and std.mem.eql(u8, extra[0], "--ttl")) return std.fmt.parseInt(u32, extra[1], 10);
    return 0;
}

fn fail(io: Io, comptime fmt: []const u8, a: anytype) noreturn {
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "sedimentum: " ++ fmt ++ "\n", a) catch "sedimentum: error\n";
    Io.File.stderr().writeStreamingAll(io, msg) catch {};
    std.process.exit(1);
}

/// Commands for the stream stores. `args[0]` is the command, `args[1]` the
/// directory.
fn streamMain(comptime S: type, init: std.process.Init, args: []const []const u8, out: *Io.Writer) !void {
    const io = init.io;
    const gpa = init.gpa;
    const cmd = args[0];
    const dir = args[1];
    var db = S.open(gpa, io, Io.Dir.cwd(), dir, .{}) catch |err| fail(io, "cannot open {s}: {t}", .{ dir, err });
    defer db.close();

    if (std.mem.eql(u8, cmd, "stats")) {
        const st = db.stats();
        try out.print("engine      {s}\nshards      {d}\nstreams     {d}\nruns        {d}\nchunks      {d}\ndisk bytes  {d}\nin memory   {d} bytes of tails, {d} bytes of fences and filters\n", .{
            @tagName(S.engine), st.shards, st.streams, st.runs, st.chunks, st.data_bytes, st.tail_bytes, st.meta_bytes,
        });
    } else if (std.mem.eql(u8, cmd, "check")) {
        var rep = try db.verify(gpa);
        defer rep.deinit(gpa);
        for (rep.problems.items) |p| try out.print("shard {d}, stream \"{s}\": damaged chunk at byte {d}\n", .{ p.shard, p.stream, p.chunk_offset });
        if (rep.ok()) {
            try out.print("ok: {d} chunks ({d} blocks, {d} bytes) verified\n", .{ rep.chunks, rep.blocks, rep.bytes });
        } else {
            try out.flush();
            std.process.exit(1);
        }
    } else if (std.mem.eql(u8, cmd, "get")) {
        if (args.len < 3) return usageExit(io);
        const v = (try db.get(gpa, args[2])) orelse fail(io, "not found", .{});
        defer gpa.free(v);
        try out.print("{s}\n", .{v});
    } else if (std.mem.eql(u8, cmd, "put")) {
        if (args.len < 4) return usageExit(io);
        const ttl = try ttlArg(args[4..]);
        if (ttl > 0) try db.putTtl(args[2], args[3], ttl) else try db.put(args[2], args[3]);
    } else if (std.mem.eql(u8, cmd, "delete")) {
        if (args.len < 3) return usageExit(io);
        if (!try db.contains(args[2])) fail(io, "not found", .{});
        try db.delete(args[2]);
    } else if (std.mem.eql(u8, cmd, "scan")) {
        var prefix: []const u8 = "";
        var reverse = false;
        var limit: usize = std.math.maxInt(usize);
        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            const a = args[i];
            if (std.mem.eql(u8, a, "-r")) {
                reverse = true;
            } else if (std.mem.eql(u8, a, "-n")) {
                if (i + 1 >= args.len) return usageExit(io);
                i += 1;
                limit = try std.fmt.parseInt(usize, args[i], 10);
            } else prefix = a;
        }
        const end_buf = try gpa.alloc(u8, prefix.len);
        defer gpa.free(end_buf);
        var it = try db.iterator(.{ .start = prefix, .end = sdm.streams.prefixEnd(prefix, end_buf), .reverse = reverse }, null);
        defer it.deinit();
        var n: usize = 0;
        while (n < limit) : (n += 1) {
            const p = (try it.next()) orelse break;
            try out.print("{s}\t{s}\n", .{ p.key, p.value });
        }
    } else if (std.mem.eql(u8, cmd, "compact")) {
        const before = db.stats().data_bytes;
        try db.compact();
        try out.print("compacted: {d} -> {d} bytes\n", .{ before, db.stats().data_bytes });
    } else if (std.mem.eql(u8, cmd, "streams")) {
        const list = try db.listStreams(gpa);
        defer sdm.streams.freeStreams(gpa, list);
        try out.print("{s:<32} {s:>5} {s:>10} {s:>12}\n", .{ "stream", "shard", "records", "disk bytes" });
        for (list) |st| try out.print("{s:<32} {d:>5} {d:>10} {d:>12}\n", .{ if (st.name.len == 0) "(no stream)" else st.name, st.shard, st.records, st.disk_bytes });
    } else if (std.mem.eql(u8, cmd, "incr")) {
        if (args.len < 3) return usageExit(io);
        const delta = if (args.len > 3) try std.fmt.parseInt(i64, args[3], 10) else 1;
        try out.print("{d}\n", .{try db.incr(args[2], delta)});
    } else if (std.mem.eql(u8, cmd, "trim")) {
        if (args.len < 4) return usageExit(io);
        const keep = try std.fmt.parseInt(usize, args[3], 10);
        const last = args.len > 4 and std.mem.eql(u8, args[4], "--last");
        try out.print("deleted {d}\n", .{try db.trim(args[2], keep, if (last) .last else .first)});
    } else if (std.mem.eql(u8, cmd, "backup")) {
        if (args.len < 3) return usageExit(io);
        try db.backup(Io.Dir.cwd(), args[2]);
        try out.print("backed up to {s}\n", .{args[2]});
    } else if (std.mem.eql(u8, cmd, "checkpoint")) {
        try db.checkpoint();
    } else return usageExit(io);
}
