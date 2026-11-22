const Buffer = @This();
const std = @import("std");
const c = @import("c");
const Font = @import("Font.zig");
const common = @import("common.zig");
const Direction = common.Direction;

ref: *c.hb_buffer_t,

pub fn init() error{OutOfMemory}!Buffer {
    const ref = c.hb_buffer_create().?;
    if (c.hb_buffer_allocation_successful(ref) == 0) {
        c.hb_buffer_destroy(ref);
        return error.OutOfMemory;
    }

    return .{ .ref = ref };
}

pub fn deinit(self: Buffer) void {
    c.hb_buffer_destroy(self.ref);
}

/// Shapes one script/direction/font run with the surrounding UTF-8 as context.
pub fn shape(
    self: Buffer,
    font: Font,
    text: []const u8,
    start: usize,
    end: usize,
    direction: Direction,
    script: c.hb_script_t,
) !Glyphs {
    if (start > end or end > text.len) return error.InvalidTextRange;
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
    if ((start < text.len and text[start] & 0xc0 == 0x80) or
        (end < text.len and text[end] & 0xc0 == 0x80)) return error.InvalidTextRange;
    const length = std.math.cast(c_int, text.len) orelse return error.InputTooLong;

    c.hb_buffer_clear_contents(self.ref);
    c.hb_buffer_set_direction(
        self.ref,
        if (direction == .ltr) c.HB_DIRECTION_LTR else c.HB_DIRECTION_RTL,
    );
    c.hb_buffer_set_script(self.ref, script);
    c.hb_buffer_set_language(self.ref, c.hb_language_from_string("und", -1));
    c.hb_buffer_set_cluster_level(self.ref, c.HB_BUFFER_CLUSTER_LEVEL_MONOTONE_GRAPHEMES);
    c.hb_buffer_add_utf8(self.ref, text.ptr, length, @intCast(start), @intCast(end - start));

    if (c.hb_buffer_allocation_successful(self.ref) == 0) return error.OutOfMemory;
    c.hb_shape(font.ref, self.ref, null, 0);
    if (c.hb_buffer_allocation_successful(self.ref) == 0) return error.OutOfMemory;

    var info_count: c_uint = 0;
    var position_count: c_uint = 0;
    const infos = c.hb_buffer_get_glyph_infos(self.ref, &info_count);
    const positions = c.hb_buffer_get_glyph_positions(self.ref, &position_count);
    if (info_count != position_count) return error.InvalidGlyphData;

    return .{
        .infos = if (info_count == 0) &.{} else infos[0..info_count],
        .positions = if (position_count == 0) &.{} else positions[0..position_count],
    };
}

pub const Glyphs = struct {
    infos: []const c.hb_glyph_info_t,
    positions: []const c.hb_glyph_position_t,
};
