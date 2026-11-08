//! 27.9 AsyncGenerator Objects
//! https://tc39.es/ecma262/#sec-asyncgenerator-objects

const std = @import("std");

const builtins = @import("../builtins.zig");
const execution = @import("../execution.zig");
const interpreter = @import("../interpreter.zig");
const types = @import("../types.zig");
const utils = @import("../utils.zig");

const Agent = execution.Agent;
const Arguments = types.Arguments;
const Completion = builtins.generator.Completion;
const ExecutionContext = execution.ExecutionContext;
const MakeObject = types.MakeObject;
const Object = types.Object;
const PromiseCapability = builtins.promise.PromiseCapability;
const Realm = execution.Realm;
const Value = types.Value;
const await = builtins.await;
const createBuiltinFunction = builtins.createBuiltinFunction;
const createIteratorResultObject = types.createIteratorResultObject;
const newPromiseCapability = builtins.newPromiseCapability;
const noexcept = utils.noexcept;
const ordinaryObjectCreate = builtins.ordinaryObjectCreate;
const performPromiseThen = builtins.performPromiseThen;
const promiseResolve = builtins.promiseResolve;

/// 27.9.1 The %AsyncGeneratorPrototype% Object
/// https://tc39.es/ecma262/#sec-properties-of-asyncgenerator-prototype
pub const prototype = struct {
    pub fn create(agent: *Agent, realm: *Realm) std.mem.Allocator.Error!*Object {
        return ordinaryObjectCreate(agent, try realm.intrinsic(.async_iterator_prototype));
    }

    pub fn init(agent: *Agent, realm: *Realm, object: *Object) std.mem.Allocator.Error!void {
        try object.defineBuiltinFunction(agent, "next", next, 1, realm);
        try object.defineBuiltinFunction(agent, "return", @"return", 1, realm);
        try object.defineBuiltinFunction(agent, "throw", throw, 1, realm);

        // 27.9.1.1 %AsyncGeneratorPrototype%.constructor
        // https://tc39.es/ecma262/#sec-asyncgenerator-prototype-constructor
        try object.defineBuiltinPropertyWithAttributes(
            agent,
            "constructor",
            Value.from(try realm.intrinsic(.async_generator_function_prototype)),
            .{
                .writable = false,
                .enumerable = false,
                .configurable = true,
            },
        );

        // 27.9.1.5 %AsyncGeneratorPrototype% [ %Symbol.toStringTag% ]
        // https://tc39.es/ecma262/#sec-asyncgenerator-prototype-%symbol.tostringtag%
        try object.defineBuiltinPropertyWithAttributes(
            agent,
            "Symbol.toStringTag",
            Value.from("AsyncGenerator"),
            .{
                .writable = false,
                .enumerable = false,
                .configurable = true,
            },
        );
    }

    /// 27.9.1.2 %AsyncGeneratorPrototype%.next ( value )
    /// https://tc39.es/ecma262/#sec-asyncgenerator-prototype-next
    fn next(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const realm = agent.currentRealm();
        const value = arguments.get(0);

        // 1. Let gen be the this value.
        const gen_value = this_value;

        // 2. Let promiseCapability be ! NewPromiseCapability(%Promise%).
        const promise_capability = newPromiseCapability(
            agent,
            Value.from(try realm.intrinsic(.promise)),
        ) catch |err| try noexcept(err);

        // 3. Let result be Completion(AsyncGeneratorValidate(gen, empty)).
        const gen = asyncGeneratorValidate(agent, gen_value) catch |err| {
            // 4. IfAbruptRejectPromise(result, promiseCapability).
            return Value.from(try promise_capability.rejectPromise(agent, err));
        };

        // 5. Let state be gen.[[AsyncGeneratorState]].
        const state = gen.fields.async_generator_state;

        // 6. If state is completed, then
        if (state == .completed) {
            // a. Let iteratorResult be CreateIteratorResultObject(undefined, true).
            const iterator_result = try createIteratorResultObject(agent, .undefined, true);

            // b. Perform ! Call(promiseCapability.[[Resolve]], undefined, « iteratorResult »).
            _ = promise_capability.resolve.call(
                agent,
                .undefined,
                &.{Value.from(iterator_result)},
            ) catch |err| try noexcept(err);

            // c. Return promiseCapability.[[Promise]].
            return Value.from(promise_capability.promise);
        }

        // 7. Let completion be NormalCompletion(value).
        const completion: Completion = .{ .normal = value };

        // 8. Perform AsyncGeneratorEnqueue(gen, completion, promiseCapability).
        try asyncGeneratorEnqueue(agent, gen, completion, promise_capability);

        // 9. If state is either suspended-start or suspended-yield, then
        if (state == .suspended_start or state == .suspended_yield) {
            // a. Perform AsyncGeneratorResume(gen, completion).
            try asyncGeneratorResume(agent, gen, completion);
        } else {
            // 10. Else,
            // a. Assert: state is either executing or draining-queue.
            std.debug.assert(state == .executing or state == .draining_queue);
        }

        // 11. Return promiseCapability.[[Promise]].
        return Value.from(promise_capability.promise);
    }

    /// 27.9.1.3 %AsyncGeneratorPrototype%.return ( value )
    /// https://tc39.es/ecma262/#sec-asyncgenerator-prototype-return
    fn @"return"(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const realm = agent.currentRealm();
        const value = arguments.get(0);

        // 1. Let gen be the this value.
        const gen_value = this_value;

        // 2. Let promiseCapability be ! NewPromiseCapability(%Promise%).
        const promise_capability = newPromiseCapability(
            agent,
            Value.from(try realm.intrinsic(.promise)),
        ) catch |err| try noexcept(err);

        // 3. Let result be Completion(AsyncGeneratorValidate(gen, empty)).
        const gen = asyncGeneratorValidate(agent, gen_value) catch |err| {
            // 4. IfAbruptRejectPromise(result, promiseCapability).
            return Value.from(try promise_capability.rejectPromise(agent, err));
        };

        // 5. Let completion be ReturnCompletion(value).
        const completion: Completion = .{ .@"return" = value };

        // 6. Perform AsyncGeneratorEnqueue(gen, completion, promiseCapability).
        try asyncGeneratorEnqueue(agent, gen, completion, promise_capability);

        // 7. Let state be gen.[[AsyncGeneratorState]].
        const state = gen.fields.async_generator_state;

        // 8. If state is either suspended-start or completed, then
        if (state == .suspended_start or state == .completed) {
            // a. Set gen.[[AsyncGeneratorState]] to draining-queue.
            gen.fields.async_generator_state = .draining_queue;

            // b. Perform AsyncGeneratorAwaitReturn(gen).
            try asyncGeneratorAwaitReturn(agent, gen);
        }
        // 9. Else if state is suspended-yield, then
        else if (state == .suspended_yield) {
            // a. Perform AsyncGeneratorResume(gen, completion).
            try asyncGeneratorResume(agent, gen, completion);
        } else {
            // 10. Else,
            // a. Assert: state is either executing or draining-queue.
            std.debug.assert(state == .executing or state == .draining_queue);
        }

        // 11. Return promiseCapability.[[Promise]].
        return Value.from(promise_capability.promise);
    }

    /// 27.9.1.4 %AsyncGeneratorPrototype%.throw ( exception )
    /// https://tc39.es/ecma262/#sec-asyncgenerator-prototype-throw
    fn throw(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const realm = agent.currentRealm();
        const exception = arguments.get(0);

        // 1. Let gen be the this value.
        const gen_value = this_value;

        // 2. Let promiseCapability be ! NewPromiseCapability(%Promise%).
        const promise_capability = newPromiseCapability(
            agent,
            Value.from(try realm.intrinsic(.promise)),
        ) catch |err| try noexcept(err);

        // 3. Let result be Completion(AsyncGeneratorValidate(gen, empty)).
        const gen = asyncGeneratorValidate(agent, gen_value) catch |err| {
            // 4. IfAbruptRejectPromise(result, promiseCapability).
            return Value.from(try promise_capability.rejectPromise(agent, err));
        };

        // 5. Let state be gen.[[AsyncGeneratorState]].
        var state = gen.fields.async_generator_state;

        // 6. If state is suspended-start, then
        if (state == .suspended_start) {
            // a. Set gen.[[AsyncGeneratorState]] to completed.
            gen.fields.async_generator_state = .completed;

            // b. Set state to completed.
            state = .completed;
        }

        // 7. If state is completed, then
        if (state == .completed) {
            // a. Perform ! Call(promiseCapability.[[Reject]], undefined, « exception »).
            _ = promise_capability.reject.call(
                agent,
                .undefined,
                &.{exception},
            ) catch |err| try noexcept(err);

            // b. Return promiseCapability.[[Promise]].
            return Value.from(promise_capability.promise);
        }

        // 8. Let completion be ThrowCompletion(exception).
        const completion: Completion = .{ .throw = exception };

        // 9. Perform AsyncGeneratorEnqueue(gen, completion, promiseCapability).
        try asyncGeneratorEnqueue(agent, gen, completion, promise_capability);

        // 10. If state is suspended-yield, then
        if (state == .suspended_yield) {
            // a. Perform AsyncGeneratorResume(gen, completion).
            try asyncGeneratorResume(agent, gen, completion);
        } else {
            // 11. Else,
            // a. Assert: state is either executing or draining-queue.
            std.debug.assert(state == .executing or state == .draining_queue);
        }

        // 12. Return promiseCapability.[[Promise]].
        return Value.from(promise_capability.promise);
    }
};

