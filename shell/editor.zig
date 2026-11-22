//! Small in-kernel text editor backed by the native FAT32 driver.
const s = @import("../system/state.zig");
const fat32 = @import("../fs/storage.zig");

const history_capacity = 16;
const Snapshot = struct {
    buffer: [2048]u8 = @splat(0),
    len: usize = 0,
    cursor: usize = 0,
    selection: ?usize = null,
    dirty: bool = false,
    directory: u32 = 0,
    filename: [255]u8 = @splat(0),
    filename_len: usize = 0,
};
const History = struct {
    items: [history_capacity]Snapshot = undefined,
    count: usize = 0,
};
var undo_history: History = .{};
var redo_history: History = .{};

fn snapshot() Snapshot {
    return .{ .buffer = s.editor_buffer, .len = s.editor_len, .cursor = s.editor_cursor, .selection = s.editor_selection, .dirty = s.editor_dirty, .directory = s.editor_directory, .filename = s.editor_filename, .filename_len = s.editor_filename_len };
}

fn push(history: *History, value: Snapshot) void {
    if (history.count == history.items.len) {
        for (0..history.items.len - 1) |i| history.items[i] = history.items[i + 1];
        history.count -= 1;
    }
    history.items[history.count] = value;
    history.count += 1;
}

fn beginEdit() void {
    push(&undo_history, snapshot());
    redo_history.count = 0;
}

fn restore(value: Snapshot) void {
    s.editor_buffer = value.buffer;
    s.editor_len = value.len;
    s.editor_cursor = value.cursor;
    s.editor_selection = value.selection;
    s.editor_dirty = value.dirty;
    s.editor_directory = value.directory;
    s.editor_filename = value.filename;
    s.editor_filename_len = value.filename_len;
}

pub fn clearHistory() void {
    undo_history.count = 0;
    redo_history.count = 0;
}

pub fn undo() bool {
    if (undo_history.count == 0) return false;
    push(&redo_history, snapshot());
    undo_history.count -= 1;
    restore(undo_history.items[undo_history.count]);
    return true;
}

pub fn redo() bool {
    if (redo_history.count == 0) return false;
    push(&undo_history, snapshot());
    redo_history.count -= 1;
    restore(redo_history.items[redo_history.count]);
    return true;
}

pub fn selectedRange() ?struct { first: usize, last: usize } {
    const anchor = s.editor_selection orelse return null;
    return .{ .first = @min(anchor, s.editor_cursor), .last = @max(anchor, s.editor_cursor) };
}

fn removeRange(first: usize, last: usize) void {
    if (first >= last) return;
    const removed = last - first;
    var i = last;
    while (i < s.editor_len) : (i += 1) s.editor_buffer[i - removed] = s.editor_buffer[i];
    s.editor_len -= removed;
    @memset(s.editor_buffer[s.editor_len..][0..removed], 0);
    s.editor_cursor = first;
    s.editor_selection = null;
}

pub fn deleteSelection() bool {
    const range = selectedRange() orelse return false;
    if (range.first == range.last) {
        s.editor_selection = null;
        return false;
    }
    beginEdit();
    removeRange(range.first, range.last);
    s.editor_dirty = true;
    return true;
}

pub fn selectAll() void {
    s.editor_selection = 0;
    s.editor_cursor = s.editor_len;
}

pub fn moveCursor(position: usize, extend: bool) void {
    if (extend) {
        if (s.editor_selection == null) s.editor_selection = s.editor_cursor;
    } else {
        s.editor_selection = null;
    }
    s.editor_cursor = @min(position, s.editor_len);
}

pub fn open(name: []const u8) bool {
    if (name.len == 0 or name.len > s.editor_filename.len) return false;
    s.editor_buffer = @splat(0);
    s.editor_len = 0;
    s.editor_cursor = 0;
    s.editor_selection = null;
    clearHistory();
    s.editor_filename = @splat(0);
    @memcpy(s.editor_filename[0..name.len], name);
    s.editor_filename_len = name.len;
    s.editor_directory = s.fs_current_directory;
    s.editor_dirty = false;
    if (fat32.readFileAt(s.editor_directory, name, &s.editor_buffer)) |length| {
        s.editor_len = length;
        s.editor_cursor = length;
    }
    return true;
}

pub fn save() bool {
    if (!s.fs_mounted or s.editor_filename_len == 0) return false;
    if (!fat32.writeFileAt(s.editor_directory, s.editor_filename[0..s.editor_filename_len], s.editor_buffer[0..s.editor_len])) return false;
    s.editor_dirty = false;
    return true;
}

pub fn insert(ch: u8) void {
    const selection = selectedRange();
    if (s.editor_len >= s.editor_buffer.len and (selection == null or selection.?.first == selection.?.last)) return;
    beginEdit();
    if (selection) |range| removeRange(range.first, range.last);
    var i = s.editor_len;
    while (i > s.editor_cursor) : (i -= 1) s.editor_buffer[i] = s.editor_buffer[i - 1];
    s.editor_buffer[s.editor_cursor] = ch;
    s.editor_cursor += 1;
    s.editor_len += 1;
    s.editor_dirty = true;
}

pub fn backspace() void {
    if (deleteSelection()) return;
    if (s.editor_cursor == 0) return;
    beginEdit();
    s.editor_cursor -= 1;
    removeRange(s.editor_cursor, s.editor_cursor + 1);
    s.editor_dirty = true;
}

pub fn delete() void {
    if (deleteSelection()) return;
    if (s.editor_cursor >= s.editor_len) return;
    beginEdit();
    removeRange(s.editor_cursor, s.editor_cursor + 1);
    s.editor_dirty = true;
}
