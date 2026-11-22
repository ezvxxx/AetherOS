// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! VP8L: WebP's lossless bitstream.
//!
//! A five-byte header, then one entropy-coded image, then — read first and
//! applied last — up to four reversible transforms that the encoder used to
//! make that image cheaper to code.
//!
//! ## Everything is an image
//!
//! The shape worth understanding before anything else is that **four of the
//! things a VP8L file contains are themselves VP8L images**: the entropy
//! image that says which prefix codes a block of pixels uses, the predictor
//! transform's per-block modes, the colour transform's per-block
//! coefficients, and the colour-indexing transform's palette. Each is decoded
//! by the same machinery as the picture, at a lower resolution, with its
//! payload in whichever channel the thing in question happens to use.
//!
//! That recursion is bounded at exactly two levels, and the bound is stated
//! as a call graph rather than as a counter: `decodeTop` is the only function
//! that reads transforms or a meta-prefix image, and the only caller of
//! `decodeSub`, which reads neither. A third level is not something this code
//! declines to do — it is something it cannot say.
//!
//! ## The pixel loop
//!
//! One symbol out of the green code decides what a pixel is:
//!
//! | symbol | meaning |
//! | --- | --- |
//! | 0–255 | a literal: this is green, and red, blue and alpha follow from their own codes |
//! | 256–279 | a backward reference: a length, then a distance |
//! | 280 and up | an index into the colour cache |
//!
//! A backward reference's distance is not a plain pixel count. The first 120
//! codes name a neighbourhood — seven rows up, eight columns either side —
//! because the pixel above is a far commoner match than the pixel 640 back,
//! and spending a short code on it is most of why this format compresses
//! photographs at all. Only past 120 does a code mean a distance.
//!
//! ## What a decoder has to be careful about
//!
//! **The colour-indexing transform narrows the image.** After it, every
//! transform read afterwards and the pixel data itself are at the narrowed
//! width, and only inverting it restores the declared one.
//!
//! **Transforms are undone in the reverse of the order they were read**, each
//! at the width it was read at.
//!
//! **Every pixel written goes into the colour cache**, in the order it was
//! written — literals, the pixels of a copied run, and the results of cache
//! lookups alike. A decoder that inserts only literals decodes the first few
//! hundred pixels of a file correctly and then diverges.

const std = @import("std");
const Io = std.Io;
const mem = std.mem;
const math = std.math;
const testing = std.testing;
const Allocator = mem.Allocator;

const common = @import("../common.zig");
const DecodeError = common.DecodeError;
const Limits = common.Limits;
const prefix = @import("prefix.zig");

/// The byte a VP8L bitstream begins with.
pub const signature = 0x2f;

/// The largest image the header can describe: fourteen bits a side, plus one.
pub const max_side = 1 << 14;

/// Literal green values, then the backward-reference length codes. Colour
/// cache indices extend this alphabet when a cache is in use.
const literal_codes = 256;
const length_codes = 24;
const distance_codes = 40;

/// The five codes that decode one pixel, and how large each one's alphabet is.
const alphabet_sizes = [5]u16{ literal_codes + length_codes, 256, 256, 256, distance_codes };
const green = 0;
const red = 1;
const blue = 2;
const alpha = 3;
const distance = 4;

/// The first distance code that means a plain distance rather than a
/// neighbour.
const plane_codes = 120;

/// What a VP8L header says.
pub const Header = struct {
    width: u32,
    height: u32,
    /// The encoder's hint that some pixel is not opaque. A hint only: the
    /// specification says it should be zero when every alpha is 255 and does
    /// not say it must be, so nothing is decided by it.
    has_alpha: bool,
};

/// Reads the five-byte header out of five bytes.
///
/// A separate entry point from `readHeader` for a reason worth stating: a
/// `prefix.BitReader` fills its accumulator eight bytes at a time, so reading
/// a header through one takes more of the stream than the header occupies.
/// That is exactly what is wanted when the same reader goes on to decode the
/// bitstream, and exactly wrong when the header is being peeked at and the
/// stream handed to something else — which is what the container does to
/// learn an image's size.
pub fn parseHeader(body: *const [5]u8) DecodeError!Header {
    var r: Io.Reader = .fixed(body);
    var br: prefix.BitReader = .init(&r);
    return readHeader(&br);
}

/// Reads the five-byte header.
pub fn readHeader(br: *prefix.BitReader) DecodeError!Header {
    if (try br.take(8) != signature) return error.InvalidData;
    const width = try br.take(14) + 1;
    const height = try br.take(14) + 1;
    const has_alpha = try br.takeBit() == 1;
    // The only version this format has. A file declaring another is not one
    // this library can guess at.
    if (try br.take(3) != 0) return error.Unsupported;
    return .{ .width = width, .height = height, .has_alpha = has_alpha };
}

/// The neighbourhood the first 120 distance codes name, as (x, y) offsets
/// back from the current pixel.
///
/// Taken from the specification's own table rather than transcribed: the
/// order is not derivable — it is roughly by increasing distance, and the
/// middle of it is not what a reader would guess — and a single wrong entry
/// would corrupt only the files that happened to use that code.
const distance_map = [plane_codes][2]i8{
    .{ 0, 1 },  .{ 1, 0 },  .{ 1, 1 },  .{ -1, 1 }, .{ 0, 2 },  .{ 2, 0 },
    .{ 1, 2 },  .{ -1, 2 }, .{ 2, 1 },  .{ -2, 1 }, .{ 2, 2 },  .{ -2, 2 },
    .{ 0, 3 },  .{ 3, 0 },  .{ 1, 3 },  .{ -1, 3 }, .{ 3, 1 },  .{ -3, 1 },
    .{ 2, 3 },  .{ -2, 3 }, .{ 3, 2 },  .{ -3, 2 }, .{ 0, 4 },  .{ 4, 0 },
    .{ 1, 4 },  .{ -1, 4 }, .{ 4, 1 },  .{ -4, 1 }, .{ 3, 3 },  .{ -3, 3 },
    .{ 2, 4 },  .{ -2, 4 }, .{ 4, 2 },  .{ -4, 2 }, .{ 0, 5 },  .{ 3, 4 },
    .{ -3, 4 }, .{ 4, 3 },  .{ -4, 3 }, .{ 5, 0 },  .{ 1, 5 },  .{ -1, 5 },
    .{ 5, 1 },  .{ -5, 1 }, .{ 2, 5 },  .{ -2, 5 }, .{ 5, 2 },  .{ -5, 2 },
    .{ 4, 4 },  .{ -4, 4 }, .{ 3, 5 },  .{ -3, 5 }, .{ 5, 3 },  .{ -5, 3 },
    .{ 0, 6 },  .{ 6, 0 },  .{ 1, 6 },  .{ -1, 6 }, .{ 6, 1 },  .{ -6, 1 },
    .{ 2, 6 },  .{ -2, 6 }, .{ 6, 2 },  .{ -6, 2 }, .{ 4, 5 },  .{ -4, 5 },
    .{ 5, 4 },  .{ -5, 4 }, .{ 3, 6 },  .{ -3, 6 }, .{ 6, 3 },  .{ -6, 3 },
    .{ 0, 7 },  .{ 7, 0 },  .{ 1, 7 },  .{ -1, 7 }, .{ 5, 5 },  .{ -5, 5 },
    .{ 7, 1 },  .{ -7, 1 }, .{ 4, 6 },  .{ -4, 6 }, .{ 6, 4 },  .{ -6, 4 },
    .{ 2, 7 },  .{ -2, 7 }, .{ 7, 2 },  .{ -7, 2 }, .{ 3, 7 },  .{ -3, 7 },
    .{ 7, 3 },  .{ -7, 3 }, .{ 5, 6 },  .{ -5, 6 }, .{ 6, 5 },  .{ -6, 5 },
    .{ 8, 0 },  .{ 4, 7 },  .{ -4, 7 }, .{ 7, 4 },  .{ -7, 4 }, .{ 8, 1 },
    .{ 8, 2 },  .{ 6, 6 },  .{ -6, 6 }, .{ 8, 3 },  .{ 5, 7 },  .{ -5, 7 },
    .{ 7, 5 },  .{ -7, 5 }, .{ 8, 4 },  .{ 6, 7 },  .{ -6, 7 }, .{ 7, 6 },
    .{ -7, 6 }, .{ 8, 5 },  .{ 7, 7 },  .{ -7, 7 }, .{ 8, 6 },  .{ 8, 7 },
};

