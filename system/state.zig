const framebuffer = @import("../graphics/framebuffer.zig");
const storage = @import("../fs/storage.zig");

pub var fb: framebuffer.Framebuffer = undefined;
pub var pixels: [*]volatile u32 = undefined;
pub var framebuffer_backbuffer: ?[*]u32 = null;
pub var framebuffer_backbuffer_active = false;
pub var mouse_x: u64 = 0;
pub var mouse_y: u64 = 0;
pub var mouse_packet: [4]u8 = .{ 0, 0, 0, 0 };
pub var mouse_packet_index: u8 = 0;
pub var mouse_buttons: u8 = 0;
pub var mouse_packet_size: u8 = 3;
pub var mouse_clicked: u8 = 0;
pub var scroll_offset: i32 = 0;
pub const App = enum(u8) { none, files, settings, terminal, editor, system, browser, image_viewer, game, accounts, aether_studio, aether_runtime, media_player, zip_tool };
pub const Window = struct {
    app: App = .none,
    x: u64 = 0,
    y: u64 = 0,
    w: u64 = 480,
    h: u64 = 320,
    open: bool = false,
    minimized: bool = false,
    maximized: bool = false,
    resizing: bool = false,
};
pub var windows = [_]Window{ .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{} };
pub var active_window: i8 = -1;
pub var start_menu_open = false;
pub var boot_splash_visible = false;
/// Light is the default; the Personalization settings page can switch this at runtime.
pub var dark_theme = false;
pub var dragging = false;
pub var drag_x: u64 = 0;
pub var drag_y: u64 = 0;
pub var keyboard_shift_mask: u8 = 0;
pub var keyboard_ctrl_mask: u8 = 0;
pub var keyboard_alt_mask: u8 = 0;
pub var keyboard_win_mask: u8 = 0;
pub var keyboard_win_used = false;
pub var task_switcher_open = false;
pub var task_switcher_window: i8 = -1;
pub var keyboard_caps = false;
pub var keyboard_num = true;
pub var keyboard_scroll_lock = false;
pub var screenshot_requested = false;
pub var keyboard_extended = false;
pub var keyboard_pause_bytes: u8 = 0;
pub var terminal_line: [80]u8 = @splat(0);
pub var terminal_len: usize = 0;
pub var terminal_cursor: usize = 0;
pub var terminal_insert = true;
pub var terminal_selection: ?usize = null;
pub const TerminalHistoryKind = enum(u8) { command, output, success, failure };
pub const TerminalHistoryLine = struct {
    text: [96]u8 = @splat(0),
    len: u8 = 0,
    kind: TerminalHistoryKind = .output,
};
pub const terminal_history_capacity = 128;
pub var terminal_history: [terminal_history_capacity]TerminalHistoryLine = @splat(.{});
pub var terminal_history_head: usize = 0;
pub var terminal_history_count: usize = 0;
pub const TerminalCommand = struct { text: [80]u8 = @splat(0), len: u8 = 0 };
pub const terminal_command_capacity = 32;
pub var terminal_commands: [terminal_command_capacity]TerminalCommand = @splat(.{});
pub var terminal_command_head: usize = 0;
pub var terminal_command_count: usize = 0;
pub var terminal_history_position: usize = 0;
pub var terminal_view_offset: usize = 0;
pub var terminal_reply: []const u8 = "";
pub var fs_mounted = false;
pub var fs_entries: [2048]storage.Entry = undefined;
pub var fs_entry_count: usize = 0;
pub var fs_text_buffer: [80]u8 = @splat(0);
pub var fs_current_directory: u32 = 2;
pub var fs_current_path: [1024]u8 = @splat(0);
pub var fs_current_path_len: usize = 1;
pub var desktop_directory_cluster: u32 = 2;
pub var desktop_directory_ready = false;
pub var editor_buffer: [2048]u8 = @splat(0);
pub var editor_len: usize = 0;
pub var editor_cursor: usize = 0;
pub var editor_selection: ?usize = null;
pub var editor_filename: [255]u8 = @splat(0);
pub var editor_filename_len: usize = 0;
pub var editor_dirty = false;
pub var editor_directory: u32 = 2;
pub var clipboard: [2048]u8 = @splat(0);
pub var clipboard_len: usize = 0;
pub var boot_is_uefi = false;
pub var physical_memory_bytes: u64 = 0;
pub var memory_ready = false;
pub var keyboard_ready = false;
pub var mouse_ready = false;
pub var ethernet_present = false;
pub var ethernet_link_up = false;
pub var usb_controller_count: u8 = 0;
pub var usb_connected_ports: u8 = 0;
pub var usb_xhci_present = false;
pub var usb_ehci_present = false;
pub var usb_uhci_ohci_present = false;
pub var account_name: [16]u8 = .{ 'a', 'e', 't', 'h', 'e', 'r', 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
pub var account_home: [24]u8 = .{ '/', 'h', 'o', 'm', 'e', '/', 'a', 'e', 't', 'h', 'e', 'r', 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
pub var account_ready = false;
pub var ethernet_rx_frames: u64 = 0;
pub var ethernet_arp_frames: u64 = 0;
pub var ethernet_ipv4_frames: u64 = 0;
pub var ethernet_ipv6_frames: u64 = 0;
pub var network_configured = false;
pub var network_updated = false;
pub var ipv4_mtu: u16 = 1500;
pub var ipv4_address: [4]u8 = .{ 0, 0, 0, 0 };
pub var ipv4_subnet: [4]u8 = .{ 0, 0, 0, 0 };
pub var ipv4_gateway: [4]u8 = .{ 0, 0, 0, 0 };
pub var ipv4_dns: [4]u8 = .{ 0, 0, 0, 0 };
pub var ipv4_dns_secondary: [4]u8 = .{ 0, 0, 0, 0 };
pub const Ipv4Route = struct {
    destination: [4]u8 = .{ 0, 0, 0, 0 },
    prefix_length: u8 = 0,
    gateway: [4]u8 = .{ 0, 0, 0, 0 },
};
pub var ipv4_routes: [8]Ipv4Route = @splat(.{});
pub var ipv4_route_count: usize = 0;
pub var uptime_ticks: u64 = 0;
pub var timer_irq_count: u64 = 0;
pub var keyboard_irq_count: u64 = 0;
pub var mouse_irq_count: u64 = 0;
pub var keyboard_queue_drops: u64 = 0;
pub var mouse_queue_drops: u64 = 0;
/// The PIT interrupt updates this counter asynchronously while the networking
/// code polls deadlines in optimized builds. Volatile accesses prevent a
/// polling loop from reusing a cached value forever.
pub fn uptime() u64 {
    const ticks: *volatile u64 = &uptime_ticks;
    return ticks.*;
}

pub fn advanceUptime() void {
    const ticks: *volatile u64 = &uptime_ticks;
    ticks.* +%= 1;
}

pub var keyboard_queue: [256]u8 = @splat(0);
pub var keyboard_head: u8 = 0;
pub var keyboard_tail: u8 = 0;
pub var mouse_queue: [256]u8 = @splat(0);
pub var mouse_head: u8 = 0;
pub var mouse_tail: u8 = 0;
pub var clock_time: [8]u8 = .{ '-', '-', ':', '-', '-', ' ', '-', '-' };
pub var clock_time_len: usize = 8;
pub var clock_date: [10]u8 = .{ '-', '-', '/', '-', '-', '/', '-', '-', '-', '-' };
pub var clock_valid = false;
pub var clock_second: u8 = 0xff;
pub var clock_year: u16 = 0;
pub var clock_month: u8 = 0;
pub var clock_day: u8 = 0;
pub var clock_hour: u8 = 0;
pub var clock_minute: u8 = 0;
pub var clock_unix_seconds: i64 = 0;
