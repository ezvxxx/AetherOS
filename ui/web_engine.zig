//! AetherOS web engine. Fetching and navigation are supplied by the browser app.
const std = @import("std");
const canvas = @import("../graphics/canvas.zig");
const font = @import("../graphics/font.zig");
const media = @import("../graphics/media.zig");
const svg = @import("../graphics/svg.zig");
const css = @import("css.zig");
const html = @import("html.zig");
const equalIgnoreCase = std.ascii.eqlIgnoreCase;

pub const max_url = 320;
const max_page = 16384;
const max_inline_images = 16;
const max_block_boxes = 256;
const max_links = 48;

pub const Resources = struct {
    resolve: *const fn ([]const u8, *[max_url]u8) ?usize,
    stylesheet: *const fn ([]const u8) ?[]const u8,
    image: *const fn ([]const u8) ?media.Picture,
};

const BlockBox = struct {
    start_line: usize = 0,
    end_line: usize = 0,
    style: css.Computed = .{},
    image_id: ?u8 = null,
};

var page: [max_page]u8 = @splat(0);
var page_colors: [max_page]u24 = @splat(0);
var page_backgrounds: [max_page]u24 = @splat(0);
var page_style_flags: [max_page]u8 = @splat(0);
var page_decorations: [max_page]u8 = @splat(0);
var page_letter_spacing: [max_page]i8 = @splat(0);
var page_word_spacing: [max_page]u8 = @splat(0);
var page_line_heights: [max_page]u8 = @splat(10);
var page_font_scales: [max_page]u8 = @splat(1);
var page_align_starts: [max_page]u16 = @splat(0);
var page_align_widths: [max_page]u16 = @splat(0);
var page_background_color: ?u24 = null;
var page_len: usize = 0;
var page_lines: usize = 0;
var page_scroll: usize = 0;
pub var page_title: [128]u8 = @splat(0);
pub var page_title_len: usize = 0;
const Link = struct { url: [max_url]u8 = undefined, url_len: usize = 0 };
var links: [max_links]Link = @splat(.{});
var link_count: usize = 0;
var active_link: u8 = 0;
var page_link_ids: [max_page]u8 = undefined;
var rendering_style: css.Computed = .{};
var flow_style: css.Computed = .{};
var flow_indent: usize = 0;
var flow_right_inset: usize = 0;
var flow_font_scale: usize = 1;
var flow_align_start: usize = 0;
var flow_align_width: usize = 0;
var inline_images: [max_inline_images]?media.Picture = @splat(null);
var page_media_ids: [max_page]u8 = @splat(0);
var page_media_widths: [max_page]u16 = @splat(0);
var page_media_heights: [max_page]u16 = @splat(0);
var page_media_fit_modes: [max_page]u8 = @splat(0);
var block_boxes: [max_block_boxes]BlockBox = @splat(.{});
var block_box_count: usize = 0;

fn clearInlineImages() void {
    for (&inline_images) |*image| {
        if (image.*) |picture| media.release(picture);
        image.* = null;
    }
}

fn storeInlineImage(picture: media.Picture) ?u8 {
    for (inline_images, 0..) |image, image_index| if (image == null) {
        inline_images[image_index] = picture;
        return @intCast(image_index);
    };
    media.release(picture);
    return null;
}

pub fn clear() void {
    clearInlineImages();
    page_len = 0;
    page_lines = 0;
    page_scroll = 0;
    link_count = 0;
    active_link = 0;
    block_box_count = 0;
    page_background_color = null;
    page_title_len = 0;
}

pub fn hasPage() bool {
    return page_len != 0;
}

fn appendPage(ch: u8) void {
    if (page_len >= page.len) return;
    page[page_len] = ch;
    page_link_ids[page_len] = active_link;
    page_colors[page_len] = rendering_style.color orelse 0;
    page_backgrounds[page_len] = rendering_style.background orelse 0;
    page_line_heights[page_len] = rendering_style.line_height;
    page_font_scales[page_len] = rendering_style.font_scale;
    page_align_starts[page_len] = @intCast(@min(flow_align_start, std.math.maxInt(u16)));
    page_align_widths[page_len] = @intCast(@min(flow_align_width, std.math.maxInt(u16)));
    page_style_flags[page_len] = (if (rendering_style.color != null) @as(u8, 1) else 0) |
        (if (rendering_style.background != null) @as(u8, 2) else 0) |
        (if (rendering_style.bold) @as(u8, 4) else 0) |
        (if (rendering_style.underline) @as(u8, 8) else 0) |
        (if (rendering_style.text_align == .center) @as(u8, 16) else if (rendering_style.text_align == .right) @as(u8, 32) else 0) |
        (if (rendering_style.white_space_nowrap) @as(u8, 64) else 0) |
        (if (rendering_style.italic) @as(u8, 128) else 0);
    page_decorations[page_len] = (if (rendering_style.line_through) @as(u8, 1) else 0) | (if (rendering_style.overline) @as(u8, 2) else 0);
    page_letter_spacing[page_len] = rendering_style.letter_spacing;
    page_word_spacing[page_len] = rendering_style.word_spacing;
    page_len += 1;
    if (ch == '\n') page_lines += 1;
}

fn newline() void {
    if (page_len != 0 and page[page_len - 1] != '\n') appendPage('\n');
}

fn appendVisible(ch: u8, columns: usize, previous_space: *bool) void {
    if (ch == '\r' or ch == '\n' or ch == '\t' or ch == ' ') {
        if (page_len != 0 and page[page_len - 1] != '\n' and !previous_space.*) appendPage(' ');
        previous_space.* = true;
        return;
    }
    const effective_columns = @max(1, columns / @max(1, flow_font_scale));
    if (!flow_style.white_space_nowrap and page_len != 0 and page[page_len - 1] != '\n') {
        var line_start = page_len;
        while (line_start > 0 and page[line_start - 1] != '\n') : (line_start -= 1) {}
        const line_length = page_len - line_start;
        const indent = @min(flow_indent, effective_columns -| 1);
        const content_length = line_length -| indent;
        const content_columns = effective_columns -| indent -| @min(flow_right_inset, effective_columns -| indent -| 1);
        if (content_length >= @max(1, content_columns)) newline();
    }
    const indent = @min(flow_indent, effective_columns -| 1);
    if (page_len == 0 or page[page_len - 1] == '\n') {
        for (0..indent) |_| appendPage(' ');
    }
    var displayed = ch;
    if (ch < 0x80) switch (flow_style.text_transform) {
        .uppercase => displayed = std.ascii.toUpper(ch),
        .lowercase => displayed = std.ascii.toLower(ch),
        .capitalize => if (previous_space.*) {
            displayed = std.ascii.toUpper(ch);
        },
        .none => {},
    };
    appendPage(if (displayed < 0x80) displayed else '?');
    previous_space.* = false;
}

