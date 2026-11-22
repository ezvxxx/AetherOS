// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Windows and OS/2 bitmaps.
//!
//! BMP is the simplest of the formats here and the least tidy. It is not one
//! format but a small family: a fourteen-byte file header that has not changed
//! since 1990, followed by a device-independent bitmap header that exists in
//! eight sizes, and the size is the only thing that says which one it is.
//! Between them those headers can describe uncompressed pixels at one, four,
//! eight, sixteen, twenty-four or thirty-two bits, two run-length encodings,
//! an indexed palette, and arbitrary bit masks for picking channels out of a
//! sixteen- or thirty-two-bit word. This decoder reads all of that.
//!
//! What it does not read is the two encodings that are not bitmaps at all:
//! `BI_JPEG` and `BI_PNG` wrap a whole JPEG or PNG file inside a BMP, and the
//! OS/2 headers reuse the same two compression numbers for a 1-bit Huffman
//! encoding and a 24-bit run length encoding. Each is refused as
//! `error.Unsupported` rather than guessed at.
//!
//! ## Reading it sans-I/O
//!
//! BMP's one real obstacle for a streaming decoder is that the file header
//! gives the pixel data's position as an absolute offset from the start of the
//! file, and a `*Io.Reader` can neither be asked where it is nor told to go
//! back. `Cursor` below is the answer: it counts what has been taken, so the
//! offset can be honoured by discarding forward to it. An offset that points
//! backwards into bytes already consumed is a malformed file, and is refused
//! as one.
//!
//! ## What comes out
//!
//! Straight-alpha values in the file become premultiplied ones in the surface;
//! `pixels.zig` explains why, and is the only place in this file that writes
//! to a surface. An image whose encoding carries no alpha decodes to
//! `.image_surface_rgb`, one that does to `.image_surface_rgba`, and
//! `DecodeOptions.surface_type` overrides both.

const std = @import("std");
const Io = std.Io;
const math = std.math;
const mem = std.mem;
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

// The two formats a BMP may contain instead of pixels. See `Header.embeds`.
const jpeg = @import("jpeg.zig");
const png = @import("png.zig");

/// `BM`, as the little-endian `u16` the file header's first field is.
const magic: u16 = 0x4d42;

/// The fourteen-byte `BITMAPFILEHEADER`.
const file_header_len = 14;

// -- headers -----------------------------------------------------------------

/// Which DIB header a file carries, named by its length, which is the only
/// thing in the file that distinguishes them.
///
/// The three OS/2 sizes and the five Windows ones are interleaved in value and
/// unrelated in lineage, which is why this is a flat enum rather than anything
/// ordered: `os22x` at 64 bytes is not a later version of `v2` at 52, it is a
/// different vendor's idea.
pub const HeaderVersion = enum(u32) {
    /// `BITMAPCOREHEADER`, OS/2 1.x and Windows 2.0. Sixteen-bit dimensions,
    /// three-byte palette entries, no compression field at all.
    core = 12,
    /// The short `OS22XBITMAPHEADER`, which is the first sixteen bytes of the
    /// full one and nothing else.
    os22x_short = 16,
    /// `BITMAPINFOHEADER`, Windows 3.0 and the one almost every BMP is.
    info = 40,
    /// `BITMAPV2INFOHEADER`: the above plus red, green and blue masks.
    v2 = 52,
    /// `BITMAPV3INFOHEADER`: plus an alpha mask. Undocumented by Microsoft
    /// and written by a great deal of software regardless.
    v3 = 56,
    /// The full `OS22XBITMAPHEADER`. Its first forty bytes match
    /// `BITMAPINFOHEADER`; the rest is OS/2 colour management this decoder
    /// skips.
    os22x = 64,
    /// `BITMAPV4HEADER`: plus a colour space and gamma.
    v4 = 108,
    /// `BITMAPV5HEADER`: plus a rendering intent and an embedded ICC profile.
    v5 = 124,

    /// Whether the header's first forty bytes are `BITMAPINFOHEADER`'s.
    ///
    /// True for everything but the two short ones, which is what lets one
    /// parser read all six.
    fn hasInfoFields(self: HeaderVersion) bool {
        return switch (self) {
            .core, .os22x_short => false,
            else => true,
        };
    }

    /// Whether the compression field means what Windows says it means.
    ///
    /// OS/2 gave 3 and 4 to a 1-bit Huffman encoding and a 24-bit run length
    /// encoding, where Windows has `BI_BITFIELDS` and `BI_JPEG`. The header
    /// length is the only way to tell which document applies.
    fn compressionIsWindows(self: HeaderVersion) bool {
        return switch (self) {
            .os22x_short, .os22x => false,
            else => true,
        };
    }

    /// The size of one palette entry. Only the original OS/2 header uses the
    /// three-byte `RGBTRIPLE`; everything since uses a four-byte `RGBQUAD`
    /// whose fourth byte is reserved.
    fn paletteEntryLen(self: HeaderVersion) u32 {
        return if (self == .core) 3 else 4;
    }
};

/// The `biCompression` field, for the headers where it is Windows'.
pub const Compression = enum(u32) {
    /// Uncompressed, with the channel layout implied by the bit depth.
    rgb = 0,
    /// Run-length encoded, eight bits per pixel and indexed.
    rle8 = 1,
    /// Run-length encoded, four bits per pixel and indexed.
    rle4 = 2,
    /// Uncompressed, with explicit red, green and blue masks.
    bitfields = 3,
    /// A whole JPEG file, embedded. Only ever legal for a printer driver.
    jpeg = 4,
    /// A whole PNG file, embedded. Likewise.
    png = 5,
    /// `BI_BITFIELDS` with a fourth mask for alpha. Windows CE only.
    alpha_bitfields = 6,
    _,
};

