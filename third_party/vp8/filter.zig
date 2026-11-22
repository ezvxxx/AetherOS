// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! The loop filter: softening the edges between blocks.
//!
//! Every block in a VP8 frame is predicted and transformed on its own, so
//! the seams between them are where the coding shows. The loop filter runs
//! over those seams and pulls the pixels either side of each a little
//! closer together — but only where the difference looks like an artefact
//! rather than like part of the picture, which is what all the thresholds
//! are for.
//!
//! ## What is filtered, and in what order
//!
//! Macroblocks in raster order, each responsible for the edges **above and
//! to the left of it** and for the edges *inside* it — never the ones below
//! or to the right, which belong to the macroblocks that have them on their
//! own top and left. Within a macroblock, in this order:
//!
//! 1. the left macroblock edge, if there is a macroblock to the left;
//! 2. the three interior vertical edges (one in chroma);
//! 3. the top macroblock edge, if there is a macroblock above;
//! 4. the three interior horizontal edges (one in chroma).
//!
//! All the vertical edges before any of the horizontal ones, and each
//! filtered against pixels the previous steps have already changed.
//!
//! **The interior edges are skipped** for a macroblock that is predicted
//! whole *and* has no coefficients at all: there are no subblock seams in
//! it to soften, because nothing inside it was coded separately.
//!
//! ## Two filters, and they are not the same picture
//!
//! `filter_type` in the frame header chooses between a **simple** filter,
//! which touches only the two pixels either side of an edge and only in
//! luma, and a **normal** one, which reaches three deep and treats
//! macroblock edges more strongly than subblock ones. They are different
//! filters producing different output, not a fast path and a slow one.
//!
//! ## Everything is signed eight-bit arithmetic
//!
//! Pixels are converted to signed by subtracting 128, filtered, clamped
//! back into range, and converted again. Getting that wrong gives a picture
//! that is right except where a filtered value would have left the range —
//! which is exactly at the strong edges the filter is supposed to leave
//! alone.

const std = @import("std");
const testing = std.testing;

const header = @import("header.zig");

/// The thresholds one macroblock is filtered with.
pub const Strength = struct {
    /// Zero means this macroblock is not filtered at all.
    level: u8,
    /// The limit on differences between neighbouring interior pixels, past
    /// which the edge is taken to be real and left alone.
    interior: u8,
    /// How far apart two pixels either side of an edge may be.
    edge_limit: u8,
    /// Past this, the edge is "high variance" and is filtered narrowly
    /// rather than broadly.
    hev_threshold: u8,
    /// Whether the edges inside the macroblock are filtered.
    inner: bool,

    /// The limit for an edge between two macroblocks, which is four more
    /// than the limit for one inside a macroblock.
    pub fn macroblockLimit(self: Strength) u8 {
        return self.edge_limit +| 4;
    }
};

/// Works out a macroblock's thresholds from the frame header.
///
/// `segment` is which of the four segments it is in, `split` whether its
/// luma is predicted as subblocks, and `has_coeffs` whether anything in it
/// was coded at all.
pub fn strengthFor(
    h: *const header.Header,
    segment: usize,
    split: bool,
    has_coeffs: bool,
) Strength {
    var level: i32 = h.loop_filter.level;
    if (h.segmentation.enabled) {
        const adjust: i32 = h.segmentation.loop_filter[segment];
        level = if (h.segmentation.absolute) adjust else level + adjust;
    }
    if (h.loop_filter.delta_enabled) {
        // Index zero of each is the intra-frame one, which on a key frame
        // is the only one there is.
        level += h.loop_filter.ref_delta[0];
        if (split) level += h.loop_filter.mode_delta[0];
    }
    level = std.math.clamp(level, 0, 63);

    if (level == 0) {
        return .{ .level = 0, .interior = 0, .edge_limit = 0, .hev_threshold = 0, .inner = false };
    }

    // Sharpness tightens the interior limit, which makes the filter give up
    // on smaller differences and so keeps more detail.
    var interior: i32 = level;
    if (h.loop_filter.sharpness > 0) {
        interior >>= if (h.loop_filter.sharpness > 4) @as(u5, 2) else 1;
        const cap = 9 - @as(i32, h.loop_filter.sharpness);
        if (interior > cap) interior = cap;
    }
    if (interior < 1) interior = 1;

    return .{
        .level = @intCast(level),
        .interior = @intCast(interior),
        .edge_limit = @intCast(2 * level + interior),
        // A key frame's thresholds. An interframe has a third step at 20,
        // and no interframe reaches this library.
        .hev_threshold = if (level >= 40) 2 else if (level >= 15) @as(u8, 1) else 0,
        .inner = split or has_coeffs,
    };
}

