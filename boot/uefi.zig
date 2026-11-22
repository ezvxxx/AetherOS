//! Standalone AetherOS UEFI loader. It embeds and loads the ELF kernel, then
//! exits firmware services and transfers control through boot/info.zig.
const std = @import("std");
const uefi = std.os.uefi;
const boot = @import("info.zig");
const GraphicsOutput = uefi.protocol.GraphicsOutput;

const ElfHeader = extern struct {
    ident: [16]u8, kind: u16, machine: u16, version: u32, entry: u64,
    phoff: u64, shoff: u64, flags: u32, ehsize: u16, phentsize: u16,
    phnum: u16, shentsize: u16, shnum: u16, shstrndx: u16,
};
const ProgramHeader = extern struct {
    kind: u32, flags: u32, offset: u64, vaddr: u64, paddr: u64,
    filesz: u64, memsz: u64, align_value: u64,
};
const hhdm_offset: u64 = 0xffff800000000000;

var boot_info: boot.BootInfo = undefined;
var regions: [256]boot.MemoryRegion = undefined;

fn outputAscii(message: []const u8) void {
    var wide: [96]u16 = undefined;
    const length = @min(message.len, wide.len - 1);
    for (message[0..length], 0..) |ch, i| wide[i] = ch;
    wide[length] = 0;
    if (uefi.system_table.con_out) |output| _ = output.outputString(@ptrCast(&wide)) catch {};
}

fn statusFor(err: anyerror) uefi.Status {
    return switch (err) {
        error.NotFound => .not_found,
        error.OutOfResources => .out_of_resources,
        error.InvalidParameter => .invalid_parameter,
        else => .load_error,
    };
}

fn loadKernel() !u64 {
    const bs = uefi.system_table.boot_services.?;
    const loaded = (try bs.handleProtocol(uefi.protocol.LoadedImage, uefi.handle)) orelse return error.NotFound;
    const device = loaded.device_handle orelse return error.NotFound;
    const filesystem = (try bs.handleProtocol(uefi.protocol.SimpleFileSystem, device)) orelse return error.NotFound;
    const root = try filesystem.openVolume();
    defer root.close() catch {};
    const kernel_path = [_:0]u16{ '\\', 'K', 'E', 'R', 'N', 'E', 'L', '.', 'E', 'L', 'F' };
    const iso_kernel_path = [_:0]u16{ '\\', 'b', 'o', 'o', 't', '\\', 'k', 'e', 'r', 'n', 'e', 'l', '.', 'e', 'l', 'f' };
    const file = root.open(&kernel_path, .read, .{}) catch try root.open(&iso_kernel_path, .read, .{});
    defer file.close() catch {};
    const info_size = try file.getInfoSize(.file);
    const info_buffer = try bs.allocatePool(.loader_data, info_size);
    defer bs.freePool(info_buffer.ptr) catch {};
    const file_info = try file.getInfo(.file, info_buffer);
    const file_size = std.math.cast(usize, file_info.file_size) orelse return error.KernelFileTooLarge;
    if (file_size < @sizeOf(ElfHeader)) return error.KernelFileTooSmall;
    // Keep only the small ELF header table in loader memory. Allocating a
    // second complete copy of this kernel used to require ~230 MiB of EFI pool
    // on top of the loaded segments, which failed with OutOfResources.
    var header_bytes: [4096]u8 = undefined;
    try file.setPosition(0);
    const header_read = try file.read(&header_bytes);
    if (header_read < @sizeOf(ElfHeader)) return error.KernelFileTooSmall;
    const eh: *align(1) const ElfHeader = @ptrCast(&header_bytes);
    if (!std.mem.eql(u8, eh.ident[0..4], "\x7fELF")) return error.KernelBadMagic;
    if (eh.machine != 62 or eh.phentsize != @sizeOf(ProgramHeader)) return error.KernelBadElfHeader;
    const table_bytes = std.math.mul(usize, eh.phnum, eh.phentsize) catch return error.KernelBadElfHeader;
    if (eh.phoff > file_size or table_bytes > file_size - eh.phoff) return error.KernelProgramHeaderTableOutOfBounds;
    if (eh.phoff > header_read or table_bytes > header_read - eh.phoff) return error.KernelProgramHeaderTableOutOfBounds;
    var i: usize = 0;
    while (i < eh.phnum) : (i += 1) {
        const ph: *align(1) const ProgramHeader = @ptrCast(header_bytes[eh.phoff + i * eh.phentsize ..].ptr);
        if (ph.kind != 1 or ph.memsz == 0) continue;
        if (ph.filesz > ph.memsz or ph.offset > file_size or ph.filesz > file_size - ph.offset) return error.KernelSegmentOutOfBounds;
        if (ph.paddr < 0x100000) return error.KernelSegmentAddressInvalid;
        const start = ph.paddr & ~@as(u64, 0xfff);
        const raw_end = std.math.add(u64, ph.paddr, ph.memsz) catch return error.KernelSegmentOutOfBounds;
        const end_unaligned = std.math.add(u64, raw_end, 0xfff) catch return error.KernelSegmentOutOfBounds;
        const end = end_unaligned & ~@as(u64, 0xfff);
        const dest: [*]align(4096) uefi.Page = @ptrFromInt(start);
        _ = uefi.system_table.boot_services.?.allocatePages(.{ .address = dest }, .loader_data, @intCast((end - start) / 4096)) catch |err| {
            outputAscii("AetherOS: physical allocation failed at kernel segment\r\n");
            return err;
        };
        try file.setPosition(ph.offset);
        const dst: [*]u8 = @ptrFromInt(ph.paddr);
        var copied: usize = 0;
        const file_bytes: usize = @intCast(ph.filesz);
        while (copied < file_bytes) {
            const chunk = @min(file_bytes - copied, 1024 * 1024);
            const count = try file.read(dst[copied .. copied + chunk]);
            if (count == 0) return error.KernelReadEof;
            copied += count;
        }
        @memset(dst[file_bytes..@intCast(ph.memsz)], 0);
    }
    return eh.entry;
}

