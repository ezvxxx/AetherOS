// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! GIF's variable-width LZW, which is not quite anybody else's.
//!
//! The dictionary starts with one entry per palette index and grows by one
//! entry for every code read; the code width starts one bit wider than the
//! palette and grows with the dictionary, to twelve bits. Two codes are
//! reserved: `clear`, which throws the dictionary away and starts again, and
//! `end`, which ends the stream.
//!
//! Three things make it its own thing rather than an implementation of LZW.
//!
//! **The bits are packed least significant first**, within bytes and across
//! them, which is the opposite of TIFF's LZW and the reason code that looks
//! right often is not.
//!
//! **The width grows one code early.** The encoder increases the width when
//! the *next* code it would assign no longer fits, so a decoder that waits
//! until the dictionary is actually full reads every code after the first
//! boundary at the wrong width. The condition below is written to match.
//!
//! **A code may refer to the entry it is about to create.** If the encoder
//! meets a sequence, adds it to the dictionary, and immediately meets it
//! again, the decoder sees a code it has not defined yet. The answer is
//! forced: the new entry can only be the previous string followed by its own
//! first byte. It is the one case in LZW everybody gets wrong once, and it is
//! why the test for it is called what it is.

const std = @import("std");
const mem = std.mem;
const testing = std.testing;

/// The widest code, which is the format's limit and not a choice.
pub const max_code_bits = 12;
pub const max_codes = 1 << max_code_bits;

/// The largest palette a GIF may have, and so the widest a starting code may
/// be.
pub const max_min_code_bits = 8;

pub const Error = error{
    /// A code that names no dictionary entry, a width that grew past twelve
    /// bits, or a stream that ends without saying so.
    InvalidData,
};

/// One dictionary entry: everything before the last byte, and the last byte.
///
/// Strings are stored this way rather than laid out end to end because they
/// share prefixes — that is the whole of what LZW is — so a string of any
/// length costs three bytes here and is walked backwards when it is wanted.
const Entry = struct {
    prefix: u16,
    suffix: u8,
};

