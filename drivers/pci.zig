//! Minimal PCI configuration-space inventory, shared by class drivers.
const io = @import("../arch/io.zig");

pub const Device = struct {
    vendor_id: u16,
    device_id: u16,
    class: u8,
    subclass: u8,
    programming_interface: u8,
    bus: u8,
    slot: u8,
    function: u8,
};

const capacity = 128;
var inventory: [capacity]Device = undefined;
var count: usize = 0;
var description_buffer: [4096]u8 = @splat(0);
var description_len: usize = 0;

fn readConfig(bus: u8, slot: u8, function: u8, offset: u8) u32 {
    const address = 0x8000_0000 | (@as(u32, bus) << 16) | (@as(u32, slot) << 11) |
        (@as(u32, function) << 8) | (@as(u32, offset) & 0xfc);
    io.out32(0x0cf8, address);
    return io.in32(0x0cfc);
}

fn writeConfig(bus: u8, slot: u8, function: u8, offset: u8, value: u32) void {
    const address = 0x8000_0000 | (@as(u32, bus) << 16) | (@as(u32, slot) << 11) |
        (@as(u32, function) << 8) | (@as(u32, offset) & 0xfc);
    io.out32(0x0cf8, address);
    io.out32(0x0cfc, value);
}

pub fn barAddress(device: Device, index: u8) u64 {
    if (index >= 6) return 0;
    const offset: u8 = 0x10 + index * 4;
    const low = readConfig(device.bus, device.slot, device.function, offset);
    if (low == 0 or low == 0xffff_ffff or (low & 1) != 0) return 0;
    const kind = (low >> 1) & 3;
    if (kind == 2 and index < 5) {
        const high = readConfig(device.bus, device.slot, device.function, offset + 4);
        return (@as(u64, high) << 32) | (low & 0xffff_fff0);
    }
    return low & 0xffff_fff0;
}

pub fn enableMemoryAndBusMaster(device: Device) void {
    const command = readConfig(device.bus, device.slot, device.function, 0x04);
    writeConfig(device.bus, device.slot, device.function, 0x04, command | 0x0000_0006);
}

pub fn init() void {
    count = 0;
    var bus: u16 = 0;
    while (bus < 256) : (bus += 1) {
        for (0..32) |slot_index| {
            const slot: u8 = @intCast(slot_index);
            const id = readConfig(@intCast(bus), slot, 0, 0);
            if (id == 0xffff_ffff or @as(u16, @truncate(id)) == 0xffff) continue;
            const header = readConfig(@intCast(bus), slot, 0, 0x0c);
            const fn_count: u8 = if ((header >> 23) & 1 != 0) 8 else 1;
            for (0..fn_count) |function_index| {
                const function: u8 = @intCast(function_index);
                const fn_id = if (function == 0) id else readConfig(@intCast(bus), slot, function, 0);
                if (fn_id == 0xffff_ffff or @as(u16, @truncate(fn_id)) == 0xffff) continue;
                if (count == inventory.len) return;
                const class_info = readConfig(@intCast(bus), slot, function, 0x08);
                inventory[count] = .{
                    .vendor_id = @truncate(fn_id),
                    .device_id = @truncate(fn_id >> 16),
                    .class = @truncate(class_info >> 24),
                    .subclass = @truncate(class_info >> 16),
                    .programming_interface = @truncate(class_info >> 8),
                    .bus = @intCast(bus),
                    .slot = slot,
                    .function = function,
                };
                count += 1;
            }
        }
    }
}

pub fn devices() []const Device {
    return inventory[0..count];
}

pub fn find(class: u8, subclass: u8) ?Device {
    for (devices()) |device| if (device.class == class and device.subclass == subclass) return device;
    return null;
}

fn append(bytes: []const u8) void {
    const amount = @min(bytes.len, description_buffer.len - description_len);
    @memcpy(description_buffer[description_len .. description_len + amount], bytes[0..amount]);
    description_len += amount;
}

fn appendHex(value: u8) void {
    const digits = "0123456789abcdef";
    append(&.{ digits[value >> 4], digits[value & 0x0f] });
}

pub fn describeDevices() []const u8 {
    description_len = 0;
    if (count == 0) return "No PCI devices found";
    for (devices()) |device| {
        append("PCI ");
        appendHex(device.bus);
        append(":");
        appendHex(device.slot);
        append(".");
        appendHex(device.function);
        append("  ");
        appendHex(@truncate(device.vendor_id >> 8));
        appendHex(@truncate(device.vendor_id));
        append(":");
        appendHex(@truncate(device.device_id >> 8));
        appendHex(@truncate(device.device_id));
        append(" class ");
        appendHex(device.class);
        appendHex(device.subclass);
        appendHex(device.programming_interface);
        append("\n");
    }
    return description_buffer[0..description_len];
}
