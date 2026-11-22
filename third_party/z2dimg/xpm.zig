// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! X PixMap: a palette image that is also a C source file.
//!
//! ```c
//! /* XPM */
//! static char * cross[] = {
//! "5 5 2 1",
//! "  c None",
//! ". c black",
//! "..#..",
//! "..#..",
//! "#####",
//! "..#..",
//! "..#.."
//! };
//! ```
//!
//! Like XBM it was written to be compiled into an X client rather than opened,
//! and like XBM everything awkward about it follows from that. Unlike XBM it
//! has colours, transparency, and a header line that says how it is shaped.
//!
//! ## How a pixel is spelled
//!
//! The first string is `width height colours chars-per-pixel`, optionally
//! followed by a hotspot. Then one string per colour, then one per row.
//!
//! Chars-per-pixel is the part with no analogue elsewhere: a pixel is *n*
//! characters, so an image with three hundred colours can still be written as
//! plain text by spending two characters on each pixel. The colour strings
//! begin with exactly that many characters — including spaces, which is why
//! the commonest colour in an image is usually spelled with them and why a
//! parser cannot skip leading whitespace on those lines.
//!
//! ## What a colour string says
//!
//! After the characters come pairs: a key, then a colour. The keys are `c` for
//! colour, `g` for greyscale, `g4` for four-level greyscale, `m` for
//! monochrome and `s` for a symbolic name. A file may give several, so that
//! one image serves a colour screen and a black-and-white one; this takes `c`
//! and falls back through `g`, `g4` and `m`.
//!
//! A colour is `#` and hex — one, two, three or four digits per channel — or
//! `None`, which is transparent, or a name X knows. The names are the reason
//! `xpm/colours.zig` exists: they are most of what real files use, and a
//! decoder without them reads almost nothing.
//!
//! **A colour value may contain spaces.** `c navy blue` is one colour, and the
//! only thing that ends it is another key. So the rest of the line is split
//! into words and a word is a key only if it is exactly one of the five and is
//! followed by something; everything else belongs to the value being built.
//! That is what libXpm does, and there is no better rule available.

const std = @import("std");
const Io = std.Io;
const mem = std.mem;
const math = std.math;
const testing = std.testing;
const Allocator = mem.Allocator;

const z2d = @import("z2d");

const common = @import("common.zig");
const DecodeError = common.DecodeError;
const DecodeOptions = common.DecodeOptions;
const EncodeError = common.EncodeError;
const Info = common.Info;
const Limits = common.Limits;
const pixels = @import("pixels.zig");
const Rgba8 = pixels.Rgba8;

/// The colours X knows by name, which is most of what XPM files use.
pub const colours = @import("xpm/colours.zig");

/// What every XPM begins with, and the only thing about it that is a
/// signature.
pub const signature = "/* XPM */";

/// The most characters a pixel may be spelled with.
///
/// The format sets no limit. Two is almost everything, four covers an image
/// with more colours than there are pixels in any image this library would
/// decode, and a bound is what keeps a header from asking for a lookup table
/// the size of memory.
pub const max_chars_per_pixel = 4;

/// The most colours a palette may have.
///
/// Also not the format's limit but a budget: a table of this many is a few
/// megabytes, and an image needing more has a colour for every pixel.
pub const max_colours = 1 << 20;

/// One entry of the palette: the characters that spell it and what it is.
const Entry = struct {
    /// The characters, left-aligned, `chars_per_pixel` of them.
    key: [max_chars_per_pixel]u8,
    colour: Rgba8,
};

