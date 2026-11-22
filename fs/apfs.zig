//! Native APFS container, volume, browse, and data-fork support. Structural
//! mutations on AetherOS-formatted volumes use journaled COW metadata blocks;
//! generic external volumes accept only guarded same-length data writes.
const ata = @import("../drivers/ata.zig");
const std = @import("std");
const apfs_format = @import("apfs_format.zig");
const Entry = @import("ext2.zig").Entry;

const sector_size: usize = 512;
const max_block_size: usize = 65536;
const native_journal_capacity: usize = 8;
const apfs_partition_guid = [_]u8{ 0xef, 0x57, 0x34, 0x7c, 0x00, 0x00, 0xaa, 0x11, 0xaa, 0x11, 0x00, 0x30, 0x65, 0x43, 0xec, 0xac };

pub const Container = struct {
    device: u8,
    partition_lba: u64,
    block_size: u32,
    block_count: u64,
    maximum_volumes: u32,
    uuid: [16]u8,
    xid: u64,
    next_object_id: u64,
    omap_block: u64,
    spaceman_oid: u64,
    reaper_oid: u64,
    spaceman_block: u64,
    reaper_block: u64,
    free_block_count: u64,
    has_checkpoint: bool,
    checkpoint_desc_base: u64,
    checkpoint_desc_blocks: u32,
    checkpoint_desc_index: u32,
    checkpoint_data_base: u64,
    checkpoint_data_blocks: u32,
    checkpoint_data_index: u32,
    checkpoint_data_len: u32,
    volume_oids: [100]u64,
};

pub const Volume = struct {
    container: Container,
    object_id: u64,
    superblock_block: u64,
    xid: u64,
    omap_block: u64,
    omap_tree_block: u64,
    root_tree_oid: u64,
    root_tree_type: u32,
    root_tree_block: u64,
    extentref_tree_oid: u64,
    snapshot_tree_oid: u64,
    snapshot_count: u64,
    unencrypted: bool,
    sealed: bool,
    native_formatted: bool,
    next_object_id: u64,
    next_data_block: u64,
    next_metadata_block: u64,
    allocator_xid: u64,
    metadata_journal: [native_journal_capacity]NativeMetadataRun,
    metadata_journal_count: u8,
    pending_metadata_run: NativeMetadataRun,
    name: [128]u8,
    name_len: u8,
};

const NativeMetadataRun = struct {
    xid: u64 = 0,
    first_block: u64 = 0,
    block_count: u64 = 0,
    volume_block_count: u64 = 0,
};

fn validMetadataRun(run: NativeMetadataRun, container: Container) bool {
    return run.xid != 0 and run.first_block != 0 and run.block_count != 0 and
        run.first_block < container.block_count - 1 and run.block_count <= container.block_count - 1 - run.first_block and
        run.volume_block_count <= run.block_count;
}

fn putMetadataRun(bytes: []u8, offset: usize, run: NativeMetadataRun) void {
    put64(bytes, offset, run.xid);
    put64(bytes, offset + 8, run.first_block);
    put64(bytes, offset + 16, run.block_count);
    put64(bytes, offset + 24, run.volume_block_count);
}

fn buildAllocatorJournal(output: []u8, next_oid: u64, next_data: u64, next_metadata: u64, allocator_xid: u64, entries: []const NativeMetadataRun, pending: NativeMetadataRun) bool {
    if (output.len < 352 or entries.len > native_journal_capacity) return false;
    @memset(output, 0);
    put32(output, 8, 2);
    put64(output, 16, next_oid);
    put64(output, 24, next_data);
    put64(output, 32, next_metadata);
    put64(output, 40, allocator_xid);
    put32(output, 48, @intCast(entries.len));
    for (entries, 0..) |entry, index| putMetadataRun(output, 56 + index * 32, entry);
    putMetadataRun(output, 312, pending);
    @memcpy(output[344..352], "AETHAPFS");
    put64(output, 0, fletcher64(output[8..]));
    return true;
}

const Block = [max_block_size]u8;
// APFS operations are currently serialized by the kernel; a shared scratch
// block avoids allocating a 64 KiB buffer in each tree-walk stack frame.
var io_block: Block = undefined;
var allocator_cib_block: Block = undefined;
// APFS spaceman CIBs hold up to 126 chunk descriptors. Keep their 4 KiB
// bitmaps in static storage so allocation never consumes kernel stack space.
const native_chunk_blocks: u64 = 32768;
const native_chunk_bitmap_bytes: usize = 4096;
const native_max_chunks: usize = 126;
var native_allocation_bitmap: [native_chunk_bitmap_bytes * native_max_chunks]u8 = undefined;
var native_allocator_block_count: u64 = 0;
const NativeRun = struct { first_block: u64, block_count: u64, logical_offset: u64, byte_len: usize };
var native_pending_runs: [max_native_records]NativeRun = undefined;
const NativeFreedRange = struct { first_block: u64, block_count: u64 };
const NativeFreedSet = struct { ranges: [max_native_records]NativeFreedRange = undefined, count: usize = 0 };
const OmapValue = struct { flags: u32, size: u32, xid: u64, paddr: u64 };
const TreeEntry = struct { key: []const u8, value: []const u8 };
const Handle = struct { value: u32, object_id: u64 };
var mounted_volume: ?Volume = null;
pub var last_operation_error: []const u8 = "none";
var operation_error_buffer: [128]u8 = undefined;
var handles: [512]Handle = undefined;
var handle_count: usize = 0;
var next_handle: u32 = 3;

fn setOperationErrorFmt(comptime format: []const u8, args: anytype) void {
    last_operation_error = std.fmt.bufPrint(&operation_error_buffer, format, args) catch "APFS operation failed";
}

fn le16(bytes: []const u8, offset: usize) u16 {
    return @as(u16, bytes[offset]) | (@as(u16, bytes[offset + 1]) << 8);
}
fn le32(bytes: []const u8, offset: usize) u32 {
    return @as(u32, bytes[offset]) |
        (@as(u32, bytes[offset + 1]) << 8) |
        (@as(u32, bytes[offset + 2]) << 16) |
        (@as(u32, bytes[offset + 3]) << 24);
}
fn le64(bytes: []const u8, offset: usize) u64 {
    return @as(u64, le32(bytes, offset)) | (@as(u64, le32(bytes, offset + 4)) << 32);
}
fn put16(bytes: []u8, offset: usize, value: u16) void {
    bytes[offset] = @truncate(value);
    bytes[offset + 1] = @truncate(value >> 8);
}
fn put32(bytes: []u8, offset: usize, value: u32) void {
    for (0..4) |i| bytes[offset + i] = @truncate(value >> @intCast(i * 8));
}
fn put64(bytes: []u8, offset: usize, value: u64) void {
    for (0..8) |i| bytes[offset + i] = @truncate(value >> @intCast(i * 8));
}
fn readSectors(device: u8, lba: u64, output: []u8) bool {
    if (output.len == 0 or output.len % sector_size != 0) return false;
    const count = output.len / sector_size;
    const max_lba: u64 = 0x0000_ffff_ffff_ffff;
    if (lba > max_lba or @as(u64, @intCast(count - 1)) > max_lba - lba) return false;
    for (0..count) |index| {
        const sector: *[sector_size]u8 = @ptrCast(output[index * sector_size ..][0..sector_size]);
        if (!ata.readSector(device, lba + index, sector)) return false;
    }
    return true;
}
fn writeSectors(device: u8, lba: u64, input: []const u8) bool {
    if (input.len == 0 or input.len % sector_size != 0) return false;
    const count = input.len / sector_size;
    const max_lba: u64 = 0x0000_ffff_ffff_ffff;
    if (lba > max_lba or @as(u64, @intCast(count - 1)) > max_lba - lba) return false;
    for (0..count) |index| {
        const sector: *const [sector_size]u8 = @ptrCast(input[index * sector_size ..][0..sector_size]);
        if (!ata.writeSector(device, lba + index, sector)) return false;
    }
    return true;
}
fn fletcher64(bytes: []const u8) u64 {
    const modulus: u64 = 0xffff_ffff;
    var sum1: u64 = 0;
    var sum2: u64 = 0;
    var offset: usize = 0;
    while (offset + 4 <= bytes.len) : (offset += 4) {
        sum1 = (sum1 + le32(bytes, offset)) % modulus;
        sum2 = (sum2 + sum1) % modulus;
    }
    const low = modulus - ((sum1 + sum2) % modulus);
    const high = modulus - ((sum1 + low) % modulus);
    return (high << 32) | low;
}
fn hasValidChecksum(block: []const u8) bool {
    return block.len >= 4096 and block.len % 4 == 0 and le64(block, 0) == fletcher64(block[8..]);
}
fn readBlock(container: Container, block_number: u64, output: []u8) bool {
    if (output.len != container.block_size or block_number >= container.block_count) return false;
    const sectors_per_block = container.block_size / sector_size;
    const block_sector = std.math.mul(u64, block_number, sectors_per_block) catch return false;
    const lba = std.math.add(u64, container.partition_lba, block_sector) catch return false;
    return readSectors(container.device, lba, output);
}
fn writeBlock(container: Container, block_number: u64, input: []const u8) bool {
    if (input.len != container.block_size or block_number >= container.block_count) return false;
    const sectors_per_block = container.block_size / sector_size;
    const block_sector = std.math.mul(u64, block_number, sectors_per_block) catch return false;
    const lba = std.math.add(u64, container.partition_lba, block_sector) catch return false;
    return writeSectors(container.device, lba, input);
}

fn treeEntry(block: []const u8, index: usize, key_size: usize, value_size: usize) ?TreeEntry {
    if (block.len < 96) return null;
    const flags = @as(u16, block[32]) | (@as(u16, block[33]) << 8);
    const count = le32(block, 36);
    if (index >= count) return null;
    const toc_offset = @as(usize, le16(block, 40));
    const toc_bytes = @as(usize, le16(block, 42));
    const fixed = (flags & 4) != 0;
    const entry_size: usize = if (fixed) 4 else 8;
    const toc_start = 56 + toc_offset;
    const entries_bytes = @as(usize, count) * entry_size;
    if (toc_bytes < entries_bytes or toc_start > block.len or toc_bytes > block.len - toc_start) return null;
    const toc = toc_start + index * entry_size;
    const key_offset = @as(usize, le16(block, toc));
    const actual_key_size = if (fixed) key_size else @as(usize, le16(block, toc + 2));
    const value_offset_at: usize = toc + (if (fixed) @as(usize, 2) else @as(usize, 4));
    const value_offset = @as(usize, le16(block, value_offset_at));
    const actual_value_size = if (fixed) value_size else @as(usize, le16(block, toc + 6));
    const key_start = toc_start + toc_bytes + key_offset;
    const footer_size: usize = if ((flags & 1) != 0) 40 else 0;
    if (footer_size > block.len or value_offset > block.len - footer_size) return null;
    const value_end = block.len - footer_size - value_offset;
    if (key_start > block.len or actual_key_size > block.len - key_start or actual_value_size > value_end) return null;
    const value_start = value_end - actual_value_size;
    return .{ .key = block[key_start .. key_start + actual_key_size], .value = block[value_start..value_end] };
}

fn readRawContainerBlock(device: u8, partition_lba: u64, block_size: u32, block_count: u64, block_number: u64, output: []u8) bool {
    if (output.len != block_size or block_number >= block_count) return false;
    const sectors_per_block = block_size / sector_size;
    const sector_offset = std.math.mul(u64, block_number, sectors_per_block) catch return false;
    const lba = std.math.add(u64, partition_lba, sector_offset) catch return false;
    return readSectors(device, lba, output);
}

/// Resolve one logical block of a checkpoint area. APFS can store the area
/// contiguously or describe its fragments with an extent-list B-tree.
fn checkpointAreaPhysicalBlock(device: u8, partition_lba: u64, block_size: u32, block_count: u64, base: u64, blocks_field: u32, logical_block: u64) ?u64 {
    const capacity: u64 = blocks_field & 0x7fff_ffff;
    if (logical_block >= capacity) return null;
    if ((blocks_field & 0x8000_0000) == 0) {
        const paddr = std.math.add(u64, base, logical_block) catch return null;
        if (paddr >= block_count) return null;
        return paddr;
    }
    if (base >= block_count) return null;
    var node: Block = undefined;
    var paddr = base;
    var depth: u8 = 0;
    while (depth < 32) : (depth += 1) {
        if (!readRawContainerBlock(device, partition_lba, block_size, block_count, paddr, node[0..block_size])) return null;
        const bytes = node[0..block_size];
        if (!hasValidChecksum(bytes) or (le32(bytes, 24) & 0xffff) != 2 or (le32(bytes, 28) & 0xffff) != 0x0a) return null;
        const flags = le16(bytes, 32);
        const level = le16(bytes, 34);
        const count = le32(bytes, 36);
        if (count > 4096) return null;
        if (level != 0) {
            var child: ?u64 = null;
            var first_child: ?u64 = null;
            for (0..count) |index| {
                const item = treeEntry(bytes, index, 8, 8) orelse return null;
                if (item.key.len < 8 or item.value.len < 8) return null;
                const key = le64(item.key, 0);
                const next_child = le64(item.value, 0);
                if (first_child == null) first_child = next_child;
                if (key <= logical_block) child = next_child else break;
            }
            paddr = child orelse first_child orelse return null;
            continue;
        }
        if ((flags & 2) == 0) return null;
        for (0..count) |index| {
            const item = treeEntry(bytes, index, 8, 16) orelse return null;
            if (item.key.len < 8 or item.value.len < 16) return null;
            const first_logical = le64(item.key, 0);
            const extent_start = le64(item.value, 0);
            const extent_count = le64(item.value, 8);
            if (extent_count == 0 or logical_block < first_logical or logical_block - first_logical >= extent_count) continue;
            const resolved = std.math.add(u64, extent_start, logical_block - first_logical) catch return null;
            if (resolved >= block_count) return null;
            return resolved;
        }
        return null;
    }
    return null;
}

fn checkpointDataContainsPaddr(device: u8, partition_lba: u64, block_size: u32, block_count: u64, base: u64, blocks_field: u32, index: u32, length: u32, paddr: u64) bool {
    const capacity: u64 = blocks_field & 0x7fff_ffff;
    if (capacity == 0 or length == 0 or length > capacity or index >= capacity or paddr >= block_count) return false;
    if ((blocks_field & 0x8000_0000) == 0) {
        const end = std.math.add(u64, base, capacity) catch return false;
        if (end > block_count or paddr < base or paddr >= end) return false;
        const slot = paddr - base;
        const distance = (slot + capacity - index) % capacity;
        return distance < length;
    }
    // Checkpoint data areas are normally small. Bound reverse membership
    // walks for fragmented areas; larger noncontiguous layouts remain
    // unsupported instead of causing an unbounded mount-time scan.
    if (length > 4096) return false;
    for (0..length) |offset| {
        const slot = (@as(u64, index) + offset) % capacity;
        const physical = checkpointAreaPhysicalBlock(device, partition_lba, block_size, block_count, base, blocks_field, slot) orelse return false;
        if (physical == paddr) return true;
    }
    return false;
}

