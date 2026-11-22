//! Fallback masks for common Simplified Chinese and Arabic web text.
const std = @import("std");
const canvas = @import("canvas.zig");
const atlas = @embedFile("../assets/fonts/AetherWebFallback.bin");
const width = 24;
const height = 20;
const record_size = 3 + width * height / 8;

pub fn find(codepoint: u21) ?[]const u8 {
    var low: usize = 0;
    var high: usize = atlas.len / record_size;
    while (low < high) {
        const middle = low + (high - low) / 2;
        const entry = atlas[middle * record_size ..][0..record_size];
        const code = std.mem.readInt(u16, entry[0..2], .little);
        if (code == codepoint) return entry;
        if (code < codepoint) low = middle + 1 else high = middle;
    }
    return null;
}

pub fn advance(entry: []const u8, pixels: u8) u16 {
    return @max(1, (@as(u16, entry[2]) * pixels + 8) / 16);
}

pub fn draw(entry: []const u8, x: u64, y: u64, pixels: u8, ink: u32) void {
    const w = (width * @as(u64, pixels) + 15) / 16;
    const h = (height * @as(u64, pixels) + 15) / 16;
    for (0..h) |out_y| {
        const row = out_y * 16 / pixels;
        for (0..w) |out_x| {
            const col = out_x * 16 / pixels;
            const byte = entry[3 + row * (width / 8) + col / 8];
            if (byte & (@as(u8, 0x80) >> @as(u3, @intCast(col % 8))) != 0) {
                canvas.putPixel(x + out_x, y + out_y, ink);
            }
        }
    }
}