pub fn htmlEntity(input: []const u8, start: usize) ?struct { ch: u8, consumed: usize } {
    const end_rel = std.mem.indexOfScalar(u8, input[start..@min(input.len, start + 12)], ';') orelse return null;
    const entity = input[start .. start + end_rel + 1];
    const decoded: u8 = if (equalIgnoreCase(entity, "&amp;")) '&' else if (equalIgnoreCase(entity, "&lt;")) '<' else if (equalIgnoreCase(entity, "&gt;")) '>' else if (equalIgnoreCase(entity, "&quot;")) '"' else if (equalIgnoreCase(entity, "&#39;") or equalIgnoreCase(entity, "&apos;")) '\'' else if (equalIgnoreCase(entity, "&nbsp;")) ' ' else return null;
    return .{ .ch = decoded, .consumed = entity.len };
}

fn htmlPixelSize(tag: []const u8, attribute_name: []const u8) ?u16 {
    const raw = html.attribute(tag, attribute_name) orelse return null;
    const value = std.mem.trim(u8, raw, " \t\r\n");
    if (value.len == 0 or value.len > 5) return null;
    const parsed = std.fmt.parseInt(u16, value, 10) catch return null;
    return if (parsed == 0) null else @min(parsed, 4096);
}

fn htmlNumberMilli(tag: []const u8, attribute_name: []const u8) ?u64 {
    const raw = html.attribute(tag, attribute_name) orelse return null;
    var value: u64 = 0;
    var fraction: u64 = 0;
    var fraction_digits: u8 = 0;
    var after_dot = false;
    var saw_digit = false;
    for (raw) |ch| {
        if (ch == '.' and !after_dot) {
            after_dot = true;
            continue;
        }
        if (ch < '0' or ch > '9') return null;
        saw_digit = true;
        if (!after_dot) {
            value = @min(1_000_000, value * 10 + (ch - '0'));
        } else if (fraction_digits < 3) {
            fraction = fraction * 10 + (ch - '0');
            fraction_digits += 1;
        }
    }
    if (!saw_digit) return null;
    while (fraction_digits < 3) : (fraction_digits += 1) fraction *= 10;
    return @min(1_000_000_000, value * 1000 + fraction);
}

fn renderMeterTag(tag: []const u8, columns: usize, previous_space: *bool) void {
    const max_value = htmlNumberMilli(tag, "max") orelse 100_000;
    const value = htmlNumberMilli(tag, "value") orelse 0;
    const percent: usize = if (max_value == 0) 0 else @intCast(@min(100, value * 100 / max_value));
    appendVisible('[', columns, previous_space);
    for (0..10) |segment| appendVisible(if (segment < (percent + 5) / 10) '#' else '-', columns, previous_space);
    appendVisible(']', columns, previous_space);
}

fn renderInput(tag: []const u8, columns: usize, previous_space: *bool) void {
    const kind = html.attribute(tag, "type") orelse "text";
    if (equalIgnoreCase(kind, "hidden")) return;
    if (equalIgnoreCase(kind, "checkbox")) {
        appendVisible('[', columns, previous_space);
        appendVisible(if (hasHtmlAttribute(tag, "checked")) 'x' else ' ', columns, previous_space);
        appendVisible(']', columns, previous_space);
        return;
    }
    if (equalIgnoreCase(kind, "radio")) {
        appendVisible('(', columns, previous_space);
        appendVisible(if (hasHtmlAttribute(tag, "checked")) '*' else ' ', columns, previous_space);
        appendVisible(')', columns, previous_space);
        return;
    }
    if (equalIgnoreCase(kind, "submit") or equalIgnoreCase(kind, "reset") or equalIgnoreCase(kind, "button")) {
        const label = html.attribute(tag, "value") orelse if (equalIgnoreCase(kind, "submit")) "Submit" else if (equalIgnoreCase(kind, "reset")) "Reset" else "Button";
        appendVisible('[', columns, previous_space);
        for (label[0..@min(label.len, 40)]) |ch| appendVisible(ch, columns, previous_space);
        appendVisible(']', columns, previous_space);
        return;
    }
    if (equalIgnoreCase(kind, "file")) {
        for ("[Choose file]") |ch| appendVisible(ch, columns, previous_space);
        return;
    }
    var size: usize = 12;
    if (html.attribute(tag, "size")) |raw_size| size = @max(1, @min(32, std.fmt.parseInt(usize, raw_size, 10) catch 12));
    appendVisible('[', columns, previous_space);
    const value = html.attribute(tag, "value") orelse html.attribute(tag, "placeholder") orelse "";
    const visible_len = @min(size, 40);
    if (equalIgnoreCase(kind, "password")) {
        for (0..@min(value.len, visible_len)) |_| appendVisible('*', columns, previous_space);
    } else {
        for (value[0..@min(value.len, visible_len)]) |ch| appendVisible(ch, columns, previous_space);
    }
    if (value.len < visible_len) for (0..visible_len - value.len) |_| appendVisible('_', columns, previous_space);
    appendVisible(']', columns, previous_space);
}

fn imageSource(tag: []const u8) ?[]const u8 {
    if (html.attribute(tag, "src")) |source| return source;
    const srcset = html.attribute(tag, "srcset") orelse return null;
    const candidate_end = std.mem.indexOfScalar(u8, srcset, ',') orelse srcset.len;
    const candidate = std.mem.trim(u8, srcset[0..candidate_end], " \t\r\n");
    const url_end = std.mem.indexOfAny(u8, candidate, " \t\r\n") orelse candidate.len;
    return if (url_end == 0) null else candidate[0..url_end];
}

