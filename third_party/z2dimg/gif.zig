// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! GIF: a palette, LZW, and a container that turned out to be for animation.
//!
//! A file is a logical screen, a palette, and then a sequence of blocks:
//! images, extensions describing how to show them, and a trailer. The
//! extensions are where most of the format's later life happened — the
//! animation everybody knows it for is a graphic control extension in front of
//! each frame and an application extension nobody standardised saying how many
//! times to loop.
//!
//! ## One frame
//!
//! This decodes the first image and stops. A `decode` here answers with one
//! `z2d.Surface`, and an animation is a sequence of surfaces with delays and
//! disposal rules between them — a different shape of answer, and one this
//! library's API has nowhere to put. The first frame is what a still-image
//! decoder shows and what almost every GIF in the wild contains only one of.
//!
//! The surface is the *logical screen*, which a frame need not fill: a frame
//! has its own position and size, and what it does not cover is left
//! transparent rather than filled with the background colour the screen
//! descriptor names. That index is unreliable — writers leave it zero — and
//! transparent is the answer that composites correctly whatever a caller does
//! next.
//!
//! ## Interlacing
//!
//! A frame may be stored in four passes: every eighth row from 0, then every
//! eighth from 4, then every fourth from 2, then every second from 1. It
//! predates progressive JPEG and was for the same reason, a picture appearing
//! over a slow line. Reading it is a table; the trap is that the passes are
//! not all the same height, so a decoder counting rows rather than mapping
//! them gets the bottom of the image wrong.
//!
//! ## Transparency
//!
//! One palette index may be declared transparent by the graphic control
//! extension in front of the frame. It is an index and not a colour, so the
//! same colour at another index stays opaque, and a file may declare an index
//! its palette does not have — which means nothing and is ignored rather than
//! refused.

const std = @import("std");
const Io = std.Io;
const mem = std.mem;
const math = std.math;
const testing = std.testing;
const Allocator = mem.Allocator;

const z2d = @import("z2d");

const common = @import("common.zig");
const DecodeError = common.DecodeError;
const DecodeOptions = common.DecodeOptions;
const EncodeError = common.EncodeError;
const Info = common.Info;
const Limits = common.Limits;
const anim = @import("anim.zig");
const pixels = @import("pixels.zig");
const Rgba8 = pixels.Rgba8;

/// GIF's own LZW, which is not quite anybody else's.
pub const lzw = @import("gif/lzw.zig");

/// The two versions, which differ only in what extensions they allow. Both are
/// read the same way: an unknown extension is skipped by its own block
/// structure, which is the whole reason that structure exists.
pub const signature_87a = "GIF87a";
pub const signature_89a = "GIF89a";

const block_extension = 0x21;
const block_image = 0x2c;
const block_trailer = 0x3b;
const extension_graphic_control = 0xf9;
const extension_application = 0xff;

/// Where each interlace pass starts and how far it steps.
const interlace_passes = [_]struct { start: u32, step: u32 }{
    .{ .start = 0, .step = 8 },
    .{ .start = 4, .step = 8 },
    .{ .start = 2, .step = 4 },
    .{ .start = 1, .step = 2 },
};

/// What the logical screen descriptor said.
pub const Screen = struct {
    width: u32,
    height: u32,
    /// How many entries the global colour table has, or zero for none.
    global_colours: u32,
    /// The palette index the screen descriptor names as the background.
    ///
    /// Read and deliberately not used. Canvas this library has not drawn on
    /// is transparent, not this colour, and a disposal of "restore to
    /// background" clears rather than fills --- see `anim.Dispose.background`
    /// for whose behaviour that matches and whose it does not. It is kept
    /// because it is part of the header and because a caller that wants to
    /// honour it needs somewhere to have read it from.
    background: u8,
};

