//! 24.1 Map Objects
//! https://tc39.es/ecma262/#sec-map-objects

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
const createArrayFromList = types.createArrayFromList;
const createBuiltinFunction = builtins.createBuiltinFunction;
const createMapIterator = builtins.createMapIterator;
const getIterator = types.getIterator;
const noexcept = utils.noexcept;
const ordinaryCreateFromConstructor = builtins.ordinaryCreateFromConstructor;
const sameValue = types.sameValue;
const ordinaryObjectCreate = builtins.ordinaryObjectCreate;

const MapData = std.array_hash_map.Custom(Value, Value, struct {
    pub fn hash(_: @This(), key: Value) u32 {
        if (key.isUninitialized()) return 0;
        return key.hash();
    }
    pub fn eql(_: @This(), a: Value, b: Value, _: usize) bool {
        if (a.isUninitialized() or b.isUninitialized()) return false;
        return sameValue(a, b);
    }
}, false);

fn compactMapData(
    gpa: std.mem.Allocator,
    map_data: *MapData,
    dead_entries: usize,
) std.mem.Allocator.Error!MapData {
    var compacted: MapData = .empty;
    try compacted.ensureUnusedCapacity(gpa, map_data.count() - dead_entries);
    for (map_data.keys(), map_data.values()) |key, value| {
        if (!key.isUninitialized()) {
            compacted.putAssumeCapacity(key, value);
        }
    }
    map_data.deinit(gpa);
    return compacted;
}

/// 24.1.1.2 AddEntriesFromIterable ( target, iterable, adder )
/// https://tc39.es/ecma262/#sec-add-entries-from-iterable
pub fn addEntriesFromIterable(
    agent: *Agent,
    target: *Object,
    iterable: Value,
    adder: *Object,
) Agent.Error!*Object {
    std.debug.assert(adder.internalMethods().call != null);

    // 1. Let iteratorRecord be ? GetIterator(iterable, sync).
    var iterator = try getIterator(agent, iterable, .sync);

    // 2. Repeat,
    //     a. Let next be ? IteratorStepValue(iteratorRecord).
    //     b. If next is done, return target.
    while (try iterator.stepValue(agent)) |next| {
        // c. If next is not an Object, then
        if (!next.isObject()) {
            // i. Let error be ThrowCompletion(a newly created TypeError object).
            const @"error" = agent.throwException(
                .type_error,
                "Iterable must return object items",
                .{},
            );

            // ii. Return ? IteratorClose(iteratorRecord, error).
            return iterator.close(agent, @as(Agent.Error!*Object, @"error"));
        }

        // d. Let key be Completion(Get(next, "0")).
        const key = next.asObject().get(agent, PropertyKey.from(0)) catch |err| {
            // e. IfAbruptCloseIterator(key, iteratorRecord).
            return iterator.close(agent, @as(Agent.Error!*Object, err));
        };

        // f. Let value be Completion(Get(next, "1")).
        const value = next.asObject().get(agent, PropertyKey.from(1)) catch |err| {
            // g. IfAbruptCloseIterator(value, iteratorRecord).
            return iterator.close(agent, @as(Agent.Error!*Object, err));
        };

        // h. Let status be Completion(Call(adder, target, « key, value »)).
        _ = adder.call(agent, Value.from(target), &.{ key, value }) catch |err| {
            // i. IfAbruptCloseIterator(status, iteratorRecord).
            return iterator.close(agent, @as(Agent.Error!*Object, err));
        };
    }

    return target;
}