/// A channel picked out of a pixel word by a bit mask.
///
/// `BI_BITFIELDS` lets a file put its channels anywhere: the common 16-bit
/// layouts are 5-5-5 and 5-6-5, but the field is a free `u32` and a decoder
/// has to cope with whatever is in it.
const Channel = struct {
    /// How far right to shift the pixel word to bring the channel to zero.
    shift: u5,
    /// The largest value the channel can hold, which is what it is scaled
    /// against on the way to eight bits. Zero means the channel is absent.
    max: u64,

    /// Absent: an image with no alpha mask has no alpha channel.
    const none: Channel = .{ .shift = 0, .max = 0 };

    /// Reads a mask, refusing one that is not a single run of set bits.
    ///
    /// A mask with a hole in it — `0b1011`, say — has no sensible reading:
    /// the channel's value would not be contiguous in the word, and no
    /// encoder writes one. Refusing it here is what stops the scaling
    /// arithmetic below from quietly producing nonsense.
    fn init(mask: u32) error{InvalidData}!Channel {
        if (mask == 0) return .none;
        const shift: u5 = @intCast(@ctz(mask));
        const bits = @popCount(mask);
        const max = (@as(u64, 1) << bits) - 1;
        if (mask >> shift != max) return error.InvalidData;
        return .{ .shift = shift, .max = max };
    }

    /// The channel's value from a pixel word, scaled to eight bits, or
    /// `absent` when the channel is not there.
    ///
    /// The scaling is a rounded proportion rather than a shift, so that a
    /// full five-bit channel comes out 255 and not 248.
    fn extract(self: Channel, word: u32, absent: u8) u8 {
        if (self.max == 0) return absent;
        const raw: u64 = (word >> self.shift) & self.max;
        return @intCast((raw * 255 + self.max / 2) / self.max);
    }
};

/// The four channel masks, already parsed.
const Masks = struct {
    r: Channel,
    g: Channel,
    b: Channel,
    a: Channel,

    /// X1R5G5B5, which is what an uncompressed sixteen-bit BMP means even
    /// though nothing in the file says so.
    const rgb555: Masks = .{
        .r = .{ .shift = 10, .max = 31 },
        .g = .{ .shift = 5, .max = 31 },
        .b = .{ .shift = 0, .max = 31 },
        .a = .none,
    };

    /// The layout of an uncompressed thirty-two-bit BMP: the top byte is
    /// documented as unused, and this decoder treats it as unused unless a
    /// V3-or-later header supplies an alpha mask saying otherwise.
    const xrgb8888: Masks = .{
        .r = .{ .shift = 16, .max = 255 },
        .g = .{ .shift = 8, .max = 255 },
        .b = .{ .shift = 0, .max = 255 },
        .a = .none,
    };

    fn hasAlpha(self: Masks) bool {
        return self.a.max != 0;
    }
};

/// Everything the two headers said, normalised across their versions.
pub const Header = struct {
    version: HeaderVersion,
    width: u32,
    height: u32,
    /// Rows stored bottom to top, which is what a positive height in the file
    /// means and what almost every BMP is. A negative height means top-down.
    bottom_up: bool,
    /// Bits per pixel: 1, 4, 8, 16, 24 or 32.
    bpp: u16,
    compression: Compression,
    /// Palette entries present in the file. Zero for the non-indexed depths.
    palette_len: u32,
    masks: Masks,
    /// `bfOffBits`: where the pixel data begins, counted from the first byte
    /// of the file.
    pixel_offset: u32,

    /// Whether the pixels are palette indices rather than colours.
    pub fn isIndexed(self: Header) bool {
        return !self.embeds() and self.bpp <= 8;
    }

    /// Whether the "pixel data" is a whole file of another format.
    ///
    /// `BI_JPEG` and `BI_PNG` do not describe pixels at all: the bytes at
    /// `pixel_offset` are a complete JPEG or PNG, and everything else the
    /// header says — depth, masks, palette — means nothing. Microsoft added
    /// them so a printer driver could hand a printer an image it already had,
    /// and says plainly that they are not valid for a bitmap in a device
    /// context: they are for spooling rather than displaying. Which is why
    /// almost nothing writes one, and why the depth field is zero.
    pub fn embeds(self: Header) bool {
        if (!self.version.compressionIsWindows()) return false;
        return self.compression == .jpeg or self.compression == .png;
    }

    /// Bytes per row in the file, including the padding that rounds every row
    /// up to a four-byte boundary. Meaningless for the run-length encodings,
    /// which are not row-structured.
    ///
    /// In `u64` because the multiplication is of two attacker-supplied
    /// numbers; the caller has already held the width within `Limits` by the
    /// time this is asked for, but the arithmetic should not depend on that.
    pub fn strideLen(self: Header) u64 {
        return ((@as(u64, self.width) * self.bpp + 31) / 32) * 4;
    }
};

// -- reading -----------------------------------------------------------------

/// A reader that remembers how far into the file it has got.
///
/// BMP puts absolute file offsets in its header and a `*Io.Reader` has no
/// position to ask about, so the position is kept here instead. That is the
/// whole of what makes the format readable from a stream rather than a file.
const Cursor = struct {
    r: *Io.Reader,
    pos: u64,

    fn init(r: *Io.Reader) Cursor {
        return .{ .r = r, .pos = 0 };
    }

    fn int(self: *Cursor, comptime T: type) Io.Reader.Error!T {
        const v = try self.r.takeInt(T, .little);
        self.pos += @divExact(@typeInfo(T).int.bits, 8);
        return v;
    }

    fn slice(self: *Cursor, buf: []u8) Io.Reader.Error!void {
        try self.r.readSliceAll(buf);
        self.pos += buf.len;
    }

    fn skip(self: *Cursor, n: u64) Io.Reader.Error!void {
        try self.r.discardAll64(n);
        self.pos += n;
    }

    /// Discards forward to an absolute offset.
    ///
    /// An offset already behind the cursor is a file whose header contradicts
    /// itself — pixel data inside the palette, or inside the header — and
    /// there is nothing to do with it but refuse it.
    fn seekTo(self: *Cursor, offset: u64) (Io.Reader.Error || error{InvalidData})!void {
        if (offset < self.pos) return error.InvalidData;
        try self.skip(offset - self.pos);
    }
};

