//! 9.1 Environment Records
//! https://tc39.es/ecma262/#sec-environment-records

const std = @import("std");

const builtins = @import("../builtins.zig");
const execution = @import("../execution.zig");
const types = @import("../types.zig");

const Agent = execution.Agent;
const ECMAScriptFunction = builtins.ECMAScriptFunction;
const Object = types.Object;
const PrivateName = types.PrivateName;
const String = types.String;
const Value = types.Value;

pub const DeclarativeEnvironment = @import("environments/DeclarativeEnvironment.zig");
pub const FunctionEnvironment = @import("environments/FunctionEnvironment.zig");
pub const GlobalEnvironment = @import("environments/GlobalEnvironment.zig");
pub const ModuleEnvironment = @import("environments/ModuleEnvironment.zig");
pub const ObjectEnvironment = @import("environments/ObjectEnvironment.zig");
pub const PrivateEnvironment = @import("environments/PrivateEnvironment.zig");

/// 9.1.1 The Environment Record Type Hierarchy
/// https://tc39.es/ecma262/#sec-the-environment-record-type-hierarchy
pub const Environment = union(enum) {
    declarative_environment: *DeclarativeEnvironment,
    object_environment: *ObjectEnvironment,
    function_environment: *FunctionEnvironment,
    global_environment: *GlobalEnvironment,
    module_environment: *ModuleEnvironment,

    pub fn outerEnv(self: Environment) ?Environment {
        return switch (self) {
            .declarative_environment => |env| env.outer_env,
            .object_environment => |env| env.outer_env,
            .function_environment => |env| env.declarative_environment.outer_env,
            .global_environment => |env| env.outer_env,
            .module_environment => |env| env.declarative_environment.outer_env,
        };
    }

    pub fn declarativeEnv(self: Environment) ?*DeclarativeEnvironment {
        return switch (self) {
            .declarative_environment => |env| env,
            .object_environment => null,
            .function_environment => |env| &env.declarative_environment,
            .global_environment => |env| env.declarative_record,
            .module_environment => |env| &env.declarative_environment,
        };
    }

    pub fn hasBinding(self: Environment, agent: *Agent, name: *const String) Agent.Error!bool {
        return switch (self) {
            .declarative_environment => |env| env.hasBinding(name),
            .object_environment => |env| env.hasBinding(agent, name),
            .function_environment => |env| env.declarative_environment.hasBinding(name),
            .global_environment => |env| env.hasBinding(agent, name),
            .module_environment => |env| env.hasBinding(name),
        };
    }

    pub fn createMutableBinding(
        self: Environment,
        agent: *Agent,
        name: *const String,
        deletable: bool,
    ) Agent.Error!void {
        return switch (self) {
            .declarative_environment => |env| env.createMutableBinding(agent, name, deletable),
            .object_environment => |env| env.createMutableBinding(agent, name, deletable),
            .function_environment => |env| env.declarative_environment.createMutableBinding(agent, name, deletable),
            .global_environment => |env| env.createMutableBinding(agent, name, deletable),
            .module_environment => |env| env.declarative_environment.createMutableBinding(agent, name, deletable),
        };
    }

    pub fn createImmutableBinding(
        self: Environment,
        agent: *Agent,
        name: *const String,
        strict: bool,
    ) Agent.Error!void {
        return switch (self) {
            .declarative_environment => |env| env.createImmutableBinding(agent, name, strict),
            .object_environment => unreachable,
            .function_environment => |env| env.declarative_environment.createImmutableBinding(agent, name, strict),
            .global_environment => |env| env.createImmutableBinding(agent, name, strict),
            .module_environment => |env| env.declarative_environment.createImmutableBinding(agent, name, strict),
        };
    }

    pub fn initializeBinding(
        self: Environment,
        agent: *Agent,
        name: *const String,
        value: Value,
    ) Agent.Error!void {
        return switch (self) {
            .declarative_environment => |env| env.initializeBinding(name, value),
            .object_environment => |env| env.initializeBinding(agent, name, value),
            .function_environment => |env| env.declarative_environment.initializeBinding(name, value),
            .global_environment => |env| env.initializeBinding(agent, name, value),
            .module_environment => |env| env.declarative_environment.initializeBinding(name, value),
        };
    }

    pub fn setMutableBinding(
        self: Environment,
        agent: *Agent,
        name: *const String,
        value: Value,
        strict: bool,
    ) Agent.Error!void {
        return switch (self) {
            .declarative_environment => |env| env.setMutableBinding(agent, name, value, strict),
            .object_environment => |env| env.setMutableBinding(agent, name, value, strict),
            .function_environment => |env| env.declarative_environment.setMutableBinding(agent, name, value, strict),
            .global_environment => |env| env.setMutableBinding(agent, name, value, strict),
            .module_environment => |env| env.setMutableBinding(agent, name, value, strict),
        };
    }

    pub fn getBindingValue(
        self: Environment,
        agent: *Agent,
        name: *const String,
        strict: bool,
    ) Agent.Error!Value {
        return switch (self) {
            .declarative_environment => |env| env.getBindingValue(agent, name, strict),
            .object_environment => |env| env.getBindingValue(agent, name, strict),
            .function_environment => |env| env.declarative_environment.getBindingValue(agent, name, strict),
            .global_environment => |env| env.getBindingValue(agent, name, strict),
            .module_environment => |env| env.getBindingValue(agent, name, strict),
        };
    }

    pub fn deleteBinding(self: Environment, agent: *Agent, name: *const String) Agent.Error!bool {
        return switch (self) {
            .declarative_environment => |env| env.deleteBinding(name),
            .object_environment => |env| env.deleteBinding(agent, name),
            .function_environment => |env| env.declarative_environment.deleteBinding(name),
            .global_environment => |env| env.deleteBinding(agent, name),
            .module_environment => unreachable,
        };
    }

    pub fn hasThisBinding(self: Environment) bool {
        return switch (self) {
            .declarative_environment => |env| env.hasThisBinding(),
            .object_environment => |env| env.hasThisBinding(),
            .function_environment => |env| env.hasThisBinding(),
            .global_environment => |env| env.hasThisBinding(),
            .module_environment => |env| env.hasThisBinding(),
        };
    }

    pub fn hasSuperBinding(self: Environment) bool {
        return switch (self) {
            .declarative_environment => |env| env.hasSuperBinding(),
            .object_environment => |env| env.hasSuperBinding(),
            .function_environment => |env| env.hasSuperBinding(),
            .global_environment => |env| env.hasSuperBinding(),
            .module_environment => |env| env.declarative_environment.hasSuperBinding(),
        };
    }

    pub fn withBaseObject(self: Environment) ?*Object {
        return switch (self) {
            .declarative_environment => |env| env.withBaseObject(),
            .object_environment => |env| env.withBaseObject(),
            .function_environment => |env| env.declarative_environment.withBaseObject(),
            .global_environment => |env| env.withBaseObject(),
            .module_environment => |env| env.declarative_environment.withBaseObject(),
        };
    }

    pub fn getThisBinding(self: Environment, agent: *Agent) error{ExceptionThrown}!Value {
        return switch (self) {
            .declarative_environment => unreachable,
            .object_environment => unreachable,
            .function_environment => |env| env.getThisBinding(agent),
            .global_environment => |env| env.getThisBinding(),
            .module_environment => |env| env.getThisBinding(),
        };
    }

    pub fn getBindingValueIfExists(
        self: Environment,
        agent: *Agent,
        name: *const String,
        strict: bool,
    ) Agent.Error!?Value {
        return switch (self) {
            .declarative_environment => |env| env.getBindingValueIfExists(agent, name),
            .function_environment => |env| env.declarative_environment.getBindingValueIfExists(agent, name),
            .object_environment => |env| env.getBindingValueIfExists(agent, name, strict),
            .global_environment => |env| env.getBindingValueIfExists(agent, name, strict),
            .module_environment => |env| env.getBindingValueIfExists(agent, name),
        };
    }

    pub fn setMutableBindingIfExists(
        self: Environment,
        agent: *Agent,
        name: *const String,
        value: Value,
        strict: bool,
    ) Agent.Error!bool {
        return switch (self) {
            .declarative_environment => |env| env.setMutableBindingIfExists(agent, name, value, strict),
            .function_environment => |env| env.declarative_environment.setMutableBindingIfExists(agent, name, value, strict),
            .object_environment => |env| env.setMutableBindingIfExists(agent, name, value, strict),
            .global_environment => |env| env.setMutableBindingIfExists(agent, name, value, strict),
            .module_environment => |env| env.setMutableBindingIfExists(agent, name, value, strict),
        };
    }
};

