//! Safe, bounded SVG rasterizer for common shapes and simple paths.
const std = @import("std");
const fat32 = @import("../fs/storage.zig");
const vm = @import("../memory/vm.zig");
const media = @import("media.zig");

const Point = struct { x: f64, y: f64 };
const Color = struct { r: u8, g: u8, b: u8, a: u8 };
const white = Color{ .r = 255, .g = 255, .b = 255, .a = 255 };
const black = Color{ .r = 0, .g = 0, .b = 0, .a = 255 };

fn attr(tag: []const u8, wanted: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < tag.len and !space(tag[i])) : (i += 1) {}
    while (i < tag.len) {
        while (i < tag.len and (space(tag[i]) or tag[i] == '/')) : (i += 1) {}
        const start = i;
        while (i < tag.len and tag[i] != '=' and !space(tag[i]) and tag[i] != '/') : (i += 1) {}
        if (start == i) break;
        const name = tag[start..i];
        while (i < tag.len and space(tag[i])) : (i += 1) {}
        if (i == tag.len or tag[i] != '=') continue;
        i += 1;
        while (i < tag.len and space(tag[i])) : (i += 1) {}
        if (i == tag.len) return null;
        const quote = if (tag[i] == '"' or tag[i] == '\'') tag[i] else 0;
        if (quote != 0) i += 1;
        const value_start = i;
        if (quote != 0) {
            while (i < tag.len and tag[i] != quote) : (i += 1) {}
        } else {
            while (i < tag.len and !space(tag[i]) and tag[i] != '/') : (i += 1) {}
        }
        const value = tag[value_start..i];
        if (quote != 0 and i < tag.len) i += 1;
        if (std.ascii.eqlIgnoreCase(name, wanted)) return value;
    }
    return null;
}

fn styleValue(tag: []const u8, wanted: []const u8) ?[]const u8 {
    const style = attr(tag, "style") orelse return null;
    var cursor: usize = 0;
    while (cursor < style.len) {
        const end = std.mem.indexOfScalarPos(u8, style, cursor, ';') orelse style.len;
        const item = std.mem.trim(u8, style[cursor..end], " \t\r\n");
        if (std.mem.indexOfScalar(u8, item, ':')) |colon| {
            if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, item[0..colon], " \t\r\n"), wanted))
                return std.mem.trim(u8, item[colon + 1 ..], " \t\r\n");
        }
        cursor = if (end < style.len) end + 1 else style.len;
    }
    return null;
}

fn number(raw: ?[]const u8, fallback: f64) f64 {
    const value = raw orelse return fallback;
    var end = value.len;
    while (end > 0 and ((value[end - 1] >= 'a' and value[end - 1] <= 'z') or value[end - 1] == '%')) : (end -= 1) {}
    return std.fmt.parseFloat(f64, value[0..end]) catch fallback;
}

fn color(raw: ?[]const u8, fallback: Color) Color {
    const value = raw orelse return fallback;
    if (std.ascii.eqlIgnoreCase(value, "none")) return .{ .r = 0, .g = 0, .b = 0, .a = 0 };
    if (value.len == 4 and value[0] == '#') {
        const r = std.fmt.parseInt(u8, value[1..2], 16) catch return fallback;
        const g = std.fmt.parseInt(u8, value[2..3], 16) catch return fallback;
        const b = std.fmt.parseInt(u8, value[3..4], 16) catch return fallback;
        return .{ .r = r * 17, .g = g * 17, .b = b * 17, .a = 255 };
    }
    if (value.len == 7 and value[0] == '#') {
        const rgb = std.fmt.parseInt(u24, value[1..], 16) catch return fallback;
        return .{ .r = @truncate(rgb >> 16), .g = @truncate(rgb >> 8), .b = @truncate(rgb), .a = 255 };
    }
    if (std.ascii.eqlIgnoreCase(value, "black")) return black;
    if (std.ascii.eqlIgnoreCase(value, "white")) return white;
    if (std.ascii.eqlIgnoreCase(value, "red")) return .{ .r = 255, .g = 0, .b = 0, .a = 255 };
    if (std.ascii.eqlIgnoreCase(value, "green")) return .{ .r = 0, .g = 128, .b = 0, .a = 255 };
    if (std.ascii.eqlIgnoreCase(value, "blue")) return .{ .r = 0, .g = 0, .b = 255, .a = 255 };
    if (std.ascii.eqlIgnoreCase(value, "yellow")) return .{ .r = 255, .g = 255, .b = 0, .a = 255 };
    if (std.ascii.eqlIgnoreCase(value, "gray") or std.ascii.eqlIgnoreCase(value, "grey")) return .{ .r = 128, .g = 128, .b = 128, .a = 255 };
    return fallback;
}

