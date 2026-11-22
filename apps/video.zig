//! Bounded video path for MJPEG/H.264 MP4 and VP8/H.264 Matroska.
const std = @import("std");
const s = @import("../system/state.zig");
const fat32 = @import("../fs/storage.zig");
const heap = @import("../memory/heap.zig");
const image = @import("../graphics/image.zig");
const media = @import("../graphics/media.zig");
const vp8 = @import("vp8");

const max_file = 8 * 1024 * 1024;
const max_frames = 4096;
const max_h264_nal = max_file;
const FrameRef = struct { offset: usize, length: usize, time_ms: u64 };

var file_buffer: [max_file]u8 align(16) = @splat(0);
var h264_input: [max_h264_nal + 64 * 1024]u8 align(16) = @splat(0);
var h264_picture: ?media.Picture = null;
var h264_storage: ?*anyopaque = null;
var h264_active = false;
var h264_config_pending = true;
var h264_input_used: usize = 0;
var h264_alloc_base: ?[*]u8 = null;
var h264_alloc_cursor: usize = 0;
const h264_alloc_capacity = 96 * 1024 * 1024;
var h264_length_size: usize = 4;
var h264_config: [4096]u8 = @splat(0);
var h264_config_len: usize = 0;
const Codec = enum { mjpeg, vp8, h264 };
var selected_codec: Codec = .mjpeg;
var active_codec: Codec = .mjpeg;
var frame_refs: [max_frames]FrameRef = @splat(.{ .offset = 0, .length = 0, .time_ms = 0 });
var frame_count: usize = 0;
var next_frame: usize = 0;
var next_due_ms: u64 = 0;
var playback_start_ms: u64 = 0;
var active = false;
var owner_window: usize = 11;
var picture: ?media.Picture = null;
pub var status: []const u8 = "Open an MP4 or MKV video";

extern fn h264bsdAlloc() ?*anyopaque;
extern fn h264bsdInit(storage: *anyopaque, no_reordering: u32) u32;
extern fn h264bsdDecode(storage: *anyopaque, bytes: [*]u8, length: u32, output: *?[*]u8, width: *u32, height: *u32) u32;
extern fn h264bsdShutdown(storage: *anyopaque) void;
extern fn h264bsdFree(storage: *anyopaque) void;

/// C decoder allocations live in the kernel's bounded heap and are rewound
/// together when playback stops. Frees during a decode are intentionally deferred.
export fn aether_h264_malloc(size: usize) ?*anyopaque {
    if (h264_alloc_base == null) h264_alloc_base = heap.allocate(h264_alloc_capacity, 4096);
    const base = h264_alloc_base orelse return null;
    const aligned = (h264_alloc_cursor + 15) & ~@as(usize, 15);
    if (aligned > h264_alloc_capacity or size > h264_alloc_capacity - aligned) return null;
    h264_alloc_cursor = aligned + size;
    return @ptrCast(base + aligned);
}
export fn aether_h264_free(_: ?*anyopaque) void {}

fn be16(b: []const u8, p: usize) u16 {
    return (@as(u16, b[p]) << 8) | b[p + 1];
}
fn be32(b: []const u8, p: usize) u32 {
    return (@as(u32, b[p]) << 24) | (@as(u32, b[p + 1]) << 16) | (@as(u32, b[p + 2]) << 8) | b[p + 3];
}
fn be64(b: []const u8, p: usize) u64 {
    return (@as(u64, be32(b, p)) << 32) | be32(b, p + 4);
}
fn le16(b: []const u8, p: usize) u16 {
    return @as(u16, b[p]) | (@as(u16, b[p + 1]) << 8);
}
fn le32(b: []const u8, p: usize) u32 {
    return @as(u32, b[p]) | (@as(u32, b[p + 1]) << 8) | (@as(u32, b[p + 2]) << 16) | (@as(u32, b[p + 3]) << 24);
}
fn has(b: []const u8, p: usize, text: []const u8) bool {
    return p <= b.len and text.len <= b.len - p and std.mem.eql(u8, b[p .. p + text.len], text);
}
fn appendFrame(offset: usize, length: usize, time_ms: u64) bool {
    if (length == 0 or offset > file_buffer.len or length > file_buffer.len - offset or frame_count == max_frames) return false;
    frame_refs[frame_count] = .{ .offset = offset, .length = length, .time_ms = time_ms };
    frame_count += 1;
    return true;
}