/// A BMP part-read: the headers are parsed, the pixels are not.
///
/// Reading it in two steps is what lets a caller find out how big an image is
/// and decide not to decode it. `init` consumes the headers and nothing else;
/// `decode` consumes the palette and the pixels. Nothing is buffered between
/// them but the header fields themselves, so a decoder is cheap to make and
/// cheap to throw away.
pub const Decoder = struct {
    header: Header,
    /// Where `init` left the underlying reader, counted from the start of the
    /// file, so that `decode` can go on honouring `pixel_offset`.
    pos: u64,
    limits: Limits,
    /// Always a full `1 << bpp` entries for the indexed depths, with anything
    /// the file did not supply left opaque black.
    ///
    /// Filling it out rather than bounds-checking each index is deliberate:
    /// indices past the end of a short palette turn up in real files, and a
    /// decoder that refuses them refuses images every other decoder reads.
    /// Being a fixed array rather than an allocation also means the indexed
    /// path allocates nothing but the surface, which is what the sandbox wants
    /// of it.
    palette: [256]Rgba8,

    /// Reads the file header and the DIB header, and nothing beyond them.
    ///
    /// The dimensions are checked against `limits` here, before anything has
    /// been allocated on the strength of them.
    pub fn init(r: *Io.Reader, limits: Limits) DecodeError!Decoder {
        var cur: Cursor = .init(r);

        if (try cur.int(u16) != magic) return error.UnknownFormat;
        // bfSize, which is the file's length as the writer believed it to be.
        // Writers get it wrong often enough — zero, or the pixel data's
        // length, or the truth — that nothing here may depend on it.
        _ = try cur.int(u32);
        _ = try cur.int(u16); // bfReserved1
        _ = try cur.int(u16); // bfReserved2
        const pixel_offset = try cur.int(u32);

        var self: Decoder = .{
            .header = undefined,
            .pos = 0,
            .limits = limits,
            .palette = @splat(.black),
        };
        self.header = try readDibHeader(&cur, pixel_offset, limits);
        self.pos = cur.pos;
        return self;
    }

    /// What the headers said, in the shape every codec here reports it.
    pub fn info(self: Decoder) Info {
        if (self.header.embeds()) {
            // The dimensions are the header's, which is all that can be known
            // without reading into the embedded file — and a stream cannot be
            // rewound, so reading into it here would spend the bytes the
            // embedded decoder needs. `decode` refuses a file whose header
            // disagrees with what it contains, which is what makes these
            // trustworthy rather than merely plausible.
            //
            // `has_alpha` is a property of the encoding rather than of the
            // image, and here of the *embedded* encoding: a PNG may carry an
            // alpha channel and a JPEG never does.
            const has_alpha = self.header.compression == .png;
            return .{
                .format = .bmp,
                .width = self.header.width,
                .height = self.header.height,
                .has_alpha = has_alpha,
                .surface_type = pixels.naturalSurfaceType(has_alpha),
            };
        }
        const has_alpha = self.header.masks.hasAlpha();
        return .{
            .format = .bmp,
            .width = self.header.width,
            .height = self.header.height,
            .has_alpha = has_alpha,
            .surface_type = pixels.naturalSurfaceType(has_alpha),
        };
    }

    /// Reads the palette and the pixel data, producing the surface.
    ///
    /// The caller owns the surface and must `deinit` it with the same
    /// allocator. On any error nothing is returned and nothing is leaked.
    pub fn decode(self: *Decoder, gpa: Allocator, r: *Io.Reader, opts: DecodeOptions) DecodeError!z2d.Surface {
        var cur: Cursor = .{ .r = r, .pos = self.pos };

        if (self.header.embeds()) return self.decodeEmbedded(gpa, &cur, opts);

        try self.readPalette(&cur);

        const surface_type = opts.surface_type orelse self.info().surface_type;
        var sfc: z2d.Surface = z2d.Surface.init(
            surface_type,
            gpa,
            @intCast(self.header.width),
            @intCast(self.header.height),
        ) catch |err| switch (err) {
            // Held within i32 by `Limits.check` long before here, so these
            // cannot happen; mapping them keeps the error set honest rather
            // than asserting about another library's contract.
            error.InvalidWidth, error.InvalidHeight => return error.InvalidData,
            error.OutOfMemory => |e| return e,
        };
        errdefer sfc.deinit(gpa);

        try cur.seekTo(self.header.pixel_offset);

        // One row of decoded colour, reused for every row of the image.
        const row = try gpa.alloc(Rgba8, self.header.width);
        defer gpa.free(row);

        switch (self.header.compression) {
            .rle8, .rle4 => try self.decodeRle(&cur, &sfc, row),
            else => try self.decodeUncompressed(gpa, &cur, &sfc, row),
        }

        return sfc;
    }

    /// Hands the file over to the decoder that can actually read it.
    ///
    /// The caller's options pass through, so an embedded JPEG's orientation
    /// and colour profile come out of a BMP exactly as they would out of the
    /// same JPEG on its own.
    ///
    /// The dimensions are then held to what the BMP header claimed. A header
    /// that disagrees with the file inside it is refused rather than believed,
    /// because `probe` has already answered from that header and the two must
    /// not be able to say different things about one file.
    fn decodeEmbedded(
        self: *Decoder,
        gpa: Allocator,
        cur: *Cursor,
        opts: DecodeOptions,
    ) DecodeError!z2d.Surface {
        try cur.seekTo(self.header.pixel_offset);

        // Nothing recursive can come of this: the only two formats a BMP may
        // embed are the two that cannot embed anything.
        var sfc = switch (self.header.compression) {
            .jpeg => jpeg.decode(gpa, cur.r, opts),
            .png => png.decode(gpa, cur.r, opts),
            else => unreachable,
        } catch |err| switch (err) {
            // The embedded decoder is speaking about its own file, and to it a
            // payload that does not begin with its signature is "not one of my
            // formats". To this caller the stream *is* a format this library
            // recognises --- it is a BMP, and detection said so --- whose
            // contents are broken. Letting `UnknownFormat` out would have
            // `probe` and `decode` disagree about whether the file is an image
            // at all, which is what the fuzzer found within minutes.
            error.UnknownFormat => return error.InvalidData,
            else => |e| return e,
        };
        errdefer sfc.deinit(gpa);

        if (sfc.getWidth() != self.header.width or sfc.getHeight() != self.header.height) {
            return error.InvalidData;
        }
        return sfc;
    }

    /// Reads the palette that sits between the header and the pixel data.
    ///
    /// Entries are stored blue first. The fourth byte of a `RGBQUAD` is
    /// reserved and is *not* an alpha channel however tempting it looks: files
    /// written by tools that thought otherwise exist, and honouring it would
    /// turn every one of their images transparent.
    fn readPalette(self: *Decoder, cur: *Cursor) DecodeError!void {
        if (self.header.palette_len == 0) return;

        const entry_len = self.header.version.paletteEntryLen();
        var buf: [4]u8 = undefined;
        for (self.palette[0..self.header.palette_len]) |*entry| {
            try cur.slice(buf[0..entry_len]);
            entry.* = .rgb(buf[2], buf[1], buf[0]);
        }
    }

    /// The uncompressed encodings: a fixed number of bytes per row, padded up
    /// to a four-byte boundary, rows bottom-to-top unless the height was
    /// negative.
    fn decodeUncompressed(
        self: *Decoder,
        gpa: Allocator,
        cur: *Cursor,
        sfc: *z2d.Surface,
        row: []Rgba8,
    ) DecodeError!void {
        const stride = self.header.strideLen();
        // Bounded by the width limit that has already been applied: at the
        // default 32768 pixels and 32 bits this is 128 KiB. Cast rather than
        // narrowed, because on a 32-bit host a width the limits allowed can
        // still give a stride that does not fit a `usize`.
        const stride_len = math.cast(usize, stride) orelse return error.ImageTooLarge;
        const raw = try gpa.alloc(u8, stride_len);
        defer gpa.free(raw);

        for (0..self.header.height) |i| {
            try cur.slice(raw);
            self.expandRow(raw, row);
            const y: i32 = if (self.header.bottom_up)
                @intCast(self.header.height - 1 - i)
            else
                @intCast(i);
            pixels.writeRow(sfc, y, row);
        }
    }

    /// Turns one row of file bytes into colour.
    ///
    /// Infallible: every index is in range because the palette is always a
    /// full `1 << bpp` entries, and every bit depth here has a total mapping
    /// to `Rgba8`.
    fn expandRow(self: *const Decoder, raw: []const u8, row: []Rgba8) void {
        switch (self.header.bpp) {
            1, 4, 8 => {
                // Indices are packed high-order bits first, which is to say a
                // 4-bit image's first pixel is the *high* nibble of its first
                // byte.
                //
                // The widths here are worth a second look. At one bit a byte
                // holds eight pixels, and eight does not fit the `u3` that a
                // shift of a byte wants -- so the count and the slot stay
                // `usize`, and only the shift, which is at most seven, is
                // narrowed. Narrowing earlier is a panic rather than an error,
                // and a panic in a decoder is a crash in whatever opened the
                // file.
                const per_byte: usize = 8 / self.header.bpp;
                const mask: u8 = @intCast((@as(u16, 1) << @intCast(self.header.bpp)) - 1);
                for (row, 0..) |*px, x| {
                    const byte = raw[x / per_byte];
                    const slot = per_byte - 1 - (x % per_byte);
                    const shift: u3 = @intCast(slot * self.header.bpp);
                    px.* = self.palette[(byte >> shift) & mask];
                }
            },
            16 => for (row, 0..) |*px, x| {
                const word = mem.readInt(u16, raw[x * 2 ..][0..2], .little);
                px.* = self.fromWord(word);
            },
            24 => for (row, 0..) |*px, x| {
                // Always B, G, R in that order, with no mask field to say
                // otherwise: `BI_BITFIELDS` is not legal at this depth.
                px.* = .rgb(raw[x * 3 + 2], raw[x * 3 + 1], raw[x * 3]);
            },
            32 => for (row, 0..) |*px, x| {
                const word = mem.readInt(u32, raw[x * 4 ..][0..4], .little);
                px.* = self.fromWord(word);
            },
            else => unreachable, // `readDibHeader` admits no other depth.
        }
    }

    /// One pixel word through the channel masks.
    fn fromWord(self: *const Decoder, word: u32) Rgba8 {
        const m = self.header.masks;
        return .{
            .r = m.r.extract(word, 0),
            .g = m.g.extract(word, 0),
            .b = m.b.extract(word, 0),
            // No alpha mask means an opaque image, not a transparent one.
            .a = m.a.extract(word, 255),
        };
    }

    /// The two run-length encodings.
    ///
    /// Both are a stream of byte pairs rather than rows: a count and a value
    /// is a run, and a zero count introduces an escape — end of line, end of
    /// bitmap, or a delta that moves the cursor and leaves everything it
    /// skipped as it was. Which is why the surface is painted with the first
    /// palette entry first: what a delta skips is not written by the file, and
    /// Windows leaves it the background colour.
    ///
    /// A stream that stops without its end-of-bitmap escape is accepted, and
    /// what had been decoded by then is kept. Truncated RLE bitmaps are common
    /// and the alternative is throwing away an image that is all there but for
    /// its last two bytes.
    fn decodeRle(self: *Decoder, cur: *Cursor, sfc: *z2d.Surface, row: []Rgba8) DecodeError!void {
        const width = self.header.width;
        const height = self.header.height;

        // The background the file's gaps show through.
        @memset(row, self.palette[0]);
        for (0..height) |y| pixels.writeRow(sfc, @intCast(y), row);

        // `line` counts up from the bottom of the image, the way the file
        // does; `surfaceRow` turns that into a row of the surface.
        var line: u32 = 0;
        var x: u32 = 0;

        while (line < height) {
            const count = cur.int(u8) catch |err| switch (err) {
                error.EndOfStream => break,
                error.ReadFailed => |e| return e,
            };
            const value = cur.int(u8) catch |err| switch (err) {
                error.EndOfStream => break,
                error.ReadFailed => |e| return e,
            };

            if (count > 0) {
                // A run of `count` pixels. Anything past the right edge is
                // dropped rather than refused: encoders round runs up to the
                // padding and files that do are everywhere.
                const n = @min(count, width -| x);
                for (0..n) |i| {
                    row[x + i] = self.palette[self.rleIndex(value, i)];
                }
                x +|= count;
                continue;
            }

            switch (value) {
                // End of line.
                0 => {
                    pixels.writeRow(sfc, self.surfaceRow(line), row);
                    line += 1;
                    x = 0;
                    @memset(row, self.palette[0]);
                },
                // End of bitmap.
                1 => {
                    pixels.writeRow(sfc, self.surfaceRow(line), row);
                    return;
                },
                // Delta: move right and up by the next two bytes, leaving
                // what is passed over as background.
                2 => {
                    const dx = cur.int(u8) catch |err| switch (err) {
                        error.EndOfStream => break,
                        error.ReadFailed => |e| return e,
                    };
                    const dy = cur.int(u8) catch |err| switch (err) {
                        error.EndOfStream => break,
                        error.ReadFailed => |e| return e,
                    };
                    if (dy > 0) {
                        pixels.writeRow(sfc, self.surfaceRow(line), row);
                        @memset(row, self.palette[0]);
                    }
                    x +|= dx;
                    line +|= dy;
                },
                // Absolute mode: `value` literal pixels follow, padded up to
                // an even number of bytes.
                else => {
                    const n: u32 = value;
                    const bytes = self.rleAbsoluteLen(n);
                    var buf: [256]u8 = undefined;
                    try cur.slice(buf[0..bytes]);
                    for (0..n) |i| {
                        if (x + i >= width) break;
                        row[x + i] = self.palette[self.rleAbsoluteIndex(buf[0..bytes], i)];
                    }
                    x +|= n;
                    // The padding byte that rounds an odd length up.
                    if (bytes % 2 == 1) try cur.skip(1);
                },
            }
        }

        // Ran out of input, or off the top of the image, mid-line.
        if (line < height) pixels.writeRow(sfc, self.surfaceRow(line), row);
    }

    /// Where a file line ends up in the surface. RLE bitmaps are always stored
    /// bottom-up; `readDibHeader` refuses a top-down one.
    fn surfaceRow(self: *const Decoder, line: u32) i32 {
        return @intCast(self.header.height - 1 - @min(line, self.header.height - 1));
    }

    /// The palette index of the `i`th pixel of a run.
    ///
    /// RLE8 repeats one index. RLE4 alternates the two nibbles of the byte,
    /// high first, so a run of five from `0x1f` is 1, f, 1, f, 1.
    fn rleIndex(self: *const Decoder, value: u8, i: usize) u8 {
        if (self.header.compression == .rle8) return value;
        return if (i % 2 == 0) value >> 4 else value & 0x0f;
    }

    /// How many bytes `n` literal pixels occupy in absolute mode.
    fn rleAbsoluteLen(self: *const Decoder, n: u32) u32 {
        return if (self.header.compression == .rle8) n else (n + 1) / 2;
    }

    /// The palette index of the `i`th pixel of an absolute run.
    fn rleAbsoluteIndex(self: *const Decoder, buf: []const u8, i: usize) u8 {
        if (self.header.compression == .rle8) return buf[i];
        const byte = buf[i / 2];
        return if (i % 2 == 0) byte >> 4 else byte & 0x0f;
    }
};

