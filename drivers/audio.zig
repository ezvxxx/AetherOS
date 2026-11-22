//! Basic audio output: AC'97 PCM playback with a PC speaker fallback.
const io = @import("../arch/io.zig");
const s = @import("../system/state.zig");
const pci = @import("pci.zig");
const fat32 = @import("../fs/storage.zig");

const sample_rate = 48_000;
const frames = sample_rate; // One second, signed 16-bit stereo.
const BufferDescriptor = extern struct { address: u32, samples: u16, control: u16 = 0 };
var initialized = false;
var mixer_base: u16 = 0;
var busmaster_base: u16 = 0;
var hardware: [8]pci.Device = undefined;
var hardware_count: usize = 0;
var sample_buffer: [frames * 2]i16 align(4096) = @splat(0);
var bdl: [32]BufferDescriptor align(16) = @splat(.{ .address = 0, .samples = 0 });
var wav_buffer: [512 * 1024]u8 align(16) = @splat(0);
var mp3_buffer: [4 * 1024 * 1024]u8 align(16) = @splat(0);
var pcm_ready = false;
var volume_percent: u8 = 80;

extern fn aether_mp3_init(data: [*]const u8, length: usize) callconv(.c) void;
extern fn aether_mp3_next(sample_rate: *c_int, channels: *c_int) callconv(.c) c_int;
extern fn aether_mp3_samples() callconv(.c) [*]const i16;

fn pciRead(bus: u8, slot: u8, function: u8, offset: u8) u32 {
    const address = 0x8000_0000 | (@as(u32, bus) << 16) | (@as(u32, slot) << 11) |
        (@as(u32, function) << 8) | (@as(u32, offset) & 0xfc);
    io.out32(0x0cf8, address);
    return io.in32(0x0cfc);
}

fn pciWrite(bus: u8, slot: u8, function: u8, offset: u8, value: u32) void {
    const address = 0x8000_0000 | (@as(u32, bus) << 16) | (@as(u32, slot) << 11) |
        (@as(u32, function) << 8) | (@as(u32, offset) & 0xfc);
    io.out32(0x0cf8, address);
    io.out32(0x0cfc, value);
}

fn writeMixer(offset: u16, value: u16) void {
    io.out16(mixer_base + offset, value);
}
fn readMixer(offset: u16) u16 {
    return io.in16(mixer_base + offset);
}
fn bmWrite8(offset: u16, value: u8) void {
    io.out8(busmaster_base + offset, value);
}
fn bmWrite16(offset: u16, value: u16) void {
    io.out16(busmaster_base + offset, value);
}
fn bmWrite32(offset: u16, value: u32) void {
    io.out32(busmaster_base + offset, value);
}
fn bmRead8(offset: u16) u8 {
    return io.in8(busmaster_base + offset);
}

fn read16(bytes: []const u8, at: usize) u16 {
    return @as(u16, bytes[at]) | (@as(u16, bytes[at + 1]) << 8);
}
fn read32(bytes: []const u8, at: usize) u32 {
    return @as(u32, bytes[at]) | (@as(u32, bytes[at + 1]) << 8) |
        (@as(u32, bytes[at + 2]) << 16) | (@as(u32, bytes[at + 3]) << 24);
}
fn signature(bytes: []const u8, at: usize, value: []const u8) bool {
    if (at > bytes.len or value.len > bytes.len - at) return false;
    for (value, 0..) |byte, i| if (bytes[at + i] != byte) return false;
    return true;
}

fn setCodecVolume(percent: u8) void {
    volume_percent = @min(percent, 100);
    if (!pcm_ready) return;
    const attenuation: u16 = @intCast(31 - (@as(u16, volume_percent) * 31 / 100));
    const level = (attenuation << 8) | attenuation;
    writeMixer(0x02, level);
    writeMixer(0x18, level);
}

pub fn setVolume(percent: u8) void {
    volume_percent = @min(percent, 100);
    setCodecVolume(volume_percent);
}

pub fn volume() u8 {
    return volume_percent;
}

fn initializeAc97(device: pci.Device) bool {
    const command_status = pciRead(device.bus, device.slot, device.function, 0x04);
    pciWrite(device.bus, device.slot, device.function, 0x04, (command_status & 0xffff) | 0x0005);
    const nam = pciRead(device.bus, device.slot, device.function, 0x10);
    const nabm = pciRead(device.bus, device.slot, device.function, 0x14);
    if ((nam & 1) == 0 or (nabm & 1) == 0) return false;
    mixer_base = @truncate(nam & 0xfffc);
    busmaster_base = @truncate(nabm & 0xfffc);
    if (mixer_base == 0 or busmaster_base == 0) return false;
    // Reset codec and set audible master/PCM levels. Bounded polls prevent hangs.
    writeMixer(0x00, 0);
    var wait: usize = 0;
    while (wait < 100_000 and readMixer(0x00) != 0) : (wait += 1) {}
    writeMixer(0x02, 0);
    writeMixer(0x18, 0);
    writeMixer(0x2a, readMixer(0x2a) | 1); // Enable variable-rate audio when supported.
    writeMixer(0x2c, sample_rate);
    pcm_ready = true;
    setCodecVolume(volume_percent);
    return true;
}

