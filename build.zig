const std = @import("std");

/// Map an MSS version string to the packed major*10+minor encoding.
fn parseMssVersion(s: []const u8) ?u16 {
    const map = [_]struct { k: []const u8, v: u16 }{
        .{ .k = "3", .v = 30 },   .{ .k = "4", .v = 40 },
        .{ .k = "5", .v = 50 },   .{ .k = "6", .v = 66 },
        .{ .k = "6.0", .v = 60 }, .{ .k = "6.1", .v = 61 },
        .{ .k = "6.5", .v = 65 }, .{ .k = "6.6", .v = 66 },
        .{ .k = "7", .v = 70 },   .{ .k = "8", .v = 80 },
        .{ .k = "9", .v = 90 },
    };
    for (map) |m| {
        if (std.mem.eql(u8, s, m.k)) return m.v;
    }
    return null;
}

const OpenmilesModule = struct {
    mod: *std.Build.Module,
    c_impl: *std.Build.Step.Compile,
    ma: *std.Build.Module,
    tsf: *std.Build.Module,
};

// C sources compile with warnings as errors. The set beyond -Wall -Wextra is
// the correctness and portability groups the tree already passes: -Wpedantic
// for anything outside c99, -Wshadow for a variable that hides another, the
// two prototype groups for declarations that do not match a header, -Wvla for
// stack arrays of unknown size, -Wformat=2 for a format string that does not
// match its arguments, and -Wwrite-strings for a string literal written
// through a mutable pointer.
//
// Three of them need a counter-flag, each for vendored code, never ours:
// -Wno-c11-extensions because tml.h declares an anonymous union, and
// -Wno-format-nonliteral because miniaudio.h passes a format string through a
// parameter. c_impl.c additionally silences -Wnull-pointer-subtraction because
// vendored tsf.h computes struct member offsets via
// ((struct tsf_region*)0)->FIELD pointer math.
const c_flags = [_][]const u8{
    "-std=c99",               "-Wall",               "-Wextra",    "-Werror",
    "-Wpedantic",             "-Wno-c11-extensions", "-Wshadow",   "-Wstrict-prototypes",
    "-Wold-style-definition", "-Wvla",               "-Wformat=2", "-Wno-format-nonliteral",
    "-Wwrite-strings",
};
const c_flags_tsf = c_flags ++ [_][]const u8{"-Wno-null-pointer-subtraction"};

