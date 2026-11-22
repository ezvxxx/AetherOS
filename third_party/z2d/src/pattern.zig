// SPDX-License-Identifier: MPL-2.0
//   Copyright © 2024-2026 Chris Marchesi

//! Pattern types and interfaces.
const testing = @import("std").testing;

const math = @import("std").math;

const gradient = @import("gradient.zig");

const Dither = @import("Dither.zig");
const Gradient = @import("gradient.zig").Gradient;
const pixel = @import("pixel.zig");
const Pixel = pixel.Pixel;
const Surface = @import("surface.zig").Surface;
const Transformation = @import("Transformation.zig");

/// Interface tags for pattern types.
pub const PatternType = enum {
    opaque_pattern,
    gradient,
    dither,
    surface,
};

/// What a surface pattern paints outside the surface it samples.
///
/// The same idea as `gradient.Extend` and deliberately not the same type: a
/// gradient's range is an offset and a surface's is a rectangle, and a surface
/// has a fourth answer a gradient does not -- paint nothing at all.
pub const Extend = enum {
    /// Outside the surface is transparent. Cairo's `EXTEND_NONE`.
    none,
    /// The edge pixels carry on outwards forever.
    pad,
    /// The surface tiles.
    repeat,
    /// The surface tiles, every other one mirrored, so tiles meet without a
    /// seam.
    reflect,

    /// Brings a coordinate into `0..size`, or null when there is nothing
    /// there to sample.
    fn apply(self: Extend, v: i64, size: i64) ?i64 {
        if (size <= 0) return null;
        if (v >= 0 and v < size) return v;
        return switch (self) {
            .none => null,
            .pad => @min(@max(v, 0), size - 1),
            .repeat => @mod(v, size),
            .reflect => reflect: {
                const period = size * 2;
                const m = @mod(v, period);
                break :reflect if (m < size) m else period - 1 - m;
            },
        };
    }
};

/// How a surface pattern turns the point a device pixel lands on into a
/// colour, when that point is not the centre of one of the surface's pixels.
pub const Filter = enum {
    /// The pixel the point is in. Hard edges, and the only right answer for
    /// a picture that asks to be drawn pixelated -- and the wrong one for
    /// anything drawn larger or rotated, which it aliases.
    nearest,
    /// A weighted average of the four pixels around the point. Smooth, and
    /// soft when enlarged a long way.
    bilinear,
    /// Mitchell and Netravali's cubic, with B = C = 1/3, over the sixteen
    /// pixels around the point. Sharper than bilinear when enlarging, without
    /// the ringing of an interpolating cubic. It is what Skia means by
    /// high-quality sampling, and so what resvg draws a picture with; against
    /// a black and a white pixel enlarged thirty-two times it reproduces
    /// resvg's ramp to the level.
    ///
    /// It does not pass through the pixels it is given -- B is not zero -- so
    /// a picture at its own size would come out slightly softened. That is
    /// the case a pure translation is, and it is sampled `nearest` instead.
    bicubic,
};

/// Represents sources of pixel data, such as "opaque" single-pixel patterns,
/// gradients, or dithering (additional patterns are WIP).
///
/// The main purpose the `Pattern` union serves is to unify all possible pixel
/// sources to be able to be passed through to the context via
/// `Context.setSource`. There is not much functionality here otherwise,
/// although `Pattern.getPixel` does serve as a baseline for all patterns to
/// assert that they fulfill their basic role of supplying pixel data for
/// drawing operations.
///
/// For more in-depth pattern management, consult the packages holding the
/// primitives, such as `gradient` or `pixel`.
pub const Pattern = union(PatternType) {
    opaque_pattern: OpaquePattern,
    gradient: *Gradient,
    dither: Dither,
    surface: SurfacePattern,

    /// Gets the pixel data at the co-ordinates specified.
    pub fn getPixel(self: Pattern, x: i32, y: i32) Pixel {
        return switch (self) {
            .opaque_pattern => |s| s.pixel,
            inline else => |s| s.getPixel(x, y),
        };
    }
};

/// A simple opaque color pattern that writes the set color to every pixel.
pub const OpaquePattern = struct {
    /// The underlying pixel for this pattern.
    pixel: Pixel,
};

