//! Bounded recursive filesystem filename search.
const std = @import("std");
const fat32 = @import("../fs/storage.zig");

pub const max_query = 64;
pub const max_results = 48;
const max_directories = 128;

pub const Result = struct {
    entry: fat32.Entry = .{},
    parent_cluster: u32 = 0,
    parent_name: [255]u8 = @splat(0),
    parent_name_len: u8 = 0,
};

const Directory = struct {
    cluster: u32,
    label: [255]u8 = @splat(0),
    label_len: u8 = 0,
};

pub var query: [max_query]u8 = @splat(0);
pub var query_len: usize = 0;
pub var results: [max_results]Result = @splat(.{});
pub var result_count: usize = 0;
pub var status: []const u8 = "Type a filename, then press Enter";
pub var focused = false;
pub var has_searched = false;

pub fn reset() void {
    query = @splat(0);
    query_len = 0;
    result_count = 0;
    status = "Type a filename, then press Enter";
    focused = false;
    has_searched = false;
}

pub fn append(ch: u8) void {
    if (ch < 0x20 or query_len == query.len) return;
    query[query_len] = ch;
    query_len += 1;
    result_count = 0;
    has_searched = false;
    status = "Press Enter to search the disk";
}

pub fn backspace() void {
    if (query_len == 0) return;
    query_len -= 1;
    query[query_len] = 0;
    result_count = 0;
    has_searched = false;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

fn isDotName(name: []const u8) bool {
    return std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..");
}

pub fn execute(start_directory: u32) void {
    result_count = 0;
    has_searched = true;
    if (!fat32.isMounted()) {
        status = "No disk is mounted";
        return;
    }
    if (query_len == 0) {
        status = "Enter part of a filename first";
        return;
    }

    var queue: [max_directories]Directory = @splat(.{ .cluster = 0 });
    var visited: [max_directories]u32 = undefined;
    var queued: usize = 1;
    var head: usize = 0;
    var seen: usize = 0;
    queue[0].cluster = start_directory;
    const root_label = "Current folder";
    @memcpy(queue[0].label[0..root_label.len], root_label);
    queue[0].label_len = @intCast(root_label.len);
    var truncated = false;
    while (head < queued and result_count < results.len) : (head += 1) {
        const directory = queue[head];
        var already_seen = false;
        for (visited[0..seen]) |cluster| if (cluster == directory.cluster) {
            already_seen = true;
            break;
        };
        if (already_seen) continue;
        visited[seen] = directory.cluster;
        seen += 1;

        var entries: [64]fat32.Entry = undefined;
        const count = fat32.listDirectory(directory.cluster, &entries);
        for (entries[0..count]) |entry| {
            const name = entry.name[0..entry.name_len];
            if (isDotName(name) or (entry.attributes & 0x08) != 0) continue;
            if ((entry.attributes & 0x10) != 0) {
                if (entry.first_cluster >= 2) {
                    if (queued < queue.len) {
                        queue[queued] = .{ .cluster = entry.first_cluster, .label = entry.name, .label_len = entry.name_len };
                        queued += 1;
                    } else truncated = true;
                }
                continue;
            }
            if (!containsIgnoreCase(name, query[0..query_len])) continue;
            results[result_count] = .{ .entry = entry, .parent_cluster = directory.cluster, .parent_name = directory.label, .parent_name_len = directory.label_len };
            result_count += 1;
            if (result_count == results.len) break;
        }
    }
    if (result_count == results.len or truncated)
        status = "Search limited to 48 results and 128 folders"
    else if (result_count == 0)
        status = "No matching filenames found"
    else
        status = "Search complete";
}
