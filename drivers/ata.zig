//! Minimal ATA PIO access for QEMU IDE disks. Uses 28-bit LBA and 512-byte sectors.
const usb = @import("usb.zig");
const sata = @import("sata.zig");
const std = @import("std");

/// Probe for a PCI AHCI controller and attach its SATA disks. Legacy IDE
/// remains available automatically when no AHCI disk is present.
pub fn init() usize {
    return sata.init();
}

pub var last_write_error: u8 = 0;
pub var last_write_lba: u64 = 0;
pub var last_status: u8 = 0;

fn out8(port: u16, value: u8) void {
    asm volatile ("outb %al, %dx"
        :
        : [port] "{dx}" (port),
          [value] "{al}" (value),
    );
}

fn in8(port: u16) u8 {
    var value: u8 = undefined;
    asm volatile ("inb %dx, %al"
        : [value] "={al}" (value),
        : [port] "{dx}" (port),
    );
    return value;
}

fn in16(port: u16) u16 {
    var value: u16 = undefined;
    asm volatile ("inw %dx, %ax"
        : [value] "={ax}" (value),
        : [port] "{dx}" (port),
    );
    return value;
}

fn out16(port: u16, value: u16) void {
    asm volatile ("outw %ax, %dx"
        :
        : [port] "{dx}" (port),
          [value] "{ax}" (value),
    );
}

fn delay400ns() void {
    _ = in8(0x3f6);
    _ = in8(0x3f6);
    _ = in8(0x3f6);
    _ = in8(0x3f6);
}

fn waitNotBusy() bool {
    var tries: u32 = 0;
    while (tries < 1_000_000) : (tries += 1) {
        const status = in8(0x1f7);
        last_status = status;
        if (status == 0 or status == 0xff) return false;
        if ((status & 0x80) == 0) return (status & 0x21) == 0;
    }
    return false;
}

fn waitDataRequest() bool {
    var tries: u32 = 0;
    while (tries < 1_000_000) : (tries += 1) {
        const status = in8(0x1f7);
        last_status = status;
        if (status == 0 or status == 0xff or (status & 0x21) != 0) return false;
        if ((status & 0x08) != 0) return true;
    }
    return false;
}

fn selectSector(device: u8, lba: u32) bool {
    if (device > 1 or lba >= 0x10000000) return false;
    out8(0x1f6, 0xe0 | (device << 4) | @as(u8, @truncate(lba >> 24)));
    delay400ns();
    if (!waitNotBusy()) return false;
    out8(0x1f2, 1);
    out8(0x1f3, @truncate(lba));
    out8(0x1f4, @truncate(lba >> 8));
    out8(0x1f5, @truncate(lba >> 16));
    return true;
}

pub fn readSector(device: u8, lba: u64, output: *[512]u8) bool {
    if (device == 2) return lba <= std.math.maxInt(u32) and usb.readSector(@intCast(lba), output);
    if (sata.present(device)) return sata.readSector(device, lba, output);
    if (lba > std.math.maxInt(u32) or !selectSector(device, @intCast(lba))) return false;
    out8(0x1f7, 0x20);
    if (!waitDataRequest()) return false;
    for (0..256) |word_index| {
        const word = in16(0x1f0);
        output[word_index * 2] = @truncate(word);
        output[word_index * 2 + 1] = @truncate(word >> 8);
    }
    return waitNotBusy();
}

pub fn writeSector(device: u8, lba: u64, input: *const [512]u8) bool {
    if (device == 2) return lba <= std.math.maxInt(u32) and usb.writeSector(@intCast(lba), input);
    if (sata.present(device)) return sata.writeSector(device, lba, input);
    last_write_error = 0;
    last_write_lba = lba;
    if (lba > std.math.maxInt(u32) or !selectSector(device, @intCast(lba))) { last_write_error = 1; return false; }
    out8(0x1f7, 0x30);
    if (!waitDataRequest()) { last_write_error = 2; return false; }
    for (0..256) |word_index| {
        const word = @as(u16, input[word_index * 2]) | (@as(u16, input[word_index * 2 + 1]) << 8);
        out16(0x1f0, word);
    }
    if (!waitNotBusy()) { last_write_error = 3; return false; }
    return true;
}

/// Flush ATA's write cache once after a complete filesystem operation.
pub fn flushCache(device: u8) bool {
    if (device == 2) return true;
    if (sata.present(device)) return sata.flushCache(device);
    if (device > 1 or !waitNotBusy()) return false;
    out8(0x1f7, 0xe7);
    return waitNotBusy();
}
