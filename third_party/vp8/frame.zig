// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Decoding a key frame into three planes of samples.
//!
//! This is where the other files meet. Each macroblock's modes come out of
//! the first partition, its coefficients out of a token partition, and then
//! it is predicted from its neighbours, has its residue added back, and is
//! written into the frame — after which the macroblock to its right and the
//! one below predict from it.
//!
//! ## The shape of a macroblock
//!
//! Sixteen by sixteen of luma, and eight by eight each of two chroma planes
//! at half resolution in both directions. The luma is carried as sixteen
//! 4×4 blocks and the chroma as four each.
//!
//! When the luma is predicted whole, the sixteen luma blocks' DC
//! coefficients are pulled out into a seventeenth block — **Y2** — and sent
//! through a Walsh-Hadamard transform instead. So such a macroblock codes
//! twenty-five blocks and a `b_pred` one codes twenty-four.
//!
//! ## What the borders are for
//!
//! The planes are allocated with a one-pixel border above and to the left,
//! and four extra columns to the right of the top border. That is not
//! padding for alignment: it is where the invented neighbours live, so that
//! prediction can read them the same way it reads real ones.
//!
//! - The top border row is **127**, all of it, including the four extra
//!   columns and the corner.
//! - The left border column is **129**, which is a different value on
//!   purpose.
//! - After each macroblock row, the four extra columns of its last row are
//!   filled with that row's rightmost pixel, because that is what the
//!   specification says the subblocks on the frame's right edge shall use
//!   for the pixels above and to their right.
//!
//! ## Prediction reads unfiltered pixels
//!
//! The loop filter runs over the frame afterwards and does not feed back
//! into prediction within the frame. That is what makes this file testable
//! on its own: `dwebp -nofilter` produces exactly what this produces, and
//! the comparison is bit for bit rather than within a tolerance.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const boolean = @import("bool.zig");
const filter = @import("filter.zig");
const header = @import("header.zig");
const modes = @import("modes.zig");
const predict = @import("predict.zig");
const tokens = @import("tokens.zig");
const transform = @import("transform.zig");

pub const Error = error{
    /// A partition that is not there, or is too short to start reading.
    Truncated,
    /// A frame this library cannot decode: an interframe, or a colour space
    /// the format reserves and does not define.
    Unsupported,
    /// Something that contradicts itself.
    InvalidData,
} || Allocator.Error;

/// A decoded frame, as three planes of samples.
///
/// The buffers include the prediction borders, so a row of the picture is
/// not the start of a row of the buffer: `y[y_origin + r * y_stride ..]` is
/// row `r`.
pub const Frame = struct {
    y: []u8,
    u: []u8,
    v: []u8,
    y_stride: usize,
    uv_stride: usize,
    y_origin: usize,
    uv_origin: usize,
    /// The picture's size, which is what the container declared and may be
    /// less than the macroblocks cover.
    width: u32,
    height: u32,

    pub fn deinit(self: *Frame, gpa: Allocator) void {
        gpa.free(self.y);
        gpa.free(self.u);
        gpa.free(self.v);
        self.* = undefined;
    }

    /// One row of luma, cropped to the picture.
    pub fn luma(self: *const Frame, row: usize) []const u8 {
        return self.y[self.y_origin + row * self.y_stride ..][0..self.width];
    }

    pub fn chromaU(self: *const Frame, row: usize) []const u8 {
        return self.u[self.uv_origin + row * self.uv_stride ..][0..self.chromaWidth()];
    }

    pub fn chromaV(self: *const Frame, row: usize) []const u8 {
        return self.v[self.uv_origin + row * self.uv_stride ..][0..self.chromaWidth()];
    }

    pub fn chromaWidth(self: *const Frame) u32 {
        return (self.width + 1) / 2;
    }

    pub fn chromaHeight(self: *const Frame) u32 {
        return (self.height + 1) / 2;
    }
};

/// What one macroblock's header said.
const Macroblock = struct {
    segment: u8 = 0,
    skip: bool = false,
    luma: predict.WholeMode = .dc,
    /// True when the luma is predicted as sixteen subblocks rather than
    /// whole, which is also what decides whether there is a Y2 block.
    split: bool = false,
    sub: [16]predict.SubMode = @splat(.dc),
    chroma: predict.WholeMode = .dc,
};

