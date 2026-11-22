//! Bounded CSS cascade for graphical HTML layout, typography, boxes and media.
const std = @import("std");

const max_rules = 96;
const selector_capacity = 96;

pub const Patch = struct {
    color: ?u24 = null,
    background: ?u24 = null,
    bold: ?bool = null,
    underline: ?bool = null,
    hidden: ?bool = null,
    block: ?bool = null,
    margin: ?Box = null,
    negative_top_margin: ?u16 = null,
    padding: ?Box = null,
    text_align: ?Align = null,
    line_height: ?u8 = null,
    max_width: ?u16 = null,
    margin_auto: ?bool = null,
    font_scale: ?u8 = null,
    relative_font_percent: ?u8 = null,
    opacity: ?u8 = null,
    width: ?u16 = null,
    height: ?u16 = null,
    width_percent: ?u8 = null,
    height_percent: ?u8 = null,
    border_width: ?u8 = null,
    border_color: ?u24 = null,
    border_radius: ?u8 = null,
    background_image: ?ImageUrl = null,
    text_transform: ?TextTransform = null,
    white_space_nowrap: ?bool = null,
    letter_spacing: ?i8 = null,
    word_spacing: ?u8 = null,
    text_indent: ?u16 = null,
    italic: ?bool = null,
    line_through: ?bool = null,
    overline: ?bool = null,
    list_style: ?ListStyle = null,
    min_width: ?u16 = null,
    min_height: ?u16 = null,
    max_height: ?u16 = null,
    background_position: ?BackgroundPosition = null,
    object_fit: ?ObjectFit = null,
    border_style: ?BorderStyle = null,
    border_top_width: ?u8 = null,
};

pub const Box = struct { top: u16 = 0, right: u16 = 0, bottom: u16 = 0, left: u16 = 0 };
pub const Align = enum(u8) { left, center, right };
pub const TextTransform = enum(u8) { none, uppercase, lowercase, capitalize };
pub const ListStyle = enum(u8) { dash, disc, circle, square, decimal, none };
pub const ObjectFit = enum(u8) { fill, contain, cover };
pub const BackgroundPosition = enum(u8) { left, center, right };
pub const BorderStyle = enum(u8) { solid, dashed, dotted, double };
pub const ImageUrl = struct { value: [256]u8 = @splat(0), len: u16 = 0 };

pub const Computed = struct {
    color: ?u24 = null,
    background: ?u24 = null,
    bold: bool = false,
    underline: bool = false,
    hidden: bool = false,
    block: ?bool = null,
    margin: Box = .{},
    negative_top_margin: u16 = 0,
    padding: Box = .{},
    text_align: Align = .left,
    container_background: ?u24 = null,
    line_height: u8 = 10,
    max_width: ?u16 = null,
    margin_auto: bool = false,
    font_scale: u8 = 1,
    font_pixels: u8 = 0,
    opacity: u8 = 255,
    width: ?u16 = null,
    height: ?u16 = null,
    width_percent: ?u8 = null,
    height_percent: ?u8 = null,
    border_width: u8 = 0,
    border_color: ?u24 = null,
    border_radius: u8 = 0,
    background_image: ?ImageUrl = null,
    text_transform: TextTransform = .none,
    white_space_nowrap: bool = false,
    letter_spacing: i8 = 0,
    word_spacing: u8 = 0,
    text_indent: u16 = 0,
    italic: bool = false,
    line_through: bool = false,
    overline: bool = false,
    list_style: ListStyle = .dash,
    min_width: u16 = 0,
    min_height: u16 = 0,
    max_height: u16 = 0,
    background_position: BackgroundPosition = .left,
    object_fit: ObjectFit = .fill,
    border_style: BorderStyle = .solid,
    border_top_width: u8 = 0,
};

const AdvancedScores = struct {
    text_transform: ?u16 = null,
    opacity: ?u16 = null,
    negative_top_margin: ?u16 = null,
    white_space_nowrap: ?u16 = null,
    letter_spacing: ?u16 = null,
    word_spacing: ?u16 = null,
    text_indent: ?u16 = null,
    italic: ?u16 = null,
    line_through: ?u16 = null,
    overline: ?u16 = null,
    list_style: ?u16 = null,
    min_width: ?u16 = null,
    min_height: ?u16 = null,
    max_height: ?u16 = null,
    background_position: ?u16 = null,
    object_fit: ?u16 = null,
    border_style: ?u16 = null,
    border_top_width: ?u16 = null,
};

fn cascadeAdvanced(comptime T: type, target: *T, value: ?T, specificity: u16, best: *?u16) void {
    if (value) |candidate| {
        if (best.* == null or specificity >= best.*.?) {
            target.* = candidate;
            best.* = specificity;
        }
    }
}

const Rule = struct {
    selector: [selector_capacity]u8 = @splat(0),
    selector_len: u8 = 0,
    specificity: u16 = 0,
    patch: Patch = .{},
};