/// A distance code, as a number of pixels back in scan-line order.
fn planeDistance(width: u32, code: u32) u32 {
    if (code > plane_codes) return code - plane_codes;
    const offset = distance_map[code - 1];
    const dist = @as(i64, offset[0]) + @as(i64, offset[1]) * width;
    // A neighbour above and to the right of the first pixel of a very narrow
    // image lands before the start. One pixel back is what the specification
    // says to use.
    return if (dist >= 1) @intCast(dist) else 1;
}

/// A length or distance: four values outright, then a prefix and extra bits.
fn readExtended(br: *prefix.BitReader, symbol: u16) DecodeError!u32 {
    if (symbol < 4) return symbol + 1;
    const extra: u6 = @intCast((symbol - 2) >> 1);
    const offset: u32 = @as(u32, 2 + (symbol & 1)) << @intCast(extra);
    return offset + try br.take(extra) + 1;
}

/// The recently used colours, addressed by a hash of the colour itself.
const ColourCache = struct {
    entries: []u32,
    bits: u4,

    /// Knuth's multiplicative hash, with the format's own constant.
    fn slot(self: ColourCache, argb: u32) usize {
        return (0x1e35a7bd *% argb) >> @intCast(32 - @as(u6, self.bits));
    }

    fn insert(self: ColourCache, argb: u32) void {
        self.entries[self.slot(argb)] = argb;
    }
};

/// The five codes that decode one pixel.
const Group = struct {
    codes: [5]prefix.Code,
};

/// The entropy image, reduced to what the pixel loop needs: one compact group
/// index per block.
const Meta = struct {
    index: []const u16,
    width: u32,
    bits: u5,
};

/// One transform, and the width it was read at.
const Transform = struct {
    kind: Kind,
    /// The image width *before* this transform was applied, which for the
    /// colour-indexing one is the width inverting it restores.
    width: u32,
    height: u32,
    /// The block size, as a shift. Unused by subtract-green.
    bits: u5 = 0,
    /// The sub-image: per-block modes, per-block coefficients, or the
    /// palette. Empty for subtract-green.
    data: []u32 = &.{},

    const Kind = enum(u2) { predictor, colour, subtract_green, palette };
};

/// `(size + (1 << bits) - 1) >> bits`: the block-resolution size of a
/// transform or entropy image.
fn subSampleSize(size: u32, bits: u5) u32 {
    return (size + (@as(u32, 1) << bits) - 1) >> bits;
}

/// The state one bitstream is decoded with.
pub const Decode = struct {
    br: prefix.BitReader,
    gpa: Allocator,
    limits: Limits,
    /// One buffer of code lengths, reused by every code read anywhere in the
    /// bitstream.
    lengths: []u8,

    pub fn init(gpa: Allocator, r: *Io.Reader, limits: Limits) Allocator.Error!Decode {
        return .{
            .br = .init(r),
            .gpa = gpa,
            .limits = limits,
            .lengths = try gpa.alloc(u8, prefix.max_symbols),
        };
    }

    pub fn deinit(self: *Decode) void {
        self.gpa.free(self.lengths);
        self.* = undefined;
    }
};

/// How much pool one group of five codes can need.
///
/// The stored symbols of all five, plus the nineteen the code-length code
/// takes while a code is being read — that one is built from the same pool
/// and released again, so it is headroom rather than storage, but a pool
/// without it cannot read the last code it has room to store.
fn groupSymbols(cache_bits: u4) usize {
    var total: usize = prefix.code_length_symbols;
    for (alphabet_sizes) |n| total += n;
    if (cache_bits > 0) total += @as(usize, 1) << cache_bits;
    return total;
}

/// The most memory one bitstream may spend on prefix-code symbol tables.
///
/// This is the one place in the format where a few bytes of input buy an
/// unbounded allocation. The number of prefix-code groups a file declares is
/// one more than the largest value in its entropy image, and that value is
/// two bytes of a pixel — so a three-pixel entropy image may legitimately ask
/// for sixty-five thousand groups, at about six kilobytes of table for a
/// hundred and thirty bytes of input.
///
/// Two things answer it, and both are wanted. Only the groups some pixel
/// actually names are *stored* — the rest still have to be read, since they
/// sit consecutively in the stream with nowhere to seek to, but reading and
/// discarding costs nothing. And every symbol any code stores is drawn
/// through one budget, which is this.
///
/// `Limits` has no working-memory budget to take it from — every other codec
/// here allocates pixels and little else — so it is derived from the one it
/// has. A caller who has said how many pixels it will pay for has implicitly
/// said how large an image it expects, and a real file of that size spends a
/// few tens of kilobytes here. The floor is what stops a caller who lowered
/// `max_pixels` for thumbnails from being refused a legitimate small file.
fn tableBudget(limits: Limits) usize {
    const derived = limits.max_pixels / 8;
    return @max(1 << 16, @min(derived, 1 << 22));
}

