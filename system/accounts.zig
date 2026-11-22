//! Local account directories on FAT32. This first account layer is intended
//! for single-user desktop sessions; it does not claim password isolation.
const std = @import("std");
const s = @import("state.zig");
const fat32 = @import("../fs/storage.zig");
const ext2 = @import("../fs/ext2.zig");
const apfs = @import("../fs/apfs.zig");
const panic_handler = @import("panic.zig");
const ata = @import("../drivers/ata.zig");

fn equalFold(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        const l = if (left >= 'A' and left <= 'Z') left + 32 else left;
        const r = if (right >= 'A' and right <= 'Z') right + 32 else right;
        if (l != r) return false;
    }
    return true;
}

fn findDirectory(parent: u32, name: []const u8) ?u32 {
    var entries: [32]fat32.Entry = undefined;
    const count = fat32.listDirectory(parent, &entries);
    for (entries[0..count]) |entry| {
        if ((entry.attributes & 0x10) != 0 and equalFold(entry.name[0..entry.name_len], name)) return entry.first_cluster;
    }
    return null;
}

fn containsFile(directory: u32, name: []const u8) bool {
    var entries: [64]fat32.Entry = undefined;
    const count = fat32.listDirectory(directory, &entries);
    for (entries[0..count]) |entry| {
        if ((entry.attributes & 0x10) == 0 and equalFold(entry.name[0..entry.name_len], name)) return true;
    }
    return false;
}

fn writeEmbedded(directory: u32, name: []const u8, bytes: []const u8) void {
    if (containsFile(directory, name)) return;
    if (!fat32.writeFileAt(directory, name, bytes)) {
        const message = std.fmt.bufPrint(&s.fs_text_buffer, "ext2 failed {s}, stage {d}, block {d}, ATA {d}/{d} at {d}", .{ name, ext2.last_write_error, ext2.last_write_block, ata.last_write_error, ata.last_status, ata.last_write_lba }) catch "storage write failed";
        panic_handler.trace(message);
    }
}

pub fn init() bool {
    s.account_ready = false;
    if (!s.fs_mounted) return false;
    const root = fat32.rootCluster();
    var home = findDirectory(root, "home");
    if (home == null) {
        if (!fat32.makeDirectory(root, "home")) {
            if (fat32.mountedKind() == .apfs) panic_handler.trace(apfs.last_operation_error);
            return false;
        }
        home = findDirectory(root, "home");
    }
    const home_cluster = home orelse {
        if (fat32.mountedKind() == .apfs) panic_handler.trace("APFS created /home but listing could not find it");
        return false;
    };
    var user = findDirectory(home_cluster, "aether");
    if (user == null) {
        if (!fat32.makeDirectory(home_cluster, "aether")) {
            if (fat32.mountedKind() == .apfs) panic_handler.trace(apfs.last_operation_error);
            return false;
        }
        user = findDirectory(home_cluster, "aether");
    }
    const user_cluster = user orelse {
        if (fat32.mountedKind() == .apfs) panic_handler.trace("APFS created /home/aether but listing could not find it");
        return false;
    };
    var desktop = findDirectory(user_cluster, "Desktop");
    if (desktop == null) {
        if (!fat32.makeDirectory(user_cluster, "Desktop")) {
            if (fat32.mountedKind() == .apfs) panic_handler.trace(apfs.last_operation_error);
            return false;
        }
        desktop = findDirectory(user_cluster, "Desktop");
    }
    s.desktop_directory_cluster = desktop orelse {
        if (fat32.mountedKind() == .apfs) panic_handler.trace("APFS created the desktop folder but listing could not find it");
        return false;
    };
    s.desktop_directory_ready = true;
    // Install small local video samples on the first boot only. The FAT32
    // existence check preserves any files the user has already put in Home.
    writeEmbedded(user_cluster, "Sample video.mp4", @embedFile("../assets/sample.mp4"));
    writeEmbedded(user_cluster, "Sample video.mkv", @embedFile("../assets/sample.mkv"));
    writeEmbedded(user_cluster, "JPEG demo.mp4", @embedFile("../assets/sample-mjpeg.mp4"));
    writeEmbedded(user_cluster, "VP8 demo.mkv", @embedFile("../assets/sample-vp8.mkv"));
    writeEmbedded(user_cluster, "H264 demo.mp4", @embedFile("../assets/sample-h264.mp4"));
    writeEmbedded(user_cluster, "H264 demo.mkv", @embedFile("../assets/sample-h264.mkv"));
    writeEmbedded(user_cluster, "Demo tone.wav", @embedFile("../assets/demo-tone.wav"));
    @memset(&s.account_name, 0);
    @memcpy(s.account_name[0..6], "aether");
    @memset(&s.account_home, 0);
    @memcpy(s.account_home[0..12], "/home/aether");
    s.fs_current_directory = user_cluster;
    s.fs_current_path = @splat(0);
    @memcpy(s.fs_current_path[0..12], "/home/aether");
    s.fs_current_path_len = 12;
    s.account_ready = true;
    return true;
}

pub fn create(name: []const u8) bool {
    if (!s.fs_mounted or name.len == 0 or name.len > 24) return false;
    const home = findDirectory(fat32.rootCluster(), "home") orelse return false;
    if (findDirectory(home, name) != null) return false;
    return fat32.makeDirectory(home, name);
}

pub fn switchTo(name: []const u8) bool {
    if (!s.fs_mounted) return false;
    const home = findDirectory(fat32.rootCluster(), "home") orelse return false;
    const user_cluster = findDirectory(home, name) orelse return false;
    var desktop = findDirectory(user_cluster, "Desktop");
    if (desktop == null) {
        if (!fat32.makeDirectory(user_cluster, "Desktop")) return false;
        desktop = findDirectory(user_cluster, "Desktop");
    }
    s.desktop_directory_cluster = desktop orelse return false;
    s.desktop_directory_ready = true;
    if (name.len == 0 or name.len > s.account_name.len or name.len + 6 > s.account_home.len) return false;
    @memset(&s.account_name, 0);
    @memcpy(s.account_name[0..name.len], name);
    @memset(&s.account_home, 0);
    @memcpy(s.account_home[0..6], "/home/");
    @memcpy(s.account_home[6 .. 6 + name.len], name);
    s.fs_current_directory = user_cluster;
    s.fs_current_path = @splat(0);
    @memcpy(s.fs_current_path[0 .. 6 + name.len], s.account_home[0 .. 6 + name.len]);
    s.fs_current_path_len = 6 + name.len;
    s.fs_entry_count = fat32.listDirectory(user_cluster, &s.fs_entries);
    return true;
}