pub const Sheet = struct {
    dark: bool = false,
    rules: [max_rules]Rule = @splat(.{}),
    count: usize = 0,

    pub fn parse(self: *Sheet, source: []const u8, viewport_height: u16) void {
        var cursor: usize = 0;
        while (cursor < source.len and self.count < self.rules.len) {
            skipSpaceAndComments(source, &cursor);
            if (cursor >= source.len) break;
            const open = std.mem.indexOfScalarPos(u8, source, cursor, '{') orelse break;
            const close = std.mem.indexOfScalarPos(u8, source, open + 1, '}') orelse break;
            const selectors = std.mem.trim(u8, source[cursor..open], " \t\r\n");
            const patch = parseDeclarations(source[open + 1 .. close], viewport_height, self.dark);
            var selector_start: usize = 0;
            while (selector_start < selectors.len and self.count < self.rules.len) {
                const comma = std.mem.indexOfScalarPos(u8, selectors, selector_start, ',') orelse selectors.len;
                const selector = std.mem.trim(u8, selectors[selector_start..comma], " \t\r\n");
                if (selector.len != 0 and selector.len <= selector_capacity and !std.mem.startsWith(u8, selector, "@")) {
                    var rule = Rule{ .patch = patch };
                    @memcpy(rule.selector[0..selector.len], selector);
                    rule.selector_len = @intCast(selector.len);
                    rule.specificity = selectorSpecificity(selector);
                    self.rules[self.count] = rule;
                    self.count += 1;
                }
                selector_start = comma + 1;
            }
            cursor = close + 1;
        }
    }

    pub fn compute(self: *const Sheet, parent: Computed, tag: []const u8, id: []const u8, classes: []const u8, previous_tag: []const u8, inline_style: []const u8, viewport_height: u16) Computed {
        var result = Computed{
            .color = parent.color,
            .container_background = parent.container_background,
            .background = null,
            .bold = parent.bold,
            .underline = parent.underline,
            .hidden = false,
            .text_align = parent.text_align,
            .font_scale = parent.font_scale,
            .font_pixels = parent.font_pixels,
            .opacity = parent.opacity,
            .line_height = parent.line_height,
            .text_transform = parent.text_transform,
            .white_space_nowrap = parent.white_space_nowrap,
            .letter_spacing = parent.letter_spacing,
            .word_spacing = parent.word_spacing,
            .italic = parent.italic,
            .margin = if (std.ascii.eqlIgnoreCase(tag, "p")) .{ .top = 16, .bottom = 0 } else .{},
        };
        var advanced_scores = AdvancedScores{};
        var color_score: u16 = 0;
        var background_score: u16 = 0;
        var bold_score: u16 = 0;
        var underline_score: u16 = 0;
        var hidden_score: u16 = 0;
        var has_color = false;
        var has_background = false;
        var has_bold = false;
        var has_underline = false;
        var has_hidden = false;
        var align_score: u16 = 0;
        var has_align = false;
        var margin_score: u16 = 0;
        var padding_score: u16 = 0;
        var block_score: u16 = 0;
        var has_margin = false;
        var has_padding = false;
        var has_block = false;
        var line_height_score: u16 = 0;
        var max_width_score: u16 = 0;
        var margin_auto_score: u16 = 0;
        var has_line_height = false;
        var has_max_width = false;
        var has_margin_auto = false;
        var font_scale_score: u16 = 0;
        var has_font_scale = false;
        var width_score: u16 = 0;
        var height_score: u16 = 0;
        var border_score: u16 = 0;
        var has_width = false;
        var has_height = false;
        var has_border_width = false;
        var has_border_color = false;
        var has_border_radius = false;
        var background_image_score: u16 = 0;
        var has_background_image = false;

        for (self.rules[0..self.count]) |rule| {
            const selector = rule.selector[0..rule.selector_len];
            if (!matchesElement(selector, tag, id, classes, previous_tag)) continue;
            const score = rule.specificity;
            if (rule.patch.color) |value| if (!has_color or score >= color_score) {
                result.color = value;
                color_score = score;
                has_color = true;
            };
            if (rule.patch.background) |value| if (!has_background or score >= background_score) {
                result.background = value;
                background_score = score;
                has_background = true;
            };
            if (rule.patch.bold) |value| if (!has_bold or score >= bold_score) {
                result.bold = value;
                bold_score = score;
                has_bold = true;
            };
            if (rule.patch.underline) |value| if (!has_underline or score >= underline_score) {
                result.underline = value;
                underline_score = score;
                has_underline = true;
            };
            if (rule.patch.hidden) |value| if (!has_hidden or score >= hidden_score) {
                result.hidden = value;
                hidden_score = score;
                has_hidden = true;
            };
            if (rule.patch.block) |value| if (!has_block or score >= block_score) {
                result.block = value;
                block_score = score;
                has_block = true;
            };
            if (rule.patch.margin) |value| if (!has_margin or score >= margin_score) {
                result.margin = value;
                margin_score = score;
                has_margin = true;
            };
            if (rule.patch.padding) |value| if (!has_padding or score >= padding_score) {
                result.padding = value;
                padding_score = score;
                has_padding = true;
            };
            if (rule.patch.text_align) |value| if (!has_align or score >= align_score) {
                result.text_align = value;
                align_score = score;
                has_align = true;
            };
            if (rule.patch.line_height) |value| if (!has_line_height or score >= line_height_score) {
                result.line_height = value;
                line_height_score = score;
                has_line_height = true;
            };
            if (rule.patch.max_width) |value| if (!has_max_width or score >= max_width_score) {
                result.max_width = value;
                max_width_score = score;
                has_max_width = true;
            };
            if (rule.patch.margin_auto) |value| if (!has_margin_auto or score >= margin_auto_score) {
                result.margin_auto = value;
                margin_auto_score = score;
                has_margin_auto = true;
            };
            if (rule.patch.font_scale) |value| if (!has_font_scale or score >= font_scale_score) {
                result.font_scale = value;
                result.font_pixels = 0;
                font_scale_score = score;
                has_font_scale = true;
            };
            if (rule.patch.width) |value| if (!has_width or score >= width_score) {
                result.width = value;
                result.width_percent = null;
                width_score = score;
                has_width = true;
            };
            if (rule.patch.height) |value| if (!has_height or score >= height_score) {
                result.height = value;
                result.height_percent = null;
                height_score = score;
                has_height = true;
            };
            if (rule.patch.width_percent) |value| if (!has_width or score >= width_score) {
                result.width_percent = value;
                result.width = null;
                width_score = score;
                has_width = true;
            };
            if (rule.patch.height_percent) |value| if (!has_height or score >= height_score) {
                result.height_percent = value;
                result.height = null;
                height_score = score;
                has_height = true;
            };
            if (rule.patch.border_width) |value| if (!has_border_width or score >= border_score) {
                result.border_width = value;
                border_score = score;
                has_border_width = true;
            };
            if (rule.patch.border_color) |value| if (!has_border_color or score >= border_score) {
                result.border_color = value;
                border_score = score;
                has_border_color = true;
            };
            if (rule.patch.border_radius) |value| if (!has_border_radius or score >= border_score) {
                result.border_radius = value;
                border_score = score;
                has_border_radius = true;
            };
            if (rule.patch.background_image) |value| if (!has_background_image or score >= background_image_score) {
                result.background_image = value;
                background_image_score = score;
                has_background_image = true;
            };
            if (rule.patch.relative_font_percent) |percent| if (!has_font_scale or score >= font_scale_score) {
                result.font_pixels = relativeFontPixels(parent, percent);
                if (!has_line_height) result.line_height = scaleLineHeight(parent.line_height, percent);
                font_scale_score = score;
                has_font_scale = true;
            };
            cascadeAdvanced(u16, &result.negative_top_margin, rule.patch.negative_top_margin, score, &advanced_scores.negative_top_margin);
            cascadeAdvanced(u8, &result.opacity, rule.patch.opacity, score, &advanced_scores.opacity);
            cascadeAdvanced(TextTransform, &result.text_transform, rule.patch.text_transform, score, &advanced_scores.text_transform);
            cascadeAdvanced(bool, &result.white_space_nowrap, rule.patch.white_space_nowrap, score, &advanced_scores.white_space_nowrap);
            cascadeAdvanced(i8, &result.letter_spacing, rule.patch.letter_spacing, score, &advanced_scores.letter_spacing);
            cascadeAdvanced(u8, &result.word_spacing, rule.patch.word_spacing, score, &advanced_scores.word_spacing);
            cascadeAdvanced(u16, &result.text_indent, rule.patch.text_indent, score, &advanced_scores.text_indent);
            cascadeAdvanced(bool, &result.italic, rule.patch.italic, score, &advanced_scores.italic);
            cascadeAdvanced(bool, &result.line_through, rule.patch.line_through, score, &advanced_scores.line_through);
            cascadeAdvanced(bool, &result.overline, rule.patch.overline, score, &advanced_scores.overline);
            cascadeAdvanced(ListStyle, &result.list_style, rule.patch.list_style, score, &advanced_scores.list_style);
            cascadeAdvanced(u16, &result.min_width, rule.patch.min_width, score, &advanced_scores.min_width);
            cascadeAdvanced(u16, &result.min_height, rule.patch.min_height, score, &advanced_scores.min_height);
            cascadeAdvanced(u16, &result.max_height, rule.patch.max_height, score, &advanced_scores.max_height);
            cascadeAdvanced(BackgroundPosition, &result.background_position, rule.patch.background_position, score, &advanced_scores.background_position);
            cascadeAdvanced(ObjectFit, &result.object_fit, rule.patch.object_fit, score, &advanced_scores.object_fit);
            cascadeAdvanced(BorderStyle, &result.border_style, rule.patch.border_style, score, &advanced_scores.border_style);
            cascadeAdvanced(u8, &result.border_top_width, rule.patch.border_top_width, score, &advanced_scores.border_top_width);
        }

        const inline_patch = parseDeclarations(inline_style, viewport_height, self.dark);
        if (inline_patch.color) |value| result.color = value;
        if (inline_patch.background) |value| result.background = value;
        if (inline_patch.bold) |value| result.bold = value;
        if (inline_patch.underline) |value| result.underline = value;
        if (inline_patch.hidden) |value| result.hidden = value;
        if (inline_patch.block) |value| result.block = value;
        if (inline_patch.margin) |value| result.margin = value;
        if (inline_patch.negative_top_margin) |value| result.negative_top_margin = value;
        if (inline_patch.padding) |value| result.padding = value;
        if (inline_patch.text_align) |value| result.text_align = value;
        if (inline_patch.line_height) |value| result.line_height = value;
        if (inline_patch.max_width) |value| result.max_width = value;
        if (inline_patch.margin_auto) |value| result.margin_auto = value;
        if (inline_patch.font_scale) |value| {
            result.font_scale = value;
            result.font_pixels = 0;
        }
        if (inline_patch.relative_font_percent) |percent| {
            result.font_pixels = relativeFontPixels(parent, percent);
            if (!has_line_height and inline_patch.line_height == null) result.line_height = scaleLineHeight(parent.line_height, percent);
        }
        if (inline_patch.opacity) |opacity| result.opacity = opacity;
        if (inline_patch.width) |value| result.width = value;
        if (inline_patch.height) |value| result.height = value;
        if (inline_patch.width_percent) |value| result.width_percent = value;
        if (inline_patch.height_percent) |value| result.height_percent = value;
        if (inline_patch.border_width) |value| result.border_width = value;
        if (inline_patch.border_color) |value| result.border_color = value;
        if (inline_patch.border_radius) |value| result.border_radius = value;
        if (inline_patch.background_image) |value| result.background_image = value;
        if (inline_patch.text_transform) |value| result.text_transform = value;
        if (inline_patch.white_space_nowrap) |value| result.white_space_nowrap = value;
        if (inline_patch.letter_spacing) |value| result.letter_spacing = value;
        if (inline_patch.word_spacing) |value| result.word_spacing = value;
        if (inline_patch.text_indent) |value| result.text_indent = value;
        if (inline_patch.italic) |value| result.italic = value;
        if (inline_patch.line_through) |value| result.line_through = value;
        if (inline_patch.overline) |value| result.overline = value;
        if (inline_patch.list_style) |value| result.list_style = value;
        if (inline_patch.min_width) |value| result.min_width = value;
        if (inline_patch.min_height) |value| result.min_height = value;
        if (inline_patch.max_height) |value| result.max_height = value;
        if (inline_patch.background_position) |value| result.background_position = value;
        if (inline_patch.object_fit) |value| result.object_fit = value;
        if (inline_patch.border_style) |value| result.border_style = value;
        if (inline_patch.border_top_width) |value| result.border_top_width = value;
        return result;
    }
};

