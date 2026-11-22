// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Netpbm: the smallest image formats that are still formats.
//!
//! Seven magic numbers, four names, one family:
//!
//! | magic | name | samples a pixel | bytes |
//! | --- | --- | --- | --- |
//! | `P1` | PBM | one bit | decimal digits |
//! | `P2` | PGM | one | decimal digits |
//! | `P3` | PPM | three | decimal digits |
//! | `P4` | PBM | one bit | packed, eight to a byte |
//! | `P5` | PGM | one | raw |
//! | `P6` | PPM | three | raw |
//! | `P7` | PAM | one to four | raw |
//!
//! A header of whitespace-separated numbers, then the samples. `#` begins a
//! comment that runs to the end of the line, and a comment may appear anywhere
//! in the header — between the width and the height, if a writer felt like it
//! — which is why the header here is read a token at a time rather than a line
//! at a time.
//!
//! PAM is the later, tidier one: a header of `KEY value` lines ended by
//! `ENDHDR`, with `DEPTH` saying how many samples a pixel has and `TUPLTYPE`
//! naming what they mean. It is the only one of the four that can carry an
//! alpha channel, and the only one this library writes when asked for alpha.
//!
//! ## In PBM, one is black
//!
//! In PBM, and only in PBM, **a set bit is black**. Every other format in this
//! family counts up from black, so a PGM sample of zero is black and `maxval`
//! is white — and then PBM, the same family and the same header, inverts. Even
//! PAM inverts back: a `TUPLTYPE BLACKANDWHITE` image with `MAXVAL 1` reads
//! zero as black like everything else, so the same two colours are written two
//! opposite ways depending on which member of the family is carrying them.
//!
//! It is the trap XBM sets as well, and both are here for the same reason: the
//! bit means *ink*, not brightness. It is this far up the file because it is
//! the one thing here a decoder can get exactly backwards while agreeing with
//! itself perfectly, which is not something a round trip will ever tell you —
//! so `tests/netpbm.zig` asserts it against files netpbm's own tools wrote.
//!
//! The other half of that confusion is bit order. A packed PBM row puts the
//! **most** significant bit of the first byte at the left of the image; XBM
//! puts the least significant one there. The two formats are one bit a pixel,
//! packed eight to a byte, MSB-first and LSB-first respectively, and nothing
//! in either file says which.
//!
//! ## Sixteen-bit samples
//!
//! A `maxval` above 255 means two bytes a sample, big-endian. A z2d surface
//! holds eight bits a channel, so those are scaled down — scaled rather than
//! shifted, so that `maxval` itself comes out 255 exactly instead of 254.
//!
//! ## No alpha, and what happens to it
//!
//! PBM, PGM and PPM have no alpha channel. A surface with one is flattened
//! onto white on the way out, since something has to be behind a transparent
//! pixel and white is what a page is. PAM keeps the channel instead.

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
const format = @import("format.zig");
const pixels = @import("pixels.zig");
const Rgba8 = pixels.Rgba8;

/// Which of the seven a file is.
pub const Kind = enum {
    bitmap_plain,
    grey_plain,
    colour_plain,
    bitmap_raw,
    grey_raw,
    colour_raw,
    arbitrary,

    /// The kind named by the byte after the `P`, or null if that byte names
    /// none of them.
    pub fn fromMagic(digit: u8) ?Kind {
        return switch (digit) {
            '1' => .bitmap_plain,
            '2' => .grey_plain,
            '3' => .colour_plain,
            '4' => .bitmap_raw,
            '5' => .grey_raw,
            '6' => .colour_raw,
            '7' => .arbitrary,
            else => null,
        };
    }

    /// Whether the samples are written as decimal numbers rather than bytes.
    pub fn isPlain(self: Kind) bool {
        return switch (self) {
            .bitmap_plain, .grey_plain, .colour_plain => true,
            else => false,
        };
    }

    /// Whether the samples are single bits, with the inverted sense described
    /// at the top of this file.
    pub fn isBitmap(self: Kind) bool {
        return self == .bitmap_plain or self == .bitmap_raw;
    }

    /// Which `Format` a file of this kind is. Four kinds map onto two formats
    /// each, because the plain and raw members of a pair are the same format
    /// written two ways and share an extension and a media type.
    pub fn asFormat(self: Kind) format.Format {
        return switch (self) {
            .bitmap_plain, .bitmap_raw => .pbm,
            .grey_plain, .grey_raw => .pgm,
            .colour_plain, .colour_raw => .ppm,
            .arbitrary => .pam,
        };
    }
};

