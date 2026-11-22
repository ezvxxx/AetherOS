//! Kernel/user GDT and the 64-bit task-state segment used for ring transitions.
const Tss = packed struct {
    reserved0: u32 = 0,
    rsp0: u64 = 0,
    rsp1: u64 = 0,
    rsp2: u64 = 0,
    reserved1: u64 = 0,
    ist1: u64 = 0,
    ist2: u64 = 0,
    ist3: u64 = 0,
    ist4: u64 = 0,
    ist5: u64 = 0,
    ist6: u64 = 0,
    ist7: u64 = 0,
    reserved2: u64 = 0,
    reserved3: u16 = 0,
    io_map_base: u16 = @sizeOf(Tss),
};

const DescriptorPointer = packed struct { limit: u16, base: u64 };
const tss_selector: u16 = 0x28;
const kernel_data_selector: u16 = 0x10;
var gdt = [_]u64{
    0,
    0x00af9a000000ffff, // 0x08: 64-bit ring 0 code.
    0x00cf92000000ffff, // 0x10: ring 0 data.
    0x00cff2000000ffff, // 0x18: ring 3 data.
    0x00affa000000ffff, // 0x20: 64-bit ring 3 code.
    0,
    0,
};
var tss: Tss align(16) = .{};
var ready = false;

extern fn aether_load_gdt(descriptor: *const DescriptorPointer) callconv(.c) void;

pub fn init() void {
    const base = @intFromPtr(&tss);
    const limit: u64 = @sizeOf(Tss) - 1;
    gdt[5] = (limit & 0xffff) |
        ((base & 0xffffff) << 16) |
        (@as(u64, 0x89) << 40) |
        (((limit >> 16) & 0xf) << 48) |
        (((base >> 24) & 0xff) << 56);
    gdt[6] = base >> 32;
    tss.io_map_base = @sizeOf(Tss);
    const descriptor = DescriptorPointer{ .limit = @sizeOf(@TypeOf(gdt)) - 1, .base = @intFromPtr(&gdt) };
    aether_load_gdt(&descriptor);
    ready = true;
}

pub fn setKernelStack(stack_top: u64) void {
    tss.rsp0 = stack_top;
}

pub fn isReady() bool {
    return ready;
}

pub const user_code_selector: u16 = 0x23;
pub const user_data_selector: u16 = 0x1b;
pub const kernel_code_selector: u16 = 0x08;
