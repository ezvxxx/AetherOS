// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! WebP lossless prefix codes, and the bit stream they are read out of.
//!
//! The two are one file for the reason `src/jpeg/huffman.zig` is: reading a
//! code *is* reading bits in a particular order, and the order here has a
//! subtlety that is invisible from either side alone.
//!
//! **The stream is least significant bit first** — within a byte and across
//! bytes — which is GIF's LZW packing and the opposite of JPEG's.
//!
//! **A code is packed most significant bit of the code first.** So the first
//! bit to come out of the stream is the *top* bit of the code, and the
//! decoding loop appends each new bit at the bottom:
//!
//! ```zig
//! code = (code << 1) | try br.takeBit();
//! ```
//!
//! The two conventions are opposite, both are correct, and this is DEFLATE's
//! arrangement exactly. Code that assumes one order holds throughout reads
//! every table in every file wrongly, which is why it is written down here
//! rather than left for whoever meets it.
//!
//! ## What a code is built from
//!
//! A length for every symbol, and nothing else: the codes themselves are
//! canonical, so they follow from the lengths. That is a different input from
//! JPEG's `DHT`, which gives counts per length and then the symbols, and is
//! why `jpeg.huffman.Table` cannot be borrowed for this — quite apart from
//! its `values: [256]u8`, where a WebP alphabet reaches 2328.
//!
//! The lengths themselves arrive in one of two forms. A **simple** code names
//! one or two symbols outright and has no lengths at all. A **normal** one is
//! coded with a second prefix code, over nineteen symbols, which is itself
//! given as nineteen three-bit lengths in a fixed and deliberately unsorted
//! order — the lengths most likely to be non-zero first, so that a file can
//! stop early.
//!
//! ## No fast table, on purpose
//!
//! An eight-bit lookup would cost a kilobyte per code and five kilobytes per
//! group, and the number of groups a file may declare is the one place in
//! this format where a few bytes of input buy an unbounded allocation (see
//! `vp8l.zig`). Decoding a bit at a time costs at most fifteen iterations and
//! keeps a code to about a hundred bytes plus its symbols, which is the side
//! to err on in a library whose decoders are meant to be handed hostile
//! input.

const std = @import("std");
const Io = std.Io;
const mem = std.mem;
const testing = std.testing;
const Allocator = mem.Allocator;

/// The longest prefix code the format allows.
pub const max_code_length = 15;

/// The largest alphabet: 256 green values, 24 backward-reference length
/// codes, and colour-cache indices for a cache of up to 2048 entries.
pub const max_symbols = 256 + 24 + (1 << 11);

/// The nineteen code-length symbols, in the order a file gives their lengths.
///
/// Not a sort. The two run-length symbols and the short lengths come first
/// because they are the ones most likely to be used, so a file may give
/// fewer than nineteen and have the rest be zero.
pub const code_length_order = [19]u8{
    17, 18, 0, 1, 2, 3, 4, 5, 16, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
};

/// How many symbols the code that codes the code lengths has.
///
/// Worth a name because it is the headroom a `SymbolPool` needs above
/// whatever it is going to store: that code is built out of the same pool and
/// is live while the code it describes is being read.
pub const code_length_symbols = 19;

/// The first code-length symbol that is a repeat rather than a length.
const first_repeat = 16;
/// Extra bits and offsets for symbols 16, 17 and 18.
const repeat_extra = [3]u3{ 2, 3, 7 };
const repeat_offset = [3]u8{ 3, 3, 11 };
/// What symbol 16 repeats before any non-zero length has been seen.
const default_code_length = 8;

pub const Error = error{
    /// A code whose lengths describe no code — over-subscribed, or
    /// incomplete, or naming a symbol outside its alphabet.
    InvalidData,
} || Io.Reader.Error;

