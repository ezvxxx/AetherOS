const Pattern = @This();
const std = @import("std");
const c = @import("c");
const result = @import("result.zig");
const CharSet = @import("CharSet.zig");

ref: *c.FcPattern,

pub fn fromRef(ref: *c.FcPattern) Pattern {
    return .{ .ref = ref };
}

pub fn init() error{OutOfMemory}!Pattern {
    return .fromRef(c.FcPatternCreate() orelse return error.OutOfMemory);
}

pub fn retain(self: Pattern) Pattern {
    c.FcPatternReference(self.ref);
    return self;
}

pub fn deinit(self: Pattern) void {
    c.FcPatternDestroy(self.ref);
}

/// Appends a copied string value. `object` is a native key such as raw.FC_FAMILY.
/// Values may contain arbitrary bytes (e.g. filesystem paths), except NUL.
pub fn addString(
    self: Pattern,
    allocator: std.mem.Allocator,
    object: [*:0]const u8,
    value: []const u8,
) !void {
    if (std.mem.indexOfScalar(u8, value, 0) != null) return error.EmbeddedNull;
    const terminated = try allocator.dupeSentinel(u8, value, 0);
    defer allocator.free(terminated);

    if (c.FcPatternAddString(self.ref, object, terminated.ptr) == 0) return error.OutOfMemory;
}

pub fn addInteger(self: Pattern, object: [*:0]const u8, value: c_int) error{OutOfMemory}!void {
    if (c.FcPatternAddInteger(self.ref, object, value) == 0) return error.OutOfMemory;
}

/// Returns borrowed bytes, invalidated by removal/replacement of the value or
/// destruction of the pattern. Missing properties/indices return null.
pub fn getString(self: Pattern, object: [*:0]const u8, index: u32) result.Error!?[:0]const u8 {
    const native_index = std.math.cast(c_int, index) orelse return null;
    var value: [*c]c.FcChar8 = null;
    if (!try result.found(c.FcPatternGetString(
        self.ref,
        object,
        native_index,
        &value,
    ))) return null;
    if (value == null) return error.UnexpectedResult;

    return std.mem.span(value);
}

pub fn getInteger(self: Pattern, object: [*:0]const u8, index: u32) result.Error!?c_int {
    const native_index = std.math.cast(c_int, index) orelse return null;
    var value: c_int = undefined;
    if (!try result.found(c.FcPatternGetInteger(
        self.ref,
        object,
        native_index,
        &value,
    ))) return null;

    return value;
}

pub fn getCharSet(self: Pattern, object: [*:0]const u8, index: u32) result.Error!?CharSet {
    const native_index = std.math.cast(c_int, index) orelse return null;
    var value: ?*c.FcCharSet = null;
    if (!try result.found(c.FcPatternGetCharSet(
        self.ref,
        object,
        native_index,
        &value,
    ))) return null;

    return .fromRef(value orelse return error.UnexpectedResult);
}

/// Fills in Fontconfig defaults after Config.substitute(), before matching/sorting.
pub fn defaultSubstitute(self: Pattern) void {
    c.FcDefaultSubstitute(self.ref);
}