/// How to decode.
pub const Options = struct {
    /// Whether to run the loop filter.
    ///
    /// Turning it off is not an optimisation, it is a different picture:
    /// the seams between blocks stay as the transform left them. It is here
    /// because it is testable — `dwebp -nofilter` produces exactly this —
    /// and because a caller that is about to scale a frame down may not
    /// care about its seams.
    loop_filter: bool = true,
};

/// Decodes a key frame.
///
/// `first` is the first partition, already past the ten-byte frame tag;
/// `parts` are the token partitions.
pub fn decode(
    gpa: Allocator,
    width: u32,
    height: u32,
    h: *const header.Header,
    first: *boolean.Decoder,
    parts: []const []const u8,
    opts: Options,
) Error!Frame {
    // One is the only colour space the format defines. A frame declaring the
    // other has not said what its samples mean.
    if (h.colour_space != 0) return error.Unsupported;

    const mb_w = (width + 15) / 16;
    const mb_h = (height + 15) / 16;

    // A border of one above and to the left, and four spare columns on the
    // right so that the pixels above and to the right of the last subblock
    // in a row have somewhere to be.
    const y_stride: usize = @as(usize, mb_w) * 16 + 1 + 4;
    const uv_stride: usize = @as(usize, mb_w) * 8 + 1;
    const y_rows: usize = @as(usize, mb_h) * 16 + 1;
    const uv_rows: usize = @as(usize, mb_h) * 8 + 1;

    var frame: Frame = .{
        .y = try gpa.alloc(u8, y_stride * y_rows),
        .u = undefined,
        .v = undefined,
        .y_stride = y_stride,
        .uv_stride = uv_stride,
        .y_origin = y_stride + 1,
        .uv_origin = uv_stride + 1,
        .width = width,
        .height = height,
    };
    errdefer gpa.free(frame.y);
    frame.u = try gpa.alloc(u8, uv_stride * uv_rows);
    errdefer gpa.free(frame.u);
    frame.v = try gpa.alloc(u8, uv_stride * uv_rows);
    errdefer gpa.free(frame.v);

    // The invented neighbours, written once: 127 along the top and 129 down
    // the left. Two different values, which the specification states and
    // `predict` explains.
    @memset(frame.y, 0);
    @memset(frame.u, 0);
    @memset(frame.v, 0);
    @memset(frame.y[0..y_stride], predict.absent_above);
    @memset(frame.u[0..uv_stride], predict.absent_above);
    @memset(frame.v[0..uv_stride], predict.absent_above);
    for (1..y_rows) |r| frame.y[r * y_stride] = predict.absent_left;
    for (1..uv_rows) |r| {
        frame.u[r * uv_stride] = predict.absent_left;
        frame.v[r * uv_stride] = predict.absent_left;
    }

    // Which segment's dequantisation factors each macroblock uses. Worked
    // out once rather than per macroblock.
    var factors: [header.segments]transform.Factors = undefined;
    for (&factors, 0..) |*f, i| {
        f.* = .init(h, if (h.segmentation.enabled) i else null);
    }

    // The per-subblock modes of the macroblock row above, and of the one to
    // the left, for the contextual coding of subblock modes.
    const above_modes = try gpa.alloc(predict.SubMode, @as(usize, mb_w) * 4);
    defer gpa.free(above_modes);
    @memset(above_modes, .dc);
    var left_modes: [4]predict.SubMode = @splat(.dc);

    // Whether each block had any coefficients, which is the context the next
    // block's tokens are read with. Four luma, two each of chroma, one Y2.
    const above_nz = try gpa.alloc(u8, @as(usize, mb_w) * 9);
    defer gpa.free(above_nz);
    @memset(above_nz, 0);
    var left_nz: [9]u8 = @splat(0);

    var coeffs: [25]tokens.Block = undefined;

    const strengths = try gpa.alloc(filter.Strength, @as(usize, mb_w) * mb_h);
    defer gpa.free(strengths);

    // One decoder per token partition, kept for the whole frame. The
    // partitions are dealt out by macroblock row --- row `i` uses partition
    // `i mod n`, which is what lets a decoder run several rows at once ---
    // and each one continues where the previous row using it left off. A
    // decoder made afresh per macroblock would re-read the same coefficients
    // over and over, which decodes the first macroblock of the frame
    // correctly and nothing after it.
    if (parts.len == 0) return error.Truncated;
    var token_readers: [8]boolean.Decoder = undefined;
    for (parts, 0..) |p, i| {
        token_readers[i] = boolean.Decoder.init(p) catch return error.Truncated;
    }

    var mb_y: u32 = 0;
    while (mb_y < mb_h) : (mb_y += 1) {
        left_nz = @splat(0);
        left_modes = @splat(.dc);

        var mb_x: u32 = 0;
        while (mb_x < mb_w) : (mb_x += 1) {
            const mb = readMacroblock(first, h, above_modes[mb_x * 4 ..][0..4], &left_modes);

            const part = &token_readers[mb_y % parts.len];

            @memset(std.mem.asBytes(&coeffs), 0);
            var has_coeffs = false;
            if (!mb.skip) {
                has_coeffs = readResidue(part, h, mb, above_nz[mb_x * 9 ..][0..9], &left_nz, &coeffs);
            } else {
                @memset(above_nz[mb_x * 9 ..][0..9], 0);
                left_nz = @splat(0);
                // A `b_pred` macroblock has no Y2 block, so its Y2 context is
                // not something a skip can clear --- there is nothing there
                // to clear.
                if (mb.split) {
                    above_nz[mb_x * 9 + 8] = 0;
                    left_nz[8] = 0;
                }
            }

            const f = factors[if (h.segmentation.enabled) mb.segment else 0];
            reconstruct(&frame, mb_x, mb_y, mb, f, &coeffs);

            // Kept for the filtering pass, which cannot run until the whole
            // frame is reconstructed: a macroblock's own strength depends on
            // its segment and on whether it coded anything, and both are
            // gone by then.
            strengths[@as(usize, mb_y) * mb_w + mb_x] =
                filter.strengthFor(h, mb.segment, mb.split, has_coeffs);
        }

        // The four spare columns at the end of this row of macroblocks take
        // the rightmost real pixel, because that is what the subblocks on the
        // frame's right edge use for the pixels above and to their right.
        const last_row = frame.y_origin + (@as(usize, mb_y) * 16 + 15) * y_stride;
        const rightmost = frame.y[last_row + @as(usize, mb_w) * 16 - 1];
        @memset(frame.y[last_row + @as(usize, mb_w) * 16 ..][0..4], rightmost);
    }

    // The loop filter runs over the finished frame, in the same raster
    // order, each macroblock filtering the edges above and to the left of
    // it against pixels its neighbours have already had filtered. It could
    // not have run sooner: prediction reads *unfiltered* neighbours, so
    // filtering as we went would have fed the wrong pixels into every
    // macroblock after the first.
    if (!opts.loop_filter) return frame;

    const kind: filter.Kind = if (h.loop_filter.simple) .simple else .normal;
    const y_plane: filter.Plane = .{ .data = frame.y, .stride = y_stride, .origin = frame.y_origin };
    const u_plane: filter.Plane = .{ .data = frame.u, .stride = uv_stride, .origin = frame.uv_origin };
    const v_plane: filter.Plane = .{ .data = frame.v, .stride = uv_stride, .origin = frame.uv_origin };
    for (0..mb_h) |fy| {
        for (0..mb_w) |fx| {
            filter.macroblock(
                kind,
                y_plane,
                u_plane,
                v_plane,
                @intCast(fx),
                @intCast(fy),
                strengths[fy * mb_w + fx],
            );
        }
    }

    return frame;
}

