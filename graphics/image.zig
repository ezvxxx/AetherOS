//! Bounded BMP/PNG/JPEG/WebP decoding and framebuffer composition.
const std = @import("std");
const s = @import("../system/state.zig");
const vm = @import("../memory/vm.zig");
const heap = @import("../memory/heap.zig");
const fat32 = @import("../fs/storage.zig");
const media = @import("media.zig");
const codecs = @import("z2dimg");

pub const max_file_bytes = 16 * 1024 * 1024;
pub const max_pixels: u64 = 4 * 1024 * 1024;

pub const Decoded = media.Picture;

fn freePages(pointer: [*]u8, pages: usize) void {
    for (0..pages) |i| vm.freePage(@intFromPtr(pointer) + @as(u64, @intCast(i)) * 4096);
}

pub fn decode(data: []const u8) ?Decoded {
    if (data.len < 8 or data.len > max_file_bytes) return null;
    const mark_value = heap.mark();
    defer heap.rewind(mark_value);
    const allocator = heap.allocator();
    var reader = std.Io.Reader.fixed(data);
    var surface = codecs.decode(allocator, &reader, .{
        .surface_type = .image_surface_rgba,
        .limits = .{ .max_width = 8192, .max_height = 8192, .max_pixels = max_pixels, .max_input_bytes = max_file_bytes },
    }) catch return null;
    defer surface.deinit(allocator);
    if (surface != .image_surface_rgba) return null;
    const width: usize = @intCast(surface.image_surface_rgba.width);
    const height: usize = @intCast(surface.image_surface_rgba.height);
    if (width == 0 or height == 0 or width > 8192 or height > 8192) return null;
    const count = std.math.mul(usize, width, height) catch return null;
    if (count > max_pixels) return null;
    const decoded = media.allocate(width, height) orelse return null;
    for (surface.image_surface_rgba.buf, 0..) |premultiplied, i| {
        const straight = premultiplied.demultiply();
        decoded.pixels[i] = (@as(u32, straight.r) << 24) | (@as(u32, straight.g) << 16) | (@as(u32, straight.b) << 8) | straight.a;
    }
    return decoded;
}

pub fn supportsName(name: []const u8) bool {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return false;
    const ext = name[dot..];
    return std.ascii.eqlIgnoreCase(ext, ".bmp") or std.ascii.eqlIgnoreCase(ext, ".png") or
        std.ascii.eqlIgnoreCase(ext, ".jpg") or std.ascii.eqlIgnoreCase(ext, ".jpeg") or
        std.ascii.eqlIgnoreCase(ext, ".webp") or std.ascii.eqlIgnoreCase(ext, ".svg");
}

pub fn loadFromDisk(name: []const u8, directory: u32) bool {
    if (!s.fs_mounted or name.len == 0 or name.len > 63 or !supportsName(name)) return false;
    var entries: [32]fat32.Entry = undefined;
    const count = fat32.listDirectory(directory, &entries);
    var file_size: usize = 0;
    var found = false;
    for (entries[0..count]) |entry| {
        if (entry.name_len != name.len) continue;
        var equal = true;
        for (name, 0..) |ch, i| {
            if (std.ascii.toUpper(ch) != std.ascii.toUpper(entry.name[i])) {
                equal = false;
                break;
            }
        }
        if (equal and (entry.attributes & 0x10) == 0) {
            file_size = entry.size;
            found = true;
            break;
        }
    }
    if (!found or file_size < 8 or file_size > max_file_bytes) return false;
    const input_pages = (file_size + 4095) / 4096;
    const input = vm.allocatePages(input_pages) orelse return false;
    defer freePages(input, input_pages);
    const read = fat32.readFileAt(directory, name, input[0..file_size]) orelse return false;
    if (read != file_size) return false;
    const decoded = decode(input[0..file_size]) orelse return false;
    media.setSelected(decoded, name);
    return true;
}
