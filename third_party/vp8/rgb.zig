// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Turning the three planes into pixels.
//!
//! **RFC 6386 does not specify this.** It says the colour space is the one
//! everybody means by BT.601 and stops there, because converting to RGB is a
//! display decision rather than a decoding one — which is why two decoders
//! can both be right and disagree by a count.
//!
//! So the reference here is libwebp rather than the specification: its
//! coefficients, its rounding, and its two ways of stretching the chroma
//! planes back to full size. That is the convention behind every WebP anyone
//! has ever looked at, Pillow's included, and a library that chose its own
//! would be correct and useless.
//!
//! ## Two upsamplers
//!
//! Chroma is stored at half resolution in both directions, so each chroma
//! sample covers a two-by-two block of pixels. There are two ways to spread
//! it back out:
//!
//! - **`.plain`** repeats each sample over its four pixels. Obvious, fast,
//!   and visible as blockiness on a strong colour edge.
//! - **`.smooth`** interpolates, weighting the nearest chroma sample three
//!   to one against each of its neighbours — so a pixel takes 9/16 of the
//!   sample it sits on and the rest from the three around it. This is the
//!   default, and what `dwebp` does when not told otherwise.
//!
//! Both are exact against `dwebp` and `dwebp -nofancy` respectively.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const frame_mod = @import("frame.zig");

/// How to stretch the chroma planes back to full resolution.
pub const Upsampling = enum { smooth, plain };

/// The fixed-point conversion out of YUV, as libwebp computes it.
///
/// Sixteen-bit coefficients, a multiply that keeps the high bits, and a
/// final shift of six. The scale on luma is 255/219, which is what turns
/// the studio range the samples are stored in into the full range a screen
/// wants.
const y_scale: i32 = 19077;
const v_to_r: i32 = 26149;
const u_to_g: i32 = 6419;
const v_to_g: i32 = 13320;
const u_to_b: i32 = 33050;
const r_offset: i32 = -14234;
const g_offset: i32 = 8708;
const b_offset: i32 = -17685;

fn multHi(v: i32, coeff: i32) i32 {
    return (v * coeff) >> 8;
}

/// The last shift, and the clamp that goes with it.
fn clip8(v: i32) u8 {
    const shifted = v >> 6;
    return @intCast(std.math.clamp(shifted, 0, 255));
}

/// One pixel.
pub fn toRgb(y: u8, u: u8, v: u8) [3]u8 {
    const yy = multHi(y, y_scale);
    return .{
        clip8(yy + multHi(v, v_to_r) + r_offset),
        clip8(yy - multHi(u, u_to_g) - multHi(v, v_to_g) + g_offset),
        clip8(yy + multHi(u, u_to_b) + b_offset),
    };
}

/// Converts a decoded frame into RGBA, four bytes a pixel, alpha always 255.
///
/// The caller owns the result.
pub fn toRgba(
    gpa: Allocator,
    frame: *const frame_mod.Frame,
    upsampling: Upsampling,
) Allocator.Error![]u8 {
    const w = frame.width;
    const h = frame.height;
    const out = try gpa.alloc(u8, @as(usize, w) * h * 4);
    errdefer gpa.free(out);

    const cw = frame.chromaWidth();
    const ch = frame.chromaHeight();

    for (0..h) |row| {
        const luma = frame.luma(row);
        for (0..w) |col| {
            const uv = switch (upsampling) {
                .plain => plainSample(frame, col / 2, row / 2),
                .smooth => smoothSample(frame, col, row, cw, ch),
            };
            const rgb = toRgb(luma[col], uv[0], uv[1]);
            const at = (row * w + col) * 4;
            out[at + 0] = rgb[0];
            out[at + 1] = rgb[1];
            out[at + 2] = rgb[2];
            out[at + 3] = 255;
        }
    }
    return out;
}

fn plainSample(frame: *const frame_mod.Frame, cx: usize, cy: usize) [2]u8 {
    return .{ frame.chromaU(cy)[cx], frame.chromaV(cy)[cx] };
}

/// The interpolated sample for one pixel.
///
/// The pixel sits in one quadrant of its chroma sample, so the three nearest
/// neighbours are the ones on that side. Weighted nine, three, three, one —
/// which is a bilinear interpolation at quarter offsets, and is what makes a
/// colour edge a gradient rather than a staircase.
fn smoothSample(
    frame: *const frame_mod.Frame,
    col: usize,
    row: usize,
    cw: u32,
    ch: u32,
) [2]u8 {
    const cx = col / 2;
    const cy = row / 2;
    // Which way the nearest neighbours lie: left or right, up or down.
    const dx: isize = if (col % 2 == 0) -1 else 1;
    const dy: isize = if (row % 2 == 0) -1 else 1;

    const nx: usize = @intCast(std.math.clamp(@as(isize, @intCast(cx)) + dx, 0, @as(isize, cw) - 1));
    const ny: usize = @intCast(std.math.clamp(@as(isize, @intCast(cy)) + dy, 0, @as(isize, ch) - 1));

    var out: [2]u8 = undefined;
    inline for (0..2) |plane| {
        const row_here = if (plane == 0) frame.chromaU(cy) else frame.chromaV(cy);
        const row_there = if (plane == 0) frame.chromaU(ny) else frame.chromaV(ny);
        const a: u32 = row_here[cx];
        const b: u32 = row_here[nx];
        const c: u32 = row_there[cx];
        const d: u32 = row_there[nx];
        out[plane] = @intCast((9 * a + 3 * b + 3 * c + d + 8) / 16);
    }
    return out;
}

// -- tests -------------------------------------------------------------------

test "the conversion is the one libwebp makes" {
    // Black, white and the primaries, as the studio-range samples that
    // stand for them.
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0 }, &toRgb(16, 128, 128));
    const white = toRgb(235, 128, 128);
    for (white) |v| try testing.expect(v >= 253);

    // Luma below the studio floor clamps rather than wrapping.
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0 }, &toRgb(0, 128, 128));
    // And above the ceiling.
    const over = toRgb(255, 128, 128);
    for (over) |v| try testing.expectEqual(@as(u8, 255), v);
}

test "grey stays grey, to within the count the rounding costs" {
    // Neutral chroma should give equal channels, and almost does: the three
    // offsets are rounded independently, so at three of the two hundred and
    // fifty-six luma levels --- 86, 159 and 232 --- green comes out one
    // below red and blue. That is libwebp's arithmetic and not a mistake
    // here, and the test says "within one" rather than "equal" because the
    // stronger claim is false.
    //
    // It is still worth making: a coefficient out of place would spread the
    // channels by far more than one.
    var spread_one: u32 = 0;
    var y: u32 = 0;
    while (y <= 255) : (y += 1) {
        const c = toRgb(@intCast(y), 128, 128);
        const hi = @max(c[0], @max(c[1], c[2]));
        const lo = @min(c[0], @min(c[1], c[2]));
        try testing.expect(hi - lo <= 1);
        if (hi != lo) spread_one += 1;
    }
    try testing.expectEqual(@as(u32, 3), spread_one);
}
