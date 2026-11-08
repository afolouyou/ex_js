//! 28.2 Proxy Objects
//! https://tc39.es/ecma262/#sec-proxy-objects

const std = @import("std");

const builtins = @import("../builtins.zig");
const execution = @import("../execution.zig");
const types = @import("../types.zig");

const Agent = execution.Agent;
const Arguments = types.Arguments;
const MakeObject = types.MakeObject;
const Object = types.Object;
const PropertyDescriptor = types.PropertyDescriptor;
const PropertyKey = types.PropertyKey;
const Realm = execution.Realm;
const Value = types.Value;
const createArrayFromList = types.createArrayFromList;
const createBuiltinFunction = builtins.createBuiltinFunction;
const isCompatiblePropertyDescriptor = builtins.isCompatiblePropertyDescriptor;
const ordinaryObjectCreate = builtins.ordinaryObjectCreate;
const sameValue = types.sameValue;

/// 10.5.1 [[GetPrototypeOf]] ( )
/// https://tc39.es/ecma262/#sec-proxy-object-internal-methods-and-internal-slots-getprototypeof
fn getPrototypeOf(agent: *Agent, obj: *Object) Agent.Error!?*Object {
    const proxy = obj.as(Proxy);

    // 1. Perform ? ValidateNonRevokedProxy(obj).
    try validateNonRevokedProxy(agent, proxy);

    // 2. Let target be obj.[[ProxyTarget]].
    const target = proxy.fields.proxy_target.?;

    // 3. Let handler be obj.[[ProxyHandler]].
    // 4. Assert: handler is an Object.
    const handler = proxy.fields.proxy_handler.?;

    // 5. Let trap be ? GetMethod(handler, "getPrototypeOf").
    const trap = try handler.getMethod(agent, PropertyKey.from("getPrototypeOf")) orelse {
        // 6. If trap is undefined, then
        //     a. Return ? target.[[GetPrototypeOf]]().
        return target.internalMethods().getPrototypeOf(agent, target);
    };

    // 7. Let handlerProto be ? Call(trap, handler, « target »).
    const handler_proto = try trap.call(agent, Value.from(handler), &.{Value.from(target)});

    // 8. If handlerProto is not an Object and handlerProto is not null, throw a TypeError
    //    exception.
    if (!handler_proto.isObject() and !handler_proto.isNull()) {
        return agent.throwException(
            .type_error,
            "{f} is not an Object or null",
            .{handler_proto},
        );
    }

    // 9. Let extensibleTarget be ? IsExtensible(target).
    const extensible_target = try target.isExtensible(agent);

    // 10. If extensibleTarget is true, return handlerProto.
    if (extensible_target) {
        return if (handler_proto.isObject()) handler_proto.asObject() else null;
    }

    // 11. Let targetProto be ? target.[[GetPrototypeOf]]().
    const target_proto = try target.internalMethods().getPrototypeOf(agent, target);

    // 12. If SameValue(handlerProto, targetProto) is false, throw a TypeError exception.
    if (!sameValue(
        handler_proto,
        if (target_proto != null) Value.from(target_proto.?) else .null,
    )) {
        return agent.throwException(
            .type_error,
            "Proxy 'getPrototypeOf' trap must return same prototype for non-extensible target",
            .{},
        );
    }

    // 13. Return handlerProto.
    return if (handler_proto.isObject()) handler_proto.asObject() else null;
}

/// 10.5.2 [[SetPrototypeOf]] ( proto )
/// https://tc39.es/ecma262/#sec-proxy-object-internal-methods-and-internal-slots-setprototypeof-v
fn setPrototypeOf(agent: *Agent, obj: *Object, proto: ?*Object) Agent.Error!bool {
    const proxy = obj.as(Proxy);

    // 1. Perform ? ValidateNonRevokedProxy(obj).
    try validateNonRevokedProxy(agent, proxy);

    // 2. Let target be obj.[[ProxyTarget]].
    const target = proxy.fields.proxy_target.?;

    // 3. Let handler be obj.[[ProxyHandler]].
    // 4. Assert: handler is an Object.
    const handler = proxy.fields.proxy_handler.?;

    // 5. Let trap be ? GetMethod(handler, "setPrototypeOf").
    const trap = try handler.getMethod(agent, PropertyKey.from("setPrototypeOf")) orelse {
        // 6. If trap is undefined, then
        //     a. Return ? target.[[SetPrototypeOf]](proto).
        return target.internalMethods().setPrototypeOf(agent, target, proto);
    };

    // 7. Let boolTrapResult be ToBoolean(? Call(trap, handler, « target, proto »)).
    const bool_trap_result = (try trap.call(
        agent,
        Value.from(handler),
        &.{ Value.from(target), if (proto != null) Value.from(proto.?) else .null },
    )).toBoolean();

    // 8. If boolTrapResult is false, return false.
    if (!bool_trap_result) return false;

    // 9. Let extensibleTarget be ? IsExtensible(target).
    const extensible_target = try target.isExtensible(agent);

    // 10. If extensibleTarget is true, return true.
    if (extensible_target) return true;

    // 11. Let targetProto be ? target.[[GetPrototypeOf]]().
    const target_proto = try target.internalMethods().getPrototypeOf(agent, target);

    // 12. If SameValue(proto, targetProto) is false, throw a TypeError exception.
    if (proto != target_proto) {
        return agent.throwException(
            .type_error,
            "Proxy 'setPrototypeOf' trap must return false or receive same prototype for non-extensible target",
            .{},
        );
    }

    // 13. Return true.
    return true;
}