fn bitmapIsAllocated(block_number: u64) bool {
    const byte_index: usize = @intCast(block_number / 8);
    const bit: u3 = @intCast(block_number % 8);
    return (native_allocation_bitmap[byte_index] & (@as(u8, 1) << bit)) != 0;
}

fn setBitmapAllocated(block_number: u64) void {
    const byte_index: usize = @intCast(block_number / 8);
    const bit: u3 = @intCast(block_number % 8);
    native_allocation_bitmap[byte_index] |= @as(u8, 1) << bit;
}

/// Load and cross-check the APFS chunk bitmaps emitted by our formatter.
/// The CIB free counts and spaceman totals must match the bitmap before any
/// native structural write is allowed.
fn loadNativeAllocationBitmap(container: Container) bool {
    if (container.block_size != 4096 or container.block_count < 256 or container.block_count > native_chunk_blocks * native_max_chunks or container.spaceman_block >= container.block_count) {
        last_operation_error = "APFS spaceman geometry is outside writer limits";
        return false;
    }
    const chunk_count = (container.block_count + native_chunk_blocks - 1) / native_chunk_blocks;
    if (!readBlock(container, container.spaceman_block, io_block[0..container.block_size])) {
        last_operation_error = "APFS spaceman block read failed";
        return false;
    }
    const spaceman = io_block[0..container.block_size];
    const cib_array_offset = le32(spaceman, 80);
    const spaceman_free_count = le64(spaceman, 72);
    if (!hasValidChecksum(spaceman) or (le32(spaceman, 24) & 0xffff) != 5 or le64(spaceman, 48) != container.block_count or
        le32(spaceman, 36) != @as(u32, @intCast(native_chunk_blocks)) or le64(spaceman, 56) != chunk_count or le32(spaceman, 64) != 1 or
        cib_array_offset < 2496 or cib_array_offset > container.block_size - 8) {
        last_operation_error = "APFS spaceman header or CIB address array is invalid";
        return false;
    }
    const cib_paddr = le64(spaceman, cib_array_offset);
    if (cib_paddr >= container.block_count or !readBlock(container, cib_paddr, io_block[0..container.block_size])) {
        last_operation_error = "APFS chunk-info block read failed";
        return false;
    }
    // Keep the CIB separate from the shared I/O block: reading each chunk
    // bitmap reuses io_block, while later chunk descriptors still come from
    // this CIB.
    @memcpy(allocator_cib_block[0..container.block_size], io_block[0..container.block_size]);
    const cib = allocator_cib_block[0..container.block_size];
    if (!hasValidChecksum(cib) or (le32(cib, 24) & 0xffff) != 7 or le64(cib, 8) != cib_paddr or le32(cib, 32) != 0 or @as(u64, le32(cib, 36)) != chunk_count) {
        last_operation_error = "APFS chunk-info block header is invalid";
        return false;
    }
    @memset(&native_allocation_bitmap, 0);
    var total_free: u64 = 0;
    for (0..chunk_count) |chunk| {
        const entry = 40 + chunk * 32;
        const start = le64(cib, entry + 8);
        const count = le32(cib, entry + 16);
        const expected_start = @as(u64, chunk) * native_chunk_blocks;
        const expected_count = @min(native_chunk_blocks, container.block_count - expected_start);
        const bitmap_paddr = le64(cib, entry + 24);
        if (start != expected_start or @as(u64, count) != expected_count or bitmap_paddr >= container.block_count) {
            last_operation_error = "APFS chunk descriptor is invalid";
            return false;
        }
        if (!readBlock(container, bitmap_paddr, io_block[0..container.block_size])) {
            last_operation_error = "APFS chunk bitmap read failed";
            return false;
        }
        const bitmap_start: usize = chunk * native_chunk_bitmap_bytes;
        @memcpy(native_allocation_bitmap[bitmap_start .. bitmap_start + native_chunk_bitmap_bytes], io_block[0..native_chunk_bitmap_bytes]);
        // AetherOS reserves the final two container blocks for the allocator
        // journal and a guard block. Some legacy PIO controllers return the
        // last word of the final bitmap sector as zero; enforce these reserved
        // bits in memory as well as validating them through the CIB counts.
        const reserved_start = container.block_count - 2;
        for (reserved_start..container.block_count) |reserved_block| {
            if (reserved_block < expected_start or reserved_block >= expected_start + expected_count) continue;
            const local: usize = @intCast(reserved_block - expected_start);
            native_allocation_bitmap[bitmap_start + local / 8] |= @as(u8, 1) << @intCast(local % 8);
        }
        var chunk_free: u64 = 0;
        for (0..count) |local| {
            const bit_index: usize = local;
            if ((native_allocation_bitmap[bitmap_start + bit_index / 8] & (@as(u8, 1) << @intCast(bit_index % 8))) == 0) chunk_free += 1;
        }
        if (chunk_free != le32(cib, entry + 20)) {
            setOperationErrorFmt("APFS chunk {d}: bitmap free={d}, CIB free={d}, tail=0x{x}", .{ chunk, chunk_free, le32(cib, entry + 20), io_block[container.block_size - 1] });
            return false;
        }
        total_free = std.math.add(u64, total_free, chunk_free) catch return false;
    }
    if (total_free != container.free_block_count or total_free != spaceman_free_count) {
        setOperationErrorFmt("APFS free count {d}; container {d}, spaceman {d}", .{ total_free, container.free_block_count, spaceman_free_count });
        return false;
    }
    native_allocator_block_count = container.block_count;
    return true;
}

/// Reserve one contiguous run from APFS's bitmap. Data uses a high-address
/// first fit; metadata uses a low-address first fit to keep tree packing
/// predictable while no longer trusting the private journal as free-space.
fn reserveNativeRun(block_count: u64, from_high_end: bool) ?u64 {
    const total_blocks = native_allocator_block_count;
    if (total_blocks == 0 or block_count == 0 or block_count > total_blocks) return null;
    if (from_high_end) {
        var first: u64 = total_blocks - block_count;
        while (true) {
            var occupied: ?u64 = null;
            for (0..block_count) |offset| if (bitmapIsAllocated(first + offset)) {
                occupied = first + offset;
                break;
            };
            if (occupied == null) {
                for (0..block_count) |offset| setBitmapAllocated(first + offset);
                return first;
            }
            const used = occupied.?;
            if (used < block_count) break;
            first = used - block_count;
        }
    } else {
        var first: u64 = 0;
        while (first <= total_blocks - block_count) : (first += 1) {
            var occupied: ?u64 = null;
            for (0..block_count) |offset| if (bitmapIsAllocated(first + offset)) {
                occupied = first + offset;
                break;
            };
            if (occupied == null) {
                for (0..block_count) |offset| setBitmapAllocated(first + offset);
                return first;
            }
            first = occupied.?;
        }
    }
    return null;
}

fn reserveNativeRunUpTo(max_blocks: u64, from_high_end: bool) ?NativeRun {
    const total_blocks = native_allocator_block_count;
    if (total_blocks == 0) return null;
    if (max_blocks == 0 or max_blocks > total_blocks) return null;
    if (from_high_end) {
        var cursor = total_blocks;
        while (cursor > 0) {
            cursor -= 1;
            if (bitmapIsAllocated(cursor)) continue;
            const end = cursor + 1;
            var start = cursor;
            while (start > 0 and end - start < max_blocks and !bitmapIsAllocated(start - 1)) start -= 1;
            const count = end - start;
            for (start..end) |block_number| setBitmapAllocated(block_number);
            return .{ .first_block = start, .block_count = count, .logical_offset = 0, .byte_len = 0 };
        }
    } else {
        var cursor: u64 = 0;
        while (cursor < total_blocks) : (cursor += 1) {
            if (bitmapIsAllocated(cursor)) continue;
            const start = cursor;
            while (cursor < total_blocks and cursor - start < max_blocks and !bitmapIsAllocated(cursor)) cursor += 1;
            const count = cursor - start;
            for (start..cursor) |block_number| setBitmapAllocated(block_number);
            return .{ .first_block = start, .block_count = count, .logical_offset = 0, .byte_len = 0 };
        }
    }
    return null;
}

fn nativeBitmapFreeCount() u64 {
    var free: u64 = 0;
    for (0..native_allocator_block_count) |block_number| if (!bitmapIsAllocated(block_number)) {
        free += 1;
    };
    return free;
}

fn addFreedRange(freed: *NativeFreedSet, first_block: u64, block_count: u64) bool {
    if (block_count == 0 or native_allocator_block_count == 0 or first_block >= native_allocator_block_count or block_count > native_allocator_block_count - first_block or freed.count == freed.ranges.len) return false;
    freed.ranges[freed.count] = .{ .first_block = first_block, .block_count = block_count };
    freed.count += 1;
    return true;
}

fn collectStreamExtents(set: *const RecordSet, stream_oid: u64, block_size: u32, freed: *NativeFreedSet) bool {
    for (set.records[0..set.count]) |record| {
        const key = record.key[0..record.key_len];
        const value = record.value[0..record.value_len];
        if (key.len < 16 or value.len < 24) continue;
        const header = le64(key, 0);
        if ((header >> 60) != 8 or (header & 0x0fff_ffff_ffff_ffff) != stream_oid) continue;
        const len_and_flags = le64(value, 0);
        const length = len_and_flags & 0x00ff_ffff_ffff_ffff;
        const physical = le64(value, 8);
        if (length == 0 or (len_and_flags >> 56) != 0 or le64(value, 16) != 0 or physical == 0) return false;
        const blocks = (length + block_size - 1) / block_size;
        if (!addFreedRange(freed, physical, blocks)) return false;
    }
    return true;
}

fn freedBlockCount(freed: ?*const NativeFreedSet) ?u64 {
    const ranges = freed orelse return 0;
    var total: u64 = 0;
    for (ranges.ranges[0..ranges.count]) |range| total = std.math.add(u64, total, range.block_count) catch return null;
    return total;
}

fn validateFreedRanges(freed: ?*const NativeFreedSet) bool {
    const ranges = freed orelse return true;
    for (ranges.ranges[0..ranges.count], 0..) |range, i| {
        if (range.first_block >= native_allocator_block_count or range.block_count > native_allocator_block_count - range.first_block) return false;
        for (ranges.ranges[0..i]) |prior| {
            if (range.first_block < prior.first_block + prior.block_count and prior.first_block < range.first_block + range.block_count) return false;
        }
        for (0..range.block_count) |offset| if (!bitmapIsAllocated(range.first_block + offset)) return false;
    }
    return true;
}

fn clearFreedRanges(freed: ?*const NativeFreedSet) bool {
    const ranges = freed orelse return true;
    for (ranges.ranges[0..ranges.count]) |range| {
        for (0..range.block_count) |offset| {
            const block_number = range.first_block + offset;
            if (!bitmapIsAllocated(block_number)) return false;
            const byte_index: usize = @intCast(block_number / 8);
            const bit: u3 = @intCast(block_number % 8);
            native_allocation_bitmap[byte_index] &= ~(@as(u8, 1) << bit);
        }
    }
    return true;
}

fn validateMetadataRunBitmap(run: NativeMetadataRun) bool {
    if (run.first_block >= native_allocator_block_count or run.block_count > native_allocator_block_count - run.first_block) return false;
    for (0..run.block_count) |offset| if (!bitmapIsAllocated(run.first_block + offset)) return false;
    return true;
}

fn clearMetadataRunBitmap(run: NativeMetadataRun) bool {
    if (!validateMetadataRunBitmap(run)) return false;
    for (0..run.block_count) |offset| {
        const block_number = run.first_block + offset;
        const byte_index: usize = @intCast(block_number / 8);
        const bit: u3 = @intCast(block_number % 8);
        native_allocation_bitmap[byte_index] &= ~(@as(u8, 1) << bit);
    }
    return true;
}

fn keyCompare(akey: []const u8, bkey: []const u8) ?std.math.Order {
    if (akey.len < 16 or bkey.len < 16) return null;
    const a_oid = le64(akey, 0);
    const b_oid = le64(bkey, 0);
    if (a_oid != b_oid) return std.math.order(a_oid, b_oid);
    return std.math.order(le64(akey, 8), le64(bkey, 8));
}

fn lookupOmap(container: Container, tree_root: u64, wanted_oid: u64, target_xid: u64) ?OmapValue {
    var paddr = tree_root;
    var node: Block = undefined;
    var depth: u8 = 0;
    while (depth < 32) : (depth += 1) {
        if (!readBlock(container, paddr, node[0..container.block_size])) return null;
        const bytes = node[0..container.block_size];
        if (!hasValidChecksum(bytes)) return null;
        const flags = @as(u16, bytes[32]) | (@as(u16, bytes[33]) << 8);
        const level = @as(u16, bytes[34]) | (@as(u16, bytes[35]) << 8);
        const count = le32(bytes, 36);
        if ((flags & 4) == 0 or count > 4096) return null;
        var target_key: [16]u8 = undefined;
        put64(&target_key, 0, wanted_oid);
        put64(&target_key, 8, target_xid);
        if (level != 0) {
            var chosen: ?u64 = null;
            var first_child: ?u64 = null;
            for (0..count) |index| {
                const item = treeEntry(bytes, index, 16, 8) orelse return null;
                if (item.key.len < 16 or item.value.len < 8) return null;
                const order = keyCompare(item.key, &target_key) orelse return null;
                if (first_child == null) first_child = le64(item.value, 0);
                if (order != .gt) chosen = le64(item.value, 0) else break;
            }
            paddr = chosen orelse first_child orelse return null;
            continue;
        }
        var result: ?OmapValue = null;
        for (0..count) |index| {
            const item = treeEntry(bytes, index, 16, 16) orelse return null;
            if (item.key.len < 16 or item.value.len < 16) return null;
            const oid = le64(item.key, 0);
            const xid = le64(item.key, 8);
            if (oid != wanted_oid or xid > target_xid) continue;
            if (result == null or xid > result.?.xid) {
                result = .{ .flags = le32(item.value, 0), .size = le32(item.value, 4), .xid = xid, .paddr = le64(item.value, 8) };
            }
        }
        return result;
    }
    return null;
}