pub const Decoder = struct {
    screen: Screen,
    limits: Limits,
    /// The global palette, filled out to 256 entries with opaque black so that
    /// an index past the end of a short table is a colour rather than a read.
    palette: [256]Rgba8,
    /// What frames and canvas are made of. Set by whichever entry point built
    /// this, so that a caller's `DecodeOptions.surface_type` reaches the
    /// frames and not only the canvas.
    surface_type: z2d.surface.SurfaceType = pixels.naturalSurfaceType(true),
    /// The NETSCAPE application extension's raw value, if the file carried
    /// one at all. Null and zero mean different things here --- see
    /// `Animation.info` --- which is why this is optional.
    loop_count: ?u32 = null,

    /// Reads the header, the screen descriptor and the global colour table.
    pub fn init(r: *Io.Reader, limits: Limits) DecodeError!Decoder {
        var sig: [6]u8 = undefined;
        r.readSliceAll(&sig) catch |err| switch (err) {
            error.EndOfStream => return error.UnknownFormat,
            error.ReadFailed => |e| return e,
        };
        if (!mem.eql(u8, &sig, signature_87a) and !mem.eql(u8, &sig, signature_89a)) {
            return error.UnknownFormat;
        }

        const width = try r.takeInt(u16, .little);
        const height = try r.takeInt(u16, .little);
        const packed_fields = try r.takeByte();
        const background = try r.takeByte();
        _ = try r.takeByte(); // pixel aspect ratio, which nothing honours

        try limits.check(width, height);

        var self: Decoder = .{
            .screen = .{
                .width = width,
                .height = height,
                .global_colours = 0,
                .background = background,
            },
            .limits = limits,
            .palette = @splat(.rgb(0, 0, 0)),
        };

        if (packed_fields & 0x80 != 0) {
            self.screen.global_colours = @as(u32, 2) << @intCast(packed_fields & 0x07);
            try readPalette(r, &self.palette, self.screen.global_colours);
        }
        return self;
    }

    pub fn info(self: Decoder) Info {
        // A GIF may declare a transparent index and most do not, and knowing
        // which needs the extension in front of the first frame. `has_alpha`
        // is a property of the encoding rather than the image, and this
        // encoding carries transparency.
        return .{
            .format = .gif,
            .width = self.screen.width,
            .height = self.screen.height,
            .has_alpha = true,
            .surface_type = pixels.naturalSurfaceType(true),
            // Never anything else. A GIF has nowhere to declare a frame count
            // and its loop count sits in an extension that may be anywhere,
            // so the header this has read cannot say whether the file
            // animates --- and saying "no" would be a guess dressed as an
            // answer.
            .animation = .unknown,
        };
    }

    /// Reads blocks until the next image and decodes it, or null at the end
    /// of the file.
    ///
    /// The frame's surface belongs to the caller of this, which in practice
    /// is `Animation.next` --- it is the one that decides whether to hand it
    /// out borrowed or composite it and throw it away.
    fn nextFrame(
        self: *Decoder,
        gpa: Allocator,
        r: *Io.Reader,
        index: u32,
    ) DecodeError!?anim.Frame {
        var control: Control = .{};
        while (true) {
            const kind = r.takeByte() catch |err| switch (err) {
                // A file that ends before its trailer is truncated, and what
                // was decoded already is kept.
                error.EndOfStream => return null,
                error.ReadFailed => |e| return e,
            };
            switch (kind) {
                block_trailer => return null,
                block_extension => {
                    const label = try r.takeByte();
                    switch (label) {
                        extension_graphic_control => control = try readGraphicControl(r),
                        extension_application => try self.readApplication(r),
                        else => try skipSubBlocks(r),
                    }
                },
                block_image => return try self.readImage(gpa, r, control, index),
                // Writers pad with zero bytes between blocks, and a decoder
                // that refused them would refuse files every other one reads.
                0 => {},
                else => return error.InvalidData,
            }
        }
    }

    /// An application extension, of which one is worth reading.
    ///
    /// NETSCAPE2.0 is where a GIF's loop count lives: eleven bytes naming the
    /// extension, then a sub-block of three whose first byte is 1 and whose
    /// next two are the number of times to play, little-endian, with zero
    /// meaning forever. It is a convention rather than part of the format,
    /// and it is the only reason an animated GIF can repeat at all.
    fn readApplication(self: *Decoder, r: *Io.Reader) DecodeError!void {
        const len = r.takeByte() catch |err| switch (err) {
            error.EndOfStream => return,
            error.ReadFailed => |e| return e,
        };
        if (len != 11) {
            try r.discardAll(len);
            return skipSubBlocks(r);
        }
        var name: [11]u8 = undefined;
        r.readSliceAll(&name) catch |err| switch (err) {
            error.EndOfStream => return,
            error.ReadFailed => |e| return e,
        };
        if (!mem.eql(u8, &name, "NETSCAPE2.0") and !mem.eql(u8, &name, "ANIMEXTS1.0")) {
            return skipSubBlocks(r);
        }
        // The sub-blocks behind the name. Only a three-byte one beginning
        // with 1 says anything; a file with several of them is taking the
        // last, which is what the block loop does with everything else.
        while (true) {
            const sub = r.takeByte() catch |err| switch (err) {
                error.EndOfStream => return,
                error.ReadFailed => |e| return e,
            };
            if (sub == 0) return;
            if (sub == 3) {
                const tag = try r.takeByte();
                const count = try r.takeInt(u16, .little);
                // The last one wins. Nothing specifies what several should
                // mean --- the loop count is a convention, not part of the
                // format --- and taking the most recent is what wuffs does
                // and what the block loop does with every other repeated
                // thing here.
                if (tag == 1) self.loop_count = count;
                continue;
            }
            r.discardAll(sub) catch |err| switch (err) {
                error.EndOfStream => return,
                error.ReadFailed => |e| return e,
            };
        }
    }

    /// Reads one image block into a surface of its own and says where it
    /// goes.
    ///
    /// The surface is the frame **clipped to the logical screen**, which is
    /// the one thing here that bounds it. A frame may declare itself larger
    /// than the screen or sitting off the edge of it --- files exist where it
    /// does --- and the screen is the only rectangle `probe` checked against
    /// the limits, so materialising the frame at its declared size would let
    /// a header of ten bytes ask for four gigabytes that `probe` had already
    /// called reasonable. Clipping costs nothing real: the part outside the
    /// screen is outside the picture by definition, and the specification
    /// says a frame has to fit in the first place.
    ///
    /// The pixels outside the clip are still *decoded* --- the LZW stream has
    /// to be walked past them --- and simply not kept.
    fn readImage(
        self: *Decoder,
        gpa: Allocator,
        r: *Io.Reader,
        control: Control,
        index: u32,
    ) DecodeError!anim.Frame {
        const left = try r.takeInt(u16, .little);
        const top = try r.takeInt(u16, .little);
        const width = try r.takeInt(u16, .little);
        const height = try r.takeInt(u16, .little);
        const packed_fields = try r.takeByte();

        var palette = self.palette;
        if (packed_fields & 0x80 != 0) {
            const count = @as(u32, 2) << @intCast(packed_fields & 0x07);
            palette = @splat(.rgb(0, 0, 0));
            try readPalette(r, &palette, count);
        }
        if (control.transparent) |t| palette[t].a = 0;

        const interlaced = packed_fields & 0x40 != 0;

        // How much of the frame lands on the screen. A frame's position is
        // unsigned, so it can run off the right and the bottom and never off
        // the left or the top --- which is why the kept part always starts at
        // the frame's own origin and only its size is in question.
        const clip_w = @min(width, self.screen.width -| left);
        const clip_h = @min(height, self.screen.height -| top);

        var sfc: z2d.Surface = z2d.Surface.init(
            self.surface_type,
            gpa,
            @intCast(@max(clip_w, 1)),
            @intCast(@max(clip_h, 1)),
        ) catch |err| switch (err) {
            error.InvalidWidth, error.InvalidHeight => return error.InvalidData,
            error.OutOfMemory => |e| return e,
        };
        errdefer sfc.deinit(gpa);

        const min_code_bits = try r.takeByte();
        var decompressor = lzw.Decompressor.init(min_code_bits) catch return error.InvalidData;

        var painter: Painter = .{
            .sfc = &sfc,
            .palette = &palette,
            .width = width,
            .height = height,
            .clip_w = clip_w,
            .clip_h = clip_h,
            .interlaced = interlaced,
            .row = try gpa.alloc(Rgba8, @max(clip_w, 1)),
            // A frame of no area is not refused. It covers nothing, so it
            // draws nothing, and drawing nothing is not the same as being
            // malformed --- files exist with one, carrying pixel data for it
            // anyway. Saying the painter is finished before it starts stops
            // the decompressor at the first code rather than letting it walk
            // data that has nowhere to go.
            .done = width == 0 or height == 0 or clip_w == 0 or clip_h == 0,
        };
        defer gpa.free(painter.row);
        @memset(painter.row, .{ .r = 0, .g = 0, .b = 0, .a = 0 });

        // The compressed data, as sub-blocks.
        //
        // Two of the ways out of this loop leave the chain half-read: a frame
        // that fills before its data runs out, and a stream that says it has
        // ended before the last sub-block. Both are ordinary --- an encoder
        // writes the end code and then pads to a sub-block boundary --- and
        // for a still image neither mattered, because nothing read further.
        // For an animation the next frame is read from exactly here, so the
        // rest of the chain has to be stepped over or a sub-block's length
        // byte is read as the next block's kind.
        var half_read = false;
        var buf: [255]u8 = undefined;
        while (true) {
            const len = r.takeByte() catch |err| switch (err) {
                error.EndOfStream => break,
                error.ReadFailed => |e| return e,
            };
            if (len == 0) break;
            r.readSliceAll(buf[0..len]) catch |err| switch (err) {
                error.EndOfStream => break,
                error.ReadFailed => |e| return e,
            };
            decompressor.push(buf[0..len], &painter, Painter.emit) catch |err| {
                // The painter stops the decompressor once the frame is full,
                // which is not a failure.
                if (err == error.Full) {
                    half_read = true;
                    break;
                }
                if (err == error.InvalidData) return error.InvalidData;
                if (err == error.OutOfMemory) return error.OutOfMemory;
                return error.InvalidData;
            };
            if (decompressor.ended()) {
                half_read = true;
                break;
            }
        }
        if (half_read) try skipSubBlocks(r);
        painter.flush();

        return .{
            .surface = sfc,
            .x = left,
            .y = top,
            .width = width,
            .height = height,
            .delay_ms = control.delay_ms,
            .dispose = control.dispose,
            // A GIF frame is always drawn over what is there; its transparent
            // index is what shows the canvas through.
            .blend = .over,
            .index = index,
        };
    }
};

