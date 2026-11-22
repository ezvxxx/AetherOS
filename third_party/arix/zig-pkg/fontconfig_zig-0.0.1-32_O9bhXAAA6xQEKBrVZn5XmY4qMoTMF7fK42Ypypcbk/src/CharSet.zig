const CharSet = @This();
const c = @import("c");

ref: *const c.FcCharSet,

pub fn fromRef(ref: *const c.FcCharSet) CharSet {
    return .{ .ref = ref };
}

pub fn contains(self: CharSet, codepoint: u21) bool {
    return c.FcCharSetHasChar(self.ref, codepoint) != 0;
}
