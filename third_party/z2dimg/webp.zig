// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! WebP: a RIFF container over two unrelated bitstreams.
//!
//! Neither the container nor the lossy bitstream lives here. **RIFF** is what
//! WAV and AVI are made of too, and is its own library; **VP8** is a video
//! codec that this format happens to carry one keyframe of, and is another.
//! What is left in this file is the part that is actually about WebP: which
//! chunks mean what, and how a frame becomes a surface.
//!
//! What is inside a file comes in three shapes:
//!
//! - **Simple lossless**: one `VP8L` chunk and nothing else. This is the
//!   only shape this library *writes*.
//! - **Simple lossy**: one `VP8 ` chunk — the trailing space is part of the
//!   name — holding a VP8 keyframe. The keyframe itself is decoded by
//!   [zig-vp8](https://git.jcollie.dev/jeff/zig-vp8), which is a video
//!   codec's intra path and has nothing to say about containers.
//! - **Extended**: a `VP8X` chunk declaring a canvas and a set of features,
//!   then any of `ICCP`, `ANIM` with its `ANMF` frames, `ALPH`, `EXIF` and
//!   `XMP `.
//!
//! ## Metadata sits on both sides of the pixels
//!
//! `ICCP` comes before the image data and `EXIF` after it, which the format
//! requires and which has a consequence worth stating plainly: **`probe`
//! can never report a WebP's orientation.** `probe` stops at the first
//! image chunk — that is what makes it cheap — and the `EXIF` chunk is
//! past it, so `Info.orientation` is always `.top_left` here. A caller who
//! wants the real answer passes `DecodeOptions.orientation` to `decode`,
//! which keeps walking the container after it has the picture.
//!
//! That walk is not free on a stream, since stepping over a chunk means
//! reading it, so it happens only when a caller asked for something that
//! lives out there. Nothing is decoded by it: an `ANMF` is a chunk like any
//! other to a walk that does not descend into it.
//!
//! ## Reading the flags
//!
//! `VP8X` holds its feature bits in one byte, and **the specification's prose
//! numbers those bits most significant first**, which reads inverted from the
//! values every implementation actually uses. The constants below are
//! libwebp's, and are the ones to trust.
//!
//! ## Animation
//!
//! An `ANMF` frame maps onto `src/anim.zig` with nothing left over:
//!
//! | `ANMF` | `anim` |
//! | --- | --- |
//! | frame X and Y, stored halved | `Frame.x`, `Frame.y` |
//! | width and height, minus one | `Frame.width`, `Frame.height` |
//! | duration, in milliseconds | `Frame.delay_ms` |
//! | blending method 0 / 1 | `Blend.over` / `Blend.source` |
//! | disposal method 0 / 1 | `Dispose.keep` / `Dispose.background` |
//!
//! There is no dispose-to-previous, so a third of the disposal state machine
//! goes unused. `ANIM`'s loop count already counts plays with zero meaning
//! forever, which is what `anim.Info.loop_count` means — so unlike GIF it
//! needs no conversion.
//!
//! `decode` is written in terms of the animation, exactly as `gif.decode` is:
//! one frame onto a canvas, and the canvas is the answer. A file with no
//! `ANMF` at all is an animation of one frame, which costs nothing to say and
//! saves saying everything twice.
//!
//! ## Sandboxing one
//!
//! `sandbox.decode` runs a decoder on a fixed arena of
//! `Limits.max_pixels * 4 + Options.working_bytes`, and this is the one
//! decoder here that needs a whole second image's worth of scratch: a
//! backward reference may reach anywhere earlier in the picture, so there is
//! no streaming form of VP8L and the ARGB buffer has to exist alongside the
//! surface being filled from it. Eight bytes a pixel at the peak, where every
//! other decoder here allocates the surface and little else.
//!
//! The default eight megabytes of working memory therefore covers an image of
//! about half `max_pixels` and no more. A caller sandboxing WebP at the full
//! budget should raise `working_bytes` to match.
//!
//! ## What the alpha flag means
//!
//! Both `VP8X` and the `VP8L` header carry a bit saying the image has
//! transparency, and in both places it is a *hint*: the specification says it
//! should be zero when every pixel is opaque and does not say it must be.
//! This library takes it at its word, because `probe` and `decode` have to
//! agree about the surface type and the hint is all `probe` can see — which
//! is also what libwebp reports and therefore what Pillow shows. One thing
//! follows that is worth knowing: in `animated-red-blue.webp` the `VP8X`
//! claims alpha while every one of its frames disclaims it, so the container
//! is describing the file and not any particular frame.

