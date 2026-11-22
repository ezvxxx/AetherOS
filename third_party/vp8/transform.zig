// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Dequantisation and the two inverse transforms.
//!
//! What the token decoder produces is quantised levels. Turning them back
//! into a residue takes two steps: multiply each by a factor that depends on
//! the plane and on whether it is the DC coefficient, and then run the block
//! through the inverse transform.
//!
//! ## Two transforms, not one
//!
//! Most blocks go through an inverse **DCT**. But when a macroblock's luma is
//! predicted whole — anything but `B_PRED` — the sixteen luma blocks' DC
//! coefficients are collected into a seventeenth block of their own, the
//! **Y2** block, and that one goes through an inverse **Walsh-Hadamard**
//! transform instead. A flat macroblock then costs one block rather than
//! sixteen, which is the entire reason for the arrangement.
//!
//! The Y2 block is inverted first, and the value at row `i`, column `j` of
//! its result becomes coefficient zero of the luma block at that position.
//!
//! ## The factors are not simply the table
//!
//! Y1 reads the tables directly. Y2 and chroma do not:
//!
//! - **Y2's DC factor is doubled**, and its AC factor multiplied by 1.55,
//!   with a floor of 8 — the Y2 block holds what sixteen DC coefficients had
//!   in common, so its values are larger and are quantised more coarsely.
//! - **Chroma's DC factor is capped at 132**, because chroma is subsampled
//!   and a coarse DC there is visible as a colour shift across a whole
//!   region in a way the same coarseness in luma is not.
//!
//! Every index is clamped to 0–127 before it is looked up, which matters
//! because the frame header's deltas are signed and a segment may adjust
//! them further.

const std = @import("std");
const math = std.math;
const testing = std.testing;

const header = @import("header.zig");

/// The dequantisation factor for a DC coefficient, by index.
///
/// A hundred and twenty-eight steps from 4 to 157, bunched at the fine end:
/// the difference between index 0 and index 1 matters far more to a picture
/// than the difference between 120 and 121.
pub const dc_qlookup = [128]u16{
    4,   5,   6,   7,   8,   9,   10,  10,  11,  12,  13,  14,  15,
    16,  17,  17,  18,  19,  20,  20,  21,  21,  22,  22,  23,  23,
    24,  25,  25,  26,  27,  28,  29,  30,  31,  32,  33,  34,  35,
    36,  37,  37,  38,  39,  40,  41,  42,  43,  44,  45,  46,  46,
    47,  48,  49,  50,  51,  52,  53,  54,  55,  56,  57,  58,  59,
    60,  61,  62,  63,  64,  65,  66,  67,  68,  69,  70,  71,  72,
    73,  74,  75,  76,  76,  77,  78,  79,  80,  81,  82,  83,  84,
    85,  86,  87,  88,  89,  91,  93,  95,  96,  98,  100, 101, 102,
    104, 106, 108, 110, 112, 114, 116, 118, 122, 124, 126, 128, 130,
    132, 134, 136, 138, 140, 143, 145, 148, 151, 154, 157,
};

/// The dequantisation factor for an AC coefficient, by index.
///
/// The same hundred and twenty-eight steps, running further --- to 284 --- because
/// the eye forgives more error in detail than in overall level.
pub const ac_qlookup = [128]u16{
    4,   5,   6,   7,   8,   9,   10,  11,  12,  13,  14,  15,  16,
    17,  18,  19,  20,  21,  22,  23,  24,  25,  26,  27,  28,  29,
    30,  31,  32,  33,  34,  35,  36,  37,  38,  39,  40,  41,  42,
    43,  44,  45,  46,  47,  48,  49,  50,  51,  52,  53,  54,  55,
    56,  57,  58,  60,  62,  64,  66,  68,  70,  72,  74,  76,  78,
    80,  82,  84,  86,  88,  90,  92,  94,  96,  98,  100, 102, 104,
    106, 108, 110, 112, 114, 116, 119, 122, 125, 128, 131, 134, 137,
    140, 143, 146, 149, 152, 155, 158, 161, 164, 167, 170, 173, 177,
    181, 185, 189, 193, 197, 201, 205, 209, 213, 217, 221, 225, 229,
    234, 239, 245, 249, 254, 259, 264, 269, 274, 279, 284,
};

