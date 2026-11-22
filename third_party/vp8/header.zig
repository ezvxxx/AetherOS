// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! The first partition's header: everything a frame says about itself before
//! it says anything about a pixel.
//!
//! It is long, flat, and almost entirely a transcription of Annex A of RFC
//! 6386 — which is why it is worth having in one file with the specification
//! open beside it, and why almost every field here is named after the field
//! in that table.
//!
//! What it carries, in the order it carries it: the colour space and whether
//! reconstructed values need clamping; the segmentation map and the
//! per-segment quantiser and filter adjustments; the loop filter's type,
//! level and sharpness, and its per-reference and per-mode adjustments; how
//! many token partitions the coefficients are split across; the five
//! quantiser indices; and then a thousand and fifty-six flags saying which
//! coefficient probabilities this frame replaces.
//!
//! ## Two things Annex A understates
//!
//! **The coefficient update flags are not `L(1)`.** Annex A writes them that
//! way; Section 13.4 is the normative version and reads each one at its own
//! probability out of `coeff.update_probs`. Most probabilities are almost
//! never touched, so the flag for one costs a fraction of a bit rather than
//! a whole one — and a decoder that read them at even odds would consume the
//! wrong number of bits and desynchronise before the first macroblock.
//!
//! **A key frame resets the probabilities before reading its own updates.**
//! The defaults go in first and the header then modifies them, so a frame
//! that updates nothing still gets the defaults rather than whatever the
//! previous frame left behind.
//!
//! ## Only key frames
//!
//! An interframe's header carries reference-frame handling, sign biases and
//! motion-vector probabilities, none of which a still image has. This reads
//! the key-frame form and nothing else, because a still WebP is one key
//! frame and there is no second frame for any of that to refer to.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const boolean = @import("bool.zig");
const coeff = @import("coeff.zig");
const Prob = boolean.Prob;

pub const Error = error{
    /// The header ran off the end of the first partition, which means the
    /// bits read were not the bits written.
    Truncated,
};

/// How many segments a frame may divide its macroblocks into.
pub const segments = 4;

/// The per-segment adjustments.
///
/// A frame may split its macroblocks into four segments and give each its
/// own quantiser and loop filter strength — which is how an encoder spends
/// more bits on a face than on the wall behind it.
pub const Segmentation = struct {
    enabled: bool = false,
    /// Whether this frame re-codes which segment each macroblock is in.
    update_map: bool = false,
    /// Whether the values below replace the segment's setting or adjust it.
    absolute: bool = false,
    quantizer: [segments]i8 = @splat(0),
    loop_filter: [segments]i8 = @splat(0),
    /// The tree that codes a macroblock's segment. 255 where the frame did
    /// not say, which makes that branch free.
    tree_probs: [3]Prob = @splat(255),
};

/// Everything about the deblocking filter except the filtering.
pub const LoopFilter = struct {
    /// The simple filter, rather than the normal one. A different filter,
    /// not a faster one: they produce different pixels.
    simple: bool = false,
    level: u8 = 0,
    sharpness: u8 = 0,
    /// Whether the two delta arrays below apply.
    delta_enabled: bool = false,
    /// By reference frame, and by prediction mode. A still key frame uses
    /// only the first of each, but they are read either way because the
    /// bits are there.
    ref_delta: [4]i8 = @splat(0),
    mode_delta: [4]i8 = @splat(0),
};

/// The five dequantisation indices, as an index and four deltas.
///
/// Four of the five are deltas from the first because they are nearly always
/// close to it: an encoder that wanted them equal spends five bits saying so
/// rather than thirty-five.
pub const Quant = struct {
    y_ac: u8 = 0,
    y_dc_delta: i8 = 0,
    y2_dc_delta: i8 = 0,
    y2_ac_delta: i8 = 0,
    uv_dc_delta: i8 = 0,
    uv_ac_delta: i8 = 0,
};

pub const Header = struct {
    /// Zero is the only colour space defined. One is reserved, and a decoder
    /// meeting it has nothing it can do but say so.
    colour_space: u1 = 0,
    /// Whether the decoder must clamp reconstructed values, or whether the
    /// encoder has promised they will not need it.
    clamping_required: bool = true,
    segmentation: Segmentation = .{},
    loop_filter: LoopFilter = .{},
    /// One, two, four or eight.
    partitions: u8 = 1,
    quant: Quant = .{},
    /// Whether the probability updates in this frame outlive it. Meaningless
    /// for a still image, and read because the bit is there.
    refresh_entropy: bool = true,
    /// The token probabilities, after this frame's updates.
    coeff_probs: coeff.Probs = coeff.default_probs,
    /// Whether macroblocks may be flagged as having no coefficients at all.
    skip_enabled: bool = false,
    prob_skip_false: Prob = 0,
};

