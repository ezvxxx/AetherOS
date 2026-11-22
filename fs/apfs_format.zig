//! Small APFS image initializer for AetherOS's unencrypted single-volume subset.
//! The formatter emits the same APFS object, OMAP, and B-tree records consumed
//! by the native driver. A block sink keeps it usable from the kernel and host
//! image builder without importing any external filesystem implementation.
const std = @import("std");

pub const block_size: usize = 4096;
pub const Block = [block_size]u8;
pub const BlockSink = *const fn (context: *anyopaque, block_number: u64, block: []const u8) bool;
pub const max_formatted_blocks: u64 = 32768 * 126;

const checkpoint_desc_base: u64 = 1;
const checkpoint_desc_blocks: u32 = 16;
const checkpoint_data_base: u64 = checkpoint_desc_base + checkpoint_desc_blocks;
const checkpoint_data_blocks: u32 = 8;
const spaceman_block: u64 = checkpoint_data_base;
const reaper_block: u64 = checkpoint_data_base + 1;
const container_omap_object: u64 = checkpoint_data_base + checkpoint_data_blocks;
const container_omap_tree: u64 = container_omap_object + 1;
const volume_superblock: u64 = container_omap_tree + 1;
const volume_omap_object: u64 = volume_superblock + 1;
const volume_omap_tree: u64 = volume_omap_object + 1;
const fs_tree_block: u64 = volume_omap_tree + 1;
const cib_block: u64 = fs_tree_block + 1;
const bitmap0_block: u64 = cib_block + 1;
const blocks_per_chunk: u32 = 32768;
const cib_capacity: u32 = 126;

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
fn fletcher64(bytes: []const u8) u64 {
    const modulus: u64 = 0xffff_ffff;
    var sum1: u64 = 0;
    var sum2: u64 = 0;
    var offset: usize = 0;
    while (offset + 4 <= bytes.len) : (offset += 4) {
        const word = @as(u64, bytes[offset]) |
            (@as(u64, bytes[offset + 1]) << 8) |
            (@as(u64, bytes[offset + 2]) << 16) |
            (@as(u64, bytes[offset + 3]) << 24);
        sum1 = (sum1 + word) % modulus;
        sum2 = (sum2 + sum1) % modulus;
    }
    const low = modulus - ((sum1 + sum2) % modulus);
    const high = modulus - ((sum1 + low) % modulus);
    return (high << 32) | low;
}
fn seal(bytes: []u8) void {
    put64(bytes, 0, 0);
    put64(bytes, 0, fletcher64(bytes[8..]));
}
fn objectHeader(bytes: []u8, oid: u64, xid: u64, object_type: u32, subtype: u32) void {
    @memset(bytes, 0);
    put64(bytes, 8, oid);
    put64(bytes, 16, xid);
    put32(bytes, 24, object_type);
    put32(bytes, 28, subtype);
}
fn makeOmap(block: *Block, oid: u64, xid: u64, tree_oid: u64) void {
    objectHeader(block, oid, xid, 0x4000000b, 0);
    put32(block, 40, 0x40000002); // physical OBJECT_TYPE_BTREE
    put64(block, 48, tree_oid);
    seal(block);
}
fn makeSpaceman(block: *Block, xid: u64, block_count: u64, first_allocated_metadata_block: u64) void {
    objectHeader(block, 2, xid, 0x80000005, 0);
    put32(block, 32, block_size);
    put32(block, 36, blocks_per_chunk);
    put32(block, 40, 126);
    put32(block, 44, 1);
    put64(block, 48, block_count);
    const chunks: u64 = (block_count + blocks_per_chunk - 1) / blocks_per_chunk;
    const free_count = block_count - first_allocated_metadata_block - 2;
    put64(block, 56, chunks);
    put32(block, 64, 1);
    put64(block, 72, free_count);
    put32(block, 80, 2496); // inline CIB physical-address array
    put32(block, 312, 1);
    put32(block, 316, 2496);
    put64(block, 2496, cib_block);
    seal(block);
}
fn makeCib(block: *Block, xid: u64, block_count: u64, first_bitmap_block: u64, first_allocated_metadata_block: u64) void {
    objectHeader(block, cib_block, xid, 0x40000007, 0);
    const chunks: u32 = @intCast((block_count + blocks_per_chunk - 1) / blocks_per_chunk);
    put32(block, 32, 0); // CIB index
    put32(block, 36, chunks);
    for (0..chunks) |index| {
        const start = @as(u64, index) * blocks_per_chunk;
        const count: u32 = @intCast(@min(blocks_per_chunk, block_count - start));
        const allocated_low: u32 = @intCast(@min(count, first_allocated_metadata_block -| start));
        const allocated_high: u32 = if (start + count > block_count - 2) @intCast(start + count - @max(start, block_count - 2)) else 0;
        const entry = 40 + index * 32;
        put64(block, entry, xid);
        put64(block, entry + 8, start);
        put32(block, entry + 16, count);
        put32(block, entry + 20, count - allocated_low - allocated_high);
        put64(block, entry + 24, first_bitmap_block + index);
    }
    seal(block);
}
fn makeChunkBitmap(block: *Block, block_count: u64, chunk_index: u32, first_allocated_metadata_block: u64) void {
    @memset(block, 0);
    const start = @as(u64, chunk_index) * blocks_per_chunk;
    const count = @min(blocks_per_chunk, block_count - start);
    for (0..count) |local| {
        const absolute = start + local;
        if (absolute < first_allocated_metadata_block or absolute >= block_count - 2) {
            block[local / 8] |= @as(u8, 1) << @intCast(local % 8);
        }
    }
}
fn makeReaper(block: *Block, xid: u64) void {
    objectHeader(block, 3, xid, 0x80000011, 0);
    put64(block, 32, 1);
    put32(block, 64, 1);
    put32(block, 108, block_size - 112);
    seal(block);
}
fn makeCheckpointMap(block: *Block, xid: u64) void {
    objectHeader(block, checkpoint_desc_base, xid, 0x4000000c, 0);
    put32(block, 32, 1);
    put32(block, 36, 2);
    const spaceman_entry: usize = 40;
    put32(block, spaceman_entry, 0x80000005);
    put32(block, spaceman_entry + 8, block_size);
    put64(block, spaceman_entry + 24, 2);
    put64(block, spaceman_entry + 32, spaceman_block);
    const reaper_entry: usize = spaceman_entry + 40;
    put32(block, reaper_entry, 0x80000011);
    put32(block, reaper_entry + 8, block_size);
    put64(block, reaper_entry + 24, 3);
    put64(block, reaper_entry + 32, reaper_block);
    seal(block);
}
fn makeNxsb(block: *Block, block_count: u64, xid: u64, volume_oid: u64) void {
    objectHeader(block, 1, xid, 0x80000001, 0);
    put32(block, 32, 0x4253584e);
    put32(block, 36, block_size);
    put64(block, 40, block_count);
    put64(block, 72, 0x4145544845524f53);
    put64(block, 80, 0x4150465300000001);
    put64(block, 88, 14);
    put64(block, 96, xid + 1);
    put32(block, 104, checkpoint_desc_blocks);
    put32(block, 108, checkpoint_data_blocks);
    put64(block, 112, checkpoint_desc_base);
    put64(block, 120, checkpoint_data_base);
    put32(block, 128, 2);
    put32(block, 132, 2);
    put32(block, 136, 0);
    put32(block, 140, 2);
    put32(block, 144, 0);
    put32(block, 148, 2);
    put64(block, 152, 2);
    put64(block, 160, container_omap_object);
    put64(block, 168, 3);
    // APFS recommends one volume per 512 MiB of container capacity, rounded up.
    put32(block, 180, @intCast((block_count + 131071) / 131072));
    put64(block, 184, volume_oid);
    // min checkpoint-data blocks (8), four volume ephemeral structures,
    // and NX_EPH_INFO_VERSION_1.
    put64(block, 1312, 0x0000000800040001);
    seal(block);
}
fn makeFixedTree(block: *Block, oid: u64, xid: u64, subtype: u32, key: []const u8, value: []const u8) bool {
    if (key.len != 16 or value.len != 16) return false;
    objectHeader(block, oid, xid, 0x40000002, subtype);
    put16(block, 32, 7); // root | leaf | fixed key/value
    put16(block, 34, 0);
    put32(block, 36, 1);
    put16(block, 40, 0);
    put16(block, 42, 4);
    put16(block, 56, 0); // key offset in key area
    put16(block, 58, 0); // value offset back from the end
    @memcpy(block[60 .. 60 + key.len], key);
    @memcpy(block[block_size - 40 - value.len .. block_size - 40], value);
    seal(block);
    return true;
}
fn makeVariableTree(block: *Block, oid: u64, xid: u64, subtype: u32, key: []const u8, value: []const u8) bool {
    const toc_size = 8;
    const key_start = 56 + toc_size;
    const value_start = block_size - 40 - value.len;
    if (key.len == 0 or key.len > std.math.maxInt(u16) or value.len > std.math.maxInt(u16) or key_start + key.len > value_start) return false;
    objectHeader(block, oid, xid, 0x00000002, subtype);
    put16(block, 32, 3); // root | leaf
    put16(block, 34, 0);
    put32(block, 36, 1);
    put16(block, 40, 0);
    put16(block, 42, toc_size);
    put16(block, 56, 0); // key offset in key area
    put16(block, 58, @intCast(key.len));
    put16(block, 60, 0); // value offset back from the end
    put16(block, 62, @intCast(value.len));
    @memcpy(block[key_start .. key_start + key.len], key);
    @memcpy(block[value_start .. value_start + value.len], value);
    put32(block, block_size - 36, block_size); // btree_info_fixed.node_size
    put64(block, block_size - 16, 1); // key_count
    put64(block, block_size - 8, 1); // node_count
    seal(block);
    return true;
}

