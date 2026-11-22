//! QEMU Intel 82540EM (e1000) polling driver with DHCPv4 setup.
const std = @import("std");
const entropy_source = @import("../network/entropy.zig");
const io = @import("../arch/io.zig");
const s = @import("../system/state.zig");

const pci_address_port: u16 = 0x0cf8;
const pci_data_port: u16 = 0x0cfc;
const rx_count = 32;
const rx_buffer_size = 2048;
const tx_count = 8;
const tx_buffer_size = 1536;

const RxDescriptor = extern struct {
    address: u64 = 0,
    length: u16 = 0,
    checksum: u16 = 0,
    status: u8 = 0,
    errors: u8 = 0,
    special: u16 = 0,
};
const TxDescriptor = extern struct {
    address: u64 = 0,
    length: u16 = 0,
    checksum_offset: u8 = 0,
    command: u8 = 0,
    status: u8 = 1,
    checksum_start: u8 = 0,
    special: u16 = 0,
};

var registers: ?[*]volatile u32 = null;
var rx_descriptors: [rx_count]RxDescriptor align(16) = @splat(.{});
var rx_buffers: [rx_count][rx_buffer_size]u8 align(16) = @splat(@splat(0));
var rx_index: usize = 0;
var tx_descriptors: [tx_count]TxDescriptor align(16) = @splat(.{});
var tx_buffers: [tx_count][tx_buffer_size]u8 align(16) = @splat(@splat(0));
var tx_index: usize = 0;
var mac_address: [6]u8 = @splat(0);
var dhcp_xid: u32 = 0x41544852; // "ATHR"
var dhcp_state: enum { idle, discovering, requesting, probing, configured, renewing, rebinding, declining } = .idle;
var dhcp_retry_tick: u64 = 0;
var offered_ip: [4]u8 = @splat(0);
var dhcp_server: [4]u8 = @splat(0);
var dhcp_server_mac: [6]u8 = @splat(0);
var lease_seconds: u32 = 0;
var renew_seconds: u32 = 0;
var rebind_seconds: u32 = 0;
var lease_start_tick: u64 = 0;
var dhcp_probe_count: u8 = 0;
var dhcp_probe_tick: u64 = 0;
const DhcpOptions = struct {
    message_type: u8 = 0,
    server: [4]u8 = .{ 0, 0, 0, 0 },
    subnet: [4]u8 = .{ 0, 0, 0, 0 },
    router: [4]u8 = .{ 0, 0, 0, 0 },
    dns: [4]u8 = .{ 0, 0, 0, 0 },
    dns_secondary: [4]u8 = .{ 0, 0, 0, 0 },
    routes: [8]s.Ipv4Route = @splat(.{}),
    route_count: usize = 0,
    route_priority: u8 = 0,
    lease: u32 = 0,
    renew: u32 = 0,
    rebind: u32 = 0,
    mtu: u16 = 0,
    overload: u8 = 0,
    has_server: bool = false,
    has_subnet: bool = false,
    has_router: bool = false,
    has_dns: bool = false,
    has_dns_secondary: bool = false,
    has_routes: bool = false,
    has_mtu: bool = false,
};

fn validSubnetMask(mask: [4]u8) bool {
    var zero_seen = false;
    for (mask) |octet| {
        var bit: u8 = 0x80;
        while (bit != 0) : (bit >>= 1) {
            if ((octet & bit) != 0) {
                if (zero_seen) return false;
            } else zero_seen = true;
        }
    }
    return true;
}

fn defaultSubnetMask(address: [4]u8) [4]u8 {
    if (address[0] < 128) return .{ 255, 0, 0, 0 };
    if (address[0] < 192) return .{ 255, 255, 0, 0 };
    if (address[0] < 224) return .{ 255, 255, 255, 0 };
    return .{ 0, 0, 0, 0 };
}

