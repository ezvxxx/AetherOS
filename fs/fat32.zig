//! Native FAT32 directory, short-name, and LFN operations over ATA sectors.
//! This is a filesystem implementation without a VFS layer.

const std = @import("std");
const ata = @import("../drivers/ata.zig");

pub const Entry = @import("ext2.zig").Entry;

const Volume = struct {
    mounted: bool = false,
    device: u8 = 0,
    start_lba: u32 = 0,
    total_sectors: u32 = 0,
    sectors_per_cluster: u8 = 0,
    reserved_sectors: u16 = 0,
    fat_count: u8 = 0,
    fat_sectors: u32 = 0,
    root_cluster: u32 = 2,
    first_data_sector: u32 = 0,
    cluster_count: u32 = 0,
    ext_flags: u16 = 0,
    next_free_hint: u32 = 2,
};

var volume = Volume{};

fn get16(data: []const u8, offset: usize) u16 {
    return @as(u16, data[offset]) | (@as(u16, data[offset + 1]) << 8);
}

fn get32(data: []const u8, offset: usize) u32 {
    return @as(u32, data[offset]) |
        (@as(u32, data[offset + 1]) << 8) |
        (@as(u32, data[offset + 2]) << 16) |
        (@as(u32, data[offset + 3]) << 24);
}

fn set16(data: []u8, offset: usize, value: u16) void {
    data[offset] = @truncate(value);
    data[offset + 1] = @truncate(value >> 8);
}

fn set32(data: []u8, offset: usize, value: u32) void {
    data[offset] = @truncate(value);
    data[offset + 1] = @truncate(value >> 8);
    data[offset + 2] = @truncate(value >> 16);
    data[offset + 3] = @truncate(value >> 24);
}

pub fn isMounted() bool {
    return volume.mounted;
}

pub fn mount() bool {
    volume = .{};
    for (0..3) |dev| {
        if (mountDeviceInternal(@intCast(dev))) return true;
    }
    volume = .{};
    return false;
}

/// Mount a specific block-device index: IDE 0/1 or xHCI USB storage 2.
pub fn mountDevice(device: u8) bool {
    volume = .{};
    if (device > 2 or !mountDeviceInternal(device)) {
        volume = .{};
        return false;
    }
    return true;
}

fn mountDeviceInternal(device: u8) bool {
    var sector: [512]u8 = undefined;
    if (!ata.readSector(device, 0, &sector)) return false;
    if (tryMount(device, 0, 0, &sector)) return true;
    if (sector[510] != 0x55 or sector[511] != 0xaa) return false;
    for (0..4) |part| {
        const offset = 446 + part * 16;
        const kind = sector[offset + 4];
        if (kind != 0x0b and kind != 0x0c and kind != 0x1b and kind != 0x1c) continue;
        const start = get32(&sector, offset + 8);
        const count = get32(&sector, offset + 12);
        if (start == 0 or count == 0) continue;
        if (!ata.readSector(device, start, &sector)) continue;
        if (tryMount(device, start, count, &sector)) return true;
    }
    return false;
}

fn tryMount(device: u8, start: u32, partition_sectors: u32, boot: *const [512]u8) bool {
    if (boot[510] != 0x55 or boot[511] != 0xaa or get16(boot, 11) != 512) return false;
    const spc = boot[13];
    const reserved = get16(boot, 14);
    const fats = boot[16];
    const total16 = get16(boot, 19);
    const total32 = get32(boot, 32);
    const fat_sectors = get32(boot, 36);
    const ext_flags = get16(boot, 40);
    const root = get32(boot, 44) & 0x0fffffff;
    const total = if (total16 != 0) @as(u32, total16) else total32;
    if (spc == 0 or spc > 128 or (spc & (spc - 1)) != 0) return false;
    if (reserved == 0 or fats == 0 or fats > 2 or fat_sectors == 0 or total == 0) return false;
    if (partition_sectors != 0 and total > partition_sectors) return false;
    const first_data_offset = @as(u32, reserved) + @as(u32, fats) * fat_sectors;
    if (first_data_offset >= total or root < 2) return false;
    const clusters = (total - first_data_offset) / spc;
    // Require a standards-sized FAT32 data region; reject FAT12/16 volumes.
    if (clusters < 65_525 or clusters > 0x0fffffed or root >= clusters + 2) return false;

    volume = .{
        .mounted = true,
        .device = device,
        .start_lba = start,
        .total_sectors = total,
        .sectors_per_cluster = spc,
        .reserved_sectors = reserved,
        .fat_count = fats,
        .fat_sectors = fat_sectors,
        .root_cluster = root,
        .first_data_sector = start + first_data_offset,
        .cluster_count = clusters,
        .ext_flags = ext_flags,
        .next_free_hint = 2,
    };
    return true;
}

fn activeFatStart() u32 {
    const active: u32 = if ((volume.ext_flags & 0x0080) != 0) volume.ext_flags & 0x000f else 0;
    return volume.start_lba + @as(u32, volume.reserved_sectors) + active * volume.fat_sectors;
}

