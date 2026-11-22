//! Small round-robin scheduler for isolated ring-3 processes.
//! The first user ABI provides write, yield, and exit system calls.
const gdt = @import("../arch/gdt.zig");
const pmm = @import("../memory/pmm.zig");
const vm = @import("../memory/vm.zig");
const system = @import("../system/state.zig");

const page_size: u64 = pmm.page_size;
const user_code: u64 = 0x0000008000000000;
const user_stack: u64 = user_code + 0x2000;
const user_stack_top: u64 = user_stack + page_size;
const kernel_stack_size = 8192;
const process_capacity = 4;
const batch_capacity = 2;

const ProcessState = enum { free, ready, running, exited };

const SyscallFrame = extern struct {
    r15: u64,
    r14: u64,
    r13: u64,
    r12: u64,
    r11: u64,
    r10: u64,
    r9: u64,
    r8: u64,
    rbp: u64,
    rdi: u64,
    rsi: u64,
    rdx: u64,
    rcx: u64,
    rbx: u64,
    rax: u64,
    rip: u64,
    cs: u64,
    rflags: u64,
    rsp: u64,
    ss: u64,
};

const Process = struct {
    pid: u32 = 0,
    state: ProcessState = .free,
    root: u64 = 0,
    code_page: u64 = 0,
    stack_page: u64 = 0,
    code_mapped: bool = false,
    stack_mapped: bool = false,
    kernel_stack: [kernel_stack_size]u8 align(16) = @splat(0),
    frame: ?*SyscallFrame = null,
    name: [16]u8 = @splat(0),
    name_len: usize = 0,
    syscall_count: u32 = 0,
    yield_count: u32 = 0,
    exit_code: u64 = 0,
};

var processes: [process_capacity]Process = @splat(.{});
var batch: [batch_capacity]usize = @splat(0);
var batch_count: usize = 0;
var current_slot: usize = 0;
var kernel_root: u64 = 0;
var next_pid: u32 = 1;
var output: [512]u8 = @splat(0);
var output_len: usize = 0;
var process_list_buffer: [512]u8 = @splat(0);
var process_list_len: usize = 0;
pub var last_fault_vector: u64 = 0;
pub var last_fault_address: u64 = 0;
pub var user_fault_count: u64 = 0;

pub const Syscall = struct {
    pub const write: u64 = 1;
    pub const yield: u64 = 2;
    pub const exit: u64 = 3;
    pub const get_pid: u64 = 4;
    pub const uptime_ticks: u64 = 5;
};

/// The syscall return stub restores this kernel continuation when a batch exits.
pub export var aether_user_kernel_rsp: u64 = 0;
extern fn aether_enter_user(rip: u64, rsp: u64) callconv(.c) void;

const user_code_template = [_]u8{
    0xb8, 2, 0, 0, 0, // mov eax, SYS_YIELD
    0xcd, 0x80, // int 0x80
    0xb8, 1, 0, 0, 0, // mov eax, SYS_WRITE
    0x48, 0x8d, 0x3d, 0, 0, 0, 0, // lea rdi, [rip + message]
    0xbe, 0, 0, 0, 0, // mov esi, message length
    0xcd, 0x80, // int 0x80
    0xb8, 5, 0, 0, 0, // mov eax, SYS_UPTIME
    0xcd, 0x80,
    0xb8, 4, 0, 0, 0, // mov eax, SYS_GETPID
    0xcd, 0x80,
    0x48, 0x89, 0xc7, // mov rdi, rax (exit status = PID)
    0xb8, 3, 0, 0, 0, // mov eax, SYS_EXIT
    0xcd, 0x80, // int 0x80
    0xeb, 0xfe, // unreachable safety loop
};
const user_message_offset: usize = 64;

fn stackTop(process: *Process) u64 {
    const raw = @intFromPtr(&process.kernel_stack) + process.kernel_stack.len;
    return raw & ~@as(u64, 15);
}

