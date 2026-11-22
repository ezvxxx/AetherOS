// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Portable Network Graphics.
//!
//! Where BMP is a header and then the pixels, PNG is a container: an
//! eight-byte signature and then a sequence of length-tagged, CRC-checked
//! chunks, of which three matter here. `IHDR` says how large the image is and
//! how its samples are arranged, `IDAT` carries a zlib stream, and `IEND` ends
//! the file. `PLTE` and `tRNS` supply a palette and its transparency when the
//! image is indexed.
//!
//! Inside the zlib stream is not the image but a *filtered* form of it: every
//! scanline is preceded by a byte naming one of five filters, each of which
//! predicts a byte from its neighbours to the left and above and stores only
//! the difference. That is where most of PNG's compression comes from — the
//! filters turn a smooth gradient into a run of near-zero bytes, which deflate
//! then encodes to almost nothing.
//!
//! ## Reading it sans-I/O
//!
//! The zlib stream does not sit in one chunk. It is split across however many
//! `IDAT` chunks the encoder felt like, each with its own length and CRC, and
//! the split can fall anywhere — including in the middle of a deflate symbol.
//! So the pipeline is three readers deep, and each layer is a `std.Io.Reader`
//! that pulls from the one beneath it:
//!
//! ```text
//!   the caller's reader        bytes of the file
//!     └─ IdatReader            the IDAT payloads, concatenated, CRCs checked
//!          └─ flate.Decompress the zlib stream, inflated
//!               └─ scanlines   a filter byte and a row, over and over
//! ```
//!
//! Nothing buffers the compressed image, and nothing needs to know how many
//! `IDAT` chunks there are before it starts. `IdatReader` is the only piece of
//! this that is unusual, and it is about forty lines.
//!
//! ## What is read
//!
//! All five colour types, every bit depth each of them allows (1, 2, 4, 8 and
//! 16), all five filters, both interlace methods, `PLTE`, `tRNS`, and the CRC
//! on every chunk. Sixteen-bit samples are scaled down to eight, because that
//! is what a z2d surface holds.
//!
//! Ancillary chunks are skipped, their CRCs checked on the way past. An
//! unrecognised *critical* chunk is refused: the fifth bit of the first letter
//! of a chunk type says whether a decoder that does not know it may go on, and
//! a file using a critical extension is not a file this can read.
//!
//! ## What is written
//!
//! Eight-bit truecolour, with or without alpha, or eight-bit
//! greyscale-with-alpha for a surface that has only an alpha channel.
//! Non-interlaced, with the filter chosen per row by the heuristic the PNG
//! specification suggests. That is a lossless encoding of any surface z2d has.

const std = @import("std");
const Crc32 = std.hash.Crc32;
const Io = std.Io;
const flate = std.compress.flate;
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
const anim = @import("anim.zig");
const exif = @import("exif.zig");
const icc = @import("icc.zig");
const pixels = @import("pixels.zig");
const Rgba8 = pixels.Rgba8;

/// The eight bytes every PNG begins with. `format.zig` says what each of them
/// is for.
const signature = "\x89PNG\r\n\x1a\n";

/// How the samples in a scanline are arranged.
pub const ColourType = enum(u8) {
    /// One sample: brightness.
    greyscale = 0,
    /// Three samples: red, green, blue.
    truecolour = 2,
    /// One sample: an index into `PLTE`.
    indexed = 3,
    /// Two samples: brightness and alpha.
    greyscale_alpha = 4,
    /// Four samples: red, green, blue, alpha.
    truecolour_alpha = 6,
    _,

    /// How many samples make up one pixel.
    fn channels(self: ColourType) u8 {
        return switch (self) {
            .greyscale, .indexed => 1,
            .greyscale_alpha => 2,
            .truecolour => 3,
            .truecolour_alpha => 4,
            _ => 0,
        };
    }

    /// Whether this colour type may be stored at this bit depth.
    ///
    /// The table is in the specification and is not derivable: truecolour
    /// starts at eight bits because three channels below that would not pack
    /// usefully, and indexed stops at eight because a palette has at most 256
    /// entries.
    fn allowsDepth(self: ColourType, depth: u8) bool {
        return switch (self) {
            .greyscale => depth == 1 or depth == 2 or depth == 4 or depth == 8 or depth == 16,
            .indexed => depth == 1 or depth == 2 or depth == 4 or depth == 8,
            .truecolour, .greyscale_alpha, .truecolour_alpha => depth == 8 or depth == 16,
            _ => false,
        };
    }

    /// Whether every pixel carries its own alpha sample. An indexed image can
    /// still be transparent, through `tRNS`, which is why this is not the same
    /// question as whether the image has transparency.
    fn hasAlphaChannel(self: ColourType) bool {
        return self == .greyscale_alpha or self == .truecolour_alpha;
    }
};

/// How the image is laid out across the zlib stream.
pub const Interlace = enum(u8) {
    /// One pass, top to bottom.
    none = 0,
    /// Adam7: seven passes at coarsening resolution, so that a partly
    /// downloaded image can be shown blurred rather than half-drawn.
    adam7 = 1,
    _,
};

/// What `IHDR` said.
pub const Header = struct {
    width: u32,
    height: u32,
    /// Bits per sample, not per pixel.
    depth: u8,
    colour: ColourType,
    interlace: Interlace,

    /// Bytes in one unfiltered scanline of an image this wide.
    ///
    /// Sub-byte depths pack several pixels into a byte and the last byte of a
    /// row is padded, which is why this rounds up rather than dividing.
    fn rowBytes(self: Header, width: u32) usize {
        const bits = @as(u64, width) * self.colour.channels() * self.depth;
        return @intCast((bits + 7) / 8);
    }

    /// The filter's idea of a pixel: the distance in bytes between a byte and
    /// the corresponding byte of the pixel to its left.
    ///
    /// Rounded up to one, because at depths below eight a pixel is less than a
    /// byte and the filters still work a byte at a time.
    fn filterStride(self: Header) usize {
        return @max(1, @as(usize, self.colour.channels()) * self.depth / 8);
    }
};

/// Adam7's seven passes: where each starts and how far apart its pixels are.
///
/// Read down a column for one pass. The first takes one pixel in sixty-four,
/// the last takes every pixel of every other row, and between them they cover
/// the image exactly once.
const adam7 = struct {
    const row_start = [7]u32{ 0, 0, 4, 0, 2, 0, 1 };
    const col_start = [7]u32{ 0, 4, 0, 2, 0, 1, 0 };
    const row_step = [7]u32{ 8, 8, 8, 4, 4, 2, 2 };
    const col_step = [7]u32{ 8, 8, 4, 4, 2, 2, 1 };

    /// How many pixels across this pass is, which can be zero for a narrow
    /// image — a one-pixel-wide image has nothing at all in passes 2, 4 and 6.
    fn width(pass: usize, w: u32) u32 {
        if (w <= col_start[pass]) return 0;
        return (w - col_start[pass] + col_step[pass] - 1) / col_step[pass];
    }

    fn height(pass: usize, h: u32) u32 {
        if (h <= row_start[pass]) return 0;
        return (h - row_start[pass] + row_step[pass] - 1) / row_step[pass];
    }
};

// -- chunks ------------------------------------------------------------------

/// A chunk's length and type, already read.
const Chunk = struct {
    len: u32,
    kind: [4]u8,

    fn is(self: Chunk, name: *const [4]u8) bool {
        return mem.eql(u8, &self.kind, name);
    }

    /// Whether a decoder that does not recognise this chunk may carry on
    /// without it.
    ///
    /// The fifth bit of the first letter says so: lower case is ancillary,
    /// upper case is critical. It is the one piece of PNG's design that lets a
    /// reader written in 1996 cope with a chunk invented later.
    fn isAncillary(self: Chunk) bool {
        return self.kind[0] & 0x20 != 0;
    }
};

/// The largest chunk this decoder will read into memory rather than skip.
///
/// `PLTE` is at most 768 bytes and `tRNS` at most 256; nothing else is read
/// whole. A header claiming more than this for one of those is malformed, and
/// the cap means a malicious file cannot make the decoder allocate on the
/// strength of a length field.
const max_read_chunk = 1024;