fn fatEntry(cluster: u32) ?u32 {
    if (!volume.mounted or cluster >= volume.cluster_count + 2) return null;
    const sector_lba = activeFatStart() + (cluster * 4) / 512;
    var sector: [512]u8 = undefined;
    if (!ata.readSector(volume.device, sector_lba, &sector)) return null;
    return get32(&sector, @intCast((cluster * 4) % 512)) & 0x0fffffff;
}

fn setFatEntry(cluster: u32, value: u32) bool {
    if (cluster < 2 or cluster >= volume.cluster_count + 2) return false;
    const relative = (cluster * 4) / 512;
    const offset: usize = @intCast((cluster * 4) % 512);
    const mirrored = (volume.ext_flags & 0x0080) == 0;
    const first_copy: u32 = if (mirrored) 0 else volume.ext_flags & 0x000f;
    const copies: u32 = if (mirrored) volume.fat_count else 1;
    var copy: u32 = 0;
    while (copy < copies) : (copy += 1) {
        const fat_index = if (mirrored) copy else first_copy;
        const lba = volume.start_lba + @as(u32, volume.reserved_sectors) + fat_index * volume.fat_sectors + relative;
        var sector: [512]u8 = undefined;
        if (!ata.readSector(volume.device, lba, &sector)) return false;
        set32(&sector, offset, (get32(&sector, offset) & 0xf0000000) | (value & 0x0fffffff));
        if (!ata.writeSector(volume.device, lba, &sector)) return false;
    }
    return true;
}

fn clusterLba(cluster: u32) ?u32 {
    if (cluster < 2 or cluster >= volume.cluster_count + 2) return null;
    return volume.first_data_sector + (cluster - 2) * volume.sectors_per_cluster;
}

fn nextCluster(cluster: u32) ?u32 {
    const value = fatEntry(cluster) orelse return null;
    if (value >= 0x0ffffff8 or value == 0) return null;
    if (value < 2 or value >= volume.cluster_count + 2) return null;
    return value;
}

fn nameToShort(name: []const u8, output: *[11]u8) bool {
    output.* = .{ ' ', ' ', ' ', ' ', ' ', ' ', ' ', ' ', ' ', ' ', ' ' };
    if (name.len == 0 or name.len > 12) return false;
    var base_len: usize = 0;
    var ext_len: usize = 0;
    var in_ext = false;
    for (name) |raw| {
        if (raw == '.') {
            if (in_ext or base_len == 0) return false;
            in_ext = true;
            continue;
        }
        if (!(raw >= 'a' and raw <= 'z') and !(raw >= 'A' and raw <= 'Z') and !(raw >= '0' and raw <= '9') and raw != '_' and raw != '-') return false;
        if (in_ext) {
            if (ext_len == 3) return false;
            output[8 + ext_len] = if (raw >= 'a' and raw <= 'z') raw - 32 else raw;
            ext_len += 1;
        } else {
            if (base_len == 8) return false;
            output[base_len] = if (raw >= 'a' and raw <= 'z') raw - 32 else raw;
            base_len += 1;
        }
    }
    if (base_len == 0 or (in_ext and ext_len == 0)) return false;
    return true;
}

fn wantedName(name: []const u8, output: *[11]u8) bool {
    if (nameToShort(name, output)) return true;
    if (name.len == 0 or name.len > 63 or bytesEqual(name, ".") or bytesEqual(name, "..")) return false;
    for (name) |ch| if (ch < 0x20 or ch > 0x7e or ch == '/' or ch == '\\') return false;
    output.* = @splat(' ');
    var dot: ?usize = null;
    for (name, 0..) |ch, i| if (ch == '.') {
        dot = i;
    };
    var base_count: usize = 0;
    for (name[0 .. dot orelse name.len]) |raw| {
        if (!((raw >= 'a' and raw <= 'z') or (raw >= 'A' and raw <= 'Z') or (raw >= '0' and raw <= '9'))) continue;
        if (base_count >= 6) break;
        output[base_count] = if (raw >= 'a' and raw <= 'z') raw - 32 else raw;
        base_count += 1;
    }
    if (base_count == 0) return false;
    output[base_count] = '~';
    output[base_count + 1] = '1';
    if (dot) |dot_index| {
        var ext_count: usize = 0;
        for (name[dot_index + 1 ..]) |raw| {
            if (!((raw >= 'a' and raw <= 'z') or (raw >= 'A' and raw <= 'Z') or (raw >= '0' and raw <= '9'))) continue;
            if (ext_count == 3) break;
            output[8 + ext_count] = if (raw >= 'a' and raw <= 'z') raw - 32 else raw;
            ext_count += 1;
        }
    }
    return true;
}

