//! Experimental Arix HTML/CSS backend. Networking, navigation and media
//! retrieval remain owned by the AetherOS browser.
const std = @import("std");
const arix = @import("arix_core");
const strale = @import("strale");
const aether_font = @import("aether_font");

const HtmlParser = arix.html.Parser;
const BufferDeque = arix.utils.buffer_deque.BufferDeque;
const CssBuffer = arix.css.syntax.Buffer;
const CssParser = arix.css.syntax.Parser;
const DisplayList = arix.paint.display.DisplayList;
const Canvas = arix.paint.Canvas;

pub const Raster = struct { pixels: [][3]u8, width: usize, height: usize };
const Failure = enum { none, parser_create, html_buffer, html_tokenize, missing_root, css_parse, css_prepare, style_compute, box_build, layout, display_list, raster_alloc, paint, raster_copy };
var failure: Failure = .none;
var failure_detail: [80]u8 = @splat(0);
var failure_detail_len: usize = 0;

pub fn failureMessage() []const u8 {
    if (failure_detail_len != 0) return failure_detail[0..failure_detail_len];
    return switch (failure) {
        .none => "Arix rendering failed without a stage error",
        .parser_create => "Arix failed to create the HTML parser",
        .html_buffer => "Arix failed to buffer the HTML document",
        .html_tokenize => "Arix failed to tokenize the HTML document",
        .missing_root => "Arix did not produce an HTML document element",
        .css_parse => "Arix failed to parse the combined CSS",
        .css_prepare => "Arix failed to prepare CSS rules",
        .style_compute => "Arix failed to compute document styles",
        .box_build => "Arix failed to build layout boxes",
        .layout => "Arix failed to lay out the page",
        .display_list => "Arix failed to build the display list",
        .raster_alloc => "Arix could not allocate its page raster",
        .paint => "Arix failed to paint the page",
        .raster_copy => "Arix could not return its page raster",
    };
}

pub fn initFont(allocator: std.mem.Allocator) bool {
    return aether_font.init(allocator);
}

pub fn render(allocator: std.mem.Allocator, html: []const u8, css_text: []const u8, width: usize, requested_height: usize) ?Raster {
    failure = .none;
    failure_detail_len = 0;
    if (width == 0 or html.len == 0) return null;
    const height = @min(4096, @max(600, requested_height));
    strale.setGlobalAlloc(allocator);

    const parser = HtmlParser.create(allocator, .{ .tokenizer = .{}, .tree_builder = .{} }) catch {
        failure = .parser_create;
        return null;
    };
    defer parser.destroy();
    var input = BufferDeque(.utf8, .not_atomic, true).init(allocator) catch {
        failure = .html_buffer;
        return null;
    };
    defer input.deinit();
    input.pushBackSlice(html) catch {
        failure = .html_buffer;
        return null;
    };
    parser.tokenizer.step_E(&input) catch {
        failure = .html_tokenize;
        return null;
    };
    const root = parser.tree_builder.document.documentElement() orelse {
        failure = .missing_root;
        return null;
    };

    const ua_css = "html,body,main,header,footer,nav,section,article,aside,div,p,ul,ol,li,table,tr,td,th,form,pre,blockquote,h1,h2,h3,h4,h5,h6{display:block} span,a,strong,b,em,i,small,code,label{display:inline} body{margin:8px;color:#24292f;background:#ffffff;font-family:Inter,Arial,sans-serif;font-size:14px;line-height:1.5} h1{font-size:2em;font-weight:bold;margin:0.67em 0} h2{font-size:1.5em;font-weight:bold;margin:0.83em 0} p{margin:1em 0} a{color:#0969da;text-decoration:underline} ul,ol{padding-left:2em} li{display:list-item} pre,code{font-family:monospace} img{display:inline-block} hr{display:block}\n";
    var combined = std.ArrayList(u8).empty;
    combined.appendSlice(allocator, ua_css) catch {
        failure = .css_parse;
        return null;
    };
    combined.appendSlice(allocator, css_text) catch {
        failure = .css_parse;
        return null;
    };
    var css_buffer = CssBuffer.init(allocator, combined.items) catch {
        failure = .css_parse;
        return null;
    };
    defer css_buffer.deinit();
    var stream = css_buffer.stream(allocator);
    defer stream.deinit();
    var css_parser = CssParser.init(allocator, &stream);
    const stylesheet = css_parser.parseStylesheet() catch {
        failure = .css_parse;
        return null;
    };
    var prepared = arix.style.PreparedStylesheet.init(allocator, &stylesheet, .author) catch {
        failure = .css_prepare;
        return null;
    };
    defer prepared.deinit(allocator);

    const context: arix.style.computed.ComputedStyle.Context = .{
        .font_size = 14,
        .root_font_size = 14,
        .x_height = 7,
        .zero_advance = 7,
        .viewport_width = @floatFromInt(width),
        .viewport_height = @floatFromInt(height),
    };
    const styled = arix.style.StyledNode.build(allocator, root, &.{prepared}, &context) catch {
        failure = .style_compute;
        return null;
    };
    defer styled.destroy(allocator);
    var boxes = arix.layout.BoxTree.build(allocator, styled) catch {
        failure = .box_build;
        return null;
    };
    defer boxes.destroy(allocator);
    const fallback_families = [_][]const u8{"Inter"};
    const layout_options: arix.layout.Options = .{ .font_matcher = .{ .fallback_families = &fallback_families } };
    var fragments = boxes.layoutWithOptions(allocator, context.viewport_width, context.viewport_height, layout_options) catch |err| {
        failure = .layout;
        if (std.fmt.bufPrint(&failure_detail, "Arix layout error: {s}", .{@errorName(err)})) |message| {
            failure_detail_len = message.len;
        } else |_| {}
        return null;
    };
    defer fragments.destroy(allocator);
    var list = DisplayList.build(allocator, &fragments) catch {
        failure = .display_list;
        return null;
    };
    defer list.deinit(allocator);
    var canvas = Canvas.init(allocator, width, height, .{ .clear_color = .{ 255, 255, 255 } }) catch {
        failure = .raster_alloc;
        return null;
    };
    defer canvas.deinit(allocator);
    canvas.draw(allocator, &list) catch |err| {
        failure = .paint;
        if (std.fmt.bufPrint(&failure_detail, "Arix paint error: {s}", .{@errorName(err)})) |message| {
            failure_detail_len = message.len;
        } else |_| {}
        return null;
    };
    const pixels = allocator.dupe([3]u8, canvas.pixels) catch {
        failure = .raster_copy;
        return null;
    };
    return .{ .pixels = pixels, .width = width, .height = height };
}