/// What the header said.
pub const Header = struct {
    kind: Kind,
    width: u32,
    height: u32,
    /// The largest value a sample may hold. A bitmap has no `maxval` field and
    /// is recorded as one, since its samples are bits.
    max_value: u16,
    /// Samples a pixel: 1 grey, 2 grey and alpha, 3 colour, 4 colour and
    /// alpha. Only PAM has the middle two.
    depth: u8,

    pub fn hasAlpha(self: Header) bool {
        return self.depth == 2 or self.depth == 4;
    }
};

/// Reads the header a token at a time, which is what lets a comment sit
/// anywhere in it.
const Scanner = struct {
    r: *Io.Reader,

    fn byte(self: *Scanner) DecodeError!?u8 {
        return self.r.takeByte() catch |err| switch (err) {
            error.EndOfStream => null,
            error.ReadFailed => |e| return e,
        };
    }

    /// The next run of non-whitespace, with comments skipped. An empty result
    /// means the stream ended.
    ///
    /// Exactly one whitespace byte is consumed after a token, which is what
    /// the raw formats require: the sample data begins immediately after the
    /// single character that ends the header.
    fn token(self: *Scanner, buf: []u8) DecodeError![]const u8 {
        var n: usize = 0;
        var in_comment = false;
        while (try self.byte()) |b| {
            if (in_comment) {
                if (b == '\n') in_comment = false;
                continue;
            }
            if (b == '#') {
                if (n != 0) break;
                in_comment = true;
                continue;
            }
            if (isSpace(b)) {
                if (n != 0) break;
                continue;
            }
            if (n == buf.len) return error.InvalidData;
            buf[n] = b;
            n += 1;
        }
        return buf[0..n];
    }

    fn number(self: *Scanner, buf: []u8) DecodeError!u32 {
        const t = try self.token(buf);
        if (t.len == 0) return error.InvalidData;
        return std.fmt.parseInt(u32, t, 10) catch error.InvalidData;
    }
};

fn isSpace(b: u8) bool {
    return b == ' ' or b == '\t' or b == '\r' or b == '\n' or b == 0x0b or b == 0x0c;
}