/// Reads the strings a C array is made of, one at a time.
///
/// The file is C source, so the strings are quoted, may be separated by
/// commas and comments, and may run to a closing brace. Nothing here
/// interprets escapes: XPM strings are printable characters chosen to spell
/// pixels, and a backslash in one is far more likely to be a pixel than an
/// escape.
const Reader = struct {
    r: *Io.Reader,
    peeked: ?u8 = null,

    fn next(self: *Reader) DecodeError!?u8 {
        if (self.peeked) |b| {
            self.peeked = null;
            return b;
        }
        return self.r.takeByte() catch |err| switch (err) {
            error.EndOfStream => null,
            error.ReadFailed => |e| return e,
        };
    }

    fn peek(self: *Reader) DecodeError!?u8 {
        if (self.peeked == null) self.peeked = try self.next();
        return self.peeked;
    }

    /// The next quoted string, or null when the array has ended.
    ///
    /// `buf` is the caller's, and a string too long for it is `InvalidData`
    /// rather than a truncation — a row longer than the buffer is a row this
    /// decoder was not going to be able to use.
    fn string(self: *Reader, buf: []u8) DecodeError!?[]const u8 {
        // Find the opening quote, stepping over commas, comments and
        // whitespace on the way.
        while (true) {
            const b = try self.next() orelse return null;
            switch (b) {
                '"' => break,
                '}' => return null,
                '/' => {
                    const second = try self.next() orelse return null;
                    if (second == '*') {
                        var star = false;
                        while (try self.next()) |c| {
                            if (star and c == '/') break;
                            star = c == '*';
                        }
                    } else if (second == '/') {
                        while (try self.next()) |c| {
                            if (c == '\n') break;
                        }
                    }
                },
                else => {},
            }
        }

        var n: usize = 0;
        while (true) {
            const b = try self.next() orelse return error.InvalidData;
            if (b == '"') break;
            if (n == buf.len) return error.InvalidData;
            buf[n] = b;
            n += 1;
        }
        return buf[0..n];
    }
};

/// What the values line said.
pub const Header = struct {
    width: u32,
    height: u32,
    colours: u32,
    chars_per_pixel: u32,
    x_hot: ?u32 = null,
    y_hot: ?u32 = null,
};

/// The next whitespace-separated word of `line`, and what is left after it.
fn word(line: []const u8) struct { []const u8, []const u8 } {
    var at: usize = 0;
    while (at < line.len and isSpace(line[at])) at += 1;
    const start = at;
    while (at < line.len and !isSpace(line[at])) at += 1;
    return .{ line[start..at], line[at..] };
}

fn isSpace(b: u8) bool {
    return b == ' ' or b == '\t';
}

fn parseHeader(line: []const u8) ?Header {
    var rest = line;
    var values: [6]u32 = undefined;
    var n: usize = 0;
    while (n < values.len) {
        const w, const after = word(rest);
        if (w.len == 0) break;
        values[n] = std.fmt.parseInt(u32, w, 10) catch break;
        n += 1;
        rest = after;
    }
    if (n < 4) return null;
    return .{
        .width = values[0],
        .height = values[1],
        .colours = values[2],
        .chars_per_pixel = values[3],
        .x_hot = if (n >= 6) values[4] else null,
        .y_hot = if (n >= 6) values[5] else null,
    };
}

/// The five keys a colour string may use, in the order this decoder would
/// rather have them.
const keys = [_][]const u8{ "c", "g", "g4", "m", "s" };

/// How much this decoder wants a key's value, lower being better. A file that
/// gives several gets the best one it offered.
fn keyRank(k: []const u8) ?u8 {
    if (mem.eql(u8, k, "c")) return 0;
    if (mem.eql(u8, k, "g")) return 1;
    if (mem.eql(u8, k, "g4")) return 2;
    if (mem.eql(u8, k, "m")) return 3;
    // A symbolic name is a name for the colour, not a colour, so it is never
    // what gets used.
    if (mem.eql(u8, k, "s")) return null;
    return null;
}

fn isKey(w: []const u8) bool {
    for (keys) |k| {
        if (mem.eql(u8, w, k)) return true;
    }
    return false;
}

