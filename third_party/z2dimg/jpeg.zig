// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! JFIF/JPEG.
//!
//! The third format here and much the largest, because it is the only one that
//! is genuinely a *compression* format rather than a container around pixels.
//! BMP stores samples. PNG predicts a sample from its neighbours and deflates
//! the difference. JPEG throws information away: it converts to a colour space
//! where the eye is least sensitive to what is about to be lost, discards
//! three quarters of the colour resolution, transforms each eight-by-eight
//! block into frequencies, divides those by a table chosen to zero the ones
//! nobody will miss, and Huffman-codes what is left.
//!
//! Decoding is all of that backwards, and this module is organised in the same
//! order:
//!
//! ```text
//!   markers        SOI, DQT, DHT, SOFn, SOS, DRI, EOI     this file
//!   entropy        canonical Huffman over a stuffed stream  jpeg/huffman.zig
//!   coefficients   one 8×8 block of frequencies per unit    this file
//!   dequantise     multiply back by the table               this file
//!   transform      frequencies to samples                   jpeg/idct.zig
//!   upsample       chroma back to full resolution           this file
//!   colour         YCbCr (or YCCK, or CMYK) to RGB          this file
//! ```
//!
//! ## What is read
//!
//! Baseline and extended sequential (`SOF0`, `SOF1`) and progressive (`SOF2`),
//! at eight bits per sample; greyscale, YCbCr, and four-component CMYK and
//! YCCK as Adobe writes them; any sampling factors, so 4:4:4, 4:2:2, 4:2:0 and
//! the unusual ones all work; restart intervals; and scans in any of the
//! arrangements the format allows, interleaved or not.
//!
//! What is refused, as `error.Unsupported`, is arithmetic coding (`SOF9`
//! onwards — patented until 2003, implemented by almost nobody, and still
//! rare), lossless and hierarchical modes, and twelve-bit samples.
//!
//! ## Progressive, and why the decoder holds coefficients
//!
//! A baseline JPEG could be decoded a block at a time and written straight
//! out. A progressive one cannot: its coefficients arrive across several
//! scans, a few bits of each at a time, and nothing can be transformed until
//! the last scan that touches it has been read. So the decoder keeps a
//! coefficient buffer per component and does the transform at the end.
//!
//! Doing that for baseline too is a deliberate choice. It costs memory —
//! `2 · samples` bytes of coefficients on top of the samples themselves —
//! and it means one code path where there would otherwise be two, with the
//! progressive one getting far less exercise. The alternative is a second
//! block loop that has to agree with the first about dequantisation, the
//! zig-zag order, restart handling and sampling factors, and that is exactly
//! the kind of duplication that rots.
//!
//! ## What is written
//!
//! Baseline sequential, eight bits, YCbCr with 4:4:4 or 4:2:0 chroma, using
//! the example Huffman tables from the specification's Annex K and the example
//! quantisation tables scaled by a quality setting. That is what almost every
//! JPEG in the world is, and it is what every decoder reads.

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

/// Huffman tables and the bit stream they are read from.
pub const huffman = @import("jpeg/huffman.zig");
/// The transform between frequencies and samples.
pub const idct = @import("jpeg/idct.zig");

/// Choosing coefficients by what they cost rather than by what is nearest.
pub const trellis = @import("jpeg/trellis.zig");

const exif = @import("exif.zig");
const icc = @import("icc.zig");

/// The side of a block. Everything in JPEG is eight by eight.
const block_size = idct.size;
/// Coefficients in a block.
const block_len = block_size * block_size;

/// The order coefficients are stored in, which is not raster order.
///
/// A block is written as a zig-zag from the top-left corner, so that the low
/// frequencies — the ones that carry most of the image — come first and the
/// high ones, which are usually zero after quantisation, end up in a run at
/// the end that the entropy coder can dismiss with a single end-of-block
/// symbol. This table gives the raster position of each zig-zag index.
const zigzag = [block_len]u8{
    0,  1,  8,  16, 9,  2,  3,  10,
    17, 24, 32, 25, 18, 11, 4,  5,
    12, 19, 26, 33, 40, 48, 41, 34,
    27, 20, 13, 6,  7,  14, 21, 28,
    35, 42, 49, 56, 57, 50, 43, 36,
    29, 22, 15, 23, 30, 37, 44, 51,
    58, 59, 52, 45, 38, 31, 39, 46,
    53, 60, 61, 54, 47, 55, 62, 63,
};

// -- markers -----------------------------------------------------------------

const Marker = struct {
    const soi = 0xd8;
    const eoi = 0xd9;
    const sos = 0xda;
    const dqt = 0xdb;
    const dnl = 0xdc;
    const dri = 0xdd;
    const sof0 = 0xc0;
    const sof2 = 0xc2;
    const dht = 0xc4;
    const dac = 0xcc;
    const app0 = 0xe0;
    const app1 = 0xe1;
    const app2 = 0xe2;
    const app14 = 0xee;
    const com = 0xfe;
    const tem = 0x01;

    fn isRestart(m: u8) bool {
        return m >= 0xd0 and m <= 0xd7;
    }

    /// Whether a marker begins a frame, and if so what kind.
    fn frameKind(m: u8) ?FrameKind {
        return switch (m) {
            0xc0 => .baseline,
            0xc1 => .extended,
            0xc2 => .progressive,
            // Lossless, hierarchical, and every arithmetic-coded variant.
            0xc3, 0xc5, 0xc6, 0xc7, 0xc9, 0xca, 0xcb, 0xcd, 0xce, 0xcf => .unsupported,
            else => null,
        };
    }

    /// Whether a marker stands alone, with no length and no payload.
    fn isStandalone(m: u8) bool {
        return isRestart(m) or m == soi or m == eoi or m == tem;
    }
};

const FrameKind = enum { baseline, extended, progressive, unsupported };

// -- the frame ---------------------------------------------------------------

/// One colour component of the image: a plane of samples at its own
/// resolution, and the tables used to code it.
const Component = struct {
    /// The identifier a scan header refers to it by.
    id: u8,
    /// Sampling factors, relative to the other components. A 4:2:0 image has
    /// luma at 2×2 and chroma at 1×1, which is to say the chroma planes are
    /// half the width and half the height.
    h: u32,
    v: u32,
    /// Which quantisation table dequantises it.
    quant: u8,

    /// The plane's size in blocks, rounded up to whole MCUs — a JPEG codes
    /// whole MCUs even when the image does not fill the last one, and the
    /// padding has to be decoded before it can be discarded.
    blocks_w: u32,
    blocks_h: u32,
    /// `blocks_w · blocks_h · 64` coefficients, in raster order of blocks and
    /// raster order within a block.
    coeffs: []i16,
    /// The plane's samples, after the transform: `blocks_w · 8` by
    /// `blocks_h · 8`.
    samples: []u8,

    /// Set while a scan is being read.
    dc_table: u8 = 0,
    ac_table: u8 = 0,
    dc_pred: i32 = 0,

    /// The width of the sample plane, which is a whole number of blocks and so
    /// usually wider than the part of it that holds image.
    fn stride(self: Component) usize {
        return @as(usize, self.blocks_w) * block_size;
    }
};

/// What `SOFn` said.
const Frame = struct {
    kind: FrameKind,
    width: u32,
    height: u32,
    components: [4]Component,
    n: usize,
    /// The largest sampling factors, which set the size of an MCU.
    hmax: u32,
    vmax: u32,
    mcus_x: u32,
    mcus_y: u32,
};

/// How the components should be read as colour.
///
/// JPEG itself says nothing about colour: it codes some number of components
/// and leaves what they mean to the application. In practice one component is
/// greyscale and three are YCbCr, and for four there is no answer without the
/// Adobe `APP14` marker, which is why it is the one application segment this
/// decoder reads.
const ColourSpace = enum { greyscale, ycbcr, rgb, cmyk, ycck };

// -- decoding ----------------------------------------------------------------

/// A JPEG part-read: the frame header has been found, the scans have not been
/// decoded.
pub const Decoder = struct {
    frame: Frame,
    colour: ColourSpace,
    limits: Limits,
    orientation: exif.Orientation,

    /// Reads as far as the frame header and stops.
    ///
    /// This is what `probe` is built on, and unlike `bmp.Decoder` and
    /// `png.Decoder` it is not half of a two-step decode: a JPEG's tables may
    /// appear before or after the frame header and a scan needs all of them,
    /// so stopping at `SOF` leaves a decoder holding some of what it will need
    /// and not knowing whether more is coming. `decode` makes its own single
    /// pass instead.
    pub fn init(r: *Io.Reader, limits: Limits) DecodeError!Decoder {
        var scanner: Scanner = .{ .r = r };
        try scanner.expectSoi();

        var adobe_transform: ?u8 = null;
        var orientation: ?exif.Orientation = null;
        while (true) {
            const marker = try scanner.nextMarker();
            if (Marker.frameKind(marker)) |kind| {
                if (kind == .unsupported) return error.Unsupported;
                const frame = try scanner.readFrameHeader(kind, limits);
                return .{
                    .frame = frame,
                    .colour = colourSpaceFor(frame, adobe_transform),
                    .limits = limits,
                    .orientation = orientation orelse .top_left,
                };
            }
            switch (marker) {
                Marker.eoi, Marker.sos => return error.InvalidData, // no frame
                Marker.dac => return error.Unsupported, // arithmetic coding
                Marker.app14 => adobe_transform = try scanner.readAdobe(),
                // The first one that says anything wins, which is what a file
                // carrying both EXIF and XMP needs.
                Marker.app1 => orientation = orientation orelse try scanner.readExif(),
                else => {
                    if (Marker.isStandalone(marker)) continue;
                    try scanner.skipSegment();
                },
            }
        }
    }

    /// What the frame header said.
    ///
    /// A JPEG never has transparency: no mode of the format carries an alpha
    /// channel, so this is always opaque and always an `image_surface_rgb`
    /// unless the caller asks for something else.
    pub fn info(self: Decoder) Info {
        return .{
            .format = .jpeg,
            .width = self.frame.width,
            .height = self.frame.height,
            .has_alpha = false,
            .surface_type = pixels.naturalSurfaceType(false),
            .orientation = self.orientation,
        };
    }
};

/// Walks the marker structure of a file.
const Scanner = struct {
    r: *Io.Reader,

    fn expectSoi(self: *Scanner) DecodeError!void {
        const a = try self.r.takeByte();
        const b = try self.r.takeByte();
        if (a != 0xff or b != Marker.soi) return error.UnknownFormat;
    }

    /// The next marker, skipping the fill bytes that may precede one.
    fn nextMarker(self: *Scanner) DecodeError!u8 {
        // A marker is 0xFF followed by a byte that is neither 0x00 nor 0xFF;
        // any number of 0xFF fill bytes may come first.
        while (true) {
            const b = try self.r.takeByte();
            if (b != 0xff) continue; // padding between segments, which exists
            while (true) {
                const m = try self.r.takeByte();
                if (m == 0xff) continue;
                if (m == 0x00) break; // a stuffed byte outside a scan: ignore
                return m;
            }
        }
    }

    /// A segment's length, which counts itself.
    fn segmentLen(self: *Scanner) DecodeError!usize {
        const len = try self.r.takeInt(u16, .big);
        if (len < 2) return error.InvalidData;
        return len - 2;
    }

    fn skipSegment(self: *Scanner) DecodeError!void {
        const len = try self.segmentLen();
        try self.r.discardAll(len);
    }

    /// The Adobe `APP14` marker, whose last byte says how four components are
    /// to be read.
    fn readAdobe(self: *Scanner) DecodeError!?u8 {
        const len = try self.segmentLen();
        if (len < 12) {
            try self.r.discardAll(len);
            return null;
        }
        var head: [11]u8 = undefined;
        try self.r.readSliceAll(&head);
        const transform = try self.r.takeByte();
        try self.r.discardAll(len - 12);
        if (!mem.eql(u8, head[0..5], "Adobe")) return null;
        return transform;
    }

    /// `APP1`, which is where EXIF lives when a JPEG has any.
    ///
    /// An `APP1` may equally be XMP, which is why the block is handed to
    /// `exif` with its `Exif\0\0` marker still on it rather than being
    /// identified here.
    fn readExif(self: *Scanner) DecodeError!?exif.Orientation {
        const len = try self.segmentLen();
        return exif.readOrientation(self.r, @intCast(len));
    }

    /// `APP2`, which is where a piece of an ICC profile lives when a JPEG
    /// carries one.
    ///
    /// The segment is consumed whatever it holds; an `APP2` that is not part
    /// of a profile is simply not one this cares about.
    fn readIcc(
        self: *Scanner,
        gpa: Allocator,
        out: *std.ArrayList(u8),
        assembler: *icc.Assembler,
        limit: u64,
    ) DecodeError!void {
        const len = try self.segmentLen();
        if (len < icc.jpeg_marker.len) {
            try self.r.discardAll(len);
            return;
        }
        var head: [icc.jpeg_marker.len]u8 = undefined;
        try self.r.readSliceAll(&head);
        var left = len - icc.jpeg_marker.len;
        if (!mem.eql(u8, &head, icc.jpeg_marker)) {
            try self.r.discardAll(left);
            return;
        }

        // The rest of the segment is a piece number, a count, and profile.
        // Read in bounded steps rather than in one allocation, so that a
        // length field cannot ask for memory before the limit has seen it.
        var payload: std.ArrayList(u8) = .empty;
        defer payload.deinit(gpa);
        var buf: [4096]u8 = undefined;
        while (left > 0) {
            const n = @min(left, buf.len);
            try self.r.readSliceAll(buf[0..n]);
            try payload.appendSlice(gpa, buf[0..n]);
            left -= n;
        }
        _ = try assembler.take(gpa, out, payload.items, limit);
    }

    /// `SOFn`: the size of the image and the components it is made of.
    fn readFrameHeader(self: *Scanner, kind: FrameKind, limits: Limits) DecodeError!Frame {
        const len = try self.segmentLen();
        if (len < 6) return error.InvalidData;

        const precision = try self.r.takeByte();
        // Twelve-bit JPEG is legal, rare, and would need a second path through
        // dequantisation and the transform for the sake of almost no files.
        if (precision != 8) return error.Unsupported;

        const height = try self.r.takeInt(u16, .big);
        const width = try self.r.takeInt(u16, .big);
        const n = try self.r.takeByte();
        if (n == 0 or n > 4) return error.Unsupported;
        if (len != 6 + @as(usize, n) * 3) return error.InvalidData;

        // A height of zero means "to be given later", in a `DNL` segment after
        // the first scan. Almost nothing writes it and supporting it would
        // mean deferring every allocation; refusing is honest.
        if (height == 0) return error.Unsupported;
        try limits.check(width, height);

        var frame: Frame = .{
            .kind = kind,
            .width = width,
            .height = height,
            .components = undefined,
            .n = n,
            .hmax = 1,
            .vmax = 1,
            .mcus_x = 0,
            .mcus_y = 0,
        };

        for (0..n) |i| {
            const id = try self.r.takeByte();
            const sampling = try self.r.takeByte();
            const quant = try self.r.takeByte();
            const h: u32 = sampling >> 4;
            const v: u32 = sampling & 0x0f;
            // The format allows one to four in each direction. Zero would mean
            // a plane with no samples in it.
            if (h < 1 or h > 4 or v < 1 or v > 4) return error.InvalidData;
            if (quant > 3) return error.InvalidData;
            for (frame.components[0..i]) |prev| {
                if (prev.id == id) return error.InvalidData; // two of the same
            }
            frame.components[i] = .{
                .id = id,
                .h = h,
                .v = v,
                .quant = quant,
                .blocks_w = 0,
                .blocks_h = 0,
                .coeffs = &.{},
                .samples = &.{},
            };
            frame.hmax = @max(frame.hmax, h);
            frame.vmax = @max(frame.vmax, v);
        }

        // An MCU is `hmax` by `vmax` blocks of the most finely sampled
        // component, which is to say one block of it from each component at
        // that component's own resolution.
        const mcu_w = frame.hmax * block_size;
        const mcu_h = frame.vmax * block_size;
        frame.mcus_x = (width + mcu_w - 1) / mcu_w;
        frame.mcus_y = (height + mcu_h - 1) / mcu_h;

        for (frame.components[0..n]) |*c| {
            c.blocks_w = frame.mcus_x * c.h;
            c.blocks_h = frame.mcus_y * c.v;
        }

        return frame;
    }
};

