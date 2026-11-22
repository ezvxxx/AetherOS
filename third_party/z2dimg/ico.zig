// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! ICO and CUR: Windows icons and cursors, which are containers rather than
//! images.
//!
//! A six-byte directory header, then one sixteen-byte entry per image, then
//! the images. The entries are *alternatives* --- the same icon at several
//! sizes and depths, for a system to pick from --- which is why `decode` has
//! to choose one and says which it chose. It takes the largest, breaking ties
//! on depth, because that is what a caller asking for "the icon" means.
//! `Decoder` hands over the directory for a caller who wants a particular
//! one.
//!
//! ## What is inside an entry
//!
//! One of two things, told apart by looking.
//!
//! A **PNG**, complete with its signature, which Windows Vista introduced for
//! the large sizes. Pillow writes these even at sixteen by sixteen.
//!
//! Or a **DIB** --- a BMP from the `BITMAPINFOHEADER` onwards, with no
//! `BITMAPFILEHEADER` in front of it, since the directory entry already said
//! where the image is and how long. Two things about it are traps.
//!
//! ## The doubled height
//!
//! The DIB's height is **twice** the icon's, because the pixels are followed
//! by an AND mask: one bit a pixel saying which are transparent, from the days
//! before an alpha channel. Handing that header to a bitmap decoder unaltered
//! asks it to read the mask as more rows of colour, which it cannot, because
//! the mask is one bit a pixel and the colour is not.
//!
//! ## The alpha that a BMP does not have
//!
//! A thirty-two-bit DIB in an icon carries alpha in its top byte. A
//! thirty-two-bit BMP with a forty-byte header does not: the format says
//! those eight bits are unused, and this library's BMP decoder reads them
//! that way, correctly. The two disagree because the icon convention was
//! never written into the bitmap one.
//!
//! So the header is rewritten rather than reinterpreted. A forty-byte header
//! at thirty-two bits becomes the fifty-six-byte `BITMAPV3INFOHEADER` that
//! says what the icon means --- the same fields, plus the four channel masks,
//! with alpha at the top byte --- and the pixel data is untouched. Everything
//! else about the DIB, which is to say eight header versions, every depth,
//! the palettes, the bitfields and both run-length encodings, is the bitmap
//! decoder's and is not written again here.

const std = @import("std");
const Io = std.Io;
const mem = std.mem;
const math = std.math;
const testing = std.testing;
const Allocator = mem.Allocator;

const z2d = @import("z2d");

const bmp = @import("bmp.zig");
const common = @import("common.zig");
const DecodeError = common.DecodeError;
const DecodeOptions = common.DecodeOptions;
const EncodeError = common.EncodeError;
const Info = common.Info;
const Limits = common.Limits;
const pixels = @import("pixels.zig");
const png = @import("png.zig");
const Rgba8 = pixels.Rgba8;

/// Which of the two the file is. They differ only in this field and in what
/// two bytes of each entry mean.
pub const Kind = enum(u16) {
    icon = 1,
    cursor = 2,
};

/// One line of the directory: where an image is, and what it claims to be.
pub const Entry = struct {
    /// The size the *directory* claims. Zero in the file means 256, since the
    /// field is one byte and 256 is a size Windows wanted after the format
    /// was fixed.
    width: u32,
    height: u32,
    /// Palette entries, or zero for an image with more than 255 colours.
    colours: u8,
    /// Colour planes and bits per pixel for an icon; the hotspot for a
    /// cursor. The same two fields, read either way.
    planes: u16,
    bits: u16,
    /// How long the image is, and where it starts from the beginning of the
    /// file.
    len: u32,
    offset: u32,

    /// How good an image this is, for choosing between them: pixels first,
    /// then depth.
    fn rank(self: Entry) u64 {
        return (@as(u64, self.width) * self.height) << 16 | self.bits;
    }

    /// That the image really is the size the directory said it was.
    ///
    /// They are written by the same encoder out of the same surface, so in
    /// any real icon they agree --- but the entry is all `probe` can see and
    /// the image is what `decode` returns, and a file where the two differ
    /// would have one of this library's entry points contradicting the other.
    /// It is rejected rather than picked between, and rejected *before* the
    /// image is decoded, so that a directory promising something small cannot
    /// be a way to ask for something large.
    ///
    /// The one shape this refuses that a renderer might not: an image bigger
    /// than 256, which the entry's one-byte fields cannot describe and which
    /// therefore cannot agree with anything.
    fn agreesWith(self: Entry, width: u64, height: u64) error{InvalidData}!void {
        if (width != self.width or height != self.height) return error.InvalidData;
    }
};

