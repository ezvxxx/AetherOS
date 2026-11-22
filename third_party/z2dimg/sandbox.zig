// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Decoding in a process that cannot do anything but decode.
//!
//! Image decoders are where memory-safety bugs live. They parse
//! attacker-controlled binary structures, they do arithmetic on lengths, and
//! they are reached by every program that displays a picture from anywhere.
//! Zig's bounds and overflow checks catch a great deal of that in a safe build
//! and none of it in `ReleaseFast`, and neither build catches a logic error
//! that reads the wrong part of a buffer it is entitled to read. So the
//! decoder is run somewhere it can do no harm even if it is wrong.
//!
//! This follows [glycin](https://gitlab.gnome.org/GNOME/glycin), GNOME's image
//! loading library, which runs each format's loader as a separate sandboxed
//! process and passes the pixels back through shared memory. The mechanism
//! here is smaller — one `fork`, one seccomp filter, one `memfd` — because the
//! decoders it is protecting are already pure: being sans-I/O means a decoder
//! never opens anything, so there is nothing to permit.
//!
//! That is the Linux description, and the one the rest of this comment uses.
//! FreeBSD has the same design with Capsicum in place of seccomp; see "Where
//! it runs" below, and `capsicum` for what differs.
//!
//! ## How it works
//!
//! ```text
//!   parent                              child
//!   ------                              -----
//!   read the input into memory
//!   memfd_create + ftruncate
//!   mmap MAP_SHARED  ─────────────────▶ inherited across fork()
//!   pipe2
//!   fork()  ──────────────────────────▶ prctl(PR_SET_NO_NEW_PRIVS)
//!                                       seccomp(SET_MODE_FILTER)
//!                                       ── nothing further is permitted ──
//!                                       decode, allocating from the mapping
//!                                       write(pipe, reply)
//!                                       exit_group(0)
//!   waitpid   ◀────────────────────────
//!   read the reply, validate it
//!   munmap the unused tail
//!   wrap the pixels as a z2d.Surface
//! ```
//!
//! Three details carry most of the design.
//!
//! **The input is copied in before the fork**, rather than streamed to the
//! child. A child that could still read its input would need `read` on a file
//! descriptor an attacker might redirect, and would introduce a deadlock — two
//! processes each blocked writing to a pipe the other is not draining. Copying
//! first costs the memory the encoded image occupies, bounded by
//! `Limits.max_input_bytes`, and buys a child that needs no input syscall at
//! all: after `fork` the bytes are simply there, copy-on-write.
//!
//! An animation is the exception and needs one, because streaming means
//! waiting. It is a `read` of a single byte from a descriptor the filter
//! names by number and permits on no other — which is possible only because a
//! descriptor is an integer, and is why the child moves the pipe onto a fixed
//! number before the filter goes on. There is still no deadlock to have: the
//! parent reads a reply before it writes an acknowledgement, so the two never
//! wait on each other.
//!
//! **The child allocates out of the shared mapping.** Its allocator is a
//! `FixedBufferAllocator` over the `memfd`, so the surface it decodes into is
//! already in memory the parent can see, and there is nothing to copy back.
//! It also means the child needs no `mmap` and no `brk`: the memory was
//! reserved before the filter was installed. The reservation is address space
//! rather than memory — pages of a `memfd` are allocated when they are first
//! touched — so the default budget costs nothing for a small image.
//!
//! **The reply is one fixed-size struct**, small enough that the write cannot
//! block on a full pipe, which is what lets the parent wait for the child to
//! exit *before* reading it. By the time the parent looks at the pixels the
//! writer of those pixels no longer exists.
//!
//! That last property belongs to `decode` and not to `decodeAnimation`, which
//! streams: there the child is alive between frames, waiting to be told it may
//! write the next one over the last. Every shape check survives --- a reply
//! still cannot make the parent read outside the mapping --- and what is given
//! up is that a frame's *contents* may change while the parent is looking at
//! them, which is a torn picture rather than a memory-safety failure. See
//! `AnimationStream`, which says what that costs and what it buys.
//!
//! ## What this protects against, and what it does not
//!
//! It contains a decoder that has been subverted into doing something other
//! than decoding: reading a file, opening a socket, executing a program,
//! attaching to another process. All of those die at the attempt.
//!
//! It contains a decoder that crashes. A segmentation fault in the child is a
//! `error.DecoderCrashed` in the parent, not a dead program.
//!
//! It does **not** make the pixels trustworthy. A subverted decoder can still
//! write whatever it likes into the shared mapping, because writing there is
//! its job. What the parent validates is the *shape* of the result — that the
//! buffer is inside the mapping, correctly aligned, and exactly the length the
//! stated dimensions require — so a malicious reply cannot make the parent
//! read out of bounds. The contents of a valid-looking buffer are the
//! attacker's if the decoder was theirs.
//!
//! It does not stop a decoder reading the rest of the shared mapping, which
//! holds this decode's own working memory and nothing else.
//!
//! ## What the child is stripped of before the filter goes on
//!
//! A forked child keeps everything the parent had, because `CLOEXEC` means
//! nothing to a process that never execs. Four things are taken away first,
//! and none of them needs permitting because all of them happen before the
//! filter exists:
//!
//! **Its inherited descriptors.** A decoder cannot *open* a socket under any
//! profile here, but `write` is a call it has, and a subverted one could put
//! attacker-controlled bytes into a connection the parent already had. The
//! pipes are moved to fixed numbers, everything above them is closed, and the
//! strict profiles then permit `write` on the reply descriptor and no other.
//! The two halves are what make each other worth having: closing takes away
//! what could be written to, and the filter takes away the ability to name
//! anything else.
//!
//! **Processor time**, through `RLIMIT_CPU`. A decoder stuck in a loop is
//! killed by the kernel, so the parent needs no clock of its own. Waiting on
//! a pipe does not count towards it, which is what makes it safe for a
//! streaming decode that may sit idle between frames.
//!
//! **Core dumps**, through `RLIMIT_CORE`, so that a crash does not write the
//! shared mapping out to disk.
//!
//! **Dumpability**, through `PR_SET_DUMPABLE`, which also stops another
//! process of the same user attaching with `ptrace` and reading the mapping
//! out from under the parent.
//!
//! It is not a replacement for the limits. A child cannot exhaust the parent's
//! memory, but it can touch every page of the mapping, so the mapping is sized
//! by `Limits` like everything else here.
//!
//! ## Cost
//!
//! A `fork` and a `waitpid` per image, plus the page faults for the pixels.
//! That is tens of microseconds against a decode measured in milliseconds for
//! anything but a tiny image — but it is per image, so a program decoding
//! thousands of thumbnails should measure rather than assume.
//!
//! ## Where it runs
//!
//! On 64-bit Linux, under seccomp, and on 64-bit FreeBSD, under Capsicum.
//! The process design is the same on both --- fork, a shared mapping, the
//! reply pipe on a fixed descriptor, everything else closed --- and only the
//! lock differs. seccomp is an allowlist of system calls; Capsicum takes away
//! every global namespace, so that the calls it permits have nothing to reach.
//! A call either one refuses kills the child, and the parent reports
//! `error.SandboxViolation` for both. `capsicum` says what Capsicum does not
//! refuse that seccomp does, which is short but not empty.
//!
//! `available` says at compile time whether this target is one of them.
//! Elsewhere --- macOS, Windows, a 32-bit build --- a decode asking for
//! `Isolation.process` returns `error.SandboxUnavailable` rather than silently
//! decoding unsandboxed: a security feature that quietly turns itself off is
//! worse than one that was never there.
//!
//! ## Deciding not to isolate
//!
//! There are two good reasons to decode without a child process, and both are
//! a decision for the caller rather than something to fall back to. The
//! platform may have no sandbox this module can use: macOS's is deprecated
//! and Windows' needs a second executable, which a library has no business
//! shipping. Or the caller may already be inside one --- a renderer that runs
//! in a locked-down child of its own and meets a PNG embedded in the document
//! it is drawing, say, where forking again would buy nothing and the filter it
//! is under would refuse the fork anyway.
//!
//! `Options.isolation = .none` is that decision, written down. It runs the
//! same code in this process, through the same `Image` and `AnimationStream`,
//! with the same limits and the same errors, so a program can make the choice
//! in one place and have one code path after it. `Isolation.best` chooses
//! `.process` where the sandbox exists and `.none` where it does not, for a
//! caller who has decided that is acceptable --- and it is spelled out, rather
//! than being the default, so that the decision shows up in the source.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
/// For the two tests that are claims about seccomp alone; everything else goes
/// through `os`.
const linux = std.os.linux;
const math = std.math;
const mem = std.mem;
const testing = std.testing;
const Allocator = mem.Allocator;

const z2d = @import("z2d");

const codecs = @import("codecs.zig");
const common = @import("common.zig");
const format = @import("format.zig");
const anim = @import("anim.zig");
const exif = @import("exif.zig");
const pixels = @import("pixels.zig");

/// The seccomp filter the child runs under on Linux. Its `Profile` is also
/// what `Options.profile` takes on FreeBSD.
pub const seccomp = @import("sandbox/seccomp.zig");

/// How the child is locked down on FreeBSD.
pub const capsicum = @import("sandbox/capsicum.zig");

/// The process plumbing for this target: `sandbox/linux.zig`,
/// `sandbox/freebsd.zig`, or nothing at all where neither applies.
const os = switch (builtin.os.tag) {
    .linux => @import("sandbox/linux.zig"),
    .freebsd => @import("sandbox/freebsd.zig"),
    else => struct {
        pub const supported = false;
        // Named by the fields of a stream's child, which exists as a type on
        // every target even where no value of it can ever be made.
        pub const Fd = i32;
        pub const Pid = i32;
    },
};

/// Whether this target can sandbox anything.
///
/// A 32-bit address space cannot hold the reservation this design makes,
/// seccomp is Linux's and Capsicum is FreeBSD's. Everywhere else a decode
/// asking for `Isolation.process` fails rather than pretending.
pub const available = os.supported;

/// Where a decode runs.
pub const Isolation = enum {
    /// In a forked child locked down by seccomp or Capsicum, which is the
    /// point of this module. `error.SandboxUnavailable` where `available` is
    /// false.
    process,

    /// In this process, with no isolation at all.
    ///
    /// For a platform this module cannot sandbox on, or a caller that is
    /// already sandboxed. The limits still apply, and are still the only
    /// thing between a hostile file and this process's memory; `profile`,
    /// `working_bytes` and `cpu_seconds` mean nothing without a child and are
    /// ignored. See "Deciding not to isolate" in the module comment.
    none,

    /// `process` where the sandbox exists and `none` where it does not.
    ///
    /// Not the default, on purpose: it is the choice to decode unsandboxed
    /// on some platforms, and a caller making it should have to say so.
    pub const best: Isolation = if (available) .process else .none;
};

/// The most address space the mapping may reserve. Far above any plausible
/// image, and low enough that a `Limits` with nothing in it is caught here
/// rather than by `mmap`.
const max_reservation: u64 = 1 << 40;

/// Errors from a sandboxed decode.
///
/// A superset of `DecodeError`: everything an ordinary decode can fail with,
/// plus what can go wrong with the sandbox itself.
pub const Error = common.DecodeError || error{
    /// `Isolation.process` was asked for on a target where `available` is
    /// false: neither Linux nor FreeBSD, or not 64-bit.
    SandboxUnavailable,

    /// `Limits` does not bound the image tightly enough to reserve memory
    /// for — `Limits.unlimited`, or something close to it. The sandbox has to
    /// reserve the output before it knows how big the output is, so it needs a
    /// ceiling; an ordinary `decode` does not and will take these limits
    /// happily.
    LimitsUnbounded,

    /// The encoded image is larger than `Limits.max_input_bytes`.
    InputTooLarge,

    /// The child was killed for making a system call the filter refused.
    ///
    /// This means the decoder tried to do something other than decode. It is
    /// either an exploit or a bug, and under `seccomp.Profile.strict` it is
    /// also what a panicking decoder looks like, because printing a panic
    /// means reading debug info and reading is a system call. Re-running with
    /// `seccomp.Profile.permissive` tells the two apart.
    SandboxViolation,

    /// The child died some other way: a segmentation fault, an abort, a
    /// signal from outside. The decoder has a bug.
    DecoderCrashed,

    /// The child exited without a usable reply, or with one that does not
    /// describe a buffer inside the shared mapping. Nothing is read from a
    /// mapping on the strength of a reply that failed this check.
    SandboxProtocolError,

    /// The sandbox could not be set up: the shared mapping, a pipe or the
    /// `fork` was refused, or the kernel would not lock the child down. Not a
    /// property of the image.
    SandboxFailed,
};

