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
const web_engine = @import("web_engine.zig");
const svg = @import("../graphics/svg.zig");
const media = @import("../graphics/media.zig");
const fat32 = @import("../fs/storage.zig");
const raster_image = @import("../graphics/image.zig");

const https_enabled = true;
const default_scheme = "http://";
const default_port: u16 = 80;
const max_url = web_engine.max_url;
pub const tab_capacity = 4;
const max_response = 64 * 1024 * 1024;
const max_resource_response = 1024 * 1024;
const max_page_response = 1024 * 1024;
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
    javascript: bool = false,
    attachment: bool = false,
    filename: [96]u8 = @splat(0),
    filename_len: usize = 0,
    location: [max_url]u8 = @splat(0),
    location_len: usize = 0,
};
var address: [max_url]u8 = @splat(0);
var address_len: usize = 0;
var address_cursor: usize = 0;
var address_focused = false;
var select_address = false;
var message: [128]u8 = @splat(0);
var message_len: usize = 0;
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

fn indexOfIgnoreCase(input: []const u8, needle: []const u8) ?usize {
    if (needle.len > input.len) return null;
    for (0..input.len - needle.len + 1) |start| {
        if (equalIgnoreCase(input[start..][0..needle.len], needle)) return start;
    }
    return null;
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
        .title = web_engine.page_title,
        .title_len = web_engine.page_title_len,
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
    web_engine.page_title = tab.title;
    web_engine.page_title_len = tab.title_len;
    history = tab.history;
    history_lens = tab.history_lens;
    history_count = tab.history_count;
    history_pos = tab.history_pos;
    address_focused = false;
    select_address = false;
}

fn clearCurrentPage() void {
    web_engine.clear();
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
    const tab = if (index == active_browser_tab) BrowserTab{ .title = web_engine.page_title, .title_len = web_engine.page_title_len, .url = address, .url_len = address_len } else browser_tabs[index];
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
            const end = std.mem.indexOfScalar(u8, value, ';') orelse value.len;
            const mime = std.mem.trim(u8, value[0..end], " \t");
            meta.javascript = equalIgnoreCase(mime, "text/javascript") or equalIgnoreCase(mime, "application/javascript");
        } else if (equalIgnoreCase(name, "content-disposition")) {
            meta.attachment = startsIgnoreCase(value, "attachment");
            if (indexOfIgnoreCase(value, "filename=")) |filename_at| {
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
    const columns: usize = @intCast(@max(1, (width -| 36) / 6));
    var inserted: usize = 0;
    if (meta.plain) {
        web_engine.renderPlain(body_buffer[0..body_len], columns);
    } else {
        const height = if (isActive()) s.windows[@intCast(s.active_window)].h else s.fb.height;
        inserted = web_engine.renderHtml(body_buffer[0..body_len], columns, @intCast(@min(height -| 126, 65535)), s.dark_theme, .{
            .resolve = resolvePageLink,
            .stylesheet = fetchPageStylesheet,
            .script = fetchPageScript,
            .image = fetchPageImage,
        });
    }
    panic_report.trace("browser: response body rendered");
    setMessage(if (partial) "Page is truncated; rendering supported HTML, CSS and media." else if (inserted != 0) "Page rendered with script content." else "Page rendered.");
    return false;
}

fn fetchResource(url_text: []const u8) ?[]const u8 {
    return fetchResourceOfType(url_text, false);
}

fn fetchResourceOfType(url_text: []const u8, script: bool) ?[]const u8 {
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
    if (script and !meta.javascript) return null;
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
    web_engine.clear();
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
    return web_engine.page_title[0..web_engine.page_title_len];
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
    const height = if (isActive()) s.windows[@intCast(s.active_window)].h else s.fb.height;
    web_engine.scroll(lines, height -| 126);
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
    if (x < win.x + 18 or y < win.y + 110) return;
    if (web_engine.linkAt(x - win.x - 18, y - win.y - 110, win.w -| 36, win.h -| 126)) |url| {
        var target: [max_url]u8 = undefined;
        @memcpy(target[0..url.len], url);
        navigate(target[0..url.len], true);
    }
}

fn resolveLink(page_url: Url, href: []const u8, out: *[max_url]u8) ?usize {
    const reference = std.mem.trim(u8, href, " \t\r\n");
    if (reference.len == 0 or reference[0] == '#' or reference.len > out.len) return null;
    const first_separator = std.mem.indexOfAny(u8, reference, ":/?#") orelse reference.len;
    if (first_separator < reference.len and reference[first_separator] == ':' and
        !startsIgnoreCase(reference, "http://") and !startsIgnoreCase(reference, "https://")) return null;
    var decoded: [max_url]u8 = @splat(0);
    var dlen: usize = 0;
    var i: usize = 0;
    while (i < reference.len and dlen < decoded.len) {
        if (reference[i] == '&') {
            if (web_engine.htmlEntity(reference, i)) |entity| {
                decoded[dlen] = entity.ch;
                dlen += 1;
                i += entity.consumed;
                continue;
            }
        }
        decoded[dlen] = reference[i];
        dlen += 1;
        i += 1;
    }
    const resolved = resolveRedirect(page_url, decoded[0..dlen], out) orelse return null;
    return resolved.len;
}

fn resolvePageLink(href: []const u8, out: *[max_url]u8) ?usize {
    const base = parseUrl(address[0..address_len]) orelse return null;
    return resolveLink(base, href, out);
}

fn fetchPageScript(src: []const u8) ?[]const u8 {
    const base = parseUrl(address[0..address_len]) orelse return null;
    var url: [max_url]u8 = undefined;
    const length = resolveLink(base, src, &url) orelse return null;
    const target = parseUrl(url[0..length]) orelse return null;
    if (target.secure != base.secure or target.port != base.port or
        !equalIgnoreCase(target.host[0..target.host_len], base.host[0..base.host_len])) return null;
    return fetchResourceOfType(url[0..length], true);
}

fn fetchPageStylesheet(href: []const u8) ?[]const u8 {
    var url: [max_url]u8 = undefined;
    const length = resolvePageLink(href, &url) orelse return null;
    return fetchResource(url[0..length]);
}

fn fetchPageImage(src: []const u8) ?media.Picture {
    var url: [max_url]u8 = undefined;
    const length = resolvePageLink(src, &url) orelse return null;
    return fetchImage(url[0..length]);
}

pub fn draw(win: s.Window) void {
    const fg = if (s.dark_theme) canvas.color(235, 235, 235) else canvas.color(32, 32, 32);
    const muted = if (s.dark_theme) canvas.color(155, 155, 155) else canvas.color(105, 105, 105);
    const accent = if (s.dark_theme) canvas.color(205, 205, 205) else canvas.color(55, 55, 55);
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
    if (!web_engine.hasPage()) {
        font.drawText(content_x, content_y, "AetherOS Browser", 1, accent);
        font.drawText(content_x, content_y + 24, "Graphical HTML, CSS, images and SVG rendering.", 1, fg);
        font.drawText(content_x, content_y + 44, "Limited script support.", 1, muted);
        font.drawText(content_x, content_y + 70, "Enter an address or search query above.", 1, muted);
        return;
    }
    web_engine.draw(content_x, content_y, content_pixels, content_height, s.dark_theme);
}