fn setName(process: *Process, name: []const u8) void {
    @memset(&process.name, 0);
    process.name_len = @min(name.len, process.name.len);
    @memcpy(process.name[0..process.name_len], name[0..process.name_len]);
}

fn cleanupProcess(process: *Process) void {
    if (process.root != 0) vm.destroyAddressSpace(process.root);
    if (process.code_page != 0 and !process.code_mapped) pmm.freePage(process.code_page);
    if (process.stack_page != 0 and !process.stack_mapped) pmm.freePage(process.stack_page);
    process.root = 0;
    process.code_page = 0;
    process.stack_page = 0;
    process.code_mapped = false;
    process.stack_mapped = false;
    process.frame = null;
}

fn makeProcess(process: *Process, pid: u32, name: []const u8, message: []const u8) bool {
    process.* = .{};
    process.pid = pid;
    process.state = .ready;
    setName(process, name);

    process.root = vm.createAddressSpace() orelse return false;
    process.code_page = pmm.allocatePage() orelse {
        cleanupProcess(process);
        return false;
    };
    process.stack_page = pmm.allocatePage() orelse {
        cleanupProcess(process);
        return false;
    };

    if (!vm.mapUserPage(process.root, user_code, process.code_page)) {
        cleanupProcess(process);
        return false;
    }
    process.code_mapped = true;
    if (!vm.mapUserPage(process.root, user_stack, process.stack_page)) {
        cleanupProcess(process);
        return false;
    }
    process.stack_mapped = true;

    const code: [*]u8 = @ptrFromInt(vm.physicalToVirtual(process.code_page));
    const stack: [*]u8 = @ptrFromInt(vm.physicalToVirtual(process.stack_page));
    @memset(code[0..page_size], 0);
    @memset(stack[0..page_size], 0);
    var program = user_code_template;
    const displacement: u32 = @intCast(user_message_offset - 19); // RIP after the LEA.
    program[15] = @truncate(displacement);
    program[16] = @truncate(displacement >> 8);
    program[17] = @truncate(displacement >> 16);
    program[18] = @truncate(displacement >> 24);
    const message_length: u32 = @intCast(@min(message.len, 256));
    program[20] = @truncate(message_length);
    program[21] = @truncate(message_length >> 8);
    program[22] = @truncate(message_length >> 16);
    program[23] = @truncate(message_length >> 24);
    @memcpy(code[0..program.len], &program);
    @memcpy(code[user_message_offset .. user_message_offset + message_length], message[0..message_length]);

    const frame_address = stackTop(process) - @sizeOf(SyscallFrame);
    const frame: *SyscallFrame = @ptrFromInt(frame_address);
    frame.* = .{
        .r15 = 0,
        .r14 = 0,
        .r13 = 0,
        .r12 = 0,
        .r11 = 0,
        .r10 = 0,
        .r9 = 0,
        .r8 = 0,
        .rbp = 0,
        .rdi = 0,
        .rsi = 0,
        .rdx = 0,
        .rcx = 0,
        .rbx = 0,
        .rax = 0,
        .rip = user_code,
        .cs = gdt.user_code_selector,
        .rflags = 0x202,
        .rsp = user_stack_top - 16,
        .ss = gdt.user_data_selector,
    };
    process.frame = frame;
    return true;
}

fn appendOutput(bytes: []const u8) usize {
    const amount = @min(bytes.len, output.len - output_len);
    if (amount != 0) {
        @memcpy(output[output_len .. output_len + amount], bytes[0..amount]);
        output_len += amount;
    }
    return amount;
}

fn validUserRead(pointer: u64, length: u64) bool {
    if (length > page_size) return false;
    const regions = [_]u64{ user_code, user_stack };
    for (regions) |base| {
        if (pointer >= base and pointer <= base + page_size and length <= base + page_size - pointer) return true;
    }
    return false;
}

