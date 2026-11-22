//! ACPI table discovery and basic platform power controls.
//! The current kernel can enter S5 and reset the machine. S3 requires a resume
//! trampoline, and S4 requires saving/restoring OS memory state, so neither is
//! exposed as an available operation yet.
const io = @import("../arch/io.zig");
const cpu = @import("../arch/cpu.zig");

const physical_limit: u64 = 0x1_0000_0000; // The bootloader maps the first 4 GiB.
const max_table_size: u32 = 1024 * 1024;

const Gas = struct {
    space: u8 = 0,
    bit_width: u8 = 0,
    bit_offset: u8 = 0,
    access_size: u8 = 0,
    address: u64 = 0,
};

var rsdp_address: u64 = 0;
var xsdt_address: u64 = 0;
var root_table_address: u64 = 0;
var root_is_xsdt = false;
var fadt_address: u64 = 0;
var dsdt_address: u64 = 0;
var fadt_length: u32 = 0;
var pm1a_control: Gas = .{};
var pm1b_control: Gas = .{};
var reset_register: Gas = .{};
var reset_value: u8 = 0;
var reset_register_supported = false;
var acpi_enabled = false;
var s5_supported = false;
var s5_type_a: u8 = 0;
var s5_type_b: u8 = 0;
var s1_supported = false;
var s1_type_a: u8 = 0;
var s1_type_b: u8 = 0;
var s3_table_state_found = false;

fn rangeMapped(address: u64, length: u64) bool {
    return address != 0 and address < physical_limit and length <= physical_limit - address;
}

fn byteAt(address: u64, offset: usize) u8 {
    const ptr: [*]const u8 = @ptrFromInt(address);
    return ptr[offset];
}

fn read16(address: u64, offset: usize) u16 {
    return @as(u16, byteAt(address, offset)) | (@as(u16, byteAt(address, offset + 1)) << 8);
}

fn read32(address: u64, offset: usize) u32 {
    return @as(u32, byteAt(address, offset)) |
        (@as(u32, byteAt(address, offset + 1)) << 8) |
        (@as(u32, byteAt(address, offset + 2)) << 16) |
        (@as(u32, byteAt(address, offset + 3)) << 24);
}

fn read64(address: u64, offset: usize) u64 {
    return @as(u64, read32(address, offset)) | (@as(u64, read32(address, offset + 4)) << 32);
}

fn checksum(address: u64, length: usize) bool {
    if (!rangeMapped(address, length)) return false;
    var sum: u8 = 0;
    for (0..length) |i| sum +%= byteAt(address, i);
    return sum == 0;
}

fn bytesEqualAt(address: u64, offset: usize, expected: []const u8) bool {
    for (expected, 0..) |byte, i| if (byteAt(address, offset + i) != byte) return false;
    return true;
}

fn validRsdp(address: u64) bool {
    if (!rangeMapped(address, 20) or !bytesEqualAt(address, 0, "RSD PTR ") or !checksum(address, 20)) return false;
    if (byteAt(address, 15) < 2) return true;
    const length = read32(address, 20);
    return length >= 36 and length <= 4096 and rangeMapped(address, length) and checksum(address, length);
}

fn scanRange(start: u64, end: u64) ?u64 {
    var address = (start + 15) & ~@as(u64, 15);
    while (address + 20 <= end) : (address += 16) {
        if (validRsdp(address)) return address;
    }
    return null;
}

fn findRsdpFallback() ?u64 {
    // BIOS Data Area 0x40e contains the Extended BIOS Data Area segment.
    const ebda_segment = read16(0x40e, 0);
    const ebda = @as(u64, ebda_segment) << 4;
    if (ebda >= 0x80000 and ebda < 0xa0000) {
        if (scanRange(ebda, @min(ebda + 1024, 0xa0000))) |found| return found;
    }
    return scanRange(0xe0000, 0x100000);
}

