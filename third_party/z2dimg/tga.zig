// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Truevision TGA: eighteen bytes of header and then the pixels, mostly.
//!
//! A simple format with one awkward property: **it has no signature.** The
//! file begins with its header and the header begins with a length byte, so
//! there is nothing to match. Version 2.0 added a footer — the string
//! `TRUEVISION-XFILE.` in the last twenty-six bytes — which is a signature at
//! the wrong end of the file for a decoder that reads forwards and never
//! seeks.
//!
//! So `detect` answers `.tga` only from a structural check, and only after
//! every real signature has been tried: the colour map type must be 0 or 1,
//! the image type one of the seven that exist, the depth one of the five, and
//! a file claiming no colour map must have a colour map specification of
//! zeroes. That is enough to reject essentially everything that is not a TGA
//! while accepting every TGA, which is the best available answer — but it is a
//! heuristic and is documented as one, and a caller who knows what it has
//! should say so with `decodeAs`.
//!
//! ## What it holds
//!
//! Three kinds of image — colour-mapped, true-colour and greyscale — each
//! either uncompressed or run-length encoded, which is the seven types. Depths
//! of 8, 15, 16, 24 and 32 bits; 15 and 16 are the same five-bits-a-channel
//! layout, differing only in whether the sixteenth bit is an alpha bit.
//!
//! Rows are stored bottom-up unless bit 5 of the image descriptor says
//! otherwise, which is BMP's convention and the same source of upside-down
//! images.
//!
//! ## The alpha byte that is not alpha
//!
//! A 32-bit TGA has eight bits left over, and whether they are alpha or
//! padding is genuinely ambiguous. Version 2.0 added an attributes field to
//! the extension area to say which, and almost nothing writes it — so there
//! are 32-bit files in the world whose fourth byte is zero throughout and
//! which every reader that honours it renders as a blank image.
//!
//! The rule here: the alpha bits in the image descriptor are believed, and a
//! 32-bit image whose alpha is zero in *every* pixel is treated as opaque.
//! That second part is a guess, and it is the guess every other decoder makes,
//! because the alternative is handing back nothing at all.

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

/// The header, which is all a version 1.0 file has.
pub const header_len = 18;

/// What kind of image the file holds.
pub const ImageType = enum(u8) {
    none = 0,
    colour_mapped = 1,
    true_colour = 2,
    greyscale = 3,
    colour_mapped_rle = 9,
    true_colour_rle = 10,
    greyscale_rle = 11,
    _,

    pub fn isRle(self: ImageType) bool {
        return switch (self) {
            .colour_mapped_rle, .true_colour_rle, .greyscale_rle => true,
            else => false,
        };
    }

    pub fn isMapped(self: ImageType) bool {
        return self == .colour_mapped or self == .colour_mapped_rle;
    }

    pub fn known(self: ImageType) bool {
        return switch (self) {
            .none, .colour_mapped, .true_colour, .greyscale, .colour_mapped_rle, .true_colour_rle, .greyscale_rle => true,
            _ => false,
        };
    }
};

/// Whether a depth is one the format defines.
fn validDepth(depth: u8) bool {
    return switch (depth) {
        8, 15, 16, 24, 32 => true,
        else => false,
    };
}

pub const Header = struct {
    id_len: u8,
    has_colour_map: bool,
    image_type: ImageType,
    map_first: u16,
    map_len: u16,
    map_depth: u8,
    width: u32,
    height: u32,
    depth: u8,
    /// Bits of alpha the image descriptor claims, which is how a 16- or
    /// 32-bit file says whether its spare bits mean anything.
    alpha_bits: u4,
    /// Rows stored top to bottom, which is bit 5 of the image descriptor and
    /// the opposite of the default.
    top_down: bool,
};

/// Whether eighteen bytes are shaped like a TGA header.
///
/// Used by `format.detect` as a last resort, after every real signature. See
/// the note at the top of this file for why a heuristic is the best available
/// answer and what it costs.
pub fn looksLikeHeader(bytes: []const u8) bool {
    if (bytes.len < header_len) return false;
    const map_type = bytes[1];
    if (map_type > 1) return false;

    const image_type: ImageType = @fromBackingInt(@intCast(bytes[2]));
    if (!image_type.known() or image_type == .none) return false;

    const depth = bytes[16];
    if (!validDepth(depth)) return false;

    const width = mem.readInt(u16, bytes[12..14], .little);
    const height = mem.readInt(u16, bytes[14..16], .little);
    if (width == 0 or height == 0) return false;

    // A file with no colour map must say nothing about one, and a file with
    // one must say something consistent. Both halves reject a great deal.
    const map_len = mem.readInt(u16, bytes[5..7], .little);
    const map_depth = bytes[7];
    if (map_type == 0) {
        if (map_len != 0 or map_depth != 0) return false;
        if (mem.readInt(u16, bytes[3..5], .little) != 0) return false;
    } else {
        if (map_len == 0) return false;
        if (!validDepth(map_depth)) return false;
    }

    // A colour-mapped image needs a map and an unmapped one must not have a
    // map type saying otherwise.
    if (image_type.isMapped() != (map_type == 1)) return false;

    // The top two bits of the image descriptor are reserved and zero.
    return bytes[17] & 0xc0 == 0;
}

