// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Huffman tables, and the bit stream they are read out of.
//!
//! JPEG's entropy coding is canonical Huffman: a table is not a list of codes
//! but a list of *how many codes there are of each length*, from one bit to
//! sixteen, followed by the symbols in order. The codes themselves are then
//! implied — start at zero, and at each length take the next code and shift
//! left — which is why a table costs seventeen bytes plus its symbols rather
//! than a tree.
//!
//! That structure also gives the decoding procedure in the specification:
//! read a bit at a time, and after each bit ask whether the code so far is
//! within the range of codes of that length. `Table.max_code` holds the
//! largest code at each length, which makes the question a comparison.
//!
//! ## The bit stream
//!
//! Entropy-coded data is not a plain byte run. `0xFF` introduces a marker, so
//! an `0xFF` that is part of the compressed data is written as `0xFF 0x00` and
//! has to be unstuffed on the way in. Anything else after an `0xFF` is a real
//! marker and the end of this run of data — a restart marker between
//! intervals, or the marker that ends the scan.
//!
//! When that happens the reader does not fail. It records the marker and
//! supplies zero bits from then on, which is what libjpeg does and what keeps
//! a truncated file decoding into a partial image rather than nothing at all.
//! The caller checks `marker` to find out.

const std = @import("std");
const Io = std.Io;
const math = std.math;
const testing = std.testing;

/// The errors this layer can produce, a subset of the codec's.
pub const Error = error{
    InvalidData,
    ReadFailed,
};

/// One Huffman table, in the form the specification's decoding procedure
/// wants.
pub const Table = struct {
    /// `min_code[l]` is the smallest code of length `l`, and `max_code[l]` the
    /// largest; `-1` where there are no codes of that length.
    min_code: [17]i32,
    max_code: [17]i32,
    /// Where the symbols for length `l` begin in `values`.
    val_offset: [17]i32,
    values: [256]u8,
    count: usize,

    /// A fast path for the common case: the first eight bits of a code, when
    /// that is enough to identify it, mapped straight to its symbol and
    /// length. Most codes in a real image are short, so most reads never touch
    /// the loop.
    fast: [256]Fast,

    const Fast = struct {
        /// Zero means "not resolved by eight bits, take the slow path".
        len: u8,
        value: u8,
    };

    /// Builds a table from a `DHT` segment's counts and symbols.
    ///
    /// `counts[i]` is the number of codes of length `i + 1`.
    pub fn init(counts: *const [16]u8, values: []const u8) Error!Table {
        var total: usize = 0;
        for (counts) |n| total += n;
        if (total != values.len or total > 256) return error.InvalidData;

        var self: Table = .{
            .min_code = @splat(0),
            .max_code = @splat(-1),
            .val_offset = @splat(0),
            .values = @splat(0),
            .count = total,
            .fast = @splat(.{ .len = 0, .value = 0 }),
        };
        @memcpy(self.values[0..total], values);

        // The canonical assignment: codes ascend within a length, and moving
        // to the next length shifts left.
        var code: i32 = 0;
        var k: i32 = 0;
        for (1..17) |len| {
            const n: i32 = counts[len - 1];
            if (n != 0) {
                self.val_offset[len] = k - code;
                self.min_code[len] = code;
                code += n;
                k += n;
                self.max_code[len] = code - 1;
                // A code that would need more bits than its length allows is a
                // table that cannot be decoded — the counts describe more
                // codes than exist at that length.
                if (code > (@as(i32, 1) << @intCast(len))) return error.InvalidData;
            } else {
                self.max_code[len] = -1;
            }
            // Unconditionally, and this is the whole subtlety of the
            // construction: moving to the next length appends a bit to every
            // code, whether or not any codes were assigned at this one. A
            // shift skipped over an empty length puts every longer code out by
            // a factor of two — and since real JPEG tables have no codes of
            // length one or two, that is every table in every file, in the
            // lengths past eight that the shortcut above does not cover.
            code <<= 1;
        }

        // Fill the eight-bit shortcut for every code that fits in it.
        var index: usize = 0;
        var c: u32 = 0;
        for (1..17) |len| {
            const n: usize = counts[len - 1];
            for (0..n) |_| {
                if (len <= 8) {
                    // Every eight-bit prefix beginning with this code.
                    const shift: u3 = @intCast(8 - len);
                    const base = c << shift;
                    for (0..(@as(u32, 1) << shift)) |j| {
                        self.fast[base + j] = .{ .len = @intCast(len), .value = self.values[index] };
                    }
                }
                index += 1;
                c += 1;
            }
            c <<= 1;
        }

        return self;
    }
};

