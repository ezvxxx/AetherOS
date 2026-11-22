//! Bounded classic ZIP32 creation, preview and extraction for storage.
const std = @import("std");
const fat32 = @import("../fs/storage.zig");
const heap = @import("../memory/heap.zig");

pub const Mode = enum { preview, reader, create };
pub const max_archive_size = 8 * 1024 * 1024;
pub const max_items = 32;

pub const ZipEntry = struct {
    path: [256]u8 = @splat(0),
    path_len: u16 = 0,
    size: u32 = 0,
    compressed_size: u32 = 0,
    crc: u32 = 0,
    local_offset: u32 = 0,
    method: u16 = 0,
    flags: u16 = 0,
};

pub var mode: Mode = .preview;
pub var directory_cluster: u32 = 0;
pub var files: [max_items]fat32.Entry = @splat(.{});
pub var file_count: usize = 0;
pub var selected_files: [max_items]bool = @splat(false);
pub var zip_entries: [max_items]ZipEntry = @splat(.{});
pub var zip_count: usize = 0;
pub var selected_zip_entry: ?usize = null;
pub var opened_zip: [64]u8 = @splat(0);
pub var opened_zip_len: usize = 0;
pub var status: []const u8 = "Choose Preview, Reader or Create";

fn get16(bytes: []const u8, at: usize) u16 {
    return @as(u16, bytes[at]) | (@as(u16, bytes[at + 1]) << 8);
}
fn get32(bytes: []const u8, at: usize) u32 {
    return @as(u32, bytes[at]) | (@as(u32, bytes[at + 1]) << 8) | (@as(u32, bytes[at + 2]) << 16) | (@as(u32, bytes[at + 3]) << 24);
}
fn put16(bytes: []u8, at: usize, value: u16) void {
    bytes[at] = @truncate(value);
    bytes[at + 1] = @truncate(value >> 8);
}
fn put32(bytes: []u8, at: usize, value: u32) void {
    bytes[at] = @truncate(value);
    bytes[at + 1] = @truncate(value >> 8);
    bytes[at + 2] = @truncate(value >> 16);
    bytes[at + 3] = @truncate(value >> 24);
}
fn rangeOk(total: usize, offset: usize, length: usize) bool {
    return offset <= total and length <= total - offset;
}
pub fn isZipName(name: []const u8) bool {
    return name.len >= 4 and std.ascii.eqlIgnoreCase(name[name.len - 4 ..], ".zip");
}

pub fn start(directory: u32) void {
    directory_cluster = directory;
    mode = .preview;
    closeArchive();
    refresh();
}

pub fn setMode(new_mode: Mode) void {
    mode = new_mode;
    selected_files = @splat(false);
    selected_zip_entry = null;
    if (mode == .create) status = "Select files, then choose Create ZIP" else if (mode == .preview) status = "Select a ZIP archive to preview" else status = "Select a ZIP archive to read and extract";
}

pub fn refresh() void {
    file_count = fat32.listDirectory(directory_cluster, &files);
    selected_files = @splat(false);
}

pub fn changeDirectory(name: []const u8) bool {
    const next = fat32.changeDirectory(directory_cluster, name) orelse return false;
    directory_cluster = next;
    closeArchive();
    refresh();
    return true;
}

pub fn closeArchive() void {
    zip_count = 0;
    selected_zip_entry = null;
    opened_zip = @splat(0);
    opened_zip_len = 0;
}

fn readArchive(name: []const u8, out: []u8) ?usize {
    const got = fat32.readFileAt(directory_cluster, name, out) orelse return null;
    if (got < 22 or got > max_archive_size) return null;
    return got;
}

