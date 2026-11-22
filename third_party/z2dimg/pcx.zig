// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! PCX: ZSoft's PC Paintbrush format, and a tour of 1980s graphics hardware.
//!
//! A 128-byte header, then rows of run-length-encoded bytes. What makes it
//! more than that is how many ways it has of saying what a pixel is, because
//! it grew alongside the display adapters it was written for and kept a shape
//! for each of them.
//!
//! Two numbers in the header decide: `bits_per_pixel`, which is per *plane*,
//! and `planes`. Their product is the depth.
//!
//! | bits | planes | what it is |
//! | --- | --- | --- |
//! | 1 | 1 | monochrome |
//! | 1 | 4 | sixteen colours, EGA, one bit in each of four planes |
//! | 2 | 1 | four colours, CGA |
//! | 4 | 1 | sixteen colours packed two to a byte |
//! | 8 | 1 | two hundred and fifty-six colours |
//! | 8 | 3 | true colour, one plane each for red, green and blue |
//! | 8 | 4 | true colour and an alpha plane, which almost nothing writes |
//!
//! The planar forms are the awkward ones and they are not historical
//! curiosities: ImageMagick still writes `1`×`4` for any image of sixteen
//! colours or fewer. A row there is four separate bit-planes one after
//! another, and a pixel's index is assembled a bit at a time from the same
//! position in each.
//!
//! ## Where the colours are
//!
//! In two places, and which one depends on the depth.
//!
//! Sixteen colours or fewer take the **48-byte palette in the header**, which
//! holds sixteen entries whatever the depth actually needs. Two hundred and
//! fifty-six colours take a **768-byte palette after the image data**,
//! introduced by a `0x0C` byte, because there was nowhere in a header that
//! was already fixed at 128 bytes to put it.
//!
//! Files carry both. ImageMagick writes a trailing 256-entry palette onto a
//! four-plane file whose first sixteen entries repeat the header's; reading
//! the header one is right and reading the trailing one would also work, and
//! a decoder should not depend on the second being there.
//!
//! A **version 3** file is the exception: it declares that it has no palette
//! at all, and means the default sixteen EGA colours, which are written out
//! in `default_ega` below because there is nowhere else to get them.
//!
//! ## The run that crosses a row
//!
//! The specification says a run does not span scanlines. Encoders exist that
//! let one, so this decodes the image data as one continuous stream and cuts
//! it into rows afterwards, which reads both kinds and cannot desynchronise
//! on either.

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

/// The byte every PCX begins with, and the only part of the header that is a
/// signature rather than a field.
pub const magic: u8 = 0x0a;

/// The header, and the whole of what a decoder has to agree with before it
/// reads a pixel.
pub const Header = struct {
    version: u8,
    /// Whether the rows are run-length encoded. Zero means they are not,
    /// which a handful of very early files are.
    encoded: bool,
    /// Bits per pixel **per plane**, not in total.
    bits: u8,
    planes: u8,
    width: u32,
    height: u32,
    /// Bytes a plane occupies in one row, which is not always the least that
    /// would hold the pixels: the format pads it, conventionally to an even
    /// number, and the padding is not pixel data.
    bytes_per_line: u32,
    /// Two means the palette is a greyscale ramp rather than colours. Almost
    /// nothing sets it, and nothing this reads depends on it.
    palette_info: u16,
    /// The sixteen entries every header carries, whether or not they are the
    /// palette in force.
    ega: [16]Rgba8,

    /// The bits a pixel occupies once its planes are put together.
    pub fn depth(self: Header) u32 {
        return @as(u32, self.bits) * self.planes;
    }
};

/// The sixteen colours a version 3 file means when it says it has no palette.
///
/// The IBM EGA's default text-mode palette, which is what PC Paintbrush was
/// drawing with. There is nowhere in such a file to read them from, so a
/// decoder either knows them or renders one of these files in the wrong
/// colours.
pub const default_ega = [16]Rgba8{
    .rgb(0, 0, 0),     .rgb(0, 0, 170),    .rgb(0, 170, 0),    .rgb(0, 170, 170),
    .rgb(170, 0, 0),   .rgb(170, 0, 170),  .rgb(170, 85, 0),   .rgb(170, 170, 170),
    .rgb(85, 85, 85),  .rgb(85, 85, 255),  .rgb(85, 255, 85),  .rgb(85, 255, 255),
    .rgb(255, 85, 85), .rgb(255, 85, 255), .rgb(255, 255, 85), .rgb(255, 255, 255),
};