/// Bits, least significant first.
///
/// Sans-I/O like everything else here: it pulls from an `Io.Reader` and holds
/// no buffer of its own beyond the accumulator.
pub const BitReader = struct {
    source: *Io.Reader,
    /// Bits not yet consumed, the next one in the lowest position. Everything
    /// at or above `count` is zero, which is what lets a read past the end of
    /// the stream be detected by `count` alone.
    bits: u64 = 0,
    count: u7 = 0,

    pub fn init(source: *Io.Reader) BitReader {
        return .{ .source = source };
    }

    /// Pulls bytes until the accumulator is full or the stream ends.
    ///
    /// Running out is not an error here. It becomes one at `take`, where the
    /// caller asked for a specific number of bits and can be told it did not
    /// get them.
    fn refill(self: *BitReader) Error!void {
        while (self.count <= 56) {
            const byte = self.source.takeByte() catch |err| switch (err) {
                error.EndOfStream => break,
                error.ReadFailed => |e| return e,
            };
            self.bits |= @as(u64, byte) << @intCast(self.count);
            self.count += 8;
        }
    }

    /// Reads `n` bits. `n` is at most 32, which is wider than any field the
    /// format has.
    pub fn take(self: *BitReader, n: u6) Error!u32 {
        std.debug.assert(n <= 32);
        if (n == 0) return 0;
        if (self.count < n) try self.refill();
        if (self.count < n) return error.EndOfStream;
        const value: u32 = @truncate(self.bits & ((@as(u64, 1) << n) - 1));
        self.bits >>= n;
        self.count -= n;
        return value;
    }

    pub fn takeBit(self: *BitReader) Error!u1 {
        return @intCast(try self.take(1));
    }
};

/// Somewhere to put the symbols of every code built for one image.
///
/// One allocation for the whole bitstream rather than one per code, because
/// the sandboxed child decodes onto a `FixedBufferAllocator`, which can only
/// give back its most recent block. A decoder that allocated and freed a few
/// thousand small symbol tables would spend the whole arena and get none of
/// it back.
///
/// It is also where the budget is enforced: `take` is the single place every
/// code's storage comes from, so bounding it bounds the lot.
pub const SymbolPool = struct {
    buf: []u16,
    used: usize = 0,

    pub fn init(gpa: Allocator, capacity: usize) Allocator.Error!SymbolPool {
        return .{ .buf = try gpa.alloc(u16, capacity) };
    }

    pub fn deinit(self: *SymbolPool, gpa: Allocator) void {
        gpa.free(self.buf);
        self.* = undefined;
    }

    /// `error.ImageTooLarge` rather than `error.InvalidData`: a file that asks
    /// for more table than the budget allows is well formed and was refused,
    /// which is the distinction `common.DecodeError` draws.
    pub fn take(self: *SymbolPool, n: usize) error{ImageTooLarge}![]u16 {
        if (n > self.buf.len - self.used) return error.ImageTooLarge;
        const out = self.buf[self.used..][0..n];
        self.used += n;
        return out;
    }

    /// How much of the budget is left, in symbols.
    pub fn remaining(self: SymbolPool) usize {
        return self.buf.len - self.used;
    }
};

/// One canonical prefix code.
pub const Code = struct {
    /// `first[l]` is the smallest code of length `l`, `count[l]` how many
    /// there are, and `index[l]` where their symbols begin in `symbols`.
    first: [max_code_length + 1]u16 = @splat(0),
    count: [max_code_length + 1]u16 = @splat(0),
    index: [max_code_length + 1]u16 = @splat(0),
    /// Borrowed from the pool the whole image was built out of, never owned.
    symbols: []const u16 = &.{},
    /// A code with exactly one symbol reads no bits at all.
    ///
    /// Not an edge case to be tolerated: the simple form below produces one
    /// on purpose, and so does a normal form whose lengths name a single
    /// symbol. A decoder that insisted on consuming a bit for it would
    /// desynchronise on the very next read.
    single: ?u16 = null,

    pub fn read(self: *const Code, br: *BitReader) Error!u16 {
        if (self.single) |only| return only;
        var code: u32 = 0;
        for (1..max_code_length + 1) |len| {
            code = (code << 1) | try br.takeBit();
            const n = self.count[len];
            if (n != 0) {
                const offset = code -% self.first[len];
                if (offset < n) return self.symbols[self.index[len] + offset];
            }
        }
        return error.InvalidData;
    }
};