/// Reads the chunk structure. Every chunk's CRC is checked, whether its
/// contents are wanted or not.
const ChunkReader = struct {
    r: *Io.Reader,

    /// The next chunk's length and type, with the type already fed to a fresh
    /// CRC — the checksum covers the type as well as the data.
    fn next(self: *ChunkReader) DecodeError!struct { Chunk, Crc32 } {
        const len = try self.r.takeInt(u32, .big);
        const kind = (try self.r.takeArray(4)).*;
        var crc: Crc32 = .init();
        crc.update(&kind);
        return .{ .{ .len = len, .kind = kind }, crc };
    }

    /// Reads a chunk's data into `buf`, which must be exactly its length, and
    /// checks the CRC.
    fn read(self: *ChunkReader, chunk: Chunk, crc: *Crc32, buf: []u8) DecodeError!void {
        std.debug.assert(buf.len == chunk.len);
        try self.r.readSliceAll(buf);
        crc.update(buf);
        try self.verify(crc);
    }

    /// Discards a chunk's data, still checking the CRC.
    fn skip(self: *ChunkReader, chunk: Chunk, crc: *Crc32) DecodeError!void {
        var left = chunk.len;
        var buf: [512]u8 = undefined;
        while (left > 0) {
            const n = @min(left, buf.len);
            try self.r.readSliceAll(buf[0..n]);
            crc.update(buf[0..n]);
            left -= n;
        }
        try self.verify(crc);
    }

    /// Hands a chunk's data to `exif` while still checking the checksum.
    ///
    /// Every other chunk is either read whole into a bounded buffer or
    /// skipped, and `eXIf` can be neither: it may be megabytes of thumbnail,
    /// and it has to be *parsed*. So the source is wrapped in a reader that
    /// feeds the checksum as the parser pulls through it, which is the one
    /// arrangement that neither buffers the chunk nor reads it twice.
    fn readExif(self: *ChunkReader, chunk: Chunk, crc: *Crc32) DecodeError!?exif.Orientation {
        // Bounded to the chunk's data before it is hashed, and that order
        // matters: a reader reads ahead, and hashing what it read ahead would
        // fold the checksum into the checksum it is being compared against.
        // Both readers need a buffer of their own to read ahead into. What
        // sits in the first one has not been hashed yet — it is hashed as the
        // second pulls it through — so every byte of the chunk is hashed
        // exactly once however the two divide it up.
        var bound_buf: [512]u8 = undefined;
        var limited = self.r.limited(.limited(chunk.len), &bound_buf);
        var hash_buf: [64]u8 = undefined;
        var hashed = limited.interface.hashed(crc, &hash_buf);
        const found = try exif.readOrientation(&hashed.reader, chunk.len);
        try self.verify(crc);
        return found;
    }

    /// Inflates an `iCCP` chunk's profile into `out`, still checking the
    /// checksum.
    ///
    /// The chunk is a name, a compression method, and the profile deflated.
    /// The name is of no use to anything here — it is a label a person chose
    /// — and the compression method has only ever had one value.
    fn readIcc(
        self: *ChunkReader,
        chunk: Chunk,
        crc: *Crc32,
        gpa: Allocator,
        out: *std.ArrayList(u8),
        limit: u64,
    ) DecodeError!void {
        // Bounded to the chunk before it is hashed, for the reason `readExif`
        // gives: a reader reads ahead, and hashing the read-ahead would fold
        // the checksum into itself.
        var bound_buf: [512]u8 = undefined;
        var limited = self.r.limited(.limited(chunk.len), &bound_buf);
        var hash_buf: [512]u8 = undefined;
        var hashed = limited.interface.hashed(crc, &hash_buf);
        const source = &hashed.reader;

        inflate: {
            // The name, up to 79 bytes and a terminator.
            var name_len: usize = 0;
            while (true) {
                const b = source.takeByte() catch break :inflate;
                if (b == 0) break;
                name_len += 1;
                if (name_len > 79) break :inflate;
            }
            if (name_len == 0) break :inflate;
            const method = source.takeByte() catch break :inflate;
            if (method != 0) break :inflate;

            const window = try gpa.alloc(u8, flate.max_window_len);
            defer gpa.free(window);
            var stream: flate.Decompress = .init(source, .zlib, window);

            var buf: [4096]u8 = undefined;
            while (true) {
                const n = stream.reader.readSliceShort(&buf) catch break :inflate;
                if (n == 0) break;
                if (out.items.len + n > limit) {
                    out.clearRetainingCapacity();
                    break :inflate;
                }
                try out.appendSlice(gpa, buf[0..n]);
            }
            // A profile that is not one is dropped rather than carried into
            // whatever the caller writes next.
            if (!icc.looksValid(out.items)) out.clearRetainingCapacity();
        }

        // Whatever happened above, the rest of the chunk still has to be read
        // for the checksum to mean anything.
        _ = source.discardRemaining() catch {};
        try self.verify(crc);
    }

    /// Reads the four-byte checksum and compares it.
    fn verify(self: *ChunkReader, crc: *Crc32) DecodeError!void {
        const want = try self.r.takeInt(u32, .big);
        if (crc.final() != want) return error.InvalidData;
    }
};

/// An `Io.Reader` over the concatenated payloads of the `IDAT` chunks.
///
/// This is what lets the zlib stream be inflated without first being
/// reassembled: the chunk boundaries, their lengths and their checksums are
/// consumed here, and what comes out is the compressed bytes and nothing else.
///
/// Errors take the long way round. A `Reader`'s `stream` may only fail with
/// `ReadFailed`, `WriteFailed` or `EndOfStream`, and a bad CRC is none of
/// those, so the real error is put in `err` and `ReadFailed` returned; the
/// decoder checks `err` when a read fails. `flate.Decompress` does the same
/// thing for the same reason.
const IdatReader = struct {
    source: *Io.Reader,
    /// Which chunk type carries this stream: `IDAT` for the still image,
    /// `fdAT` for an APNG frame after the first.
    kind: *const [4]u8,
    /// Bytes left in the chunk being read.
    remaining: u32,
    crc: Crc32,
    /// Set once a chunk of another type has been reached. A PNG's image data
    /// is one unbroken run of `IDAT`s and an APNG frame's is one unbroken run
    /// of `fdAT`s, so the first thing that is not one is the end of it.
    ended: bool,
    /// The header of that chunk, read and not yet consumed, so that `finish`
    /// can carry on from where this stopped rather than from the middle of a
    /// chunk it has already half-read.
    pending: ?Pending,
    err: ?DecodeError,
    /// Where the next expected APNG sequence number lives, or null for an
    /// `IDAT` stream, which has none.
    ///
    /// Every `fcTL` and `fdAT` in a file shares one counter that must go up by
    /// exactly one each time. Checking it is not pedantry: the numbers are the
    /// only thing tying a frame's data to the frame header that describes it,
    /// so a file that repeats or reorders them is a file that can make a
    /// decoder draw one frame's pixels with another frame's rectangle.
    sequence: ?*u32,
    interface: Io.Reader,

    const Pending = struct { chunk: Chunk, crc: Crc32 };

    /// Starts from a chunk header that has already been read and found to be
    /// of `kind`, with `crc` already covering its type bytes.
    fn init(
        source: *Io.Reader,
        kind: *const [4]u8,
        first: Chunk,
        crc: Crc32,
        buffer: []u8,
        sequence: ?*u32,
    ) IdatReader {
        return .{
            .source = source,
            .kind = kind,
            .remaining = first.len,
            .crc = crc,
            .ended = false,
            .pending = null,
            .err = null,
            .sequence = sequence,
            .interface = .{
                .vtable = &.{ .stream = stream },
                .buffer = buffer,
                .seek = 0,
                .end = 0,
            },
        };
    }

    fn stream(r: *Io.Reader, w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
        const self: *IdatReader = @fieldParentPtr("interface", r);
        while (self.remaining == 0) {
            if (self.ended) return error.EndOfStream;
            self.advance() catch |err| {
                self.err = err;
                return error.ReadFailed;
            };
        }
        // Taken from the source's own buffer so that the same bytes can be
        // both checksummed and handed on without a copy in between.
        const available = try self.source.peekGreedy(1);
        const n = @min(available.len, limit.minInt(self.remaining));
        self.crc.update(available[0..n]);
        try w.writeAll(available[0..n]);
        self.source.toss(n);
        self.remaining -= @intCast(n);
        return n;
    }

    /// Finishes the chunk just read and moves to the next, if it is another
    /// of the same kind.
    fn advance(self: *IdatReader) DecodeError!void {
        var chunks: ChunkReader = .{ .r = self.source };
        try chunks.verify(&self.crc);

        const chunk, const crc = try chunks.next();
        if (!chunk.is(self.kind)) {
            self.ended = true;
            self.pending = .{ .chunk = chunk, .crc = crc };
            return;
        }
        self.remaining = chunk.len;
        self.crc = crc;
        try self.takeSequence();
    }

    /// Consumes an `fdAT`'s leading sequence number, which is part of the
    /// chunk and its checksum but not part of the zlib stream.
    ///
    /// Called for the first chunk by whoever built this and for every later
    /// one by `advance`.
    fn takeSequence(self: *IdatReader) DecodeError!void {
        const counter = self.sequence orelse return;
        if (self.remaining < 4) return error.InvalidData;
        const bytes = (try self.source.takeArray(4)).*;
        self.crc.update(&bytes);
        self.remaining -= 4;
        if (mem.readInt(u32, &bytes, .big) != counter.*) return error.InvalidData;
        counter.* += 1;
    }

    /// Ends the stream where it stands and hands back the chunk header that
    /// ended it.
    ///
    /// `finish` is the still-image version, which insists on reaching `IEND`;
    /// this is for a caller that has more of the file to read --- an
    /// animation, where what follows one frame's data is the next frame's
    /// header.
    fn stop(self: *IdatReader) DecodeError!Pending {
        var chunks: ChunkReader = .{ .r = self.source };
        if (self.pending) |p| {
            self.pending = null;
            return p;
        }
        // Still inside a chunk: the inflater stopped before the chunk did,
        // which is the ordinary case for the last one. What is left of it
        // still counts towards the checksum.
        var left = self.remaining;
        var buf: [512]u8 = undefined;
        while (left > 0) {
            const n = @min(left, buf.len);
            try self.source.readSliceAll(buf[0..n]);
            self.crc.update(buf[0..n]);
            left -= n;
        }
        self.remaining = 0;
        try chunks.verify(&self.crc);
        const chunk, const crc = try chunks.next();
        return .{ .chunk = chunk, .crc = crc };
    }

    /// Reads the rest of the file once the image has been decoded, checking
    /// every checksum on the way and insisting on an `IEND`.
    ///
    /// Without this the last `IDAT`'s checksum is never looked at, because
    /// nothing asks for a byte past the end of the zlib stream and it is that
    /// request which would have verified it. The effect is not subtle: a file
    /// truncated after its last scanline decodes perfectly happily, since
    /// every byte the inflater wanted was there. Requiring `IEND` is what
    /// makes a complete-looking file actually complete.
    fn finish(self: *IdatReader) DecodeError!void {
        var chunks: ChunkReader = .{ .r = self.source };

        // Still inside an `IDAT`: the inflater stopped before the chunk did,
        // which is the ordinary case for the last one. Whatever is left of it
        // still counts towards the checksum.
        if (self.pending == null) {
            var left = self.remaining;
            var buf: [512]u8 = undefined;
            while (left > 0) {
                const n = @min(left, buf.len);
                try self.source.readSliceAll(buf[0..n]);
                self.crc.update(buf[0..n]);
                left -= n;
            }
            self.remaining = 0;
            try chunks.verify(&self.crc);
        }

        while (true) {
            var entry: Pending = if (self.pending) |p| p else blk: {
                const chunk, const crc = try chunks.next();
                break :blk .{ .chunk = chunk, .crc = crc };
            };
            self.pending = null;

            if (entry.chunk.is("IEND")) {
                if (entry.chunk.len != 0) return error.InvalidData;
                return chunks.verify(&entry.crc);
            }
            // A chunk of the stream's own kind after it has ended is a file
            // whose image data is not one unbroken run, which the format
            // forbids.
            if (entry.chunk.is(self.kind)) return error.InvalidData;
            if (!entry.chunk.isAncillary()) return error.Unsupported;
            if (entry.chunk.len > 1 << 24) return error.InvalidData;
            try chunks.skip(entry.chunk, &entry.crc);
        }
    }
};