fn aliasWithSuffix(base: *const [11]u8, suffix: u32, output: *[11]u8) bool {
    if (suffix == 0) return false;
    var stem_end: usize = 0;
    while (stem_end < 8 and base[stem_end] != ' ' and base[stem_end] != '~') : (stem_end += 1) {}
    if (stem_end == 0) return false;
    var digits = suffix;
    var digit_count: usize = 0;
    while (digits != 0) : (digits /= 10) digit_count += 1;
    if (digit_count > 6) return false;
    output.* = base.*;
    @memset(output[0..8], ' ');
    const prefix_len = @min(stem_end, 7 - digit_count);
    @memcpy(output[0..prefix_len], base[0..prefix_len]);
    output[prefix_len] = '~';
    digits = suffix;
    var index: usize = prefix_len + 1 + digit_count;
    while (digits != 0) {
        index -= 1;
        output[index] = '0' + @as(u8, @intCast(digits % 10));
        digits /= 10;
    }
    return true;
}

fn shortName(entry: []const u8, nt_case: u8, output: *Entry) void {
    var length: usize = 0;
    var base_end: usize = 8;
    while (base_end > 0 and entry[base_end - 1] == ' ') base_end -= 1;
    for (0..base_end) |i| {
        var ch = entry[i];
        if (i == 0 and ch == 0x05) ch = 0xe5;
        if ((nt_case & 0x08) != 0 or nt_case == 0) ch = std.ascii.toLower(ch);
        output.name[length] = ch;
        length += 1;
    }
    var ext_end: usize = 11;
    while (ext_end > 8 and entry[ext_end - 1] == ' ') ext_end -= 1;
    if (ext_end > 8) {
        output.name[length] = '.';
        length += 1;
        for (8..ext_end) |i| {
            var ch = entry[i];
            if ((nt_case & 0x10) != 0 or nt_case == 0) ch = std.ascii.toLower(ch);
            output.name[length] = ch;
            length += 1;
        }
    }
    output.name_len = @intCast(length);
}

fn shortCaseFlags(name: []const u8) u8 {
    var in_extension = false;
    var base_has_letters = false;
    var extension_has_letters = false;
    var base_lower = true;
    var extension_lower = true;
    for (name) |ch| {
        if (ch == '.') {
            in_extension = true;
            continue;
        }
        if (ch < 'A' or ch > 'z' or (ch > 'Z' and ch < 'a')) continue;
        if (in_extension) {
            extension_has_letters = true;
            if (ch < 'a') extension_lower = false;
        } else {
            base_has_letters = true;
            if (ch < 'a') base_lower = false;
        }
    }
    return (if (base_has_letters and base_lower) @as(u8, 0x08) else 0) |
        (if (extension_has_letters and extension_lower) @as(u8, 0x10) else 0);
}

fn shortChecksum(name: []const u8) u8 {
    var sum: u8 = 0;
    for (name[0..11]) |byte| sum = (sum >> 1) +% (sum << 7) +% byte;
    return sum;
}

fn decodeLongName(units: *const [260]u16, checksum: u8, short: []const u8, output: *Entry) bool {
    if (checksum != shortChecksum(short)) return false;
    var length: usize = 0;
    for (units) |unit| {
        if (unit == 0 or unit == 0xffff) break;
        if (length == output.name.len) break;
        output.name[length] = if (unit >= 0x20 and unit <= 0x7e) @intCast(unit) else '?';
        length += 1;
    }
    if (length == 0) return false;
    output.name_len = @intCast(length);
    return true;
}

fn lfnNameEqual(units: *const [260]u16, checksum: u8, short: []const u8, name: []const u8) bool {
    if (checksum != shortChecksum(short)) return false;
    var length: usize = 0;
    for (units) |unit| {
        if (unit == 0 or unit == 0xffff) break;
        if (length >= name.len) return false;
        const ch: u8 = if (unit >= 0x20 and unit <= 0x7e) @intCast(unit) else '?';
        const a = if (ch >= 'a' and ch <= 'z') ch - 32 else ch;
        const b = if (name[length] >= 'a' and name[length] <= 'z') name[length] - 32 else name[length];
        if (a != b) return false;
        length += 1;
    }
    return length == name.len;
}

fn captureLongName(sector: *const [512]u8, offset: usize, units: *[260]u16, checksum: *u8) void {
    const ordinal = sector[offset] & 0x1f;
    if (ordinal == 0 or ordinal > 20) return;
    if ((sector[offset] & 0x40) != 0) {
        units.* = @splat(0xffff);
        checksum.* = sector[offset + 13];
    }
    const base = (@as(usize, ordinal) -| 1) * 13;
    for (0..5) |i| units[base + i] = get16(sector, offset + 1 + i * 2);
    for (0..6) |i| units[base + 5 + i] = get16(sector, offset + 14 + i * 2);
    for (0..2) |i| units[base + 11 + i] = get16(sector, offset + 28 + i * 2);
}

const Found = struct {
    entry: Entry,
    sector_lba: u32,
    offset: usize,
};

const DirectorySlot = struct { lba: u32, offset: usize };