pub const Decoder = struct {
    header: Header,
    limits: Limits,
    /// Filled out to 256 entries, so an index past a short map is a colour
    /// rather than a read.
    palette: [256]Rgba8,

    pub fn init(r: *Io.Reader, limits: Limits) DecodeError!Decoder {
        var raw: [header_len]u8 = undefined;
        r.readSliceAll(&raw) catch |err| switch (err) {
            error.EndOfStream => return error.UnknownFormat,
            error.ReadFailed => |e| return e,
        };
        if (!looksLikeHeader(&raw)) return error.UnknownFormat;

        const image_type: ImageType = @fromBackingInt(@intCast(raw[2]));
        const header: Header = .{
            .id_len = raw[0],
            .has_colour_map = raw[1] == 1,
            .image_type = image_type,
            .map_first = mem.readInt(u16, raw[3..5], .little),
            .map_len = mem.readInt(u16, raw[5..7], .little),
            .map_depth = raw[7],
            .width = mem.readInt(u16, raw[12..14], .little),
            .height = mem.readInt(u16, raw[14..16], .little),
            .depth = raw[16],
            .alpha_bits = @intCast(raw[17] & 0x0f),
            .top_down = raw[17] & 0x20 != 0,
        };

        try limits.check(header.width, header.height);
        // A colour-mapped image is indices, so eight bits at most.
        if (header.image_type.isMapped() and header.depth != 8) return error.Unsupported;
        // Greyscale is one sample a pixel.
        if (header.image_type == .greyscale or header.image_type == .greyscale_rle) {
            if (header.depth != 8) return error.Unsupported;
        }

        var self: Decoder = .{
            .header = header,
            .limits = limits,
            .palette = @splat(.rgb(0, 0, 0)),
        };

        // The image identification field, which is a comment.
        try r.discardAll(header.id_len);

        if (header.has_colour_map) {
            if (header.map_len > 256) return error.Unsupported;
            const entry_bytes: u32 = switch (header.map_depth) {
                15, 16 => 2,
                24 => 3,
                32 => 4,
                8 => 1,
                else => return error.InvalidData,
            };
            var i: u32 = 0;
            while (i < header.map_len) : (i += 1) {
                var buf: [4]u8 = undefined;
                try r.readSliceAll(buf[0..entry_bytes]);
                const at = header.map_first + i;
                if (at < 256) self.palette[at] = unpack(buf[0..entry_bytes], header.map_depth, 8);
            }
        }
        return self;
    }

    pub fn info(self: Decoder) Info {
        const has_alpha = self.header.alpha_bits > 0;
        return .{
            .format = .tga,
            .width = self.header.width,
            .height = self.header.height,
            .has_alpha = has_alpha,
            .surface_type = pixels.naturalSurfaceType(has_alpha),
        };
    }

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

        const bytes_per_pixel: u32 = (self.header.depth + 7) / 8;
        const row = try gpa.alloc(Rgba8, self.header.width);
        defer gpa.free(row);
        @memset(row, .rgb(0, 0, 0));

        // Read every pixel into one buffer first, because a run in a
        // run-length image may cross a row boundary --- the encoding is of the
        // image, not of its rows.
        const count = @as(usize, self.header.width) * self.header.height;
        const image = try gpa.alloc(Rgba8, count);
        defer gpa.free(image);
        @memset(image, .rgb(0, 0, 0));

        if (self.header.image_type.isRle()) {
            try self.readRle(r, image, bytes_per_pixel);
        } else {
            try self.readPlain(r, image, bytes_per_pixel);
        }

        // A 32-bit file whose alpha is zero everywhere almost certainly means
        // padding rather than a blank image; see the note at the top.
        if (self.header.alpha_bits > 0 and allTransparent(image)) {
            for (image) |*px| px.a = 255;
        }

        var y: u32 = 0;
        while (y < self.header.height) : (y += 1) {
            const source = if (self.header.top_down) y else self.header.height - 1 - y;
            const start = @as(usize, source) * self.header.width;
            pixels.writeRow(&sfc, @intCast(y), image[start..][0..self.header.width]);
        }
        return sfc;
    }

    fn readPlain(self: *Decoder, r: *Io.Reader, image: []Rgba8, bytes_per_pixel: u32) DecodeError!void {
        var buf: [4]u8 = undefined;
        for (image) |*px| {
            r.readSliceAll(buf[0..bytes_per_pixel]) catch |err| switch (err) {
                // A truncated file keeps what it had.
                error.EndOfStream => return,
                error.ReadFailed => |e| return e,
            };
            px.* = self.pixel(buf[0..bytes_per_pixel]);
        }
    }

    fn readRle(self: *Decoder, r: *Io.Reader, image: []Rgba8, bytes_per_pixel: u32) DecodeError!void {
        var at: usize = 0;
        var buf: [4]u8 = undefined;
        while (at < image.len) {
            const packet = r.takeByte() catch |err| switch (err) {
                error.EndOfStream => return,
                error.ReadFailed => |e| return e,
            };
            // The low seven bits are one less than the count, so a packet is
            // one to a hundred and twenty-eight pixels and never zero.
            const n: usize = @as(usize, packet & 0x7f) + 1;
            const room = @min(n, image.len - at);

            if (packet & 0x80 != 0) {
                r.readSliceAll(buf[0..bytes_per_pixel]) catch |err| switch (err) {
                    error.EndOfStream => return,
                    error.ReadFailed => |e| return e,
                };
                const px = self.pixel(buf[0..bytes_per_pixel]);
                @memset(image[at..][0..room], px);
            } else {
                for (0..room) |i| {
                    r.readSliceAll(buf[0..bytes_per_pixel]) catch |err| switch (err) {
                        error.EndOfStream => return,
                        error.ReadFailed => |e| return e,
                    };
                    image[at + i] = self.pixel(buf[0..bytes_per_pixel]);
                }
                // A packet that runs past the end of the image still has to be
                // consumed, or everything after it is misread.
                for (room..n) |_| {
                    r.readSliceAll(buf[0..bytes_per_pixel]) catch return;
                }
            }
            at += room;
            if (room < n) return; // the image is full
        }
    }

    fn pixel(self: *const Decoder, bytes: []const u8) Rgba8 {
        return switch (self.header.image_type) {
            .colour_mapped, .colour_mapped_rle => self.palette[bytes[0]],
            .greyscale, .greyscale_rle => .rgb(bytes[0], bytes[0], bytes[0]),
            else => unpack(bytes, self.header.depth, self.header.alpha_bits),
        };
    }
};

