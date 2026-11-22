//! Bounded support for top-level insertAdjacentHTML calls with literal arguments.
const std = @import("std");
const html = @import("html.zig");
const eql = std.mem.eql;

const max_scripts = 4;
const max_source = 64 * 1024;
const max_insertions = 32;
const max_added = 32 * 1024;
var document: [1024 * 1024 + max_added]u8 = undefined;
var fragment: [max_added]u8 = undefined;

pub const Result = struct { markup: []const u8, applied: usize };

pub fn apply(input: []const u8, fetch: *const fn ([]const u8) ?[]const u8) Result {
    if (input.len > document.len - max_added) return .{ .markup = input, .applied = 0 };
    var scan: html.Tokenizer = .{ .input = input };
    var length = input.len;
    var applied: usize = 0;
    var scripts: usize = 0;
    var copied = false;
    while (scan.next()) |token| {
        if (token != .tag or token.tag.closing or !html.isRawText(token.tag.name)) continue;
        const tag = token.tag;
        const inline_source = scan.rawText(tag.name);
        if (!std.ascii.eqlIgnoreCase(tag.name, "script")) continue;
        if (scripts == max_scripts or applied == max_insertions) break;
        if (html.attribute(tag.attributes, "type")) |kind| {
            if (kind.len != 0 and !std.ascii.eqlIgnoreCase(kind, "text/javascript") and
                !std.ascii.eqlIgnoreCase(kind, "application/javascript")) continue;
        }
        scripts += 1;
        const source = if (html.attribute(tag.attributes, "src")) |url| fetch(url) orelse continue else inline_source;
        if (source.len > max_source) continue;
        var lexer: Lexer = .{ .source = source };
        var alias: []const u8 = "";
        while (lexer.statement()) |statement| {
            var parser: Lexer = .{ .source = statement };
            const head = parser.next() orelse continue;
            if (eql(u8, head, "var") or eql(u8, head, "let") or eql(u8, head, "const")) {
                const name = parser.next() orelse continue;
                if (isIdentifier(name[0]) and parser.take("=") and parser.bodyReference("")) {
                    if (parser.next()) |tail| {
                        if (!eql(u8, tail, ",")) continue;
                    }
                    alias = name;
                }
                continue;
            }
            parser.pos = 0;
            if (!parser.bodyReference(alias) or !parser.take(".")) continue;
            var child: ?usize = null;
            if (parser.take("children")) {
                if (!parser.take("[")) continue;
                const number = parser.next() orelse continue;
                child = std.fmt.parseInt(usize, number, 10) catch continue;
                if (!parser.take("]") or !parser.take(".")) continue;
            }
            if (!parser.take("insertAdjacentHTML") or !parser.take("(")) continue;
            const position = stringLiteral(parser.next() orelse continue) orelse continue;
            if (!parser.take(",")) continue;
            const raw = stringLiteral(parser.next() orelse continue) orelse continue;
            if (!parser.take(")") or parser.next() != null) continue;
            const bytes = decode(raw) orelse continue;
            if (bytes.len == 0 or bytes.len > max_added - (length - input.len)) continue;
            const current = if (copied) document[0..length] else input;
            const index = insertionOffset(current, child, position) orelse continue;
            if (!copied) {
                @memcpy(document[0..length], input);
                copied = true;
            }
            std.mem.copyBackwards(u8, document[index + bytes.len .. length + bytes.len], document[index..length]);
            @memcpy(document[index..][0..bytes.len], bytes);
            length += bytes.len;
            applied += 1;
            if (applied == max_insertions) break;
        }
    }
    return .{ .markup = if (copied) document[0..length] else input, .applied = applied };
}

