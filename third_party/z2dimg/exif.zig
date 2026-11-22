// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! EXIF, as far as this library reads it: which way up the image goes.
//!
//! EXIF is a TIFF file with no image in it, carried inside some other file's
//! metadata — JPEG puts it in an `APP1` segment behind the marker `Exif\0\0`,
//! and PNG Third Edition puts the same block in an `eXIf` chunk. So this is a
//! module of its own rather than part of either codec, and it knows nothing
//! about markers or chunks: it is handed a block and reads it.
//!
//! ## Only orientation, and only reading it
//!
//! A camera that is turned on its side records the picture the way the sensor
//! saw it and writes down which way the camera was held. Every other tag EXIF
//! defines — the exposure, the lens, the time, the place — describes the
//! photograph rather than the pixels, and a library that turns bytes into a
//! surface has nothing to do with it. Orientation is the exception: get it
//! wrong and the image is displayed sideways.
//!
//! Writing is the same one tag and nothing else. `writeOrientation` builds the
//! smallest block that says which way up an image goes, which is twenty-six
//! bytes, and the encoders put it where their format keeps one. Every other
//! tag a camera wrote — the exposure, the lens, the time, the place — is lost
//! by a decode here, and inventing a block that carried only orientation while
//! claiming to be the original file's metadata would be worse than saying so.
//!
//! What the tag *means* on the way out is the caller's to decide. This library
//! rotates nothing, so an encoder asked to write `.right_top` writes it and
//! makes no claim about the pixels beside it; a caller who has already turned
//! the image the right way up wants `.top_left` or nothing at all.
//!
//! ## Forward only
//!
//! A TIFF is a structure of offsets, and reading one usually means seeking
//! about inside it. This reads it in a single forward pass instead, because
//! that is what a sans-I/O decoder can do without either buffering a block
//! that may be megabytes of thumbnail or holding a reader it is allowed to
//! seek. An offset that points backwards is not followed — a real file's
//! `IFD0` follows its header immediately — and the cost is that a deliberately
//! shuffled block reports no orientation rather than being chased around.
//!
//! ## Malformed input is not an error
//!
//! Every structural problem here answers `null`, not an error. Metadata is
//! decoration: a camera that wrote a broken `APP1` segment fifteen years ago
//! still wrote a perfectly good photograph, and refusing to decode it would
//! serve nobody. Only a failure of the underlying stream propagates, and
//! running out of input inside a block the container said was there means the
//! *file* is truncated, which is the container's business rather than this
//! module's.

const std = @import("std");
const Io = std.Io;
const mem = std.mem;
const testing = std.testing;

/// Which corner of the stored image the first row and column belong in, which
/// is EXIF tag 0x0112 and the one thing this module reads.
///
/// The names are the specification's, and read as "the zeroth row is at the
/// visual *top* and the zeroth column is at the visual *left*", which is the
/// ordinary case and the value 1.
pub const Orientation = enum(u8) {
    top_left = 1,
    top_right = 2,
    bottom_right = 3,
    bottom_left = 4,
    left_top = 5,
    right_top = 6,
    right_bottom = 7,
    left_bottom = 8,

    /// Whether displaying this image correctly swaps its width and height.
    ///
    /// True for the four that involve a quarter turn. A caller laying out a
    /// thumbnail grid from `Info` alone needs this before it decodes anything.
    pub fn swapsDimensions(self: Orientation) bool {
        return switch (self) {
            .top_left, .top_right, .bottom_right, .bottom_left => false,
            .left_top, .right_top, .right_bottom, .left_bottom => true,
        };
    }

    /// What to do to the stored pixels to display them the right way up.
    ///
    /// Mirroring is applied first, then the rotation clockwise. Every
    /// orientation decomposes this way — the eight values are the four
    /// rotations times mirrored or not — and giving the decomposition rather
    /// than the tag saves every caller working it out.
    pub fn transform(self: Orientation) Transform {
        return switch (self) {
            .top_left => .{ .mirror = false, .rotate = .none },
            .top_right => .{ .mirror = true, .rotate = .none },
            .bottom_right => .{ .mirror = false, .rotate = .half_turn },
            .bottom_left => .{ .mirror = true, .rotate = .half_turn },
            .left_top => .{ .mirror = true, .rotate = .clockwise },
            .right_top => .{ .mirror = false, .rotate = .clockwise },
            .right_bottom => .{ .mirror = true, .rotate = .anticlockwise },
            .left_bottom => .{ .mirror = false, .rotate = .anticlockwise },
        };
    }
};