/// Turns palette indices into pixels, a row at a time, in whichever order the
/// frame is stored.
///
/// It paints into the frame's *own* surface, which is exactly the size of the
/// frame, so there is no clipping here and no notion of a screen: a frame that
/// hangs off the edge is clipped once, later, by the compositor. That is what
/// this used to do by hand, with a left edge, a visible width, a screen height
/// and a row-to-screen mapping, all of which are gone.
const Painter = struct {
    sfc: *z2d.Surface,
    palette: *const [256]Rgba8,
    /// The frame's width, which is how many pixels a row of it is --- all of
    /// which arrive, whether or not they are kept.
    width: u32,
    height: u32,
    /// How much of the frame lands on the screen, and so how large `sfc` is.
    /// Pixels past it are decoded and dropped.
    clip_w: u32,
    clip_h: u32,
    interlaced: bool,
    row: []Rgba8,

    /// How far into the current row, and which row of the frame it is.
    x: u32 = 0,
    line: u32 = 0,
    pass: usize = 0,
    done: bool = false,

    const Error = error{Full} || Allocator.Error;

    fn emit(self: *Painter, indices: []const u8) anyerror!void {
        for (indices) |index| {
            if (self.done) return error.Full;
            if (self.x < self.clip_w) self.row[self.x] = self.palette[index];
            self.x += 1;
            if (self.x == self.width) self.endRow();
        }
        // Said again on the way out, and this is the half that matters. A
        // frame filled by the last index of a batch would otherwise let the
        // decompressor read one more code before being told to stop, and a
        // file carrying an invalid code after a complete image would be
        // refused over bytes that were never needed. The image was finished
        // before they arrived.
        if (self.done) return error.Full;
    }

    fn endRow(self: *Painter) void {
        self.writeCurrent();
        self.x = 0;
        @memset(self.row, .{ .r = 0, .g = 0, .b = 0, .a = 0 });
        self.line += 1;
        if (self.interlaced) {
            // Each pass has its own height, which is what a decoder counting
            // rows rather than mapping them gets wrong.
            while (self.pass < interlace_passes.len) {
                const p = interlace_passes[self.pass];
                const rows = (self.height -| p.start + p.step - 1) / p.step;
                if (self.line < rows) break;
                self.pass += 1;
                self.line = 0;
            }
            if (self.pass == interlace_passes.len) self.done = true;
        } else if (self.line >= self.height) {
            self.done = true;
        }
    }

    /// Writes a partial last row, for a frame whose data ran out mid-row.
    fn flush(self: *Painter) void {
        if (self.x != 0 and !self.done) self.writeCurrent();
    }

    fn writeCurrent(self: *Painter) void {
        if (self.clip_w == 0) return;
        const y = self.frameRow() orelse return;
        if (y >= self.clip_h) return;
        pixels.writeRow(self.sfc, @intCast(y), self.row);
    }

    /// Which row of the frame the current row is, which for an interlaced
    /// frame is not the order they arrive in.
    fn frameRow(self: *const Painter) ?u32 {
        const within = if (self.interlaced) blk: {
            if (self.pass >= interlace_passes.len) return null;
            const p = interlace_passes[self.pass];
            break :blk p.start + self.line * p.step;
        } else self.line;
        if (within >= self.height) return null;
        return within;
    }
};