fn readContainerAt(device: u8, partition_lba: u64) ?Container {
    var first_sector: [sector_size]u8 = undefined;
    if (!readSectors(device, partition_lba, &first_sector) or le32(&first_sector, 32) != 0x4253_584e) return null; // NXSB
    const block_size = le32(&first_sector, 36);
    if (block_size < 4096 or block_size > max_block_size or !std.math.isPowerOfTwo(block_size)) return null;
    const block_count = le64(&first_sector, 40);
    if (block_count < 256 or block_count > std.math.maxInt(u64) / @as(u64, block_size)) return null;
    var block: [max_block_size]u8 = undefined;
    const active_block = block[0..block_size];
    if (!readSectors(device, partition_lba, active_block) or !hasValidChecksum(active_block)) return null;
    if (le32(active_block, 32) != 0x4253_584e or le32(active_block, 36) != block_size or le64(active_block, 40) != block_count) return null;

    // Block zero is only the checkpoint locator in APFS. Its checkpoint
    // descriptor area contains checkpoint maps and later NXSB copies; use the
    // newest valid copy instead of silently mounting stale metadata.
    const desc_blocks_field = le32(active_block, 104);
    const desc_base = le64(active_block, 112);
    var has_checkpoint = false;
    var spaceman_block: u64 = 0;
    var reaper_block: u64 = 0;
    var free_block_count: u64 = 0;
    const desc_capacity: u64 = desc_blocks_field & 0x7fff_ffff;
    if (desc_capacity > 0) {
        const contiguous = (desc_blocks_field & 0x8000_0000) == 0;
        const desc_end_block = if (contiguous) std.math.add(u64, desc_base, desc_capacity) catch return null else desc_base;
        if (desc_end_block <= block_count and (!contiguous or desc_base < block_count)) {
            var newest_xid: u64 = 0;
            var selected: [max_block_size]u8 = undefined;
            @memcpy(selected[0..block_size], active_block);
            var offset: u64 = 0;
            while (offset < desc_capacity) : (offset += 1) {
                const block_number = checkpointAreaPhysicalBlock(device, partition_lba, block_size, block_count, desc_base, desc_blocks_field, offset) orelse continue;
                if (!readRawContainerBlock(device, partition_lba, block_size, block_count, block_number, active_block)) return null;
                if (!hasValidChecksum(active_block) or le32(active_block, 32) != 0x4253_584e) continue;
                if (le32(active_block, 36) != block_size or le64(active_block, 40) != block_count) continue;
                const xid = le64(active_block, 16);
                if (xid < newest_xid) continue;
                newest_xid = xid;
                has_checkpoint = true;
                @memcpy(selected[0..block_size], active_block);
            }
            @memcpy(active_block, selected[0..block_size]);

            // The checkpoint map resolves ephemeral container objects such
            // as the space manager. Resolve and validate that reference before
            // accepting a standards-layout checkpoint; this catches stale or
            // half-published superblocks instead of treating them as mounts.
            if (has_checkpoint) {
                const selected_desc_base = le64(active_block, 112);
                const selected_desc_blocks = le32(active_block, 104);
                const selected_desc_capacity: u64 = selected_desc_blocks & 0x7fff_ffff;
                const selected_desc_index = le32(active_block, 136);
                const selected_desc_len = le32(active_block, 140);
                const selected_data_base = le64(active_block, 120);
                const selected_data_blocks = le32(active_block, 108);
                const selected_data_capacity: u64 = selected_data_blocks & 0x7fff_ffff;
                const selected_data_index = le32(active_block, 144);
                const selected_data_len = le32(active_block, 148);
                const selected_spaceman_oid = le64(active_block, 152);
                const selected_reaper_oid = le64(active_block, 168);
                if (selected_desc_capacity == 0 or selected_desc_len == 0 or selected_desc_len > selected_desc_capacity or selected_desc_index >= selected_desc_capacity) return null;
                if (selected_data_capacity == 0 or selected_data_len == 0 or selected_data_len > selected_data_capacity or selected_data_index >= selected_data_capacity) return null;
                const selected_desc_contiguous = (selected_desc_blocks & 0x8000_0000) == 0;
                const selected_desc_end = if (selected_desc_contiguous) std.math.add(u64, selected_desc_base, selected_desc_capacity) catch return null else selected_desc_base;
                if (selected_desc_end > block_count or (!selected_desc_contiguous and selected_desc_base >= block_count)) return null;
                var map_found = false;
                var reaper_found = selected_reaper_oid == 0;
                var desc_offset: u64 = 0;
                while (desc_offset < selected_desc_len) : (desc_offset += 1) {
                    const slot = (@as(u64, selected_desc_index) + desc_offset) % selected_desc_capacity;
                    const desc_block = checkpointAreaPhysicalBlock(device, partition_lba, block_size, block_count, selected_desc_base, selected_desc_blocks, slot) orelse return null;
                    if (!readRawContainerBlock(device, partition_lba, block_size, block_count, desc_block, active_block)) return null;
                    if (!hasValidChecksum(active_block) or (le32(active_block, 24) & 0xffff) != 0x0c) continue;
                    @memcpy(io_block[0..block_size], active_block);
                    const map_bytes = io_block[0..block_size];
                    const count = le32(map_bytes, 36);
                    if (count > (block_size - 40) / 40) return null;
                    for (0..count) |entry_index| {
                        const entry_offset = 40 + entry_index * 40;
                        if (le64(map_bytes, entry_offset + 16) != 0) continue;
                        const entry_type = le32(map_bytes, entry_offset) & 0xffff;
                        const entry_oid = le64(map_bytes, entry_offset + 24);
                        const entry_paddr = le64(map_bytes, entry_offset + 32);
                        if (entry_type == 0x11 and entry_oid == selected_reaper_oid and
                            checkpointDataContainsPaddr(device, partition_lba, block_size, block_count, selected_data_base, selected_data_blocks, selected_data_index, selected_data_len, entry_paddr))
                        {
                            reaper_block = entry_paddr;
                            reaper_found = true;
                        }
                        if (entry_type != 5 or entry_oid != selected_spaceman_oid) continue;
                        const paddr = entry_paddr;
                        if (le32(map_bytes, entry_offset + 8) < block_size or
                            !checkpointDataContainsPaddr(device, partition_lba, block_size, block_count, selected_data_base, selected_data_blocks, selected_data_index, selected_data_len, paddr)) return null;
                        const sm_lba_offset = std.math.mul(u64, paddr, block_size / sector_size) catch return null;
                        const sm_lba = std.math.add(u64, partition_lba, sm_lba_offset) catch return null;
                        if (!readSectors(device, sm_lba, active_block)) return null;
                        if (!hasValidChecksum(active_block) or (le32(active_block, 24) & 0xffff) != 5 or le64(active_block, 8) != selected_spaceman_oid) return null;
                        if (le32(active_block, 32) != block_size or le64(active_block, 48) != block_count or le64(active_block, 72) > block_count) return null;
                        spaceman_block = paddr;
                        free_block_count = le64(active_block, 72);
                        map_found = true;
                    }
                }
                if (!map_found or !reaper_found) return null;
                if (selected_reaper_oid != 0) {
                    if (reaper_block >= block_count or !readRawContainerBlock(device, partition_lba, block_size, block_count, reaper_block, active_block)) return null;
                    if (!hasValidChecksum(active_block) or (le32(active_block, 24) & 0xffff) != 0x11 or le64(active_block, 8) != selected_reaper_oid) return null;
                }
                // Restore the selected NXSB because the descriptor walk used
                // the shared block as scratch space.
                @memcpy(active_block, selected[0..block_size]);
            }
        }
    }
    var uuid: [16]u8 = undefined;
    @memcpy(&uuid, active_block[72..88]);
    var volume_oids: [100]u64 = @splat(0);
    for (0..volume_oids.len) |index| volume_oids[index] = le64(active_block, 184 + index * 8);
    return .{
        .device = device,
        .partition_lba = partition_lba,
        .block_size = block_size,
        .block_count = block_count,
        .maximum_volumes = le32(active_block, 180),
        .uuid = uuid,
        .xid = le64(active_block, 16),
        .next_object_id = le64(active_block, 88),
        .omap_block = le64(active_block, 160),
        .spaceman_oid = le64(active_block, 152),
        .reaper_oid = le64(active_block, 168),
        .spaceman_block = spaceman_block,
        .reaper_block = reaper_block,
        .free_block_count = free_block_count,
        .has_checkpoint = has_checkpoint,
        .checkpoint_desc_base = le64(active_block, 112),
        .checkpoint_desc_blocks = le32(active_block, 104) & 0x7fff_ffff,
        .checkpoint_desc_index = le32(active_block, 136),
        .checkpoint_data_base = le64(active_block, 120),
        .checkpoint_data_blocks = le32(active_block, 108) & 0x7fff_ffff,
        .checkpoint_data_index = le32(active_block, 144),
        .checkpoint_data_len = le32(active_block, 148),
        .volume_oids = volume_oids,
    };
}
fn findPartition(device: u8) ?u64 {
    var header: [sector_size]u8 = undefined;
    if (!readSectors(device, 1, &header) or !std.mem.eql(u8, header[0..8], "EFI PART")) return null;
    const entries_lba = le64(&header, 72);
    const entry_count = @min(le32(&header, 80), 128);
    const entry_size = le32(&header, 84);
    if (entry_size < 128 or entry_size > 4096 or entries_lba == 0) return null;
    var entry: [4096]u8 = undefined;
    for (0..entry_count) |index| {
        const byte_offset = index * entry_size;
        const sector_lba = entries_lba + byte_offset / sector_size;
        const in_sector = byte_offset % sector_size;
        if (in_sector + 128 > sector_size) continue;
        if (!readSectors(device, sector_lba, entry[0..sector_size])) return null;
        if (std.mem.eql(u8, entry[in_sector .. in_sector + 16], &apfs_partition_guid)) {
            return le64(entry[0..], in_sector + 32);
        }
    }
    return null;
}

/// Recognize a raw APFS container or an APFS GPT partition and validate NXSB.
pub fn probe(device: u8) ?Container {
    if (readContainerAt(device, 0)) |container| return container;
    const start = findPartition(device) orelse return null;
    return readContainerAt(device, start);
}

fn readVolume(container: Container, object_id: u64, superblock_block: u64) ?Volume {
    var superblock: Block = undefined;
    if (!readBlock(container, superblock_block, superblock[0..container.block_size])) return null;
    const bytes = superblock[0..container.block_size];
    if (!hasValidChecksum(bytes) or le32(bytes, 32) != 0x4253_5041 or (le32(bytes, 24) & 0xffff) != 0x0d) return null;
    const xid = le64(bytes, 16);
    const omap_block = le64(bytes, 128);
    if (omap_block == 0 or omap_block >= container.block_count) return null;
    var omap: Block = undefined;
    if (!readBlock(container, omap_block, omap[0..container.block_size])) return null;
    const omap_bytes = omap[0..container.block_size];
    // Earlier AetherOS images labeled the volume OMAP object with its private
    // OID 11 instead of its physical block address. Continue mounting those
    // images while newly formatted/committed OMAP objects use APFS paddr OIDs.
    if (!hasValidChecksum(omap_bytes) or (le64(omap_bytes, 8) != omap_block and le64(omap_bytes, 8) != 11) or (le32(omap_bytes, 24) & 0xffff) != 0x0b) return null;
    const omap_tree_block = le64(omap_bytes, 48);
    if (omap_tree_block == 0 or omap_tree_block >= container.block_count) return null;
    const root_tree_oid = le64(bytes, 136);
    const root_tree_type = le32(bytes, 116);
    const incompatible_features = le64(bytes, 56);
    if ((incompatible_features & ~@as(u64, 0x3f)) != 0 or (incompatible_features & 0x10) != 0) return null;
    const unencrypted = (le64(bytes, 264) & 1) != 0;
    if (!unencrypted) return null; // metadata/data encryption needs APFS keybag support
    const volume_omap_tree = lookupOmap(container, omap_tree_block, root_tree_oid, xid) orelse return null;
    if (volume_omap_tree.paddr >= container.block_count or (volume_omap_tree.flags & 1) != 0) return null;
    var result: Volume = .{
        .container = container,
        .object_id = object_id,
        .superblock_block = superblock_block,
        .xid = xid,
        .omap_block = omap_block,
        .omap_tree_block = omap_tree_block,
        .root_tree_oid = root_tree_oid,
        .root_tree_type = root_tree_type,
        .root_tree_block = volume_omap_tree.paddr,
        .extentref_tree_oid = le64(bytes, 144),
        .snapshot_tree_oid = le64(bytes, 152),
        .snapshot_count = le64(bytes, 216),
        .unencrypted = unencrypted,
        .sealed = (incompatible_features & 0x20) != 0,
        .native_formatted = false,
        .next_object_id = 0,
        .next_data_block = 0,
        .next_metadata_block = 0,
        .allocator_xid = 0,
        .metadata_journal = @splat(.{}),
        .metadata_journal_count = 0,
        .pending_metadata_run = .{},
        .name = @splat(0),
        .name_len = 0,
    };
    var allocator_block: Block = undefined;
    if (readBlock(container, container.block_count - 1, allocator_block[0..container.block_size])) {
        const journal_version = le32(allocator_block[8..], 0);
        const legacy_marker = std.mem.eql(u8, allocator_block[0..8], "AETHAPFS");
        const journal_marker = std.mem.eql(u8, allocator_block[344..352], "AETHAPFS");
        if (journal_version == 1 and legacy_marker) {
            const next_oid = le64(allocator_block[16..], 0);
            const next_metadata = le64(allocator_block[32..], 0);
            if (next_oid >= 3 and next_oid < 0x0fff_ffff_ffff_ffff and next_metadata < container.block_count - 1) {
                result.native_formatted = true;
                result.next_object_id = next_oid;
                result.next_data_block = le64(allocator_block[24..], 0);
                result.next_metadata_block = next_metadata;
                result.allocator_xid = le64(allocator_block[40..], 0);
            }
        } else if (journal_version == 2 and hasValidChecksum(allocator_block[0..container.block_size]) and
            // Older v2 journals put the signature under the checksum; accept
            // them when their APFS allocator fields validate, then migrate
            // to the non-overlapping signature slot on the next commit.
            (journal_marker or !legacy_marker)) {
            var parsed = result;
            parsed.next_object_id = le64(allocator_block[16..], 0);
            parsed.next_data_block = le64(allocator_block[24..], 0);
            parsed.next_metadata_block = le64(allocator_block[32..], 0);
            parsed.allocator_xid = le64(allocator_block[40..], 0);
            const journal_count = le32(allocator_block[48..], 0);
            var valid = journal_count <= native_journal_capacity and
                parsed.next_object_id >= 3 and parsed.next_object_id < 0x0fff_ffff_ffff_ffff and
                parsed.next_metadata_block < container.block_count - 1 and parsed.allocator_xid >= xid;
            if (valid) parsed.metadata_journal_count = @intCast(journal_count);
            if (valid) for (0..journal_count) |index| {
                const entry = 56 + index * 32;
                parsed.metadata_journal[index] = .{
                    .xid = le64(allocator_block[entry..], 0),
                    .first_block = le64(allocator_block[entry..], 8),
                    .block_count = le64(allocator_block[entry..], 16),
                    .volume_block_count = le64(allocator_block[entry..], 24),
                };
                if (!validMetadataRun(parsed.metadata_journal[index], container) or parsed.metadata_journal[index].xid > xid or
                    (index != 0 and parsed.metadata_journal[index - 1].xid >= parsed.metadata_journal[index].xid)) valid = false;
            };
            parsed.pending_metadata_run = .{
                .xid = le64(allocator_block[312..], 0),
                .first_block = le64(allocator_block[312..], 8),
                .block_count = le64(allocator_block[312..], 16),
                .volume_block_count = le64(allocator_block[312..], 24),
            };
            if (valid and parsed.pending_metadata_run.xid != 0 and
                (!validMetadataRun(parsed.pending_metadata_run, container) or parsed.pending_metadata_run.xid < xid)) valid = false;
            if (valid and parsed.pending_metadata_run.xid != 0 and parsed.metadata_journal_count != 0 and
                parsed.metadata_journal[parsed.metadata_journal_count - 1].xid >= parsed.pending_metadata_run.xid) valid = false;
            if (valid and parsed.pending_metadata_run.xid == 0 and
                (parsed.pending_metadata_run.first_block != 0 or parsed.pending_metadata_run.block_count != 0 or parsed.pending_metadata_run.volume_block_count != 0)) valid = false;
            if (valid and parsed.pending_metadata_run.xid == xid) {
                if (parsed.metadata_journal_count == native_journal_capacity) {
                    for (1..native_journal_capacity) |index| parsed.metadata_journal[index - 1] = parsed.metadata_journal[index];
                    parsed.metadata_journal_count -= 1;
                }
                parsed.metadata_journal[parsed.metadata_journal_count] = parsed.pending_metadata_run;
                parsed.metadata_journal_count += 1;
                parsed.pending_metadata_run = .{};
            }
            if (valid) {
                parsed.native_formatted = true;
                result = parsed;
            }
        }
    }
    var i: usize = 0;
    while (i + 1 < 256 and result.name_len < result.name.len) : (i += 2) {
        const codepoint = @as(u16, bytes[704 + i]) | (@as(u16, bytes[705 + i]) << 8);
        if (codepoint == 0) break;
        result.name[result.name_len] = if (codepoint < 0x80) @intCast(codepoint) else '?';
        result.name_len += 1;
    }
    return result;
}

