// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Animation: the part that GIF and APNG agree about.
//!
//! The two formats arrived twenty years apart and describe an animation the
//! same way, because there is only one sensible way to describe one that is
//! smaller than a stack of complete pictures. There is a **canvas** the size
//! of the whole image, and a sequence of **frames**, each of which is a
//! rectangle somewhere on that canvas, a duration, a rule for how it is drawn
//! onto what is already there, and a rule for what to do with the canvas
//! afterwards. Everything else is spelling.
//!
//! This module holds that model and the state machine that plays it. The
//! codecs hold the spelling.
//!
//! ## Two outputs, not one
//!
//! A caller gets both halves and pays for only the half it asks for.
//!
//! The **frame** is the rectangle as the file stored it: its own pixels, its
//! own size, un-composited, with nothing of any other frame in it. That is
//! what a frame extractor, a transcoder or anything analysing the file wants,
//! and it is what a viewer does *not* want, since most frames of a real
//! animation are a small patch of changed pixels that means nothing on its
//! own.
//!
//! The **canvas** is every frame so far drawn onto each other in order, which
//! is what is actually on screen at that moment. That is the viewer's half.
//!
//! Frames come out of the decoder either way, because a frame is decoded into
//! its own surface before it can be composited --- so the un-composited half
//! is not an extra feature, it is the intermediate the composited half is
//! built from. `Options.composite` turns the canvas off for a caller that
//! only wants frames, and then no canvas is allocated at all.
//!
//! ## Why the compositing is not here
//!
//! It is in z2d. `z2d.Surface.composite` is a Porter-Duff compositor with the
//! three operators this needs --- `.src`, `.src_over` and `.clear` --- and it
//! ignores the part of a source that falls outside the destination, which is
//! the frame-clipping rule both formats need and the policy this library had
//! already chosen for a GIF frame that hangs off the screen. So what is here
//! is a state machine over three calls, not an implementation of blending.
//!
//! ## Disposal is applied late, which is the thing to get right
//!
//! A frame's `dispose` says what happens to the canvas **after that frame has
//! been shown**, not before it is drawn. So the canvas carries the previous
//! frame's disposal as an obligation and discharges it at the start of the
//! next frame. Applying it eagerly --- at the end of the frame it belongs
//! to --- gives the same picture for `keep` and a canvas that is blank when it
//! should not be for the other two, and it is the classic way to get an
//! animated GIF subtly wrong.
//!
//! `previous` compounds this: it restores what was under the frame *before
//! that frame was drawn*, so the canvas has to save those pixels on the way
//! past. Only the frame's own rectangle is saved, not the whole canvas, which
//! is the difference between a few kilobytes and a few megabytes per frame.

const std = @import("std");
const mem = std.mem;
const testing = std.testing;
const Allocator = mem.Allocator;

const z2d = @import("z2d");

const common = @import("common.zig");
const pixels = @import("pixels.zig");
const Rgba8 = pixels.Rgba8;

/// What to do with the canvas once a frame has been shown.
pub const Dispose = enum {
    /// Leave it. The next frame is drawn over this one.
    keep,
    /// Clear this frame's rectangle back to transparent.
    ///
    /// Named for the GIF specification's "restore to background colour",
    /// which is what it says and not what it means here. APNG's
    /// `APNG_DISPOSE_OP_BACKGROUND` says transparent outright, and for GIF
    /// wuffs makes honouring the declared background colour an opt-in quirk
    /// whose own documentation describes the default it departs from as
    /// "always being transparent black". This library takes that default, for
    /// both formats and for the canvas a first frame does not cover.
    ///
    /// Pillow is the implementation that disagrees: it fills uncovered canvas
    /// and disposed rectangles with the palette entry the screen descriptor
    /// names. So a GIF whose first frame does not cover the screen decodes
    /// differently here than in Pillow, deliberately, and the GIF fixtures
    /// generated against Pillow elsewhere in this project are all single
    /// frames covering the whole screen, where the question does not arise.
    background,
    /// Put back whatever was under this frame's rectangle before it was
    /// drawn.
    previous,
};

/// How a frame is drawn onto what is already on the canvas.
pub const Blend = enum {
    /// Replace, alpha and all. A transparent pixel in the frame makes the
    /// canvas transparent there.
    source,
    /// Composite over. A transparent pixel in the frame leaves the canvas
    /// alone.
    over,
};

