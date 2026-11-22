// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! The inverse discrete cosine transform, on the eight-by-eight blocks JPEG
//! stores.
//!
//! A JPEG block is sixty-four frequency coefficients. The transform turns them
//! back into sixty-four samples, and it is the arithmetic heart of the format:
//! everything else is bookkeeping around it.
//!
//! ## Why this one
//!
//! The transform is separable — a two-dimensional IDCT is a one-dimensional
//! one applied to every row and then to every column — so what is written here
//! is the definition, twice:
//!
//! ```text
//!   s(x) = ½ · Σ  C(u) · S(u) · cos((2x + 1)uπ / 16)
//!             u
//! ```
//!
//! with `C(0) = 1/√2` and `C(u) = 1` otherwise. The cosines are a fixed
//! eight-by-eight table computed at compile time, so each pass is an
//! eight-by-eight matrix multiply and a block costs 1024 multiply-adds.
//!
//! Faster IDCTs exist and every production decoder uses one: Loeffler's
//! factorisation brings a one-dimensional pass from 64 multiplies down to 11,
//! and libjpeg's `jpeg_idct_islow` is that in 13-bit fixed point. The reason
//! not to start there is that a factorised IDCT is a wall of magic constants
//! whose correctness is not apparent from reading it, and an IDCT that is
//! subtly wrong produces images that look fine until they do not. This one can
//! be checked against the definition by eye, and the test below checks it
//! against a direct evaluation of the formula above at every basis function.
//!
//! Replacing it is a contained change if the speed is ever wanted: the only
//! thing outside this file that matters is that `block` maps sixty-four
//! coefficients to sixty-four samples.
//!
//! ## Accuracy
//!
//! The JPEG specification does not define an exact IDCT — it defines accuracy
//! *requirements*, in ITU-T T.83, because a bit-exact transform would have
//! ruled out the fast approximations everybody wanted to use. Two conforming
//! decoders may therefore disagree by a little, and this one and libjpeg do.
//! That is why the tests compare against Pillow with a tolerance rather than
//! for equality, and it is a property of the format rather than a weakness
//! here: computed in `f32` from the definition, this is *more* accurate than
//! the fixed-point transforms it is being compared against.

const std = @import("std");
const math = std.math;
const testing = std.testing;

/// The side of a block, and the reason for every 8 and 64 in this file.
pub const size = 8;

/// `cos((2x + 1) · u · π / 16) · C(u) / 2`, for every `x` and `u`.
///
/// One pass of the transform is a multiply by this matrix. Built at compile
/// time, so the cosines cost nothing at run time and the table can be read as
/// the definition it is.
const basis: [size][size]f32 = blk: {
    @setEvalBranchQuota(10_000);
    var table: [size][size]f32 = undefined;
    for (0..size) |x| {
        for (0..size) |u| {
            const c: f32 = if (u == 0) 1.0 / math.sqrt2 else 1.0;
            table[x][u] = c * @cos((2.0 * @as(f32, @floatFromInt(x)) + 1.0) *
                @as(f32, @floatFromInt(u)) * math.pi / 16.0) / 2.0;
        }
    }
    break :blk table;
};

/// Transforms one block of coefficients into one block of samples.
///
/// `in` is in row-major order, already dequantised. `out` receives the samples
/// with the level shift applied and clamped to a byte: JPEG stores samples
/// centred on zero, so 128 is added on the way out, and a block whose
/// coefficients came from a lossy round trip can land a little outside the
/// range a byte holds.
pub fn block(in: *const [size * size]i32, out: *[size * size]u8) void {
    // Rows first, into an intermediate that keeps full precision.
    var tmp: [size * size]f32 = undefined;
    for (0..size) |y| {
        const row = in[y * size ..][0..size];
        for (0..size) |x| {
            var sum: f32 = 0;
            for (0..size) |u| {
                const coeff = row[u];
                if (coeff != 0) sum += basis[x][u] * @as(f32, @floatFromInt(coeff));
            }
            tmp[y * size + x] = sum;
        }
    }

    // Then columns, and out.
    for (0..size) |x| {
        for (0..size) |y| {
            var sum: f32 = 0;
            for (0..size) |v| {
                sum += basis[y][v] * tmp[v * size + x];
            }
            // The level shift, and the rounding that turns a real number back
            // into a sample.
            const shifted = sum + 128.0;
            out[y * size + x] = if (shifted <= 0)
                0
            else if (shifted >= 255)
                255
            else
                @intFromFloat(@round(shifted));
        }
    }
}

/// The forward transform, which the encoder needs.
///
/// The mirror of `block`: the level shift comes off, and the same basis is
/// applied the other way round.
///
/// The coefficients come back as `f32` rather than rounded, which matters more
/// than it looks. The encoder divides each one by a quantiser and rounds
/// *that*, so rounding here as well would round twice — and the error the
/// first rounding introduces survives the division, moving a coefficient
/// across the boundary between two quantised values whenever the true value
/// happens to sit near one. Those are coefficients that become non-zero when
/// they should not have, which is the expensive kind: each breaks a run of
/// zeroes and costs several bits. Rounding once costs nothing and is what
/// libjpeg's float path does.
pub fn forward(in: *const [size * size]u8, out: *[size * size]f32) void {
    var shifted: [size * size]f32 = undefined;
    for (in, &shifted) |s, *d| d.* = @as(f32, @floatFromInt(s)) - 128.0;

    var tmp: [size * size]f32 = undefined;
    for (0..size) |y| {
        for (0..size) |u| {
            var sum: f32 = 0;
            for (0..size) |x| {
                sum += basis[x][u] * shifted[y * size + x];
            }
            tmp[y * size + u] = sum;
        }
    }
    for (0..size) |u| {
        for (0..size) |v| {
            var sum: f32 = 0;
            for (0..size) |y| {
                sum += basis[y][v] * tmp[y * size + u];
            }
            out[v * size + u] = sum;
        }
    }
}