/// Reads whichever DIB header this is, having already read the file header.
fn readDibHeader(cur: *Cursor, pixel_offset: u32, limits: Limits) DecodeError!Header {
    const header_len = try cur.int(u32);
    // Written out rather than converted: `std.meta.intToEnum` is gone from
    // Zig, and being explicit puts each length beside the header it names.
    const version: HeaderVersion = switch (header_len) {
        12 => .core,
        16 => .os22x_short,
        40 => .info,
        52 => .v2,
        56 => .v3,
        64 => .os22x,
        108 => .v4,
        124 => .v5,
        else => return error.InvalidData,
    };

    var width: i64 = undefined;
    var height: i64 = undefined;
    var bpp: u16 = undefined;
    var compression: Compression = .rgb;
    var palette_len: u32 = 0;
    var declared_palette: u32 = 0;

    if (version == .core) {
        // Sixteen-bit dimensions, and no compression field: a core-header BMP
        // is always uncompressed.
        width = try cur.int(u16);
        height = try cur.int(u16);
        _ = try cur.int(u16); // planes
        bpp = try cur.int(u16);
    } else {
        width = try cur.int(i32);
        height = try cur.int(i32);
        _ = try cur.int(u16); // planes
        bpp = try cur.int(u16);
        if (version == .os22x_short) {
            // Sixteen bytes and that is all of it: no compression, no palette
            // count, nothing further.
        } else {
            compression = @fromBackingInt(@intCast(try cur.int(u32)));
            _ = try cur.int(u32); // biSizeImage, which writers also get wrong
            _ = try cur.int(i32); // biXPelsPerMeter
            _ = try cur.int(i32); // biYPelsPerMeter
            declared_palette = try cur.int(u32);
            _ = try cur.int(u32); // biClrImportant
        }
    }

    // A negative height means the rows are stored top-down. The sign is the
    // only thing it carries, so the magnitude is taken before anything else
    // looks at it — and `-(-2^31)` does not fit an i32, which is why this
    // arithmetic is in i64.
    const bottom_up = height >= 0;
    const abs_height: u64 = @intCast(@abs(height));
    if (width < 0) return error.InvalidData;
    const abs_width: u64 = @intCast(width);

    // A z2d surface is measured in `i32`, and `-2147483648` is a height a BMP
    // can express whose magnitude is one larger than that. Refusing it here is
    // what keeps every later `@intCast` from being a panic — and a panic in a
    // decoder is a crash in whatever opened the file. The limits below would
    // catch it under any sane budget; this does not depend on the caller
    // having set one.
    if (abs_width > math.maxInt(i32) or abs_height > math.maxInt(i32)) return error.InvalidData;

    try limits.check(abs_width, abs_height);

    // A BMP that is really a JPEG or a PNG describes nothing else about
    // itself. The depth is documented as zero, there is no palette, and the
    // masks mean nothing, so none of the checks below apply to one — the
    // embedded file describes itself and this header's job is finished.
    const embedded = version.compressionIsWindows() and
        (compression == .jpeg or compression == .png);

    if (!embedded) switch (bpp) {
        1, 4, 8, 16, 24, 32 => {},
        else => return error.InvalidData,
    };

    // What the compression field means, and the depth it is legal at. Checked
    // here rather than after the masks have been read, so that a header which
    // contradicts itself is refused for the contradiction rather than for
    // running out of bytes behind it.
    //
    // The two tables are chosen between, never applied in turn: for an OS/2
    // header the Windows meanings do not apply at all, and testing them first
    // makes the OS/2 reading unreachable whenever the Windows one happens to
    // be invalid. A 24-bit OS/2 bitmap with compression 4 is an RLE24 this
    // decoder does not implement, and saying `InvalidData` because 4 is
    // `BI_JPEG` to somebody else would be answering a question nobody asked.
    if (version.compressionIsWindows()) {
        switch (compression) {
            .rgb => {},
            .rle8 => if (bpp != 8) return error.InvalidData,
            .rle4 => if (bpp != 4) return error.InvalidData,
            .bitfields, .alpha_bitfields => switch (bpp) {
                16, 32 => {},
                // `BI_BITFIELDS` has no meaning at any other depth.
                else => return error.InvalidData,
            },
            // A BMP that is really a JPEG or a PNG. Legal, vanishingly rare,
            // and a different decoder's job.
            // A BMP that is really a JPEG or a PNG: another decoder's job,
            // which this library happens to have. Nothing is checked about
            // the depth because nothing is derived from it — the embedded
            // file describes itself.
            .jpeg, .png => {},
            else => return error.InvalidData,
        }
    } else {
        switch (@backingInt(compression)) {
            0 => {}, // BI_RGB means the same in both.
            1 => if (bpp != 8) return error.InvalidData, // RLE8, likewise.
            2 => if (bpp != 4) return error.InvalidData, // RLE4, likewise.
            3 => return error.Unsupported, // OS/2 1-bit Huffman.
            4 => return error.Unsupported, // OS/2 24-bit RLE.
            else => return error.InvalidData,
        }
    }

    // The masks, wherever this header keeps them. `BI_BITFIELDS` in a
    // forty-byte header puts them immediately after it, where a longer header
    // has fields of its own for them.
    var raw_masks: [4]u32 = @splat(0);
    const uses_masks = compression == .bitfields or compression == .alpha_bitfields;
    if (version.hasInfoFields()) {
        const in_header: usize = switch (version) {
            .v2 => 3,
            .v3, .v4, .v5 => 4,
            else => 0,
        };
        for (raw_masks[0..in_header]) |*m| m.* = try cur.int(u32);
        if (in_header == 0 and uses_masks) {
            const trailing: usize = if (compression == .alpha_bitfields) 4 else 3;
            for (raw_masks[0..trailing]) |*m| m.* = try cur.int(u32);
        }
    }

    // Whatever is left of a header longer than the fields read above — a V4 or
    // V5 header's colour space and gamma, or an OS/2 one's colour management.
    //
    // Only ever forward. A forty-byte header with `BI_BITFIELDS` keeps its
    // masks *after* itself, so by this point the cursor is already past the
    // declared header length, and that is correct rather than a contradiction.
    const header_end = file_header_len + @as(u64, header_len);
    if (cur.pos < header_end) try cur.skip(header_end - cur.pos);

    const masks: Masks = masks: {
        if (uses_masks) {
            const m: Masks = .{
                .r = try .init(raw_masks[0]),
                .g = try .init(raw_masks[1]),
                .b = try .init(raw_masks[2]),
                .a = try .init(raw_masks[3]),
            };
            // Channels that overlap describe no pixel anyone could have
            // written, and would decode to a colour that is partly another
            // colour.
            if (raw_masks[0] & raw_masks[1] != 0 or
                raw_masks[0] & raw_masks[2] != 0 or
                raw_masks[0] & raw_masks[3] != 0 or
                raw_masks[1] & raw_masks[2] != 0 or
                raw_masks[1] & raw_masks[3] != 0 or
                raw_masks[2] & raw_masks[3] != 0) return error.InvalidData;
            if (raw_masks[0] | raw_masks[1] | raw_masks[2] == 0) return error.InvalidData;
            break :masks m;
        }
        break :masks switch (bpp) {
            16 => Masks.rgb555,
            32 => m32: {
                // The one place a mask matters outside `BI_BITFIELDS`: a V3 or
                // later header that declares an alpha mask alongside `BI_RGB`
                // means it, and that is how most thirty-two-bit BMPs with
                // transparency are written.
                //
                // Only the one value, though. `BI_RGB` fixes the colour
                // channels at the top three bytes, so the single alpha mask
                // consistent with it is the fourth. Anything else is a header
                // contradicting itself — fuzzing turns up alpha masks sitting
                // on top of green within seconds — and the safe reading is the
                // one the compression field already gave: an opaque image
                // whose top byte is unused. Refusing the file outright would
                // be worse, since the contradiction is in a field that plenty
                // of writers leave full of rubbish.
                var m = Masks.xrgb8888;
                if (version == .v3 or version == .v4 or version == .v5) {
                    if (raw_masks[3] == 0xff000000) m.a = .{ .shift = 24, .max = 255 };
                }
                break :m32 m;
            },
            else => .{ .r = .none, .g = .none, .b = .none, .a = .none },
        };
    };

    if (compression == .rle8 or compression == .rle4) {
        // The run-length encodings walk the image from the bottom up by
        // construction; there is no way to express a top-down one.
        if (!bottom_up) return error.InvalidData;
    }

    // An embedded file has no palette whatever the depth field says, and at a
    // depth of zero the arithmetic below would invent one of a single entry.
    if (!embedded and bpp <= 8) {
        const full: u32 = @as(u32, 1) << @intCast(bpp);
        const wanted: u32 = if (declared_palette == 0) full else declared_palette;
        // A palette longer than the depth can index is a header lying about
        // its own size, and believing it would read the pixel data as colours.
        if (wanted > full) return error.InvalidData;

        // And however many entries the header asks for, only the ones that fit
        // between here and the pixel data are actually in the file.
        //
        // This is not pedantry. A `BITMAPCOREHEADER` has no palette-count
        // field at all, so its palette is *defined* as the full `1 << bpp`
        // entries — yet files exist with `bfOffBits` leaving room for four, and
        // reading 256 from one of them runs off the end of an image that is
        // otherwise perfectly good. The offset is the authority, because it is
        // the thing the pixel data is actually at. Entries the file does not
        // supply stay opaque black.
        const room: u64 = if (pixel_offset > cur.pos)
            (pixel_offset - cur.pos) / version.paletteEntryLen()
        else
            0;
        palette_len = @intCast(@min(wanted, room));
    }

    return .{
        .version = version,
        .width = @intCast(abs_width),
        .height = @intCast(abs_height),
        .bottom_up = bottom_up,
        .bpp = bpp,
        .compression = compression,
        .palette_len = palette_len,
        .masks = masks,
        .pixel_offset = pixel_offset,
    };
}