pub fn openArchive(name: []const u8) bool {
    if (!isZipName(name) or name.len > opened_zip.len) {
        status = "Choose a .zip file";
        return false;
    }
    const mark = heap.mark();
    defer heap.rewind(mark);
    const raw = heap.allocate(max_archive_size, 16) orelse {
        status = "Not enough memory to open this ZIP";
        return false;
    };
    const bytes = raw[0..max_archive_size];
    const len = readArchive(name, bytes) orelse {
        status = "ZIP is damaged or larger than 8 MiB";
        return false;
    };

    const search_start = len -| 65_557;
    var eocd: ?usize = null;
    var pos = len - 22;
    while (true) : (pos -= 1) {
        if (get32(bytes, pos) == 0x06054b50) {
            eocd = pos;
            break;
        }
        if (pos == search_start) break;
    }
    const end_record = eocd orelse {
        status = "ZIP end directory was not found";
        return false;
    };
    if (!rangeOk(len, end_record, 22)) return false;
    const disk = get16(bytes, end_record + 4);
    const central_disk = get16(bytes, end_record + 6);
    const disk_count = get16(bytes, end_record + 8);
    const total_count = get16(bytes, end_record + 10);
    const central_size: usize = get32(bytes, end_record + 12);
    const central_offset: usize = get32(bytes, end_record + 16);
    const comment_len: usize = get16(bytes, end_record + 20);
    if (disk != 0 or central_disk != 0 or disk_count != total_count or total_count == 0xffff or
        !rangeOk(len, end_record + 22, comment_len) or !rangeOk(len, central_offset, central_size) or total_count > zip_entries.len)
    {
        status = "Multi-disk, ZIP64 or oversized directory is unsupported";
        return false;
    }

    zip_entries = @splat(.{});
    var count: usize = 0;
    var cursor = central_offset;
    while (count < total_count) : (count += 1) {
        if (!rangeOk(len, cursor, 46) or get32(bytes, cursor) != 0x02014b50) {
            status = "Invalid ZIP central directory";
            return false;
        }
        const flags = get16(bytes, cursor + 8);
        const method = get16(bytes, cursor + 10);
        const compressed = get32(bytes, cursor + 20);
        const uncompressed = get32(bytes, cursor + 24);
        const name_len: usize = get16(bytes, cursor + 28);
        const extra_len: usize = get16(bytes, cursor + 30);
        const note_len: usize = get16(bytes, cursor + 32);
        const local_offset = get32(bytes, cursor + 42);
        const variable_len = name_len + extra_len + note_len;
        if (!rangeOk(len, cursor + 46, variable_len) or name_len == 0 or name_len > 255) {
            status = "Invalid ZIP entry bounds";
            return false;
        }
        const path = bytes[cursor + 46 ..][0..name_len];
        const is_directory = path[path.len - 1] == '/' or path[path.len - 1] == '\\';
        if (!is_directory and count < zip_entries.len) {
            var entry: ZipEntry = .{};
            @memcpy(entry.path[0..name_len], path);
            entry.path_len = @intCast(name_len);
            entry.size = uncompressed;
            entry.compressed_size = compressed;
            entry.crc = get32(bytes, cursor + 16);
            entry.local_offset = local_offset;
            entry.method = method;
            entry.flags = flags;
            zip_entries[count] = entry;
        }
        cursor += 46 + variable_len;
        if (cursor > central_offset + central_size) {
            status = "ZIP directory length is inconsistent";
            return false;
        }
    }
    // Compact out directory records: `count` tracks central records while
    // zip_count tracks only selectable files.
    var compact_count: usize = 0;
    for (0..@min(count, zip_entries.len)) |i| {
        if (zip_entries[i].path_len == 0) continue;
        if (compact_count != i) zip_entries[compact_count] = zip_entries[i];
        compact_count += 1;
    }
    zip_count = compact_count;
    opened_zip = @splat(0);
    @memcpy(opened_zip[0..name.len], name);
    opened_zip_len = name.len;
    selected_zip_entry = if (zip_count == 0) null else 0;
    status = if (zip_count == 0) "Archive is empty" else "Archive preview ready";
    return true;
}

fn safeBaseName(entry: ZipEntry, out: *[64]u8) ?usize {
    const path = entry.path[0..entry.path_len];
    var basename_start: usize = 0;
    for (path, 0..) |ch, i| if (ch == '/' or ch == '\\') { basename_start = i + 1; };
    const base = path[basename_start..];
    if (base.len == 0 or base.len > out.len or std.mem.eql(u8, base, ".") or std.mem.eql(u8, base, "..")) return null;
    for (base) |ch| if (ch < 0x20 or ch == ':' or ch == '*' or ch == '?' or ch == '"' or ch == '<' or ch == '>' or ch == '|') return null;
    @memcpy(out[0..base.len], base);
    return base.len;
}

fn uniqueOutputName(directory: u32, base: []const u8, out: *[64]u8) ?usize {
    var entries: [64]fat32.Entry = undefined;
    const count = fat32.listDirectory(directory, &entries);
    const dot = std.mem.lastIndexOfScalar(u8, base, '.');
    const stem = if (dot) |i| base[0..i] else base;
    const extension = if (dot) |i| base[i..] else "";
    var suffix: usize = 0;
    while (suffix < 1000) : (suffix += 1) {
        var candidate: [64]u8 = @splat(0);
        var used: usize = 0;
        const tail = if (suffix == 0) "" else blk: {
            var number: [8]u8 = undefined;
            const text = std.fmt.bufPrint(&number, "-{d}", .{suffix}) catch return null;
            break :blk text;
        };
        if (stem.len + tail.len + extension.len > candidate.len) return null;
        @memcpy(candidate[0..stem.len], stem);
        used += stem.len;
        @memcpy(candidate[used..][0..tail.len], tail);
        used += tail.len;
        @memcpy(candidate[used..][0..extension.len], extension);
        used += extension.len;
        var exists = false;
        for (entries[0..count]) |old| {
            if (old.name_len == used and std.ascii.eqlIgnoreCase(old.name[0..old.name_len], candidate[0..used])) {
                exists = true;
                break;
            }
        }
        if (!exists) {
            @memcpy(out[0..used], candidate[0..used]);
            return used;
        }
    }
    return null;
}

