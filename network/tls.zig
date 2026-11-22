//! TLS stream sessions over the kernel TCP client sockets.
//! Verification must use a populated CA bundle; this module does not silently
//! accept untrusted certificates.
const std = @import("std");
const stack = @import("stack.zig");
const entropy_source = @import("entropy.zig");
const e1000 = @import("../drivers/e1000.zig");
const state = @import("../system/state.zig");
const panic_report = @import("../system/panic.zig");

const CryptoClient = std.crypto.tls.Client;
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;
const max_sessions = 2;
const transport_chunk = 512;
const io_timeout_ticks = 1500;
// TLS handshakes do several cryptographic operations while the whole OS is
// serviced by one polling loop. A small spin budget expires far sooner than
// io_timeout_ticks on a slow QEMU or physical CPU, even though the socket is
// still healthy. Keep the wall-clock bound, but allow enough polls to reach it.
const max_io_spins: usize = 5_000_000;

pub const Verification = @FieldType(CryptoClient.Options, "ca");
pub const entropy_len = CryptoClient.Options.entropy_len;
pub const InitError = CryptoClient.InitError || error{InvalidSession, InvalidHost, TcpNotConnected, CertificateBundleRequired, EntropyUnavailable};

const Session = struct {
    active: bool = false,
    tcp_socket: u8 = 0,
    reader_storage: [CryptoClient.min_buffer_len]u8 = @splat(0),
    // std.crypto.tls.Client asks its ciphertext output writer for at least
    // min_buffer_len bytes. A zero-capacity writer makes Writer.defaultRebase
    // retry forever in ReleaseFast, which looked like a hard freeze directly
    // after the TLS handshake.
    writer_storage: [CryptoClient.min_buffer_len]u8 = @splat(0),
    tls_read_storage: [CryptoClient.min_buffer_len]u8 = @splat(0),
    tls_write_storage: [CryptoClient.min_buffer_len]u8 = @splat(0),
    raw_reader: Reader = undefined,
    raw_writer: Writer = undefined,
    client: CryptoClient = undefined,
};

var sessions: [max_sessions]Session = @splat(.{});

fn serviceNetwork() void {
    e1000.poll(stack.onEthernetFrame);
    stack.poll();
}

fn parentFromReader(raw_reader: *Reader) *Session {
    return @fieldParentPtr("raw_reader", raw_reader);
}
fn parentFromWriter(raw_writer: *Writer) *Session {
    return @fieldParentPtr("raw_writer", raw_writer);
}

fn readStream(raw_reader: *Reader, destination: *Writer, limit: std.Io.Limit) Reader.StreamError!usize {
    const session = parentFromReader(raw_reader);
    const maximum = @min(limit.toInt() orelse transport_chunk, transport_chunk);
    if (maximum == 0) return 0;
    var bytes: [transport_chunk]u8 = undefined;
    const deadline = state.uptime() + io_timeout_ticks;
    var spins: usize = 0;
    while (state.uptime() < deadline and spins < max_io_spins) : (spins += 1) {
        serviceNetwork();
        // Reader.Stream must never return more bytes than the caller's limit.
        // In particular TLS often asks for one byte while finishing a record;
        // consuming a whole TCP segment here can overrun that read boundary
        // and desynchronize later TLS records on larger subresources.
        if (stack.tcpReceive(session.tcp_socket, bytes[0..maximum])) |length| {
            try destination.writeAll(bytes[0..length]);
            return length;
        }
        if (stack.tcpPeerClosed(session.tcp_socket)) return error.EndOfStream;
        // Yield to the host between polls. Busy-polling can exhaust the spin
        // budget before QEMU's user-network backend gets scheduled to deliver
        // the next TCP segment.
        asm volatile ("hlt");
    }
    if (spins >= max_io_spins) {
        panic_report.trace("TLS transport read exhausted its polling budget");
    } else {
        panic_report.trace("TLS transport read timed out waiting for TCP data");
    }
    return error.ReadFailed;
}

fn sendBytes(session: *Session, bytes: []const u8) bool {
    var offset: usize = 0;
    const deadline = state.uptime() + io_timeout_ticks;
    var spins: usize = 0;
    while (offset < bytes.len and state.uptime() < deadline and spins < max_io_spins) : (spins += 1) {
        const amount = @min(bytes.len - offset, 4096);
        if (stack.tcpSend(session.tcp_socket, bytes[offset .. offset + amount])) {
            offset += amount;
            continue;
        }
        if (stack.tcpPeerClosed(session.tcp_socket)) {
            panic_report.trace("TLS transport: peer closed during write");
            return false;
        }
        serviceNetwork();
        asm volatile ("hlt");
    }
    return offset == bytes.len;
}

fn drain(raw_writer: *Writer, data: []const []const u8, splat: usize) Writer.Error!usize {
    const session = parentFromWriter(raw_writer);
    // Writer.drain receives existing buffered bytes separately from the new
    // slices. Flush buffered bytes even when `data` is empty: Zig uses that
    // form for a plain flush, and skipping it leaves application records
    // (such as the HTTP request) unsent until the peer times out.
    const buffered = raw_writer.buffered();
    if (data.len == 0 and buffered.len == 0) return 0;
    if (!sendBytes(session, buffered)) {
        panic_report.trace("TLS transport: buffered write failed");
        return error.WriteFailed;
    }
    var sent: usize = buffered.len;
    if (data.len != 0) {
        for (data[0 .. data.len - 1]) |bytes| {
            if (!sendBytes(session, bytes)) {
                panic_report.trace("TLS transport: write failed");
                return error.WriteFailed;
            }
            sent += bytes.len;
        }
        const repeated = data[data.len - 1];
        for (0..splat) |_| {
            if (!sendBytes(session, repeated)) {
                panic_report.trace("TLS transport: write failed");
                return error.WriteFailed;
            }
            sent += repeated.len;
        }
    }
    return raw_writer.consume(sent);
}

