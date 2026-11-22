const s = @import("../system/state.zig");
const desktop = @import("../ui/desktop.zig");
const io = @import("../arch/io.zig");
const fat32 = @import("../fs/storage.zig");
const editor = @import("../shell/editor.zig");
const browser = @import("../ui/browser.zig");
const acpi = @import("acpi.zig");
const process = @import("../process/scheduler.zig");
const accounts = @import("../system/accounts.zig");
const notifications = @import("../system/notifications.zig");
const audio = @import("audio.zig");
const usb = @import("usb.zig");
const game = @import("../ui/game.zig");
const pci = @import("pci.zig");
const search = @import("../apps/search.zig");
const std = @import("std");

pub var active_window_only_update = false;

pub fn keyAscii(code: u8, shifted: bool, num_lock: bool) u8 {
    return switch (code) {
        0x02 => if (shifted) '!' else '1',
        0x03 => if (shifted) '@' else '2',
        0x04 => if (shifted) '#' else '3',
        0x05 => if (shifted) '$' else '4',
        0x06 => if (shifted) '%' else '5',
        0x07 => if (shifted) '^' else '6',
        0x08 => if (shifted) '&' else '7',
        0x09 => if (shifted) '*' else '8',
        0x0a => if (shifted) '(' else '9',
        0x0b => if (shifted) ')' else '0',
        0x0c => if (shifted) '_' else '-',
        0x0d => if (shifted) '+' else '=',
        0x10 => if (shifted) 'Q' else 'q',
        0x11 => if (shifted) 'W' else 'w',
        0x12 => if (shifted) 'E' else 'e',
        0x13 => if (shifted) 'R' else 'r',
        0x14 => if (shifted) 'T' else 't',
        0x15 => if (shifted) 'Y' else 'y',
        0x16 => if (shifted) 'U' else 'u',
        0x17 => if (shifted) 'I' else 'i',
        0x18 => if (shifted) 'O' else 'o',
        0x19 => if (shifted) 'P' else 'p',
        0x1a => if (shifted) '{' else '[',
        0x1b => if (shifted) '}' else ']',
        0x1e => if (shifted) 'A' else 'a',
        0x1f => if (shifted) 'S' else 's',
        0x20 => if (shifted) 'D' else 'd',
        0x21 => if (shifted) 'F' else 'f',
        0x22 => if (shifted) 'G' else 'g',
        0x23 => if (shifted) 'H' else 'h',
        0x24 => if (shifted) 'J' else 'j',
        0x25 => if (shifted) 'K' else 'k',
        0x26 => if (shifted) 'L' else 'l',
        0x27 => if (shifted) ':' else ';',
        0x28 => if (shifted) '"' else '\'',
        0x29 => if (shifted) '~' else '`',
        0x2b => if (shifted) '|' else '\\',
        0x2c => if (shifted) 'Z' else 'z',
        0x2d => if (shifted) 'X' else 'x',
        0x2e => if (shifted) 'C' else 'c',
        0x2f => if (shifted) 'V' else 'v',
        0x30 => if (shifted) 'B' else 'b',
        0x31 => if (shifted) 'N' else 'n',
        0x32 => if (shifted) 'M' else 'm',
        0x33 => if (shifted) '<' else ',',
        0x34 => if (shifted) '>' else '.',
        0x35 => if (shifted) '?' else '/',
        0x39 => ' ',
        0x37 => '*',
        0x4a => '-',
        0x4e => '+',
        0x47 => if (num_lock) '7' else 0,
        0x48 => if (num_lock) '8' else 0,
        0x49 => if (num_lock) '9' else 0,
        0x4b => if (num_lock) '4' else 0,
        0x4c => if (num_lock) '5' else 0,
        0x4d => if (num_lock) '6' else 0,
        0x4f => if (num_lock) '1' else 0,
        0x50 => if (num_lock) '2' else 0,
        0x51 => if (num_lock) '3' else 0,
        0x52 => if (num_lock) '0' else 0,
        0x53 => if (num_lock) '.' else 0,
        0x56 => if (shifted) '>' else '<',
        else => 0,
    };
}

pub fn bytesEqual(left: []const u8, right: []const u8) bool {
    if (left.len != right.len) return false;
    for (left, right) |a, b| if (a != b) return false;
    return true;
}

pub fn terminalIsActive() bool {
    return s.active_window >= 0 and s.windows[@intCast(s.active_window)].app == .terminal;
}

pub fn deleteTerminalSelection() bool {
    const anchor = s.terminal_selection orelse return false;
    const first = @min(anchor, s.terminal_cursor);
    const last = @max(anchor, s.terminal_cursor);
    s.terminal_selection = null;
    if (first == last) return false;
    var src = last;
    while (src < s.terminal_len) : (src += 1) s.terminal_line[src - (last - first)] = s.terminal_line[src];
    s.terminal_len -= last - first;
    s.terminal_cursor = first;
    return true;
}

pub fn moveTerminalCursor(position: usize, extend: bool) void {
    if (extend) {
        if (s.terminal_selection == null) s.terminal_selection = s.terminal_cursor;
    } else {
        s.terminal_selection = null;
    }
    s.terminal_cursor = @min(position, s.terminal_len);
}

