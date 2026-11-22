const std = @import("std");
const s = @import("../system/state.zig");
const canvas = @import("../graphics/canvas.zig");
const heap = @import("../memory/heap.zig");
const fat32 = @import("../fs/storage.zig");
const z2d = @import("z2d");

const inter_regular = @embedFile("../assets/fonts/Inter-Regular.ttf");
const max_glyph_size = 48;
const glyph_cache_capacity = 512;

const CachedGlyph = struct {
    valid: bool = false,
    codepoint: u21 = 0,
    size: u8 = 0,
    advance: u8 = 0,
    rounded_advance: u8 = 0,
    width: u8 = 0,
    height: u8 = 0,
    alpha: [max_glyph_size * max_glyph_size]u8 = @splat(0),
};

/// Raster metrics and alpha-mask access used by the freestanding browser
/// renderer. `out` must have room for `max_glyph_size * max_glyph_size` bytes.
pub const RasterGlyph = struct { width: u8, height: u8, advance: u8 };

pub fn rasterGlyph(codepoint: u21, size: u8, out: []u8) ?RasterGlyph {
    if (out.len < max_glyph_size * max_glyph_size or size == 0 or size > max_glyph_size) return null;
    const active_face = if (face) |*value| value else return null;
    const cached = getGlyph(active_face, codepoint, size) orelse return null;
    @memcpy(out[0 .. max_glyph_size * max_glyph_size], &cached.alpha);
    return .{ .width = cached.width, .height = cached.height, .advance = cached.advance };
}

var face: ?z2d.font.Font = null;
var glyph_cache: [glyph_cache_capacity]CachedGlyph = @splat(.{});
var glyph_cache_cursor: usize = 0;
var installed_font_buffer: [4 * 1024 * 1024]u8 = undefined;

/// Initializes the system font from the original Inter TrueType file.
/// The TTF is embedded as a font file; glyphs are rasterized from its outlines
/// at runtime, never stored as pre-generated bitmap assets.
pub fn init() bool {
    return loadFontData(inter_regular);
}

/// Installs a single-face TTF/OTF buffer as the active system font.
/// The caller must keep `bytes` alive for as long as this face is selected.
pub fn loadFontData(bytes: []const u8) bool {
    const file = z2d.font.File.loadBuffer(bytes) catch return false;
    const loaded = file.loadFontIndex(0) catch return false;
    face = loaded;
    glyph_cache = @splat(.{});
    glyph_cache_cursor = 0;
    return true;
}

/// Loads the first root-directory .ttf or .otf file that the TrueType/OpenType
/// outline renderer accepts. Its file bytes remain resident for the font life.
pub fn loadFirstInstalled(entries: []const fat32.Entry) bool {
    for (entries) |entry| {
        const name = entry.name[0..entry.name_len];
        if (entry.attributes & 0x10 != 0 or !(std.ascii.endsWithIgnoreCase(name, ".ttf") or std.ascii.endsWithIgnoreCase(name, ".otf"))) continue;
        const length = fat32.readFile(name, &installed_font_buffer) orelse continue;
        if (loadFontData(installed_font_buffer[0..length])) return true;
    }
    return false;
}