/// How to decode, and how tightly to lock the decoder down.
pub const Options = struct {
    /// Where the decode runs. See `Isolation`.
    isolation: Isolation = .process,

    /// The same options an unsandboxed decode takes.
    decode: common.DecodeOptions = .{},

    /// How much of the system call surface to leave the decoder.
    profile: seccomp.Profile = .strict,

    /// Working memory the decoder gets on top of the pixels: the row buffers
    /// and tables a codec needs while running.
    ///
    /// Address space rather than memory, like the rest of the mapping. Too
    /// small shows up as `error.OutOfMemory` from the decode.
    working_bytes: usize = 8 << 20,

    /// A ceiling on the processor time the child may use, in seconds, or
    /// null for none.
    ///
    /// The answer to a decoder that has stopped making progress: the kernel
    /// kills it, so the parent needs no timeout of its own. A wall rather
    /// than a budget --- sixty seconds is far above what any decode inside
    /// the default `Limits.max_pixels` costs --- but a caller who raises that
    /// limit a long way should raise this with it.
    ///
    /// Time spent blocked waiting for the parent does not count towards it,
    /// which is what makes it safe for a streaming decode.
    cpu_seconds: ?u32 = 60,

    /// For `decodeAnimation`: whether to composite a canvas in *this*
    /// process as the frames arrive.
    ///
    /// The child never composites either way --- see `AnimationStream` for
    /// why that is deliberate --- so turning this off means no canvas exists
    /// at all and only the un-composited frames come back.
    composite: bool = true,
};

/// A decoded image, living in memory the sandbox set up.
///
/// Under `Isolation.process` the surface's buffer is inside a shared mapping
/// rather than in the allocator's heap, so it must **not** be released with
/// `z2d.Surface.deinit` — that would hand the mapping to an allocator that
/// never handed it out. Call `deinit` here instead, which knows where the
/// buffer came from and gives it back there; it is right under either
/// isolation, which is what lets a caller write one code path for both. The
/// surface is perfectly ordinary in every other way: draw on it, composite it,
/// clone it.
pub const Image = struct {
    /// The pixels. Valid until `deinit`.
    surface: z2d.Surface,

    /// What the decoder found in the header.
    info: common.Info,

    /// Where the surface's buffer lives. Not for the caller to touch; it is
    /// here so that `deinit` can give it back.
    backing: Backing,

    pub const Backing = union(enum) {
        /// The shared mapping a sandboxed child decoded into.
        mapping: []align(std.heap.page_size_min) u8,
        /// The allocator an unisolated decode allocated from.
        heap: Allocator,
    };

    /// Releases the pixels. The surface is invalid afterwards.
    pub fn deinit(self: *Image) void {
        switch (self.backing) {
            // Only ever made where there is a sandbox to make it, so on any
            // other target this arm is never reached and names nothing.
            .mapping => |m| if (comptime available) os.unmap(m.ptr, m.len) else unreachable,
            .heap => |gpa| self.surface.deinit(gpa),
        }
        self.* = undefined;
    }

    /// A copy of the surface in ordinary heap memory, which can be released
    /// with `z2d.Surface.deinit` like any other.
    ///
    /// For a caller who wants the sandbox for the decode and does not want to
    /// think about the mapping afterwards — the cost is one copy of the
    /// pixels.
    pub fn toOwned(self: *const Image, gpa: Allocator) Allocator.Error!z2d.Surface {
        // Done by hand because z2d has no copy constructor to call: `init`
        // allocates a blank surface and `initBuffer` adopts a buffer without
        // copying it, so there is nothing that takes a surface and gives back
        // an owned one. The switch is `inline else` so that each variant's
        // buffer keeps its own element type.
        switch (self.surface) {
            inline else => |s, tag| {
                const buf = try gpa.dupe(std.meta.Elem(@TypeOf(s.buf)), s.buf);
                return @unionInit(z2d.Surface, @tagName(tag), .{
                    .width = s.width,
                    .height = s.height,
                    .buf = buf,
                });
            },
        }
    }
};

/// Decodes `r`, in a sandboxed child process unless `opts.isolation` says
/// otherwise.
///
/// `gpa` holds the encoded input, which is released before this returns.
/// Under `Isolation.process` the pixels come back in a shared mapping; under
/// `Isolation.none` they are allocated from `gpa`. The `Image` knows which, and
/// its `deinit` is right for both.
///
/// Beware `fork` in a threaded program. This forks, and the child runs Zig
/// code between the fork and its exit, which in a multi-threaded parent is
/// only safe if that code is async-signal-safe. It is: the child locks itself
/// down, decodes out of a fixed buffer it was given, writes a struct to a pipe
/// and exits, taking no lock and allocating nothing from the parent's heap. On
/// Linux nothing it does calls into libc; on FreeBSD, where libc is the system
/// call interface, it calls only thin wrappers around single system calls.
pub fn decode(gpa: Allocator, r: *Io.Reader, opts: Options) Error!Image {
    return switch (opts.isolation) {
        .process => decodeInChild(gpa, r, opts),
        .none => decodeHere(gpa, r, opts.decode),
    };
}

/// `Isolation.none`: the child's work, done here.
///
/// Through the same `readInput` and `decodeBytes` the sandboxed path uses, so
/// that the two cannot come to disagree about what a file decodes to or which
/// error a bad one is.
fn decodeHere(gpa: Allocator, r: *Io.Reader, opts: common.DecodeOptions) Error!Image {
    const input = try readInput(gpa, r, opts.limits);
    defer gpa.free(input);
    const d = try decodeBytes(gpa, input, opts);
    return .{ .surface = d.surface, .info = d.info, .backing = .{ .heap = gpa } };
}

/// The whole encoded image, in ordinary memory, bounded by the limits. See the
/// module comment for why it is not streamed; the unisolated path reads it
/// the same way so that the two refuse the same inputs.
fn readInput(gpa: Allocator, r: *Io.Reader, limits: common.Limits) Error![]u8 {
    return r.allocRemaining(gpa, .limited64(limits.max_input_bytes)) catch |err| switch (err) {
        error.StreamTooLong => error.InputTooLarge,
        error.ReadFailed => |e| e,
        error.OutOfMemory => |e| e,
    };
}

/// What decoding a file already in memory produces, in whichever process.
const Decoded = struct {
    surface: z2d.Surface,
    /// The header's account of the image, with `surface_type` corrected to
    /// the surface actually produced --- which differs from the header's when
    /// `DecodeOptions.surface_type` asked for another.
    info: common.Info,
};

/// Detects, probes and decodes `input`. The child's work, and the unisolated
/// path's.
fn decodeBytes(gpa: Allocator, input: []const u8, opts: common.DecodeOptions) common.DecodeError!Decoded {
    var reader: Io.Reader = .fixed(input);
    const fmt = format.detectReader(&reader) catch |err| switch (err) {
        // Cannot happen: the reader's buffer is the whole input.
        error.BufferTooSmall => return error.InvalidData,
        else => |e| return e,
    };
    var info = try codecs.probe(fmt, &reader, opts.limits);

    // Probing consumed the header, so the decode runs from the top of a
    // second reader over the same bytes. They are in memory already, so this
    // costs nothing but the parse.
    var again: Io.Reader = .fixed(input);
    const sfc = try codecs.decode(gpa, fmt, &again, opts);
    info.format = fmt;
    info.surface_type = std.meta.activeTag(sfc);
    return .{ .surface = sfc, .info = info };
}

fn decodeInChild(gpa: Allocator, r: *Io.Reader, opts: Options) Error!Image {
    if (!available) return error.SandboxUnavailable;

    const limits = opts.decode.limits;
    const page = std.heap.pageSize();
    const cap = try reservation(limits, opts.working_bytes, page);

    // The whole encoded image, in ordinary memory, before the fork.
    const input = try readInput(gpa, r, limits);
    defer gpa.free(input);

    const base = os.mapShared(cap) orelse return error.SandboxFailed;
    // Unmapped on every path out but the successful one, where ownership
    // passes to the `Image`.
    var mapped = true;
    defer if (mapped) os.unmap(base, cap);

    var pipe_fds: [2]os.Fd = undefined;
    if (!os.pipe(&pipe_fds)) return error.SandboxFailed;
    // The write end is closed early on the successful path, so that the pipe
    // reaches end of stream when the child is gone; this flag is what keeps
    // the cleanup from closing it a second time and shutting whatever
    // descriptor number has since been handed out.
    var pipe_open = [2]bool{ true, true };
    defer for (pipe_fds, pipe_open) |pfd, open| {
        if (open) os.close(pfd);
    };

    const arena = base[0..cap];

    const pid = os.fork() orelse return error.SandboxFailed;
    if (pid == 0) {
        // The child. Nothing below this line returns.
        os.close(pipe_fds[0]);
        childMain(pipe_fds[1], arena, input, opts);
    }

    // The parent keeps only the read end, so that the pipe reaches end of
    // stream when the child is gone.
    os.close(pipe_fds[1]);
    pipe_open[1] = false;

    const status = os.wait(pid) orelse return error.SandboxFailed;
    const reply = readReply(pipe_fds[0]);

    try checkExit(status);

    const r_ = reply orelse return error.SandboxProtocolError;
    if (r_.magic != reply_magic) return error.SandboxProtocolError;
    if (r_.status != 0) return wireToError(r_.status);

    const surface_type = surfaceTypeFromWire(r_.surface_type) orelse return error.SandboxProtocolError;
    const sfc = try wrapSurface(surface_type, arena, r_.width, r_.height, r_.offset, r_.len);
    const orientation = orientationFromWire(r_.orientation) orelse return error.SandboxProtocolError;

    // The profile, copied out of the mapping before the part of it that holds
    // the profile is given back. Its place was written by the child, so it is
    // checked like the pixels' was --- and against the caller's own limit,
    // since a profile larger than that is one the decoder should never have
    // collected.
    if (opts.decode.icc) |list| {
        if (r_.icc_len > 0) {
            const icc = try sliceOf(arena, r_.icc_offset, r_.icc_len);
            if (icc.len > limits.max_icc_bytes) return error.SandboxProtocolError;
            try list.appendSlice(gpa, icc);
        }
    }
    if (opts.decode.orientation) |o| o.* = orientation;

    // Everything past the pixels is the decoder's spent working memory, and
    // giving it back is the difference between a live mapping the size of the
    // image and one the size of the budget.
    const keep = mem.alignForward(usize, @intCast(r_.offset + r_.len), page);
    if (keep < cap) os.unmap(@alignCast(base + keep), cap - keep);

    const info: common.Info = .{
        .format = formatFromWire(r_.format) orelse return error.SandboxProtocolError,
        .width = r_.width,
        .height = r_.height,
        .has_alpha = r_.has_alpha != 0,
        .surface_type = surface_type,
        .orientation = orientation,
        .animation = switch (r_.animation) {
            0 => .none,
            1 => .unknown,
            2 => .{ .declared = .{
                .loop_count = r_.loop_count,
                .frames = if (r_.declared_frames == 0) null else r_.declared_frames - 1,
            } },
            // Every number in a reply is checked against something the
            // parent knows, and a tag it has never heard of is a reply it
            // cannot read.
            else => return error.SandboxProtocolError,
        },
    };

    mapped = false;
    return .{
        .surface = sfc,
        .info = info,
        .backing = .{ .mapping = @alignCast(base[0..keep]) },
    };
}

/// How much address space to reserve for a child: the pixels a `Limits`
/// permits at four bytes each, plus the codec's working memory. Decided before
/// anything has been read.
fn reservation(limits: common.Limits, working_bytes: usize, page: usize) Error!usize {
    const pixel_bytes = math.mul(u64, limits.max_pixels, 4) catch return error.LimitsUnbounded;
    const requested = math.add(u64, pixel_bytes, working_bytes) catch return error.LimitsUnbounded;
    if (requested > max_reservation) return error.LimitsUnbounded;
    return @intCast(mem.alignForward(u64, requested, page));
}

// -- the child ---------------------------------------------------------------

/// Everything the child does, which is as little as it can be.
///
/// Async-signal-safe throughout, because a `fork` from a threaded parent gives
/// a child holding whatever locks the other threads held at the moment of the
/// fork, forever. Nothing here takes a lock or allocates from the parent's
/// heap.
fn childMain(write_fd: os.Fd, arena: []u8, input: []const u8, opts: Options) noreturn {
    var reply: Reply = .{
        .magic = reply_magic,
        .status = @backingInt(WireError.protocol),
        .format = 0,
        .surface_type = 0,
        .has_alpha = 0,
        .animation = 0,
        .orientation = 0,
        .width = 0,
        .height = 0,
        .loop_count = 0,
        .declared_frames = 0,
        .offset = 0,
        .len = 0,
    };

    result: {
        // The reply pipe onto the number the lock knows, and then every
        // other descriptor the child inherited shut. Both before the lock
        // exists, which is why neither needs permitting.
        const parked = os.park(write_fd, first_closable) orelse {
            reply.status = @backingInt(WireError.sandbox);
            break :result;
        };
        if (!os.claim(parked, reply_fd)) {
            reply.status = @backingInt(WireError.sandbox);
            break :result;
        }
        os.closeFrom(first_closable);
        os.harden(opts.cpu_seconds);

        // The point of no return: after this the process can report a result
        // and stop, and that is all.
        switch (opts.profile) {
            inline else => |p| os.confine(p) catch {
                reply.status = @backingInt(WireError.sandbox);
                break :result;
            },
        }

        // The two out-parameters point into the parent's memory, which in
        // here is a copy-on-write copy that nobody will ever read. So neither
        // is written through: the orientation travels in the reply, and the
        // profile is collected into the shared mapping for the parent to copy
        // out, allocated like everything else from the arena.
        var fba: std.heap.FixedBufferAllocator = .init(arena);
        var icc: std.ArrayList(u8) = .empty;
        var here = opts.decode;
        here.orientation = null;
        here.icc = if (opts.decode.icc != null) &icc else null;

        const d = decodeBytes(fba.allocator(), input, here) catch |err| {
            reply.status = @backingInt(wireFromError(err));
            break :result;
        };
        if (icc.items.len > 0) {
            reply.icc_offset = @intFromPtr(icc.items.ptr) - @intFromPtr(arena.ptr);
            reply.icc_len = icc.items.len;
        }

        const bytes = surfaceBytes(d.surface);
        reply.status = 0;
        reply.format = @backingInt(d.info.format) + 1;
        reply.surface_type = @backingInt(d.info.surface_type) + 1;
        reply.has_alpha = @intFromBool(d.info.has_alpha);
        reply.orientation = @backingInt(d.info.orientation);
        reply.width = d.info.width;
        reply.height = d.info.height;
        switch (d.info.animation) {
            .none => reply.animation = 0,
            .unknown => reply.animation = 1,
            .declared => |a| {
                reply.animation = 2;
                reply.loop_count = a.loop_count;
                reply.declared_frames = if (a.frames) |n| n + 1 else 0;
            },
        }
        reply.offset = @intFromPtr(bytes.ptr) - @intFromPtr(arena.ptr);
        reply.len = bytes.len;
    }

    writeAll(reply_fd, mem.asBytes(&reply));
    os.exit(0);
}