/// A palette of `count` entries, three bytes each, filled out to 256.
fn readPalette(r: *Io.Reader, palette: *[256]Rgba8, count: u32) DecodeError!void {
    if (count > 256) return error.InvalidData;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const red = try r.takeByte();
        const green = try r.takeByte();
        const blue = try r.takeByte();
        palette[i] = .rgb(red, green, blue);
    }
}

/// The graphic control extension, of which only the transparent index is used.
/// What a graphic control extension says about the frame behind it.
const Control = struct {
    /// The palette index to show through, if the extension named one.
    transparent: ?u8 = null,
    /// How long the frame is shown. The file counts hundredths of a second;
    /// this is milliseconds, which is what `anim.Frame` carries.
    delay_ms: u32 = 0,
    dispose: anim.Dispose = .keep,
};

fn readGraphicControl(r: *Io.Reader) DecodeError!Control {
    const len = try r.takeByte();
    if (len < 4) {
        try r.discardAll(len);
        try skipSubBlocks(r);
        return .{};
    }
    const packed_fields = try r.takeByte();
    const delay = try r.takeInt(u16, .little);
    const index = try r.takeByte();
    try r.discardAll(len - 4);
    try skipSubBlocks(r);
    return .{
        .transparent = if (packed_fields & 0x01 != 0) index else null,
        .delay_ms = @as(u32, delay) * 10,
        // Bits two to four. Four to seven are undefined, and a decoder that
        // refused them would refuse files over a field that means nothing;
        // "leave it" is what they get, which is what every other decoder
        // does with them.
        .dispose = switch ((packed_fields >> 2) & 0x07) {
            2 => .background,
            3 => .previous,
            else => .keep,
        },
    };
}

/// Steps over a chain of sub-blocks, which is how a decoder skips an extension
/// it does not know.
fn skipSubBlocks(r: *Io.Reader) DecodeError!void {
    while (true) {
        const len = r.takeByte() catch |err| switch (err) {
            error.EndOfStream => return,
            error.ReadFailed => |e| return e,
        };
        if (len == 0) return;
        r.discardAll(len) catch |err| switch (err) {
            error.EndOfStream => return,
            error.ReadFailed => |e| return e,
        };
    }
}

/// Reads the first frame of a GIF from `r`, producing a surface the caller
/// owns.
///
/// The same machinery the animation uses, stopped after one frame: a screen
/// to draw on, one frame decoded, one composite. Sharing it is what keeps the
/// still-image answer and the first frame of the animated answer from ever
/// disagreeing, which two implementations of the same thing eventually would.
pub fn decode(gpa: Allocator, r: *Io.Reader, opts: DecodeOptions) DecodeError!z2d.Surface {
    if (opts.orientation) |out| out.* = .top_left;
    if (opts.icc) |out| out.clearRetainingCapacity();

    var animation: Animation = try .init(r, gpa, .{
        .limits = opts.limits,
        .surface_type = opts.surface_type,
        .composite = true,
    });
    defer animation.deinit(gpa);

    _ = try animation.next(gpa);

    // The canvas is the answer, and it has to outlive the animation that
    // built it --- so it is taken rather than copied, and the animation is
    // left with nothing to release.
    var canvas = animation.canvas.?;
    animation.canvas = null;
    if (canvas.saved) |*sv| sv.deinit(canvas.gpa);
    return canvas.surface;
}

/// Reads only the screen descriptor, and says what it described.
pub fn probe(r: *Io.Reader, limits: Limits) DecodeError!Info {
    const decoder: Decoder = try .init(r, limits);
    return decoder.info();
}

// -- writing -----------------------------------------------------------------

/// How to write a GIF.
pub const EncodeOptions = struct {
    /// The most colours to write before giving up.
    ///
    /// A GIF's palette is at most 256 entries and this encoder does not
    /// quantise — see `encode` — so an image with more distinct colours than
    /// this is `error.Unsupported`. The default is the format's own limit.
    max_colours: u32 = 256,
};

