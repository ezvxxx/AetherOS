// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! VP8: the lossy bitstream inside a lossy WebP, and a video codec's keyframe.
//!
//! **It decodes key frames to pixels**, and the samples it produces are bit
//! for bit the ones libwebp produces — filtered or unfiltered, at every
//! quality. `decode` takes the payload of a `VP8 ` chunk and gives back
//! three planes; `decodeRgba` goes the rest of the way.
//!
//! ```zig
//! var frame = try vp8.decode(gpa, chunk, .{});
//! defer frame.deinit(gpa);
//! ```
//!
//! Everything underneath is public as well, because a decoder is a stack of
//! separately meaningful pieces and a caller may want one of them: the
//! boolean coder, the header, the tokens, the transforms, prediction, the
//! loop filter. `readFrameHeader` in particular answers "how big is this
//! picture?" out of ten bytes, without decoding anything, which is what a
//! `probe` wants for a file it is about to refuse.
//!
//! ## What a VP8 keyframe decoder is
//!
//! VP8 is a video codec and a still WebP is one keyframe of it, so the work
//! is the intra-only path and none of the inter-frame machinery. In the
//! order a decoder needs them, and one file each:
//!
//! 1. **The boolean decoder** (`boolean`). A binary arithmetic coder, and
//!    everything below reads through it.
//! 2. **The first partition's header** (`header`): colour space and
//!    clamping, the segmentation map and its per-segment quantiser and
//!    filter adjustments, the loop filter's type and level, how many token
//!    partitions there are, the quantiser indices, and the updates to the
//!    token probabilities.
//! 3. **The default probability tables** (`coeff`). A thousand and fifty-six
//!    constants, which are data rather than code and have to be exactly
//!    right; there is no partial credit.
//! 4. **Token decoding** (`tokens`): the DCT coefficients, per macroblock,
//!    through a tree of probabilities selected by band and by context.
//! 5. **Intra prediction** (`predict`, `modes`): four whole-block modes for
//!    luma and chroma and ten four-by-four modes, each a small stencil over
//!    the row above and the column to the left.
//! 6. **The inverse transforms** (`transform`): a four-by-four integer DCT,
//!    and a Walsh-Hadamard transform for the second-order luma block.
//! 7. **The loop filter** (`filter`), normal and simple, on every edge —
//!    the part that is easy to write plausibly and get subtly wrong, and
//!    the part that makes the difference between "close" and "exact".
//! 8. **YUV to RGB** (`rgb`), which the specification does not cover at all
//!    and libwebp therefore defines.
//!
//! `frame` is where one to seven meet.
//!
//! RFC 6386 specifies all of it *and* ships the reference decoder as part of
//! the document, which is unusual and makes it the thing to read rather than
//! anything written about it.
//!
//! ## Why it is its own library
//!
//! VP8 is not an image format. It is a video codec that an image format
//! happens to carry one frame of, and it is several thousand lines of
//! arithmetic that has nothing to do with containers, palettes or surfaces.
//! A library that reads it should be usable by anything that meets one.

const std = @import("std");
const Io = std.Io;
const mem = std.mem;
const testing = std.testing;

/// The boolean entropy coder, and the tree coding built on it. Everything
/// past the ten-byte header is read through it.
pub const boolean = @import("bool.zig");
/// The coefficient probability tables: a thousand and fifty-six of them,
/// indexed by plane, band, context and tree branch.
pub const coeff = @import("coeff.zig");
/// The first partition's header, which is everything a frame says about
/// itself before it says anything about a pixel.
pub const header = @import("header.zig");
/// The DCT coefficients: what a macroblock's residue actually is.
pub const tokens = @import("tokens.zig");
/// Dequantisation, and the two inverse transforms.
pub const transform = @import("transform.zig");
/// Intra prediction: guessing a block from its neighbours.
pub const predict = @import("predict.zig");
/// The trees and probabilities a key frame codes its modes with.
pub const modes = @import("modes.zig");
/// The loop filter, which softens the seams between blocks.
pub const filter = @import("filter.zig");
/// Decoding a whole key frame into three planes of samples.
pub const frame = @import("frame.zig");
/// Turning those planes into pixels, which the specification leaves open.
pub const rgb = @import("rgb.zig");

pub const Error = error{
    /// Not a VP8 frame: the three-byte start code is not there.
    InvalidData,
    /// Well formed, and a thing this library does not do: an interframe,
    /// which is a frame of video and never appears in a still image.
    Unsupported,
};

/// The three bytes that follow the frame tag of every keyframe.
pub const start_code = [3]u8{ 0x9d, 0x01, 0x2a };