fn findFreeDirectorySlots(directory_cluster: u32, needed: usize, output: []DirectorySlot) bool {
    if (needed > output.len or needed == 0) return false;
    var cluster = directory_cluster;
    var traversed: u32 = 0;
    var found: usize = 0;
    while (traversed < volume.cluster_count) : (traversed += 1) {
        const first_sector = clusterLba(cluster) orelse return false;
        for (0..volume.sectors_per_cluster) |sector_offset| {
            const lba = first_sector + @as(u32, @intCast(sector_offset));
            var sector: [512]u8 = undefined;
            if (!ata.readSector(volume.device, lba, &sector)) return false;
            var offset: usize = 0;
            while (offset < 512) : (offset += 32) {
                if (sector[offset] == 0 or sector[offset] == 0xe5) {
                    output[found] = .{ .lba = lba, .offset = offset };
                    found += 1;
                    if (found == needed) return true;
                } else found = 0;
            }
        }
        if (nextCluster(cluster)) |next| {
            cluster = next;
        } else {
            cluster = allocateCluster(cluster) orelse return false;
        }
    }
    return false;
}

fn writeLongNameSlot(slot: DirectorySlot, name: []const u8, ordinal: u8, count: u8, checksum: u8) bool {
    var sector: [512]u8 = undefined;
    if (!ata.readSector(volume.device, slot.lba, &sector)) return false;
    const offset = slot.offset;
    @memset(sector[offset .. offset + 32], 0);
    sector[offset] = ordinal | (if (ordinal == count) @as(u8, 0x40) else 0);
    sector[offset + 11] = 0x0f;
    sector[offset + 12] = 0;
    sector[offset + 13] = checksum;
    sector[offset + 26] = 0;
    sector[offset + 27] = 0;
    var cell: usize = 0;
    while (cell < 13) : (cell += 1) {
        const unit_index = (@as(usize, ordinal) - 1) * 13 + cell;
        const unit: u16 = if (unit_index < name.len) name[unit_index] else if (unit_index == name.len) 0 else 0xffff;
        const cell_offset: usize = if (cell < 5) 1 + cell * 2 else if (cell < 11) 14 + (cell - 5) * 2 else 28 + (cell - 11) * 2;
        set16(&sector, offset + cell_offset, unit);
    }
    return ata.writeSector(volume.device, slot.lba, &sector);
}

fn searchDirectory(directory_cluster: u32, name: []const u8, wanted: *const [11]u8) ?Found {
    // A generated alias is only a candidate for a new long name. It must
    // not make another file with the same alias look like an exact match.
    var short_lookup: [11]u8 = undefined;
    const match_short = name.len == 0 or nameToShort(name, &short_lookup);
    var cluster = directory_cluster;
    var traversed: u32 = 0;
    var long_units: [260]u16 = @splat(0xffff);
    var long_checksum: u8 = 0;
    while (traversed < volume.cluster_count) : (traversed += 1) {
        const first_sector = clusterLba(cluster) orelse return null;
        for (0..volume.sectors_per_cluster) |sector_offset| {
            const lba = first_sector + @as(u32, @intCast(sector_offset));
            var sector: [512]u8 = undefined;
            if (!ata.readSector(volume.device, lba, &sector)) return null;
            var offset: usize = 0;
            while (offset < 512) : (offset += 32) {
                const first = sector[offset];
                if (first == 0) return null;
                const attributes = sector[offset + 11];
                if (attributes == 0x0f) {
                    captureLongName(&sector, offset, &long_units, &long_checksum);
                    continue;
                }
                if (first == 0xe5 or (attributes & 0x08) != 0) {
                    long_units = @splat(0xffff);
                    continue;
                }
                const short_match = match_short and bytesEqual(sector[offset .. offset + 11], wanted);
                const long_match = lfnNameEqual(&long_units, long_checksum, sector[offset .. offset + 11], name);
                if (!short_match and !long_match) {
                    long_units = @splat(0xffff);
                    continue;
                }
                var result = Found{
                    .entry = .{
                        .size = get32(&sector, offset + 28),
                        .first_cluster = (@as(u32, get16(&sector, offset + 20)) << 16) | get16(&sector, offset + 26),
                        .attributes = attributes,
                    },
                    .sector_lba = lba,
                    .offset = offset,
                };
                if (!decodeLongName(&long_units, long_checksum, sector[offset .. offset + 11], &result.entry))
                    shortName(sector[offset .. offset + 11], sector[offset + 12], &result.entry);
                return result;
            }
        }
        cluster = nextCluster(cluster) orelse return null;
    }
    return null;
}

fn bytesEqual(left: []const u8, right: []const u8) bool {
    if (left.len != right.len) return false;
    for (left, right) |a, b| if (a != b) return false;
    return true;
}

pub fn rootCluster() u32 {
    return volume.root_cluster;
}

pub fn listRoot(output: []Entry) usize {
    return listDirectory(volume.root_cluster, output);
}