/// Reads one group of five prefix codes.
fn readGroup(d: *Decode, pool: *prefix.SymbolPool, cache_bits: u4) DecodeError!Group {
    var g: Group = .{ .codes = @splat(.{}) };
    for (&g.codes, alphabet_sizes, 0..) |*code, size, i| {
        var alphabet = size;
        // Only the green code carries the colour-cache indices, because only
        // it is read for every pixel.
        if (i == green and cache_bits > 0) alphabet += @as(u16, 1) << cache_bits;
        code.* = try prefix.readCode(&d.br, alphabet, d.lengths, pool);
    }
    return g;
}

/// Reads the colour-cache declaration, if there is one.
fn readCacheBits(d: *Decode) DecodeError!u4 {
    if (try d.br.takeBit() == 0) return 0;
    const bits = try d.br.take(4);
    // Zero would mean a cache of one entry declared as though it were absent,
    // which the format does not allow; eleven is the largest it does.
    if (bits < 1 or bits > 11) return error.InvalidData;
    return @intCast(bits);
}

/// Decodes an entropy-coded image with no transforms and no meta-prefix
/// image: one group of five codes over the whole of it.
///
/// This is what the entropy image, both transform images and the palette all
/// are, and it is the whole of the recursion bound. Nothing it reads can name
/// another image, so it calls nothing that could reach `decodeTop`.
fn decodeSub(d: *Decode, width: u32, height: u32, out: []u32) DecodeError!void {
    std.debug.assert(out.len == @as(usize, width) * height);

    const cache_bits = try readCacheBits(d);

    var pool: prefix.SymbolPool = try .init(d.gpa, @min(groupSymbols(cache_bits), tableBudget(d.limits)));
    defer pool.deinit(d.gpa);
    const groups = [1]Group{try readGroup(d, &pool, cache_bits)};

    var cache: ?ColourCache = null;
    if (cache_bits > 0) {
        const entries = try d.gpa.alloc(u32, @as(usize, 1) << cache_bits);
        @memset(entries, 0);
        cache = .{ .entries = entries, .bits = cache_bits };
    }
    defer if (cache) |c| d.gpa.free(c.entries);

    try decodePixels(d, width, out, &groups, null, if (cache) |*c| c else null);
}

/// Decodes the top-level image: the transforms, an optional meta-prefix
/// image, the pixels, and then the inverse transforms in reverse.
///
/// The only caller of `decodeSub`, and the only place a transform or a
/// meta-prefix may appear.
pub fn decodeTop(d: *Decode, width: u32, height: u32, out: []u32) DecodeError!void {
    std.debug.assert(out.len == @as(usize, width) * height);

    var transforms: [4]Transform = undefined;
    var count: usize = 0;
    var seen: u4 = 0;
    // The width the *next* thing read will be at. Only the colour-indexing
    // transform changes it, and everything after it --- another transform,
    // the entropy image, the pixels --- is at the narrowed width.
    var narrow = width;

    errdefer for (transforms[0..count]) |t| d.gpa.free(t.data);

    while (try d.br.takeBit() == 1) {
        if (count == transforms.len) return error.InvalidData;
        const kind: Transform.Kind = @fromBackingInt(@intCast(try d.br.take(2)));
        const bit = @as(u4, 1) << @backingInt(kind);
        // Each of the four may appear at most once. A file repeating one is
        // describing two different things with the same name.
        if (seen & bit != 0) return error.InvalidData;
        seen |= bit;

        var t: Transform = .{ .kind = kind, .width = narrow, .height = height };
        switch (kind) {
            .predictor, .colour => {
                t.bits = @intCast(try d.br.take(3) + 2);
                const sub_w = subSampleSize(narrow, t.bits);
                const sub_h = subSampleSize(height, t.bits);
                t.data = try d.gpa.alloc(u32, @as(usize, sub_w) * sub_h);
                // Until it is stored below, this is the one reference to it:
                // the outer `errdefer` only knows about transforms that have
                // been counted.
                errdefer d.gpa.free(t.data);
                try decodeSub(d, sub_w, sub_h, t.data);
            },
            .subtract_green => {},
            .palette => {
                const colours = try d.br.take(8) + 1;
                t.bits = switch (colours) {
                    1, 2 => 3,
                    3, 4 => 2,
                    5...16 => 1,
                    else => 0,
                };
                t.data = try d.gpa.alloc(u32, colours);
                errdefer d.gpa.free(t.data);
                try decodeSub(d, colours, 1, t.data);
                // The palette is stored as differences, because the deltas
                // between neighbouring colours carry far less entropy than
                // the colours do. Each channel separately, and wrapping.
                for (1..t.data.len) |i| t.data[i] = addPixels(t.data[i], t.data[i - 1]);
                narrow = subSampleSize(narrow, t.bits);
            },
        }
        transforms[count] = t;
        count += 1;
    }

    // The pixels, at whatever width the transforms left.
    var buffer = out;
    var owned: ?[]u32 = null;
    defer if (owned) |b| d.gpa.free(b);
    if (narrow != width) {
        const b = try d.gpa.alloc(u32, @as(usize, narrow) * height);
        owned = b;
        buffer = b;
    }

    try decodeEntropyImage(d, narrow, height, buffer);

    // Undone in the reverse of the order they were read, each at the width it
    // was read at.
    var i = count;
    while (i > 0) {
        i -= 1;
        const t = transforms[i];
        switch (t.kind) {
            .predictor => inversePredictor(t, buffer),
            .colour => inverseColour(t, buffer),
            .subtract_green => inverseSubtractGreen(buffer),
            .palette => {
                // The one transform that changes the width, so it runs from
                // the narrow buffer into the wide one rather than in place.
                inversePalette(t, buffer, out);
                buffer = out;
                if (owned) |b| d.gpa.free(b);
                owned = null;
            },
        }
        d.gpa.free(t.data);
        transforms[i].data = &.{};
    }
}