/// 9.1.2.2 NewDeclarativeEnvironment ( outerEnv )
/// https://tc39.es/ecma262/#sec-newdeclarativeenvironment
pub fn newDeclarativeEnvironment(
    allocator: std.mem.Allocator,
    outer_env: ?Environment,
) std.mem.Allocator.Error!*DeclarativeEnvironment {
    // 1. Let envRecord be a new Declarative Environment Record containing no bindings.
    const env = try allocator.create(DeclarativeEnvironment);

    env.* = .{
        // 2. Set envRecord.[[OuterEnv]] to outerEnv.
        .outer_env = outer_env,

        // 3. Set envRecord.[[DisposableResourceStack]] to a new empty List.
        .disposable_resource_stack = .empty,

        .bindings = .empty,
        .is_catch_env = false,
    };

    // 4. Return envRecord.
    return env;
}

/// 9.1.2.3 NewObjectEnvironment ( obj, isWithEnv, outerEnv )
/// https://tc39.es/ecma262/#sec-newobjectenvironment
pub fn newObjectEnvironment(
    allocator: std.mem.Allocator,
    obj: *Object,
    is_with_env: bool,
    outer_env: ?Environment,
) std.mem.Allocator.Error!*ObjectEnvironment {
    // 1. Let envRecord be a new Object Environment Record.
    const env = try allocator.create(ObjectEnvironment);

    env.* = .{
        // 2. Set envRecord.[[BindingObject]] to obj.
        .binding_object = obj,

        // 3. Set envRecord.[[IsWithEnvironment]] to isWithEnv.
        .is_with_environment = is_with_env,

        // 4. Set envRecord.[[OuterEnv]] to outerEnv.
        .outer_env = outer_env,
    };

    // 5. Return envRecord.
    return env;
}