pub fn init() bool {
    initialized = true;
    hardware_count = 0;
    pcm_ready = false;
    for (pci.devices()) |device| {
        if (device.class != 0x04 or device.subclass != 0x01) continue;
        if (hardware_count < hardware.len) {
            hardware[hardware_count] = device;
            hardware_count += 1;
        }
        if (!pcm_ready and device.programming_interface == 0 and initializeAc97(device)) pcm_ready = true;
    }
    for (pci.devices()) |device| {
        if (device.class != 0x04 or device.subclass != 0x03) continue;
        if (hardware_count < hardware.len) {
            hardware[hardware_count] = device;
            hardware_count += 1;
        }
    }
    return initialized;
}

pub fn available() bool {
    return initialized;
}
pub fn controllers() []const pci.Device {
    return hardware[0..hardware_count];
}
pub fn controllerName(device: pci.Device) []const u8 {
    if (device.subclass == 0x03) return "HDA (detected)";
    if (device.subclass == 0x01) return if (pcm_ready) "AC'97 PCM" else "AC'97 (detected)";
    return "Audio";
}
pub fn description() []const u8 {
    if (pcm_ready) return "AC'97 PCM playback ready";
    if (hardware_count != 0 and hardware[0].subclass == 0x03) return "HDA found; PCM playback unavailable";
    if (hardware_count != 0) return "AC'97 found; PCM playback unavailable";
    return if (initialized) "PC speaker output available" else "No audio output detected";
}

pub fn stop() void {
    if (pcm_ready) bmWrite8(0x1b, 0);
    const gate = io.in8(0x61) & ~@as(u8, 3);
    io.out8(0x61, gate);
}

fn speakerTone(frequency_hz: u32, duration_ticks: u64) void {
    if (frequency_hz < 20 or frequency_hz > 20_000) return;
    const divisor: u16 = @truncate(1_193_182 / frequency_hz);
    io.out8(0x43, 0xb6);
    io.out8(0x42, @truncate(divisor));
    io.out8(0x42, @truncate(divisor >> 8));
    io.out8(0x61, io.in8(0x61) | 3);
    const deadline = s.uptime() + duration_ticks;
    while (s.uptime() < deadline) asm volatile ("hlt");
    stop();
}

fn playPcmFrames(frame_count: usize) bool {
    if (!pcm_ready or frame_count == 0 or frame_count > frames) return false;
    const buffer_address = @intFromPtr(&sample_buffer);
    const bdl_address = @intFromPtr(&bdl);
    if (buffer_address > 0xffff_ffff or bdl_address > 0xffff_ffff) return false;
    const first_frames = @min(frame_count, frames / 2);
    const second_frames = frame_count - first_frames;
    bdl[0] = .{ .address = @truncate(buffer_address), .samples = @intCast(first_frames * 2), .control = if (second_frames == 0) 1 << 15 else 0 };
    if (second_frames != 0) bdl[1] = .{
        .address = @truncate(buffer_address + first_frames * 2 * @sizeOf(i16)),
        .samples = @intCast(second_frames * 2),
        .control = 1 << 15,
    };
    bmWrite8(0x1b, 0x02); // Reset PCM-out channel.
    var wait: usize = 0;
    while (wait < 100_000 and (bmRead8(0x1b) & 0x02) != 0) : (wait += 1) {}
    bmWrite8(0x16, 0x1c); // Clear completion/error status bits.
    bmWrite32(0x10, @truncate(bdl_address));
    bmWrite8(0x15, if (second_frames == 0) 0 else 1);
    bmWrite8(0x1b, 0x11); // Run and interrupt on completion.
    const deadline = s.uptime() + @max(200, frame_count / 240 + 100);
    wait = 0;
    while (wait < 100_000_000 and s.uptime() < deadline and (bmRead8(0x16) & 0x0c) == 0) : (wait += 1) asm volatile ("pause");
    const status = bmRead8(0x16);
    bmWrite8(0x1b, 0);
    // DCH (bit 0) and CELV (bit 1) normally become set when DMA reaches the
    // final buffer. They are completion state, not playback errors. BCIS or
    // LVBCI (bits 2/3) confirms the buffer played; FIFOE (bit 4) is the real
    // transfer failure. Requiring bits 0/1 clear made audible playback report
    // a false failure after the AC'97 engine halted normally.
    return (status & 0x0c) != 0 and (status & 0x10) == 0;
}

