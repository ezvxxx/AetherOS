// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! The `ALPH` chunk: a lossy frame's transparency.
//!
//! VP8 has no alpha channel — it is a video codec, and video is opaque. So a
//! lossy WebP that is not opaque carries its alpha *beside* the frame, in a
//! chunk of its own, as a plane of one byte a pixel the same size as the
//! frame. The two are decoded independently and put together at the end.
//!
//! One header byte, then the plane:
//!
//! ```text
//!   7 6 | 5 4 |   3 2   |   1 0
//!  rsvd | pre | filter  | compression
//! ```
//!
//! **Compression** is either nothing at all — `width * height` bytes, as they
//! are — or a VP8L bitstream. The lossless one is the same bitstream this
//! library already reads, with two differences that are easy to miss: it has
//! **no five-byte header**, because the frame has already said how big it is,
//! and the alpha values are carried in the **green** channel, the encoder
//! having left the other three at zero. That is not a convention invented for
//! the sake of it: it puts the values where the subtract-green transform and
//! the colour cache can do the most for them.
//!
//! **Filtering** is applied to the plane before compression and undone after,
//! and it is not the same machinery as VP8L's predictor transform — this one
//! is four fixed rules over bytes rather than fourteen over pixels.
//!
//! **Pre-processing** the specification calls informative: it says what the
//! encoder did to the values before compressing them, so that a decoder can
//! smooth the result if it wants to. Nothing here acts on it, which is
//! allowed and is what makes it informative.

const std = @import("std");
const testing = std.testing;

/// How a row was predicted from the one above and the byte to the left.
pub const Filter = enum(u2) {
    none,
    horizontal,
    vertical,
    gradient,
};

/// What the plane was compressed with.
pub const Compression = enum(u2) {
    /// The bytes as they are.
    none,
    /// A VP8L bitstream, with the values in its green channel.
    lossless,
};

pub const Header = struct {
    compression: Compression,
    filter: Filter,
    /// What the encoder says it did to the values first. Informative, and
    /// deliberately unused.
    preprocessing: u2,
};

/// Reads the chunk's one header byte.
pub fn parseHeader(byte: u8) error{ InvalidData, Unsupported }!Header {
    // The top two bits must be zero. Rejecting a file that sets them is
    // what libwebp does, and the alternative --- ignoring them --- would be
    // guessing at a meaning some later revision may give them.
    if (byte >> 6 != 0) return error.InvalidData;
    return .{
        .compression = switch (@as(u2, @truncate(byte))) {
            0 => .none,
            1 => .lossless,
            // Two values the format has never defined. A file using one is
            // well formed and says something this cannot read.
            else => return error.Unsupported,
        },
        .filter = @fromBackingInt(@intCast(@as(u2, @truncate(byte >> 2)))),
        .preprocessing = @truncate(byte >> 4),
    };
}

/// Undoes the row filtering, in place.
///
/// The first row has no row above it, so every filter that would have used
/// one falls back to predicting from the left — and the first byte of the
/// first row, which has neither, is predicted from zero.
pub fn unfilter(filter: Filter, width: usize, height: usize, plane: []u8) void {
    std.debug.assert(plane.len == width * height);
    if (filter == .none or width == 0) return;

    for (0..height) |y| {
        const row = plane[y * width ..][0..width];
        const above: ?[]const u8 = if (y == 0) null else plane[(y - 1) * width ..][0..width];
        switch (filter) {
            .none => unreachable,
            .horizontal => horizontal(above, row),
            .vertical => if (above) |prev| {
                for (row, prev) |*v, p| v.* +%= p;
            } else horizontal(null, row),
            .gradient => if (above) |prev| {
                var left: u8 = prev[0];
                var top_left: u8 = prev[0];
                for (row, prev) |*v, top| {
                    left = v.* +% gradient(left, top, top_left);
                    top_left = top;
                    v.* = left;
                }
            } else horizontal(null, row),
        }
    }
}

fn horizontal(above: ?[]const u8, row: []u8) void {
    // The byte above the first one, when there is a row above: the left
    // neighbour of a row's first byte is the byte over it, not nothing.
    var pred: u8 = if (above) |prev| prev[0] else 0;
    for (row) |*v| {
        v.* +%= pred;
        pred = v.*;
    }
}

/// Left plus above minus the corner between them, clamped rather than
/// wrapped — which is the one place this differs from the other three.
fn gradient(left: u8, top: u8, top_left: u8) u8 {
    const g = @as(i32, left) + @as(i32, top) - @as(i32, top_left);
    return @intCast(std.math.clamp(g, 0, 255));
}

// -- tests -------------------------------------------------------------------

test "the header byte comes apart the way libwebp reads it" {
    // `hippopotamus.masked-with-muybridge.lossy.webp`'s, which is 0x0d:
    // gradient filtering over a lossless plane.
    const h = try parseHeader(0x0d);
    try testing.expectEqual(Compression.lossless, h.compression);
    try testing.expectEqual(Filter.gradient, h.filter);
    try testing.expectEqual(@as(u2, 0), h.preprocessing);

    // Nothing set at all: uncompressed and unfiltered.
    const plain = try parseHeader(0x00);
    try testing.expectEqual(Compression.none, plain.compression);
    try testing.expectEqual(Filter.none, plain.filter);

    // The reserved bits are reserved.
    try testing.expectError(error.InvalidData, parseHeader(0x40));
    // And two of the four compression methods do not exist.
    try testing.expectError(error.Unsupported, parseHeader(0x02));
}

test "each filter is undone into what it was filtered from" {
    // A plane with a gradient in it, so that every rule has something to
    // predict rather than a flat field any of them would get right.
    const width = 5;
    const height = 4;
    var original: [width * height]u8 = undefined;
    for (&original, 0..) |*v, i| v.* = @intCast((i * 37 + (i / width) * 11) % 251);

    inline for ([_]Filter{ .none, .horizontal, .vertical, .gradient }) |f| {
        // Filter it the way an encoder would, then undo that.
        var filtered: [width * height]u8 = undefined;
        for (0..height) |y| {
            for (0..width) |x| {
                const at = y * width + x;
                const left: ?u8 = if (x > 0) original[at - 1] else null;
                const top: ?u8 = if (y > 0) original[at - width] else null;
                const corner: ?u8 = if (x > 0 and y > 0) original[at - width - 1] else null;
                const pred: u8 = switch (f) {
                    .none => 0,
                    .horizontal => left orelse (top orelse 0),
                    .vertical => top orelse (left orelse 0),
                    .gradient => if (left != null and top != null and corner != null)
                        gradient(left.?, top.?, corner.?)
                    else
                        (left orelse (top orelse 0)),
                };
                filtered[at] = original[at] -% pred;
            }
        }
        unfilter(f, width, height, &filtered);
        try testing.expectEqualSlices(u8, &original, &filtered);
    }
}

test "a plane with no rows is not walked" {
    var empty: [0]u8 = undefined;
    unfilter(.gradient, 0, 0, &empty);
}
