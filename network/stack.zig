//! Small polling IPv4/ARP socket layer for the built-in kernel apps.
//! This is an in-kernel API, not a POSIX userspace socket implementation.
const e1000 = @import("../drivers/e1000.zig");
const entropy_source = @import("entropy.zig");
const s = @import("../system/state.zig");
const std = @import("std");

const max_sockets = 4;
const ipv4_default_mtu = 1500;
const tcp_mss = 536;
const tcp_buffer_size = 4096;
const tcp_initial_rto_ticks: u64 = 100;
const tcp_max_rto_ticks: u64 = 6000;
const udp_queue_depth = 4;
const fragment_slots_count = 4;
const fragment_limit = 8192;
const max_udp_payload = fragment_limit - 8;
const max_udp_send_payload = ipv4_default_mtu - 20 - 8;
const IpAddress = [4]u8;
const MacAddress = [6]u8;

const Datagram = struct {
    payload: [max_udp_payload]u8 = @splat(0),
    length: usize = 0,
    ready: bool = false,
    address: IpAddress = .{ 0, 0, 0, 0 },
    port: u16 = 0,
};
pub const UdpResult = struct { length: usize, datagram_length: usize, truncated: bool, address: IpAddress, port: u16 };
pub const NetworkError = enum { none, network_unreachable, host_unreachable, port_unreachable, fragmentation_needed, ttl_expired, protocol_unreachable, parameter_problem, administrative_prohibited, reset, timeout };
const UdpSocket = struct {
    open: bool = false,
    port: u16 = 0,
    network_error: NetworkError = .none,
    received: [udp_queue_depth]Datagram = @splat(.{}),
    received_head: usize = 0,
    received_count: usize = 0,
};
const TcpState = enum { closed, listen, syn_sent, syn_received, established, fin_wait_1, fin_wait_2, closing, close_wait, last_ack, time_wait };
const TcpSocket = struct {
    open: bool = false,
    state: TcpState = .closed,
    local_port: u16 = 0,
    listener: u8 = 0xff,
    remote_port: u16 = 0,
    remote_ip: IpAddress = .{ 0, 0, 0, 0 },
    send_sequence: u32 = 0,
    send_unacknowledged: u32 = 0,
    receive_sequence: u32 = 0,
    peer_window: u16 = 0,
    peer_mss: u16 = tcp_mss,
    received: [tcp_buffer_size]u8 = @splat(0),
    received_len: usize = 0,
    transmit: [tcp_buffer_size]u8 = @splat(0),
    transmit_len: usize = 0,
    in_flight: usize = 0,
    syn_unacknowledged: bool = false,
    fin_unacknowledged: bool = false,
    close_requested: bool = false,
    retries: u8 = 0,
    deadline: u64 = 0,
    rto_ticks: u64 = tcp_initial_rto_ticks,
    rtt_started_tick: u64 = 0,
    rtt_sample_valid: bool = false,
    rtt_initialized: bool = false,
    smoothed_rtt: u64 = 0,
    rtt_variance: u64 = 0,
    congestion_window: u32 = tcp_mss,
    slow_start_threshold: u32 = 65535,
    duplicate_acks: u8 = 0,
    recovery_sequence: u32 = 0,
    in_fast_recovery: bool = false,
    last_advertised_window: u16 = 0,
    persist_deadline: u64 = 0,
    persist_interval: u64 = 0,
    network_error: NetworkError = .none,
    syn_transmitted: bool = false,
    ack_pending: bool = false,
    accepted: [max_sockets]u8 = @splat(0),
    accepted_head: usize = 0,
    accepted_count: usize = 0,
};
const Neighbor = struct { ip: IpAddress, mac: MacAddress, expires: u64 = 0, valid: bool = false };
const FragmentSlot = struct {
    used: bool = false,
    source: IpAddress = .{ 0, 0, 0, 0 },
    destination: IpAddress = .{ 0, 0, 0, 0 },
    identification: u16 = 0,
    protocol: u8 = 0,
    data: [fragment_limit]u8 = @splat(0),
    present: [fragment_limit / 8]u8 = @splat(0),
    received: usize = 0,
    total_len: usize = 0,
    has_final: bool = false,
    expires: u64 = 0,
};

var udp_sockets: [max_sockets]UdpSocket = @splat(.{});
var tcp_sockets: [max_sockets]TcpSocket = @splat(.{});
var neighbors: [8]Neighbor = @splat(.{ .ip = .{ 0, 0, 0, 0 }, .mac = .{ 0, 0, 0, 0, 0, 0 } });
var fragments: [fragment_slots_count]FragmentSlot = @splat(.{});
var fragment_cursor: usize = 0;
var neighbor_next: usize = 0;
var pending_arp: IpAddress = .{ 0, 0, 0, 0 };
var arp_retry_tick: u64 = 0;
var next_ephemeral_port: u16 = 49152;
var next_udp_port: u16 = 49152;
var tcp_ephemeral_seeded = false;
var udp_ephemeral_seeded = false;

fn get16(data: []const u8, offset: usize) u16 {
    return (@as(u16, data[offset]) << 8) | data[offset + 1];
}
fn get32(data: []const u8, offset: usize) u32 {
    return (@as(u32, data[offset]) << 24) | (@as(u32, data[offset + 1]) << 16) | (@as(u32, data[offset + 2]) << 8) | data[offset + 3];
}
fn randomU32() ?u32 {
    var bytes: [4]u8 = undefined;
    if (!entropy_source.fill(&bytes)) return null;
    return get32(&bytes, 0);
}
fn put16(data: []u8, offset: usize, value: u16) void {
    data[offset] = @truncate(value >> 8);
    data[offset + 1] = @truncate(value);
}
fn put32(data: []u8, offset: usize, value: u32) void {
    data[offset] = @truncate(value >> 24);
    data[offset + 1] = @truncate(value >> 16);
    data[offset + 2] = @truncate(value >> 8);
    data[offset + 3] = @truncate(value);
}
fn checksum(data: []const u8) u16 {
    var sum: u32 = 0;
    var i: usize = 0;
    while (i + 1 < data.len) : (i += 2) sum += (@as(u32, data[i]) << 8) | data[i + 1];
    if (i < data.len) sum += @as(u32, data[i]) << 8;
    while (sum >> 16 != 0) sum = (sum & 0xffff) + (sum >> 16);
    return ~@as(u16, @truncate(sum));
}
fn transportChecksum(source: IpAddress, destination: IpAddress, protocol: u8, payload: []const u8) u16 {
    var sum: u32 = 0;
    const addresses = [_]u8{ source[0], source[1], source[2], source[3], destination[0], destination[1], destination[2], destination[3] };
    for (addresses, 0..) |byte, i| {
        if ((i & 1) == 0) sum += @as(u32, byte) << 8 else sum += byte;
    }
    sum += protocol;
    sum += @as(u32, @intCast(payload.len));
    var i: usize = 0;
    while (i + 1 < payload.len) : (i += 2) sum += (@as(u32, payload[i]) << 8) | payload[i + 1];
    if (i < payload.len) sum += @as(u32, payload[i]) << 8;
    while (sum >> 16 != 0) sum = (sum & 0xffff) + (sum >> 16);
    return ~@as(u16, @truncate(sum));
}
fn ipEqual(a: IpAddress, b: IpAddress) bool {
    return a[0] == b[0] and a[1] == b[1] and a[2] == b[2] and a[3] == b[3];
}
fn isZero(ip: IpAddress) bool {
    return ip[0] == 0 and ip[1] == 0 and ip[2] == 0 and ip[3] == 0;
}