/// 10.5.3 [[IsExtensible]] ( )
/// https://tc39.es/ecma262/#sec-proxy-object-internal-methods-and-internal-slots-isextensible
fn isExtensible(agent: *Agent, obj: *Object) Agent.Error!bool {
    const proxy = obj.as(Proxy);

    // 1. Perform ? ValidateNonRevokedProxy(obj).
    try validateNonRevokedProxy(agent, proxy);

    // 2. Let target be obj.[[ProxyTarget]].
    const target = proxy.fields.proxy_target.?;

    // 3. Let handler be obj.[[ProxyHandler]].
    // 4. Assert: handler is an Object.
    const handler = proxy.fields.proxy_handler.?;

    // 5. Let trap be ? GetMethod(handler, "isExtensible").
    const trap = try handler.getMethod(agent, PropertyKey.from("isExtensible")) orelse {
        // 6. If trap is undefined, then
        //     a. Return ? IsExtensible(target).
        return target.isExtensible(agent);
    };

    // 7. Let boolTrapResult be ToBoolean(? Call(trap, handler, « target »)).
    const bool_trap_result = (try trap.call(
        agent,
        Value.from(handler),
        &.{Value.from(target)},
    )).toBoolean();

    // 8. Let targetResult be ? IsExtensible(target).
    const target_result = try target.isExtensible(agent);

    // 9. If boolTrapResult is not targetResult, throw a TypeError exception.
    if (bool_trap_result != target_result) {
        return agent.throwException(
            .type_error,
            "Proxy 'isExtensible' trap must return same result as target",
            .{},
        );
    }

    // 10. Return boolTrapResult.
    return bool_trap_result;
}

/// 10.5.4 [[PreventExtensions]] ( )
/// https://tc39.es/ecma262/#sec-proxy-object-internal-methods-and-internal-slots-preventextensions
fn preventExtensions(agent: *Agent, obj: *Object) Agent.Error!bool {
    const proxy = obj.as(Proxy);

    // 1. Perform ? ValidateNonRevokedProxy(obj).
    try validateNonRevokedProxy(agent, proxy);

    // 2. Let target be obj.[[ProxyTarget]].
    const target = proxy.fields.proxy_target.?;

    // 3. Let handler be obj.[[ProxyHandler]].
    // 4. Assert: handler is an Object.
    const handler = proxy.fields.proxy_handler.?;

    // 5. Let trap be ? GetMethod(handler, "preventExtensions").
    const trap = try handler.getMethod(agent, PropertyKey.from("preventExtensions")) orelse {
        // 6. If trap is undefined, then
        //     a. Return ? target.[[PreventExtensions]]().
        return target.internalMethods().preventExtensions(agent, target);
    };

    // 7. Let boolTrapResult be ToBoolean(? Call(trap, handler, « target »)).
    const bool_trap_result = (try trap.call(
        agent,
        Value.from(handler),
        &.{Value.from(target)},
    )).toBoolean();

    // 8. If boolTrapResult is true, then
    if (bool_trap_result) {
        // a. Let extensibleTarget be ? IsExtensible(target).
        const extensible_target = try target.isExtensible(agent);

        // b. If extensibleTarget is true, throw a TypeError exception.
        if (extensible_target) {
            return agent.throwException(
                .type_error,
                "Proxy 'preventExtensions' trap must not return true for extensible target",
                .{},
            );
        }
    }

    // 9. Return boolTrapResult.
    return bool_trap_result;
}

/// 10.5.5 [[GetOwnProperty]] ( propertyKey )
/// https://tc39.es/ecma262/#sec-proxy-object-internal-methods-and-internal-slots-getownproperty-p
fn getOwnProperty(
    agent: *Agent,
    obj: *Object,
    property_key: PropertyKey,
) Agent.Error!?PropertyDescriptor {
    const proxy = obj.as(Proxy);

    // 1. Perform ? ValidateNonRevokedProxy(obj).
    try validateNonRevokedProxy(agent, proxy);

    // 2. Let target be obj.[[ProxyTarget]].
    const target = proxy.fields.proxy_target.?;

    // 3. Let handler be obj.[[ProxyHandler]].
    // 4. Assert: handler is an Object.
    const handler = proxy.fields.proxy_handler.?;

    // 5. Let trap be ? GetMethod(handler, "getOwnPropertyDescriptor").
    const trap = try handler.getMethod(
        agent,
        PropertyKey.from("getOwnPropertyDescriptor"),
    ) orelse {
        // 6. If trap is undefined, then
        //     a. Return ? target.[[GetOwnProperty]](propertyKey).
        return target.internalMethods().getOwnProperty(agent, target, property_key);
    };

    // 7. Let trapResultObj be ? Call(trap, handler, « target, propertyKey »).
    const trap_result_obj = try trap.call(
        agent,
        Value.from(handler),
        &.{ Value.from(target), try property_key.toValue(agent) },
    );

    // 8. If trapResultObj is not an Object and trapResultObj is not undefined, throw a TypeError
    //    exception.
    if (!trap_result_obj.isObject() and !trap_result_obj.isUndefined()) {
        return agent.throwException(
            .type_error,
            "Proxy 'getOwnPropertyDescriptor' trap must return an object or undefined",
            .{},
        );
    }

    // 9. Let targetDesc be ? target.[[GetOwnProperty]](propertyKey).
    const target_desc = try target.internalMethods().getOwnProperty(
        agent,
        target,
        property_key,
    );

    // 10. If trapResultObj is undefined, then
    if (trap_result_obj.isUndefined()) {
        // a. If targetDesc is undefined, return undefined.
        if (target_desc == null) return null;

        // b. If targetDesc.[[Configurable]] is false, throw a TypeError exception.
        if (target_desc.?.configurable == false) {
            return agent.throwException(
                .type_error,
                "Proxy 'getOwnPropertyDescriptor' trap must not return undefined for non-configurable property on target",
                .{},
            );
        }

        // c. Let extensibleTarget be ? IsExtensible(target).
        const extensible_target = try target.isExtensible(agent);

        // d. If extensibleTarget is false, throw a TypeError exception.
        if (!extensible_target) {
            return agent.throwException(
                .type_error,
                "Proxy 'getOwnPropertyDescriptor' trap must not return undefined for property on non-extensible target",
                .{},
            );
        }

        // e. Return undefined.
        return null;
    }

    // 11. Let extensibleTarget be ? IsExtensible(target).
    const extensible_target = try target.isExtensible(agent);

    // 12. Let resultDesc be ? ToPropertyDescriptor(trapResultObj).
    var result_descriptor = try trap_result_obj.toPropertyDescriptor(agent);

    // 13. Perform CompletePropertyDescriptor(resultDesc).
    result_descriptor.completePropertyDescriptor();

    // 14. Let valid be IsCompatiblePropertyDescriptor(extensibleTarget, resultDesc, targetDesc).
    const valid = isCompatiblePropertyDescriptor(
        extensible_target,
        result_descriptor,
        target_desc,
    );

    // 15. If valid is false, throw a TypeError exception.
    if (!valid) {
        return agent.throwException(
            .type_error,
            "Proxy 'getOwnPropertyDescriptor' trap must return a property descriptor compatible with the target object",
            .{},
        );
    }

    // 16. If resultDesc.[[Configurable]] is false, then
    if (result_descriptor.configurable == false) {
        // a. If targetDesc is undefined or targetDesc.[[Configurable]] is true, then
        if (target_desc == null or target_desc.?.configurable == true) {
            // i. Throw a TypeError exception.
            return agent.throwException(
                .type_error,
                "Proxy 'getOwnPropertyDescriptor' trap must not return 'configurable: false' for missing or configurable property on target",
                .{},
            );
        }

        // b. If resultDesc has a [[Writable]] field and resultDesc.[[Writable]] is false, then
        if (result_descriptor.writable == false) {
            // i. Assert: targetDesc has a [[Writable]] field.
            std.debug.assert(target_desc.?.writable != null);

            // ii. If targetDesc.[[Writable]] is true, throw a TypeError exception.
            if (target_desc.?.writable == true) {
                return agent.throwException(
                    .type_error,
                    "Proxy 'getOwnPropertyDescriptor' trap must not return 'writable: false' for non-configurable but writable property on target",
                    .{},
                );
            }
        }
    }

    // 17. Return resultDesc.
    return result_descriptor;
}

