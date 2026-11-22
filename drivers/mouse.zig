const s = @import("../system/state.zig");
const desktop = @import("../ui/desktop.zig");
const browser = @import("../ui/browser.zig");
const io = @import("../arch/io.zig");

pub const Update = struct { cursor_changed: bool = false, desktop_changed: bool = false };

pub fn pollMouse() Update {
    var update: Update = .{};
    while (s.mouse_tail != s.mouse_head) {
        const value = s.mouse_queue[s.mouse_tail];
        s.mouse_tail +%= 1;
        if (s.mouse_packet_index == 0 and (value & 0x08) == 0) continue;
        s.mouse_packet[s.mouse_packet_index] = value;
        s.mouse_packet_index += 1;
        if (s.mouse_packet_index < s.mouse_packet_size) continue;
        s.mouse_packet_index = 0;

        const flags = s.mouse_packet[0];
        const old_buttons = s.mouse_buttons;
        s.mouse_buttons = flags & 0x07;
        if (s.mouse_packet_size == 4) {
            const extra = s.mouse_packet[3];
            s.mouse_buttons |= (extra & 0x30) >> 1; // wheel mouse buttons 4 and 5
        }
        s.mouse_clicked |= s.mouse_buttons & ~old_buttons;
        if (s.mouse_buttons != old_buttons) {
            update.cursor_changed = true;
            update.desktop_changed = true;
        }
        if ((flags & 0xc0) != 0) continue; // Ignore overflowed deltas.
        const dx: i16 = if ((flags & 0x10) != 0)
            @as(i16, s.mouse_packet[1]) - 256
        else
            s.mouse_packet[1];
        const dy: i16 = if ((flags & 0x20) != 0)
            @as(i16, s.mouse_packet[2]) - 256
        else
            s.mouse_packet[2];
        const next_x = @as(i32, @intCast(s.mouse_x)) + dx;
        const next_y = @as(i32, @intCast(s.mouse_y)) - dy;
        const clamped_x = @max(0, @min(next_x, @as(i32, @intCast(s.fb.width -| 1))));
        const clamped_y = @max(0, @min(next_y, @as(i32, @intCast(s.fb.height -| 1))));
        const position_changed = clamped_x != s.mouse_x or clamped_y != s.mouse_y;
        if (position_changed) update.cursor_changed = true;
        if (position_changed) {
            desktop.handleMouseMove(@intCast(clamped_x), @intCast(clamped_y));
            if (desktop.isShortcutDragging()) update.desktop_changed = true;
        }
        const pressed = s.mouse_buttons & ~old_buttons;
        if ((pressed & 1) != 0) {
            desktop.handleMousePress(@intCast(clamped_x), @intCast(clamped_y));
            update.desktop_changed = true;
        }
        if ((pressed & 2) != 0) { s.start_menu_open = false; desktop.handleMouseRightClick(@intCast(clamped_x), @intCast(clamped_y)); update.desktop_changed = true; }
        if ((pressed & 4) != 0) { desktop.minimizeActiveWindow(); update.desktop_changed = true; }
        if ((pressed & 8) != 0) { desktop.launchApp(.terminal); update.desktop_changed = true; }
        if ((pressed & 16) != 0) { s.start_menu_open = !s.start_menu_open; update.desktop_changed = true; }
        if ((s.mouse_buttons & 1) == 0 and (old_buttons & 1) != 0) {
            desktop.handleMouseRelease();
            s.dragging = false;
            if (s.active_window >= 0) s.windows[@intCast(s.active_window)].resizing = false;
            update.desktop_changed = true;
        }
        if (s.mouse_packet_size == 4) {
            const wheel = @as(i8, @bitCast(s.mouse_packet[3] << 4)) >> 4;
            if (wheel != 0) {
                if (s.active_window >= 0 and s.windows[@intCast(s.active_window)].app == .files) {
                    s.scroll_offset = @max(0, @min(s.scroll_offset + @as(i32, wheel) * 24, 72));
                } else if (browser.isActive()) {
                    browser.scroll(-@as(i32, wheel) * 3);
                } else {
                    const line_delta = @as(i32, wheel) * 3;
                    if (line_delta > 0) {
                        s.terminal_view_offset = @min(s.terminal_history_count, s.terminal_view_offset + @as(usize, @intCast(line_delta)));
                    } else if (line_delta < 0) {
                        s.terminal_view_offset -|= @as(usize, @intCast(-line_delta));
                    }
                }
                update.desktop_changed = true;
            }
        }
        if (s.dragging and position_changed) {
            if (s.active_window >= 0) {
                desktop.moveWindow(@intCast(s.active_window), clamped_x, clamped_y);
                update.desktop_changed = true;
            }
        }
        s.mouse_x = @intCast(clamped_x);
        s.mouse_y = @intCast(clamped_y);
    }
    return update;
}

pub export fn aether_irq_mouse() callconv(.c) void {
    const irq_count: *volatile u64 = &s.mouse_irq_count;
    irq_count.* +%= 1;
    const status = io.in8(0x64);
    if ((status & 1) != 0) {
        const value = io.in8(0x60);
        if ((status & 0x20) != 0) {
            const next = s.mouse_head +% 1;
            if (next != s.mouse_tail) {
                s.mouse_queue[s.mouse_head] = value;
                s.mouse_head = next;
            } else {
                const drops: *volatile u64 = &s.mouse_queue_drops;
                drops.* +%= 1;
            }
        }
    }
    io.out8(0xa0, 0x20);
    io.out8(0x20, 0x20);
}

