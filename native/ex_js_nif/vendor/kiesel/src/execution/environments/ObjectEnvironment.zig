//! 9.1.1.2 Object Environment Records
//! https://tc39.es/ecma262/#sec-object-environment-records

const environments = @import("../environments.zig");
const execution = @import("../../execution.zig");
const types = @import("../../types.zig");

const Agent = execution.Agent;
const Environment = environments.Environment;
const Object = types.Object;
const PropertyKey = types.PropertyKey;
const String = types.String;
const Value = types.Value;

const ObjectEnvironment = @This();

/// [[BindingObject]]
binding_object: *Object,

/// [[IsWithEnvironment]]
is_with_environment: bool,

/// [[OuterEnv]]
outer_env: ?Environment,

/// 9.1.1.2.1 HasBinding ( name )
/// https://tc39.es/ecma262/#sec-object-environment-records-hasbinding-n
pub fn hasBinding(self: *const ObjectEnvironment, agent: *Agent, name: *const String) Agent.Error!bool {
    const property_key: PropertyKey = .{ .string = name };

    // 1. Let bindingObj be envRecord.[[BindingObject]].
    // 2. Let foundBinding be ? HasProperty(bindingObj, name).
    const found_binding = try self.binding_object.hasProperty(agent, property_key);

    // 3. If foundBinding is false, return false.
    if (!found_binding) return false;

    // 4. If envRecord.[[IsWithEnvironment]] is false, return true.
    if (!self.is_with_environment) {
        @branchHint(.likely);
        return true;
    }

    // 5. Let unscopables be ? Get(bindingObj, %Symbol.unscopables%).
    const unscopables = try self.binding_object.get(
        agent,
        PropertyKey.from(agent.well_known_symbols.unscopables),
    );

    // 6. If unscopables is an Object, then
    if (unscopables.isObject()) {
        // a. Let blocked be ToBoolean(? Get(unscopables, name)).
        const blocked = (try unscopables.asObject().get(agent, property_key)).toBoolean();

        // b. If blocked is true, return false.
        if (blocked) return false;
    }

    // 7. Return true.
    return true;
}

/// 9.1.1.2.2 CreateMutableBinding ( name, deletable )
/// https://tc39.es/ecma262/#sec-object-environment-records-createmutablebinding-n-d
pub fn createMutableBinding(
    self: *const ObjectEnvironment,
    agent: *Agent,
    name: *const String,
    deletable: bool,
) Agent.Error!void {
    const property_key: PropertyKey = .{ .string = name };

    // 1. Let bindingObj be envRecord.[[BindingObject]].
    // 2. Perform ? DefinePropertyOrThrow(bindingObj, name, PropertyDescriptor {
    //    [[Value]]: undefined, [[Writable]]: true, [[Enumerable]]: true,
    //    [[Configurable]]: deletable }).
    try self.binding_object.definePropertyOrThrow(agent, property_key, .{
        .value = .undefined,
        .writable = true,
        .enumerable = true,
        .configurable = deletable,
    });

    // 3. Return unused.
}

/// 9.1.1.2.3 CreateImmutableBinding ( name, strict )
/// https://tc39.es/ecma262/#sec-object-environment-records-createimmutablebinding-n-s
pub fn createImmutableBinding(_: *const ObjectEnvironment, _: *const String, _: bool) noreturn {
    // The CreateImmutableBinding concrete method of an Object Environment Record is never used
    // within this specification.
    @compileError("Should not be used");
}

/// 9.1.1.2.4 InitializeBinding ( name, value )
/// https://tc39.es/ecma262/#sec-object-environment-records-initializebinding-n-v
pub fn initializeBinding(
    self: *const ObjectEnvironment,
    agent: *Agent,
    name: *const String,
    value: Value,
) Agent.Error!void {
    // 1. Perform ? envRecord.SetMutableBinding(name, value, false).
    try self.setMutableBinding(agent, name, value, false);

    // 2. Return unused.
}

/// 9.1.1.2.5 SetMutableBinding ( name, value, strict )
/// https://tc39.es/ecma262/#sec-object-environment-records-setmutablebinding-n-v-s
pub fn setMutableBinding(
    self: *const ObjectEnvironment,
    agent: *Agent,
    name: *const String,
    value: Value,
    strict: bool,
) Agent.Error!void {
    const property_key: PropertyKey = .{ .string = name };

    // 1. Let bindingObj be envRecord.[[BindingObject]].
    // 2. Let stillExists be ? HasProperty(bindingObj, name).
    const still_exists = try self.binding_object.hasProperty(agent, property_key);

    // 3. If stillExists is false and strict is true, throw a ReferenceError exception.
    if (!still_exists and strict) {
        @branchHint(.unlikely);
        return agent.throwException(.reference_error, "'{f}' is not defined", .{name.fmtRaw()});
    }

    // 4. Perform ? Set(bindingObj, name, value, strict).
    try self.binding_object.set(agent, property_key, value, if (strict) .throw else .ignore);

    // 5. Return unused.
}

/// 9.1.1.2.6 GetBindingValue ( name, strict )
/// https://tc39.es/ecma262/#sec-object-environment-records-getbindingvalue-n-s
pub fn getBindingValue(
    self: *const ObjectEnvironment,
    agent: *Agent,
    name: *const String,
    strict: bool,
) Agent.Error!Value {
    const property_key: PropertyKey = .{ .string = name };

    // 1. Let bindingObj be envRecord.[[BindingObject]].
    // 2. Let value be ? HasProperty(bindingObj, name).
    const value = try self.binding_object.hasProperty(agent, property_key);

    // 3. If value is false, then
    if (!value) {
        @branchHint(.unlikely);
        // a. If strict is false, return undefined.
        if (!strict) return .undefined;

        // b. Throw a ReferenceError exception.
        return agent.throwException(.reference_error, "'{f}' is not defined", .{name.fmtRaw()});
    }

    // 4. Return ? Get(bindingObj, name).
    return self.binding_object.get(agent, property_key);
}

