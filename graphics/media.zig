//! Shared decoded-image storage and framebuffer drawing helpers.
const std = @import("std");
const s = @import("../system/state.zig");
const canvas = @import("canvas.zig");
const vm = @import("../memory/vm.zig");

pub const Picture = struct { pixels: [*]u32, width: usize, height: usize, pages: usize };
var selected: ?Picture = null;
var selected_name: [64]u8 = @splat(0);
var selected_name_len: usize = 0;

pub fn allocate(width: usize, height: usize) ?Picture {
    if (width == 0 or height == 0 or width > 8192 or height > 8192) return null;
    const count = std.math.mul(usize, width, height) catch return null;
    if (count > 4 * 1024 * 1024) return null;
    const bytes = std.math.mul(usize, count, @sizeOf(u32)) catch return null;
    const pages = (bytes + 4095) / 4096;
    const memory = vm.allocatePages(pages) orelse return null;
    const pixels: [*]u32 = @ptrCast(@alignCast(memory));
    @memset(pixels[0..count], 0);
    return .{ .pixels = pixels, .width = width, .height = height, .pages = pages };
}

pub fn release(picture: Picture) void {
    for (0..picture.pages) |i| vm.freePage(@intFromPtr(picture.pixels) + @as(u64, @intCast(i)) * 4096);
}

pub fn setSelected(picture: Picture, name: []const u8) void {
    clearSelected();
    selected = picture;
    selected_name = @splat(0);
    selected_name_len = @min(name.len, selected_name.len);
    @memcpy(selected_name[0..selected_name_len], name[0..selected_name_len]);
}

pub fn clearSelected() void {
    if (selected) |old| release(old);
    selected = null;
    selected_name = @splat(0);
    selected_name_len = 0;
}

pub fn current() ?Picture {
    return selected;
}
pub fn currentName() []const u8 {
    return if (selected != null) selected_name[0..selected_name_len] else "No image";
}

fn channel(pixel: u32, size: u8, shift: u8) u8 {
    if (size == 0) return 0;
    const max_value: u32 = (@as(u32, 1) << @intCast(size)) - 1;
    return @intCast((((pixel >> @intCast(shift)) & max_value) * 255 + max_value / 2) / max_value);
}

fn over(source: u32, dest: u32) u32 {
    const r: u8 = @truncate(source >> 24);
    const g: u8 = @truncate(source >> 16);
    const b: u8 = @truncate(source >> 8);
    const alpha: u32 = source & 0xff;
    if (alpha == 255) return canvas.color(r, g, b);
    if (alpha == 0) return dest;
    const inverse = 255 - alpha;
    const blend = struct {
        fn one(src: u8, dst: u8, a: u32, inv: u32) u8 {
            return @intCast((@as(u32, src) * a + @as(u32, dst) * inv + 127) / 255);
        }
    }.one;
    return canvas.color(
        blend(r, channel(dest, s.fb.red_mask_size, s.fb.red_mask_shift), alpha, inverse),
        blend(g, channel(dest, s.fb.green_mask_size, s.fb.green_mask_shift), alpha, inverse),
        blend(b, channel(dest, s.fb.blue_mask_size, s.fb.blue_mask_shift), alpha, inverse),
    );
}

pub fn drawScaled(picture: Picture, x: u64, y: u64, width: u64, height: u64) void {
    if (picture.width == 0 or picture.height == 0 or width == 0 or height == 0) return;
    const right = @min(x +| width, s.fb.width);
    const bottom = @min(y +| height, s.fb.height);
    if (x >= right or y >= bottom) return;
    const stride: usize = @intCast(s.fb.pitch / 4);
    var dy = y;
    while (dy < bottom) : (dy += 1) {
        const sy: usize = @intCast(@min(picture.height - 1, ((dy - y) * picture.height) / height));
        var dx = x;
        while (dx < right) : (dx += 1) {
            const sx: usize = @intCast(@min(picture.width - 1, ((dx - x) * picture.width) / width));
            const source = picture.pixels[sy * picture.width + sx];
            const index = @as(usize, @intCast(dy)) * stride + @as(usize, @intCast(dx));
            s.pixels[index] = over(source, s.pixels[index]);
        }
    }
}

