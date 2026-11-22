// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! The table of codecs: which one reads which format, and which writes it.
//!
//! This is one short switch statement, and it is a module of its own because
//! two things need it and neither should have to import the other. `root.zig`
//! is the library's front door; `sandbox.zig` runs the same codecs inside a
//! forked, locked-down process and has no business depending on the front
//! door to do it. Both depend on this.
//!
//! A format that is recognised but has no codec yet fails with
//! `error.Unsupported`, which is the whole reason `Format` lists formats this
//! library cannot read: a caller is told "not yet" rather than "not an image".

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const z2d = @import("z2d");

const common = @import("common.zig");
const format = @import("format.zig");

/// Windows and OS/2 bitmaps.
pub const bmp = @import("bmp.zig");
/// Portable Network Graphics.
pub const png = @import("png.zig");
/// JFIF/JPEG.
pub const jpeg = @import("jpeg.zig");
/// X BitMap.
pub const xbm = @import("xbm.zig");
/// X PixMap.
pub const xpm = @import("xpm.zig");
/// Graphics Interchange Format.
pub const gif = @import("gif.zig");
/// Truevision TGA.
pub const tga = @import("tga.zig");
/// Netpbm: PBM, PGM, PPM and PAM.
pub const netpbm = @import("netpbm.zig");
/// ZSoft PC Paintbrush.
pub const pcx = @import("pcx.zig");
/// Windows icons and cursors.
pub const ico = @import("ico.zig");
/// WebP: a RIFF container over either a lossless bitstream or a VP8
/// keyframe, with the frame's transparency in a chunk of its own.
pub const webp = @import("webp.zig");

/// Reads an image known to be of `fmt`.
pub fn decode(
    gpa: Allocator,
    fmt: format.Format,
    r: *Io.Reader,
    opts: common.DecodeOptions,
) common.DecodeError!z2d.Surface {
    return switch (fmt) {
        .bmp => bmp.decode(gpa, r, opts),
        .png => png.decode(gpa, r, opts),
        .jpeg => jpeg.decode(gpa, r, opts),
        .xbm => xbm.decode(gpa, r, opts),
        .xpm => xpm.decode(gpa, r, opts),
        .gif => gif.decode(gpa, r, opts),
        .tga => tga.decode(gpa, r, opts),
        .pbm, .pgm, .ppm, .pam => netpbm.decode(gpa, r, opts),
        .pcx => pcx.decode(gpa, r, opts),
        .ico => ico.decode(gpa, r, opts),
        .webp => webp.decode(gpa, r, opts),
    };
}

/// Reads the header of an image known to be of `fmt`, and nothing further.
pub fn probe(fmt: format.Format, r: *Io.Reader, limits: common.Limits) common.DecodeError!common.Info {
    return switch (fmt) {
        .bmp => bmp.probe(r, limits),
        .png => png.probe(r, limits),
        .jpeg => jpeg.probe(r, limits),
        .xbm => xbm.probe(r, limits),
        .xpm => xpm.probe(r, limits),
        .gif => gif.probe(r, limits),
        .tga => tga.probe(r, limits),
        .pbm, .pgm, .ppm, .pam => netpbm.probe(r, limits),
        .pcx => pcx.probe(r, limits),
        .ico => ico.probe(r, limits),
        .webp => webp.probe(r, limits),
    };
}

/// Identifies the stream and decodes it.
pub fn decodeDetect(gpa: Allocator, r: *Io.Reader, opts: common.DecodeOptions) common.DecodeError!z2d.Surface {
    const fmt = format.detectReader(r) catch |err| switch (err) {
        // A buffer too small for the signature is a mistake in the calling
        // program, not a property of the image, but `DecodeError` is what the
        // signature promises and this is the nearest thing in it.
        error.BufferTooSmall => return error.InvalidData,
        else => |e| return e,
    };
    return decode(gpa, fmt, r, opts);
}

/// Identifies the stream and reads its header.
pub fn probeDetect(r: *Io.Reader, limits: common.Limits) common.DecodeError!common.Info {
    const fmt = format.detectReader(r) catch |err| switch (err) {
        error.BufferTooSmall => return error.InvalidData,
        else => |e| return e,
    };
    return probe(fmt, r, limits);
}

// -- animation ---------------------------------------------------------------

/// The frame model both animated formats share.
pub const anim = @import("anim.zig");

