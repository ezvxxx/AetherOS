// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! The DCT coefficients: what a macroblock's residue actually is.
//!
//! Sixteen coefficients a block, read in zigzag order, each coded as a token
//! from a twelve-value tree. Most of them are zero and the tree is built
//! around that: end-of-block is one bit, a zero is two, a one is three, and
//! only a large coefficient costs anything like its magnitude.
//!
//! | token | value |
//! | --- | --- |
//! | `eob` | the rest of the block is zero |
//! | `zero`, `one`, `two`, `three`, `four` | exactly that |
//! | `cat1` … `cat6` | a range — 5–6, 7–10, 11–18, 19–34, 35–66, 67–2048 — with the offset in 1, 2, 3, 4, 5 or 11 extra bits |
//!
//! A non-zero value is then followed by a sign bit at even odds.
//!
//! ## The context is most of the format
//!
//! Which probabilities a token is read with depends on three things, and
//! getting any of them wrong decodes a picture that looks almost right:
//!
//! - the **plane** — Y after a Y2 block, Y2 itself, chroma, or Y with no Y2;
//! - the **band**, a grouping of the sixteen positions by how much they
//!   usually matter, so that position 0 and position 15 are coded with
//!   different statistics;
//! - the **context**, which is what the *previous* coefficient in this block
//!   was: zero, one, or more than one. For the first coefficient of a block
//!   it is instead how many of the block above and the block to the left had
//!   any coefficients at all.
//!
//! That last one is why a decoder has to carry a row of "above" flags and a
//! single "left" flag as it goes, and why blocks off the top or left edge of
//! the frame count as empty.
//!
//! ## Two things the pseudocode gets slightly wrong
//!
//! Section 13.3's pseudocode sets `prevCoeffWasZero = true` unconditionally
//! at the end of each iteration, which cannot be what it means — the whole
//! point of the flag is that end-of-block **cannot follow a zero**, so the
//! first branch of the tree is skipped only when the previous token really
//! was a zero. The reference decoder in Section 20.16 does it correctly and
//! is what this follows.
//!
//! And the pseudocode writes `block[i]`, in scan order. Coefficients are
//! stored in raster order and the scan is a zigzag, so it is
//! `block[zigzag[i]]`.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const boolean = @import("bool.zig");
const coeff = @import("coeff.zig");
const Prob = boolean.Prob;

/// The twelve tokens, in the order the tree names them.
pub const Token = enum(u8) {
    zero = 0,
    one = 1,
    two = 2,
    three = 3,
    four = 4,
    cat1 = 5,
    cat2 = 6,
    cat3 = 7,
    cat4 = 8,
    cat5 = 9,
    cat6 = 10,
    eob = 11,
};

/// The tree, as pairs of signed bytes: a positive entry is a deeper node, a
/// non-positive one is the leaf whose value is its negation.
pub const tree = [22]i8{
    -@as(i8, @backingInt(Token.eob)), 2, // eob = "0"
    -@as(i8, @backingInt(Token.zero)), 4, // 0 = "10"
    -@as(i8, @backingInt(Token.one)), 6, // 1 = "110"
    8,                                12,
    -@as(i8, @backingInt(Token.two)),   10, // 2 = "11100"
    -@as(i8, @backingInt(Token.three)), -@as(i8, @backingInt(Token.four)),
    14,                                 16,
    -@as(i8, @backingInt(Token.cat1)),  -@as(i8, @backingInt(Token.cat2)),
    18,                                 20,
    -@as(i8, @backingInt(Token.cat3)),  -@as(i8, @backingInt(Token.cat4)),
    -@as(i8, @backingInt(Token.cat5)),  -@as(i8, @backingInt(Token.cat6)),
};

/// Where to enter the tree when the previous token was a zero.
///
/// Node 2, which is the branch below end-of-block — because end-of-block
/// cannot follow a zero, so that bit is not in the stream at all.
pub const after_zero = 2;

/// Where each category's range starts.
pub const category_base = [6]u16{ 5, 7, 11, 19, 35, 67 };