/// How a dimension is scaled for display.
///
/// The bitstream may say that a frame is to be shown larger than it is coded.
/// Nothing here acts on it — upscaling is a display decision and not a
/// decoding one — but it is carried because a caller that is going to show
/// the picture needs to know, and because throwing it away silently would be
/// worse than saying it is ignored.
pub const Scale = enum(u2) {
    none = 0,
    five_fourths = 1,
    five_thirds = 2,
    two = 3,
};

/// What the ten bytes at the front of a keyframe say.
pub const FrameHeader = struct {
    /// Coded dimensions, in pixels. Fourteen bits each, so at most 16383.
    width: u16,
    height: u16,
    horizontal_scale: Scale,
    vertical_scale: Scale,
    /// Whether the frame may be shown. An invisible frame is a video thing
    /// and never appears in a still image.
    show: bool,
    /// The version, which selects the reconstruction filter and the loop
    /// filter. Zero is the common one; three means no loop filter at all.
    version: u3,
    /// How long the first partition is. Everything above comes before it;
    /// everything a decoder still has to do begins inside it.
    first_partition_len: u19,

    /// The bytes this occupies at the front of a keyframe.
    pub const len = 10;
};

/// Reads the frame tag and keyframe header out of the first ten bytes.
///
/// Only keyframes: an interframe has no start code and no dimensions, and
/// nothing that carries a still image contains one.
pub fn readFrameHeader(bytes: *const [FrameHeader.len]u8) Error!FrameHeader {
    const tag = @as(u32, bytes[0]) | (@as(u32, bytes[1]) << 8) | (@as(u32, bytes[2]) << 16);

    // Bit zero clear means a keyframe. An interframe reaching this is not
    // malformed --- it is a frame of video --- but it has no header to read
    // and nothing here can say anything about it.
    if (tag & 1 != 0) return error.Unsupported;
    if (!mem.eql(u8, bytes[3..6], &start_code)) return error.InvalidData;

    const raw_width = mem.readInt(u16, bytes[6..8], .little);
    const raw_height = mem.readInt(u16, bytes[8..10], .little);

    return .{
        .width = raw_width & 0x3fff,
        .height = raw_height & 0x3fff,
        .horizontal_scale = @fromBackingInt(@intCast(raw_width >> 14)),
        .vertical_scale = @fromBackingInt(@intCast(raw_height >> 14)),
        .version = @intCast((tag >> 1) & 0x7),
        .show = (tag >> 4) & 1 != 0,
        .first_partition_len = @intCast((tag >> 5) & 0x7ffff),
    };
}

/// Reads the frame tag and keyframe header off a stream.
pub fn readHeader(r: *Io.Reader) (Error || Io.Reader.Error)!FrameHeader {
    var bytes: [FrameHeader.len]u8 = undefined;
    try r.readSliceAll(&bytes);
    return readFrameHeader(&bytes);
}

/// A decoded key frame: three planes of samples.
pub const Frame = frame.Frame;

/// What to do while decoding one.
pub const Options = frame.Options;

/// How to stretch the chroma planes back to full size on the way to RGB.
pub const Upsampling = rgb.Upsampling;

/// Decodes a whole key frame out of the bytes of a `VP8 ` chunk.
///
/// This is the way in for a caller that has a lossy WebP and wants the
/// picture: hand it the chunk's payload — the ten-byte frame tag and
/// everything after it — and it does the rest. The pieces are public
/// underneath for anything that needs to take the frame apart, but nothing
/// has to.
///
/// The caller owns the frame and must `deinit` it.
pub fn decode(
    gpa: std.mem.Allocator,
    chunk: []const u8,
    opts: Options,
) (Error || frame.Error)!Frame {
    if (chunk.len < FrameHeader.len) return error.Truncated;
    const tag = try readFrameHeader(chunk[0..FrameHeader.len]);

    const body = chunk[FrameHeader.len..];
    if (body.len < tag.first_partition_len) return error.Truncated;

    var first = try boolean.Decoder.init(body[0..tag.first_partition_len]);
    const h = try header.readKeyFrame(&first);

    // The token partitions live after the first one, behind a table of
    // their sizes. There are at most eight, and the count came out of the
    // header, so the array is a fixed one and nothing is allocated for it.
    var slices: [8][]const u8 = undefined;
    try header.partitionSlices(body[tag.first_partition_len..], h.partitions, &slices);

    return frame.decode(
        gpa,
        tag.width,
        tag.height,
        &h,
        &first,
        slices[0..h.partitions],
        opts,
    );
}

