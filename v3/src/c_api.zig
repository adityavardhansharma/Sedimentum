//! C ABI over `Shared`. See `include/sedimentum.h` for the contract.

const std = @import("std");
const Db = @import("Db.zig");
const Shared = @import("Shared.zig");
const streams = @import("streams/Store.zig");

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
    /// The engine behind this handle has no such operation.
    unsupported = 9,
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
        error.EmptyKey, error.KeyTooLarge, error.ValueTooLarge, error.BatchTooLarge, error.InvalidArgument, error.SegmentTooLarge, error.ReservedKey, error.NotACounter, error.Overflow, error.WrongEngine => .invalid_argument,
        error.OutOfMemory => .out_of_memory,
        error.Poisoned => .poisoned,
        error.Unsupported => .unsupported,
        else => .io_error,
    };
}

fn bytes(ptr: ?[*]const u8, len: usize) []const u8 {
    return if (len == 0) &.{} else ptr.?[0..len];
}

/// What an `sdm_db*` points at: one of the three engines.
const Handle = union(enum) {
    v1: *Shared,
    v2: *streams.V2,
    v3: *streams.V3,
};

fn handle(h: ?*anyopaque) *Handle {
    return @ptrCast(@alignCast(h.?));
}

fn prefixRange(prefix: []const u8, reverse: bool, end_buf: []u8) streams.Range {
    return .{ .start = prefix, .end = streams.prefixEnd(prefix, end_buf), .reverse = reverse };
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
    // A v2 or v3 directory is refused, never opened as an empty v1
    // database beside the real one.
    const found = streams.detect(io_state.io(), std.Io.Dir.cwd(), path.?[0..path_len]) catch |err| return fail(err);
    if (found != null) return fail(error.WrongEngine);
    return openV1(path.?[0..path_len], sync_writes, memory_budget, out);
}

fn openV1(p: []const u8, sync_writes: c_int, memory_budget: usize, out: ?*?*anyopaque) Status {
    const hd = gpa.create(Handle) catch |err| return fail(err);
    const s = Shared.open(gpa, io_state.io(), std.Io.Dir.cwd(), p, .{
        .sync_writes = sync_writes != 0,
        .memory_budget = memory_budget,
    }) catch |err| {
        gpa.destroy(hd);
        return fail(err);
    };
    hd.* = .{ .v1 = s };
    out.?.* = hd;
    return .ok;
}

/// engine: 1 = v1, 2 = v2, 3 = v3, 0 = whatever the directory already holds
/// (v1 for a new one).
export fn sdm_open_engine(path: ?[*]const u8, path_len: usize, engine: c_int, sync_writes: c_int, out: ?*?*anyopaque) Status {
    if (path == null or path_len == 0 or out == null) return fail(error.InvalidArgument);
    ensureIo();
    const io = io_state.io();
    const p = path.?[0..path_len];
    const found = streams.detect(io, std.Io.Dir.cwd(), p) catch |err| return fail(err);
    const existing: c_int = if (found) |f| switch (f) {
        .v2 => 2,
        .v3 => 3,
    } else 0;
    // A stream store asked for as another engine is refused, never opened
    // as an empty database beside the real one. (v2 and v3 refuse a v1
    // directory themselves.)
    if (engine != 0 and existing != 0 and engine != existing) return fail(error.WrongEngine);
    const which: c_int = if (engine != 0) engine else if (existing != 0) existing else 1;
    if (which == 1) return openV1(p, sync_writes, 0, out);
    const hd = gpa.create(Handle) catch |err| return fail(err);
    const opts: streams.Options = .{ .sync_writes = sync_writes != 0 };
    hd.* = switch (which) {
        2 => .{ .v2 = streams.V2.open(gpa, io, std.Io.Dir.cwd(), p, opts) catch |err| {
            gpa.destroy(hd);
            return fail(err);
        } },
        3 => .{ .v3 = streams.V3.open(gpa, io, std.Io.Dir.cwd(), p, opts) catch |err| {
            gpa.destroy(hd);
            return fail(err);
        } },
        else => {
            gpa.destroy(hd);
            return fail(error.InvalidArgument);
        },
    };
    out.?.* = hd;
    return .ok;
}

