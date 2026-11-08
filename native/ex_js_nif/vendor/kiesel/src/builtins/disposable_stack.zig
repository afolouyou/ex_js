//! 27.3 DisposableStack Objects
//! https://tc39.es/ecma262/#sec-disposablestack-objects

const std = @import("std");

const builtins = @import("../builtins.zig");
const execution = @import("../execution.zig");
const types = @import("../types.zig");

const Agent = execution.Agent;
const Arguments = types.Arguments;
const DisposableResource = types.DisposableResource;
const MakeObject = types.MakeObject;
const Object = types.Object;
const PropertyKey = types.PropertyKey;
const Realm = execution.Realm;
const Value = types.Value;
const addDisposableResource = types.addDisposableResource;
const createBuiltinFunction = builtins.createBuiltinFunction;
const disposeResources = types.disposeResources;
const ordinaryCreateFromConstructor = builtins.ordinaryCreateFromConstructor;
const ordinaryObjectCreate = builtins.ordinaryObjectCreate;

/// 27.3.2 Properties of the DisposableStack Constructor
/// https://tc39.es/ecma262/#sec-properties-of-the-disposablestack-constructor
pub const constructor = struct {
    pub fn create(agent: *Agent, realm: *Realm) std.mem.Allocator.Error!*Object {
        const builtin_function = try createBuiltinFunction(
            agent,
            .{ .constructor = impl },
            0,
            "DisposableStack",
            .{ .realm = realm, .proto = try realm.intrinsic(.function_prototype) },
        );
        return &builtin_function.object;
    }

    pub fn init(agent: *Agent, realm: *Realm, object: *Object) std.mem.Allocator.Error!void {
        // 27.3.2.1 DisposableStack.prototype
        // https://tc39.es/ecma262/#sec-disposablestack.prototype
        try object.defineBuiltinPropertyWithAttributes(
            agent,
            "prototype",
            Value.from(try realm.intrinsic(.disposable_stack_prototype)),
            .none,
        );
    }

    /// 27.3.1.1 DisposableStack ( )
    /// https://tc39.es/ecma262/#sec-disposablestack
    fn impl(agent: *Agent, _: Arguments, maybe_new_target: ?*Object) Agent.Error!Value {
        // 1. If NewTarget is undefined, throw a TypeError exception.
        const new_target = maybe_new_target orelse {
            return agent.throwException(
                .type_error,
                "DisposableStack must be constructed with 'new'",
                .{},
            );
        };

        // 2. Let disposableStack be ? OrdinaryCreateFromConstructor(NewTarget,
        //    "%DisposableStack.prototype%", « [[DisposableState]], [[DisposableResourceStack]] »).
        const disposable_stack = try ordinaryCreateFromConstructor(
            DisposableStack,
            agent,
            new_target,
            .disposable_stack_prototype,
            .{
                // 3. Set disposableStack.[[DisposableState]] to pending.
                // 4. Set disposableStack.[[DisposableResourceStack]] to a new empty List.
                .pending = .empty,
            },
        );

        // 5. Return disposableStack.
        return Value.from(&disposable_stack.object);
    }
};