/// An orientation as something to do rather than something to look up.
pub const Transform = struct {
    /// Mirror left to right, before rotating.
    mirror: bool,
    rotate: enum { none, clockwise, half_turn, anticlockwise },
};

/// How many bytes `writeOrientation` fills.
///
/// A byte order mark, the magic 42, the offset of the first directory, a count
/// of one, one twelve-byte entry, and the four bytes that say no directory
/// follows.
pub const orientation_block_len = 2 + 2 + 4 + 2 + entry_len + 4;

/// Builds the smallest EXIF block that says which way up an image goes.
///
/// Big-endian, because a block this size gains nothing from matching the
/// host's byte order and `MM` is the one a person reading a hex dump will
/// recognise. The reader above takes either.
///
/// What comes back is the TIFF block alone. A JPEG puts `Exif\0\0` in front
/// of it inside an `APP1` segment and PNG carries it bare in an `eXIf` chunk,
/// which is the encoders' business rather than this function's.
pub fn writeOrientation(out: *[orientation_block_len]u8, o: Orientation) void {
    var w: Io.Writer = .fixed(out);
    w.writeAll("MM") catch unreachable;
    w.writeInt(u16, 42, .big) catch unreachable;
    w.writeInt(u32, 8, .big) catch unreachable; // the directory follows the header
    w.writeInt(u16, 1, .big) catch unreachable; // one entry
    w.writeInt(u16, orientation_tag, .big) catch unreachable;
    w.writeInt(u16, type_short, .big) catch unreachable;
    w.writeInt(u32, 1, .big) catch unreachable; // one value
    // A `SHORT` that fits in the entry sits at the start of the four value
    // bytes, and the other two are padding.
    w.writeInt(u16, @backingInt(o), .big) catch unreachable;
    w.writeInt(u16, 0, .big) catch unreachable;
    w.writeInt(u32, 0, .big) catch unreachable; // no directory after this one
}

/// The tag that says which way up, in the only IFD that carries it.
const orientation_tag = 0x0112;

/// TIFF's type codes, of which only `short` matters here: orientation is a
/// single `SHORT`, which is small enough to sit in the entry itself rather
/// than at an offset, which is the whole reason a forward-only pass can read
/// it at all.
const type_short = 3;

/// One entry of an image file directory is twelve bytes: tag, type, count,
/// and four bytes that are either the value or where to find it.
const entry_len = 12;

/// Reads an EXIF block of exactly `len` bytes and says what it says about
/// orientation.
///
/// Consumes the whole block whatever it finds, so that the caller's framing —
/// a JPEG segment, a PNG chunk and its checksum — is undisturbed. A block that
/// is not EXIF, or is EXIF and says nothing about orientation, or is malformed
/// in any of the ways a file written by a camera in 2008 can be malformed,
/// answers `null`.
pub fn readOrientation(r: *Io.Reader, len: u32) Io.Reader.Error!?Orientation {
    var left: u32 = len;
    const found = scan(r, &left) catch |err| switch (err) {
        // The block ran out inside itself, which says the block is malformed
        // and not that the stream is. There may still be bytes of it left for
        // the caller's framing, so fall through to the discard below.
        error.EndOfStream => null,
        error.ReadFailed => |e| return e,
    };
    try r.discardAll(left);
    return found;
}