fn scaleLineHeight(line_height: u8, percent: u8) u8 {
    return @intCast(@max(10, @min(255, (@as(u16, line_height) * percent + 50) / 100)));
}

fn relativeFontPixels(parent: Computed, percent: u8) u8 {
    const size = if (parent.font_pixels != 0) parent.font_pixels else if (parent.font_scale <= 1) @as(u8, 10) else parent.font_scale * 8;
    return @intCast(@max(6, @min(32, (@as(u16, size) * percent + 50) / 100)));
}

fn parseOpacity(value: []const u8) ?u8 {
    const number = std.fmt.parseFloat(f64, value) catch return null;
    if (!std.math.isFinite(number)) return null;
    return @intFromFloat(@min(1, @max(0, number)) * 255 + 0.5);
}

fn parseDeclarations(input: []const u8, viewport_height: u16, dark: bool) Patch {
    var result = Patch{};
    var cursor: usize = 0;
    while (cursor < input.len) {
        const end = std.mem.indexOfScalarPos(u8, input, cursor, ';') orelse input.len;
        const declaration = std.mem.trim(u8, input[cursor..end], " \t\r\n");
        if (std.mem.indexOfScalar(u8, declaration, ':')) |colon| {
            const name = std.mem.trim(u8, declaration[0..colon], " \t\r\n");
            const value = std.mem.trim(u8, declaration[colon + 1 ..], " \t\r\n");
            if (std.ascii.eqlIgnoreCase(name, "color")) {
                result.color = parseColor(value, dark) orelse result.color;
            } else if (std.ascii.eqlIgnoreCase(name, "background-color") or std.ascii.eqlIgnoreCase(name, "background")) {
                result.background = parseColor(value, dark) orelse result.background;
                result.background_image = parseImageUrl(value) orelse result.background_image;
            } else if (std.ascii.eqlIgnoreCase(name, "background-image")) {
                result.background_image = parseImageUrl(value) orelse result.background_image;
            } else if (std.ascii.eqlIgnoreCase(name, "font-weight")) {
                result.bold = std.ascii.eqlIgnoreCase(value, "bold") or std.ascii.eqlIgnoreCase(value, "bolder") or numericWeight(value) >= 600;
            } else if (std.ascii.eqlIgnoreCase(name, "text-decoration")) {
                if (std.ascii.eqlIgnoreCase(value, "none")) {
                    result.underline = false;
                    result.line_through = false;
                    result.overline = false;
                } else {
                    result.underline = std.mem.indexOf(u8, value, "underline") != null;
                    result.line_through = std.mem.indexOf(u8, value, "line-through") != null;
                    result.overline = std.mem.indexOf(u8, value, "overline") != null;
                }
            } else if (std.ascii.eqlIgnoreCase(name, "text-decoration-line")) {
                result.underline = containsIgnoreCase(value, "underline");
                result.line_through = containsIgnoreCase(value, "line-through");
                result.overline = containsIgnoreCase(value, "overline");
            } else if (std.ascii.eqlIgnoreCase(name, "text-decoration-color")) {
                result.color = parseColor(value, dark) orelse result.color;
            } else if (oneOfIgnoreCase(name, &.{ "text-decoration-style", "text-decoration-thickness", "text-underline-offset" })) {
                if (std.ascii.eqlIgnoreCase(value, "none")) result.underline = false else if (std.ascii.eqlIgnoreCase(name, "text-decoration-thickness")) result.underline = true;
            } else if (std.ascii.eqlIgnoreCase(name, "text-transform")) {
                if (std.ascii.eqlIgnoreCase(value, "uppercase")) result.text_transform = .uppercase else if (std.ascii.eqlIgnoreCase(value, "lowercase")) result.text_transform = .lowercase else if (std.ascii.eqlIgnoreCase(value, "capitalize")) result.text_transform = .capitalize else if (std.ascii.eqlIgnoreCase(value, "none")) result.text_transform = .none;
            } else if (std.ascii.eqlIgnoreCase(name, "white-space")) {
                if (std.ascii.eqlIgnoreCase(value, "nowrap")) result.white_space_nowrap = true else if (std.ascii.eqlIgnoreCase(value, "normal") or std.ascii.eqlIgnoreCase(value, "pre-wrap") or std.ascii.eqlIgnoreCase(value, "pre-line")) result.white_space_nowrap = false;
            } else if (std.ascii.eqlIgnoreCase(name, "text-wrap")) {
                if (std.ascii.eqlIgnoreCase(value, "nowrap")) result.white_space_nowrap = true else if (std.ascii.eqlIgnoreCase(value, "wrap")) result.white_space_nowrap = false;
            } else if (oneOfIgnoreCase(name, &.{ "overflow-wrap", "word-break" })) {
                result.white_space_nowrap = std.ascii.eqlIgnoreCase(value, "keep-all");
            } else if (std.ascii.eqlIgnoreCase(name, "text-overflow")) {
                result.white_space_nowrap = std.ascii.eqlIgnoreCase(value, "ellipsis");
            } else if (std.ascii.eqlIgnoreCase(name, "letter-spacing")) {
                if (std.ascii.eqlIgnoreCase(value, "normal")) result.letter_spacing = 0 else result.letter_spacing = parseSpacing(value) orelse result.letter_spacing;
            } else if (std.ascii.eqlIgnoreCase(name, "word-spacing")) {
                if (std.ascii.eqlIgnoreCase(value, "normal")) {
                    result.word_spacing = 0;
                } else if (parseLength(value, viewport_height)) |spacing| {
                    result.word_spacing = @intCast(@min(32, spacing));
                }
            } else if (std.ascii.eqlIgnoreCase(name, "text-indent")) {
                result.text_indent = parseLength(value, viewport_height) orelse result.text_indent;
            } else if (std.ascii.eqlIgnoreCase(name, "font-style")) {
                result.italic = std.ascii.eqlIgnoreCase(value, "italic") or std.ascii.eqlIgnoreCase(value, "oblique");
            } else if (std.ascii.eqlIgnoreCase(name, "font-variant")) {
                if (std.ascii.eqlIgnoreCase(value, "small-caps")) result.text_transform = .uppercase;
            } else if (std.ascii.eqlIgnoreCase(name, "font-stretch")) {
                if (oneOfIgnoreCase(value, &.{ "expanded", "semi-expanded", "wider" })) result.font_scale = @min(4, (result.font_scale orelse 1) + 1) else if (oneOfIgnoreCase(value, &.{ "condensed", "semi-condensed", "narrower" })) result.font_scale = @max(1, (result.font_scale orelse 1) -| 1);
            } else if (std.ascii.eqlIgnoreCase(name, "vertical-align")) {
                if (oneOfIgnoreCase(value, &.{ "sub", "super", "text-top", "text-bottom" })) result.font_scale = @max(1, (result.font_scale orelse 1) -| 1);
            } else if (std.ascii.eqlIgnoreCase(name, "list-style-type")) {
                if (std.ascii.eqlIgnoreCase(value, "none")) result.list_style = .none else if (std.ascii.eqlIgnoreCase(value, "disc")) result.list_style = .disc else if (std.ascii.eqlIgnoreCase(value, "circle")) result.list_style = .circle else if (std.ascii.eqlIgnoreCase(value, "square")) result.list_style = .square else if (std.ascii.eqlIgnoreCase(value, "decimal")) result.list_style = .decimal else if (std.ascii.eqlIgnoreCase(value, "initial") or std.ascii.eqlIgnoreCase(value, "outside")) result.list_style = .dash;
            } else if (std.ascii.eqlIgnoreCase(name, "list-style")) {
                if (containsIgnoreCase(value, "decimal")) result.list_style = .decimal else if (containsIgnoreCase(value, "square")) result.list_style = .square else if (containsIgnoreCase(value, "circle")) result.list_style = .circle else if (containsIgnoreCase(value, "disc")) result.list_style = .disc else if (containsIgnoreCase(value, "none")) result.list_style = .none;
            } else if (std.ascii.eqlIgnoreCase(name, "list-style-position")) {
                if (std.ascii.eqlIgnoreCase(value, "inside")) result.text_indent = 8 else if (std.ascii.eqlIgnoreCase(value, "outside")) result.text_indent = 0;
            } else if (std.ascii.eqlIgnoreCase(name, "display")) {
                result.hidden = std.ascii.eqlIgnoreCase(value, "none");
                if (std.ascii.eqlIgnoreCase(value, "block")) result.block = true else if (std.ascii.eqlIgnoreCase(value, "inline") or std.ascii.eqlIgnoreCase(value, "inline-block")) result.block = false;
            } else if (std.ascii.eqlIgnoreCase(name, "visibility")) {
                result.hidden = oneOfIgnoreCase(value, &.{ "hidden", "collapse" });
            } else if (oneOfIgnoreCase(name, &.{ "overflow", "overflow-x", "overflow-y" })) {
                if (oneOfIgnoreCase(value, &.{ "hidden", "clip" })) result.hidden = true;
            } else if (std.ascii.eqlIgnoreCase(name, "text-align")) {
                result.text_align = if (std.ascii.eqlIgnoreCase(value, "center")) .center else if (std.ascii.eqlIgnoreCase(value, "right")) .right else if (std.ascii.eqlIgnoreCase(value, "left")) .left else result.text_align;
            } else if (std.ascii.eqlIgnoreCase(name, "text-align-last")) {
                result.text_align = if (std.ascii.eqlIgnoreCase(value, "center")) .center else if (std.ascii.eqlIgnoreCase(value, "right")) .right else if (std.ascii.eqlIgnoreCase(value, "left")) .left else result.text_align;
            } else if (std.ascii.eqlIgnoreCase(name, "line-height")) {
                result.line_height = parseLineHeight(value) orelse result.line_height;
            } else if (std.ascii.eqlIgnoreCase(name, "font")) {
                const size_end = std.mem.indexOfAny(u8, value, "/ \t\r\n") orelse value.len;
                result.font_scale = parseFontScale(value[0..size_end]) orelse result.font_scale;
                if (std.mem.indexOfScalar(u8, value, '/')) |slash| result.line_height = parseLineHeight(value[slash + 1 ..]) orelse result.line_height;
            } else if (std.ascii.eqlIgnoreCase(name, "font-size")) {
                if (std.ascii.endsWithIgnoreCase(value, "em") and !std.ascii.endsWithIgnoreCase(value, "rem")) {
                    const number = std.fmt.parseFloat(f64, value[0 .. value.len - 2]) catch 0;
                    if (std.math.isFinite(number) and number > 0) {
                        result.relative_font_percent = @intFromFloat(@min(255, number * 100 + 0.5));
                        result.font_scale = null;
                    }
                } else if (parseFontScale(value)) |scale| {
                    result.font_scale = scale;
                    result.relative_font_percent = null;
                }
            } else if (std.ascii.eqlIgnoreCase(name, "opacity")) {
                result.opacity = parseOpacity(value) orelse result.opacity;
            } else if (std.ascii.eqlIgnoreCase(name, "width")) {
                if (std.ascii.endsWithIgnoreCase(value, "%")) {
                    result.width_percent = parsePercent(value) orelse result.width_percent;
                    result.width = null;
                } else {
                    result.width = parseLength(value, viewport_height) orelse result.width;
                    result.width_percent = null;
                }
            } else if (std.ascii.eqlIgnoreCase(name, "height")) {
                if (std.ascii.endsWithIgnoreCase(value, "%")) {
                    result.height_percent = parsePercent(value) orelse result.height_percent;
                    result.height = null;
                } else {
                    result.height = parseLength(value, viewport_height) orelse result.height;
                    result.height_percent = null;
                }
            } else if (std.ascii.eqlIgnoreCase(name, "min-width")) {
                result.min_width = parseLength(value, viewport_height) orelse result.min_width;
            } else if (std.ascii.eqlIgnoreCase(name, "min-height")) {
                result.min_height = parseLength(value, viewport_height) orelse result.min_height;
            } else if (std.ascii.eqlIgnoreCase(name, "max-height")) {
                result.max_height = parseLength(value, viewport_height) orelse result.max_height;
            } else if (std.ascii.eqlIgnoreCase(name, "background-position")) {
                if (containsIgnoreCase(value, "center")) result.background_position = .center else if (containsIgnoreCase(value, "right")) result.background_position = .right else if (containsIgnoreCase(value, "left")) result.background_position = .left;
            } else if (oneOfIgnoreCase(name, &.{ "background-position-x", "background-position-y", "object-position" })) {
                if (containsIgnoreCase(value, "center")) result.background_position = .center else if (containsIgnoreCase(value, "right")) result.background_position = .right else if (containsIgnoreCase(value, "left")) result.background_position = .left;
            } else if (std.ascii.eqlIgnoreCase(name, "background-size")) {
                if (std.ascii.eqlIgnoreCase(value, "contain")) result.object_fit = .contain else if (std.ascii.eqlIgnoreCase(value, "cover")) result.object_fit = .cover else if (std.ascii.eqlIgnoreCase(value, "auto") or std.ascii.eqlIgnoreCase(value, "100% 100%")) result.object_fit = .fill;
            } else if (oneOfIgnoreCase(name, &.{ "background-repeat", "background-attachment", "background-origin", "background-clip" })) {
                // The current renderer draws one clipped image per box; no-repeat is native behavior.
            } else if (std.ascii.eqlIgnoreCase(name, "object-fit")) {
                if (std.ascii.eqlIgnoreCase(value, "contain")) result.object_fit = .contain else if (std.ascii.eqlIgnoreCase(value, "cover")) result.object_fit = .cover else if (std.ascii.eqlIgnoreCase(value, "fill")) result.object_fit = .fill;
            } else if (std.ascii.eqlIgnoreCase(name, "border-style")) {
                result.border_style = parseBorderStyleValue(value) orelse result.border_style;
            } else if (std.ascii.eqlIgnoreCase(name, "border-top-width")) {
                const length = parseLength(value, viewport_height) orelse 0;
                result.border_top_width = @intCast(@min(8, length));
            } else if (oneOfIgnoreCase(name, &.{ "border-right-width", "border-bottom-width", "border-left-width" })) {
                const length = parseLength(value, viewport_height) orelse 0;
                result.border_width = @intCast(@min(8, length));
            } else if (oneOfIgnoreCase(name, &.{ "border-top-color", "border-right-color", "border-bottom-color", "border-left-color" })) {
                result.border_color = parseColor(value, dark) orelse result.border_color;
            } else if (oneOfIgnoreCase(name, &.{ "border-top-style", "border-right-style", "border-bottom-style", "border-left-style" })) {
                result.border_style = parseBorderStyleValue(value) orelse result.border_style;
            } else if (oneOfIgnoreCase(name, &.{ "border-top-left-radius", "border-top-right-radius", "border-bottom-right-radius", "border-bottom-left-radius" })) {
                const length = parseLength(value, viewport_height) orelse 0;
                result.border_radius = @intCast(@min(24, length));
            } else if (oneOfIgnoreCase(name, &.{ "border-top", "border-right", "border-bottom", "border-left", "outline" })) {
                var parts = std.mem.tokenizeScalar(u8, value, ' ');
                while (parts.next()) |part| {
                    if (parseLength(part, viewport_height)) |length| result.border_width = @intCast(@min(8, length)) else if (parseColor(part, dark)) |color| result.border_color = color else if (parseBorderStyleValue(part)) |style| result.border_style = style;
                }
            } else if (oneOfIgnoreCase(name, &.{ "outline-width", "outline-offset" })) {
                const length = parseLength(value, viewport_height) orelse 0;
                result.border_width = @intCast(@min(8, length));
            } else if (std.ascii.eqlIgnoreCase(name, "outline-color")) {
                result.border_color = parseColor(value, dark) orelse result.border_color;
            } else if (std.ascii.eqlIgnoreCase(name, "outline-style")) {
                result.border_style = parseBorderStyleValue(value) orelse result.border_style;
            } else if (std.ascii.eqlIgnoreCase(name, "border-width")) {
                const length = parseLength(value, viewport_height) orelse 0;
                result.border_width = @intCast(@min(8, length));
            } else if (std.ascii.eqlIgnoreCase(name, "border-color")) {
                result.border_color = parseColor(value, dark) orelse result.border_color;
            } else if (std.ascii.eqlIgnoreCase(name, "border-radius")) {
                const length = parseLength(value, viewport_height) orelse 0;
                result.border_radius = @intCast(@min(24, length));
            } else if (std.ascii.eqlIgnoreCase(name, "border")) {
                var parts = std.mem.tokenizeScalar(u8, value, ' ');
                while (parts.next()) |part| {
                    if (std.mem.indexOf(u8, part, "px") != null) {
                        const length = parseLength(part, viewport_height) orelse 0;
                        result.border_width = @intCast(@min(8, length));
                    } else if (parseColor(part, dark)) |color| result.border_color = color;
                }
            } else if (std.ascii.eqlIgnoreCase(name, "max-width")) {
                result.max_width = parseLength(value, viewport_height) orelse result.max_width;
            } else if (std.ascii.eqlIgnoreCase(name, "margin")) {
                var terms = std.mem.tokenizeAny(u8, value, " \t\r\n");
                const top = terms.next() orelse "";
                const side = terms.next() orelse top;
                if (top.len > 1 and top[0] == '-') {
                    result.negative_top_margin = parseLength(top[1..], viewport_height) orelse 0;
                } else result.negative_top_margin = 0;
                if (std.ascii.eqlIgnoreCase(side, "auto")) result.margin_auto = true;
                result.margin = parseBox(value, viewport_height) orelse result.margin;
            } else if (std.ascii.eqlIgnoreCase(name, "padding")) {
                result.padding = parseBox(value, viewport_height) orelse result.padding;
            } else if (oneOfIgnoreCase(name, &.{ "margin-inline-start", "margin-inline-end", "margin-block-start", "margin-block-end" })) {
                const length = parseLength(value, viewport_height) orelse 0;
                var box = result.margin orelse Box{};
                if (std.ascii.eqlIgnoreCase(name, "margin-inline-start")) box.left = length else if (std.ascii.eqlIgnoreCase(name, "margin-inline-end")) box.right = length else if (std.ascii.eqlIgnoreCase(name, "margin-block-start")) box.top = length else box.bottom = length;
                result.margin = box;
            } else if (oneOfIgnoreCase(name, &.{ "padding-inline-start", "padding-inline-end", "padding-block-start", "padding-block-end" })) {
                const length = parseLength(value, viewport_height) orelse 0;
                var box = result.padding orelse Box{};
                if (std.ascii.eqlIgnoreCase(name, "padding-inline-start")) box.left = length else if (std.ascii.eqlIgnoreCase(name, "padding-inline-end")) box.right = length else if (std.ascii.eqlIgnoreCase(name, "padding-block-start")) box.top = length else box.bottom = length;
                result.padding = box;
            } else if (name.len >= 7 and std.ascii.eqlIgnoreCase(name[0..7], "margin-")) {
                const length = parseLength(value, viewport_height) orelse 0;
                var box = result.margin orelse Box{};
                if (std.ascii.eqlIgnoreCase(name, "margin-top")) box.top = length else if (std.ascii.eqlIgnoreCase(name, "margin-right")) box.right = length else if (std.ascii.eqlIgnoreCase(name, "margin-bottom")) box.bottom = length else if (std.ascii.eqlIgnoreCase(name, "margin-left")) box.left = length;
                result.margin = box;
            } else if (name.len >= 8 and std.ascii.eqlIgnoreCase(name[0..8], "padding-")) {
                const length = parseLength(value, viewport_height) orelse 0;
                var box = result.padding orelse Box{};
                if (std.ascii.eqlIgnoreCase(name, "padding-top")) box.top = length else if (std.ascii.eqlIgnoreCase(name, "padding-right")) box.right = length else if (std.ascii.eqlIgnoreCase(name, "padding-bottom")) box.bottom = length else if (std.ascii.eqlIgnoreCase(name, "padding-left")) box.left = length;
                result.padding = box;
            }
        }
        cursor = if (end < input.len) end + 1 else input.len;
    }
    return result;
}