/// 27.9.2 Properties of AsyncGenerator Instances
/// https://tc39.es/ecma262/#sec-properties-of-asyncgenerator-intances
pub const AsyncGenerator = MakeObject(.{
    .Fields = struct {
        pub const State = enum {
            suspended_start,
            suspended_yield,
            executing,
            draining_queue,
            completed,
        };

        /// [[AsyncGeneratorState]]
        async_generator_state: State,

        /// [[AsyncGeneratorContext]]
        async_generator_context: *ExecutionContext,

        /// [[AsyncGeneratorQueue]]
        async_generator_queue: std.ArrayList(AsyncGeneratorRequest),

        // Non-standard
        evaluation_state: struct {
            closure: *const fn (*Agent, *builtins.ECMAScriptFunction, Completion) std.mem.Allocator.Error!void,
            gen_func: *builtins.ECMAScriptFunction,
            suspension_result: ?Value = null,
            suspension: ?interpreter.Vm.GeneratorSuspension = null,
        },
    },
    .tag = .async_generator,
    .display_name = "AsyncGenerator",
});

/// 27.9.3.1 AsyncGeneratorRequest Records
/// https://tc39.es/ecma262/#sec-asyncgeneratorrequest-records
pub const AsyncGeneratorRequest = struct {
    /// [[Completion]]
    completion: Completion,

    /// [[Capability]]
    capability: PromiseCapability,
};

