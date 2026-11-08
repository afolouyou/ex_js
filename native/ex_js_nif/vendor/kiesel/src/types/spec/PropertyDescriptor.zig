//! 6.2.6 The Property Descriptor Specification Type
//! https://tc39.es/ecma262/#sec-property-descriptor-specification-type

const std = @import("std");

const builtins = @import("../../builtins.zig");
const execution = @import("../../execution.zig");
const language = @import("../language.zig");

const Agent = execution.Agent;
const Object = language.Object;
const PropertyKey = language.Object.PropertyKey;
const Value = language.Value;
const ordinaryObjectCreate = builtins.ordinaryObjectCreate;

const PropertyDescriptor = @This();

/// [[Value]]
value: ?Value = null,

/// [[Writable]]
writable: ?bool = null,

/// [[Getter]]
getter: ??*Object = null,

/// [[Setter]]
setter: ??*Object = null,

/// [[Enumerable]]
enumerable: ?bool = null,

/// [[Configurable]]
configurable: ?bool = null,

/// 6.2.6.1 IsAccessorDescriptor ( propertyDesc )
/// https://tc39.es/ecma262/#sec-isaccessordescriptor
pub fn isAccessorDescriptor(property_desc: *const PropertyDescriptor) bool {
    // 1. If propertyDesc has a [[Getter]] field, return true.
    // 2. If propertyDesc has a [[Setter]] field, return true.
    // 3. Return false.
    return property_desc.getter != null or property_desc.setter != null;
}

/// 6.2.6.2 IsDataDescriptor ( propertyDesc )
/// https://tc39.es/ecma262/#sec-isdatadescriptor
pub fn isDataDescriptor(property_desc: *const PropertyDescriptor) bool {
    // 1. If propertyDesc has a [[Value]] field, return true.
    // 2. If propertyDesc has a [[Writable]] field, return true.
    // 3. Return false.
    return property_desc.value != null or property_desc.writable != null;
}

/// 6.2.6.3 IsGenericDescriptor ( propertyDesc )
/// https://tc39.es/ecma262/#sec-isgenericdescriptor
pub fn isGenericDescriptor(property_desc: *const PropertyDescriptor) bool {
    // 1. If IsAccessorDescriptor(propertyDesc) is true, return false.
    // 2. If IsDataDescriptor(propertyDesc) is true, return false.
    // 3. Return true.
    return !(property_desc.isAccessorDescriptor() or property_desc.isDataDescriptor());
}

/// 6.2.6.4 FromPropertyDescriptor ( propertyDesc )
/// https://tc39.es/ecma262/#sec-frompropertydescriptor
pub fn fromPropertyDescriptor(
    property_desc: *const PropertyDescriptor,
    agent: *Agent,
) std.mem.Allocator.Error!*Object {
    const realm = agent.currentRealm();

    // 1. If propertyDesc is undefined, return undefined.

    // 2. Let obj be OrdinaryObjectCreate(%Object.prototype%).
    // 3. Assert: obj is an extensible ordinary object with no own properties.
    const obj = try ordinaryObjectCreate(agent, try realm.intrinsic(.object_prototype));

    // 4. If propertyDesc has a [[Value]] field, then
    if (property_desc.value) |value| {
        // a. Perform ! CreateDataPropertyOrThrow(obj, "value", propertyDesc.[[Value]]).
        try obj.createDataPropertyDirect(
            agent,
            PropertyKey.from("value"),
            value,
        );
    }

    // 5. If propertyDesc has a [[Writable]] field, then
    if (property_desc.writable) |writable| {
        // a. Perform ! CreateDataPropertyOrThrow(obj, "writable", propertyDesc.[[Writable]]).
        try obj.createDataPropertyDirect(
            agent,
            PropertyKey.from("writable"),
            Value.from(writable),
        );
    }

    // 6. If propertyDesc has a [[Getter]] field, then
    if (property_desc.getter) |getter| {
        // a. Perform ! CreateDataPropertyOrThrow(obj, "get", propertyDesc.[[Getter]]).
        try obj.createDataPropertyDirect(
            agent,
            PropertyKey.from("get"),
            if (getter) |o| Value.from(o) else .undefined,
        );
    }

    // 7. If propertyDesc has a [[Setter]] field, then
    if (property_desc.setter) |setter| {
        // a. Perform ! CreateDataPropertyOrThrow(obj, "set", propertyDesc.[[Setter]]).
        try obj.createDataPropertyDirect(
            agent,
            PropertyKey.from("set"),
            if (setter) |o| Value.from(o) else .undefined,
        );
    }

    // 8. If propertyDesc has an [[Enumerable]] field, then
    if (property_desc.enumerable) |enumerable| {
        // a. Perform ! CreateDataPropertyOrThrow(obj, "enumerable", propertyDesc.[[Enumerable]]).
        try obj.createDataPropertyDirect(
            agent,
            PropertyKey.from("enumerable"),
            Value.from(enumerable),
        );
    }

    // 9. If propertyDesc has a [[Configurable]] field, then
    if (property_desc.configurable) |configurable| {
        // a. Perform ! CreateDataPropertyOrThrow(obj, "configurable",
        //    propertyDesc.[[Configurable]]).
        try obj.createDataPropertyDirect(
            agent,
            PropertyKey.from("configurable"),
            Value.from(configurable),
        );
    }

    // 10. Return obj.
    return obj;
}