const std = @import("std");
const Io = std.Io;
const mem = std.mem;
const math = std.math;
const testing = std.testing;
const Allocator = mem.Allocator;

const z2d = @import("z2d");
/// The container this arrives in, which is also WAV's and AVI's.
pub const riff = @import("riff");
/// The lossy bitstream, which is a video codec and lives in its own library.
pub const vp8 = @import("vp8");

const anim = @import("anim.zig");
const common = @import("common.zig");
const exif = @import("exif.zig");
const icc = @import("icc.zig");
const DecodeError = common.DecodeError;
const DecodeOptions = common.DecodeOptions;
const EncodeError = common.EncodeError;
const Info = common.Info;
const Limits = common.Limits;
const pixels = @import("pixels.zig");
const Rgba8 = pixels.Rgba8;

/// The bit stream and its prefix codes.
pub const prefix = @import("webp/prefix.zig");
/// The lossless bitstream.
pub const vp8l = @import("webp/vp8l.zig");
/// The `ALPH` chunk, which is where a lossy frame keeps its transparency.
pub const alpha = @import("webp/alpha.zig");

/// The `VP8X` feature bits, as libwebp defines them.
pub const feature = struct {
    pub const animation = 0x02;
    pub const xmp = 0x04;
    pub const exif = 0x08;
    pub const alpha = 0x10;
    pub const icc = 0x20;
};

/// The largest canvas `VP8X` can describe: twenty-four bits a side, plus one.
pub const max_canvas = 1 << 24;

/// A file begins `RIFF`, four bytes of length, `WEBP`.
///
/// The signature is in two halves with the file's length between them, which
/// is why this is a predicate rather than an entry in `format.signatures`.
pub fn looksLikeHeader(bytes: []const u8) bool {
    return riff.looksLike(bytes, "WEBP");
}

/// Whether a window too short to decide could still turn out to be one.
pub fn couldBeHeader(bytes: []const u8) bool {
    return riff.couldBe(bytes, "WEBP");
}

/// The container's errors, as this library's.
fn fromRiff(err: riff.Error) DecodeError {
    return switch (err) {
        // Not a RIFF at all, and an RF64 is a WAV too large for RIFF ---
        // neither is a WebP, and neither is a broken one.
        error.NotRiff, error.Rf64 => error.UnknownFormat,
        error.InvalidData => error.InvalidData,
        error.EndOfStream => error.InvalidData,
        error.ReadFailed => |e| e,
    };
}

/// Where a file's metadata goes, for a caller that asked for any.
///
/// Separate from `DecodeOptions` because the two entry points that walk a
/// container are not both given an allocator: `probe` has none and wants
/// none, and passes null here.
pub const Sink = struct {
    gpa: Allocator,
    /// Where an `ICCP` chunk's profile is appended, bounded by
    /// `max_icc_bytes`.
    profile: ?*std.ArrayList(u8) = null,
    /// Where an `EXIF` chunk's orientation is written.
    orientation: ?*exif.Orientation = null,
    max_icc_bytes: u64,

    /// Whether there is anything to collect at all, which is what decides
    /// whether a metadata chunk is read or stepped over.
    fn wanted(self: Sink) bool {
        return self.profile != null or self.orientation != null;
    }
};

/// Reads an `ICCP` or `EXIF` chunk into `sink`.
///
/// Nothing is read when there is nowhere to put it: the chunk is left for
/// the walk to step over, which costs nothing and is what `probe` does.
///
/// **A profile or a block that is malformed is dropped, never an error.**
/// Metadata is decoration, and the rule every reader here follows is that a
/// camera which wrote a broken block fifteen years ago still wrote a
/// perfectly good picture. Only the underlying stream failing propagates.
fn readMetadata(chunks: *riff.Reader, chunk: riff.Chunk, sink: ?*const Sink) DecodeError!void {
    const s = sink orelse return;
    var buf: [512]u8 = undefined;

    if (chunk.is("ICCP")) {
        const out = s.profile orelse return;
        // The first one wins. The format allows one, and choosing between
        // two would be choosing which of two contradictory things to
        // believe about the same pixels.
        if (out.items.len != 0) return;
        if (chunk.len > s.max_icc_bytes) return;
        const body = chunks.payload(&buf);
        try body.appendRemainingUnlimited(s.gpa, out);
        // A profile that is not one is dropped rather than carried into
        // whatever the caller writes next.
        if (!icc.looksValid(out.items)) out.clearRetainingCapacity();
        return;
    }

    if (chunk.is("EXIF")) {
        const out = s.orientation orelse return;
        const body = chunks.payload(&buf);
        // The same TIFF block a JPEG carries in `APP1` and a PNG in `eXIf`,
        // which is why it is read by a module that belongs to none of the
        // three.
        if (try exif.readOrientation(body, chunk.len)) |o| out.* = o;
        return;
    }
}