// -- decoding ----------------------------------------------------------------

/// What `acTL` declares about the animation as a whole.
pub const Actl = struct {
    /// How many frames the animation has. Checked against how many actually
    /// arrive, since a count that disagrees with the file is a file that
    /// disagrees with itself.
    frames: u32,
    /// How many times to play, zero for forever. APNG counts plays, which is
    /// the meaning `anim.Info.loop_count` uses, so nothing is converted.
    plays: u32,
};

/// An `fcTL`: one frame's geometry, timing and rules.
pub const Fctl = struct {
    sequence: u32,
    width: u32,
    height: u32,
    x: u32,
    y: u32,
    /// The delay as the file writes it: a fraction of a second, numerator and
    /// denominator, rather than a fixed unit.
    delay_num: u16,
    delay_den: u16,
    dispose: anim.Dispose,
    blend: anim.Blend,

    pub const len = 26;

    pub fn parse(buf: *const [len]u8) DecodeError!Fctl {
        const dispose: anim.Dispose = switch (buf[24]) {
            0 => .keep,
            1 => .background,
            2 => .previous,
            // Unlike GIF's disposal field, APNG's has no undefined values to
            // be generous about: three of three are specified, so a fourth is
            // a file that is wrong rather than a file that is new.
            else => return error.InvalidData,
        };
        const blend: anim.Blend = switch (buf[25]) {
            0 => .source,
            1 => .over,
            else => return error.InvalidData,
        };
        return .{
            .sequence = mem.readInt(u32, buf[0..4], .big),
            .width = mem.readInt(u32, buf[4..8], .big),
            .height = mem.readInt(u32, buf[8..12], .big),
            .x = mem.readInt(u32, buf[12..16], .big),
            .y = mem.readInt(u32, buf[16..20], .big),
            .delay_num = mem.readInt(u16, buf[20..22], .big),
            .delay_den = mem.readInt(u16, buf[22..24], .big),
            .dispose = dispose,
            .blend = blend,
        };
    }

    /// The delay in milliseconds.
    ///
    /// A denominator of zero means hundredths of a second, which the
    /// specification says outright --- so the obvious division is also a
    /// division by zero on a value real files carry.
    pub fn delayMs(self: Fctl) u32 {
        const den: u32 = if (self.delay_den == 0) 100 else self.delay_den;
        return @intCast(@as(u64, self.delay_num) * 1000 / den);
    }
};

/// A PNG part-read: everything before the image data has been read, and the
/// image data has not.
///
/// "Everything before the image data" rather than just `IHDR`, because `IHDR`
/// alone does not say whether the image has transparency. A greyscale or
/// truecolour image with no alpha channel can still be transparent, through a
/// `tRNS` chunk that sits between the two — so a decoder that chose its
/// surface from `IHDR` would pick one with nowhere to put the alpha, and drop
/// it silently. Reading as far as the first `IDAT` costs a palette and a
/// transparency table, both of which are under a kilobyte, and is what makes
/// `info` true.
pub const Decoder = struct {
    header: Header,
    limits: Limits,
    /// Always a full 256 entries, with anything the file did not supply left
    /// opaque black, so that an index past the end of a short palette is a
    /// colour rather than a refusal. Short palettes with out-of-range indices
    /// turn up in real files and every other decoder reads them.
    palette: [256]Rgba8,
    palette_len: u32,
    transparency: Transparency,
    /// The first `IDAT`'s header, already read, and the checksum covering its
    /// type bytes.
    first: Chunk,
    first_crc: Crc32,
    /// What an `eXIf` chunk before the image data said, if there was one.
    orientation: exif.Orientation,
    /// What `acTL` declared, if this is an APNG.
    actl: ?Actl = null,
    /// The `fcTL` in front of `IDAT`, if there was one.
    ///
    /// Its presence is what says the default image is also the animation's
    /// first frame. Without it the `IDAT` is a still picture for readers that
    /// do not know APNG, and the animation is the `fdAT` frames alone --- a
    /// distinction with no field of its own, carried entirely by whether one
    /// chunk came before another.
    first_fctl: ?Fctl = null,

    /// Somewhere to put the metadata that needs memory to collect.
    ///
    /// `init` reads every chunk before the image data, which is where an
    /// `iCCP` profile is, and it is also what `probe` is built on — and
    /// `probe` has no allocator and no reason to want one. So the sink is
    /// optional: given one, the profile is inflated into it; given none,
    /// the chunk is skipped like any other and nothing is allocated.
    pub const Sink = struct {
        gpa: Allocator,
        icc: *std.ArrayList(u8),
    };

    /// Reads the signature, `IHDR`, and every chunk up to the first `IDAT`.
    ///
    /// The `IDAT`'s length and type are consumed; its data is not.
    pub fn init(r: *Io.Reader, limits: Limits, sink: ?Sink) DecodeError!Decoder {
        const magic = try r.takeArray(signature.len);
        if (!mem.eql(u8, magic, signature)) return error.UnknownFormat;

        var chunks: ChunkReader = .{ .r = r };
        const ihdr_chunk, var ihdr_crc = try chunks.next();
        // `IHDR` is required to come first, and a file that puts something
        // else there is not one this should go looking through.
        if (!ihdr_chunk.is("IHDR") or ihdr_chunk.len != 13) return error.InvalidData;

        var buf: [13]u8 = undefined;
        try chunks.read(ihdr_chunk, &ihdr_crc, &buf);

        const width = mem.readInt(u32, buf[0..4], .big);
        const height = mem.readInt(u32, buf[4..8], .big);
        const depth = buf[8];
        const colour: ColourType = @fromBackingInt(@intCast(buf[9]));
        const compression = buf[10];
        const filter = buf[11];
        const interlace: Interlace = @fromBackingInt(@intCast(buf[12]));

        try limits.check(width, height);
        // A PNG's dimensions are unsigned thirty-two-bit and a z2d surface is
        // measured in `i32`, so the top half of the range is expressible in
        // the file and not in a surface. Refusing it here is what keeps every
        // later `@intCast` from being a panic; the limits would catch it under
        // any sane budget, and this does not depend on the caller having set
        // one.
        if (width > math.maxInt(i32) or height > math.maxInt(i32)) return error.InvalidData;
        if (!colour.allowsDepth(depth)) return error.InvalidData;
        // Both fields have had exactly one valid value since 1996, and a file
        // with another is either corrupt or from a future that never arrived.
        if (compression != 0 or filter != 0) return error.InvalidData;
        switch (interlace) {
            .none, .adam7 => {},
            _ => return error.InvalidData,
        }

        var self: Decoder = .{
            .header = .{
                .width = width,
                .height = height,
                .depth = depth,
                .colour = colour,
                .interlace = interlace,
            },
            .limits = limits,
            .palette = @splat(.black),
            .palette_len = 0,
            .transparency = .none,
            .first = undefined,
            .first_crc = undefined,
            .orientation = .top_left,
        };

        // Everything between `IHDR` and the image data.
        while (true) {
            const chunk, var crc = try chunks.next();
            if (chunk.is("IDAT")) {
                self.first = chunk;
                self.first_crc = crc;
                break;
            }
            if (chunk.is("IEND")) return error.InvalidData; // no image data
            if (chunk.is("PLTE")) {
                if (chunk.len == 0 or chunk.len % 3 != 0 or chunk.len > 768) return error.InvalidData;
                var plte: [768]u8 = undefined;
                try chunks.read(chunk, &crc, plte[0..chunk.len]);
                self.palette_len = chunk.len / 3;
                for (self.palette[0..self.palette_len], 0..) |*entry, i| {
                    entry.* = .rgb(plte[i * 3], plte[i * 3 + 1], plte[i * 3 + 2]);
                }
                continue;
            }
            if (chunk.is("tRNS")) {
                if (chunk.len > max_read_chunk) return error.InvalidData;
                var trns: [max_read_chunk]u8 = undefined;
                try chunks.read(chunk, &crc, trns[0..chunk.len]);
                self.transparency = try Transparency.parse(
                    colour,
                    trns[0..chunk.len],
                    &self.palette,
                    self.palette_len,
                );
                continue;
            }
            if (chunk.is("iCCP")) {
                if (sink) |s| {
                    try chunks.readIcc(chunk, &crc, s.gpa, s.icc, limits.max_icc_bytes);
                } else {
                    if (chunk.len > 1 << 24) return error.InvalidData;
                    try chunks.skip(chunk, &crc);
                }
                continue;
            }
            if (chunk.is("acTL")) {
                // Once only, and before the image data, which is where this
                // loop is. A second one is a file contradicting itself.
                if (self.actl != null or chunk.len != 8) return error.InvalidData;
                var buf8: [8]u8 = undefined;
                try chunks.read(chunk, &crc, &buf8);
                self.actl = .{
                    .frames = mem.readInt(u32, buf8[0..4], .big),
                    .plays = mem.readInt(u32, buf8[4..8], .big),
                };
                continue;
            }
            if (chunk.is("fcTL")) {
                if (self.first_fctl != null or chunk.len != Fctl.len) return error.InvalidData;
                var buf26: [Fctl.len]u8 = undefined;
                try chunks.read(chunk, &crc, &buf26);
                const fctl = try Fctl.parse(&buf26);
                // The frame the default image is has to *be* the default
                // image: full size, at the origin. Anything else describes a
                // picture the `IDAT` does not contain.
                if (fctl.x != 0 or fctl.y != 0 or
                    fctl.width != width or fctl.height != height) return error.InvalidData;
                self.first_fctl = fctl;
                continue;
            }
            if (chunk.is("eXIf")) {
                // The same TIFF block a JPEG carries in `APP1`, which is why
                // it is read by a module that belongs to neither codec. PNG
                // Third Edition says the chunk holds the block alone, without
                // the `Exif\0\0` marker; `exif` accepts it either way,
                // because encoders exist that write the marker anyway.
                if (try chunks.readExif(chunk, &crc)) |o| self.orientation = o;
                continue;
            }
            // Anything else: skipped if the file says a reader may skip it,
            // refused if it does not.
            if (!chunk.isAncillary()) return error.Unsupported;
            if (chunk.len > 1 << 24) return error.InvalidData;
            try chunks.skip(chunk, &crc);
        }

        // An indexed image without a palette has nothing to index.
        if (colour == .indexed and self.palette_len == 0) return error.InvalidData;

        return self;
    }

    /// What the file said, in the shape every codec here reports it.
    ///
    /// `has_alpha` is true when the colour type carries an alpha sample *or* a
    /// `tRNS` chunk was found, which is why `init` reads that far: an image
    /// can be transparent without its colour type saying so, and a caller that
    /// believed otherwise would be handed a surface that had quietly dropped
    /// the transparency.
    pub fn info(self: Decoder) Info {
        const has_alpha = self.header.colour.hasAlphaChannel() or self.transparency != .none;
        return .{
            .format = .png,
            // `acTL` is required to precede `IDAT`, and `init` reads that
            // far, so this is settled rather than guessed at: a PNG without
            // one is a still picture and nothing later in the file can make
            // it otherwise.
            .animation = if (self.actl) |a| .{
                .declared = .{
                    // APNG counts plays, which is the meaning `anim.Info` uses.
                    .loop_count = a.plays,
                    .frames = a.frames,
                },
            } else .none,
            .width = self.header.width,
            .height = self.header.height,
            .has_alpha = has_alpha,
            .surface_type = pixels.naturalSurfaceType(has_alpha),
            .orientation = self.orientation,
        };
    }

    /// Reads the image data, producing the surface.
    ///
    /// The caller owns the surface and must `deinit` it with the same
    /// allocator.
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

        // The three readers of the module comment, stacked.
        const idat_buffer = try gpa.alloc(u8, 4096);
        defer gpa.free(idat_buffer);
        var idat: IdatReader = .init(r, "IDAT", self.first, self.first_crc, idat_buffer, null);

        const window = try gpa.alloc(u8, flate.max_window_len);
        defer gpa.free(window);
        var inflate: flate.Decompress = .init(&idat.interface, .zlib, window);

        var ctx: Pass = .{
            .header = self.header,
            .palette = &self.palette,
            .palette_len = self.palette_len,
            .transparency = self.transparency,
            .input = &inflate.reader,
            .idat = &idat,
        };

        switch (self.header.interlace) {
            .none => try ctx.run(gpa, &sfc, 0, 0, 1, 1, self.header.width, self.header.height),
            .adam7 => for (0..7) |pass| {
                const w = adam7.width(pass, self.header.width);
                const h = adam7.height(pass, self.header.height);
                if (w == 0 or h == 0) continue;
                try ctx.run(
                    gpa,
                    &sfc,
                    adam7.col_start[pass],
                    adam7.row_start[pass],
                    adam7.col_step[pass],
                    adam7.row_step[pass],
                    w,
                    h,
                );
            },
            _ => unreachable, // refused in `init`
        }

        // The rest of the file: the last checksum, and the `IEND` that says
        // the file is all there.
        try idat.finish();

        return sfc;
    }
};