/// One index, clamped into the tables.
fn clampIndex(q: i32) usize {
    return @intCast(math.clamp(q, 0, 127));
}

pub fn dcFactor(q: i32) u16 {
    return dc_qlookup[clampIndex(q)];
}

pub fn acFactor(q: i32) u16 {
    return ac_qlookup[clampIndex(q)];
}

/// The six factors a macroblock dequantises with.
pub const Factors = struct {
    y_dc: u16,
    y_ac: u16,
    y2_dc: u16,
    y2_ac: u16,
    uv_dc: u16,
    uv_ac: u16,

    /// Works them out for one segment, from the frame's quantiser header.
    ///
    /// `segment` is the index into the segmentation adjustments, or null
    /// when the frame does not segment.
    pub fn init(h: *const header.Header, segment: ?usize) Factors {
        var q: i32 = h.quant.y_ac;
        if (h.segmentation.enabled) {
            if (segment) |i| {
                const adjust: i32 = h.segmentation.quantizer[i];
                q = if (h.segmentation.absolute) adjust else q + adjust;
            }
        }

        var f: Factors = .{
            .y_dc = dcFactor(q + h.quant.y_dc_delta),
            .y_ac = acFactor(q),
            // Doubled, and one and a half times over, because a Y2 block
            // holds what sixteen luma DCs had in common and so runs larger.
            .y2_dc = dcFactor(q + h.quant.y2_dc_delta) * 2,
            .y2_ac = @intCast(@as(u32, acFactor(q + h.quant.y2_ac_delta)) * 155 / 100),
            .uv_dc = dcFactor(q + h.quant.uv_dc_delta),
            .uv_ac = acFactor(q + h.quant.uv_ac_delta),
        };
        if (f.y2_ac < 8) f.y2_ac = 8;
        // Chroma is subsampled, so a coarse DC there shifts the colour of a
        // whole region rather than one pixel of it.
        if (f.uv_dc > 132) f.uv_dc = 132;
        return f;
    }
};

/// Multiplies a block's levels by its factors, in place.
///
/// Coefficient zero takes the DC factor and the rest the AC one. The
/// specification says the products are computed and stored in sixteen signed
/// bits, so this wraps where they would.
pub fn dequantise(block: *[16]i16, dc: u16, ac: u16) void {
    block[0] = @bitCast(@as(u16, @bitCast(block[0])) *% dc);
    for (block[1..]) |*v| v.* = @bitCast(@as(u16, @bitCast(v.*)) *% ac);
}

/// The two constants the inverse DCT's rotations are built from.
///
/// `35468 / 65536` is `sqrt(2) * sin(pi/8)` and `1 + 20091 / 65536` is
/// `sqrt(2) * cos(pi/8)`, which is what makes the butterflies below a
/// four-point inverse DCT rather than an arbitrary pair of sums.
const sin_pi8_sqrt2: i32 = 35468;
const cos_pi8_sqrt2_minus1: i32 = 20091;

