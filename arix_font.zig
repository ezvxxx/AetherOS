//! Minimal Arix font bridge using AetherOS's embedded Inter TTF and z2d.
const std = @import("std");
const z2d = @import("z2d");
const font_bytes = @embedFile("assets/fonts/Inter-Regular.ttf");
const glyph_limit = 48;

const Glyph = struct {
    valid: bool = false,
    codepoint: u21 = 0,
    size: u8 = 0,
    width: u8 = 0,
    height: u8 = 0,
    advance: u8 = 0,
    alpha: [glyph_limit * glyph_limit]u8 = @splat(0),
};

var face: ?z2d.font.Font = null;
var cache: [512]Glyph = @splat(.{});
var cache_cursor: usize = 0;

pub fn init(allocator: std.mem.Allocator) bool {
    if (face != null) return true;
    const file = z2d.font.File.loadBuffer(font_bytes) catch return false;
    face = file.loadFontIndex(0) catch return false;
    _ = allocator;
    return true;
}

pub const RasterGlyph = struct { width: u8, height: u8, advance: u8 };

pub fn rasterGlyph(allocator: std.mem.Allocator, codepoint: u21, size: u8, out: []u8) ?RasterGlyph {
    if (out.len < glyph_limit * glyph_limit or size == 0 or size > glyph_limit) return null;
    if (face == null and !init(allocator)) return null;
    for (&cache) |*item| if (item.valid and item.codepoint == codepoint and item.size == size) {
        @memcpy(out[0 .. glyph_limit * glyph_limit], &item.alpha);
        return .{ .width = item.width, .height = item.height, .advance = item.advance };
    };

    const active_face = if (face) |*value| value else return null;
    const slot = &cache[cache_cursor];
    cache_cursor = (cache_cursor + 1) % cache.len;
    slot.* = .{ .valid = true, .codepoint = codepoint, .size = size };
    var surface = z2d.surface.Surface.init(.image_surface_alpha8, allocator, glyph_limit, glyph_limit) catch {
        slot.valid = false;
        return null;
    };
    defer surface.deinit(allocator);
    const encoded = encode(codepoint);
    const glyph_slice = encoded.bytes[0..encoded.length];
    const options: z2d.text.ShowTextOptions = .{ .size = @floatFromInt(size) };
    const advance = z2d.text.measure(allocator, active_face, glyph_slice, options) catch return null;
    const pixel = z2d.Pixel{ .alpha8 = .{ .a = 255 } };
    const pattern = z2d.Pattern{ .opaque_pattern = .{ .pixel = pixel } };
    z2d.text.show(allocator, &surface, &pattern, active_face, glyph_slice, 2, 0, options) catch return null;
    slot.advance = @intCast(@max(1, @min(glyph_limit - 1, @as(usize, @intFromFloat(@ceil(advance))))));
    for (surface.image_surface_alpha8.buf, 0..) |alpha, index| {
        slot.alpha[index] = alpha.a;
        if (alpha.a != 0) {
            slot.width = @max(slot.width, @as(u8, @intCast(index % glyph_limit + 1)));
            slot.height = @max(slot.height, @as(u8, @intCast(index / glyph_limit + 1)));
        }
    }
    @memcpy(out[0 .. glyph_limit * glyph_limit], &slot.alpha);
    return .{ .width = slot.width, .height = slot.height, .advance = slot.advance };
}

const Encoded = struct { bytes: [4]u8, length: usize };
fn encode(cp: u21) Encoded {
    var result: Encoded = .{ .bytes = @splat(0), .length = 0 };
    if (cp < 0x80) {
        result.bytes[0] = @intCast(cp); result.length = 1;
    } else if (cp < 0x800) {
        result.bytes[0] = @intCast(0xc0 | (cp >> 6)); result.bytes[1] = @intCast(0x80 | (cp & 0x3f)); result.length = 2;
    } else if (cp < 0x10000) {
        result.bytes[0] = @intCast(0xe0 | (cp >> 12)); result.bytes[1] = @intCast(0x80 | ((cp >> 6) & 0x3f)); result.bytes[2] = @intCast(0x80 | (cp & 0x3f)); result.length = 3;
    } else {
        result.bytes[0] = @intCast(0xf0 | (cp >> 18)); result.bytes[1] = @intCast(0x80 | ((cp >> 12) & 0x3f)); result.bytes[2] = @intCast(0x80 | ((cp >> 6) & 0x3f)); result.bytes[3] = @intCast(0x80 | (cp & 0x3f)); result.length = 4;
    }
    return result;
}