fn paintColor(raw: ?[]const u8, fallback: Color, current: Color) Color {
    if (raw) |value| if (std.ascii.eqlIgnoreCase(value, "currentColor")) return current;
    return color(raw, fallback);
}

fn rgbaPacked(c: Color, opacity: f64) u32 {
    const alpha: u8 = @intFromFloat(@min(255, @max(0, @as(f64, @floatFromInt(c.a)) * opacity)));
    return (@as(u32, c.r) << 24) | (@as(u32, c.g) << 16) | (@as(u32, c.b) << 8) | alpha;
}

fn over(src: u32, dst: u32) u32 {
    const sa = src & 0xff;
    if (sa == 255) return src;
    if (sa == 0) return dst;
    const da = dst & 0xff;
    const oa = sa + (da * (255 - sa) + 127) / 255;
    if (oa == 0) return 0;
    const blend = struct {
        fn one(sc: u8, dc: u8, sa_: u32, da_: u32, oa_: u32) u8 {
            const premul = @as(u32, sc) * sa_ + (@as(u32, dc) * da_ * (255 - sa_) + 127) / 255;
            return @intCast(@min(255, (premul + oa_ / 2) / oa_));
        }
    }.one;
    return (@as(u32, blend(@truncate(src >> 24), @truncate(dst >> 24), sa, da, oa)) << 24) |
        (@as(u32, blend(@truncate(src >> 16), @truncate(dst >> 16), sa, da, oa)) << 16) |
        (@as(u32, blend(@truncate(src >> 8), @truncate(dst >> 8), sa, da, oa)) << 8) | oa;
}

fn put(picture: media.Picture, x: i64, y: i64, px: u32) void {
    if (x < 0 or y < 0 or x >= picture.width or y >= picture.height) return;
    const index: usize = @intCast(y * @as(i64, @intCast(picture.width)) + x);
    picture.pixels[index] = over(px, picture.pixels[index]);
}

fn fillRect(picture: media.Picture, x: i64, y: i64, w: i64, h: i64, px: u32) void {
    if (w <= 0 or h <= 0) return;
    var py = @max(0, y);
    while (py < @min(@as(i64, @intCast(picture.height)), y + h)) : (py += 1) {
        var at = @max(0, x);
        while (at < @min(@as(i64, @intCast(picture.width)), x + w)) : (at += 1) put(picture, at, py, px);
    }
}

fn line(picture: media.Picture, a: Point, b: Point, stroke: u32, width: f64) void {
    var x0: i64 = @intFromFloat(a.x);
    var y0: i64 = @intFromFloat(a.y);
    const x1: i64 = @intFromFloat(b.x);
    const y1: i64 = @intFromFloat(b.y);
    const dx = @as(i64, @intCast(@abs(x1 - x0)));
    const sx: i64 = if (x0 < x1) 1 else -1;
    const dy = -@as(i64, @intCast(@abs(y1 - y0)));
    const sy: i64 = if (y0 < y1) 1 else -1;
    var err = dx + dy;
    const radius: i64 = @intFromFloat(@max(0, (width - 1) / 2));
    while (true) {
        fillRect(picture, x0 - radius, y0 - radius, radius * 2 + 1, radius * 2 + 1, stroke);
        if (x0 == x1 and y0 == y1) break;
        const twice = err * 2;
        if (twice >= dy) {
            err += dy;
            x0 += sx;
        }
        if (twice <= dx) {
            err += dx;
            y0 += sy;
        }
    }
}

