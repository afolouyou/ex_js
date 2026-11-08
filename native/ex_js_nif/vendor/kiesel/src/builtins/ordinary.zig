//! 10.1 Ordinary Object Internal Methods and Internal Slots
//! https://tc39.es/ecma262/#sec-ordinary-object-internal-methods-and-internal-slots

const std = @import("std");

const builtins = @import("../builtins.zig");
const execution = @import("../execution.zig");
const types = @import("../types.zig");

const Agent = execution.Agent;
const Object = types.Object;
const PropertyDescriptor = types.PropertyDescriptor;
const PropertyKey = Object.PropertyKey;
const Realm = execution.Realm;
const Value = types.Value;
const sameValue = types.sameValue;

const module = @This();

// Only export these in a namespace so it's clear what they are.
pub const internal_methods = struct {
    pub const getPrototypeOf = module.getPrototypeOf;
    pub const setPrototypeOf = module.setPrototypeOf;
    pub const isExtensible = module.isExtensible;
    pub const preventExtensions = module.preventExtensions;
    pub const getOwnProperty = module.getOwnProperty;
    pub const defineOwnProperty = module.defineOwnProperty;
    pub const hasProperty = module.hasProperty;
    pub const get = module.get;
    pub const set = module.set;
    pub const delete = module.delete;
    pub const ownPropertyKeys = module.ownPropertyKeys;
};

/// 10.1.1 [[GetPrototypeOf]] ( )
/// https://tc39.es/ecma262/#sec-ordinary-object-internal-methods-and-internal-slots-getprototypeof
fn getPrototypeOf(_: *Agent, obj: *Object) error{}!?*Object {
    // 1. Return OrdinaryGetPrototypeOf(obj).
    return ordinaryGetPrototypeOf(obj);
}

/// 10.1.1.1 OrdinaryGetPrototypeOf ( obj )
/// https://tc39.es/ecma262/#sec-ordinarygetprototypeof
pub fn ordinaryGetPrototypeOf(obj: *Object) ?*Object {
    // 1. Return obj.[[Prototype]].
    return obj.prototype();
}

/// 10.1.2 [[SetPrototypeOf]] ( proto )
/// https://tc39.es/ecma262/#sec-ordinary-object-internal-methods-and-internal-slots-setprototypeof-v
fn setPrototypeOf(agent: *Agent, obj: *Object, proto: ?*Object) std.mem.Allocator.Error!bool {
    // 1. Return OrdinarySetPrototypeOf(obj, proto).
    return ordinarySetPrototypeOf(agent, obj, proto);
}

/// 10.1.2.1 OrdinarySetPrototypeOf ( obj, proto )
/// https://tc39.es/ecma262/#sec-ordinarysetprototypeof
pub fn ordinarySetPrototypeOf(
    agent: *Agent,
    obj: *Object,
    proto: ?*Object,
) std.mem.Allocator.Error!bool {
    // 1. Let current be obj.[[Prototype]].
    const current = obj.prototype();

    // 2. If SameValue(proto, current) is true, return true.
    if (proto == current) return true;

    // 3. Let extensible be obj.[[Extensible]].
    const extensible = obj.extensible();

    // 4. If extensible is false, return false.
    if (!extensible) return false;

    // 5. Let cursor be proto.
    var maybe_cursor = proto;

    // 6. Let done be false.
    // 7. Repeat, while done is false,
    while (maybe_cursor) |cursor| {
        // a. If cursor is null, then
        //     i. Set done to true.

        // b. Else if SameValue(cursor, obj) is true, then
        if (cursor == obj) {
            // i. Return false.
            return false;
        }

        // c. Else,
        // i. If cursor.[[GetPrototypeOf]] is not the ordinary object internal method defined in
        //    10.1.1, set done to true.
        if (cursor.internalMethods().getPrototypeOf != getPrototypeOf) break;

        // ii. Else, set cursor to cursor.[[Prototype]].
        maybe_cursor = cursor.prototype();
    }

    // 8. Set obj.[[Prototype]] to proto.
    try obj.setPrototype(agent, proto);

    // 9. Return true.
    return true;
}

/// 10.1.3 [[IsExtensible]] ( )
/// https://tc39.es/ecma262/#sec-ordinary-object-internal-methods-and-internal-slots-isextensible
fn isExtensible(_: *Agent, obj: *Object) error{}!bool {
    // 1. Return OrdinaryIsExtensible(obj).
    return ordinaryIsExtensible(obj);
}

/// 10.1.3.1 OrdinaryIsExtensible ( obj )
/// https://tc39.es/ecma262/#sec-ordinaryisextensible
pub fn ordinaryIsExtensible(obj: *Object) bool {
    // 1. Return obj.[[Extensible]].
    return obj.extensible();
}

/// 10.1.4 [[PreventExtensions]] ( )
/// https://tc39.es/ecma262/#sec-ordinary-object-internal-methods-and-internal-slots-preventextensions
fn preventExtensions(agent: *Agent, obj: *Object) std.mem.Allocator.Error!bool {
    // 1. Return OrdinaryPreventExtensions(obj).
    return ordinaryPreventExtensions(agent, obj);
}

