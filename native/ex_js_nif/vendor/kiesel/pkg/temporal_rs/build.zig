const std = @import("std");

const Translator = @import("translate_c").Translator;

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const temporal_rs = b.dependency("temporal_rs", .{});
    const translate_c = b.dependency("translate_c", .{});

    const c: Translator = .init(translate_c, .{
        .c_source_file = b.path("src/c.h"),
        .target = target,
        .optimize = optimize,
        .default_init = true,
    });
    c.addIncludePath(temporal_rs.path("temporal_capi/bindings/c"));

    _ = b.addModule("temporal_rs", .{
        .root_source_file = b.path("src/root.zig"),
        .imports = &.{
            .{ .name = "c", .module = c.mod },
        },
        .target = target,
        .optimize = optimize,
    });
}