const reader_vtable: Reader.VTable = .{ .stream = readStream };
const writer_vtable: Writer.VTable = .{ .drain = drain };

/// Fills TLS's required entropy using the CPU RDRAND instruction. It returns
/// false on CPUs without RDRAND or when the hardware source repeatedly fails.
pub fn secureRandom(output: *[entropy_len]u8) bool {
    return entropy_source.fill(output);
}

/// Starts a TLS 1.2/1.3 handshake on an already connected TCP socket.
/// A verified CA bundle, wall clock, and fresh secure entropy are mandatory.
/// Keep `host` alive through this call; certificate validation and SNI finish
/// before this function returns.
pub fn init(
    session_id: u8,
    tcp_socket: u8,
    host: []const u8,
    verification: Verification,
    now: std.Io.Timestamp,
    entropy: *const [entropy_len]u8,
) InitError!void {
    if (session_id >= sessions.len) return error.InvalidSession;
    if (host.len == 0 or host.len > 253) return error.InvalidHost;
    if (!stack.tcpConnected(tcp_socket)) return error.TcpNotConnected;
    switch (verification) {
        .bundle => {},
        else => return error.CertificateBundleRequired,
    }
    const session = &sessions[session_id];
    session.* = .{};
    session.tcp_socket = tcp_socket;
    session.raw_reader = .{
        .vtable = &reader_vtable,
        .buffer = &session.reader_storage,
        .seek = 0,
        .end = 0,
    };
    session.raw_writer = .{
        .vtable = &writer_vtable,
        .buffer = &session.writer_storage,
        .end = 0,
    };
    session.active = true;
    session.client = CryptoClient.init(&session.raw_reader, &session.raw_writer, .{
        .host = .{ .explicit = host },
        .ca = verification,
        .read_buffer = &session.tls_read_storage,
        .write_buffer = &session.tls_write_storage,
        .entropy = entropy,
        .realtime_now = now,
        .allow_truncation_attacks = false,
    }) catch |err| {
        session.active = false;
        return err;
    };
}

/// Loads PEM CA certificates into a Zig certificate bundle. The caller can
/// read the PEM file from FAT32 and pass its bytes here.
pub fn appendPemBundle(bundle: *std.crypto.Certificate.Bundle, allocator: std.mem.Allocator, pem: []const u8, now_seconds: i64) !usize {
    const begin_marker = "-----BEGIN CERTIFICATE-----";
    const end_marker = "-----END CERTIFICATE-----";
    const decoder = std.base64.standard.decoderWithIgnore(" \t\r\n");
    var cursor: usize = 0;
    var loaded: usize = 0;
    while (std.mem.indexOfPosLinear(u8, pem, cursor, begin_marker)) |begin| {
        const content_start = begin + begin_marker.len;
        const marker_end = std.mem.indexOfPosLinear(u8, pem, content_start, end_marker) orelse return error.InvalidPem;
        const encoded = pem[content_start..marker_end];
        const decoded_storage = try allocator.alloc(u8, decoder.calcSizeUpperBound(encoded.len));
        defer allocator.free(decoded_storage);
        const decoded_len = decoder.decode(decoded_storage, encoded) catch return error.InvalidPem;
        if (decoded_len == 0 or bundle.bytes.items.len > std.math.maxInt(u32)) return error.InvalidPem;
        const decoded_start: u32 = @intCast(bundle.bytes.items.len);
        try bundle.bytes.appendSlice(allocator, decoded_storage[0..decoded_len]);
        bundle.parseCert(allocator, decoded_start, now_seconds) catch |err| {
            bundle.bytes.items.len = decoded_start;
            return err;
        };
        if (bundle.bytes.items.len != decoded_start) loaded += 1;
        cursor = marker_end + end_marker.len;
    }
    if (loaded == 0) return error.NoCertificates;
    return loaded;
}

/// Collects fresh entropy from RDRAND and then starts a verified TLS session.
pub fn connect(
    session_id: u8,
    tcp_socket: u8,
    host: []const u8,
    verification: Verification,
    now: std.Io.Timestamp,
) InitError!void {
    var entropy: [entropy_len]u8 = undefined;
    if (!secureRandom(&entropy)) return error.EntropyUnavailable;
    return init(session_id, tcp_socket, host, verification, now, &entropy);
}

pub fn reader(session_id: u8) ?*Reader {
    if (session_id >= sessions.len or !sessions[session_id].active) return null;
    return &sessions[session_id].client.reader;
}

pub fn writer(session_id: u8) ?*Writer {
    if (session_id >= sessions.len or !sessions[session_id].active) return null;
    return &sessions[session_id].client.writer;
}

/// Flushes TLS ciphertext from Zig's TLS output writer to the TCP socket.
/// `Client.writer.flush()` only stages encrypted bytes in `raw_writer`.
pub fn flushTransport(session_id: u8) Writer.Error!void {
    if (session_id >= sessions.len or !sessions[session_id].active) return error.WriteFailed;
    try sessions[session_id].raw_writer.flush();
}

pub fn end(session_id: u8) void {
    if (session_id >= sessions.len or !sessions[session_id].active) return;
    sessions[session_id].client.end() catch {};
    stack.tcpClose(sessions[session_id].tcp_socket);
    sessions[session_id].active = false;
}