/// Clamps an integer into signed eight bits.
fn c(v: i32) i32 {
    return std.math.clamp(v, -128, 127);
}

fn u2s(v: u8) i32 {
    return @as(i32, v) - 128;
}

fn s2u(v: i32) u8 {
    return @intCast(c(v) + 128);
}

/// A run of pixels across an edge, addressed by a stride.
///
/// One type for both directions: a vertical edge is filtered along a row
/// with a step of one, and a horizontal edge down a column with a step of
/// the plane's stride. Nothing else about the two differs, which is why the
/// specification describes only one.
const Segment = struct {
    plane: []u8,
    /// The first pixel *after* the edge.
    at: usize,
    step: usize,

    fn get(self: Segment, i: i32) u8 {
        return self.plane[self.index(i)];
    }

    fn set(self: Segment, i: i32, v: u8) void {
        self.plane[self.index(i)] = v;
    }

    /// `i` counts from the edge: -1 is the pixel before it, 0 the pixel
    /// after.
    fn index(self: Segment, i: i32) usize {
        const signed: isize = @intCast(self.at);
        return @intCast(signed + @as(isize, i) * @as(isize, @intCast(self.step)));
    }
};

/// The adjustment both filters are built on.
///
/// Brings the two pixels either side of the edge closer together by roughly
/// a quarter of their difference, using the pixels one further out as well
/// when `outer_taps` is set.
fn commonAdjust(s: Segment, outer_taps: bool) i32 {
    const p1 = u2s(s.get(-2));
    const p0 = u2s(s.get(-1));
    const q0 = u2s(s.get(0));
    const q1 = u2s(s.get(1));

    var a = c((if (outer_taps) c(p1 - q1) else 0) + 3 * (q0 - p0));
    // `b` balances the rounding of `a / 8` in the one case where the
    // fraction is exactly a half, so that the two sides are moved by the
    // same amount rather than one of them by one more.
    const b = c(a + 3) >> 3;
    a = c(a + 4) >> 3;

    s.set(0, s2u(q0 - a));
    s.set(-1, s2u(p0 + b));
    return a;
}

/// Whether the differences across and around the edge are small enough for
/// this to be an artefact worth softening rather than a real edge.
fn shouldFilter(s: Segment, interior: u8, edge_limit: u8) bool {
    const p3 = u2s(s.get(-4));
    const p2 = u2s(s.get(-3));
    const p1 = u2s(s.get(-2));
    const p0 = u2s(s.get(-1));
    const q0 = u2s(s.get(0));
    const q1 = u2s(s.get(1));
    const q2 = u2s(s.get(2));
    const q3 = u2s(s.get(3));

    const i: i32 = interior;
    return (@abs(p0 - q0) * 2 + @abs(p1 - q1) / 2) <= edge_limit and
        @abs(p3 - p2) <= i and @abs(p2 - p1) <= i and @abs(p1 - p0) <= i and
        @abs(q3 - q2) <= i and @abs(q2 - q1) <= i and @abs(q1 - q0) <= i;
}

/// Whether the edge is sharp enough that filtering it widely would blur
/// something real.
fn highVariance(s: Segment, threshold: u8) bool {
    const p1 = u2s(s.get(-2));
    const p0 = u2s(s.get(-1));
    const q0 = u2s(s.get(0));
    const q1 = u2s(s.get(1));
    return @abs(p1 - p0) > threshold or @abs(q1 - q0) > threshold;
}