/// 27.9.3.2 AsyncGeneratorStart ( gen, genBody )
/// https://tc39.es/ecma262/#sec-asyncgeneratorstart
pub fn asyncGeneratorStart(
    agent: *Agent,
    gen: *AsyncGenerator,
    gen_func: *builtins.ECMAScriptFunction,
    initial_suspension: interpreter.Vm.GeneratorSuspension,
) std.mem.Allocator.Error!void {
    // 1. Assert: gen.[[AsyncGeneratorState]] is suspended-start.
    std.debug.assert(gen.fields.async_generator_state == .suspended_start);

    // 2. Let genContext be the running execution context.
    // NOTE: The running execution context may be stack-allocated by the caller, so we replace it
    //       with a heap-allocated one here since async generators store it for later resumption.
    const gen_context = try agent.gc_allocator.create(ExecutionContext);
    gen_context.* = agent.runningExecutionContext().*;
    agent.execution_context_stack.lastPtr().?.* = gen_context;

    // 3. Set the Generator component of genContext to gen.
    gen_context.generator = .{ .async_generator = gen };

    // 4. Let closure be a new Abstract Closure with no parameters that captures genBody and
    //    performs the following steps when called:
    const closure = struct {
        fn func(
            agent_: *Agent,
            generator_function_: *builtins.ECMAScriptFunction,
            resume_completion: Completion,
        ) std.mem.Allocator.Error!void {
            // a. Let acGenContext be the running execution context.
            const closure_gen_context = agent_.runningExecutionContext();

            // b. Let acGen be the Generator component of acGenContext.
            const closure_gen = closure_gen_context.generator.async_generator;

            const vm = agent_.active_vm.?;
            const suspension = &closure_gen.fields.evaluation_state.suspension.?;

            // If resuming causes another yield the suspension will be overwritten, so we
            // have to capture the stack to free it regardless.
            const current_stack = suspension.stack;
            defer agent_.gc_allocator.free(current_stack);
            switch (resume_completion) {
                .normal => |value| {
                    if (suspension.yield_reg != .none) {
                        suspension.regs()[@backingInt(suspension.yield_reg)] = value;
                    }
                },
                // TODO: Integrate throw/return completions with exception handlers in the Vm
                .@"return", .throw => {
                    _ = agent_.execution_context_stack.pop().?;
                    closure_gen.fields.async_generator_state = .draining_queue;
                    closure_gen.fields.evaluation_state = undefined;

                    const completion: Completion = switch (resume_completion) {
                        .normal => unreachable,
                        .@"return" => |value| .{ .normal = value },
                        .throw => |value| .{ .throw = value },
                    };

                    try asyncGeneratorCompleteStep(agent_, closure_gen, completion, true, null);
                    try asyncGeneratorDrainQueue(agent_, closure_gen);
                    return;
                },
            }

            // c. If genBody is a Parse Node, then
            //     i. Let result be Completion(Evaluation of genBody).
            // d. Else,
            //     i. Assert: genBody is an Abstract Closure with no parameters.
            //     ii. Let result be Completion(genBody()).
            const bc = generator_function_.fields.cached_bytecode.?;
            const result = vm.@"resume"(bc, suspension.*) catch |err| {
                // f-g.
                _ = agent_.execution_context_stack.pop().?;
                closure_gen.fields.async_generator_state = .draining_queue;
                closure_gen.fields.evaluation_state = undefined;

                switch (err) {
                    error.OutOfMemory => |e| return e,
                    error.ExceptionThrown => {
                        const exception = agent_.clearException();
                        // j-k.
                        try asyncGeneratorCompleteStep(agent_, closure_gen, .{ .throw = exception.value }, true, null);
                        try asyncGeneratorDrainQueue(agent_, closure_gen);
                        return;
                    },
                }
            };
            switch (result) {
                .yield => |new_suspension| {
                    closure_gen.fields.evaluation_state.suspension = new_suspension;
                    closure_gen.fields.evaluation_state.suspension_result = null;
                    return;
                },
                .@"return" => |value| {
                    // e. Assert: If we return here, the async generator either threw an exception
                    //    or performed either an implicit or explicit return.

                    // f. Remove acGenContext from the execution context stack and restore the
                    //    execution context that is at the top of the execution context stack as the
                    //    running execution context.
                    _ = agent_.execution_context_stack.pop().?;

                    // g. Set acGen.[[AsyncGeneratorState]] to draining-queue.
                    closure_gen.fields.async_generator_state = .draining_queue;

                    closure_gen.fields.evaluation_state = undefined;

                    // h. If result is a normal completion, set result to NormalCompletion(
                    //    undefined).
                    // i. If result is a return completion, set result to NormalCompletion(
                    //    result.[[Value]]).
                    const result_value: Value = value orelse .undefined;

                    // j. Perform AsyncGeneratorCompleteStep(acGen, result, true).
                    try asyncGeneratorCompleteStep(agent_, closure_gen, .{ .normal = result_value }, true, null);

                    // k. Perform AsyncGeneratorDrainQueue(acGen).
                    try asyncGeneratorDrainQueue(agent_, closure_gen);

                    // l. Let callerContext be the running execution context.
                    // m. Resume callerContext, passing NormalCompletion(undefined).
                    // n. Assert: This step is never reached.
                    return;
                },
            }
        }
    }.func;

    // 5. Set the code evaluation state of genContext such that when evaluation is resumed for that
    //    execution context, closure will be called with no arguments.
    gen.fields.evaluation_state = .{
        .closure = closure,
        .gen_func = gen_func,
    };

    gen.fields.evaluation_state.suspension = initial_suspension;

    // 6. Set gen.[[AsyncGeneratorContext]] to genContext.
    gen.fields.async_generator_context = gen_context;

    // 7. Set gen.[[AsyncGeneratorQueue]] to a new empty List.
    gen.fields.async_generator_queue = .empty;

    // 8. Return unused.
}

