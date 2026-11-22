// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Intra prediction: guessing a block from its neighbours before the residue
//! is added back.
//!
//! Everything in a key frame is predicted from pixels already reconstructed
//! — the row immediately above and the column immediately to the left — and
//! what the file actually stores is the difference between that guess and
//! the truth. A good guess makes the difference small and the difference is
//! what costs bits, which is most of why an image codec compresses at all.
//!
//! ## Two sizes and fourteen modes
//!
//! A macroblock's luma is predicted either **whole** — one 16×16 guess in
//! one of four modes — or as **sixteen 4×4 subblocks**, each with its own
//! mode out of ten. Chroma is always predicted whole, as two 8×8 blocks in
//! the same four modes.
//!
//! The four whole-block modes are the obvious ones: fill with the average
//! (`dc`), copy the row above down (`v`), copy the column to the left across
//! (`h`), and propagate both (`tm`). The ten subblock modes add six
//! *diagonals* at roughly ±27° and ±45°, which is what makes `b_pred` worth
//! having on an edge that runs at an angle.
//!
//! ## What is off the edge of the frame
//!
//! The awkward part, and the part where an implementation is most likely to
//! be almost right. There is no single rule:
//!
//! - **`v` and `h`** use an invented row of **127** above the top row of the
//!   frame, and an invented column of **129** left of the first column. Two
//!   different values, which looks like a mistake and is not — the
//!   specification states both and every decoder uses both. It gives no
//!   reason for the asymmetry and neither does this.
//! - **`dc`** does *not* use those. It averages whichever of the two edges
//!   really exists; with neither — the very first macroblock — it fills with
//!   **128** flat.
//! - **`tm`** does use 127 and 129, unlike `dc`.
//!
//! And for subblock prediction there is one more: the four pixels *above and
//! to the right* of a subblock, which the diagonal modes reach for. For
//! subblocks on the right edge of a macroblock those pixels have not been
//! reconstructed yet, because macroblocks are done in raster order — so
//! subblocks 3, 7, 11 and 15 all use the four pixels above and to the right
//! of subblock 3. At the right edge of the frame those are the rightmost
//! visible pixel repeated, and on the top row of the frame they are 127.
//!
//! ## One typo worth knowing about
//!
//! Section 12.3's `B_HD_PRED` reads `svg2p(E + 1)`, which is not a function.
//! It is `avg2p`, as the comment beside it and every implementation agree.

const std = @import("std");
const testing = std.testing;

/// The four modes a whole block can be predicted with.
///
/// Luma has a fifth, `b_pred`, which is not a prediction at all but an
/// instruction to predict each of the sixteen subblocks separately.
pub const WholeMode = enum(u8) {
    dc = 0,
    v = 1,
    h = 2,
    tm = 3,
};

/// The ten modes a 4×4 luma subblock can be predicted with, in the order the
/// coding tree names them.
pub const SubMode = enum(u8) {
    dc = 0,
    tm = 1,
    ve = 2,
    he = 3,
    /// South-west, at 45°.
    ld = 4,
    /// South-east, at 45°.
    rd = 5,
    /// Vertical-right, at about 27° from vertical.
    vr = 6,
    vl = 7,
    /// Horizontal-down, at about 27° from horizontal.
    hd = 8,
    hu = 9,
};

/// What an absent row above reads as.
pub const absent_above: u8 = 127;
/// What an absent column to the left reads as.
///
/// Not the same as `absent_above`, and not a typo in this file or in the
/// specification: they really are 127 and 129.
pub const absent_left: u8 = 129;
/// What a `dc` prediction with no neighbours at all fills with.
pub const no_neighbours: u8 = 128;

fn clamp255(v: i32) u8 {
    return @intCast(std.math.clamp(v, 0, 255));
}

/// The weighted average of three adjacent pixels, centred on the middle one.
fn avg3(x: u8, y: u8, z: u8) u8 {
    return @intCast((@as(u32, x) + 2 * @as(u32, y) + @as(u32, z) + 2) >> 2);
}

