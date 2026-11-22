//! Small polling xHCI host path for one USB Mass Storage BOT device.
//! DMA objects are static kernel objects in the low, identity-mapped image.
const io = @import("../arch/io.zig");
const pci = @import("pci.zig");
const vm = @import("../memory/vm.zig");

const Trb = extern struct { parameter: u64 = 0, status: u32 = 0, control: u32 = 0 };
const trb_count = 256;
const max_ports = 64;
const max_endpoint_contexts = 32;
const event_count = 256;
const ctx_words = 16;
const timeout_polls = 20_000_000;

var ready = false;
var storage_ready = false;
var mmio: u64 = 0;
var cap_length: u8 = 0;
var doorbell_offset: u32 = 0;
var runtime_offset: u32 = 0;
var max_slots: u8 = 0;
var max_usb_ports: u8 = 0;
var context_dwords: usize = 8;
var command_ring: [trb_count]Trb align(64) = @splat(.{});
var event_ring: [event_count]Trb align(64) = @splat(.{});
var event_segment: extern struct { address: u64, size: u16, reserved: u16 = 0, reserved2: u32 = 0 } align(64) = .{ .address = 0, .size = event_count };
var dcbaa: [256]u64 align(64) = @splat(0);
var input_context: [ctx_words * 33]u32 align(64) = @splat(0);
var output_context: [ctx_words * 33]u32 align(64) = @splat(0);
var ep0_ring: [trb_count]Trb align(64) = @splat(.{});
var bulk_in_ring: [trb_count]Trb align(64) = @splat(.{});
var bulk_out_ring: [trb_count]Trb align(64) = @splat(.{});
var control_buffer: [1024]u8 align(64) = @splat(0);
var bulk_buffer: [4096]u8 align(64) = @splat(0);
var command_index: usize = 0;
var command_cycle: u1 = 1;
var event_index: usize = 0;
var event_cycle: u1 = 1;
var ep0_index: usize = 0;
var ep0_cycle: u1 = 1;
var bulk_in_index: usize = 0;
var bulk_in_cycle: u1 = 1;
var bulk_out_index: usize = 0;
var bulk_out_cycle: u1 = 1;
var slot_id: u8 = 0;
var ep0_packet: u16 = 8;
var mass_in_ep: u8 = 0;
var mass_out_ep: u8 = 0;
var mass_in_packet: u16 = 512;
var mass_out_packet: u16 = 512;
var configuration_value: u8 = 0;
var storage_blocks: u32 = 0;
var storage_port: u8 = 0xff;
var attempted_ports: u64 = 0;
var diagnostic: []const u8 = "xHCI is not initialized";
var tag: u32 = 1;

fn mmio32(offset: u64) *volatile u32 {
    return @ptrFromInt(mmio + offset);
}
fn read32(offset: u64) u32 {
    return mmio32(offset).*;
}
fn write32(offset: u64, value: u32) void {
    mmio32(offset).* = value;
}
fn read64(offset: u64) u64 {
    const low: u64 = read32(offset);
    const high: u64 = read32(offset + 4);
    return low | (high << 32);
}
fn write64(offset: u64, value: u64) void {
    write32(offset, @truncate(value));
    write32(offset + 4, @truncate(value >> 32));
}

fn cfgRead(device: pci.Device, offset: u8) u32 {
    const address = 0x8000_0000 | (@as(u32, device.bus) << 16) | (@as(u32, device.slot) << 11) |
        (@as(u32, device.function) << 8) | (@as(u32, offset) & 0xfc);
    io.out32(0x0cf8, address);
    return io.in32(0x0cfc);
}
fn cfgWrite(device: pci.Device, offset: u8, value: u32) void {
    const address = 0x8000_0000 | (@as(u32, device.bus) << 16) | (@as(u32, device.slot) << 11) |
        (@as(u32, device.function) << 8) | (@as(u32, offset) & 0xfc);
    io.out32(0x0cf8, address);
    io.out32(0x0cfc, value);
}