/// Resolve and validate the first unencrypted APFS volume in a container.
pub fn findVolume(device: u8) ?Volume {
    const container = probe(device) orelse return null;
    if (container.omap_block == 0 or container.omap_block >= container.block_count) return null;
    var omap: Block = undefined;
    if (!readBlock(container, container.omap_block, omap[0..container.block_size])) return null;
    const omap_bytes = omap[0..container.block_size];
    if (!hasValidChecksum(omap_bytes) or le64(omap_bytes, 8) != container.omap_block or (le32(omap_bytes, 24) & 0xffff) != 0x0b) return null;
    const omap_tree_block = le64(omap_bytes, 48);
    if (omap_tree_block == 0 or omap_tree_block >= container.block_count) return null;
    for (container.volume_oids) |volume_oid| {
        if (volume_oid == 0) continue;
        const resolved = lookupOmap(container, omap_tree_block, volume_oid, container.xid) orelse continue;
        if (resolved.paddr >= container.block_count or (resolved.flags & 1) != 0) continue;
        if (readVolume(container, volume_oid, resolved.paddr)) |volume| return volume;
    }
    return null;
}

fn handleFor(object_id: u64) u32 {
    for (handles[0..handle_count]) |handle| if (handle.object_id == object_id) return handle.value;
    if (handle_count == handles.len) return 0;
    const value = next_handle;
    next_handle +%= 1;
    if (next_handle < 3) next_handle = 3;
    handles[handle_count] = .{ .value = value, .object_id = object_id };
    handle_count += 1;
    return value;
}
fn objectForHandle(value: u32) ?u64 {
    for (handles[0..handle_count]) |handle| if (handle.value == value) return handle.object_id;
    return null;
}

pub fn mountDevice(device: u8) bool {
    mounted_volume = null;
    handle_count = 1;
    next_handle = 3;
    const volume = findVolume(device) orelse {
        handle_count = 0;
        return false;
    };
    handles[0] = .{ .value = 2, .object_id = 2 };
    mounted_volume = volume;
    return true;
}
pub fn isMounted() bool {
    return mounted_volume != null;
}

const FormatContext = struct { device: u8 };
fn formatBlockSink(context_ptr: *anyopaque, block_number: u64, block: []const u8) bool {
    const context: *FormatContext = @ptrCast(@alignCast(context_ptr));
    const sectors_per_block = apfs_format.block_size / sector_size;
    const lba = std.math.mul(u64, block_number, sectors_per_block) catch return false;
    return writeSectors(context.device, lba, block);
}

/// Format only a completely zero-filled raw disk. This explicit API is for the
/// dedicated AetherOS target image; it will refuse existing filesystems/data.
pub fn formatBlankDevice(device: u8, block_count: u64, volume_name: []const u8) bool {
    if (block_count < 256 or block_count > apfs_format.max_formatted_blocks) return false;
    var blank_check: [apfs_format.block_size]u8 = undefined;
    for (0..block_count) |block_number| {
        if (!readSectors(device, block_number * (apfs_format.block_size / sector_size), &blank_check)) return false;
        for (blank_check) |byte| if (byte != 0) return false;
    }
    var context = FormatContext{ .device = device };
    if (!apfs_format.format(block_count, volume_name, formatBlockSink, @ptrCast(&context))) return false;
    if (!ata.flushCache(device)) return false;
    return mountDevice(device);
}

pub fn rootCluster() u32 {
    return 2;
}

/// Walk the filesystem B-tree and return directory records for one directory.
/// APFS FSOIDs are 60-bit; opaque 32-bit handles bridge the existing desktop API.
const RecordVisitor = *const fn (context: *anyopaque, key: []const u8, value: []const u8) bool;

/// Decode either j_drec_key_t or j_drec_hashed_key_t. APFS name lengths
/// include the trailing NUL; the fixed-width B-tree key length disambiguates
/// the two key layouts without guessing from the hash bits.
fn directoryName(key: []const u8) ?[]const u8 {
    if (key.len < 11) return null;
    const hashed_length: usize = @as(usize, le32(key, 8) & 0x3ff);
    if (hashed_length != 0 and hashed_length + 12 == key.len) {
        return key[12 .. key.len - 1];
    }
    const plain_length: usize = le16(key, 8);
    if (plain_length != 0 and plain_length + 10 == key.len) {
        return key[10 .. key.len - 1];
    }
    return null;
}

// Keep the bounded writer workspace out of the kernel stack. Each record owns
// fixed key/value storage so loading an APFS tree never needs heap allocation.
const max_native_records = 2048;
const max_native_record_bytes = 272;
const FsRecord = struct {
    key: [max_native_record_bytes]u8 = @splat(0),
    value: [max_native_record_bytes]u8 = @splat(0),
    key_len: u16 = 0,
    value_len: u16 = 0,
};
const RecordSet = struct { records: [max_native_records]FsRecord = @splat(.{}), count: usize = 0, failed: bool = false };
var native_record_workspace: RecordSet = .{};
const NativeTreePlan = struct {
    starts: [max_native_records]usize = @splat(0),
    ends: [max_native_records]usize = @splat(0),
    page_count: usize = 0,
    internal_root: bool = false,
};

fn collectRecord(context_ptr: *anyopaque, key: []const u8, value: []const u8) bool {
    const set: *RecordSet = @ptrCast(@alignCast(context_ptr));
    if (set.count == set.records.len or key.len > max_native_record_bytes or value.len > max_native_record_bytes) {
        set.failed = true;
        return false;
    }
    var record = FsRecord{};
    @memcpy(record.key[0..key.len], key);
    @memcpy(record.value[0..value.len], value);
    record.key_len = @intCast(key.len);
    record.value_len = @intCast(value.len);
    set.records[set.count] = record;
    set.count += 1;
    return true;
}

fn recordLess(a: FsRecord, b: FsRecord) bool {
    const akey = a.key[0..a.key_len];
    const bkey = b.key[0..b.key_len];
    if (akey.len < 8 or bkey.len < 8) return akey.len < bkey.len;
    const aheader = le64(akey, 0);
    const bheader = le64(bkey, 0);
    const aoid = aheader & 0x0fff_ffff_ffff_ffff;
    const boid = bheader & 0x0fff_ffff_ffff_ffff;
    if (aoid != boid) return aoid < boid;
    const atype = aheader >> 60;
    const btype = bheader >> 60;
    if (atype != btype) return atype < btype;
    const aextra = akey[8..];
    const bextra = bkey[8..];
    // APFS file-extent records are ordered by their numeric logical byte
    // address, not by the little-endian byte encoding of that address.
    if (atype == 8 and aextra.len >= 8 and bextra.len >= 8) return le64(akey, 8) < le64(bkey, 8);
    const common = @min(aextra.len, bextra.len);
    for (0..common) |i| if (aextra[i] != bextra[i]) return aextra[i] < bextra[i];
    return aextra.len < bextra.len;
}

fn sortRecords(set: *RecordSet) void {
    for (1..set.count) |i| {
        const item = set.records[i];
        var j = i;
        while (j > 0 and recordLess(item, set.records[j - 1])) : (j -= 1) set.records[j] = set.records[j - 1];
        set.records[j] = item;
    }
}

fn loadNativeRecords(volume: Volume) bool {
    if (!volume.native_formatted) {
        last_operation_error = "APFS writer journal was not recognized";
        return false;
    }
    if (!readBlock(volume.container, volume.root_tree_block, io_block[0..volume.container.block_size])) {
        last_operation_error = "APFS root tree read failed";
        return false;
    }
    if (!hasValidChecksum(io_block[0..volume.container.block_size])) {
        last_operation_error = "APFS root tree checksum failed";
        return false;
    }
    native_record_workspace = .{};
    if (!walkFsRecords(volume, collectRecord, @ptrCast(&native_record_workspace)) or native_record_workspace.failed) {
        last_operation_error = "APFS filesystem tree traversal failed";
        return false;
    }
    return true;
}

fn recordsRangeFits(set: *const RecordSet, first: usize, end: usize, block_size: usize, root: bool) bool {
    if (first >= end or end > set.count) return false;
    const count = end - first;
    const footer: usize = if (root) 40 else 0;
    var used: usize = 56 + count * 8;
    for (set.records[first..end]) |record| {
        used = std.math.add(usize, used, record.key_len) catch return false;
        used = std.math.add(usize, used, record.value_len) catch return false;
    }
    return used <= block_size - footer;
}

fn planNativeTree(set: *const RecordSet, block_size: usize) ?NativeTreePlan {
    if (set.count == 0) return null;
    var plan = NativeTreePlan{};
    if (recordsRangeFits(set, 0, set.count, block_size, true)) {
        plan.starts[0] = 0;
        plan.ends[0] = set.count;
        plan.page_count = 1;
        return plan;
    }

    plan.internal_root = true;
    var first: usize = 0;
    while (first < set.count) {
        if (plan.page_count == plan.starts.len) return null;
        var end = first + 1;
        while (end <= set.count and recordsRangeFits(set, first, end, block_size, false)) : (end += 1) {}
        end -= 1;
        if (end == first) return null;
        const page = plan.page_count;
        plan.starts[page] = first;
        plan.ends[page] = end;
        plan.page_count += 1;
        first = end;
    }
    var root_used: usize = 56 + plan.page_count * 8 + 40;
    for (0..plan.page_count) |page| root_used += set.records[plan.starts[page]].key_len + 8;
    if (root_used > block_size) return null;
    return plan;
}

fn packNativeNode(volume: Volume, set: *const RecordSet, first: usize, end: usize, oid: u64, xid: u64, root: bool, output: []u8) bool {
    const block_len = output.len;
    const footer: usize = if (root) 40 else 0;
    const count = end - first;
    if (count == 0 or !recordsRangeFits(set, first, end, block_len, root)) return false;
    @memset(output, 0);
    put64(output, 8, oid);
    put64(output, 16, xid);
    put32(output, 24, 0x00000002);
    put32(output, 28, 0x0e);
    put16(output, 32, if (root) 3 else 2); // root|leaf or leaf
    put16(output, 34, 0);
    put32(output, 36, @intCast(count));
    put16(output, 40, 0);
    put16(output, 42, @intCast(count * 8));
    const key_base = 56 + count * 8;
    var key_cursor: usize = 0;
    var value_cursor: usize = 0;
    for (set.records[first..end], 0..) |record, local_index| {
        const key = record.key[0..record.key_len];
        const value = record.value[0..record.value_len];
        const toc = 56 + local_index * 8;
        const key_start = key_base + key_cursor;
        const value_end = block_len - footer - value_cursor;
        if (key_start > value_end or key.len > value_end - key_start or value.len > value_end - key_start - key.len) return false;
        put16(output, toc, @intCast(key_cursor));
        put16(output, toc + 2, @intCast(key.len));
        put16(output, toc + 4, @intCast(value_cursor));
        put16(output, toc + 6, @intCast(value.len));
        @memcpy(output[key_start .. key_start + key.len], key);
        const value_start = value_end - value.len;
        @memcpy(output[value_start..value_end], value);
        key_cursor += key.len;
        value_cursor += value.len;
    }
    if (root) {
        const info = block_len - 40;
        put32(output, info + 4, volume.container.block_size);
        put64(output, info + 24, set.count);
        put64(output, info + 32, 1);
    }
    put64(output, 0, fletcher64(output[8..]));
    return true;
}

fn packNativeInternalRoot(volume: Volume, set: *const RecordSet, plan: NativeTreePlan, first_leaf_oid: u64, xid: u64, output: []u8) bool {
    const count = plan.page_count;
    const block_len = output.len;
    const footer: usize = 40;
    var key_bytes: usize = 0;
    for (0..count) |page| key_bytes += set.records[plan.starts[page]].key_len;
    if (56 + count * 8 + key_bytes + count * 8 > block_len - footer) return false;
    @memset(output, 0);
    put64(output, 8, volume.root_tree_oid);
    put64(output, 16, xid);
    put32(output, 24, 2);
    put32(output, 28, 0x0e);
    put16(output, 32, 1); // root internal node
    put16(output, 34, 1);
    put32(output, 36, @intCast(count));
    put16(output, 40, 0);
    put16(output, 42, @intCast(count * 8));
    const key_base = 56 + count * 8;
    var key_cursor: usize = 0;
    var value_cursor: usize = 0;
    for (0..count) |page| {
        const record = set.records[plan.starts[page]];
        const key = record.key[0..record.key_len];
        const toc = 56 + page * 8;
        const value_end = block_len - footer - value_cursor;
        if (key_base + key_cursor + key.len > value_end - 8) return false;
        put16(output, toc, @intCast(key_cursor));
        put16(output, toc + 2, @intCast(key.len));
        put16(output, toc + 4, @intCast(value_cursor));
        put16(output, toc + 6, 8);
        @memcpy(output[key_base + key_cursor .. key_base + key_cursor + key.len], key);
        put64(output, value_end - 8, first_leaf_oid + page);
        key_cursor += key.len;
        value_cursor += 8;
    }
    const info = block_len - footer;
    put32(output, info + 4, volume.container.block_size);
    put64(output, info + 24, set.count);
    put64(output, info + 32, count + 1);
    put64(output, 0, fletcher64(output[8..]));
    return true;
}

const OmapMapping = struct { object_id: u64, physical_block: u64 };

