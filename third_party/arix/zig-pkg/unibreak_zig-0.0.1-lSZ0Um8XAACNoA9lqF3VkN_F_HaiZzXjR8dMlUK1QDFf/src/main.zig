const std = @import("std");
pub const raw = @import("c");

/// Returns UTF-8 offsets after allowed/mandatory breaks, including the end.
pub fn lineBreaks(allocator: std.mem.Allocator, text: []const u8) ![]usize {
    return boundaries(allocator, text, false);
}

/// Returns extended-grapheme boundaries, including zero and the exclusive end.
pub fn graphemeBreaks(allocator: std.mem.Allocator, text: []const u8) ![]usize {
    return boundaries(allocator, text, true);
}

fn boundaries(allocator: std.mem.Allocator, text: []const u8, grapheme: bool) ![]usize {
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
    const flags = try allocator.alloc(u8, text.len);
    defer allocator.free(flags);
    if (text.len != 0) {
        if (grapheme)
            raw.set_graphemebreaks_utf8(text.ptr, text.len, null, @ptrCast(flags.ptr))
        else
            raw.set_linebreaks_utf8(text.ptr, text.len, null, @ptrCast(flags.ptr));
    }

    var result: std.ArrayList(usize) = .empty;
    errdefer result.deinit(allocator);
    if (grapheme) try result.append(allocator, 0);
    for (flags, 0..) |flag, i| {
        const allowed = if (grapheme)
            flag == raw.GRAPHEMEBREAK_BREAK
        else
            flag == raw.LINEBREAK_ALLOWBREAK or flag == raw.LINEBREAK_MUSTBREAK;

        if (allowed or i + 1 == text.len) try result.append(allocator, i + 1);
    }

    return result.toOwnedSlice(allocator);
}

test "Unicode breaks use byte offsets and preserve graphemes" {
    const allocator = std.testing.allocator;
    const lines = try lineBreaks(allocator, "😀 😀");
    defer allocator.free(lines);
    try std.testing.expectEqualSlices(usize, &.{ 5, 9 }, lines);

    const graphemes = try graphemeBreaks(allocator, "a\u{301}👩‍👩‍👧‍👦b");
    defer allocator.free(graphemes);
    try std.testing.expectEqualSlices(usize, &.{ 0, 3, 28, 29 }, graphemes);
    try std.testing.expectError(error.InvalidUtf8, lineBreaks(allocator, "\xff"));
}