fn contextWord(context: *[ctx_words * 33]u32, context_index: usize, dword: usize) *u32 {
    return &context[context_index * context_dwords + dword];
}
fn setTrb(trb: *Trb, parameter: u64, status: u32, control: u32) void {
    trb.* = .{ .parameter = parameter, .status = status, .control = control };
}

fn nextEvent() ?Trb {
    var spin: usize = 0;
    while (spin < timeout_polls) : (spin += 1) {
        const event_ptr: *volatile Trb = @ptrFromInt(@intFromPtr(&event_ring[event_index]));
        const control = event_ptr.control;
        if ((control & 1) == event_cycle) {
            const event = event_ptr.*;
            event_index += 1;
            if (event_index == event_ring.len) {
                event_index = 0;
                event_cycle ^= 1;
            }
            write64(runtime_offset + 0x38, @intFromPtr(&event_ring[event_index]) | 8);
            return event;
        }
        asm volatile ("pause");
    }
    return null;
}

fn pushCommand(parameter: u64, status: u32, control: u32) bool {
    if (command_index >= trb_count - 1) return false;
    command_ring[command_index] = .{ .parameter = parameter, .status = status, .control = (control & ~@as(u32, 1)) | command_cycle };
    command_index += 1;
    if (command_index == trb_count - 1) {
        command_ring[command_index] = .{ .parameter = @intFromPtr(&command_ring), .status = 0, .control = (6 << 10) | 2 | @as(u32, command_cycle) };
        command_index = 0;
        command_cycle ^= 1;
    }
    write32(doorbell_offset, 0);
    return true;
}

fn commandCompletion() ?Trb {
    var tries: usize = 0;
    while (tries < 16) : (tries += 1) {
        const event = nextEvent() orelse return null;
        if (((event.control >> 10) & 0x3f) == 33) return event;
    }
    return null;
}

fn runCommand(parameter: u64, status: u32, control: u32) ?Trb {
    if (!pushCommand(parameter, status, control)) return null;
    return commandCompletion();
}

fn pushEp0(parameter: u64, status: u32, control: u32) bool {
    if (ep0_index >= trb_count - 1) return false;
    ep0_ring[ep0_index] = .{ .parameter = parameter, .status = status, .control = (control & ~@as(u32, 1)) | ep0_cycle };
    ep0_index += 1;
    if (ep0_index == trb_count - 1) {
        ep0_ring[ep0_index] = .{ .parameter = @intFromPtr(&ep0_ring), .status = 0, .control = (6 << 10) | 2 | @as(u32, ep0_cycle) };
        ep0_index = 0;
        ep0_cycle ^= 1;
    }
    return true;
}

fn controlRequest(request_type: u8, request: u8, value: u16, index: u16, data: []u8) bool {
    const setup: u64 = @as(u64, request_type) | (@as(u64, request) << 8) | (@as(u64, value) << 16) |
        (@as(u64, index) << 32) | (@as(u64, @intCast(data.len)) << 48);
    const has_data = data.len != 0;
    const setup_type: u32 = (2 << 10) | (1 << 6) | (if (has_data) @as(u32, 3) else @as(u32, 0)) << 16 | (if (has_data) @as(u32, 1 << 4) else 0);
    if (!pushEp0(setup, 8, setup_type)) return false;
    if (has_data) {
        const in_data = (request_type & 0x80) != 0;
        if (!pushEp0(@intFromPtr(data.ptr), @intCast(data.len), (3 << 10) | (1 << 4) | (if (in_data) @as(u32, 1 << 16) else 0) | ep0_cycle)) return false;
    }
    const status_in = !has_data or (request_type & 0x80) == 0;
    if (!pushEp0(0, 0, (4 << 10) | (1 << 5) | (if (status_in) @as(u32, 1 << 16) else 0) | ep0_cycle)) return false;
    write32(doorbell_offset + @as(u32, slot_id) * 4, 1);
    var spin: usize = 0;
    while (spin < 32) : (spin += 1) {
        const event = nextEvent() orelse return false;
        if (((event.control >> 10) & 0x3f) != 32) continue;
        if (((event.control >> 24) & 0xff) != slot_id) continue;
        return ((event.status >> 24) & 0xff) == 1;
    }
    return false;
}

