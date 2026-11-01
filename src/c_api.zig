//! C ABI over `Shared`. See `include/sedimentum.h` for the contract.

const std = @import("std");
const Db = @import("Db.zig");
const Shared = @import("Shared.zig");

const gpa = std.heap.smp_allocator;

pub const Status = enum(c_int) {
    ok = 0,
    not_found = 1,
    conflict = 2,
    locked = 3,
    corrupt = 4,
    invalid_argument = 5,
    io_error = 6,
    out_of_memory = 7,
    poisoned = 8,
};

var io_state: std.Io.Threaded = undefined;
/// 0 = not started, 1 = initializing, 2 = ready.
var io_ready: std.atomic.Value(u8) = .init(0);

fn ensureIo() void {
    if (io_ready.load(.acquire) == 2) return;
    if (io_ready.cmpxchgStrong(0, 1, .acquire, .acquire) == null) {
        io_state = std.Io.Threaded.init(gpa, .{});
        io_ready.store(2, .release);
        return;
    }
    while (io_ready.load(.acquire) != 2) std.atomic.spinLoopHint();
}

threadlocal var last_error_buf: [256]u8 = undefined;
threadlocal var last_error_len: usize = 0;

fn fail(err: anyerror) Status {
    const msg = @errorName(err);
    const n = @min(msg.len, last_error_buf.len - 1);
    @memcpy(last_error_buf[0..n], msg[0..n]);
    last_error_buf[n] = 0;
    last_error_len = n;
    return switch (err) {
        error.NotFound => .not_found,
        error.Conflict => .conflict,
        error.Locked => .locked,
        error.Corrupt => .corrupt,
        error.EmptyKey, error.KeyTooLarge, error.ValueTooLarge, error.BatchTooLarge, error.InvalidArgument, error.SegmentTooLarge => .invalid_argument,
        error.OutOfMemory => .out_of_memory,
        error.Poisoned => .poisoned,
        else => .io_error,
    };
}

fn bytes(ptr: ?[*]const u8, len: usize) []const u8 {
    return if (len == 0) &.{} else ptr.?[0..len];
}

fn handle(h: ?*anyopaque) *Shared {
    return @ptrCast(@alignCast(h.?));
}

export fn sdm_last_error() [*:0]const u8 {
    last_error_buf[last_error_len] = 0;
    return @ptrCast(&last_error_buf);
}

export fn sdm_open(path: ?[*]const u8, path_len: usize, sync_writes: c_int, out: ?*?*anyopaque) Status {
    return sdm_open_capped(path, path_len, sync_writes, 0, out);
}

export fn sdm_open_capped(path: ?[*]const u8, path_len: usize, sync_writes: c_int, memory_budget: usize, out: ?*?*anyopaque) Status {
    if (path == null or path_len == 0 or out == null) return fail(error.InvalidArgument);
    ensureIo();
    const s = Shared.open(gpa, io_state.io(), std.Io.Dir.cwd(), path.?[0..path_len], .{
        .sync_writes = sync_writes != 0,
        .memory_budget = memory_budget,
    }) catch |err| return fail(err);
    out.?.* = s;
    return .ok;
}

export fn sdm_close(h: ?*anyopaque) void {
    if (h == null) return;
    handle(h).close();
}

export fn sdm_put(h: ?*anyopaque, k: ?[*]const u8, klen: usize, v: ?[*]const u8, vlen: usize) Status {
    handle(h).put(bytes(k, klen), bytes(v, vlen)) catch |err| return fail(err);
    return .ok;
}

export fn sdm_put_ttl(h: ?*anyopaque, k: ?[*]const u8, klen: usize, v: ?[*]const u8, vlen: usize, ttl_seconds: u32) Status {
    handle(h).putTtl(bytes(k, klen), bytes(v, vlen), ttl_seconds) catch |err| return fail(err);
    return .ok;
}