/// Reads bits out of an entropy-coded segment.
pub const BitReader = struct {
    source: *Io.Reader,
    /// Bits waiting to be consumed, most significant first.
    bits: u32,
    /// How many of them are valid.
    count: u6,
    /// The marker that ended the data, once one has been met.
    marker: ?u8,

    pub fn init(source: *Io.Reader) BitReader {
        return .{ .source = source, .bits = 0, .count = 0, .marker = null };
    }

    /// Throws away any part-consumed byte, which is what a restart marker
    /// requires: each interval begins on a byte boundary.
    pub fn alignToByte(self: *BitReader) void {
        self.bits = 0;
        self.count = 0;
    }

    /// Brings at least `n` bits into the buffer, supplying zeroes once a
    /// marker has been reached.
    fn fill(self: *BitReader, n: u6) Error!void {
        while (self.count < n) {
            const byte = try self.nextByte();
            self.bits = (self.bits << 8) | byte;
            self.count += 8;
        }
    }

    /// One byte of entropy-coded data, undoing the stuffing.
    fn nextByte(self: *BitReader) Error!u32 {
        if (self.marker != null) return 0;

        const b = self.source.takeByte() catch |err| switch (err) {
            // A file that stops in the middle of a scan. Treated as the end of
            // the data rather than as a failure, so that what was decoded
            // before it is kept.
            error.EndOfStream => {
                self.marker = 0xd9; // EOI
                return 0;
            },
            error.ReadFailed => return error.ReadFailed,
        };
        if (b != 0xff) return b;

        // An `0xFF`: either stuffed data or a marker.
        const next = self.source.takeByte() catch |err| switch (err) {
            error.EndOfStream => {
                self.marker = 0xd9;
                return 0;
            },
            error.ReadFailed => return error.ReadFailed,
        };
        switch (next) {
            // `0xFF 0x00` is a literal `0xFF` in the data.
            0x00 => return 0xff,
            // A run of fill bytes before a marker is legal, and rare.
            0xff => {
                self.source.toss(0);
                return 0xff;
            },
            else => {
                self.marker = next;
                return 0;
            },
        }
    }

    /// The next `n` bits, as an unsigned value. `n` may be zero.
    pub fn take(self: *BitReader, n: u6) Error!u32 {
        if (n == 0) return 0;
        try self.fill(n);
        self.count -= n;
        const shift: u5 = @intCast(self.count);
        const mask: u32 = (@as(u32, 1) << @intCast(n)) - 1;
        return (self.bits >> shift) & mask;
    }

    /// One bit.
    pub fn takeBit(self: *BitReader) Error!u32 {
        return self.take(1);
    }

    /// The symbol the next code in the stream stands for.
    pub fn decode(self: *BitReader, table: *const Table) Error!u8 {
        // The shortcut first: eight bits is enough for most codes.
        try self.fill(8);
        const peek: u8 = @intCast((self.bits >> @intCast(self.count - 8)) & 0xff);
        const fast = table.fast[peek];
        if (fast.len != 0) {
            self.count -= @intCast(fast.len);
            return fast.value;
        }

        // The specification's procedure, a bit at a time.
        var code: i32 = @intCast(try self.take(8));
        var len: usize = 8;
        while (len < 16) {
            len += 1;
            code = (code << 1) | @as(i32, @intCast(try self.takeBit()));
            if (table.max_code[len] >= code and code >= table.min_code[len]) {
                const index = table.val_offset[len] + code;
                if (index < 0 or index >= table.count) return error.InvalidData;
                return table.values[@intCast(index)];
            }
        }
        // Seventeen bits without a match: the stream and the table disagree.
        return error.InvalidData;
    }

    /// A coefficient of `n` bits, sign-extended the way JPEG defines it.
    ///
    /// The encoding is unusual: the top half of the range is positive and the
    /// bottom half negative, so a value whose leading bit is zero is negative
    /// and has `2^n - 1` subtracted from it. This is `EXTEND` in the
    /// specification.
    pub fn receiveExtend(self: *BitReader, n: u6) Error!i32 {
        if (n == 0) return 0;
        const v: i32 = @intCast(try self.take(n));
        const threshold = @as(i32, 1) << @intCast(n - 1);
        if (v < threshold) return v - (@as(i32, 1) << @intCast(n)) + 1;
        return v;
    }
};

