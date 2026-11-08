//! 24.3 WeakMap Objects
//! https://tc39.es/ecma262/#sec-weakmap-objects

const std = @import("std");

const build_options = @import("build-options");
const builtins = @import("../builtins.zig");
const execution = @import("../execution.zig");
const gc = @import("../gc.zig");
const types = @import("../types.zig");

const Agent = execution.Agent;
const Arguments = types.Arguments;
const MakeObject = types.MakeObject;
const Object = types.Object;
const PropertyKey = types.PropertyKey;
const Realm = execution.Realm;
const Value = types.Value;
const addEntriesFromIterable = builtins.addEntriesFromIterable;
const createBuiltinFunction = builtins.createBuiltinFunction;
const ordinaryCreateFromConstructor = builtins.ordinaryCreateFromConstructor;
const ordinaryObjectCreate = builtins.ordinaryObjectCreate;

/// 24.3.2 Properties of the WeakMap Constructor
/// https://tc39.es/ecma262/#sec-properties-of-the-weakmap-constructor
pub const constructor = struct {
    pub fn create(agent: *Agent, realm: *Realm) std.mem.Allocator.Error!*Object {
        const builtin_function = try createBuiltinFunction(
            agent,
            .{ .constructor = impl },
            0,
            "WeakMap",
            .{ .realm = realm, .proto = try realm.intrinsic(.function_prototype) },
        );
        return &builtin_function.object;
    }

    pub fn init(agent: *Agent, realm: *Realm, object: *Object) std.mem.Allocator.Error!void {
        // 24.3.2.1 WeakMap.prototype
        // https://tc39.es/ecma262/#sec-weakmap.prototype
        try object.defineBuiltinPropertyWithAttributes(
            agent,
            "prototype",
            Value.from(try realm.intrinsic(.weak_map_prototype)),
            .none,
        );
    }

    /// 24.3.1.1 WeakMap ( [ iterable ] )
    /// https://tc39.es/ecma262/#sec-weakmap-iterable
    fn impl(agent: *Agent, arguments: Arguments, maybe_new_target: ?*Object) Agent.Error!Value {
        const iterable = arguments.get(0);

        const new_target = maybe_new_target orelse {
            // 1. If NewTarget is undefined, throw a TypeError exception.
            return agent.throwException(
                .type_error,
                "WeakMap must be constructed with 'new'",
                .{},
            );
        };

        // 2. Let map be ? OrdinaryCreateFromConstructor(NewTarget, "%WeakMap.prototype%",
        //    « [[WeakMapData]] »).
        const map = try ordinaryCreateFromConstructor(
            WeakMap,
            agent,
            new_target,
            .weak_map_prototype,
            .{
                // 3. Set map.[[WeakMapData]] to a new empty List.
                .weak_map_data = .empty,
            },
        );

        // 4. If iterable is either undefined or null, return map.
        if (iterable.isUndefined() or iterable.isNull()) {
            return Value.from(&map.object);
        }

        // 5. Let adder be ? Get(map, "set").
        const adder = try map.object.get(agent, PropertyKey.from("set"));

        // 6. If IsCallable(adder) is false, throw a TypeError exception.
        if (!adder.isCallable()) {
            return agent.throwException(
                .type_error,
                "{f} is not callable",
                .{adder},
            );
        }

        // 7. Return ? AddEntriesFromIterable(map, iterable, adder).
        return Value.from(try addEntriesFromIterable(agent, &map.object, iterable, adder.asObject()));
    }
};