/// What `tRNS` said, which depends entirely on the colour type.
pub const Transparency = union(enum) {
    none,
    /// A single grey sample that is fully transparent, at the image's own bit
    /// depth so that the comparison is exact.
    grey: u16,
    /// A single colour that is fully transparent.
    colour: struct { r: u16, g: u16, b: u16 },
    /// Already folded into the palette, which is where an indexed image keeps
    /// it: there is nothing left to compare against.
    palette,

    fn parse(
        colour: ColourType,
        data: []const u8,
        palette: *[256]Rgba8,
        palette_len: u32,
    ) DecodeError!Transparency {
        switch (colour) {
            .indexed => {
                // One alpha byte per palette entry, for as many as are given;
                // the rest stay opaque. More than the palette holds is a file
                // contradicting itself.
                if (data.len > palette_len) return error.InvalidData;
                for (data, 0..) |a, i| palette[i].a = a;
                return .palette;
            },
            .greyscale => {
                if (data.len != 2) return error.InvalidData;
                return .{ .grey = mem.readInt(u16, data[0..2], .big) };
            },
            .truecolour => {
                if (data.len != 6) return error.InvalidData;
                return .{ .colour = .{
                    .r = mem.readInt(u16, data[0..2], .big),
                    .g = mem.readInt(u16, data[2..4], .big),
                    .b = mem.readInt(u16, data[4..6], .big),
                } };
            },
            // A colour type that already has an alpha sample per pixel has no
            // use for `tRNS`, and the specification says it must not appear.
            else => return error.InvalidData,
        }
    }
};

/// One pass over the image: the whole of a non-interlaced image, or one
/// seventh of an Adam7 one.
const Pass = struct {
    header: Header,
    palette: *const [256]Rgba8,
    palette_len: u32,
    transparency: Transparency,
    input: *Io.Reader,
    /// Consulted when a read fails, since that is where the real error went.
    idat: *IdatReader,

    /// Reads `height` scanlines of `width` pixels and places them at
    /// `(x_start + i * x_step, y_start + j * y_step)`.
    fn run(
        self: *Pass,
        gpa: Allocator,
        sfc: *z2d.Surface,
        x_start: u32,
        y_start: u32,
        x_step: u32,
        y_step: u32,
        width: u32,
        height: u32,
    ) DecodeError!void {
        const row_bytes = self.header.rowBytes(width);
        const stride = self.header.filterStride();

        // Two scanlines: the one being read and the one above it, which the
        // `Up`, `Average` and `Paeth` filters predict from. The previous row
        // starts as zeroes, which is what the specification says to use above
        // the first row of a pass.
        const buf = try gpa.alloc(u8, row_bytes * 2);
        defer gpa.free(buf);
        @memset(buf, 0);
        var curr = buf[0..row_bytes];
        var prev = buf[row_bytes..];

        const row = try gpa.alloc(Rgba8, width);
        defer gpa.free(row);

        var j: u32 = 0;
        while (j < height) : (j += 1) {
            // The filter byte first, then the row, then the reversal. Its
            // value is copied out straight away because `take` hands back a
            // pointer into the inflater's window, which the next read moves.
            const filter = (try self.take(1))[0];
            try self.readInto(curr);
            try unfilter(filter, curr, prev, stride);

            self.expand(curr, row, width);

            const y: i32 = @intCast(y_start + j * y_step);
            if (x_step == 1) {
                // The common case, and every row of a non-interlaced image:
                // the pixels are adjacent, so the whole row goes at once.
                pixels.writeRow(sfc, y, row);
            } else {
                for (row, 0..) |px, i| {
                    pixels.writePixel(sfc, @intCast(x_start + @as(u32, @intCast(i)) * x_step), y, px);
                }
            }

            mem.swap([]u8, &curr, &prev);
        }
    }

    /// Reads `n` bytes of the inflated stream, translating a failure back into
    /// whatever really went wrong underneath.
    fn take(self: *Pass, n: usize) DecodeError![]u8 {
        return self.input.take(n) catch |err| switch (err) {
            error.EndOfStream => error.EndOfStream,
            error.ReadFailed => self.underlying(),
        };
    }

    fn readInto(self: *Pass, buf: []u8) DecodeError!void {
        return self.input.readSliceAll(buf) catch |err| switch (err) {
            error.EndOfStream => error.EndOfStream,
            error.ReadFailed => self.underlying(),
        };
    }

    /// The error a `ReadFailed` was standing in for.
    ///
    /// Three layers can fail: the chunk structure (a bad CRC), the zlib stream
    /// (a bad checksum, a corrupt deflate block) and the caller's own reader.
    /// Only the first keeps its error where this can reach it; the rest arrive
    /// as a malformed file, which is what they are.
    fn underlying(self: *Pass) DecodeError {
        if (self.idat.err) |err| return err;
        return error.InvalidData;
    }

    /// Turns one unfiltered scanline into colour.
    fn expand(self: *const Pass, raw: []const u8, row: []Rgba8, width: u32) void {
        const depth = self.header.depth;
        const channels = self.header.colour.channels();
        for (row[0..width], 0..) |*px, i| {
            const base = i * channels;
            px.* = switch (self.header.colour) {
                .greyscale => grey: {
                    // The comparison is against the *raw* sample, before it is
                    // scaled to eight bits: `tRNS` names a value at the
                    // image's own depth, and two different sixteen-bit greys
                    // can scale to the same byte.
                    const v = sample(raw, depth, base);
                    const g = scale(v, depth);
                    var out: Rgba8 = .rgb(g, g, g);
                    switch (self.transparency) {
                        .grey => |t| if (t == v) {
                            out.a = 0;
                        },
                        else => {},
                    }
                    break :grey out;
                },
                .truecolour => rgb: {
                    const r = sample(raw, depth, base);
                    const g = sample(raw, depth, base + 1);
                    const b = sample(raw, depth, base + 2);
                    var out: Rgba8 = .rgb(scale(r, depth), scale(g, depth), scale(b, depth));
                    switch (self.transparency) {
                        .colour => |t| if (t.r == r and t.g == g and t.b == b) {
                            out.a = 0;
                        },
                        else => {},
                    }
                    break :rgb out;
                },
                // The palette is a full 256 entries whatever the file supplied,
                // so an index past the end is opaque black rather than a
                // refusal. Short palettes with out-of-range indices turn up in
                // real files, and every other decoder reads them.
                .indexed => self.palette[sample(raw, depth, base)],
                .greyscale_alpha => ga: {
                    const g = scale(sample(raw, depth, base), depth);
                    break :ga .{ .r = g, .g = g, .b = g, .a = scale(sample(raw, depth, base + 1), depth) };
                },
                .truecolour_alpha => .{
                    .r = scale(sample(raw, depth, base), depth),
                    .g = scale(sample(raw, depth, base + 1), depth),
                    .b = scale(sample(raw, depth, base + 2), depth),
                    .a = scale(sample(raw, depth, base + 3), depth),
                },
                _ => unreachable, // refused in `Decoder.init`
            };
        }
    }
};

/// The `i`th sample of a scanline, at its own bit depth.
///
/// Samples below eight bits are packed high-order first, several to a byte;
/// sixteen-bit ones are big-endian, like every other number in a PNG.
fn sample(raw: []const u8, depth: u8, i: usize) u16 {
    return switch (depth) {
        8 => raw[i],
        16 => mem.readInt(u16, raw[i * 2 ..][0..2], .big),
        else => sub: {
            // The widths matter: at one bit a byte holds eight samples, and
            // eight does not fit the `u3` a byte shift wants. Only the shift,
            // which is at most seven, is narrowed.
            const per_byte: usize = 8 / depth;
            const byte = raw[i / per_byte];
            const slot = per_byte - 1 - (i % per_byte);
            const shift: u3 = @intCast(slot * depth);
            const mask: u8 = @intCast((@as(u16, 1) << @intCast(depth)) - 1);
            break :sub (byte >> shift) & mask;
        },
    };
}

