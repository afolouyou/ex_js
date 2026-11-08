//! 27.10 AsyncFunction Objects
//! https://tc39.es/ecma262/#sec-async-function-objects

const std = @import("std");

const ast = @import("../language/ast.zig");
const builtins = @import("../builtins.zig");
const execution = @import("../execution.zig");
const interpreter = @import("../interpreter.zig");
const types = @import("../types.zig");
const utils = @import("../utils.zig");

const Agent = execution.Agent;
const Arguments = types.Arguments;
const ExecutionContext = execution.ExecutionContext;
const Object = types.Object;
const PromiseCapability = builtins.promise.PromiseCapability;
const Realm = execution.Realm;
const Value = types.Value;
const createBuiltinFunction = builtins.createBuiltinFunction;
const createDynamicFunction = builtins.createDynamicFunction;
const noexcept = utils.noexcept;
const ordinaryObjectCreate = builtins.ordinaryObjectCreate;
const performPromiseThen = builtins.performPromiseThen;
const promiseResolve = builtins.promiseResolve;

/// 27.10.2 Properties of the AsyncFunction Constructor
/// https://tc39.es/ecma262/#sec-async-function-constructor-properties
pub const constructor = struct {
    pub fn create(agent: *Agent, realm: *Realm) std.mem.Allocator.Error!*Object {
        const builtin_function = try createBuiltinFunction(
            agent,
            .{ .constructor = impl },
            1,
            "AsyncFunction",
            .{ .realm = realm, .proto = try realm.intrinsic(.function) },
        );
        return &builtin_function.object;
    }

    pub fn init(agent: *Agent, realm: *Realm, object: *Object) std.mem.Allocator.Error!void {
        // 27.10.2.1 AsyncFunction.prototype
        // https://tc39.es/ecma262/#sec-async-function-constructor-prototype
        try object.defineBuiltinPropertyWithAttributes(
            agent,
            "prototype",
            Value.from(try realm.intrinsic(.async_function_prototype)),
            .none,
        );
    }

    /// 27.10.1.1 AsyncFunction ( ...paramArgs, bodyArg )
    /// https://tc39.es/ecma262/#sec-async-function-constructor-arguments
    fn impl(agent: *Agent, arguments: Arguments, new_target: ?*Object) Agent.Error!Value {
        const param_args = arguments.values[0..arguments.count() -| 1];
        const maybe_body_arg = arguments.getOrNull(arguments.count() -| 1);

        // 1. Let activeFunc be the active function object.
        const active_func = agent.activeFunctionObject();

        // 2. If bodyArg is not present, set bodyArg to the empty String.
        const body_arg = maybe_body_arg orelse Value.from("");

        // 3. Return ? CreateDynamicFunction(activeFunc, NewTarget, async, paramArgs, bodyArg).
        const ecmascript_function = try createDynamicFunction(
            agent,
            active_func,
            new_target,
            .async,
            param_args,
            body_arg,
        );
        return Value.from(&ecmascript_function.object);
    }
};

/// 27.10.3 Properties of the AsyncFunction Prototype Object
/// https://tc39.es/ecma262/#sec-async-function-prototype-properties
pub const prototype = struct {
    pub fn create(agent: *Agent, realm: *Realm) std.mem.Allocator.Error!*Object {
        return ordinaryObjectCreate(agent, try realm.intrinsic(.function_prototype));
    }

    pub fn init(agent: *Agent, realm: *Realm, object: *Object) std.mem.Allocator.Error!void {
        // 27.10.3.1 AsyncFunction.prototype.constructor
        // https://tc39.es/ecma262/#sec-async-function-prototype-properties-constructor
        try object.defineBuiltinPropertyWithAttributes(
            agent,
            "constructor",
            Value.from(try realm.intrinsic(.async_function)),
            .{
                .writable = false,
                .enumerable = false,
                .configurable = true,
            },
        );

        // 27.10.3.2 AsyncFunction.prototype [ %Symbol.toStringTag% ]
        // https://tc39.es/ecma262/#sec-async-function-prototype-%symbol.tostringtag%
        try object.defineBuiltinPropertyWithAttributes(
            agent,
            "Symbol.toStringTag",
            Value.from("AsyncFunction"),
            .{
                .writable = false,
                .enumerable = false,
                .configurable = true,
            },
        );
    }
};

