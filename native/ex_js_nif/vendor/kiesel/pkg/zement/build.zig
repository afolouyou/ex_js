const std = @import("std");

const build_crab = @import("build_crab");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const enable_intl = b.option(bool, "enable-intl", "Enable Intl") orelse true;
    const enable_temporal = b.option(bool, "enable-temporal", "Enable Temporal") orelse true;

    const features = blk: {
        var features: std.ArrayList([]const u8) = .empty;
        defer features.deinit(b.allocator);
        if (enable_intl) {
            features.append(b.allocator, "intl") catch @panic("OOM");
        }
        if (enable_temporal) {
            features.append(b.allocator, "temporal") catch @panic("OOM");
        }
        break :blk (std.mem.join(b.allocator, ",", features.items) catch @panic("OOM"));
    };

    var cargo_args: std.ArrayList([]const u8) = .empty;
    defer cargo_args.deinit(b.allocator);
    cargo_args.appendSlice(b.allocator, &.{ "--features", features }) catch @panic("OOM");
    if (optimize != .debug) {
        cargo_args.append(b.allocator, "--release") catch @panic("OOM");
    }

    const build_dir = build_crab.addCargoBuild(
        b,
        .{
            .manifest_path = b.path("Cargo.toml"),
            .cargo_args = cargo_args.items,
        },
        .{
            .target = target,
            .optimize = .safe,
        },
    );

    const zement = b.addModule("zement", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const unwind_stubs = b.addLibrary(.{
        .linkage = .static,
        .name = "unwind_stubs",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/unwind_stubs.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // NOTE: Rust outputs 'libzement.a' instead of 'zement.lib' when targeting
    // *-pc-windows-gnu, so we can hardcode the name here instead of using
    // `std.zig.binNameAlloc()` to select a target-dependent prefix and extension.
    // See: https://github.com/rust-lang/rust/pull/70937
    zement.addObjectFile(build_dir.path(b, "libzement.a"));
    // icu4zig provides its own copies of these symbols so we link them as a
    // static library which will only include them if needed.
    zement.linkLibrary(unwind_stubs);

    // NOTE: Empirically these are not needed in release builds, presumably due to LTO.
    if (target.result.os.tag == .windows and optimize == .debug) {
        // For GetUserProfileDirectoryW
        zement.linkSystemLibrary("userenv", .{});
        // For a bunch of networking APIs
        zement.linkSystemLibrary("ws2_32", .{});
    }
}