/// The definition, evaluated directly, for the tests to check against.
fn reference(in: *const [size * size]i32, x: usize, y: usize) f64 {
    var sum: f64 = 0;
    for (0..size) |v| {
        for (0..size) |u| {
            const cu: f64 = if (u == 0) 1.0 / @sqrt(2.0) else 1.0;
            const cv: f64 = if (v == 0) 1.0 / @sqrt(2.0) else 1.0;
            sum += cu * cv * @as(f64, @floatFromInt(in[v * size + u])) *
                @cos((2.0 * @as(f64, @floatFromInt(x)) + 1.0) * @as(f64, @floatFromInt(u)) * math.pi / 16.0) *
                @cos((2.0 * @as(f64, @floatFromInt(y)) + 1.0) * @as(f64, @floatFromInt(v)) * math.pi / 16.0);
        }
    }
    return sum / 4.0;
}

test "every basis function matches the definition" {
    // Sixty-four blocks, each with a single coefficient set: between them they
    // span everything the transform can produce, so agreeing on all of them is
    // agreeing on the transform.
    for (0..size * size) |k| {
        var in: [size * size]i32 = @splat(0);
        in[k] = 200;
        var out: [size * size]u8 = undefined;
        block(&in, &out);

        for (0..size) |y| {
            for (0..size) |x| {
                const want = reference(&in, x, y) + 128.0;
                const clamped: f64 = @max(0, @min(255, want));
                const got: f64 = @floatFromInt(out[y * size + x]);
                if (@abs(got - clamped) > 1.0) {
                    std.debug.print("coefficient {d} at ({d},{d}): {d}, definition says {d}\n", .{
                        k, x, y, got, clamped,
                    });
                    return error.TransformDisagreesWithDefinition;
                }
            }
        }
    }
}

test "a flat block is its DC coefficient" {
    // The one case anybody can check by hand: only the DC term set means every
    // sample is the same, and its value is the coefficient over eight.
    var in: [size * size]i32 = @splat(0);
    in[0] = 8 * 50; // 8 · 50 / 8 = 50 above the level shift
    var out: [size * size]u8 = undefined;
    block(&in, &out);
    for (out) |s| try testing.expectEqual(@as(u8, 178), s);
}

test "an empty block is mid grey" {
    var in: [size * size]i32 = @splat(0);
    var out: [size * size]u8 = undefined;
    block(&in, &out);
    for (out) |s| try testing.expectEqual(@as(u8, 128), s);
}

test "the transform round trips through its own inverse" {
    var samples: [size * size]u8 = undefined;
    var seed: u32 = 12345;
    for (&samples) |*s| {
        seed = seed *% 1664525 +% 1013904223;
        s.* = @truncate(seed >> 16);
    }

    var coeffs: [size * size]f32 = undefined;
    forward(&samples, &coeffs);
    var rounded: [size * size]i32 = undefined;
    for (coeffs, &rounded) |c, *r| r.* = @intFromFloat(@round(c));
    var back: [size * size]u8 = undefined;
    block(&rounded, &back);

    // Rounding the coefficients to whole numbers is the only loss, and it is
    // small: this is the transform alone, with no quantisation in the way.
    for (samples, back) |a, b| {
        const diff = if (a > b) a - b else b - a;
        try testing.expect(diff <= 1);
    }
}

test "out-of-range coefficients clamp rather than wrap" {
    // A coefficient far larger than any real image produces, which a decoder
    // meets when a file is corrupt. The samples must saturate, not wrap around
    // into a bright speckle.
    var in: [size * size]i32 = @splat(0);
    in[0] = 100_000;
    var out: [size * size]u8 = undefined;
    block(&in, &out);
    for (out) |s| try testing.expectEqual(@as(u8, 255), s);

    in[0] = -100_000;
    block(&in, &out);
    for (out) |s| try testing.expectEqual(@as(u8, 0), s);
}

test "the transform is orthonormal" {
    // Which matters beyond elegance: an orthonormal transform preserves the
    // sum of squares, so squared error measured on the coefficients *is*
    // squared error on the samples. Anything choosing coefficients to trade
    // error against bits depends on that, because it can only see
    // coefficients.
    //
    // The basis is `C(u)·cos((2x+1)uπ/16)/2`, and the orthonormal DCT-II's
    // factor is `sqrt(2/N)·C(u)`, which at N=8 is `C(u)/2`. So this checks
    // what the table was built to be.
    for (0..size) |u| {
        for (0..size) |v| {
            var dot: f64 = 0;
            for (0..size) |x| dot += @as(f64, basis[x][u]) * @as(f64, basis[x][v]);
            const want: f64 = if (u == v) 1.0 else 0.0;
            if (@abs(dot - want) > 1e-6) {
                std.debug.print("columns {d} and {d} dot to {d}\n", .{ u, v, dot });
                return error.BasisIsNotOrthonormal;
            }
        }
    }
}