fn imageLayoutSize(tag: []const u8, style: css.Computed, image: media.Picture, max_width: usize, max_height: usize) struct { w: u16, h: u16 } {
    const requested_w: ?u16 = if (style.width_percent) |percent| @intCast(@max(1, max_width * percent / 100)) else style.width orelse htmlPixelSize(tag, "width");
    const requested_h: ?u16 = if (style.height_percent) |percent| @intCast(@max(1, max_height * percent / 100)) else style.height orelse htmlPixelSize(tag, "height");
    var width: usize = image.width;
    var height: usize = image.height;
    if (requested_w) |w| width = w else if (requested_h) |h| width = (@as(u64, h) * image.width / image.height);
    if (requested_h) |h| height = h else if (requested_w) |w| height = (@as(u64, w) * image.height / image.width);
    if (requested_w == null and requested_h == null) {
        const scale = @min(1.0, @min(@as(f64, @floatFromInt(max_width)) / @as(f64, @floatFromInt(width)), @as(f64, @floatFromInt(max_height)) / @as(f64, @floatFromInt(height))));
        width = @max(1, @as(usize, @intFromFloat(@as(f64, @floatFromInt(width)) * scale)));
        height = @max(1, @as(usize, @intFromFloat(@as(f64, @floatFromInt(height)) * scale)));
    } else if (requested_w == null or requested_h == null) {
        const scale = @min(1.0, @min(@as(f64, @floatFromInt(max_width)) / @as(f64, @floatFromInt(width)), @as(f64, @floatFromInt(max_height)) / @as(f64, @floatFromInt(height))));
        width = @max(1, @as(usize, @intFromFloat(@as(f64, @floatFromInt(width)) * scale)));
        height = @max(1, @as(usize, @intFromFloat(@as(f64, @floatFromInt(height)) * scale)));
    }
    return .{ .w = @intCast(@min(max_width, width)), .h = @intCast(@min(max_height, height)) };
}

fn hasHtmlAttribute(tag: []const u8, name: []const u8) bool {
    return html.attribute(tag, name) != null;
}

pub fn renderPlain(input: []const u8, columns: usize) void {
    clear();
    rendering_style = .{};
    flow_style = .{};
    flow_indent = 0;
    flow_right_inset = 0;
    flow_font_scale = 1;
    flow_align_start = 0;
    flow_align_width = columns;
    page_lines = 1;
    var previous_space = true;
    for (input) |ch| {
        if (ch == '\n') {
            newline();
            previous_space = true;
        } else if (ch != '\r') {
            appendVisible(ch, columns, &previous_space);
        }
        if (page_len + 1 >= page.len) break;
    }
    while (page_len != 0 and (page[page_len - 1] == '\n' or page[page_len - 1] == ' ')) page_len -= 1;
    page_lines = 1;
    for (page[0..page_len]) |ch| if (ch == '\n') {
        page_lines += 1;
    };
}

fn isBlockElement(name: []const u8) bool {
    return equalIgnoreCase(name, "address") or equalIgnoreCase(name, "article") or equalIgnoreCase(name, "aside") or
        equalIgnoreCase(name, "blockquote") or equalIgnoreCase(name, "body") or equalIgnoreCase(name, "caption") or
        equalIgnoreCase(name, "dd") or equalIgnoreCase(name, "details") or equalIgnoreCase(name, "dialog") or
        equalIgnoreCase(name, "div") or equalIgnoreCase(name, "dl") or equalIgnoreCase(name, "dt") or
        equalIgnoreCase(name, "fieldset") or equalIgnoreCase(name, "figcaption") or equalIgnoreCase(name, "figure") or
        equalIgnoreCase(name, "footer") or equalIgnoreCase(name, "form") or equalIgnoreCase(name, "h1") or
        equalIgnoreCase(name, "h2") or equalIgnoreCase(name, "h3") or equalIgnoreCase(name, "h4") or
        equalIgnoreCase(name, "h5") or equalIgnoreCase(name, "h6") or equalIgnoreCase(name, "header") or
        equalIgnoreCase(name, "hr") or equalIgnoreCase(name, "li") or equalIgnoreCase(name, "main") or
        equalIgnoreCase(name, "nav") or equalIgnoreCase(name, "ol") or equalIgnoreCase(name, "p") or
        equalIgnoreCase(name, "pre") or equalIgnoreCase(name, "section") or equalIgnoreCase(name, "summary") or
        equalIgnoreCase(name, "html") or equalIgnoreCase(name, "table") or equalIgnoreCase(name, "tbody") or equalIgnoreCase(name, "thead") or
        equalIgnoreCase(name, "tfoot") or equalIgnoreCase(name, "tr") or equalIgnoreCase(name, "ul") or equalIgnoreCase(name, "center");
}

fn isBlock(name: []const u8, style: css.Computed) bool {
    return style.block orelse isBlockElement(name);
}

fn verticalGap(pixel_value: u16) void {
    const rows = @min(128, (@as(usize, pixel_value) + 9) / 10);
    if (rows == 0) return;
    newline();
    for (0..rows) |_| appendPage('\n');
}

fn updateFlow(style: css.Computed, columns: usize) void {
    flow_style = style;
    flow_font_scale = @max(1, style.font_scale);
    const cell_width = 6 * flow_font_scale;
    const available = @max(1, columns / flow_font_scale);
    const left = (@as(usize, style.margin.left) + style.padding.left + cell_width - 1) / cell_width;
    const right = (@as(usize, style.margin.right) + style.padding.right + cell_width - 1) / cell_width;
    const max_content = if (style.max_width) |width| @max(1, @as(usize, width) / cell_width) else available;
    const min_content = @as(usize, style.min_width) / cell_width;
    const set_width = @min(available, @max(min_content, if (style.width_percent) |percent| @max(1, available * percent / 100) else if (style.width) |width| @max(1, @as(usize, width) / cell_width) else max_content));
    const total = @min(available, set_width + left + right);
    const centered = if (style.margin_auto and style.max_width != null and total < available) (available - total) / 2 else 0;
    const text_indent = (@as(usize, style.text_indent) + cell_width - 1) / cell_width;
    flow_indent = @min(available -| 1, centered + left + text_indent);
    flow_right_inset = @max(centered + right, available -| centered -| left -| set_width);
    flow_align_start = flow_indent;
    flow_align_width = @max(1, @min(set_width, available -| left -| right));
}

