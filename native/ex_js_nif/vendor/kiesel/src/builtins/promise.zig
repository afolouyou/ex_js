//! 27.5 Promise Objects
//! https://tc39.es/ecma262/#sec-promise-objects

const std = @import("std");

const builtins = @import("../builtins.zig");
const execution = @import("../execution.zig");
const types = @import("../types.zig");

const Agent = execution.Agent;
const Arguments = types.Arguments;
const Iterator = types.Iterator;
const Job = execution.Job;
const MakeObject = types.MakeObject;
const Object = types.Object;
const PropertyKey = types.PropertyKey;
const Realm = execution.Realm;
const Value = types.Value;
const createArrayFromList = types.createArrayFromList;
const createBuiltinFunction = builtins.createBuiltinFunction;
const getIterator = types.getIterator;
const ordinaryCreateFromConstructor = builtins.ordinaryCreateFromConstructor;
const ordinaryObjectCreate = builtins.ordinaryObjectCreate;
const sameValue = types.sameValue;

/// 27.5.1.1 PromiseCapability Records
/// https://tc39.es/ecma262/#sec-promisecapability-records
pub const PromiseCapability = struct {
    /// [[Promise]]
    promise: *Object,

    /// [[Resolve]]
    resolve: *Object,

    /// [[Reject]]
    reject: *Object,

    /// 27.5.1.1.1 IfAbruptRejectPromise ( value, capability )
    /// https://tc39.es/ecma262/#sec-ifabruptrejectpromise
    pub fn rejectPromise(self: @This(), agent: *Agent, err: Agent.Error) Agent.Error!*Object {
        // 1. Assert: value is a Completion Record.
        switch (err) {
            error.OutOfMemory => |e| return e,

            // 2. If value is an abrupt completion, then
            error.ExceptionThrown => {
                const exception = agent.clearException();

                // a. Perform ? Call(capability.[[Reject]], undefined, « value.[[Value]] »).
                _ = try self.reject.call(agent, .undefined, &.{exception.value});

                // b. Return capability.[[Promise]].
                return self.promise;
            },
        }

        // 3. Set value to ! value.
        // NOTE: This has to be handled at the call site.
    }
};

/// 27.5.1.2 PromiseReaction Records
/// https://tc39.es/ecma262/#sec-promisereaction-records
const PromiseReaction = struct {
    /// [[Capability]]
    capability: ?PromiseCapability,

    /// [[Type]]
    type: enum { fulfill, reject },

    /// [[Handler]]
    handler: ?Job.Callback,
};

const ResolvingFunctions = struct {
    resolve: *builtins.BuiltinFunction,
    reject: *builtins.BuiltinFunction,
};

/// 27.5.1.3 CreateResolvingFunctions ( toResolve )
/// https://tc39.es/ecma262/#sec-createresolvingfunctions
pub fn createResolvingFunctions(
    agent: *Agent,
    to_resolve: *Promise,
) std.mem.Allocator.Error!ResolvingFunctions {
    const PromiseOrEmpty = struct { value: ?*Promise };

    const AdditionalFields = struct {
        promise_or_empty: PromiseOrEmpty,
    };
    const additional_fields = try agent.gc_allocator.create(AdditionalFields);
    additional_fields.* = .{
        // 1. Let promiseOrEmpty be the Record { [[Value]]: toResolve }.
        .promise_or_empty = .{ .value = to_resolve },
    };

    // 2. Let resolveSteps be a new Abstract Closure with parameters (resolution) that captures
    //    promiseOrEmpty and performs the following steps when called:
    const resolve_steps = struct {
        fn func(agent_: *Agent, _: Value, arguments: Arguments) Agent.Error!Value {
            const resolution = arguments.get(0);

            const function = agent_.activeFunctionObject();
            const additional_fields_ = function.as(builtins.BuiltinFunction).fields.additionalFieldsAs(AdditionalFields);
            const promise_or_empty_ = &additional_fields_.promise_or_empty;

            // a. If promiseOrEmpty.[[Value]] is empty, return undefined.
            // b. Let promise be promiseOrEmpty.[[Value]].
            const promise_ = promise_or_empty_.value orelse return .undefined;

            // c. Set promiseOrEmpty.[[Value]] to empty.
            promise_or_empty_.value = null;

            // d. If SameValue(resolution, promise) is true, then
            if (sameValue(resolution, Value.from(&promise_.object))) {
                // i. Let selfResolutionError be a newly created TypeError object.
                const self_resolution_error = try agent_.createErrorObject(
                    .type_error,
                    "Cannot resolve promise with itself",
                    .{},
                );

                // ii. Perform RejectPromise(promise, selfResolutionError).
                try rejectPromise(agent_, promise_, Value.from(&self_resolution_error.object));

                // iii. Return undefined.
                return .undefined;
            }

            // e. If resolution is not an Object, then
            if (!resolution.isObject()) {
                // i. Perform FulfillPromise(promise, resolution).
                try fulfillPromise(agent_, promise_, resolution);

                // ii. Return undefined.
                return .undefined;
            }

            // f. Let then be Completion(Get(resolution, "then")).
            // h. Let thenAction be then.[[Value]].
            const then_action = resolution.asObject().get(
                agent_,
                PropertyKey.from("then"),
            ) catch |err| switch (err) {
                error.OutOfMemory => |e| return e,

                // g. If then is an abrupt completion, then
                error.ExceptionThrown => {
                    const exception = agent_.clearException();

                    // i. Perform RejectPromise(promise, then.[[Value]]).
                    try rejectPromise(agent_, promise_, exception.value);

                    // ii. Return undefined.
                    return .undefined;
                },
            };

            // i. If IsCallable(thenAction) is false, then
            if (!then_action.isCallable()) {
                // i. Perform FulfillPromise(promise, resolution).
                try fulfillPromise(agent_, promise_, resolution);

                // ii. Return undefined.
                return .undefined;
            }

            // j. Let thenJobCallback be HostMakeJobCallback(thenAction).
            const then_job_callback = agent_.host_hooks.hostMakeJobCallback(then_action.asObject());

            // k. Let job be NewPromiseResolveThenableJob(promise, resolution, thenJobCallback).
            const job = try newPromiseResolveThenableJob(
                agent_,
                promise_,
                resolution.asObject(),
                then_job_callback,
            );

            // l. Perform HostEnqueuePromiseJob(job.[[Job]], job.[[Realm]]).
            try agent_.host_hooks.hostEnqueuePromiseJob(agent_, job.job, job.realm);

            // m. Return undefined.
            return .undefined;
        }
    }.func;

    // 3. Let resolve be CreateBuiltinFunction(resolveSteps, 1, "", « »).
    const resolve = try createBuiltinFunction(
        agent,
        .{ .function = resolve_steps },
        1,
        "",
        .{ .additional_fields = additional_fields },
    );

    // 4. Let rejectSteps be a new Abstract Closure with parameters (reason) that captures
    //    promiseOrEmpty and performs the following steps when called:
    const reject_steps = struct {
        fn func(agent_: *Agent, _: Value, arguments: Arguments) Agent.Error!Value {
            const reason = arguments.get(0);

            const function = agent_.activeFunctionObject();
            const additional_fields_ = function.as(builtins.BuiltinFunction).fields.additionalFieldsAs(AdditionalFields);
            const promise_or_empty_ = &additional_fields_.promise_or_empty;

            // a. If promiseOrEmpty.[[Value]] is empty, return undefined.
            // b. Let promise be promiseOrEmpty.[[Value]].
            const promise_ = promise_or_empty_.value orelse return .undefined;

            // c. Set promiseOrEmpty.[[Value]] to empty.
            promise_or_empty_.value = null;

            // d. Perform RejectPromise(promise, reason).
            try rejectPromise(agent_, promise_, reason);

            // e. Return undefined.
            return .undefined;
        }
    }.func;

    // 5. Let reject be CreateBuiltinFunction(rejectSteps, 1, "", « »).
    const reject = try createBuiltinFunction(
        agent,
        .{ .function = reject_steps },
        1,
        "",
        .{ .additional_fields = additional_fields },
    );

    // 6. Return the Record { [[Resolve]]: resolve, [[Reject]]: reject }.
    return .{ .resolve = resolve, .reject = reject };
}

/// 27.5.1.4 FulfillPromise ( promise, value )
/// https://tc39.es/ecma262/#sec-fulfillpromise
pub fn fulfillPromise(
    agent: *Agent,
    promise: *Promise,
    value: Value,
) std.mem.Allocator.Error!void {
    // 1. Assert: promise.[[PromiseState]] is pending.
    std.debug.assert(promise.fields.promise_state == .pending);

    // 2. Let reactions be promise.[[PromiseFulfillReactions]].
    const reactions = &promise.fields.promise_fulfill_reactions;

    // 3. Set promise.[[PromiseResult]] to value.
    promise.fields.promise_result = value;

    // 4. Set promise.[[PromiseFulfillReactions]] to undefined.
    defer promise.fields.promise_fulfill_reactions.deinit(agent.gc_allocator);

    // 5. Set promise.[[PromiseRejectReactions]] to undefined.
    defer promise.fields.promise_reject_reactions.deinit(agent.gc_allocator);

    // 6. Set promise.[[PromiseState]] to fulfilled.
    promise.fields.promise_state = .fulfilled;

    // 7. Perform TriggerPromiseReactions(reactions, value).
    try triggerPromiseReactions(agent, reactions.items, value);

    // 8. Return unused.
}

/// 27.5.1.5 NewPromiseCapability ( ctor )
/// https://tc39.es/ecma262/#sec-newpromisecapability
pub fn newPromiseCapability(agent: *Agent, ctor: Value) Agent.Error!PromiseCapability {
    // 1. If IsConstructor(ctor) is false, throw a TypeError exception.
    if (!ctor.isConstructor()) {
        return agent.throwException(.type_error, "{f} is not a constructor", .{ctor});
    }

    // 2. NOTE: ctor is assumed to be a constructor function that supports the parameter conventions
    //    of the Promise constructor (see 27.5.3.1).

    // 3. Let resolvingFuncs be the Record { [[Resolve]]: undefined, [[Reject]]: undefined }.
    // NOTE: This is created later.

    const AdditionalFields = struct {
        resolving_funcs: struct {
            resolve: Value,
            reject: Value,
        },
    };

    // 4. Let executorClosure be a new Abstract Closure with parameters (resolve, reject) that
    //    captures resolvingFuncs and performs the following steps when called:
    const executor_closure = struct {
        fn func(agent_: *Agent, _: Value, arguments: Arguments) Agent.Error!Value {
            const resolve = arguments.get(0);
            const reject = arguments.get(1);
            const function = agent_.activeFunctionObject();
            const additional_fields = function.as(builtins.BuiltinFunction).fields.additionalFieldsAs(AdditionalFields);
            const resolving_funcs_ = &additional_fields.resolving_funcs;

            // a. If resolvingFuncs.[[Resolve]] is not undefined, throw a TypeError exception.
            if (!resolving_funcs_.resolve.isUndefined()) {
                return agent_.throwException(
                    .type_error,
                    "Resolve function has already been set",
                    .{},
                );
            }
            // b. If resolvingFuncs.[[Reject]] is not undefined, throw a TypeError exception.
            if (!resolving_funcs_.reject.isUndefined()) {
                return agent_.throwException(
                    .type_error,
                    "Reject function has already been set",
                    .{},
                );
            }

            // c. Set resolvingFuncs.[[Resolve]] to resolve.
            resolving_funcs_.resolve = resolve;

            // d. Set resolvingFuncs.[[Reject]] to reject.
            resolving_funcs_.reject = reject;

            // e. Return NormalCompletion(undefined).
            return .undefined;
        }
    }.func;

    // 5. Let executor be CreateBuiltinFunction(executorClosure, 2, "", « »).
    const additional_fields = try agent.gc_allocator.create(AdditionalFields);
    const executor = try createBuiltinFunction(
        agent,
        .{ .function = executor_closure },
        2,
        "",
        .{ .additional_fields = additional_fields },
    );

    // NOTE: This struct can outlive the function scope if anything holds on to the callback above.
    additional_fields.* = .{
        .resolving_funcs = .{ .resolve = .undefined, .reject = .undefined },
    };
    const resolving_funcs = &additional_fields.resolving_funcs;

    // 6. Let promise be ? Construct(ctor, « executor »).
    const promise = try ctor.asObject().construct(
        agent,
        &.{Value.from(&executor.object)},
        null,
    );

    // 7. If IsCallable(resolvingFuncs.[[Resolve]]) is false, throw a TypeError exception.
    if (!resolving_funcs.resolve.isCallable()) {
        return agent.throwException(.type_error, "{f} is not callable", .{resolving_funcs.resolve});
    }

    // 8. If IsCallable(resolvingFuncs.[[Reject]]) is false, throw a TypeError exception.
    if (!resolving_funcs.reject.isCallable()) {
        return agent.throwException(
            .type_error,
            "{f} is not callable",
            .{resolving_funcs.reject},
        );
    }

    // 9. Return the PromiseCapability Record { [[Promise]]: promise,
    //    [[Resolve]]: resolvingFuncs.[[Resolve]], [[Reject]]: resolvingFuncs.[[Reject]] }.
    return .{
        .promise = promise,
        .resolve = resolving_funcs.resolve.asObject(),
        .reject = resolving_funcs.reject.asObject(),
    };
}

