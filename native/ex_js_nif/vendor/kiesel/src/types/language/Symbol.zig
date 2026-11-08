//! 6.1.5 The Symbol Type
//! https://tc39.es/ecma262/#sec-ecmascript-language-types-symbol-type

const std = @import("std");

const execution = @import("../../execution.zig");
const types = @import("../../types.zig");

const Agent = execution.Agent;
const String = types.String;

const Symbol = @This();

/// Flag to mark this symbol as a private name.
is_private: bool = false,

/// [[Description]]
description: ?*const String,

pub fn init(
    agent: *Agent,
    description: ?*const String,
) std.mem.Allocator.Error!*const Symbol {
    const symbol = try agent.gc_allocator.create(Symbol);
    symbol.* = .{ .description = description };
    return symbol;
}

pub inline fn initComptime(comptime description: ?*const String) *const Symbol {
    comptime {
        const symbol: Symbol = .{ .description = description };
        return &symbol;
    }
}

pub fn format(self: *const Symbol, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.writeAll("Symbol(");
    if (self.description) |description| {
        try writer.print("{f}", .{description});
    }
    try writer.writeAll(")");
}

/// 20.4.3.3.1 SymbolDescriptiveString ( symbol )
/// https://tc39.es/ecma262/#sec-symboldescriptivestring
pub fn descriptiveString(self: *const Symbol, agent: *Agent) std.mem.Allocator.Error!*const String {
    // 1. Let description be symbol.[[Description]].
    // 2. If description is undefined, set description to the empty String.
    // 3. Assert: description is a String.
    const description: *const String = self.description orelse .empty;

    // 4. Return the string-concatenation of "Symbol(", description, and ")".
    return String.concat(agent, &.{
        String.fromLiteral("Symbol("),
        description,
        String.fromLiteral(")"),
    });
}

test format {
    const test_cases = [_]struct { *const Symbol, []const u8 }{
        .{ .initComptime(null), "Symbol()" },
        .{ .initComptime(.empty), "Symbol(\"\")" },
        .{ .initComptime(String.fromLiteral("foo")), "Symbol(\"foo\")" },
    };
    for (test_cases) |test_case| {
        const symbol, const expected = test_case;
        try std.testing.expectFmt(expected, "{f}", .{symbol});
    }
}
