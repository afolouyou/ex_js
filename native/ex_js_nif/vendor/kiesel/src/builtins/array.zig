//! 10.4.2 Array Exotic Objects
//! https://tc39.es/ecma262/#sec-array-exotic-objects

const std = @import("std");

const build_options = @import("build-options");
const builtins = @import("../builtins.zig");
const execution = @import("../execution.zig");
const ordinary = @import("ordinary.zig");
const types = @import("../types.zig");
const utils = @import("../utils.zig");

const Agent = execution.Agent;
const Arguments = types.Arguments;
const Iterator = types.Iterator;
const MakeObject = types.MakeObject;
const Object = types.Object;
const PropertyDescriptor = types.PropertyDescriptor;
const PropertyKey = Object.PropertyKey;
const Realm = execution.Realm;
const String = types.String;
const Value = types.Value;
const await = builtins.await;
const createArrayIterator = builtins.createArrayIterator;
const createAsyncFromSyncIterator = builtins.createAsyncFromSyncIterator;
const createBuiltinFunction = builtins.createBuiltinFunction;
const getIteratorFromMethod = types.getIteratorFromMethod;
const getPrototypeFromConstructor = builtins.getPrototypeFromConstructor;
const isLessThan = types.isLessThan;
const isStrictlyEqual = types.isStrictlyEqual;
const noexcept = utils.noexcept;
const ordinaryDefineOwnProperty = ordinary.ordinaryDefineOwnProperty;
const ordinaryObjectCreate = ordinary.ordinaryObjectCreate;
const sameValueZero = types.sameValueZero;

const array_fast_paths = @import("array_fast_paths.zig");

pub const internal_methods = Object.InternalMethods.initComptime(.{
    .defineOwnProperty = defineOwnProperty,
});

/// 10.4.2.1 [[DefineOwnProperty]] ( propertyKey, propertyDesc )
/// https://tc39.es/ecma262/#sec-array-exotic-objects-defineownproperty-p-desc
fn defineOwnProperty(
    agent: *Agent,
    array: *Object,
    property_key: PropertyKey,
    property_desc: PropertyDescriptor,
) Agent.Error!bool {
    // 1. If propertyKey is "length", return ? ArraySetLength(array, propertyDesc).
    if (property_key.isLength()) {
        return arraySetLength(agent, array.as(builtins.Array), property_desc);
    }

    // 2. If propertyKey is an array index, then
    if (property_key.isArrayIndex()) {
        // a. Let lengthDesc be OrdinaryGetOwnProperty(array, "length").
        // b. Assert: lengthDesc is not undefined.
        // c. Assert: IsDataDescriptor(lengthDesc) is true.
        // d. Assert: lengthDesc.[[Configurable]] is false.

        // e. Let length be lengthDesc.[[Value]].
        // f. Assert: length is a non-negative integral Number.
        const length = array.as(builtins.Array).fields.length;

        // g. Let index be ! ToUint32(propertyKey).
        const index: u32 = @intCast(property_key.integer_index);

        // h. If index ≥ length and lengthDesc.[[Writable]] is false, return false.
        if (index >= length and !array.as(builtins.Array).fields.length_writable)
            return false;

        // i. Let succeeded be ! OrdinaryDefineOwnProperty(array, propertyKey, propertyDesc).
        const succeeded = ordinaryDefineOwnProperty(
            agent,
            array,
            property_key,
            property_desc,
        ) catch |err| try noexcept(err);

        // j. If succeeded is false, return false.
        if (!succeeded)
            return false;

        // k. If index ≥ length, then
        if (index >= length) {
            // i. Set lengthDesc.[[Value]] to index + 1𝔽.
            // ii. Set succeeded to ! OrdinaryDefineOwnProperty(array, "length", lengthDesc).
            // iii. Assert: succeeded is true.
            array.as(builtins.Array).fields.length = index + 1;
        }

        // l. Return true.
        return true;
    }

    // 3. Return ? OrdinaryDefineOwnProperty(array, propertyKey, propertyDesc).
    return ordinaryDefineOwnProperty(agent, array, property_key, property_desc);
}

/// 10.4.2.2 ArrayCreate ( length [ , proto ] )
/// https://tc39.es/ecma262/#sec-arraycreate
pub fn arrayCreate(agent: *Agent, length: u53, maybe_proto: ?*Object) Agent.Error!*Array {
    const realm = agent.currentRealm();

    // 1. If length > 2**32 - 1, throw a RangeError exception.
    if (length > std.math.maxInt(u32)) {
        return agent.throwException(.range_error, "Invalid array length", .{});
    }

    // 2. If proto is not present, set proto to %Array.prototype%.
    const proto = maybe_proto orelse {
        // OPTIMIZATION: When no custom prototype is provided we can use the default array shape.
        const shape = try realm.shape(.array);
        return arrayCreateFastWithShape(agent, @intCast(length), shape);
    };

    // 3. Let array be MakeBasicObject(« [[Prototype]], [[Extensible]] »).
    const array = try Array.create(agent, .{
        // 4. Set array.[[Prototype]] to proto.
        .prototype = proto,

        // 5. Set array.[[DefineOwnProperty]] as specified in 10.4.2.1.
        .internal_methods = internal_methods,

        // 6. Perform ! OrdinaryDefineOwnProperty(array, "length", PropertyDescriptor {
        //    [[Value]]: 𝔽(length), [[Writable]]: true, [[Enumerable]]: false,
        //    [[Configurable]]: false }).
        .fields = .{
            .length = @intCast(length),
            .length_writable = true,
        },
    });

    // 7. Return array.
    return array;
}

pub fn arrayCreateFast(agent: *Agent, length: u32) std.mem.Allocator.Error!*Array {
    const realm = agent.currentRealm();
    const shape = try realm.shape(.array);
    return arrayCreateFastWithShape(agent, length, shape);
}

pub fn arrayCreateFastWithShape(
    agent: *Agent,
    length: u32,
    shape: *Object.Shape,
) std.mem.Allocator.Error!*Array {
    return Array.createWithShape(agent, .{
        .shape = shape,
        .fields = .{
            .length = length,
            .length_writable = true,
        },
    });
}

/// 10.4.2.3 ArraySpeciesCreate ( originalArray, length )
/// https://tc39.es/ecma262/#sec-arrayspeciescreate
pub fn arraySpeciesCreate(agent: *Agent, original_array: *Object, length: u53) Agent.Error!*Object {
    // 1. Let isArray be ? IsArray(originalArray).
    const is_array = try Value.from(original_array).isArray(agent);

    // 2. If isArray is false, return ? ArrayCreate(length).
    if (!is_array) {
        const array = try arrayCreate(agent, length, null);
        return &array.object;
    }

    // 3. Let ctor be ? Get(originalArray, "constructor").
    var ctor = try original_array.get(agent, PropertyKey.from("constructor"));

    // 4. If IsConstructor(ctor) is true, then
    if (ctor.isConstructor()) {
        // a. Let thisRealm be the current Realm Record.
        const this_realm = agent.currentRealm();

        // b. Let ctorRealm be ? GetFunctionRealm(ctor).
        const ctor_realm = try ctor.asObject().getFunctionRealm(agent);

        // c. If thisRealm and ctorRealm are not the same Realm Record, then
        if (this_realm != ctor_realm) {
            // i. If SameValue(ctor, ctorRealm.[[Intrinsics]].[[%Array%]]) is true, set ctor to
            //    undefined.
            if (ctor.asObject() == try ctor_realm.intrinsic(.array)) {
                ctor = .undefined;
            }
        }
    }

    // 5. If ctor is an Object, then
    if (ctor.isObject()) {
        // a. Set ctor to ? Get(ctor, %Symbol.species%).
        ctor = try ctor.get(
            agent,
            PropertyKey.from(agent.well_known_symbols.species),
        );

        // b. If ctor is null, set ctor to undefined.
        if (ctor.isNull()) ctor = .undefined;
    }

    // 6. If ctor is undefined, return ? ArrayCreate(length).
    if (ctor.isUndefined()) {
        const array = try arrayCreate(agent, length, null);
        return &array.object;
    }

    // 7. If IsConstructor(ctor) is false, throw a TypeError exception.
    if (!ctor.isConstructor()) {
        return agent.throwException(.type_error, "{f} is not a constructor", .{ctor});
    }

    // 8. Return ? Construct(ctor, « 𝔽(length) »).
    return ctor.asObject().construct(agent, &.{Value.from(length)}, null);
}

/// 10.4.2.4 ArraySetLength ( array, propertyDesc )
/// https://tc39.es/ecma262/#sec-arraysetlength
fn arraySetLength(
    agent: *Agent,
    array: *builtins.Array,
    property_desc: PropertyDescriptor,
) Agent.Error!bool {
    // 1. If propertyDesc does not have a [[Value]] field, then
    //     a. Return ! OrdinaryDefineOwnProperty(array, "length", propertyDesc).
    // 2. Let newLengthDesc be a copy of propertyDesc.

    var new_length: u32 = array.fields.length;
    if (property_desc.value) |new_len_value| {
        // 3. Let newLength be ? ToUint32(propertyDesc.[[Value]]).
        new_length = try new_len_value.toUint32(agent);

        // 4. Let numberLength be ? ToNumber(propertyDesc.[[Value]]).
        const number_length = try new_len_value.toNumber(agent);

        // 5. If SameValueZero(newLength, numberLength) is false, throw a RangeError exception.
        if (@as(f64, @floatFromInt(new_length)) != number_length.asFloat()) {
            return agent.throwException(.range_error, "Invalid array length", .{});
        }
    }

    // 6. Set newLengthDesc.[[Value]] to newLength.
    // 7. Let oldLengthDesc be OrdinaryGetOwnProperty(array, "length").
    // 8. Assert: oldLengthDesc is not undefined.
    // 9. Assert: IsDataDescriptor(oldLengthDesc) is true.
    // 10. Assert: oldLengthDesc.[[Configurable]] is false.
    // 11. Let oldLength be oldLengthDesc.[[Value]].
    const old_length = array.fields.length;
    const old_writable = array.fields.length_writable;

    // 12. If newLength ≥ oldLength, then
    //     a. Return ! OrdinaryDefineOwnProperty(array, "length", newLengthDesc).
    // 13. If oldLengthDesc.[[Writable]] is false, return false.

    // 14. If newLengthDesc does not have a [[Writable]] field or newLengthDesc.[[Writable]] is
    //     true, then
    //     a. Let newWritable be true.
    // 15. Else,
    //     a. NOTE: Setting the [[Writable]] attribute to false is deferred in case any elements
    //        cannot be deleted.
    //     b. Let newWritable be false.
    //     c. Set newLengthDesc.[[Writable]] to true.
    const new_writable = property_desc.writable orelse true;

    // 16. Let succeeded be ! OrdinaryDefineOwnProperty(array, "length", newLengthDesc).
    // 17. If succeeded is false, return false.
    // Relevant steps from ValidateAndApplyPropertyDescriptor
    if (property_desc.configurable == true) return false;
    if (property_desc.enumerable == true) return false;
    if (!property_desc.isGenericDescriptor() and property_desc.isAccessorDescriptor()) return false;
    if (!old_writable) {
        if (property_desc.writable == true) return false;
        if (old_length != new_length) return false;
    }
    array.fields.length = new_length;

    const extra_data = array.object.extra_data;
    if (new_length < old_length and extra_data != null) {
        // 18. For each own property key propertyKey of array such that propertyKey is an array
        //     index and ! ToUint32(propertyKey) ≥ newLength, in descending numeric index order, do
        //     a. Let deleteSucceeded be ! array.[[Delete]](propertyKey).
        switch (extra_data.?.indexed_properties.storage) {
            .none => {},
            // `shrinkRetainingCapacity()` asserts that the new length is less than the old length,
            // so we have to check the storage size first.
            .dense_i32 => |*dense_i32| if (dense_i32.items.len > new_length) dense_i32.shrinkRetainingCapacity(new_length),
            .dense_f64 => |*dense_f64| if (dense_f64.items.len > new_length) dense_f64.shrinkRetainingCapacity(new_length),
            .dense_value => |*dense_value| if (dense_value.items.len > new_length) dense_value.shrinkRetainingCapacity(new_length),
            .sparse_value => |*sparse_value| {
                var indices: std.ArrayList(u32) = .empty;
                defer indices.deinit(agent.gc_allocator);
                try indices.ensureTotalCapacity(agent.gc_allocator, sparse_value.count());
                var it = sparse_value.keyIterator();
                while (it.next()) |index| if (index.* >= new_length) indices.appendAssumeCapacity(index.*);
                std.sort.insertion(u32, indices.items, {}, std.sort.asc(u32));
                while (indices.pop()) |index| {
                    const removed = sparse_value.remove(index);
                    std.debug.assert(removed);
                }
            },
            .sparse_property_descriptor => |*sparse_property_descriptor| {
                var indices: std.ArrayList(u32) = .empty;
                defer indices.deinit(agent.gc_allocator);
                try indices.ensureTotalCapacity(agent.gc_allocator, sparse_property_descriptor.count());
                var it = sparse_property_descriptor.keyIterator();
                while (it.next()) |index| if (index.* >= new_length) indices.appendAssumeCapacity(index.*);
                std.sort.insertion(u32, indices.items, {}, std.sort.asc(u32));
                while (indices.pop()) |index| {
                    const descriptor = sparse_property_descriptor.get(index).?;

                    // b. If deleteSucceeded is false, then
                    if (!descriptor.attributes.configurable) {
                        // i. Set newLengthDesc.[[Value]] to ! ToUint32(propertyKey) + 1𝔽.

                        // ii. If newWritable is false, set newLengthDesc.[[Writable]] to false.
                        if (!new_writable) {
                            array.fields.length_writable = false;
                        }

                        // iii. Perform ! OrdinaryDefineOwnProperty(array, "length", newLengthDesc).
                        array.fields.length = index + 1;

                        // iv. Return false.
                        return false;
                    }

                    const removed = sparse_property_descriptor.remove(index);
                    std.debug.assert(removed);
                }
            },
        }
    }

    // 19. If newWritable is false, then
    if (!new_writable) {
        // a. Set succeeded to ! OrdinaryDefineOwnProperty(array, "length", PropertyDescriptor {
        //    [[Writable]]: false }).
        // b. Assert: succeeded is true.
        array.fields.length_writable = false;
    }

    // 20. Return true.
    return true;
}