/// Reads the header, and then the samples.
pub const Decoder = struct {
    header: Header,
    limits: Limits,

    /// Reads the magic number and the header, leaving `r` at the first sample.
    pub fn init(r: *Io.Reader, limits: Limits) DecodeError!Decoder {
        var magic: [2]u8 = undefined;
        r.readSliceAll(&magic) catch |err| switch (err) {
            error.EndOfStream => return error.UnknownFormat,
            error.ReadFailed => |e| return e,
        };
        if (magic[0] != 'P') return error.UnknownFormat;
        const kind = Kind.fromMagic(magic[1]) orelse return error.UnknownFormat;

        var scanner: Scanner = .{ .r = r };
        var buf: [32]u8 = undefined;

        const header: Header = if (kind == .arbitrary)
            try readPamHeader(&scanner, &buf)
        else blk: {
            const width = try scanner.number(&buf);
            const height = try scanner.number(&buf);
            const max_value: u32 = if (kind.isBitmap()) 1 else try scanner.number(&buf);
            if (max_value == 0 or max_value > 65535) return error.InvalidData;
            break :blk .{
                .kind = kind,
                .width = width,
                .height = height,
                .max_value = @intCast(max_value),
                .depth = if (kind == .colour_plain or kind == .colour_raw) 3 else 1,
            };
        };

        if (header.width == 0 or header.height == 0) return error.InvalidData;
        try limits.check(header.width, header.height);
        if (header.width > math.maxInt(i32) or header.height > math.maxInt(i32)) {
            return error.InvalidData;
        }
        return .{ .header = header, .limits = limits };
    }

    pub fn info(self: Decoder) Info {
        const alpha = self.header.hasAlpha();
        return .{
            .format = self.header.kind.asFormat(),
            .width = self.header.width,
            .height = self.header.height,
            .has_alpha = alpha,
            .surface_type = pixels.naturalSurfaceType(alpha),
        };
    }

    /// Reads the samples into a surface the caller owns.
    pub fn decode(self: *Decoder, gpa: Allocator, r: *Io.Reader, opts: DecodeOptions) DecodeError!z2d.Surface {
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

        // A file that stops early leaves the rest as it was. For a format with
        // no alpha that should read as white --- an unfinished page rather
        // than a black band --- and for one with alpha the surface is already
        // transparent, which says the same thing better.
        const unwritten: Rgba8 = if (self.header.hasAlpha()) .transparent else .rgb(255, 255, 255);

        var scanner: Scanner = .{ .r = r };
        var y: u32 = 0;
        while (y < self.header.height) : (y += 1) {
            @memset(row, unwritten);
            const complete = try self.readRow(r, &scanner, row);
            pixels.writeRow(&sfc, @intCast(y), row);
            if (!complete) {
                y += 1;
                break;
            }
        }

        // Only what the file did not reach is filled in, and only when the
        // fill is not what the surface already holds --- a whole image is
        // otherwise written twice, which on a large one is most of the
        // decode.
        if (!self.header.hasAlpha()) {
            @memset(row, unwritten);
            while (y < self.header.height) : (y += 1) pixels.writeRow(&sfc, @intCast(y), row);
        }
        return sfc;
    }

    /// One row, and whether all of it was there. A row that ran out is still
    /// written, so a truncated file decodes to as much of itself as it had.
    fn readRow(self: *Decoder, r: *Io.Reader, scanner: *Scanner, row: []Rgba8) DecodeError!bool {
        var buf: [32]u8 = undefined;
        const max: u32 = self.header.max_value;

        switch (self.header.kind) {
            .bitmap_plain => {
                for (row) |*px| {
                    const t = try scanner.token(&buf);
                    if (t.len == 0) return false;
                    // One is black. See the note at the top of this file.
                    px.* = if (t[0] != '0') .rgb(0, 0, 0) else .rgb(255, 255, 255);
                }
                return true;
            },

            .bitmap_raw => {
                const bytes_per_row = (row.len + 7) / 8;
                var packed_bits: [512]u8 = undefined;
                var at: usize = 0;
                while (at < bytes_per_row) {
                    const n = @min(packed_bits.len, bytes_per_row - at);
                    r.readSliceAll(packed_bits[0..n]) catch |err| switch (err) {
                        error.EndOfStream => return false,
                        error.ReadFailed => |e| return e,
                    };
                    for (packed_bits[0..n], 0..) |byte, i| {
                        const base = (at + i) * 8;
                        for (0..8) |b| {
                            const x = base + b;
                            if (x >= row.len) break;
                            // The *most* significant bit is the leftmost
                            // pixel, which is the opposite of XBM.
                            const ink = (byte >> @intCast(7 - b)) & 1 != 0;
                            row[x] = if (ink) .rgb(0, 0, 0) else .rgb(255, 255, 255);
                        }
                    }
                    at += n;
                }
                return true;
            },

            .grey_plain, .colour_plain => {
                for (row) |*px| {
                    var samples: [4]u32 = @splat(max);
                    for (0..self.header.depth) |i| {
                        const t = try scanner.token(&buf);
                        if (t.len == 0) return false;
                        samples[i] = std.fmt.parseInt(u32, t, 10) catch return error.InvalidData;
                    }
                    px.* = self.pixel(samples, max);
                }
                return true;
            },

            .grey_raw, .colour_raw, .arbitrary => {
                const wide = max > 255;
                const sample_bytes: usize = if (wide) 2 else 1;
                for (row) |*px| {
                    var samples: [4]u32 = @splat(max);
                    for (0..self.header.depth) |i| {
                        var sample: [2]u8 = undefined;
                        r.readSliceAll(sample[0..sample_bytes]) catch |err| switch (err) {
                            error.EndOfStream => return false,
                            error.ReadFailed => |e| return e,
                        };
                        samples[i] = if (wide)
                            (@as(u32, sample[0]) << 8) | sample[1]
                        else
                            sample[0];
                    }
                    px.* = self.pixel(samples, max);
                }
                return true;
            },
        }
    }

    /// One pixel's worth of samples, laid out by `depth`.
    fn pixel(self: *const Decoder, samples: [4]u32, max: u32) Rgba8 {
        return switch (self.header.depth) {
            1 => grey(scale(samples[0], max), 255),
            2 => grey(scale(samples[0], max), scale(samples[1], max)),
            3 => .{
                .r = scale(samples[0], max),
                .g = scale(samples[1], max),
                .b = scale(samples[2], max),
                .a = 255,
            },
            else => .{
                .r = scale(samples[0], max),
                .g = scale(samples[1], max),
                .b = scale(samples[2], max),
                .a = scale(samples[3], max),
            },
        };
    }
};

