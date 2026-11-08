//! 9.1.1.4 Global Environment Records
//! https://tc39.es/ecma262/#sec-global-environment-records

const std = @import("std");

const builtins = @import("../../builtins.zig");
const environments = @import("../environments.zig");
const execution = @import("../../execution.zig");
const types = @import("../../types.zig");

const Agent = execution.Agent;
const DeclarativeEnvironment = environments.DeclarativeEnvironment;
const Environment = environments.Environment;
const Object = types.Object;
const ObjectEnvironment = environments.ObjectEnvironment;
const PropertyDescriptor = types.PropertyDescriptor;
const PropertyKey = types.PropertyKey;
const String = types.String;
const Value = types.Value;

const GlobalEnvironment = @This();

/// [[ObjectRecord]]
object_record: *ObjectEnvironment,

/// [[GlobalThisValue]]
global_this_value: *Object,

/// [[DeclarativeRecord]]
declarative_record: *DeclarativeEnvironment,

/// [[OuterEnv]]
outer_env: ?Environment,

/// 9.1.1.4.1 HasBinding ( name )
/// https://tc39.es/ecma262/#sec-global-environment-records-hasbinding-n
pub fn hasBinding(self: *const GlobalEnvironment, agent: *Agent, name: *const String) Agent.Error!bool {
    // 1. Let declRecord be envRecord.[[DeclarativeRecord]].
    // 2. If ! declRecord.HasBinding(name) is true, return true.
    if (self.declarative_record.hasBinding(name)) return true;

    // 3. Let objRecord be envRecord.[[ObjectRecord]].
    // 4. Return ? objRecord.HasBinding(name).
    return self.object_record.hasBinding(agent, name);
}

/// 9.1.1.4.2 CreateMutableBinding ( name, deletable )
/// https://tc39.es/ecma262/#sec-global-environment-records-createmutablebinding-n-d
pub fn createMutableBinding(
    self: *GlobalEnvironment,
    agent: *Agent,
    name: *const String,
    deletable: bool,
) Agent.Error!void {
    // 1. Let declRecord be envRecord.[[DeclarativeRecord]].
    // 2. If ! declRecord.HasBinding(name) is true, throw a TypeError exception.
    if (self.declarative_record.hasBinding(name)) {
        @branchHint(.unlikely);
        return agent.throwException(
            .type_error,
            "Binding for '{f}' already exists",
            .{name.fmtRaw()},
        );
    }

    // 3. Return ! declRecord.CreateMutableBinding(name, deletable).
    return self.declarative_record.createMutableBinding(agent, name, deletable);
}

/// 9.1.1.4.3 CreateImmutableBinding ( name, strict )
/// https://tc39.es/ecma262/#sec-global-environment-records-createimmutablebinding-n-s
pub fn createImmutableBinding(
    self: *GlobalEnvironment,
    agent: *Agent,
    name: *const String,
    strict: bool,
) Agent.Error!void {
    // 1. Let declRecord be envRecord.[[DeclarativeRecord]].
    // 2. If ! declRecord.HasBinding(name) is true, throw a TypeError exception.
    if (self.declarative_record.hasBinding(name)) {
        @branchHint(.unlikely);
        return agent.throwException(
            .type_error,
            "Binding for '{f}' already exists",
            .{name.fmtRaw()},
        );
    }

    // 3. Return ! declRecord.CreateImmutableBinding(name, strict).
    return self.declarative_record.createImmutableBinding(agent, name, strict);
}

/// 9.1.1.4.4 InitializeBinding ( name, value )
/// https://tc39.es/ecma262/#sec-global-environment-records-initializebinding-n-v
pub fn initializeBinding(
    self: *const GlobalEnvironment,
    agent: *Agent,
    name: *const String,
    value: Value,
) Agent.Error!void {
    // 1. Let declRecord be envRecord.[[DeclarativeRecord]].
    // 2. If ! declRecord.HasBinding(name) is true, then
    if (self.declarative_record.bindings.getPtr(name)) |binding| {
        // a. Return ! declRecord.InitializeBinding(name, value).
        std.debug.assert(binding.initialized == false);
        binding.value = value;
        binding.initialized = true;
        return;
    }

    // 3. Assert: If the binding exists, it must be in the Object Environment Record.
    // 4. Let objRecord be envRecord.[[ObjectRecord]].
    // 5. Return ? objRecord.InitializeBinding(name, value).
    return self.object_record.initializeBinding(agent, name, value);
}