/// The inverse DCT: two passes of the same four-point butterfly, down the
/// columns and then along the rows.
///
/// Its output is the orthonormal two-dimensional inverse DCT scaled by a
/// quarter, to within about one and a quarter counts — which is the claim
/// the tests make, and the one that catches a mistyped constant or a
/// transposed pass.
///
/// **Every arithmetic operation here wraps on purpose.** A dequantised
/// coefficient is stored in sixteen signed bits, which the format says
/// explicitly, and the second pass multiplies something four times that by
/// thirty-five thousand — so a coefficient near the top of its range
/// overflows a thirty-two bit intermediate. The reference decoder is C and
/// wraps there too, quietly and undefinedly; this wraps the same way and
/// says so, because a decoder handed a hostile file must have *some*
/// defined answer and the useful one is the answer everybody else gives.
pub fn inverseDct(input: *const [16]i16, out: *[16]i16) void {
    var mid: [16]i32 = undefined;

    for (0..4) |i| {
        const x0: i32 = input[i];
        const x1: i32 = input[4 + i];
        const x2: i32 = input[8 + i];
        const x3: i32 = input[12 + i];

        const a = x0 +% x2;
        const b = x0 -% x2;
        const c = ((x1 *% sin_pi8_sqrt2) >> 16) -% (x3 +% ((x3 *% cos_pi8_sqrt2_minus1) >> 16));
        const d = (x1 +% ((x1 *% cos_pi8_sqrt2_minus1) >> 16)) +% ((x3 *% sin_pi8_sqrt2) >> 16);

        mid[i] = a +% d;
        mid[12 + i] = a -% d;
        mid[4 + i] = b +% c;
        mid[8 + i] = b -% c;
    }

    for (0..4) |r| {
        const row = mid[4 * r ..][0..4];
        const a = row[0] +% row[2];
        const b = row[0] -% row[2];
        const c = ((row[1] *% sin_pi8_sqrt2) >> 16) -% (row[3] +% ((row[3] *% cos_pi8_sqrt2_minus1) >> 16));
        const d = (row[1] +% ((row[1] *% cos_pi8_sqrt2_minus1) >> 16)) +% ((row[3] *% sin_pi8_sqrt2) >> 16);

        out[4 * r + 0] = @truncate((a +% d +% 4) >> 3);
        out[4 * r + 3] = @truncate((a -% d +% 4) >> 3);
        out[4 * r + 1] = @truncate((b +% c +% 4) >> 3);
        out[4 * r + 2] = @truncate((b -% c +% 4) >> 3);
    }
}

/// The inverse Walsh-Hadamard transform, for the Y2 block.
///
/// Sums and differences and nothing else, which is why it is exact where the
/// DCT is an approximation: it is the two-dimensional Hadamard transform
/// divided by eight, to within the half a count its rounding costs.
pub fn inverseWht(input: *const [16]i16, out: *[16]i16) void {
    var mid: [16]i32 = undefined;

    for (0..4) |i| {
        const a = @as(i32, input[i]) +% input[12 + i];
        const b = @as(i32, input[4 + i]) +% input[8 + i];
        const c = @as(i32, input[4 + i]) -% input[8 + i];
        const d = @as(i32, input[i]) -% input[12 + i];

        mid[i] = a +% b;
        mid[4 + i] = c +% d;
        mid[8 + i] = a -% b;
        mid[12 + i] = d -% c;
    }

    for (0..4) |r| {
        const row = mid[4 * r ..][0..4];
        const a = row[0] +% row[3];
        const b = row[1] +% row[2];
        const c = row[1] -% row[2];
        const d = row[0] -% row[3];

        out[4 * r + 0] = @truncate((a +% b +% 3) >> 3);
        out[4 * r + 1] = @truncate((c +% d +% 3) >> 3);
        out[4 * r + 2] = @truncate((a -% b +% 3) >> 3);
        out[4 * r + 3] = @truncate((d -% c +% 3) >> 3);
    }
}

// -- tests -------------------------------------------------------------------

/// The orthonormal two-dimensional inverse DCT, in floating point, scaled by
/// the quarter that VP8's integer version carries.
///
/// The anchor for the test below: it is the transform the integer code is
/// approximating, written from its mathematical definition rather than from
/// the same butterflies, so agreeing with it is evidence about the
/// transcription and not about itself.
fn floatIdct(x: *const [16]i16, out: *[16]f64) void {
    for (0..4) |i| {
        for (0..4) |j| {
            var sum: f64 = 0;
            for (0..4) |v| {
                for (0..4) |u| {
                    const au: f64 = if (u == 0) math.sqrt(0.5) else 1.0;
                    const av: f64 = if (v == 0) math.sqrt(0.5) else 1.0;
                    const fi: f64 = @floatFromInt(i);
                    const fj: f64 = @floatFromInt(j);
                    const fu: f64 = @floatFromInt(u);
                    const fv: f64 = @floatFromInt(v);
                    sum += au * av * @as(f64, @floatFromInt(x[4 * v + u])) *
                        @cos((2 * fj + 1) * fu * math.pi / 8) *
                        @cos((2 * fi + 1) * fv * math.pi / 8);
                }
            }
            out[4 * i + j] = 0.25 * sum;
        }
    }
}