/// 24.3.3 Properties of the WeakMap Prototype Object
/// https://tc39.es/ecma262/#sec-properties-of-the-weakmap-prototype-object
pub const prototype = struct {
    pub fn create(agent: *Agent, realm: *Realm) std.mem.Allocator.Error!*Object {
        return ordinaryObjectCreate(agent, try realm.intrinsic(.object_prototype));
    }

    pub fn init(agent: *Agent, realm: *Realm, object: *Object) std.mem.Allocator.Error!void {
        try object.defineBuiltinFunction(agent, "delete", delete, 1, realm);
        try object.defineBuiltinFunction(agent, "get", get, 1, realm);
        try object.defineBuiltinFunction(agent, "getOrInsert", getOrInsert, 2, realm);
        try object.defineBuiltinFunction(agent, "getOrInsertComputed", getOrInsertComputed, 2, realm);
        try object.defineBuiltinFunction(agent, "has", has, 1, realm);
        try object.defineBuiltinFunction(agent, "set", set, 2, realm);

        // 24.3.3.1 WeakMap.prototype.constructor
        // https://tc39.es/ecma262/#sec-weakmap.prototype.constructor
        try object.defineBuiltinProperty(
            agent,
            "constructor",
            Value.from(try realm.intrinsic(.weak_map)),
        );

        // 24.3.3.8 WeakMap.prototype [ %Symbol.toStringTag% ]
        // https://tc39.es/ecma262/#sec-weakmap.prototype-%symbol.tostringtag%
        try object.defineBuiltinPropertyWithAttributes(
            agent,
            "Symbol.toStringTag",
            Value.from("WeakMap"),
            .{
                .writable = false,
                .enumerable = false,
                .configurable = true,
            },
        );
    }

    /// 24.3.3.2 WeakMap.prototype.delete ( key )
    /// https://tc39.es/ecma262/#sec-weakmap.prototype.delete
    fn delete(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const key = arguments.get(0);

        // 1. Let weakMap be the this value.
        // 2. Perform ? RequireInternalSlot(weakMap, [[WeakMapData]]).
        const weak_map = try this_value.requireInternalSlot(agent, WeakMap);

        // 3. If CanBeHeldWeakly(key) is false, return false.
        if (!key.canBeHeldWeakly(agent)) {
            return .false;
        }

        // 4. For each Record { [[Key]], [[Value]] } entry of weakMap.[[WeakMapData]], do
        //    a. If entry.[[Key]] is not empty and SameValue(entry.[[Key]], key) is true, then
        //       i. Set entry.[[Key]] to empty.
        //       ii. Set entry.[[Value]] to empty.
        //       iii. Return true.
        // 5. Return false.
        const is_removed = weak_map.fields.weak_map_data.remove(Value.Weak.init(key));
        return Value.from(is_removed);
    }

    /// 24.3.3.3 WeakMap.prototype.get ( key )
    /// https://tc39.es/ecma262/#sec-weakmap.prototype.get
    fn get(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const key = arguments.get(0);

        // 1. Let weakMap be the this value.
        // 2. Perform ? RequireInternalSlot(weakMap, [[WeakMapData]]).
        const weak_map = try this_value.requireInternalSlot(agent, WeakMap);

        // 3. If CanBeHeldWeakly(key) is false, return undefined.
        if (!key.canBeHeldWeakly(agent)) {
            return .undefined;
        }

        // 4. For each Record { [[Key]], [[Value]] } entry of weakMap.[[WeakMapData]], do
        // a. If entry.[[Key]] is not empty and SameValue(entry.[[Key]], key) is true, return
        //    entry.[[Value]].
        // 5. Return undefined.
        const maybe_value = weak_map.fields.weak_map_data.get(Value.Weak.init(key));
        return maybe_value orelse .undefined;
    }

    /// 24.3.3.4 WeakMap.prototype.getOrInsert ( key, value )
    /// https://tc39.es/ecma262/#sec-weakmap.prototype.getorinsert
    fn getOrInsert(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const key = arguments.get(0);
        const value = arguments.get(1);

        // 1. Let weakMap be the this value.
        // 2. Perform ? RequireInternalSlot(weakMap, [[WeakMapData]]).
        const weak_map = try this_value.requireInternalSlot(agent, WeakMap);

        // 3. If CanBeHeldWeakly(key) is false, throw a TypeError exception.
        if (!key.canBeHeldWeakly(agent)) {
            return agent.throwException(.type_error, "Value {f} cannot be held weakly", .{key});
        }

        // 4. For each Record { [[Key]], [[Value]] } entry of weakMap.[[WeakMapData]], do
        //     a. If entry.[[Key]] is not empty and SameValue(entry.[[Key]], key) is true, return
        //        entry.[[Value]].
        const weak_map_data = &weak_map.fields.weak_map_data;
        const weak_key = Value.Weak.init(key);
        const gop = try weak_map_data.getOrPut(agent.gc_allocator, weak_key);
        if (gop.found_existing) return gop.value_ptr.*;

        // 5. Let entry be the Record { [[Key]]: key, [[Value]]: value }.
        // 6. Append entry to weakMap.[[WeakMapData]].
        gop.value_ptr.* = value;
        try registerFinalizer(agent, weak_key, weak_map_data);

        // 7. Return value.
        return value;
    }

    /// 24.3.3.5 WeakMap.prototype.getOrInsertComputed ( key, callback )
    /// https://tc39.es/ecma262/#sec-weakmap.prototype.getorinsertcomputed
    fn getOrInsertComputed(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        var key = arguments.get(0);
        const callback_value = arguments.get(1);

        // 1. Let weakMap be the this value.
        // 2. Perform ? RequireInternalSlot(weakMap, [[WeakMapData]]).
        const weak_map = try this_value.requireInternalSlot(agent, WeakMap);

        // 3. If CanBeHeldWeakly(key) is false, throw a TypeError exception.
        if (!key.canBeHeldWeakly(agent)) {
            return agent.throwException(.type_error, "Value {f} cannot be held weakly", .{key});
        }

        // 4. If IsCallable(callback) is false, throw a TypeError exception.
        if (!callback_value.isCallable()) {
            return agent.throwException(.type_error, "{f} is not callable", .{callback_value});
        }
        const callback = callback_value.asObject();

        // 5. For each Record { [[Key]], [[Value]] } entry of weakMap.[[WeakMapData]], do
        //     a. If entry.[[Key]] is not empty and SameValue(entry.[[Key]], key) is true, return
        //        entry.[[Value]].
        const weak_map_data = &weak_map.fields.weak_map_data;
        const weak_key = Value.Weak.init(key);
        if (weak_map_data.get(weak_key)) |value| return value;

        // 6. Let value be ? Call(callback, undefined, « key »).
        const value = try callback.call(agent, .undefined, &.{key});

        // 7. NOTE: The WeakMap may have been modified during execution of callback.
        // 8. For each Record { [[Key]], [[Value]] } entry of weakMap.[[WeakMapData]], do
        //     a. If entry.[[Key]] is not empty and SameValue(entry.[[Key]], key) is true, then
        //         i. Set entry.[[Value]] to value.
        //         ii. Return value.
        // 9. Let entry be the Record { [[Key]]: key, [[Value]]: value }.
        // 10. Append entry to weakMap.[[WeakMapData]].
        const gop = try weak_map_data.getOrPut(agent.gc_allocator, weak_key);
        gop.value_ptr.* = value;
        if (!gop.found_existing) {
            try registerFinalizer(agent, weak_key, weak_map_data);
        }

        // 11. Return value.
        return value;
    }

    /// 24.3.3.6 WeakMap.prototype.has ( key )
    /// https://tc39.es/ecma262/#sec-weakmap.prototype.has
    fn has(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const key = arguments.get(0);

        // 1. Let weakMap be the this value.
        // 2. Perform ? RequireInternalSlot(weakMap, [[WeakMapData]]).
        const weak_map = try this_value.requireInternalSlot(agent, WeakMap);

        // 3. If CanBeHeldWeakly(key) is false, return false.
        if (!key.canBeHeldWeakly(agent)) {
            return .false;
        }

        // 4. For each Record { [[Key]], [[Value]] } entry of weakMap.[[WeakMapData]], do
        // a. If entry.[[Key]] is not empty and SameValue(entry.[[Key]], key) is true, return true.
        // 5. Return false.
        const is_present = weak_map.fields.weak_map_data.contains(Value.Weak.init(key));
        return Value.from(is_present);
    }

    /// 24.3.3.7 WeakMap.prototype.set ( key, value )
    /// https://tc39.es/ecma262/#sec-weakmap.prototype.set
    fn set(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const key = arguments.get(0);
        const value = arguments.get(1);

        // 1. Let weakMap be the this value.
        // 2. Perform ? RequireInternalSlot(weakMap, [[WeakMapData]]).
        const weak_map = try this_value.requireInternalSlot(agent, WeakMap);

        // 3. If CanBeHeldWeakly(key) is false, throw a TypeError exception.
        if (!key.canBeHeldWeakly(agent)) {
            return agent.throwException(
                .type_error,
                "Value {f} cannot be held weakly",
                .{key},
            );
        }

        // 4. For each Record { [[Key]], [[Value]] } entry of weakMap.[[WeakMapData]], do
        //    a. If entry.[[Key]] is not empty and SameValue(entry.[[Key]], key) is true, then
        //       i. Set entry.[[Value]] to value.
        //       ii. Return weakMap.
        // 5. Let entry be the Record { [[Key]]: key, [[Value]]: value }.
        // 6. Append entry to weakMap.[[WeakMapData]].
        const weak_map_data = &weak_map.fields.weak_map_data;
        const weak_key = Value.Weak.init(key);
        const gop = try weak_map_data.getOrPut(agent.gc_allocator, weak_key);
        gop.value_ptr.* = value;
        if (!gop.found_existing) {
            try registerFinalizer(agent, weak_key, weak_map_data);
        }

        // 7. Return weakMap.
        return this_value;
    }

    const CleanupEntryData = struct {
        key: Value.Weak,
        weak_map_data: *WeakMapData,
    };

    /// Implements 9.9.3 Execution step 1.c
    /// https://tc39.es/ecma262/#sec-weakref-execution
    fn registerFinalizer(
        agent: *Agent,
        weak_key: Value.Weak,
        weak_map_data: *WeakMapData,
    ) std.mem.Allocator.Error!void {
        if (!build_options.enable_libgc) return;
        const finalizer_data = try agent.gc_allocator.create(gc.FinalizerData(CleanupEntryData));
        finalizer_data.* = .{ .data = .{
            .key = weak_key,
            .weak_map_data = weak_map_data,
        } };
        gc.registerFinalizer(weak_key.getPtr(), finalizer_data, struct {
            pub fn finalizer(_: *anyopaque, data: *CleanupEntryData) void {
                // i. Set entry.[[Key]] to empty.
                // ii. Set entry.[[Value]] to empty.
                _ = data.weak_map_data.*.remove(data.key);
            }
        }.finalizer);
    }
};

const WeakMapData = Value.Weak.HashMap(Value);

/// 24.3.4 Properties of WeakMap Instances
/// https://tc39.es/ecma262/#sec-properties-of-weakmap-instances
pub const WeakMap = MakeObject(.{
    .Fields = struct {
        /// [[WeakMapData]]
        weak_map_data: WeakMapData,
    },
    .tag = .weak_map,
    .display_name = "WeakMap",
});