/// Decodes a key frame and converts it to RGBA, four bytes a pixel.
///
/// The alpha is always 255: a `VP8 ` chunk carries none, and what
/// transparency a lossy WebP has arrives beside it in an `ALPH` chunk that
/// this library does not see.
///
/// The caller owns the returned pixels.
pub fn decodeRgba(
    gpa: std.mem.Allocator,
    chunk: []const u8,
    opts: Options,
    upsampling: Upsampling,
) (Error || frame.Error)![]u8 {
    var f = try decode(gpa, chunk, opts);
    defer f.deinit(gpa);
    return rgb.toRgba(gpa, &f, upsampling);
}

// -- tests -------------------------------------------------------------------

test {
    // Without this the other files' tests are never compiled, let alone run:
    // a module's tests come from the files that are analysed, and a `pub
    // const` import that nothing else mentions is not.
    _ = boolean;
    _ = coeff;
    _ = header;
    _ = tokens;
    _ = transform;
    _ = predict;
    _ = modes;
    _ = filter;
    _ = frame;
    _ = rgb;
}

test "a keyframe header gives up its dimensions" {
    // The first ten bytes of `hippopotamus.lossy.webp`'s VP8 chunk, which is
    // 36x28. Taken from the file rather than constructed, so the field
    // packing is held against something libwebp wrote.
    const bytes = [_]u8{ 0x30, 0x01, 0x00, 0x9d, 0x01, 0x2a, 0x24, 0x00, 0x1c, 0x00 };
    const tag = try readFrameHeader(&bytes);

    try testing.expectEqual(@as(u16, 36), tag.width);
    try testing.expectEqual(@as(u16, 28), tag.height);
    try testing.expectEqual(Scale.none, tag.horizontal_scale);
    try testing.expectEqual(Scale.none, tag.vertical_scale);
    try testing.expect(tag.show);
    try testing.expectEqual(@as(u3, 0), tag.version);
}

test "the top two bits of each dimension are a display scale and not size" {
    // 36x28 again, with both scales set: the coded size is unchanged and only
    // what a player would do with it differs.
    const bytes = [_]u8{ 0x30, 0x01, 0x00, 0x9d, 0x01, 0x2a, 0x24, 0xc0, 0x1c, 0x40 };
    const tag = try readFrameHeader(&bytes);

    try testing.expectEqual(@as(u16, 36), tag.width);
    try testing.expectEqual(@as(u16, 28), tag.height);
    try testing.expectEqual(Scale.two, tag.horizontal_scale);
    try testing.expectEqual(Scale.five_fourths, tag.vertical_scale);
}

test "what is not a keyframe says which kind of not" {
    // The start code is wrong: this is not a VP8 frame at all.
    const bad = [_]u8{ 0x30, 0x01, 0x00, 0x00, 0x00, 0x00, 0x24, 0x00, 0x1c, 0x00 };
    try testing.expectError(error.InvalidData, readFrameHeader(&bad));

    // A well-formed interframe, which is a frame of video and has no header
    // to read --- a different thing from a broken file, and told apart from
    // one because a caller may reasonably meet either.
    const inter = [_]u8{ 0x31, 0x01, 0x00, 0x9d, 0x01, 0x2a, 0x24, 0x00, 0x1c, 0x00 };
    try testing.expectError(error.Unsupported, readFrameHeader(&inter));
}

test "it reads off a stream as well as out of an array" {
    var stream: Io.Reader = .fixed(&.{ 0x30, 0x01, 0x00, 0x9d, 0x01, 0x2a, 0x24, 0x00, 0x1c, 0x00 });
    const tag = try readHeader(&stream);
    try testing.expectEqual(@as(u16, 36), tag.width);

    var short: Io.Reader = .fixed(&.{ 0x30, 0x01, 0x00 });
    try testing.expectError(error.EndOfStream, readHeader(&short));
}

test "the whole way in: a chunk of bytes to a picture" {
    const fixtures = @import("fixtures.zig");
    const gpa = testing.allocator;

    // What `dwebp` writes for the same file, which is the only claim worth
    // making here --- the pieces are each checked against libwebp in their
    // own files, and this is checking that they are wired together.
    const pixels = try decodeRgba(gpa, &fixtures.quality_50, .{}, .smooth);
    defer gpa.free(pixels);
    try testing.expectEqualSlices(u8, &fixtures.quality_50_rgba, pixels);

    var f = try decode(gpa, &fixtures.quality_50, .{});
    defer f.deinit(gpa);
    try testing.expectEqual(@as(u32, fixtures.width), f.width);
    try testing.expectEqual(@as(u32, fixtures.height), f.height);
}

test "a chunk too short to hold a header is truncated, not invalid" {
    try testing.expectError(
        error.Truncated,
        decode(testing.allocator, &.{ 0x30, 0x01, 0x00 }, .{}),
    );
}