test "a canonical table decodes the codes it describes" {
    // Three symbols: one of length one, two of length two. The canonical codes
    // are therefore 0, 10 and 11.
    var counts: [16]u8 = @splat(0);
    counts[0] = 1;
    counts[1] = 2;
    const table: Table = try .init(&counts, &.{ 'a', 'b', 'c' });

    // 0 10 11 0, then padding.
    var r: Io.Reader = .fixed(&.{0b0101_1000});
    var bits: BitReader = .init(&r);
    try testing.expectEqual(@as(u8, 'a'), try bits.decode(&table));
    try testing.expectEqual(@as(u8, 'b'), try bits.decode(&table));
    try testing.expectEqual(@as(u8, 'c'), try bits.decode(&table));
    try testing.expectEqual(@as(u8, 'a'), try bits.decode(&table));
}

test "a table whose counts describe impossible codes is refused" {
    // Three codes of length one, where only two exist.
    var counts: [16]u8 = @splat(0);
    counts[0] = 3;
    try testing.expectError(error.InvalidData, Table.init(&counts, &.{ 'a', 'b', 'c' }));

    // And counts that do not match the symbols given.
    var other: [16]u8 = @splat(0);
    other[1] = 2;
    try testing.expectError(error.InvalidData, Table.init(&other, &.{'a'}));
}

test "a long code takes the slow path and still decodes" {
    // One symbol at each length from 1 to 16, which puts the last few well
    // past the eight-bit shortcut.
    var counts: [16]u8 = @splat(1);
    var values: [16]u8 = undefined;
    for (&values, 0..) |*v, i| v.* = @intCast(i);
    const table: Table = try .init(&counts, &values);

    // The canonical code for the symbol at length 16 is fifteen ones then a
    // zero... which is what this builds: 0b0, 0b10, 0b110, and so on.
    var buf: [4]u8 = .{ 0xff, 0xff, 0xfe, 0x00 };
    var r: Io.Reader = .fixed(&buf);
    var bits: BitReader = .init(&r);
    try testing.expectEqual(@as(u8, 15), try bits.decode(&table));
}

test "stuffed bytes are unstuffed and markers stop the data" {
    // `0xFF 0x00` is a literal 0xFF; `0xFF 0xD9` is the end-of-image marker.
    var r: Io.Reader = .fixed(&.{ 0xff, 0x00, 0x5a, 0xff, 0xd9 });
    var bits: BitReader = .init(&r);

    try testing.expectEqual(@as(u32, 0xff), try bits.take(8));
    try testing.expectEqual(@as(u32, 0x5a), try bits.take(8));
    try testing.expectEqual(@as(?u8, null), bits.marker);

    // Past the marker the reader supplies zeroes rather than failing.
    try testing.expectEqual(@as(u32, 0), try bits.take(8));
    try testing.expectEqual(@as(?u8, 0xd9), bits.marker);
}

test "a stream that simply stops is the end of the data" {
    var r: Io.Reader = .fixed(&.{0x12});
    var bits: BitReader = .init(&r);
    try testing.expectEqual(@as(u32, 0x12), try bits.take(8));
    try testing.expectEqual(@as(u32, 0), try bits.take(8));
    try testing.expect(bits.marker != null);
}

test "the sign extension is JPEG's, not two's complement" {
    // Four bits: 0b1000 through 0b1111 are 8..15, and 0b0000 through 0b0111
    // are -15..-8.
    var r: Io.Reader = .fixed(&.{ 0b1111_0000, 0b1000_0111 });
    var bits: BitReader = .init(&r);
    try testing.expectEqual(@as(i32, 15), try bits.receiveExtend(4));
    try testing.expectEqual(@as(i32, -15), try bits.receiveExtend(4));
    try testing.expectEqual(@as(i32, 8), try bits.receiveExtend(4));
    try testing.expectEqual(@as(i32, -8), try bits.receiveExtend(4));
    // Zero bits is zero, which is how a DC difference of nothing is coded.
    try testing.expectEqual(@as(i32, 0), try bits.receiveExtend(0));
}