/// 6.2.6.6 CompletePropertyDescriptor ( propertyDesc )
/// https://tc39.es/ecma262/#sec-completepropertydescriptor
pub fn completePropertyDescriptor(property_desc: *PropertyDescriptor) void {
    // 1. Let like be the Record { [[Value]]: undefined, [[Writable]]: false, [[Getter]]: undefined,
    //    [[Setter]]: undefined, [[Enumerable]]: false, [[Configurable]]: false }.
    const like: PropertyDescriptor = .{
        .value = .undefined,
        .writable = false,
        .enumerable = false,
        .configurable = false,
    };

    // 2. If IsGenericDescriptor(propertyDesc) is true or IsDataDescriptor(propertyDesc) is true,
    //    then
    if (property_desc.isGenericDescriptor() or property_desc.isDataDescriptor()) {
        // a. If propertyDesc does not have a [[Value]] field, set propertyDesc.[[Value]] to
        //    like.[[Value]].
        if (property_desc.value == null) property_desc.value = like.value;

        // b. If propertyDesc does not have a [[Writable]] field, set propertyDesc.[[Writable]] to
        //    like.[[Writable]].
        if (property_desc.writable == null) property_desc.writable = like.writable;
    } else {
        // 3. Else,
        // a. If propertyDesc does not have a [[Getter]] field, set propertyDesc.[[Getter]] to
        //    like.[[Getter]].
        // b. If propertyDesc does not have a [[Setter]] field, set propertyDesc.[[Setter]] to
        //    like.[[Setter]].
        // NOTE: These are no-ops, the fields can't be missing.
    }

    // 4. If propertyDesc does not have an [[Enumerable]] field, set propertyDesc.[[Enumerable]] to
    //    like.[[Enumerable]].
    if (property_desc.enumerable == null) property_desc.enumerable = like.enumerable;

    // 5. If propertyDesc does not have a [[Configurable]] field, set propertyDesc.[[Configurable]]
    //    to like.[[Configurable]].
    if (property_desc.configurable == null) property_desc.configurable = like.configurable;

    // 6. Return unused.
}

pub fn isFullyPopulated(property_desc: *const PropertyDescriptor) bool {
    return ((property_desc.value != null and property_desc.writable != null) or
        (property_desc.getter != null or property_desc.setter != null)) and
        property_desc.enumerable != null and
        property_desc.configurable != null;
}

pub fn hasFields(property_desc: *const PropertyDescriptor) bool {
    return property_desc.value != null or
        property_desc.writable != null or
        property_desc.getter != null or
        property_desc.setter != null or
        property_desc.enumerable != null or
        property_desc.configurable != null;
}

test isAccessorDescriptor {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var environ_map = try std.process.Environ.createMap(.empty, gpa);
    defer environ_map.deinit();
    const platform: Agent.Platform = .default(io, &environ_map);
    defer platform.deinit();
    var agent = try Agent.init(gpa, io, &platform, .{});
    defer agent.deinit();
    const getter = try ordinaryObjectCreate(&agent, null);
    const setter = try ordinaryObjectCreate(&agent, null);
    try std.testing.expect((PropertyDescriptor{ .getter = getter }).isAccessorDescriptor());
    try std.testing.expect((PropertyDescriptor{ .setter = setter }).isAccessorDescriptor());
    try std.testing.expect((PropertyDescriptor{ .getter = getter, .setter = setter }).isAccessorDescriptor());
    try std.testing.expect(!(PropertyDescriptor{ .value = .undefined }).isAccessorDescriptor());
    try std.testing.expect(!(PropertyDescriptor{}).isAccessorDescriptor());
}

test isDataDescriptor {
    try std.testing.expect((PropertyDescriptor{ .value = .undefined }).isDataDescriptor());
    try std.testing.expect((PropertyDescriptor{ .writable = true }).isDataDescriptor());
    try std.testing.expect(!(PropertyDescriptor{ .writable = null }).isDataDescriptor());
    try std.testing.expect(!(PropertyDescriptor{}).isDataDescriptor());
}

test isGenericDescriptor {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var environ_map = try std.process.Environ.createMap(.empty, gpa);
    defer environ_map.deinit();
    const platform: Agent.Platform = .default(io, &environ_map);
    defer platform.deinit();
    var agent = try Agent.init(gpa, io, &platform, .{});
    defer agent.deinit();
    const setter = try ordinaryObjectCreate(&agent, null);
    try std.testing.expect((PropertyDescriptor{ .writable = null }).isGenericDescriptor());
    try std.testing.expect(!(PropertyDescriptor{ .setter = setter }).isGenericDescriptor());
    try std.testing.expect((PropertyDescriptor{}).isGenericDescriptor());
}