/// The simple filter: two pixels either side, and only where the edge
/// difference is small.
fn simpleSegment(s: Segment, edge_limit: u8) void {
    const p1: i32 = s.get(-2);
    const p0: i32 = s.get(-1);
    const q0: i32 = s.get(0);
    const q1: i32 = s.get(1);
    if ((@abs(p0 - q0) * 2 + @abs(p1 - q1) / 2) <= edge_limit) {
        _ = commonAdjust(s, true);
    }
}

/// The normal filter, on an edge between subblocks.
fn subblockSegment(s: Segment, st: Strength, edge_limit: u8) void {
    if (!shouldFilter(s, st.interior, edge_limit)) return;

    const hv = highVariance(s, st.hev_threshold);
    const a = (commonAdjust(s, hv) + 1) >> 1;
    if (!hv) {
        // The two pixels one step in move by about half as much as the two
        // at the edge.
        s.set(1, s2u(u2s(s.get(1)) - a));
        s.set(-2, s2u(u2s(s.get(-2)) + a));
    }
}

/// The normal filter, on an edge between macroblocks, which reaches three
/// pixels deep instead of two.
fn macroblockSegment(s: Segment, st: Strength, edge_limit: u8) void {
    if (!shouldFilter(s, st.interior, edge_limit)) return;

    if (highVariance(s, st.hev_threshold)) {
        // A sharp edge gets the narrow treatment, exactly as the simple
        // filter would give it.
        _ = commonAdjust(s, true);
        return;
    }

    const p2 = u2s(s.get(-3));
    const p1 = u2s(s.get(-2));
    const p0 = u2s(s.get(-1));
    const q0 = u2s(s.get(0));
    const q1 = u2s(s.get(1));
    const q2 = u2s(s.get(2));

    // Something like twice the edge difference, spread over six pixels with
    // the adjustment decaying as it moves away: three sevenths, two
    // sevenths, one seventh. The 27, 18 and 9 over 128 are those fractions,
    // since 9/64 is close enough to a seventh.
    const w = c(c(p1 - q1) + 3 * (q0 - p0));

    var a = c((27 * w + 63) >> 7);
    s.set(0, s2u(q0 - a));
    s.set(-1, s2u(p0 + a));
    a = c((18 * w + 63) >> 7);
    s.set(1, s2u(q1 - a));
    s.set(-2, s2u(p1 + a));
    a = c((9 * w + 63) >> 7);
    s.set(2, s2u(q2 - a));
    s.set(-3, s2u(p2 + a));
}

/// Which of the two filters a frame uses, and how it is applied to a whole
/// edge rather than one segment of it.
pub const Kind = enum { normal, simple };

/// Filters one edge: `count` segments, each starting `span` apart.
fn edge(
    kind: Kind,
    plane: []u8,
    start: usize,
    /// Between one segment and the next along the edge.
    span: usize,
    /// Across the edge, from one pixel to the one after it.
    step: usize,
    count: usize,
    st: Strength,
    limit: u8,
    macroblock_edge: bool,
) void {
    for (0..count) |i| {
        const s: Segment = .{ .plane = plane, .at = start + i * span, .step = step };
        switch (kind) {
            .simple => simpleSegment(s, limit),
            .normal => if (macroblock_edge) macroblockSegment(s, st, limit) else subblockSegment(s, st, limit),
        }
    }
}

/// What one plane of a frame looks like to the filter.
pub const Plane = struct {
    data: []u8,
    stride: usize,
    origin: usize,
};

