//! Early kernel bump heap. The arena is statically mapped by the bootloader.
const std = @import("std");
// Scoped image decoding uses this scratch arena and rewinds it after each
// decode. The persistent framebuffer copy lives in VM-backed pages instead.
const capacity = 192 * 1024 * 1024;
var arena: [capacity]u8 align(4096) = undefined;
var cursor: usize = 0;

pub fn allocate(size: usize, alignment: usize) ?[*]u8 {
    if (size == 0 or alignment == 0 or (alignment & (alignment - 1)) != 0) return null;
    const aligned = (cursor + alignment - 1) & ~(alignment - 1);
    if (aligned > arena.len or size > arena.len - aligned) return null;
    cursor = aligned + size;
    return @ptrCast(&arena[aligned]);
}

pub fn usedBytes() usize { return cursor; }
pub fn capacityBytes() usize { return arena.len; }
pub fn mark() usize { return cursor; }
pub fn rewind(mark_value: usize) void {
    if (mark_value <= cursor) cursor = mark_value;
}

fn allocatorAlloc(_: *anyopaque, size: usize, alignment: std.mem.Alignment, return_address: usize) ?[*]u8 {
    _ = return_address;
    return allocate(size, alignment.toByteUnits());
}

fn allocatorResize(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_size: usize, return_address: usize) bool {
    _ = alignment;
    _ = return_address;
    return new_size <= memory.len;
}

fn allocatorRemap(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_size: usize, return_address: usize) ?[*]u8 {
    _ = alignment;
    _ = return_address;
    return if (new_size <= memory.len) memory.ptr else null;
}

fn allocatorFree(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, return_address: usize) void {
    _ = memory;
    _ = alignment;
    _ = return_address;
}

const allocator_vtable: std.mem.Allocator.VTable = .{
    .alloc = allocatorAlloc,
    .resize = allocatorResize,
    .remap = allocatorRemap,
    .free = allocatorFree,
};

/// A bounded allocator over the early heap. Frees are intentionally no-ops;
/// use it for boot-lifetime data such as certificate bundles.
pub fn allocator() std.mem.Allocator {
    return .{ .ptr = @ptrCast(&arena), .vtable = &allocator_vtable };
}
