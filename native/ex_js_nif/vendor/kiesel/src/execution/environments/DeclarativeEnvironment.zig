//! 9.1.1.1 Declarative Environment Records
//! https://tc39.es/ecma262/#sec-declarative-environment-records

const builtin = @import("builtin");
const std = @import("std");

const environments = @import("../environments.zig");
const execution = @import("../../execution.zig");
const types = @import("../../types.zig");

const Agent = execution.Agent;
const DisposableResource = types.DisposableResource;
const Environment = environments.Environment;
const Object = types.Object;
const String = types.String;
const Value = types.Value;

const DeclarativeEnvironment = @This();

/// [[OuterEnv]]
outer_env: ?Environment,

/// [[DisposableResourceStack]]
disposable_resource_stack: std.ArrayList(DisposableResource),

bindings: String.HashMap(Binding),
is_catch_env: bool,

pub const Binding = struct {
    value: Value,
    initialized: bool,
    strict: bool,
    mutable: bool,
    deletable: bool,
};

comptime {
    switch (builtin.target.ptrBitWidth()) {
        // Only some 32-bit platforms have certain bitpacking optimizations applied
        32 => std.debug.assert(@sizeOf(Binding) == @sizeOf(Value) + 4 or @sizeOf(Binding) == @sizeOf(Value) + 8),
        64 => std.debug.assert(@sizeOf(Binding) == @sizeOf(Value) + 8),
        else => unreachable,
    }
}

/// 9.1.1.1.1 HasBinding ( name )
/// https://tc39.es/ecma262/#sec-declarative-environment-records-hasbinding-n
pub fn hasBinding(self: *const DeclarativeEnvironment, name: *const String) bool {
    // 1. If envRecord has a binding for name, return true.
    // 2. Return false.
    return self.bindings.contains(name);
}

/// 9.1.1.1.2 CreateMutableBinding ( name, deletable )
/// https://tc39.es/ecma262/#sec-declarative-environment-records-createmutablebinding-n-d
pub fn createMutableBinding(
    self: *DeclarativeEnvironment,
    agent: *Agent,
    name: *const String,
    deletable: bool,
) std.mem.Allocator.Error!void {
    // 1. Assert: envRecord does not already have a binding for name.
    // 2. Create a mutable binding in envRecord for name and record that it is uninitialized. If
    //    deletable is true, record that the newly created binding may be deleted by a subsequent
    //    DeleteBinding call.
    try self.bindings.putNoClobber(agent.gc_allocator, name, .{
        .value = undefined,
        .initialized = false,
        .strict = false,
        .mutable = true,
        .deletable = deletable,
    });

    // 3. Return unused.
}

/// 9.1.1.1.3 CreateImmutableBinding ( name, strict )
/// https://tc39.es/ecma262/#sec-declarative-environment-records-createimmutablebinding-n-s
pub fn createImmutableBinding(
    self: *DeclarativeEnvironment,
    agent: *Agent,
    name: *const String,
    strict: bool,
) std.mem.Allocator.Error!void {
    // 1. Assert: envRecord does not already have a binding for name.
    // 2. Create an immutable binding in envRecord for name and record that it is uninitialized. If
    //    strict is true, record that the newly created binding is a strict binding.
    try self.bindings.putNoClobber(agent.gc_allocator, name, .{
        .value = undefined,
        .initialized = false,
        .strict = strict,
        .mutable = false,
        .deletable = false,
    });

    // 3. Return unused.
}

/// 9.1.1.1.4 InitializeBinding ( name, value )
/// https://tc39.es/ecma262/#sec-declarative-environment-records-initializebinding-n-v
pub fn initializeBinding(
    self: *const DeclarativeEnvironment,
    name: *const String,
    value: Value,
) void {
    var binding = self.bindings.getPtr(name).?;

    // 1. Assert: envRecord must have an uninitialized binding for name.
    std.debug.assert(binding.initialized == false);

    // 2. Set the bound value for name in envRecord to value.
    binding.value = value;

    // 3. Record that the binding for name in envRecord has been initialized.
    binding.initialized = true;

    // 4. Return unused.
}