/// Filters one macroblock's edges, in the four steps and their order.
pub fn macroblock(
    kind: Kind,
    y: Plane,
    u: Plane,
    v: Plane,
    mb_x: u32,
    mb_y: u32,
    st: Strength,
) void {
    if (st.level == 0) return;

    const mb_limit = st.macroblockLimit();
    const sub_limit = st.edge_limit;

    const y_at = y.origin + @as(usize, mb_y) * 16 * y.stride + @as(usize, mb_x) * 16;
    const u_at = u.origin + @as(usize, mb_y) * 8 * u.stride + @as(usize, mb_x) * 8;
    const v_at = v.origin + @as(usize, mb_y) * 8 * v.stride + @as(usize, mb_x) * 8;

    // 1. The left macroblock edge: a vertical edge, so the segments run
    //    along rows and step by one pixel.
    if (mb_x > 0) {
        edge(kind, y.data, y_at, y.stride, 1, 16, st, mb_limit, true);
        if (kind == .normal) {
            // The simple filter leaves chroma alone entirely.
            edge(kind, u.data, u_at, u.stride, 1, 8, st, mb_limit, true);
            edge(kind, v.data, v_at, v.stride, 1, 8, st, mb_limit, true);
        }
    }

    // 2. The vertical edges inside it.
    if (st.inner) {
        for ([_]usize{ 4, 8, 12 }) |x| {
            edge(kind, y.data, y_at + x, y.stride, 1, 16, st, sub_limit, false);
        }
        if (kind == .normal) {
            edge(kind, u.data, u_at + 4, u.stride, 1, 8, st, sub_limit, false);
            edge(kind, v.data, v_at + 4, v.stride, 1, 8, st, sub_limit, false);
        }
    }

    // 3. The top macroblock edge: a horizontal edge, so the segments run
    //    down columns and step by a whole row.
    if (mb_y > 0) {
        edge(kind, y.data, y_at, 1, y.stride, 16, st, mb_limit, true);
        if (kind == .normal) {
            edge(kind, u.data, u_at, 1, u.stride, 8, st, mb_limit, true);
            edge(kind, v.data, v_at, 1, v.stride, 8, st, mb_limit, true);
        }
    }

    // 4. And the horizontal edges inside it.
    if (st.inner) {
        for ([_]usize{ 4, 8, 12 }) |row| {
            edge(kind, y.data, y_at + row * y.stride, 1, y.stride, 16, st, sub_limit, false);
        }
        if (kind == .normal) {
            edge(kind, u.data, u_at + 4 * u.stride, 1, u.stride, 8, st, sub_limit, false);
            edge(kind, v.data, v_at + 4 * v.stride, 1, v.stride, 8, st, sub_limit, false);
        }
    }
}

// -- tests -------------------------------------------------------------------

test "a level of zero means no filtering at all" {
    var h: header.Header = .{};
    h.loop_filter.level = 0;
    const st = strengthFor(&h, 0, false, true);
    try testing.expectEqual(@as(u8, 0), st.level);
    try testing.expect(!st.inner);
}

test "sharpness tightens the interior limit and caps it" {
    var h: header.Header = .{};
    h.loop_filter.level = 40;

    h.loop_filter.sharpness = 0;
    try testing.expectEqual(@as(u8, 40), strengthFor(&h, 0, false, true).interior);

    // Up to four halves it; past four quarters it; and either way it is
    // capped at nine less the sharpness.
    h.loop_filter.sharpness = 1;
    try testing.expectEqual(@as(u8, 8), strengthFor(&h, 0, false, true).interior);
    h.loop_filter.sharpness = 4;
    try testing.expectEqual(@as(u8, 5), strengthFor(&h, 0, false, true).interior);
    h.loop_filter.sharpness = 5;
    try testing.expectEqual(@as(u8, 4), strengthFor(&h, 0, false, true).interior);
    h.loop_filter.sharpness = 7;
    try testing.expectEqual(@as(u8, 2), strengthFor(&h, 0, false, true).interior);
}

test "the interior limit never falls to zero" {
    // A limit of zero would disable the filter by accident rather than by
    // decision, so the specification floors it at one.
    var h: header.Header = .{};
    h.loop_filter.level = 1;
    h.loop_filter.sharpness = 7;
    try testing.expectEqual(@as(u8, 1), strengthFor(&h, 0, false, true).interior);
}

test "a macroblock edge is allowed four more than a subblock edge" {
    var h: header.Header = .{};
    h.loop_filter.level = 20;
    const st = strengthFor(&h, 0, false, true);
    try testing.expectEqual(st.edge_limit + 4, st.macroblockLimit());
    try testing.expectEqual(@as(u8, 2 * 20 + 20), st.edge_limit);
}

