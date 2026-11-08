//! 24.4 WeakSet Objects
//! https://tc39.es/ecma262/#sec-weakset-objects

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
const createBuiltinFunction = builtins.createBuiltinFunction;
const getIterator = types.getIterator;
const ordinaryCreateFromConstructor = builtins.ordinaryCreateFromConstructor;
const ordinaryObjectCreate = builtins.ordinaryObjectCreate;

/// 24.4.2 Properties of the WeakSet Constructor
/// https://tc39.es/ecma262/#sec-properties-of-the-weakset-constructor
pub const constructor = struct {
    pub fn create(agent: *Agent, realm: *Realm) std.mem.Allocator.Error!*Object {
        const builtin_function = try createBuiltinFunction(
            agent,
            .{ .constructor = impl },
            0,
            "WeakSet",
            .{ .realm = realm, .proto = try realm.intrinsic(.function_prototype) },
        );
        return &builtin_function.object;
    }

    pub fn init(agent: *Agent, realm: *Realm, object: *Object) std.mem.Allocator.Error!void {
        // 24.4.2.1 WeakSet.prototype
        // https://tc39.es/ecma262/#sec-weakset.prototype
        try object.defineBuiltinPropertyWithAttributes(
            agent,
            "prototype",
            Value.from(try realm.intrinsic(.weak_set_prototype)),
            .none,
        );
    }

    /// 24.4.1.1 WeakSet ( [ iterable ] )
    /// https://tc39.es/ecma262/#sec-weakset-iterable
    fn impl(agent: *Agent, arguments: Arguments, maybe_new_target: ?*Object) Agent.Error!Value {
        const iterable = arguments.get(0);

        const new_target = maybe_new_target orelse {
            // 1. If NewTarget is undefined, throw a TypeError exception.
            return agent.throwException(
                .type_error,
                "WeakSet must be constructed with 'new'",
                .{},
            );
        };

        // 2. Let set be ? OrdinaryCreateFromConstructor(NewTarget, "%WeakSet.prototype%",
        //    « [[WeakSetData]] »).
        const set = try ordinaryCreateFromConstructor(
            WeakSet,
            agent,
            new_target,
            .weak_set_prototype,
            .{
                // 3. Set set.[[WeakSetData]] to a new empty List.
                .weak_set_data = .empty,
            },
        );

        // 4. If iterable is either undefined or null, return set.
        if (iterable.isUndefined() or iterable.isNull()) {
            return Value.from(&set.object);
        }

        // 5. Let adder be ? Get(set, "add").
        const adder_value = try set.object.get(agent, PropertyKey.from("add"));

        // 6. If IsCallable(adder) is false, throw a TypeError exception.
        if (!adder_value.isCallable()) {
            return agent.throwException(
                .type_error,
                "{f} is not callable",
                .{adder_value},
            );
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
};

/// 24.4.3 Properties of the WeakSet Prototype Object
/// https://tc39.es/ecma262/#sec-properties-of-the-weakset-prototype-object
pub const prototype = struct {
    pub fn create(agent: *Agent, realm: *Realm) std.mem.Allocator.Error!*Object {
        return ordinaryObjectCreate(agent, try realm.intrinsic(.object_prototype));
    }

    pub fn init(agent: *Agent, realm: *Realm, object: *Object) std.mem.Allocator.Error!void {
        try object.defineBuiltinFunction(agent, "add", add, 1, realm);
        try object.defineBuiltinFunction(agent, "delete", delete, 1, realm);
        try object.defineBuiltinFunction(agent, "has", has, 1, realm);

        // 24.4.3.2 WeakSet.prototype.constructor
        // https://tc39.es/ecma262/#sec-weakset.prototype.constructor
        try object.defineBuiltinProperty(
            agent,
            "constructor",
            Value.from(try realm.intrinsic(.weak_set)),
        );

        // 24.4.3.5 WeakSet.prototype [ %Symbol.toStringTag% ]
        // https://tc39.es/ecma262/#sec-weakset.prototype-%symbol.tostringtag%
        try object.defineBuiltinPropertyWithAttributes(
            agent,
            "Symbol.toStringTag",
            Value.from("WeakSet"),
            .{
                .writable = false,
                .enumerable = false,
                .configurable = true,
            },
        );
    }

    /// 24.4.3.1 WeakSet.prototype.add ( value )
    /// https://tc39.es/ecma262/#sec-weakset.prototype.add
    fn add(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const value = arguments.get(0);

        // 1. Let weakSet be the this value.
        // 2. Perform ? RequireInternalSlot(weakSet, [[WeakSetData]]).
        const weak_set = try this_value.requireInternalSlot(agent, WeakSet);

        // 3. If CanBeHeldWeakly(value) is false, throw a TypeError exception.
        if (!value.canBeHeldWeakly(agent)) {
            return agent.throwException(
                .type_error,
                "Value {f} cannot be held weakly",
                .{value},
            );
        }

        // 4. For each element entry of weakSet.[[WeakSetData]], do
        //    a. If entry is not empty and SameValue(entry, value) is true, then
        //       i. Return weakSet.
        // 5. Append value to weakSet.[[WeakSetData]].
        const weak_set_data = &weak_set.fields.weak_set_data;
        const weak_value = Value.Weak.init(value);
        const gop = try weak_set_data.getOrPut(agent.gc_allocator, weak_value);
        if (build_options.enable_libgc and !gop.found_existing) {
            // Implements 9.9.3 Execution step 1.d
            // https://tc39.es/ecma262/#sec-weakref-execution
            const finalizer_data = try agent.gc_allocator.create(gc.FinalizerData(CleanupValueData));
            finalizer_data.* = .{ .data = .{
                .value = weak_value,
                .weak_set_data = weak_set_data,
            } };
            gc.registerFinalizer(weak_value.getPtr(), finalizer_data, struct {
                pub fn finalizer(_: *anyopaque, data: *CleanupValueData) void {
                    // i. Replace the element of set.[[WeakSetData]] whose value
                    //    is value with an element whose value is empty.
                    _ = data.weak_set_data.*.remove(data.value);
                }
            }.finalizer);
        }

        // 6. Return weakSet.
        return this_value;
    }

    const CleanupValueData = struct {
        value: Value.Weak,
        weak_set_data: *WeakSetData,
    };

    /// 24.4.3.3 WeakSet.prototype.delete ( value )
    /// https://tc39.es/ecma262/#sec-weakset.prototype.delete
    fn delete(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const value = arguments.get(0);

        // 1. Let weakSet be the this value.
        // 2. Perform ? RequireInternalSlot(weakSet, [[WeakSetData]]).
        const weak_set = try this_value.requireInternalSlot(agent, WeakSet);

        // 3. If CanBeHeldWeakly(value) is false, return false.
        if (!value.canBeHeldWeakly(agent)) {
            return .false;
        }

        // 4. For each element entry of weakSet.[[WeakSetData]], do
        //     a. If entry is not empty and SameValue(entry, value) is true, then
        //         i. Replace the element of weakSet.[[WeakSetData]] whose value is entry with an
        //            element whose value is empty.
        //         ii. Return true.
        // 5. Return false.
        const is_removed = weak_set.fields.weak_set_data.remove(Value.Weak.init(value));
        return Value.from(is_removed);
    }

    /// 24.4.3.4 WeakSet.prototype.has ( value )
    /// https://tc39.es/ecma262/#sec-weakset.prototype.has
    fn has(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const value = arguments.get(0);

        // 1. Let weakSet be the this value.
        // 2. Perform ? RequireInternalSlot(weakSet, [[WeakSetData]]).
        const weak_set = try this_value.requireInternalSlot(agent, WeakSet);

        // 3. If CanBeHeldWeakly(value) is false, return false.
        if (!value.canBeHeldWeakly(agent)) {
            return .false;
        }

        // 4. For each element entry of weakSet.[[WeakSetData]], do
        //     a. If entry is not empty and SameValue(entry, value) is true, return true.
        // 5. Return false.
        const is_present = weak_set.fields.weak_set_data.contains(Value.Weak.init(value));
        return Value.from(is_present);
    }
};

const WeakSetData = Value.Weak.HashMap(void);

/// 24.4.4 Properties of WeakSet Instances
/// https://tc39.es/ecma262/#sec-properties-of-weakset-instances
pub const WeakSet = MakeObject(.{
    .Fields = struct {
        /// [[WeakSetData]]
        weak_set_data: WeakSetData,
    },
    .tag = .weak_set,
    .display_name = "WeakSet",
});