/// 10.5.6 [[DefineOwnProperty]] ( propertyKey, propertyDesc )
/// https://tc39.es/ecma262/#sec-proxy-object-internal-methods-and-internal-slots-defineownproperty-p-desc
fn defineOwnProperty(
    agent: *Agent,
    obj: *Object,
    property_key: PropertyKey,
    property_desc: PropertyDescriptor,
) Agent.Error!bool {
    const proxy = obj.as(Proxy);

    // 1. Perform ? ValidateNonRevokedProxy(obj).
    try validateNonRevokedProxy(agent, proxy);

    // 2. Let target be obj.[[ProxyTarget]].
    const target = proxy.fields.proxy_target.?;

    // 3. Let handler be obj.[[ProxyHandler]].
    // 4. Assert: handler is an Object.
    const handler = proxy.fields.proxy_handler.?;

    // 5. Let trap be ? GetMethod(handler, "defineProperty").
    const trap = try handler.getMethod(agent, PropertyKey.from("defineProperty")) orelse {
        // 6. If trap is undefined, then
        //     a. Return ? target.[[DefineOwnProperty]](propertyKey, propertyDesc).
        return target.internalMethods().defineOwnProperty(
            agent,
            target,
            property_key,
            property_desc,
        );
    };

    // 7. Let propertyDescObj be FromPropertyDescriptor(propertyDesc).
    const property_desc_obj = try property_desc.fromPropertyDescriptor(agent);

    // 8. Let boolTrapResult be ToBoolean(? Call(trap, handler, « target, propertyKey,
    //    propertyDescObj »)).
    const bool_trap_result = (try trap.call(
        agent,
        Value.from(handler),
        &.{
            Value.from(target),
            try property_key.toValue(agent),
            Value.from(property_desc_obj),
        },
    )).toBoolean();

    // 9. If boolTrapResult is false, return false.
    if (!bool_trap_result) return false;

    // 10. Let targetDesc be ? target.[[GetOwnProperty]](propertyKey).
    const target_desc = try target.internalMethods().getOwnProperty(
        agent,
        target,
        property_key,
    );

    // 11. Let extensibleTarget be ? IsExtensible(target).
    const extensible_target = try target.isExtensible(agent);

    // 12. If propertyDesc has a [[Configurable]] field and propertyDesc.[[Configurable]] is false,
    //     then
    //     a. Let settingConfigurableFalse be true.
    // 13. Else,
    //     a. Let settingConfigurableFalse be false.
    const setting_configurable_false = property_desc.configurable == false;

    // 14. If targetDesc is undefined, then
    if (target_desc == null) {
        // a. If extensibleTarget is false, throw a TypeError exception.
        if (!extensible_target) {
            return agent.throwException(
                .type_error,
                "Proxy 'defineProperty' trap must not return true for missing property on non-extensible target",
                .{},
            );
        }

        // b. If settingConfigurableFalse is true, throw a TypeError exception.
        if (setting_configurable_false) {
            return agent.throwException(
                .type_error,
                "Proxy 'defineProperty' trap must not return 'configurable: false' for missing property on target",
                .{},
            );
        }
    } else {
        // 15. Else,
        // a. If IsCompatiblePropertyDescriptor(extensibleTarget, propertyDesc, targetDesc) is
        //    false, throw a TypeError exception.
        if (!isCompatiblePropertyDescriptor(extensible_target, property_desc, target_desc)) {
            return agent.throwException(
                .type_error,
                "Proxy 'defineProperty' trap must return a property descriptor compatible with the target object",
                .{},
            );
        }

        // b. If settingConfigurableFalse is true and targetDesc.[[Configurable]] is true, throw a
        //    TypeError exception.
        if (setting_configurable_false and target_desc.?.configurable == true) {
            return agent.throwException(
                .type_error,
                "Proxy 'defineProperty' trap must not return 'configurable: false' for configurable property on target",
                .{},
            );
        }

        // c. If IsDataDescriptor(targetDesc) is true, targetDesc.[[Configurable]] is false, and
        //    targetDesc.[[Writable]] is true, then
        if (target_desc.?.isDataDescriptor() and
            target_desc.?.configurable == false and
            target_desc.?.writable == true and
            // i. If propertyDesc has a [[Writable]] field and propertyDesc.[[Writable]] is false,
            //    throw a TypeError exception.
            property_desc.writable == false)
        {
            return agent.throwException(
                .type_error,
                "Proxy 'defineProperty' trap must not return 'writable: false' for non-configurable but writable property on target",
                .{},
            );
        }
    }

    // 16. Return true.
    return true;
}