/// 27.9.3.3 AsyncGeneratorValidate ( gen, genBrand )
/// https://tc39.es/ecma262/#sec-asyncgeneratorvalidate
pub fn asyncGeneratorValidate(agent: *Agent, gen_value: Value) error{ExceptionThrown}!*AsyncGenerator {
    // 1. Perform ? RequireInternalSlot(gen, [[AsyncGeneratorContext]]).
    // 2. Perform ? RequireInternalSlot(gen, [[AsyncGeneratorState]]).
    // 3. Perform ? RequireInternalSlot(gen, [[AsyncGeneratorQueue]]).
    const gen = try gen_value.requireInternalSlot(agent, AsyncGenerator);

    // 4. If gen.[[GeneratorBrand]] is not genBrand, throw a TypeError exception.
    // NOTE: All iterators using [[GeneratorBrand]] in the spec are implemented without generators
    //       so this is currently not needed.

    // 5. Return unused.
    // NOTE: Returning the object here allows for direct assignment of the object at the call site.
    return gen;
}

/// 27.9.3.4 AsyncGeneratorEnqueue ( gen, completion, promiseCapability )
/// https://tc39.es/ecma262/#sec-asyncgeneratorenqueue
pub fn asyncGeneratorEnqueue(
    agent: *Agent,
    gen: *AsyncGenerator,
    completion: Completion,
    promise_capability: PromiseCapability,
) std.mem.Allocator.Error!void {
    // 1. Let request be AsyncGeneratorRequest { [[Completion]]: completion,
    //    [[Capability]]: promiseCapability }.
    const request: AsyncGeneratorRequest = .{
        .completion = completion,
        .capability = promise_capability,
    };

    // 2. Append request to gen.[[AsyncGeneratorQueue]].
    try gen.fields.async_generator_queue.append(agent.gc_allocator, request);

    // 3. Return unused.
}