/// Reads a key frame's header out of the first partition.
///
/// `d` is left positioned at the per-macroblock prediction records, which
/// are the rest of the first partition.
pub fn readKeyFrame(d: *boolean.Decoder) Error!Header {
    var h: Header = .{};

    h.colour_space = @intCast(d.literal(1));
    // The flag says clamping is *not* required, so it reads inverted.
    h.clamping_required = d.literal(1) == 0;

    h.segmentation.enabled = d.literal(1) == 1;
    if (h.segmentation.enabled) readSegmentation(d, &h.segmentation);

    h.loop_filter.simple = d.literal(1) == 1;
    h.loop_filter.level = @intCast(d.literal(6));
    h.loop_filter.sharpness = @intCast(d.literal(3));
    readFilterDeltas(d, &h.loop_filter);

    h.partitions = @as(u8, 1) << @intCast(d.literal(2));

    readQuant(d, &h.quant);

    h.refresh_entropy = d.literal(1) == 1;

    // A key frame starts from the defaults and then applies its own updates,
    // so a frame that updates nothing still gets the defaults.
    h.coeff_probs = coeff.default_probs;
    readCoeffUpdates(d, &h.coeff_probs);

    h.skip_enabled = d.literal(1) == 1;
    if (h.skip_enabled) h.prob_skip_false = @intCast(d.literal(8));

    // Everything above was read out of a partition of known length. Having
    // run past the end of it means the bits read were not the bits written,
    // and nothing decoded from here would mean anything.
    if (d.exhausted) return error.Truncated;
    return h;
}

fn readSegmentation(d: *boolean.Decoder, s: *Segmentation) void {
    s.update_map = d.literal(1) == 1;
    const update_data = d.literal(1) == 1;

    if (update_data) {
        s.absolute = d.literal(1) == 1;
        for (&s.quantizer) |*q| q.* = @intCast(d.optionalSigned(7));
        for (&s.loop_filter) |*f| f.* = @intCast(d.optionalSigned(6));
    }

    if (s.update_map) {
        for (&s.tree_probs) |*p| {
            // Absent means 255, which costs that branch nothing.
            p.* = if (d.literal(1) == 1) @intCast(d.literal(8)) else 255;
        }
    }
}

fn readFilterDeltas(d: *boolean.Decoder, f: *LoopFilter) void {
    f.delta_enabled = d.literal(1) == 1;
    if (!f.delta_enabled) return;
    if (d.literal(1) == 0) return; // no update this frame
    for (&f.ref_delta) |*v| v.* = @intCast(d.optionalSigned(6));
    for (&f.mode_delta) |*v| v.* = @intCast(d.optionalSigned(6));
}

fn readQuant(d: *boolean.Decoder, q: *Quant) void {
    q.y_ac = @intCast(d.literal(7));
    q.y_dc_delta = @intCast(d.optionalSigned(4));
    q.y2_dc_delta = @intCast(d.optionalSigned(4));
    q.y2_ac_delta = @intCast(d.optionalSigned(4));
    q.uv_dc_delta = @intCast(d.optionalSigned(4));
    q.uv_ac_delta = @intCast(d.optionalSigned(4));
}

/// A thousand and fifty-six flags, each at its own probability.
fn readCoeffUpdates(d: *boolean.Decoder, probs: *coeff.Probs) void {
    for (0..coeff.planes) |i| {
        for (0..coeff.bands) |j| {
            for (0..coeff.contexts) |k| {
                for (0..coeff.branches) |t| {
                    if (d.bool_(coeff.update_probs[i][j][k][t]) == 1) {
                        probs[i][j][k][t] = @intCast(d.literal(8));
                    }
                }
            }
        }
    }
}