/// 9.1.1.4.5 SetMutableBinding ( name, value, strict )
/// https://tc39.es/ecma262/#sec-global-environment-records-setmutablebinding-n-v-s
pub fn setMutableBinding(
    self: *const GlobalEnvironment,
    agent: *Agent,
    name: *const String,
    value: Value,
    strict: bool,
) Agent.Error!void {
    // 1. Let declRecord be envRecord.[[DeclarativeRecord]].
    // 2. If ! declRecord.HasBinding(name) is true, then
    if (self.declarative_record.bindings.getPtr(name)) |binding| {
        // a. Return ? declRecord.SetMutableBinding(name, value, strict).
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
        return;
    }

    // 3. Let objRecord be envRecord.[[ObjectRecord]].
    // 4. Return ? objRecord.SetMutableBinding(name, value, strict).
    return self.object_record.setMutableBinding(agent, name, value, strict);
}

/// 9.1.1.4.6 GetBindingValue ( name, strict )
/// https://tc39.es/ecma262/#sec-global-environment-records-getbindingvalue-n-s
pub fn getBindingValue(
    self: *const GlobalEnvironment,
    agent: *Agent,
    name: *const String,
    strict: bool,
) Agent.Error!Value {
    // 1. Let declRecord be envRecord.[[DeclarativeRecord]].
    // 2. If ! declRecord.HasBinding(name) is true, then
    if (self.declarative_record.bindings.get(name)) |binding| {
        // a. Return ? declRecord.GetBindingValue(name, strict).
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

    // 3. Let objRecord be envRecord.[[ObjectRecord]].
    // 4. Return ? objRecord.GetBindingValue(name, strict).
    return self.object_record.getBindingValue(agent, name, strict);
}

/// 9.1.1.4.7 DeleteBinding ( name )
/// https://tc39.es/ecma262/#sec-global-environment-records-deletebinding-n
pub fn deleteBinding(self: *const GlobalEnvironment, agent: *Agent, name: *const String) Agent.Error!bool {
    const property_key: PropertyKey = .{ .string = name };

    // 1. Let declRecord be envRecord.[[DeclarativeRecord]].
    // 2. If ! declRecord.HasBinding(name) is true, then
    if (self.declarative_record.bindings.get(name)) |binding| {
        // a. Return ! declRecord.DeleteBinding(name).
        if (!binding.deletable) {
            @branchHint(.unlikely);
            return false;
        }
        _ = self.declarative_record.bindings.remove(name);
        return true;
    }

    // 3. Let objRecord be envRecord.[[ObjectRecord]].
    // 4. Let globalObj be objRecord.[[BindingObject]].
    const global_obj = self.object_record.binding_object;

    // 5. Let existingProperty be ? HasOwnProperty(globalObj, name).
    const existing_property = try global_obj.hasOwnProperty(agent, property_key);

    // 6. If existingProperty is true, then
    if (existing_property) {
        @branchHint(.likely);
        // a. Return ? objRecord.DeleteBinding(name).
        return self.object_record.deleteBinding(agent, name);
    }

    // 7. Return true.
    return true;
}

/// 9.1.1.4.8 HasThisBinding ( )
/// https://tc39.es/ecma262/#sec-global-environment-records-hasthisbinding
pub fn hasThisBinding(_: *const GlobalEnvironment) bool {
    // 1. Return true.
    return true;
}

/// 9.1.1.4.9 GetThisBinding ( )
/// https://tc39.es/ecma262/#sec-global-environment-records-getthisbinding
pub fn getThisBinding(self: *const GlobalEnvironment) Value {
    // 1. Return envRecord.[[GlobalThisValue]].
    return Value.from(self.global_this_value);
}

/// 9.1.1.4.10 HasSuperBinding ( )
/// https://tc39.es/ecma262/#sec-global-environment-records-hassuperbinding
pub fn hasSuperBinding(_: *const GlobalEnvironment) bool {
    // 1. Return false.
    return false;
}

/// 9.1.1.4.11 WithBaseObject ( )
/// https://tc39.es/ecma262/#sec-global-environment-records-withbaseobject
pub fn withBaseObject(_: *const GlobalEnvironment) ?*Object {
    // 1. Return undefined.
    return null;
}

/// 9.1.1.4.12 HasLexicalDeclaration ( envRecord, name )
/// https://tc39.es/ecma262/#sec-haslexicaldeclaration
pub fn hasLexicalDeclaration(self: *const GlobalEnvironment, name: *const String) bool {
    // 1. Let declRecord be envRecord.[[DeclarativeRecord]].
    // 2. Return ! declRecord.HasBinding(name).
    return self.declarative_record.hasBinding(name);
}

/// 9.1.1.4.13 HasRestrictedGlobalProperty ( envRecord, name )
/// https://tc39.es/ecma262/#sec-hasrestrictedglobalproperty
pub fn hasRestrictedGlobalProperty(
    self: *const GlobalEnvironment,
    agent: *Agent,
    name: *const String,
) Agent.Error!bool {
    const property_key: PropertyKey = .{ .string = name };

    // 1. Let objRecord be envRecord.[[ObjectRecord]].
    // 2. Let globalObj be objRecord.[[BindingObject]].
    const global_obj = self.object_record.binding_object;

    // 3. Let existingProperty be ? globalObj.[[GetOwnProperty]](name).
    const existing_property = try global_obj.internalMethods().getOwnProperty(
        agent,
        global_obj,
        property_key,
    ) orelse {
        // 4. If existingProperty is undefined, return false.
        return false;
    };

    // 5. If existingProperty.[[Configurable]] is true, return false.
    if (existing_property.configurable == true) return false;

    // 6. Return true.
    return true;
}

/// 9.1.1.4.14 CanDeclareGlobalVar ( envRecord, name )
/// https://tc39.es/ecma262/#sec-candeclareglobalvar
pub fn canDeclareGlobalVar(
    self: *const GlobalEnvironment,
    agent: *Agent,
    name: *const String,
) Agent.Error!bool {
    const property_key: PropertyKey = .{ .string = name };

    // 1. Let objRecord be envRecord.[[ObjectRecord]].
    // 2. Let globalObj be objRecord.[[BindingObject]].
    const global_obj = self.object_record.binding_object;

    // 3. Let hasProperty be ? HasOwnProperty(globalObj, name).
    const has_property = try global_obj.hasOwnProperty(agent, property_key);

    // 4. If hasProperty is true, return true.
    if (has_property) return true;

    // 5. Return ? IsExtensible(globalObj).
    return global_obj.isExtensible(agent);
}

/// 9.1.1.4.15 CanDeclareGlobalFunction ( envRecord, name )
/// https://tc39.es/ecma262/#sec-candeclareglobalfunction
pub fn canDeclareGlobalFunction(
    self: *const GlobalEnvironment,
    agent: *Agent,
    name: *const String,
) Agent.Error!bool {
    const property_key: PropertyKey = .{ .string = name };

    // 1. Let objRecord be envRecord.[[ObjectRecord]].
    // 2. Let globalObj be objRecord.[[BindingObject]].
    const global_obj = self.object_record.binding_object;

    // 3. Let existingProperty be ? globalObj.[[GetOwnProperty]](name).
    const existing_property = try global_obj.internalMethods().getOwnProperty(
        agent,
        global_obj,
        property_key,
    ) orelse {
        // 4. If existingProperty is undefined, return ? IsExtensible(globalObj).
        return global_obj.isExtensible(agent);
    };

    // 5. If existingProperty.[[Configurable]] is true, return true.
    if (existing_property.configurable == true) return true;

    // 6. If IsDataDescriptor(existingProperty) is true and existingProperty has attribute values {
    //    [[Writable]]: true, [[Enumerable]]: true }, return true.
    if (existing_property.isDataDescriptor() and
        existing_property.writable == true and
        existing_property.enumerable == true) return true;

    // 7. Return false.
    return false;
}

/// 9.1.1.4.16 CreateGlobalVarBinding ( envRecord, name, deletable )
/// https://tc39.es/ecma262/#sec-createglobalvarbinding
pub fn createGlobalVarBinding(
    self: *const GlobalEnvironment,
    agent: *Agent,
    name: *const String,
    deletable: bool,
) Agent.Error!void {
    const property_key: PropertyKey = .{ .string = name };

    // 1. Let objRecord be envRecord.[[ObjectRecord]].
    // 2. Let globalObj be objRecord.[[BindingObject]].
    const global_obj = self.object_record.binding_object;

    // 3. Let hasProperty be ? HasOwnProperty(globalObj, name).
    const has_property = try global_obj.hasOwnProperty(agent, property_key);

    // 4. Let extensible be ? IsExtensible(globalObj).
    const extensible = try global_obj.isExtensible(agent);

    // 5. If hasProperty is false and extensible is true, then
    if (!has_property and extensible) {
        // a. Perform ? objRecord.CreateMutableBinding(name, deletable).
        try self.object_record.createMutableBinding(agent, name, deletable);

        // b. Perform ? objRecord.InitializeBinding(name, undefined).
        try self.object_record.initializeBinding(agent, name, .undefined);
    }

    // 6. Return unused.
}

/// 9.1.1.4.17 CreateGlobalFunctionBinding ( envRecord, name, value, deletable )
/// https://tc39.es/ecma262/#sec-createglobalfunctionbinding
pub fn createGlobalFunctionBinding(
    self: *const GlobalEnvironment,
    agent: *Agent,
    name: *const String,
    value: *builtins.ECMAScriptFunction,
    deletable: bool,
) Agent.Error!void {
    const property_key: PropertyKey = .{ .string = name };

    // 1. Let objRecord be envRecord.[[ObjectRecord]].
    // 2. Let globalObj be objRecord.[[BindingObject]].
    const global_obj = self.object_record.binding_object;

    // 3. Let existingProperty be ? globalObj.[[GetOwnProperty]](name).
    const existing_property = try global_obj.internalMethods().getOwnProperty(
        agent,
        global_obj,
        property_key,
    );

    // 4. If existingProperty is undefined or existingProperty.[[Configurable]] is true, then
    const property_desc: PropertyDescriptor = if (existing_property == null or existing_property.?.configurable == true) blk: {
        // a. Let propertyDesc be the PropertyDescriptor { [[Value]]: value, [[Writable]]: true,
        //    [[Enumerable]]: true, [[Configurable]]: deletable }.
        break :blk .{ .value = Value.from(&value.object), .writable = true, .enumerable = true, .configurable = deletable };
    } else blk: {
        // 5. Else,
        // a. Let propertyDesc be the PropertyDescriptor { [[Value]]: value }.
        break :blk .{ .value = Value.from(&value.object) };
    };

    // 6. Perform ? DefinePropertyOrThrow(globalObj, name, propertyDesc).
    try global_obj.definePropertyOrThrow(agent, property_key, property_desc);

    // 7. Perform ? Set(globalObj, name, value, false).
    try global_obj.set(agent, property_key, Value.from(&value.object), .ignore);

    // 8. Return unused.
}

/// Combined `hasBinding()` and `getBindingValue()`
pub fn getBindingValueIfExists(
    self: *const GlobalEnvironment,
    agent: *Agent,
    name: *const String,
    strict: bool,
) Agent.Error!?Value {
    if (self.declarative_record.bindings.get(name)) |binding| {
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
    return self.object_record.getBindingValueIfExists(agent, name, strict);
}

/// Combined `hasBinding()` and `setMutableBinding()`
pub fn setMutableBindingIfExists(
    self: *const GlobalEnvironment,
    agent: *Agent,
    name: *const String,
    value: Value,
    strict: bool,
) Agent.Error!bool {
    if (self.declarative_record.bindings.getPtr(name)) |binding| {
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
    return self.object_record.setMutableBindingIfExists(agent, name, value, strict);
}
