//! Sedimentum v3 (Lean): a stream store with no write-ahead log; each
//! stream's tail lives in a page of its shard. Start with `V3`.
//!
//! This folder also has the tools that open every key-value format
//! (v1, v2 and v3): the `sedimentum` CLI, the C library and the kiban
//! comparison benchmark, so it carries the v1 and v2 code they need.

pub const streams = @import("streams/Store.zig");
pub const V3 = streams.V3;
pub const V2 = streams.V2;
pub const Db = @import("Db.zig");
pub const Shared = @import("Shared.zig");
pub const Log = @import("Log.zig");
pub const record = @import("record.zig");
pub const segment = @import("segment.zig");
pub const index = @import("index.zig");
pub const cold = @import("cold.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