/// The probabilities for each category's extra bits, most significant first,
/// terminated by a zero the way the specification writes them.
pub const cat_probs = [6][]const Prob{
    &.{159},
    &.{ 165, 145 },
    &.{ 173, 148, 140 },
    &.{ 176, 155, 140, 135 },
    &.{ 180, 157, 141, 134, 130 },
    &.{ 254, 254, 243, 230, 196, 177, 153, 140, 133, 130, 129 },
};

/// Scan order: where the `n`th coefficient read belongs in the four by four
/// block.
pub const zigzag = [16]u8{ 0, 1, 4, 8, 5, 2, 3, 6, 9, 12, 13, 10, 7, 11, 14, 15 };

/// Which plane's statistics a block is coded with.
pub const Plane = enum(u2) {
    /// Y, starting at coefficient 1, because coefficient 0 is in the Y2
    /// block.
    y_after_y2 = 0,
    y2 = 1,
    chroma = 2,
    /// Y with no Y2 block, so starting at coefficient 0.
    y_alone = 3,

    /// The first coefficient position this plane codes.
    pub fn first(self: Plane) u8 {
        return if (self == .y_after_y2) 1 else 0;
    }
};

/// One block's worth of quantised coefficients, in raster order.
pub const Block = [16]i16;

/// Reads one block's coefficients.
///
/// Returns the position decoding stopped at: the index of the end-of-block,
/// or 16 if the block ran to the end. A block whose result equals
/// `plane.first()` held nothing, which is what the neighbouring blocks are
/// told and what their `context` is built from.
pub fn readBlock(
    d: *boolean.Decoder,
    probs: *const coeff.Probs,
    plane: Plane,
    /// Zero, one or two: how many of the block above and the block to the
    /// left had any coefficients.
    context: u8,
    out: *Block,
) u8 {
    @memset(out, 0);

    var n = plane.first();
    var ctx = context;
    var previous_was_zero = false;

    while (n < 16) {
        const band = coeff.coeff_bands[n];
        const p = &probs[@backingInt(plane)][band][ctx];

        const token: Token = @fromBackingInt(@intCast(if (previous_was_zero)
            d.treeFrom(&tree, p, after_zero)
        else
            d.tree(&tree, p)));

        switch (token) {
            .eob => return n,
            .zero => {
                ctx = 0;
                previous_was_zero = true;
                n += 1;
            },
            else => {
                const magnitude = readMagnitude(d, token);
                // The sign is a plain flag at even odds: it is as likely to
                // be one as the other, and no context makes it otherwise.
                const value: i16 = @intCast(magnitude);
                out[zigzag[n]] = if (d.bool_(boolean.even) == 1) -value else value;
                ctx = if (magnitude == 1) 1 else 2;
                previous_was_zero = false;
                n += 1;
            },
        }
    }
    return 16;
}

/// The unsigned magnitude a non-zero token stands for.
fn readMagnitude(d: *boolean.Decoder, token: Token) u16 {
    return switch (token) {
        .one => 1,
        .two => 2,
        .three => 3,
        .four => 4,
        .cat1, .cat2, .cat3, .cat4, .cat5, .cat6 => blk: {
            const cat = @backingInt(token) - @backingInt(Token.cat1);
            // The offset within the range, most significant bit first, each
            // at its own fixed probability. Fixed, not from the frame: these
            // are the same in every VP8 stream ever made.
            var v: u16 = 0;
            for (cat_probs[cat]) |prob| v = v + v + d.bool_(prob);
            break :blk category_base[cat] + v;
        },
        .zero, .eob => unreachable, // handled by the caller
    };
}

// -- tests -------------------------------------------------------------------