fn interfaceMtu() usize {
    return @min(@as(usize, 1500), @max(@as(usize, 68), s.ipv4_mtu));
}

fn localTcpMss() u16 {
    return @intCast(@min(@as(usize, tcp_mss), interfaceMtu() - 40));
}

fn effectiveTcpMss(socket: *const TcpSocket) u16 {
    return @max(@as(u16, 1), @min(socket.peer_mss, localTcpMss()));
}

fn subnetPrefixLength(mask: IpAddress) u8 {
    var count: u8 = 0;
    var zero_seen = false;
    for (mask) |octet| {
        var bit: u8 = 0x80;
        while (bit != 0) : (bit >>= 1) {
            if ((octet & bit) != 0) {
                if (zero_seen) return 0;
                count += 1;
            } else zero_seen = true;
        }
    }
    return count;
}

fn routeFor(ip: IpAddress) IpAddress {
    var best_prefix: u8 = 0;
    var best_route: ?s.Ipv4Route = null;
    var local = true;
    for (0..4) |i| if ((ip[i] & s.ipv4_subnet[i]) != (s.ipv4_address[i] & s.ipv4_subnet[i])) {
        local = false;
    };
    if (local) {
        best_prefix = subnetPrefixLength(s.ipv4_subnet);
        best_route = .{ .destination = .{ 0, 0, 0, 0 }, .prefix_length = best_prefix, .gateway = .{ 0, 0, 0, 0 } };
    }
    for (s.ipv4_routes[0..s.ipv4_route_count]) |route| {
        if (route.prefix_length > 32 or route.prefix_length < best_prefix or (route.prefix_length == best_prefix and best_route != null)) continue;
        const whole_bytes: usize = route.prefix_length / 8;
        const remaining_bits: u3 = @intCast(route.prefix_length % 8);
        var matches = true;
        for (0..whole_bytes) |i| if (ip[i] != route.destination[i]) {
            matches = false;
        };
        if (remaining_bits != 0) {
            const shift: u3 = @intCast(8 - @as(u8, remaining_bits));
            const mask: u8 = @as(u8, 0xff) << shift;
            if ((ip[whole_bytes] & mask) != (route.destination[whole_bytes] & mask)) matches = false;
        }
        if (matches) {
            best_prefix = route.prefix_length;
            best_route = route;
        }
    }
    if (best_route) |route| return if (isZero(route.gateway)) ip else route.gateway;
    return s.ipv4_gateway;
}

fn isIpv4Broadcast(ip: IpAddress) bool {
    if (ipEqual(ip, .{ 255, 255, 255, 255 })) return true;
    var directed: IpAddress = undefined;
    for (0..4) |i| directed[i] = (s.ipv4_address[i] & s.ipv4_subnet[i]) | ~s.ipv4_subnet[i];
    return !ipEqual(directed, s.ipv4_address) and ipEqual(ip, directed);
}

fn lookupNeighbor(ip: IpAddress) ?MacAddress {
    for (&neighbors) |*entry| {
        if (entry.valid and s.uptime() >= entry.expires) entry.valid = false;
        if (entry.valid and ipEqual(entry.ip, ip)) return entry.mac;
    }
    return null;
}

fn learnNeighbor(ip: IpAddress, mac: MacAddress) void {
    if (isZero(ip) or (mac[0] & 1) != 0) return;
    for (&neighbors) |*entry| {
        if (entry.valid and ipEqual(entry.ip, ip)) {
            entry.mac = mac;
            entry.expires = s.uptime() + 6000;
            return;
        }
    }
    neighbors[neighbor_next] = .{ .ip = ip, .mac = mac, .expires = s.uptime() + 6000, .valid = true };
    neighbor_next = (neighbor_next + 1) % neighbors.len;
}

fn sendArpRequest(ip: IpAddress) void {
    var frame: [42]u8 = @splat(0);
    const mac = e1000.macAddress();
    @memset(frame[0..6], 0xff);
    @memcpy(frame[6..12], &mac);
    put16(&frame, 12, 0x0806);
    put16(&frame, 14, 1);
    put16(&frame, 16, 0x0800);
    frame[18] = 6;
    frame[19] = 4;
    put16(&frame, 20, 1);
    @memcpy(frame[22..28], &mac);
    @memcpy(frame[28..32], &s.ipv4_address);
    @memcpy(frame[38..42], &ip);
    _ = e1000.sendEthernetFrame(&frame);
    pending_arp = ip;
    arp_retry_tick = s.uptime() + 100;
}

fn resolve(ip: IpAddress) ?MacAddress {
    if (lookupNeighbor(ip)) |mac| return mac;
    if (!ipEqual(pending_arp, ip) or s.uptime() >= arp_retry_tick) sendArpRequest(ip);
    return null;
}

fn sendIpv4(destination: IpAddress, protocol: u8, payload: []const u8) bool {
    if (!s.network_configured or payload.len > interfaceMtu() - 20) return false;
    const next_hop = routeFor(destination);
    if (isZero(next_hop)) return false;
    const destination_mac: MacAddress = if (isIpv4Broadcast(destination)) @splat(0xff) else resolve(next_hop) orelse return false;
    var frame: [14 + 20 + 1480]u8 = @splat(0);
    const mac = e1000.macAddress();
    @memcpy(frame[0..6], &destination_mac);
    @memcpy(frame[6..12], &mac);
    put16(&frame, 12, 0x0800);
    const ip = 14;
    frame[ip] = 0x45;
    put16(&frame, ip + 2, @intCast(20 + payload.len));
    put16(&frame, ip + 4, @truncate(s.uptime()));
    put16(&frame, ip + 6, 0x4000);
    frame[ip + 8] = 64;
    frame[ip + 9] = protocol;
    @memcpy(frame[ip + 12 .. ip + 16], &s.ipv4_address);
    @memcpy(frame[ip + 16 .. ip + 20], &destination);
    put16(&frame, ip + 10, checksum(frame[ip .. ip + 20]));
    @memcpy(frame[ip + 20 .. ip + 20 + payload.len], payload);
    return e1000.sendEthernetFrame(frame[0 .. ip + 20 + payload.len]);
}

fn seqAfter(a: u32, b: u32) bool {
    return @as(i32, @bitCast(a -% b)) > 0;
}

fn seqBefore(a: u32, b: u32) bool {
    return seqAfter(b, a);
}

fn seqBeforeOrEqual(a: u32, b: u32) bool {
    return !seqAfter(a, b);
}