fn polygon(picture: media.Picture, points: []const Point, fill: u32, stroke: u32, stroke_width: f64, closed: bool) void {
    if (points.len < 2) return;
    if ((fill & 0xff) != 0 and points.len >= 3) {
        var min_y = points[0].y;
        var max_y = points[0].y;
        for (points) |p| {
            min_y = @min(min_y, p.y);
            max_y = @max(max_y, p.y);
        }
        var ys: i64 = @intFromFloat(@max(0, @floor(min_y)));
        const ye: i64 = @intFromFloat(@min(@as(f64, @floatFromInt(picture.height)), @ceil(max_y)));
        while (ys < ye) : (ys += 1) {
            var intersections: [256]f64 = undefined;
            var n: usize = 0;
            for (points, 0..) |p1, i| {
                const p2 = points[(i + 1) % points.len];
                if ((p1.y <= @as(f64, @floatFromInt(ys)) and p2.y > @as(f64, @floatFromInt(ys))) or (p2.y <= @as(f64, @floatFromInt(ys)) and p1.y > @as(f64, @floatFromInt(ys)))) {
                    if (n < intersections.len) {
                        intersections[n] = p1.x + (@as(f64, @floatFromInt(ys)) - p1.y) * (p2.x - p1.x) / (p2.y - p1.y);
                        n += 1;
                    }
                }
            }
            var i: usize = 0;
            while (i + 1 < n) : (i += 2) {
                var j = i + 1;
                while (j < n) : (j += 1) if (intersections[j] < intersections[i]) {
                    std.mem.swap(f64, &intersections[i], &intersections[j]);
                };
                const x0: i64 = @intFromFloat(@max(0, @ceil(intersections[i])));
                const x1: i64 = @intFromFloat(@min(@as(f64, @floatFromInt(picture.width)), @ceil(intersections[i + 1])));
                fillRect(picture, x0, ys, x1 - x0, 1, fill);
            }
        }
    }
    if ((stroke & 0xff) != 0) {
        for (0..points.len - 1) |i| line(picture, points[i], points[i + 1], stroke, stroke_width);
        if (closed) line(picture, points[points.len - 1], points[0], stroke, stroke_width);
    }
}

fn scaled(x: f64, scale: f64) f64 {
    return x * scale;
}

fn readNumbers(list: []const u8, out: []Point, scale_x: f64, scale_y: f64) usize {
    var i: usize = 0;
    var count: usize = 0;
    while (i < list.len and count < out.len) {
        while (i < list.len and (space(list[i]) or list[i] == ',')) : (i += 1) {}
        if (i == list.len) break;
        const start_x = i;
        while (i < list.len and !space(list[i]) and list[i] != ',') : (i += 1) {}
        const x = std.fmt.parseFloat(f64, list[start_x..i]) catch break;
        while (i < list.len and (space(list[i]) or list[i] == ',')) : (i += 1) {}
        const start_y = i;
        while (i < list.len and !space(list[i]) and list[i] != ',') : (i += 1) {}
        const y = std.fmt.parseFloat(f64, list[start_y..i]) catch break;
        out[count] = .{ .x = scaled(x, scale_x), .y = scaled(y, scale_y) };
        count += 1;
    }
    return count;
}

pub fn rasterize(data: []const u8) ?media.Picture {
    return rasterizeWithColor(data, 0x000000, 1);
}

