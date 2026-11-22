// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! z2dimg reads image files into [z2d](https://github.com/vancluever/z2d)
//! surfaces and writes surfaces back out as image files.
//!
//! ```zig
//! var reader = file.reader(io, &buf);              // whatever you have
//! var surface = try z2dimg.decode(gpa, &reader.interface, .{});
//! defer surface.deinit(gpa);
//! ```
//!
//! ## Sans-I/O
//!
//! Nothing in this library opens, closes, reads or writes a file, and nothing
//! in it takes an `Io`. A decoder is handed a `*std.Io.Reader` and an encoder
//! a `*std.Io.Writer`, and where those get their bytes is entirely the calling
//! program's business: a file, a socket, a slice already in memory, a
//! decompressor, a test fixture. That is what "sans-I/O" means here, and it
//! buys three things.
//!
//! It makes the library indifferent to the `Io` implementation — threads,
//! fibers, io_uring — because it never performs I/O to need one.
//!
//! It makes the library testable without a filesystem: every test in it runs
//! against `Io.Reader.fixed` over a byte slice, which is why they are fast and
//! why a fuzzer can drive them at full speed.
//!
//! And it makes the decoders *pure*, which is the part that matters most. A
//! decoder here is a function from bytes to pixels that performs no system
//! call of any kind. That is what makes `sandbox` possible: a process that can
//! neither open a file nor touch the network is still a perfectly capable
//! decoder, because decoding never needed either.
//!
//! ## Reading
//!
//! `decode` identifies the format from its signature and never from a file
//! name — see `format` for why — and hands off to the codec. `probe` reads
//! only the header, which is how to find out how large an image is before
//! agreeing to decode it. `DecodeOptions.limits` is how to bound what a header
//! may ask for; the defaults are in `Limits` and are worth reading before
//! trusting them with input from anywhere.
//!
//! The reader must have a buffer of at least `min_buffer_len` bytes, so that
//! the signature can be examined without being consumed. A reader with a
//! smaller one is an error rather than a panic.
//!
//! ## Writing
//!
//! `encode` takes a surface and an `EncodeOptions`, whose tag *is* the format
//! to write: there is no separate format argument to contradict the options.
//!
//! ## Sandboxing
//!
//! `sandbox.decode` runs a decoder in a forked process that has been reduced
//! by seccomp to almost no system calls at all, and returns the pixels through
//! shared memory. It is an optional layer over the same codecs, and is the
//! answer to the awkward fact that image decoders are where memory-safety bugs
//! live. See that module for what it does and does not protect against.
//!
//! ## Formats
//!
//! | | reading | writing |
//! | --- | --- | --- |
//! | `bmp` | yes | yes |
//! | `png` | yes, including APNG | yes, including APNG |
//! | `jpeg` | yes | baseline and progressive |
//! | `xbm` | yes | yes |
//! | `xpm` | yes | yes |
//! | `gif` | yes, animated | yes, animated |
//! | `tga` | yes | yes |
//! | `pbm` `pgm` `ppm` `pam` | yes | yes |
//! | `pcx` | yes, every depth | 24-bit |
//! | `ico` | yes, and `cur` | several images |
//! | `webp` | lossless and lossy, still and animated | lossless, still |
//!
//! A format that is recognised but not implemented fails with
//! `error.Unsupported`, never with `error.UnknownFormat`: the library can tell
//! a PNG from a stray file, and says so.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const Allocator = std.mem.Allocator;

const z2d = @import("z2d");

const codecs = @import("codecs.zig");
const common = @import("common.zig");
const format = @import("format.zig");

/// Windows and OS/2 bitmaps.
pub const bmp = codecs.bmp;
/// Portable Network Graphics.
pub const png = codecs.png;
/// JFIF/JPEG.
pub const jpeg = codecs.jpeg;
/// X BitMap: a one-bit image that is also a C source file.
pub const xbm = codecs.xbm;
/// X PixMap: a palette image that is also a C source file.
pub const xpm = codecs.xpm;
/// Graphics Interchange Format, one frame of it.
pub const gif = codecs.gif;
/// Truevision TGA.
pub const tga = codecs.tga;
/// Netpbm: PBM, PGM, PPM and PAM, which are one family and one module.
pub const netpbm = codecs.netpbm;
/// ZSoft PC Paintbrush, and a tour of 1980s graphics hardware.
pub const pcx = codecs.pcx;
/// Windows icons and cursors, which are containers rather than images.
pub const ico = codecs.ico;
/// WebP, both halves of it: the lossless bitstream and the lossy one. Only
/// the lossless half is written.
pub const webp = codecs.webp;
/// Animation: the frame model animated GIF and APNG share.
pub const anim = codecs.anim;
/// ICC colour profiles, carried from one file to another without being
/// interpreted.
pub const icc = @import("icc.zig");
/// Which way up an image goes, read from the EXIF block a JPEG or a PNG can
/// carry.
pub const exif = @import("exif.zig");
/// The straight-alpha to premultiplied-alpha bridge that every codec here
/// writes its output through.
pub const pixels = @import("pixels.zig");
/// Decoding in a process that cannot do anything else.
pub const sandbox = @import("sandbox.zig");