fn outputWavPcm(data: []const u8, channels: u16, input_rate: u32) bool {
    const bytes_per_frame: usize = @as(usize, channels) * 2;
    const source_frames = data.len / bytes_per_frame;
    if (source_frames == 0 or input_rate == 0) return false;
    const output_frames = source_frames * sample_rate / input_rate;
    if (output_frames == 0) return false;
    var output_offset: usize = 0;
    while (output_offset < output_frames) {
        const count = @min(frames, output_frames - output_offset);
        for (0..count) |i| {
            const source_frame = @min((output_offset + i) * input_rate / sample_rate, source_frames - 1);
            const source_offset = source_frame * bytes_per_frame;
            const left: i16 = @bitCast(read16(data, source_offset));
            const right: i16 = if (channels == 2) @bitCast(read16(data, source_offset + 2)) else left;
            sample_buffer[i * 2] = left;
            sample_buffer[i * 2 + 1] = right;
        }
        if (!playPcmFrames(count)) return false;
        output_offset += count;
    }
    return true;
}

/// Play PCM WAV from the mounted filesystem directory. Supports 16-bit mono/stereo RIFF WAVE.
pub fn playWav(directory: u32, name: []const u8) bool {
    if (!pcm_ready) return false;
    const length = fat32.readFileAt(directory, name, &wav_buffer) orelse return false;
    return playWavBytes(wav_buffer[0..length]);
}

pub fn playWavBytes(bytes: []const u8) bool {
    if (!pcm_ready) return false;
    if (bytes.len < 12 or !signature(bytes, 0, "RIFF") or !signature(bytes, 8, "WAVE")) return false;
    var offset: usize = 12;
    var format_ok = false;
    var channels: u16 = 0;
    var input_rate: u32 = 0;
    var pcm_data: []const u8 = &.{};
    while (offset + 8 <= bytes.len) {
        const chunk_size: usize = read32(bytes, offset + 4);
        const start = offset + 8;
        if (chunk_size > bytes.len - start) return false;
        if (signature(bytes, offset, "fmt ")) {
            if (chunk_size < 16 or read16(bytes, start) != 1) return false;
            channels = read16(bytes, start + 2);
            input_rate = read32(bytes, start + 4);
            const bits = read16(bytes, start + 14);
            format_ok = bits == 16 and (channels == 1 or channels == 2) and input_rate >= 8_000 and input_rate <= 96_000;
        } else if (signature(bytes, offset, "data")) {
            pcm_data = bytes[start .. start + chunk_size];
        }
        offset = start + chunk_size + (chunk_size & 1);
    }
    return format_ok and pcm_data.len != 0 and outputWavPcm(pcm_data, channels, input_rate);
}

/// Decode and play an MPEG Layer III file using the bundled minimp3 decoder.
pub fn playMp3(directory: u32, name: []const u8) bool {
    if (!pcm_ready) return false;
    const length = fat32.readFileAt(directory, name, &mp3_buffer) orelse return false;
    return playMp3Bytes(mp3_buffer[0..length]);
}

pub fn playMp3Bytes(bytes: []const u8) bool {
    if (!pcm_ready or bytes.len < 4 or bytes.len > mp3_buffer.len) return false;
    aether_mp3_init(bytes.ptr, bytes.len);
    var decoded_any = false;
    var rate: c_int = 0;
    var channels: c_int = 0;
    while (true) {
        const sample_count_raw = aether_mp3_next(&rate, &channels);
        if (sample_count_raw <= 0) break;
        if (rate < 8_000 or rate > 96_000 or (channels != 1 and channels != 2)) return false;
        const sample_count: usize = @intCast(sample_count_raw);
        const source = aether_mp3_samples();
        const output_count = sample_count * sample_rate / @as(usize, @intCast(rate));
        if (output_count == 0 or output_count > frames) return false;
        for (0..output_count) |i| {
            const src_frame = @min(i * @as(usize, @intCast(rate)) / sample_rate, sample_count - 1);
            const left = source[src_frame * @as(usize, @intCast(channels))];
            const right = if (channels == 2) source[src_frame * 2 + 1] else left;
            sample_buffer[i * 2] = left;
            sample_buffer[i * 2 + 1] = right;
        }
        if (!playPcmFrames(output_count)) return false;
        decoded_any = true;
    }
    return decoded_any;
}

/// Play a one-second 440 Hz tone through AC'97 or the PC speaker fallback.
pub fn playTestTone() bool {
    if (!initialized) return false;
    if (!pcm_ready) {
        speakerTone(440, 30);
        return true;
    }
    const phase_step: usize = 440 * 2;
    for (0..frames) |frame| {
        const value: i16 = if ((frame * phase_step / sample_rate) & 1 == 0) 7000 else -7000;
        sample_buffer[frame * 2] = value;
        sample_buffer[frame * 2 + 1] = value;
    }
    return playPcmFrames(frames);
}

pub fn tone(frequency_hz: u32, duration_ticks: u64) void {
    if (!initialized) return;
    speakerTone(frequency_hz, duration_ticks);
}
