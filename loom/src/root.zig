//! Loom: agent memory that learns the shape of what it is told.
pub const Loom = @import("Loom.zig");
pub const Meaning = Loom.Meaning;
pub const words = @import("words.zig");
pub const ans = @import("ans.zig");

test {
    _ = Loom;
    _ = words;
    _ = ans;
    _ = Meaning;
}