/// The pass itself, which leaves `left` saying how much of the block it did
/// not consume.
fn scan(r: *Io.Reader, left: *u32) (Io.Reader.Error || error{EndOfStream})!?Orientation {
    // JPEG hands over the `Exif\0\0` that identifies the segment, since an
    // `APP1` may just as well be XMP; PNG's chunk is the TIFF block alone.
    // Both are accepted, because encoders exist that write the marker into the
    // chunk as well.
    const first = try take(r, left, 2);
    var order_bytes: [2]u8 = first[0..2].*;
    if (mem.eql(u8, &order_bytes, "Ex")) {
        const rest = try take(r, left, 4);
        if (!mem.eql(u8, rest[0..4], "if\x00\x00")) return null;
        order_bytes = (try take(r, left, 2))[0..2].*;
    }

    const endian: std.builtin.Endian = if (mem.eql(u8, &order_bytes, "II"))
        .little
    else if (mem.eql(u8, &order_bytes, "MM"))
        .big
    else
        return null;

    // Everything after this is measured from the byte order mark, which has
    // already been read, so the count starts at two.
    var at: u32 = 2;

    if (readInt(u16, try take(r, left, 2), endian) != 42) return null;
    at += 2;

    const ifd0 = readInt(u32, try take(r, left, 4), endian);
    at += 4;
    if (ifd0 < at) return null; // backwards, which nothing real is
    try skip(r, left, ifd0 - at);
    at = ifd0;

    const count = readInt(u16, try take(r, left, 2), endian);
    at += 2;
    // A directory longer than the block it is in is a malformed block rather
    // than a directory to read part of.
    if (@as(u32, count) * entry_len > left.*) return null;

    for (0..count) |_| {
        const entry = try take(r, left, entry_len);
        const tag = readInt(u16, entry[0..2], endian);
        if (tag != orientation_tag) continue;
        if (readInt(u16, entry[2..4], endian) != type_short) return null;
        if (readInt(u32, entry[4..8], endian) != 1) return null;
        // A `SHORT` that fits in the entry sits at its start, whichever way
        // round the file is: the four value bytes are a little field of their
        // own and the unused half is padding at the end.
        const value = readInt(u16, entry[8..10], endian);
        if (value < 1 or value > 8) return null;
        return @fromBackingInt(@intCast(value));
    }
    return null;
}

/// Takes `n` bytes of the block, refusing to read past its end.
fn take(r: *Io.Reader, left: *u32, n: u32) (Io.Reader.Error || error{EndOfStream})![]const u8 {
    if (n > left.*) return error.EndOfStream;
    const bytes = try r.take(n);
    left.* -= n;
    return bytes;
}

/// Discards `n` bytes of the block.
fn skip(r: *Io.Reader, left: *u32, n: u32) (Io.Reader.Error || error{EndOfStream})!void {
    if (n > left.*) return error.EndOfStream;
    try r.discardAll(n);
    left.* -= n;
}

/// `std.mem.readInt` over a slice whose length is known only at run time,
/// which is what `Reader.take` gives back.
fn readInt(T: type, bytes: []const u8, endian: std.builtin.Endian) T {
    const n = @divExact(@typeInfo(T).int.bits, 8);
    return mem.readInt(T, bytes[0..n], endian);
}

// -- tests -------------------------------------------------------------------

/// Builds an EXIF block the way a camera would: a byte order mark, the magic
/// 42, an offset to the first directory, and that directory's entries.
fn buildBlock(
    buf: []u8,
    endian: std.builtin.Endian,
    prefix: bool,
    entries: []const [2]u16,
) []const u8 {
    var w: Io.Writer = .fixed(buf);
    if (prefix) w.writeAll("Exif\x00\x00") catch unreachable;
    w.writeAll(if (endian == .little) "II" else "MM") catch unreachable;
    w.writeInt(u16, 42, endian) catch unreachable;
    w.writeInt(u32, 8, endian) catch unreachable;
    w.writeInt(u16, @intCast(entries.len), endian) catch unreachable;
    for (entries) |e| {
        w.writeInt(u16, e[0], endian) catch unreachable; // tag
        w.writeInt(u16, type_short, endian) catch unreachable;
        w.writeInt(u32, 1, endian) catch unreachable; // count
        w.writeInt(u16, e[1], endian) catch unreachable; // value
        w.writeInt(u16, 0, endian) catch unreachable; // and its padding
    }
    w.writeInt(u32, 0, endian) catch unreachable; // no next directory
    return w.buffered();
}

