// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Choosing a block's coefficients by what they cost rather than by what is
//! nearest.
//!
//! An ordinary quantiser rounds each coefficient to the nearest multiple of
//! its divisor and is done. That is the best answer to the question "which
//! value is closest", and the wrong question: what a JPEG wants is the
//! cheapest block that still looks like the original, and the cheapest block
//! is often not the nearest one.
//!
//! The reason is that the entropy coder does not price coefficients
//! independently. A coefficient costs a Huffman symbol naming how many zeroes
//! precede it and how many bits its value needs, plus those bits. So a
//! coefficient of ±1 sitting alone among zeroes costs several bits *and*
//! splits a run of zeroes in two, making its neighbours more expensive; the
//! same ±1 next to other non-zero coefficients costs much less. And the last
//! non-zero coefficient in a block is special: everything after it is free,
//! dismissed by one end-of-block symbol, so moving it earlier can delete a
//! dozen coefficients for the price of one.
//!
//! None of that is visible one coefficient at a time, which is why this is a
//! search over the whole block.
//!
//! ## What is being minimised
//!
//! `D + λR`: the squared error the choice introduces, plus a price per bit it
//! costs. Sweeping λ sweeps out the curve of everything achievable, and a
//! point on that curve is better than any encoder not on it — that is the
//! whole of rate-distortion optimisation, and the rest is bookkeeping.
//!
//! Measuring `D` on coefficients rather than on pixels is exact rather than an
//! approximation, and it is worth saying why: the transform in `idct` is
//! orthonormal, so it preserves the sum of squares, and squared error on the
//! coefficients *is* squared error on the samples. There is a test for it.
//!
//! Working in units of each coefficient's own divisor turns `D + λR` into
//! `(x - v)² + μR`, where `x` is the coefficient divided by its divisor and
//! `v` the integer chosen for it. `μ` is then one number for the whole image
//! rather than one per coefficient. What it should be is a question the theory
//! answers wrongly; see `default_strength`.
//!
//! ## The search
//!
//! A dynamic program over which position holds the last non-zero coefficient.
//! `best[i]` is the cheapest way to code positions 1 to `i` with `i` non-zero;
//! a step from `j` to `i` prices the run of zeroes between them, the symbol
//! for `i`, and the error of having zeroed everything in between. Two
//! candidate values are tried at each position — the rounded one and one step
//! towards zero — which is where nearly all of the gain is, since the choice
//! that matters is usually whether a coefficient survives at all.
//!
//! It is `O(63² · 2)` per block against 64 divisions, so it is not free and is
//! not on by default.
//!
//! ## What it does not do
//!
//! The DC coefficient is rounded, not searched. It is coded as a difference
//! from the previous block's, so its price depends on a neighbour this has not
//! seen and cannot see; a trellis over the DC coefficients is a second,
//! different search over a whole component at once.
//!
//! And the rate model is the *baseline* one, even when the file will be
//! progressive. A progressive scan splits a block across several scans and
//! prices it differently, so the costs here are an estimate there rather than
//! a count — and an estimate in the sequential case too, since the table the
//! rate comes from is not the table the file ends up with once the tables are
//! measured from the image.
//!
//! Both estimates turn out to be good enough, which is a claim worth measuring
//! rather than assuming. In progressive mode the saving against the quality
//! scale is within a tenth of a percent of what it is in baseline mode at
//! every quality tried.

const std = @import("std");
const math = std.math;
const testing = std.testing;

/// The side of a block.
pub const size = 8;
/// The coefficients in one block.
pub const len = size * size;

/// The raster position of each zig-zag index, which is the order the entropy
/// coder walks a block in and therefore the order the runs of zeroes are
/// counted in.
pub const zigzag = [len]u8{
    0,  1,  8,  16, 9,  2,  3,  10,
    17, 24, 32, 25, 18, 11, 4,  5,
    12, 19, 26, 33, 40, 48, 41, 34,
    27, 20, 13, 6,  7,  14, 21, 28,
    35, 42, 49, 56, 57, 50, 43, 36,
    29, 22, 15, 23, 30, 37, 44, 51,
    58, 59, 52, 45, 38, 31, 39, 46,
    53, 60, 61, 54, 47, 55, 62, 63,
};