fn setAvcConfig(data: []const u8, start: usize, end: usize) bool {
    if (start >= end or end > data.len or end - start < 7 or data[start] != 1 or end - start > h264_config.len) return false;
    @memcpy(h264_config[0 .. end - start], data[start..end]);
    h264_config_len = end - start;
    h264_length_size = @as(usize, data[start + 4] & 3) + 1;
    return h264_length_size == 1 or h264_length_size == 2 or h264_length_size == 4;
}

const Box = struct { payload: usize, end: usize, kind: []const u8 };
fn childBox(data: []const u8, begin: usize, end: usize, kind: []const u8) ?Box {
    var at = begin;
    while (at + 8 <= end and at + 8 <= data.len) {
        var size: u64 = be32(data, at);
        var header: usize = 8;
        if (size == 1) {
            if (at + 16 > end or at + 16 > data.len) return null;
            size = be64(data, at + 8);
            header = 16;
        } else if (size == 0) size = end - at;
        if (size < header or size > end - at or size > data.len - at) return null;
        const box_end = at + @as(usize, @intCast(size));
        if (has(data, at + 4, kind)) return .{ .payload = at + header, .end = box_end, .kind = kind };
        at = box_end;
    }
    return null;
}

fn parseMp4(data: []const u8) bool {
    const moov = childBox(data, 0, data.len, "moov") orelse return false;
    var trak_at = moov.payload;
    while (trak_at + 8 <= moov.end) {
        const trak = childBox(data, trak_at, moov.end, "trak") orelse break;
        trak_at = trak.end;
        const mdia = childBox(data, trak.payload, trak.end, "mdia") orelse continue;
        const hdlr = childBox(data, mdia.payload, mdia.end, "hdlr") orelse continue;
        if (hdlr.payload + 12 > hdlr.end or !has(data, hdlr.payload + 8, "vide")) continue;
        const minf = childBox(data, mdia.payload, mdia.end, "minf") orelse continue;
        const stbl = childBox(data, minf.payload, minf.end, "stbl") orelse continue;
        const stsd = childBox(data, stbl.payload, stbl.end, "stsd") orelse continue;
        if (stsd.payload + 16 > stsd.end) continue;
        const entry = stsd.payload + 8;
        const entry_size: usize = be32(data, entry);
        if (entry_size < 86 or entry_size > stsd.end - entry) continue;
        const is_mjpeg = has(data, entry + 4, "jpeg") or has(data, entry + 4, "mjpg") or has(data, entry + 4, "MJPG");
        const is_h264 = has(data, entry + 4, "avc1") or has(data, entry + 4, "avc3");
        if (!is_mjpeg and !is_h264) {
            status = "MP4 video codec is unsupported";
            continue;
        }
        if (is_h264) {
            const child_at = entry + 86;
            const entry_end = entry + entry_size;
            var found_config = false;
            while (child_at + 8 <= entry_end) {
                const child = childBox(data, child_at, entry_end, "avcC") orelse break;
                if (setAvcConfig(data, child.payload, child.end)) found_config = true;
                break;
            }
            if (!found_config) {
                status = "H.264 MP4 is missing its AVC decoder configuration";
                continue;
            }
            selected_codec = .h264;
        } else selected_codec = .mjpeg;
        const stsz = childBox(data, stbl.payload, stbl.end, "stsz") orelse continue;
        const stsc = childBox(data, stbl.payload, stbl.end, "stsc") orelse continue;
        const stco = childBox(data, stbl.payload, stbl.end, "stco") orelse childBox(data, stbl.payload, stbl.end, "co64") orelse continue;
        const stts = childBox(data, stbl.payload, stbl.end, "stts") orelse continue;
        const mdhd = childBox(data, mdia.payload, mdia.end, "mdhd") orelse continue;
        if (stsz.payload + 12 > stsz.end or stsc.payload + 8 > stsc.end or stco.payload + 8 > stco.end or stts.payload + 8 > stts.end) continue;
        const default_size = be32(data, stsz.payload + 4);
        const samples: usize = @min(be32(data, stsz.payload + 8), max_frames);
        const chunk_entries: usize = be32(data, stsc.payload + 4);
        const chunk_count: usize = be32(data, stco.payload + 4);
        const timing_entries: usize = be32(data, stts.payload + 4);
        if (samples == 0 or chunk_count == 0 or chunk_entries == 0 or timing_entries == 0) continue;
        var sizes: [max_frames]u32 = @splat(default_size);
        if (default_size == 0) {
            if (stsz.payload + 12 + samples * 4 > stsz.end) continue;
            for (0..samples) |i| sizes[i] = be32(data, stsz.payload + 12 + i * 4);
        }
        var chunk_offsets: [max_frames]u64 = @splat(0);
        const chunk_width: usize = if (has(data, stco.payload - 4, "co64")) 8 else 4;
        const actual_chunks = @min(chunk_count, max_frames);
        if (stco.payload + 8 + actual_chunks * chunk_width > stco.end) continue;
        for (0..actual_chunks) |i| chunk_offsets[i] = if (chunk_width == 8) be64(data, stco.payload + 8 + i * 8) else be32(data, stco.payload + 8 + i * 4);
        const entries_at = stsc.payload + 8;
        if (entries_at + chunk_entries * 12 > stsc.end or stts.payload + 8 + timing_entries * 8 > stts.end) continue;
        var durations: [max_frames]u32 = @splat(40);
        var sample_at: usize = 0;
        for (0..timing_entries) |i| {
            const p = stts.payload + 8 + i * 8;
            const run = be32(data, p);
            const duration = be32(data, p + 4);
            for (0..@min(run, samples -| sample_at)) |_| {
                durations[sample_at] = duration;
                sample_at += 1;
            }
            if (sample_at == samples) break;
        }
        const timescale_at = mdhd.payload + (if (data[mdhd.payload] == 1) @as(usize, 20) else 12);
        if (timescale_at + 4 > mdhd.end) continue;
        const timescale = be32(data, timescale_at);
        if (timescale == 0) continue;
        var time_units: u64 = 0;
        sample_at = 0;
        for (0..actual_chunks) |chunk_i| {
            const chunk_number = chunk_i + 1;
            var samples_per_chunk: usize = 0;
            for (0..chunk_entries) |j| {
                const p = entries_at + j * 12;
                const first_chunk = be32(data, p);
                const next_first = if (j + 1 < chunk_entries) be32(data, p + 12) else std.math.maxInt(u32);
                if (first_chunk <= chunk_number and chunk_number < next_first) samples_per_chunk = be32(data, p + 4);
            }
            if (samples_per_chunk == 0) continue;
            var frame_offset: usize = @intCast(chunk_offsets[chunk_i]);
            for (0..samples_per_chunk) |_| {
                if (sample_at >= samples) break;
                const length: usize = sizes[sample_at];
                if (!appendFrame(frame_offset, length, time_units * 1000 / timescale)) return false;
                frame_offset += length;
                time_units +%= durations[sample_at];
                sample_at += 1;
            }
            if (sample_at == samples) break;
        }
        if (frame_count != 0) return true;
    }
    return false;
}