/// 10.1.4.1 OrdinaryPreventExtensions ( obj )
/// https://tc39.es/ecma262/#sec-ordinarypreventextensions
pub fn ordinaryPreventExtensions(agent: *Agent, obj: *Object) std.mem.Allocator.Error!bool {
    // 1. Set obj.[[Extensible]] to false.
    try obj.setNonExtensible(agent);

    // 2. Return true.
    return true;
}

/// 10.1.5 [[GetOwnProperty]] ( propertyKey )
/// https://tc39.es/ecma262/#sec-ordinary-object-internal-methods-and-internal-slots-getownproperty-p
fn getOwnProperty(
    _: *Agent,
    obj: *Object,
    property_key: PropertyKey,
) std.mem.Allocator.Error!?PropertyDescriptor {
    // 1. Return OrdinaryGetOwnProperty(obj, propertyKey).
    return ordinaryGetOwnProperty(obj, property_key);
}

/// 10.1.5.1 OrdinaryGetOwnProperty ( obj, propertyKey )
/// https://tc39.es/ecma262/#sec-ordinarygetownproperty
pub fn ordinaryGetOwnProperty(
    obj: *Object,
    property_key: PropertyKey,
) std.mem.Allocator.Error!?PropertyDescriptor {
    // 1. If obj does not have an own property with key propertyKey, return undefined.
    // 2. Let propertyDesc be a newly created Property Descriptor with no fields.
    // 3. Let ownProperty be obj's own property whose key is propertyKey.
    // 4. If ownProperty is a data property, then
    //     a. Set propertyDesc.[[Value]] to the value of ownProperty's [[Value]] attribute.
    //     b. Set propertyDesc.[[Writable]] to the value of ownProperty's [[Writable]] attribute.
    // 5. Else,
    //     a. Assert: ownProperty is an accessor property.
    //     b. Set propertyDesc.[[Getter]] to the value of ownProperty's [[Getter]] attribute.
    //     c. Set propertyDesc.[[Setter]] to the value of ownProperty's [[Setter]] attribute.
    // 6. Set propertyDesc.[[Enumerable]] to the value of ownProperty's [[Enumerable]] attribute.
    // 7. Set propertyDesc.[[Configurable]] to the value of ownProperty's [[Configurable]]
    //    attribute.
    // 8. Return propertyDesc.
    // OPTIMIZATION: The Array length property is stored in fields instead of property storage.
    if (obj.is(builtins.Array) and property_key.isLength()) {
        return .{
            .value = Value.from(obj.as(builtins.Array).fields.length),
            .writable = obj.as(builtins.Array).fields.length_writable,
            .enumerable = false,
            .configurable = false,
        };
    }
    const property_desc = (try obj.getPropertyCreateLazyIfNeeded(property_key)) orelse return null;
    return property_desc.toPropertyDescriptor();
}

/// 10.1.6 [[DefineOwnProperty]] ( propertyKey, propertyDesc )
/// https://tc39.es/ecma262/#sec-ordinary-object-internal-methods-and-internal-slots-defineownproperty-p-desc
fn defineOwnProperty(
    agent: *Agent,
    obj: *Object,
    property_key: PropertyKey,
    property_desc: PropertyDescriptor,
) Agent.Error!bool {
    // 1. Return ? OrdinaryDefineOwnProperty(obj, propertyKey, propertyDesc).
    return ordinaryDefineOwnProperty(agent, obj, property_key, property_desc);
}

/// 10.1.6.1 OrdinaryDefineOwnProperty ( obj, propertyKey, propertyDesc )
/// https://tc39.es/ecma262/#sec-ordinarydefineownproperty
pub fn ordinaryDefineOwnProperty(
    agent: *Agent,
    obj: *Object,
    property_key: PropertyKey,
    property_desc: PropertyDescriptor,
) Agent.Error!bool {
    // 1. Let current be ? obj.[[GetOwnProperty]](propertyKey).
    const current = try obj.internalMethods().getOwnProperty(agent, obj, property_key);

    // 2. Let extensible be ? IsExtensible(obj).
    const extensible = try obj.isExtensible(agent);

    // 3. Return ValidateAndApplyPropertyDescriptor(obj, propertyKey, extensible, propertyDesc,
    //    current).
    return validateAndApplyPropertyDescriptor(
        agent.gc_allocator,
        obj,
        property_key,
        extensible,
        property_desc,
        current,
    );
}

/// 10.1.6.2 IsCompatiblePropertyDescriptor ( extensible, propertyDesc, current )
/// https://tc39.es/ecma262/#sec-iscompatiblepropertydescriptor
pub fn isCompatiblePropertyDescriptor(
    extensible: bool,
    property_desc: PropertyDescriptor,
    current: ?PropertyDescriptor,
) bool {
    // 1. Return ValidateAndApplyPropertyDescriptor(undefined, "", extensible, propertyDesc,
    //    current).
    return validateAndApplyPropertyDescriptor(
        undefined, // No Allocator needed when not passing an object
        null,
        PropertyKey.from(""),
        extensible,
        property_desc,
        current,
    ) catch unreachable;
}