fn nextRunnable(after_slot: usize) ?usize {
    var step: usize = 1;
    while (step <= batch_count) : (step += 1) {
        const start_position = for (batch[0..batch_count], 0..) |slot, position| {
            if (slot == after_slot) break position;
        } else 0;
        const position = (start_position + step) % batch_count;
        const candidate = batch[position];
        if (processes[candidate].state == .ready or processes[candidate].state == .running) return candidate;
    }
    return null;
}

fn switchTo(slot: usize) ?*SyscallFrame {
    const process = &processes[slot];
    const frame = process.frame orelse return null;
    current_slot = slot;
    process.state = .running;
    vm.switchAddressSpace(process.root);
    gdt.setKernelStack(stackTop(process));
    return frame;
}

fn dispatch(frame: *SyscallFrame) usize {
    const process = &processes[current_slot];
    process.frame = frame;
    process.syscall_count +%= 1;
    switch (frame.rax) {
        Syscall.write => { // write(user_ptr, length), limited to mapped user pages.
            const start = frame.rdi;
            const length = frame.rsi;
            if (!validUserRead(start, length)) {
                frame.rax = @as(u64, 0xffffffffffffffff);
            } else {
                const source: [*]const u8 = @ptrFromInt(start);
                frame.rax = appendOutput(source[0..@intCast(length)]);
            }
            return @intFromPtr(frame);
        },
        Syscall.yield => {
            process.yield_count +%= 1;
            process.state = .ready;
            if (nextRunnable(current_slot)) |next| {
                if (switchTo(next)) |next_frame| return @intFromPtr(next_frame);
            }
            process.state = .running;
            return @intFromPtr(frame);
        },
        Syscall.exit => {
            process.exit_code = frame.rdi;
            process.state = .exited;
            if (nextRunnable(current_slot)) |next| {
                if (switchTo(next)) |next_frame| return @intFromPtr(next_frame);
            }
            vm.switchAddressSpace(kernel_root);
            return 0; // Assembly restores the kernel continuation and returns to runDemo.
        },
        Syscall.get_pid => {
            frame.rax = process.pid;
            return @intFromPtr(frame);
        },
        Syscall.uptime_ticks => {
            frame.rax = system.uptime();
            return @intFromPtr(frame);
        },
        else => {
            frame.rax = 0xffffffffffffffff;
            return @intFromPtr(frame);
        },
    }
}

pub export fn aether_syscall_dispatch(frame: *SyscallFrame) callconv(.c) usize {
    return dispatch(frame);
}

pub export fn aether_user_exception(
    vector: u64,
    error_code: u64,
    instruction_pointer: u64,
    code_segment: u64,
    flags: u64,
    cr2: u64,
) callconv(.c) usize {
    last_fault_vector = vector;
    _ = error_code;
    _ = instruction_pointer;
    _ = code_segment;
    _ = flags;
    last_fault_address = cr2;
    user_fault_count +%= 1;
    processes[current_slot].state = .exited;
    _ = appendOutput("user process faulted and was stopped\n");
    if (nextRunnable(current_slot)) |next| {
        if (switchTo(next)) |next_frame| return @intFromPtr(next_frame);
    }
    vm.switchAddressSpace(kernel_root);
    return 0;
}

fn freeSlot() ?usize {
    for (processes, 0..) |process, index| if (process.state == .free or process.state == .exited) return index;
    return null;
}

