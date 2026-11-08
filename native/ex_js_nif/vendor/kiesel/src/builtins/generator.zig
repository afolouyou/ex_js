//! 27.8 Generator Objects
//! https://tc39.es/ecma262/#sec-generator-objects

const std = @import("std");

const builtins = @import("../builtins.zig");
const execution = @import("../execution.zig");
const interpreter = @import("../interpreter.zig");
const types = @import("../types.zig");

const Agent = execution.Agent;
const Arguments = types.Arguments;
const ExecutionContext = execution.ExecutionContext;
const MakeObject = types.MakeObject;
const Object = types.Object;
const Realm = execution.Realm;
const Value = types.Value;
const asyncGeneratorYield = builtins.asyncGeneratorYield;
const await = builtins.await;
const createIteratorResultObject = types.createIteratorResultObject;
const ordinaryObjectCreate = builtins.ordinaryObjectCreate;

/// 27.8.1 The %GeneratorPrototype% Object
/// https://tc39.es/ecma262/#sec-properties-of-generator-prototype
pub const prototype = struct {
    pub fn create(agent: *Agent, realm: *Realm) std.mem.Allocator.Error!*Object {
        return ordinaryObjectCreate(agent, try realm.intrinsic(.iterator_prototype));
    }

    pub fn init(agent: *Agent, realm: *Realm, object: *Object) std.mem.Allocator.Error!void {
        try object.defineBuiltinFunction(agent, "next", next, 1, realm);
        try object.defineBuiltinFunction(agent, "return", @"return", 1, realm);
        try object.defineBuiltinFunction(agent, "throw", throw, 1, realm);

        // 27.8.1.1 %GeneratorPrototype%.constructor
        // https://tc39.es/ecma262/#sec-generator.prototype.constructor
        try object.defineBuiltinPropertyWithAttributes(
            agent,
            "constructor",
            Value.from(try realm.intrinsic(.generator_function_prototype)),
            .{
                .writable = false,
                .enumerable = false,
                .configurable = true,
            },
        );

        // 27.8.1.5 %GeneratorPrototype% [ %Symbol.toStringTag% ]
        // https://tc39.es/ecma262/#sec-generator.prototype-%symbol.tostringtag%
        try object.defineBuiltinPropertyWithAttributes(
            agent,
            "Symbol.toStringTag",
            Value.from("Generator"),
            .{
                .writable = false,
                .enumerable = false,
                .configurable = true,
            },
        );
    }

    /// 27.8.1.2 %GeneratorPrototype%.next ( value )
    /// https://tc39.es/ecma262/#sec-generator.prototype.next
    fn next(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const value = arguments.get(0);

        // 1. Return ? GeneratorResume(this value, value, empty).
        return Value.from(try generatorResume(agent, this_value, value));
    }

    /// 27.8.1.3 %GeneratorPrototype%.return ( value )
    /// https://tc39.es/ecma262/#sec-generator.prototype.return
    fn @"return"(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const value = arguments.get(0);

        // 1. Let gen be the this value.
        const gen = this_value;

        // 2. Let completion be ReturnCompletion(value).
        const completion: Completion = .{ .@"return" = value };

        // 3. Return ? GeneratorResumeAbrupt(gen, completion, empty).
        return Value.from(try generatorResumeAbrupt(agent, gen, completion));
    }

    /// 27.8.1.4 %GeneratorPrototype%.throw ( exception )
    /// https://tc39.es/ecma262/#sec-generator.prototype.throw
    fn throw(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const exception = arguments.get(0);

        // 1. Let gen be the this value.
        const gen = this_value;

        // 2. Let completion be ThrowCompletion(exception).
        const completion: Completion = .{ .throw = exception };

        // 3. Return ? GeneratorResumeAbrupt(gen, completion, empty).
        return Value.from(try generatorResumeAbrupt(agent, gen, completion));
    }
};