/// 10.5.7 [[HasProperty]] ( propertyKey )
/// https://tc39.es/ecma262/#sec-proxy-object-internal-methods-and-internal-slots-hasproperty-p
fn hasProperty(agent: *Agent, obj: *Object, property_key: PropertyKey) Agent.Error!bool {
    const proxy = obj.as(Proxy);

    // 1. Perform ? ValidateNonRevokedProxy(obj).
    try validateNonRevokedProxy(agent, proxy);

    // 2. Let target be obj.[[ProxyTarget]].
    const target = proxy.fields.proxy_target.?;

    // 3. Let handler be obj.[[ProxyHandler]].
    // 4. Assert: handler is an Object.
    const handler = proxy.fields.proxy_handler.?;

    // 5. Let trap be ? GetMethod(handler, "has").
    const trap = try handler.getMethod(agent, PropertyKey.from("has")) orelse {
        // 6. If trap is undefined, then
        //     a. Return ? target.[[HasProperty]](propertyKey).
        return target.internalMethods().hasProperty(agent, target, property_key);
    };

    // 7. Let boolTrapResult be ToBoolean(? Call(trap, handler, « target, propertyKey »)).
    const bool_trap_result = (try trap.call(
        agent,
        Value.from(handler),
        &.{ Value.from(target), try property_key.toValue(agent) },
    )).toBoolean();

    // 8. If boolTrapResult is false, then
    if (!bool_trap_result) {
        // a. Let targetDesc be ? target.[[GetOwnProperty]](propertyKey).
        const target_desc = try target.internalMethods().getOwnProperty(
            agent,
            target,
            property_key,
        );

        // b. If targetDesc is not undefined, then
        if (target_desc != null) {
            // i. If targetDesc.[[Configurable]] is false, throw a TypeError exception.
            if (target_desc.?.configurable == false) {
                return agent.throwException(
                    .type_error,
                    "Proxy 'has' trap must not return false for non-configurable property on target",
                    .{},
                );
            }

            // ii. Let extensibleTarget be ? IsExtensible(target).
            const extensible_target = try target.isExtensible(agent);

            // iii. If extensibleTarget is false, throw a TypeError exception.
            if (!extensible_target) {
                return agent.throwException(
                    .type_error,
                    "Proxy 'has' trap must not return false for property on non-extensible target",
                    .{},
                );
            }
        }
    }

    // 9. Return boolTrapResult.
    return bool_trap_result;
}

/// 10.5.8 [[Get]] ( propertyKey, receiver )
/// https://tc39.es/ecma262/#sec-proxy-object-internal-methods-and-internal-slots-get-p-receiver
fn get(
    agent: *Agent,
    obj: *Object,
    property_key: PropertyKey,
    receiver: Value,
) Agent.Error!Value {
    const proxy = obj.as(Proxy);

    // 1. Perform ? ValidateNonRevokedProxy(obj).
    try validateNonRevokedProxy(agent, proxy);

    // 2. Let target be obj.[[ProxyTarget]].
    const target = proxy.fields.proxy_target.?;

    // 3. Let handler be obj.[[ProxyHandler]].
    // 4. Assert: handler is an Object.
    const handler = proxy.fields.proxy_handler.?;

    // 5. Let trap be ? GetMethod(handler, "get").
    const trap = try handler.getMethod(agent, PropertyKey.from("get")) orelse {
        // 6. If trap is undefined, then
        //     a. Return ? target.[[Get]](propertyKey, receiver).
        return target.internalMethods().get(agent, target, property_key, receiver);
    };

    // 7. Let trapResult be ? Call(trap, handler, « target, propertyKey, receiver »).
    const trap_result = try trap.call(
        agent,
        Value.from(handler),
        &.{ Value.from(target), try property_key.toValue(agent), receiver },
    );

    // 8. Let targetDesc be ? target.[[GetOwnProperty]](propertyKey).
    const target_desc = try target.internalMethods().getOwnProperty(
        agent,
        target,
        property_key,
    );

    // 9. If targetDesc is not undefined and targetDesc.[[Configurable]] is false, then
    if (target_desc != null and target_desc.?.configurable == false) {
        // a. If IsDataDescriptor(targetDesc) is true and targetDesc.[[Writable]] is false, then
        if (target_desc.?.isDataDescriptor() and target_desc.?.writable == false) {
            // i. If SameValue(trapResult, targetDesc.[[Value]]) is false, throw a TypeError
            //    exception.
            if (!sameValue(trap_result, target_desc.?.value.?)) {
                return agent.throwException(
                    .type_error,
                    "Proxy 'get' trap must not return different value for non-configurable, non-writable property on target",
                    .{},
                );
            }
        }

        // b. If IsAccessorDescriptor(targetDesc) is true and targetDesc.[[Getter]] is undefined,
        //    then
        if (target_desc.?.isAccessorDescriptor() and target_desc.?.getter.? == null) {
            // i. If trapResult is not undefined, throw a TypeError exception.
            if (!trap_result.isUndefined()) {
                return agent.throwException(
                    .type_error,
                    "Proxy 'get' trap must return undefined for non-configurable accessor property with no getter on target",
                    .{},
                );
            }
        }
    }

    // 10. Return trapResult.
    return trap_result;
}