/// Whether a window begins something shaped like a PCX header.
///
/// One magic byte is not much, so this reads five fields rather than one: the
/// manufacturer byte, a version that exists, an encoding that exists, a depth
/// that exists and a plane count that exists. A file passing all five and not
/// being a PCX would have to be trying.
pub fn looksLikeHeader(bytes: []const u8) bool {
    if (bytes.len < 70) return false;
    if (bytes[0] != magic) return false;
    switch (bytes[1]) {
        0, 2, 3, 4, 5 => {},
        else => return false,
    }
    if (bytes[2] > 1) return false;
    switch (bytes[3]) {
        1, 2, 4, 8 => {},
        else => return false,
    }
    switch (bytes[65]) {
        1, 2, 3, 4 => {},
        else => return false,
    }
    // A row of no bytes describes no image.
    if (mem.readInt(u16, bytes[66..68], .little) == 0) return false;
    // And a window whose corners are the wrong way round.
    if (mem.readInt(u16, bytes[8..10], .little) < mem.readInt(u16, bytes[4..6], .little)) return false;
    if (mem.readInt(u16, bytes[10..12], .little) < mem.readInt(u16, bytes[6..8], .little)) return false;
    return true;
}

pub const Decoder = struct {
    header: Header,
    limits: Limits,

    pub fn init(r: *Io.Reader, limits: Limits) DecodeError!Decoder {
        var buf: [128]u8 = undefined;
        r.readSliceAll(&buf) catch |err| switch (err) {
            error.EndOfStream => return error.UnknownFormat,
            error.ReadFailed => |e| return e,
        };
        if (!looksLikeHeader(&buf)) return error.UnknownFormat;

        const xmin = mem.readInt(u16, buf[4..6], .little);
        const ymin = mem.readInt(u16, buf[6..8], .little);
        const xmax = mem.readInt(u16, buf[8..10], .little);
        const ymax = mem.readInt(u16, buf[10..12], .little);

        var ega: [16]Rgba8 = undefined;
        for (&ega, 0..) |*slot, i| {
            slot.* = .rgb(buf[16 + i * 3], buf[17 + i * 3], buf[18 + i * 3]);
        }

        const header: Header = .{
            .version = buf[1],
            .encoded = buf[2] == 1,
            .bits = buf[3],
            .planes = buf[65],
            // The window is inclusive at both ends, which is the one place a
            // PCX is off by one from everything else.
            .width = @as(u32, xmax - xmin) + 1,
            .height = @as(u32, ymax - ymin) + 1,
            .bytes_per_line = mem.readInt(u16, buf[66..68], .little),
            .palette_info = mem.readInt(u16, buf[68..70], .little),
            .ega = ega,
        };

        // A row has to have somewhere to put the pixels it claims.
        const needed = (@as(u64, header.width) * header.bits + 7) / 8;
        if (header.bytes_per_line < needed) return error.InvalidData;
        // Depths the format does not define.
        switch (header.depth()) {
            1, 2, 4, 8, 16, 24, 32 => {},
            else => return error.Unsupported,
        }
        try limits.check(header.width, header.height);
        return .{ .header = header, .limits = limits };
    }

    pub fn info(self: Decoder) Info {
        const alpha = self.header.bits == 8 and self.header.planes == 4;
        return .{
            .format = .pcx,
            .width = self.header.width,
            .height = self.header.height,
            .has_alpha = alpha,
            .surface_type = pixels.naturalSurfaceType(alpha),
        };
    }

    pub fn decode(self: *Decoder, gpa: Allocator, r: *Io.Reader, opts: DecodeOptions) DecodeError!z2d.Surface {
        const h = self.header;
        const surface_type = opts.surface_type orelse self.info().surface_type;
        var sfc: z2d.Surface = z2d.Surface.init(
            surface_type,
            gpa,
            @intCast(h.width),
            @intCast(h.height),
        ) catch |err| switch (err) {
            error.InvalidWidth, error.InvalidHeight => return error.InvalidData,
            error.OutOfMemory => |e| return e,
        };
        errdefer sfc.deinit(gpa);

        // The whole image as raw plane bytes. Bounded by the header, which
        // the limits have already agreed to: rows times planes times the
        // row's declared length.
        const row_len = @as(u64, h.bytes_per_line) * h.planes;
        const total = row_len * h.height;
        if (total > self.limits.max_input_bytes) return error.ImageTooLarge;
        const raw = try gpa.alloc(u8, math.cast(usize, total) orelse return error.ImageTooLarge);
        defer gpa.free(raw);
        @memset(raw, 0);

        const filled = try self.readPlanes(r, raw);
        // A file that stopped early keeps what arrived; the rest is already
        // zero, which for every depth here is the palette's first colour.
        _ = filled;

        const palette = try self.readPalette(r);

        const row = try gpa.alloc(Rgba8, h.width);
        defer gpa.free(row);

        for (0..h.height) |y| {
            const base = @as(usize, @intCast(y)) * @as(usize, @intCast(row_len));
            self.expand(raw[base..][0..@intCast(row_len)], row, &palette);
            pixels.writeRow(&sfc, @intCast(y), row);
        }
        return sfc;
    }

    /// The image data, run-length decoded if the header says it is encoded.
    ///
    /// Decoded as one continuous stream rather than a row at a time: the
    /// specification says a run does not cross a scanline, encoders exist
    /// that let one, and a decoder that resynchronised per row would read
    /// those files wrongly while a decoder that does not cannot tell the
    /// difference.
    fn readPlanes(self: *Decoder, r: *Io.Reader, raw: []u8) DecodeError!usize {
        if (!self.header.encoded) {
            r.readSliceAll(raw) catch |err| switch (err) {
                error.EndOfStream => return raw.len,
                error.ReadFailed => |e| return e,
            };
            return raw.len;
        }

        var at: usize = 0;
        while (at < raw.len) {
            const byte = r.takeByte() catch |err| switch (err) {
                error.EndOfStream => return at,
                error.ReadFailed => |e| return e,
            };
            if (byte & 0xc0 != 0xc0) {
                raw[at] = byte;
                at += 1;
                continue;
            }
            const count = byte & 0x3f;
            const value = r.takeByte() catch |err| switch (err) {
                error.EndOfStream => return at,
                error.ReadFailed => |e| return e,
            };
            // A run longer than what is left fills what is left. Refusing
            // would throw away an image over its last byte.
            const n = @min(@as(usize, count), raw.len - at);
            @memset(raw[at..][0..n], value);
            at += n;
        }
        return at;
    }

    /// The colours in force, from whichever of the two places holds them.
    fn readPalette(self: *Decoder, r: *Io.Reader) DecodeError![256]Rgba8 {
        var palette: [256]Rgba8 = @splat(.rgb(0, 0, 0));

        // A version 3 file says it has no palette, and means the EGA
        // defaults. Nothing in the file says otherwise and nothing can.
        if (self.header.version == 3) {
            @memcpy(palette[0..16], &default_ega);
            return palette;
        }

        if (self.header.bits == 8 and self.header.planes == 1) {
            // Two hundred and fifty-six colours live after the image, behind
            // a marker byte, because a 128-byte header had nowhere to put
            // them.
            const marker = r.takeByte() catch |err| switch (err) {
                // No trailing palette. A greyscale ramp is the least wrong
                // thing left: the header's sixteen entries cannot describe
                // two hundred and fifty-six colours, and black would make the
                // image disappear.
                error.EndOfStream => {
                    for (&palette, 0..) |*slot, i| slot.* = .rgb(@intCast(i), @intCast(i), @intCast(i));
                    return palette;
                },
                error.ReadFailed => |e| return e,
            };
            if (marker == 0x0c) {
                var buf: [768]u8 = undefined;
                r.readSliceAll(&buf) catch |err| switch (err) {
                    error.EndOfStream => {
                        for (&palette, 0..) |*slot, i| slot.* = .rgb(@intCast(i), @intCast(i), @intCast(i));
                        return palette;
                    },
                    error.ReadFailed => |e| return e,
                };
                for (&palette, 0..) |*slot, i| {
                    slot.* = .rgb(buf[i * 3], buf[i * 3 + 1], buf[i * 3 + 2]);
                }
                return palette;
            }
            for (&palette, 0..) |*slot, i| slot.* = .rgb(@intCast(i), @intCast(i), @intCast(i));
            return palette;
        }

        @memcpy(palette[0..16], &self.header.ega);

        // A monochrome file whose two entries are the same colour has a
        // palette that cannot tell its two values apart, which makes the
        // image one flat rectangle. That is not what the file means: writers
        // leave the palette blank because a one-bit image has only ever meant
        // black and white, and Pillow writes exactly that --- sixteen entries
        // of zero on an image it then renders in black and white itself.
        //
        // Scoped to one bit in one plane on purpose. A four-plane or
        // four-bit file names real colours and is believed.
        if (self.header.bits == 1 and self.header.planes == 1 and
            std.meta.eql(palette[0], palette[1]))
        {
            palette[0] = .rgb(0, 0, 0);
            palette[1] = .rgb(255, 255, 255);
        }
        return palette;
    }

    /// One row of plane bytes, as pixels.
    fn expand(self: *Decoder, raw: []const u8, row: []Rgba8, palette: *const [256]Rgba8) void {
        const h = self.header;
        const bpl: usize = @intCast(h.bytes_per_line);

        // True colour: one plane a channel, and no palette at all.
        if (h.bits == 8 and h.planes >= 3) {
            for (row, 0..) |*px, x| {
                px.* = .{
                    .r = raw[x],
                    .g = raw[bpl + x],
                    .b = raw[bpl * 2 + x],
                    .a = if (h.planes >= 4) raw[bpl * 3 + x] else 255,
                };
            }
            return;
        }

        if (h.bits == 8 and h.planes == 1) {
            for (row, 0..) |*px, x| px.* = palette[raw[x]];
            return;
        }

        // Everything else is an index assembled out of bits. For a single
        // plane they are adjacent in one byte; for several they are the same
        // position in each plane, one bit of the index from each --- which is
        // how an EGA addressed its memory and why this shape exists at all.
        for (row, 0..) |*px, x| {
            var index: u32 = 0;
            for (0..h.planes) |plane| {
                const bit_at = x * h.bits;
                const byte = raw[plane * bpl + bit_at / 8];
                const shift: u3 = @intCast(8 - h.bits - (bit_at % 8));
                const mask: u32 = (@as(u32, 1) << @intCast(h.bits)) - 1;
                const part = (byte >> shift) & @as(u8, @intCast(mask));
                index |= @as(u32, part) << @intCast(plane * h.bits);
            }
            px.* = palette[index & 0xff];
        }
    }
};

