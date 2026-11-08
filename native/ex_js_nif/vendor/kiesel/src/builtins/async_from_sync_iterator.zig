//! 27.1.5 Async-from-Sync Iterator Objects
//! https://tc39.es/ecma262/#sec-async-from-sync-iterator-objects

const std = @import("std");

const builtins = @import("../builtins.zig");
const execution = @import("../execution.zig");
const types = @import("../types.zig");
const utils = @import("../utils.zig");

const Agent = execution.Agent;
const Arguments = types.Arguments;
const Iterator = types.Iterator;
const MakeObject = types.MakeObject;
const Object = types.Object;
const PromiseCapability = builtins.promise.PromiseCapability;
const PropertyKey = types.PropertyKey;
const Realm = execution.Realm;
const Value = types.Value;
const createBuiltinFunction = builtins.createBuiltinFunction;
const createIteratorResultObject = types.createIteratorResultObject;
const newPromiseCapability = builtins.newPromiseCapability;
const noexcept = utils.noexcept;
const ordinaryObjectCreate = builtins.ordinaryObjectCreate;
const performPromiseThen = builtins.performPromiseThen;
const promiseResolve = builtins.promiseResolve;

/// 27.1.5.1 CreateAsyncFromSyncIterator ( syncIteratorRecord )
/// https://tc39.es/ecma262/#sec-createasyncfromsynciterator
pub fn createAsyncFromSyncIterator(
    agent: *Agent,
    sync_iterator: Iterator,
) std.mem.Allocator.Error!Iterator {
    const realm = agent.currentRealm();

    // 1. Let asyncIterator be OrdinaryObjectCreate(%AsyncFromSyncIteratorPrototype%,
    //    « [[SyncIteratorRecord]] »).
    // 2. Set asyncIterator.[[SyncIteratorRecord]] to syncIteratorRecord.
    const async_iterator = try AsyncFromSyncIterator.create(agent, .{
        .prototype = try realm.intrinsic(.async_from_sync_iterator_prototype),
        .fields = .{
            .sync_iterator = sync_iterator,
        },
    });

    // 3. Let nextMethod be ! Get(asyncIterator, "next").
    const next_method = async_iterator.object.get(
        agent,
        PropertyKey.from("next"),
    ) catch |err| try noexcept(err);

    // 4. Let iteratorRecord be the Iterator Record { [[Iterator]]: asyncIterator,
    //    [[NextMethod]]: nextMethod, [[Done]]: false }.
    const iterator: Iterator = .{
        .iterator = &async_iterator.object,
        .next_method = next_method,
        .done = false,
    };

    // 5. Return iteratorRecord.
    return iterator;
}

