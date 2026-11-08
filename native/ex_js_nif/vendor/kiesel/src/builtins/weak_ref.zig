//! 26.1 WeakRef Objects
//! https://tc39.es/ecma262/#sec-weak-ref-objects

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
const Realm = execution.Realm;
const Value = types.Value;
const createBuiltinFunction = builtins.createBuiltinFunction;
const ordinaryCreateFromConstructor = builtins.ordinaryCreateFromConstructor;
const ordinaryObjectCreate = builtins.ordinaryObjectCreate;

/// 26.1.2 Properties of the WeakRef Constructor
/// https://tc39.es/ecma262/#sec-properties-of-the-weak-ref-constructor
pub const constructor = struct {
    pub fn create(agent: *Agent, realm: *Realm) std.mem.Allocator.Error!*Object {
        const builtin_function = try createBuiltinFunction(
            agent,
            .{ .constructor = impl },
            1,
            "WeakRef",
            .{ .realm = realm, .proto = try realm.intrinsic(.function_prototype) },
        );
        return &builtin_function.object;
    }

    pub fn init(agent: *Agent, realm: *Realm, object: *Object) std.mem.Allocator.Error!void {
        // 26.1.2.1 WeakRef.prototype
        // https://tc39.es/ecma262/#sec-weak-ref.prototype
        try object.defineBuiltinPropertyWithAttributes(
            agent,
            "prototype",
            Value.from(try realm.intrinsic(.weak_ref_prototype)),
            .none,
        );
    }

    /// 26.1.1.1 WeakRef ( target )
    /// https://tc39.es/ecma262/#sec-weak-ref-target
    fn impl(agent: *Agent, arguments: Arguments, maybe_new_target: ?*Object) Agent.Error!Value {
        const target = arguments.get(0);

        const new_target = maybe_new_target orelse {
            // 1. If NewTarget is undefined, throw a TypeError exception.
            return agent.throwException(
                .type_error,
                "WeakRef must be constructed with 'new'",
                .{},
            );
        };

        // 2. If CanBeHeldWeakly(target) is false, throw a TypeError exception.
        if (!target.canBeHeldWeakly(agent)) {
            return agent.throwException(
                .type_error,
                "Value {f} cannot be held weakly",
                .{target},
            );
        }

        // 3. Let weakRef be ? OrdinaryCreateFromConstructor(NewTarget, "%WeakRef.prototype%",
        //    « [[WeakRefTarget]] »).
        const weak_ref = try ordinaryCreateFromConstructor(
            WeakRef,
            agent,
            new_target,
            .weak_ref_prototype,
            .{
                // 4. Perform AddToKeptObjects(target).
                // NOTE: libgc tracks all used pointers

                // 5. Set weakRef.[[WeakRefTarget]] to target.
                .weak_ref_target = .init(target),
            },
        );

        if (build_options.enable_libgc) {
            // Implements 9.9.3 Execution step 1.a
            // https://tc39.es/ecma262/#sec-weakref-execution
            const weak_ref_target_ptr = &weak_ref.fields.weak_ref_target;
            const finalizer_data = try agent.gc_allocator.create(gc.FinalizerData(*?Value.Weak));
            finalizer_data.* = .{ .data = weak_ref_target_ptr };
            gc.registerFinalizer(weak_ref_target_ptr.*.?.getPtr(), finalizer_data, struct {
                pub fn finalize(_: *anyopaque, weak_ref_target: **?Value.Weak) void {
                    // i. Set ref.[[WeakRefTarget]] to empty.
                    weak_ref_target.*.* = null;
                }
            }.finalize);
        }

        // 6. Return weakRef.
        return Value.from(&weak_ref.object);
    }
};

/// 26.1.3 Properties of the WeakRef Prototype Object
/// https://tc39.es/ecma262/#sec-properties-of-the-weak-ref-prototype-object
pub const prototype = struct {
    pub fn create(agent: *Agent, realm: *Realm) std.mem.Allocator.Error!*Object {
        return ordinaryObjectCreate(agent, try realm.intrinsic(.object_prototype));
    }

    pub fn init(agent: *Agent, realm: *Realm, object: *Object) std.mem.Allocator.Error!void {
        try object.defineBuiltinFunction(agent, "deref", deref, 0, realm);

        // 26.1.3.1 WeakRef.prototype.constructor
        // https://tc39.es/ecma262/#sec-weak-ref.prototype.constructor
        try object.defineBuiltinProperty(
            agent,
            "constructor",
            Value.from(try realm.intrinsic(.weak_ref)),
        );

        // 26.1.3.3 WeakRef.prototype [ %Symbol.toStringTag% ]
        // https://tc39.es/ecma262/#sec-weak-ref.prototype-%symbol.tostringtag%
        try object.defineBuiltinPropertyWithAttributes(
            agent,
            "Symbol.toStringTag",
            Value.from("WeakRef"),
            .{
                .writable = false,
                .enumerable = false,
                .configurable = true,
            },
        );
    }

    /// 26.1.3.2 WeakRef.prototype.deref ( )
    /// https://tc39.es/ecma262/#sec-weak-ref.prototype.deref
    fn deref(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let weakRef be the this value.
        // 2. Perform ? RequireInternalSlot(weakRef, [[WeakRefTarget]]).
        const weak_ref = try this_value.requireInternalSlot(agent, WeakRef);

        // 3. Return WeakRefDeref(weakRef).
        return weakRefDeref(weak_ref);
    }
};

/// 26.1.4.1 WeakRefDeref ( weakRef )
/// https://tc39.es/ecma262/#sec-weakrefderef
pub fn weakRefDeref(weak_ref: *const WeakRef) Value {
    // 1. Let target be weakRef.[[WeakRefTarget]].
    const maybe_target = weak_ref.fields.weak_ref_target;

    // 2. If target is not empty, then
    if (maybe_target) |target| {
        // a. Perform AddToKeptObjects(target).
        // NOTE: libgc tracks all used pointers

        // b. Return target.
        return target.get();
    }

    // 3. Return undefined.
    return .undefined;
}

/// 26.1.5 Properties of WeakRef Instances
/// https://tc39.es/ecma262/#sec-properties-of-weak-ref-instances
pub const WeakRef = MakeObject(.{
    .Fields = struct {
        /// [[WeakRefTarget]]
        weak_ref_target: ?Value.Weak,
    },
    .tag = .weak_ref,
    .display_name = "WeakRef",
});