/// Reads a PCX from `r`, producing a surface the caller owns.
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

/// Which of the format's shapes to write.
///
/// Named for what a reader sees, with the header's `bits`×`planes` beside
/// each. Monochrome, one bit in one plane, is missing on purpose: no palette
/// written into it means the same thing to everyone. Pillow reads a set bit as
/// white and ImageMagick as black, whatever the header says, so a
/// two-color image goes out as `.planar_16` instead, which both read as
/// written.
pub const Shape = enum {
    /// The shallowest of `.planar_16`, `.indexed_256` and `.rgb` that holds
    /// the image without losing a color: the smallest file every reader
    /// reads.
    auto,
    /// True color, 8×3: a plane each for red, green and blue. Every reader.
    rgb,
    /// True color and alpha, 8×4. The one shape that keeps transparency.
    /// ImageMagick reads it; **Pillow does not**.
    rgba,
    /// Up to 256 colors, 8×1, with the palette after the image. Every
    /// reader.
    indexed_256,
    /// Up to sixteen colors, 1×4: EGA's four bit-planes, with the palette in
    /// the header. Every reader, and what ImageMagick itself writes for an
    /// image this small in colors.
    planar_16,
    /// Up to sixteen colors, 4×1, packed two pixels to a byte. ImageMagick
    /// reads it; **Pillow does not**.
    packed_16,
    /// Up to four colors, 2×1, packed four pixels to a byte: CGA's shape.
    /// ImageMagick reads it; **Pillow does not**. The palette is written as
    /// four colors in the header, which is how modern readers take it;
    /// software of the CGA's own era read those bytes as the adapter's
    /// palette-select settings instead, and would show other colors.
    packed_4,

    fn bits(self: Shape) u8 {
        return switch (self) {
            .auto => unreachable,
            .rgb, .rgba, .indexed_256 => 8,
            .planar_16 => 1,
            .packed_16 => 4,
            .packed_4 => 2,
        };
    }

    fn planes(self: Shape) u8 {
        return switch (self) {
            .auto => unreachable,
            .rgb => 3,
            .rgba, .planar_16 => 4,
            .indexed_256, .packed_16, .packed_4 => 1,
        };
    }

    /// How many colors the shape's palette holds, or null for true color.
    fn colors(self: Shape) ?u16 {
        return switch (self) {
            .auto, .rgb, .rgba => null,
            .indexed_256 => 256,
            .planar_16, .packed_16 => 16,
            .packed_4 => 4,
        };
    }
};