/// 27.5.1.7 RejectPromise ( promise, reason )
/// https://tc39.es/ecma262/#sec-rejectpromise
pub fn rejectPromise(
    agent: *Agent,
    promise: *Promise,
    reason: Value,
) std.mem.Allocator.Error!void {
    // 1. Assert: promise.[[PromiseState]] is pending.
    std.debug.assert(promise.fields.promise_state == .pending);

    // 2. Let reactions be promise.[[PromiseRejectReactions]].
    const reactions = promise.fields.promise_reject_reactions;

    // 3. Set promise.[[PromiseResult]] to reason.
    promise.fields.promise_result = reason;

    // 4. Set promise.[[PromiseFulfillReactions]] to undefined.
    defer promise.fields.promise_fulfill_reactions.deinit(agent.gc_allocator);

    // 5. Set promise.[[PromiseRejectReactions]] to undefined.
    defer promise.fields.promise_reject_reactions.deinit(agent.gc_allocator);

    // 6. Set promise.[[PromiseState]] to rejected.
    promise.fields.promise_state = .rejected;

    // 7. If promise.[[PromiseIsHandled]] is false, perform HostPromiseRejectionTracker(promise,
    //    "reject").
    if (!promise.fields.promise_is_handled) {
        agent.host_hooks.hostPromiseRejectionTracker(agent, promise, .reject);
    }

    // 8. Perform TriggerPromiseReactions(reactions, reason).
    try triggerPromiseReactions(agent, reactions.items, reason);

    // 9. Return unused.
}

/// 27.5.1.8 TriggerPromiseReactions ( reactions, arg )
/// https://tc39.es/ecma262/#sec-triggerpromisereactions
pub fn triggerPromiseReactions(
    agent: *Agent,
    reactions: []const PromiseReaction,
    arg: Value,
) std.mem.Allocator.Error!void {
    // 1. For each element reaction of reactions, do
    for (reactions) |reaction| {
        // a. Let job be NewPromiseReactionJob(reaction, arg).
        const job = try newPromiseReactionJob(agent, reaction, arg);

        // b. Perform HostEnqueuePromiseJob(job.[[Job]], job.[[Realm]]).
        try agent.host_hooks.hostEnqueuePromiseJob(agent, job.job, job.realm);
    }

    // 2. Return unused.
}

/// 27.5.4.7.1 PromiseResolve ( ctor, resolution )
/// https://tc39.es/ecma262/#sec-promise-resolve
pub fn promiseResolve(agent: *Agent, ctor: *Object, resolution: Value) Agent.Error!*Object {
    // 1. If IsPromise(resolution) is true, then
    if (resolution.isPromise()) {
        // a. Let resolutionCtor be ? Get(resolution, "constructor").
        const resolution_ctor = try resolution.asObject().get(agent, PropertyKey.from("constructor"));

        // b. If SameValue(resolutionCtor, ctor) is true, return resolution.
        if (sameValue(resolution_ctor, Value.from(ctor))) return resolution.asObject();
    }

    // 2. Let promiseCapability be ? NewPromiseCapability(ctor).
    const promise_capability = try newPromiseCapability(agent, Value.from(ctor));

    // 3. Perform ? Call(promiseCapability.[[Resolve]], undefined, « resolution »).
    _ = try promise_capability.resolve.call(agent, .undefined, &.{resolution});

    // 4. Return promiseCapability.[[Promise]].
    return promise_capability.promise;
}

/// 27.5.2.1 NewPromiseReactionJob ( reaction, arg )
/// https://tc39.es/ecma262/#sec-newpromisereactionjob
pub fn newPromiseReactionJob(
    agent: *Agent,
    reaction: PromiseReaction,
    arg: Value,
) std.mem.Allocator.Error!struct { job: Job, realm: ?*Realm } {
    const Captures = struct {
        agent: *Agent,
        reaction: PromiseReaction,
        arg: Value,
    };
    const captures = try agent.gc_allocator.create(Captures);
    captures.* = .{ .agent = agent, .reaction = reaction, .arg = arg };

    // 1. Let job be a new Job Abstract Closure with no parameters that captures reaction and arg
    //    and performs the following steps when called:
    const func = struct {
        fn func(captures_ptr: *anyopaque) Agent.Error!Value {
            const captures_: *Captures = @ptrCast(@alignCast(captures_ptr));
            const agent_ = captures_.agent;
            const reaction_ = captures_.reaction;
            const arg_ = captures_.arg;

            // a. Let promiseCapability be reaction.[[Capability]].
            const maybe_promise_capability = reaction_.capability;

            // b. Let type be reaction.[[Type]].
            const @"type" = reaction_.type;

            // c. Let handler be reaction.[[Handler]].
            const handler = reaction_.handler;

            const Result = union(enum) {
                resolve: Value,
                reject: Value,
            };

            // d. If handler is empty, then
            const handler_result: Result = if (handler == null) blk: {
                switch (@"type") {
                    // i. If type is fulfill, then
                    .fulfill => {
                        // 1. Let handlerResult be NormalCompletion(arg).
                        break :blk .{ .resolve = arg_ };
                    },
                    // ii. Else,
                    //    1. Assert: type is reject.
                    .reject => {
                        // 2. Let handlerResult be ThrowCompletion(arg).
                        break :blk .{ .reject = arg_ };
                    },
                }
            } else blk: {
                // e. Else,
                // i. Let handlerResult be Completion(HostCallJobCallback(handler, undefined,
                //    « arg »)).
                if (agent_.host_hooks.hostCallJobCallback(
                    agent_,
                    handler.?,
                    .undefined,
                    &.{arg_},
                )) |value|
                    break :blk .{ .resolve = value }
                else |err| switch (err) {
                    error.OutOfMemory => |e| return e,
                    error.ExceptionThrown => {
                        const exception = agent_.clearException();
                        break :blk .{ .reject = exception.value };
                    },
                }
            };

            // f. If promiseCapability is undefined, then
            const promise_capability = maybe_promise_capability orelse {
                // i. Assert: handlerResult is not an abrupt completion.
                std.debug.assert(handler_result == .resolve);

                // ii. Return empty.
                return .undefined;
            };

            // g. Assert: promiseCapability is a PromiseCapability Record.

            switch (handler_result) {
                // h. If handlerResult is an abrupt completion, then
                .reject => |value| {
                    // i. Return ? Call(promiseCapability.[[Reject]], undefined,
                    //    « handlerResult.[[Value]] »).
                    return promise_capability.reject.call(agent_, .undefined, &.{value});
                },
                .resolve => |value| {
                    // i. Return ? Call(promiseCapability.[[Resolve]], undefined,
                    //    « handlerResult.[[Value]] »).
                    return promise_capability.resolve.call(agent_, .undefined, &.{value});
                },
            }
        }
    }.func;
    const job: Job = .{ .func = func, .captures = captures };

    // 2. Let handlerRealm be null.
    var handler_realm: ?*Realm = null;

    // 3. If reaction.[[Handler]] is not empty, then
    if (reaction.handler) |handler| {
        // a. Let getHandlerRealmResult be Completion(GetFunctionRealm(
        //    reaction.[[Handler]].[[Callback]])).
        const get_handler_realm_result = handler.callback.getFunctionRealm(agent);

        // b. If getHandlerRealmResult is a normal completion, set handlerRealm to
        //    getHandlerRealmResult.[[Value]].
        if (get_handler_realm_result) |realm| {
            handler_realm = realm;
        }
        // c. Else, set handlerRealm to the current Realm Record.
        else |_| {
            handler_realm = agent.currentRealm();
        }

        // d. NOTE: handlerRealm is never null unless the handler is undefined. When the handler is
        //    a revoked Proxy and no ECMAScript code runs, handlerRealm is used to create error
        //    objects.
    }

    // 4. Return the Record { [[Job]]: job, [[Realm]]: handlerRealm }.
    return .{ .job = job, .realm = handler_realm };
}

/// 27.5.2.2 NewPromiseResolveThenableJob ( promiseToResolve, thenable, then )
/// https://tc39.es/ecma262/#sec-newpromiseresolvethenablejob
pub fn newPromiseResolveThenableJob(
    agent: *Agent,
    promise_to_resolve: *Promise,
    thenable: *Object,
    then: Job.Callback,
) std.mem.Allocator.Error!struct { job: Job, realm: *Realm } {
    const Captures = struct {
        agent: *Agent,
        promise_to_resolve: *Promise,
        thenable: *Object,
        then: Job.Callback,
    };
    const captures = try agent.gc_allocator.create(Captures);
    captures.* = .{
        .agent = agent,
        .promise_to_resolve = promise_to_resolve,
        .thenable = thenable,
        .then = then,
    };

    // 1. Let job be a new Job Abstract Closure with no parameters that captures promiseToResolve,
    //    thenable, and then and performs the following steps when called:
    const func = struct {
        fn func(captures_ptr: *anyopaque) Agent.Error!Value {
            const captures_: *Captures = @ptrCast(@alignCast(captures_ptr));
            const agent_ = captures_.agent;
            const promise_to_resolve_ = captures_.promise_to_resolve;
            const thenable_ = captures_.thenable;
            const then_ = captures_.then;

            // a. Let resolvingFuncs be CreateResolvingFunctions(promiseToResolve).
            const resolving_funcs = try createResolvingFunctions(agent_, promise_to_resolve_);

            // b. Let thenCallResult be Completion(HostCallJobCallback(then, thenable,
            //    « resolvingFuncs.[[Resolve]], resolvingFuncs.[[Reject]] »)).
            const then_call_result = agent_.host_hooks.hostCallJobCallback(
                agent_,
                then_,
                Value.from(thenable_),
                &.{
                    Value.from(&resolving_funcs.resolve.object),
                    Value.from(&resolving_funcs.reject.object),
                },
            ) catch |err| switch (err) {
                error.OutOfMemory => |e| return e,

                // c. If thenCallResult is an abrupt completion, then
                error.ExceptionThrown => {
                    const exception = agent_.clearException();

                    // i. Return ? Call(resolvingFuncs.[[Reject]], undefined,
                    //    « thenCallResult.[[Value]] »).
                    return resolving_funcs.reject.object.call(
                        agent_,
                        .undefined,
                        &.{exception.value},
                    );
                },
            };

            // d. Return ! thenCallResult.
            return then_call_result;
        }
    }.func;
    const job: Job = .{ .func = func, .captures = captures };

    // 2. Let getThenRealmResult be Completion(GetFunctionRealm(then.[[Callback]])).
    const get_handler_realm_result = then.callback.getFunctionRealm(agent);

    // 3. If getThenRealmResult is a normal completion, let thenRealm be
    //    getThenRealmResult.[[Value]].
    const then_realm = if (get_handler_realm_result) |realm| blk: {
        break :blk realm;
    } else |_| blk: {
        // 4. Else, let thenRealm be the current Realm Record.
        break :blk agent.currentRealm();
    };

    // 5. NOTE: thenRealm is never null. When then.[[Callback]] is a revoked Proxy and no code runs,
    //    thenRealm is used to create error objects.

    // 6. Return the Record { [[Job]]: job, [[Realm]]: thenRealm }.
    return .{ .job = job, .realm = then_realm };
}