/// A pattern that samples another surface.
///
/// What makes a picture usable as paint: a tile rendered once and then repeated
/// across whatever it fills, which is what SVG's `<pattern>` is and what Cairo
/// calls a surface pattern. Filling a shape with one is an ordinary fill
/// afterwards, rather than a loop that draws the tile again for every cell it
/// covers.
///
/// The surface is borrowed and must outlive the pattern.
pub const SurfacePattern = struct {
    /// The picture being sampled.
    surface: *const Surface,

    /// Where that picture sits, as a matrix taking *pattern* space to the
    /// device -- the same direction `Gradient.setTransformation` takes, and
    /// stored inverted for the same reason: sampling asks the opposite
    /// question, which device pixel came from where.
    ///
    /// Set it with `setTransformation` rather than writing it, unless what you
    /// have is already the inverse.
    transformation: Transformation = Transformation.identity,

    /// What is painted outside the surface's own bounds.
    extend: Extend = .none,

    /// How a point between pixel centres is sampled. `nearest` is the
    /// default because it is what this pattern did before it had a choice,
    /// and it is the right one for a tile that is only ever repeated at its
    /// own size.
    ///
    /// Filtering happens in pre-multiplied space, so a transparent pixel
    /// lends none of its colour to its neighbours, and each tap goes through
    /// `extend` like any sample: an edge under `none` fades to transparent
    /// over the filter's reach rather than stopping hard.
    ///
    /// None of it applies where the matrix is a pure translation. There the
    /// picture is at its own size and every device pixel's centre lands on
    /// one of the picture's, or at a fixed offset from one, and `nearest` is
    /// both exact and cheapest -- which is also what Skia, and so resvg, does.
    filter: Filter = .nearest,

    /// Sets where the sampled picture sits, in the pattern space -> user space
    /// -> device space model. The inverse is what gets stored, because that is
    /// what sampling needs.
    pub fn setTransformation(
        self: *SurfacePattern,
        tr: Transformation,
    ) Transformation.Error!void {
        self.transformation = try tr.inverse();
    }

    /// The pixel at `(x, y)`, or a transparent one where the extend mode says
    /// there is nothing.
    pub fn getPixel(self: *const SurfacePattern, x: i32, y: i32) Pixel {
        // The pixel's centre, so that an identity transformation samples the
        // pixel it is standing on rather than the corner between four.
        var px: f64 = @as(f64, @floatFromInt(x)) + 0.5;
        var py: f64 = @as(f64, @floatFromInt(y)) + 0.5;
        if (!self.transformation.equal(Transformation.identity)) {
            self.transformation.userToDevice(&px, &py);
        }
        if (!(math.isFinite(px) and math.isFinite(py))) return transparent;
        // Far enough out that no tap can be a real pixel of any surface, and
        // far enough in that the integer conversions below cannot overflow.
        const limit: f64 = math.maxInt(i32) - 4;
        if (@abs(px) > limit or @abs(py) > limit) return transparent;

        const filter: Filter = if (self.isTranslation()) .nearest else self.filter;
        return switch (filter) {
            // Floored rather than truncated so that the cell below zero is -1
            // rather than a second zero -- which would make a double-width
            // column down the seam of every tiling.
            .nearest => self.tap(@intFromFloat(@floor(px)), @intFromFloat(@floor(py))) orelse transparent,
            .bilinear => self.filtered(2, px, py, bilinearWeights),
            .bicubic => self.filtered(4, px, py, mitchellWeights),
        };
    }

    const transparent: Pixel = .{ .rgba = .{ .r = 0, .g = 0, .b = 0, .a = 0 } };

    /// Whether the matrix only moves the picture, leaving it at its own size.
    fn isTranslation(self: *const SurfacePattern) bool {
        const t = self.transformation;
        return t.ax == 1 and t.by == 0 and t.cx == 0 and t.dy == 1;
    }

    /// The surface's pixel at `(sx, sy)` after the extend mode has had its
    /// say, or null where it says there is nothing.
    fn tap(self: *const SurfacePattern, sx: i64, sy: i64) ?Pixel {
        const ex = self.extend.apply(sx, self.surface.getWidth()) orelse return null;
        const ey = self.extend.apply(sy, self.surface.getHeight()) orelse return null;
        return self.surface.getPixel(@intCast(ex), @intCast(ey));
    }

    /// A separable filter of `n` taps a side, centred on `(px, py)`.
    ///
    /// Pixel centres are at half-integers, so the point is moved back half a
    /// pixel to put them on whole numbers; the taps are then the `n` whole
    /// numbers around it, and `weights` says how much each is worth given how
    /// far the point sits past the lower middle one.
    fn filtered(
        self: *const SurfacePattern,
        comptime n: usize,
        px: f64,
        py: f64,
        comptime weights: fn (t: f32) [n]f32,
    ) Pixel {
        const fx = px - 0.5;
        const fy = py - 0.5;
        const base_x: i64 = @as(i64, @intFromFloat(@floor(fx))) - (n / 2 - 1);
        const base_y: i64 = @as(i64, @intFromFloat(@floor(fy))) - (n / 2 - 1);
        const wx = weights(@floatCast(fx - @floor(fx)));
        const wy = weights(@floatCast(fy - @floor(fy)));

        var acc: [4]f32 = .{ 0, 0, 0, 0 };
        for (0..n) |j| {
            if (wy[j] == 0) continue;
            for (0..n) |i| {
                const w = wx[i] * wy[j];
                if (w == 0) continue;
                const p = self.tap(base_x + @as(i64, @intCast(i)), base_y + @as(i64, @intCast(j))) orelse continue;
                const c = pixel.RGBA.fromPixel(p);
                acc[0] += w * @as(f32, @floatFromInt(c.r));
                acc[1] += w * @as(f32, @floatFromInt(c.g));
                acc[2] += w * @as(f32, @floatFromInt(c.b));
                acc[3] += w * @as(f32, @floatFromInt(c.a));
            }
        }

        // A cubic's negative lobes can overshoot either way. Alpha is held
        // to a byte, and each colour to the alpha, because a pre-multiplied
        // colour larger than its alpha is not a colour at all -- the
        // compositor would take it for one brighter than white.
        const a = byte(acc[3], 255);
        return .{ .rgba = .{
            .r = byte(acc[0], a),
            .g = byte(acc[1], a),
            .b = byte(acc[2], a),
            .a = a,
        } };
    }

    fn byte(v: f32, max: u8) u8 {
        return @intFromFloat(@round(math.clamp(v, 0, @as(f32, @floatFromInt(max)))));
    }

    fn bilinearWeights(t: f32) [2]f32 {
        return .{ 1 - t, t };
    }

    /// The four weights of the Mitchell--Netravali cubic, B = C = 1/3, for a
    /// point `t` past the second of four taps. They sum to one.
    fn mitchellWeights(t: f32) [4]f32 {
        return .{ mitchell(1 + t), mitchell(t), mitchell(1 - t), mitchell(2 - t) };
    }

    /// Mitchell and Netravali's kernel at distance `x`, with B = C = 1/3:
    /// "Reconstruction Filters in Computer Graphics", SIGGRAPH 1988, eq. 8.
    fn mitchell(x: f32) f32 {
        const b: f32 = 1.0 / 3.0;
        const c: f32 = 1.0 / 3.0;
        const ax = @abs(x);
        if (ax < 1) {
            return ((12 - 9 * b - 6 * c) * ax * ax * ax +
                (-18 + 12 * b + 6 * c) * ax * ax +
                (6 - 2 * b)) / 6;
        }
        if (ax < 2) {
            return ((-b - 6 * c) * ax * ax * ax +
                (6 * b + 30 * c) * ax * ax +
                (-12 * b - 48 * c) * ax +
                (8 * b + 24 * c)) / 6;
        }
        return 0;
    }

    /// Shorthand for returning this as a pattern.
    pub fn asPattern(self: *const SurfacePattern) Pattern {
        return .{ .surface = self.* };
    }
};