/// 24.1.2 Properties of the Map Constructor
/// https://tc39.es/ecma262/#sec-properties-of-the-map-constructor
pub const constructor = struct {
    pub fn create(agent: *Agent, realm: *Realm) std.mem.Allocator.Error!*Object {
        const builtin_function = try createBuiltinFunction(
            agent,
            .{ .constructor = impl },
            0,
            "Map",
            .{ .realm = realm, .proto = try realm.intrinsic(.function_prototype) },
        );
        return &builtin_function.object;
    }

    pub fn init(agent: *Agent, realm: *Realm, object: *Object) std.mem.Allocator.Error!void {
        try object.defineBuiltinFunction(agent, "groupBy", groupBy, 2, realm);
        try object.defineBuiltinAccessor(agent, "Symbol.species", @"Symbol.species", null, realm);

        // 24.1.2.2 Map.prototype
        // https://tc39.es/ecma262/#sec-map.prototype
        try object.defineBuiltinPropertyWithAttributes(
            agent,
            "prototype",
            Value.from(try realm.intrinsic(.map_prototype)),
            .none,
        );
    }

    /// 24.1.1.1 Map ( [ iterable ] )
    /// https://tc39.es/ecma262/#sec-map-iterable
    fn impl(agent: *Agent, arguments: Arguments, new_target: ?*Object) Agent.Error!Value {
        const iterable = arguments.get(0);

        // 1. If NewTarget is undefined, throw a TypeError exception.
        if (new_target == null) {
            return agent.throwException(.type_error, "Map must be constructed with 'new'", .{});
        }

        // 2. Let map be ? OrdinaryCreateFromConstructor(NewTarget, "%Map.prototype%",
        //    « [[MapData]] »).
        const map = try ordinaryCreateFromConstructor(
            Map,
            agent,
            new_target.?,
            .map_prototype,
            .{
                // 3. Set map.[[MapData]] to a new empty List.
                .map_data = .empty,
            },
        );

        // 4. If iterable is either undefined or null, return map.
        if (iterable.isUndefined() or iterable.isNull()) return Value.from(&map.object);

        // 5. Let adder be ? Get(map, "set").
        const adder = try map.object.get(agent, PropertyKey.from("set"));

        // 6. If IsCallable(adder) is false, throw a TypeError exception.
        if (!adder.isCallable()) {
            return agent.throwException(.type_error, "{f} is not callable", .{adder});
        }

        // 7. Return ? AddEntriesFromIterable(map, iterable, adder).
        return Value.from(try addEntriesFromIterable(agent, &map.object, iterable, adder.asObject()));
    }

    /// 24.1.2.1 Map.groupBy ( items, callback )
    /// https://tc39.es/ecma262/#sec-map.groupby
    fn groupBy(agent: *Agent, _: Value, arguments: Arguments) Agent.Error!Value {
        const realm = agent.currentRealm();
        const items = arguments.get(0);
        const callback = arguments.get(1);

        // 1. Let groups be ? GroupBy(items, callback, collection).
        const groups = try items.groupBy(agent, callback, .collection);

        // 2. Let map be ! Construct(%Map%).
        const map_object = (try realm.intrinsic(.map)).construct(
            agent,
            &.{},
            null,
        ) catch |err| try noexcept(err);
        const map = map_object.as(Map);

        // 3. For each Record { [[Key]], [[Elements]] } group of groups, do
        var it = groups.iterator();
        while (it.next()) |entry| {
            // a. Let elements be CreateArrayFromList(group.[[Elements]]).
            const elements = try createArrayFromList(agent, entry.value_ptr.items);

            // b. Let entry be the Record { [[Key]]: group.[[Key]], [[Value]]: elements }.
            // c. Append entry to map.[[MapData]].
            try map.fields.map_data.putNoClobber(
                agent.gc_allocator,
                entry.key_ptr.*,
                Value.from(&elements.object),
            );
        }

        // 4. Return map.
        return Value.from(&map.object);
    }

    /// 24.1.2.3 get Map [ %Symbol.species% ]
    /// https://tc39.es/ecma262/#sec-get-map-%symbol.species%
    fn @"Symbol.species"(_: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Return the this value.
        return this_value;
    }
};