/// 23.1.2 Properties of the Array Constructor
/// https://tc39.es/ecma262/#sec-properties-of-the-array-constructor
pub const constructor = struct {
    pub fn create(agent: *Agent, realm: *Realm) std.mem.Allocator.Error!*Object {
        const builtin_function = try createBuiltinFunction(
            agent,
            .{ .constructor = impl },
            1,
            "Array",
            .{ .realm = realm, .proto = try realm.intrinsic(.function_prototype) },
        );
        return &builtin_function.object;
    }

    pub fn init(agent: *Agent, realm: *Realm, object: *Object) std.mem.Allocator.Error!void {
        try object.defineBuiltinFunction(agent, "from", from, 1, realm);
        try object.defineBuiltinAsyncFunction(agent, "fromAsync", fromAsync, 1, realm);
        try object.defineBuiltinFunction(agent, "isArray", isArray, 1, realm);
        try object.defineBuiltinFunction(agent, "of", of, 0, realm);
        try object.defineBuiltinAccessor(agent, "Symbol.species", @"Symbol.species", null, realm);

        // 23.1.2.5 Array.prototype
        // https://tc39.es/ecma262/#sec-array.prototype
        try object.defineBuiltinPropertyWithAttributes(
            agent,
            "prototype",
            Value.from(try realm.intrinsic(.array_prototype)),
            .none,
        );
    }

    /// 23.1.1.1 Array ( ...values )
    /// https://tc39.es/ecma262/#sec-array
    fn impl(agent: *Agent, arguments: Arguments, new_target: ?*Object) Agent.Error!Value {
        // 1. If NewTarget is undefined, let newTarget be the active function object; else let
        //    newTarget be NewTarget.
        const new_target_ = new_target orelse agent.activeFunctionObject();

        // 2. Let proto be ? GetPrototypeFromConstructor(newTarget, "%Array.prototype%").
        const proto = try getPrototypeFromConstructor(
            agent,
            new_target_,
            .array_prototype,
        );

        // 3. Let numberOfArgs be the number of elements in values.
        const number_of_args = arguments.count();

        // 4. If numberOfArgs = 0, return ! ArrayCreate(0, proto).
        if (number_of_args == 0) {
            const array = arrayCreate(agent, 0, proto) catch |err| try noexcept(err);
            return Value.from(&array.object);
        }

        // 5. If numberOfArgs = 1, then
        if (number_of_args == 1) {
            // a. Let length be values[0].
            const length = arguments.get(0);

            // b. Let array be ! ArrayCreate(0, proto).
            const array = arrayCreate(agent, 0, proto) catch |err| try noexcept(err);

            var int_length: u32 = undefined;

            // c. If length is not a Number, then
            if (!length.isNumber()) {
                // i. Perform ! CreateDataPropertyOrThrow(array, "0", length).
                try array.object.createDataPropertyDirect(agent, PropertyKey.from(0), length);

                // ii. Let intLength be 1𝔽.
                int_length = 1;
            } else {
                // d. Else,
                // i. Let intLength be ! ToUint32(length).
                int_length = length.toUint32(agent) catch unreachable;

                // ii. If SameValueZero(intLength, length) is false, throw a RangeError exception.
                if (@as(f64, @floatFromInt(int_length)) != length.asNumber().asFloat()) {
                    return agent.throwException(.range_error, "Invalid array length", .{});
                }
            }

            // e. Perform ! Set(array, "length", intLength, true).
            _ = array.object.set(
                agent,
                PropertyKey.from("length"),
                Value.from(int_length),
                .throw,
            ) catch |err| try noexcept(err);

            // f. Return array.
            return Value.from(&array.object);
        }

        // 6. Assert: numberOfArgs ≥ 2.
        std.debug.assert(number_of_args >= 2);

        // 7. Let array be ? ArrayCreate(numberOfArgs, proto).
        const array = try arrayCreate(agent, @intCast(number_of_args), proto);

        // 8. Let k be 0.
        // 9. Repeat, while k < numberOfArgs,
        for (arguments.values, 0..) |item_k, k| {
            // a. Let propertyKey be ! ToString(𝔽(k)).
            const property_key = PropertyKey.from(@as(PropertyKey.IntegerIndex, @intCast(k)));

            // b. Let itemK be values[k].
            // c. Perform ! CreateDataPropertyOrThrow(array, propertyKey, itemK).
            try array.object.createDataPropertyDirect(agent, property_key, item_k);

            // d. Set k to k + 1.
        }

        // 10. Assert: The mathematical value of array's "length" property is numberOfArgs.
        std.debug.assert(array.fields.length == @as(u32, @intCast(number_of_args)));

        // 11. Return array.
        return Value.from(&array.object);
    }

    /// 23.1.2.1 Array.from ( items [ , mapper [ , thisArg ] ] )
    /// https://tc39.es/ecma262/#sec-array.from
    fn from(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const items = arguments.get(0);
        const mapper_value = arguments.get(1);
        const this_arg = arguments.get(2);

        // 1. Let ctor be the this value.
        const ctor = this_value;

        // 2. If mapper is undefined, then
        const maybe_mapper = if (mapper_value.isUndefined()) blk: {
            // a. Let mapping be false.
            break :blk null;
        } else blk: {
            // 3. Else,
            // a. If IsCallable(mapper) is false, throw a TypeError exception.
            if (!mapper_value.isCallable()) {
                return agent.throwException(.type_error, "{f} is not callable", .{mapper_value});
            }

            // b. Let mapping be true.
            break :blk mapper_value.asObject();
        };

        // 4. Let usingIterator be ? GetMethod(items, %Symbol.iterator%).
        const using_iterator = try items.getMethod(
            agent,
            PropertyKey.from(agent.well_known_symbols.iterator),
        );

        // 5. If usingIterator is not undefined, then
        if (using_iterator != null) {
            // a. If IsConstructor(ctor) is true, then
            const array = if (ctor.isConstructor()) blk: {
                // i. Let array be ? Construct(ctor).
                break :blk try ctor.asObject().construct(agent, &.{}, null);
            } else blk: {
                // b. Else,
                // i. Let array be ! ArrayCreate(0).
                const array = try arrayCreateFast(agent, 0);
                break :blk &array.object;
            };

            // c. Let iteratorRecord be ? GetIteratorFromMethod(items, usingIterator).
            var iterator = try getIteratorFromMethod(agent, items, using_iterator.?);

            // d. Let k be 0.
            var k: u53 = 0;

            // e. Repeat,
            while (true) : (k += 1) {
                // i. If k ≥ 2**53 - 1, then
                if (k == std.math.maxInt(u53)) {
                    // 1. Let error be ThrowCompletion(a newly created TypeError object).
                    const @"error" = agent.throwException(
                        .type_error,
                        "Maximum array length exceeded",
                        .{},
                    );

                    // 2. Return ? IteratorClose(iteratorRecord, error).
                    return iterator.close(agent, @as(Agent.Error!Value, @"error"));
                }

                // ii. Let propertyKey be ! ToString(𝔽(k)).
                const property_key = PropertyKey.from(k);

                // iii. Let next be ? IteratorStepValue(iteratorRecord).
                // iv. If next is done, then
                const next = try iterator.stepValue(agent) orelse {
                    // 1. Perform ? Set(array, "length", 𝔽(k), true).
                    try array.set(agent, PropertyKey.from("length"), Value.from(k), .throw);

                    // 2. Return array.
                    return Value.from(array);
                };

                // v. If mapping is true, then
                const mapped_value = if (maybe_mapper) |mapper| blk: {
                    // 1. Let mappedValue be Completion(Call(mapper, thisArg, « next, 𝔽(k) »)).
                    break :blk mapper.call(
                        agent,
                        this_arg,
                        &.{ next, Value.from(k) },
                    ) catch |err| {
                        // 2. IfAbruptCloseIterator(mappedValue, iteratorRecord).
                        return iterator.close(agent, @as(Agent.Error!Value, err));
                    };
                } else blk: {
                    // vi. Else,
                    // 1. Let mappedValue be next.
                    break :blk next;
                };

                // vii. Let defineStatus be Completion(CreateDataPropertyOrThrow(array, propertyKey,
                //      mappedValue)).
                _ = array.createDataPropertyOrThrow(agent, property_key, mapped_value) catch |err| {
                    // viii. IfAbruptCloseIterator(defineStatus, iteratorRecord).
                    return iterator.close(agent, @as(Agent.Error!Value, err));
                };

                // ix. Set k to k + 1.
            }
        }

        // 6. NOTE: items is not iterable so assume it is an array-like object.
        // 7. Let arrayLike be ! ToObject(items).
        const array_like = items.toObject(agent) catch |err| try noexcept(err);

        // 8. Let length be ? LengthOfArrayLike(arrayLike).
        const length = try array_like.lengthOfArrayLike(agent);

        // 9. If IsConstructor(ctor) is true, then
        const array = if (ctor.isConstructor()) blk: {
            // a. Let array be ? Construct(ctor, « 𝔽(length) »).
            break :blk try ctor.asObject().construct(agent, &.{Value.from(length)}, null);
        } else blk: {
            // 10. Else,
            // a. Let array be ? ArrayCreate(length).
            const array = try arrayCreate(agent, length, null);
            break :blk &array.object;
        };

        // 11. Let k be 0.
        var k: u53 = 0;

        // 12. Repeat, while k < length,
        while (k < length) : (k += 1) {
            // a. Let propertyKey be ! ToString(𝔽(k)).
            const property_key = PropertyKey.from(k);

            // b. Let kValue be ? Get(arrayLike, propertyKey).
            const k_value = try array_like.get(agent, property_key);

            // c. If mapping is true, then
            const mapped_value = if (maybe_mapper) |mapper| blk: {
                // i. Let mappedValue be ? Call(mapper, thisArg, « kValue, 𝔽(k) »).
                break :blk try mapper.call(agent, this_arg, &.{ k_value, Value.from(k) });
            } else blk: {
                // d. Else,
                // i. Let mappedValue be kValue.
                break :blk k_value;
            };

            // e. Perform ? CreateDataPropertyOrThrow(array, propertyKey, mappedValue).
            try array.createDataPropertyOrThrow(agent, property_key, mapped_value);

            // f. Set k to k + 1.
        }

        // 13. Perform ? Set(array, "length", 𝔽(length), true).
        try array.set(agent, PropertyKey.from("length"), Value.from(length), .throw);

        // 14. Return array.
        return Value.from(array);
    }

    /// 23.1.2.2 Array.fromAsync ( items [ , mapper [ , thisArg ] ] )
    /// https://tc39.es/ecma262/#sec-array.fromasync
    fn fromAsync(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const items = arguments.get(0);
        const mapper_value = arguments.get(1);
        const this_arg = arguments.get(2);

        // 1. Let ctor be the this value.
        const ctor = this_value;

        // 2. Let mapping be false.
        // 3. If mapper is not undefined, then
        const maybe_mapper = if (!mapper_value.isUndefined()) blk: {
            // a. If IsCallable(mapper) is false, throw a TypeError exception.
            if (!mapper_value.isCallable()) {
                return agent.throwException(.type_error, "{f} is not callable", .{mapper_value});
            }

            // b. Set mapping to true.
            break :blk mapper_value.asObject();
        } else null;

        // 4. Let iteratorRecord be undefined.
        var maybe_iterator: ?Iterator = null;

        // 5. Let usingAsyncIterator be ? GetMethod(items, %Symbol.asyncIterator%).
        const using_async_iterator = try items.getMethod(
            agent,
            PropertyKey.from(agent.well_known_symbols.async_iterator),
        );

        // 6. If usingAsyncIterator is undefined, then
        if (using_async_iterator == null) {
            // a. Let usingSyncIterator be ? GetMethod(items, %Symbol.iterator%).
            const using_sync_iterator = try items.getMethod(
                agent,
                PropertyKey.from(agent.well_known_symbols.iterator),
            );

            // b. If usingSyncIterator is not undefined, then
            if (using_sync_iterator) |sync_iterator| {
                // i. Set iteratorRecord to CreateAsyncFromSyncIterator(? GetIteratorFromMethod(
                //    items, usingSyncIterator)).
                maybe_iterator = try createAsyncFromSyncIterator(
                    agent,
                    try getIteratorFromMethod(agent, items, sync_iterator),
                );
            }
        } else if (using_async_iterator) |async_iterator| {
            // 7. Else,
            // a. Set iteratorRecord to ? GetIteratorFromMethod(items, usingAsyncIterator).
            maybe_iterator = try getIteratorFromMethod(agent, items, async_iterator);
        } else unreachable;

        // 8. If iteratorRecord is not undefined, then
        if (maybe_iterator) |iterator| {
            // a. If IsConstructor(ctor) is true, then
            const array = if (ctor.isConstructor()) blk: {
                // i. Let array be ? Construct(ctor).
                break :blk try ctor.asObject().construct(agent, &.{}, null);
            } else blk: {
                // b. Else,
                // i. Let array be ! ArrayCreate(0).
                const array = try arrayCreateFast(agent, 0);
                break :blk &array.object;
            };

            // c. Let k be 0.
            var k: u53 = 0;

            // d. Repeat,
            while (true) : (k += 1) {
                // i. If k ≥ 2**53 - 1, then
                if (k == std.math.maxInt(u53)) {
                    // 1. Let error be ThrowCompletion(a newly created TypeError object).
                    const @"error" = agent.throwException(
                        .type_error,
                        "Maximum array length exceeded",
                        .{},
                    );

                    // 2. Return ? AsyncIteratorClose(iteratorRecord, error).
                    return iterator.closeAsync(agent, @as(Agent.Error!Value, @"error"));
                }

                // ii. Let propertyKey be ! ToString(𝔽(k)).
                const property_key = PropertyKey.from(k);

                // iii. Let nextResult be ? Call(iteratorRecord.[[NextMethod]],
                //      iteratorRecord.[[Iterator]]).
                var next_result_value = try iterator.next_method.asObject().call(
                    agent,
                    Value.from(iterator.iterator),
                    &.{},
                );

                // iv. Set nextResult to ? Await(nextResult).
                next_result_value = try await(agent, next_result_value);

                // v. If nextResult is not an Object, throw a TypeError exception.
                if (!next_result_value.isObject()) {
                    return agent.throwException(.type_error, "{f} is not an Object", .{next_result_value});
                }
                const next_result = next_result_value.asObject();

                // vi. Let done be ? IteratorComplete(nextResult).
                const done = try Iterator.complete(agent, next_result);

                // vii. If done is true, then
                if (done) {
                    // 1. Perform ? Set(array, "length", 𝔽(k), true).
                    try array.set(agent, PropertyKey.from("length"), Value.from(k), .throw);

                    // 2. Return array.
                    return Value.from(array);
                }

                // viii. Let nextValue be ? IteratorValue(nextResult).
                const next_value = try Iterator.value(agent, next_result);

                // ix. If mapping is true, then
                const mapped_value = if (maybe_mapper) |mapper| blk: {
                    // 1. Let mappedValue be Completion(Call(mapper, thisArg, « nextValue, 𝔽(k) »)).
                    var mapped_value = mapper.call(
                        agent,
                        this_arg,
                        &.{ next_value, Value.from(k) },
                    ) catch |err| switch (err) {
                        error.OutOfMemory => |e| return e,
                        error.ExceptionThrown => {
                            // 2. IfAbruptCloseAsyncIterator(mappedValue, iteratorRecord).
                            return iterator.closeAsync(agent, @as(Agent.Error!Value, err));
                        },
                    };

                    // 3. Set mappedValue to Completion(Await(mappedValue)).
                    mapped_value = await(agent, mapped_value) catch |err| switch (err) {
                        error.OutOfMemory => |e| return e,
                        error.ExceptionThrown => {
                            // 4. IfAbruptCloseAsyncIterator(mappedValue, iteratorRecord).
                            return iterator.closeAsync(agent, @as(Agent.Error!Value, err));
                        },
                    };

                    break :blk mapped_value;
                } else blk: {
                    // x. Else,
                    // 1. Let mappedValue be nextValue.
                    break :blk next_value;
                };

                // xi. Let defineStatus be Completion(CreateDataPropertyOrThrow(array, propertyKey,
                //     mappedValue)).
                array.createDataPropertyOrThrow(agent, property_key, mapped_value) catch |err| switch (err) {
                    error.OutOfMemory => |e| return e,
                    error.ExceptionThrown => {
                        // xii. IfAbruptCloseAsyncIterator(defineStatus, iteratorRecord).
                        return iterator.closeAsync(agent, @as(Agent.Error!Value, err));
                    },
                };

                // xiii. Set k to k + 1.
            }
        } else {
            // 9. Else,
            // a. NOTE: items is neither async iterable nor iterable so assume it is an array-like
            //    object.

            // b. Let arrayLike be ! ToObject(items).
            const array_like = items.toObject(agent) catch |err| try noexcept(err);

            // c. Let length be ? LengthOfArrayLike(arrayLike).
            const length = try array_like.lengthOfArrayLike(agent);

            // d. If IsConstructor(ctor) is true, then
            const array = if (ctor.isConstructor()) blk: {
                // i. Let array be ? Construct(ctor, « 𝔽(length) »).
                break :blk try ctor.asObject().construct(
                    agent,
                    &.{Value.from(length)},
                    null,
                );
            } else blk: {
                // e. Else,
                // i. Let array be ? ArrayCreate(length).
                const array = try arrayCreate(agent, length, null);
                break :blk &array.object;
            };

            // f. Let k be 0.
            var k: u53 = 0;

            // g. Repeat, while k < length,
            while (k < length) : (k += 1) {
                // i. Let propertyKey be ! ToString(𝔽(k)).
                const property_key = PropertyKey.from(k);

                // ii. Let kValue be ? Get(arrayLike, propertyKey).
                var k_value = try array_like.get(agent, property_key);

                // iii. Set kValue to ? Await(kValue).
                k_value = try await(agent, k_value);

                // iv. If mapping is true, then
                const mapped_value = if (maybe_mapper) |mapper| blk: {
                    // 1. Let mappedValue be ? Call(mapper, thisArg, « kValue, 𝔽(k) »).
                    var mapped_value = try mapper.call(
                        agent,
                        this_arg,
                        &.{ k_value, Value.from(k) },
                    );

                    // 2. Set mappedValue to ? Await(mappedValue).
                    mapped_value = try await(agent, mapped_value);

                    break :blk mapped_value;
                } else blk: {
                    // v. Else,
                    // 1. Let mappedValue be kValue.
                    break :blk k_value;
                };

                // vi. Perform ? CreateDataPropertyOrThrow(array, propertyKey, mappedValue).
                try array.createDataPropertyOrThrow(agent, property_key, mapped_value);

                // vii. Set k to k + 1.
            }

            // h. Perform ? Set(array, "length", 𝔽(length), true).
            try array.set(agent, PropertyKey.from("length"), Value.from(length), .throw);

            // i. Return array.
            return Value.from(array);
        }
    }

    /// 23.1.2.3 Array.isArray ( arg )
    /// https://tc39.es/ecma262/#sec-array.isarray
    fn isArray(agent: *Agent, _: Value, arguments: Arguments) Agent.Error!Value {
        const arg = arguments.get(0);

        // 1. Return ? IsArray(arg).
        return Value.from(try arg.isArray(agent));
    }

    /// 23.1.2.4 Array.of ( ...items )
    /// https://tc39.es/ecma262/#sec-array.of
    fn of(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        // 1. Let length be the number of elements in items.
        const length: u53 = @intCast(arguments.count());

        // 2. Let lengthNumber be 𝔽(length).
        const length_number = Value.from(length);

        // 3. Let ctor be the this value.
        const ctor = this_value;

        // 4. If IsConstructor(ctor) is true, then
        const array = blk: {
            if (ctor.isConstructor()) {
                // a. Let array be ? Construct(ctor, « lengthNumber »).
                break :blk try ctor.asObject().construct(agent, &.{length_number}, null);
            } else {
                // 5. Else,
                // a. Let array be ? ArrayCreate(length).
                const array = try arrayCreate(agent, length, null);
                break :blk &array.object;
            }
        };

        // 6. Let k be 0.
        // 7. Repeat, while k < length,
        for (arguments.values, 0..) |k_value, k| {
            // a. Let kValue be items[k].

            // b. Let propertyKey be ! ToString(𝔽(k)).
            const property_key = PropertyKey.from(@as(PropertyKey.IntegerIndex, @intCast(k)));

            // c. Perform ? CreateDataPropertyOrThrow(array, propertyKey, kValue).
            try array.createDataPropertyOrThrow(agent, property_key, k_value);

            // d. Set k to k + 1.
        }

        // 8. Perform ? Set(array, "length", lengthNumber, true).
        try array.set(agent, PropertyKey.from("length"), length_number, .throw);

        // 9. Return array.
        return Value.from(array);
    }

    /// 23.1.2.6 get Array [ %Symbol.species% ]
    /// https://tc39.es/ecma262/#sec-get-array-%symbol.species%
    fn @"Symbol.species"(_: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Return the this value.
        return this_value;
    }
};

