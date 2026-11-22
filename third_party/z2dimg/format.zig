// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Telling one image format from another by the bytes it starts with.
//!
//! None of this trusts a file name. A decoder is the most exposed thing in a
//! program that opens images, and choosing which one to run by looking at an
//! extension means an attacker chooses it instead.
//!
//! Detection reads from the front of the stream **without consuming it**, so
//! that the codec it selects sees the signature too and can check it again for
//! itself. That is what `Io.Reader.peek` is for, and it is the reason this
//! library asks a caller for a reader with a buffer of at least
//! `min_buffer_len` bytes.

const std = @import("std");
const Io = std.Io;
const mem = std.mem;

const ico = @import("ico.zig");
const pcx = @import("pcx.zig");
const tga = @import("tga.zig");
const webp = @import("webp.zig");
const testing = std.testing;

/// The image formats this library knows how to recognise.
///
/// Recognising a format and being able to decode it are different things:
/// `detect` names a PNG whether or not the PNG codec is finished, so that the
/// error a caller gets says "this library cannot read a PNG yet" rather than
/// "this is not an image".
pub const Format = enum {
    bmp,
    png,
    jpeg,
    xbm,
    xpm,
    gif,
    tga,
    pbm,
    pgm,
    ppm,
    pam,
    pcx,
    ico,
    /// Appended rather than placed alphabetically, and every future format
    /// should be too: `sandbox.zig` puts `@intFromEnum(Format) + 1` on the
    /// wire, so the order of this enum is part of a protocol.
    webp,

    /// The conventional file extension, without the dot. For messages and for
    /// naming files that are written out; never for deciding what to decode.
    pub fn extension(self: Format) []const u8 {
        return switch (self) {
            .bmp => "bmp",
            .png => "png",
            .jpeg => "jpg",
            .xbm => "xbm",
            .xpm => "xpm",
            .gif => "gif",
            .tga => "tga",
            .pbm => "pbm",
            .pgm => "pgm",
            .ppm => "ppm",
            .pam => "pam",
            .pcx => "pcx",
            .ico => "ico",
            .webp => "webp",
        };
    }

    /// The IANA media type.
    pub fn mediaType(self: Format) []const u8 {
        return switch (self) {
            .bmp => "image/bmp",
            .png => "image/png",
            .jpeg => "image/jpeg",
            // Not registered with IANA. `image/x-xbitmap` is what browsers
            // sent for these when they still displayed them, and what every
            // table of media types lists.
            .xbm => "image/x-xbitmap",
            .xpm => "image/x-xpixmap",
            .gif => "image/gif",
            // Not registered with IANA either; this is what every table lists.
            .tga => "image/x-targa",
            // Nor are these four, which is why every one of them is an
            // `x-` name. They are what the netpbm tools themselves use.
            .pbm => "image/x-portable-bitmap",
            .pgm => "image/x-portable-graymap",
            .ppm => "image/x-portable-pixmap",
            .pam => "image/x-portable-arbitrarymap",
            // Not registered either. `image/x-pcx` is what every table lists
            // and what the browsers sent when they still displayed these.
            .pcx => "image/x-pcx",
            // The one in this tail that IANA did register.
            .ico => "image/vnd.microsoft.icon",
            .webp => "image/webp",
        };
    }
};

/// The number of bytes `detect` needs to see, and so the smallest buffer a
/// `Io.Reader` handed to this library may have.
///
/// A hundred and twenty-eight, which two formats need and the rest do not.
///
/// Every format here with a real signature has one of nine bytes or fewer and
/// would be happy with nine. Two have no signature worth the name, and each
/// pushes this out for its own reason.
///
/// **XBM** has none at all. It is C source, and the only thing separating one
/// from any other header is a `#define` whose name ends in `_width`, sitting
/// at an offset that depends on how long somebody's variable name is; sixty
/// four bytes reaches it for any name a person would write.
///
/// **PCX** has one magic byte, which is not enough to act on --- a great many
/// files begin with a newline. What makes it identifiable is four more fields
/// that have to hold values the format defines, and the last of them is the
/// row stride at bytes sixty-six and sixty-seven. Reading those means having
/// the header, which is a hundred and twenty-eight bytes, so that is what
/// this is.
///
/// A reader buffer of a hundred and twenty-eight bytes costs a caller nothing,
/// which is the only reason it is reasonable to ask for one.
pub const min_buffer_len = 128;