/// How to read the components as colour, from the number of them and whatever
/// the Adobe marker said.
fn colourSpaceFor(frame: Frame, adobe_transform: ?u8) ColourSpace {
    return switch (frame.n) {
        1 => .greyscale,
        3 => blk: {
            // Adobe's marker can say a three-component image is untransformed
            // RGB. Without it, the component identifiers are the only hint,
            // and 'R', 'G', 'B' is the convention.
            if (adobe_transform) |t| break :blk if (t == 0) .rgb else .ycbcr;
            if (frame.components[0].id == 'R' and
                frame.components[1].id == 'G' and
                frame.components[2].id == 'B') break :blk .rgb;
            break :blk .ycbcr;
        },
        4 => blk: {
            // Four components without the marker is ambiguous, and Adobe is
            // the only thing that writes four, so its answer is the answer.
            if (adobe_transform) |t| break :blk if (t == 2) .ycck else .cmyk;
            break :blk .cmyk;
        },
        else => .greyscale,
    };
}

/// Everything a decode accumulates as it walks the file.
const State = struct {
    gpa: Allocator,
    frame: ?Frame = null,
    colour: ColourSpace = .greyscale,
    /// Up to four quantisation tables, in zig-zag order as the file stores
    /// them.
    quant: [4][block_len]u16 = @splat(@splat(0)),
    quant_seen: [4]bool = @splat(false),
    dc_tables: [4]?huffman.Table = @splat(null),
    ac_tables: [4]?huffman.Table = @splat(null),
    /// `DRI`: how many units between restart markers, or zero for none.
    restart_interval: u32 = 0,
    /// Progressive AC scans code runs of blocks that are finished; this is how
    /// many are left in the current run.
    eobrun: u32 = 0,

    fn deinit(self: *State) void {
        if (self.frame) |*f| {
            for (f.components[0..f.n]) |*c| {
                self.gpa.free(c.coeffs);
                self.gpa.free(c.samples);
            }
        }
    }

    /// Allocates the coefficient and sample planes, once the frame header has
    /// been read and checked.
    fn allocate(self: *State, limits: Limits) DecodeError!void {
        const f = &self.frame.?;
        for (f.components[0..f.n]) |*c| {
            const blocks = @as(u64, c.blocks_w) * c.blocks_h;
            const samples = blocks * block_len;
            // The padding a JPEG codes beyond the edge of the image is part of
            // what has to be held, so the budget is checked against the padded
            // size rather than the image's own.
            //
            // Saturating, because `Limits.unlimited` sets `max_pixels` to the
            // largest `u64` there is and four times that is not a number. An
            // ordinary multiply here panicked on every JPEG, valid ones
            // included, for any caller who asked for no limits --- which is a
            // crash in whatever opened the file, and the one thing a decoder
            // must never do.
            if (samples > limits.max_pixels *| 4) return error.ImageTooLarge;
            const n = math.cast(usize, samples) orelse return error.ImageTooLarge;
            c.coeffs = try self.gpa.alloc(i16, n);
            @memset(c.coeffs, 0);
            c.samples = try self.gpa.alloc(u8, n);
            @memset(c.samples, 128);
        }
    }
};

/// `DQT`: one or more quantisation tables.
fn readQuantTables(scanner: *Scanner, state: *State) DecodeError!void {
    var left = try scanner.segmentLen();
    while (left > 0) {
        // The precision-and-identifier byte, and then a whole table.
        if (left < 1 + block_len) return error.InvalidData;

        const pq_tq = try scanner.r.takeByte();
        left -= 1;
        const precision = pq_tq >> 4;
        const id = pq_tq & 0x0f;
        if (id > 3) return error.InvalidData;

        const entry_len: usize = if (precision == 0) 1 else if (precision == 1) 2 else return error.InvalidData;
        if (left < block_len * entry_len) return error.InvalidData;
        for (0..block_len) |i| {
            state.quant[id][i] = if (precision == 0)
                try scanner.r.takeByte()
            else
                try scanner.r.takeInt(u16, .big);
        }
        state.quant_seen[id] = true;
        left -= block_len * entry_len;
    }
}

/// `DHT`: one or more Huffman tables.
fn readHuffmanTables(scanner: *Scanner, state: *State) DecodeError!void {
    var left = try scanner.segmentLen();
    while (left > 0) {
        // One byte of class and identifier, then sixteen counts, before a
        // single symbol has been read. A segment that declares less than that
        // is malformed, and checking here is what keeps the subtractions below
        // from running backwards off zero — `left` is a `usize`, so an
        // underflow is not a small negative number but an enormous positive
        // one, and the read it then authorises is the whole bug.
        if (left < 17) return error.InvalidData;

        const tc_th = try scanner.r.takeByte();
        left -= 1;
        const class = tc_th >> 4;
        const id = tc_th & 0x0f;
        if (id > 3 or class > 1) return error.InvalidData;

        var counts: [16]u8 = undefined;
        try scanner.r.readSliceAll(&counts);
        left -= 16;

        var total: usize = 0;
        for (counts) |c| total += c;
        if (total > 256 or left < total) return error.InvalidData;

        var values: [256]u8 = undefined;
        try scanner.r.readSliceAll(values[0..total]);
        left -= total;

        const table = huffman.Table.init(&counts, values[0..total]) catch |err| switch (err) {
            error.InvalidData => return error.InvalidData,
            error.ReadFailed => return error.ReadFailed,
        };
        if (class == 0) state.dc_tables[id] = table else state.ac_tables[id] = table;
    }
}

/// Reads the entropy-coded data of one scan.
fn decodeScan(
    state: *State,
    frame: *Frame,
    order: []const usize,
    bits: *huffman.BitReader,
    ss: u8,
    se: u8,
    ah: u5,
    al: u5,
) DecodeError!void {
    const interleaved = order.len > 1;

    // How many units this scan is made of, and what a unit is. Interleaved,
    // a unit is an MCU and covers a block of every component; on its own, a
    // unit is one block of the one component, and the traversal is that
    // component's own raster order over only the blocks the image reaches —
    // not the padding that fills out the last MCU.
    var units_x: u32 = undefined;
    var units_y: u32 = undefined;
    if (interleaved) {
        units_x = frame.mcus_x;
        units_y = frame.mcus_y;
    } else {
        const c = frame.components[order[0]];
        const w = (frame.width * c.h + frame.hmax - 1) / frame.hmax;
        const h = (frame.height * c.v + frame.vmax - 1) / frame.vmax;
        units_x = (w + block_size - 1) / block_size;
        units_y = (h + block_size - 1) / block_size;
    }

    var restart_left = state.restart_interval;
    var unit: u64 = 0;
    const total = @as(u64, units_x) * units_y;

    var y: u32 = 0;
    while (y < units_y) : (y += 1) {
        var x: u32 = 0;
        while (x < units_x) : (x += 1) {
            if (interleaved) {
                for (order) |k| {
                    const c = &frame.components[k];
                    var by: u32 = 0;
                    while (by < c.v) : (by += 1) {
                        var bx: u32 = 0;
                        while (bx < c.h) : (bx += 1) {
                            const block_x = x * c.h + bx;
                            const block_y = y * c.v + by;
                            try decodeBlock(state, c, bits, block_x, block_y, ss, se, ah, al);
                        }
                    }
                }
            } else {
                const c = &frame.components[order[0]];
                try decodeBlock(state, c, bits, x, y, ss, se, ah, al);
            }

            unit += 1;
            if (state.restart_interval != 0 and unit < total) {
                restart_left -= 1;
                if (restart_left == 0) {
                    restart_left = state.restart_interval;
                    try restart(state, frame, order, bits);
                }
            }
        }
    }
}

/// Handles the marker between two restart intervals.
///
/// Each interval is independently decodable: it begins on a byte boundary,
/// with the DC predictors reset and any end-of-block run abandoned. That is
/// the whole point of restart markers — a corrupt interval costs one interval
/// rather than the rest of the image.
fn restart(state: *State, frame: *Frame, order: []const usize, bits: *huffman.BitReader) DecodeError!void {
    bits.alignToByte();

    // The marker may already have been met by the bit reader running off the
    // end of the interval's data, or may still be in the stream.
    if (bits.marker) |m| {
        if (!Marker.isRestart(m)) return; // the scan has ended early
        bits.marker = null;
    } else {
        const a = bits.source.takeByte() catch |err| switch (err) {
            error.EndOfStream => return,
            error.ReadFailed => |e| return e,
        };
        if (a != 0xff) return error.InvalidData;
        const m = bits.source.takeByte() catch |err| switch (err) {
            error.EndOfStream => return,
            error.ReadFailed => |e| return e,
        };
        if (!Marker.isRestart(m)) return error.InvalidData;
    }

    for (order) |k| frame.components[k].dc_pred = 0;
    state.eobrun = 0;
}

/// Reads whatever this scan has to say about one block.
fn decodeBlock(
    state: *State,
    c: *Component,
    bits: *huffman.BitReader,
    block_x: u32,
    block_y: u32,
    ss: u8,
    se: u8,
    ah: u5,
    al: u5,
) DecodeError!void {
    // A scan may address blocks outside the plane when the image does not fill
    // its last MCU. Those still have to be *decoded*, because the bits are
    // there, but there is nowhere to put them.
    const in_range = block_x < c.blocks_w and block_y < c.blocks_h;
    var discard: [block_len]i16 = @splat(0);
    const block: *[block_len]i16 = if (in_range)
        c.coeffs[(@as(usize, block_y) * c.blocks_w + block_x) * block_len ..][0..block_len]
    else
        &discard;

    const dc = &(state.dc_tables[c.dc_table] orelse return error.InvalidData);

    if (ss == 0) {
        if (ah == 0) {
            // The DC coefficient, coded as a difference from the previous
            // block of the same component: a run of flat blocks costs almost
            // nothing.
            const t = try huffErr(bits.decode(dc));
            if (t > 15) return error.InvalidData;
            const diff = try huffErr(bits.receiveExtend(@intCast(t)));
            c.dc_pred +%= diff;
            block[0] = saturate(c.dc_pred << al);
        } else {
            // A progressive refinement scan: one more bit of the DC value.
            if (try huffErr(bits.takeBit()) != 0) {
                block[0] |= @as(i16, 1) << @intCast(al);
            }
        }
        if (se == 0) return;
    }

    if (ss == 0 and state.frame.?.kind != .progressive) {
        // Sequential: the DC above and then the whole AC spectrum, here.
        const ac = &(state.ac_tables[c.ac_table] orelse return error.InvalidData);
        var k: usize = 1;
        while (k < block_len) {
            const rs = try huffErr(bits.decode(ac));
            const size: u6 = @intCast(rs & 0x0f);
            const run: usize = rs >> 4;
            if (size == 0) {
                // A run of fifteen zeroes, or the end of the block.
                if (run != 15) break;
                k += 16;
                continue;
            }
            k += run;
            if (k >= block_len) return error.InvalidData;
            block[zigzag[k]] = saturate(try huffErr(bits.receiveExtend(size)));
            k += 1;
        }
        return;
    }

    if (ss == 0) return; // a progressive DC scan, already done

    // A progressive AC scan.
    const ac = &(state.ac_tables[c.ac_table] orelse return error.InvalidData);
    if (ah == 0) {
        try acFirst(state, block, bits, ac, ss, se, al);
    } else {
        try acRefine(state, block, bits, ac, ss, se, al);
    }
}

/// The first AC scan over a band: the coefficients themselves, shifted left by
/// whatever precision is still to come.
fn acFirst(
    state: *State,
    block: *[block_len]i16,
    bits: *huffman.BitReader,
    ac: *const huffman.Table,
    ss: u8,
    se: u8,
    al: u5,
) DecodeError!void {
    if (state.eobrun > 0) {
        state.eobrun -= 1;
        return;
    }
    var k: usize = ss;
    while (k <= se) {
        const rs = try huffErr(bits.decode(ac));
        const size: u6 = @intCast(rs & 0x0f);
        const run: usize = rs >> 4;
        if (size == 0) {
            if (run < 15) {
                // The end of this block, and of `2^run - 1` more after it.
                state.eobrun = (@as(u32, 1) << @intCast(run)) - 1;
                if (run != 0) state.eobrun += @intCast(try huffErr(bits.take(@intCast(run))));
                return;
            }
            k += 16;
            continue;
        }
        k += run;
        if (k > se) return error.InvalidData;
        const v = try huffErr(bits.receiveExtend(size));
        block[zigzag[k]] = saturate(v << al);
        k += 1;
    }
}

