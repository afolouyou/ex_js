//! 10.2.4.1 %ThrowTypeError% ( )
//! https://tc39.es/ecma262/#sec-%throwtypeerror%

const std = @import("std");

const builtins = @import("../builtins.zig");
const execution = @import("../execution.zig");
const types = @import("../types.zig");

const Agent = execution.Agent;
const Arguments = types.Arguments;
const Object = types.Object;
const Realm = execution.Realm;
const Value = types.Value;
const createBuiltinFunction = builtins.createBuiltinFunction;

pub const function = struct {
    pub fn create(agent: *Agent, realm: *Realm) std.mem.Allocator.Error!*Object {
        const builtin_function = try createBuiltinFunction(
            agent,
            .{ .function = impl },
            0,
            "",
            .{ .realm = realm },
        );
        return &builtin_function.object;
    }

    pub fn init(agent: *Agent, _: *Realm, object: *Object) std.mem.Allocator.Error!void {
        // The value of the [[Extensible]] internal slot of this function is false.
        try object.setNonExtensible(agent);

        // The "length" property of this function has the attributes {
        //   [[Writable]]: false, [[Enumerable]]: false, [[Configurable]]: false
        // }.
        try object.defineBuiltinPropertyWithAttributes(
            agent,
            "length",
            Value.from(0),
            .none,
        );

        // The "name" property of this function has the attributes {
        //   [[Writable]]: false, [[Enumerable]]: false, [[Configurable]]: false
        // }.
        try object.defineBuiltinPropertyWithAttributes(
            agent,
            "name",
            Value.from(""),
            .none,
        );
    }

    fn impl(agent: *Agent, _: Value, _: Arguments) Agent.Error!Value {
        // 1. Throw a TypeError exception.
        return agent.throwException(.type_error, "Forbidden property access", .{});
    }
};