/// Where each token partition begins and ends, within the data that follows
/// the first partition.
///
/// The sizes of all but the last are written as three bytes each, in front
/// of the partitions themselves; the last one is whatever is left. So the
/// table is `3 * (n - 1)` bytes and then the data.
pub fn partitionSlices(
    rest: []const u8,
    count: u8,
    out: *[8][]const u8,
) error{Truncated}!void {
    std.debug.assert(count == 1 or count == 2 or count == 4 or count == 8);
    const table = 3 * (@as(usize, count) - 1);
    if (rest.len < table) return error.Truncated;

    var at = table;
    for (0..count - 1) |i| {
        const size = @as(usize, rest[i * 3]) |
            (@as(usize, rest[i * 3 + 1]) << 8) |
            (@as(usize, rest[i * 3 + 2]) << 16);
        if (rest.len - at < size) return error.Truncated;
        out[i] = rest[at..][0..size];
        at += size;
    }
    out[count - 1] = rest[at..];
}

// -- tests -------------------------------------------------------------------

/// Writes a key frame header, so that reading one can be checked against
/// something. The same argument as the boolean encoder next door: until the
/// rest of the decoder exists there is no file here that can be read, and a
/// parser checked only against itself is checked against nothing.
fn writeKeyFrame(e: *boolean.Encoder, h: Header) Allocator.Error!void {
    try e.literal(h.colour_space, 1);
    try e.literal(@intFromBool(!h.clamping_required), 1);

    try e.literal(@intFromBool(h.segmentation.enabled), 1);
    if (h.segmentation.enabled) {
        try e.literal(@intFromBool(h.segmentation.update_map), 1);
        try e.literal(1, 1); // always write the feature data
        try e.literal(@intFromBool(h.segmentation.absolute), 1);
        for (h.segmentation.quantizer) |q| try writeOptionalSigned(e, q, 7);
        for (h.segmentation.loop_filter) |f| try writeOptionalSigned(e, f, 6);
        if (h.segmentation.update_map) {
            for (h.segmentation.tree_probs) |p| {
                if (p == 255) {
                    try e.literal(0, 1);
                } else {
                    try e.literal(1, 1);
                    try e.literal(p, 8);
                }
            }
        }
    }

    try e.literal(@intFromBool(h.loop_filter.simple), 1);
    try e.literal(h.loop_filter.level, 6);
    try e.literal(h.loop_filter.sharpness, 3);
    try e.literal(@intFromBool(h.loop_filter.delta_enabled), 1);
    if (h.loop_filter.delta_enabled) {
        try e.literal(1, 1); // always write the deltas
        for (h.loop_filter.ref_delta) |v| try writeOptionalSigned(e, v, 6);
        for (h.loop_filter.mode_delta) |v| try writeOptionalSigned(e, v, 6);
    }

    try e.literal(@ctz(h.partitions), 2);

    try e.literal(h.quant.y_ac, 7);
    for ([_]i8{
        h.quant.y_dc_delta,  h.quant.y2_dc_delta, h.quant.y2_ac_delta,
        h.quant.uv_dc_delta, h.quant.uv_ac_delta,
    }) |v| try writeOptionalSigned(e, v, 4);

    try e.literal(@intFromBool(h.refresh_entropy), 1);

    for (0..coeff.planes) |i| {
        for (0..coeff.bands) |j| {
            for (0..coeff.contexts) |k| {
                for (0..coeff.branches) |t| {
                    const want = h.coeff_probs[i][j][k][t];
                    const have = coeff.default_probs[i][j][k][t];
                    if (want == have) {
                        try e.bool_(coeff.update_probs[i][j][k][t], 0);
                    } else {
                        try e.bool_(coeff.update_probs[i][j][k][t], 1);
                        try e.literal(want, 8);
                    }
                }
            }
        }
    }

    try e.literal(@intFromBool(h.skip_enabled), 1);
    if (h.skip_enabled) try e.literal(h.prob_skip_false, 8);
}

fn writeOptionalSigned(e: *boolean.Encoder, value: i8, bits: u6) Allocator.Error!void {
    if (value == 0) {
        try e.literal(0, 1);
        return;
    }
    try e.literal(1, 1);
    const magnitude: u32 = @intCast(@abs(value));
    try e.literal(magnitude, bits);
    try e.literal(@intFromBool(value < 0), 1);
}

fn roundTrip(gpa: Allocator, h: Header) !Header {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var e: boolean.Encoder = .init(gpa, &out);
    try writeKeyFrame(&e, h);
    try e.finish();

    var d = try boolean.Decoder.init(out.items);
    return readKeyFrame(&d);
}