pub fn glyph(ch: u8) [7]u8 {
    return switch (ch) {
        'A' => .{ 14, 17, 17, 31, 17, 17, 17 }, 'B' => .{ 30, 17, 17, 30, 17, 17, 30 },
        'C' => .{ 14, 17, 16, 16, 16, 17, 14 }, 'D' => .{ 30, 17, 17, 17, 17, 17, 30 },
        'E' => .{ 31, 16, 16, 30, 16, 16, 31 }, 'F' => .{ 31, 16, 16, 30, 16, 16, 16 },
        'G' => .{ 14, 17, 16, 23, 17, 17, 15 }, 'H' => .{ 17, 17, 17, 31, 17, 17, 17 },
        'I' => .{ 14, 4, 4, 4, 4, 4, 14 }, 'J' => .{ 7, 2, 2, 2, 18, 18, 12 },
        'K' => .{ 17, 18, 20, 24, 20, 18, 17 },
        'L' => .{ 16, 16, 16, 16, 16, 16, 31 }, 'M' => .{ 17, 27, 21, 21, 17, 17, 17 },
        'N' => .{ 17, 25, 25, 21, 19, 19, 17 }, 'O' => .{ 14, 17, 17, 17, 17, 17, 14 },
        'P' => .{ 30, 17, 17, 30, 16, 16, 16 }, 'Q' => .{ 14, 17, 17, 17, 21, 18, 13 },
        'R' => .{ 30, 17, 17, 30, 20, 18, 17 },
        'S' => .{ 15, 16, 16, 14, 1, 1, 30 }, 'T' => .{ 31, 4, 4, 4, 4, 4, 4 },
        'U' => .{ 17, 17, 17, 17, 17, 17, 14 }, 'V' => .{ 17, 17, 17, 17, 17, 10, 4 },
        'W' => .{ 17, 17, 17, 21, 21, 21, 10 }, 'X' => .{ 17, 17, 10, 4, 10, 17, 17 },
        'Y' => .{ 17, 17, 10, 4, 4, 4, 4 }, 'Z' => .{ 31, 1, 2, 4, 8, 16, 31 },
        'a' => .{ 0, 0, 14, 1, 15, 17, 15 }, 'b' => .{ 16, 16, 22, 25, 17, 17, 30 },
        'c' => .{ 0, 0, 14, 17, 16, 17, 14 }, 'd' => .{ 1, 1, 13, 19, 17, 17, 15 },
        'e' => .{ 0, 0, 14, 17, 31, 16, 14 }, 'f' => .{ 6, 9, 8, 28, 8, 8, 8 },
        'g' => .{ 0, 15, 17, 17, 15, 1, 14 }, 'h' => .{ 16, 16, 22, 25, 17, 17, 17 },
        'i' => .{ 4, 0, 12, 4, 4, 4, 14 }, 'j' => .{ 2, 0, 6, 2, 2, 18, 12 },
        'k' => .{ 16, 16, 18, 20, 24, 20, 18 }, 'l' => .{ 12, 4, 4, 4, 4, 4, 14 },
        'm' => .{ 0, 0, 26, 21, 21, 21, 21 }, 'n' => .{ 0, 0, 22, 25, 17, 17, 17 },
        'o' => .{ 0, 0, 14, 17, 17, 17, 14 }, 'p' => .{ 0, 30, 17, 17, 30, 16, 16 },
        'q' => .{ 0, 15, 17, 17, 15, 1, 1 }, 'r' => .{ 0, 0, 22, 25, 16, 16, 16 },
        's' => .{ 0, 0, 15, 16, 14, 1, 30 }, 't' => .{ 8, 8, 28, 8, 8, 9, 6 },
        'u' => .{ 0, 0, 17, 17, 17, 19, 13 }, 'v' => .{ 0, 0, 17, 17, 17, 10, 4 },
        'w' => .{ 0, 0, 17, 17, 21, 21, 10 }, 'x' => .{ 0, 0, 17, 10, 4, 10, 17 },
        'y' => .{ 0, 17, 17, 17, 15, 1, 14 }, 'z' => .{ 0, 0, 31, 2, 4, 8, 31 },
        '0' => .{ 14, 17, 19, 21, 25, 17, 14 }, '1' => .{ 4, 12, 4, 4, 4, 4, 14 },
        '2' => .{ 14, 17, 1, 2, 4, 8, 31 }, '3' => .{ 30, 1, 1, 14, 1, 1, 30 },
        '4' => .{ 2, 6, 10, 18, 31, 2, 2 }, '5' => .{ 31, 16, 16, 30, 1, 1, 30 },
        '6' => .{ 14, 16, 16, 30, 17, 17, 14 }, '7' => .{ 31, 1, 2, 4, 8, 8, 8 },
        '8' => .{ 14, 17, 17, 14, 17, 17, 14 }, '9' => .{ 14, 17, 17, 15, 1, 1, 14 },
        '!' => .{ 4, 4, 4, 4, 4, 0, 4 }, '"' => .{ 10, 10, 10, 0, 0, 0, 0 },
        '#' => .{ 10, 10, 31, 10, 31, 10, 10 }, '$' => .{ 4, 15, 20, 14, 5, 30, 4 },
        '%' => .{ 24, 25, 2, 4, 8, 19, 3 }, '&' => .{ 12, 18, 20, 8, 21, 18, 13 },
        '\'' => .{ 4, 4, 8, 0, 0, 0, 0 }, '(' => .{ 2, 4, 8, 8, 8, 4, 2 },
        ')' => .{ 8, 4, 2, 2, 2, 4, 8 }, '*' => .{ 0, 4, 21, 14, 21, 4, 0 },
        '+' => .{ 0, 4, 4, 31, 4, 4, 0 }, ',' => .{ 0, 0, 0, 0, 4, 4, 8 },
        '-' => .{ 0, 0, 0, 31, 0, 0, 0 }, '.' => .{ 0, 0, 0, 0, 0, 12, 12 },
        '/' => .{ 1, 2, 2, 4, 8, 8, 16 }, ':' => .{ 0, 4, 4, 0, 4, 4, 0 },
        ';' => .{ 0, 4, 4, 0, 4, 4, 8 }, '<' => .{ 2, 4, 8, 16, 8, 4, 2 },
        '=' => .{ 0, 0, 31, 0, 31, 0, 0 }, '>' => .{ 8, 4, 2, 1, 2, 4, 8 },
        '?' => .{ 14, 17, 1, 2, 4, 0, 4 }, '@' => .{ 14, 17, 23, 21, 23, 16, 14 },
        '[' => .{ 14, 8, 8, 8, 8, 8, 14 }, '\\' => .{ 16, 8, 8, 4, 2, 2, 1 },
        ']' => .{ 14, 2, 2, 2, 2, 2, 14 }, '^' => .{ 4, 10, 17, 0, 0, 0, 0 },
        '_' => .{ 0, 0, 0, 0, 0, 0, 31 }, '`' => .{ 8, 4, 2, 0, 0, 0, 0 },
        '{' => .{ 2, 4, 4, 8, 4, 4, 2 }, '|' => .{ 4, 4, 4, 4, 4, 4, 4 },
        '}' => .{ 8, 4, 4, 2, 4, 4, 8 }, '~' => .{ 0, 0, 9, 22, 0, 0, 0 },
        ' ' => .{ 0, 0, 0, 0, 0, 0, 0 }, else => .{ 0, 0, 0, 0, 0, 0, 0 },
    };
}