pub fn listDirectory(directory_cluster: u32, output: []Entry) usize {
    if (!volume.mounted) return 0;
    var found_count: usize = 0;
    var cluster = directory_cluster;
    var traversed: u32 = 0;
    var long_units: [260]u16 = @splat(0xffff);
    var long_checksum: u8 = 0;
    while (traversed < volume.cluster_count and found_count < output.len) : (traversed += 1) {
        const first_sector = clusterLba(cluster) orelse break;
        var ended = false;
        for (0..volume.sectors_per_cluster) |sector_offset| {
            const lba = first_sector + @as(u32, @intCast(sector_offset));
            var sector: [512]u8 = undefined;
            if (!ata.readSector(volume.device, lba, &sector)) return found_count;
            var offset: usize = 0;
            while (offset < 512 and found_count < output.len) : (offset += 32) {
                const first = sector[offset];
                if (first == 0) {
                    ended = true;
                    break;
                }
                const attributes = sector[offset + 11];
                if (attributes == 0x0f) {
                    captureLongName(&sector, offset, &long_units, &long_checksum);
                    continue;
                }
                if (first == 0xe5 or (attributes & 0x08) != 0) {
                    long_units = @splat(0xffff);
                    continue;
                }
                if (sector[offset] == '.' and (sector[offset + 1] == ' ' or sector[offset + 1] == '.')) continue;
                output[found_count] = .{
                    .size = get32(&sector, offset + 28),
                    .first_cluster = (@as(u32, get16(&sector, offset + 20)) << 16) | get16(&sector, offset + 26),
                    .attributes = attributes,
                };
                if (!decodeLongName(&long_units, long_checksum, sector[offset .. offset + 11], &output[found_count]))
                    shortName(sector[offset .. offset + 11], sector[offset + 12], &output[found_count]);
                long_units = @splat(0xffff);
                found_count += 1;
            }
            if (ended) return found_count;
        }
        cluster = nextCluster(cluster) orelse break;
    }
    return found_count;
}

pub fn readFile(name: []const u8, output: []u8) ?usize {
    return readFileAt(volume.root_cluster, name, output);
}

pub fn readFileAt(directory_cluster: u32, name: []const u8, output: []u8) ?usize {
    if (!volume.mounted) return null;
    var wanted: [11]u8 = undefined;
    if (!wantedName(name, &wanted)) return null;
    const found = searchDirectory(directory_cluster, name, &wanted) orelse return null;
    if ((found.entry.attributes & 0x10) != 0) return null;
    const bytes_to_read = @min(output.len, @as(usize, @intCast(found.entry.size)));
    if (bytes_to_read == 0) return 0;
    var cluster = found.entry.first_cluster;
    var written: usize = 0;
    var traversed: u32 = 0;
    while (written < bytes_to_read and traversed < volume.cluster_count) : (traversed += 1) {
        const first_sector = clusterLba(cluster) orelse return null;
        for (0..volume.sectors_per_cluster) |sector_offset| {
            if (written >= bytes_to_read) break;
            var sector: [512]u8 = undefined;
            if (!ata.readSector(volume.device, first_sector + @as(u32, @intCast(sector_offset)), &sector)) return null;
            const amount = @min(512, bytes_to_read - written);
            @memcpy(output[written .. written + amount], sector[0..amount]);
            written += amount;
        }
        if (written < bytes_to_read) cluster = nextCluster(cluster) orelse return null;
    }
    return written;
}

fn findFreeCluster() ?u32 {
    var candidate = volume.next_free_hint;
    var checked: u32 = 0;
    while (checked < volume.cluster_count) : (checked += 1) {
        if (candidate >= volume.cluster_count + 2) candidate = 2;
        const value = fatEntry(candidate) orelse return null;
        if (value == 0) {
            volume.next_free_hint = candidate + 1;
            return candidate;
        }
        candidate += 1;
    }
    return null;
}

fn zeroCluster(cluster: u32) bool {
    const first_sector = clusterLba(cluster) orelse return false;
    var sector: [512]u8 = @splat(0);
    for (0..volume.sectors_per_cluster) |offset| {
        if (!ata.writeSector(volume.device, first_sector + @as(u32, @intCast(offset)), &sector)) return false;
    }
    return true;
}

fn allocateCluster(previous: u32) ?u32 {
    const cluster = findFreeCluster() orelse return null;
    if (!setFatEntry(cluster, 0x0fffffff)) return null;
    if (previous >= 2 and !setFatEntry(previous, cluster)) return null;
    if (!zeroCluster(cluster)) return null;
    return cluster;
}

fn freeChain(first: u32) bool {
    var cluster = first;
    var traversed: u32 = 0;
    while (cluster >= 2 and traversed < volume.cluster_count) : (traversed += 1) {
        const next = fatEntry(cluster) orelse return false;
        if (!setFatEntry(cluster, 0)) return false;
        if (next >= 0x0ffffff8) return true;
        if (next < 2 or next >= volume.cluster_count + 2) return false;
        cluster = next;
    }
    return cluster < 2;
}