/// How to write a PCX.
pub const EncodeOptions = struct {
    /// Which shape to write. The default is true color, which every reader
    /// reads and which never refuses an image; `.auto` writes the smallest
    /// shape that loses nothing.
    shape: Shape = .rgb,

    /// Whether to run-length encode the rows.
    ///
    /// The format allows either and every file anyone has is encoded, which
    /// is a warning as much as a fact: **Pillow cannot read an unencoded
    /// PCX** --- it reports a buffer overrun --- while ImageMagick reads one
    /// happily. So a file written with this off is valid, is smaller to
    /// produce, and is one that a reader in the wild may refuse. It is off
    /// the beaten path and the default keeps to the path.
    encoded: bool = true,
};

/// Writes a surface out as a PCX, version 5, in the shape `opts` asks for.
///
/// **Nothing here reduces colors**, for the same reason `gif` and `xpm` do
/// not: quantising is a discipline of its own, and a caller who wants it has
/// opinions this library has no way to ask for. A paletted shape takes the
/// image's own colors, in the order they are first met, and an image with
/// more of them than the shape holds is `error.Unsupported`. `.auto` never
/// refuses, since true color holds anything.
///
/// Only `.rgba` has alpha. Every other shape flattens a transparent pixel onto
/// white on the way out, since something has to be behind it, and it is the
/// flattened colors a palette is made of.
pub fn encode(
    gpa: Allocator,
    sfc: *const z2d.Surface,
    w: *Io.Writer,
    opts: EncodeOptions,
) EncodeError!void {
    const width = sfc.getWidth();
    const height = sfc.getHeight();
    if (width < 1 or height < 1) return error.Unsupported;
    // The window is a pair of inclusive sixteen-bit corners, so the largest
    // image is one past what they can name apart.
    if (width > math.maxInt(u16) or height > math.maxInt(u16)) return error.Unsupported;

    switch (opts.shape) {
        .rgb, .rgba => return writeTrueColor(gpa, sfc, w, opts),
        .auto => {
            // One pass decides and, when a palette will do, is the palette.
            var indexed = Indexed.init(gpa, sfc, 256) catch |err| switch (err) {
                error.Unsupported => return writeTrueColor(gpa, sfc, w, .{
                    .shape = .rgb,
                    .encoded = opts.encoded,
                }),
                else => |e| return e,
            };
            defer indexed.deinit(gpa);
            const shape: Shape = if (indexed.count <= 16) .planar_16 else .indexed_256;
            return writeIndexed(gpa, &indexed, w, shape, opts.encoded);
        },
        else => |shape| {
            var indexed = try Indexed.init(gpa, sfc, shape.colors().?);
            defer indexed.deinit(gpa);
            return writeIndexed(gpa, &indexed, w, shape, opts.encoded);
        },
    }
}