fn sequenceAcceptable(sequence: u32, length: usize, next: u32, window: u16) bool {
    if (window == 0) return length == 0 and sequence == next;
    const right_edge = next +% window;
    if (length == 0) return !seqBefore(sequence, next) and seqBefore(sequence, right_edge);
    const last = sequence +% @as(u32, @intCast(length - 1));
    return (!seqBefore(sequence, next) and seqBefore(sequence, right_edge)) or
        (!seqBefore(last, next) and seqBefore(last, right_edge));
}

fn updateRtt(socket: *TcpSocket, sample: u64) void {
    const measured = @max(@as(u64, 1), sample);
    if (!socket.rtt_initialized) {
        socket.smoothed_rtt = measured;
        socket.rtt_variance = @max(@as(u64, 1), measured / 2);
        socket.rtt_initialized = true;
    } else {
        const delta = if (socket.smoothed_rtt > measured) socket.smoothed_rtt - measured else measured - socket.smoothed_rtt;
        socket.rtt_variance = (3 * socket.rtt_variance + delta) / 4;
        socket.smoothed_rtt = (7 * socket.smoothed_rtt + measured) / 8;
    }
    socket.rto_ticks = @min(tcp_max_rto_ticks, @max(tcp_initial_rto_ticks, socket.smoothed_rtt + @max(@as(u64, 1), 4 * socket.rtt_variance)));
}

fn congestionAck(socket: *TcpSocket, acknowledged: u32) void {
    if (acknowledged == 0) return;
    const mss: u32 = effectiveTcpMss(socket);
    if (socket.in_fast_recovery) {
        if (!seqBefore(socket.send_unacknowledged, socket.recovery_sequence)) {
            socket.congestion_window = socket.slow_start_threshold;
            socket.in_fast_recovery = false;
            socket.duplicate_acks = 0;
        }
    } else if (socket.congestion_window < socket.slow_start_threshold) {
        socket.congestion_window +|= @min(acknowledged, mss);
    } else {
        const increase = @max(@as(u32, 1), (mss * @min(acknowledged, mss)) / @max(@as(u32, 1), socket.congestion_window));
        socket.congestion_window +|= increase;
    }
}

fn congestionTimeout(socket: *TcpSocket) void {
    const mss: u32 = effectiveTcpMss(socket);
    socket.slow_start_threshold = @max(2 * mss, @as(u32, @intCast(socket.in_flight / 2)));
    socket.congestion_window = mss;
    socket.duplicate_acks = 0;
    socket.in_fast_recovery = false;
}

fn sendReset(source: IpAddress, source_port: u16, destination_port: u16, sequence: u32, acknowledgment: u32, flags: u8, payload_len: usize) void {
    if (isZero(source) or isIpv4Broadcast(source)) return;
    var segment: [20]u8 = @splat(0);
    put16(&segment, 0, destination_port);
    put16(&segment, 2, source_port);
    if ((flags & 0x10) != 0) {
        put32(&segment, 4, acknowledgment);
        segment[13] = 0x04;
    } else {
        const consumed: u32 = @intCast(payload_len + @as(usize, @intFromBool((flags & 0x02) != 0)) + @as(usize, @intFromBool((flags & 0x01) != 0)));
        put32(&segment, 8, sequence +% consumed);
        segment[13] = 0x14;
    }
    segment[12] = 5 << 4;
    put16(&segment, 16, transportChecksum(s.ipv4_address, source, 6, &segment));
    _ = sendIpv4(source, 6, &segment);
}

fn receiveWindow(socket: *const TcpSocket) u16 {
    return @intCast(socket.received.len - socket.received_len);
}

fn sendTcpAt(socket: *TcpSocket, sequence: u32, flags: u8, payload: []const u8) bool {
    if (payload.len > localTcpMss()) return false;
    const header_len: usize = if ((flags & 0x02) != 0) 24 else 20;
    var segment: [24 + tcp_mss]u8 = @splat(0);
    put16(&segment, 0, socket.local_port);
    put16(&segment, 2, socket.remote_port);
    put32(&segment, 4, sequence);
    put32(&segment, 8, socket.receive_sequence);
    segment[12] = @intCast((header_len / 4) << 4);
    segment[13] = flags;
    put16(&segment, 14, receiveWindow(socket));
    if (header_len == 24) {
        segment[20] = 2; // MSS option.
        segment[21] = 4;
        put16(&segment, 22, localTcpMss());
    }
    @memcpy(segment[header_len .. header_len + payload.len], payload);
    const segment_len = header_len + payload.len;
    put16(&segment, 16, transportChecksum(s.ipv4_address, socket.remote_ip, 6, segment[0..segment_len]));
    return sendIpv4(socket.remote_ip, 6, segment[0..segment_len]);
}

fn sendTcp(socket: *TcpSocket, flags: u8, payload: []const u8) bool {
    return sendTcpAt(socket, socket.send_sequence, flags, payload);
}

fn sendAck(socket: *TcpSocket) void {
    socket.ack_pending = !sendTcp(socket, 0x10, "");
}

pub fn udpOpen(local_port: u16) ?u8 {
    var assigned_port = local_port;
    if (assigned_port == 0) {
        if (!udp_ephemeral_seeded) {
            const seed = randomU32() orelse return null;
            next_udp_port = 49152 + @as(u16, @truncate(seed % 16384));
            udp_ephemeral_seeded = true;
        }
        var attempts: usize = 0;
        while (attempts < 16384) : (attempts += 1) {
            const candidate = next_udp_port;
            next_udp_port = if (next_udp_port == 65535) 49152 else next_udp_port + 1;
            var occupied = false;
            for (udp_sockets) |socket| if (socket.open and socket.port == candidate) {
                occupied = true;
            };
            if (!occupied) {
                assigned_port = candidate;
                break;
            }
        }
        if (assigned_port == 0) return null;
    }
    for (udp_sockets) |socket| if (socket.open and socket.port == assigned_port) return null;
    for (&udp_sockets, 0..) |*socket, i| {
        if (!socket.open) {
            socket.* = .{ .open = true, .port = assigned_port };
            return @intCast(i);
        }
    }
    return null;
}

pub fn udpClose(id: u8) void {
    if (id < udp_sockets.len) udp_sockets[id] = .{};
}

pub fn udpSendTo(id: u8, destination: IpAddress, port: u16, payload: []const u8) bool {
    if (id >= udp_sockets.len or !udp_sockets[id].open or payload.len > @min(max_udp_send_payload, interfaceMtu() - 28)) return false;
    var datagram: [8 + max_udp_send_payload]u8 = @splat(0);
    put16(&datagram, 0, udp_sockets[id].port);
    put16(&datagram, 2, port);
    put16(&datagram, 4, @intCast(8 + payload.len));
    @memcpy(datagram[8 .. 8 + payload.len], payload);
    put16(&datagram, 6, transportChecksum(s.ipv4_address, destination, 17, datagram[0 .. 8 + payload.len]));
    if (get16(&datagram, 6) == 0) put16(&datagram, 6, 0xffff);
    return sendIpv4(destination, 17, datagram[0 .. 8 + payload.len]);
}

