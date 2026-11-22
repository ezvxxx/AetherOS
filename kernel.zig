const std = @import("std");
const cpu = @import("arch/cpu.zig");
const state = @import("system/state.zig");
const framebuffer = @import("graphics/framebuffer.zig");
const boot_protocol = @import("boot/info.zig");
const keyboard = @import("drivers/keyboard.zig");
const mouse = @import("drivers/mouse.zig");
const rtc = @import("drivers/rtc.zig");
const ps2 = @import("drivers/ps2.zig");
const e1000 = @import("drivers/e1000.zig");
const network = @import("network/stack.zig");
const dns = @import("network/dns.zig");
const tls = @import("network/tls.zig");
const storage = @import("fs/storage.zig");
const desktop = @import("ui/desktop.zig");
const browser = @import("ui/browser.zig");
const canvas = @import("graphics/canvas.zig");
const screenshot = @import("graphics/screenshot.zig");
const system_font = @import("graphics/font.zig");
const pmm = @import("memory/pmm.zig");
const heap = @import("memory/heap.zig");
const vm = @import("memory/vm.zig");
const interrupts = @import("arch/interrupts.zig");
const panic_handler = @import("system/panic.zig");
const acpi = @import("drivers/acpi.zig");
const usb = @import("drivers/usb.zig");
const audio = @import("drivers/audio.zig");
const accounts = @import("system/accounts.zig");
const notifications = @import("system/notifications.zig");
const game = @import("ui/game.zig");
const pci = @import("drivers/pci.zig");
const ata = @import("drivers/ata.zig");
const media_player = @import("apps/media_player.zig");
const brand = @import("graphics/brand.zig");

pub const panic = panic_handler.panic;
var kernel_stack: [1024 * 1024]u8 align(16) = undefined;

pub export fn _start(info: *const boot_protocol.BootInfo) callconv(.c) noreturn {
    const stack_top = @intFromPtr(&kernel_stack) + kernel_stack.len;
    asm volatile (
        \\movq %[stack_top], %%rsp
        \\andq $-16, %%rsp
        \\call *%[entry]
        :
        : [stack_top] "r" (stack_top),
          [entry] "r" (@intFromPtr(&kernelMain)),
          [boot_info] "{rdi}" (info),
        : .{ .memory = true, .cc = true });
    unreachable;
}