/// The header every shape starts with. `ega` is the sixteen-entry palette the
/// header carries, which only the shapes of sixteen colors or fewer read.
fn writeHeader(
    w: *Io.Writer,
    width: u32,
    height: u32,
    shape: Shape,
    encoded: bool,
    bytes_per_line: u32,
    ega: []const Rgba8,
) EncodeError!void {
    var header: [128]u8 = @splat(0);
    header[0] = magic;
    header[1] = 5; // version 5: the header palette is real, and one may follow
    header[2] = if (encoded) 1 else 0;
    header[3] = shape.bits(); // bits per pixel per plane
    mem.writeInt(u16, header[4..6], 0, .little); // xmin
    mem.writeInt(u16, header[6..8], 0, .little); // ymin
    mem.writeInt(u16, header[8..10], @intCast(width - 1), .little); // xmax, inclusive
    mem.writeInt(u16, header[10..12], @intCast(height - 1), .little); // ymax
    mem.writeInt(u16, header[12..14], 72, .little); // horizontal dots per inch
    mem.writeInt(u16, header[14..16], 72, .little);
    for (ega[0..@min(ega.len, 16)], 0..) |c, i| {
        header[16 + i * 3] = c.r;
        header[17 + i * 3] = c.g;
        header[18 + i * 3] = c.b;
    }
    header[65] = shape.planes();
    mem.writeInt(u16, header[66..68], @intCast(bytes_per_line), .little);
    mem.writeInt(u16, header[68..70], 1, .little); // the palette is color
    try w.writeAll(&header);
}

