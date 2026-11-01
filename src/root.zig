//! Sedimentum: a small embedded key-value store for agent memory.
//!
//! PR 1 provides the on-disk layer: record encoding, append-only segment
//! files and crash recovery. The ordered index and the public KV API come
//! in later changes.

pub const record = @import("record.zig");
pub const segment = @import("segment.zig");
pub const Log = @import("Log.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