/// 27.9.3.5 AsyncGeneratorCompleteStep ( gen, completion, done [ , realm ] )
/// https://tc39.es/ecma262/#sec-asyncgeneratorcompletestep
pub fn asyncGeneratorCompleteStep(
    agent: *Agent,
    gen: *AsyncGenerator,
    completion: Completion,
    done: bool,
    realm: ?*Realm,
) std.mem.Allocator.Error!void {
    // 1. Assert: gen.[[AsyncGeneratorQueue]] is not empty.
    std.debug.assert(gen.fields.async_generator_queue.items.len != 0);

    // 2. Let next be the first element of gen.[[AsyncGeneratorQueue]].
    // 3. Remove the first element from gen.[[AsyncGeneratorQueue]].
    const next = gen.fields.async_generator_queue.orderedRemove(0);

    // 4. Let promiseCapability be next.[[Capability]].
    const promise_capability = next.capability;

    // 5. Let value be completion.[[Value]].
    switch (completion) {
        // 6. If completion is a throw completion, then
        .throw => |value| {
            // a. Perform ! Call(promiseCapability.[[Reject]], undefined, « value »).
            _ = promise_capability.reject.call(
                agent,
                .undefined,
                &.{value},
            ) catch |err| try noexcept(err);
        },
        // 7. Else,
        // a. Assert: completion is a normal completion.
        .normal => |value| {
            // b. If realm is present, then
            const iterator_result = if (realm) |new_realm| blk: {
                // i. Let oldRealm be the running execution context's Realm.
                const old_realm = agent.runningExecutionContext().realm;

                // ii. Set the running execution context's Realm to realm.
                agent.runningExecutionContext().realm = new_realm;
                defer agent.runningExecutionContext().realm = old_realm;

                // iii. Let iteratorResult be CreateIteratorResultObject(value, done).
                break :blk try createIteratorResultObject(agent, value, done);

                // iv. Set the running execution context's Realm to oldRealm.
            } else blk: {
                // c. Else,
                // i. Let iteratorResult be CreateIteratorResultObject(value, done).
                break :blk try createIteratorResultObject(agent, value, done);
            };

            // d. Perform ! Call(promiseCapability.[[Resolve]], undefined, « iteratorResult »).
            _ = promise_capability.resolve.call(
                agent,
                .undefined,
                &.{Value.from(iterator_result)},
            ) catch |err| try noexcept(err);
        },
        .@"return" => unreachable,
    }

    // 8. Return unused.
}