fn orientationOf(block: []const u8) !?Orientation {
    var r: Io.Reader = .fixed(block);
    const found = try readOrientation(&r, @intCast(block.len));
    // Whatever it found, the whole block must have been consumed: the caller's
    // framing depends on it.
    try testing.expectEqual(@as(usize, 0), r.bufferedLen());
    return found;
}

test "orientation, either way round and with or without the JPEG marker" {
    var buf: [256]u8 = undefined;
    for ([_]std.builtin.Endian{ .little, .big }) |endian| {
        for ([_]bool{ false, true }) |prefix| {
            for (1..9) |value| {
                const block = buildBlock(&buf, endian, prefix, &.{
                    .{ 0x010f, 7 }, // Make, which is not what is wanted
                    .{ orientation_tag, @intCast(value) },
                    .{ 0x0128, 2 }, // ResolutionUnit, after it
                });
                try testing.expectEqual(
                    @as(?Orientation, @fromBackingInt(@intCast(value))),
                    try orientationOf(block),
                );
            }
        }
    }
}

test "a directory with no orientation in it" {
    var buf: [256]u8 = undefined;
    const block = buildBlock(&buf, .little, true, &.{ .{ 0x010f, 7 }, .{ 0x0128, 2 } });
    try testing.expectEqual(@as(?Orientation, null), try orientationOf(block));
}

test "an empty directory" {
    var buf: [256]u8 = undefined;
    const block = buildBlock(&buf, .big, false, &.{});
    try testing.expectEqual(@as(?Orientation, null), try orientationOf(block));
}

test "what is not EXIF at all" {
    // XMP, which JPEG also carries in an APP1 segment, and which is why the
    // marker has to be checked rather than assumed.
    const xmp = "http://ns.adobe.com/xap/1.0/\x00<?xpacket begin=...";
    try testing.expectEqual(@as(?Orientation, null), try orientationOf(xmp));

    try testing.expectEqual(@as(?Orientation, null), try orientationOf(""));
    try testing.expectEqual(@as(?Orientation, null), try orientationOf("II"));
    try testing.expectEqual(@as(?Orientation, null), try orientationOf("Exif\x00\x00"));
    // The right marker and the wrong magic.
    try testing.expectEqual(@as(?Orientation, null), try orientationOf("MM\x00\x2b\x00\x00\x00\x08\x00\x00"));
}

test "an orientation outside the eight the specification defines" {
    var buf: [256]u8 = undefined;
    for ([_]u16{ 0, 9, 255, 65535 }) |value| {
        const block = buildBlock(&buf, .little, true, &.{.{ orientation_tag, value }});
        try testing.expectEqual(@as(?Orientation, null), try orientationOf(block));
    }
}

test "a block truncated at every length" {
    var buf: [256]u8 = undefined;
    const whole = buildBlock(&buf, .little, true, &.{
        .{ 0x010f, 7 },
        .{ orientation_tag, 6 },
    });
    // Every prefix of a good block either answers with the orientation or
    // answers with nothing, and none of them fails or reads past its end.
    for (0..whole.len) |n| {
        var r: Io.Reader = .fixed(whole[0..n]);
        _ = try readOrientation(&r, @intCast(n));
        try testing.expectEqual(@as(usize, 0), r.bufferedLen());
    }
}

test "a directory claiming more entries than the block can hold" {
    // The count is read before the entries, so a malicious one is the obvious
    // way to ask a reader to run off the end.
    var buf: [64]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try w.writeAll("II");
    try w.writeInt(u16, 42, .little);
    try w.writeInt(u32, 8, .little);
    try w.writeInt(u16, 65535, .little);
    try testing.expectEqual(@as(?Orientation, null), try orientationOf(w.buffered()));
}