pub fn udpReceive(id: u8, output: []u8) ?UdpResult {
    if (id >= udp_sockets.len or !udp_sockets[id].open or udp_sockets[id].received_count == 0) return null;
    const socket = &udp_sockets[id];
    const packet = &socket.received[socket.received_head];
    const length = @min(output.len, packet.length);
    @memcpy(output[0..length], packet.payload[0..length]);
    const result: UdpResult = .{ .length = length, .datagram_length = packet.length, .truncated = length != packet.length, .address = packet.address, .port = packet.port };
    packet.* = .{};
    socket.received_head = (socket.received_head + 1) % socket.received.len;
    socket.received_count -= 1;
    return result;
}

pub fn udpError(id: u8) ?NetworkError {
    if (id >= udp_sockets.len or !udp_sockets[id].open or udp_sockets[id].network_error == .none) return null;
    return udp_sockets[id].network_error;
}

pub fn tcpOpen(local_port: u16) ?u8 {
    if (local_port != 0) for (tcp_sockets) |socket| {
        if (socket.open and socket.local_port == local_port and socket.state != .closed) return null;
    };
    for (&tcp_sockets, 0..) |*socket, i| {
        if (!socket.open or socket.state == .closed) {
            var assigned_port = local_port;
            if (assigned_port == 0) {
                if (!tcp_ephemeral_seeded) {
                    const seed = randomU32() orelse return null;
                    next_ephemeral_port = 49152 + @as(u16, @truncate(seed % 16384));
                    tcp_ephemeral_seeded = true;
                }
                var attempts: usize = 0;
                while (attempts < 16384) : (attempts += 1) {
                    const candidate = next_ephemeral_port;
                    next_ephemeral_port = if (next_ephemeral_port == 65535) 49152 else next_ephemeral_port + 1;
                    var occupied = false;
                    for (tcp_sockets) |existing| if (existing.open and existing.state != .closed and existing.local_port == candidate) {
                        occupied = true;
                    };
                    if (!occupied) {
                        assigned_port = candidate;
                        break;
                    }
                }
                if (assigned_port == 0) return null;
            }
            socket.* = .{ .open = true, .local_port = assigned_port };
            return @intCast(i);
        }
    }
    return null;
}

pub fn tcpListen(local_port: u16) ?u8 {
    if (local_port == 0) return null;
    const id = tcpOpen(local_port) orelse return null;
    tcp_sockets[id].state = .listen;
    tcp_sockets[id].accepted = @splat(0);
    tcp_sockets[id].accepted_head = 0;
    tcp_sockets[id].accepted_count = 0;
    return id;
}

pub fn tcpAccept(id: u8) ?u8 {
    if (id >= tcp_sockets.len or tcp_sockets[id].state != .listen or tcp_sockets[id].accepted_count == 0) return null;
    const listener = &tcp_sockets[id];
    const child = listener.accepted[listener.accepted_head];
    listener.accepted_head = (listener.accepted_head + 1) % listener.accepted.len;
    listener.accepted_count -= 1;
    return child;
}

pub fn tcpConnect(id: u8, destination: IpAddress, port: u16) bool {
    if (id >= tcp_sockets.len or !tcp_sockets[id].open or tcp_sockets[id].state != .closed or !s.network_configured) return false;
    const socket = &tcp_sockets[id];
    socket.remote_ip = destination;
    socket.remote_port = port;
    socket.send_sequence = randomU32() orelse return false;
    socket.send_unacknowledged = socket.send_sequence;
    socket.receive_sequence = 0;
    socket.transmit_len = 0;
    socket.in_flight = 0;
    socket.peer_window = 0;
    socket.peer_mss = localTcpMss();
    socket.syn_unacknowledged = false;
    socket.fin_unacknowledged = false;
    socket.close_requested = false;
    socket.retries = 0;
    socket.syn_transmitted = false;
    socket.network_error = .none;
    socket.rto_ticks = tcp_initial_rto_ticks;
    socket.rtt_sample_valid = false;
    socket.rtt_initialized = false;
    socket.smoothed_rtt = 0;
    socket.rtt_variance = 0;
    socket.congestion_window = effectiveTcpMss(socket);
    socket.slow_start_threshold = 65535;
    socket.duplicate_acks = 0;
    socket.in_fast_recovery = false;
    socket.state = .syn_sent;
    socket.deadline = s.uptime();
    return true;
}

pub fn tcpSend(id: u8, payload: []const u8) bool {
    // A received FIN only closes the peer's sending half. TCP remains
    // full-duplex until we send our own FIN, so close_wait sockets may still
    // queue application data (for example, a TLS request after a server's
    // close_notify/EOF).
    if (id >= tcp_sockets.len or (tcp_sockets[id].state != .established and tcp_sockets[id].state != .close_wait)) return false;
    const socket = &tcp_sockets[id];
    if (payload.len > socket.transmit.len - socket.transmit_len) return false;
    @memcpy(socket.transmit[socket.transmit_len..][0..payload.len], payload);
    socket.transmit_len += payload.len;
    return true;
}

pub fn tcpConnected(id: u8) bool {
    return id < tcp_sockets.len and tcp_sockets[id].open and tcp_sockets[id].state == .established;
}

pub fn tcpError(id: u8) ?NetworkError {
    if (id >= tcp_sockets.len or tcp_sockets[id].network_error == .none) return null;
    return tcp_sockets[id].network_error;
}

pub fn tcpPeerClosed(id: u8) bool {
    return id >= tcp_sockets.len or !tcp_sockets[id].open or tcp_sockets[id].state == .close_wait or tcp_sockets[id].state == .time_wait or tcp_sockets[id].state == .closed;
}

pub fn tcpReceive(id: u8, output: []u8) ?usize {
    if (id >= tcp_sockets.len or !tcp_sockets[id].open or tcp_sockets[id].received_len == 0) return null;
    const socket = &tcp_sockets[id];
    const length = @min(output.len, socket.received_len);
    @memcpy(output[0..length], socket.received[0..length]);
    var i = length;
    while (i < socket.received_len) : (i += 1) socket.received[i - length] = socket.received[i];
    socket.received_len -= length;
    if (length != 0 and socket.state != .closed) sendAck(socket);
    return length;
}

pub fn tcpClose(id: u8) void {
    if (id >= tcp_sockets.len) return;
    const socket = &tcp_sockets[id];
    if (socket.state == .listen or socket.state == .closed or socket.state == .syn_sent or socket.state == .syn_received) {
        socket.open = false;
        socket.state = .closed;
        return;
    }
    if (socket.state == .established or socket.state == .close_wait) socket.close_requested = true;
}

