//! PIC, IDT, PIT, and IRQ setup for the boot CPU.
const io = @import("io.zig");
const s = @import("../system/state.zig");
const gdt = @import("gdt.zig");

const Gate = packed struct {
    offset_low: u16 = 0,
    selector: u16 = 0,
    ist: u8 = 0,
    attributes: u8 = 0,
    offset_mid: u16 = 0,
    offset_high: u32 = 0,
    reserved: u32 = 0,
};
const Idtr = packed struct { limit: u16, base: u64 };
var idt: [256]Gate align(16) = @splat(.{});

extern fn aether_irq0_stub() callconv(.c) void;
extern fn aether_irq1_stub() callconv(.c) void;
extern fn aether_irq12_stub() callconv(.c) void;
extern fn aether_syscall_stub() callconv(.c) void;
extern fn aether_unhandled_stub() callconv(.c) void;
extern fn aether_exception_0_stub() callconv(.c) void;
extern fn aether_exception_1_stub() callconv(.c) void;
extern fn aether_exception_2_stub() callconv(.c) void;
extern fn aether_exception_3_stub() callconv(.c) void;
extern fn aether_exception_4_stub() callconv(.c) void;
extern fn aether_exception_5_stub() callconv(.c) void;
extern fn aether_exception_6_stub() callconv(.c) void;
extern fn aether_exception_7_stub() callconv(.c) void;
extern fn aether_exception_8_stub() callconv(.c) void;
extern fn aether_exception_9_stub() callconv(.c) void;
extern fn aether_exception_10_stub() callconv(.c) void;
extern fn aether_exception_11_stub() callconv(.c) void;
extern fn aether_exception_12_stub() callconv(.c) void;
extern fn aether_exception_13_stub() callconv(.c) void;
extern fn aether_exception_14_stub() callconv(.c) void;
extern fn aether_exception_15_stub() callconv(.c) void;
extern fn aether_exception_16_stub() callconv(.c) void;
extern fn aether_exception_17_stub() callconv(.c) void;
extern fn aether_exception_18_stub() callconv(.c) void;
extern fn aether_exception_19_stub() callconv(.c) void;
extern fn aether_exception_20_stub() callconv(.c) void;
extern fn aether_exception_21_stub() callconv(.c) void;
extern fn aether_exception_22_stub() callconv(.c) void;
extern fn aether_exception_23_stub() callconv(.c) void;
extern fn aether_exception_24_stub() callconv(.c) void;
extern fn aether_exception_25_stub() callconv(.c) void;
extern fn aether_exception_26_stub() callconv(.c) void;
extern fn aether_exception_27_stub() callconv(.c) void;
extern fn aether_exception_28_stub() callconv(.c) void;
extern fn aether_exception_29_stub() callconv(.c) void;
extern fn aether_exception_30_stub() callconv(.c) void;
extern fn aether_exception_31_stub() callconv(.c) void;

const exception_stubs = [_]*const fn () callconv(.c) void{
    &aether_exception_0_stub,  &aether_exception_1_stub,  &aether_exception_2_stub,  &aether_exception_3_stub,
    &aether_exception_4_stub,  &aether_exception_5_stub,  &aether_exception_6_stub,  &aether_exception_7_stub,
    &aether_exception_8_stub,  &aether_exception_9_stub,  &aether_exception_10_stub, &aether_exception_11_stub,
    &aether_exception_12_stub, &aether_exception_13_stub, &aether_exception_14_stub, &aether_exception_15_stub,
    &aether_exception_16_stub, &aether_exception_17_stub, &aether_exception_18_stub, &aether_exception_19_stub,
    &aether_exception_20_stub, &aether_exception_21_stub, &aether_exception_22_stub, &aether_exception_23_stub,
    &aether_exception_24_stub, &aether_exception_25_stub, &aether_exception_26_stub, &aether_exception_27_stub,
    &aether_exception_28_stub, &aether_exception_29_stub, &aether_exception_30_stub, &aether_exception_31_stub,
};

fn setGate(vector: usize, address: usize, selector: u16, attributes: u8) void {
    idt[vector] = .{
        .offset_low = @truncate(address),
        .selector = selector,
        .ist = 0,
        .attributes = attributes,
        .offset_mid = @truncate(address >> 16),
        .offset_high = @truncate(address >> 32),
        .reserved = 0,
    };
}

fn ioWait() void { io.out8(0x80, 0); }

fn remapPic() void {
    io.out8(0x20, 0x11); ioWait();
    io.out8(0xa0, 0x11); ioWait();
    io.out8(0x21, 0x20); ioWait();
    io.out8(0xa1, 0x28); ioWait();
    io.out8(0x21, 0x04); ioWait();
    io.out8(0xa1, 0x02); ioWait();
    io.out8(0x21, 0x01); ioWait();
    io.out8(0xa1, 0x01); ioWait();
    io.out8(0x21, 0xf8); // IRQ0, IRQ1, and slave cascade.
    io.out8(0xa1, 0xef); // IRQ12 on the slave PIC.
}

pub fn init() void {
    gdt.init();
    var selector: u16 = 0;
    asm volatile ("movw %%cs, %[selector]" : [selector] "=r" (selector));
    const default = @intFromPtr(&aether_unhandled_stub);
    for (0..idt.len) |vector| setGate(vector, default, selector, 0x8e);
    for (exception_stubs, 0..) |stub, vector| setGate(vector, @intFromPtr(stub), selector, 0x8e);
    setGate(0x20, @intFromPtr(&aether_irq0_stub), selector, 0x8e);
    setGate(0x21, @intFromPtr(&aether_irq1_stub), selector, 0x8e);
    setGate(0x2c, @intFromPtr(&aether_irq12_stub), selector, 0x8e);
    setGate(0x80, @intFromPtr(&aether_syscall_stub), selector, 0xee); // DPL 3 syscall gate.
    const idtr = Idtr{ .limit = @sizeOf(@TypeOf(idt)) - 1, .base = @intFromPtr(&idt) };
    asm volatile ("lidt (%[descriptor])" :: [descriptor] "r" (&idtr));

    remapPic();
    io.out8(0x43, 0x36);
    const divisor: u16 = 11_931; // Approximately 100 Hz.
    io.out8(0x40, @truncate(divisor));
    io.out8(0x40, @truncate(divisor >> 8));
    asm volatile ("sti");
}

pub export fn aether_irq_timer() callconv(.c) void {
    s.advanceUptime();
    const irq_count: *volatile u64 = &s.timer_irq_count;
    irq_count.* +%= 1;
    io.out8(0x20, 0x20);
}