/// 27.2.4.1.1 GetPromiseResolve ( promiseConstructor )
fn getPromiseResolve(agent: *Agent, promise_constructor: *Object) Agent.Error!*Object {
    // 1. Let promiseResolve be ? Get(promiseConstructor, "resolve").
    const promise_resolve = try promise_constructor.get(agent, PropertyKey.from("resolve"));

    // 2. If IsCallable(promiseResolve) is false, throw a TypeError exception.
    if (!promise_resolve.isCallable()) {
        return agent.throwException(.type_error, "{f} is not callable", .{promise_resolve});
    }

    // 3. Return promiseResolve.
    return promise_resolve.asObject();
}

const KeyedEntry = struct {
    /// [[Key]]
    key: PropertyKey,

    /// [[Value]]
    value: Value,
};

/// 27.2.1.10 CreateKeyedPromiseCombinatorResultObject ( entries )
/// https://tc39.es/proposal-await-dictionary/#sec-createkeyedpromisecombinatorresultobject
fn createKeyedPromiseCombinatorResultObject(
    agent: *Agent,
    entries: []const KeyedEntry,
) std.mem.Allocator.Error!*Object {
    // 1. Let obj be OrdinaryObjectCreate(null).
    const obj = try ordinaryObjectCreate(agent, null);

    // 2. For each Record { [[Key]], [[Value]] } entry of entries, do
    for (entries) |entry| {
        // a. Perform ! CreateDataPropertyOrThrow(obj, entry.[[Key]], entry.[[Value]]).
        try obj.createDataPropertyDirect(agent, entry.key, entry.value);
    }

    // 3. Return obj.
    return obj;
}

const RemainingElements = struct {
    value: usize,
};

/// 27.5.4.1.2 PerformPromiseAll ( iteratorRecord, ctor, resultCapability, promiseResolve )
/// https://tc39.es/ecma262/#sec-performpromiseall
fn performPromiseAll(
    agent: *Agent,
    iterator: *Iterator,
    ctor: *Object,
    result_capability: PromiseCapability,
    promise_resolve: *Object,
) Agent.Error!*Object {
    // 1. Let values be a new empty List.
    var values = try agent.gc_allocator.create(std.ArrayList(Value));
    values.* = .empty;

    // 2. NOTE: remainingElementsCount starts at 1 instead of 0 to ensure
    //    resultCapability.[[Resolve]] is only called once, even in the presence of a misbehaving
    //    "then" which calls the passed callback before the input iterator is exhausted.
    // 3. Let remainingElementsCount be the Record { [[Value]]: 1 }.
    var remaining_elements_count = try agent.gc_allocator.create(RemainingElements);
    remaining_elements_count.* = .{ .value = 1 };

    // 4. Let index be 0.
    var index: usize = 0;

    // 5. Repeat,
    while (true) {
        // a. Let next be ? IteratorStepValue(iteratorRecord).
        // b. If next is done, then
        const next = try iterator.stepValue(agent) orelse {
            // i. Set remainingElementsCount.[[Value]] to remainingElementsCount.[[Value]] - 1.
            remaining_elements_count.value -= 1;

            // ii. If remainingElementsCount.[[Value]] = 0, then
            if (remaining_elements_count.value == 0) {
                // 1. Let valuesArray be CreateArrayFromList(values).
                const values_array = try createArrayFromList(agent, values.items);

                // 2. Perform ? Call(resultCapability.[[Resolve]], undefined, « valuesArray »).
                _ = try result_capability.resolve.call(
                    agent,
                    .undefined,
                    &.{Value.from(&values_array.object)},
                );
            }

            // iii. Return resultCapability.[[Promise]].
            return result_capability.promise;
        };

        // c. Append undefined to values.
        try values.append(agent.gc_allocator, .undefined);

        // d. Let nextPromise be ? Call(promiseResolve, ctor, « next »).
        const next_promise = try promise_resolve.call(agent, Value.from(ctor), &.{next});

        const AdditionalFields = struct {
            /// [[AlreadyCalled]]
            already_called: bool,

            /// [[Index]]
            index: usize,

            // Captures
            values: *std.ArrayList(Value),
            result_capability: PromiseCapability,
            remaining_elements_count: *RemainingElements,
        };

        // e. Let fulfilledSteps be a new Abstract Closure with parameters (value) that captures
        //    values, resultCapability, and remainingElementsCount and performs the following steps
        //    when called:
        const fulfilled_steps = struct {
            fn func(agent_: *Agent, _: Value, arguments: Arguments) Agent.Error!Value {
                const value = arguments.get(0);

                // i. Let activeFunc be the active function object.
                const active_func = agent_.activeFunctionObject();

                const additional_fields = active_func.as(builtins.BuiltinFunction).fields.additionalFieldsAs(AdditionalFields);
                const values_ = additional_fields.values;
                const result_capability_ = additional_fields.result_capability;
                const remaining_elements_count_ = additional_fields.remaining_elements_count;

                // ii. If activeFunc.[[AlreadyCalled]] is true, return undefined.
                if (additional_fields.already_called) return .undefined;

                // iii. Set activeFunc.[[AlreadyCalled]] to true.
                additional_fields.already_called = true;

                // iv. Let thisIndex be activeFunc.[[Index]].
                const this_index = additional_fields.index;

                // v. Set values[thisIndex] to value.
                values_.items[this_index] = value;

                // vi. Set remainingElementsCount.[[Value]] to remainingElementsCount.[[Value]] - 1.
                remaining_elements_count_.value -= 1;

                // vii. If remainingElementsCount.[[Value]] = 0, then
                if (remaining_elements_count_.value == 0) {
                    // 1. Let valuesArray be CreateArrayFromList(values).
                    const values_array = try createArrayFromList(agent_, values_.items);

                    // 2. Return ? Call(resultCapability.[[Resolve]], undefined, « valuesArray »).
                    return result_capability_.resolve.call(
                        agent_,
                        .undefined,
                        &.{Value.from(&values_array.object)},
                    );
                }

                // viii. Return undefined.
                return .undefined;
            }
        }.func;

        // f. Let onFulfilled be CreateBuiltinFunction(fulfilledSteps, 1, "", « [[AlreadyCalled]],
        //    [[Index]] »).
        const additional_fields = try agent.gc_allocator.create(AdditionalFields);
        const on_fulfilled = try createBuiltinFunction(
            agent,
            .{ .function = fulfilled_steps },
            1,
            "",
            .{ .additional_fields = additional_fields },
        );

        additional_fields.* = .{
            // g. Set onFulfilled.[[AlreadyCalled]] to false.
            .already_called = false,

            // h. Set onFulfilled.[[Index]] to index.
            .index = index,

            // Captures
            .values = values,
            .result_capability = result_capability,
            .remaining_elements_count = remaining_elements_count,
        };

        // i. Set index to index + 1.
        index += 1;

        // j. Set remainingElementsCount.[[Value]] to remainingElementsCount.[[Value]] + 1.
        remaining_elements_count.value += 1;

        // k. Perform ? Invoke(nextPromise, "then", « onFulfilled, resultCapability.[[Reject]] »).
        _ = try next_promise.invoke(
            agent,
            PropertyKey.from("then"),
            &.{ Value.from(&on_fulfilled.object), Value.from(result_capability.reject) },
        );
    }
}

const AllKeyedVariant = enum { all, all_settled };