test "alignToByte throws away a part-read byte" {
    var r: Io.Reader = .fixed(&.{ 0xab, 0xcd });
    var bits: BitReader = .init(&r);
    _ = try bits.take(4);
    bits.alignToByte();
    try testing.expectEqual(@as(u32, 0xcd), try bits.take(8));
}

test "a table with empty lengths still assigns the right codes" {
    // The shape every real JPEG table has: nothing short, everything bunched
    // in the middle and long lengths. With the shift skipped over the empty
    // lengths, the codes past eight bits come out wrong and nothing but a
    // real file notices.
    var counts: [16]u8 = @splat(0);
    counts[3] = 2; // two codes of length 4
    counts[8] = 1; // one of length 9
    counts[9] = 1; // one of length 10
    const table: Table = try .init(&counts, &.{ 'a', 'b', 'c', 'd' });

    // Canonical: 'a' = 0000, 'b' = 0001, then length 9 starts at
    // (0b0010 << 5) = 0b001000000 and length 10 at 0b0010000010.
    try testing.expectEqual(@as(i32, 0b0000), table.min_code[4]);
    try testing.expectEqual(@as(i32, 0b0001), table.max_code[4]);
    try testing.expectEqual(@as(i32, 0b001000000), table.min_code[9]);
    try testing.expectEqual(@as(i32, 0b0010000010), table.min_code[10]);

    // And they decode. 0000 0001 0010 0000 0 0010000010, padded.
    var r: Io.Reader = .fixed(&.{ 0b0000_0001, 0b0010_0000, 0b0001_0000, 0b0100_0000 });
    var bits: BitReader = .init(&r);
    try testing.expectEqual(@as(u8, 'a'), try bits.decode(&table));
    try testing.expectEqual(@as(u8, 'b'), try bits.decode(&table));
    try testing.expectEqual(@as(u8, 'c'), try bits.decode(&table));
    try testing.expectEqual(@as(u8, 'd'), try bits.decode(&table));
}

// -- writing -----------------------------------------------------------------

/// A Huffman table in the form an encoder wants: symbol to code.
///
/// Built from the same counts and symbols a `Table` is, by the same canonical
/// assignment, so an encoder and a decoder given one `DHT` segment necessarily
/// agree about it.
pub const Encoder = struct {
    code: [256]u16,
    len: [256]u8,

    pub fn init(counts: *const [16]u8, values: []const u8) Error!Encoder {
        var total: usize = 0;
        for (counts) |n| total += n;
        if (total != values.len or total > 256) return error.InvalidData;

        var self: Encoder = .{ .code = @splat(0), .len = @splat(0) };
        var code: u32 = 0;
        var index: usize = 0;
        for (1..17) |length| {
            for (0..counts[length - 1]) |_| {
                if (code >= (@as(u32, 1) << @intCast(length))) return error.InvalidData;
                self.code[values[index]] = @intCast(code);
                self.len[values[index]] = @intCast(length);
                code += 1;
                index += 1;
            }
            code <<= 1;
        }
        return self;
    }
};

/// Writes bits into an entropy-coded segment, stuffing as it goes.
///
/// The mirror of `BitReader`: an `0xFF` that falls out of the entropy coder
/// has to be written as `0xFF 0x00`, or a decoder would read it as the start of
/// a marker and stop.
pub const BitWriter = struct {
    out: *std.Io.Writer,
    /// Bits waiting to be written, most significant first, left-aligned in
    /// the low `count` positions.
    bits: u32,
    count: u6,

    pub fn init(out: *std.Io.Writer) BitWriter {
        return .{ .out = out, .bits = 0, .count = 0 };
    }

    pub fn write(self: *BitWriter, code: u32, len: u6) std.Io.Writer.Error!void {
        if (len == 0) return;
        self.bits = (self.bits << @intCast(len)) | (code & ((@as(u32, 1) << @intCast(len)) - 1));
        self.count += len;
        while (self.count >= 8) {
            self.count -= 8;
            const byte: u8 = @truncate(self.bits >> @intCast(self.count));
            try self.out.writeByte(byte);
            if (byte == 0xff) try self.out.writeByte(0x00);
        }
    }

    /// Pads the last byte out with ones and writes it.
    ///
    /// Ones rather than zeroes because the specification says so, and it is
    /// not arbitrary: a run of ones is not a valid prefix of any code in a
    /// table built from `DHT`, so a decoder cannot mistake the padding for one
    /// more coefficient.
    pub fn flush(self: *BitWriter) std.Io.Writer.Error!void {
        if (self.count == 0) return;
        const pad: u6 = 8 - self.count;
        try self.write((@as(u32, 1) << @intCast(pad)) - 1, pad);
    }
};