fn buildOmapTree(oid: u64, xid: u64, mappings: []const OmapMapping, output: []u8) bool {
    if (mappings.len == 0 or 56 + mappings.len * 4 + mappings.len * 32 > output.len - 40) return false;
    @memset(output, 0);
    put64(output, 8, oid);
    put64(output, 16, xid);
    put32(output, 24, 0x40000002);
    put32(output, 28, 0x0b); // OBJECT_TYPE_OMAP
    put16(output, 32, 7); // root | leaf | fixed key/value
    put16(output, 34, 0);
    put32(output, 36, @intCast(mappings.len));
    put16(output, 40, 0);
    put16(output, 42, @intCast(mappings.len * 4));
    const key_base = 56 + mappings.len * 4;
    for (mappings, 0..) |mapping, index| {
        const toc = 56 + index * 4;
        put16(output, toc, @intCast(index * 16));
        put16(output, toc + 2, @intCast(index * 16));
        const key = key_base + index * 16;
        put64(output, key, mapping.object_id);
        put64(output, key + 8, xid);
        const value_end = output.len - 40 - index * 16;
        const value = value_end - 16;
        put32(output, value + 4, @intCast(output.len));
        put64(output, value + 8, mapping.physical_block);
    }
    const info = output.len - 40;
    put32(output, info + 4, @intCast(output.len));
    put64(output, info + 24, mappings.len);
    put64(output, info + 32, 1);
    put64(output, 0, fletcher64(output[8..]));
    return true;
}

fn buildUpdatedContainerOmap(volume: Volume, oid: u64, xid: u64, updated_volume_block: u64, output: []u8) bool {
    var omap_object: Block = undefined;
    if (!readBlock(volume.container, volume.container.omap_block, omap_object[0..volume.container.block_size])) return false;
    const object_bytes = omap_object[0..volume.container.block_size];
    if (!hasValidChecksum(object_bytes) or (le32(object_bytes, 24) & 0xffff) != 0x0b) return false;
    const old_tree = le64(object_bytes, 48);
    if (old_tree == 0 or old_tree >= volume.container.block_count) return false;

    var mappings: [100]OmapMapping = undefined;
    var mapping_count: usize = 0;
    var found_volume = false;
    for (volume.container.volume_oids) |volume_oid| {
        if (volume_oid == 0) continue;
        if (mapping_count == mappings.len) return false;
        var physical_block = updated_volume_block;
        if (volume_oid == volume.object_id) {
            found_volume = true;
        } else {
            const resolved = lookupOmap(volume.container, old_tree, volume_oid, volume.container.xid) orelse return false;
            if ((resolved.flags & 1) != 0) continue;
            if (resolved.paddr >= volume.container.block_count) return false;
            physical_block = resolved.paddr;
        }
        mappings[mapping_count] = .{ .object_id = volume_oid, .physical_block = physical_block };
        mapping_count += 1;
    }
    return found_volume and buildOmapTree(oid, xid, mappings[0..mapping_count], output);
}

fn buildOmapObject(oid: u64, xid: u64, tree_block: u64, output: []u8) void {
    @memset(output, 0);
    put64(output, 8, oid);
    put64(output, 16, xid);
    put32(output, 24, 0x4000000b);
    put32(output, 40, 0x40000002);
    put64(output, 48, tree_block);
    put64(output, 0, fletcher64(output[8..]));
}

fn buildCheckpointMap(paddr: u64, xid: u64, spaceman_oid: u64, spaceman_paddr: u64, reaper_oid: u64, reaper_paddr: u64, output: []u8) void {
    @memset(output, 0);
    put64(output, 8, paddr);
    put64(output, 16, xid);
    put32(output, 24, 0x4000000c);
    put32(output, 32, 1); // CHECKPOINT_MAP_LAST
    put32(output, 36, 2);
    put32(output, 40, 0x80000005);
    put32(output, 48, @intCast(output.len));
    put64(output, 64, spaceman_oid);
    put64(output, 72, spaceman_paddr);
    put32(output, 80, 0x80000011);
    put32(output, 88, @intCast(output.len));
    put64(output, 104, reaper_oid);
    put64(output, 112, reaper_paddr);
    put64(output, 0, fletcher64(output[8..]));
}

const apfs_blocks_per_chunk: u64 = 32768;
const apfs_cib_capacity: u64 = 126;

fn buildSpaceman(oid: u64, xid: u64, block_size: u32, block_count: u64, free_blocks: u64, cib_paddr: u64, output: []u8) void {
    @memset(output, 0);
    put64(output, 8, oid);
    put64(output, 16, xid);
    put32(output, 24, 0x80000005);
    put32(output, 32, block_size);
    put32(output, 36, @intCast(apfs_blocks_per_chunk));
    put32(output, 40, 126);
    put32(output, 44, 1);
    put64(output, 48, block_count);
    const chunks = (block_count + apfs_blocks_per_chunk - 1) / apfs_blocks_per_chunk;
    put64(output, 56, chunks);
    put32(output, 64, 1);
    put64(output, 72, free_blocks);
    put32(output, 80, 2496); // inline SD_MAIN CIB address array
    put32(output, 312, 1);
    put32(output, 316, 2496);
    put64(output, 2496, cib_paddr);
    put64(output, 0, fletcher64(output[8..]));
}

fn buildSpacemanCib(paddr: u64, xid: u64, block_count: u64, first_bitmap: u64, output: []u8) bool {
    const chunks = (block_count + apfs_blocks_per_chunk - 1) / apfs_blocks_per_chunk;
    if (chunks == 0 or chunks > apfs_cib_capacity or output.len < 40 + chunks * 32) return false;
    @memset(output, 0);
    put64(output, 8, paddr);
    put64(output, 16, xid);
    put32(output, 24, 0x40000007);
    put32(output, 32, 0);
    put32(output, 36, @intCast(chunks));
    for (0..chunks) |index| {
        const start = @as(u64, index) * apfs_blocks_per_chunk;
        const count = @min(apfs_blocks_per_chunk, block_count - start);
        var free_count: u32 = 0;
        for (0..count) |local| if (!bitmapIsAllocated(start + local)) {
            free_count += 1;
        };
        const entry = 40 + index * 32;
        put64(output, entry, xid);
        put64(output, entry + 8, start);
        put32(output, entry + 16, @intCast(count));
        put32(output, entry + 20, free_count);
        put64(output, entry + 24, first_bitmap + index);
    }
    put64(output, 0, fletcher64(output[8..]));
    return true;
}

fn buildSpacemanBitmap(block_count: u64, chunk_index: u64, output: []u8) bool {
    const chunks = (block_count + native_chunk_blocks - 1) / native_chunk_blocks;
    if (block_count != native_allocator_block_count or output.len != native_chunk_bitmap_bytes or chunk_index >= chunks or chunks > native_max_chunks) return false;
    const start: usize = @intCast(chunk_index * native_chunk_bitmap_bytes);
    @memcpy(output, native_allocation_bitmap[start .. start + native_chunk_bitmap_bytes]);
    return true;
}

fn buildEmptyReaper(oid: u64, xid: u64, output: []u8) void {
    @memset(output, 0);
    put64(output, 8, oid);
    put64(output, 16, xid);
    put32(output, 24, 0x80000011);
    put64(output, 32, 1);
    put32(output, 64, 1);
    put32(output, 108, @intCast(output.len - 112));
    put64(output, 0, fletcher64(output[8..]));
}

const InodeCounts = struct { files: u64 = 0, directories: u64 = 0, symlinks: u64 = 0, other: u64 = 0 };
fn countInodes(set: *const RecordSet) ?InodeCounts {
    var counts = InodeCounts{};
    for (set.records[0..set.count]) |record| {
        const key = record.key[0..record.key_len];
        const value = record.value[0..record.value_len];
        if (key.len < 8 or value.len < 82) continue;
        const header = le64(key, 0);
        if ((header >> 60) != 3) continue;
        const mode = le16(value, 80) & 0xf000;
        if (mode == 0x8000) {
            counts.files = std.math.add(u64, counts.files, 1) catch return null;
        } else if (mode == 0x4000) {
            counts.directories = std.math.add(u64, counts.directories, 1) catch return null;
        } else if (mode == 0xa000) {
            counts.symlinks = std.math.add(u64, counts.symlinks, 1) catch return null;
        } else {
            counts.other = std.math.add(u64, counts.other, 1) catch return null;
        }
    }
    return counts;
}

