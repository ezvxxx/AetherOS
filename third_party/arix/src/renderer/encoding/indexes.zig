//! AetherOS currently feeds the renderer UTF-8 response bodies. Keep the
//! encoding decoder API but omit multi-megabyte legacy charset lookup tables.
//! Non-UTF-8 legacy encodings therefore decode as replacement characters.
const Encoding = @import("encoding.zig").Encoding;
const empty_index: []const u21 = &.{};
const empty_ranges: []const [2]u32 = &.{};
const empty_single_byte: [128]u21 = @splat(0);

pub const big5 = empty_index;
pub const euc_kr = empty_index;
pub const gb18030 = empty_index;
pub const jis0208 = empty_index;
pub const jis0212 = empty_index;

pub fn codePoint(index: []const u21, pointer: usize) ?u21 {
    if (pointer >= index.len or index[pointer] == 0) return null;
    return index[pointer];
}

pub fn singleByte(_: Encoding) *const [128]u21 { return &empty_single_byte; }

pub fn gb18030RangeCodePoint(_: u32) ?u21 { return null; }