fn isVoidElement(name: []const u8) bool {
    return equalIgnoreCase(name, "area") or equalIgnoreCase(name, "base") or equalIgnoreCase(name, "br") or
        equalIgnoreCase(name, "col") or equalIgnoreCase(name, "embed") or equalIgnoreCase(name, "hr") or
        equalIgnoreCase(name, "img") or equalIgnoreCase(name, "input") or equalIgnoreCase(name, "link") or
        equalIgnoreCase(name, "meta") or equalIgnoreCase(name, "param") or equalIgnoreCase(name, "source") or
        equalIgnoreCase(name, "track") or equalIgnoreCase(name, "wbr");
}

pub fn renderHtml(input: []const u8, columns: usize, viewport_height: u16, resources: Resources) void {
    clear();
    rendering_style = .{};
    flow_style = .{};
    flow_indent = 0;
    flow_right_inset = 0;
    flow_font_scale = 1;
    flow_align_start = 0;
    flow_align_width = columns;
    page_lines = 1;
    var stylesheet = css.Sheet{};
    collectMetadata(input, &stylesheet, viewport_height, resources);
    const StyleFrame = struct {
        name: []const u8 = "",
        parent_link: u8 = 0,
        parent: css.Computed = .{},
        parent_indent: usize = 0,
        parent_right_inset: usize = 0,
        parent_font_scale: usize = 1,
        parent_align_start: usize = 0,
        parent_align_width: usize = 0,
        box_index: ?usize = null,
    };
    var style_stack: [32]StyleFrame = @splat(.{});
    var style_stack_len: usize = 0;
    var active_style: css.Computed = .{};
    var tokens: html.Tokenizer = .{ .input = input };
    var list_item_counter: u16 = 0;
    var preformatted = false;
    var previous_space = true;
    while (page_len + 1 < page.len) {
        const token = tokens.next() orelse break;
        if (token == .tag) {
            const element = token.tag;
            const tag = element.attributes;
            const name = element.name;
            const closing = element.closing;
            const void_element = isVoidElement(name) or element.self_closing;
            if (!closing and equalIgnoreCase(name, "svg")) {
                if (!void_element) tokens.skipElement(name);
                if (svg.rasterize(input[element.start..tokens.pos])) |picture| {
                    addImage(tag, .{}, picture, columns);
                }
                previous_space = true;
                continue;
            }
            if (!closing and equalIgnoreCase(name, "head")) continue;
            if (!closing and (equalIgnoreCase(name, "script") or equalIgnoreCase(name, "style") or equalIgnoreCase(name, "title"))) {
                _ = tokens.rawText(name);
                continue;
            }
            if (!closing and equalIgnoreCase(name, "textarea")) {
                const content = tokens.rawText(name);
                appendVisible('[', columns, &previous_space);
                appendText(content, columns, &previous_space, false);
                appendVisible(']', columns, &previous_space);
                continue;
            }
            if (!closing and !void_element and style_stack_len == style_stack.len) {
                tokens.skipElement(name);
                continue;
            }
            if (closing) {
                var match = style_stack_len;
                while (match > 0 and !equalIgnoreCase(style_stack[match - 1].name, name)) match -= 1;
                if (match == 0) continue;
                const closing_style = active_style;
                if (equalIgnoreCase(name, "q")) appendVisible('"', columns, &previous_space);
                if (equalIgnoreCase(name, "rt")) appendVisible(')', columns, &previous_space);
                if (equalIgnoreCase(name, "button") or equalIgnoreCase(name, "select") or equalIgnoreCase(name, "textarea")) appendVisible(']', columns, &previous_space);
                if (equalIgnoreCase(name, "pre")) preformatted = false;
                if (isBlock(name, closing_style)) {
                    rendering_style = closing_style;
                    newline();
                    verticalGap(closing_style.padding.bottom);
                    verticalGap(closing_style.margin.bottom);
                }
                var frame_index = style_stack_len;
                while (frame_index >= match) {
                    frame_index -= 1;
                    active_style = style_stack[frame_index].parent;
                    flow_indent = style_stack[frame_index].parent_indent;
                    flow_right_inset = style_stack[frame_index].parent_right_inset;
                    flow_font_scale = style_stack[frame_index].parent_font_scale;
                    flow_align_start = style_stack[frame_index].parent_align_start;
                    flow_align_width = style_stack[frame_index].parent_align_width;
                    style_stack_len = frame_index;
                    if (style_stack[frame_index].box_index) |index| block_boxes[index].end_line = page_lines;
                    active_link = style_stack[frame_index].parent_link;
                }
                rendering_style = active_style;
                flow_style = active_style;
                if (isBlockElement(name)) newline();
                if (isBlock(name, closing_style)) previous_space = true;
                continue;
            }
            const parent_style = active_style;
            var element_style = stylesheet.compute(
                parent_style,
                name,
                html.attribute(tag, "id") orelse "",
                html.attribute(tag, "class") orelse "",
                html.attribute(tag, "style") orelse "",
                viewport_height,
            );
            if (element_style.hidden) {
                if (!void_element) {
                    if (html.isRawText(name)) {
                        _ = tokens.rawText(name);
                    } else tokens.skipElement(name);
                }
                continue;
            }
            if (equalIgnoreCase(name, "iframe") or equalIgnoreCase(name, "video") or equalIgnoreCase(name, "audio")) {
                const fallback = if (equalIgnoreCase(name, "iframe")) "[Embedded frame]" else if (equalIgnoreCase(name, "video")) "[Video player]" else "[Audio player]";
                for (fallback) |ch| appendVisible(ch, columns, &previous_space);
                if (!void_element) {
                    if (equalIgnoreCase(name, "iframe")) {
                        _ = tokens.rawText(name);
                    } else tokens.skipElement(name);
                }
                continue;
            }
            if (equalIgnoreCase(name, "progress") or equalIgnoreCase(name, "meter")) {
                renderMeterTag(tag, columns, &previous_space);
                if (!void_element) tokens.skipElement(name);
                continue;
            }
            const block_layout = isBlock(name, element_style);
            if (equalIgnoreCase(name, "html")) page_background_color = element_style.background;
            if (equalIgnoreCase(name, "body")) page_background_color = element_style.background orelse page_background_color;
            if (block_layout) element_style.container_background = element_style.background orelse parent_style.container_background;
            if (equalIgnoreCase(name, "body")) element_style.container_background = element_style.background;
            if (equalIgnoreCase(name, "b") or equalIgnoreCase(name, "strong") or (name.len == 2 and name[0] == 'h' and name[1] >= '1' and name[1] <= '6')) element_style.bold = true;
            if (equalIgnoreCase(name, "em") or equalIgnoreCase(name, "i")) element_style.italic = true;
            if (equalIgnoreCase(name, "del") or equalIgnoreCase(name, "s")) element_style.line_through = true;
            if (equalIgnoreCase(name, "mark")) {
                element_style.background = 0xffeb3b;
                if (element_style.color == parent_style.color) element_style.color = 0x202020;
            }
            if (equalIgnoreCase(name, "small") and element_style.font_scale > 1) element_style.font_scale -= 1;
            if (equalIgnoreCase(name, "code")) {
                element_style.background = 0x202938;
                if (element_style.color == parent_style.color) element_style.color = 0xb7e4c7;
            }
            if (equalIgnoreCase(name, "kbd")) {
                element_style.background = 0x303846;
                element_style.bold = true;
            }
            if (equalIgnoreCase(name, "samp")) {
                element_style.background = 0x202938;
                if (element_style.color == parent_style.color) element_style.color = 0xb7e4c7;
            }
            if (equalIgnoreCase(name, "output")) element_style.background = 0xe8eef8;
            if (equalIgnoreCase(name, "label") or equalIgnoreCase(name, "summary")) element_style.bold = true;
            if (equalIgnoreCase(name, "cite") or equalIgnoreCase(name, "dfn") or equalIgnoreCase(name, "var")) element_style.italic = true;
            if (equalIgnoreCase(name, "time") and element_style.color == parent_style.color) element_style.color = 0x2878b8;
            if (equalIgnoreCase(name, "center")) element_style.text_align = .center;
            if (equalIgnoreCase(name, "button")) {
                element_style.background = 0xdce7f5;
                element_style.bold = true;
            }
            if (equalIgnoreCase(name, "form")) {
                if (element_style.background == null) element_style.background = 0xf8fafc;
                element_style.padding.top = @max(element_style.padding.top, 4);
                element_style.padding.bottom = @max(element_style.padding.bottom, 4);
            }
            if (equalIgnoreCase(name, "textarea") or equalIgnoreCase(name, "select")) element_style.background = 0xf1f4f8;
            if (equalIgnoreCase(name, "fieldset")) {
                if (element_style.border_width == 0) element_style.border_width = 1;
                if (element_style.border_color == null) element_style.border_color = 0x8492a6;
            }
            if (equalIgnoreCase(name, "blockquote")) element_style.margin.left = @max(element_style.margin.left, 24);
            if (equalIgnoreCase(name, "dd")) element_style.margin.left = @max(element_style.margin.left, 16);
            if (equalIgnoreCase(name, "dt") or equalIgnoreCase(name, "legend") or equalIgnoreCase(name, "optgroup")) element_style.bold = true;
            if (equalIgnoreCase(name, "address")) element_style.italic = true;
            if (equalIgnoreCase(name, "pre")) element_style.white_space_nowrap = true;
            if (equalIgnoreCase(name, "abbr")) element_style.underline = true;
            if (equalIgnoreCase(name, "ol")) list_item_counter = 0;
            if (name.len == 2 and name[0] == 'h' and name[1] >= '1' and name[1] <= '6') {
                const heading_scale: u8 = switch (name[1]) {
                    '1' => 4,
                    '2' => 3,
                    '3' => 2,
                    '4' => 2,
                    else => 1,
                };
                if (element_style.font_scale == parent_style.font_scale) element_style.font_scale = heading_scale;
                element_style.line_height = @max(element_style.line_height, heading_scale * 10);
            }
            if (equalIgnoreCase(name, "u")) element_style.underline = true;
            if (block_layout) {
                newline();
                verticalGap(element_style.margin.top);
                if (block_box_count < block_boxes.len and (element_style.background != null or element_style.background_image != null or element_style.border_width != 0 or element_style.border_top_width != 0 or element_style.min_height != 0 or element_style.height != null)) {
                    block_boxes[block_box_count] = .{
                        .start_line = page_lines,
                        .end_line = page_lines,
                        .style = element_style,
                        .image_id = if (element_style.background_image) |image| if (resources.image(image.value[0..image.len])) |picture| storeInlineImage(picture) else null else null,
                    };
                }
                verticalGap(element_style.padding.top);
            }
            const pushed_style = !void_element and style_stack_len < style_stack.len;
            if (pushed_style) {
                const box_index: ?usize = if (block_layout and block_box_count < block_boxes.len and (element_style.background != null or element_style.background_image != null or element_style.border_width != 0 or element_style.border_top_width != 0 or element_style.min_height != 0 or element_style.height != null)) block_box_count else null;
                style_stack[style_stack_len] = .{ .parent = active_style, .name = name, .parent_link = active_link, .parent_indent = flow_indent, .parent_right_inset = flow_right_inset, .parent_font_scale = flow_font_scale, .parent_align_start = flow_align_start, .parent_align_width = flow_align_width, .box_index = box_index };
                style_stack_len += 1;
                if (box_index != null) block_box_count += 1;
            }
            active_style = if (pushed_style) element_style else parent_style;
            if (block_layout) updateFlow(active_style, columns) else flow_style = active_style;
            flow_font_scale = @max(1, active_style.font_scale);
            rendering_style = element_style;
            if (equalIgnoreCase(name, "q")) appendVisible('"', columns, &previous_space);
            if (equalIgnoreCase(name, "button") or equalIgnoreCase(name, "select") or equalIgnoreCase(name, "textarea")) appendVisible('[', columns, &previous_space);
            if (equalIgnoreCase(name, "option")) appendVisible(if (hasHtmlAttribute(tag, "selected")) '*' else ' ', columns, &previous_space);
            if (equalIgnoreCase(name, "summary")) {
                appendVisible('>', columns, &previous_space);
                appendVisible(' ', columns, &previous_space);
            }
            if (equalIgnoreCase(name, "rt")) appendVisible('(', columns, &previous_space);
            if (equalIgnoreCase(name, "pre")) {
                preformatted = true;
                newline();
            }
            if (equalIgnoreCase(name, "br")) {
                newline();
                previous_space = true;
            } else if (equalIgnoreCase(name, "hr")) {
                var dash: usize = 0;
                while (dash < columns and page_len + 1 < page.len) : (dash += 1) appendPage('-');
                newline();
                previous_space = true;
            } else if (equalIgnoreCase(name, "li")) {
                if (element_style.list_style != .none) {
                    if (element_style.list_style == .decimal) {
                        list_item_counter +|= 1;
                        var digits: [8]u8 = undefined;
                        const number = std.fmt.bufPrint(&digits, "{d}. ", .{list_item_counter}) catch "*. ";
                        for (number) |ch| appendVisible(ch, columns, &previous_space);
                    } else {
                        const marker: u8 = switch (element_style.list_style) {
                            .circle => 'o',
                            .square => '#',
                            .disc => '*',
                            .dash, .none, .decimal => '-',
                        };
                        appendVisible(marker, columns, &previous_space);
                        appendVisible(' ', columns, &previous_space);
                    }
                }
            } else if (equalIgnoreCase(name, "td") or equalIgnoreCase(name, "th")) {
                if (page_len != 0 and page[page_len - 1] != '\n') appendVisible('|', columns, &previous_space);
                appendVisible(' ', columns, &previous_space);
            } else if (block_layout) {
                newline();
                previous_space = true;
            }
            if (pushed_style and equalIgnoreCase(name, "a") and link_count < links.len) {
                if (html.attribute(tag, "href")) |href| {
                    var link: Link = .{};
                    if (resources.resolve(href, &link.url)) |length| {
                        link.url_len = length;
                        links[link_count] = link;
                        link_count += 1;
                        active_link = @intCast(link_count);
                    }
                }
            }
            if (equalIgnoreCase(name, "img")) {
                const picture = if (imageSource(tag)) |src| resources.image(src) else null;
                if (picture) |loaded| {
                    addImage(tag, element_style, loaded, columns);
                } else {
                    const alt = html.attribute(tag, "alt") orelse "[image unavailable]";
                    appendText(alt, columns, &previous_space, false);
                }
            }
            if (equalIgnoreCase(name, "input")) renderInput(tag, columns, &previous_space);
            if (equalIgnoreCase(name, "canvas")) {
                const label = "[Canvas]";
                for (label) |ch| appendVisible(ch, columns, &previous_space);
            }
            rendering_style = active_style;
            continue;
        }
        appendText(token.text, columns, &previous_space, preformatted);
    }
    for (style_stack[0..style_stack_len]) |frame| {
        if (frame.box_index) |index| block_boxes[index].end_line = page_lines;
    }
    while (page_len != 0 and (page[page_len - 1] == '\n' or page[page_len - 1] == ' ')) page_len -= 1;
    page_lines = 1;
    for (page[0..page_len]) |ch| if (ch == '\n') {
        page_lines += 1;
    };
}