test "OpaquePattern, as interface" {
    const px: Pixel = .{ .rgb = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC } };
    const pt: Pattern = .{ .opaque_pattern = .{ .pixel = px } };
    try testing.expectEqual(px, pt.getPixel(1, 1));
}

test "Extend brings a coordinate into range, or says there is nothing there" {
    const cases = [_]struct { v: i64, none: ?i64, pad: ?i64, repeat: ?i64, reflect: ?i64 }{
        // Inside, where every mode agrees and none of them touches it.
        .{ .v = 0, .none = 0, .pad = 0, .repeat = 0, .reflect = 0 },
        .{ .v = 3, .none = 3, .pad = 3, .repeat = 3, .reflect = 3 },
        // Past the far edge of a four-wide surface.
        .{ .v = 4, .none = null, .pad = 3, .repeat = 0, .reflect = 3 },
        .{ .v = 5, .none = null, .pad = 3, .repeat = 1, .reflect = 2 },
        .{ .v = 8, .none = null, .pad = 3, .repeat = 0, .reflect = 0 },
        // And before the near one, where the two periodic modes differ in
        // sign and a `@rem` would give something negative to index with.
        .{ .v = -1, .none = null, .pad = 0, .repeat = 3, .reflect = 0 },
        .{ .v = -4, .none = null, .pad = 0, .repeat = 0, .reflect = 3 },
        .{ .v = -5, .none = null, .pad = 0, .repeat = 3, .reflect = 3 },
    };
    for (cases) |c| {
        try testing.expectEqual(c.none, Extend.none.apply(c.v, 4));
        try testing.expectEqual(c.pad, Extend.pad.apply(c.v, 4));
        try testing.expectEqual(c.repeat, Extend.repeat.apply(c.v, 4));
        try testing.expectEqual(c.reflect, Extend.reflect.apply(c.v, 4));
    }
    // A surface with no extent has nothing to sample whatever the mode.
    for ([_]Extend{ .none, .pad, .repeat, .reflect }) |e| {
        try testing.expectEqual(@as(?i64, null), e.apply(0, 0));
    }
}

