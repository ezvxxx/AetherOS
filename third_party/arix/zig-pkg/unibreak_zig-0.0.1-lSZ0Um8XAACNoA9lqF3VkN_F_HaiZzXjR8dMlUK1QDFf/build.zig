const std = @import("std");
const Translator = @import("translate_c").Translator;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const library = buildUnibreak(b, target, optimize);
    b.installArtifact(library);

    const t: Translator = .init(b.dependency("translate_c", .{}), .{
        .c_source_file = b.path("src/c.h"),
        .target = target,
        .optimize = optimize,
    });
    t.linkLibrary(library);

    const module = b.addModule("unibreak_zig", .{
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

fn buildUnibreak(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Step.Compile {
    const source = b.dependency("unibreak", .{});
    const module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .pic = true,
    });
    module.addIncludePath(source.path("src"));
    module.addCSourceFiles(.{
        .root = source.path("src"),
        .flags = &.{"-std=c99"},
        .files = &.{
            "unibreakbase.c", "unibreakdef.c",       "linebreak.c", "linebreakdata.c",
            "linebreakdef.c", "eastasianwidthdef.c", "emojidef.c",  "graphemebreak.c",
            "wordbreak.c",
        },
    });
    const library = b.addLibrary(.{ .name = "unibreak", .linkage = .static, .root_module = module });
    inline for (.{ "unibreakbase.h", "unibreakdef.h", "linebreak.h", "graphemebreak.h", "wordbreak.h" }) |header|
        library.installHeader(source.path("src/" ++ header), header);
    return library;
}