/// 27.9.3.6 AsyncGeneratorResume ( gen, completion )
/// https://tc39.es/ecma262/#sec-asyncgeneratorresume
pub fn asyncGeneratorResume(
    agent: *Agent,
    gen: *AsyncGenerator,
    completion: Completion,
) std.mem.Allocator.Error!void {
    // 1. Assert: gen.[[AsyncGeneratorState]] is either suspended-start or suspended-yield.
    std.debug.assert(gen.fields.async_generator_state == .suspended_start or
        gen.fields.async_generator_state == .suspended_yield);

    // 2. Let genContext be gen.[[AsyncGeneratorContext]].
    const gen_context = gen.fields.async_generator_context;

    // 3. Set gen.[[AsyncGeneratorState]] to executing.
    gen.fields.async_generator_state = .executing;

    // 4. Perform ! RunSuspendedContext(genContext, completion).
    const caller_context = agent.runningExecutionContext();
    try agent.execution_context_stack.append(agent.gc_allocator, gen_context);
    try gen.fields.evaluation_state.closure(
        agent,
        gen.fields.evaluation_state.gen_func,
        completion,
    );
    std.debug.assert(caller_context == agent.runningExecutionContext());

    // 5. Return unused.
}

/// 27.9.3.7 AsyncGeneratorUnwrapYieldResumption ( resumptionValue )
/// https://tc39.es/ecma262/#sec-asyncgeneratorunwrapyieldresumption
pub fn asyncGeneratorUnwrapYieldResumption(agent: *Agent, resumption_value: Completion) Agent.Error!Completion {
    // 1. If resumptionValue is not a return completion, return ? resumptionValue.
    const value = switch (resumption_value) {
        .@"return" => |value| value,
        else => return resumption_value,
    };

    // 2. Let awaited be Completion(Await(resumptionValue.[[Value]])).
    const awaited = await(agent, value) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,

        // 3. If awaited is a throw completion, return ? awaited.
        error.ExceptionThrown => {
            const exception = agent.clearException();
            return .{ .throw = exception.value };
        },
    };

    // 4. Assert: awaited is a normal completion.
    // 5. Return ReturnCompletion(awaited.[[Value]]).
    return .{ .@"return" = awaited };
}