/// PNG's signature is eight bytes and every one of them is doing a job: the
/// high bit catches a transport that stripped it, `PNG` names the format,
/// `\r\n` and the lone `\n` catch a transfer that translated line endings, and
/// the `\x1a` stops a DOS `TYPE` of the file from scrolling the binary past.
const png_signature = "\x89PNG\r\n\x1a\n";

/// JPEG starts with the Start Of Image marker, and the third byte begins the
/// marker that follows it — always `\xff`, since every JPEG marker does.
/// Checking it costs nothing and rules out a file that is two bytes of
/// coincidence.
const jpeg_signature = "\xff\xd8\xff";

/// A Windows BMP starts with `BM`, and that is the whole of its signature: two
/// bytes, which is weak enough that anything acting on it should be ready for
/// the header behind it not to parse. The OS/2 bitmap array and icon variants
/// (`BA`, `CI`, `CP`, `IC`, `PT`) are deliberately not matched — this library
/// does not decode them, and claiming a file is a BMP that it then refuses is
/// worse than not claiming it.
const bmp_signature = "BM";

/// An XPM has one: the comment every file of the format begins with, which
/// the specification requires and every writer emits.
const xpm_signature = "/* XPM */";

/// GIF names its own version in its signature. Both are read, so both are
/// matched, and the six bytes they share are what a short window can be tested
/// against.
const gif_signatures = [_][]const u8{ "GIF87a", "GIF89a" };

/// Netpbm's is three bytes and only two of them are constant: `P`, a digit
/// from `1` to `7` naming which of the seven layouts follows, and then
/// whitespace. The whitespace is load-bearing --- without it `P6DATA` would
/// be a PPM, and the rule "a letter, a digit, and then a separator" is what
/// keeps this from claiming any file that happens to start with a `P`.
fn looksLikeNetpbm(bytes: []const u8) ?Format {
    if (bytes.len < 3 or bytes[0] != 'P') return null;
    if (!isSpace(bytes[2])) return null;
    return switch (bytes[1]) {
        '1', '4' => .pbm,
        '2', '5' => .pgm,
        '3', '6' => .ppm,
        '7' => .pam,
        else => null,
    };
}

/// Whether a window is still consistent with being a Netpbm file: `P`, or `P`
/// and a digit that names one of the seven, with the separator not yet
/// visible.
fn couldBeNetpbm(bytes: []const u8) bool {
    if (bytes.len == 0 or bytes.len >= 3) return false;
    if (bytes[0] != 'P') return false;
    return bytes.len == 1 or (bytes[1] >= '1' and bytes[1] <= '7');
}

/// The format `bytes` begins with, or null if it begins with none of them.
///
/// A short slice is answered honestly: fewer bytes than a signature needs
/// cannot match it, so a two-byte slice can still come back `.bmp` but never
/// `.png`.
pub fn detect(bytes: []const u8) ?Format {
    if (mem.startsWith(u8, bytes, png_signature)) return .png;
    if (mem.startsWith(u8, bytes, jpeg_signature)) return .jpeg;
    if (mem.startsWith(u8, bytes, bmp_signature)) return .bmp;
    if (mem.startsWith(u8, bytes, xpm_signature)) return .xpm;
    for (gif_signatures) |sig| {
        if (mem.startsWith(u8, bytes, sig)) return .gif;
    }
    if (looksLikeNetpbm(bytes)) |fmt| return fmt;
    // A signature in two halves with a length between them, which is why it
    // is a predicate here rather than an entry in `signatures`.
    if (webp.looksLikeHeader(bytes)) return .webp;
    // Six bytes, four of them constrained: two of reserved zero, a type that
    // is one of two values, and a count that cannot be zero.
    if (ico.looksLikeHeader(bytes)) return .ico;
    // Before TGA, which has no signature at all, and after everything that
    // has a real one: a PCX begins with a single magic byte and is told apart
    // from a file that happens to start with it by four more fields that have
    // to hold values the format defines. See `pcx.looksLikeHeader`.
    if (pcx.looksLikeHeader(bytes)) return .pcx;
    // Last, and not a signature at all: a TGA has none, so this is a
    // structural check on its header and is only reached once every real
    // signature has been ruled out. See `tga.looksLikeHeader`.
    if (tga.looksLikeHeader(bytes)) return .tga;
    if (looksLikeXbm(bytes)) return .xbm;
    return null;
}