/// The two-dimensional Hadamard transform over eight, likewise.
fn floatWht(x: *const [16]i16, out: *[16]f64) void {
    const h = [4][4]f64{
        .{ 1, 1, 1, 1 },
        .{ 1, 1, -1, -1 },
        .{ 1, -1, -1, 1 },
        .{ 1, -1, 1, -1 },
    };
    var mid: [16]f64 = @splat(0);
    for (0..4) |i| {
        for (0..4) |j| {
            var sum: f64 = 0;
            for (0..4) |k| sum += h[i][k] * @as(f64, @floatFromInt(x[4 * k + j]));
            mid[4 * i + j] = sum;
        }
    }
    for (0..4) |i| {
        for (0..4) |j| {
            var sum: f64 = 0;
            for (0..4) |k| sum += h[j][k] * mid[4 * i + k];
            out[4 * i + j] = sum / 8;
        }
    }
}

/// A small deterministic generator, so the tests are the same every run.
fn noise(seed: *u64, limit: i16) i16 {
    seed.* = seed.* *% 6364136223846793005 +% 1442695040888963407;
    const v: i32 = @intCast((seed.* >> 33) % (2 * @as(u64, @intCast(limit)) + 1));
    return @intCast(v - limit);
}

test "the inverse DCT is the inverse DCT" {
    var seed: u64 = 7;
    // Up to four thousand, which is where a thirty-two bit intermediate
    // stops holding the second pass. Past that the transform still answers
    // --- see the test below --- but it wraps, and comparing a wrapped
    // answer against a real-number one would be comparing nothing.
    for ([_]i16{ 300, 2048, 4096 }) |limit| {
        for (0..200) |_| {
            var x: [16]i16 = undefined;
            for (&x) |*v| v.* = noise(&seed, limit);

            var got: [16]i16 = undefined;
            inverseDct(&x, &got);
            var want: [16]f64 = undefined;
            floatIdct(&x, &want);

            for (got, want) |g, w| {
                const delta = @abs(@as(f64, @floatFromInt(g)) - w);
                // One and a quarter is what the integer approximation
                // actually costs; two is the bound, so that the test is
                // about the transform being right and not about the last
                // bit of its rounding.
                try testing.expect(delta <= 2.0);
            }
        }
    }
}

test "a coefficient at the top of its range does not bring the decoder down" {
    // A dequantised coefficient is stored in sixteen signed bits and a
    // malformed file may put anything there. The answer past the point where
    // the intermediates wrap is not meaningful, but it has to exist: a
    // decoder that panicked here would be a decoder a crafted file could
    // stop.
    var seed: u64 = 99;
    var out: [16]i16 = undefined;
    for (0..500) |_| {
        var x: [16]i16 = undefined;
        for (&x) |*v| v.* = noise(&seed, math.maxInt(i16));
        inverseDct(&x, &out);
        inverseWht(&x, &out);
    }
    // And the extremes themselves.
    inverseDct(&@as([16]i16, @splat(math.maxInt(i16))), &out);
    inverseDct(&@as([16]i16, @splat(math.minInt(i16))), &out);
    inverseWht(&@as([16]i16, @splat(math.maxInt(i16))), &out);
    inverseWht(&@as([16]i16, @splat(math.minInt(i16))), &out);
}

test "the inverse Walsh-Hadamard transform is exact but for its rounding" {
    var seed: u64 = 11;
    for (0..300) |_| {
        var x: [16]i16 = undefined;
        for (&x) |*v| v.* = noise(&seed, 2048);

        var got: [16]i16 = undefined;
        inverseWht(&x, &got);
        var want: [16]f64 = undefined;
        floatWht(&x, &want);

        for (got, want) |g, w| {
            try testing.expect(@abs(@as(f64, @floatFromInt(g)) - w) <= 0.5);
        }
    }
}