/// What the container says, before any pixels.
pub const Decoder = struct {
    /// The chunk walk, which is the container library's and not this one's.
    /// It carries the position, so `Animation` picks up wherever `init` left
    /// off.
    chunks: riff.Reader,
    width: u32,
    height: u32,
    has_alpha: bool,
    animated: bool,
    /// Plays, with zero meaning forever. One when the file does not say.
    loop_count: u32 = 1,
    limits: Limits,
    surface_type: z2d.surface.SurfaceType,
    /// The image chunk `init` stopped on, and its `VP8L` header when that was
    /// read to learn the size. What has been read of the chunk is the
    /// container reader's business, not this one's.
    image: ?riff.Chunk = null,
    header: ?vp8l.Header = null,
    /// The ten bytes of a `VP8 ` chunk that `init` read to learn the size,
    /// kept because the lossy decoder wants the frame from its first byte
    /// and the container reader cannot rewind.
    frame_head: ?[vp8.FrameHeader.len]u8 = null,

    pub fn init(r: *Io.Reader, limits: Limits, sink: ?*const Sink) DecodeError!Decoder {
        var chunks = riff.Reader.init(r) catch |err| return fromRiff(err);
        if (!chunks.form.is("WEBP")) return error.UnknownFormat;

        var self: Decoder = .{
            .chunks = chunks,
            .width = 0,
            .height = 0,
            .has_alpha = false,
            .animated = false,
            .limits = limits,
            .surface_type = .image_surface_rgb,
        };

        while (self.chunks.next() catch |err| return fromRiff(err)) |chunk| {
            if (chunk.is("VP8X")) {
                if (self.width != 0) return error.InvalidData;
                if (chunk.len < 10) return error.InvalidData;
                var body: [10]u8 = undefined;
                self.chunks.readSome(&body) catch |err| return fromRiff(err);

                const flags = body[0];
                self.animated = flags & feature.animation != 0;
                self.has_alpha = flags & feature.alpha != 0;
                self.width = readInt24(body[4..7]) + 1;
                self.height = readInt24(body[7..10]) + 1;
                try limits.check(self.width, self.height);
                continue;
            }
            if (chunk.is("ANIM")) {
                if (chunk.len < 6) return error.InvalidData;
                var body: [6]u8 = undefined;
                self.chunks.readSome(&body) catch |err| return fromRiff(err);
                // The background colour is deliberately ignored: this library
                // clears to transparent, which is wuffs' default and what
                // `anim.Canvas` does for every other format.
                self.loop_count = mem.readInt(u16, body[4..6], .little);
                continue;
            }
            if (chunk.is("VP8L")) {
                if (chunk.len < 5) return error.InvalidData;
                var body: [5]u8 = undefined;
                self.chunks.readSome(&body) catch |err| return fromRiff(err);
                const header = try vp8l.parseHeader(&body);
                self.header = header;
                // Only a simple file takes its size from the bitstream; an
                // extended one has already been told by `VP8X`, and a frame
                // may be smaller than the canvas.
                if (self.width == 0) {
                    self.width = header.width;
                    self.height = header.height;
                    self.has_alpha = header.has_alpha;
                    try limits.check(self.width, self.height);
                }
                self.image = chunk;
                break;
            }
            if (chunk.is("VP8 ")) {
                if (chunk.len >= vp8.FrameHeader.len and self.width == 0) {
                    var body: [vp8.FrameHeader.len]u8 = undefined;
                    self.chunks.readSome(&body) catch |err| return fromRiff(err);
                    // Read so that `probe` can answer for a file `decode` is
                    // about to refuse. An interframe has no dimensions to
                    // give, and neither has a frame this cannot parse.
                    const frame = vp8.readFrameHeader(&body) catch |err| switch (err) {
                        error.InvalidData => return error.InvalidData,
                        error.Unsupported => return error.Unsupported,
                    };
                    self.width = frame.width;
                    self.height = frame.height;
                    try limits.check(self.width, self.height);
                    self.frame_head = body;
                }
                self.image = chunk;
                break;
            }
            if (chunk.is("ANMF") or chunk.is("ALPH")) {
                self.image = chunk;
                break;
            }
            if (chunk.is("ICCP") or chunk.is("EXIF")) {
                // `ICCP` belongs here --- the format puts it before the
                // image data --- and `EXIF` does not, but is accepted here
                // anyway for a file that put it early.
                try readMetadata(&self.chunks, chunk, sink);
                continue;
            }
            // `XMP ` and anything this library has never heard of are
            // stepped over by the next `next`, which is the whole point of
            // having a container.
        }

        if (self.width == 0) return error.InvalidData;
        self.surface_type = pixels.naturalSurfaceType(self.has_alpha);
        return self;
    }

    pub fn info(self: Decoder) Info {
        return .{
            .format = .webp,
            .width = self.width,
            .height = self.height,
            .has_alpha = self.has_alpha,
            .surface_type = self.surface_type,
            .animation = if (self.animated) .{
                .declared = .{
                    .loop_count = self.loop_count,
                    // Nothing in the container says how many frames there are:
                    // they are found by reaching the end.
                    .frames = null,
                },
            } else .none,
        };
    }
};

