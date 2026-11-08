const types = @import("../../types.zig");

const Value = types.Value;

const Arguments = @This();

values: []const Value,

pub fn from(values: []const Value) Arguments {
    return .{ .values = values };
}

pub fn count(self: Arguments) usize {
    return self.values.len;
}

pub fn get(self: Arguments, index: usize) Value {
    return self.getOrNull(index) orelse .undefined;
}

pub fn getOrNull(self: Arguments, index: usize) ?Value {
    return if (self.count() > index) self.values[index] else null;
}