fn validUnicastAddress(address: []const u8) bool {
    if (address.len != 4 or address[0] == 0 or address[0] == 127 or address[0] >= 224) return false;
    return !(address[0] == 255 and address[1] == 255 and address[2] == 255 and address[3] == 255);
}

fn pciRead(bus: u32, device: u32, function: u32, offset: u32) u32 {
    const address = 0x80000000 | (bus << 16) | (device << 11) | (function << 8) | (offset & 0xfc);
    io.out32(pci_address_port, address);
    return io.in32(pci_data_port);
}

fn pciWrite(bus: u32, device: u32, function: u32, offset: u32, value: u32) void {
    const address = 0x80000000 | (bus << 16) | (device << 11) | (function << 8) | (offset & 0xfc);
    io.out32(pci_address_port, address);
    io.out32(pci_data_port, value);
}

fn findController() ?u64 {
    for (0..256) |bus| {
        for (0..32) |device| {
            const vendor_device = pciRead(@intCast(bus), @intCast(device), 0, 0);
            if (vendor_device == 0xffffffff or vendor_device == 0) continue;
            const vendor: u16 = @truncate(vendor_device);
            const product: u16 = @truncate(vendor_device >> 16);
            if (vendor == 0x8086 and (product == 0x100e or product == 0x100f)) {
                const bar = pciRead(@intCast(bus), @intCast(device), 0, 0x10);
                if (bar == 0 or (bar & 1) != 0) return null;
                const base: u64 = bar & 0xfffffff0;
                if (base == 0 or base >= 0x1_0000_0000) return null;
                const command_status = pciRead(@intCast(bus), @intCast(device), 0, 0x04);
                pciWrite(@intCast(bus), @intCast(device), 0, 0x04, (command_status & 0xffff) | 0x0006);
                return base;
            }
        }
    }
    return null;
}

pub fn init() bool {
    const base = findController() orelse return false;
    registers = @ptrFromInt(base);
    // Mask interrupts; packet reception is polled by the kernel main loop.
    writeRegister(0x00d8, 0xffffffff);
    writeRegister(0x0000, readRegister(0x0000) | (1 << 26));
    var reset_wait: usize = 0;
    while (reset_wait < 1_000_000 and (readRegister(0x0000) & (1 << 26)) != 0) : (reset_wait += 1) {}

    for (&rx_descriptors, 0..) |*descriptor, i| {
        descriptor.* = .{ .address = @intFromPtr(&rx_buffers[i]) };
    }
    rx_index = 0;
    writeRegister(0x2800, @truncate(@intFromPtr(&rx_descriptors)));
    writeRegister(0x2804, @truncate(@intFromPtr(&rx_descriptors) >> 32));
    writeRegister(0x2808, @sizeOf(@TypeOf(rx_descriptors)));
    writeRegister(0x2810, 0);
    writeRegister(0x2818, rx_count - 1);
    // Enable receive, accept broadcast packets, and strip the Ethernet CRC.
    writeRegister(0x0100, (1 << 1) | (1 << 15) | (1 << 26));

    for (&tx_descriptors, 0..) |*descriptor, i| {
        descriptor.* = .{ .address = @intFromPtr(&tx_buffers[i]) };
    }
    tx_index = 0;
    writeRegister(0x3800, @truncate(@intFromPtr(&tx_descriptors)));
    writeRegister(0x3804, @truncate(@intFromPtr(&tx_descriptors) >> 32));
    writeRegister(0x3808, @sizeOf(@TypeOf(tx_descriptors)));
    writeRegister(0x3810, 0);
    writeRegister(0x3818, 0);
    writeRegister(0x0400, (1 << 1) | (1 << 3) | (0x10 << 4) | (0x40 << 12));
    writeRegister(0x0410, 10 | (8 << 10) | (6 << 20));

    const ral = readRegister(0x5400);
    const rah = readRegister(0x5404);
    mac_address = .{ @truncate(ral), @truncate(ral >> 8), @truncate(ral >> 16), @truncate(ral >> 24), @truncate(rah), @truncate(rah >> 8) };
    dhcp_state = .idle;
    return true;
}