/// One frame, as the file stored it.
pub const Frame = struct {
    /// The frame's own pixels: exactly `width` by `height`, un-composited.
    ///
    /// **Borrowed.** It belongs to the decoder and is reused or released by
    /// the next call to `next`. `toOwned` takes a copy that outlives it.
    surface: z2d.Surface,

    /// Where the frame's top-left corner sits on the canvas.
    x: i32,
    y: i32,

    /// The size the *file* gave the frame, which is not always the size of
    /// `surface`.
    ///
    /// A frame may declare itself larger than the canvas or sitting off the
    /// edge of it. `surface` holds the part that lands on the canvas, because
    /// that part is bounded by something the limits have already checked and
    /// the declared size is not. When a frame lands entirely off the canvas
    /// there is nothing to hold and `surface` is a one-pixel transparent
    /// stand-in, a surface having no way to be empty; these two fields are
    /// then the only honest account of what the file asked for.
    width: u32,
    height: u32,

    /// How long the frame is shown, in milliseconds, as the file said.
    ///
    /// Not corrected. A GIF delay of zero or one hundredth of a second is
    /// common and every browser substitutes about a tenth of a second for it,
    /// but that is a viewer's policy about what looks right and not a fact
    /// about the file, so it is left to the viewer.
    delay_ms: u32,

    dispose: Dispose,
    blend: Blend,

    /// Which frame this is, counting from zero.
    index: u32,

    /// A copy of `surface` in memory the caller owns, released with
    /// `z2d.Surface.deinit`.
    ///
    /// For the caller keeping frames past the next `next`, which is anything
    /// collecting them rather than displaying them as they arrive.
    pub fn toOwned(self: *const Frame, gpa: Allocator) Allocator.Error!z2d.Surface {
        // By hand because z2d has no copy constructor: `init` allocates a
        // blank surface and `initBuffer` adopts a buffer rather than copying
        // one. `inline else` so each variant keeps its own element type.
        // The same shape as `sandbox.Image.toOwned`.
        switch (self.surface) {
            inline else => |s, tag| {
                const buf = try gpa.dupe(std.meta.Elem(@TypeOf(s.buf)), s.buf);
                return @unionInit(z2d.Surface, @tagName(tag), .{
                    .width = s.width,
                    .height = s.height,
                    .buf = buf,
                });
            },
        }
    }
};

/// What a file says about the animation as a whole.
pub const Info = struct {
    /// How many times to play it: zero for forever, otherwise the number of
    /// times the whole animation is shown.
    ///
    /// This is APNG's meaning, and **not** GIF's. A GIF's loop count excludes
    /// the first play --- a file saying 2 is played three times --- and a GIF
    /// with no loop count at all is played exactly once, which is a third
    /// case its own encoding cannot distinguish from "twice". The GIF decoder
    /// converts, so that a caller looping on this number is right for both
    /// formats rather than for one and off by one for the other.
    loop_count: u32 = 1,

    /// How many frames the file declares, if it declares a number at all.
    ///
    /// APNG's `acTL` carries one and it is checked against what actually
    /// arrives. GIF has nowhere to put one, so this is null for a GIF and the
    /// only way to learn the count is to reach the end.
    frames: ?u32 = null,
};

/// How to read an animation.
///
/// The same shape as `DecodeOptions`, minus the parts that mean nothing for
/// one: orientation and colour profiles are still-image metadata, and no
/// animated format here carries either.
pub const Options = struct {
    /// What the decoder may allocate on the strength of the headers.
    /// `max_frames` and `max_total_pixels` are the two that matter here.
    limits: common.Limits = .{},

    /// The surface type for both the canvas and the frames, or null for the
    /// one the format naturally produces.
    surface_type: ?z2d.surface.SurfaceType = null,

    /// Whether to keep a composited canvas.
    ///
    /// Turn it off and nothing is allocated for one and nothing is
    /// composited: frames still come out, because a frame is decoded into its
    /// own surface either way. That is the frame-extraction case, and it is
    /// the cheaper of the two rather than the more expensive.
    composite: bool = true,
};

