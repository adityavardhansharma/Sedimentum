//! Stratum: facts over their whole life, one lane file per writer; the
//! memory structure behind Sedimentum.

pub const Stratum = @import("stratum/Stratum.zig");
pub const holo_text = @import("holo/text.zig");
pub const holo_meaning = @import("holo/Meaning.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