/// A later AC scan over a band: one more bit for every coefficient already
/// there, and the newly non-zero ones.
///
/// The awkward one. A refinement scan carries two interleaved things — the
/// positions of coefficients becoming non-zero at this precision, coded as
/// runs of zeroes exactly as in a first scan, and a correction bit for every
/// *already* non-zero coefficient passed on the way. The correction bits are
/// not in the Huffman stream at all; they are raw bits read as each such
/// coefficient is stepped over.
fn acRefine(
    state: *State,
    block: *[block_len]i16,
    bits: *huffman.BitReader,
    ac: *const huffman.Table,
    ss: u8,
    se: u8,
    al: u5,
) DecodeError!void {
    const positive: i16 = @as(i16, 1) << @intCast(al);
    const negative: i16 = -positive;
    var k: usize = ss;

    if (state.eobrun == 0) {
        while (k <= se) {
            const rs = try huffErr(bits.decode(ac));
            const size = rs & 0x0f;
            var run: i32 = rs >> 4;
            var value: i16 = 0;

            if (size == 0) {
                if (run < 15) {
                    state.eobrun = @as(u32, 1) << @intCast(run);
                    if (run != 0) state.eobrun += @intCast(try huffErr(bits.take(@intCast(run))));
                    break;
                }
                // Sixteen zero coefficients, counting only the ones that are
                // still zero.
            } else {
                // A refinement scan can only ever make a coefficient one
                // step away from zero.
                if (size != 1) return error.InvalidData;
                value = if (try huffErr(bits.takeBit()) != 0) positive else negative;
            }

            while (k <= se) {
                const at = &block[zigzag[k]];
                if (at.* != 0) {
                    // Already non-zero: a raw correction bit says whether this
                    // precision adds to it.
                    if (try huffErr(bits.takeBit()) != 0 and (at.* & positive) == 0) {
                        at.* +%= if (at.* >= 0) positive else negative;
                    }
                } else {
                    if (run == 0) {
                        if (value != 0) at.* = value;
                        k += 1;
                        break;
                    }
                    run -= 1;
                }
                k += 1;
            }
        }
    }

    if (state.eobrun > 0) {
        // Inside an end-of-block run: no new coefficients, but the ones
        // already there still take their correction bits.
        while (k <= se) : (k += 1) {
            const at = &block[zigzag[k]];
            if (at.* != 0) {
                if (try huffErr(bits.takeBit()) != 0 and (at.* & positive) == 0) {
                    at.* +%= if (at.* >= 0) positive else negative;
                }
            }
        }
        state.eobrun -= 1;
    }
}

/// Coefficients are held in sixteen bits, and a corrupt file can code a value
/// that does not fit. Clamping keeps the transform's input in the range it
/// expects rather than wrapping a bright block into a dark one.
fn saturate(v: i32) i16 {
    return @intCast(@max(math.minInt(i16), @min(math.maxInt(i16), v)));
}

/// Translates the bit reader's narrow error set into the codec's.
fn huffErr(result: anytype) DecodeError!@typeInfo(@TypeOf(result)).error_union.payload {
    return result catch |err| switch (err) {
        error.InvalidData => error.InvalidData,
        error.ReadFailed => error.ReadFailed,
    };
}

// -- from coefficients to pixels ---------------------------------------------

/// Dequantises every block and transforms it into samples.
fn reconstruct(state: *State) DecodeError!void {
    const f = &state.frame.?;
    for (f.components[0..f.n]) |*c| {
        if (!state.quant_seen[c.quant]) return error.InvalidData;

        // The quantisation table is stored in zig-zag order and the
        // coefficients in raster order, so it is reordered once here rather
        // than indirected through `zigzag` sixty-four times a block.
        var q: [block_len]u16 = undefined;
        for (zigzag, 0..) |raster, k| q[raster] = state.quant[c.quant][k];

        var dequantised: [block_len]i32 = undefined;
        var samples: [block_len]u8 = undefined;

        var by: u32 = 0;
        while (by < c.blocks_h) : (by += 1) {
            var bx: u32 = 0;
            while (bx < c.blocks_w) : (bx += 1) {
                const coeffs = c.coeffs[(@as(usize, by) * c.blocks_w + bx) * block_len ..][0..block_len];
                for (coeffs, q, &dequantised) |coeff, scale, *out| {
                    out.* = @as(i32, coeff) * @as(i32, scale);
                }
                idct.block(&dequantised, &samples);

                // Into the plane, a row of eight at a time.
                const stride = c.stride();
                const origin = @as(usize, by) * block_size * stride + @as(usize, bx) * block_size;
                for (0..block_size) |row| {
                    @memcpy(
                        c.samples[origin + row * stride ..][0..block_size],
                        samples[row * block_size ..][0..block_size],
                    );
                }
            }
        }
    }
}

/// Where an output pixel's sample comes from in a component plane, and how
/// much of the next one to mix with it.
const Tap = struct {
    index: u32,
    /// The weight of `index + 1`, in sixteenths of a sixteenth — 16.16 fixed
    /// point, so zero means take `index` alone.
    frac: u32,
    /// The neighbour, already clamped to the plane.
    next: u32,
};

/// Builds the taps for one axis of one component.
///
/// The mapping is the one that puts sample centres where they belong:
///
/// ```text
///   source = (out + ½) · sampling / max − ½
/// ```
///
/// which for an unsubsampled component is the identity, and for a halved one
/// gives the weights 3:1 and 1:3 alternately — exactly what libjpeg's
/// "fancy" upsampling computes, so a 4:2:0 image decoded here and by libjpeg
/// agree to within rounding rather than to within a chroma block.
///
/// Replication would be less code and is what a first version of this did. It
/// is also visibly worse: chroma follows the eight-pixel block grid, and on a
/// photograph the result is a faint quilting across every colour edge.
///
/// There is one case where the two deliberately part company. libjpeg only
/// takes its interpolating path when there are more than two chroma samples
/// across — `jdsample.c` guards it with `compptr->downsampled_width > 2` —
/// and replicates otherwise, because its edge handling needs a sample on each
/// side. That means an image four pixels wide or narrower is upsampled one way
/// there and another way here. Measured over a hundred and twenty randomly
/// generated JPEGs, every disagreement with libjpeg larger than six counts was
/// such an image, and there were none at all above that width. Matching the
/// fallback would make those few images blockier to no purpose; nothing about
/// chroma upsampling is normative, and this is the better answer for both.
fn buildTaps(gpa: Allocator, out_len: u32, sampling: u32, max: u32, plane_len: u32) Allocator.Error![]Tap {
    const taps = try gpa.alloc(Tap, out_len);
    const den: i64 = 2 * @as(i64, max);
    for (taps, 0..) |*t, x| {
        const num: i64 = (2 * @as(i64, @intCast(x)) + 1) * @as(i64, sampling) - @as(i64, max);
        const pos = @divFloor(num << 16, den);
        var i = pos >> 16;
        var frac: i64 = pos - (i << 16);
        // Off the left edge, or off the right: the outermost sample carries
        // the whole weight rather than being mixed with something that is not
        // there.
        if (i < 0) {
            i = 0;
            frac = 0;
        }
        if (i >= plane_len - 1) {
            i = plane_len - 1;
            frac = 0;
        }
        t.* = .{
            .index = @intCast(i),
            .frac = @intCast(frac),
            .next = @intCast(@min(i + 1, plane_len - 1)),
        };
    }
    return taps;
}

/// Writes the reconstructed planes into the surface, upsampling the
/// under-sampled ones and converting to colour.
fn emit(state: *State, sfc: *z2d.Surface, gpa: Allocator) DecodeError!void {
    const f = &state.frame.?;
    const row = try gpa.alloc(Rgba8, f.width);
    defer gpa.free(row);

    // The taps are the same for every row and every column, so they are built
    // once rather than divided for at each of the width × height pixels.
    var x_taps: [4][]Tap = @splat(&.{});
    var y_taps: [4][]Tap = @splat(&.{});
    defer for (x_taps, y_taps) |xt, yt| {
        gpa.free(xt);
        gpa.free(yt);
    };
    for (f.components[0..f.n], 0..) |c, i| {
        // The part of the plane that holds image, rather than the padding that
        // fills out the last MCU: interpolating into the padding would drag
        // the edge of the image towards whatever the encoder put there.
        const cw = (f.width * c.h + f.hmax - 1) / f.hmax;
        const ch = (f.height * c.v + f.vmax - 1) / f.vmax;
        x_taps[i] = try buildTaps(gpa, f.width, c.h, f.hmax, @max(1, cw));
        y_taps[i] = try buildTaps(gpa, f.height, c.v, f.vmax, @max(1, ch));
    }

    var y: u32 = 0;
    while (y < f.height) : (y += 1) {
        var x: u32 = 0;
        while (x < f.width) : (x += 1) {
            var s: [4]u8 = .{ 0, 0, 0, 0 };
            for (f.components[0..f.n], 0..) |c, i| {
                s[i] = sampleAt(c, x_taps[i][x], y_taps[i][y]);
            }
            row[x] = convert(state.colour, s);
        }
        pixels.writeRow(sfc, @intCast(y), row);
    }
}

/// One sample, bilinearly interpolated between the four the taps name.
fn sampleAt(c: Component, tx: Tap, ty: Tap) u8 {
    const stride = c.stride();
    const top = c.samples[@as(usize, ty.index) * stride ..];
    const bottom = c.samples[@as(usize, ty.next) * stride ..];

    const a: u64 = top[tx.index];
    const b: u64 = top[tx.next];
    const cc: u64 = bottom[tx.index];
    const d: u64 = bottom[tx.next];

    const fx: u64 = tx.frac;
    const fy: u64 = ty.frac;
    const one: u64 = 1 << 16;

    const upper = a * (one - fx) + b * fx;
    const lower = cc * (one - fx) + d * fx;
    const value = upper * (one - fy) + lower * fy;

    // Two rounds of 16.16, so 32 fractional bits to shift back off.
    return @intCast((value + (1 << 31)) >> 32);
}

/// One pixel's components, as colour.
fn convert(space: ColourSpace, s: [4]u8) Rgba8 {
    return switch (space) {
        .greyscale => .rgb(s[0], s[0], s[0]),
        .rgb => .rgb(s[0], s[1], s[2]),
        .ycbcr => ycbcr(s[0], s[1], s[2]),
        // Adobe writes CMYK inverted, so a stored sample is already
        // `255 - ink`, and the conversion is a plain multiply rather than the
        // subtractions the name suggests.
        .cmyk => .rgb(
            scaleBy(s[0], s[3]),
            scaleBy(s[1], s[3]),
            scaleBy(s[2], s[3]),
        ),
        // The same, with the first three components carried as YCbCr — but
        // the colour they encode is the *ink*, not the light. libjpeg's
        // `ycck_cmyk_convert` writes `MAXJSAMPLE - (y + Crrtab[cr])`, so
        // converting the YCbCr back gives a value that still has to be
        // complemented before it means what the stored samples of a
        // transform-0 file mean.
        .ycck => blk: {
            const c = ycbcr(s[0], s[1], s[2]);
            break :blk .rgb(
                scaleBy(255 - c.r, s[3]),
                scaleBy(255 - c.g, s[3]),
                scaleBy(255 - c.b, s[3]),
            );
        },
    };
}

fn scaleBy(v: u8, k: u8) u8 {
    return @intCast((@as(u16, v) * @as(u16, k) + 127) / 255);
}

/// YCbCr to RGB, in the form JFIF defines.
///
/// Fixed point at sixteen bits, which is exact enough that the result matches
/// the floating-point definition everywhere: the coefficients have four
/// significant figures and the inputs are bytes.
fn ycbcr(y: u8, cb: u8, cr: u8) Rgba8 {
    const yy: i32 = @as(i32, y) << 16;
    const b: i32 = @as(i32, cb) - 128;
    const r: i32 = @as(i32, cr) - 128;

    //  R = Y                + 1.402   · (Cr − 128)
    //  G = Y − 0.344136 · (Cb − 128) − 0.714136 · (Cr − 128)
    //  B = Y + 1.772   · (Cb − 128)
    const red = yy + 91881 * r;
    const green = yy - 22554 * b - 46802 * r;
    const blue = yy + 116130 * b;

    return .rgb(clampShift(red), clampShift(green), clampShift(blue));
}

fn clampShift(v: i32) u8 {
    const rounded = (v + 32768) >> 16;
    return @intCast(@max(0, @min(255, rounded)));
}

// -- the entry points --------------------------------------------------------

