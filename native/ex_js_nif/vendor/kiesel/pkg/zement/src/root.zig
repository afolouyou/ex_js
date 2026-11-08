const std = @import("std");

extern fn zement_rustc_version() [*:0]const u8;

pub fn rustcVersion() []const u8 {
    return std.mem.sliceTo(zement_rustc_version(), 0);
}