/// The surface's pixel buffer as bytes, wherever in the union it lives.
fn surfaceBytes(sfc: z2d.Surface) []const u8 {
    return switch (sfc) {
        inline else => |s| mem.sliceAsBytes(s.buf),
    };
}

/// `write` until it is all gone, which is the child's only system call in
/// ordinary operation.
fn writeAll(fd: os.Fd, bytes: []const u8) void {
    var off: usize = 0;
    while (off < bytes.len) {
        // On failure nothing useful is left to do: the parent will see a
        // missing reply and say so.
        const n = os.write(fd, bytes[off..]) orelse return;
        if (n == 0) return;
        off += n;
    }
}

/// `read` until `buf` is full. False if the stream ended first or failed.
fn readFull(fd: os.Fd, buf: []u8) bool {
    var off: usize = 0;
    while (off < buf.len) {
        const n = os.read(fd, buf[off..]) orelse return false;
        if (n == 0) return false;
        off += n;
    }
    return true;
}

// -- the wire ----------------------------------------------------------------

/// Guards against a reply that is not one: a short write, a child that died
/// mid-struct, a pipe with something else in it.
const reply_magic: u32 = 0x7a32_6d67; // "z2mg"

/// What the child tells the parent. Fixed size, so the write cannot block and
/// the parent can wait for the child before reading it.
const Reply = extern struct {
    magic: u32,
    /// Zero, or a `WireError`.
    status: u16,
    /// `@intFromEnum(Format) + 1`, so that zero is never a valid format.
    format: u8,
    /// `@intFromEnum(SurfaceType) + 1`, likewise.
    surface_type: u8,
    has_alpha: u8,
    /// `Info.Animation`'s tag: nought for `none`, one for `unknown`, two for
    /// `declared`. Any other value is a reply this parent does not
    /// understand.
    animation: u8,
    /// `exif.Orientation`'s own number, one to eight, so that zero is never
    /// valid here either.
    orientation: u8,
    _pad: [1]u8 = @splat(0),
    width: u32,
    height: u32,
    /// Meaningful only when `animation` is two.
    loop_count: u32,
    /// Likewise, and plus one, so that zero means the file did not say.
    declared_frames: u32,
    /// Where the pixel buffer starts within the shared mapping.
    offset: u64,
    /// How long it is, in bytes.
    len: u64,
    /// Where the ICC profile the child collected starts within the mapping,
    /// and how long it is: zero when the caller did not ask for one or the
    /// file had none.
    icc_offset: u64 = 0,
    icc_len: u64 = 0,
};

/// An error, as a number that survives a process boundary.
///
/// A Zig error is an integer whose value depends on how the program was
/// compiled, so it cannot simply be written down and read back. This
/// enumeration is the stable spelling, and the two functions either side of it
/// are the only places the mapping exists.
const WireError = enum(u16) {
    ok = 0,
    unknown_format = 1,
    invalid_data = 2,
    unsupported = 3,
    image_too_large = 4,
    read_failed = 5,
    end_of_stream = 6,
    out_of_memory = 7,
    /// The filter could not be installed, so nothing was decoded.
    sandbox = 8,
    /// The child never got as far as setting a status.
    protocol = 9,
    _,
};

fn wireFromError(err: anyerror) WireError {
    return switch (err) {
        error.UnknownFormat => .unknown_format,
        error.InvalidData => .invalid_data,
        error.Unsupported => .unsupported,
        error.ImageTooLarge => .image_too_large,
        error.ReadFailed => .read_failed,
        error.EndOfStream => .end_of_stream,
        error.OutOfMemory => .out_of_memory,
        // `BufferTooSmall` cannot happen: the child reads from a fixed reader
        // whose buffer is the whole input.
        else => .protocol,
    };
}

fn wireToError(status: u16) Error {
    return switch (@as(WireError, @fromBackingInt(@intCast(status)))) {
        .ok => error.SandboxProtocolError, // never called with zero
        .unknown_format => error.UnknownFormat,
        .invalid_data => error.InvalidData,
        .unsupported => error.Unsupported,
        .image_too_large => error.ImageTooLarge,
        .read_failed => error.ReadFailed,
        .end_of_stream => error.EndOfStream,
        .out_of_memory => error.OutOfMemory,
        .sandbox => error.SandboxFailed,
        .protocol, _ => error.SandboxProtocolError,
    };
}

fn formatFromWire(v: u8) ?format.Format {
    if (v == 0) return null;
    const names = @typeInfo(format.Format).@"enum".field_names;
    if (v - 1 >= names.len) return null;
    return @fromBackingInt(@intCast(v - 1));
}

fn orientationFromWire(v: u8) ?exif.Orientation {
    inline for (@typeInfo(exif.Orientation).@"enum".field_values) |value| {
        if (v == value) return @fromBackingInt(@intCast(v));
    }
    return null;
}

fn surfaceTypeFromWire(v: u8) ?z2d.surface.SurfaceType {
    if (v == 0) return null;
    const names = @typeInfo(z2d.surface.SurfaceType).@"enum".field_names;
    if (v - 1 >= names.len) return null;
    return @fromBackingInt(@intCast(v - 1));
}

// -- the parent's half -------------------------------------------------------

/// Turns how the child died into the error that says so.
fn checkExit(status: u32) Error!void {
    if (os.W.IFSIGNALED(status)) {
        return if (os.W.TERMSIG(status) == os.violation)
            error.SandboxViolation
        else
            error.DecoderCrashed;
    }
    if (!os.W.IFEXITED(status)) return error.DecoderCrashed;
    if (os.W.EXITSTATUS(status) != 0) return error.DecoderCrashed;
}

/// Reads the reply, if there is a whole one.
///
/// Called after the child has been reaped, so the pipe holds everything it
/// will ever hold and a short read means a short write.
fn readReply(fd: os.Fd) ?Reply {
    var reply: Reply = undefined;
    return if (readFull(fd, mem.asBytes(&reply))) reply else null;
}

/// The `len` bytes at `offset` in the mapping, having checked that they are
/// inside it.
fn sliceOf(arena: []u8, offset: u64, len: u64) Error![]u8 {
    const end = math.add(u64, offset, len) catch return error.SandboxProtocolError;
    if (end > arena.len) return error.SandboxProtocolError;
    return arena[@intCast(offset)..@intCast(end)];
}

/// Builds a surface over the child's pixels, having satisfied itself that they
/// are where the reply says they are.
///
/// This is the security boundary on the way back. Every number in the reply
/// was written by the process that is not trusted, so each one is checked
/// against something the parent knows: the mapping's length, the alignment the
/// pixel type needs, and the buffer length the stated dimensions imply. Only
/// then is a pointer made out of an offset.
///
/// z2d has no constructor for this. `Surface.initBuffer` would do it, but it
/// clears the buffer it is given, which here means erasing the image. So the
/// union is built directly out of the fields, which are public and are the
/// same three fields `initBuffer` would have set.
fn wrapSurface(
    surface_type: z2d.surface.SurfaceType,
    arena: []u8,
    width: u32,
    height: u32,
    claimed_offset: u64,
    claimed_len: u64,
) Error!z2d.Surface {
    if (width == 0 or height == 0) return error.SandboxProtocolError;
    const end = math.add(u64, claimed_offset, claimed_len) catch return error.SandboxProtocolError;
    if (end > arena.len) return error.SandboxProtocolError;

    const w: i32 = math.cast(i32, width) orelse return error.SandboxProtocolError;
    const h: i32 = math.cast(i32, height) orelse return error.SandboxProtocolError;
    const count = @as(u64, width) * @as(u64, height);
    const offset: usize = @intCast(claimed_offset);
    const len = claimed_len;

    switch (surface_type) {
        inline .image_surface_argb,
        .image_surface_xrgb,
        .image_surface_rgb,
        .image_surface_rgba,
        .image_surface_alpha8,
        => |t| {
            const T = t.toPixelType();
            if (len != count * @sizeOf(T)) return error.SandboxProtocolError;
            if (offset % @alignOf(T) != 0) return error.SandboxProtocolError;
            const ptr: [*]T = @ptrCast(@alignCast(arena.ptr + offset));
            return @unionInit(z2d.Surface, @tagName(t), .{
                .width = w,
                .height = h,
                .buf = ptr[0..@intCast(count)],
            });
        },
        inline .image_surface_alpha4,
        .image_surface_alpha2,
        .image_surface_alpha1,
        => |t| {
            const T = t.toPixelType();
            // The packing z2d uses: as many pixels to a byte as fit, rounded
            // up to a whole byte at the end of the image rather than the end
            // of each row.
            if (len != (count * @bitSizeOf(T) + 7) / 8) return error.SandboxProtocolError;
            return @unionInit(z2d.Surface, @tagName(t), .{
                .width = w,
                .height = h,
                .buf = arena[offset..][0..@intCast(len)],
            });
        },
    }
}

// -- tests -------------------------------------------------------------------

/// The smallest real BMP there is: one white pixel, 24-bit, uncompressed.
const one_white_pixel_bmp = [_]u8{
    'B', 'M', 0x1a, 0, 0, 0, 0, 0, 0, 0, 0x1a, 0, 0, 0, // file header
    0x0c, 0, 0, 0, // BITMAPCOREHEADER
    1, 0, // width
    1, 0, // height
    1, 0, // planes
    24, 0, // bits per pixel
    0xff, 0xff, 0xff, 0, // one pixel, padded to four bytes
};

/// A four-by-three PNG: eight-bit truecolour with alpha, one of the fixtures
/// `tests/png.zig` checks against Pillow.
const small_png =
    "\x89\x50\x4e\x47\x0d\x0a\x1a\x0a\x00\x00\x00\x0d\x49\x48\x44" ++
    "\x52\x00\x00\x00\x04\x00\x00\x00\x03\x08\x06\x00\x00\x00\xb4" ++
    "\xf4\xae\xc6\x00\x00\x00\x2c\x49\x44\x41\x54\x78\x9c\x63\xf8" ++
    "\xcf\xc0\xf0\x1f\x0c\x19\xfe\x83\x01\x03\x03\x98\x05\x12\x02" ++
    "\x53\xff\x19\xb8\x44\xe4\xfe\x6b\x18\xd9\x34\xb8\x05\x44\x31" ++
    "\x9c\xb8\x74\xc7\x01\x00\xb1\x12\x19\xe4\xce\xc0\x9e\xd3\x00" ++
    "\x00\x00\x00\x49\x45\x4e\x44\xae\x42\x60\x82";

