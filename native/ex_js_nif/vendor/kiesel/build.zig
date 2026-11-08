const builtin = @import("builtin");
const std = @import("std");

const manifest = @import("build.zig.zon");

const kiesel_version = std.SemanticVersion.parse(manifest.version) catch unreachable;

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Stop people from trying to build with an outdated Zig compiler
    if (builtin.zig_version.order(.{ .major = 0, .minor = 17, .patch = 0, .pre = "dev" }) == .lt) {
        std.debug.print("\n    {s}\n    {s}\n\n", .{
            "Zig version 0.17.0 is required, found " ++ builtin.zig_version_string ++ ".",
            "Please \u{1B}]8;;https://ziglang.org/download/\u{1B}\\download\u{1B}]8;;\u{1B}\\ or otherwise install a newer build and try again.",
        });
        std.process.exit(1);
    }

    const enable_annex_b = b.option(
        bool,
        "enable-annex-b",
        "Enable Annex B features",
    ) orelse true;
    const enable_intl = b.option(
        bool,
        "enable-intl",
        "Enable the Intl built-in object (requires cargo)",
    ) orelse true;
    const enable_legacy = b.option(
        bool,
        "enable-legacy",
        "Enable features marked as 'Legacy' in the spec",
    ) orelse true;
    const enable_libgc = b.option(
        bool,
        "enable-libgc",
        "Enable building with libgc",
    ) orelse true;
    const enable_libregexp = b.option(
        bool,
        "enable-libregexp",
        "Enable building with libregexp",
    ) orelse true;
    const enable_nan_boxing = b.option(
        bool,
        "enable-nan-boxing",
        "Enable NaN-boxing (requires a maximum of 48 bits of addressable memory and enabled by default on x86_64 and aarch64)",
    ) orelse switch (target.result.cpu.arch) {
        .x86_64, .aarch64 => true,
        else => false,
    };
    const enable_temporal = b.option(
        bool,
        "enable-temporal",
        "Enable the Temporal built-in object (requires cargo)",
    ) orelse true;

    const strip = b.option(bool, "strip", "Strip debug symbols") orelse (optimize != .debug);
    // Defaults to true for now as the self-hosted backend in 0.17 fails with a linker error.
    const use_llvm = b.option(bool, "use-llvm", "Use the LLVM backend") orelse true;
    const maybe_version_string = b.option([]const u8, "version-string", "Version string, read from git by default");

    // https://codeberg.org/ziglang/zig/src/commit/9787df9421ad9d3fcb08cc7b394656542b16cfae/build.zig#L254-L309
    const version_string = maybe_version_string orelse v: {
        const version_string = b.fmt("{d}.{d}.{d}", .{ kiesel_version.major, kiesel_version.minor, kiesel_version.patch });

        var code: u8 = undefined;
        const git_describe_untrimmed = b.runAllowFail(&.{
            "git",
            "-C", b.fmt("{f}", .{b.root}), // affects the --git-dir argument
            "--git-dir", ".git", // affected by the -C argument
            "describe", "--match",    "*.*.*", //
            "--tags",   "--abbrev=9",
        }, &code, .ignore) catch {
            break :v version_string;
        };
        const git_describe = std.mem.trim(u8, git_describe_untrimmed, " \n\r");

        switch (std.mem.countScalar(u8, git_describe, '-')) {
            0 => {
                // Tagged release version (e.g. 0.10.0).
                if (!std.mem.eql(u8, git_describe, version_string)) {
                    std.debug.print("Kiesel version '{s}' does not match Git tag '{s}'\n", .{ version_string, git_describe });
                    std.process.exit(1);
                }
                break :v version_string;
            },
            2 => {
                // Untagged development build (e.g. 0.10.0-dev.2025+ecf0050a9).
                var it = std.mem.splitScalar(u8, git_describe, '-');
                const tagged_ancestor = it.first();
                const commit_height = it.next().?;
                const commit_id = it.next().?;

                const ancestor_ver = try std.SemanticVersion.parse(tagged_ancestor);
                if (kiesel_version.order(ancestor_ver) != .gt) {
                    std.debug.print("Kiesel version '{f}' must be greater than tagged ancestor '{f}'\n", .{ kiesel_version, ancestor_ver });
                    std.process.exit(1);
                }

                // Check that the commit hash is prefixed with a 'g' (a Git convention).
                if (commit_id.len < 1 or commit_id[0] != 'g') {
                    std.debug.print("Unexpected `git describe` output: {s}\n", .{git_describe});
                    break :v version_string;
                }

                // The version is reformatted in accordance with the https://semver.org specification.
                break :v b.fmt("{s}-dev.{s}+{s}", .{ version_string, commit_height, commit_id[1..] });
            },
            else => {
                std.debug.print("Unexpected `git describe` output: {s}\n", .{git_describe});
                break :v version_string;
            },
        }
    };
    const version = std.SemanticVersion.parse(version_string) catch {
        std.debug.print("Invalid version string: {s}\n", .{version_string});
        std.process.exit(1);
    };

    const options = b.addOptions();
    options.addOption(bool, "enable_annex_b", enable_annex_b);
    options.addOption(bool, "enable_intl", enable_intl);
    options.addOption(bool, "enable_legacy", enable_legacy);
    options.addOption(bool, "enable_libgc", enable_libgc);
    options.addOption(bool, "enable_libregexp", enable_libregexp);
    options.addOption(bool, "enable_nan_boxing", enable_nan_boxing);
    options.addOption(bool, "enable_temporal", enable_temporal);
    options.addOption(std.SemanticVersion, "version", version);

    const args = b.dependency("args", .{});
    const known_folders = b.dependency("known_folders", .{});
    const parser_toolkit = b.dependency("parser_toolkit", .{});
    const stackinfo = b.dependency("stackinfo", .{ .target = target });
    const unicode_id = b.dependency("unicode_id", .{});
    const zigline = b.dependency("zigline", .{});

    const kiesel = b.addModule("kiesel", .{
        .root_source_file = b.path("src/root.zig"),
        .imports = &.{
            .{ .name = "build-options", .module = options.createModule() },
            .{ .name = "ptk", .module = parser_toolkit.module("parser-toolkit") },
            .{ .name = "stackinfo", .module = stackinfo.module("stackinfo") },
            .{ .name = "unicode-id", .module = unicode_id.module("unicode-id") },
        },
        .target = target,
        .optimize = optimize,
    });

    if (enable_intl) {
        if (b.lazyDependency("icu4zig", .{
            .target = target,
            .optimize = optimize,
            .@"link-icu4x" = false,
        })) |icu4zig| {
            kiesel.addImport("icu4zig", icu4zig.module("icu4zig"));
        }
    }

    if (enable_libgc) {
        const cflags_extra: []const u8 = blk: {
            var cflags: std.ArrayList([]const u8) = .empty;
            defer cflags.deinit(b.allocator);
            try cflags.append(b.allocator, "-DNO_MSGBOX_ON_ERROR");
            if (optimize != .debug) {
                try cflags.append(b.allocator, "-DNO_GETENV");
            }
            // bdwgc references `__data_start` when targeting OpenBSD, but only their patched
            // ld/lld ports provide it. See: https://codeberg.org/ziglang/zig/issues/32004
            if (target.result.os.tag == .openbsd) {
                try cflags.append(b.allocator, "-DSEARCH_FOR_DATA_START");
            }
            break :blk try std.mem.join(b.allocator, " ", cflags.items);
        };
        if (b.lazyDependency("bdwgc_zig", .{
            .target = target,
            .optimize = optimize,
            .linkage = .static,
            .CFLAGS_EXTRA = cflags_extra,
            .enable_gcj_support = false,
            .enable_java_finalization = false,
            .enable_large_config = true,
            .enable_gc_dump = false,
            .enable_dynamic_pointer_mask = enable_nan_boxing,
        })) |bdwgc| {
            kiesel.addImport("bdwgc", bdwgc.module("bdwgc"));
        }
    }

    if (enable_libregexp) {
        if (b.lazyDependency("libregexp", .{
            .target = target,
            .optimize = optimize,
        })) |libregexp| {
            kiesel.addImport("libregexp", libregexp.module("libregexp"));
        }
    }

    if (enable_temporal) {
        if (b.lazyDependency("temporal_rs", .{
            .target = target,
            .optimize = optimize,
        })) |temporal_rs| {
            kiesel.addImport("temporal_rs", temporal_rs.module("temporal_rs"));
        }
    }

    if (enable_intl or enable_temporal) {
        if (b.lazyDependency("zement", .{
            .target = target,
            .optimize = optimize,
            .@"enable-intl" = enable_intl,
            .@"enable-temporal" = enable_temporal,
        })) |zement| {
            kiesel.addImport("zement", zement.module("zement"));
        }
    }

    const exe = b.addExecutable(.{
        .name = "kiesel",
        .root_module = blk: {
            const module = b.createModule(.{
                .root_source_file = b.path("src/cli.zig"),
                .imports = &.{
                    .{ .name = "args", .module = args.module("args") },
                    .{ .name = "kiesel", .module = kiesel },
                    .{ .name = "known-folders", .module = known_folders.module("known-folders") },
                    .{ .name = "zigline", .module = zigline.module("zigline") },
                },
                .target = target,
                .optimize = optimize,
                .strip = strip,
            });
            // Use musl's optimized memset until Zig's compiler_rt implementations have
            // comparable performance. See: https://codeberg.org/ziglang/zig/issues/32091
            if (target.result.os.tag == .linux) {
                if (b.lazyDependency("musl", .{})) |musl| {
                    switch (target.result.cpu.arch) {
                        .aarch64 => module.addAssemblyFile(musl.path("src/string/aarch64/memset.S")),
                        .arm => module.addAssemblyFile(musl.path("src/string/arm/__aeabi_memset.s")),
                        .x86 => module.addAssemblyFile(musl.path("src/string/i386/memset.s")),
                        .x86_64 => module.addAssemblyFile(musl.path("src/string/x86_64/memset.s")),
                        else => {},
                    }
                }
            }
            if (enable_intl) {
                if (b.lazyDependency("icu4zig", .{
                    .target = target,
                    .optimize = optimize,
                    .@"link-icu4x" = false,
                })) |icu4zig| {
                    module.addImport("icu4zig", icu4zig.module("icu4zig"));
                }
            }
            if (enable_temporal) {
                if (b.lazyDependency("temporal_rs", .{
                    .target = target,
                    .optimize = optimize,
                })) |temporal_rs| {
                    module.addImport("temporal_rs", temporal_rs.module("temporal_rs"));
                }
            }
            break :blk module;
        },
        .use_llvm = use_llvm,
    });

    const install_exe = b.addInstallArtifact(exe, .{});
    b.getInstallStep().dependOn(&install_exe.step);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const unit_tests = b.addTest(.{
        .root_module = kiesel,
        .use_llvm = use_llvm,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    const fuzz = b.addTest(.{
        .name = "fuzz",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/fuzz.zig"),
            .imports = &.{
                .{ .name = "unicode-id", .module = unicode_id.module("unicode-id") },
            },
            .target = target,
            .optimize = optimize,
        }),
        .use_llvm = use_llvm,
    });
    const run_fuzz = b.addRunArtifact(fuzz);

    const fuzz_step = b.step("fuzz", "Run fuzz tests");
    fuzz_step.dependOn(&run_fuzz.step);

    const docs = b.addObject(.{
        .name = "kiesel",
        .root_module = kiesel,
    });
    const install_docs = b.addInstallDirectory(.{
        .source_dir = docs.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });

    const docs_step = b.step("docs", "Build and install documentation");
    docs_step.dependOn(&install_docs.step);

    const fuzzilli = b.addExecutable(.{
        .name = "kiesel-fuzzilli",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/fuzzilli/main.zig"),
            .imports = &.{
                .{ .name = "kiesel", .module = kiesel },
            },
            .link_libc = true,
            .target = target,
            .optimize = optimize,
            .strip = strip,
        }),
        .use_llvm = use_llvm,
    });
    fuzzilli.sanitize_coverage_trace_pc_guard = true;

    const fuzzilli_step = b.step("fuzzilli", "Build and install fuzzilli shell");
    fuzzilli_step.dependOn(&b.addInstallArtifact(fuzzilli, .{}).step);

    const update_expectations = b.addExecutable(.{
        .name = "update-expectations",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/interpreter/update_expectations.zig"),
            .imports = &.{
                .{ .name = "kiesel", .module = kiesel },
            },
            .target = target,
            .optimize = optimize,
        }),
        .use_llvm = use_llvm,
    });

    const run_update_expectations = b.addRunArtifact(update_expectations);
    run_update_expectations.addArg("src/interpreter/test_cases.zon");

    const update_expectations_step = b.step("update-expectations", "Update test expectations");
    update_expectations_step.dependOn(&run_update_expectations.step);
}