/// 10.5.9 [[Set]] ( propertyKey, value, receiver )
/// https://tc39.es/ecma262/#sec-proxy-object-internal-methods-and-internal-slots-set-p-v-receiver
fn set(
    agent: *Agent,
    obj: *Object,
    property_key: PropertyKey,
    value: Value,
    receiver: Value,
) Agent.Error!bool {
    const proxy = obj.as(Proxy);

    // 1. Perform ? ValidateNonRevokedProxy(obj).
    try validateNonRevokedProxy(agent, proxy);

    // 2. Let target be obj.[[ProxyTarget]].
    const target = proxy.fields.proxy_target.?;

    // 3. Let handler be obj.[[ProxyHandler]].
    // 4. Assert: handler is an Object.
    const handler = proxy.fields.proxy_handler.?;

    // 5. Let trap be ? GetMethod(handler, "set").
    const trap = try handler.getMethod(agent, PropertyKey.from("set")) orelse {
        // 6. If trap is undefined, then
        //     a. Return ? target.[[Set]](propertyKey, value, receiver).
        return target.internalMethods().set(agent, target, property_key, value, receiver);
    };

    // 7. Let boolTrapResult be ToBoolean(? Call(trap, handler, « target, propertyKey, value,
    //    receiver »)).
    const bool_trap_result = (try trap.call(
        agent,
        Value.from(handler),
        &.{ Value.from(target), try property_key.toValue(agent), value, receiver },
    )).toBoolean();

    // 8. If boolTrapResult is false, return false.
    if (!bool_trap_result) return false;

    // 9. Let targetDesc be ? target.[[GetOwnProperty]](propertyKey).
    const target_desc = try target.internalMethods().getOwnProperty(
        agent,
        target,
        property_key,
    );

    // 10. If targetDesc is not undefined and targetDesc.[[Configurable]] is false, then
    if (target_desc != null and target_desc.?.configurable == false) {
        // a. If IsDataDescriptor(targetDesc) is true and targetDesc.[[Writable]] is false, then
        if (target_desc.?.isDataDescriptor() and target_desc.?.writable == false) {
            // i. If SameValue(value, targetDesc.[[Value]]) is false, throw a TypeError exception.
            if (!sameValue(value, target_desc.?.value.?)) {
                return agent.throwException(
                    .type_error,
                    "Proxy 'set' trap must not return true when attempting to change the value of a non-configurable, non-writable property on target",
                    .{},
                );
            }
        }

        // b. If IsAccessorDescriptor(targetDesc) is true, then
        if (target_desc.?.isAccessorDescriptor()) {
            // i. If targetDesc.[[Setter]] is undefined, throw a TypeError exception.
            if (target_desc.?.setter.? == null) {
                return agent.throwException(
                    .type_error,
                    "Proxy 'set' trap must not return true when attempting to set the value of a non-configurable accessor property with no setter on target",
                    .{},
                );
            }
        }
    }

    // 11. Return true.
    return true;
}

/// 10.5.10 [[Delete]] ( propertyKey )
/// https://tc39.es/ecma262/#sec-proxy-object-internal-methods-and-internal-slots-delete-p
fn delete(agent: *Agent, obj: *Object, property_key: PropertyKey) Agent.Error!bool {
    const proxy = obj.as(Proxy);

    // 1. Perform ? ValidateNonRevokedProxy(obj).
    try validateNonRevokedProxy(agent, proxy);

    // 2. Let target be obj.[[ProxyTarget]].
    const target = proxy.fields.proxy_target.?;

    // 3. Let handler be obj.[[ProxyHandler]].
    // 4. Assert: handler is an Object.
    const handler = proxy.fields.proxy_handler.?;

    // 5. Let trap be ? GetMethod(handler, "deleteProperty").
    const trap = try handler.getMethod(agent, PropertyKey.from("deleteProperty")) orelse {
        // 6. If trap is undefined, then
        //     a. Return ? target.[[Delete]](propertyKey).
        return target.internalMethods().delete(agent, target, property_key);
    };

    // 7. Let boolTrapResult be ToBoolean(? Call(trap, handler, « target, propertyKey »)).
    const bool_trap_result = (try trap.call(
        agent,
        Value.from(handler),
        &.{ Value.from(target), try property_key.toValue(agent) },
    )).toBoolean();

    // 8. If boolTrapResult is false, return false.
    if (!bool_trap_result) return false;

    // 9. Let targetDesc be ? target.[[GetOwnProperty]](propertyKey).
    const target_desc = try target.internalMethods().getOwnProperty(
        agent,
        target,
        property_key,
    ) orelse {
        // 10. If targetDesc is undefined, return true.
        return true;
    };

    // 11. If targetDesc.[[Configurable]] is false, throw a TypeError exception.
    if (target_desc.configurable == false) {
        return agent.throwException(
            .type_error,
            "Proxy 'deleteProperty' trap must not return true for non-configurable property on target",
            .{},
        );
    }

    // 12. Let extensibleTarget be ? IsExtensible(target).
    const extensible_target = try target.isExtensible(agent);

    // 13. If extensibleTarget is false, throw a TypeError exception.
    if (!extensible_target) {
        return agent.throwException(
            .type_error,
            "Proxy 'deleteProperty' trap must not return true for property on non-extensible target",
            .{},
        );
    }

    // 14. Return true.
    return true;
}

