//! 24.2 Set Objects
//! https://tc39.es/ecma262/#sec-set-objects

const std = @import("std");

const builtins = @import("../builtins.zig");
const execution = @import("../execution.zig");
const types = @import("../types.zig");
const utils = @import("../utils.zig");

const Agent = execution.Agent;
const Arguments = types.Arguments;
const MakeObject = types.MakeObject;
const Object = types.Object;
const PropertyKey = types.PropertyKey;
const Realm = execution.Realm;
const Value = types.Value;
const createBuiltinFunction = builtins.createBuiltinFunction;
const createSetIterator = builtins.createSetIterator;
const getIterator = types.getIterator;
const getIteratorFromMethod = types.getIteratorFromMethod;
const noexcept = utils.noexcept;
const ordinaryCreateFromConstructor = builtins.ordinaryCreateFromConstructor;
const ordinaryObjectCreate = builtins.ordinaryObjectCreate;
const ordinaryObjectCreateWithType = builtins.ordinaryObjectCreateWithType;
const sameValue = types.sameValue;

const SetData = std.array_hash_map.Custom(Value, void, struct {
    pub fn hash(_: @This(), key: Value) u32 {
        if (key.isUninitialized()) return 0;
        return key.hash();
    }
    pub fn eql(_: @This(), a: Value, b: Value, _: usize) bool {
        if (a.isUninitialized() or b.isUninitialized()) return false;
        return sameValue(a, b);
    }
}, false);

fn compactSetData(
    gpa: std.mem.Allocator,
    set_data: *SetData,
    dead_entries: usize,
) std.mem.Allocator.Error!SetData {
    var compacted: SetData = .empty;
    try compacted.ensureUnusedCapacity(gpa, set_data.count() - dead_entries);
    for (set_data.keys()) |key| {
        if (!key.isUninitialized()) {
            compacted.putAssumeCapacity(key, {});
        }
    }
    set_data.deinit(gpa);
    return compacted;
}

/// 24.2.1.1 Set Records
/// https://tc39.es/ecma262/#sec-set-records
const SetRecord = struct {
    /// [[SetObject]]
    set_object: *Object,

    /// [[Size]]
    size: usize,

    /// [[Has]]
    has: *Object,

    /// [[Keys]]
    keys: *Object,
};

/// 24.2.1.2 GetSetRecord ( obj )
/// https://tc39.es/ecma262/#sec-getsetrecord
fn getSetRecord(agent: *Agent, obj_value: Value) Agent.Error!SetRecord {
    // 1. If obj is not an Object, throw a TypeError exception.
    if (!obj_value.isObject()) {
        return agent.throwException(
            .type_error,
            "{f} is not an Object",
            .{obj_value},
        );
    }
    const obj = obj_value.asObject();

    // 2. Let rawSize be ? Get(obj, "size").
    const raw_size = try obj.get(agent, PropertyKey.from("size"));

    // 3. Let numberSize be ? ToNumber(rawSize).
    const number_size = try raw_size.toNumber(agent);

    // 4. NOTE: If rawSize is undefined, then numberSize will be NaN.

    // 5. If numberSize is NaN, throw a TypeError exception.
    if (number_size.isNan()) {
        return agent.throwException(
            .type_error,
            "Size of Set-like object must not be NaN",
            .{},
        );
    }

    // 6. Let intSize be ! ToIntegerOrInfinity(numberSize).
    const int_size = Value.from(number_size).toIntegerOrInfinity(agent) catch |err| try noexcept(err);

    // 7. If intSize < 0, throw a RangeError exception.
    if (int_size < 0) {
        return agent.throwException(
            .range_error,
            "Size of Set-like object must be non-negative",
            .{},
        );
    }

    // 8. Let has be ? Get(obj, "has").
    const has = try obj.get(agent, PropertyKey.from("has"));

    // 9. If IsCallable(has) is false, throw a TypeError exception.
    if (!has.isCallable()) {
        return agent.throwException(
            .type_error,
            "'has' property of Set-like object must be callable",
            .{},
        );
    }

    // 10. Let keys be ? Get(obj, "keys").
    const keys = try obj.get(agent, PropertyKey.from("keys"));

    // 11. If IsCallable(keys) is false, throw a TypeError exception.
    if (!keys.isCallable()) {
        return agent.throwException(
            .type_error,
            "'keys' property of Set-like object must be callable",
            .{},
        );
    }

    // 12. Return a new Set Record { [[SetObject]]: obj, [[Size]]: intSize, [[Has]]: has,
    //     [[Keys]]: keys }.
    return .{
        .set_object = obj,
        .size = @intFromFloat(int_size),
        .has = has.asObject(),
        .keys = keys.asObject(),
    };
}

