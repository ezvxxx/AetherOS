const std = @import("std");
const s = @import("../system/state.zig");
const canvas = @import("../graphics/canvas.zig");
const font = @import("../graphics/font.zig");
const fat32 = @import("../fs/storage.zig");
const pmm = @import("../memory/pmm.zig");
const vm = @import("../memory/vm.zig");
const editor = @import("../shell/editor.zig");
const browser = @import("browser.zig");
const acpi = @import("../drivers/acpi.zig");
const bmp = @import("../graphics/bmp.zig");
const viewer = @import("../graphics/viewer.zig");
const media = @import("../graphics/media.zig");
const game = @import("game.zig");
const notifications = @import("../system/notifications.zig");
const usb = @import("../drivers/usb.zig");
const audio = @import("../drivers/audio.zig");
const aetherlang = @import("../apps/aetherlang.zig");
const media_player = @import("../apps/media_player.zig");
const zip_tool = @import("../apps/zip_tool.zig");
const search = @import("../apps/search.zig");

pub var start_search: [40]u8 = @splat(0);
pub var start_search_len: usize = 0;
const menu_apps = [_]s.App{ .terminal, .files, .settings, .editor, .system, .browser, .image_viewer, .game, .accounts, .aether_studio, .media_player, .zip_tool };

const Shortcut = struct { app: s.App, x: u64, y: u64, name: [32]u8 = @splat(0), name_len: u8 = 0 };
const shortcut_capacity = 12;
const DesktopMenu = enum { none, background, shortcut, desktop_file, explorer_entry, explorer_background, app_picker };
const TopMenu = enum { none, finder, file, edit, view, go, window, help };
var top_menu: TopMenu = .none;
const finder_menu_items = [_][]const u8{ "About AetherOS", "Open Files", "Settings" };
const file_menu_items = [_][]const u8{ "New Window", "New Folder", "Close Window" };
const edit_menu_items = [_][]const u8{ "Cut", "Copy", "Paste" };
const view_menu_items = [_][]const u8{ "Refresh", "Light Theme", "Dark Theme", "Show Desktop" };
const go_menu_items = [_][]const u8{ "Home", "Desktop", "Computer" };
const window_menu_items = [_][]const u8{ "Files", "Settings", "Terminal", "Text Editor", "System Info", "Browser", "Image Viewer", "Aether Dodge", "Users", "AetherLang Studio", "Aether App", "Media Player", "Zip Tool", "Minimize", "Maximize", "Close" };
const help_menu_items = [_][]const u8{"About AetherOS"};
const window_apps = [_]s.App{ .files, .settings, .terminal, .editor, .system, .browser, .image_viewer, .game, .accounts, .aether_studio, .aether_runtime, .media_player, .zip_tool };
var shortcuts: [shortcut_capacity]Shortcut = undefined;
var shortcut_count: usize = 0;
var desktop_files: [32]fat32.Entry = undefined;
var desktop_file_count: usize = 0;
const DesktopFilePosition = struct { x: u64 = 0, y: u64 = 0 };
var desktop_file_positions: [32]DesktopFilePosition = @splat(.{});
var dragging_file: ?usize = null;
var menu_file: usize = 0;
var desktop_menu: DesktopMenu = .none;
var menu_x: u64 = 0;
var desktop_menu_y: u64 = 0;
var menu_shortcut: usize = 0;
var dragging_shortcut: ?usize = null;
var shortcut_dragged = false;
var shortcut_press_x: u64 = 0;
var shortcut_press_y: u64 = 0;
var shortcut_origin_x: u64 = 0;
var shortcut_origin_y: u64 = 0;
var selected_shortcut: ?usize = null;
var last_shortcut_click: ?usize = null;
var last_shortcut_click_tick: u64 = 0;
var pending_shortcut_x: u64 = 20;
var pending_shortcut_y: u64 = 36;
var pending_file_click: ?usize = null;
var renaming_shortcut: ?usize = null;
var rename_buffer: [255]u8 = @splat(0);
var rename_len: usize = 0;
var renaming_file = false;
var explorer_target: fat32.Entry = .{};
var explorer_target_directory: u32 = 2;
const ClipboardEntry = struct { entry: fat32.Entry, directory: u32, cut: bool };
var file_clipboard: ?ClipboardEntry = null;
var properties_entry: ?fat32.Entry = null;
var properties_open = false;

const copy_depth_limit = 8;
var copy_scratch: [copy_depth_limit][256]fat32.Entry = undefined;

pub fn pasteClipboardInto(directory: u32) bool {
    const pending = file_clipboard orelse {
        notifications.show("Clipboard is empty");
        return false;
    };
    if (pending.cut and pending.directory == directory) {
        file_clipboard = null;
        notifications.show("Item is already in this folder");
        return false;
    }
    var target_name: [255]u8 = @splat(0);
    const target = if (pending.cut) pending.entry.name[0..pending.entry.name_len] else uniqueCopyName(directory, pending.entry.name[0..pending.entry.name_len], &target_name) orelse {
        notifications.show("Could not create a copy name");
        return false;
    };
    if (!copyEntry(pending.directory, directory, pending.entry, target, 0)) {
        notifications.show("Copy failed; check available disk space");
        return false;
    }
    if (pending.cut) {
        if (!fat32.deleteEntryAt(pending.directory, pending.entry.name[0..pending.entry.name_len])) {
            notifications.show("Copied, but could not remove the original");
            return false;
        }
        file_clipboard = null;
    }
    notifications.show(if (pending.cut) "Item moved" else "Item copied");
    refreshFileViews();
    return true;
}

pub fn copyExplorerSelection(cut: bool) void {
    if (explorer_target.name_len == 0) {
        notifications.show("Right-click an item first");
        return;
    }
    file_clipboard = .{ .entry = explorer_target, .directory = explorer_target_directory, .cut = cut };
    notifications.show(if (cut) "Item ready to move" else "Item copied to clipboard");
}

fn uniqueCopyName(directory: u32, original: []const u8, output: *[255]u8) ?[]const u8 {
    var entries: [256]fat32.Entry = undefined;
    const count = fat32.listDirectory(directory, &entries);
    var suffix: u32 = 1;
    while (suffix < 1000) : (suffix += 1) {
        const candidate = std.fmt.bufPrint(output, "Copy ({d}) {s}", .{ suffix, original }) catch return null;
        var exists = false;
        for (entries[0..count]) |entry| if (std.ascii.eqlIgnoreCase(entry.name[0..entry.name_len], candidate)) {
            exists = true;
            break;
        };
        if (!exists) return candidate;
    }
    return null;
}

fn copyEntry(source_directory: u32, destination_directory: u32, entry: fat32.Entry, destination_name: []const u8, depth: usize) bool {
    if (depth >= copy_depth_limit) return false;
    if ((entry.attributes & 0x10) != 0) {
        if (!fat32.makeDirectory(destination_directory, destination_name)) return false;
        const source_child = fat32.changeDirectory(source_directory, entry.name[0..entry.name_len]) orelse return false;
        const destination_child = fat32.changeDirectory(destination_directory, destination_name) orelse return false;
        const count = fat32.listDirectory(source_child, &copy_scratch[depth]);
        for (copy_scratch[depth][0..count]) |child| {
            if (std.mem.eql(u8, child.name[0..child.name_len], ".") or std.mem.eql(u8, child.name[0..child.name_len], "..")) continue;
            if (!copyEntry(source_child, destination_child, child, child.name[0..child.name_len], depth + 1)) return false;
        }
        return true;
    }
    const size: usize = @intCast(entry.size);
    if (size == 0) return fat32.writeFileAt(destination_directory, destination_name, "");
    const page_count = (size + pmm.page_size - 1) / pmm.page_size;
    const buffer = vm.allocatePages(page_count) orelse return false;
    defer for (0..page_count) |page| vm.freePage(@intFromPtr(buffer) + @as(u64, @intCast(page)) * pmm.page_size);
    const data = buffer[0..size];
    const read_size = fat32.readFileAt(source_directory, entry.name[0..entry.name_len], data) orelse return false;
    if (read_size != size) return false;
    return fat32.writeFileAt(destination_directory, destination_name, data);
}

fn openProperties(entry: fat32.Entry) void {
    properties_entry = entry;
    properties_open = true;
    desktop_menu = .none;
}

fn refreshFileViews() void {
    s.fs_entry_count = fat32.listDirectory(s.fs_current_directory, &s.fs_entries);
    if (search.query_len != 0) search.execute(s.fs_current_directory);
    refreshDesktopFiles();
}

fn refreshDesktopFiles() void {
    desktop_file_count = if (s.desktop_directory_ready) fat32.listDirectory(s.desktop_directory_cluster, &desktop_files) else 0;
    var saved: [9 + 32 * 67]u8 = @splat(0);
    const saved_len = fat32.readFileAt(fat32.rootCluster(), "AETHPOS.DAT", &saved) orelse 0;
    const has_saved = saved_len >= 9 and std.mem.eql(u8, saved[0..8], "AETHPOS1");
    const saved_count: usize = if (has_saved) @min(@as(usize, saved[8]), 32) else 0;
    for (desktop_files[0..desktop_file_count], 0..) |entry, index| {
        var found = false;
        if (has_saved) {
            var cursor: usize = 9;
            for (0..saved_count) |_| {
                if (cursor + 67 > saved_len) break;
                const name_len: usize = @min(@as(usize, saved[cursor]), 64);
                const column = saved[cursor + 65];
                const row = saved[cursor + 66];
                if (name_len == entry.name_len and std.mem.eql(u8, entry.name[0..entry.name_len], saved[cursor + 1 ..][0..name_len])) {
                    const pos = snapToGrid(20 + @as(u64, column) * 88, 36 + @as(u64, row) * 76, false);
                    if (!filePositionTaken(pos.x, pos.y, index)) {
                        desktop_file_positions[index] = .{ .x = pos.x, .y = pos.y };
                        found = true;
                    }
                }
                cursor += 67;
            }
        }
        if (!found) {
            const max_x = s.fb.width -| 72;
            const max_y = s.fb.height -| 54 -| 60;
            const columns = (max_x -| 20) / 88 + 1;
            const rows = (max_y -| 36) / 76 + 1;
            outer: for (0..@as(usize, @intCast(rows))) |row| {
                for (0..@as(usize, @intCast(columns))) |column| {
                    const x = 20 + @as(u64, @intCast(column)) * 88;
                    const y = 36 + @as(u64, @intCast(row)) * 76;
                    if (!shortcutCellOccupied(x, y, null) and !filePositionTaken(x, y, index)) {
                        desktop_file_positions[index] = .{ .x = x, .y = y };
                        break :outer;
                    }
                }
            }
        }
    }
}

fn filePositionTaken(x: u64, y: u64, except: usize) bool {
    for (0..@min(desktop_file_count, except)) |i| {
        if (desktop_file_positions[i].x == x and desktop_file_positions[i].y == y) return true;
    }
    return false;
}

fn saveDesktopFilePositions() void {
    if (!s.fs_mounted) return;
    var data: [9 + 32 * 67]u8 = @splat(0);
    @memcpy(data[0..8], "AETHPOS1");
    data[8] = @intCast(desktop_file_count);
    var cursor: usize = 9;
    for (desktop_files[0..desktop_file_count], 0..) |entry, i| {
        data[cursor] = entry.name_len;
        @memcpy(data[cursor + 1 ..][0..entry.name_len], entry.name[0..entry.name_len]);
        data[cursor + 65] = @intCast((desktop_file_positions[i].x -| 20) / 88);
        data[cursor + 66] = @intCast((desktop_file_positions[i].y -| 36) / 76);
        cursor += 67;
    }
    _ = fat32.writeFileAt(fat32.rootCluster(), "AETHPOS.DAT", data[0..cursor]);
}

pub fn init() void {
    if (!s.fs_mounted) return;
    var data: [9 + shortcut_capacity * 36]u8 = @splat(0);
    const length = fat32.readFileAt(fat32.rootCluster(), "AETHDESK.DAT", &data) orelse 0;
    if (length < 9) {
        refreshDesktopFiles();
        return;
    }
    const version_two = std.mem.eql(u8, data[0..8], "AETHDSK2");
    if (!version_two and !std.mem.eql(u8, data[0..8], "AETHDSK1")) return;
    const count = @min(@as(usize, data[8]), shortcut_capacity);
    var cursor: usize = 9;
    var finder_label_migrated = false;
    for (0..count) |_| {
        if (cursor + (if (version_two) @as(usize, 4) else 3) > length) break;
        const app_id = data[cursor];
        const column = data[cursor + 1];
        const row = data[cursor + 2];
        var name_len: usize = 0;
        var name: [32]u8 = @splat(0);
        if (version_two) {
            name_len = @min(@as(usize, data[cursor + 3]), name.len);
            if (cursor + 4 + name_len > length) break;
            @memcpy(name[0..name_len], data[cursor + 4 ..][0..name_len]);
            cursor += 4 + name_len;
        } else cursor += 3;
        if (app_id == @intFromEnum(s.App.files) and name_len == 6 and std.mem.eql(u8, name[0..name_len], "Finder")) {
            name = @splat(0);
            @memcpy(name[0..5], "Files");
            name_len = 5;
            finder_label_migrated = true;
        }
        var app: ?s.App = null;
        for (menu_apps) |candidate| if (@intFromEnum(candidate) == app_id) {
            app = candidate;
            break;
        };
        if (app == null) continue;
        const pos = snapToGrid(20 + @as(u64, column) * 88, 36 + @as(u64, row) * 76, false);
        const available = availableGridPosition(pos.x, pos.y, null) orelse continue;
        shortcuts[shortcut_count] = .{ .app = app.?, .x = available.x, .y = available.y, .name = name, .name_len = @intCast(name_len) };
        shortcut_count += 1;
    }
    if (finder_label_migrated) saveShortcuts();
    refreshDesktopFiles();
}

fn saveShortcuts() void {
    if (!s.fs_mounted) return;
    var data: [9 + shortcut_capacity * 36]u8 = @splat(0);
    @memcpy(data[0..8], "AETHDSK2");
    data[8] = @intCast(shortcut_count);
    var length: usize = 9;
    for (shortcuts[0..shortcut_count]) |item| {
        const offset = length;
        data[offset] = @intFromEnum(item.app);
        data[offset + 1] = @intCast((item.x -| 20) / 88);
        data[offset + 2] = @intCast((item.y -| 36) / 76);
        data[offset + 3] = item.name_len;
        @memcpy(data[offset + 4 ..][0..item.name_len], item.name[0..item.name_len]);
        length += 4 + item.name_len;
    }
    _ = fat32.writeFileAt(fat32.rootCluster(), "AETHDESK.DAT", data[0..length]);
}

fn snapToGrid(x: u64, y: u64, nearest: bool) Shortcut {
    const origin_x: u64 = 20;
    const origin_y: u64 = 36;
    const cell_w: u64 = 88;
    const cell_h: u64 = 76;
    const max_x = s.fb.width -| 72;
    const max_y = s.fb.height -| 54 -| 60;
    const rel_x = x -| origin_x;
    const rel_y = y -| origin_y;
    var column = if (nearest) (rel_x + cell_w / 2) / cell_w else rel_x / cell_w;
    var row = if (nearest) (rel_y + cell_h / 2) / cell_h else rel_y / cell_h;
    column = @min(column, (max_x -| origin_x) / cell_w);
    row = @min(row, (max_y -| origin_y) / cell_h);
    return .{ .app = .none, .x = @min(origin_x + column * cell_w, max_x), .y = @min(origin_y + row * cell_h, max_y) };
}