/// Reads a whole JPEG from `r`, producing a surface the caller owns.
pub fn decode(gpa: Allocator, r: *Io.Reader, opts: DecodeOptions) DecodeError!z2d.Surface {
    var state: State = .{ .gpa = gpa };
    defer state.deinit();

    var scanner: Scanner = .{ .r = r };
    try scanner.expectSoi();

    var adobe_transform: ?u8 = null;
    // A file with no EXIF in it leaves the caller's variable saying `.top_left`
    // rather than saying nothing, which is the same promise `Info` makes.
    var found_orientation = false;
    if (opts.orientation) |out| out.* = .top_left;
    // A profile arrives in pieces spread through the file's markers, so the
    // collector lives as long as the marker loop does.
    var assembler: icc.Assembler = .{};
    if (opts.icc) |out| out.clearRetainingCapacity();
    var scans: usize = 0;
    // A scan's bit reader consumes the marker that ended it, so the marker is
    // handed back here rather than looked for again.
    var pending: ?u8 = null;

    walk: while (true) {
        const marker = if (pending) |m| blk: {
            pending = null;
            break :blk m;
        } else scanner.nextMarker() catch |err| switch (err) {
            // A file that simply stops. What was decoded before it is kept,
            // which is what every other decoder does and what makes a
            // part-downloaded image show as a part-drawn one.
            error.EndOfStream => break :walk,
            else => |e| return e,
        };

        switch (marker) {
            Marker.eoi => break :walk,
            Marker.dqt => try readQuantTables(&scanner, &state),
            Marker.dht => try readHuffmanTables(&scanner, &state),
            Marker.dac => return error.Unsupported,
            Marker.dri => {
                const len = try scanner.segmentLen();
                if (len != 2) return error.InvalidData;
                state.restart_interval = try scanner.r.takeInt(u16, .big);
            },
            Marker.app14 => adobe_transform = try scanner.readAdobe(),
            Marker.app2 => {
                if (opts.icc) |out| {
                    try scanner.readIcc(gpa, out, &assembler, opts.limits.max_icc_bytes);
                } else {
                    try scanner.skipSegment();
                }
            },
            Marker.app1 => {
                if (opts.orientation) |out| {
                    if (!found_orientation) {
                        if (try scanner.readExif()) |o| {
                            out.* = o;
                            found_orientation = true;
                        }
                    } else {
                        try scanner.skipSegment();
                    }
                } else {
                    try scanner.skipSegment();
                }
            },
            Marker.sos => {
                if (state.frame == null) return error.InvalidData;
                pending = try readScanAndData(&scanner, &state);
                scans += 1;
            },
            else => {
                if (Marker.frameKind(marker)) |kind| {
                    if (kind == .unsupported) return error.Unsupported;
                    if (state.frame != null) return error.Unsupported; // hierarchical
                    state.frame = try scanner.readFrameHeader(kind, opts.limits);
                    state.colour = colourSpaceFor(state.frame.?, adobe_transform);
                    try state.allocate(opts.limits);
                    continue;
                }
                if (Marker.isStandalone(marker)) continue;
                try scanner.skipSegment();
            },
        }
    }

    const frame = &(state.frame orelse return error.InvalidData);
    if (scans == 0) return error.InvalidData;

    // Every marker has been seen, so a profile is either complete or is not
    // one and is thrown away.
    if (opts.icc) |out| assembler.finish(out);

    try reconstruct(&state);

    const surface_type = opts.surface_type orelse pixels.naturalSurfaceType(false);
    var sfc: z2d.Surface = z2d.Surface.init(
        surface_type,
        gpa,
        @intCast(frame.width),
        @intCast(frame.height),
    ) catch |err| switch (err) {
        error.InvalidWidth, error.InvalidHeight => return error.InvalidData,
        error.OutOfMemory => |e| return e,
    };
    errdefer sfc.deinit(gpa);

    try emit(&state, &sfc, gpa);
    return sfc;
}

/// `readScan`, returning whatever marker the entropy data ran into.
fn readScanAndData(scanner: *Scanner, state: *State) DecodeError!?u8 {
    const len = try scanner.segmentLen();
    if (len < 1) return error.InvalidData;
    const ns = try scanner.r.takeByte();
    if (ns == 0 or ns > 4) return error.InvalidData;
    if (len != 1 + @as(usize, ns) * 2 + 3) return error.InvalidData;

    const frame = &(state.frame orelse return error.InvalidData);

    var order: [4]usize = undefined;
    for (0..ns) |i| {
        const id = try scanner.r.takeByte();
        const tables = try scanner.r.takeByte();
        const found = for (frame.components[0..frame.n], 0..) |c, k| {
            if (c.id == id) break k;
        } else return error.InvalidData;
        for (order[0..i]) |prev| {
            if (prev == found) return error.InvalidData;
        }
        order[i] = found;
        frame.components[found].dc_table = tables >> 4;
        frame.components[found].ac_table = tables & 0x0f;
        if (frame.components[found].dc_table > 3 or frame.components[found].ac_table > 3) {
            return error.InvalidData;
        }
    }

    const ss = try scanner.r.takeByte();
    const se = try scanner.r.takeByte();
    const a = try scanner.r.takeByte();
    const ah: u5 = @intCast(a >> 4);
    const al: u5 = @intCast(a & 0x0f);

    if (frame.kind != .progressive) {
        if (ss != 0 or se != 63 or ah != 0 or al != 0) return error.InvalidData;
    } else {
        if (ss > 63 or se > 63 or ss > se) return error.InvalidData;
        if (ss != 0 and ns != 1) return error.InvalidData;
        if (al > 13 or ah > 13) return error.InvalidData;
    }

    for (order[0..ns]) |k| frame.components[k].dc_pred = 0;
    state.eobrun = 0;

    var bits: huffman.BitReader = .init(scanner.r);
    try decodeScan(state, frame, order[0..ns], &bits, ss, se, ah, al);
    return bits.marker;
}

/// Reads only as far as the frame header, and says what it described.
pub fn probe(r: *Io.Reader, limits: Limits) DecodeError!Info {
    const decoder: Decoder = try .init(r, limits);
    return decoder.info();
}

// -- writing -----------------------------------------------------------------

/// The example quantisation and Huffman tables from the specification's
/// Annex K.
///
/// "Example" is what the standard calls them, and they are also what almost
/// every JPEG in the world uses: the tables were derived from perceptual
/// experiments and nothing much has improved on them, so an encoder that
/// writes its own rarely writes better ones. Using them makes the output
/// ordinary, which for a format this widely read is a feature.
const annex_k = struct {
    /// Luminance, in raster order. Low frequencies at the top left get small
    /// divisors and survive; the high frequencies at the bottom right get
    /// large ones and mostly become zero, which is where the compression is.
    const luma_quant = [block_len]u16{
        16, 11, 10, 16, 24,  40,  51,  61,
        12, 12, 14, 19, 26,  58,  60,  55,
        14, 13, 16, 24, 40,  57,  69,  56,
        14, 17, 22, 29, 51,  87,  80,  62,
        18, 22, 37, 56, 68,  109, 103, 77,
        24, 35, 55, 64, 81,  104, 113, 92,
        49, 64, 78, 87, 103, 121, 120, 101,
        72, 92, 95, 98, 112, 100, 103, 99,
    };

    /// Chrominance, which is divided far more harshly — the eye resolves
    /// colour much less finely than brightness, which is the same observation
    /// that makes 4:2:0 subsampling acceptable.
    const chroma_quant = [block_len]u16{
        17, 18, 24, 47, 99, 99, 99, 99,
        18, 21, 26, 66, 99, 99, 99, 99,
        24, 26, 56, 99, 99, 99, 99, 99,
        47, 66, 99, 99, 99, 99, 99, 99,
        99, 99, 99, 99, 99, 99, 99, 99,
        99, 99, 99, 99, 99, 99, 99, 99,
        99, 99, 99, 99, 99, 99, 99, 99,
        99, 99, 99, 99, 99, 99, 99, 99,
    };

    const dc_luma_counts = [16]u8{ 0, 1, 5, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0 };
    const dc_luma_values = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 };

    const dc_chroma_counts = [16]u8{ 0, 3, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0 };
    const dc_chroma_values = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 };

    const ac_luma_counts = [16]u8{ 0, 2, 1, 3, 3, 2, 4, 3, 5, 5, 4, 4, 0, 0, 1, 0x7d };
    const ac_luma_values = [_]u8{
        0x01, 0x02, 0x03, 0x00, 0x04, 0x11, 0x05, 0x12, 0x21, 0x31, 0x41, 0x06,
        0x13, 0x51, 0x61, 0x07, 0x22, 0x71, 0x14, 0x32, 0x81, 0x91, 0xa1, 0x08,
        0x23, 0x42, 0xb1, 0xc1, 0x15, 0x52, 0xd1, 0xf0, 0x24, 0x33, 0x62, 0x72,
        0x82, 0x09, 0x0a, 0x16, 0x17, 0x18, 0x19, 0x1a, 0x25, 0x26, 0x27, 0x28,
        0x29, 0x2a, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3a, 0x43, 0x44, 0x45,
        0x46, 0x47, 0x48, 0x49, 0x4a, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59,
        0x5a, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69, 0x6a, 0x73, 0x74, 0x75,
        0x76, 0x77, 0x78, 0x79, 0x7a, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89,
        0x8a, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9a, 0xa2, 0xa3,
        0xa4, 0xa5, 0xa6, 0xa7, 0xa8, 0xa9, 0xaa, 0xb2, 0xb3, 0xb4, 0xb5, 0xb6,
        0xb7, 0xb8, 0xb9, 0xba, 0xc2, 0xc3, 0xc4, 0xc5, 0xc6, 0xc7, 0xc8, 0xc9,
        0xca, 0xd2, 0xd3, 0xd4, 0xd5, 0xd6, 0xd7, 0xd8, 0xd9, 0xda, 0xe1, 0xe2,
        0xe3, 0xe4, 0xe5, 0xe6, 0xe7, 0xe8, 0xe9, 0xea, 0xf1, 0xf2, 0xf3, 0xf4,
        0xf5, 0xf6, 0xf7, 0xf8, 0xf9, 0xfa,
    };

    const ac_chroma_counts = [16]u8{ 0, 2, 1, 2, 4, 4, 3, 4, 7, 5, 4, 4, 0, 1, 2, 0x77 };
    const ac_chroma_values = [_]u8{
        0x00, 0x01, 0x02, 0x03, 0x11, 0x04, 0x05, 0x21, 0x31, 0x06, 0x12, 0x41,
        0x51, 0x07, 0x61, 0x71, 0x13, 0x22, 0x32, 0x81, 0x08, 0x14, 0x42, 0x91,
        0xa1, 0xb1, 0xc1, 0x09, 0x23, 0x33, 0x52, 0xf0, 0x15, 0x62, 0x72, 0xd1,
        0x0a, 0x16, 0x24, 0x34, 0xe1, 0x25, 0xf1, 0x17, 0x18, 0x19, 0x1a, 0x26,
        0x27, 0x28, 0x29, 0x2a, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3a, 0x43, 0x44,
        0x45, 0x46, 0x47, 0x48, 0x49, 0x4a, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58,
        0x59, 0x5a, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69, 0x6a, 0x73, 0x74,
        0x75, 0x76, 0x77, 0x78, 0x79, 0x7a, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87,
        0x88, 0x89, 0x8a, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9a,
        0xa2, 0xa3, 0xa4, 0xa5, 0xa6, 0xa7, 0xa8, 0xa9, 0xaa, 0xb2, 0xb3, 0xb4,
        0xb5, 0xb6, 0xb7, 0xb8, 0xb9, 0xba, 0xc2, 0xc3, 0xc4, 0xc5, 0xc6, 0xc7,
        0xc8, 0xc9, 0xca, 0xd2, 0xd3, 0xd4, 0xd5, 0xd6, 0xd7, 0xd8, 0xd9, 0xda,
        0xe2, 0xe3, 0xe4, 0xe5, 0xe6, 0xe7, 0xe8, 0xe9, 0xea, 0xf2, 0xf3, 0xf4,
        0xf5, 0xf6, 0xf7, 0xf8, 0xf9, 0xfa,
    };
};

/// How finely to divide the colour resolution.
///
/// Every named ratio is a pair of factors applied to the chroma planes; the
/// luma plane carries the reciprocal, which is how JPEG expresses it. The
/// implementation is general in those factors — `fillPlanes` averages over
/// whatever box they describe — so a coarser ratio is an arm of this
/// enumeration and nothing else.
/// The sampling factors of one component: how many of its blocks sit across
/// and down in each MCU.
pub const Sampling = struct {
    h: u32 = 1,
    v: u32 = 1,
};

/// The three components' sampling factors, resolved.
pub const Factors = struct {
    luma: Sampling,
    cb: Sampling = .{},
    cr: Sampling = .{},
};

/// How the chroma components are sampled against the luma one.
///
/// The four named ratios are the ones worth naming and cover almost every
/// JPEG ever written. `factors` is the general case, for the rest of what the
/// decoder here reads: chroma sampled by three or four, or the two chroma
/// components sampled differently from each other.
pub const Chroma = union(enum) {
    /// 4:4:4 — chroma at the same resolution as luma. Larger, and the right
    /// answer for an image with hard colour edges: text, diagrams, anything
    /// with saturated lines a pixel or two wide.
    full,
    /// 4:2:2 — chroma halved across only. What a good deal of video-adjacent
    /// work uses, because horizontal resolution is what chroma can spare.
    horizontal,
    /// 4:4:0 — chroma halved down only. Rare, and the right answer for an
    /// image whose detail runs in vertical strokes.
    vertical,
    /// 4:2:0 — chroma at half resolution in each direction, which is what
    /// almost every JPEG is and what the format was designed around.
    half,
    /// Sampling factors given outright.
    ///
    /// JPEG states these as "how many blocks of this component are in an
    /// MCU", so a component sampled *less* finely has the *smaller* number:
    /// 4:2:0 is luma 2×2 against chroma 1×1. Which is why the named ratios
    /// above exist — the numbers are the reciprocal of what the name says.
    ///
    /// `Chroma.valid` says whether a set can be written; `encode` refuses one
    /// that cannot with `error.Unsupported`.
    factors: Factors,

    /// The three components' factors, whichever way they were asked for.
    pub fn resolve(self: Chroma) Factors {
        return switch (self) {
            .full => .{ .luma = .{ .h = 1, .v = 1 } },
            .horizontal => .{ .luma = .{ .h = 2, .v = 1 } },
            .vertical => .{ .luma = .{ .h = 1, .v = 2 } },
            .half => .{ .luma = .{ .h = 2, .v = 2 } },
            .factors => |f| f,
        };
    }

    /// Whether these are factors this encoder can write.
    ///
    /// Four rules, and each of them is the format's or the arithmetic's
    /// rather than this encoder's preference:
    ///
    /// * Every factor is 1 to 4. The field in `SOF` is four bits, and the
    ///   specification bounds it further than the field does.
    /// * Luma is at least as finely sampled as either chroma component in
    ///   each direction. Chroma sampled *more* finely is legal and is not
    ///   something to write: it spends bits on the channel the eye is least
    ///   sensitive to.
    /// * Luma's factors divide exactly by each chroma component's, so that a
    ///   chroma sample covers a whole number of luma samples. A ratio of 3
    ///   against 2 is legal in the format and would mean averaging a fraction
    ///   of a sample, which this refuses rather than approximates.
    /// * The blocks of one MCU come to ten or fewer, which is the
    ///   specification's own limit on an interleaved scan.
    pub fn valid(self: Chroma) bool {
        const f = self.resolve();
        for ([_]Sampling{ f.luma, f.cb, f.cr }) |c| {
            if (c.h < 1 or c.h > 4 or c.v < 1 or c.v > 4) return false;
        }
        for ([_]Sampling{ f.cb, f.cr }) |c| {
            if (c.h > f.luma.h or c.v > f.luma.v) return false;
            if (f.luma.h % c.h != 0 or f.luma.v % c.v != 0) return false;
        }
        const blocks = f.luma.h * f.luma.v + f.cb.h * f.cb.v + f.cr.h * f.cr.v;
        return blocks <= 10;
    }
};