/// The entropy-coded pixels of the top-level image: a colour cache, an
/// optional meta-prefix image, the groups, and then the loop.
fn decodeEntropyImage(d: *Decode, width: u32, height: u32, out: []u32) DecodeError!void {
    const cache_bits = try readCacheBits(d);

    var meta: ?Meta = null;
    var meta_index: []u16 = &.{};
    defer d.gpa.free(meta_index);
    var named: usize = 1;
    var declared: usize = 1;
    var compact: []u16 = &.{};
    defer d.gpa.free(compact);

    if (try d.br.takeBit() == 1) {
        const bits: u5 = @intCast(try d.br.take(3) + 2);
        const mw = subSampleSize(width, bits);
        const mh = subSampleSize(height, bits);

        const image = try d.gpa.alloc(u32, @as(usize, mw) * mh);
        defer d.gpa.free(image);
        try decodeSub(d, mw, mh, image);

        // The group number lives in the red and green bytes of each pixel,
        // so a file may name any of sixty-five thousand groups from three
        // pixels. Which groups are *used* is what bounds the work, so that is
        // what is counted, and the indices are remapped to a compact range.
        var highest: u32 = 0;
        for (image) |px| highest = @max(highest, (px >> 8) & 0xffff);
        declared = highest + 1;

        compact = try d.gpa.alloc(u16, declared);
        @memset(compact, 0xffff);
        for (image) |px| compact[(px >> 8) & 0xffff] = 0;
        named = 0;
        for (compact) |*slot| {
            if (slot.* == 0) {
                slot.* = @intCast(named);
                named += 1;
            }
        }

        meta_index = try d.gpa.alloc(u16, image.len);
        for (image, meta_index) |px, *out_index| out_index.* = compact[(px >> 8) & 0xffff];
        meta = .{ .index = meta_index, .width = mw, .bits = bits };
    }

    var pool: prefix.SymbolPool = try .init(
        d.gpa,
        @min(named *| groupSymbols(cache_bits), tableBudget(d.limits)),
    );
    defer pool.deinit(d.gpa);

    const groups = try d.gpa.alloc(Group, named);
    defer d.gpa.free(groups);
    for (0..declared) |i| {
        // A group nothing names still has to be read --- the groups sit one
        // after another and there is nowhere to seek to --- but it does not
        // have to be kept, and giving the pool its space back is just moving
        // the mark.
        const mark = pool.used;
        const g = try readGroup(d, &pool, cache_bits);
        if (compact.len == 0) {
            groups[0] = g;
        } else if (compact[i] != 0xffff) {
            groups[compact[i]] = g;
        } else {
            pool.used = mark;
        }
    }

    var cache: ?ColourCache = null;
    if (cache_bits > 0) {
        const entries = try d.gpa.alloc(u32, @as(usize, 1) << cache_bits);
        @memset(entries, 0);
        cache = .{ .entries = entries, .bits = cache_bits };
    }
    defer if (cache) |c| d.gpa.free(c.entries);

    try decodePixels(d, width, out, groups, meta, if (cache) |*c| c else null);
}

/// The loop that actually writes pixels.
///
/// The same for the top-level image and for a sub-image; `meta` is null for
/// the second, which is the only difference between them.
fn decodePixels(
    d: *Decode,
    width: u32,
    out: []u32,
    groups: []const Group,
    meta: ?Meta,
    cache: ?*ColourCache,
) DecodeError!void {
    if (groups.len == 0) return error.InvalidData;

    var pos: usize = 0;
    // Everything below this has been put in the colour cache. It lags `pos`
    // so that a copied run goes in a pixel at a time, in the order it was
    // written, which is what the encoder assumed.
    var cached: usize = 0;
    var x: u32 = 0;
    var y: u32 = 0;

    while (pos < out.len) {
        const g = if (meta) |m| blk: {
            const at = @as(usize, y >> m.bits) * m.width + (x >> m.bits);
            const index = m.index[at];
            if (index >= groups.len) return error.InvalidData;
            break :blk &groups[index];
        } else &groups[0];

        const symbol = try g.codes[green].read(&d.br);

        if (symbol < literal_codes) {
            // A literal: green came out of the first code, and the other
            // three channels have codes of their own.
            const r = try g.codes[red].read(&d.br);
            const b = try g.codes[blue].read(&d.br);
            const a = try g.codes[alpha].read(&d.br);
            out[pos] = (@as(u32, a) << 24) | (@as(u32, r) << 16) |
                (@as(u32, symbol) << 8) | @as(u32, b);
            pos += 1;
            x += 1;
            if (x == width) {
                x = 0;
                y += 1;
            }
        } else if (symbol < literal_codes + length_codes) {
            // A backward reference.
            const length = try readExtended(&d.br, symbol - literal_codes);
            const code = try readExtended(&d.br, try g.codes[distance].read(&d.br));
            const back = planeDistance(width, code);

            if (back > pos) return error.InvalidData;
            if (length > out.len - pos) return error.InvalidData;
            // One pixel at a time: a run may overlap itself, which is how
            // LZ77 spells a repeat, so this cannot be a block move.
            for (0..length) |k| out[pos + k] = out[pos + k - back];

            const total = x + length;
            y += total / width;
            x = total % width;
            pos += length;
        } else {
            const c = cache orelse return error.InvalidData;
            const index = symbol - (literal_codes + length_codes);
            if (index >= c.entries.len) return error.InvalidData;
            // Whatever has been written since the last look has to go in
            // before this one is answered.
            while (cached < pos) : (cached += 1) c.insert(out[cached]);
            out[pos] = c.entries[index];
            pos += 1;
            x += 1;
            if (x == width) {
                x = 0;
                y += 1;
            }
        }

        if (cache) |c| while (cached < pos) : (cached += 1) c.insert(out[cached]);
    }
}

// -- the inverse transforms --------------------------------------------------

/// Per-channel addition, wrapping within each channel.
fn addPixels(a: u32, b: u32) u32 {
    const ag = (a & 0xff00ff00) +% (b & 0xff00ff00);
    const rb = (a & 0x00ff00ff) +% (b & 0x00ff00ff);
    return (ag & 0xff00ff00) | (rb & 0x00ff00ff);
}

/// `(a + b) / 2` for each of the four channels at once.
fn average2(a: u32, b: u32) u32 {
    return (((a ^ b) & 0xfefefefe) >> 1) +% (a & b);
}

fn channel(px: u32, comptime shift: u5) i32 {
    return @intCast((px >> shift) & 0xff);
}

fn clamp(v: i32) u32 {
    return @intCast(@min(@max(v, 0), 255));
}

/// Whichever of left and top is closer to `left + top - top_left`.
fn select(left: u32, top: u32, top_left: u32) u32 {
    var to_left: i32 = 0;
    var to_top: i32 = 0;
    inline for ([4]u5{ 24, 16, 8, 0 }) |shift| {
        const estimate = channel(left, shift) + channel(top, shift) - channel(top_left, shift);
        to_left += @intCast(@abs(estimate - channel(left, shift)));
        to_top += @intCast(@abs(estimate - channel(top, shift)));
    }
    return if (to_left < to_top) left else top;
}

fn clampAddSubtractFull(a: u32, b: u32, c: u32) u32 {
    var out: u32 = 0;
    inline for ([4]u5{ 24, 16, 8, 0 }) |shift| {
        out |= clamp(channel(a, shift) + channel(b, shift) - channel(c, shift)) << shift;
    }
    return out;
}

fn clampAddSubtractHalf(a: u32, b: u32) u32 {
    var out: u32 = 0;
    inline for ([4]u5{ 24, 16, 8, 0 }) |shift| {
        const av = channel(a, shift);
        out |= clamp(av + @divTrunc(av - channel(b, shift), 2)) << shift;
    }
    return out;
}

