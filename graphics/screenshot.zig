//! Captures the current framebuffer as a 24-bit BMP on the FAT32 root volume.
const std = @import("std");
const s = @import("../system/state.zig");
const fat32 = @import("../fs/storage.zig");
const vm = @import("../memory/vm.zig");

fn put16(data: []u8, offset: usize, value: u16) void {
    data[offset] = @truncate(value);
    data[offset + 1] = @truncate(value >> 8);
}

fn put32(data: []u8, offset: usize, value: u32) void {
    data[offset] = @truncate(value);
    data[offset + 1] = @truncate(value >> 8);
    data[offset + 2] = @truncate(value >> 16);
    data[offset + 3] = @truncate(value >> 24);
}

fn channel(pixel: u32, size: u8, shift: u8) u8 {
    if (size == 0 or size > 8) return 0;
    const max_value = (@as(u32, 1) << @intCast(size)) - 1;
    const value = (pixel >> @intCast(shift)) & max_value;
    return @intCast((value * 255 + max_value / 2) / max_value);
}

fn nameExists(entries: []const fat32.Entry, name: []const u8) bool {
    for (entries) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.name[0..entry.name_len], name)) return true;
    }
    return false;
}

/// Save a screenshot as the first free SCREENnn.BMP in the root directory.
/// On success, `saved_name` receives its 12-character FAT filename.
pub fn save(saved_name: *[12]u8) bool {
    if (!fat32.isMounted() or s.fb.bpp != 32 or s.fb.width == 0 or s.fb.height == 0) return false;
    if (s.fb.width > std.math.maxInt(i32) or s.fb.height > std.math.maxInt(i32)) return false;

    const width: usize = @intCast(s.fb.width);
    const height: usize = @intCast(s.fb.height);
    const row_bytes = std.math.mul(usize, width, 3) catch return false;
    const row_stride = (std.math.add(usize, row_bytes, 3) catch return false) & ~@as(usize, 3);
    const image_size = std.math.mul(usize, row_stride, height) catch return false;
    const file_size = std.math.add(usize, 54, image_size) catch return false;
    if (file_size > std.math.maxInt(u32) or s.fb.pitch < s.fb.width * 4) return false;

    var entries: [128]fat32.Entry = undefined;
    const entry_count = fat32.listRoot(&entries);
    var filename: [12]u8 = undefined;
    var found_name = false;
    var number: u8 = 1;
    while (number <= 99) : (number += 1) {
        const formatted = std.fmt.bufPrint(&filename, "SCREEN{d:0>2}.BMP", .{number}) catch return false;
        if (!nameExists(entries[0..entry_count], formatted)) {
            found_name = true;
            break;
        }
    }
    if (!found_name) return false;

    const pages = (file_size + 4095) / 4096;
    const allocation = vm.allocatePages(pages) orelse return false;
    defer for (0..pages) |i| vm.freePage(@intFromPtr(allocation) + @as(u64, @intCast(i)) * 4096);
    const data = allocation[0..file_size];
    @memset(data, 0);

    data[0] = 'B';
    data[1] = 'M';
    put32(data, 2, @intCast(file_size));
    put32(data, 10, 54);
    put32(data, 14, 40);
    put32(data, 18, @intCast(width));
    put32(data, 22, @intCast(height));
    put16(data, 26, 1);
    put16(data, 28, 24);
    put32(data, 34, @intCast(image_size));
    put32(data, 38, 2835);
    put32(data, 42, 2835);

    const source_stride: usize = @intCast(s.fb.pitch / 4);
    for (0..height) |row| {
        const source_row = height - 1 - row;
        const output_row = 54 + row * row_stride;
        for (0..width) |column| {
            const pixel = s.pixels[source_row * source_stride + column];
            const at = output_row + column * 3;
            data[at] = channel(pixel, s.fb.blue_mask_size, s.fb.blue_mask_shift);
            data[at + 1] = channel(pixel, s.fb.green_mask_size, s.fb.green_mask_shift);
            data[at + 2] = channel(pixel, s.fb.red_mask_size, s.fb.red_mask_shift);
        }
    }

    if (!fat32.writeFileAt(fat32.rootCluster(), &filename, data)) return false;
    @memcpy(saved_name, &filename);
    return true;
}
