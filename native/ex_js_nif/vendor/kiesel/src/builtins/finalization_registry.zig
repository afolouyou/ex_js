//! 26.2 FinalizationRegistry Objects
//! https://tc39.es/ecma262/#sec-finalization-registry-objects

const std = @import("std");

const build_options = @import("build-options");
const builtins = @import("../builtins.zig");
const execution = @import("../execution.zig");
const gc = @import("../gc.zig");
const types = @import("../types.zig");

const Agent = execution.Agent;
const Arguments = types.Arguments;
const Job = execution.Job;
const MakeObject = types.MakeObject;
const Object = types.Object;
const Realm = execution.Realm;
const Value = types.Value;
const createBuiltinFunction = builtins.createBuiltinFunction;
const ordinaryCreateFromConstructor = builtins.ordinaryCreateFromConstructor;
const ordinaryObjectCreate = builtins.ordinaryObjectCreate;
const sameValue = types.sameValue;

/// 26.2.1 The FinalizationRegistry Constructor
/// https://tc39.es/ecma262/#sec-finalization-registry-constructor
pub const constructor = struct {
    pub fn create(agent: *Agent, realm: *Realm) std.mem.Allocator.Error!*Object {
        const builtin_function = try createBuiltinFunction(
            agent,
            .{ .constructor = impl },
            1,
            "FinalizationRegistry",
            .{ .realm = realm, .proto = try realm.intrinsic(.function_prototype) },
        );
        return &builtin_function.object;
    }

    pub fn init(agent: *Agent, realm: *Realm, object: *Object) std.mem.Allocator.Error!void {
        // 26.2.2.1 FinalizationRegistry.prototype
        // https://tc39.es/ecma262/#sec-finalization-registry.prototype
        try object.defineBuiltinPropertyWithAttributes(
            agent,
            "prototype",
            Value.from(try realm.intrinsic(.finalization_registry_prototype)),
            .none,
        );
    }

    /// 26.2.1.1 FinalizationRegistry ( cleanupCallback )
    /// https://tc39.es/ecma262/#sec-finalization-registry-cleanup-callback
    fn impl(agent: *Agent, arguments: Arguments, new_target: ?*Object) Agent.Error!Value {
        const cleanup_callback = arguments.get(0);

        // 1. If NewTarget is undefined, throw a TypeError exception.
        if (new_target == null) {
            return agent.throwException(
                .type_error,
                "FinalizationRegistry must be constructed with 'new'",
                .{},
            );
        }

        // 2. If IsCallable(cleanupCallback) is false, throw a TypeError exception.
        if (!cleanup_callback.isCallable()) {
            return agent.throwException(.type_error, "{f} is not callable", .{cleanup_callback});
        }

        // 4. Let activeFunc be the active function object.
        const active_func = agent.activeFunctionObject();

        // 3. Let finalizationRegistry be ? OrdinaryCreateFromConstructor(NewTarget,
        //    "%FinalizationRegistry.prototype%", « [[Realm]], [[CleanupCallback]], [[Cells]] »).
        const finalization_registry = try ordinaryCreateFromConstructor(
            FinalizationRegistry,
            agent,
            new_target.?,
            .finalization_registry_prototype,
            .{
                // 5. Set finalizationRegistry.[[Realm]] to activeFunc.[[Realm]].
                .realm = active_func.as(builtins.BuiltinFunction).fields.realm,

                // 6. Set finalizationRegistry.[[CleanupCallback]] to HostMakeJobCallback(
                //    cleanupCallback).
                .cleanup_callback = agent.host_hooks.hostMakeJobCallback(cleanup_callback.asObject()),

                // 7. Set finalizationRegistry.[[Cells]] to a new empty List.
                .cells = .empty,
            },
        );

        // 8. Return finalizationRegistry.
        return Value.from(&finalization_registry.object);
    }
};