fn parseLength(raw: []const u8, viewport_height: u16) ?u16 {
    const value = std.mem.trim(u8, raw, " \t\r\n");
    if (value.len == 0 or std.ascii.eqlIgnoreCase(value, "auto")) return null;
    var end = value.len;
    var multiplier: u16 = 1;
    if (std.ascii.endsWithIgnoreCase(value, "px")) end -= 2 else if (std.ascii.endsWithIgnoreCase(value, "rem") or std.ascii.endsWithIgnoreCase(value, "em")) {
        end -= if (std.ascii.endsWithIgnoreCase(value, "rem")) @as(usize, 3) else 2;
        multiplier = 16;
    } else if (std.ascii.endsWithIgnoreCase(value, "vh")) {
        end -= 2;
        const percent = std.fmt.parseInt(u16, value[0..end], 10) catch return null;
        return @intCast(@min(4096, (@as(u32, percent) * viewport_height) / 100));
    } else if (std.ascii.endsWithIgnoreCase(value, "pt")) {
        end -= 2;
        multiplier = 1;
    }
    if (std.mem.indexOfScalar(u8, value[0..end], '.') != null) {
        const decimal = std.fmt.parseFloat(f64, value[0..end]) catch return null;
        if (!std.math.isFinite(decimal) or decimal < 0) return null;
        return @intFromFloat(@min(4096, @round(decimal * @as(f64, @floatFromInt(multiplier)))));
    }
    const number = std.fmt.parseInt(u16, value[0..end], 10) catch return null;
    if (number >= 4096 or number > 4096 / multiplier) return 4096;
    return @intCast(number * multiplier);
}

