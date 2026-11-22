//! Four-level x86-64 page mapper and virtual-page allocator.
const pmm = @import("pmm.zig");
const entry_mask: u64 = 0x000ffffffffff000;
const present_write: u64 = 0x003;
var hhdm_offset: u64 = 0;
var next_virtual: u64 = 0xffffc00000000000;

pub fn init(offset: u64) bool {
    hhdm_offset = offset;
    return true;
}

fn tableAt(physical: u64) [*]u64 {
    return @ptrFromInt(hhdm_offset + physical);
}

fn ensureChild(parent: [*]u64, index: usize, user: bool) ?[*]u64 {
    if ((parent[index] & 1) == 0) {
        const physical = pmm.allocatePage() orelse return null;
        const child = tableAt(physical);
        @memset(child[0..512], 0);
        parent[index] = (physical & entry_mask) | present_write | if (user) @as(u64, 4) else 0;
    } else if ((parent[index] & 0x80) != 0) {
        return null; // Existing 1 GiB or 2 MiB leaf; do not descend through it.
    } else if (user) {
        parent[index] |= 4;
    }
    return tableAt(parent[index] & entry_mask);
}

fn mapPageInRoot(root_phys: u64, virtual: u64, physical: u64, user: bool, leaf_flags: u64) bool {
    const pml4 = tableAt(root_phys & entry_mask);
    const l4 = @as(usize, @truncate((virtual >> 39) & 0x1ff));
    const l3 = @as(usize, @truncate((virtual >> 30) & 0x1ff));
    const l2 = @as(usize, @truncate((virtual >> 21) & 0x1ff));
    const l1 = @as(usize, @truncate((virtual >> 12) & 0x1ff));
    const pdpt = ensureChild(pml4, l4, user) orelse return false;
    const pd = ensureChild(pdpt, l3, user) orelse return false;
    const pt = ensureChild(pd, l2, user) orelse return false;
    if ((pt[l1] & 1) != 0) return false;
    pt[l1] = (physical & entry_mask) | leaf_flags | if (user) @as(u64, 4) else 0;
    var active_root: u64 = undefined;
    asm volatile ("movq %cr3, %[root]"
        : [root] "=r" (active_root),
    );
    if ((active_root & entry_mask) == (root_phys & entry_mask))
        asm volatile ("invlpg (%[address])"
            :
            : [address] "r" (virtual),
            : .{ .memory = true });
    return true;
}

fn mapPage(virtual: u64, physical: u64) bool {
    return mapPageInRoot(currentRoot(), virtual, physical, false, present_write);
}

/// Map a physical MMIO range into the kernel's reserved high virtual window.
/// PCD/PWT disable caching for device register accesses.
pub fn mapMmio(physical: u64, length: usize) ?[*]volatile u8 {
    if (length == 0 or physical + length < physical) return null;
    const page_offset = physical & (pmm.page_size - 1);
    const aligned_physical = physical & ~(pmm.page_size - 1);
    const covered = page_offset + length;
    const page_count: usize = @intCast((covered + pmm.page_size - 1) / pmm.page_size);
    const virtual_base = next_virtual;
    const mapped_bytes = @as(u64, @intCast(page_count)) * pmm.page_size;
    if (virtual_base + mapped_bytes < virtual_base or virtual_base + mapped_bytes >= 0xffffe00000000000) return null;
    var mapped: usize = 0;
    while (mapped < page_count) : (mapped += 1) {
        const phys = aligned_physical + @as(u64, @intCast(mapped)) * pmm.page_size;
        if (!mapPageInRoot(currentRoot(), virtual_base + @as(u64, @intCast(mapped)) * pmm.page_size, phys, false, present_write | 0x18)) return null;
    }
    next_virtual += mapped_bytes;
    return @ptrFromInt(virtual_base + page_offset);
}

pub fn physicalToVirtual(physical: u64) u64 {
    return hhdm_offset + physical;
}

pub fn currentRoot() u64 {
    var root: u64 = undefined;
    asm volatile ("movq %cr3, %[root]"
        : [root] "=r" (root),
    );
    return root & entry_mask;
}

pub fn switchAddressSpace(root_physical: u64) void {
    asm volatile ("movq %[root], %cr3"
        :
        : [root] "r" (root_physical & entry_mask),
        : .{ .memory = true });
}

/// Clone the current kernel mappings into a new root. The user PML4 slot is
/// deliberately empty and will be populated only for this address space.
pub fn createAddressSpace() ?u64 {
    const root = pmm.allocatePage() orelse return null;
    const new_table = tableAt(root);
    const active_table = tableAt(currentRoot());
    @memcpy(new_table[0..512], active_table[0..512]);
    new_table[1] = 0;
    return root;
}

