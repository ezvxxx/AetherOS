// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! The bridge between what image files carry and what z2d holds.
//!
//! Every format this library reads stores **straight** alpha: a half
//! transparent red is `(255, 0, 0, 128)`, the colour written out at full
//! strength alongside the coverage that applies to it. z2d's compositor wants
//! **premultiplied** alpha, where the same pixel is `(128, 0, 0, 128)` — the
//! colour channels already scaled by the alpha. Handing a straight-alpha value
//! to z2d does not fail; it composites wrongly, and the symptom is a halo of
//! too-bright colour around anything semi-transparent. So the conversion
//! happens exactly once, here, on the way in and on the way out, and no codec
//! in this library ever writes to a surface buffer directly.
//!
//! `Rgba8` is the straight-alpha value that codecs speak. It is deliberately
//! not one of z2d's pixel types: keeping them distinct is what stops a
//! premultiplied value and a straight one being mixed up by the type system
//! staying quiet.
//!
//! The multiplication itself is delegated to z2d rather than written again
//! here, so that this library's rounding is z2d's rounding by construction and
//! cannot drift from it.

const std = @import("std");
const debug = std.debug;
const testing = std.testing;

const z2d = @import("z2d");

/// A single pixel as an image file stores it: 8 bits per channel, straight
/// (non-premultiplied) alpha, in memory order R, G, B, A.
///
/// `extern` for the guaranteed layout, so that a row of these can be cast
/// from or to the packed byte runs that decoders assemble.
pub const Rgba8 = extern struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8,

    /// Fully opaque black — what an undefined pixel decodes to in formats
    /// that leave regions unwritten.
    pub const black: Rgba8 = .{ .r = 0, .g = 0, .b = 0, .a = 255 };

    /// Fully transparent, colourless.
    pub const transparent: Rgba8 = .{ .r = 0, .g = 0, .b = 0, .a = 0 };

    /// An opaque colour.
    pub fn rgb(r: u8, g: u8, b: u8) Rgba8 {
        return .{ .r = r, .g = g, .b = b, .a = 255 };
    }

    /// The same colour and coverage as a z2d `RGBA`, which is to say the
    /// premultiplied form of this value.
    pub fn toZ2d(self: Rgba8) z2d.pixel.RGBA {
        const straight: z2d.pixel.RGBA = .{ .r = self.r, .g = self.g, .b = self.b, .a = self.a };
        return straight.multiply();
    }

    /// The straight-alpha form of a premultiplied z2d `RGBA`.
    ///
    /// Not exactly reversible: `demultiply` divides by the alpha and the
    /// remainder is gone, so a value that made a round trip through a surface
    /// can come back a shade off. That loss is in the premultiplied
    /// representation, not in this conversion, and it is the reason an encoder
    /// writing a surface back out cannot promise the file it produces is
    /// byte-identical to the file it was decoded from.
    pub fn fromZ2d(px: z2d.Pixel) Rgba8 {
        const straight = z2d.pixel.RGBA.fromPixel(px).demultiply();
        return .{ .r = straight.r, .g = straight.g, .b = straight.b, .a = straight.a };
    }
};

/// Writes `src` as the pixels of row `y` of `sfc`, left to right from x = 0,
/// premultiplying on the way.
///
/// Pixels beyond the width of the surface are dropped; a `src` shorter than
/// the row leaves the rest of the row as it was.
///
/// For the four colour formats this takes a `Stride` — one typed slice
/// covering the whole run — and switches once for the row rather than once
/// per pixel. The sub-byte alpha formats have no such slice to hand out,
/// several pixels sharing a byte, so those go through `putPixel` and z2d's own
/// packing.
pub fn writeRow(sfc: *z2d.Surface, y: i32, src: []const Rgba8) void {
    writeRowAt(sfc, 0, y, src);
}

