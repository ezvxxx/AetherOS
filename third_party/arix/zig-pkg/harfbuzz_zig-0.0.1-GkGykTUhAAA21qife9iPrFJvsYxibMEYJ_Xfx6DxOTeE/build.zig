const std = @import("std");
const Translator = @import("translate_c").Translator;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const library = buildHarfBuzz(b, target, optimize);
    b.installArtifact(library);

    const t: Translator = .init(b.dependency("translate_c", .{}), .{
        .c_source_file = b.path("src/c.h"),
        .target = target,
        .optimize = optimize,
    });
    t.linkLibrary(library);

    const module = b.addModule("harfbuzz_zig", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{
                .name = "c",
                .module = t.mod,
            },
        },
    });

    // Test
    const test_step = b.step("test", "Run all tests");

    const unit_tests = b.addTest(.{ .name = "tests", .root_module = module });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    test_step.dependOn(&run_unit_tests.step);
    b.step("check", "Compile without running tests").dependOn(&unit_tests.step);
}

fn buildHarfBuzz(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Step.Compile {
    const source = b.dependency("harfbuzz", .{});
    const module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
        .pic = true,
    });
    module.addIncludePath(source.path("src"));
    switch (target.result.os.tag) {
        .linux, .macos, .freebsd, .netbsd, .openbsd, .dragonfly => {
            inline for (.{ "HAVE_PTHREAD", "HAVE_UNISTD_H", "HAVE_SYS_MMAN_H", "HAVE_MMAP", "HAVE_MPROTECT" }) |feature|
                module.addCMacro(feature, "1");
            module.linkSystemLibrary("pthread", .{ .use_pkg_config = .no });
        },
        else => {},
    }
    module.addCSourceFiles(.{
        .root = source.path("src"),
        .flags = &.{ "-std=c++17", "-fno-exceptions", "-fno-rtti" },
        .files = &.{"harfbuzz.cc"},
    });
    const library = b.addLibrary(.{ .name = "harfbuzz", .linkage = .static, .root_module = module });
    library.installHeadersDirectory(source.path("src"), "", .{ .include_extensions = &.{".h"} });
    return library;
}