pub fn drawText(x: u64, y: u64, text: []const u8, scale: u64, ink: u32) void {
    drawTextSized(x, y, text, scale, @as(u8, @intCast(@min(scale, 4))) * 10, ink);
}

pub fn drawTextSized(x: u64, y: u64, text: []const u8, scale: u64, pixel_size: u8, ink: u32) void {
    if (text.len == 0 or scale == 0) return;
    if (face) |*active_face| {
        var cursor = x;
        var offset: usize = 0;
        while (offset < text.len and cursor < s.fb.width) {
            const decoded = decodeUtf8(text[offset..]);
            const cached = getGlyph(active_face, decoded.codepoint, pixel_size) orelse {
                drawBitmapText(cursor, y, text[offset .. offset + decoded.length], scale, ink);
                cursor += 6 * scale;
                offset += decoded.length;
                continue;
            };
            drawCachedGlyph(cursor, y, cached, ink);
            // Text size already includes scale, so use the font's measured
            // advance directly instead of applying scale a second time.
            cursor +|= cached.advance;
            offset += decoded.length;
        }
        return;
    }
    drawBitmapText(x, y, text, scale, ink);
}

/// Draws text with a small rightward shear, used for CSS italic/oblique text.
pub fn drawTextItalicSized(x: u64, y: u64, text: []const u8, scale: u64, pixel_size: u8, ink: u32) void {
    if (text.len == 0 or scale == 0) return;
    if (face) |*active_face| {
        var cursor = x;
        var offset: usize = 0;
        const bounded_scale: u64 = @min(scale, 4);
        while (offset < text.len and cursor < s.fb.width) {
            const decoded = decodeUtf8(text[offset..]);
            const cached = getGlyph(active_face, decoded.codepoint, pixel_size) orelse {
                drawText(cursor, y, text[offset .. offset + decoded.length], scale, ink);
                cursor += 6 * scale;
                offset += decoded.length;
                continue;
            };
            for (0..cached.height) |row| {
                const shear = (@as(u64, cached.height - 1 - @as(u8, @intCast(row))) * bounded_scale) / 5;
                for (0..cached.width) |column| blend(cursor +| shear +| column, y +| row, ink, cached.alpha[row * max_glyph_size + column]);
            }
            cursor +|= cached.advance + bounded_scale;
            offset += decoded.length;
        }
    } else drawText(x, y, text, scale, ink);
}

