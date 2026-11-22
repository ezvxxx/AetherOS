// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! X BitMap: a one-bit image that is also a C source file.
//!
//! ```c
//! #define cursor_width 8
//! #define cursor_height 8
//! static unsigned char cursor_bits[] = {
//!    0x3c, 0x42, 0xa5, 0x81, 0xa5, 0x99, 0x42, 0x3c };
//! ```
//!
//! That is the whole format. It was meant to be `#include`d into an X client
//! and compiled, which is why it has no header, no signature and no magic
//! number — it is not a container at all, and everything below follows from
//! that.
//!
//! ## What a bit means
//!
//! One bit a pixel, and the *least* significant bit of each byte is the
//! leftmost pixel, which is the opposite of the order a reader expects and the
//! single most common mistake made with this format. Each row starts on a
//! fresh byte, so a nine-pixel row takes two bytes and seven bits are wasted.
//!
//! A set bit is the foreground. X itself attaches no colours to a bitmap —
//! the client chooses them when it draws — so a decoder has to pick, and the
//! conventional rendering is black on white: a set bit is where the ink is.
//!
//! **Not everything agrees.** ImageMagick reads a set bit as black, which is
//! what this does and what the X semantics imply, since a 1 selects the
//! foreground and the foreground of a monochrome image is its ink. Pillow
//! reads the same byte as *white*. They were checked against each other on a
//! file with a single set bit and they genuinely disagree, so anyone comparing
//! this library against Pillow will find every XBM inverted and should not
//! conclude from that that either is broken.
//!
//! ## The X10 form
//!
//! The original format declared `static short` and packed two rows' worth of
//! padding into sixteen bits rather than eight. Files like it still exist, so
//! the declaration is read rather than assumed: a `short` there means the
//! values are sixteen bits wide and rows pad to sixteen.
//!
//! ## Why it is not detected by content
//!
//! `detect` can return `.xbm`, but only because it looks for a `#define` whose
//! name ends in `_width` within the first `format.min_buffer_len` bytes. There
//! is nothing else to look for: an XBM and any other C header begin with the
//! same eight characters, and claiming every `#include` file in a source tree
//! is an image would be worse than not claiming any of them.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const mem = std.mem;
const math = std.math;
const testing = std.testing;

const z2d = @import("z2d");

const common = @import("common.zig");
const DecodeError = common.DecodeError;
const DecodeOptions = common.DecodeOptions;
const EncodeError = common.EncodeError;
const Info = common.Info;
const Limits = common.Limits;
const pixels = @import("pixels.zig");
const Rgba8 = pixels.Rgba8;

/// The colours a bit stands for.
///
/// Set is the foreground, and the foreground is black: that is what every
/// general-purpose decoder produces from an XBM and what somebody opening one
/// expects to see.
const foreground: Rgba8 = .rgb(0, 0, 0);
const background: Rgba8 = .rgb(255, 255, 255);