/// 9.1.1.1.5 SetMutableBinding ( name, value, strict )
/// https://tc39.es/ecma262/#sec-declarative-environment-records-setmutablebinding-n-v-s
pub fn setMutableBinding(
    self: *DeclarativeEnvironment,
    agent: *Agent,
    name: *const String,
    value: Value,
    strict: bool,
) Agent.Error!void {
    const maybe_binding = self.bindings.getPtr(name);

    // 1. If envRecord does not have a binding for name, then
    const binding = maybe_binding orelse {
        @branchHint(.unlikely);
        // a. If strict is true, throw a ReferenceError exception.
        if (strict) {
            return agent.throwException(
                .reference_error,
                "'{f}' is not defined",
                .{name.fmtRaw()},
            );
        }

        // b. Perform ! envRecord.CreateMutableBinding(name, true).
        try self.createMutableBinding(agent, name, true);

        // c. Perform ! envRecord.InitializeBinding(name, value).
        self.initializeBinding(name, value);

        // d. Return unused.
        return;
    };

    // 2. If the binding for name in envRecord is a strict binding, set strict to true.
    const final_strict = binding.strict or strict;

    // 3. If the binding for name in envRecord has not yet been initialized, then
    if (!binding.initialized) {
        @branchHint(.unlikely);
        // a. Throw a ReferenceError exception.
        return agent.throwException(
            .reference_error,
            "Binding for '{f}' is not initialized",
            .{name.fmtRaw()},
        );
    }

    // 4. Else if the binding for name in envRecord is a mutable binding, then
    if (binding.mutable) {
        @branchHint(.likely);
        // a. Change its bound value to value.
        binding.value = value;
    } else {
        // 5. Else,
        // a. Assert: This is an attempt to change the value of an immutable binding.
        // b. If strict is true, throw a TypeError exception.
        if (final_strict) {
            return agent.throwException(
                .type_error,
                "Binding for '{f}' is immutable",
                .{name.fmtRaw()},
            );
        }
    }

    // 6. Return unused.
}

/// 9.1.1.1.6 GetBindingValue ( name, strict )
/// https://tc39.es/ecma262/#sec-declarative-environment-records-getbindingvalue-n-s
pub fn getBindingValue(
    self: *const DeclarativeEnvironment,
    agent: *Agent,
    name: *const String,
    _: bool,
) error{ExceptionThrown}!Value {
    // 1. Assert: envRecord has a binding for name.
    const binding = self.bindings.get(name).?;

    // 2. If the binding for name in envRecord is an uninitialized binding, throw a ReferenceError
    //    exception.
    if (!binding.initialized) {
        @branchHint(.unlikely);
        return agent.throwException(
            .reference_error,
            "Binding for '{f}' is not initialized",
            .{name.fmtRaw()},
        );
    }

    // 3. Return the value currently bound to name in envRecord.
    return binding.value;
}

/// 9.1.1.1.7 DeleteBinding ( name )
/// https://tc39.es/ecma262/#sec-declarative-environment-records-deletebinding-n
pub fn deleteBinding(self: *DeclarativeEnvironment, name: *const String) bool {
    // 1. Assert: envRecord has a binding for name.
    const binding = self.bindings.get(name).?;

    // 2. If the binding for name in envRecord cannot be deleted, return false.
    if (!binding.deletable) {
        @branchHint(.unlikely);
        return false;
    }

    // 3. Remove the binding for name from envRecord.
    _ = self.bindings.remove(name);

    // 4. Return true.
    return true;
}

/// 9.1.1.1.8 HasThisBinding ( )
/// https://tc39.es/ecma262/#sec-declarative-environment-records-hasthisbinding
pub fn hasThisBinding(_: *const DeclarativeEnvironment) bool {
    // 1. Return false.
    return false;
}

/// 9.1.1.1.9 GetThisBinding ( )
/// https://tc39.es/ecma262/#sec-declarative-environment-records-getthisbinding
pub fn getThisBinding(_: *const DeclarativeEnvironment) Value {
    // The GetThisBinding concrete method of a Declarative Environment Record is never used within
    // this specification.
    @compileError("Should not be used");
}

/// 9.1.1.1.10 HasSuperBinding ( )
/// https://tc39.es/ecma262/#sec-declarative-environment-records-hassuperbinding
pub fn hasSuperBinding(_: *const DeclarativeEnvironment) bool {
    // 1. Return false.
    return false;
}
/// 9.1.1.1.11 WithBaseObject ( )
/// https://tc39.es/ecma262/#sec-declarative-environment-records-withbaseobject
pub fn withBaseObject(_: *const DeclarativeEnvironment) ?*Object {
    // 1. Return undefined.
    return null;
}

/// Combined `hasBinding()` and `getBindingValue()`
pub fn getBindingValueIfExists(
    self: *const DeclarativeEnvironment,
    agent: *Agent,
    name: *const String,
) error{ExceptionThrown}!?Value {
    const binding = self.bindings.get(name) orelse return null;
    if (!binding.initialized) {
        @branchHint(.unlikely);
        return agent.throwException(
            .reference_error,
            "Binding for '{f}' is not initialized",
            .{name.fmtRaw()},
        );
    }
    return binding.value;
}

/// Combined `hasBinding()` and `setMutableBinding()`
pub fn setMutableBindingIfExists(
    self: *DeclarativeEnvironment,
    agent: *Agent,
    name: *const String,
    value: Value,
    strict: bool,
) Agent.Error!bool {
    const binding = self.bindings.getPtr(name) orelse return false;
    const final_strict = binding.strict or strict;
    if (!binding.initialized) {
        @branchHint(.unlikely);
        return agent.throwException(
            .reference_error,
            "Binding for '{f}' is not initialized",
            .{name.fmtRaw()},
        );
    }
    if (binding.mutable) {
        @branchHint(.likely);
        binding.value = value;
    } else if (final_strict) {
        return agent.throwException(
            .type_error,
            "Binding for '{f}' is immutable",
            .{name.fmtRaw()},
        );
    }
    return true;
}