/// 27.9.3.8 AsyncGeneratorYield ( arg )
/// https://tc39.es/ecma262/#sec-asyncgeneratoryield
pub fn asyncGeneratorYield(agent: *Agent, arg: Value) Agent.Error!Completion {
    // 1. Let genContext be the running execution context.
    const gen_context = agent.runningExecutionContext();

    // 2. Assert: genContext is the execution context of a generator.
    // 3. Let gen be the value of the Generator component of genContext.
    // 4. Assert: GetGeneratorKind() is async.
    const gen = gen_context.generator.async_generator;

    // 5. Let completion be NormalCompletion(arg).
    const completion: Completion = .{ .normal = arg };

    // 6. Assert: The execution context stack has at least two elements.
    std.debug.assert(agent.execution_context_stack.items.len >= 2);

    // 7. Let previousContext be the second to top element of the execution context stack.
    const previous_context = agent.execution_context_stack.items[agent.execution_context_stack.items.len - 2];

    // 8. Let previousRealm be previousContext's Realm.
    const previous_realm = previous_context.realm;

    // 9. Perform AsyncGeneratorCompleteStep(gen, completion, false, previousRealm).
    try asyncGeneratorCompleteStep(agent, gen, completion, false, previous_realm);

    // 10. Let queue be gen.[[AsyncGeneratorQueue]].
    const queue = &gen.fields.async_generator_queue;

    // 11. If queue is not empty, then
    if (queue.items.len != 0) {
        // a. NOTE: Execution continues without suspending the generator.
        // b. Let toYield be the first element of queue.
        const to_yield = queue.items[0];

        // c. Let resumptionValue be Completion(toYield.[[Completion]]).
        const resumption_value = to_yield.completion;

        // d. Return ? AsyncGeneratorUnwrapYieldResumption(resumptionValue).
        return asyncGeneratorUnwrapYieldResumption(agent, resumption_value);
    }

    // 12. Set gen.[[AsyncGeneratorState]] to suspended-yield.
    gen.fields.async_generator_state = .suspended_yield;

    // 13. Let resumptionValue be Completion(RunCallerContext(undefined)).
    // 14. Return ? AsyncGeneratorUnwrapYieldResumption(resumptionValue).
    _ = agent.execution_context_stack.pop().?;
    gen.fields.evaluation_state.suspension_result = .undefined;
    return .{ .normal = .undefined };
}

/// 27.9.3.10 AsyncGeneratorDrainQueue ( gen )
/// https://tc39.es/ecma262/#sec-asyncgeneratordrainqueue
pub fn asyncGeneratorDrainQueue(
    agent: *Agent,
    gen: *AsyncGenerator,
) std.mem.Allocator.Error!void {
    // 1. Assert: gen.[[AsyncGeneratorState]] is draining-queue.
    std.debug.assert(gen.fields.async_generator_state == .draining_queue);

    // 2. Let queue be gen.[[AsyncGeneratorQueue]].
    const queue = &gen.fields.async_generator_queue;

    // 3. Repeat, while queue is not empty,
    while (queue.items.len != 0) {
        // a. Let next be the first element of queue.
        const next = queue.items[0];

        // b. Let completion be Completion(next.[[Completion]]).
        var completion = next.completion;

        // c. If completion is a return completion, then
        if (completion == .@"return") {
            // i. Perform AsyncGeneratorAwaitReturn(gen).
            try asyncGeneratorAwaitReturn(agent, gen);

            // ii. Return unused.
            return;
        }

        // d. If completion is a normal completion, then
        if (completion == .normal) {
            // i. Set completion to NormalCompletion(undefined).
            completion = .{ .normal = .undefined };
        }

        // e. Perform AsyncGeneratorCompleteStep(gen, completion, true).
        try asyncGeneratorCompleteStep(agent, gen, completion, true, null);
    }

    // 4. Set gen.[[AsyncGeneratorState]] to completed.
    gen.fields.async_generator_state = .completed;

    // 5. Return unused.
}