/// What a bit is worth, in squared quantiser units.
///
/// Measured, and worth saying so, because the theory gives a different answer
/// and the theory is wrong here. High-rate quantisation theory puts the slope
/// of the distortion-rate curve for a uniform quantiser at `2 ln2 / 12`, about
/// `0.115` — but that assumes the quantiser sits *at* its rate-distortion
/// operating point, and the Annex K tables do not: they are perceptually
/// weighted, quantising high frequencies far more coarsely than minimising
/// squared error would. Priced at `0.115` the search gives away far more error
/// than the bits it saves are worth, and on a photograph it loses to simply
/// asking for a lower quality.
///
/// So this was swept against the quality scale instead, which is the honest
/// comparison: the question is not whether the search makes a smaller file —
/// anything that throws detail away does — but whether it makes a smaller file
/// than turning the quality down to the same fidelity would. At this value the
/// answer is yes at every quality tried, by about 0.8% at quality 85 and 3.7%
/// at 50. Higher spends more and wins more at low quality while losing at
/// high, which is why it is not higher.
pub const default_strength: f32 = 0.02;

/// The price of a symbol the table has no code for.
///
/// It cannot happen with the tables this is given — the Annex K AC tables
/// carry every run and size a block can produce — but a table is data and a
/// rate model that returned zero for a missing symbol would make the missing
/// ones look free and choose them.
const missing_symbol_bits = 32;

/// How many bits a value needs, which is what its Huffman symbol names.
fn magnitude(v: u32) u5 {
    return @intCast(32 - @clz(v));
}

/// Chooses the quantised value of every coefficient in one block.
///
/// `scaled` is each coefficient already divided by its quantiser, in raster
/// order — so the integer written out is a value in those same units, and the
/// error of choosing `v` for `x` is `(x - v)²` with no scaling left in it.
///
/// `ac_bits` is the AC Huffman table's code length for each symbol, which is
/// the whole of the rate model.
pub fn block(
    scaled: *const [len]f32,
    ac_bits: *const [256]u8,
    strength: f32,
    out: *[len]i16,
) void {
    @memset(out, 0);
    // The DC coefficient is rounded; see the note at the top of this file.
    out[0] = saturate(@round(scaled[0]));

    // What each position costs to abandon, and the running total of that, so
    // that the error of a run of zeroes is two lookups rather than a loop.
    var zeroed: [len]f32 = undefined;
    var upto: [len + 1]f32 = undefined;
    upto[0] = 0;
    upto[1] = 0;
    for (1..len) |k| {
        const x = scaled[zigzag[k]];
        zeroed[k] = x * x;
        upto[k + 1] = upto[k] + zeroed[k];
    }

    const infinity = math.inf(f32);
    // `best[i]`: the cheapest coding of positions 1..i with i non-zero.
    var best: [len]f32 = @splat(infinity);
    var chosen: [len]i16 = @splat(0);
    var came_from: [len]u8 = @splat(0);

    const eob_bits: f32 = @floatFromInt(cost(ac_bits, 0x00));
    const zrl_bits: f32 = @floatFromInt(cost(ac_bits, 0xf0));

    for (1..len) |i| {
        const x = scaled[zigzag[i]];
        const rounded: u32 = @intFromFloat(@round(@abs(x)));
        if (rounded == 0) continue; // nothing here can be made non-zero

        // The rounded value, and one step towards zero. A step further is
        // simply zero, which the search reaches by not choosing this position
        // at all.
        var candidates: [2]u32 = .{ rounded, rounded - 1 };
        const n: usize = if (rounded > 1) 2 else 1;

        for (candidates[0..n]) |v| {
            const bits = magnitude(v);
            const error_here = (@abs(x) - @as(f32, @floatFromInt(v)));
            const distortion = error_here * error_here;

            for (0..i) |j| {
                const before: f32 = if (j == 0) 0 else best[j];
                if (before == infinity) continue;

                const run = i - j - 1;
                // A run of more than fifteen zeroes needs a symbol of its own
                // for each sixteen of them.
                const zrls: f32 = @floatFromInt(run / 16);
                const symbol: u8 = @intCast(((run % 16) << 4) | @as(usize, bits));
                const rate = zrls * zrl_bits +
                    @as(f32, @floatFromInt(cost(ac_bits, symbol))) +
                    @as(f32, @floatFromInt(bits));

                const total = before + (upto[i] - upto[j + 1]) + distortion + strength * rate;
                if (total < best[i]) {
                    best[i] = total;
                    chosen[i] = if (x < 0) -@as(i16, @intCast(v)) else @intCast(v);
                    came_from[i] = @intCast(j);
                }
            }
        }
    }

    // Where to stop. Ending at `last` abandons everything after it, which
    // costs their error and one end-of-block symbol — unless `last` is the
    // final position, where the block ends on its own.
    var stop: usize = 0;
    var stop_cost = upto[len] + strength * eob_bits; // every coefficient zero
    for (1..len) |last| {
        if (best[last] == infinity) continue;
        const tail = upto[len] - upto[last + 1];
        const eob: f32 = if (last == len - 1) 0 else strength * eob_bits;
        const total = best[last] + tail + eob;
        if (total < stop_cost) {
            stop_cost = total;
            stop = last;
        }
    }

    var at = stop;
    while (at != 0) {
        out[zigzag[at]] = chosen[at];
        at = came_from[at];
    }
}