/// 10.1.6.3 ValidateAndApplyPropertyDescriptor ( obj, propertyKey, extensible, propertyDesc, current )
/// https://tc39.es/ecma262/#sec-validateandapplypropertydescriptor
fn validateAndApplyPropertyDescriptor(
    allocator: std.mem.Allocator,
    maybe_obj: ?*Object,
    property_key: PropertyKey,
    extensible: bool,
    property_desc: PropertyDescriptor,
    maybe_current: ?PropertyDescriptor,
) std.mem.Allocator.Error!bool {
    // 1. Assert: propertyKey is a property key.

    // 2. If current is undefined, then
    const current = maybe_current orelse {
        // a. If extensible is false, return false.
        if (!extensible) return false;

        // b. If obj is undefined, return true.
        const obj = maybe_obj orelse return true;

        // c. If IsAccessorDescriptor(propertyDesc) is true, then
        const complete_property_desc: Object.CompletePropertyDescriptor = if (property_desc.isAccessorDescriptor()) blk: {
            // i. Create an own accessor property named propertyKey of object obj whose [[Getter]],
            //    [[Setter]], [[Enumerable]], and [[Configurable]] attributes are set to the value
            //    of the corresponding field in propertyDesc if propertyDesc has that field, or to
            //    the attribute's default value otherwise.
            break :blk .{
                .value_or_accessor = .{ .accessor = .{
                    .getter = property_desc.getter orelse @as(?*Object, null),
                    .setter = property_desc.setter orelse @as(?*Object, null),
                } },
                .attributes = .{
                    .writable = false,
                    .enumerable = property_desc.enumerable orelse false,
                    .configurable = property_desc.configurable orelse false,
                },
            };
        } else blk: {
            // d. Else,
            // i. Create an own data property named propertyKey of object obj whose [[Value]],
            //    [[Writable]], [[Enumerable]], and [[Configurable]] attributes are set to the value
            //    of the corresponding field in propertyDesc if propertyDesc has that field, or to
            //    the attribute's default value otherwise.
            break :blk .{
                .value_or_accessor = .{ .value = property_desc.value orelse .undefined },
                .attributes = .{
                    .writable = property_desc.writable orelse false,
                    .enumerable = property_desc.enumerable orelse false,
                    .configurable = property_desc.configurable orelse false,
                },
            };
        };

        try obj.setProperty(allocator, property_key, complete_property_desc);

        // e. Return true.
        return true;
    };

    // 3. Assert: current is a fully populated Property Descriptor.
    std.debug.assert(current.isFullyPopulated());

    // 4. If propertyDesc does not have any fields, return true.
    if (!property_desc.hasFields()) return true;

    // 5. If current.[[Configurable]] is false, then
    if (!current.configurable.?) {
        // a. If propertyDesc has a [[Configurable]] field and propertyDesc.[[Configurable]] is
        //    true, return false.
        if (property_desc.configurable) |configurable| if (configurable) return false;

        // b. If propertyDesc has an [[Enumerable]] field and propertyDesc.[[Enumerable]] is not
        //    current.[[Enumerable]], return false.
        if (property_desc.enumerable) |enumerable| if (enumerable != current.enumerable.?) return false;

        // c. If IsGenericDescriptor(propertyDesc) is false and IsAccessorDescriptor(propertyDesc)
        //    is not IsAccessorDescriptor(current), return false.
        if (!property_desc.isGenericDescriptor() and
            property_desc.isAccessorDescriptor() != current.isAccessorDescriptor()) return false;

        // d. If IsAccessorDescriptor(current) is true, then
        if (current.isAccessorDescriptor()) {
            // i. If propertyDesc has a [[Getter]] field and SameValue(propertyDesc.[[Getter]],
            //    current.[[Getter]]) is false, return false.
            if (property_desc.getter != null and !(blk: {
                if (property_desc.getter.? == null and current.getter.? == null) break :blk true;
                if (property_desc.getter.?) |a| if (current.getter.?) |b| break :blk a == b;
                break :blk false;
            })) return false;

            // ii. If propertyDesc has a [[Setter]] field and SameValue(propertyDesc.[[Setter]],
            //     current.[[Setter]]) is false, return false.
            if (property_desc.setter != null and !(blk: {
                if (property_desc.setter.? == null and current.setter.? == null) break :blk true;
                if (property_desc.setter.?) |a| if (current.setter.?) |b| break :blk a == b;
                break :blk false;
            })) return false;
        }
        // e. Else if current.[[Writable]] is false, then
        else if (!current.writable.?) {
            // i. If propertyDesc has a [[Writable]] field and propertyDesc.[[Writable]] is true,
            //    return false.
            if (property_desc.writable) |writable| if (writable) return false;

            // ii. NOTE: SameValue returns true for NaN values which may be distinguishable by other
            //     means. Returning here ensures that any existing property of obj remains
            //     unmodified.
            // iii. If propertyDesc has a [[Value]] field, return SameValue(propertyDesc.[[Value]],
            //      current.[[Value]]).
            if (property_desc.value) |value| return sameValue(value, current.value.?);
        }
    }

    // 6. If obj is not undefined, then
    if (maybe_obj) |obj| {
        // a. If IsDataDescriptor(current) is true and IsAccessorDescriptor(propertyDesc) is true,
        //    then
        const complete_property_desc: Object.CompletePropertyDescriptor = if (current.isDataDescriptor() and property_desc.isAccessorDescriptor()) blk: {
            // i. If propertyDesc has a [[Configurable]] field, let configurable be
            //    propertyDesc.[[Configurable]]; else let configurable be current.[[Configurable]].
            const configurable = property_desc.configurable orelse current.configurable.?;

            // ii. If propertyDesc has an [[Enumerable]] field, let enumerable be
            //     propertyDesc.[[Enumerable]]; else let enumerable be current.[[Enumerable]].
            const enumerable = property_desc.enumerable orelse current.enumerable.?;

            // iii. Replace the property named propertyKey of object obj with an accessor property
            //      whose [[Configurable]] and [[Enumerable]] attributes are set to configurable and
            //      enumerable, respectively, and whose [[Getter]] and [[Setter]] attributes are set
            //      to the value of the corresponding field in propertyDesc if propertyDesc has that
            //      field, or to the attribute's default value otherwise.
            break :blk .{
                .value_or_accessor = .{ .accessor = .{
                    .getter = property_desc.getter orelse @as(?*Object, null),
                    .setter = property_desc.setter orelse @as(?*Object, null),
                } },
                .attributes = .{
                    .writable = false,
                    .enumerable = enumerable,
                    .configurable = configurable,
                },
            };
        } else if (current.isAccessorDescriptor() and property_desc.isDataDescriptor()) blk: {
            // b. Else if IsAccessorDescriptor(current) is true and IsDataDescriptor(propertyDesc)
            //    is true, then
            // i. If propertyDesc has a [[Configurable]] field, let configurable be
            //    propertyDesc.[[Configurable]]; else let configurable be current.[[Configurable]].
            const configurable = property_desc.configurable orelse current.configurable.?;

            // ii. If propertyDesc has an [[Enumerable]] field, let enumerable be
            //     propertyDesc.[[Enumerable]]; else let enumerable be current.[[Enumerable]].
            const enumerable = property_desc.enumerable orelse current.enumerable.?;

            // iii. Replace the property named propertyKey of object obj with a data property whose
            //      [[Configurable]] and [[Enumerable]] attributes are set to configurable and
            //      enumerable, respectively, and whose [[Value]] and [[Writable]] attributes are
            //      set to the value of the corresponding field in propertyDesc if propertyDesc has
            //      that field, or to the attribute's default value otherwise.
            break :blk .{
                .value_or_accessor = .{ .value = property_desc.value orelse .undefined },
                .attributes = .{
                    .writable = property_desc.writable orelse false,
                    .enumerable = enumerable,
                    .configurable = configurable,
                },
            };
        } else blk: {
            // c. Else,
            // i. For each field name fieldName of propertyDesc, set the attribute named fieldName
            //    of the property named propertyKey of object obj to the value of propertyDesc's
            //    fieldName field.
            if (current.isDataDescriptor()) {
                break :blk .{
                    .value_or_accessor = .{ .value = property_desc.value orelse current.value.? },
                    .attributes = .{
                        .writable = property_desc.writable orelse current.writable.?,
                        .enumerable = property_desc.enumerable orelse current.enumerable.?,
                        .configurable = property_desc.configurable orelse current.configurable.?,
                    },
                };
            } else {
                std.debug.assert(current.isAccessorDescriptor());
                break :blk .{
                    .value_or_accessor = .{ .accessor = .{
                        .getter = property_desc.getter orelse current.getter.?,
                        .setter = property_desc.setter orelse current.setter.?,
                    } },
                    .attributes = .{
                        .writable = false,
                        .enumerable = property_desc.enumerable orelse current.enumerable.?,
                        .configurable = property_desc.configurable orelse current.configurable.?,
                    },
                };
            }
        };

        try obj.setProperty(allocator, property_key, complete_property_desc);
    }

    // 7. Return true.
    return true;
}