fn parseSpacing(raw: []const u8) ?i8 {
    var value = std.mem.trim(u8, raw, " \t\r\n");
    if (std.ascii.endsWithIgnoreCase(value, "px")) value = value[0 .. value.len - 2];
    const parsed = std.fmt.parseInt(i16, value, 10) catch return null;
    return @intCast(@max(-8, @min(32, parsed)));
}

fn containsIgnoreCase(value: []const u8, needle: []const u8) bool {
    if (needle.len > value.len) return false;
    var offset: usize = 0;
    while (offset + needle.len <= value.len) : (offset += 1) {
        if (std.ascii.eqlIgnoreCase(value[offset .. offset + needle.len], needle)) return true;
    }
    return false;
}

fn oneOfIgnoreCase(value: []const u8, choices: []const []const u8) bool {
    for (choices) |choice| if (std.ascii.eqlIgnoreCase(value, choice)) return true;
    return false;
}

fn parseBorderStyleValue(value: []const u8) ?BorderStyle {
    if (std.ascii.eqlIgnoreCase(value, "solid")) return .solid;
    if (std.ascii.eqlIgnoreCase(value, "dashed")) return .dashed;
    if (std.ascii.eqlIgnoreCase(value, "dotted")) return .dotted;
    if (std.ascii.eqlIgnoreCase(value, "double")) return .double;
    return null;
}

