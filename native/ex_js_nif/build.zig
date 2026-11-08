const std = @import("std");
const Translator = @import("translate_c").Translator;

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const sanitize = b.option(bool, "sanitize", "Enable ASan/UBSan (development only)") orelse false;

    const enable_nan_boxing = switch (target.result.cpu.arch) {
        .x86_64, .aarch64 => true,
        else => false,
    };

    // KIESEL_PATH (via the `kiesel_src` symlink created by the Mix task) takes
    // precedence over the vendored copy, so development can target a checkout.
    const kiesel_src: []const u8 = blk: {
        const io = std.Io.Threaded.global_single_threaded.io();
        if (std.Io.Dir.cwd().access(io, "kiesel_src/src/root.zig", .{})) |_| {
            break :blk "kiesel_src";
        } else |_| {}
        break :blk "vendor/kiesel";
    };

    // Build options module for Kiesel (Intl/Temporal disabled; we don't want a Rust dependency).
    const options = b.addOptions();
    options.addOption(bool, "enable_annex_b", true);
    options.addOption(bool, "enable_intl", false);
    options.addOption(bool, "enable_legacy", true);
    options.addOption(bool, "enable_libgc", true);
    options.addOption(bool, "enable_libregexp", true);
    options.addOption(bool, "enable_nan_boxing", enable_nan_boxing);
    options.addOption(bool, "enable_temporal", false);
    options.addOption(std.SemanticVersion, "version", .{ .major = 0, .minor = 5, .patch = 0 });

    // Non-lazy dependencies that Kiesel always needs.
    const parser_toolkit = b.dependency("parser_toolkit", .{});
    const stackinfo = b.dependency("stackinfo", .{ .target = target });
    const unicode_id = b.dependency("unicode_id", .{});

    // libregexp is required by Kiesel's RegExp built-ins. It bundles
    // QuickJS' regexp sources and translates them to Zig.
    const quickjs = b.dependency("quickjs", .{});
    const translate_c = b.dependency("translate_c", .{});

    const regexp_root = try std.fmt.allocPrint(b.allocator, "{s}/pkg/libregexp", .{kiesel_src});

    const regexp_translate: Translator = .init(translate_c, .{
        .c_source_file = b.path(try std.fmt.allocPrint(
            b.allocator,
            "{s}/src/c.h",
            .{regexp_root},
        )),
        .target = target,
        .optimize = optimize,
    });
    regexp_translate.addIncludePath(quickjs.path("."));

    const libregexp = b.addModule("libregexp", .{
        .root_source_file = b.path(try std.fmt.allocPrint(
            b.allocator,
            "{s}/src/root.zig",
            .{regexp_root},
        )),
        .imports = &.{
            .{ .name = "c", .module = regexp_translate.mod },
        },
        .target = target,
        .optimize = optimize,
    });
    libregexp.addCSourceFiles(.{
        .root = quickjs.path("."),
        .files = &.{
            "cutils.c",
            "libregexp.c",
            "libunicode.c",
        },
    });

    const kiesel_module = b.createModule(.{
        .root_source_file = b.path(try std.fmt.allocPrint(
            b.allocator,
            "{s}/src/root.zig",
            .{kiesel_src},
        )),
        .imports = &.{
            .{ .name = "build-options", .module = options.createModule() },
            .{ .name = "ptk", .module = parser_toolkit.module("parser-toolkit") },
            .{ .name = "stackinfo", .module = stackinfo.module("stackinfo") },
            .{ .name = "unicode-id", .module = unicode_id.module("unicode-id") },
            .{ .name = "libregexp", .module = libregexp },
        },
        .target = target,
        .optimize = optimize,
    });

    // Boehm-Demers-Weiser GC, used by Kiesel's runtime.
    const cflags_extra: []const u8 = blk: {
        var cflags: std.ArrayList([]const u8) = .empty;
        defer cflags.deinit(b.allocator);
        try cflags.append(b.allocator, "-DNO_MSGBOX_ON_ERROR");
        if (optimize != .debug) {
            try cflags.append(b.allocator, "-DNO_GETENV");
        }
        break :blk try std.mem.join(b.allocator, " ", cflags.items);
    };

    const bdwgc = b.lazyDependency("bdwgc_zig", .{
        .target = target,
        .optimize = optimize,
        .linkage = .static,
        .CFLAGS_EXTRA = cflags_extra,
        .enable_gcj_support = false,
        .enable_java_finalization = false,
        .enable_large_config = true,
        .enable_gc_dump = false,
        .enable_dynamic_pointer_mask = enable_nan_boxing,
    }) orelse {
        std.debug.print("Error: bdwgc_zig dependency was not fetched.\n", .{});
        std.process.exit(1);
    };

    kiesel_module.addImport("bdwgc", bdwgc.module("bdwgc"));

    // Translate erl_nif.h to Zig (Zig 0.17 removed @cImport).
    // `erl_include` is a relative symlink to the Erlang include directory,
    // created by the Mix task.
    const erl_nif = b.addTranslateC(.{
        .root_source_file = b.path("erl_include/erl_nif.h"),
        .target = target,
        .optimize = optimize,
    });

    const nif = b.addLibrary(.{
        .name = "ex_js_nif",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .sanitize_c = if (sanitize) .full else null,
        }),
    });

    nif.root_module.addImport("kiesel", kiesel_module);
    nif.root_module.addImport("erl_nif", erl_nif.createModule());

    const install_step = b.addInstallArtifact(nif, .{
        .dest_dir = .{ .override = .{ .custom = "../../../priv" } },
    });

    b.default_step.dependOn(&install_step.step);
}