/// 10.1.7 [[HasProperty]] ( propertyKey )
/// https://tc39.es/ecma262/#sec-ordinary-object-internal-methods-and-internal-slots-hasproperty-p
fn hasProperty(agent: *Agent, obj: *Object, property_key: PropertyKey) Agent.Error!bool {
    // 1. Return ? OrdinaryHasProperty(obj, propertyKey).
    return ordinaryHasProperty(agent, obj, property_key);
}

/// 10.1.7.1 OrdinaryHasProperty ( obj, propertyKey )
/// https://tc39.es/ecma262/#sec-ordinaryhasproperty
pub fn ordinaryHasProperty(
    agent: *Agent,
    obj: *Object,
    property_key: PropertyKey,
) Agent.Error!bool {
    // OPTIMIZATION: The Array length property is stored in fields instead of property storage.
    if (obj.is(builtins.Array) and property_key.isLength()) {
        return true;
    }

    const has_ordinary_internal_methods = obj.internalMethods().flags.supersetOf(comptime .initMany(&.{
        .ordinary_get_own_property,
        .ordinary_get_prototype_of,
    }));

    // OPTIMIZATION: Fast path for ordinary objects
    if (has_ordinary_internal_methods) {
        if (obj.containsProperty(property_key)) return true;
        const parent = obj.prototype() orelse return false;
        return parent.internalMethods().hasProperty(agent, parent, property_key);
    }

    // 1. Let hasOwn be ? obj.[[GetOwnProperty]](propertyKey).
    const has_own = try obj.internalMethods().getOwnProperty(agent, obj, property_key);

    // 2. If hasOwn is not undefined, return true.
    if (has_own != null) return true;

    // 3. Let parent be ? obj.[[GetPrototypeOf]]().
    const parent = try obj.internalMethods().getPrototypeOf(agent, obj);

    // 4. If parent is not null, then
    if (parent) |parent_object| {
        // a. Return ? parent.[[HasProperty]](propertyKey).
        return parent_object.internalMethods().hasProperty(agent, parent_object, property_key);
    }

    // 5. Return false.
    return false;
}

