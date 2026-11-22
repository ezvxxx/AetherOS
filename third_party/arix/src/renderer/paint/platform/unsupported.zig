const std = @import("std");
const Rect = @import("../../geometry/Rect.zig");
const TextDisplayItem = @import("../display/display_item.zig").TextDisplayItem;
const aether_font = @import("aether_font");

/// Premultiplied RGBA text bitmap for the AetherOS software canvas.
pub const Bitmap = struct {
    pixels: [][4]u8 = &.{},
    width: usize = 0,
    height: usize = 0,
    x: usize = 0,
    y: usize = 0,
    pub fn deinit(self: Bitmap, allocator: std.mem.Allocator) void { if (self.pixels.len != 0) allocator.free(self.pixels); }
};

pub fn rasterize(allocator: std.mem.Allocator, text: TextDisplayItem, clip: Rect, scale: f64) !Bitmap {
    if (!std.math.isFinite(scale) or scale <= 0 or clip.x < 0 or clip.y < 0 or clip.width <= 0 or clip.height <= 0) return error.InvalidDimensions;
    const x: usize = @intFromFloat(@floor(clip.x));
    const y: usize = @intFromFloat(@floor(clip.y));
    const right: usize = @intFromFloat(@ceil(clip.x + clip.width));
    const bottom: usize = @intFromFloat(@ceil(clip.y + clip.height));
    const width = right - x;
    const height = bottom - y;
    const pixels = try allocator.alloc([4]u8, try std.math.mul(usize, width, height));
    @memset(pixels, .{ 0, 0, 0, 0 });
    const bitmap: Bitmap = .{ .pixels = pixels, .width = width, .height = height, .x = x, .y = y };
    errdefer bitmap.deinit(allocator);
    if (text.font.size <= 0 or text.color[3] <= 0) return bitmap;

    const size: u8 = @intFromFloat(@max(1, @min(48, @round(text.font.size * scale))));
    var mask: [48 * 48]u8 = undefined;
    const red: f64 = std.math.clamp(text.color[0], 0, 1);
    const green: f64 = std.math.clamp(text.color[1], 0, 1);
    const blue: f64 = std.math.clamp(text.color[2], 0, 1);
    const opacity: f64 = std.math.clamp(text.color[3], 0, 1);
    for (text.glyphs) |glyph| {
        const metrics = aether_font.rasterGlyph(allocator, glyph.id, size, &mask) orelse continue;
        const gx_f = (text.baseline_origin[0] + glyph.position[0]) * scale;
        const gy_f = (text.baseline_origin[1] - glyph.position[1]) * scale;
        if (!std.math.isFinite(gx_f) or !std.math.isFinite(gy_f) or @abs(gx_f) > 100000 or @abs(gy_f) > 100000) continue;
        const gx: i64 = @intFromFloat(@round(gx_f));
        const gy: i64 = @intFromFloat(@round(gy_f));
        for (0..metrics.height) |row| {
            const py = gy + @as(i64, @intCast(row));
            if (py < @as(i64, @intCast(y)) or py >= @as(i64, @intCast(bottom))) continue;
            for (0..metrics.width) |col| {
                const px = gx + @as(i64, @intCast(col));
                if (px < @as(i64, @intCast(x)) or px >= @as(i64, @intCast(right))) continue;
                const alpha = @as(f64, @floatFromInt(mask[row * 48 + col])) / 255 * opacity;
                if (alpha <= 0) continue;
                const pixel = &pixels[(@as(usize, @intCast(py)) - y) * width + (@as(usize, @intCast(px)) - x)];
                const src_alpha = alpha * 255;
                const inv = 1 - alpha;
                pixel[0] = @intFromFloat(@round(std.math.clamp(red * src_alpha + @as(f64, @floatFromInt(pixel[0])) * inv, 0, 255)));
                pixel[1] = @intFromFloat(@round(std.math.clamp(green * src_alpha + @as(f64, @floatFromInt(pixel[1])) * inv, 0, 255)));
                pixel[2] = @intFromFloat(@round(std.math.clamp(blue * src_alpha + @as(f64, @floatFromInt(pixel[2])) * inv, 0, 255)));
                pixel[3] = @intFromFloat(@round(std.math.clamp(src_alpha + @as(f64, @floatFromInt(pixel[3])) * inv, 0, 255)));
            }
        }
    }
    return bitmap;
}
