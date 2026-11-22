//! Host runner for the native APFS image formatter.
const std = @import("std");
const formatter = @import("apfs_format.zig");

const Context = struct { writer: *std.Io.File.Writer };
fn writeBlock(context_ptr: *anyopaque, block_number: u64, bytes: []const u8) bool {
    const context: *Context = @ptrCast(@alignCast(context_ptr));
    context.writer.seekTo(block_number * formatter.block_size) catch return false;
    context.writer.interface.writeAll(bytes) catch return false;
    return true;
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
fn fletcher64(bytes: []const u8) u64 {
    const modulus: u64 = 0xffff_ffff;
    var sum1: u64 = 0;
    var sum2: u64 = 0;
    var offset: usize = 0;
    while (offset + 4 <= bytes.len) : (offset += 4) {
        const word = le32(bytes, offset);
        sum1 = (sum1 + word) % modulus;
        sum2 = (sum2 + sum1) % modulus;
    }
    const low = modulus - ((sum1 + sum2) % modulus);
    const high = modulus - ((sum1 + low) % modulus);
    return (high << 32) | low;
}
fn validChecksum(block: []const u8) bool {
    return block.len == formatter.block_size and le64(block, 0) == fletcher64(block[8..]);
}

/// Return true only for the untouched one-root-directory image emitted by the
/// first AetherOS subset formatter. Check the complete unallocated region
/// before allowing an in-place metadata-format upgrade.
fn isVirginLegacyImage(bytes: []const u8) bool {
    const block_size = formatter.block_size;
    if (bytes.len < block_size * 256 or bytes.len % block_size != 0) return false;
    const block_count = bytes.len / block_size;
    const nx = bytes[0..block_size];
    if (!validChecksum(nx) or le32(nx, 32) != 0x4253_584e or le32(nx, 36) != block_size or le64(nx, 40) != block_count or le64(nx, 16) != 1 or le64(nx, 96) != 1) return false;
    if (le64(nx, 88) != 14 or le64(nx, 160) != 1 or le32(nx, 180) != 1 or le64(nx, 184) != 10) return false;
    const container_omap = bytes[block_size .. block_size * 2];
    const container_tree = bytes[block_size * 2 .. block_size * 3];
    const volume = bytes[block_size * 3 .. block_size * 4];
    const volume_omap = bytes[block_size * 4 .. block_size * 5];
    const volume_tree = bytes[block_size * 5 .. block_size * 6];
    const fs_tree = bytes[block_size * 6 .. block_size * 7];
    if (!validChecksum(container_omap) or le32(container_omap, 24) & 0xffff != 0x0b or le64(container_omap, 8) != 1) return false;
    if (!validChecksum(container_tree) or le32(container_tree, 24) & 0xffff != 2 or le32(container_tree, 28) & 0xffff != 0x0b or le32(container_tree, 36) != 1) return false;
    if (!validChecksum(volume) or le32(volume, 32) != 0x4253_5041 or le64(volume, 16) != 1 or le64(volume, 128) != 4 or le64(volume, 136) != 13 or le64(volume, 184) != 0 or le64(volume, 192) != 1) return false;
    if (!validChecksum(volume_omap) or le32(volume_omap, 24) & 0xffff != 0x0b or (le64(volume_omap, 8) != 4 and le64(volume_omap, 8) != 11)) return false;
    if (!validChecksum(volume_tree) or le32(volume_tree, 24) & 0xffff != 2 or le32(volume_tree, 28) & 0xffff != 0x0b or le32(volume_tree, 36) != 1) return false;
    if (!validChecksum(fs_tree) or le32(fs_tree, 24) & 0xffff != 2 or le32(fs_tree, 28) & 0xffff != 0x0e or le16(fs_tree, 32) & 2 == 0 or le32(fs_tree, 36) != 1 or (le64(fs_tree, 64) >> 60) != 3 or (le64(fs_tree, 64) & 0x0fff_ffff_ffff_ffff) != 2) return false;

    const marker = bytes[(block_count - 1) * block_size .. block_count * block_size];
    if (!std.mem.eql(u8, marker[0..8], "AETHAPFS") or le32(marker, 8) != 1 or le64(marker, 16) != 14 or le64(marker, 24) != block_count - 2 or le64(marker, 32) != 7 or le64(marker, 40) != 1) return false;
    for (7..block_count - 1) |index| {
        const block = bytes[index * block_size .. (index + 1) * block_size];
        for (block) |byte| if (byte != 0) return false;
    }
    return true;
}

/// Recognize only the immediately preceding empty AetherOS APFS layout. Its
/// allocator journal and zeroed data region prove that no user data has been
/// added, so the next build may safely regenerate its new chunk bitmaps.
fn isVirginCurrentImage(bytes: []const u8) bool {
    const bs = formatter.block_size;
    if (bytes.len < bs * 256 or bytes.len % bs != 0) return false;
    const blocks = bytes.len / bs;
    const nx = bytes[0..bs];
    if (!validChecksum(nx) or le32(nx, 32) != 0x4253_584e or le32(nx, 36) != bs or le64(nx, 40) != blocks or le64(nx, 16) != 2 or le64(nx, 88) != 14 or le64(nx, 160) != 25 or le64(nx, 184) != 10) return false;
    const live_nx = bytes[2 * bs .. 3 * bs];
    if (!validChecksum(live_nx) or le32(live_nx, 32) != 0x4253_584e or le64(live_nx, 16) != 2) return false;
    const volume = bytes[27 * bs .. 28 * bs];
    if (!validChecksum(volume) or le32(volume, 32) != 0x4253_5041 or le64(volume, 16) != 2 or le64(volume, 128) != 28 or le64(volume, 136) != 13 or le64(volume, 184) != 0 or le64(volume, 192) != 1) return false;
    const container_omap = bytes[25 * bs .. 26 * bs];
    const container_tree = bytes[26 * bs .. 27 * bs];
    const volume_omap = bytes[28 * bs .. 29 * bs];
    const volume_tree = bytes[29 * bs .. 30 * bs];
    if (!validChecksum(container_omap) or le32(container_omap, 24) & 0xffff != 0x0b or le64(container_omap, 8) != 25) return false;
    if (!validChecksum(container_tree) or le32(container_tree, 24) & 0xffff != 2 or le32(container_tree, 28) & 0xffff != 0x0b or le32(container_tree, 36) != 1) return false;
    if (!validChecksum(volume_omap) or le32(volume_omap, 24) & 0xffff != 0x0b or le64(volume_omap, 8) != 28) return false;
    if (!validChecksum(volume_tree) or le32(volume_tree, 24) & 0xffff != 2 or le32(volume_tree, 28) & 0xffff != 0x0b or le32(volume_tree, 36) != 1) return false;
    const tree = bytes[30 * bs .. 31 * bs];
    if (!validChecksum(tree) or le32(tree, 24) & 0xffff != 2 or le32(tree, 28) & 0xffff != 0x0e or le32(tree, 36) != 1 or (le64(tree, 64) >> 60) != 3 or (le64(tree, 64) & 0x0fff_ffff_ffff_ffff) != 2) return false;
    // The previous formatter left its empty one-volume metadata in blocks
    // 3..6 when it moved the live objects into checkpoint-managed blocks.
    // Accept only that exact, checksummed legacy root so this migration can
    // distinguish an untouched image from a volume containing user objects.
    const old_volume = bytes[3 * bs .. 4 * bs];
    const old_omap = bytes[4 * bs .. 5 * bs];
    const old_omap_tree = bytes[5 * bs .. 6 * bs];
    const old_fs_tree = bytes[6 * bs .. 7 * bs];
    if (!validChecksum(old_volume) or le32(old_volume, 32) != 0x4253_5041 or le64(old_volume, 8) != 10 or le64(old_volume, 16) != 1 or le64(old_volume, 128) != 4 or le64(old_volume, 136) != 13 or le64(old_volume, 184) != 0 or le64(old_volume, 192) != 1) return false;
    if (!validChecksum(old_omap) or le32(old_omap, 24) & 0xffff != 0x0b or le64(old_omap, 8) != 4 or le64(old_omap, 48) != 5) return false;
    if (!validChecksum(old_omap_tree) or le32(old_omap_tree, 24) & 0xffff != 2 or le32(old_omap_tree, 28) & 0xffff != 0x0b or le32(old_omap_tree, 36) != 1) return false;
    if (!validChecksum(old_fs_tree) or le32(old_fs_tree, 24) & 0xffff != 2 or le32(old_fs_tree, 28) & 0xffff != 0x0e or le32(old_fs_tree, 36) != 1 or (le64(old_fs_tree, 64) >> 60) != 3 or (le64(old_fs_tree, 64) & 0x0fff_ffff_ffff_ffff) != 2) return false;
    const marker = bytes[(blocks - 1) * bs .. blocks * bs];
    if (!std.mem.eql(u8, marker[0..8], "AETHAPFS") or le32(marker, 8) != 1 or le64(marker, 16) != 14 or le64(marker, 24) != blocks - 2 or le64(marker, 32) != 31 or le64(marker, 40) != 2) return false;
    for (7..17) |index| if (!allZero(bytes[index * bs .. (index + 1) * bs])) return false;
    for (19..25) |index| if (!allZero(bytes[index * bs .. (index + 1) * bs])) return false;
    for (31..blocks - 1) |index| if (!allZero(bytes[index * bs .. (index + 1) * bs])) return false;
    return true;
}

fn allZero(bytes: []const u8) bool {
    for (bytes) |byte| if (byte != 0) return false;
    return true;
}

fn verifyBlock(init: std.process.Init, file: std.Io.File, block_number: u64, expected_type: u32, output: *formatter.Block) !void {
    const offset = std.math.mul(u64, block_number, formatter.block_size) catch return error.InvalidImageSize;
    const read = try file.readPositionalAll(init.io, output, offset);
    if (read != output.len or !validChecksum(output) or le32(output, 24) != expected_type) {
        std.debug.print("APFS image verification failed at block {d}: short read, checksum, or object type mismatch\n", .{block_number});
        return error.FormattedImageVerificationFailed;
    }
}

fn verifyFailure(stage: []const u8) error{FormattedImageVerificationFailed} {
    std.debug.print("APFS image verification failed: {s}\n", .{stage});
    return error.FormattedImageVerificationFailed;
}

fn verifyFormattedImage(init: std.process.Init, path: []const u8, block_count: u64) !void {
    var file = try std.Io.Dir.cwd().openFile(init.io, path, .{ .mode = .read_only });
    defer file.close(init.io);
    var block: formatter.Block = undefined;

    try verifyBlock(init, file, 0, 0x8000_0001, &block);
    if (le32(&block, 32) != 0x4253_584e or le32(&block, 36) != formatter.block_size or le64(&block, 40) != block_count or
        le32(&block, 104) != 16 or le32(&block, 108) != 8 or le64(&block, 112) != 1 or le64(&block, 120) != 17 or
        le64(&block, 160) != 25 or le64(&block, 184) != 10)
        return verifyFailure("NXSB references");
    try verifyBlock(init, file, 1, 0x4000_000c, &block); // checkpoint map
    if (le64(&block, 64) != 2 or le64(&block, 72) != 17 or le64(&block, 104) != 3 or le64(&block, 112) != 18)
        return verifyFailure("checkpoint map references");
    try verifyBlock(init, file, 17, 0x8000_0005, &block); // space manager
    if (le64(&block, 48) != block_count or le32(&block, 36) != 32768 or le64(&block, 2496) != 31)
        return verifyFailure("space manager references");
    const spaceman_free = le64(&block, 72);
    try verifyBlock(init, file, 18, 0x8000_0011, &block); // reaper
    try verifyBlock(init, file, 25, 0x4000_000b, &block); // container OMAP object
    if (le64(&block, 48) != 26) return verifyFailure("container OMAP object");
    try verifyBlock(init, file, 26, 0x4000_0002, &block); // container OMAP tree
    if (le64(&block, 60) != 10 or le64(&block, 68) != 2 or le64(&block, 4048) != 27)
        return verifyFailure("container OMAP tree entry");
    try verifyBlock(init, file, 27, 0x0000_000d, &block); // volume superblock
    if (le32(&block, 32) != 0x4253_5041 or le64(&block, 8) != 10 or le64(&block, 128) != 28 or le64(&block, 136) != 13)
        return verifyFailure("volume superblock references");
    try verifyBlock(init, file, 28, 0x4000_000b, &block); // volume OMAP object
    if (le64(&block, 48) != 29) return verifyFailure("volume OMAP object");
    try verifyBlock(init, file, 29, 0x4000_0002, &block); // volume OMAP tree
    if (le64(&block, 60) != 13 or le64(&block, 68) != 2 or le64(&block, 4048) != 30)
        return verifyFailure("volume OMAP tree entry");
    try verifyBlock(init, file, 30, 0x0000_0002, &block); // filesystem B-tree
    if (le32(&block, 36) != 1 or le64(&block, 64) != (@as(u64, 3) << 60 | 2))
        return verifyFailure("filesystem root record");
    var cib: formatter.Block = undefined;
    try verifyBlock(init, file, 31, 0x4000_0007, &cib); // chunk info block

    const chunks = (block_count + 32767) / 32768;
        if (le32(&cib, 36) != chunks) return verifyFailure("CIB chunk count");
    const first_allocated = 32 + chunks;
    var total_free: u64 = 0;
    var bitmap: formatter.Block = undefined;
    for (0..chunks) |chunk| {
        const entry = 40 + chunk * 32;
        const start = @as(u64, chunk) * 32768;
        const count = @min(@as(u64, 32768), block_count - start);
        const bitmap_block = le64(&cib, entry + 24);
        if (le64(&cib, entry + 8) != start or le32(&cib, entry + 16) != count or bitmap_block != 32 + chunk)
            return verifyFailure("CIB chunk descriptor");
        const bitmap_offset = std.math.mul(u64, bitmap_block, formatter.block_size) catch return error.InvalidImageSize;
        const read = try file.readPositionalAll(init.io, &bitmap, bitmap_offset);
        if (read != bitmap.len) return verifyFailure("chunk bitmap read");
        var chunk_free: u32 = 0;
        for (0..count) |local| {
            const physical = start + local;
            const allocated = (bitmap[local / 8] & (@as(u8, 1) << @intCast(local % 8))) != 0;
            const expected_allocated = physical < first_allocated or physical >= block_count - 2;
            if (allocated != expected_allocated) return verifyFailure("chunk allocation bits");
            if (!allocated) chunk_free += 1;
        }
        if (le32(&cib, entry + 20) != chunk_free) return verifyFailure("CIB free count");
        total_free += chunk_free;
    }
    if (total_free != spaceman_free) return verifyFailure("space manager free count");
    const marker_offset = (block_count - 1) * formatter.block_size;
    const marker_read = try file.readPositionalAll(init.io, &block, marker_offset);
    if (marker_read != block.len or !validChecksum(&block) or
        !std.mem.eql(u8, block[344..352], "AETHAPFS") or le32(&block, 8) != 2)
        return verifyFailure("allocator marker");
}

fn rewriteVirginLegacy(init: std.process.Init, path: []const u8, bytes: []const u8) !void {
    if (!isVirginLegacyImage(bytes) and !isVirginCurrentImage(bytes)) {
        std.debug.print("Skipped APFS metadata upgrade; disk contains non-virgin or unrecognized state: {s}\n", .{path});
        return;
    }
    var file = try std.Io.Dir.cwd().openFile(init.io, path, .{ .mode = .read_write });
    var file_closed = false;
    defer if (!file_closed) file.close(init.io);
    var writer_buffer: [8192]u8 = undefined;
    var writer = file.writer(init.io, &writer_buffer);
    var context = Context{ .writer = &writer };
    const block_count = bytes.len / formatter.block_size;
    if (!formatter.format(block_count, "AetherOS", writeBlock, @ptrCast(&context))) return error.FormatFailed;
    try writer.interface.flush();
    try file.sync(init.io);
    file.close(init.io);
    file_closed = true;
    try verifyFormattedImage(init, path, block_count);
    std.debug.print("Upgraded pristine AetherOS APFS metadata in place: {s}\n", .{path});
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const upgrade = args.len == 3 and std.mem.eql(u8, args[1], "--upgrade-virgin");
    if ((!upgrade and args.len != 2) or (upgrade and args.len != 3)) return error.InvalidArguments;
    const path = args[if (upgrade) 2 else 1];
    if (upgrade) {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, path, arena, .limited(512 * 1024 * 1024));
        if (bytes.len < formatter.block_size * 256 or bytes.len % formatter.block_size != 0) return error.InvalidImageSize;
        return rewriteVirginLegacy(init, path, bytes);
    }

    var input_file = try std.Io.Dir.cwd().openFile(init.io, path, .{ .mode = .read_only });
    defer input_file.close(init.io);
    const image_size = (try input_file.stat(init.io)).size;
    if (image_size < formatter.block_size * 256 or image_size % formatter.block_size != 0) return error.InvalidImageSize;
    const block_count = image_size / formatter.block_size;
    if (block_count > formatter.max_formatted_blocks) return error.UnsupportedImageSize;
    const read_buffer = try arena.alloc(u8, 1024 * 1024);
    var file_reader_buffer: [4096]u8 = undefined;
    var file_reader = input_file.reader(init.io, &file_reader_buffer);
    var first_block: formatter.Block = undefined;
    try file_reader.interface.readSliceAll(&first_block);
    if (std.mem.eql(u8, first_block[32..36], "NXSB")) {
        std.debug.print("APFS container already present: {s}", .{path});
        return;
    }
    var all_zero = true;
    for (first_block) |byte| if (byte != 0) {
        all_zero = false;
        break;
    };
    var remaining = image_size - formatter.block_size;
    while (remaining != 0) {
        const amount: usize = @intCast(@min(remaining, read_buffer.len));
        try file_reader.interface.readSliceAll(read_buffer[0..amount]);
        for (read_buffer[0..amount]) |byte| if (byte != 0) {
            all_zero = false;
            break;
        };
        if (!all_zero) break;
        remaining -= amount;
    }
    if (!all_zero) {
        std.debug.print("Refusing to format non-empty disk image: {s}", .{path});
        return error.DiskImageNotBlank;
    }

    var file = try std.Io.Dir.cwd().openFile(init.io, path, .{ .mode = .read_write });
    var file_closed = false;
    defer if (!file_closed) file.close(init.io);
    var writer_buffer: [8192]u8 = undefined;
    var writer = file.writer(init.io, &writer_buffer);
    var context = Context{ .writer = &writer };
    if (!formatter.format(block_count, "AetherOS", writeBlock, @ptrCast(&context))) return error.FormatFailed;
    try writer.interface.flush();
    try file.sync(init.io);
    file.close(init.io);
    file_closed = true;
    try verifyFormattedImage(init, path, block_count);
    std.debug.print("Formatted blank image as AetherOS APFS: {s} ({d} blocks)", .{ path, block_count });
}