/// Commit a native-volume metadata change with fresh filesystem-tree, OMAP,
/// volume-superblock, and container-OMAP blocks. NXSB is written last.
fn saveNativeRecords(volume: Volume, set: *RecordSet, next_oid: u64, allocated_data_blocks: u64, bitmap_preloaded: bool, freed: ?*const NativeFreedSet) bool {
    const next_xid = std.math.add(u64, @max(volume.allocator_xid, volume.xid), 1) catch return false;
    if (next_xid == std.math.maxInt(u64)) return false;
    if (volume.container.has_checkpoint and volume.container.checkpoint_desc_blocks != native_journal_capacity * 2) {
        last_operation_error = "APFS checkpoint descriptor ring size is unsupported by the writer";
        return false;
    }
    if (!bitmap_preloaded and !loadNativeAllocationBitmap(volume.container)) return false;
    if (!validateFreedRanges(freed)) {
        last_operation_error = "APFS freed extent validation failed";
        return false;
    }
    const freed_data_blocks = freedBlockCount(freed) orelse return false;
    var evicted_metadata: ?NativeMetadataRun = null;
    if (volume.container.has_checkpoint and volume.metadata_journal_count == native_journal_capacity) {
        evicted_metadata = volume.metadata_journal[0];
        if (!validMetadataRun(evicted_metadata.?, volume.container) or !validateMetadataRunBitmap(evicted_metadata.?)) return false;
    }
    sortRecords(set);
    const plan = planNativeTree(set, volume.container.block_size) orelse {
        last_operation_error = "APFS filesystem tree exceeds the native writer limits";
        return false;
    };
    const root_offset: u64 = if (plan.internal_root) plan.page_count else 0;
    // root/OMAP/APSB/container OMAP plus one CIB and the per-chunk bitmap
    // blocks form one append-only checkpoint transaction.
    const chunks = (volume.container.block_count + apfs_blocks_per_chunk - 1) / apfs_blocks_per_chunk;
    if (chunks == 0 or chunks > native_max_chunks or volume.container.block_size != 4096) {
        last_operation_error = "APFS volume geometry exceeds the native writer limits";
        return false;
    }
    const block_count = root_offset + 7 + chunks;
    const first_meta = reserveNativeRun(block_count, false) orelse {
        last_operation_error = "APFS has no contiguous metadata allocation run";
        return false;
    };
    if (first_meta + block_count >= volume.container.block_count - 1) return false;
    if (plan.internal_root and next_oid > 0x0fff_ffff_ffff_ffff - plan.page_count) return false;
    const counts = countInodes(set) orelse return false;
    const tree_node_count = if (plan.internal_root) plan.page_count + 1 else 1;
    const allocated_volume_blocks = std.math.add(u64, 3 + tree_node_count, allocated_data_blocks) catch return false;
    const evicted_volume_blocks = if (evicted_metadata) |run| run.volume_block_count else 0;
    const root_block = first_meta + root_offset;
    const persisted_next_oid = next_oid + (if (plan.internal_root) plan.page_count else 0);

    // Write COW filesystem-tree leaves first. Their virtual OIDs are reserved
    // from the same monotonically increasing object-ID stream as file objects.
    if (plan.internal_root) {
        for (0..plan.page_count) |page| {
            const leaf_oid = next_oid + page;
            if (!packNativeNode(volume, set, plan.starts[page], plan.ends[page], leaf_oid, next_xid, false, io_block[0..volume.container.block_size])) return false;
            if (!writeBlock(volume.container, first_meta + page, io_block[0..volume.container.block_size])) return false;
        }
        if (!packNativeInternalRoot(volume, set, plan, next_oid, next_xid, io_block[0..volume.container.block_size])) return false;
        if (!writeBlock(volume.container, root_block, io_block[0..volume.container.block_size])) return false;
    } else {
        if (!packNativeNode(volume, set, plan.starts[0], plan.ends[0], volume.root_tree_oid, next_xid, true, io_block[0..volume.container.block_size])) return false;
        if (!writeBlock(volume.container, root_block, io_block[0..volume.container.block_size])) return false;
    }

    // New fs-tree root and volume OMAP mapping.
    var fs_mappings: [max_native_records + 1]OmapMapping = undefined;
    fs_mappings[0] = .{ .object_id = volume.root_tree_oid, .physical_block = root_block };
    if (plan.internal_root) for (0..plan.page_count) |page| {
        fs_mappings[page + 1] = .{ .object_id = next_oid + page, .physical_block = first_meta + page };
    };
    const fs_mapping_count = 1 + (if (plan.internal_root) plan.page_count else 0);
    const volume_omap_tree = root_block + 1;
    const volume_omap_object = root_block + 2;
    const volume_superblock = root_block + 3;
    const container_omap_tree = root_block + 4;
    const container_omap_object = root_block + 5;
    if (!buildOmapTree(volume_omap_tree, next_xid, fs_mappings[0..fs_mapping_count], io_block[0..volume.container.block_size])) return false;
    if (!writeBlock(volume.container, volume_omap_tree, io_block[0..volume.container.block_size])) return false;
    buildOmapObject(volume_omap_object, next_xid, volume_omap_tree, io_block[0..volume.container.block_size]);
    if (!writeBlock(volume.container, volume_omap_object, io_block[0..volume.container.block_size])) return false;

    // New APFS volume superblock points at the new volume OMAP.
    if (!readBlock(volume.container, volume.superblock_block, io_block[0..volume.container.block_size])) return false;
    put64(io_block[0..], 16, next_xid);
    put32(io_block[0..], 116, 0x00000002); // virtual OBJECT_TYPE_BTREE root
    put64(io_block[0..], 128, volume_omap_object);
    put64(io_block[0..], 176, persisted_next_oid); // apfs_next_obj_id
    put64(io_block[0..], 184, counts.files);
    put64(io_block[0..], 192, counts.directories);
    put64(io_block[0..], 200, counts.symlinks);
    put64(io_block[0..], 208, counts.other);
    const current_allocated = le64(io_block[0..], 88);
    const total_allocated = le64(io_block[0..], 224);
    const freed_volume_blocks = std.math.add(u64, freed_data_blocks, evicted_volume_blocks) catch return false;
    put64(io_block[0..], 88, std.math.sub(u64, std.math.add(u64, current_allocated, allocated_volume_blocks) catch return false, freed_volume_blocks) catch return false);
    put64(io_block[0..], 224, std.math.sub(u64, std.math.add(u64, total_allocated, allocated_volume_blocks) catch return false, freed_volume_blocks) catch return false);
    put64(io_block[0..], 0, fletcher64(io_block[8..volume.container.block_size]));
    if (!writeBlock(volume.container, volume_superblock, io_block[0..volume.container.block_size])) return false;

    // Keep all container volumes addressable when publishing this volume's
    // new superblock through a copy-on-write container OMAP.
    if (!buildUpdatedContainerOmap(volume, container_omap_tree, next_xid, volume_superblock, io_block[0..volume.container.block_size])) return false;
    if (!writeBlock(volume.container, container_omap_tree, io_block[0..volume.container.block_size])) return false;
    buildOmapObject(container_omap_object, next_xid, container_omap_tree, io_block[0..volume.container.block_size]);
    if (!writeBlock(volume.container, container_omap_object, io_block[0..volume.container.block_size])) return false;

    const cib_paddr = root_block + 6;
    const first_bitmap_paddr = root_block + 7;
    var spaceman_paddr: u64 = 0;
    var reaper_paddr: u64 = 0;
    var next_data_index = volume.container.checkpoint_data_index;
    var free_after: u64 = volume.container.free_block_count;
    if (volume.container.has_checkpoint) {
        if (!clearFreedRanges(freed)) return false;
        if (evicted_metadata) |run| if (!clearMetadataRunBitmap(run)) return false;
        free_after = nativeBitmapFreeCount();
        if (!buildSpacemanCib(cib_paddr, next_xid, volume.container.block_count, first_bitmap_paddr, io_block[0..volume.container.block_size])) return false;
        if (!writeBlock(volume.container, cib_paddr, io_block[0..volume.container.block_size])) return false;
        for (0..chunks) |chunk| {
            if (!buildSpacemanBitmap(volume.container.block_count, chunk, io_block[0..volume.container.block_size])) return false;
            if (!writeBlock(volume.container, first_bitmap_paddr + chunk, io_block[0..volume.container.block_size])) return false;
        }
    }

    // Record the pending COW transaction before publishing its checkpoint.
    // After a reset, the volume XID decides whether to discard this entry or
    // fold it into the committed metadata history.
    if (!readBlock(volume.container, volume.container.block_count - 1, io_block[0..volume.container.block_size])) {
        last_operation_error = "APFS allocator journal block read failed";
        return false;
    }
    const legacy_allocator_marker = std.mem.eql(u8, io_block[0..8], "AETHAPFS") and le32(io_block[8..], 0) == 1;
    const journal_allocator_marker = le32(io_block[8..], 0) == 2 and hasValidChecksum(io_block[0..volume.container.block_size]) and
        (std.mem.eql(u8, io_block[344..352], "AETHAPFS") or !std.mem.eql(u8, io_block[0..8], "AETHAPFS"));
    if (!legacy_allocator_marker and !journal_allocator_marker) {
        last_operation_error = "APFS allocator journal marker is invalid";
        return false;
    }
    const metadata_run = NativeMetadataRun{
        .xid = next_xid,
        .first_block = first_meta,
        .block_count = block_count,
        .volume_block_count = 3 + tree_node_count,
    };
    const pending_run = if (volume.container.has_checkpoint) metadata_run else NativeMetadataRun{};
    if (!buildAllocatorJournal(io_block[0..volume.container.block_size], persisted_next_oid, volume.next_data_block, @max(volume.next_metadata_block, first_meta + block_count), next_xid, volume.metadata_journal[0..volume.metadata_journal_count], pending_run)) {
        last_operation_error = "APFS allocator journal packing failed";
        return false;
    }
    if (!writeBlock(volume.container, volume.container.block_count - 1, io_block[0..volume.container.block_size]) or !ata.flushCache(volume.container.device)) {
        last_operation_error = "APFS pending allocator journal write failed";
        return false;
    }

    const next_container_oid = @max(volume.container.next_object_id, persisted_next_oid);
    var next_checkpoint_index = volume.container.checkpoint_desc_index;
    var next_checkpoint_map = volume.container.checkpoint_desc_base;
    if (volume.container.has_checkpoint) {
        const desc_blocks = volume.container.checkpoint_desc_blocks;
        if (desc_blocks < 4 or volume.container.checkpoint_desc_index >= desc_blocks) {
            last_operation_error = "APFS checkpoint descriptor ring is invalid";
            return false;
        }
        const data_blocks = volume.container.checkpoint_data_blocks;
        if (data_blocks < 4 or volume.container.checkpoint_data_index >= data_blocks or volume.container.checkpoint_data_len < 2 or volume.container.checkpoint_data_len > data_blocks) {
            last_operation_error = "APFS checkpoint data ring is invalid";
            return false;
        }
        next_checkpoint_index = (volume.container.checkpoint_desc_index + 2) % desc_blocks;
        next_checkpoint_map = volume.container.checkpoint_desc_base + next_checkpoint_index;
        if (next_checkpoint_map + 1 >= volume.container.block_count) {
            last_operation_error = "APFS next checkpoint descriptor is out of range";
            return false;
        }
        next_data_index = (volume.container.checkpoint_data_index + volume.container.checkpoint_data_len) % data_blocks;
        if (next_data_index + 1 >= data_blocks) {
            last_operation_error = "APFS next checkpoint data slot is out of range";
            return false;
        }
        spaceman_paddr = volume.container.checkpoint_data_base + next_data_index;
        reaper_paddr = spaceman_paddr + 1;
        if (reaper_paddr >= volume.container.block_count) {
            last_operation_error = "APFS reaper checkpoint address is out of range";
            return false;
        }
        buildSpaceman(volume.container.spaceman_oid, next_xid, volume.container.block_size, volume.container.block_count, free_after, cib_paddr, io_block[0..volume.container.block_size]);
        if (!writeBlock(volume.container, spaceman_paddr, io_block[0..volume.container.block_size])) {
            last_operation_error = "APFS checkpoint spaceman write failed";
            return false;
        }
        buildEmptyReaper(volume.container.reaper_oid, next_xid, io_block[0..volume.container.block_size]);
        if (!writeBlock(volume.container, reaper_paddr, io_block[0..volume.container.block_size])) {
            last_operation_error = "APFS checkpoint reaper write failed";
            return false;
        }
        buildCheckpointMap(next_checkpoint_map, next_xid, volume.container.spaceman_oid, spaceman_paddr, volume.container.reaper_oid, reaper_paddr, io_block[0..volume.container.block_size]);
        if (!writeBlock(volume.container, next_checkpoint_map, io_block[0..volume.container.block_size]) or !ata.flushCache(volume.container.device)) {
            last_operation_error = "APFS checkpoint map write failed";
            return false;
        }

        // Publish a fresh NXSB in the next checkpoint pair. Block zero remains
        // the stable label that locates the descriptor ring.
        const active_nxsb_block = volume.container.checkpoint_desc_base + volume.container.checkpoint_desc_index + 1;
        if (!readBlock(volume.container, active_nxsb_block, io_block[0..volume.container.block_size])) {
            last_operation_error = "APFS active checkpoint NXSB read failed";
            return false;
        }
        if (!hasValidChecksum(io_block[0..volume.container.block_size]) or le32(io_block[32..], 0) != 0x4253_584e) {
            last_operation_error = "APFS active checkpoint NXSB is invalid";
            return false;
        }
        put64(io_block[8..], 0, 1);
        put64(io_block[16..], 0, next_xid);
        put32(io_block[24..], 0, 0x80000001);
        put64(io_block[88..], 0, next_container_oid);
        put64(io_block[96..], 0, next_xid + 1);
        put32(io_block[128..], 0, (next_checkpoint_index + 2) % desc_blocks);
        put32(io_block[132..], 0, (next_data_index + 2) % data_blocks);
        put32(io_block[136..], 0, next_checkpoint_index);
        put32(io_block[140..], 0, 2);
        put32(io_block[144..], 0, next_data_index);
        put32(io_block[148..], 0, 2);
        put64(io_block[160..], 0, container_omap_object);
        put64(io_block[0..], 0, fletcher64(io_block[8..volume.container.block_size]));
        const next_live_nxsb = next_checkpoint_map + 1;
        if (!writeBlock(volume.container, next_live_nxsb, io_block[0..volume.container.block_size]) or !ata.flushCache(volume.container.device)) {
            last_operation_error = "APFS next checkpoint NXSB publication failed";
            return false;
        }
    } else {
        // Compatibility path for older AetherOS subset images without a
        // checkpoint ring.
        if (!readBlock(volume.container, 0, io_block[0..volume.container.block_size])) return false;
        put64(io_block[16..], 0, next_xid);
        put64(io_block[88..], 0, next_container_oid);
        put64(io_block[96..], 0, next_xid + 1);
        put64(io_block[160..], 0, container_omap_object);
        put64(io_block[0..], 0, fletcher64(io_block[8..volume.container.block_size]));
        if (!writeBlock(volume.container, 0, io_block[0..volume.container.block_size]) or !ata.flushCache(volume.container.device)) return false;
    }

    var committed_metadata = volume.metadata_journal;
    var committed_metadata_count: usize = volume.metadata_journal_count;
    if (volume.container.has_checkpoint) {
        if (evicted_metadata != null) {
            for (1..committed_metadata_count) |index| committed_metadata[index - 1] = committed_metadata[index];
            committed_metadata_count -= 1;
        }
        if (committed_metadata_count == native_journal_capacity) return false;
        committed_metadata[committed_metadata_count] = metadata_run;
        committed_metadata_count += 1;
        // The NXSB is already durable. If this final journal write is lost,
        // mount-time recovery recognizes the pending entry by matching XIDs.
        if (buildAllocatorJournal(io_block[0..volume.container.block_size], persisted_next_oid, volume.next_data_block, @max(volume.next_metadata_block, first_meta + block_count), next_xid, committed_metadata[0..committed_metadata_count], .{})) {
            if (writeBlock(volume.container, volume.container.block_count - 1, io_block[0..volume.container.block_size])) _ = ata.flushCache(volume.container.device);
        }
    }

    var updated = volume;
    updated.xid = next_xid;
    updated.superblock_block = volume_superblock;
    updated.omap_block = volume_omap_object;
    updated.omap_tree_block = volume_omap_tree;
    updated.root_tree_block = root_block;
    updated.next_object_id = persisted_next_oid;
    updated.next_metadata_block = @max(volume.next_metadata_block, first_meta + block_count);
    updated.allocator_xid = next_xid;
    updated.metadata_journal = committed_metadata;
    updated.metadata_journal_count = @intCast(committed_metadata_count);
    updated.pending_metadata_run = .{};
    updated.container.xid = next_xid;
    updated.container.next_object_id = next_container_oid;
    updated.container.omap_block = container_omap_object;
    if (volume.container.has_checkpoint) {
        updated.container.spaceman_block = spaceman_paddr;
        updated.container.reaper_block = reaper_paddr;
        updated.container.free_block_count = free_after;
        updated.container.checkpoint_desc_index = next_checkpoint_index;
        updated.container.checkpoint_data_index = next_data_index;
    }
    mounted_volume = updated;
    return true;
}

fn findRecordIndex(set: *const RecordSet, oid: u64, record_type: u4, name: ?[]const u8) ?usize {
    for (set.records[0..set.count], 0..) |record, index| {
        const key = record.key[0..record.key_len];
        if (key.len < 8) continue;
        const header = le64(key, 0);
        if ((header & 0x0fff_ffff_ffff_ffff) != oid or (header >> 60) != record_type) continue;
        if (name) |wanted| {
            const stored = directoryName(key) orelse continue;
            if (!std.mem.eql(u8, stored, wanted)) continue;
        }
        return index;
    }
    return null;
}

fn removeRecord(set: *RecordSet, index: usize) void {
    if (index + 1 < set.count) std.mem.copyForwards(FsRecord, set.records[index .. set.count - 1], set.records[index + 1 .. set.count]);
    set.count -= 1;
}

fn appendRecord(set: *RecordSet, key: []const u8, value: []const u8) bool {
    if (set.count == set.records.len or key.len > max_native_record_bytes or value.len > max_native_record_bytes) return false;
    var record = FsRecord{};
    @memcpy(record.key[0..key.len], key);
    @memcpy(record.value[0..value.len], value);
    record.key_len = @intCast(key.len);
    record.value_len = @intCast(value.len);
    set.records[set.count] = record;
    set.count += 1;
    return true;
}

fn recordsFit(set: *const RecordSet, block_size: usize) bool {
    return planNativeTree(set, block_size) != null;
}

fn writeNativeDataRun(volume: Volume, data: []const u8, logical_offset: usize, byte_len: usize, first_block: u64) bool {
    const block_size: usize = volume.container.block_size;
    if (logical_offset > data.len or byte_len > data.len - logical_offset) return false;
    var offset: usize = 0;
    var block_number = first_block;
    while (offset < byte_len) : (block_number += 1) {
        @memset(io_block[0..block_size], 0);
        const amount = @min(block_size, byte_len - offset);
        const source = logical_offset + offset;
        @memcpy(io_block[0..amount], data[source .. source + amount]);
        if (!writeBlock(volume.container, block_number, io_block[0..block_size])) return false;
        offset += amount;
    }
    return true;
}

fn makeInodeRecord(set: *RecordSet, oid: u64, parent_oid: u64, is_directory: bool, stream_oid: u64, file_size: u64, allocated_size: u64) bool {
    var key: [8]u8 = @splat(0);
    put64(&key, 0, (@as(u64, 3) << 60) | oid);
    if (is_directory) {
        var value: [96]u8 = @splat(0);
        put64(&value, 0, parent_oid);
        put32(&value, 56, 0); // nchildren / nlink
        put16(&value, 80, 0x41ed); // S_IFDIR | 0755
        return appendRecord(set, &key, &value);
    }
    var value: [144]u8 = @splat(0);
    put64(&value, 0, parent_oid);
    put64(&value, 8, stream_oid);
    put32(&value, 56, 1);
    put16(&value, 80, 0x81a4); // S_IFREG | 0644
    put16(&value, 92, 1); // one xfield
    put16(&value, 94, 40); // xfield payload bytes
    value[96] = 8; // INO_EXT_TYPE_DSTREAM
    put16(&value, 98, 40);
    put64(&value, 104, file_size);
    put64(&value, 112, allocated_size);
    put64(&value, 120, 0); // default crypto id
    return appendRecord(set, &key, &value);
}

fn makeDirectoryRecord(set: *RecordSet, parent_oid: u64, name: []const u8, child_oid: u64, is_directory: bool) bool {
    var key: [280]u8 = @splat(0);
    const key_len = buildDrecKey(parent_oid, name, &key) orelse return false;
    var value: [18]u8 = @splat(0);
    put64(&value, 0, child_oid);
    put16(&value, 16, if (is_directory) 4 else 8);
    return appendRecord(set, key[0..key_len], &value);
}

fn makeExtentRecord(set: *RecordSet, stream_oid: u64, logical_offset: u64, first_block: u64, byte_len: usize) bool {
    if (byte_len == 0) return true;
    var key: [16]u8 = @splat(0);
    put64(&key, 0, (@as(u64, 8) << 60) | stream_oid);
    put64(&key, 8, logical_offset);
    var value: [24]u8 = @splat(0);
    put64(&value, 0, byte_len);
    put64(&value, 8, first_block);
    return appendRecord(set, &key, &value);
}

fn objectIdForName(set: *const RecordSet, parent_oid: u64, name: []const u8) ?struct { oid: u64, kind: u16 } {
    const index = findRecordIndex(set, parent_oid, 9, name) orelse return null;
    const value = set.records[index].value[0..set.records[index].value_len];
    if (value.len < 18) return null;
    return .{ .oid = le64(value, 0), .kind = le16(value, 16) & 0x0f };
}