/// Decompresses one GIF image's worth of LZW.
///
/// Sans-I/O in the same sense as everything else here: bytes are pushed in as
/// they arrive and decoded output is pushed out through `emit`, so the caller
/// keeps the reading and this keeps the state.
pub const Decompressor = struct {
    /// How wide a code is when the dictionary is fresh, less one.
    min_bits: u4,
    code_bits: u5,
    clear_code: u16,
    end_code: u16,
    next_code: u16,

    entries: [max_codes]Entry,
    /// The code before this one, or `none` at the start and after a clear.
    previous: u16,

    /// Bits read but not yet consumed, least significant first.
    bits: u32,
    bit_count: u5,
    finished: bool,

    /// One string, walked out backwards.
    ///
    /// A string cannot be longer than the dictionary, and the case below where
    /// a code names the entry it is about to create needs room for one byte
    /// more than that, which is where the `+ 1` goes.
    scratch: [max_codes + 1]u8,

    const none: u16 = 0xffff;

    pub fn init(min_code_bits: u8) Error!Decompressor {
        // One is legal and means a two-colour image; zero is not, since the
        // two reserved codes would leave nothing to say.
        if (min_code_bits < 1 or min_code_bits > max_min_code_bits) return error.InvalidData;
        const min: u4 = @intCast(min_code_bits);
        var self: Decompressor = .{
            .min_bits = min,
            .code_bits = 0,
            .clear_code = @as(u16, 1) << min,
            .end_code = (@as(u16, 1) << min) + 1,
            .next_code = 0,
            .entries = undefined,
            .previous = none,
            .bits = 0,
            .bit_count = 0,
            .finished = false,
            .scratch = undefined,
        };
        // The first `clear_code` entries are the palette indices themselves.
        for (self.entries[0..self.clear_code], 0..) |*e, i| {
            e.* = .{ .prefix = none, .suffix = @intCast(i) };
        }
        self.reset();
        return self;
    }

    fn reset(self: *Decompressor) void {
        self.code_bits = @as(u5, self.min_bits) + 1;
        self.next_code = self.end_code + 1;
        self.previous = none;
    }

    /// Feeds one block of compressed bytes, writing what comes out.
    ///
    /// `emit` takes a slice and may be called many times. It returns an error
    /// set of the caller's choosing, which is what lets the caller stop early
    /// once the image is full.
    pub fn push(
        self: *Decompressor,
        data: []const u8,
        context: anytype,
        comptime emit: fn (@TypeOf(context), []const u8) anyerror!void,
    ) anyerror!void {
        for (data) |byte| {
            if (self.finished) return;
            self.bits |= @as(u32, byte) << self.bit_count;
            self.bit_count += 8;

            while (self.bit_count >= self.code_bits) {
                const mask: u32 = (@as(u32, 1) << @intCast(self.code_bits)) - 1;
                const code: u16 = @intCast(self.bits & mask);
                self.bits >>= self.code_bits;
                self.bit_count -= self.code_bits;

                if (code == self.clear_code) {
                    self.reset();
                    continue;
                }
                if (code == self.end_code) {
                    self.finished = true;
                    return;
                }
                try self.expand(code, context, emit);
            }
        }
    }

    /// Whether the stream said it had ended, rather than merely running out.
    pub fn ended(self: Decompressor) bool {
        return self.finished;
    }

    fn expand(
        self: *Decompressor,
        code: u16,
        context: anytype,
        comptime emit: fn (@TypeOf(context), []const u8) anyerror!void,
    ) anyerror!void {
        var first: u8 = undefined;

        if (self.previous == none) {
            // The first code after a clear has to be a palette index: there is
            // nothing else defined yet.
            if (code >= self.clear_code) return error.InvalidData;
            first = self.entries[code].suffix;
            self.scratch[0] = first;
            try emit(context, self.scratch[0..1]);
        } else if (code < self.next_code) {
            const start = try self.stringInto(code, self.scratch.len);
            first = self.scratch[start];
            try emit(context, self.scratch[start..]);
        } else if (code == self.next_code) {
            // The entry this code names is the one it is about to create, and
            // the only string that can be is the previous one followed by its
            // own first byte. See the note at the top of this file.
            //
            // So the previous string is laid out one byte short of the end and
            // its first byte written after it, rather than over it --- which
            // is the mistake this arrangement exists to make impossible.
            const start = try self.stringInto(self.previous, self.scratch.len - 1);
            first = self.scratch[start];
            self.scratch[self.scratch.len - 1] = first;
            try emit(context, self.scratch[start..]);
        } else {
            return error.InvalidData;
        }

        if (self.previous != none and self.next_code < max_codes) {
            self.entries[self.next_code] = .{ .prefix = self.previous, .suffix = first };
            self.next_code += 1;
        }

        // Checked whether or not an entry was added, and with `>=` rather than
        // `==`, because both matter. The first code after a clear adds
        // nothing — there is no previous string to extend — so a check inside
        // the branch above would be skipped exactly when a two-colour image
        // needs it: there the first free code is 4 and the starting field is
        // two bits, so the width has to grow before the second code is read.
        if (self.next_code >= (@as(u16, 1) << @intCast(self.code_bits)) and
            self.code_bits < max_code_bits)
        {
            self.code_bits += 1;
        }
        self.previous = code;
    }

    /// Lays a code's string out backwards into `scratch`, ending just before
    /// `end`, and returns where it starts.
    fn stringInto(self: *Decompressor, code: u16, end: usize) Error!usize {
        var at = end;
        var c = code;
        while (true) {
            if (c >= self.next_code and c >= self.clear_code) return error.InvalidData;
            // A dictionary whose prefixes form a cycle would walk forever;
            // running out of buffer is what catches it, since a well-formed
            // string is shorter than the dictionary that describes it.
            if (at == 0) return error.InvalidData;
            at -= 1;
            self.scratch[at] = self.entries[c].suffix;
            const prefix = self.entries[c].prefix;
            if (prefix == none) break;
            c = prefix;
        }
        return at;
    }
};

// -- compressing --------------------------------------------------------------