fn predict(mode: u4, left: u32, top: u32, top_left: u32, top_right: u32) u32 {
    return switch (mode) {
        1 => left,
        2 => top,
        3 => top_right,
        4 => top_left,
        5 => average2(average2(left, top_right), top),
        6 => average2(left, top_left),
        7 => average2(left, top),
        8 => average2(top_left, top),
        9 => average2(top, top_right),
        10 => average2(average2(left, top_left), average2(top, top_right)),
        11 => select(left, top, top_left),
        12 => clampAddSubtractFull(left, top, top_left),
        13 => clampAddSubtractHalf(average2(left, top), top_left),
        // Zero is solid black. Fourteen and fifteen are not modes at all ---
        // the mode is read out of a whole byte and only fourteen values are
        // defined --- and mean the same as zero, which is what every reader
        // does and what keeps a malformed file from needing its own branch.
        else => 0xff000000,
    };
}

/// Adds back what the encoder predicted and subtracted.
fn inversePredictor(t: Transform, argb: []u32) void {
    const w = t.width;
    const blocks = subSampleSize(w, t.bits);

    // The very first pixel has no neighbours at all.
    argb[0] = addPixels(argb[0], 0xff000000);
    // The top row can only look left, and the left column only up, whatever
    // the block says.
    for (1..w) |x| argb[x] = addPixels(argb[x], argb[x - 1]);

    var y: u32 = 1;
    while (y < t.height) : (y += 1) {
        const row = @as(usize, y) * w;
        argb[row] = addPixels(argb[row], argb[row - w]);

        var x: u32 = 1;
        while (x < w) : (x += 1) {
            const pos = row + x;
            const mode: u4 = @truncate((t.data[(y >> t.bits) * blocks + (x >> t.bits)] >> 8) & 0xf);
            // The top-right of the last pixel in a row is, by this
            // arithmetic, the first pixel of the current row --- which is
            // exactly the exception the specification states for the
            // rightmost column, arrived at without a branch because the rows
            // are contiguous.
            argb[pos] = addPixels(argb[pos], predict(
                mode,
                argb[pos - 1],
                argb[pos - w],
                argb[pos - w - 1],
                argb[pos - w + 1],
            ));
        }
    }
}

/// Adds back the cross-channel correlation the encoder removed.
fn inverseColour(t: Transform, argb: []u32) void {
    const w = t.width;
    const blocks = subSampleSize(w, t.bits);

    var y: u32 = 0;
    while (y < t.height) : (y += 1) {
        var x: u32 = 0;
        while (x < w) : (x += 1) {
            const element = t.data[(y >> t.bits) * blocks + (x >> t.bits)];
            const green_to_red: u8 = @truncate(element);
            const green_to_blue: u8 = @truncate(element >> 8);
            const red_to_blue: u8 = @truncate(element >> 16);

            const pos = @as(usize, y) * w + x;
            const px = argb[pos];
            const g: i8 = @bitCast(@as(u8, @truncate(px >> 8)));

            var r: i32 = @intCast((px >> 16) & 0xff);
            r = (r + delta(green_to_red, g)) & 0xff;
            var b: i32 = @intCast(px & 0xff);
            b += delta(green_to_blue, g);
            b += delta(red_to_blue, @bitCast(@as(u8, @intCast(r))));
            b &= 0xff;

            argb[pos] = (px & 0xff00ff00) | (@as(u32, @intCast(r)) << 16) | @as(u32, @intCast(b));
        }
    }
}

/// A 3.5-fixed-point multiply of a signed coefficient by a signed channel.
fn delta(coefficient: u8, value: i8) i32 {
    const c: i32 = @as(i8, @bitCast(coefficient));
    return (c * @as(i32, value)) >> 5;
}

/// Adds green back into red and blue.
fn inverseSubtractGreen(argb: []u32) void {
    for (argb) |*px| {
        const g = (px.* >> 8) & 0xff;
        const r = (((px.* >> 16) & 0xff) +% g) & 0xff;
        const b = ((px.* & 0xff) +% g) & 0xff;
        px.* = (px.* & 0xff00ff00) | (r << 16) | b;
    }
}

/// Replaces indices with the colours they name, unbundling as it goes.
///
/// The only inverse that changes the width, so it reads from the narrow
/// buffer and writes to the wide one.
fn inversePalette(t: Transform, src: []const u32, dst: []u32) void {
    const w = t.width;
    const narrow = subSampleSize(w, t.bits);
    // Eight bits an index, or four, two or one when pixels were bundled.
    const index_bits: u5 = @intCast(@as(u8, 8) >> @intCast(t.bits));
    const mask: u32 = (@as(u32, 1) << index_bits) - 1;
    const per: u32 = @as(u32, 1) << t.bits;

    var y: u32 = 0;
    while (y < t.height) : (y += 1) {
        var x: u32 = 0;
        while (x < w) : (x += 1) {
            const packed_px = src[@as(usize, y) * narrow + (x >> t.bits)];
            const shift: u5 = @intCast((x & (per - 1)) * index_bits);
            const index = ((packed_px >> 8) >> shift) & mask;
            // An index past the end of the table is transparent black rather
            // than an error, which is what the specification asks for.
            dst[@as(usize, y) * w + x] = if (index < t.data.len) t.data[index] else 0;
        }
    }
}

// -- writing -----------------------------------------------------------------

/// How hard to try.
pub const EncodeOptions = struct {
    /// Subtract the green channel from red and blue before coding.
    ///
    /// Three lines of arithmetic and one bit to declare, and on a photograph
    /// it is most of what the cross-channel transforms would buy: the three
    /// channels of a natural image are highly correlated, and removing green
    /// from the other two leaves far less to code. It costs a little on an
    /// image whose channels are unrelated, so it is chosen by measuring rather
    /// than assumed --- both forms are coded and the smaller kept, which for
    /// one extra pass over the histogram is the honest way to answer a
    /// question that depends on the picture.
    subtract_green: bool = true,
};

/// Writes a VP8L bitstream for `argb` into `out`.
///
/// Not an `Io.Writer`: a bitstream goes inside a RIFF chunk and a chunk
/// carries its length in front of it, so the bytes have to exist before the
/// thing that says how many there are.
pub fn encode(
    gpa: Allocator,
    out: *std.ArrayList(u8),
    width: u32,
    height: u32,
    argb: []const u32,
    opts: EncodeOptions,
) Allocator.Error!void {
    std.debug.assert(argb.len == @as(usize, width) * height);
    std.debug.assert(width >= 1 and width <= max_side);
    std.debug.assert(height >= 1 and height <= max_side);

    var alpha_used = false;
    for (argb) |px| {
        if (px >> 24 != 0xff) {
            alpha_used = true;
            break;
        }
    }

    const subtract_green = opts.subtract_green and try greenHelps(gpa, argb);

    // One writer for the whole bitstream, header and pixels together. Two
    // would be easier to arrange and wrong: `flush` pads to a byte, and the
    // header is forty bits plus however many the transforms take, so padding
    // between them would put every bit after it out of place.
    var w: prefix.BitWriter = .init(gpa, out);
    try w.put(signature, 8);
    try w.put(width - 1, 14);
    try w.put(height - 1, 14);
    try w.put(@intFromBool(alpha_used), 1);
    // The only version there is.
    try w.put(0, 3);
    if (subtract_green) {
        try w.put(1, 1); // a transform follows
        try w.put(@backingInt(Transform.Kind.subtract_green), 2);
    }
    try w.put(0, 1); // and no more transforms

    try codeImage(gpa, &w, width, argb, subtract_green);
    try w.flush();
}