pub fn rasterizeWithColor(data: []const u8, foreground: u24, css_opacity: f64) ?media.Picture {
    const current: Color = .{ .r = @truncate(foreground >> 16), .g = @truncate(foreground >> 8), .b = @truncate(foreground), .a = 255 };
    if (data.len == 0 or data.len > 256 * 1024) return null;
    const root_start = findIgnoreCase(data, "<svg") orelse return null;
    const root_end = std.mem.indexOfScalarPos(u8, data, root_start, '>') orelse return null;
    const root = data[root_start + 1 .. root_end];
    var width = number(attr(root, "width"), 300);
    var height = number(attr(root, "height"), 150);
    var vb_x: f64 = 0;
    var vb_y: f64 = 0;
    var vb_w = width;
    var vb_h = height;
    if (attr(root, "viewBox")) |view_box| {
        var values: [4]Point = undefined;
        const count = readNumbers(view_box, &values, 1, 1);
        if (count == 2) {
            vb_x = values[0].x;
            vb_y = values[0].y;
            vb_w = values[1].x;
            vb_h = values[1].y;
        }
        if (attr(root, "width") == null) width = vb_w;
        if (attr(root, "height") == null) height = vb_h;
    }
    if (width <= 0 or height <= 0 or vb_w <= 0 or vb_h <= 0) return null;
    const output_width: usize = @intFromFloat(@min(2048, @max(1, @ceil(width))));
    const output_height: usize = @intFromFloat(@min(2048, @max(1, @ceil(height))));
    const picture = media.allocate(output_width, output_height) orelse return null;
    const scale_x = @as(f64, @floatFromInt(output_width)) / vb_w;
    const scale_y = @as(f64, @floatFromInt(output_height)) / vb_h;
    const root_fill = paintColor(attr(root, "fill"), black, current);
    const root_opacity = css_opacity * @min(1, @max(0, number(attr(root, "opacity"), 1)));
    const Path = struct { id: []const u8, data: []const u8, fill: u32, stroke: u32, width: f64 };
    var paths: [32]Path = undefined;
    var path_count: usize = 0;
    var cursor = root_end + 1;
    while (cursor < data.len) {
        const open = std.mem.indexOfScalarPos(u8, data, cursor, '<') orelse break;
        const close = std.mem.indexOfScalarPos(u8, data, open, '>') orelse break;
        const tag = data[open + 1 .. close];
        cursor = close + 1;
        if (tag.len == 0 or tag[0] == '/' or tag[0] == '!' or tag[0] == '?') continue;
        var name_end: usize = 0;
        while (name_end < tag.len and !space(tag[name_end]) and tag[name_end] != '/') : (name_end += 1) {}
        const name = tag[0..name_end];
        const opacity = root_opacity * @min(1, @max(0, number(attr(tag, "opacity"), number(styleValue(tag, "opacity"), 1))));
        const fill_color = paintColor(attr(tag, "fill") orelse styleValue(tag, "fill"), root_fill, current);
        const stroke_color = paintColor(attr(tag, "stroke") orelse styleValue(tag, "stroke"), .{ .r = 0, .g = 0, .b = 0, .a = 0 }, current);
        const fill_px = rgbaPacked(fill_color, opacity);
        const stroke_px = rgbaPacked(stroke_color, opacity);
        const stroke_w = @max(1, number(attr(tag, "stroke-width") orelse styleValue(tag, "stroke-width"), 1) * @min(scale_x, scale_y));
        if (std.ascii.eqlIgnoreCase(name, "rect")) {
            const x = (number(attr(tag, "x"), 0) - vb_x) * scale_x;
            const y = (number(attr(tag, "y"), 0) - vb_y) * scale_y;
            const w = number(attr(tag, "width"), 0) * scale_x;
            const h = number(attr(tag, "height"), 0) * scale_y;
            fillRect(picture, @intFromFloat(x), @intFromFloat(y), @intFromFloat(@max(0, w)), @intFromFloat(@max(0, h)), fill_px);
            if ((stroke_px & 0xff) != 0 and w > 0 and h > 0) {
                line(picture, .{ .x = x, .y = y }, .{ .x = x + w, .y = y }, stroke_px, stroke_w);
                line(picture, .{ .x = x + w, .y = y }, .{ .x = x + w, .y = y + h }, stroke_px, stroke_w);
                line(picture, .{ .x = x + w, .y = y + h }, .{ .x = x, .y = y + h }, stroke_px, stroke_w);
                line(picture, .{ .x = x, .y = y + h }, .{ .x = x, .y = y }, stroke_px, stroke_w);
            }
        } else if (std.ascii.eqlIgnoreCase(name, "circle") or std.ascii.eqlIgnoreCase(name, "ellipse")) {
            const cx = (number(attr(tag, "cx"), 0) - vb_x) * scale_x;
            const cy = (number(attr(tag, "cy"), 0) - vb_y) * scale_y;
            const rx = number(attr(tag, if (std.ascii.eqlIgnoreCase(name, "circle")) "r" else "rx"), 0) * scale_x;
            const ry = number(attr(tag, if (std.ascii.eqlIgnoreCase(name, "circle")) "r" else "ry"), 0) * scale_y;
            var py: i64 = @intFromFloat(@max(0, cy - ry));
            const bottom: i64 = @intFromFloat(@min(@as(f64, @floatFromInt(output_height)), cy + ry));
            while (py < bottom) : (py += 1) {
                const ny = (@as(f64, @floatFromInt(py)) + 0.5 - cy) / @max(0.001, ry);
                const nx = @sqrt(@max(0, 1 - ny * ny)) * rx;
                const left: i64 = @intFromFloat(@max(0, @ceil(cx - nx)));
                const right: i64 = @intFromFloat(@min(@as(f64, @floatFromInt(output_width)), @ceil(cx + nx)));
                fillRect(picture, left, py, right - left, 1, fill_px);
                if ((stroke_px & 0xff) != 0 and nx > 0) {
                    put(picture, left, py, stroke_px);
                    put(picture, right - 1, py, stroke_px);
                }
            }
        } else if (std.ascii.eqlIgnoreCase(name, "line")) {
            line(picture, .{ .x = (number(attr(tag, "x1"), 0) - vb_x) * scale_x, .y = (number(attr(tag, "y1"), 0) - vb_y) * scale_y }, .{ .x = (number(attr(tag, "x2"), 0) - vb_x) * scale_x, .y = (number(attr(tag, "y2"), 0) - vb_y) * scale_y }, stroke_px, stroke_w);
        } else if (std.ascii.eqlIgnoreCase(name, "polygon") or std.ascii.eqlIgnoreCase(name, "polyline")) {
            var points: [256]Point = undefined;
            const count = readNumbers(attr(tag, "points") orelse "", &points, scale_x, scale_y);
            for (points[0..count]) |*point| {
                point.x -= vb_x * scale_x;
                point.y -= vb_y * scale_y;
            }
            polygon(picture, points[0..count], fill_px, stroke_px, stroke_w, std.ascii.eqlIgnoreCase(name, "polygon"));
        } else if (std.ascii.eqlIgnoreCase(name, "path")) {
            const d = attr(tag, "d") orelse continue;
            renderPath(picture, d, fill_px, stroke_px, stroke_w, vb_x, vb_y, scale_x, scale_y);
            if (path_count < paths.len) {
                if (attr(tag, "id")) |id| {
                    paths[path_count] = .{ .id = id, .data = d, .fill = fill_px, .stroke = stroke_px, .width = stroke_w };
                    path_count += 1;
                }
            }
        } else if (std.ascii.eqlIgnoreCase(name, "use")) {
            const href = attr(tag, "href") orelse continue;
            if (href.len < 2 or href[0] != '#') continue;
            for (paths[0..path_count]) |path| {
                if (!std.mem.eql(u8, href[1..], path.id)) continue;
                renderPath(picture, path.data, path.fill, path.stroke, path.width, vb_x - number(attr(tag, "x"), 0), vb_y - number(attr(tag, "y"), 0), scale_x, scale_y);
                break;
            }
        }
    }
    return picture;
}