fn processArp(frame: []const u8) void {
    if (frame.len < 42 or get16(frame, 14) != 1 or get16(frame, 16) != 0x0800 or frame[18] != 6 or frame[19] != 4) return;
    var sender_ip: IpAddress = undefined;
    var sender_mac: MacAddress = undefined;
    @memcpy(&sender_mac, frame[22..28]);
    @memcpy(&sender_ip, frame[28..32]);
    if (!std.mem.eql(u8, frame[6..12], &sender_mac) or (sender_mac[0] & 1) != 0) return;
    if (isZero(sender_ip)) return;
    if (s.network_configured and !ipEqual(routeFor(sender_ip), sender_ip)) return;
    learnNeighbor(sender_ip, sender_mac);
    if (get16(frame, 20) != 1 or !s.network_configured or !ipEqual(frame[38..42].*, s.ipv4_address)) return;
    var reply: [42]u8 = @splat(0);
    const local_mac = e1000.macAddress();
    @memcpy(reply[0..6], &sender_mac);
    @memcpy(reply[6..12], &local_mac);
    put16(&reply, 12, 0x0806);
    put16(&reply, 14, 1);
    put16(&reply, 16, 0x0800);
    reply[18] = 6;
    reply[19] = 4;
    put16(&reply, 20, 2);
    @memcpy(reply[22..28], &local_mac);
    @memcpy(reply[28..32], &s.ipv4_address);
    @memcpy(reply[32..38], &sender_mac);
    @memcpy(reply[38..42], &sender_ip);
    _ = e1000.sendEthernetFrame(&reply);
}

fn validTcpOptions(segment: []const u8, header_len: usize) bool {
    var cursor: usize = 20;
    while (cursor < header_len) {
        const kind = segment[cursor];
        if (kind == 0) {
            for (segment[cursor + 1 .. header_len]) |padding| if (padding != 0) return false;
            return true;
        }
        if (kind == 1) {
            cursor += 1;
            continue;
        }
        if (cursor + 2 > header_len) return false;
        const length: usize = segment[cursor + 1];
        if (length < 2 or cursor + length > header_len) return false;
        if (segment[cursor] == 2 and length != 4) return false;
        cursor += length;
    }
    return true;
}

fn processUdp(source_ip: IpAddress, destination_ip: IpAddress, ip_payload: []const u8) void {
    if (ip_payload.len < 8) return;
    const length = get16(ip_payload, 4);
    if (length < 8 or length != ip_payload.len) return;
    if (get16(ip_payload, 6) != 0 and transportChecksum(source_ip, destination_ip, 17, ip_payload[0..length]) != 0) return;
    const destination_port = get16(ip_payload, 2);
    if (destination_port == 0) return;
    for (&udp_sockets) |*socket| {
        if (!socket.open or socket.port != destination_port) continue;
        if (socket.received_count == socket.received.len) return;
        const payload = ip_payload[8..length];
        const slot_index = (socket.received_head + socket.received_count) % socket.received.len;
        const packet = &socket.received[slot_index];
        @memcpy(packet.payload[0..payload.len], payload);
        packet.length = payload.len;
        packet.ready = true;
        packet.address = source_ip;
        packet.port = get16(ip_payload, 0);
        socket.received_count += 1;
        return;
    }
    sendIcmpError(source_ip, destination_ip, 3, 3, 17, ip_payload[0..@min(length, 8)]);
}