fn readRegister(offset: usize) u32 {
    const regs = registers orelse return 0;
    return regs[offset / 4];
}

fn writeRegister(offset: usize, value: u32) void {
    const regs = registers orelse return;
    regs[offset / 4] = value;
}

fn txSend(frame: []const u8) bool {
    if (frame.len < 14 or frame.len > tx_buffer_size) return false;
    const descriptor = &tx_descriptors[tx_index];
    const status: *volatile u8 = @ptrCast(&descriptor.status);
    if ((status.* & 1) == 0) return false;
    @memcpy(tx_buffers[tx_index][0..frame.len], frame);
    descriptor.length = @intCast(frame.len);
    descriptor.checksum_offset = 0;
    descriptor.command = 0x0b; // EOP | IFCS | RS
    descriptor.checksum_start = 0;
    descriptor.special = 0;
    status.* = 0;
    asm volatile ("" ::: .{ .memory = true });
    tx_index = (tx_index + 1) % tx_count;
    writeRegister(0x3818, @intCast(tx_index));
    return true;
}

pub fn sendEthernetFrame(frame: []const u8) bool {
    return txSend(frame);
}

pub fn macAddress() [6]u8 {
    return mac_address;
}

fn put16(buffer: []u8, offset: usize, value: u16) void {
    buffer[offset] = @truncate(value >> 8);
    buffer[offset + 1] = @truncate(value);
}

fn put32(buffer: []u8, offset: usize, value: u32) void {
    buffer[offset] = @truncate(value >> 24);
    buffer[offset + 1] = @truncate(value >> 16);
    buffer[offset + 2] = @truncate(value >> 8);
    buffer[offset + 3] = @truncate(value);
}

fn get16(buffer: []const u8, offset: usize) u16 {
    return (@as(u16, buffer[offset]) << 8) | buffer[offset + 1];
}

fn get32(buffer: []const u8, offset: usize) u32 {
    return (@as(u32, buffer[offset]) << 24) | (@as(u32, buffer[offset + 1]) << 16) | (@as(u32, buffer[offset + 2]) << 8) | buffer[offset + 3];
}

fn checksum(data: []const u8) u16 {
    var sum: u32 = 0;
    var i: usize = 0;
    while (i + 1 < data.len) : (i += 2) sum += (@as(u32, data[i]) << 8) | data[i + 1];
    if (i < data.len) sum += @as(u32, data[i]) << 8;
    while (sum >> 16 != 0) sum = (sum & 0xffff) + (sum >> 16);
    return ~@as(u16, @truncate(sum));
}

