const builtin = @import("builtin");
const std = @import("std");

const icu4zig = @import("icu4zig");
const stackinfo = @import("stackinfo");
const temporal_rs = @import("temporal_rs");

const build_options = @import("build-options");
const gc = @import("../../gc.zig");

const Platform = @This();

gc_allocator: std.mem.Allocator,
gc_allocator_atomic: std.mem.Allocator,
stdout: *std.Io.Writer,
stderr: *std.Io.Writer,
terminal_mode: std.Io.Terminal.Mode,
default_locale: Locale,
default_time_zone: TimeZone,
checkStackOverflow: *const fn () bool,

pub const Locale = if (build_options.enable_intl) icu4zig.Locale else void;
pub const TimeZone = if (build_options.enable_temporal) temporal_rs.c.TimeZone else void;

const State = struct {
    stdout_buffer: [1024]u8,
    stdout_writer: std.Io.File.Writer,
    stderr_buffer: [1024]u8,
    stderr_writer: std.Io.File.Writer,
    stack_info: ?stackinfo.StackInfo,
};

var state: State = undefined;

pub fn default(io: std.Io, environ_map: *const std.process.Environ.Map) Platform {
    if (build_options.enable_libgc) gc.init();
    state = .{
        .stdout_buffer = undefined,
        .stdout_writer = std.Io.File.stdout().writer(io, &state.stdout_buffer),
        .stderr_buffer = undefined,
        .stderr_writer = std.Io.File.stderr().writer(io, &state.stderr_buffer),
        .stack_info = stackinfo.StackInfo.init() catch null,
    };
    const terminal_mode = std.Io.Terminal.Mode.detect(
        io,
        .stderr(),
        environ_map.contains("NO_COLOR"),
        environ_map.contains("CLICOLOR_FORCE"),
    ) catch .no_color;
    return .{
        .gc_allocator = if (build_options.enable_libgc) gc.allocator else std.heap.page_allocator,
        .gc_allocator_atomic = if (build_options.enable_libgc) gc.allocator_atomic else std.heap.page_allocator,
        .stdout = &state.stdout_writer.interface,
        .stderr = &state.stderr_writer.interface,
        .terminal_mode = terminal_mode,
        .default_locale = if (Locale != void) icu4zig.Locale.unknown(),
        .default_time_zone = if (TimeZone != void) temporal_rs.c.temporal_rs_TimeZone_utc(),
        .checkStackOverflow = checkStackOverflowImpl,
    };
}

pub fn deinit(self: *const Platform) void {
    if (Locale != void) self.default_locale.deinit();
}

fn checkStackOverflowImpl() bool {
    const stack_info = state.stack_info orelse return false;
    const remaining_stack = @frameAddress() - stack_info.base;
    // Determined empirically using `kiesel -c '(function f() { f(); })();'` on
    // x86_64-linux-musl and Zig 0.16.0. Observed required minimum values:
    // - debug, stage2_llvm: 116 KB
    // - debug, stage2_x86_64: 49 KB
    // - safe, stage2_llvm: 37 KB
    // - fast, stage2_llvm: 37 KB
    // - small, stage2_llvm: 42 KB
    // Since these will vary a lot across platforms we pad generously.
    const required_stack = switch (builtin.optimize) {
        .debug => 128 * 1024,
        else => 64 * 1024,
    };
    return remaining_stack < required_stack;
}