fn kernelMain(info: *const boot_protocol.BootInfo) callconv(.c) noreturn {
    asm volatile ("cli");
    _ = tls.init;
    _ = tls.secureRandom;
    cpu.enableSse();
    if (info.magic != boot_protocol.magic) cpu.halt();
    state.fb = .{
        .address = @ptrFromInt(info.framebuffer),
        .width = info.width,
        .height = info.height,
        .pitch = info.pitch,
        .bpp = info.bpp,
        .memory_model = 1,
        .red_mask_size = info.red_mask_size,
        .red_mask_shift = info.red_mask_shift,
        .green_mask_size = info.green_mask_size,
        .green_mask_shift = info.green_mask_shift,
        .blue_mask_size = info.blue_mask_size,
        .blue_mask_shift = info.blue_mask_shift,
        .unused = @splat(0),
    };
    panic_handler.setFramebufferReady();
    if (state.fb.bpp != 32) cpu.halt();
    const raw = state.fb.address orelse cpu.halt();
    state.pixels = @ptrCast(@alignCast(raw));
    state.boot_is_uefi = info.firmware == 1;
    const regions = info.memory_regions[0..info.memory_region_count];
    const physical_ready = pmm.init(regions);
    const virtual_ready = vm.init(info.hhdm_offset);
    state.memory_ready = physical_ready and virtual_ready;
    acpi.init(info.acpi_rsdp);
    state.physical_memory_bytes = pmm.totalMemoryBytes();
    _ = canvas.initBackbuffer();
    _ = heap.allocate(64, 16);
    brand.init();
    state.boot_splash_visible = true;
    state.mouse_x = state.fb.width;
    state.mouse_y = state.fb.height;
    if (system_font.init()) {
        panic_handler.trace("font: Inter TTF loaded");
    } else {
        panic_handler.trace("font: Inter TTF failed; bitmap fallback active");
    }
    brand.drawBootSplash();
    state.mouse_x = state.fb.width / 2;
    state.mouse_y = state.fb.height / 2;
    panic_handler.trace("input: initializing PS/2");
    state.keyboard_ready = ps2.initKeyboard();
    state.mouse_ready = ps2.initMouse();
    interrupts.init();
    panic_handler.trace("ui: interrupts enabled");
    state.ethernet_present = e1000.init();
    state.ethernet_link_up = e1000.linkUp();
    pci.init();
    panic_handler.trace("storage: PCI inventory follows");
    panic_handler.trace(pci.describeDevices());
    const sata_disks = ata.init();
    if (sata_disks != 0) {
        panic_handler.trace("storage: AHCI SATA disks detected");
    } else {
        panic_handler.trace("storage: AHCI found no usable SATA disks");
    }
    usb.init();
    panic_handler.trace("storage: mount start");
    state.fs_mounted = storage.mount();
    panic_handler.trace(if (!state.fs_mounted) "storage: no disk mounted" else if (storage.mountedKind() == .apfs) "storage: APFS volume mounted" else if (storage.mountedKind() == .ext2) "storage: ext2 mounted" else "storage: FAT32 mounted");
    state.fs_current_directory = storage.rootCluster();
    state.fs_current_path = @splat(0);
    state.fs_current_path[0] = '/';
    state.fs_current_path_len = 1;
    panic_handler.trace("accounts: initialization start");
    if (accounts.init()) {
        state.fs_entry_count = storage.listDirectory(state.fs_current_directory, &state.fs_entries);
        panic_handler.trace("accounts: home directory ready");
    } else {
        panic_handler.trace("accounts: home directory setup failed");
    }
    panic_handler.trace("ui: desktop init start");
    desktop.init();
    panic_handler.trace("ui: desktop init done");
    if (system_font.loadFirstInstalled(state.fs_entries[0..state.fs_entry_count])) {
        panic_handler.trace("font: installed TTF/OTF selected from FAT32 root");
    }
    _ = audio.init();
    if (state.usb_controller_count != 0) notifications.show(usb.description());
    keyboard.refreshFilesystemListing();
    panic_handler.trace("ui: keyboard filesystem refresh done");
    var first_frame = true;
    var frame_trace_pending = true;
    while (true) {
        const is_first_frame = first_frame;
        var redraw = first_frame;
        first_frame = false;
        if (notifications.update()) redraw = true;
        const keyboard_changed = keyboard.pollKeyboard();
        const mouse_update = mouse.pollMouse();
        if (usb.poll()) redraw = true;
        e1000.poll(network.onEthernetFrame);
        network.poll();
        dns.poll();
        redraw = mouse_update.desktop_changed or redraw;
        if (state.network_updated) {
            state.network_updated = false;
            redraw = true;
        }
        if (mouse_update.cursor_changed and !canvas.hasBackbuffer()) redraw = true;
        if (state.ethernet_present) {
            const link_up = e1000.linkUp();
            if (link_up != state.ethernet_link_up) {
                state.ethernet_link_up = link_up;
                notifications.show(if (link_up) "Ethernet connected" else "Ethernet disconnected");
                redraw = true;
            }
        }
        if (state.windows[7].open and !state.windows[7].minimized and game.update()) redraw = true;
        if (state.windows[11].open and !state.windows[11].minimized and media_player.update()) redraw = true;
        const clock_changed = rtc.updateClock();
        if (keyboard_changed and !redraw and keyboard.active_window_only_update and canvas.hasBackbuffer()) {
            if (desktop.drawActiveWindow()) |index| {
                const win = state.windows[index];
                canvas.presentRegion(win.x, win.y, win.w +| 5, win.h +| 6);
            } else {
                redraw = true;
            }
        } else if (keyboard_changed) {
            redraw = true;
        }
        if (redraw) {
            if (frame_trace_pending) panic_handler.trace("ui: first frame draw start");
            if (is_first_frame and state.boot_splash_visible) brand.finishBootSplash();
            desktop.drawDesktop();
            canvas.presentFrame();
            if (frame_trace_pending) {
                panic_handler.trace("ui: first frame presented");
                frame_trace_pending = false;
            }
        } else if (clock_changed) {
            desktop.drawTopBar();
            canvas.presentRegion(0, 0, state.fb.width, 28);
        }
        if (state.screenshot_requested) {
            state.screenshot_requested = false;
            var filename: [12]u8 = undefined;
            if (screenshot.save(&filename)) {
                var message: [32]u8 = undefined;
                const text = std.fmt.bufPrint(&message, "Screenshot saved: {s}", .{filename[0..]}) catch "Screenshot saved";
                notifications.show(text);
            } else {
                notifications.show("Screenshot failed; check the disk");
            }
            desktop.drawDesktop();
            canvas.presentFrame();
        }
        if (!redraw and mouse_update.cursor_changed) canvas.presentCursor();
        asm volatile ("hlt");
    }
}
