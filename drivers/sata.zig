//! Native AHCI SATA disk driver. Uses one DMA command slot per request and
//! exposes 512-byte ATA sectors to the existing filesystem block path.
const pci = @import("pci.zig");
const std = @import("std");
const vm = @import("../memory/vm.zig");
const pmm = @import("../memory/pmm.zig");
const panic_report = @import("../system/panic.zig");

const max_ports = 32;
const max_disks = 2;
const wait_limit: u32 = 10_000_000;
const DmaPage = struct { physical: u64, virtual: [*]u8 };
const Port = struct {
    regs: [*]volatile u32,
    command_list: DmaPage,
    received_fis: DmaPage,
    command_table: DmaPage,
    data: DmaPage,
    hardware_port: u8,
};

var disks: [max_disks]Port = undefined;
var disk_count: usize = 0;
var initialized = false;
var controller_found = false;

fn put16(bytes: []u8, offset: usize, value: u16) void {
    bytes[offset] = @truncate(value);
    bytes[offset + 1] = @truncate(value >> 8);
}
fn put32(bytes: []u8, offset: usize, value: u32) void {
    bytes[offset] = @truncate(value);
    bytes[offset + 1] = @truncate(value >> 8);
    bytes[offset + 2] = @truncate(value >> 16);
    bytes[offset + 3] = @truncate(value >> 24);
}
fn put64(bytes: []u8, offset: usize, value: u64) void {
    put32(bytes, offset, @truncate(value));
    put32(bytes, offset + 4, @truncate(value >> 32));
}
fn allocDmaPage() ?DmaPage {
    const physical = pmm.allocatePage() orelse return null;
    const virtual = vm.physicalToVirtual(physical);
    const bytes: [*]u8 = @ptrFromInt(virtual);
    @memset(bytes[0..4096], 0);
    return .{ .physical = physical, .virtual = bytes };
}
fn delay() void {
    asm volatile ("pause");
}
fn waitMask(reg: *volatile u32, mask: u32, expected: u32) bool {
    var i: u32 = 0;
    while (i < wait_limit) : (i += 1) {
        if ((reg.* & mask) == expected) return true;
        delay();
    }
    return false;
}
fn stopPort(regs: [*]volatile u32) bool {
    regs[6] &= ~@as(u32, 1 << 0); // Stop command processing first.
    if (!waitMask(&regs[6], 1 << 15, 0)) return false;
    regs[6] &= ~@as(u32, 1 << 4); // Then stop FIS reception.
    return waitMask(&regs[6], 1 << 14, 0);
}
fn startPort(regs: [*]volatile u32) bool {
    regs[6] |= 1 << 4;
    if (!waitMask(&regs[6], 1 << 14, 1 << 14)) return false;
    regs[6] |= 1;
    return true;
}
fn setupPort(hba: [*]volatile u8, hardware_port: u8) bool {
    const regs: [*]volatile u32 = @ptrCast(@alignCast(hba + 0x100 + @as(usize, hardware_port) * 0x80));
    const ssts = regs[10];
    if ((ssts & 0xf) != 3 or ((ssts >> 8) & 0xf) != 1 or regs[9] != 0x0000_0101) {
        if ((ssts & 0xf) != 0) {
            var message: [80]u8 = undefined;
            const formatted = std.fmt.bufPrint(&message, "AHCI port status=0x{x} signature=0x{x}", .{ ssts, regs[9] }) catch "AHCI port status unavailable";
            panic_report.trace(formatted);
        }
        return false;
    }
    if (!stopPort(regs)) {
        panic_report.trace("AHCI: failed to stop command engine on connected port");
        return false;
    }

    const command_list = allocDmaPage() orelse {
        panic_report.trace("AHCI: DMA page allocation failed (command list)");
        return false;
    };
    const received_fis = allocDmaPage() orelse {
        panic_report.trace("AHCI: DMA page allocation failed (received FIS)");
        return false;
    };
    const command_table = allocDmaPage() orelse {
        panic_report.trace("AHCI: DMA page allocation failed (command table)");
        return false;
    };
    const data = allocDmaPage() orelse {
        panic_report.trace("AHCI: DMA page allocation failed (transfer buffer)");
        return false;
    };
    regs[0] = @truncate(command_list.physical);
    regs[1] = @truncate(command_list.physical >> 32);
    regs[2] = @truncate(received_fis.physical);
    regs[3] = @truncate(received_fis.physical >> 32);
    regs[4] = 0xffff_ffff;
    regs[5] = 0xffff_ffff;
    if (!startPort(regs)) {
        panic_report.trace("AHCI: failed to start command/FIS engine on connected port");
        return false;
    }
    disks[disk_count] = .{
        .regs = regs,
        .command_list = command_list,
        .received_fis = received_fis,
        .command_table = command_table,
        .data = data,
        .hardware_port = hardware_port,
    };
    disk_count += 1;
    return true;
}

