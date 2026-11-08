//! 27.4 AsyncDisposableStack Objects
//! https://tc39.es/ecma262/#sec-asyncdisposablestack-objects

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

/// 27.4.2 Properties of the AsyncDisposableStack Constructor
/// https://tc39.es/ecma262/#sec-properties-of-the-asyncdisposablestack-constructor
pub const constructor = struct {
    pub fn create(agent: *Agent, realm: *Realm) std.mem.Allocator.Error!*Object {
        const builtin_function = try createBuiltinFunction(
            agent,
            .{ .constructor = impl },
            0,
            "AsyncDisposableStack",
            .{ .realm = realm, .proto = try realm.intrinsic(.function_prototype) },
        );
        return &builtin_function.object;
    }

    pub fn init(agent: *Agent, realm: *Realm, object: *Object) std.mem.Allocator.Error!void {
        // 27.4.2.1 AsyncDisposableStack.prototype
        // https://tc39.es/ecma262/#sec-asyncdisposablestack.prototype
        try object.defineBuiltinPropertyWithAttributes(
            agent,
            "prototype",
            Value.from(try realm.intrinsic(.async_disposable_stack_prototype)),
            .none,
        );
    }

    /// 27.4.1.1 AsyncDisposableStack ( )
    /// https://tc39.es/ecma262/#sec-asyncdisposablestack
    fn impl(agent: *Agent, _: Arguments, maybe_new_target: ?*Object) Agent.Error!Value {
        // 1. If NewTarget is undefined, throw a TypeError exception.
        const new_target = maybe_new_target orelse {
            return agent.throwException(
                .type_error,
                "AsyncDisposableStack must be constructed with 'new'",
                .{},
            );
        };

        // 2. Let asyncDisposableStack be ? OrdinaryCreateFromConstructor(NewTarget,
        //    "%AsyncDisposableStack.prototype%", « [[AsyncDisposableState]],
        //    [[DisposableResourceStack]] »).
        const async_disposable_stack = try ordinaryCreateFromConstructor(
            AsyncDisposableStack,
            agent,
            new_target,
            .async_disposable_stack_prototype,
            .{
                // 3. Set asyncDisposableStack.[[AsyncDisposableState]] to pending.
                // 4. Set asyncDisposableStack.[[DisposableResourceStack]] to a new empty List.
                .pending = .empty,
            },
        );

        // 5. Return asyncDisposableStack.
        return Value.from(&async_disposable_stack.object);
    }
};

