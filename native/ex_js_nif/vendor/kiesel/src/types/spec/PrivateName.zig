//! 6.2.12 Private Names
//! https://tc39.es/ecma262/#sec-private-names

const std = @import("std");

const types = @import("../../types.zig");

const String = types.String;
const Symbol = types.Symbol;

const PrivateName = @This();

/// As symbols already have uniqueness via pointers, as well as a description string, private
/// names can easily be implemented using symbols.
/// This should be considered an implementation detail and not relied upon for anything else.
symbol: *const Symbol,

pub fn init(
    allocator: std.mem.Allocator,
    description: *const String,
) std.mem.Allocator.Error!PrivateName {
    const symbol = try allocator.create(Symbol);
    symbol.* = .{ .description = description, .is_private = true };
    return .{ .symbol = symbol };
}

pub fn format(self: PrivateName, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.print("#{f}", .{self.symbol.description.?.fmtRaw()});
}

pub fn hash(self: PrivateName) u64 {
    return std.hash_map.getAutoHashFn(*const Symbol, void)({}, self.symbol);
}

pub fn eql(a: PrivateName, b: PrivateName) bool {
    return a.symbol == b.symbol;
}

pub fn HashMap(comptime V: type) type {
    return std.HashMapUnmanaged(PrivateName, V, struct {
        pub fn hash(_: @This(), private_name: PrivateName) u64 {
            return private_name.hash();
        }

        pub fn eql(_: @This(), a: PrivateName, b: PrivateName) bool {
            return a.eql(b);
        }
    }, std.hash_map.default_max_load_percentage);
}