/// One pixel of `depth` bits, in TGA's blue-green-red order.
fn unpack(bytes: []const u8, depth: u8, alpha_bits: u4) Rgba8 {
    return switch (depth) {
        8 => .rgb(bytes[0], bytes[0], bytes[0]),
        15, 16 => blk: {
            const v = mem.readInt(u16, bytes[0..2], .little);
            // Five bits a channel, scaled rather than shifted, so that the
            // brightest value is 255 and not 248.
            const r: u8 = @intCast((((v >> 10) & 0x1f) * 255 + 15) / 31);
            const g: u8 = @intCast((((v >> 5) & 0x1f) * 255 + 15) / 31);
            const b: u8 = @intCast(((v & 0x1f) * 255 + 15) / 31);
            if (depth == 16 and alpha_bits > 0 and v & 0x8000 == 0) {
                break :blk .{ .r = r, .g = g, .b = b, .a = 0 };
            }
            break :blk .rgb(r, g, b);
        },
        24 => .rgb(bytes[2], bytes[1], bytes[0]),
        32 => if (alpha_bits > 0)
            .{ .r = bytes[2], .g = bytes[1], .b = bytes[0], .a = bytes[3] }
        else
            .rgb(bytes[2], bytes[1], bytes[0]),
        else => .rgb(0, 0, 0),
    };
}

fn allTransparent(image: []const Rgba8) bool {
    for (image) |px| {
        if (px.a != 0) return false;
    }
    return true;
}

/// Reads a whole TGA from `r`, producing a surface the caller owns.
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

// -- writing -----------------------------------------------------------------

/// How to write a TGA.
pub const EncodeOptions = struct {
    /// Run-length encode the pixels.
    ///
    /// TGA's run-length encoding is per-image rather than per-row, so a run
    /// may cross from one row into the next. On a photograph it makes the file
    /// slightly larger than not bothering, which is why it is a choice.
    rle: bool = false,

    /// Store the rows top to bottom.
    ///
    /// The format's default is bottom-up, which is what almost every TGA is
    /// and what the oldest readers assume. Top-down is signalled by a bit in
    /// the image descriptor and is understood by everything current.
    top_down: bool = false,
};