test "the high-variance threshold steps at fifteen and forty" {
    var h: header.Header = .{};
    for ([_]struct { u8, u8 }{
        .{ 14, 0 }, .{ 15, 1 }, .{ 39, 1 }, .{ 40, 2 }, .{ 63, 2 },
    }) |case| {
        h.loop_filter.level = case[0];
        try testing.expectEqual(case[1], strengthFor(&h, 0, false, true).hev_threshold);
    }
}

test "inner edges are filtered unless the macroblock is whole and empty" {
    var h: header.Header = .{};
    h.loop_filter.level = 30;
    // Predicted whole and nothing coded: there are no subblock seams in it.
    try testing.expect(!strengthFor(&h, 0, false, false).inner);
    // Anything else has them.
    try testing.expect(strengthFor(&h, 0, true, false).inner);
    try testing.expect(strengthFor(&h, 0, false, true).inner);
    try testing.expect(strengthFor(&h, 0, true, true).inner);
}

test "a segment with nothing to soften is left alone" {
    // Two flat halves with a step between them far larger than the limit:
    // that is a real edge in the picture and the filter must not touch it.
    var plane: [8]u8 = .{ 20, 20, 20, 20, 220, 220, 220, 220 };
    const before = plane;
    const s: Segment = .{ .plane = &plane, .at = 4, .step = 1 };
    const st: Strength = .{
        .level = 20,
        .interior = 20,
        .edge_limit = 60,
        .hev_threshold = 1,
        .inner = true,
    };
    macroblockSegment(s, st, st.macroblockLimit());
    try testing.expectEqualSlices(u8, &before, &plane);
}

test "a small step across an edge is softened" {
    // A step of six, well inside the limits, which is the sort of thing
    // quantisation leaves behind.
    var plane: [8]u8 = .{ 100, 100, 100, 100, 106, 106, 106, 106 };
    const s: Segment = .{ .plane = &plane, .at = 4, .step = 1 };
    const st: Strength = .{
        .level = 20,
        .interior = 20,
        .edge_limit = 60,
        .hev_threshold = 1,
        .inner = true,
    };
    macroblockSegment(s, st, st.macroblockLimit());

    // The two nearest the edge moved most, the next pair less, the outer
    // pair least --- and the whole thing stayed monotonic.
    try testing.expect(plane[3] > 100);
    try testing.expect(plane[4] < 106);
    try testing.expect(plane[3] - 100 >= 106 - plane[4] - 1);
    try testing.expect(plane[2] >= 100 and plane[2] <= plane[3]);
    try testing.expect(plane[5] <= 106 and plane[5] >= plane[4]);
    // And the total is preserved to within rounding: the filter moves
    // pixels together, it does not brighten or darken.
    var sum: i32 = 0;
    for (plane) |v| sum += v;
    try testing.expect(@abs(sum - (4 * 100 + 4 * 106)) <= 2);
}

test "a filter is the same in both directions" {
    // The specification describes one filter and applies it to horizontal
    // and vertical edges alike, so the same segment laid out down a column
    // must come out the same as one laid out along a row.
    const st: Strength = .{
        .level = 25,
        .interior = 25,
        .edge_limit = 70,
        .hev_threshold = 1,
        .inner = true,
    };
    const start = [8]u8{ 60, 62, 61, 64, 71, 70, 72, 73 };

    var row: [8]u8 = start;
    macroblockSegment(.{ .plane = &row, .at = 4, .step = 1 }, st, st.macroblockLimit());

    // The same eight pixels, one per row of a plane eight wide.
    var column: [64]u8 = @splat(0);
    for (start, 0..) |v, i| column[i * 8 + 3] = v;
    macroblockSegment(.{ .plane = &column, .at = 4 * 8 + 3, .step = 8 }, st, st.macroblockLimit());

    for (0..8) |i| try testing.expectEqual(row[i], column[i * 8 + 3]);
}