/// Whether a window begins a `#define` whose name ends in `_width`.
///
/// Both halves are needed. `#define` alone is every C header ever written, and
/// `_width` alone appears in plenty of source that is not an image; together,
/// as the first thing in a file, they are an XBM or something deliberately
/// imitating one.
///
/// The rule is deliberately "the first thing in the file", not "somewhere near
/// the start". A comment may precede the directive in a *valid* XBM and the
/// decoder accepts one, but a comment can be any length at all, so no window
/// is wide enough to see past every one of them — and a detector whose answer
/// depends on how chatty the generator was is worse than one with a rule that
/// can be stated. A file with a comment in front of its defines is read with
/// `decodeAs`.
fn looksLikeXbm(bytes: []const u8) bool {
    var at: usize = 0;
    while (at < bytes.len and isSpace(bytes[at])) at += 1;
    if (!mem.startsWith(u8, bytes[at..], xbm_directive)) return false;
    at += xbm_directive.len;

    // The name, which has to end in `_width` --- so `_width_of_something` is
    // not one, and neither is anything that merely contains it.
    while (at < bytes.len and isSpace(bytes[at])) at += 1;
    const start = at;
    while (at < bytes.len and isNameByte(bytes[at])) at += 1;
    return mem.endsWith(u8, bytes[start..at], "_width");
}

const xbm_directive = "#define";

fn isSpace(b: u8) bool {
    return b == ' ' or b == '\t' or b == '\r' or b == '\n';
}

fn isNameByte(b: u8) bool {
    return (b >= 'a' and b <= 'z') or (b >= 'A' and b <= 'Z') or
        (b >= '0' and b <= '9') or b == '_';
}

/// Errors from looking at the front of a stream.
pub const DetectError = error{
    /// The stream does not begin with a signature this library recognises.
    UnknownFormat,
    /// The reader was given a buffer smaller than `min_buffer_len`, so the
    /// signature cannot be examined without consuming it.
    ///
    /// This is a mistake in the calling program rather than anything about the
    /// image, and it is an error rather than a panic because a library has no
    /// business crashing a caller over its own buffer size.
    BufferTooSmall,
} || Io.Reader.Error;

/// Every fixed signature, so that a short window can be asked whether it is
/// still consistent with one of them.
///
/// Four formats are missing from this list and each is answered by a
/// function of its own below. XBM has no signature at all; Netpbm's is a
/// pattern rather than a string, since two of its three bytes vary; TGA's is
/// not a signature but a structural reading of its whole header; and WebP's
/// is in two halves with the file's length between them, which a prefix test
/// cannot express.
const signatures = [_][]const u8{
    png_signature,
    jpeg_signature,
    bmp_signature,
    xpm_signature,
    gif_signatures[0],
    gif_signatures[1],
};

/// Whether `bytes` is a prefix of a signature, and so might still turn out to
/// be one if more of the stream were visible.
///
/// This is what makes a small window usable. Signatures are prefixes, so two
/// bytes that match no signature's first two bytes cannot become a match
/// however many more arrive — and two bytes that do are not yet an answer.
fn couldMatch(bytes: []const u8) bool {
    for (signatures) |sig| {
        if (sig.len > bytes.len and mem.startsWith(u8, sig, bytes)) return true;
    }
    return false;
}

/// Whether a window is still consistent with being an XBM.
///
/// A window holding a prefix of `#define`, or a `#define` whose name has not
/// been seen to its end, may still turn out to be one.
fn couldBeXbm(bytes: []const u8) bool {
    var at: usize = 0;
    while (at < bytes.len and isSpace(bytes[at])) at += 1;
    const rest = bytes[at..];
    if (rest.len < xbm_directive.len) return mem.startsWith(u8, xbm_directive, rest);
    if (!mem.startsWith(u8, rest, xbm_directive)) return false;
    // The name runs to the end of what is visible, so `_width` may be just
    // past it.
    var name = rest[xbm_directive.len..];
    var i: usize = 0;
    while (i < name.len and isSpace(name[i])) i += 1;
    name = name[i..];
    for (name) |b| {
        if (!isNameByte(b)) return false; // the name ended, and did not match
    }
    return true;
}

