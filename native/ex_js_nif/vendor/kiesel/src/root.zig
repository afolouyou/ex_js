pub const build_options = @import("build-options");
pub const builtins = @import("builtins.zig");
pub const execution = @import("execution.zig");
pub const gc = @import("gc.zig");
pub const interpreter = @import("interpreter.zig");
pub const language = @import("language.zig");
pub const types = @import("types.zig");
pub const utils = @import("utils.zig");
pub const zement = @import("zement");

pub const version = build_options.version;

test {
    _ = builtins;
    _ = execution;
    _ = gc;
    _ = interpreter;
    _ = language;
    _ = types;
    _ = utils;
}