fn adjustDirectoryChildren(set: *RecordSet, directory_oid: u64, increase: bool) bool {
    const index = findRecordIndex(set, directory_oid, 3, null) orelse return false;
    const value = set.records[index].value[0..set.records[index].value_len];
    if (value.len < 60 or le16(value, 80) & 0xf000 != 0x4000) return false;
    const old_count = le32(value, 56);
    const new_count = if (increase) std.math.add(u32, old_count, 1) catch return false else std.math.sub(u32, old_count, 1) catch return false;
    put32(value, 56, new_count);
    return true;
}

fn nativeMakeDirectory(volume: Volume, parent_oid: u64, name: []const u8) bool {
    last_operation_error = "APFS directory operation failed";
    if (!volume.unencrypted or volume.snapshot_count != 0) {
        last_operation_error = "APFS volume is encrypted or has snapshots";
        return false;
    }
    if (!loadNativeRecords(volume)) return false;
    const set = &native_record_workspace;
    if (findRecordIndex(set, parent_oid, 9, name) != null) return false;
    const child_oid = volume.next_object_id;
    if (child_oid < 3 or child_oid >= 0x0fff_ffff_ffff_ffff) return false;
    if (!makeInodeRecord(set, child_oid, parent_oid, true, 0, 0, 0) or
        !makeDirectoryRecord(set, parent_oid, name, child_oid, true) or
        !adjustDirectoryChildren(set, parent_oid, true)) return false;
    if (!recordsFit(set, volume.container.block_size)) {
        last_operation_error = "APFS directory records do not fit the native tree";
        return false;
    }
    last_operation_error = "APFS metadata commit failed";
    return saveNativeRecords(volume, set, child_oid + 1, 0, false, null);
}

fn nativeWriteFile(volume: Volume, parent_oid: u64, name: []const u8, data: []const u8) bool {
    if (!volume.unencrypted or volume.snapshot_count != 0) return false;
    if (!loadNativeRecords(volume)) return false;
    const set = &native_record_workspace;
    var next_oid = volume.next_object_id;
    var file_oid: u64 = undefined;
    var stream_oid: u64 = undefined;
    var is_new = true;
    var freed = NativeFreedSet{};
    if (objectIdForName(set, parent_oid, name)) |existing| {
        if (existing.kind != 8) return false;
        is_new = false;
        file_oid = existing.oid;
        const inode_index = findRecordIndex(set, file_oid, 3, null) orelse return false;
        const inode_value = set.records[inode_index].value[0..set.records[inode_index].value_len];
        if (inode_value.len < 96 or le16(inode_value, 80) & 0xf000 != 0x8000) return false;
        stream_oid = le64(inode_value, 8);
        if (!collectStreamExtents(set, stream_oid, volume.container.block_size, &freed)) return false;
        removeRecord(set, inode_index);
        var index: usize = set.count;
        while (index > 0) {
            index -= 1;
            const key = set.records[index].key[0..set.records[index].key_len];
            if (key.len >= 8 and (le64(key, 0) >> 60) == 8 and (le64(key, 0) & 0x0fff_ffff_ffff_ffff) == stream_oid) removeRecord(set, index);
        }
    } else {
        // A directory record with a malformed value still occupies the name;
        // refuse to create a duplicate key over damaged metadata.
        if (findRecordIndex(set, parent_oid, 9, name) != null) return false;
        if (next_oid < 3 or next_oid >= 0x0fff_ffff_ffff_fffd) return false;
        file_oid = next_oid;
        stream_oid = next_oid + 1;
        next_oid += 2;
    }

    const block_size: usize = volume.container.block_size;
    const blocks = if (data.len == 0) 0 else (data.len - 1) / block_size + 1;
    if (!loadNativeAllocationBitmap(volume.container)) return false;
    const allocated_size: u64 = @as(u64, @intCast(blocks)) * volume.container.block_size;
    if (!makeInodeRecord(set, file_oid, parent_oid, false, stream_oid, data.len, allocated_size) or
        (is_new and !makeDirectoryRecord(set, parent_oid, name, file_oid, false))) return false;
    var run_count: usize = 0;
    var logical_offset: usize = 0;
    var remaining_blocks: u64 = @intCast(blocks);
    while (remaining_blocks != 0) {
        if (run_count == native_pending_runs.len) return false;
        var run = reserveNativeRunUpTo(remaining_blocks, true) orelse return false;
        const run_bytes = std.math.mul(u64, run.block_count, volume.container.block_size) catch return false;
        const byte_len = @min(@as(u64, @intCast(data.len - logical_offset)), run_bytes);
        run.logical_offset = logical_offset;
        run.byte_len = @intCast(byte_len);
        if (!makeExtentRecord(set, stream_oid, run.logical_offset, run.first_block, run.byte_len)) return false;
        native_pending_runs[run_count] = run;
        run_count += 1;
        logical_offset += run.byte_len;
        remaining_blocks -= run.block_count;
    }
    if (is_new and !adjustDirectoryChildren(set, parent_oid, true)) return false;
    if (!recordsFit(set, volume.container.block_size)) return false;
    for (native_pending_runs[0..run_count]) |run| {
        if (!writeNativeDataRun(volume, data, run.logical_offset, run.byte_len, run.first_block)) return false;
    }
    return saveNativeRecords(volume, set, next_oid, @intCast(blocks), true, &freed);
}

fn removeNativeObject(set: *RecordSet, object_oid: u64, kind: u16, freed: *NativeFreedSet, block_size: u32) bool {
    if (kind != 4 and kind != 8) return false;
    const inode_index = findRecordIndex(set, object_oid, 3, null) orelse return false;
    const inode_value = set.records[inode_index].value[0..set.records[inode_index].value_len];
    if (inode_value.len < 82) return false;
    const mode = le16(inode_value, 80) & 0xf000;
    if ((kind == 4 and mode != 0x4000) or (kind == 8 and mode != 0x8000)) return false;
    const stream_oid = if (kind == 8) le64(inode_value, 8) else 0;
    if (kind == 8 and !collectStreamExtents(set, stream_oid, block_size, freed)) return false;
    removeRecord(set, inode_index);
    if (kind == 8) {
        var index = set.count;
        while (index > 0) {
            index -= 1;
            const key = set.records[index].key[0..set.records[index].key_len];
            if (key.len >= 8 and (le64(key, 0) >> 60) == 8 and (le64(key, 0) & 0x0fff_ffff_ffff_ffff) == stream_oid) removeRecord(set, index);
        }
    }
    return true;
}

fn deleteNativeDirectoryContents(set: *RecordSet, directory_oid: u64, depth: usize, freed: *NativeFreedSet, block_size: u32) bool {
    if (depth >= max_native_records) return false;
    while (true) {
        var child_oid: ?u64 = null;
        var child_kind: u16 = 0;
        for (set.records[0..set.count]) |record| {
            const key = record.key[0..record.key_len];
            const value = record.value[0..record.value_len];
            if (key.len < 11 or value.len < 18 or (le64(key, 0) >> 60) != 9 or (le64(key, 0) & 0x0fff_ffff_ffff_ffff) != directory_oid) continue;
            child_oid = le64(value, 0);
            child_kind = le16(value, 16) & 0x0f;
            break;
        }
        const oid = child_oid orelse return true;
        if (oid == directory_oid or (child_kind != 4 and child_kind != 8)) return false;
        if (child_kind == 4 and !deleteNativeDirectoryContents(set, oid, depth + 1, freed, block_size)) return false;

        // Re-find after recursion because descendants may have compacted the
        // transaction's record array and changed the entry's index.
        var drec_index: ?usize = null;
        for (set.records[0..set.count], 0..) |record, index| {
            const key = record.key[0..record.key_len];
            const value = record.value[0..record.value_len];
            if (key.len >= 8 and value.len >= 8 and (le64(key, 0) >> 60) == 9 and
                (le64(key, 0) & 0x0fff_ffff_ffff_ffff) == directory_oid and le64(value, 0) == oid)
            {
                drec_index = index;
                break;
            }
        }
        removeRecord(set, drec_index orelse return false);
        if (!removeNativeObject(set, oid, child_kind, freed, block_size)) return false;
    }
}

fn nativeDelete(volume: Volume, parent_oid: u64, name: []const u8, files_only: bool) bool {
    if (!volume.unencrypted or volume.snapshot_count != 0) return false;
    if (!loadNativeRecords(volume)) return false;
    const set = &native_record_workspace;
    const drec_index = findRecordIndex(set, parent_oid, 9, name) orelse return false;
    const drec_value = set.records[drec_index].value[0..set.records[drec_index].value_len];
    if (drec_value.len < 18) return false;
    const child_oid = le64(drec_value, 0);
    const kind = le16(drec_value, 16) & 0x0f;
    if (files_only and kind != 8) return false;
    if ((kind != 4 and kind != 8) or (kind == 4 and files_only)) return false;
    var freed = NativeFreedSet{};
    if (kind == 4 and !deleteNativeDirectoryContents(set, child_oid, 0, &freed, volume.container.block_size)) return false;
    if (!removeNativeObject(set, child_oid, kind, &freed, volume.container.block_size)) return false;
    const refreshed = findRecordIndex(set, parent_oid, 9, name) orelse return false;
    removeRecord(set, refreshed);
    if (!adjustDirectoryChildren(set, parent_oid, false)) return false;
    return saveNativeRecords(volume, set, volume.next_object_id, 0, false, &freed);
}

fn nativeRename(volume: Volume, parent_oid: u64, old_name: []const u8, new_name: []const u8) bool {
    if (!volume.unencrypted or volume.snapshot_count != 0) return false;
    if (!loadNativeRecords(volume)) return false;
    const set = &native_record_workspace;
    const source = objectIdForName(set, parent_oid, old_name) orelse return false;
    if (source.kind != 4 and source.kind != 8) return false;
    if (std.mem.eql(u8, old_name, new_name)) return true;
    if (findRecordIndex(set, parent_oid, 9, new_name) != null) return false;
    const index = findRecordIndex(set, parent_oid, 9, old_name) orelse return false;
    var new_key: [280]u8 = @splat(0);
    const new_len = buildDrecKey(parent_oid, new_name, &new_key) orelse return false;
    @memset(&set.records[index].key, 0);
    @memcpy(set.records[index].key[0..new_len], new_key[0..new_len]);
    set.records[index].key_len = @intCast(new_len);
    return recordsFit(set, volume.container.block_size) and saveNativeRecords(volume, set, volume.next_object_id, 0, false, null);
}

fn buildDrecKey(parent_oid: u64, name: []const u8, key: []u8) ?usize {
    if (name.len == 0 or name.len > 255 or key.len < 11 + name.len or std.mem.indexOfScalar(u8, name, 0) != null or std.mem.indexOfScalar(u8, name, '/') != null) return null;
    @memset(key, 0);
    put64(key, 0, (@as(u64, 9) << 60) | parent_oid);
    put16(key, 8, @intCast(name.len + 1));
    @memcpy(key[10 .. 10 + name.len], name);
    key[10 + name.len] = 0;
    return 11 + name.len;
}

fn walkFsRecords(volume: Volume, visitor: RecordVisitor, context: *anyopaque) bool {
    var pending: [2048]u64 = undefined;
    var visited: [2048]u64 = undefined;
    var pending_count: usize = 1;
    var visited_count: usize = 0;
    pending[0] = volume.root_tree_block;
    var block: Block = undefined;
    while (pending_count != 0 and visited_count < visited.len) {
        pending_count -= 1;
        const paddr = pending[pending_count];
        var duplicate = false;
        for (visited[0..visited_count]) |previous| if (previous == paddr) {
            duplicate = true;
            break;
        };
        if (duplicate) continue;
        visited[visited_count] = paddr;
        visited_count += 1;
        if (!readBlock(volume.container, paddr, block[0..volume.container.block_size])) return false;
        const bytes = block[0..volume.container.block_size];
        if (!hasValidChecksum(bytes)) return false;
        const node_flags = le16(bytes, 32);
        const count = @min(le32(bytes, 36), 4096);
        if ((node_flags & 2) != 0) {
            for (0..count) |index| {
                const item = treeEntry(bytes, index, 0, 0) orelse return false;
                // A false visitor result means it found its answer or filled
                // its output buffer and intentionally stopped the scan.
                if (!visitor(context, item.key, item.value)) return true;
            }
        } else {
            for (0..count) |index| {
                const item = treeEntry(bytes, index, 0, 8) orelse return false;
                if (item.value.len < 8) return false;
                const child_oid = le64(item.value, 0);
                const resolved = lookupOmap(volume.container, volume.omap_tree_block, child_oid, volume.xid) orelse return false;
                if (resolved.paddr >= volume.container.block_count or pending_count == pending.len) return false;
                pending[pending_count] = resolved.paddr;
                pending_count += 1;
            }
        }
    }
    return pending_count == 0;
}

const ListContext = struct {
    directory_oid: u64,
    output: []Entry,
    object_ids: [max_native_records]u64 = @splat(0),
    count: usize = 0,
};
fn listRecord(context_ptr: *anyopaque, key: []const u8, value: []const u8) bool {
    const context: *ListContext = @ptrCast(@alignCast(context_ptr));
    const limit = @min(context.output.len, context.object_ids.len);
    if (key.len < 10 or value.len < 18 or context.count == limit) return context.count < limit;
    const key_header = le64(key, 0);
    if ((key_header >> 60) != 9 or (key_header & 0x0fff_ffff_ffff_ffff) != context.directory_oid) return true;
    const name = directoryName(key) orelse return true;
    if (name.len == 0) return true;
    const file_id = le64(value, 0);
    const entry_type = le16(value, 16) & 0x0f;
    var entry: Entry = .{};
    const copy_len = @min(name.len, entry.name.len);
    @memcpy(entry.name[0..copy_len], name[0..copy_len]);
    entry.name_len = @intCast(copy_len);
    entry.attributes = if (entry_type == 4) 0x10 else 0x20;
    entry.first_cluster = if (entry_type == 4) handleFor(file_id) else 0;
    context.object_ids[context.count] = file_id;
    context.output[context.count] = entry;
    context.count += 1;
    return context.count < limit;
}

const InodeInfo = struct { stream_oid: u64 = 0, size: u64 = 0, crypto_id: u64 = 0, inode_flags: u64 = 0, mode: u16 = 0 };
fn inodeInfo(value: []const u8) ?InodeInfo {
    if (value.len < 96) return null;
    var info = InodeInfo{ .stream_oid = le64(value, 8), .inode_flags = le64(value, 48), .mode = le16(value, 80) };
    const count = @min(le16(value, 92), 256);
    const descriptors: usize = 96;
    if (descriptors > value.len or @as(usize, count) * 4 > value.len - descriptors) return null;
    var data = descriptors + @as(usize, count) * 4;
    data = (data + 7) & ~@as(usize, 7);
    for (0..count) |i| {
        const descriptor = descriptors + i * 4;
        const field_type = value[descriptor];
        const field_size = @as(usize, le16(value, descriptor + 2));
        data = (data + 7) & ~@as(usize, 7);
        if (data > value.len or field_size > value.len - data) return null;
        if (field_type == 8 and field_size >= 40) {
            info.size = le64(value, data);
            info.crypto_id = le64(value, data + 16);
        }
        data += field_size;
    }
    return info;
}