/// Bytes a plane occupies in one row. Conventionally even, and enough
/// decoders assume it that writing an odd one is asking for trouble.
fn bytesPerLine(width: u32, bits: u8) u32 {
    const n = (width * bits + 7) / 8;
    return n + (n & 1);
}

/// `.rgb` and `.rgba`: a plane a channel, and no palette at all.
fn writeTrueColor(
    gpa: Allocator,
    sfc: *const z2d.Surface,
    w: *Io.Writer,
    opts: EncodeOptions,
) EncodeError!void {
    const uw: u32 = @intCast(sfc.getWidth());
    const uh: u32 = @intCast(sfc.getHeight());
    const alpha = opts.shape == .rgba;
    const bytes_per_line = bytesPerLine(uw, 8);
    try writeHeader(w, uw, uh, opts.shape, opts.encoded, bytes_per_line, &.{});

    const row = try gpa.alloc(Rgba8, uw);
    defer gpa.free(row);
    // One plane's worth of a row, reused. Three or four of these go out per
    // row, and the padding byte on an odd width is part of each.
    const plane = try gpa.alloc(u8, bytes_per_line);
    defer gpa.free(plane);
    @memset(plane, 0);

    for (0..uh) |y| {
        pixels.readRow(row, sfc, @intCast(y));
        for (0..opts.shape.planes()) |channel| {
            for (row, 0..) |px, x| {
                // Straight alpha, which is what a reader of the fourth plane
                // expects; the surface's premultiplication is undone by
                // `readRow`.
                const c = if (alpha) px else flatten(px);
                plane[x] = switch (channel) {
                    0 => c.r,
                    1 => c.g,
                    2 => c.b,
                    else => c.a,
                };
            }
            if (opts.encoded) try writeRle(w, plane) else try w.writeAll(plane);
        }
    }
}