/// 10.1.8 [[Get]] ( propertyKey, receiver )
/// https://tc39.es/ecma262/#sec-ordinary-object-internal-methods-and-internal-slots-get-p-receiver
fn get(
    agent: *Agent,
    obj: *Object,
    property_key: PropertyKey,
    receiver: Value,
) Agent.Error!Value {
    // 1. Return ? OrdinaryGet(obj, propertyKey, receiver).
    return ordinaryGet(agent, obj, property_key, receiver);
}

/// 10.1.8.1 OrdinaryGet ( obj, propertyKey, receiver )
/// https://tc39.es/ecma262/#sec-ordinaryget
pub fn ordinaryGet(
    agent: *Agent,
    obj: *Object,
    property_key: PropertyKey,
    receiver: Value,
) Agent.Error!Value {
    // OPTIMIZATION: The Array length property is stored in fields instead of property storage.
    if (obj.is(builtins.Array) and property_key.isLength()) {
        return Value.from(obj.as(builtins.Array).fields.length);
    }

    const has_ordinary_internal_methods = obj.internalMethods().flags.supersetOf(comptime .initMany(&.{
        .ordinary_get_own_property,
        .ordinary_get_prototype_of,
    }));

    // OPTIMIZATION: Fast path for ordinary objects
    if (has_ordinary_internal_methods) {
        // If we have an array index, dense storage, and no out of bounds access, return the value directly.
        if (property_key.isArrayIndex()) {
            if (obj.getIndexedFast(@intCast(property_key.integer_index))) |value| {
                return value;
            }
        }
        // Otherwise go through the prototype chain and invoke the getter if necessary.
        const property_desc = try obj.getPropertyCreateLazyIfNeeded(property_key) orelse {
            const parent = obj.prototype() orelse return .undefined;
            return parent.internalMethods().get(agent, parent, property_key, receiver);
        };
        switch (property_desc.value_or_accessor) {
            .value => |value| return value,
            .accessor => |accessor| {
                const getter = accessor.getter orelse return .undefined;
                return getter.call(agent, receiver, &.{});
            },
        }
    }

    // 1. Let propertyDesc be ? obj.[[GetOwnProperty]](propertyKey).
    const property_desc = try obj.internalMethods().getOwnProperty(agent, obj, property_key) orelse {
        // 2. If propertyDesc is undefined, then
        // a. Let parent be ? obj.[[GetPrototypeOf]]().
        const parent = try obj.internalMethods().getPrototypeOf(agent, obj) orelse {
            // b. If parent is null, return undefined.
            return .undefined;
        };

        // c. Return ? parent.[[Get]](propertyKey, receiver).
        return parent.internalMethods().get(agent, parent, property_key, receiver);
    };

    // 3. If IsDataDescriptor(propertyDesc) is true, return propertyDesc.[[Value]].
    if (property_desc.value) |value| {
        std.debug.assert(property_desc.isDataDescriptor());
        return value;
    }

    // 4. Assert: IsAccessorDescriptor(propertyDesc) is true.
    std.debug.assert(property_desc.isAccessorDescriptor());

    // 5. Let getter be propertyDesc.[[Getter]].
    // 6. If getter is undefined, return undefined.
    const getter = property_desc.getter.? orelse return .undefined;

    // 7. Return ? Call(getter, receiver).
    return getter.call(agent, receiver, &.{});
}