/// The code length of one symbol, or what a missing one is priced at.
fn cost(ac_bits: *const [256]u8, symbol: u8) u8 {
    const bits = ac_bits[symbol];
    return if (bits == 0) missing_symbol_bits else bits;
}

fn saturate(v: f32) i16 {
    return @intFromFloat(@max(
        @as(f32, math.minInt(i16)),
        @min(@as(f32, math.maxInt(i16)), v),
    ));
}

// -- tests -------------------------------------------------------------------

/// What a block of chosen values actually costs, computed the long way: walk
/// the zig-zag, count the runs, price each symbol.
///
/// Deliberately not the code above. The search's job is to find the cheapest
/// block; this says what a block costs, and the two agreeing is the whole
/// check.
fn costOf(scaled: *const [len]f32, chosen: *const [len]i16, ac_bits: *const [256]u8, strength: f32) f32 {
    var distortion: f32 = 0;
    for (1..len) |k| {
        const x = scaled[zigzag[k]];
        const v: f32 = @floatFromInt(chosen[zigzag[k]]);
        distortion += (x - v) * (x - v);
    }

    var last: usize = 0;
    for (1..len) |k| {
        if (chosen[zigzag[k]] != 0) last = k;
    }

    var bits: u32 = 0;
    var run: u32 = 0;
    for (1..last + 1) |k| {
        const v = chosen[zigzag[k]];
        if (v == 0) {
            run += 1;
            continue;
        }
        while (run > 15) {
            bits += cost(ac_bits, 0xf0);
            run -= 16;
        }
        const m = magnitude(@abs(v));
        bits += cost(ac_bits, @intCast((run << 4) | @as(u32, m))) + m;
        run = 0;
    }
    if (last != len - 1) bits += cost(ac_bits, 0x00);

    return distortion + strength * @as(f32, @floatFromInt(bits));
}

/// A rate model with a spread of code lengths, so that which symbol is chosen
/// actually matters. Shorter codes for small values and short runs, which is
/// the shape of a real table.
fn sampleBits() [256]u8 {
    var bits: [256]u8 = @splat(0);
    bits[0x00] = 4; // end of block
    bits[0xf0] = 11; // sixteen zeroes
    for (0..16) |run| {
        for (1..11) |m| {
            bits[(run << 4) | m] = @intCast(@min(16, 2 + run + m));
        }
    }
    return bits;
}

test "with bits free, the search rounds" {
    // The degenerate case, and the sharpest check on the bookkeeping: when
    // rate costs nothing, the cheapest block is the nearest one, so the whole
    // apparatus has to reproduce plain rounding exactly.
    const bits = sampleBits();
    var prng: std.Random.DefaultPrng = .init(0xa11ce);
    const rand = prng.random();

    for (0..200) |_| {
        var scaled: [len]f32 = undefined;
        for (&scaled) |*x| x.* = (rand.float(f32) - 0.5) * 20.0;

        var out: [len]i16 = undefined;
        block(&scaled, &bits, 0.0, &out);

        for (scaled, out) |x, v| {
            try testing.expectEqual(@as(i16, @intFromFloat(@round(x))), v);
        }
    }
}

test "with bits ruinously expensive, everything goes" {
    const bits = sampleBits();
    var scaled: [len]f32 = undefined;
    for (&scaled, 0..) |*x, i| x.* = if (i == 0) 12.0 else 3.0;

    var out: [len]i16 = undefined;
    block(&scaled, &bits, 1_000_000.0, &out);

    // The DC coefficient is not the search's to drop.
    try testing.expectEqual(@as(i16, 12), out[0]);
    for (out[1..]) |v| try testing.expectEqual(@as(i16, 0), v);
}