/// Writes a run of pixels starting part way along a row.
///
/// The same as `writeRow` but for a run that does not begin at the left edge,
/// which is what a GIF frame needs: a frame has its own position on the
/// logical screen and may sit anywhere on it.
pub fn writeRowAt(sfc: *z2d.Surface, x: i32, y: i32, src: []const Rgba8) void {
    const width: usize = @intCast(@max(0, sfc.getWidth()));
    if (x < 0 or y < 0 or y >= sfc.getHeight()) return;
    const start: usize = @intCast(x);
    if (start >= width) return;
    const len = @min(width - start, src.len);
    if (len == 0) return;

    switch (sfc.*) {
        .image_surface_argb, .image_surface_rgba => {
            // The two premultiplied colour formats. Same arithmetic, two
            // channel orders, so the switch is on the stride rather than
            // repeated in the loop.
            switch (sfc.getStride(x, y, len)) {
                .argb => |dst| for (dst, src[0..len]) |*d, s| {
                    const px = s.toZ2d();
                    d.* = .{ .r = px.r, .g = px.g, .b = px.b, .a = px.a };
                },
                .rgba => |dst| for (dst, src[0..len]) |*d, s| {
                    d.* = s.toZ2d();
                },
                else => unreachable,
            }
        },
        .image_surface_xrgb, .image_surface_rgb => {
            // No alpha channel to carry the coverage, so the alpha is
            // composited against nothing and the colour is simply taken as
            // written. A caller who wants transparency flattened onto a
            // background should composite it onto one before encoding.
            switch (sfc.getStride(x, y, len)) {
                .xrgb => |dst| for (dst, src[0..len]) |*d, s| {
                    d.* = .{ .r = s.r, .g = s.g, .b = s.b };
                },
                .rgb => |dst| for (dst, src[0..len]) |*d, s| {
                    d.* = .{ .r = s.r, .g = s.g, .b = s.b };
                },
                else => unreachable,
            }
        },
        .image_surface_alpha8, .image_surface_alpha4, .image_surface_alpha2, .image_surface_alpha1 => {
            // An alpha-only surface keeps the coverage and discards the
            // colour, which is z2d's own conversion, so it is z2d that does
            // it: `putPixel` narrows an 8-bit alpha to the surface's width.
            for (src[0..len], 0..) |s, i| {
                sfc.putPixel(@intCast(start + i), y, s.toZ2d().asPixel());
            }
        },
    }
}

/// Writes one pixel, premultiplying on the way.
///
/// The per-row functions are the ones to reach for; this exists for the one
/// case that cannot use them, which is an interlaced image. Adam7 delivers a
/// seventh of a row at a time, scattered across it at a stride that changes
/// every pass, so there is no run of adjacent pixels to hand to `writeRow`.
///
/// A position outside the surface is ignored rather than an error: a decoder
/// working from a malformed header can compute one.
pub fn writePixel(sfc: *z2d.Surface, x: i32, y: i32, px: Rgba8) void {
    if (x < 0 or y < 0 or x >= sfc.getWidth() or y >= sfc.getHeight()) return;
    sfc.putPixel(x, y, px.toZ2d().asPixel());
}

/// Reads row `y` of `sfc` into `dst` as straight alpha, the reverse of
/// `writeRow`.
///
/// Reads `@min(dst.len, width)` pixels and leaves the rest of `dst` untouched.
pub fn readRow(dst: []Rgba8, sfc: *const z2d.Surface, y: i32) void {
    readSegment(dst, sfc, 0, y);
}

/// `readRow` starting somewhere other than the left edge.
///
/// This is what lets an encoder work along a row in fixed-size pieces and so
/// allocate nothing at all, however wide the image: it holds one small buffer
/// on the stack and fills it again for each piece. Going through the stride
/// rather than asking for pixels one at a time matters even then — the switch
/// on the surface's format happens once per piece instead of once per pixel.
pub fn readSegment(dst: []Rgba8, sfc: *const z2d.Surface, x: i32, y: i32) void {
    const width: usize = @intCast(@max(0, sfc.getWidth()));
    if (x < 0 or x >= sfc.getWidth()) return;
    const remaining = width - @as(usize, @intCast(x));
    const len = @min(remaining, dst.len);
    if (len == 0) return;
    if (y < 0 or y >= sfc.getHeight()) return;

    switch (sfc.*) {
        .image_surface_argb, .image_surface_rgba => {
            switch (sfc.getStride(x, y, len)) {
                .argb => |src| for (dst[0..len], src) |*d, s| {
                    d.* = .fromZ2d(s.asPixel());
                },
                .rgba => |src| for (dst[0..len], src) |*d, s| {
                    d.* = .fromZ2d(s.asPixel());
                },
                else => unreachable,
            }
        },
        .image_surface_xrgb, .image_surface_rgb => {
            switch (sfc.getStride(x, y, len)) {
                .xrgb => |src| for (dst[0..len], src) |*d, s| {
                    d.* = .rgb(s.r, s.g, s.b);
                },
                .rgb => |src| for (dst[0..len], src) |*d, s| {
                    d.* = .rgb(s.r, s.g, s.b);
                },
                else => unreachable,
            }
        },
        .image_surface_alpha8, .image_surface_alpha4, .image_surface_alpha2, .image_surface_alpha1 => {
            for (dst[0..len], 0..) |*d, i| {
                const px = sfc.getPixel(x + @as(i32, @intCast(i)), y) orelse
                    z2d.Pixel{ .alpha8 = .{ .a = 0 } };
                d.* = .fromZ2d(px);
            }
        },
    }
}

/// The surface type that carries an image of this description without losing
/// anything: the colour formats, with an alpha channel only when the image has
/// one to keep.
///
/// `has_alpha` is a property of the *file*, not of its contents — a 32-bit
/// PNG every one of whose pixels happens to be opaque still decodes to an
/// alpha surface, because deciding otherwise would mean reading the whole
/// image before choosing where to put it.
pub fn naturalSurfaceType(has_alpha: bool) z2d.surface.SurfaceType {
    return if (has_alpha) .image_surface_rgba else .image_surface_rgb;
}

