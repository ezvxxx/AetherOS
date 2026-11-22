//! Lightweight media browser and audio player.
const std = @import("std");
const s = @import("../system/state.zig");
const fat32 = @import("../fs/storage.zig");
const audio = @import("../drivers/audio.zig");
const video = @import("video.zig");

pub var home_cluster: u32 = 0;
pub var entries: [32]fat32.Entry = @splat(.{});
pub var count: usize = 0;
pub var selected: usize = 0;
pub var status: []const u8 = "Choose an audio or video file";

fn eq(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

pub fn isMediaName(name: []const u8) bool {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return false;
    const ext = name[dot..];
    return eq(ext, ".wav") or eq(ext, ".mp3") or eq(ext, ".mp4") or eq(ext, ".mkv");
}

pub fn refresh() void {
    count = 0;
    if (!s.fs_mounted) {
        status = "No data disk is mounted";
        return;
    }
    const root = fat32.rootCluster();
    const home = fat32.changeDirectory(root, "home") orelse {
        status = "Home directory is unavailable";
        return;
    };
    const user_name = s.account_name[0..std.mem.indexOfScalar(u8, &s.account_name, 0).?];
    home_cluster = fat32.changeDirectory(home, user_name) orelse {
        status = "User home directory is unavailable";
        return;
    };
    var all: [64]fat32.Entry = undefined;
    const all_count = fat32.listDirectory(home_cluster, &all);
    for (all[0..all_count]) |entry| {
        if ((entry.attributes & 0x10) == 0 and isMediaName(entry.name[0..entry.name_len])) {
            if (count < entries.len) {
                entries[count] = entry;
                count += 1;
            }
        }
    }
    if (selected >= count) selected = if (count == 0) 0 else count - 1;
    status = if (count == 0) "No media files in /home/aether" else "H.264 Baseline I/P, MJPEG MP4, VP8 MKV; WAV/MP3 audio";
}

pub fn openFile(directory: u32, name: []const u8) void {
    count = 0;
    var all: [64]fat32.Entry = undefined;
    const n = fat32.listDirectory(directory, &all);
    for (all[0..n]) |entry| {
        if (entry.name_len == name.len and std.ascii.eqlIgnoreCase(entry.name[0..entry.name_len], name) and isMediaName(name)) {
            home_cluster = directory;
            entries[0] = entry;
            count = 1;
            selected = 0;
            status = "File selected";
            return;
        }
    }
    refresh();
}

pub fn selectAt(y: u64, win_y: u64, win_h: u64) void {
    if (y < win_y + 46 or y >= win_y + win_h -| 36) return;
    const row: usize = @intCast((y - win_y - 46) / 22);
    if (row < count) {
        selected = row;
        status = "Ready";
    }
}

pub fn play() void {
    if (count == 0 or selected >= count or home_cluster == 0) {
        status = "Select a media file first";
        return;
    }
    const entry = entries[selected];
    const name = entry.name[0..entry.name_len];
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse {
        status = "Unknown media type";
        return;
    };
    const ext = name[dot..];
    if (eq(ext, ".wav")) {
        status = "Playing WAV";
        status = if (audio.playWav(home_cluster, name)) "WAV playback finished" else "WAV playback failed; requires 16-bit PCM and AC'97";
    } else if (eq(ext, ".mp3")) {
        status = "Playing MP3";
        status = if (audio.playMp3(home_cluster, name)) "MP3 playback finished" else "MP3 playback failed; check audio hardware or file";
    } else {
        _ = video.play(home_cluster, name);
        status = video.status;
    }
}

pub fn stopVideo() void {
    video.stop();
    status = video.status;
}

pub fn update() bool {
    const changed = video.updateFor(11);
    if (changed) status = video.status;
    return changed;
}

pub fn drawVideo(x: u64, y: u64, width: u64, height: u64) void {
    video.draw(x, y, width, height);
}

pub fn selectedName() []const u8 {
    if (count == 0 or selected >= count) return "No selection";
    return entries[selected].name[0..entries[selected].name_len];
}