/// 23.1.3 Properties of the Array Prototype Object
/// https://tc39.es/ecma262/#sec-properties-of-the-array-prototype-object
pub const prototype = struct {
    pub fn create(agent: *Agent, realm: *Realm) std.mem.Allocator.Error!*Object {
        const array = arrayCreate(
            agent,
            0,
            try realm.intrinsic(.object_prototype),
        ) catch |err| try noexcept(err);
        return &array.object;
    }

    pub fn init(agent: *Agent, realm: *Realm, object: *Object) std.mem.Allocator.Error!void {
        try object.defineBuiltinFunction(agent, "at", at, 1, realm);
        try object.defineBuiltinFunction(agent, "concat", concat, 1, realm);
        try object.defineBuiltinFunction(agent, "copyWithin", copyWithin, 2, realm);
        try object.defineBuiltinFunction(agent, "entries", entries, 0, realm);
        try object.defineBuiltinFunction(agent, "every", every, 1, realm);
        try object.defineBuiltinFunction(agent, "fill", fill, 1, realm);
        try object.defineBuiltinFunction(agent, "filter", filter, 1, realm);
        try object.defineBuiltinFunction(agent, "find", find, 1, realm);
        try object.defineBuiltinFunction(agent, "findIndex", findIndex, 1, realm);
        try object.defineBuiltinFunction(agent, "findLast", findLast, 1, realm);
        try object.defineBuiltinFunction(agent, "findLastIndex", findLastIndex, 1, realm);
        try object.defineBuiltinFunction(agent, "flat", flat, 0, realm);
        try object.defineBuiltinFunction(agent, "flatMap", flatMap, 1, realm);
        try object.defineBuiltinFunction(agent, "forEach", forEach, 1, realm);
        try object.defineBuiltinFunction(agent, "includes", includes, 1, realm);
        try object.defineBuiltinFunction(agent, "indexOf", indexOf, 1, realm);
        try object.defineBuiltinFunction(agent, "join", join, 1, realm);
        try object.defineBuiltinFunction(agent, "keys", keys, 0, realm);
        try object.defineBuiltinFunction(agent, "lastIndexOf", lastIndexOf, 1, realm);
        try object.defineBuiltinFunction(agent, "map", map, 1, realm);
        try object.defineBuiltinFunction(agent, "pop", pop, 0, realm);
        try object.defineBuiltinFunction(agent, "push", push, 1, realm);
        try object.defineBuiltinFunction(agent, "reduce", reduce, 1, realm);
        try object.defineBuiltinFunction(agent, "reduceRight", reduceRight, 1, realm);
        try object.defineBuiltinFunction(agent, "reverse", reverse, 0, realm);
        try object.defineBuiltinFunction(agent, "shift", shift, 0, realm);
        try object.defineBuiltinFunction(agent, "slice", slice, 2, realm);
        try object.defineBuiltinFunction(agent, "some", some, 1, realm);
        try object.defineBuiltinFunction(agent, "sort", sort, 1, realm);
        try object.defineBuiltinFunction(agent, "splice", splice, 2, realm);
        try object.defineBuiltinFunction(agent, "toLocaleString", toLocaleString, 0, realm);
        try object.defineBuiltinFunction(agent, "toReversed", toReversed, 0, realm);
        try object.defineBuiltinFunction(agent, "toSorted", toSorted, 1, realm);
        try object.defineBuiltinFunction(agent, "toSpliced", toSpliced, 2, realm);
        try object.defineBuiltinFunction(agent, "toString", toString, 0, realm);
        try object.defineBuiltinFunction(agent, "unshift", unshift, 1, realm);
        try object.defineBuiltinFunction(agent, "values", values, 0, realm);
        try object.defineBuiltinFunction(agent, "with", with, 2, realm);

        // 23.1.3.3 Array.prototype.constructor
        // https://tc39.es/ecma262/#sec-array.prototype.constructor
        try object.defineBuiltinProperty(
            agent,
            "constructor",
            Value.from(try realm.intrinsic(.array)),
        );

        // 23.1.3.40 Array.prototype [ %Symbol.iterator% ] ( )
        // https://tc39.es/ecma262/#sec-array.prototype-%symbol.iterator%
        // NOTE: We can't use the intrinsic getter for this while creating the underlying prototype
        //       object, as it hasn't been finalized yet.
        const array_prototype_values = object.getPropertyValueDirect(PropertyKey.from("values"));
        try object.defineBuiltinProperty(agent, "Symbol.iterator", array_prototype_values);

        // 23.1.3.41 Array.prototype [ %Symbol.unscopables% ]
        // https://tc39.es/ecma262/#sec-array.prototype-%symbol.unscopables%
        try object.defineBuiltinPropertyWithAttributes(
            agent,
            "Symbol.unscopables",
            blk: {
                // 1. Let unscopableList be OrdinaryObjectCreate(null).
                const unscopable_list = try ordinaryObjectCreate(agent, null);

                // 2. Perform ! CreateDataPropertyOrThrow(unscopableList, "at", true).
                // 3. Perform ! CreateDataPropertyOrThrow(unscopableList, "copyWithin", true).
                // 4. Perform ! CreateDataPropertyOrThrow(unscopableList, "entries", true).
                // 5. Perform ! CreateDataPropertyOrThrow(unscopableList, "fill", true).
                // 6. Perform ! CreateDataPropertyOrThrow(unscopableList, "find", true).
                // 7. Perform ! CreateDataPropertyOrThrow(unscopableList, "findIndex", true).
                // 8. Perform ! CreateDataPropertyOrThrow(unscopableList, "findLast", true).
                // 9. Perform ! CreateDataPropertyOrThrow(unscopableList, "findLastIndex", true).
                // 10. Perform ! CreateDataPropertyOrThrow(unscopableList, "flat", true).
                // 11. Perform ! CreateDataPropertyOrThrow(unscopableList, "flatMap", true).
                // 12. Perform ! CreateDataPropertyOrThrow(unscopableList, "includes", true).
                // 13. Perform ! CreateDataPropertyOrThrow(unscopableList, "keys", true).
                // 14. Perform ! CreateDataPropertyOrThrow(unscopableList, "toReversed", true).
                // 15. Perform ! CreateDataPropertyOrThrow(unscopableList, "toSorted", true).
                // 16. Perform ! CreateDataPropertyOrThrow(unscopableList, "toSpliced", true).
                // 17. Perform ! CreateDataPropertyOrThrow(unscopableList, "values", true).
                inline for (.{
                    "at",         "copyWithin",    "entries",   "fill",    "find",     "findIndex",
                    "findLast",   "findLastIndex", "flat",      "flatMap", "includes", "keys",
                    "toReversed", "toSorted",      "toSpliced", "values",
                }) |name| {
                    try unscopable_list.createDataPropertyDirect(
                        agent,
                        PropertyKey.from(name),
                        .true,
                    );
                }

                // 18. Return unscopableList.
                break :blk Value.from(unscopable_list);
            },
            .{
                .writable = false,
                .enumerable = false,
                .configurable = true,
            },
        );

        // Ensure property intrinsics are looked up right after the object is created
        _ = try realm.intrinsic(.array_prototype_to_string);
        _ = try realm.intrinsic(.array_prototype_values);
    }

    /// 23.1.3.1 Array.prototype.at ( index )
    /// https://tc39.es/ecma262/#sec-array.prototype.at
    fn at(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const index = arguments.get(0);
        // 1. Let obj be ? ToObject(this value).
        const obj = try this_value.toObject(agent);

        // 2. Let length be ? LengthOfArrayLike(obj).
        const length = try obj.lengthOfArrayLike(agent);

        // 3. Let k be ? ToAbsoluteIndex(index, length).
        const k_f64 = try index.toAbsoluteIndex(agent, length);

        // 4. If k < 0 or k ≥ length, return undefined.
        if (k_f64 < 0 or k_f64 >= @as(f64, @floatFromInt(length))) return .undefined;
        const k: u53 = @intFromFloat(k_f64);

        // 5. Return ? Get(obj, ! ToString(𝔽(k))).
        return obj.get(agent, PropertyKey.from(k));
    }

    /// 23.1.3.2 Array.prototype.concat ( ...items )
    /// https://tc39.es/ecma262/#sec-array.prototype.concat
    fn concat(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        // 1. Let obj be ? ToObject(this value).
        const obj = try this_value.toObject(agent);

        // 2. Let array be ? ArraySpeciesCreate(obj, 0).
        const array = try arraySpeciesCreate(agent, obj, 0);

        // 3. Let nextIndex be 0.
        var next_index: u53 = 0;

        // 4. Prepend obj to items.

        // 5. For each element item of items, do
        var index: u53 = 0;
        while (index <= arguments.count()) : (index += 1) {
            const item = if (index == 0)
                Value.from(obj)
            else
                arguments.values[@as(usize, @intCast(index)) - 1];

            // a. Let spreadable be ? IsConcatSpreadable(item).
            const spreadable = try isConcatSpreadable(agent, item);

            // b. If spreadable is true, then
            if (spreadable) {
                // i. Let length be ? LengthOfArrayLike(item).
                const length = try item.asObject().lengthOfArrayLike(agent);

                // ii. If nextIndex + length > 2**53 - 1, throw a TypeError exception.
                _ = std.math.add(u53, next_index, length) catch {
                    return agent.throwException(.type_error, "Maximum array length exceeded", .{});
                };

                // iii. Let sourceIndex be 0.
                var source_index: u53 = 0;

                // iv. Repeat, while sourceIndex < length,
                while (source_index < length) : ({
                    next_index += 1;
                    source_index += 1;
                }) {
                    // 1. Let propertyKey be ! ToString(𝔽(sourceIndex)).
                    const property_key = PropertyKey.from(source_index);

                    // 2. Let exists be ? HasProperty(item, propertyKey).
                    const exists = try item.asObject().hasProperty(agent, property_key);

                    // 3. If exists is true, then
                    if (exists) {
                        // a. Let subElement be ? Get(item, propertyKey).
                        const sub_element = try item.asObject().get(agent, property_key);

                        // b. Perform ? CreateDataPropertyOrThrow(array, ! ToString(𝔽(nextIndex)),
                        //    subElement).
                        try array.createDataPropertyOrThrow(
                            agent,
                            PropertyKey.from(next_index),
                            sub_element,
                        );
                    }

                    // 4. Set nextIndex to nextIndex + 1.
                    // 5. Set sourceIndex to sourceIndex + 1.
                }
            } else {
                // c. Else,
                // i. NOTE: item is added as a single item rather than spread.

                // ii. If nextIndex ≥ 2**53 - 1, throw a TypeError exception.
                if (next_index == std.math.maxInt(u53)) {
                    return agent.throwException(.type_error, "Maximum array length exceeded", .{});
                }

                // iii. Perform ? CreateDataPropertyOrThrow(array, ! ToString(𝔽(nextIndex)), item).
                try array.createDataPropertyOrThrow(agent, PropertyKey.from(next_index), item);

                // iv. Set nextIndex to nextIndex + 1.
                next_index += 1;
            }
        }

        // 6. Perform ? Set(array, "length", 𝔽(nextIndex), true).
        try array.set(agent, PropertyKey.from("length"), Value.from(next_index), .throw);

        // 7. Return array.
        return Value.from(array);
    }

    /// 23.1.3.2.1 IsConcatSpreadable ( obj )
    /// https://tc39.es/ecma262/#sec-isconcatspreadable
    fn isConcatSpreadable(agent: *Agent, obj: Value) Agent.Error!bool {
        // 1. If obj is not an Object, return false.
        if (!obj.isObject()) return false;

        // 2. Let spreadable be ? Get(obj, %Symbol.isConcatSpreadable%).
        const spreadable = try obj.asObject().get(
            agent,
            PropertyKey.from(agent.well_known_symbols.is_concat_spreadable),
        );

        // 3. If spreadable is not undefined, return ToBoolean(spreadable).
        if (!spreadable.isUndefined()) return spreadable.toBoolean();

        // 4. Return ? IsArray(obj).
        return obj.isArray(agent);
    }

    /// 23.1.3.4 Array.prototype.copyWithin ( target, start [ , end ] )
    /// https://tc39.es/ecma262/#sec-array.prototype.copywithin
    fn copyWithin(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const target = arguments.get(0);
        const start = arguments.get(1);
        const end = arguments.get(2);

        // 1. Let obj be ? ToObject(this value).
        const obj = try this_value.toObject(agent);

        // 2. Let length be ? LengthOfArrayLike(obj).
        const length = try obj.lengthOfArrayLike(agent);

        // 3. Let to be ? ToClampedIndex(target, length).
        var to = try target.toClampedIndex(agent, length);

        // 4. Let from be ? ToClampedIndex(start, length).
        var from = try start.toClampedIndex(agent, length);

        // 5. If end is undefined, let final be length; else let final be ? ToClampedIndex(end,
        //    length).
        const final = if (end.isUndefined())
            length
        else
            try end.toClampedIndex(agent, length);

        // 6. Let count be min(final - from, length - to).
        var count = @min(final -| from, length -| to);

        // 7. If from < to and to < from + count, then
        const direction: i2 = if (from < to and to < (from + count)) blk: {
            // b. Set from to from + count - 1.
            from = from + count - 1;

            // c. Set to to to + count - 1.
            to = to + count - 1;

            // a. Let direction be -1.
            break :blk -1;
        } else blk: {
            // 8. Else,
            // a. Let direction be 1.
            break :blk 1;
        };

        // 9. Repeat, while count > 0,
        while (count > 0) : ({
            if (direction == 1) from += 1 else from -|= 1;
            if (direction == 1) to += 1 else to -|= 1;
            count -= 1;
        }) {
            // a. Let fromKey be ! ToString(𝔽(from)).
            const from_key = PropertyKey.from(from);

            // b. Let toKey be ! ToString(𝔽(to)).
            const to_key = PropertyKey.from(to);

            // c. Let fromPresent be ? HasProperty(obj, fromKey).
            const from_present = try obj.hasProperty(agent, from_key);

            // d. If fromPresent is true, then
            if (from_present) {
                // i. Let fromValue be ? Get(obj, fromKey).
                const from_value = try obj.get(agent, from_key);

                // ii. Perform ? Set(obj, toKey, fromValue, true).
                try obj.set(agent, to_key, from_value, .throw);
            } else {
                // e. Else,
                // i. Assert: fromPresent is false.
                std.debug.assert(!from_present);

                // ii. Perform ? DeletePropertyOrThrow(obj, toKey).
                try obj.deletePropertyOrThrow(agent, to_key);
            }

            // f. Set from to from + direction.
            // g. Set to to to + direction.
            // h. Set count to count - 1.
        }

        // 10. Return obj.
        return Value.from(obj);
    }

    /// 23.1.3.5 Array.prototype.entries ( )
    /// https://tc39.es/ecma262/#sec-array.prototype.entries
    fn entries(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let obj be ? ToObject(this value).
        const obj = try this_value.toObject(agent);

        // 2. Return CreateArrayIterator(obj, key+value).
        const array_iterator = try createArrayIterator(agent, obj, .key_value);
        return Value.from(&array_iterator.object);
    }

    /// 23.1.3.6 Array.prototype.every ( callback [ , thisArg ] )
    /// https://tc39.es/ecma262/#sec-array.prototype.every
    fn every(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const callback_value = arguments.get(0);
        const this_arg = arguments.get(1);

        // 1. Let obj be ? ToObject(this value).
        const obj = try this_value.toObject(agent);

        // 2. Let length be ? LengthOfArrayLike(obj).
        const length = try obj.lengthOfArrayLike(agent);

        // 3. If IsCallable(callback) is false, throw a TypeError exception.
        if (!callback_value.isCallable()) {
            return agent.throwException(.type_error, "{f} is not callable", .{callback_value});
        }
        const callback = callback_value.asObject();

        // 4. Let k be 0.
        var k: u53 = 0;

        // OPTIMIZATION: Use fast path if applicable
        if (try array_fast_paths.every(
            agent,
            obj,
            length,
            callback,
            this_arg,
        )) |result| switch (result) {
            .done => |value| return Value.from(value),
            .continue_slow => |index| k = @intCast(index),
        };

        // 5. Repeat, while k < length,
        while (k < length) : (k += 1) {
            // a. Let propertyKey be ! ToString(𝔽(k)).
            const property_key = PropertyKey.from(k);

            // b. Let kPresent be ? HasProperty(obj, propertyKey).
            const k_present = try obj.hasProperty(agent, property_key);

            // c. If kPresent is true, then
            if (k_present) {
                // i. Let kValue be ? Get(obj, propertyKey).
                const k_value = try obj.get(agent, property_key);

                // ii. Let testResult be ToBoolean(? Call(callback, thisArg, « kValue, 𝔽(k),
                //     obj »)).
                const test_result = (try callback.call(
                    agent,
                    this_arg,
                    &.{ k_value, Value.from(k), Value.from(obj) },
                )).toBoolean();

                // iii. If testResult is false, return false.
                if (!test_result) return .false;
            }

            // d. Set k to k + 1.
        }

        // 6. Return true.
        return .true;
    }

    /// 23.1.3.7 Array.prototype.fill ( value [ , start [ , end ] ] )
    /// https://tc39.es/ecma262/#sec-array.prototype.fill
    fn fill(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const value = arguments.get(0);
        const start = arguments.get(1);
        const end = arguments.get(2);

        // 1. Let obj be ? ToObject(this value).
        const obj = try this_value.toObject(agent);

        // 2. Let length be ? LengthOfArrayLike(obj).
        const length = try obj.lengthOfArrayLike(agent);

        // 3. Let k be ? ToClampedIndex(start, length).
        var k = try start.toClampedIndex(agent, length);

        // 4. If end is undefined, let final be length; else let final be ? ToClampedIndex(end,
        //    length).
        const final = if (end.isUndefined())
            length
        else
            try end.toClampedIndex(agent, length);

        // OPTIMIZATION: Use fast path if applicable
        if (try array_fast_paths.fill(
            agent.gc_allocator,
            obj,
            length,
            k,
            final,
            value,
        )) |_| {
            return Value.from(obj);
        }

        // 5. Repeat, while k < final,
        while (k < final) : (k += 1) {
            // a. Let propertyKey be ! ToString(𝔽(k)).
            const property_key = PropertyKey.from(k);

            // b. Perform ? Set(obj, propertyKey, value, true).
            try obj.set(agent, property_key, value, .throw);

            // c. Set k to k + 1.
        }

        // 6. Return obj.
        return Value.from(obj);
    }

    /// 23.1.3.8 Array.prototype.filter ( callback [ , thisArg ] )
    /// https://tc39.es/ecma262/#sec-array.prototype.filter
    fn filter(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const callback_value = arguments.get(0);
        const this_arg = arguments.get(1);

        // 1. Let obj be ? ToObject(this value).
        const obj = try this_value.toObject(agent);

        // 2. Let length be ? LengthOfArrayLike(obj).
        const length = try obj.lengthOfArrayLike(agent);

        // 3. If IsCallable(callback) is false, throw a TypeError exception.
        if (!callback_value.isCallable()) {
            return agent.throwException(.type_error, "{f} is not callable", .{callback_value});
        }
        const callback = callback_value.asObject();

        // 4. Let array be ? ArraySpeciesCreate(obj, 0).
        const array = try arraySpeciesCreate(agent, obj, 0);

        // 5. Let k be 0.
        var k: u53 = 0;

        // 6. Let to be 0.
        var to: u53 = 0;

        // 7. Repeat, while k < length,
        while (k < length) : (k += 1) {
            // a. Let propertyKey be ! ToString(𝔽(k)).
            const property_key = PropertyKey.from(k);

            // b. Let kPresent be ? HasProperty(obj, propertyKey).
            const k_present = try obj.hasProperty(agent, property_key);

            // c. If kPresent is true, then
            if (k_present) {
                // i. Let kValue be ? Get(obj, propertyKey).
                const k_value = try obj.get(agent, property_key);

                // ii. Let selected be ToBoolean(? Call(callback, thisArg, « kValue, 𝔽(k), obj »)).
                const selected = (try callback.call(
                    agent,
                    this_arg,
                    &.{ k_value, Value.from(k), Value.from(obj) },
                )).toBoolean();

                // iii. If selected is true, then
                if (selected) {
                    // 1. Perform ? CreateDataPropertyOrThrow(array, ! ToString(𝔽(to)), kValue).
                    try array.createDataPropertyOrThrow(agent, PropertyKey.from(to), k_value);

                    // 2. Set to to to + 1.
                    to += 1;
                }
            }

            // d. Set k to k + 1.
        }

        // 8. Return array.
        return Value.from(array);
    }

    /// 23.1.3.9 Array.prototype.find ( predicate [ , thisArg ] )
    /// https://tc39.es/ecma262/#sec-array.prototype.find
    fn find(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const predicate = arguments.get(0);
        const this_arg = arguments.get(1);

        // 1. Let obj be ? ToObject(this value).
        const obj = try this_value.toObject(agent);

        // 2. Let length be ? LengthOfArrayLike(obj).
        const length = try obj.lengthOfArrayLike(agent);

        // 3. Let findRecord be ? FindViaPredicate(obj, length, ascending, predicate, thisArg).
        const find_record = try findViaPredicate(
            agent,
            obj,
            length,
            .ascending,
            predicate,
            this_arg,
        );

        // 4. Return findRecord.[[Value]].
        return find_record.value;
    }

    /// 23.1.3.10 Array.prototype.findIndex ( predicate [ , thisArg ] )
    /// https://tc39.es/ecma262/#sec-array.prototype.findindex
    fn findIndex(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const predicate = arguments.get(0);
        const this_arg = arguments.get(1);

        // 1. Let obj be ? ToObject(this value).
        const obj = try this_value.toObject(agent);

        // 2. Let length be ? LengthOfArrayLike(obj).
        const length = try obj.lengthOfArrayLike(agent);

        // 3. Let findRecord be ? FindViaPredicate(obj, length, ascending, predicate, thisArg).
        const find_record = try findViaPredicate(
            agent,
            obj,
            length,
            .ascending,
            predicate,
            this_arg,
        );

        // 4. Return findRecord.[[Index]].
        return find_record.index;
    }

    /// 23.1.3.11 Array.prototype.findLast ( predicate [ , thisArg ] )
    /// https://tc39.es/ecma262/#sec-array.prototype.findlast
    fn findLast(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const predicate = arguments.get(0);
        const this_arg = arguments.get(1);

        // 1. Let obj be ? ToObject(this value).
        const obj = try this_value.toObject(agent);

        // 2. Let length be ? LengthOfArrayLike(obj).
        const length = try obj.lengthOfArrayLike(agent);

        // 3. Let findRecord be ? FindViaPredicate(obj, length, descending, predicate, thisArg).
        const find_record = try findViaPredicate(
            agent,
            obj,
            length,
            .descending,
            predicate,
            this_arg,
        );

        // 4. Return findRecord.[[Value]].
        return find_record.value;
    }

    /// 23.1.3.12 Array.prototype.findLastIndex ( predicate [ , thisArg ] )
    /// https://tc39.es/ecma262/#sec-array.prototype.findlastindex
    fn findLastIndex(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const predicate = arguments.get(0);
        const this_arg = arguments.get(1);

        // 1. Let obj be ? ToObject(this value).
        const obj = try this_value.toObject(agent);

        // 2. Let length be ? LengthOfArrayLike(obj).
        const length = try obj.lengthOfArrayLike(agent);

        // 3. Let findRecord be ? FindViaPredicate(obj, length, descending, predicate, thisArg).
        const find_record = try findViaPredicate(
            agent,
            obj,
            length,
            .descending,
            predicate,
            this_arg,
        );

        // 4. Return findRecord.[[Index]].
        return find_record.index;
    }
    /// 23.1.3.13 Array.prototype.flat ( [ depth ] )
    /// https://tc39.es/ecma262/#sec-array.prototype.flat
    fn flat(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const depth = arguments.get(0);

        // 1. Let obj be ? ToObject(this value).
        const obj = try this_value.toObject(agent);

        // 2. Let sourceLength be ? LengthOfArrayLike(obj).
        const source_length = try obj.lengthOfArrayLike(agent);

        // 3. Let depthNumber be 1.
        var depth_number: f64 = 1;

        // 4. If depth is not undefined, then
        if (!depth.isUndefined()) {
            // a. Set depthNumber to ? ToIntegerOrInfinity(depth).
            depth_number = try depth.toIntegerOrInfinity(agent);

            // b. If depthNumber < 0, set depthNumber to 0.
            if (depth_number < 0) depth_number = 0;
        }

        // 5. Let array be ? ArraySpeciesCreate(obj, 0).
        const array = try arraySpeciesCreate(agent, obj, 0);

        // 6. Perform ? FlattenIntoArray(array, obj, sourceLength, 0, depthNumber).
        _ = try flattenIntoArray(agent, array, obj, source_length, 0, depth_number, null, null);

        // 7. Return array.
        return Value.from(array);
    }

    /// 23.1.3.13.1 FlattenIntoArray ( target, source, sourceLength, start, depth [ , mapperFunc [ , thisArg ] ] )
    /// https://tc39.es/ecma262/#sec-flattenintoarray
    fn flattenIntoArray(
        agent: *Agent,
        target: *Object,
        source: *Object,
        source_length: u53,
        start: f64,
        depth: f64,
        maybe_mapper_func: ?*Object,
        this_arg: ?Value,
    ) Agent.Error!f64 {
        // 1. Assert: If mapperFunc is present, then IsCallable(mapperFunc) is true, thisArg is
        //    present, and depth is 1.
        if (maybe_mapper_func) |mapper_func| {
            std.debug.assert(mapper_func.internalMethods().call != null);
            std.debug.assert(this_arg != null);
            std.debug.assert(depth == 1);
        }

        // 2. Let targetIndex be start.
        var target_index = start;

        // 3. Let sourceIndex be 0.
        var source_index: u53 = 0;

        // 4. Repeat, while sourceIndex < sourceLength,
        while (source_index < source_length) : (source_index += 1) {
            // a. Let propertyKey be ! ToString(𝔽(sourceIndex)).
            const property_key = PropertyKey.from(source_index);

            // b. Let exists be ? HasProperty(source, propertyKey).
            const exists = try source.hasProperty(agent, property_key);

            // c. If exists is true, then
            if (exists) {
                // i. Let element be ? Get(source, propertyKey).
                var element = try source.get(agent, property_key);

                // ii. If mapperFunc is present, then
                if (maybe_mapper_func) |mapper_func| {
                    // 1. Set element to ? Call(mapperFunc, thisArg, « element, 𝔽(sourceIndex),
                    //    source »).
                    element = try mapper_func.call(
                        agent,
                        this_arg.?,
                        &.{ element, Value.from(source_index), Value.from(source) },
                    );
                }

                // iii. Let shouldFlatten be false.
                var should_flatten = false;

                // iv. If depth > 0, then
                if (depth > 0) {
                    // 1. Set shouldFlatten to ? IsArray(element).
                    should_flatten = try element.isArray(agent);
                }

                // v. If shouldFlatten is true, then
                if (should_flatten) {
                    // 1. If depth = +∞, let newDepth be +∞.
                    // 2. Else, let newDepth be depth - 1.
                    const new_depth = if (std.math.isPositiveInf(depth))
                        std.math.inf(f64)
                    else
                        depth - 1;

                    // 3. Let elementLength be ? LengthOfArrayLike(element).
                    const element_length = try element.asObject().lengthOfArrayLike(agent);

                    // NOTE: flattenIntoArray() is being called recursively here.
                    if (agent.platform.checkStackOverflow()) {
                        return agent.throwException(.internal_error, "Stack overflow", .{});
                    }

                    // 4. Set targetIndex to ? FlattenIntoArray(target, element, elementLength,
                    //    targetIndex, newDepth).
                    target_index = try flattenIntoArray(
                        agent,
                        target,
                        element.asObject(),
                        element_length,
                        target_index,
                        new_depth,
                        null,
                        null,
                    );
                } else {
                    // vi. Else,
                    // 1. If targetIndex ≥ 2**53 - 1, throw a TypeError exception.
                    if (target_index >= std.math.maxInt(u53)) {
                        return agent.throwException(.type_error, "Maximum array length exceeded", .{});
                    }

                    // 2. Perform ? CreateDataPropertyOrThrow(target, ! ToString(𝔽(targetIndex)),
                    //    element).
                    try target.createDataPropertyOrThrow(
                        agent,
                        PropertyKey.from(@as(PropertyKey.IntegerIndex, @intFromFloat(target_index))),
                        element,
                    );

                    // 3. Set targetIndex to targetIndex + 1.
                    target_index += 1;
                }
            }

            // d. Set sourceIndex to sourceIndex + 1.
        }

        // 5. Return targetIndex.
        return target_index;
    }

    /// 23.1.3.14 Array.prototype.flatMap ( mapperFunc [ , thisArg ] )
    /// https://tc39.es/ecma262/#sec-array.prototype.flatmap
    fn flatMap(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const mapper_func = arguments.get(0);
        const this_arg = arguments.get(1);

        // 1. Let obj be ? ToObject(this value).
        const obj = try this_value.toObject(agent);

        // 2. Let sourceLength be ? LengthOfArrayLike(obj).
        const source_length = try obj.lengthOfArrayLike(agent);

        // 3. If IsCallable(mapperFunc) is false, throw a TypeError exception.
        if (!mapper_func.isCallable()) {
            return agent.throwException(.type_error, "{f} is not callable", .{mapper_func});
        }

        // 4. Let array be ? ArraySpeciesCreate(obj, 0).
        const array = try arraySpeciesCreate(agent, obj, 0);

        // 5. Perform ? FlattenIntoArray(array, obj, sourceLength, 0, 1, mapperFunc, thisArg).
        _ = try flattenIntoArray(
            agent,
            array,
            obj,
            source_length,
            0,
            1,
            mapper_func.asObject(),
            this_arg,
        );

        // 6. Return array.
        return Value.from(array);
    }

    /// 23.1.3.15 Array.prototype.forEach ( callback [ , thisArg ] )
    /// https://tc39.es/ecma262/#sec-array.prototype.foreach
    fn forEach(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const callback_value = arguments.get(0);
        const this_arg = arguments.get(1);

        // 1. Let obj be ? ToObject(this value).
        const obj = try this_value.toObject(agent);

        // 2. Let length be ? LengthOfArrayLike(obj).
        const length = try obj.lengthOfArrayLike(agent);

        // 3. If IsCallable(callback) is false, throw a TypeError exception.
        if (!callback_value.isCallable()) {
            return agent.throwException(.type_error, "{f} is not callable", .{callback_value});
        }
        const callback = callback_value.asObject();

        // 4. Let k be 0.
        var k: u53 = 0;

        // OPTIMIZATION: Use fast path if applicable
        if (try array_fast_paths.forEach(
            agent,
            obj,
            length,
            callback,
            this_arg,
        )) |result| switch (result) {
            .done => return .undefined,
            .continue_slow => |index| k = @intCast(index),
        };

        // 5. Repeat, while k < length,
        while (k < length) : (k += 1) {
            // a. Let propertyKey be ! ToString(𝔽(k)).
            const property_key = PropertyKey.from(k);

            // b. Let kPresent be ? HasProperty(obj, propertyKey).
            const k_present = try obj.hasProperty(agent, property_key);

            // c. If kPresent is true, then
            if (k_present) {
                // i. Let kValue be ? Get(obj, propertyKey).
                const k_value = try obj.get(agent, property_key);

                // ii. Perform ? Call(callback, thisArg, « kValue, 𝔽(k), obj »).
                _ = try callback.call(
                    agent,
                    this_arg,
                    &.{ k_value, Value.from(k), Value.from(obj) },
                );
            }

            // d. Set k to k + 1.
        }

        // 6. Return undefined.
        return .undefined;
    }

    /// 23.1.3.16 Array.prototype.includes ( searchElement [ , fromIndex ] )
    /// https://tc39.es/ecma262/#sec-array.prototype.includes
    fn includes(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const search_element = arguments.get(0);
        const from_index = arguments.get(1);

        // 1. Let obj be ? ToObject(this value).
        const obj = try this_value.toObject(agent);

        // 2. Let length be ? LengthOfArrayLike(obj).
        const length = try obj.lengthOfArrayLike(agent);

        // 3. If length = 0, return false.
        if (length == 0) return .false;

        // 4. Let k be ? ToClampedIndex(fromIndex, length).
        var k = try from_index.toClampedIndex(agent, length);

        // OPTIMIZATION: Use fast path if applicable
        if (array_fast_paths.includes(obj, length, k, search_element)) |result| {
            return Value.from(result);
        }

        // 5. Repeat, while k < length,
        while (k < length) : (k += 1) {
            // a. Let elementK be ? Get(obj, ! ToString(𝔽(k))).
            const element_k = try obj.get(agent, PropertyKey.from(k));

            // b. If SameValueZero(searchElement, elementK) is true, return true.
            if (sameValueZero(search_element, element_k)) return .true;

            // c. Set k to k + 1.
        }

        // 6. Return false.
        return .false;
    }

    /// 23.1.3.17 Array.prototype.indexOf ( searchElement [ , fromIndex ] )
    /// https://tc39.es/ecma262/#sec-array.prototype.indexof
    fn indexOf(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const search_element = arguments.get(0);
        const from_index = arguments.get(1);

        // 1. Let obj be ? ToObject(this value).
        const obj = try this_value.toObject(agent);

        // 2. Let length be ? LengthOfArrayLike(obj).
        const length = try obj.lengthOfArrayLike(agent);

        // 3. If length = 0, return -1𝔽.
        if (length == 0) return Value.from(-1);

        // 4. Let k be ? ToClampedIndex(fromIndex, length).
        var k = try from_index.toClampedIndex(agent, length);

        // OPTIMIZATION: Use fast path if applicable
        if (array_fast_paths.indexOf(obj, length, k, search_element)) |result| {
            return result;
        }

        // 5. Repeat, while k < length,
        while (k < length) : (k += 1) {
            // a. Let propertyKey be ! ToString(𝔽(k)).
            const property_key = PropertyKey.from(k);

            // b. Let kPresent be ? HasProperty(obj, propertyKey).
            const k_present = try obj.hasProperty(agent, property_key);

            // c. If kPresent is true, then
            if (k_present) {
                // i. Let elementK be ? Get(obj, propertyKey).
                const element_k = try obj.get(agent, property_key);

                // ii. If IsStrictlyEqual(searchElement, elementK) is true, return 𝔽(k).
                if (isStrictlyEqual(search_element, element_k)) return Value.from(k);
            }

            // d. Set k to k + 1.
        }

        // 6. Return -1𝔽.
        return Value.from(-1);
    }

    /// 23.1.3.18 Array.prototype.join ( separator )
    /// https://tc39.es/ecma262/#sec-array.prototype.join
    fn join(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const separator = arguments.get(0);

        // 1. Let obj be ? ToObject(this value).
        const obj = try this_value.toObject(agent);

        // 2. Let length be ? LengthOfArrayLike(obj).
        const length = try obj.lengthOfArrayLike(agent);

        // 3. If separator is undefined, let separatorString be ",".
        // 4. Else, let separatorString be ? ToString(separator).
        const separator_string: String.Builder.Segment = if (separator.isUndefined())
            .{ .char = ',' }
        else
            .{ .string = try separator.toString(agent) };

        // OPTIMIZATION: If the array is empty the result will be an empty string
        if (length == 0) return Value.from(String.empty);

        // 5. Let result be the empty String.
        // NOTE: This allocates the maximum needed capacity upfront
        const capacity = std.math.cast(u32, @as(u64, length) * 2 - 1) orelse
            return error.OutOfMemory;
        var result = try String.Builder.initCapacity(agent.gc_allocator, capacity);
        defer result.deinit(agent.gc_allocator);

        // 6. Let k be 0.
        var k: u53 = 0;

        // 7. Repeat, while k < length,
        while (k < length) : (k += 1) {
            // a. If k > 0, set result to the string-concatenation of result and separatorString.
            if (k > 0) result.appendSegmentAssumeCapacity(separator_string);

            // b. Let element be ? Get(obj, ! ToString(𝔽(k))).
            const element = try obj.get(agent, PropertyKey.from(k));

            // c. If element is neither undefined nor null, then
            if (!element.isUndefined() and !element.isNull()) {
                // i. Let elementString be ? ToString(element).
                const element_string = try element.toString(agent);

                // ii. Set result to the string-concatenation of result and elementString.
                result.appendStringAssumeCapacity(element_string);
            }

            // d. Set k to k + 1.
        }

        // 8. Return result.
        return Value.from(try result.build(agent));
    }

    /// 23.1.3.19 Array.prototype.keys ( )
    /// https://tc39.es/ecma262/#sec-array.prototype.keys
    fn keys(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let obj be ? ToObject(this value).
        const obj = try this_value.toObject(agent);

        // 2. Return CreateArrayIterator(obj, key).
        const array_iterator = try createArrayIterator(agent, obj, .key);
        return Value.from(&array_iterator.object);
    }

    /// 23.1.3.20 Array.prototype.lastIndexOf ( searchElement [ , fromIndex ] )
    /// https://tc39.es/ecma262/#sec-array.prototype.lastindexof
    fn lastIndexOf(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const search_element = arguments.get(0);
        const from_index = arguments.get(1);

        // 1. Let obj be ? ToObject(this value).
        const obj = try this_value.toObject(agent);

        // 2. Let length be ? LengthOfArrayLike(obj).
        const length = try obj.lengthOfArrayLike(agent);

        // 3. If length = 0, return -1𝔽.
        if (length == 0) return Value.from(-1);

        // 4. If fromIndex is not present, let k be length - 1; else let k be min(? ToAbsoluteIndex(
        //    fromIndex, length), length - 1).
        var k = if (arguments.count() <= 1)
            length - 1
        else blk: {
            const absolute = try from_index.toAbsoluteIndex(agent, length);
            if (absolute < 0) return Value.from(-1);
            break :blk @as(u53, @intFromFloat(@min(absolute, @as(f64, @floatFromInt(length - 1)))));
        };

        // OPTIMIZATION: Use fast path if applicable
        if (array_fast_paths.lastIndexOf(obj, length, k, search_element)) |result| {
            return result;
        }

        // 5. Repeat, while k ≥ 0,
        while (k >= 0) : (k -|= 1) {
            // a. Let propertyKey be ! ToString(𝔽(k)).
            const property_key = PropertyKey.from(k);

            // b. Let kPresent be ? HasProperty(obj, propertyKey).
            const k_present = try obj.hasProperty(agent, property_key);

            // c. If kPresent is true, then
            if (k_present) {
                // i. Let elementK be ? Get(obj, propertyKey).
                const element_k = try obj.get(agent, property_key);

                // ii. If IsStrictlyEqual(searchElement, elementK) is true, return 𝔽(k).
                if (isStrictlyEqual(search_element, element_k)) return Value.from(k);
            }

            // d. Set k to k - 1.
            if (k == 0) break;
        }

        // 6. Return -1𝔽.
        return Value.from(-1);
    }

    /// 23.1.3.21 Array.prototype.map ( callback [ , thisArg ] )
    /// https://tc39.es/ecma262/#sec-array.prototype.map
    fn map(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const callback_value = arguments.get(0);
        const this_arg = arguments.get(1);

        // 1. Let obj be ? ToObject(this value).
        const obj = try this_value.toObject(agent);

        // 2. Let length be ? LengthOfArrayLike(obj).
        const length = try obj.lengthOfArrayLike(agent);

        // 3. If IsCallable(callback) is false, throw a TypeError exception.
        if (!callback_value.isCallable()) {
            return agent.throwException(.type_error, "{f} is not callable", .{callback_value});
        }
        const callback = callback_value.asObject();

        // 4. Let array be ? ArraySpeciesCreate(obj, length).
        const array = try arraySpeciesCreate(agent, obj, length);

        // 5. Let k be 0.
        var k: u53 = 0;

        // 6. Repeat, while k < length,
        while (k < length) : (k += 1) {
            // a. Let propertyKey be ! ToString(𝔽(k)).
            const property_key = PropertyKey.from(k);

            // b. Let kPresent be ? HasProperty(obj, propertyKey).
            const k_present = try obj.hasProperty(agent, property_key);

            // c. If kPresent is true, then
            if (k_present) {
                // i. Let kValue be ? Get(obj, propertyKey).
                const k_value = try obj.get(agent, property_key);

                // ii. Let mappedValue be ? Call(callback, thisArg, « kValue, 𝔽(k), obj »).
                const mapped_value = try callback.call(
                    agent,
                    this_arg,
                    &.{ k_value, Value.from(k), Value.from(obj) },
                );

                // iii. Perform ? CreateDataPropertyOrThrow(array, propertyKey, mappedValue).
                try array.createDataPropertyOrThrow(agent, property_key, mapped_value);
            }

            // d. Set k to k + 1.
        }

        // 7. Return array.
        return Value.from(array);
    }

    /// 23.1.3.22 Array.prototype.pop ( )
    /// https://tc39.es/ecma262/#sec-array.prototype.pop
    fn pop(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let obj be ? ToObject(this value).
        const obj = try this_value.toObject(agent);

        // 2. Let length be ? LengthOfArrayLike(obj).
        const length = try obj.lengthOfArrayLike(agent);

        // OPTIMIZATION: Use fast path if applicable
        if (try array_fast_paths.pop(agent, obj, length)) |result| {
            return result;
        }

        // 3. If length = 0, then
        if (length == 0) {
            // a. Perform ? Set(obj, "length", +0𝔽, true).
            try obj.set(agent, PropertyKey.from("length"), Value.from(0), .throw);

            // b. Return undefined.
            return .undefined;
        }

        // 4. Assert: length > 0.
        std.debug.assert(length > 0);

        // 5. Let newLength be 𝔽(length - 1).
        const new_length = length - 1;

        // 6. Let index be ! ToString(newLength).
        const index = PropertyKey.from(new_length);

        // 7. Let element be ? Get(obj, index).
        const element = try obj.get(agent, index);

        // 8. Perform ? DeletePropertyOrThrow(obj, index).
        try obj.deletePropertyOrThrow(agent, index);

        // 9. Perform ? Set(obj, "length", newLength, true).
        try obj.set(agent, PropertyKey.from("length"), Value.from(new_length), .throw);

        // 10. Return element.
        return element;
    }

    /// 23.1.3.23 Array.prototype.push ( ...items )
    /// https://tc39.es/ecma262/#sec-array.prototype.push
    fn push(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        // 1. Let obj be ? ToObject(this value).
        const obj = try this_value.toObject(agent);

        // 2. Let length be ? LengthOfArrayLike(obj).
        var length = try obj.lengthOfArrayLike(agent);

        // 3. Let argCount be the number of elements in items.
        const arg_count: u53 = @intCast(arguments.count());

        // 4. If length + argCount > 2**53 - 1, throw a TypeError exception.
        _ = std.math.add(u53, length, arg_count) catch {
            return agent.throwException(.type_error, "Maximum array length exceeded", .{});
        };

        // OPTIMIZATION: Use fast path if applicable
        if (try array_fast_paths.push(agent, obj, length, arguments.values)) |result| {
            return result;
        }

        // 5. For each element item of items, do
        for (arguments.values) |item| {
            // a. Perform ? Set(obj, ! ToString(𝔽(length)), item, true).
            try obj.set(agent, PropertyKey.from(length), item, .throw);

            // b. Set length to length + 1.
            length += 1;
        }

        // 6. Perform ? Set(obj, "length", 𝔽(length), true).
        try obj.set(agent, PropertyKey.from("length"), Value.from(length), .throw);

        // 7. Return 𝔽(length).
        return Value.from(length);
    }

    /// 23.1.3.24 Array.prototype.reduce ( callback [ , initialValue ] )
    /// https://tc39.es/ecma262/#sec-array.prototype.reduce
    fn reduce(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const callback_value = arguments.get(0);
        const initial_value = arguments.getOrNull(1);

        // 1. Let obj be ? ToObject(this value).
        const obj = try this_value.toObject(agent);

        // 2. Let length be ? LengthOfArrayLike(obj).
        const length = try obj.lengthOfArrayLike(agent);

        // 3. If IsCallable(callback) is false, throw a TypeError exception.
        if (!callback_value.isCallable()) {
            return agent.throwException(.type_error, "{f} is not callable", .{callback_value});
        }
        const callback = callback_value.asObject();

        // 4. If length = 0 and initialValue is not present, throw a TypeError exception.
        if (length == 0 and initial_value == null) {
            return agent.throwException(
                .type_error,
                "Cannot reduce empty array without initial value",
                .{},
            );
        }

        // 5. Let k be 0.
        var k: u53 = 0;

        // 6. Let accumulator be undefined.
        var accumulator: Value = undefined;

        // 7. If initialValue is present, then
        if (initial_value != null) {
            // a. Set accumulator to initialValue.
            accumulator = initial_value.?;
        } else {
            // 8. Else,
            // a. Let kPresent be false.
            var k_present = false;

            // b. Repeat, while kPresent is false and k < length,
            while (!k_present and k < length) : (k += 1) {
                // i. Let propertyKey be ! ToString(𝔽(k)).
                const property_key = PropertyKey.from(k);

                // ii. Set kPresent to ? HasProperty(obj, propertyKey).
                k_present = try obj.hasProperty(agent, property_key);

                // iii. If kPresent is true, then
                if (k_present) {
                    // 1. Set accumulator to ? Get(obj, propertyKey).
                    accumulator = try obj.get(agent, property_key);
                }

                // iv. Set k to k + 1.
            }

            // c. If kPresent is false, throw a TypeError exception.
            if (!k_present) {
                return agent.throwException(
                    .type_error,
                    "Cannot reduce empty array without initial value",
                    .{},
                );
            }
        }

        // 9. Repeat, while k < length,
        while (k < length) : (k += 1) {
            // a. Let propertyKey be ! ToString(𝔽(k)).
            const property_key = PropertyKey.from(k);

            // b. Let kPresent be ? HasProperty(obj, propertyKey).
            const k_present = try obj.hasProperty(agent, property_key);

            // c. If kPresent is true, then
            if (k_present) {
                // i. Let kValue be ? Get(obj, propertyKey).
                const k_value = try obj.get(agent, property_key);

                // ii. Set accumulator to ? Call(callback, undefined, « accumulator, kValue, 𝔽(k),
                //     obj »).
                accumulator = try callback.call(
                    agent,
                    .undefined,
                    &.{ accumulator, k_value, Value.from(k), Value.from(obj) },
                );
            }

            // d. Set k to k + 1.
        }

        // 10. Return accumulator.
        return accumulator;
    }

    /// 23.1.3.25 Array.prototype.reduceRight ( callback [ , initialValue ] )
    /// https://tc39.es/ecma262/#sec-array.prototype.reduceright
    fn reduceRight(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const callback_value = arguments.get(0);
        const initial_value = arguments.getOrNull(1);

        // 1. Let obj be ? ToObject(this value).
        const obj = try this_value.toObject(agent);

        // 2. Let length be ? LengthOfArrayLike(obj).
        const length = try obj.lengthOfArrayLike(agent);

        // 3. If IsCallable(callback) is false, throw a TypeError exception.
        if (!callback_value.isCallable()) {
            return agent.throwException(.type_error, "{f} is not callable", .{callback_value});
        }
        const callback = callback_value.asObject();

        // 4. If length = 0 and initialValue is not present, throw a TypeError exception.
        if (length == 0 and initial_value == null) {
            return agent.throwException(
                .type_error,
                "Cannot reduce empty array without initial value",
                .{},
            );
        }

        // 5. Let k be length - 1.
        var k: ?u53 = std.math.sub(u53, length, 1) catch null;

        // 6. Let accumulator be undefined.
        var accumulator: Value = undefined;

        // 7. If initialValue is present, then
        if (initial_value != null) {
            // a. Set accumulator to initialValue.
            accumulator = initial_value.?;
        } else {
            // 8. Else,
            // a. Let kPresent be false.
            var k_present = false;

            // b. Repeat, while kPresent is false and k ≥ 0,
            while (!k_present and k != null) : (k = (std.math.sub(u53, k.?, 1) catch null)) {
                // i. Let propertyKey be ! ToString(𝔽(k)).
                const property_key = PropertyKey.from(k.?);

                // ii. Set kPresent to ? HasProperty(obj, propertyKey).
                k_present = try obj.hasProperty(agent, property_key);

                // iii. If kPresent is true, then
                if (k_present) {
                    // 1. Set accumulator to ? Get(obj, propertyKey).
                    accumulator = try obj.get(agent, property_key);
                }

                // iv. Set k to k - 1.
            }

            // c. If kPresent is false, throw a TypeError exception.
            if (!k_present) {
                return agent.throwException(
                    .type_error,
                    "Cannot reduce empty array without initial value",
                    .{},
                );
            }
        }

        // 9. Repeat, while k ≥ 0,
        while (k != null) : (k = (std.math.sub(u53, k.?, 1) catch null)) {
            // a. Let propertyKey be ! ToString(𝔽(k)).
            const property_key = PropertyKey.from(k.?);

            // b. Let kPresent be ? HasProperty(obj, propertyKey).
            const k_present = try obj.hasProperty(agent, property_key);

            // c. If kPresent is true, then
            if (k_present) {
                // i. Let kValue be ? Get(obj, propertyKey).
                const k_value = try obj.get(agent, property_key);

                // ii. Set accumulator to ? Call(callback, undefined, « accumulator, kValue, 𝔽(k),
                //     obj »).
                accumulator = try callback.call(
                    agent,
                    .undefined,
                    &.{ accumulator, k_value, Value.from(k.?), Value.from(obj) },
                );
            }

            // d. Set k to k - 1.
        }

        // 10. Return accumulator.
        return accumulator;
    }

    /// 23.1.3.26 Array.prototype.reverse ( )
    /// https://tc39.es/ecma262/#sec-array.prototype.reverse
    fn reverse(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let obj be ? ToObject(this value).
        const obj = try this_value.toObject(agent);

        // 2. Let length be ? LengthOfArrayLike(obj).
        const length = try obj.lengthOfArrayLike(agent);

        // OPTIMIZATION: Use fast path if applicable
        if (array_fast_paths.reverse(obj, length)) |_| {
            return Value.from(obj);
        }

        // 3. Let middle be floor(length / 2).
        const middle = length / 2;

        // 4. Let lower be 0.
        var lower: u53 = 0;

        // 5. Repeat, while lower ≠ middle,
        while (lower != middle) : (lower += 1) {
            // a. Let upper be length - lower - 1.
            const upper = length - lower - 1;

            // b. Let upperP be ! ToString(𝔽(upper)).
            const upper_property_key = PropertyKey.from(upper);

            // c. Let lowerP be ! ToString(𝔽(lower)).
            const lower_property_key = PropertyKey.from(lower);

            // d. Let lowerExists be ? HasProperty(obj, lowerP).
            const lower_exists = try obj.hasProperty(agent, lower_property_key);

            // e. If lowerExists is true, then
            const lower_value = if (lower_exists) blk: {
                // i. Let lowerValue be ? Get(obj, lowerP).
                break :blk try obj.get(agent, lower_property_key);
            } else undefined;

            // f. Let upperExists be ? HasProperty(obj, upperP).
            const upper_exists = try obj.hasProperty(agent, upper_property_key);

            // g. If upperExists is true, then
            const upper_value = if (upper_exists) blk: {
                // i. Let upperValue be ? Get(obj, upperP).
                break :blk try obj.get(agent, upper_property_key);
            } else undefined;

            // h. If lowerExists is true and upperExists is true, then
            if (lower_exists and upper_exists) {
                // i. Perform ? Set(obj, lowerP, upperValue, true).
                try obj.set(agent, lower_property_key, upper_value, .throw);

                // ii. Perform ? Set(obj, upperP, lowerValue, true).
                try obj.set(agent, upper_property_key, lower_value, .throw);
            }
            // i. Else if lowerExists is false and upperExists is true, then
            else if (!lower_exists and upper_exists) {
                // i. Perform ? Set(obj, lowerP, upperValue, true).
                try obj.set(agent, lower_property_key, upper_value, .throw);

                // ii. Perform ? DeletePropertyOrThrow(obj, upperP).
                try obj.deletePropertyOrThrow(agent, upper_property_key);
            }
            // j. Else if lowerExists is true and upperExists is false, then
            else if (lower_exists and !upper_exists) {
                // i. Perform ? DeletePropertyOrThrow(obj, lowerP).
                try obj.deletePropertyOrThrow(agent, lower_property_key);

                // ii. Perform ? Set(obj, upperP, lowerValue, true).
                try obj.set(agent, upper_property_key, lower_value, .throw);
            } else {
                // k. Else,
                // i. Assert: lowerExists and upperExists are both false.
                std.debug.assert(!lower_exists and !upper_exists);

                // ii. NOTE: No action is required.
            }

            // l. Set lower to lower + 1.
        }

        // 6. Return obj.
        return Value.from(obj);
    }

    /// 23.1.3.27 Array.prototype.shift ( )
    /// https://tc39.es/ecma262/#sec-array.prototype.shift
    fn shift(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let obj be ? ToObject(this value).
        const obj = try this_value.toObject(agent);

        // 2. Let length be ? LengthOfArrayLike(obj).
        const length = try obj.lengthOfArrayLike(agent);

        // OPTIMIZATION: Use fast path if applicable
        if (try array_fast_paths.shift(agent, obj, length)) |result| {
            return result;
        }

        // 3. If length = 0, then
        if (length == 0) {
            // a. Perform ? Set(obj, "length", +0𝔽, true).
            try obj.set(agent, PropertyKey.from("length"), Value.from(0), .throw);

            // b. Return undefined.
            return .undefined;
        }

        // 4. Let first be ? Get(obj, "0").
        const first = try obj.get(agent, PropertyKey.from(0));

        // 5. Let k be 1.
        var k: u53 = 1;

        // 6. Repeat, while k < length,
        while (k < length) : (k += 1) {
            // a. Let from be ! ToString(𝔽(k)).
            const from = PropertyKey.from(k);

            // b. Let to be ! ToString(𝔽(k - 1)).
            const to = PropertyKey.from(k - 1);

            // c. Let fromPresent be ? HasProperty(obj, from).
            const from_present = try obj.hasProperty(agent, from);

            // d. If fromPresent is true, then
            if (from_present) {
                // i. Let fromValue be ? Get(obj, from).
                const from_value = try obj.get(agent, from);

                // ii. Perform ? Set(obj, to, fromValue, true).
                try obj.set(agent, to, from_value, .throw);
            } else {
                // e. Else,
                // i. Assert: fromPresent is false.
                std.debug.assert(!from_present);

                // ii. Perform ? DeletePropertyOrThrow(obj, to).
                try obj.deletePropertyOrThrow(agent, to);
            }

            // f. Set k to k + 1.
        }

        // 7. Perform ? DeletePropertyOrThrow(obj, ! ToString(𝔽(length - 1))).
        try obj.deletePropertyOrThrow(agent, PropertyKey.from(length - 1));

        // 8. Perform ? Set(obj, "length", 𝔽(length - 1), true).
        try obj.set(agent, PropertyKey.from("length"), Value.from(length - 1), .throw);

        // 9. Return first.
        return first;
    }

    /// 23.1.3.28 Array.prototype.slice ( start, end )
    /// https://tc39.es/ecma262/#sec-array.prototype.slice
    fn slice(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const start = arguments.get(0);
        const end = arguments.get(1);

        // 1. Let obj be ? ToObject(this value).
        const obj = try this_value.toObject(agent);

        // 2. Let length be ? LengthOfArrayLike(obj).
        const length = try obj.lengthOfArrayLike(agent);

        // 3. Let k be ? ToClampedIndex(start, length).
        var k = try start.toClampedIndex(agent, length);

        // 4. If end is undefined, let final be length; else let final be ? ToClampedIndex(end,
        //    length).
        const final = if (end.isUndefined())
            length
        else
            try end.toClampedIndex(agent, length);

        // 5. Let count be max(final - k, 0).
        const count = final -| k;

        // 6. Let array be ? ArraySpeciesCreate(obj, count).
        const array = try arraySpeciesCreate(agent, obj, count);

        // 7. Let resultIndex be 0.
        var result_index: u53 = 0;

        // 8. Repeat, while k < final,
        while (k < final) : ({
            k += 1;
            result_index += 1;
        }) {
            // a. Let propertyKey be ! ToString(𝔽(k)).
            const property_key = PropertyKey.from(k);

            // b. Let kPresent be ? HasProperty(obj, propertyKey).
            const k_present = try obj.hasProperty(agent, property_key);

            // c. If kPresent is true, then
            if (k_present) {
                // i. Let kValue be ? Get(obj, propertyKey).
                const k_value = try obj.get(agent, property_key);

                // ii. Perform ? CreateDataPropertyOrThrow(array, ! ToString(𝔽(resultIndex)),
                //     kValue).
                try array.createDataPropertyOrThrow(agent, PropertyKey.from(result_index), k_value);
            }

            // d. Set k to k + 1.
            // e. Set resultIndex to resultIndex + 1.
        }

        // 9. Perform ? Set(array, "length", 𝔽(resultIndex), true).
        try array.set(agent, PropertyKey.from("length"), Value.from(result_index), .throw);

        // 10. Return array.
        return Value.from(array);
    }

    /// 23.1.3.29 Array.prototype.some ( callback [ , thisArg ] )
    /// https://tc39.es/ecma262/#sec-array.prototype.some
    fn some(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const callback_value = arguments.get(0);
        const this_arg = arguments.get(1);

        // 1. Let obj be ? ToObject(this value).
        const obj = try this_value.toObject(agent);

        // 2. Let length be ? LengthOfArrayLike(obj).
        const length = try obj.lengthOfArrayLike(agent);

        // 3. If IsCallable(callback) is false, throw a TypeError exception.
        if (!callback_value.isCallable()) {
            return agent.throwException(.type_error, "{f} is not callable", .{callback_value});
        }
        const callback = callback_value.asObject();

        // 4. Let k be 0.
        var k: u53 = 0;

        // OPTIMIZATION: Use fast path if applicable
        if (try array_fast_paths.some(
            agent,
            obj,
            length,
            callback,
            this_arg,
        )) |result| switch (result) {
            .done => |value| return Value.from(value),
            .continue_slow => |index| k = @intCast(index),
        };

        // 5. Repeat, while k < length,
        while (k < length) : (k += 1) {
            // a. Let propertyKey be ! ToString(𝔽(k)).
            const property_key = PropertyKey.from(k);

            // b. Let kPresent be ? HasProperty(obj, propertyKey).
            const k_present = try obj.hasProperty(agent, property_key);

            // c. If kPresent is true, then
            if (k_present) {
                // i. Let kValue be ? Get(obj, propertyKey).
                const k_value = try obj.get(agent, property_key);

                // ii. Let testResult be ToBoolean(? Call(callback, thisArg, « kValue, 𝔽(k),
                //     obj »)).
                const test_result = (try callback.call(
                    agent,
                    this_arg,
                    &.{ k_value, Value.from(k), Value.from(obj) },
                )).toBoolean();

                // iii. If testResult is true, return true.
                if (test_result) return .true;
            }

            // d. Set k to k + 1.
        }

        // 6. Return false.
        return .false;
    }

    /// 23.1.3.30 Array.prototype.sort ( comparator )
    /// https://tc39.es/ecma262/#sec-array.prototype.sort
    fn sort(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const comparator = arguments.get(0);

        // 1. If comparator is not undefined and IsCallable(comparator) is false, throw a TypeError
        //    exception.
        if (!comparator.isUndefined() and !comparator.isCallable()) {
            return agent.throwException(.type_error, "{f} is not callable", .{comparator});
        }

        // 2. Let obj be ? ToObject(this value).
        const obj = try this_value.toObject(agent);

        // 3. Let length be ? LengthOfArrayLike(obj).
        const length = try obj.lengthOfArrayLike(agent);

        // 4. Let sortCompare be a new Abstract Closure with parameters (x, y) that captures
        //    comparator and performs the following steps when called:
        const sortCompare = struct {
            fn func(agent_: *Agent, x: Value, y: Value, comparator_: ?*Object) Agent.Error!std.math.Order {
                // a. Return ? CompareArrayElements(x, y, comparator).
                return compareArrayElements(agent_, x, y, comparator_);
            }
        }.func;

        // 5. Let sortedList be ? SortIndexedProperties(obj, length, sortCompare, skip-holes).
        const sorted_list = try sortIndexedProperties(
            agent,
            obj,
            length,
            .{
                .impl = sortCompare,
                .comparator = if (!comparator.isUndefined()) comparator.asObject() else null,
            },
            .skip_holes,
        );

        // 6. Let itemCount be the number of elements in sortedList.
        const item_count: u53 = @intCast(sorted_list.len);

        // 7. Let j be 0.
        var j: u53 = 0;

        // 8. Repeat, while j < itemCount,
        while (j < item_count) : (j += 1) {
            // a. Perform ? Set(obj, ! ToString(𝔽(j)), sortedList[j], true).
            try obj.set(agent, PropertyKey.from(j), sorted_list[@intCast(j)], .throw);

            // b. Set j to j + 1.
        }

        // 9. NOTE: The call to SortIndexedProperties in step 5 uses skip-holes. The remaining
        //    indices are deleted to preserve the number of holes that were detected and excluded
        //    from the sort.

        // 10. Repeat, while j < length,
        while (j < length) : (j += 1) {
            // a. Perform ? DeletePropertyOrThrow(obj, ! ToString(𝔽(j))).
            try obj.deletePropertyOrThrow(agent, PropertyKey.from(j));

            // b. Set j to j + 1.
        }

        // 11. Return obj.
        return Value.from(obj);
    }

    /// 23.1.3.31 Array.prototype.splice ( start, deleteCount, ...items )
    /// https://tc39.es/ecma262/#sec-array.prototype.splice
    fn splice(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const start = arguments.get(0);
        const delete_count = arguments.get(1);
        const items = if (arguments.count() <= 2) &[_]Value{} else arguments.values[2..];

        // 1. Let obj be ? ToObject(this value).
        const obj = try this_value.toObject(agent);

        // 2. Let length be ? LengthOfArrayLike(obj).
        const length = try obj.lengthOfArrayLike(agent);

        // 3. Let actualStart be ? ToClampedIndex(start, length).
        const actual_start = try start.toClampedIndex(agent, length);

        // 4. Let itemCount be the number of elements in items.
        const item_count: u53 = @intCast(items.len);

        // 5. If start is not present, then
        const actual_delete_count = if (arguments.count() == 0) blk: {
            // a. Let actualDeleteCount be 0.
            break :blk 0;
        } else if (arguments.count() == 1) blk: {
            // 6. Else if deleteCount is not present, then
            // a. Let actualDeleteCount be length - actualStart.
            // b. Assert: actualDeleteCount ≥ 0.
            break :blk length - actual_start;
        } else blk: {
            // 7. Else,
            // a. Let dc be ? ToIntegerOrInfinity(deleteCount).
            const dc = try delete_count.toIntegerOrInfinity(agent);

            // b. Let actualDeleteCount be the result of clamping dc between 0 and
            //    length - actualStart.
            break :blk @as(u53, @intFromFloat(
                std.math.clamp(dc, 0, @as(f64, @floatFromInt(length - actual_start))),
            ));
        };

        // 8. If length + itemCount - actualDeleteCount > 2**53 - 1, throw a TypeError exception.
        _ = std.math.add(u53, length - actual_delete_count, item_count) catch {
            return agent.throwException(.type_error, "Maximum array length exceeded", .{});
        };

        // 9. Let deletedArray be ? ArraySpeciesCreate(obj, actualDeleteCount).
        const deleted_array = try arraySpeciesCreate(agent, obj, actual_delete_count);

        // 10. Let k be 0.
        var k: u53 = 0;

        // 11. Repeat, while k < actualDeleteCount,
        while (k < actual_delete_count) : (k += 1) {
            // a. Let from be ! ToString(𝔽(actualStart + k)).
            const from = PropertyKey.from(actual_start + k);

            // b. If ? HasProperty(obj, from) is true, then
            if (try obj.hasProperty(agent, from)) {
                // i. Let fromValue be ? Get(obj, from).
                const from_value = try obj.get(agent, from);

                // ii. Perform ? CreateDataPropertyOrThrow(deletedArray, ! ToString(𝔽(k)),
                //     fromValue).
                try deleted_array.createDataPropertyOrThrow(agent, PropertyKey.from(k), from_value);
            }

            // c. Set k to k + 1.
        }

        // 12. Perform ? Set(deletedArray, "length", 𝔽(actualDeleteCount), true).
        try deleted_array.set(agent, PropertyKey.from("length"), Value.from(actual_delete_count), .throw);

        // 13. If itemCount < actualDeleteCount, then
        if (item_count < actual_delete_count) {
            // a. Set k to actualStart.
            k = actual_start;

            // b. Repeat, while k < (length - actualDeleteCount),
            while (k < (length - actual_delete_count)) : (k += 1) {
                // i. Let from be ! ToString(𝔽(k + actualDeleteCount)).
                const from = PropertyKey.from(k + actual_delete_count);

                // ii. Let to be ! ToString(𝔽(k + itemCount)).
                const to = PropertyKey.from(k + item_count);

                // iii. If ? HasProperty(obj, from) is true, then
                if (try obj.hasProperty(agent, from)) {
                    // 1. Let fromValue be ? Get(obj, from).
                    const from_value = try obj.get(agent, from);

                    // 2. Perform ? Set(obj, to, fromValue, true).
                    try obj.set(agent, to, from_value, .throw);
                } else {
                    // iv. Else,
                    // 1. Perform ? DeletePropertyOrThrow(obj, to).
                    try obj.deletePropertyOrThrow(agent, to);
                }

                // v. Set k to k + 1.
            }

            // c. Set k to length.
            k = length;

            // d. Repeat, while k > (length - actualDeleteCount + itemCount),
            while (k > (length - actual_delete_count + item_count)) : (k -= 1) {
                // i. Perform ? DeletePropertyOrThrow(obj, ! ToString(𝔽(k - 1))).
                try obj.deletePropertyOrThrow(agent, PropertyKey.from(k - 1));

                // ii. Set k to k - 1.
            }
        }
        // 14. Else if itemCount > actualDeleteCount, then
        else if (item_count > actual_delete_count) {
            // a. Set k to (length - actualDeleteCount).
            k = length - actual_delete_count;

            // b. Repeat, while k > actualStart,
            while (k > actual_start) : (k -= 1) {
                // i. Let from be ! ToString(𝔽(k + actualDeleteCount - 1)).
                const from = PropertyKey.from(k + actual_delete_count - 1);

                // ii. Let to be ! ToString(𝔽(k + itemCount - 1)).
                const to = PropertyKey.from(k + item_count - 1);

                // iii. If ? HasProperty(obj, from) is true, then
                if (try obj.hasProperty(agent, from)) {
                    // 1. Let fromValue be ? Get(obj, from).
                    const from_value = try obj.get(agent, from);

                    // 2. Perform ? Set(obj, to, fromValue, true).
                    try obj.set(agent, to, from_value, .throw);
                } else {
                    // iv. Else,
                    // 1. Perform ? DeletePropertyOrThrow(obj, to).
                    try obj.deletePropertyOrThrow(agent, to);
                }

                // v. Set k to k - 1.
            }
        }

        // 15. Set k to actualStart.
        k = actual_start;

        // 16. For each element item of items, do
        for (items) |item| {
            // a. Perform ? Set(obj, ! ToString(𝔽(k)), item, true).
            try obj.set(agent, PropertyKey.from(k), item, .throw);

            // b. Set k to k + 1.
            k += 1;
        }

        // 17. Perform ? Set(obj, "length", 𝔽(length - actualDeleteCount + itemCount), true).
        try obj.set(
            agent,
            PropertyKey.from("length"),
            Value.from(length - actual_delete_count + item_count),
            .throw,
        );

        // 18. Return deletedArray.
        return Value.from(deleted_array);
    }

    /// 23.1.3.32 Array.prototype.toLocaleString ( [ reserved1 [ , reserved2 ] ] )
    /// https://tc39.es/ecma262/#sec-array.prototype.tolocalestring
    fn toLocaleString(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        if (build_options.enable_intl) {
            return toLocaleStringIntl(agent, this_value, arguments);
        }

        // 1. Let array be ? ToObject(this value).
        const array = try this_value.toObject(agent);

        // 2. Let length be ? LengthOfArrayLike(array).
        const length = try array.lengthOfArrayLike(agent);

        // OPTIMIZATION: If the array is empty the result will be an empty string
        if (length == 0) return Value.from(String.empty);

        // 3. Let separator be the implementation-defined list-separator String value appropriate
        //    for the host environment's current locale (such as ", ").
        const separator = String.fromLiteral(", ");

        // 4. Let result be the empty String.
        // NOTE: This allocates the maximum needed capacity upfront
        const capacity = std.math.cast(u32, @as(u64, length) * 2 - 1) orelse
            return error.OutOfMemory;
        var result = try String.Builder.initCapacity(agent.gc_allocator, capacity);
        defer result.deinit(agent.gc_allocator);

        // 5. Let k be 0.
        var k: u53 = 0;

        // 6. Repeat, while k < length,
        while (k < length) : (k += 1) {
            // a. If k > 0, set result to the string-concatenation of result and separator.
            if (k > 0) result.appendStringAssumeCapacity(separator);

            // b. Let element be ? Get(array, ! ToString(𝔽(k))).
            const element = try array.get(agent, PropertyKey.from(k));

            // c. If element is neither undefined nor null, then
            if (!element.isUndefined() and !element.isNull()) {
                // i. Let elementString be ? ToString(? Invoke(element, "toLocaleString")).
                const element_string = try (try element.invoke(
                    agent,
                    PropertyKey.from("toLocaleString"),
                    &.{},
                )).toString(agent);

                // ii. Set result to the string-concatenation of result and elementString.
                result.appendStringAssumeCapacity(element_string);
            }

            // d. Set k to k + 1.
        }

        // 7. Return result.
        return Value.from(try result.build(agent));
    }

    /// 20.5.1 Array.prototype.toLocaleString ( [ locales [ , options ] ] )
    /// https://tc39.es/ecma402/#sup-array.prototype.tolocalestring
    fn toLocaleStringIntl(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const locales = arguments.get(0);
        const options = arguments.get(1);

        // 1. Let array be ? ToObject(this value).
        const array = try this_value.toObject(agent);

        // 2. Let length be ? LengthOfArrayLike(array).
        const length = try array.lengthOfArrayLike(agent);

        // OPTIMIZATION: If the array is empty the result will be an empty string
        if (length == 0) return Value.from(String.empty);

        // 3. Let separator be the implementation-defined list-separator String value appropriate
        //    for the host environment's current locale (such as ", ").
        const separator = String.fromLiteral(", ");

        // 4. Let result be the empty String.
        // NOTE: This allocates the maximum needed capacity upfront
        const capacity = std.math.cast(u32, @as(u64, length) * 2 - 1) orelse
            return error.OutOfMemory;
        var result = try String.Builder.initCapacity(agent.gc_allocator, capacity);
        defer result.deinit(agent.gc_allocator);

        // 5. Let k be 0.
        var k: u53 = 0;

        // 6. Repeat, while k < length,
        while (k < length) : (k += 1) {

            // a. If k > 0, then
            if (k > 0) {
                // i. Set result to the string-concatenation of result and separator.
                result.appendStringAssumeCapacity(separator);
            }

            // b. Let element be ? Get(array, ! ToString(𝔽(k))).
            const element = try array.get(agent, PropertyKey.from(k));

            // c. If element is neither undefined nor null, then
            if (!element.isUndefined() and !element.isNull()) {
                // i. Let elementString be ? ToString(? Invoke(element, "toLocaleString", « locales,
                //    options »)).
                const element_string = try (try element.invoke(
                    agent,
                    PropertyKey.from("toLocaleString"),
                    &.{ locales, options },
                )).toString(agent);

                // ii. Set result to the string-concatenation of result and elementString.
                result.appendStringAssumeCapacity(element_string);
            }

            // d. Set k to k + 1.
        }

        // 7. Return result.
        return Value.from(try result.build(agent));
    }

    /// 23.1.3.33 Array.prototype.toReversed ( )
    /// https://tc39.es/ecma262/#sec-array.prototype.toreversed
    fn toReversed(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let obj be ? ToObject(this value).
        const obj = try this_value.toObject(agent);

        // 2. Let length be ? LengthOfArrayLike(obj).
        const length = try obj.lengthOfArrayLike(agent);

        // 3. Let array be ? ArrayCreate(length).
        const array = try arrayCreate(agent, length, null);

        // 4. Let k be 0.
        var k: u53 = 0;

        // 5. Repeat, while k < length,
        while (k < length) : (k += 1) {
            // a. Let from be ! ToString(𝔽(length - k - 1)).
            const from = PropertyKey.from(length - k - 1);

            // b. Let propertyKey be ! ToString(𝔽(k)).
            const property_key = PropertyKey.from(k);

            // c. Let fromValue be ? Get(obj, from).
            const from_value = try obj.get(agent, from);

            // d. Perform ! CreateDataPropertyOrThrow(array, propertyKey, fromValue).
            try array.object.createDataPropertyDirect(agent, property_key, from_value);

            // e. Set k to k + 1.
        }

        // 6. Return array.
        return Value.from(&array.object);
    }

    /// 23.1.3.34 Array.prototype.toSorted ( comparator )
    /// https://tc39.es/ecma262/#sec-array.prototype.tosorted
    fn toSorted(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const comparator = arguments.get(0);

        // 1. If comparator is not undefined and IsCallable(comparator) is false, throw a TypeError
        //    exception.
        if (!comparator.isUndefined() and !comparator.isCallable()) {
            return agent.throwException(.type_error, "{f} is not callable", .{comparator});
        }

        // 2. Let obj be ? ToObject(this value).
        const obj = try this_value.toObject(agent);

        // 3. Let length be ? LengthOfArrayLike(obj).
        const length = try obj.lengthOfArrayLike(agent);

        // 4. Let array be ? ArrayCreate(length).
        const array = try arrayCreate(agent, length, null);

        // 5. Let sortCompare be a new Abstract Closure with parameters (x, y) that captures
        //    comparator and performs the following steps when called:
        const sortCompare = struct {
            fn func(agent_: *Agent, x: Value, y: Value, comparator_: ?*Object) Agent.Error!std.math.Order {
                // a. Return ? CompareArrayElements(x, y, comparator).
                return compareArrayElements(agent_, x, y, comparator_);
            }
        }.func;

        // 6. Let sortedList be ? SortIndexedProperties(obj, length, sortCompare,
        //    read-through-holes).
        const sorted_list = try sortIndexedProperties(
            agent,
            obj,
            length,
            .{
                .impl = sortCompare,
                .comparator = if (!comparator.isUndefined()) comparator.asObject() else null,
            },
            .read_through_holes,
        );

        // 7. Let j be 0.
        var j: u53 = 0;

        // 8. Repeat, while j < length,
        while (j < length) : (j += 1) {
            // a. Perform ! CreateDataPropertyOrThrow(array, ! ToString(𝔽(j)), sortedList[j]).
            try array.object.createDataPropertyDirect(agent, PropertyKey.from(j), sorted_list[@intCast(j)]);

            // b. Set j to j + 1.
        }

        // 9. Return array.
        return Value.from(&array.object);
    }

    /// 23.1.3.35 Array.prototype.toSpliced ( start, skipCount, ...items )
    /// https://tc39.es/ecma262/#sec-array.prototype.tospliced
    fn toSpliced(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const start = arguments.get(0);
        const skip_count = arguments.get(1);
        const items = if (arguments.count() <= 2) &[_]Value{} else arguments.values[2..];

        // 1. Let obj be ? ToObject(this value).
        const obj = try this_value.toObject(agent);

        // 2. Let length be ? LengthOfArrayLike(obj).
        const length = try obj.lengthOfArrayLike(agent);

        // 3. Let actualStart be ? ToClampedIndex(start, length).
        const actual_start = try start.toClampedIndex(agent, length);

        // 4. Let insertCount be the number of elements in items.
        const insert_count: u53 = @intCast(items.len);

        // 5. Let maxSkipCount be length - actualStart.
        const max_skip_count = length - actual_start;

        // 6. If start is not present, then
        const actual_skip_count = if (arguments.count() == 0) blk: {
            // a. Let actualSkipCount be 0.
            break :blk 0;
        } else if (arguments.count() == 1) blk: {
            // 7. Else if skipCount is not present, then
            // a. Let actualSkipCount be maxSkipCount.
            break :blk max_skip_count;
        } else blk: {
            // 8. Else,
            // a. Let actualSkipCount be the result of clamping ? ToIntegerOrInfinity(skipCount)
            //    between 0 and maxSkipCount.
            break :blk @as(u53, @intFromFloat(
                std.math.clamp(try skip_count.toIntegerOrInfinity(agent), 0, @as(f64, @floatFromInt(max_skip_count))),
            ));
        };

        // 9. Let newLength be length + insertCount - actualSkipCount.
        // 10. Assert: newLength ≥ 0.
        // 11. If newLength > 2**53 - 1, throw a TypeError exception.
        const new_length = std.math.add(u53, length - actual_skip_count, insert_count) catch {
            return agent.throwException(.type_error, "Maximum array length exceeded", .{});
        };

        // 12. Let newArray be ? ArrayCreate(newLength).
        const new_array = try arrayCreate(agent, new_length, null);

        // 13. Let writeIndex be 0.
        var write_index: u53 = 0;

        // 14. Let readIndex be actualStart + actualSkipCount.
        var read_index = actual_start + actual_skip_count;

        // 15. Repeat, while writeIndex < actualStart,
        while (write_index < actual_start) : (write_index += 1) {
            // a. Let propertyKey be ! ToString(𝔽(writeIndex)).
            const property_key = PropertyKey.from(write_index);

            // b. Let iValue be ? Get(obj, propertyKey).
            const i_value = try obj.get(agent, property_key);

            // c. Perform ! CreateDataPropertyOrThrow(newArray, propertyKey, iValue).
            try new_array.object.createDataPropertyDirect(agent, property_key, i_value);

            // d. Set writeIndex to writeIndex + 1.
        }

        // 16. For each element item of items, do
        for (items) |item| {
            // a. Let propertyKey be ! ToString(𝔽(writeIndex)).
            const property_key = PropertyKey.from(write_index);

            // b. Perform ! CreateDataPropertyOrThrow(newArray, propertyKey, item).
            try new_array.object.createDataPropertyDirect(agent, property_key, item);

            // c. Set writeIndex to writeIndex + 1.
            write_index += 1;
        }

        // 17. Repeat, while writeIndex < newLength,
        while (write_index < new_length) : ({
            write_index += 1;
            read_index += 1;
        }) {
            // a. Let propertyKey be ! ToString(𝔽(writeIndex)).
            const property_key = PropertyKey.from(write_index);

            // b. Let from be ! ToString(𝔽(readIndex)).
            const from = PropertyKey.from(read_index);

            // c. Let fromValue be ? Get(obj, from).
            const from_value = try obj.get(agent, from);

            // d. Perform ! CreateDataPropertyOrThrow(newArray, propertyKey, fromValue).
            try new_array.object.createDataPropertyDirect(agent, property_key, from_value);

            // e. Set writeIndex to writeIndex + 1.
            // f. Set readIndex to readIndex + 1.
        }

        // 18. Return newArray.
        return Value.from(&new_array.object);
    }

    /// 23.1.3.36 Array.prototype.toString ( )
    /// https://tc39.es/ecma262/#sec-array.prototype.tostring
    fn toString(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        const realm = agent.currentRealm();

        // 1. Let array be ? ToObject(this value).
        const array = try this_value.toObject(agent);

        // 2. Let func be ? Get(array, "join").
        const func_value = try array.get(agent, PropertyKey.from("join"));

        // 3. If IsCallable(func) is false, set func to the intrinsic function
        //    %Object.prototype.toString%.
        const func = if (func_value.isCallable())
            func_value.asObject()
        else
            try realm.intrinsic(.object_prototype_to_string);

        // 4. Return ? Call(func, array).
        return func.call(agent, Value.from(array), &.{});
    }

    /// 23.1.3.37 Array.prototype.unshift ( ...items )
    /// https://tc39.es/ecma262/#sec-array.prototype.unshift
    fn unshift(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        // 1. Let obj be ? ToObject(this value).
        const obj = try this_value.toObject(agent);

        // 2. Let length be ? LengthOfArrayLike(obj).
        const length = try obj.lengthOfArrayLike(agent);

        // 3. Let argCount be the number of elements in items.
        const arg_count = arguments.count();

        // 4. If argCount > 0, then
        if (arg_count > 0) {
            // a. If length + argCount > 2**53 - 1, throw a TypeError exception.
            _ = std.math.add(u53, length, @intCast(arg_count)) catch {
                return agent.throwException(.type_error, "Maximum array length exceeded", .{});
            };

            // OPTIMIZATION: Use fast path if applicable
            if (try array_fast_paths.unshift(agent, obj, length, arguments.values)) |result| {
                return result;
            }

            // b. Let k be length.
            var k = length;

            // c. Repeat, while k > 0,
            while (k > 0) : (k -= 1) {
                // i. Let from be ! ToString(𝔽(k - 1)).
                const from = PropertyKey.from(k - 1);

                // ii. Let to be ! ToString(𝔽(k + argCount - 1)).
                const to = PropertyKey.from(
                    k + @as(PropertyKey.IntegerIndex, @intCast(arg_count)) - 1,
                );

                // iii. Let fromPresent be ? HasProperty(obj, from).
                const from_present = try obj.hasProperty(agent, from);

                // iv. If fromPresent is true, then
                if (from_present) {
                    // 1. Let fromValue be ? Get(obj, from).
                    const from_value = try obj.get(agent, from);

                    // 2. Perform ? Set(obj, to, fromValue, true).
                    try obj.set(agent, to, from_value, .throw);
                } else {
                    // v. Else,
                    // 1. Assert: fromPresent is false.
                    std.debug.assert(!from_present);

                    // 2. Perform ? DeletePropertyOrThrow(obj, to).
                    try obj.deletePropertyOrThrow(agent, to);
                }

                // vi. Set k to k - 1.
            }

            // d. Let j be 0.
            // e. For each element item of items, do
            for (arguments.values, 0..) |item, j| {
                // i. Perform ? Set(obj, ! ToString(𝔽(j)), item, true).
                const property_key = PropertyKey.from(@as(PropertyKey.IntegerIndex, @intCast(j)));
                try obj.set(agent, property_key, item, .throw);

                // ii. Set j to j + 1.
            }
        }

        // 5. Perform ? Set(obj, "length", 𝔽(length + argCount), true).
        try obj.set(
            agent,
            PropertyKey.from("length"),
            Value.from(length + @as(u53, @intCast(arg_count))),
            .throw,
        );

        // 6. Return 𝔽(length + argCount).
        return Value.from(length + @as(u53, @intCast(arg_count)));
    }

    /// 23.1.3.38 Array.prototype.values ( )
    /// https://tc39.es/ecma262/#sec-array.prototype.values
    fn values(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let obj be ? ToObject(this value).
        const obj = try this_value.toObject(agent);

        // 2. Return CreateArrayIterator(obj, value).
        const array_iterator = try createArrayIterator(agent, obj, .value);
        return Value.from(&array_iterator.object);
    }

    /// 23.1.3.39 Array.prototype.with ( index, value )
    /// https://tc39.es/ecma262/#sec-array.prototype.with
    fn with(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const index = arguments.get(0);
        const value = arguments.get(1);

        // 1. Let obj be ? ToObject(this value).
        const obj = try this_value.toObject(agent);

        // 2. Let length be ? LengthOfArrayLike(obj).
        const length = try obj.lengthOfArrayLike(agent);

        // 3. Let actualIndex be ? ToAbsoluteIndex(index, length).
        const actual_index_f64 = try index.toAbsoluteIndex(agent, length);

        // 4. If actualIndex < 0 or actualIndex ≥ length, throw a RangeError exception.
        if (actual_index_f64 < 0 or actual_index_f64 >= @as(f64, @floatFromInt(length))) {
            return agent.throwException(.range_error, "Index is out of array bounds", .{});
        }
        const actual_index: u53 = @intFromFloat(actual_index_f64);

        // 5. Let array be ? ArrayCreate(length).
        const array = try arrayCreate(agent, length, null);

        // 6. Let k be 0.
        var k: u53 = 0;

        // 7. Repeat, while k < length,
        while (k < length) : (k += 1) {
            // a. Let propertyKey be ! ToString(𝔽(k)).
            const property_key = PropertyKey.from(k);

            // b. If k = actualIndex, let fromValue be value.
            // c. Else, let fromValue be ? Get(obj, propertyKey).
            const from_value = if (k == actual_index)
                value
            else
                try obj.get(agent, property_key);

            // d. Perform ! CreateDataPropertyOrThrow(array, propertyKey, fromValue).
            try array.object.createDataPropertyDirect(agent, property_key, from_value);

            // e. Set k to k + 1.
        }

        // 8. Return array.
        return Value.from(&array.object);
    }
};