test "a surface pattern samples the picture it is given" {
    const alloc = testing.allocator;
    var tile = try Surface.init(.image_surface_rgba, alloc, 2, 2);
    defer tile.deinit(alloc);
    // Four distinguishable pixels, so that a sample landing in the wrong one
    // is visible rather than plausible.
    tile.putPixel(0, 0, .{ .rgba = .{ .r = 10, .g = 0, .b = 0, .a = 255 } });
    tile.putPixel(1, 0, .{ .rgba = .{ .r = 20, .g = 0, .b = 0, .a = 255 } });
    tile.putPixel(0, 1, .{ .rgba = .{ .r = 30, .g = 0, .b = 0, .a = 255 } });
    tile.putPixel(1, 1, .{ .rgba = .{ .r = 40, .g = 0, .b = 0, .a = 255 } });

    // Untransformed and repeating: the tile lies on the device grid.
    var p: SurfacePattern = .{ .surface = &tile, .extend = .repeat };
    try testing.expectEqual(@as(u8, 10), p.getPixel(0, 0).rgba.r);
    try testing.expectEqual(@as(u8, 20), p.getPixel(1, 0).rgba.r);
    try testing.expectEqual(@as(u8, 30), p.getPixel(0, 1).rgba.r);
    try testing.expectEqual(@as(u8, 40), p.getPixel(1, 1).rgba.r);
    // And again, one tile over in each direction.
    try testing.expectEqual(@as(u8, 10), p.getPixel(2, 2).rgba.r);
    try testing.expectEqual(@as(u8, 40), p.getPixel(-1, -1).rgba.r);

    // With nothing outside it, the same coordinates are empty.
    p.extend = .none;
    try testing.expectEqual(@as(u8, 10), p.getPixel(0, 0).rgba.r);
    try testing.expectEqual(@as(u8, 0), p.getPixel(2, 2).rgba.a);
    try testing.expectEqual(@as(u8, 0), p.getPixel(-1, 0).rgba.a);
}