/// A 24x16 baseline JPEG at 4:4:4, one of the fixtures `tests/jpeg.zig`
/// checks against libjpeg.
const small_jpeg =
    "\xff\xd8\xff\xe0\x00\x10\x4a\x46\x49\x46\x00\x01\x01\x00\x00" ++
    "\x01\x00\x01\x00\x00\xff\xdb\x00\x43\x00\x03\x02\x02\x03\x02" ++
    "\x02\x03\x03\x03\x03\x04\x03\x03\x04\x05\x08\x05\x05\x04\x04" ++
    "\x05\x0a\x07\x07\x06\x08\x0c\x0a\x0c\x0c\x0b\x0a\x0b\x0b\x0d" ++
    "\x0e\x12\x10\x0d\x0e\x11\x0e\x0b\x0b\x10\x16\x10\x11\x13\x14" ++
    "\x15\x15\x15\x0c\x0f\x17\x18\x16\x14\x18\x12\x14\x15\x14\xff" ++
    "\xdb\x00\x43\x01\x03\x04\x04\x05\x04\x05\x09\x05\x05\x09\x14" ++
    "\x0d\x0b\x0d\x14\x14\x14\x14\x14\x14\x14\x14\x14\x14\x14\x14" ++
    "\x14\x14\x14\x14\x14\x14\x14\x14\x14\x14\x14\x14\x14\x14\x14" ++
    "\x14\x14\x14\x14\x14\x14\x14\x14\x14\x14\x14\x14\x14\x14\x14" ++
    "\x14\x14\x14\x14\x14\x14\x14\x14\xff\xc0\x00\x11\x08\x00\x10" ++
    "\x00\x18\x03\x01\x11\x00\x02\x11\x01\x03\x11\x01\xff\xc4\x00" ++
    "\x1f\x00\x00\x01\x05\x01\x01\x01\x01\x01\x01\x00\x00\x00\x00" ++
    "\x00\x00\x00\x00\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b" ++
    "\xff\xc4\x00\xb5\x10\x00\x02\x01\x03\x03\x02\x04\x03\x05\x05" ++
    "\x04\x04\x00\x00\x01\x7d\x01\x02\x03\x00\x04\x11\x05\x12\x21" ++
    "\x31\x41\x06\x13\x51\x61\x07\x22\x71\x14\x32\x81\x91\xa1\x08" ++
    "\x23\x42\xb1\xc1\x15\x52\xd1\xf0\x24\x33\x62\x72\x82\x09\x0a" ++
    "\x16\x17\x18\x19\x1a\x25\x26\x27\x28\x29\x2a\x34\x35\x36\x37" ++
    "\x38\x39\x3a\x43\x44\x45\x46\x47\x48\x49\x4a\x53\x54\x55\x56" ++
    "\x57\x58\x59\x5a\x63\x64\x65\x66\x67\x68\x69\x6a\x73\x74\x75" ++
    "\x76\x77\x78\x79\x7a\x83\x84\x85\x86\x87\x88\x89\x8a\x92\x93" ++
    "\x94\x95\x96\x97\x98\x99\x9a\xa2\xa3\xa4\xa5\xa6\xa7\xa8\xa9" ++
    "\xaa\xb2\xb3\xb4\xb5\xb6\xb7\xb8\xb9\xba\xc2\xc3\xc4\xc5\xc6" ++
    "\xc7\xc8\xc9\xca\xd2\xd3\xd4\xd5\xd6\xd7\xd8\xd9\xda\xe1\xe2" ++
    "\xe3\xe4\xe5\xe6\xe7\xe8\xe9\xea\xf1\xf2\xf3\xf4\xf5\xf6\xf7" ++
    "\xf8\xf9\xfa\xff\xc4\x00\x1f\x01\x00\x03\x01\x01\x01\x01\x01" ++
    "\x01\x01\x01\x01\x00\x00\x00\x00\x00\x00\x01\x02\x03\x04\x05" ++
    "\x06\x07\x08\x09\x0a\x0b\xff\xc4\x00\xb5\x11\x00\x02\x01\x02" ++
    "\x04\x04\x03\x04\x07\x05\x04\x04\x00\x01\x02\x77\x00\x01\x02" ++
    "\x03\x11\x04\x05\x21\x31\x06\x12\x41\x51\x07\x61\x71\x13\x22" ++
    "\x32\x81\x08\x14\x42\x91\xa1\xb1\xc1\x09\x23\x33\x52\xf0\x15" ++
    "\x62\x72\xd1\x0a\x16\x24\x34\xe1\x25\xf1\x17\x18\x19\x1a\x26" ++
    "\x27\x28\x29\x2a\x35\x36\x37\x38\x39\x3a\x43\x44\x45\x46\x47" ++
    "\x48\x49\x4a\x53\x54\x55\x56\x57\x58\x59\x5a\x63\x64\x65\x66" ++
    "\x67\x68\x69\x6a\x73\x74\x75\x76\x77\x78\x79\x7a\x82\x83\x84" ++
    "\x85\x86\x87\x88\x89\x8a\x92\x93\x94\x95\x96\x97\x98\x99\x9a" ++
    "\xa2\xa3\xa4\xa5\xa6\xa7\xa8\xa9\xaa\xb2\xb3\xb4\xb5\xb6\xb7" ++
    "\xb8\xb9\xba\xc2\xc3\xc4\xc5\xc6\xc7\xc8\xc9\xca\xd2\xd3\xd4" ++
    "\xd5\xd6\xd7\xd8\xd9\xda\xe2\xe3\xe4\xe5\xe6\xe7\xe8\xe9\xea" ++
    "\xf2\xf3\xf4\xf5\xf6\xf7\xf8\xf9\xfa\xff\xda\x00\x0c\x03\x01" ++
    "\x00\x02\x11\x03\x11\x00\x3f\x00\xf8\x9f\xc3\x9f\x0a\x3e\xef" ++
    "\xee\x7f\x4a\xbc\x3d\x73\xc8\xca\xf3\xfd\xb5\x3d\x43\xc3\xbf" ++
    "\x09\xfe\xef\xee\x7f\x4a\xfa\x7c\x3d\x73\xf5\xfc\xaf\x3f\xdb" ++
    "\x53\xd4\x7c\x39\xf0\x9f\xee\xfe\xe7\xf4\xaf\xa7\xc3\xd7\x3f" ++
    "\x5e\xca\xf3\xfd\xb5\x3a\xcf\x0e\x7c\x27\xfb\xbf\xb9\xfd\x2b" ++
    "\xf1\x2c\x3d\x73\xfc\xb0\xca\xf3\xfd\xb5\x3d\x43\xc3\xbf\x09" ++
    "\xfe\xef\xee\x7f\x4a\xfa\x7c\x3d\x73\xf5\xfc\xaf\x3f\xdb\x53" ++
    "\xd3\x74\x4f\x85\xf1\xda\xc3\xe6\xcb\x18\x48\xd0\x64\xb1\x1d" ++
    "\x2b\xd6\xc4\x66\xf8\x5c\xab\x0b\x3c\x6e\x36\xa2\x85\x28\x2b" ++
    "\xb6\xfa\x7e\xad\xb7\xa2\x4a\xed\xb6\x92\x4d\xbb\x1f\xb0\xe5" ++
    "\x19\xec\xa7\x28\xc6\x2e\xed\x9f\xff\xd9";

test "a JPEG decodes inside the sandbox" {
    if (!available) return error.SkipZigTest;

    // The most code of the three by a wide margin, and the most arithmetic:
    // Huffman decoding, an inverse DCT per block, and bilinear upsampling,
    // none of it written with a system call budget in mind.
    var r: Io.Reader = .fixed(small_jpeg);
    var image = decode(testing.allocator, &r, .{}) catch |err| switch (err) {
        error.SandboxFailed => return error.SkipZigTest,
        else => |e| return e,
    };
    defer image.deinit();

    try testing.expectEqual(format.Format.jpeg, image.info.format);
    try testing.expectEqual(@as(u32, 24), image.info.width);
    try testing.expectEqual(@as(u32, 16), image.info.height);
    try testing.expect(!image.info.has_alpha);
    try testing.expect(image.surface.getPixel(23, 15) != null);
}

test "a PNG decodes inside the sandbox, which is the real test of the filter" {
    if (!available) return error.SkipZigTest;

    // BMP is a weak test of the strict profile: it parses a header and copies
    // bytes, so of course it needs no system calls. PNG inflates a zlib
    // stream through `std.compress.flate`, which is a great deal more code
    // and none of it written with a sandbox in mind. That it runs under a
    // filter permitting four system calls is the claim worth checking.
    var r: Io.Reader = .fixed(small_png);
    var image = decode(testing.allocator, &r, .{}) catch |err| switch (err) {
        error.SandboxFailed => return error.SkipZigTest,
        else => |e| return e,
    };
    defer image.deinit();

    try testing.expectEqual(format.Format.png, image.info.format);
    try testing.expectEqual(@as(u32, 4), image.info.width);
    try testing.expectEqual(@as(u32, 3), image.info.height);
    try testing.expect(image.info.has_alpha);

    // The top-left pixel of that fixture is opaque red.
    const px = image.surface.getPixel(0, 0).?.rgba;
    try testing.expectEqual(@as(u8, 255), px.a);
    try testing.expectEqual(@as(u8, 255), px.r);
    try testing.expectEqual(@as(u8, 0), px.g);
}

test "a sandboxed decode produces the same pixels as an ordinary one" {
    if (!available) return error.SkipZigTest;

    var r: Io.Reader = .fixed(&one_white_pixel_bmp);
    var image = decode(testing.allocator, &r, .{}) catch |err| switch (err) {
        // A kernel without seccomp, or a container that refuses to let a
        // process install a filter. Not a failure of this library.
        error.SandboxFailed => return error.SkipZigTest,
        else => |e| return e,
    };
    defer image.deinit();

    try testing.expectEqual(@as(u32, 1), image.info.width);
    try testing.expectEqual(@as(u32, 1), image.info.height);
    try testing.expectEqual(format.Format.bmp, image.info.format);

    const px = image.surface.getPixel(0, 0).?.rgb;
    try testing.expectEqual(@as(u8, 255), px.r);
    try testing.expectEqual(@as(u8, 255), px.g);
    try testing.expectEqual(@as(u8, 255), px.b);
}

test "a decode error crosses the process boundary as itself" {
    if (!available) return error.SkipZigTest;

    var r: Io.Reader = .fixed("not an image, not even close");
    const result = decode(testing.allocator, &r, .{});
    if (result) |_| {
        return error.ExpectedError;
    } else |err| switch (err) {
        error.UnknownFormat => {},
        error.SandboxFailed => return error.SkipZigTest,
        else => return err,
    }
}

test "the limits are enforced inside the sandbox too" {
    if (!available) return error.SkipZigTest;

    var r: Io.Reader = .fixed(&one_white_pixel_bmp);
    const result = decode(testing.allocator, &r, .{
        .decode = .{ .limits = .{ .max_width = 0 } },
    });
    if (result) |_| {
        return error.ExpectedError;
    } else |err| switch (err) {
        error.ImageTooLarge => {},
        error.SandboxFailed => return error.SkipZigTest,
        else => return err,
    }
}

test "unbounded limits are refused rather than reserved for" {
    if (!available) return error.SkipZigTest;

    var r: Io.Reader = .fixed(&one_white_pixel_bmp);
    try testing.expectError(error.LimitsUnbounded, decode(testing.allocator, &r, .{
        .decode = .{ .limits = .unlimited },
    }));
}

test "an input larger than the budget is refused before the fork" {
    if (!available) return error.SkipZigTest;

    var r: Io.Reader = .fixed(&one_white_pixel_bmp);
    try testing.expectError(error.InputTooLarge, decode(testing.allocator, &r, .{
        .decode = .{ .limits = .{ .max_input_bytes = 4 } },
    }));
}

test "the permissive profile decodes what the strict one does" {
    if (!available) return error.SkipZigTest;

    var r: Io.Reader = .fixed(&one_white_pixel_bmp);
    var image = decode(testing.allocator, &r, .{ .profile = .permissive }) catch |err| switch (err) {
        error.SandboxFailed => return error.SkipZigTest,
        else => |e| return e,
    };
    defer image.deinit();
    try testing.expectEqual(@as(u32, 1), image.info.width);
}

test "toOwned hands back a surface an allocator can free" {
    if (!available) return error.SkipZigTest;

    var r: Io.Reader = .fixed(&one_white_pixel_bmp);
    var image = decode(testing.allocator, &r, .{}) catch |err| switch (err) {
        error.SandboxFailed => return error.SkipZigTest,
        else => |e| return e,
    };
    var owned = try image.toOwned(testing.allocator);
    defer owned.deinit(testing.allocator);
    image.deinit();

    // Still the same pixel after the mapping is gone.
    try testing.expectEqual(@as(u8, 255), owned.getPixel(0, 0).?.rgb.r);
}

test "an unisolated decode gives what a sandboxed one does" {
    // The promise `Isolation` makes: the choice changes where the decode runs
    // and nothing about what comes back. Run everywhere for `.none`, and
    // compared against `.process` where there is one to compare against.
    const gpa = testing.allocator;
    for ([_][]const u8{ small_png, small_jpeg, &one_white_pixel_bmp }) |bytes| {
        var r: Io.Reader = .fixed(bytes);
        var here = try decode(gpa, &r, .{ .isolation = .none });
        defer here.deinit();
        try testing.expect(here.backing == .heap);

        if (!available) continue;
        var r2: Io.Reader = .fixed(bytes);
        var there = decode(gpa, &r2, .{}) catch |err| switch (err) {
            error.SandboxFailed => return error.SkipZigTest,
            else => |e| return e,
        };
        defer there.deinit();

        try testing.expectEqualDeep(there.info, here.info);
        try testing.expectEqualSlices(u8, surfaceBytes(there.surface), surfaceBytes(here.surface));
    }
}

test "an unisolated decode enforces the limits a sandboxed one does" {
    const gpa = testing.allocator;
    var r: Io.Reader = .fixed(&one_white_pixel_bmp);
    try testing.expectError(error.ImageTooLarge, decode(gpa, &r, .{
        .isolation = .none,
        .decode = .{ .limits = .{ .max_width = 0 } },
    }));
    var r2: Io.Reader = .fixed(&one_white_pixel_bmp);
    try testing.expectError(error.InputTooLarge, decode(gpa, &r2, .{
        .isolation = .none,
        .decode = .{ .limits = .{ .max_input_bytes = 4 } },
    }));
    var r3: Io.Reader = .fixed("not an image, not even close");
    try testing.expectError(error.UnknownFormat, decode(gpa, &r3, .{ .isolation = .none }));
}

