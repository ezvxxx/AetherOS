const FontSet = @This();
const c = @import("c");
const Pattern = @import("Pattern.zig");

ref: *c.FcFontSet,

pub fn fromRef(ref: *c.FcFontSet) FontSet {
    return .{ .ref = ref };
}

pub fn deinit(self: FontSet) void {
    c.FcFontSetDestroy(self.ref);
}

pub fn len(self: FontSet) usize {
    return @intCast(self.ref.nfont);
}

pub fn get(self: FontSet, index: usize) ?Pattern {
    if (index >= self.len()) return null;
    return .fromRef(self.ref.fonts[index].?);
}