fn processTcp(source_ip: IpAddress, destination_ip: IpAddress, ip_payload: []const u8) void {
    if (ip_payload.len < 20) return;
    const header_len: usize = @as(usize, ip_payload[12] >> 4) * 4;
    if (header_len < 20 or header_len > ip_payload.len or ip_payload[12] & 0x0e != 0 or !validTcpOptions(ip_payload, header_len)) return;
    if (transportChecksum(source_ip, destination_ip, 6, ip_payload) != 0) return;
    const source_port = get16(ip_payload, 0);
    const destination_port = get16(ip_payload, 2);
    if (source_port == 0 or destination_port == 0) return;
    const sequence = get32(ip_payload, 4);
    const acknowledgment = get32(ip_payload, 8);
    const flags = ip_payload[13];
    const payload = ip_payload[header_len..];
    for (&tcp_sockets) |*socket| {
        if (!socket.open or socket.local_port != destination_port or socket.remote_port != source_port or !ipEqual(socket.remote_ip, source_ip)) continue;
        const old_peer_window = socket.peer_window;
        socket.peer_window = get16(ip_payload, 14);
        if (socket.peer_window != 0) {
            socket.persist_deadline = 0;
            socket.persist_interval = 0;
        }

        if (socket.state == .syn_sent or socket.state == .syn_received) {
            if (socket.state == .syn_received) {
                if ((flags & 0x04) != 0 and sequence == socket.receive_sequence) {
                    socket.state = .closed;
                    socket.open = false;
                    socket.network_error = .reset;
                    return;
                }
                if ((flags & 0x02) != 0 and (flags & 0x10) == 0 and sequence +% 1 == socket.receive_sequence) {
                    if (sendTcpAt(socket, socket.send_unacknowledged, 0x12, "")) socket.deadline = s.uptime() + socket.rto_ticks;
                    return; // Retransmitted SYN: repeat SYN-ACK for a lost handshake response.
                }
                if ((flags & 0x10) == 0 or (flags & 0x02) != 0 or acknowledgment != socket.send_sequence or sequence != socket.receive_sequence) return;
                socket.syn_unacknowledged = false;
                socket.send_unacknowledged = acknowledgment;
                socket.state = .established;
                socket.retries = 0;
                if (socket.listener < tcp_sockets.len) {
                    const listener = &tcp_sockets[socket.listener];
                    if (listener.accepted_count < listener.accepted.len) {
                        const slot = (listener.accepted_head + listener.accepted_count) % listener.accepted.len;
                        listener.accepted[slot] = @intCast((@intFromPtr(socket) - @intFromPtr(&tcp_sockets[0])) / @sizeOf(TcpSocket));
                        listener.accepted_count += 1;
                    }
                }
                if (payload.len == 0 and (flags & 0x01) == 0) return;
            } else {
            if ((flags & 0x04) != 0 and (flags & 0x10) != 0 and acknowledgment == socket.send_sequence) {
                socket.state = .closed;
                socket.network_error = .reset;
                return;
            }
            if (!socket.syn_transmitted or (flags & 0x12) != 0x12 or acknowledgment != socket.send_sequence) return;
            var option = @as(usize, 20);
            while (option < header_len) {
                const kind = ip_payload[option];
                if (kind == 0) break;
                if (kind == 1) {
                    option += 1;
                    continue;
                }
                if (option + 2 > header_len) return;
                const option_len: usize = ip_payload[option + 1];
                if (option_len < 2 or option + option_len > header_len) return;
                if (kind == 2 and option_len == 4) socket.peer_mss = @max(@as(u16, 1), @min(get16(ip_payload, option + 2), localTcpMss()));
                option += option_len;
            }
            socket.congestion_window = socket.peer_mss;
            socket.receive_sequence = sequence +% 1;
            socket.send_unacknowledged = acknowledgment;
            socket.syn_unacknowledged = false;
            socket.state = .established;
            socket.retries = 0;
            sendAck(socket);
            return;
            }
        }

        if (socket.state == .closed) return;
        if ((flags & 0x04) != 0) {
            const segment_length = payload.len + @as(usize, @intFromBool((flags & 0x02) != 0)) + @as(usize, @intFromBool((flags & 0x01) != 0));
            if (sequence == socket.receive_sequence) {
                socket.state = .closed;
                socket.open = false;
                socket.network_error = .reset;
            } else if (sequenceAcceptable(sequence, segment_length, socket.receive_sequence, receiveWindow(socket))) {
                sendAck(socket); // RFC 5961 challenge ACK for an in-window, non-exact RST.
            }
            return;
        }
        if ((flags & 0x02) != 0) {
            sendAck(socket); // Challenge ACK for a stray SYN on an established tuple.
            return;
        }
        if ((flags & 0x10) == 0) return;

        if (seqAfter(acknowledgment, socket.send_sequence)) {
            sendAck(socket); // ACKs beyond SND.NXT are invalid.
            return;
        }

        const segment_length = payload.len + @as(usize, @intFromBool((flags & 0x02) != 0)) + @as(usize, @intFromBool((flags & 0x01) != 0));
        if (!sequenceAcceptable(sequence, segment_length, socket.receive_sequence, receiveWindow(socket))) {
            if (segment_length != 0) sendAck(socket);
            return;
        }

        if (seqAfter(acknowledgment, socket.send_unacknowledged) and seqBeforeOrEqual(acknowledgment, socket.send_sequence)) {
                const acknowledged = acknowledgment -% socket.send_unacknowledged;
                const data_acknowledged = @min(acknowledged, socket.in_flight);
                if (data_acknowledged != 0) {
                    if (socket.rtt_sample_valid) updateRtt(socket, s.uptime() -| socket.rtt_started_tick);
                    socket.rtt_sample_valid = false;
                    var i: usize = data_acknowledged;
                    while (i < socket.transmit_len) : (i += 1) socket.transmit[i - data_acknowledged] = socket.transmit[i];
                    socket.transmit_len -= data_acknowledged;
                    socket.in_flight -= data_acknowledged;
                }
                socket.send_unacknowledged = acknowledgment;
                congestionAck(socket, data_acknowledged);
                socket.retries = 0;
                socket.rto_ticks = @max(tcp_initial_rto_ticks, socket.rto_ticks);
                socket.deadline = s.uptime() + socket.rto_ticks;
                socket.duplicate_acks = 0;
                if (socket.syn_unacknowledged and acknowledgment == socket.send_sequence) socket.syn_unacknowledged = false;
                if (socket.fin_unacknowledged and acknowledgment == socket.send_sequence) {
                    socket.fin_unacknowledged = false;
                    socket.state = switch (socket.state) {
                        .fin_wait_1 => .fin_wait_2,
                        .closing => .time_wait,
                        .last_ack => .closed,
                        else => socket.state,
                    };
                    if (socket.state == .time_wait) socket.deadline = s.uptime() + 12000;
                    if (socket.state == .closed) socket.open = false;
                }
                if (socket.in_fast_recovery and !seqAfter(socket.send_unacknowledged, socket.recovery_sequence) and socket.in_flight != 0) {
                    const amount = @min(socket.in_flight, @as(usize, effectiveTcpMss(socket)));
                    if (amount != 0) _ = sendTcpAt(socket, socket.send_unacknowledged, 0x18, socket.transmit[0..amount]);
                    socket.deadline = s.uptime() + socket.rto_ticks;
                }
        } else if (acknowledgment == socket.send_unacknowledged and socket.in_flight != 0 and payload.len == 0 and (flags & 0x03) == 0 and socket.peer_window == old_peer_window) {
            if (socket.duplicate_acks < 255) socket.duplicate_acks += 1;
            const mss: u32 = effectiveTcpMss(socket);
            if (socket.duplicate_acks == 3 and !socket.in_fast_recovery) {
                socket.slow_start_threshold = @max(2 * mss, @as(u32, @intCast(socket.in_flight / 2)));
                socket.congestion_window = socket.slow_start_threshold + 3 * mss;
                socket.recovery_sequence = socket.send_sequence;
                socket.in_fast_recovery = true;
                const amount = @min(socket.in_flight, @as(usize, effectiveTcpMss(socket)));
                if (amount != 0) _ = sendTcpAt(socket, socket.send_unacknowledged, 0x18, socket.transmit[0..amount]);
                socket.deadline = s.uptime() + socket.rto_ticks;
            } else if (socket.in_fast_recovery and socket.duplicate_acks > 3) {
                socket.congestion_window +|= mss;
            }
        }

        var accepted = false;
        if (payload.len != 0) {
            if (sequence == socket.receive_sequence) {
                const room = socket.received.len - socket.received_len;
                const copy_len = @min(payload.len, room);
                if (copy_len != 0) {
                    @memcpy(socket.received[socket.received_len..][0..copy_len], payload[0..copy_len]);
                    socket.received_len += copy_len;
                    socket.receive_sequence +%= @intCast(copy_len);
                    accepted = true;
                }
                if (copy_len != payload.len) {
                    sendAck(socket);
                    return;
                }
            } else {
                sendAck(socket); // Duplicate ACK for out-of-order or duplicate data.
                return;
            }
        }

        if ((flags & 0x01) != 0 and sequence +% @as(u32, @intCast(payload.len)) == socket.receive_sequence) {
            socket.receive_sequence +%= 1;
            accepted = true;
            socket.state = switch (socket.state) {
                .established => .close_wait,
                .fin_wait_1 => .closing,
                .fin_wait_2 => .time_wait,
                else => socket.state,
            };
            if (socket.state == .time_wait) socket.deadline = s.uptime() + 12000;
        }
        if (accepted or (flags & 0x01) != 0) sendAck(socket);
        return;
    }

    if ((flags & 0x04) != 0) return;
    if ((flags & 0x02) == 0 or (flags & 0x10) != 0) {
        sendReset(source_ip, source_port, destination_port, sequence, acknowledgment, flags, payload.len);
        return;
    }
    for (&tcp_sockets, 0..) |*listener, listener_index| {
        if (!listener.open or listener.state != .listen or listener.local_port != destination_port or listener.accepted_count == listener.accepted.len) continue;
        const child_id = tcpOpen(0) orelse return;
        const child = &tcp_sockets[child_id];
        child.local_port = destination_port;
        child.listener = @intCast(listener_index);
        child.remote_port = source_port;
        child.remote_ip = source_ip;
        child.receive_sequence = sequence +% 1;
        child.send_sequence = randomU32() orelse {
            tcp_sockets[child_id] = .{};
            return;
        };
        child.send_unacknowledged = child.send_sequence;
        child.peer_window = get16(ip_payload, 14);
        child.peer_mss = localTcpMss();
        var option = @as(usize, 20);
        while (option < header_len) {
            const kind = ip_payload[option];
            if (kind == 0) break;
            if (kind == 1) {
                option += 1;
                continue;
            }
            if (option + 2 > header_len) break;
            const option_len: usize = ip_payload[option + 1];
            if (option_len < 2 or option + option_len > header_len) break;
            if (kind == 2 and option_len == 4) child.peer_mss = @max(@as(u16, 1), @min(get16(ip_payload, option + 2), localTcpMss()));
            option += option_len;
        }
        child.congestion_window = child.peer_mss;
        child.state = .syn_received;
        if (sendTcpAt(child, child.send_sequence, 0x12, "")) {
            child.send_sequence +%= 1;
            child.syn_transmitted = true;
            child.syn_unacknowledged = true;
            child.deadline = s.uptime() + 100;
        }
        return;
    }
    sendReset(source_ip, source_port, destination_port, sequence, acknowledgment, flags, payload.len);
}