/// 9.1.1.2.7 DeleteBinding ( name )
/// https://tc39.es/ecma262/#sec-object-environment-records-deletebinding-n
pub fn deleteBinding(self: *const ObjectEnvironment, agent: *Agent, name: *const String) Agent.Error!bool {
    const property_key: PropertyKey = .{ .string = name };

    // 1. Let bindingObj be envRecord.[[BindingObject]].
    // 2. Return ? bindingObj.[[Delete]](name).
    return self.binding_object.internalMethods().delete(
        agent,
        self.binding_object,
        property_key,
    );
}

/// 9.1.1.2.8 HasThisBinding ( )
/// https://tc39.es/ecma262/#sec-object-environment-records-hasthisbinding
pub fn hasThisBinding(_: *const ObjectEnvironment) bool {
    // 1. Return false.
    return false;
}

/// 9.1.1.2.9 GetThisBinding ( )
/// https://tc39.es/ecma262/#sec-object-environment-records-getthisbinding
pub fn getThisBinding(_: *const ObjectEnvironment) Value {
    // The GetThisBinding concrete method of an Object Environment Record is never used within this
    // specification.
    @compileError("Should not be used");
}

/// 9.1.1.2.10 HasSuperBinding ( )
/// https://tc39.es/ecma262/#sec-object-environment-records-hassuperbinding
pub fn hasSuperBinding(_: *const ObjectEnvironment) bool {
    // 1. Return false.
    return false;
}

/// 9.1.1.2.11 WithBaseObject ( )
/// https://tc39.es/ecma262/#sec-object-environment-records-withbaseobject
pub fn withBaseObject(self: *const ObjectEnvironment) ?*Object {
    // 1. If envRecord.[[IsWithEnvironment]] is true, return envRecord.[[BindingObject]].
    if (self.is_with_environment) {
        @branchHint(.unlikely);
        return self.binding_object;
    }

    // 2. Return undefined.
    return null;
}

/// Combined `hasBinding()` and `getBindingValue()`
pub fn getBindingValueIfExists(
    self: *const ObjectEnvironment,
    agent: *Agent,
    name: *const String,
    strict: bool,
) Agent.Error!?Value {
    const object = self.binding_object;
    const has_ordinary_internal_methods = object.internalMethods().flags.supersetOf(comptime .initMany(&.{
        .ordinary_has_property,
        .ordinary_get,
        // Dependencies of ordinary [[HasProperty]] and [[Get]]
        .ordinary_get_own_property,
        .ordinary_get_prototype_of,
    }));

    // OPTIMIZATION: Fast path for ordinary objects, no `with` environment
    if (has_ordinary_internal_methods and !self.is_with_environment) fast_path: {
        @branchHint(.likely);
        const property_key: PropertyKey = .{ .string = name };
        const property_desc = try object.getPropertyCreateLazyIfNeeded(property_key) orelse {
            // Don't bother with doing prototype chain traversal here, fall through to slow path
            break :fast_path;
        };
        switch (property_desc.value_or_accessor) {
            .value => |value| return value,
            .accessor => |accessor| {
                const getter = accessor.getter orelse return .undefined;
                return try getter.call(agent, Value.from(object), &.{});
            },
        }
    }

    if (!try self.hasBinding(agent, name)) return null;
    return try self.getBindingValue(agent, name, strict);
}

/// Combined `hasBinding()` and `setMutableBinding()`
pub fn setMutableBindingIfExists(
    self: *const ObjectEnvironment,
    agent: *Agent,
    name: *const String,
    value: Value,
    strict: bool,
) Agent.Error!bool {
    const object = self.binding_object;
    const has_ordinary_internal_methods = object.internalMethods().flags.supersetOf(comptime .initMany(&.{
        .ordinary_has_property,
        .ordinary_set,
        // Dependencies of ordinary [[HasProperty]] and [[Set]]
        .ordinary_get_own_property,
    }));

    // OPTIMIZATION: Fast path for ordinary objects, no `with` environment
    if (has_ordinary_internal_methods and !self.is_with_environment) fast_path: {
        @branchHint(.likely);
        const property_key: PropertyKey = .{ .string = name };
        const property = object.shape.properties.get(property_key) orelse {
            // Don't bother with doing prototype chain traversal here, fall through to slow path
            break :fast_path;
        };
        switch (property.type) {
            .value => {
                if (!property.attributes.writable) {
                    @branchHint(.unlikely);
                    if (strict) {
                        return agent.throwException(.type_error, "Could not set property", .{});
                    }
                    return true;
                }
                object.setValueAtPropertyOffset(property.offset, value);
            },
            .accessor => {
                const setter_value = object.getValueAtPropertyOffset(
                    @fromBackingInt(@backingInt(property.offset) + 1),
                );
                if (setter_value.isNull()) {
                    @branchHint(.unlikely);
                    if (strict) {
                        return agent.throwException(.type_error, "Could not set property", .{});
                    }
                    return true;
                }
                const setter = setter_value.asObject();
                _ = try setter.call(agent, Value.from(object), &.{value});
            },
        }
        return true;
    }

    if (!try self.hasBinding(agent, name)) return false;
    try self.setMutableBinding(agent, name, value, strict);
    return true;
}
