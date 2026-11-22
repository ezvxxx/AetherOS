//! Physical page-frame allocator populated from the AetherOS boot memory map.
const boot = @import("../boot/info.zig");

pub const page_size: u64 = 4096;
const mapped_physical_limit: u64 = 0x1_0000_0000; // Current boot page tables map 4 GiB.
const max_regions = 128;
const max_freed_pages = 4096;
const Region = struct { next: u64, end: u64 };
var regions: [max_regions]Region = undefined;
var region_count: usize = 0;
var region_index: usize = 0;
var freed: [max_freed_pages]u64 = undefined;
var freed_count: usize = 0;
var total_pages: u64 = 0;
var allocated_pages: u64 = 0;

pub fn init(entries: []const boot.MemoryRegion) bool {
    region_count = 0;
    region_index = 0;
    freed_count = 0;
    total_pages = 0;
    allocated_pages = 0;
    for (entries) |entry| {
        if (region_count >= regions.len) break;
        if (entry.kind != 0 or entry.length < page_size) continue;
        if (entry.base >= mapped_physical_limit) continue;
        const start = (entry.base + page_size - 1) & ~(page_size - 1);
        const raw_end = entry.base + entry.length;
        const end = @min(raw_end, mapped_physical_limit) & ~(page_size - 1);
        if (end <= start) continue;
        regions[region_count] = .{ .next = start, .end = end };
        total_pages += (end - start) / page_size;
        region_count += 1;
    }
    return region_count != 0;
}

pub fn allocatePage() ?u64 {
    if (freed_count != 0) {
        freed_count -= 1;
        allocated_pages += 1;
        return freed[freed_count];
    }
    while (region_index < region_count) {
        const index = region_index;
        if (regions[index].next < regions[index].end) {
            const result = regions[index].next;
            regions[index].next += page_size;
            allocated_pages += 1;
            return result;
        }
        region_index += 1;
    }
    return null;
}

pub fn freePage(physical: u64) void {
    if ((physical & (page_size - 1)) != 0 or freed_count == freed.len) return;
    if (allocated_pages != 0) allocated_pages -= 1;
    freed[freed_count] = physical;
    freed_count += 1;
}

pub fn totalMemoryBytes() u64 { return total_pages * page_size; }
pub fn usedMemoryBytes() u64 { return allocated_pages * page_size; }
pub fn freeMemoryBytes() u64 { return totalMemoryBytes() -| usedMemoryBytes(); }