const Vint = struct { value: u64, length: usize };
fn ebmlVint(data: []const u8, at: usize, keep_marker: bool) ?Vint {
    if (at >= data.len or data[at] == 0) return null;
    var marker: u8 = 0x80;
    var length: usize = 1;
    while (data[at] & marker == 0 and length < 8) : (length += 1) marker >>= 1;
    if (length > 8 or at + length > data.len) return null;
    var value: u64 = if (keep_marker) data[at] else data[at] & (marker - 1);
    for (1..length) |i| value = (value << 8) | data[at + i];
    return .{ .value = value, .length = length };
}
const EbmlElement = struct { id: u64, payload: usize, end: usize };
fn ebmlElement(data: []const u8, at: usize, parent_end: usize) ?EbmlElement {
    const id = ebmlVint(data, at, true) orelse return null;
    const size = ebmlVint(data, at + id.length, false) orelse return null;
    const payload = at + id.length + size.length;
    if (payload > parent_end) return null;
    const unknown_size = size.value == ((@as(u64, 1) << @intCast(size.length * 7)) - 1);
    if (unknown_size) return .{ .id = id.value, .payload = payload, .end = parent_end };
    if (size.value > parent_end - payload) return null;
    return .{ .id = id.value, .payload = payload, .end = payload + @as(usize, @intCast(size.value)) };
}
fn uintElement(data: []const u8, e: EbmlElement) u64 {
    var value: u64 = 0;
    for (data[e.payload..e.end]) |b| value = (value << 8) | b;
    return value;
}
fn parseMkvTracks(data: []const u8, tracks: EbmlElement, video_track: *u64) void {
    var p = tracks.payload;
    while (p < tracks.end) {
        const entry = ebmlElement(data, p, tracks.end) orelse break;
        p = entry.end;
        if (entry.id != 0xae) continue;
        var q = entry.payload;
        var number: u64 = 0;
        var track_type: u64 = 0;
        var vp8_track = false;
        var h264_track = false;
        var private_start: usize = 0;
        var private_end: usize = 0;
        while (q < entry.end) {
            const field = ebmlElement(data, q, entry.end) orelse break;
            q = field.end;
            if (field.id == 0xd7) number = uintElement(data, field);
            if (field.id == 0x83) track_type = uintElement(data, field);
            if (field.id == 0x86) vp8_track = has(data, field.payload, "V_VP8");
            if (field.id == 0x86) h264_track = has(data, field.payload, "V_MPEG4/ISO/AVC");
            if (field.id == 0x63a2) {
                private_start = field.payload;
                private_end = field.end;
            }
        }
        if (track_type == 1 and vp8_track) {
            video_track.* = number;
            selected_codec = .vp8;
        } else if (track_type == 1 and h264_track) {
            if (private_start != 0 and setAvcConfig(data, private_start, private_end)) {
                video_track.* = number;
                selected_codec = .h264;
            }
        }
    }
}
fn parseMkvBlock(data: []const u8, block: EbmlElement, track: u64, cluster_time: u64, scale_ns: u64) bool {
    const track_vint = ebmlVint(data, block.payload, false) orelse return false;
    const p = block.payload + track_vint.length;
    if (p + 3 > block.end or track_vint.value != track) return true;
    const flags = data[p + 2];
    if ((flags & 0x06) != 0) return false; // Laced frames are not handled yet.
    if (selected_codec == .vp8 and (flags & 0x80) == 0) return false;
    const relative: i16 = @bitCast(be16(data, p));
    const ticks_i64 = @as(i64, @intCast(cluster_time)) + relative;
    const ticks: u64 = @intCast(@max(0, ticks_i64));
    return appendFrame(p + 3, block.end - (p + 3), ticks * scale_ns / 1_000_000);
}
fn parseMkv(data: []const u8) bool {
    var segment: ?EbmlElement = null;
    var p: usize = 0;
    while (p < data.len) {
        const e = ebmlElement(data, p, data.len) orelse break;
        p = e.end;
        if (e.id == 0x18538067) {
            segment = e;
            break;
        }
    }
    const seg = segment orelse return false;
    var scale_ns: u64 = 1_000_000;
    var track: u64 = 0;
    var q = seg.payload;
    while (q < seg.end) {
        const e = ebmlElement(data, q, seg.end) orelse break;
        q = e.end;
        if (e.id == 0x1549a966) {
            var t = e.payload;
            while (t < e.end) {
                const v = ebmlElement(data, t, e.end) orelse break;
                t = v.end;
                if (v.id == 0x2ad7b1) scale_ns = uintElement(data, v);
            }
        } else if (e.id == 0x1654ae6b) {
            parseMkvTracks(data, e, &track);
        }
    }
    if (track == 0 or scale_ns == 0) return false;
    q = seg.payload;
    while (q < seg.end) {
        const cluster = ebmlElement(data, q, seg.end) orelse break;
        q = cluster.end;
        if (cluster.id != 0x1f43b675) continue;
        var cluster_time: u64 = 0;
        var r = cluster.payload;
        while (r < cluster.end) {
            const e = ebmlElement(data, r, cluster.end) orelse break;
            r = e.end;
            if (e.id == 0xe7) cluster_time = uintElement(data, e);
        }
        r = cluster.payload;
        while (r < cluster.end) {
            const e = ebmlElement(data, r, cluster.end) orelse break;
            r = e.end;
            if (e.id == 0xa3 and !parseMkvBlock(data, e, track, cluster_time, scale_ns)) return false;
        }
    }
    return frame_count != 0;
}