fn sendDhcp(message_type: u8) void {
    var frame: [14 + 20 + 8 + 300]u8 = @splat(0);
    const unicast_renewal = dhcp_state == .renewing;
    const lease_request = unicast_renewal or dhcp_state == .rebinding;
    if (unicast_renewal) @memcpy(frame[0..6], &dhcp_server_mac) else @memset(frame[0..6], 0xff);
    @memcpy(frame[6..12], &mac_address);
    put16(&frame, 12, 0x0800);
    const ip = 14;
    frame[ip] = 0x45;
    put16(&frame, ip + 4, @truncate(dhcp_xid));
    put16(&frame, ip + 6, 0x4000);
    frame[ip + 8] = 64;
    frame[ip + 9] = 17;
    if (lease_request) @memcpy(frame[ip + 12 .. ip + 16], &s.ipv4_address) else put32(&frame, ip + 12, 0);
    if (unicast_renewal) {
        @memcpy(frame[ip + 16 .. ip + 20], &dhcp_server);
    } else {
        put32(&frame, ip + 16, 0xffffffff);
    }
    put16(&frame, ip + 10, checksum(frame[ip .. ip + 20]));
    const udp = ip + 20;
    put16(&frame, udp, 68);
    put16(&frame, udp + 2, 67);
    const dhcp = udp + 8;
    frame[dhcp] = 1; // BOOTREQUEST
    frame[dhcp + 1] = 1; // Ethernet
    frame[dhcp + 2] = 6;
    put32(&frame, dhcp + 4, dhcp_xid);
    if (!unicast_renewal) frame[dhcp + 10] = 0x80; // Broadcast reply requested.
    @memcpy(frame[dhcp + 28 .. dhcp + 34], &mac_address);
    if (lease_request) @memcpy(frame[dhcp + 12 .. dhcp + 16], &s.ipv4_address); // ciaddr
    put32(&frame, dhcp + 236, 0x63825363);
    var option: usize = dhcp + 240;
    frame[option] = 53;
    frame[option + 1] = 1;
    frame[option + 2] = message_type;
    option += 3;
    if ((message_type == 3 and dhcp_state == .requesting) or (message_type == 4 and dhcp_state == .declining)) {
        frame[option] = 50;
        frame[option + 1] = 4;
        @memcpy(frame[option + 2 .. option + 6], &offered_ip);
        option += 6;
        frame[option] = 54;
        frame[option + 1] = 4;
        @memcpy(frame[option + 2 .. option + 6], &dhcp_server);
        option += 6;
    }
    frame[option] = 55;
    frame[option + 1] = 12;
    frame[option + 2] = 1;
    frame[option + 3] = 3;
    frame[option + 4] = 6;
    frame[option + 5] = 15;
    frame[option + 6] = 26;
    frame[option + 7] = 28;
    frame[option + 8] = 51;
    frame[option + 9] = 58;
    frame[option + 10] = 59;
    frame[option + 11] = 119;
    frame[option + 12] = 121;
    frame[option + 13] = 249;
    option += 14;
    frame[option] = 57; // Maximum DHCP message size.
    frame[option + 1] = 2;
    put16(&frame, option + 2, 576);
    option += 4;
    frame[option] = 61; // Stable client identifier: Ethernet hardware type + MAC.
    frame[option + 1] = 7;
    frame[option + 2] = 1;
    @memcpy(frame[option + 3 .. option + 9], &mac_address);
    option += 9;
    frame[option] = 12; // Host name.
    frame[option + 1] = 8;
    @memcpy(frame[option + 2 .. option + 10], "aetheros");
    option += 10;
    frame[option] = 255;
    const dhcp_len = option - dhcp + 1;
    put16(&frame, udp + 4, @intCast(8 + dhcp_len));
    put16(&frame, ip + 2, @intCast(20 + 8 + dhcp_len));
    put16(&frame, ip + 10, 0);
    put16(&frame, ip + 10, checksum(frame[ip .. ip + 20]));
    _ = txSend(frame[0 .. dhcp + dhcp_len]);
    dhcp_retry_tick = s.uptime() + 500;
}

fn sendArpProbe(address: [4]u8) bool {
    var frame: [42]u8 = @splat(0);
    const mac = mac_address;
    @memset(frame[0..6], 0xff);
    @memcpy(frame[6..12], &mac);
    put16(&frame, 12, 0x0806);
    put16(&frame, 14, 1);
    put16(&frame, 16, 0x0800);
    frame[18] = 6;
    frame[19] = 4;
    put16(&frame, 20, 1);
    @memcpy(frame[22..28], &mac);
    // Sender protocol address remains zero while probing for a candidate.
    @memcpy(frame[38..42], &address);
    return txSend(&frame);
}

fn clearNetworkConfiguration() void {
    s.network_configured = false;
    s.network_updated = true;
    s.ipv4_mtu = 1500;
    s.ipv4_address = .{ 0, 0, 0, 0 };
    s.ipv4_subnet = .{ 0, 0, 0, 0 };
    s.ipv4_gateway = .{ 0, 0, 0, 0 };
    s.ipv4_dns = .{ 0, 0, 0, 0 };
    s.ipv4_dns_secondary = .{ 0, 0, 0, 0 };
    s.ipv4_routes = @splat(.{});
    s.ipv4_route_count = 0;
    lease_seconds = 0;
}