/// 26.2.3 Properties of the FinalizationRegistry Prototype Object
/// https://tc39.es/ecma262/#sec-properties-of-the-finalization-registry-prototype-object
pub const prototype = struct {
    pub fn create(agent: *Agent, realm: *Realm) std.mem.Allocator.Error!*Object {
        return ordinaryObjectCreate(agent, try realm.intrinsic(.object_prototype));
    }

    pub fn init(agent: *Agent, realm: *Realm, object: *Object) std.mem.Allocator.Error!void {
        try object.defineBuiltinFunction(agent, "register", register, 2, realm);
        try object.defineBuiltinFunction(agent, "unregister", unregister, 1, realm);

        // 26.2.3.1 FinalizationRegistry.prototype.constructor
        // https://tc39.es/ecma262/#sec-finalization-registry.prototype.constructor
        try object.defineBuiltinProperty(
            agent,
            "constructor",
            Value.from(try realm.intrinsic(.finalization_registry)),
        );

        // 26.2.3.4 FinalizationRegistry.prototype [ %Symbol.toStringTag% ]
        // https://tc39.es/ecma262/#sec-finalization-registry.prototype-%symbol.tostringtag%
        try object.defineBuiltinPropertyWithAttributes(
            agent,
            "Symbol.toStringTag",
            Value.from("FinalizationRegistry"),
            .{
                .writable = false,
                .enumerable = false,
                .configurable = true,
            },
        );
    }

    /// 26.2.3.2 FinalizationRegistry.prototype.register ( target, heldValue [ , unregisterToken ] )
    /// https://tc39.es/ecma262/#sec-finalization-registry.prototype.register
    fn register(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const target = arguments.get(0);
        const held_value = arguments.get(1);
        const unregister_token = arguments.get(2);
        var maybe_unregister_token: ?Value = unregister_token;

        // 1. Let finalizationRegistry be the this value.
        // 2. Perform ? RequireInternalSlot(finalizationRegistry, [[Cells]]).
        const finalization_registry = try this_value.requireInternalSlot(agent, FinalizationRegistry);

        // 3. If CanBeHeldWeakly(target) is false, throw a TypeError exception.
        if (!target.canBeHeldWeakly(agent)) {
            return agent.throwException(
                .type_error,
                "Value {f} cannot be held weakly",
                .{target},
            );
        }

        // 4. If SameValue(target, heldValue) is true, throw a TypeError exception.
        if (sameValue(target, held_value)) {
            return agent.throwException(
                .type_error,
                "Target and held value must not be the same",
                .{},
            );
        }

        // 5. If CanBeHeldWeakly(unregisterToken) is false, then
        if (!unregister_token.canBeHeldWeakly(agent)) {
            // a. If unregisterToken is not undefined, throw a TypeError exception.
            if (!unregister_token.isUndefined()) {
                return agent.throwException(
                    .type_error,
                    "Value {f} cannot be held weakly",
                    .{unregister_token},
                );
            }

            // b. Set unregisterToken to empty.
            maybe_unregister_token = null;
        }

        // 6. Let cell be the Record { [[WeakRefTarget]]: target, [[HeldValue]]: heldValue,
        //    [[UnregisterToken]]: unregisterToken }.
        const cell: Cell = .{
            .agent = agent,
            .is_unregistered = false,
            .finalization_registry = finalization_registry,
            .held_value = held_value,
            .unregister_token = if (maybe_unregister_token) |unregister_token_| Value.Weak.init(unregister_token_) else null,
        };

        const finalizer_data = try agent.gc_allocator.create(gc.FinalizerData(Cell));
        finalizer_data.* = .{ .data = cell };

        // 7. Append cell to finalizationRegistry.[[Cells]].
        try finalization_registry.fields.cells.append(agent.gc_allocator, &finalizer_data.data);

        if (build_options.enable_libgc) {
            // Implements 9.9.3 Execution step 1.b
            // https://tc39.es/ecma262/#sec-weakref-execution
            gc.registerFinalizer(Value.Weak.init(target).getPtr(), finalizer_data, struct {
                fn finalizer(_: *anyopaque, finalizer_cell: *Cell) void {
                    // unregister() calls will set this
                    if (finalizer_cell.is_unregistered) return;

                    // i. Set cell.[[WeakRefTarget]] to empty.
                    // NOTE: The weak ref target is managed by libgc.

                    // ii. Optionally, perform HostEnqueueFinalizationRegistryCleanupJob(fg).
                    const finalizer_agent = finalizer_cell.agent;
                    finalizer_agent.host_hooks.hostEnqueueFinalizationRegistryCleanupJob(finalizer_agent, finalizer_cell) catch {
                        // We are not required to run finalizers, so we can ignore OOMs.
                    };
                }
            }.finalizer);

            // Guarantee cell.[[UnregisterToken]] is empty when it is no longer live.
            if (cell.unregister_token) |weak_unregister_token| {
                const unregister_finalizer_data = try agent.gc_allocator.create(gc.FinalizerData(*Cell));
                unregister_finalizer_data.* = .{ .data = &finalizer_data.data };

                gc.registerFinalizer(weak_unregister_token.getPtr(), unregister_finalizer_data, struct {
                    fn finalizer(_: *anyopaque, finalizer_cell: **Cell) void {
                        finalizer_cell.*.unregister_token = null;
                    }
                }.finalizer);
            }
        }

        // 8. Return undefined.
        return .undefined;
    }

    /// 26.2.3.3 FinalizationRegistry.prototype.unregister ( unregisterToken )
    /// https://tc39.es/ecma262/#sec-finalization-registry.prototype.unregister
    fn unregister(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const unregister_token = arguments.get(0);

        // 1. Let finalizationRegistry be the this value.
        // 2. Perform ? RequireInternalSlot(finalizationRegistry, [[Cells]]).
        const finalization_registry = try this_value.requireInternalSlot(agent, FinalizationRegistry);

        // 3. If CanBeHeldWeakly(unregisterToken) is false, throw a TypeError exception.
        if (!unregister_token.canBeHeldWeakly(agent)) {
            return agent.throwException(
                .type_error,
                "Value {f} cannot be held weakly",
                .{unregister_token},
            );
        }

        // 4. Let removed be false.
        var removed = false;

        // 5. For each Record { [[WeakRefTarget]], [[HeldValue]], [[UnregisterToken]] } cell of
        //    finalizationRegistry.[[Cells]], do
        var index = finalization_registry.fields.cells.items.len;
        while (index > 0) {
            index -= 1;
            const cell = finalization_registry.fields.cells.items[index];
            // a. If cell.[[UnregisterToken]] is not empty and SameValue(cell.[[UnregisterToken]],
            //    unregisterToken) is true, then
            if (cell.unregister_token) |cell_unregister_token| {
                if (cell_unregister_token.get().sameValue(unregister_token)) {
                    // i. Remove cell from finalizationRegistry.[[Cells]].
                    _ = finalization_registry.fields.cells.swapRemove(index);
                    cell.is_unregistered = true;

                    // ii. Set removed to true.
                    removed = true;
                }
            }
        }

        // 6. Return removed.
        return Value.from(removed);
    }
};