/// A sample scaled to the eight bits a z2d surface holds.
///
/// A rounded proportion rather than a shift, so that the largest value at any
/// depth comes out 255 rather than a little short of it — a one-bit sample of
/// 1 is white, not 128.
fn scale(v: u16, depth: u8) u8 {
    return switch (depth) {
        8 => @intCast(v),
        16 => @intCast((@as(u32, v) * 255 + 32767) / 65535),
        else => small: {
            const max: u32 = (@as(u32, 1) << @intCast(depth)) - 1;
            break :small @intCast((@as(u32, v) * 255 + max / 2) / max);
        },
    };
}

/// Reverses one scanline's filter, in place.
///
/// Each filter predicts a byte from up to three already-reconstructed
/// neighbours — `a` to the left, `b` above, `c` above-left — and the stored
/// byte is the difference. Reconstructing therefore has to go left to right,
/// because each byte's prediction depends on the one before it having already
/// been put right.
///
/// All of it is modular arithmetic on bytes. The `+%` is not a shortcut; the
/// specification defines the filters that way, and a checked add would reject
/// perfectly ordinary images.
fn unfilter(kind: u8, curr: []u8, prev: []const u8, stride: usize) DecodeError!void {
    switch (kind) {
        // None.
        0 => {},
        // Sub: the byte to the left.
        1 => for (stride..curr.len) |i| {
            curr[i] +%= curr[i - stride];
        },
        // Up: the byte above.
        2 => for (curr, prev) |*b, p| {
            b.* +%= p;
        },
        // Average: the mean of left and above, rounded down, computed in nine
        // bits so that the sum cannot wrap before the halving.
        3 => for (0..curr.len) |i| {
            const a: u16 = if (i >= stride) curr[i - stride] else 0;
            const b: u16 = prev[i];
            curr[i] +%= @intCast((a + b) / 2);
        },
        // Paeth: whichever of left, above and above-left is closest to their
        // linear estimate.
        4 => for (0..curr.len) |i| {
            const a: u8 = if (i >= stride) curr[i - stride] else 0;
            const b: u8 = prev[i];
            const c: u8 = if (i >= stride) prev[i - stride] else 0;
            curr[i] +%= paeth(a, b, c);
        },
        else => return error.InvalidData,
    }
}

/// The Paeth predictor: of the three neighbours, the one nearest `a + b - c`.
///
/// Ties go to `a`, then `b`, which the specification is explicit about because
/// the order changes the answer and every decoder has to agree.
fn paeth(a: u8, b: u8, c: u8) u8 {
    const p = @as(i32, a) + @as(i32, b) - @as(i32, c);
    const pa = @abs(p - @as(i32, a));
    const pb = @abs(p - @as(i32, b));
    const pc = @abs(p - @as(i32, c));
    if (pa <= pb and pa <= pc) return a;
    if (pb <= pc) return b;
    return c;
}

/// Reads a whole PNG from `r`, producing a surface the caller owns.
pub fn decode(gpa: Allocator, r: *Io.Reader, opts: DecodeOptions) DecodeError!z2d.Surface {
    if (opts.icc) |out| out.clearRetainingCapacity();
    const sink: ?Decoder.Sink = if (opts.icc) |out| .{ .gpa = gpa, .icc = out } else null;
    var decoder: Decoder = try .init(r, opts.limits, sink);
    if (opts.orientation) |out| out.* = decoder.orientation;
    return decoder.decode(gpa, r, opts);
}

/// Reads only as far as the first `IDAT`, and says what the header described.
///
/// This consumes the signature, `IHDR` and everything between that and the
/// image data; see `bmp.probe` for what that means for a caller who wants to
/// probe and then decode.
pub fn probe(r: *Io.Reader, limits: Limits) DecodeError!Info {
    const decoder: Decoder = try .init(r, limits, null);
    return decoder.info();
}

// -- writing -----------------------------------------------------------------

/// How hard deflate should work.
pub const Level = enum {
    /// Quickest, and the largest output.
    fastest,
    fast,
    /// zlib's own default, and a good trade for almost everything.
    default,
    /// Smallest output, and several times slower than `default` for a few per
    /// cent.
    best,

    fn options(self: Level) flate.Compress.Options {
        return switch (self) {
            .fastest => .level_1,
            .fast => .level_4,
            .default => .level_6,
            .best => .level_9,
        };
    }
};

/// Which scanline filter to use.
pub const FilterChoice = enum {
    /// Store the row as it is. Fastest, and right for an image that is already
    /// noise — a photograph that has been through a lossy codec, say, where
    /// the filters have nothing to predict and only cost time.
    none,
    /// Predict from the byte to the left.
    sub,
    /// Predict from the byte above.
    up,
    /// Predict from the mean of the two.
    average,
    /// Predict from whichever neighbour is closest to their linear estimate.
    paeth,
    /// Try all five on every row and keep whichever makes the smallest sum of
    /// absolute differences.
    ///
    /// This is the heuristic the PNG specification suggests, and it is almost
    /// always worth its cost: it is five passes over a row that is about to be
    /// deflated anyway, and choosing per row is what lets one image use `up`
    /// through a gradient and `sub` through a run of flat colour.
    adaptive,
};

/// How to write a PNG.
pub const EncodeOptions = struct {
    level: Level = .default,
    filter: FilterChoice = .adaptive,

    /// An ICC colour profile to carry into the file, as an `iCCP` chunk.
    ///
    /// Borrowed for the call and not kept. Nothing here interprets it — see
    /// `icc` for what that means — but a profile that is not shaped like one
    /// is refused with `error.Unsupported` rather than written, since a
    /// malformed profile in the output is a file other readers reject.
    icc: ?[]const u8 = null,

    /// Which way up the image goes, written as an `eXIf` chunk.
    ///
    /// Nothing here rotates anything, so this is written as given and makes no
    /// claim about the pixels beside it. Null writes no chunk; see `exif`.
    orientation: ?exif.Orientation = null,

    /// What to call the profile in the file.
    ///
    /// PNG requires a name of 1 to 79 bytes and does nothing with it; it is a
    /// label for a person. Ignored when `icc` is null.
    icc_name: []const u8 = "ICC profile",
};

/// Writes `sfc` as a PNG.
///
/// The encoding is chosen from the surface's pixel format, and is lossless in
/// every case — unlike BMP, where the container cannot hold everything a
/// surface can, PNG can:
///
///   * A surface with colour and an alpha channel becomes eight-bit
///     truecolour with alpha.
///   * One with colour and no alpha becomes eight-bit truecolour.
///   * One with only an alpha channel becomes eight-bit greyscale with alpha,
///     the grey fixed at zero. That is what such a surface holds — z2d's
///     alpha-only formats carry coverage and no colour — and it is half the
///     size of writing it as transparent black in four channels.
///
/// The alpha written is straight alpha, demultiplied from what the surface
/// holds, so a decode-and-encode round trip is not promised to be byte-exact
/// for an image with transparency. `pixels.Rgba8.fromZ2d` says why.
///
/// `gpa` is used for the compressor's window, two scanline buffers and the
/// compressed image, and all of it is released before this returns.
pub fn encode(
    gpa: Allocator,
    sfc: *const z2d.Surface,
    w: *Io.Writer,
    opts: EncodeOptions,
) EncodeError!void {
    const width = sfc.getWidth();
    const height = sfc.getHeight();
    if (width < 1 or height < 1) return error.Unsupported;

    const colour: ColourType = switch (sfc.getFormat()) {
        .rgb, .xrgb => .truecolour,
        .argb, .rgba => .truecolour_alpha,
        .alpha8, .alpha4, .alpha2, .alpha1 => .greyscale_alpha,
    };
    const channels: usize = colour.channels();
    const row_bytes = @as(usize, @intCast(width)) * channels;

    // -- IHDR ----------------------------------------------------------------
    try w.writeAll(signature);

    var ihdr: [13]u8 = undefined;
    mem.writeInt(u32, ihdr[0..4], @intCast(width), .big);
    mem.writeInt(u32, ihdr[4..8], @intCast(height), .big);
    ihdr[8] = 8; // bit depth
    ihdr[9] = @backingInt(colour);
    ihdr[10] = 0; // compression: deflate, the only value there has ever been
    ihdr[11] = 0; // filter: adaptive, likewise
    ihdr[12] = @backingInt(Interlace.none);
    try writeChunk(w, "IHDR", &ihdr);

    // -- iCCP ----------------------------------------------------------------
    if (opts.icc) |profile| {
        if (!icc.looksValid(profile)) return error.Unsupported;
        if (opts.icc_name.len == 0 or opts.icc_name.len > 79) return error.Unsupported;
        // A name is Latin-1 text with no null in it, since a null is what
        // ends it.
        if (mem.indexOfScalar(u8, opts.icc_name, 0) != null) return error.Unsupported;

        var chunk: std.ArrayList(u8) = .empty;
        defer chunk.deinit(gpa);
        try chunk.appendSlice(gpa, opts.icc_name);
        try chunk.append(gpa, 0);
        try chunk.append(gpa, 0); // deflate, the only compression method
        try chunk.ensureUnusedCapacity(gpa, 1024);
        {
            var out: Io.Writer.Allocating = .fromArrayList(gpa, &chunk);
            defer chunk = out.toArrayList();
            const window = try gpa.alloc(u8, flate.max_window_len);
            defer gpa.free(window);
            var deflate = flate.Compress.init(&out.writer, window, .zlib, opts.level.options()) catch
                return error.WriteFailed;
            try deflate.writer.writeAll(profile);
            try deflate.finish();
        }
        try writeChunk(w, "iCCP", chunk.items);
    }

    // -- eXIf ----------------------------------------------------------------
    if (opts.orientation) |o| {
        // The TIFF block alone. PNG Third Edition says the chunk holds the
        // block without the `Exif\0\0` marker a JPEG puts in front of it.
        var tiff: [exif.orientation_block_len]u8 = undefined;
        exif.writeOrientation(&tiff, o);
        try writeChunk(w, "eXIf", &tiff);
    }

    // -- IDAT ----------------------------------------------------------------
    //
    // The compressed image is assembled in memory and written as one chunk.
    // Splitting it across several would let the encoder stream, and is not
    // worth the custom `Io.Writer` it would take here: the caller already
    // holds the whole image as a surface, and the compressed copy is smaller
    // than that, so this is not a new order of magnitude of memory.
    var compressed: std.ArrayList(u8) = .empty;
    defer compressed.deinit(gpa);
    // `flate.Compress` asserts its output has somewhere to write before it
    // starts, so the list is given room before it is handed over.
    try compressed.ensureTotalCapacity(gpa, 4096);

    {
        var out: Io.Writer.Allocating = .fromArrayList(gpa, &compressed);
        defer compressed = out.toArrayList();

        const window = try gpa.alloc(u8, flate.max_window_len);
        defer gpa.free(window);

        var deflate = flate.Compress.init(&out.writer, window, .zlib, opts.level.options()) catch
            return error.OutOfMemory;

        try writeScanlines(gpa, sfc, &deflate.writer, colour, row_bytes, opts.filter);
        deflate.finish() catch return error.OutOfMemory;
        out.writer.flush() catch return error.OutOfMemory;
    }

    // A chunk's length is a `u32`, so an image whose compressed form does not
    // fit one cannot be written as a single chunk. Nothing near this is
    // reachable in practice; refusing is better than truncating.
    if (compressed.items.len > math.maxInt(u32)) return error.Unsupported;
    try writeChunk(w, "IDAT", compressed.items);

    try writeChunk(w, "IEND", &.{});
}