fn validIpv4Options(header: []const u8) bool {
    var cursor: usize = 20;
    while (cursor < header.len) {
        const kind = header[cursor];
        if (kind == 0) {
            for (header[cursor + 1 ..]) |padding| if (padding != 0) return false;
            return true;
        }
        if (kind == 1) {
            cursor += 1;
            continue;
        }
        if (cursor + 2 > header.len) return false;
        const length: usize = header[cursor + 1];
        if (length < 2 or cursor + length > header.len) return false;
        // Source-route options are rejected because they bypass normal routing.
        if (kind == 131 or kind == 137) return false;
        cursor += length;
    }
    return true;
}

fn sendIcmpError(source: IpAddress, destination: IpAddress, kind: u8, code: u8, protocol: u8, quoted_transport: []const u8) void {
    if (isZero(source) or isIpv4Broadcast(source) or isIpv4Broadcast(destination) or (source[0] & 0xf0) == 0xe0) return;
    if (quoted_transport.len < 8) return;
    var error_packet: [36]u8 = @splat(0);
    error_packet[0] = kind;
    error_packet[1] = code;
    const quote_ip = 8;
    error_packet[quote_ip] = 0x45;
    put16(&error_packet, quote_ip + 2, 28);
    error_packet[quote_ip + 8] = 64;
    error_packet[quote_ip + 9] = protocol;
    @memcpy(error_packet[quote_ip + 12 .. quote_ip + 16], &destination);
    @memcpy(error_packet[quote_ip + 16 .. quote_ip + 20], &source);
    put16(&error_packet, quote_ip + 10, checksum(error_packet[quote_ip .. quote_ip + 20]));
    @memcpy(error_packet[quote_ip + 20 .. quote_ip + 28], quoted_transport[0..8]);
    put16(&error_packet, 2, checksum(&error_packet));
    _ = sendIpv4(source, 1, &error_packet);
}

fn networkErrorFromIcmp(kind: u8, code: u8) ?NetworkError {
    if (kind == 11) return .ttl_expired;
    if (kind == 12) return .parameter_problem;
    if (kind != 3) return null;
    return switch (code) {
        0 => .network_unreachable,
        1 => .host_unreachable,
        2 => .protocol_unreachable,
        3 => .port_unreachable,
        4 => .fragmentation_needed,
        9, 10, 13 => .administrative_prohibited,
        else => null,
    };
}

fn processIcmp(source: IpAddress, destination: IpAddress, payload: []const u8) void {
    if (payload.len < 8 or checksum(payload) != 0) return;
    if (payload.len <= interfaceMtu() - 20 and payload[0] == 8 and payload[1] == 0 and !isZero(source) and !isIpv4Broadcast(source) and !isIpv4Broadcast(destination)) {
        var reply: [1480]u8 = @splat(0);
        @memcpy(reply[0..payload.len], payload);
        reply[0] = 0;
        put16(&reply, 2, 0);
        put16(&reply, 2, checksum(reply[0..payload.len]));
        _ = sendIpv4(source, 1, reply[0..payload.len]);
        return;
    }
    const network_error = networkErrorFromIcmp(payload[0], payload[1]) orelse return;
    if (payload.len < 8 + 20 + 8) return;
    const quoted = payload[8..];
    if ((quoted[0] >> 4) != 4) return;
    const header_len: usize = @as(usize, quoted[0] & 0x0f) * 4;
    if (header_len < 20 or quoted.len < header_len + 8 or checksum(quoted[0..header_len]) != 0 or (get16(quoted, 6) & 0x1fff) != 0) return;
    var original_source: IpAddress = undefined;
    var original_destination: IpAddress = undefined;
    @memcpy(&original_source, quoted[12..16]);
    @memcpy(&original_destination, quoted[16..20]);
    if (!ipEqual(original_source, s.ipv4_address)) return;
    const transport = quoted[header_len..];
    const local_port = get16(transport, 0);
    const remote_port = get16(transport, 2);
    if (quoted[9] == 17) {
        for (&udp_sockets) |*socket| if (socket.open and socket.port == local_port) {
            socket.network_error = network_error;
        };
    } else if (quoted[9] == 6) {
        for (&tcp_sockets) |*socket| if (socket.open and socket.local_port == local_port and socket.remote_port == remote_port and ipEqual(socket.remote_ip, original_destination)) {
            socket.network_error = network_error;
            socket.state = .closed;
        };
    }
}

fn processIpv4Payload(source: IpAddress, destination: IpAddress, protocol: u8, payload: []const u8) void {
    switch (protocol) {
        17 => processUdp(source, destination, payload),
        6 => processTcp(source, destination, payload),
        1 => processIcmp(source, destination, payload),
        else => {},
    }
}

fn reassembleFragment(source: IpAddress, destination: IpAddress, identification: u16, protocol: u8, offset: usize, more: bool, payload: []const u8) void {
    if (payload.len == 0 or offset > fragment_limit or payload.len > fragment_limit - offset or (more and payload.len % 8 != 0)) return;
    var slot: ?*FragmentSlot = null;
    for (&fragments) |*candidate| {
        if (!candidate.used or s.uptime() >= candidate.expires) continue;
        if (candidate.identification == identification and candidate.protocol == protocol and ipEqual(candidate.source, source) and ipEqual(candidate.destination, destination)) {
            slot = candidate;
            break;
        }
    }
    if (slot == null) {
        const candidate = &fragments[fragment_cursor];
        fragment_cursor = (fragment_cursor + 1) % fragments.len;
        candidate.* = .{
            .used = true,
            .source = source,
            .destination = destination,
            .identification = identification,
            .protocol = protocol,
            .expires = s.uptime() + 3000,
        };
        slot = candidate;
    }
    const entry = slot.?;
    if (entry.has_final and !more and offset + payload.len != entry.total_len) {
        entry.used = false;
        return;
    }
    if (entry.has_final and offset + payload.len > entry.total_len) {
        entry.used = false;
        return;
    }
    for (0..payload.len) |i| {
        const byte_offset = offset + i;
        const mask: u8 = @as(u8, 1) << @as(u3, @intCast(byte_offset & 7));
        const present_byte = &entry.present[byte_offset >> 3];
        if ((present_byte.* & mask) != 0) {
            entry.used = false; // RFC 5722: discard the whole datagram on any overlap.
            return;
        }
        present_byte.* |= mask;
        entry.data[byte_offset] = payload[i];
        entry.received += 1;
    }
    if (!more) {
        entry.total_len = offset + payload.len;
        entry.has_final = true;
        for (entry.total_len..fragment_limit) |i| {
            const mask: u8 = @as(u8, 1) << @as(u3, @intCast(i & 7));
            if ((entry.present[i >> 3] & mask) != 0) {
                entry.used = false;
                return;
            }
        }
    }
    if (!entry.has_final or entry.received < entry.total_len) return;
    for (0..entry.total_len) |i| {
        const mask: u8 = @as(u8, 1) << @as(u3, @intCast(i & 7));
        if ((entry.present[i >> 3] & mask) == 0) return;
    }
    processIpv4Payload(entry.source, entry.destination, entry.protocol, entry.data[0..entry.total_len]);
    entry.used = false;
}