/// 24.1.3 Properties of the Map Prototype Object
/// https://tc39.es/ecma262/#sec-properties-of-the-map-prototype-object
pub const prototype = struct {
    pub fn create(agent: *Agent, realm: *Realm) std.mem.Allocator.Error!*Object {
        return ordinaryObjectCreate(agent, try realm.intrinsic(.object_prototype));
    }

    pub fn init(agent: *Agent, realm: *Realm, object: *Object) std.mem.Allocator.Error!void {
        try object.defineBuiltinFunction(agent, "clear", clear, 0, realm);
        try object.defineBuiltinFunction(agent, "delete", delete, 1, realm);
        try object.defineBuiltinFunction(agent, "entries", entries, 0, realm);
        try object.defineBuiltinFunction(agent, "forEach", forEach, 1, realm);
        try object.defineBuiltinFunction(agent, "get", get, 1, realm);
        try object.defineBuiltinFunction(agent, "getOrInsert", getOrInsert, 2, realm);
        try object.defineBuiltinFunction(agent, "getOrInsertComputed", getOrInsertComputed, 2, realm);
        try object.defineBuiltinFunction(agent, "has", has, 1, realm);
        try object.defineBuiltinFunction(agent, "keys", keys, 0, realm);
        try object.defineBuiltinFunction(agent, "set", set, 2, realm);
        try object.defineBuiltinAccessor(agent, "size", size, null, realm);
        try object.defineBuiltinFunction(agent, "values", values, 0, realm);

        // 24.1.3.2 Map.prototype.constructor
        // https://tc39.es/ecma262/#sec-map.prototype.constructor
        try object.defineBuiltinProperty(
            agent,
            "constructor",
            Value.from(try realm.intrinsic(.map)),
        );

        // 24.1.3.14 Map.prototype [ %Symbol.iterator% ] ( )
        // https://tc39.es/ecma262/#sec-map.prototype-%symbol.iterator%
        const map_prototype_entries = object.getPropertyValueDirect(PropertyKey.from("entries"));
        try object.defineBuiltinProperty(agent, "Symbol.iterator", map_prototype_entries);

        // 24.1.3.15 Map.prototype [ %Symbol.toStringTag% ]
        // https://tc39.es/ecma262/#sec-map.prototype-%symbol.tostringtag%
        try object.defineBuiltinPropertyWithAttributes(
            agent,
            "Symbol.toStringTag",
            Value.from("Map"),
            .{
                .writable = false,
                .enumerable = false,
                .configurable = true,
            },
        );
    }

    /// 24.1.3.1 Map.prototype.clear ( )
    /// https://tc39.es/ecma262/#sec-map.prototype.clear
    fn clear(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let map be the this value.
        // 2. Perform ? RequireInternalSlot(map, [[MapData]]).
        const map = try this_value.requireInternalSlot(agent, Map);

        // 3. For each Record { [[Key]], [[Value]] } entry of map.[[MapData]], do
        //     a. Set entry.[[Key]] to empty.
        //     b. Set entry.[[Value]] to empty.
        @memset(map.fields.map_data.keys(), .uninitialized);
        @memset(map.fields.map_data.values(), undefined);
        map.fields.dead_entries = map.fields.map_data.count();
        try map.fields.compactIfNeeded(agent.gc_allocator);

        // 4. Return undefined.
        return .undefined;
    }

    /// 24.1.3.3 Map.prototype.delete ( key )
    /// https://tc39.es/ecma262/#sec-map.prototype.delete
    fn delete(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        var key = arguments.get(0);

        // 1. Let map be the this value.
        // 2. Perform ? RequireInternalSlot(map, [[MapData]]).
        const map = try this_value.requireInternalSlot(agent, Map);

        // 3. Set key to CanonicalizeKeyedCollectionKey(key).
        key = key.canonicalizeKeyedCollectionKey();

        // 4. For each Record { [[Key]], [[Value]] } entry of map.[[MapData]], do
        //     a. If entry.[[Key]] is not empty and SameValue(entry.[[Key]], key) is true, then
        if (map.fields.map_data.getIndex(key)) |index| {
            // i. Set entry.[[Key]] to empty.
            // ii. Set entry.[[Value]] to empty.
            map.fields.map_data.entries.set(index, .{
                .hash = {},
                .key = .uninitialized,
                .value = undefined,
            });
            map.fields.dead_entries += 1;
            try map.fields.compactIfNeeded(agent.gc_allocator);

            // iii. Return true.
            return .true;
        }

        // 5. Return false.
        return .false;
    }

    /// 24.1.3.4 Map.prototype.entries ( )
    /// https://tc39.es/ecma262/#sec-map.prototype.entries
    fn entries(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let map be the this value.
        const map = this_value;

        // 2. Return ? CreateMapIterator(map, key+value).
        const map_iterator = try createMapIterator(agent, map, .key_value);
        return Value.from(&map_iterator.object);
    }

    /// 24.1.3.5 Map.prototype.forEach ( callback [ , thisArg ] )
    /// https://tc39.es/ecma262/#sec-map.prototype.foreach
    fn forEach(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const callback_value = arguments.get(0);
        const this_arg = arguments.get(1);

        // 1. Let map be the this value.
        // 2. Perform ? RequireInternalSlot(map, [[MapData]]).
        const map = try this_value.requireInternalSlot(agent, Map);

        // 3. If IsCallable(callback) is false, throw a TypeError exception.
        if (!callback_value.isCallable()) {
            return agent.throwException(.type_error, "{f} is not callable", .{callback_value});
        }
        const callback = callback_value.asObject();

        map.fields.active_iterators += 1;
        defer map.fields.active_iterators -= 1;

        // 4. Let entries be map.[[MapData]].
        const entries_ = &map.fields.map_data;

        // 5. Let entriesCount be the number of elements in entries.
        var entries_count = entries_.count();

        // 6. Let index be 0.
        var index: usize = 0;

        // 7. Repeat, while index < entriesCount,
        while (index < entries_count) : (index += 1) {
            // a. Let entry be entries[index].
            const entry = entries_.entries.get(index);

            // b. Set index to index + 1.

            // c. If entry.[[Key]] is not empty, then
            if (!entry.key.isUninitialized()) {
                // i. Perform ? Call(callback, thisArg, « entry.[[Value]], entry.[[Key]], map »).
                _ = try callback.call(
                    agent,
                    this_arg,
                    &.{ entry.value, entry.key, Value.from(&map.object) },
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

    /// 24.1.3.6 Map.prototype.get ( key )
    /// https://tc39.es/ecma262/#sec-map.prototype.get
    fn get(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        var key = arguments.get(0);

        // 1. Let map be the this value.
        // 2. Perform ? RequireInternalSlot(map, [[MapData]]).
        const map = try this_value.requireInternalSlot(agent, Map);

        // 3. Set key to CanonicalizeKeyedCollectionKey(key).
        key = key.canonicalizeKeyedCollectionKey();

        // 4. For each Record { [[Key]], [[Value]] } entry of map.[[MapData]], do
        //     a. If entry.[[Key]] is not empty and SameValue(entry.[[Key]], key) is true, return
        //        entry.[[Value]].
        if (map.fields.map_data.get(key)) |value| return value;

        // 5. Return undefined.
        return .undefined;
    }

    /// 24.1.3.7 Map.prototype.getOrInsert ( key, value )
    /// https://tc39.es/ecma262/#sec-map.prototype.getorinsert
    fn getOrInsert(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        var key = arguments.get(0);
        const value = arguments.get(1);

        // 1. Let map be the this value.
        // 2. Perform ? RequireInternalSlot(map, [[MapData]]).
        const map = try this_value.requireInternalSlot(agent, Map);

        // 3. Set key to CanonicalizeKeyedCollectionKey(key).
        key = key.canonicalizeKeyedCollectionKey();

        // 4. For each Record { [[Key]], [[Value]] } entry of map.[[MapData]], do
        //     a. If entry.[[Key]] is not empty and SameValue(entry.[[Key]], key) is true, return
        //        entry.[[Value]].
        const gop = try map.fields.map_data.getOrPut(agent.gc_allocator, key);
        if (gop.found_existing) return gop.value_ptr.*;

        // 5. Let entry be the Record { [[Key]]: key, [[Value]]: value }.
        // 6. Append entry to map.[[MapData]].
        gop.value_ptr.* = value;

        // 7. Return value.
        return value;
    }

    /// 24.1.3.8 Map.prototype.getOrInsertComputed ( key, callback )
    /// https://tc39.es/ecma262/#sec-map.prototype.getorinsertcomputed
    fn getOrInsertComputed(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        var key = arguments.get(0);
        const callback_value = arguments.get(1);

        // 1. Let map be the this value.
        // 2. Perform ? RequireInternalSlot(map, [[MapData]]).
        const map = try this_value.requireInternalSlot(agent, Map);

        // 3. If IsCallable(callback) is false, throw a TypeError exception.
        if (!callback_value.isCallable()) {
            return agent.throwException(.type_error, "{f} is not callable", .{callback_value});
        }
        const callback = callback_value.asObject();

        // 4. Set key to CanonicalizeKeyedCollectionKey(key).
        key = key.canonicalizeKeyedCollectionKey();

        // 5. For each Record { [[Key]], [[Value]] } entry of map.[[MapData]], do
        //     a. If entry.[[Key]] is not empty and SameValue(entry.[[Key]], key) is true, return
        //        entry.[[Value]].
        if (map.fields.map_data.get(key)) |value| return value;

        // 6. Let value be ? Call(callback, undefined, « key »).
        const value = try callback.call(agent, .undefined, &.{key});

        // 7. NOTE: The Map may have been modified during execution of callback.
        // 8. For each Record { [[Key]], [[Value]] } entry of map.[[MapData]], do
        //     a. If entry.[[Key]] is not empty and SameValue(entry.[[Key]], key) is true, then
        //         i. Set entry.[[Value]] to value.
        //         ii. Return value.
        // 9. Let entry be the Record { [[Key]]: key, [[Value]]: value }.
        // 10. Append entry to map.[[MapData]].
        try map.fields.map_data.put(agent.gc_allocator, key, value);

        // 11. Return value.
        return value;
    }

    /// 24.1.3.9 Map.prototype.has ( key )
    /// https://tc39.es/ecma262/#sec-map.prototype.has
    fn has(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        var key = arguments.get(0);

        // 1. Let map be the this value.
        // 2. Perform ? RequireInternalSlot(map, [[MapData]]).
        const map = try this_value.requireInternalSlot(agent, Map);

        // 3. Set key to CanonicalizeKeyedCollectionKey(key).
        key = key.canonicalizeKeyedCollectionKey();

        // 4. For each Record { [[Key]], [[Value]] } entry of map.[[MapData]], do
        //     a. If entry.[[Key]] is not empty and SameValue(entry.[[Key]], key) is true, return
        //        true.
        // 5. Return false.
        return Value.from(map.fields.map_data.contains(key));
    }

    /// 24.1.3.10 Map.prototype.keys ( )
    /// https://tc39.es/ecma262/#sec-map.prototype.keys
    fn keys(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let map be the this value.
        const map = this_value;

        // 2. Return ? CreateMapIterator(map, key).
        const map_iterator = try createMapIterator(agent, map, .key);
        return Value.from(&map_iterator.object);
    }

    /// 24.1.3.11 Map.prototype.set ( key, value )
    /// https://tc39.es/ecma262/#sec-map.prototype.set
    fn set(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        var key = arguments.get(0);
        const value = arguments.get(1);

        // 1. Let map be the this value.
        // 2. Perform ? RequireInternalSlot(map, [[MapData]]).
        const map = try this_value.requireInternalSlot(agent, Map);

        // 3. Set key to CanonicalizeKeyedCollectionKey(key).
        key = key.canonicalizeKeyedCollectionKey();

        // 4. For each Record { [[Key]], [[Value]] } entry of map.[[MapData]], do
        //     a. If entry.[[Key]] is not empty and SameValue(entry.[[Key]], key) is true, then
        //         i. Set entry.[[Value]] to value.
        //         ii. Return map.
        // 5. Let entry be the Record { [[Key]]: key, [[Value]]: value }.
        // 6. Append entry to map.[[MapData]].
        try map.fields.map_data.put(agent.gc_allocator, key, value);

        // 7. Return map.
        return Value.from(&map.object);
    }

    /// 24.1.3.12 get Map.prototype.size
    /// https://tc39.es/ecma262/#sec-get-map.prototype.size
    fn size(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let map be the this value.
        // 2. Perform ? RequireInternalSlot(map, [[MapData]]).
        const map = try this_value.requireInternalSlot(agent, Map);

        // 3. Let count be 0.
        // 4. For each Record { [[Key]], [[Value]] } entry of map.[[MapData]], do
        //     a. If entry.[[Key]] is not empty, set count to count + 1.
        const count = map.fields.map_data.count() - map.fields.dead_entries;

        // 5. Return 𝔽(count).
        return Value.from(@as(u53, @intCast(count)));
    }

    /// 24.1.3.13 Map.prototype.values ( )
    /// https://tc39.es/ecma262/#sec-map.prototype.values
    fn values(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let map be the this value.
        const map = this_value;

        // 2. Return ? CreateMapIterator(map, value).
        const map_iterator = try createMapIterator(agent, map, .value);
        return Value.from(&map_iterator.object);
    }
};

/// 24.1.4 Properties of Map Instances
/// https://tc39.es/ecma262/#sec-properties-of-map-instances
pub const Map = MakeObject(.{
    .Fields = struct {
        /// [[MapData]]
        map_data: MapData,

        dead_entries: usize = 0,
        active_iterators: usize = 0,

        pub fn compactIfNeeded(self: *@This(), gpa: std.mem.Allocator) std.mem.Allocator.Error!void {
            if (self.active_iterators > 0 or self.dead_entries <= self.map_data.count() / 4) return;
            self.map_data = try compactMapData(gpa, &self.map_data, self.dead_entries);
            self.dead_entries = 0;
        }
    },
    .tag = .map,
    .display_name = "Map",
});
