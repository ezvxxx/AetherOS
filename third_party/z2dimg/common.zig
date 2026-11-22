// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! What every codec in this library agrees about: the limits it decodes
//! within, the description it can give of an image before decoding it, and the
//! errors it is allowed to fail with.
//!
//! These live in a module of their own rather than in the root so that a codec
//! depends on the vocabulary without depending on the dispatcher that chooses
//! between codecs. `root.zig` re-exports all of it; a caller should read it
//! from there.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const Allocator = std.mem.Allocator;

const z2d = @import("z2d");

const Format = @import("format.zig").Format;
const anim = @import("anim.zig");
const exif = @import("exif.zig");
const icc = @import("icc.zig");

/// How much a decoder is permitted to believe about an image before it has
/// seen the pixels.
///
/// A header is a handful of bytes that an attacker writes, and one of the
/// numbers in it is how much memory to allocate. Being sans-I/O makes this
/// worse rather than better: there is no file on disk whose size bounds the
/// claim, only a stream that may be arbitrarily long or may be a pipe that
/// never ends. So the bound has to come from the calling program, which is the
/// only party that knows what it is willing to spend.
///
/// The defaults are sized for a program displaying images to a person: large
/// enough that nothing a camera or a screenshot produces is refused, small
/// enough that a malicious file cannot ask for a terabyte. A batch converter
/// with a machine to itself should raise them; something decoding avatars from
/// the network should lower them a long way.
pub const Limits = struct {
    /// The widest image to decode. The BMP, PNG and JPEG containers all allow
    /// far wider than anything real.
    max_width: u32 = 1 << 15,

    /// The tallest image to decode.
    max_height: u32 = 1 << 15,

    /// The most pixels to decode, however they are arranged. This is the bound
    /// that matters: width and height can each be modest while their product
    /// is not, and it is the product that is allocated. At four bytes a pixel
    /// the default is a quarter of a gigabyte.
    max_pixels: u64 = 1 << 26,

    /// The most encoded input to buffer, for the callers that have to buffer
    /// it — `sandbox.decode` copies the stream into memory before it forks,
    /// because a sandboxed process that could still read its input would need
    /// a syscall this library would rather not permit it.
    ///
    /// Unused by the ordinary streaming decoders, which never hold the encoded
    /// bytes at all.
    max_input_bytes: u64 = 1 << 28,

    /// The largest ICC colour profile to carry out of a file.
    ///
    /// A profile is metadata and is allocated on the strength of a length
    /// field, which is exactly the shape of claim `Limits` exists to bound.
    /// The default is what a JPEG can hold at all --- 255 segments of 65519
    /// bytes --- since a profile larger than that could not have come out of
    /// one, and real profiles are a few kilobytes. A program that never asks
    /// for a profile never allocates for one whatever this says.
    max_icc_bytes: u64 = icc.jpeg_max,

    /// The most frames an animation may have.
    ///
    /// A frame costs almost nothing to declare --- ten bytes of header in a
    /// GIF --- and everything to decode, so the count is where the leverage
    /// is. A thousand frames is longer than any animation anyone means.
    max_frames: u32 = 1 << 10,

    /// The most pixels an animation may decode in total, summed over every
    /// frame.
    ///
    /// `max_pixels` bounds one picture; this bounds the work. They are
    /// different questions: a file well inside `max_pixels` can still ask for
    /// a thousand frames of it, and the cost of that is a thousand times the
    /// cost the still-image budget was written for.
    max_total_pixels: u64 = 1 << 28,

    /// Nothing is refused. For a program decoding files it produced itself, on
    /// a machine it is not sharing.
    pub const unlimited: Limits = .{
        .max_width = std.math.maxInt(u32),
        .max_height = std.math.maxInt(u32),
        .max_pixels = std.math.maxInt(u64),
        .max_input_bytes = std.math.maxInt(u64),
        .max_icc_bytes = std.math.maxInt(u64),
        .max_frames = std.math.maxInt(u32),
        .max_total_pixels = std.math.maxInt(u64),
    };

    /// Refuses dimensions this budget will not pay for.
    ///
    /// Zero in either dimension is refused as well. Every format here can
    /// express a zero-pixel image and none of them mean anything by it, z2d
    /// surfaces start at 1×1, and a decoder that returned one would hand every
    /// caller an edge case to discover for themselves.
    pub fn check(self: Limits, width: u64, height: u64) error{ ImageTooLarge, InvalidData }!void {
        if (width == 0 or height == 0) return error.InvalidData;
        if (width > self.max_width or height > self.max_height) return error.ImageTooLarge;
        // In u64 and so cannot overflow: both sides have already been held
        // below 2^32 by the checks above.
        if (width * height > self.max_pixels) return error.ImageTooLarge;
    }
};

