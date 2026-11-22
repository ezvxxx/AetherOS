const std = @import("std");
const Metrics = @import("../Metrics.zig");
const ShapedText = @import("../ShapedText.zig");
const matching = @import("../matching.zig");
const aether_font = @import("aether_font");

/// AetherOS freestanding Inter-backed font adapter.
pub const Font = struct {
    size: f64,
    pub const Descriptor = struct { pub fn deinit(_: Descriptor) void {} };
    pub fn initWithName(_: []const u8, size: f64) !Font { return .{ .size = size }; }
    pub fn initWithDescriptor(_: Descriptor, size: f64) !Font { return .{ .size = size }; }
    pub fn deinit(_: Font) void {}
    pub fn retain(self: Font) Font { return self; }
    pub fn familyName(_: Font, allocator: std.mem.Allocator) ![]u8 { return allocator.dupe(u8, "Inter"); }
    pub fn postScriptName(_: Font, allocator: std.mem.Allocator) ![]u8 { return allocator.dupe(u8, "Inter-Regular"); }
    pub fn metrics(self: Font) Metrics {
        return .{ .ascent = self.size * 0.8, .descent = self.size * 0.2, .leading = self.size * 0.1, .x_height = self.size * 0.5, .cap_height = self.size * 0.7 };
    }
};

pub const Family = struct {
    pub fn init(_: []const u8) !?Family { return .{}; }
    pub fn deinit(_: Family) void {}
    pub fn match(_: Family, _: std.mem.Allocator, _: matching.Attributes) !?Font.Descriptor { return .{}; }
};

fn decode(bytes: []const u8, offset: usize) struct { cp: u21, len: usize } {
    const first = bytes[offset];
    if (first < 0x80) return .{ .cp = first, .len = 1 };
    const len: usize = if (first & 0xe0 == 0xc0) 2 else if (first & 0xf0 == 0xe0) 3 else if (first & 0xf8 == 0xf0) 4 else 1;
    if (len == 1 or offset + len > bytes.len) return .{ .cp = 0xfffd, .len = 1 };
    return .{ .cp = std.unicode.utf8Decode(bytes[offset .. offset + len]) catch return .{ .cp = 0xfffd, .len = 1 }, .len = len };
}

pub fn shape(allocator: std.mem.Allocator, text: []const u8, font: Font, direction: ShapedText.Direction) !ShapedText {
    var glyphs = try allocator.alloc(ShapedText.Glyph, text.len);
    var count: usize = 0;
    var width: f64 = 0;
    var offset: usize = 0;
    const pixel_size: u8 = @intFromFloat(@max(1, @min(48, @round(font.size))));
    var mask: [48 * 48]u8 = undefined;
    while (offset < text.len) {
        const decoded = decode(text, offset);
        const measured = aether_font.rasterGlyph(allocator, decoded.cp, pixel_size, &mask);
        const advance: f64 = if (measured) |m| @floatFromInt(m.advance) else font.size * 0.55;
        glyphs[count] = .{ .id = @intCast(@min(decoded.cp, std.math.maxInt(u16))), .cluster = offset, .position = .{ width, 0 }, .advance = .{ advance, 0 } };
        count += 1;
        width += advance;
        offset += decoded.len;
    }
    const run_glyphs = try allocator.realloc(glyphs, count);
    const runs = try allocator.alloc(ShapedText.Run, 1);
    runs[0] = .{ .font = font.retain(), .direction = direction, .glyphs = run_glyphs, .text_range = .{ .start = 0, .end = text.len }, .text_matrix = .{ .{ 1, 0 }, .{ 0, 1 }, .{ 0, 0 } } };
    const m = font.metrics();
    return .{ .runs = runs, .width = width, .ascent = m.ascent, .descent = m.descent, .leading = m.leading };
}

pub fn lineBreaks(allocator: std.mem.Allocator, text: []const u8) ![]usize {
    var breaks: std.ArrayList(usize) = .empty;
    var offset: usize = 0;
    while (offset < text.len) {
        const decoded = decode(text, offset);
        offset += decoded.len;
        if (decoded.cp == ' ' or decoded.cp == '\t' or decoded.cp == '\n' or decoded.cp == '-' or decoded.cp == '/') try breaks.append(allocator, offset);
    }
    return breaks.toOwnedSlice(allocator);
}
