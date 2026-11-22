//! Safe decoder and renderer for uncompressed 24-bit and 32-bit BMP images.
const std = @import("std");
const s = @import("../system/state.zig");
const canvas = @import("canvas.zig");
const vm = @import("../memory/vm.zig");
const fat32 = @import("../fs/storage.zig");

pub const wallpaper = @embedFile("../assets/wallpaper.bmp");
const Image = struct { width: usize, height: usize, top_down: bool, bpp: usize, offset: usize, stride: usize };
var wallpaper_cache: ?[*]u32 = null;
var wallpaper_width: usize = 0;
var wallpaper_height: usize = 0;
var loaded_image: ?[*]u8 = null;
var loaded_image_len: usize = 0;
var loaded_image_pages: usize = 0;
var loaded_name: [64]u8 = @splat(0);
var loaded_name_len: usize = 0;
var fit_cache: ?[*]u32 = null;
var fit_cache_pages: usize = 0;
var fit_cache_width: usize = 0;
var fit_cache_height: usize = 0;
var fit_cache_data: usize = 0;
var fit_cache_len: usize = 0;
var fit_cache_cover = false;

fn u16le(data: []const u8, i: usize) u16 { return @as(u16, data[i]) | (@as(u16, data[i + 1]) << 8); }
fn u32le(data: []const u8, i: usize) u32 {
    return @as(u32, data[i]) | (@as(u32, data[i + 1]) << 8) | (@as(u32, data[i + 2]) << 16) | (@as(u32, data[i + 3]) << 24);
}
fn i32le(data: []const u8, i: usize) i32 { return @bitCast(u32le(data, i)); }

pub fn parse(data: []const u8) ?Image {
    if (data.len < 54 or data[0] != 'B' or data[1] != 'M') return null;
    const offset: usize = u32le(data, 10);
    const dib: usize = u32le(data, 14);
    if (dib < 40 or dib > data.len - 14 or offset < 14 + dib or offset > data.len) return null;
    const width_i = i32le(data, 18);
    const height_i = i32le(data, 22);
    if (width_i <= 0 or height_i == 0 or height_i == std.math.minInt(i32) or u16le(data, 26) != 1 or u32le(data, 30) != 0) return null;
    const bits = u16le(data, 28);
    if (bits != 24 and bits != 32) return null;
    const width: usize = @intCast(width_i);
    const abs_height: usize = @intCast(if (height_i < 0) -height_i else height_i);
    const bytes_per_pixel: usize = bits / 8;
    const row_raw = std.math.mul(usize, width, bytes_per_pixel) catch return null;
    const stride = (std.math.add(usize, row_raw, 3) catch return null) & ~@as(usize, 3);
    const pixel_bytes = std.math.mul(usize, stride, abs_height) catch return null;
    if (pixel_bytes > data.len - offset) return null;
    return .{ .width = width, .height = abs_height, .top_down = height_i < 0, .bpp = bytes_per_pixel, .offset = offset, .stride = stride };
}

pub fn loadFromDisk(name: []const u8, directory: u32) bool {
    if (!s.fs_mounted or name.len == 0 or name.len > 63) return false;
    var entries: [32]fat32.Entry = undefined;
    const entry_count = fat32.listDirectory(directory, &entries);
    var size: usize = 0;
    var found = false;
    for (entries[0..entry_count]) |entry| {
        if (entry.name_len != name.len) continue;
        var equal = true;
        for (name, 0..) |ch, i| {
            const a = if (ch >= 'a' and ch <= 'z') ch - 32 else ch;
            const b0 = entry.name[i];
            const b = if (b0 >= 'a' and b0 <= 'z') b0 - 32 else b0;
            if (a != b) { equal = false; break; }
        }
        if (equal and (entry.attributes & 0x10) == 0) { size = entry.size; found = true; break; }
    }
    if (!found or size < 54 or size > 32 * 1024 * 1024) return false;
    const pages = (size + 4095) / 4096;
    const buffer = vm.allocatePages(pages) orelse return false;
    const bytes_read = fat32.readFileAt(directory, name, buffer[0..size]) orelse {
        for (0..pages) |i| vm.freePage(@intFromPtr(buffer) + @as(u64, @intCast(i)) * 4096);
        return false;
    };
    if (bytes_read != size or parse(buffer[0..size]) == null) {
        for (0..pages) |i| vm.freePage(@intFromPtr(buffer) + @as(u64, @intCast(i)) * 4096);
        return false;
    }
    if (loaded_image) |old| for (0..loaded_image_pages) |i| vm.freePage(@intFromPtr(old) + @as(u64, @intCast(i)) * 4096);
    loaded_image = buffer;
    loaded_image_len = size;
    loaded_image_pages = pages;
    loaded_name = @splat(0);
    loaded_name_len = name.len;
    @memcpy(loaded_name[0..name.len], name);
    return true;
}

pub fn currentImage() []const u8 { return if (loaded_image) |ptr| ptr[0..loaded_image_len] else wallpaper; }
pub fn currentName() []const u8 { return if (loaded_image != null) loaded_name[0..loaded_name_len] else "wallpaper.bmp"; }

fn pixel(data: []const u8, image: Image, x: usize, y: usize) u32 {
    const source_y = if (image.top_down) y else image.height - 1 - y;
    const at = image.offset + source_y * image.stride + x * image.bpp;
    return canvas.color(data[at + 2], data[at + 1], data[at]);
}