/// 27.2.4.1.1 PerformPromiseAllKeyed ( variant, promises, ctor, resultCapability, promiseResolve )
/// https://tc39.es/proposal-await-dictionary/#sec-performpromiseallkeyed
fn performPromiseAllKeyed(
    agent: *Agent,
    variant: AllKeyedVariant,
    promises: *Object,
    ctor: *Object,
    result_capability: PromiseCapability,
    promise_resolve: *Object,
) Agent.Error!*Object {
    // 1. Let allKeys be ? promises.[[OwnPropertyKeys]]().
    const all_keys = try promises.internalMethods().ownPropertyKeys(agent, promises);
    defer agent.gc_allocator.free(all_keys);

    // 2. Let entries be a new empty List.
    var entries = try agent.gc_allocator.create(std.ArrayList(KeyedEntry));
    entries.* = .empty;

    // 3. Let remainingElementsCount be the Record { [[Value]]: 1 }.
    var remaining_elements_count = try agent.gc_allocator.create(RemainingElements);
    remaining_elements_count.* = .{ .value = 1 };

    // 4. Let index be 0.
    var index: usize = 0;

    // 5. For each element key of allKeys, do
    for (all_keys) |key| {
        // a. Let propertyDesc be ? promises.[[GetOwnProperty]](key).
        const property_desc = try promises.internalMethods().getOwnProperty(agent, promises, key);

        // b. If propertyDesc is not undefined and propertyDesc.[[Enumerable]] is true, then
        if (property_desc != null and property_desc.?.enumerable == true) {
            // i. Let propertyValue be ? Get(promises, key).
            const property_value = try promises.get(agent, key);

            // ii. Append the Record { [[Key]]: key, [[Value]]: undefined } to entries.
            try entries.append(agent.gc_allocator, .{ .key = key, .value = .undefined });

            // iii. Let nextPromise be ? Call(promiseResolve, ctor, « propertyValue »).
            const next_promise = try promise_resolve.call(
                agent,
                Value.from(ctor),
                &.{property_value},
            );

            const AlreadyCalled = struct { value: bool };

            // iv. Let alreadyCalled be the Record { [[Value]]: false }.
            const already_called = try agent.gc_allocator.create(AlreadyCalled);
            already_called.* = .{ .value = false };

            const AdditionalFields = struct {
                /// [[AlreadyCalled]]
                already_called: *AlreadyCalled,

                /// [[Index]]
                index: usize,

                // Captures
                variant: AllKeyedVariant,
                entries: *std.ArrayList(KeyedEntry),
                result_capability: PromiseCapability,
                remaining_elements_count: *RemainingElements,
            };

            // v. Let fulfilledSteps be a new Abstract Closure with parameters (value) that captures
            //    variant, entries, resultCapability, and remainingElementsCount and performs the
            //    following steps when called:
            const fulfilled_steps = struct {
                fn func(agent_: *Agent, _: Value, arguments_: Arguments) Agent.Error!Value {
                    const realm = agent_.currentRealm();
                    const value = arguments_.get(0);

                    // 1. Let activeFunc be the active function object.
                    const active_func = agent_.activeFunctionObject();

                    const additional_fields_ = active_func.as(builtins.BuiltinFunction).fields.additionalFieldsAs(AdditionalFields);
                    const variant_ = additional_fields_.variant;
                    const entries_ = additional_fields_.entries;
                    const result_capability_ = additional_fields_.result_capability;
                    const remaining_elements_count_ = additional_fields_.remaining_elements_count;

                    // 2. If activeFunc.[[AlreadyCalled]].[[Value]] is true, return undefined.
                    if (additional_fields_.already_called.value) return .undefined;

                    // 3. Set activeFunc.[[AlreadyCalled]].[[Value]] to true.
                    additional_fields_.already_called.value = true;

                    // 4. Let thisIndex be activeFunc.[[Index]].
                    const this_index = additional_fields_.index;

                    switch (variant_) {
                        // 5. If variant is all, then
                        .all => {
                            // a. Set entries[thisIndex].[[Value]] to value.
                            entries_.items[this_index].value = value;
                        },
                        // 6. Else,
                        //     a. Assert: variant is all-settled.
                        .all_settled => {
                            // b. Let obj be OrdinaryObjectCreate(%Object.prototype%).
                            const obj = try ordinaryObjectCreate(
                                agent_,
                                try realm.intrinsic(.object_prototype),
                            );

                            // c. Perform ! CreateDataPropertyOrThrow(obj, "status", "fulfilled").
                            try obj.createDataPropertyDirect(
                                agent_,
                                PropertyKey.from("status"),
                                Value.from("fulfilled"),
                            );

                            // d. Perform ! CreateDataPropertyOrThrow(obj, "value", value).
                            try obj.createDataPropertyDirect(
                                agent_,
                                PropertyKey.from("value"),
                                value,
                            );

                            // e. Set entries[thisIndex].[[Value]] to obj.
                            entries_.items[this_index].value = Value.from(obj);
                        },
                    }

                    // 7. Set remainingElementsCount.[[Value]] to
                    //    remainingElementsCount.[[Value]] - 1.
                    remaining_elements_count_.value -= 1;

                    // 8. If remainingElementsCount.[[Value]] = 0, then
                    if (remaining_elements_count_.value == 0) {
                        // a. Let result be CreateKeyedPromiseCombinatorResultObject(entries).
                        const result = try createKeyedPromiseCombinatorResultObject(
                            agent_,
                            entries_.items,
                        );

                        // b. Return ? Call(resultCapability.[[Resolve]], undefined, « result »).
                        return result_capability_.resolve.call(
                            agent_,
                            .undefined,
                            &.{Value.from(result)},
                        );
                    }

                    // 9. Return undefined.
                    return .undefined;
                }
            }.func;

            // vi. Let onFulfilled be CreateBuiltinFunction(fulfilledSteps, 1, "",
            //     « [[AlreadyCalled]], [[Index]] »).
            const on_fulfilled_additional_fields = try agent.gc_allocator.create(AdditionalFields);
            const on_fulfilled = try createBuiltinFunction(
                agent,
                .{ .function = fulfilled_steps },
                1,
                "",
                .{ .additional_fields = on_fulfilled_additional_fields },
            );

            on_fulfilled_additional_fields.* = .{
                // vii. Set onFulfilled.[[AlreadyCalled]] to alreadyCalled.
                .already_called = already_called,

                // viii. Set onFulfilled.[[Index]] to index.
                .index = index,

                // Captures
                .variant = variant,
                .entries = entries,
                .result_capability = result_capability,
                .remaining_elements_count = remaining_elements_count,
            };

            const on_rejected = switch (variant) {
                // ix. If variant is all, then
                .all => blk: {
                    // 1. Let onRejected be resultCapability.[[Reject]].
                    break :blk result_capability.reject;
                },
                // x. Else,
                //     1. Assert: variant is all-settled.
                .all_settled => blk: {
                    // 2. Let rejectedSteps be a new Abstract Closure with parameters (error) that
                    //    captures entries, resultCapability, and remainingElementsCount and
                    //    performs the following steps when called:
                    const rejected_steps = struct {
                        fn func(agent_: *Agent, _: Value, arguments_: Arguments) Agent.Error!Value {
                            const realm = agent_.currentRealm();
                            const @"error" = arguments_.get(0);

                            // a. Let activeFunc be the active function object.
                            const active_func = agent_.activeFunctionObject();

                            const additional_fields_ = active_func.as(builtins.BuiltinFunction).fields.additionalFieldsAs(AdditionalFields);
                            const entries_ = additional_fields_.entries;
                            const result_capability_ = additional_fields_.result_capability;
                            const remaining_elements_count_ = additional_fields_.remaining_elements_count;

                            // b. If activeFunc.[[AlreadyCalled]].[[Value]] is true, return
                            //    undefined.
                            if (additional_fields_.already_called.value) return .undefined;

                            // c. Set activeFunc.[[AlreadyCalled]].[[Value]] to true.
                            additional_fields_.already_called.value = true;

                            // d. Let thisIndex be activeFunc.[[Index]].
                            const this_index = additional_fields_.index;

                            // e. Let obj be OrdinaryObjectCreate(%Object.prototype%).
                            const obj = try ordinaryObjectCreate(
                                agent_,
                                try realm.intrinsic(.object_prototype),
                            );

                            // f. Perform ! CreateDataPropertyOrThrow(obj, "status", "rejected").
                            try obj.createDataPropertyDirect(
                                agent_,
                                PropertyKey.from("status"),
                                Value.from("rejected"),
                            );

                            // g. Perform ! CreateDataPropertyOrThrow(obj, "reason", error).
                            try obj.createDataPropertyDirect(
                                agent_,
                                PropertyKey.from("reason"),
                                @"error",
                            );

                            // h. Set entries[thisIndex].[[Value]] to obj.
                            entries_.items[this_index].value = Value.from(obj);

                            // i. Set remainingElementsCount.[[Value]] to
                            //    remainingElementsCount.[[Value]] - 1.
                            remaining_elements_count_.value -= 1;

                            // j. If remainingElementsCount.[[Value]] = 0, then
                            if (remaining_elements_count_.value == 0) {
                                // i. Let result be CreateKeyedPromiseCombinatorResultObject(
                                //    entries).
                                const result = try createKeyedPromiseCombinatorResultObject(
                                    agent_,
                                    entries_.items,
                                );

                                // ii. Return ? Call(resultCapability.[[Resolve]], undefined,
                                //     « result »).
                                return result_capability_.resolve.call(
                                    agent_,
                                    .undefined,
                                    &.{Value.from(result)},
                                );
                            }

                            // k. Return undefined.
                            return .undefined;
                        }
                    }.func;

                    // 3. Let onRejected be CreateBuiltinFunction(rejectedSteps, 1, "",
                    //    « [[AlreadyCalled]], [[Index]] »).
                    const on_rejected_additional_fields = try agent.gc_allocator.create(AdditionalFields);
                    const on_rejected = try createBuiltinFunction(
                        agent,
                        .{ .function = rejected_steps },
                        1,
                        "",
                        .{ .additional_fields = on_rejected_additional_fields },
                    );

                    on_rejected_additional_fields.* = .{
                        // 4. Set onRejected.[[AlreadyCalled]] to alreadyCalled.
                        .already_called = already_called,

                        // 5. Set onRejected.[[Index]] to index.
                        .index = index,

                        // Captures
                        .variant = variant,
                        .entries = entries,
                        .result_capability = result_capability,
                        .remaining_elements_count = remaining_elements_count,
                    };

                    break :blk &on_rejected.object;
                },
            };

            // xi. Set remainingElementsCount.[[Value]] to remainingElementsCount.[[Value]] + 1.
            remaining_elements_count.value += 1;

            // xii. Perform ? Invoke(nextPromise, "then", « onFulfilled, onRejected »).
            _ = try next_promise.invoke(
                agent,
                PropertyKey.from("then"),
                &.{ Value.from(&on_fulfilled.object), Value.from(on_rejected) },
            );

            // xiii. Set index to index + 1.
            index += 1;
        }
    }

    // 6. Set remainingElementsCount.[[Value]] to remainingElementsCount.[[Value]] - 1.
    remaining_elements_count.value -= 1;

    // 7. If remainingElementsCount.[[Value]] = 0, then
    if (remaining_elements_count.value == 0) {
        // a. NOTE: This can happen even if entries is non-empty if an ill-behaved thenable
        //    synchronously invoked the callback passed to its "then" method.
        // b. Let result be CreateKeyedPromiseCombinatorResultObject(entries).
        const result = try createKeyedPromiseCombinatorResultObject(agent, entries.items);

        // c. Perform ? Call(resultCapability.[[Resolve]], undefined, « result »).
        _ = try result_capability.resolve.call(agent, .undefined, &.{Value.from(result)});
    }

    // 8. Return resultCapability.[[Promise]].
    return result_capability.promise;
}