/// 10.1.9 [[Set]] ( propertyKey, value, receiver )
/// https://tc39.es/ecma262/#sec-ordinary-object-internal-methods-and-internal-slots-set-p-v-receiver
fn set(
    agent: *Agent,
    obj: *Object,
    property_key: PropertyKey,
    value: Value,
    receiver: Value,
) Agent.Error!bool {
    // 1. Return ? OrdinarySet(obj, propertyKey, value, receiver).
    return ordinarySet(agent, obj, property_key, value, receiver);
}

/// 10.1.9.1 OrdinarySet ( obj, propertyKey, value, receiver )
/// https://tc39.es/ecma262/#sec-ordinaryset
pub fn ordinarySet(
    agent: *Agent,
    obj: *Object,
    property_key: PropertyKey,
    value: Value,
    receiver: Value,
) Agent.Error!bool {
    const has_ordinary_internal_methods = obj.internalMethods().flags.supersetOf(comptime .initMany(&.{
        .ordinary_get_own_property,
        .ordinary_get_prototype_of,
        .ordinary_is_extensible,
        .ordinary_define_own_property,
    }));
    const receiver_is_self = receiver.isObject() and obj == receiver.asObject();

    // OPTIMIZATION: Fast path for ordinary objects and regular properties
    // This excludes arrays which have a custom defineOwnProperty method for the length property.
    if (!property_key.isArrayIndex() and
        has_ordinary_internal_methods and
        receiver_is_self)
    {
        const property = obj.shape.properties.get(property_key) orelse {
            if (obj.prototype()) |parent| {
                return parent.internalMethods().set(agent, parent, property_key, value, receiver);
            }
            if (!obj.extensible()) return false;
            try obj.setProperty(agent.gc_allocator, property_key, .{
                .value_or_accessor = .{
                    .value = value,
                },
                .attributes = .all,
            });
            return true;
        };
        switch (property.type) {
            .value => {
                if (!property.attributes.writable) {
                    @branchHint(.unlikely);
                    return false;
                }
                obj.setValueAtPropertyOffset(property.offset, value);
            },
            .accessor => {
                const setter_value = obj.getValueAtPropertyOffset(
                    @fromBackingInt(@backingInt(property.offset) + 1),
                );
                if (setter_value.isNull()) {
                    @branchHint(.unlikely);
                    return false;
                }
                const setter = setter_value.asObject();
                _ = try setter.call(agent, receiver, &.{value});
            },
        }
        return true;
    }

    // OPTIMIZATION: Fast path for ordinary objects or arrays and indexed properties
    if (property_key.isArrayIndex() and receiver_is_self) {
        if (try obj.setIndexedFast(agent.gc_allocator, @intCast(property_key.integer_index), value)) {
            return true;
        }
    }

    // 1. Let ownDesc be ? obj.[[GetOwnProperty]](propertyKey).
    const own_desc = try obj.internalMethods().getOwnProperty(agent, obj, property_key);

    // 2. Return ? OrdinarySetWithOwnDescriptor(obj, propertyKey, value, receiver, ownDesc).
    return ordinarySetWithOwnDescriptor(
        agent,
        obj,
        property_key,
        value,
        receiver,
        own_desc,
    );
}

/// 10.1.9.2 OrdinarySetWithOwnDescriptor ( obj, propertyKey, value, receiver, ownDesc )
/// https://tc39.es/ecma262/#sec-ordinarysetwithowndescriptor
pub fn ordinarySetWithOwnDescriptor(
    agent: *Agent,
    obj: *Object,
    property_key: PropertyKey,
    value: Value,
    receiver_value: Value,
    maybe_own_desc: ?PropertyDescriptor,
) Agent.Error!bool {
    // 1. If ownDesc is undefined, then
    const own_desc = maybe_own_desc orelse blk: {
        // a. Let parent be ? obj.[[GetPrototypeOf]]().
        const parent = try obj.internalMethods().getPrototypeOf(agent, obj);

        // b. If parent is not null, return ? parent.[[Set]](propertyKey, value, receiver).
        if (parent) |parent_obj| {
            return parent_obj.internalMethods().set(
                agent,
                parent_obj,
                property_key,
                value,
                receiver_value,
            );
        }

        // c. Set ownDesc to the PropertyDescriptor { [[Value]]: undefined, [[Writable]]: true,
        //    [[Enumerable]]: true, [[Configurable]]: true }.
        break :blk PropertyDescriptor{
            .value = .undefined,
            .writable = true,
            .enumerable = true,
            .configurable = true,
        };
    };

    // 2. If IsDataDescriptor(ownDesc) is true, then
    if (own_desc.isDataDescriptor()) {
        // a. If ownDesc.[[Writable]] is false, return false.
        if (own_desc.writable == false) return false;

        // b. If receiver is not an Object, return false.
        if (!receiver_value.isObject()) return false;
        const receiver = receiver_value.asObject();

        // c. Let existingDesc be ? receiver.[[GetOwnProperty]](propertyKey).
        const existing_desc = try receiver.internalMethods().getOwnProperty(
            agent,
            receiver,
            property_key,
        ) orelse {
            // d. If existingDesc is undefined, then
            // i. Assert: receiver does not currently have a property propertyKey.
            std.debug.assert(!receiver.containsProperty(property_key));

            // ii. Return ? CreateDataProperty(receiver, propertyKey, value).
            return receiver.createDataProperty(agent, property_key, value);
        };

        // e. If IsAccessorDescriptor(existingDesc) is true, return false.
        if (existing_desc.isAccessorDescriptor()) return false;

        // f. If existingDesc.[[Writable]] is false, return false.
        if (existing_desc.writable == false) return false;

        // g. Let valueDesc be the PropertyDescriptor { [[Value]]: value }.
        const value_descriptor: PropertyDescriptor = .{ .value = value };

        // h. Return ? receiver.[[DefineOwnProperty]](propertyKey, valueDesc).
        return receiver.internalMethods().defineOwnProperty(
            agent,
            receiver,
            property_key,
            value_descriptor,
        );
    }

    // 3. Assert: IsAccessorDescriptor(ownDesc) is true.
    std.debug.assert(own_desc.isAccessorDescriptor());

    // 4. Let setter be ownDesc.[[Setter]].
    // 5. If setter is undefined, return false.
    const setter = own_desc.setter.? orelse return false;

    // 6. Perform ? Call(setter, receiver, « value »).
    _ = try setter.call(agent, receiver_value, &.{value});

    // 7. Return true.
    return true;
}