fn readInt24(bytes: *const [3]u8) u32 {
    return @as(u32, bytes[0]) | (@as(u32, bytes[1]) << 8) | (@as(u32, bytes[2]) << 16);
}

// -- animation ---------------------------------------------------------------

pub const Animation = struct {
    decoder: Decoder,
    r: *Io.Reader,
    opts: anim.Options,
    canvas: ?anim.Canvas,
    /// The frame handed out last, still owned here and released when the next
    /// one is read.
    held: ?anim.Frame = null,
    index: u32 = 0,
    /// Summed over every frame, against `Limits.max_total_pixels`. An `ANMF`
    /// header is sixteen bytes and may declare a full-canvas frame, so the
    /// count of frames is the bomb and this is what bounds it.
    total_pixels: u64 = 0,
    done: bool = false,
    /// Where the metadata chunks go, for the caller that asked for any.
    /// `animate` has nowhere to put them and passes null.
    sink: ?*const Sink = null,

    pub fn init(
        r: *Io.Reader,
        gpa: Allocator,
        opts: anim.Options,
        sink: ?*const Sink,
    ) DecodeError!Animation {
        var decoder: Decoder = try .init(r, opts.limits, sink);
        decoder.surface_type = opts.surface_type orelse decoder.info().surface_type;

        var canvas: ?anim.Canvas = null;
        if (opts.composite) {
            canvas = try anim.Canvas.init(gpa, decoder.surface_type, decoder.width, decoder.height);
        }
        return .{ .decoder = decoder, .r = r, .opts = opts, .canvas = canvas, .sink = sink };
    }

    pub fn deinit(self: *Animation, gpa: Allocator) void {
        if (self.held) |*f| f.surface.deinit(gpa);
        if (self.canvas) |*c| c.deinit();
        self.* = undefined;
    }

    pub fn info(self: *const Animation) anim.Info {
        return .{
            .loop_count = if (self.decoder.animated) self.decoder.loop_count else 1,
            .frames = null,
        };
    }

    pub fn canvasSurface(self: *const Animation) ?*const z2d.Surface {
        if (self.canvas) |*c| return &c.surface;
        return null;
    }

    pub fn next(self: *Animation, gpa: Allocator) DecodeError!?anim.Frame {
        if (self.held) |*f| {
            f.surface.deinit(gpa);
            self.held = null;
        }
        if (self.done) return null;
        if (self.index >= self.opts.limits.max_frames) return error.ImageTooLarge;

        var frame = try self.readFrame(gpa) orelse {
            self.done = true;
            return null;
        };
        errdefer frame.surface.deinit(gpa);

        const area = @as(u64, @intCast(frame.surface.getWidth())) *
            @as(u64, @intCast(frame.surface.getHeight()));
        self.total_pixels += area;
        if (self.total_pixels > self.opts.limits.max_total_pixels) return error.ImageTooLarge;

        if (self.canvas) |*c| try c.draw(frame);

        self.index += 1;
        self.held = frame;
        return frame;
    }

    /// Walks chunks until one of them is an image.
    fn readFrame(self: *Animation, gpa: Allocator) DecodeError!?anim.Frame {
        // What the enclosing `ANMF` said, if there is one. A simple file has
        // no frame header at all and its one image covers the canvas.
        var rect: Rect = .{
            .x = 0,
            .y = 0,
            .width = self.decoder.width,
            .height = self.decoder.height,
        };
        var delay_ms: u32 = 0;
        var dispose: anim.Dispose = .keep;
        var blend: anim.Blend = .source;
        // A lossy frame's transparency, if an `ALPH` came before it. Freed
        // either way: `readLossy` copies the values into the surface.
        var plane: ?[]u8 = null;
        defer if (plane) |p| gpa.free(p);

        while (true) {
            // The chunk `Decoder.init` stopped on is the first one here; from
            // then on the container reader supplies them, stepping over
            // whatever was not read and climbing out of any `ANMF` that runs
            // out.
            const chunk = self.decoder.image orelse
                (self.decoder.chunks.next() catch |err| return fromRiff(err)) orelse return null;
            self.decoder.image = null;

            if (chunk.is("ANMF")) {
                // A frame in a file whose `VP8X` did not set the animation
                // flag is a file contradicting its own header --- and, worse,
                // one where `probe` has already told a caller there is no
                // animation here. The same gate APNG puts on `fcTL` for the
                // same reason: an entry point that disagrees with another is
                // worse than one that refuses.
                if (!self.decoder.animated) return error.InvalidData;
                if (chunk.len < 16) return error.InvalidData;
                var body: [16]u8 = undefined;
                self.decoder.chunks.readSome(&body) catch |err| return fromRiff(err);
                // The offsets are stored halved, so a frame always begins on
                // an even pixel. The sizes are stored one less than they are.
                rect = .{
                    .x = readInt24(body[0..3]) * 2,
                    .y = readInt24(body[3..6]) * 2,
                    .width = readInt24(body[6..9]) + 1,
                    .height = readInt24(body[9..12]) + 1,
                };
                delay_ms = readInt24(body[12..15]);
                dispose = if (body[15] & 1 != 0) .background else .keep;
                // Set means *do not* blend, which is the inversion worth
                // reading twice.
                blend = if (body[15] & 2 != 0) .source else .over;
                // A frame has to fit inside the canvas, which the format
                // requires and this library does not clip to. Held against
                // the canvas rather than against `Limits`: the canvas was
                // checked when it was read, so a frame inside it needs no
                // budget of its own --- and a frame outside it is a file
                // contradicting its own header, which is `InvalidData` and
                // not `ImageTooLarge`.
                if (@as(u64, rect.x) + rect.width > self.decoder.width or
                    @as(u64, rect.y) + rect.height > self.decoder.height)
                    return error.InvalidData;
                // An `ANMF` is a container and not a `LIST`: sixteen bytes of
                // frame header, already read above, and then the frame's own
                // chunks. `descend` takes the header from whatever has been
                // read rather than assuming a list type.
                self.decoder.chunks.descend() catch |err| return fromRiff(err);
                continue;
            }

            if (chunk.is("VP8L")) {
                // `ALPH` belongs to a lossy frame and to nothing else: a
                // lossless one carries its own alpha channel, so a file
                // with both has said two different things about the same
                // pixels and there is no reason to prefer either.
                if (plane != null) return error.InvalidData;
                const surface = try self.readLossless(gpa, rect);
                return .{
                    .surface = surface,
                    .x = @intCast(rect.x),
                    .y = @intCast(rect.y),
                    .width = rect.width,
                    .height = rect.height,
                    .delay_ms = delay_ms,
                    .dispose = dispose,
                    .blend = blend,
                    .index = self.index,
                };
            }

            if (chunk.is("ALPH")) {
                // Two of them for one frame is a file contradicting itself,
                // and taking the second would be choosing which of the two
                // contradictory things it says to believe.
                if (plane != null) return error.InvalidData;
                plane = try self.readAlpha(gpa, chunk, rect);
                continue;
            }

            if (chunk.is("VP8 ")) {
                const surface = try self.readLossy(gpa, rect, plane);
                return .{
                    .surface = surface,
                    .x = @intCast(rect.x),
                    .y = @intCast(rect.y),
                    .width = rect.width,
                    .height = rect.height,
                    .delay_ms = delay_ms,
                    .dispose = dispose,
                    .blend = blend,
                    .index = self.index,
                };
            }

            if (chunk.is("ICCP") or chunk.is("EXIF")) {
                // `EXIF` belongs *here*, after the pixels, which is the
                // whole reason this walk reads metadata at all: `probe`
                // stops at the first image chunk and can never reach it.
                try readMetadata(&self.decoder.chunks, chunk, self.sink);
                continue;
            }

            // Everything else --- `XMP ` and whatever this library has
            // never heard of --- is skipped by the next `next`.
        }
    }

    /// Walks whatever is left of the container for the metadata that comes
    /// *after* the pixels, which in WebP is where `EXIF` lives.
    ///
    /// Nothing is decoded: an `ANMF` is a chunk like any other to a walk
    /// that does not descend into it, so this costs the bytes it steps over
    /// and no more. Those bytes still have to be read, since the stream
    /// cannot be seeked, which is why `decode` does this only when a caller
    /// actually asked for something that lives out here.
    pub fn finishMetadata(self: *Animation) DecodeError!void {
        const sink = self.sink orelse return;
        if (!sink.wanted()) return;
        while (self.decoder.chunks.next() catch |err| return fromRiff(err)) |chunk| {
            if (chunk.is("ICCP") or chunk.is("EXIF")) {
                try readMetadata(&self.decoder.chunks, chunk, self.sink);
            }
        }
    }

    /// Reads an `ALPH` chunk into a plane of one byte a pixel.
    fn readAlpha(self: *Animation, gpa: Allocator, chunk: riff.Chunk, rect: Rect) DecodeError![]u8 {
        // A frame carrying transparency in a file whose `VP8X` did not say
        // so is a file contradicting its own header, and `probe` has already
        // told a caller there is no alpha here. The same gate `ANMF` gets,
        // for the same reason: an entry point that disagrees with another is
        // worse than one that refuses.
        if (!self.decoder.has_alpha) return error.InvalidData;
        if (chunk.len < 1) return error.InvalidData;
        var head: [1]u8 = undefined;
        self.decoder.chunks.readSome(&head) catch |err| return fromRiff(err);
        const h = try alpha.parseHeader(head[0]);

        const count = @as(usize, rect.width) * rect.height;
        const plane = try gpa.alloc(u8, count);
        errdefer gpa.free(plane);

        switch (h.compression) {
            .none => {
                // A chunk too short for the plane it claims cannot be
                // stretched into one, and one too long is a file saying two
                // different things about how big its frame is.
                if (chunk.len - 1 != count) return error.InvalidData;
                self.decoder.chunks.readAll(plane) catch |err| return fromRiff(err);
            },
            .lossless => {
                // The same bitstream as a `VP8L` chunk with the five-byte
                // header taken off: the frame has already said how big it
                // is, so the stream does not say it again.
                var limited_buf: [64]u8 = undefined;
                const bounded = self.decoder.chunks.payload(&limited_buf);

                var d: vp8l.Decode = try .init(gpa, bounded, self.opts.limits);
                defer d.deinit();

                const argb = try gpa.alloc(u32, count);
                defer gpa.free(argb);
                try vp8l.decodeTop(&d, rect.width, rect.height, argb);

                // The values are in the green channel and the other three
                // are whatever the encoder left there --- zero, in libwebp's
                // case, which is why the subtract-green transform and the
                // colour cache have anything to work with.
                for (argb, plane) |px, *out| out.* = @truncate(px >> 8);
            },
        }

        alpha.unfilter(h.filter, rect.width, rect.height, plane);
        return plane;
    }

    /// Reads a `VP8 ` chunk, with the alpha plane beside it if there was one.
    fn readLossy(
        self: *Animation,
        gpa: Allocator,
        rect: Rect,
        plane: ?[]const u8,
    ) DecodeError!z2d.Surface {
        // The whole frame has to be in memory at once: VP8 reads its modes
        // out of one partition and its coefficients out of up to eight
        // others, in step, so there is no order in which a stream could be
        // read once.
        //
        // Grown as the bytes arrive rather than allocated from `chunk.len`,
        // which is a number in the file and not a promise about how much of
        // it is there. The reader is bounded to the chunk either way, so
        // this costs nothing and a chunk header claiming a gigabyte behind
        // a hundred bytes buys a hundred bytes.
        var bytes: std.ArrayList(u8) = .empty;
        defer bytes.deinit(gpa);
        if (self.decoder.frame_head) |head| {
            try bytes.appendSlice(gpa, &head);
            self.decoder.frame_head = null;
        }
        var limited_buf: [64]u8 = undefined;
        const bounded = self.decoder.chunks.payload(&limited_buf);
        try bounded.appendRemainingUnlimited(gpa, &bytes);

        // The size out of the frame's own header, checked against what
        // declared it before any planes are allocated. `vp8.decode` finds
        // the same disagreement on its own, but only after allocating for
        // whatever the frame claimed --- and a frame may claim 16383 square
        // inside a container that said nine.
        {
            if (bytes.items.len < vp8.FrameHeader.len) return error.InvalidData;
            const tag = try vp8.readFrameHeader(bytes.items[0..vp8.FrameHeader.len]);
            if (tag.width != rect.width or tag.height != rect.height) return error.InvalidData;
        }

        var f = vp8.decode(gpa, bytes.items, .{}) catch |err| switch (err) {
            error.OutOfMemory => |e| return e,
            error.Unsupported => |e| return e,
            error.Truncated, error.InvalidData => return error.InvalidData,
        };
        defer f.deinit(gpa);

        // The frame and whatever declared it have to agree about the size,
        // for the reason an icon's directory and its image do: one of them
        // is what `probe` reported and the other is what came back.
        if (f.width != rect.width or f.height != rect.height) return error.InvalidData;
        if (plane) |a| std.debug.assert(a.len == @as(usize, f.width) * f.height);

        var sfc: z2d.Surface = z2d.Surface.init(
            self.decoder.surface_type,
            gpa,
            @intCast(f.width),
            @intCast(f.height),
        ) catch |err| switch (err) {
            error.InvalidWidth, error.InvalidHeight => return error.InvalidData,
            error.OutOfMemory => |e| return e,
        };
        errdefer sfc.deinit(gpa);

        // Allocated after the surface so that it is the allocator's last
        // block: in the sandbox, where the child runs on an arena that can
        // only give back what it handed out most recently, that is the
        // difference between the scratch being reclaimed and not.
        //
        // `.smooth` and not `.plain` because it is what `dwebp`, Pillow and
        // every browser do unasked, and a library that quietly produced a
        // blockier picture than all of them would be wrong in the only way
        // that matters here. It is not offered as an option: the
        // specification does not cover the conversion at all, so the thing
        // to be is the same as everybody else rather than configurable.
        const rgba = try vp8.rgb.toRgba(gpa, &f, .smooth);
        defer gpa.free(rgba);

        const row = try gpa.alloc(Rgba8, f.width);
        defer gpa.free(row);
        for (0..f.height) |y| {
            const src = rgba[y * f.width * 4 ..][0 .. f.width * 4];
            for (row, 0..) |*out, x| out.* = .{
                .r = src[x * 4 + 0],
                .g = src[x * 4 + 1],
                .b = src[x * 4 + 2],
                .a = if (plane) |a| a[y * f.width + x] else 255,
            };
            pixels.writeRow(&sfc, @intCast(y), row);
        }
        return sfc;
    }

    fn readLossless(self: *Animation, gpa: Allocator, rect: Rect) DecodeError!z2d.Surface {
        var limited_buf: [64]u8 = undefined;
        // Bounded to what is left of the chunk, so the bitstream cannot read
        // into the one after it however malformed it is --- and the walk
        // works out for itself how much of the chunk the bitstream took, so
        // there is nothing to drain here.
        const bounded = self.decoder.chunks.payload(&limited_buf);

        var d: vp8l.Decode = try .init(gpa, bounded, self.opts.limits);
        defer d.deinit();

        // Read by `Decoder.init` for the first image, and by this for every
        // frame after it.
        const header = self.decoder.header orelse try vp8l.readHeader(&d.br);
        self.decoder.header = null;
        // The frame header and the bitstream have to agree about how big the
        // frame is, for the reason an icon's directory and its image do: one
        // of them is what `probe` reports and the other is what comes back.
        //
        // Before the limits, and that order matters: a bitstream declaring
        // sixteen thousand pixels inside an `ANMF` that declared nine is a
        // malformed file, not a large one, and answering `ImageTooLarge`
        // would have `probe` promise something small and `decode` refuse it
        // as big.
        if (header.width != rect.width or header.height != rect.height) return error.InvalidData;
        try self.opts.limits.check(header.width, header.height);

        const count = @as(usize, header.width) * header.height;
        const argb = try gpa.alloc(u32, count);
        defer gpa.free(argb);
        try vp8l.decodeTop(&d, header.width, header.height, argb);

        var sfc: z2d.Surface = z2d.Surface.init(
            self.decoder.surface_type,
            gpa,
            @intCast(header.width),
            @intCast(header.height),
        ) catch |err| switch (err) {
            error.InvalidWidth, error.InvalidHeight => return error.InvalidData,
            error.OutOfMemory => |e| return e,
        };
        errdefer sfc.deinit(gpa);

        const row = try gpa.alloc(Rgba8, header.width);
        defer gpa.free(row);
        for (0..header.height) |y| {
            const src = argb[y * header.width ..][0..header.width];
            for (src, row) |px, *out| out.* = .{
                .a = @truncate(px >> 24),
                .r = @truncate(px >> 16),
                .g = @truncate(px >> 8),
                .b = @truncate(px),
            };
            pixels.writeRow(&sfc, @intCast(y), row);
        }
        return sfc;
    }
};