/// 27.9.3.9 AsyncGeneratorAwaitReturn ( gen )
/// https://tc39.es/ecma262/#sec-asyncgeneratorawaitreturn
pub fn asyncGeneratorAwaitReturn(
    agent: *Agent,
    gen: *AsyncGenerator,
) std.mem.Allocator.Error!void {
    const realm = agent.currentRealm();

    // 1. Assert: gen.[[AsyncGeneratorState]] is draining-queue.
    std.debug.assert(gen.fields.async_generator_state == .draining_queue);

    // 2. Let queue be gen.[[AsyncGeneratorQueue]].
    const queue = &gen.fields.async_generator_queue;

    // 3. Assert: queue is not empty.
    std.debug.assert(queue.items.len != 0);

    // 4. Let next be the first element of queue.
    const next = queue.items[0];

    // 5. Let completion be Completion(next.[[Completion]]).
    const completion = next.completion;

    // 6. Assert: completion is a return completion.
    std.debug.assert(completion == .@"return");

    // 7. Let promiseCompletion be Completion(PromiseResolve(%Promise%, completion.[[Value]])).
    // 9. Assert: promiseCompletion is a normal completion.
    // 10. Let promise be promiseCompletion.[[Value]].
    const promise = promiseResolve(
        agent,
        try realm.intrinsic(.promise),
        completion.@"return",
    ) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,

        // 8. If promiseCompletion is an abrupt completion, then
        error.ExceptionThrown => {
            const exception = agent.clearException();
            const promise_completion: Completion = .{ .throw = exception.value };

            // a. Perform AsyncGeneratorCompleteStep(gen, promiseCompletion, true).
            try asyncGeneratorCompleteStep(agent, gen, promise_completion, true, null);

            // b. Perform AsyncGeneratorDrainQueue(gen).
            try asyncGeneratorDrainQueue(agent, gen);

            // c. Return unused.
            return;
        },
    };

    const Captures = struct {
        gen: *AsyncGenerator,
    };
    const captures = try agent.gc_allocator.create(Captures);
    captures.* = .{
        .gen = gen,
    };

    // 11. Let fulfilledClosure be a new Abstract Closure with parameters (value) that captures gen
    //     and performs the following steps when called:
    const fulfilled_closure = struct {
        fn func(agent_: *Agent, _: Value, arguments_: Arguments) Agent.Error!Value {
            const function_ = agent_.activeFunctionObject();
            const captures_ = function_.as(builtins.BuiltinFunction).fields.additionalFieldsAs(Captures);
            const gen_ = captures_.gen;
            const value = arguments_.get(0);

            // a. Assert: gen.[[AsyncGeneratorState]] is draining-queue.
            std.debug.assert(gen_.fields.async_generator_state == .draining_queue);

            // b. Let result be NormalCompletion(value).
            const result: Completion = .{ .normal = value };

            // c. Perform AsyncGeneratorCompleteStep(gen, result, true).
            try asyncGeneratorCompleteStep(agent_, gen_, result, true, null);

            // d. Perform AsyncGeneratorDrainQueue(gen).
            try asyncGeneratorDrainQueue(agent_, gen_);

            // e. Return NormalCompletion(undefined).
            return .undefined;
        }
    }.func;

    // 12. Let onFulfilled be CreateBuiltinFunction(fulfilledClosure, 1, "", « »).
    const on_fulfilled = try createBuiltinFunction(
        agent,
        .{ .function = fulfilled_closure },
        1,
        "",
        .{ .additional_fields = captures },
    );

    // 13. Let rejectedClosure be a new Abstract Closure with parameters (reason) that captures gen
    //     and performs the following steps when called:
    const rejected_closure = struct {
        fn func(agent_: *Agent, _: Value, arguments_: Arguments) Agent.Error!Value {
            const function_ = agent_.activeFunctionObject();
            const captures_ = function_.as(builtins.BuiltinFunction).fields.additionalFieldsAs(Captures);
            const gen_ = captures_.gen;
            const reason = arguments_.get(0);

            // a. Assert: gen.[[AsyncGeneratorState]] is draining-queue.
            std.debug.assert(gen_.fields.async_generator_state == .draining_queue);

            // b. Let result be ThrowCompletion(reason).
            const result: Completion = .{ .throw = reason };

            // c. Perform AsyncGeneratorCompleteStep(gen, result, true).
            try asyncGeneratorCompleteStep(agent_, gen_, result, true, null);

            // d. Perform AsyncGeneratorDrainQueue(gen).
            try asyncGeneratorDrainQueue(agent_, gen_);

            // e. Return NormalCompletion(undefined).
            return .undefined;
        }
    }.func;

    // 14. Let onRejected be CreateBuiltinFunction(rejectedClosure, 1, "", « »).
    const on_rejected = try createBuiltinFunction(
        agent,
        .{ .function = rejected_closure },
        1,
        "",
        .{ .additional_fields = captures },
    );

    // 15. Perform PerformPromiseThen(promise, onFulfilled, onRejected).
    _ = try performPromiseThen(
        agent,
        promise.as(builtins.Promise),
        Value.from(&on_fulfilled.object),
        Value.from(&on_rejected.object),
        null,
    );

    // 16. Return unused.
}