/// 10.1.10 [[Delete]] ( propertyKey )
/// https://tc39.es/ecma262/#sec-ordinary-object-internal-methods-and-internal-slots-delete-p
fn delete(agent: *Agent, obj: *Object, property_key: PropertyKey) Agent.Error!bool {
    // 1. Return ? OrdinaryDelete(obj, propertyKey).
    return ordinaryDelete(agent, obj, property_key);
}

/// 10.1.10.1 OrdinaryDelete ( obj, propertyKey )
/// https://tc39.es/ecma262/#sec-ordinarydelete
pub fn ordinaryDelete(agent: *Agent, obj: *Object, property_key: PropertyKey) Agent.Error!bool {
    // OPTIMIZATION: The Array length property is stored in fields instead of property storage.
    if (obj.is(builtins.Array) and property_key.isLength()) {
        return false;
    }

    // 1. Let propertyDesc be ? obj.[[GetOwnProperty]](propertyKey).
    const property_desc = try obj.internalMethods().getOwnProperty(
        agent,
        obj,
        property_key,
    ) orelse {
        // 2. If propertyDesc is undefined, return true.
        return true;
    };

    // 3. If propertyDesc.[[Configurable]] is true, then
    if (property_desc.configurable == true) {
        // a. Remove the own property with name propertyKey from obj.
        try obj.removeProperty(agent.gc_allocator, property_key);

        // b. Return true.
        return true;
    }

    // 4. Return false.
    return false;
}

/// 10.1.11 [[OwnPropertyKeys]] ( )
/// https://tc39.es/ecma262/#sec-ordinary-object-internal-methods-and-internal-slots-ownpropertykeys
fn ownPropertyKeys(agent: *Agent, obj: *Object) std.mem.Allocator.Error![]PropertyKey {
    // 1. Return OrdinaryOwnPropertyKeys(obj).
    return ordinaryOwnPropertyKeys(agent.gc_allocator, obj);
}

/// 10.1.11.1 OrdinaryOwnPropertyKeys ( obj )
/// https://tc39.es/ecma262/#sec-ordinaryownpropertykeys
pub fn ordinaryOwnPropertyKeys(
    allocator: std.mem.Allocator,
    obj: *Object,
) std.mem.Allocator.Error![]PropertyKey {
    const indexed_properties = obj.indexedProperties();

    // 1. Let keys be a new empty List.
    var keys = try std.ArrayList(PropertyKey).initCapacity(
        allocator,
        indexed_properties.count() +
            obj.shape.properties.count() +
            @intFromBool(obj.is(builtins.Array)),
    );

    // 2. For each own property key propertyKey of obj such that propertyKey is an array index, in
    //    ascending numeric index order, do
    //     a. Append propertyKey to keys.
    switch (indexed_properties.storage) {
        .none => {},
        inline .sparse_value, .sparse_property_descriptor => |sparse| {
            var it = sparse.keyIterator();
            while (it.next()) |index| {
                const property_key = PropertyKey.from(@as(PropertyKey.IntegerIndex, @intCast(index.*)));
                keys.appendAssumeCapacity(property_key);
            }
            std.mem.sortUnstable(PropertyKey, keys.items, {}, struct {
                fn lessThanFn(_: void, a: PropertyKey, b: PropertyKey) bool {
                    return a.integer_index < b.integer_index;
                }
            }.lessThanFn);
        },
        else => {
            for (0..indexed_properties.count()) |index| {
                const property_key = PropertyKey.from(@as(PropertyKey.IntegerIndex, @intCast(index)));
                keys.appendAssumeCapacity(property_key);
            }
        },
    }

    // OPTIMIZATION: The Array length property is stored in fields instead of property storage.
    if (obj.is(builtins.Array)) {
        // Always the first property in chronological order
        keys.appendAssumeCapacity(PropertyKey.from("length"));
    }

    // 3. For each own property key propertyKey of obj such that propertyKey is a String and
    //    propertyKey is not an array index, in ascending chronological order of property creation,
    //    do
    for (obj.shape.properties.keys()) |property_key| {
        if (property_key == .string or property_key == .integer_index) {
            std.debug.assert(!property_key.isArrayIndex());

            // a. Append propertyKey to keys.
            keys.appendAssumeCapacity(property_key);
        }
    }

    // 4. For each own property key propertyKey of obj such that propertyKey is a Symbol, in
    //    ascending chronological order of property creation, do
    for (obj.shape.properties.keys()) |property_key| {
        if (property_key == .symbol) {
            // a. Append propertyKey to keys.
            keys.appendAssumeCapacity(property_key);
        }
    }

    // 5. Return keys.
    return keys.toOwnedSlice(allocator);
}