pub fn insertTerminalChar(ch: u8) void {
    _ = deleteTerminalSelection();
    s.terminal_history_position = 0;
    s.terminal_view_offset = 0;
    if (s.terminal_insert) {
        if (s.terminal_len == s.terminal_line.len) return;
        var i = s.terminal_len;
        while (i > s.terminal_cursor) : (i -= 1) s.terminal_line[i] = s.terminal_line[i - 1];
        s.terminal_len += 1;
    } else if (s.terminal_cursor == s.terminal_len) {
        if (s.terminal_len == s.terminal_line.len) return;
        s.terminal_len += 1;
    }
    s.terminal_line[s.terminal_cursor] = ch;
    s.terminal_cursor += 1;
}

pub fn deleteAtTerminalCursor() void {
    if (deleteTerminalSelection()) return;
    if (s.terminal_cursor >= s.terminal_len) return;
    var i = s.terminal_cursor;
    while (i + 1 < s.terminal_len) : (i += 1) s.terminal_line[i] = s.terminal_line[i + 1];
    s.terminal_len -= 1;
    s.terminal_line[s.terminal_len] = 0;
}

pub fn backspaceTerminal() void {
    if (deleteTerminalSelection()) return;
    if (s.terminal_cursor == 0) return;
    s.terminal_history_position = 0;
    s.terminal_view_offset = 0;
    s.terminal_cursor -= 1;
    deleteAtTerminalCursor();
}

fn copyActiveSelection(terminal: bool) void {
    if (terminal) {
        const anchor = s.terminal_selection orelse return;
        const first = @min(anchor, s.terminal_cursor);
        const last = @max(anchor, s.terminal_cursor);
        s.clipboard_len = @min(last - first, s.clipboard.len);
        if (s.clipboard_len != 0) @memcpy(s.clipboard[0..s.clipboard_len], s.terminal_line[first .. first + s.clipboard_len]);
    } else if (editor.selectedRange()) |range| {
        s.clipboard_len = @min(range.last - range.first, s.clipboard.len);
        if (s.clipboard_len != 0) @memcpy(s.clipboard[0..s.clipboard_len], s.editor_buffer[range.first .. range.first + s.clipboard_len]);
    }
}

fn pasteClipboard(terminal: bool) void {
    if (terminal) {
        for (s.clipboard[0..s.clipboard_len]) |ch| {
            if (ch >= 0x20 and ch != 0x7f) insertTerminalChar(ch);
        }
    } else {
        for (s.clipboard[0..s.clipboard_len]) |ch| {
            if (ch == '\n' or (ch >= 0x20 and ch != 0x7f)) editor.insert(ch);
        }
    }
}

fn appendTerminalHistoryLine(text: []const u8, kind: s.TerminalHistoryKind) void {
    var line: s.TerminalHistoryLine = .{ .kind = kind };
    const length = @min(text.len, line.text.len);
    if (length != 0) @memcpy(line.text[0..length], text[0..length]);
    line.len = @intCast(length);
    s.terminal_history[s.terminal_history_head] = line;
    s.terminal_history_head = (s.terminal_history_head + 1) % s.terminal_history.len;
    s.terminal_history_count = @min(s.terminal_history_count + 1, s.terminal_history.len);
    s.terminal_view_offset = 0;
}

fn appendTerminalOutput(text: []const u8) void {
    if (text.len == 0) return;
    const kind: s.TerminalHistoryKind = if (startsWith(text, "Unknown") or startsWith(text, "Cannot") or startsWith(text, "Usage") or startsWith(text, "Failed") or startsWith(text, "Create failed") or startsWith(text, "Delete failed") or startsWith(text, "Write failed") or startsWith(text, "Directory not found") or startsWith(text, "No disk mounted") or startsWith(text, "File not found")) .failure else if (startsWith(text, "Created") or startsWith(text, "Deleted") or startsWith(text, "Saved") or startsWith(text, "Directory created")) .success else .output;
    var offset: usize = 0;
    while (offset < text.len) {
        if (text[offset] == '\n') {
            appendTerminalHistoryLine("", kind);
            offset += 1;
            continue;
        }
        var end = offset;
        while (end < text.len and text[end] != '\n' and end - offset < 96) : (end += 1) {}
        appendTerminalHistoryLine(text[offset..end], kind);
        offset = end;
        if (offset < text.len and text[offset] == '\n') offset += 1;
    }
}

fn rememberTerminalCommand(command: []const u8) void {
    if (command.len == 0) return;
    if (s.terminal_command_count != 0) {
        const previous = (s.terminal_command_head + s.terminal_commands.len - 1) % s.terminal_commands.len;
        const last = s.terminal_commands[previous];
        if (last.len == command.len and bytesEqual(last.text[0..last.len], command)) return;
    }
    var entry: s.TerminalCommand = .{};
    const length = @min(command.len, entry.text.len);
    @memcpy(entry.text[0..length], command[0..length]);
    entry.len = @intCast(length);
    s.terminal_commands[s.terminal_command_head] = entry;
    s.terminal_command_head = (s.terminal_command_head + 1) % s.terminal_commands.len;
    s.terminal_command_count = @min(s.terminal_command_count + 1, s.terminal_commands.len);
}

pub fn recallTerminalCommand(previous: bool) void {
    if (previous) {
        if (s.terminal_history_position < s.terminal_command_count) s.terminal_history_position += 1;
    } else if (s.terminal_history_position != 0) {
        s.terminal_history_position -= 1;
    }
    s.terminal_line = @splat(0);
    s.terminal_cursor = 0;
    s.terminal_len = 0;
    s.terminal_selection = null;
    if (s.terminal_history_position == 0) return;
    const index = (s.terminal_command_head + s.terminal_commands.len - s.terminal_history_position) % s.terminal_commands.len;
    const entry = s.terminal_commands[index];
    s.terminal_len = entry.len;
    s.terminal_cursor = entry.len;
    @memcpy(s.terminal_line[0..entry.len], entry.text[0..entry.len]);
}