pub fn glyphAdvanceSized(codepoint: u21, pixel_size: u8, scale: u8) u16 {
    if (face) |*active_face| {
        if (getGlyph(active_face, codepoint, pixel_size)) |cached| return cached.rounded_advance;
    }
    return 6 * @as(u16, scale);
}

pub fn textWidth(text: []const u8, scale: u64) u64 {
    return textWidthSized(text, scale, @as(u8, @intCast(@min(scale, 4))) * 10);
}

pub fn textWidthSized(text: []const u8, scale: u64, pixel_size: u8) u64 {
    if (text.len == 0 or scale == 0) return 0;
    if (face) |*active_face| {
        var width: u64 = 0;
        var offset: usize = 0;
        while (offset < text.len) {
            const decoded = decodeUtf8(text[offset..]);
            if (getGlyph(active_face, decoded.codepoint, pixel_size)) |cached| {
                width +|= cached.advance;
            } else {
                width +|= 6 * scale;
            }
            offset += decoded.length;
        }
        return width;
    }
    return @as(u64, @intCast(text.len)) * 6 * scale;
}

pub fn drawTextCentered(x: u64, y: u64, width: u64, height: u64, text: []const u8, scale: u64, ink: u32) void {
    const bounded_scale: u64 = @min(scale, 4);
    const text_width = textWidth(text, bounded_scale);
    const em_height = bounded_scale * 10;
    const draw_x = x + (width -| text_width) / 2;
    const draw_y = y + (height -| em_height) / 2;
    drawText(draw_x, draw_y, text, bounded_scale, ink);
}

const Decoded = struct { codepoint: u21, length: usize };

fn isContinuation(byte: u8) bool {
    return (byte & 0xc0) == 0x80;
}

pub fn decodeUtf8(input: []const u8) Decoded {
    const first = input[0];
    if (first < 0x80) return .{ .codepoint = first, .length = 1 };
    if (first >= 0xc2 and first <= 0xdf and input.len >= 2 and isContinuation(input[1])) {
        return .{ .codepoint = (@as(u21, first & 0x1f) << 6) | (input[1] & 0x3f), .length = 2 };
    }
    if (first >= 0xe0 and first <= 0xef and input.len >= 3 and isContinuation(input[1]) and isContinuation(input[2])) {
        const value = (@as(u21, first & 0x0f) << 12) | (@as(u21, input[1] & 0x3f) << 6) | (input[2] & 0x3f);
        if (value >= 0x800 and !(value >= 0xd800 and value <= 0xdfff)) return .{ .codepoint = value, .length = 3 };
    }
    if (first >= 0xf0 and first <= 0xf4 and input.len >= 4 and isContinuation(input[1]) and isContinuation(input[2]) and isContinuation(input[3])) {
        const value = (@as(u21, first & 0x07) << 18) | (@as(u21, input[1] & 0x3f) << 12) | (@as(u21, input[2] & 0x3f) << 6) | (input[3] & 0x3f);
        if (value >= 0x10000 and value <= 0x10ffff) return .{ .codepoint = value, .length = 4 };
    }
    return .{ .codepoint = 0xfffd, .length = 1 };
}