/// One colour, read from the part of a colour string after the characters.
///
/// The awkwardness is that a value may be several words — `navy blue` — and
/// the only thing that ends one is the next key. So words are accumulated
/// until one of them is a key that has something after it.
fn parseColour(spec: []const u8) ?Rgba8 {
    var best: ?Rgba8 = null;
    var best_rank: u8 = 255;

    var rest = spec;
    var current_key: ?[]const u8 = null;
    var value_start: ?usize = null;
    var value_end: usize = 0;

    while (true) {
        const w, const after = word(rest);
        if (w.len == 0) break;
        const at = @intFromPtr(w.ptr) - @intFromPtr(spec.ptr);

        // A word is a key only if it is one of the five *and* something
        // follows it, so that a colour literally named `c` at the end of a
        // line is still a colour.
        const next_word, _ = word(after);
        if (isKey(w) and next_word.len != 0) {
            if (current_key) |k| {
                if (value_start) |s| take(spec[s..value_end], k, &best, &best_rank);
            }
            current_key = w;
            value_start = null;
            rest = after;
            continue;
        }

        if (value_start == null) value_start = at;
        value_end = at + w.len;
        rest = after;
    }
    if (current_key) |k| {
        if (value_start) |s| take(spec[s..value_end], k, &best, &best_rank);
    }
    return best;
}

fn take(value: []const u8, key: []const u8, best: *?Rgba8, best_rank: *u8) void {
    const rank = keyRank(key) orelse return;
    if (rank >= best_rank.*) return;
    const colour = resolve(value) orelse return;
    best.* = colour;
    best_rank.* = rank;
}

/// A colour value: hex, a name X knows, or `None`.
fn resolve(value: []const u8) ?Rgba8 {
    if (value.len == 0) return null;
    if (std.ascii.eqlIgnoreCase(value, "none")) return .{ .r = 0, .g = 0, .b = 0, .a = 0 };
    if (value[0] == '#') return parseHex(value[1..]);
    // `%` introduces HSV, which the specification defines and nothing writes.
    if (value[0] == '%') return null;
    const rgb = colours.find(value) orelse return null;
    return .rgb(rgb[0], rgb[1], rgb[2]);
}

/// `#` followed by one, two, three or four hexadecimal digits per channel.
///
/// The wider forms are scaled down rather than truncated, so that `#ffff` of
/// sixteen-bit red is 255 and not 255 by luck.
fn parseHex(digits: []const u8) ?Rgba8 {
    if (digits.len == 0 or digits.len % 3 != 0) return null;
    const per = digits.len / 3;
    if (per > 4) return null;

    var out: [3]u8 = undefined;
    for (0..3) |i| {
        const part = digits[i * per ..][0..per];
        var v: u32 = 0;
        for (part) |d| {
            const n = std.fmt.charToDigit(d, 16) catch return null;
            v = v * 16 + n;
        }
        const max: u32 = (@as(u32, 1) << @intCast(4 * per)) - 1;
        out[i] = @intCast((v * 255 + max / 2) / max);
    }
    return .rgb(out[0], out[1], out[2]);
}