/// 27.10.5.1 AsyncFunctionStart ( promiseCapability, asyncFuncBody )
/// https://tc39.es/ecma262/#sec-async-functions-abstract-operations-async-function-start
pub fn asyncFunctionStart(
    agent: *Agent,
    promise_capability: PromiseCapability,
    async_body: AsyncBody,
) std.mem.Allocator.Error!void {
    // 1. Let runningContext be the running execution context.
    const running_context = agent.runningExecutionContext();

    // 2. Let asyncContext be a copy of runningContext.
    // 3. NOTE: Copying the execution state is required for AsyncBlockStart to resume its execution.
    //    It is ill-defined to resume a currently executing context.
    const async_context = try agent.gc_allocator.create(ExecutionContext);
    async_context.* = running_context.*;

    // 4. Perform AsyncBlockStart(promiseCapability, asyncFuncBody, asyncContext).
    try asyncBlockStart(
        agent,
        promise_capability,
        async_body,
        async_context,
    );

    // 5. Return unused.
}

const AsyncBody = union(enum) {
    ecmascript_function: struct {
        function: *builtins.ECMAScriptFunction,
        arguments: []const Value,
    },
    abstract_closure: struct {
        func: *const fn (agent: *Agent, captures: *anyopaque) Agent.Error!Value,
        captures: *anyopaque,
    },
    module: ast.Module,
};

/// 27.10.5.2 AsyncBlockStart ( promiseCapability, asyncBody, asyncContext )
/// https://tc39.es/ecma262/#sec-asyncblockstart
pub fn asyncBlockStart(
    agent: *Agent,
    promise_capability: PromiseCapability,
    async_body: AsyncBody,
    async_context: *ExecutionContext,
) std.mem.Allocator.Error!void {
    // 1. Let closure be a new Abstract Closure with no parameters that captures promiseCapability
    //    and asyncBody and performs the following steps when called:
    const closure = struct {
        fn func(
            agent_: *Agent,
            promise_capability_: PromiseCapability,
            async_body_: AsyncBody,
        ) std.mem.Allocator.Error!void {
            // a. Let acAsyncContext be the running execution context.

            // b. If asyncBody is a Parse Node, then
            //     i. Let result be Completion(Evaluation of asyncBody).
            // c. Else,
            //     i. Assert: asyncBody is an Abstract Closure with no parameters.
            //     ii. Let result be Completion(asyncBody()).
            const result: Agent.Error!Value = switch (async_body_) {
                .ecmascript_function => |ef| blk: {
                    const bc = ef.function.fields.compile(agent_) catch |err| break :blk err;
                    var temp_vm: ?interpreter.Vm = null;
                    defer if (temp_vm) |*vm_| vm_.deinit();

                    const vm = agent_.active_vm orelse vm: {
                        // Create a temporary VM if none is active. This happens when draining
                        // the job queue for example.
                        temp_vm = interpreter.Vm.init(agent_, bc) catch |err| break :blk err;
                        break :vm &temp_vm.?;
                    };

                    vm.pushCallFrame(bc, ef.arguments) catch |err| break :blk err;
                    const result = vm.run(.{}) catch |err| {
                        vm.popCallFrame();
                        break :blk err;
                    };
                    const result_value = switch (result) {
                        .@"return" => |value| value,
                        .yield => unreachable,
                    };
                    break :blk result_value orelse .undefined;
                },
                .abstract_closure => |abstract_closure| abstract_closure.func(agent_, abstract_closure.captures),
                .module => |module| blk: {
                    const result_value = interpreter.compileAndRun(agent_, .{ .module = &module }, "<async module>") catch |err| break :blk err;
                    break :blk result_value orelse .undefined;
                },
            };

            // d. Assert: If we return here, the async function either threw an exception or
            //    performed an implicit or explicit return; all awaiting is done.

            // e. Remove acAsyncContext from the execution context stack and restore the execution
            //    context that is at the top of the execution context stack as the running execution
            //    context.
            _ = agent_.execution_context_stack.pop().?;

            if (result) |value| {
                // f. If result is a normal completion, then
                //     i. Perform ! Call(promiseCapability.[[Resolve]], undefined, « undefined »).
                // g. Else if result is a return completion, then
                //     i. Perform ! Call(promiseCapability.[[Resolve]], undefined,
                //        « result.[[Value]] »).
                _ = promise_capability_.resolve.call(
                    agent_,
                    .undefined,
                    &.{value},
                ) catch |err| try noexcept(err);
            }
            // h. Else,
            else |err| switch (err) {
                error.OutOfMemory => |e| return e,

                // i. Assert: result is a throw completion.
                error.ExceptionThrown => {
                    const exception = agent_.clearException();

                    // ii. Perform ! Call(promiseCapability.[[Reject]], undefined,
                    //     « result.[[Value]] »).
                    _ = promise_capability_.reject.call(
                        agent_,
                        .undefined,
                        &.{exception.value},
                    ) catch |err_| try noexcept(err_);
                },
            }

            // i. Let callerContext be the running execution context.
            // j. Resume callerContext, passing NormalCompletion(unused).
            // k. Assert: This step is never reached.
        }
    }.func;

    // 2. Set the code evaluation state of asyncContext such that when evaluation is resumed for
    //    that execution context, closure will be called with no arguments.

    // 3. Let result be ! RunSuspendedContext(asyncContext, NormalCompletion(empty)).
    // 4. Assert: result is unused.
    // 5. NOTE: The possible sources of result values are Await or, if the async function doesn't
    //    await anything, step 1.j above.
    // 6. Return unused.
    const running_context = agent.runningExecutionContext();
    try agent.execution_context_stack.append(agent.gc_allocator, async_context);
    try closure(agent, promise_capability, async_body);
    std.debug.assert(running_context == agent.runningExecutionContext());
}

