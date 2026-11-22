const s = @import("../system/state.zig");
const vm = @import("../memory/vm.zig");
var cursor_drawn = false;
var cursor_x: u64 = 0;
var cursor_y: u64 = 0;

/// Allocate an off-screen frame so complex UI drawing is never shown midway.
pub fn initBackbuffer() bool {
    const bytes = s.fb.pitch * s.fb.height;
    if (bytes == 0 or bytes > 128 * 1024 * 1024) return false;
    const pages: usize = @intCast((bytes + 4095) / 4096);
    const memory = vm.allocatePages(pages) orelse return false;
    const aligned: [*]align(4) u8 = @alignCast(memory);
    s.framebuffer_backbuffer = @ptrCast(aligned);
    s.pixels = @ptrCast(aligned);
    s.framebuffer_backbuffer_active = true;
    return true;
}

pub fn hasBackbuffer() bool {
    return s.framebuffer_backbuffer != null;
}

pub fn presentFrame() void {
    const source = s.framebuffer_backbuffer orelse {
        drawMouseCursor();
        return;
    };
    const destination: [*]u32 = @ptrCast(@alignCast(s.fb.address orelse return));
    const pixel_count: usize = @intCast((s.fb.pitch * s.fb.height) / 4);
    @memcpy(destination[0..pixel_count], source[0..pixel_count]);
    cursor_drawn = false;
    presentCursor();
}

pub fn presentRegion(x: u64, y: u64, width: u64, height: u64) void {
    const source = s.framebuffer_backbuffer orelse return;
    const destination: [*]u32 = @ptrCast(@alignCast(s.fb.address orelse return));
    if (x >= s.fb.width or y >= s.fb.height or width == 0 or height == 0) return;
    const right = @min(x +| width, s.fb.width);
    const bottom = @min(y +| height, s.fb.height);
    const stride: usize = @intCast(s.fb.pitch / 4);
    const left_i: usize = @intCast(x);
    const copy_width: usize = @intCast(right - x);
    var row = y;
    while (row < bottom) : (row += 1) {
        const offset = @as(usize, @intCast(row)) * stride + left_i;
        @memcpy(destination[offset .. offset + copy_width], source[offset .. offset + copy_width]);
    }
    if (cursor_drawn and cursor_x < right and cursor_x +| cursor_width > x and cursor_y < bottom and cursor_y +| cursor_height > y) {
        cursor_drawn = false;
        presentCursor();
    }
}

/// Update only the small cursor rectangle. Pointer motion no longer redraws or
/// copies the entire desktop frame.
pub fn presentCursor() void {
    const source = s.framebuffer_backbuffer orelse {
        drawMouseCursor();
        return;
    };
    const destination: [*]u32 = @ptrCast(@alignCast(s.fb.address orelse return));
    const stride: usize = @intCast(s.fb.pitch / 4);
    if (cursor_drawn) {
        const left = cursor_x;
        const top = cursor_y;
        var row: u64 = top;
        while (row < @min(top +| cursor_height, s.fb.height)) : (row += 1) {
            var col: u64 = left;
            while (col < @min(left +| cursor_width, s.fb.width)) : (col += 1) {
                const index = @as(usize, @intCast(row)) * stride + @as(usize, @intCast(col));
                destination[index] = source[index];
            }
        }
    }
    const saved_pixels = s.pixels;
    s.pixels = destination;
    drawMouseCursor();
    s.pixels = saved_pixels;
    cursor_x = s.mouse_x;
    cursor_y = s.mouse_y;
    cursor_drawn = true;
}

pub fn component(value: u8, size: u8, shift: u8) u32 {
    if (size == 0) return 0;
    const max_value: u32 = (@as(u32, 1) << @intCast(size)) - 1;
    const scaled = (@as(u32, value) * max_value + 127) / 255;
    return scaled << @intCast(shift);
}