pub fn drawFit(picture: Picture, x: u64, y: u64, width: u64, height: u64) void {
    if (picture.width == 0 or picture.height == 0 or width == 0 or height == 0) return;
    const sx = @as(f64, @floatFromInt(width)) / @as(f64, @floatFromInt(picture.width));
    const sy = @as(f64, @floatFromInt(height)) / @as(f64, @floatFromInt(picture.height));
    const scale = @min(sx, sy);
    const draw_w: u64 = @max(1, @as(u64, @intFromFloat(@as(f64, @floatFromInt(picture.width)) * scale)));
    const draw_h: u64 = @max(1, @as(u64, @intFromFloat(@as(f64, @floatFromInt(picture.height)) * scale)));
    drawScaled(picture, x + (width -| draw_w) / 2, y + (height -| draw_h) / 2, draw_w, draw_h);
}

/// Draw a viewport-sized, unscaled slice of a picture. Used by browser pages
/// rendered into a tall offscreen document image so normal page scrolling can
/// reveal the rest of the document.
pub fn drawRegion(picture: Picture, x: u64, y: u64, source_y: usize, width: u64, height: u64) void {
    if (picture.width == 0 or picture.height == 0 or width == 0 or height == 0 or source_y >= picture.height) return;
    const draw_w = @min(@min(width, picture.width), s.fb.width -| x);
    const draw_h = @min(@min(height, picture.height - source_y), s.fb.height -| y);
    if (draw_w == 0 or draw_h == 0) return;
    const stride: usize = @intCast(s.fb.pitch / 4);
    for (0..draw_h) |row| {
        const source = (source_y + row) * picture.width;
        const dest = (@as(usize, @intCast(y)) + row) * stride + @as(usize, @intCast(x));
        for (0..draw_w) |column| {
            const pixel = picture.pixels[source + column];
            const index = dest + column;
            s.pixels[index] = over(pixel, s.pixels[index]);
        }
    }
}

/// Fills a destination rectangle while preserving aspect ratio, cropping the
/// source around its center (or toward the right edge when requested).
pub fn drawCover(picture: Picture, x: u64, y: u64, width: u64, height: u64, align_right: bool) void {
    if (picture.width == 0 or picture.height == 0 or width == 0 or height == 0) return;
    const target_ratio = @as(f64, @floatFromInt(width)) / @as(f64, @floatFromInt(height));
    const source_ratio = @as(f64, @floatFromInt(picture.width)) / @as(f64, @floatFromInt(picture.height));
    var crop_x: usize = 0;
    var crop_y: usize = 0;
    var crop_w = picture.width;
    var crop_h = picture.height;
    if (source_ratio > target_ratio) {
        crop_w = @max(1, @as(usize, @intFromFloat(@as(f64, @floatFromInt(picture.height)) * target_ratio)));
        crop_x = if (align_right) picture.width -| crop_w else (picture.width -| crop_w) / 2;
    } else {
        crop_h = @max(1, @as(usize, @intFromFloat(@as(f64, @floatFromInt(picture.width)) / target_ratio)));
        crop_y = (picture.height -| crop_h) / 2;
    }
    const right = @min(x +| width, s.fb.width);
    const bottom = @min(y +| height, s.fb.height);
    if (x >= right or y >= bottom) return;
    const stride: usize = @intCast(s.fb.pitch / 4);
    var dy = y;
    while (dy < bottom) : (dy += 1) {
        const sy = crop_y + @min(crop_h - 1, @as(usize, @intCast((dy - y) * crop_h / height)));
        var dx = x;
        while (dx < right) : (dx += 1) {
            const sx = crop_x + @min(crop_w - 1, @as(usize, @intCast((dx - x) * crop_w / width)));
            const source = picture.pixels[sy * picture.width + sx];
            const index = @as(usize, @intCast(dy)) * stride + @as(usize, @intCast(dx));
            s.pixels[index] = over(source, s.pixels[index]);
        }
    }
}