/// Reads one macroblock's prediction modes.
fn readMacroblock(
    d: *boolean.Decoder,
    h: *const header.Header,
    above: *[4]predict.SubMode,
    left: *[4]predict.SubMode,
) Macroblock {
    var mb: Macroblock = .{};

    if (h.segmentation.enabled and h.segmentation.update_map) {
        mb.segment = d.tree(&modes.segment_tree, &h.segmentation.tree_probs);
    }
    if (h.skip_enabled) mb.skip = d.bool_(h.prob_skip_false) == 1;

    const luma = d.tree(&modes.kf_ymode_tree, &modes.kf_ymode_probs);
    // Four is `b_pred`, which is not a mode but an instruction to code
    // sixteen of them.
    mb.split = luma == 4;

    if (mb.split) {
        for (0..4) |by| {
            for (0..4) |bx| {
                // The neighbours may be in another macroblock: to the left of
                // column zero is the macroblock to the left, and above row
                // zero is the one above.
                const a = above[bx];
                const l = left[by];
                const mode: predict.SubMode = @fromBackingInt(@intCast(d.tree(
                    &modes.bmode_tree,
                    &modes.kf_bmode_probs[@backingInt(a)][@backingInt(l)],
                )));
                mb.sub[by * 4 + bx] = mode;
                above[bx] = mode;
                left[by] = mode;
            }
        }
    } else {
        mb.luma = @fromBackingInt(@intCast(luma));
        // A macroblock predicted whole still has to answer for its
        // neighbours' sake.
        const stand_in = modes.asSubMode(mb.luma);
        mb.sub = @splat(stand_in);
        above.* = @splat(stand_in);
        left.* = @splat(stand_in);
    }

    mb.chroma = @fromBackingInt(@intCast(d.tree(&modes.uv_mode_tree, &modes.kf_uv_mode_probs)));
    return mb;
}