/// Writes one block's coefficients, so that reading them can be checked.
fn writeBlock(
    e: *boolean.Encoder,
    probs: *const coeff.Probs,
    plane: Plane,
    context: u8,
    block: *const Block,
) Allocator.Error!void {
    // The last position in scan order that holds anything, which is where
    // the end-of-block goes.
    var last: i32 = -1;
    for (0..16) |i| {
        if (block[zigzag[i]] != 0) last = @intCast(i);
    }

    var n = plane.first();
    var ctx = context;
    var previous_was_zero = false;

    while (n < 16) {
        const band = coeff.coeff_bands[n];
        const p = &probs[@backingInt(plane)][band][ctx];

        if (@as(i32, n) > last) {
            // Everything left is zero. End-of-block says so in one bit ---
            // unless the previous token was a zero, in which case that bit
            // is not in the stream and the rest has to be written out as
            // zeros.
            if (!previous_was_zero) {
                try writeToken(e, p, .eob, 0);
                return;
            }
            try writeToken(e, p, .zero, if (previous_was_zero) after_zero else 0);
            ctx = 0;
            previous_was_zero = true;
            n += 1;
            continue;
        }

        const value = block[zigzag[n]];
        if (value == 0) {
            try writeToken(e, p, .zero, if (previous_was_zero) after_zero else 0);
            ctx = 0;
            previous_was_zero = true;
            n += 1;
            continue;
        }

        const magnitude: u16 = @intCast(@abs(value));
        const token = tokenFor(magnitude);
        try writeToken(e, p, token, if (previous_was_zero) after_zero else 0);
        if (@backingInt(token) >= @backingInt(Token.cat1)) {
            const cat = @backingInt(token) - @backingInt(Token.cat1);
            const offset = magnitude - category_base[cat];
            // Most significant bit first, which is what the reader's
            // `v = v + v + bit` builds up.
            const probs_for_cat = cat_probs[cat];
            for (probs_for_cat, 0..) |prob, k| {
                const shift: u4 = @intCast(probs_for_cat.len - 1 - k);
                try e.bool_(prob, @intCast((offset >> shift) & 1));
            }
        }
        try e.bool_(boolean.even, @intFromBool(value < 0));
        ctx = if (magnitude == 1) 1 else 2;
        previous_was_zero = false;
        n += 1;
    }
}

fn tokenFor(magnitude: u16) Token {
    if (magnitude <= 4) return @fromBackingInt(@intCast(magnitude));
    var cat: usize = 5;
    while (cat > 0 and magnitude < category_base[cat]) cat -= 1;
    return @fromBackingInt(@intCast(@backingInt(Token.cat1) + cat));
}

const Step = struct { prob: Prob, bit: u1 };

/// Writes a token, entering the tree where the reader will.
///
/// `start` is `after_zero` when the previous token was a zero, because the
/// reader skips the end-of-block branch then and a writer that did not would
/// put a bit in the stream nobody reads --- which desynchronises everything
/// after it, and shows up as the *next* non-zero coefficient coming back
/// wrong rather than this one.
fn writeToken(
    e: *boolean.Encoder,
    p: *const [coeff.branches]Prob,
    token: Token,
    start: usize,
) Allocator.Error!void {
    var path: [16]Step = undefined;
    const target: i8 = -@as(i8, @intCast(@backingInt(token)));
    const depth = findLeaf(p, start, target, &path, 0).?;
    for (path[0..depth]) |step| try e.bool_(step.prob, step.bit);
}

fn findLeaf(
    p: *const [coeff.branches]Prob,
    node: usize,
    target: i8,
    path: *[16]Step,
    depth: usize,
) ?usize {
    for ([_]u1{ 0, 1 }) |branch| {
        const entry: i8 = tree[node + branch];
        path[depth] = .{ .prob = p[node >> 1], .bit = branch };
        if (entry == target) return depth + 1;
        if (entry > 0) {
            if (findLeaf(p, @intCast(entry), target, path, depth + 1)) |n| return n;
        }
    }
    return null;
}

fn roundTrip(gpa: Allocator, plane: Plane, context: u8, block: Block) !struct { Block, u8 } {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var e: boolean.Encoder = .init(gpa, &out);
    try writeBlock(&e, &coeff.default_probs, plane, context, &block);
    try e.finish();

    var d = try boolean.Decoder.init(out.items);
    var back: Block = undefined;
    const last = readBlock(&d, &coeff.default_probs, plane, context, &back);
    return .{ back, last };
}