fn parseImageUrl(raw: []const u8) ?ImageUrl {
    const start = std.mem.indexOf(u8, raw, "url(") orelse return null;
    const value_start = start + 4;
    const close = std.mem.indexOfScalarPos(u8, raw, value_start, ')') orelse return null;
    const url = std.mem.trim(u8, raw[value_start..close], " \t\r\n\"'");
    if (url.len == 0 or url.len > 256 or std.mem.startsWith(u8, url, "data:")) return null;
    var result = ImageUrl{};
    result.len = @intCast(url.len);
    @memcpy(result.value[0..url.len], url);
    return result;
}

fn parsePercent(raw: []const u8) ?u8 {
    if (!std.ascii.endsWithIgnoreCase(raw, "%")) return null;
    const value = std.fmt.parseInt(u16, raw[0 .. raw.len - 1], 10) catch return null;
    if (value > 100) return null;
    return @intCast(value);
}

fn parseBox(value: []const u8, viewport_height: u16) ?Box {
    var lengths: [4]u16 = .{ 0, 0, 0, 0 };
    var count: usize = 0;
    var cursor: usize = 0;
    while (cursor < value.len) {
        while (cursor < value.len and isSpace(value[cursor])) : (cursor += 1) {}
        if (cursor == value.len) break;
        const start = cursor;
        while (cursor < value.len and !isSpace(value[cursor])) : (cursor += 1) {}
        if (count == lengths.len) return null;
        lengths[count] = parseLength(value[start..cursor], viewport_height) orelse return null;
        count += 1;
    }
    if (count == 0) return null;
    return switch (count) {
        1 => .{ .top = lengths[0], .right = lengths[0], .bottom = lengths[0], .left = lengths[0] },
        2 => .{ .top = lengths[0], .right = lengths[1], .bottom = lengths[0], .left = lengths[1] },
        3 => .{ .top = lengths[0], .right = lengths[1], .bottom = lengths[2], .left = lengths[1] },
        4 => .{ .top = lengths[0], .right = lengths[1], .bottom = lengths[2], .left = lengths[3] },
        else => null,
    };
}