/// Draw a centered, aspect-preserving image; `cover` fills the rectangle by cropping.
pub fn drawFit(data: []const u8, x: u64, y: u64, w: u64, h: u64, cover: bool) bool {
    const image = parse(data) orelse return false;
    if (w == 0 or h == 0) return false;
    const width: usize = @intCast(w);
    const height: usize = @intCast(h);
    const pointer = @intFromPtr(data.ptr);
    if (fit_cache == null or fit_cache_width != width or fit_cache_height != height or fit_cache_data != pointer or fit_cache_len != data.len or fit_cache_cover != cover) {
        if (fit_cache) |old| for (0..fit_cache_pages) |i| vm.freePage(@intFromPtr(old) + @as(u64, @intCast(i)) * 4096);
        fit_cache = null;
        fit_cache_pages = 0;
        const count = std.math.mul(usize, width, height) catch return false;
        const bytes = std.math.mul(usize, count, @sizeOf(u32)) catch return false;
        if (bytes > 64 * 1024 * 1024) return false;
        const pages = (bytes + 4095) / 4096;
        const memory = vm.allocatePages(pages) orelse return false;
        const cache: [*]u32 = @ptrCast(@alignCast(memory));
        @memset(cache[0..count], canvas.color(10, 12, 18));
        renderFit(cache, width, height, data, image, cover);
        fit_cache = cache;
        fit_cache_pages = pages;
        fit_cache_width = width;
        fit_cache_height = height;
        fit_cache_data = pointer;
        fit_cache_len = data.len;
        fit_cache_cover = cover;
    }
    const cache = fit_cache orelse return false;
    const stride: usize = @intCast(s.fb.pitch / 4);
    const left: usize = @intCast(x);
    const top: usize = @intCast(y);
    for (0..height) |row| {
        const start = (top + row) * stride + left;
        @memcpy(s.pixels[start .. start + width], cache[row * width .. (row + 1) * width]);
    }
    return true;
}

fn renderFit(cache: [*]u32, width: usize, height: usize, data: []const u8, image: Image, cover: bool) void {
    const sx = @as(f64, @floatFromInt(width)) / @as(f64, @floatFromInt(image.width));
    const sy = @as(f64, @floatFromInt(height)) / @as(f64, @floatFromInt(image.height));
    const scale = if (cover) @max(sx, sy) else @min(sx, sy);
    const dw: u64 = @max(@as(u64, 1), @as(u64, @intFromFloat(@as(f64, @floatFromInt(image.width)) * scale)));
    const dh: u64 = @max(@as(u64, 1), @as(u64, @intFromFloat(@as(f64, @floatFromInt(image.height)) * scale)));
    const dx = (@as(u64, @intCast(width)) -| dw) / 2;
    const dy = (@as(u64, @intCast(height)) -| dh) / 2;
    const left: u64 = if (cover) 0 else dx;
    const top: u64 = if (cover) 0 else dy;
    const right = @min(@as(u64, @intCast(width)), dx + dw);
    const bottom = @min(@as(u64, @intCast(height)), dy + dh);
    var py = top;
    while (py < bottom) : (py += 1) {
        const iy: usize = @intCast(@min(image.height - 1, ((py -| dy) * image.height) / dh));
        var px = left;
        while (px < right) : (px += 1) {
            const ix: usize = @intCast(@min(image.width - 1, ((px -| dx) * image.width) / dw));
            cache[@as(usize, @intCast(py)) * width + @as(usize, @intCast(px))] = pixel(data, image, ix, iy);
        }
    }
}

/// Decode and scale the built-in BMP once; normal desktop frames only copy rows.
pub fn drawWallpaper() void {
    const w: usize = @intCast(s.fb.width);
    const h: usize = @intCast(s.fb.height);
    if (w == 0 or h == 0 or w > 8192 or h > 8192) return;
    if (wallpaper_cache == null or wallpaper_width != w or wallpaper_height != h) {
        const image = parse(wallpaper) orelse return;
        const count = std.math.mul(usize, w, h) catch return;
        const bytes = std.math.mul(usize, count, @sizeOf(u32)) catch return;
        if (bytes > 128 * 1024 * 1024) return;
        const mem = vm.allocatePages((bytes + 4095) / 4096) orelse return;
        const cache: [*]u32 = @ptrCast(@alignCast(mem));
        const scale = @max(@as(f64, @floatFromInt(w)) / @as(f64, @floatFromInt(image.width)), @as(f64, @floatFromInt(h)) / @as(f64, @floatFromInt(image.height)));
        const dw: usize = @intFromFloat(@as(f64, @floatFromInt(image.width)) * scale);
        const dh: usize = @intFromFloat(@as(f64, @floatFromInt(image.height)) * scale);
        const crop_x = (dw -| w) / 2;
        const crop_y = (dh -| h) / 2;
        for (0..h) |py| {
            const iy = @min(image.height - 1, ((py + crop_y) * image.height) / dh);
            for (0..w) |px| {
                const ix = @min(image.width - 1, ((px + crop_x) * image.width) / dw);
                cache[py * w + px] = pixel(wallpaper, image, ix, iy);
            }
        }
        wallpaper_cache = cache;
        wallpaper_width = w;
        wallpaper_height = h;
    }
    const cache = wallpaper_cache orelse return;
    const stride: usize = @intCast(s.fb.pitch / 4);
    for (0..h) |row| @memcpy(s.pixels[row * stride .. row * stride + w], cache[row * w .. row * w + w]);
}