/// The largest an entry may claim to be, which is what one byte can say once
/// zero has been spent on 256.
pub const max_side = 256;

/// Whether a directory header is one at all: two bytes of reserved zero, a
/// type that is one of two values, and a count that is not zero.
fn headerIsSane(head: *const [6]u8) bool {
    if (mem.readInt(u16, head[0..2], .little) != 0) return false;
    switch (mem.readInt(u16, head[2..4], .little)) {
        1, 2 => {},
        else => return false,
    }
    return mem.readInt(u16, head[4..6], .little) != 0;
}

/// Whether a window begins an icon file.
///
/// The six-byte header is not enough on its own, and finding that out is what
/// this check is shaped by. **A TGA has the same first four bytes**: one with
/// no identification field and no colour map begins with two zeroes, and its
/// image type of one or two then sits exactly where an icon's type does. The
/// two formats collide in the only bytes either of them offers as a
/// signature.
///
/// So the first *entry* is read as well. Its reserved byte has to be zero,
/// its image cannot be empty, and the image cannot begin inside the directory
/// that points at it --- three more constraints, on fields a TGA is using for
/// its colour map and its dimensions, which is what separates the two.
///
/// The cost is that an icon is not recognised from fewer than twenty-two
/// bytes. That is no loss: a directory declaring an image and not having room
/// for the entry describing it is not a file anything could read.
pub fn looksLikeHeader(bytes: []const u8) bool {
    if (bytes.len < 22) return false;
    if (!headerIsSane(bytes[0..6])) return false;
    const count = mem.readInt(u16, bytes[4..6], .little);

    // The first entry. Its fourth byte is reserved and every writer leaves it
    // zero.
    if (bytes[9] != 0) return false;
    if (mem.readInt(u32, bytes[14..18], .little) == 0) return false;
    const offset = mem.readInt(u32, bytes[18..22], .little);
    const directory_end = 6 + @as(u32, count) * 16;
    return offset >= directory_end;
}