test "an encoder and a decoder agree about one table" {
    // One code of length two, two of length three, one of length four. The
    // lengths have to leave room for each other -- a code of length one plus
    // two of length two already fills the space, and nothing longer can follow
    // them -- which is what `init` refuses below.
    var counts: [16]u8 = @splat(0);
    counts[1] = 1;
    counts[2] = 2;
    counts[3] = 1;
    const values = [_]u8{ 'a', 'b', 'c', 'd' };

    const enc: Encoder = try .init(&counts, &values);
    const dec: Table = try .init(&counts, &values);

    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var bw: BitWriter = .init(&w);
    for ("abcdabcd") |sym| {
        try bw.write(enc.code[sym], @intCast(enc.len[sym]));
    }
    try bw.flush();

    var r: Io.Reader = .fixed(w.buffered());
    var br: BitReader = .init(&r);
    for ("abcdabcd") |sym| {
        try testing.expectEqual(sym, try br.decode(&dec));
    }
}

test "an 0xFF that falls out of the coder is stuffed" {
    var buf: [16]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var bw: BitWriter = .init(&w);
    try bw.write(0xff, 8);
    try bw.write(0x0f, 8);
    try bw.flush();
    // The 0xFF grows a zero behind it; the 0x0F does not.
    try testing.expectEqualSlices(u8, &.{ 0xff, 0x00, 0x0f }, w.buffered());
}

test "the padding is ones, which no code can be" {
    var buf: [16]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var bw: BitWriter = .init(&w);
    try bw.write(0b010, 3);
    try bw.flush();
    try testing.expectEqualSlices(u8, &.{0b0101_1111}, w.buffered());
}

test "a table an encoder refuses is one a decoder refuses too" {
    {
        var counts: [16]u8 = @splat(0);
        counts[0] = 3; // three codes of length one, where two exist
        try testing.expectError(error.InvalidData, Encoder.init(&counts, &.{ 'a', 'b', 'c' }));
        try testing.expectError(error.InvalidData, Table.init(&counts, &.{ 'a', 'b', 'c' }));
    }
    {
        // A code space already full, with something longer after it.
        var counts: [16]u8 = @splat(0);
        counts[0] = 1;
        counts[1] = 2;
        counts[3] = 1;
        try testing.expectError(error.InvalidData, Encoder.init(&counts, &.{ 'a', 'b', 'c', 'd' }));
        try testing.expectError(error.InvalidData, Table.init(&counts, &.{ 'a', 'b', 'c', 'd' }));
    }
}