pub fn scrollTerminal(lines: i32) void {
    if (lines > 0) {
        s.terminal_view_offset = @min(s.terminal_history_count, s.terminal_view_offset + @as(usize, @intCast(lines)));
    } else if (lines < 0) {
        s.terminal_view_offset -|= @as(usize, @intCast(-lines));
    }
}

pub fn runTerminalCommand() void {
    var submitted: [80]u8 = @splat(0);
    const submitted_len = s.terminal_len;
    if (submitted_len != 0) @memcpy(submitted[0..submitted_len], s.terminal_line[0..submitted_len]);
    const command = submitted[0..submitted_len];
    const is_clear = bytesEqual(command, "clear");
    rememberTerminalCommand(command);
    if (is_clear) {
        s.terminal_history_head = 0;
        s.terminal_history_count = 0;
        s.terminal_view_offset = 0;
    } else if (command.len != 0) {
        appendTerminalHistoryLine(command, .command);
    }
    s.terminal_reply = "";
    if (startsWith(command, "edit ")) {
        if (editor.open(command[5..])) desktop.launchApp(.editor) else s.terminal_reply = "Cannot open that file name";
    } else if (bytesEqual(command, "help")) {
        s.terminal_reply = "help ls cd DIR pwd mkdir DIR cat NAME touch NAME write NAME TEXT rm NAME edit NAME run demo ps irq devices acpi usb mount usb mount ide audio beep play FILE.WAV volume 0-100 game users whoami useradd NAME su NAME shutdown reboot sleep hibernate panic clear about";
    } else if (bytesEqual(command, "panic")) {
        @panic("Kernel panic requested by terminal command");
    } else if (bytesEqual(command, "mount usb")) {
        if (fat32.mountDevice(2)) {
            s.fs_mounted = true;
            s.fs_current_directory = fat32.rootCluster();
            s.fs_current_path = @splat(0);
            s.fs_current_path[0] = '/';
            s.fs_current_path_len = 1;
            refreshFilesystemListing();
            s.terminal_reply = "Mounted USB filesystem";
        } else s.terminal_reply = "No readable USB filesystem found";
    } else if (bytesEqual(command, "mount ide")) {
        if (fat32.mount()) {
            s.fs_mounted = true;
            s.fs_current_directory = fat32.rootCluster();
            s.fs_current_path = @splat(0);
            s.fs_current_path[0] = '/';
            s.fs_current_path_len = 1;
            refreshFilesystemListing();
            s.terminal_reply = "Mounted the first available filesystem";
        } else s.terminal_reply = "No readable filesystem found";
    } else if (bytesEqual(command, "acpi")) {
        s.terminal_reply = acpi.describe();
    } else if (bytesEqual(command, "shutdown")) {
        if (acpi.canShutdown()) acpi.shutdown() else s.terminal_reply = "ACPI shutdown is unavailable on this firmware";
    } else if (bytesEqual(command, "reboot")) {
        acpi.reboot();
    } else if (bytesEqual(command, "sleep")) {
        s.terminal_reply = if (acpi.sleep()) "Woke from ACPI S1 sleep" else "Sleep unavailable on this firmware";
    } else if (bytesEqual(command, "hibernate")) {
        s.terminal_reply = if (acpi.hibernateSupported()) "Hibernate requested" else "Hibernate unavailable; no hibernation image support";
    } else if (bytesEqual(command, "about")) {
        s.terminal_reply = if (s.fs_mounted) "AetherOS Zig; filesystem mounted" else "AetherOS Zig; no disk";
    } else if (bytesEqual(command, "run demo")) {
        s.terminal_reply = process.runDemo() orelse "Could not start isolated user processes";
    } else if (startsWith(command, "run ")) {
        const name = command[4..];
        if (!s.fs_mounted) {
            s.terminal_reply = "Mount a disk before running .ath apps";
        } else if (desktop.launchAetherAppFile(name, s.fs_current_directory)) {
            s.terminal_reply = "Started Aether app";
        } else {
            s.terminal_reply = "Usage: run app.ath";
        }
    } else if (bytesEqual(command, "ps")) {
        s.terminal_reply = process.list();
    } else if (bytesEqual(command, "irq")) {
        s.terminal_reply = std.fmt.bufPrint(&s.fs_text_buffer, "PIT {d}  keyboard {d} (drop {d})  mouse {d} (drop {d})", .{ s.timer_irq_count, s.keyboard_irq_count, s.keyboard_queue_drops, s.mouse_irq_count, s.mouse_queue_drops }) catch "IRQ counters unavailable";
    } else if (bytesEqual(command, "usb")) {
        s.terminal_reply = usb.description();
    } else if (bytesEqual(command, "audio")) {
        s.terminal_reply = audio.description();
    } else if (bytesEqual(command, "devices")) {
        s.terminal_reply = pci.describeDevices();
    } else if (bytesEqual(command, "beep")) {
        if (audio.available()) {
            audio.tone(880, 20);
            s.terminal_reply = "PC speaker tone played";
        } else s.terminal_reply = "No audio output available";
    } else if (bytesEqual(command, "play")) {
        s.terminal_reply = if (audio.playTestTone()) "Test tone played" else "Audio playback failed; check audio device support";
    } else if (startsWith(command, "play ")) {
        const name = command[5..];
        s.terminal_reply = if (s.fs_mounted and audio.playWav(s.fs_current_directory, name)) "WAV playback complete" else "Cannot play file; use 16-bit PCM WAV on AC'97";
    } else if (startsWith(command, "volume ")) {
        const value = command[7..];
        var parsed: u16 = 0;
        var valid = value.len != 0 and value.len <= 3;
        for (value) |digit| {
            if (digit < '0' or digit > '9') {
                valid = false;
                break;
            }
            parsed = parsed * 10 + (digit - '0');
            if (parsed > 100) {
                valid = false;
                break;
            }
        }
        if (valid) {
            audio.setVolume(@intCast(parsed));
            s.terminal_reply = "Volume updated";
        } else s.terminal_reply = "Usage: volume 0-100";
    } else if (bytesEqual(command, "game")) {
        desktop.launchApp(.game);
    } else if (bytesEqual(command, "users")) {
        desktop.launchApp(.accounts);
    } else if (bytesEqual(command, "whoami")) {
        s.terminal_reply = s.account_name[0..stringLen(&s.account_name)];
    } else if (startsWith(command, "useradd ")) {
        if (accounts.create(command[8..])) s.terminal_reply = "Account home created" else s.terminal_reply = "Create account failed";
    } else if (startsWith(command, "su ")) {
        if (accounts.switchTo(command[3..])) {
            s.terminal_reply = "Switched local account and home directory";
            notifications.show("User session changed");
        } else s.terminal_reply = "Account home not found";
    } else if (is_clear) {
        s.terminal_reply = "";
    } else if (!runFilesystemCommand(command) and s.terminal_len != 0) {
        s.terminal_reply = "Unknown command. Try help.";
    }
    if (!is_clear) appendTerminalOutput(s.terminal_reply);
    s.terminal_len = 0;
    s.terminal_cursor = 0;
    s.terminal_selection = null;
    s.terminal_line = @splat(0);
    s.terminal_history_position = 0;
    s.terminal_view_offset = 0;
}

