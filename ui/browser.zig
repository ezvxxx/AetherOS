//! Bounded HTTP browser with a graphical HTML flow, CSS box styling and media.
const std = @import("std");
const s = @import("../system/state.zig");
const canvas = @import("../graphics/canvas.zig");
const font = @import("../graphics/font.zig");
const dns = @import("../network/dns.zig");
const net = @import("../network/stack.zig");
const tls = @import("../network/tls.zig");
const e1000 = @import("../drivers/e1000.zig");
const rtc = @import("../drivers/rtc.zig");
const heap = @import("../memory/heap.zig");
const panic_report = @import("../system/panic.zig");
const css = @import("css.zig");
const svg = @import("../graphics/svg.zig");
const media = @import("../graphics/media.zig");
const fat32 = @import("../fs/storage.zig");
const raster_image = @import("../graphics/image.zig");
const arix_renderer = @import("arix_renderer");

const https_enabled = true;
const use_arix_renderer = true;
const default_scheme = "http://";
const default_port: u16 = 80;
const max_url = 320;
pub const tab_capacity = 4;
const max_response = 64 * 1024 * 1024;
const max_resource_response = 1024 * 1024;
const max_page_response = 1024 * 1024;
const max_page = 16384;
const max_inline_images = 16;
const max_block_boxes = 256;
const max_links = 48;
const max_arix_css = 256 * 1024;
const max_network_spins: usize = 250_000;
const ca_pem = @embedFile("../network/cacert.pem");

const Url = struct {
    secure: bool = false,
    host: [254]u8 = @splat(0),
    host_len: usize = 0,
    port: u16 = 80,
    path: [512]u8 = @splat(0),
    path_len: usize = 1,
    text: [max_url]u8 = @splat(0),
    text_len: usize = 0,
};
const Link = struct { url: [max_url]u8 = @splat(0), url_len: usize = 0, line: usize = 0, valid: bool = false };
const BrowserTab = struct {
    url: [max_url]u8 = @splat(0),
    url_len: usize = 0,
    title: [128]u8 = @splat(0),
    title_len: usize = 0,
    history: [12][max_url]u8 = @splat(@splat(0)),
    history_lens: [12]usize = @splat(0),
    history_count: usize = 0,
    history_pos: usize = 0,
};
const Download = struct { name: [96]u8 = @splat(0), name_len: usize = 0, url: [max_url]u8 = @splat(0), url_len: usize = 0, size: usize = 0 };
const Meta = struct {
    status: u16 = 0,
    body_start: usize = 0,
    content_length: ?usize = null,
    chunked: bool = false,
    html: bool = true,
    plain: bool = false,
    compressed: bool = false,
    content_type_seen: bool = false,
    attachment: bool = false,
    filename: [96]u8 = @splat(0),
    filename_len: usize = 0,
    location: [max_url]u8 = @splat(0),
    location_len: usize = 0,
};
const BlockBox = struct {
    start_line: usize = 0,
    end_line: usize = 0,
    style: css.Computed = .{},
    image_id: ?u8 = null,
};

var address: [max_url]u8 = @splat(0);
var address_len: usize = 0;
var address_cursor: usize = 0;
var address_focused = false;
var select_address = false;
var page: [max_page]u8 = @splat(0);
var page_colors: [max_page]u24 = @splat(0);
var page_backgrounds: [max_page]u24 = @splat(0);
var page_box_backgrounds: [max_page]u24 = @splat(0);
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
var page_title: [128]u8 = @splat(0);
var page_title_len: usize = 0;
var message: [128]u8 = @splat(0);
var message_len: usize = 0;
var links: [max_links]Link = @splat(.{});
var link_count: usize = 0;
var history: [12][max_url]u8 = @splat(@splat(0));
var history_lens: [12]usize = @splat(0);
var history_count: usize = 0;
var history_pos: usize = 0;
var browser_tabs: [tab_capacity]BrowserTab = @splat(.{});
var browser_tab_count: usize = 1;
var active_browser_tab: usize = 0;
var history_panel = false;
var downloads_panel = false;
var downloads: [8]Download = @splat(.{});
var download_count: usize = 0;
var response: [max_response]u8 = undefined;
var body_buffer: [max_page_response]u8 = undefined;
// Resource fetches can happen while renderHtml is still reading body_buffer.
// Keep CSS, image, and download bodies separate so fetching a stylesheet does
// not replace the HTML currently being rendered.
var resource_body_buffer: [max_resource_response]u8 = undefined;
var trust_bundle: std.crypto.Certificate.Bundle = .empty;
var trust_ready = false;
var trust_lock: std.Io.RwLock = .init;
var rendering_style: css.Computed = .{};
var flow_style: css.Computed = .{};
var flow_indent: usize = 0;
var flow_right_inset: usize = 0;
var flow_font_scale: usize = 1;
var flow_align_start: usize = 0;
var flow_align_width: usize = 0;
var expanded_html: [max_page]u8 = undefined;
var inline_images: [max_inline_images]?media.Picture = @splat(null);
var arix_rendered = false;
var arix_css_buffer: [max_arix_css]u8 = undefined;
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
    arix_rendered = false;
}

fn storeInlineImage(picture: media.Picture) ?u8 {
    for (inline_images, 0..) |image, image_index| if (image == null) {
        inline_images[image_index] = picture;
        return @intCast(image_index);
    };
    media.release(picture);
    return null;
}

fn fetchCssImage(reference: css.ImageUrl) ?u8 {
    const base = parseUrl(address[0..address_len]) orelse return null;
    var resolved: [max_url]u8 = undefined;
    const length = resolveLink(base, reference.value[0..reference.len], &resolved) orelse return null;
    const picture = fetchImage(resolved[0..length]) orelse return null;
    return storeInlineImage(picture);
}

fn setMessage(text: []const u8) void {
    message_len = @min(text.len, message.len);
    @memcpy(message[0..message_len], text[0..message_len]);
}