const ListSizeContext = struct { list: *ListContext };
fn listSizeRecord(context_ptr: *anyopaque, key: []const u8, value: []const u8) bool {
    const context: *ListSizeContext = @ptrCast(@alignCast(context_ptr));
    if (key.len < 8 or value.len < 96) return true;
    const header = le64(key, 0);
    if ((header >> 60) != 3) return true;
    const object_id = header & 0x0fff_ffff_ffff_ffff;
    const info = inodeInfo(value) orelse return true;
    for (0..context.list.count) |i| {
        if (context.list.object_ids[i] == object_id) {
            context.list.output[i].size = info.size;
            break;
        }
    }
    return true;
}

pub fn listDirectory(directory_handle: u32, output: []Entry) usize {
    const volume = mounted_volume orelse return 0;
    const directory_oid = objectForHandle(directory_handle) orelse return 0;
    var context = ListContext{ .directory_oid = directory_oid, .output = output };
    if (!walkFsRecords(volume, listRecord, @ptrCast(&context))) return 0;
    var sizes = ListSizeContext{ .list = &context };
    if (!walkFsRecords(volume, listSizeRecord, @ptrCast(&sizes))) return 0;
    return context.count;
}

pub fn changeDirectory(directory_handle: u32, name: []const u8) ?u32 {
    const parent_oid = objectForHandle(directory_handle) orelse return null;
    var search = DirectorySearch{ .parent_oid = parent_oid, .name = name };
    const volume = mounted_volume orelse return null;
    if (!walkFsRecords(volume, findDirectoryRecord, @ptrCast(&search))) return null;
    if (search.kind != 4) return null;
    return handleFor(search.object_id orelse return null);
}

const DirectorySearch = struct { parent_oid: u64, name: []const u8, object_id: ?u64 = null, kind: u16 = 0 };
fn findDirectoryRecord(context_ptr: *anyopaque, key: []const u8, value: []const u8) bool {
    const context: *DirectorySearch = @ptrCast(@alignCast(context_ptr));
    if (key.len < 10 or value.len < 18) return true;
    const header = le64(key, 0);
    if ((header >> 60) != 9 or (header & 0x0fff_ffff_ffff_ffff) != context.parent_oid) return true;
    const stored_name = directoryName(key) orelse return true;
    if (!std.mem.eql(u8, stored_name, context.name)) return true;
    context.object_id = le64(value, 0);
    context.kind = le16(value, 16) & 0x0f;
    return false;
}

const InodeSearch = struct { object_id: u64, info: ?InodeInfo = null };
fn findInodeRecord(context_ptr: *anyopaque, key: []const u8, value: []const u8) bool {
    const context: *InodeSearch = @ptrCast(@alignCast(context_ptr));
    if (key.len < 8 or value.len < 96) return true;
    const header = le64(key, 0);
    if ((header >> 60) != 3 or (header & 0x0fff_ffff_ffff_ffff) != context.object_id) return true;
    context.info = inodeInfo(value) orelse return true;
    return false;
}

const ExtentRead = struct {
    volume: Volume,
    stream_oid: u64,
    output: []u8,
    file_size: u64,
    spans: [4096]struct { logical: u64, length: u64 } = undefined,
    span_count: usize = 0,
    failed: bool = false,
};
fn findExtentRecord(context_ptr: *anyopaque, key: []const u8, value: []const u8) bool {
    const context: *ExtentRead = @ptrCast(@alignCast(context_ptr));
    if (key.len < 16 or value.len < 24) return true;
    const header = le64(key, 0);
    if ((header >> 60) != 8 or (header & 0x0fff_ffff_ffff_ffff) != context.stream_oid) return true;
    const len_and_flags = le64(value, 0);
    const length = len_and_flags & 0x00ff_ffff_ffff_ffff;
    const logical = le64(key, 8);
    const physical = le64(value, 8);
    // Refuse extents that need crypto/compression/shared-extent semantics we
    // do not yet implement, instead of returning silently corrupted bytes.
    if (length == 0 or (len_and_flags >> 56) != 0 or le64(value, 16) != 0) {
        context.failed = true;
        return false;
    }
    if (length > std.math.maxInt(u64) - logical) {
        context.failed = true;
        return false;
    }
    if (physical == 0 or logical >= context.file_size) return true; // Sparse extent.
    const block_size: u64 = context.volume.container.block_size;
    const required_blocks = (length - 1) / block_size + 1;
    if (physical >= context.volume.container.block_count or required_blocks > context.volume.container.block_count - physical) {
        context.failed = true;
        return false;
    }
    if (context.span_count == context.spans.len) {
        context.failed = true;
        return false;
    }
    const clipped_length = @min(length, context.file_size - logical);
    context.spans[context.span_count] = .{ .logical = logical, .length = clipped_length };
    context.span_count += 1;
    var copied: u64 = 0;
    while (copied < length and logical + copied < context.file_size) {
        const within_block = copied % block_size;
        const physical_block = physical + copied / block_size;
        if (!readBlock(context.volume.container, physical_block, io_block[0..context.volume.container.block_size])) {
            context.failed = true;
            return false;
        }
        const amount = @min(block_size - within_block, @min(length - copied, context.file_size - (logical + copied)));
        const destination = std.math.cast(usize, logical + copied) orelse {
            context.failed = true;
            return false;
        };
        const source: usize = @intCast(within_block);
        const count: usize = @intCast(amount);
        if (destination > context.output.len or count > context.output.len - destination) {
            context.failed = true;
            return false;
        }
        @memcpy(context.output[destination .. destination + count], io_block[source .. source + count]);
        copied += amount;
    }
    return true;
}

const ExtentWriteContext = struct {
    volume: Volume,
    stream_oid: u64,
    data: []const u8,
    spans: [4096]struct { logical: u64, length: u64 } = undefined,
    span_count: usize = 0,
    covered: u64 = 0,
    write: bool = false,
    failed: bool = false,
};
fn writeExtentRecord(context_ptr: *anyopaque, key: []const u8, value: []const u8) bool {
    const context: *ExtentWriteContext = @ptrCast(@alignCast(context_ptr));
    if (key.len < 16 or value.len < 24) return true;
    const header = le64(key, 0);
    if ((header >> 60) != 8 or (header & 0x0fff_ffff_ffff_ffff) != context.stream_oid) return true;
    const len_and_flags = le64(value, 0);
    const length = len_and_flags & 0x00ff_ffff_ffff_ffff;
    const logical = le64(key, 8);
    const physical = le64(value, 8);
    const block_size: u64 = context.volume.container.block_size;
    const required_blocks = (length + block_size - 1) / block_size;
    if ((len_and_flags >> 56) != 0 or le64(value, 16) != 0 or physical == 0 or length == 0) {
        context.failed = true;
        return false;
    }
    if (physical >= context.volume.container.block_count or required_blocks > context.volume.container.block_count - physical) {
        context.failed = true;
        return false;
    }
    if (logical > context.data.len or length > context.data.len - logical) {
        context.failed = true;
        return false;
    }
    if (!context.write) {
        if (context.span_count == context.spans.len) {
            context.failed = true;
            return false;
        }
        context.spans[context.span_count] = .{ .logical = logical, .length = length };
        context.span_count += 1;
        context.covered = std.math.add(u64, context.covered, length) catch {
            context.failed = true;
            return false;
        };
        return true;
    }
    var copied: u64 = 0;
    while (copied < length) {
        const within_block = copied % block_size;
        const physical_block = physical + copied / block_size;
        if (!readBlock(context.volume.container, physical_block, io_block[0..context.volume.container.block_size])) {
            context.failed = true;
            return false;
        }
        const amount = @min(block_size - within_block, length - copied);
        const source_offset = std.math.cast(usize, logical + copied) orelse {
            context.failed = true;
            return false;
        };
        const source_end = source_offset + @as(usize, @intCast(amount));
        const block_offset: usize = @intCast(within_block);
        @memcpy(io_block[block_offset .. block_offset + @as(usize, @intCast(amount))], context.data[source_offset..source_end]);
        if (!writeBlock(context.volume.container, physical_block, io_block[0..context.volume.container.block_size])) {
            context.failed = true;
            return false;
        }
        copied += amount;
    }
    return true;
}

const CompressionSearch = struct { object_id: u64, found: bool = false };
fn findCompressionXattr(context_ptr: *anyopaque, key: []const u8, value: []const u8) bool {
    const context: *CompressionSearch = @ptrCast(@alignCast(context_ptr));
    if (key.len < 10) return true;
    const header = le64(key, 0);
    if ((header >> 60) != 4 or (header & 0x0fff_ffff_ffff_ffff) != context.object_id) return true;
    const name_len = @as(usize, le16(key, 8));
    if (name_len == 0 or name_len > key.len - 10) return true;
    var name = key[10 .. 10 + name_len];
    if (name.len != 0 and name[name.len - 1] == 0) name = name[0 .. name.len - 1];
    if (std.mem.eql(u8, name, "com.apple.decmpfs")) {
        context.found = true;
        return false;
    }
    _ = value;
    return true;
}

/// Replace bytes in a preallocated APFS data stream without changing its
/// length. This only accepts plain unencrypted extents and volumes without
/// snapshots or cloned-file flags; structural mutations need COW transactions.
pub fn writeFileAt(directory_handle: u32, name: []const u8, data: []const u8) bool {
    const volume = mounted_volume orelse return false;
    if (volume.sealed) return false;
    if (volume.native_formatted) {
        const parent_oid = objectForHandle(directory_handle) orelse return false;
        return nativeWriteFile(volume, parent_oid, name, data);
    }
    if (!volume.unencrypted or volume.snapshot_count != 0) return false;
    const parent_oid = objectForHandle(directory_handle) orelse return false;
    var directory_search = DirectorySearch{ .parent_oid = parent_oid, .name = name };
    if (!walkFsRecords(volume, findDirectoryRecord, @ptrCast(&directory_search))) return false;
    const object_id = directory_search.object_id orelse return false;
    if (directory_search.kind != 8) return false;
    var inode_search = InodeSearch{ .object_id = object_id };
    if (!walkFsRecords(volume, findInodeRecord, @ptrCast(&inode_search))) return false;
    const inode = inode_search.info orelse return false;
    if (inode.mode & 0xf000 != 0x8000 or inode.size != data.len or inode.stream_oid == 0 or inode.crypto_id != 0) return false;
    if ((inode.inode_flags & 0x0000_0000_0000_0610) != 0) return false; // sparse, cloned, or ever cloned
    var compression = CompressionSearch{ .object_id = object_id };
    if (!walkFsRecords(volume, findCompressionXattr, @ptrCast(&compression))) return false;
    if (compression.found) return false;
    if (data.len == 0) return true;

    var extents = ExtentWriteContext{ .volume = volume, .stream_oid = inode.stream_oid, .data = data };
    if (!walkFsRecords(volume, writeExtentRecord, @ptrCast(&extents))) return false;
    if (extents.failed or extents.covered != inode.size) return false;

    // The file's plain extent records must form an exact, non-overlapping
    // logical range before any existing data block is modified.
    for (1..extents.span_count) |i| {
        const span = extents.spans[i];
        var j = i;
        while (j > 0 and span.logical < extents.spans[j - 1].logical) : (j -= 1) extents.spans[j] = extents.spans[j - 1];
        extents.spans[j] = span;
    }
    var logical_end: u64 = 0;
    for (extents.spans[0..extents.span_count]) |span| {
        if (span.logical != logical_end) return false;
        logical_end = std.math.add(u64, logical_end, span.length) catch return false;
    }
    if (logical_end != inode.size) return false;

    extents.covered = 0;
    extents.write = true;
    extents.failed = false;
    if (!walkFsRecords(volume, writeExtentRecord, @ptrCast(&extents))) return false;
    if (extents.failed or !ata.flushCache(volume.container.device)) return false;
    return true;
}

pub fn makeDirectory(directory_handle: u32, name: []const u8) bool {
    const volume = mounted_volume orelse return false;
    if (volume.sealed) return false;
    const parent_oid = objectForHandle(directory_handle) orelse return false;
    return nativeMakeDirectory(volume, parent_oid, name);
}

pub fn deleteFileAt(directory_handle: u32, name: []const u8) bool {
    const volume = mounted_volume orelse return false;
    if (volume.sealed) return false;
    const parent_oid = objectForHandle(directory_handle) orelse return false;
    return nativeDelete(volume, parent_oid, name, true);
}

pub fn deleteEntryAt(directory_handle: u32, name: []const u8) bool {
    const volume = mounted_volume orelse return false;
    if (volume.sealed) return false;
    const parent_oid = objectForHandle(directory_handle) orelse return false;
    return nativeDelete(volume, parent_oid, name, false);
}

pub fn renameAt(directory_handle: u32, old_name: []const u8, new_name: []const u8) bool {
    const volume = mounted_volume orelse return false;
    if (volume.sealed) return false;
    const parent_oid = objectForHandle(directory_handle) orelse return false;
    return nativeRename(volume, parent_oid, old_name, new_name);
}

/// Read an unencrypted, uncompressed APFS data fork through its FILE_EXTENT records.
/// The caller supplies a bounded destination buffer, matching AetherOS's file API.
pub fn readFileAt(directory_handle: u32, name: []const u8, output: []u8) ?usize {
    const volume = mounted_volume orelse return null;
    const parent_oid = objectForHandle(directory_handle) orelse return null;
    var directory_search = DirectorySearch{ .parent_oid = parent_oid, .name = name };
    if (!walkFsRecords(volume, findDirectoryRecord, @ptrCast(&directory_search))) return null;
    const object_id = directory_search.object_id orelse return null;
    if (directory_search.kind != 8) return null;
    var inode_search = InodeSearch{ .object_id = object_id };
    if (!walkFsRecords(volume, findInodeRecord, @ptrCast(&inode_search))) return null;
    const inode = inode_search.info orelse return null;
    const file_size = std.math.cast(usize, inode.size) orelse return null;
    if (file_size > output.len) return null;
    @memset(output[0..file_size], 0);
    if (file_size == 0) return 0;
    if (inode.stream_oid == 0) return null;
    var extent_search = ExtentRead{ .volume = volume, .stream_oid = inode.stream_oid, .output = output, .file_size = inode.size };
    if (!walkFsRecords(volume, findExtentRecord, @ptrCast(&extent_search))) return null;
    if (extent_search.failed) return null;
    var span_index: usize = 1;
    while (span_index < extent_search.span_count) : (span_index += 1) {
        const i = span_index;
        const span = extent_search.spans[i];
        var j = i;
        while (j > 0 and span.logical < extent_search.spans[j - 1].logical) : (j -= 1) extent_search.spans[j] = extent_search.spans[j - 1];
        extent_search.spans[j] = span;
    }
    var logical_end: u64 = 0;
    for (extent_search.spans[0..extent_search.span_count]) |span| {
        if (span.logical < logical_end) return null;
        logical_end = span.logical + span.length;
    }
    return file_size;
}