/// Reads one macroblock's coefficients: up to twenty-five blocks.
fn readResidue(
    d: *boolean.Decoder,
    h: *const header.Header,
    mb: Macroblock,
    above: *[9]u8,
    left: *[9]u8,
    out: *[25]tokens.Block,
) bool {
    const probs = &h.coeff_probs;
    var any = false;

    // The Y2 block, when there is one, and the plane its absence changes.
    var luma_plane: tokens.Plane = .y_alone;
    if (!mb.split) {
        const ctx = above[8] + left[8];
        const last = tokens.readBlock(d, probs, .y2, ctx, &out[24]);
        const nz: u8 = @intFromBool(last > 0);
        above[8] = nz;
        left[8] = nz;
        any = any or nz != 0;
        luma_plane = .y_after_y2;
    }

    const first = luma_plane.first();
    for (0..4) |by| {
        for (0..4) |bx| {
            const ctx = above[bx] + left[by];
            const last = tokens.readBlock(d, probs, luma_plane, ctx, &out[by * 4 + bx]);
            const nz: u8 = @intFromBool(last > first);
            above[bx] = nz;
            left[by] = nz;
            any = any or nz != 0;
        }
    }

    for (0..2) |plane| {
        for (0..2) |by| {
            for (0..2) |bx| {
                const base = 4 + plane * 2;
                const ctx = above[base + bx] + left[base + by];
                const block = 16 + plane * 4 + by * 2 + bx;
                const last = tokens.readBlock(d, probs, .chroma, ctx, &out[block]);
                const nz: u8 = @intFromBool(last > 0);
                above[base + bx] = nz;
                left[base + by] = nz;
                any = any or nz != 0;
            }
        }
    }
    return any;
}

