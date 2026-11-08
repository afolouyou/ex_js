//! 9.1.1.5 Module Environment Records
//! https://tc39.es/ecma262/#sec-module-environment-records

const std = @import("std");

const environments = @import("../environments.zig");
const execution = @import("../../execution.zig");
const language = @import("../../language.zig");
const types = @import("../../types.zig");

const Agent = execution.Agent;
const DeclarativeEnvironment = environments.DeclarativeEnvironment;
const Module = language.Module;
const String = types.String;
const Value = types.Value;

const ModuleEnvironment = @This();

indirect_bindings: String.HashMap(IndirectBinding),

// NOTE: This is how we implement the spec's inheritance of module environments.
declarative_environment: DeclarativeEnvironment,

pub const IndirectBinding = struct {
    module: Module,
    target_name: *const String,
};

pub fn hasBinding(self: *const ModuleEnvironment, name: *const String) bool {
    // Handled via DeclarativeEnvironment in the spec but with a vague "has a binding", so we need
    // to override the implementation and check the indirect bindings as well.
    return self.indirect_bindings.contains(name) or self.declarative_environment.bindings.contains(name);
}

/// 9.1.1.5.1 GetBindingValue ( name, strict )
/// https://tc39.es/ecma262/#sec-module-environment-records-getbindingvalue-n-s
pub fn getBindingValue(
    self: *const ModuleEnvironment,
    agent: *Agent,
    name: *const String,
    strict: bool,
) error{ ExceptionThrown, OutOfMemory }!Value {
    // 1. Assert: strict is true.
    std.debug.assert(strict);

    // 2. Assert: envRecord has a binding for name.
    std.debug.assert(self.hasBinding(name));

    // 3. If the binding for name is an indirect binding, then
    if (self.indirect_bindings.get(name)) |indirect_binding| {
        // a. Let module and targetName be the indirection values provided when this binding for
        //    name was created.
        const module = indirect_binding.module;
        const target_name = indirect_binding.target_name;

        // b. Let targetEnv be module.[[Environment]].
        const maybe_target_env = switch (module) {
            inline else => |m| m.environment,
        };

        // c. If targetEnv is empty, throw a ReferenceError exception.
        const target_env = maybe_target_env orelse {
            @branchHint(.unlikely);
            return agent.throwException(
                .reference_error,
                "Module environment is not initialized",
                .{},
            );
        };

        // d. Return ? targetEnv.GetBindingValue(targetName, true).
        return target_env.getBindingValue(agent, target_name, true);
    }

    const binding = self.declarative_environment.bindings.get(name).?;

    // 4. If the binding for name in envRecord is an uninitialized binding, throw a ReferenceError
    //    exception.
    if (!binding.initialized) {
        @branchHint(.unlikely);
        return agent.throwException(
            .reference_error,
            "Binding for '{f}' is not initialized",
            .{name.fmtRaw()},
        );
    }

    // 5. Return the value currently bound to name in envRecord.
    return binding.value;
}

pub fn setMutableBinding(
    self: *ModuleEnvironment,
    agent: *Agent,
    name: *const String,
    value: Value,
    strict: bool,
) Agent.Error!void {
    // In the spec indirect bindings are created as immutable bindings in the declarative
    // environment, but since we keep them separate we have to check before delegating to the
    // declarative environment. (9.1.1.1.5 SetMutableBinding step 5)
    if (self.indirect_bindings.contains(name)) {
        @branchHint(.unlikely);
        return agent.throwException(
            .type_error,
            "Binding for '{f}' is immutable",
            .{name.fmtRaw()},
        );
    }
    return self.declarative_environment.setMutableBinding(agent, name, value, strict);
}

/// 9.1.1.5.2 DeleteBinding ( name )
/// https://tc39.es/ecma262/#sec-module-environment-records-deletebinding-n
pub fn deleteBinding(_: *ModuleEnvironment, _: *const String) bool {
    // The DeleteBinding concrete method of a Module Environment Record is never used within this
    // specification.
    @compileError("Should not be used");
}

/// 9.1.1.5.3 HasThisBinding ( )
/// https://tc39.es/ecma262/#sec-module-environment-records-hasthisbinding
pub fn hasThisBinding(_: *const ModuleEnvironment) bool {
    // 1. Return true.
    return true;
}

/// 9.1.1.5.4 GetThisBinding ( )
/// https://tc39.es/ecma262/#sec-module-environment-records-getthisbinding
pub fn getThisBinding(_: *const ModuleEnvironment) Value {
    // 1. Return undefined.
    return .undefined;
}

/// 9.1.1.5.5 CreateImportBinding ( envRecord, name, targetModule, targetName )
/// https://tc39.es/ecma262/#sec-createimportbinding
pub fn createImportBinding(
    self: *ModuleEnvironment,
    agent: *Agent,
    name: *const String,
    module: Module,
    target_name: *const String,
) std.mem.Allocator.Error!void {
    // 1. Assert: envRecord does not already have a binding for name.
    // 2. Assert: When targetModule.[[Environment]] is instantiated, it will have a direct binding
    //    for targetName.
    // 3. Create an immutable indirect binding in envRecord for name that references targetModule
    //    and targetName as its target binding and record that the binding is initialized.
    try self.indirect_bindings.putNoClobber(agent.gc_allocator, name, .{
        .module = module,
        .target_name = target_name,
    });

    // 4. Return unused.
}

/// Combined `hasBinding()` and `getBindingValue()`
pub fn getBindingValueIfExists(
    self: *const ModuleEnvironment,
    agent: *Agent,
    name: *const String,
) Agent.Error!?Value {
    if (self.indirect_bindings.get(name)) |indirect_binding| {
        const module = indirect_binding.module;
        const target_name = indirect_binding.target_name;
        const maybe_target_env = switch (module) {
            inline else => |m| m.environment,
        };
        const target_env = maybe_target_env orelse {
            @branchHint(.unlikely);
            return agent.throwException(
                .reference_error,
                "Module environment is not initialized",
                .{},
            );
        };
        return try target_env.getBindingValue(agent, target_name, true);
    }
    return self.declarative_environment.getBindingValueIfExists(agent, name);
}

/// Combined `hasBinding()` and `setMutableBinding()`
pub fn setMutableBindingIfExists(
    self: *ModuleEnvironment,
    agent: *Agent,
    name: *const String,
    value: Value,
    strict: bool,
) Agent.Error!bool {
    if (try self.declarative_environment.setMutableBindingIfExists(agent, name, value, strict)) return true;
    if (self.indirect_bindings.contains(name)) {
        return agent.throwException(
            .type_error,
            "Binding for '{f}' is immutable",
            .{name.fmtRaw()},
        );
    }
    return false;
}