fn parseLineHeight(raw: []const u8) ?u8 {
    var value = std.mem.trim(u8, raw, " \t\r\n");
    if (std.mem.indexOfAny(u8, value, " \t\r\n")) |space| value = value[0..space];
    if (std.ascii.eqlIgnoreCase(value, "normal")) return 16;
    if (std.ascii.endsWithIgnoreCase(value, "px")) {
        const px = std.fmt.parseInt(u16, value[0 .. value.len - 2], 10) catch return null;
        return @intCast(@min(64, @max(10, px)));
    }
    // The supplied font shorthand uses a unitless 1.6 multiplier for a 16px font.
    if (value.len == 3 and value[1] == '.' and std.ascii.isDigit(value[0]) and std.ascii.isDigit(value[2])) {
        const tenths = (value[0] - '0') * 10 + (value[2] - '0');
        return @intCast(@min(64, @max(10, (@as(u16, tenths) * 16 + 5) / 10)));
    }
    return null;
}

fn parseFontScale(raw: []const u8) ?u8 {
    const value = std.mem.trim(u8, raw, " \t\r\n");
    if (!std.ascii.endsWithIgnoreCase(value, "px")) return null;
    const px = std.fmt.parseInt(u16, value[0 .. value.len - 2], 10) catch return null;
    return @intCast(@min(4, @max(1, (px + 7) / 8)));
}