/// Writes `sfc` as a single-frame GIF.
///
/// **Nothing here reduces colours**, for the same reason `xpm` does not:
/// quantising is a whole discipline, a palette chosen badly is worse than no
/// file, and a caller who wants one has opinions about how it should be chosen
/// that this library has no way to ask for. GIF's 256 colours make that bite
/// sooner than XPM's do — a photograph will not fit — and a photograph should
/// be a PNG or a JPEG.
///
/// Transparency is an index rather than a channel, so partial alpha is rounded
/// at half: a pixel more than half opaque keeps its colour and anything less
/// becomes the transparent index. The colour of what survives is
/// un-premultiplied first, since a surface stores a half-transparent red
/// darker than it looks.
pub fn encode(
    gpa: Allocator,
    sfc: *const z2d.Surface,
    w: *Io.Writer,
    opts: EncodeOptions,
) EncodeError!void {
    const width = sfc.getWidth();
    const height = sfc.getHeight();
    if (width < 1 or height < 1) return error.Unsupported;
    // Both dimensions go into a sixteen-bit field.
    if (width > math.maxInt(u16) or height > math.maxInt(u16)) return error.Unsupported;

    const uw: u32 = @intCast(width);
    const uh: u32 = @intCast(height);
    const limit = @min(opts.max_colours, 256);

    var indexed = try Indexed.init(gpa, sfc, limit);
    defer indexed.deinit(gpa);
    const palette = indexed.palette;
    const indices = indexed.indices;
    const transparent = indexed.transparent;
    const bits = indexed.bits();
    const table_len = @as(u32, 2) << bits;

    try w.writeAll(signature_89a);
    try w.writeInt(u16, @intCast(uw), .little);
    try w.writeInt(u16, @intCast(uh), .little);
    // A global colour table, eight bits of colour resolution, not sorted.
    try w.writeByte(0x80 | 0x70 | @as(u8, bits));
    try w.writeByte(0); // background index
    try w.writeByte(0); // pixel aspect ratio

    try writeTable(w, palette.items, table_len);

    if (transparent) |index| {
        try w.writeAll(&.{ block_extension, extension_graphic_control, 4 });
        try w.writeByte(0x01); // no disposal, no user input, transparency used
        try w.writeInt(u16, 0, .little); // no delay: there is one frame
        try w.writeByte(index);
        try w.writeByte(0); // the block terminator
    }

    try w.writeByte(block_image);
    try w.writeInt(u16, 0, .little); // left
    try w.writeInt(u16, 0, .little); // top
    try w.writeInt(u16, @intCast(uw), .little);
    try w.writeInt(u16, @intCast(uh), .little);
    try w.writeByte(0); // no local table, not interlaced

    // LZW wants at least two bits, whatever the palette size.
    const min_code_bits: u8 = @max(2, @as(u8, bits) + 1);
    try w.writeByte(min_code_bits);

    var compressed: std.ArrayList(u8) = .empty;
    defer compressed.deinit(gpa);
    {
        var c = lzw.Compressor.init(gpa, &compressed, min_code_bits) catch
            return error.Unsupported;
        defer c.deinit();
        c.push(indices) catch |err| switch (err) {
            error.InvalidData => return error.Unsupported,
            error.OutOfMemory => |e| return e,
        };
        c.finish() catch |err| switch (err) {
            error.InvalidData => return error.Unsupported,
            error.OutOfMemory => |e| return e,
        };
    }

    // Sub-blocks of at most 255 bytes, then the terminator.
    var at: usize = 0;
    while (at < compressed.items.len) {
        const n = @min(@as(usize, 255), compressed.items.len - at);
        try w.writeByte(@intCast(n));
        try w.writeAll(compressed.items[at..][0..n]);
        at += n;
    }
    try w.writeByte(0);
    try w.writeByte(block_trailer);
}

/// GIF has no partial transparency: a pixel is an index, and one index may be
/// transparent. So alpha is rounded, and a colour that survives is
/// un-premultiplied back to what it was.
fn flatten(px: Rgba8) Rgba8 {
    if (px.a < 128) return .{ .r = 0, .g = 0, .b = 0, .a = 0 };
    if (px.a == 255) return .rgb(px.r, px.g, px.b);
    const a: u32 = px.a;
    return .rgb(
        @intCast(@min(255, (@as(u32, px.r) * 255 + a / 2) / a)),
        @intCast(@min(255, (@as(u32, px.g) * 255 + a / 2) / a)),
        @intCast(@min(255, (@as(u32, px.b) * 255 + a / 2) / a)),
    );
}

fn indexOf(palette: []const Rgba8, colour: Rgba8) ?u8 {
    for (palette, 0..) |c, i| {
        if (std.meta.eql(c, colour)) return @intCast(i);
    }
    return null;
}

// -- animation ---------------------------------------------------------------