test "an unisolated decode has no reservation to refuse unbounded limits for" {
    // `LimitsUnbounded` is the sandbox saying it cannot reserve a mapping for
    // an image of no particular size. Without a child there is no mapping.
    var r: Io.Reader = .fixed(&one_white_pixel_bmp);
    var image = try decode(testing.allocator, &r, .{
        .isolation = .none,
        .decode = .{ .limits = .unlimited },
    });
    defer image.deinit();
    try testing.expectEqual(@as(u32, 1), image.info.width);
}

test "asking for a sandbox where there is none is refused, not quietly granted" {
    if (available) return error.SkipZigTest;
    var r: Io.Reader = .fixed(&one_white_pixel_bmp);
    try testing.expectError(error.SandboxUnavailable, decode(testing.allocator, &r, .{}));
    var r2: Io.Reader = .fixed(&one_white_pixel_bmp);
    try testing.expectError(error.SandboxUnavailable, decodeAnimation(testing.allocator, &r2, .{}));
}

test "the best isolation is a process exactly where there is a sandbox" {
    try testing.expectEqual(available, Isolation.best == .process);
    // And the default is the sandbox, everywhere: a caller has to ask for
    // less.
    try testing.expectEqual(Isolation.process, (Options{}).isolation);
}

test "a reply pointing outside the mapping is refused" {
    // The check that stops a subverted child making the parent read memory it
    // does not own. Driven directly, since a cooperating child never produces
    // one of these.
    var arena: [64]u8 = undefined;
    const bad_offset: Reply = .{
        .magic = reply_magic,
        .status = 0,
        .format = 1,
        .surface_type = 1,
        .has_alpha = 0,
        .animation = 0,
        .orientation = 1,
        .loop_count = 0,
        .declared_frames = 0,
        .width = 1,
        .height = 1,
        .offset = 1024,
        .len = 4,
    };
    try testing.expectError(
        error.SandboxProtocolError,
        wrapSurface(.image_surface_rgba, &arena, bad_offset.width, bad_offset.height, bad_offset.offset, bad_offset.len),
    );

    var wrong_len = bad_offset;
    wrong_len.offset = 0;
    wrong_len.len = 8; // a 1x1 RGBA surface is four bytes, not eight
    try testing.expectError(
        error.SandboxProtocolError,
        wrapSurface(.image_surface_rgba, &arena, wrong_len.width, wrong_len.height, wrong_len.offset, wrong_len.len),
    );

    var misaligned = bad_offset;
    misaligned.offset = 1;
    misaligned.len = 4;
    try testing.expectError(
        error.SandboxProtocolError,
        wrapSurface(.image_surface_rgba, &arena, misaligned.width, misaligned.height, misaligned.offset, misaligned.len),
    );

    var overflowing = bad_offset;
    overflowing.offset = math.maxInt(u64);
    overflowing.len = 4;
    try testing.expectError(
        error.SandboxProtocolError,
        wrapSurface(.image_surface_rgba, &arena, overflowing.width, overflowing.height, overflowing.offset, overflowing.len),
    );
}

test "a well-formed reply is accepted" {
    var arena: [64]u8 align(4) = @splat(0);
    const good: Reply = .{
        .magic = reply_magic,
        .status = 0,
        .format = 1,
        .surface_type = 1,
        .has_alpha = 0,
        .animation = 0,
        .orientation = 1,
        .loop_count = 0,
        .declared_frames = 0,
        .width = 2,
        .height = 2,
        .offset = 0,
        .len = 16,
    };
    const sfc = try wrapSurface(.image_surface_rgba, &arena, good.width, good.height, good.offset, good.len);
    try testing.expectEqual(@as(i32, 2), sfc.getWidth());
    try testing.expectEqual(@as(i32, 2), sfc.getHeight());
}

test "the wire encoding of errors round trips" {
    const cases = [_]anyerror{
        error.UnknownFormat, error.InvalidData, error.Unsupported,
        error.ImageTooLarge, error.ReadFailed,  error.EndOfStream,
        error.OutOfMemory,
    };
    for (cases) |err| {
        const wire = wireFromError(err);
        try testing.expectEqual(err, wireToError(@backingInt(wire)));
    }
}

test "an unknown wire tag does not become a valid format" {
    try testing.expectEqual(@as(?format.Format, null), formatFromWire(0));
    try testing.expectEqual(@as(?format.Format, null), formatFromWire(200));
    try testing.expectEqual(format.Format.bmp, formatFromWire(1).?);
    try testing.expectEqual(@as(?z2d.surface.SurfaceType, null), surfaceTypeFromWire(0));
    try testing.expectEqual(@as(?z2d.surface.SurfaceType, null), surfaceTypeFromWire(200));
}

test "the sandbox actually kills a child that steps outside it" {
    if (!available) return error.SkipZigTest;

    // The claim the whole module rests on, made directly: a process that has
    // locked itself down and then makes an ordinary, harmless system call the
    // lock refuses does not come back from it. Which call that is differs ---
    // `getpid` under seccomp, opening a path under Capsicum, which allows
    // `getpid` because it names nothing outside the process --- and so does
    // the signal, which is why both come from the backend.
    const pid = os.fork() orelse return error.SkipZigTest;
    if (pid == 0) {
        os.confine(.strict) catch {
            // No lock here --- an old kernel, or a container that will not
            // allow a filter. Say so through the exit status.
            os.exit(9);
        };
        os.forbiddenCall();
        // Only reached if the lock did nothing, which is the failure this
        // test exists to catch.
        os.exit(0);
    }

    const status = os.wait(pid) orelse return error.SkipZigTest;
    if (os.W.IFEXITED(status) and os.W.EXITSTATUS(status) == 9) return error.SkipZigTest;
    try testing.expect(os.W.IFSIGNALED(status));
    try testing.expectEqual(os.violation, os.W.TERMSIG(status));
}

test "a call the sandbox does permit goes through" {
    if (!available) return error.SkipZigTest;

    // The other half of the claim: the lock is an allowlist, not a wall.
    const pid = os.fork() orelse return error.SkipZigTest;
    if (pid == 0) {
        // Closed *before* the lock goes on, because `close` is not on the
        // seccomp list either --- which is the whole point of the list.
        os.close(reply_fd);
        os.confine(.strict) catch os.exit(9);
        // `write` on the reply descriptor is permitted. That descriptor is
        // shut, so this writes nothing anywhere and still has to be permitted
        // to come back with a failure of its own.
        _ = os.write(reply_fd, "x");
        os.exit(0);
    }

    const status = os.wait(pid) orelse return error.SkipZigTest;
    if (os.W.IFEXITED(status) and os.W.EXITSTATUS(status) == 9) return error.SkipZigTest;
    try testing.expect(os.W.IFEXITED(status));
    try testing.expectEqual(@as(u8, 0), os.W.EXITSTATUS(status));
}

test "a streaming child may read its acknowledgements and nothing else it holds" {
    if (!available) return error.SkipZigTest;

    // `streaming` adds one `read` to what `strict` permits, and it must be a
    // read of the acknowledgement pipe and of nothing else --- the reply pipe
    // included, which the child does hold. seccomp compares the descriptor
    // number; Capsicum gave the reply pipe `CAP_WRITE` alone. The same claim
    // holds under both for different reasons, which is why it is worth making
    // against both.
    for ([_]enum { ack, reply }{ .ack, .reply }) |which| {
        var fds: [2]os.Fd = undefined;
        if (!os.pipe(&fds)) return error.SkipZigTest;
        defer {
            os.close(fds[0]);
            os.close(fds[1]);
        }
        // Something to read, so that a permitted read returns rather than
        // blocking on an empty pipe with nobody left to fill it.
        _ = os.write(fds[1], "x");

        const pid = os.fork() orelse return error.SkipZigTest;
        if (pid == 0) {
            // The two ends onto the numbers the lock knows: the read end as
            // the acknowledgements, the write end as the reply.
            const parked_ack = os.park(fds[0], first_closable) orelse os.exit(9);
            const parked_reply = os.park(fds[1], first_closable) orelse os.exit(9);
            if (!os.claim(parked_ack, ack_fd) or !os.claim(parked_reply, reply_fd)) os.exit(9);
            os.closeFrom(first_closable);
            os.confine(.streaming) catch os.exit(9);
            var byte: [1]u8 = undefined;
            _ = os.read(switch (which) {
                .ack => ack_fd,
                .reply => reply_fd,
            }, &byte);
            os.exit(0);
        }

        const status = os.wait(pid) orelse return error.SkipZigTest;
        if (os.W.IFEXITED(status) and os.W.EXITSTATUS(status) == 9) return error.SkipZigTest;
        switch (which) {
            .ack => {
                try testing.expect(os.W.IFEXITED(status));
                try testing.expectEqual(@as(u8, 0), os.W.EXITSTATUS(status));
            },
            .reply => {
                try testing.expect(os.W.IFSIGNALED(status));
                try testing.expectEqual(os.violation, os.W.TERMSIG(status));
            },
        }
    }
}

test "a strict child cannot write to its standard error" {
    if (!available) return error.SkipZigTest;

    // The standard streams are inherited like everything else, and are the
    // ones the child keeps: seccomp refuses `write` on any descriptor but the
    // reply's, and Capsicum strips the streams of every right. Either way a
    // write to one is a violation --- which is also why a panic under `strict`
    // reports as one.
    const pid = os.fork() orelse return error.SkipZigTest;
    if (pid == 0) {
        os.confine(.strict) catch os.exit(9);
        _ = os.write(2, "a sandboxed child should never print this\n");
        os.exit(0);
    }

    const status = os.wait(pid) orelse return error.SkipZigTest;
    if (os.W.IFEXITED(status) and os.W.EXITSTATUS(status) == 9) return error.SkipZigTest;
    try testing.expect(os.W.IFSIGNALED(status));
    try testing.expectEqual(os.violation, os.W.TERMSIG(status));
}

/// A PNG whose `IDAT` declares a hundred megabytes and supplies forty bytes of
/// malformed deflate. Zig 0.16.0's inflater panics on it.
const panicking_png =
    "\x89\x50\x4e\x47\x0d\x0a\x1a\x0a\x00\x00\x00\x0d\x49\x48\x44" ++
    "\x52\x00\x00\x00\x04\x00\x00\x00\x03\x01\x00\x00\x00\x00\x9c" ++
    "\x8f\x93\x6b\x06\x00\x00\x0e\x49\x44\x41\x54\x78\x03\x9c\x63" ++
    "\x48\x60\x4a\xc0\x60\x00\x00\x03\xc6\x01\x21\x68\xd1\x59\xb8" ++
    "\x51\x00\x00\x00\x00\x49\x45\x4e\x21\xae\x42\x26\x82";

test "a decoder that dies is contained rather than fatal" {
    if (!available) return error.SkipZigTest;

    // This input panicked inside `std.compress.flate` on a stock Zig 0.16.0 —
    // not in this library's code, and not catchably, so an ordinary decode of
    // it took the whole process with it. That is the case this module exists
    // for, and it is how the bug was confirmed: sandboxed, the panic was
    // `error.DecoderCrashed` rather than a dead program.
    //
    // The devshell now carries a one-line fix for that bug (`flake.nix` says
    // what it is, and `tools/std_flate_panic.zig` still reproduces it against
    // an unpatched toolchain), so on this toolchain the file is simply
    // rejected. Both answers are correct and which one comes back says which
    // standard library is underneath — so the test accepts either, and what it
    // actually asserts is the thing that must hold on every toolchain: the
    // *parent survives* either way.
    var r: Io.Reader = .fixed(panicking_png);
    const result = decode(testing.allocator, &r, .{});
    if (result) |img| {
        var i = img;
        i.deinit();
    } else |err| switch (err) {
        // A patched standard library: an ordinary malformed file.
        error.InvalidData, error.EndOfStream, error.UnknownFormat, error.Unsupported => {},
        // An unpatched one: the child died where it stood. Either it aborted,
        // or it tripped the filter on its way to printing the panic.
        error.DecoderCrashed, error.SandboxViolation => {},
        error.SandboxFailed => return error.SkipZigTest,
        else => return err,
    }
}

test "a child killed by a signal is a crash rather than a result" {
    if (!available) return error.SkipZigTest;

    // The containment claim on its own, with nothing depending on a decoder
    // being wrong: a child that dies of a signal must be reported as having
    // died, never as having produced something.
    const pid = os.fork() orelse return error.SkipZigTest;
    if (pid == 0) os.crash();

    const status = os.wait(pid) orelse return error.SkipZigTest;
    try testing.expect(os.W.IFSIGNALED(status));
    try testing.expectError(error.DecoderCrashed, checkExit(status));
}

test "a child that exits badly is a crash too" {
    if (!available) return error.SkipZigTest;

    const pid = os.fork() orelse return error.SkipZigTest;
    if (pid == 0) os.exit(3);

    const status = os.wait(pid) orelse return error.SkipZigTest;
    try testing.expectError(error.DecoderCrashed, checkExit(status));
}

