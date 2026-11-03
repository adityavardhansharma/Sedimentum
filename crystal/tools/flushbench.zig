//! How many durable turns a disk allows, with no store in the way: eight
//! threads append two 100-byte records each turn into a mapped file and
//! make them durable before the next turn. Run it next to an agent
//! benchmark to see what part of the durable turn rate is the disk.
//!
//!   zig-out/bin/crystal-flushbench <each|leader|fdatasync> <file>
//!
//! each:      every thread flushes its own range (msync), side by side
//! leader:    one flush at a time covers everything written so far
//! fdatasync: every thread calls fdatasync on the file

const std = @import("std");
const Io = std.Io;
const page = std.heap.page_size_min;

const threads = 8;
const turns_each = 3000;
const file_len = 64 << 20;

const Mode = enum { each, leader, fdatasync };

var mode: Mode = .each;
var map: []align(page) u8 = undefined;
var fd: std.posix.fd_t = undefined;
var end: std.atomic.Value(u64) = .init(page);
var synced: std.atomic.Value(u64) = .init(page);
var flushes: std.atomic.Value(u64) = .init(0);
var append_lock: SpinLock = .{};
var flush_lock: SpinLock = .{};

const SpinLock = struct {
    v: std.atomic.Value(u32) = .init(0),
    fn lock(l: *SpinLock) void {
        while (l.v.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
    }
    fn unlock(l: *SpinLock) void {
        l.v.store(0, .release);
    }
};

fn flush(from: u64, to: u64) void {
    switch (mode) {
        .fdatasync => _ = std.os.linux.fdatasync(fd),
        else => std.posix.msync(@alignCast(map[std.mem.alignBackward(u64, from, page)..to]), std.posix.MSF.SYNC) catch {},
    }
    _ = flushes.fetchAdd(1, .monotonic);
}

fn worker() void {
    const rec: [100]u8 = @splat('x');
    for (0..turns_each) |_| {
        for (0..2) |_| {
            append_lock.lock();
            const off = end.load(.monotonic);
            @memcpy(map[off..][0..rec.len], &rec);
            end.store(off + rec.len, .release);
            append_lock.unlock();
        }
        const target = end.load(.acquire);
        if (synced.load(.acquire) >= target) continue;
        if (mode == .leader) {
            flush_lock.lock();
            defer flush_lock.unlock();
            const from = synced.load(.acquire);
            if (from >= target) continue;
            const to = end.load(.acquire);
            flush(from, to);
            _ = synced.fetchMax(to, .release);
        } else {
            flush(synced.load(.acquire), target);
            _ = synced.fetchMax(target, .release);
        }
    }
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 3) {
        try Io.File.stderr().writeStreamingAll(io, "usage: crystal-flushbench <each|leader|fdatasync> <file>\n");
        std.process.exit(2);
    }
    mode = std.meta.stringToEnum(Mode, args[1]) orelse return error.UnknownMode;
    const f = try Io.Dir.cwd().createFile(io, args[2], .{ .read = true, .truncate = true });
    defer {
        f.close(io);
        Io.Dir.cwd().deleteFile(io, args[2]) catch {};
    }
    // Written once and synced, like a lane grown ahead of its writes.
    try f.setLength(io, file_len);
    var z: [1 << 16]u8 = @splat(0);
    var o: u64 = 0;
    while (o < file_len) : (o += z.len) try f.writePositionalAll(io, &z, o);
    try f.sync(io);
    fd = f.handle;
    map = try std.posix.mmap(null, file_len, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, fd, 0);
    defer std.posix.munmap(map);

    const t0 = Io.Clock.awake.now(io).nanoseconds;
    var ts: [threads]std.Thread = undefined;
    for (&ts) |*t| t.* = try std.Thread.spawn(.{}, worker, .{});
    for (ts) |t| t.join();
    const secs = @as(f64, @floatFromInt(Io.Clock.awake.now(io).nanoseconds - t0)) / 1e9;
    const turns = threads * turns_each;
    var buf: [256]u8 = undefined;
    const line = try std.fmt.bufPrint(&buf, "{{\"mode\":\"{s}\",\"turns\":{d},\"seconds\":{d:.3},\"turns_per_sec\":{d:.0},\"flushes\":{d}}}\n", .{ @tagName(mode), turns, secs, @as(f64, @floatFromInt(turns)) / secs, flushes.load(.monotonic) });
    try Io.File.stdout().writeStreamingAll(io, line);
}