/// Compresses palette indices into GIF's LZW.
///
/// The mirror of the decompressor, and it has to agree with it about the one
/// thing that is easy to get wrong: when the code width grows. Both do it the
/// instant the dictionary reaches the next power of two, which is one code
/// earlier than a reading of the algorithm suggests and is what every GIF in
/// the world was written with.
pub const Compressor = struct {
    min_bits: u4,
    code_bits: u5,
    clear_code: u16,
    end_code: u16,
    next_code: u16,

    /// `(prefix << 8) | suffix` to the code that stands for it.
    dictionary: std.AutoHashMapUnmanaged(u32, u16),
    prefix: ?u16,

    bits: u32,
    bit_count: u5,
    out: *std.ArrayList(u8),
    gpa: mem.Allocator,

    pub fn init(
        gpa: mem.Allocator,
        out: *std.ArrayList(u8),
        min_code_bits: u8,
    ) (Error || mem.Allocator.Error)!Compressor {
        if (min_code_bits < 1 or min_code_bits > max_min_code_bits) return error.InvalidData;
        const min: u4 = @intCast(min_code_bits);
        var self: Compressor = .{
            .min_bits = min,
            .code_bits = @as(u5, min) + 1,
            .clear_code = @as(u16, 1) << min,
            .end_code = (@as(u16, 1) << min) + 1,
            .next_code = (@as(u16, 1) << min) + 2,
            .dictionary = .empty,
            .prefix = null,
            .bits = 0,
            .bit_count = 0,
            .out = out,
            .gpa = gpa,
        };
        // A stream begins by clearing, so that a decoder starting anywhere in
        // a concatenation of them is in a known state.
        try self.write(self.clear_code);
        return self;
    }

    pub fn deinit(self: *Compressor) void {
        self.dictionary.deinit(self.gpa);
    }

    pub fn push(self: *Compressor, indices: []const u8) (Error || mem.Allocator.Error)!void {
        for (indices) |index| {
            if (index >= self.clear_code) return error.InvalidData;
            const current = self.prefix orelse {
                self.prefix = index;
                continue;
            };

            const key = (@as(u32, current) << 8) | index;
            if (self.dictionary.get(key)) |code| {
                self.prefix = code;
                continue;
            }

            try self.write(current);
            if (self.next_code < max_codes) {
                try self.dictionary.put(self.gpa, key, self.next_code);
                self.next_code += 1;
                // One code *later* than the decompressor grows, and that is
                // the heart of this format's LZW. An encoder assigns an entry
                // with every code it emits; a decoder cannot complete that
                // entry until it has read the code after it, so its dictionary
                // is permanently one behind. Both must nonetheless change
                // width between the same two codes, so the encoder's condition
                // is the decompressor's shifted by one. Getting this wrong on
                // both sides at once produces an encoder and decoder that
                // agree with each other and with nothing else in the world.
                if (self.next_code > (@as(u16, 1) << @intCast(self.code_bits)) and
                    self.code_bits < max_code_bits)
                {
                    self.code_bits += 1;
                }
            } else {
                // The dictionary is full, so start again --- which is the only
                // thing that keeps a long image from coding every byte at
                // twelve bits.
                try self.write(self.clear_code);
                self.dictionary.clearRetainingCapacity();
                self.code_bits = @as(u5, self.min_bits) + 1;
                self.next_code = self.end_code + 1;
            }
            self.prefix = index;
        }
    }

    /// Writes what is left and the end code, and pads the last byte.
    pub fn finish(self: *Compressor) (Error || mem.Allocator.Error)!void {
        if (self.prefix) |p| try self.write(p);
        try self.write(self.end_code);
        if (self.bit_count > 0) {
            try self.out.append(self.gpa, @truncate(self.bits));
            self.bits = 0;
            self.bit_count = 0;
        }
    }

    fn write(self: *Compressor, code: u16) mem.Allocator.Error!void {
        self.bits |= @as(u32, code) << self.bit_count;
        self.bit_count += self.code_bits;
        while (self.bit_count >= 8) {
            try self.out.append(self.gpa, @truncate(self.bits));
            self.bits >>= 8;
            self.bit_count -= 8;
        }
    }
};

// -- tests --------------------------------------------------------------------

const Collector = struct {
    out: *std.ArrayList(u8),
    gpa: mem.Allocator,

    fn emit(self: *Collector, bytes: []const u8) anyerror!void {
        try self.out.appendSlice(self.gpa, bytes);
    }
};