/// Predicts a macroblock, adds its residue back, and writes it into the
/// frame.
fn reconstruct(
    frame: *Frame,
    mb_x: u32,
    mb_y: u32,
    mb: Macroblock,
    f: transform.Factors,
    coeffs: *[25]tokens.Block,
) void {
    const have_above = mb_y > 0;
    const have_left = mb_x > 0;

    // The Y2 block carries what the sixteen luma blocks' DC coefficients had
    // in common, so it is inverted first and scattered back into them.
    if (!mb.split) {
        transform.dequantise(&coeffs[24], f.y2_dc, f.y2_ac);
        var dc: [16]i16 = undefined;
        transform.inverseWht(&coeffs[24], &dc);
        for (0..16) |i| coeffs[i][0] = dc[i];
    }

    const y_at = frame.y_origin + @as(usize, mb_y) * 16 * frame.y_stride + @as(usize, mb_x) * 16;

    if (mb.split) {
        // Each subblock is predicted from pixels the previous ones have just
        // written, so prediction and reconstruction interleave.
        for (0..16) |i| {
            const bx = i % 4;
            const by = i / 4;
            const at = y_at + by * 4 * frame.y_stride + bx * 4;

            var edge: [13]u8 = undefined;
            gatherEdge(frame, y_at, i, &edge);

            var pred: [16]u8 = undefined;
            predict.subblock(mb.sub[i], &edge, &pred);

            // Only coefficient zero was ever in the Y2 block, and a split
            // macroblock has none, so every coefficient here is this
            // block's own.
            transform.dequantise(&coeffs[i], f.y_dc, f.y_ac);
            addResidue(frame.y, at, frame.y_stride, &pred, &coeffs[i], 4);
        }
    } else {
        var above: [16]u8 = undefined;
        var left: [16]u8 = undefined;
        @memcpy(&above, frame.y[offset(y_at, -1, 0, frame.y_stride)..][0..16]);
        for (0..16) |r| left[r] = frame.y[offset(y_at, @intCast(r), -1, frame.y_stride)];
        const corner = frame.y[offset(y_at, -1, -1, frame.y_stride)];

        var pred: [256]u8 = undefined;
        predict.whole(mb.luma, 16, &above, &left, corner, have_above, have_left, &pred);

        for (0..16) |i| {
            const bx = i % 4;
            const by = i / 4;
            // The DC came from the Y2 block and has already been scaled, so
            // only the AC coefficients are dequantised here.
            var block = coeffs[i];
            for (block[1..]) |*c| c.* = @bitCast(@as(u16, @bitCast(c.*)) *% f.y_ac);

            var sub_pred: [16]u8 = undefined;
            for (0..4) |r| {
                @memcpy(sub_pred[r * 4 ..][0..4], pred[(by * 4 + r) * 16 + bx * 4 ..][0..4]);
            }
            const dst = y_at + by * 4 * frame.y_stride + bx * 4;
            addResidue(frame.y, dst, frame.y_stride, &sub_pred, &block, 4);
        }
    }

    const uv_at = frame.uv_origin + @as(usize, mb_y) * 8 * frame.uv_stride + @as(usize, mb_x) * 8;
    for ([_]*[]u8{ &frame.u, &frame.v }, 0..) |plane, p| {
        var above: [8]u8 = undefined;
        var left: [8]u8 = undefined;
        @memcpy(&above, plane.*[offset(uv_at, -1, 0, frame.uv_stride)..][0..8]);
        for (0..8) |r| left[r] = plane.*[offset(uv_at, @intCast(r), -1, frame.uv_stride)];
        const corner = plane.*[offset(uv_at, -1, -1, frame.uv_stride)];

        var pred: [64]u8 = undefined;
        predict.whole(mb.chroma, 8, &above, &left, corner, have_above, have_left, &pred);

        for (0..4) |i| {
            const bx = i % 2;
            const by = i / 2;
            var block = coeffs[16 + p * 4 + i];
            transform.dequantise(&block, f.uv_dc, f.uv_ac);

            var sub_pred: [16]u8 = undefined;
            for (0..4) |r| {
                @memcpy(sub_pred[r * 4 ..][0..4], pred[(by * 4 + r) * 8 + bx * 4 ..][0..4]);
            }
            const dst = uv_at + by * 4 * frame.uv_stride + bx * 4;
            addResidue(plane.*, dst, frame.uv_stride, &sub_pred, &block, 4);
        }
    }
}

/// An offset from a pixel, in rows and columns.
fn offset(base: usize, row: i32, col: i32, stride: usize) usize {
    const signed: isize = @intCast(base);
    return @intCast(signed + @as(isize, row) * @as(isize, @intCast(stride)) + @as(isize, col));
}