fn writeDataChain(data: []const u8) ?u32 {
    if (data.len == 0) return 0;
    var first: u32 = 0;
    var previous: u32 = 0;
    var written: usize = 0;
    while (written < data.len) {
        const cluster = allocateCluster(previous) orelse {
            if (first >= 2) _ = freeChain(first);
            return null;
        };
        if (first == 0) first = cluster;
        previous = cluster;
        const first_sector = clusterLba(cluster) orelse {
            _ = freeChain(first);
            return null;
        };
        for (0..volume.sectors_per_cluster) |sector_offset| {
            if (written >= data.len) break;
            var sector: [512]u8 = @splat(0);
            const amount = @min(512, data.len - written);
            @memcpy(sector[0..amount], data[written .. written + amount]);
            if (!ata.writeSector(volume.device, first_sector + @as(u32, @intCast(sector_offset)), &sector)) {
                _ = freeChain(first);
                return null;
            }
            written += amount;
        }
    }
    return first;
}

fn findFreeDirectorySlot(directory_cluster: u32) ?DirectorySlot {
    var cluster = directory_cluster;
    var traversed: u32 = 0;
    while (traversed < volume.cluster_count) : (traversed += 1) {
        const first_sector = clusterLba(cluster) orelse return null;
        for (0..volume.sectors_per_cluster) |sector_offset| {
            const lba = first_sector + @as(u32, @intCast(sector_offset));
            var sector: [512]u8 = undefined;
            if (!ata.readSector(volume.device, lba, &sector)) return null;
            var offset: usize = 0;
            while (offset < 512) : (offset += 32) {
                if (sector[offset] == 0 or sector[offset] == 0xe5) return .{ .lba = lba, .offset = offset };
            }
        }
        cluster = nextCluster(cluster) orelse {
            const extension = allocateCluster(cluster) orelse return null;
            return .{ .lba = (clusterLba(extension) orelse return null), .offset = 0 };
        };
    }
    return null;
}

pub fn writeFile(name: []const u8, data: []const u8) bool {
    return writeFileAt(volume.root_cluster, name, data);
}

pub fn writeFileAt(directory_cluster: u32, name: []const u8, data: []const u8) bool {
    if (!volume.mounted or data.len > 0xffffffff) return false;
    var wanted: [11]u8 = undefined;
    const short_form = nameToShort(name, &wanted);
    if (!short_form and !wantedName(name, &wanted)) return false;
    const existing = searchDirectory(directory_cluster, name, &wanted);
    if (existing) |old| if ((old.entry.attributes & 0x10) != 0) return false;

    if (existing) |old| {
        var old_sector: [512]u8 = undefined;
        if (!ata.readSector(volume.device, old.sector_lba, &old_sector)) return false;
        @memcpy(&wanted, old_sector[old.offset .. old.offset + 11]);
    } else if (!short_form) {
        var suffix: u32 = 1;
        var found_alias = false;
        while (suffix <= 999_999) : (suffix += 1) {
            var alias: [11]u8 = undefined;
            if (!aliasWithSuffix(&wanted, suffix, &alias)) break;
            if (searchDirectory(directory_cluster, "", &alias) == null) {
                wanted = alias;
                found_alias = true;
                break;
            }
        }
        if (!found_alias) return false;
    }

    const new_first = writeDataChain(data) orelse return false;
    var slots: [6]DirectorySlot = undefined;
    const lfn_count: usize = if (short_form or existing != null) 0 else (name.len + 12) / 13;
    const slot_count = lfn_count + 1;
    if (existing == null and !findFreeDirectorySlots(directory_cluster, slot_count, &slots)) {
        if (new_first >= 2) _ = freeChain(new_first);
        return false;
    }
    const slot: DirectorySlot = if (existing) |old| .{ .lba = old.sector_lba, .offset = old.offset } else slots[slot_count - 1];
    if (existing == null and lfn_count != 0) {
        const checksum = shortChecksum(&wanted);
        var i: usize = 0;
        while (i < lfn_count) : (i += 1) {
            const ordinal: u8 = @intCast(lfn_count - i);
            if (!writeLongNameSlot(slots[i], name, ordinal, @intCast(lfn_count), checksum)) {
                if (new_first >= 2) _ = freeChain(new_first);
                return false;
            }
        }
    }

    var sector: [512]u8 = undefined;
    if (!ata.readSector(volume.device, slot.lba, &sector)) {
        if (new_first >= 2) _ = freeChain(new_first);
        return false;
    }
    const offset = slot.offset;
    @memcpy(sector[offset .. offset + 11], &wanted);
    sector[offset + 11] = 0x20; // Archive file.
    sector[offset + 12] = shortCaseFlags(name);
    set16(&sector, offset + 20, @truncate(new_first >> 16));
    set16(&sector, offset + 26, @truncate(new_first));
    set32(&sector, offset + 28, @intCast(data.len));
    if (!ata.writeSector(volume.device, slot.lba, &sector)) {
        if (new_first >= 2) _ = freeChain(new_first);
        return false;
    }
    if (existing) |old| {
        if (old.entry.first_cluster >= 2 and old.entry.first_cluster != new_first) _ = freeChain(old.entry.first_cluster);
    }
    return true;
}