fn tableLength(address: u64, signature: []const u8) ?u32 {
    if (!rangeMapped(address, 36) or !bytesEqualAt(address, 0, signature)) return null;
    const length = read32(address, 4);
    if (length < 36 or length > max_table_size or !rangeMapped(address, length) or !checksum(address, length)) return null;
    return length;
}

fn findFadtInRoot(root: u64, signature: []const u8, entry_size: usize) ?u64 {
    const length = tableLength(root, signature) orelse return null;
    const payload_length: usize = length - 36;
    if (payload_length % entry_size != 0) return null;
    var offset: usize = 36;
    while (offset + entry_size <= length) : (offset += entry_size) {
        const candidate = if (entry_size == 8) read64(root, offset) else read32(root, offset);
        if (tableLength(candidate, "FACP") != null) return candidate;
    }
    return null;
}

fn gasAt(address: u64, offset: usize) Gas {
    return .{
        .space = byteAt(address, offset),
        .bit_width = byteAt(address, offset + 1),
        .bit_offset = byteAt(address, offset + 2),
        .access_size = byteAt(address, offset + 3),
        .address = read64(address, offset + 4),
    };
}

fn legacyIoGas(port: u32, length: u8) Gas {
    if (port == 0 or length < 2 or port > 0xffff) return .{};
    return .{ .space = 1, .bit_width = 16, .address = port };
}

fn decodePackageLength(address: u64, available: usize) ?struct { length: usize, encoded: usize } {
    if (available == 0) return null;
    const lead = byteAt(address, 0);
    const following: usize = lead >> 6;
    if (following == 0) return .{ .length = lead & 0x3f, .encoded = 1 };
    if (following > 3 or following + 1 > available) return null;
    var length: usize = lead & 0x0f;
    for (0..following) |i| length |= @as(usize, byteAt(address, i + 1)) << @intCast(4 + i * 8);
    return .{ .length = length, .encoded = following + 1 };
}

fn amlInteger(address: u64, available: usize) ?struct { value: u64, used: usize } {
    if (available == 0) return null;
    return switch (byteAt(address, 0)) {
        0x00 => .{ .value = 0, .used = 1 }, // ZeroOp
        0x01 => .{ .value = 1, .used = 1 }, // OneOp
        0xff => .{ .value = 0xff, .used = 1 }, // OnesOp
        0x0a => if (available >= 2) .{ .value = byteAt(address, 1), .used = 2 } else null,
        0x0b => if (available >= 3) .{ .value = read16(address, 1), .used = 3 } else null,
        0x0c => if (available >= 5) .{ .value = read32(address, 1), .used = 5 } else null,
        0x0e => if (available >= 9) .{ .value = read64(address, 1), .used = 9 } else null,
        else => null,
    };
}

fn findSleepTypes(dsdt: u64, length: u32, name: []const u8) ?[2]u8 {
    if (length <= 36 or name.len != 4) return null;
    var offset: usize = 36;
    while (offset + 10 < length) : (offset += 1) {
        if (byteAt(dsdt, offset) != 0x08 or !bytesEqualAt(dsdt, offset + 1, name)) continue; // NameOp + NameSeg
        const package_op = offset + 5;
        if (byteAt(dsdt, package_op) != 0x12) continue; // PackageOp
        const package_length_at = package_op + 1;
        const decoded = decodePackageLength(dsdt + package_length_at, length - package_length_at) orelse continue;
        if (decoded.length < decoded.encoded + 3 or decoded.length > length - package_length_at) continue;
        const elements_at = package_length_at + decoded.encoded;
        const package_end = package_length_at + decoded.length;
        if (elements_at >= package_end or byteAt(dsdt, elements_at) < 2) continue;
        const first = amlInteger(dsdt + elements_at + 1, package_end - elements_at - 1) orelse continue;
        const second_at = elements_at + 1 + first.used;
        if (second_at >= package_end) continue;
        const second = amlInteger(dsdt + second_at, package_end - second_at) orelse continue;
        return .{ @truncate(first.value), @truncate(second.value) };
    }
    return null;
}