/// Builds a code from one length per symbol.
///
/// `lengths.len` is the alphabet size; a zero length means the symbol does
/// not appear.
pub fn build(lengths: []const u8, pool: *SymbolPool) (Error || error{ImageTooLarge})!Code {
    var self: Code = .{};

    var total: usize = 0;
    var last: u16 = 0;
    for (lengths, 0..) |len, symbol| {
        if (len == 0) continue;
        if (len > max_code_length) return error.InvalidData;
        self.count[len] += 1;
        total += 1;
        last = @intCast(symbol);
    }

    // A code with nothing in it decodes nothing, and a file that built one
    // would read the next symbol out of a table that cannot answer.
    if (total == 0) return error.InvalidData;
    if (total == 1) {
        self.single = last;
        return self;
    }

    // The canonical assignment, and the completeness check in the same walk:
    // `left` is how many codes of the current length remain unassigned, which
    // must reach exactly zero. Negative means the lengths describe more codes
    // than exist at that length; positive at the end means they describe
    // fewer, and a code with a hole in it is one a decoder could fall
    // through.
    var left: i32 = 1;
    var code: u32 = 0;
    var index: u16 = 0;
    for (1..max_code_length + 1) |len| {
        left <<= 1;
        left -= self.count[len];
        if (left < 0) return error.InvalidData;
        self.first[len] = @intCast(code);
        self.index[len] = index;
        code += self.count[len];
        index += self.count[len];
        code <<= 1;
    }
    if (left != 0) return error.InvalidData;

    // Symbols in canonical order: by length, and by symbol within a length.
    const symbols = try pool.take(total);
    var next: [max_code_length + 1]u16 = self.index;
    for (lengths, 0..) |len, symbol| {
        if (len == 0) continue;
        symbols[next[len]] = @intCast(symbol);
        next[len] += 1;
    }
    self.symbols = symbols;
    return self;
}

/// Reads one prefix code off the stream: either the simple form or the
/// normal one.
///
/// `lengths` is scratch of at least `alphabet_size` bytes, reused by every
/// call — the lengths are consumed the moment the code is built, so one
/// buffer serves a whole image.
pub fn readCode(
    br: *BitReader,
    alphabet_size: u16,
    lengths: []u8,
    pool: *SymbolPool,
) (Error || error{ImageTooLarge})!Code {
    std.debug.assert(lengths.len >= alphabet_size);

    if (try br.takeBit() == 1) return readSimpleCode(br, alphabet_size, pool);

    // The nineteen code-length symbols, given as three-bit lengths in the
    // fixed order above. A file may give as few as four and mean zero for the
    // rest.
    var meta_lengths: [19]u8 = @splat(0);
    const given = 4 + try br.take(4);
    for (0..given) |i| {
        meta_lengths[code_length_order[i]] = @intCast(try br.take(3));
    }

    // Built out of the same pool, and given back the moment the real lengths
    // are decoded: it is the pool's most recent block, so releasing it is
    // just moving the mark. Not a `defer`, deliberately --- that would fire
    // after the code below had been built on top of it and hand the caller
    // symbols the next allocation is about to overwrite.
    const mark = pool.used;
    const meta = try build(&meta_lengths, pool);

    @memset(lengths[0..alphabet_size], 0);
    try readCodeLengths(br, &meta, lengths[0..alphabet_size]);
    pool.used = mark;

    return build(lengths[0..alphabet_size], pool);
}

/// The one- or two-symbol form, which carries no lengths.
fn readSimpleCode(br: *BitReader, alphabet_size: u16, pool: *SymbolPool) (Error || error{ImageTooLarge})!Code {
    const count = try br.take(1) + 1;
    // The first symbol is written in one bit or eight, because a great many
    // simple codes are over an alphabet of two.
    const width: u6 = if (try br.takeBit() == 1) 8 else 1;

    var symbols: [2]u16 = undefined;
    symbols[0] = @intCast(try br.take(width));
    if (count == 2) symbols[1] = @intCast(try br.take(8));
    for (symbols[0..count]) |s| if (s >= alphabet_size) return error.InvalidData;

    if (count == 1) return .{ .single = symbols[0] };

    var self: Code = .{};
    self.count[1] = 2;
    self.first[1] = 0;
    self.index[1] = 0;
    const out = try pool.take(2);
    // Deliberately *not* sorted: the file names them in code order, so the
    // first one written is the symbol for code 0 whatever its value.
    out[0] = symbols[0];
    out[1] = symbols[1];
    self.symbols = out;
    return self;
}