/// 27.3.3 Properties of the DisposableStack Prototype Object
/// https://tc39.es/ecma262/#sec-properties-of-the-disposablestack-prototype-object
pub const prototype = struct {
    pub fn create(agent: *Agent, realm: *Realm) std.mem.Allocator.Error!*Object {
        return ordinaryObjectCreate(agent, try realm.intrinsic(.object_prototype));
    }

    pub fn init(agent: *Agent, realm: *Realm, object: *Object) std.mem.Allocator.Error!void {
        try object.defineBuiltinFunction(agent, "adopt", adopt, 2, realm);
        try object.defineBuiltinFunction(agent, "defer", @"defer", 1, realm);
        try object.defineBuiltinFunction(agent, "dispose", dispose, 0, realm);
        try object.defineBuiltinAccessor(agent, "disposed", disposed, null, realm);
        try object.defineBuiltinFunction(agent, "move", move, 0, realm);
        try object.defineBuiltinFunction(agent, "use", use, 1, realm);

        // 27.3.3.2 DisposableStack.prototype.constructor
        // https://tc39.es/ecma262/#sec-disposablestack.prototype.constructor
        try object.defineBuiltinProperty(
            agent,
            "constructor",
            Value.from(try realm.intrinsic(.disposable_stack)),
        );

        // 27.3.3.8 DisposableStack.prototype [ %Symbol.dispose% ] ( )
        // https://tc39.es/ecma262/#sec-disposablestack.prototype-%symbol.dispose%
        // NOTE: We can't use the intrinsic getter for this while creating the underlying prototype
        //       object, as it hasn't been finalized yet.
        const disposable_stack_prototype_dispose = object.getPropertyValueDirect(
            PropertyKey.from("dispose"),
        );
        try object.defineBuiltinProperty(
            agent,
            "Symbol.dispose",
            disposable_stack_prototype_dispose,
        );

        // 27.3.3.9 DisposableStack.prototype [ %Symbol.toStringTag% ]
        // https://tc39.es/ecma262/#sec-disposablestack.prototype-%symbol.tostringtag%
        try object.defineBuiltinPropertyWithAttributes(
            agent,
            "Symbol.toStringTag",
            Value.from("DisposableStack"),
            .{
                .writable = false,
                .enumerable = false,
                .configurable = true,
            },
        );
    }

    /// 27.3.3.1 DisposableStack.prototype.adopt ( value, onDispose )
    /// https://tc39.es/ecma262/#sec-disposablestack.prototype.adopt
    fn adopt(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const value = arguments.get(0);
        const on_dispose = arguments.get(1);

        // 1. Let disposableStack be the this value.
        // 2. Perform ? RequireInternalSlot(disposableStack, [[DisposableState]]).
        const disposable_stack = try this_value.requireInternalSlot(agent, DisposableStack);

        const disposable_resource_stack = switch (disposable_stack.fields) {
            .pending => |*disposable_resource_stack| disposable_resource_stack,

            // 3. If disposableStack.[[DisposableState]] is disposed, throw a ReferenceError
            //    exception.
            .disposed => {
                return agent.throwException(.reference_error, "DisposableStack is disposed", .{});
            },
        };

        // 4. If IsCallable(onDispose) is false, throw a TypeError exception.
        if (!on_dispose.isCallable()) {
            return agent.throwException(.type_error, "{f} is not callable", .{on_dispose});
        }

        const Captures = struct {
            value: Value,
            on_dispose: *Object,
        };
        const captures = try agent.gc_allocator.create(Captures);
        captures.* = .{ .value = value, .on_dispose = on_dispose.asObject() };

        // 5. Let closure be a new Abstract Closure with no parameters that captures value and
        //    onDispose and performs the following steps when called:
        const closure = struct {
            fn func(agent_: *Agent, _: Value, _: Arguments) Agent.Error!Value {
                const function = agent_.activeFunctionObject();
                const captures_ = function.as(builtins.BuiltinFunction).fields.additionalFieldsAs(Captures);
                const value_ = captures_.value;
                const on_dispose_ = captures_.on_dispose;

                // a. Return ? Call(onDispose, undefined, « value »).
                return on_dispose_.call(agent_, .undefined, &.{value_});
            }
        }.func;

        // 6. Let func be CreateBuiltinFunction(closure, 0, "", « »).
        const func = try createBuiltinFunction(
            agent,
            .{ .function = closure },
            0,
            "",
            .{ .additional_fields = captures },
        );

        // 7. Perform ? AddDisposableResource(disposableStack.[[DisposableResourceStack]],
        //    undefined, sync-dispose, func).
        try addDisposableResource(
            agent,
            disposable_resource_stack,
            .undefined,
            .sync_dispose,
            &func.object,
        );

        // 8. Return value.
        return value;
    }

    /// 27.3.3.3 DisposableStack.prototype.defer ( onDispose )
    /// https://tc39.es/ecma262/#sec-disposablestack.prototype.defer
    fn @"defer"(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const on_dispose = arguments.get(0);

        // 1. Let disposableStack be the this value.
        // 2. Perform ? RequireInternalSlot(disposableStack, [[DisposableState]]).
        const disposable_stack = try this_value.requireInternalSlot(agent, DisposableStack);

        const disposable_resource_stack = switch (disposable_stack.fields) {
            .pending => |*disposable_resource_stack| disposable_resource_stack,

            // 3. If disposableStack.[[DisposableState]] is disposed, throw a ReferenceError
            //    exception.
            .disposed => {
                return agent.throwException(.reference_error, "DisposableStack is disposed", .{});
            },
        };

        // 4. If IsCallable(onDispose) is false, throw a TypeError exception.
        if (!on_dispose.isCallable()) {
            return agent.throwException(.type_error, "{f} is not callable", .{on_dispose});
        }

        // 5. Perform ? AddDisposableResource(disposableStack.[[DisposableResourceStack]],
        //    undefined, sync-dispose, onDispose).
        try addDisposableResource(
            agent,
            disposable_resource_stack,
            .undefined,
            .sync_dispose,
            on_dispose.asObject(),
        );

        // 6. Return undefined.
        return .undefined;
    }

    /// 27.3.3.4 DisposableStack.prototype.dispose ( )
    /// https://tc39.es/ecma262/#sec-disposablestack.prototype.dispose
    fn dispose(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        _ = arguments;

        // 1. Let disposableStack be the this value.
        // 2. Perform ? RequireInternalSlot(disposableStack, [[DisposableState]]).
        const disposable_stack = try this_value.requireInternalSlot(agent, DisposableStack);

        var disposable_resource_stack_copy = switch (disposable_stack.fields) {
            .pending => |disposable_resource_stack| disposable_resource_stack,

            // 3. If disposableStack.[[DisposableState]] is disposed, return undefined.
            .disposed => return .undefined,
        };
        const disposable_resource_stack = &disposable_resource_stack_copy;

        // 4. Set disposableStack.[[DisposableState]] to disposed.
        disposable_stack.fields = .disposed;

        // 5. Return ? DisposeResources(disposableStack.[[DisposableResourceStack]],
        //    NormalCompletion(undefined)).
        return disposeResources(
            agent,
            disposable_resource_stack,
            @as(Agent.Error!Value, .undefined),
        );
    }

    /// 27.3.3.5 get DisposableStack.prototype.disposed
    /// https://tc39.es/ecma262/#sec-get-disposablestack.prototype.disposed
    fn disposed(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let disposableStack be the this value.
        // 2. Perform ? RequireInternalSlot(disposableStack, [[DisposableState]]).
        const disposable_stack = try this_value.requireInternalSlot(agent, DisposableStack);

        // 3. If disposableStack.[[DisposableState]] is disposed, return true.
        // 4. Return false.
        return switch (disposable_stack.fields) {
            .disposed => .true,
            .pending => .false,
        };
    }

    /// 27.3.3.6 DisposableStack.prototype.move ( )
    /// https://tc39.es/ecma262/#sec-disposablestack.prototype.move
    fn move(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        const realm = agent.currentRealm();

        // 1. Let disposableStack be the this value.
        // 2. Perform ? RequireInternalSlot(disposableStack, [[DisposableState]]).
        const disposable_stack = try this_value.requireInternalSlot(agent, DisposableStack);

        const disposable_resource_stack = switch (disposable_stack.fields) {
            .pending => |*disposable_resource_stack| disposable_resource_stack,

            // 3. If disposableStack.[[DisposableState]] is disposed, throw a ReferenceError
            //    exception.
            .disposed => {
                return agent.throwException(.reference_error, "DisposableStack is disposed", .{});
            },
        };

        // 4. Let newDisposableStack be ? OrdinaryCreateFromConstructor(%DisposableStack%,
        //    "%DisposableStack.prototype%", « [[DisposableState]], [[DisposableResourceStack]] »).
        const new_disposable_stack = try ordinaryCreateFromConstructor(
            DisposableStack,
            agent,
            try realm.intrinsic(.disposable_stack),
            .disposable_stack_prototype,
            .{
                // 5. Set newDisposableStack.[[DisposableState]] to pending.
                // 6. Set newDisposableStack.[[DisposableResourceStack]] to
                //    disposableStack.[[DisposableResourceStack]].
                .pending = disposable_resource_stack.*,
            },
        );

        // 7. Set disposableStack.[[DisposableResourceStack]] to a new empty List.
        // 8. Set disposableStack.[[DisposableState]] to disposed.
        disposable_stack.fields = .disposed;

        // 9. Return newDisposableStack.
        return Value.from(&new_disposable_stack.object);
    }

    /// 27.3.3.7 DisposableStack.prototype.use ( value )
    /// https://tc39.es/ecma262/#sec-disposablestack.prototype.use
    fn use(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const value = arguments.get(0);

        // 1. Let disposableStack be the this value.
        // 2. Perform ? RequireInternalSlot(disposableStack, [[DisposableState]]).
        const disposable_stack = try this_value.requireInternalSlot(agent, DisposableStack);

        const disposable_resource_stack = switch (disposable_stack.fields) {
            .pending => |*disposable_resource_stack| disposable_resource_stack,

            // 3. If disposableStack.[[DisposableState]] is disposed, throw a ReferenceError
            //    exception.
            .disposed => {
                return agent.throwException(.reference_error, "DisposableStack is disposed", .{});
            },
        };

        // 4. Perform ? AddDisposableResource(disposableStack.[[DisposableResourceStack]], value,
        //    sync-dispose).
        try addDisposableResource(
            agent,
            disposable_resource_stack,
            value,
            .sync_dispose,
            null,
        );

        // 5. Return value.
        return value;
    }
};

/// 27.3.4 Properties of DisposableStack Instances
/// https://tc39.es/ecma262/#sec-properties-of-disposablestack-instances
pub const DisposableStack = MakeObject(.{
    .Fields = union(enum) {
        /// [[DisposableState]]
        /// [[DisposableResourceStack]]
        pending: std.ArrayList(DisposableResource),
        disposed,
    },
    .tag = .disposable_stack,
    .display_name = "DisposableStack",
});