/// 27.1.5.2 The %AsyncFromSyncIteratorPrototype% Object
/// https://tc39.es/ecma262/#sec-%asyncfromsynciteratorprototype%-object
pub const prototype = struct {
    pub fn create(agent: *Agent, realm: *Realm) std.mem.Allocator.Error!*Object {
        return ordinaryObjectCreate(
            agent,
            try realm.intrinsic(.async_iterator_prototype),
        );
    }

    pub fn init(agent: *Agent, realm: *Realm, object: *Object) std.mem.Allocator.Error!void {
        try object.defineBuiltinFunction(agent, "next", next, 0, realm);
        try object.defineBuiltinFunction(agent, "return", @"return", 0, realm);
        try object.defineBuiltinFunction(agent, "throw", throw, 0, realm);
    }

    /// 27.1.5.2.1 %AsyncFromSyncIteratorPrototype%.next ( [ value ] )
    /// https://tc39.es/ecma262/#sec-%asyncfromsynciteratorprototype%.next
    fn next(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const realm = agent.currentRealm();
        const maybe_value = arguments.getOrNull(0);

        // 1. Let obj be the this value.
        // 2. Assert: obj is an Object that has a [[SyncIteratorRecord]] internal slot.
        const async_from_sync_iterator = this_value.asObject().as(AsyncFromSyncIterator);

        // 3. Let promiseCapability be ! NewPromiseCapability(%Promise%).
        const promise_capability = newPromiseCapability(
            agent,
            Value.from(try realm.intrinsic(.promise)),
        ) catch |err| try noexcept(err);

        // 4. Let syncIteratorRecord be obj.[[SyncIteratorRecord]].
        const sync_iterator = &async_from_sync_iterator.fields.sync_iterator;

        // 5. If value is present, then
        const result = (if (maybe_value) |value| blk: {
            // a. Let result be Completion(IteratorNext(syncIteratorRecord, value)).
            break :blk sync_iterator.next(agent, value);
        } else blk: {
            // 6. Else,
            // a. Let result be Completion(IteratorNext(syncIteratorRecord)).
            break :blk sync_iterator.next(agent, null);
        }) catch |err| {
            // 7. IfAbruptRejectPromise(result, promiseCapability).
            return Value.from(try promise_capability.rejectPromise(agent, err));
        };

        // 8. Return AsyncFromSyncIteratorContinuation(result, promiseCapability,
        //    syncIteratorRecord, true).
        return Value.from(
            try asyncFromSyncIteratorContinuation(
                agent,
                result,
                promise_capability,
                sync_iterator,
                true,
            ),
        );
    }

    /// 27.1.5.2.2 %AsyncFromSyncIteratorPrototype%.return ( [ value ] )
    /// https://tc39.es/ecma262/#sec-%asyncfromsynciteratorprototype%.return
    fn @"return"(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const realm = agent.currentRealm();
        const maybe_value = arguments.getOrNull(0);

        // 1. Let obj be the this value.
        // 2. Assert: obj is an Object that has a [[SyncIteratorRecord]] internal slot.
        const async_from_sync_iterator = this_value.asObject().as(AsyncFromSyncIterator);

        // 3. Let promiseCapability be ! NewPromiseCapability(%Promise%).
        const promise_capability = newPromiseCapability(
            agent,
            Value.from(try realm.intrinsic(.promise)),
        ) catch |err| try noexcept(err);

        // 4. Let syncIteratorRecord be obj.[[SyncIteratorRecord]].
        const sync_iterator = &async_from_sync_iterator.fields.sync_iterator;

        // 5. Let syncIterator be syncIteratorRecord.[[Iterator]].
        // 6. Let return be Completion(GetMethod(syncIterator, "return")).
        const return_ = sync_iterator.iterator.getMethod(agent, PropertyKey.from("return")) catch |err| {
            // 7. IfAbruptRejectPromise(return, promiseCapability).
            return Value.from(try promise_capability.rejectPromise(agent, err));
        } orelse {
            // 8. If return is undefined, then
            // a. Let iteratorResult be CreateIteratorResultObject(value, true).
            const iterator_result = try createIteratorResultObject(
                agent,
                maybe_value orelse .undefined,
                true,
            );

            // b. Perform ! Call(promiseCapability.[[Resolve]], undefined, « iteratorResult »).
            _ = promise_capability.resolve.call(
                agent,
                .undefined,
                &.{Value.from(iterator_result)},
            ) catch |err| try noexcept(err);

            // c. Return promiseCapability.[[Promise]].
            return Value.from(promise_capability.promise);
        };

        // 9. If value is present, then
        const result = (if (maybe_value) |value| blk: {
            // a. Let result be Completion(Call(return, syncIterator, « value »)).
            break :blk return_.call(agent, Value.from(sync_iterator.iterator), &.{value});
        } else blk: {
            // 10. Else,
            // a. Let result be Completion(Call(return, syncIterator)).
            break :blk return_.call(agent, Value.from(sync_iterator.iterator), &.{});
        }) catch |err| {
            // 11. IfAbruptRejectPromise(result, promiseCapability).
            return Value.from(try promise_capability.rejectPromise(agent, err));
        };

        // 12. If result is not an Object, then
        if (!result.isObject()) {
            const type_error = try agent.createErrorObject(
                .type_error,
                "Return value of iterator 'return' function must be object",
                .{},
            );

            // a. Perform ! Call(promiseCapability.[[Reject]], undefined, « a newly created
            //    TypeError object »).
            _ = promise_capability.reject.call(
                agent,
                .undefined,
                &.{Value.from(&type_error.object)},
            ) catch |err| try noexcept(err);

            // b. Return promiseCapability.[[Promise]].
            return Value.from(promise_capability.promise);
        }

        // 13. Return AsyncFromSyncIteratorContinuation(result, promiseCapability,
        //     syncIteratorRecord, false).
        return Value.from(
            try asyncFromSyncIteratorContinuation(
                agent,
                result.asObject(),
                promise_capability,
                sync_iterator,
                false,
            ),
        );
    }

    /// 27.1.5.2.3 %AsyncFromSyncIteratorPrototype%.throw ( [ value ] )
    /// https://tc39.es/ecma262/#sec-%asyncfromsynciteratorprototype%.throw
    fn throw(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const realm = agent.currentRealm();
        const maybe_value = arguments.getOrNull(0);

        // 1. Let obj be the this value.
        // 2. Assert: obj is an Object that has a [[SyncIteratorRecord]] internal slot.
        const async_from_sync_iterator = this_value.asObject().as(AsyncFromSyncIterator);

        // 3. Let promiseCapability be ! NewPromiseCapability(%Promise%).
        const promise_capability = newPromiseCapability(
            agent,
            Value.from(try realm.intrinsic(.promise)),
        ) catch |err| try noexcept(err);

        // 4. Let syncIteratorRecord be obj.[[SyncIteratorRecord]].
        const sync_iterator = &async_from_sync_iterator.fields.sync_iterator;

        // 5. Let syncIterator be syncIteratorRecord.[[Iterator]].
        // 6. Let throw be Completion(GetMethod(syncIterator, "throw")).
        const throw_ = sync_iterator.iterator.getMethod(agent, PropertyKey.from("throw")) catch |err| {
            // 7. IfAbruptRejectPromise(throw, promiseCapability).
            return Value.from(try promise_capability.rejectPromise(agent, err));
        } orelse {
            // 8. If throw is undefined, then

            // a. NOTE: If syncIterator does not have a `throw` method, close it to give it a chance
            //    to clean up before we reject the capability.

            // b. Let closeCompletion be NormalCompletion(empty).
            // c. Let result be Completion(IteratorClose(syncIteratorRecord, closeCompletion)).
            sync_iterator.close(agent, @as(Agent.Error!void, {})) catch |err| {
                // d. IfAbruptRejectPromise(result, promiseCapability).
                return Value.from(try promise_capability.rejectPromise(agent, err));
            };

            // e. NOTE: The next step throws a TypeError to indicate that there was a protocol
            //    violation: syncIterator does not have a `throw` method.
            // f. NOTE: If closing syncIterator does not throw then the result of that operation is
            //    ignored, even if it yields a rejected promise.

            const type_error = try agent.createErrorObject(
                .type_error,
                "Iterator does not have a 'throw' function",
                .{},
            );

            // g. Perform ! Call(promiseCapability.[[Reject]], undefined, « a newly created
            //    TypeError object »).
            _ = promise_capability.reject.call(
                agent,
                .undefined,
                &.{Value.from(&type_error.object)},
            ) catch |err| try noexcept(err);

            // h. Return promiseCapability.[[Promise]].
            return Value.from(promise_capability.promise);
        };

        // 9. If value is present, then
        const result = (if (maybe_value) |value| blk: {
            // a. Let result be Completion(Call(throw, syncIterator, « value »)).
            break :blk throw_.call(agent, Value.from(sync_iterator.iterator), &.{value});
        } else blk: {
            // 10. Else,
            // a. Let result be Completion(Call(throw, syncIterator)).
            break :blk throw_.call(agent, Value.from(sync_iterator.iterator), &.{});
        }) catch |err| {
            // 11. IfAbruptRejectPromise(result, promiseCapability).
            return Value.from(try promise_capability.rejectPromise(agent, err));
        };

        // 12. If result is not an Object, then
        if (!result.isObject()) {
            const type_error = try agent.createErrorObject(
                .type_error,
                "Return value of iterator 'throw' function must be object",
                .{},
            );

            // a. Perform ! Call(promiseCapability.[[Reject]], undefined, « a newly created
            //    TypeError object »).
            _ = promise_capability.reject.call(
                agent,
                .undefined,
                &.{Value.from(&type_error.object)},
            ) catch |err| try noexcept(err);

            // b. Return promiseCapability.[[Promise]].
            return Value.from(promise_capability.promise);
        }

        // 13. Return AsyncFromSyncIteratorContinuation(result, promiseCapability,
        //     syncIteratorRecord, true).
        return Value.from(
            try asyncFromSyncIteratorContinuation(
                agent,
                result.asObject(),
                promise_capability,
                sync_iterator,
                true,
            ),
        );
    }
};