/// Decodes the per-symbol lengths with the code-length code.
fn readCodeLengths(br: *BitReader, meta: *const Code, lengths: []u8) Error!void {
    // A file may say it is only going to describe the first so many symbols,
    // which is how a large alphabet with a small used range is written
    // cheaply. Everything past it keeps the zero it was memset to.
    var remaining: u32 = @intCast(lengths.len);
    if (try br.takeBit() == 1) {
        const width: u6 = @intCast(2 + 2 * try br.take(3));
        const stated = 2 + try br.take(width);
        if (stated > lengths.len) return error.InvalidData;
        remaining = stated;
    }

    var previous: u8 = default_code_length;
    var at: usize = 0;
    while (at < lengths.len) {
        if (remaining == 0) break;
        remaining -= 1;

        const symbol = try meta.read(br);
        if (symbol < first_repeat) {
            lengths[at] = @intCast(symbol);
            at += 1;
            if (symbol != 0) previous = @intCast(symbol);
            continue;
        }

        const slot = symbol - first_repeat;
        if (slot >= repeat_extra.len) return error.InvalidData;
        const run: usize = try br.take(repeat_extra[slot]) + repeat_offset[slot];
        if (at + run > lengths.len) return error.InvalidData;
        // Symbol 16 repeats the last non-zero length; 17 and 18 are runs of
        // zero, which is why they come first in `code_length_order`.
        const value: u8 = if (symbol == first_repeat) previous else 0;
        @memset(lengths[at..][0..run], value);
        at += run;
    }
}

// -- tests -------------------------------------------------------------------

/// Bits into a reader, least significant first, the way a file holds them.
const Packer = struct {
    bytes: std.ArrayList(u8) = .empty,
    partial: u8 = 0,
    count: u3 = 0,

    fn put(self: *Packer, gpa: Allocator, value: u32, n: u6) !void {
        for (0..n) |i| {
            const bit: u1 = @intCast((value >> @intCast(i)) & 1);
            self.partial |= @as(u8, bit) << self.count;
            if (self.count == 7) {
                try self.bytes.append(gpa, self.partial);
                self.partial = 0;
                self.count = 0;
            } else self.count += 1;
        }
    }

    /// A prefix code, most significant bit of the code first --- which is the
    /// opposite order from a plain field, and the whole subtlety this module
    /// exists to get right.
    fn putCode(self: *Packer, gpa: Allocator, code: u32, n: u6) !void {
        var i: u6 = n;
        while (i > 0) {
            i -= 1;
            try self.put(gpa, (code >> @intCast(i)) & 1, 1);
        }
    }

    fn finish(self: *Packer, gpa: Allocator) ![]u8 {
        if (self.count != 0) try self.bytes.append(gpa, self.partial);
        return self.bytes.toOwnedSlice(gpa);
    }
};

test "bits come out least significant first, within a byte and across bytes" {
    var r: Io.Reader = .fixed(&.{ 0b1010_0101, 0b0000_0011 });
    var br: BitReader = .init(&r);

    try testing.expectEqual(@as(u32, 1), try br.take(1));
    try testing.expectEqual(@as(u32, 2), try br.take(2));
    try testing.expectEqual(@as(u32, 0b10100), try br.take(5));
    // Straddling the byte boundary: the low bits come from the first byte.
    try testing.expectEqual(@as(u32, 3), try br.take(8));
}

test "a read past the end of the stream is an error rather than zeroes" {
    var r: Io.Reader = .fixed(&.{0xff});
    var br: BitReader = .init(&r);
    try testing.expectEqual(@as(u32, 0xff), try br.take(8));
    try testing.expectError(error.EndOfStream, br.take(1));
}

test "a canonical code decodes what its lengths describe" {
    const gpa = testing.allocator;
    var pool: SymbolPool = try .init(gpa, 64);
    defer pool.deinit(gpa);

    // Four symbols: lengths 1, 2, 3, 3 give codes 0, 10, 110, 111.
    const code = try build(&[_]u8{ 1, 2, 3, 3 }, &pool);

    var p: Packer = .{};
    defer p.bytes.deinit(gpa);
    try p.putCode(gpa, 0b0, 1);
    try p.putCode(gpa, 0b10, 2);
    try p.putCode(gpa, 0b110, 3);
    try p.putCode(gpa, 0b111, 3);
    const bytes = try p.finish(gpa);
    defer gpa.free(bytes);

    var r: Io.Reader = .fixed(bytes);
    var br: BitReader = .init(&r);
    for ([_]u16{ 0, 1, 2, 3 }) |want| {
        try testing.expectEqual(want, try code.read(&br));
    }
}

test "a code with one symbol consumes no bits" {
    const gpa = testing.allocator;
    var pool: SymbolPool = try .init(gpa, 64);
    defer pool.deinit(gpa);

    const code = try build(&[_]u8{ 0, 0, 1, 0 }, &pool);
    try testing.expectEqual(@as(?u16, 2), code.single);

    // An empty stream, which is the point: reading the symbol must not ask
    // for a bit.
    var r: Io.Reader = .fixed(&.{});
    var br: BitReader = .init(&r);
    try testing.expectEqual(@as(u16, 2), try code.read(&br));
    try testing.expectEqual(@as(u16, 2), try code.read(&br));
}

