const ObjectSet = @This();
const c = @import("c");

ref: *c.FcObjectSet,

pub fn fromRef(ref: *c.FcObjectSet) ObjectSet {
    return .{ .ref = ref };
}

/// Creates the property selection for Config.listFonts().
pub fn init(objects: []const [*:0]const u8) error{OutOfMemory}!ObjectSet {
    const self: ObjectSet = .fromRef(c.FcObjectSetCreate() orelse return error.OutOfMemory);
    errdefer self.deinit();
    for (objects) |object| {
        if (c.FcObjectSetAdd(self.ref, object) == 0) return error.OutOfMemory;
    }

    return self;
}

pub fn deinit(self: ObjectSet) void {
    c.FcObjectSetDestroy(self.ref);
}