test "the plainest header there is" {
    const gpa = testing.allocator;
    const back = try roundTrip(gpa, .{});

    try testing.expectEqual(@as(u1, 0), back.colour_space);
    try testing.expect(back.clamping_required);
    try testing.expect(!back.segmentation.enabled);
    try testing.expectEqual(@as(u8, 1), back.partitions);
    try testing.expectEqual(@as(u8, 0), back.quant.y_ac);
    try testing.expect(!back.skip_enabled);
    // Nothing updated, so every probability is still its default.
    try testing.expectEqualDeep(coeff.default_probs, back.coeff_probs);
}

test "every field comes back the way it went in" {
    const gpa = testing.allocator;
    var want: Header = .{
        .colour_space = 0,
        .clamping_required = false,
        .segmentation = .{
            .enabled = true,
            .update_map = true,
            .absolute = true,
            .quantizer = .{ 20, -30, 0, 127 },
            .loop_filter = .{ -1, 63, 0, -63 },
            .tree_probs = .{ 10, 255, 200 },
        },
        .loop_filter = .{
            .simple = true,
            .level = 63,
            .sharpness = 7,
            .delta_enabled = true,
            .ref_delta = .{ 1, -2, 63, -63 },
            .mode_delta = .{ 0, 4, -4, 0 },
        },
        .partitions = 8,
        .quant = .{
            .y_ac = 127,
            .y_dc_delta = 15,
            .y2_dc_delta = -15,
            .y2_ac_delta = 0,
            .uv_dc_delta = 7,
            .uv_ac_delta = -1,
        },
        .refresh_entropy = false,
        .skip_enabled = true,
        .prob_skip_false = 42,
    };
    // A scattering of probability updates, including at both ends of each
    // dimension, so an index the wrong way round shows up.
    want.coeff_probs[0][0][0][0] = 1;
    want.coeff_probs[3][7][2][10] = 254;
    want.coeff_probs[1][3][1][5] = 99;
    want.coeff_probs[2][0][2][0] = 200;

    const back = try roundTrip(gpa, want);
    try testing.expectEqualDeep(want, back);
}

test "the partition count is a power of two written as its logarithm" {
    const gpa = testing.allocator;
    for ([_]u8{ 1, 2, 4, 8 }) |count| {
        const back = try roundTrip(gpa, .{ .partitions = count });
        try testing.expectEqual(count, back.partitions);
    }
}

test "a header cut short says so rather than inventing the rest" {
    const gpa = testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var e: boolean.Encoder = .init(gpa, &out);
    try writeKeyFrame(&e, .{});
    try e.finish();

    // Every prefix of a real header. None of them may come back as a header.
    var len: usize = 2;
    while (len < out.items.len - 1) : (len += 1) {
        var d = try boolean.Decoder.init(out.items[0..len]);
        try testing.expectError(error.Truncated, readKeyFrame(&d));
    }
}

test "partitions are sliced out of what follows the first" {
    var out: [8][]const u8 = undefined;

    // One partition: no size table, and the whole remainder is it.
    try partitionSlices("abcdef", 1, &out);
    try testing.expectEqualStrings("abcdef", out[0]);

    // Two: three bytes of size, then that many, then the rest.
    try partitionSlices("\x02\x00\x00" ++ "AB" ++ "CDE", 2, &out);
    try testing.expectEqualStrings("AB", out[0]);
    try testing.expectEqualStrings("CDE", out[1]);

    // Four, with the last taking whatever is left.
    try partitionSlices(
        "\x01\x00\x00\x02\x00\x00\x03\x00\x00" ++ "a" ++ "bb" ++ "ccc" ++ "dddd",
        4,
        &out,
    );
    try testing.expectEqualStrings("a", out[0]);
    try testing.expectEqualStrings("bb", out[1]);
    try testing.expectEqualStrings("ccc", out[2]);
    try testing.expectEqualStrings("dddd", out[3]);
}

test "a partition table that promises more than there is, is refused" {
    var out: [8][]const u8 = undefined;
    // The table itself does not fit.
    try testing.expectError(error.Truncated, partitionSlices("ab", 2, &out));
    // The table fits and the partition it describes does not.
    try testing.expectError(
        error.Truncated,
        partitionSlices("\xff\xff\x00" ++ "short", 2, &out),
    );
}

// -- against libwebp ---------------------------------------------------------

const fixtures = @import("fixtures.zig");
const root = @import("root.zig");