/// Reads a whole BMP from `r`, producing a surface the caller owns.
pub fn decode(gpa: Allocator, r: *Io.Reader, opts: DecodeOptions) DecodeError!z2d.Surface {
    // BMP carries neither of these as far as this library reads it, and the
    // promise is that a caller who asked is answered rather than left with
    // whatever was there before. `icc` says why a `BITMAPV5HEADER`'s embedded
    // profile is not read.
    if (opts.orientation) |out| out.* = .top_left;
    if (opts.icc) |out| out.clearRetainingCapacity();
    var decoder: Decoder = try .init(r, opts.limits);
    return decoder.decode(gpa, r, opts);
}

/// Reads only as far as the headers, and says what they described.
///
/// This consumes them: a `*Io.Reader` cannot be rewound, so a caller who wants
/// to probe an image and then decode the same stream needs either two readers
/// over the same bytes or a `Decoder`, which keeps what it read.
pub fn probe(r: *Io.Reader, limits: Limits) DecodeError!Info {
    const decoder: Decoder = try .init(r, limits);
    return decoder.info();
}

// -- writing -----------------------------------------------------------------

/// Which end of the image the first row written is.
pub const RowOrder = enum {
    /// Last row first, which is what a BMP has meant since 1990 and what
    /// every reader accepts.
    bottom_up,
    /// First row first, signalled by a negative height. Understood by most
    /// readers, refused by a few old ones, and not legal at all with the
    /// run-length encodings.
    top_down,
};