fn skipSpaceAndComments(input: []const u8, cursor: *usize) void {
    while (cursor.* < input.len) {
        if (isSpace(input[cursor.*])) {
            cursor.* += 1;
        } else if (cursor.* + 1 < input.len and input[cursor.*] == '/' and input[cursor.* + 1] == '*') {
            const end = std.mem.indexOfPos(u8, input, cursor.* + 2, "*/") orelse {
                cursor.* = input.len;
                return;
            };
            cursor.* = end + 2;
        } else return;
    }
}

fn selectorSpecificity(selector: []const u8) u16 {
    var score: u16 = 0;
    var i: usize = 0;
    while (i < selector.len) {
        if (selector[i] == '#') score +|= 100 else if (selector[i] == '.') score +|= 10 else if (std.ascii.isAlphabetic(selector[i]) and (i == 0 or !std.ascii.isAlphanumeric(selector[i - 1]))) score +|= 1;
        i += 1;
    }
    return score;
}

fn matchesElement(selector: []const u8, tag: []const u8, id: []const u8, classes: []const u8, previous_tag: []const u8) bool {
    if (std.mem.indexOfScalar(u8, selector, '+')) |plus| {
        const earlier = std.mem.trim(u8, selector[0..plus], " \t\r\n");
        return earlier.len != 0 and std.ascii.eqlIgnoreCase(earlier, previous_tag) and matches(selector[plus + 1 ..], tag, id, classes);
    }
    return matches(selector, tag, id, classes);
}

fn matches(selector: []const u8, tag: []const u8, id: []const u8, classes: []const u8) bool {
    const trimmed = std.mem.trim(u8, selector, " \t\r\n");
    if (std.mem.indexOfAny(u8, trimmed, " >+~:[")) |complex| {
        if (complex != 0) return false;
    }
    var i: usize = 0;
    if (trimmed.len == 0) return false;
    if (trimmed[0] == '*') {
        i = 1;
    } else if (std.ascii.isAlphabetic(trimmed[0])) {
        const start = i;
        while (i < trimmed.len and (std.ascii.isAlphanumeric(trimmed[i]) or trimmed[i] == '-')) : (i += 1) {}
        if (!std.ascii.eqlIgnoreCase(trimmed[start..i], tag)) return false;
    }
    while (i < trimmed.len) {
        const marker = trimmed[i];
        if (marker != '.' and marker != '#') return false;
        i += 1;
        const start = i;
        while (i < trimmed.len and (std.ascii.isAlphanumeric(trimmed[i]) or trimmed[i] == '-' or trimmed[i] == '_')) : (i += 1) {}
        if (start == i) return false;
        const expected = trimmed[start..i];
        if (marker == '#') {
            if (!std.mem.eql(u8, expected, id)) return false;
        } else if (!hasClass(classes, expected)) return false;
    }
    return true;
}

fn hasClass(classes: []const u8, expected: []const u8) bool {
    var cursor: usize = 0;
    while (cursor < classes.len) {
        while (cursor < classes.len and isSpace(classes[cursor])) : (cursor += 1) {}
        const start = cursor;
        while (cursor < classes.len and !isSpace(classes[cursor])) : (cursor += 1) {}
        if (std.mem.eql(u8, classes[start..cursor], expected)) return true;
    }
    return false;
}

fn parseColor(input: []const u8, dark: bool) ?u24 {
    var value = std.mem.trim(u8, input, " \t\r\n");
    const prefix = "light-dark(";
    if (std.ascii.startsWithIgnoreCase(value, prefix)) {
        if (!std.mem.endsWith(u8, value, ")")) return null;
        const arguments = value[prefix.len .. value.len - 1];
        const comma = std.mem.indexOfScalar(u8, arguments, ',') orelse return null;
        const selected = if (dark) arguments[comma + 1 ..] else arguments[0..comma];
        value = std.mem.trim(u8, selected, " \t\r\n");
    }
    if (value.len == 4 and value[0] == '#') {
        const r = std.fmt.parseInt(u8, value[1..2], 16) catch return null;
        const g = std.fmt.parseInt(u8, value[2..3], 16) catch return null;
        const b = std.fmt.parseInt(u8, value[3..4], 16) catch return null;
        return (@as(u24, r * 17) << 16) | (@as(u24, g * 17) << 8) | (@as(u24, b * 17));
    }
    if (value.len == 7 and value[0] == '#') return std.fmt.parseInt(u24, value[1..], 16) catch null;
    if (std.ascii.eqlIgnoreCase(value, "black")) return 0x000000;
    if (std.ascii.eqlIgnoreCase(value, "white")) return 0xffffff;
    if (std.ascii.eqlIgnoreCase(value, "red")) return 0xff0000;
    if (std.ascii.eqlIgnoreCase(value, "green")) return 0x008000;
    if (std.ascii.eqlIgnoreCase(value, "blue")) return 0x0000ff;
    if (std.ascii.eqlIgnoreCase(value, "yellow")) return 0xffff00;
    if (std.ascii.eqlIgnoreCase(value, "gray") or std.ascii.eqlIgnoreCase(value, "grey")) return 0x808080;
    if (std.ascii.eqlIgnoreCase(value, "silver")) return 0xc0c0c0;
    if (std.ascii.eqlIgnoreCase(value, "maroon")) return 0x800000;
    if (std.ascii.eqlIgnoreCase(value, "purple")) return 0x800080;
    if (std.ascii.eqlIgnoreCase(value, "fuchsia")) return 0xff00ff;
    if (std.ascii.eqlIgnoreCase(value, "lime")) return 0x00ff00;
    if (std.ascii.eqlIgnoreCase(value, "olive")) return 0x808000;
    if (std.ascii.eqlIgnoreCase(value, "navy")) return 0x000080;
    if (std.ascii.eqlIgnoreCase(value, "teal")) return 0x008080;
    if (std.ascii.eqlIgnoreCase(value, "aqua")) return 0x00ffff;
    if (std.ascii.eqlIgnoreCase(value, "orange")) return 0xffa500;
    return null;
}

fn numericWeight(value: []const u8) u16 {
    return std.fmt.parseInt(u16, value, 10) catch 0;
}

fn isSpace(ch: u8) bool {
    return ch == ' ' or ch == '\t' or ch == '\r' or ch == '\n';
}