/// Whether subtracting green from red and blue makes them cheaper to code.
///
/// Measured rather than assumed. It is most of what the cross-channel
/// transforms would buy on a photograph, whose three channels are highly
/// correlated, and it costs a little on an image whose channels are
/// unrelated --- so the two forms of the red and blue histograms are both
/// built and the one that codes to fewer bits wins. Green and alpha are not
/// touched by the transform and so cannot decide anything.
fn greenHelps(gpa: Allocator, argb: []const u32) Allocator.Error!bool {
    var plain_red: [256]u32 = @splat(0);
    var plain_blue: [256]u32 = @splat(0);
    var less_red: [256]u32 = @splat(0);
    var less_blue: [256]u32 = @splat(0);

    for (argb) |px| {
        const g: u8 = @truncate(px >> 8);
        const r: u8 = @truncate(px >> 16);
        const b: u8 = @truncate(px);
        plain_red[r] += 1;
        plain_blue[b] += 1;
        less_red[r -% g] += 1;
        less_blue[b -% g] += 1;
    }

    const plain = try codedBits(gpa, &plain_red) + try codedBits(gpa, &plain_blue);
    const less = try codedBits(gpa, &less_red) + try codedBits(gpa, &less_blue);
    return less < plain;
}

/// What a histogram costs to code, in bits, not counting its table.
///
/// The tables are the same size either way to within a few bytes, which is
/// far below what the transform moves on any image where the answer is not
/// obvious.
fn codedBits(gpa: Allocator, freqs: *const [256]u32) Allocator.Error!u64 {
    var lengths: [256]u8 = undefined;
    prefix.buildLengths(gpa, freqs, &lengths, prefix.max_code_length) catch |err| switch (err) {
        // One symbol or none costs nothing to write and nothing to read.
        error.TooFewSymbols => return 0,
        error.OutOfMemory => |e| return e,
    };
    var total: u64 = 0;
    for (freqs, lengths) |f, l| total += @as(u64, f) * l;
    return total;
}

/// What the encoder decided a pixel, or a run of them, should be.
///
/// Worked out in one pass and written in another, because the codes cannot be
/// built until every symbol is known and the symbols cannot be chosen twice:
/// the colour cache's contents depend on what was emitted before, so a second
/// pass that decided differently would desynchronise from the first.
const Op = struct {
    kind: enum(u2) { literal, cached, copy },
    /// The pixel, the cache index, or the length.
    a: u32,
    /// The distance, for a copy.
    b: u32 = 0,
};

/// How large a colour cache to ask for.
///
/// Bigger is better until it is not: every entry costs a symbol in the green
/// alphabet whether or not anything uses it, and a table with two thousand
/// mostly-empty entries in it costs more to write down than the hits are
/// worth on a small picture.
fn pickCacheBits(pixels_count: usize) u4 {
    if (pixels_count < 64) return 0;
    if (pixels_count < 1024) return 6;
    if (pixels_count < 16384) return 8;
    return 10;
}

/// The shortest backward reference worth making.
///
/// Two pixels cost a length code, a distance code and their extra bits, which
/// is rarely less than coding them outright; three is where it starts paying.
const min_match = 3;
/// How many candidates to look at before settling for the best so far.
const max_chain = 32;
const hash_bits = 15;

/// Codes the pixels: five prefix codes and then the symbols themselves.
fn codeImage(
    gpa: Allocator,
    w: *prefix.BitWriter,
    width: u32,
    argb: []const u32,
    subtract_green: bool,
) Allocator.Error!void {
    // The transform is applied before anything else looks at the pixels: what
    // is matched, cached and coded is what the decoder will read, which is
    // the transformed image and not the original.
    var owned: ?[]u32 = null;
    defer if (owned) |b| gpa.free(b);
    const src: []const u32 = if (subtract_green) blk: {
        const t = try gpa.alloc(u32, argb.len);
        owned = t;
        for (argb, t) |px, *out| {
            const g = (px >> 8) & 0xff;
            const r = (((px >> 16) & 0xff) -% g) & 0xff;
            const b = ((px & 0xff) -% g) & 0xff;
            out.* = (px & 0xff00ff00) | (r << 16) | b;
        }
        break :blk t;
    } else argb;

    const cache_bits = pickCacheBits(src.len);

    const freqs = try gpa.alloc(u32, literal_codes + length_codes + (@as(usize, 1) << cache_bits) +
        3 * 256 + distance_codes);
    defer gpa.free(freqs);
    @memset(freqs, 0);
    const green_len = literal_codes + length_codes + (@as(usize, 1) << cache_bits);
    const green_freq = freqs[0..green_len];
    const red_freq = freqs[green_len..][0..256];
    const blue_freq = freqs[green_len + 256 ..][0..256];
    const alpha_freq = freqs[green_len + 512 ..][0..256];
    const distance_freq = freqs[green_len + 768 ..][0..distance_codes];

    var ops: std.ArrayList(Op) = .empty;
    defer ops.deinit(gpa);
    try choose(gpa, src, width, cache_bits, &ops, .{
        .green = green_freq,
        .red = red_freq,
        .blue = blue_freq,
        .alpha = alpha_freq,
        .distance = distance_freq,
    });

    // A code has to be written for every one of the five even when nothing
    // uses it: the decoder reads all five before it reads a pixel, so an
    // alphabet with no symbols in it still needs something readable in front
    // of the ones that have.
    var codes: [5]Table = undefined;
    const histograms = [5][]const u32{ green_freq, red_freq, blue_freq, alpha_freq, distance_freq };
    for (&codes, histograms) |*table, freq| table.* = try Table.build(gpa, freq);
    defer for (&codes) |*table| table.deinit(gpa);

    if (cache_bits == 0) {
        try w.put(0, 1);
    } else {
        try w.put(1, 1);
        try w.put(cache_bits, 4);
    }
    // One group of codes for the whole image.
    try w.put(0, 1);
    for (&codes) |*table| try table.write(gpa, w);

    for (ops.items) |op| switch (op.kind) {
        .literal => {
            const px = op.a;
            // One channel at a time, and to a byte first: `put` takes a
            // symbol, and truncating an ARGB word straight to sixteen bits
            // hands it two channels stuck together.
            try codes[green].put(w, @as(u8, @truncate(px >> 8)));
            try codes[red].put(w, @as(u8, @truncate(px >> 16)));
            try codes[blue].put(w, @as(u8, @truncate(px)));
            try codes[alpha].put(w, @as(u8, @truncate(px >> 24)));
        },
        .cached => try codes[green].put(w, @intCast(literal_codes + length_codes + op.a)),
        .copy => {
            const len = extended(op.a);
            try codes[green].put(w, literal_codes + len.symbol);
            try w.put(len.extra, len.bits);
            const dist = extended(op.b);
            try codes[distance].put(w, dist.symbol);
            try w.put(dist.extra, dist.bits);
        },
    };
}