/// What a decoder can say about an image from its header alone, without
/// decoding a single pixel.
pub const Info = struct {
    /// The container the image was found in.
    format: Format,

    width: u32,
    height: u32,

    /// Whether the encoding carries an alpha channel.
    ///
    /// A property of the file rather than of its contents: a 32-bit image
    /// every pixel of which happens to be opaque still reports `true`, since
    /// deciding otherwise would mean reading the whole image to answer a
    /// question asked to avoid reading it.
    has_alpha: bool,

    /// The surface type `decode` will produce for this image when
    /// `DecodeOptions.surface_type` is left null.
    surface_type: z2d.surface.SurfaceType,

    /// Which way up the image goes, from its EXIF metadata.
    ///
    /// `width` and `height` above are the image as *stored*, which is what
    /// `decode` produces; this says what a viewer has to do to display it the
    /// way it was taken, and `Orientation.swapsDimensions` says whether the
    /// two are the other way round on screen.
    ///
    /// A file with no EXIF in it — every BMP, and most PNGs — reports
    /// `.top_left`, which asks for nothing to be done. That is deliberately
    /// indistinguishable from a file that says `.top_left` itself: the
    /// question a caller has is how to display the image, and the answer is
    /// the same either way.
    ///
    /// Read from the metadata that precedes the pixels, since that is how far
    /// this has read. A PNG that puts its `eXIf` chunk after `IDAT`, which is
    /// legal and unusual, reports `.top_left` here.
    orientation: exif.Orientation = .top_left,

    /// What the header said about animation.
    ///
    /// Read from the metadata that precedes the pixels, like `orientation`
    /// above, and honest about the case where that is not enough to say.
    animation: Animation = .none,

    /// Whether a file animates, as far as its header goes.
    ///
    /// Three cases rather than an optional, because the third is real and a
    /// null would hide it. "This file does not animate" and "this format
    /// animates and its header does not say whether this file does" are
    /// different answers, and a caller deciding whether to reach for
    /// `decodeAnimation` wants to tell them apart.
    pub const Animation = union(enum) {
        /// The format has no animated form, or the header settles it: a PNG
        /// with no `acTL` is a still picture and nothing later can change
        /// that.
        none,

        /// The format animates and the header does not say whether this file
        /// does.
        ///
        /// This is GIF, always. A GIF has nowhere to declare a frame count,
        /// and its loop count lives in an extension that may sit anywhere ---
        /// so the only way to learn either is to walk the file, which is
        /// exactly what `probe` exists not to do. `decodeAnimation` answers
        /// as it goes.
        unknown,

        /// The header said, and this is what it said.
        declared: anim.Info,
    };

    /// The pixels this image will occupy, which is the number a caller
    /// deciding whether to go on with the decode actually wants.
    pub fn pixelCount(self: Info) u64 {
        return @as(u64, self.width) * self.height;
    }
};

