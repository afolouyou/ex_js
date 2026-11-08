//! 28.1 The Reflect Object
//! https://tc39.es/ecma262/#sec-reflect-object

const std = @import("std");

const builtins = @import("../builtins.zig");
const execution = @import("../execution.zig");
const types = @import("../types.zig");

const Agent = execution.Agent;
const Arguments = types.Arguments;
const Object = types.Object;
const PropertyKey = types.PropertyKey;
const Realm = execution.Realm;
const Value = types.Value;
const createArrayFromListMapToValue = types.createArrayFromListMapToValue;
const ordinaryObjectCreate = builtins.ordinaryObjectCreate;

pub const namespace = struct {
    pub fn create(agent: *Agent, realm: *Realm) std.mem.Allocator.Error!*Object {
        return ordinaryObjectCreate(agent, try realm.intrinsic(.object_prototype));
    }

    pub fn init(agent: *Agent, realm: *Realm, object: *Object) std.mem.Allocator.Error!void {
        try object.defineBuiltinFunction(agent, "apply", apply, 3, realm);
        try object.defineBuiltinFunction(agent, "construct", construct, 2, realm);
        try object.defineBuiltinFunction(agent, "defineProperty", defineProperty, 3, realm);
        try object.defineBuiltinFunction(agent, "deleteProperty", deleteProperty, 2, realm);
        try object.defineBuiltinFunction(agent, "get", get, 2, realm);
        try object.defineBuiltinFunction(agent, "getOwnPropertyDescriptor", getOwnPropertyDescriptor, 2, realm);
        try object.defineBuiltinFunction(agent, "getPrototypeOf", getPrototypeOf, 1, realm);
        try object.defineBuiltinFunction(agent, "has", has, 2, realm);
        try object.defineBuiltinFunction(agent, "isExtensible", isExtensible, 1, realm);
        try object.defineBuiltinFunction(agent, "ownKeys", ownKeys, 1, realm);
        try object.defineBuiltinFunction(agent, "preventExtensions", preventExtensions, 1, realm);
        try object.defineBuiltinFunction(agent, "set", set, 3, realm);
        try object.defineBuiltinFunction(agent, "setPrototypeOf", setPrototypeOf, 2, realm);

        // 28.1.14 Reflect [ %Symbol.toStringTag% ]
        // https://tc39.es/ecma262/#sec-reflect-%symbol.tostringtag%
        try object.defineBuiltinPropertyWithAttributes(
            agent,
            "Symbol.toStringTag",
            Value.from("Reflect"),
            .{
                .writable = false,
                .enumerable = false,
                .configurable = true,
            },
        );
    }

    /// 28.1.1 Reflect.apply ( target, thisArg, args )
    /// https://tc39.es/ecma262/#sec-reflect.apply
    fn apply(agent: *Agent, _: Value, arguments: Arguments) Agent.Error!Value {
        const target = arguments.get(0);
        const this_arg = arguments.get(1);
        const args = arguments.get(2);

        // 1. If IsCallable(target) is false, throw a TypeError exception.
        if (!target.isCallable()) {
            return agent.throwException(.type_error, "{f} is not callable", .{target});
        }

        // 2. Let argList be ? CreateListFromArrayLike(args).
        const arg_list = try args.createListFromArrayLike(agent, null);

        // 3. Perform PrepareForTailCall().
        // 4. Return ? Call(target, thisArg, argList).
        return target.call(agent, this_arg, arg_list);
    }

    /// 28.1.2 Reflect.construct ( target, args [ , newTarget ] )
    /// https://tc39.es/ecma262/#sec-reflect.construct
    fn construct(agent: *Agent, _: Value, arguments: Arguments) Agent.Error!Value {
        const target = arguments.get(0);
        const args = arguments.get(1);
        var new_target = arguments.get(2);

        // 1. If IsConstructor(target) is false, throw a TypeError exception.
        if (!target.isConstructor()) {
            return agent.throwException(.type_error, "{f} is not a constructor", .{target});
        }

        // 2. If newTarget is not present, set newTarget to target.
        if (arguments.count() <= 2) {
            new_target = target;
        }
        // 3. Else if IsConstructor(newTarget) is false, throw a TypeError exception.
        else if (!new_target.isConstructor()) {
            return agent.throwException(.type_error, "{f} is not a constructor", .{new_target});
        }

        // 4. Let argList be ? CreateListFromArrayLike(args).
        const arg_list = try args.createListFromArrayLike(agent, null);

        // 5. Return ? Construct(target, argList, newTarget).
        return Value.from(try target.asObject().construct(agent, arg_list, new_target.asObject()));
    }

    /// 28.1.3 Reflect.defineProperty ( target, key, attrs )
    /// https://tc39.es/ecma262/#sec-reflect.defineproperty
    fn defineProperty(agent: *Agent, _: Value, arguments: Arguments) Agent.Error!Value {
        const target = arguments.get(0);
        const key = arguments.get(1);
        const attrs = arguments.get(2);

        // 1. If target is not an Object, throw a TypeError exception.
        if (!target.isObject()) {
            return agent.throwException(.type_error, "{f} is not an Object", .{target});
        }

        // 2. Let propertyKey be ? ToPropertyKey(key).
        const property_key = try key.toPropertyKey(agent);

        // 3. Let propertyDesc be ? ToPropertyDescriptor(attrs).
        const property_desc = try attrs.toPropertyDescriptor(agent);

        // 4. Return ? target.[[DefineOwnProperty]](propertyKey, propertyDesc).
        return Value.from(
            try target.asObject().internalMethods().defineOwnProperty(
                agent,
                target.asObject(),
                property_key,
                property_desc,
            ),
        );
    }

    /// 28.1.4 Reflect.deleteProperty ( target, key )
    /// https://tc39.es/ecma262/#sec-reflect.deleteproperty
    fn deleteProperty(agent: *Agent, _: Value, arguments: Arguments) Agent.Error!Value {
        const target = arguments.get(0);
        const key = arguments.get(1);

        // 1. If target is not an Object, throw a TypeError exception.
        if (!target.isObject()) {
            return agent.throwException(.type_error, "{f} is not an Object", .{target});
        }

        // 2. Let propertyKey be ? ToPropertyKey(key).
        const property_key = try key.toPropertyKey(agent);

        // 3. Return ? target.[[Delete]](propertyKey).
        return Value.from(try target.asObject().internalMethods().delete(
            agent,
            target.asObject(),
            property_key,
        ));
    }

    /// 28.1.5 Reflect.get ( target, key [ , receiver ] )
    /// https://tc39.es/ecma262/#sec-reflect.get
    fn get(agent: *Agent, _: Value, arguments: Arguments) Agent.Error!Value {
        const target = arguments.get(0);
        const key = arguments.get(1);

        // 1. If target is not an Object, throw a TypeError exception.
        if (!target.isObject()) {
            return agent.throwException(.type_error, "{f} is not an Object", .{target});
        }

        // 2. Let propertyKey be ? ToPropertyKey(key).
        const property_key = try key.toPropertyKey(agent);

        // 3. If receiver is not present, then
        //     a. Set receiver to target.
        const receiver = arguments.getOrNull(2) orelse target;

        // 4. Return ? target.[[Get]](propertyKey, receiver).
        return try target.asObject().internalMethods().get(
            agent,
            target.asObject(),
            property_key,
            receiver,
        );
    }

    /// 28.1.6 Reflect.getOwnPropertyDescriptor ( target, key )
    /// https://tc39.es/ecma262/#sec-reflect.getownpropertydescriptor
    fn getOwnPropertyDescriptor(agent: *Agent, _: Value, arguments: Arguments) Agent.Error!Value {
        const target = arguments.get(0);
        const key = arguments.get(1);

        // 1. If target is not an Object, throw a TypeError exception.
        if (!target.isObject()) {
            return agent.throwException(.type_error, "{f} is not an Object", .{target});
        }

        // 2. Let propertyKey be ? ToPropertyKey(key).
        const property_key = try key.toPropertyKey(agent);

        // 3. Let propertyDesc be ? target.[[GetOwnProperty]](propertyKey).
        const maybe_property_desc = try target.asObject().internalMethods().getOwnProperty(
            agent,
            target.asObject(),
            property_key,
        );

        // 4. Return FromPropertyDescriptor(propertyDesc).
        if (maybe_property_desc) |property_desc|
            return Value.from(try property_desc.fromPropertyDescriptor(agent))
        else
            return .undefined;
    }

    /// 28.1.7 Reflect.getPrototypeOf ( target )
    /// https://tc39.es/ecma262/#sec-reflect.getprototypeof
    fn getPrototypeOf(agent: *Agent, _: Value, arguments: Arguments) Agent.Error!Value {
        const target = arguments.get(0);

        // 1. If target is not an Object, throw a TypeError exception.
        if (!target.isObject()) {
            return agent.throwException(.type_error, "{f} is not an Object", .{target});
        }

        // 2. Return ? target.[[GetPrototypeOf]]().
        return Value.from(
            try target.asObject().internalMethods().getPrototypeOf(
                agent,
                target.asObject(),
            ) orelse return .null,
        );
    }

    /// 28.1.8 Reflect.has ( target, key )
    /// https://tc39.es/ecma262/#sec-reflect.has
    fn has(agent: *Agent, _: Value, arguments: Arguments) Agent.Error!Value {
        const target = arguments.get(0);
        const key = arguments.get(1);

        // 1. If target is not an Object, throw a TypeError exception.
        if (!target.isObject()) {
            return agent.throwException(.type_error, "{f} is not an Object", .{target});
        }

        // 2. Let propertyKey be ? ToPropertyKey(key).
        const property_key = try key.toPropertyKey(agent);

        // 3. Return ? target.[[HasProperty]](propertyKey).
        return Value.from(
            try target.asObject().internalMethods().hasProperty(agent, target.asObject(), property_key),
        );
    }

    /// 28.1.9 Reflect.isExtensible ( target )
    /// https://tc39.es/ecma262/#sec-reflect.isextensible
    fn isExtensible(agent: *Agent, _: Value, arguments: Arguments) Agent.Error!Value {
        const target = arguments.get(0);

        // 1. If target is not an Object, throw a TypeError exception.
        if (!target.isObject()) {
            return agent.throwException(.type_error, "{f} is not an Object", .{target});
        }

        // 2. Return ? target.[[IsExtensible]]().
        return Value.from(
            try target.asObject().internalMethods().isExtensible(agent, target.asObject()),
        );
    }

    /// 28.1.10 Reflect.ownKeys ( target )
    /// https://tc39.es/ecma262/#sec-reflect.ownkeys
    fn ownKeys(agent: *Agent, _: Value, arguments: Arguments) Agent.Error!Value {
        const target = arguments.get(0);

        // 1. If target is not an Object, throw a TypeError exception.
        if (!target.isObject()) {
            return agent.throwException(.type_error, "{f} is not an Object", .{target});
        }

        // 2. Let keys be ? target.[[OwnPropertyKeys]]().
        const keys = try target.asObject().internalMethods().ownPropertyKeys(
            agent,
            target.asObject(),
        );
        defer agent.gc_allocator.free(keys);

        // 3. Return CreateArrayFromList(keys).
        const array = try createArrayFromListMapToValue(agent, PropertyKey, keys, struct {
            fn mapFn(agent_: *Agent, property_key: PropertyKey) std.mem.Allocator.Error!Value {
                return property_key.toValue(agent_);
            }
        }.mapFn);
        return Value.from(&array.object);
    }

    /// 28.1.11 Reflect.preventExtensions ( target )
    /// https://tc39.es/ecma262/#sec-reflect.preventextensions
    fn preventExtensions(agent: *Agent, _: Value, arguments: Arguments) Agent.Error!Value {
        const target = arguments.get(0);

        // 1. If target is not an Object, throw a TypeError exception.
        if (!target.isObject()) {
            return agent.throwException(.type_error, "{f} is not an Object", .{target});
        }

        // 2. Return ? target.[[PreventExtensions]]().
        return Value.from(
            try target.asObject().internalMethods().preventExtensions(agent, target.asObject()),
        );
    }

    /// 28.1.12 Reflect.set ( target, key, value [ , receiver ] )
    /// https://tc39.es/ecma262/#sec-reflect.set
    fn set(agent: *Agent, _: Value, arguments: Arguments) Agent.Error!Value {
        const target = arguments.get(0);
        const key = arguments.get(1);
        const value = arguments.get(2);

        // 1. If target is not an Object, throw a TypeError exception.
        if (!target.isObject()) {
            return agent.throwException(.type_error, "{f} is not an Object", .{target});
        }

        // 2. Let propertyKey be ? ToPropertyKey(key).
        const property_key = try key.toPropertyKey(agent);

        // 3. If receiver is not present, then
        //     a. Set receiver to target.
        const receiver = arguments.getOrNull(3) orelse target;

        // 4. Return ? target.[[Set]](propertyKey, value, receiver).
        return Value.from(
            try target.asObject().internalMethods().set(
                agent,
                target.asObject(),
                property_key,
                value,
                receiver,
            ),
        );
    }

    /// 28.1.13 Reflect.setPrototypeOf ( target, proto )
    /// https://tc39.es/ecma262/#sec-reflect.setprototypeof
    fn setPrototypeOf(agent: *Agent, _: Value, arguments: Arguments) Agent.Error!Value {
        const target = arguments.get(0);
        const proto = arguments.get(1);

        // 1. If target is not an Object, throw a TypeError exception.
        if (!target.isObject()) {
            return agent.throwException(.type_error, "{f} is not an Object", .{target});
        }

        // 2. If proto is not an Object and proto is not null, throw a TypeError exception.
        if (!proto.isObject() and !proto.isNull()) {
            return agent.throwException(.type_error, "{f} is not an Object or null", .{proto});
        }

        // 3. Return ? target.[[SetPrototypeOf]](proto).
        return Value.from(
            try target.asObject().internalMethods().setPrototypeOf(
                agent,
                target.asObject(),
                if (proto.isObject()) proto.asObject() else null,
            ),
        );
    }
};