/// 1, 2 or 3.
export fn sdm_engine(h: ?*anyopaque) c_int {
    return switch (handle(h).*) {
        .v1 => 1,
        .v2 => 2,
        .v3 => 3,
    };
}

export fn sdm_close(h: ?*anyopaque) void {
    if (h == null) return;
    const hd = handle(h);
    switch (hd.*) {
        inline else => |db| db.close(),
    }
    gpa.destroy(hd);
}

export fn sdm_put(h: ?*anyopaque, k: ?[*]const u8, klen: usize, v: ?[*]const u8, vlen: usize) Status {
    switch (handle(h).*) {
        inline else => |db| db.put(bytes(k, klen), bytes(v, vlen)) catch |err| return fail(err),
    }
    return .ok;
}

export fn sdm_put_ttl(h: ?*anyopaque, k: ?[*]const u8, klen: usize, v: ?[*]const u8, vlen: usize, ttl_seconds: u32) Status {
    switch (handle(h).*) {
        inline else => |db| db.putTtl(bytes(k, klen), bytes(v, vlen), ttl_seconds) catch |err| return fail(err),
    }
    return .ok;
}

/// expected_seq == 0 means "the key must not exist".
export fn sdm_put_if(h: ?*anyopaque, k: ?[*]const u8, klen: usize, v: ?[*]const u8, vlen: usize, expected_seq: u64) Status {
    switch (handle(h).*) {
        .v1 => |db| {
            const expect: Db.Expect = if (expected_seq == 0) .absent else .{ .seq = expected_seq };
            db.putIf(bytes(k, klen), bytes(v, vlen), expect) catch |err| return fail(err);
        },
        inline else => |db| {
            const expect: streams.Expect = if (expected_seq == 0) .absent else .{ .seq = expected_seq };
            db.putIf(bytes(k, klen), bytes(v, vlen), expect) catch |err| return fail(err);
        },
    }
    return .ok;
}

/// Sets the error text for a missing key and returns `.not_found`.
fn notFound() Status {
    return fail(error.NotFound);
}

export fn sdm_seq_of(h: ?*anyopaque, k: ?[*]const u8, klen: usize, out_seq: *u64) Status {
    const seq = switch (handle(h).*) {
        inline else => |db| db.seqOf(bytes(k, klen)) catch |err| return fail(err),
    };
    out_seq.* = seq orelse return notFound();
    return .ok;
}

export fn sdm_delete(h: ?*anyopaque, k: ?[*]const u8, klen: usize) Status {
    const key = bytes(k, klen);
    switch (handle(h).*) {
        .v1 => |db| {
            const existed = db.delete(key) catch |err| return fail(err);
            return if (existed) .ok else notFound();
        },
        inline else => |db| {
            if (!(db.contains(key) catch |err| return fail(err))) return notFound();
            db.delete(key) catch |err| return fail(err);
            return .ok;
        },
    }
}

export fn sdm_delete_prefix(h: ?*anyopaque, p: ?[*]const u8, plen: usize, out_count: ?*u64) Status {
    const prefix = bytes(p, plen);
    const n: u64 = switch (handle(h).*) {
        .v1 => |db| db.deletePrefix(prefix) catch |err| return fail(err),
        inline else => |db| blk: {
            const end_buf = gpa.alloc(u8, prefix.len) catch |err| return fail(err);
            defer gpa.free(end_buf);
            const n = db.count(prefixRange(prefix, false, end_buf)) catch |err| return fail(err);
            db.deletePrefix(prefix) catch |err| return fail(err);
            break :blk n;
        },
    };
    if (out_count) |c| c.* = n;
    return .ok;
}