fn roundTrip(gpa: mem.Allocator, indices: []const u8, min_bits: u8) ![]u8 {
    var compressed: std.ArrayList(u8) = .empty;
    defer compressed.deinit(gpa);
    var c = try Compressor.init(gpa, &compressed, min_bits);
    defer c.deinit();
    try c.push(indices);
    try c.finish();

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var collector: Collector = .{ .out = &out, .gpa = gpa };
    var d = try Decompressor.init(min_bits);
    try d.push(compressed.items, &collector, Collector.emit);
    return out.toOwnedSlice(gpa);
}

test "the string a code names before it exists" {
    // The case everybody gets wrong once: the encoder meets a sequence, adds
    // it, and immediately meets it again, so the decoder sees a code it has
    // not defined. `ababab...` produces it within a few bytes, which is why
    // it is the shape used here.
    const gpa = testing.allocator;
    var indices: [64]u8 = undefined;
    for (&indices, 0..) |*v, i| v.* = @intCast(i % 2);

    const back = try roundTrip(gpa, &indices, 2);
    defer gpa.free(back);
    try testing.expectEqualSlices(u8, &indices, back);
}

test "a run long enough to grow the code width several times" {
    const gpa = testing.allocator;
    // Every distinct pair, so the dictionary fills steadily and every width
    // boundary from five bits upwards is crossed.
    var indices: std.ArrayList(u8) = .empty;
    defer indices.deinit(gpa);
    for (0..256) |a| {
        for (0..16) |b| {
            try indices.append(gpa, @intCast(a % 16));
            try indices.append(gpa, @intCast(b));
        }
    }

    const back = try roundTrip(gpa, indices.items, 4);
    defer gpa.free(back);
    try testing.expectEqualSlices(u8, indices.items, back);
}

test "enough data to fill the dictionary and start again" {
    const gpa = testing.allocator;
    // Pseudo-random indices compress badly, which is what drives the
    // dictionary to four thousand entries and makes the encoder clear it.
    var prng: std.Random.DefaultPrng = .init(0x9e3779b9);
    const rand = prng.random();
    const indices = try gpa.alloc(u8, 40_000);
    defer gpa.free(indices);
    for (indices) |*v| v.* = rand.int(u8);

    const back = try roundTrip(gpa, indices, 8);
    defer gpa.free(back);
    try testing.expectEqualSlices(u8, indices, back);
}

test "every palette size the format allows" {
    const gpa = testing.allocator;
    for (1..max_min_code_bits + 1) |bits| {
        const limit: u16 = @as(u16, 1) << @intCast(bits);
        var indices: std.ArrayList(u8) = .empty;
        defer indices.deinit(gpa);
        for (0..600) |i| try indices.append(gpa, @intCast(i % limit));

        const back = try roundTrip(gpa, indices.items, @intCast(bits));
        defer gpa.free(back);
        try testing.expectEqualSlices(u8, indices.items, back);
    }
}

test "codes that name nothing" {
    const gpa = testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var collector: Collector = .{ .out = &out, .gpa = gpa };

    // A first code that is not a palette index and is not reserved, which
    // nothing has defined. Three bits a code, a palette of four: 0 to 3 are
    // the palette, 4 clears and 5 ends, so 6 is the first code that names
    // nothing at all.
    var d = try Decompressor.init(2);
    try testing.expectError(error.InvalidData, d.push(&.{0x06}, &collector, Collector.emit));

    // And a starting width the format does not have.
    try testing.expectError(error.InvalidData, Decompressor.init(0));
    try testing.expectError(error.InvalidData, Decompressor.init(9));
}

test "a stream that stops without saying so" {
    const gpa = testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var collector: Collector = .{ .out = &out, .gpa = gpa };

    // A clear code and one palette index, and then nothing --- a perfectly
    // good prefix of a stream that was cut off. Three bits a code, so the
    // two fit in one byte: 0b100 is the clear and 0b000 the index.
    var d = try Decompressor.init(2);
    try d.push(&.{0x04}, &collector, Collector.emit);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    // What matters is that it is not said to have ended, so a caller can tell
    // a truncated image from a complete one.
    try testing.expect(!d.ended());
}