fn gasMask(gas: Gas) u64 {
    if (gas.bit_width == 0 or gas.bit_width >= 64) return stdMaxIntU64();
    return (@as(u64, 1) << @intCast(gas.bit_width)) - 1;
}

fn stdMaxIntU64() u64 {
    return ~@as(u64, 0);
}

fn gasReadRaw(gas: Gas) ?u64 {
    if (gas.address == 0) return null;
    if (gas.space == 1) {
        if (gas.address > 0xffff) return null;
        const port: u16 = @intCast(gas.address);
        return switch (if (gas.access_size != 0) gas.access_size else if (gas.bit_width > 16) @as(u8, 3) else @as(u8, 2)) {
            1 => io.in8(port),
            2 => io.in16(port),
            3 => io.in32(port),
            else => null,
        };
    }
    if (gas.space == 0 and rangeMapped(gas.address, 8)) {
        return switch (if (gas.access_size != 0) gas.access_size else if (gas.bit_width > 32) @as(u8, 4) else if (gas.bit_width > 16) @as(u8, 3) else if (gas.bit_width > 8) @as(u8, 2) else @as(u8, 1)) {
            1 => @as(*volatile u8, @ptrFromInt(gas.address)).*,
            2 => @as(*volatile u16, @ptrFromInt(gas.address)).*,
            3 => @as(*volatile u32, @ptrFromInt(gas.address)).*,
            4 => @as(*volatile u64, @ptrFromInt(gas.address)).*,
            else => null,
        };
    }
    return null;
}

fn gasRead(gas: Gas) ?u64 {
    const raw = gasReadRaw(gas) orelse return null;
    return (raw >> @intCast(gas.bit_offset)) & gasMask(gas);
}

fn gasWriteRaw(gas: Gas, value: u64) bool {
    if (gas.address == 0) return false;
    const access_size = if (gas.access_size != 0) gas.access_size else if (gas.bit_width > 32) @as(u8, 4) else if (gas.bit_width > 16) @as(u8, 3) else if (gas.bit_width > 8) @as(u8, 2) else @as(u8, 1);
    if (gas.space == 1 and gas.address <= 0xffff) {
        const port: u16 = @intCast(gas.address);
        switch (access_size) {
            1 => io.out8(port, @truncate(value)),
            2 => io.out16(port, @truncate(value)),
            3 => io.out32(port, @truncate(value)),
            else => return false,
        }
        return true;
    }
    if (gas.space == 0 and rangeMapped(gas.address, 8)) {
        switch (access_size) {
            1 => @as(*volatile u8, @ptrFromInt(gas.address)).* = @truncate(value),
            2 => @as(*volatile u16, @ptrFromInt(gas.address)).* = @truncate(value),
            3 => @as(*volatile u32, @ptrFromInt(gas.address)).* = @truncate(value),
            4 => @as(*volatile u64, @ptrFromInt(gas.address)).* = value,
            else => return false,
        }
        return true;
    }
    return false;
}

fn gasWrite(gas: Gas, value: u64) bool {
    if (gas.bit_offset == 0 and gas.bit_width >= 64) return gasWriteRaw(gas, value);
    const old = gasReadRaw(gas) orelse return false;
    const mask = gasMask(gas) << @intCast(gas.bit_offset);
    const updated = (old & ~mask) | ((value & gasMask(gas)) << @intCast(gas.bit_offset));
    return gasWriteRaw(gas, updated);
}

fn resetDiscovery() void {
    rsdp_address = 0;
    xsdt_address = 0;
    root_table_address = 0;
    root_is_xsdt = false;
    fadt_address = 0;
    dsdt_address = 0;
    fadt_length = 0;
    pm1a_control = .{};
    pm1b_control = .{};
    reset_register = .{};
    reset_value = 0;
    reset_register_supported = false;
    acpi_enabled = false;
    s5_supported = false;
    s5_type_a = 0;
    s5_type_b = 0;
    s1_supported = false;
    s1_type_a = 0;
    s1_type_b = 0;
    s3_table_state_found = false;
}