const Histograms = struct {
    green: []u32,
    red: []u32,
    blue: []u32,
    alpha: []u32,
    distance: []u32,
};

/// Decides what every pixel is going to be, and counts the symbols that
/// decision implies.
fn choose(
    gpa: Allocator,
    src: []const u32,
    width: u32,
    cache_bits: u4,
    ops: *std.ArrayList(Op),
    freqs: Histograms,
) Allocator.Error!void {
    var cache: ?ColourCache = null;
    if (cache_bits > 0) {
        const entries = try gpa.alloc(u32, @as(usize, 1) << cache_bits);
        @memset(entries, 0);
        cache = .{ .entries = entries, .bits = cache_bits };
    }
    defer if (cache) |c| gpa.free(c.entries);

    // A chained hash table over three-pixel sequences. `head` is the most
    // recent position with a given hash and `prev` chains backwards from
    // there, so following it visits the nearest matches first --- which is
    // also the cheapest to code, since the first hundred and twenty distance
    // codes name a neighbourhood rather than a number.
    const head = try gpa.alloc(i32, @as(usize, 1) << hash_bits);
    defer gpa.free(head);
    @memset(head, -1);
    const prev = try gpa.alloc(i32, src.len);
    defer gpa.free(prev);

    const plane = try planeCodes(gpa, width);
    defer gpa.free(plane);

    var at: usize = 0;
    while (at < src.len) {
        var best_len: usize = 0;
        var best_dist: usize = 0;
        if (at + min_match <= src.len) {
            const h = hash3(src, at);
            var candidate = head[h];
            var tries: usize = 0;
            while (candidate >= 0 and tries < max_chain) : (tries += 1) {
                const pos: usize = @intCast(candidate);
                candidate = prev[pos];
                var len: usize = 0;
                const limit = @min(src.len - at, max_copy_length);
                while (len < limit and src[pos + len] == src[at + len]) len += 1;
                if (len > best_len) {
                    best_len = len;
                    best_dist = at - pos;
                    if (len == limit) break;
                }
            }
        }

        if (best_len >= min_match) {
            const code = distanceCode(plane, best_dist);
            freqs.green[literal_codes + extended(@intCast(best_len)).symbol] += 1;
            freqs.distance[extended(code).symbol] += 1;
            try ops.append(gpa, .{
                .kind = .copy,
                .a = @intCast(best_len),
                .b = code,
            });
            for (0..best_len) |k| {
                insert(head, prev, src, at + k);
                if (cache) |c| c.insert(src[at + k]);
            }
            at += best_len;
            continue;
        }

        const px = src[at];
        if (cache) |c| {
            const slot = c.slot(px);
            if (c.entries[slot] == px) {
                freqs.green[literal_codes + length_codes + slot] += 1;
                try ops.append(gpa, .{ .kind = .cached, .a = @intCast(slot) });
                insert(head, prev, src, at);
                c.insert(px);
                at += 1;
                continue;
            }
        }

        freqs.green[@as(u8, @truncate(px >> 8))] += 1;
        freqs.red[@as(u8, @truncate(px >> 16))] += 1;
        freqs.blue[@as(u8, @truncate(px))] += 1;
        freqs.alpha[@as(u8, @truncate(px >> 24))] += 1;
        try ops.append(gpa, .{ .kind = .literal, .a = px });
        insert(head, prev, src, at);
        if (cache) |c| c.insert(px);
        at += 1;
    }
}

/// The longest run a single backward reference may name.
const max_copy_length = 4096;

fn hash3(src: []const u32, at: usize) usize {
    var h: u32 = src[at] *% 0x9e37_79b1;
    h ^= src[at + 1] *% 0x85eb_ca6b;
    h ^= src[at + 2] *% 0xc2b2_ae35;
    return h >> (32 - hash_bits);
}

fn insert(head: []i32, prev: []i32, src: []const u32, at: usize) void {
    if (at + min_match > src.len) return;
    const h = hash3(src, at);
    prev[at] = head[h];
    head[h] = @intCast(at);
}

/// The distance each of the hundred and twenty neighbourhood codes means, at
/// this width, so that a distance can be turned back into the cheapest code
/// that names it.
fn planeCodes(gpa: Allocator, width: u32) Allocator.Error![]u32 {
    const out = try gpa.alloc(u32, plane_codes);
    for (out, 1..) |*d, code| d.* = planeDistance(width, @intCast(code));
    return out;
}

/// The code for a distance: a neighbourhood code where one names it, and the
/// distance itself plus a hundred and twenty otherwise.
fn distanceCode(plane: []const u32, dist: usize) u32 {
    for (plane, 1..) |d, code| {
        if (d == dist) return @intCast(code);
    }
    return @intCast(dist + plane_codes);
}

/// A length or a distance, as the symbol and extra bits that carry it.
///
/// The inverse of `readExtended`, and it has to be exactly that: the ranges
/// the two agree on are what keep a file readable.
fn extended(value: u32) struct { symbol: u16, extra: u32, bits: u6 } {
    std.debug.assert(value >= 1);
    if (value <= 4) return .{ .symbol = @intCast(value - 1), .extra = 0, .bits = 0 };

    const n = value - 1;
    const bits: u6 = @intCast(31 - @clz(n) - 1);
    // Two symbols share each width: the lower half of the range and the
    // upper. Which one `n` falls in is the symbol's bottom bit.
    const upper = n >= (@as(u32, 3) << @intCast(bits));
    const symbol: u16 = @intCast(2 * @as(u16, bits) + 2 + @intFromBool(upper));
    const offset = (@as(u32, 2) + @intFromBool(upper)) << @intCast(bits);
    return .{ .symbol = symbol, .extra = n - offset, .bits = bits };
}