fn preferredDisplayResolution() ?struct { width: u32, height: u32 } {
    const protocol = (uefi.system_table.boot_services.?.locateProtocol(uefi.protocol.edid.Active, null) catch null) orelse return null;
    const data = protocol.edid orelse return null;
    if (protocol.size_of_edid < 128) return null;
    const edid_data = data[0..protocol.size_of_edid];
    if (!std.mem.eql(u8, edid_data[0..8], "\x00\xff\xff\xff\xff\xff\xff\x00")) return null;
    var checksum: u8 = 0;
    for (edid_data[0..128]) |byte| checksum +%= byte;
    if (checksum != 0) return null;

    // The first detailed timing descriptor in the base EDID block is the
    // preferred/native timing on standard EDID 1.x displays.
    const timing = edid_data[54..72];
    if (timing[0] == 0 and timing[1] == 0) return null;
    const width: u32 = @as(u32, timing[2]) | (@as(u32, timing[4] & 0xf0) << 4);
    const height: u32 = @as(u32, timing[5]) | (@as(u32, timing[7] & 0xf0) << 4);
    if (width == 0 or height == 0) return null;
    return .{ .width = width, .height = height };
}

fn initGraphics() !void {
    const bs = uefi.system_table.boot_services.?;
    const gop = (try bs.locateProtocol(GraphicsOutput, null)) orelse return error.NotFound;

    // Use the display's EDID native timing rather than the largest mode the
    // graphics device happens to expose (which may be an upscaled mode).
    if (preferredDisplayResolution()) |preferred| {
        var mode_id: u32 = 0;
        while (mode_id < gop.mode.max_mode) : (mode_id += 1) {
            const mode_info = gop.queryMode(mode_id) catch continue;
            const matches = mode_info.horizontal_resolution == preferred.width and
                mode_info.vertical_resolution == preferred.height and
                mode_info.pixel_format != .blt_only and
                mode_info.pixels_per_scan_line >= mode_info.horizontal_resolution and
                @as(u64, mode_info.pixels_per_scan_line) * mode_info.vertical_resolution * 4 <= 128 * 1024 * 1024;
            bs.freePool(@ptrCast(@alignCast(mode_info))) catch {};
            if (matches) {
                gop.setMode(mode_id) catch {};
                break;
            }
        }
    }

    const mode = gop.mode.info.*;
    if (mode.pixel_format == .blt_only) return error.Unsupported;
    const masks = switch (mode.pixel_format) {
        .red_green_blue_reserved_8_bit_per_color => .{ 0x000000ff, 0x0000ff00, 0x00ff0000 },
        .blue_green_red_reserved_8_bit_per_color => .{ 0x00ff0000, 0x0000ff00, 0x000000ff },
        .bit_mask => .{ mode.pixel_information.red_mask, mode.pixel_information.green_mask, mode.pixel_information.blue_mask },
        .blt_only => unreachable,
    };
    boot_info.framebuffer = gop.mode.frame_buffer_base;
    boot_info.width = mode.horizontal_resolution;
    boot_info.height = mode.vertical_resolution;
    boot_info.pitch = @as(u64, mode.pixels_per_scan_line) * 4;
    boot_info.bpp = 32;
    boot_info.red_mask_size = @intCast(@popCount(masks[0]));
    boot_info.red_mask_shift = @intCast(@ctz(masks[0]));
    boot_info.green_mask_size = @intCast(@popCount(masks[1]));
    boot_info.green_mask_shift = @intCast(@ctz(masks[1]));
    boot_info.blue_mask_size = @intCast(@popCount(masks[2]));
    boot_info.blue_mask_shift = @intCast(@ctz(masks[2]));
}