/// The same, centred on `p[0]`, so it reaches one either side.
fn avg3p(p: []const u8, at: usize) u8 {
    return avg3(p[at - 1], p[at], p[at + 1]);
}

/// The plain average of two, which stands for a pixel half way between them.
fn avg2(x: u8, y: u8) u8 {
    return @intCast((@as(u32, x) + @as(u32, y) + 1) >> 1);
}

fn avg2p(p: []const u8, at: usize) u8 {
    return avg2(p[at], p[at + 1]);
}

/// Predicts a whole block of `size` by `size`.
///
/// `above` and `left` are the reconstructed neighbours, `corner` the pixel
/// diagonally above and left of both. `have_above` and `have_left` say
/// whether those are real pixels or the invented ones — which `dc` needs to
/// know and the others do not, because `dc` is the one mode that averages
/// rather than copies.
pub fn whole(
    mode: WholeMode,
    comptime size: usize,
    above: *const [size]u8,
    left: *const [size]u8,
    corner: u8,
    have_above: bool,
    have_left: bool,
    out: *[size * size]u8,
) void {
    switch (mode) {
        .v => for (0..size) |r| @memcpy(out[r * size ..][0..size], above),
        .h => for (0..size) |r| @memset(out[r * size ..][0..size], left[r]),
        .tm => {
            // Propagate the vertical differences down each column, starting
            // each from the row above. The clamp is needed and the averages
            // elsewhere are not: this is a sum of two pixels less a third
            // and can leave the range at either end.
            for (0..size) |r| {
                for (0..size) |c| {
                    out[r * size + c] = clamp255(
                        @as(i32, left[r]) + @as(i32, above[c]) - @as(i32, corner),
                    );
                }
            }
        },
        .dc => {
            // Only the edges that really exist are averaged, and the
            // invented 127 and 129 are deliberately *not* used here --- the
            // specification is explicit that the exceptional cases are not
            // the same as substituting those values.
            var sum: u32 = 0;
            var count: u32 = 0;
            if (have_above) {
                for (above) |p| sum += p;
                count += size;
            }
            if (have_left) {
                for (left) |p| sum += p;
                count += size;
            }
            const value: u8 = if (count == 0)
                no_neighbours
            else
                @intCast((sum + count / 2) / count);
            @memset(out, value);
        },
    }
}