test "a surface pattern's matrix says where the picture sits" {
    const alloc = testing.allocator;
    var tile = try Surface.init(.image_surface_rgba, alloc, 2, 2);
    defer tile.deinit(alloc);
    tile.putPixel(0, 0, .{ .rgba = .{ .r = 10, .g = 0, .b = 0, .a = 255 } });
    tile.putPixel(1, 0, .{ .rgba = .{ .r = 20, .g = 0, .b = 0, .a = 255 } });
    tile.putPixel(0, 1, .{ .rgba = .{ .r = 30, .g = 0, .b = 0, .a = 255 } });
    tile.putPixel(1, 1, .{ .rgba = .{ .r = 40, .g = 0, .b = 0, .a = 255 } });

    // Doubled: each of the tile's pixels covers two device pixels each way.
    var p: SurfacePattern = .{ .surface = &tile, .extend = .repeat };
    try p.setTransformation(Transformation.identity.scale(2, 2));
    try testing.expectEqual(@as(u8, 10), p.getPixel(0, 0).rgba.r);
    try testing.expectEqual(@as(u8, 10), p.getPixel(1, 1).rgba.r);
    try testing.expectEqual(@as(u8, 20), p.getPixel(2, 0).rgba.r);
    try testing.expectEqual(@as(u8, 40), p.getPixel(3, 3).rgba.r);

    // Moved: the matrix is where the picture *goes*, so the inverse is what
    // sampling uses and `setTransformation` is what inverts it.
    var q: SurfacePattern = .{ .surface = &tile, .extend = .none };
    try q.setTransformation(Transformation.identity.translate(5, 0));
    try testing.expectEqual(@as(u8, 10), q.getPixel(5, 0).rgba.r);
    try testing.expectEqual(@as(u8, 20), q.getPixel(6, 0).rgba.r);
    try testing.expectEqual(@as(u8, 0), q.getPixel(0, 0).rgba.a);

    // A matrix that collapses the plane cannot be inverted, and says so
    // rather than sampling something arbitrary.
    var bad: SurfacePattern = .{ .surface = &tile };
    try testing.expectError(
        error.InvalidMatrix,
        bad.setTransformation(Transformation.identity.scale(0, 0)),
    );
}

test "a shape filled with a surface pattern is tiled with it" {
    const alloc = testing.allocator;
    const painter = @import("painter.zig");
    const Path = @import("Path.zig");

    // A two-by-two tile: red, then transparent along one diagonal.
    var tile = try Surface.init(.image_surface_rgba, alloc, 2, 2);
    defer tile.deinit(alloc);
    tile.putPixel(0, 0, .{ .rgba = .{ .r = 255, .g = 0, .b = 0, .a = 255 } });
    tile.putPixel(1, 1, .{ .rgba = .{ .r = 255, .g = 0, .b = 0, .a = 255 } });

    var sfc = try Surface.init(.image_surface_rgba, alloc, 8, 8);
    defer sfc.deinit(alloc);

    var p: Path = .empty;
    defer p.deinit(alloc);
    try p.moveTo(alloc, 0, 0);
    try p.lineTo(alloc, 8, 0);
    try p.lineTo(alloc, 8, 8);
    try p.lineTo(alloc, 0, 8);
    try p.close(alloc);

    const sp: SurfacePattern = .{ .surface = &tile, .extend = .repeat };
    const source: Pattern = .{ .surface = sp };
    try painter.fill(alloc, &sfc, &source, p.nodes.items, .{ .anti_aliasing_mode = .none });

    // The tile repeats across the whole shape: every even cell painted, every
    // odd one left alone, eight pixels away just as at the origin.
    var y: i32 = 0;
    while (y < 8) : (y += 1) {
        var x: i32 = 0;
        while (x < 8) : (x += 1) {
            const got = sfc.getPixel(x, y).?.rgba;
            const want_paint = (@mod(x, 2) == @mod(y, 2));
            try testing.expectEqual(@as(u8, if (want_paint) 255 else 0), got.a);
        }
    }
}

test "the Mitchell weights sum to one and do not interpolate" {
    for ([_]f32{ 0, 0.25, 0.5, 0.9 }) |t| {
        const w = SurfacePattern.mitchellWeights(t);
        try testing.expectApproxEqAbs(@as(f32, 1), w[0] + w[1] + w[2] + w[3], 1e-6);
    }
    // At a pixel centre the neighbours still count for an eighteenth each,
    // which is the softening a translation is spared.
    const w = SurfacePattern.mitchellWeights(0);
    try testing.expectApproxEqAbs(@as(f32, 1.0 / 18.0), w[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 16.0 / 18.0), w[1], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1.0 / 18.0), w[2], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0), w[3], 1e-6);
}