/// 27.5.4.2.1 PerformPromiseAllSettled ( iteratorRecord, ctor, resultCapability, promiseResolve )
/// https://tc39.es/ecma262/#sec-performpromiseallsettled
fn performPromiseAllSettled(
    agent: *Agent,
    iterator: *Iterator,
    ctor: *Object,
    result_capability: PromiseCapability,
    promise_resolve: *Object,
) Agent.Error!*Object {
    // 1. Let values be a new empty List.
    var values = try agent.gc_allocator.create(std.ArrayList(Value));
    values.* = .empty;

    // 2. NOTE: remainingElementsCount starts at 1 instead of 0 to ensure
    //    resultCapability.[[Resolve]] is only called once, even in the presence of a misbehaving
    //    "then" which calls one of the passed callbacks before the input iterator is exhausted.
    // 3. Let remainingElementsCount be the Record { [[Value]]: 1 }.
    var remaining_elements_count = try agent.gc_allocator.create(RemainingElements);
    remaining_elements_count.* = .{ .value = 1 };

    // 4. Let index be 0.
    var index: usize = 0;

    // 5. Repeat,
    while (true) {
        // a. Let next be ? IteratorStepValue(iteratorRecord).
        // b. If next is done, then
        const next = try iterator.stepValue(agent) orelse {
            // i. Set remainingElementsCount.[[Value]] to remainingElementsCount.[[Value]] - 1.
            remaining_elements_count.value -= 1;

            // ii. If remainingElementsCount.[[Value]] = 0, then
            if (remaining_elements_count.value == 0) {
                // 1. Let valuesArray be CreateArrayFromList(values).
                const values_array = try createArrayFromList(agent, values.items);

                // 2. Perform ? Call(resultCapability.[[Resolve]], undefined, « valuesArray »).
                _ = try result_capability.resolve.call(
                    agent,
                    .undefined,
                    &.{Value.from(&values_array.object)},
                );
            }

            // iii. Return resultCapability.[[Promise]].
            return result_capability.promise;
        };

        // c. Append undefined to values.
        try values.append(agent.gc_allocator, .undefined);

        // d. Let nextPromise be ? Call(promiseResolve, ctor, « next »).
        const next_promise = try promise_resolve.call(agent, Value.from(ctor), &.{next});

        const AlreadyCalled = struct { value: bool };

        // e. Let alreadyCalled be the Record { [[Value]]: false }.
        const already_called = try agent.gc_allocator.create(AlreadyCalled);
        already_called.* = .{ .value = false };

        const AdditionalFields = struct {
            /// [[AlreadyCalled]]
            already_called: *AlreadyCalled,

            /// [[Index]]
            index: usize,

            // Captures
            values: *std.ArrayList(Value),
            result_capability: PromiseCapability,
            remaining_elements_count: *RemainingElements,
        };

        // f. Let fulfilledSteps be a new Abstract Closure with parameters (value) that captures
        //    values, resultCapability, and remainingElementsCount and performs the following steps
        //    when called:
        const fulfilled_steps = struct {
            fn func(agent_: *Agent, _: Value, arguments_: Arguments) Agent.Error!Value {
                const realm = agent_.currentRealm();
                const value = arguments_.get(0);

                // i. Let activeFunc be the active function object.
                const active_func = agent_.activeFunctionObject();

                const additional_fields_ = active_func.as(builtins.BuiltinFunction).fields.additionalFieldsAs(AdditionalFields);
                const values_ = additional_fields_.values;
                const result_capability_ = additional_fields_.result_capability;
                const remaining_elements_count_ = additional_fields_.remaining_elements_count;

                // ii. If activeFunc.[[AlreadyCalled]].[[Value]] is true, return undefined.
                if (additional_fields_.already_called.value) return .undefined;

                // iii. Set activeFunc.[[AlreadyCalled]].[[Value]] to true.
                additional_fields_.already_called.value = true;

                // iv. Let obj be OrdinaryObjectCreate(%Object.prototype%).
                const obj = try ordinaryObjectCreate(
                    agent_,
                    try realm.intrinsic(.object_prototype),
                );

                // v. Perform ! CreateDataPropertyOrThrow(obj, "status", "fulfilled").
                try obj.createDataPropertyDirect(
                    agent_,
                    PropertyKey.from("status"),
                    Value.from("fulfilled"),
                );

                // vi. Perform ! CreateDataPropertyOrThrow(obj, "value", value).
                try obj.createDataPropertyDirect(agent_, PropertyKey.from("value"), value);

                // vii. Let thisIndex be activeFunc.[[Index]].
                const this_index = additional_fields_.index;

                // viii. Set values[thisIndex] to obj.
                values_.items[this_index] = Value.from(obj);

                // ix. Set remainingElementsCount.[[Value]] to remainingElementsCount.[[Value]] - 1.
                remaining_elements_count_.value -= 1;

                // x. If remainingElementsCount.[[Value]] = 0, then
                if (remaining_elements_count_.value == 0) {
                    // 1. Let valuesArray be CreateArrayFromList(values).
                    const values_array = try createArrayFromList(agent_, values_.items);

                    // 2. Return ? Call(resultCapability.[[Resolve]], undefined, « valuesArray »).
                    return result_capability_.resolve.call(
                        agent_,
                        .undefined,
                        &.{Value.from(&values_array.object)},
                    );
                }

                // xi. Return undefined.
                return .undefined;
            }
        }.func;

        // g. Let onFulfilled be CreateBuiltinFunction(fulfilledSteps, 1, "", « [[AlreadyCalled]],
        //    [[Index]] »).
        const on_fulfilled_additional_fields = try agent.gc_allocator.create(AdditionalFields);
        const on_fulfilled = try createBuiltinFunction(
            agent,
            .{ .function = fulfilled_steps },
            1,
            "",
            .{ .additional_fields = on_fulfilled_additional_fields },
        );

        on_fulfilled_additional_fields.* = .{
            // h. Set onFulfilled.[[AlreadyCalled]] to alreadyCalled.
            .already_called = already_called,

            // i. Set onFulfilled.[[Index]] to index.
            .index = index,

            // Captures
            .values = values,
            .result_capability = result_capability,
            .remaining_elements_count = remaining_elements_count,
        };

        // j. Let rejectedSteps be a new Abstract Closure with parameters (error) that captures
        //    values, resultCapability, and remainingElementsCount and performs the following steps
        //    when called:
        const rejected_steps = struct {
            fn func(agent_: *Agent, _: Value, arguments_: Arguments) Agent.Error!Value {
                const realm = agent_.currentRealm();
                const @"error" = arguments_.get(0);

                // i. Let activeFunc be the active function object.
                const active_func = agent_.activeFunctionObject();

                const additional_fields_ = active_func.as(builtins.BuiltinFunction).fields.additionalFieldsAs(AdditionalFields);
                const values_ = additional_fields_.values;
                const result_capability_ = additional_fields_.result_capability;
                const remaining_elements_count_ = additional_fields_.remaining_elements_count;

                // ii. If activeFunc.[[AlreadyCalled]].[[Value]] is true, return undefined.
                if (additional_fields_.already_called.value) return .undefined;

                // iii. Set activeFunc.[[AlreadyCalled]].[[Value]] to true.
                additional_fields_.already_called.value = true;

                // iv. Let obj be OrdinaryObjectCreate(%Object.prototype%).
                const obj = try ordinaryObjectCreate(
                    agent_,
                    try realm.intrinsic(.object_prototype),
                );

                // v. Perform ! CreateDataPropertyOrThrow(obj, "status", "rejected").
                try obj.createDataPropertyDirect(
                    agent_,
                    PropertyKey.from("status"),
                    Value.from("rejected"),
                );

                // vi. Perform ! CreateDataPropertyOrThrow(obj, "reason", error).
                try obj.createDataPropertyDirect(agent_, PropertyKey.from("reason"), @"error");

                // vii. Let thisIndex be activeFunc.[[Index]].
                const this_index = additional_fields_.index;

                // viii. Set values[thisIndex] to obj.
                values_.items[this_index] = Value.from(obj);

                // ix. Set remainingElementsCount.[[Value]] to remainingElementsCount.[[Value]] - 1.
                remaining_elements_count_.value -= 1;

                // x. If remainingElementsCount.[[Value]] = 0, then
                if (remaining_elements_count_.value == 0) {
                    // 1. Let valuesArray be CreateArrayFromList(values).
                    const values_array = try createArrayFromList(agent_, values_.items);

                    // 2. Return ? Call(resultCapability.[[Resolve]], undefined, « valuesArray »).
                    return result_capability_.resolve.call(
                        agent_,
                        .undefined,
                        &.{Value.from(&values_array.object)},
                    );
                }

                // xi. Return undefined.
                return .undefined;
            }
        }.func;

        // k. Let onRejected be CreateBuiltinFunction(rejectedSteps, 1, "", « [[AlreadyCalled]],
        //    [[Index]] »).
        const on_rejected_additional_fields = try agent.gc_allocator.create(AdditionalFields);
        const on_rejected = try createBuiltinFunction(
            agent,
            .{ .function = rejected_steps },
            1,
            "",
            .{ .additional_fields = on_rejected_additional_fields },
        );

        on_rejected_additional_fields.* = .{
            // l. Set onRejected.[[AlreadyCalled]] to alreadyCalled.
            .already_called = already_called,

            // m. Set onRejected.[[Index]] to index.
            .index = index,

            // Captures
            .values = values,
            .result_capability = result_capability,
            .remaining_elements_count = remaining_elements_count,
        };

        // n. Set index to index + 1.
        index += 1;

        // o. Set remainingElementsCount.[[Value]] to remainingElementsCount.[[Value]] + 1.
        remaining_elements_count.value += 1;

        // p. Perform ? Invoke(nextPromise, "then", « onFulfilled, onRejected »).
        _ = try next_promise.invoke(
            agent,
            PropertyKey.from("then"),
            &.{ Value.from(&on_fulfilled.object), Value.from(&on_rejected.object) },
        );
    }
}

/// 27.5.4.3.1 PerformPromiseAny ( iteratorRecord, ctor, resultCapability, promiseResolve )
/// https://tc39.es/ecma262/#sec-performpromiseany
fn performPromiseAny(
    agent: *Agent,
    iterator: *Iterator,
    ctor: *Object,
    result_capability: PromiseCapability,
    promise_resolve: *Object,
) Agent.Error!*Object {
    // 1. Let errors be a new empty List.
    var errors = try agent.gc_allocator.create(std.ArrayList(Value));
    errors.* = .empty;

    // 2. NOTE: remainingElementsCount starts at 1 instead of 0 to ensure
    //    resultCapability.[[Reject]] is only called once, even in the presence of a misbehaving
    //    "then" which calls the passed callback before the input iterator is exhausted.
    // 3. Let remainingElementsCount be the Record { [[Value]]: 1 }.
    var remaining_elements_count = try agent.gc_allocator.create(RemainingElements);
    remaining_elements_count.* = .{ .value = 1 };

    // 4. Let index be 0.
    var index: usize = 0;

    // 5. Repeat,
    while (true) {
        // a. Let next be ? IteratorStepValue(iteratorRecord).
        // b. If next is done, then
        const next = try iterator.stepValue(agent) orelse {
            // i. Set remainingElementsCount.[[Value]] to remainingElementsCount.[[Value]] - 1.
            remaining_elements_count.value -= 1;

            // ii. If remainingElementsCount.[[Value]] = 0, then
            if (remaining_elements_count.value == 0) {
                // 1. Let aggregateError be a newly created AggregateError object.
                const aggregate_error = try agent.createErrorObject(
                    .aggregate_error,
                    "All promises were rejected",
                    .{},
                );

                // 2. Perform ! DefinePropertyOrThrow(aggregateError, "errors", PropertyDescriptor {
                //    [[Configurable]]: true, [[Enumerable]]: false, [[Writable]]: true,
                //    [[Value]]: CreateArrayFromList(errors) }).
                const errors_array = try createArrayFromList(agent, errors.items);
                try aggregate_error.object.definePropertyDirect(agent, PropertyKey.from("errors"), .{
                    .value_or_accessor = .{
                        .value = Value.from(&errors_array.object),
                    },
                    .attributes = .builtin_default,
                });

                // 3. Perform ? Call(resultCapability.[[Reject]], undefined, « aggregateError »).
                _ = try result_capability.reject.call(
                    agent,
                    .undefined,
                    &.{Value.from(&aggregate_error.object)},
                );
            }

            // iii. Return resultCapability.[[Promise]].
            return result_capability.promise;
        };

        // c. Append undefined to errors.
        try errors.append(agent.gc_allocator, .undefined);

        // d. Let nextPromise be ? Call(promiseResolve, ctor, « next »).
        const next_promise = try promise_resolve.call(agent, Value.from(ctor), &.{next});

        const AdditionalFields = struct {
            /// [[AlreadyCalled]]
            already_called: bool,

            /// [[Index]]
            index: usize,

            // Captures
            errors: *std.ArrayList(Value),
            result_capability: PromiseCapability,
            remaining_elements_count: *RemainingElements,
        };

        // e. Let rejectedSteps be a new Abstract Closure with parameters (error) that captures
        //    errors, resultCapability, and remainingElementsCount and performs the following steps
        //    when called:
        const rejected_steps = struct {
            fn func(agent_: *Agent, _: Value, arguments_: Arguments) Agent.Error!Value {
                const @"error" = arguments_.get(0);

                // i. Let activeFunc be the active function object.
                const active_func = agent_.activeFunctionObject();

                const additional_fields_ = active_func.as(builtins.BuiltinFunction).fields.additionalFieldsAs(AdditionalFields);
                const errors_ = additional_fields_.errors;
                const promise_capability = additional_fields_.result_capability;
                const remaining_elements_count_ = additional_fields_.remaining_elements_count;

                // ii. If activeFunc.[[AlreadyCalled]] is true, return undefined.
                if (additional_fields_.already_called) return .undefined;

                // iii. Set activeFunc.[[AlreadyCalled]] to true.
                additional_fields_.already_called = true;

                // iv. Let thisIndex be activeFunc.[[Index]].
                const this_index = additional_fields_.index;

                // v. Set errors[thisIndex] to error.
                errors_.items[this_index] = @"error";

                // vi. Set remainingElementsCount.[[Value]] to remainingElementsCount.[[Value]] - 1.
                remaining_elements_count_.value -= 1;

                // vii. If remainingElementsCount.[[Value]] = 0, then
                if (remaining_elements_count_.value == 0) {
                    // 1. Let aggregateError be a newly created AggregateError object.
                    const aggregate_error = try agent_.createErrorObject(
                        .aggregate_error,
                        "All promises were rejected",
                        .{},
                    );

                    // 2. Perform ! DefinePropertyOrThrow(aggregateError, "errors",
                    //    PropertyDescriptor { [[Configurable]]: true, [[Enumerable]]: false,
                    //    [[Writable]]: true, [[Value]]: CreateArrayFromList(errors) }).
                    const errors_list = try createArrayFromList(agent_, errors_.items);
                    try aggregate_error.object.definePropertyDirect(agent_, PropertyKey.from("errors"), .{
                        .value_or_accessor = .{
                            .value = Value.from(&errors_list.object),
                        },
                        .attributes = .builtin_default,
                    });

                    // 3. Return ? Call(resultCapability.[[Reject]], undefined, « aggregateError »).
                    return promise_capability.reject.call(
                        agent_,
                        .undefined,
                        &.{Value.from(&aggregate_error.object)},
                    );
                }

                // viii. Return undefined.
                return .undefined;
            }
        }.func;

        // f. Let onRejected be CreateBuiltinFunction(rejectedSteps, 1, "", « [[AlreadyCalled]],
        //    [[Index]] »).
        const additional_fields = try agent.gc_allocator.create(AdditionalFields);
        const on_rejected = try createBuiltinFunction(
            agent,
            .{ .function = rejected_steps },
            1,
            "",
            .{ .additional_fields = additional_fields },
        );

        additional_fields.* = .{
            // g. Set onRejected.[[AlreadyCalled]] to false.
            .already_called = false,

            // h. Set onRejected.[[Index]] to index.
            .index = index,

            // Captures
            .errors = errors,
            .result_capability = result_capability,
            .remaining_elements_count = remaining_elements_count,
        };

        // i. Set index to index + 1.
        index += 1;

        // j. Set remainingElementsCount.[[Value]] to remainingElementsCount.[[Value]] + 1.
        remaining_elements_count.value += 1;

        // k. Perform ? Invoke(nextPromise, "then", « resultCapability.[[Resolve]], onRejected »).
        _ = try next_promise.invoke(
            agent,
            PropertyKey.from("then"),
            &.{ Value.from(result_capability.resolve), Value.from(&on_rejected.object) },
        );
    }
}

