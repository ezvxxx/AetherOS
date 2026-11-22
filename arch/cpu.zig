const s = @import("../system/state.zig");

pub fn enableSse() void {
    // x86-64 compilers may use SSE for ordinary struct/array copies. Firmware
    // boot paths need not set CR4.OSFXSR, so initialize the architectural
    // state before any drawing or input code can execute those instructions.
    var scratch: u64 = 0;
    asm volatile (
        \\movq %cr0, %[scratch]
        \\andq $-5, %[scratch]
        \\orq $0x22, %[scratch]
        \\movq %[scratch], %cr0
        \\movq %cr4, %[scratch]
        \\orq $0x600, %[scratch]
        \\movq %[scratch], %cr4
        : [scratch] "=&r" (scratch),
        :
    );
}

pub fn halt() noreturn {
    while (true) asm volatile ("hlt");
}

