//! Foundations only: persistence and durability are not implemented yet.
pub const Key = @import("format/key.zig").Key;
pub const Component = @import("format/key.zig").Component;
pub const Region = @import("format/key.zig").Region;

test {
    _ = @import("format/key.zig");
}
