// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! VP8's boolean entropy coder, and the tree coding built on it.
//!
//! Everything in a VP8 frame past the ten-byte uncompressed header is read
//! through this, so it is the first thing a decoder needs and the only thing
//! that can be finished before anything else is started.
//!
//! It is a **binary arithmetic coder**, not a bit reader. Each call says how
//! likely the bit is to be zero — a probability out of 256 — and the coder
//! spends less than a whole bit on a likely one. The state is an interval:
//! `range` is how wide it is and `value` is how far into it the encoded
//! number falls, and reading a bool splits the interval in proportion to the
//! probability and keeps whichever half the number is in.
//!
//! ```
//! split = 1 + ((range - 1) * prob) / 256
//! ```
//!
//! That `1 +` is not rounding. It is what keeps `split` strictly between zero
//! and `range`, so that neither branch can be given an empty interval however
//! extreme the probability — an encoder and a decoder that disagreed about
//! that would diverge on the first improbable bit.
//!
//! ## What the probabilities are for
//!
//! They are not decoration. A VP8 frame carries, in its header, updates to
//! hundreds of probabilities, and every one of them is a claim about what the
//! *next* symbol is likely to be given its context — which coefficient
//! position, which neighbouring blocks, which band. Coding a bit at
//! probability 254 costs about a fiftieth of a bit. That is where the
//! compression is; the transforms and the prediction only arrange for the
//! probabilities to be extreme.
//!
//! ## Trees
//!
//! A value from a small alphabet is coded as a walk down a binary tree, one
//! bool per branch, each with its own probability. The tree is an array of
//! signed bytes in pairs: a positive entry is the index of a deeper interior
//! node, and a non-positive entry `v` is the leaf whose value is `-v`. The
//! probabilities are indexed by half the tree position, so the array is one
//! shorter than the alphabet.
//!
//! The whole of reading one is a single line, which is the point of the
//! representation.
//!
//! ## Running out
//!
//! The specification's decoder reads past the end of its partition without
//! noticing, which is fine for a reference implementation and not for one
//! handed a file off the network. This one supplies zeroes instead and
//! records that it did, so a caller can ask afterwards whether what it
//! decoded was in the file or was made up — while the decode itself carries
//! on and terminates, because the alternative is threading an error through
//! every one of the several million calls a frame makes.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

/// A probability that the next bool is zero, out of 256.
///
/// Never 0 and never 256: the split is nudged so that both branches keep a
/// non-empty interval, so a probability of 0 still leaves a way to code a
/// zero. It is a hint about likelihood and never a promise.
pub const Prob = u8;

/// Even chances, which is what a literal is coded at.
pub const even: Prob = 128;

/// A tree, as pairs of signed bytes.
///
/// A positive entry is the index of a deeper interior node; a non-positive
/// entry `v` is the leaf whose value is `-v`.
pub const Tree = []const i8;