pub const FindViaPredicateDirection = enum { ascending, descending };
pub const FindViaPredicateResult = struct { index: Value, value: Value };

/// 23.1.3.12.1 FindViaPredicate ( obj, length, direction, predicate, thisArg )
/// https://tc39.es/ecma262/#sec-findviapredicate
pub fn findViaPredicate(
    agent: *Agent,
    obj: *Object,
    length: u53,
    comptime direction: FindViaPredicateDirection,
    predicate_value: Value,
    this_arg: Value,
) Agent.Error!FindViaPredicateResult {
    // 1. If IsCallable(predicate) is false, throw a TypeError exception.
    if (!predicate_value.isCallable()) {
        return agent.throwException(.type_error, "{f} is not callable", .{predicate_value});
    }
    const predicate = predicate_value.asObject();

    // 2. If direction is ascending, then
    //     a. Let indices be a List of the integers in the interval from 0 (inclusive) to length
    //        (exclusive), in ascending order.
    // 3. Else,
    //     a. Let indices be a List of the integers in the interval from 0 (inclusive) to length
    //        (exclusive), in descending order.
    // 4. For each integer k of indices, do
    var k: ?u53 = if (direction == .ascending) 0 else std.math.sub(u53, length, 1) catch null;

    // OPTIMIZATION: Use fast path if applicable
    if (try array_fast_paths.findViaPredicate(
        agent,
        obj,
        length,
        direction,
        predicate,
        this_arg,
    )) |result| switch (result) {
        .done => |value| return value,
        .continue_slow => |index| k = if (index) |i| @intCast(i) else null,
    };

    // zig fmt: off
    while (
        if (direction == .ascending) k.? < length else k != null
    ) : (
        k = if (direction == .ascending) k.? + 1 else std.math.sub(u53, k.?, 1) catch null
    ) {
        // zig fmt: on
        // a. Let propertyKey be ! ToString(𝔽(k)).
        const property_key = PropertyKey.from(k.?);

        // b. NOTE: If obj is a TypedArray, the following invocation of Get will return a normal
        //    completion.
        // c. Let kValue be ? Get(obj, propertyKey).
        const k_value = try obj.get(agent, property_key);

        // d. Let testResult be ? Call(predicate, thisArg, « kValue, 𝔽(k), obj »).
        const test_result = try predicate.call(
            agent,
            this_arg,
            &.{ k_value, Value.from(k.?), Value.from(obj) },
        );

        // e. If ToBoolean(testResult) is true, return the Record { [[Index]]: 𝔽(k),
        //    [[Value]]: kValue }.
        if (test_result.toBoolean()) return .{ .index = Value.from(k.?), .value = k_value };
    }

    // 5. Return the Record { [[Index]]: -1𝔽, [[Value]]: undefined }.
    return .{ .index = Value.from(-1), .value = .undefined };
}