/// 10.5.11 [[OwnPropertyKeys]] ( )
/// https://tc39.es/ecma262/#sec-proxy-object-internal-methods-and-internal-slots-ownpropertykeys
fn ownPropertyKeys(agent: *Agent, obj: *Object) Agent.Error![]PropertyKey {
    const proxy = obj.as(Proxy);

    // 1. Perform ? ValidateNonRevokedProxy(obj).
    try validateNonRevokedProxy(agent, proxy);

    // 2. Let target be obj.[[ProxyTarget]].
    const target = proxy.fields.proxy_target.?;

    // 3. Let handler be obj.[[ProxyHandler]].
    // 4. Assert: handler is an Object.
    const handler = proxy.fields.proxy_handler.?;

    // 5. Let trap be ? GetMethod(handler, "ownKeys").
    const trap = try handler.getMethod(agent, PropertyKey.from("ownKeys")) orelse {
        // 6. If trap is undefined, then
        //     a. Return ? target.[[OwnPropertyKeys]]().
        return target.internalMethods().ownPropertyKeys(agent, target);
    };

    // 7. Let trapResultArray be ? Call(trap, handler, « target »).
    const trap_result_array = try trap.call(agent, Value.from(handler), &.{Value.from(target)});

    // 8. Let trapResult be ? CreateListFromArrayLike(trapResultArray, property-key).
    const elements = try trap_result_array.createListFromArrayLike(agent, .property_key);
    var trap_result: PropertyKey.ArrayHashMap(void) = .empty;
    defer trap_result.deinit(agent.gc_allocator);
    try trap_result.ensureTotalCapacity(agent.gc_allocator, elements.len);

    for (elements) |element| {
        const property_key = switch (element.type()) {
            .string => PropertyKey.from(element.asString()),
            .symbol => PropertyKey.from(element.asSymbol()),
            else => unreachable,
        };
        const gop = try trap_result.getOrPut(agent.gc_allocator, property_key);

        // 9. If trapResult contains any duplicate entries, throw a TypeError exception.
        if (gop.found_existing) {
            return agent.throwException(
                .type_error,
                "Proxy 'ownKeys' trap must not return duplicate property keys",
                .{},
            );
        }
    }

    // 10. Let extensibleTarget be ? IsExtensible(target).
    const extensible_target = try target.isExtensible(agent);

    // 11. Let targetKeys be ? target.[[OwnPropertyKeys]]().
    // 12. Assert: targetKeys is a List of property keys.
    // 13. Assert: targetKeys contains no duplicate entries.
    const target_keys = try target.internalMethods().ownPropertyKeys(agent, target);
    defer agent.gc_allocator.free(target_keys);

    // 14. Let targetConfigurableKeys be a new empty List.
    var target_configurable_keys: std.ArrayList(PropertyKey) = .empty;
    defer target_configurable_keys.deinit(agent.gc_allocator);

    // 15. Let targetNonconfigurableKeys be a new empty List.
    var target_nonconfigurable_keys: std.ArrayList(PropertyKey) = .empty;
    defer target_nonconfigurable_keys.deinit(agent.gc_allocator);

    // 16. For each element key of targetKeys, do
    for (target_keys) |key| {
        // a. Let propertyDesc be ? target.[[GetOwnProperty]](key).
        const property_desc = try target.internalMethods().getOwnProperty(agent, target, key);

        // b. If propertyDesc is not undefined and propertyDesc.[[Configurable]] is false, then
        if (property_desc != null and property_desc.?.configurable == false) {
            // i. Append key to targetNonconfigurableKeys.
            try target_nonconfigurable_keys.append(agent.gc_allocator, key);
        } else {
            // c. Else,
            // i. Append key to targetConfigurableKeys.
            try target_configurable_keys.append(agent.gc_allocator, key);
        }
    }

    // 17. If extensibleTarget is true and targetNonconfigurableKeys is empty, then
    if (extensible_target and target_nonconfigurable_keys.items.len == 0) {
        // a. Return trapResult.
        return agent.gc_allocator.dupe(PropertyKey, trap_result.keys());
    }

    // 18. Let uncheckedResultKeys be a List whose elements are the elements of trapResult.
    var unchecked_result_keys: PropertyKey.HashMap(void) = .empty;
    defer unchecked_result_keys.deinit(agent.gc_allocator);
    try unchecked_result_keys.ensureTotalCapacity(agent.gc_allocator, @intCast(trap_result.count()));
    for (trap_result.keys()) |key| {
        unchecked_result_keys.putAssumeCapacity(key, {});
    }

    // 19. For each element key of targetNonconfigurableKeys, do
    for (target_nonconfigurable_keys.items) |key| {
        // a. If uncheckedResultKeys does not contain key, throw a TypeError exception.
        // b. Remove key from uncheckedResultKeys.
        if (!unchecked_result_keys.remove(key)) {
            return agent.throwException(
                .type_error,
                "Proxy 'ownKeys' trap must not omit any non-configurable properties",
                .{},
            );
        }
    }

    // 20. If extensibleTarget is true, return trapResult.
    if (extensible_target) return agent.gc_allocator.dupe(PropertyKey, trap_result.keys());

    // 21. For each element key of targetConfigurableKeys, do
    for (target_configurable_keys.items) |key| {
        // a. If uncheckedResultKeys does not contain key, throw a TypeError exception.
        // b. Remove key from uncheckedResultKeys.
        if (!unchecked_result_keys.remove(key)) {
            return agent.throwException(
                .type_error,
                "Proxy 'ownKeys' trap must not omit any properties of non-extensible target",
                .{},
            );
        }
    }

    // 22. If uncheckedResultKeys is not empty, throw a TypeError exception.
    if (unchecked_result_keys.count() != 0) {
        return agent.throwException(
            .type_error,
            "Proxy 'ownKeys' trap must not include new properties of non-extensible target",
            .{},
        );
    }

    // 23. Return trapResult.
    return agent.gc_allocator.dupe(PropertyKey, trap_result.keys());
}

