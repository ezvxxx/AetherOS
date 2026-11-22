// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! ICC colour profiles, carried through rather than understood.
//!
//! A profile says what the numbers in an image *mean* — which real colours
//! those bytes stand for, and how to get from them to some other device's
//! numbers. This library does not do any of that. z2d has no colour
//! management, so there is nothing here that could apply a profile, and
//! pretending otherwise would be worse than saying so.
//!
//! What it can do is not lose it. A program converting a JPEG to a PNG, or
//! re-encoding one at a different quality, should hand back a file that still
//! says what its colours mean; a library that silently dropped the profile
//! would turn a wide-gamut photograph into a washed-out one the first time it
//! passed through. So the profile comes out as bytes and goes back in as
//! bytes, unread.
//!
//! ## Where a profile lives
//!
//! JPEG has no chunk large enough. A profile is commonly a few kilobytes and
//! can be megabytes, and an `APP2` segment holds at most 65533 bytes, so the
//! ICC specification's own Annex B defines how to split one: each segment
//! begins `ICC_PROFILE\0`, then a one-based piece number and the number of
//! pieces, then that piece of the profile. That embedding belongs to ICC
//! rather than to JPEG, which is why it is described here and not in `jpeg`.
//!
//! PNG has `iCCP`, which holds a name, a compression method, and the profile
//! deflated. One chunk, whatever the size.
//!
//! BMP can carry one too, in a `BITMAPV5HEADER`, and this library does not
//! read it. The header gives an offset to the profile rather than the profile
//! itself, and writers put it after the pixel data — so reaching it means
//! knowing where the cursor is in a stream that has already been read past,
//! which a decoder that only ever seeks forward cannot do. It is also
//! vanishingly rare.
//!
//! ## A profile that is not one is dropped
//!
//! As with EXIF: metadata is decoration, and a file with a broken profile in
//! it is still a perfectly good photograph. But unlike EXIF, this is passed
//! *on* rather than read, so a malformed profile carried through would become
//! a malformed profile in the output, which other readers would reject. So
//! anything that is not shaped like a profile is dropped rather than
//! propagated.

const std = @import("std");
const mem = std.mem;
const testing = std.testing;

/// What every `APP2` segment carrying a piece of a profile begins with.
pub const jpeg_marker = "ICC_PROFILE\x00";

/// The most profile data one `APP2` segment can carry.
///
/// A segment's length field counts itself, so 65535 leaves 65533 bytes behind
/// it; the marker above takes twelve of those and the two piece numbers take
/// two more.
pub const jpeg_chunk_len = 65535 - 2 - jpeg_marker.len - 2;

/// The most pieces a profile may be split into, since the piece number is a
/// single byte and counts from one.
pub const jpeg_chunk_limit = 255;

/// The largest profile a JPEG can carry, which is the natural ceiling on all
/// of this: 255 pieces of 65519 bytes.
pub const jpeg_max = jpeg_chunk_limit * jpeg_chunk_len;

/// The fixed part of a profile, which every one begins with.
const header_len = 128;

/// Whether a byte string is shaped like an ICC profile.
///
/// Two checks, both from the profile's own header and both cheap. The first
/// four bytes are the profile's size, which must be the size it actually is —
/// that is what catches a truncated one, a profile reassembled from pieces
/// that went missing, and a chunk of something else entirely. Bytes 36 to 40
/// are the signature `acsp`, which every profile since the first version has
/// carried and nothing else has a reason to.
///
/// It is not a validation of the profile's contents, and is not meant to be:
/// what follows the header is a tag table describing colour transforms that
/// this library has no opinion about.
pub fn looksValid(bytes: []const u8) bool {
    if (bytes.len < header_len) return false;
    if (mem.readInt(u32, bytes[0..4], .big) != bytes.len) return false;
    return mem.eql(u8, bytes[36..40], "acsp");
}