/// How to decode.
pub const DecodeOptions = struct {
    /// What the decoder is allowed to allocate on the strength of the header.
    limits: Limits = .{},

    /// The surface to decode into, overriding the one the format would
    /// naturally produce.
    ///
    /// Asking for a format that cannot hold what the image contains is
    /// allowed, and loses what it cannot hold: decoding a photograph into
    /// `.image_surface_alpha8` keeps the transparency and discards the colour.
    /// Leave it null to get the closest fit, which is `Info.surface_type`.
    surface_type: ?z2d.surface.SurfaceType = null,

    /// Where to put what the file said about orientation.
    ///
    /// `probe` answers the same question from the header alone and is the way
    /// to ask it before deciding to decode at all. This is for the caller who
    /// has already decided: a sans-I/O decoder is handed a stream it cannot
    /// rewind, so without somewhere to put this, learning the orientation
    /// would mean buffering the whole image to read it twice.
    ///
    /// Left null, nothing is written and nothing is parsed.
    orientation: ?*exif.Orientation = null,

    /// Where to put the file's ICC colour profile, if it has one.
    ///
    /// The bytes are appended with the same allocator the decode was given,
    /// and the caller owns what is in the list afterwards. A file with no
    /// profile, or with one that is not shaped like a profile, leaves it
    /// untouched — so a list that started empty and ended empty means there
    /// was nothing to carry.
    ///
    /// Left null, no profile is collected and nothing is allocated for one.
    /// `Limits.max_icc_bytes` bounds what is.
    ///
    /// Nothing here interprets a profile; see `icc` for what that means and
    /// why.
    icc: ?*std.ArrayList(u8) = null,
};

/// Everything a decode can fail with.
///
/// The three interesting ones are distinct on purpose, because a caller wants
/// to treat them differently: `UnknownFormat` is "this is not an image",
/// `Unsupported` is "this is an image of a kind I cannot read", and
/// `InvalidData` is "this claims to be an image and is broken". Only the last
/// is worth reporting as a corrupt file.
pub const DecodeError = error{
    /// The stream does not begin with a signature this library recognises.
    UnknownFormat,

    /// The stream is one of the formats this library knows, but is malformed:
    /// a length that does not fit the data, a field with no valid value, a
    /// structure that contradicts itself.
    InvalidData,

    /// Well-formed, and uses a feature of the format that this library does
    /// not implement. Distinct from `InvalidData` so that a bug report about
    /// one is not confused with a bug report about the other.
    Unsupported,

    /// The header asks for more than `Limits` permits.
    ImageTooLarge,
} || Io.Reader.Error || Allocator.Error;

/// Everything an encode can fail with.
pub const EncodeError = error{
    /// The surface cannot be represented in the requested format — a
    /// dimension the container cannot express, or a pixel format the encoder
    /// has no faithful mapping for.
    Unsupported,
} || Io.Writer.Error || Allocator.Error;

test "limits refuse what they are there to refuse" {
    const l: Limits = .{ .max_width = 100, .max_height = 100, .max_pixels = 1000 };

    try l.check(10, 10);
    try testing.expectError(error.ImageTooLarge, l.check(101, 1));
    try testing.expectError(error.ImageTooLarge, l.check(1, 101));
    // Within both dimensions and over the product, which is the case a
    // per-dimension limit alone would let through.
    try l.check(100, 10);
    try testing.expectError(error.ImageTooLarge, l.check(100, 11));
}

test "a zero dimension is malformed rather than merely large" {
    const l: Limits = .{};
    try testing.expectError(error.InvalidData, l.check(0, 10));
    try testing.expectError(error.InvalidData, l.check(10, 0));
}

test "the largest dimensions cannot overflow the product" {
    // Both at the maximum an image header can express. The check multiplies
    // in u64, so this is a large number rather than a wrapped one.
    try testing.expectError(error.ImageTooLarge, Limits.check(.{}, std.math.maxInt(u32), std.math.maxInt(u32)));
    try Limits.unlimited.check(std.math.maxInt(u32), std.math.maxInt(u32));
}

test "Info reports the pixel count it was asked for" {
    const info: Info = .{
        .format = .bmp,
        .width = 640,
        .height = 480,
        .has_alpha = false,
        .surface_type = .image_surface_rgb,
    };
    try testing.expectEqual(@as(u64, 307200), info.pixelCount());
}