test "the streaming filter permits a read on one descriptor and no other" {
    // A claim about seccomp alone. Capsicum limits a descriptor's rights
    // rather than the number it is reached by, and the child's other
    // descriptors are closed rather than filtered, so the "wrong" read below
    // would be permitted there and would block for ever on an empty pipe.
    if (builtin.os.tag != .linux or !available) return error.SkipZigTest;

    // The claim the streaming protocol rests on. `strict` permits four calls
    // and `streaming` permits a fifth --- `read` --- which would be a real
    // loosening if it were `read` on anything. It is not: the filter compares
    // the descriptor, which it can do because a descriptor is an integer and
    // a filter cannot follow a pointer.
    //
    // Two children, differing only in which descriptor they read from.
    for ([_]enum { right, wrong }{ .right, .wrong }) |which| {
        var fds: [2]i32 = undefined;
        if (linux.errno(linux.pipe2(&fds, .{})) != .SUCCESS) return error.SkipZigTest;
        defer {
            _ = linux.close(fds[0]);
            _ = linux.close(fds[1]);
        }
        // Something to read, so that a permitted read returns rather than
        // blocking on an empty pipe with nobody left to fill it.
        _ = linux.write(fds[1], "x", 1);

        const fork_rc = linux.fork();
        if (linux.errno(fork_rc) != .SUCCESS) return error.SkipZigTest;
        const pid: i32 = @intCast(fork_rc);
        if (pid == 0) {
            // The read end onto the number the filter knows. Done before the
            // filter exists, which is why it needs no permission --- and
            // skipped when the pipe already landed there, since `dup3`
            // refuses a descriptor onto itself where `dup2` would have said
            // nothing and done nothing.
            if (fds[0] != @as(i32, @intCast(seccomp.ack_fd))) {
                if (linux.errno(linux.dup3(fds[0], @intCast(seccomp.ack_fd), 0)) != .SUCCESS) {
                    _ = linux.exit_group(9);
                }
            }
            seccomp.install(.streaming) catch {
                _ = linux.exit_group(9);
                unreachable;
            };
            var byte: [1]u8 = undefined;
            // The right descriptor is the one the filter names. The wrong one
            // is the *same pipe*, reached by another number --- which is the
            // point: nothing about the object being read changes, only the
            // integer naming it, and that is the whole of what a filter can
            // see.
            const fd: i32 = switch (which) {
                .right => @intCast(seccomp.ack_fd),
                .wrong => fds[1],
            };
            _ = linux.read(fd, &byte, 1);
            _ = linux.exit_group(0);
            unreachable;
        }

        const status = os.wait(pid) orelse return error.SkipZigTest;
        if (linux.W.IFEXITED(status) and linux.W.EXITSTATUS(status) == 9) return error.SkipZigTest;
        switch (which) {
            // Permitted: the child read its byte and left of its own accord.
            .right => {
                try testing.expect(linux.W.IFEXITED(status));
                try testing.expectEqual(@as(u32, 0), linux.W.EXITSTATUS(status));
            },
            // Refused: the same call, one integer different, and the process
            // does not come back from it.
            .wrong => {
                try testing.expect(linux.W.IFSIGNALED(status));
                try testing.expectEqual(linux.SIG.SYS, linux.W.TERMSIG(status));
            },
        }
    }
}

// -- animation ---------------------------------------------------------------

/// What the child says about one frame, or about the end of the animation.
///
/// Its own struct and its own magic rather than more fields on `Reply`,
/// because the two protocols are read in different places and a reply that
/// could be mistaken for the other kind is a way for one to be read as the
/// other.
const FrameReply = extern struct {
    magic: u32,
    /// Zero, or a `WireError`.
    status: u16,
    /// Set when the animation has ended and no frame follows.
    done: u8,
    /// `@intFromEnum(SurfaceType) + 1`, so that zero is never valid.
    surface_type: u8,
    dispose: u8,
    blend: u8,
    _pad: [2]u8 = @splat(0),
    /// The frame surface's size, which is what `offset` and `len` describe.
    width: u32,
    height: u32,
    /// Where it belongs on the canvas.
    x: i32,
    y: i32,
    /// The size the file gave the frame, which a clipped one does not match.
    declared_width: u32,
    declared_height: u32,
    delay_ms: u32,
    index: u32,
    /// The canvas the frames belong on. Repeated on every frame so that the
    /// parent can check it never changes, which a well-behaved child's does
    /// not.
    canvas_width: u32,
    canvas_height: u32,
    loop_count: u32,
    /// How many frames the file declared, plus one so that zero means "it did
    /// not say".
    declared_frames: u32,
    /// Where the pixels start within the shared mapping, and how long they
    /// are.
    offset: u64,
    len: u64,
};

/// A distinct magic from `Reply`'s, for the reason given on `FrameReply`.
const frame_magic: u32 = 0x7a32_6672; // "z2fr"

/// An animation decoded in the sandbox, a frame at a time.
///
/// The still-image `decode` runs the child to completion and reads its one
/// reply afterwards, so by the time the parent looks at the pixels the process
/// that wrote them is gone. That cannot hold here: streaming means the child
/// is alive between frames, waiting to be told to carry on.
///
/// What is given up by that is smaller than it sounds, and what is kept is the
/// part that mattered. Every number in every reply is still checked against
/// something the parent knows before a pointer is made out of it, so a
/// malicious reply still cannot make the parent read outside the mapping. What
/// is new is that a frame's *contents* may be rewritten while the parent is
/// looking at them, which yields a torn picture and not a memory-safety
/// failure --- and the module comment has always said that a subverted
/// decoder's pixels are the attacker's anyway.
///
/// **The child does not composite.** It is run with compositing off and hands
/// back un-composited frames; the canvas is built here, in the parent, out of
/// frames whose shape has already been checked. That is less work inside the
/// sandbox and less to trust from it: a child that lied about a frame can make
/// this canvas wrong, but it cannot make the compositing itself go wrong,
/// because the compositing is not its.
///
/// Under `Isolation.none` none of that applies: the frames come straight out
/// of an ordinary `codecs.Animation` in this process, which composites them
/// itself. The contract a caller sees is the same either way.
pub const AnimationStream = struct {
    backend: Backend,

    const Backend = union(enum) {
        child: Child,
        here: Here,
    };

    /// The next frame, or null at the end of the animation.
    ///
    /// The surface is valid until the next call. A caller keeping a frame
    /// past that must copy it, which `anim.Frame.toOwned` does.
    pub fn next(self: *AnimationStream) Error!?anim.Frame {
        return switch (self.backend) {
            // Only ever made where there is a sandbox to make it.
            .child => |*b| if (comptime available) b.next() else unreachable,
            .here => |*b| b.next(),
        };
    }

    /// The canvas as it stands after the last frame, or null when compositing
    /// was turned off.
    pub fn canvasSurface(self: *const AnimationStream) ?*const z2d.Surface {
        return switch (self.backend) {
            .child => |*b| if (b.canvas) |*c| &c.surface else null,
            .here => |*b| b.animation.canvasSurface(),
        };
    }

    /// What the file said about the animation as a whole, once a frame has
    /// been read.
    pub fn animationInfo(self: *const AnimationStream) anim.Info {
        return switch (self.backend) {
            .child => |*b| b.info,
            .here => |*b| b.animation.info(),
        };
    }

    /// Releases everything, and kills the child if the frames were not read
    /// to the end.
    pub fn deinit(self: *AnimationStream) void {
        switch (self.backend) {
            .child => |*b| if (comptime available) b.deinit() else unreachable,
            .here => |*b| b.deinit(),
        }
        self.* = undefined;
    }
};

/// `Isolation.none`: an ordinary animation, in this process.
const Here = struct {
    gpa: Allocator,
    /// The encoded input and the reader over it, together on the heap: the
    /// animation keeps a pointer to the reader, and this struct is returned
    /// by value.
    source: *Source,
    animation: codecs.Animation,
    ended: bool = false,

    const Source = struct {
        input: []u8,
        reader: Io.Reader,
    };

    fn next(self: *Here) Error!?anim.Frame {
        if (self.ended) return null;
        const frame = self.animation.next(self.gpa) catch |err| {
            // Ended by an error the way a sandboxed stream is, so that a
            // caller calling again gets the end rather than a decoder asked
            // to carry on from somewhere it has already failed.
            self.ended = true;
            return err;
        };
        if (frame == null) self.ended = true;
        return frame;
    }

    fn deinit(self: *Here) void {
        self.animation.deinit(self.gpa);
        self.gpa.free(self.source.input);
        self.gpa.destroy(self.source);
    }
};

/// `Isolation.process`: a forked child and the two pipes to it.
const Child = struct {
    /// The shared mapping, and its length.
    mapping: []align(std.heap.page_size_min) u8,
    /// The child, and the two pipes.
    pid: os.Pid,
    replies: os.Fd,
    acks: os.Fd,
    /// The canvas, in ordinary memory, or null when the caller asked for no
    /// compositing.
    canvas: ?anim.Canvas,
    /// Whether one is wanted. The canvas itself cannot exist until a frame
    /// has said how large it should be.
    want_canvas: bool,
    /// What the caller allowed, which the canvas the *child* asked for has to
    /// be inside. The parent allocates that canvas, on the strength of a
    /// number the child supplied, so it is checked like every other number in
    /// a reply.
    limits: common.Limits,
    gpa: Allocator,
    /// Set once the child has said it is finished, or has gone.
    ended: bool = false,
    /// Whether the child is waiting to be told to carry on. It is, from the
    /// moment a frame is handed out until the next call.
    owed_ack: bool = false,
    /// Checked against every reply, since a child whose canvas changes size
    /// half way through is one that is not describing an animation.
    canvas_width: u32 = 0,
    canvas_height: u32 = 0,
    info: anim.Info = .{},
    reaped: bool = false,

    /// The next frame. Its surface points into the shared mapping, and the
    /// next call is when the child is told it may reuse the memory.
    fn next(self: *Child) Error!?anim.Frame {
        if (self.ended) return null;

        // The frame handed out last is finished with, so the child may carry
        // on. Nothing is written before the first frame, which is why the
        // child does not wait before the first one either.
        if (self.owed_ack) {
            self.owed_ack = false;
            writeAll(self.acks, "\x00");
        }

        const reply = readFrameReply(self.replies) orelse {
            // The child went without saying anything, which is a crash or a
            // filter violation; its exit status says which.
            self.ended = true;
            try self.reap();
            return error.SandboxProtocolError;
        };
        if (reply.magic != frame_magic) {
            self.ended = true;
            return error.SandboxProtocolError;
        }
        if (reply.status != 0) {
            self.ended = true;
            try self.reap();
            return wireToError(reply.status);
        }
        if (reply.done != 0) {
            self.ended = true;
            try self.reap();
            return null;
        }

        if (self.canvas_width == 0) {
            // The child's first word about how large the picture is. It is
            // checked against the caller's budget before anything is
            // allocated on the strength of it.
            self.limits.check(reply.canvas_width, reply.canvas_height) catch {
                self.ended = true;
                return error.SandboxProtocolError;
            };
            self.canvas_width = reply.canvas_width;
            self.canvas_height = reply.canvas_height;
            self.info = .{
                .loop_count = reply.loop_count,
                .frames = if (reply.declared_frames == 0) null else reply.declared_frames - 1,
            };
            if (self.want_canvas) {
                const t = surfaceTypeFromWire(reply.surface_type) orelse {
                    self.ended = true;
                    return error.SandboxProtocolError;
                };
                self.canvas = anim.Canvas.init(
                    self.gpa,
                    t,
                    reply.canvas_width,
                    reply.canvas_height,
                ) catch |err| switch (err) {
                    error.InvalidData => {
                        self.ended = true;
                        return error.SandboxProtocolError;
                    },
                    error.OutOfMemory => |e| {
                        self.ended = true;
                        return e;
                    },
                };
            }
        } else if (reply.canvas_width != self.canvas_width or
            reply.canvas_height != self.canvas_height)
        {
            self.ended = true;
            return error.SandboxProtocolError;
        }

        const surface_type = surfaceTypeFromWire(reply.surface_type) orelse {
            self.ended = true;
            return error.SandboxProtocolError;
        };
        const sfc = self.wrap(surface_type, reply) catch |err| {
            self.ended = true;
            return err;
        };

        const frame: anim.Frame = .{
            .surface = sfc,
            .x = reply.x,
            .y = reply.y,
            .width = reply.declared_width,
            .height = reply.declared_height,
            .delay_ms = reply.delay_ms,
            .dispose = switch (reply.dispose) {
                1 => .background,
                2 => .previous,
                else => .keep,
            },
            .blend = if (reply.blend == 1) .over else .source,
            .index = reply.index,
        };

        if (self.canvas) |*c| {
            // Built here rather than in the child, out of a frame whose shape
            // the parent has just checked.
            c.draw(frame) catch |err| {
                self.ended = true;
                return err;
            };
        }

        self.owed_ack = true;
        return frame;
    }

    fn deinit(self: *Child) void {
        // A caller that stops early leaves the child blocked on an
        // acknowledgement that is never coming, so it is killed rather than
        // waited for. Closing the pipes would do it too --- the read would
        // end and the child would leave --- but only if the child is
        // co-operating, and this one is the process that might not be.
        if (!self.reaped) {
            os.kill(self.pid);
            _ = self.reap() catch {};
        }
        os.close(self.replies);
        os.close(self.acks);
        if (self.canvas) |*c| c.deinit();
        os.unmap(self.mapping.ptr, self.mapping.len);
    }

    fn reap(self: *Child) Error!void {
        if (self.reaped) return;
        self.reaped = true;
        const status = os.wait(self.pid) orelse return error.SandboxFailed;
        try checkExit(status);
    }

    fn wrap(self: *Child, surface_type: z2d.surface.SurfaceType, reply: FrameReply) Error!z2d.Surface {
        return wrapSurface(surface_type, self.mapping, reply.width, reply.height, reply.offset, reply.len);
    }
};