/// Which pixel format to write.
pub const Depth = enum {
    /// Twenty-four bits when the surface has no alpha channel, thirty-two when
    /// it has. The right answer when the BMP is going to a general-purpose
    /// reader, because it neither loses transparency nor invents it.
    auto,

    /// Always twenty-four-bit `BI_RGB` under a plain `BITMAPINFOHEADER`, with
    /// any transparency composited onto `EncodeOptions.background` first.
    ///
    /// This is the oldest and most universally understood BMP there is: a
    /// fifty-four byte header and three bytes a pixel. Ask for it when the
    /// reader on the other end is fussy — the Elgato Stream Deck Original and
    /// Mini take exactly this shape and nothing else, and they are not the
    /// only firmware that parses a fixed header rather than a format.
    rgb24,

    /// Always thirty-two-bit `BI_BITFIELDS` under a `BITMAPV4HEADER`. A
    /// surface with no alpha channel is written fully opaque.
    rgba32,
};

/// How to write a BMP.
pub const EncodeOptions = struct {
    row_order: RowOrder = .bottom_up,

    /// The pixel format to write. The default follows the surface.
    depth: Depth = .auto,

    /// The colour that transparency is composited onto when the depth being
    /// written has no alpha channel to keep it in. Its own alpha is ignored.
    ///
    /// Compositing rather than discarding, because discarding is almost never
    /// what anyone means: a red at a tenth opacity has colour channels saying
    /// "red", and dropping the alpha turns a faint tint into a solid block.
    /// The default is black, which for a surface holding premultiplied alpha
    /// is exactly the value already stored — so the common case costs nothing
    /// and loses nothing.
    background: Rgba8 = .black,
};