fn grey(v: u8, a: u8) Rgba8 {
    return .{ .r = v, .g = v, .b = v, .a = a };
}

/// A sample against its maximum, in eight bits, so that the maximum itself
/// becomes 255 exactly rather than 254.
fn scale(value: u32, max: u32) u8 {
    if (max == 0) return 0;
    const clamped = @min(value, max);
    if (max == 255) return @intCast(clamped);
    return @intCast((clamped * 255 + max / 2) / max);
}

/// The other way: eight bits out to a sample against `max`.
fn unscale(value: u8, max: u16) u16 {
    if (max == 255) return value;
    return @intCast((@as(u32, value) * max + 127) / 255);
}

/// PAM's header: `KEY value` lines until `ENDHDR`.
fn readPamHeader(scanner: *Scanner, buf: []u8) DecodeError!Header {
    var width: ?u32 = null;
    var height: ?u32 = null;
    var depth: ?u32 = null;
    var max_value: ?u32 = null;

    // Bounded, so that a stream of keys nobody asked for cannot spin here.
    // A real PAM header has five lines.
    for (0..64) |_| {
        const key = try scanner.token(buf);
        if (key.len == 0) return error.InvalidData;
        if (mem.eql(u8, key, "ENDHDR")) break;

        var value: [32]u8 = undefined;
        if (mem.eql(u8, key, "WIDTH")) {
            width = try scanner.number(&value);
        } else if (mem.eql(u8, key, "HEIGHT")) {
            height = try scanner.number(&value);
        } else if (mem.eql(u8, key, "DEPTH")) {
            depth = try scanner.number(&value);
        } else if (mem.eql(u8, key, "MAXVAL")) {
            max_value = try scanner.number(&value);
        } else {
            // `TUPLTYPE`, and anything a later version adds. The depth says
            // how the samples are laid out; the tuple type only names what
            // they mean, and a reader that trusted the name over the count
            // would disagree with the file about how many bytes a pixel is.
            _ = try scanner.token(&value);
        }
    } else return error.InvalidData;

    const d = depth orelse return error.InvalidData;
    const m = max_value orelse return error.InvalidData;
    if (d == 0 or d > 4) return error.Unsupported;
    if (m == 0 or m > 65535) return error.InvalidData;

    return .{
        .kind = .arbitrary,
        .width = width orelse return error.InvalidData,
        .height = height orelse return error.InvalidData,
        .max_value = @intCast(m),
        .depth = @intCast(d),
    };
}

/// Reads a whole Netpbm image from `r`.
///
/// The caller owns the returned surface and must `deinit` it with `gpa`.
pub fn decode(gpa: Allocator, r: *Io.Reader, opts: DecodeOptions) DecodeError!z2d.Surface {
    if (opts.orientation) |out| out.* = .top_left;
    if (opts.icc) |out| out.clearRetainingCapacity();
    var decoder: Decoder = try .init(r, opts.limits);
    return decoder.decode(gpa, r, opts);
}

/// Reads only the header, and says what it described.
pub fn probe(r: *Io.Reader, limits: Limits) DecodeError!Info {
    const decoder: Decoder = try .init(r, limits);
    return decoder.info();
}

// ---------------------------------------------------------------------------
// Writing
// ---------------------------------------------------------------------------

/// How to write a PBM.
pub const BitmapOptions = struct {
    /// `P4`, the packed one, rather than `P1`, the one made of digits.
    binary: bool = true,

    /// A pixel darker than this becomes a set bit, which in this format means
    /// black. The middle of the range, which is the answer that needs no
    /// explaining; coverage is luminance by the same coefficients the JPEG
    /// encoder uses for `Y`.
    threshold: u8 = 128,
};

/// How to write a PGM.
pub const GreyOptions = struct {
    /// `P5` rather than `P2`.
    binary: bool = true,

    /// The `maxval` to write. A surface holds eight bits a channel, so
    /// anything above 255 buys no precision --- it is here because a pipeline
    /// downstream may insist on sixteen-bit samples.
    max_value: u16 = 255,
};

/// How to write a PPM.
pub const ColourOptions = struct {
    /// `P6` rather than `P3`.
    binary: bool = true,
    /// As `GreyOptions.max_value`.
    max_value: u16 = 255,
};