/// expected_seq == 0 means "the key must not exist".
export fn sdm_put_if(h: ?*anyopaque, k: ?[*]const u8, klen: usize, v: ?[*]const u8, vlen: usize, expected_seq: u64) Status {
    const expect: Db.Expect = if (expected_seq == 0) .absent else .{ .seq = expected_seq };
    handle(h).putIf(bytes(k, klen), bytes(v, vlen), expect) catch |err| return fail(err);
    return .ok;
}

/// Sets the error text for a missing key and returns `.not_found`.
fn notFound() Status {
    return fail(error.NotFound);
}

export fn sdm_seq_of(h: ?*anyopaque, k: ?[*]const u8, klen: usize, out_seq: *u64) Status {
    out_seq.* = (handle(h).seqOf(bytes(k, klen)) catch |err| return fail(err)) orelse return notFound();
    return .ok;
}

export fn sdm_delete(h: ?*anyopaque, k: ?[*]const u8, klen: usize) Status {
    const existed = handle(h).delete(bytes(k, klen)) catch |err| return fail(err);
    return if (existed) .ok else notFound();
}

export fn sdm_delete_prefix(h: ?*anyopaque, p: ?[*]const u8, plen: usize, out_count: ?*u64) Status {
    const n = handle(h).deletePrefix(bytes(p, plen)) catch |err| return fail(err);
    if (out_count) |c| c.* = n;
    return .ok;
}

export fn sdm_get(h: ?*anyopaque, k: ?[*]const u8, klen: usize, out_ptr: *?[*]u8, out_len: *usize) Status {
    out_ptr.* = null;
    out_len.* = 0;
    const v = (handle(h).get(gpa, bytes(k, klen)) catch |err| return fail(err)) orelse return notFound();
    out_ptr.* = v.ptr;
    out_len.* = v.len;
    return .ok;
}

export fn sdm_free(ptr: ?[*]u8, len: usize) void {
    if (ptr) |p| gpa.free(p[0..len]);
}

export fn sdm_sync(h: ?*anyopaque) Status {
    handle(h).sync() catch |err| return fail(err);
    return .ok;
}

export fn sdm_count(h: ?*anyopaque) u64 {
    return handle(h).count();
}

/// Scans keys starting with `prefix` and returns up to `limit` pairs in one
/// buffer: repeated [u32 key_len][key][u32 value_len][value], little endian.
export fn sdm_scan_prefix(
    h: ?*anyopaque,
    p: ?[*]const u8,
    plen: usize,
    reverse: c_int,
    limit: usize,
    out_ptr: *?[*]u8,
    out_len: *usize,
    out_count: *usize,
) Status {
    out_ptr.* = null;
    out_len.* = 0;
    out_count.* = 0;
    const prefix = bytes(p, plen);
    const end_buf = gpa.alloc(u8, prefix.len) catch |err| return fail(err);
    defer gpa.free(end_buf);
    const pairs = handle(h).scan(gpa, Db.prefixRange(prefix, reverse != 0, end_buf), null, limit) catch |err| return fail(err);
    defer Db.freePairs(gpa, pairs);
    var total: usize = 0;
    for (pairs) |pair| total += 8 + pair.key.len + pair.value.len;
    if (total == 0) return .ok;
    const buf = gpa.alloc(u8, total) catch |err| return fail(err);
    var pos: usize = 0;
    for (pairs) |pair| {
        std.mem.writeInt(u32, buf[pos..][0..4], @intCast(pair.key.len), .little);
        @memcpy(buf[pos + 4 ..][0..pair.key.len], pair.key);
        pos += 4 + pair.key.len;
        std.mem.writeInt(u32, buf[pos..][0..4], @intCast(pair.value.len), .little);
        @memcpy(buf[pos + 4 ..][0..pair.value.len], pair.value);
        pos += 4 + pair.value.len;
    }
    out_ptr.* = buf.ptr;
    out_len.* = total;
    out_count.* = pairs.len;
    return .ok;
}
