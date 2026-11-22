const s = @import("../system/state.zig");

pub fn out8(port: u16, value: u8) void {
    asm volatile ("outb %al, %dx"
        :
        : [port] "{dx}" (port), [value] "{al}" (value)
    );
}

pub fn out16(port: u16, value: u16) void {
    asm volatile ("outw %ax, %dx"
        :
        : [port] "{dx}" (port), [value] "{ax}" (value)
    );
}

pub fn in8(port: u16) u8 {
    var value: u8 = undefined;
    asm volatile ("inb %dx, %al"
        : [value] "={al}" (value),
        : [port] "{dx}" (port)
    );
    return value;
}

pub fn in16(port: u16) u16 {
    var value: u16 = undefined;
    asm volatile ("inw %dx, %ax"
        : [value] "={ax}" (value),
        : [port] "{dx}" (port)
    );
    return value;
}

pub fn out32(port: u16, value: u32) void {
    asm volatile ("outl %eax, %dx"
        :
        : [port] "{dx}" (port), [value] "{eax}" (value)
    );
}

pub fn in32(port: u16) u32 {
    var value: u32 = undefined;
    asm volatile ("inl %dx, %eax"
        : [value] "={eax}" (value),
        : [port] "{dx}" (port)
    );
    return value;
}