/// Collects a profile from the pieces a JPEG splits it into.
///
/// The pieces have to arrive in order. The specification numbers them and does
/// not promise an order, and libjpeg sorts them — but it can, because it holds
/// every marker in memory before it looks at any of them. A decoder reading a
/// stream once cannot leave a gap for a piece that has not come yet, and no
/// encoder writes them out of order. One that did would have its profile
/// dropped rather than reassembled wrongly.
pub const Assembler = struct {
    /// How many pieces the first one said there would be, or zero before any
    /// have arrived.
    total: u8 = 0,
    /// How many have been taken.
    seen: u8 = 0,
    /// Set by anything that went wrong, after which nothing more is taken and
    /// the result is nothing.
    broken: bool = false,

    /// Offers one `APP2` payload, with the `ICC_PROFILE\0` marker already
    /// matched and removed.
    ///
    /// Returns false when this piece was not usable, which the caller needs
    /// only to decide whether to go on appending.
    pub fn take(
        self: *Assembler,
        gpa: mem.Allocator,
        out: *std.ArrayList(u8),
        payload: []const u8,
        limit: u64,
    ) mem.Allocator.Error!bool {
        if (self.broken) return false;
        // The two numbers, and at least one byte of profile behind them.
        if (payload.len < 3) return self.fail(out);

        const number = payload[0];
        const total = payload[1];
        if (total == 0 or number == 0 or number > total) return self.fail(out);

        if (self.seen == 0) {
            self.total = total;
        } else if (total != self.total) {
            // The pieces disagree about how many there are.
            return self.fail(out);
        }
        if (number != self.seen + 1) return self.fail(out);

        const piece = payload[2..];
        if (out.items.len + piece.len > limit) return self.fail(out);
        try out.appendSlice(gpa, piece);
        self.seen = number;
        return true;
    }

    /// Whether every piece arrived and what they came to is a profile.
    ///
    /// Called once the file's markers have been read. A profile that never
    /// finished, or finished as something that is not a profile, leaves the
    /// list empty.
    pub fn finish(self: *Assembler, out: *std.ArrayList(u8)) void {
        if (self.broken or self.seen == 0 or self.seen != self.total or
            !looksValid(out.items))
        {
            out.clearRetainingCapacity();
            self.broken = true;
        }
    }

    fn fail(self: *Assembler, out: *std.ArrayList(u8)) bool {
        self.broken = true;
        out.clearRetainingCapacity();
        return false;
    }
};

/// A profile to write, split into the pieces a JPEG needs, one at a time.
///
/// An iterator rather than a list, so that writing one allocates nothing: the
/// encoder holds the caller's profile and walks it.
pub const Pieces = struct {
    profile: []const u8,
    next: usize = 0,

    pub fn init(profile: []const u8) Pieces {
        return .{ .profile = profile };
    }

    /// How many `APP2` segments this profile takes.
    pub fn count(self: Pieces) usize {
        return (self.profile.len + jpeg_chunk_len - 1) / jpeg_chunk_len;
    }

    /// The next piece, and its one-based number.
    pub fn take(self: *Pieces) ?struct { number: u8, bytes: []const u8 } {
        if (self.next >= self.profile.len) return null;
        const end = @min(self.next + jpeg_chunk_len, self.profile.len);
        const bytes = self.profile[self.next..end];
        const number: u8 = @intCast(self.next / jpeg_chunk_len + 1);
        self.next = end;
        return .{ .number = number, .bytes = bytes };
    }
};

// -- tests -------------------------------------------------------------------

/// A profile-shaped byte string of `len` bytes: the right size in the right
/// place and the right signature, with nothing meaningful behind them.
fn fakeProfile(buf: []u8) []u8 {
    @memset(buf, 0x5a);
    mem.writeInt(u32, buf[0..4], @intCast(buf.len), .big);
    @memcpy(buf[36..40], "acsp");
    return buf;
}

test "what is and is not shaped like a profile" {
    var buf: [400]u8 = undefined;
    const good = fakeProfile(&buf);
    try testing.expect(looksValid(good));

    // Too short to hold a header.
    try testing.expect(!looksValid(good[0..127]));
    try testing.expect(!looksValid(""));

    // The size field disagreeing with the size, which is what catches a
    // profile reassembled from pieces that went missing.
    var wrong: [400]u8 = undefined;
    _ = fakeProfile(&wrong);
    mem.writeInt(u32, wrong[0..4], 399, .big);
    try testing.expect(!looksValid(&wrong));

    // And the signature.
    var unsigned: [400]u8 = undefined;
    _ = fakeProfile(&unsigned);
    @memcpy(unsigned[36..40], "nope");
    try testing.expect(!looksValid(&unsigned));
}