pub fn deleteFile(name: []const u8) bool {
    return deleteFileAt(volume.root_cluster, name);
}

pub fn deleteFileAt(directory_cluster: u32, name: []const u8) bool {
    if (!volume.mounted) return false;
    var wanted: [11]u8 = undefined;
    if (!wantedName(name, &wanted)) return false;
    const found = searchDirectory(directory_cluster, name, &wanted) orelse return false;
    if ((found.entry.attributes & 0x10) != 0) return false;
    var sector: [512]u8 = undefined;
    if (!ata.readSector(volume.device, found.sector_lba, &sector)) return false;
    sector[found.offset] = 0xe5;
    if (!ata.writeSector(volume.device, found.sector_lba, &sector)) return false;
    if (found.entry.first_cluster >= 2) return freeChain(found.entry.first_cluster);
    return true;
}

fn markDirectorySlotDeleted(slot: DirectorySlot) bool {
    var sector: [512]u8 = undefined;
    if (!ata.readSector(volume.device, slot.lba, &sector)) return false;
    sector[slot.offset] = 0xe5;
    return ata.writeSector(volume.device, slot.lba, &sector);
}

fn eraseDirectoryRecord(directory: u32, found: Found) bool {
    var cluster = directory;
    var pending: [20]DirectorySlot = undefined;
    var count: usize = 0;
    var traversed: u32 = 0;
    while (traversed < volume.cluster_count) : (traversed += 1) {
        const first_sector = clusterLba(cluster) orelse return false;
        for (0..volume.sectors_per_cluster) |sector_offset| {
            const lba = first_sector + @as(u32, @intCast(sector_offset));
            var sector: [512]u8 = undefined;
            if (!ata.readSector(volume.device, lba, &sector)) return false;
            var offset: usize = 0;
            while (offset < 512) : (offset += 32) {
                if (lba == found.sector_lba and offset == found.offset) {
                    if (!markDirectorySlotDeleted(.{ .lba = lba, .offset = offset })) return false;
                    for (pending[0..count]) |slot| if (!markDirectorySlotDeleted(slot)) return false;
                    return true;
                }
                if (sector[offset] == 0) return false;
                if (sector[offset] != 0xe5 and sector[offset + 11] == 0x0f) {
                    if (count == pending.len) return false;
                    pending[count] = .{ .lba = lba, .offset = offset };
                    count += 1;
                } else count = 0;
            }
        }
        cluster = nextCluster(cluster) orelse return false;
    }
    return false;
}

pub fn renameAt(directory: u32, old_name: []const u8, new_name: []const u8) bool {
    if (!volume.mounted or new_name.len == 0 or new_name.len > 63 or bytesEqual(new_name, ".") or bytesEqual(new_name, "..")) return false;
    if (new_name[new_name.len - 1] == '.' or new_name[new_name.len - 1] == ' ') return false;
    for (new_name) |ch| if (ch < 0x20 or ch > 0x7e or std.mem.indexOfScalar(u8, "\\/:*?\"<>|", ch) != null) return false;
    var old_alias: [11]u8 = undefined;
    if (!wantedName(old_name, &old_alias)) return false;
    const old = searchDirectory(directory, old_name, &old_alias) orelse return false;
    if (bytesEqual(old_name, new_name)) return true;
    var alias: [11]u8 = undefined;
    if (!wantedName(new_name, &alias)) return false;
    if (searchDirectory(directory, new_name, &alias)) |existing| {
        if (existing.sector_lba != old.sector_lba or existing.offset != old.offset) return false;
    }
    const base = alias;
    var suffix: u32 = 1;
    while (suffix <= 999_999) : (suffix += 1) {
        if (!aliasWithSuffix(&base, suffix, &alias)) return false;
        if (searchDirectory(directory, "", &alias) == null) break;
    }
    if (suffix > 999_999) return false;
    const lfn_count = (new_name.len + 12) / 13;
    var slots: [6]DirectorySlot = undefined;
    if (!findFreeDirectorySlots(directory, lfn_count + 1, &slots)) return false;
    var original_sector: [512]u8 = undefined;
    if (!ata.readSector(volume.device, old.sector_lba, &original_sector)) return false;
    var record: [32]u8 = undefined;
    @memcpy(&record, original_sector[old.offset..][0..32]);
    @memcpy(record[0..11], &alias);
    record[12] = shortCaseFlags(new_name);
    for (0..lfn_count) |i| {
        if (!writeLongNameSlot(slots[i], new_name, @intCast(lfn_count - i), @intCast(lfn_count), shortChecksum(&alias))) return false;
    }
    const target = slots[lfn_count];
    var target_sector: [512]u8 = undefined;
    if (!ata.readSector(volume.device, target.lba, &target_sector)) return false;
    @memcpy(target_sector[target.offset..][0..32], &record);
    if (!ata.writeSector(volume.device, target.lba, &target_sector)) return false;
    if (!eraseDirectoryRecord(directory, old)) {
        for (slots[0 .. lfn_count + 1]) |slot| _ = markDirectorySlotDeleted(slot);
        return false;
    }
    return true;
}

