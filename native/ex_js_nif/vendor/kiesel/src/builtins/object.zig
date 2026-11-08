//! 20.1 Object Objects
//! https://tc39.es/ecma262/#sec-object-objects

const std = @import("std");

const build_options = @import("build-options");
const builtins = @import("../builtins.zig");
const execution = @import("../execution.zig");
const types = @import("../types.zig");
const utils = @import("../utils.zig");

const Agent = execution.Agent;
const Arguments = types.Arguments;
const MakeObject = types.MakeObject;
const PropertyDescriptor = types.PropertyDescriptor;
const PropertyKey = types.PropertyKey;
const Realm = execution.Realm;
const String = types.String;
const Value = types.Value;
const addEntriesFromIterable = builtins.addEntriesFromIterable;
const createArrayFromList = types.createArrayFromList;
const createArrayFromListMapToValue = types.createArrayFromListMapToValue;
const createBuiltinFunction = builtins.createBuiltinFunction;
const noexcept = utils.noexcept;
const ordinaryCreateFromConstructor = builtins.ordinaryCreateFromConstructor;
const ordinaryObjectCreate = builtins.ordinaryObjectCreate;
const sameValue = types.sameValue;

/// 20.1.2 Properties of the Object Constructor
/// https://tc39.es/ecma262/#sec-properties-of-the-object-constructor
pub const constructor = struct {
    pub fn create(agent: *Agent, realm: *Realm) std.mem.Allocator.Error!*types.Object {
        const builtin_function = try createBuiltinFunction(
            agent,
            .{ .constructor = impl },
            1,
            "Object",
            .{ .realm = realm, .proto = try realm.intrinsic(.function_prototype) },
        );
        return &builtin_function.object;
    }

    pub fn init(agent: *Agent, realm: *Realm, object: *types.Object) std.mem.Allocator.Error!void {
        try object.defineBuiltinFunction(agent, "assign", assign, 2, realm);
        try object.defineBuiltinFunction(agent, "create", create_, 2, realm);
        try object.defineBuiltinFunction(agent, "defineProperties", defineProperties, 2, realm);
        try object.defineBuiltinFunction(agent, "defineProperty", defineProperty, 3, realm);
        try object.defineBuiltinFunction(agent, "entries", entries, 1, realm);
        try object.defineBuiltinFunction(agent, "freeze", freeze, 1, realm);
        try object.defineBuiltinFunction(agent, "fromEntries", fromEntries, 1, realm);
        try object.defineBuiltinFunction(agent, "getOwnPropertyDescriptor", getOwnPropertyDescriptor, 2, realm);
        try object.defineBuiltinFunction(agent, "getOwnPropertyDescriptors", getOwnPropertyDescriptors, 1, realm);
        try object.defineBuiltinFunction(agent, "getOwnPropertyNames", getOwnPropertyNames, 1, realm);
        try object.defineBuiltinFunction(agent, "getOwnPropertySymbols", getOwnPropertySymbols, 1, realm);
        try object.defineBuiltinFunction(agent, "getPrototypeOf", getPrototypeOf, 1, realm);
        try object.defineBuiltinFunction(agent, "groupBy", groupBy, 2, realm);
        try object.defineBuiltinFunction(agent, "hasOwn", hasOwn, 2, realm);
        try object.defineBuiltinFunction(agent, "is", is, 2, realm);
        try object.defineBuiltinFunction(agent, "isExtensible", isExtensible, 1, realm);
        try object.defineBuiltinFunction(agent, "isFrozen", isFrozen, 1, realm);
        try object.defineBuiltinFunction(agent, "isSealed", isSealed, 1, realm);
        try object.defineBuiltinFunction(agent, "keys", keys, 1, realm);
        try object.defineBuiltinFunction(agent, "preventExtensions", preventExtensions, 1, realm);
        try object.defineBuiltinFunction(agent, "seal", seal, 1, realm);
        try object.defineBuiltinFunction(agent, "setPrototypeOf", setPrototypeOf, 2, realm);
        try object.defineBuiltinFunction(agent, "values", values, 1, realm);

        // 20.1.2.21 Object.prototype
        // https://tc39.es/ecma262/#sec-object.prototype
        try object.defineBuiltinPropertyWithAttributes(
            agent,
            "prototype",
            Value.from(try realm.intrinsic(.object_prototype)),
            .none,
        );
    }

    /// 20.1.1.1 Object ( value )
    /// https://tc39.es/ecma262/#sec-object-value
    fn impl(agent: *Agent, arguments: Arguments, new_target: ?*types.Object) Agent.Error!Value {
        const realm = agent.currentRealm();
        const value = arguments.get(0);

        // 1. If NewTarget is neither undefined nor the active function object, then
        if (new_target != null and new_target.? != agent.activeFunctionObject()) {
            // a. Return ? OrdinaryCreateFromConstructor(NewTarget, "%Object.prototype%").
            const obj = try ordinaryCreateFromConstructor(
                Object,
                agent,
                new_target.?,
                .object_prototype,
                {},
            );
            return Value.from(&obj.object);
        }

        // 2. If value is either undefined or null, return OrdinaryObjectCreate(%Object.prototype%).
        if (value.isUndefined() or value.isNull()) {
            return Value.from(try ordinaryObjectCreate(
                agent,
                try realm.intrinsic(.object_prototype),
            ));
        }

        // 3. Return ! ToObject(value).
        return Value.from(value.toObject(agent) catch |err| try noexcept(err));
    }

    /// 20.1.2.1 Object.assign ( target, ...sources )
    /// https://tc39.es/ecma262/#sec-object.assign
    fn assign(agent: *Agent, _: Value, arguments: Arguments) Agent.Error!Value {
        const target = arguments.get(0);
        const sources = if (arguments.count() <= 1) &[_]Value{} else arguments.values[1..];

        // 1. Let targetObj be ? ToObject(target).
        const target_obj = try target.toObject(agent);

        // 2. If only one argument was passed, return targetObj.
        if (arguments.count() == 1) return Value.from(target_obj);

        // 3. For each element nextSource of sources, do
        for (sources) |next_source| {
            // a. If nextSource is neither undefined nor null, then
            if (!next_source.isUndefined() and !next_source.isNull()) {
                // i. Let from be ! ToObject(nextSource).
                const from = next_source.toObject(agent) catch |err| try noexcept(err);

                // ii. Let keys be ? from.[[OwnPropertyKeys]]().
                const keys_ = try from.internalMethods().ownPropertyKeys(agent, from);
                defer agent.gc_allocator.free(keys_);

                // iii. For each element nextKey of keys, do
                for (keys_) |next_key| {
                    // 1. Let propertyDesc be ? from.[[GetOwnProperty]](nextKey).
                    const property_desc = try from.internalMethods().getOwnProperty(
                        agent,
                        from,
                        next_key,
                    );

                    // 2. If propertyDesc is not undefined and propertyDesc.[[Enumerable]] is true,
                    //    then
                    if (property_desc != null and property_desc.?.enumerable == true) {
                        // a. Let propertyValue be ? Get(from, nextKey).
                        const property_value = try from.get(agent, next_key);

                        // b. Perform ? Set(targetObj, nextKey, propertyValue, true).
                        try target_obj.set(agent, next_key, property_value, .throw);
                    }
                }
            }
        }

        // 4. Return targetObj.
        return Value.from(target_obj);
    }

    /// 20.1.2.2 Object.create ( proto, properties )
    /// https://tc39.es/ecma262/#sec-object.create
    fn create_(agent: *Agent, _: Value, arguments: Arguments) Agent.Error!Value {
        const proto = arguments.get(0);
        const properties = arguments.get(1);

        // 1. If proto is not an Object and proto is not null, throw a TypeError exception.
        if (!proto.isObject() and !proto.isNull()) {
            return agent.throwException(.type_error, "{f} is not an Object or null", .{proto});
        }

        // 2. Let obj be OrdinaryObjectCreate(proto).
        const obj = try ordinaryObjectCreate(
            agent,
            if (proto.isObject()) proto.asObject() else null,
        );

        // 3. If properties is not undefined, then
        if (!properties.isUndefined()) {
            // a. Return ? ObjectDefineProperties(obj, properties).
            return Value.from(try objectDefineProperties(agent, obj, properties));
        }

        // 4. Return obj.
        return Value.from(obj);
    }

    /// 20.1.2.3 Object.defineProperties ( obj, properties )
    /// https://tc39.es/ecma262/#sec-object.defineproperties
    fn defineProperties(agent: *Agent, _: Value, arguments: Arguments) Agent.Error!Value {
        const obj = arguments.get(0);
        const properties = arguments.get(1);

        // 1. If obj is not an Object, throw a TypeError exception.
        if (!obj.isObject()) {
            return agent.throwException(.type_error, "{f} is not an Object", .{obj});
        }

        // 2. Return ? ObjectDefineProperties(obj, properties).
        return Value.from(try objectDefineProperties(agent, obj.asObject(), properties));
    }

    /// 20.1.2.3.1 ObjectDefineProperties ( obj, properties )
    /// https://tc39.es/ecma262/#sec-objectdefineproperties
    fn objectDefineProperties(
        agent: *Agent,
        obj: *types.Object,
        properties_value: Value,
    ) Agent.Error!*types.Object {
        // 1. Set properties to ? ToObject(properties).
        const properties = try properties_value.toObject(agent);

        // 2. Let keys be ? properties.[[OwnPropertyKeys]]().
        const keys_ = try properties.internalMethods().ownPropertyKeys(agent, properties);
        defer agent.gc_allocator.free(keys_);

        const Property = struct {
            /// [[Key]]
            key: PropertyKey,
            /// [[Descriptor]]
            descriptor: PropertyDescriptor,
        };

        // 3. Let propertyDescs be a new empty List.
        var property_descs: std.ArrayList(Property) = .empty;
        defer property_descs.deinit(agent.gc_allocator);

        // 4. For each element nextKey of keys, do
        for (keys_) |next_key| {
            // a. Let currentPropertyDesc be ? properties.[[GetOwnProperty]](nextKey).
            const current_property_desc = try properties.internalMethods().getOwnProperty(
                agent,
                properties,
                next_key,
            );

            // b. If currentPropertyDesc is not undefined and currentPropertyDesc.[[Enumerable]] is
            //    true, then
            if (current_property_desc != null and current_property_desc.?.enumerable == true) {
                // i. Let propertyDescObj be ? Get(properties, nextKey).
                const property_desc_obj = try properties.get(agent, next_key);

                // ii. Let propertyDesc be ? ToPropertyDescriptor(propertyDescObj).
                const property_desc = try property_desc_obj.toPropertyDescriptor(agent);

                // iii. Append the Record { [[Key]]: nextKey, [[Descriptor]]: propertyDesc } to
                //      propertyDescs.
                try property_descs.append(agent.gc_allocator, .{
                    .key = next_key,
                    .descriptor = property_desc,
                });
            }
        }

        // 5. For each element property of propertyDescs, do
        for (property_descs.items) |property| {
            // a. Perform ? DefinePropertyOrThrow(obj, property.[[Key]], property.[[Descriptor]]).
            try obj.definePropertyOrThrow(agent, property.key, property.descriptor);
        }

        // 6. Return obj.
        return obj;
    }

    /// 20.1.2.4 Object.defineProperty ( obj, key, attrs )
    /// https://tc39.es/ecma262/#sec-object.defineproperty
    fn defineProperty(agent: *Agent, _: Value, arguments: Arguments) Agent.Error!Value {
        const obj = arguments.get(0);
        const key = arguments.get(1);
        const attrs = arguments.get(2);

        // 1. If obj is not an Object, throw a TypeError exception.
        if (!obj.isObject()) {
            return agent.throwException(.type_error, "{f} is not an Object", .{obj});
        }

        // 2. Let propertyKey be ? ToPropertyKey(key).
        const property_key = try key.toPropertyKey(agent);

        // 3. Let propertyDesc be ? ToPropertyDescriptor(attrs).
        const property_desc = try attrs.toPropertyDescriptor(agent);

        // 4. Perform ? DefinePropertyOrThrow(obj, propertyKey, propertyDesc).
        try obj.asObject().definePropertyOrThrow(agent, property_key, property_desc);

        // 5. Return obj.
        return obj;
    }

    /// 20.1.2.5 Object.entries ( obj )
    /// https://tc39.es/ecma262/#sec-object.entries
    fn entries(agent: *Agent, _: Value, arguments: Arguments) Agent.Error!Value {
        const obj = arguments.get(0);

        // 1. Let coerced be ? ToObject(obj).
        const coerced = try obj.toObject(agent);

        // 2. Let entryList be ? EnumerableOwnProperties(coerced, key+value).
        var entry_list = try coerced.enumerableOwnProperties(agent, .key_value);
        defer entry_list.deinit(agent.gc_allocator);

        // 3. Return CreateArrayFromList(entryList).
        const array = try createArrayFromList(agent, entry_list.items);
        return Value.from(&array.object);
    }

    /// 20.1.2.6 Object.freeze ( obj )
    /// https://tc39.es/ecma262/#sec-object.freeze
    fn freeze(agent: *Agent, _: Value, arguments: Arguments) Agent.Error!Value {
        const obj = arguments.get(0);

        // 1. If obj is not an Object, return obj.
        if (!obj.isObject()) return obj;

        // 2. Let status be ? SetIntegrityLevel(obj, frozen).
        const status = try obj.asObject().setIntegrityLevel(agent, .frozen);

        // 3. If status is false, throw a TypeError exception.
        if (!status) return agent.throwException(.type_error, "Could not freeze object", .{});

        // 4. Return obj.
        return obj;
    }

    /// 20.1.2.7 Object.fromEntries ( iterable )
    /// https://tc39.es/ecma262/multipage/fundamental-objects.html#sec-object.fromentries
    fn fromEntries(agent: *Agent, _: Value, arguments: Arguments) Agent.Error!Value {
        const realm = agent.currentRealm();
        const iterable = arguments.get(0);

        // 1. Perform ? RequireObjectCoercible(iterable).
        try iterable.requireObjectCoercible(agent);

        // 2. Let obj be OrdinaryObjectCreate(%Object.prototype%).
        // 3. Assert: obj is an extensible ordinary object with no own properties.
        const obj = try ordinaryObjectCreate(
            agent,
            try realm.intrinsic(.object_prototype),
        );

        const Captures = struct {
            object: *types.Object,
        };
        const captures = try agent.gc_allocator.create(Captures);
        captures.* = .{ .object = obj };

        // 4. Let closure be a new Abstract Closure with parameters (key, value) that captures obj
        //    and performs the following steps when called:
        const closure = struct {
            fn func(agent_: *Agent, _: Value, arguments_: Arguments) Agent.Error!Value {
                const function = agent_.activeFunctionObject();
                const captures_ = function.as(builtins.BuiltinFunction).fields.additionalFieldsAs(Captures);
                const object_ = captures_.object;
                const key = arguments_.get(0);
                const value = arguments_.get(1);

                // a. Let propertyKey be ? ToPropertyKey(key).
                const property_key = try key.toPropertyKey(agent_);

                // b. Perform ! CreateDataPropertyOrThrow(obj, propertyKey, value).
                try object_.createDataPropertyDirect(agent_, property_key, value);

                // c. Return NormalCompletion(undefined).
                return .undefined;
            }
        }.func;

        // 5. Let adder be CreateBuiltinFunction(closure, 2, "", « »).
        const adder = try createBuiltinFunction(
            agent,
            .{ .function = closure },
            2,
            "",
            .{ .additional_fields = captures },
        );

        // 6. Return ? AddEntriesFromIterable(obj, iterable, adder).
        return Value.from(try addEntriesFromIterable(agent, obj, iterable, &adder.object));
    }

    /// 20.1.2.8 Object.getOwnPropertyDescriptor ( obj, key )
    /// https://tc39.es/ecma262/#sec-object.getownpropertydescriptor
    fn getOwnPropertyDescriptor(agent: *Agent, _: Value, arguments: Arguments) Agent.Error!Value {
        const obj = arguments.get(0);
        const key = arguments.get(1);

        // 1. Let coerced be ? ToObject(obj).
        const coerced = try obj.toObject(agent);

        // 2. Let propertyKey be ? ToPropertyKey(key).
        const property_key = try key.toPropertyKey(agent);

        // 3. Let propertyDesc be ? coerced.[[GetOwnProperty]](propertyKey).
        const property_desc = try coerced.internalMethods().getOwnProperty(agent, coerced, property_key);

        // 4. Return FromPropertyDescriptor(propertyDesc).
        if (property_desc) |descriptor|
            return Value.from(try descriptor.fromPropertyDescriptor(agent))
        else
            return .undefined;
    }

    /// 20.1.2.9 Object.getOwnPropertyDescriptors ( obj )
    /// https://tc39.es/ecma262/#sec-object.getownpropertydescriptors
    fn getOwnPropertyDescriptors(agent: *Agent, _: Value, arguments: Arguments) Agent.Error!Value {
        const realm = agent.currentRealm();
        const obj = arguments.get(0);

        // 1. Let coerced be ? ToObject(obj).
        const coerced = try obj.toObject(agent);

        // 2. Let ownKeys be ? coerced.[[OwnPropertyKeys]]().
        const own_keys = try coerced.internalMethods().ownPropertyKeys(agent, coerced);
        defer agent.gc_allocator.free(own_keys);

        // 3. Let descs be OrdinaryObjectCreate(%Object.prototype%).
        const descs = try ordinaryObjectCreate(
            agent,
            try realm.intrinsic(.object_prototype),
        );

        // 4. For each element key of ownKeys, do
        for (own_keys) |key| {
            // a. Let propertyDesc be ? coerced.[[GetOwnProperty]](key).
            if (try coerced.internalMethods().getOwnProperty(agent, coerced, key)) |property_desc| {
                // b. Let propertyDescObj be FromPropertyDescriptor(propertyDesc).
                const property_desc_obj = try property_desc.fromPropertyDescriptor(agent);

                // c. If propertyDescObj is not undefined, perform ! CreateDataPropertyOrThrow(
                //    descs, key, propertyDescObj).
                try descs.createDataPropertyDirect(agent, key, Value.from(property_desc_obj));
            }
        }

        // 5. Return descs.
        return Value.from(descs);
    }

    /// 20.1.2.10 Object.getOwnPropertyNames ( obj )
    /// https://tc39.es/ecma262/#sec-object.getownpropertynames
    fn getOwnPropertyNames(agent: *Agent, _: Value, arguments: Arguments) Agent.Error!Value {
        const obj = arguments.get(0);

        // 1. Return CreateArrayFromList(? GetOwnPropertyKeys(obj, string)).
        const property_keys = try getOwnPropertyKeys(agent, obj, .string);
        defer agent.gc_allocator.free(property_keys);
        const array = try createArrayFromListMapToValue(agent, PropertyKey, property_keys, struct {
            fn mapFn(agent_: *Agent, property_key: PropertyKey) std.mem.Allocator.Error!Value {
                return property_key.toValue(agent_);
            }
        }.mapFn);
        return Value.from(&array.object);
    }

    /// 20.1.2.11 Object.getOwnPropertySymbols ( obj )
    /// https://tc39.es/ecma262/#sec-object.getownpropertysymbols
    fn getOwnPropertySymbols(agent: *Agent, _: Value, arguments: Arguments) Agent.Error!Value {
        const obj = arguments.get(0);

        // 1. Return CreateArrayFromList(? GetOwnPropertyKeys(obj, symbol)).
        const property_keys = try getOwnPropertyKeys(agent, obj, .symbol);
        defer agent.gc_allocator.free(property_keys);
        const array = try createArrayFromListMapToValue(agent, PropertyKey, property_keys, struct {
            fn mapFn(agent_: *Agent, property_key: PropertyKey) std.mem.Allocator.Error!Value {
                return property_key.toValue(agent_);
            }
        }.mapFn);
        return Value.from(&array.object);
    }

    /// 20.1.2.11.1 GetOwnPropertyKeys ( value, type )
    /// https://tc39.es/ecma262/#sec-getownpropertykeys
    fn getOwnPropertyKeys(
        agent: *Agent,
        value: Value,
        comptime @"type": enum { string, symbol },
    ) Agent.Error![]PropertyKey {
        // 1. Let obj be ? ToObject(value).
        const obj = try value.toObject(agent);

        // 2. Let keys be ? obj.[[OwnPropertyKeys]]().
        const keys_ = try obj.internalMethods().ownPropertyKeys(agent, obj);
        defer agent.gc_allocator.free(keys_);

        // 3. Let nameList be a new empty List.
        var name_list: std.ArrayList(PropertyKey) = .empty;

        // 4. For each element nextKey of keys, do
        for (keys_) |next_key| {
            // a. If nextKey is a Symbol and type is symbol, or if nextKey is a String and type is
            //    string, then
            if ((next_key == .symbol and @"type" == .symbol) or
                ((next_key == .string or next_key == .integer_index) and @"type" == .string))
            {
                // i. Append nextKey to nameList.
                try name_list.append(agent.gc_allocator, next_key);
            }
        }

        // 5. Return nameList.
        return name_list.toOwnedSlice(agent.gc_allocator);
    }

    /// 20.1.2.12 Object.getPrototypeOf ( obj )
    /// https://tc39.es/ecma262/#sec-object.getprototypeof
    fn getPrototypeOf(agent: *Agent, _: Value, arguments: Arguments) Agent.Error!Value {
        const obj = arguments.get(0);

        // 1. Let coerced be ? ToObject(obj).
        const coerced = try obj.toObject(agent);

        // 2. Return ? coerced.[[GetPrototypeOf]]().
        return if (try coerced.internalMethods().getPrototypeOf(agent, coerced)) |proto|
            Value.from(proto)
        else
            .null;
    }

    /// 20.1.2.13 Object.groupBy ( items, callback )
    /// https://tc39.es/ecma262/#sec-object.groupby
    fn groupBy(agent: *Agent, _: Value, arguments: Arguments) Agent.Error!Value {
        const items = arguments.get(0);
        const callback = arguments.get(1);

        // 1. Let groups be ? GroupBy(items, callback, property).
        const groups = try items.groupBy(agent, callback, .property);

        // 2. Let obj be OrdinaryObjectCreate(null).
        const obj = try ordinaryObjectCreate(agent, null);

        // 3. For each Record { [[Key]], [[Elements]] } group of groups, do
        var it = groups.iterator();
        while (it.next()) |entry| {
            // a. Let elements be CreateArrayFromList(group.[[Elements]]).
            const elements = try createArrayFromList(agent, entry.value_ptr.items);

            // b. Perform ! CreateDataPropertyOrThrow(obj, group.[[Key]], elements).
            try obj.createDataPropertyDirect(
                agent,
                entry.key_ptr.*,
                Value.from(&elements.object),
            );
        }

        // 4. Return obj.
        return Value.from(obj);
    }

    /// 20.1.2.14 Object.hasOwn ( obj, key )
    /// https://tc39.es/ecma262/#sec-object.hasown
    fn hasOwn(agent: *Agent, _: Value, arguments: Arguments) Agent.Error!Value {
        const obj = arguments.get(0);
        const key = arguments.get(1);

        // 1. Let coerced be ? ToObject(obj).
        const coerced = try obj.toObject(agent);

        // 2. Let propertyKey be ? ToPropertyKey(key).
        const property_key = try key.toPropertyKey(agent);

        // 3. Return ? HasOwnProperty(coerced, propertyKey).
        return Value.from(try coerced.hasOwnProperty(agent, property_key));
    }

    /// 20.1.2.15 Object.is ( value1, value2 )
    /// https://tc39.es/ecma262/#sec-object.is
    fn is(_: *Agent, _: Value, arguments: Arguments) Agent.Error!Value {
        const value1 = arguments.get(0);
        const value2 = arguments.get(1);

        // 1. Return SameValue(value1, value2).
        return Value.from(sameValue(value1, value2));
    }

    /// 20.1.2.16 Object.isExtensible ( obj )
    /// https://tc39.es/ecma262/#sec-object.isextensible
    fn isExtensible(agent: *Agent, _: Value, arguments: Arguments) Agent.Error!Value {
        const obj = arguments.get(0);

        // 1. If obj is not an Object, return false.
        if (!obj.isObject()) return .false;

        // 2. Return ? IsExtensible(obj).
        return Value.from(try obj.asObject().isExtensible(agent));
    }

    /// 20.1.2.17 Object.isFrozen ( obj )
    /// https://tc39.es/ecma262/#sec-object.isfrozen
    fn isFrozen(agent: *Agent, _: Value, arguments: Arguments) Agent.Error!Value {
        const obj = arguments.get(0);

        // 1. If obj is not an Object, return true.
        if (!obj.isObject()) return .true;

        // 2. Return ? TestIntegrityLevel(obj, frozen).
        return Value.from(try obj.asObject().testIntegrityLevel(agent, .frozen));
    }

    /// 20.1.2.18 Object.isSealed ( obj )
    /// https://tc39.es/ecma262/#sec-object.issealed
    fn isSealed(agent: *Agent, _: Value, arguments: Arguments) Agent.Error!Value {
        const obj = arguments.get(0);

        // 1. If obj is not an Object, return true.
        if (!obj.isObject()) return .true;

        // 2. Return ? TestIntegrityLevel(obj, sealed).
        return Value.from(try obj.asObject().testIntegrityLevel(agent, .sealed));
    }

    /// 20.1.2.19 Object.keys ( obj )
    /// https://tc39.es/ecma262/#sec-object.keys
    fn keys(agent: *Agent, _: Value, arguments: Arguments) Agent.Error!Value {
        const obj = arguments.get(0);

        // 1. Let coerced be ? ToObject(obj).
        const coerced = try obj.toObject(agent);

        // 2. Let keyList be ? EnumerableOwnProperties(coerced, key).
        var key_list = try coerced.enumerableOwnProperties(agent, .key);
        defer key_list.deinit(agent.gc_allocator);

        // 3. Return CreateArrayFromList(keyList).
        const array = try createArrayFromList(agent, key_list.items);
        return Value.from(&array.object);
    }

    /// 20.1.2.20 Object.preventExtensions ( obj )
    /// https://tc39.es/ecma262/#sec-object.preventextensions
    fn preventExtensions(agent: *Agent, _: Value, arguments: Arguments) Agent.Error!Value {
        const obj = arguments.get(0);

        // 1. If obj is not an Object, return obj.
        if (!obj.isObject()) return obj;

        // 2. Let status be ? obj.[[PreventExtensions]]().
        const status = try obj.asObject().internalMethods().preventExtensions(agent, obj.asObject());

        // 3. If status is false, throw a TypeError exception.
        if (!status) return agent.throwException(.type_error, "Could not prevent extensions", .{});

        // 4. Return obj.
        return obj;
    }

    /// 20.1.2.22 Object.seal ( obj )
    /// https://tc39.es/ecma262/#sec-object.seal
    fn seal(agent: *Agent, _: Value, arguments: Arguments) Agent.Error!Value {
        const obj = arguments.get(0);

        // 1. If obj is not an Object, return obj.
        if (!obj.isObject()) return obj;

        // 2. Let status be ? SetIntegrityLevel(obj, sealed).
        const status = try obj.asObject().setIntegrityLevel(agent, .sealed);

        // 3. If status is false, throw a TypeError exception.
        if (!status) return agent.throwException(.type_error, "Could not seal object", .{});

        // 4. Return obj.
        return obj;
    }

    /// 20.1.2.23 Object.setPrototypeOf ( obj, proto )
    /// https://tc39.es/ecma262/#sec-object.setprototypeof
    fn setPrototypeOf(agent: *Agent, _: Value, arguments: Arguments) Agent.Error!Value {
        const obj = arguments.get(0);
        const proto = arguments.get(1);

        // 1. Perform ? RequireObjectCoercible(obj).
        try obj.requireObjectCoercible(agent);

        // 2. If proto is not an Object and proto is not null, throw a TypeError exception.
        if (!proto.isObject() and !proto.isNull()) {
            return agent.throwException(.type_error, "{f} is not an Object or null", .{proto});
        }

        // 3. If obj is not an Object, return obj.
        if (!obj.isObject()) return obj;

        // 4. Let status be ? obj.[[SetPrototypeOf]](proto).
        const status = try obj.asObject().internalMethods().setPrototypeOf(
            agent,
            obj.asObject(),
            if (proto.isObject()) proto.asObject() else null,
        );

        // 5. If status is false, throw a TypeError exception.
        if (!status) return agent.throwException(.type_error, "Could not set prototype", .{});

        // 6. Return obj.
        return obj;
    }

    /// 20.1.2.24 Object.values ( obj )
    /// https://tc39.es/ecma262/#sec-object.values
    fn values(agent: *Agent, _: Value, arguments: Arguments) Agent.Error!Value {
        const obj = arguments.get(0);

        // 1. Let coerced be ? ToObject(obj).
        const coerced = try obj.toObject(agent);

        // 2. Let valueList be ? EnumerableOwnProperties(coerced, value).
        var value_list = try coerced.enumerableOwnProperties(agent, .value);
        defer value_list.deinit(agent.gc_allocator);

        // 3. Return CreateArrayFromList(valueList).
        const array = try createArrayFromList(agent, value_list.items);
        return Value.from(&array.object);
    }
};