const SortCompare = struct {
    impl: *const fn (
        agent: *Agent,
        x: Value,
        y: Value,
        comparator: ?*Object,
    ) Agent.Error!std.math.Order,
    comparator: ?*Object,
};

/// Custom insertion sort implementation, `std.mem` doesn't have fallible sorting functions
/// https://github.com/Koura/algorithms/blob/main/sorting/insertion_sort.zig
fn insertionSort(agent: *Agent, items: []Value, sort_compare: SortCompare) Agent.Error!void {
    const sortCompare = sort_compare.impl;
    const comparator = sort_compare.comparator;
    var i: usize = 1;
    while (i < items.len) : (i += 1) {
        const x = items[i];
        var j = i;
        while (j > 0) : (j -= 1) {
            const y = items[j - 1];
            if (try sortCompare(agent, x, y, comparator) != .lt) break;
            items[j] = y;
        }
        items[j] = x;
    }
}

/// 23.1.3.30.1 SortIndexedProperties ( obj, length, sortCompare, holes )
/// https://tc39.es/ecma262/#sec-sortindexedproperties
pub fn sortIndexedProperties(
    agent: *Agent,
    obj: *Object,
    length: u53,
    sort_compare: SortCompare,
    comptime holes: enum { skip_holes, read_through_holes },
) Agent.Error![]const Value {
    // 1. Let items be a new empty List.
    var items: std.ArrayList(Value) = .empty;

    // 2. Let k be 0.
    var k: u53 = 0;

    // 3. Repeat, while k < length,
    while (k < length) : (k += 1) {
        // a. Let propertyKey be ! ToString(𝔽(k)).
        const property_key = PropertyKey.from(k);

        const k_read = switch (holes) {
            // b. If holes is skip-holes, then
            .skip_holes => blk: {
                // i. Let kRead be ? HasProperty(obj, propertyKey).
                break :blk try obj.hasProperty(agent, property_key);
            },
            // c. Else,
            .read_through_holes => blk: {
                // i. Assert: holes is read-through-holes.
                // ii. Let kRead be true.
                break :blk true;
            },
        };

        // d. If kRead is true, then
        if (k_read) {
            // i. Let kValue be ? Get(obj, propertyKey).
            const k_value = try obj.get(agent, property_key);

            // ii. Append kValue to items.
            try items.append(agent.gc_allocator, k_value);
        }

        // e. Set k to k + 1.
    }

    // 4. Sort items using an implementation-defined sequence of calls to sortCompare. If any such
    //    call returns an abrupt completion, stop before performing any further calls to sortCompare
    //    and return that Completion Record.
    try insertionSort(agent, items.items, sort_compare);

    // 5. Return items.
    return items.toOwnedSlice(agent.gc_allocator);
}

