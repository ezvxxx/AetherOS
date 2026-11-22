const std = @import("std");
const image = @import("image.zig");
const svg = @import("svg.zig");
const media = @import("media.zig");

pub fn supportsName(name: []const u8) bool {
    return image.supportsName(name);
}

pub fn loadFromDisk(name: []const u8, directory: u32) bool {
    if (!supportsName(name)) return false;
    media.clearSelected();
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return false;
    if (std.ascii.eqlIgnoreCase(name[dot..], ".svg")) return svg.loadFromDisk(name, directory);
    return image.loadFromDisk(name, directory);
}