/// Map user pages in the currently reserved 512 GiB PML4 slot.
pub fn mapUserPage(root_physical: u64, virtual: u64, physical: u64) bool {
    const user_base: u64 = 0x0000008000000000;
    const user_end: u64 = 0x0000010000000000;
    if (virtual < user_base or virtual >= user_end or
        (virtual & (pmm.page_size - 1)) != 0 or (physical & (pmm.page_size - 1)) != 0)
        return false;
    return mapPageInRoot(root_physical, virtual, physical, true, present_write);
}

/// Destroy an address space created by createAddressSpace with its private
/// user mappings in PML4 slot 1. Kernel page-table branches are shared.
pub fn destroyAddressSpace(root_physical: u64) void {
    const root = tableAt(root_physical);
    if ((root[1] & 1) != 0) {
        const pdpt_physical = root[1] & entry_mask;
        const pdpt = tableAt(pdpt_physical);
        for (pdpt[0..512]) |pdpt_entry| {
            if ((pdpt_entry & 1) == 0 or (pdpt_entry & 0x80) != 0) continue;
            const pd_physical = pdpt_entry & entry_mask;
            const pd = tableAt(pd_physical);
            for (pd[0..512]) |pd_entry| {
                if ((pd_entry & 1) == 0 or (pd_entry & 0x80) != 0) continue;
                const pt_physical = pd_entry & entry_mask;
                const pt = tableAt(pt_physical);
                for (pt[0..512]) |*page_entry| {
                    if ((page_entry.* & 1) != 0) {
                        pmm.freePage(page_entry.* & entry_mask);
                        page_entry.* = 0;
                    }
                }
                pmm.freePage(pt_physical);
            }
            pmm.freePage(pd_physical);
        }
        pmm.freePage(pdpt_physical);
        root[1] = 0;
    }
    pmm.freePage(root_physical);
}

pub fn allocatePages(count: usize) ?[*]u8 {
    if (count == 0 or count > 0x100000) return null;
    const bytes = @as(u64, @intCast(count)) * pmm.page_size;
    const base = next_virtual;
    if (base + bytes < base or base + bytes >= 0xffffe00000000000) return null;
    var mapped: usize = 0;
    while (mapped < count) : (mapped += 1) {
        const physical = pmm.allocatePage() orelse break;
        if (!mapPage(base + @as(u64, @intCast(mapped)) * pmm.page_size, physical)) {
            pmm.freePage(physical);
            break;
        }
    }
    if (mapped != count) {
        var rollback: usize = 0;
        while (rollback < mapped) : (rollback += 1) freePage(base + @as(u64, @intCast(rollback)) * pmm.page_size);
        return null;
    }
    next_virtual += bytes;
    return @ptrFromInt(base);
}

pub fn freePage(virtual: u64) void {
    if ((virtual & (pmm.page_size - 1)) != 0) return;
    var root_phys: u64 = undefined;
    asm volatile ("movq %cr3, %[root]"
        : [root] "=r" (root_phys),
    );
    const l4 = @as(usize, @truncate((virtual >> 39) & 0x1ff));
    const l3 = @as(usize, @truncate((virtual >> 30) & 0x1ff));
    const l2 = @as(usize, @truncate((virtual >> 21) & 0x1ff));
    const l1 = @as(usize, @truncate((virtual >> 12) & 0x1ff));
    const pml4 = tableAt(root_phys & entry_mask);
    if ((pml4[l4] & 1) == 0) return;
    const pdpt = tableAt(pml4[l4] & entry_mask);
    if ((pdpt[l3] & 1) == 0 or (pdpt[l3] & 0x80) != 0) return;
    const pd = tableAt(pdpt[l3] & entry_mask);
    if ((pd[l2] & 1) == 0 or (pd[l2] & 0x80) != 0) return;
    const pt = tableAt(pd[l2] & entry_mask);
    const physical = pt[l1] & entry_mask;
    if ((pt[l1] & 1) == 0) return;
    pt[l1] = 0;
    asm volatile ("invlpg (%[address])"
        :
        : [address] "r" (virtual),
        : .{ .memory = true });
    pmm.freePage(physical);
}

pub export fn aether_allocate_virtual_pages(count: usize) callconv(.c) ?[*]u8 {
    return allocatePages(count);
}

pub export fn aether_free_virtual_page(address: u64) callconv(.c) void {
    freePage(address);
}