fn equalIgnoreCase(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

fn startsIgnoreCase(value: []const u8, prefix: []const u8) bool {
    return value.len >= prefix.len and equalIgnoreCase(value[0..prefix.len], prefix);
}

fn serviceNetwork() void {
    e1000.poll(net.onEthernetFrame);
    net.poll();
    dns.poll();
}

fn copyUrl(url: []const u8) bool {
    if (url.len == 0 or url.len > address.len) return false;
    address = @splat(0);
    @memcpy(address[0..url.len], url);
    address_len = url.len;
    address_cursor = url.len;
    return true;
}

fn saveBrowserTab() void {
    if (active_browser_tab >= browser_tab_count) return;
    browser_tabs[active_browser_tab] = .{
        .url = address,
        .url_len = address_len,
        .title = page_title,
        .title_len = page_title_len,
        .history = history,
        .history_lens = history_lens,
        .history_count = history_count,
        .history_pos = history_pos,
    };
}

fn restoreBrowserTab(index: usize) void {
    active_browser_tab = index;
    const tab = browser_tabs[index];
    address = tab.url;
    address_len = tab.url_len;
    address_cursor = address_len;
    page_title = tab.title;
    page_title_len = tab.title_len;
    history = tab.history;
    history_lens = tab.history_lens;
    history_count = tab.history_count;
    history_pos = tab.history_pos;
    address_focused = false;
    select_address = false;
}

fn clearCurrentPage() void {
    clearInlineImages();
    page = @splat(0);
    page_len = 0;
    page_lines = 0;
    page_scroll = 0;
    link_count = 0;
    page_title = @splat(0);
    page_title_len = 0;
    history_panel = false;
    downloads_panel = false;
}

pub fn newTab() bool {
    saveBrowserTab();
    if (browser_tab_count == browser_tabs.len) return false;
    browser_tab_count += 1;
    active_browser_tab = browser_tab_count - 1;
    browser_tabs[active_browser_tab] = .{};
    history = @splat(@splat(0));
    history_lens = @splat(0);
    history_count = 0;
    history_pos = 0;
    address = @splat(0);
    address_len = 0;
    address_cursor = 0;
    clearCurrentPage();
    setMessage("New browser tab");
    return true;
}

pub fn switchTab(index: usize) bool {
    if (index >= browser_tab_count) return false;
    if (index == active_browser_tab) return true;
    saveBrowserTab();
    restoreBrowserTab(index);
    clearCurrentPage();
    if (address_len != 0) navigate(address[0..address_len], false) else setMessage("New browser tab");
    return true;
}

pub fn closeTab(index: usize) bool {
    if (index >= browser_tab_count or browser_tab_count <= 1) return false;
    saveBrowserTab();
    for (index..browser_tab_count - 1) |i| browser_tabs[i] = browser_tabs[i + 1];
    browser_tab_count -= 1;
    const next = if (active_browser_tab > index) active_browser_tab - 1 else if (active_browser_tab == index) @min(index, browser_tab_count - 1) else active_browser_tab;
    restoreBrowserTab(next);
    clearCurrentPage();
    if (address_len != 0) navigate(address[0..address_len], false) else setMessage("New browser tab");
    return true;
}

pub fn tabCount() usize { return browser_tab_count; }
pub fn activeTab() usize { return active_browser_tab; }
pub fn tabTitle(index: usize) []const u8 {
    if (index >= browser_tab_count) return "";
    const tab = if (index == active_browser_tab) BrowserTab{ .title = page_title, .title_len = page_title_len, .url = address, .url_len = address_len } else browser_tabs[index];
    if (tab.title_len != 0) return tab.title[0..tab.title_len];
    if (tab.url_len == 0) return "New Tab";
    return tab.url[0..tab.url_len];
}

fn append(out: []u8, used: *usize, value: []const u8) bool {
    if (value.len > out.len -| used.*) return false;
    @memcpy(out[used.*..][0..value.len], value);
    used.* += value.len;
    return true;
}

fn parseUrl(raw: []const u8) ?Url {
    if (raw.len == 0 or raw.len > max_url) return null;
    var parsed = Url{ .secure = false, .port = default_port };
    var input = raw;
    if (startsIgnoreCase(input, "https://")) {
        if (!https_enabled) return null;
        parsed.secure = true;
        parsed.port = 443;
        input = input[8..];
    } else if (startsIgnoreCase(input, "http://")) {
        parsed.secure = false;
        parsed.port = 80;
        input = input[7..];
    }
    var authority_end: usize = input.len;
    for (input, 0..) |ch, i| if (ch == '/' or ch == '?' or ch == '#') {
        authority_end = i;
        break;
    };
    const authority = input[0..authority_end];
    if (authority.len == 0 or authority.len > parsed.host.len or std.mem.indexOfScalar(u8, authority, '@') != null) return null;
    var host = authority;
    if (std.mem.lastIndexOfScalar(u8, authority, ':')) |colon| {
        if (std.mem.indexOfScalar(u8, authority, ':') != colon) return null; // IPv6 literals are not implemented.
        host = authority[0..colon];
        const port_text = authority[colon + 1 ..];
        if (port_text.len == 0) return null;
        var port: u32 = 0;
        for (port_text) |ch| {
            if (ch < '0' or ch > '9') return null;
            port = port * 10 + ch - '0';
            if (port > 65535) return null;
        }
        if (port == 0) return null;
        parsed.port = @intCast(port);
    }
    if (host.len == 0 or host.len > 253) return null;
    for (host, 0..) |ch, i| {
        const lower = std.ascii.toLower(ch);
        if (!((lower >= 'a' and lower <= 'z') or (lower >= '0' and lower <= '9') or lower == '-' or lower == '.')) return null;
        parsed.host[i] = lower;
    }
    parsed.host_len = host.len;
    const tail = input[authority_end..];
    var path_start: usize = 0;
    while (path_start < tail.len and tail[path_start] != '#') : (path_start += 1) {}
    const path = tail[0..path_start];
    if (path.len == 0) {
        parsed.path[0] = '/';
        parsed.path_len = 1;
    } else if (path[0] == '?') {
        parsed.path[0] = '/';
        @memcpy(parsed.path[1..][0..path.len], path);
        parsed.path_len = path.len + 1;
    } else {
        if (path.len > parsed.path.len) return null;
        @memcpy(parsed.path[0..path.len], path);
        parsed.path_len = path.len;
    }
    var used: usize = 0;
    if (!append(&parsed.text, &used, if (parsed.secure) "https://" else "http://")) return null;
    if (!append(&parsed.text, &used, parsed.host[0..parsed.host_len])) return null;
    if ((parsed.secure and parsed.port != 443) or (!parsed.secure and parsed.port != 80)) {
        var port_text: [5]u8 = undefined;
        const printed = std.fmt.bufPrint(&port_text, "{d}", .{parsed.port}) catch return null;
        if (!append(&parsed.text, &used, ":") or !append(&parsed.text, &used, printed)) return null;
    }
    if (!append(&parsed.text, &used, parsed.path[0..parsed.path_len])) return null;
    parsed.text_len = used;
    return parsed;
}

fn normalizeInput() ?[]const u8 {
    var raw = std.mem.trim(u8, address[0..address_len], " \t\r\n");
    if (raw.len == 0) return null;
    if (std.mem.indexOf(u8, raw, "://") != null) return raw;
    if (equalIgnoreCase(raw, "google")) raw = "www.google.com";
    if (equalIgnoreCase(raw, "youtube")) raw = "www.youtube.com";
    if (equalIgnoreCase(raw, "tiktok")) raw = "www.tiktok.com";
    if (std.mem.indexOfScalar(u8, raw, ' ') != null or std.mem.indexOfScalar(u8, raw, '.') == null) {
        var search: [max_url]u8 = @splat(0);
        var used: usize = 0;
        if (!append(&search, &used, default_scheme) or !append(&search, &used, "www.google.com/search?gbv=1&q=")) return null;
        for (raw) |ch| {
            if (ch == ' ') {
                if (!append(&search, &used, "+")) return null;
            } else if ((ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or (ch >= '0' and ch <= '9') or ch == '-' or ch == '_' or ch == '.') {
                if (!append(&search, &used, &.{ch})) return null;
            } else {
                const encoded = [_]u8{ '%', "0123456789ABCDEF"[ch >> 4], "0123456789ABCDEF"[ch & 15] };
                if (!append(&search, &used, &encoded)) return null;
            }
        }
        _ = copyUrl(search[0..used]);
        return address[0..address_len];
    }
    var normalized: [max_url]u8 = @splat(0);
    var used: usize = 0;
    if (!append(&normalized, &used, default_scheme) or !append(&normalized, &used, raw)) return null;
    _ = copyUrl(normalized[0..used]);
    return address[0..address_len];
}

fn addHistory(url: []const u8) void {
    if (history_count != 0 and history_pos + 1 == history_count and history_lens[history_pos] == url.len and std.mem.eql(u8, history[history_pos][0..url.len], url)) return;
    if (history_count != 0 and history_pos + 1 < history_count) history_count = history_pos + 1;
    if (history_count == history.len) {
        for (1..history.len) |i| {
            history[i - 1] = history[i];
            history_lens[i - 1] = history_lens[i];
        }
        history_count -= 1;
    }
    @memcpy(history[history_count][0..url.len], url);
    history_lens[history_count] = url.len;
    history_count += 1;
    history_pos = history_count - 1;
}

fn ensureTrust() bool {
    if (trust_ready) return true;
    const now = if (s.clock_valid) s.clock_unix_seconds else blk: {
        _ = rtc.updateClock();
        break :blk s.clock_unix_seconds;
    };
    if (now < 1_600_000_000) {
        setMessage("System clock is unavailable; HTTPS certificate checks cannot run.");
        return false;
    }
    _ = tls.appendPemBundle(&trust_bundle, heap.allocator(), ca_pem, now) catch {
        panic_report.trace("HTTPS: failed to parse the embedded CA bundle");
        setMessage("Could not load the built-in trusted certificate roots.");
        return false;
    };
    trust_ready = true;
    return true;
}

fn makeRequest(url: Url, out: *[1024]u8) ?usize {
    var used: usize = 0;
    if (!append(out, &used, "GET ") or !append(out, &used, url.path[0..url.path_len]) or !append(out, &used, " HTTP/1.1\r\nHost: ") or !append(out, &used, url.host[0..url.host_len])) return null;
    if ((url.secure and url.port != 443) or (!url.secure and url.port != 80)) {
        var port_text: [5]u8 = undefined;
        const printed = std.fmt.bufPrint(&port_text, ":{d}", .{url.port}) catch return null;
        if (!append(out, &used, printed)) return null;
    }
    if (!append(out, &used, "\r\nUser-Agent: AetherOS/0.1\r\nAccept: text/html,text/plain;q=0.9,*/*;q=0.1\r\nAccept-Encoding: identity\r\nConnection: close\r\n\r\n")) return null;
    return used;
}

fn parseMeta(bytes: []const u8) ?Meta {
    const header_end = std.mem.indexOf(u8, bytes, "\r\n\r\n") orelse return null;
    var meta = Meta{ .body_start = header_end + 4 };
    const first_end = std.mem.indexOf(u8, bytes[0..header_end], "\r\n") orelse header_end;
    const first = bytes[0..first_end];
    if (!startsIgnoreCase(first, "HTTP/")) return null;
    if (first.len >= 12 and first[9] >= '0' and first[9] <= '9' and first[10] >= '0' and first[10] <= '9' and first[11] >= '0' and first[11] <= '9') {
        meta.status = @as(u16, first[9] - '0') * 100 + @as(u16, first[10] - '0') * 10 + first[11] - '0';
    }
    var cursor = first_end + (if (first_end < header_end) @as(usize, 2) else 0);
    while (cursor < header_end) {
        const rel_end = std.mem.indexOf(u8, bytes[cursor..header_end], "\r\n") orelse header_end - cursor;
        const line = bytes[cursor .. cursor + rel_end];
        cursor += rel_end + (if (cursor + rel_end < header_end) @as(usize, 2) else 0);
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = line[0..colon];
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (equalIgnoreCase(name, "content-length")) {
            var number: usize = 0;
            for (value) |ch| {
                if (ch < '0' or ch > '9') return null;
                const digit: usize = ch - '0';
                if (number > (std.math.maxInt(usize) - digit) / 10) return null;
                number = number * 10 + digit;
            }
            meta.content_length = number;
        } else if (equalIgnoreCase(name, "transfer-encoding")) {
            meta.chunked = std.mem.indexOf(u8, value, "chunked") != null;
        } else if (equalIgnoreCase(name, "content-type")) {
            meta.content_type_seen = true;
            meta.html = startsIgnoreCase(value, "text/html") or startsIgnoreCase(value, "application/xhtml+xml");
            meta.plain = startsIgnoreCase(value, "text/plain");
        } else if (equalIgnoreCase(name, "content-disposition")) {
            meta.attachment = startsIgnoreCase(value, "attachment");
            if (findIgnoreCase(value, "filename=", 0)) |filename_at| {
                var filename = std.mem.trim(u8, value[filename_at + 9 ..], " \t");
                if (filename.len != 0 and filename[0] == '"') {
                    filename = filename[1..];
                    if (std.mem.indexOfScalar(u8, filename, '"')) |end| filename = filename[0..end];
                } else if (std.mem.indexOfScalar(u8, filename, ';')) |end| {
                    filename = std.mem.trimEnd(u8, filename[0..end], " \t");
                }
                meta.filename_len = @min(filename.len, meta.filename.len);
                @memcpy(meta.filename[0..meta.filename_len], filename[0..meta.filename_len]);
            }
        } else if (equalIgnoreCase(name, "content-encoding")) {
            meta.compressed = !equalIgnoreCase(value, "identity");
        } else if (equalIgnoreCase(name, "location")) {
            meta.location_len = @min(value.len, meta.location.len);
            @memcpy(meta.location[0..meta.location_len], value[0..meta.location_len]);
        }
    }
    return meta;
}

fn responseComplete(bytes: []const u8) bool {
    const meta = parseMeta(bytes) orelse return false;
    if (meta.content_length) |length| return meta.body_start <= bytes.len and length <= bytes.len - meta.body_start;
    if (meta.chunked and std.mem.indexOf(u8, bytes[meta.body_start..], "\r\n0\r\n\r\n") != null) return true;
    return false;
}

fn collectResponse(socket: u8, secure: bool, host: []const u8, request: []const u8) usize {
    var response_len: usize = 0;
    if (secure) {
        panic_report.trace("TLS: starting verified handshake");
        if (!ensureTrust()) return 0;
        const timestamp = std.Io.Timestamp.fromNanoseconds(@as(i96, s.clock_unix_seconds) * 1_000_000_000);
        tls.connect(0, socket, host, .{
            .bundle = .{
                .gpa = heap.allocator(),
                // Certificate verification runs synchronously on the single kernel
                // thread. The lock is uncontended, but it still requires a valid
                // Io value for its slow path and unlock operations.
                .io = std.Io.failing,
                .lock = &trust_lock,
                .bundle = &trust_bundle,
            },
        }, timestamp) catch |err| {
            panic_report.trace(@errorName(err));
            var detail: [message.len]u8 = undefined;
            const explanation = std.fmt.bufPrint(&detail, "HTTPS failed: {s}", .{@errorName(err)}) catch "HTTPS handshake failed.";
            setMessage(explanation);
            net.tcpClose(socket);
            return 0;
        };
        panic_report.trace("TLS: handshake complete");
        const writer = tls.writer(0) orelse return 0;
        panic_report.trace("TLS: writing HTTP request");
        writer.writeAll(request) catch {
            setMessage("Could not send the HTTPS request.");
            tls.end(0);
            return 0;
        };
        panic_report.trace("TLS: HTTP request buffered");
        writer.flush() catch {
            setMessage("Could not finish sending the HTTPS request.");
            tls.end(0);
            return 0;
        };
        tls.flushTransport(0) catch {
            setMessage("Could not send the HTTPS request over TCP.");
            tls.end(0);
            return 0;
        };
        panic_report.trace("TLS: HTTP request sent; waiting for response");
        const reader = tls.reader(0) orelse return 0;
        var spins: usize = 0;
        while (response_len < response.len and spins < max_network_spins) : (spins += 1) {
            if (reader.bufferedLen() != 0) {
                const available = @min(reader.bufferedLen(), response.len - response_len);
                var buffers = [_][]u8{response[response_len..][0..available]};
                const amount = reader.readVec(&buffers) catch |err| {
                    panic_report.trace(@errorName(err));
                    break;
                };
                if (amount == 0) break;
                response_len += amount;
            } else {
                // A one-byte blocking read preserves a short final TLS record
                // if the peer closes without sending close_notify.
                var byte: [1]u8 = undefined;
                const amount = reader.readSliceShort(&byte) catch |err| {
                    panic_report.trace(@errorName(err));
                    break;
                };
                if (amount == 0) break;
                response[response_len] = byte[0];
                response_len += 1;
            }
            if (responseComplete(response[0..response_len])) break;
        }
        if (spins >= max_network_spins and !responseComplete(response[0..response_len]))
            panic_report.trace("TLS: read spin budget ended");
        tls.end(0);
    } else {
        if (!net.tcpSend(socket, request)) {
            setMessage("Could not queue the HTTP request.");
            net.tcpClose(socket);
            return 0;
        }
        const deadline = s.uptime() + 1500;
        var spins: usize = 0;
        while (s.uptime() < deadline and response_len < response.len and spins < max_network_spins) : (spins += 1) {
            serviceNetwork();
            if (net.tcpReceive(socket, response[response_len..])) |length| {
                response_len += length;
                if (responseComplete(response[0..response_len])) break;
            } else if (net.tcpPeerClosed(socket)) break else asm volatile ("hlt");
        }
        net.tcpClose(socket);
    }
    return response_len;
}

fn decodeChunks(input: []const u8, out: []u8) ?usize {
    var cursor: usize = 0;
    var used: usize = 0;
    while (cursor < input.len) {
        const line_end = std.mem.indexOf(u8, input[cursor..], "\r\n") orelse return null;
        const size_text = input[cursor .. cursor + line_end];
        var size: usize = 0;
        for (size_text) |ch| {
            if (ch == ';') break;
            const nibble = if (ch >= '0' and ch <= '9') ch - '0' else if (std.ascii.toLower(ch) >= 'a' and std.ascii.toLower(ch) <= 'f') std.ascii.toLower(ch) - 'a' + 10 else return null;
            size = size * 16 + nibble;
            if (size > out.len) return null;
        }
        cursor += line_end + 2;
        if (size == 0) return used;
        if (size > input.len -| cursor or used + size > out.len) return null;
        @memcpy(out[used..][0..size], input[cursor..][0..size]);
        used += size;
        cursor += size;
        if (cursor + 2 > input.len or !std.mem.eql(u8, input[cursor..][0..2], "\r\n")) return null;
        cursor += 2;
    }
    return null;
}

/// Decode HTTP chunk framing in place. Output always trails input, so a
/// forward byte copy safely compacts the body without another 64 MiB buffer.
fn decodeChunksInPlace(buffer: []u8) ?usize {
    var cursor: usize = 0;
    var used: usize = 0;
    while (cursor < buffer.len) {
        const line_end = std.mem.indexOf(u8, buffer[cursor..], "\r\n") orelse return null;
        const size_text = buffer[cursor .. cursor + line_end];
        var size: usize = 0;
        var digits: usize = 0;
        for (size_text) |ch| {
            if (ch == ';') break;
            const lower = std.ascii.toLower(ch);
            const nibble: usize = if (lower >= '0' and lower <= '9') lower - '0' else if (lower >= 'a' and lower <= 'f') lower - 'a' + 10 else return null;
            if (size > (buffer.len -| nibble) / 16) return null;
            size = size * 16 + nibble;
            digits += 1;
        }
        if (digits == 0) return null;
        cursor += line_end + 2;
        if (size == 0) return used;
        if (size > buffer.len -| cursor or size > buffer.len -| used) return null;
        for (0..size) |i| buffer[used + i] = buffer[cursor + i];
        used += size;
        cursor += size;
        if (cursor + 2 > buffer.len or !std.mem.eql(u8, buffer[cursor..][0..2], "\r\n")) return null;
        cursor += 2;
    }
    return null;
}

fn resolveRedirect(base: Url, location: []const u8, out: *[max_url]u8) ?[]const u8 {
    if (std.mem.indexOf(u8, location, "://") != null) {
        if (location.len > out.len) return null;
        @memcpy(out[0..location.len], location);
        return out[0..location.len];
    }
    var used: usize = 0;
    if (location.len >= 2 and location[0] == '/' and location[1] == '/') {
        if (!append(out, &used, if (base.secure) "https:" else "http:") or !append(out, &used, location)) return null;
        return out[0..used];
    }
    if (!append(out, &used, if (base.secure) "https://" else "http://") or !append(out, &used, base.host[0..base.host_len])) return null;
    if ((base.secure and base.port != 443) or (!base.secure and base.port != 80)) {
        var port_text: [6]u8 = undefined;
        const printed = std.fmt.bufPrint(&port_text, ":{d}", .{base.port}) catch return null;
        if (!append(out, &used, printed)) return null;
    }
    if (location.len != 0 and location[0] == '/') {
        if (!append(out, &used, location)) return null;
    } else {
        const path = base.path[0..base.path_len];
        const last_slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse 0;
        if (!append(out, &used, path[0 .. last_slash + 1]) or !append(out, &used, location)) return null;
    }
    return out[0..used];
}

fn loadOnce(url: *Url) bool {
    panic_report.trace("browser: DNS start");
    setMessage("Resolving host...");
    if (!dns.start(url.host[0..url.host_len])) {
        setMessage("DNS could not start. Check Ethernet and DHCP.");
        return false;
    }
    panic_report.trace("browser: DNS wait");
    const dns_deadline = s.uptime() + 1200;
    var dns_spins: usize = 0;
    while (dns.status() == .pending and s.uptime() < dns_deadline and dns_spins < max_network_spins) : (dns_spins += 1) {
        serviceNetwork();
        asm volatile ("hlt");
    }
    if (dns.status() == .pending) {
        panic_report.trace("browser: DNS timed out");
        setMessage("DNS timed out. Check Ethernet and DHCP.");
        return false;
    }
    const ip = dns.address() orelse {
        setMessage("Host lookup failed. Check the network connection.");
        return false;
    };
    panic_report.trace("browser: DNS resolved; TCP connect start");
    setMessage("Connecting...");
    const socket = net.tcpOpen(0) orelse {
        setMessage("No TCP socket is available.");
        return false;
    };
    if (!net.tcpConnect(socket, ip, url.port)) {
        net.tcpClose(socket);
        setMessage("Could not start the TCP connection.");
        return false;
    }
    const connect_deadline = s.uptime() + 1500;
    var connect_spins: usize = 0;
    while (!net.tcpConnected(socket) and net.tcpError(socket) == null and s.uptime() < connect_deadline and connect_spins < max_network_spins) : (connect_spins += 1) {
        serviceNetwork();
        asm volatile ("hlt");
    }
    if (!net.tcpConnected(socket)) {
        panic_report.trace("browser: TCP connect timed out");
        setMessage("TCP connection timed out or was refused.");
        net.tcpClose(socket);
        return false;
    }
    var request: [1024]u8 = undefined;
    const request_len = makeRequest(url.*, &request) orelse {
        setMessage("The URL is too long to request.");
        net.tcpClose(socket);
        return false;
    };
    panic_report.trace("browser: TCP connected; request send");
    setMessage(if (url.secure) "Establishing verified HTTPS..." else "Loading page...");
    const length = collectResponse(socket, url.secure, url.host[0..url.host_len], request[0..request_len]);
    panic_report.trace("browser: response collection finished");
    if (length == 0) panic_report.trace("browser: response was empty");
    if (length == 0) return false;
    const meta = parseMeta(response[0..length]) orelse {
        panic_report.trace("browser: response headers were invalid");
        setMessage("The server returned an invalid HTTP response.");
        return false;
    };
    var response_info: [128]u8 = undefined;
    const response_info_text = std.fmt.bufPrint(&response_info, "browser: HTTP {d} {s}", .{ meta.status, url.text[0..url.text_len] }) catch "browser: response headers parsed";
    panic_report.trace(response_info_text);
    if (meta.status >= 300 and meta.status < 400 and meta.location_len != 0) {
        var redirected: [max_url]u8 = undefined;
        const next = resolveRedirect(url.*, meta.location[0..meta.location_len], &redirected) orelse {
            setMessage("The redirect URL is not supported.");
            return false;
        };
        url.* = parseUrl(next) orelse {
            setMessage("The redirect destination is invalid or unsupported.");
            return false;
        };
        return true;
    }
    if (meta.status < 200 or meta.status >= 300) {
        setMessage("The website returned an HTTP error.");
        return false;
    }
    if (meta.compressed) {
        setMessage("The site sent compressed content; decompression is not supported yet.");
        return false;
    }
    if (meta.body_start > length) return false;
    const raw_body = response[meta.body_start..length];
    const should_download = meta.attachment or
        (meta.content_type_seen and !meta.html and !meta.plain) or
        (urlLooksLikeFile(url.*) and !(meta.content_type_seen and meta.html));
    if (should_download) {
        _ = receiveDownload(url.*, meta, raw_body);
        return false;
    }
    if (!meta.html and !meta.plain) {
        setMessage("This response is not HTML or plain text.");
        return false;
    }
    panic_report.trace("browser: rendering response body");
    var body_len: usize = 0;
    var partial = false;
    if (meta.chunked) {
        body_len = decodeChunks(raw_body, &body_buffer) orelse {
            setMessage("The server sent an unsupported chunked response.");
            return false;
        };
    } else {
        body_len = @min(raw_body.len, body_buffer.len);
        @memcpy(body_buffer[0..body_len], raw_body[0..body_len]);
        if (meta.content_length) |expected| partial = expected > body_len;
    }
    const width = if (isActive()) s.windows[@intCast(s.active_window)].w else @min(860, s.fb.width -| 24);
    const columns: usize = @intCast(@max(30, (width -| 36) / 6));
    if (meta.plain) renderPlain(body_buffer[0..body_len], columns) else renderHtml(body_buffer[0..body_len], columns);
    panic_report.trace("browser: response body rendered");
    setMessage(if (partial) "Page is truncated; rendering supported HTML, CSS and media." else "Page rendered. JavaScript is disabled.");
    return false;
}

fn fetchResource(url_text: []const u8) ?[]const u8 {
    const url = parseUrl(url_text) orelse return null;
    if (!dns.start(url.host[0..url.host_len])) return null;
    const dns_deadline = s.uptime() + 1200;
    var spins: usize = 0;
    while (dns.status() == .pending and s.uptime() < dns_deadline and spins < max_network_spins) : (spins += 1) {
        serviceNetwork();
        asm volatile ("hlt");
    }
    const ip = dns.address() orelse return null;
    const socket = net.tcpOpen(0) orelse return null;
    if (!net.tcpConnect(socket, ip, url.port)) {
        net.tcpClose(socket);
        return null;
    }
    const connect_deadline = s.uptime() + 1500;
    spins = 0;
    while (!net.tcpConnected(socket) and net.tcpError(socket) == null and s.uptime() < connect_deadline and spins < max_network_spins) : (spins += 1) {
        serviceNetwork();
        asm volatile ("hlt");
    }
    if (!net.tcpConnected(socket)) {
        net.tcpClose(socket);
        return null;
    }
    var request: [1024]u8 = undefined;
    const request_len = makeRequest(url, &request) orelse {
        net.tcpClose(socket);
        return null;
    };
    const response_len = collectResponse(socket, url.secure, url.host[0..url.host_len], request[0..request_len]);
    if (response_len == 0) return null;
    const meta = parseMeta(response[0..response_len]) orelse return null;
    if (meta.status < 200 or meta.status >= 300 or meta.compressed or meta.body_start > response_len) return null;
    const raw_body = response[meta.body_start..response_len];
    var body_len: usize = 0;
    if (meta.chunked) {
        body_len = decodeChunks(raw_body, &resource_body_buffer) orelse return null;
    } else {
        if (meta.content_length) |expected| if (expected > raw_body.len or expected > resource_body_buffer.len) return null;
        body_len = @min(raw_body.len, resource_body_buffer.len);
        @memcpy(resource_body_buffer[0..body_len], raw_body[0..body_len]);
    }
    return resource_body_buffer[0..body_len];
}

fn urlLooksLikeFile(url: Url) bool {
    const path = url.path[0..url.path_len];
    const end = std.mem.indexOfAny(u8, path, "?#") orelse path.len;
    const clean = path[0..end];
    const slash = std.mem.lastIndexOfScalar(u8, clean, '/') orelse 0;
    const filename = clean[slash..];
    const dot = std.mem.lastIndexOfScalar(u8, filename, '.') orelse return false;
    if (dot == 0 or dot + 1 >= filename.len) return false;
    const extension = filename[dot..];
    return !(std.ascii.eqlIgnoreCase(extension, ".html") or std.ascii.eqlIgnoreCase(extension, ".htm") or
        std.ascii.eqlIgnoreCase(extension, ".xhtml") or std.ascii.eqlIgnoreCase(extension, ".php") or
        std.ascii.eqlIgnoreCase(extension, ".asp") or std.ascii.eqlIgnoreCase(extension, ".aspx"));
}

fn downloadsDirectory() ?u32 {
    if (!s.fs_mounted or !fat32.isMounted()) return null;
    const root = fat32.rootCluster();
    const home = fat32.changeDirectory(root, "home") orelse return null;
    const account_len = std.mem.indexOfScalar(u8, &s.account_name, 0) orelse s.account_name.len;
    const user = fat32.changeDirectory(home, s.account_name[0..account_len]) orelse return null;
    if (fat32.changeDirectory(user, "Downloads")) |existing| return existing;
    if (!fat32.makeDirectory(user, "Downloads")) return null;
    return fat32.changeDirectory(user, "Downloads");
}

fn downloadName(raw: []const u8, out: *[96]u8) usize {
    out.* = @splat(0);
    var used: usize = 0;
    for (raw) |ch| {
        if (ch < 0x20 or ch > 0x7e or ch == '/' or ch == '\\' or ch == ':' or ch == '*' or ch == '?' or ch == '"' or ch == '<' or ch == '>' or ch == '|') continue;
        if (used == 63) break; // Current file name field is bounded to 63 bytes.
        out[used] = ch;
        used += 1;
    }
    if (used == 0 or std.mem.eql(u8, out[0..used], ".") or std.mem.eql(u8, out[0..used], "..")) {
        @memcpy(out[0..12], "download.bin");
        return 12;
    }
    return used;
}

fn nameExists(directory: u32, name: []const u8) bool {
    var entries: [96]fat32.Entry = undefined;
    const count = fat32.listDirectory(directory, &entries);
    for (entries[0..count]) |entry| if (entry.name_len == name.len and std.ascii.eqlIgnoreCase(entry.name[0..entry.name_len], name)) return true;
    return false;
}

fn uniqueDownloadName(directory: u32, initial: []const u8, out: *[96]u8) ?[]const u8 {
    const length = downloadName(initial, out);
    if (!nameExists(directory, out[0..length])) return out[0..length];
    const original = out.*;
    const dot = std.mem.lastIndexOfScalar(u8, original[0..length], '.');
    const base_end = if (dot) |index| index else length;
    const extension = if (dot) |index| original[index..length] else "";
    var suffix: [8]u8 = undefined;
    for (1..100) |number| {
        const suffix_text = std.fmt.bufPrint(&suffix, " ({d})", .{number}) catch return null;
        const base_len = @min(base_end, 63 -| suffix_text.len -| extension.len);
        var used: usize = base_len;
        @memcpy(out[0..base_len], original[0..base_len]);
        @memcpy(out[used..][0..suffix_text.len], suffix_text);
        used += suffix_text.len;
        @memcpy(out[used..][0..extension.len], extension);
        used += extension.len;
        if (!nameExists(directory, out[0..used])) return out[0..used];
    }
    return null;
}

fn saveDownload(url: Url, meta: Meta, body: []const u8) bool {
    const directory = downloadsDirectory() orelse {
        setMessage("Cannot access Downloads in your home folder on the disk.");
        return false;
    };
    var path_name: [96]u8 = undefined;
    const path = url.path[0..url.path_len];
    const path_end = std.mem.indexOfAny(u8, path, "?#") orelse path.len;
    const clean_path = path[0..path_end];
    const slash = std.mem.lastIndexOfScalar(u8, clean_path, '/') orelse 0;
    const fallback_name = clean_path[slash..];
    const raw_name = if (meta.filename_len != 0) meta.filename[0..meta.filename_len] else fallback_name;
    const unique = uniqueDownloadName(directory, raw_name, &path_name) orelse {
        setMessage("Could not choose a unique filename for this download.");
        return false;
    };
    if (!fat32.writeFileAt(directory, unique, body)) {
        setMessage("Could not write the downloaded file to disk.");
        return false;
    }
    if (download_count == downloads.len) {
        for (1..downloads.len) |index| downloads[index - 1] = downloads[index];
        download_count -= 1;
    }
    var item = Download{ .name_len = unique.len, .url_len = @min(url.text_len, max_url), .size = body.len };
    @memcpy(item.name[0..unique.len], unique);
    @memcpy(item.url[0..item.url_len], url.text[0..item.url_len]);
    downloads[download_count] = item;
    download_count += 1;
    var msg: [128]u8 = undefined;
    const account_len = std.mem.indexOfScalar(u8, &s.account_name, 0) orelse s.account_name.len;
    const text = std.fmt.bufPrint(&msg, "Saved /home/{s}/Downloads/{s} ({d} bytes).", .{ s.account_name[0..account_len], unique, body.len }) catch "Download saved to Downloads.";
    setMessage(text);
    return true;
}

fn receiveDownload(url: Url, meta: Meta, raw_body: []const u8) bool {
    if (meta.content_length) |expected| if (expected > max_response or expected > raw_body.len) {
        setMessage("Download exceeds the 64 MiB browser limit or ended early.");
        return false;
    };
    var body_len: usize = 0;
    var body: []const u8 = raw_body;
    if (meta.chunked) {
        const mutable_body: []u8 = @constCast(raw_body);
        body_len = decodeChunksInPlace(mutable_body) orelse {
            setMessage("The downloaded file was incomplete or had invalid chunked encoding.");
            return false;
        };
        body = mutable_body[0..body_len];
    } else {
        body_len = if (meta.content_length) |expected| expected else raw_body.len;
        if (body_len > max_response or body_len > raw_body.len) {
            setMessage("Download exceeds the 64 MiB browser limit or ended early.");
            return false;
        }
        body = raw_body[0..body_len];
    }
    return saveDownload(url, meta, body[0..body_len]);
}

fn fetchImage(url_text: []const u8) ?media.Picture {
    const url = parseUrl(url_text) orelse return null;
    const body = fetchResource(url_text) orelse return null;
    const path_end = std.mem.indexOfAny(u8, url.path[0..url.path_len], "?#") orelse url.path_len;
    if (std.ascii.endsWithIgnoreCase(url.path[0..path_end], ".svg")) return svg.rasterize(body);
    return raster_image.decode(body);
}

fn navigate(url_text: []const u8, remember: bool) void {
    clearInlineImages();
    page = @splat(0);
    page_len = 0;
    page_lines = 0;
    page_scroll = 0;
    link_count = 0;
    page_title = @splat(0);
    page_title_len = 0;
    var parsed = parseUrl(url_text) orelse {
        setMessage("Enter a valid HTTP or HTTPS address.");
        return;
    };
    var redirects: u8 = 0;
    while (true) {
        _ = copyUrl(parsed.text[0..parsed.text_len]);
        if (!loadOnce(&parsed)) break;
        redirects += 1;
        if (redirects > 5) {
            setMessage("The page redirected too many times.");
            break;
        }
    }
    _ = copyUrl(parsed.text[0..parsed.text_len]);
    if (remember) addHistory(address[0..address_len]);
    saveBrowserTab();
}

fn submitAddress() void {
    const input = normalizeInput() orelse {
        setMessage("Type a website address or a search query.");
        return;
    };
    navigate(input, true);
    address_focused = false;
    select_address = false;
}

fn back() void {
    if (history_pos == 0 or history_count == 0) return;
    history_pos -= 1;
    navigate(history[history_pos][0..history_lens[history_pos]], false);
}

fn forward() void {
    if (history_pos + 1 >= history_count) return;
    history_pos += 1;
    navigate(history[history_pos][0..history_lens[history_pos]], false);
}

pub fn isActive() bool {
    return s.active_window >= 0 and s.windows[@intCast(s.active_window)].app == .browser;
}

pub fn addressFocused() bool {
    return address_focused;
}

pub fn documentTitle() []const u8 {
    return page_title[0..page_title_len];
}

pub fn copyAddressToClipboard() void {
    s.clipboard_len = @min(address_len, s.clipboard.len);
    @memcpy(s.clipboard[0..s.clipboard_len], address[0..s.clipboard_len]);
}

pub fn deleteAddressSelection() void {
    if (!address_focused or !select_address) return;
    address = @splat(0);
    address_len = 0;
    address_cursor = 0;
    select_address = false;
}

pub fn focusAddress() void {
    address_focused = true;
    select_address = true;
    address_cursor = address_len;
}

pub fn selectAllAddress() void {
    address_focused = true;
    select_address = true;
    address_cursor = address_len;
}

pub fn insertAddressChar(ch: u8) void {
    if (ch < 0x20 or ch == 0x7f) return;
    if (select_address) {
        address_len = 0;
        address_cursor = 0;
        address = @splat(0);
        select_address = false;
    }
    if (address_len == address.len) return;
    var i = address_len;
    while (i > address_cursor) : (i -= 1) address[i] = address[i - 1];
    address[address_cursor] = ch;
    address_len += 1;
    address_cursor += 1;
}

pub fn backspaceAddress() void {
    if (!address_focused) return;
    if (select_address) {
        address = @splat(0);
        address_len = 0;
        address_cursor = 0;
        select_address = false;
    } else if (address_cursor != 0) {
        var i = address_cursor - 1;
        while (i + 1 < address_len) : (i += 1) address[i] = address[i + 1];
        address_len -= 1;
        address_cursor -= 1;
        address[address_len] = 0;
    }
}

pub fn moveAddressCursor(right: bool) void {
    select_address = false;
    if (right) address_cursor = @min(address_cursor + 1, address_len) else address_cursor -|= 1;
}

pub fn pasteAddress(bytes: []const u8) void {
    if (select_address) {
        address = @splat(0);
        address_len = 0;
        address_cursor = 0;
        select_address = false;
    }
    for (bytes) |ch| if (ch >= 0x20 and ch != 0x7f) insertAddressChar(ch);
}

pub fn navigateCurrent() void {
    submitAddress();
}

pub fn refresh() void {
    if (address_len != 0) navigate(address[0..address_len], false);
}

pub fn scroll(lines: i32) void {
    if (arix_rendered) {
        const visible = visiblePageLines();
        const maximum = page_lines -| visible;
        if (lines > 0) page_scroll = @min(maximum, page_scroll + @as(usize, @intCast(lines))) else page_scroll -|= @as(usize, @intCast(-lines));
    } else if (lines > 0) page_scroll = @min(page_lines, page_scroll + @as(usize, @intCast(lines))) else page_scroll -|= @as(usize, @intCast(-lines));
}

fn visiblePageLines() usize {
    const height: usize = if (isActive()) @intCast(s.windows[@intCast(s.active_window)].h -| 130) else @intCast(s.fb.height -| 126);
    return @max(1, (height + 9) / 10);
}

pub fn handleMousePress(x: u64, y: u64, win: s.Window) void {
    if (y >= win.y + 34 and y < win.y + 58) {
        const tabs_x = win.x + 8;
        if (x < tabs_x) return;
        const relative = x - tabs_x;
        const tab_width: u64 = 156;
        const index: usize = @intCast(relative / tab_width);
        if (index < browser_tab_count) {
            if (x >= tabs_x + @as(u64, @intCast(index)) * tab_width + 132) {
                _ = closeTab(index);
            } else _ = switchTab(index);
        } else if (relative >= browser_tab_count * tab_width and relative < browser_tab_count * tab_width + 40) {
            _ = newTab();
        }
        return;
    }
    const toolbar_y = win.y + 60;
    if (y >= toolbar_y and y < toolbar_y + 26) {
        if (x < win.x + 44) back() else if (x < win.x + 78) forward() else if (x < win.x + 112) refresh() else if (x >= win.x + win.w -| 124 and x < win.x + win.w -| 92) {
            downloads_panel = !downloads_panel;
            history_panel = false;
            address_focused = false;
        } else if (x >= win.x + win.w -| 88 and x < win.x + win.w -| 56) {
            history_panel = !history_panel;
            downloads_panel = false;
            address_focused = false;
        } else if (x >= win.x + 112 and x < win.x + win.w -| 128) {
            address_focused = true;
            select_address = false;
            address_cursor = address_len;
        } else submitAddress();
        return;
    }
    address_focused = false;
    if (history_panel or downloads_panel) {
        const row = if (y < win.y + 138) 0 else @as(usize, @intCast((y - (win.y + 138)) / 20));
        if (history_panel and row < history_count) {
            const selected = history_count - 1 - row;
            history_panel = false;
            navigate(history[selected][0..history_lens[selected]], true);
        }
        return;
    }
    if (y < win.y + 110 or page_lines == 0) return;
    const local_y = y - (win.y + 110);
    var visible_line = page_scroll;
    var used_y: u64 = 0;
    var scan: usize = 0;
    while (scan < page_len and used_y <= local_y) {
        if (visible_line >= page_lines) break;
        const end = std.mem.indexOfScalarPos(u8, page[0..page_len], scan, '\n') orelse page_len;
        const row_height = @max(10, page_line_heights[scan]);
        if (local_y < used_y +| row_height) break;
        used_y +|= row_height;
        scan = if (end < page_len) end + 1 else page_len;
        visible_line += 1;
    }
    for (links[0..link_count]) |link| if (link.valid and link.line == visible_line) {
        navigate(link.url[0..link.url_len], true);
        return;
    };
}

fn appendPage(ch: u8) void {
    if (page_len >= page.len) return;
    page[page_len] = ch;
    page_colors[page_len] = rendering_style.color orelse 0;
    page_backgrounds[page_len] = rendering_style.background orelse 0;
    page_box_backgrounds[page_len] = rendering_style.container_background orelse 0;
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
    var line_start = page_len;
    while (line_start > 0 and page[line_start - 1] != '\n') : (line_start -= 1) {}
    if (line_start == page_len and page_len != 0 and page[page_len - 1] == '\n') line_start = page_len;
    const indent = @min(flow_indent, effective_columns -| 1);
    if (page_len == 0 or page[page_len - 1] == '\n') {
        for (0..indent) |_| appendPage(' ');
    } else if (line_start == page_len) {
        for (0..indent) |_| appendPage(' ');
    }
    var displayed = ch;
    if (ch < 0x80) switch (flow_style.text_transform) {
        .uppercase => displayed = std.ascii.toUpper(ch),
        .lowercase => displayed = std.ascii.toLower(ch),
        .capitalize => if (previous_space.*) { displayed = std.ascii.toUpper(ch); },
        .none => {},
    };
    appendPage(if (displayed < 0x80) displayed else '?');
    previous_space.* = false;
}

fn htmlEntity(input: []const u8, start: usize) ?struct { ch: u8, consumed: usize } {
    const end_rel = std.mem.indexOfScalar(u8, input[start..@min(input.len, start + 12)], ';') orelse return null;
    const entity = input[start .. start + end_rel + 1];
    const decoded: u8 = if (equalIgnoreCase(entity, "&amp;")) '&' else if (equalIgnoreCase(entity, "&lt;")) '<' else if (equalIgnoreCase(entity, "&gt;")) '>' else if (equalIgnoreCase(entity, "&quot;")) '"' else if (equalIgnoreCase(entity, "&#39;") or equalIgnoreCase(entity, "&apos;")) '\'' else if (equalIgnoreCase(entity, "&nbsp;")) ' ' else return null;
    return .{ .ch = decoded, .consumed = entity.len };
}

fn parseHref(tag: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < tag.len) {
        while (i < tag.len and tag[i] != ' ' and tag[i] != '\t') : (i += 1) {}
        while (i < tag.len and (tag[i] == ' ' or tag[i] == '\t' or tag[i] == '/')) : (i += 1) {}
        const name_start = i;
        while (i < tag.len and tag[i] != '=' and tag[i] != ' ' and tag[i] != '\t') : (i += 1) {}
        const name = tag[name_start..i];
        while (i < tag.len and (tag[i] == ' ' or tag[i] == '\t')) : (i += 1) {}
        if (i >= tag.len or tag[i] != '=') continue;
        i += 1;
        while (i < tag.len and (tag[i] == ' ' or tag[i] == '\t')) : (i += 1) {}
        if (equalIgnoreCase(name, "href")) {
            if (i >= tag.len) return null;
            const quote = if (tag[i] == '"' or tag[i] == '\'') tag[i] else 0;
            if (quote != 0) i += 1;
            const start = i;
            while (i < tag.len and (if (quote == 0) tag[i] != ' ' and tag[i] != '>' else tag[i] != quote)) : (i += 1) {}
            return tag[start..i];
        }
        if (i < tag.len and (tag[i] == '"' or tag[i] == '\'')) {
            const quote = tag[i];
            i += 1;
            while (i < tag.len and tag[i] != quote) : (i += 1) {}
            if (i < tag.len) i += 1;
        } else while (i < tag.len and tag[i] != ' ' and tag[i] != '>') : (i += 1) {}
    }
    return null;
}

fn htmlPixelSize(tag: []const u8, attribute_name: []const u8) ?u16 {
    const raw = css.attribute(tag, attribute_name) orelse return null;
    const value = std.mem.trim(u8, raw, " \t\r\n");
    if (value.len == 0 or value.len > 5) return null;
    const parsed = std.fmt.parseInt(u16, value, 10) catch return null;
    return if (parsed == 0) null else @min(parsed, 4096);
}

fn htmlNumberMilli(tag: []const u8, attribute_name: []const u8) ?u64 {
    const raw = css.attribute(tag, attribute_name) orelse return null;
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

fn hasHtmlAttribute(tag: []const u8, wanted: []const u8) bool {
    var cursor: usize = 0;
    while (cursor < tag.len) {
        while (cursor < tag.len and (tag[cursor] == ' ' or tag[cursor] == '\t' or tag[cursor] == '/' or tag[cursor] == '\r' or tag[cursor] == '\n')) : (cursor += 1) {}
        const start = cursor;
        while (cursor < tag.len and tag[cursor] != '=' and tag[cursor] != ' ' and tag[cursor] != '\t' and tag[cursor] != '/' and tag[cursor] != '>') : (cursor += 1) {}
        if (cursor > start and std.ascii.eqlIgnoreCase(tag[start..cursor], wanted)) return true;
        while (cursor < tag.len and (tag[cursor] == ' ' or tag[cursor] == '\t')) : (cursor += 1) {}
        if (cursor < tag.len and tag[cursor] == '=') {
            cursor += 1;
            while (cursor < tag.len and (tag[cursor] == ' ' or tag[cursor] == '\t')) : (cursor += 1) {}
            if (cursor < tag.len and (tag[cursor] == '\'' or tag[cursor] == '"')) {
                const quote = tag[cursor];
                cursor += 1;
                while (cursor < tag.len and tag[cursor] != quote) : (cursor += 1) {}
                if (cursor < tag.len) cursor += 1;
            } else while (cursor < tag.len and tag[cursor] != ' ' and tag[cursor] != '\t' and tag[cursor] != '>') : (cursor += 1) {}
        }
    }
    return false;
}

fn renderInput(tag: []const u8, columns: usize, previous_space: *bool) void {
    const kind = css.attribute(tag, "type") orelse "text";
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
        const label = css.attribute(tag, "value") orelse if (equalIgnoreCase(kind, "submit")) "Submit" else if (equalIgnoreCase(kind, "reset")) "Reset" else "Button";
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
    if (css.attribute(tag, "size")) |raw_size| size = @max(1, @min(32, std.fmt.parseInt(usize, raw_size, 10) catch 12));
    appendVisible('[', columns, previous_space);
    const value = css.attribute(tag, "value") orelse css.attribute(tag, "placeholder") orelse "";
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
    if (css.attribute(tag, "src")) |source| return source;
    const srcset = css.attribute(tag, "srcset") orelse return null;
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

fn resolveLink(page_url: Url, href: []const u8, out: *[max_url]u8) ?usize {
    if (href.len == 0 or href[0] == '#' or startsIgnoreCase(href, "javascript:")) return null;
    var decoded: [max_url]u8 = @splat(0);
    var dlen: usize = 0;
    var i: usize = 0;
    while (i < href.len and dlen < decoded.len) {
        if (href[i] == '&') {
            if (htmlEntity(href, i)) |entity| {
                decoded[dlen] = entity.ch;
                dlen += 1;
                i += entity.consumed;
                continue;
            }
        }
        decoded[dlen] = href[i];
        dlen += 1;
        i += 1;
    }
    const resolved = resolveRedirect(page_url, decoded[0..dlen], out) orelse return null;
    return resolved.len;
}

fn titleFromHtml(input: []const u8) void {
    var cursor: usize = 0;
    while (cursor < input.len) {
        const open = std.mem.indexOfScalarPos(u8, input, cursor, '<') orelse return;
        const end = std.mem.indexOfScalarPos(u8, input, open, '>') orelse return;
        if (startsIgnoreCase(input[open..end], "<title")) {
            const close = std.mem.indexOf(u8, input[end + 1 ..], "</title") orelse return;
            const title = std.mem.trim(u8, input[end + 1 ..][0..close], " \r\n\t");
            page_title_len = @min(title.len, page_title.len);
            for (title[0..page_title_len], 0..) |ch, index| page_title[index] = if (ch < 0x80) ch else '?';
            return;
        }
        cursor = end + 1;
    }
}

fn renderPlain(input: []const u8, columns: usize) void {
    page = @splat(0);
    page_background_color = null;
    rendering_style = .{};
    flow_style = .{};
    flow_indent = 0;
    flow_right_inset = 0;
    flow_font_scale = 1;
    flow_align_start = 0;
    flow_align_width = columns;
    page_len = 0;
    page_lines = 1;
    block_box_count = 0;
    link_count = 0;
    page_title_len = 0;
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

fn findIgnoreCase(input: []const u8, needle: []const u8, start: usize) ?usize {
    if (needle.len == 0 or start > input.len or needle.len > input.len - start) return null;
    var cursor = start;
    while (cursor + needle.len <= input.len) : (cursor += 1) {
        if (std.ascii.eqlIgnoreCase(input[cursor .. cursor + needle.len], needle)) return cursor;
    }
    return null;
}

fn collectStyleBlocks(input: []const u8, sheet: *css.Sheet, viewport_height: u16) void {
    var cursor: usize = 0;
    while (findIgnoreCase(input, "<style", cursor)) |open| {
        const tag_end = std.mem.indexOfScalarPos(u8, input, open, '>') orelse return;
        const close = findIgnoreCase(input, "</style", tag_end + 1) orelse return;
        sheet.parse(input[tag_end + 1 .. close], viewport_height);
        cursor = close + 7;
    }
    cursor = 0;
    while (findIgnoreCase(input, "<link", cursor)) |open| {
        const tag_end = std.mem.indexOfScalarPos(u8, input, open, '>') orelse return;
        const tag = input[open + 1 .. tag_end];
        const rel = css.attribute(tag, "rel") orelse "";
        const href = css.attribute(tag, "href") orelse "";
        if (equalIgnoreCase(rel, "stylesheet") and href.len != 0) {
            if (parseUrl(address[0..address_len])) |base| {
                var resolved: [max_url]u8 = undefined;
                if (resolveLink(base, href, &resolved)) |resolved_len| {
                    if (fetchResource(resolved[0..resolved_len])) |stylesheet| sheet.parse(stylesheet, viewport_height);
                }
            }
        }
        cursor = tag_end + 1;
    }
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
    flow_right_inset = centered + right;
    flow_align_start = flow_indent;
    flow_align_width = @max(1, @min(max_content, available -| left -| right));
}

fn appendScriptLiteral(source: []const u8, out: []u8, used: *usize) usize {
    var cursor: usize = 0;
    while (cursor < source.len) {
        const write_at = findIgnoreCase(source, "document.write", cursor) orelse break;
        var i = write_at + "document.write".len;
        var line_break = false;
        if (i < source.len and source[i] == 'l') {
            if (source.len - i >= 2 and std.mem.eql(u8, source[i .. i + 2], "ln")) {
                line_break = true;
                i += 2;
            }
        }
        while (i < source.len and (source[i] == ' ' or source[i] == '\t' or source[i] == '\r' or source[i] == '\n')) : (i += 1) {}
        if (i >= source.len or source[i] != '(') {
            cursor = write_at + 1;
            continue;
        }
        i += 1;
        while (i < source.len and (source[i] == ' ' or source[i] == '\t' or source[i] == '\r' or source[i] == '\n')) : (i += 1) {}
        if (i >= source.len or (source[i] != '\'' and source[i] != '"')) {
            cursor = write_at + 1;
            continue;
        }
        const quote = source[i];
        i += 1;
        var literal: [max_page]u8 = undefined;
        var literal_len: usize = 0;
        var valid = false;
        while (i < source.len and literal_len < literal.len) : (i += 1) {
            const ch = source[i];
            if (ch == quote) {
                valid = true;
                i += 1;
                break;
            }
            if (ch == '\\' and i + 1 < source.len) {
                i += 1;
                literal[literal_len] = switch (source[i]) {
                    'n' => '\n',
                    'r' => '\r',
                    't' => '\t',
                    else => source[i],
                };
            } else literal[literal_len] = ch;
            literal_len += 1;
        }
        if (valid) {
            if (!append(out, used, literal[0..literal_len])) return cursor;
            if (line_break) _ = append(out, used, "\n");
        }
        cursor = i;
    }
    return cursor;
}

/// A deliberately small first JavaScript step: execute literal document.write/writeln calls.
/// It never evaluates expressions, variables, loops, or event handlers.
fn expandBasicScripts(input: []const u8) []const u8 {
    var used: usize = 0;
    var cursor: usize = 0;
    while (findIgnoreCase(input, "<script", cursor)) |open| {
        if (!append(&expanded_html, &used, input[cursor..open])) break;
        const tag_end = std.mem.indexOfScalarPos(u8, input, open, '>') orelse {
            _ = append(&expanded_html, &used, input[cursor..]);
            cursor = input.len;
            break;
        };
        const close = findIgnoreCase(input, "</script", tag_end + 1) orelse {
            _ = append(&expanded_html, &used, input[cursor..]);
            cursor = input.len;
            break;
        };
        const tag = input[open + 1 .. tag_end];
        if (css.attribute(tag, "src") == null) _ = appendScriptLiteral(input[tag_end + 1 .. close], &expanded_html, &used);
        const close_end = std.mem.indexOfScalarPos(u8, input, close, '>') orelse input.len - 1;
        cursor = close_end + 1;
        if (used == expanded_html.len) break;
    }
    if (cursor < input.len and used < expanded_html.len) _ = append(&expanded_html, &used, input[cursor..]);
    return expanded_html[0..used];
}

fn isVoidElement(name: []const u8) bool {
    return equalIgnoreCase(name, "area") or equalIgnoreCase(name, "base") or equalIgnoreCase(name, "br") or
        equalIgnoreCase(name, "col") or equalIgnoreCase(name, "embed") or equalIgnoreCase(name, "hr") or
        equalIgnoreCase(name, "img") or equalIgnoreCase(name, "input") or equalIgnoreCase(name, "link") or
        equalIgnoreCase(name, "meta") or equalIgnoreCase(name, "param") or equalIgnoreCase(name, "source") or
        equalIgnoreCase(name, "track") or equalIgnoreCase(name, "wbr");
}

fn skipElement(input: []const u8, start: usize, name: []const u8) ?usize {
    var depth: usize = 1;
    var cursor = start;
    while (cursor < input.len) {
        const open = std.mem.indexOfScalarPos(u8, input, cursor, '<') orelse return null;
        const end = std.mem.indexOfScalarPos(u8, input, open, '>') orelse return null;
        const tag = input[open + 1 .. end];
        const closing = tag.len != 0 and tag[0] == '/';
        var tag_start: usize = @intFromBool(closing);
        while (tag_start < tag.len and tag[tag_start] == ' ') : (tag_start += 1) {}
        var tag_end = tag_start;
        while (tag_end < tag.len and (std.ascii.isAlphanumeric(tag[tag_end]) or tag[tag_end] == '-' or tag[tag_end] == ':')) : (tag_end += 1) {}
        if (std.ascii.eqlIgnoreCase(tag[tag_start..tag_end], name)) {
            if (closing) {
                depth -= 1;
                if (depth == 0) return end + 1;
            } else if (!isVoidElement(name) and std.mem.indexOfScalar(u8, tag, '/') == null) {
                depth += 1;
            }
        }
        cursor = end + 1;
    }
    return null;
}

fn renderHtml(input: []const u8, columns: usize) void {
    if (use_arix_renderer and renderHtmlArix(input, columns)) return;
    renderHtmlDocument(input, columns);
}

fn appendArixCss(used: *usize, bytes: []const u8) void {
    if (bytes.len > arix_css_buffer.len -| used.*) return;
    @memcpy(arix_css_buffer[used.*..][0..bytes.len], bytes);
    used.* += bytes.len;
    if (used.* < arix_css_buffer.len) {
        arix_css_buffer[used.*] = '\n';
        used.* += 1;
    }
}

fn collectArixCss(input: []const u8) []const u8 {
    var used: usize = 0;
    var external_sheets: u8 = 0;
    var cursor: usize = 0;
    while (findIgnoreCase(input, "<style", cursor)) |open| {
        const tag_end = std.mem.indexOfScalarPos(u8, input, open, '>') orelse break;
        const close = findIgnoreCase(input, "</style", tag_end + 1) orelse break;
        appendArixCss(&used, input[tag_end + 1 .. close]);
        cursor = close + 7;
    }
    cursor = 0;
    while (external_sheets < 4 and used < arix_css_buffer.len) {
        const open = findIgnoreCase(input, "<link", cursor) orelse break;
        const tag_end = std.mem.indexOfScalarPos(u8, input, open, '>') orelse break;
        const tag = input[open + 1 .. tag_end];
        const rel = css.attribute(tag, "rel") orelse "";
        const href = css.attribute(tag, "href") orelse "";
        if (equalIgnoreCase(rel, "stylesheet") and href.len != 0) {
            external_sheets += 1;
            if (parseUrl(address[0..address_len])) |base| {
                var resolved: [max_url]u8 = undefined;
                if (resolveLink(base, href, &resolved)) |length| {
                    if (fetchResource(resolved[0..length])) |sheet| appendArixCss(&used, sheet);
                }
            }
        }
        cursor = tag_end + 1;
    }
    return arix_css_buffer[0..used];
}

const CssVariable = struct { name: []const u8, value: []const u8 };

fn resolveArixCssVariables(allocator: std.mem.Allocator, source: []const u8) ![]const u8 {
    var variables: [256]CssVariable = undefined;
    var variable_count: usize = 0;
    var cursor: usize = 0;
    while (findIgnoreCase(source, "--", cursor)) |start| {
        var name_end = start + 2;
        while (name_end < source.len and (std.ascii.isAlphanumeric(source[name_end]) or source[name_end] == '-' or source[name_end] == '_')) : (name_end += 1) {}
        if (name_end == start + 2 or name_end >= source.len or source[name_end] != ':') {
            cursor = start + 2;
            continue;
        }
        var value_start = name_end + 1;
        while (value_start < source.len and std.ascii.isWhitespace(source[value_start])) : (value_start += 1) {}
        const value_end = value_start + (std.mem.indexOfAny(u8, source[value_start..], ";}") orelse source.len - value_start);
        if (value_end > value_start) {
            const name = source[start..name_end];
            const value = std.mem.trim(u8, source[value_start..value_end], " \t\r\n");
            var replaced = false;
            for (variables[0..variable_count]) |*existing| {
                if (std.mem.eql(u8, existing.name, name)) {
                    existing.value = value;
                    replaced = true;
                    break;
                }
            }
            if (!replaced and variable_count < variables.len) {
                variables[variable_count] = .{ .name = name, .value = value };
                variable_count += 1;
            }
        }
        cursor = value_end + 1;
    }

    var output: std.ArrayList(u8) = .empty;
    try expandArixCssVariables(allocator, &output, source, variables[0..variable_count], 0);
    return output.items;
}

fn expandArixCssVariables(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    source: []const u8,
    variables: []const CssVariable,
    depth: u8,
) !void {
    var cursor: usize = 0;
    while (findIgnoreCase(source, "var(", cursor)) |start| {
        var nesting: usize = 1;
        var end = start + 4;
        while (end < source.len and nesting != 0) : (end += 1) {
            if (source[end] == '(') nesting += 1 else if (source[end] == ')') nesting -= 1;
        }
        if (nesting != 0) break;
        const close = end - 1;
        try appendResolvedCss(output, allocator, source[cursor..start]);
        const expression = source[start + 4 .. close];
        const comma = std.mem.indexOfScalar(u8, expression, ',');
        const name = std.mem.trim(u8, if (comma) |at| expression[0..at] else expression, " \t\r\n");
        var replacement: ?[]const u8 = null;
        for (variables) |variable| {
            if (std.mem.eql(u8, variable.name, name)) {
                replacement = variable.value;
                break;
            }
        }
        if (replacement) |value| {
            if (depth < 4 and findIgnoreCase(value, "var(", 0) != null)
                try expandArixCssVariables(allocator, output, value, variables, depth + 1)
            else
                try appendResolvedCss(output, allocator, value);
        } else if (comma) |at| {
            try appendResolvedCss(output, allocator, std.mem.trim(u8, expression[at + 1 ..], " \t\r\n"));
        } else {
            try appendResolvedCss(output, allocator, source[start..end]);
        }
        cursor = end;
    }
    try appendResolvedCss(output, allocator, source[cursor..]);
}

fn appendResolvedCss(output: *std.ArrayList(u8), allocator: std.mem.Allocator, value: []const u8) !void {
    if (value.len > max_arix_css * 2 -| output.items.len) return error.CssTooLarge;
    try output.appendSlice(allocator, value);
}

fn stripArixElement(allocator: std.mem.Allocator, input: []const u8, tag_name: []const u8) ?[]const u8 {
    const output = allocator.alloc(u8, input.len) catch return null;
    var open_tag: [16]u8 = undefined;
    var close_tag: [17]u8 = undefined;
    const open_tag_text = std.fmt.bufPrint(&open_tag, "<{s}", .{tag_name}) catch return null;
    const close_tag_text = std.fmt.bufPrint(&close_tag, "</{s}", .{tag_name}) catch return null;
    var used: usize = 0;
    var cursor: usize = 0;
    while (findIgnoreCase(input, open_tag_text, cursor)) |open| {
        const tag_end = std.mem.indexOfScalarPos(u8, input, open, '>') orelse break;
        const close = findIgnoreCase(input, close_tag_text, tag_end + 1) orelse {
            const remaining = input.len - cursor;
            @memcpy(output[used..][0..remaining], input[cursor..]);
            used += remaining;
            return output[0..used];
        };
        const close_end = std.mem.indexOfScalarPos(u8, input, close, '>') orelse input.len - 1;
        const keep_len = open - cursor;
        @memcpy(output[used..][0..keep_len], input[cursor..open]);
        used += keep_len;
        cursor = @min(input.len, close_end + 1);
    }
    if (cursor < input.len) {
        const remaining = input.len - cursor;
        @memcpy(output[used..][0..remaining], input[cursor..]);
        used += remaining;
    }
    return output[0..used];
}

fn renderHtmlArix(input: []const u8, columns: usize) bool {
    clearInlineImages();
    page = @splat(0);
    page_len = 1;
    page_lines = 0;
    page_scroll = 0;
    page_background_color = null;
    block_box_count = 0;
    link_count = 0;
    titleFromHtml(input);

    const active = if (isActive()) s.windows[@intCast(s.active_window)] else null;
    const requested_width: usize = if (active) |window|
        @intCast(@max(320, window.w -| 36))
    else
        @max(320, columns * 6);
    const width = @min(requested_width, 1920);
    const requested_height: usize = if (active) |window|
        @intCast(@max(600, window.h -| 104) * 2)
    else
        @max(900, @as(usize, s.fb.height) * 3);
    const height = @min(requested_height, @max(@as(usize, 600), @as(usize, 3_800_000) / width));

    if (!arix_renderer.initFont(heap.allocator())) return false;
    const mark = heap.mark();
    const no_scripts = stripArixElement(heap.allocator(), input, "script") orelse {
        heap.rewind(mark);
        panic_report.trace("Arix: could not remove disabled script content");
        return false;
    };
    const sanitized_html = stripArixElement(heap.allocator(), no_scripts, "style") orelse {
        heap.rewind(mark);
        panic_report.trace("Arix: could not remove style blocks from the document flow");
        return false;
    };
    const collected_css = collectArixCss(input);
    var css_diagnostic: [48]u8 = undefined;
    const css_diagnostic_text = std.fmt.bufPrint(&css_diagnostic, "Arix: stylesheet bytes={d}", .{collected_css.len}) catch "Arix: stylesheet bytes unavailable";
    panic_report.trace(css_diagnostic_text);
    const arix_css = resolveArixCssVariables(heap.allocator(), collected_css) catch {
        heap.rewind(mark);
        panic_report.trace("Arix: CSS variable expansion failed");
        return false;
    };
    const raster = arix_renderer.render(heap.allocator(), sanitized_html, arix_css, width, height) orelse {
        heap.rewind(mark);
        panic_report.trace(arix_renderer.failureMessage());
        return false;
    };
    const picture = media.allocate(raster.width, raster.height) orelse {
        heap.rewind(mark);
        return false;
    };
    for (raster.pixels, 0..) |pixel, index| {
        picture.pixels[index] = (@as(u32, pixel[0]) << 24) | (@as(u32, pixel[1]) << 16) | (@as(u32, pixel[2]) << 8) | 0xff;
    }
    heap.rewind(mark);
    inline_images[0] = picture;
    arix_rendered = true;
    panic_report.trace("Arix: page rendered successfully");
    page_lines = (picture.height + 9) / 10;
    return true;
}

fn renderHtmlDocument(input: []const u8, columns: usize) void {
    clearInlineImages();
    page = @splat(0);
    page_background_color = null;
    rendering_style = .{};
    flow_style = .{};
    flow_indent = 0;
    flow_right_inset = 0;
    flow_font_scale = 1;
    flow_align_start = 0;
    flow_align_width = columns;
    page_len = 0;
    page_lines = 1;
    block_box_count = 0;
    link_count = 0;
    titleFromHtml(input);
    var stylesheet = css.Sheet{};
    const viewport_height: u16 = @intCast(@min(s.fb.height, std.math.maxInt(u16)));
    collectStyleBlocks(input, &stylesheet, viewport_height);
    var hidden: ?[]const u8 = null;
    const StyleFrame = struct {
        name: [16]u8 = @splat(0),
        name_len: u8 = 0,
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
    var i: usize = 0;
    var list_item_counter: u16 = 0;
    var preformatted = false;
    var previous_space = true;
    while (i < input.len and page_len + 1 < page.len) {
        if (hidden) |tag_name| {
            var close_tag: [16]u8 = undefined;
            var close_len: usize = 0;
            close_tag[close_len] = '<';
            close_len += 1;
            close_tag[close_len] = '/';
            close_len += 1;
            @memcpy(close_tag[close_len..][0..tag_name.len], tag_name);
            close_len += tag_name.len;
            const end_tag = std.mem.indexOf(u8, input[i..], close_tag[0..close_len]) orelse break;
            i += end_tag + close_len;
            while (i < input.len and input[i] != '>') : (i += 1) {}
            if (i < input.len) i += 1;
            hidden = null;
            continue;
        }
        if (input[i] == '<') {
            if (i + 3 < input.len and std.mem.eql(u8, input[i .. i + 4], "<!--")) {
                const comment_end = std.mem.indexOf(u8, input[i + 4 ..], "-->") orelse break;
                i += comment_end + 7;
                continue;
            }
            const end = std.mem.indexOfScalarPos(u8, input, i, '>') orelse break;
            const tag = input[i + 1 .. end];
            const closing = tag.len != 0 and tag[0] == '/';
            var name_start: usize = @intFromBool(closing);
            while (name_start < tag.len and tag[name_start] == ' ') : (name_start += 1) {}
            var name_end = name_start;
            while (name_end < tag.len and (std.ascii.isAlphanumeric(tag[name_end]) or tag[name_end] == '-' or tag[name_end] == ':')) : (name_end += 1) {}
            const name = tag[name_start..name_end];
            if (!closing and equalIgnoreCase(name, "svg")) {
                const remaining = input[end + 1 ..];
                const close_at = findIgnoreCase(remaining, "</svg", 0) orelse {
                    i = end + 1;
                    continue;
                };
                const close_tail = remaining[close_at..];
                const close_end = std.mem.indexOfScalar(u8, close_tail, '>') orelse {
                    i = end + 1 + close_at;
                    continue;
                };
                if (inline_images.len > 0) {
                    if (svg.rasterize(input[i .. end + 1 + close_at + close_end + 1])) |picture| {
                        var slot: ?usize = null;
                        for (inline_images, 0..) |image, image_index| if (image == null) {
                            slot = image_index;
                            break;
                        };
                        if (slot) |image_index| {
                            const max_width = @max(1, columns * 6);
                            const max_height: usize = 220;
                            const dimensions = imageLayoutSize(tag, .{}, picture, max_width, max_height);
                            inline_images[image_index] = picture;
                            newline();
                            const marker = page_len;
                            appendPage(0xff);
                            page_media_ids[marker] = @intCast(image_index);
                            page_media_widths[marker] = dimensions.w;
                            page_media_heights[marker] = dimensions.h;
                            page_media_fit_modes[marker] = @intFromEnum(css.ObjectFit.fill);
                            page_line_heights[marker] = @intCast(@min(255, @max(10, dimensions.h)));
                            newline();
                        } else media.release(picture);
                    }
                }
                i = end + 1 + close_at + close_end + 1;
                previous_space = true;
                continue;
            }
            if (!closing and (equalIgnoreCase(name, "script") or equalIgnoreCase(name, "style") or equalIgnoreCase(name, "head") or equalIgnoreCase(name, "noscript"))) {
                hidden = name;
                i = end + 1;
                continue;
            }
            if (closing) {
                const closing_style = active_style;
                if (equalIgnoreCase(name, "q")) appendVisible('"', columns, &previous_space);
                if (equalIgnoreCase(name, "rt")) appendVisible(')', columns, &previous_space);
                if (equalIgnoreCase(name, "button") or equalIgnoreCase(name, "select") or equalIgnoreCase(name, "textarea")) appendVisible(']', columns, &previous_space);
                if (equalIgnoreCase(name, "pre")) preformatted = false;
                if (isBlock(name, closing_style)) {
                    rendering_style = closing_style;
                    newline();
                    verticalGap(closing_style.padding.bottom);
                    var matching = style_stack_len;
                    while (matching > 0) {
                        matching -= 1;
                        if (style_stack[matching].name_len == name.len and std.ascii.eqlIgnoreCase(style_stack[matching].name[0..style_stack[matching].name_len], name)) {
                            if (style_stack[matching].box_index) |box_index| block_boxes[box_index].end_line = page_lines;
                            break;
                        }
                    }
                    verticalGap(closing_style.margin.bottom);
                }
                var frame_index = style_stack_len;
                while (frame_index > 0) {
                    frame_index -= 1;
                    active_style = style_stack[frame_index].parent;
                    flow_indent = style_stack[frame_index].parent_indent;
                    flow_right_inset = style_stack[frame_index].parent_right_inset;
                    flow_font_scale = style_stack[frame_index].parent_font_scale;
                    flow_align_start = style_stack[frame_index].parent_align_start;
                    flow_align_width = style_stack[frame_index].parent_align_width;
                    style_stack_len = frame_index;
                    if (style_stack[frame_index].name_len == name.len and std.ascii.eqlIgnoreCase(style_stack[frame_index].name[0..style_stack[frame_index].name_len], name)) break;
                }
                rendering_style = active_style;
                flow_style = active_style;
                if (isBlockElement(name)) newline();
                previous_space = true;
                i = end + 1;
                continue;
            }
            const parent_style = active_style;
            var element_style = stylesheet.compute(
                parent_style,
                name,
                css.attribute(tag, "id") orelse "",
                css.attribute(tag, "class") orelse "",
                css.attribute(tag, "style") orelse "",
                viewport_height,
            );
            if (element_style.hidden) {
                if (skipElement(input, end + 1, name)) |after_element| {
                    i = after_element;
                    continue;
                }
            }
            if (equalIgnoreCase(name, "iframe") or equalIgnoreCase(name, "video") or equalIgnoreCase(name, "audio")) {
                const fallback = if (equalIgnoreCase(name, "iframe")) "[Embedded frame]" else if (equalIgnoreCase(name, "video")) "[Video player]" else "[Audio player]";
                for (fallback) |ch| appendVisible(ch, columns, &previous_space);
                i = skipElement(input, end + 1, name) orelse end + 1;
                previous_space = false;
                continue;
            }
            if (equalIgnoreCase(name, "progress") or equalIgnoreCase(name, "meter")) {
                renderMeterTag(tag, columns, &previous_space);
                i = skipElement(input, end + 1, name) orelse end + 1;
                previous_space = false;
                continue;
            }
            var trimmed_tag_len = tag.len;
            while (trimmed_tag_len > 0 and (tag[trimmed_tag_len - 1] == ' ' or tag[trimmed_tag_len - 1] == '\t' or tag[trimmed_tag_len - 1] == '\r' or tag[trimmed_tag_len - 1] == '\n')) : (trimmed_tag_len -= 1) {}
            const void_element = isVoidElement(name) or (trimmed_tag_len > 0 and tag[trimmed_tag_len - 1] == '/');
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
                const heading_scale: u8 = switch (name[1]) { '1' => 4, '2' => 3, '3' => 2, '4' => 2, else => 1 };
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
                        .image_id = if (element_style.background_image) |image| fetchCssImage(image) else null,
                    };
                }
                verticalGap(element_style.padding.top);
            }
            const pushed_style = !void_element and style_stack_len < style_stack.len and name.len <= style_stack[0].name.len;
            if (pushed_style) {
                const box_index: ?usize = if (block_layout and block_box_count < block_boxes.len and (element_style.background != null or element_style.background_image != null or element_style.border_width != 0 or element_style.border_top_width != 0 or element_style.min_height != 0 or element_style.height != null)) block_box_count else null;
                style_stack[style_stack_len] = .{ .parent = active_style, .name_len = @intCast(name.len), .parent_indent = flow_indent, .parent_right_inset = flow_right_inset, .parent_font_scale = flow_font_scale, .parent_align_start = flow_align_start, .parent_align_width = flow_align_width, .box_index = box_index };
                @memcpy(style_stack[style_stack_len].name[0..name.len], name);
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
                        const marker: u8 = switch (element_style.list_style) { .circle => 'o', .square => '#', .disc => '*', .dash, .none, .decimal => '-' };
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
            if (!closing and equalIgnoreCase(name, "a") and link_count < links.len) {
                if (parseHref(tag)) |href| {
                    if (parseUrl(address[0..address_len])) |base| {
                        var link = Link{};
                        if (resolveLink(base, href, &link.url)) |link_len| {
                            link.url_len = link_len;
                            link.line = page_lines - 1;
                            link.valid = true;
                            links[link_count] = link;
                            link_count += 1;
                        }
                    }
                }
            }
            if (equalIgnoreCase(name, "img")) {
                var loaded_image = false;
                if (imageSource(tag)) |src| {
                    if (parseUrl(address[0..address_len])) |base| {
                        var resolved: [max_url]u8 = undefined;
                        if (resolveLink(base, src, &resolved)) |resolved_len| {
                            if (fetchImage(resolved[0..resolved_len])) |picture| {
                                var slot: ?usize = null;
                                for (inline_images, 0..) |image, image_index| if (image == null) {
                                    slot = image_index;
                                    break;
                                };
                                if (slot) |image_index| {
                                    const max_width = @max(1, columns * 6);
                                    const max_height: usize = 220;
                                    const dimensions = imageLayoutSize(tag, element_style, picture, max_width, max_height);
                                    inline_images[image_index] = picture;
                                    newline();
                                    const marker = page_len;
                                    appendPage(0xff);
                                    page_media_ids[marker] = @intCast(image_index);
                                    page_media_widths[marker] = dimensions.w;
                                    page_media_heights[marker] = dimensions.h;
                                    page_media_fit_modes[marker] = @intFromEnum(element_style.object_fit);
                                    page_line_heights[marker] = @intCast(@min(255, @max(10, dimensions.h)));
                                    newline();
                                    loaded_image = true;
                                } else media.release(picture);
                            }
                        }
                    }
                }
                if (!loaded_image) {
                    const alt = css.attribute(tag, "alt") orelse "[image unavailable]";
                    for (alt) |ch| appendVisible(ch, columns, &previous_space);
                }
            }
            if (equalIgnoreCase(name, "input")) renderInput(tag, columns, &previous_space);
            if (equalIgnoreCase(name, "canvas")) {
                const label = "[Canvas]";
                for (label) |ch| appendVisible(ch, columns, &previous_space);
            }
            rendering_style = active_style;
            i = end + 1;
            continue;
        }
        if (input[i] == '&') {
            if (htmlEntity(input, i)) |entity| {
                appendVisible(entity.ch, columns, &previous_space);
                i += entity.consumed;
                continue;
            }
        }
        if (preformatted and input[i] == '\n') {
            newline();
            previous_space = true;
        } else if (preformatted and input[i] == '\t') {
            for (0..4) |_| appendPage(' ');
            previous_space = true;
        } else if (preformatted and input[i] == ' ') {
            appendPage(' ');
            previous_space = true;
        } else appendVisible(input[i], columns, &previous_space);
        i += 1;
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
    var line: usize = 0;
    var offset: usize = 0;
    var y: u64 = 0;
    while (offset < page_len and line < wanted) {
        const end = std.mem.indexOfScalarPos(u8, page[0..page_len], offset, '\n') orelse page_len;
        y +|= @max(10, page_line_heights[offset]);
        offset = if (end < page_len) end + 1 else page_len;
        line += 1;
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
        const box_w = @min(available_w, css_width);
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

fn drawStyledLine(x: u64, y: u64, start: usize, text: []const u8, is_link: bool, normal_ink: u32, link_ink: u32, columns: usize, row_height: u8) void {
    if (text.len == 0) return;
    const layout = page_style_flags[start];
    const line_scale = @max(1, page_font_scales[start]);
    const cell_width = 6 * line_scale;
    var leading_spaces: usize = 0;
    while (leading_spaces < text.len and text[leading_spaces] == ' ') : (leading_spaces += 1) {}
    const content_length = text.len - leading_spaces;
    const align_start: usize = page_align_starts[start];
    const align_width = if (page_align_widths[start] == 0) columns else @as(usize, page_align_widths[start]);
    const spare = align_width -| content_length;
    const desired_start = align_start + (if ((layout & 16) != 0) spare / 2 else if ((layout & 32) != 0) spare else 0);
    const offset = desired_start -| leading_spaces;
    var extra_x: i64 = 0;
    for (text, 0..) |ch, column| {
        const index = start + column;
        const flags = page_style_flags[index];
        const scale = @max(1, page_font_scales[index]);
        const spacing: i64 = @as(i64, page_letter_spacing[index]) + (if (ch == ' ') @as(i64, page_word_spacing[index]) else 0);
        const px_signed = @as(i64, @intCast(x + @as(u64, @intCast(column + offset)) * cell_width)) + extra_x;
        const px = @as(u64, @intCast(@max(0, px_signed)));
        extra_x += spacing;
        if (column + offset >= columns) continue;
        if (ch == 0xff) {
            const image_index: usize = page_media_ids[index];
            if (image_index < inline_images.len) if (inline_images[image_index]) |picture| {
                const image_width = page_media_widths[index];
                const image_height = page_media_heights[index];
                if (page_media_fit_modes[index] == @intFromEnum(css.ObjectFit.contain)) {
                    media.drawFit(picture, px, y, image_width, image_height);
                } else if (page_media_fit_modes[index] == @intFromEnum(css.ObjectFit.cover)) {
                    media.drawCover(picture, px, y, image_width, image_height, false);
                } else media.drawScaled(picture, px, y, image_width, image_height);
            };
            continue;
        }
        if ((flags & 2) != 0) canvas.fillRect(px, y, 6 * scale, row_height, cssColor(page_backgrounds[index]));
        const ink = if ((flags & 1) != 0) cssColor(page_colors[index]) else if (is_link) link_ink else normal_ink;
        const character = [_]u8{ch};
        if ((flags & 128) != 0) font.drawTextItalic(px, y, &character, scale, ink) else font.drawText(px, y, &character, scale, ink);
        if ((flags & 4) != 0) font.drawText(px + scale, y, &character, scale, ink);
        if ((flags & 8) != 0) canvas.fillRect(px, y + 7 * scale, 5 * scale, scale, ink);
        if ((page_decorations[index] & 1) != 0) canvas.fillRect(px, y + 4 * scale, 5 * scale, scale, ink);
        if ((page_decorations[index] & 2) != 0) canvas.fillRect(px, y, 5 * scale, scale, ink);
    }
}

pub fn draw(win: s.Window) void {
    const fg = if (s.dark_theme) canvas.color(235, 235, 235) else canvas.color(32, 32, 32);
    const muted = if (s.dark_theme) canvas.color(155, 155, 155) else canvas.color(105, 105, 105);
    const accent = if (s.dark_theme) canvas.color(205, 205, 205) else canvas.color(55, 55, 55);
    const blue = canvas.color(127, 188, 255);
    const chrome = if (s.dark_theme) canvas.color(34, 34, 36) else canvas.color(238, 238, 238);
    const selected_chrome = if (s.dark_theme) canvas.color(63, 63, 65) else canvas.color(218, 218, 218);
    const address_bg = if (s.dark_theme) canvas.color(18, 18, 20) else canvas.color(255, 255, 255);
    const address_border = if (s.dark_theme) canvas.color(78, 78, 80) else canvas.color(195, 195, 195);
    for (0..browser_tab_count) |i| {
        const tx = win.x + 8 + @as(u64, @intCast(i)) * 156;
        const selected = i == active_browser_tab;
        canvas.fillRect(tx, win.y + 34, 150, 22, if (selected) selected_chrome else chrome);
        const label = tabTitle(i);
        font.drawText(tx + 6, win.y + 42, label[0..@min(label.len, 19)], 1, if (selected) accent else muted);
        font.drawText(tx + 134, win.y + 42, "x", 1, muted);
    }
    if (browser_tab_count < tab_capacity) font.drawText(win.x + 8 + @as(u64, @intCast(browser_tab_count)) * 156 + 10, win.y + 42, "+", 1, accent);
    const bar_y = win.y + 60;
    canvas.fillRect(win.x + 8, bar_y, 34, 24, chrome);
    canvas.fillRect(win.x + 44, bar_y, 30, 24, chrome);
    canvas.fillRect(win.x + 76, bar_y, 30, 24, chrome);
    font.drawText(win.x + 19, bar_y + 8, "<", 1, if (history_pos > 0) fg else muted);
    font.drawText(win.x + 53, bar_y + 8, ">", 1, if (history_pos + 1 < history_count) fg else muted);
    font.drawText(win.x + 87, bar_y + 8, "R", 1, fg);
    const address_x = win.x + 112;
    const address_w = win.w -| 240;
    canvas.fillRect(address_x, bar_y, address_w, 24, address_bg);
    canvas.fillRect(address_x, bar_y, address_w, 1, if (address_focused) accent else address_border);
    canvas.fillRect(address_x, bar_y + 23, address_w, 1, if (address_focused) accent else address_border);
    const columns: usize = @intCast(@max(1, (address_w -| 14) / 6));
    const visible_start = if (address_cursor > columns) address_cursor - columns else 0;
    const visible_end = @min(address_len, visible_start + columns);
    font.drawText(address_x + 7, bar_y + 8, address[visible_start..visible_end], 1, fg);
    if (address_len == 0) font.drawText(address_x + 7, bar_y + 8, "Search or enter a website", 1, muted);
    if (address_focused) {
        const caret = address_x + 7 + @as(u64, @intCast(address_cursor - visible_start)) * 6;
        canvas.fillRect(caret, bar_y + 6, 1, 11, accent);
    }
    canvas.fillRect(win.x + win.w -| 124, bar_y, 32, 24, chrome);
    font.drawText(win.x + win.w -| 118, bar_y + 8, "DL", 1, fg);
    canvas.fillRect(win.x + win.w -| 88, bar_y, 32, 24, if (history_panel) selected_chrome else chrome);
    font.drawText(win.x + win.w -| 82, bar_y + 8, "H", 1, fg);
    canvas.fillRect(win.x + win.w -| 54, bar_y, 46, 24, selected_chrome);
    font.drawText(win.x + win.w -| 43, bar_y + 8, "Go", 1, fg);
    if (message_len != 0) font.drawText(win.x + 18, win.y + 92, message[0..message_len], 1, muted);
    const content_y = win.y + 110;
    const content_x = win.x + 18;
    const content_pixels = win.w -| 36;
    const content_height = win.h -| 126;
    if (history_panel or downloads_panel) {
        const panel_x = win.x + 12;
        const panel_y = win.y + 110;
        const panel_w = win.w -| 24;
        const panel_h = win.h -| 122;
        canvas.fillRect(panel_x, panel_y, panel_w, panel_h, if (s.dark_theme) canvas.color(22, 22, 24) else canvas.color(255, 255, 255));
        font.drawText(panel_x + 10, panel_y + 8, if (history_panel) "History" else "Downloads", 1, accent);
        const count = if (history_panel) history_count else download_count;
        var row: usize = 0;
        while (row < count and row < (panel_h -| 34) / 20) : (row += 1) {
            const y = panel_y + 28 + @as(u64, @intCast(row * 20));
            if (row % 2 == 0) canvas.fillRect(panel_x + 4, y -| 2, panel_w -| 8, 18, if (s.dark_theme) canvas.color(35, 35, 37) else canvas.color(242, 242, 242));
            if (history_panel) {
                const index = history_count - 1 - row;
                font.drawText(panel_x + 10, y, history[index][0..history_lens[index]], 1, fg);
            } else {
                const index = download_count - 1 - row;
                font.drawText(panel_x + 10, y, downloads[index].name[0..downloads[index].name_len], 1, fg);
                var size_text: [24]u8 = undefined;
                const text = std.fmt.bufPrint(&size_text, "{d} bytes", .{downloads[index].size}) catch "";
                font.drawText(panel_x + panel_w -| 100, y, text, 1, muted);
            }
        }
        if (history_panel and count == 0) font.drawText(panel_x + 10, panel_y + 34, "No browsing history yet.", 1, muted);
        if (downloads_panel and download_count == 0) font.drawText(panel_x + 10, panel_y + 48, "No downloads yet.", 1, muted);
        return;
    }
    if (page_background_color) |background| canvas.fillRect(content_x, content_y, win.w -| 36, content_height, cssColor(background));
    drawBlockBoxes(content_x, content_y, content_pixels, content_height, page_scroll);
    if (arix_rendered) {
        const visible = @max(1, (content_height + 9) / 10);
        page_scroll = @min(page_scroll, page_lines -| visible);
        if (inline_images[0]) |picture| media.drawRegion(picture, content_x, content_y, page_scroll * 10, content_pixels, content_height);
        return;
    }
    if (page_len == 0) {
        font.drawText(content_x, content_y, "AetherOS Browser", 1, accent);
        font.drawText(content_x, content_y + 24, "Graphical HTML, CSS, images and SVG rendering.", 1, fg);
        font.drawText(content_x, content_y + 44, "JavaScript is disabled.", 1, muted);
        font.drawText(content_x, content_y + 74, "Try a website address or search query:", 1, muted);
        font.drawText(content_x, content_y + 82, "Google: google.com", 1, blue);
        font.drawText(content_x, content_y + 102, "YouTube: youtube.com", 1, blue);
        font.drawText(content_x, content_y + 122, "TikTok: tiktok.com", 1, blue);
        font.drawText(content_x, content_y + 164, "Enter an address above and press Enter or Go.", 1, muted);
        return;
    }
    var line_index = page_scroll;
    var offset: usize = 0;
    while (offset < page_len and line_index > 0) : (offset += 1) if (page[offset] == '\n') {
        line_index -= 1;
    };
    var draw_y = content_y;
    while (offset < page_len and draw_y +| 7 < content_y +| content_height) {
        const line_end = std.mem.indexOfScalarPos(u8, page[0..page_len], offset, '\n') orelse page_len;
        const line = page[offset..line_end];
        const row_height = @max(10, page_line_heights[offset]);
        const line_scale = @max(1, page_font_scales[offset]);
        const line_columns: usize = @intCast(@max(1, content_pixels / (6 * line_scale)));
        var is_link = false;
        for (links[0..link_count]) |link| if (link.valid and link.line == line_index) {
            is_link = true;
            break;
        };
        drawStyledLine(content_x, draw_y, offset, line, is_link, fg, blue, line_columns, row_height);
        draw_y +|= row_height;
        offset = if (line_end < page_len) line_end + 1 else page_len;
        line_index += 1;
    }
}