/// What a PAM pixel holds.
pub const Channels = enum {
    grey,
    grey_alpha,
    rgb,
    rgb_alpha,

    pub fn depth(self: Channels) u8 {
        return switch (self) {
            .grey => 1,
            .grey_alpha => 2,
            .rgb => 3,
            .rgb_alpha => 4,
        };
    }

    pub fn tupleType(self: Channels) []const u8 {
        return switch (self) {
            .grey => "GRAYSCALE",
            .grey_alpha => "GRAYSCALE_ALPHA",
            .rgb => "RGB",
            .rgb_alpha => "RGB_ALPHA",
        };
    }
};

/// How to write a PAM.
pub const ArbitraryOptions = struct {
    /// What to write, or null to take it from the surface: colour, with alpha
    /// if the surface has any.
    ///
    /// Taken from the surface's *type* rather than its contents, for the same
    /// reason `Info.has_alpha` is: deciding otherwise would mean reading the
    /// whole image before choosing the header.
    channels: ?Channels = null,
    /// As `GreyOptions.max_value`.
    max_value: u16 = 255,
};

// There is deliberately no `EncodeOptions` here and no `encode`. In every
// other codec in this library those two names are what the library's own
// `EncodeOptions` union holds and dispatches to, and here they could not be:
// one module writes four formats, so the union has four arms pointing at the
// four functions below. A `netpbm.EncodeOptions` would be a fifth spelling of
// the same choice, and the wrong one to reach for.

/// What is behind a transparent pixel in a format with no alpha channel:
/// white, because that is what a page is.
fn flatten(px: Rgba8) Rgba8 {
    if (px.a == 255) return px;
    const over = struct {
        fn f(v: u8, a: u8) u8 {
            const bg: u32 = 255 * (255 - @as(u32, a));
            return @intCast((@as(u32, v) * a + bg + 127) / 255);
        }
    }.f;
    return .{ .r = over(px.r, px.a), .g = over(px.g, px.a), .b = over(px.b, px.a), .a = 255 };
}

fn luminance(px: Rgba8) u8 {
    const f = flatten(px);
    return @intCast((19595 * @as(u32, f.r) + 38470 * @as(u32, f.g) + 7471 * @as(u32, f.b)) >> 16);
}

/// Checks the surface and returns its size, which every encoder here needs
/// before it writes a header.
fn dimensions(sfc: *const z2d.Surface) EncodeError!struct { u32, u32 } {
    const width = sfc.getWidth();
    const height = sfc.getHeight();
    if (width < 1 or height < 1) return error.Unsupported;
    return .{ @intCast(width), @intCast(height) };
}

/// Wraps the plain formats' samples, which the specification holds to 70
/// characters a line.
const Wrapper = struct {
    w: *Io.Writer,
    column: usize = 0,

    fn sample(self: *Wrapper, value: u32) EncodeError!void {
        var buf: [8]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "{d}", .{value}) catch unreachable;
        if (self.column != 0 and self.column + 1 + text.len > 70) {
            try self.w.writeByte('\n');
            self.column = 0;
        } else if (self.column != 0) {
            try self.w.writeByte(' ');
            self.column += 1;
        }
        try self.w.writeAll(text);
        self.column += text.len;
    }

    fn finish(self: *Wrapper) EncodeError!void {
        if (self.column != 0) try self.w.writeByte('\n');
        self.column = 0;
    }
};

pub fn encodeBitmap(
    gpa: Allocator,
    sfc: *const z2d.Surface,
    w: *Io.Writer,
    opts: BitmapOptions,
) EncodeError!void {
    const uw, const uh = try dimensions(sfc);
    try w.print("{s}\n{d} {d}\n", .{ if (opts.binary) "P4" else "P1", uw, uh });

    const row = try gpa.alloc(Rgba8, uw);
    defer gpa.free(row);
    var wrapper: Wrapper = .{ .w = w };

    for (0..uh) |y| {
        pixels.readRow(row, sfc, @intCast(y));
        if (!opts.binary) {
            for (row) |px| try wrapper.sample(@intFromBool(luminance(px) < opts.threshold));
            try wrapper.finish();
            continue;
        }
        // Packed, most significant bit leftmost, each row starting a new byte.
        var byte: u8 = 0;
        for (row, 0..) |px, x| {
            if (luminance(px) < opts.threshold) byte |= @as(u8, 0x80) >> @intCast(x % 8);
            if (x % 8 == 7) {
                try w.writeByte(byte);
                byte = 0;
            }
        }
        if (uw % 8 != 0) try w.writeByte(byte);
    }
}