pub const Decoder = struct {
    input: []const u8,
    at: usize,
    /// Always identical to the encoder's.
    range: u32,
    /// The encoded number, less the left end of the current interval.
    value: u32,
    /// How many bits have been shifted out of `value`; at most seven.
    bit_count: u8,
    /// Set once a byte has been invented because the partition ran out.
    ///
    /// Not an error, and not ignorable either: everything decoded after it is
    /// arithmetic on zeroes rather than on anything the file said.
    exhausted: bool = false,

    /// A partition needs two bytes to start. One byte or none is not a short
    /// partition but an absent one.
    pub fn init(input: []const u8) error{Truncated}!Decoder {
        if (input.len < 2) return error.Truncated;
        return .{
            .input = input,
            .at = 2,
            .range = 255,
            .value = (@as(u32, input[0]) << 8) | input[1],
            .bit_count = 0,
        };
    }

    fn nextByte(self: *Decoder) u8 {
        if (self.at >= self.input.len) {
            self.exhausted = true;
            return 0;
        }
        const byte = self.input[self.at];
        self.at += 1;
        return byte;
    }

    /// Reads one bool, which the encoder wrote at this same probability.
    pub fn bool_(self: *Decoder, prob: Prob) u1 {
        // Strictly bigger than zero and strictly smaller than `range`, which
        // is what the `1 +` is for.
        const split = 1 + (((self.range - 1) * @as(u32, prob)) >> 8);
        const big = split << 8;

        var bit: u1 = 0;
        if (self.value >= big) {
            bit = 1;
            self.range -= split;
            self.value -= big;
        } else {
            self.range = split;
        }

        // Renormalise: the interval has to stay wide enough for the next
        // split to be meaningful, and every doubling of it is a bit of
        // `value` that has stopped mattering.
        while (self.range < 128) {
            self.value <<= 1;
            self.range <<= 1;
            self.bit_count += 1;
            if (self.bit_count == 8) {
                self.bit_count = 0;
                self.value |= self.nextByte();
            }
        }
        return bit;
    }

    /// An unsigned value of `n` bits, high-order first, each at even odds.
    pub fn literal(self: *Decoder, n: u6) u32 {
        var v: u32 = 0;
        for (0..n) |_| v = (v << 1) | self.bool_(even);
        return v;
    }

    /// A signed `n`-bit number, high-order bit first.
    ///
    /// Two's complement, and worth pausing on because it is *not* the shape
    /// the rest of the format uses. The specification starts the value at
    /// minus one when the top bit is set and then shifts the remaining bits
    /// in, which sign-extends: five bits of `10101` is -11, not -5. A reader
    /// who assumed a sign and a magnitude --- the form every *other* signed
    /// field in VP8 takes, and the one `optionalSigned` implements --- would
    /// be wrong by an amount that depends on the value.
    ///
    /// The specification calls these rare, and they are.
    pub fn signedLiteral(self: *Decoder, n: u6) i32 {
        if (n == 0) return 0;
        var v: i32 = if (self.bool_(even) == 1) -1 else 0;
        for (1..n) |_| v = (v << 1) + @as(i32, self.bool_(even));
        return v;
    }

    /// A seven-bit specification of an eight-bit probability.
    ///
    /// Zero means one rather than zero, because a probability of zero would
    /// say a bool can never be zero and the coder has no way to express
    /// that: the split is nudged to keep both branches reachable, so the
    /// value would be a lie.
    pub fn prob7(self: *Decoder) Prob {
        const x = self.literal(7);
        return if (x != 0) @intCast(x << 1) else 1;
    }

    /// A flag, and then a signed value of `n` bits if the flag was set.
    ///
    /// The shape the frame header uses everywhere for an optional adjustment.
    pub fn optionalSigned(self: *Decoder, n: u6) i32 {
        if (self.bool_(even) == 0) return 0;
        const magnitude = self.literal(n);
        const negative = self.bool_(even) == 1;
        const v: i32 = @intCast(magnitude);
        return if (negative) -v else v;
    }

    /// Walks a tree, one bool a branch, and returns the leaf.
    pub fn tree(self: *Decoder, t: Tree, probs: []const Prob) u8 {
        return self.treeFrom(t, probs, 0);
    }

    /// The same, starting part way down — which the coefficient decoder
    /// needs, because it skips the first branch when it already knows the
    /// previous token was not zero.
    pub fn treeFrom(self: *Decoder, t: Tree, probs: []const Prob, start: usize) u8 {
        var i: i8 = t[start + self.bool_(probs[start >> 1])];
        while (i > 0) {
            const at: usize = @intCast(i);
            i = t[at + self.bool_(probs[at >> 1])];
        }
        return @intCast(-i);
    }
};

/// The encoder, which exists so that the decoder can be tested.
///
/// A decoder alone can only be checked against files somebody else wrote,
/// and until the rest of VP8 exists there is nothing here that can read one.
/// An encoder written from the same description gives the property that
/// matters in the meantime: what goes in comes out, at every probability,
/// including the extreme ones where the `1 +` in the split is doing the work.
pub const Encoder = struct {
    out: *std.ArrayList(u8),
    gpa: Allocator,
    range: u32 = 255,
    /// The least the remaining output can be.
    bottom: u32 = 0,
    /// Shifts before a byte is ready.
    bit_count: i32 = 24,

    pub fn init(gpa: Allocator, out: *std.ArrayList(u8)) Encoder {
        return .{ .out = out, .gpa = gpa };
    }

    /// A carry into what has already been written.
    ///
    /// Very rare, and it can never run off the front: the encoded number is
    /// always less than one, so there is always a zero byte above to absorb
    /// it.
    fn carry(self: *Encoder) void {
        var i = self.out.items.len;
        while (i > 0) {
            i -= 1;
            if (self.out.items[i] != 255) {
                self.out.items[i] += 1;
                return;
            }
            self.out.items[i] = 0;
        }
    }

    pub fn bool_(self: *Encoder, prob: Prob, bit: u1) Allocator.Error!void {
        const split = 1 + (((self.range - 1) * @as(u32, prob)) >> 8);
        if (bit == 1) {
            self.bottom += split;
            self.range -= split;
        } else {
            self.range = split;
        }

        while (self.range < 128) {
            self.range <<= 1;
            if (self.bottom & (1 << 31) != 0) self.carry();
            self.bottom <<= 1;
            self.bit_count -= 1;
            if (self.bit_count == 0) {
                try self.out.append(self.gpa, @truncate(self.bottom >> 24));
                self.bottom &= (1 << 24) - 1;
                self.bit_count = 8;
            }
        }
    }

    pub fn literal(self: *Encoder, value: u32, n: u6) Allocator.Error!void {
        var i = n;
        while (i > 0) {
            i -= 1;
            try self.bool_(even, @intCast((value >> @intCast(i)) & 1));
        }
    }

    /// Writes out what is still held, once, after the last bool.
    pub fn finish(self: *Encoder) Allocator.Error!void {
        var c = self.bit_count;
        var v = self.bottom;

        if (v & (@as(u32, 1) << @intCast(32 - c)) != 0) self.carry();
        v <<= @intCast(c & 7);
        c >>= 3;
        while (c > 0) : (c -= 1) v <<= 8;
        for (0..4) |_| {
            try self.out.append(self.gpa, @truncate(v >> 24));
            v <<= 8;
        }
    }
};