/// Construct clean identity and HHDM maps before leaving firmware. The kernel
/// uses physical pointers during early memory setup, so relying on the
/// firmware's private page tables would fault on some UEFI implementations.
fn setupPageTables() !u64 {
    const bs = uefi.system_table.boot_services.?;
    const pages = try bs.allocatePages(.any, .loader_data, 6);
    const physical = @intFromPtr(pages.ptr);
    const pml4: [*]u64 = @ptrCast(@alignCast(pages.ptr));
    const pdpt: [*]u64 = @ptrFromInt(physical + 4096);
    @memset(pml4[0..512], 0);
    @memset(pdpt[0..512], 0);
    pml4[0] = (physical + 4096) | 0x03;
    pml4[256] = (physical + 4096) | 0x03; // 0xffff800000000000 HHDM
    var pd_index: usize = 0;
    while (pd_index < 4) : (pd_index += 1) {
        const pd_phys = physical + 8192 + @as(u64, @intCast(pd_index)) * 4096;
        const pd: [*]u64 = @ptrFromInt(pd_phys);
        @memset(pd[0..512], 0);
        pdpt[pd_index] = pd_phys | 0x03;
        var page: usize = 0;
        while (page < 512) : (page += 1) {
            const address = (@as(u64, @intCast(pd_index * 512 + page))) * 0x200000;
            pd[page] = address | 0x83; // present, writable, 2 MiB page
        }
    }
    return physical;
}

fn captureMemoryMapAndExit() !void {
    const bs = uefi.system_table.boot_services.?;
    const sizing = try bs.getMemoryMapInfo();
    const buffer = try bs.allocatePool(.loader_data, (sizing.len + 24) * sizing.descriptor_size);
    const map = try bs.getMemoryMap(buffer);
    var iter = map.iterator();
    var count: usize = 0;
    while (iter.next()) |descriptor| {
        if (count == regions.len) break;
        regions[count] = .{
            .base = descriptor.physical_start,
            .length = descriptor.number_of_pages * 4096,
            .kind = if (descriptor.type == .conventional_memory) 0 else 1,
        };
        count += 1;
    }
    boot_info.magic = boot.magic;
    boot_info.firmware = 1;
    boot_info.hhdm_offset = hhdm_offset;
    boot_info.acpi_rsdp = findAcpiRsdp();
    boot_info.memory_region_count = @intCast(count);
    boot_info.memory_regions = &regions;
    try bs.exitBootServices(uefi.handle, map.info.key);
}

fn findAcpiRsdp() u64 {
    const system_table = uefi.system_table;
    const entries = system_table.configuration_table[0..system_table.number_of_table_entries];
    for (entries) |entry| {
        if (entry.vendor_guid.eql(uefi.tables.ConfigurationTable.acpi_20_table_guid) or
            entry.vendor_guid.eql(uefi.tables.ConfigurationTable.acpi_10_table_guid))
        {
            return @intFromPtr(entry.vendor_table);
        }
    }
    return 0;
}

pub fn main() uefi.Status {
    initGraphics() catch |err| {
        _ = uefi.system_table.con_out.?.outputString(&[_:0]u16{ 'A', 'e', 't', 'h', 'e', 'r', 'O', 'S', ':', ' ', 'G', 'O', 'P', ' ', 'i', 'n', 'i', 't', ' ', 'f', 'a', 'i', 'l', 'e', 'd', 13, 10 }) catch {};
        return statusFor(err);
    };
    const entry = loadKernel() catch |err| {
        outputAscii("AetherOS: kernel load failed: ");
        outputAscii(@errorName(err));
        outputAscii("\r\n");
        return statusFor(err);
    };
    const page_root = setupPageTables() catch |err| {
        _ = uefi.system_table.con_out.?.outputString(&[_:0]u16{ 'A', 'e', 't', 'h', 'e', 'r', 'O', 'S', ':', ' ', 'p', 'a', 'g', 'e', ' ', 't', 'a', 'b', 'l', 'e', ' ', 's', 'e', 't', 'u', 'p', ' ', 'f', 'a', 'i', 'l', 'e', 'd', 13, 10 }) catch {};
        return statusFor(err);
    };
    captureMemoryMapAndExit() catch |err| {
        _ = uefi.system_table.con_out.?.outputString(&[_:0]u16{ 'A', 'e', 't', 'h', 'e', 'r', 'O', 'S', ':', ' ', 'e', 'x', 'i', 't', ' ', 'B', 'o', 'o', 't', ' ', 'S', 'e', 'r', 'v', 'i', 'c', 'e', 's', ' ', 'f', 'a', 'i', 'l', 'e', 'd', 13, 10 }) catch {};
        return statusFor(err);
    };
    asm volatile (
        \\cli
        \\mov %%rax, %%cr3
        \\andq $-16, %%rsp
        \\subq $8, %%rsp
        \\jmp *%%rsi
        :
        : [page_root] "{rax}" (page_root), [boot_info] "{rdi}" (&boot_info), [entry] "{rsi}" (entry)
        : .{ .memory = true }
    );
    unreachable;
}