fn cssColor(value: u24) u32 {
    return canvas.color(@truncate(value >> 16), @truncate(value >> 8), @truncate(value));
}

fn drawRoundedBackground(x: u64, y: u64, width: u64, height: u64, radius: u8, color: u32) void {
    const r = @min(@as(u64, radius), @min(width / 2, height / 2));
    if (r == 0) {
        canvas.fillRect(x, y, width, height, color);
        return;
    }
    canvas.fillRect(x +| r, y, width -| 2 * r, height, color);
    var row: u64 = 0;
    while (row < r) : (row += 1) {
        const dy = @as(f64, @floatFromInt(r - row));
        const rf = @as(f64, @floatFromInt(r));
        const inset: u64 = @intFromFloat(@max(0, rf - @sqrt(rf * rf - dy * dy)));
        const row_width = width -| 2 * inset;
        canvas.fillRect(x +| inset, y +| row, row_width, 1, color);
        canvas.fillRect(x +| inset, y +| height -| row -| 1, row_width, 1, color);
    }
}

fn drawBorderLine(x: u64, y: u64, width: u64, thickness: u64, ink: u32, style: css.BorderStyle, horizontal: bool) void {
    if (width == 0 or thickness == 0) return;
    if (style == .solid) {
        canvas.fillRect(x, y, width, thickness, ink);
        return;
    }
    if (style == .double) {
        const band = @max(1, thickness / 3);
        canvas.fillRect(x, y, width, band, ink);
        if (thickness > band * 2) canvas.fillRect(x, y +| thickness -| band, width, band, ink);
        return;
    }
    const dash: u64 = if (style == .dotted) @max(1, thickness) else @max(3, thickness * 3);
    var cursor: u64 = 0;
    while (cursor < width) : (cursor += dash * 2) {
        const part = @min(dash, width - cursor);
        if (horizontal) canvas.fillRect(x +| cursor, y, part, thickness, ink) else canvas.fillRect(x, y +| cursor, thickness, part, ink);
    }
}

