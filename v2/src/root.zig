//! Sedimentum v2: a stream store with a write-ahead log plus 64 KB tails
//! in RAM. Start with `V2`.

pub const streams = @import("streams/Store.zig");
pub const V2 = streams.V2;

test {
    @import("std").testing.refAllDecls(@This());
}