/// 10.5.12 [[Call]] ( thisArg, argList )
/// https://tc39.es/ecma262/#sec-proxy-object-internal-methods-and-internal-slots-call-thisargument-argumentslist
fn call(
    agent: *Agent,
    obj: *Object,
    this_arg: Value,
    arg_list: Arguments,
) Agent.Error!Value {
    const proxy = obj.as(Proxy);

    // 1. Perform ? ValidateNonRevokedProxy(obj).
    try validateNonRevokedProxy(agent, proxy);

    // 2. Let target be obj.[[ProxyTarget]].
    const target = proxy.fields.proxy_target.?;

    // 3. Let handler be obj.[[ProxyHandler]].
    // 4. Assert: handler is an Object.
    const handler = proxy.fields.proxy_handler.?;

    // 5. Let trap be ? GetMethod(handler, "apply").
    const trap = try handler.getMethod(agent, PropertyKey.from("apply")) orelse {
        // 6. If trap is undefined, then
        //     a. Return ? Call(target, thisArg, argList).
        return target.call(agent, this_arg, arg_list.values);
    };

    // 7. Let argArray be CreateArrayFromList(argList).
    const arg_array = try createArrayFromList(agent, arg_list.values);

    // 8. Return ? Call(trap, handler, « target, thisArg, argArray »).
    return trap.call(
        agent,
        Value.from(handler),
        &.{ Value.from(target), this_arg, Value.from(&arg_array.object) },
    );
}

/// 10.5.13 [[Construct]] ( argList, newTarget )
/// https://tc39.es/ecma262/#sec-proxy-object-internal-methods-and-internal-slots-construct-argumentslist-newtarget
fn construct(
    agent: *Agent,
    obj: *Object,
    arg_list: Arguments,
    new_target: *Object,
) Agent.Error!*Object {
    const proxy = obj.as(Proxy);

    // 1. Perform ? ValidateNonRevokedProxy(obj).
    try validateNonRevokedProxy(agent, proxy);

    // 2. Let target be obj.[[ProxyTarget]].
    const target = proxy.fields.proxy_target.?;

    // 3. Assert: IsConstructor(target) is true.
    std.debug.assert(Value.from(target).isConstructor());

    // 4. Let handler be obj.[[ProxyHandler]].
    // 5. Assert: handler is an Object.
    const handler = proxy.fields.proxy_handler.?;

    // 6. Let trap be ? GetMethod(handler, "construct").
    const trap = try handler.getMethod(agent, PropertyKey.from("construct")) orelse {
        // 7. If trap is undefined, then
        //     a. Return ? Construct(target, argList, newTarget).
        return target.construct(agent, arg_list.values, new_target);
    };

    // 8. Let argArray be CreateArrayFromList(argList).
    const arg_array = try createArrayFromList(agent, arg_list.values);

    // 9. Let newObj be ? Call(trap, handler, « target, argArray, newTarget »).
    const new_obj = try trap.call(
        agent,
        Value.from(handler),
        &.{ Value.from(target), Value.from(&arg_array.object), Value.from(new_target) },
    );

    // 10. If newObj is not an Object, throw a TypeError exception.
    if (!new_obj.isObject()) {
        return agent.throwException(
            .type_error,
            "Proxy 'construct' trap must return an object",
            .{},
        );
    }

    // 11. Return newObj.
    return new_obj.asObject();
}

/// 10.5.14 ValidateNonRevokedProxy ( proxy )
/// https://tc39.es/ecma262/#sec-validatenonrevokedproxy
pub fn validateNonRevokedProxy(agent: *Agent, proxy: *Proxy) error{ExceptionThrown}!void {
    // 1. If proxy.[[ProxyTarget]] is null, throw a TypeError exception.
    if (proxy.fields.proxy_target == null) {
        return agent.throwException(.type_error, "Proxy has been revoked", .{});
    }

    // 2. Assert: proxy.[[ProxyHandler]] is not null.
    std.debug.assert(proxy.fields.proxy_handler != null);

    // 3. Return unused.
}

/// 10.5.15 ProxyCreate ( target, handler )
/// https://tc39.es/ecma262/#sec-proxycreate
fn proxyCreate(agent: *Agent, target: Value, handler: Value) Agent.Error!*Proxy {
    // 1. If target is not an Object, throw a TypeError exception.
    if (!target.isObject()) {
        return agent.throwException(.type_error, "{f} is not an Object", .{target});
    }

    // 2. If handler is not an Object, throw a TypeError exception.
    if (!handler.isObject()) {
        return agent.throwException(.type_error, "{f} is not an Object", .{handler});
    }

    // 3. Let proxy be MakeBasicObject(« [[ProxyHandler]], [[ProxyTarget]] »).
    const proxy = try Proxy.create(agent, .{
        .internal_methods = blk: {
            // 4. Set proxy's essential internal methods, except for [[Call]] and [[Construct]], to
            //    the definitions specified in 10.5.
            var internal_methods = proxyInternalMethods(false, false);

            // 5. If IsCallable(target) is true, then
            if (target.isCallable()) {
                // a. Set proxy.[[Call]] as specified in 10.5.12.
                internal_methods = proxyInternalMethods(true, false);

                // b. If IsConstructor(target) is true, then
                if (target.isConstructor()) {
                    // i. Set proxy.[[Construct]] as specified in 10.5.13.
                    internal_methods = proxyInternalMethods(true, true);
                }
            }
            break :blk internal_methods;
        },
        .prototype = undefined,
        .fields = .{
            // 6. Set proxy.[[ProxyTarget]] to target.
            .proxy_target = target.asObject(),

            // 7. Set proxy.[[ProxyHandler]] to handler.
            .proxy_handler = handler.asObject(),
        },
    });

    // 8. Return proxy.
    return proxy;
}