test "Rgba8 round trip through a premultiplied surface" {
    var sfc: z2d.Surface = try .init(.image_surface_rgba, testing.allocator, 4, 1);
    defer sfc.deinit(testing.allocator);

    // Opaque values survive exactly: multiplying by 255/255 changes nothing.
    const src = [_]Rgba8{
        .rgb(255, 0, 0),
        .rgb(0, 128, 64),
        .{ .r = 255, .g = 255, .b = 255, .a = 255 },
        .transparent,
    };
    writeRow(&sfc, 0, &src);

    var back: [4]Rgba8 = undefined;
    readRow(&back, &sfc, 0);
    try testing.expectEqualSlices(Rgba8, &src, &back);
}

test "a half-transparent pixel is premultiplied in the surface" {
    var sfc: z2d.Surface = try .init(.image_surface_rgba, testing.allocator, 1, 1);
    defer sfc.deinit(testing.allocator);

    // Straight alpha in; the surface must hold the colour scaled by it, or
    // z2d's compositor would draw this far too brightly.
    writeRow(&sfc, 0, &[_]Rgba8{.{ .r = 255, .g = 255, .b = 255, .a = 128 }});
    const stored = sfc.getPixel(0, 0).?.rgba;
    try testing.expectEqual(@as(u8, 128), stored.a);
    try testing.expect(stored.r < 255);
}

test "writeRow clips to the surface rather than writing past it" {
    var sfc: z2d.Surface = try .init(.image_surface_rgb, testing.allocator, 2, 1);
    defer sfc.deinit(testing.allocator);

    writeRow(&sfc, 0, &[_]Rgba8{ .rgb(1, 2, 3), .rgb(4, 5, 6), .rgb(7, 8, 9) });
    try testing.expectEqual(@as(u8, 4), sfc.getPixel(1, 0).?.rgb.r);

    // Rows outside the surface are ignored rather than panicking: a decoder
    // reading a malformed file can ask for one.
    writeRow(&sfc, 5, &[_]Rgba8{.rgb(1, 2, 3)});
    writeRow(&sfc, -1, &[_]Rgba8{.rgb(1, 2, 3)});
}

test "an alpha-only surface keeps the coverage and drops the colour" {
    var sfc: z2d.Surface = try .init(.image_surface_alpha8, testing.allocator, 2, 1);
    defer sfc.deinit(testing.allocator);

    writeRow(&sfc, 0, &[_]Rgba8{
        .{ .r = 255, .g = 0, .b = 0, .a = 200 },
        .{ .r = 0, .g = 255, .b = 0, .a = 0 },
    });
    try testing.expectEqual(@as(u8, 200), sfc.getPixel(0, 0).?.alpha8.a);
    try testing.expectEqual(@as(u8, 0), sfc.getPixel(1, 0).?.alpha8.a);
}

test "readSegment starts where it is told to" {
    var sfc: z2d.Surface = try .init(.image_surface_rgb, testing.allocator, 4, 1);
    defer sfc.deinit(testing.allocator);
    writeRow(&sfc, 0, &[_]Rgba8{ .rgb(1, 0, 0), .rgb(2, 0, 0), .rgb(3, 0, 0), .rgb(4, 0, 0) });

    var two: [2]Rgba8 = undefined;
    readSegment(&two, &sfc, 2, 0);
    try testing.expectEqual(@as(u8, 3), two[0].r);
    try testing.expectEqual(@as(u8, 4), two[1].r);

    // A segment running past the right edge reads what is there and stops.
    var four: [4]Rgba8 = @splat(.black);
    readSegment(&four, &sfc, 3, 0);
    try testing.expectEqual(@as(u8, 4), four[0].r);

    // And one starting past it reads nothing rather than panicking.
    readSegment(&four, &sfc, 9, 0);
    readSegment(&four, &sfc, -1, 0);
}

test "writePixel places one pixel and ignores what is off the surface" {
    var sfc: z2d.Surface = try .init(.image_surface_rgba, testing.allocator, 2, 2);
    defer sfc.deinit(testing.allocator);

    writePixel(&sfc, 1, 1, .{ .r = 255, .g = 255, .b = 255, .a = 128 });
    const stored = sfc.getPixel(1, 1).?.rgba;
    try testing.expectEqual(@as(u8, 128), stored.a);
    // Premultiplied, like everything else that goes through this module.
    try testing.expect(stored.r < 255);

    // Off the surface in each direction, none of which may panic.
    writePixel(&sfc, -1, 0, .black);
    writePixel(&sfc, 0, -1, .black);
    writePixel(&sfc, 2, 0, .black);
    writePixel(&sfc, 0, 2, .black);
}

test "naturalSurfaceType" {
    try testing.expectEqual(z2d.surface.SurfaceType.image_surface_rgba, naturalSurfaceType(true));
    try testing.expectEqual(z2d.surface.SurfaceType.image_surface_rgb, naturalSurfaceType(false));
}