fn shortcutCellOccupied(x: u64, y: u64, except: ?usize) bool {
    for (shortcuts[0..shortcut_count], 0..) |item, i| {
        if (except != null and except.? == i) continue;
        if (item.x == x and item.y == y) return true;
    }
    return false;
}

fn desktopFilePosition(wanted_index: usize) ?Shortcut {
    if (!s.desktop_directory_ready or wanted_index >= desktop_file_count) return null;
    return .{ .app = .none, .x = desktop_file_positions[wanted_index].x, .y = desktop_file_positions[wanted_index].y };
}

fn gridCellOccupied(x: u64, y: u64, except: ?usize) bool {
    if (shortcutCellOccupied(x, y, except)) return true;
    for (0..desktop_file_count) |i| {
        if (desktopFilePosition(i)) |position| if (position.x == x and position.y == y) return true;
    }
    return false;
}

fn availableGridPosition(preferred_x: u64, preferred_y: u64, except: ?usize) ?Shortcut {
    const preferred = snapToGrid(preferred_x, preferred_y, false);
    if (!gridCellOccupied(preferred.x, preferred.y, except)) return preferred;
    const max_x = s.fb.width -| 72;
    const max_y = s.fb.height -| 54 -| 60;
    const columns = (max_x -| 20) / 88 + 1;
    const rows = (max_y -| 36) / 76 + 1;
    for (0..@as(usize, @intCast(rows))) |row| {
        for (0..@as(usize, @intCast(columns))) |column| {
            const x = 20 + @as(u64, @intCast(column)) * 88;
            const y = 36 + @as(u64, @intCast(row)) * 76;
            if (!gridCellOccupied(x, y, except)) return .{ .app = .none, .x = x, .y = y };
        }
    }
    return null;
}

fn shortcutAt(x: u64, y: u64) ?usize {
    for (0..shortcut_count) |i| {
        const item = shortcuts[i];
        if (x >= item.x and x < item.x + 72 and y >= item.y and y < item.y + 60) return i;
    }
    return null;
}

fn desktopFileAt(x: u64, y: u64) ?usize {
    for (0..desktop_file_count) |i| {
        const pos = desktopFilePosition(i) orelse continue;
        if (x >= pos.x and x < pos.x + 72 and y >= pos.y and y < pos.y + 60) return i;
    }
    return null;
}

fn addShortcut(app: s.App, x: u64, y: u64) void {
    if (shortcut_count >= shortcut_capacity) {
        notifications.show("Desktop is full");
        return;
    }
    for (shortcuts[0..shortcut_count]) |item| if (item.app == app) {
        notifications.show("That shortcut is already on the desktop");
        return;
    };
    if (gridCellOccupied(x, y, null)) {
        notifications.show("That desktop grid cell is occupied");
        return;
    }
    shortcuts[shortcut_count] = .{ .app = app, .x = x, .y = y };
    shortcut_count += 1;
    saveShortcuts();
}

fn openShortcut(index: usize) void {
    if (index < shortcut_count) launchApp(shortcuts[index].app);
}

pub fn beginShortcutRename(index: usize) void {
    if (index >= shortcut_count) return;
    renaming_shortcut = index;
    renaming_file = false;
    rename_buffer = @splat(0);
    const current = if (shortcuts[index].name_len != 0) shortcuts[index].name[0..shortcuts[index].name_len] else appTitle(shortcuts[index].app);
    rename_len = @min(current.len, rename_buffer.len);
    @memcpy(rename_buffer[0..rename_len], current[0..rename_len]);
    desktop_menu = .none;
}

fn beginFileRename(entry: fat32.Entry, directory: u32) void {
    renaming_shortcut = null;
    renaming_file = true;
    explorer_target = entry;
    explorer_target_directory = directory;
    rename_buffer = @splat(0);
    rename_len = @min(@as(usize, entry.name_len), rename_buffer.len);
    @memcpy(rename_buffer[0..rename_len], entry.name[0..rename_len]);
    desktop_menu = .none;
}

fn isRenamingEntry(entry: fat32.Entry, directory: u32) bool {
    return renaming_file and explorer_target_directory == directory and explorer_target.name_len == entry.name_len and
        std.mem.eql(u8, explorer_target.name[0..explorer_target.name_len], entry.name[0..entry.name_len]);
}

pub fn shortcutRenameActive() bool {
    return renaming_shortcut != null or renaming_file;
}

pub fn appendShortcutRename(ch: u8) void {
    if (!shortcutRenameActive() or ch < 0x20 or rename_len >= (if (renaming_file) @as(usize, 255) else 32)) return;
    rename_buffer[rename_len] = ch;
    rename_len += 1;
}

pub fn backspaceShortcutRename() void {
    if (!shortcutRenameActive() or rename_len == 0) return;
    rename_len -= 1;
    rename_buffer[rename_len] = 0;
}

pub fn commitShortcutRename() void {
    if (renaming_file) {
        if (rename_len == explorer_target.name_len and std.mem.eql(u8, rename_buffer[0..rename_len], explorer_target.name[0..explorer_target.name_len])) {
            renaming_file = false;
            rename_len = 0;
            return;
        }
        if (fat32.renameAt(explorer_target_directory, explorer_target.name[0..explorer_target.name_len], rename_buffer[0..rename_len])) {
            renaming_file = false;
            refreshFileViews();
        } else notifications.show("Cannot rename: check the name or an existing item");
        return;
    }
    const index = renaming_shortcut orelse return;
    if (rename_len == 0) {
        notifications.show("Shortcut name cannot be empty");
        return;
    }
    shortcuts[index].name = @splat(0);
    @memcpy(shortcuts[index].name[0..rename_len], rename_buffer[0..rename_len]);
    shortcuts[index].name_len = @intCast(rename_len);
    renaming_shortcut = null;
    saveShortcuts();
}

pub fn cancelShortcutRename() void {
    renaming_shortcut = null;
    renaming_file = false;
    rename_len = 0;
}

fn openDesktopFile(index: usize) void {
    if (index >= desktop_file_count) return;
    const entry = desktop_files[index];
    const name = entry.name[0..entry.name_len];
    s.fs_current_directory = s.desktop_directory_cluster;
    s.fs_current_path = @splat(0);
    const base = s.account_home[0..nameLen(&s.account_home)];
    const suffix = "/Desktop";
    if (base.len + suffix.len + 1 + (if ((entry.attributes & 0x10) != 0) name.len else 0) <= s.fs_current_path.len) {
        @memcpy(s.fs_current_path[0..base.len], base);
        @memcpy(s.fs_current_path[base.len .. base.len + suffix.len], suffix);
        s.fs_current_path_len = base.len + suffix.len;
        if ((entry.attributes & 0x10) != 0) {
            s.fs_current_path[s.fs_current_path_len] = '/';
            s.fs_current_path_len += 1;
            @memcpy(s.fs_current_path[s.fs_current_path_len..][0..name.len], name);
            s.fs_current_path_len += name.len;
            s.fs_current_directory = entry.first_cluster;
        }
    }
    s.fs_entry_count = fat32.listDirectory(s.fs_current_directory, &s.fs_entries);
    search.reset();
    s.scroll_offset = 0;
    if ((entry.attributes & 0x10) != 0) launchApp(.files) else openFile(name, s.desktop_directory_cluster);
}

fn createDesktopEntry(create_folder: bool) void {
    if (!s.desktop_directory_ready) {
        notifications.show("Desktop folder is unavailable");
        return;
    }
    var entries: [256]fat32.Entry = undefined;
    const count = fat32.listDirectory(s.desktop_directory_cluster, &entries);
    var suffix: u32 = 0;
    while (suffix <= 999) : (suffix += 1) {
        var buffer: [32]u8 = undefined;
        const name = if (suffix == 0)
            (if (create_folder) "New Folder" else "New.txt")
        else if (create_folder)
            (std.fmt.bufPrint(&buffer, "New Folder ({d})", .{suffix}) catch continue)
        else
            (std.fmt.bufPrint(&buffer, "New ({d}).txt", .{suffix}) catch continue);
        var exists = false;
        for (entries[0..count]) |entry| {
            if (std.ascii.eqlIgnoreCase(entry.name[0..entry.name_len], name)) {
                exists = true;
                break;
            }
        }
        if (exists) continue;
        const created = if (create_folder)
            fat32.makeDirectory(s.desktop_directory_cluster, name)
        else
            fat32.writeFileAt(s.desktop_directory_cluster, name, "");
        if (created) {
            refreshDesktopFiles();
            return;
        }
        notifications.show(if (create_folder) "Could not create folder on Desktop" else "Could not create file on Desktop");
        return;
    }
    notifications.show("Could not find a free desktop name");
}

fn createFolderIn(directory: u32) void {
    var entries: [256]fat32.Entry = undefined;
    const count = fat32.listDirectory(directory, &entries);
    var suffix: u32 = 0;
    while (suffix < 1000) : (suffix += 1) {
        var buffer: [32]u8 = undefined;
        const name = if (suffix == 0) "New Folder" else std.fmt.bufPrint(&buffer, "New Folder ({d})", .{suffix}) catch continue;
        var exists = false;
        for (entries[0..count]) |entry| if (std.ascii.eqlIgnoreCase(entry.name[0..entry.name_len], name)) {
            exists = true;
            break;
        };
        if (exists) continue;
        if (fat32.makeDirectory(directory, name)) {
            refreshFileViews();
            notifications.show("Folder created");
        } else notifications.show("Could not create folder");
        return;
    }
    notifications.show("Could not find a free folder name");
}

fn navigateToPath(path: []const u8) void {
    if (!s.fs_mounted or path.len == 0 or path.len > s.fs_current_path.len) return;
    var directory = fat32.rootCluster();
    var start: usize = 1;
    while (start < path.len) {
        var end = start;
        while (end < path.len and path[end] != '/') : (end += 1) {}
        if (end > start) directory = fat32.changeDirectory(directory, path[start..end]) orelse return;
        start = end + 1;
    }
    s.fs_current_directory = directory;
    s.fs_current_path = @splat(0);
    @memcpy(s.fs_current_path[0..path.len], path);
    s.fs_current_path_len = path.len;
    search.reset();
    s.scroll_offset = 0;
    refreshFileViews();
    launchApp(.files);
}

fn topMenuItems(menu: TopMenu) []const []const u8 {
    return switch (menu) {
        .finder => &finder_menu_items,
        .file => &file_menu_items,
        .edit => &edit_menu_items,
        .view => &view_menu_items,
        .go => &go_menu_items,
        .window => &window_menu_items,
        .help => &help_menu_items,
        .none => &.{},
    };
}

fn topMenuX(menu: TopMenu) u64 {
    return switch (menu) {
        .finder => 12,
        .file => 76,
        .edit => 118,
        .view => 160,
        .go => 202,
        .window => 232,
        .help => 286,
        .none => 0,
    };
}

fn handleTopBarClick(x: u64) void {
    if (x < 70) {
        top_menu = if (top_menu == .finder) .none else .finder;
        return;
    }
    const labels = [_]TopMenu{ .file, .edit, .view, .go, .window, .help };
    const starts = [_]u64{ 76, 118, 160, 202, 232, 286 };
    const widths = [_]u64{ 30, 30, 30, 24, 48, 30 };
    for (labels, starts, widths) |menu, start, width| {
        if (x >= start and x < start + width) {
            top_menu = if (top_menu == menu) .none else menu;
            return;
        }
    }
    top_menu = .none;
}

fn activateTopMenuItem(menu: TopMenu, row: usize) void {
    switch (menu) {
        .finder, .help => {
            if (menu == .finder and row == 1) launchApp(.files) else if (menu == .finder and row == 2) launchApp(.settings) else notifications.show("AetherOS 64-bit desktop");
        },
        .file => switch (row) {
            0 => launchApp(.files),
            1 => createFolderIn(s.fs_current_directory),
            2 => closeActiveWindow(),
            else => {},
        },
        .edit => switch (row) {
            0 => copyExplorerSelection(true),
            1 => copyExplorerSelection(false),
            2 => _ = pasteClipboardInto(s.fs_current_directory),
            else => {},
        },
        .view => switch (row) {
            0 => refreshFileViews(),
            1 => s.dark_theme = false,
            2 => s.dark_theme = true,
            3 => {
                for (&s.windows) |*win| {
                    if (win.open) win.minimized = true;
                }
                s.active_window = -1;
            },
            else => {},
        },
        .go => switch (row) {
            0 => navigateToPath(s.account_home[0..nameLen(&s.account_home)]),
            1 => {
                var path: [96]u8 = undefined;
                const home = s.account_home[0..nameLen(&s.account_home)];
                const desktop_path = std.fmt.bufPrint(&path, "{s}/Desktop", .{home}) catch return;
                navigateToPath(desktop_path);
            },
            2 => navigateToPath("/"),
            else => {},
        },
        .window => {
            if (row < window_apps.len) launchApp(window_apps[row]) else switch (row - window_apps.len) {
                0 => minimizeActiveWindow(),
                1 => if (s.active_window >= 0) toggleMaximize(@intCast(s.active_window)),
                2 => closeActiveWindow(),
                else => {},
            }
        },
        .none => {},
    }
}

pub fn handleMouseRightClick(x: u64, y: u64) void {
    if (y < 28 or y >= s.fb.height -| 54) return;
    var order_index: usize = 0;
    while (order_index < s.windows.len) : (order_index += 1) {
        const index = if (s.active_window >= 0)
            (@as(usize, @intCast(s.active_window)) + s.windows.len - order_index) % s.windows.len
        else s.windows.len - 1 - order_index;
        const win = s.windows[index];
        if (!win.open or win.minimized or x < win.x or x >= win.x + win.w or y < win.y or y >= win.y + win.h) continue;
        desktop_menu = .none;
        if (win.app != .files or y < win.y + 72 or y >= win.y + win.h -| 32) return;
        const row: usize = @intCast((y - (win.y + 72) + @as(u64, @intCast(s.scroll_offset))) / 20);
        if (search.query_len != 0) {
            if (row >= search.result_count) {
                s.active_window = @intCast(index);
                menu_x = @min(x, s.fb.width -| 174);
                desktop_menu_y = @min(y, s.fb.height -| 54);
                desktop_menu = .explorer_background;
                return;
            }
            explorer_target = search.results[row].entry;
            explorer_target_directory = search.results[row].parent_cluster;
        } else {
            if (row >= s.fs_entry_count) {
                s.active_window = @intCast(index);
                menu_x = @min(x, s.fb.width -| 174);
                desktop_menu_y = @min(y, s.fb.height -| 54);
                desktop_menu = .explorer_background;
                return;
            }
            explorer_target = s.fs_entries[row];
            explorer_target_directory = s.fs_current_directory;
        }
        s.active_window = @intCast(index);
        menu_x = @min(x, s.fb.width -| 174);
        desktop_menu_y = @min(y, s.fb.height -| 184);
        desktop_menu = .explorer_entry;
        return;
    }
    refreshDesktopFiles();
    menu_x = @min(x, s.fb.width -| 174);
    desktop_menu_y = @min(y, s.fb.height -| 184);
    if (desktopFileAt(x, y)) |index| {
        menu_file = index;
        desktop_menu = .desktop_file;
    } else if (shortcutAt(x, y)) |index| {
        menu_shortcut = index;
        desktop_menu = .shortcut;
    } else {
        const position = snapToGrid(x, y, false);
        pending_shortcut_x = position.x;
        pending_shortcut_y = position.y;
        desktop_menu = .background;
    }
}