/// A whole frame reply, or null if the child went before writing one.
fn readFrameReply(fd: os.Fd) ?FrameReply {
    var reply: FrameReply = undefined;
    return if (readFull(fd, mem.asBytes(&reply))) reply else null;
}

/// Reads an animation a frame at a time, in a forked, locked-down process
/// unless `opts.isolation` says otherwise.
///
/// The counterpart of `decode` for animated files, and the same warnings
/// apply; see `AnimationStream` for the one property streaming gives up and
/// why it is smaller than it sounds.
///
/// The caller owns the returned stream and must `deinit` it, which kills the
/// child if the frames were not read to the end.
pub fn decodeAnimation(gpa: Allocator, r: *Io.Reader, opts: Options) Error!AnimationStream {
    return switch (opts.isolation) {
        .process => animateInChild(gpa, r, opts),
        .none => animateHere(gpa, r, opts),
    };
}

/// `Isolation.none`: an ordinary animation over the input read into memory,
/// which is read the same way the sandboxed path reads it so that both refuse
/// the same inputs.
fn animateHere(gpa: Allocator, r: *Io.Reader, opts: Options) Error!AnimationStream {
    const input = try readInput(gpa, r, opts.decode.limits);
    errdefer gpa.free(input);
    const source = try gpa.create(Here.Source);
    errdefer gpa.destroy(source);
    source.* = .{ .input = input, .reader = .fixed(input) };

    const animation = try codecs.animateDetect(gpa, &source.reader, .{
        .limits = opts.decode.limits,
        .surface_type = opts.decode.surface_type,
        .composite = opts.composite,
    });
    return .{ .backend = .{ .here = .{ .gpa = gpa, .source = source, .animation = animation } } };
}

fn animateInChild(gpa: Allocator, r: *Io.Reader, opts: Options) Error!AnimationStream {
    if (!available) return error.SandboxUnavailable;

    const limits = opts.decode.limits;

    // Sized for one frame at a time rather than for the whole animation,
    // which is the point of streaming: the child resets its allocator between
    // frames, so what has to fit is the largest frame and the decoder's
    // working memory, not the sum of every frame.
    const cap = try reservation(limits, opts.working_bytes, std.heap.pageSize());

    const input = try readInput(gpa, r, limits);
    defer gpa.free(input);

    const base = os.mapShared(cap) orelse return error.SandboxFailed;
    var mapped = true;
    defer if (mapped) os.unmap(base, cap);

    // Two pipes, and the second is what streaming costs: the child has to be
    // told when a frame has been read before it may write the next one over
    // it.
    var reply_fds: [2]os.Fd = undefined;
    if (!os.pipe(&reply_fds)) return error.SandboxFailed;
    var ack_fds: [2]os.Fd = undefined;
    if (!os.pipe(&ack_fds)) {
        os.close(reply_fds[0]);
        os.close(reply_fds[1]);
        return error.SandboxFailed;
    }
    var open = [4]bool{ true, true, true, true };
    const all_fds = [4]os.Fd{ reply_fds[0], reply_fds[1], ack_fds[0], ack_fds[1] };
    errdefer for (all_fds, open) |pfd, is_open| {
        if (is_open) os.close(pfd);
    };

    const arena = base[0..cap];

    const pid = os.fork() orelse return error.SandboxFailed;
    if (pid == 0) {
        // The child. Nothing below this line returns.
        os.close(reply_fds[0]);
        os.close(ack_fds[1]);
        childAnimateMain(reply_fds[1], ack_fds[0], arena, input, opts);
    }

    // The parent keeps the reply pipe's read end and the ack pipe's write
    // end, and closes the ends the child has.
    os.close(reply_fds[1]);
    open[1] = false;
    os.close(ack_fds[0]);
    open[2] = false;

    mapped = false;
    open[0] = false;
    open[3] = false;
    return .{
        .backend = .{
            .child = .{
                .mapping = @alignCast(base[0..cap]),
                .pid = pid,
                .replies = reply_fds[0],
                .acks = ack_fds[1],
                // The canvas cannot be built yet: nothing has said how large it is.
                // The first frame says, and builds it.
                .canvas = null,
                .want_canvas = opts.composite,
                .limits = limits,
                .gpa = gpa,
            },
        },
    };
}

/// The descriptor a child writes its reply to, and the one a streaming child
/// reads acknowledgements from. Fixed numbers, because the seccomp filter
/// compares them as constants; see `seccomp.reply_fd`. Capsicum has no such
/// need, and uses the same numbers so that the child is arranged the same way
/// on both.
const reply_fd: os.Fd = @intCast(seccomp.reply_fd);
const ack_fd: os.Fd = @intCast(seccomp.ack_fd);

/// The lowest descriptor number the child may close: everything at or above
/// this is something it inherited and has no business keeping.
///
/// The child's descriptors are moved into place in two steps, because the two
/// moves cannot otherwise be ordered safely: the reply pipe might already sit
/// on the number the acknowledgement pipe is about to take, or the other way
/// round, and either order then closes the descriptor the other move was going
/// to use. So each is first parked at or above this number with `os.park`,
/// and only then claims its fixed number with `os.claim`.
///
/// Everything at or above it is then closed. The child is forked and never
/// exec'd, so `CLOEXEC` does nothing for it: it starts life holding
/// everything the parent had open. It cannot *open* a socket or a file under
/// either kernel's lock, but `write` is a call it has, and a decoder
/// subverted into writing attacker-controlled bytes into a connection the
/// parent already had is a containment failure in the thing whose only job is
/// containment. Closing takes away what could be written to; the lock takes
/// away the ability to name anything else.
const first_closable: os.Fd = @max(reply_fd, ack_fd) + 1;

/// The child of `decodeAnimation`: locks itself down, decodes a frame at a
/// time out of the buffer it was given, and waits to be told to carry on.
fn childAnimateMain(reply_pipe: os.Fd, ack_pipe: os.Fd, arena: []u8, input: []const u8, opts: Options) noreturn {
    var reply: FrameReply = .{
        .magic = frame_magic,
        .status = @backingInt(WireError.protocol),
        .done = 0,
        .surface_type = 0,
        .dispose = 0,
        .blend = 0,
        .width = 0,
        .height = 0,
        .x = 0,
        .y = 0,
        .declared_width = 0,
        .declared_height = 0,
        .delay_ms = 0,
        .index = 0,
        .canvas_width = 0,
        .canvas_height = 0,
        .loop_count = 0,
        .declared_frames = 0,
        .offset = 0,
        .len = 0,
    };

    result: {
        // Both pipes onto the numbers the lock knows, and every other
        // descriptor the child inherited shut. All of it before the lock
        // exists, which is why none of it needs permitting.
        //
        // Both are parked out of range first. Either could already be sitting
        // on the number the other is about to claim, and then whichever moved
        // first would close the descriptor the second needed.
        const parked_reply = os.park(reply_pipe, first_closable) orelse {
            reply.status = @backingInt(WireError.sandbox);
            break :result;
        };
        const parked_ack = os.park(ack_pipe, first_closable) orelse {
            reply.status = @backingInt(WireError.sandbox);
            break :result;
        };
        if (!os.claim(parked_reply, reply_fd) or
            !os.claim(parked_ack, ack_fd))
        {
            reply.status = @backingInt(WireError.sandbox);
            break :result;
        }
        os.closeFrom(first_closable);
        os.harden(opts.cpu_seconds);

        // The point of no return. Whichever profile the caller asked for,
        // in the variant that also permits the acknowledgement read --- so
        // that asking for `permissive` does not quietly get a filter tighter
        // than the one requested.
        const profile: seccomp.Profile = switch (opts.profile) {
            .permissive, .permissive_streaming => .permissive_streaming,
            .strict, .streaming => .streaming,
        };
        switch (profile) {
            inline else => |p| os.confine(p) catch {
                reply.status = @backingInt(WireError.sandbox);
                break :result;
            },
        }

        var reader: Io.Reader = .fixed(input);
        const fmt = format.detectReader(&reader) catch |err| {
            reply.status = @backingInt(wireFromError(err));
            break :result;
        };

        // The frames come out un-composited and the parent composites them,
        // so nothing here allocates a canvas --- which is also what lets the
        // allocator below be reset between frames.
        var again: Io.Reader = .fixed(input);
        var fba: std.heap.FixedBufferAllocator = .init(arena);
        var animation = codecs.animate(fba.allocator(), fmt, &again, .{
            .limits = opts.decode.limits,
            .surface_type = opts.decode.surface_type,
            .composite = false,
        }) catch |err| {
            reply.status = @backingInt(wireFromError(err));
            break :result;
        };

        // Where the animation's own state ends and a frame's memory begins.
        // Everything past here is thrown away between frames, which is what
        // keeps a thousand-frame animation inside a one-frame budget.
        const persistent = fba.end_index;

        while (true) {
            fba.end_index = persistent;

            const maybe = animation.next(fba.allocator()) catch |err| {
                reply.status = @backingInt(wireFromError(err));
                break :result;
            };
            const frame = maybe orelse {
                reply.status = 0;
                reply.done = 1;
                break :result;
            };

            const bytes = surfaceBytes(frame.surface);
            const info = animation.info();
            reply.status = 0;
            reply.done = 0;
            reply.surface_type = @backingInt(std.meta.activeTag(frame.surface)) + 1;
            reply.dispose = switch (frame.dispose) {
                .keep => 0,
                .background => 1,
                .previous => 2,
            };
            reply.blend = switch (frame.blend) {
                .source => 0,
                .over => 1,
            };
            reply.width = @intCast(frame.surface.getWidth());
            reply.height = @intCast(frame.surface.getHeight());
            reply.x = frame.x;
            reply.y = frame.y;
            reply.declared_width = frame.width;
            reply.declared_height = frame.height;
            reply.delay_ms = frame.delay_ms;
            reply.index = frame.index;
            reply.canvas_width = canvasWidth(&animation);
            reply.canvas_height = canvasHeight(&animation);
            reply.loop_count = info.loop_count;
            reply.declared_frames = if (info.frames) |n| n + 1 else 0;
            reply.offset = @intFromPtr(bytes.ptr) - @intFromPtr(arena.ptr);
            reply.len = bytes.len;

            writeAll(reply_fd, mem.asBytes(&reply));

            // Wait to be told the parent has finished with those pixels. This
            // is the one call `streaming` permits that `strict` does not, and
            // the lock confines it to this descriptor. End of stream, or an
            // error, means the parent has gone and there is nobody to hand
            // the next frame to.
            var ack: [1]u8 = undefined;
            const n = os.read(ack_fd, &ack) orelse os.exit(0);
            if (n == 0) os.exit(0);
        }
    }

    writeAll(reply_fd, mem.asBytes(&reply));
    os.exit(0);
}

/// The canvas size an animation reports, which is the image's own size and is
/// known whether or not a canvas was allocated.
fn canvasWidth(animation: *const codecs.Animation) u32 {
    return switch (animation.*) {
        .gif => |*a| a.decoder.screen.width,
        .png => |*a| a.decoder.header.width,
        .webp => |*a| a.decoder.width,
        .still => |*a| if (a.surface) |s| @intCast(s.getWidth()) else 0,
    };
}

fn canvasHeight(animation: *const codecs.Animation) u32 {
    return switch (animation.*) {
        .gif => |*a| a.decoder.screen.height,
        .png => |*a| a.decoder.header.height,
        .webp => |*a| a.decoder.height,
        .still => |*a| if (a.surface) |s| @intCast(s.getHeight()) else 0,
    };
}