/// 27.4.3 Properties of the AsyncDisposableStack Prototype Object
/// https://tc39.es/ecma262/#sec-properties-of-the-asyncdisposablestack-prototype-object
pub const prototype = struct {
    pub fn create(agent: *Agent, realm: *Realm) std.mem.Allocator.Error!*Object {
        return ordinaryObjectCreate(agent, try realm.intrinsic(.object_prototype));
    }

    pub fn init(agent: *Agent, realm: *Realm, object: *Object) std.mem.Allocator.Error!void {
        try object.defineBuiltinFunction(agent, "adopt", adopt, 2, realm);
        try object.defineBuiltinFunction(agent, "defer", @"defer", 1, realm);
        try object.defineBuiltinAsyncFunction(agent, "disposeAsync", disposeAsync, 0, realm);
        try object.defineBuiltinAccessor(agent, "disposed", disposed, null, realm);
        try object.defineBuiltinFunction(agent, "move", move, 0, realm);
        try object.defineBuiltinFunction(agent, "use", use, 1, realm);

        // 27.4.3.2 AsyncDisposableStack.prototype.constructor
        // https://tc39.es/ecma262/#sec-asyncdisposablestack.prototype.constructor
        try object.defineBuiltinProperty(
            agent,
            "constructor",
            Value.from(try realm.intrinsic(.async_disposable_stack)),
        );

        // 27.4.3.8 AsyncDisposableStack.prototype [ %Symbol.asyncDispose% ] ( )
        // https://tc39.es/ecma262/#sec-asyncdisposablestack.prototype-%symbol.asyncdispose%
        // NOTE: We can't use the intrinsic getter for this while creating the underlying prototype
        //       object, as it hasn't been finalized yet.
        const async_disposable_stack_prototype_dispose_async = object.getPropertyValueDirect(
            PropertyKey.from("disposeAsync"),
        );
        try object.defineBuiltinProperty(
            agent,
            "Symbol.asyncDispose",
            async_disposable_stack_prototype_dispose_async,
        );

        // 27.4.3.9 AsyncDisposableStack.prototype [ %Symbol.toStringTag% ]
        // https://tc39.es/ecma262/#sec-asyncdisposablestack.prototype-%symbol.tostringtag%
        try object.defineBuiltinPropertyWithAttributes(
            agent,
            "Symbol.toStringTag",
            Value.from("AsyncDisposableStack"),
            .{
                .writable = false,
                .enumerable = false,
                .configurable = true,
            },
        );
    }

    /// 27.4.3.1 AsyncDisposableStack.prototype.adopt ( value, onDisposeAsync )
    /// https://tc39.es/ecma262/#sec-asyncdisposablestack.prototype.adopt
    fn adopt(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const value = arguments.get(0);
        const on_dispose_async = arguments.get(1);

        // 1. Let asyncDisposableStack be the this value.
        // 2. Perform ? RequireInternalSlot(asyncDisposableStack, [[AsyncDisposableState]]).
        const async_disposable_stack = try this_value.requireInternalSlot(agent, AsyncDisposableStack);

        const disposable_resource_stack = switch (async_disposable_stack.fields) {
            .pending => |*disposable_resource_stack| disposable_resource_stack,

            // 3. If asyncDisposableStack.[[AsyncDisposableState]] is disposed, throw a
            //    ReferenceError exception.
            .disposed => {
                return agent.throwException(.reference_error, "AsyncDisposableStack is disposed", .{});
            },
        };

        // 4. If IsCallable(onDisposeAsync) is false, throw a TypeError exception.
        if (!on_dispose_async.isCallable()) {
            return agent.throwException(.type_error, "{f} is not callable", .{on_dispose_async});
        }

        const Captures = struct {
            value: Value,
            on_dispose_async: *Object,
        };
        const captures = try agent.gc_allocator.create(Captures);
        captures.* = .{ .value = value, .on_dispose_async = on_dispose_async.asObject() };

        // 5. Let closure be a new Abstract Closure with no parameters that captures value and
        //    onDisposeAsync and performs the following steps when called:
        const closure = struct {
            fn func(agent_: *Agent, _: Value, _: Arguments) Agent.Error!Value {
                const function = agent_.activeFunctionObject();
                const captures_ = function.as(builtins.BuiltinFunction).fields.additionalFieldsAs(Captures);
                const value_ = captures_.value;
                const on_dispose_async_ = captures_.on_dispose_async;

                // a. Return ? Call(onDisposeAsync, undefined, « value »).
                return on_dispose_async_.call(agent_, .undefined, &.{value_});
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

        // 7. Perform ? AddDisposableResource(asyncDisposableStack.[[DisposableResourceStack]],
        //    undefined, async-dispose, func).
        try addDisposableResource(
            agent,
            disposable_resource_stack,
            .undefined,
            .async_dispose,
            &func.object,
        );

        // 8. Return value.
        return value;
    }

    /// 27.4.3.3 AsyncDisposableStack.prototype.defer ( onDisposeAsync )
    /// https://tc39.es/ecma262/#sec-asyncdisposablestack.prototype.defer
    fn @"defer"(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const on_dispose_async = arguments.get(0);

        // 1. Let asyncDisposableStack be the this value.
        // 2. Perform ? RequireInternalSlot(asyncDisposableStack, [[AsyncDisposableState]]).
        const async_disposable_stack = try this_value.requireInternalSlot(agent, AsyncDisposableStack);

        const disposable_resource_stack = switch (async_disposable_stack.fields) {
            .pending => |*disposable_resource_stack| disposable_resource_stack,

            // 3. If asyncDisposableStack.[[AsyncDisposableState]] is disposed, throw a
            //    ReferenceError exception.
            .disposed => {
                return agent.throwException(.reference_error, "AsyncDisposableStack is disposed", .{});
            },
        };

        // 4. If IsCallable(onDisposeAsync) is false, throw a TypeError exception.
        if (!on_dispose_async.isCallable()) {
            return agent.throwException(.type_error, "{f} is not callable", .{on_dispose_async});
        }

        // 5. Perform ? AddDisposableResource(asyncDisposableStack.[[DisposableResourceStack]],
        //    undefined, async-dispose, onDisposeAsync).
        try addDisposableResource(
            agent,
            disposable_resource_stack,
            .undefined,
            .async_dispose,
            on_dispose_async.asObject(),
        );

        // 6. Return undefined.
        return .undefined;
    }

    /// 27.4.3.4 AsyncDisposableStack.prototype.disposeAsync ( )
    /// https://tc39.es/ecma262/#sec-asyncdisposablestack.prototype.disposeAsync
    fn disposeAsync(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let asyncDisposableStack be the this value.
        // 2. Perform ? RequireInternalSlot(asyncDisposableStack, [[AsyncDisposableState]]).
        const async_disposable_stack = try this_value.requireInternalSlot(agent, AsyncDisposableStack);

        var disposable_resource_stack_copy = switch (async_disposable_stack.fields) {
            .pending => |disposable_resource_stack| disposable_resource_stack,

            // 3. If asyncDisposableStack.[[AsyncDisposableState]] is disposed, return undefined.
            .disposed => return .undefined,
        };
        const disposable_resource_stack = &disposable_resource_stack_copy;

        // 4. Set asyncDisposableStack.[[AsyncDisposableState]] to disposed.
        async_disposable_stack.fields = .disposed;

        // 5. Return ? DisposeResources(asyncDisposableStack.[[DisposableResourceStack]],
        //    NormalCompletion(undefined)).
        return disposeResources(
            agent,
            disposable_resource_stack,
            @as(Agent.Error!Value, .undefined),
        );
    }

    /// 27.4.3.5 get AsyncDisposableStack.prototype.disposed
    /// https://tc39.es/ecma262/#sec-get-asyncdisposablestack.prototype.disposed
    fn disposed(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let asyncDisposableStack be the this value.
        // 2. Perform ? RequireInternalSlot(asyncDisposableStack, [[AsyncDisposableState]]).
        const async_disposable_stack = try this_value.requireInternalSlot(agent, AsyncDisposableStack);

        // 3. If asyncDisposableStack.[[AsyncDisposableState]] is disposed, return true.
        // 4. Return false.
        return switch (async_disposable_stack.fields) {
            .pending => .false,
            .disposed => .true,
        };
    }

    /// 27.4.3.6 AsyncDisposableStack.prototype.move ( )
    /// https://tc39.es/ecma262/#sec-asyncdisposablestack.prototype.move
    fn move(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        const realm = agent.currentRealm();

        // 1. Let asyncDisposableStack be the this value.
        // 2. Perform ? RequireInternalSlot(asyncDisposableStack, [[AsyncDisposableState]]).
        const async_disposable_stack = try this_value.requireInternalSlot(agent, AsyncDisposableStack);

        const disposable_resource_stack = switch (async_disposable_stack.fields) {
            .pending => |*disposable_resource_stack| disposable_resource_stack,

            .disposed => {
                // 3. If asyncDisposableStack.[[AsyncDisposableState]] is disposed, throw a
                //    ReferenceError exception.
                return agent.throwException(.reference_error, "AsyncDisposableStack is disposed", .{});
            },
        };

        // 4. Let newAsyncDisposableStack be ? OrdinaryCreateFromConstructor(%AsyncDisposableStack%,
        //    "%AsyncDisposableStack.prototype%", « [[AsyncDisposableState]],
        //    [[DisposableResourceStack]] »).
        const new_async_disposable_stack = try ordinaryCreateFromConstructor(
            AsyncDisposableStack,
            agent,
            try realm.intrinsic(.async_disposable_stack),
            .async_disposable_stack_prototype,
            .{
                // 5. Set newAsyncDisposableStack.[[AsyncDisposableState]] to pending.
                // 6. Set newAsyncDisposableStack.[[DisposableResourceStack]] to
                //    asyncDisposableStack.[[DisposableResourceStack]].
                .pending = disposable_resource_stack.*,
            },
        );

        // 7. Set asyncDisposableStack.[[DisposableResourceStack]] to a new empty List.
        // 8. Set asyncDisposableStack.[[AsyncDisposableState]] to disposed.
        async_disposable_stack.fields = .disposed;

        // 9. Return newAsyncDisposableStack.
        return Value.from(&new_async_disposable_stack.object);
    }

    /// 27.4.3.7 AsyncDisposableStack.prototype.use ( value )
    /// https://tc39.es/ecma262/#sec-asyncdisposablestack.prototype.use
    fn use(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const value = arguments.get(0);

        // 1. Let asyncDisposableStack be the this value.
        // 2. Perform ? RequireInternalSlot(asyncDisposableStack, [[AsyncDisposableState]]).
        const async_disposable_stack = try this_value.requireInternalSlot(agent, AsyncDisposableStack);

        const disposable_resource_stack = switch (async_disposable_stack.fields) {
            .pending => |*disposable_resource_stack| disposable_resource_stack,

            // 3. If asyncDisposableStack.[[AsyncDisposableState]] is disposed, throw a
            //    ReferenceError exception.
            .disposed => {
                return agent.throwException(.reference_error, "AsyncDisposableStack is disposed", .{});
            },
        };

        // 4. Perform ? AddDisposableResource(asyncDisposableStack.[[DisposableResourceStack]],
        //    value, async-dispose).
        try addDisposableResource(
            agent,
            disposable_resource_stack,
            value,
            .async_dispose,
            null,
        );

        // 5. Return value.
        return value;
    }
};

/// 27.4.4 Properties of AsyncDisposableStack Instances
/// https://tc39.es/ecma262/#sec-properties-of-asyncdisposablestack-instances
pub const AsyncDisposableStack = MakeObject(.{
    .Fields = union(enum) {
        /// [[AsyncDisposableState]]
        /// [[DisposableResourceStack]]
        pending: std.ArrayList(DisposableResource),
        disposed,
    },
    .tag = .async_disposable_stack,
    .display_name = "AsyncDisposableStack",
});