/// How to write a JPEG.
pub const EncodeOptions = struct {
    /// 1 to 100, in the scale the Independent JPEG Group's tool established
    /// and everything since has followed. 75 is that tool's default; this one
    /// asks for a little more.
    quality: u7 = 85,

    chroma: Chroma = .half,

    /// The colour transparency is composited onto.
    ///
    /// No mode of JPEG carries an alpha channel, so a surface that has one has
    /// to be flattened. As in `bmp`, compositing rather than discarding: the
    /// colour channels of a nearly-transparent red say "red", and dropping the
    /// alpha would turn a faint tint into a solid block.
    background: Rgba8 = .black,

    /// Emit a restart marker every this many MCUs, or zero for none.
    ///
    /// A restart interval is independently decodable: it begins on a byte
    /// boundary with the DC predictors reset, so a decoder that meets corrupt
    /// data can resynchronise at the next marker and lose one interval rather
    /// than the rest of the image. It also lets a decoder split the scan
    /// across threads. The cost is a couple of bytes per interval and the
    /// coding efficiency given up by resetting the predictors, so intervals of
    /// a whole MCU row or two are the usual choice rather than a handful.
    restart_interval: u16 = 0,

    /// Which Huffman tables code the scan.
    ///
    /// Ignored in `.progressive`, which always measures its own: the Annex K
    /// tables define no code for the end-of-block-run symbols a progressive
    /// scan is largely made of, so they are not a table a progressive file
    /// could be written with at all.
    tables: Tables = .optimal,

    /// Sequential or progressive.
    mode: Mode = .baseline,

    /// Which way up the image goes, written as an `APP1` segment.
    ///
    /// Nothing here rotates anything, so this is written as given and makes no
    /// claim about the pixels beside it: a caller who has already turned the
    /// image the right way up wants `.top_left`, or null for no segment at
    /// all. Null and `.top_left` differ only in whether the file carries the
    /// tag; both say the same thing to a viewer.
    ///
    /// Only this one tag is written. See `exif` for why.
    orientation: ?exif.Orientation = null,

    /// An ICC colour profile to carry into the file, in `APP2` segments.
    ///
    /// Borrowed for the call and not kept. Nothing here interprets it — see
    /// `icc` for what that means — but a profile that is not shaped like one
    /// is refused with `error.Unsupported` rather than written, since a
    /// malformed profile in the output is a file other readers reject.
    ///
    /// A profile larger than 255 segments of 65519 bytes cannot be written at
    /// all, which is the format's limit rather than this encoder's.
    icc: ?[]const u8 = null,

    /// Choose each block's coefficients by what they cost rather than by what
    /// is nearest.
    ///
    /// An ordinary quantiser rounds, which is the best answer to the wrong
    /// question: the cheapest block that still looks like the original is
    /// often not the nearest one, because the entropy coder does not price
    /// coefficients independently. See `trellis` for what that means.
    ///
    /// Smaller at the same fidelity, and slower — the search is `O(63²)` a
    /// block against sixty-four divisions — which is why it is off by default.
    /// Nothing about the file changes: what comes out is an ordinary JPEG that
    /// any decoder reads, with different numbers in it.
    trellis: bool = false,

    /// What a bit is worth to the search, in squared quantiser units.
    ///
    /// Larger spends fewer bits and loses more. Ignored unless `trellis` is
    /// set; see `trellis.default_strength` for where the default comes from.
    trellis_strength: f32 = trellis.default_strength,

    /// How many components to write, and what they mean.
    colour: Colour = .auto,

    /// The scans a progressive file is written as, instead of the default
    /// script. Ignored in `.baseline`, which has one scan and no choice.
    ///
    /// `progressive_colour` and `progressive_grey` are the defaults, and are
    /// libjpeg's `jpeg_simple_progression` — worth reading before writing
    /// one, since they are what almost every progressive JPEG in the world
    /// carries. `checkScript` says whether a script can be written, and
    /// `encode` refuses one that cannot with `error.Unsupported`.
    script: ?[]const Scan = null,

    /// Quantisation tables to use instead of the Annex K ones scaled by
    /// `quality`, which is then ignored.
    ///
    /// For a caller who has tables worth more than a number between 1 and 100:
    /// measured for a particular kind of image, taken from another encoder to
    /// match its output, or tuned against a quality metric. Everything else
    /// about the file is unchanged, and a decoder cannot tell where the tables
    /// came from — they go into `DQT` either way.
    quant: ?Quant = null,
};

/// How many components a file is written with, and what they mean.
pub const Colour = enum {
    /// Follow the surface: one with colour becomes `ycbcr`, one that has only
    /// an alpha channel becomes `greyscale`.
    auto,
    /// One component. A colour surface is reduced to its luma, by the same
    /// coefficients that would have produced the `Y` of a three-component
    /// file, so the greyscale image is the colour one with the chroma thrown
    /// away rather than a different rendering of it.
    ///
    /// Smaller than `ycbcr` by a good deal more than a third, since the
    /// chroma components of a photograph are mostly flat and code cheaply but
    /// still cost two tables and their share of every MCU.
    greyscale,
    /// Three components, `Y`, `Cb` and `Cr`, which is what a JFIF file means
    /// by three components and what almost every JPEG is.
    ///
    /// Asking for this from a surface that has only an alpha channel writes
    /// that channel as brightness with both chroma components flat, which is
    /// a grey image in three components: larger than `greyscale` and carrying
    /// no more.
    ycbcr,
};

/// Quantisation tables, in raster order.
///
/// Raster order rather than the zig-zag order `DQT` stores them in, because
/// that is the order the transform divides by and so the order the numbers
/// are about; the encoder reorders them on the way into the file. An entry of
/// zero is refused rather than dividing by it, and 8-bit `DQT` cannot carry a
/// value above 255.
pub const Quant = struct {
    luma: [block_len]u16,
    chroma: [block_len]u16,

    /// Whether every entry of both tables can be written and divided by.
    pub fn valid(self: Quant) bool {
        for (self.luma) |v| {
            if (v < 1 or v > 255) return false;
        }
        for (self.chroma) |v| {
            if (v < 1 or v > 255) return false;
        }
        return true;
    }
};

/// How the coefficients are laid out in the file.
pub const Mode = enum {
    /// One scan carrying every coefficient, which is what almost every JPEG
    /// is and what every decoder reads.
    baseline,
    /// Ten scans — six for a greyscale image — each carrying a slice of the
    /// precision or of the spectrum, so that a decoder reading the file as it
    /// arrives has a whole blurred image after the first one and sharpens it
    /// with each of the rest.
    ///
    /// The scan script is libjpeg's, which is the one the format settled on:
    /// the DC coefficients first, less their bottom bit, then the low AC
    /// coefficients of luma, then all of chroma, then the rest of luma, and
    /// then the bottom bit of everything. It is usually a few percent smaller
    /// than baseline as well, because a band of coefficients coded on its own
    /// has statistics its own table can fit.
    progressive,
};

/// Where the Huffman tables written into a file come from.
pub const Tables = enum {
    /// The example tables of the specification's Annex K, which are the ones
    /// almost every JPEG in the world was written with: they were measured
    /// once, on a set of photographs, and every encoder since has copied them.
    ///
    /// They cost nothing to produce and are a reasonable fit for a photograph.
    /// They are a poor fit for anything else, and for a small image the table
    /// definitions themselves — about four hundred bytes of them — can be most
    /// of the file.
    annex_k,
    /// Tables computed from the image, which is what `cjpeg -optimize` does.
    ///
    /// Every symbol the scan will use is counted first, and the tables are
    /// built to code exactly those. It is strictly smaller than `annex_k` for
    /// anything but a coincidence, typically by a few percent and by much more
    /// for an image the Annex K tables do not suit, and it costs a second pass
    /// over the coefficients. The tables go into the file either way, so a
    /// decoder cannot tell the difference.
    optimal,
};

/// One component on the way out: where its samples are, and which tables code
/// them.
const Outgoing = struct {
    id: u8,
    h: u32,
    v: u32,
    quant: u8,
    plane: []u8,
    stride: u32,
    dc: *const huffman.Encoder = undefined,
    ac: *const huffman.Encoder = undefined,
    /// Which of the four table slots this component's symbols are counted
    /// into and coded with.
    table: u8,
    /// The quantised coefficients of every block, in raster order of blocks
    /// and raster order within a block.
    ///
    /// The encoder produces all of these before it codes any of them, which
    /// costs two bytes a sample and buys the two things that need more than
    /// one look at a block: Huffman tables computed from the image, and --
    /// when it comes -- progressive mode, whose scans each carry a slice of
    /// every coefficient.
    coeffs: []i16 = &.{},
    blocks_w: u32 = 0,
    blocks_h: u32 = 0,
    /// The blocks the image actually reaches, which is fewer than `blocks_w`
    /// by `blocks_h` whenever it does not fill its last MCU. A scan carrying
    /// one component walks these; an interleaved scan walks whole MCUs and so
    /// walks the padding as well.
    sblocks_w: u32 = 0,
    sblocks_h: u32 = 0,
    /// The previous block's DC coefficient, which the next one is coded as a
    /// difference from.
    pred: i32 = 0,
};

/// What a pass over the scan is for.
const Pass = enum {
    /// Count how often each symbol occurs, to build tables from.
    count,
    /// Write the bits.
    emit,
};

/// The symbol frequencies of one scan, one array per table slot.
///
/// The extra entry past the 256 real symbols is the specification's reserved
/// one, which never occurs and is counted by `huffman.Spec.optimal` rather
/// than here; see that function for what it is for.
const Stats = struct {
    dc: [4][257]u32 = @splat(@splat(0)),
    ac: [4][257]u32 = @splat(@splat(0)),
};