test "the search finds what an exhaustive one finds" {
    // The real test. Restricted to the first few positions and to values small
    // enough that `{rounded, rounded - 1, 0}` is every value there is, so that
    // enumerating the whole space is possible and is the same space the search
    // is allowed to look in.
    const bits = sampleBits();
    var prng: std.Random.DefaultPrng = .init(0xbeef);
    const rand = prng.random();

    const positions = 5;
    for (0..300) |_| {
        const strength = rand.float(f32) * 0.5;
        var scaled: [len]f32 = @splat(0);
        scaled[0] = 10.0;
        var rounded: [positions + 1]u32 = @splat(0);
        for (1..positions + 1) |k| {
            // Spread out along the zig-zag, so runs of zeroes of several
            // lengths come into it.
            const x = (rand.float(f32) - 0.5) * 5.0;
            scaled[zigzag[k * 7]] = x;
            rounded[k] = @intFromFloat(@round(@abs(x)));
        }

        var out: [len]i16 = undefined;
        block(&scaled, &bits, strength, &out);
        const got = costOf(&scaled, &out, &bits, strength);

        // Every combination of values at those positions.
        var want = math.inf(f32);
        var counter: u32 = 0;
        const combinations = std.math.pow(u32, 3, positions);
        while (counter < combinations) : (counter += 1) {
            var trial: [len]i16 = @splat(0);
            trial[0] = out[0];
            var n = counter;
            for (1..positions + 1) |k| {
                const pick = n % 3;
                n /= 3;
                const r = rounded[k];
                const v: u32 = switch (pick) {
                    0 => r,
                    1 => if (r > 0) r - 1 else 0,
                    else => 0,
                };
                const at = zigzag[k * 7];
                trial[at] = if (scaled[at] < 0) -@as(i16, @intCast(v)) else @intCast(v);
            }
            want = @min(want, costOf(&scaled, &trial, &bits, strength));
        }

        if (got > want + 1e-4) {
            std.debug.print("\nsearch found {d}, exhaustive found {d}\n", .{ got, want });
            return error.SearchIsNotOptimal;
        }
    }
}

test "a coefficient is never made larger than rounding would" {
    // The search only ever chooses a value at or below the rounded one, so it
    // can lose detail and never invent it.
    const bits = sampleBits();
    var prng: std.Random.DefaultPrng = .init(0xfeed);
    const rand = prng.random();

    for (0..200) |_| {
        var scaled: [len]f32 = undefined;
        for (&scaled) |*x| x.* = (rand.float(f32) - 0.5) * 30.0;

        var out: [len]i16 = undefined;
        block(&scaled, &bits, default_strength, &out);

        for (scaled[1..], out[1..]) |x, v| {
            const rounded: i32 = @intFromFloat(@round(@abs(x)));
            try testing.expect(@abs(@as(i32, v)) <= rounded);
            // And never flips a sign, which would be a different colour
            // rather than less of one.
            if (v != 0) try testing.expect((v < 0) == (x < 0));
        }
    }
}

test "a lone coefficient goes where a cluster stays" {
    // What the search is for, in the smallest case that shows it: the same
    // value is worth keeping among neighbours and not worth keeping alone,
    // because alone it also splits a run of zeroes and needs two run-of-
    // sixteen symbols to reach.
    //
    // At a price per bit of its own rather than the default, which is tuned
    // for what a photograph costs rather than for showing this: the claim
    // here is that the two blocks are treated *differently* at one price, not
    // that any particular price is the right one.
    const strength = 0.1;
    const bits = sampleBits();

    var lonely: [len]f32 = @splat(0);
    lonely[0] = 20.0;
    lonely[zigzag[40]] = 1.0;

    var clustered: [len]f32 = @splat(0);
    clustered[0] = 20.0;
    for (1..6) |k| clustered[zigzag[k]] = 1.0;

    var a: [len]i16 = undefined;
    block(&lonely, &bits, strength, &a);
    try testing.expectEqual(@as(i16, 0), a[zigzag[40]]);

    var b: [len]i16 = undefined;
    block(&clustered, &bits, strength, &b);
    var kept: usize = 0;
    for (1..6) |k| {
        if (b[zigzag[k]] != 0) kept += 1;
    }
    try testing.expect(kept >= 3);
}