test "lengths that do not describe a code are refused" {
    const gpa = testing.allocator;
    var pool: SymbolPool = try .init(gpa, 64);
    defer pool.deinit(gpa);

    // Nothing at all.
    try testing.expectError(error.InvalidData, build(&[_]u8{ 0, 0, 0 }, &pool));
    // Three codes of length one, where there is room for two.
    try testing.expectError(error.InvalidData, build(&[_]u8{ 1, 1, 1 }, &pool));
    // Two codes of length two, leaving half the tree unreachable: a stream
    // could then present a code that falls out of the bottom of `read`.
    try testing.expectError(error.InvalidData, build(&[_]u8{ 2, 2 }, &pool));
    // Longer than the format allows.
    try testing.expectError(error.InvalidData, build(&[_]u8{ 16, 1 }, &pool));
}

test "the pool refuses to hand out more than its budget" {
    const gpa = testing.allocator;
    var pool: SymbolPool = try .init(gpa, 4);
    defer pool.deinit(gpa);

    _ = try pool.take(3);
    try testing.expectEqual(@as(usize, 1), pool.remaining());
    try testing.expectError(error.ImageTooLarge, pool.take(2));
}

test "the simple form names its symbols outright" {
    const gpa = testing.allocator;
    var pool: SymbolPool = try .init(gpa, 64);
    defer pool.deinit(gpa);
    var scratch: [256]u8 = undefined;

    // One symbol, written in eight bits.
    {
        var p: Packer = .{};
        defer p.bytes.deinit(gpa);
        try p.put(gpa, 1, 1); // simple
        try p.put(gpa, 0, 1); // one symbol
        try p.put(gpa, 1, 1); // eight bits wide
        try p.put(gpa, 200, 8);
        const bytes = try p.finish(gpa);
        defer gpa.free(bytes);

        var r: Io.Reader = .fixed(bytes);
        var br: BitReader = .init(&r);
        const code = try readCode(&br, 256, &scratch, &pool);
        try testing.expectEqual(@as(?u16, 200), code.single);
    }

    // Two symbols, the first written in one bit, and they decode in the order
    // the file names them rather than in numeric order.
    {
        var p: Packer = .{};
        defer p.bytes.deinit(gpa);
        try p.put(gpa, 1, 1); // simple
        try p.put(gpa, 1, 1); // two symbols
        try p.put(gpa, 0, 1); // one bit wide
        try p.put(gpa, 1, 1); // first symbol: 1
        try p.put(gpa, 7, 8); // second symbol: 7
        try p.putCode(gpa, 0, 1);
        try p.putCode(gpa, 1, 1);
        const bytes = try p.finish(gpa);
        defer gpa.free(bytes);

        var r: Io.Reader = .fixed(bytes);
        var br: BitReader = .init(&r);
        const code = try readCode(&br, 256, &scratch, &pool);
        try testing.expectEqual(@as(u16, 1), try code.read(&br));
        try testing.expectEqual(@as(u16, 7), try code.read(&br));
    }
}

test "the normal form codes its lengths with a code of its own" {
    const gpa = testing.allocator;
    var pool: SymbolPool = try .init(gpa, 512);
    defer pool.deinit(gpa);
    var scratch: [8]u8 = undefined;

    // An alphabet of four whose lengths are 1, 2, 3, 3. Those lengths are
    // themselves written with a prefix code over the code-length symbols, and
    // giving symbols 0 to 3 a length of two each makes that code complete:
    // 00, 01, 10, 11 for the lengths 0, 1, 2 and 3.
    var p: Packer = .{};
    defer p.bytes.deinit(gpa);
    try p.put(gpa, 0, 1); // normal, not simple
    // Six three-bit lengths, in `code_length_order`, which reaches symbol 3
    // at its sixth entry.
    try p.put(gpa, 6 - 4, 4);
    for ([6]u3{ 0, 0, 2, 2, 2, 2 }) |len| try p.put(gpa, len, 3);
    try p.put(gpa, 0, 1); // no explicit symbol count
    // The four lengths: 1, 2, 3, 3.
    try p.putCode(gpa, 0b01, 2);
    try p.putCode(gpa, 0b10, 2);
    try p.putCode(gpa, 0b11, 2);
    try p.putCode(gpa, 0b11, 2);
    // Then the four symbols, in the code those lengths describe.
    try p.putCode(gpa, 0b0, 1);
    try p.putCode(gpa, 0b10, 2);
    try p.putCode(gpa, 0b110, 3);
    try p.putCode(gpa, 0b111, 3);
    const bytes = try p.finish(gpa);
    defer gpa.free(bytes);

    var r: Io.Reader = .fixed(bytes);
    var br: BitReader = .init(&r);
    const code = try readCode(&br, 4, &scratch, &pool);
    for ([_]u16{ 0, 1, 2, 3 }) |want| {
        try testing.expectEqual(want, try code.read(&br));
    }
}