test "a block of only DC comes out flat" {
    // The property a reader can check by eye, and the one that catches a
    // transform wired up transposed: the DC coefficient alone means "this
    // block is all one value".
    for ([_]i16{ 8, 100, -64, 1000 }) |dc| {
        var x: [16]i16 = @splat(0);
        x[0] = dc;

        var out: [16]i16 = undefined;
        inverseDct(&x, &out);
        const expected: i16 = @intCast((@as(i32, dc) + 4) >> 3);
        for (out) |v| try testing.expectEqual(expected, v);

        inverseWht(&x, &out);
        const expected_wht: i16 = @intCast((@as(i32, dc) + 3) >> 3);
        for (out) |v| try testing.expectEqual(expected_wht, v);
    }
}

test "an empty block transforms to nothing" {
    const zero: [16]i16 = @splat(0);
    var out: [16]i16 = undefined;
    inverseDct(&zero, &out);
    try testing.expectEqualSlices(i16, &zero, &out);
    inverseWht(&zero, &out);
    try testing.expectEqualSlices(i16, &zero, &out);
}

test "the quantiser tables run from four and never go backwards" {
    try testing.expectEqual(@as(u16, 4), dc_qlookup[0]);
    try testing.expectEqual(@as(u16, 4), ac_qlookup[0]);
    try testing.expectEqual(@as(u16, 157), dc_qlookup[127]);
    try testing.expectEqual(@as(u16, 284), ac_qlookup[127]);
    for (1..128) |i| {
        try testing.expect(dc_qlookup[i] >= dc_qlookup[i - 1]);
        try testing.expect(ac_qlookup[i] >= ac_qlookup[i - 1]);
    }
}

test "an index outside the tables is clamped rather than wrapped" {
    // The deltas in the frame header are signed and a segment may adjust
    // them further, so an index off either end is a thing a valid file can
    // ask for.
    try testing.expectEqual(dc_qlookup[0], dcFactor(-100));
    try testing.expectEqual(dc_qlookup[127], dcFactor(1000));
    try testing.expectEqual(ac_qlookup[0], acFactor(-1));
    try testing.expectEqual(ac_qlookup[127], acFactor(127));
}

test "Y2 is coarser than Y, and chroma's DC is capped" {
    var h: header.Header = .{};
    h.quant.y_ac = 60;
    const f = Factors.init(&h, null);

    try testing.expectEqual(dc_qlookup[60], f.y_dc);
    try testing.expectEqual(ac_qlookup[60], f.y_ac);
    // Doubled, and one and a half times over.
    try testing.expectEqual(dc_qlookup[60] * 2, f.y2_dc);
    try testing.expectEqual(@as(u16, @intCast(@as(u32, ac_qlookup[60]) * 155 / 100)), f.y2_ac);

    // At the top of the range the chroma DC would be 157 and is held at 132.
    h.quant.y_ac = 127;
    const top = Factors.init(&h, null);
    try testing.expectEqual(@as(u16, 132), top.uv_dc);

    // And at the bottom the Y2 AC would be 6 and is held at 8.
    h.quant.y_ac = 0;
    const bottom = Factors.init(&h, null);
    try testing.expectEqual(@as(u16, 8), bottom.y2_ac);
}

test "a segment adjusts the index, or replaces it" {
    var h: header.Header = .{};
    h.quant.y_ac = 50;
    h.segmentation.enabled = true;
    h.segmentation.quantizer = .{ 10, -10, 0, 40 };

    h.segmentation.absolute = false;
    try testing.expectEqual(ac_qlookup[60], Factors.init(&h, 0).y_ac);
    try testing.expectEqual(ac_qlookup[40], Factors.init(&h, 1).y_ac);

    h.segmentation.absolute = true;
    try testing.expectEqual(ac_qlookup[10], Factors.init(&h, 0).y_ac);
    try testing.expectEqual(ac_qlookup[40], Factors.init(&h, 3).y_ac);
}

test "dequantising multiplies the DC by one factor and the rest by another" {
    var block: [16]i16 = @splat(0);
    block[0] = 3;
    block[1] = -2;
    block[15] = 10;

    dequantise(&block, 20, 7);
    try testing.expectEqual(@as(i16, 60), block[0]);
    try testing.expectEqual(@as(i16, -14), block[1]);
    try testing.expectEqual(@as(i16, 70), block[15]);
}