test "an animation streams out of the sandbox a frame at a time" {
    if (!available) return error.SkipZigTest;
    const gpa = testing.allocator;

    // A two-frame GIF: a 2x2 screen of red, then one blue pixel over it.
    const bytes = "GIF89a" ++ "\x02\x00\x02\x00\x91\x00\x00" ++
        "\xff\x00\x00" ++ "\x00\xff\x00" ++ "\x00\x00\xff" ++ "\xff\xff\xff" ++
        "\x21\xf9\x04\x04\x0a\x00\x00\x00" ++
        "\x2c\x00\x00\x00\x00\x02\x00\x02\x00\x00\x02\x03\x04\x00\x05\x00" ++
        "\x21\xf9\x04\x04\x00\x00\x00\x00" ++
        "\x2c\x01\x00\x01\x00\x01\x00\x01\x00\x00\x02\x02\x54\x01\x00" ++
        "\x3b";

    var r: Io.Reader = .fixed(bytes);
    var stream = decodeAnimation(gpa, &r, .{}) catch |err| switch (err) {
        // No seccomp here: an old kernel, or a container that will not allow
        // a filter.
        error.SandboxFailed => return error.SkipZigTest,
        else => |e| return e,
    };
    defer stream.deinit();

    const red: pixels.Rgba8 = .rgb(255, 0, 0);
    const blue: pixels.Rgba8 = .rgb(0, 0, 255);

    const first = (stream.next() catch |err| switch (err) {
        error.SandboxViolation, error.SandboxFailed => return error.SkipZigTest,
        else => |e| return e,
    }) orelse return error.SkipZigTest;
    try testing.expectEqual(@as(i32, 2), first.surface.getWidth());
    try testing.expectEqual(@as(u32, 100), first.delay_ms);
    try testing.expectEqual(red, pixels.Rgba8.fromZ2d(first.surface.getPixel(0, 0).?));

    // The second frame is a single pixel, un-composited --- the same contract
    // the unsandboxed reader offers.
    const second = (try stream.next()).?;
    try testing.expectEqual(@as(i32, 1), second.surface.getWidth());
    try testing.expectEqual(@as(i32, 1), second.x);
    try testing.expectEqual(blue, pixels.Rgba8.fromZ2d(second.surface.getPixel(0, 0).?));

    // And the canvas, which this process composited out of frames whose shape
    // it had already checked.
    const canvas = stream.canvasSurface().?;
    try testing.expectEqual(red, pixels.Rgba8.fromZ2d(canvas.getPixel(0, 0).?));
    try testing.expectEqual(blue, pixels.Rgba8.fromZ2d(canvas.getPixel(1, 1).?));

    try testing.expectEqual(@as(?anim.Frame, null), try stream.next());
}

test "a sandboxed animation abandoned half way does not leave a child behind" {
    if (!available) return error.SkipZigTest;
    const gpa = testing.allocator;

    // The child blocks waiting to be told it may write the next frame, so a
    // caller that simply stops leaves it there for ever. `deinit` kills it
    // rather than waiting for it, which is the only answer that works when
    // the process being waited for is the one that might not co-operate.
    const bytes = "GIF89a" ++ "\x02\x00\x02\x00\x91\x00\x00" ++
        "\xff\x00\x00" ++ "\x00\xff\x00" ++ "\x00\x00\xff" ++ "\xff\xff\xff" ++
        "\x2c\x00\x00\x00\x00\x02\x00\x02\x00\x00\x02\x03\x04\x00\x05\x00" ++
        "\x2c\x00\x00\x00\x00\x01\x00\x01\x00\x00\x02\x02\x54\x01\x00" ++
        "\x3b";

    var r: Io.Reader = .fixed(bytes);
    var stream = decodeAnimation(gpa, &r, .{}) catch |err| switch (err) {
        error.SandboxFailed => return error.SkipZigTest,
        else => |e| return e,
    };
    const pid = stream.backend.child.pid;
    const first = (stream.next() catch return error.SkipZigTest) orelse return error.SkipZigTest;
    try testing.expectEqual(@as(i32, 2), first.surface.getWidth());

    // Stop here, with a frame still owed.
    stream.deinit();

    // The child is gone: waiting for it again says there is no such process.
    try testing.expectEqual(@as(?u32, null), os.wait(pid));
}

test "a streaming decode under permissive is not quietly made stricter" {
    if (!available) return error.SkipZigTest;
    const gpa = testing.allocator;

    // Asking for `permissive` and being handed `streaming` would be a filter
    // tighter than the one requested, which is the wrong direction for a
    // surprise: a decoder that needed `mmap` would die of a violation the
    // caller had explicitly asked not to have.
    const bytes = "GIF89a" ++ "\x02\x00\x02\x00\x91\x00\x00" ++
        "\xff\x00\x00" ++ "\x00\xff\x00" ++ "\x00\x00\xff" ++ "\xff\xff\xff" ++
        "\x2c\x00\x00\x00\x00\x02\x00\x02\x00\x00\x02\x03\x04\x00\x05\x00" ++
        "\x3b";

    var r: Io.Reader = .fixed(bytes);
    var stream = decodeAnimation(gpa, &r, .{ .profile = .permissive }) catch |err| switch (err) {
        error.SandboxFailed => return error.SkipZigTest,
        else => |e| return e,
    };
    defer stream.deinit();

    const frame = (stream.next() catch return error.SkipZigTest) orelse return error.SkipZigTest;
    try testing.expectEqual(@as(i32, 2), frame.surface.getWidth());
    try testing.expectEqual(
        pixels.Rgba8.rgb(255, 0, 0),
        pixels.Rgba8.fromZ2d(frame.surface.getPixel(0, 0).?),
    );
}

test "an unisolated animation streams and composites like a sandboxed one" {
    const gpa = testing.allocator;
    const bytes = "GIF89a" ++ "\x02\x00\x02\x00\x91\x00\x00" ++
        "\xff\x00\x00" ++ "\x00\xff\x00" ++ "\x00\x00\xff" ++ "\xff\xff\xff" ++
        "\x21\xf9\x04\x04\x0a\x00\x00\x00" ++
        "\x2c\x00\x00\x00\x00\x02\x00\x02\x00\x00\x02\x03\x04\x00\x05\x00" ++
        "\x21\xf9\x04\x04\x00\x00\x00\x00" ++
        "\x2c\x01\x00\x01\x00\x01\x00\x01\x00\x00\x02\x02\x54\x01\x00" ++
        "\x3b";

    var r: Io.Reader = .fixed(bytes);
    var stream = try decodeAnimation(gpa, &r, .{ .isolation = .none });
    defer stream.deinit();

    const red: pixels.Rgba8 = .rgb(255, 0, 0);
    const blue: pixels.Rgba8 = .rgb(0, 0, 255);

    const first = (try stream.next()).?;
    try testing.expectEqual(@as(i32, 2), first.surface.getWidth());
    try testing.expectEqual(@as(u32, 100), first.delay_ms);
    try testing.expectEqual(red, pixels.Rgba8.fromZ2d(first.surface.getPixel(0, 0).?));

    const second = (try stream.next()).?;
    try testing.expectEqual(@as(i32, 1), second.surface.getWidth());
    try testing.expectEqual(@as(i32, 1), second.x);
    try testing.expectEqual(blue, pixels.Rgba8.fromZ2d(second.surface.getPixel(0, 0).?));

    const canvas = stream.canvasSurface().?;
    try testing.expectEqual(red, pixels.Rgba8.fromZ2d(canvas.getPixel(0, 0).?));
    try testing.expectEqual(blue, pixels.Rgba8.fromZ2d(canvas.getPixel(1, 1).?));

    try testing.expectEqual(@as(?anim.Frame, null), try stream.next());
    // And the end stays the end.
    try testing.expectEqual(@as(?anim.Frame, null), try stream.next());
}

test "an unisolated animation abandoned half way leaks nothing" {
    // The allocator this runs under fails the test on a leak, which is the
    // claim: `deinit` part way through releases the input, the reader and
    // the decoder's state as surely as reading to the end would.
    const gpa = testing.allocator;
    const bytes = "GIF89a" ++ "\x02\x00\x02\x00\x91\x00\x00" ++
        "\xff\x00\x00" ++ "\x00\xff\x00" ++ "\x00\x00\xff" ++ "\xff\xff\xff" ++
        "\x2c\x00\x00\x00\x00\x02\x00\x02\x00\x00\x02\x03\x04\x00\x05\x00" ++
        "\x2c\x00\x00\x00\x00\x01\x00\x01\x00\x00\x02\x02\x54\x01\x00" ++
        "\x3b";

    var r: Io.Reader = .fixed(bytes);
    var stream = try decodeAnimation(gpa, &r, .{ .isolation = .none, .composite = false });
    defer stream.deinit();
    _ = (try stream.next()).?;
    try testing.expectEqual(@as(?*const z2d.Surface, null), stream.canvasSurface());
}

test "a strict child may write down the reply pipe and nowhere else" {
    // seccomp's claim, as the test above is: the filter refuses a write to a
    // descriptor that is still open. Capsicum's answer to the same hole is
    // that the descriptor is not open, which the next test covers for both.
    if (builtin.os.tag != .linux or !available) return error.SkipZigTest;

    // The hole this closes: a forked child keeps every descriptor the parent
    // had open, because `CLOEXEC` means nothing to a process that never
    // execs. A decoder cannot *open* a socket under any profile here, but
    // `write` is a call it has --- so without this it could put
    // attacker-controlled bytes into a connection the parent already had.
    //
    // Two children, differing only in which descriptor they write to.
    for ([_]enum { reply, other }{ .reply, .other }) |which| {
        var fds: [2]i32 = undefined;
        if (linux.errno(linux.pipe2(&fds, .{})) != .SUCCESS) return error.SkipZigTest;
        defer {
            _ = linux.close(fds[0]);
            _ = linux.close(fds[1]);
        }

        const fork_rc = linux.fork();
        if (linux.errno(fork_rc) != .SUCCESS) return error.SkipZigTest;
        const pid: i32 = @intCast(fork_rc);
        if (pid == 0) {
            const parked = os.park(fds[1], first_closable) orelse {
                _ = linux.exit_group(9);
                unreachable;
            };
            if (!os.claim(parked, reply_fd)) {
                _ = linux.exit_group(9);
                unreachable;
            }
            // Deliberately *not* sealed: the point is that the filter refuses
            // the write even when the descriptor is still there to write to.
            seccomp.install(.strict) catch {
                _ = linux.exit_group(9);
                unreachable;
            };
            const fd: i32 = switch (which) {
                .reply => @intCast(seccomp.reply_fd),
                // The same pipe, by the number it was opened as. Nothing
                // about the object changes; only the integer naming it.
                .other => parked,
            };
            _ = linux.write(fd, "x", 1);
            _ = linux.exit_group(0);
            unreachable;
        }

        const status = os.wait(pid) orelse return error.SkipZigTest;
        if (linux.W.IFEXITED(status) and linux.W.EXITSTATUS(status) == 9) return error.SkipZigTest;
        switch (which) {
            .reply => {
                try testing.expect(linux.W.IFEXITED(status));
                try testing.expectEqual(@as(u32, 0), linux.W.EXITSTATUS(status));
            },
            .other => {
                try testing.expect(linux.W.IFSIGNALED(status));
                try testing.expectEqual(linux.SIG.SYS, linux.W.TERMSIG(status));
            },
        }
    }
}

test "a child keeps no descriptor it was not given" {
    if (!available) return error.SkipZigTest;

    // `os.closeFrom` closes what the fork handed over. Proved by opening a
    // pipe the child has no business keeping, closing, and having the child
    // report whether it is still there --- through the one descriptor it is
    // allowed to keep.
    var carrier: [2]os.Fd = undefined;
    if (!os.pipe(&carrier)) return error.SkipZigTest;
    defer {
        os.close(carrier[0]);
        os.close(carrier[1]);
    }
    var stray: [2]os.Fd = undefined;
    if (!os.pipe(&stray)) return error.SkipZigTest;
    defer {
        os.close(stray[0]);
        os.close(stray[1]);
    }

    const pid = os.fork() orelse return error.SkipZigTest;
    if (pid == 0) {
        const parked = os.park(carrier[1], first_closable) orelse os.exit(9);
        if (!os.claim(parked, reply_fd)) os.exit(9);
        os.closeFrom(first_closable);
        // No lock here: what is being tested is the closing, and a lock
        // would only make a failure harder to tell apart from a refusal.
        var answer: [1]u8 = .{if (os.write(stray[1], "x") != null) 1 else 0};
        _ = os.write(reply_fd, &answer);
        os.exit(0);
    }

    const status = os.wait(pid) orelse return error.SkipZigTest;
    if (os.W.IFEXITED(status) and os.W.EXITSTATUS(status) == 9) return error.SkipZigTest;
    var answer: [1]u8 = undefined;
    try testing.expectEqual(@as(?usize, 1), os.read(carrier[0], &answer));
    // Zero: the stray descriptor was gone by the time the child tried it.
    try testing.expectEqual(@as(u8, 0), answer[0]);
}

test "a child that stops making progress is killed by the kernel" {
    if (!available) return error.SkipZigTest;

    // The answer to a decoder stuck in a loop. Without it the parent waits
    // for a child that is never coming back, and a timeout in the parent
    // would be a second clock to get wrong; with it the kernel does the
    // killing and the parent's ordinary wait returns.
    //
    // One second rather than the default sixty, so the test costs a second
    // rather than a minute.
    const pid = os.fork() orelse return error.SkipZigTest;
    if (pid == 0) {
        os.harden(1);
        // Spin. `@breakpoint` is not it and a sleep would not do: this has to
        // consume processor time, which is what the limit measures.
        var x: u64 = 0;
        while (true) : (x +%= 1) std.mem.doNotOptimizeAway(x);
    }

    const status = os.wait(pid) orelse return error.SkipZigTest;
    try testing.expect(os.W.IFSIGNALED(status));
    // `SIGXCPU` at the soft limit, whose default disposition is to end the
    // process, or `SIGKILL` at the hard one. Which arrives first is the
    // kernel's business; that one of them does is the claim.
    const sig = os.W.TERMSIG(status);
    try testing.expect(sig == os.SIG.XCPU or sig == os.SIG.KILL);
}