fn linePixelY(wanted: usize) u64 {
    var rows: Rows = .{};
    var y: u64 = 0;
    for (0..wanted) |_| {
        const row = rows.next() orelse break;
        y += row.height;
    }
    return y;
}

fn drawBlockBoxes(content_x: u64, content_y: u64, content_w: u64, content_h: u64, scroll_line: usize) void {
    const scroll_y = linePixelY(scroll_line);
    for (block_boxes[0..block_box_count]) |box| {
        if (box.end_line < scroll_line) continue;
        const style = box.style;
        const margin = style.margin;
        const padding = style.padding;
        const available_w = content_w -| margin.left -| margin.right;
        const css_width: u64 = if (style.width_percent) |percent| available_w * percent / 100 else if (style.width) |width| @as(u64, width) + padding.left + padding.right else available_w;
        const box_w = @min(@min(available_w, css_width), style.max_width orelse available_w);
        const box_x = content_x +| margin.left +| (if (style.margin_auto and box_w < available_w) (available_w - box_w) / 2 else 0);
        const raw_top = linePixelY(box.start_line);
        const raw_bottom = linePixelY(@max(box.start_line + 1, box.end_line));
        const top = if (raw_top >= scroll_y) content_y +| (raw_top - scroll_y) else content_y;
        const above_scroll = if (raw_top < scroll_y) scroll_y - raw_top else 0;
        const declared_h: u64 = if (style.height_percent) |percent| content_h * percent / 100 else style.height orelse 0;
        const natural_h = @max(declared_h + padding.top + padding.bottom, raw_bottom -| raw_top);
        const constrained_h = @max(natural_h, style.min_height);
        const computed_h = if (style.max_height != 0) @max(raw_bottom -| raw_top, @min(constrained_h, style.max_height)) else constrained_h;
        const box_h = computed_h -| above_scroll;
        const visible_h = @min(box_h, content_y +| content_h -| top);
        if (visible_h == 0 or top >= content_y +| content_h) continue;
        if (style.background) |background| drawRoundedBackground(box_x, top, box_w, visible_h, style.border_radius, cssColor(background));
        if (box.image_id) |image_id| if (image_id < inline_images.len) if (inline_images[image_id]) |picture| {
            if (style.object_fit == .contain or style.background_position == .center) {
                media.drawFit(picture, box_x, top, box_w, visible_h);
            } else if (style.object_fit == .cover or style.background_position == .right) {
                media.drawCover(picture, box_x, top, box_w, visible_h, style.background_position == .right);
            } else media.drawScaled(picture, box_x, top, box_w, visible_h);
        };
        if (style.border_width != 0 or style.border_top_width != 0) {
            const border = @as(u64, style.border_width);
            const top_border = @as(u64, if (style.border_top_width != 0) style.border_top_width else style.border_width);
            const color = cssColor(style.border_color orelse style.color orelse 0x808080);
            drawBorderLine(box_x, top, box_w, @min(top_border, visible_h), color, style.border_style, true);
            if (border != 0) {
                drawBorderLine(box_x, top +| visible_h -| border, box_w, @min(border, visible_h), color, style.border_style, true);
                drawBorderLine(box_x, top, visible_h, @min(border, box_w), color, style.border_style, false);
                drawBorderLine(box_x +| box_w -| border, top, visible_h, @min(border, box_w), color, style.border_style, false);
            }
        }
    }
}