/// 20.1.3 Properties of the Object Prototype Object
/// https://tc39.es/ecma262/#sec-properties-of-the-object-prototype-object
pub const prototype = struct {
    pub fn create(agent: *Agent, _: *Realm) std.mem.Allocator.Error!*types.Object {
        const object = try Object.create(agent, .{
            .prototype = null,
            .internal_methods = .initComptime(.{
                .setPrototypeOf = builtins.immutable_prototype.setPrototypeOf,
            }),
        });
        return &object.object;
    }

    pub fn init(agent: *Agent, realm: *Realm, object: *types.Object) std.mem.Allocator.Error!void {
        try object.defineBuiltinFunction(agent, "hasOwnProperty", hasOwnProperty, 1, realm);
        try object.defineBuiltinFunction(agent, "isPrototypeOf", isPrototypeOf, 1, realm);
        try object.defineBuiltinFunction(agent, "propertyIsEnumerable", propertyIsEnumerable, 1, realm);
        try object.defineBuiltinFunction(agent, "toLocaleString", toLocaleString, 0, realm);
        try object.defineBuiltinFunction(agent, "toString", toString, 0, realm);
        try object.defineBuiltinFunction(agent, "valueOf", valueOf, 0, realm);

        // 20.1.3.1 Object.prototype.constructor
        // https://tc39.es/ecma262/#sec-object.prototype.constructor
        try object.defineBuiltinProperty(
            agent,
            "constructor",
            Value.from(try realm.intrinsic(.object)),
        );

        if (build_options.enable_legacy) {
            try object.defineBuiltinAccessor(agent, "__proto__", @"get __proto__", @"set __proto__", realm);
            try object.defineBuiltinFunction(agent, "__defineGetter__", __defineGetter__, 2, realm);
            try object.defineBuiltinFunction(agent, "__defineSetter__", __defineSetter__, 2, realm);
            try object.defineBuiltinFunction(agent, "__lookupGetter__", __lookupGetter__, 1, realm);
            try object.defineBuiltinFunction(agent, "__lookupSetter__", __lookupSetter__, 1, realm);
        }

        // Ensure property intrinsics are looked up right after the object is created
        _ = try realm.intrinsic(.object_prototype_to_string);
    }

    /// 20.1.3.2 Object.prototype.hasOwnProperty ( value )
    /// https://tc39.es/ecma262/#sec-object.prototype.hasownproperty
    fn hasOwnProperty(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const value = arguments.get(0);

        // 1. Let propertyKey be ? ToPropertyKey(value).
        const property_key = try value.toPropertyKey(agent);

        // 2. Let obj be ? ToObject(this value).
        const obj = try this_value.toObject(agent);

        // 3. Return ? HasOwnProperty(obj, propertyKey).
        return Value.from(try obj.hasOwnProperty(agent, property_key));
    }

    /// 20.1.3.3 Object.prototype.isPrototypeOf ( value )
    /// https://tc39.es/ecma262/#sec-object.prototype.isprototypeof
    fn isPrototypeOf(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const value = arguments.get(0);

        // 1. If value is not an Object, return false.
        if (!value.isObject()) return .false;

        // 2. Let obj be ? ToObject(this value).
        const obj = try this_value.toObject(agent);

        var proto = value.asObject();

        // 3. Repeat,
        while (true) {
            // a. Set value to ? value.[[GetPrototypeOf]]().
            proto = try proto.internalMethods().getPrototypeOf(agent, proto) orelse {
                // b. If value is null, return false.
                return .false;
            };

            // c. If SameValue(obj, value) is true, return true.
            if (obj == proto) return .true;
        }
    }

    /// 20.1.3.4 Object.prototype.propertyIsEnumerable ( value )
    /// https://tc39.es/ecma262/#sec-object.prototype.propertyisenumerable
    fn propertyIsEnumerable(
        agent: *Agent,
        this_value: Value,
        arguments: Arguments,
    ) Agent.Error!Value {
        const value = arguments.get(0);

        // 1. Let propertyKey be ? ToPropertyKey(value).
        const property_key = try value.toPropertyKey(agent);

        // 2. Let obj be ? ToObject(this value).
        const obj = try this_value.toObject(agent);

        // 3. Let propertyDesc be ? obj.[[GetOwnProperty]](propertyKey).
        const property_desc = try obj.internalMethods().getOwnProperty(
            agent,
            obj,
            property_key,
        ) orelse {
            // 4. If propertyDesc is undefined, return false.
            return .false;
        };

        // 5. Return propertyDesc.[[Enumerable]].
        return Value.from(property_desc.enumerable.?);
    }

    /// 20.1.3.5 Object.prototype.toLocaleString ( [ reserved1 [ , reserved2 ] ] )
    /// https://tc39.es/ecma262/#sec-object.prototype.tolocalestring
    fn toLocaleString(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let thisValue be the this value.
        // 2. Return ? Invoke(thisValue, "toString").
        return this_value.invoke(agent, PropertyKey.from("toString"), &.{});
    }

    /// 20.1.3.6 Object.prototype.toString ( )
    /// https://tc39.es/ecma262/#sec-object.prototype.tostring
    fn toString(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. If the this value is undefined, return "[object Undefined]".
        if (this_value.isUndefined()) return Value.from("[object Undefined]");

        // 2. If the this value is null, return "[object Null]".
        if (this_value.isNull()) return Value.from("[object Null]");

        // 3. Let obj be ! ToObject(this value).
        const obj = this_value.toObject(agent) catch |err| try noexcept(err);

        // 4. Let isArray be ? IsArray(obj).
        const is_array = try this_value.isArray(agent);

        // zig fmt: off
        // 5. If isArray is true, let builtinTag be "Array".
        const builtin_tag = if (is_array)
            String.fromLiteral("Array")
        // 6. Else if obj has a [[ParameterMap]] internal slot, let builtinTag be "Arguments".
        else if (obj.is(builtins.Arguments))
            String.fromLiteral("Arguments")
        // 7. Else if obj has a [[Call]] internal method, let builtinTag be "Function".
        else if (obj.internalMethods().call) |_|
            String.fromLiteral("Function")
        // 8. Else if obj has an [[ErrorData]] internal slot, let builtinTag be "Error".
        else if (obj.is(builtins.Error))
            String.fromLiteral("Error")
        // 9. Else if obj has a [[BooleanData]] internal slot, let builtinTag be "Boolean".
        else if (obj.is(builtins.Boolean))
            String.fromLiteral("Boolean")
        // 10. Else if obj has a [[NumberData]] internal slot, let builtinTag be "Number".
        else if (obj.is(builtins.Number))
            String.fromLiteral("Number")
        // 11. Else if obj has a [[StringData]] internal slot, let builtinTag be "String".
        else if (obj.is(builtins.String))
            String.fromLiteral("String")
        // 12. Else if obj has a [[DateValue]] internal slot, let builtinTag be "Date".
        else if (obj.is(builtins.Date))
            String.fromLiteral("Date")
        // 13. Else if obj has a [[RegExpMatcher]] internal slot, let builtinTag be "RegExp".
        else if (obj.is(builtins.RegExp))
            String.fromLiteral("RegExp")
        // 14. Else, let builtinTag be "Object".
        else
            String.fromLiteral("Object");
        // zig fmt: on

        // 15. Let tag be ? Get(obj, %Symbol.toStringTag%).
        const tag_value = try obj.get(agent, PropertyKey.from(agent.well_known_symbols.to_string_tag));

        // 16. If tag is not a String, set tag to builtinTag.
        const tag = if (tag_value.isString()) tag_value.asString() else builtin_tag;

        // 17. Return the string-concatenation of "[object ", tag, and "]".
        return Value.from(
            try String.concat(agent, &.{
                String.fromLiteral("[object "),
                tag,
                String.fromLiteral("]"),
            }),
        );
    }

    /// 20.1.3.7 Object.prototype.valueOf ( )
    /// https://tc39.es/ecma262/#sec-object.prototype.valueof
    fn valueOf(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Return ? ToObject(this value).
        return Value.from(try this_value.toObject(agent));
    }

    /// 20.1.3.8.1 get Object.prototype.__proto__
    /// https://tc39.es/ecma262/#sec-get-object.prototype.__proto__
    fn @"get __proto__"(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let obj be ? ToObject(this value).
        const obj = try this_value.toObject(agent);

        // 2. Return ? obj.[[GetPrototypeOf]]().
        return if (try obj.internalMethods().getPrototypeOf(agent, obj)) |proto|
            Value.from(proto)
        else
            .null;
    }

    /// 20.1.3.8.2 set Object.prototype.__proto__
    /// https://tc39.es/ecma262/#sec-set-object.prototype.__proto__
    fn @"set __proto__"(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const proto = arguments.get(0);

        // 1. Let thisValue be the this value.

        // 2. Perform ? RequireObjectCoercible(thisValue).
        try this_value.requireObjectCoercible(agent);

        // 3. If proto is not an Object and proto is not null, return undefined.
        if (!proto.isObject() and !proto.isNull()) return .undefined;

        // 4. If thisValue is not an Object, return undefined.
        if (!this_value.isObject()) return .undefined;

        // 5. Let status be ? thisValue.[[SetPrototypeOf]](proto).
        const status = try this_value.asObject().internalMethods().setPrototypeOf(
            agent,
            this_value.asObject(),
            if (proto.isObject()) proto.asObject() else null,
        );

        // 6. If status is false, throw a TypeError exception.
        if (!status) {
            return agent.throwException(.type_error, "Could not set prototype", .{});
        }

        // 7. Return undefined.
        return .undefined;
    }

    /// 20.1.3.9.1 Object.prototype.__defineGetter__ ( key, getter )
    /// https://tc39.es/ecma262/#sec-object.prototype.__defineGetter__
    fn __defineGetter__(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const key = arguments.get(0);
        const getter = arguments.get(1);

        // 1. Let obj be ? ToObject(this value).
        const obj = try this_value.toObject(agent);

        // 2. If IsCallable(getter) is false, throw a TypeError exception.
        if (!getter.isCallable()) {
            return agent.throwException(.type_error, "{f} is not callable", .{getter});
        }

        // 3. Let propertyDesc be PropertyDescriptor { [[Getter]]: getter, [[Enumerable]]: true,
        //    [[Configurable]]: true }.
        const property_desc: PropertyDescriptor = .{
            .getter = getter.asObject(),
            .enumerable = true,
            .configurable = true,
        };

        // 4. Let propertyKey be ? ToPropertyKey(key).
        const property_key = try key.toPropertyKey(agent);

        // 5. Perform ? DefinePropertyOrThrow(obj, propertyKey, propertyDesc).
        try obj.definePropertyOrThrow(agent, property_key, property_desc);

        // 6. Return undefined.
        return .undefined;
    }

    /// 20.1.3.9.2 Object.prototype.__defineSetter__ ( key, setter )
    /// https://tc39.es/ecma262/#sec-object.prototype.__defineSetter__
    fn __defineSetter__(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const key = arguments.get(0);
        const setter = arguments.get(1);

        // 1. Let obj be ? ToObject(this value).
        const obj = try this_value.toObject(agent);

        // 2. If IsCallable(setter) is false, throw a TypeError exception.
        if (!setter.isCallable()) {
            return agent.throwException(.type_error, "{f} is not callable", .{setter});
        }

        // 3. Let propertyDesc be PropertyDescriptor { [[Setter]]: setter, [[Enumerable]]: true,
        //    [[Configurable]]: true }.
        const property_desc: PropertyDescriptor = .{
            .setter = setter.asObject(),
            .enumerable = true,
            .configurable = true,
        };

        // 4. Let propertyKey be ? ToPropertyKey(key).
        const property_key = try key.toPropertyKey(agent);

        // 5. Perform ? DefinePropertyOrThrow(obj, propertyKey, propertyDesc).
        try obj.definePropertyOrThrow(agent, property_key, property_desc);

        // 6. Return undefined.
        return .undefined;
    }

    /// 20.1.3.9.3 Object.prototype.__lookupGetter__ ( key )
    /// https://tc39.es/ecma262/#sec-object.prototype.__lookupGetter__
    fn __lookupGetter__(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const key = arguments.get(0);

        // 1. Let obj be ? ToObject(this value).
        var obj = try this_value.toObject(agent);

        // 2. Let propertyKey be ? ToPropertyKey(key).
        const property_key = try key.toPropertyKey(agent);

        // 3. Repeat,
        while (true) {
            // a. Let propertyDesc be ? obj.[[GetOwnProperty]](propertyKey).
            // b. If propertyDesc is not undefined, then
            if (try obj.internalMethods().getOwnProperty(
                agent,
                obj,
                property_key,
            )) |property_desc| {
                // i. If IsAccessorDescriptor(propertyDesc) is true, return propertyDesc.[[Getter]].
                if (property_desc.isAccessorDescriptor()) {
                    return Value.from(property_desc.getter.? orelse return .undefined);
                }

                // ii. Return undefined.
                return .undefined;
            }

            // c. Set obj to ? obj.[[GetPrototypeOf]]().
            obj = try obj.internalMethods().getPrototypeOf(agent, obj) orelse {
                // d. If obj is null, return undefined.
                return .undefined;
            };
        }
    }

    /// 20.1.3.9.4 Object.prototype.__lookupSetter__ ( key )
    /// https://tc39.es/ecma262/#sec-object.prototype.__lookupSetter__
    fn __lookupSetter__(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const key = arguments.get(0);

        // 1. Let obj be ? ToObject(this value).
        var obj = try this_value.toObject(agent);

        // 2. Let propertyKey be ? ToPropertyKey(key).
        const property_key = try key.toPropertyKey(agent);

        // 3. Repeat,
        while (true) {
            // a. Let propertyDesc be ? obj.[[GetOwnProperty]](propertyKey).
            // b. If propertyDesc is not undefined, then
            if (try obj.internalMethods().getOwnProperty(
                agent,
                obj,
                property_key,
            )) |property_desc| {
                // i. If IsAccessorDescriptor(propertyDesc) is true, return propertyDesc.[[Setter]].
                if (property_desc.isAccessorDescriptor()) {
                    return Value.from(property_desc.setter.? orelse return .undefined);
                }

                // ii. Return undefined.
                return .undefined;
            }

            // c. Set obj to ? obj.[[GetPrototypeOf]]().
            obj = try obj.internalMethods().getPrototypeOf(agent, obj) orelse {
                // d. If obj is null, return undefined.
                return .undefined;
            };
        }
    }
};

/// 20.1.4 Properties of Object Instances
/// https://tc39.es/ecma262/#sec-properties-of-object-instances
pub const Object = MakeObject(.{
    .tag = .object,
    .display_name = "Object",
});