fn getGlyph(active_face: *z2d.font.Font, codepoint: u21, size: u8) ?*const CachedGlyph {
    for (&glyph_cache) |*cached| {
        if (cached.valid and cached.codepoint == codepoint and cached.size == size) return cached;
    }

    const slot = &glyph_cache[glyph_cache_cursor];
    glyph_cache_cursor = (glyph_cache_cursor + 1) % glyph_cache.len;
    slot.* = .{ .valid = true, .codepoint = codepoint, .size = size };

    const saved_mark = heap.mark();
    const allocator = heap.allocator();
    var surface = z2d.surface.Surface.init(.image_surface_alpha8, allocator, max_glyph_size, max_glyph_size) catch {
        heap.rewind(saved_mark);
        slot.valid = false;
        return null;
    };
    defer {
        surface.deinit(allocator);
        heap.rewind(saved_mark);
    }

    const pixel = z2d.Pixel{ .alpha8 = .{ .a = 255 } };
    const pattern = z2d.Pattern{ .opaque_pattern = .{ .pixel = pixel } };
    const encoded = encodeUtf8(codepoint);
    const font_size: f64 = @floatFromInt(size);
    const options: z2d.text.ShowTextOptions = .{ .size = font_size };
    const glyph_bytes = encoded.bytes[0..encoded.length];
    const advance = z2d.text.measure(allocator, active_face, glyph_bytes, options) catch return null;
    z2d.text.show(allocator, &surface, &pattern, active_face, glyph_bytes, 2, 0, options) catch return null;
    slot.rounded_advance = @intFromFloat(@max(1, @min(max_glyph_size - 1, @round(advance))));
    slot.advance = @intCast(@max(1, @min(max_glyph_size - 1, @as(usize, @intFromFloat(@ceil(advance))))));
    for (surface.image_surface_alpha8.buf, 0..) |alpha, index| {
        slot.alpha[index] = alpha.a;
        if (alpha.a != 0) {
            const row = index / max_glyph_size;
            const column = index % max_glyph_size;
            slot.width = @max(slot.width, @as(u8, @intCast(column + 1)));
            slot.height = @max(slot.height, @as(u8, @intCast(row + 1)));
        }
    }
    return slot;
}

const Encoded = struct { bytes: [4]u8, length: usize };

pub fn encodeUtf8(codepoint: u21) Encoded {
    var result = Encoded{ .bytes = @splat(0), .length = 0 };
    if (codepoint < 0x80) {
        result.bytes[0] = @intCast(codepoint);
        result.length = 1;
    } else if (codepoint < 0x800) {
        result.bytes[0] = @intCast(0xc0 | (codepoint >> 6));
        result.bytes[1] = @intCast(0x80 | (codepoint & 0x3f));
        result.length = 2;
    } else if (codepoint < 0x10000) {
        result.bytes[0] = @intCast(0xe0 | (codepoint >> 12));
        result.bytes[1] = @intCast(0x80 | ((codepoint >> 6) & 0x3f));
        result.bytes[2] = @intCast(0x80 | (codepoint & 0x3f));
        result.length = 3;
    } else {
        result.bytes[0] = @intCast(0xf0 | (codepoint >> 18));
        result.bytes[1] = @intCast(0x80 | ((codepoint >> 12) & 0x3f));
        result.bytes[2] = @intCast(0x80 | ((codepoint >> 6) & 0x3f));
        result.bytes[3] = @intCast(0x80 | (codepoint & 0x3f));
        result.length = 4;
    }
    return result;
}

fn channel(value: u32, size: u8, shift: u8) u8 {
    if (size == 0) return 0;
    const max_value = (@as(u32, 1) << @intCast(size)) - 1;
    return @intCast((((value >> @intCast(shift)) & max_value) * 255 + max_value / 2) / max_value);
}