/// The thirteen neighbours a subblock predicts from.
///
/// `mb` is the macroblock's top-left pixel and `i` the subblock's index in
/// raster order, both of which are needed for the last four: the pixels
/// *above and to the right*.
///
/// Those are the awkward ones. For a subblock on the macroblock's right
/// edge they have not been reconstructed yet --- macroblocks are done in
/// raster order, so the one to the right does not exist --- and the
/// specification says subblocks 3, 7, 11 and 15 shall all use the same four:
/// the ones above and to the right of subblock 3, which is to say the
/// macroblock's own row above at columns sixteen to nineteen. Reading the
/// row above the *subblock* instead is right for subblock 3 and wrong for
/// the other three, which shows up as a column of wrong pixels down the
/// right-hand edge of every macroblock and nowhere else.
fn gatherEdge(frame: *const Frame, mb: usize, i: usize, out: *[13]u8) void {
    const s = frame.y_stride;
    const bx = i % 4;
    const by = i / 4;
    const block = mb + by * 4 * s + bx * 4;

    // The left column, bottom to top, then the corner, then the row above.
    out[0] = frame.y[offset(block, 3, -1, s)];
    out[1] = frame.y[offset(block, 2, -1, s)];
    out[2] = frame.y[offset(block, 1, -1, s)];
    out[3] = frame.y[offset(block, 0, -1, s)];
    out[4] = frame.y[offset(block, -1, -1, s)];
    @memcpy(out[5..9], frame.y[offset(block, -1, 0, s)..][0..4]);

    if (bx == 3) {
        @memcpy(out[9..13], frame.y[offset(mb, -1, 16, s)..][0..4]);
    } else {
        @memcpy(out[9..13], frame.y[offset(block, -1, 4, s)..][0..4]);
    }
}

/// Adds a 4×4 residue to a prediction and stores it, clamped.
fn addResidue(
    plane: []u8,
    dst: usize,
    stride: usize,
    pred: *const [16]u8,
    block: *const tokens.Block,
    comptime size: usize,
) void {
    var residue: [16]i16 = undefined;
    transform.inverseDct(block, &residue);
    for (0..size) |r| {
        for (0..size) |c| {
            const v = @as(i32, pred[r * size + c]) + residue[r * size + c];
            plane[dst + r * stride + c] = @intCast(std.math.clamp(v, 0, 255));
        }
    }
}

// -- tests -------------------------------------------------------------------

const fixtures = @import("fixtures.zig");
const root = @import("root.zig");

/// Decodes one of the `VP8 ` chunks in `fixtures`.
fn decodeChunk(gpa: Allocator, chunk: []const u8, opts: Options) !Frame {
    const tag = try root.readFrameHeader(chunk[0..root.FrameHeader.len]);
    const body = chunk[root.FrameHeader.len..];
    if (body.len < tag.first_partition_len) return error.Truncated;

    var first = try boolean.Decoder.init(body[0..tag.first_partition_len]);
    const h = try header.readKeyFrame(&first);

    var slices: [8][]const u8 = undefined;
    try header.partitionSlices(body[tag.first_partition_len..], h.partitions, &slices);

    return decode(gpa, tag.width, tag.height, &h, &first, slices[0..h.partitions], opts);
}