fn findIgnoreCase(data: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0 or needle.len > data.len) return null;
    var i: usize = 0;
    while (i <= data.len - needle.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(data[i .. i + needle.len], needle)) return i;
    }
    return null;
}

fn renderPath(picture: media.Picture, d: []const u8, fill: u32, stroke: u32, stroke_width: f64, vb_x: f64, vb_y: f64, sx: f64, sy: f64) void {
    var points: [256]Point = undefined;
    var count: usize = 0;
    var i: usize = 0;
    var command: u8 = 0;
    var x: f64 = 0;
    var y: f64 = 0;
    var start = Point{ .x = 0, .y = 0 };
    var closed = false;
    while (i < d.len and count < points.len) {
        while (i < d.len and (space(d[i]) or d[i] == ',')) : (i += 1) {}
        if (i == d.len) break;
        if (std.ascii.isAlphabetic(d[i])) {
            command = d[i];
            i += 1;
            if (command == 'Z' or command == 'z') {
                closed = true;
                x = start.x;
                y = start.y;
                break;
            }
        }
        const relative = command >= 'a' and command <= 'z';
        const upper = std.ascii.toUpper(command);
        if (upper == 'Q') {
            const cx = readPathNumber(d, &i) orelse break;
            const cy = readPathNumber(d, &i) orelse break;
            const end_x = readPathNumber(d, &i) orelse break;
            const end_y = readPathNumber(d, &i) orelse break;
            const control_x = if (relative) x + cx else cx;
            const control_y = if (relative) y + cy else cy;
            const nx = if (relative) x + end_x else end_x;
            const ny = if (relative) y + end_y else end_y;
            for (1..9) |step| {
                if (count == points.len) break;
                const t = @as(f64, @floatFromInt(step)) / 8;
                const u = 1 - t;
                const sample_x = u * u * x + 2 * u * t * control_x + t * t * nx;
                const sample_y = u * u * y + 2 * u * t * control_y + t * t * ny;
                points[count] = pathPoint(sample_x, sample_y, vb_x, vb_y, sx, sy);
                count += 1;
            }
            x = nx;
            y = ny;
            continue;
        }
        if (upper != 'M' and upper != 'L' and upper != 'H' and upper != 'V') break;
        const x0 = readPathNumber(d, &i) orelse break;
        var y0 = y;
        if (upper == 'M' or upper == 'L') y0 = readPathNumber(d, &i) orelse break;
        var nx = x;
        var ny = y;
        if (upper == 'H') nx = if (relative) x + x0 else x0 else if (upper == 'V') ny = if (relative) y + x0 else x0 else {
            nx = if (relative) x + x0 else x0;
            ny = if (relative) y + y0 else y0;
        }
        x = nx;
        y = ny;
        if (upper == 'M' and count != 0) {
            polygon(picture, points[0..count], fill, stroke, stroke_width, false);
            count = 0;
        }
        points[count] = pathPoint(x, y, vb_x, vb_y, sx, sy);
        count += 1;
        if (upper == 'M') {
            start = .{ .x = x, .y = y };
            command = if (relative) 'l' else 'L';
        }
    }
    if (count >= 2) polygon(picture, points[0..count], fill, stroke, stroke_width, closed);
}