/// A black pixel and a white one, side by side.
fn blackWhite(alloc: @import("std").mem.Allocator) !Surface {
    var s = try Surface.init(.image_surface_rgba, alloc, 2, 1);
    s.putPixel(0, 0, .{ .rgba = .{ .r = 0, .g = 0, .b = 0, .a = 255 } });
    s.putPixel(1, 0, .{ .rgba = .{ .r = 255, .g = 255, .b = 255, .a = 255 } });
    return s;
}

test "bicubic sampling is resvg's, to the level" {
    const alloc = testing.allocator;
    var bw = try blackWhite(alloc);
    defer bw.deinit(alloc);

    // Enlarged thirty-two times and sampled across the step. These are the
    // levels resvg 0.48 draws for the same picture at the same size, and a
    // Mitchell cubic with B = C = 1/3 is the curve that reproduces them.
    var p: SurfacePattern = .{ .surface = &bw, .extend = .pad, .filter = .bicubic };
    try p.setTransformation(Transformation.identity.scale(32, 32));
    const resvg = [_]u8{ 3, 12, 26, 44, 65, 89, 115, 140, 166, 190, 211, 229, 243, 252 };
    for (resvg, 0..) |want, i| {
        const x: i32 = 12 + 3 * @as(i32, @intCast(i));
        const got = p.getPixel(x, 16).rgba.r;
        try testing.expect(@abs(@as(i32, got) - want) <= 1);
    }
}

test "bilinear sampling is a straight ramp between centres" {
    const alloc = testing.allocator;
    var bw = try blackWhite(alloc);
    defer bw.deinit(alloc);
    var p: SurfacePattern = .{ .surface = &bw, .extend = .pad, .filter = .bilinear };
    try p.setTransformation(Transformation.identity.scale(4, 4));
    // Device pixels 0..7 cover the two source pixels; centres fall at 2 and
    // 6, held at the ends and ramping between.
    const want = [_]u8{ 0, 0, 32, 96, 159, 223, 255, 255 };
    for (want, 0..) |w, x| try testing.expectEqual(w, p.getPixel(@intCast(x), 0).rgba.r);
}

test "a translation is sampled exactly whatever the filter" {
    const alloc = testing.allocator;
    var bw = try blackWhite(alloc);
    defer bw.deinit(alloc);
    inline for (.{ Filter.bilinear, Filter.bicubic }) |f| {
        var p: SurfacePattern = .{ .surface = &bw, .extend = .none, .filter = f };
        // Half a pixel over, which a filter would blend into grey: device
        // centres 0.5 and 1.5 land at 0 and 1 in the picture, the two sides
        // of the step, and neither comes out anything in between.
        try p.setTransformation(Transformation.identity.translate(0.5, 0));
        try testing.expectEqual(@as(u8, 0), p.getPixel(0, 0).rgba.r);
        try testing.expectEqual(@as(u8, 255), p.getPixel(1, 0).rgba.r);
    }
}

test "a filtered colour never exceeds its alpha" {
    const alloc = testing.allocator;
    // Opaque white beside transparent: the step a cubic overshoots on. A
    // pre-multiplied colour above its alpha would read as brighter than
    // white to the compositor.
    var s = try Surface.init(.image_surface_rgba, alloc, 4, 1);
    defer s.deinit(alloc);
    s.putPixel(0, 0, .{ .rgba = .{ .r = 255, .g = 255, .b = 255, .a = 255 } });
    s.putPixel(1, 0, .{ .rgba = .{ .r = 255, .g = 255, .b = 255, .a = 255 } });
    inline for (.{ Filter.bilinear, Filter.bicubic }) |f| {
        var p: SurfacePattern = .{ .surface = &s, .extend = .none, .filter = f };
        try p.setTransformation(Transformation.identity.scale(7, 7));
        var x: i32 = -10;
        while (x < 40) : (x += 1) {
            const px = p.getPixel(x, 3).rgba;
            try testing.expect(px.r <= px.a and px.g <= px.a and px.b <= px.a);
        }
        // And under `none` the edge fades rather than stopping: somewhere
        // past the last white pixel is partly there.
        var partial = false;
        x = 14;
        while (x < 22) : (x += 1) {
            const a = p.getPixel(x, 3).rgba.a;
            if (a > 0 and a < 255) partial = true;
        }
        try testing.expect(partial);
    }
}