/// The image formats this library can recognise.
pub const Format = format.Format;
/// The format a byte slice begins with, or null.
pub const detect = format.detect;
/// The format a stream begins with, without consuming it.
pub const detectReader = format.detectReader;
/// The smallest buffer a reader handed to this library may have.
pub const min_buffer_len = format.min_buffer_len;

/// What a decoder may believe about an image before it has seen the pixels.
pub const Limits = common.Limits;
/// What a decoder can say about an image from its header alone.
pub const Info = common.Info;
/// How to decode.
pub const DecodeOptions = common.DecodeOptions;
/// Everything a decode can fail with.
pub const DecodeError = common.DecodeError;
/// Everything an encode can fail with.
pub const EncodeError = common.EncodeError;

/// How to write, and what to write.
///
/// The tag is the format, so there is no way to ask for a PNG and pass BMP
/// options: the two are the same choice and are made once.
pub const EncodeOptions = union(Format) {
    bmp: bmp.EncodeOptions,
    png: png.EncodeOptions,
    jpeg: jpeg.EncodeOptions,
    xbm: xbm.EncodeOptions,
    xpm: xpm.EncodeOptions,
    gif: gif.EncodeOptions,
    tga: tga.EncodeOptions,
    pbm: netpbm.BitmapOptions,
    pgm: netpbm.GreyOptions,
    ppm: netpbm.ColourOptions,
    pam: netpbm.ArbitraryOptions,
    pcx: pcx.EncodeOptions,
    ico: ico.EncodeOptions,
    /// Lossless still images only, which is less than WebP can hold and less
    /// than this library reads; `webp.encode` says what it refuses and why.
    webp: webp.EncodeOptions,
};

/// Reads an image, choosing the codec from the stream's signature.
///
/// The caller owns the returned surface and must `deinit` it with `gpa`.
///
/// `r` must have a buffer of at least `min_buffer_len` bytes; the signature is
/// examined without being consumed, so the codec sees it too.
pub fn decode(gpa: Allocator, r: *Io.Reader, opts: DecodeOptions) DecodeError!z2d.Surface {
    return codecs.decodeDetect(gpa, r, opts);
}

/// Reads an image that is known to be of `fmt`, without consulting its
/// signature.
///
/// For a caller who already knows — a stream arriving with a media type it
/// trusts, or a fixture in a test. `decode` is the one to reach for otherwise:
/// trusting an out-of-band claim about a format is trusting whoever made it.
pub fn decodeAs(gpa: Allocator, fmt: Format, r: *Io.Reader, opts: DecodeOptions) DecodeError!z2d.Surface {
    return codecs.decode(gpa, fmt, r, opts);
}

/// Reads an image frame by frame.
///
/// Every format is playable, not only the animated ones: a still image is an
/// animation of one frame, so a caller wanting "the frames of this file" need
/// not first ask what the file is.
///
/// Each frame comes out **un-composited** --- its own pixels, its own
/// rectangle, its delay and its disposal --- and the composited canvas is
/// available alongside it through `Animation.canvasSurface`. Which of the two
/// a caller wants depends entirely on what it is for; see `anim` for why both
/// are offered and why the un-composited half is the cheaper one.
///
/// ```zig
/// var frames = try z2dimg.decodeAnimation(gpa, &reader, .{});
/// defer frames.deinit(gpa);
/// while (try frames.next(gpa)) |frame| {
///     // frame.surface is this frame alone; frames.canvasSurface() is the
///     // picture on screen at this moment.
/// }
/// ```
pub fn decodeAnimation(gpa: Allocator, r: *Io.Reader, opts: anim.Options) DecodeError!Animation {
    return codecs.animateDetect(gpa, r, opts);
}