fn drawStyledLine(x: u64, y: u64, start: usize, text: []const u8, normal_ink: u32, link_ink: u32, width: u64, row_height: u8) void {
    if (text.len == 0) return;
    var glyphs = GlyphPositions.init(x, start, text, width);
    for (text, 0..) |ch, column| {
        const index = start + column;
        const px = glyphs.next(index, column, ch) orelse continue;
        const flags = page_style_flags[index];
        const scale = @max(1, page_font_scales[index]);
        if (ch == 0xff) {
            const image_index: usize = page_media_ids[index];
            if (image_index < inline_images.len) if (inline_images[image_index]) |picture| {
                const image_width = @min(@as(u64, page_media_widths[index]), x + width -| px);
                const image_height = page_media_heights[index];
                if (page_media_fit_modes[index] == @backingInt(css.ObjectFit.contain)) {
                    media.drawFit(picture, px, y, image_width, image_height);
                } else if (page_media_fit_modes[index] == @backingInt(css.ObjectFit.cover)) {
                    media.drawCover(picture, px, y, image_width, image_height, false);
                } else media.drawScaled(picture, px, y, image_width, image_height);
            };
            continue;
        }
        if (px + 6 * @as(u64, scale) > x + width) continue;
        if ((flags & 2) != 0) canvas.fillRect(px, y, 6 * scale, row_height, cssColor(page_backgrounds[index]));
        const ink = if ((flags & 1) != 0) cssColor(page_colors[index]) else if (page_link_ids[index] != 0) link_ink else normal_ink;
        const character = [_]u8{ch};
        if ((flags & 128) != 0) font.drawTextItalic(px, y, &character, scale, ink) else font.drawText(px, y, &character, scale, ink);
        if ((flags & 4) != 0) font.drawText(px + scale, y, &character, scale, ink);
        if ((flags & 8) != 0 or page_link_ids[index] != 0) canvas.fillRect(px, y + 7 * scale, 5 * scale, scale, ink);
        if ((page_decorations[index] & 1) != 0) canvas.fillRect(px, y + 4 * scale, 5 * scale, scale, ink);
        if ((page_decorations[index] & 2) != 0) canvas.fillRect(px, y, 5 * scale, scale, ink);
    }
}

fn addImage(tag: []const u8, style: css.Computed, picture: media.Picture, columns: usize) void {
    const index = storeInlineImage(picture) orelse return;
    const dimensions = imageLayoutSize(tag, style, picture, @max(1, columns * 6), 220);
    newline();
    const marker = page_len;
    if (marker == page.len) return;
    appendPage(0xff);
    page_media_ids[marker] = index;
    page_media_widths[marker] = dimensions.w;
    page_media_heights[marker] = dimensions.h;
    page_media_fit_modes[marker] = @backingInt(style.object_fit);
    page_line_heights[marker] = @intCast(@max(10, dimensions.h));
    newline();
}

fn appendText(text: []const u8, columns: usize, previous_space: *bool, preformatted: bool) void {
    var i: usize = 0;
    while (i < text.len and page_len < page.len) {
        const ch = text[i];
        if (ch == '&') {
            if (htmlEntity(text, i)) |entity| {
                appendVisible(entity.ch, columns, previous_space);
                i += entity.consumed;
                continue;
            }
        }
        if (preformatted and ch == '\n') {
            appendPage('\n');
            previous_space.* = true;
        } else if (preformatted and ch == '\t') {
            for (0..4) |_| appendPage(' ');
        } else if (preformatted and ch == ' ') {
            appendPage(' ');
        } else appendVisible(ch, columns, previous_space);
        i += 1;
    }
}