/// Predicts one 4×4 luma subblock.
///
/// `edge` is the nine reconstructed pixels around its top-left corner, in
/// the order the specification's `E` array uses — the left column bottom to
/// top, then the corner, then the row above — followed by the four pixels
/// above and to the right, which the diagonal modes reach into. So:
///
/// ```
/// edge[0..4]   L[3], L[2], L[1], L[0]
/// edge[4]      P, the corner
/// edge[5..9]   A[0], A[1], A[2], A[3]
/// edge[9..13]  A[4], A[5], A[6], A[7], above and to the right
/// ```
pub fn subblock(mode: SubMode, edge: *const [13]u8, out: *[16]u8) void {
    // `A` indexed from -1, which is how the specification writes it: `a[0]`
    // is the corner and `a[1..9]` the eight pixels above.
    const a = edge[4..13];
    // `L` likewise, with `l[0]` the corner and `l[1..5]` the column down.
    const l = [5]u8{ edge[4], edge[3], edge[2], edge[1], edge[0] };
    const e = edge[0..9];

    switch (mode) {
        .dc => {
            var v: u32 = 4;
            for (0..4) |i| v += @as(u32, a[1 + i]) + l[1 + i];
            @memset(out, @intCast(v >> 3));
        },
        .tm => {
            for (0..4) |r| {
                for (0..4) |c| {
                    out[r * 4 + c] = clamp255(
                        @as(i32, l[1 + r]) + @as(i32, a[1 + c]) - @as(i32, a[0]),
                    );
                }
            }
        },
        .ve => {
            // Like `v`, but smoothed across three pixels --- which is why it
            // reaches one past each end of the four above.
            for (0..4) |c| {
                const value = avg3p(a, 1 + c);
                for (0..4) |r| out[r * 4 + c] = value;
            }
        },
        .he => {
            // The bottom row is exceptional because there is no pixel below
            // `L[3]` to smooth against, so it doubles the last one.
            for (0..3) |r| {
                const value = avg3p(&l, 1 + r);
                @memset(out[r * 4 ..][0..4], value);
            }
            @memset(out[12..16], avg3(l[3], l[4], l[4]));
        },
        .ld => {
            out[0] = avg3p(a, 2);
            out[1] = avg3p(a, 3);
            out[4] = out[1];
            out[2] = avg3p(a, 4);
            out[5] = out[2];
            out[8] = out[2];
            out[3] = avg3p(a, 5);
            out[6] = out[3];
            out[9] = out[3];
            out[12] = out[3];
            out[7] = avg3p(a, 6);
            out[10] = out[7];
            out[13] = out[7];
            out[11] = avg3p(a, 7);
            out[14] = out[11];
            // A[8] does not exist, so the last one doubles A[7].
            out[15] = avg3(a[7], a[8], a[8]);
        },
        .rd => {
            out[12] = avg3p(e, 1);
            out[13] = avg3p(e, 2);
            out[8] = out[13];
            out[14] = avg3p(e, 3);
            out[9] = out[14];
            out[4] = out[14];
            out[15] = avg3p(e, 4);
            out[10] = out[15];
            out[5] = out[15];
            out[0] = out[15];
            out[11] = avg3p(e, 5);
            out[6] = out[11];
            out[1] = out[11];
            out[7] = avg3p(e, 6);
            out[2] = out[7];
            out[3] = avg3p(e, 7);
        },
        .vr => {
            out[12] = avg3p(e, 2);
            out[8] = avg3p(e, 3);
            out[13] = avg3p(e, 4);
            out[4] = out[13];
            out[9] = avg2p(e, 4);
            out[0] = out[9];
            out[14] = avg3p(e, 5);
            out[5] = out[14];
            out[10] = avg2p(e, 5);
            out[1] = out[10];
            out[15] = avg3p(e, 6);
            out[6] = out[15];
            out[11] = avg2p(e, 6);
            out[2] = out[11];
            out[7] = avg3p(e, 7);
            out[3] = avg2p(e, 7);
        },
        .vl => {
            out[0] = avg2p(a, 1);
            out[4] = avg3p(a, 2);
            out[8] = avg2p(a, 2);
            out[1] = out[8];
            out[5] = avg3p(a, 3);
            out[12] = out[5];
            out[9] = avg2p(a, 3);
            out[2] = out[9];
            out[13] = avg3p(a, 4);
            out[6] = out[13];
            out[10] = avg2p(a, 4);
            out[3] = out[10];
            out[14] = avg3p(a, 5);
            out[7] = out[14];
            // The last two do not follow the pattern: there is nothing
            // further right to synthesise from.
            out[11] = avg3p(a, 6);
            out[15] = avg3p(a, 7);
        },
        .hd => {
            out[12] = avg2p(e, 0);
            out[13] = avg3p(e, 1);
            // The specification writes `svg2p` here, which is not a
            // function. It is `avg2p`, as its own comment and every
            // implementation agree.
            out[8] = avg2p(e, 1);
            out[14] = out[8];
            out[9] = avg3p(e, 2);
            out[15] = out[9];
            out[10] = avg2p(e, 2);
            out[4] = out[10];
            out[11] = avg3p(e, 3);
            out[5] = out[11];
            out[6] = avg2p(e, 3);
            out[0] = out[6];
            out[7] = avg3p(e, 4);
            out[1] = out[7];
            out[2] = avg3p(e, 5);
            out[3] = avg3p(e, 6);
        },
        .hu => {
            out[0] = avg2p(&l, 1);
            out[1] = avg3p(&l, 2);
            out[2] = avg2p(&l, 2);
            out[4] = out[2];
            out[3] = avg3p(&l, 3);
            out[5] = out[3];
            out[6] = avg2p(&l, 3);
            out[8] = out[6];
            out[7] = avg3(l[3], l[4], l[4]);
            out[9] = out[7];
            // Nothing nearby lies on the diagonals the rest would need, so
            // the bottom corner is simply the last left pixel.
            out[10] = l[4];
            out[11] = l[4];
            out[12] = l[4];
            out[13] = l[4];
            out[14] = l[4];
            out[15] = l[4];
        },
    }
}