/// The paletted shapes: every row as indices, cut into planes and packed at
/// whatever depth the shape has.
fn writeIndexed(
    gpa: Allocator,
    indexed: *const Indexed,
    w: *Io.Writer,
    shape: Shape,
    encoded: bool,
) EncodeError!void {
    const uw = indexed.width;
    const uh = indexed.height;
    const bits = shape.bits();
    const bytes_per_line = bytesPerLine(uw, bits);
    // Two hundred and fifty-six colors go after the image; sixteen or fewer
    // in the header, where they have always been.
    const in_header = shape != .indexed_256;
    try writeHeader(
        w,
        uw,
        uh,
        shape,
        encoded,
        bytes_per_line,
        if (in_header) indexed.palette[0..indexed.count] else &.{},
    );

    const plane = try gpa.alloc(u8, bytes_per_line);
    defer gpa.free(plane);

    for (0..uh) |y| {
        const row = indexed.indices[y * uw ..][0..uw];
        for (0..shape.planes()) |p| {
            @memset(plane, 0);
            if (bits == 8) {
                @memcpy(plane[0..uw], row);
            } else if (shape.planes() > 1) {
                // One bit of each index in each plane: bit `p` of every pixel
                // goes into plane `p`, most significant pixel first.
                for (row, 0..) |index, x| {
                    const bit: u8 = (index >> @intCast(p)) & 1;
                    plane[x / 8] |= bit << @intCast(7 - x % 8);
                }
            } else {
                // Several pixels to a byte, the first in the high bits.
                const per_byte = 8 / bits;
                for (row, 0..) |index, x| {
                    const shift: u3 = @intCast(8 - bits - (x % per_byte) * bits);
                    plane[x / per_byte] |= index << shift;
                }
            }
            if (encoded) try writeRle(w, plane) else try w.writeAll(plane);
        }
    }

    if (!in_header) {
        var trailer: [769]u8 = @splat(0);
        trailer[0] = 0x0c;
        for (indexed.palette[0..indexed.count], 0..) |c, i| {
            trailer[1 + i * 3] = c.r;
            trailer[2 + i * 3] = c.g;
            trailer[3 + i * 3] = c.b;
        }
        try w.writeAll(&trailer);
    }
}

/// An image as a palette and an index a pixel.
const Indexed = struct {
    width: u32,
    height: u32,
    /// The colors, in the order they are first met, so that a file written
    /// twice is the same both times.
    palette: [256]Rgba8,
    count: u16,
    /// One index a pixel, row-major.
    indices: []u8,

    /// Refuses an image of more than `limit` colors with
    /// `error.Unsupported`, as soon as it meets the one too many.
    fn init(gpa: Allocator, sfc: *const z2d.Surface, limit: u16) EncodeError!Indexed {
        const uw: u32 = @intCast(sfc.getWidth());
        const uh: u32 = @intCast(sfc.getHeight());

        var self: Indexed = .{
            .width = uw,
            .height = uh,
            .palette = undefined,
            .count = 0,
            .indices = try gpa.alloc(u8, @as(usize, uw) * uh),
        };
        errdefer gpa.free(self.indices);

        var seen: std.AutoHashMapUnmanaged(u32, u8) = .empty;
        defer seen.deinit(gpa);
        // One more than the limit: the color that is one too many is
        // inserted before it is refused.
        try seen.ensureTotalCapacity(gpa, @as(u32, limit) + 1);

        const row = try gpa.alloc(Rgba8, uw);
        defer gpa.free(row);

        for (0..uh) |y| {
            pixels.readRow(row, sfc, @intCast(y));
            for (row, 0..) |px, x| {
                const c = flatten(px);
                const key = @as(u32, c.r) << 16 | @as(u32, c.g) << 8 | c.b;
                const got = seen.getOrPutAssumeCapacity(key);
                if (!got.found_existing) {
                    if (self.count == limit) return error.Unsupported;
                    got.value_ptr.* = @intCast(self.count);
                    self.palette[self.count] = c;
                    self.count += 1;
                }
                self.indices[y * uw + x] = got.value_ptr.*;
            }
        }
        return self;
    }

    fn deinit(self: *Indexed, gpa: Allocator) void {
        gpa.free(self.indices);
        self.* = undefined;
    }
};

/// One plane of a row, run-length encoded.
///
/// A byte with its top two bits set is a count, so a literal that happens to
/// look like one has to be written as a run of one --- two bytes to say what
/// would have been one, which is why a PCX of noise is slightly larger than
/// the noise.
fn writeRle(w: *Io.Writer, bytes: []const u8) EncodeError!void {
    var at: usize = 0;
    while (at < bytes.len) {
        const value = bytes[at];
        var run: usize = 1;
        // Sixty-three is as far as six bits of count will reach.
        while (at + run < bytes.len and bytes[at + run] == value and run < 63) run += 1;
        if (run > 1 or value & 0xc0 == 0xc0) {
            try w.writeByte(@intCast(0xc0 | run));
            try w.writeByte(value);
        } else {
            try w.writeByte(value);
        }
        at += run;
    }
}

/// What is behind a transparent pixel in a format with no alpha: white,
/// because that is what a page is. The same answer `netpbm` gives.
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