/// A table as `DHT` carries it: how many codes there are of each length, and
/// the symbols in the order the codes are assigned to them.
pub const Spec = struct {
    counts: [16]u8 = @splat(0),
    values: [256]u8 = @splat(0),
    len: usize = 0,

    pub fn symbols(self: *const Spec) []const u8 {
        return self.values[0..self.len];
    }

    /// The fixed table the specification's Annex K gives as an example.
    pub fn fixed(counts: *const [16]u8, values: []const u8) Spec {
        var self: Spec = .{ .counts = counts.*, .len = values.len };
        @memcpy(self.values[0..values.len], values);
        return self;
    }

    /// The table that codes `freq` in the fewest bits, subject to the
    /// specification's two constraints on a JPEG Huffman table.
    ///
    /// This is the procedure of Annex K.2, which is Huffman's algorithm with
    /// the tree left implicit: `others` chains each symbol to the one it was
    /// merged into, so walking that chain and adding one to every code length
    /// along it is the same thing as making a node the child of a new parent.
    /// A merge takes the two least frequent symbols, breaking a tie towards
    /// the *larger* index, which is not arbitrary — it is what makes two
    /// encoders given the same statistics write the same table.
    ///
    /// The two constraints are what separate this from plain Huffman coding.
    /// No code may be longer than sixteen bits, and no code may be all ones:
    /// a decoder reading past the end of the scan sees the padding bits, which
    /// are ones, and an all-ones code would decode as one more symbol rather
    /// than running out. The first is met by the shortening loop below and the
    /// second by coding a symbol that never occurs, so that the all-ones code
    /// is spent on it.
    pub fn optimal(freq: *const [257]u32) Spec {
        // Frequencies get merged into, so work on a copy. The reserved symbol
        // is given a frequency of one so that it is merged last and so ends up
        // with the longest code, which is the all-ones one.
        var f: [257]u32 = freq.*;
        f[256] = 1;

        var codesize: [257]u16 = @splat(0);
        var others: [257]i16 = @splat(-1);

        while (true) {
            // The two least frequent symbols still in play, ties going to the
            // larger index.
            var v1: i16 = -1;
            var least: u32 = math.maxInt(u32);
            for (f, 0..) |n, i| {
                if (n != 0 and n <= least) {
                    least = n;
                    v1 = @intCast(i);
                }
            }
            if (v1 < 0) break;
            var v2: i16 = -1;
            var next: u32 = math.maxInt(u32);
            const first: usize = @intCast(v1);
            for (f, 0..) |n, i| {
                if (n != 0 and n <= next and i != first) {
                    next = n;
                    v2 = @intCast(i);
                }
            }
            if (v2 < 0) break;

            const a: usize = @intCast(v1);
            const b: usize = @intCast(v2);
            f[a] += f[b];
            f[b] = 0;

            // Everything already under `v1` gets a bit longer, and so does
            // everything already under `v2`, which is now under `v1` too.
            var walk: usize = a;
            codesize[walk] += 1;
            while (others[walk] >= 0) {
                walk = @intCast(others[walk]);
                codesize[walk] += 1;
            }
            // The link goes on the end of `v1`'s chain rather than on `v1`
            // itself, which is what keeps the chains single and so keeps the
            // walk above linear.
            others[walk] = v2;

            walk = b;
            codesize[walk] += 1;
            while (others[walk] >= 0) {
                walk = @intCast(others[walk]);
                codesize[walk] += 1;
            }
        }

        // How many codes of each length. Huffman's algorithm can produce a
        // code longer than sixteen bits — it takes frequencies growing like
        // the Fibonacci numbers, so it needs a very large and very skewed
        // image, but it is reachable — and the array is sized for the worst
        // case rather than for the likely one.
        var counts: [258]u16 = @splat(0);
        for (codesize) |n| {
            if (n != 0) counts[n] += 1;
        }

        // Shorten anything past sixteen bits, by the specification's Figure
        // K.3. Taking two codes of length `i` and making one of them length
        // `i-1` needs a prefix to hang it from, so a code of some length `j`
        // below is split into two of length `j+1`: the total number of codes
        // is unchanged and the total number of bits goes up a little, which is
        // the price of the limit.
        var i: usize = counts.len - 1;
        while (i > 16) : (i -= 1) {
            while (counts[i] > 0) {
                var j = i - 2;
                while (counts[j] == 0) j -= 1;
                counts[i] -= 2;
                counts[i - 1] += 1;
                counts[j + 1] += 2;
                counts[j] -= 1;
            }
        }

        // And spend the longest code on the reserved symbol, which is what
        // leaves no code that is all ones.
        //
        // Statistics with nothing in them are not something this encoder
        // produces — every scan it writes codes at least one symbol — but a
        // table is still asked for by position, so answer with the smallest
        // valid one rather than running `i` off the bottom of the array.
        while (i > 0 and counts[i] == 0) i -= 1;
        if (i == 0) {
            var empty: Spec = .{ .len = 1 };
            empty.counts[0] = 1;
            return empty;
        }
        counts[i] -= 1;

        var self: Spec = .{};
        for (counts[1..17], 0..) |n, k| self.counts[k] = @intCast(n);

        // The symbols, shortest code first and in increasing order within a
        // length. The lengths here are the ones from before the shortening,
        // which is deliberate and is what libjpeg does: the shortening changed
        // how many codes there are of each length but not which symbols
        // deserve the short ones, and the assignment is by position.
        for (1..counts.len) |length| {
            for (codesize[0..256], 0..) |n, symbol| {
                if (n == length) {
                    self.values[self.len] = @intCast(symbol);
                    self.len += 1;
                }
            }
        }
        return self;
    }
};