/// The canvas, and the disposal owed to the frame before this one.
pub const Canvas = struct {
    /// The allocator the canvas was made with, and the one everything it owns
    /// afterwards comes from.
    ///
    /// Kept rather than taken per call, so that a caller may hand `draw` a
    /// *different* allocator for the frame and have the canvas' own memory
    /// stay where it was put. That is what lets the sandboxed reader give
    /// each frame a region it resets between frames: the frame is transient
    /// and the canvas is not, and the two must not come from the same bump.
    gpa: Allocator,
    surface: z2d.Surface,

    /// The obligation left by the frame just shown: its rectangle, and what
    /// to do with it. Null before the first frame.
    owed: ?Owed = null,

    /// What `Dispose.previous` needs: the pixels that were under the last
    /// frame before it was drawn. Only allocated if a frame actually asks for
    /// that disposal, which most files never do.
    saved: ?z2d.Surface = null,

    const Owed = struct {
        dispose: Dispose,
        x: i32,
        y: i32,
        width: u32,
        height: u32,
    };

    pub fn init(
        gpa: Allocator,
        surface_type: z2d.surface.SurfaceType,
        width: u32,
        height: u32,
    ) error{ OutOfMemory, InvalidData }!Canvas {
        const surface: z2d.Surface = z2d.Surface.init(
            surface_type,
            gpa,
            @intCast(width),
            @intCast(height),
        ) catch |err| switch (err) {
            error.InvalidWidth, error.InvalidHeight => return error.InvalidData,
            error.OutOfMemory => |e| return e,
        };
        // A new surface is zeroed, which for a colour format is transparent
        // black --- the blank canvas both formats start from.
        return .{ .gpa = gpa, .surface = surface };
    }

    pub fn deinit(self: *Canvas) void {
        self.surface.deinit(self.gpa);
        if (self.saved) |*s| s.deinit(self.gpa);
        self.* = undefined;
    }

    /// Draws one frame: discharges the previous frame's disposal, saves what
    /// this frame needs saved, and composites it.
    pub fn draw(self: *Canvas, frame: Frame) Allocator.Error!void {
        try self.dischargeOwed();

        if (frame.dispose == .previous) {
            try self.save(frame);
        } else if (self.saved) |*s| {
            // Nothing will ask for it; give the memory back rather than
            // holding it for the rest of the animation.
            s.deinit(self.gpa);
            self.saved = null;
        }

        self.surface.composite(
            &frame.surface,
            switch (frame.blend) {
                .source => .src,
                .over => .src_over,
            },
            frame.x,
            frame.y,
            .{},
        );

        self.owed = .{
            .dispose = frame.dispose,
            .x = frame.x,
            .y = frame.y,
            .width = @intCast(frame.surface.getWidth()),
            .height = @intCast(frame.surface.getHeight()),
        };
    }

    /// What the previous frame asked for, now that it has been shown.
    fn dischargeOwed(self: *Canvas) Allocator.Error!void {
        const owed = self.owed orelse return;
        self.owed = null;
        switch (owed.dispose) {
            .keep => {},
            .background => self.clearRect(owed.x, owed.y, owed.width, owed.height) catch |err| switch (err) {
                error.OutOfMemory => |e| return e,
            },
            .previous => {
                const saved = self.saved orelse return; // nothing was saved; leave it
                self.surface.composite(&saved, .src, owed.x, owed.y, .{});
            },
        }
    }

    /// Copies the canvas under `frame` aside, so that `Dispose.previous` has
    /// something to put back.
    fn save(self: *Canvas, frame: Frame) Allocator.Error!void {
        const w: u32 = @intCast(frame.surface.getWidth());
        const h: u32 = @intCast(frame.surface.getHeight());

        if (self.saved) |*s| {
            if (s.getWidth() != @as(i32, @intCast(w)) or s.getHeight() != @as(i32, @intCast(h))) {
                s.deinit(self.gpa);
                self.saved = null;
            }
        }
        if (self.saved == null) {
            self.saved = z2d.Surface.init(
                std.meta.activeTag(self.surface),
                self.gpa,
                @intCast(w),
                @intCast(h),
            ) catch |err| switch (err) {
                // A frame of no area has nothing to save and nothing to
                // restore, which the draw below handles as a no-op.
                error.InvalidWidth, error.InvalidHeight => return,
                error.OutOfMemory => |e| return e,
            };
        }

        // Read the canvas into the saved surface. Straight through `Rgba8`
        // rather than a raw copy, because the two surfaces may be of
        // different types only in principle --- they are the same type here,
        // but going through the conversion is what keeps that an assumption
        // this module does not make.
        const row = try self.gpa.alloc(Rgba8, w);
        defer self.gpa.free(row);
        for (0..h) |j| {
            const y: i32 = frame.y + @as(i32, @intCast(j));
            @memset(row, .{ .r = 0, .g = 0, .b = 0, .a = 0 });
            pixels.readSegment(row, &self.surface, frame.x, y);
            pixels.writeRow(&self.saved.?, @intCast(j), row);
        }
    }

    /// Clears a rectangle back to transparent.
    ///
    /// Done a row at a time rather than through `composite` with `.clear`,
    /// because that operator takes its bounds from a source surface and there
    /// is no source here --- the frame whose rectangle this is has already
    /// been replaced by the next one by the time the disposal is discharged.
    fn clearRect(
        self: *Canvas,
        x: i32,
        y: i32,
        width: u32,
        height: u32,
    ) Allocator.Error!void {
        if (width == 0 or height == 0) return;
        const row = try self.gpa.alloc(Rgba8, width);
        defer self.gpa.free(row);
        @memset(row, .{ .r = 0, .g = 0, .b = 0, .a = 0 });
        for (0..height) |j| {
            pixels.writeRowAt(&self.surface, x, y + @as(i32, @intCast(j)), row);
        }
    }
};
