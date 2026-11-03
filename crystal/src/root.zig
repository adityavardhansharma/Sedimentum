//! Crystal: agent memory that keeps what is true, built from first principles.
pub const Crystal = @import("Crystal.zig");
pub const Meaning = Crystal.Meaning;
pub const words = @import("words.zig");
pub const ans = @import("ans.zig");

test {
    _ = Crystal;
    _ = words;
    _ = ans;
    _ = Meaning;
}