/// An animation being played, whatever format it came out of.
///
/// Every format is playable, not only the animated ones: a still image is an
/// animation of one frame that is shown forever, and saying so here means a
/// caller can hand this a file without first asking what it is. A PNG that
/// turns out not to be an APNG answers one frame rather than an error, which
/// is what a caller wanting "the frames of this image" meant either way.
pub const Animation = union(enum) {
    gif: gif.Animation,
    png: png.Animation,
    webp: webp.Animation,
    /// Any format with no animated form, or an animated one carrying a single
    /// image: decoded once, handed out once.
    still: Still,

    pub const Still = struct {
        surface: ?z2d.Surface,
        delivered: bool = false,

        pub fn next(self: *Still, gpa: Allocator) common.DecodeError!?anim.Frame {
            // The surface was decoded when this was built, so there is
            // nothing left to allocate; the parameter is here to match the
            // other arms.
            _ = gpa;
            if (self.delivered) return null;
            self.delivered = true;
            return .{
                .surface = self.surface.?,
                .x = 0,
                .y = 0,
                .width = @intCast(self.surface.?.getWidth()),
                .height = @intCast(self.surface.?.getHeight()),
                .delay_ms = 0,
                .dispose = .keep,
                .blend = .source,
                .index = 0,
            };
        }
    };

    pub fn next(self: *Animation, gpa: Allocator) common.DecodeError!?anim.Frame {
        return switch (self.*) {
            inline else => |*a| a.next(gpa),
        };
    }

    /// The canvas as it stands after the last frame, or null when compositing
    /// was turned off.
    pub fn canvasSurface(self: *const Animation) ?*const z2d.Surface {
        return switch (self.*) {
            .gif => |*a| a.canvasSurface(),
            .png => |*a| a.canvasSurface(),
            .webp => |*a| a.canvasSurface(),
            // The frame *is* the canvas for a still image, and it is the same
            // surface rather than a copy of it.
            .still => |*a| if (a.surface) |*s| s else null,
        };
    }

    pub fn info(self: *const Animation) anim.Info {
        return switch (self.*) {
            .gif => |*a| a.info(),
            .png => |*a| a.info(),
            .webp => |*a| a.info(),
            // A still image is shown once and there is only one of it.
            .still => .{ .loop_count = 1, .frames = 1 },
        };
    }

    pub fn deinit(self: *Animation, gpa: Allocator) void {
        switch (self.*) {
            .gif => |*a| a.deinit(gpa),
            .png => |*a| a.deinit(gpa),
            .webp => |*a| a.deinit(gpa),
            .still => |*a| if (a.surface) |*s| s.deinit(gpa),
        }
        self.* = undefined;
    }
};

/// Plays a stream known to be of `fmt`.
pub fn animate(
    gpa: Allocator,
    fmt: format.Format,
    r: *Io.Reader,
    opts: anim.Options,
) common.DecodeError!Animation {
    return switch (fmt) {
        .gif => .{ .gif = try gif.animate(gpa, r, opts) },
        // Every PNG goes through the animated reader, APNG or not: a plain
        // one is an animation of a single frame, which is the same statement
        // this makes about every other format and costs nothing to honour.
        .png => .{ .png = try png.animate(gpa, r, opts) },
        // And every WebP, for the same reason: a simple file is an animation
        // of one frame covering the canvas, and `webp.decode` is itself
        // written in terms of this.
        .webp => .{ .webp = try webp.animate(gpa, r, opts) },
        else => .{ .still = .{ .surface = try decode(gpa, fmt, r, .{
            .limits = opts.limits,
            .surface_type = opts.surface_type,
        }) } },
    };
}

/// Identifies the stream and plays it.
pub fn animateDetect(gpa: Allocator, r: *Io.Reader, opts: anim.Options) common.DecodeError!Animation {
    const fmt = format.detectReader(r) catch |err| switch (err) {
        error.BufferTooSmall => return error.InvalidData,
        else => |e| return e,
    };
    return animate(gpa, fmt, r, opts);
}

/// How to write an animation, and what to write.
///
/// The tag is the format, as it is for `EncodeOptions` --- but only two
/// formats here animate, so this is its own union rather than one arm per
/// `Format` with nine of them refusing.
pub const EncodeAnimationOptions = union(enum) {
    gif: gif.EncodeAnimationOptions,
    png: png.EncodeAnimationOptions,
};

/// An animation being written, whatever format it is going out as.
pub const AnimationEncoder = union(enum) {
    gif: gif.AnimationEncoder,
    png: png.AnimationEncoder,

    /// Writes one frame, exactly as given: its rectangle, delay, disposal and
    /// blend are what goes into the file.
    pub fn frame(self: *AnimationEncoder, gpa: Allocator, f: anim.Frame) common.EncodeError!void {
        return switch (self.*) {
            inline else => |*e| e.frame(gpa, f),
        };
    }

    /// Ends the file. Not optional: neither format is complete without it.
    pub fn finish(self: *AnimationEncoder) common.EncodeError!void {
        return switch (self.*) {
            inline else => |*e| e.finish(),
        };
    }

    pub fn deinit(self: *AnimationEncoder, gpa: Allocator) void {
        switch (self.*) {
            inline else => |*e| e.deinit(gpa),
        }
        self.* = undefined;
    }
};

/// Begins writing an animation.
pub fn encodeAnimation(
    w: *Io.Writer,
    opts: EncodeAnimationOptions,
) common.EncodeError!AnimationEncoder {
    return switch (opts) {
        .gif => |o| .{ .gif = try gif.encodeAnimation(w, o) },
        .png => |o| .{ .png = try png.encodeAnimation(w, o) },
    };
}