/// Writes `sfc` as a baseline JPEG.
///
/// Eight-bit, sequential, Huffman-coded, with the Annex K tables — which is to
/// say an ordinary JPEG that every decoder in the world reads.
///
/// By default a surface with colour becomes YCbCr and a surface that has
/// *only* an alpha channel becomes a single-component greyscale JPEG carrying
/// that alpha as brightness. The second needs saying because it differs from
/// what `bmp` and `png` do with the same surface: both of those can keep the
/// coverage in an alpha channel and so write it as transparent black, and
/// JPEG has no alpha channel to keep it in. The choice is between putting the
/// one channel the surface has into the one channel the file has, and writing
/// a black rectangle. `EncodeOptions.colour` overrides both.
///
/// `gpa` is used for the component planes and released before this returns.
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

    // Whether the surface has colour at all, which is what `.auto` follows and
    // what decides where a luma sample comes from: a surface with only an
    // alpha channel has one channel to give, and it is that one.
    const alpha_only = switch (sfc.getFormat()) {
        .alpha8, .alpha4, .alpha2, .alpha1 => true,
        .argb, .rgba, .xrgb, .rgb => false,
    };
    const greyscale = switch (opts.colour) {
        .auto => alpha_only,
        .greyscale => true,
        .ycbcr => false,
    };
    // A single component has nothing to subsample against.
    if (opts.icc) |profile| {
        if (!icc.looksValid(profile) or profile.len > icc.jpeg_max) return error.Unsupported;
    }
    // A price per bit that is negative, or is not a number, would make the
    // search's arithmetic meaningless rather than merely aggressive.
    if (opts.trellis and !(opts.trellis_strength >= 0 and
        math.isFinite(opts.trellis_strength)))
    {
        return error.Unsupported;
    }

    const chroma: Chroma = if (greyscale) .full else opts.chroma;
    if (!chroma.valid()) return error.Unsupported;
    const factors = chroma.resolve();
    const hmax = factors.luma.h;
    const vmax = factors.luma.v;

    const mcu_w = hmax * block_size;
    const mcu_h = vmax * block_size;
    const uw: u32 = @intCast(width);
    const uh: u32 = @intCast(height);
    const mcus_x = (uw + mcu_w - 1) / mcu_w;
    const mcus_y = (uh + mcu_h - 1) / mcu_h;

    const luma_q, const chroma_q = if (opts.quant) |q| tables: {
        if (!q.valid()) return error.Unsupported;
        break :tables .{ q.luma, q.chroma };
    } else .{
        scaleQuant(&annex_k.luma_quant, opts.quality),
        scaleQuant(&annex_k.chroma_quant, opts.quality),
    };

    // The component table, which everything below is driven by rather than
    // knowing how many components there are.
    var comps: [3]Outgoing = undefined;
    const n: usize = if (greyscale) 1 else 3;
    comps[0] = .{
        .id = 1,
        .h = hmax,
        .v = vmax,
        .quant = 0,
        .table = 0,
        .plane = &.{},
        .stride = 0,
    };
    if (!greyscale) {
        for (1..3) |i| comps[i] = .{
            .id = @intCast(i + 1),
            .h = if (i == 1) factors.cb.h else factors.cr.h,
            .v = if (i == 1) factors.cb.v else factors.cr.v,
            .quant = 1,
            .table = 1,
            .plane = &.{},
            .stride = 0,
        };
    }

    // The planes, padded out to whole MCUs. The padding is coded like
    // everything else — a JPEG has no way to say "stop half way through an
    // MCU" — so the edge samples are repeated into it rather than left at
    // zero, which would put a hard edge there for the transform to spend bits
    // on and for a decoder to ring against.
    defer for (comps[0..n]) |c| {
        gpa.free(c.plane);
        gpa.free(c.coeffs);
    };
    for (comps[0..n]) |*c| {
        c.blocks_w = mcus_x * c.h;
        c.blocks_h = mcus_y * c.v;
        c.sblocks_w = ((uw * c.h + hmax - 1) / hmax + block_size - 1) / block_size;
        c.sblocks_h = ((uh * c.v + vmax - 1) / vmax + block_size - 1) / block_size;
        c.stride = c.blocks_w * block_size;
        c.plane = try gpa.alloc(u8, @as(usize, c.stride) * c.blocks_h * block_size);
        c.coeffs = try gpa.alloc(i16, @as(usize, c.blocks_w) * c.blocks_h * block_len);
    }

    try fillPlanes(gpa, sfc, opts, comps[0..n], hmax, vmax, alpha_only);

    // Transform and quantise every block, once. Everything after this reads
    // coefficients rather than samples.
    //
    // The rate model the search prices symbols with, when there is one. The
    // Annex K tables rather than the ones this file will carry, which is a
    // circle that has to be broken somewhere: the tables are measured from the
    // coefficients, and the coefficients would be chosen using the tables.
    // Annex K is a good enough estimate of any table's shape, and the search
    // is choosing between whole blocks rather than splitting hairs.
    const trellis_luma = try encoderTable(&.fixed(&annex_k.ac_luma_counts, &annex_k.ac_luma_values));
    const trellis_chroma = try encoderTable(&.fixed(&annex_k.ac_chroma_counts, &annex_k.ac_chroma_values));

    for (comps[0..n]) |*c| {
        const luma = c.quant == 0;
        const model: ?*const [256]u8 = if (opts.trellis)
            (if (luma) &trellis_luma.len else &trellis_chroma.len)
        else
            null;
        quantiseComponent(c, if (luma) &luma_q else &chroma_q, model, opts.trellis_strength);
    }

    // The tables, which have to be settled before the headers are written
    // because the headers carry them. Counting is a whole pass over the
    // coefficients that produces no output, which is what `.optimal` costs.
    // A progressive file builds one set per scan instead, later.
    const progressive = opts.mode == .progressive;
    const script: []const Scan = if (opts.script) |given|
        given
    else if (greyscale)
        &progressive_grey
    else
        &progressive_colour;
    if (progressive and checkScript(script, n) != null) return error.Unsupported;
    var dc_spec: [2]huffman.Spec = .{
        .fixed(&annex_k.dc_luma_counts, &annex_k.dc_luma_values),
        .fixed(&annex_k.dc_chroma_counts, &annex_k.dc_chroma_values),
    };
    var ac_spec: [2]huffman.Spec = .{
        .fixed(&annex_k.ac_luma_counts, &annex_k.ac_luma_values),
        .fixed(&annex_k.ac_chroma_counts, &annex_k.ac_chroma_values),
    };
    if (opts.tables == .optimal and !progressive) {
        var stats: Stats = .{};
        try runScan(.count, comps[0..n], mcus_x, mcus_y, opts.restart_interval, &stats, null, null);
        for (0..if (greyscale) 1 else 2) |slot| {
            dc_spec[slot] = .optimal(&stats.dc[slot]);
            ac_spec[slot] = .optimal(&stats.ac[slot]);
        }
    }

    const dc_luma = try encoderTable(&dc_spec[0]);
    const ac_luma = try encoderTable(&ac_spec[0]);
    const dc_chroma = try encoderTable(&dc_spec[1]);
    const ac_chroma = try encoderTable(&ac_spec[1]);

    // -- the file ------------------------------------------------------------
    try w.writeAll(&.{ 0xff, Marker.soi });

    // JFIF, which is what says three components are YCbCr.
    try w.writeAll(&.{ 0xff, Marker.app0 });
    try w.writeInt(u16, 16, .big);
    try w.writeAll("JFIF\x00");
    try w.writeAll(&.{ 1, 1 }); // version 1.1
    try w.writeAll(&.{0}); // no density units
    try w.writeInt(u16, 1, .big); // x density
    try w.writeInt(u16, 1, .big); // y density
    try w.writeAll(&.{ 0, 0 }); // no thumbnail

    // Which way up, before the profile: `APP1` then `APP2` is the order
    // everything writes them in.
    if (opts.orientation) |o| {
        var tiff: [exif.orientation_block_len]u8 = undefined;
        exif.writeOrientation(&tiff, o);
        try w.writeAll(&.{ 0xff, Marker.app1 });
        try w.writeInt(u16, @intCast(2 + 6 + tiff.len), .big);
        try w.writeAll("Exif\x00\x00");
        try w.writeAll(&tiff);
    }

    // The profile, in as many `APP2` segments as it takes. Before everything
    // but the JFIF header, which is where readers look for it.
    if (opts.icc) |profile| {
        var pieces: icc.Pieces = .init(profile);
        const total = pieces.count();
        while (pieces.take()) |piece| {
            try w.writeAll(&.{ 0xff, Marker.app2 });
            try w.writeInt(u16, @intCast(2 + icc.jpeg_marker.len + 2 + piece.bytes.len), .big);
            try w.writeAll(icc.jpeg_marker);
            try w.writeAll(&.{ piece.number, @intCast(total) });
            try w.writeAll(piece.bytes);
        }
    }

    try writeQuantTable(w, 0, &luma_q);
    if (!greyscale) try writeQuantTable(w, 1, &chroma_q);

    try w.writeAll(&.{ 0xff, if (progressive) Marker.sof2 else Marker.sof0 });
    try w.writeInt(u16, @intCast(8 + n * 3), .big);
    try w.writeAll(&.{8}); // precision
    try w.writeInt(u16, @intCast(height), .big);
    try w.writeInt(u16, @intCast(width), .big);
    try w.writeAll(&.{@intCast(n)});
    for (comps[0..n]) |c| {
        try w.writeAll(&.{ c.id, @intCast((c.h << 4) | c.v), c.quant });
    }

    if (opts.restart_interval != 0) {
        try w.writeAll(&.{ 0xff, Marker.dri });
        try w.writeInt(u16, 4, .big);
        try w.writeInt(u16, opts.restart_interval, .big);
    }

    // -- the scans -----------------------------------------------------------
    if (progressive) {
        try writeProgressive(w, gpa, comps[0..n], mcus_x, mcus_y, opts.restart_interval, script);
    } else {
        try writeHuffTable(w, 0x00, &dc_spec[0]);
        try writeHuffTable(w, 0x10, &ac_spec[0]);
        if (!greyscale) {
            try writeHuffTable(w, 0x01, &dc_spec[1]);
            try writeHuffTable(w, 0x11, &ac_spec[1]);
        }

        for (comps[0..n]) |*c| {
            c.dc = if (c.table == 0) &dc_luma else &dc_chroma;
            c.ac = if (c.table == 0) &ac_luma else &ac_chroma;
        }

        try w.writeAll(&.{ 0xff, Marker.sos });
        try w.writeInt(u16, @intCast(6 + n * 2), .big);
        try w.writeAll(&.{@intCast(n)});
        for (comps[0..n]) |c| {
            const tables: u8 = if (c.id == 1) 0x00 else 0x11;
            try w.writeAll(&.{ c.id, tables });
        }
        try w.writeAll(&.{ 0, 63, 0 }); // Ss, Se, Ah/Al

        var bits: huffman.BitWriter = .init(w);
        try runScan(.emit, comps[0..n], mcus_x, mcus_y, opts.restart_interval, null, &bits, w);
        try bits.flush();
    }

    try w.writeAll(&.{ 0xff, Marker.eoi });
}

/// Converts the surface to YCbCr and fills each component's padded plane,
/// averaging chroma down to whatever its sampling factors ask for.
fn fillPlanes(
    gpa: Allocator,
    sfc: *const z2d.Surface,
    opts: EncodeOptions,
    comps: []Outgoing,
    hmax: u32,
    vmax: u32,
    /// Whether the surface's only channel is its alpha, which is the one case
    /// where a luma sample is read rather than computed.
    alpha_only: bool,
) EncodeError!void {
    const width: u32 = @intCast(sfc.getWidth());
    const height: u32 = @intCast(sfc.getHeight());
    const greyscale = comps.len == 1;

    const luma_w = comps[0].stride;
    const luma_h: u32 = @intCast(comps[0].plane.len / luma_w);

    const row = try gpa.alloc(Rgba8, width);
    defer gpa.free(row);

    // Chroma is accumulated at full resolution and averaged down afterwards,
    // which is what a sampling factor means arithmetically: a chroma sample is
    // the mean of the samples it stands for, not one of them picked out.
    var full_cb: []u8 = &.{};
    defer gpa.free(full_cb);
    var full_cr: []u8 = &.{};
    defer gpa.free(full_cr);
    const subsampled = !greyscale and for (comps[1..]) |c| {
        if (c.h != hmax or c.v != vmax) break true;
    } else false;
    if (subsampled) {
        const area = @as(usize, luma_w) * luma_h;
        full_cb = try gpa.alloc(u8, area);
        full_cr = try gpa.alloc(u8, area);
    }

    var y: u32 = 0;
    while (y < luma_h) : (y += 1) {
        // Past the bottom of the image, repeat the last row.
        pixels.readRow(row, sfc, @intCast(@min(y, height - 1)));
        var x: u32 = 0;
        while (x < luma_w) : (x += 1) {
            const px = row[@min(x, width - 1)];
            const at = @as(usize, y) * luma_w + x;

            if (alpha_only) {
                // The surface's one channel, which `readRow` reports as the
                // alpha of a transparent black pixel. It goes in as brightness
                // whether the file has one component or three; asking for
                // three of a surface that has one channel gives a grey image
                // with both chroma components flat, which is the honest
                // answer and is why it is the caller's choice rather than
                // something to refuse.
                comps[0].plane[at] = px.a;
                if (!greyscale) {
                    if (subsampled) {
                        full_cb[at] = 128;
                        full_cr[at] = 128;
                    } else {
                        comps[1].plane[at] = 128;
                        comps[2].plane[at] = 128;
                    }
                }
                continue;
            }

            const flat = over(px, opts.background);
            const r: i32 = flat.r;
            const g: i32 = flat.g;
            const b: i32 = flat.b;
            comps[0].plane[at] = clampShift(19595 * r + 38470 * g + 7471 * b);
            // A greyscale file is the colour one with the chroma thrown away,
            // so the luma above is computed the same way and nothing else is
            // computed at all.
            if (greyscale) continue;
            const cb = clampShift(-11056 * r - 21712 * g + 32768 * b + (128 << 16));
            const cr = clampShift(32768 * r - 27440 * g - 5328 * b + (128 << 16));
            if (subsampled) {
                full_cb[at] = cb;
                full_cr[at] = cr;
            } else {
                comps[1].plane[at] = cb;
                comps[2].plane[at] = cr;
            }
        }
    }

    if (!subsampled) return;

    for (comps[1..3], [_][]const u8{ full_cb, full_cr }) |*c, source| {
        // The box this component's samples cover, which the two chroma
        // components need not agree about.
        const rx = hmax / c.h;
        const ry = vmax / c.v;
        const count: u32 = rx * ry;
        const rows: u32 = @intCast(c.plane.len / c.stride);
        var cy: u32 = 0;
        while (cy < rows) : (cy += 1) {
            var cx: u32 = 0;
            while (cx < c.stride) : (cx += 1) {
                var sum: u32 = 0;
                for (0..ry) |dy| {
                    for (0..rx) |dx| {
                        const sy = @min(cy * ry + @as(u32, @intCast(dy)), luma_h - 1);
                        const sx = @min(cx * rx + @as(u32, @intCast(dx)), luma_w - 1);
                        sum += source[@as(usize, sy) * luma_w + sx];
                    }
                }
                c.plane[@as(usize, cy) * c.stride + cx] = @intCast((sum + count / 2) / count);
            }
        }
    }
}

/// The Annex K table scaled by a quality setting.
///
/// The scale is the Independent JPEG Group's, which is what "quality 85" means
/// to everyone: linear in the divisors above 50 and hyperbolic below, so that
/// the low end degrades gracefully rather than falling off a cliff. A divisor
/// is never allowed below one, which would be no quantisation at all.
fn scaleQuant(base: *const [block_len]u16, quality: u7) [block_len]u16 {
    const q: u32 = @max(1, @min(100, @as(u32, quality)));
    const scale: u32 = if (q < 50) 5000 / q else 200 - 2 * q;
    var out: [block_len]u16 = undefined;
    for (base, &out) |b, *o| {
        const v = (@as(u32, b) * scale + 50) / 100;
        o.* = @intCast(@max(1, @min(255, v)));
    }
    return out;
}

fn encoderTable(spec: *const huffman.Spec) EncodeError!huffman.Encoder {
    return huffman.Encoder.init(&spec.counts, spec.symbols()) catch error.Unsupported;
}

/// A `DQT` segment, whose table is written in zig-zag order.
fn writeQuantTable(w: *Io.Writer, id: u8, table: *const [block_len]u16) EncodeError!void {
    try w.writeAll(&.{ 0xff, Marker.dqt });
    try w.writeInt(u16, 3 + block_len, .big);
    try w.writeAll(&.{id}); // eight-bit precision, and this identifier
    for (zigzag) |raster| try w.writeAll(&.{@intCast(table[raster])});
}

/// A `DHT` segment.
fn writeHuffTable(w: *Io.Writer, class_and_id: u8, spec: *const huffman.Spec) EncodeError!void {
    try w.writeAll(&.{ 0xff, Marker.dht });
    try w.writeInt(u16, @intCast(3 + 16 + spec.len), .big);
    try w.writeAll(&.{class_and_id});
    try w.writeAll(&spec.counts);
    try w.writeAll(spec.symbols());
}

test "the Annex K tables satisfy what the optimal ones are checked against" {
    // Worth knowing both ways round: it says the check the generated tables
    // are held to is the right check, and it says the tables the specification
    // ships are complete but for the reserved code, as it claims.
    const tables = .{
        huffman.Spec.fixed(&annex_k.dc_luma_counts, &annex_k.dc_luma_values),
        huffman.Spec.fixed(&annex_k.ac_luma_counts, &annex_k.ac_luma_values),
        huffman.Spec.fixed(&annex_k.dc_chroma_counts, &annex_k.dc_chroma_values),
        huffman.Spec.fixed(&annex_k.ac_chroma_counts, &annex_k.ac_chroma_values),
    };
    inline for (tables) |spec| try huffman.checkSpec(&spec, spec.symbols());
}