pub fn onEthernetFrame(frame: []const u8) void {
    if (frame.len < 14) return;
    const ether_type = get16(frame, 12);
    if (ether_type == 0x0806) {
        processArp(frame);
        return;
    }
    if (ether_type != 0x0800 or frame.len < 34 or (frame[14] >> 4) != 4) return;
    const ip_header_len: usize = @as(usize, frame[14] & 0x0f) * 4;
    if (ip_header_len < 20 or frame.len < 14 + ip_header_len) return;
    const total_len = get16(frame, 16);
    if (total_len < ip_header_len or total_len > interfaceMtu() or total_len > frame.len - 14 or checksum(frame[14 .. 14 + ip_header_len]) != 0 or !validIpv4Options(frame[14 .. 14 + ip_header_len])) return;
    const fragment = get16(frame, 20);
    if ((fragment & 0x8000) != 0) return;
    if ((fragment & 0x4000) != 0 and (fragment & 0x3fff) != 0) return;
    var destination: IpAddress = undefined;
    var source: IpAddress = undefined;
    @memcpy(&source, frame[26..30]);
    @memcpy(&destination, frame[30..34]);
    if (!s.network_configured or (!ipEqual(destination, s.ipv4_address) and !isIpv4Broadcast(destination))) return;
    if (isZero(source) or source[0] == 0 or source[0] == 127 or source[0] >= 224 or isIpv4Broadcast(source)) return;
    if (!isZero(source) and ipEqual(routeFor(source), source)) {
        var source_mac: MacAddress = undefined;
        @memcpy(&source_mac, frame[6..12]);
        learnNeighbor(source, source_mac);
    }
    const payload = frame[14 + ip_header_len .. 14 + total_len];
    if ((fragment & 0x3fff) != 0) {
        const offset: usize = @as(usize, fragment & 0x1fff) * 8;
        reassembleFragment(source, destination, get16(frame, 18), frame[23], offset, (fragment & 0x2000) != 0, payload);
    } else {
        processIpv4Payload(source, destination, frame[23], payload);
    }
}

pub fn poll() void {
    for (&tcp_sockets) |*socket| {
        if (!socket.open) continue;
        if (socket.ack_pending) sendAck(socket);
        if (socket.state == .time_wait and s.uptime() >= socket.deadline) {
            socket.state = .closed;
            socket.open = false;
            continue;
        }

        if (socket.state == .syn_sent or socket.state == .syn_received) {
            if (socket.syn_transmitted and s.uptime() < socket.deadline) continue;
            if (socket.retries >= 6) {
                socket.state = .closed;
                    socket.network_error = .timeout;
                continue;
            }
            const syn_flags: u8 = if (socket.state == .syn_received) 0x12 else 0x02;
            if (sendTcpAt(socket, socket.send_unacknowledged, syn_flags, "")) {
                if (!socket.syn_transmitted) {
                    socket.send_sequence +%= 1;
                } else {
                    socket.retries += 1;
                }
                socket.syn_transmitted = true;
                socket.syn_unacknowledged = true;
                socket.deadline = s.uptime() + (@as(u64, 100) << @min(socket.retries, 4));
            }
            continue;
        }

        if (socket.in_flight != 0) {
            if (s.uptime() >= socket.deadline) {
                if (socket.retries >= 8) {
                    socket.state = .closed;
                    socket.open = false;
                    socket.network_error = .timeout;
                    continue;
                }
                    const amount = @min(socket.in_flight, @as(usize, effectiveTcpMss(socket)));
                if (amount != 0 and sendTcpAt(socket, socket.send_unacknowledged, 0x18, socket.transmit[0..amount])) {
                    congestionTimeout(socket);
                    socket.rtt_sample_valid = false; // Karn's rule: do not sample retransmitted data.
                    socket.rto_ticks = @min(tcp_max_rto_ticks, socket.rto_ticks * 2);
                    socket.retries += 1;
                    socket.deadline = s.uptime() + socket.rto_ticks;
                } else socket.deadline = s.uptime() + 10;
                continue;
            }
        }

        if (socket.peer_window == 0 and socket.in_flight == 0 and socket.transmit_len != 0 and (socket.state == .established or socket.state == .close_wait)) {
            if (socket.persist_deadline == 0) {
                socket.persist_interval = 500;
                socket.persist_deadline = s.uptime() + socket.persist_interval;
            } else if (s.uptime() >= socket.persist_deadline) {
                if (sendTcpAt(socket, socket.send_sequence -% 1, 0x18, socket.transmit[0..1])) {
                    socket.persist_interval = @min(@as(u64, 6000), socket.persist_interval * 2);
                    socket.persist_deadline = s.uptime() + socket.persist_interval;
                } else socket.persist_deadline = s.uptime() + 10;
            }
            continue;
        }

        if (socket.transmit_len > socket.in_flight and (socket.state == .established or socket.state == .close_wait)) {
            const flight = @as(u32, @intCast(socket.in_flight));
            const congestion_room = socket.congestion_window -| flight;
            const receive_room = @as(u32, socket.peer_window) -| flight;
            const available = @min(congestion_room, receive_room);
            const unsent = socket.transmit_len - socket.in_flight;
            const amount = @min(unsent, @min(@as(usize, effectiveTcpMss(socket)), @as(usize, available)));
            if (amount != 0 and sendTcpAt(socket, socket.send_unacknowledged +% flight, 0x18, socket.transmit[socket.in_flight .. socket.in_flight + amount])) {
                if (socket.in_flight == 0) {
                    socket.deadline = s.uptime() + socket.rto_ticks;
                    socket.rtt_started_tick = s.uptime();
                    socket.rtt_sample_valid = true;
                }
                socket.in_flight += amount;
                socket.send_sequence +%= @intCast(amount);
            }
            if (amount != 0) continue;
        }

        if (socket.close_requested and socket.transmit_len == 0 and socket.in_flight == 0 and !socket.fin_unacknowledged and (socket.state == .established or socket.state == .close_wait)) {
            if (sendTcp(socket, 0x11, "")) {
                socket.send_sequence +%= 1;
                socket.fin_unacknowledged = true;
                socket.state = if (socket.state == .close_wait) .last_ack else .fin_wait_1;
                socket.deadline = s.uptime() + 100;
                socket.retries = 0;
            }
            continue;
        }

        if (socket.fin_unacknowledged and s.uptime() >= socket.deadline) {
            if (socket.retries >= 8) {
                socket.state = .closed;
                socket.open = false;
                socket.network_error = .timeout;
            } else if (sendTcpAt(socket, socket.send_unacknowledged, 0x11, "")) {
                socket.retries += 1;
                socket.deadline = s.uptime() + (@as(u64, 100) << @min(socket.retries, 4));
            } else socket.deadline = s.uptime() + 10;
        }
    }
}
