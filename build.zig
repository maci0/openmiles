const std = @import("std");

/// Map an MSS version string to the packed major*10+minor encoding.
fn parseMssVersion(s: []const u8) ?u16 {
    const map = [_]struct { k: []const u8, v: u16 }{
        .{ .k = "3", .v = 30 },   .{ .k = "4", .v = 40 },
        .{ .k = "5", .v = 50 },   .{ .k = "6", .v = 66 },
        .{ .k = "6.0", .v = 60 }, .{ .k = "6.1", .v = 61 },
        .{ .k = "6.5", .v = 65 }, .{ .k = "6.6", .v = 66 },
    };
    for (map) |m| {
        if (std.mem.eql(u8, s, m.k)) return m.v;
    }
    return null;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Target MSS version: gates which API groups are compiled/exported so the
    // DLL is ABI-shaped like a specific Miles release. Encoded major*10+minor:
    // 30=3.x, 40=4.x, 50=5.x, 60=6.0, 61=6.1, 65=6.5, 66=6.6 (default newest).
    const mss_version_str = b.option([]const u8, "mss-version", "Target MSS version (3,4,5,6,6.0,6.1,6.5,6.6)") orelse "6.6";
    const mss_version: u16 = parseMssVersion(mss_version_str) orelse {
        std.debug.print("invalid -Dmss-version='{s}' (use 3,4,5,6,6.0,6.1,6.5,6.6)\n", .{mss_version_str});
        std.process.exit(1);
    };
    const build_opts = b.addOptions();
    build_opts.addOption(u16, "mss_version", mss_version);
    const build_opts_mod = build_opts.createModule();

    // Translate C headers into Zig modules (replaces inline @cImport).
    const translate_ma = b.addTranslateC(.{
        .root_source_file = b.path("deps/miniaudio.h"),
        .target = target,
        .optimize = optimize,
    });
    translate_ma.addIncludePath(b.path("deps"));
    const ma_mod = translate_ma.createModule();

    const translate_tsf = b.addTranslateC(.{
        .root_source_file = b.path("deps/tsf_tml.h"),
        .target = target,
        .optimize = optimize,
    });
    translate_tsf.addIncludePath(b.path("deps"));
    const tsf_mod = translate_tsf.createModule();

    // Main OpenMiles module
    const mod = b.addModule("openmiles", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addIncludePath(b.path("deps"));
    mod.addImport("ma_c", ma_mod);
    mod.addImport("tsf_c", tsf_mod);
    mod.addImport("build_options", build_opts_mod);

    // Shared Library: drop-in replacement for mss32.dll (Miles Sound System)
    const lib = b.addLibrary(.{
        .name = "mss32",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "openmiles", .module = mod },
                .{ .name = "build_options", .module = build_opts_mod },
            },
            .link_libc = true,
        }),
    });

    lib.root_module.addIncludePath(b.path("deps"));
    lib.root_module.addIncludePath(b.path("src"));

    const c_impl = b.addObject(.{
        .name = "c_impl",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    c_impl.root_module.addIncludePath(b.path("deps"));
    c_impl.root_module.addCSourceFile(.{
        .file = b.path("src/bindings/c_impl.c"),
        .flags = &.{"-std=c99"},
    });

    lib.root_module.addObject(c_impl);

    b.installArtifact(lib);

    // Tests
    const mod_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/test_root.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "ma_c", .module = ma_mod },
                .{ .name = "tsf_c", .module = tsf_mod },
                // Share the same openmiles module the api wrappers import, so
                // test code and AIL_* exports exchange identical types.
                .{ .name = "openmiles", .module = mod },
                .{ .name = "build_options", .module = build_opts_mod },
            },
        }),
    });
    mod_tests.root_module.addIncludePath(b.path("deps"));
    mod_tests.root_module.addIncludePath(b.path("src"));
    mod_tests.root_module.addObject(c_impl);

    const run_mod_tests = b.addRunArtifact(mod_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);

    // C test executables
    const c_tests = [_]struct { name: []const u8, source: []const u8 }{
        .{ .name = "play_test", .source = "tests/play_test.c" },
        .{ .name = "midi_test", .source = "tests/midi_test.c" },
        .{ .name = "full_suite", .source = "tests/full_suite.c" },
        .{ .name = "rib_test", .source = "tests/rib_test.c" },
    };
    for (c_tests) |t| {
        const obj = b.addObject(.{
            .name = b.fmt("{s}_obj", .{t.name}),
            .root_module = b.createModule(.{
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            }),
        });
        obj.root_module.addCSourceFile(.{
            .file = b.path(t.source),
            .flags = &.{"-std=c99"},
        });
        obj.root_module.addIncludePath(b.path("src"));

        const exe = b.addExecutable(.{
            .name = b.fmt("{s}", .{t.name}),
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/empty.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            }),
        });
        exe.root_module.addObject(obj);
        b.installArtifact(exe);
    }

    // Mock ASI (Audio Stream Interface) plugin for testing plugin discovery/loading
    const mock_root_step = b.addWriteFile("mock_root.zig", "");
    const mock_asi = b.addLibrary(.{
        .name = "mock",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = mock_root_step.add("mock_root.zig", ""),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    mock_asi.root_module.addCSourceFile(.{
        .file = b.path("src/bindings/mock_asi.c"),
        .flags = &.{"-std=c99"},
    });
    // Install to bin/plugins/ (output name depends on platform: mock.dll, libmock.so, etc.)
    const install_mock = b.addInstallArtifact(mock_asi, .{
        .dest_dir = .{ .override = .{ .custom = "bin/plugins" } },
    });
    b.getInstallStep().dependOn(&install_mock.step);

    // Native RIB test
    const native_rib_test = b.addExecutable(.{
        .name = "native_rib_test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/native_rib_test.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "openmiles", .module = mod },
            },
        }),
    });
    native_rib_test.root_module.addIncludePath(b.path("deps"));
    native_rib_test.root_module.addIncludePath(b.path("src"));
    native_rib_test.root_module.addObject(c_impl);
    b.installArtifact(native_rib_test);
}
