//! RDRAND-backed hardware entropy source used for DNS transaction material and TLS.
pub fn fill(output: []u8) bool {
    var eax: u32 = undefined;
    var ebx: u32 = undefined;
    var ecx: u32 = undefined;
    var edx: u32 = undefined;
    asm volatile ("cpuid"
        : [_] "={eax}" (eax),
          [_] "={ebx}" (ebx),
          [_] "={ecx}" (ecx),
          [_] "={edx}" (edx),
        : [_] "{eax}" (@as(u32, 1)),
          [_] "{ecx}" (@as(u32, 0)),
    );
    if (eax < 1 or (ecx & (1 << 30)) == 0) return false;

    var offset: usize = 0;
    while (offset < output.len) {
        var value: u64 = undefined;
        var ready: u8 = 0;
        var attempt: u8 = 0;
        while (attempt < 10 and ready == 0) : (attempt += 1) {
            asm volatile ("rdrand %[value]\n\tsetc %[ready]"
                : [value] "=&r" (value),
                  [ready] "=qm" (ready),
            );
        }
        if (ready == 0) return false;
        const amount = @min(@as(usize, 8), output.len - offset);
        @memcpy(output[offset .. offset + amount], @as([*]const u8, @ptrCast(&value))[0..amount]);
        offset += amount;
    }
    return true;
}