fn dhcpAddressConflict(frame: []const u8) bool {
    if (dhcp_state != .probing or frame.len < 42) return false;
    const sender_ip = frame[28..32];
    const target_ip = frame[38..42];
    const sender_mac = frame[22..28];
    if ((sender_mac[0] & 1) != 0 or std.mem.eql(u8, sender_mac, &mac_address)) return false;
    const sender_matches = std.mem.eql(u8, sender_ip, &offered_ip);
    const probe_matches = std.mem.eql(u8, sender_ip, &.{ 0, 0, 0, 0 }) and std.mem.eql(u8, target_ip, &offered_ip);
    return sender_matches or probe_matches;
}

fn declineAddress() void {
    dhcp_state = .declining;
    sendDhcp(4);
    dhcp_state = .idle;
    clearNetworkConfiguration();
    offered_ip = .{ 0, 0, 0, 0 };
    dhcp_retry_tick = s.uptime() + 1000;
}

fn parseClasslessRoutes(frame: []const u8, start: usize, length: usize, options: *DhcpOptions, priority: u8) bool {
    if (priority < options.route_priority) return true;
    const end = start + length;
    var cursor = start;
    var routes: [8]s.Ipv4Route = @splat(.{});
    var route_count: usize = 0;
    while (cursor < end) {
        const prefix = frame[cursor];
        cursor += 1;
        if (prefix > 32) return false;
        const destination_bytes: usize = (@as(usize, prefix) + 7) / 8;
        if (cursor + destination_bytes + 4 > end) return false;
        var destination: [4]u8 = .{ 0, 0, 0, 0 };
        @memcpy(destination[0..destination_bytes], frame[cursor .. cursor + destination_bytes]);
        if (destination_bytes != 0 and prefix % 8 != 0) destination[destination_bytes - 1] &= @as(u8, 0xff) << @as(u3, @intCast(8 - prefix % 8));
        cursor += destination_bytes;
        var gateway: [4]u8 = undefined;
        @memcpy(&gateway, frame[cursor .. cursor + 4]);
        cursor += 4;
        if (route_count < routes.len) {
            routes[route_count] = .{ .destination = destination, .prefix_length = prefix, .gateway = gateway };
            route_count += 1;
        }
    }
    options.routes = routes;
    options.route_count = route_count;
    options.route_priority = priority;
    options.has_routes = true;
    return true;
}

fn parseDhcpOptions(frame: []const u8, start: usize, end: usize, options: *DhcpOptions, allow_overload: bool) bool {
    var cursor = start;
    while (cursor < end) {
        const tag = frame[cursor];
        cursor += 1;
        if (tag == 0) continue;
        if (tag == 255) return true;
        if (cursor >= end) return false;
        const length: usize = frame[cursor];
        cursor += 1;
        if (length > end - cursor) return false;
        switch (tag) {
            53 => if (length == 1) { options.message_type = frame[cursor]; },
            1 => if (length == 4) { @memcpy(&options.subnet, frame[cursor .. cursor + 4]); options.has_subnet = true; },
            3 => if (length >= 4 and length % 4 == 0) { @memcpy(&options.router, frame[cursor .. cursor + 4]); options.has_router = true; },
            6 => if (length >= 4 and length % 4 == 0) {
                @memcpy(&options.dns, frame[cursor .. cursor + 4]);
                options.has_dns = true;
                if (length >= 8) {
                    @memcpy(&options.dns_secondary, frame[cursor + 4 .. cursor + 8]);
                    options.has_dns_secondary = true;
                }
            },
            54 => if (length == 4) { @memcpy(&options.server, frame[cursor .. cursor + 4]); options.has_server = true; },
            51 => if (length == 4) { options.lease = get32(frame, cursor); },
            58 => if (length == 4) { options.renew = get32(frame, cursor); },
            59 => if (length == 4) { options.rebind = get32(frame, cursor); },
            26 => if (length == 2) { options.mtu = get16(frame, cursor); options.has_mtu = options.mtu >= 68; },
            52 => if (allow_overload and length == 1) {
                if ((frame[cursor] & 0xfc) != 0) return false;
                options.overload = frame[cursor];
            },
            121 => if (!parseClasslessRoutes(frame, cursor, length, options, 2)) return false,
            249 => if (!parseClasslessRoutes(frame, cursor, length, options, 1)) return false,
            else => {},
        }
        cursor += length;
    }
    return false;
}