/// Reads an animation that is known to be of `fmt`, without consulting its
/// signature.
///
/// The counterpart of `decodeAs`, and the same warning applies: trusting an
/// out-of-band claim about a format is trusting whoever made it.
pub fn decodeAnimationAs(
    gpa: Allocator,
    fmt: Format,
    r: *Io.Reader,
    opts: anim.Options,
) DecodeError!Animation {
    return codecs.animate(gpa, fmt, r, opts);
}

/// An animation being played. See `decodeAnimation`.
pub const Animation = codecs.Animation;

/// Writes an animation, a frame at a time.
///
/// Frames go out **as they are given**: the rectangle, delay, disposal and
/// blend on each `anim.Frame` are what the file records. Nothing is analysed
/// and nothing is optimised, which is what makes a decode and an encode a
/// lossless pipe --- an animation through both keeps the sub-rectangles the
/// original had rather than becoming a stack of full-canvas pictures.
///
/// Both formats need the canvas size before any frame, and APNG needs the
/// frame count as well, because `acTL` precedes the image data and a sans-I/O
/// encoder cannot go back and revise it. So those are declared up front and
/// `finish` refuses a count that did not come true.
///
/// ```zig
/// var enc = try z2dimg.encodeAnimation(w, .{ .gif = .{ .width = 64, .height = 48 } });
/// defer enc.deinit(gpa);
/// while (try frames.next(gpa)) |frame| try enc.frame(gpa, frame);
/// try enc.finish();
/// ```
pub fn encodeAnimation(w: *Io.Writer, opts: EncodeAnimationOptions) EncodeError!AnimationEncoder {
    return codecs.encodeAnimation(w, opts);
}

/// How to write an animation, and what to write. See `encodeAnimation`.
pub const EncodeAnimationOptions = codecs.EncodeAnimationOptions;
/// An animation being written. See `encodeAnimation`.
pub const AnimationEncoder = codecs.AnimationEncoder;

/// Reads an image's header and says what it described, without decoding a
/// pixel.
///
/// This consumes the header. A `*Io.Reader` cannot be rewound, so probing and
/// then decoding the same stream means either two readers over the same bytes
/// or a codec's own two-step decoder, such as `bmp.Decoder`, which keeps what
/// it read.
pub fn probe(r: *Io.Reader, limits: Limits) DecodeError!Info {
    return codecs.probeDetect(r, limits);
}

/// Writes a surface out as an image file.
///
/// `gpa` is what the encoder needs while it runs, and is released before this
/// returns. Not every format needs one — `bmp.encode` allocates nothing at all
/// and can be called directly when that matters — but PNG cannot compress
/// without a window, so the shared entry point takes one.
pub fn encode(
    gpa: Allocator,
    sfc: *const z2d.Surface,
    w: *Io.Writer,
    opts: EncodeOptions,
) EncodeError!void {
    return switch (opts) {
        .bmp => |o| bmp.encode(sfc, w, o),
        .png => |o| png.encode(gpa, sfc, w, o),
        .jpeg => |o| jpeg.encode(gpa, sfc, w, o),
        .xbm => |o| xbm.encode(gpa, sfc, w, o),
        .xpm => |o| xpm.encode(gpa, sfc, w, o),
        .gif => |o| gif.encode(gpa, sfc, w, o),
        .tga => |o| tga.encode(gpa, sfc, w, o),
        .pbm => |o| netpbm.encodeBitmap(gpa, sfc, w, o),
        .pgm => |o| netpbm.encodeGrey(gpa, sfc, w, o),
        .ppm => |o| netpbm.encodeColour(gpa, sfc, w, o),
        .pam => |o| netpbm.encodeArbitrary(gpa, sfc, w, o),
        .pcx => |o| pcx.encode(gpa, sfc, w, o),
        .ico => |o| ico.encode(gpa, sfc, w, o),
        .webp => |o| webp.encode(gpa, sfc, w, o),
    };
}

test {
    // Every module, so that `zig build test` runs the tests in all of them
    // rather than only the ones this file happens to reference.
    testing.refAllDecls(@This());
    _ = common;
    _ = format;
    _ = codecs;
    _ = bmp;
    _ = png;
    _ = jpeg;
    _ = xbm;
    _ = xpm;
    _ = gif;
    _ = tga;
    _ = netpbm;
    _ = pcx;
    _ = ico;
    _ = webp;
    _ = anim;
    _ = exif;
    _ = icc;
    _ = pixels;
    _ = sandbox;
}

