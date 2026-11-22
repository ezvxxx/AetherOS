//! Stable handoff shared by AetherOS bootloaders and the kernel.
pub const MemoryRegion = extern struct {
    base: u64,
    length: u64,
    kind: u64, // 0 = usable RAM; all other values are reserved.
};

pub const BootInfo = extern struct {
    magic: u64,
    firmware: u64, // 0 = BIOS, 1 = UEFI
    framebuffer: u64,
    width: u64,
    height: u64,
    pitch: u64,
    bpp: u16,
    red_mask_size: u8,
    red_mask_shift: u8,
    green_mask_size: u8,
    green_mask_shift: u8,
    blue_mask_size: u8,
    blue_mask_shift: u8,
    reserved: u8,
    memory_region_count: u16,
    hhdm_offset: u64,
    acpi_rsdp: u64,
    memory_regions: [*]const MemoryRegion,
};

pub const magic: u64 = 0x4145544845524249; // "AETHERBI"