/// 9.12 CleanupFinalizationRegistry ( finalizationRegistry )
/// https://tc39.es/ecma262/#sec-cleanup-finalization-registry
pub fn cleanupFinalizationRegistry(cell: *Cell) Agent.Error!void {
    const agent = cell.agent;

    // 1. Assert: finalizationRegistry has [[Cells]] and [[CleanupCallback]] internal slots.
    const finalization_registry = cell.finalization_registry;

    // 2. Let callback be finalizationRegistry.[[CleanupCallback]].
    const callback = finalization_registry.fields.cleanup_callback;

    // 3. While finalizationRegistry.[[Cells]] contains a Record cell such that
    //    cell.[[WeakRefTarget]] is empty, an implementation may perform the following steps:
    //    a. Choose any such cell.
    // NOTE: Steps 3 and 3.a are completed by libgc which is why this function takes
    //       a single cell instead.

    //    b. Remove cell from finalizationRegistry.[[Cells]].
    const cell_index = std.mem.findScalar(*Cell, cell.finalization_registry.fields.cells.items, cell) orelse return;
    _ = finalization_registry.fields.cells.swapRemove(cell_index);

    if (!cell.is_unregistered) {
        // c. Perform ? HostCallJobCallback(callback, undefined, « cell.[[HeldValue]] »).
        _ = try agent.host_hooks.hostCallJobCallback(
            agent,
            callback,
            .undefined,
            &.{cell.held_value},
        );
    }

    // 4. Return unused.
}

pub const Cell = struct {
    agent: *Agent,

    // libgc does not support unregistering finalizers so we use a flag to
    // achieve the functionality.
    is_unregistered: bool,

    finalization_registry: *FinalizationRegistry,

    // [[WeakRefTarget]]
    // NOTE: This is tracked by libgc's finalizer.

    /// [[HeldValue]]
    held_value: Value,

    /// [[UnregisterToken]]
    unregister_token: ?Value.Weak,
};

/// 26.2.4 Properties of FinalizationRegistry Instances
/// https://tc39.es/ecma262/#sec-properties-of-finalization-registry-instances
pub const FinalizationRegistry = MakeObject(.{
    .Fields = struct {
        /// [[Realm]]
        realm: *Realm,

        /// [[CleanupCallback]]
        cleanup_callback: Job.Callback,

        /// [[Cells]]
        cells: std.ArrayList(*Cell),
    },
    .tag = .finalization_registry,
    .display_name = "FinalizationRegistry",
});