/// 27.1.5.3 Properties of Async-from-Sync Iterator Instances
/// https://tc39.es/ecma262/#sec-properties-of-async-from-sync-iterator-instances
pub const AsyncFromSyncIterator = MakeObject(.{
    .Fields = struct {
        /// [[SyncIteratorRecord]]
        sync_iterator: Iterator,
    },
    .tag = .async_from_sync_iterator,
    .display_name = "Async-from-Sync Iterator",
});

/// 27.1.5.4 AsyncFromSyncIteratorContinuation ( result, promiseCapability, syncIteratorRecord, closeOnRejection )
/// https://tc39.es/ecma262/#sec-asyncfromsynciteratorcontinuation
fn asyncFromSyncIteratorContinuation(
    agent: *Agent,
    result: *Object,
    promise_capability: PromiseCapability,
    sync_iterator: *Iterator,
    close_on_rejection: bool,
) std.mem.Allocator.Error!*Object {
    const realm = agent.currentRealm();

    // 1. NOTE: Because promiseCapability is derived from the intrinsic %Promise%, the calls to
    //    promiseCapability.[[Reject]] entailed by the use IfAbruptRejectPromise below are
    //    guaranteed not to throw.

    // 2. Let done be Completion(IteratorComplete(result)).
    const done = Iterator.complete(agent, result) catch |err| {
        // 3. IfAbruptRejectPromise(done, promiseCapability).
        return promise_capability.rejectPromise(agent, err) catch |err_| try noexcept(err_);
    };

    // 4. Let value be Completion(IteratorValue(result)).
    const value = Iterator.value(agent, result) catch |err| {
        // 5. IfAbruptRejectPromise(value, promiseCapability).
        return promise_capability.rejectPromise(agent, err) catch |err_| try noexcept(err_);
    };

    // 6. Let valueWrapper be Completion(PromiseResolve(%Promise%, value)).
    const value_wrapper = promiseResolve(agent, try realm.intrinsic(.promise), value) catch |err| {
        // 7. If valueWrapper is an abrupt completion, done is false, and closeOnRejection is true,
        //    then
        if (!done and close_on_rejection) {
            // a. Set valueWrapper to Completion(IteratorClose(syncIteratorRecord, valueWrapper)).
            _ = sync_iterator.close(agent, @as(Agent.Error!Value, err)) catch |err_| {
                return promise_capability.rejectPromise(agent, err_) catch |err__| try noexcept(err__);
            };
            unreachable;
        }

        // 8. IfAbruptRejectPromise(valueWrapper, promiseCapability).
        return promise_capability.rejectPromise(agent, err) catch |err_| try noexcept(err_);
    };

    const UnwrapClosureCaptures = struct {
        done: bool,
    };
    const unwrap_closure_captures = try agent.gc_allocator.create(UnwrapClosureCaptures);
    unwrap_closure_captures.* = .{ .done = done };

    // 9. Let unwrap be a new Abstract Closure with parameters (value) that captures done and
    //    performs the following steps when called:
    const unwrap = struct {
        fn func(agent_: *Agent, _: Value, arguments_: Arguments) Agent.Error!Value {
            const function = agent_.activeFunctionObject();
            const captures = function.as(builtins.BuiltinFunction).fields.additionalFieldsAs(UnwrapClosureCaptures);
            const done_ = captures.done;
            const value_ = arguments_.get(0);

            // a. Return CreateIteratorResultObject(value, done).
            return Value.from(try createIteratorResultObject(agent_, value_, done_));
        }
    }.func;

    // 10. Let onFulfilled be CreateBuiltinFunction(unwrap, 1, "", « »).
    const on_fulfilled = try createBuiltinFunction(
        agent,
        .{ .function = unwrap },
        1,
        "",
        .{ .additional_fields = unwrap_closure_captures },
    );

    // 11. NOTE: onFulfilled is used when processing the "value" property of an IteratorResult
    //     object in order to wait for its value if it is a promise and re-package the result in a
    //     new “unwrapped” IteratorResult object.

    // 12. If done is true or closeOnRejection is false, then
    const maybe_on_rejected = if (done or !close_on_rejection) blk: {
        // a. Let onRejected be undefined.
        break :blk null;
    } else blk: {
        // 13. Else,

        const CloseIteratorClosureCaptures = struct {
            sync_iterator: *Iterator,
        };
        const close_iterator_closure_captures = try agent.gc_allocator.create(CloseIteratorClosureCaptures);
        close_iterator_closure_captures.* = .{ .sync_iterator = sync_iterator };

        // a. Let closeIterator be a new Abstract Closure with parameters (error) that captures
        //    syncIteratorRecord and performs the following steps when called:
        const close_iterator = struct {
            fn func(agent_: *Agent, _: Value, arguments_: Arguments) Agent.Error!Value {
                const function = agent_.activeFunctionObject();
                const captures = function.as(builtins.BuiltinFunction).fields.additionalFieldsAs(CloseIteratorClosureCaptures);
                const sync_iterator_ = captures.sync_iterator;
                const @"error" = arguments_.get(0);

                agent_.exception = .{
                    .value = @"error",
                    .stack_trace = try agent_.captureStackTrace(.{}),
                };

                // i. Return ? IteratorClose(syncIteratorRecord, ThrowCompletion(error)).
                return sync_iterator_.close(agent_, @as(Agent.Error!Value, error.ExceptionThrown));
            }
        }.func;

        // b. Let onRejected be CreateBuiltinFunction(closeIterator, 1, "", « »).
        // c. NOTE: onRejected is used to close the Iterator when the "value" property of an
        //    IteratorResult object it yields is a rejected promise.
        break :blk try createBuiltinFunction(
            agent,
            .{ .function = close_iterator },
            1,
            "",
            .{ .additional_fields = close_iterator_closure_captures },
        );
    };

    // 14. Perform PerformPromiseThen(valueWrapper, onFulfilled, onRejected, promiseCapability).
    _ = try performPromiseThen(
        agent,
        value_wrapper.as(builtins.Promise),
        Value.from(&on_fulfilled.object),
        if (maybe_on_rejected) |on_rejected| Value.from(&on_rejected.object) else .undefined,
        promise_capability,
    );

    // 15. Return promiseCapability.[[Promise]].
    return promise_capability.promise;
}