pub fn encodeGrey(
    gpa: Allocator,
    sfc: *const z2d.Surface,
    w: *Io.Writer,
    opts: GreyOptions,
) EncodeError!void {
    if (opts.max_value == 0) return error.Unsupported;
    const uw, const uh = try dimensions(sfc);
    try w.print("{s}\n{d} {d}\n{d}\n", .{
        if (opts.binary) "P5" else "P2",
        uw,
        uh,
        opts.max_value,
    });

    const row = try gpa.alloc(Rgba8, uw);
    defer gpa.free(row);
    var wrapper: Wrapper = .{ .w = w };

    for (0..uh) |y| {
        pixels.readRow(row, sfc, @intCast(y));
        for (row) |px| {
            const v = unscale(luminance(px), opts.max_value);
            if (opts.binary) try writeSample(w, v, opts.max_value) else try wrapper.sample(v);
        }
        if (!opts.binary) try wrapper.finish();
    }
}

pub fn encodeColour(
    gpa: Allocator,
    sfc: *const z2d.Surface,
    w: *Io.Writer,
    opts: ColourOptions,
) EncodeError!void {
    if (opts.max_value == 0) return error.Unsupported;
    const uw, const uh = try dimensions(sfc);
    try w.print("{s}\n{d} {d}\n{d}\n", .{
        if (opts.binary) "P6" else "P3",
        uw,
        uh,
        opts.max_value,
    });

    const row = try gpa.alloc(Rgba8, uw);
    defer gpa.free(row);
    var wrapper: Wrapper = .{ .w = w };

    for (0..uh) |y| {
        pixels.readRow(row, sfc, @intCast(y));
        for (row) |raw| {
            const px = flatten(raw);
            for ([_]u8{ px.r, px.g, px.b }) |channel| {
                const v = unscale(channel, opts.max_value);
                if (opts.binary) try writeSample(w, v, opts.max_value) else try wrapper.sample(v);
            }
        }
        if (!opts.binary) try wrapper.finish();
    }
}

pub fn encodeArbitrary(
    gpa: Allocator,
    sfc: *const z2d.Surface,
    w: *Io.Writer,
    opts: ArbitraryOptions,
) EncodeError!void {
    if (opts.max_value == 0) return error.Unsupported;
    const uw, const uh = try dimensions(sfc);
    const channels = opts.channels orelse switch (sfc.*) {
        .image_surface_rgba, .image_surface_alpha8, .image_surface_alpha4, .image_surface_alpha2, .image_surface_alpha1 => Channels.rgb_alpha,
        else => Channels.rgb,
    };

    try w.print(
        "P7\nWIDTH {d}\nHEIGHT {d}\nDEPTH {d}\nMAXVAL {d}\nTUPLTYPE {s}\nENDHDR\n",
        .{ uw, uh, channels.depth(), opts.max_value, channels.tupleType() },
    );

    const row = try gpa.alloc(Rgba8, uw);
    defer gpa.free(row);

    for (0..uh) |y| {
        pixels.readRow(row, sfc, @intCast(y));
        for (row) |px| switch (channels) {
            .grey => try writeSample(w, unscale(luminance(px), opts.max_value), opts.max_value),
            .grey_alpha => {
                // Luminance of the colour as it is, not flattened: the alpha
                // is being kept, so there is nothing to flatten onto.
                const v: u8 = @intCast((19595 * @as(u32, px.r) + 38470 * @as(u32, px.g) + 7471 * @as(u32, px.b)) >> 16);
                try writeSample(w, unscale(v, opts.max_value), opts.max_value);
                try writeSample(w, unscale(px.a, opts.max_value), opts.max_value);
            },
            .rgb => {
                const f = flatten(px);
                for ([_]u8{ f.r, f.g, f.b }) |c| try writeSample(w, unscale(c, opts.max_value), opts.max_value);
            },
            .rgb_alpha => {
                for ([_]u8{ px.r, px.g, px.b, px.a }) |c| try writeSample(w, unscale(c, opts.max_value), opts.max_value);
            },
        };
    }
}

fn writeSample(w: *Io.Writer, value: u16, max: u16) EncodeError!void {
    if (max > 255) {
        try w.writeByte(@intCast(value >> 8));
        try w.writeByte(@truncate(value));
    } else {
        try w.writeByte(@intCast(value));
    }
}