/// A character-level reader over what is, after all, a C source file.
///
/// Everything here is one forward pass with a single byte of lookahead, which
/// is all the grammar needs: the file is a sequence of `#define` lines and
/// then a braced list of integers, and nothing in it has to be reconsidered
/// once it has been read.
const Scanner = struct {
    r: *Io.Reader,
    /// The byte read ahead of the cursor, if one has been.
    peeked: ?u8 = null,

    fn next(self: *Scanner) DecodeError!?u8 {
        if (self.peeked) |b| {
            self.peeked = null;
            return b;
        }
        return self.r.takeByte() catch |err| switch (err) {
            error.EndOfStream => null,
            error.ReadFailed => |e| return e,
        };
    }

    fn peek(self: *Scanner) DecodeError!?u8 {
        if (self.peeked == null) self.peeked = try self.next();
        return self.peeked;
    }

    fn back(self: *Scanner, b: u8) void {
        std.debug.assert(self.peeked == null);
        self.peeked = b;
    }

    /// Whitespace and C comments, of both kinds.
    ///
    /// Comments are skipped rather than refused because real files carry them:
    /// a generated XBM often has the tool's name in one above the defines.
    fn skipBlanks(self: *Scanner) DecodeError!void {
        while (try self.peek()) |b| {
            if (b == ' ' or b == '\t' or b == '\r' or b == '\n') {
                _ = try self.next();
                continue;
            }
            if (b != '/') return;
            _ = try self.next();
            const second = try self.peek() orelse return;
            if (second == '*') {
                _ = try self.next();
                var star = false;
                while (try self.next()) |c| {
                    if (star and c == '/') break;
                    star = c == '*';
                }
                continue;
            }
            if (second == '/') {
                while (try self.next()) |c| {
                    if (c == '\n') break;
                }
                continue;
            }
            // A stray slash, which is not this grammar's.
            return error.InvalidData;
        }
    }

    /// The next word: a run of identifier characters, or a run of digits and
    /// the letters a hexadecimal constant is made of.
    ///
    /// Returns what would not fit as `error.InvalidData` rather than
    /// truncating, since a name longer than this is not one an XBM has.
    fn word(self: *Scanner, buf: []u8) DecodeError![]const u8 {
        try self.skipBlanks();
        var n: usize = 0;
        while (try self.peek()) |b| {
            if (!isWordByte(b)) break;
            if (n == buf.len) return error.InvalidData;
            buf[n] = b;
            n += 1;
            _ = try self.next();
        }
        return buf[0..n];
    }
};

fn isWordByte(b: u8) bool {
    return (b >= 'a' and b <= 'z') or (b >= 'A' and b <= 'Z') or
        (b >= '0' and b <= '9') or b == '_';
}

/// One integer of the array, in whichever base it was written.
///
/// `signed char` was the declaration for years, so values above 127 appear as
/// negative numbers in plenty of files and a leading minus is part of the
/// grammar rather than a malformation.
fn parseInt(word_bytes: []const u8, negative: bool) ?u32 {
    if (word_bytes.len == 0) return null;
    const value: u32 = blk: {
        if (word_bytes.len > 2 and word_bytes[0] == '0' and
            (word_bytes[1] == 'x' or word_bytes[1] == 'X'))
        {
            break :blk std.fmt.parseInt(u32, word_bytes[2..], 16) catch return null;
        }
        break :blk std.fmt.parseInt(u32, word_bytes, 10) catch return null;
    };
    if (!negative) return value;
    // Two's complement, at whatever width holds it.
    if (value > 0x8000) return null;
    return (~value +% 1) & 0xffff;
}

/// What the `#define` lines said.
pub const Header = struct {
    width: u32,
    height: u32,
    /// The hotspot, for the files that are cursors. Read and reported, and
    /// nothing here does anything with it.
    x_hot: ?u32 = null,
    y_hot: ?u32 = null,
};