fn resetPort(port: usize) bool {
    const offset = @as(u64, cap_length) + 0x400 + @as(u64, port) * 0x10;
    const reg = mmio32(offset);
    const value = reg.*;
    if ((value & 1) == 0) return false;
    const speed = (value >> 10) & 0xf;
    const reset_bit: u32 = if (speed >= 4) 1 << 31 else 1 << 4;
    reg.* = reset_bit;
    var spin: usize = 0;
    while (spin < timeout_polls) : (spin += 1) {
        const state = reg.*;
        if ((state & (1 << 1)) != 0 and (state & reset_bit) == 0) return true;
        asm volatile ("pause");
    }
    return false;
}

fn enumerateStorage(port: usize) bool {
    diagnostic = "xHCI: resetting USB port";
    if (!resetPort(port)) {
        diagnostic = "xHCI: port reset failed";
        return false;
    }
    const portsc = read32(@as(u64, cap_length) + 0x400 + @as(u64, port) * 0x10);
    const speed: u8 = @truncate((portsc >> 10) & 0xf);
    ep0_packet = switch (speed) {
        1, 2 => 8,
        3 => 64,
        4 => 512,
        else => return false,
    };
    const enable = runCommand(0, 0, (9 << 10)); // Enable Slot using the default protocol slot type.
    if (enable == null or ((enable.?.status >> 24) & 0xff) != 1) {
        diagnostic = "xHCI: Enable Slot failed";
        return false;
    }
    slot_id = @truncate(enable.?.control >> 24);
    if (slot_id == 0 or slot_id >= max_slots) {
        diagnostic = "xHCI: invalid slot id";
        return false;
    }
    @memset(&input_context, 0);
    @memset(&output_context, 0);
    @memset(&ep0_ring, .{});
    ep0_index = 0;
    ep0_cycle = 1;
    dcbaa[slot_id] = @intFromPtr(&output_context);
    contextWord(&input_context, 0, 1).* = 3; // Add slot and EP0 contexts.
    contextWord(&input_context, 1, 0).* = (@as(u32, speed) << 20) | (1 << 27);
    contextWord(&input_context, 1, 1).* = @as(u32, @intCast(port + 1)) << 16;
    contextWord(&input_context, 2, 1).* = (@as(u32, ep0_packet) << 16) | 3 | (4 << 3);
    contextWord(&input_context, 2, 2).* = @as(u32, @truncate(@intFromPtr(&ep0_ring))) | 1;
    contextWord(&input_context, 2, 3).* = @truncate(@intFromPtr(&ep0_ring) >> 32);
    contextWord(&input_context, 2, 4).* = 8;
    const address = runCommand(@intFromPtr(&input_context), 0, (11 << 10) | (@as(u32, slot_id) << 24));
    if (address == null or ((address.?.status >> 24) & 0xff) != 1) {
        diagnostic = "xHCI: Address Device failed";
        return false;
    }
    // Read the configuration descriptor header, then the full descriptor set.
    @memset(&control_buffer, 0);
    diagnostic = "xHCI: reading USB configuration header";
    if (!controlRequest(0x80, 6, 0x0200, 0, control_buffer[0..9])) {
        diagnostic = "xHCI: configuration header request failed";
        return false;
    }
    const total_len = @as(usize, control_buffer[2]) | (@as(usize, control_buffer[3]) << 8);
    if (total_len < 9 or total_len > control_buffer.len) {
        diagnostic = "xHCI: invalid configuration length";
        return false;
    }
    if (!controlRequest(0x80, 6, 0x0200, 0, control_buffer[0..total_len])) {
        diagnostic = "xHCI: configuration transfer failed";
        return false;
    }
    var off: usize = 0;
    var interface_storage = false;
    var endpoints: u8 = 0;
    var interface_number: u8 = 0;
    var found_config = false;
    while (off + 2 <= total_len) {
        const length: usize = control_buffer[off];
        if (length < 2 or off + length > total_len) return false;
        const dtype = control_buffer[off + 1];
        if (dtype == 4 and length >= 9) {
            interface_storage = control_buffer[off + 5] == 8 and control_buffer[off + 6] == 6 and control_buffer[off + 7] == 0x50;
            if (interface_storage) {
                interface_number = control_buffer[off + 2];
                endpoints = 0;
            }
        } else if (dtype == 5 and length >= 7 and interface_storage and (control_buffer[off + 3] & 3) == 2) {
            const address_byte = control_buffer[off + 2];
            const packet: u16 = @as(u16, control_buffer[off + 4]) | (@as(u16, control_buffer[off + 5]) << 8);
            if ((address_byte & 0x80) != 0) {
                mass_in_ep = address_byte & 0x0f;
                mass_in_packet = packet;
                endpoints |= 1;
            } else {
                mass_out_ep = address_byte & 0x0f;
                mass_out_packet = packet;
                endpoints |= 2;
            }
            if (endpoints == 3) {
                found_config = true;
                break;
            }
        } else if (dtype == 2 and length >= 9) configuration_value = control_buffer[off + 5];
        off += length;
    }
    if (!found_config or configuration_value == 0) {
        diagnostic = "USB device has no BOT mass-storage interface";
        return false;
    }
    if (!controlRequest(0, 9, configuration_value, 0, &.{})) {
        diagnostic = "xHCI: SET_CONFIGURATION failed";
        return false;
    }
    // Endpoint IDs: OUT=2*n-1, IN=2*n. Configure both bulk endpoint contexts.
    const out_id: usize = @as(usize, mass_out_ep) * 2 - 1;
    const in_id: usize = @as(usize, mass_in_ep) * 2;
    if (out_id >= max_endpoint_contexts or in_id >= max_endpoint_contexts) {
        diagnostic = "USB storage endpoint number unsupported";
        return false;
    }
    @memset(&input_context, 0);
    contextWord(&input_context, 0, 1).* = 1 | (@as(u32, 1) << @intCast(out_id)) | (@as(u32, 1) << @intCast(in_id));
    contextWord(&input_context, 1, 0).* = (@as(u32, speed) << 20) | (@as(u32, @intCast(@max(out_id, in_id))) << 27);
    contextWord(&input_context, 1, 1).* = @as(u32, @intCast(port + 1)) << 16;
    @memset(&ep0_ring, .{});
    @memset(&bulk_in_ring, .{});
    @memset(&bulk_out_ring, .{});
    bulk_in_index = 0;
    bulk_out_index = 0;
    bulk_in_cycle = 1;
    bulk_out_cycle = 1;
    setBulkContext(out_id, mass_out_packet, false);
    setBulkContext(in_id, mass_in_packet, true);
    const configure = runCommand(@intFromPtr(&input_context), 0, (12 << 10) | (@as(u32, slot_id) << 24));
    if (configure == null or ((configure.?.status >> 24) & 0xff) != 1) {
        diagnostic = "xHCI: Configure Endpoint failed";
        return false;
    }
    diagnostic = "USB Mass Storage BOT endpoints configured";
    return true;
}