pub fn extractSelected() bool {
    const index = selected_zip_entry orelse {
        status = "Select a file in the archive first";
        return false;
    };
    if (index >= zip_count) return false;
    const entry = zip_entries[index];
    if ((entry.flags & 1) != 0 or entry.size > max_archive_size or entry.compressed_size > max_archive_size) {
        status = "Encrypted or oversized ZIP entry is unsupported";
        return false;
    }
    const mark = heap.mark();
    defer heap.rewind(mark);
    const raw = heap.allocate(max_archive_size, 16) orelse return fail("Not enough memory to extract");
    const archive = raw[0..max_archive_size];
    const archive_len = readArchive(opened_zip[0..opened_zip_len], archive) orelse return fail("Could not read ZIP file");
    const local: usize = entry.local_offset;
    if (!rangeOk(archive_len, local, 30) or get32(archive, local) != 0x04034b50) return fail("Invalid ZIP local header");
    const local_name_len: usize = get16(archive, local + 26);
    const local_extra_len: usize = get16(archive, local + 28);
    const payload = local + 30 + local_name_len + local_extra_len;
    const compressed_size: usize = @intCast(entry.compressed_size);
    if (!rangeOk(archive_len, payload, compressed_size)) return fail("ZIP payload is out of bounds");
    const entry_size: usize = @intCast(entry.size);
    const output_mem = heap.allocate(@max(entry_size, 1), 16) orelse return fail("Not enough memory for file");
    const output = output_mem[0..entry_size];
    const compressed = archive[payload..][0..compressed_size];
    if (entry.method == 0) {
        if (entry.compressed_size != entry.size) return fail("Stored ZIP entry size mismatch");
        @memcpy(output, compressed);
    } else if (entry.method == 8) {
        var input: std.Io.Reader = .fixed(compressed);
        var window: [std.compress.flate.max_window_len]u8 = undefined;
        var decoder: std.compress.flate.Decompress = .init(&input, .raw, &window);
        decoder.reader.readSliceAll(output) catch return fail("Invalid DEFLATE data");
        var extra: [1]u8 = undefined;
        const extra_count = decoder.reader.readSliceShort(&extra) catch 0;
        if (extra_count != 0) return fail("DEFLATE output exceeded declared size");
    } else return fail("ZIP method unsupported (use Store or Deflate)");

    if (std.hash.Crc32.hash(output) != entry.crc) return fail("ZIP CRC check failed");
    var base: [64]u8 = undefined;
    const base_len = safeBaseName(entry, &base) orelse return fail("Unsafe or unsupported filename in ZIP");
    var output_name: [64]u8 = undefined;
    const output_name_len = uniqueOutputName(directory_cluster, base[0..base_len], &output_name) orelse return fail("Could not choose output filename");
    if (!fat32.writeFileAt(directory_cluster, output_name[0..output_name_len], output)) return fail("Storage could not write extracted file");
    refresh();
    status = "File extracted successfully";
    return true;
}

fn fail(message: []const u8) bool {
    status = message;
    return false;
}

const CentralRecord = struct { name: [255]u8, name_len: usize, crc: u32, size: u32, compressed_size: u32, method: u16, offset: u32 };

fn deflateRaw(input: []const u8, output: []u8, compressor: *std.compress.flate.Compress, window: []u8) ?usize {
    var writer: std.Io.Writer = .fixed(output);
    compressor.* = std.compress.flate.Compress.init(&writer, window, .raw, .default) catch return null;
    compressor.writer.writeAll(input) catch return null;
    compressor.finish() catch return null;
    return writer.end;
}