/// The options each format is round-tripped with by the two tests below.
///
/// One switch rather than the same switch twice, and exhaustive over
/// `Format` on purpose: a format added without a round trip fails to compile
/// in exactly one place rather than being quietly half-finished.
fn coverage(fmt: Format) EncodeOptions {
    return switch (fmt) {
        .bmp => .{ .bmp = .{} },
        .png => .{ .png = .{} },
        .jpeg => .{ .jpeg = .{} },
        .xbm => .{ .xbm = .{} },
        .xpm => .{ .xpm = .{} },
        .gif => .{ .gif = .{} },
        .tga => .{ .tga = .{} },
        .pbm => .{ .pbm = .{} },
        .pgm => .{ .pgm = .{} },
        .ppm => .{ .ppm = .{} },
        .pam => .{ .pam = .{} },
        .pcx => .{ .pcx = .{} },
        .ico => .{ .ico = .{} },
        .webp => .{ .webp = .{} },
    };
}

test "every format reads and writes" {
    // A one-pixel surface through each encoder and back, which is the
    // shortest statement that every round trip exists at all. The codecs'
    // own tests are where the pixels are checked.
    //
    // Exhaustive over `Format` through `coverage`: a format added without a
    // round trip fails to compile there rather than being quietly
    // half-finished.
    const gpa = testing.allocator;
    var sfc: z2d.Surface = try .init(.image_surface_rgb, gpa, 1, 1);
    defer sfc.deinit(gpa);
    sfc.putPixel(0, 0, .{ .rgb = .{ .r = 200, .g = 100, .b = 50 } });

    for (std.enums.values(Format)) |fmt| {
        var list: std.ArrayList(u8) = .empty;
        defer list.deinit(gpa);
        var w: Io.Writer.Allocating = .fromArrayList(gpa, &list);
        defer list = w.toArrayList();

        try encode(gpa, &sfc, &w.writer, coverage(fmt));

        var r: Io.Reader = .fixed(w.written());
        try testing.expectEqual(fmt, try detectReader(&r));

        var back = try decode(gpa, &r, .{});
        defer back.deinit(gpa);
        try testing.expectEqual(@as(i32, 1), back.getWidth());
    }
}

test "every format decodes with the limits turned off" {
    // `Limits.unlimited` sets every budget to the largest value of its type,
    // which is a number arithmetic inside a decoder can walk off the end of:
    // the JPEG decoder multiplied `max_pixels` by four to account for the
    // padding a frame codes beyond the edge of the image, and panicked on
    // every JPEG there is --- valid ones included --- for any caller who
    // asked for no limits.
    //
    // Exhaustive over `Format`, like the round trip above, so a format added
    // without this being true fails to compile here.
    const gpa = testing.allocator;
    var sfc: z2d.Surface = try .init(.image_surface_rgb, gpa, 20, 20);
    defer sfc.deinit(gpa);
    // Twenty-five colours in blocks of four, rather than a gradient: the GIF
    // and XPM encoders build a palette and refuse an image with more colours
    // than one holds, and this test is about the decoders.
    for (0..20) |y| for (0..20) |x| {
        sfc.putPixel(@intCast(x), @intCast(y), .{ .rgb = .{
            .r = @truncate(x / 4 * 60),
            .g = @truncate(y / 4 * 60),
            .b = 0x40,
        } });
    };

    for (std.enums.values(Format)) |fmt| {
        var list: std.ArrayList(u8) = .empty;
        defer list.deinit(gpa);
        var w: Io.Writer.Allocating = .fromArrayList(gpa, &list);
        defer list = w.toArrayList();

        try encode(gpa, &sfc, &w.writer, coverage(fmt));

        var probe_reader: Io.Reader = .fixed(w.written());
        const info = try probe(&probe_reader, .unlimited);
        try testing.expectEqual(@as(u32, 20), info.width);

        var reader: Io.Reader = .fixed(w.written());
        var back = try decode(gpa, &reader, .{ .limits = .unlimited });
        defer back.deinit(gpa);
        try testing.expectEqual(@as(i32, 20), back.getWidth());
    }
}

test "a recognised format that is malformed is not mistaken for a stray file" {
    // A JPEG signature with nothing usable behind it. `InvalidData`, not
    // `UnknownFormat`: the library knows what this claims to be.
    var r: Io.Reader = .fixed("\xff\xd8\xff\xe0" ++ @as([16]u8, @splat('\x00')));
    try testing.expectError(error.InvalidData, decode(testing.allocator, &r, .{}));
}

test "an unrecognised stream is not an image" {
    var r: Io.Reader = .fixed("this is just some text, at length");
    try testing.expectError(error.UnknownFormat, decode(testing.allocator, &r, .{}));
}