inline fn proxyInternalMethods(
    comptime target_is_callable: bool,
    comptime target_is_constructor: bool,
) *const Object.InternalMethods {
    return .initComptime(.{
        .getPrototypeOf = getPrototypeOf,
        .setPrototypeOf = setPrototypeOf,
        .isExtensible = isExtensible,
        .preventExtensions = preventExtensions,
        .getOwnProperty = getOwnProperty,
        .defineOwnProperty = defineOwnProperty,
        .hasProperty = hasProperty,
        .get = get,
        .set = set,
        .delete = delete,
        .ownPropertyKeys = ownPropertyKeys,
        .call = if (target_is_callable) call else null,
        .construct = if (target_is_constructor) construct else null,
    });
}

/// 28.2.2 Properties of the Proxy Constructor
/// https://tc39.es/ecma262/#sec-properties-of-the-proxy-constructor
pub const constructor = struct {
    pub fn create(agent: *Agent, realm: *Realm) std.mem.Allocator.Error!*Object {
        const builtin_function = try createBuiltinFunction(
            agent,
            .{ .constructor = impl },
            2,
            "Proxy",
            .{ .realm = realm, .proto = try realm.intrinsic(.function_prototype) },
        );
        return &builtin_function.object;
    }

    pub fn init(agent: *Agent, realm: *Realm, object: *Object) std.mem.Allocator.Error!void {
        try object.defineBuiltinFunction(agent, "revocable", revocable, 2, realm);
    }

    /// 28.2.1.1 Proxy ( target, handler )
    /// https://tc39.es/ecma262/#sec-proxy-target-handler
    fn impl(agent: *Agent, arguments: Arguments, new_target: ?*Object) Agent.Error!Value {
        const target = arguments.get(0);
        const handler = arguments.get(1);

        // 1. If NewTarget is undefined, throw a TypeError exception.
        if (new_target == null) {
            return agent.throwException(.type_error, "Proxy must be constructed with 'new'", .{});
        }

        // 2. Return ? ProxyCreate(target, handler).
        const proxy = try proxyCreate(agent, target, handler);
        return Value.from(&proxy.object);
    }

    /// 28.2.2.1 Proxy.revocable ( target, handler )
    /// https://tc39.es/ecma262/#sec-proxy.revocable
    fn revocable(agent: *Agent, _: Value, arguments: Arguments) Agent.Error!Value {
        const realm = agent.currentRealm();
        const target = arguments.get(0);
        const handler = arguments.get(1);

        const AdditionalFields = struct {
            revocable_proxy: ?*Object,
        };

        // 1. Let proxy be ? ProxyCreate(target, handler).
        const proxy = try proxyCreate(agent, target, handler);

        // 2. Let revokerClosure be a new Abstract Closure with no parameters that captures nothing
        //    and performs the following steps when called:
        const revoker_closure = struct {
            fn func(agent_: *Agent, _: Value, _: Arguments) Agent.Error!Value {
                // a. Let activeFunc be the active function object.
                const active_func = agent_.activeFunctionObject();

                // b. Let revocableProxy be activeFunc.[[RevocableProxy]].
                const additional_fields = active_func.as(builtins.BuiltinFunction).fields.additionalFieldsAs(AdditionalFields);
                const revocable_proxy = additional_fields.revocable_proxy orelse {
                    // c. If revocableProxy is null, return NormalCompletion(undefined).
                    return .undefined;
                };

                // d. Set activeFunc.[[RevocableProxy]] to null.
                additional_fields.revocable_proxy = null;

                // e. Assert: revocableProxy is a Proxy exotic object.
                // f. Set revocableProxy.[[ProxyTarget]] to null.
                revocable_proxy.as(Proxy).fields.proxy_target = null;

                // g. Set revocableProxy.[[ProxyHandler]] to null.
                revocable_proxy.as(Proxy).fields.proxy_handler = null;

                // h. Return NormalCompletion(undefined).
                return .undefined;
            }
        }.func;

        // 3. Let revoker be CreateBuiltinFunction(revokerClosure, 0, "", « [[RevocableProxy]] »).
        const additional_fields = try agent.gc_allocator.create(AdditionalFields);
        const revoker = try createBuiltinFunction(
            agent,
            .{ .function = revoker_closure },
            0,
            "",
            .{ .additional_fields = additional_fields },
        );

        // 4. Set revoker.[[RevocableProxy]] to proxy.
        additional_fields.* = .{ .revocable_proxy = &proxy.object };

        // 5. Let result be OrdinaryObjectCreate(%Object.prototype%).
        const result = try ordinaryObjectCreate(
            agent,
            try realm.intrinsic(.object_prototype),
        );

        // 6. Perform ! CreateDataPropertyOrThrow(result, "proxy", proxy).
        try result.createDataPropertyDirect(
            agent,
            PropertyKey.from("proxy"),
            Value.from(&proxy.object),
        );

        // 7. Perform ! CreateDataPropertyOrThrow(result, "revoke", revoker).
        try result.createDataPropertyDirect(
            agent,
            PropertyKey.from("revoke"),
            Value.from(&revoker.object),
        );

        // 8. Return result.
        return Value.from(result);
    }
};

/// 10.5 Proxy Object Internal Methods and Internal Slots
/// https://tc39.es/ecma262/#sec-proxy-object-internal-methods-and-internal-slots
pub const Proxy = MakeObject(.{
    .Fields = struct {
        /// [[ProxyTarget]]
        proxy_target: ?*Object,

        /// [[ProxyHandler]]
        proxy_handler: ?*Object,
    },
    .tag = .proxy,
    .display_name = "Proxy",
});