/// Filters every row and hands it to the compressor.
fn writeScanlines(
    gpa: Allocator,
    sfc: *const z2d.Surface,
    out: *Io.Writer,
    colour: ColourType,
    row_bytes: usize,
    choice: FilterChoice,
) EncodeError!void {
    const width: usize = @intCast(sfc.getWidth());
    const height = sfc.getHeight();
    const stride = @as(usize, colour.channels()); // eight bits a sample

    // Two raw rows, the one being written and the one above it, plus two
    // filtered candidates to choose between.
    const buf = try gpa.alloc(u8, row_bytes * 4);
    defer gpa.free(buf);
    @memset(buf, 0);
    var curr = buf[0 * row_bytes ..][0..row_bytes];
    var prev = buf[1 * row_bytes ..][0..row_bytes];
    const best = buf[2 * row_bytes ..][0..row_bytes];
    const candidate = buf[3 * row_bytes ..][0..row_bytes];

    const row = try gpa.alloc(Rgba8, width);
    defer gpa.free(row);

    var y: i32 = 0;
    while (y < height) : (y += 1) {
        pixels.readRow(row, sfc, y);
        serialise(row, curr, colour);

        var kind: u8 = 0;
        if (choice == .adaptive) {
            var best_score: u64 = math.maxInt(u64);
            for ([_]u8{ 0, 1, 2, 3, 4 }) |k| {
                filterRow(k, curr, prev, stride, candidate);
                const score = absoluteSum(candidate);
                if (score < best_score) {
                    best_score = score;
                    kind = k;
                    @memcpy(best, candidate);
                }
            }
        } else {
            kind = switch (choice) {
                .none => 0,
                .sub => 1,
                .up => 2,
                .average => 3,
                .paeth => 4,
                .adaptive => unreachable,
            };
            filterRow(kind, curr, prev, stride, best);
        }

        try out.writeByte(kind);
        try out.writeAll(best);

        mem.swap([]u8, &curr, &prev);
    }
}

/// Turns a row of straight-alpha colour into the samples the colour type
/// stores.
fn serialise(row: []const Rgba8, out: []u8, colour: ColourType) void {
    switch (colour) {
        .truecolour => for (row, 0..) |px, i| {
            out[i * 3 + 0] = px.r;
            out[i * 3 + 1] = px.g;
            out[i * 3 + 2] = px.b;
        },
        .truecolour_alpha => for (row, 0..) |px, i| {
            out[i * 4 + 0] = px.r;
            out[i * 4 + 1] = px.g;
            out[i * 4 + 2] = px.b;
            out[i * 4 + 3] = px.a;
        },
        // Grey and alpha. A z2d alpha-only surface has no colour to write, and
        // `pixels.readRow` reports its pixels as transparent black, so the
        // grey sample is zero throughout and the alpha carries everything.
        .greyscale_alpha => for (row, 0..) |px, i| {
            out[i * 2 + 0] = px.r;
            out[i * 2 + 1] = px.a;
        },
        else => unreachable, // `encode` produces no other colour type
    }
}

/// Applies one filter to a row, the reverse of `unfilter`.
///
/// The neighbours here are the *original* bytes rather than reconstructed
/// ones, which is the whole asymmetry between filtering and unfiltering: an
/// encoder already has the real data, where a decoder has to rebuild each byte
/// before the next one can use it.
fn filterRow(kind: u8, curr: []const u8, prev: []const u8, stride: usize, out: []u8) void {
    switch (kind) {
        0 => @memcpy(out, curr),
        1 => for (0..curr.len) |i| {
            const a: u8 = if (i >= stride) curr[i - stride] else 0;
            out[i] = curr[i] -% a;
        },
        2 => for (0..curr.len) |i| {
            out[i] = curr[i] -% prev[i];
        },
        3 => for (0..curr.len) |i| {
            const a: u16 = if (i >= stride) curr[i - stride] else 0;
            const b: u16 = prev[i];
            out[i] = curr[i] -% @as(u8, @intCast((a + b) / 2));
        },
        4 => for (0..curr.len) |i| {
            const a: u8 = if (i >= stride) curr[i - stride] else 0;
            const b: u8 = prev[i];
            const c: u8 = if (i >= stride) prev[i - stride] else 0;
            out[i] = curr[i] -% paeth(a, b, c);
        },
        else => unreachable,
    }
}

/// The heuristic's score for a filtered row: the sum of the bytes read as
/// signed magnitudes.
///
/// Smaller is better, on the reasoning that deflate encodes a run of
/// near-zero bytes in fewer bits than a run of arbitrary ones. It is a
/// heuristic and not a measurement — the only way to know which filter
/// compresses best is to compress all five — but it is the one the
/// specification suggests and it is close enough that nobody does the
/// measurement.
fn absoluteSum(row: []const u8) u64 {
    var total: u64 = 0;
    for (row) |b| {
        const signed: i8 = @bitCast(b);
        total += @abs(@as(i16, signed));
    }
    return total;
}

/// Writes one chunk: its length, its type, its data and the checksum over the
/// last two.
fn writeChunk(w: *Io.Writer, kind: *const [4]u8, data: []const u8) EncodeError!void {
    try w.writeInt(u32, @intCast(data.len), .big);
    try w.writeAll(kind);
    try w.writeAll(data);
    var crc: Crc32 = .init();
    crc.update(kind);
    crc.update(data);
    try w.writeInt(u32, crc.final(), .big);
}

// -- animation ---------------------------------------------------------------

