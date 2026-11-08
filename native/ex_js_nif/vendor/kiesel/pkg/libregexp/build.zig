const std = @import("std");

const Translator = @import("translate_c").Translator;

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const quickjs = b.dependency("quickjs", .{});
    const translate_c = b.dependency("translate_c", .{});

    const c: Translator = .init(translate_c, .{
        .c_source_file = b.path("src/c.h"),
        .target = target,
        .optimize = optimize,
    });
    c.addIncludePath(quickjs.path("."));

    const module = b.addModule("libregexp", .{
        .root_source_file = b.path("src/root.zig"),
        .imports = &.{
            .{ .name = "c", .module = c.mod },
        },
        .target = target,
        .optimize = optimize,
    });
    module.addCSourceFiles(.{
        .root = quickjs.path("."),
        .files = &.{
            "cutils.c",
            "libregexp.c",
            "libunicode.c",
        },
    });
}