pub fn startsWith(value: []const u8, prefix: []const u8) bool {
    return value.len >= prefix.len and bytesEqual(value[0..prefix.len], prefix);
}

fn stringLen(value: []const u8) usize {
    for (value, 0..) |byte, index| if (byte == 0) return index;
    return value.len;
}

pub fn nextSpace(value: []const u8, start: usize) ?usize {
    var i = start;
    while (i < value.len) : (i += 1) if (value[i] == ' ') return i;
    return null;
}

pub fn refreshFilesystemListing() void {
    s.fs_entry_count = if (s.fs_mounted) fat32.listDirectory(s.fs_current_directory, &s.fs_entries) else 0;
}

pub fn runFilesystemCommand(command: []const u8) bool {
    if (bytesEqual(command, "ls")) {
        if (!s.fs_mounted) {
            s.terminal_reply = "No disk. Attach a QEMU IDE drive.";
            return true;
        }
        var used: usize = 0;
        for (s.fs_entries[0..s.fs_entry_count]) |entry| {
            if (used != 0 and used < s.fs_text_buffer.len) {
                s.fs_text_buffer[used] = ' ';
                used += 1;
            }
            const length = @min(entry.name_len, s.fs_text_buffer.len - used);
            @memcpy(s.fs_text_buffer[used .. used + length], entry.name[0..length]);
            used += length;
            if (used == s.fs_text_buffer.len) break;
        }
        s.terminal_reply = if (used == 0) "(empty directory)" else s.fs_text_buffer[0..used];
        return true;
    }
    if (startsWith(command, "cat ")) {
        if (!s.fs_mounted) {
            s.terminal_reply = "No disk mounted";
            return true;
        }
        const name = command[4..];
        if (name.len == 0) {
            s.terminal_reply = "Usage: cat NAME";
            return true;
        }
        const length = fat32.readFileAt(s.fs_current_directory, name, &s.fs_text_buffer) orelse {
            s.terminal_reply = "File not found or read failed";
            return true;
        };
        s.terminal_reply = s.fs_text_buffer[0..length];
        return true;
    }
    if (startsWith(command, "touch ")) {
        if (!s.fs_mounted) {
            s.terminal_reply = "No disk mounted";
            return true;
        }
        const name = command[6..];
        if (name.len == 0 or !fat32.writeFileAt(s.fs_current_directory, name, "")) {
            s.terminal_reply = "Create failed; use a valid FAT filename";
        } else {
            s.terminal_reply = "Created file";
            refreshFilesystemListing();
        }
        return true;
    }
    if (startsWith(command, "rm ")) {
        if (!s.fs_mounted) {
            s.terminal_reply = "No disk mounted";
            return true;
        }
        if (fat32.deleteFileAt(s.fs_current_directory, command[3..])) {
            s.terminal_reply = "Deleted file";
            refreshFilesystemListing();
        } else {
            s.terminal_reply = "Delete failed or file not found";
        }
        return true;
    }
    if (startsWith(command, "write ")) {
        if (!s.fs_mounted) {
            s.terminal_reply = "No disk mounted";
            return true;
        }
        const separator = nextSpace(command, 6) orelse {
            s.terminal_reply = "Usage: write NAME TEXT";
            return true;
        };
        const name = command[6..separator];
        const content = command[separator + 1 ..];
        if (!fat32.writeFileAt(s.fs_current_directory, name, content)) {
            s.terminal_reply = "Write failed; use a valid FAT filename";
        } else {
            s.terminal_reply = "Saved file";
            refreshFilesystemListing();
        }
        return true;
    }
    if (bytesEqual(command, "pwd")) {
        s.terminal_reply = s.fs_current_path[0..s.fs_current_path_len];
        return true;
    }
    if (startsWith(command, "cd ")) {
        const name = command[3..];
        if (bytesEqual(name, "/")) {
            s.fs_current_directory = fat32.rootCluster();
            s.fs_current_path = @splat(0);
            s.fs_current_path[0] = '/';
            s.fs_current_path_len = 1;
        } else if (fat32.changeDirectory(s.fs_current_directory, name)) |next| {
            s.fs_current_directory = next;
            if (bytesEqual(name, "..")) {
                if (s.fs_current_path_len > 1) {
                    s.fs_current_path_len -= 1;
                    while (s.fs_current_path_len > 1 and s.fs_current_path[s.fs_current_path_len - 1] != '/') s.fs_current_path_len -= 1;
                    if (s.fs_current_path_len > 1) s.fs_current_path_len -= 1;
                }
            } else if (s.fs_current_path_len + name.len + 1 < s.fs_current_path.len) {
                if (s.fs_current_path_len > 1) {
                    s.fs_current_path[s.fs_current_path_len] = '/';
                    s.fs_current_path_len += 1;
                }
                @memcpy(s.fs_current_path[s.fs_current_path_len..][0..name.len], name);
                s.fs_current_path_len += name.len;
            }
            refreshFilesystemListing();
            s.terminal_reply = "Directory changed";
        } else {
            s.terminal_reply = "Directory not found";
        }
        return true;
    }
    if (startsWith(command, "mkdir ")) {
        if (fat32.makeDirectory(s.fs_current_directory, command[6..])) {
            s.terminal_reply = "Directory created";
            refreshFilesystemListing();
        } else s.terminal_reply = "mkdir failed; use a valid FAT filename";
        return true;
    }
    return false;
}