/// An APNG played frame by frame.
///
/// See `anim` for the model, and the module comment above for the chunk
/// machinery this is built on. Three things about APNG are worth knowing
/// before reading it.
///
/// **A frame's data is its own zlib stream**, spread over `fdAT` chunks the
/// way the still image's is spread over `IDAT`s. `IdatReader` reads either,
/// which is the whole reason it takes a chunk type.
///
/// **Every `fcTL` and `fdAT` shares one sequence counter** that must go up by
/// exactly one each time. That counter is the only thing tying a frame's data
/// to the header describing it, so a file that repeats or reorders numbers is
/// a file that can make a decoder draw one frame's pixels into another
/// frame's rectangle. It is checked on every chunk.
///
/// **Whether the default image is part of the animation is not a field.** It
/// is carried by whether an `fcTL` came before the `IDAT`: with one, the
/// `IDAT` is frame zero; without one, the `IDAT` is a still picture for
/// readers that do not know APNG and the animation is the `fdAT` frames
/// alone. Getting that backwards drops or duplicates a frame.
pub const Animation = struct {
    decoder: Decoder,
    r: *Io.Reader,
    opts: anim.Options,
    canvas: ?anim.Canvas,
    held: ?anim.Frame = null,
    index: u32 = 0,
    total_pixels: u64 = 0,
    /// The next `fcTL`/`fdAT` sequence number expected.
    sequence: u32 = 0,
    stage: Stage = .at_idat,
    /// A chunk header read and not yet acted on.
    pending: ?IdatReader.Pending = null,

    const Stage = enum { at_idat, in_frames, ended };

    pub fn init(r: *Io.Reader, gpa: Allocator, opts: anim.Options) DecodeError!Animation {
        var decoder: Decoder = try .init(r, opts.limits, null);
        const surface_type = opts.surface_type orelse decoder.info().surface_type;

        // The `fcTL` before the `IDAT`, if there was one, is sequence zero.
        var sequence: u32 = 0;
        if (decoder.actl != null) if (decoder.first_fctl) |f| {
            if (f.sequence != 0) return error.InvalidData;
            sequence = 1;
        };

        var canvas: ?anim.Canvas = null;
        if (opts.composite) {
            canvas = try anim.Canvas.init(
                gpa,
                surface_type,
                decoder.header.width,
                decoder.header.height,
            );
        }
        return .{
            .decoder = decoder,
            .r = r,
            .opts = opts,
            .canvas = canvas,
            .sequence = sequence,
        };
    }

    pub fn deinit(self: *Animation, gpa: Allocator) void {
        if (self.held) |*f| f.surface.deinit(gpa);
        if (self.canvas) |*c| c.deinit();
        self.* = undefined;
    }

    pub fn info(self: *const Animation) anim.Info {
        if (self.decoder.actl) |a| {
            // APNG already counts plays, which is what `anim.Info` means, so
            // nothing is converted --- unlike GIF, where it must be.
            return .{ .loop_count = a.plays, .frames = a.frames };
        }
        return .{ .loop_count = 1, .frames = 1 };
    }

    pub fn canvasSurface(self: *const Animation) ?*const z2d.Surface {
        if (self.canvas) |*c| return &c.surface;
        return null;
    }

    pub fn next(self: *Animation, gpa: Allocator) DecodeError!?anim.Frame {
        if (self.held) |*f| {
            f.surface.deinit(gpa);
            self.held = null;
        }
        if (self.stage == .ended) return null;
        if (self.index >= self.opts.limits.max_frames) return error.ImageTooLarge;

        var frame = try self.readFrame(gpa) orelse {
            self.stage = .ended;
            // The count `acTL` declared has to be the count that arrived. A
            // file that disagrees with itself about how many frames it has is
            // one where something has been removed or added since it was
            // written.
            if (self.decoder.actl) |a| {
                if (a.frames != self.index) return error.InvalidData;
            }
            return null;
        };
        errdefer frame.surface.deinit(gpa);

        const area = @as(u64, @intCast(frame.surface.getWidth())) *
            @as(u64, @intCast(frame.surface.getHeight()));
        self.total_pixels += area;
        if (self.total_pixels > self.opts.limits.max_total_pixels) return error.ImageTooLarge;

        if (self.canvas) |*c| try c.draw(frame);

        frame.index = self.index;
        self.index += 1;
        self.held = frame;
        return frame;
    }

    /// The next frame's pixels and geometry, or null at the end.
    fn readFrame(self: *Animation, gpa: Allocator) DecodeError!?anim.Frame {
        if (self.stage == .at_idat) {
            self.stage = .in_frames;
            if (self.decoder.actl == null or self.decoder.first_fctl != null) {
                // A plain PNG, whose one frame is its image; or an APNG whose
                // default image is frame zero.
                return try self.readIdatFrame(gpa);
            }
            // The default image is not part of the animation. It still has to
            // be walked past, checksums and all, to reach the `fdAT`s behind
            // it --- but nothing is inflated, because nothing will look at it.
            try self.skipIdat();
        }

        // `fcTL`, then the `fdAT`s it describes.
        while (true) {
            const entry = try self.nextChunk() orelse return null;
            var chunk = entry.chunk;
            var crc = entry.crc;

            if (chunk.is("IEND")) {
                if (chunk.len != 0) return error.InvalidData;
                var chunks: ChunkReader = .{ .r = self.r };
                try chunks.verify(&crc);
                return null;
            }
            // `acTL` is what makes a PNG an APNG. Without one the frame
            // chunks are not frame chunks --- they are ancillary chunks this
            // decoder does not recognise, exactly as they are to a reader
            // that never heard of APNG --- and they are skipped below like
            // any other. Honouring them anyway would have `probe`, which sees
            // the missing `acTL` and says the file does not animate,
            // contradicted by a decode that played frames out of it.
            if (chunk.is("fcTL") and self.decoder.actl != null) {
                if (chunk.len != Fctl.len) return error.InvalidData;
                var buf: [Fctl.len]u8 = undefined;
                var chunks: ChunkReader = .{ .r = self.r };
                try chunks.read(chunk, &crc, &buf);
                const fctl = try Fctl.parse(&buf);
                if (fctl.sequence != self.sequence) return error.InvalidData;
                self.sequence += 1;
                return try self.readFdatFrame(gpa, fctl);
            }
            // An `fdAT` with no `fcTL` in front of it is data for a frame
            // nothing described --- in a file that is an APNG at all.
            if (chunk.is("fdAT") and self.decoder.actl != null) return error.InvalidData;
            if (chunk.is("IDAT")) return error.InvalidData;
            if (!chunk.isAncillary()) return error.Unsupported;
            if (chunk.len > 1 << 24) return error.InvalidData;
            var chunks: ChunkReader = .{ .r = self.r };
            try chunks.skip(chunk, &crc);
        }
    }

    /// A chunk header, either one already read or the next from the stream.
    ///
    /// Running out is an error rather than an ending. PNG has a checksum on
    /// every chunk and an `IEND` to say the file is all there, and the still
    /// decoder refuses a file that stops before one --- so the animated
    /// reader refuses it too, rather than handing back the frames that
    /// happened to arrive and letting the two entry points disagree about
    /// whether the same file is broken. GIF, which has neither a checksum nor
    /// a way to tell a truncated file from a short one, keeps what it read.
    fn nextChunk(self: *Animation) DecodeError!?IdatReader.Pending {
        if (self.pending) |p| {
            self.pending = null;
            return p;
        }
        var chunks: ChunkReader = .{ .r = self.r };
        const chunk, const crc = chunks.next() catch |err| switch (err) {
            error.EndOfStream => return error.InvalidData,
            else => |e| return e,
        };
        return .{ .chunk = chunk, .crc = crc };
    }

    /// The `IDAT` image, as a frame.
    fn readIdatFrame(self: *Animation, gpa: Allocator) DecodeError!anim.Frame {
        var sfc = try self.newSurface(gpa, self.decoder.header.width, self.decoder.header.height);
        errdefer sfc.deinit(gpa);
        self.pending = try self.inflateInto(
            gpa,
            &sfc,
            self.decoder.header,
            "IDAT",
            self.decoder.first,
            self.decoder.first_crc,
        );

        // Only an APNG's `fcTL` says anything. In a file with no `acTL` the
        // chunk is one this decoder does not recognise, and the frame it
        // describes is not a frame.
        const fctl = if (self.decoder.actl == null) null else self.decoder.first_fctl;
        return .{
            .surface = sfc,
            .x = 0,
            .y = 0,
            .width = self.decoder.header.width,
            .height = self.decoder.header.height,
            .delay_ms = if (fctl) |f| f.delayMs() else 0,
            .dispose = if (fctl) |f| f.dispose else .keep,
            // Frame zero has nothing underneath it, so `over` and `source`
            // come to the same thing --- but a file may still say either, and
            // saying what it said is cheaper than explaining why it does not
            // matter.
            .blend = if (fctl) |f| f.blend else .source,
            .index = 0,
        };
    }

    /// A frame whose pixels are in `fdAT` chunks.
    fn readFdatFrame(self: *Animation, gpa: Allocator, fctl: Fctl) DecodeError!anim.Frame {
        if (fctl.width == 0 or fctl.height == 0) return error.InvalidData;
        // A frame has to fit the canvas. APNG says so outright, unlike GIF,
        // where files that break the rule are common enough that this library
        // clips instead --- so here the rule can simply be enforced, and a
        // frame is never larger than the image `probe` already checked.
        if (fctl.x > self.decoder.header.width or
            fctl.y > self.decoder.header.height or
            fctl.width > self.decoder.header.width - fctl.x or
            fctl.height > self.decoder.header.height - fctl.y) return error.InvalidData;

        const entry = try self.nextChunk() orelse return error.InvalidData;
        if (!entry.chunk.is("fdAT")) return error.InvalidData;

        var header = self.decoder.header;
        header.width = fctl.width;
        header.height = fctl.height;

        var sfc = try self.newSurface(gpa, fctl.width, fctl.height);
        errdefer sfc.deinit(gpa);
        self.pending = try self.inflateInto(gpa, &sfc, header, "fdAT", entry.chunk, entry.crc);

        return .{
            .surface = sfc,
            .x = @intCast(fctl.x),
            .y = @intCast(fctl.y),
            .width = fctl.width,
            .height = fctl.height,
            .delay_ms = fctl.delayMs(),
            .dispose = fctl.dispose,
            .blend = fctl.blend,
            .index = self.index,
        };
    }

    fn newSurface(self: *Animation, gpa: Allocator, width: u32, height: u32) DecodeError!z2d.Surface {
        const surface_type = self.opts.surface_type orelse self.decoder.info().surface_type;
        return z2d.Surface.init(
            surface_type,
            gpa,
            @intCast(width),
            @intCast(height),
        ) catch |err| switch (err) {
            error.InvalidWidth, error.InvalidHeight => return error.InvalidData,
            error.OutOfMemory => |e| return e,
        };
    }

    /// Inflates one stream of image data into `sfc`, and returns the chunk
    /// header that ended it.
    fn inflateInto(
        self: *Animation,
        gpa: Allocator,
        sfc: *z2d.Surface,
        header: Header,
        kind: *const [4]u8,
        first: Chunk,
        first_crc: Crc32,
    ) DecodeError!IdatReader.Pending {
        const idat_buffer = try gpa.alloc(u8, 4096);
        defer gpa.free(idat_buffer);
        var idat: IdatReader = .init(
            self.r,
            kind,
            first,
            first_crc,
            idat_buffer,
            if (mem.eql(u8, kind, "fdAT")) &self.sequence else null,
        );
        // The first chunk's sequence number, which `advance` takes for every
        // one after it.
        try idat.takeSequence();

        const window = try gpa.alloc(u8, flate.max_window_len);
        defer gpa.free(window);
        var inflate: flate.Decompress = .init(&idat.interface, .zlib, window);

        var ctx: Pass = .{
            .header = header,
            .palette = &self.decoder.palette,
            .palette_len = self.decoder.palette_len,
            .transparency = self.decoder.transparency,
            .input = &inflate.reader,
            .idat = &idat,
        };

        switch (header.interlace) {
            .none => try ctx.run(gpa, sfc, 0, 0, 1, 1, header.width, header.height),
            .adam7 => for (0..7) |pass| {
                const w = adam7.width(pass, header.width);
                const h = adam7.height(pass, header.height);
                if (w == 0 or h == 0) continue;
                try ctx.run(
                    gpa,
                    sfc,
                    adam7.col_start[pass],
                    adam7.row_start[pass],
                    adam7.col_step[pass],
                    adam7.row_step[pass],
                    w,
                    h,
                );
            },
            _ => unreachable, // refused in `init`
        }
        return idat.stop();
    }

    /// Walks past the default image without inflating it, for an APNG whose
    /// `IDAT` is not one of its frames.
    fn skipIdat(self: *Animation) DecodeError!void {
        var chunks: ChunkReader = .{ .r = self.r };
        var chunk = self.decoder.first;
        var crc = self.decoder.first_crc;
        while (true) {
            try chunks.skip(chunk, &crc);
            const next_chunk, const next_crc = try chunks.next();
            if (!next_chunk.is("IDAT")) {
                self.pending = .{ .chunk = next_chunk, .crc = next_crc };
                return;
            }
            chunk = next_chunk;
            crc = next_crc;
        }
    }
};

