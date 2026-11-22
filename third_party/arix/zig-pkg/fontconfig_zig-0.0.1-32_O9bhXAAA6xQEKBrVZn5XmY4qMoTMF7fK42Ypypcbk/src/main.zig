pub const raw = @import("c");
pub const Config = @import("Config.zig");
pub const Pattern = @import("Pattern.zig");
pub const ObjectSet = @import("ObjectSet.zig");
pub const FontSet = @import("FontSet.zig");
pub const CharSet = @import("CharSet.zig");
pub const result = @import("result.zig");

/// Converts Fontconfig's weight scale to OpenType's 1..1000 scale.
/// Returns null when the Fontconfig weight is out of range.
pub fn weightToOpenType(weight: i32) ?u16 {
    if (weight < raw.FC_WEIGHT_THIN or weight > raw.FC_WEIGHT_EXTRABLACK) return null;
    return @intCast(raw.FcWeightToOpenType(weight));
}

test {
    @import("std").testing.refAllDecls(@This());
}