/// Start a small two-process ring-3 demonstration and return its captured output.
pub fn runDemo() ?[]const u8 {
    if (!gdt.isReady() or !batchCapacityAvailable()) return null;
    output_len = 0;
    kernel_root = vm.currentRoot();
    batch_count = 0;
    const message_a = "user process A: isolated ring 3\n";
    const message_b = "user process B: isolated ring 3\n";
    const messages = [_][]const u8{ message_a, message_b };
    const names = [_][]const u8{ "demo-a", "demo-b" };

    for (0..batch_capacity) |index| {
        const slot = freeSlot() orelse break;
        const pid = next_pid;
        next_pid +%= 1;
        if (!makeProcess(&processes[slot], pid, names[index], messages[index])) {
            for (batch[0..batch_count]) |created| cleanupProcess(&processes[created]);
            batch_count = 0;
            return null;
        }
        batch[index] = slot;
        batch_count += 1;
    }
    if (batch_count != batch_capacity) {
        for (batch[0..batch_count]) |created| cleanupProcess(&processes[created]);
        batch_count = 0;
        return null;
    }

    const first = batch[0];
    const initial_frame = processes[first].frame orelse return null;
    current_slot = first;
    processes[first].state = .running;
    vm.switchAddressSpace(processes[first].root);
    gdt.setKernelStack(stackTop(&processes[first]));
    aether_enter_user(initial_frame.rip, initial_frame.rsp);

    vm.switchAddressSpace(kernel_root);
    for (batch[0..batch_count]) |slot| cleanupProcess(&processes[slot]);
    batch_count = 0;
    if (output_len == 0) return "User processes exited without output";
    return output[0..output_len];
}

fn batchCapacityAvailable() bool {
    var free_count: usize = 0;
    for (processes) |process| if (process.state == .free or process.state == .exited) { free_count += 1; };
    return free_count >= batch_capacity;
}

fn appendListText(text: []const u8) void {
    const amount = @min(text.len, process_list_buffer.len - process_list_len);
    @memcpy(process_list_buffer[process_list_len .. process_list_len + amount], text[0..amount]);
    process_list_len += amount;
}

fn appendPid(pid: u32) void {
    var digits: [10]u8 = undefined;
    var count: usize = 0;
    var value = pid;
    while (value != 0) : (value /= 10) {
        digits[count] = @intCast(value % 10 + '0');
        count += 1;
    }
    if (count == 0) {
        appendListText("0");
    } else while (count != 0) {
        count -= 1;
        appendListText(digits[count .. count + 1]);
    }
}

fn appendUnsigned(value_in: u64) void {
    var digits: [20]u8 = undefined;
    var count: usize = 0;
    var value = value_in;
    while (value != 0) : (value /= 10) {
        digits[count] = @intCast(value % 10 + '0');
        count += 1;
    }
    if (count == 0) {
        appendListText("0");
    } else while (count != 0) {
        count -= 1;
        appendListText(digits[count .. count + 1]);
    }
}

pub fn list() []const u8 {
    @memset(&process_list_buffer, 0);
    process_list_len = 0;
    var found = false;
    for (processes) |process| {
        if (process.state == .free) continue;
        found = true;
        appendListText("PID ");
        appendPid(process.pid);
        appendListText("  ");
        appendListText(process.name[0..process.name_len]);
        appendListText(switch (process.state) {
            .free => " free\n",
            .ready => " ready\n",
            .running => " running\n",
            .exited => " exited\n",
        });
        appendListText("  syscalls=");
        appendUnsigned(process.syscall_count);
        appendListText(" yields=");
        appendUnsigned(process.yield_count);
        appendListText(" exit=");
        appendUnsigned(process.exit_code);
        appendListText("\n");
    }
    if (user_fault_count != 0) {
        appendListText("Last user fault vector=");
        appendUnsigned(last_fault_vector);
        appendListText(" address=0x");
        var digits: [16]u8 = undefined;
        var count: usize = 0;
        var value = last_fault_address;
        const hex = "0123456789abcdef";
        while (value != 0) : (value >>= 4) {
            digits[count] = hex[@intCast(value & 0xf)];
            count += 1;
        }
        if (count == 0) {
            appendListText("0");
        } else while (count != 0) {
            count -= 1;
            appendListText(digits[count .. count + 1]);
        }
        appendListText("\n");
    }
    return if (found) process_list_buffer[0..process_list_len] else "No user processes have run";
}