const Rect = struct { x: u32, y: u32, width: u32, height: u32 };

/// Reads a WebP as an animation.
pub fn animate(gpa: Allocator, r: *Io.Reader, opts: anim.Options) DecodeError!Animation {
    return Animation.init(r, gpa, opts, null);
}

// -- the uniform entry points ------------------------------------------------

/// Reads a WebP, or its first frame if it animates.
pub fn decode(gpa: Allocator, r: *Io.Reader, opts: DecodeOptions) DecodeError!z2d.Surface {
    if (opts.orientation) |out| out.* = .top_left;
    if (opts.icc) |out| out.clearRetainingCapacity();

    const sink: Sink = .{
        .gpa = gpa,
        .profile = opts.icc,
        .orientation = opts.orientation,
        .max_icc_bytes = opts.limits.max_icc_bytes,
    };
    var animation: Animation = try .init(r, gpa, .{
        .limits = opts.limits,
        .surface_type = opts.surface_type,
        .composite = true,
    }, &sink);
    defer animation.deinit(gpa);

    // A container holding no image chunk at all is thirty bytes long and
    // would otherwise decode to a blank canvas of whatever size its `VP8X`
    // claimed, which is a silent success for a file that has no picture in
    // it.
    if (try animation.next(gpa) == null) return error.InvalidData;

    // `EXIF` sits after the image data --- that is where the format puts
    // it --- so the frame that was just decoded is not the end of what this
    // file has to say. Only when somebody is listening, because reading to
    // the end of an animation to find out which way up it goes is a poor
    // trade for a caller who never asked.
    try animation.finishMetadata();

    // The canvas is the answer, and it has to outlive the animation that
    // built it --- so it is taken rather than copied.
    var canvas = animation.canvas.?;
    animation.canvas = null;
    if (canvas.saved) |*sv| sv.deinit(canvas.gpa);
    return canvas.surface;
}