pub fn handleMouseMove(x: u64, y: u64) void {
    if (dragging_shortcut) |index| {
        if (index >= shortcut_count) return;
        if (x > shortcut_press_x + 4 or shortcut_press_x > x + 4 or y > shortcut_press_y + 4 or shortcut_press_y > y + 4) shortcut_dragged = true;
        if (shortcut_dragged) {
            shortcuts[index].x = @min(x -| 36, s.fb.width -| 72);
            shortcuts[index].y = @min(y -| 20, s.fb.height -| 114);
        }
    }
    if (dragging_file) |index| {
        if (index >= desktop_file_count) return;
        if (x > shortcut_press_x + 4 or shortcut_press_x > x + 4 or y > shortcut_press_y + 4 or shortcut_press_y > y + 4) shortcut_dragged = true;
        if (shortcut_dragged) {
            desktop_file_positions[index].x = @min(x -| 36, s.fb.width -| 72);
            desktop_file_positions[index].y = @min(y -| 20, s.fb.height -| 114);
        }
    }
}

pub fn isShortcutDragging() bool {
    return (dragging_shortcut != null or dragging_file != null) and shortcut_dragged;
}

pub fn handleMouseRelease() void {
    if (dragging_shortcut) |index| {
        if (!shortcut_dragged) {
            const now = s.uptime();
            if (last_shortcut_click != null and last_shortcut_click.? == index and now -| last_shortcut_click_tick <= 60) {
                openShortcut(index);
                last_shortcut_click = null;
            } else {
                selected_shortcut = index;
                last_shortcut_click = index;
                last_shortcut_click_tick = now;
            }
        } else {
            last_shortcut_click = null;
            const position = snapToGrid(shortcuts[index].x, shortcuts[index].y, true);
            if (gridCellOccupied(position.x, position.y, index)) {
                shortcuts[index].x = shortcut_origin_x;
                shortcuts[index].y = shortcut_origin_y;
                notifications.show("That desktop grid cell is occupied");
            } else {
                shortcuts[index].x = position.x;
                shortcuts[index].y = position.y;
                saveShortcuts();
            }
        }
        dragging_shortcut = null;
        shortcut_dragged = false;
        pending_file_click = null;
        return;
    }
    if (dragging_file) |index| {
        if (index < desktop_file_count) {
            if (!shortcut_dragged) {
                const click_id = shortcut_capacity + index;
                const now = s.uptime();
                if (last_shortcut_click != null and last_shortcut_click.? == click_id and now -| last_shortcut_click_tick <= 60) {
                    openDesktopFile(index);
                    last_shortcut_click = null;
                } else {
                    selected_shortcut = click_id;
                    last_shortcut_click = click_id;
                    last_shortcut_click_tick = now;
                }
            } else {
                last_shortcut_click = null;
                const position = snapToGrid(desktop_file_positions[index].x, desktop_file_positions[index].y, true);
                if (shortcutCellOccupied(position.x, position.y, null) or filePositionTaken(position.x, position.y, index)) {
                    desktop_file_positions[index] = .{ .x = shortcut_origin_x, .y = shortcut_origin_y };
                    notifications.show("That desktop grid cell is occupied");
                } else {
                    desktop_file_positions[index] = .{ .x = position.x, .y = position.y };
                    saveDesktopFilePositions();
                }
            }
        }
        dragging_file = null;
        shortcut_dragged = false;
        pending_file_click = null;
        return;
    }
    if (pending_file_click) |index| {
        if (index < desktop_file_count) {
            const click_id = shortcut_capacity + index;
            const now = s.uptime();
            if (last_shortcut_click != null and last_shortcut_click.? == click_id and now -| last_shortcut_click_tick <= 60) {
                openDesktopFile(index);
                last_shortcut_click = null;
            } else {
                selected_shortcut = click_id;
                last_shortcut_click = click_id;
                last_shortcut_click_tick = now;
            }
        }
        pending_file_click = null;
    }
}
pub fn newActiveAppTab() bool {
    if (s.active_window < 0) return false;
    return s.windows[@intCast(s.active_window)].app == .browser and browser.newTab();
}

pub fn cycleActiveAppTab() bool {
    if (s.active_window < 0) return false;
    return s.windows[@intCast(s.active_window)].app == .browser and browser.tabCount() > 1 and browser.switchTab((browser.activeTab() + 1) % browser.tabCount());
}