/// 27.8.2 Properties of Generator Instances
/// https://tc39.es/ecma262/#sec-properties-of-generator-instances
pub const Generator = MakeObject(.{
    .Fields = struct {
        pub const State = enum {
            suspended_start,
            suspended_yield,
            executing,
            completed,
        };

        /// [[GeneratorState]]
        generator_state: State,

        /// [[GeneratorContext]]
        generator_context: *ExecutionContext,

        // Non-standard
        evaluation_state: struct {
            closure: *const fn (*Agent, *builtins.ECMAScriptFunction, Completion) Agent.Error!*Object,
            gen_func: *builtins.ECMAScriptFunction,
            suspension_result: ?Value = null,
            suspension: ?interpreter.Vm.GeneratorSuspension = null,
        },
    },
    .tag = .generator,
    .display_name = "Generator",
});

pub const Completion = union(enum) {
    normal: Value,
    @"return": Value,
    throw: Value,
};

/// 27.8.3.1 GeneratorStart ( gen, genBody )
/// https://tc39.es/ecma262/#sec-generatorstart
pub fn generatorStart(
    agent: *Agent,
    gen: *Generator,
    gen_func: *builtins.ECMAScriptFunction,
    initial_suspension: interpreter.Vm.GeneratorSuspension,
) std.mem.Allocator.Error!void {
    // 1. Assert: gen.[[GeneratorState]] is suspended-start.
    std.debug.assert(gen.fields.generator_state == .suspended_start);

    // 2. Let genContext be the running execution context.
    // NOTE: The running execution context may be stack-allocated by the caller, so we replace it
    //       with a heap-allocated one here since generators store it for later resumption.
    const gen_context = try agent.gc_allocator.create(ExecutionContext);
    gen_context.* = agent.runningExecutionContext().*;
    agent.execution_context_stack.lastPtr().?.* = gen_context;

    // 3. Set the Generator component of genContext to gen.
    gen_context.generator = .{ .generator = gen };

    // 4. Let closure be a new Abstract Closure with no parameters that captures genBody and
    //    performs the following steps when called:
    const closure = struct {
        fn func(
            agent_: *Agent,
            generator_function_: *builtins.ECMAScriptFunction,
            resume_completion: Completion,
        ) Agent.Error!*Object {
            // a. Let acGenContext be the running execution context.
            const closure_gen_context = agent_.runningExecutionContext();

            // b. Let acGen be the Generator component of acGenContext.
            const closure_gen = closure_gen_context.generator.generator;

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
                .@"return", .throw => |value| {
                    _ = agent_.execution_context_stack.pop().?;
                    closure_gen.fields.generator_state = .completed;
                    closure_gen.fields.evaluation_state = undefined;

                    if (resume_completion == .@"return") {
                        return createIteratorResultObject(agent_, value, true);
                    }

                    agent_.exception = .{
                        .value = value,
                        .stack_trace = agent_.captureStackTrace(.{}) catch &.{},
                    };
                    return error.ExceptionThrown;
                },
            }

            // c. If genBody is a Parse Node, then
            //     i. Let result be Completion(Evaluation of genBody).
            // d. Else,
            //     i. Assert: genBody is an Abstract Closure with no parameters.
            //     ii. Let result be Completion(genBody()).
            const bc = generator_function_.fields.cached_bytecode.?;
            const result = vm.@"resume"(bc, suspension.*) catch |err| {
                // f-h, k.
                _ = agent_.execution_context_stack.pop().?;
                closure_gen.fields.generator_state = .completed;
                closure_gen.fields.evaluation_state = undefined;
                return err;
            };
            switch (result) {
                .yield => |next_suspension| {
                    const suspension_result = closure_gen.fields.evaluation_state.suspension_result.?;
                    closure_gen.fields.evaluation_state.suspension = next_suspension;
                    closure_gen.fields.evaluation_state.suspension_result = null;
                    return suspension_result.asObject();
                },
                .@"return" => |value| {
                    // e. Assert: If we return here, the generator either threw an exception or
                    //    performed either an implicit or explicit return.

                    // f. Remove acGenContext from the execution context stack and restore the
                    //    execution context that is at the top of the execution context stack as the
                    //    running execution context.
                    _ = agent_.execution_context_stack.pop().?;

                    // g. Set acGen.[[GeneratorState]] to completed.
                    closure_gen.fields.generator_state = .completed;

                    // h. NOTE: Once a generator enters the completed state it never leaves it and
                    //    its associated execution context is never resumed. Any execution state
                    //    associated with acGen can be discarded at this point.
                    closure_gen.fields.evaluation_state = undefined;

                    // i. If result is a throw completion, then
                    //     i. Let resumption be result.
                    // j. Else,
                    //     i. If result is a normal completion, then
                    //         1. Let resultValue be undefined.
                    //     ii. Else if result is a return completion, then
                    //         1. Let resultValue be result.[[Value]].
                    //     iii. Let resumption be NormalCompletion(CreateIteratorResultObject(
                    //          resultValue, true)).
                    // k. Let callerContext be the running execution context.
                    // l. Resume callerContext, passing resumption.
                    // m. Assert: This step is never reached.
                    const result_value: Value = value orelse .undefined;
                    return createIteratorResultObject(agent_, result_value, true);
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

    // 6. Set gen.[[GeneratorContext]] to genContext.
    gen.fields.generator_context = gen_context;

    // 7. Return unused.
}

/// 27.8.3.2 GeneratorValidate ( gen, genBrand )
/// https://tc39.es/ecma262/#sec-generatorvalidate
pub fn generatorValidate(
    agent: *Agent,
    gen_value: Value,
) Agent.Error!struct { *Generator, Generator.Fields.State } {
    // 1. Perform ? RequireInternalSlot(gen, [[GeneratorState]]).
    // 2. Perform ? RequireInternalSlot(gen, [[GeneratorBrand]]).
    const gen = try gen_value.requireInternalSlot(agent, Generator);

    // 3. If gen.[[GeneratorBrand]] is not genBrand, throw a TypeError exception.
    // NOTE: All iterators using [[GeneratorBrand]] in the spec are implemented without generators
    //       so this is currently not needed.

    // 4. Assert: gen has a [[GeneratorContext]] internal slot.
    // 5. Let state be gen.[[GeneratorState]].
    const state = gen.fields.generator_state;

    // 6. If state is executing, throw a TypeError exception.
    if (state == .executing) {
        return agent.throwException(.type_error, "Generator is currently executing", .{});
    }

    // 7. Return state.
    // NOTE: Returning the object here allows for direct assignment of the object at the call site.
    return .{ gen, state };
}

/// 27.8.3.3 GeneratorResume ( gen, value, genBrand )
/// https://tc39.es/ecma262/#sec-generatorresume
pub fn generatorResume(agent: *Agent, gen_value: Value, value: Value) Agent.Error!*Object {
    // 1. Let state be ? GeneratorValidate(gen, genBrand).
    const gen, const state = try generatorValidate(agent, gen_value);

    // 2. If state is completed, return CreateIteratorResultObject(undefined, true).
    if (state == .completed) return createIteratorResultObject(agent, .undefined, true);

    // 3. Assert: state is either suspended-start or suspended-yield.
    std.debug.assert(state == .suspended_start or state == .suspended_yield);

    // 4. Let genContext be gen.[[GeneratorContext]].
    const gen_context = gen.fields.generator_context;

    // 5. Set gen.[[GeneratorState]] to executing.
    gen.fields.generator_state = .executing;

    // 6. Return ? RunSuspendedContext(genContext, NormalCompletion(value)).
    const caller_context = agent.runningExecutionContext();
    try agent.execution_context_stack.append(agent.gc_allocator, gen_context);
    const result = try gen.fields.evaluation_state.closure(
        agent,
        gen.fields.evaluation_state.gen_func,
        .{ .normal = value },
    );
    std.debug.assert(caller_context == agent.runningExecutionContext());
    return result;
}

/// 27.8.3.4 GeneratorResumeAbrupt ( gen, abruptCompletion, genBrand )
/// https://tc39.es/ecma262/#sec-generatorresumeabrupt
pub fn generatorResumeAbrupt(
    agent: *Agent,
    gen_value: Value,
    abrupt_completion: Completion,
) Agent.Error!*Object {
    // 1. Let state be ? GeneratorValidate(gen, genBrand).
    const gen, var state = try generatorValidate(agent, gen_value);

    // 2. If state is suspended-start, then
    if (state == .suspended_start) {
        // a. Set gen.[[GeneratorState]] to completed.
        gen.fields.generator_state = .completed;

        // b. NOTE: Once a generator enters the completed state it never leaves it and its
        //    associated execution context is never resumed. Any execution state associated with gen
        //    can be discarded at this point.
        gen.fields.evaluation_state = undefined;

        // c. Set state to completed.
        state = .completed;
    }

    // 3. If state is completed, then
    if (state == .completed) {
        switch (abrupt_completion) {
            .normal => unreachable,

            // a. If abruptCompletion is a return completion, then
            .@"return" => |value| {
                // i. Return CreateIteratorResultObject(abruptCompletion.[[Value]], true).
                return createIteratorResultObject(agent, value, true);
            },

            // b. Return ? abruptCompletion.
            .throw => |value| {
                agent.exception = .{
                    .value = value,
                    .stack_trace = agent.captureStackTrace(.{}) catch &.{},
                };
                return error.ExceptionThrown;
            },
        }
    }

    // 4. Assert: state is suspended-yield.
    std.debug.assert(state == .suspended_yield);

    // 5. Let genContext be gen.[[GeneratorContext]].
    const gen_context = gen.fields.generator_context;

    // 6. Set gen.[[GeneratorState]] to executing.
    gen.fields.generator_state = .executing;

    // 7. Return ? RunSuspendedContext(genContext, abruptCompletion).
    const caller_context = agent.runningExecutionContext();
    try agent.execution_context_stack.append(agent.gc_allocator, gen_context);
    const result = try gen.fields.evaluation_state.closure(
        agent,
        gen.fields.evaluation_state.gen_func,
        abrupt_completion,
    );
    std.debug.assert(caller_context == agent.runningExecutionContext());
    return result;
}

pub const GeneratorKind = enum {
    non_generator,
    sync,
    async,
};

/// 27.8.3.5 GetGeneratorKind ( )
/// https://tc39.es/ecma262/#sec-getgeneratorkind
pub fn getGeneratorKind(agent: *Agent) GeneratorKind {
    // 1. Let genContext be the running execution context.
    const gen_context = agent.runningExecutionContext();

    // 2. If genContext does not have a Generator component, return non-generator.
    // 3. Let gen be the Generator component of genContext.
    return switch (gen_context.generator) {
        .unset => .non_generator,

        // 4. If gen has an [[AsyncGeneratorState]] internal slot, return async.
        .async_generator => .async,

        // 5. Return sync.
        .generator => .sync,
    };
}

/// 27.8.3.6 GeneratorYield ( iteratorResult )
/// https://tc39.es/ecma262/#sec-generatoryield
pub fn generatorYield(agent: *Agent, iterator_result: *Object) Agent.Error!Completion {
    // 1. Let genContext be the running execution context.
    const gen_context = agent.runningExecutionContext();

    // 2. Assert: genContext is the execution context of a generator.
    std.debug.assert(gen_context.generator != .unset);

    // 3. Let gen be the value of the Generator component of genContext.
    // 4. Assert: GetGeneratorKind() is sync.
    const gen = gen_context.generator.generator;

    // 5. Set gen.[[GeneratorState]] to suspended-yield.
    gen.fields.generator_state = .suspended_yield;

    // 6. Return ? RunCallerContext(iteratorResult).
    _ = agent.execution_context_stack.pop().?;
    gen.fields.evaluation_state.suspension_result = Value.from(iterator_result);
    return .{ .normal = .undefined };
}

/// 27.8.3.7 Yield ( arg )
/// https://tc39.es/ecma262/#sec-yield
pub fn yield(agent: *Agent, arg: Value) Agent.Error!Completion {
    // 1. Let genKind be GetGeneratorKind().
    const gen_kind = getGeneratorKind(agent);

    switch (gen_kind) {
        // 2. If genKind is async, return ? AsyncGeneratorYield(? Await(arg)).
        .async => return asyncGeneratorYield(agent, try await(agent, arg)),

        // 3. Return ? GeneratorYield(CreateIteratorResultObject(arg, false)).
        .sync => return generatorYield(agent, try createIteratorResultObject(agent, arg, false)),

        .non_generator => unreachable,
    }
}