// -- writing -----------------------------------------------------------------

/// Bits out, least significant first, into a growing buffer.
///
/// A buffer rather than an `Io.Writer` because a VP8L bitstream goes inside a
/// RIFF chunk, and a chunk carries its length in front of it: the bytes have
/// to exist before the thing that says how many there are can be written.
pub const BitWriter = struct {
    out: *std.ArrayList(u8),
    gpa: Allocator,
    bits: u64 = 0,
    count: u7 = 0,

    pub fn init(gpa: Allocator, out: *std.ArrayList(u8)) BitWriter {
        return .{ .out = out, .gpa = gpa };
    }

    /// Writes `n` bits of a plain field.
    pub fn put(self: *BitWriter, value: u32, n: u6) Allocator.Error!void {
        std.debug.assert(n <= 32);
        if (n == 0) return;
        self.bits |= @as(u64, value & mask(n)) << @intCast(self.count);
        self.count += n;
        while (self.count >= 8) {
            try self.out.append(self.gpa, @truncate(self.bits));
            self.bits >>= 8;
            self.count -= 8;
        }
    }

    /// Writes a prefix code, most significant bit of the code first.
    ///
    /// The opposite order from `put`, and the whole subtlety this module
    /// exists to get right: the stream is least significant bit first and a
    /// code is packed top bit first, which are different things and both
    /// true.
    pub fn putCode(self: *BitWriter, code: u16, len: u8) Allocator.Error!void {
        var i: u8 = len;
        while (i > 0) {
            i -= 1;
            try self.put((@as(u32, code) >> @intCast(i)) & 1, 1);
        }
    }

    /// Pads the last byte with zeroes. A VP8L bitstream ends wherever it
    /// ends and the rest of the byte is nobody's.
    pub fn flush(self: *BitWriter) Allocator.Error!void {
        if (self.count != 0) {
            try self.out.append(self.gpa, @truncate(self.bits));
            self.bits = 0;
            self.count = 0;
        }
    }

    fn mask(n: u6) u32 {
        return if (n >= 32) 0xffff_ffff else (@as(u32, 1) << @intCast(n)) - 1;
    }
};