test "a profile that fits in one piece" {
    const gpa = testing.allocator;
    var buf: [300]u8 = undefined;
    const profile = fakeProfile(&buf);

    var pieces: Pieces = .init(profile);
    try testing.expectEqual(@as(usize, 1), pieces.count());

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var asm_: Assembler = .{};

    var payload: [2 + 300]u8 = undefined;
    while (pieces.take()) |piece| {
        payload[0] = piece.number;
        payload[1] = 1;
        @memcpy(payload[2..][0..piece.bytes.len], piece.bytes);
        try testing.expect(try asm_.take(gpa, &out, payload[0 .. 2 + piece.bytes.len], jpeg_max));
    }
    asm_.finish(&out);
    try testing.expectEqualSlices(u8, profile, out.items);
}

test "a profile that has to be split" {
    const gpa = testing.allocator;
    const size = jpeg_chunk_len * 2 + 17;
    const buf = try gpa.alloc(u8, size);
    defer gpa.free(buf);
    const profile = fakeProfile(buf);

    var pieces: Pieces = .init(profile);
    try testing.expectEqual(@as(usize, 3), pieces.count());

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var asm_: Assembler = .{};

    const payload = try gpa.alloc(u8, 2 + jpeg_chunk_len);
    defer gpa.free(payload);
    const total: u8 = @intCast(pieces.count());
    var numbers: [3]u8 = undefined;
    var at: usize = 0;
    while (pieces.take()) |piece| {
        numbers[at] = piece.number;
        at += 1;
        payload[0] = piece.number;
        payload[1] = total;
        @memcpy(payload[2..][0..piece.bytes.len], piece.bytes);
        try testing.expect(try asm_.take(gpa, &out, payload[0 .. 2 + piece.bytes.len], jpeg_max));
    }
    // Numbered from one, in order.
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, &numbers);
    asm_.finish(&out);
    try testing.expectEqualSlices(u8, profile, out.items);
}

test "pieces that do not add up leave nothing" {
    const gpa = testing.allocator;
    var buf: [300]u8 = undefined;
    const profile = fakeProfile(&buf);

    const cases = [_]struct { note: []const u8, numbers: []const [2]u8 }{
        // A piece missing from the middle.
        .{ .note = "gap", .numbers = &.{ .{ 1, 3 }, .{ 3, 3 } } },
        // Out of order, which no encoder writes and this does not reassemble.
        .{ .note = "reversed", .numbers = &.{ .{ 2, 2 }, .{ 1, 2 } } },
        // The same piece twice.
        .{ .note = "repeated", .numbers = &.{ .{ 1, 2 }, .{ 1, 2 } } },
        // Disagreeing about how many pieces there are.
        .{ .note = "disagreement", .numbers = &.{ .{ 1, 2 }, .{ 2, 3 } } },
        // Numbered from zero.
        .{ .note = "zero", .numbers = &.{.{ 0, 1 }} },
        // A piece past the end.
        .{ .note = "past the end", .numbers = &.{.{ 2, 1 }} },
        // Fewer pieces than were promised.
        .{ .note = "unfinished", .numbers = &.{.{ 1, 2 }} },
    };

    for (cases) |k| {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(gpa);
        var asm_: Assembler = .{};
        var payload: [2 + 100]u8 = undefined;
        for (k.numbers) |n| {
            payload[0] = n[0];
            payload[1] = n[1];
            @memcpy(payload[2..][0..100], profile[0..100]);
            _ = try asm_.take(gpa, &out, payload[0..102], jpeg_max);
        }
        asm_.finish(&out);
        if (out.items.len != 0) {
            std.debug.print("\n{s}: {d} bytes survived and should not have\n", .{ k.note, out.items.len });
            return error.ShouldHaveBeenDropped;
        }
    }
}

test "a piece longer than the limit allows" {
    const gpa = testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var asm_: Assembler = .{};

    var payload: [2 + 200]u8 = undefined;
    payload[0] = 1;
    payload[1] = 1;
    @memset(payload[2..], 0);
    try testing.expect(!try asm_.take(gpa, &out, &payload, 100));
    asm_.finish(&out);
    try testing.expectEqual(@as(usize, 0), out.items.len);
}

test "what was reassembled has to be a profile" {
    const gpa = testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var asm_: Assembler = .{};

    // Every piece arrives and is numbered correctly, and what they come to is
    // not a profile.
    var payload: [2 + 200]u8 = undefined;
    payload[0] = 1;
    payload[1] = 1;
    @memset(payload[2..], 0x11);
    try testing.expect(try asm_.take(gpa, &out, &payload, jpeg_max));
    asm_.finish(&out);
    try testing.expectEqual(@as(usize, 0), out.items.len);
}