pub const Decoder = struct {
    header: Header,
    limits: Limits,
    /// Whether any colour in the palette is transparent, which is what decides
    /// the surface type.
    has_alpha: bool = false,

    /// Reads the signature and the values line, and stops before the palette.
    pub fn init(r: *Io.Reader, limits: Limits) DecodeError!Decoder {
        var sig: [signature.len]u8 = undefined;
        r.readSliceAll(&sig) catch |err| switch (err) {
            error.EndOfStream => return error.UnknownFormat,
            error.ReadFailed => |e| return e,
        };
        if (!mem.eql(u8, &sig, signature)) return error.UnknownFormat;

        var reader: Reader = .{ .r = r };
        var buf: [256]u8 = undefined;
        const line = try reader.string(&buf) orelse return error.InvalidData;
        const header = parseHeader(line) orelse return error.InvalidData;

        try limits.check(header.width, header.height);
        if (header.width > math.maxInt(i32) or header.height > math.maxInt(i32)) {
            return error.InvalidData;
        }
        if (header.chars_per_pixel == 0 or header.chars_per_pixel > max_chars_per_pixel) {
            return error.Unsupported;
        }
        if (header.colours > max_colours) return error.ImageTooLarge;

        return .{ .header = header, .limits = limits };
    }

    pub fn info(self: Decoder) Info {
        // Before the palette has been read there is no way to know whether any
        // colour is `None`, so this says the encoding may carry alpha, which
        // is what `Info.has_alpha` means: a property of the format rather than
        // of the pixels.
        return .{
            .format = .xpm,
            .width = self.header.width,
            .height = self.header.height,
            .has_alpha = true,
            .surface_type = pixels.naturalSurfaceType(true),
        };
    }

    /// Reads the palette and the rows, producing the surface.
    pub fn decode(self: *Decoder, gpa: Allocator, r: *Io.Reader, opts: DecodeOptions) DecodeError!z2d.Surface {
        var reader: Reader = .{ .r = r };

        // A colour string is the pixel characters and then the keys and
        // values, and a row is `width * chars_per_pixel` characters. Either
        // may be long, so the buffer is sized for the larger.
        const row_len = @as(u64, self.header.width) * self.header.chars_per_pixel;
        const buf_len = math.cast(usize, @max(row_len, 512)) orelse return error.ImageTooLarge;
        const buf = try gpa.alloc(u8, buf_len + 1);
        defer gpa.free(buf);

        const palette = try gpa.alloc(Entry, self.header.colours);
        defer gpa.free(palette);

        const cpp = self.header.chars_per_pixel;
        var found: usize = 0;
        while (found < self.header.colours) : (found += 1) {
            const line = try reader.string(buf) orelse break;
            if (line.len < cpp) return error.InvalidData;
            var entry: Entry = .{ .key = @splat(0), .colour = .rgb(0, 0, 0) };
            @memcpy(entry.key[0..cpp], line[0..cpp]);
            // A colour the palette gives but this cannot resolve is left
            // black rather than refused: a file naming one colour this does
            // not know is still a picture.
            if (parseColour(line[cpp..])) |c| entry.colour = c;
            palette[found] = entry;
        }

        const surface_type = opts.surface_type orelse self.info().surface_type;
        var sfc: z2d.Surface = z2d.Surface.init(
            surface_type,
            gpa,
            @intCast(self.header.width),
            @intCast(self.header.height),
        ) catch |err| switch (err) {
            error.InvalidWidth, error.InvalidHeight => return error.InvalidData,
            error.OutOfMemory => |e| return e,
        };
        errdefer sfc.deinit(gpa);

        const row = try gpa.alloc(Rgba8, self.header.width);
        defer gpa.free(row);

        // Transparent everywhere first, so that a file which stops early
        // leaves nothing rather than black.
        @memset(row, .{ .r = 0, .g = 0, .b = 0, .a = 0 });
        for (0..self.header.height) |y| pixels.writeRow(&sfc, @intCast(y), row);

        var y: u32 = 0;
        while (y < self.header.height) : (y += 1) {
            const line = try reader.string(buf) orelse break;
            @memset(row, .{ .r = 0, .g = 0, .b = 0, .a = 0 });
            var x: u32 = 0;
            while (x < self.header.width) : (x += 1) {
                const at = @as(usize, x) * cpp;
                if (at + cpp > line.len) break; // the row stopped short
                row[x] = lookup(palette[0..found], line[at..][0..cpp], cpp);
            }
            pixels.writeRow(&sfc, @intCast(y), row);
        }

        return sfc;
    }
};

/// The colour of one pixel's characters.
///
/// Linear, because the palette is small in every file that exists and a hash
/// would cost an allocation to save nothing. A pixel spelled with characters
/// the palette does not have is transparent, which is what libXpm does and is
/// the least surprising of the available wrong answers.
fn lookup(palette: []const Entry, key: []const u8, cpp: u32) Rgba8 {
    for (palette) |entry| {
        if (mem.eql(u8, entry.key[0..cpp], key)) return entry.colour;
    }
    return .{ .r = 0, .g = 0, .b = 0, .a = 0 };
}