pub fn init() usize {
    disk_count = 0;
    initialized = true;
    controller_found = false;
    var controller: ?pci.Device = null;
    for (pci.devices()) |device| {
        if (device.class == 0x01 and device.subclass == 0x06 and device.programming_interface == 0x01) {
            controller = device;
            break;
        }
    }
    const device = controller orelse {
        panic_report.trace("AHCI: PCI controller not found");
        return 0;
    };
    controller_found = true;
    pci.enableMemoryAndBusMaster(device);
    const bar = pci.barAddress(device, 5);
    if (bar == 0) {
        panic_report.trace("AHCI: controller BAR5 is not assigned");
        return 0;
    }
    const mapped = vm.mapMmio(bar, 0x1100) orelse {
        panic_report.trace("AHCI: could not map controller registers");
        return 0;
    };
    const hba: [*]volatile u8 = mapped;
    const ghc: *volatile u32 = @ptrCast(@alignCast(hba + 0x04));
    ghc.* |= 1 << 31; // AHCI enable.
    ghc.* |= 1 << 0; // HBA reset.
    if (!waitMask(ghc, 1, 0)) {
        panic_report.trace("AHCI: controller reset timed out");
        return 0;
    }
    ghc.* |= 1 << 31;
    const implemented = (@as(*volatile u32, @ptrCast(@alignCast(hba + 0x0c)))).*;
    for (0..max_ports) |port_index| {
        if (disk_count == disks.len) break;
        const mask = @as(u32, 1) << @intCast(port_index);
        if ((implemented & mask) == 0) continue;
        _ = setupPort(hba, @intCast(port_index));
    }
    if (disk_count == 0) panic_report.trace("AHCI: no usable SATA disk ports after probing");
    return disk_count;
}

pub fn present(device: u8) bool {
    return initialized and device < disk_count;
}
pub fn hasController() bool {
    return controller_found;
}
pub fn portNumber(device: u8) ?u8 {
    if (!present(device)) return null;
    return disks[device].hardware_port;
}

fn issue(port: *Port, command: u8, lba: u64, buffer: ?*anyopaque) bool {
    if (lba > 0x0000_ffff_ffff_ffff) return false;
    const regs = port.regs;
    if (!waitMask(&regs[8], (1 << 7) | (1 << 3), 0)) return false;
    var slot: ?usize = null;
    const occupied = regs[13] | regs[14];
    for (0..32) |i| if ((occupied & (@as(u32, 1) << @intCast(i))) == 0) {
        slot = i;
        break;
    };
    const command_slot = slot orelse return false;
    const header = port.command_list.virtual + command_slot * 32;
    @memset(header[0..32], 0);
    const table = port.command_table.virtual;
    @memset(table[0..256], 0);
    const is_write = command == 0x35;
    put16(header[0..32], 0, 5 | (if (is_write) @as(u16, 1 << 6) else 0));
    put16(header[0..32], 2, if (buffer != null) 1 else 0);
    put32(header[0..32], 8, @truncate(port.command_table.physical));
    put32(header[0..32], 12, @truncate(port.command_table.physical >> 32));

    // Register Host to Device FIS, command FIS (0x27).
    table[0] = 0x27;
    table[1] = 1 << 7;
    table[2] = command;
    table[4] = @truncate(lba);
    table[5] = @truncate(lba >> 8);
    table[6] = @truncate(lba >> 16);
    table[7] = 1 << 6; // LBA mode.
    table[8] = @truncate(lba >> 24);
    table[9] = @truncate(lba >> 32);
    table[10] = @truncate(lba >> 40);
    if (buffer) |data_buffer| {
        table[12] = 1; // Transfer one 512-byte sector.
        const buffer_address = @intFromPtr(data_buffer);
        put32(table[0..256], 128, @truncate(buffer_address));
        put32(table[0..256], 132, @truncate(buffer_address >> 32));
        put32(table[0..256], 140, 511); // One 512-byte sector, DBC is zero-based.
    }
    regs[4] = 0xffff_ffff;
    regs[14] = @as(u32, 1) << @intCast(command_slot);
    var i: u32 = 0;
    while (i < wait_limit) : (i += 1) {
        if ((regs[14] & (@as(u32, 1) << @intCast(command_slot))) == 0) break;
        if ((regs[4] & (1 << 30)) != 0) return false;
        delay();
    }
    if (i == wait_limit or (regs[4] & (1 << 30)) != 0) return false;
    return true;
}

pub fn readSector(device: u8, lba: u64, output: *[512]u8) bool {
    if (!present(device)) return false;
    const port = &disks[device];
    if (!issue(port, 0x25, lba, @ptrFromInt(port.data.physical))) return false;
    @memcpy(output, port.data.virtual[0..512]);
    return true;
}
pub fn writeSector(device: u8, lba: u64, input: *const [512]u8) bool {
    if (!present(device)) return false;
    const port = &disks[device];
    @memcpy(port.data.virtual[0..512], input);
    return issue(port, 0x35, lba, @ptrFromInt(port.data.physical));
}
pub fn flushCache(device: u8) bool {
    if (!present(device)) return false;
    return issue(&disks[device], 0xea, 0, null); // FLUSH CACHE EXT.
}