// -- tests -------------------------------------------------------------------

test "what is written comes back, at every probability" {
    const gpa = testing.allocator;
    // Every probability, and a bit pattern that is not the same at each so
    // that a coder which ignored the probability would still have to get the
    // bits right by luck.
    var prob: u16 = 0;
    while (prob <= 255) : (prob += 1) {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(gpa);
        var e: Encoder = .init(gpa, &out);

        var bits: [64]u1 = undefined;
        for (&bits, 0..) |*b, i| b.* = @intCast((i * 7 + prob) % 3 & 1);
        for (bits) |b| try e.bool_(@intCast(prob), b);
        try e.finish();

        var d = try Decoder.init(out.items);
        for (bits, 0..) |want, i| {
            const got = d.bool_(@intCast(prob));
            testing.expectEqual(want, got) catch |err| {
                std.debug.print("prob {d}, bit {d}\n", .{ prob, i });
                return err;
            };
        }
        try testing.expect(!d.exhausted);
    }
}

test "a literal comes back high-order bit first" {
    const gpa = testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var e: Encoder = .init(gpa, &out);

    try e.literal(0b1011, 4);
    try e.literal(0xdeadbe, 24);
    try e.literal(1, 1);
    try e.finish();

    var d = try Decoder.init(out.items);
    try testing.expectEqual(@as(u32, 0b1011), d.literal(4));
    try testing.expectEqual(@as(u32, 0xdeadbe), d.literal(24));
    try testing.expectEqual(@as(u32, 1), d.literal(1));
}

test "a signed literal is two's complement, not a sign and a magnitude" {
    const gpa = testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var e: Encoder = .init(gpa, &out);

    // Five bits of 10101. A sign-and-magnitude reader would call that -5;
    // it is -11, because the top bit is a sign that the rest extends.
    try e.literal(0b10101, 5);
    try e.literal(0b00101, 5);
    try e.finish();

    var d = try Decoder.init(out.items);
    try testing.expectEqual(@as(i32, -11), d.signedLiteral(5));
    try testing.expectEqual(@as(i32, 5), d.signedLiteral(5));
    try testing.expectEqual(@as(i32, 0), d.signedLiteral(0));
}

test "a seven-bit probability of zero means one" {
    const gpa = testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var e: Encoder = .init(gpa, &out);

    try e.literal(0, 7);
    try e.literal(100, 7);
    try e.literal(127, 7);
    try e.finish();

    var d = try Decoder.init(out.items);
    // Zero would say a bool can never be zero, which the coder cannot mean.
    try testing.expectEqual(@as(Prob, 1), d.prob7());
    try testing.expectEqual(@as(Prob, 200), d.prob7());
    try testing.expectEqual(@as(Prob, 254), d.prob7());
}

test "an optional signed value is a flag, a magnitude and a sign" {
    const gpa = testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var e: Encoder = .init(gpa, &out);

    try e.bool_(even, 0); // absent
    try e.bool_(even, 1); // present
    try e.literal(9, 6);
    try e.bool_(even, 1); // negative
    try e.finish();

    var d = try Decoder.init(out.items);
    try testing.expectEqual(@as(i32, 0), d.optionalSigned(6));
    try testing.expectEqual(@as(i32, -9), d.optionalSigned(6));
}