/// Transforms and quantises every block of one component into its coefficient
/// buffer.
fn quantiseComponent(
    c: *Outgoing,
    quant: *const [block_len]u16,
    /// The AC table's code lengths, when the coefficients are to be searched
    /// for rather than rounded to; null to round.
    rate_model: ?*const [256]u8,
    strength: f32,
) void {
    var samples: [block_len]u8 = undefined;
    var transformed: [block_len]f32 = undefined;
    var scaled: [block_len]f32 = undefined;

    var by: u32 = 0;
    while (by < c.blocks_h) : (by += 1) {
        var bx: u32 = 0;
        while (bx < c.blocks_w) : (bx += 1) {
            const x0 = bx * block_size;
            const y0 = by * block_size;
            for (0..block_size) |r| {
                const at = (@as(usize, y0) + r) * c.stride + x0;
                @memcpy(samples[r * block_size ..][0..block_size], c.plane[at..][0..block_size]);
            }
            idct.forward(&samples, &transformed);

            const out = c.coeffs[(@as(usize, by) * c.blocks_w + bx) * block_len ..][0..block_len];

            // Into the quantiser's own units, where the error of choosing an
            // integer for a coefficient is just the difference. Dividing here
            // and rounding after is also what keeps the rounding to *once*:
            // rounding the transform's output to a whole number first and
            // dividing that would round twice, and the first rounding's error
            // survives the division, moving a coefficient across the boundary
            // between two quantised values whenever the true value sits near
            // one. See `idct.forward`.
            for (transformed, quant, &scaled) |v, divisor, *slot| {
                slot.* = v / @as(f32, @floatFromInt(divisor));
            }

            if (rate_model) |bits| {
                trellis.block(&scaled, bits, strength, out);
            } else {
                for (scaled, out) |v, *slot| {
                    slot.* = @intFromFloat(@max(
                        @as(f32, math.minInt(i16)),
                        @min(@as(f32, math.maxInt(i16)), @round(v)),
                    ));
                }
            }
        }
    }
}

/// Walks the blocks of the scan in the order they are coded, either counting
/// the symbols or writing them.
///
/// One loop for both passes rather than two that have to agree. They must
/// agree exactly: the DC coefficient is coded as a difference from the
/// previous block of the same component, and a restart interval resets those
/// predictors, so a counting pass that handled restarts differently from the
/// emitting pass would build its tables from symbols that are never written.
fn runScan(
    comptime mode: Pass,
    comps: []Outgoing,
    mcus_x: u32,
    mcus_y: u32,
    restart_interval: u16,
    stats: ?*Stats,
    bits: ?*huffman.BitWriter,
    w: ?*Io.Writer,
) EncodeError!void {
    for (comps) |*c| c.pred = 0;

    const total = @as(u64, mcus_x) * mcus_y;
    var left = restart_interval;
    var marker: u8 = 0;
    var done: u64 = 0;

    var my: u32 = 0;
    while (my < mcus_y) : (my += 1) {
        var mx: u32 = 0;
        while (mx < mcus_x) : (mx += 1) {
            // One MCU: every component's blocks, in the order the scan header
            // listed them, and within a component in raster order.
            for (comps) |*c| {
                var by: u32 = 0;
                while (by < c.v) : (by += 1) {
                    var bx: u32 = 0;
                    while (bx < c.h) : (bx += 1) {
                        const block_x = mx * c.h + bx;
                        const block_y = my * c.v + by;
                        const block = c.coeffs[(@as(usize, block_y) * c.blocks_w + block_x) * block_len ..][0..block_len];
                        switch (mode) {
                            .count => countBlock(&stats.?.dc[c.table], &stats.?.ac[c.table], block, &c.pred),
                            .emit => try emitBlock(bits.?, block, c.dc, c.ac, &c.pred),
                        }
                    }
                }
            }

            done += 1;
            if (restart_interval != 0 and done < total) {
                left -= 1;
                if (left == 0) {
                    left = restart_interval;
                    // An interval ends on a byte boundary with the predictors
                    // reset, which is the whole of what makes the next one
                    // independently decodable.
                    if (mode == .emit) {
                        try bits.?.flush();
                        try w.?.writeAll(&.{ 0xff, 0xd0 + marker });
                    }
                    marker = (marker + 1) % 8;
                    for (comps) |*c| c.pred = 0;
                }
            }
        }
    }
}

/// The symbols one block would be coded as, without coding them.
fn countBlock(dc: *[257]u32, ac: *[257]u32, block: []const i16, pred: *i32) void {
    const value: i32 = block[0];
    dc[magnitude(value - pred.*)] += 1;
    pred.* = value;

    var run: u32 = 0;
    for (1..block_len) |k| {
        const v = block[zigzag[k]];
        if (v == 0) {
            run += 1;
            continue;
        }
        while (run >= 16) {
            ac[0xf0] += 1;
            run -= 16;
        }
        ac[(run << 4) | magnitude(v)] += 1;
        run = 0;
    }
    if (run > 0) ac[0x00] += 1;
}

/// One block of coefficients, entropy-coded.
fn emitBlock(
    bits: *huffman.BitWriter,
    block: []const i16,
    dc: *const huffman.Encoder,
    ac: *const huffman.Encoder,
    pred: *i32,
) EncodeError!void {
    // The DC coefficient, as a difference from the previous block.
    const value: i32 = block[0];
    const diff = value - pred.*;
    pred.* = value;
    const dc_size = magnitude(diff);
    try bits.write(dc.code[dc_size], @intCast(dc.len[dc_size]));
    try bits.write(encodeMagnitude(diff, dc_size), dc_size);

    // Then the AC coefficients in zig-zag order, as runs of zeroes and a
    // value. `0xF0` is a run of sixteen zeroes, `0x00` the end of the block.
    var run: u32 = 0;
    for (1..block_len) |k| {
        const v: i32 = block[zigzag[k]];
        if (v == 0) {
            run += 1;
            continue;
        }
        while (run >= 16) {
            try bits.write(ac.code[0xf0], @intCast(ac.len[0xf0]));
            run -= 16;
        }
        const size = magnitude(v);
        const symbol: u8 = @intCast((run << 4) | size);
        try bits.write(ac.code[symbol], @intCast(ac.len[symbol]));
        try bits.write(encodeMagnitude(v, size), size);
        run = 0;
    }
    if (run > 0) try bits.write(ac.code[0x00], @intCast(ac.len[0x00]));
}

// -- progressive -------------------------------------------------------------

/// One scan of a progressive file: which components it carries, which band of
/// the spectrum, and which bits of it.
///
/// `ss`..`se` is the band, in zig-zag order, and a scan carrying the DC
/// coefficient carries nothing else. `al` is the point transform: the scan
/// codes the coefficients shifted right by that much, so the bits below it are
/// left for a later scan. `ah` is what the *previous* scan of the same band
/// used, so a scan with `ah` non-zero is a refinement — it carries one more
/// bit of what is already there rather than the coefficients themselves.
pub const Scan = struct {
    /// Which components this scan carries, by index: 0 is luma, and 1 and 2
    /// are `Cb` and `Cr`. They must be in increasing order, which is the order
    /// `SOF` lists them in and the order a decoder reads them in.
    ///
    /// A scan of the DC coefficient may carry any number of them, interleaved;
    /// a scan of any AC band must carry exactly one, which is the
    /// specification's rule and not this encoder's.
    components: []const u8,
    /// The band of the spectrum this scan carries, in zig-zag order, both ends
    /// included. `0, 0` is the DC coefficient, which travels alone: a scan
    /// carrying it carries nothing else.
    ss: u8,
    se: u8,
    /// The point transform the previous scan of this band used, or zero when
    /// this is the first scan of it. A scan with `ah` other than zero is a
    /// refinement: it carries one more bit of coefficients already sent,
    /// rather than the coefficients themselves.
    ah: u5,
    /// The point transform this scan uses. It codes the coefficients shifted
    /// right by this much, leaving the bits below for a later scan; a final
    /// scan of a band has `al` of zero, and nothing is left.
    al: u5,
};

/// Why a scan script cannot be written.
///
/// Every one of these is the specification's rule rather than this encoder's
/// preference, except `incomplete`, which is explained on its own.
pub const ScriptProblem = enum {
    /// No scans at all.
    empty,
    /// A scan carrying no components, or more than the image has.
    bad_component_count,
    /// A component index the image does not have — asking for chroma of a
    /// greyscale image, most likely.
    no_such_component,
    /// Components out of order within a scan, or named twice. They have to
    /// appear in the order `SOF` lists them.
    components_out_of_order,
    /// A band running past the 64 coefficients a block has, or ending before
    /// it starts.
    bad_band,
    /// A scan carrying the DC coefficient and AC coefficients together, which
    /// no scan may do.
    dc_and_ac_together,
    /// An AC scan carrying more than one component.
    interleaved_ac,
    /// A point transform past the 13 bits one can shift by.
    bad_point_transform,
    /// The first scan of a band claiming to refine something, or a refinement
    /// that does not continue from where the previous scan of that band left
    /// off. Successive approximation descends one bit at a time and may not
    /// skip or repeat one.
    bad_succession,
    /// A coefficient the script never sends, or never sends the bottom bit of.
    ///
    /// This one is a choice. A progressive file that stops early is legal ---
    /// that is the whole point of the format, and a decoder shows what it has
    /// --- but a *script* that stops early asks this encoder to throw away
    /// part of the image without saying so, and quietly writing a file that
    /// does not round-trip is worse than refusing one.
    incomplete,
};

/// Whether a scan script can be written for an image of `components`
/// components, and if not, the first thing wrong with it.
///
/// The rules are checked in the order a reader would want them reported:
/// each scan on its own, then how the scans fit together, then whether they
/// cover the image between them.
pub fn checkScript(script: []const Scan, components: usize) ?ScriptProblem {
    if (script.len == 0) return .empty;

    // The point transform each coefficient of each component was last sent
    // at, or null for one that has not been sent. This is the whole of what
    // "successive approximation" has to be checked against.
    var sent: [4][block_len]?u5 = @splat(@splat(null));

    for (script) |scan| {
        if (scan.components.len == 0 or scan.components.len > components) {
            return .bad_component_count;
        }
        for (scan.components, 0..) |ci, i| {
            if (ci >= components) return .no_such_component;
            if (i > 0 and ci <= scan.components[i - 1]) return .components_out_of_order;
        }
        if (scan.se >= block_len or scan.se < scan.ss) return .bad_band;
        if (scan.ss == 0 and scan.se != 0) return .dc_and_ac_together;
        if (scan.ss != 0 and scan.components.len != 1) return .interleaved_ac;
        if (scan.ah > 13 or scan.al > 13) return .bad_point_transform;

        for (scan.components) |ci| {
            for (scan.ss..@as(usize, scan.se) + 1) |k| {
                if (sent[ci][k]) |last| {
                    // A refinement continues from the bit the last scan of
                    // this coefficient stopped at, and goes down by one.
                    if (scan.ah != last or scan.al + 1 != scan.ah) return .bad_succession;
                } else {
                    if (scan.ah != 0) return .bad_succession;
                }
                sent[ci][k] = scan.al;
            }
        }
    }

    for (0..components) |ci| {
        for (sent[ci]) |last| {
            if (last == null or last.? != 0) return .incomplete;
        }
    }
    return null;
}

/// The scan script, which is libjpeg's `jpeg_simple_progression` and is what
/// almost every progressive JPEG in the world was written with.
///
/// The order is chosen for what a decoder can show early: the DC scan alone is
/// the image at one eighth scale, the luma band after it puts most of the
/// detail in, and chroma — which the eye is least sensitive to — comes before
/// the rest of luma rather than after it because a grey image looks worse than
/// a soft one.
pub const progressive_colour = [_]Scan{
    .{ .components = &.{ 0, 1, 2 }, .ss = 0, .se = 0, .ah = 0, .al = 1 },
    .{ .components = &.{0}, .ss = 1, .se = 5, .ah = 0, .al = 2 },
    .{ .components = &.{2}, .ss = 1, .se = 63, .ah = 0, .al = 1 },
    .{ .components = &.{1}, .ss = 1, .se = 63, .ah = 0, .al = 1 },
    .{ .components = &.{0}, .ss = 6, .se = 63, .ah = 0, .al = 2 },
    .{ .components = &.{0}, .ss = 1, .se = 63, .ah = 2, .al = 1 },
    .{ .components = &.{ 0, 1, 2 }, .ss = 0, .se = 0, .ah = 1, .al = 0 },
    .{ .components = &.{2}, .ss = 1, .se = 63, .ah = 1, .al = 0 },
    .{ .components = &.{1}, .ss = 1, .se = 63, .ah = 1, .al = 0 },
    .{ .components = &.{0}, .ss = 1, .se = 63, .ah = 1, .al = 0 },
};

/// The same script with the chroma scans taken out.
pub const progressive_grey = [_]Scan{
    .{ .components = &.{0}, .ss = 0, .se = 0, .ah = 0, .al = 1 },
    .{ .components = &.{0}, .ss = 1, .se = 5, .ah = 0, .al = 2 },
    .{ .components = &.{0}, .ss = 6, .se = 63, .ah = 0, .al = 2 },
    .{ .components = &.{0}, .ss = 1, .se = 63, .ah = 2, .al = 1 },
    .{ .components = &.{0}, .ss = 0, .se = 0, .ah = 1, .al = 0 },
    .{ .components = &.{0}, .ss = 1, .se = 63, .ah = 1, .al = 0 },
};

/// How many correction bits may wait for the symbol they follow.
///
/// libjpeg's number, and it has to be one: the bits of a refinement scan are
/// held back until the next Huffman symbol, and an end-of-block run can put
/// that arbitrarily far away, so the run is forced out when the buffer is
/// within one block of full rather than letting it grow.
const max_corr_bits = 1000;

/// One progressive scan's coder: the tables, the statistics being gathered,
/// and the state that runs between blocks.
///
/// Both of the table sets are here rather than one, because the same walk runs
/// twice — once counting symbols and once writing them — and holding real
/// memory for the half that is not in use is simpler than threading an
/// optional through every function below.
const Coder = struct {
    stats: Stats = .{},
    dc: [2]huffman.Encoder = @splat(.{ .code = @splat(0), .len = @splat(0) }),
    ac: [2]huffman.Encoder = @splat(.{ .code = @splat(0), .len = @splat(0) }),
    bits: ?*huffman.BitWriter = null,
    out: ?*Io.Writer = null,
    /// Blocks that have ended with nothing more in this band and have not been
    /// coded yet, since one symbol can say that any number of them did.
    eobrun: u32 = 0,
    /// Correction bits waiting for the Huffman symbol they have to follow.
    corr: [max_corr_bits]u1 = @splat(0),
    corr_len: usize = 0,
};

