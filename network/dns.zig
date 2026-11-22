//! Poll-driven DNS resolver. Supports recursive IPv4 A queries, EDNS0, CNAME
//! chains, retransmission, and DNS-over-TCP fallback for truncated replies.
const stack = @import("stack.zig");
const state = @import("../system/state.zig");
const entropy_source = @import("entropy.zig");
const panic_report = @import("../system/panic.zig");

const Name = [254]u8;
const max_packet = 1232;
const cache_capacity = 8;

pub const Status = enum { idle, pending, resolved, failed };
const CacheEntry = struct {
    valid: bool = false,
    name: Name = @splat(0),
    name_len: u8 = 0,
    address: [4]u8 = .{ 0, 0, 0, 0 },
    expires: u64 = 0,
};
const DecodedName = struct { length: usize, consumed: usize };
const Alias = struct { owner: Name, owner_len: usize, target: Name, target_len: usize, ttl: u32 };
const AddressRecord = struct { owner: Name, owner_len: usize, address: [4]u8, ttl: u32 };

var status_value: Status = .idle;
var query_name: Name = @splat(0);
var query_name_len: usize = 0;
var dns_id: u16 = 0;
var udp_id: ?u8 = null;
var tcp_id: ?u8 = null;
var query: [512]u8 = @splat(0);
var query_len: usize = 0;
var deadline: u64 = 0;
var retries: u8 = 0;
var dns_server_index: u8 = 0;
var resolved_address: [4]u8 = .{ 0, 0, 0, 0 };
var cache: [cache_capacity]CacheEntry = @splat(.{});
var cache_cursor: usize = 0;
var tcp_stage: enum { none, connecting, sending, receiving } = .none;
var tcp_request: [514]u8 = @splat(0);
var tcp_request_len: usize = 0;
var tcp_response: [4096]u8 = @splat(0);
var tcp_response_len: usize = 0;
var tcp_expected_len: usize = 0;

fn get16(data: []const u8, offset: usize) u16 {
    return (@as(u16, data[offset]) << 8) | data[offset + 1];
}
fn get32(data: []const u8, offset: usize) u32 {
    return (@as(u32, data[offset]) << 24) | (@as(u32, data[offset + 1]) << 16) | (@as(u32, data[offset + 2]) << 8) | data[offset + 3];
}
fn put16(data: []u8, offset: usize, value: u16) void {
    data[offset] = @truncate(value >> 8);
    data[offset + 1] = @truncate(value);
}
fn equalName(a: []const u8, b: []const u8) bool {
    return a.len == b.len and @import("std").mem.eql(u8, a, b);
}
fn lowerAscii(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + ('a' - 'A') else c;
}