pub const Decoder = struct {
    kind: Kind,
    /// The directory, in the order the file gave it.
    entries: []Entry,
    limits: Limits,
    /// How far into the file the reader has got, so that an entry can be
    /// skipped to. A `*Io.Reader` cannot be rewound, so an entry that lies
    /// behind this one is out of reach.
    pos: u32,

    pub fn init(gpa: Allocator, r: *Io.Reader, limits: Limits) DecodeError!Decoder {
        var head: [6]u8 = undefined;
        r.readSliceAll(&head) catch |err| switch (err) {
            error.EndOfStream => return error.UnknownFormat,
            error.ReadFailed => |e| return e,
        };
        if (!headerIsSane(&head)) return error.UnknownFormat;

        const kind: Kind = @fromBackingInt(@intCast(mem.readInt(u16, head[2..4], .little)));
        const count = mem.readInt(u16, head[4..6], .little);

        const entries = try gpa.alloc(Entry, count);
        errdefer gpa.free(entries);

        for (entries) |*entry| {
            var buf: [16]u8 = undefined;
            r.readSliceAll(&buf) catch |err| switch (err) {
                error.EndOfStream => return error.InvalidData,
                error.ReadFailed => |e| return e,
            };
            entry.* = .{
                // Zero means 256. The field is a byte and the format wanted a
                // size that does not fit one.
                .width = if (buf[0] == 0) max_side else buf[0],
                .height = if (buf[1] == 0) max_side else buf[1],
                .colours = buf[2],
                .planes = mem.readInt(u16, buf[4..6], .little),
                .bits = mem.readInt(u16, buf[6..8], .little),
                .len = mem.readInt(u32, buf[8..12], .little),
                .offset = mem.readInt(u32, buf[12..16], .little),
            };
        }

        return .{
            .kind = kind,
            .entries = entries,
            .limits = limits,
            .pos = 6 + @as(u32, count) * 16,
        };
    }

    pub fn deinit(self: *Decoder, gpa: Allocator) void {
        gpa.free(self.entries);
        self.* = undefined;
    }

    /// Which entry `decode` would read: the largest, then the deepest.
    ///
    /// A directory is conventionally ordered smallest first, so taking the
    /// first would usually hand back a sixteen by sixteen --- rarely what
    /// anyone wanted from a bare `decode`.
    pub fn best(self: Decoder) usize {
        var at: usize = 0;
        for (self.entries, 0..) |entry, i| {
            if (entry.rank() > self.entries[at].rank()) at = i;
        }
        return at;
    }

    pub fn info(self: Decoder) Info {
        const entry = self.entries[self.best()];
        return .{
            .format = .ico,
            .width = entry.width,
            .height = entry.height,
            // Both shapes an entry may hold can carry transparency: a DIB has
            // its AND mask whatever its depth, and a PNG has whatever it has.
            .has_alpha = true,
            .surface_type = pixels.naturalSurfaceType(true),
        };
    }

    /// Reads one entry.
    ///
    /// The stream only goes forwards, so entries have to be read in the order
    /// they sit in the file. One that lies behind what has already been read
    /// is `error.Unsupported` rather than a wrong answer.
    pub fn decodeEntry(
        self: *Decoder,
        gpa: Allocator,
        r: *Io.Reader,
        index: usize,
        opts: DecodeOptions,
    ) DecodeError!z2d.Surface {
        if (index >= self.entries.len) return error.InvalidData;
        const entry = self.entries[index];
        if (entry.offset < self.pos) return error.Unsupported;
        if (entry.len == 0) return error.InvalidData;
        if (entry.len > self.limits.max_input_bytes) return error.ImageTooLarge;

        try r.discardAll(entry.offset - self.pos);
        self.pos = entry.offset;

        const bytes = try gpa.alloc(u8, entry.len);
        defer gpa.free(bytes);
        r.readSliceAll(bytes) catch |err| switch (err) {
            error.EndOfStream => return error.InvalidData,
            error.ReadFailed => |e| return e,
        };
        self.pos += entry.len;

        // A PNG says so itself. Everything else is a headerless DIB.
        if (bytes.len >= 8 and mem.eql(u8, bytes[0..8], "\x89PNG\r\n\x1a\n")) {
            // The `IHDR` is fixed in place at the front of every PNG, so the
            // size can be had without decoding anything.
            if (bytes.len >= 24 and mem.eql(u8, bytes[12..16], "IHDR")) {
                try entry.agreesWith(
                    mem.readInt(u32, bytes[16..20], .big),
                    mem.readInt(u32, bytes[20..24], .big),
                );
            }
            var inner: Io.Reader = .fixed(bytes);
            return png.decode(gpa, &inner, opts);
        }
        return self.decodeDib(gpa, bytes, entry, opts);
    }

    /// An entry's DIB, by way of the bitmap decoder.
    fn decodeDib(
        self: *Decoder,
        gpa: Allocator,
        bytes: []const u8,
        entry: Entry,
        opts: DecodeOptions,
    ) DecodeError!z2d.Surface {
        const shape = try Dib.parse(bytes);
        try entry.agreesWith(shape.width, shape.height);

        const rebuilt = try shape.rebuild(gpa, bytes);
        defer gpa.free(rebuilt);

        var inner: Io.Reader = .fixed(rebuilt);
        var sfc = try bmp.decode(gpa, &inner, .{
            .limits = self.limits,
            // A surface that can hold transparency, whatever the DIB's own
            // depth would have chosen. A four-bit bitmap has no alpha and the
            // bitmap decoder rightly gives back a surface with nowhere to put
            // any --- but an icon's transparency is in the AND mask, which is
            // applied after, and would have had nowhere to go. `info` already
            // promises an alpha channel for exactly this reason.
            .surface_type = opts.surface_type orelse pixels.naturalSurfaceType(true),
        });
        errdefer sfc.deinit(gpa);

        try shape.applyMask(&sfc, bytes);
        return sfc;
    }
};