/// Reads a whole XPM from `r`, producing a surface the caller owns.
pub fn decode(gpa: Allocator, r: *Io.Reader, opts: DecodeOptions) DecodeError!z2d.Surface {
    if (opts.orientation) |out| out.* = .top_left;
    if (opts.icc) |out| out.clearRetainingCapacity();
    var decoder: Decoder = try .init(r, opts.limits);
    return decoder.decode(gpa, r, opts);
}

/// Reads only the values line, and says what it described.
pub fn probe(r: *Io.Reader, limits: Limits) DecodeError!Info {
    const decoder: Decoder = try .init(r, limits);
    return decoder.info();
}

// -- writing -----------------------------------------------------------------

/// How to write an XPM.
pub const EncodeOptions = struct {
    /// The name of the C array the file declares.
    ///
    /// The file is C source and this becomes an identifier in it, so it has to
    /// be one. Anything else is `error.Unsupported`: a file that does not
    /// compile is not an XPM.
    name: []const u8 = "image",

    /// The most colours to write before giving up.
    ///
    /// XPM has no compression. Every distinct colour costs a line of palette
    /// and every pixel costs `chars_per_pixel` bytes, so a photograph becomes
    /// a file several times the size of the bitmap it came from and a palette
    /// with more entries than anything will read. This encoder does not reduce
    /// colours to fit — see `encode` for why — so an image with more than this
    /// is `error.Unsupported` rather than quietly ruined.
    max_colours: u32 = 4096,

    /// The hotspot to record, for a cursor.
    x_hot: ?u32 = null,
    y_hot: ?u32 = null,
};

/// The characters a pixel may be spelled with, in the order they are used.
///
/// Printable ASCII without the quote, the backslash or the comma: the first
/// two would have to be escaped inside a C string and the third is what
/// separates the strings. A space is fine and is deliberately first, since the
/// commonest colour gets the shortest-looking spelling.
const alphabet = blk: {
    var out: [0x7f - 0x20 - 3]u8 = undefined;
    var n = 0;
    for (0x20..0x7f) |c| {
        if (c == '"' or c == '\\' or c == ',') continue;
        out[n] = @intCast(c);
        n += 1;
    }
    break :blk out;
};

/// Whether `name` can be an identifier in the C file this writes.
pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 200) return false;
    if (name[0] >= '0' and name[0] <= '9') return false;
    for (name) |b| {
        const ok = (b >= 'a' and b <= 'z') or (b >= 'A' and b <= 'Z') or
            (b >= '0' and b <= '9') or b == '_';
        if (!ok) return false;
    }
    return true;
}