/// `LCS_sRGB`: the colour space field of a V4 header, spelled `sRGB` and read
/// as a big-endian word, which is how the constant is defined.
const lcs_srgb: u32 = 0x73524742;

/// 72 dots per inch in the units the header actually uses, which are dots per
/// metre. Nothing in a z2d surface records a physical size, so a plausible
/// default is written rather than a zero that some readers divide by.
const pixels_per_metre: i32 = 2835;

/// Writes `sfc` as a BMP.
///
/// The encoding is chosen from the surface's pixel format, which is the only
/// thing that says whether the image has transparency to keep:
///
///   * A surface with an alpha channel — `argb`, `rgba`, or any of the
///     alpha-only formats — is written as thirty-two-bit `BI_BITFIELDS` under
///     a `BITMAPV4HEADER`, with the alpha mask that makes the channel mean
///     something. A bare `BITMAPINFOHEADER` has nowhere to say that the top
///     byte is alpha, and readers given one are entitled to ignore it.
///   * A surface without one is written as twenty-four-bit `BI_RGB` under a
///     `BITMAPINFOHEADER`, which is the most widely readable BMP there is.
///
/// The alpha written out is straight alpha, demultiplied from what the surface
/// holds. That conversion loses a little precision in the dark end of a
/// semi-transparent image; `pixels.Rgba8.fromZ2d` says why, and it is the
/// reason a decode-then-encode round trip is not promised to be byte-exact.
///
/// Nothing here allocates: one row is held on the stack at a time and written
/// as it is converted, so the memory cost is independent of the image.
pub fn encode(sfc: *const z2d.Surface, w: *Io.Writer, opts: EncodeOptions) EncodeError!void {
    const width = sfc.getWidth();
    const height = sfc.getHeight();
    if (width < 1 or height < 1) return error.Unsupported;
    // A BMP's dimensions are signed thirty-two-bit, and a top-down image
    // negates the height, so the largest expressible height is one short of
    // what a z2d surface could in principle hold.
    if (height == math.minInt(i32)) return error.Unsupported;

    const surface_has_alpha = switch (sfc.getFormat()) {
        .argb, .rgba, .alpha8, .alpha4, .alpha2, .alpha1 => true,
        .xrgb, .rgb => false,
    };
    const has_alpha = switch (opts.depth) {
        .auto => surface_has_alpha,
        .rgb24 => false,
        .rgba32 => true,
    };
    // Transparency that the file has nowhere to put has to go somewhere, and
    // the background is where. Only reached when the surface had an alpha
    // channel and the depth being written has none.
    const flatten = surface_has_alpha and !has_alpha;

    const bpp: u16 = if (has_alpha) 32 else 24;
    const header_len: u32 = if (has_alpha) 108 else 40;

    // All of this in `u64` until it is known to fit. A surface may legitimately
    // be wider than a BMP row length can express, and working that out by
    // overflowing a `u32` would be a panic where it should be an error.
    const stride_64 = ((@as(u64, @intCast(width)) * bpp + 31) / 32) * 4;
    const image_len = stride_64 * @as(u64, @intCast(height));
    const total = file_header_len + @as(u64, header_len) + image_len;
    // Every size in a BMP header is a `u32`. An image too big to describe is
    // refused rather than described wrongly.
    if (total > math.maxInt(u32)) return error.Unsupported;
    // Safe now: the stride is one part of a total that fits.
    const stride: u32 = @intCast(stride_64);

    try w.writeInt(u16, magic, .little);
    try w.writeInt(u32, @intCast(total), .little);
    try w.writeInt(u16, 0, .little); // bfReserved1
    try w.writeInt(u16, 0, .little); // bfReserved2
    try w.writeInt(u32, file_header_len + header_len, .little);

    try w.writeInt(u32, header_len, .little);
    try w.writeInt(i32, width, .little);
    try w.writeInt(i32, switch (opts.row_order) {
        .bottom_up => height,
        .top_down => -height,
    }, .little);
    try w.writeInt(u16, 1, .little); // biPlanes
    try w.writeInt(u16, bpp, .little);
    try w.writeInt(u32, if (has_alpha) @backingInt(Compression.bitfields) else @backingInt(Compression.rgb), .little);
    try w.writeInt(u32, @intCast(image_len), .little);
    try w.writeInt(i32, pixels_per_metre, .little);
    try w.writeInt(i32, pixels_per_metre, .little);
    try w.writeInt(u32, 0, .little); // biClrUsed
    try w.writeInt(u32, 0, .little); // biClrImportant

    if (has_alpha) {
        try w.writeInt(u32, 0x00ff0000, .little); // red
        try w.writeInt(u32, 0x0000ff00, .little); // green
        try w.writeInt(u32, 0x000000ff, .little); // blue
        try w.writeInt(u32, 0xff000000, .little); // alpha
        try w.writeInt(u32, lcs_srgb, .little);
        // The endpoints and the three gamma values, which `LCS_sRGB` makes
        // meaningless: the colour space is named, so the numbers describing
        // an unnamed one are ignored.
        try w.splatByteAll(0, 36 + 12);
    }

    // One row at a time, converted and written. The surface is walked in the
    // order the file wants it, so `bottom_up` reads upwards.
    var buf: [64]Rgba8 = undefined;
    var y: i32 = 0;
    while (y < height) : (y += 1) {
        const src_y: i32 = switch (opts.row_order) {
            .bottom_up => height - 1 - y,
            .top_down => y,
        };
        var x: i32 = 0;
        while (x < width) {
            const n: usize = @intCast(@min(@as(i64, buf.len), @as(i64, width) - x));
            pixels.readSegment(buf[0..n], sfc, x, src_y);
            for (buf[0..n]) |px| {
                // Blue, green, red: the order a BMP has always stored, and
                // the order the masks above describe.
                if (has_alpha) {
                    try w.writeAll(&[_]u8{ px.b, px.g, px.r, px.a });
                } else {
                    const c = if (flatten) over(px, opts.background) else px;
                    try w.writeAll(&[_]u8{ c.b, c.g, c.r });
                }
            }
            x += @intCast(n);
        }
        // The padding that rounds a twenty-four-bit row up to four bytes.
        // Thirty-two-bit rows are aligned already.
        const written: u32 = @intCast(@as(u64, @intCast(width)) * (bpp / 8));
        try w.splatByteAll(0, stride - written);
    }
}

/// `src` composited over an opaque `bg`, the ordinary source-over of a
/// straight-alpha colour onto a background.
///
/// Rounded rather than truncated, so that a fully opaque source comes back
/// exactly itself and a fully transparent one comes back exactly the
/// background — the two cases anyone will check by eye.
fn over(src: Rgba8, bg: Rgba8) Rgba8 {
    if (src.a == 255) return .rgb(src.r, src.g, src.b);
    if (src.a == 0) return .rgb(bg.r, bg.g, bg.b);
    const a: u32 = src.a;
    const blend = struct {
        fn f(s: u8, b: u8, alpha: u32) u8 {
            const num = @as(u32, s) * alpha + @as(u32, b) * (255 - alpha);
            return @intCast((num + 127) / 255);
        }
    }.f;
    return .rgb(
        blend(src.r, bg.r, a),
        blend(src.g, bg.g, a),
        blend(src.b, bg.b, a),
    );
}