/// What an entry's DIB header says, and what has to be done about it.
const Dib = struct {
    header_len: u32,
    width: u32,
    /// The icon's height, which is half what the header says.
    height: u32,
    bottom_up: bool,
    bits: u16,
    compression: u32,
    /// Where the pixels start within the entry.
    pixel_offset: u32,
    /// Whether the header has to become a `BITMAPV3INFOHEADER` for its alpha
    /// to be read.
    upgrade: bool,

    const file_header_len = 14;
    const v3_len = 56;

    fn parse(bytes: []const u8) DecodeError!Dib {
        if (bytes.len < 16) return error.InvalidData;
        const header_len = mem.readInt(u32, bytes[0..4], .little);
        if (header_len < 12 or header_len > bytes.len) return error.InvalidData;

        var width: i64 = undefined;
        var doubled: i64 = undefined;
        var bits: u16 = undefined;
        var compression: u32 = 0;
        var clr_used: u32 = 0;

        if (header_len == 12) {
            // `BITMAPCOREHEADER`: sixteen-bit dimensions and no compression.
            width = mem.readInt(u16, bytes[4..6], .little);
            doubled = mem.readInt(u16, bytes[6..8], .little);
            bits = mem.readInt(u16, bytes[10..12], .little);
        } else {
            if (bytes.len < 40) return error.InvalidData;
            width = mem.readInt(i32, bytes[4..8], .little);
            doubled = mem.readInt(i32, bytes[8..12], .little);
            bits = mem.readInt(u16, bytes[14..16], .little);
            compression = mem.readInt(u32, bytes[16..20], .little);
            clr_used = mem.readInt(u32, bytes[32..36], .little);
        }

        const bottom_up = doubled >= 0;
        const abs = @abs(doubled);
        // The AND mask doubles it, so an odd height is a file that does not
        // describe a mask it must have.
        if (abs == 0 or abs % 2 != 0) return error.InvalidData;
        if (width <= 0) return error.InvalidData;

        const height: u32 = @intCast(abs / 2);
        const uw: u32 = @intCast(width);

        // Where the pixels are, which an embedded DIB does not say: they
        // follow the header, whatever masks sit behind it, and the palette.
        // A standalone BMP has a field for this and an entry has nowhere to
        // put one.
        const masks_len: u32 = if (header_len == 40 and compression == 3) 12 else 0;
        const entry_len: u32 = if (header_len == 12) 3 else 4;
        const palette_entries: u32 = if (clr_used != 0)
            clr_used
        else if (bits <= 8)
            @as(u32, 1) << @intCast(bits)
        else
            0;
        const palette_len = math.mul(u32, palette_entries, entry_len) catch
            return error.InvalidData;

        const upgrade = bits == 32 and header_len == 40 and compression == 0;
        const emitted_header: u32 = if (upgrade) v3_len else header_len;
        const pixel_offset = file_header_len + emitted_header + masks_len + palette_len;

        return .{
            .header_len = header_len,
            .width = uw,
            .height = height,
            .bottom_up = bottom_up,
            .bits = bits,
            .compression = compression,
            .pixel_offset = pixel_offset,
            .upgrade = upgrade,
        };
    }

    /// The entry, as a standalone bitmap: a file header in front, the height
    /// halved, and a thirty-two-bit header upgraded so its alpha is read.
    fn rebuild(self: Dib, gpa: Allocator, bytes: []const u8) DecodeError![]u8 {
        const emitted_header: u32 = if (self.upgrade) v3_len else self.header_len;
        const tail = bytes[self.header_len..];
        const total = math.add(usize, file_header_len + emitted_header, tail.len) catch
            return error.InvalidData;

        const out = try gpa.alloc(u8, total);
        errdefer gpa.free(out);

        out[0] = 'B';
        out[1] = 'M';
        mem.writeInt(u32, out[2..6], @intCast(total), .little);
        mem.writeInt(u16, out[6..8], 0, .little);
        mem.writeInt(u16, out[8..10], 0, .little);
        mem.writeInt(u32, out[10..14], self.pixel_offset, .little);

        const header = out[file_header_len..][0..emitted_header];
        if (self.upgrade) {
            // The same forty bytes, then the four channel masks a V3 header
            // carries. `BI_RGB` fixes the colours at the top three bytes, so
            // the only alpha mask consistent with it is the fourth --- which
            // is exactly what an icon means by its top byte.
            @memcpy(header[0..40], bytes[0..40]);
            mem.writeInt(u32, header[0..4], v3_len, .little);
            mem.writeInt(u32, header[40..44], 0x00ff0000, .little); // red
            mem.writeInt(u32, header[44..48], 0x0000ff00, .little); // green
            mem.writeInt(u32, header[48..52], 0x000000ff, .little); // blue
            mem.writeInt(u32, header[52..56], 0xff000000, .little); // alpha
        } else {
            @memcpy(header, bytes[0..self.header_len]);
        }

        // The height, halved: what the header says includes the mask and what
        // the pixels are is the icon.
        const signed: i32 = if (self.bottom_up)
            @intCast(self.height)
        else
            -@as(i32, @intCast(self.height));
        if (self.header_len == 12) {
            mem.writeInt(u16, header[6..8], @intCast(self.height), .little);
        } else {
            mem.writeInt(i32, header[8..12], signed, .little);
        }

        @memcpy(out[file_header_len + emitted_header ..], tail);
        return out;
    }

    /// The AND mask: one bit a pixel, set where the icon is transparent.
    ///
    /// It is how an icon was transparent before there was an alpha channel,
    /// and it is still there in every DIB entry whatever the depth. At
    /// thirty-two bits the alpha channel is the better answer and this only
    /// steps in when that channel says nothing at all --- which is the same
    /// judgement TGA's unused alpha byte needs, and is wrong in the same rare
    /// direction.
    fn applyMask(self: Dib, sfc: *z2d.Surface, bytes: []const u8) DecodeError!void {
        // Only the uncompressed forms have a mask where arithmetic can find
        // it. A run-length encoded icon is vanishingly rare and its mask is
        // not worth guessing at.
        if (self.compression != 0 and self.compression != 3) return;

        const xor_stride = (@as(u64, self.width) * self.bits + 31) / 32 * 4;
        const xor_len = xor_stride * self.height;
        const mask_stride = (@as(u64, self.width) + 31) / 32 * 4;
        const mask_len = mask_stride * self.height;

        const pixels_at = self.pixel_offset - file_header_len -
            (if (self.upgrade) v3_len - self.header_len else 0);
        const mask_at = @as(u64, pixels_at) + xor_len;
        if (mask_at + mask_len > bytes.len) return; // no mask; nothing to do
        const mask = bytes[@intCast(mask_at)..][0..@intCast(mask_len)];

        if (self.bits == 32 and !allTransparent(sfc)) {
            // The alpha channel said something, and it is the better answer.
            return;
        }

        for (0..self.height) |y| {
            // The mask is stored the way the pixels are: bottom row first for
            // a bottom-up bitmap, which is nearly all of them.
            const source_row = if (self.bottom_up) self.height - 1 - y else y;
            const line = mask[@intCast(source_row * mask_stride)..];
            for (0..self.width) |x| {
                const byte = line[x / 8];
                if ((byte >> @intCast(7 - (x % 8))) & 1 == 0) continue;
                pixels.writePixel(sfc, @intCast(x), @intCast(y), .{
                    .r = 0,
                    .g = 0,
                    .b = 0,
                    .a = 0,
                });
            }
        }
    }
};

