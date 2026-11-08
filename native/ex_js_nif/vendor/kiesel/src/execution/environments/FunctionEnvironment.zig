//! 9.1.1.3 Function Environment Records
//! https://tc39.es/ecma262/#sec-function-environment-records

const std = @import("std");

const builtins = @import("../../builtins.zig");
const execution = @import("../../execution.zig");
const types = @import("../../types.zig");

const Agent = execution.Agent;
const DeclarativeEnvironment = execution.DeclarativeEnvironment;
const ECMAScriptFunction = builtins.ECMAScriptFunction;
const Object = types.Object;
const Value = types.Value;

const FunctionEnvironment = @This();

pub const ThisBindingStatus = enum {
    lexical,
    initialized,
    uninitialized,
};

/// [[ThisValue]]
this_value: Value,

/// [[ThisBindingStatus]]
this_binding_status: ThisBindingStatus,

/// [[FunctionObject]]
function_object: *ECMAScriptFunction,

/// [[NewTarget]]
new_target: ?*Object,

// NOTE: This is how we implement the spec's inheritance of function environments.
declarative_environment: DeclarativeEnvironment,

/// 9.1.1.3.1 BindThisValue ( envRecord, value )
/// https://tc39.es/ecma262/#sec-bindthisvalue
pub fn bindThisValue(
    self: *FunctionEnvironment,
    agent: *Agent,
    value: Value,
) error{ExceptionThrown}!void {
    // 1. Assert: envRecord.[[ThisBindingStatus]] is not lexical.
    std.debug.assert(self.this_binding_status != .lexical);

    // 2. If envRecord.[[ThisBindingStatus]] is initialized, throw a ReferenceError exception.
    if (self.this_binding_status == .initialized) {
        @branchHint(.unlikely);
        return agent.throwException(
            .reference_error,
            "Function this binding is already initialized",
            .{},
        );
    }

    // 3. Set envRecord.[[ThisValue]] to value.
    self.this_value = value;

    // 4. Set envRecord.[[ThisBindingStatus]] to initialized.
    self.this_binding_status = .initialized;

    // 5. Return unused.
}

/// 9.1.1.3.2 HasThisBinding ( )
/// https://tc39.es/ecma262/#sec-function-environment-records-hasthisbinding
pub fn hasThisBinding(self: *const FunctionEnvironment) bool {
    // 1. If envRecord.[[ThisBindingStatus]] is lexical, return false.
    // 2. Return true.
    return self.this_binding_status != .lexical;
}

/// 9.1.1.3.3 GetThisBinding ( )
/// https://tc39.es/ecma262/#sec-function-environment-records-getthisbinding
pub fn getThisBinding(self: *const FunctionEnvironment, agent: *Agent) error{ExceptionThrown}!Value {
    // 1. Assert: envRecord.[[ThisBindingStatus]] is not lexical.
    std.debug.assert(self.this_binding_status != .lexical);

    // 2. If envRecord.[[ThisBindingStatus]] is uninitialized, throw a ReferenceError exception.
    if (self.this_binding_status == .uninitialized) {
        @branchHint(.unlikely);
        return agent.throwException(
            .reference_error,
            "Function this binding is uninitialized",
            .{},
        );
    }

    // 3. Return envRecord.[[ThisValue]].
    return self.this_value;
}

/// 9.1.1.3.4 HasSuperBinding ( )
/// https://tc39.es/ecma262/#sec-function-environment-records-hassuperbinding
pub fn hasSuperBinding(self: *const FunctionEnvironment) bool {
    // 1. If envRecord.[[ThisBindingStatus]] is lexical, return false.
    if (self.this_binding_status == .lexical) return false;

    // 2. If envRecord.[[FunctionObject]].[[HomeObject]] is undefined, return false.
    // 3. Return true.
    return self.function_object.fields.home_object != null;
}

pub const SuperBase = union(enum) {
    undefined,
    object: ?*Object,
};

/// 9.1.1.3.5 GetSuperBase ( envRecord )
/// https://tc39.es/ecma262/#sec-getsuperbase
pub fn getSuperBase(self: *const FunctionEnvironment) SuperBase {
    // 1. Let home be envRecord.[[FunctionObject]].[[HomeObject]].
    const home = self.function_object.fields.home_object orelse {
        // 2. If home is undefined, return undefined.
        return .undefined;
    };

    // 3. Assert: home is an ordinary object.
    std.debug.assert(home.internalMethods().flags.contains(.ordinary_get_prototype_of));

    // 4. Return ! home.[[GetPrototypeOf]]().
    return .{ .object = home.prototype() };
}