fn blend(x: u64, y: u64, ink: u32, alpha: u8) void {
    if (alpha == 0 or x >= s.fb.width or y >= s.fb.height) return;
    if (alpha == 255) {
        canvas.putPixel(x, y, ink);
        return;
    }
    const stride: usize = @intCast(s.fb.pitch / 4);
    const index = @as(usize, @intCast(y)) * stride + @as(usize, @intCast(x));
    const background = s.pixels[index];
    const a: u32 = alpha;
    const inverse = 255 - a;
    const red = (@as(u32, channel(ink, s.fb.red_mask_size, s.fb.red_mask_shift)) * a + @as(u32, channel(background, s.fb.red_mask_size, s.fb.red_mask_shift)) * inverse + 127) / 255;
    const green = (@as(u32, channel(ink, s.fb.green_mask_size, s.fb.green_mask_shift)) * a + @as(u32, channel(background, s.fb.green_mask_size, s.fb.green_mask_shift)) * inverse + 127) / 255;
    const blue = (@as(u32, channel(ink, s.fb.blue_mask_size, s.fb.blue_mask_shift)) * a + @as(u32, channel(background, s.fb.blue_mask_size, s.fb.blue_mask_shift)) * inverse + 127) / 255;
    canvas.putPixel(x, y, canvas.color(@intCast(red), @intCast(green), @intCast(blue)));
}

fn drawCachedGlyph(x: u64, y: u64, cached: *const CachedGlyph, ink: u32) void {
    for (0..cached.height) |row| {
        const py = y +| row;
        if (py >= s.fb.height) break;
        for (0..cached.width) |column| {
            const px = x +| column;
            if (px >= s.fb.width) break;
            blend(px, py, ink, cached.alpha[row * max_glyph_size + column]);
        }
    }
}

fn drawBitmapText(x: u64, y: u64, text: []const u8, scale: u64, ink: u32) void {
    var cursor = x;
    for (text) |ch| {
        const rows = glyph(ch);
        for (rows, 0..) |bits, row| {
            var col: u8 = 0;
            while (col < 5) : (col += 1) {
                if ((bits & (@as(u8, 1) << @intCast(4 - col))) != 0)
                    canvas.fillRect(cursor + @as(u64, col) * scale, y + row * scale, scale, scale, ink);
            }
        }
        cursor += 6 * scale;
        if (cursor >= s.fb.width) return;
    }
}

pub fn drawTextNumber(x: u64, y: u64, first: u64, separator: []const u8, second: u64, ink: u32) void {
    var buffer: [48]u8 = undefined;
    var digits: [20]u8 = undefined;
    var digit_count: usize = 0;
    var value = first;
    while (true) {
        digits[digit_count] = '0' + @as(u8, @intCast(value % 10));
        digit_count += 1;
        value /= 10;
        if (value == 0) break;
    }
    var length: usize = 0;
    while (digit_count > 0) {
        digit_count -= 1;
        buffer[length] = digits[digit_count];
        length += 1;
    }
    @memcpy(buffer[length..][0..separator.len], separator);
    length += separator.len;
    value = second;
    digit_count = 0;
    while (true) {
        digits[digit_count] = '0' + @as(u8, @intCast(value % 10));
        digit_count += 1;
        value /= 10;
        if (value == 0) break;
    }
    while (digit_count > 0) {
        digit_count -= 1;
        buffer[length] = digits[digit_count];
        length += 1;
    }
    drawText(x, y, buffer[0..length], 1, ink);
}

pub fn drawNumber(x: u64, y: u64, value: u64, ink: u32) void {
    var digits: [20]u8 = undefined;
    var count: usize = 0;
    var remaining = value;
    while (true) {
        digits[count] = '0' + @as(u8, @intCast(remaining % 10));
        count += 1;
        remaining /= 10;
        if (remaining == 0) break;
    }
    var text: [20]u8 = undefined;
    for (0..count) |i| text[i] = digits[count - i - 1];
    drawText(x, y, text[0..count], 1, ink);
}

pub fn drawIPv4(x: u64, y: u64, address: [4]u8, ink: u32) void {
    var text: [15]u8 = undefined;
    var length: usize = 0;
    for (address, 0..) |octet, index| {
        var digits: [3]u8 = undefined;
        var count: usize = 0;
        var value: u16 = octet;
        while (true) {
            digits[count] = '0' + @as(u8, @intCast(value % 10));
            count += 1;
            value /= 10;
            if (value == 0) break;
        }
        while (count > 0) {
            count -= 1;
            text[length] = digits[count];
            length += 1;
        }
        if (index != address.len - 1) {
            text[length] = '.';
            length += 1;
        }
    }
    drawText(x, y, text[0..length], 1, ink);
}

