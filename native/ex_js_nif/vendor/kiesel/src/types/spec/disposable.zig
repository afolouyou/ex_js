//! 7.5 Operations on Disposable Objects
//! https://tc39.es/ecma262/#sec-operations-on-disposable-objects

const std = @import("std");

const builtins = @import("../../builtins.zig");
const execution = @import("../../execution.zig");
const types = @import("../../types.zig");
const utils = @import("../../utils.zig");

const Agent = execution.Agent;
const Arguments = types.Arguments;
const Object = types.Object;
const PropertyKey = types.PropertyKey;
const String = types.String;
const Value = types.Value;
const await = builtins.await;
const createBuiltinFunction = builtins.createBuiltinFunction;
const newPromiseCapability = builtins.newPromiseCapability;
const noexcept = utils.noexcept;
const ordinaryCreateFromConstructor = builtins.ordinaryCreateFromConstructor;

/// 7.5.1 DisposableResource Records
/// https://tc39.es/ecma262/#sec-disposableresource-records
pub const DisposableResource = struct {
    pub const Kind = enum {
        sync_dispose,
        async_dispose,
    };

    /// [[ResourceValue]]
    resource_value: ?*Object,

    /// [[Kind]]
    kind: Kind,

    /// [[DisposeMethod]]
    dispose_method: ?*Object,
};

/// 7.5.2 AddDisposableResource ( disposableResourceStack, value, kind [ , method ] )
/// https://tc39.es/ecma262/#sec-adddisposableresource
pub fn addDisposableResource(
    agent: *Agent,
    disposable_resource_stack: *std.ArrayList(DisposableResource),
    value: Value,
    kind: DisposableResource.Kind,
    maybe_method: ?*Object,
) Agent.Error!void {
    // 1. If method is present, then
    const resource = if (maybe_method) |method| blk: {
        // a. Assert: value is undefined.
        std.debug.assert(value.isUndefined());

        // b. Let resource be ? CreateDisposableResource(undefined, kind, method).
        break :blk try createDisposableResource(agent, .undefined, kind, method);
    } else blk: {
        // 2. Else,
        // a. If value is either null or undefined and kind is sync-dispose, return unused.
        // b. NOTE: When value is either null or undefined and kind is async-dispose, we record that
        //    the resource was evaluated to ensure we will still perform an Await when resources are
        //    later disposed.
        if ((value.isNull() or value.isUndefined()) and kind == .sync_dispose) {
            return;
        }

        // c. Let resource be ? CreateDisposableResource(value, kind).
        break :blk try createDisposableResource(agent, value, kind, null);
    };

    // 3. Append resource to disposableResourceStack.
    try disposable_resource_stack.append(agent.gc_allocator, resource);

    // 4. Return unused.
}

/// 7.5.3 CreateDisposableResource ( value, kind [ , method ] )
/// https://tc39.es/ecma262/#sec-createdisposableresource
pub fn createDisposableResource(
    agent: *Agent,
    value: Value,
    kind: DisposableResource.Kind,
    maybe_method: ?*Object,
) Agent.Error!DisposableResource {
    // 1. If method is not present, then
    const resource_value, const method = if (maybe_method) |method| blk: {
        std.debug.assert(value.isUndefined());
        break :blk .{ null, method };
    } else blk: {
        // a. If value is either null or undefined, then
        if (value.isNull() or value.isUndefined()) {
            // i. Set value to undefined.
            // ii. Set method to undefined.
            break :blk .{ null, null };
        } else {
            // b. Else,
            // i. Set method to ? GetDisposeMethod(value, kind).
            const method = try getDisposeMethod(agent, value, kind) orelse {
                // ii. If method is undefined, throw a TypeError exception.
                return agent.throwException(.type_error, "{f} is not disposable", .{value});
            };
            break :blk .{ value.asObject(), method };
        }
    };

    // 2. Return the DisposableResource Record { [[ResourceValue]]: value, [[Kind]]: kind,
    //    [[DisposeMethod]]: method }.
    return .{
        .resource_value = resource_value,
        .kind = kind,
        .dispose_method = method,
    };
}