/// 23.1.3.30.2 CompareArrayElements ( x, y, comparator )
/// https://tc39.es/ecma262/#sec-comparearrayelements
pub fn compareArrayElements(
    agent: *Agent,
    x: Value,
    y: Value,
    maybe_comparator: ?*Object,
) Agent.Error!std.math.Order {
    // 1. If x is undefined and y is undefined, return +0𝔽.
    if (x.isUndefined() and y.isUndefined()) return .eq;

    // 2. If x is undefined, return 1𝔽.
    if (x.isUndefined()) return .gt;

    // 3. If y is undefined, return -1𝔽.
    if (y.isUndefined()) return .lt;

    // 4. If comparator is not undefined, then
    if (maybe_comparator) |comparator| {
        // a. Let result be ? ToNumber(? Call(comparator, undefined, « x, y »)).
        const result = try (try comparator.call(agent, .undefined, &.{ x, y })).toNumber(agent);

        // b. If result is NaN, return +0𝔽.
        if (result.isNan()) return .eq;

        // c. Return result.
        return if (result.isZero()) .eq else if (result.asFloat() < 0) .lt else .gt;
    }

    // 5. Let xString be ? ToString(x).
    const x_string = try x.toString(agent);

    // 6. Let yString be ? ToString(y).
    const y_string = try y.toString(agent);

    // 7. Let xSmaller be ! IsLessThan(xString, yString, true).
    const x_smaller = isLessThan(
        agent,
        Value.from(x_string),
        Value.from(y_string),
        .left_first,
    ) catch unreachable;

    // 8. If xSmaller is true, return -1𝔽.
    if (x_smaller == true) return .lt;

    // 9. Let ySmaller be ! IsLessThan(yString, xString, true).
    const y_smaller = isLessThan(
        agent,
        Value.from(y_string),
        Value.from(x_string),
        .left_first,
    ) catch unreachable;

    // 10. If ySmaller is true, return 1𝔽.
    if (y_smaller == true) return .gt;

    // 11. Return +0𝔽.
    return .eq;
}

/// 23.1.4 Properties of Array Instances
/// https://tc39.es/ecma262/#sec-properties-of-array-instances
pub const Array = MakeObject(.{
    .Fields = struct {
        length: u32,
        length_writable: bool,
    },
    .tag = .array,
    .display_name = "Array",
});