/// Canonical code lengths for a set of frequencies, none longer than
/// `max_code_length`.
///
/// Huffman's algorithm, and then a fixup, because Huffman's algorithm does
/// not respect a length limit: frequencies growing like the Fibonacci numbers
/// produce a code as long as the alphabet, and while that takes a very skewed
/// image it is reachable and a file with a sixteen-bit code in it is one no
/// decoder will read.
///
/// `lengths` is written for every symbol, zero where the symbol does not
/// occur. A caller with fewer than two used symbols should be writing the
/// simple form instead and gets `error.TooFewSymbols` here, because a code of
/// one symbol has no canonical lengths to describe it.
pub fn buildLengths(
    gpa: Allocator,
    freqs: []const u32,
    lengths: []u8,
    /// The longest code to allow. `max_code_length` for the codes that
    /// describe pixels; seven for the code that describes *their* lengths,
    /// whose own lengths are written in three bits each.
    limit: u8,
) (Allocator.Error || error{TooFewSymbols})!void {
    std.debug.assert(lengths.len == freqs.len);
    @memset(lengths, 0);

    var used: usize = 0;
    for (freqs) |f| {
        if (f != 0) used += 1;
    }
    if (used < 2) return error.TooFewSymbols;

    // The tree, as a flat array: `used` leaves and `used - 1` internal nodes,
    // each internal node created after both its children. That ordering is
    // what lets the depths be computed in one backwards pass instead of by
    // walking from every leaf to the root.
    const nodes = try gpa.alloc(Node, 2 * used - 1);
    defer gpa.free(nodes);
    const order = try gpa.alloc(u32, used);
    defer gpa.free(order);

    var n: usize = 0;
    for (freqs, 0..) |f, symbol| {
        if (f == 0) continue;
        nodes[n] = .{ .freq = f, .parent = 0, .symbol = @intCast(symbol) };
        order[n] = @intCast(n);
        n += 1;
    }

    // Leaves by frequency, ties by symbol, so that two encoders given the
    // same statistics write the same table.
    std.mem.sort(u32, order, nodes, lessByFreq);

    // Huffman's algorithm with two queues rather than a heap: the leaves are
    // already in order, and every node the merges produce comes out in order
    // too, so the smallest of the two fronts is the smallest overall and no
    // priority queue is needed.
    var leaf: usize = 0;
    var made: usize = used;
    var merged: usize = used;
    while (merged < nodes.len) : (merged += 1) {
        const a = takeSmallest(nodes, order, &leaf, used, &made, merged);
        const b = takeSmallest(nodes, order, &leaf, used, &made, merged);
        nodes[merged] = .{
            .freq = nodes[a].freq +| nodes[b].freq,
            .parent = 0,
            .symbol = 0,
        };
        nodes[a].parent = @intCast(merged);
        nodes[b].parent = @intCast(merged);
    }

    // Depths, root downwards. The root is the last node and has none.
    const depth = try gpa.alloc(u16, nodes.len);
    defer gpa.free(depth);
    depth[nodes.len - 1] = 0;
    var i = nodes.len - 1;
    while (i > 0) {
        i -= 1;
        depth[i] = depth[nodes[i].parent] + 1;
    }

    // How many codes of each length, which is all the fixup below needs: the
    // lengths are handed back out to symbols by frequency afterwards, so
    // which symbol had which length before it does not matter.
    var counts: [max_symbols + 1]u16 = @splat(0);
    var longest: usize = 0;
    for (0..used) |leaf_index| {
        const d = depth[leaf_index];
        counts[d] += 1;
        longest = @max(longest, d);
    }

    // Shorten anything past the limit. Taking two codes of length `i` and
    // making one of them `i - 1` needs a prefix to hang it from, so a code of
    // some shorter length `j` is split into two of length `j + 1`: the number
    // of codes is unchanged and the total number of bits goes up a little,
    // which is the price of the limit.
    var at = longest;
    while (at > limit) : (at -= 1) {
        while (counts[at] > 0) {
            var j = at - 2;
            while (counts[j] == 0) j -= 1;
            counts[at] -= 2;
            counts[at - 1] += 1;
            counts[j + 1] += 2;
            counts[j] -= 1;
        }
    }

    // And out to the symbols, the shortest codes to the most frequent, which
    // is the whole point of having done any of this.
    var slot: usize = used;
    for (1..@as(usize, limit) + 1) |len| {
        var k = counts[len];
        while (k > 0) : (k -= 1) {
            slot -= 1;
            lengths[nodes[order[slot]].symbol] = @intCast(len);
        }
    }
}

const Node = struct {
    freq: u32,
    parent: u32,
    symbol: u16,
};

fn lessByFreq(nodes: []const Node, a: u32, b: u32) bool {
    if (nodes[a].freq != nodes[b].freq) return nodes[a].freq < nodes[b].freq;
    return nodes[a].symbol < nodes[b].symbol;
}

/// The smallest node still unmerged, out of the leaves in `order` and the
/// internal nodes already made.
fn takeSmallest(
    nodes: []Node,
    order: []const u32,
    leaf: *usize,
    used: usize,
    made: *usize,
    merged: usize,
) usize {
    const have_leaf = leaf.* < used;
    const have_node = made.* < merged;
    if (have_leaf and (!have_node or nodes[order[leaf.*]].freq <= nodes[made.*].freq)) {
        const at = order[leaf.*];
        leaf.* += 1;
        return at;
    }
    const at = made.*;
    made.* += 1;
    return at;
}

/// The canonical codes a set of lengths describes.
pub fn assignCodes(lengths: []const u8, codes: []u16) void {
    std.debug.assert(lengths.len == codes.len);
    var counts: [max_code_length + 1]u16 = @splat(0);
    for (lengths) |l| {
        if (l != 0) counts[l] += 1;
    }
    var next: [max_code_length + 1]u16 = @splat(0);
    var code: u16 = 0;
    for (1..max_code_length + 1) |len| {
        code = (code + counts[len - 1]) << 1;
        next[len] = code;
    }
    for (lengths, codes) |l, *out| {
        if (l == 0) {
            out.* = 0;
            continue;
        }
        out.* = next[l];
        next[l] += 1;
    }
}