pub fn deletePreviousWord() void {
    _ = deleteTerminalSelection();
    while (s.terminal_cursor > 0 and s.terminal_line[s.terminal_cursor - 1] == ' ') backspaceTerminal();
    while (s.terminal_cursor > 0 and s.terminal_line[s.terminal_cursor - 1] != ' ') backspaceTerminal();
}

pub fn deleteNextWord() void {
    _ = deleteTerminalSelection();
    while (s.terminal_cursor < s.terminal_len and s.terminal_line[s.terminal_cursor] == ' ') deleteAtTerminalCursor();
    while (s.terminal_cursor < s.terminal_len and s.terminal_line[s.terminal_cursor] != ' ') deleteAtTerminalCursor();
}

pub fn previousWordPosition() usize {
    var position = s.terminal_cursor;
    while (position > 0 and s.terminal_line[position - 1] == ' ') position -= 1;
    while (position > 0 and s.terminal_line[position - 1] != ' ') position -= 1;
    return position;
}

pub fn nextWordPosition() usize {
    var position = s.terminal_cursor;
    while (position < s.terminal_len and s.terminal_line[position] == ' ') position += 1;
    while (position < s.terminal_len and s.terminal_line[position] != ' ') position += 1;
    return position;
}

pub fn pollKeyboard() bool {
    var changed = false;
    active_window_only_update = false;
    while (s.keyboard_tail != s.keyboard_head) {
        const scan = s.keyboard_queue[s.keyboard_tail];
        s.keyboard_tail +%= 1;
        if (scan == 0xe1) {
            s.keyboard_pause_bytes = 5;
            s.keyboard_extended = false;
            continue;
        }
        if (s.keyboard_pause_bytes != 0) {
            s.keyboard_pause_bytes -= 1;
            continue;
        }
        if (scan == 0xe0) {
            s.keyboard_extended = true;
            continue;
        }
        const extended = s.keyboard_extended;
        s.keyboard_extended = false;
        const released = (scan & 0x80) != 0;
        const code = scan & 0x7f;
        if (extended and code == 0x2a) continue; // Print Screen's synthetic Shift key.
        if (extended and code == 0x37) {
            if (!released) {
                s.screenshot_requested = true;
                changed = true;
            }
            continue;
        }

        if (!extended and code == 0x2a) {
            s.keyboard_shift_mask = if (released) s.keyboard_shift_mask & ~@as(u8, 1) else s.keyboard_shift_mask | 1;
            continue;
        }
        if (!extended and code == 0x36) {
            s.keyboard_shift_mask = if (released) s.keyboard_shift_mask & ~@as(u8, 2) else s.keyboard_shift_mask | 2;
            continue;
        }
        if (code == 0x1d) {
            s.keyboard_ctrl_mask = if (released) s.keyboard_ctrl_mask & ~@as(u8, if (extended) 2 else 1) else s.keyboard_ctrl_mask | @as(u8, if (extended) 2 else 1);
            continue;
        }
        if (code == 0x38) {
            s.keyboard_alt_mask = if (released) s.keyboard_alt_mask & ~@as(u8, if (extended) 2 else 1) else s.keyboard_alt_mask | @as(u8, if (extended) 2 else 1);
            if (released and s.keyboard_alt_mask == 0) desktop.commitTaskSwitcher();
            continue;
        }
        if (!extended and code == 0x3a and !released) {
            s.keyboard_caps = !s.keyboard_caps;
            changed = true;
            active_window_only_update = false;
            continue;
        }
        if (!extended and code == 0x45 and !released) {
            s.keyboard_num = !s.keyboard_num;
            changed = true;
            active_window_only_update = false;
            continue;
        }
        if (!extended and code == 0x46 and !released) {
            s.keyboard_scroll_lock = !s.keyboard_scroll_lock;
            changed = true;
            active_window_only_update = false;
            continue;
        }
        if (extended and (code == 0x5b or code == 0x5c)) {
            const win_bit: u8 = if (code == 0x5b) 1 else 2;
            if (!released) {
                if (s.keyboard_win_mask == 0) s.keyboard_win_used = false;
                s.keyboard_win_mask |= win_bit;
            } else {
                s.keyboard_win_mask &= ~win_bit;
                if (s.keyboard_win_mask == 0) {
                    if (!s.keyboard_win_used) desktop.toggleStartMenu();
                    s.keyboard_win_used = false;
                }
            }
            changed = true;
            active_window_only_update = false;
            continue;
        }
        if (released) continue;

        // A later pressed key in the same interrupt batch may be a desktop
        // shortcut. Clear the partial-redraw hint before classifying it.
        active_window_only_update = false;

        const game_active = s.active_window >= 0 and s.windows[@intCast(s.active_window)].app == .game;
        if (game_active and ((extended and (code == 0x4b or code == 0x4d)) or (!extended and code == 0x39))) {
            game.key(code, extended);
            changed = true;
            continue;
        }

        const ctrl = s.keyboard_ctrl_mask != 0;
        const alt = s.keyboard_alt_mask != 0;
        const shift = s.keyboard_shift_mask != 0;
        if (ctrl and alt and !extended and code == 0x19) {
            s.screenshot_requested = true;
            changed = true;
            continue;
        }
        const terminal = terminalIsActive();
        const editing = s.active_window >= 0 and (s.windows[@intCast(s.active_window)].app == .editor or s.windows[@intCast(s.active_window)].app == .aether_studio);
        const browsing = browser.isActive();
        const explorer_searching = s.active_window >= 0 and s.windows[@intCast(s.active_window)].app == .files and search.focused;
        const files_active = s.active_window >= 0 and s.windows[@intCast(s.active_window)].app == .files;
        const address_editing = browsing and browser.addressFocused();
        const tabbed_app = browsing;
        if (files_active and ctrl and !extended) {
            switch (code) {
                0x2e => { desktop.copyExplorerSelection(false); changed = true; continue; }, // Ctrl+C
                0x2d => { desktop.copyExplorerSelection(true); changed = true; continue; }, // Ctrl+X
                0x2f => { _ = desktop.pasteClipboardInto(s.fs_current_directory); changed = true; continue; }, // Ctrl+V
                else => {},
            }
        }
        if (tabbed_app and ctrl and !extended and code == 0x14) {
            _ = desktop.newActiveAppTab();
            changed = true;
            continue;
        }
        if (tabbed_app and ctrl and !extended and code == 0x11) {
            _ = desktop.closeActiveAppTab();
            changed = true;
            continue;
        }
        if (tabbed_app and ctrl and !extended and code == 0x0f) {
            _ = desktop.cycleActiveAppTab();
            changed = true;
            continue;
        }
        if (editing and ctrl and !extended and (code == 0x14 or code == 0x11 or code == 0x0f)) continue;
        if (s.keyboard_win_mask != 0 and !extended and code == 0x12) {
            s.keyboard_win_used = true;
            desktop.launchApp(.files);
            changed = true;
            continue;
        }
        if (!extended and code == 0x57) {
            if (s.active_window >= 0) desktop.toggleMaximize(@intCast(s.active_window));
            changed = true;
            continue;
        }
        if (alt and !extended and code == 0x3e) {
            desktop.closeActiveWindow();
            changed = true;
            continue;
        }
        if (alt and !extended and code == 0x0f) {
            s.task_switcher_open = true;
            desktop.advanceTaskSwitcher(shift);
            changed = true;
            continue;
        }
        if (s.keyboard_win_mask != 0 and !extended and code == 0x0f) {
            s.keyboard_win_used = true;
            desktop.cycleApplicationTab(shift);
            changed = true;
            continue;
        }
        if (!extended and code == 0x01) {
            if (desktop.shortcutRenameActive()) desktop.cancelShortcutRename() else if (s.start_menu_open) s.start_menu_open = false else if (terminal and s.terminal_selection != null) s.terminal_selection = null;
            changed = true;
            continue;
        }
        if (desktop.shortcutRenameActive() and s.keyboard_ctrl_mask == 0 and s.keyboard_alt_mask == 0 and !extended) {
            if (code == 0x1c) {
                desktop.commitShortcutRename();
                changed = true;
                continue;
            }
            if (code == 0x0e) {
                desktop.backspaceShortcutRename();
                changed = true;
                continue;
            }
            const is_letter = (code >= 0x10 and code <= 0x19) or (code >= 0x1e and code <= 0x26) or (code >= 0x2c and code <= 0x32);
            const ascii = keyAscii(code, if (is_letter) shift != s.keyboard_caps else shift, s.keyboard_num);
            if (ascii != 0) {
                desktop.appendShortcutRename(ascii);
                changed = true;
                continue;
            }
        }
        if (s.start_menu_open and s.keyboard_ctrl_mask == 0 and s.keyboard_alt_mask == 0 and !extended) {
            if (code == 0x1c) {
                desktop.startMenuSubmit();
                changed = true;
                continue;
            }
            if (code == 0x0e) {
                desktop.startMenuBackspace();
                changed = true;
                continue;
            }
            const is_letter = (code >= 0x10 and code <= 0x19) or (code >= 0x1e and code <= 0x26) or (code >= 0x2c and code <= 0x32);
            const ascii = keyAscii(code, if (is_letter) shift != s.keyboard_caps else shift, s.keyboard_num);
            if (ascii != 0) {
                desktop.startMenuAppend(ascii);
                changed = true;
                continue;
            }
        }
        if (!extended and code == 0x0f) {
            if (terminal) {
                var n: u8 = 0;
                while (n < 4) : (n += 1) insertTerminalChar(' ');
            } else if (shift) {
                desktop.focusPreviousWindow();
            } else {
                desktop.focusNextWindow();
            }
            changed = true;
            continue;
        }
        if (!extended and code == 0x3b) {
            desktop.launchApp(.terminal);
            s.terminal_reply = "help ls cd pwd mkdir cat touch write rm edit run demo ps irq acpi shutdown reboot sleep hibernate";
            changed = true;
            continue;
        }
        if (!extended and code == 0x3c) {
            desktop.launchApp(.files);
            changed = true;
            continue;
        }
        if (!extended and code == 0x3d) {
            desktop.launchApp(.settings);
            changed = true;
            continue;
        }
        if (!extended and code == 0x3e) {
            desktop.launchApp(.editor);
            changed = true;
            continue;
        }
        if (!extended and code == 0x41) {
            desktop.launchApp(.system);
            changed = true;
            continue;
        }
        if (browsing and !extended and code == 0x40) {
            browser.focusAddress();
            changed = true;
            continue;
        } // F6
        if (!extended and code == 0x42) {
            desktop.focusNextWindow();
            changed = true;
            continue;
        }
        if (!extended and code == 0x43) {
            desktop.minimizeActiveWindow();
            changed = true;
            continue;
        }
        if (!extended and code == 0x44) {
            desktop.toggleStartMenu();
            changed = true;
            continue;
        }
        if (browsing and ctrl and !extended and code == 0x26) {
            browser.focusAddress();
            changed = true;
            continue;
        } // Ctrl+L
        if (browsing and !extended and code == 0x3f) {
            browser.refresh();
            changed = true;
            continue;
        } // F5
        if (!extended and code == 0x3f) {
            changed = true;
            continue;
        } // F5 requests an immediate redraw.
        if (editing and ctrl and !extended and code == 0x1f) {
            if (!editor.save()) s.terminal_reply = "Save failed";
            changed = true;
            continue;
        }
        if ((terminal or editing or (browsing and address_editing)) and ctrl and !extended) {
            switch (code) {
                0x1e => { // Ctrl+A: select the current command or whole document.
                    if (terminal) {
                        s.terminal_selection = 0;
                        s.terminal_cursor = s.terminal_len;
                    } else if (editing) editor.selectAll() else browser.selectAllAddress();
                    changed = true;
                    active_window_only_update = true;
                    continue;
                },
                0x2e => { // Ctrl+C
                    if (browsing and address_editing) browser.copyAddressToClipboard() else copyActiveSelection(terminal);
                    changed = true;
                    continue;
                },
                0x2f => { // Ctrl+V
                    if (browsing and address_editing) browser.pasteAddress(s.clipboard[0..s.clipboard_len]) else pasteClipboard(terminal);
                    changed = true;
                    active_window_only_update = true;
                    continue;
                },
                0x2d => { // Ctrl+X
                    if (browsing and address_editing) browser.copyAddressToClipboard() else copyActiveSelection(terminal);
                    if (terminal) _ = deleteTerminalSelection() else if (editing) _ = editor.deleteSelection();
                    if (browsing and address_editing) browser.deleteAddressSelection();
                    changed = true;
                    active_window_only_update = true;
                    continue;
                },
                0x2c => { // Ctrl+Z, or Ctrl+Shift+Z to redo.
                    if (editing) {
                        if (shift) _ = editor.redo() else _ = editor.undo();
                        changed = true;
                        active_window_only_update = true;
                    }
                    continue;
                },
                0x15 => { // Ctrl+Y
                    if (editing) {
                        _ = editor.redo();
                        changed = true;
                        active_window_only_update = true;
                    }
                    continue;
                },
                else => {},
            }
        }
        if (editing and (ctrl or (shift and extended)) and code == 0x52) {
            if (ctrl) copyActiveSelection(false) else pasteClipboard(false);
            changed = true;
            active_window_only_update = true;
            continue;
        }
        if (browsing and address_editing and !extended and code == 0x0e) {
            browser.backspaceAddress();
            changed = true;
            active_window_only_update = true;
            continue;
        }
        if (editing and !extended and code == 0x0e) {
            editor.backspace();
            changed = true;
            active_window_only_update = true;
            continue;
        }
        if (explorer_searching and !extended and code == 0x0e) {
            search.backspace();
            changed = true;
            active_window_only_update = true;
            continue;
        }
        if (browsing and address_editing and code == 0x1c) {
            browser.navigateCurrent();
            changed = true;
            continue;
        }
        if (editing and code == 0x1c) {
            editor.insert('\n');
            changed = true;
            active_window_only_update = true;
            continue;
        }
        if (explorer_searching and !extended and code == 0x1c) {
            search.execute(s.fs_current_directory);
            changed = true;
            active_window_only_update = false;
            continue;
        }
        if (browsing and address_editing and extended and (code == 0x4b or code == 0x4d)) {
            browser.moveAddressCursor(code == 0x4d);
            changed = true;
            active_window_only_update = true;
            continue;
        }
        if (editing and extended and (code == 0x4b or code == 0x4d or code == 0x47 or code == 0x4f)) {
            var position = s.editor_cursor;
            if (code == 0x4b) position -|= 1 else if (code == 0x4d) position = @min(position + 1, s.editor_len) else if (code == 0x47) {
                while (position > 0 and s.editor_buffer[position - 1] != '\n') position -= 1;
            } else {
                while (position < s.editor_len and s.editor_buffer[position] != '\n') position += 1;
            }
            editor.moveCursor(position, shift);
            changed = true;
            active_window_only_update = true;
            continue;
        }
        if (editing and extended and code == 0x53) {
            editor.delete();
            changed = true;
            active_window_only_update = true;
            continue;
        }
        if (!extended and code == 0x0e and terminal) {
            if (s.keyboard_ctrl_mask != 0) deletePreviousWord() else backspaceTerminal();
            changed = true;
            active_window_only_update = true;
            continue;
        }
        if (code == 0x1c and terminal) {
            runTerminalCommand();
            changed = true;
            continue;
        }
        if (terminal and ctrl and code == 0x53 and (extended or !s.keyboard_num)) {
            deleteNextWord();
            changed = true;
            continue;
        }
        // Full Set-1 navigation and edit block, including keypad navigation.
        var nav = if (extended) code else if (!s.keyboard_num) code else 0;
        if (!extended and s.keyboard_num and code == 0x52) nav = 0;
        if (!extended and s.keyboard_num and code == 0x53) nav = 0;
        if (nav != 0 and terminal) {
            switch (nav) {
                0x47 => moveTerminalCursor(0, shift), // Home / keypad 7
                0x4f => moveTerminalCursor(s.terminal_len, shift), // End / keypad 1
                0x4b => moveTerminalCursor(if (ctrl) previousWordPosition() else s.terminal_cursor -| 1, shift),
                0x4d => moveTerminalCursor(if (ctrl) nextWordPosition() else @min(s.terminal_cursor + 1, s.terminal_len), shift),
                0x49 => scrollTerminal(20), // Page Up scrollback
                0x51 => scrollTerminal(-20), // Page Down scrollback
                0x48 => {
                    if (ctrl) scrollTerminal(1) else recallTerminalCommand(true);
                }, // Up / Ctrl+Up
                0x50 => {
                    if (ctrl) scrollTerminal(-1) else recallTerminalCommand(false);
                }, // Down / Ctrl+Down
                0x52 => s.terminal_insert = !s.terminal_insert, // Insert
                0x53 => deleteAtTerminalCursor(), // Delete
                else => {},
            }
            changed = true;
            active_window_only_update = true;
            continue;
        } else if (nav != 0 and !terminal) {
            if (browsing and (nav == 0x48 or nav == 0x50 or nav == 0x49 or nav == 0x51)) {
                const delta: i32 = switch (nav) {
                    0x48 => -3,
                    0x50 => 3,
                    0x49 => -20,
                    else => 20,
                };
                browser.scroll(delta);
            } else if (nav == 0x49) s.scroll_offset = @max(0, s.scroll_offset - 48) else if (nav == 0x51) s.scroll_offset = @min(72, s.scroll_offset + 48);
            changed = true;
            active_window_only_update = true;
            continue;
        }

        if (terminal and ctrl and !extended) {
            switch (code) {
                0x2d => {
                    _ = deleteTerminalSelection();
                    changed = true;
                    continue;
                }, // Ctrl+X
                0x16 => {
                    s.terminal_line = @splat(0);
                    s.terminal_len = 0;
                    s.terminal_cursor = 0;
                    s.terminal_selection = null;
                    changed = true;
                    continue;
                }, // Ctrl+U
                0x26 => {
                    s.terminal_view_offset = s.terminal_history_count;
                    changed = true;
                    active_window_only_update = true;
                    continue;
                }, // Ctrl+L clears visible scrollback; Page Up restores it.
                0x11 => {
                    deletePreviousWord();
                    changed = true;
                    continue;
                }, // Ctrl+W
                else => {},
            }
        }
        if (terminal and ctrl) continue;

        if (terminal or editing or address_editing or explorer_searching) {
            const is_letter = (code >= 0x10 and code <= 0x19) or (code >= 0x1e and code <= 0x26) or (code >= 0x2c and code <= 0x32);
            var ascii = keyAscii(code, if (is_letter) shift != s.keyboard_caps else shift, s.keyboard_num);
            if (extended and code == 0x35) ascii = '/';
            if (editing) {
                if (ascii != 0) {
                    editor.insert(ascii);
                    changed = true;
                    active_window_only_update = true;
                }
            } else if (address_editing and ascii != 0) {
                browser.insertAddressChar(ascii);
                changed = true;
                active_window_only_update = true;
            } else if (explorer_searching and ascii != 0) {
                search.append(ascii);
                changed = true;
                active_window_only_update = true;
            } else if (terminal and ascii != 0) {
                insertTerminalChar(ascii);
                changed = true;
                active_window_only_update = true;
            }
        }
    }
    return changed;
}

pub export fn aether_irq_keyboard() callconv(.c) void {
    const irq_count: *volatile u64 = &s.keyboard_irq_count;
    irq_count.* +%= 1;
    const status = io.in8(0x64);
    if ((status & 1) != 0) {
        const value = io.in8(0x60);
        if ((status & 0x20) == 0) {
            const next = s.keyboard_head +% 1;
            if (next != s.keyboard_tail) {
                s.keyboard_queue[s.keyboard_head] = value;
                s.keyboard_head = next;
            } else {
                const drops: *volatile u64 = &s.keyboard_queue_drops;
                drops.* +%= 1;
            }
        }
    }
    io.out8(0x20, 0x20);
}