fn insertionOffset(doc: []const u8, child: ?usize, position: []const u8) ?usize {
    const before = std.ascii.eqlIgnoreCase(position, "beforebegin");
    const after = std.ascii.eqlIgnoreCase(position, "afterend");
    const first = std.ascii.eqlIgnoreCase(position, "afterbegin");
    const last = std.ascii.eqlIgnoreCase(position, "beforeend");
    if (!before and !after and !first and !last) return null;
    var tokens: html.Tokenizer = .{ .input = doc };
    var in_body = false;
    var index: usize = 0;
    while (tokens.next()) |token| {
        if (token != .tag) continue;
        const tag = token.tag;
        if (!in_body) {
            if (!tag.closing and std.ascii.eqlIgnoreCase(tag.name, "body")) {
                in_body = true;
                if (child == null) {
                    if (before) return tag.start;
                    if (first) return tokens.pos;
                }
            } else if (!tag.closing and html.isRawText(tag.name)) _ = tokens.rawText(tag.name);
            continue;
        }
        if (tag.closing) {
            if (!std.ascii.eqlIgnoreCase(tag.name, "body")) continue;
            if (child != null) return null;
            return if (after) tokens.pos else tag.start;
        }
        const selected = child == index;
        if (selected and before) return tag.start;
        if (selected and first) return tokens.pos;
        if (tag.self_closing or html.isVoid(tag.name)) {
            if (selected) return if (after) tokens.pos else null;
        } else if (html.isRawText(tag.name)) {
            const raw = tokens.rawText(tag.name);
            if (selected) return if (after) tokens.pos else @intFromPtr(raw.ptr) - @intFromPtr(doc.ptr) + raw.len;
        } else {
            var closing: usize = tokens.pos;
            var depth: usize = 1;
            while (tokens.next()) |nested| {
                if (nested != .tag) continue;
                const item = nested.tag;
                if (std.ascii.eqlIgnoreCase(item.name, tag.name)) {
                    if (item.closing) {
                        depth -= 1;
                        if (depth == 0) {
                            closing = item.start;
                            break;
                        }
                    } else if (!item.self_closing) depth += 1;
                } else if (!item.closing and html.isRawText(item.name)) _ = tokens.rawText(item.name);
            }
            if (selected) return if (after) tokens.pos else closing;
        }
        index += 1;
    }
    return if (in_body and child == null and last) doc.len else null;
}

fn isIdentifier(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '$';
}

fn stringLiteral(token: []const u8) ?[]const u8 {
    if (token.len < 2 or (token[0] != '\'' and token[0] != '"') or token[token.len - 1] != token[0]) return null;
    return token[1 .. token.len - 1];
}

fn decode(raw: []const u8) ?[]const u8 {
    if (raw.len > fragment.len) return null;
    var count: usize = 0;
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        var ch = raw[i];
        if (ch == '\\') {
            i += 1;
            if (i == raw.len) return null;
            ch = switch (raw[i]) {
                'n' => '\n',
                'r' => '\r',
                't' => '\t',
                '\'', '"', '\\', '/' => raw[i],
                else => return null,
            };
        }
        fragment[count] = ch;
        count += 1;
    }
    return fragment[0..count];
}

const Lexer = struct {
    source: []const u8,
    pos: usize = 0,

    fn bodyReference(self: *Lexer, alias: []const u8) bool {
        if (alias.len != 0 and self.take(alias)) return true;
        return self.take("document") and self.take(".") and self.take("body");
    }

    fn take(self: *Lexer, expected: []const u8) bool {
        const saved = self.pos;
        if (self.next()) |token| if (eql(u8, token, expected)) return true;
        self.pos = saved;
        return false;
    }

    fn next(self: *Lexer) ?[]const u8 {
        const source = self.source;
        while (self.pos < source.len) {
            if (std.ascii.isWhitespace(source[self.pos])) {
                self.pos += 1;
            } else if (std.mem.startsWith(u8, source[self.pos..], "//")) {
                self.pos = std.mem.indexOfScalarPos(u8, source, self.pos, '\n') orelse source.len;
            } else if (std.mem.startsWith(u8, source[self.pos..], "/*")) {
                self.pos = if (std.mem.indexOfPos(u8, source, self.pos + 2, "*/")) |end| end + 2 else source.len;
            } else break;
        }
        if (self.pos == source.len) return null;
        const start = self.pos;
        const lead = source[start];
        self.pos += 1;
        if (lead == '"' or lead == '\'' or lead == '`') {
            while (self.pos < source.len) {
                const ch = source[self.pos];
                self.pos += 1;
                if (ch == lead) return source[start..self.pos];
                if (ch == '\\' and self.pos < source.len) self.pos += 1;
            }
            return null;
        }
        if (isIdentifier(lead)) while (self.pos < source.len and isIdentifier(source[self.pos])) {
            self.pos += 1;
        };
        return source[start..self.pos];
    }

    fn statement(self: *Lexer) ?[]const u8 {
        if (self.pos == self.source.len) return null;
        const start = self.pos;
        var depth: usize = 0;
        while (self.next()) |token| {
            if (token.len != 1) continue;
            switch (token[0]) {
                '(', '[', '{' => depth += 1,
                ')', ']', '}' => depth -|= 1,
                ';' => if (depth == 0) return self.source[start .. self.pos - 1],
                else => {},
            }
        }
        return self.source[start..self.pos];
    }
};
