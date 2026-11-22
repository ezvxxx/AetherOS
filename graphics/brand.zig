//! AetherOS identity marks used by the boot splash and desktop dock.
const image = @import("image.zig");
const media = @import("media.zig");
const canvas = @import("canvas.zig");
const s = @import("../system/state.zig");

const logo_bytes = @embedFile("../assets/aetheros-logo.png");
var logo: ?media.Picture = null;
var spinner_ticks: u8 = 0;
var spinner_frame: usize = 0;

const spinner_points = [_][2]i8{
    .{ 0, -18 }, .{ 9, -16 }, .{ 16, -9 }, .{ 18, 0 },
    .{ 16, 9 }, .{ 9, 16 }, .{ 0, 18 }, .{ -9, 16 },
    .{ -16, 9 }, .{ -18, 0 }, .{ -16, -9 }, .{ -9, -16 },
};
const spinner_shades = [_]u8{ 255, 245, 225, 195, 160, 125, 95, 70, 52, 42, 38, 38 };

pub fn init() void {
    if (logo == null) logo = image.decode(logo_bytes);
}

fn unpack(pixel: u32, size: u8, shift: u8) u8 {
    if (size == 0) return 0;
    const max_value: u32 = (@as(u32, 1) << @intCast(size)) - 1;
    return @intCast((((pixel >> @intCast(shift)) & max_value) * 255 + max_value / 2) / max_value);
}

fn over(source: u8, destination: u8, alpha: u8) u8 {
    const a: u32 = alpha;
    return @intCast((@as(u32, source) * a + @as(u32, destination) * (255 - a) + 127) / 255);
}

/// Draw the logo with colors chosen for the requested background theme.
fn drawLogoForTheme(x: u64, y: u64, size: u64, dark_background: bool) void {
    const picture = logo orelse return;
    if (size == 0 or picture.width == 0 or picture.height == 0) return;
    const width = @min(size, s.fb.width -| x);
    const height = @min(size, s.fb.height -| y);
    if (width == 0 or height == 0) return;
    const source_size: usize = @intCast(size);
    const stride: usize = @intCast(s.fb.pitch / 4);
    for (0..height) |dy| {
        const sy = @min(picture.height - 1, @as(usize, @intCast(dy)) * picture.height / source_size);
        for (0..width) |dx| {
            const sx = @min(picture.width - 1, @as(usize, @intCast(dx)) * picture.width / source_size);
            const source = picture.pixels[sy * picture.width + sx];
            const alpha: u8 = @truncate(source);
            if (alpha == 0) continue;
            const is_mark = (source >> 24) < 80;
            const red: u8 = if (is_mark) (if (dark_background) 229 else 48) else (if (dark_background) 155 else 130);
            const green: u8 = if (is_mark) (if (dark_background) 236 else 60) else (if (dark_background) 180 else 156);
            const blue: u8 = if (is_mark) (if (dark_background) 238 else 66) else (if (dark_background) 190 else 166);
            const index = (@as(usize, @intCast(y + dy)) * stride) + @as(usize, @intCast(x + dx));
            const destination = s.pixels[index];
            s.pixels[index] = canvas.color(
                over(red, unpack(destination, s.fb.red_mask_size, s.fb.red_mask_shift), alpha),
                over(green, unpack(destination, s.fb.green_mask_size, s.fb.green_mask_shift), alpha),
                over(blue, unpack(destination, s.fb.blue_mask_size, s.fb.blue_mask_shift), alpha),
            );
        }
    }
}

pub fn drawLogo(x: u64, y: u64, size: u64) void {
    drawLogoForTheme(x, y, size, s.dark_theme);
}

fn drawSpinnerToBackbuffer(center_x: u64, center_y: u64, phase: usize) void {
    for (spinner_points, 0..) |point, i| {
        const px = @as(i64, @intCast(center_x)) + @as(i64, @intCast(point[0]));
        const py = @as(i64, @intCast(center_y)) + @as(i64, @intCast(point[1]));
        if (px < 0 or py < 0) continue;
        const x: u64 = @intCast(px);
        const y: u64 = @intCast(py);
        const shade = spinner_shades[(i + spinner_points.len - phase % spinner_points.len) % spinner_points.len];
        const dot = canvas.color(shade, shade, shade);
        canvas.fillRoundedRect(x -| 2, y -| 2, 5, 5, 2, dot);
    }
}

pub fn drawBootSplash() void {
    const background = canvas.color(16, 24, 32);
    canvas.fillRect(0, 0, s.fb.width, s.fb.height, background);
    const logo_size = @min(@as(u64, 160), @min(s.fb.width, s.fb.height) / 3);
    const center_x = s.fb.width / 2;
    const center_y = s.fb.height / 2;
    drawLogoForTheme(center_x -| logo_size / 2, center_y -| 126, logo_size, true);
    drawSpinnerToBackbuffer(center_x, center_y +| 82, spinner_frame);
    canvas.presentFrame();
}

/// The timer draws directly to the firmware framebuffer while boot is in
/// progress, so the logo remains animated even while synchronous drivers start.
pub fn timerTick() void {
    if (!s.boot_splash_visible) return;
    spinner_ticks +%= 1;
    if (spinner_ticks < 8) return;
    spinner_ticks = 0;
    spinner_frame = (spinner_frame + 1) % spinner_points.len;
    drawHardwareSpinner(spinner_frame);
}

fn drawHardwareSpinner(phase: usize) void {
    const raw = s.fb.address orelse return;
    const pixels: [*]volatile u32 = @ptrCast(@alignCast(raw));
    const stride: usize = @intCast(s.fb.pitch / 4);
    const center_x = s.fb.width / 2;
    const center_y = s.fb.height / 2 +| 82;
    const background = canvas.color(16, 24, 32);
    var row = center_y -| 25;
    while (row < @min(center_y +| 26, s.fb.height)) : (row += 1) {
        var column = center_x -| 25;
        while (column < @min(center_x +| 26, s.fb.width)) : (column += 1) {
            pixels[@as(usize, @intCast(row)) * stride + @as(usize, @intCast(column))] = background;
        }
    }
    for (spinner_points, 0..) |point, i| {
        const px = @as(i64, @intCast(center_x)) + @as(i64, @intCast(point[0]));
        const py = @as(i64, @intCast(center_y)) + @as(i64, @intCast(point[1]));
        if (px < 2 or py < 2) continue;
        const x: u64 = @intCast(px);
        const y: u64 = @intCast(py);
        const shade = spinner_shades[(i + spinner_points.len - phase % spinner_points.len) % spinner_points.len];
        const dot = canvas.color(shade, shade, shade);
        var dy: u64 = 0;
        while (dy < 5 and y -| 2 + dy < s.fb.height) : (dy += 1) {
            var dx: u64 = 0;
            while (dx < 5 and x -| 2 + dx < s.fb.width) : (dx += 1) {
                pixels[@as(usize, @intCast(y -| 2 + dy)) * stride + @as(usize, @intCast(x -| 2 + dx))] = dot;
            }
        }
    }
}

pub fn finishBootSplash() void {
    s.boot_splash_visible = false;
}