fn setBulkContext(id: usize, packet: u16, input: bool) void {
    const ring_address: u64 = if (input) @intFromPtr(&bulk_in_ring) else @intFromPtr(&bulk_out_ring);
    contextWord(&input_context, id + 1, 1).* = (@as(u32, packet) << 16) | 3 | (@as(u32, if (input) 6 else 2) << 3);
    contextWord(&input_context, id + 1, 2).* = @as(u32, @truncate(ring_address)) | 1;
    contextWord(&input_context, id + 1, 3).* = @truncate(ring_address >> 32);
    contextWord(&input_context, id + 1, 4).* = packet;
}

fn bulkTransfer(input: bool, buffer: []u8) bool {
    if (buffer.len == 0 or buffer.len > bulk_buffer.len) return false;
    const id: usize = if (input) @as(usize, mass_in_ep) * 2 else @as(usize, mass_out_ep) * 2 - 1;
    var ring = if (input) &bulk_in_ring else &bulk_out_ring;
    const index = if (input) &bulk_in_index else &bulk_out_index;
    const cycle = if (input) &bulk_in_cycle else &bulk_out_cycle;
    if (input) {
        @memset(bulk_buffer[0..buffer.len], 0);
    } else {
        @memcpy(bulk_buffer[0..buffer.len], buffer);
    }
    ring[index.*] = .{ .parameter = @intFromPtr(&bulk_buffer), .status = @intCast(buffer.len), .control = (1 << 10) | (1 << 5) | @as(u32, cycle.*) };
    index.* += 1;
    if (index.* == trb_count - 1) {
        ring[index.*] = .{ .parameter = @intFromPtr(ring), .status = 0, .control = (6 << 10) | 2 | @as(u32, cycle.*) };
        index.* = 0;
        cycle.* ^= 1;
    }
    write32(doorbell_offset + @as(u32, slot_id) * 4, @intCast(id));
    var spin: usize = 0;
    var completed = false;
    while (spin < 32) : (spin += 1) {
        const event = nextEvent() orelse break;
        if (((event.control >> 10) & 0x3f) == 32 and ((event.control >> 24) & 0xff) == slot_id and ((event.control >> 16) & 0x1f) == id) {
            completed = ((event.status >> 24) & 0xff) == 1;
            break;
        }
    }
    if (input and completed) @memcpy(buffer, bulk_buffer[0..buffer.len]);
    return completed;
}