/// 24.2.1.3 SetDataHas ( setData, value )
/// https://tc39.es/ecma262/#sec-setdatahas
fn setDataHas(set_data: SetData, value: Value) bool {
    // 1. If SetDataIndex(setData, value) is not-found, return false.
    // 2. Return true.
    return setDataIndex(set_data, value) != null;
}

/// 24.2.1.4 SetDataIndex ( setData, value )
/// https://tc39.es/ecma262/#sec-setdataindex
fn setDataIndex(set_data: SetData, value: Value) ?usize {
    // 1. Set value to CanonicalizeKeyedCollectionKey(value).
    // 2. Let size be the number of elements in setData.
    // 3. Let index be 0.
    // 4. Repeat, while index < size,
    //    a. Let element be setData[index].
    //    b. If element is not empty and element is value, then
    //       i. Return index.
    //    c. Set index to index + 1.
    // 5. Return not-found.
    return set_data.getIndex(value.canonicalizeKeyedCollectionKey());
}

/// 24.2.1.5 SetDataSize ( setData )
/// https://tc39.es/ecma262/#sec-setdatasize
fn setDataSize(set_data: SetData, dead_entries: usize) usize {
    // 1. Let count be 0.
    // 2. For each element element of setData, do
    //     a. If element is not empty, set count to count + 1.
    // 3. Return count.
    return set_data.count() - dead_entries;
}

/// 24.2.3 Properties of the Set Constructor
/// https://tc39.es/ecma262/#sec-properties-of-the-set-constructor
pub const constructor = struct {
    pub fn create(agent: *Agent, realm: *Realm) std.mem.Allocator.Error!*Object {
        const builtin_function = try createBuiltinFunction(
            agent,
            .{ .constructor = impl },
            0,
            "Set",
            .{ .realm = realm, .proto = try realm.intrinsic(.function_prototype) },
        );
        return &builtin_function.object;
    }

    pub fn init(agent: *Agent, realm: *Realm, object: *Object) std.mem.Allocator.Error!void {
        try object.defineBuiltinAccessor(agent, "Symbol.species", @"Symbol.species", null, realm);

        // 24.2.3.1 Set.prototype
        // https://tc39.es/ecma262/#sec-set.prototype
        try object.defineBuiltinPropertyWithAttributes(
            agent,
            "prototype",
            Value.from(try realm.intrinsic(.set_prototype)),
            .none,
        );
    }

    /// 24.2.2.1 Set ( [ iterable ] )
    /// https://tc39.es/ecma262/#sec-set-iterable
    fn impl(agent: *Agent, arguments: Arguments, new_target: ?*Object) Agent.Error!Value {
        const iterable = arguments.get(0);

        // 1. If NewTarget is undefined, throw a TypeError exception.
        if (new_target == null) {
            return agent.throwException(.type_error, "Set must be constructed with 'new'", .{});
        }

        // 2. Let set be ? OrdinaryCreateFromConstructor(NewTarget, "%Set.prototype%",
        //    « [[SetData]] »).
        const set = try ordinaryCreateFromConstructor(
            Set,
            agent,
            new_target.?,
            .set_prototype,
            .{
                // 3. Set set.[[SetData]] to a new empty List.
                .set_data = .empty,
            },
        );

        // 4. If iterable is either undefined or null, return set.
        if (iterable.isUndefined() or iterable.isNull()) return Value.from(&set.object);

        // 5. Let adder be ? Get(set, "add").
        const adder_value = try set.object.get(agent, PropertyKey.from("add"));

        // 6. If IsCallable(adder) is false, throw a TypeError exception.
        if (!adder_value.isCallable()) {
            return agent.throwException(.type_error, "{f} is not callable", .{adder_value});
        }
        const adder = adder_value.asObject();

        // 7. Let iteratorRecord be ? GetIterator(iterable, sync).
        var iterator = try getIterator(agent, iterable, .sync);

        // 8. Repeat,
        //     a. Let next be ? IteratorStepValue(iteratorRecord).
        //     b. If next is done, return set.
        while (try iterator.stepValue(agent)) |next| {
            // c. Let status be Completion(Call(adder, set, « next »)).
            _ = adder.call(agent, Value.from(&set.object), &.{next}) catch |err| {
                // d. IfAbruptCloseIterator(status, iteratorRecord).
                return iterator.close(agent, @as(Agent.Error!Value, err));
            };
        }

        return Value.from(&set.object);
    }

    /// 24.2.3.2 get Set [ %Symbol.species% ]
    /// https://tc39.es/ecma262/#sec-get-set-%symbol.species%
    fn @"Symbol.species"(_: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Return the this value.
        return this_value;
    }
};

