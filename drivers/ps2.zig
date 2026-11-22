const s = @import("../system/state.zig");
const io = @import("../arch/io.zig");

pub fn waitControllerInput() bool {
    var tries: u32 = 0;
    while (tries < 100_000) : (tries += 1) {
        if ((io.in8(0x64) & 2) == 0) return true;
    }
    return false;
}

pub fn waitControllerOutput() bool {
    var tries: u32 = 0;
    while (tries < 100_000) : (tries += 1) {
        if ((io.in8(0x64) & 1) != 0) return true;
    }
    return false;
}

pub fn sendMouse(value: u8) bool {
    if (!waitControllerInput()) return false;
    io.out8(0x64, 0xd4);
    if (!waitControllerInput()) return false;
    io.out8(0x60, value);
    if (!waitControllerOutput()) return false;
    return io.in8(0x60) == 0xfa;
}

pub fn setMouseRate(rate: u8) bool {
    return sendMouse(0xf3) and sendMouse(rate);
}

pub fn initKeyboard() bool {
    if (!waitControllerInput()) return false;
    io.out8(0x64, 0xad); // Disable keyboard while changing controller config.
    if (!waitControllerInput()) return false;
    io.out8(0x64, 0x20);
    if (!waitControllerOutput()) return false;
    var command = io.in8(0x60);
    command = (command | 0x03) & ~@as(u8, 0x30); // Enable IRQs and both PS/2 clocks.
    if (!waitControllerInput()) return false;
    io.out8(0x64, 0x60);
    if (!waitControllerInput()) return false;
    io.out8(0x60, command);
    if (!waitControllerInput()) return false;
    io.out8(0x64, 0xae);
    return true;
}

pub fn initMouse() bool {
    // Configure the auxiliary PS/2 port before interrupts are enabled.
    if (!waitControllerInput()) return false;
    io.out8(0x64, 0xa8);
    if (!waitControllerInput()) return false;
    io.out8(0x64, 0x20);
    if (!waitControllerOutput()) return false;
    var command = io.in8(0x60);
    command = (command | 0x03) & ~@as(u8, 0x30); // Enable IRQs after IDT setup.
    if (!waitControllerInput()) return false;
    io.out8(0x64, 0x60);
    if (!waitControllerInput()) return false;
    io.out8(0x60, command);
    if (!sendMouse(0xf6)) return false;
    // IntelliMouse wheel negotiation: the 200, 100, 80 sample-rate sequence
    // changes the packet ID to 3 on compatible devices.
    if (!setMouseRate(200) or !setMouseRate(100) or !setMouseRate(80)) return false;
    if (!sendMouse(0xf2) or !waitControllerOutput()) return false;
    const wheel_id = io.in8(0x60);
    if (wheel_id == 3) {
        s.mouse_packet_size = 4;
        // Some devices support two more buttons (ID 4).
        if (setMouseRate(200) and setMouseRate(200) and setMouseRate(80)) {
            if (sendMouse(0xf2) and waitControllerOutput()) {
                if (io.in8(0x60) == 4) s.mouse_packet_size = 4;
            }
        }
    }
    if (!sendMouse(0xf4)) return false;
    return true;
}