fn botCommand(command_bytes: []const u8, input: bool, data: []u8) bool {
    const command_tag = tag;
    tag +%= 1;
    var cbw: [31]u8 = @splat(0);
    if (command_bytes.len == 0 or command_bytes.len > 16) return false;
    putLe32(&cbw, 0, 0x43425355);
    putLe32(&cbw, 4, command_tag);
    putLe32(&cbw, 8, @intCast(data.len));
    cbw[12] = if (input) 0x80 else 0;
    cbw[14] = @intCast(command_bytes.len);
    @memcpy(cbw[15 .. 15 + command_bytes.len], command_bytes);
    if (!bulkTransfer(false, &cbw)) return false;
    if (data.len != 0 and !bulkTransfer(input, data)) return false;
    var csw: [13]u8 = undefined;
    if (!bulkTransfer(true, &csw)) return false;
    return getLe32(&csw, 0) == 0x53425355 and getLe32(&csw, 4) == command_tag and csw[12] == 0;
}

fn putLe32(bytes: []u8, offset: usize, value: u32) void {
    bytes[offset] = @truncate(value);
    bytes[offset + 1] = @truncate(value >> 8);
    bytes[offset + 2] = @truncate(value >> 16);
    bytes[offset + 3] = @truncate(value >> 24);
}
fn getLe32(bytes: []const u8, offset: usize) u32 {
    return @as(u32, bytes[offset]) | (@as(u32, bytes[offset + 1]) << 8) |
        (@as(u32, bytes[offset + 2]) << 16) | (@as(u32, bytes[offset + 3]) << 24);
}

fn be32(bytes: []const u8, offset: usize) u32 {
    return (@as(u32, bytes[offset]) << 24) | (@as(u32, bytes[offset + 1]) << 16) | (@as(u32, bytes[offset + 2]) << 8) | bytes[offset + 3];
}

