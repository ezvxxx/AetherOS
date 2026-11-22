const std = @import("std");
const Translator = @import("translate_c").Translator;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const library = buildFontconfig(b, target, optimize);

    const t: Translator = .init(b.dependency("translate_c", .{}), .{
        .c_source_file = b.path("src/c.h"),
        .target = target,
        .optimize = optimize,
    });
    t.linkLibrary(library);
    b.installArtifact(library);

    const module = b.addModule("fontconfig_zig", .{
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

fn buildFontconfig(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Step.Compile {
    if (target.result.os.tag != .linux) @panic("the bundled Fontconfig build currently supports Linux");
    const source = b.dependency("fontconfig", .{});
    const lib = cLibrary(b, "fontconfig", target, optimize);
    const mod = lib.root_module;
    const freetype = b.dependency("freetype_zig", .{ .target = target, .optimize = optimize });
    mod.linkLibrary(freetype.artifact("freetype"));
    mod.linkLibrary(buildExpat(b, target, optimize));
    mod.linkSystemLibrary("m", .{ .use_pkg_config = .no });
    mod.linkSystemLibrary("pthread", .{ .use_pkg_config = .no });

    const header = b.addConfigHeader(.{
        .style = .{ .autoconf_at = source.path("fontconfig/fontconfig.h.in") },
        .include_path = "fontconfig/fontconfig.h",
    }, .{ .CACHE_VERSION = 12, .CACHE_MIN_COMPAT_VERSION = 9, .CACHE_SNAP_VERSION = 0, .NEXT_CACHE_VERSION = 0 });
    const includes = b.addWriteFiles();
    _ = includes.addCopyFile(header.getOutputFile(), "fontconfig/fontconfig.h");
    const tables = fontconfigTables(b, source, header.getOutputFile(), includes.getDirectory());
    mod.addIncludePath(includes.getDirectory());
    mod.addIncludePath(tables);
    mod.addIncludePath(tables.path(b, "src"));
    mod.addIncludePath(source.path(""));
    mod.addIncludePath(source.path("src"));
    mod.addConfigHeader(b.addConfigHeader(.{ .style = .blank, .include_path = "config.h" }, .{
        ._GNU_SOURCE = 1,
        .ENABLE_FREETYPE = 1,
        .ENABLE_FONTATIONS = 0,
        .USE_ICONV = 1,
        .FREETYPE_PCF_LONG_FAMILY_NAMES = 1,
        .PACKAGE = "fontconfig",
        .PACKAGE_NAME = "fontconfig",
        .PACKAGE_VERSION = "2.18.3",
        .FC_VERSION_MAJOR = 2,
        .FC_VERSION_MINOR = 18,
        .FC_VERSION_MICRO = 3,
        .FC_DEFAULT_FONTS = "<dir>/usr/share/fonts</dir><dir>/usr/local/share/fonts</dir><dir>~/.fonts</dir>",
        .FC_FONTPATH = "",
        .FC_CACHEDIR = "/var/cache/fontconfig",
        .FC_TEMPLATEDIR = "/usr/share/fontconfig/conf.avail",
        .FONTCONFIG_PATH = "/etc/fonts",
        .CONFIGDIR = "/etc/fonts/conf.d",
        .FC_GPERF_SIZE_T = .size_t,
        .SIZEOF_VOID_P = target.result.ptrBitWidth() / 8,
        .ALIGNOF_VOID_P = target.result.ptrBitWidth() / 8,
        .ALIGNOF_DOUBLE = target.result.cTypeAlignment(.double).?,
        .WORDS_BIGENDIAN = @intFromBool(target.result.cpu.arch.endian() == .big),
        .FLEXIBLE_ARRAY_MEMBER = .@"/**/",
        .HAVE_STDATOMIC_PRIMITIVES = 1,
        .HAVE_PTHREAD = 1,
        .HAVE_DIRENT_H = 1,
        .HAVE_FCNTL_H = 1,
        .HAVE_UNISTD_H = 1,
        .HAVE_SYS_STAT_H = 1,
        .HAVE_SYS_TYPES_H = 1,
        .HAVE_SYS_STATVFS_H = 1,
        .HAVE_SYS_VFS_H = 1,
        .HAVE_SYS_STATFS_H = 1,
        .HAVE_SYS_PARAM_H = 1,
        .HAVE_SYS_MOUNT_H = 1,
        .HAVE_FSTATVFS = 1,
        .HAVE_FSTATFS = 1,
        .HAVE_LINK = 1,
        .HAVE_SYMLINK = 1,
        .HAVE_LSTAT = 1,
        .HAVE_READLINK = 1,
        .HAVE_MKSTEMP = 1,
        .HAVE_MKOSTEMP = 1,
        .HAVE_MMAP = 1,
        .HAVE_POSIX_FADVISE = 1,
        .HAVE_RAND = 1,
        .HAVE_RANDOM = 1,
        .HAVE_LRAND48 = 1,
        .HAVE_STRDUP = 1,
        .HAVE_STRERROR = 1,
        .HAVE_VASPRINTF = 1,
        .HAVE_VSNPRINTF = 1,
        .HAVE_C99_VSNPRINTF = 1,
        .HAVE_USELOCALE = 1,
        .HAVE_STRUCT_DIRENT_D_TYPE = 1,
        .HAVE_STRUCT_STAT_ST_MTIM = 1,
        .HAVE_STRUCT_STATFS_F_FLAGS = 1,
        .HAVE_FT_DONE_MM_VAR = 1,
        .HAVE_FT_GET_BDF_PROPERTY = 1,
        .HAVE_FT_GET_PS_FONT_INFO = 1,
        .HAVE_FT_GET_X11_FONT_FORMAT = 1,
    }));
    mod.addCSourceFiles(.{
        .root = source.path("src"),
        .flags = &.{ "-std=c11", "-DHAVE_CONFIG_H" },
        .files = &.{
            "fcatomic.c",   "fccache.c", "fccfg.c",          "fccharset.c", "fcconffile.c",
            "fccompat.c",   "fcdbg.c",   "fcdefault.c",      "fcdir.c",     "fcformat.c",
            "fcfreetype.c", "fcfs.c",    "fcgenericalias.c", "fcptrlist.c", "fchash.c",
            "fcinit.c",     "fclang.c",  "fclist.c",         "fcmatch.c",   "fcmatrix.c",
            "fcname.c",     "fcobjs.c",  "fcpat.c",          "fcrange.c",   "fcserialize.c",
            "fcstat.c",     "fcstr.c",   "fcweight.c",       "fcxml.c",     "ftglue.c",
        },
    });
    lib.installConfigHeader(header);
    lib.installHeader(source.path("fontconfig/fcfreetype.h"), "fontconfig/fcfreetype.h");
    lib.installHeader(source.path("fontconfig/fcprivate.h"), "fontconfig/fcprivate.h");
    return lib;
}

fn cLibrary(b: *std.Build, name: []const u8, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Step.Compile {
    return b.addLibrary(.{
        .name = name,
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .pic = true,
        }),
    });
}

/// Builds the XML parser with namespaces, DTD support, and OS-provided entropy.
fn buildExpat(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Step.Compile {
    const source = b.dependency("expat", .{});
    const lib = cLibrary(b, "expat", target, optimize);
    lib.root_module.addIncludePath(source.path("lib"));
    lib.root_module.addConfigHeader(b.addConfigHeader(.{ .style = .blank, .include_path = "expat_config.h" }, .{
        .BYTEORDER = if (target.result.cpu.arch.endian() == .little) @as(u16, 1234) else @as(u16, 4321),
        .HAVE_UNISTD_H = 1,
        .HAVE_FCNTL_H = 1,
        .HAVE_SYS_TYPES_H = 1,
        .HAVE_SYS_STAT_H = 1,
        .HAVE_STDINT_H = 1,
        .XML_DEV_URANDOM = 1,
        .XML_CONTEXT_BYTES = 1024,
        .XML_DTD = 1,
        .XML_NS = 1,
        .XML_GE = 1,
    }));
    lib.root_module.addCSourceFiles(.{
        .root = source.path("lib"),
        .flags = &.{ "-std=c11", "-D_GNU_SOURCE", "-DHAVE_EXPAT_CONFIG_H", "-DXML_STATIC" },
        .files = &.{ "xmlparse.c", "xmlrole.c", "xmltok.c", "xcs.c", "random_dev_urandom.c" },
    });
    lib.installHeader(source.path("lib/expat.h"), "expat.h");
    lib.installHeader(source.path("lib/expat_external.h"), "expat_external.h");

    return lib;
}

fn buildGperf(b: *std.Build) *std.Build.Step.Compile {
    const source = b.dependency("gperf", .{});
    const mod = b.createModule(.{
        .target = b.graph.host,
        .optimize = .fast,
        .link_libc = true,
        .link_libcpp = true,
    });
    mod.addIncludePath(source.path("src"));
    mod.addIncludePath(source.path("lib"));
    mod.addConfigHeader(b.addConfigHeader(.{ .style = .blank, .include_path = "config.h" }, .{
        .HAVE_DYNAMIC_ARRAY = 1,
        .HAVE_GETOPT_H = 1,
        .HAVE_UNISTD_H = 1,
        .PACKAGE_VERSION = "3.1",
        .PACKAGE_STRING = "GNU gperf 3.1",
        .PACKAGE_NAME = "gperf",
        .PACKAGE_BUGREPORT = "bug-gperf@gnu.org",
    }));
    mod.addCSourceFiles(.{
        .root = source.path(""),
        .flags = &.{"-std=gnu++98"},
        .files = &.{
            "src/version.cc",      "src/positions.cc", "src/options.cc",    "src/keyword.cc",
            "src/keyword-list.cc", "src/input.cc",     "src/bool-array.cc", "src/hash-table.cc",
            "src/search.cc",       "src/output.cc",    "src/main.cc",       "lib/getline.cc",
            "lib/hash.cc",
        },
    });

    return b.addExecutable(.{ .name = "gperf", .root_module = mod });
}

/// Runs Fontconfig's own generators and places their results in a cached include tree.
/// Python 3 is a build-time requirement. gperf is compiled from its pinned sources above.
fn fontconfigTables(b: *std.Build, source: *std.Build.Dependency, header: std.Build.LazyPath, includes: std.Build.LazyPath) std.Build.LazyPath {
    const files = b.addWriteFiles();
    _ = files.addCopyFile(source.path("src/fcstdint.h.in"), "fcstdint.h");
    const aliases = python(b, source.path("src/makealias.py"));
    aliases.addDirectoryArg(source.path("src"));
    _ = files.addCopyFile(aliases.addOutputFileArg("fcalias.h"), "src/fcalias.h");
    _ = files.addCopyFile(aliases.addOutputFileArg("fcaliastail.h"), "src/fcaliastail.h");
    aliases.addFileArg(header);
    aliases.addFileArg(source.path("src/fcdeprecate.h"));
    aliases.addFileArg(source.path("fontconfig/fcprivate.h"));
    const ft_aliases = python(b, source.path("src/makealias.py"));
    ft_aliases.addDirectoryArg(source.path("src"));
    _ = files.addCopyFile(ft_aliases.addOutputFileArg("fcftalias.h"), "src/fcftalias.h");
    _ = files.addCopyFile(ft_aliases.addOutputFileArg("fcftaliastail.h"), "src/fcftaliastail.h");
    ft_aliases.addFileArg(source.path("fontconfig/fcfreetype.h"));

    const folding = python(b, source.path("fc-case/fc-case.py"));
    folding.addFileArg(source.path("fc-case/CaseFolding.txt"));
    folding.addArg("--template");
    folding.addFileArg(source.path("fc-case/fccase.tmpl.h"));
    folding.addArg("--output");
    _ = files.addCopyFile(folding.addOutputFileArg("fccase.h"), "fc-case/fccase.h");

    // Preserve the upstream language order, which determines indices in the table.
    const languages = b.addSystemCommand(&.{
        "python3", "-c",
        \\import pathlib, re, subprocess, sys
        \\root = pathlib.Path(sys.argv[1])
        \\listing = (root / 'fc-lang/meson.build').read_text().split('orth_files = [', 1)[1].split(']', 1)[0]
        \\names = re.findall(r"'([^']+[.]orth)'", listing)
        \\assert names, 'missing upstream language list'
        \\subprocess.run([sys.executable, str(root / 'fc-lang/fc-lang.py'), *names, '--template', str(root / 'fc-lang/fclang.tmpl.h'), '--directory', str(root / 'fc-lang'), '--output', sys.argv[2]], check=True)
    });
    languages.addDirectoryArg(source.path(""));
    _ = files.addCopyFile(languages.addOutputFileArg("fclang.h"), "fclang.h");
    const constants = python(b, source.path("fc-const/fc-const.py"));
    constants.addFileArg(source.path("fc-const/fcconst.list"));
    constants.addFileArg(source.path("src/fcobjs.h"));
    constants.addArg("--output");
    _ = files.addCopyFile(constants.addOutputFileArg("fcconst.h"), "fcconst.h");

    const preprocess = b.addSystemCommand(&.{ b.graph.zig_exe, "cc", "-E", "-P", "-x", "c" });
    preprocess.addPrefixedDirectoryArg("-I", includes);
    preprocess.addPrefixedDirectoryArg("-I", source.path("src"));
    preprocess.addFileArg(source.path("src/fcobjshash.gperf.h"));
    const cutout = python(b, source.path("src/cutout.py"));
    cutout.addFileArg(preprocess.captureStdOut(.{}));
    const objects = cutout.addOutputFileArg("fcobjshash.gperf");
    const families = python(b, source.path("fc-genericfamily/fc-genericfamily.py"));
    families.addArg("-d");
    families.addDirectoryArg(source.path("fc-genericfamily"));
    families.addArg("-o");
    const family_table = families.addOutputFileArg("fcgenericfamily.gperf");
    const gperf = buildGperf(b);
    inline for (.{ .{ objects, "fcobjshash.h" }, .{ family_table, "fcgenericfamily.h" } }) |input| {
        const generate = b.addRunArtifact(gperf);
        generate.addArgs(&.{ "--pic", "-m", "100" });
        generate.addFileArg(input[0]);
        _ = files.addCopyFile(generate.addPrefixedOutputFileArg("--output-file=", input[1]), input[1]);
    }

    return files.getDirectory();
}

/// Invokes a Python generator from the fetched upstream archive.
fn python(b: *std.Build, script: std.Build.LazyPath) *std.Build.Step.Run {
    const run = b.addSystemCommand(&.{"python3"});
    run.addFileArg(script);

    return run;
}