/// Writes every scan of a progressive file, headers and all.
fn writeProgressive(
    w: *Io.Writer,
    gpa: Allocator,
    comps: []Outgoing,
    mcus_x: u32,
    mcus_y: u32,
    restart_interval: u16,
    script: []const Scan,
) EncodeError!void {
    const coder = try gpa.create(Coder);
    defer gpa.destroy(coder);

    for (script) |scan| {
        const order = scan.components;

        // The tables this scan needs, measured from the scan itself. A
        // refinement of the DC coefficient needs none at all: it is one raw
        // bit per block with nothing to code.
        const refines_dc = scan.ss == 0 and scan.ah != 0;
        coder.* = .{};
        if (!refines_dc) {
            try runProgressive(.count, coder, comps, order, scan, mcus_x, mcus_y, restart_interval);
            // One table per slot, not one per component: an interleaved DC
            // scan names chroma twice and they share a table.
            var done: [2]bool = @splat(false);
            for (order) |ci| {
                const slot = comps[ci].table;
                if (done[slot]) continue;
                done[slot] = true;
                const freq = if (scan.ss == 0) &coder.stats.dc[slot] else &coder.stats.ac[slot];
                const spec: huffman.Spec = .optimal(freq);
                // Built before it is written, so that a table this encoder
                // cannot use is refused rather than half written into the
                // file first.
                const enc = try encoderTable(&spec);
                const class: u8 = if (scan.ss == 0) 0x00 else 0x10;
                try writeHuffTable(w, class | slot, &spec);
                if (scan.ss == 0) coder.dc[slot] = enc else coder.ac[slot] = enc;
            }
        }

        try w.writeAll(&.{ 0xff, Marker.sos });
        try w.writeInt(u16, @intCast(6 + scan.components.len * 2), .big);
        try w.writeAll(&.{@intCast(scan.components.len)});
        for (order) |ci| {
            const c = comps[ci];
            const tables: u8 = if (scan.ss == 0) c.table << 4 else c.table;
            try w.writeAll(&.{ c.id, tables });
        }
        try w.writeAll(&.{ scan.ss, scan.se, (@as(u8, scan.ah) << 4) | scan.al });

        var bits: huffman.BitWriter = .init(w);
        coder.bits = &bits;
        coder.out = w;
        try runProgressive(.emit, coder, comps, order, scan, mcus_x, mcus_y, restart_interval);
    }
}

/// Walks the blocks of one progressive scan, either counting the symbols or
/// writing them.
///
/// The traversal is the decoder's, and has to be: an interleaved scan — which
/// in this script means a scan of the DC coefficients — walks whole MCUs and
/// so walks the padding that fills out the last one, while a scan carrying a
/// single component walks that component's own blocks and stops where the
/// image does.
fn runProgressive(
    comptime mode: Pass,
    k: *Coder,
    comps: []Outgoing,
    order: []const u8,
    scan: Scan,
    mcus_x: u32,
    mcus_y: u32,
    restart_interval: u16,
) EncodeError!void {
    for (comps) |*c| c.pred = 0;
    k.eobrun = 0;
    k.corr_len = 0;

    const interleaved = order.len > 1;
    const first = &comps[order[0]];
    const units_x = if (interleaved) mcus_x else first.sblocks_w;
    const units_y = if (interleaved) mcus_y else first.sblocks_h;

    const total = @as(u64, units_x) * units_y;
    var left = restart_interval;
    var marker: u8 = 0;
    var unit: u64 = 0;

    var y: u32 = 0;
    while (y < units_y) : (y += 1) {
        var x: u32 = 0;
        while (x < units_x) : (x += 1) {
            if (interleaved) {
                for (order) |ci| {
                    const c = &comps[ci];
                    var by: u32 = 0;
                    while (by < c.v) : (by += 1) {
                        var bx: u32 = 0;
                        while (bx < c.h) : (bx += 1) {
                            try progressiveBlock(mode, k, c, scan, x * c.h + bx, y * c.v + by);
                        }
                    }
                }
            } else {
                try progressiveBlock(mode, k, first, scan, x, y);
            }

            unit += 1;
            if (restart_interval != 0 and unit < total) {
                left -= 1;
                if (left == 0) {
                    left = restart_interval;
                    // An end-of-block run cannot cross a restart marker, since
                    // the next interval has to be decodable on its own.
                    try flushEobRun(mode, k, first);
                    if (mode == .emit) {
                        try k.bits.?.flush();
                        try k.out.?.writeAll(&.{ 0xff, 0xd0 + marker });
                    }
                    marker = (marker + 1) % 8;
                    for (comps) |*c| c.pred = 0;
                    k.eobrun = 0;
                    k.corr_len = 0;
                }
            }
        }
    }

    try flushEobRun(mode, k, first);
    if (mode == .emit) try k.bits.?.flush();
}

/// What one block contributes to one scan.
fn progressiveBlock(
    comptime mode: Pass,
    k: *Coder,
    c: *Outgoing,
    scan: Scan,
    bx: u32,
    by: u32,
) EncodeError!void {
    const block = c.coeffs[(@as(usize, by) * c.blocks_w + bx) * block_len ..][0..block_len];
    if (scan.ss == 0) {
        if (scan.ah == 0) {
            // The DC coefficient, shifted down by the point transform and
            // coded as a difference from the previous block as in a baseline
            // scan. The shift is arithmetic, which for the DC coefficient is
            // what the specification asks for.
            const value: i32 = @as(i32, block[0]) >> scan.al;
            const diff = value - c.pred;
            c.pred = value;
            const size = magnitude(diff);
            switch (mode) {
                .count => k.stats.dc[c.table][size] += 1,
                .emit => {
                    const enc = &k.dc[c.table];
                    try k.bits.?.write(enc.code[size], @intCast(enc.len[size]));
                    try k.bits.?.write(encodeMagnitude(diff, size), size);
                },
            }
        } else if (mode == .emit) {
            // A refinement of the DC coefficient is one raw bit, with no
            // symbol and so no table.
            try k.bits.?.write(@as(u32, @bitCast(@as(i32, block[0]) >> scan.al)) & 1, 1);
        }
        return;
    }
    if (scan.ah == 0) {
        try acFirstBlock(mode, k, c, block, scan);
    } else {
        try acRefineBlock(mode, k, c, block, scan);
    }
}

/// One AC symbol of the scan's band.
fn acSymbol(comptime mode: Pass, k: *Coder, c: *Outgoing, symbol: u8) EncodeError!void {
    switch (mode) {
        .count => k.stats.ac[c.table][symbol] += 1,
        .emit => {
            const enc = &k.ac[c.table];
            try k.bits.?.write(enc.code[symbol], @intCast(enc.len[symbol]));
        },
    }
}

/// Codes however many blocks have ended, and then the correction bits that
/// were waiting behind the run.
fn flushEobRun(comptime mode: Pass, k: *Coder, c: *Outgoing) EncodeError!void {
    if (k.eobrun == 0) return;

    // The symbol names the *number of bits* in the run length, and the run
    // length itself follows less its leading one — so a run of one is a
    // symbol on its own, which is what makes the ordinary case cheap.
    var nbits: u6 = 0;
    var rest = k.eobrun >> 1;
    while (rest != 0) : (rest >>= 1) nbits += 1;

    try acSymbol(mode, k, c, @as(u8, @intCast(nbits)) << 4);
    if (mode == .emit and nbits != 0) try k.bits.?.write(k.eobrun, nbits);
    k.eobrun = 0;

    if (mode == .emit) {
        for (k.corr[0..k.corr_len]) |b| try k.bits.?.write(b, 1);
    }
    k.corr_len = 0;
}

/// The first scan over a band: the coefficients themselves, shifted right by
/// the point transform.
fn acFirstBlock(
    comptime mode: Pass,
    k: *Coder,
    c: *Outgoing,
    block: []const i16,
    scan: Scan,
) EncodeError!void {
    var run: u32 = 0;
    var i: usize = scan.ss;
    while (i <= scan.se) : (i += 1) {
        const raw: i32 = block[zigzag[i]];
        // The point transform of an AC coefficient divides towards zero rather
        // than shifting, so a coefficient of -1 at `al` of 1 becomes zero and
        // not minus one.
        const negative = raw < 0;
        const shifted: i32 = @as(i32, @intCast(@abs(raw))) >> scan.al;
        if (shifted == 0) {
            run += 1;
            continue;
        }
        const value: i32 = if (negative) -shifted else shifted;

        // Anything this block still owes has to be written before the run that
        // ends here can be.
        try flushEobRun(mode, k, c);
        while (run > 15) {
            try acSymbol(mode, k, c, 0xf0);
            run -= 16;
        }

        const size = magnitude(value);
        try acSymbol(mode, k, c, @intCast((run << 4) | size));
        if (mode == .emit) try k.bits.?.write(encodeMagnitude(value, size), size);
        run = 0;
    }

    // Trailing zeroes are not coded; the block simply ends, and the run of
    // blocks ending here is coded once when something else has to be said.
    if (run > 0) {
        k.eobrun += 1;
        if (k.eobrun == 0x7fff) try flushEobRun(mode, k, c);
    }
}

/// A later scan over a band: one more bit of everything already there, and the
/// coefficients that become non-zero at this precision.
///
/// The awkward one, and it is worth saying why. Two things are interleaved:
/// the newly non-zero coefficients, coded as runs of zeroes exactly as in a
/// first scan, and a correction bit for every coefficient that was *already*
/// non-zero and is passed on the way. The correction bits are not Huffman
/// coded at all — they are raw bits, written after the symbol whose run
/// stepped over them — so they have to be held back until that symbol is
/// known, and an end-of-block run can hold them back across whole blocks.
///
/// The run of zeroes counts only coefficients that are still zero. A
/// coefficient that was already non-zero is invisible to the run and
/// contributes only its correction bit, which is the rule that makes a
/// refinement scan cheap and the code fiddly.
fn acRefineBlock(
    comptime mode: Pass,
    k: *Coder,
    c: *Outgoing,
    block: []const i16,
    scan: Scan,
) EncodeError!void {
    // The magnitudes after the point transform, and where the last newly
    // non-zero coefficient is. A run of zeroes may be folded into an
    // end-of-block run only if nothing new follows it, so knowing where the
    // last new one is decides whether a run of sixteen has to be written.
    var absolute: [block_len]u32 = undefined;
    var last_new: usize = 0;
    for (scan.ss..@as(usize, scan.se) + 1) |i| {
        const v: u32 = @abs(@as(i32, block[zigzag[i]])) >> scan.al;
        absolute[i] = v;
        if (v == 1) last_new = i;
    }

    // This block's own correction bits, kept apart from the ones carried over
    // from earlier blocks behind an end-of-block run: those go out with the
    // run, and these go out behind the symbol that steps over them.
    var mine: [block_len]u1 = undefined;
    var mine_len: usize = 0;

    var run: u32 = 0;
    for (scan.ss..@as(usize, scan.se) + 1) |i| {
        const v = absolute[i];
        if (v == 0) {
            run += 1;
            continue;
        }

        while (run > 15 and i <= last_new) {
            try flushEobRun(mode, k, c);
            try acSymbol(mode, k, c, 0xf0);
            run -= 16;
            if (mode == .emit) {
                for (mine[0..mine_len]) |b| try k.bits.?.write(b, 1);
            }
            mine_len = 0;
        }

        if (v > 1) {
            // Already non-zero at this precision: nothing but the next bit of
            // its magnitude, and the run of zeroes does not see it at all.
            mine[mine_len] = @intCast(v & 1);
            mine_len += 1;
            continue;
        }

        try flushEobRun(mode, k, c);
        try acSymbol(mode, k, c, @intCast((run << 4) | 1));
        if (mode == .emit) {
            // The sign of the coefficient that has just become non-zero, and
            // then everything that was waiting behind this run.
            try k.bits.?.write(@as(u32, if (block[zigzag[i]] < 0) 0 else 1), 1);
            for (mine[0..mine_len]) |b| try k.bits.?.write(b, 1);
        }
        mine_len = 0;
        run = 0;
    }

    if (run > 0 or mine_len > 0) {
        k.eobrun += 1;
        @memcpy(k.corr[k.corr_len..][0..mine_len], mine[0..mine_len]);
        k.corr_len += mine_len;
        // Forced out before either counter can overflow: a run length is coded
        // in at most fourteen bits, and the correction bits have a fixed
        // buffer that one more block could fill the rest of.
        if (k.eobrun == 0x7fff or k.corr_len > max_corr_bits - block_len) {
            try flushEobRun(mode, k, c);
        }
    }
}

/// How many bits a coefficient needs, which is what its Huffman symbol names.
fn magnitude(v: i32) u6 {
    const a: u32 = @abs(v);
    return @intCast(32 - @clz(a));
}

/// The bits that follow the symbol, in the representation `receiveExtend`
/// reverses: a positive value as it is, a negative one with the leading bit
/// clear.
fn encodeMagnitude(v: i32, size: u6) u32 {
    if (size == 0) return 0;
    const adjusted: i32 = if (v >= 0) v else v - 1;
    const mask: u32 = (@as(u32, 1) << @intCast(size)) - 1;
    return @as(u32, @bitCast(adjusted)) & mask;
}

/// `src` composited over an opaque `bg`. The same arithmetic as `bmp.over`,
/// for the same reason.
fn over(src: Rgba8, bg: Rgba8) Rgba8 {
    if (src.a == 255) return .rgb(src.r, src.g, src.b);
    if (src.a == 0) return .rgb(bg.r, bg.g, bg.b);
    const a: u32 = src.a;
    const blend = struct {
        fn f(s: u8, b: u8, alpha: u32) u8 {
            return @intCast((@as(u32, s) * alpha + @as(u32, b) * (255 - alpha) + 127) / 255);
        }
    }.f;
    return .rgb(blend(src.r, bg.r, a), blend(src.g, bg.g, a), blend(src.b, bg.b, a));
}