pub fn init() bool {
    ready = false;
    storage_ready = false;
    diagnostic = "xHCI: looking for controller";
    const device = blk: {
        for (pci.devices()) |candidate| if (candidate.class == 0x0c and candidate.subclass == 0x03 and candidate.programming_interface == 0x30) break :blk candidate;
        break :blk null;
    } orelse {
        diagnostic = "No xHCI controller";
        return false;
    };
    const bar = cfgRead(device, 0x10);
    if (bar == 0 or (bar & 1) != 0) return false;
    var physical: u64 = bar & 0xfffffff0;
    if ((bar & 6) == 4) physical |= @as(u64, cfgRead(device, 0x14)) << 32;
    if (physical == 0) {
        diagnostic = "xHCI BAR is not assigned";
        return false;
    }
    const mapped_mmio = vm.mapMmio(physical, 0x4000) orelse {
        diagnostic = "xHCI BAR MMIO mapping failed";
        return false;
    };
    mmio = @intFromPtr(mapped_mmio);
    const command = cfgRead(device, 4);
    cfgWrite(device, 4, (command & 0xffff) | 6);
    cap_length = @truncate(read32(0) & 0xff);
    const hcs1 = read32(4);
    max_slots = @truncate(hcs1 & 0xff);
    max_usb_ports = @truncate(hcs1 >> 24);
    if (cap_length < 0x20 or max_slots == 0 or max_usb_ports == 0 or max_usb_ports > max_ports) {
        diagnostic = "xHCI capability registers invalid";
        return false;
    }
    context_dwords = if ((read32(0x10) & 4) != 0) 16 else 8;
    doorbell_offset = read32(0x14) & ~@as(u32, 3);
    runtime_offset = read32(0x18) & ~@as(u32, 0x1f);
    const op: u64 = cap_length;
    takeOwnership(read32(0x10));
    write32(op, read32(op) & ~@as(u32, 1)); // Stop firmware-owned controller before reset.
    var spin: usize = 0;
    while (spin < timeout_polls and (read32(op + 4) & 1) == 0) : (spin += 1) asm volatile ("pause");
    if ((read32(op + 4) & 1) == 0) {
        diagnostic = "xHCI did not halt";
        return false;
    }
    spin = 0;
    write32(op, read32(op) | 2); // Host controller reset.
    while (spin < timeout_polls and (read32(op) & 2) != 0) : (spin += 1) asm volatile ("pause");
    if ((read32(op) & 2) != 0) {
        diagnostic = "xHCI reset timed out";
        return false;
    }
    spin = 0;
    while (spin < timeout_polls and (read32(op + 4) & (1 << 11)) != 0) : (spin += 1) asm volatile ("pause");
    if ((read32(op + 4) & (1 << 11)) != 0) {
        diagnostic = "xHCI controller not ready after reset";
        return false;
    }
    @memset(&dcbaa, 0);
    @memset(&command_ring, .{});
    @memset(&event_ring, .{});
    command_index = 0;
    command_cycle = 1;
    event_index = 0;
    event_cycle = 1;
    command_ring[trb_count - 1] = .{ .parameter = @intFromPtr(&command_ring), .status = 0, .control = (6 << 10) | 2 | 1 };
    event_segment.address = @intFromPtr(&event_ring);
    event_segment.size = event_count;
    write64(op + 0x30, @intFromPtr(&dcbaa));
    write64(op + 0x18, @intFromPtr(&command_ring) | 1);
    write32(op + 0x38, max_slots);
    write32(runtime_offset + 0x20, 0); // Poll events; disable interrupter IRQ.
    write32(runtime_offset + 0x24, 0);
    write32(runtime_offset + 0x28, 1);
    write64(runtime_offset + 0x30, @intFromPtr(&event_segment));
    write64(runtime_offset + 0x38, @intFromPtr(&event_ring));
    write32(op, read32(op) | 1);
    spin = 0;
    while (spin < timeout_polls and (read32(op + 4) & 1) != 0) : (spin += 1) asm volatile ("pause");
    if ((read32(op + 4) & 1) != 0) {
        diagnostic = "xHCI failed to start";
        return false;
    }
    ready = true;
    diagnostic = "xHCI running; scanning USB ports";
    // Enumerate connected ports in order and keep the first BOT storage device.
    attempted_ports = 0;
    for (0..max_usb_ports) |port| if ((read32(op + 0x400 + port * 0x10) & 1) != 0) {
        attempted_ports |= @as(u64, 1) << @intCast(port);
        if (enumerateStorage(port)) {
            storage_ready = probeCapacity();
            if (storage_ready) {
                diagnostic = "USB Mass Storage ready (SCSI block size 512)";
                storage_port = @intCast(port);
                return true;
            }
            diagnostic = "USB BOT device found; READ CAPACITY failed";
        }
    };
    return true;
}