/// 27.10.5.3 Await ( arg )
/// https://tc39.es/ecma262/#await
pub fn await(agent: *Agent, arg: Value) Agent.Error!Value {
    const realm = agent.currentRealm();
    // 1. Let asyncContext be the running execution context.
    const async_context = agent.runningExecutionContext();

    // 2. Let promise be ? PromiseResolve(%Promise%, arg).
    const promise_object = try promiseResolve(agent, try realm.intrinsic(.promise), arg);
    const promise = promise_object.as(builtins.Promise);

    const Captures = struct {
        async_context: *ExecutionContext,
    };
    const captures = try agent.gc_allocator.create(Captures);
    captures.* = .{ .async_context = async_context };

    // 3. Let fulfilledClosure be a new Abstract Closure with parameters (value) that captures
    //    asyncContext and performs the following steps when called:
    const fulfilled_closure = struct {
        fn func(agent_: *Agent, _: Value, arguments_: Arguments) Agent.Error!Value {
            const function_ = agent_.activeFunctionObject();
            const captures_ = function_.as(builtins.BuiltinFunction).fields.additionalFieldsAs(Captures);
            const async_context_ = captures_.async_context;
            const value_ = arguments_.get(0);

            // TODO: a. Perform Completion(RunSuspendedContext(asyncContext, NormalCompletion(
            //          value))).
            // b. NOTE: The Completion Record returned by RunSuspendedContext is intentionally
            //    ignored.
            _ = value_;
            _ = async_context_;

            // c. Return NormalCompletion(undefined).
            return .undefined;
        }
    }.func;

    // 4. Let onFulfilled be CreateBuiltinFunction(fulfilledClosure, 1, "", « »).
    const on_fulfilled = try createBuiltinFunction(
        agent,
        .{ .function = fulfilled_closure },
        1,
        "",
        .{ .additional_fields = captures },
    );

    // 5. Let rejectedClosure be a new Abstract Closure with parameters (reason) that captures
    //    asyncContext and performs the following steps when called:
    const rejected_closure = struct {
        fn func(agent_: *Agent, _: Value, arguments_: Arguments) Agent.Error!Value {
            const function_ = agent_.activeFunctionObject();
            const captures_ = function_.as(builtins.BuiltinFunction).fields.additionalFieldsAs(Captures);
            const async_context_ = captures_.async_context;
            const reason = arguments_.get(0);

            // TODO: a. Perform Completion(RunSuspendedContext(asyncContext, ThrowCompletion(
            //          reason))).
            // b. NOTE: The Completion Record returned by RunSuspendedContext is intentionally
            //    ignored.
            _ = reason;
            _ = async_context_;

            // c. Return NormalCompletion(undefined).
            return .undefined;
        }
    }.func;

    // 6. Let onRejected be CreateBuiltinFunction(rejectedClosure, 1, "", « »).
    const on_rejected = try createBuiltinFunction(
        agent,
        .{ .function = rejected_closure },
        1,
        "",
        .{ .additional_fields = captures },
    );

    // 7. Perform PerformPromiseThen(promise, onFulfilled, onRejected).
    _ = try performPromiseThen(
        agent,
        promise,
        Value.from(&on_fulfilled.object),
        Value.from(&on_rejected.object),
        null,
    );

    // 8. Return ? RunCallerContext(empty).
    agent.drainJobQueue();
    switch (promise.fields.promise_state) {
        .pending => return Value.from(&promise.object), // `await properAwait()` :)
        .rejected => {
            agent.exception = .{
                .value = promise.fields.promise_result,
                // TODO: Capture stack when rejecting a promise
                .stack_trace = &.{},
            };
            return error.ExceptionThrown;
        },
        .fulfilled => return promise.fields.promise_result,
    }
}