export fn sdm_get(h: ?*anyopaque, k: ?[*]const u8, klen: usize, out_ptr: *?[*]u8, out_len: *usize) Status {
    out_ptr.* = null;
    out_len.* = 0;
    const got = switch (handle(h).*) {
        inline else => |db| db.get(gpa, bytes(k, klen)) catch |err| return fail(err),
    };
    const v = got orelse return notFound();
    out_ptr.* = v.ptr;
    out_len.* = v.len;
    return .ok;
}

export fn sdm_free(ptr: ?[*]u8, len: usize) void {
    if (ptr) |p| gpa.free(p[0..len]);
}

export fn sdm_sync(h: ?*anyopaque) Status {
    switch (handle(h).*) {
        .v1 => |db| db.sync() catch |err| return fail(err),
        // A C caller may sync from another thread than it wrote from.
        inline else => |db| db.syncAll() catch |err| return fail(err),
    }
    return .ok;
}

/// v1 keeps a count; v2 and v3 count by walking every key.
export fn sdm_count(h: ?*anyopaque) u64 {
    return switch (handle(h).*) {
        .v1 => |db| db.count(),
        inline else => |db| db.count(.{}) catch 0,
    };
}

/// Atomically adds `delta` to the decimal integer at `key` (missing = 0).
/// v2 and v3 only.
export fn sdm_incr(h: ?*anyopaque, k: ?[*]const u8, klen: usize, delta: i64, out_value: ?*i64) Status {
    const v = switch (handle(h).*) {
        .v1 => return fail(error.Unsupported),
        inline else => |db| db.incr(bytes(k, klen), delta) catch |err| return fail(err),
    };
    if (out_value) |o| o.* = v;
    return .ok;
}

/// Keeps the first (keep_last == 0) or last `keep` keys under `prefix` and
/// deletes the rest. v2 and v3 only.
export fn sdm_trim(h: ?*anyopaque, p: ?[*]const u8, plen: usize, keep: usize, keep_last: c_int, out_deleted: ?*u64) Status {
    const n = switch (handle(h).*) {
        .v1 => return fail(error.Unsupported),
        inline else => |db| db.trim(bytes(p, plen), keep, if (keep_last != 0) .last else .first) catch |err| return fail(err),
    };
    if (out_deleted) |o| o.* = n;
    return .ok;
}

/// Writes a consistent copy to `dest` (a new directory). v2 and v3 only.
export fn sdm_backup(h: ?*anyopaque, dest: ?[*]const u8, dest_len: usize) Status {
    if (dest == null or dest_len == 0) return fail(error.InvalidArgument);
    switch (handle(h).*) {
        .v1 => return fail(error.Unsupported),
        inline else => |db| db.backup(std.Io.Dir.cwd(), dest.?[0..dest_len]) catch |err| return fail(err),
    }
    return .ok;
}

/// Checks every stored checksum; returns SDM_CORRUPT when any fails.
/// v2 and v3 only (v1: use the command-line `check`).
export fn sdm_verify(h: ?*anyopaque) Status {
    switch (handle(h).*) {
        .v1 => return fail(error.Unsupported),
        inline else => |db| {
            var rep = db.verify(gpa) catch |err| return fail(err);
            defer rep.deinit(gpa);
            if (!rep.ok()) return fail(error.Corrupt);
        },
    }
    return .ok;
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
    switch (handle(h).*) {
        .v1 => |db| {
            const pairs = db.scan(gpa, Db.prefixRange(prefix, reverse != 0, end_buf), null, limit) catch |err| return fail(err);
            defer Db.freePairs(gpa, pairs);
            return packPairs(pairs, out_ptr, out_len, out_count);
        },
        inline else => |db| {
            const pairs = db.scan(gpa, prefixRange(prefix, reverse != 0, end_buf), null, limit) catch |err| return fail(err);
            defer streams.freePairs(gpa, pairs);
            return packPairs(pairs, out_ptr, out_len, out_count);
        },
    }
}

fn packPairs(pairs: anytype, out_ptr: *?[*]u8, out_len: *usize, out_count: *usize) Status {
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