/// Whether every pixel is fully transparent, which is what a thirty-two-bit
/// icon looks like when its writer left the alpha channel blank.
fn allTransparent(sfc: *const z2d.Surface) bool {
    var y: i32 = 0;
    while (y < sfc.getHeight()) : (y += 1) {
        var x: i32 = 0;
        while (x < sfc.getWidth()) : (x += 1) {
            const px = Rgba8.fromZ2d(sfc.getPixel(x, y).?);
            if (px.a != 0) return false;
        }
    }
    return true;
}

/// Reads the largest image in an icon file.
pub fn decode(gpa: Allocator, r: *Io.Reader, opts: DecodeOptions) DecodeError!z2d.Surface {
    if (opts.orientation) |out| out.* = .top_left;
    if (opts.icc) |out| out.clearRetainingCapacity();
    var decoder: Decoder = try .init(gpa, r, opts.limits);
    defer decoder.deinit(gpa);
    return decoder.decodeEntry(gpa, r, decoder.best(), opts);
}

/// Reads the directory, and says what the largest entry claims.
pub fn probe(r: *Io.Reader, limits: Limits) DecodeError!Info {
    var head: [6]u8 = undefined;
    r.readSliceAll(&head) catch |err| switch (err) {
        error.EndOfStream => return error.UnknownFormat,
        error.ReadFailed => |e| return e,
    };
    if (!headerIsSane(&head)) return error.UnknownFormat;
    const count = mem.readInt(u16, head[4..6], .little);

    // The largest entry has to be found before anything can be said, and a
    // directory is not ordered by size --- but nothing has to be *kept* while
    // looking for it beyond the best one seen so far. So the whole directory
    // is read and none of it is stored, which is how `probe` reports on the
    // same entry `decode` will read while still allocating nothing.
    var best: Entry = undefined;
    for (0..count) |i| {
        var e: [16]u8 = undefined;
        r.readSliceAll(&e) catch |err| switch (err) {
            error.EndOfStream => return error.InvalidData,
            error.ReadFailed => |err2| return err2,
        };
        const entry: Entry = .{
            .width = if (e[0] == 0) max_side else e[0],
            .height = if (e[1] == 0) max_side else e[1],
            .colours = e[2],
            .planes = mem.readInt(u16, e[4..6], .little),
            .bits = mem.readInt(u16, e[6..8], .little),
            .len = mem.readInt(u32, e[8..12], .little),
            .offset = mem.readInt(u32, e[12..16], .little),
        };
        if (i == 0 or entry.rank() > best.rank()) best = entry;
    }

    try limits.check(best.width, best.height);
    // The same refusal `decodeEntry` makes, made here as well: an entry
    // declaring more bytes than a caller is willing to read is a file this
    // library will not decode, and a probe that answered otherwise would be
    // promising a decode that cannot happen.
    if (best.len > limits.max_input_bytes) return error.ImageTooLarge;
    return .{
        .format = .ico,
        .width = best.width,
        .height = best.height,
        .has_alpha = true,
        .surface_type = pixels.naturalSurfaceType(true),
    };
}

