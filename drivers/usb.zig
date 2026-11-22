//! PCI USB controller inventory plus read-only xHCI connected-port detection.
//! Device enumeration and class transfers are not yet implemented.
const pci = @import("pci.zig");
const s = @import("../system/state.zig");
const notifications = @import("../system/notifications.zig");
const xhci = @import("xhci.zig");

const max_controllers = 16;
var found: [max_controllers]pci.Device = undefined;
var count: usize = 0;
var connected: u8 = 0;
var last_poll_tick: u64 = 0;
var port_maps: [max_controllers]u64 = @splat(0);
var storage_found = false;

fn scanXhciPorts(_: pci.Device) u64 {
    return xhci.connectedBitmap();
}

pub fn init() void {
    storage_found = xhci.init() and xhci.hasStorage();
    count = 0;
    connected = 0;
    port_maps = @splat(0);
    s.usb_controller_count = 0;
    s.usb_connected_ports = 0;
    last_poll_tick = s.uptime();
    s.usb_xhci_present = false;
    s.usb_ehci_present = false;
    s.usb_uhci_ohci_present = false;
    for (pci.devices()) |device| {
        if (device.class != 0x0c or device.subclass != 0x03) continue;
        if (count < found.len) {
            found[count] = device;
            count += 1;
        }
        s.usb_controller_count +|= 1;
        switch (device.programming_interface) {
            0x30 => {
                s.usb_xhci_present = true;
                const map = scanXhciPorts(device);
                port_maps[count - 1] = map;
                connected +|= @truncate(@popCount(map));
            },
            0x20 => s.usb_ehci_present = true,
            0x00, 0x10 => s.usb_uhci_ohci_present = true,
            else => {},
        }
    }
    s.usb_connected_ports = connected;
}

/// Poll xHCI port connection bits and enumerate new mass-storage devices.
pub fn poll() bool {
    const now = s.uptime();
    if (now -| last_poll_tick < 100) return false;
    last_poll_tick = now;
    var current: u8 = 0;
    var changed = false;
    var attached = false;
    const previous_count = connected;
    const old_storage = storage_found;
    _ = xhci.pollStorage();
    storage_found = xhci.hasStorage();
    if (old_storage != storage_found) changed = true;
    for (controllers(), 0..) |device, index| {
        if (device.programming_interface != 0x30) continue;
        const map = scanXhciPorts(device);
        if (map != port_maps[index]) {
            changed = true;
            if ((map & ~port_maps[index]) != 0) attached = true;
            port_maps[index] = map;
        }
        current +|= @truncate(@popCount(map));
    }
    if (!changed) return false;
    connected = current;
    s.usb_connected_ports = current;
    if (old_storage != storage_found) {
        notifications.show(if (storage_found) "USB storage is ready" else "USB storage disconnected");
    } else if (previous_count != current or changed) {
        notifications.show(if (attached) "USB device connected" else "USB device disconnected");
    }
    return true;
}

pub fn controllers() []const pci.Device {
    return found[0..count];
}
pub fn controllerName(device: pci.Device) []const u8 {
    return switch (device.programming_interface) {
        0x30 => "xHCI",
        0x20 => "EHCI",
        0x10 => "OHCI",
        0x00 => "UHCI",
        else => "USB host",
    };
}
pub fn description() []const u8 {
    if (count == 0) return "No PCI USB host controller found";
    if (storage_found) return "xHCI USB Mass Storage ready";
    if (storage_found) return "USB Mass Storage mounted at disk 2";
    if (s.usb_xhci_present) return xhci.diagnosticText();
    if (s.usb_ehci_present) return "EHCI found; device transfers unavailable";
    if (s.usb_uhci_ohci_present) return "UHCI/OHCI found; device transfers unavailable";
    return "USB host controller found";
}

pub fn storageReady() bool {
    return storage_found;
}
pub fn readSector(lba: u32, output: *[512]u8) bool {
    return xhci.readSector(lba, output);
}
pub fn writeSector(lba: u32, input: *const [512]u8) bool {
    return xhci.writeSector(lba, input);
}