/// 27.5.4.5.1 PerformPromiseRace ( iteratorRecord, ctor, resultCapability, promiseResolve )
/// https://tc39.es/ecma262/#sec-performpromiserace
fn performPromiseRace(
    agent: *Agent,
    iterator: *Iterator,
    ctor: *Object,
    result_capability: PromiseCapability,
    promise_resolve: *Object,
) Agent.Error!*Object {
    // 1. Repeat,
    while (true) {
        // a. Let next be ? IteratorStepValue(iteratorRecord).
        // b. If next is done, then
        const next = try iterator.stepValue(agent) orelse {
            // i. Return resultCapability.[[Promise]].
            return result_capability.promise;
        };

        // c. Let nextPromise be ? Call(promiseResolve, ctor, « next »).
        const next_promise = try promise_resolve.call(agent, Value.from(ctor), &.{next});

        // d. Perform ? Invoke(nextPromise, "then", « resultCapability.[[Resolve]],
        //    resultCapability.[[Reject]] »).
        _ = try next_promise.invoke(
            agent,
            PropertyKey.from("then"),
            &.{ Value.from(result_capability.resolve), Value.from(result_capability.reject) },
        );
    }
}

/// 27.5.5.4.1 PerformPromiseThen ( promise, onFulfilled, onRejected [ , resultCapability ] )
/// https://tc39.es/ecma262/#sec-performpromisethen
pub fn performPromiseThen(
    agent: *Agent,
    promise: *Promise,
    on_fulfilled: Value,
    on_rejected: Value,
    result_capability: ?PromiseCapability,
) std.mem.Allocator.Error!?*Object {
    // 1. Assert: IsPromise(promise) is true.
    // 2. If resultCapability is not present, then
    //     a. Set resultCapability to undefined.
    // NOTE: These are enforced through the parameter types.

    // 3. If IsCallable(onFulfilled) is false, then
    const on_fulfilled_job_callback = if (!on_fulfilled.isCallable()) blk: {
        // a. Let onFulfilledJobCallback be empty.
        break :blk null;
    } else blk: {
        // 4. Else,
        // a. Let onFulfilledJobCallback be HostMakeJobCallback(onFulfilled).
        break :blk agent.host_hooks.hostMakeJobCallback(on_fulfilled.asObject());
    };

    // 5. If IsCallable(onRejected) is false, then
    const on_rejected_job_callback = if (!on_rejected.isCallable()) blk: {
        // a. Let onRejectedJobCallback be empty.
        break :blk null;
    } else blk: {
        // 6. Else,
        // a. Let onRejectedJobCallback be HostMakeJobCallback(onRejected).
        break :blk agent.host_hooks.hostMakeJobCallback(on_rejected.asObject());
    };

    // 7. Let fulfillReaction be the PromiseReaction Record { [[Capability]]: resultCapability,
    //    [[Type]]: fulfill, [[Handler]]: onFulfilledJobCallback }.
    const fulfill_reaction: PromiseReaction = .{
        .capability = result_capability,
        .type = .fulfill,
        .handler = on_fulfilled_job_callback,
    };

    // 8. Let rejectReaction be the PromiseReaction Record { [[Capability]]: resultCapability,
    //    [[Type]]: reject, [[Handler]]: onRejectedJobCallback }.
    const reject_reaction: PromiseReaction = .{
        .capability = result_capability,
        .type = .reject,
        .handler = on_rejected_job_callback,
    };

    switch (promise.fields.promise_state) {
        // 9. If promise.[[PromiseState]] is pending, then
        .pending => {
            // a. Append fulfillReaction to promise.[[PromiseFulfillReactions]].
            try promise.fields.promise_fulfill_reactions.append(
                agent.gc_allocator,
                fulfill_reaction,
            );

            // b. Append rejectReaction to promise.[[PromiseRejectReactions]].
            try promise.fields.promise_reject_reactions.append(
                agent.gc_allocator,
                reject_reaction,
            );
        },

        // 10. Else if promise.[[PromiseState]] is fulfilled, then
        .fulfilled => {
            // a. Let value be promise.[[PromiseResult]].
            const value = promise.fields.promise_result;

            // b. Let fulfillJob be NewPromiseReactionJob(fulfillReaction, value).
            const fulfill_job = try newPromiseReactionJob(agent, fulfill_reaction, value);

            // c. Perform HostEnqueuePromiseJob(fulfillJob.[[Job]], fulfillJob.[[Realm]]).
            try agent.host_hooks.hostEnqueuePromiseJob(agent, fulfill_job.job, fulfill_job.realm);
        },

        // 11. Else,
        //     a. Assert: promise.[[PromiseState]] is rejected.
        .rejected => {
            // b. Let reason be promise.[[PromiseResult]].
            const reason = promise.fields.promise_result;

            // c. If promise.[[PromiseIsHandled]] is false, perform HostPromiseRejectionTracker(
            //    promise, "handle").
            if (!promise.fields.promise_is_handled) {
                agent.host_hooks.hostPromiseRejectionTracker(agent, promise, .handle);
            }

            // d. Let rejectJob be NewPromiseReactionJob(rejectReaction, reason).
            const reject_job = try newPromiseReactionJob(agent, reject_reaction, reason);

            // e. Perform HostEnqueuePromiseJob(rejectJob.[[Job]], rejectJob.[[Realm]]).
            try agent.host_hooks.hostEnqueuePromiseJob(agent, reject_job.job, reject_job.realm);
        },
    }

    // 12. Set promise.[[PromiseIsHandled]] to true.
    promise.fields.promise_is_handled = true;

    // 13. If resultCapability is undefined, return undefined.
    // 14. Return resultCapability.[[Promise]].
    return (result_capability orelse return null).promise;
}