/// 7.5.4 GetDisposeMethod ( value, kind )
/// https://tc39.es/ecma262/#sec-getdisposemethod
pub fn getDisposeMethod(
    agent: *Agent,
    value: Value,
    kind: DisposableResource.Kind,
) Agent.Error!?*Object {
    // 1. If value is not an Object, throw a TypeError exception.
    if (!value.isObject()) {
        return agent.throwException(.type_error, "{f} is not an Object", .{value});
    }

    switch (kind) {
        // 2. If kind is sync-dispose, return ? GetMethod(value, %Symbol.dispose%).
        .sync_dispose => {
            return value.getMethod(agent, PropertyKey.from(agent.well_known_symbols.dispose));
        },

        // 3. Assert: kind is async-dispose.
        .async_dispose => {},
    }

    // 4. Let asyncMethod be ? GetMethod(value, %Symbol.asyncDispose%).
    const maybe_async_method = try value.getMethod(
        agent,
        PropertyKey.from(agent.well_known_symbols.async_dispose),
    );

    // 5. If asyncMethod is not undefined, return asyncMethod.
    if (maybe_async_method) |async_method| return async_method;

    // 6. Let syncMethod be ? GetMethod(value, %Symbol.dispose%).
    const sync_method = try value.getMethod(
        agent,
        PropertyKey.from(agent.well_known_symbols.dispose),
    ) orelse {
        // 7. If syncMethod is undefined, return undefined.
        return null;
    };

    const Captures = struct {
        sync_method: *Object,
    };
    const captures = try agent.gc_allocator.create(Captures);
    captures.* = .{ .sync_method = sync_method };

    // 8. Let closure be a new Abstract Closure with no parameters that captures syncMethod and
    //    performs the following steps when called:
    const closure = struct {
        fn func(agent_: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
            const realm = agent_.currentRealm();
            const function = agent_.activeFunctionObject();
            const captures_ = function.as(builtins.BuiltinFunction).fields.additionalFieldsAs(Captures);
            const sync_method_ = captures_.sync_method;

            // a. Let obj be the this value.
            const obj = this_value;

            // b. Let promiseCapability be ! NewPromiseCapability(%Promise%).
            const promise_capability = newPromiseCapability(
                agent_,
                Value.from(try realm.intrinsic(.promise)),
            ) catch |err| try noexcept(err);

            // c. Let result be Completion(Call(syncMethod, obj)).
            _ = sync_method_.call(agent_, obj, &.{}) catch |err| {
                // d. IfAbruptRejectPromise(result, promiseCapability).
                return Value.from(try promise_capability.rejectPromise(agent_, err));
            };

            // e. Perform ! Call(promiseCapability.[[Resolve]], undefined, « undefined »).
            _ = promise_capability.resolve.call(
                agent_,
                .undefined,
                &.{.undefined},
            ) catch |err| try noexcept(err);

            // f. Return promiseCapability.[[Promise]].
            return Value.from(promise_capability.promise);
        }
    }.func;

    // 9. NOTE: This function is not observable to user code. It is used to ensure that a Promise
    //    returned from a synchronous `%Symbol.dispose%` method will not be awaited and that a
    //    synchronous exception will be translated to a rejected Promise.
    // 10. Return CreateBuiltinFunction(closure, 0, "", « »).
    const func = try createBuiltinFunction(
        agent,
        .{ .function = closure },
        0,
        "",
        .{ .additional_fields = captures },
    );
    return &func.object;
}