fn handleDhcp(frame: []const u8, ip_header_len: usize, ip_total_len: usize) void {
    const udp = 14 + ip_header_len;
    if (ip_total_len < ip_header_len + 8 + 240 or frame.len < udp + 8) return;
    if (get16(frame, udp) != 67 or get16(frame, udp + 2) != 68) return;
    const udp_len = get16(frame, udp + 4);
    if (udp_len < 8 + 240 or udp_len > 1500 or udp_len != ip_total_len - ip_header_len or frame.len < udp + udp_len) return;
    if ((get16(frame, 20) & 0x3fff) != 0 or checksum(frame[14 .. 14 + ip_header_len]) != 0) return;
    const udp_checksum = get16(frame, udp + 6);
    if (udp_checksum != 0) {
        var pseudo: [12 + 1500]u8 = @splat(0);
        @memcpy(pseudo[0..8], frame[26..34]);
        pseudo[9] = 17;
        put16(&pseudo, 10, udp_len);
        @memcpy(pseudo[12 .. 12 + udp_len], frame[udp .. udp + udp_len]);
        if (checksum(pseudo[0 .. 12 + udp_len]) != 0) return;
    }
    const dhcp = udp + 8;
    if (frame[dhcp] != 2 or frame[dhcp + 1] != 1 or frame[dhcp + 2] != 6 or get32(frame, dhcp + 4) != dhcp_xid or !std.mem.eql(u8, frame[dhcp + 28 .. dhcp + 34], &mac_address)) return;
    if (get32(frame, dhcp + 236) != 0x63825363) return;

    var options: DhcpOptions = .{};
    const cursor = dhcp + 240;
    const end = udp + udp_len;
    if (!parseDhcpOptions(frame, cursor, end, &options, true)) return;
    if ((options.overload & 1) != 0 and !parseDhcpOptions(frame, dhcp + 108, dhcp + 236, &options, false)) return;
    if ((options.overload & 2) != 0 and !parseDhcpOptions(frame, dhcp + 44, dhcp + 108, &options, false)) return;
    if (options.has_subnet and !validSubnetMask(options.subnet)) return;
    switch (options.message_type) {
        2 => { // OFFER
            if (dhcp_state != .discovering or !options.has_server) return;
            const yiaddr = frame[dhcp + 16 .. dhcp + 20];
            if (!validUnicastAddress(yiaddr)) return;
            @memcpy(&offered_ip, frame[dhcp + 16 .. dhcp + 20]);
            dhcp_server = options.server;
            @memcpy(&dhcp_server_mac, frame[6..12]);
            dhcp_state = .requesting;
            sendDhcp(3);
        },
        5 => { // ACK
            if (dhcp_state != .requesting and dhcp_state != .renewing and dhcp_state != .rebinding) return;
            const initial_configuration = dhcp_state == .requesting;
            if (!options.has_server) return;
            if (dhcp_state == .requesting and !std.mem.eql(u8, &options.server, &dhcp_server)) return;
            if (dhcp_state == .renewing and options.has_server and !std.mem.eql(u8, &options.server, &dhcp_server)) return;
            const assigned_ip = frame[dhcp + 16 .. dhcp + 20];
            if (initial_configuration and !validUnicastAddress(assigned_ip)) return;
            if (!initial_configuration and (assigned_ip[0] | assigned_ip[1] | assigned_ip[2] | assigned_ip[3]) != 0 and !std.mem.eql(u8, assigned_ip, &s.ipv4_address)) return;
            if (assigned_ip[0] | assigned_ip[1] | assigned_ip[2] | assigned_ip[3] != 0) @memcpy(&s.ipv4_address, assigned_ip);
            if (options.has_server) dhcp_server = options.server;
            @memcpy(&dhcp_server_mac, frame[6..12]);
            if (options.has_subnet) {
                s.ipv4_subnet = options.subnet;
            } else if (initial_configuration) {
                s.ipv4_subnet = defaultSubnetMask(s.ipv4_address);
            }
            if (options.has_mtu) s.ipv4_mtu = @min(options.mtu, 1500);
            if (options.has_router) s.ipv4_gateway = options.router;
            if (options.has_dns) {
                s.ipv4_dns = options.dns;
                s.ipv4_dns_secondary = if (options.has_dns_secondary) options.dns_secondary else .{ 0, 0, 0, 0 };
            }
            if (initial_configuration and !options.has_routes) s.ipv4_route_count = 0;
            if (options.has_routes) {
                s.ipv4_routes = options.routes;
                s.ipv4_route_count = options.route_count;
                s.ipv4_gateway = .{ 0, 0, 0, 0 };
                for (options.routes[0..options.route_count]) |route| {
                    if (route.prefix_length == 0) {
                        s.ipv4_gateway = route.gateway;
                        break;
                    }
                }
            }
            if (options.lease != 0) lease_seconds = options.lease;
            if (lease_seconds == 0) lease_seconds = 3600;
            renew_seconds = if (options.renew != 0 and options.renew < lease_seconds) options.renew else lease_seconds / 2;
            const default_rebind: u32 = @intCast((@as(u64, lease_seconds) * 7) / 8);
            rebind_seconds = if (options.rebind > renew_seconds and options.rebind < lease_seconds) options.rebind else default_rebind;
            lease_start_tick = s.uptime();
            if (initial_configuration) {
                offered_ip = s.ipv4_address;
                dhcp_probe_count = 0;
                dhcp_probe_tick = s.uptime();
                s.network_configured = false;
                dhcp_state = .probing;
            } else {
                s.network_configured = true;
                dhcp_state = .configured;
            }
            s.network_updated = true;
        },
        6 => { // NAK
            if (dhcp_state != .requesting and dhcp_state != .renewing and dhcp_state != .rebinding) return;
            if (!options.has_server) return;
            if (dhcp_state != .rebinding and !std.mem.eql(u8, &options.server, &dhcp_server)) return;
            clearNetworkConfiguration();
            dhcp_state = .idle;
            dhcp_retry_tick = s.uptime() + 100;
        },
        else => {},
    }
}