/// Writes `sfc` as a TGA.
///
/// True-colour, 24 bits a pixel, or 32 when the surface has transparency to
/// carry. No colour map: a mapped file would need a palette, and this library
/// does not quantise — see `gif` and `xpm`, where the same choice is made and
/// explained.
///
/// The alpha written is straight alpha, demultiplied from what the surface
/// holds, so a decode-and-encode round trip is not promised to be byte-exact
/// for an image with transparency, exactly as for PNG.
pub fn encode(
    gpa: Allocator,
    sfc: *const z2d.Surface,
    w: *Io.Writer,
    opts: EncodeOptions,
) EncodeError!void {
    const width = sfc.getWidth();
    const height = sfc.getHeight();
    if (width < 1 or height < 1) return error.Unsupported;
    // Both dimensions go into a sixteen-bit field.
    if (width > math.maxInt(u16) or height > math.maxInt(u16)) return error.Unsupported;

    const uw: u32 = @intCast(width);
    const uh: u32 = @intCast(height);
    const has_alpha = switch (sfc.getFormat()) {
        .rgba, .argb, .alpha8, .alpha4, .alpha2, .alpha1 => true,
        .rgb, .xrgb => false,
    };
    const bytes_per_pixel: u32 = if (has_alpha) 4 else 3;

    var header: [header_len]u8 = @splat(0);
    header[2] = @backingInt(if (opts.rle) ImageType.true_colour_rle else ImageType.true_colour);
    mem.writeInt(u16, header[12..14], @intCast(uw), .little);
    mem.writeInt(u16, header[14..16], @intCast(uh), .little);
    header[16] = @intCast(bytes_per_pixel * 8);
    header[17] = (if (has_alpha) @as(u8, 8) else 0) | (if (opts.top_down) @as(u8, 0x20) else 0);
    try w.writeAll(&header);

    const row = try gpa.alloc(Rgba8, uw);
    defer gpa.free(row);

    var y: u32 = 0;
    while (y < uh) : (y += 1) {
        const source = if (opts.top_down) y else uh - 1 - y;
        pixels.readRow(row, sfc, @intCast(source));
        if (opts.rle) {
            try writeRleRow(w, row, has_alpha);
        } else {
            for (row) |px| try writePixel(w, px, has_alpha);
        }
    }
}

/// One row, run-length encoded.
///
/// Runs are not carried across rows even though the format would allow it. A
/// run that spans a row boundary saves at most a byte or two and makes the
/// encoder stateful across the whole image; keeping each row self-contained
/// costs almost nothing and is far easier to be sure of.
fn writeRleRow(w: *Io.Writer, row: []const Rgba8, has_alpha: bool) EncodeError!void {
    var at: usize = 0;
    while (at < row.len) {
        // How many of the next pixels are the same.
        var run: usize = 1;
        while (at + run < row.len and run < 128 and
            std.meta.eql(row[at + run], row[at])) run += 1;

        if (run >= 2) {
            try w.writeByte(@intCast(0x80 | (run - 1)));
            try writePixel(w, row[at], has_alpha);
            at += run;
            continue;
        }

        // Otherwise a literal packet, running up to the next pair of equal
        // pixels: a run of two is not worth breaking a literal for, but a run
        // of three is.
        var len: usize = 1;
        while (at + len < row.len and len < 128) {
            const same_ahead = at + len + 2 < row.len and
                std.meta.eql(row[at + len], row[at + len + 1]) and
                std.meta.eql(row[at + len], row[at + len + 2]);
            if (same_ahead) break;
            len += 1;
        }
        try w.writeByte(@intCast(len - 1));
        for (row[at..][0..len]) |px| try writePixel(w, px, has_alpha);
        at += len;
    }
}

fn writePixel(w: *Io.Writer, px: Rgba8, has_alpha: bool) EncodeError!void {
    // Blue, green, red --- which is the order the format stores them in and
    // the reason a TGA read as RGB comes out with the sky orange.
    if (has_alpha) {
        const straight = demultiply(px);
        try w.writeAll(&.{ straight.b, straight.g, straight.r, straight.a });
    } else {
        try w.writeAll(&.{ px.b, px.g, px.r });
    }
}

/// A surface holds its colours multiplied by their alpha; a TGA does not.
fn demultiply(px: Rgba8) Rgba8 {
    if (px.a == 0) return .{ .r = 0, .g = 0, .b = 0, .a = 0 };
    if (px.a == 255) return px;
    const a: u32 = px.a;
    return .{
        .r = @intCast(@min(255, (@as(u32, px.r) * 255 + a / 2) / a)),
        .g = @intCast(@min(255, (@as(u32, px.g) * 255 + a / 2) / a)),
        .b = @intCast(@min(255, (@as(u32, px.b) * 255 + a / 2) / a)),
        .a = px.a,
    };
}