fn enableAcpi() bool {
    const control = gasRead(pm1a_control) orelse return false;
    if ((control & 1) != 0) return true;
    if (fadt_length < 53) return false;
    const command_port = read32(fadt_address, 48);
    const enable_command = byteAt(fadt_address, 52);
    if (command_port == 0 or command_port > 0xffff or enable_command == 0) return false;
    io.out8(@intCast(command_port), enable_command);
    var attempts: usize = 0;
    while (attempts < 1_000_000) : (attempts += 1) {
        if ((gasRead(pm1a_control) orelse return false) & 1 != 0) return true;
        asm volatile ("pause");
    }
    return false;
}

pub fn init(supplied_rsdp: u64) void {
    resetDiscovery();
    if (validRsdp(supplied_rsdp)) {
        rsdp_address = supplied_rsdp;
    } else if (findRsdpFallback()) |found| {
        rsdp_address = found;
    } else {
        return;
    }

    const revision = byteAt(rsdp_address, 15);
    const rsdt = read32(rsdp_address, 16);
    if (revision >= 2) {
        const xsdt = read64(rsdp_address, 24);
        if (findFadtInRoot(xsdt, "XSDT", 8)) |found| {
            xsdt_address = xsdt;
            root_table_address = xsdt;
            root_is_xsdt = true;
            fadt_address = found;
        }
    }
    if (fadt_address == 0) {
        if (findFadtInRoot(rsdt, "RSDT", 4)) |found| {
            root_table_address = rsdt;
            fadt_address = found;
        }
    }
    if (fadt_address == 0) return;

    fadt_length = tableLength(fadt_address, "FACP") orelse return;
    if (fadt_length >= 72) {
        pm1a_control = legacyIoGas(read32(fadt_address, 64), if (fadt_length > 89) byteAt(fadt_address, 89) else 0);
        pm1b_control = legacyIoGas(read32(fadt_address, 68), if (fadt_length > 89) byteAt(fadt_address, 89) else 0);
    }
    if (fadt_length >= 184) {
        const extended = gasAt(fadt_address, 172);
        if (extended.address != 0) pm1a_control = extended;
    }
    if (fadt_length >= 196) {
        const extended = gasAt(fadt_address, 184);
        if (extended.address != 0) pm1b_control = extended;
    }
    if (fadt_length >= 129) {
        reset_register = gasAt(fadt_address, 116);
        reset_value = byteAt(fadt_address, 128);
    }
    if (fadt_length >= 116) reset_register_supported = (read32(fadt_address, 112) & (1 << 10)) != 0;

    if (fadt_length >= 44) {
        dsdt_address = read32(fadt_address, 40);
        if (fadt_length >= 148) {
            const extended_dsdt = read64(fadt_address, 140);
            if (extended_dsdt != 0) dsdt_address = extended_dsdt;
        }
    }
    if (tableLength(dsdt_address, "DSDT")) |length| {
        if (findSleepTypes(dsdt_address, length, "_S1_")) |sleep_types| {
            s1_type_a = sleep_types[0] & 7;
            s1_type_b = sleep_types[1] & 7;
            s1_supported = true;
        }
        if (findSleepTypes(dsdt_address, length, "_S5_")) |sleep_types| {
            s5_type_a = sleep_types[0] & 7;
            s5_type_b = sleep_types[1] & 7;
            s5_supported = true;
        }
        s3_table_state_found = findSleepTypes(dsdt_address, length, "_S3_") != null;
    }
    acpi_enabled = enableAcpi();
}

pub fn canShutdown() bool {
    return fadt_address != 0 and acpi_enabled and s5_supported and pm1a_control.address != 0;
}

pub fn sleepSupported() bool {
    return fadt_address != 0 and acpi_enabled and s1_supported and pm1a_control.address != 0;
}