pub fn linkUp() bool {
    const regs = registers orelse return false;
    return (regs[0x0008 / 4] & (1 << 1)) != 0;
}

fn processFrame(frame: []const u8) void {
    if (frame.len < 14) return;
    const ether_type = (@as(u16, frame[12]) << 8) | frame[13];
    switch (ether_type) {
        0x0806 => { // ARP
            if (frame.len < 42) return;
            const hardware_type = (@as(u16, frame[14]) << 8) | frame[15];
            const protocol_type = (@as(u16, frame[16]) << 8) | frame[17];
            const hardware_len = frame[18];
            const protocol_len = frame[19];
            if (hardware_type != 1 or protocol_type != 0x0800 or hardware_len != 6 or protocol_len != 4) return;
            const operation = (@as(u16, frame[20]) << 8) | frame[21];
            if (operation != 1 and operation != 2) return;
            if (dhcpAddressConflict(frame)) {
                declineAddress();
                return;
            }
            s.ethernet_arp_frames +%= 1;
        },
        0x0800 => { // IPv4; validate the variable-sized header and packet length.
            if (frame.len < 34 or (frame[14] >> 4) != 4) return;
            const header_len: usize = @as(usize, frame[14] & 0x0f) * 4;
            if (header_len < 20 or frame.len < 14 + header_len) return;
            const total_len = (@as(usize, frame[16]) << 8) | frame[17];
            if (total_len < header_len or total_len > frame.len - 14) return;
            s.ethernet_ipv4_frames +%= 1;
            if (frame[14 + 9] == 17) handleDhcp(frame, header_len, total_len);
        },
        0x86dd => { // IPv6 base header.
            if (frame.len < 54 or (frame[14] >> 4) != 6) return;
            const payload_len = (@as(usize, frame[18]) << 8) | frame[19];
            if (payload_len > frame.len - 54) return;
            s.ethernet_ipv6_frames +%= 1;
        },
        else => return,
    }
    s.ethernet_rx_frames +%= 1;
}