/// 27.5.4 Properties of the Promise Constructor
/// https://tc39.es/ecma262/#sec-properties-of-the-promise-constructor
pub const constructor = struct {
    pub fn create(agent: *Agent, realm: *Realm) std.mem.Allocator.Error!*Object {
        const builtin_function = try createBuiltinFunction(
            agent,
            .{ .constructor = impl },
            1,
            "Promise",
            .{ .realm = realm, .proto = try realm.intrinsic(.function_prototype) },
        );
        return &builtin_function.object;
    }

    pub fn init(agent: *Agent, realm: *Realm, object: *Object) std.mem.Allocator.Error!void {
        try object.defineBuiltinFunction(agent, "all", all, 1, realm);
        try object.defineBuiltinFunction(agent, "allKeyed", allKeyed, 1, realm);
        try object.defineBuiltinFunction(agent, "allSettled", allSettled, 1, realm);
        try object.defineBuiltinFunction(agent, "allSettledKeyed", allSettledKeyed, 1, realm);
        try object.defineBuiltinFunction(agent, "any", any, 1, realm);
        try object.defineBuiltinFunction(agent, "race", race, 1, realm);
        try object.defineBuiltinFunction(agent, "reject", reject, 1, realm);
        try object.defineBuiltinFunction(agent, "resolve", resolve, 1, realm);
        try object.defineBuiltinFunction(agent, "try", @"try", 1, realm);
        try object.defineBuiltinFunction(agent, "withResolvers", withResolvers, 0, realm);
        try object.defineBuiltinAccessor(agent, "Symbol.species", @"Symbol.species", null, realm);

        // 27.5.4.4 Promise.prototype
        // https://tc39.es/ecma262/#sec-promise.prototype
        try object.defineBuiltinPropertyWithAttributes(
            agent,
            "prototype",
            Value.from(try realm.intrinsic(.promise_prototype)),
            .none,
        );
    }

    /// 27.5.3.1 Promise ( executor )
    /// https://tc39.es/ecma262/#sec-promise-executor
    fn impl(agent: *Agent, arguments: Arguments, new_target: ?*Object) Agent.Error!Value {
        const executor_value = arguments.get(0);

        // 1. If NewTarget is undefined, throw a TypeError exception.
        if (new_target == null) {
            return agent.throwException(
                .type_error,
                "Promise must be constructed with 'new'",
                .{},
            );
        }

        // 2. If IsCallable(executor) is false, throw a TypeError exception.
        if (!executor_value.isCallable()) {
            return agent.throwException(.type_error, "{f} is not callable", .{executor_value});
        }
        const executor = executor_value.asObject();

        // 3. Let promise be ? OrdinaryCreateFromConstructor(NewTarget, "%Promise.prototype%",
        //    « [[PromiseState]], [[PromiseResult]], [[PromiseFulfillReactions]],
        //    [[PromiseRejectReactions]], [[PromiseIsHandled]] »).
        const promise = try ordinaryCreateFromConstructor(
            Promise,
            agent,
            new_target.?,
            .promise_prototype,
            .{
                // 4. Set promise.[[PromiseState]] to pending.
                .promise_state = .pending,

                // 5. Set promise.[[PromiseResult]] to empty.
                .promise_result = undefined,

                // 6. Set promise.[[PromiseFulfillReactions]] to a new empty List.
                .promise_fulfill_reactions = .empty,

                // 7. Set promise.[[PromiseRejectReactions]] to a new empty List.
                .promise_reject_reactions = .empty,

                // 8. Set promise.[[PromiseIsHandled]] to false.
                .promise_is_handled = false,
            },
        );

        // 9. Let resolvingFuncs be CreateResolvingFunctions(promise).
        const resolving_funcs = try createResolvingFunctions(agent, promise);

        // 10. Let completion be Completion(Call(executor, undefined, « resolvingFuncs.[[Resolve]],
        //     resolvingFuncs.[[Reject]] »)).
        _ = executor.call(
            agent,
            .undefined,
            &.{
                Value.from(&resolving_funcs.resolve.object),
                Value.from(&resolving_funcs.reject.object),
            },
        ) catch |err| switch (err) {
            error.OutOfMemory => |e| return e,

            // 11. If completion is an abrupt completion, then
            error.ExceptionThrown => {
                const exception = agent.clearException();

                // a. Perform ? Call(resolvingFuncs.[[Reject]], undefined,
                //    « completion.[[Value]] »).
                _ = try resolving_funcs.reject.object.call(agent, .undefined, &.{exception.value});
            },
        };

        // 12. Return promise.
        return Value.from(&promise.object);
    }

    /// 27.5.4.1 Promise.all ( iterable )
    /// https://tc39.es/ecma262/#sec-promise.all
    fn all(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const iterable = arguments.get(0);

        // 1. Let ctor be the this value.
        const ctor = this_value;

        // 2. Let promiseCapability be ? NewPromiseCapability(ctor).
        const promise_capability = try newPromiseCapability(agent, ctor);

        // 3. Let promiseResolve be Completion(GetPromiseResolve(ctor)).
        const promise_resolve = getPromiseResolve(agent, ctor.asObject()) catch |err| {
            // 4. IfAbruptRejectPromise(promiseResolve, promiseCapability).
            return Value.from(try promise_capability.rejectPromise(agent, err));
        };

        // 5. Let iteratorRecord be Completion(GetIterator(iterable, sync)).
        var iterator = getIterator(agent, iterable, .sync) catch |err| {
            // 6. IfAbruptRejectPromise(iteratorRecord, promiseCapability).
            return Value.from(try promise_capability.rejectPromise(agent, err));
        };

        // 7. Let result be Completion(PerformPromiseAll(iteratorRecord, ctor, promiseCapability,
        //    promiseResolve)).
        var result = performPromiseAll(
            agent,
            &iterator,
            ctor.asObject(),
            promise_capability,
            promise_resolve,
        );

        // 8. If result is an abrupt completion, then
        if (std.meta.isError(result)) {
            // a. If iteratorRecord.[[Done]] is false, set result to Completion(IteratorClose(
            //    iteratorRecord, result)).
            if (!iterator.done) result = iterator.close(agent, result);

            // b. IfAbruptRejectPromise(result, promiseCapability).
            _ = result catch |err| {
                return Value.from(try promise_capability.rejectPromise(agent, err));
            };
        }

        // 9. Return ! result.
        return Value.from(result catch unreachable);
    }

    /// 27.2.4.1 Promise.allKeyed ( promises )
    /// https://tc39.es/proposal-await-dictionary/#sec-promise.allkeyed
    fn allKeyed(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const promises = arguments.get(0);

        // 1. Let ctor be the this value.
        const ctor = this_value;

        // 2. Let promiseCapability be ? NewPromiseCapability(ctor).
        const promise_capability = try newPromiseCapability(agent, ctor);

        // 3. Let promiseResolve be Completion(GetPromiseResolve(ctor)).
        const promise_resolve = getPromiseResolve(agent, ctor.asObject()) catch |err| {
            // 4. IfAbruptRejectPromise(promiseResolve, promiseCapability).
            return Value.from(try promise_capability.rejectPromise(agent, err));
        };

        // 5. If promises is not an Object, then
        if (!promises.isObject()) {
            // a. Let error be a newly created TypeError object.
            const type_error = try agent.createErrorObject(
                .type_error,
                "{f} is not an Object",
                .{promises},
            );

            // b. Perform ? Call(promiseCapability.[[Reject]], undefined, « error »).
            _ = try promise_capability.reject.call(
                agent,
                .undefined,
                &.{Value.from(&type_error.object)},
            );

            // c. Return promiseCapability.[[Promise]].
            return Value.from(promise_capability.promise);
        }

        // 6. Let result be Completion(PerformPromiseAllKeyed(all, promises, ctor,
        //    promiseCapability, promiseResolve)).
        const result = performPromiseAllKeyed(
            agent,
            .all,
            promises.asObject(),
            ctor.asObject(),
            promise_capability,
            promise_resolve,
        );

        // 7. IfAbruptRejectPromise(result, promiseCapability).
        _ = result catch |err| {
            return Value.from(try promise_capability.rejectPromise(agent, err));
        };

        // 8. Return promiseCapability.[[Promise]].
        return Value.from(promise_capability.promise);
    }

    /// 27.5.4.2 Promise.allSettled ( iterable )
    /// https://tc39.es/ecma262/#sec-promise.allsettled
    fn allSettled(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const iterable = arguments.get(0);

        // 1. Let ctor be the this value.
        const ctor = this_value;

        // 2. Let promiseCapability be ? NewPromiseCapability(ctor).
        const promise_capability = try newPromiseCapability(agent, ctor);

        // 3. Let promiseResolve be Completion(GetPromiseResolve(ctor)).
        const promise_resolve = getPromiseResolve(agent, ctor.asObject()) catch |err| {
            // 4. IfAbruptRejectPromise(promiseResolve, promiseCapability).
            return Value.from(try promise_capability.rejectPromise(agent, err));
        };

        // 5. Let iteratorRecord be Completion(GetIterator(iterable, sync)).
        var iterator = getIterator(agent, iterable, .sync) catch |err| {
            // 6. IfAbruptRejectPromise(iteratorRecord, promiseCapability).
            return Value.from(try promise_capability.rejectPromise(agent, err));
        };

        // 7. Let result be Completion(PerformPromiseAllSettled(iteratorRecord, ctor,
        //    promiseCapability, promiseResolve)).
        var result = performPromiseAllSettled(
            agent,
            &iterator,
            ctor.asObject(),
            promise_capability,
            promise_resolve,
        );

        // 8. If result is an abrupt completion, then
        if (std.meta.isError(result)) {
            // a. If iteratorRecord.[[Done]] is false, set result to Completion(IteratorClose(
            //    iteratorRecord, result)).
            if (!iterator.done) result = iterator.close(agent, result);

            // b. IfAbruptRejectPromise(result, promiseCapability).
            _ = result catch |err| {
                return Value.from(try promise_capability.rejectPromise(agent, err));
            };
        }

        // 9. Return ! result.
        return Value.from(result catch unreachable);
    }

    /// 27.2.4.2 Promise.allSettledKeyed ( promises )
    /// https://tc39.es/proposal-await-dictionary/#sec-promise.allsettledkeyed
    fn allSettledKeyed(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const promises = arguments.get(0);

        // 1. Let ctor be the this value.
        const ctor = this_value;

        // 2. Let promiseCapability be ? NewPromiseCapability(ctor).
        const promise_capability = try newPromiseCapability(agent, ctor);

        // 3. Let promiseResolve be Completion(GetPromiseResolve(ctor)).
        const promise_resolve = getPromiseResolve(agent, ctor.asObject()) catch |err| {
            // 4. IfAbruptRejectPromise(promiseResolve, promiseCapability).
            return Value.from(try promise_capability.rejectPromise(agent, err));
        };

        // 5. If promises is not an Object, then
        if (!promises.isObject()) {
            // a. Let error be a newly created TypeError object.
            const type_error = try agent.createErrorObject(.type_error, "{f} is not an Object", .{promises});

            // b. Perform ? Call(promiseCapability.[[Reject]], undefined, « error »).
            _ = try promise_capability.reject.call(
                agent,
                .undefined,
                &.{Value.from(&type_error.object)},
            );

            // c. Return promiseCapability.[[Promise]].
            return Value.from(promise_capability.promise);
        }

        // 6. Let result be Completion(PerformPromiseAllKeyed(all-settled, promises, ctor,
        //    promiseCapability, promiseResolve)).
        const result = performPromiseAllKeyed(
            agent,
            .all_settled,
            promises.asObject(),
            ctor.asObject(),
            promise_capability,
            promise_resolve,
        );

        // 7. IfAbruptRejectPromise(result, promiseCapability).
        _ = result catch |err| {
            return Value.from(try promise_capability.rejectPromise(agent, err));
        };

        // 8. Return promiseCapability.[[Promise]].
        return Value.from(promise_capability.promise);
    }

    /// 27.5.4.3 Promise.any ( iterable )
    /// https://tc39.es/ecma262/#sec-promise.any
    fn any(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const iterable = arguments.get(0);

        // 1. Let ctor be the this value.
        const ctor = this_value;

        // 2. Let promiseCapability be ? NewPromiseCapability(ctor).
        const promise_capability = try newPromiseCapability(agent, ctor);

        // 3. Let promiseResolve be Completion(GetPromiseResolve(ctor)).
        const promise_resolve = getPromiseResolve(agent, ctor.asObject()) catch |err| {
            // 4. IfAbruptRejectPromise(promiseResolve, promiseCapability).
            return Value.from(try promise_capability.rejectPromise(agent, err));
        };

        // 5. Let iteratorRecord be Completion(GetIterator(iterable, sync)).
        var iterator = getIterator(agent, iterable, .sync) catch |err| {
            // 6. IfAbruptRejectPromise(iteratorRecord, promiseCapability).
            return Value.from(try promise_capability.rejectPromise(agent, err));
        };

        // 7. Let result be Completion(PerformPromiseAny(iteratorRecord, ctor, promiseCapability,
        //    promiseResolve)).
        var result = performPromiseAny(
            agent,
            &iterator,
            ctor.asObject(),
            promise_capability,
            promise_resolve,
        );

        // 8. If result is an abrupt completion, then
        if (std.meta.isError(result)) {
            // a. If iteratorRecord.[[Done]] is false, set result to Completion(IteratorClose(
            //    iteratorRecord, result)).
            if (!iterator.done) result = iterator.close(agent, result);

            // b. IfAbruptRejectPromise(result, promiseCapability).
            _ = result catch |err| {
                return Value.from(try promise_capability.rejectPromise(agent, err));
            };
        }

        // 9. Return ! result.
        return Value.from(result catch unreachable);
    }

    /// 27.5.4.5 Promise.race ( iterable )
    /// https://tc39.es/ecma262/#sec-promise.race
    fn race(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const iterable = arguments.get(0);

        // 1. Let ctor be the this value.
        const ctor = this_value;

        // 2. Let promiseCapability be ? NewPromiseCapability(ctor).
        const promise_capability = try newPromiseCapability(agent, ctor);

        // 3. Let promiseResolve be Completion(GetPromiseResolve(ctor)).
        const promise_resolve = getPromiseResolve(agent, ctor.asObject()) catch |err| {
            // 4. IfAbruptRejectPromise(promiseResolve, promiseCapability).
            return Value.from(try promise_capability.rejectPromise(agent, err));
        };

        // 5. Let iteratorRecord be Completion(GetIterator(iterable, sync)).
        var iterator = getIterator(agent, iterable, .sync) catch |err| {
            // 6. IfAbruptRejectPromise(iteratorRecord, promiseCapability).
            return Value.from(try promise_capability.rejectPromise(agent, err));
        };

        // 7. Let result be Completion(PerformPromiseRace(iteratorRecord, ctor, promiseCapability,
        //    promiseResolve)).
        var result = performPromiseRace(
            agent,
            &iterator,
            ctor.asObject(),
            promise_capability,
            promise_resolve,
        );

        // 8. If result is an abrupt completion, then
        if (std.meta.isError(result)) {
            // a. If iteratorRecord.[[Done]] is false, set result to Completion(IteratorClose(
            //    iteratorRecord, result)).
            if (!iterator.done) result = iterator.close(agent, result);

            // b. IfAbruptRejectPromise(result, promiseCapability).
            _ = result catch |err| {
                return Value.from(try promise_capability.rejectPromise(agent, err));
            };
        }

        // 9. Return ! result.
        return Value.from(result catch unreachable);
    }

    /// 27.5.4.6 Promise.reject ( reason )
    /// https://tc39.es/ecma262/#sec-promise.reject
    fn reject(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const reason = arguments.get(0);

        // 1. Let ctor be the this value.
        const ctor = this_value;

        // 2. Let promiseCapability be ? NewPromiseCapability(ctor).
        const promise_capability = try newPromiseCapability(agent, ctor);

        // 3. Perform ? Call(promiseCapability.[[Reject]], undefined, « reason »).
        _ = try promise_capability.reject.call(agent, .undefined, &.{reason});

        // 4. Return promiseCapability.[[Promise]].
        return Value.from(promise_capability.promise);
    }

    /// 27.5.4.7 Promise.resolve ( resolution )
    /// https://tc39.es/ecma262/#sec-promise.resolve
    fn resolve(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const resolution = arguments.get(0);

        // 1. Let ctor be the this value.
        const ctor = this_value;

        // 2. If ctor is not an Object, throw a TypeError exception.
        if (!ctor.isObject()) {
            return agent.throwException(.type_error, "{f} is not an Object", .{ctor});
        }

        // 3. Return ? PromiseResolve(ctor, resolution).
        return Value.from(try promiseResolve(agent, ctor.asObject(), resolution));
    }

    /// 27.5.4.8 Promise.try ( callback, ...args )
    /// https://tc39.es/ecma262/#sec-promise.try
    fn @"try"(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const callback = arguments.get(0);
        const args = if (arguments.count() <= 1) &[_]Value{} else arguments.values[1..];

        // 1. Let ctor be the this value.
        const ctor = this_value;

        // 2. If ctor is not an Object, throw a TypeError exception.
        if (!ctor.isObject()) {
            return agent.throwException(.type_error, "{f} is not an Object", .{ctor});
        }

        // 3. Let status be Completion(Call(callback, undefined, args)).
        const status = callback.call(agent, .undefined, args) catch |err| switch (err) {
            error.OutOfMemory => |e| return e,

            // 4. If status is an abrupt completion, then
            error.ExceptionThrown => {
                const exception = agent.clearException();

                // a. Let promiseCapability be ? NewPromiseCapability(ctor).
                const promise_capability = try newPromiseCapability(agent, ctor);

                // b. Perform ? Call(promiseCapability.[[Reject]], undefined, « status.[[Value]] »).
                _ = try promise_capability.reject.call(agent, .undefined, &.{exception.value});

                // c. Return promiseCapability.[[Promise]].
                return Value.from(promise_capability.promise);
            },
        };

        // 5. Else,
        // a. Return ? PromiseResolve(ctor, ! status).
        return Value.from(try promiseResolve(agent, ctor.asObject(), status));
    }

    /// 27.5.4.9 Promise.withResolvers ( )
    /// https://tc39.es/ecma262/#sec-promise.withResolvers
    fn withResolvers(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        const realm = agent.currentRealm();

        // 1. Let ctor be the this value.
        const ctor = this_value;

        // 2. Let promiseCapability be ? NewPromiseCapability(ctor).
        const promise_capability = try newPromiseCapability(agent, ctor);

        // 3. Let obj be OrdinaryObjectCreate(%Object.prototype%).
        const obj = try ordinaryObjectCreate(
            agent,
            try realm.intrinsic(.object_prototype),
        );

        // 4. Perform ! CreateDataPropertyOrThrow(obj, "promise", promiseCapability.[[Promise]]).
        try obj.createDataPropertyDirect(
            agent,
            PropertyKey.from("promise"),
            Value.from(promise_capability.promise),
        );

        // 5. Perform ! CreateDataPropertyOrThrow(obj, "resolve", promiseCapability.[[Resolve]]).
        try obj.createDataPropertyDirect(
            agent,
            PropertyKey.from("resolve"),
            Value.from(promise_capability.resolve),
        );

        // 6. Perform ! CreateDataPropertyOrThrow(obj, "reject", promiseCapability.[[Reject]]).
        try obj.createDataPropertyDirect(
            agent,
            PropertyKey.from("reject"),
            Value.from(promise_capability.reject),
        );

        // 7. Return obj.
        return Value.from(obj);
    }

    /// 27.5.4.10 get Promise [ %Symbol.species% ]
    /// https://tc39.es/ecma262/#sec-get-promise-%symbol.species%
    fn @"Symbol.species"(_: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Return the this value.
        return this_value;
    }
};