pub const Decoder = struct {
    header: Header,
    limits: Limits,

    /// Reads the `#define` lines, and stops at the array declaration.
    pub fn init(r: *Io.Reader, limits: Limits) DecodeError!Decoder {
        var scanner: Scanner = .{ .r = r };
        var width: ?u32 = null;
        var height: ?u32 = null;
        var x_hot: ?u32 = null;
        var y_hot: ?u32 = null;

        var name_buf: [256]u8 = undefined;
        var value_buf: [32]u8 = undefined;

        while (true) {
            try scanner.skipBlanks();
            const b = try scanner.peek() orelse return error.UnknownFormat;
            if (b != '#') break; // the defines are over

            _ = try scanner.next();
            const directive = try scanner.word(&name_buf);
            if (!mem.eql(u8, directive, "define")) return error.InvalidData;

            var name_storage: [256]u8 = undefined;
            const name = try scanner.word(&name_storage);
            if (name.len == 0) return error.InvalidData;

            const digits = try scanner.word(&value_buf);
            const value = parseInt(digits, false) orelse return error.InvalidData;

            // The name is `<whatever>_width`, and what comes before it is the
            // image's name, which nothing here needs.
            if (mem.endsWith(u8, name, "_width")) {
                width = value;
            } else if (mem.endsWith(u8, name, "_height")) {
                height = value;
            } else if (mem.endsWith(u8, name, "_x_hot")) {
                x_hot = value;
            } else if (mem.endsWith(u8, name, "_y_hot")) {
                y_hot = value;
            }
            // Anything else defined here is not this format's business.
        }

        const w = width orelse return error.UnknownFormat;
        const h = height orelse return error.UnknownFormat;
        try limits.check(w, h);
        if (w > math.maxInt(i32) or h > math.maxInt(i32)) return error.InvalidData;

        return .{
            .header = .{ .width = w, .height = h, .x_hot = x_hot, .y_hot = y_hot },
            .limits = limits,
        };
    }

    pub fn info(self: Decoder) Info {
        return .{
            .format = .xbm,
            .width = self.header.width,
            .height = self.header.height,
            .has_alpha = false,
            .surface_type = pixels.naturalSurfaceType(false),
        };
    }

    /// Reads the array, producing the surface.
    pub fn decode(self: *Decoder, gpa: Allocator, r: *Io.Reader, opts: DecodeOptions) DecodeError!z2d.Surface {
        var scanner: Scanner = .{ .r = r };

        // The declaration, up to the brace. The only thing in it that matters
        // is whether it says `short`, which is the X10 form and means the
        // values are sixteen bits wide.
        var wide = false;
        var word_buf: [256]u8 = undefined;
        while (true) {
            try scanner.skipBlanks();
            const b = try scanner.next() orelse return error.InvalidData;
            if (b == '{') break;
            if (isWordByte(b)) {
                scanner.back(b);
                const w = try scanner.word(&word_buf);
                if (mem.eql(u8, w, "short")) wide = true;
                continue;
            }
            // Brackets, equals signs, asterisks and the like, which carry no
            // information this needs.
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

        // Background everywhere first. A clear bit is white, so the rows an
        // array too short never reaches are white as well --- which is what
        // the format means by no data, and more use to a caller than the
        // surface's own transparent black.
        @memset(row, background);
        for (0..self.header.height) |y| pixels.writeRow(&sfc, @intCast(y), row);

        const bits_per_value: u32 = if (wide) 16 else 8;
        // Each row starts on a fresh value, which is where the padding goes.
        const values_per_row = (self.header.width + bits_per_value - 1) / bits_per_value;

        var y: u32 = 0;
        rows: while (y < self.header.height) : (y += 1) {
            @memset(row, background);
            var v: u32 = 0;
            while (v < values_per_row) : (v += 1) {
                const value = (try nextValue(&scanner, &word_buf)) orelse {
                    // The array ended early. What was read is kept, as for
                    // every other truncated image here.
                    pixels.writeRow(&sfc, @intCast(y), row);
                    break :rows;
                };
                var bit: u32 = 0;
                while (bit < bits_per_value) : (bit += 1) {
                    const x = v * bits_per_value + bit;
                    if (x >= self.header.width) break;
                    // The least significant bit is the leftmost pixel.
                    if ((value >> @intCast(bit)) & 1 != 0) row[x] = foreground;
                }
            }
            pixels.writeRow(&sfc, @intCast(y), row);
        }

        return sfc;
    }
};

/// The next integer in the array, or null when the array has ended.
fn nextValue(scanner: *Scanner, buf: []u8) DecodeError!?u32 {
    while (true) {
        try scanner.skipBlanks();
        const b = try scanner.peek() orelse return null;
        switch (b) {
            ',' => {
                _ = try scanner.next();
                continue;
            },
            '}' => return null,
            '-' => {
                _ = try scanner.next();
                const digits = try scanner.word(buf);
                return parseInt(digits, true) orelse error.InvalidData;
            },
            else => {
                if (!isWordByte(b)) return error.InvalidData;
                const digits = try scanner.word(buf);
                return parseInt(digits, false) orelse error.InvalidData;
            },
        }
    }
}

/// Reads a whole XBM from `r`, producing a surface the caller owns.
pub fn decode(gpa: Allocator, r: *Io.Reader, opts: DecodeOptions) DecodeError!z2d.Surface {
    if (opts.orientation) |out| out.* = .top_left;
    if (opts.icc) |out| out.clearRetainingCapacity();
    var decoder: Decoder = try .init(r, opts.limits);
    return decoder.decode(gpa, r, opts);
}

/// Reads only the `#define` lines, and says what they described.
pub fn probe(r: *Io.Reader, limits: Limits) DecodeError!Info {
    const decoder: Decoder = try .init(r, limits);
    return decoder.info();
}

// -- writing -----------------------------------------------------------------

/// How to write an XBM.
pub const EncodeOptions = struct {
    /// The name the `#define`s and the array are prefixed with.
    ///
    /// The file is C source and this becomes an identifier in it, so it has to
    /// be one: letters, digits and underscores, not starting with a digit.
    /// Anything else is `error.Unsupported` rather than quietly corrected,
    /// because a file that does not compile is not an XBM.
    name: []const u8 = "image",

    /// A pixel darker than this becomes a set bit.
    ///
    /// The image has to become one bit a pixel somehow, and there is no right
    /// answer — this is the middle of the range, which is the answer that
    /// needs no explaining. Coverage is measured as luminance by the same
    /// coefficients the JPEG encoder uses for `Y`.
    threshold: u8 = 128,

    /// The hotspot to record, for a cursor.
    x_hot: ?u32 = null,
    y_hot: ?u32 = null,
};

/// Whether `name` can be an identifier in the C file this writes.
pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 200) return false;
    if (name[0] >= '0' and name[0] <= '9') return false;
    for (name) |b| {
        if (!isWordByte(b)) return false;
    }
    return true;
}