/// 24.2.4 Properties of the Set Prototype Object
/// https://tc39.es/ecma262/#sec-properties-of-the-set-prototype-object
pub const prototype = struct {
    pub fn create(agent: *Agent, realm: *Realm) std.mem.Allocator.Error!*Object {
        return ordinaryObjectCreate(agent, try realm.intrinsic(.object_prototype));
    }

    pub fn init(agent: *Agent, realm: *Realm, object: *Object) std.mem.Allocator.Error!void {
        try object.defineBuiltinFunction(agent, "add", add, 1, realm);
        try object.defineBuiltinFunction(agent, "clear", clear, 0, realm);
        try object.defineBuiltinFunction(agent, "delete", delete, 1, realm);
        try object.defineBuiltinFunction(agent, "difference", difference, 1, realm);
        try object.defineBuiltinFunction(agent, "entries", entries, 0, realm);
        try object.defineBuiltinFunction(agent, "forEach", forEach, 1, realm);
        try object.defineBuiltinFunction(agent, "has", has, 1, realm);
        try object.defineBuiltinFunction(agent, "intersection", intersection, 1, realm);
        try object.defineBuiltinFunction(agent, "isDisjointFrom", isDisjointFrom, 1, realm);
        try object.defineBuiltinFunction(agent, "isSubsetOf", isSubsetOf, 1, realm);
        try object.defineBuiltinFunction(agent, "isSupersetOf", isSupersetOf, 1, realm);
        try object.defineBuiltinAccessor(agent, "size", size, null, realm);
        try object.defineBuiltinFunction(agent, "symmetricDifference", symmetricDifference, 1, realm);
        try object.defineBuiltinFunction(agent, "union", @"union", 1, realm);
        try object.defineBuiltinFunction(agent, "values", values, 0, realm);

        // 24.2.4.3 Set.prototype.constructor
        // https://tc39.es/ecma262/#sec-set.prototype.constructor
        try object.defineBuiltinProperty(
            agent,
            "constructor",
            Value.from(try realm.intrinsic(.set)),
        );

        // 24.2.4.13 Set.prototype.keys ( )
        // https://tc39.es/ecma262/#sec-set.prototype.keys
        const set_prototype_values = object.getPropertyValueDirect(PropertyKey.from("values"));
        try object.defineBuiltinProperty(agent, "keys", set_prototype_values);

        // 24.2.4.18 Set.prototype [ %Symbol.iterator% ] ( )
        // https://tc39.es/ecma262/#sec-set.prototype-%symbol.iterator%
        try object.defineBuiltinProperty(agent, "Symbol.iterator", set_prototype_values);

        // 24.2.4.19 Set.prototype [ %Symbol.toStringTag% ]
        // https://tc39.es/ecma262/#sec-set.prototype-%symbol.tostringtag%
        try object.defineBuiltinPropertyWithAttributes(
            agent,
            "Symbol.toStringTag",
            Value.from("Set"),
            .{
                .writable = false,
                .enumerable = false,
                .configurable = true,
            },
        );
    }

    /// 24.2.4.1 Set.prototype.add ( value )
    /// https://tc39.es/ecma262/#sec-set.prototype.add
    fn add(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        var value = arguments.get(0);

        // 1. Let set be the this value.
        // 2. Perform ? RequireInternalSlot(set, [[SetData]]).
        const set = try this_value.requireInternalSlot(agent, Set);

        // 3. Set value to CanonicalizeKeyedCollectionKey(value).
        value = value.canonicalizeKeyedCollectionKey();

        // 4. For each element entry of set.[[SetData]], do
        //     a. If entry is not empty and SameValue(entry, value) is true, then
        //         i. Return set.
        // 5. Append value to set.[[SetData]].
        const result = try set.fields.set_data.getOrPut(agent.gc_allocator, value);
        if (!result.found_existing) {
            result.value_ptr.* = {};
        }

        // 6. Return set.
        return Value.from(&set.object);
    }

    /// 24.2.4.2 Set.prototype.clear ( )
    /// https://tc39.es/ecma262/#sec-set.prototype.clear
    fn clear(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let set be the this value.
        // 2. Perform ? RequireInternalSlot(set, [[SetData]]).
        const set = try this_value.requireInternalSlot(agent, Set);

        // 3. For each element entry of set.[[SetData]], do
        //     a. Replace the element of set.[[SetData]] whose value is entry with an element whose
        //        value is empty.
        @memset(set.fields.set_data.keys(), .uninitialized);
        set.fields.dead_entries = set.fields.set_data.count();
        try set.fields.compactIfNeeded(agent.gc_allocator);

        // 4. Return undefined.
        return .undefined;
    }

    /// 24.2.4.4 Set.prototype.delete ( value )
    /// https://tc39.es/ecma262/#sec-set.prototype.delete
    fn delete(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        var value = arguments.get(0);

        // 1. Let set be the this value.
        // 2. Perform ? RequireInternalSlot(set, [[SetData]]).
        const set = try this_value.requireInternalSlot(agent, Set);

        // 3. Set value to CanonicalizeKeyedCollectionKey(value).
        value = value.canonicalizeKeyedCollectionKey();

        // 4. For each element entry of set.[[SetData]], do
        //     a. If entry is not empty and SameValue(entry, value) is true, then
        if (set.fields.set_data.getIndex(value)) |index| {
            // i. Replace the element of set.[[SetData]] whose value is entry with an element whose
            //    value is empty.
            set.fields.set_data.entries.set(index, .{
                .hash = {},
                .key = .uninitialized,
                .value = {},
            });
            set.fields.dead_entries += 1;
            try set.fields.compactIfNeeded(agent.gc_allocator);

            // ii. Return true.
            return .true;
        }

        // 5. Return false.
        return .false;
    }

    /// 24.2.4.5 Set.prototype.difference ( other )
    /// https://tc39.es/ecma262/#sec-set.prototype.difference
    pub fn difference(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const other = arguments.get(0);

        // 1. Let set be the this value.
        // 2. Perform ? RequireInternalSlot(set, [[SetData]]).
        const set = try this_value.requireInternalSlot(agent, Set);

        // 3. Let otherRecord be ? GetSetRecord(other).
        const other_record = try getSetRecord(agent, other);

        // 4. Let resultSetData be a copy of set.[[SetData]].
        var result_set_data = try set.fields.set_data.clone(agent.gc_allocator);

        var dead_entries: usize = 0;

        // 5. If SetDataSize(set.[[SetData]]) ≤ otherRecord.[[Size]], then
        if (setDataSize(set.fields.set_data, set.fields.dead_entries) <= other_record.size) {
            // a. Let thisSize be the number of elements in set.[[SetData]].
            const this_size = set.fields.set_data.count();

            // b. Let index be 0.
            var index: usize = 0;

            // c. Repeat, while index < thisSize,
            while (index < this_size) : (index += 1) {
                // i. Let entry be resultSetData[index].
                const entry = result_set_data.entries.get(index);

                // ii. If entry is not empty, then
                // 1. Let inOther be ToBoolean(? Call(otherRecord.[[Has]],
                //    otherRecord.[[SetObject]], « entry »)).
                const in_other = (try other_record.has.call(
                    agent,
                    Value.from(other_record.set_object),
                    &.{entry.key},
                )).toBoolean();

                // 2. If inOther is true, then
                if (in_other) {
                    // a. Set resultSetData[index] to empty.
                    result_set_data.entries.set(index, .{
                        .hash = {},
                        .key = .uninitialized,
                        .value = {},
                    });
                    dead_entries += 1;
                }

                // iii. Set index to index + 1.
            }
        } else {
            // 6. Else,
            // a. Let keysIterator be ? GetIteratorFromMethod(otherRecord.[[SetObject]],
            //    otherRecord.[[Keys]]).
            var keys_iterator = try getIteratorFromMethod(
                agent,
                Value.from(other_record.set_object),
                other_record.keys,
            );

            // b. Let next be not-started.
            // c. Repeat, while next is not done,
            //     i. Set next to ? IteratorStepValue(keysIterator).
            //     ii. If next is not done, then
            while (try keys_iterator.stepValue(agent)) |next_| {
                // 1. Set next to CanonicalizeKeyedCollectionKey(next).
                const next = next_.canonicalizeKeyedCollectionKey();

                // 2. Let valueIndex be SetDataIndex(resultSetData, next).
                const maybe_value_index = setDataIndex(result_set_data, next);

                // 3. If valueIndex is not not-found, then
                if (maybe_value_index) |value_index| {
                    // a. Set resultSetData[valueIndex] to empty.
                    result_set_data.entries.set(value_index, .{
                        .hash = {},
                        .key = .uninitialized,
                        .value = {},
                    });
                    dead_entries += 1;
                }
            }
        }

        if (dead_entries > 0) {
            result_set_data = try compactSetData(
                agent.gc_allocator,
                &result_set_data,
                dead_entries,
            );
        }

        // 7. Let result be OrdinaryObjectCreate(%Set.prototype%, « [[SetData]] »).
        const result = try ordinaryObjectCreateWithType(
            Set,
            agent,
            try agent.currentRealm().intrinsic(.set_prototype),
            .{
                // 8. Set result.[[SetData]] to resultSetData.
                .set_data = result_set_data,
            },
        );

        // 9. Return result.
        return Value.from(&result.object);
    }

    /// 24.2.4.6 Set.prototype.entries ( )
    /// https://tc39.es/ecma262/#sec-set.prototype.entries
    fn entries(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let set be the this value.
        const set = this_value;

        // 2. Return ? CreateSetIterator(set, key+value).
        const set_iterator = try createSetIterator(agent, set, .key_value);
        return Value.from(&set_iterator.object);
    }

    /// 24.2.4.7 Set.prototype.forEach ( callback [ , thisArg ] )
    /// https://tc39.es/ecma262/#sec-set.prototype.foreach
    fn forEach(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const callback_value = arguments.get(0);
        const this_arg = arguments.get(1);

        // 1. Let set be the this value.
        // 2. Perform ? RequireInternalSlot(set, [[SetData]]).
        const set = try this_value.requireInternalSlot(agent, Set);

        // 3. If IsCallable(callback) is false, throw a TypeError exception.
        if (!callback_value.isCallable()) {
            return agent.throwException(.type_error, "{f} is not callable", .{callback_value});
        }
        const callback = callback_value.asObject();

        // 4. Let entries be set.[[SetData]].
        const entries_ = &set.fields.set_data;

        set.fields.active_iterators += 1;
        defer set.fields.active_iterators -= 1;

        // 5. Let entriesCount be the number of elements in entries.
        var entries_count = entries_.count();

        // 6. Let index be 0.
        var index: usize = 0;

        // 7. Repeat, while index < entriesCount,
        while (index < entries_count) : (index += 1) {
            // a. Let entry be entries[index].
            const entry = entries_.entries.get(index);

            // b. Set index to index + 1.

            // c. If entry is not empty, then
            if (!entry.key.isUninitialized()) {
                // i. Perform ? Call(callback, thisArg, « entry, entry, set »).
                _ = try callback.call(
                    agent,
                    this_arg,
                    &.{ entry.key, entry.key, Value.from(&set.object) },
                );

                // ii. NOTE: The number of elements in entries may have increased during execution
                //     of callback.
                // iii. Set entriesCount to the number of elements in entries.
                entries_count = entries_.count();
            }
        }

        // 8. Return undefined.
        return .undefined;
    }

    /// 24.2.4.8 Set.prototype.has ( value )
    /// https://tc39.es/ecma262/#sec-set.prototype.has
    fn has(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        var value = arguments.get(0);

        // 1. Let set be the this value.
        // 2. Perform ? RequireInternalSlot(set, [[SetData]]).
        const set = try this_value.requireInternalSlot(agent, Set);

        // 3. Set value to CanonicalizeKeyedCollectionKey(value).
        value = value.canonicalizeKeyedCollectionKey();

        // 4. For each element entry of set.[[SetData]], do
        //     a. If entry is not empty and SameValue(entry, value) is true, return true.
        // 5. Return false.
        return Value.from(set.fields.set_data.contains(value));
    }

    /// 24.2.4.9 Set.prototype.intersection ( other )
    /// https://tc39.es/ecma262/#sec-set.prototype.intersection
    fn intersection(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const other = arguments.get(0);

        // 1. Let set be the this value.
        // 2. Perform ? RequireInternalSlot(set, [[SetData]]).
        const set = try this_value.requireInternalSlot(agent, Set);

        // 3. Let otherRecord be ? GetSetRecord(other).
        const other_record = try getSetRecord(agent, other);

        // 4. Let resultSetData be a new empty List.
        var result_set_data: SetData = .empty;

        // 5. If SetDataSize(set.[[SetData]]) ≤ otherRecord.[[Size]], then
        if (setDataSize(set.fields.set_data, set.fields.dead_entries) <= other_record.size) {
            // a. Let thisSize be the number of elements in set.[[SetData]].
            var this_size = set.fields.set_data.count();

            // b. Let index be 0.
            var index: usize = 0;

            // c. Repeat, while index < thisSize,
            while (index < this_size) : (index += 1) {
                // i. Let entry be set.[[SetData]][index].
                const entry = set.fields.set_data.entries.get(index);

                // ii. Set index to index + 1.
                // iii. If entry is not empty, then

                // 1. Let inOther be ToBoolean(? Call(otherRecord.[[Has]],
                //    otherRecord.[[SetObject]], « entry »)).
                const in_other = (try other_record.has.call(
                    agent,
                    Value.from(other_record.set_object),
                    &.{entry.key},
                )).toBoolean();

                // 2. If inOther is true, then
                if (in_other) {
                    // a. NOTE: It is possible for earlier calls to otherRecord.[[Has]] to remove
                    //    and re-add an element of set.[[SetData]], which can cause the same element
                    //    to be visited twice during this iteration.
                    // b. If SetDataHas(resultSetData, entry) is false, then
                    //     i. Append entry to resultSetData.
                    // NOTE: We do not need to check because put allows clobbers.
                    try result_set_data.put(agent.gc_allocator, entry.key, {});
                }

                // 3. NOTE: The number of elements in set.[[SetData]] may have increased during
                //    execution of otherRecord.[[Has]].
                // 4. Set thisSize to the number of elements in set.[[SetData]].
                this_size = set.fields.set_data.count();
            }
        } else {
            // 6. Else,
            // a. Let keysIterator be ? GetIteratorFromMethod(otherRecord.[[SetObject]],
            //    otherRecord.[[Keys]]).
            var keys_iterator = try getIteratorFromMethod(
                agent,
                Value.from(other_record.set_object),
                other_record.keys,
            );

            // b. Let next be not-started.
            // c. Repeat, while next is not done,
            //     i. Set next to ? IteratorStepValue(keysIterator).
            //     ii. If next is not done, then
            while (try keys_iterator.stepValue(agent)) |next_| {
                // 1. Set next to CanonicalizeKeyedCollectionKey(next).
                const next = next_.canonicalizeKeyedCollectionKey();

                // 2. Let inThis be SetDataHas(set.[[SetData]], next).
                const in_this = setDataHas(set.fields.set_data, next);

                // 3. If inThis is true, then
                if (in_this) {
                    // a. NOTE: Because other is an arbitrary object, it is possible for its "keys"
                    //    iterator to produce the same value more than once.
                    // b. If SetDataHas(resultSetData, next) is false, then
                    //     i. Append next to resultSetData.
                    // NOTE: We do not need to check because put allows clobbers.
                    try result_set_data.put(agent.gc_allocator, next, {});
                }
            }
        }

        // 7. Let result be OrdinaryObjectCreate(%Set.prototype%, « [[SetData]] »).
        const result = try ordinaryObjectCreateWithType(
            Set,
            agent,
            try agent.currentRealm().intrinsic(.set_prototype),
            .{
                // 8. Set result.[[SetData]] to resultSetData.
                .set_data = result_set_data,
            },
        );

        // 9. Return result.
        return Value.from(&result.object);
    }

    /// 24.2.4.10 Set.prototype.isDisjointFrom ( other )
    /// https://tc39.es/ecma262/#sec-set.prototype.isdisjointfrom
    pub fn isDisjointFrom(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const other = arguments.get(0);

        // 1. Let set be the this value.
        // 2. Perform ? RequireInternalSlot(set, [[SetData]]).
        const set = try this_value.requireInternalSlot(agent, Set);

        // 3. Let otherRecord be ? GetSetRecord(other).
        const other_record = try getSetRecord(agent, other);

        // 4. If SetDataSize(set.[[SetData]]) ≤ otherRecord.[[Size]], then
        if (setDataSize(set.fields.set_data, set.fields.dead_entries) <= other_record.size) {
            // a. Let thisSize be the number of elements in set.[[SetData]].
            var this_size = set.fields.set_data.count();

            // b. Let index be 0.
            var index: usize = 0;

            // c. Repeat, while index < thisSize,
            while (index < this_size) : (index += 1) {
                // i. Let entry be set.[[SetData]][index].
                const entry = set.fields.set_data.entries.get(index);

                // ii. Set index to index + 1.
                // iii. If entry is not empty, then

                // 1. Let inOther be ToBoolean(? Call(otherRecord.[[Has]],
                //    otherRecord.[[SetObject]], « entry »)).
                const in_other = (try other_record.has.call(
                    agent,
                    Value.from(other_record.set_object),
                    &.{entry.key},
                )).toBoolean();

                // 2. If inOther is true, return false.
                if (in_other) {
                    return .false;
                }

                // 3. NOTE: The number of elements in set.[[SetData]] may have increased during
                //    execution of otherRecord.[[Has]].
                // 4. Set thisSize to the number of elements in set.[[SetData]].
                this_size = set.fields.set_data.count();
            }
        } else {
            // 5. Else,
            // a. Let keysIterator be ? GetIteratorFromMethod(otherRecord.[[SetObject]],
            //    otherRecord.[[Keys]]).
            var keys_iterator = try getIteratorFromMethod(
                agent,
                Value.from(other_record.set_object),
                other_record.keys,
            );

            // b. Let next be not-started.
            // c. Repeat, while next is not done,
            //     i. Set next to ? IteratorStepValue(keysIterator).
            //     ii. If next is not done, then
            while (try keys_iterator.stepValue(agent)) |next| {
                // 1. If SetDataHas(set.[[SetData]], next) is true, then
                if (setDataHas(set.fields.set_data, next)) {
                    // a. Perform ? IteratorClose(keysIterator, NormalCompletion(unused)).
                    try keys_iterator.close(agent, @as(Agent.Error!void, {}));

                    // b. Return false.
                    return .false;
                }
            }
        }

        // 6. Return true.
        return .true;
    }

    /// 24.2.4.11 Set.prototype.isSubsetOf ( other )
    /// https://tc39.es/ecma262/#sec-set.prototype.issubsetof
    pub fn isSubsetOf(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const other = arguments.get(0);

        // 1. Let set be the this value.
        // 2. Perform ? RequireInternalSlot(set, [[SetData]]).
        const set = try this_value.requireInternalSlot(agent, Set);

        // 3. Let otherRecord be ? GetSetRecord(other).
        const other_record = try getSetRecord(agent, other);

        // 4. If SetDataSize(set.[[SetData]]) > otherRecord.[[Size]], return false.
        if (setDataSize(set.fields.set_data, set.fields.dead_entries) > other_record.size) {
            return .false;
        }

        // 5. Let thisSize be the number of elements in set.[[SetData]].
        var this_size = set.fields.set_data.count();

        // 6. Let index be 0.
        var index: usize = 0;

        // 7. Repeat, while index < thisSize,
        while (index < this_size) : (index += 1) {
            // a. Let entry be set.[[SetData]][index].
            const entry = set.fields.set_data.entries.get(index);

            // b. Set index to index + 1.
            // c. If entry is not empty, then

            // i. Let inOther be ToBoolean(? Call(otherRecord.[[Has]], otherRecord.[[SetObject]],
            //    « entry »)).
            const in_other = (try other_record.has.call(
                agent,
                Value.from(other_record.set_object),
                &.{entry.key},
            )).toBoolean();

            // ii. If inOther is false, return false.
            if (!in_other) {
                return .false;
            }

            // iii. NOTE: The number of elements in set.[[SetData]] may have increased during
            //      execution of otherRecord.[[Has]].
            // iv. Set thisSize to the number of elements in set.[[SetData]].
            this_size = set.fields.set_data.count();
        }

        // 8. Return true.
        return .true;
    }

    /// 24.2.4.12 Set.prototype.isSupersetOf ( other )
    /// https://tc39.es/ecma262/#sec-set.prototype.issupersetof
    pub fn isSupersetOf(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const other = arguments.get(0);

        // 1. Let set be the this value.
        // 2. Perform ? RequireInternalSlot(set, [[SetData]]).
        const set = try this_value.requireInternalSlot(agent, Set);

        // 3. Let otherRecord be ? GetSetRecord(other).
        const other_record = try getSetRecord(agent, other);

        // 4. If SetDataSize(set.[[SetData]]) < otherRecord.[[Size]], return false.
        if (setDataSize(set.fields.set_data, set.fields.dead_entries) < other_record.size) {
            return .false;
        }

        // 5. Let keysIterator be ? GetIteratorFromMethod(otherRecord.[[SetObject]],
        //    otherRecord.[[Keys]]).
        var keys_iterator = try getIteratorFromMethod(
            agent,
            Value.from(other_record.set_object),
            other_record.keys,
        );

        // 6. Let next be not-started.
        // 7. Repeat, while next is not done,
        //     a. Set next to ? IteratorStepValue(keysIterator).
        //     b. If next is not done, then
        while (try keys_iterator.stepValue(agent)) |next| {
            // i. If SetDataHas(set.[[SetData]], next) is false, then
            if (!setDataHas(set.fields.set_data, next)) {
                // 1. Perform ? IteratorClose(keysIterator, NormalCompletion(unused)).
                try keys_iterator.close(agent, @as(Agent.Error!void, {}));

                // 2. Return false.
                return .false;
            }
        }

        // 8. Return true.
        return .true;
    }

    /// 24.2.4.14 get Set.prototype.size
    /// https://tc39.es/ecma262/#sec-get-set.prototype.size
    fn size(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let set be the this value.
        // 2. Perform ? RequireInternalSlot(set, [[SetData]]).
        const set = try this_value.requireInternalSlot(agent, Set);

        // 3. Let size be SetDataSize(set.[[SetData]]).
        const size_ = setDataSize(set.fields.set_data, set.fields.dead_entries);

        // 4. Return 𝔽(size).
        return Value.from(@as(u53, @intCast(size_)));
    }

    /// 24.2.4.15 Set.prototype.symmetricDifference ( other )
    /// https://tc39.es/ecma262/#sec-set.prototype.symmetricdifference
    pub fn symmetricDifference(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const other = arguments.get(0);

        // 1. Let set be the this value.
        // 2. Perform ? RequireInternalSlot(set, [[SetData]]).
        const set = try this_value.requireInternalSlot(agent, Set);

        // 3. Let otherRecord be ? GetSetRecord(other).
        const other_record = try getSetRecord(agent, other);

        // 4. Let keysIterator be ? GetIteratorFromMethod(otherRecord.[[SetObject]],
        //    otherRecord.[[Keys]]).
        var keys_iterator = try getIteratorFromMethod(
            agent,
            Value.from(other_record.set_object),
            other_record.keys,
        );

        // 5. Let resultSetData be a copy of set.[[SetData]].
        var result_set_data = try set.fields.set_data.clone(agent.gc_allocator);

        var dead_entries: usize = 0;

        // 6. Let next be not-started.
        // 7. Repeat, while next is not done,
        //     a. Set next to ? IteratorStepValue(keysIterator).
        //     b. If next is not done, then
        while (try keys_iterator.stepValue(agent)) |next_| {
            // i. Set next to CanonicalizeKeyedCollectionKey(next).
            const next = next_.canonicalizeKeyedCollectionKey();

            // ii. Let resultIndex be SetDataIndex(resultSetData, next).
            // iii. If resultIndex is not-found, let alreadyInResult be false; else let
            //      alreadyInResult be true.
            const maybe_result_index = setDataIndex(result_set_data, next);

            // iv. If SetDataHas(set.[[SetData]], next) is true, then
            if (setDataHas(set.fields.set_data, next)) {
                // 1. If alreadyInResult is true, set resultSetData[resultIndex] to empty.
                if (maybe_result_index) |result_index| {
                    result_set_data.entries.set(result_index, .{
                        .hash = {},
                        .key = .uninitialized,
                        .value = {},
                    });
                    dead_entries += 1;
                }
            } else {
                // v. Else,
                // 1. If alreadyInResult is false, append next to resultSetData.
                if (maybe_result_index == null) {
                    try result_set_data.put(agent.gc_allocator, next, {});
                }
            }
        }

        if (dead_entries > 0) {
            result_set_data = try compactSetData(
                agent.gc_allocator,
                &result_set_data,
                dead_entries,
            );
        }

        // 8. Let result be OrdinaryObjectCreate(%Set.prototype%, « [[SetData]] »).
        const result = try ordinaryObjectCreateWithType(
            Set,
            agent,
            try agent.currentRealm().intrinsic(.set_prototype),
            .{
                // 9. Set result.[[SetData]] to resultSetData.
                .set_data = result_set_data,
            },
        );

        // 10. Return result.
        return Value.from(&result.object);
    }

    /// 24.2.4.16 Set.prototype.union ( other )
    /// https://tc39.es/ecma262/#sec-set.prototype.union
    fn @"union"(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const other = arguments.get(0);

        // 1. Let set be the this value.
        // 2. Perform ? RequireInternalSlot(set, [[SetData]]).
        const set = try this_value.requireInternalSlot(agent, Set);

        // 3. Let otherRecord be ? GetSetRecord(other).
        const other_record = try getSetRecord(agent, other);

        // 4. Let keysIterator be ? GetIteratorFromMethod(otherRecord.[[SetObject]],
        //    otherRecord.[[Keys]]).
        var keys_iterator = try getIteratorFromMethod(
            agent,
            Value.from(other_record.set_object),
            other_record.keys,
        );

        // 5. Let resultSetData be a copy of set.[[SetData]].
        var result_set_data = try set.fields.set_data.clone(agent.gc_allocator);

        // 6. Let next be not-started.
        // 7. Repeat, while next is not done,
        //     a. Set next to ? IteratorStepValue(keysIterator).
        //     b. If next is not done, then
        while (try keys_iterator.stepValue(agent)) |next_| {
            // i. Set next to CanonicalizeKeyedCollectionKey(next).
            const next = next_.canonicalizeKeyedCollectionKey();

            // ii. If SetDataHas(resultSetData, next) is false, then
            //     1. Append next to resultSetData.
            // NOTE: We do not need to check because put allows clobbers.
            try result_set_data.put(agent.gc_allocator, next, {});
        }

        // 8. Let result be OrdinaryObjectCreate(%Set.prototype%, « [[SetData]] »).
        const result = try ordinaryObjectCreateWithType(
            Set,
            agent,
            try agent.currentRealm().intrinsic(.set_prototype),
            .{
                // 9. Set result.[[SetData]] to resultSetData.
                .set_data = result_set_data,
            },
        );

        // 10. Return result.
        return Value.from(&result.object);
    }

    /// 24.2.4.17 Set.prototype.values ( )
    /// https://tc39.es/ecma262/#sec-set.prototype.values
    fn values(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let set be the this value.
        const set = this_value;

        // 2. Return ? CreateSetIterator(set, value).
        const set_iterator = try createSetIterator(agent, set, .value);
        return Value.from(&set_iterator.object);
    }
};

/// 24.2.5 Properties of Set Instances
/// https://tc39.es/ecma262/#sec-properties-of-set-instances
pub const Set = MakeObject(.{
    .Fields = struct {
        /// [[SetData]]
        set_data: SetData,

        dead_entries: usize = 0,
        active_iterators: usize = 0,

        pub fn compactIfNeeded(self: *@This(), gpa: std.mem.Allocator) std.mem.Allocator.Error!void {
            if (self.active_iterators > 0 or self.dead_entries <= self.set_data.count() / 4) return;
            self.set_data = try compactSetData(gpa, &self.set_data, self.dead_entries);
            self.dead_entries = 0;
        }
    },
    .tag = .set,
    .display_name = "Set",
});