test "an offset to the first directory that points backwards" {
    var buf: [64]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try w.writeAll("MM");
    try w.writeInt(u16, 42, .big);
    try w.writeInt(u32, 4, .big); // inside the header it has just been read from
    try w.writeInt(u16, 1, .big);
    try testing.expectEqual(@as(?Orientation, null), try orientationOf(w.buffered()));
}

test "an offset that skips forward over padding" {
    // Legal, and written by some encoders: the directory need not follow the
    // header immediately.
    var buf: [128]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try w.writeAll("II");
    try w.writeInt(u16, 42, .little);
    try w.writeInt(u32, 24, .little);
    try w.writeAll(&@as([16]u8, @splat(0xaa))); // padding, to offset 24
    try w.writeInt(u16, 1, .little);
    try w.writeInt(u16, orientation_tag, .little);
    try w.writeInt(u16, type_short, .little);
    try w.writeInt(u32, 1, .little);
    try w.writeInt(u16, 8, .little);
    try w.writeInt(u16, 0, .little);
    try testing.expectEqual(@as(?Orientation, .left_bottom), try orientationOf(w.buffered()));
}

test "the block is consumed even when there is more of it than was read" {
    // A real block has a thumbnail and a second directory behind the first,
    // and the caller's framing depends on all of it being stepped over.
    var buf: [256]u8 = undefined;
    const block = buildBlock(&buf, .little, true, &.{.{ orientation_tag, 3 }});

    var padded: [512]u8 = undefined;
    @memcpy(padded[0..block.len], block);
    @memset(padded[block.len..], 0x5a);

    var r: Io.Reader = .fixed(&padded);
    try testing.expectEqual(@as(?Orientation, .bottom_right), try readOrientation(&r, padded.len));
    try testing.expectEqual(@as(usize, 0), r.bufferedLen());
}

test "what each orientation asks a caller to do" {
    try testing.expect(!Orientation.top_left.swapsDimensions());
    try testing.expect(!Orientation.bottom_right.swapsDimensions());
    try testing.expect(Orientation.right_top.swapsDimensions());
    try testing.expect(Orientation.left_bottom.swapsDimensions());

    // The ordinary case is no work at all, and the common camera one — held
    // on its side — is a quarter turn clockwise with no mirroring.
    try testing.expectEqual(Transform{ .mirror = false, .rotate = .none }, Orientation.top_left.transform());
    try testing.expectEqual(Transform{ .mirror = false, .rotate = .clockwise }, Orientation.right_top.transform());
    try testing.expectEqual(Transform{ .mirror = true, .rotate = .none }, Orientation.top_right.transform());

    // Exactly four of the eight are mirrored, and exactly four swap.
    var mirrored: usize = 0;
    var swapped: usize = 0;
    for (1..9) |v| {
        const o: Orientation = @fromBackingInt(@intCast(v));
        if (o.transform().mirror) mirrored += 1;
        if (o.swapsDimensions()) swapped += 1;
    }
    try testing.expectEqual(@as(usize, 4), mirrored);
    try testing.expectEqual(@as(usize, 4), swapped);
}

test "what is written is what is read" {
    // The two halves of this module against each other, which is the whole of
    // what writing has to get right.
    for (1..9) |value| {
        const o: Orientation = @fromBackingInt(@intCast(value));
        var block: [orientation_block_len]u8 = undefined;
        writeOrientation(&block, o);
        try testing.expectEqual(@as(?Orientation, o), try orientationOf(&block));

        // And with the marker a JPEG puts in front of it.
        var with_marker: [6 + orientation_block_len]u8 = undefined;
        @memcpy(with_marker[0..6], "Exif\x00\x00");
        @memcpy(with_marker[6..], &block);
        try testing.expectEqual(@as(?Orientation, o), try orientationOf(&with_marker));
    }
}

test "a written block is the size it says it is" {
    var block: [orientation_block_len]u8 = undefined;
    writeOrientation(&block, .bottom_right);
    try testing.expectEqual(@as(usize, 26), block.len);
    // Big-endian, the magic, and the directory immediately behind the header.
    try testing.expectEqualSlices(u8, "MM\x00\x2a\x00\x00\x00\x08\x00\x01", block[0..10]);
}