/// A GIF played frame by frame.
///
/// See `anim` for the model this implements and for why frames come out
/// un-composited alongside the canvas rather than instead of it.
pub const Animation = struct {
    decoder: Decoder,
    r: *Io.Reader,
    opts: anim.Options,
    canvas: ?anim.Canvas,
    /// The frame handed out last, still owned here and released when the next
    /// one is read.
    held: ?anim.Frame = null,
    index: u32 = 0,
    /// Summed over every frame decoded so far, against
    /// `Limits.max_total_pixels`. A GIF frame header is ten bytes and may
    /// declare a full-screen frame, so the count of frames is the bomb and
    /// this is what bounds it.
    total_pixels: u64 = 0,

    pub fn init(r: *Io.Reader, gpa: Allocator, opts: anim.Options) DecodeError!Animation {
        var decoder: Decoder = try .init(r, opts.limits);
        decoder.surface_type = opts.surface_type orelse decoder.info().surface_type;

        var canvas: ?anim.Canvas = null;
        if (opts.composite) {
            canvas = try anim.Canvas.init(
                gpa,
                decoder.surface_type,
                decoder.screen.width,
                decoder.screen.height,
            );
        }
        return .{ .decoder = decoder, .r = r, .opts = opts, .canvas = canvas };
    }

    pub fn deinit(self: *Animation, gpa: Allocator) void {
        if (self.held) |*f| f.surface.deinit(gpa);
        if (self.canvas) |*c| c.deinit();
        self.* = undefined;
    }

    /// What the file said about the animation as a whole.
    ///
    /// The loop count is only true once a frame has been read: it lives in an
    /// application extension which, by convention, sits in front of the first
    /// frame, but nothing in the format requires it to.
    pub fn info(self: *const Animation) anim.Info {
        return .{
            // GIF counts repeats *after* the first play, and a file with no
            // loop count is played once. `anim.Info.loop_count` counts plays,
            // APNG's way, so both cases convert: absent is one play, a
            // declared zero is forever, and a declared n is n plus the play
            // it excluded. Checked against wuffs, whose NIA footer records
            // three for a file whose GIF extension says two.
            .loop_count = if (self.decoder.loop_count) |n|
                (if (n == 0) 0 else n + 1)
            else
                1,
            // A GIF has nowhere to declare how many frames it has, so the
            // only way to know is to reach the end.
            .frames = null,
        };
    }

    /// The canvas as it stands after the last frame returned, or null if this
    /// was built with compositing off.
    pub fn canvasSurface(self: *const Animation) ?*const z2d.Surface {
        if (self.canvas) |*c| return &c.surface;
        return null;
    }

    /// The next frame, un-composited, or null at the end of the animation.
    ///
    /// The surface belongs to this and is released by the following call.
    /// `anim.Frame.toOwned` takes a copy that outlives it.
    pub fn next(self: *Animation, gpa: Allocator) DecodeError!?anim.Frame {
        if (self.held) |*f| {
            f.surface.deinit(gpa);
            self.held = null;
        }
        if (self.index >= self.opts.limits.max_frames) return error.ImageTooLarge;

        var frame = try self.decoder.nextFrame(gpa, self.r, self.index) orelse return null;
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
};

/// Reads a GIF as an animation.
pub fn animate(gpa: Allocator, r: *Io.Reader, opts: anim.Options) DecodeError!Animation {
    return Animation.init(r, gpa, opts);
}

/// A surface reduced to palette indices.
///
/// Shared by the still encoder and the animated one so that the two cannot
/// come to disagree about what a GIF's colours are --- which is the sort of
/// thing two copies of twenty-five lines eventually do.
const Indexed = struct {
    /// The colours, in the order they are first met, so that a file written
    /// twice is the same both times.
    palette: std.ArrayList(Rgba8),
    /// One index a pixel, row-major.
    indices: []u8,
    /// The entry that is fully transparent, if the image has one. GIF's
    /// transparency is an index rather than a channel, so it takes a palette
    /// entry of its own.
    transparent: ?u8,

    fn init(gpa: Allocator, sfc: *const z2d.Surface, limit: u32) EncodeError!Indexed {
        const uw: u32 = @intCast(sfc.getWidth());
        const uh: u32 = @intCast(sfc.getHeight());

        var palette: std.ArrayList(Rgba8) = .empty;
        errdefer palette.deinit(gpa);
        var transparent: ?u8 = null;

        const row = try gpa.alloc(Rgba8, uw);
        defer gpa.free(row);
        const indices = try gpa.alloc(u8, @as(usize, uw) * uh);
        errdefer gpa.free(indices);

        var y: u32 = 0;
        while (y < uh) : (y += 1) {
            pixels.readRow(row, sfc, @intCast(y));
            for (row, 0..) |px, x| {
                const flat = flatten(px);
                const found = indexOf(palette.items, flat) orelse blk: {
                    if (palette.items.len == limit) return error.Unsupported;
                    try palette.append(gpa, flat);
                    const at: u8 = @intCast(palette.items.len - 1);
                    if (flat.a == 0) transparent = at;
                    break :blk at;
                };
                indices[@as(usize, y) * uw + x] = found;
            }
        }
        return .{ .palette = palette, .indices = indices, .transparent = transparent };
    }

    fn deinit(self: *Indexed, gpa: Allocator) void {
        self.palette.deinit(gpa);
        gpa.free(self.indices);
        self.* = undefined;
    }

    /// The colour table size, as the exponent the format writes: a table is a
    /// power of two entries, and at least two.
    fn bits(self: Indexed) u3 {
        return tableBits(self.palette.items.len);
    }
};

/// The exponent a table of `count` colours is written with.
fn tableBits(count: usize) u3 {
    var n: u3 = 1;
    while ((@as(u32, 2) << n) < count) n += 1;
    return n;
}

// -- writing an animation ----------------------------------------------------

/// How to write an animated GIF.
pub const EncodeAnimationOptions = struct {
    /// The logical screen every frame is placed on.
    width: u32,
    height: u32,

    /// How many times to play, zero for forever.
    ///
    /// `anim.Info`'s meaning --- the number of plays --- and converted on the
    /// way out, because GIF counts the repeats *after* the first and has a
    /// third case its number cannot express: a file played exactly once is
    /// one with no loop extension at all, since a written zero means forever.
    loop_count: u32 = 1,

    /// The most colours a frame may have before it is refused.
    ///
    /// As `EncodeOptions.max_colours`, and for the same reason: this does not
    /// quantise. Each frame is counted separately, so an animation may use
    /// far more than 256 colours overall as long as no single frame does.
    max_colours: u32 = 256,

    /// The global colour table, for a caller that knows the whole animation's
    /// colours before writing any of it.
    ///
    /// **Worth supplying, and here is why.** GIF puts its global table in the
    /// header, before any frame, so an encoder writing forward has only the
    /// first frame to build one from --- and every later frame using a colour
    /// that frame did not have must then carry a table of its own, up to
    /// seven hundred and sixty-eight bytes each. Transcoding a fifteen-frame
    /// animation that way spent more than half the file on palettes.
    ///
    /// A caller holding all the frames does know, and can union their colours
    /// and pass the result. Left null, the first frame's colours are the
    /// global table, which is the best a streaming encoder can do on its own.
    ///
    /// At most 256 entries; more is `error.Unsupported`. A frame using a
    /// colour that is not in here still gets a local table, so this is a size
    /// optimisation and never a constraint on what can be written.
    palette: ?[]const Rgba8 = null,
};

/// Writes an animated GIF a frame at a time.
///
/// Frames are written **as they are given** --- rectangle, delay and disposal
/// --- so a decode and an encode make a lossless pipe rather than a stack of
/// full-screen pictures. GIF has no blend rule to honour: a frame is always
/// drawn over what is there, and the transparent index is what lets the
/// screen show through.
///
/// The first frame's colours become the global table, and any later frame
/// whose colours are not all in it carries a local table of its own. That is
/// what lets an animation hold more than 256 colours without this having to
/// quantise --- which it still does not do.
pub const AnimationEncoder = struct {
    w: *Io.Writer,
    opts: EncodeAnimationOptions,
    /// The global colour table, from the first frame.
    global: std.ArrayList(Rgba8) = .empty,
    global_bits: u3 = 1,
    started: bool = false,

    pub fn init(w: *Io.Writer, opts: EncodeAnimationOptions) EncodeError!AnimationEncoder {
        if (opts.width == 0 or opts.height == 0) return error.Unsupported;
        // Both dimensions go into a sixteen-bit field.
        if (opts.width > math.maxInt(u16) or opts.height > math.maxInt(u16)) return error.Unsupported;
        return .{ .w = w, .opts = opts };
    }

    pub fn deinit(self: *AnimationEncoder, gpa: Allocator) void {
        self.global.deinit(gpa);
        self.* = undefined;
    }

    /// Writes one frame.
    pub fn frame(self: *AnimationEncoder, gpa: Allocator, f: anim.Frame) EncodeError!void {
        const fw: u32 = @intCast(f.surface.getWidth());
        const fh: u32 = @intCast(f.surface.getHeight());
        if (fw == 0 or fh == 0) return error.Unsupported;
        if (f.x < 0 or f.y < 0) return error.Unsupported;
        const fx: u32 = @intCast(f.x);
        const fy: u32 = @intCast(f.y);
        if (fx > math.maxInt(u16) or fy > math.maxInt(u16)) return error.Unsupported;
        // A frame is allowed to hang off the screen --- this library reads
        // files where one does --- but writing one would be choosing to
        // produce what every decoder has to guess about.
        if (fx > self.opts.width or fy > self.opts.height or
            fw > self.opts.width - fx or fh > self.opts.height - fy) return error.Unsupported;

        var indexed = try Indexed.init(gpa, &f.surface, @min(self.opts.max_colours, 256));
        defer indexed.deinit(gpa);

        if (!self.started) {
            if (self.opts.palette) |supplied| {
                if (supplied.len == 0 or supplied.len > 256) return error.Unsupported;
                try self.global.appendSlice(gpa, supplied);
            } else {
                try self.global.appendSlice(gpa, indexed.palette.items);
            }
            self.global_bits = tableBits(self.global.items.len);
            try self.writeHeader();
            self.started = true;
        }

        // A frame whose colours are all in the global table needs no table of
        // its own, which for an animation that keeps one palette throughout
        // saves up to seven hundred and sixty-eight bytes a frame.
        const remapped = try self.remapToGlobal(gpa, indexed);
        defer if (remapped) |r| gpa.free(r);

        const local: ?Indexed = if (remapped == null) indexed else null;
        const indices = remapped orelse indexed.indices;
        const transparent = if (local) |l| l.transparent else self.globalTransparent();

        try self.writeGraphicControl(f, transparent);

        try self.w.writeByte(block_image);
        try self.w.writeInt(u16, @intCast(fx), .little);
        try self.w.writeInt(u16, @intCast(fy), .little);
        try self.w.writeInt(u16, @intCast(fw), .little);
        try self.w.writeInt(u16, @intCast(fh), .little);
        if (local) |l| {
            try self.w.writeByte(0x80 | @as(u8, l.bits()));
            try writeTable(self.w, l.palette.items, @as(u32, 2) << l.bits());
        } else {
            try self.w.writeByte(0);
        }

        const bits = if (local) |l| l.bits() else self.global_bits;
        try self.writeLzw(gpa, indices, bits);
    }

    /// Ends the file.
    pub fn finish(self: *AnimationEncoder) EncodeError!void {
        // A GIF with no frames is still a GIF: a screen and a trailer, which
        // this library reads back as an animation of none.
        if (!self.started) try self.writeHeader();
        try self.w.writeByte(block_trailer);
    }

    fn writeHeader(self: *AnimationEncoder) EncodeError!void {
        try self.w.writeAll(signature_89a);
        try self.w.writeInt(u16, @intCast(self.opts.width), .little);
        try self.w.writeInt(u16, @intCast(self.opts.height), .little);
        if (self.global.items.len == 0) {
            // Nothing to put in a global table, which happens only for an
            // animation with no frames at all.
            try self.w.writeByte(0x70);
            try self.w.writeByte(0);
            try self.w.writeByte(0);
            return;
        }
        try self.w.writeByte(0x80 | 0x70 | @as(u8, self.global_bits));
        try self.w.writeByte(0); // background index
        try self.w.writeByte(0); // pixel aspect ratio
        try writeTable(self.w, self.global.items, @as(u32, 2) << self.global_bits);

        // The loop extension, and the three cases GIF's one number has to
        // carry between them. A file played once has no extension: a written
        // zero means forever, so "once" cannot be spelled and is spelled by
        // saying nothing.
        if (self.opts.loop_count != 1) {
            const repeats: u16 = if (self.opts.loop_count == 0)
                0
            else
                @intCast(@min(self.opts.loop_count - 1, math.maxInt(u16)));
            try self.w.writeAll(&.{ block_extension, extension_application, 11 });
            try self.w.writeAll("NETSCAPE2.0");
            try self.w.writeAll(&.{ 3, 1 });
            try self.w.writeInt(u16, repeats, .little);
            try self.w.writeByte(0);
        }
    }

    /// This frame's indices in terms of the global table, or null if some
    /// colour of it is not in there.
    fn remapToGlobal(self: *AnimationEncoder, gpa: Allocator, indexed: Indexed) EncodeError!?[]u8 {
        var map: [256]u8 = undefined;
        for (indexed.palette.items, 0..) |colour, i| {
            map[i] = indexOf(self.global.items, colour) orelse return null;
        }
        const out = try gpa.alloc(u8, indexed.indices.len);
        errdefer gpa.free(out);
        for (indexed.indices, out) |from, *to| to.* = map[from];
        return out;
    }

    fn globalTransparent(self: *const AnimationEncoder) ?u8 {
        for (self.global.items, 0..) |colour, i| {
            if (colour.a == 0) return @intCast(i);
        }
        return null;
    }

    fn writeGraphicControl(
        self: *AnimationEncoder,
        f: anim.Frame,
        transparent: ?u8,
    ) EncodeError!void {
        const dispose: u8 = switch (f.dispose) {
            .keep => 1,
            .background => 2,
            .previous => 3,
        };
        const packed_fields: u8 = (dispose << 2) | (if (transparent != null) @as(u8, 1) else 0);
        // Hundredths of a second, to the nearest, which is all the format has.
        const delay: u16 = @intCast(@min((f.delay_ms + 5) / 10, math.maxInt(u16)));

        try self.w.writeAll(&.{ block_extension, extension_graphic_control, 4 });
        try self.w.writeByte(packed_fields);
        try self.w.writeInt(u16, delay, .little);
        try self.w.writeByte(transparent orelse 0);
        try self.w.writeByte(0);
    }

    fn writeLzw(self: *AnimationEncoder, gpa: Allocator, indices: []const u8, bits: u3) EncodeError!void {
        // LZW wants at least two bits, whatever the palette size.
        const min_code_bits: u8 = @max(2, @as(u8, bits) + 1);
        try self.w.writeByte(min_code_bits);

        var compressed: std.ArrayList(u8) = .empty;
        defer compressed.deinit(gpa);
        {
            var c = lzw.Compressor.init(gpa, &compressed, min_code_bits) catch
                return error.Unsupported;
            defer c.deinit();
            c.push(indices) catch |err| switch (err) {
                error.InvalidData => return error.Unsupported,
                error.OutOfMemory => |e| return e,
            };
            c.finish() catch |err| switch (err) {
                error.InvalidData => return error.Unsupported,
                error.OutOfMemory => |e| return e,
            };
        }

        var at: usize = 0;
        while (at < compressed.items.len) {
            const n = @min(@as(usize, 255), compressed.items.len - at);
            try self.w.writeByte(@intCast(n));
            try self.w.writeAll(compressed.items[at..][0..n]);
            at += n;
        }
        try self.w.writeByte(0);
    }
};

/// A colour table, padded to the power of two the header declared.
fn writeTable(w: *Io.Writer, palette: []const Rgba8, table_len: u32) EncodeError!void {
    for (0..table_len) |i| {
        const c = if (i < palette.len) palette[i] else Rgba8.rgb(0, 0, 0);
        try w.writeAll(&.{ c.r, c.g, c.b });
    }
}

/// Begins an animated GIF.
pub fn encodeAnimation(w: *Io.Writer, opts: EncodeAnimationOptions) EncodeError!AnimationEncoder {
    return AnimationEncoder.init(w, opts);
}