fn clearPicture() void {
    if (picture) |p| media.release(p);
    picture = null;
}
fn shutdownH264() void {
    if (h264_storage) |storage| {
        h264bsdShutdown(storage);
        h264bsdFree(storage);
    }
    h264_storage = null;
    h264_active = false;
    h264_alloc_cursor = 0;
}
fn appendH264Nal(nal: []const u8) bool {
    if (nal.len == 0 or nal.len > max_h264_nal or h264_input_used + 4 > h264_input.len or nal.len > h264_input.len - h264_input_used - 4) return false;
    h264_input[h264_input_used] = 0;
    h264_input[h264_input_used + 1] = 0;
    h264_input[h264_input_used + 2] = 0;
    h264_input[h264_input_used + 3] = 1;
    @memcpy(h264_input[h264_input_used + 4 .. h264_input_used + 4 + nal.len], nal);
    h264_input_used += nal.len + 4;
    return true;
}
fn decodeH264AccessUnit() bool {
    const storage = h264_storage orelse return false;
    if (h264_input_used == 0) return false;
    var decoded_ptr: ?[*]u8 = null;
    var width: u32 = 0;
    var height: u32 = 0;
    const code = h264bsdDecode(storage, &h264_input, @intCast(h264_input_used), &decoded_ptr, &width, &height);
    if (code != 1) return false;
    const yuv = decoded_ptr orelse return false;
    if (width == 0 or height == 0 or @as(u64, width) * height > 2 * 1024 * 1024) return false;
    const out = media.allocate(width, height) orelse return false;
    const y_size: usize = @as(usize, width) * height;
    const c_width: usize = (@as(usize, width) + 1) / 2;
    const c_height: usize = (@as(usize, height) + 1) / 2;
    const c_size = c_width * c_height;
    for (0..height) |y| for (0..width) |x| {
        const yy = yuv[y * @as(usize, width) + x];
        const ci = y_size + (y / 2) * c_width + x / 2;
        const uu = yuv[ci];
        const vv = yuv[y_size + c_size + (y / 2) * c_width + x / 2];
        const c = @as(i32, yy) - 16;
        const d = @as(i32, uu) - 128;
        const e = @as(i32, vv) - 128;
        const rr: u8 = @intCast(std.math.clamp((298 * c + 409 * e + 128) >> 8, 0, 255));
        const gg: u8 = @intCast(std.math.clamp((298 * c - 100 * d - 208 * e + 128) >> 8, 0, 255));
        const bb: u8 = @intCast(std.math.clamp((298 * c + 516 * d + 128) >> 8, 0, 255));
        out.pixels[y * @as(usize, width) + x] = (@as(u32, rr) << 24) | (@as(u32, gg) << 16) | (@as(u32, bb) << 8) | 0xff;
    };
    clearPicture();
    picture = out;
    return true;
}
fn startH264() bool {
    if (h264_config_len < 7) return false;
    const storage = h264bsdAlloc() orelse return false;
    h264_storage = storage;
    if (h264bsdInit(storage, 1) != 0) {
        shutdownH264();
        return false;
    }
    h264_active = true;
    h264_config_pending = true;
    var p: usize = 6;
    const sps_count = h264_config[5] & 0x1f;
    for (0..sps_count) |_| {
        if (p + 2 > h264_config_len) return false;
        const n = be16(h264_config[0..], p);
        p += 2;
        if (n == 0 or n > h264_config_len - p) return false;
        p += n;
    }
    if (p >= h264_config_len) return false;
    const pps_count = h264_config[p];
    p += 1;
    for (0..pps_count) |_| {
        if (p + 2 > h264_config_len) return false;
        const n = be16(h264_config[0..], p);
        p += 2;
        if (n == 0 or n > h264_config_len - p) return false;
        p += n;
    }
    return true;
}
fn decodeH264Sample(bytes: []const u8) bool {
    if (!h264_active or bytes.len == 0) return false;
    h264_input_used = 0;
    if (h264_config_pending) {
        var config_at: usize = 6;
        const sps_count = h264_config[5] & 0x1f;
        for (0..sps_count) |_| {
            if (config_at + 2 > h264_config_len) return false;
            const n = be16(h264_config[0..], config_at);
            config_at += 2;
            if (n == 0 or n > h264_config_len - config_at or !appendH264Nal(h264_config[config_at .. config_at + n])) return false;
            config_at += n;
        }
        if (config_at >= h264_config_len) return false;
        const pps_count = h264_config[config_at];
        config_at += 1;
        for (0..pps_count) |_| {
            if (config_at + 2 > h264_config_len) return false;
            const n = be16(h264_config[0..], config_at);
            config_at += 2;
            if (n == 0 or n > h264_config_len - config_at or !appendH264Nal(h264_config[config_at .. config_at + n])) return false;
            config_at += n;
        }
    }
    var p: usize = 0;
    while (p + h264_length_size <= bytes.len) {
        var n: usize = 0;
        for (0..h264_length_size) |i| n = (n << 8) | bytes[p + i];
        p += h264_length_size;
        if (n == 0 or n > bytes.len - p or n > max_h264_nal) return false;
        if (!appendH264Nal(bytes[p .. p + n])) return false;
        p += n;
    }
    if (p != bytes.len or !decodeH264AccessUnit()) return false;
    h264_config_pending = false;
    return true;
}
fn decodeCurrent() bool {
    if (next_frame >= frame_count) return false;
    const ref = frame_refs[next_frame];
    const bytes = file_buffer[ref.offset .. ref.offset + ref.length];
    clearPicture();
    if (active_codec == .h264) return decodeH264Sample(bytes);
    if (has(bytes, 0, "\xff\xd8")) {
        picture = image.decode(bytes) orelse return false;
        return true;
    }
    const decoded = vp8.decode(heap.allocator(), bytes, .{}) catch return false;
    defer {
        var frame = decoded;
        frame.deinit(heap.allocator());
    }
    if (decoded.width == 0 or decoded.height == 0 or @as(u64, decoded.width) * decoded.height > 2 * 1024 * 1024) return false;
    const out = media.allocate(decoded.width, decoded.height) orelse return false;
    for (0..decoded.height) |y| {
        const yy = decoded.luma(y);
        const uu = decoded.chromaU(y / 2);
        const vv = decoded.chromaV(y / 2);
        for (0..decoded.width) |x| {
            const rgb = vp8.rgb.toRgb(yy[x], uu[x / 2], vv[x / 2]);
            out.pixels[y * decoded.width + x] = (@as(u32, rgb[0]) << 24) | (@as(u32, rgb[1]) << 16) | (@as(u32, rgb[2]) << 8) | 0xff;
        }
    }
    picture = out;
    return true;
}

