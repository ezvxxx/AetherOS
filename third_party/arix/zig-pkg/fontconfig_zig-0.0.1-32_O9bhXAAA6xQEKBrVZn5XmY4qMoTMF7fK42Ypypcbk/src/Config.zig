const Config = @This();
const c = @import("c");
const Pattern = @import("Pattern.zig");
const ObjectSet = @import("ObjectSet.zig");
const FontSet = @import("FontSet.zig");
const result = @import("result.zig");

ref: *c.FcConfig,

pub fn fromRef(ref: *c.FcConfig) Config {
    return .{ .ref = ref };
}

pub fn init() error{InitializationFailed}!Config {
    return .fromRef(c.FcInitLoadConfigAndFonts() orelse return error.InitializationFailed);
}

pub fn retain(self: Config) Config {
    return .fromRef(c.FcConfigReference(self.ref).?);
}

pub fn deinit(self: Config) void {
    c.FcConfigDestroy(self.ref);
}

pub fn listFonts(self: Config, pattern: Pattern, objects: ObjectSet) error{OutOfMemory}!FontSet {
    return .fromRef(c.FcFontList(self.ref, pattern.ref, objects.ref) orelse return error.OutOfMemory);
}

pub fn substitute(self: Config, pattern: Pattern, kind: c.FcMatchKind) error{OutOfMemory}!void {
    if (c.FcConfigSubstitute(self.ref, pattern.ref, kind) == 0) return error.OutOfMemory;
}

pub fn matchFont(self: Config, pattern: Pattern) result.Error!?Pattern {
    var status: c.FcResult = c.FcResultNoMatch;
    const ref = c.FcFontMatch(self.ref, pattern.ref, &status);
    errdefer if (ref) |value| c.FcPatternDestroy(value);
    if (!try result.found(status)) {
        if (ref) |value| c.FcPatternDestroy(value);
        return null;
    }

    return .fromRef(ref orelse return error.UnexpectedResult);
}

pub fn sortFonts(self: Config, pattern: Pattern, trim: bool) result.Error!?FontSet {
    var status: c.FcResult = c.FcResultNoMatch;
    const ref = c.FcFontSort(self.ref, pattern.ref, @intFromBool(trim), null, &status);
    errdefer if (ref != null) c.FcFontSetDestroy(ref);
    if (!try result.found(status)) {
        if (ref != null) c.FcFontSetDestroy(ref);
        return null;
    }

    return .fromRef(ref orelse return error.UnexpectedResult);
}