pub fn color(r: u8, g: u8, b: u8) u32 {
    return component(r, s.fb.red_mask_size, s.fb.red_mask_shift) |
        component(g, s.fb.green_mask_size, s.fb.green_mask_shift) |
        component(b, s.fb.blue_mask_size, s.fb.blue_mask_shift);
}

pub fn putPixel(x: u64, y: u64, value: u32) void {
    if (x >= s.fb.width or y >= s.fb.height) return;
    const stride: usize = @intCast(s.fb.pitch / 4);
    s.pixels[@as(usize, @intCast(y)) * stride + @as(usize, @intCast(x))] = value;
}

pub fn fillRect(x: u64, y: u64, w: u64, h: u64, value: u32) void {
    if (x >= s.fb.width or y >= s.fb.height or w == 0 or h == 0) return;
    const clipped_w = @min(w, s.fb.width - x);
    const clipped_h = @min(h, s.fb.height - y);
    const stride: usize = @intCast(s.fb.pitch / 4);
    const start: usize = @as(usize, @intCast(y)) * stride + @as(usize, @intCast(x));
    const row_width: usize = @intCast(clipped_w);
    var row: u64 = 0;
    while (row < clipped_h) : (row += 1) {
        const row_start = start + @as(usize, @intCast(row)) * stride;
        @memset(s.pixels[row_start .. row_start + row_width], value);
    }
}

fn roundedInset(row: u64, radius: u64) u64 {
    if (radius == 0 or row >= radius) return 0;
    const dy = radius - row;
    const square = radius * radius - dy * dy;
    var extent: u64 = 0;
    while ((extent + 1) * (extent + 1) <= square) : (extent += 1) {}
    return radius - extent;
}

/// Fill a rectangle with small, pixel-rounded corners using horizontal spans.
pub fn fillRoundedRect(x: u64, y: u64, w: u64, h: u64, radius: u64, value: u32) void {
    if (w == 0 or h == 0) return;
    const r = @min(radius, @min(w / 2, h / 2));
    var row: u64 = 0;
    while (row < h) : (row += 1) {
        const from_bottom = h - 1 - row;
        const inset = @max(roundedInset(row, r), roundedInset(from_bottom, r));
        if (w > inset * 2) fillRect(x + inset, y + row, w - inset * 2, 1, value);
    }
}

/// Fill a title strip with rounded top corners and square bottom corners.
pub fn fillRoundedTopRect(x: u64, y: u64, w: u64, h: u64, radius: u64, value: u32) void {
    if (w == 0 or h == 0) return;
    const r = @min(radius, @min(w / 2, h));
    var row: u64 = 0;
    while (row < h) : (row += 1) {
        const inset = roundedInset(row, r);
        if (w > inset * 2) fillRect(x + inset, y + row, w - inset * 2, 1, value);
    }
}

pub fn drawMouseCursor() void {
    const fill = color(255, 255, 255);
    for (cursor_shape, 0..) |row, y| {
        for (row, 0..) |pixel, x| {
            if (pixel != '.') putPixel(s.mouse_x +| x, s.mouse_y +| y, fill);
        }
    }
}

const cursor_width: u64 = 19;
const cursor_height: u64 = 20;
const cursor_shape = [_][]const u8{
    ".BB................",
    "BBBB...............",
    "BWWBBB.............",
    "BWWWWBB............",
    "BWWWWWBB...........",
    "BWWWWWWBBB.........",
    "BWWWWWWWWBB........",
    "BWWWWWWWWWBB.......",
    "BWWWWWWWWWWBB......",
    "BWWWWWWWWWWWBBB....",
    "BWWWWWWWWWWWWWBB...",
    "BWWWWWWWWWWWWWWBB..",
    "BWWWWWWWBBBBBBBBB..",
    "BWWWWWBBB..........",
    "BWWWWBB............",
    "BWWWBB.............",
    "BWWWB..............",
    "BBWBB..............",
    ".BBB...............",
    ".BB................",
};