/// 9.1.2.4 NewFunctionEnvironment ( func, newTarget )
/// https://tc39.es/ecma262/#sec-newfunctionenvironment
pub fn newFunctionEnvironment(
    allocator: std.mem.Allocator,
    func: *ECMAScriptFunction,
    new_target: ?*Object,
) std.mem.Allocator.Error!*FunctionEnvironment {
    // 1. Let envRecord be a new Function Environment Record containing no bindings.
    const env = try allocator.create(FunctionEnvironment);
    env.* = .{
        // 2. Set envRecord.[[FunctionObject]] to func.
        .function_object = func,

        // 3. If func.[[ThisMode]] is lexical, set envRecord.[[ThisBindingStatus]] to lexical.
        // 4. Else, set envRecord.[[ThisBindingStatus]] to uninitialized.
        .this_binding_status = if (func.fields.flags.this_mode == .lexical)
            .lexical
        else
            .uninitialized,

        // 5. Set envRecord.[[NewTarget]] to newTarget.
        .new_target = new_target,

        .declarative_environment = .{
            // 6. Set envRecord.[[OuterEnv]] to func.[[Environment]].
            .outer_env = func.fields.environment,

            // 7. Set envRecord.[[DisposableResourceStack]] to a new empty List.
            .disposable_resource_stack = .empty,

            .bindings = .empty,
            .is_catch_env = false,
        },

        .this_value = .undefined,
    };

    // 8. Return envRecord.
    return env;
}

/// 9.1.2.5 NewGlobalEnvironment ( obj, thisValue )
/// https://tc39.es/ecma262/#sec-newglobalenvironment
pub fn newGlobalEnvironment(
    allocator: std.mem.Allocator,
    obj: *Object,
    this_value: *Object,
) std.mem.Allocator.Error!*GlobalEnvironment {
    // 1. Let objRecord be NewObjectEnvironment(obj, false, null).
    const object_record = try newObjectEnvironment(allocator, obj, false, null);

    // 2. Let declRecord be NewDeclarativeEnvironment(null).
    const declarative_record = try newDeclarativeEnvironment(allocator, null);

    // 3. Let envRecord be a new Global Environment Record.
    const env = try allocator.create(GlobalEnvironment);
    env.* = .{
        // 4. Set envRecord.[[ObjectRecord]] to objRecord.
        .object_record = object_record,

        // 5. Set envRecord.[[GlobalThisValue]] to thisValue.
        .global_this_value = this_value,

        // 6. Set envRecord.[[DeclarativeRecord]] to declRecord.
        .declarative_record = declarative_record,

        // 7. Set envRecord.[[OuterEnv]] to null.
        .outer_env = null,
    };

    // 8. Return envRecord.
    return env;
}

/// 9.1.2.6 NewModuleEnvironment ( outerEnv )
/// https://tc39.es/ecma262/#sec-newmoduleenvironment
pub fn newModuleEnvironment(
    allocator: std.mem.Allocator,
    outer_env: *GlobalEnvironment,
) std.mem.Allocator.Error!*ModuleEnvironment {
    // 1. Let envRecord be a new Module Environment Record containing no bindings.
    const env = try allocator.create(ModuleEnvironment);
    env.* = .{
        .declarative_environment = .{
            // 2. Set envRecord.[[OuterEnv]] to outerEnv.
            .outer_env = .{ .global_environment = outer_env },

            // 3. Set envRecord.[[DisposableResourceStack]] to a new empty List.
            .disposable_resource_stack = .empty,

            .bindings = .empty,
            .is_catch_env = false,
        },

        .indirect_bindings = .empty,
    };

    // 4. Return envRecord.
    return env;
}

/// 9.2.1.1 NewPrivateEnvironment ( outerPrivateEnv )
/// https://tc39.es/ecma262/#sec-newprivateenvironment
pub fn newPrivateEnvironment(
    allocator: std.mem.Allocator,
    outer_private_env: ?*PrivateEnvironment,
) std.mem.Allocator.Error!*PrivateEnvironment {
    // 1. Let names be a new empty List.
    const names: std.StringHashMapUnmanaged(PrivateName) = .empty;

    // 2. Return the PrivateEnvironment Record { [[OuterPrivateEnvironment]]: outerPrivateEnv,
    //    [[Names]]: names }.
    const env = try allocator.create(PrivateEnvironment);
    env.* = .{
        .outer_private_environment = outer_private_env,
        .names = names,
    };
    return env;
}