pub fn stop() void {
    active = false;
    clearPicture();
    shutdownH264();
    frame_count = 0;
    h264_config_len = 0;
    status = "Playback stopped";
}
pub fn play(directory: u32, name: []const u8) bool {
    stop();
    if (name.len == 0 or !s.fs_mounted) return false;
    const length = fat32.readFileAt(directory, name, &file_buffer) orelse {
        status = "Could not read video";
        return false;
    };
    return startPlayback(name, length, 11);
}

/// Starts playback from an in-memory file without saving it to disk.
/// The bytes are copied into the bounded decoder buffer and are not saved to disk.
pub fn playBuffer(bytes: []const u8, name: []const u8, window_index: usize) bool {
    stop();
    if (bytes.len == 0 or bytes.len > file_buffer.len or window_index >= s.windows.len) {
        status = "Video is empty or exceeds the 8 MiB playback limit";
        return false;
    }
    @memcpy(file_buffer[0..bytes.len], bytes);
    return startPlayback(name, bytes.len, window_index);
}

fn startPlayback(name: []const u8, length: usize, window_index: usize) bool {
    frame_count = 0;
    next_frame = 0;
    selected_codec = .mjpeg;
    h264_length_size = 4;
    if (length == 0 or length > max_file) {
        status = "Video is empty or exceeds the 8 MiB limit";
        return false;
    }
    const data = file_buffer[0..length];
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return false;
    const ext = name[dot..];
    const parsed = if (std.ascii.eqlIgnoreCase(ext, ".mkv")) parseMkv(data) else parseMp4(data);
    if (!parsed) {
        frame_count = 0;
        status = if (std.ascii.eqlIgnoreCase(ext, ".mkv"))
            "MKV needs VP8 or supported H.264 Baseline video"
        else
            "MP4 needs Motion JPEG or supported H.264 Baseline video";
        return false;
    }
    active_codec = selected_codec;
    if (active_codec == .h264 and !startH264()) {
        shutdownH264();
        frame_count = 0;
        status = "H.264 init failed; use Baseline profile with I/P frames";
        return false;
    }
    if (!decodeCurrent()) {
        frame_count = 0;
        status = "Video frame could not be decoded";
        return false;
    }
    active = true;
    owner_window = window_index;
    next_frame = 1;
    playback_start_ms = s.uptime() * 10;
    next_due_ms = if (frame_count > 1) playback_start_ms +| (frame_refs[1].time_ms -| frame_refs[0].time_ms) else playback_start_ms;
    status = "Playing video";
    return true;
}
pub fn update() bool {
    return updateFor(owner_window);
}

pub fn updateFor(window_index: usize) bool {
    if (window_index != owner_window) return false;
    if (!active) return false;
    if (owner_window >= s.windows.len or s.windows[owner_window].open == false or s.windows[owner_window].minimized) {
        active = false;
        return false;
    }
    const now_ms = s.uptime() * 10;
    if (next_frame >= frame_count) {
        active = false;
        status = "Video playback finished";
        return true;
    }
    if (now_ms < next_due_ms) return false;
    if (!decodeCurrent()) {
        active = false;
        status = "Unsupported or damaged video frame";
        return true;
    }
    next_frame += 1;
    next_due_ms = if (next_frame < frame_count)
        playback_start_ms +| (frame_refs[next_frame].time_ms -| frame_refs[0].time_ms)
    else
        now_ms;
    return true;
}
pub fn isActive() bool {
    return active;
}
pub fn draw(x: u64, y: u64, width: u64, height: u64) void {
    if (picture) |p| media.drawFit(p, x, y, width, height);
}