/// One prefix code being written: the lengths, and the codes they describe.
const Table = struct {
    lengths: []u8,
    codes: []u16,
    /// The symbols actually used, when there are one or two of them, which is
    /// what decides between the two ways a code can be written down.
    used: [2]u16 = .{ 0, 0 },
    count: u8 = 0,

    fn build(gpa: Allocator, freqs: []const u32) Allocator.Error!Table {
        const lengths = try gpa.alloc(u8, freqs.len);
        errdefer gpa.free(lengths);
        const codes = try gpa.alloc(u16, freqs.len);
        errdefer gpa.free(codes);

        var self: Table = .{ .lengths = lengths, .codes = codes };
        for (freqs, 0..) |f, symbol| {
            if (f == 0) continue;
            if (self.count < 2) self.used[self.count] = @intCast(symbol);
            self.count +|= 1;
        }

        if (self.count < 2) {
            // Nothing to build: one symbol reads no bits, and no symbols at
            // all still has to be written as something, so it is written as
            // the one symbol nothing will ask for.
            @memset(lengths, 0);
            @memset(codes, 0);
            return self;
        }
        prefix.buildLengths(gpa, freqs, lengths, prefix.max_code_length) catch |err| switch (err) {
            error.TooFewSymbols => unreachable, // `count` says otherwise
            error.OutOfMemory => |e| return e,
        };
        prefix.assignCodes(lengths, codes);
        return self;
    }

    fn deinit(self: *Table, gpa: Allocator) void {
        gpa.free(self.lengths);
        gpa.free(self.codes);
        self.* = undefined;
    }

    fn put(self: *const Table, w: *prefix.BitWriter, symbol: u16) Allocator.Error!void {
        // A code of one symbol spends no bits, which is what makes a constant
        // channel --- an opaque alpha, most often --- cost nothing at all.
        if (self.count < 2) return;
        try w.putCode(self.codes[symbol], self.lengths[symbol]);
    }

    /// Writes the code itself, in whichever of the two forms fits.
    fn write(self: *const Table, gpa: Allocator, w: *prefix.BitWriter) Allocator.Error!void {
        // The simple form names one or two symbols outright and carries no
        // lengths --- but it writes a symbol in eight bits, so it can only
        // name one below 256.
        if (self.count <= 2 and self.used[0] < 256 and self.used[1] < 256) {
            const n: u8 = if (self.count == 0) 1 else self.count;
            try w.put(1, 1);
            try w.put(n - 1, 1);
            if (self.used[0] < 2) {
                try w.put(0, 1);
                try w.put(self.used[0], 1);
            } else {
                try w.put(1, 1);
                try w.put(self.used[0], 8);
            }
            if (n == 2) try w.put(self.used[1], 8);
            return;
        }
        try self.writeLengths(gpa, w);
    }

    /// The normal form: the lengths, run-length coded, with a prefix code of
    /// their own in front of them.
    fn writeLengths(self: *const Table, gpa: Allocator, w: *prefix.BitWriter) Allocator.Error!void {
        var coded: std.ArrayList(Coded) = .empty;
        defer coded.deinit(gpa);
        try runLengthCode(gpa, self.lengths, &coded);

        var meta_freq: [19]u32 = @splat(0);
        for (coded.items) |c| meta_freq[c.symbol] += 1;

        var meta_lengths: [19]u8 = @splat(0);
        var meta_used: usize = 0;
        var only: usize = 0;
        for (meta_freq, 0..) |f, i| {
            if (f != 0) {
                meta_used += 1;
                only = i;
            }
        }
        if (meta_used < 2) {
            // Every length the same: the code that describes them has one
            // symbol and reads no bits, exactly as one over pixels would.
            meta_lengths[only] = 1;
        } else {
            // Seven, not fifteen: these lengths are written in three bits
            // each, so the code describing them cannot be deeper than its own
            // field can say.
            prefix.buildLengths(gpa, &meta_freq, &meta_lengths, 7) catch |err| switch (err) {
                error.TooFewSymbols => unreachable,
                error.OutOfMemory => |e| return e,
            };
        }
        var meta_codes: [19]u16 = undefined;
        prefix.assignCodes(&meta_lengths, &meta_codes);

        // Only as many of the nineteen as reach the last non-zero one, in the
        // order the format gives them --- which is why that order puts the
        // run codes and the short lengths first.
        var given: usize = prefix.code_length_order.len;
        while (given > 4 and meta_lengths[prefix.code_length_order[given - 1]] == 0) given -= 1;

        try w.put(0, 1); // the normal form
        try w.put(@intCast(given - 4), 4);
        for (0..given) |i| try w.put(meta_lengths[prefix.code_length_order[i]], 3);
        try w.put(0, 1); // no explicit symbol count: all of them follow

        for (coded.items) |c| {
            try w.putCode(meta_codes[c.symbol], meta_lengths[c.symbol]);
            try w.put(c.extra, c.extra_bits);
        }
    }
};

/// One entry of the run-length-coded length stream.
const Coded = struct {
    symbol: u8,
    extra: u32 = 0,
    extra_bits: u6 = 0,
};

/// Turns per-symbol code lengths into the stream the format writes them as.
///
/// Long runs are where the saving is, and a real alphabet is mostly runs: 256
/// literal symbols of which a few dozen occur leaves hundreds of zeros, and a
/// flat channel leaves hundreds of identical non-zero lengths.
fn runLengthCode(gpa: Allocator, lengths: []const u8, out: *std.ArrayList(Coded)) Allocator.Error!void {
    var at: usize = 0;
    var previous: u8 = 0xff;
    while (at < lengths.len) {
        const value = lengths[at];
        var run: usize = 1;
        while (at + run < lengths.len and lengths[at + run] == value) run += 1;

        if (value == 0) {
            // Zeros: three to ten in one symbol, eleven to a hundred and
            // thirty-eight in another.
            while (run >= 3) {
                const take = @min(run, 138);
                if (take < 11) {
                    try out.append(gpa, .{ .symbol = 17, .extra = @intCast(take - 3), .extra_bits = 3 });
                } else {
                    try out.append(gpa, .{ .symbol = 18, .extra = @intCast(take - 11), .extra_bits = 7 });
                }
                at += take;
                run -= take;
            }
            for (0..run) |_| try out.append(gpa, .{ .symbol = 0 });
            at += run;
            continue;
        }

        // A non-zero value: one of it, and then repeats of whatever came
        // last, three to six at a time.
        try out.append(gpa, .{ .symbol = value });
        at += 1;
        run -= 1;
        previous = value;
        if (previous == value) {
            while (run >= 3) {
                const take = @min(run, 6);
                try out.append(gpa, .{ .symbol = 16, .extra = @intCast(take - 3), .extra_bits = 2 });
                at += take;
                run -= take;
            }
        }
        for (0..run) |_| try out.append(gpa, .{ .symbol = value });
        at += run;
    }
}