/// Build an (anonymous) openmiles module plus its c_impl object for a given
/// resolved target. Used to produce a musl-targeted copy for the native test
/// executables on a glibc host (see `test_target`).
fn addOpenmilesModule(
    b: *std.Build,
    rtarget: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    build_opts_mod: *std.Build.Module,
) OpenmilesModule {
    const tma = b.addTranslateC(.{ .root_source_file = b.path("deps/miniaudio.h"), .target = rtarget, .optimize = optimize });
    tma.addIncludePath(b.path("deps"));
    const ma = tma.createModule();

    const ttsf = b.addTranslateC(.{ .root_source_file = b.path("deps/tsf_tml.h"), .target = rtarget, .optimize = optimize });
    ttsf.addIncludePath(b.path("deps"));
    const tsf = ttsf.createModule();

    const m = b.createModule(.{ .root_source_file = b.path("src/root.zig"), .target = rtarget, .optimize = optimize });
    m.addIncludePath(b.path("deps"));
    m.addImport("ma_c", ma);
    m.addImport("tsf_c", tsf);
    m.addImport("build_options", build_opts_mod);

    const ci = b.addObject(.{
        .name = "c_impl_test",
        .root_module = b.createModule(.{ .target = rtarget, .optimize = optimize, .link_libc = true }),
    });
    ci.root_module.addIncludePath(b.path("deps"));
    ci.root_module.addCSourceFile(.{ .file = b.path("src/bindings/c_impl.c"), .flags = &c_flags_tsf });

    return .{ .mod = m, .c_impl = ci, .ma = ma, .tsf = tsf };
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The native test executables (the C harnesses + native_rib_test) are real
    // executables that pull the host's C-runtime startup object. On a modern
    // glibc host, crt1.o now carries a .sframe section whose R_X86_64_PC64
    // relocations neither Zig's self-hosted ELF linker nor its bundled LLD can
    // process. Build those test exes against musl instead (Zig ships its own
    // self-contained musl crt), which sidesteps the host crt1.o entirely. Cross
    // targets and the shipped library keep the user-selected target unchanged.
    const host_is_glibc_linux = target.result.os.tag == .linux and target.result.abi == .gnu;
    const test_target = if (host_is_glibc_linux)
        b.resolveTargetQuery(.{ .cpu_arch = target.result.cpu.arch, .os_tag = .linux, .abi = .musl })
    else
        target;

    // The shipped DLL is stripped in every mode (see the lib module below).
    // The other installed artifacts, the C test executables, native_rib_test
    // and the mock plugin, are stripped only outside Debug: an unstripped PE
    // carries a CodeView directory pointing at a PDB whose GUID is derived from
    // the compile directory, so the same source built from two different paths
    // yields different bytes and the build path lands in the CI artifact. A
    // Debug build keeps its symbols so a test panic still names a function.
    const strip_installed = optimize != .Debug;

    // Target MSS version: gates which API groups are compiled/exported so the
    // DLL is ABI-shaped like a specific Miles release. Encoded major*10+minor:
    // 30=3.x, 40=4.x, 50=5.x, 60=6.0, 61=6.1, 65=6.5, 66=6.6, 70=7.x, 80=8.x,
    // 90=9.x (default 9, the newest).
    const mss_version_str = b.option([]const u8, "mss-version", "Target MSS version (3,4,5,6,6.0,6.1,6.5,6.6,7,8,9)") orelse "9";
    const mss_version: u16 = parseMssVersion(mss_version_str) orelse {
        std.debug.print("error: invalid -Dmss-version='{s}'\n", .{mss_version_str});
        std.debug.print("       valid values: 3,4,5,6,6.0,6.1,6.5,6.6,7,8,9\n", .{});
        std.process.exit(2);
    };
    // Run only the tests whose name contains this substring. The full suite
    // takes minutes; this is the edit-test loop for one test.
    const test_filter = b.option([]const u8, "test-filter", "Only run tests whose name contains this substring");
    const test_filters: []const []const u8 = if (test_filter) |f| &.{f} else &.{};

    const build_opts = b.addOptions();
    build_opts.addOption(u16, "mss_version", mss_version);
    build_opts.addOption(bool, "log_by_default", true);
    const build_opts_mod = build_opts.createModule();

    // The test bundle gets its own options module so a Debug test run does not
    // log by default: the suite runs from the repository root, where the
    // appending debug log would reach its 64 MiB cap on every run and bury the
    // test output in engine trace. OPENMILES_DEBUG=1 still turns it on.
    const test_opts = b.addOptions();
    test_opts.addOption(u16, "mss_version", mss_version);
    test_opts.addOption(bool, "log_by_default", false);
    const test_opts_mod = test_opts.createModule();

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
            // The DLL is the shipped artifact, so it must not ship without a
            // stack canary. Zig 0.16 rejects -fstack-protector outright on
            // x86_64 Linux ("the selected target does not support stack
            // protection"), so scope it to the Windows targets that accept it
            // rather than breaking the native build the tests run on.
            .stack_protector = if (target.result.os.tag == .windows) true else null,
            // ReleaseFast optimizes, but the linked image still carries a
            // CodeView directory pointing at a PDB whose GUID is derived from
            // the compile directory, so two builds of one commit at different
            // paths produce different DLL bytes. Stripping drops the directory,
            // which is what makes the shipped artifact path independent.
            .strip = true,
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
            .stack_protector = if (target.result.os.tag == .windows) true else null,
        }),
    });
    c_impl.root_module.addIncludePath(b.path("deps"));
    c_impl.root_module.addCSourceFile(.{
        .file = b.path("src/bindings/c_impl.c"),
        .flags = &c_flags_tsf,
    });

    lib.root_module.addObject(c_impl);

    b.installArtifact(lib);

    // Tests. The Zig test runners are real executables that link libc, so on a
    // glibc host they would pull the host crt1.o whose .sframe relocations the
    // linker can't process. Build them against the musl test_target instead
    // (same rationale as the C test exes / native_rib_test above), which needs
    // an openmiles module + translate-C + c_impl resolved for that target.
    // The module is built for the test bundle on every host, not just a glibc
    // one: it is what gives the tests their own build_options (log_by_default
    // off), which reusing the library module would silently skip.
    const tb = addOpenmilesModule(b, test_target, optimize, test_opts_mod);

    const mod_tests = b.addTest(.{
        .filters = test_filters,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/test_root.zig"),
            .target = test_target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "ma_c", .module = tb.ma },
                .{ .name = "tsf_c", .module = tb.tsf },
                // Share the same openmiles module the api wrappers import, so
                // test code and AIL_* exports exchange identical types.
                .{ .name = "openmiles", .module = tb.mod },
                .{ .name = "build_options", .module = test_opts_mod },
            },
        }),
    });
    mod_tests.root_module.addIncludePath(b.path("deps"));
    mod_tests.root_module.addIncludePath(b.path("src"));
    mod_tests.root_module.addObject(tb.c_impl);

    const run_mod_tests = b.addRunArtifact(mod_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);

    // Engine-internal unit tests: run the `test` blocks that live inside the
    // openmiles module itself (e.g. callback-ABI regression tests sitting next
    // to the private bridges they exercise). A file may belong to only one
    // module, so these cannot be pulled into test_root — they get their own
    // test artifact rooted at the same source as the openmiles module.
    const engine_c_impl = b.addObject(.{
        .name = "engine_c_impl",
        .root_module = b.createModule(.{
            .target = test_target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    engine_c_impl.root_module.addIncludePath(b.path("deps"));
    engine_c_impl.root_module.addCSourceFile(.{
        .file = b.path("src/bindings/c_impl.c"),
        .flags = &c_flags_tsf,
    });
    const engine_tests = b.addTest(.{
        .filters = test_filters,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/engine_test_root.zig"),
            .target = test_target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "ma_c", .module = tb.ma },
                .{ .name = "tsf_c", .module = tb.tsf },
                .{ .name = "build_options", .module = test_opts_mod },
            },
        }),
    });
    engine_tests.root_module.addIncludePath(b.path("deps"));
    engine_tests.root_module.addIncludePath(b.path("src"));
    engine_tests.root_module.addObject(engine_c_impl);
    const run_engine_tests = b.addRunArtifact(engine_tests);
    test_step.dependOn(&run_engine_tests.step);

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
                .target = test_target,
                .optimize = optimize,
                .link_libc = true,
            }),
        });
        obj.root_module.addCSourceFile(.{
            .file = b.path(t.source),
            .flags = &c_flags,
        });
        obj.root_module.addIncludePath(b.path("src"));

        const exe = b.addExecutable(.{
            .name = b.fmt("{s}", .{t.name}),
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/empty.zig"),
                .target = test_target,
                .optimize = optimize,
                .link_libc = true,
                .strip = strip_installed,
            }),
        });
        exe.root_module.addObject(obj);
        b.installArtifact(exe);
    }

    // Mock ASI (Audio Stream Interface) plugin for testing plugin discovery/loading.
    // Built for test_target (not the user-selected target): its only consumers
    // are the musl-resolved test executables below, and a libc mismatch shows
    // up as unrelocated data pointers crashing inside RIB_Main callbacks.
    const mock_root_step = b.addWriteFile("mock_root.zig", "");
    const mock_asi = b.addLibrary(.{
        .name = "mock",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = mock_root_step.add("mock_root.zig", ""),
            .target = test_target,
            .optimize = optimize,
            .link_libc = true,
            .strip = strip_installed,
        }),
    });
    mock_asi.root_module.addCSourceFile(.{
        .file = b.path("src/bindings/mock_asi.c"),
        .flags = &c_flags,
    });
    // Install as mock.asi (renamed via dest_sub_path): plugin discovery only
    // considers *.asi/*.m3d/*.flt names (isPluginExtension), so the platform
    // default output name (libmock.so / mock.dll) would never even be probed.
    const install_mock = b.addInstallArtifact(mock_asi, .{
        .dest_dir = .{ .override = .{ .custom = "bin/plugins" } },
        .dest_sub_path = "mock.asi",
    });
    b.getInstallStep().dependOn(&install_mock.step);
    // The plugin-loading test reads zig-out/bin/plugins/mock.asi from disk. A
    // cross-compile (-Dtarget=x86-windows) installs a PE image under that same
    // path, so the test step must re-install its own-target copy first or the
    // dlopen fails with NotElfFile after any Windows build.
    test_step.dependOn(&install_mock.step);

    // Native RIB test. Reuses the musl-resolved test bundle (tb) so on a glibc
    // host it avoids the crt1.o .sframe relocation the linker can't handle.
    const native_rib_test = b.addExecutable(.{
        .name = "native_rib_test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/native_rib_test.zig"),
            .target = test_target,
            .optimize = optimize,
            .link_libc = true,
            .strip = strip_installed,
            .imports = &.{
                .{ .name = "openmiles", .module = tb.mod },
            },
        }),
    });
    native_rib_test.root_module.addIncludePath(b.path("deps"));
    native_rib_test.root_module.addIncludePath(b.path("src"));
    native_rib_test.root_module.addObject(tb.c_impl);
    b.installArtifact(native_rib_test);

    // Install the test media (WAV/MIDI/SoundFont) next to the test exes so the
    // harnesses find them relative to their own directory (they look up
    // test_media/test.{wav,mid,sf2}). The directory is gitignored ("provide
    // your own"), so skip the install when it is absent instead of failing the
    // build on machines without the fixtures (e.g. CI). Say which of the two
    // happened: the install tree differs, and a silently fixture-less build
    // reads as a passing one.
    if (std.Io.Dir.cwd().access(b.graph.io, "test_media", .{})) |_| {
        b.installDirectory(.{
            .source_dir = b.path("test_media"),
            .install_dir = .bin,
            .install_subdir = "test_media",
        });
    } else |_| {
        std.debug.print("note: test_media/ not found, test fixtures are not installed\n", .{});
    }
}