fn takeOwnership(hcc: u32) void {
    var offset: u64 = @as(u64, (hcc >> 16) & 0xffff) * 4;
    var guard: usize = 0;
    while (offset != 0 and guard < 64) : (guard += 1) {
        const header = read32(offset);
        const id = header & 0xff;
        const next = (header >> 8) & 0xff;
        if (id == 1) {
            write32(offset, header | 2); // OS Owned Semaphore.
            var spin: usize = 0;
            while (spin < 1_000_000 and (read32(offset) & 1) != 0) : (spin += 1) asm volatile ("pause");
            write32(offset + 4, 0xffff_0000); // Disable legacy SMI sources.
        }
        if (next == 0) break;
        offset += @as(u64, next) * 4;
    }
}

fn probeCapacity() bool {
    var capacity: [8]u8 = @splat(0);
    const cmd = [_]u8{ 0x25, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    if (!botCommand(&cmd, true, &capacity)) return false;
    const last_lba = be32(&capacity, 0);
    const block_size = be32(&capacity, 4);
    if (block_size != 512 or last_lba == 0) return false;
    storage_blocks = last_lba +| 1;
    return true;
}

pub fn hasStorage() bool {
    return storage_ready;
}
pub fn diagnosticText() []const u8 {
    return diagnostic;
}
pub fn capacityBlocks() u32 {
    return storage_blocks;
}
pub fn readSector(lba: u32, output: *[512]u8) bool {
    if (!storage_ready or lba >= storage_blocks) return false;
    const cmd = [_]u8{ 0x28, 0, @truncate(lba >> 24), @truncate(lba >> 16), @truncate(lba >> 8), @truncate(lba), 0, 0, 0, 1 };
    return botCommand(&cmd, true, output);
}
pub fn writeSector(lba: u32, input: *const [512]u8) bool {
    if (!storage_ready or lba >= storage_blocks) return false;
    var data: [512]u8 = input.*;
    const cmd = [_]u8{ 0x2a, 0, @truncate(lba >> 24), @truncate(lba >> 16), @truncate(lba >> 8), @truncate(lba), 0, 0, 0, 1 };
    return botCommand(&cmd, false, &data);
}

pub fn connectedPorts() u8 {
    if (!ready) return 0;
    var count: u8 = 0;
    for (0..max_usb_ports) |port| if ((read32(@as(u64, cap_length) + 0x400 + port * 0x10) & 1) != 0) {
        count +|= 1;
    };
    return count;
}

pub fn connectedBitmap() u64 {
    if (!ready) return 0;
    var bitmap: u64 = 0;
    for (0..max_usb_ports) |port| {
        if ((read32(@as(u64, cap_length) + 0x400 + port * 0x10) & 1) != 0)
            bitmap |= @as(u64, 1) << @intCast(port);
    }
    return bitmap;
}

pub fn pollStorage() bool {
    if (!ready) return false;
    var changed = false;
    for (0..max_usb_ports) |port| {
        const bit = @as(u64, 1) << @intCast(port);
        const connected = (read32(@as(u64, cap_length) + 0x400 + port * 0x10) & 1) != 0;
        if (!connected) {
            if ((attempted_ports & bit) != 0) attempted_ports &= ~bit;
            if (storage_ready and storage_port == port) {
                _ = runCommand(0, 0, (10 << 10) | (@as(u32, slot_id) << 24));
                storage_ready = false;
                storage_port = 0xff;
                storage_blocks = 0;
                changed = true;
            }
            continue;
        }
        if ((attempted_ports & bit) != 0 or storage_ready) continue;
        attempted_ports |= bit;
        if (enumerateStorage(port) and probeCapacity()) {
            storage_ready = true;
            storage_port = @intCast(port);
            changed = true;
            break;
        }
    }
    return changed;
}