/// The specification's own example trees, from Section 8.2: the intra
/// prediction modes.
///
/// `DC_PRED` is 0, `V_PRED` 1, `H_PRED` 2, `TM_PRED` 3 and `B_PRED` 4. The
/// luma tree codes all five and the chroma tree the first four, which is why
/// they are different shapes — and both are here because a tree with an odd
/// number of interior nodes and one with an even number exercise the
/// index arithmetic differently.
const ymode_tree = [_]i8{
    0, 2, // DC_PRED, or the "1" subtree
    4, 6, // two more subtrees
    -1, -2, // V_PRED, H_PRED
    -3, -4, // TM_PRED, B_PRED
};

const uv_mode_tree = [_]i8{
    0, 2, // DC_PRED, or the "1" subtree
    -1, 4, // V_PRED, or deeper
    -2, -3, // H_PRED, TM_PRED
};

test "a tree-coded value is a walk to a leaf" {
    const gpa = testing.allocator;

    // Every leaf of both trees, written by walking the same tree the other
    // way. The probabilities are deliberately not even: a coder that ignored
    // them would have to get every bit right by luck.
    for ([_]struct { Tree, []const Prob, u8 }{
        .{ &ymode_tree, &.{ 200, 100, 40, 250 }, 5 },
        .{ &uv_mode_tree, &.{ 30, 180, 90 }, 4 },
    }) |case| {
        for (0..case[2]) |value| {
            const want: u8 = @intCast(value);
            var out: std.ArrayList(u8) = .empty;
            defer out.deinit(gpa);
            var e: Encoder = .init(gpa, &out);
            try writeTree(&e, case[0], case[1], want);
            try e.finish();

            var d = try Decoder.init(out.items);
            try testing.expectEqual(want, d.tree(case[0], case[1]));
        }
    }
}

test "a tree may be entered part way down" {
    const gpa = testing.allocator;
    const probs = [_]Prob{ 200, 100, 40, 250 };
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var e: Encoder = .init(gpa, &out);

    // Starting at index 2 skips the root's branch, so only the bools below
    // it are written --- which is what the coefficient decoder does when it
    // already knows the token is not zero.
    try e.bool_(probs[1], 0);
    try e.bool_(probs[2], 1);
    try e.finish();

    var d = try Decoder.init(out.items);
    try testing.expectEqual(@as(u8, 2), d.treeFrom(&ymode_tree, &probs, 2));
}

test "a partition that runs out is read as zeroes and says so" {
    const gpa = testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var e: Encoder = .init(gpa, &out);
    try e.literal(0xff, 8);
    try e.finish();

    // Far more bools than were written. The decode does not fail and does
    // not loop; it runs out of file and says so afterwards.
    var d = try Decoder.init(out.items);
    for (0..1000) |_| _ = d.bool_(even);
    try testing.expect(d.exhausted);
}

test "a partition of fewer than two bytes is not one" {
    try testing.expectError(error.Truncated, Decoder.init(&.{}));
    try testing.expectError(error.Truncated, Decoder.init(&.{0x42}));
}

/// Writes a tree-coded value, for the tests above. The encoder proper will
/// want this too when there is one.
fn writeTree(e: *Encoder, t: Tree, probs: []const Prob, value: u8) Allocator.Error!void {
    var path: [16]Step = undefined;
    const depth = findLeaf(t, probs, 0, -@as(i8, @intCast(value)), &path, 0).?;
    for (path[0..depth]) |step| try e.bool_(step.prob, step.bit);
}

const Step = struct { prob: Prob, bit: u1 };

/// The branches from the root down to a leaf, in the order a decoder reads
/// them.
///
/// A search rather than a lookup because the representation has no parent
/// links --- and it does not need them, since the largest tree VP8 has is
/// twenty-three positions.
fn findLeaf(t: Tree, probs: []const Prob, node: usize, target: i8, path: *[16]Step, depth: usize) ?usize {
    for ([_]u1{ 0, 1 }) |branch| {
        const entry = t[node + branch];
        path[depth] = .{ .prob = probs[node >> 1], .bit = branch };
        // A non-positive entry is a leaf; index zero is the root and so
        // never appears as a child, which is what lets zero mean a value.
        if (entry == target) return depth + 1;
        if (entry > 0) {
            if (findLeaf(t, probs, @intCast(entry), target, path, depth + 1)) |n| return n;
        }
    }
    return null;
}
