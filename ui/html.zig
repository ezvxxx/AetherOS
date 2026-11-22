//! Streaming tokenizer for the native HTML reader.
const std = @import("std");

pub const Tag = struct {
    name: []const u8,
    attributes: []const u8,
    start: usize,
    closing: bool,
    self_closing: bool,
};

pub const Token = union(enum) { text: []const u8, tag: Tag };

pub const Tokenizer = struct {
    input: []const u8,
    pos: usize = 0,

    pub fn next(self: *Tokenizer) ?Token {
        const input = self.input;
        while (self.pos < input.len) {
            const start = self.pos;
            if (input[start] != '<') {
                self.pos = std.mem.indexOfScalarPos(u8, input, start, '<') orelse input.len;
                return .{ .text = input[start..self.pos] };
            }
            if (std.mem.startsWith(u8, input[start..], "<!--")) {
                self.pos = if (std.mem.indexOfPos(u8, input, start + 4, "-->")) |end| end + 3 else input.len;
                continue;
            }
            const lead = start + 1;
            if (lead < input.len and (input[lead] == '!' or input[lead] == '?')) {
                self.pos = if (std.mem.indexOfScalarPos(u8, input, lead + 1, '>')) |end| end + 1 else input.len;
                continue;
            }
            const closing = lead < input.len and input[lead] == '/';
            const name_start = lead + @intFromBool(closing);
            if (name_start == input.len or !std.ascii.isAlphabetic(input[name_start])) {
                self.pos += 1;
                return .{ .text = input[start..self.pos] };
            }
            var name_end = name_start;
            while (name_end < input.len and !space(input[name_end]) and input[name_end] != '/' and input[name_end] != '>') : (name_end += 1) {}
            const end = tagEnd(input, name_end) orelse {
                self.pos = input.len;
                return null;
            };
            const trimmed = std.mem.trimEnd(u8, input[name_end..end], " \t\r\n\x0c");
            self.pos = end + 1;
            return .{ .tag = .{
                .name = input[name_start..name_end],
                .attributes = input[name_end..end],
                .start = start,
                .closing = closing,
                .self_closing = std.mem.endsWith(u8, trimmed, "/"),
            } };
        }
        return null;
    }

    /// Raw text can contain markup-like characters. Only its own closing tag ends it.
    pub fn rawText(self: *Tokenizer, name: []const u8) []const u8 {
        const start = self.pos;
        var search = start;
        while (std.mem.indexOfPos(u8, self.input, search, "</")) |open| {
            const after = open + 2 + name.len;
            if (after >= self.input.len) break;
            if (std.ascii.eqlIgnoreCase(self.input[open + 2 .. after], name) and
                (space(self.input[after]) or self.input[after] == '>'))
            {
                if (tagEnd(self.input, after)) |end| {
                    self.pos = end + 1;
                    return self.input[start..open];
                }
                break;
            }
            search = open + 2;
        }
        self.pos = self.input.len;
        return self.input[start..];
    }

    pub fn skipElement(self: *Tokenizer, name: []const u8) void {
        var depth: usize = 1;
        while (self.next()) |token| {
            if (token != .tag) continue;
            const tag = token.tag;
            if (std.ascii.eqlIgnoreCase(tag.name, name)) {
                if (tag.closing) {
                    depth -= 1;
                    if (depth == 0) return;
                } else if (!tag.self_closing) depth += 1;
            } else if (!tag.closing and isRawText(tag.name)) {
                _ = self.rawText(tag.name);
            }
        }
    }
};

pub fn isRawText(name: []const u8) bool {
    for ([_][]const u8{ "script", "style", "title", "textarea", "iframe" }) |raw| {
        if (std.ascii.eqlIgnoreCase(name, raw)) return true;
    }
    return false;
}

fn space(ch: u8) bool {
    return switch (ch) {
        ' ', '\t', '\r', '\n', 0x0c => true,
        else => false,
    };
}

fn tagEnd(input: []const u8, start: usize) ?usize {
    var quote: u8 = 0;
    for (input[start..], start..) |ch, index| {
        if (quote != 0) {
            if (quote == ch) quote = 0;
        } else switch (ch) {
            '"', '\'' => quote = ch,
            '>' => return index,
            else => {},
        }
    }
    return null;
}

pub fn attribute(attributes: []const u8, wanted: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < attributes.len) {
        while (i < attributes.len and (space(attributes[i]) or attributes[i] == '/')) : (i += 1) {}
        const start = i;
        while (i < attributes.len and !space(attributes[i]) and attributes[i] != '=' and attributes[i] != '/') : (i += 1) {}
        if (i == start) {
            if (i == attributes.len) break;
            i += 1;
            continue;
        }
        const name = attributes[start..i];
        while (i < attributes.len and space(attributes[i])) : (i += 1) {}
        var value: []const u8 = "";
        if (i < attributes.len and attributes[i] == '=') {
            i += 1;
            while (i < attributes.len and space(attributes[i])) : (i += 1) {}
            const quote = if (i < attributes.len and (attributes[i] == '"' or attributes[i] == '\'')) attributes[i] else 0;
            if (quote != 0) i += 1;
            const value_start = i;
            while (i < attributes.len and (if (quote != 0) attributes[i] != quote else !space(attributes[i]))) : (i += 1) {}
            value = attributes[value_start..i];
            if (quote != 0 and i < attributes.len) i += 1;
        }
        if (std.ascii.eqlIgnoreCase(name, wanted)) return value;
    }
    return null;
}

pub fn isVoid(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "area") or std.ascii.eqlIgnoreCase(name, "base") or std.ascii.eqlIgnoreCase(name, "br") or
        std.ascii.eqlIgnoreCase(name, "col") or std.ascii.eqlIgnoreCase(name, "embed") or std.ascii.eqlIgnoreCase(name, "hr") or
        std.ascii.eqlIgnoreCase(name, "img") or std.ascii.eqlIgnoreCase(name, "input") or std.ascii.eqlIgnoreCase(name, "link") or
        std.ascii.eqlIgnoreCase(name, "meta") or std.ascii.eqlIgnoreCase(name, "param") or std.ascii.eqlIgnoreCase(name, "source") or
        std.ascii.eqlIgnoreCase(name, "track") or std.ascii.eqlIgnoreCase(name, "wbr");
}