pub fn sleep() bool {
    if (!sleepSupported()) return false;
    const old_a = gasRead(pm1a_control) orelse return false;
    const value_a = (old_a & ~(@as(u64, 7 << 10) | (1 << 13))) | (@as(u64, s1_type_a) << 10) | (1 << 13);
    // S1 leaves CPU context intact. An enabled device interrupt resumes the
    // instruction stream after the firmware returns from the sleep state.
    if (!gasWrite(pm1a_control, value_a)) return false;
    if (pm1b_control.address != 0) {
        const old_b = gasRead(pm1b_control) orelse 0;
        const value_b = (old_b & ~(@as(u64, 7 << 10) | (1 << 13))) | (@as(u64, s1_type_b) << 10) | (1 << 13);
        _ = gasWrite(pm1b_control, value_b);
    }
    return true;
}

pub fn hibernateSupported() bool {
    // ACPI S4 alone does not save memory; AetherOS has no hibernation image.
    return false;
}

pub fn shutdown() noreturn {
    if (canShutdown()) {
        asm volatile ("cli");
        const old_a = gasRead(pm1a_control) orelse 0;
        const value_a = (old_a & ~(@as(u64, 7 << 10) | (1 << 13))) | (@as(u64, s5_type_a) << 10) | (1 << 13);
        _ = gasWrite(pm1a_control, value_a);
        if (pm1b_control.address != 0) {
            const old_b = gasRead(pm1b_control) orelse 0;
            const value_b = (old_b & ~(@as(u64, 7 << 10) | (1 << 13))) | (@as(u64, s5_type_b) << 10) | (1 << 13);
            _ = gasWrite(pm1b_control, value_b);
        }
    }
    cpu.halt();
}

pub fn reboot() noreturn {
    asm volatile ("cli");
    if (reset_register_supported and reset_register.address != 0) _ = gasWrite(reset_register, reset_value);

    // Standard PC chipset reset port, then the 8042 keyboard-controller reset.
    io.out8(0x0cf9, 0x02);
    io.out8(0x0cf9, 0x06);
    var attempts: usize = 0;
    while (attempts < 100_000) : (attempts += 1) {
        if ((io.in8(0x64) & 2) == 0) break;
        asm volatile ("pause");
    }
    if ((io.in8(0x64) & 2) == 0) io.out8(0x64, 0xfe);

    // Last resort: an empty IDT forces the processor's architected triple-fault reset.
    const EmptyIdt = packed struct { limit: u16, base: u64 };
    const empty_idt = EmptyIdt{ .limit = 0, .base = 0 };
    asm volatile ("lidt (%[descriptor]); int3"
        :
        : [descriptor] "r" (&empty_idt),
        : .{ .memory = true });
    cpu.halt();
}

var description: [256]u8 = @splat(0);

fn appendText(used: *usize, text: []const u8) void {
    const amount = @min(text.len, description.len - used.*);
    @memcpy(description[used.* .. used.* + amount], text[0..amount]);
    used.* += amount;
}

fn appendHex(used: *usize, value: u64) void {
    const digits = "0123456789abcdef";
    appendText(used, "0x");
    var shift: u6 = 60;
    while (true) : (shift -= 4) {
        if (used.* == description.len) return;
        description[used.*] = digits[@intCast((value >> shift) & 0xf)];
        used.* += 1;
        if (shift == 0) break;
    }
}

pub fn describe() []const u8 {
    @memset(&description, 0);
    var used: usize = 0;
    if (rsdp_address == 0) return "ACPI tables not found; reboot uses hardware reset";
    appendText(&used, "RSDP ");
    appendHex(&used, rsdp_address);
    appendText(&used, "\n");
    appendText(&used, if (root_is_xsdt) "XSDT " else "RSDT ");
    appendHex(&used, root_table_address);
    appendText(&used, "\nFADT ");
    appendHex(&used, fadt_address);
    appendText(&used, if (canShutdown()) " S5 shutdown ready" else " S5 shutdown unavailable");
    appendText(&used, "\nDSDT ");
    appendHex(&used, dsdt_address);
    appendText(&used, if (s1_supported) " S1 sleep ready" else if (s3_table_state_found) " S3 found; resume unsupported" else " S1/S3 unavailable");
    appendText(&used, "\nS4 hibernate unsupported");
    return description[0..used];
}