// -- writing -----------------------------------------------------------------

/// How to write an icon.
pub const EncodeOptions = struct {
    /// An icon or a cursor. The two differ in one field of the header and in
    /// what two bytes of each entry mean; a cursor's hotspot is written as
    /// the top left corner, there being nothing better to say.
    kind: Kind = .icon,

    /// The size at which an image goes in as a PNG rather than a DIB.
    ///
    /// Two hundred and fifty-six, which is where Windows itself draws the
    /// line and where it has to be drawn: the directory records each side in
    /// a single byte, and the DIB form has no way to be larger than the one
    /// value that byte cannot hold. A caller wanting the older readers to
    /// cope can raise it and lose the large sizes, or lower it and gain
    /// compression.
    png_from: u32 = 256,
};

/// Builds an icon out of several images.
///
/// **Everything is held until `finish`.** The directory comes first and
/// carries each image's length and offset, and neither is known until the
/// image has been encoded --- so a writer that only goes forwards has to have
/// them all before it writes the first byte. An icon is small and this is the
/// only arrangement that works; a caller writing one image can use `encode`
/// and not think about it.
pub const Encoder = struct {
    opts: EncodeOptions,
    built: std.ArrayList(Built),

    const Built = struct {
        width: u32,
        height: u32,
        bits: u16,
        bytes: []u8,
    };

    pub fn init(opts: EncodeOptions) Encoder {
        return .{ .opts = opts, .built = .empty };
    }

    pub fn deinit(self: *Encoder, gpa: Allocator) void {
        for (self.built.items) |item| gpa.free(item.bytes);
        self.built.deinit(gpa);
        self.* = undefined;
    }

    /// Adds one image. Order is kept, and nothing is written yet.
    pub fn image(self: *Encoder, gpa: Allocator, sfc: *const z2d.Surface) EncodeError!void {
        const width = sfc.getWidth();
        const height = sfc.getHeight();
        if (width < 1 or height < 1) return error.Unsupported;
        // The directory has one byte a side, with zero meaning the largest.
        // There is nowhere to record anything bigger.
        if (width > max_side or height > max_side) return error.Unsupported;
        if (self.built.items.len >= math.maxInt(u16)) return error.Unsupported;

        const uw: u32 = @intCast(width);
        const uh: u32 = @intCast(height);

        var bytes: std.ArrayList(u8) = .empty;
        errdefer bytes.deinit(gpa);
        var out: Io.Writer.Allocating = .fromArrayList(gpa, &bytes);
        errdefer bytes = out.toArrayList();

        if (@max(uw, uh) >= self.opts.png_from) {
            try png.encode(gpa, sfc, &out.writer, .{});
        } else {
            try writeDib(gpa, sfc, &out.writer, uw, uh);
        }
        out.writer.flush() catch return error.OutOfMemory;
        bytes = out.toArrayList();

        try self.built.append(gpa, .{
            .width = uw,
            .height = uh,
            .bits = 32,
            .bytes = try bytes.toOwnedSlice(gpa),
        });
    }

    /// Writes the directory and then the images.
    pub fn finish(self: *Encoder, w: *Io.Writer) EncodeError!void {
        if (self.built.items.len == 0) return error.Unsupported;

        try w.writeInt(u16, 0, .little); // reserved
        try w.writeInt(u16, @backingInt(self.opts.kind), .little);
        try w.writeInt(u16, @intCast(self.built.items.len), .little);

        var offset: u32 = 6 + @as(u32, @intCast(self.built.items.len)) * 16;
        for (self.built.items) |item| {
            // Zero is how the directory says two hundred and fifty-six, the
            // field being one byte and the size one more than it holds.
            try w.writeByte(if (item.width == max_side) 0 else @intCast(item.width));
            try w.writeByte(if (item.height == max_side) 0 else @intCast(item.height));
            try w.writeByte(0); // colours: none, the image having more than 255
            try w.writeByte(0); // reserved
            switch (self.opts.kind) {
                // Colour planes, which is always one, and the depth.
                .icon => {
                    try w.writeInt(u16, 1, .little);
                    try w.writeInt(u16, item.bits, .little);
                },
                // The same two fields are a cursor's hotspot. The top left
                // corner is the only answer a surface can give.
                .cursor => {
                    try w.writeInt(u16, 0, .little);
                    try w.writeInt(u16, 0, .little);
                },
            }
            try w.writeInt(u32, @intCast(item.bytes.len), .little);
            try w.writeInt(u32, offset, .little);
            offset += @intCast(item.bytes.len);
        }

        for (self.built.items) |item| try w.writeAll(item.bytes);
    }
};