// -- tests -------------------------------------------------------------------

fn ramp(comptime n: usize, start: u8, step: u8) [n]u8 {
    var out: [n]u8 = undefined;
    for (&out, 0..) |*v, i| v.* = start +% @as(u8, @intCast(i)) *% step;
    return out;
}

test "vertical prediction copies the row above into every row" {
    const above = ramp(8, 10, 7);
    const left = ramp(8, 200, 1);
    var out: [64]u8 = undefined;
    whole(.v, 8, &above, &left, 50, true, true, &out);
    for (0..8) |r| try testing.expectEqualSlices(u8, &above, out[r * 8 ..][0..8]);
}

test "horizontal prediction copies the column to the left across every column" {
    const above = ramp(8, 10, 7);
    const left = ramp(8, 200, 1);
    var out: [64]u8 = undefined;
    whole(.h, 8, &above, &left, 50, true, true, &out);
    for (0..8) |r| {
        for (0..8) |c| try testing.expectEqual(left[r], out[r * 8 + c]);
    }
}

test "true motion propagates both edges, and clamps where it must" {
    var above: [4]u8 = .{ 100, 200, 0, 255 };
    var left: [4]u8 = .{ 10, 250, 128, 0 };
    var out: [16]u8 = undefined;
    whole(.tm, 4, &above, &left, 128, true, true, &out);

    // left + above - corner, held inside the range at both ends.
    try testing.expectEqual(@as(u8, 0), out[0]); // 10 + 100 - 128 = -18
    try testing.expectEqual(@as(u8, 82), out[1]); // 10 + 200 - 128
    try testing.expectEqual(@as(u8, 255), out[4 + 1]); // 250 + 200 - 128 = 322
    try testing.expectEqual(@as(u8, 255), out[4 * 2 + 3]); // 128 + 255 - 128
}

test "DC prediction averages only the edges that exist" {
    const above: [4]u8 = .{ 10, 20, 30, 40 };
    const left: [4]u8 = .{ 100, 100, 100, 100 };
    var out: [16]u8 = undefined;

    // Both: the average of all eight, rounded.
    whole(.dc, 4, &above, &left, 0, true, true, &out);
    try testing.expectEqual(@as(u8, 63), out[0]); // (100 + 400 + 4) / 8

    // Only above.
    whole(.dc, 4, &above, &left, 0, true, false, &out);
    try testing.expectEqual(@as(u8, 25), out[0]); // (100 + 2) / 4

    // Only left.
    whole(.dc, 4, &above, &left, 0, false, true, &out);
    try testing.expectEqual(@as(u8, 100), out[0]);

    // Neither, which is the first macroblock of the frame.
    whole(.dc, 4, &above, &left, 0, false, false, &out);
    for (out) |v| try testing.expectEqual(no_neighbours, v);
}

test "the two invented edges are different values, and that is the rule" {
    // An absent row reads as 127 and an absent column as 129. It looks like
    // a typo in the specification and is not, so it gets a test: with both
    // absent, a `tm` prediction is 129 + 127 - 127, which is 129 and not
    // 128. A decoder that "corrected" either value to 128 would be wrong
    // along the top and left edges of every frame, subtly and everywhere.
    const above: [4]u8 = @splat(absent_above);
    const left: [4]u8 = @splat(absent_left);
    var out: [16]u8 = undefined;
    whole(.tm, 4, &above, &left, absent_above, true, true, &out);
    for (out) |v| try testing.expectEqual(absent_left, v);

    // And the corner off the top-left belongs to the row above, so it is
    // the 127 and not the 129.
    whole(.v, 4, &above, &left, absent_above, true, true, &out);
    for (out) |v| try testing.expectEqual(absent_above, v);
}