test "an empty block is one bit and comes back empty" {
    const gpa = testing.allocator;
    const result = try roundTrip(gpa, .y_alone, 0, @splat(0));
    try testing.expectEqualSlices(i16, &@as(Block, @splat(0)), &result[0]);
    // Stopped where it started, which is what tells the neighbours this
    // block held nothing.
    try testing.expectEqual(@as(u8, 0), result[1]);
}

test "every magnitude a token can carry survives the trip" {
    const gpa = testing.allocator;
    // One of each token's range, at both ends, plus the extremes of cat6.
    for ([_]i16{
        1, 2, 3, 4, // the single-value tokens
        5, 6, // cat1
        7, 10, // cat2
        11, 18, // cat3
        19, 34, // cat4
        35, 66, // cat5
        67, 200, 2048, // cat6
        -1, -5, -67, -2048, // and negative
    }) |value| {
        var block: Block = @splat(0);
        block[0] = value;
        const result = try roundTrip(gpa, .y_alone, 0, block);
        testing.expectEqual(value, result[0][0]) catch |err| {
            std.debug.print("value {d}\n", .{value});
            return err;
        };
    }
}

test "a block with coefficients scattered through it comes back in order" {
    const gpa = testing.allocator;
    var block: Block = @splat(0);
    // Deliberately not in scan order, so that a zigzag applied the wrong way
    // round would show up.
    block[0] = 12;
    block[1] = -1;
    block[4] = 3;
    block[15] = -70;
    block[7] = 2;

    const result = try roundTrip(gpa, .y_alone, 0, block);
    try testing.expectEqualSlices(i16, &block, &result[0]);
    // The last thing in scan order is raster position 15, which is scan
    // position 15, so the block runs to the end.
    try testing.expectEqual(@as(u8, 16), result[1]);
}

test "the zigzag is a permutation, and the one the specification gives" {
    var seen: [16]bool = @splat(false);
    for (zigzag) |z| {
        try testing.expect(!seen[z]);
        seen[z] = true;
    }
    // The first four: across, down-left, down, and the corner it reaches.
    try testing.expectEqual(@as(u8, 0), zigzag[0]);
    try testing.expectEqual(@as(u8, 1), zigzag[1]);
    try testing.expectEqual(@as(u8, 4), zigzag[2]);
    try testing.expectEqual(@as(u8, 15), zigzag[15]);
}

test "a Y block after a Y2 block skips its first coefficient" {
    const gpa = testing.allocator;
    var block: Block = @splat(0);
    block[1] = 7;
    // Position 0 is in the Y2 block and this plane never codes it, so a
    // value there cannot survive --- and must not be coded, or every
    // position after it would be out by one.
    block[0] = 99;

    const result = try roundTrip(gpa, .y_after_y2, 0, block);
    try testing.expectEqual(@as(i16, 0), result[0][0]);
    try testing.expectEqual(@as(i16, 7), result[0][1]);
}

test "every plane and every starting context round trips" {
    const gpa = testing.allocator;
    var block: Block = @splat(0);
    block[0] = 4;
    block[5] = -9;
    block[11] = 1;

    for ([_]Plane{ .y_after_y2, .y2, .chroma, .y_alone }) |plane| {
        for ([_]u8{ 0, 1, 2 }) |context| {
            const result = try roundTrip(gpa, plane, context, block);
            var want = block;
            // The one plane that cannot carry a coefficient at position 0.
            if (plane == .y_after_y2) want[0] = 0;
            testing.expectEqualSlices(i16, &want, &result[0]) catch |err| {
                std.debug.print("plane {t}, context {d}\n", .{ plane, context });
                return err;
            };
        }
    }
}

test "a block of every position filled runs to the end without an end-of-block" {
    const gpa = testing.allocator;
    var block: Block = undefined;
    for (&block, 0..) |*v, i| v.* = @intCast(i + 1);

    const result = try roundTrip(gpa, .y_alone, 0, block);
    try testing.expectEqualSlices(i16, &block, &result[0]);
    try testing.expectEqual(@as(u8, 16), result[1]);
}
