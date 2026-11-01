//! Sedimentum: a small embedded key-value store for agent memory.
//!
//! Values live in append-only segment files; an ordered index in memory
//! maps each live key to its newest record. Start with `Db`.

pub const Db = @import("Db.zig");
pub const Shared = @import("Shared.zig");
pub const Log = @import("Log.zig");
pub const record = @import("record.zig");
pub const segment = @import("segment.zig");
pub const index = @import("index.zig");
pub const cold = @import("cold.zig");
/// The stream stores: `streams.V2` and `streams.V3` (Lean).
pub const streams = @import("streams/Store.zig");
/// Holo: agent memory with recall, sedimentation and token-budgeted briefs.
pub const Holo = @import("holo/Holo.zig");
pub const holo_text = @import("holo/text.zig");
pub const holo_meaning = @import("holo/Meaning.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