pub fn createSelected() bool {
    var selected_count: usize = 0;
    for (files[0..file_count], 0..) |entry, i| {
        if (selected_files[i] and (entry.attributes & 0x10) == 0) selected_count += 1;
    }
    if (selected_count == 0) return fail("Select one or more files first");

    const mark = heap.mark();
    defer heap.rewind(mark);
    const archive_mem = heap.allocate(max_archive_size, 16) orelse return fail("Not enough memory to create ZIP");
    const file_mem = heap.allocate(max_archive_size, 16) orelse return fail("Not enough memory to pack files");
    const compressed_mem = heap.allocate(max_archive_size, 16) orelse return fail("Not enough memory for compression buffer");
    const window_mem = heap.allocate(std.compress.flate.max_window_len, 16) orelse return fail("Not enough memory for DEFLATE window");
    const compressor_mem = heap.allocate(@sizeOf(std.compress.flate.Compress), @alignOf(std.compress.flate.Compress)) orelse return fail("Not enough memory for compressor");
    const archive = archive_mem[0..max_archive_size];
    const file_buffer = file_mem[0..max_archive_size];
    const compressed_buffer = compressed_mem[0..max_archive_size];
    const window = window_mem[0..std.compress.flate.max_window_len];
    const compressor: *std.compress.flate.Compress = @ptrCast(@alignCast(compressor_mem));
    var used: usize = 0;
    var records: [max_items]CentralRecord = undefined;
    var record_count: usize = 0;

    for (files[0..file_count], 0..) |entry, i| {
        if (!selected_files[i] or (entry.attributes & 0x10) != 0) continue;
        const name = entry.name[0..entry.name_len];
        if (entry.size > max_archive_size or record_count >= records.len) return fail("Selected file exceeds ZIP limit");
        const entry_size: usize = @intCast(entry.size);
        const read_len = fat32.readFileAt(directory_cluster, name, file_buffer[0..entry_size]) orelse return fail("Could not read selected file");
        if (read_len != entry.size) return fail("Selected file read was incomplete");
        const compressed_len = deflateRaw(file_buffer[0..read_len], compressed_buffer, compressor, window);
        const use_deflate = if (compressed_len) |length| length < read_len else false;
        const payload = if (use_deflate) compressed_buffer[0..compressed_len.?] else file_buffer[0..read_len];
        const method: u16 = if (use_deflate) 8 else 0;
        const name_len = name.len;
        const local_offset: u32 = @intCast(used);
        if (!rangeOk(archive.len, used, 30 + name_len + payload.len)) return fail("Created ZIP would exceed 8 MiB");
        put32(archive, used, 0x04034b50);
        put16(archive, used + 4, 20);
        put16(archive, used + 6, 0);
        put16(archive, used + 8, method);
        put16(archive, used + 10, 0);
        put16(archive, used + 12, 0);
        const crc = std.hash.Crc32.hash(file_buffer[0..read_len]);
        put32(archive, used + 14, crc);
        put32(archive, used + 18, @intCast(payload.len));
        put32(archive, used + 22, @intCast(read_len));
        put16(archive, used + 26, @intCast(name_len));
        put16(archive, used + 28, 0);
        @memcpy(archive[used + 30 ..][0..name_len], name);
        @memcpy(archive[used + 30 + name_len ..][0..payload.len], payload);
        records[record_count] = .{ .name = entry.name, .name_len = name_len, .crc = crc, .size = @intCast(read_len), .compressed_size = @intCast(payload.len), .method = method, .offset = local_offset };
        record_count += 1;
        used += 30 + name_len + payload.len;
    }

    const central_offset: u32 = @intCast(used);
    for (records[0..record_count]) |record| {
        if (!rangeOk(archive.len, used, 46 + record.name_len)) return fail("ZIP directory exceeds 8 MiB limit");
        put32(archive, used, 0x02014b50);
        put16(archive, used + 4, 20);
        put16(archive, used + 6, 20);
        put16(archive, used + 8, 0);
        put16(archive, used + 10, record.method);
        put16(archive, used + 12, 0);
        put16(archive, used + 14, 0);
        put32(archive, used + 16, record.crc);
        put32(archive, used + 20, record.compressed_size);
        put32(archive, used + 24, record.size);
        put16(archive, used + 28, @intCast(record.name_len));
        put16(archive, used + 30, 0);
        put16(archive, used + 32, 0);
        put16(archive, used + 34, 0);
        put16(archive, used + 36, 0);
        put32(archive, used + 38, 0);
        put32(archive, used + 42, record.offset);
        @memcpy(archive[used + 46 ..][0..record.name_len], record.name[0..record.name_len]);
        used += 46 + record.name_len;
    }
    const central_size: u32 = @intCast(used - central_offset);
    if (!rangeOk(archive.len, used, 22)) return fail("ZIP footer exceeds 8 MiB limit");
    put32(archive, used, 0x06054b50);
    put16(archive, used + 4, 0);
    put16(archive, used + 6, 0);
    put16(archive, used + 8, @intCast(record_count));
    put16(archive, used + 10, @intCast(record_count));
    put32(archive, used + 12, central_size);
    put32(archive, used + 16, central_offset);
    put16(archive, used + 20, 0);
    used += 22;

    var archive_name: [64]u8 = undefined;
    const name_len = uniqueOutputName(directory_cluster, "Archive.zip", &archive_name) orelse return fail("Could not choose archive name");
    if (!fat32.writeFileAt(directory_cluster, archive_name[0..name_len], archive[0..used])) return fail("Storage could not save ZIP archive");
    selected_files = @splat(false);
    _ = openArchive(archive_name[0..name_len]);
    status = "ZIP created with Deflate compression when smaller";
    return true;
}