fn collectMetadata(input: []const u8, sheet: *css.Sheet, height: u16, resources: Resources) void {
    var tokens: html.Tokenizer = .{ .input = input };
    var external_sheets: usize = 0;
    while (tokens.next()) |token| {
        if (token != .tag or token.tag.closing) continue;
        const tag = token.tag;
        if (html.isRawText(tag.name)) {
            const content = tokens.rawText(tag.name);
            if (equalIgnoreCase(tag.name, "style")) {
                sheet.parse(content, height);
            } else if (equalIgnoreCase(tag.name, "title") and page_title_len == 0) {
                const title = std.mem.trim(u8, content, " \t\r\n");
                page_title_len = @min(title.len, page_title.len);
                for (title[0..page_title_len], 0..) |ch, index| page_title[index] = if (ch < 0x80) ch else '?';
            }
        } else if (equalIgnoreCase(tag.name, "link") and external_sheets < 4) {
            const rel = html.attribute(tag.attributes, "rel") orelse continue;
            if (!equalIgnoreCase(rel, "stylesheet")) continue;
            const href = html.attribute(tag.attributes, "href") orelse continue;
            external_sheets += 1;
            if (resources.stylesheet(href)) |source| sheet.parse(source, height);
        }
    }
}

const Row = struct { start: usize, end: usize, height: u64 };
const Rows = struct {
    pos: usize = 0,

    fn next(self: *Rows) ?Row {
        if (self.pos >= page_len) return null;
        const start = self.pos;
        const end = std.mem.indexOfScalarPos(u8, page[0..page_len], start, '\n') orelse page_len;
        self.pos = if (end == page_len) end else end + 1;
        var height: u64 = 10;
        for (page_line_heights[start..@min(self.pos, page_len)]) |line_height| height = @max(height, line_height);
        return .{ .start = start, .end = end, .height = height };
    }
};

fn visibleRows() Rows {
    var rows: Rows = .{};
    for (0..page_scroll) |_| _ = rows.next();
    return rows;
}

pub fn scroll(lines: i32, height: u64) void {
    if (lines >= 0) {
        page_scroll +|= @intCast(lines);
    } else page_scroll -|= @intCast(-@as(i64, lines));
    clampScroll(height);
}

fn clampScroll(height: u64) void {
    var target = linePixelY(page_lines) -| height;
    var rows: Rows = .{};
    var maximum: usize = 0;
    while (target != 0) {
        const row = rows.next() orelse break;
        if (rows.pos == page_len) break;
        target -|= row.height;
        maximum += 1;
    }
    page_scroll = @min(page_scroll, maximum);
}

pub fn draw(x: u64, y: u64, width: u64, height: u64, normal_ink: u32, link_ink: u32) void {
    clampScroll(height);
    if (page_background_color) |background| canvas.fillRect(x, y, width, height, cssColor(background));
    drawBlockBoxes(x, y, width, height, page_scroll);
    var rows = visibleRows();
    var top: u64 = 0;
    while (rows.next()) |row| {
        if (row.height > height -| top) break;
        const line = page[row.start..row.end];
        drawStyledLine(x, y + top, row.start, line, normal_ink, link_ink, width, @intCast(row.height));
        top += row.height;
    }
}

pub fn linkAt(x: u64, y: u64, width: u64, height: u64) ?[]const u8 {
    if (x >= width or y >= height) return null;
    var rows = visibleRows();
    var top: u64 = 0;
    while (rows.next()) |row| {
        if (row.height > height -| top) return null;
        top += row.height;
        if (y >= top) continue;
        const line = page[row.start..row.end];
        if (line.len == 0) return null;
        const cell_width = @as(u64, 6) * @max(1, page_font_scales[row.start]);
        var glyphs = GlyphPositions.init(0, row.start, line, width);
        for (line, 0..) |ch, column| {
            const index = row.start + column;
            const left = glyphs.next(index, column, ch) orelse continue;
            const glyph_width = if (ch == 0xff) @min(@as(u64, page_media_widths[index]), width - left) else cell_width;
            if (ch != 0xff and left + 6 * @as(u64, @max(1, page_font_scales[index])) > width) continue;
            const id = page_link_ids[index];
            if (id != 0 and x >= left and x < left + glyph_width) {
                const link = &links[id - 1];
                return link.url[0..link.url_len];
            }
        }
        return null;
    }
    return null;
}

const GlyphPositions = struct {
    x: u64,
    cell_width: u64,
    offset: usize,
    width: u64,
    extra: i64 = 0,

    fn init(x: u64, start: usize, text: []const u8, width: u64) GlyphPositions {
        const layout = page_style_flags[start];
        const line_scale: u64 = @max(1, page_font_scales[start]);
        const cell_width = 6 * line_scale;
        var leading_spaces: usize = 0;
        while (leading_spaces < text.len and text[leading_spaces] == ' ') : (leading_spaces += 1) {}
        const content_length = text.len - leading_spaces;
        const align_start: usize = page_align_starts[start];
        const align_width = if (page_align_widths[start] == 0) @as(usize, @intCast(width / cell_width)) else @as(usize, page_align_widths[start]);
        const spare = align_width -| content_length;
        const desired_start = align_start + (if ((layout & 16) != 0) spare / 2 else if ((layout & 32) != 0) spare else 0);
        const offset = desired_start -| leading_spaces;
        return .{ .x = x, .cell_width = cell_width, .offset = offset, .width = width };
    }

    fn next(self: *GlyphPositions, index: usize, column: usize, ch: u8) ?u64 {
        const px = @as(i64, @intCast(self.x + (column + self.offset) * self.cell_width)) + self.extra;
        self.extra += @as(i64, page_letter_spacing[index]) + if (ch == ' ') @as(i64, page_word_spacing[index]) else 0;
        const position: u64 = @intCast(@max(@as(i64, @intCast(self.x)), px));
        return if (position - self.x < self.width) position else null;
    }
};