test "a code built from frequencies decodes back to the symbols it was built for" {
    const gpa = testing.allocator;
    // Skewed on purpose: the most frequent symbol must come out with the
    // shortest code, which is the whole point of building a table at all.
    const freqs = [_]u32{ 100, 1, 40, 0, 7, 2 };
    var lengths: [6]u8 = undefined;
    try buildLengths(gpa, &freqs, &lengths, max_code_length);

    try testing.expectEqual(@as(u8, 0), lengths[3]);
    try testing.expect(lengths[0] < lengths[4]);
    try testing.expect(lengths[4] <= lengths[1]);
    // Kraft's equality: a complete code spends exactly one.
    var kraft: f64 = 0;
    for (lengths) |l| {
        if (l != 0) kraft += std.math.pow(f64, 2, -@as(f64, @floatFromInt(l)));
    }
    try testing.expectApproxEqAbs(@as(f64, 1), kraft, 1e-9);

    var codes: [6]u16 = undefined;
    assignCodes(&lengths, &codes);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var w: BitWriter = .init(gpa, &out);
    const written = [_]u16{ 0, 2, 4, 1, 5, 0, 0 };
    for (written) |symbol| try w.putCode(codes[symbol], lengths[symbol]);
    try w.flush();

    var pool: SymbolPool = try .init(gpa, 64);
    defer pool.deinit(gpa);
    const code = try build(&lengths, &pool);

    var r: Io.Reader = .fixed(out.items);
    var br: BitReader = .init(&r);
    for (written) |want| try testing.expectEqual(want, try code.read(&br));
}

test "a code no longer than fifteen bits comes out of frequencies that want more" {
    const gpa = testing.allocator;
    // Fibonacci frequencies are the shape that makes Huffman's algorithm
    // produce a code as long as the alphabet: each symbol merges with the
    // sum of everything below it, so the tree is a comb.
    var freqs: [40]u32 = undefined;
    freqs[0] = 1;
    freqs[1] = 1;
    for (2..freqs.len) |i| freqs[i] = freqs[i - 1] + freqs[i - 2];

    var lengths: [40]u8 = undefined;
    try buildLengths(gpa, &freqs, &lengths, max_code_length);

    var longest: u8 = 0;
    for (lengths) |l| longest = @max(longest, l);
    try testing.expect(longest <= max_code_length);

    // And it is still a code: complete, and readable.
    var pool: SymbolPool = try .init(gpa, 128);
    defer pool.deinit(gpa);
    const code = try build(&lengths, &pool);

    var codes: [40]u16 = undefined;
    assignCodes(&lengths, &codes);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var w: BitWriter = .init(gpa, &out);
    for (0..40) |s| try w.putCode(codes[s], lengths[s]);
    try w.flush();

    var r: Io.Reader = .fixed(out.items);
    var br: BitReader = .init(&r);
    for (0..40) |s| try testing.expectEqual(@as(u16, @intCast(s)), try code.read(&br));
}

test "fewer than two symbols has no table to build" {
    const gpa = testing.allocator;
    var lengths: [4]u8 = undefined;
    try testing.expectError(error.TooFewSymbols, buildLengths(gpa, &.{ 0, 0, 0, 0 }, &lengths, max_code_length));
    try testing.expectError(error.TooFewSymbols, buildLengths(gpa, &.{ 0, 9, 0, 0 }, &lengths, max_code_length));
}

test "bits go out least significant first and codes go out top bit first" {
    const gpa = testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var w: BitWriter = .init(gpa, &out);

    try w.put(1, 1);
    try w.put(2, 2);
    try w.put(0b10100, 5);
    try w.flush();
    try testing.expectEqual(@as(u8, 0b1010_0101), out.items[0]);

    out.clearRetainingCapacity();
    var w2: BitWriter = .init(gpa, &out);
    // The code 0b110 goes out as 1, then 1, then 0 --- so the stream's first
    // bit is the code's top bit, and the byte reads 0b011 in the low three.
    try w2.putCode(0b110, 3);
    try w2.flush();
    try testing.expectEqual(@as(u8, 0b0000_0011), out.items[0]);
}