/// Reads a whole `VP8 ` chunk: the ten-byte frame tag and then the header
/// out of the first partition.
fn parseChunk(chunk: []const u8) !struct { root.FrameHeader, Header } {
    const tag = try root.readFrameHeader(chunk[0..root.FrameHeader.len]);
    const first = chunk[root.FrameHeader.len..];
    if (first.len < tag.first_partition_len) return error.Truncated;
    var d = try boolean.Decoder.init(first[0..tag.first_partition_len]);
    return .{ tag, try readKeyFrame(&d) };
}

test "the sharpness libwebp was told to use is the sharpness that comes back" {
    // The one field of this header that `cwebp` puts on its command line
    // and writes through unaltered, which makes it the sharpest external
    // check available before there is a decoder to compare pixels with. A
    // bit layout adrift by one would not read three as three.
    for ([_]struct { []const u8, u8 }{
        .{ &fixtures.sharpness_0, 0 },
        .{ &fixtures.sharpness_3, 3 },
        .{ &fixtures.sharpness_7, 7 },
    }) |case| {
        const parsed = try parseChunk(case[0]);
        try testing.expectEqual(@as(u16, fixtures.width), parsed[0].width);
        try testing.expectEqual(@as(u16, fixtures.height), parsed[0].height);
        try testing.expectEqual(case[1], parsed[1].loop_filter.sharpness);
    }
}

test "segmentation is on exactly when libwebp was asked for segments" {
    const one = try parseChunk(&fixtures.segments_1);
    try testing.expect(!one[1].segmentation.enabled);

    const four = try parseChunk(&fixtures.segments_4);
    try testing.expect(four[1].segmentation.enabled);
    // Asked for four segments, so the map is coded and its tree is given.
    try testing.expect(four[1].segmentation.update_map);
}

test "the quantiser index falls as the quality rises" {
    // Nothing else in the header moves with quality, so a parse that reads
    // this field correctly reads these in descending order --- and one that
    // read the wrong seven bits would not.
    var previous: u8 = 255;
    for ([_][]const u8{
        &fixtures.quality_0,
        &fixtures.quality_25,
        &fixtures.quality_50,
        &fixtures.quality_75,
        &fixtures.quality_100,
    }) |bytes| {
        const parsed = try parseChunk(bytes);
        try testing.expect(parsed[1].quant.y_ac <= previous);
        previous = parsed[1].quant.y_ac;
    }
    // And the two ends are genuinely far apart, so the ordering above is not
    // five readings of the same number.
    const worst = try parseChunk(&fixtures.quality_0);
    const best = try parseChunk(&fixtures.quality_100);
    try testing.expect(worst[1].quant.y_ac > best[1].quant.y_ac + 20);
}

test "a real header ends inside the partition that holds it" {
    // The header is followed by the per-macroblock records, in the same
    // partition and the same bool stream. Running out while reading the
    // header would mean the bits read were not the bits written; leaving
    // nothing behind would mean the same.
    for ([_][]const u8{
        &fixtures.sharpness_0, &fixtures.segments_4,
        &fixtures.quality_0,   &fixtures.quality_100,
    }) |bytes| {
        const tag = try root.readFrameHeader(bytes[0..root.FrameHeader.len]);
        const first = bytes[root.FrameHeader.len..][0..tag.first_partition_len];
        var d = try boolean.Decoder.init(first);
        _ = try readKeyFrame(&d);
        try testing.expect(!d.exhausted);
        try testing.expect(d.at < first.len);
    }
}

test "the token partitions of a real frame add up" {
    const bytes = &fixtures.quality_75;
    const tag = try root.readFrameHeader(bytes[0..root.FrameHeader.len]);
    const first = bytes[root.FrameHeader.len..][0..tag.first_partition_len];
    var d = try boolean.Decoder.init(first);
    const h = try readKeyFrame(&d);

    const rest = bytes[root.FrameHeader.len + tag.first_partition_len ..];
    var slices: [8][]const u8 = undefined;
    try partitionSlices(rest, h.partitions, &slices);

    var total: usize = 3 * (@as(usize, h.partitions) - 1);
    for (slices[0..h.partitions]) |p| total += p.len;
    try testing.expectEqual(rest.len, total);
    // And each one has enough in it to start a bool decoder, which is two
    // bytes --- a partition of one byte is not a short partition but a
    // broken file.
    for (slices[0..h.partitions]) |p| try testing.expect(p.len >= 2);
}