fn encodeQuestion(host: []const u8, output: []u8) ?usize {
    if (host.len == 0 or host.len > 253) return null;
    var out: usize = 0;
    var label_len: usize = 0;
    output[out] = 0;
    out += 1;
    for (host, 0..) |raw, i| {
        const c = lowerAscii(raw);
        if (c == '.') {
            if (label_len == 0 or label_len > 63) {
                if (i == host.len - 1 and label_len != 0) break;
                return null;
            }
            if (output[out - 1] == '-') return null;
            output[out - label_len - 1] = @intCast(label_len);
            label_len = 0;
            if (i == host.len - 1) break;
            if (out >= output.len) return null;
            output[out] = 0;
            out += 1;
            continue;
        }
        if (!((c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '-')) return null;
        if (label_len == 0 and c == '-') return null;
        if (i + 1 == host.len and c == '-') return null;
        if (out >= output.len) return null;
        output[out] = c;
        out += 1;
        label_len += 1;
        if (label_len > 63) return null;
    }
    if (label_len == 0) return null;
    output[out - label_len - 1] = @intCast(label_len);
    if (out >= output.len) return null;
    output[out] = 0;
    return out + 1;
}

fn makeQuery() bool {
    var qname: [256]u8 = @splat(0);
    const qname_len = encodeQuestion(query_name[0..query_name_len], &qname) orelse return false;
    @memset(&query, 0);
    put16(&query, 0, dns_id);
    put16(&query, 2, 0x0100); // Standard query, recursion desired.
    put16(&query, 4, 1);
    put16(&query, 10, 1); // One EDNS0 OPT record.
    var cursor: usize = 12;
    @memcpy(query[cursor .. cursor + qname_len], qname[0..qname_len]);
    cursor += qname_len;
    put16(&query, cursor, 1); // A
    put16(&query, cursor + 2, 1); // IN
    cursor += 4;
    query[cursor] = 0; // Root owner name for OPT.
    put16(&query, cursor + 1, 41);
    put16(&query, cursor + 3, max_packet); // Advertised UDP payload size.
    @memset(query[cursor + 5 .. cursor + 11], 0); // extended RCODE/version/flags/RDLEN
    query_len = cursor + 11;
    return true;
}

fn sendUdpQuery() bool {
    const id = udp_id orelse return false;
    return stack.udpSendTo(id, currentServer(), 53, query[0..query_len]);
}

fn currentServer() [4]u8 {
    return if (dns_server_index == 0) state.ipv4_dns else state.ipv4_dns_secondary;
}

fn isZeroAddress(address_value: [4]u8) bool {
    return address_value[0] == 0 and address_value[1] == 0 and address_value[2] == 0 and address_value[3] == 0;
}

fn closeTransports() void {
    if (udp_id) |id| stack.udpClose(id);
    if (tcp_id) |id| stack.tcpClose(id);
    udp_id = null;
    tcp_id = null;
    tcp_stage = .none;
}

fn fail() void {
    closeTransports();
    status_value = .failed;
}

fn saveCache(ttl: u32) void {
    if (ttl == 0) return;
    cache[cache_cursor] = .{
        .valid = true,
        .name = query_name,
        .name_len = @intCast(query_name_len),
        .address = resolved_address,
        .expires = state.uptime() + @as(u64, ttl) * 100,
    };
    cache_cursor = (cache_cursor + 1) % cache.len;
}

fn parseResponse(packet: []const u8) enum { found, truncated, failed } {
    if (packet.len < 12 or get16(packet, 0) != dns_id) return .failed;
    const flags = get16(packet, 2);
    if ((flags & 0x8000) == 0 or (flags & 0x7800) != 0 or get16(packet, 4) != 1) return .failed;
    if ((flags & 0x0200) != 0) return .truncated;
    if ((flags & 0x000f) != 0) return .failed;

    var cursor: usize = 12;
    var question_name: Name = @splat(0);
    const decoded_question = decodeName(packet, cursor, &question_name) orelse return .failed;
    cursor += decoded_question.consumed;
    if (cursor + 4 > packet.len or !equalName(question_name[0..decoded_question.length], query_name[0..query_name_len]) or get16(packet, cursor) != 1 or get16(packet, cursor + 2) != 1) return .failed;
    cursor += 4;

    var aliases: [16]Alias = undefined;
    var alias_count: usize = 0;
    var addresses: [32]AddressRecord = undefined;
    var address_count: usize = 0;
    const record_count: usize = @as(usize, get16(packet, 6)) + get16(packet, 8) + get16(packet, 10);
    if (record_count > 128) return .failed;
    for (0..record_count) |_| {
        var owner: Name = @splat(0);
        const decoded_owner = decodeName(packet, cursor, &owner) orelse return .failed;
        cursor += decoded_owner.consumed;
        if (cursor + 10 > packet.len) return .failed;
        const kind = get16(packet, cursor);
        const class = get16(packet, cursor + 2);
        const ttl = get32(packet, cursor + 4);
        const data_len: usize = get16(packet, cursor + 8);
        cursor += 10;
        if (data_len > packet.len - cursor) return .failed;
        if (class == 1 and kind == 1 and data_len == 4 and address_count < addresses.len) {
            var record_address: [4]u8 = undefined;
            @memcpy(&record_address, packet[cursor .. cursor + 4]);
            addresses[address_count] = .{ .owner = owner, .owner_len = decoded_owner.length, .address = record_address, .ttl = ttl };
            address_count += 1;
        } else if (class == 1 and kind == 5 and alias_count < aliases.len) {
            var target: Name = @splat(0);
            const decoded_target = decodeName(packet, cursor, &target) orelse return .failed;
            if (decoded_target.consumed > data_len) return .failed;
            aliases[alias_count] = .{ .owner = owner, .owner_len = decoded_owner.length, .target = target, .target_len = decoded_target.length, .ttl = ttl };
            alias_count += 1;
        }
        cursor += data_len;
    }

    var current = query_name;
    var current_len = query_name_len;
    var ttl: u32 = 0xffffffff;
    for (0..9) |_| {
        for (addresses[0..address_count]) |record| {
            if (equalName(record.owner[0..record.owner_len], current[0..current_len])) {
                resolved_address = record.address;
                ttl = @min(ttl, record.ttl);
                saveCache(ttl);
                return .found;
            }
        }
        var found_alias = false;
        for (aliases[0..alias_count]) |alias| {
            if (!equalName(alias.owner[0..alias.owner_len], current[0..current_len])) continue;
            current = alias.target;
            current_len = alias.target_len;
            ttl = @min(ttl, alias.ttl);
            found_alias = true;
            break;
        }
        if (!found_alias) break;
    }
    return .failed;
}

fn decodeName(packet: []const u8, name_offset: usize, output: *Name) ?DecodedName {
    var position = name_offset;
    var consumed: usize = 0;
    var out_len: usize = 0;
    var jumped = false;
    var jumps: u8 = 0;
    while (true) {
        if (position >= packet.len) return null;
        const length = packet[position];
        if ((length & 0xc0) == 0xc0) {
            if (position + 1 >= packet.len or jumps >= 16) return null;
            const pointer = (@as(usize, length & 0x3f) << 8) | packet[position + 1];
            if (pointer >= position) return null; // RFC 1035 compression references an earlier name byte.
            if (!jumped) consumed += 2;
            jumped = true;
            jumps += 1;
            position = pointer;
            continue;
        }
        if ((length & 0xc0) != 0 or length > 63) return null;
        position += 1;
        if (!jumped) consumed += 1;
        if (length == 0) break;
        if (position + length > packet.len or out_len + length + @intFromBool(out_len != 0) >= output.len) return null;
        if (out_len != 0) {
            output[out_len] = '.';
            out_len += 1;
        }
        for (packet[position .. position + length]) |c| {
            if (c == 0 or c >= 0x80) return null;
            output[out_len] = lowerAscii(c);
            out_len += 1;
        }
        if (!jumped) consumed += length;
        position += length;
    }
    return .{ .length = out_len, .consumed = consumed };
}

fn beginTcpFallback() void {
    if (udp_id) |id| stack.udpClose(id);
    udp_id = null;
    const id = stack.tcpOpen(0) orelse {
        fail();
        return;
    };
    tcp_id = id;
    tcp_request[0] = @truncate(query_len >> 8);
    tcp_request[1] = @truncate(query_len);
    @memcpy(tcp_request[2 .. 2 + query_len], query[0..query_len]);
    tcp_request_len = query_len + 2;
    tcp_response_len = 0;
    tcp_expected_len = 0;
    tcp_stage = .connecting;
    deadline = state.uptime() + 1500;
    if (!stack.tcpConnect(id, currentServer(), 53)) fail();
}

fn finishParse(packet: []const u8) void {
    switch (parseResponse(packet)) {
        .found => {
            closeTransports();
            status_value = .resolved;
        },
        .truncated => beginTcpFallback(),
        .failed => fail(),
    }
}

pub fn start(host: []const u8) bool {
    if (!state.network_configured) return false;
    var normalized: Name = @splat(0);
    var normalized_len: usize = 0;
    for (host) |raw| {
        if (normalized_len >= 253) return false;
        const c = lowerAscii(raw);
        if (!((c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '.' or c == '-')) return false;
        normalized[normalized_len] = c;
        normalized_len += 1;
    }
    if (normalized_len != 0 and normalized[normalized_len - 1] == '.') normalized_len -= 1;
    if (normalized_len == 0) return false;
    if (status_value == .pending) return equalName(normalized[0..normalized_len], query_name[0..query_name_len]);
    dns_server_index = if (isZeroAddress(state.ipv4_dns)) 1 else 0;
    if (isZeroAddress(currentServer())) return false;
    query_name = normalized;
    query_name_len = normalized_len;
    var encoded: [256]u8 = @splat(0);
    if (encodeQuestion(query_name[0..query_name_len], &encoded) == null) return false;
    for (&cache) |entry| {
        if (entry.valid and state.uptime() < entry.expires and equalName(query_name[0..query_name_len], entry.name[0..entry.name_len])) {
            resolved_address = entry.address;
            status_value = .resolved;
            return true;
        }
    }
    var random_material: [4]u8 = undefined;
    if (!entropy_source.fill(&random_material)) return false;
    dns_id = get16(&random_material, 0);
    if (!makeQuery()) return false;
    const port_offset: usize = get16(&random_material, 2) % 16384;
    var attempt: usize = 0;
    while (attempt < 16 and udp_id == null) : (attempt += 1) {
        const port = 49152 + @as(u16, @intCast((port_offset + attempt) % 16384));
        udp_id = stack.udpOpen(port);
    }
    if (udp_id == null) return false;
    status_value = .pending;
    retries = 0;
    deadline = state.uptime();
    tcp_stage = .none;
    _ = sendUdpQuery();
    deadline = state.uptime() + 100;
    return true;
}

pub fn poll() void {
    if (status_value != .pending) return;
    if (tcp_stage == .none) {
        if (udp_id) |id| {
            if (stack.udpError(id) != null) {
                fail();
                return;
            }
            var packet: [max_packet]u8 = @splat(0);
            if (stack.udpReceive(id, &packet)) |received| {
                const server = currentServer();
                panic_report.trace("DNS: UDP reply delivered to resolver");
                if (received.port == 53 and received.address[0] == server[0] and received.address[1] == server[1] and received.address[2] == server[2] and received.address[3] == server[3]) {
                    if (received.length < 2 or get16(&packet, 0) != dns_id) {
                        panic_report.trace("DNS: reply transaction ID mismatch");
                        return;
                    }
                    if (received.truncated) {
                        beginTcpFallback();
                        return;
                    }
                    finishParse(packet[0..received.length]);
                    return;
                } else {
                    panic_report.trace("DNS: reply source or port mismatch");
                }
            }
        }
        if (state.uptime() >= deadline) {
            if (retries >= 2 and dns_server_index == 0 and !isZeroAddress(state.ipv4_dns_secondary)) {
                dns_server_index = 1;
                retries = 0;
                _ = sendUdpQuery();
                deadline = state.uptime() + 100;
                return;
            }
            if (retries >= 4) {
                fail();
                return;
            }
            retries += 1;
            _ = sendUdpQuery();
            deadline = state.uptime() + (@as(u64, 100) << @min(retries, 3));
        }
        return;
    }

    const id = tcp_id orelse {
        fail();
        return;
    };
    if (stack.tcpError(id) != null) {
        fail();
        return;
    }
    if (state.uptime() >= deadline) {
        fail();
        return;
    }
    switch (tcp_stage) {
        .connecting => if (stack.tcpConnected(id)) {
            tcp_stage = .sending;
        } else return,
        .sending => if (stack.tcpSend(id, tcp_request[0..tcp_request_len])) {
            tcp_stage = .receiving;
        } else return,
        .receiving => {},
        .none => return,
    }
    if (tcp_stage != .receiving) return;
    var chunk: [512]u8 = undefined;
    while (stack.tcpReceive(id, &chunk)) |length| {
        if (tcp_response_len + length > tcp_response.len) {
            fail();
            return;
        }
        @memcpy(tcp_response[tcp_response_len .. tcp_response_len + length], chunk[0..length]);
        tcp_response_len += length;
        if (tcp_expected_len == 0 and tcp_response_len >= 2) tcp_expected_len = get16(&tcp_response, 0);
        if (tcp_expected_len != 0 and tcp_response_len >= tcp_expected_len + 2) {
            finishParse(tcp_response[2 .. tcp_expected_len + 2]);
            return;
        }
    }
}

pub fn status() Status {
    return status_value;
}

pub fn address() ?[4]u8 {
    if (status_value != .resolved) return null;
    return resolved_address;
}