test "a real frame decodes to the samples libwebp produces, filtered and not" {
    // The check this whole sequence has been building towards. `dwebp
    // -nofilter` writes the reconstruction before the loop filter touches
    // it, which is exactly what this file produces --- so the comparison is
    // bit for bit and not within a tolerance.
    //
    // Intra prediction reads unfiltered neighbours, so leaving the filter
    // out does not merely change the output at block edges: it changes
    // nothing at all about what happens here.
    const gpa = testing.allocator;

    for ([_]struct { []const u8, []const u8, bool, []const u8 }{
        .{ &fixtures.quality_0, &fixtures.quality_0_yuv, false, "quality 0, unfiltered" },
        .{ &fixtures.quality_50, &fixtures.quality_50_yuv, false, "quality 50, unfiltered" },
        .{ &fixtures.quality_100, &fixtures.quality_100_yuv, false, "quality 100, unfiltered" },
        .{ &fixtures.segments_4, &fixtures.segments_4_yuv, false, "four segments, unfiltered" },
        .{ &fixtures.sharpness_7, &fixtures.sharpness_7_yuv, false, "sharpness 7, unfiltered" },
        .{ &fixtures.quality_0, &fixtures.quality_0_filtered, true, "quality 0" },
        .{ &fixtures.quality_25, &fixtures.quality_25_filtered, true, "quality 25" },
        .{ &fixtures.quality_50, &fixtures.quality_50_filtered, true, "quality 50" },
        .{ &fixtures.quality_75, &fixtures.quality_75_filtered, true, "quality 75" },
        .{ &fixtures.quality_100, &fixtures.quality_100_filtered, true, "quality 100" },
        .{ &fixtures.segments_1, &fixtures.segments_1_filtered, true, "one segment" },
        .{ &fixtures.segments_4, &fixtures.segments_4_filtered, true, "four segments" },
        .{ &fixtures.sharpness_0, &fixtures.sharpness_0_filtered, true, "sharpness 0" },
        .{ &fixtures.sharpness_3, &fixtures.sharpness_3_filtered, true, "sharpness 3" },
        .{ &fixtures.sharpness_7, &fixtures.sharpness_7_filtered, true, "sharpness 7" },
    }) |case| {
        var frame = try decodeChunk(gpa, case[0], .{ .loop_filter = case[2] });
        defer frame.deinit(gpa);

        try testing.expectEqual(@as(u32, fixtures.width), frame.width);
        try testing.expectEqual(@as(u32, fixtures.height), frame.height);

        const cw = frame.chromaWidth();
        const ch = frame.chromaHeight();
        // The reference is a grayscale PGM of the raw planes: luma first at
        // full size, then U and V side by side below it.
        const want = case[1];
        for (0..fixtures.height) |r| {
            const got = frame.luma(r);
            const expected = want[r * fixtures.width ..][0..fixtures.width];
            testing.expectEqualSlices(u8, expected, got) catch |err| {
                std.debug.print("{s}: luma row {d}\n", .{ case[3], r });
                return err;
            };
        }
        for (0..ch) |r| {
            const base = fixtures.height * fixtures.width + r * fixtures.width;
            testing.expectEqualSlices(u8, want[base..][0..cw], frame.chromaU(r)) catch |err| {
                std.debug.print("{s}: U row {d}\n", .{ case[3], r });
                return err;
            };
            testing.expectEqualSlices(u8, want[base + cw ..][0..cw], frame.chromaV(r)) catch |err| {
                std.debug.print("{s}: V row {d}\n", .{ case[3], r });
                return err;
            };
        }
    }
}

test "an interframe is refused rather than guessed at" {
    const gpa = testing.allocator;
    var chunk = fixtures.quality_50;
    // Bit zero of the frame tag says interframe.
    chunk[0] |= 1;
    try testing.expectError(error.Unsupported, decodeChunk(gpa, &chunk, .{}));
}

test "a frame converts to the pixels dwebp writes" {
    // The conversion out of YUV is not in the specification --- it is a
    // display decision --- so the reference is libwebp's, which is what
    // every WebP anyone has looked at went through.
    const gpa = testing.allocator;
    const rgb = @import("rgb.zig");

    for ([_]struct { []const u8, []const u8, rgb.Upsampling, []const u8 }{
        .{ &fixtures.quality_0, &fixtures.quality_0_rgba_plain, .plain, "q0 plain" },
        .{ &fixtures.quality_50, &fixtures.quality_50_rgba_plain, .plain, "q50 plain" },
        .{ &fixtures.quality_100, &fixtures.quality_100_rgba_plain, .plain, "q100 plain" },
        .{ &fixtures.quality_0, &fixtures.quality_0_rgba, .smooth, "q0 smooth" },
        .{ &fixtures.quality_50, &fixtures.quality_50_rgba, .smooth, "q50 smooth" },
        .{ &fixtures.quality_100, &fixtures.quality_100_rgba, .smooth, "q100 smooth" },
    }) |case| {
        var f = try decodeChunk(gpa, case[0], .{});
        defer f.deinit(gpa);

        const got = try rgb.toRgba(gpa, &f, case[2]);
        defer gpa.free(got);

        var worst: u32 = 0;
        var differing: usize = 0;
        for (got, case[1]) |g, w| {
            const delta = @abs(@as(i32, g) - @as(i32, w));
            if (delta != 0) differing += 1;
            worst = @max(worst, @as(u32, @intCast(delta)));
        }
        testing.expectEqual(@as(usize, 0), differing) catch |err| {
            std.debug.print("{s}: {d} of {d} differ, worst {d}\n", .{
                case[3], differing, got.len, worst,
            });
            return err;
        };
    }
}