/// Format a blank raw device as an unencrypted APFS container with checkpoint
/// descriptor/data areas, a space-manager and reaper record, and an empty
/// volume root directory. The caller must verify
/// that the target is blank and pass the exact block count before calling.
/// Returns false for unsupported geometry or any failed block write.
pub fn format(block_count: u64, volume_name: []const u8, sink: BlockSink, context: *anyopaque) bool {
    const chunks = (block_count + blocks_per_chunk - 1) / blocks_per_chunk;
    if (block_count < 256 or block_count > max_formatted_blocks or chunks > cib_capacity or volume_name.len == 0 or volume_name.len > 127) return false;
    const first_bitmap_block = bitmap0_block;
    const first_allocated_metadata_block = first_bitmap_block + chunks;
    if (first_allocated_metadata_block >= block_count - 2) return false;
    const xid: u64 = 2;
    const volume_oid: u64 = 10;
    const fs_tree_oid: u64 = 13;
    var block: Block = undefined;

    // Root inode record (directory object ID 2) in a one-leaf fs tree.
    var inode_key: [8]u8 = @splat(0);
    put64(&inode_key, 0, (3 << 60) | 2);
    var inode_value: [96]u8 = @splat(0);
    put64(&inode_value, 0, 2);
    put16(&inode_value, 80, 0x41ed); // S_IFDIR | 0755
    put16(&inode_value, 92, 0); // no xfields
    if (!makeVariableTree(&block, fs_tree_oid, xid, 0x0e, &inode_key, &inode_value)) return false;
    if (!sink(context, fs_tree_block, &block)) return false;

    // Volume object map maps the virtual filesystem tree OID to block 6.
    var omap_key: [16]u8 = @splat(0);
    put64(&omap_key, 0, fs_tree_oid);
    put64(&omap_key, 8, xid);
    var omap_value: [16]u8 = @splat(0);
    put32(&omap_value, 4, block_size);
    put64(&omap_value, 8, fs_tree_block);
    if (!makeFixedTree(&block, volume_omap_tree, xid, 0x0b, &omap_key, &omap_value)) return false;
    if (!sink(context, volume_omap_tree, &block)) return false;
    makeOmap(&block, volume_omap_object, xid, volume_omap_tree);
    if (!sink(context, volume_omap_object, &block)) return false;

    // APFS volume superblock. Root and metadata trees are virtual OIDs mapped
    // by the volume OMAP above; the name is UTF-16LE as required by APSB.
    objectHeader(&block, volume_oid, xid, 0x0d, 0);
    put32(&block, 32, 0x42535041); // APSB
    put32(&block, 116, 0x00000002);
    put64(&block, 128, volume_omap_object);
    put64(&block, 136, fs_tree_oid);
    put64(&block, 176, 14);
    put64(&block, 184, 0); // apfs_num_files
    put64(&block, 192, 1); // one root directory
    put64(&block, 264, 1); // APFS_FS_UNENCRYPTED
    put64(&block, 88, 4); // APFS filesystem metadata blocks in this subset
    put64(&block, 224, 4); // apfs_total_blocks_alloced
    for (0..volume_name.len) |i| put16(&block, 704 + i * 2, volume_name[i]);
    seal(&block);
    if (!sink(context, volume_superblock, &block)) return false;

    // Container object map maps volume OID 10 to its superblock at block 3.
    @memset(&omap_key, 0);
    put64(&omap_key, 0, volume_oid);
    put64(&omap_key, 8, xid);
    @memset(&omap_value, 0);
    put32(&omap_value, 4, block_size);
    put64(&omap_value, 8, volume_superblock);
    if (!makeFixedTree(&block, container_omap_tree, xid, 0x0b, &omap_key, &omap_value)) return false;
    if (!sink(context, container_omap_tree, &block)) return false;
    makeOmap(&block, container_omap_object, xid, container_omap_tree);
    if (!sink(context, container_omap_object, &block)) return false;

    makeSpaceman(&block, xid, block_count, first_allocated_metadata_block);
    if (!sink(context, spaceman_block, &block)) return false;
    makeCib(&block, xid, block_count, first_bitmap_block, first_allocated_metadata_block);
    if (!sink(context, cib_block, &block)) return false;
    for (0..chunks) |chunk| {
        makeChunkBitmap(&block, block_count, @intCast(chunk), first_allocated_metadata_block);
        if (!sink(context, first_bitmap_block + chunk, &block)) return false;
    }
    makeReaper(&block, xid);
    if (!sink(context, reaper_block, &block)) return false;
    makeCheckpointMap(&block, xid);
    if (!sink(context, checkpoint_desc_base, &block)) return false;

    // AetherOS allocator journal for this native formatter's reserved block
    // pool. It is in an otherwise unallocated APFS block and is never used on
    // externally formatted APFS containers.
    @memset(&block, 0);
    put32(&block, 8, 2);
    put64(&block, 16, 14); // next filesystem object identifier
    put64(&block, 24, block_count - 2); // high-water data block allocator
    put64(&block, 32, first_allocated_metadata_block); // next metadata block
    put64(&block, 40, xid); // allocator transaction generation
    @memcpy(block[344..352], "AETHAPFS");
    seal(&block);
    if (!sink(context, block_count - 1, &block)) return false;

    // Publish a live checkpoint first, then its label copy at block zero.
    makeNxsb(&block, block_count, xid, volume_oid);
    if (!sink(context, checkpoint_desc_base + 1, &block)) return false;
    makeNxsb(&block, block_count, xid, volume_oid);
    return sink(context, 0, &block);
}