pub fn closeActiveAppTab() bool {
    if (s.active_window < 0) return false;
    const app = s.windows[@intCast(s.active_window)].app;
    const closed = app == .browser and browser.closeTab(browser.activeTab());
    if (!closed and app == .browser) notifications.show("Keep at least one browser tab open");
    return closed;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

fn navigateExplorerPath(target_component: ?usize) void {
    if (!s.fs_mounted) return;
    var directory = fat32.rootCluster();
    if (target_component) |target| {
        var component_index: usize = 0;
        var start: usize = 1;
        while (start < s.fs_current_path_len) {
            var end = start;
            while (end < s.fs_current_path_len and s.fs_current_path[end] != '/') : (end += 1) {}
            if (end == start) break;
            directory = fat32.changeDirectory(directory, s.fs_current_path[start..end]) orelse return;
            if (component_index == target) {
                s.fs_current_directory = directory;
                s.fs_current_path_len = end;
                break;
            }
            component_index += 1;
            start = end + 1;
        }
    } else {
        s.fs_current_directory = directory;
        s.fs_current_path = @splat(0);
        s.fs_current_path[0] = '/';
        s.fs_current_path_len = 1;
    }
    search.reset();
    s.scroll_offset = 0;
    s.fs_entry_count = fat32.listDirectory(s.fs_current_directory, &s.fs_entries);
}

fn explorerPathComponentAt(character_index: usize) ?usize {
    if (character_index == 0) return null;
    var component_index: usize = 0;
    var start: usize = 1;
    while (start < s.fs_current_path_len) {
        var end = start;
        while (end < s.fs_current_path_len and s.fs_current_path[end] != '/') : (end += 1) {}
        if (character_index >= start and character_index <= end) return component_index;
        component_index += 1;
        start = end + 1;
    }
    return null;
}

fn appMatches(app: s.App) bool {
    return containsIgnoreCase(appTitle(app), start_search[0..start_search_len]);
}

pub fn startMenuAppend(ch: u8) void {
    if (ch >= 0x20 and start_search_len < start_search.len) {
        start_search[start_search_len] = ch;
        start_search_len += 1;
    }
}

pub fn startMenuBackspace() void {
    if (start_search_len == 0) return;
    start_search_len -= 1;
    start_search[start_search_len] = 0;
}

pub fn toggleStartMenu() void {
    s.start_menu_open = !s.start_menu_open;
    start_search = @splat(0);
    start_search_len = 0;
}

pub fn startMenuSubmit() void {
    if (start_search_len == 0) return;
    for (menu_apps) |app| if (appMatches(app)) {
        launchApp(app);
        start_search = @splat(0);
        start_search_len = 0;
        return;
    };
}

pub fn appSlot(app: s.App) usize {
    return switch (app) {
        .files => 0,
        .settings => 1,
        .terminal => 2,
        .editor => 3,
        .system => 4,
        .browser => 5,
        .image_viewer => 6,
        .game => 7,
        .accounts => 8,
        .aether_studio => 9,
        .aether_runtime => 10,
        .media_player => 11,
        .zip_tool => 12,
        .none => 0,
    };
}

pub fn appTitle(app: s.App) []const u8 {
    return switch (app) {
        .files => "Files",
        .settings => "Settings",
        .terminal => "Terminal",
        .editor => "Text Editor",
        .system => "System Info",
        .browser => "Browser",
        .image_viewer => "Image Viewer",
        .game => "Aether Dodge",
        .accounts => "Users",
        .aether_studio => "AetherLang Studio",
        .aether_runtime => "Aether App",
        .media_player => "Media Player",
        .zip_tool => "Zip Tool",
        .none => "AetherOS",
    };
}

pub fn launchApp(app: s.App) void {
    if (app == .none) return;
    const index = appSlot(app);
    const win = &s.windows[index];
    if (win.open and !win.minimized) {
        s.active_window = @intCast(index);
        s.start_menu_open = false;
        return;
    }
    if (app == .editor and s.editor_filename_len == 0) _ = editor.open("new.txt");
    if (app == .aether_studio and (s.editor_filename_len == 0 or s.windows[9].app != .aether_studio)) {
        _ = editor.open("hello.aeth");
        if (s.editor_len == 0) {
        const sample = "app \"Aether System Monitor\"\n\nconst std = @import(\"std\");\nconst ui = @import(\"ui\");\nconst os = @import(\"os\");\nconst fs = @import(\"fs\");\nconst gfx = @import(\"graphics\");\n\nconst background: u32 = 0xf4f6fb;\nconst title = \"AetherOS System Monitor\";\n\nfn draw() void {\n    gfx.clear(background);\n    ui.panel(20, 20, 560, 52, 0x315fbd);\n    ui.border(20, 20, 560, 52, 0x14284b);\n    ui.label(36, 38, 0xffffff, title);\n    ui.circle(548, 46, 16, 0xffffff);\n    ui.divider(36, 82, 564, 82, 0x315fbd);\n    os.clock(32, 100, 0x20242b);\n    os.info(32, 140, 0x20242b);\n    os.network(32, 236, 0x20242b);\n    fs.list(320, 100, 0x20242b);\n    fs.readText(32, 270, 0x20242b, \"README.TXT\");\n}\n";
            @memcpy(s.editor_buffer[0..sample.len], sample);
            s.editor_len = sample.len;
            s.editor_cursor = sample.len;
        }
    }
    if (app == .game) game.reset();
    if (app == .media_player) media_player.refresh();
    if (app == .zip_tool) zip_tool.start(s.fs_current_directory);
    if (app == .files) search.reset();
    const window_w = @min(if (app == .browser or app == .image_viewer or app == .media_player or app == .zip_tool) @as(u64, 860) else if (app == .aether_studio) @as(u64, 980) else 640, s.fb.width -| 24);
    const stage_h = s.fb.height -| 54;
    const window_h = @min(if (app == .browser or app == .image_viewer or app == .media_player or app == .zip_tool) @as(u64, 620) else if (app == .aether_studio) @as(u64, 680) else 440, s.fb.height -| 84);
    const offset = @as(u64, index % 3);
    win.* = .{
        .app = app,
        .x = @max(8, @min((s.fb.width -| window_w) / 2 + offset * 18, s.fb.width -| window_w -| 8)),
        .y = @max(8, @min((stage_h -| window_h) / 2 + offset * 14, stage_h -| window_h -| 8)),
        .w = window_w,
        .h = window_h,
        .open = true,
        .minimized = false,
        .maximized = false,
    };
    if (app == .terminal) {
        s.terminal_line = @splat(0);
        s.terminal_len = 0;
    }
    s.active_window = @intCast(index);
    s.start_menu_open = false;
}

/// Open a compiled AetherLang binary in its own application window.
/// Returns true when the filename belongs to the .ath format.
pub fn launchAetherAppFile(name: []const u8, directory: u32) bool {
    if (name.len < 4 or !std.ascii.eqlIgnoreCase(name[name.len - 4 ..], ".ath")) return false;
    const length = fat32.readFileAt(directory, name, &aetherlang.artifact) orelse {
        notifications.show("Could not read this .ath application");
        return true;
    };
    if (!aetherlang.activateArtifact(length)) {
        notifications.show(aetherlang.status[0..aetherlang.status_len]);
        return true;
    }
    launchApp(.aether_runtime);
    return true;
}

pub fn toggleMaximize(index: usize) void {
    if (index >= s.windows.len or !s.windows[index].open) return;
    var win = &s.windows[index];
    if (win.maximized) {
        win.maximized = false;
        win.w = @min(540, s.fb.width -| 24);
        win.h = @min(370, s.fb.height -| 84);
        win.x = @max(8, s.fb.width / 2 -| win.w / 2);
        win.y = @max(8, s.fb.height / 2 -| win.h / 2);
    } else {
        win.maximized = true;
        win.x = 8;
        win.y = 8;
        win.w = s.fb.width -| 16;
        win.h = s.fb.height -| 70;
    }
}

pub fn closeActiveWindow() void {
    if (s.active_window < 0) return;
    s.windows[@intCast(s.active_window)].open = false;
    s.windows[@intCast(s.active_window)].minimized = false;
    s.active_window = -1;
}

pub fn minimizeActiveWindow() void {
    if (s.active_window < 0) return;
    s.windows[@intCast(s.active_window)].minimized = true;
    s.active_window = -1;
}

pub fn focusNextWindow() void {
    var n: usize = 1;
    while (n <= s.windows.len) : (n += 1) {
        const base: usize = if (s.active_window < 0) s.windows.len - 1 else @intCast(s.active_window);
        const index = (base + n) % s.windows.len;
        if (s.windows[index].open and !s.windows[index].minimized) {
            s.active_window = @intCast(index);
            return;
        }
    }
}

pub fn focusPreviousWindow() void {
    var n: usize = 1;
    while (n <= s.windows.len) : (n += 1) {
        const base: usize = if (s.active_window < 0) 0 else @intCast(s.active_window);
        const index = (base + s.windows.len - n) % s.windows.len;
        if (s.windows[index].open and !s.windows[index].minimized) {
            s.active_window = @intCast(index);
            return;
        }
    }
}

pub fn advanceTaskSwitcher(reverse: bool) void {
    const base: usize = if (s.task_switcher_window >= 0)
        @intCast(s.task_switcher_window)
    else if (s.active_window >= 0)
        @intCast(s.active_window)
    else if (reverse)
        0
    else
        s.windows.len - 1;
    var n: usize = 1;
    while (n <= s.windows.len) : (n += 1) {
        const index = if (reverse)
            (base + s.windows.len - (n % s.windows.len)) % s.windows.len
        else
            (base + n) % s.windows.len;
        if (s.windows[index].open) {
            s.task_switcher_window = @intCast(index);
            return;
        }
    }
}

pub fn commitTaskSwitcher() void {
    if (!s.task_switcher_open) return;
    if (s.task_switcher_window >= 0) {
        const index: usize = @intCast(s.task_switcher_window);
        if (s.windows[index].open) {
            s.windows[index].minimized = false;
            s.active_window = @intCast(index);
            s.start_menu_open = false;
        }
    }
    s.task_switcher_open = false;
    s.task_switcher_window = -1;
}

pub fn drawTaskSwitcher() void {
    if (!s.task_switcher_open) return;
    const card_w: u64 = @min(840, s.fb.width -| 8);
    const card_h: u64 = 112;
    const x = if (s.fb.width > card_w) s.fb.width / 2 - card_w / 2 else 4;
    const y = if (s.fb.height > card_h) s.fb.height / 2 - card_h / 2 else 44;
    const panel = if (s.dark_theme) canvas.color(28, 28, 30) else canvas.color(250, 250, 250);
    const tile = if (s.dark_theme) canvas.color(43, 43, 45) else canvas.color(238, 238, 238);
    const selected_tile = if (s.dark_theme) canvas.color(72, 72, 74) else canvas.color(220, 220, 220);
    const ink = if (s.dark_theme) canvas.color(245, 245, 245) else canvas.color(28, 28, 28);
    const muted = if (s.dark_theme) canvas.color(165, 165, 165) else canvas.color(105, 105, 105);
    const accent = if (s.dark_theme) canvas.color(205, 205, 205) else canvas.color(55, 55, 55);
    canvas.fillRoundedRect(x, y, @min(card_w, s.fb.width -| x), @min(card_h, s.fb.height -| y), 12, panel);
    font.drawText(x + 14, y + 12, "Switch window", 1, accent);
    for (s.windows, 0..) |win, index| {
        if (!win.open) continue;
        const cell_w = (card_w -| 24) / s.windows.len;
        const tile_w = cell_w -| 6;
        const tile_x = x + 12 + @as(u64, index) * cell_w;
        const selected = s.task_switcher_window == @as(i8, @intCast(index));
        canvas.fillRoundedRect(tile_x, y + 34, tile_w, 60, 7, if (selected) selected_tile else tile);
        if (selected) canvas.fillRoundedRect(tile_x + 8, y + 90, tile_w -| 16, 3, 2, accent);
        drawAppIcon(tile_x + tile_w / 2 -| 12, y + 40, 24, win.app, ink);
        font.drawTextCentered(tile_x + 3, y + 68, tile_w -| 6, 12, appTitle(win.app), 1, ink);
        if (win.minimized) font.drawTextCentered(tile_x + 3, y + 81, tile_w -| 6, 10, "Minimized", 1, muted);
    }
}

pub fn cycleApplicationTab(reverse: bool) void {
    const base: usize = if (s.active_window < 0) (if (reverse) 0 else s.windows.len - 1) else @intCast(s.active_window);
    var n: usize = 1;
    while (n <= s.windows.len) : (n += 1) {
        const index = if (reverse)
            (base + s.windows.len - (n % s.windows.len)) % s.windows.len
        else
            (base + n) % s.windows.len;
        const app: s.App = switch (index) {
            0 => .files,
            1 => .settings,
            2 => .terminal,
            3 => .editor,
            4 => .system,
            5 => .browser,
            6 => .image_viewer,
            7 => .game,
            8 => .accounts,
            9 => .aether_studio,
            10 => .aether_runtime,
            11 => .media_player,
            12 => .zip_tool,
            else => .zip_tool,
        };
        if (s.windows[index].open) {
            s.windows[index].minimized = false;
            s.active_window = @intCast(index);
            s.start_menu_open = false;
        } else {
            launchApp(app);
        }
        return;
    }
}

pub fn moveWindow(index: usize, x: i32, y: i32) void {
    if (index >= s.windows.len) return;
    var win = &s.windows[index];
    if (win.maximized) return;
    const max_x = s.fb.width -| win.w;
    const max_y = s.fb.height -| 56;
    const new_x = x - @as(i32, @intCast(s.drag_x));
    const new_y = y - @as(i32, @intCast(s.drag_y));
    if (win.resizing) {
        const width = @max(320, @min(x - @as(i32, @intCast(win.x)), @as(i32, @intCast(s.fb.width -| win.x))));
        const height = @max(220, @min(y - @as(i32, @intCast(win.y)), @as(i32, @intCast(s.fb.height -| win.y -| 54))));
        win.w = @intCast(width);
        win.h = @intCast(height);
    } else {
        win.x = @intCast(@max(0, @min(new_x, @as(i32, @intCast(max_x)))));
        win.y = @intCast(@max(8, @min(new_y, @as(i32, @intCast(max_y)))));
    }
}

fn openFile(name: []const u8, directory: u32) void {
    if (zip_tool.isZipName(name)) {
        zip_tool.start(directory);
        launchApp(.zip_tool);
        zip_tool.setMode(.preview);
        _ = zip_tool.openArchive(name);
    } else if (media_player.isMediaName(name)) {
        launchApp(.media_player);
        media_player.openFile(directory, name);
    } else if (viewer.supportsName(name)) {
        _ = viewer.loadFromDisk(name, directory);
        launchApp(.image_viewer);
    } else if (!launchAetherAppFile(name, directory) and editor.open(name)) {
        launchApp(.editor);
    }
}

pub fn handleMousePress(x: u64, y: u64) void {
    if (properties_open) {
        properties_open = false;
        properties_entry = null;
        return;
    }
    if (renaming_file) return;
    if (y < 28) {
        handleTopBarClick(x);
        return;
    }
    if (top_menu != .none) {
        const items = topMenuItems(top_menu);
        const popup_x = topMenuX(top_menu);
        const popup_y: u64 = 28;
        const popup_w: u64 = 176;
        if (x >= popup_x and x < popup_x + popup_w and y >= popup_y and y < popup_y + @as(u64, @intCast(items.len)) * 24) {
            const row: usize = @intCast((y - popup_y) / 24);
            activateTopMenuItem(top_menu, row);
            top_menu = .none;
            return;
        }
        top_menu = .none;
    }
    if (s.start_menu_open) {
        const menu_y = s.fb.height -| 732;
        if (x >= 16 and x < 264 and y >= menu_y and y < s.fb.height -| 56) {
            const offset_y = y - menu_y;
            if (offset_y >= 520 and offset_y < 556) {
                s.start_menu_open = false;
                if (!acpi.sleep()) notifications.show("Sleep is unavailable on this firmware");
                return;
            }
            if (offset_y >= 556 and offset_y < 592) {
                if (!acpi.canShutdown()) return;
                s.start_menu_open = false;
                acpi.shutdown();
                return;
            }
            if (offset_y >= 592 and offset_y < 628) {
                s.start_menu_open = false;
                acpi.reboot();
                return;
            }
            if (offset_y >= 76 and offset_y < 76 + menu_apps.len * 32) {
                const row = (offset_y - 76) / 32;
                var filtered_index: usize = 0;
                for (menu_apps) |app| {
                    if (!appMatches(app)) continue;
                    if (filtered_index == row) {
                        launchApp(app);
                        start_search = @splat(0);
                        start_search_len = 0;
                        return;
                    }
                    filtered_index += 1;
                }
            }
            return;
        }
        s.start_menu_open = false;
    }

    if (desktop_menu != .none) {
        const menu_w: u64 = 164;
        const row_h: u64 = if (desktop_menu == .app_picker) 24 else 30;
        const rows: usize = switch (desktop_menu) {
            .background => 4,
            .shortcut => 3,
            .explorer_entry => 6,
            .explorer_background => if (file_clipboard != null) 1 else 0,
            .desktop_file => 6,
            .app_picker => menu_apps.len,
            .none => 0,
        };
        if (x >= menu_x and x < menu_x + menu_w and y >= desktop_menu_y and y < desktop_menu_y + @as(u64, @intCast(rows)) * row_h) {
            const row: usize = @intCast((y - desktop_menu_y) / row_h);
            switch (desktop_menu) {
                .explorer_entry => {
                    if (row == 0) {
                        const target_name = explorer_target.name[0..explorer_target.name_len];
                        if ((explorer_target.attributes & 0x10) != 0) {
                            if (fat32.changeDirectory(explorer_target_directory, target_name)) |next| {
                                s.fs_current_directory = next;
                                if (s.fs_current_path_len > 1 and s.fs_current_path_len < s.fs_current_path.len) {
                                    s.fs_current_path[s.fs_current_path_len] = '/';
                                    s.fs_current_path_len += 1;
                                }
                                const copy_len = @min(target_name.len, s.fs_current_path.len -| s.fs_current_path_len);
                                @memcpy(s.fs_current_path[s.fs_current_path_len..][0..copy_len], target_name[0..copy_len]);
                                s.fs_current_path_len += copy_len;
                                refreshFileViews();
                            }
                        } else openFile(target_name, explorer_target_directory);
                    } else if (row == 1) {
                        beginFileRename(explorer_target, explorer_target_directory);
                    } else if (row == 2 or row == 3) {
                        file_clipboard = .{ .entry = explorer_target, .directory = explorer_target_directory, .cut = row == 2 };
                        notifications.show(if (row == 2) "Item ready to move" else "Item copied to clipboard");
                    } else if (row == 4) {
                        if (!fat32.deleteEntryAt(explorer_target_directory, explorer_target.name[0..explorer_target.name_len])) {
                            notifications.show("Could not delete the file or folder");
                        }
                        refreshFileViews();
                    } else if (row == 5) {
                        openProperties(explorer_target);
                    }
                    desktop_menu = .none;
                },
                .background => {
                    if (row == 0) {
                        desktop_menu = .app_picker;
                        desktop_menu_y = @min(desktop_menu_y, s.fb.height -| 342);
                    } else if (row == 1 or row == 2) {
                        createDesktopEntry(row == 1);
                        desktop_menu = .none;
                    } else {
                        _ = pasteClipboardInto(s.desktop_directory_cluster);
                        desktop_menu = .none;
                    }
                },
                .explorer_background => {
                    _ = pasteClipboardInto(s.fs_current_directory);
                    desktop_menu = .none;
                },
                .shortcut => {
                    if (row == 0) {
                        openShortcut(menu_shortcut);
                        desktop_menu = .none;
                    } else if (row == 1) {
                        beginShortcutRename(menu_shortcut);
                    } else if (menu_shortcut < shortcut_count) {
                        for (menu_shortcut..shortcut_count - 1) |i| shortcuts[i] = shortcuts[i + 1];
                        shortcut_count -= 1;
                        if (selected_shortcut) |selected| {
                            selected_shortcut = if (selected == menu_shortcut) null else if (selected > menu_shortcut) selected - 1 else selected;
                        }
                        last_shortcut_click = null;
                        saveShortcuts();
                        desktop_menu = .none;
                    }
                },
                .app_picker => {
                    if (row < menu_apps.len) addShortcut(menu_apps[row], pending_shortcut_x, pending_shortcut_y);
                    desktop_menu = .none;
                },
                .desktop_file => {
                    if (row == 0) {
                        openDesktopFile(menu_file);
                    } else if (row == 1 and menu_file < desktop_file_count) {
                        beginFileRename(desktop_files[menu_file], s.desktop_directory_cluster);
                    } else if ((row == 2 or row == 3) and menu_file < desktop_file_count) {
                        file_clipboard = .{ .entry = desktop_files[menu_file], .directory = s.desktop_directory_cluster, .cut = row == 2 };
                        notifications.show(if (row == 2) "Item ready to move" else "Item copied to clipboard");
                    } else if (row == 4 and menu_file < desktop_file_count) {
                        const entry = desktop_files[menu_file];
                        if (fat32.deleteEntryAt(s.desktop_directory_cluster, entry.name[0..entry.name_len])) {
                            refreshDesktopFiles();
                            selected_shortcut = null;
                        } else {
                            notifications.show("Could not remove this desktop item");
                        }
                    } else if (row == 5 and menu_file < desktop_file_count) {
                        openProperties(desktop_files[menu_file]);
                    }
                    desktop_menu = .none;
                },
                .none => {},
            }
            return;
        }
        desktop_menu = .none;
    }

    const dock_y = s.fb.height -| 54;
    if (y >= dock_y) {
        if (x < 112) {
            toggleStartMenu();
            return;
        }
        const center = s.fb.width / 2;
        if (x >= center -| 100 and x < center -| 50) {
            launchApp(.terminal);
            return;
        }
        if (x >= center -| 50 and x < center) {
            launchApp(.files);
            return;
        }
        if (x >= center and x < center + 50) {
            launchApp(.settings);
            return;
        }
        if (x >= center + 50 and x < center + 100) {
            launchApp(.browser);
            return;
        }
    }

    // Active window is painted last, so check it first when hit-testing.
    var order: [s.windows.len]usize = undefined;
    for (0..order.len) |i| order[i] = i;
    if (s.active_window >= 0) {
        const a: usize = @intCast(s.active_window);
        for (0..s.windows.len) |offset| order[offset] = (a + 1 + offset) % s.windows.len;
    }
    var oi: usize = order.len;
    while (oi > 0) {
        oi -= 1;
        const index = order[oi];
        var win = &s.windows[index];
        if (!win.open or win.minimized) continue;
        if (x < win.x or x >= win.x + win.w or y < win.y or y >= win.y + win.h) continue;
        s.active_window = @intCast(index);
        if (!win.maximized and x >= win.x + win.w -| 16 and y >= win.y + win.h -| 16) {
            win.resizing = true;
            s.dragging = true;
            s.drag_x = x - win.x;
            s.drag_y = y - win.y;
            return;
        }
        if (win.app == .settings and y >= win.y + 78 and y < win.y + 154) {
            s.dark_theme = x >= win.x + win.w / 2;
            return;
        }
        if (win.app == .aether_studio and y >= win.y + 32 and y < win.y + 62) {
            if (x < win.x + 110) {
                if (editor.save()) aetherlang.status_len = 0 else {
                    const message = "Source save failed";
                    @memcpy(aetherlang.status[0..message.len], message);
                    aetherlang.status_len = message.len;
                }
            } else if (x < win.x + 222) {
                if (aetherlang.compile(s.editor_buffer[0..s.editor_len])) {
                    if (!s.fs_mounted or !fat32.writeFileAt(s.fs_current_directory, "app.ath", aetherlang.artifact[0..aetherlang.artifact_len])) {
                        const message = "Build ok, but app.ath could not be saved";
                        @memcpy(aetherlang.status[0..message.len], message);
                        aetherlang.status_len = message.len;
                    }
                }
            } else if (x < win.x + 326) {
                if (aetherlang.compile(s.editor_buffer[0..s.editor_len])) aetherlang.preview_enabled = true;
            }
            return;
        }
        if (win.app == .browser and y >= win.y + 30 and (win.maximized or x < win.x + win.w -| 16 or y < win.y + win.h -| 16)) {
            browser.handleMousePress(x, y, win.*);
            return;
        }
        if (win.app == .media_player and y >= win.y + 30) {
            const controls_y = win.y + win.h -| 36;
            if (y >= controls_y and y < controls_y + 26) {
                if (x >= win.x + 18 and x < win.x + 98) media_player.play() else if (x >= win.x + 106 and x < win.x + 186) media_player.stopVideo();
            } else if (x < win.x + 12 + @min(@as(u64, 214), win.w / 3)) {
                media_player.selectAt(y, win.y, win.h);
            }
            return;
        }
        if (win.app == .zip_tool and y >= win.y + 32) {
            const rel_x = x - win.x;
            const rel_y = y - win.y;
            if (rel_y >= 36 and rel_y < 64) {
                if (rel_x < 112) zip_tool.setMode(.preview) else if (rel_x < 216) zip_tool.setMode(.reader) else if (rel_x < 320) zip_tool.setMode(.create);
                return;
            }
            if (zip_tool.mode == .create) {
                if (rel_y >= 66 and rel_y < 96 and rel_x >= 300 and rel_x < 420) {
                    _ = zip_tool.createSelected();
                    return;
                }
                if (rel_y >= 66 and rel_y < 96 and rel_x < 92) {
                    if (zip_tool.directory_cluster != 2) _ = zip_tool.changeDirectory("..");
                    return;
                }
                if (rel_y >= 120) {
                    const row: usize = @intCast((rel_y - 120 + @as(u64, @intCast(s.scroll_offset))) / 20);
                    if (row < zip_tool.file_count) {
                        const item = zip_tool.files[row];
                        if ((item.attributes & 0x10) != 0) {
                            _ = zip_tool.changeDirectory(item.name[0..item.name_len]);
                        } else zip_tool.selected_files[row] = !zip_tool.selected_files[row];
                    }
                    return;
                }
            } else if (zip_tool.opened_zip_len == 0) {
                if (rel_y >= 66 and rel_y < 96 and rel_x < 92) {
                    if (zip_tool.directory_cluster != 2) _ = zip_tool.changeDirectory("..");
                    return;
                }
                if (rel_y >= 120) {
                    const row: usize = @intCast((rel_y - 120 + @as(u64, @intCast(s.scroll_offset))) / 20);
                    var visible: usize = 0;
                    for (zip_tool.files[0..zip_tool.file_count]) |item| {
                        if ((item.attributes & 0x10) != 0 or !zip_tool.isZipName(item.name[0..item.name_len])) continue;
                        if (visible == row) {
                            _ = zip_tool.openArchive(item.name[0..item.name_len]);
                            return;
                        }
                        visible += 1;
                    }
                }
            } else {
                if (rel_y >= 66 and rel_y < 96) {
                    if (rel_x >= 300 and rel_x < 420 and zip_tool.mode == .reader) _ = zip_tool.extractSelected() else if (rel_x >= 430 and rel_x < 510) zip_tool.closeArchive();
                    return;
                }
                if (rel_y >= 120) {
                    const row: usize = @intCast((rel_y - 120 + @as(u64, @intCast(s.scroll_offset))) / 20);
                    if (row < zip_tool.zip_count) zip_tool.selected_zip_entry = row;
                    return;
                }
            }
            return;
        }
        if (win.app == .files and y >= win.y + 38 and y < win.y + 62) {
            const search_w = @min(@as(u64, 200), win.w / 3);
            const search_x = win.x + win.w -| 18 -| search_w;
            if (x >= search_x) {
                search.focused = true;
            } else if (x >= win.x + 18) {
                const character_index: usize = @intCast((x - (win.x + 18)) / 6);
                if (character_index < s.fs_current_path_len) navigateExplorerPath(explorerPathComponentAt(character_index));
            }
            return;
        }
        if (win.app == .files and y >= win.y + 72) {
            const row: usize = @intCast((y - (win.y + 72) + @as(u64, @intCast(s.scroll_offset))) / 20);
            if (search.query_len != 0) {
                if (row < search.result_count) openFile(search.results[row].entry.name[0..search.results[row].entry.name_len], search.results[row].parent_cluster);
                search.focused = false;
                return;
            }
            if (row < s.fs_entry_count) {
                const entry = s.fs_entries[row];
                const name = entry.name[0..entry.name_len];
                if ((entry.attributes & 0x10) != 0) {
                    if (fat32.changeDirectory(s.fs_current_directory, name)) |next| {
                        search.reset();
                        s.fs_current_directory = next;
                        if (s.fs_current_path_len > 1 and s.fs_current_path_len + name.len + 1 < s.fs_current_path.len) {
                            s.fs_current_path[s.fs_current_path_len] = '/';
                            s.fs_current_path_len += 1;
                        }
                        if (s.fs_current_path_len + name.len < s.fs_current_path.len) {
                            @memcpy(s.fs_current_path[s.fs_current_path_len..][0..name.len], name);
                            s.fs_current_path_len += name.len;
                        }
                        s.scroll_offset = 0;
                        s.fs_entry_count = fat32.listDirectory(next, &s.fs_entries);
                    }
                } else openFile(name, s.fs_current_directory);
                return;
            }
        }
        if (y < win.y + 30) {
            const title_x = x - win.x;
            if (title_x >= 8 and title_x < 28) {
                win.open = false;
                s.active_window = -1;
            } else if (title_x >= 28 and title_x < 46) {
                win.minimized = true;
                s.active_window = -1;
            } else if (title_x >= 46 and title_x < 64) {
                toggleMaximize(index);
            } else if (!win.maximized) {
                s.dragging = true;
                s.drag_x = x - win.x;
                s.drag_y = y - win.y;
            }
        }
        return;
    }
    if (shortcutAt(x, y)) |shortcut_index| {
        dragging_shortcut = shortcut_index;
        shortcut_dragged = false;
        pending_file_click = null;
        selected_shortcut = shortcut_index;
        shortcut_press_x = x;
        shortcut_press_y = y;
        shortcut_origin_x = shortcuts[shortcut_index].x;
        shortcut_origin_y = shortcuts[shortcut_index].y;
        desktop_menu = .none;
        return;
    }
    if (desktopFileAt(x, y)) |file_index| {
        selected_shortcut = shortcut_capacity + file_index;
        dragging_file = file_index;
        shortcut_dragged = false;
        pending_file_click = file_index;
        shortcut_press_x = x;
        shortcut_press_y = y;
        shortcut_origin_x = desktop_file_positions[file_index].x;
        shortcut_origin_y = desktop_file_positions[file_index].y;
        desktop_menu = .none;
        return;
    }
    selected_shortcut = null;
    last_shortcut_click = null;
    pending_file_click = null;
    desktop_menu = .none;
    refreshDesktopFiles();
}

pub fn drawWindow(index: usize) void {
    const win = s.windows[index];
    if (!win.open or win.minimized) return;
    const panel = if (s.dark_theme) canvas.color(27, 27, 29) else canvas.color(250, 250, 250);
    const title = if (s.dark_theme) (if (s.active_window == @as(i8, @intCast(index))) canvas.color(48, 48, 50) else canvas.color(34, 34, 36)) else (if (s.active_window == @as(i8, @intCast(index))) canvas.color(232, 232, 232) else canvas.color(242, 242, 242));
    const border = if (s.dark_theme) canvas.color(78, 78, 80) else canvas.color(205, 205, 205);
    const text = if (s.dark_theme) canvas.color(238, 238, 238) else canvas.color(32, 32, 32);
    const muted = if (s.dark_theme) canvas.color(158, 158, 158) else canvas.color(95, 95, 95);
    const accent = if (s.dark_theme) canvas.color(205, 205, 205) else canvas.color(55, 55, 55);
    canvas.fillRoundedRect(win.x, win.y, win.w, win.h, 6, border);
    canvas.fillRoundedRect(win.x + 1, win.y + 1, win.w -| 2, win.h -| 2, 5, panel);
    canvas.fillRoundedTopRect(win.x + 1, win.y + 1, win.w -| 2, 29, 5, title);
    canvas.fillRoundedRect(win.x + 12, win.y + 9, 12, 12, 6, canvas.color(255, 95, 86));
    canvas.fillRoundedRect(win.x + 30, win.y + 9, 12, 12, 6, canvas.color(255, 189, 46));
    canvas.fillRoundedRect(win.x + 48, win.y + 9, 12, 12, 6, canvas.color(39, 201, 63));
    if (win.app == .editor) {
        const title_x = win.x + 72;
        const title_y = win.y + 11;
        font.drawText(title_x, title_y, "Text Editor (", 1, text);
        const title_capacity: usize = @intCast((win.w -| 164) / 6);
        const name_capacity = @min(s.editor_filename_len, title_capacity -| 16);
        var display_name: [255]u8 = @splat(0);
        for (s.editor_filename[0..name_capacity], 0..) |ch, i| {
            display_name[i] = if (ch >= 'A' and ch <= 'Z') ch + 32 else ch;
        }
        const name_x = title_x + 78;
        font.drawText(name_x, title_y, display_name[0..name_capacity], 1, text);
        const suffix_x = name_x + @as(u64, @intCast(name_capacity)) * 6;
        font.drawText(suffix_x, title_y, ")", 1, text);
        if (s.editor_dirty) font.drawText(suffix_x + 6, title_y, "*", 1, canvas.color(255, 190, 64));
    } else if (win.app == .browser) {
        font.drawText(win.x + 72, win.y + 11, "Browser", 1, text);
        const document_title = browser.documentTitle();
        if (document_title.len != 0) {
            const capacity: usize = @intCast((win.w -| 180) / 6);
            font.drawText(win.x + 126, win.y + 11, document_title[0..@min(document_title.len, capacity)], 1, muted);
        }
    } else if (win.app == .image_viewer) {
        font.drawText(win.x + 72, win.y + 11, "Image Viewer (", 1, text);
        const name = media.currentName();
        const max_name: usize = @intCast((win.w -| 180) / 6);
        const name_len = @min(name.len, max_name);
        font.drawText(win.x + 162, win.y + 11, name[0..name_len], 1, text);
        font.drawText(win.x + 162 + @as(u64, @intCast(name_len)) * 6, win.y + 11, ")", 1, text);
    } else {
        font.drawText(win.x + 72, win.y + 11, appTitle(win.app), 1, text);
    }

    const cx = win.x + 18;
    const cy = win.y + 52;
    switch (win.app) {
        .files => {
            if (s.fs_mounted) {
                const search_w = @min(@as(u64, 200), win.w / 3);
                const search_x = win.x + win.w -| 18 -| search_w;
                for (s.fs_current_path[0..s.fs_current_path_len], 0..) |ch, i| {
                    const path_x = cx + @as(u64, @intCast(i)) * 6;
                    if (path_x + 6 >= search_x -| 8) break;
                    const color = if (ch == '/') muted else accent;
                    font.drawText(path_x, win.y + 46, &.{ch}, 1, color);
                }
            } else font.drawText(cx, win.y + 46, "No disk", 1, muted);
            const search_w = @min(@as(u64, 200), win.w / 3);
            const search_x = win.x + win.w -| 18 -| search_w;
            const search_y = win.y + 38;
            canvas.fillRect(search_x, search_y, search_w, 24, if (s.dark_theme) canvas.color(15, 15, 15) else canvas.color(255, 255, 255));
            const query_text = if (search.query_len == 0) "Search" else search.query[0..search.query_len];
            const visible_chars: usize = @intCast((search_w -| 12) / 6);
            const query_start = if (query_text.len > visible_chars) query_text.len - visible_chars else 0;
            font.drawText(search_x + 6, search_y + 8, query_text[query_start..], 1, if (search.query_len == 0) muted else text);
            if (s.fs_mounted) {
                if (search.query_len != 0) {
                    for (search.results[0..search.result_count], 0..) |result, item_index| {
                        const row_y = win.y + 72 + @as(u64, @intCast(item_index)) * 20 -| @as(u64, @intCast(s.scroll_offset));
                        if (row_y > win.y + win.h -| 32) break;
                        if (isRenamingEntry(result.entry, result.parent_cluster)) {
                            drawInlineRename(cx -| 4, row_y -| 3, win.w -| 48, 18, text);
                        } else font.drawText(cx, row_y, result.entry.name[0..result.entry.name_len], 1, text);
                        font.drawText(cx + @as(u64, result.entry.name_len) * 6 + 12, row_y, result.parent_name[0..result.parent_name_len], 1, muted);
                    }
                    if (search.result_count == 0) font.drawText(cx, win.y + 74, if (!search.has_searched) "Press Enter to find matching files" else search.status, 1, muted);
                } else {
                    for (s.fs_entries[0..s.fs_entry_count], 0..) |entry, item_index| {
                        const row_y = win.y + 72 + @as(u64, @intCast(item_index)) * 20 -| @as(u64, @intCast(s.scroll_offset));
                        if (row_y > win.y + win.h -| 32) break;
                        if (isRenamingEntry(entry, s.fs_current_directory)) {
                            drawInlineRename(cx -| 4, row_y -| 3, win.w -| 48, 18, text);
                        } else {
                            font.drawText(cx, row_y, entry.name[0..entry.name_len], 1, text);
                            if ((entry.attributes & 0x10) != 0) font.drawText(cx + @as(u64, entry.name_len) * 6, row_y, "/", 1, accent);
                        }
                    }
                }
                if (search.query_len == 0 and s.fs_entry_count == 0) font.drawText(cx, win.y + 72, "(empty)", 1, muted);
            }
        },
        .settings => {
            font.drawText(cx, cy, "Personalization", 1, text);
            font.drawText(cx, cy + 24, "Choose your appearance", 1, muted);
            const option_y = cy + 48;
            const option_w = (win.w -| 56) / 2;
            const light_selected = !s.dark_theme;
            const dark_selected = s.dark_theme;
            canvas.fillRect(cx, option_y, option_w, 44, if (light_selected) canvas.color(220, 220, 220) else if (s.dark_theme) canvas.color(42, 42, 44) else canvas.color(238, 238, 238));
            canvas.fillRect(cx + option_w + 8, option_y, option_w, 44, if (dark_selected) canvas.color(72, 72, 74) else if (s.dark_theme) canvas.color(42, 42, 44) else canvas.color(238, 238, 238));
            font.drawText(cx + 14, option_y + 17, "Light", 1, if (light_selected) canvas.color(28, 28, 28) else text);
            font.drawText(cx + option_w + 22, option_y + 17, "Dark", 1, if (dark_selected) canvas.color(255, 255, 255) else text);
            font.drawText(cx, option_y + 62, if (s.dark_theme) "Dark theme is active" else "Light theme is active", 1, muted);
        },
        .terminal => {
            const prompt_color = if (s.dark_theme) canvas.color(205, 205, 205) else canvas.color(55, 55, 55);
            const line_height: u64 = 10;
            const history_rows: usize = @intCast(@max(1, (win.y + win.h -| 34 -| cy) / line_height));
            const total_lines = s.terminal_history_count + 1;
            const visible_end = total_lines -| @min(s.terminal_view_offset, total_lines - 1);
            const first_line = visible_end -| @min(history_rows, visible_end);
            const visible_rows = visible_end - first_line;
            const max_chars: usize = @intCast(@max(1, (win.w -| 36) / 6));
            for (0..visible_rows) |row| {
                const line_index = first_line + row;
                const y = cy + @as(u64, @intCast(row)) * line_height;
                if (line_index == s.terminal_history_count) {
                    font.drawText(cx, y, "aether@os:~$", 1, prompt_color);
                    const input_x = cx + 84;
                    const visible_chars = @min(s.terminal_len, @as(usize, @intCast((win.w -| 126) / 6)));
                    const view_start = if (s.terminal_cursor > visible_chars) s.terminal_cursor - visible_chars else 0;
                    const view_end = @min(s.terminal_len, view_start + visible_chars);
                    var char_index = view_start;
                    while (char_index < view_end) : (char_index += 1) {
                        const selected = if (s.terminal_selection) |anchor|
                            char_index >= @min(anchor, s.terminal_cursor) and char_index < @max(anchor, s.terminal_cursor)
                        else
                            false;
                        const px = input_x + @as(u64, @intCast(char_index - view_start)) * 6;
                        if (selected) canvas.fillRect(px, y -| 2, 6, 10, accent);
                        font.drawText(px, y, s.terminal_line[char_index .. char_index + 1], 1, if (selected) canvas.color(10, 18, 32) else text);
                    }
                    if (s.terminal_cursor >= view_start and s.terminal_cursor <= view_end) {
                        const caret_x = input_x + @as(u64, @intCast(s.terminal_cursor - view_start)) * 6;
                        canvas.fillRect(caret_x, y -| 2, if (s.terminal_insert) 2 else 5, 9, accent);
                    }
                    continue;
                }
                const history_index = (s.terminal_history_head + s.terminal_history.len - s.terminal_history_count + line_index) % s.terminal_history.len;
                const entry = s.terminal_history[history_index];
                if (entry.kind == .command) {
                    font.drawText(cx, y, "aether@os:~$", 1, prompt_color);
                    const text_len = @min(@as(usize, entry.len), max_chars -| 14);
                    font.drawText(cx + 84, y, entry.text[0..text_len], 1, text);
                } else {
                    const ink = switch (entry.kind) {
                        .success => canvas.color(116, 220, 151),
                        .failure => canvas.color(255, 119, 128),
                        else => canvas.color(194, 205, 220),
                    };
                    font.drawText(cx, y, entry.text[0..@min(@as(usize, entry.len), max_chars)], 1, ink);
                }
            }
        },
        .editor => {
            const columns: usize = @intCast(@max(1, (win.w -| 40) / 6));
            const rows: usize = @intCast(@max(1, (win.h -| 64) / 10));
            const editor_y = cy;
            const selection = editor.selectedRange();
            var line: usize = 0;
            var column: usize = 0;
            for (s.editor_buffer[0..s.editor_len], 0..) |ch, char_index| {
                if (line >= rows) break;
                if (ch == '\n' or column >= columns) {
                    line += 1;
                    column = 0;
                    if (ch == '\n') continue;
                }
                if (line < rows) {
                    const px = cx + @as(u64, @intCast(column)) * 6;
                    const py = editor_y + @as(u64, @intCast(line)) * 10;
                    const selected = if (selection) |range| char_index >= range.first and char_index < range.last else false;
                    if (selected) canvas.fillRect(px, py, 6, 8, accent);
                    font.drawText(px, py, &.{ch}, 1, if (selected) canvas.color(10, 18, 32) else text);
                }
                if (char_index < s.editor_cursor) {
                    if (ch == '\n' or column + 1 >= columns) {
                        line += 1;
                        column = 0;
                    } else column += 1;
                } else column += 1;
            }
            canvas.fillRect(cx + @as(u64, @intCast(column)) * 6, editor_y + @as(u64, @intCast(line)) * 10, 2, 8, accent);
        },
        .system => {
            const value_x = cx + 112;
            font.drawText(cx, cy, "Processor", 1, text);
            font.drawText(value_x, cy, "x86-64", 1, muted);
            font.drawText(cx, cy + 30, "Graphics", 1, text);
            font.drawText(value_x, cy + 30, "VESA / GOP framebuffer", 1, muted);
            font.drawText(cx, cy + 60, "Memory", 1, text);
            font.drawTextNumber(value_x, cy + 60, pmm.totalMemoryBytes() / (1024 * 1024), " MiB RAM", 0, muted);
            font.drawText(cx, cy + 90, "Display", 1, text);
            font.drawTextNumber(value_x, cy + 90, s.fb.width, " x ", s.fb.height, muted);
            font.drawText(cx, cy + 120, "Storage", 1, text);
            font.drawText(value_x, cy + 120, if (s.fs_mounted) "Disk ready" else "No disk detected", 1, muted);
            font.drawText(cx, cy + 150, "Firmware", 1, text);
            font.drawText(value_x, cy + 150, if (s.boot_is_uefi) "UEFI" else "BIOS", 1, muted);
            font.drawText(cx, cy + 180, "Ethernet", 1, text);
            font.drawText(value_x, cy + 180, if (!s.ethernet_present) "Not detected" else if (s.ethernet_link_up) "Connected" else "Cable disconnected", 1, muted);
            font.drawText(cx, cy + 210, "USB", 1, text);
            font.drawTextNumber(value_x, cy + 210, s.usb_controller_count, " controller(s)", 0, muted);
            if (usb.controllers().len != 0) {
                const controller = usb.controllers()[0];
                font.drawText(value_x, cy + 228, usb.controllerName(controller), 1, muted);
                font.drawText(value_x + 36, cy + 228, "PCI ", 1, muted);
                drawHex16(value_x + 60, cy + 228, controller.vendor_id, muted);
                font.drawText(value_x + 84, cy + 228, ":", 1, muted);
                drawHex16(value_x + 90, cy + 228, controller.device_id, muted);
            }
            font.drawText(cx, cy + 258, "Audio", 1, text);
            font.drawText(value_x, cy + 258, audio.description(), 1, muted);
            if (audio.controllers().len != 0) {
                const controller = audio.controllers()[0];
                font.drawText(value_x, cy + 276, audio.controllerName(controller), 1, muted);
                font.drawText(value_x + 36, cy + 276, "PCI ", 1, muted);
                drawHex16(value_x + 60, cy + 276, controller.vendor_id, muted);
                font.drawText(value_x + 84, cy + 276, ":", 1, muted);
                drawHex16(value_x + 90, cy + 276, controller.device_id, muted);
            }
            font.drawText(cx, cy + 306, "Account", 1, text);
            font.drawText(value_x, cy + 306, s.account_name[0..nameLen(&s.account_name)], 1, muted);
            font.drawText(cx, cy + 336, "Memory in use", 1, text);
            font.drawTextNumber(value_x, cy + 336, pmm.usedMemoryBytes() / (1024 * 1024), " MiB / ", pmm.totalMemoryBytes() / (1024 * 1024), muted);
            font.drawText(cx, cy + 366, "Network", 1, text);
            if (s.network_configured) font.drawIPv4(value_x, cy + 366, s.ipv4_address, muted) else font.drawText(value_x, cy + 366, "Waiting for DHCP", 1, muted);
        },
        .browser => browser.draw(win),
        .image_viewer => {
            const view_x = win.x + 8;
            const view_y = win.y + 38;
            const view_w = win.w -| 16;
            const view_h = win.h -| 48;
            canvas.fillRect(view_x, view_y, view_w, view_h, canvas.color(10, 12, 18));
            if (media.current()) |picture| {
                media.drawFit(picture, view_x, view_y, view_w, view_h);
                font.drawText(view_x + 6, win.y + win.h -| 18, media.currentName(), 1, canvas.color(190, 200, 216));
            } else {
                font.drawText(cx, cy, "Unsupported or damaged image", 1, canvas.color(255, 119, 128));
            }
        },
        .media_player => {
            const list_x = win.x + 12;
            const list_y = win.y + 38;
            const list_w = @min(@as(u64, 214), win.w / 3);
            const list_h = win.h -| 82;
            const player_x = list_x + list_w + 8;
            const player_y = list_y;
            const player_w = win.x + win.w -| 12 -| player_x;
            const player_h = list_h;
            canvas.fillRect(list_x, list_y, list_w, list_h, if (s.dark_theme) canvas.color(20, 20, 22) else canvas.color(244, 244, 244));
            canvas.fillRect(player_x, player_y, player_w, player_h, canvas.color(8, 10, 14));
            for (media_player.entries[0..media_player.count], 0..) |entry, i| {
                const row_y = list_y + 10 + @as(u64, @intCast(i)) * 22;
                if (row_y + 18 >= list_y + list_h) break;
                const is_selected = i == media_player.selected;
                if (is_selected) canvas.fillRect(list_x + 4, row_y -| 2, list_w -| 8, 18, if (s.dark_theme) canvas.color(62, 62, 64) else canvas.color(224, 224, 224));
                font.drawText(list_x + 8, row_y, entry.name[0..entry.name_len], 1, if (is_selected) accent else text);
            }
            if (media_player.count == 0) font.drawText(list_x + 8, list_y + 12, "No media files", 1, muted);
            if (player_w > 0 and player_h > 0) media_player.drawVideo(player_x, player_y, player_w, player_h);
            const controls_y = win.y + win.h -| 32;
            canvas.fillRect(win.x + 18, controls_y, 80, 24, if (s.dark_theme) canvas.color(55, 55, 57) else canvas.color(222, 222, 222));
            font.drawTextCentered(win.x + 18, controls_y, 80, 24, "Play", 1, accent);
            canvas.fillRect(win.x + 106, controls_y, 80, 24, if (s.dark_theme) canvas.color(38, 38, 40) else canvas.color(235, 235, 235));
            font.drawTextCentered(win.x + 106, controls_y, 80, 24, "Stop", 1, text);
        },
        .zip_tool => {
            const tab_y = win.y + 36;
            const tabs = [_][]const u8{ "Preview", "Reader", "Create" };
            const modes = [_]zip_tool.Mode{ .preview, .reader, .create };
            for (tabs, 0..) |label, i| {
                const tx = win.x + 12 + @as(u64, @intCast(i)) * 104;
                canvas.fillRoundedRect(tx, tab_y, 96, 24, 5, if (zip_tool.mode == modes[i]) accent else if (s.dark_theme) canvas.color(43, 43, 45) else canvas.color(232, 232, 232));
                font.drawTextCentered(tx, tab_y, 96, 24, label, 1, if (zip_tool.mode == modes[i]) canvas.color(255, 255, 255) else text);
            }
            const action_y = win.y + 66;
            if (zip_tool.mode == .create) {
                canvas.fillRect(win.x + 12, action_y, 72, 24, if (s.dark_theme) canvas.color(43, 43, 45) else canvas.color(232, 232, 232));
                font.drawTextCentered(win.x + 12, action_y, 72, 24, "Up", 1, text);
                canvas.fillRect(win.x + 300, action_y, 112, 24, accent);
                font.drawTextCentered(win.x + 300, action_y, 112, 24, "Create ZIP", 1, canvas.color(255, 255, 255));
                font.drawText(cx, win.y + 98, "Select files in this folder", 1, muted);
                for (zip_tool.files[0..zip_tool.file_count], 0..) |item, i| {
                    const row_y = win.y + 120 + @as(u64, @intCast(i)) * 20 -| @as(u64, @intCast(s.scroll_offset));
                    if (row_y > win.y + win.h -| 34) break;
                    const dir = (item.attributes & 0x10) != 0;
                    font.drawText(cx, row_y, if (dir) "[dir]" else if (zip_tool.selected_files[i]) "[x]" else "[ ]", 1, accent);
                    font.drawText(cx + 36, row_y, item.name[0..item.name_len], 1, text);
                    if (dir) font.drawText(cx + 36 + @as(u64, item.name_len) * 6, row_y, "/", 1, accent);
                }
            } else if (zip_tool.opened_zip_len == 0) {
                canvas.fillRect(win.x + 12, action_y, 72, 24, if (s.dark_theme) canvas.color(43, 43, 45) else canvas.color(232, 232, 232));
                font.drawTextCentered(win.x + 12, action_y, 72, 24, "Up", 1, text);
                font.drawText(cx, win.y + 98, "Choose a ZIP archive", 1, muted);
                var row: u64 = 0;
                for (zip_tool.files[0..zip_tool.file_count]) |item| {
                    if ((item.attributes & 0x10) != 0 or !zip_tool.isZipName(item.name[0..item.name_len])) continue;
                    const row_y = win.y + 120 + row * 20 -| @as(u64, @intCast(s.scroll_offset));
                    if (row_y > win.y + win.h -| 34) break;
                    font.drawText(cx, row_y, item.name[0..item.name_len], 1, text);
                    row += 1;
                }
            } else {
                if (zip_tool.mode == .reader) {
                    canvas.fillRect(win.x + 300, action_y, 112, 24, accent);
                    font.drawTextCentered(win.x + 300, action_y, 112, 24, "Extract", 1, canvas.color(255, 255, 255));
                }
                canvas.fillRect(win.x + 430, action_y, 72, 24, if (s.dark_theme) canvas.color(43, 43, 45) else canvas.color(232, 232, 232));
                font.drawTextCentered(win.x + 430, action_y, 72, 24, "Close", 1, text);
                font.drawText(cx, win.y + 98, zip_tool.opened_zip[0..zip_tool.opened_zip_len], 1, accent);
                for (zip_tool.zip_entries[0..zip_tool.zip_count], 0..) |entry, i| {
                    const row_y = win.y + 120 + @as(u64, @intCast(i)) * 20 -| @as(u64, @intCast(s.scroll_offset));
                    if (row_y > win.y + win.h -| 34) break;
                    if (zip_tool.selected_zip_entry == i) canvas.fillRect(cx -| 4, row_y -| 2, win.w -| 32, 16, if (s.dark_theme) canvas.color(62, 62, 64) else canvas.color(224, 224, 224));
                    font.drawText(cx, row_y, entry.path[0..entry.path_len], 1, text);
                    font.drawTextNumber(win.x + win.w -| 140, row_y, entry.size, " bytes", 0, muted);
                }
            }
            font.drawText(cx, win.y + win.h -| 22, zip_tool.status, 1, muted);
        },
        .game => game.draw(win),
        .accounts => {
            font.drawText(cx, cy, "Current local account", 1, accent);
            font.drawText(cx, cy + 28, s.account_name[0..nameLen(&s.account_name)], 1, text);
            font.drawText(cx, cy + 56, "Home directory", 1, muted);
            font.drawText(cx, cy + 74, s.account_home[0..nameLen(&s.account_home)], 1, text);
            font.drawText(cx, cy + 112, "Create accounts with: useradd NAME", 1, muted);
            font.drawText(cx, cy + 130, "Switch with: su NAME  |  whoami", 1, muted);
            font.drawText(cx, cy + 166, "Local folders are on the data disk.", 1, muted);
            font.drawText(cx, cy + 194, "This build has no password isolation yet.", 1, canvas.color(255, 190, 64));
        },
        .aether_studio => {
            const button_y = win.y + 36;
            const button_x = [_]u64{ win.x + 12, win.x + 122, win.x + 234 };
            const labels = [_][]const u8{ "Save source", "Build .ath", "Run preview" };
            for (button_x, 0..) |bx, i| {
                canvas.fillRect(bx, button_y, 104, 22, if (s.dark_theme) canvas.color(43, 43, 45) else canvas.color(226, 226, 226));
                font.drawText(bx + 8, button_y + 8, labels[i], 1, accent);
            }
            const split_x = win.x + win.w / 2;
            const code_x = win.x + 18;
            const code_y = win.y + 72;
            canvas.fillRect(code_x -| 4, code_y -| 4, win.w / 2 -| 18, win.h -| 108, if (s.dark_theme) canvas.color(15, 15, 15) else canvas.color(255, 255, 255));
            var lines = std.mem.splitScalar(u8, s.editor_buffer[0..s.editor_len], '\n');
            var row: u64 = 0;
            while (lines.next()) |line| : (row += 1) {
                if (code_y + row * 10 >= win.y + win.h -| 30) break;
                font.drawText(code_x, code_y + row * 10, line[0..@min(line.len, @as(usize, @intCast((win.w / 2 -| 32) / 6)))], 1, text);
            }
            font.drawText(split_x + 8, win.y + 58, "App preview", 1, muted);
            const preview_x = split_x + 8;
            const preview_y = win.y + 78;
            const preview_w = win.x + win.w -| preview_x -| 14;
            const preview_h = win.y + win.h -| preview_y -| 202;
            canvas.fillRect(preview_x, preview_y, preview_w, preview_h, if (s.dark_theme) canvas.color(12, 12, 12) else canvas.color(236, 236, 236));
            aetherlang.drawPreview(preview_x, preview_y, preview_w, preview_h);
            const sdk_y = preview_y + preview_h + 10;
            canvas.fillRect(preview_x, sdk_y, preview_w, 144, if (s.dark_theme) canvas.color(18, 18, 18) else canvas.color(246, 246, 246));
            font.drawText(preview_x + 8, sdk_y + 7, "AetherLang SDK", 1, accent);
            font.drawText(preview_x + 8, sdk_y + 23, "const std = @import(\"std\");  const ui = @import(\"ui\");", 1, text);
            font.drawText(preview_x + 8, sdk_y + 39, "const bg: u32 = 0xf4f6fb;  const title = \"AetherOS\";", 1, text);
            font.drawText(preview_x + 8, sdk_y + 55, "Modules: std.ui / std.os / std.fs / std.graphics", 1, muted);
            font.drawText(preview_x + 8, sdk_y + 71, "UI: panel(...) border(...) divider(...) circle(...) label(...) ", 1, text);
            font.drawText(preview_x + 8, sdk_y + 87, "OS: info(...) network(...) clock(...)  FS: list(...) readText(...) ", 1, text);
            font.drawText(preview_x + 8, sdk_y + 103, "@import(\"theme\") loads theme.alib from the current folder.", 1, muted);
            font.drawText(preview_x + 8, sdk_y + 119, "Libraries export const values with: pub const primary = 0x...;", 1, muted);
            if (aetherlang.status_len != 0) font.drawText(win.x + 14, win.y + win.h -| 19, aetherlang.status[0..aetherlang.status_len], 1, muted);
        },
        .aether_runtime => {
            canvas.fillRect(win.x + 8, win.y + 34, win.w -| 16, win.h -| 42, if (s.dark_theme) canvas.color(15, 15, 15) else canvas.color(236, 236, 236));
            aetherlang.drawPreview(win.x + 12, win.y + 38, win.w -| 24, win.h -| 50);
            if (!aetherlang.preview_enabled) font.drawText(cx, cy, "Invalid or unsupported .ath app", 1, canvas.color(220, 70, 70));
        },
        .none => {},
    }
    if (!win.maximized and s.active_window == @as(i8, @intCast(index))) {
        const grip = if (s.dark_theme) canvas.color(130, 130, 130) else canvas.color(150, 150, 150);
        for (0..4) |diagonal| {
            for (0..diagonal + 1) |step| {
                const d: u64 = @intCast(diagonal);
                const st: u64 = @intCast(step);
                canvas.putPixel(win.x + win.w -| 3 -| d + st, win.y + win.h -| 2 -| st, grip);
            }
        }
    }
}

pub fn drawActiveWindow() ?usize {
    if (s.active_window < 0) return null;
    const index: usize = @intCast(s.active_window);
    drawWindow(index);
    return index;
}

pub fn drawDesktop() void {
    const bg = if (s.dark_theme) canvas.color(16, 16, 18) else canvas.color(250, 250, 250);
    canvas.fillRect(0, 0, s.fb.width, s.fb.height, bg);
    bmp.drawWallpaper();
    drawDesktopShortcuts();

    // Windows are painted behind the start menu and dock; active window last.
    var order: [s.windows.len]usize = undefined;
    for (0..order.len) |i| order[i] = i;
    if (s.active_window >= 0) {
        const a: usize = @intCast(s.active_window);
        for (0..s.windows.len) |offset| order[offset] = (a + 1 + offset) % s.windows.len;
    }
    for (order) |index| drawWindow(index);

    drawTopBar();
    drawDesktopMenu();
    drawTaskSwitcher();

    drawDock();
    notifications.draw();
}

pub fn drawTopBar() void {
    const panel = if (s.dark_theme) canvas.color(28, 28, 30) else canvas.color(246, 246, 246);
    const edge = if (s.dark_theme) canvas.color(66, 66, 68) else canvas.color(214, 214, 214);
    const ink = if (s.dark_theme) canvas.color(238, 238, 238) else canvas.color(36, 36, 36);
    const muted = if (s.dark_theme) canvas.color(190, 190, 192) else canvas.color(88, 88, 88);
    canvas.fillRect(0, 0, s.fb.width, 28, panel);
    canvas.fillRect(0, 27, s.fb.width, 1, edge);
    if (top_menu == .finder) canvas.fillRoundedRect(10, 2, 54, 24, 4, if (s.dark_theme) canvas.color(58, 58, 60) else canvas.color(224, 224, 224));
    font.drawText(14, 10, "Finder", 1, ink);
    const menu_labels = [_][]const u8{ "File", "Edit", "View", "Go", "Window", "Help" };
    const menu_kinds = [_]TopMenu{ .file, .edit, .view, .go, .window, .help };
    var x: u64 = 78;
    for (menu_labels, menu_kinds) |label, kind| {
        if (top_menu == kind) canvas.fillRoundedRect(x -| 4, 2, @as(u64, @intCast(label.len)) * 6 + 8, 24, 4, if (s.dark_theme) canvas.color(58, 58, 60) else canvas.color(224, 224, 224));
        font.drawText(x, 10, label, 1, muted);
        x += @as(u64, @intCast(label.len)) * 6 + 18;
    }
    const time_width: u64 = @intCast(s.clock_time_len * 6);
    const date_width: u64 = @intCast(s.clock_date.len * 6);
    font.drawText(s.fb.width -| 16 -| time_width, 5, s.clock_time[0..s.clock_time_len], 1, ink);
    font.drawText(s.fb.width -| 16 -| date_width, 16, &s.clock_date, 1, muted);
    if (top_menu != .none) {
        const items = topMenuItems(top_menu);
        const popup_x = topMenuX(top_menu);
        const popup_y: u64 = 28;
        const popup_w: u64 = 176;
        const popup_h = @as(u64, @intCast(items.len)) * 24;
        const popup_edge = if (s.dark_theme) canvas.color(80, 80, 82) else canvas.color(190, 190, 190);
        canvas.fillRoundedRect(popup_x, popup_y, popup_w, popup_h, 6, popup_edge);
        canvas.fillRoundedRect(popup_x + 1, popup_y + 1, popup_w -| 2, popup_h -| 2, 5, panel);
        for (items, 0..) |label, index| {
            const item_y = popup_y + @as(u64, @intCast(index)) * 24;
            font.drawText(popup_x + 12, item_y + 8, label, 1, ink);
        }
    }
}

fn drawDesktopShortcuts() void {
    const ink = if (s.dark_theme) canvas.color(242, 242, 242) else canvas.color(34, 34, 34);
    const icon_bg = if (s.dark_theme) canvas.color(54, 54, 56) else canvas.color(224, 224, 224);
    const accent = if (s.dark_theme) canvas.color(220, 220, 220) else canvas.color(55, 55, 55);
    for (desktop_files[0..desktop_file_count], 0..) |entry, index| {
        const position = desktopFilePosition(index) orelse continue;
        const item_id = shortcut_capacity + index;
        const title = entry.name[0..entry.name_len];
        if (selected_shortcut != null and selected_shortcut.? == item_id) {
            canvas.fillRoundedRect(position.x -| 4, position.y -| 3, 80, 66, 5, if (s.dark_theme) canvas.color(54, 54, 56) else canvas.color(226, 226, 226));
        }
        canvas.fillRoundedRect(position.x + 16, position.y, 40, 40, 9, icon_bg);
        if ((entry.attributes & 0x10) != 0) {
            font.drawTextCentered(position.x + 16, position.y, 40, 40, "DIR", 1, accent);
        } else {
            var extension_start: usize = 0;
            for (title, 0..) |ch, i| if (ch == '.') {
                extension_start = i + 1;
            };
            const extension = if (extension_start < title.len) title[extension_start..@min(title.len, extension_start + 3)] else title[0..@min(title.len, 3)];
            font.drawTextCentered(position.x + 16, position.y, 40, 40, extension, 1, accent);
        }
        if (isRenamingEntry(entry, s.desktop_directory_cluster)) {
            drawInlineRename(position.x -| 4, position.y + 42, 80, 18, ink);
        } else {
            font.drawTextCentered(position.x, position.y + 44, 72, 14, title[0..@min(title.len, 12)], 1, ink);
        }
    }
    for (shortcuts[0..shortcut_count], 0..) |item, index| {
        const title = if (item.name_len != 0) item.name[0..item.name_len] else appTitle(item.app);
        if (selected_shortcut != null and selected_shortcut.? == index) {
            canvas.fillRoundedRect(item.x -| 4, item.y -| 3, 80, 66, 5, if (s.dark_theme) canvas.color(54, 54, 56) else canvas.color(226, 226, 226));
        }
        drawAppIcon(item.x + 16, item.y, 40, item.app, accent);
        font.drawTextCentered(item.x, item.y + 44, 72, 14, title, 1, ink);
    }
}

fn drawDesktopMenu() void {
    if (desktop_menu == .none) {
        drawRenameDialog();
        drawPropertiesDialog();
        return;
    }
    const panel = if (s.dark_theme) canvas.color(28, 28, 30) else canvas.color(252, 252, 252);
    const edge = if (s.dark_theme) canvas.color(77, 77, 79) else canvas.color(202, 202, 202);
    const ink = if (s.dark_theme) canvas.color(231, 231, 231) else canvas.color(36, 36, 36);
    const row_h: u64 = if (desktop_menu == .app_picker) 24 else 30;
    const rows: usize = switch (desktop_menu) {
        .background => 4,
        .shortcut => 3,
        .explorer_entry => 6,
        .explorer_background => if (file_clipboard != null) 1 else 0,
        .desktop_file => 6,
        .app_picker => menu_apps.len,
        .none => 0,
    };
    const height = @as(u64, @intCast(rows)) * row_h;
    canvas.fillRoundedRect(menu_x, desktop_menu_y, 164, height, 8, edge);
    canvas.fillRoundedRect(menu_x + 1, desktop_menu_y + 1, 162, height -| 2, 7, panel);
    switch (desktop_menu) {
        .explorer_entry => {
            const labels = [_][]const u8{ "Open", "Rename", "Cut", "Copy", "Delete", "Properties" };
            for (labels, 0..) |label, i| font.drawText(menu_x + 10, desktop_menu_y + @as(u64, @intCast(i)) * row_h + 9, label, 1, ink);
        },
        .background => {
            font.drawText(menu_x + 10, desktop_menu_y + 9, "New shortcut", 1, ink);
            font.drawText(menu_x + 10, desktop_menu_y + 39, "New folder", 1, ink);
            font.drawText(menu_x + 10, desktop_menu_y + 69, "New file", 1, ink);
            font.drawText(menu_x + 10, desktop_menu_y + 99, "Paste", 1, if (file_clipboard != null) ink else canvas.color(128, 128, 128));
        },
        .explorer_background => font.drawText(menu_x + 10, desktop_menu_y + 9, "Paste", 1, ink),
        .shortcut => {
            font.drawText(menu_x + 10, desktop_menu_y + 9, "Open", 1, ink);
            font.drawText(menu_x + 10, desktop_menu_y + 39, "Rename", 1, ink);
            font.drawText(menu_x + 10, desktop_menu_y + 69, "Remove", 1, ink);
        },
        .desktop_file => {
            font.drawText(menu_x + 10, desktop_menu_y + 9, "Open", 1, ink);
            font.drawText(menu_x + 10, desktop_menu_y + 39, "Rename", 1, ink);
            font.drawText(menu_x + 10, desktop_menu_y + 69, "Cut", 1, ink);
            font.drawText(menu_x + 10, desktop_menu_y + 99, "Copy", 1, ink);
            font.drawText(menu_x + 10, desktop_menu_y + 129, "Delete", 1, ink);
            font.drawText(menu_x + 10, desktop_menu_y + 159, "Properties", 1, ink);
        },
        .app_picker => for (menu_apps, 0..) |app, i| {
            const item_y = desktop_menu_y + @as(u64, @intCast(i)) * row_h;
            drawAppIcon(menu_x + 8, item_y + 2, 20, app, ink);
            font.drawText(menu_x + 36, item_y + 8, appTitle(app), 1, ink);
        },
        .none => {},
    }
    drawRenameDialog();
    drawPropertiesDialog();
}

fn drawPropertiesDialog() void {
    if (!properties_open or properties_entry == null) return;
    const entry = properties_entry.?;
    const panel = if (s.dark_theme) canvas.color(28, 28, 30) else canvas.color(252, 252, 252);
    const edge = if (s.dark_theme) canvas.color(77, 77, 79) else canvas.color(202, 202, 202);
    const ink = if (s.dark_theme) canvas.color(231, 231, 231) else canvas.color(36, 36, 36);
    const x = s.fb.width / 2 -| 150;
    const y: u64 = 90;
    canvas.fillRoundedRect(x, y, 300, 140, 9, edge);
    canvas.fillRoundedRect(x + 1, y + 1, 298, 138, 8, panel);
    font.drawText(x + 14, y + 12, "Properties", 1, ink);
    font.drawText(x + 14, y + 38, entry.name[0..entry.name_len], 1, ink);
    font.drawText(x + 14, y + 62, if ((entry.attributes & 0x10) != 0) "Type: Folder" else "Type: File", 1, ink);
    if ((entry.attributes & 0x10) == 0) font.drawTextNumber(x + 14, y + 84, entry.size, " bytes", 0, ink);
    font.drawText(x + 14, y + 116, "Click to close", 1, canvas.color(128, 128, 128));
}

fn drawRenameDialog() void {
    if (renaming_file) return;
    const panel = if (s.dark_theme) canvas.color(28, 28, 30) else canvas.color(252, 252, 252);
    const ink = if (s.dark_theme) canvas.color(231, 231, 231) else canvas.color(36, 36, 36);
    if (shortcutRenameActive()) {
        const dialog_x = s.fb.width / 2 -| 160;
        const dialog_y: u64 = 72;
        const dialog_edge = if (s.dark_theme) canvas.color(100, 100, 102) else canvas.color(190, 190, 190);
        canvas.fillRoundedRect(dialog_x, dialog_y, 320, 72, 9, dialog_edge);
        canvas.fillRoundedRect(dialog_x + 1, dialog_y + 1, 318, 70, 8, panel);
        font.drawText(dialog_x + 12, dialog_y + 10, if (renaming_file) "Rename  (Enter saves, Esc cancels)" else "Rename shortcut  (Enter saves, Esc cancels)", 1, ink);
        canvas.fillRoundedRect(dialog_x + 10, dialog_y + 34, 300, 26, 5, if (s.dark_theme) canvas.color(16, 16, 16) else canvas.color(255, 255, 255));
        const visible_start = rename_len -| 44;
        font.drawText(dialog_x + 18, dialog_y + 43, rename_buffer[visible_start..rename_len], 1, ink);
    }
}

fn drawInlineRename(x: u64, y: u64, width: u64, height: u64, ink: u32) void {
    const field = if (s.dark_theme) canvas.color(20, 20, 22) else canvas.color(255, 255, 255);
    const border = if (s.dark_theme) canvas.color(150, 150, 152) else canvas.color(130, 130, 130);
    canvas.fillRoundedRect(x, y, width, height, 3, border);
    canvas.fillRoundedRect(x + 1, y + 1, width -| 2, height -| 2, 2, field);
    const capacity: usize = @intCast((width -| 12) / 6);
    const start = rename_len -| capacity;
    const visible = rename_buffer[start..rename_len];
    font.drawText(x + 5, y + (height -| 8) / 2, visible, 1, ink);
    canvas.fillRect(x + 5 + @as(u64, @intCast(visible.len)) * 6, y + 4, 1, height -| 8, ink);
}

fn nameLen(value: []const u8) usize {
    for (value, 0..) |byte, index| if (byte == 0) return index;
    return value.len;
}

fn drawHex16(x: u64, y: u64, value: u16, ink: u32) void {
    const digits = "0123456789abcdef";
    var i: u4 = 0;
    while (i < 4) : (i += 1) {
        const shift: u4 = @intCast((3 - i) * 4);
        const digit = digits[@intCast((value >> shift) & 0xf)];
        font.drawText(x + @as(u64, i) * 6, y, &.{digit}, 1, ink);
    }
}

fn drawAppIcon(origin_x: u64, origin_y: u64, size: u64, app: s.App, foreground: u32) void {
    const unit = @max(@as(u64, 1), size / 26);
    const x = origin_x + (size -| 26 * unit) / 2;
    const y = origin_y + (size -| 26 * unit) / 2;
    const base = switch (app) {
        .files => canvas.color(48, 132, 224),
        .settings => canvas.color(105, 112, 124),
        .terminal => canvas.color(34, 43, 56),
        .editor => canvas.color(65, 132, 188),
        .system => canvas.color(50, 145, 158),
        .browser => canvas.color(51, 123, 214),
        .image_viewer => canvas.color(130, 93, 191),
        .game => canvas.color(220, 98, 75),
        .accounts => canvas.color(65, 157, 123),
        .aether_studio => canvas.color(135, 89, 191),
        .aether_runtime => canvas.color(224, 149, 54),
        .media_player => canvas.color(205, 77, 119),
        .zip_tool => canvas.color(182, 137, 57),
        .none => canvas.color(90, 100, 112),
    };
    const light = canvas.color(248, 250, 255);
    const dark = canvas.color(30, 42, 54);
    canvas.fillRoundedRect(origin_x, origin_y, size, size, size / 4, base);
    switch (app) {
        .files => {
            canvas.fillRoundedRect(x + 4 * unit, y + 8 * unit, 18 * unit, 13 * unit, 3 * unit, light);
            canvas.fillRoundedRect(x + 5 * unit, y + 6 * unit, 8 * unit, 5 * unit, 2 * unit, light);
            canvas.fillRoundedRect(x + 4 * unit, y + 11 * unit, 18 * unit, 10 * unit, 2 * unit, canvas.color(255, 218, 100));
        },
        .settings => {
            const mid = x + 13 * unit;
            const mid_y = y + 13 * unit;
            canvas.fillRoundedRect(mid -| 3 * unit, mid_y -| 3 * unit, 6 * unit, 6 * unit, 3 * unit, light);
            canvas.fillRoundedRect(mid -| unit, mid_y -| unit, 2 * unit, 2 * unit, unit, base);
            canvas.fillRect(mid -| unit, y + 3 * unit, 2 * unit, 5 * unit, light);
            canvas.fillRect(mid -| unit, y + 18 * unit, 2 * unit, 5 * unit, light);
            canvas.fillRect(x + 3 * unit, mid_y -| unit, 5 * unit, 2 * unit, light);
            canvas.fillRect(x + 18 * unit, mid_y -| unit, 5 * unit, 2 * unit, light);
            canvas.fillRect(x + 5 * unit, y + 5 * unit, 4 * unit, 2 * unit, light);
            canvas.fillRect(x + 17 * unit, y + 19 * unit, 4 * unit, 2 * unit, light);
        },
        .terminal => {
            canvas.fillRoundedRect(x + 4 * unit, y + 5 * unit, 18 * unit, 16 * unit, 3 * unit, light);
            canvas.fillRoundedRect(x + 6 * unit, y + 7 * unit, 14 * unit, 12 * unit, 2 * unit, dark);
            canvas.fillRect(x + 8 * unit, y + 10 * unit, 2 * unit, unit, light);
            canvas.fillRect(x + 10 * unit, y + 11 * unit, 2 * unit, unit, light);
            canvas.fillRect(x + 8 * unit, y + 12 * unit, 2 * unit, unit, light);
            canvas.fillRect(x + 13 * unit, y + 14 * unit, 4 * unit, unit, canvas.color(105, 220, 150));
        },
        .editor => {
            canvas.fillRoundedRect(x + 6 * unit, y + 3 * unit, 14 * unit, 20 * unit, 2 * unit, light);
            canvas.fillRect(x + 9 * unit, y + 8 * unit, 8 * unit, unit, base);
            canvas.fillRect(x + 9 * unit, y + 12 * unit, 8 * unit, unit, base);
            canvas.fillRect(x + 9 * unit, y + 16 * unit, 6 * unit, unit, base);
            canvas.fillRect(x + 17 * unit, y + 16 * unit, 5 * unit, 2 * unit, canvas.color(255, 210, 90));
        },
        .system => {
            canvas.fillRoundedRect(x + 3 * unit, y + 5 * unit, 20 * unit, 13 * unit, 2 * unit, light);
            canvas.fillRoundedRect(x + 5 * unit, y + 7 * unit, 16 * unit, 9 * unit, 1 * unit, dark);
            canvas.fillRect(x + 12 * unit, y + 18 * unit, 3 * unit, 3 * unit, light);
            canvas.fillRect(x + 8 * unit, y + 21 * unit, 11 * unit, 2 * unit, light);
            canvas.fillRect(x + 7 * unit, y + 12 * unit, 3 * unit, unit, canvas.color(83, 220, 170));
            canvas.fillRect(x + 10 * unit, y + 10 * unit, 3 * unit, unit, canvas.color(83, 220, 170));
            canvas.fillRect(x + 13 * unit, y + 12 * unit, 3 * unit, unit, canvas.color(83, 220, 170));
        },
        .browser => {
            canvas.fillRoundedRect(x + 4 * unit, y + 4 * unit, 18 * unit, 18 * unit, 9 * unit, light);
            canvas.fillRoundedRect(x + 8 * unit, y + 4 * unit, 10 * unit, 18 * unit, 5 * unit, base);
            canvas.fillRect(x + 5 * unit, y + 12 * unit, 16 * unit, unit, light);
            canvas.fillRect(x + 12 * unit, y + 5 * unit, unit, 16 * unit, light);
        },
        .image_viewer => {
            canvas.fillRoundedRect(x + 4 * unit, y + 4 * unit, 18 * unit, 18 * unit, 3 * unit, light);
            canvas.fillRoundedRect(x + 16 * unit, y + 7 * unit, 3 * unit, 3 * unit, 2 * unit, canvas.color(255, 197, 76));
            canvas.fillRect(x + 6 * unit, y + 16 * unit, 4 * unit, 4 * unit, canvas.color(70, 177, 145));
            canvas.fillRect(x + 10 * unit, y + 12 * unit, 4 * unit, 8 * unit, canvas.color(70, 177, 145));
            canvas.fillRect(x + 14 * unit, y + 15 * unit, 6 * unit, 5 * unit, canvas.color(70, 177, 145));
        },
        .game => {
            canvas.fillRoundedRect(x + 4 * unit, y + 9 * unit, 18 * unit, 11 * unit, 5 * unit, light);
            canvas.fillRect(x + 8 * unit, y + 11 * unit, 2 * unit, 7 * unit, base);
            canvas.fillRect(x + 6 * unit, y + 13 * unit, 6 * unit, 2 * unit, base);
            canvas.fillRoundedRect(x + 15 * unit, y + 12 * unit, 2 * unit, 2 * unit, unit, canvas.color(232, 82, 80));
            canvas.fillRoundedRect(x + 18 * unit, y + 15 * unit, 2 * unit, 2 * unit, unit, canvas.color(80, 149, 240));
        },
        .accounts => {
            canvas.fillRoundedRect(x + 10 * unit, y + 4 * unit, 7 * unit, 7 * unit, 4 * unit, light);
            canvas.fillRoundedRect(x + 5 * unit, y + 13 * unit, 17 * unit, 9 * unit, 6 * unit, light);
        },
        .aether_studio => {
            canvas.fillRect(x + 6 * unit, y + 7 * unit, 3 * unit, 2 * unit, light);
            canvas.fillRect(x + 4 * unit, y + 9 * unit, 2 * unit, 8 * unit, light);
            canvas.fillRect(x + 6 * unit, y + 17 * unit, 3 * unit, 2 * unit, light);
            canvas.fillRect(x + 17 * unit, y + 7 * unit, 3 * unit, 2 * unit, light);
            canvas.fillRect(x + 20 * unit, y + 9 * unit, 2 * unit, 8 * unit, light);
            canvas.fillRect(x + 17 * unit, y + 17 * unit, 3 * unit, 2 * unit, light);
            canvas.fillRect(x + 12 * unit, y + 7 * unit, 2 * unit, 12 * unit, canvas.color(255, 220, 110));
        },
        .aether_runtime => {
            canvas.fillRoundedRect(x + 5 * unit, y + 5 * unit, 16 * unit, 16 * unit, 8 * unit, light);
            canvas.fillRect(x + 11 * unit, y + 9 * unit, 2 * unit, 8 * unit, base);
            canvas.fillRect(x + 13 * unit, y + 10 * unit, 2 * unit, 6 * unit, base);
            canvas.fillRect(x + 15 * unit, y + 11 * unit, 2 * unit, 4 * unit, base);
        },
        .media_player => {
            canvas.fillRoundedRect(x + 4 * unit, y + 4 * unit, 18 * unit, 18 * unit, 9 * unit, light);
            canvas.fillRect(x + 11 * unit, y + 8 * unit, 2 * unit, 10 * unit, base);
            canvas.fillRect(x + 13 * unit, y + 10 * unit, 2 * unit, 6 * unit, base);
            canvas.fillRect(x + 15 * unit, y + 12 * unit, 2 * unit, 2 * unit, base);
        },
        .zip_tool => {
            canvas.fillRoundedRect(x + 5 * unit, y + 4 * unit, 16 * unit, 19 * unit, 3 * unit, light);
            canvas.fillRect(x + 12 * unit, y + 5 * unit, 3 * unit, 3 * unit, base);
            canvas.fillRect(x + 12 * unit, y + 9 * unit, 3 * unit, 3 * unit, base);
            canvas.fillRect(x + 12 * unit, y + 13 * unit, 3 * unit, 3 * unit, base);
            canvas.fillRect(x + 10 * unit, y + 18 * unit, 7 * unit, 2 * unit, canvas.color(255, 205, 85));
        },
        .none => font.drawTextCentered(x, y, size, size, "A", 1, foreground),
    }
}

pub fn drawDock() void {
    const panel = if (s.dark_theme) canvas.color(28, 28, 30) else canvas.color(250, 250, 250);
    const panel_edge = if (s.dark_theme) canvas.color(70, 70, 72) else canvas.color(210, 210, 210);
    const accent = if (s.dark_theme) canvas.color(205, 205, 205) else canvas.color(55, 55, 55);
    const white = if (s.dark_theme) canvas.color(238, 238, 238) else canvas.color(32, 32, 32);
    const muted = if (s.dark_theme) canvas.color(150, 150, 150) else canvas.color(95, 95, 95);
    const dock_y = s.fb.height -| 54;
    canvas.fillRect(0, dock_y, s.fb.width, 54, if (s.dark_theme) canvas.color(21, 21, 23) else canvas.color(240, 240, 240));
    canvas.fillRect(0, dock_y, s.fb.width, 1, panel_edge);
    canvas.fillRoundedRect(14, dock_y + 8, 88, 36, 10, if (s.dark_theme) canvas.color(43, 43, 45) else canvas.color(224, 224, 224));
    font.drawTextCentered(14, dock_y + 9, 88, 36, "Start", 1, if (s.start_menu_open) accent else white);
    const center = s.fb.width / 2;
    const icon_x = [_]u64{ center -| 92, center -| 42, center + 8, center + 58 };
    const icon_app = [_]s.App{ .terminal, .files, .settings, .browser };
    for (icon_x, 0..) |x, i| {
        const slot = appSlot(icon_app[i]);
        const active = s.windows[slot].open and !s.windows[slot].minimized;
        canvas.fillRoundedRect(x, dock_y + 7, 38, 38, 10, if (active) (if (s.dark_theme) canvas.color(52, 52, 54) else canvas.color(224, 224, 224)) else panel);
        drawAppIcon(x + 6, dock_y + 13, 26, icon_app[i], white);
        if (s.active_window == @as(i8, @intCast(slot))) canvas.fillRoundedRect(x + 13, dock_y + 48, 12, 3, 2, accent);
    }

    if (s.start_menu_open) {
        const menu_y = s.fb.height -| 732;
        const menu_outline = if (s.dark_theme) canvas.color(88, 88, 90) else canvas.color(205, 205, 205);
        canvas.fillRoundedRect(10, menu_y, 252, 680, 14, menu_outline);
        canvas.fillRoundedRect(11, menu_y + 1, 250, 678, 13, panel);
        font.drawText(28, menu_y + 15, "AetherOS", 1, accent);
        canvas.fillRoundedRect(22, menu_y + 42, 228, 26, 6, if (s.dark_theme) canvas.color(15, 20, 29) else canvas.color(255, 255, 255));
        font.drawText(30, menu_y + 51, if (start_search_len == 0) "Search apps" else start_search[0..start_search_len], 1, if (start_search_len == 0) muted else white);
        var visible_row: usize = 0;
        for (menu_apps) |app| {
            if (!appMatches(app)) continue;
            const row_y = menu_y + 78 + @as(u64, @intCast(visible_row)) * 32;
            if (row_y + 30 >= menu_y + 516) break;
            const label = appTitle(app);
            drawAppIcon(22, row_y + 2, 26, app, white);
            font.drawText(52, row_y + 10, label, 1, white);
            visible_row += 1;
        }
        if (visible_row == 0) font.drawText(28, menu_y + 88, "No matching apps", 1, muted);
        font.drawText(52, menu_y + 532, "Sleep", 1, if (acpi.sleepSupported()) white else muted);
        font.drawText(52, menu_y + 568, "Shut down", 1, if (acpi.canShutdown()) white else muted);
        font.drawText(52, menu_y + 604, "Restart", 1, white);
    }
}