/// Writes `sfc` as an XPM.
///
/// **Nothing here reduces colours.** An image with more distinct colours than
/// `opts.max_colours` is refused rather than quantised, because quantising is
/// a whole discipline — a palette chosen badly is worse than no file, and a
/// caller who wants one has opinions about how it should be chosen that this
/// library has no way to ask for. XPM is for icons and line art, where the
/// colours are already few and are exactly the ones the author picked; a
/// photograph should be a PNG.
///
/// Transparency is written as `None`, which is the only kind XPM has: a pixel
/// is either fully transparent or fully opaque. Partial alpha is rounded at
/// half, and the colour of what survives is un-premultiplied back to what it
/// was — a surface holds its colours multiplied by their alpha, so a
/// half-transparent red is stored as a dark red and writing that as the colour
/// would darken every edge in the image.
pub fn encode(
    gpa: Allocator,
    sfc: *const z2d.Surface,
    w: *Io.Writer,
    opts: EncodeOptions,
) EncodeError!void {
    const width = sfc.getWidth();
    const height = sfc.getHeight();
    if (width < 1 or height < 1) return error.Unsupported;
    if (!validName(opts.name)) return error.Unsupported;

    const uw: u32 = @intCast(width);
    const uh: u32 = @intCast(height);

    // Every distinct colour in the image, in the order it is first met, so
    // that the palette of a file written twice is the same both times.
    var palette: std.ArrayList(Rgba8) = .empty;
    defer palette.deinit(gpa);

    const row = try gpa.alloc(Rgba8, uw);
    defer gpa.free(row);

    var y: u32 = 0;
    while (y < uh) : (y += 1) {
        pixels.readRow(row, sfc, @intCast(y));
        for (row) |*px| {
            px.* = flatten(px.*);
            if (indexOf(palette.items, px.*) == null) {
                if (palette.items.len == opts.max_colours) return error.Unsupported;
                try palette.append(gpa, px.*);
            }
        }
    }

    // How many characters a pixel takes: the fewest that can spell the
    // palette.
    var cpp: u32 = 1;
    var capacity: u64 = alphabet.len;
    while (capacity < palette.items.len) {
        cpp += 1;
        if (cpp > max_chars_per_pixel) return error.Unsupported;
        capacity *= alphabet.len;
    }

    try w.print("{s}\n", .{signature});
    try w.print("static char * {s}[] = {{\n", .{opts.name});
    if (opts.x_hot != null and opts.y_hot != null) {
        try w.print("\"{d} {d} {d} {d} {d} {d}\",\n", .{
            uw, uh, palette.items.len, cpp, opts.x_hot.?, opts.y_hot.?,
        });
    } else {
        try w.print("\"{d} {d} {d} {d}\",\n", .{ uw, uh, palette.items.len, cpp });
    }

    var key: [max_chars_per_pixel]u8 = undefined;
    for (palette.items, 0..) |colour, i| {
        spell(i, cpp, &key);
        try w.print("\"{s}\tc ", .{key[0..cpp]});
        if (colour.a == 0) {
            try w.writeAll("None");
        } else {
            try w.print("#{x:0>2}{x:0>2}{x:0>2}", .{ colour.r, colour.g, colour.b });
        }
        try w.writeAll("\",\n");
    }

    y = 0;
    while (y < uh) : (y += 1) {
        pixels.readRow(row, sfc, @intCast(y));
        try w.writeAll("\"");
        for (row) |px| {
            const flat = flatten(px);
            spell(indexOf(palette.items, flat).?, cpp, &key);
            try w.writeAll(key[0..cpp]);
        }
        try w.writeAll("\"");
        if (y + 1 != uh) try w.writeAll(",");
        try w.writeAll("\n");
    }
    try w.writeAll("};\n");
}

/// XPM has no partial transparency: a pixel is `None` or it is a colour. So
/// alpha is rounded, and a colour that survives is un-premultiplied back to
/// what it was.
fn flatten(px: Rgba8) Rgba8 {
    if (px.a < 128) return .{ .r = 0, .g = 0, .b = 0, .a = 0 };
    if (px.a == 255) return .rgb(px.r, px.g, px.b);
    const a: u32 = px.a;
    return .rgb(
        @intCast(@min(255, (@as(u32, px.r) * 255 + a / 2) / a)),
        @intCast(@min(255, (@as(u32, px.g) * 255 + a / 2) / a)),
        @intCast(@min(255, (@as(u32, px.b) * 255 + a / 2) / a)),
    );
}

fn indexOf(palette: []const Rgba8, colour: Rgba8) ?usize {
    for (palette, 0..) |c, i| {
        if (std.meta.eql(c, colour)) return i;
    }
    return null;
}

/// The `cpp` characters that spell palette entry `index`.
fn spell(index: usize, cpp: u32, out: *[max_chars_per_pixel]u8) void {
    var n = index;
    var i: u32 = cpp;
    while (i > 0) {
        i -= 1;
        out[i] = alphabet[n % alphabet.len];
        n /= alphabet.len;
    }
}