/// Everything a JPEG Huffman table has to satisfy, which is more than being a
/// prefix code.
///
/// No code may be longer than sixteen bits, which holding the counts in
/// sixteen slots takes care of on its own. The Kraft sum must come to exactly
/// one when the reserved code is counted with the real ones, and the reserved
/// code is one code at the longest length in the table: that is the *whole*
/// of what says the table is a complete prefix code and that the all-ones code
/// is the one left unused.
pub fn checkSpec(spec: *const Spec, expect_symbols: []const u8) !void {
    var total: usize = 0;
    // A binary fraction of the Kraft sum, scaled by 2^16 so that it is exact.
    var kraft: u32 = 0;
    var longest: usize = 0;
    for (spec.counts, 1..) |n, length| {
        total += n;
        kraft += @as(u32, n) << @intCast(16 - length);
        if (n != 0) longest = length;
    }
    try testing.expectEqual(spec.len, total);
    try testing.expect(longest != 0);
    const reserved = @as(u32, 1) << @intCast(16 - longest);
    try testing.expectEqual(@as(u32, 1) << 16, kraft + reserved);

    // And the codes that come out are assignable and distinct.
    const enc = try Encoder.init(&spec.counts, spec.symbols());
    for (expect_symbols) |s| try testing.expect(enc.len[s] != 0);
}

test "an optimal table codes exactly the symbols it was given" {
    var freq: [257]u32 = @splat(0);
    freq[0] = 100;
    freq[1] = 50;
    freq[2] = 25;
    freq[0x11] = 3;
    freq[0xf0] = 1;
    const spec: Spec = .optimal(&freq);

    try checkSpec(&spec, &.{ 0, 1, 2, 0x11, 0xf0 });
    try testing.expectEqualSlices(u8, &.{ 0, 1, 2, 0x11, 0xf0 }, spec.symbols());

    // And the more frequent symbol never gets the longer code.
    const enc = try Encoder.init(&spec.counts, spec.symbols());
    try testing.expect(enc.len[0] <= enc.len[1]);
    try testing.expect(enc.len[1] <= enc.len[2]);
    try testing.expect(enc.len[2] <= enc.len[0x11]);
}

test "an optimal table for a single symbol" {
    var freq: [257]u32 = @splat(0);
    freq[7] = 12345;
    const spec: Spec = .optimal(&freq);
    try checkSpec(&spec, &.{7});
    try testing.expectEqualSlices(u8, &.{7}, spec.symbols());
    // One symbol, one bit: the other value of that bit is the reserved code.
    try testing.expectEqual(@as(u8, 1), spec.counts[0]);
}

test "an optimal table for frequencies that would run past sixteen bits" {
    // Fibonacci frequencies are the worst case for Huffman's algorithm: each
    // symbol is merged against the whole of what came before, so the tree is a
    // stick and the code lengths run up with the symbol count. Twenty-four of
    // them would reach twenty-four bits without the shortening.
    var freq: [257]u32 = @splat(0);
    var a: u32 = 1;
    var b: u32 = 1;
    for (0..24) |i| {
        freq[i] = a;
        const next = a + b;
        a = b;
        b = next;
    }
    const spec: Spec = .optimal(&freq);

    var expect: [24]u8 = undefined;
    for (&expect, 0..) |*s, i| s.* = @intCast(i);
    try checkSpec(&spec, &expect);
    try testing.expectEqual(@as(usize, 24), spec.len);
}

test "an optimal table for every symbol at once" {
    var freq: [257]u32 = @splat(0);
    for (freq[0..256], 0..) |*n, i| n.* = @intCast(256 - i);
    const spec: Spec = .optimal(&freq);

    var expect: [256]u8 = undefined;
    for (&expect, 0..) |*s, i| s.* = @intCast(i);
    try checkSpec(&spec, &expect);
    try testing.expectEqual(@as(usize, 256), spec.len);
}

test "an optimal table for statistics with nothing in them" {
    const freq: [257]u32 = @splat(0);
    const spec: Spec = .optimal(&freq);
    try checkSpec(&spec, &.{});
    try testing.expectEqual(@as(usize, 1), spec.len);
}