fn pathPoint(x: f64, y: f64, vb_x: f64, vb_y: f64, sx: f64, sy: f64) Point {
    return .{ .x = @min(8192, @max(-8192, (x - vb_x) * sx)), .y = @min(8192, @max(-8192, (y - vb_y) * sy)) };
}

fn readPathNumber(data: []const u8, cursor: *usize) ?f64 {
    while (cursor.* < data.len and (space(data[cursor.*]) or data[cursor.*] == ',')) : (cursor.* += 1) {}
    if (cursor.* == data.len) return null;
    const start = cursor.*;
    if (data[cursor.*] == '+' or data[cursor.*] == '-') cursor.* += 1;
    while (cursor.* < data.len and (std.ascii.isDigit(data[cursor.*]) or data[cursor.*] == '.')) : (cursor.* += 1) {}
    if (cursor.* == start) return null;
    return std.fmt.parseFloat(f64, data[start..cursor.*]) catch null;
}

pub fn loadFromDisk(name: []const u8, directory: u32) bool {
    if (!fat32.isMounted() or name.len == 0 or name.len > 63) return false;
    var entries: [32]fat32.Entry = undefined;
    const count = fat32.listDirectory(directory, &entries);
    var size: usize = 0;
    var found = false;
    for (entries[0..count]) |entry| {
        if (entry.name_len != name.len) continue;
        var same = true;
        for (name, 0..) |ch, i| if (std.ascii.toUpper(ch) != std.ascii.toUpper(entry.name[i])) {
            same = false;
            break;
        };
        if (same and (entry.attributes & 0x10) == 0) {
            size = entry.size;
            found = true;
            break;
        }
    }
    if (!found or size == 0 or size > 256 * 1024) return false;
    const pages = (size + 4095) / 4096;
    const data = vm.allocatePages(pages) orelse return false;
    defer for (0..pages) |i| vm.freePage(@intFromPtr(data) + @as(u64, @intCast(i)) * 4096);
    const read = fat32.readFileAt(directory, name, data[0..size]) orelse return false;
    if (read != size) return false;
    const picture = rasterize(data[0..size]) orelse return false;
    media.setSelected(picture, name);
    return true;
}

fn space(ch: u8) bool {
    return ch == ' ' or ch == '\t' or ch == '\r' or ch == '\n';
}