/// Reads a PNG as an animation.
pub fn animate(gpa: Allocator, r: *Io.Reader, opts: anim.Options) DecodeError!Animation {
    return Animation.init(r, gpa, opts);
}

// -- writing an animation ----------------------------------------------------

/// How to write an APNG.
pub const EncodeAnimationOptions = struct {
    /// The canvas every frame is placed on.
    width: u32,
    height: u32,

    /// How many frames will be written.
    ///
    /// Declared up front, and checked by `finish`, because `acTL` carries the
    /// count and has to precede `IDAT`. A sans-I/O encoder writes forward
    /// into something it cannot seek, so a number written early cannot be
    /// revised later --- and buffering the whole file to avoid asking for one
    /// number would give up the thing that makes this library streamable.
    frames: u32,

    /// How many times to play, zero for forever. APNG's own meaning, which is
    /// `anim.Info.loop_count`'s, so nothing is converted.
    loop_count: u32 = 0,

    level: Level = .default,
    filter: FilterChoice = .adaptive,
};

/// Writes an APNG a frame at a time.
///
/// Frames are written **as they are given**: the rectangle, delay, disposal
/// and blend on each `anim.Frame` are what goes in its `fcTL`. Nothing is
/// analysed and nothing is optimised, which is what makes a decode and an
/// encode a lossless pipe --- an animation transcoded through this keeps the
/// sub-rectangles the original had rather than being expanded to full frames.
///
/// The surface's own size is what is written, not `anim.Frame.width` and
/// `.height`; those record what a *file* declared, which for a frame clipped
/// on the way in is not the same thing and is not what is being written out.
pub const AnimationEncoder = struct {
    w: *Io.Writer,
    opts: EncodeAnimationOptions,
    /// Decided by the first frame, and every frame after it has to agree:
    /// one `IHDR` describes them all.
    colour: ColourType = undefined,
    /// The shared `fcTL`/`fdAT` counter.
    sequence: u32 = 0,
    written: u32 = 0,
    /// Whether the header and the default image have gone out.
    started: bool = false,

    pub fn init(w: *Io.Writer, opts: EncodeAnimationOptions) EncodeError!AnimationEncoder {
        if (opts.width == 0 or opts.height == 0) return error.Unsupported;
        if (opts.width > math.maxInt(i32) or opts.height > math.maxInt(i32)) return error.Unsupported;
        if (opts.frames == 0) return error.Unsupported;
        return .{ .w = w, .opts = opts };
    }

    /// Writes one frame.
    pub fn frame(self: *AnimationEncoder, gpa: Allocator, f: anim.Frame) EncodeError!void {
        if (self.written == self.opts.frames) return error.Unsupported;

        const fw: u32 = @intCast(f.surface.getWidth());
        const fh: u32 = @intCast(f.surface.getHeight());
        if (fw == 0 or fh == 0) return error.Unsupported;
        if (f.x < 0 or f.y < 0) return error.Unsupported;
        const fx: u32 = @intCast(f.x);
        const fy: u32 = @intCast(f.y);
        // APNG says a frame has to fit, and this is the encoder: a file that
        // does not is one this would be choosing to write.
        if (fx > self.opts.width or fy > self.opts.height or
            fw > self.opts.width - fx or fh > self.opts.height - fy) return error.Unsupported;

        const colour = colourFor(&f.surface);

        if (!self.started) {
            self.colour = colour;
            try self.writeHeader();
            // The first frame is the default image when it covers the canvas,
            // which is what the format wants and what almost every animation
            // has. When it does not --- a first frame that is a patch, which
            // a GIF may well have --- a transparent default image goes in
            // first and every frame becomes an `fdAT` behind it. Both shapes
            // are APNG; this is the one the frames allow.
            const covers = fx == 0 and fy == 0 and
                fw == self.opts.width and fh == self.opts.height;
            if (covers) {
                try self.writeFctl(f, fw, fh, fx, fy);
                try self.writeImageData(gpa, &f.surface, "IDAT");
                self.started = true;
                self.written += 1;
                return;
            }
            try self.writeBlankDefault(gpa);
            self.started = true;
        }

        if (colour != self.colour) return error.Unsupported;
        try self.writeFctl(f, fw, fh, fx, fy);
        try self.writeImageData(gpa, &f.surface, "fdAT");
        self.written += 1;
    }

    /// Ends the file.
    pub fn finish(self: *AnimationEncoder) EncodeError!void {
        // A count declared and not delivered is a file that contradicts
        // itself, and this decoder refuses one on the way in --- so it must
        // not write one.
        if (self.written != self.opts.frames) return error.Unsupported;
        // Unreachable while `frames` may not be zero, but writing a file with
        // no image data at all would be worse than saying so.
        if (!self.started) return error.Unsupported;
        try writeChunk(self.w, "IEND", &.{});
    }

    /// Nothing to release; here so that both animation encoders are used the
    /// same way.
    pub fn deinit(self: *AnimationEncoder, gpa: Allocator) void {
        _ = gpa;
        self.* = undefined;
    }

    fn writeHeader(self: *AnimationEncoder) EncodeError!void {
        try self.w.writeAll(signature);

        var ihdr: [13]u8 = undefined;
        mem.writeInt(u32, ihdr[0..4], self.opts.width, .big);
        mem.writeInt(u32, ihdr[4..8], self.opts.height, .big);
        ihdr[8] = 8;
        ihdr[9] = @backingInt(self.colour);
        ihdr[10] = 0;
        ihdr[11] = 0;
        ihdr[12] = @backingInt(Interlace.none);
        try writeChunk(self.w, "IHDR", &ihdr);

        var actl: [8]u8 = undefined;
        mem.writeInt(u32, actl[0..4], self.opts.frames, .big);
        mem.writeInt(u32, actl[4..8], self.opts.loop_count, .big);
        try writeChunk(self.w, "acTL", &actl);
    }

    /// A transparent image the size of the canvas, for a file whose first
    /// frame does not cover it.
    fn writeBlankDefault(self: *AnimationEncoder, gpa: Allocator) EncodeError!void {
        var blank: z2d.Surface = z2d.Surface.init(
            pixels.naturalSurfaceType(true),
            gpa,
            @intCast(self.opts.width),
            @intCast(self.opts.height),
        ) catch |err| switch (err) {
            error.InvalidWidth, error.InvalidHeight => return error.Unsupported,
            error.OutOfMemory => |e| return e,
        };
        defer blank.deinit(gpa);
        // A new surface is zeroed, which is transparent black.
        try self.writeImageData(gpa, &blank, "IDAT");
    }

    fn writeFctl(
        self: *AnimationEncoder,
        f: anim.Frame,
        fw: u32,
        fh: u32,
        fx: u32,
        fy: u32,
    ) EncodeError!void {
        // The delay is a fraction, and the numerator is sixteen bits. A
        // thousandths denominator keeps milliseconds exact up to about a
        // minute; past that the unit drops to hundredths, which is what GIF
        // counts in anyway and is far finer than anything that long needs.
        const num: u16, const den: u16 = if (f.delay_ms <= math.maxInt(u16))
            .{ @intCast(f.delay_ms), 1000 }
        else
            .{ @intCast(@min(f.delay_ms / 10, math.maxInt(u16))), 100 };

        var fctl: [Fctl.len]u8 = undefined;
        mem.writeInt(u32, fctl[0..4], self.sequence, .big);
        mem.writeInt(u32, fctl[4..8], fw, .big);
        mem.writeInt(u32, fctl[8..12], fh, .big);
        mem.writeInt(u32, fctl[12..16], fx, .big);
        mem.writeInt(u32, fctl[16..20], fy, .big);
        mem.writeInt(u16, fctl[20..22], num, .big);
        mem.writeInt(u16, fctl[22..24], den, .big);
        fctl[24] = switch (f.dispose) {
            .keep => 0,
            .background => 1,
            .previous => 2,
        };
        fctl[25] = switch (f.blend) {
            .source => 0,
            .over => 1,
        };
        try writeChunk(self.w, "fcTL", &fctl);
        self.sequence += 1;
    }

    /// One frame's pixels, as an `IDAT` or as an `fdAT`.
    fn writeImageData(
        self: *AnimationEncoder,
        gpa: Allocator,
        sfc: *const z2d.Surface,
        kind: *const [4]u8,
    ) EncodeError!void {
        const is_fdat = mem.eql(u8, kind, "fdAT");
        const row_bytes = @as(usize, @intCast(sfc.getWidth())) * self.colour.channels();

        var compressed: std.ArrayList(u8) = .empty;
        defer compressed.deinit(gpa);
        try compressed.ensureTotalCapacity(gpa, 4096);
        // An `fdAT` carries its sequence number in front of the stream, and
        // it is part of the chunk rather than of the data, so it goes in
        // before the compressor does.
        if (is_fdat) {
            var seq: [4]u8 = undefined;
            mem.writeInt(u32, &seq, self.sequence, .big);
            try compressed.appendSlice(gpa, &seq);
            self.sequence += 1;
        }

        {
            var out: Io.Writer.Allocating = .fromArrayList(gpa, &compressed);
            defer compressed = out.toArrayList();

            const window = try gpa.alloc(u8, flate.max_window_len);
            defer gpa.free(window);

            var deflate = flate.Compress.init(&out.writer, window, .zlib, self.opts.level.options()) catch
                return error.OutOfMemory;
            try writeScanlines(gpa, sfc, &deflate.writer, self.colour, row_bytes, self.opts.filter);
            deflate.finish() catch return error.OutOfMemory;
            out.writer.flush() catch return error.OutOfMemory;
        }

        if (compressed.items.len > math.maxInt(u32)) return error.Unsupported;
        try writeChunk(self.w, kind, compressed.items);
    }
};

/// The colour type a surface is written as, which is the one `encode` picks.
fn colourFor(sfc: *const z2d.Surface) ColourType {
    return switch (sfc.getFormat()) {
        .rgb, .xrgb => .truecolour,
        .argb, .rgba => .truecolour_alpha,
        .alpha8, .alpha4, .alpha2, .alpha1 => .greyscale_alpha,
    };
}

/// Begins an APNG.
pub fn encodeAnimation(w: *Io.Writer, opts: EncodeAnimationOptions) EncodeError!AnimationEncoder {
    return AnimationEncoder.init(w, opts);
}
