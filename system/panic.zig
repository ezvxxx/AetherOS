//! Minimal panic and CPU exception reporting for the freestanding kernel.
//! Output is sent to COM1 (QEMU -serial) and the framebuffer when available.
const std = @import("std");
const cpu = @import("../arch/cpu.zig");
const io = @import("../arch/io.zig");
const state = @import("state.zig");
const font = @import("../graphics/font.zig");

pub const panic = std.debug.FullPanic(panicMessage);

var framebuffer_ready = false;
var panicking = false;
var serial_ready = false;
var screen_x: u64 = 16;
var screen_y: u64 = 16;

pub fn setFramebufferReady() void {
    framebuffer_ready = true;
}

fn serialInit() void {
    io.out8(0x3f9, 0x00);
    io.out8(0x3fb, 0x80);
    io.out8(0x3f8, 0x01); // 115200 baud divisor.
    io.out8(0x3f9, 0x00);
    io.out8(0x3fb, 0x03); // 8N1.
    io.out8(0x3fa, 0xc7);
    io.out8(0x3fc, 0x0b);
    serial_ready = true;
}

/// Breadcrumbs for a synchronous kernel path that can stop before panicking.
pub fn trace(message: []const u8) void {
    if (!serial_ready) serialInit();
    serialText("[AetherOS] ");
    serialText(message);
    serialText("\r\n");
}

fn serialByte(byte: u8) void {
    var attempts: usize = 0;
    while (attempts < 100_000) : (attempts += 1) {
        if ((io.in8(0x3fd) & 0x20) != 0) {
            io.out8(0x3f8, byte);
            return;
        }
    }
}

fn serialText(text: []const u8) void {
    for (text) |byte| serialByte(byte);
}

fn serialHex(value: u64) void {
    const digits = "0123456789abcdef";
    serialText("0x");
    var shift: u6 = 60;
    while (true) : (shift -= 4) {
        serialByte(digits[@as(usize, @intCast((value >> shift) & 0xf))]);
        if (shift == 0) break;
    }
}

fn pixel(x: u64, y: u64, color: u32) void {
    if (!framebuffer_ready or x >= state.fb.width or y >= state.fb.height) return;
    const address = state.fb.address orelse return;
    const stride: usize = @intCast(state.fb.pitch / 4);
    const pixels: [*]volatile u32 = @ptrCast(@alignCast(address));
    pixels[@as(usize, @intCast(y)) * stride + @as(usize, @intCast(x))] = color;
}

fn fill(color: u32) void {
    if (!framebuffer_ready) return;
    var y: u64 = 0;
    while (y < state.fb.height) : (y += 1) {
        var x: u64 = 0;
        while (x < state.fb.width) : (x += 1) pixel(x, y, color);
    }
}

fn drawByte(byte: u8) void {
    if (!framebuffer_ready) return;
    if (byte == '\n' or screen_x + 8 >= state.fb.width) {
        screen_x = 16;
        screen_y += 12;
    }
    if (screen_y + 8 >= state.fb.height) return;
    if (byte != '\n') {
        const rows = font.glyph(byte);
        for (rows, 0..) |bits, row| {
            var col: u8 = 0;
            while (col < 5) : (col += 1) {
                if ((bits & (@as(u8, 1) << @intCast(4 - col))) != 0)
                    pixel(screen_x + col, screen_y + row, 0x00ffffff);
            }
        }
        screen_x += 6;
    }
}

fn report(text: []const u8) void {
    serialText(text);
    for (text) |byte| drawByte(byte);
}

fn stop() noreturn {
    asm volatile ("cli");
    cpu.halt();
}

fn beginReport(title: []const u8) void {
    asm volatile ("cli");
    if (panicking) stop();
    panicking = true;
    serialInit();
    serialText("\r\n\r\n*** AetherOS kernel failure ***\r\n");
    if (framebuffer_ready) fill(0x00101828);
    report(title);
    report("\r\n");
}

fn panicMessage(message: []const u8, return_address: ?usize) noreturn {
    beginReport("KERNEL PANIC\r\n");
    report("Reason: ");
    report(message);
    report("\r\n");
    if (return_address) |address| {
        serialText("Return address: ");
        serialHex(address);
        serialText("\r\n");
        report("See serial log for return address.\r\n");
    }
    report("System halted.\r\n");
    stop();
}

const exception_names = [_][]const u8{
    "Divide error", "Debug", "NMI", "Breakpoint", "Overflow", "Bound range",
    "Invalid opcode", "Device unavailable", "Double fault", "Coprocessor segment overrun",
    "Invalid TSS", "Segment not present", "Stack segment fault", "General protection fault",
    "Page fault", "Reserved exception", "x87 floating point", "Alignment check",
    "Machine check", "SIMD floating point", "Virtualization", "Control protection",
    "Reserved exception", "Reserved exception", "Reserved exception", "Reserved exception",
    "Reserved exception", "Reserved exception", "Hypervisor injection", "VMM communication",
    "Security exception", "Reserved exception",
};

pub export fn aether_exception(
    vector: u64,
    error_code: u64,
    instruction_pointer: u64,
    code_segment: u64,
    flags: u64,
    cr2: u64,
) callconv(.c) noreturn {
    beginReport("CPU EXCEPTION\r\n");
    const name = if (vector < exception_names.len) exception_names[@intCast(vector)] else "Unknown exception";
    report("Type: ");
    report(name);
    report("\r\n");
    serialText("Vector: ");
    serialHex(vector);
    serialText("\r\nError code: ");
    serialHex(error_code);
    serialText("\r\nInstruction pointer: ");
    serialHex(instruction_pointer);
    serialText("\r\nCode segment: ");
    serialHex(code_segment);
    serialText("\r\nFlags: ");
    serialHex(flags);
    serialText("\r\nCR2: ");
    serialHex(cr2);
    serialText("\r\n");
    report("Details recorded to COM1 serial.\r\nSystem halted.\r\n");
    stop();
}