/// The format the stream begins with, leaving the stream where it found it.
///
/// Nothing is consumed: on return the next byte to be read is still the first
/// byte of the signature.
///
/// The window examined is `min_buffer_len` bytes, or the reader's whole buffer
/// if that is smaller, or whatever the stream had if it ended first. A window
/// too short to be conclusive is `error.BufferTooSmall` — but only when it is
/// genuinely inconclusive, which is to say when what was seen is still a
/// prefix of some signature. Two bytes of a JSON document are a short window
/// and a certain answer.
pub fn detectReader(r: *Io.Reader) DetectError!Format {
    const want = @min(min_buffer_len, r.buffer.len);
    var ended = false;
    const window = r.peek(want) catch |err| switch (err) {
        error.EndOfStream => blk: {
            // The stream is shorter than the window. What there is, is all
            // there will ever be, which makes it a conclusive answer.
            ended = true;
            break :blk r.buffered();
        },
        error.ReadFailed => |e| return e,
    };

    if (detect(window)) |fmt| return fmt;
    if (!ended and window.len < min_buffer_len and
        (couldMatch(window) or couldBeXbm(window) or couldBeNetpbm(window) or
            webp.couldBeHeader(window)))
        return error.BufferTooSmall;
    return error.UnknownFormat;
}

test "each signature is recognised" {
    try testing.expectEqual(Format.png, detect("\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR").?);
    try testing.expectEqual(Format.jpeg, detect("\xff\xd8\xff\xe0\x00\x10JFIF").?);
    try testing.expectEqual(Format.bmp, detect("BM\x36\x00\x00\x00").?);
}

test "near misses are not recognised" {
    // The high bit stripped from PNG's first byte, which is exactly what that
    // byte is there to catch.
    try testing.expectEqual(@as(?Format, null), detect("\x09PNG\r\n\x1a\n"));
    // A JPEG SOI with no marker behind it.
    try testing.expectEqual(@as(?Format, null), detect("\xff\xd8\x00"));
    // OS/2 variants, which this library does not decode.
    try testing.expectEqual(@as(?Format, null), detect("BA\x00\x00"));
    try testing.expectEqual(@as(?Format, null), detect(""));
    try testing.expectEqual(@as(?Format, null), detect("not an image at all"));
}

test "a stream shorter than the window is still identified" {
    var r: Io.Reader = .fixed("BM");
    try testing.expectEqual(Format.bmp, try detectReader(&r));
    // And nothing was consumed.
    try testing.expectEqual(@as(usize, 2), r.bufferedLen());
}

test "a short window that matches nothing is still an answer" {
    // Two bytes, no buffer to speak of, and not the start of any signature:
    // there is no point reporting that the buffer was small.
    var r: Io.Reader = .fixed("ZQ");
    try testing.expectError(error.UnknownFormat, detectReader(&r));

    // Whereas two bytes that *are* the start of one cannot be answered yet,
    // which is the distinction this is about.
    var gif: Io.Reader = .fixed("GI");
    try testing.expectError(error.BufferTooSmall, detectReader(&gif));
}

test "a short window that is still ambiguous says so" {
    // The first two bytes of PNG's signature and nowhere to put the rest.
    var tiny: [2]u8 = undefined;
    var underlying: Io.Reader = .fixed("\x89PNG\r\n\x1a\n");
    var limited = underlying.limited(.unlimited, &tiny);
    try testing.expectError(error.BufferTooSmall, detectReader(&limited.interface));
}

test "detectReader leaves the signature in place" {
    var r: Io.Reader = .fixed("\x89PNG\r\n\x1a\n\x00\x00\x00\x0d");
    try testing.expectEqual(Format.png, try detectReader(&r));
    try testing.expectEqualSlices(u8, "\x89PNG\r\n\x1a\n", try r.take(8));
}

test "an unrecognised stream is an error rather than a guess" {
    var r: Io.Reader = .fixed("not an image at all, just some text");
    try testing.expectError(error.UnknownFormat, detectReader(&r));
}

test "extensions and media types" {
    try testing.expectEqualStrings("bmp", Format.bmp.extension());
    try testing.expectEqualStrings("image/jpeg", Format.jpeg.mediaType());
}