pub fn poll(on_frame: *const fn ([]const u8) void) void {
    if (registers == null) return;
    var processed: usize = 0;
    while (processed < rx_count) : (processed += 1) {
        const descriptor = &rx_descriptors[rx_index];
        const status: *volatile u8 = @ptrCast(&descriptor.status);
        if ((status.* & 1) == 0) break; // Descriptor not yet done.
        const descriptor_length: *volatile u16 = @ptrCast(&descriptor.length);
        const descriptor_errors: *volatile u8 = @ptrCast(&descriptor.errors);
        const length: usize = descriptor_length.*;
        if (descriptor_errors.* == 0 and length >= 14 and length <= rx_buffer_size) {
            processFrame(rx_buffers[rx_index][0..length]);
            on_frame(rx_buffers[rx_index][0..length]);
        }
        descriptor.length = 0;
        descriptor.checksum = 0;
        status.* = 0;
        descriptor.errors = 0;
        descriptor.special = 0;
        asm volatile ("" ::: .{ .memory = true });
        writeRegister(0x2818, @intCast(rx_index));
        rx_index = (rx_index + 1) % rx_count;
    }
    if (!linkUp()) {
        if (dhcp_state != .idle or s.network_configured) clearNetworkConfiguration();
        dhcp_state = .idle;
        offered_ip = .{ 0, 0, 0, 0 };
        dhcp_retry_tick = s.uptime() + 100;
        return;
    }
    if (dhcp_state == .probing) {
        if (dhcp_probe_count < 3 and s.uptime() >= dhcp_probe_tick) {
            if (sendArpProbe(offered_ip)) {
                dhcp_probe_count += 1;
                dhcp_probe_tick = s.uptime() + 10;
            }
        } else if (dhcp_probe_count == 3 and s.uptime() >= dhcp_probe_tick + 200) {
            s.network_configured = true;
            s.network_updated = true;
            dhcp_state = .configured;
        }
        return;
    }
    if (dhcp_state == .configured) {
        const elapsed_seconds = (s.uptime() -| lease_start_tick) / 100;
        if (elapsed_seconds >= lease_seconds) {
            clearNetworkConfiguration();
            dhcp_state = .idle;
            dhcp_retry_tick = s.uptime();
        } else if (elapsed_seconds >= renew_seconds) {
            dhcp_state = .renewing;
            sendDhcp(3);
            return;
        } else return;
    }
    if (dhcp_state == .renewing and (s.uptime() -| lease_start_tick) / 100 >= rebind_seconds) {
        dhcp_state = .rebinding;
        sendDhcp(3);
    } else if ((dhcp_state == .renewing or dhcp_state == .rebinding or dhcp_state == .requesting) and s.uptime() >= dhcp_retry_tick) {
        sendDhcp(3);
    } else if (dhcp_state == .idle and s.uptime() >= dhcp_retry_tick) {
        var random_material: [4]u8 = undefined;
        if (!entropy_source.fill(&random_material)) {
            dhcp_retry_tick = s.uptime() + 100;
            return;
        }
        dhcp_xid = get32(&random_material, 0);
        if (dhcp_xid == 0) dhcp_xid = 0x41544852;
        dhcp_state = .discovering;
        sendDhcp(1);
    }
}