pub fn ordinaryObjectCreate(agent: *Agent, proto: ?*Object) std.mem.Allocator.Error!*Object {
    const object = try ordinaryObjectCreateWithType(builtins.Object, agent, proto, {});
    return &object.object;
}

pub fn ordinaryObjectCreateFast(agent: *Agent) std.mem.Allocator.Error!*Object {
    const realm = agent.currentRealm();
    const shape = try realm.shape(.ordinary_object);
    const object = try builtins.Object.createWithShape(agent, .{ .shape = shape });
    return &object.object;
}

/// 10.1.12 OrdinaryObjectCreate ( proto [ , additionalInternalSlotsList ] )
/// https://tc39.es/ecma262/#sec-ordinaryobjectcreate
pub fn ordinaryObjectCreateWithType(
    comptime T: type,
    agent: *Agent,
    proto: ?*Object,
    fields: T.Fields,
) std.mem.Allocator.Error!*T {
    // 1. Let internalSlotsList be « [[Prototype]], [[Extensible]] ».
    // 2. If additionalInternalSlotsList is present, set internalSlotsList to the list-concatenation
    //    of internalSlotsList and additionalInternalSlotsList.

    // 3. Let obj be MakeBasicObject(internalSlotsList).
    // 4. Set obj.[[Prototype]] to proto.
    // 5. Return obj.
    return T.create(agent, if (T.Fields != void) .{
        .prototype = proto,
        .fields = fields,
    } else .{
        .prototype = proto,
    });
}

/// 10.1.13 OrdinaryCreateFromConstructor ( ctor, intrinsicDefaultProto [ , internalSlotsList ] )
/// https://tc39.es/ecma262/#sec-ordinarycreatefromconstructor
pub fn ordinaryCreateFromConstructor(
    comptime T: type,
    agent: *Agent,
    ctor: *Object,
    comptime intrinsic_default_proto: Realm.Intrinsic,
    fields: T.Fields,
) Agent.Error!*T {
    // 1. Assert: intrinsicDefaultProto is this specification's name of an intrinsic object. The
    //    corresponding object must be an intrinsic that is intended to be used as the [[Prototype]]
    //    value of an object.

    // 2. Let proto be ? GetPrototypeFromConstructor(ctor, intrinsicDefaultProto).
    const proto = try getPrototypeFromConstructor(agent, ctor, intrinsic_default_proto);

    // 3. If internalSlotsList is present, let slots be internalSlotsList.
    // 4. Else, let slots be a new empty List.
    // 5. Return OrdinaryObjectCreate(proto, slots).
    return ordinaryObjectCreateWithType(T, agent, proto, fields);
}

/// 10.1.14 GetPrototypeFromConstructor ( ctor, intrinsicDefaultProto )
/// https://tc39.es/ecma262/#sec-getprototypefromconstructor
pub fn getPrototypeFromConstructor(
    agent: *Agent,
    ctor: *Object,
    comptime intrinsic_default_proto: Realm.Intrinsic,
) Agent.Error!*Object {
    // 1. Assert: intrinsicDefaultProto is this specification's name of an intrinsic object. The
    //    corresponding object must be an intrinsic that is intended to be used as the [[Prototype]]
    //    value of an object.

    // 2. Let proto be ? Get(ctor, "prototype").
    const proto_value = try ctor.get(agent, PropertyKey.from("prototype"));

    const proto = switch (proto_value.type()) {
        .object => proto_value.asObject(),

        // 3. If proto is not an Object, then
        else => blk: {
            // a. Let realm be ? GetFunctionRealm(ctor).
            const realm = try ctor.getFunctionRealm(agent);

            // b. Set proto to realm's intrinsic object named intrinsicDefaultProto.
            break :blk try realm.intrinsic(intrinsic_default_proto);
        },
    };

    // 4. Return proto.
    return proto;
}