/// Writes `sfc` as an XBM.
///
/// One bit a pixel, so everything but coverage is lost: the image is reduced
/// to light and dark about `opts.threshold`. That is what the format is, and a
/// caller who did not mean it should be writing a PNG.
///
/// Transparency counts as light. A transparent pixel has no colour to be dark,
/// and treating it as set would put a solid block where a caller expected
/// nothing.
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

    try w.print("#define {s}_width {d}\n", .{ opts.name, uw });
    try w.print("#define {s}_height {d}\n", .{ opts.name, uh });
    if (opts.x_hot) |x| try w.print("#define {s}_x_hot {d}\n", .{ opts.name, x });
    if (opts.y_hot) |y| try w.print("#define {s}_y_hot {d}\n", .{ opts.name, y });
    try w.print("static unsigned char {s}_bits[] = {{\n", .{opts.name});

    const row = try gpa.alloc(Rgba8, uw);
    defer gpa.free(row);

    const bytes_per_row = (uw + 7) / 8;
    var written: u64 = 0;
    const total = @as(u64, bytes_per_row) * uh;

    var y: u32 = 0;
    while (y < uh) : (y += 1) {
        pixels.readRow(row, sfc, @intCast(y));
        var b: u32 = 0;
        while (b < bytes_per_row) : (b += 1) {
            var value: u8 = 0;
            var bit: u3 = 0;
            while (true) : (bit += 1) {
                const x = b * 8 + bit;
                if (x < uw and isSet(row[x], opts.threshold)) {
                    value |= @as(u8, 1) << bit;
                }
                if (bit == 7) break;
            }

            // Twelve to a line, which is what every tool that writes these
            // does and what keeps the file inside eighty columns.
            if (written % 12 == 0) try w.writeAll("  ") else try w.writeAll(" ");
            try w.print("0x{x:0>2}", .{value});
            written += 1;
            if (written != total) try w.writeAll(",");
            if (written % 12 == 0 or written == total) try w.writeAll("\n");
        }
    }
    try w.writeAll("};\n");
}

/// Whether a pixel is dark enough to be a set bit.
fn isSet(px: Rgba8, threshold: u8) bool {
    // Transparency is light: there is no colour behind it to be dark.
    if (px.a == 0) return false;
    const luma = (19595 * @as(u32, px.r) + 38470 * @as(u32, px.g) + 7471 * @as(u32, px.b)) >> 16;
    return luma < threshold;
}