pub fn probe(r: *Io.Reader, limits: Limits) DecodeError!Info {
    const decoder: Decoder = try .init(r, limits, null);
    return decoder.info();
}

/// How to write a WebP.
///
/// Lossless only. A lossy encoder is a different kind of work from a lossy
/// decoder — rate control and mode decision, where the whole question is
/// which of the correct answers looks best at a given size — and it is not
/// something this library needs in order to do its job.
pub const EncodeOptions = struct {
    lossless: vp8l.EncodeOptions = .{},
};

/// Writes a lossless WebP.
pub fn encode(
    gpa: Allocator,
    sfc: *const z2d.Surface,
    w: *Io.Writer,
    opts: EncodeOptions,
) EncodeError!void {
    const width = sfc.getWidth();
    const height = sfc.getHeight();
    // Fourteen bits a side, plus one. Larger is a picture the bitstream has
    // no way to describe, whatever the container could hold.
    if (width < 1 or height < 1 or width > vp8l.max_side or height > vp8l.max_side) {
        return error.Unsupported;
    }
    const w32: u32 = @intCast(width);
    const h32: u32 = @intCast(height);

    const argb = try gpa.alloc(u32, @as(usize, w32) * h32);
    defer gpa.free(argb);
    const row = try gpa.alloc(Rgba8, w32);
    defer gpa.free(row);
    for (0..h32) |y| {
        pixels.readRow(row, sfc, @intCast(y));
        for (row, argb[y * w32 ..][0..w32]) |px, *out| {
            out.* = (@as(u32, px.a) << 24) | (@as(u32, px.r) << 16) |
                (@as(u32, px.g) << 8) | @as(u32, px.b);
        }
    }

    var stream: std.ArrayList(u8) = .empty;
    defer stream.deinit(gpa);
    try vp8l.encode(gpa, &stream, w32, h32, argb, opts.lossless);

    // The simple lossless form: one `VP8L` chunk and nothing else. A `VP8X`
    // would be needed to declare alpha, an ICC profile or an animation, and
    // this writes none of those.
    var container: riff.Writer = .init("WEBP");
    defer container.deinit(gpa);
    container.chunk(gpa, "VP8L", stream.items) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        error.InvalidNesting => unreachable,
        error.WriteFailed => |e| return e,
    };
    container.finish(w) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        error.InvalidNesting => unreachable,
        error.WriteFailed => |e| return e,
    };
}