/// One image as a thirty-two-bit DIB, with the doubled height and the AND
/// mask an icon entry has to carry.
fn writeDib(
    gpa: Allocator,
    sfc: *const z2d.Surface,
    w: *Io.Writer,
    uw: u32,
    uh: u32,
) EncodeError!void {
    const xor_stride = uw * 4; // thirty-two bits is always a multiple of four
    const mask_stride = (uw + 31) / 32 * 4;

    // A forty-byte `BITMAPINFOHEADER`, which is what every icon has and what
    // every reader of one expects. Its thirty-two bits carry alpha by the
    // icon convention, which the bitmap format does not describe --- see the
    // note at the top of this file about reading one back.
    try w.writeInt(u32, 40, .little);
    try w.writeInt(i32, @intCast(uw), .little);
    // Twice the height: the pixels, and the mask under them.
    try w.writeInt(i32, @intCast(uh * 2), .little);
    try w.writeInt(u16, 1, .little); // planes
    try w.writeInt(u16, 32, .little); // bits per pixel
    try w.writeInt(u32, 0, .little); // BI_RGB
    try w.writeInt(u32, xor_stride * uh + mask_stride * uh, .little);
    try w.writeInt(i32, 0, .little); // pixels per metre, horizontal
    try w.writeInt(i32, 0, .little); // and vertical
    try w.writeInt(u32, 0, .little); // colours used
    try w.writeInt(u32, 0, .little); // colours important

    const row = try gpa.alloc(Rgba8, uw);
    defer gpa.free(row);

    // Bottom-up, which is what a positive height means and what icons are.
    var y: u32 = uh;
    while (y > 0) {
        y -= 1;
        pixels.readRow(row, sfc, @intCast(y));
        for (row) |px| {
            // Blue, green, red, alpha: the order a Windows bitmap stores a
            // thirty-two-bit pixel in.
            try w.writeAll(&.{ px.b, px.g, px.r, px.a });
        }
    }

    // The AND mask. Every bit clear: the alpha channel above is the
    // transparency, and a reader that honours both sees the same picture.
    const blank = try gpa.alloc(u8, mask_stride);
    defer gpa.free(blank);
    @memset(blank, 0);
    for (0..uh) |_| try w.writeAll(blank);
}

/// Writes a surface as an icon of one image.
///
/// `Encoder` is the way to write several, which is what an icon file is for;
/// this is the one-image case, so that every format here can be written the
/// same way.
pub fn encode(
    gpa: Allocator,
    sfc: *const z2d.Surface,
    w: *Io.Writer,
    opts: EncodeOptions,
) EncodeError!void {
    var encoder: Encoder = .init(opts);
    defer encoder.deinit(gpa);
    try encoder.image(gpa, sfc);
    try encoder.finish(w);
}