/// 7.5.5 DisposeResources ( disposableResourceStack, completion )
/// https://tc39.es/ecma262/#sec-disposeresources
pub fn disposeResources(
    agent: *Agent,
    disposable_resource_stack: *std.ArrayList(DisposableResource),
    completion: Agent.Error!Value,
) Agent.Error!Value {
    const realm = agent.currentRealm();

    // 1. Let needsAwait be false.
    var needs_await = false;

    // 2. Let hasAwaited be false.
    var has_awaited = false;

    // 3. Let outputCompletion be completion.
    var maybe_output_exception: ?Agent.Exception = null;
    _ = completion catch {
        maybe_output_exception = agent.clearException();
    };

    // 4. For each element resource of disposableResourceStack, in reverse List order, do
    var it = std.mem.reverseIterator(disposable_resource_stack.items);
    while (it.next()) |resource| {
        // a. Let value be resource.[[ResourceValue]].
        const value = if (resource.resource_value) |obj| Value.from(obj) else Value.undefined;

        // b. Let kind be resource.[[Kind]].
        const kind = resource.kind;

        // c. Let method be resource.[[DisposeMethod]].
        const maybe_method = resource.dispose_method;

        // d. If kind is sync-dispose, needsAwait is true, and hasAwaited is false, then
        if (kind == .sync_dispose and needs_await and !has_awaited) {
            // i. Perform ! Await(undefined).
            _ = await(agent, .undefined) catch |err| try noexcept(err);

            // ii. Set needsAwait to false.
            needs_await = false;
        }

        // e. If method is not undefined, then
        if (maybe_method) |method| {
            // i. Let result be Completion(Call(method, value)).
            var result = method.call(agent, value, &.{});

            // ii. If result is a normal completion and kind is async-dispose, then
            if (kind == .async_dispose) {
                if (result) |result_value| {
                    // 1. Set result to Completion(Await(result.[[Value]])).
                    result = await(agent, result_value);

                    // 2. Set hasAwaited to true.
                    has_awaited = true;
                } else |_| {}
            }

            // iii. If result is a throw completion, then
            _ = result catch {
                const result_exception = agent.clearException();

                // 1. If outputCompletion is a throw completion, then
                if (maybe_output_exception) |output_exception| {
                    // a. Set result to result.[[Value]].
                    const result_value = result_exception.value;

                    // b. Let suppressed be outputCompletion.[[Value]].
                    const suppressed = output_exception.value;

                    // c. Let error be a newly created SuppressedError object.
                    const @"error" = try ordinaryCreateFromConstructor(
                        builtins.SuppressedError,
                        agent,
                        try realm.intrinsic(.suppressed_error),
                        .suppressed_error_prototype,
                        .{
                            .name = String.fromLiteral("SuppressedError"),
                            .message = String.fromLiteral("Error during disposal"),
                            .stack_trace = result_exception.stack_trace,
                        },
                    );

                    // d. Perform CreateNonEnumerableDataPropertyOrThrow(error, "error", result).
                    try @"error".object.createNonEnumerableDataPropertyOrThrow(
                        agent,
                        PropertyKey.from("error"),
                        result_value,
                    );

                    // e. Perform CreateNonEnumerableDataPropertyOrThrow(error, "suppressed",
                    //    suppressed).
                    try @"error".object.createNonEnumerableDataPropertyOrThrow(
                        agent,
                        PropertyKey.from("suppressed"),
                        suppressed,
                    );

                    // f. Set outputCompletion to ThrowCompletion(error).
                    maybe_output_exception = .{
                        .value = Value.from(&@"error".object),
                        .stack_trace = result_exception.stack_trace,
                    };
                } else {
                    // 2. Else,
                    // a. Set outputCompletion to result.
                    maybe_output_exception = result_exception;
                }
            };
        } else {
            // f. Else,
            // i. Assert: kind is async-dispose.
            std.debug.assert(kind == .async_dispose);

            // ii. Set needsAwait to true.
            needs_await = true;

            // iii. NOTE: This can only indicate a case where either null or undefined was the
            //      initialized value of an `await using` declaration.
        }
    }

    // 5. If needsAwait is true and hasAwaited is false, then
    if (needs_await and !has_awaited) {
        // a. Perform ! Await(undefined).
        _ = await(agent, .undefined) catch |err| try noexcept(err);
    }

    // 6. NOTE: At this point disposableResourceStack will never be used again. The contents of
    //    disposableResourceStack can be discarded in implementations, such as by garbage
    //    collection.
    disposable_resource_stack.clearRetainingCapacity();

    // 7. Return ? outputCompletion.
    if (maybe_output_exception) |output_exception| {
        agent.exception = output_exception;
        return error.ExceptionThrown;
    }
    return completion;
}