/// 27.5.5 Properties of the Promise Prototype Object
/// https://tc39.es/ecma262/#sec-properties-of-the-promise-prototype-object
pub const prototype = struct {
    pub fn create(agent: *Agent, realm: *Realm) std.mem.Allocator.Error!*Object {
        return ordinaryObjectCreate(agent, try realm.intrinsic(.object_prototype));
    }

    pub fn init(agent: *Agent, realm: *Realm, object: *Object) std.mem.Allocator.Error!void {
        try object.defineBuiltinFunction(agent, "catch", @"catch", 1, realm);
        try object.defineBuiltinFunction(agent, "finally", finally, 1, realm);
        try object.defineBuiltinFunction(agent, "then", then, 2, realm);

        // 27.5.5.2 Promise.prototype.constructor
        // https://tc39.es/ecma262/#sec-promise.prototype.constructor
        try object.defineBuiltinProperty(
            agent,
            "constructor",
            Value.from(try realm.intrinsic(.promise)),
        );

        // 27.5.5.5 Promise.prototype [ %Symbol.toStringTag% ]
        // https://tc39.es/ecma262/#sec-promise.prototype-%symbol.tostringtag%
        try object.defineBuiltinPropertyWithAttributes(
            agent,
            "Symbol.toStringTag",
            Value.from("Promise"),
            .{
                .writable = false,
                .enumerable = false,
                .configurable = true,
            },
        );
    }

    /// 27.5.5.1 Promise.prototype.catch ( onRejected )
    /// https://tc39.es/ecma262/#sec-promise.prototype.catch
    fn @"catch"(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const on_rejected = arguments.get(0);

        // 1. Let promise be the this value.
        const promise = this_value;

        // 2. Return ? Invoke(promise, "then", « undefined, onRejected »).
        return promise.invoke(agent, PropertyKey.from("then"), &.{ .undefined, on_rejected });
    }

    /// 27.5.5.3 Promise.prototype.finally ( onFinally )
    /// https://tc39.es/ecma262/#sec-promise.prototype.finally
    fn finally(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const realm = agent.currentRealm();
        const on_finally = arguments.get(0);

        // 1. Let promise be the this value.
        // 2. If promise is not an Object, throw a TypeError exception.
        if (!this_value.isObject()) {
            return agent.throwException(.type_error, "{f} is not an Object", .{this_value});
        }
        const promise = this_value.asObject();

        // 3. Let ctor be ? SpeciesConstructor(promise, %Promise%).
        const ctor = try promise.speciesConstructor(agent, try realm.intrinsic(.promise));

        // 4. Assert: IsConstructor(ctor) is true.
        std.debug.assert(Value.from(ctor).isConstructor());

        var then_finally: Value = undefined;
        var catch_finally: Value = undefined;

        // 5. If IsCallable(onFinally) is false, then
        if (!on_finally.isCallable()) {
            // a. Let thenFinally be onFinally.
            then_finally = on_finally;

            // b. Let catchFinally be onFinally.
            catch_finally = on_finally;
        } else {
            // 6. Else,
            const Captures = struct {
                on_finally: *Object,
                ctor: *Object,
            };
            const captures = try agent.gc_allocator.create(Captures);
            captures.* = .{ .on_finally = on_finally.asObject(), .ctor = ctor };

            // a. Let thenFinallyClosure be a new Abstract Closure with parameters (value) that
            //    captures onFinally and ctor and performs the following steps when called:
            const then_finally_closure = struct {
                fn func(agent_: *Agent, _: Value, arguments_: Arguments) Agent.Error!Value {
                    const function = agent_.activeFunctionObject();
                    const captures_ = function.as(builtins.BuiltinFunction).fields.additionalFieldsAs(Captures);
                    const on_finally_ = captures_.on_finally;
                    const ctor_ = captures_.ctor;
                    const value = arguments_.get(0);

                    // i. Let result be ? Call(onFinally, undefined).
                    const result = try on_finally_.call(agent_, .undefined, &.{});

                    // ii. Let p be ? PromiseResolve(ctor, result).
                    const new_promise = try promiseResolve(agent_, ctor_, result);

                    const value_capture = try agent_.gc_allocator.create(Value);
                    value_capture.* = value;

                    // iii. Let returnValue be a new Abstract Closure with no parameters that
                    //      captures value and performs the following steps when called:
                    const return_value = struct {
                        fn func(agent__: *Agent, _: Value, _: Arguments) Agent.Error!Value {
                            const function_ = agent__.activeFunctionObject();
                            const value_ = function_.as(builtins.BuiltinFunction).fields.additionalFieldsAs(Value).*;

                            // 1. Return NormalCompletion(value).
                            return value_;
                        }
                    }.func;

                    // iv. Let valueThunk be CreateBuiltinFunction(returnValue, 0, "", « »).
                    const value_thunk = try createBuiltinFunction(
                        agent_,
                        .{ .function = return_value },
                        0,
                        "",
                        .{ .additional_fields = value_capture },
                    );

                    // v. Return ? Invoke(p, "then", « valueThunk »).
                    return new_promise.invoke(
                        agent_,
                        PropertyKey.from("then"),
                        &.{Value.from(&value_thunk.object)},
                    );
                }
            }.func;

            // b. Let thenFinally be CreateBuiltinFunction(thenFinallyClosure, 1, "", « »).
            const then_finally_function = try createBuiltinFunction(
                agent,
                .{ .function = then_finally_closure },
                1,
                "",
                .{ .additional_fields = captures },
            );
            then_finally = Value.from(&then_finally_function.object);

            // c. Let catchFinallyClosure be a new Abstract Closure with parameters (reason) that
            //    captures onFinally and ctor and performs the following steps when called:
            const catch_finally_closure = struct {
                fn func(agent_: *Agent, _: Value, arguments_: Arguments) Agent.Error!Value {
                    const function = agent_.activeFunctionObject();
                    const captures_ = function.as(builtins.BuiltinFunction).fields.additionalFieldsAs(Captures);
                    const on_finally_ = captures_.on_finally;
                    const ctor_ = captures_.ctor;
                    const reason = arguments_.get(0);

                    // i. Let result be ? Call(onFinally, undefined).
                    const result = try on_finally_.call(agent_, .undefined, &.{});

                    // ii. Let p be ? PromiseResolve(ctor, result).
                    const new_promise = try promiseResolve(agent_, ctor_, result);

                    const reason_capture = try agent_.gc_allocator.create(Value);
                    reason_capture.* = reason;

                    // iii. Let throwReason be a new Abstract Closure with no parameters that
                    //      captures reason and performs the following steps when called:
                    const throw_reason = struct {
                        fn func(agent__: *Agent, _: Value, _: Arguments) Agent.Error!Value {
                            const function_ = agent__.activeFunctionObject();
                            const reason_ = function_.as(builtins.BuiltinFunction).fields.additionalFieldsAs(Value);

                            // 1. Throw reason.
                            agent__.exception = .{
                                .value = reason_.*,
                                .stack_trace = try agent__.captureStackTrace(.{}),
                            };
                            return error.ExceptionThrown;
                        }
                    }.func;

                    // iv. Let thrower be CreateBuiltinFunction(throwReason, 0, "", « »).
                    const thrower = try createBuiltinFunction(
                        agent_,
                        .{ .function = throw_reason },
                        0,
                        "",
                        .{ .additional_fields = reason_capture },
                    );

                    // v. Return ? Invoke(p, "then", « thrower »).
                    return new_promise.invoke(
                        agent_,
                        PropertyKey.from("then"),
                        &.{Value.from(&thrower.object)},
                    );
                }
            }.func;

            // d. Let catchFinally be CreateBuiltinFunction(catchFinallyClosure, 1, "", « »).
            const catch_finally_function = try createBuiltinFunction(
                agent,
                .{ .function = catch_finally_closure },
                1,
                "",
                .{ .additional_fields = captures },
            );
            catch_finally = Value.from(&catch_finally_function.object);
        }

        // 7. Return ? Invoke(promise, "then", « thenFinally, catchFinally »).
        return promise.invoke(agent, PropertyKey.from("then"), &.{ then_finally, catch_finally });
    }

    /// 27.5.5.4 Promise.prototype.then ( onFulfilled, onRejected )
    /// https://tc39.es/ecma262/#sec-promise.prototype.then
    fn then(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const realm = agent.currentRealm();
        const on_fulfilled = arguments.get(0);
        const on_rejected = arguments.get(1);

        // 1. Let promise be the this value.
        const promise = this_value;

        // 2. If IsPromise(promise) is false, throw a TypeError exception.
        if (!promise.isPromise()) {
            return agent.throwException(.type_error, "{f} is not a Promise", .{promise});
        }

        // 3. Let ctor be ? SpeciesConstructor(promise, %Promise%).
        const ctor = try promise.asObject().speciesConstructor(
            agent,
            try realm.intrinsic(.promise),
        );

        // 4. Let resultCapability be ? NewPromiseCapability(ctor).
        const result_capability = try newPromiseCapability(agent, Value.from(ctor));

        // 5. Return PerformPromiseThen(promise, onFulfilled, onRejected, resultCapability).
        return Value.from(
            try performPromiseThen(
                agent,
                promise.asObject().as(Promise),
                on_fulfilled,
                on_rejected,
                result_capability,
            ) orelse return .undefined,
        );
    }
};

/// 27.5.6 Properties of Promise Instances
/// https://tc39.es/ecma262/#sec-properties-of-promise-instances
pub const Promise = MakeObject(.{
    .Fields = struct {
        /// [[PromiseState]]
        promise_state: enum {
            pending,
            fulfilled,
            rejected,
        },

        /// [[PromiseResult]]
        promise_result: Value,

        /// [[PromiseFulfillReactions]]
        promise_fulfill_reactions: std.ArrayList(PromiseReaction),

        /// [[PromiseRejectReactions]]
        promise_reject_reactions: std.ArrayList(PromiseReaction),

        /// [[PromiseIsHandled]]
        promise_is_handled: bool,
    },
    .tag = .promise,
    .display_name = "Promise",
});