pub fn deleteEntryAt(directory: u32, name: []const u8) bool {
    return deleteEntryRecursive(directory, name, 0);
}

fn deleteEntryRecursive(directory: u32, name: []const u8, depth: usize) bool {
    if (!volume.mounted or depth >= 32 or bytesEqual(name, ".") or bytesEqual(name, "..")) return false;
    var alias: [11]u8 = undefined;
    if (!wantedName(name, &alias)) return false;
    const found = searchDirectory(directory, name, &alias) orelse return false;
    if ((found.entry.attributes & 0x10) != 0) {
        if (found.entry.first_cluster < 2 or found.entry.first_cluster == directory or found.entry.first_cluster == volume.root_cluster) return false;
        var child: [1]Entry = undefined;
        var removed: u32 = 0;
        while (listDirectory(found.entry.first_cluster, &child) != 0) : (removed += 1) {
            if (removed >= volume.cluster_count or !deleteEntryRecursive(found.entry.first_cluster, child[0].name[0..child[0].name_len], depth + 1)) return false;
        }
    }
    if (!eraseDirectoryRecord(directory, found)) return false;
    return found.entry.first_cluster < 2 or freeChain(found.entry.first_cluster);
}

pub fn changeDirectory(directory_cluster: u32, name: []const u8) ?u32 {
    if (!volume.mounted) return null;
    if (name.len == 0 or (name.len == 1 and name[0] == '.')) return directory_cluster;
    var wanted: [11]u8 = undefined;
    if (bytesEqual(name, "..")) {
        wanted = .{ '.', '.', ' ', ' ', ' ', ' ', ' ', ' ', ' ', ' ', ' ' };
    } else if (!wantedName(name, &wanted)) return null;
    const found = searchDirectory(directory_cluster, name, &wanted) orelse return null;
    if ((found.entry.attributes & 0x10) == 0) return null;
    if (found.entry.first_cluster < 2) return volume.root_cluster;
    return found.entry.first_cluster;
}

pub fn makeDirectory(parent_cluster: u32, name: []const u8) bool {
    if (!volume.mounted) return false;
    var wanted: [11]u8 = undefined;
    const short_form = nameToShort(name, &wanted);
    if (!short_form and !wantedName(name, &wanted)) return false;
    if (searchDirectory(parent_cluster, name, &wanted) != null) return false;
    if (!short_form) {
        var suffix: u32 = 1;
        var found_alias = false;
        while (suffix <= 999_999) : (suffix += 1) {
            var alias: [11]u8 = undefined;
            if (!aliasWithSuffix(&wanted, suffix, &alias)) break;
            if (searchDirectory(parent_cluster, "", &alias) == null) {
                wanted = alias;
                found_alias = true;
                break;
            }
        }
        if (!found_alias) return false;
    }
    const cluster = allocateCluster(0) orelse return false;
    const first_sector = clusterLba(cluster) orelse return false;
    var sector: [512]u8 = undefined;
    if (!ata.readSector(volume.device, first_sector, &sector)) return false;
    // A directory starts with its self and parent records.
    @memset(sector[0..64], 0);
    @memset(sector[0..11], ' ');
    sector[0] = '.';
    sector[11] = 0x10;
    set16(&sector, 20, @truncate(cluster >> 16));
    set16(&sector, 26, @truncate(cluster));
    @memset(sector[32..43], ' ');
    sector[32] = '.';
    sector[33] = '.';
    sector[43] = 0x10;
    const actual_parent = if (parent_cluster < 2) volume.root_cluster else parent_cluster;
    set16(&sector, 52, @truncate(actual_parent >> 16));
    set16(&sector, 58, @truncate(actual_parent));
    if (!ata.writeSector(volume.device, first_sector, &sector)) return false;
    var slots: [6]DirectorySlot = undefined;
    const lfn_count: usize = if (short_form) 0 else (name.len + 12) / 13;
    const total_slots = lfn_count + 1;
    if (!findFreeDirectorySlots(parent_cluster, total_slots, &slots)) return false;
    if (lfn_count != 0) {
        const checksum = shortChecksum(&wanted);
        var i: usize = 0;
        while (i < lfn_count) : (i += 1) {
            if (!writeLongNameSlot(slots[i], name, @intCast(lfn_count - i), @intCast(lfn_count), checksum)) return false;
        }
    }
    const slot = slots[total_slots - 1];
    if (!ata.readSector(volume.device, slot.lba, &sector)) return false;
    @memcpy(sector[slot.offset .. slot.offset + 11], &wanted);
    sector[slot.offset + 11] = 0x10;
    sector[slot.offset + 12] = shortCaseFlags(name);
    set16(&sector, slot.offset + 20, @truncate(cluster >> 16));
    set16(&sector, slot.offset + 26, @truncate(cluster));
    set32(&sector, slot.offset + 28, 0);
    return ata.writeSector(volume.device, slot.lba, &sector);
}