/// An edge with distinguishable values, so that a mode reading the wrong
/// one is visible.
fn edge13() [13]u8 {
    var e: [13]u8 = undefined;
    for (&e, 0..) |*v, i| v.* = @intCast(10 + i * 10);
    return e;
}

test "subblock DC averages the four above and the four to the left" {
    const e = edge13();
    var out: [16]u8 = undefined;
    subblock(.dc, &e, &out);
    // above = e[5..9] = 60, 70, 80, 90; left = e[3], e[2], e[1], e[0]
    // reading down = 40, 30, 20, 10. Sum 400, plus 4, over 8.
    try testing.expectEqual(@as(u8, 50), out[0]);
    for (out) |v| try testing.expectEqual(@as(u8, 50), v);
}

test "every subblock mode fills every pixel of the block" {
    // The cheapest guard against a transcription that left a hole: each of
    // the ten modes is run over an edge of distinct values, and every one
    // of the sixteen outputs must have been written.
    const e = edge13();
    inline for (comptime std.enums.values(SubMode)) |mode| {
        var out: [16]u8 = @splat(0xab);
        subblock(mode, &e, &out);
        for (out, 0..) |v, i| {
            testing.expect(v != 0xab) catch |err| {
                std.debug.print("{t} left pixel {d} unwritten\n", .{ mode, i });
                return err;
            };
        }
    }
}

test "the diagonal modes are constant along their diagonals" {
    // What makes them diagonal modes: every pixel on a line of the mode's
    // slope takes the same value. A transcription that swapped two
    // assignments would break this even if it filled every pixel.
    const e = edge13();
    var out: [16]u8 = undefined;

    // South-west at 45 degrees: (row + 1, col - 1) is the same pixel.
    subblock(.ld, &e, &out);
    for (0..3) |r| {
        for (1..4) |c| try testing.expectEqual(out[r * 4 + c], out[(r + 1) * 4 + c - 1]);
    }

    // South-east at 45 degrees: (row + 1, col + 1) is the same pixel.
    subblock(.rd, &e, &out);
    for (0..3) |r| {
        for (0..3) |c| try testing.expectEqual(out[r * 4 + c], out[(r + 1) * 4 + c + 1]);
    }
}

test "a flat edge predicts a flat block, in every mode" {
    // Every mode is an average or a copy of its neighbours, so neighbours
    // that are all one value can only predict that value --- whatever the
    // mode. It catches an index reaching outside the edge it was given,
    // which the distinct-values tests above cannot.
    const e: [13]u8 = @splat(77);
    inline for (comptime std.enums.values(SubMode)) |mode| {
        var out: [16]u8 = undefined;
        subblock(mode, &e, &out);
        for (out, 0..) |v, i| {
            testing.expectEqual(@as(u8, 77), v) catch |err| {
                std.debug.print("{t} at {d}\n", .{ mode, i });
                return err;
            };
        }
    }

    inline for (.{ WholeMode.dc, .v, .h, .tm }) |mode| {
        const above: [8]u8 = @splat(77);
        const left: [8]u8 = @splat(77);
        var out: [64]u8 = undefined;
        whole(mode, 8, &above, &left, 77, true, true, &out);
        for (out) |v| try testing.expectEqual(@as(u8, 77), v);
    }
}

test "subblock true motion matches the whole-block one on the same edge" {
    // They are the same rule at two sizes, so they must agree where they
    // overlap --- which is a check on the subblock edge layout, since the
    // two take their neighbours in quite different orders.
    const e = edge13();
    var sub: [16]u8 = undefined;
    subblock(.tm, &e, &sub);

    const above: [4]u8 = .{ e[5], e[6], e[7], e[8] };
    const left: [4]u8 = .{ e[3], e[2], e[1], e[0] };
    var big: [16]u8 = undefined;
    whole(.tm, 4, &above, &left, e[4], true, true, &big);

    try testing.expectEqualSlices(u8, &big, &sub);
}
