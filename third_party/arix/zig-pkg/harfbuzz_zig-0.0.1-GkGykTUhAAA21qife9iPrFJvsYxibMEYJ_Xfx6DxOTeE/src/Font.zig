const Font = @This();
const std = @import("std");
const c = @import("c");

ref: *c.hb_font_t,
units_per_em: u32,

/// Opens a font in design units, including FreeType's encoded named-instance index.
pub fn init(path: [:0]const u8, index: u32) !Font {
    if (std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidArgument;
    const blob = c.hb_blob_create_from_file_or_fail(path.ptr) orelse return error.FontOpenFailed;
    defer c.hb_blob_destroy(blob);

    const face = c.hb_face_create(blob, index & 0xffff).?;
    defer c.hb_face_destroy(face);
    if (face == c.hb_face_get_empty()) return error.OutOfMemory;
    if (c.hb_face_get_glyph_count(face) == 0) return error.InvalidFont;

    const units = c.hb_face_get_upem(face);
    if (units == 0 or units > std.math.maxInt(i32)) return error.InvalidFont;
    const ref = c.hb_font_create(face).?;
    if (ref == c.hb_font_get_empty()) return error.OutOfMemory;

    c.hb_ot_font_set_funcs(ref);
    c.hb_font_set_scale(ref, @intCast(units), @intCast(units));
    const instance = (index >> 16) & 0x7fff;
    if (instance != 0) c.hb_font_set_var_named_instance(ref, instance - 1);

    return .{
        .ref = ref,
        .units_per_em = units,
    };
}

pub fn deinit(self: Font) void {
    c.hb_font_destroy(self.ref);
}
