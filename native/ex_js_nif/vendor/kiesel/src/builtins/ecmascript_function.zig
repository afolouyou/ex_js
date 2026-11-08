//! 10.2 ECMAScript Function Objects
//! https://tc39.es/ecma262/#sec-ecmascript-function-objects

const std = @import("std");

const ast = @import("../language/ast.zig");
const builtins = @import("../builtins.zig");
const execution = @import("../execution.zig");
const interpreter = @import("../interpreter.zig");
const types = @import("../types.zig");
const utils = @import("../utils.zig");

const Agent = execution.Agent;
const Arguments = types.Arguments;
const BuiltinFunction = builtins.BuiltinFunction;
const ClassConstructorFields = builtins.builtin_function.ClassConstructorFields;
const ClassFieldDefinition = types.ClassFieldDefinition;
const Environment = execution.Environment;
const ExecutionContext = execution.ExecutionContext;
const MakeObject = types.MakeObject;
const Object = types.Object;
const PrivateElement = types.PrivateElement;
const PrivateEnvironment = execution.PrivateEnvironment;
const PrivateMethodDefinition = types.PrivateMethodDefinition;
const PropertyDescriptor = types.PropertyDescriptor;
const PropertyKey = types.PropertyKey;
const PropertyKeyOrPrivateName = types.PropertyKeyOrPrivateName;
const Realm = execution.Realm;
const ScriptOrModule = execution.ScriptOrModule;
const String = types.String;
const Value = types.Value;
const asyncFunctionStart = builtins.asyncFunctionStart;
const asyncGeneratorStart = builtins.asyncGeneratorStart;
const generatorStart = builtins.generatorStart;
const newFunctionEnvironment = execution.newFunctionEnvironment;
const newPromiseCapability = builtins.newPromiseCapability;
const noexcept = utils.noexcept;
const ordinaryCreateFromConstructor = builtins.ordinaryCreateFromConstructor;
const ordinaryObjectCreate = builtins.ordinaryObjectCreate;

pub const ConstructorKind = enum(u1) {
    base,
    derived,
};

pub const ThisMode = enum(u2) {
    lexical,
    strict,
    global,
};

pub const Flags = packed struct(u5) {
    /// [[ConstructorKind]]
    constructor_kind: ConstructorKind,

    /// [[ThisMode]]
    this_mode: ThisMode,

    /// [[Strict]]
    strict: bool,

    /// [[IsClassConstructor]]
    is_class_constructor: bool,
};

pub const ClassData = struct {
    /// [[ClassFieldInitializerName]]
    class_field_initializer_name: ?PropertyKeyOrPrivateName,

    /// [[Fields]]
    fields: []const ClassFieldDefinition,

    /// [[PrivateMethods]]
    private_methods: []const PrivateMethodDefinition,
};

pub const SourceText = union(enum) {
    string: *const String,
    // Most functions never have their source text accessed, so we create the heap-allocated slice
    // string lazily when resolving.
    slice: struct {
        source: []const u8,
        source_range: ast.SourceRange,
    },

    pub fn resolve(source_text: SourceText, agent: *Agent) std.mem.Allocator.Error!*const String {
        return switch (source_text) {
            .string => |string| string,
            .slice => |slice| try String.fromUtf8(
                agent,
                slice.source[slice.source_range.start..slice.source_range.end],
            ),
        };
    }
};

pub const ECMAScriptFunction = MakeObject(.{
    .Fields = struct {
        /// [[Environment]]
        environment: Environment,

        /// [[PrivateEnvironment]]
        private_environment: ?*PrivateEnvironment,

        /// [[FormalParameters]]
        formal_parameters: ast.FormalParameters,

        /// [[ECMAScriptCode]]
        ecmascript_code: ast.FunctionBody,

        /// [[Realm]]
        realm: *Realm,

        /// [[ScriptOrModule]]
        script_or_module: ScriptOrModule,

        /// [[HomeObject]]
        home_object: ?*Object,

        /// [[SourceText]]
        source_text: SourceText,

        flags: Flags,
        class_data: ?*ClassData,
        cached_bytecode: ?*const interpreter.Bytecode = null,
        initial_name: ?*const String,

        pub fn ensureClassData(self: *@This(), agent: *Agent) std.mem.Allocator.Error!*ClassData {
            if (self.class_data) |class_data| return class_data;

            const class_data = try agent.gc_allocator.create(ClassData);
            class_data.* = .{
                .class_field_initializer_name = null,
                .fields = &.{},
                .private_methods = &.{},
            };
            self.class_data = class_data;
            return class_data;
        }

        pub fn compile(self: *@This(), agent: *Agent) std.mem.Allocator.Error!*const interpreter.Bytecode {
            if (self.cached_bytecode) |bc| return bc;

            const gpa = agent.gpa;
            const func: *ECMAScriptFunction = @alignCast(@fieldParentPtr("fields", self));
            const name = try (self.initial_name orelse unreachable).toUtf8(gpa);
            defer gpa.free(name);

            if (func.fields.flags.this_mode == .lexical) {
                // FDI IR lowering does not have [[ThisMode]] information and instead relies on the
                // parser setting these.
                std.debug.assert(!self.formal_parameters.arguments_object_needed);
                std.debug.assert(!self.ecmascript_code.arguments_object_needed);
            }

            const bc = try agent.gc_allocator.create(interpreter.Bytecode);
            errdefer agent.gc_allocator.destroy(bc);
            bc.* = try interpreter.compile(agent, name, .{
                .function = .{
                    .parameters = &self.formal_parameters,
                    .body = &self.ecmascript_code,
                },
            });

            self.cached_bytecode = bc;
            return bc;
        }
    },
    .tag = .ecmascript_function,
    .display_name = "Function",
});

pub const internal_methods = Object.InternalMethods.initComptime(.{
    .call = call,
});

pub const internal_methods_constructor = Object.InternalMethods.initComptime(.{
    .call = call,
    .construct = construct,
});

/// 10.2.1 [[Call]] ( thisArg, argList )
/// https://tc39.es/ecma262/#sec-ecmascript-function-objects-call-thisargument-argumentslist
fn call(
    agent: *Agent,
    obj: *Object,
    this_arg: Value,
    arg_list: Arguments,
) Agent.Error!Value {
    const func = obj.as(ECMAScriptFunction);

    if (agent.platform.checkStackOverflow()) {
        return agent.throwException(.internal_error, "Stack overflow", .{});
    }

    // 1. Let callerContext be the running execution context.
    // NOTE: This is only used to restore the context, which is a simple pop().

    // 2. Let calleeContext be PrepareForOrdinaryCall(func, undefined).
    var callee_context: ExecutionContext = undefined;
    try prepareForOrdinaryCall(agent, func, null, &callee_context);

    // 3. Assert: calleeContext is now the running execution context.
    std.debug.assert(&callee_context == agent.runningExecutionContext());

    // 4. If func.[[IsClassConstructor]] is true, then
    if (func.fields.flags.is_class_constructor) {
        // a. Let error be a newly created TypeError object.
        // b. NOTE: error is created in calleeContext with func's associated Realm Record.
        const err = agent.throwException(.type_error, "{f} is not callable", .{obj});

        // c. Remove calleeContext from the execution context stack and restore callerContext as the
        //    running execution context.
        _ = agent.execution_context_stack.pop().?;

        // d. Throw error.
        return err;
    }

    // 5. Perform OrdinaryCallBindThis(func, calleeContext, thisArg).
    try ordinaryCallBindThis(agent, func, &callee_context, this_arg);

    // 6. Let result be Completion(OrdinaryCallEvaluateBody(func, argList)).
    const result = ordinaryCallEvaluateBody(agent, func, arg_list);

    // 7. Remove calleeContext from the execution context stack and restore callerContext as the
    //    running execution context.
    _ = agent.execution_context_stack.pop().?;

    // 8. If result is a throw completion, return ? result.
    // 9. Assert: result is a return completion.
    // 10. Return result.[[Value]].
    return result;
}

/// 10.2.1.1 PrepareForOrdinaryCall ( func, newTarget )
/// https://tc39.es/ecma262/#sec-prepareforordinarycall
fn prepareForOrdinaryCall(
    agent: *Agent,
    func: *ECMAScriptFunction,
    new_target: ?*Object,
    callee_context: *ExecutionContext,
) std.mem.Allocator.Error!void {
    // 1. Let callerContext be the running execution context.
    // NOTE: This is only used to suspend the context, which we don't do yet.

    // 7. Let localEnv be NewFunctionEnvironment(func, newTarget).
    const local_env = try newFunctionEnvironment(agent.gc_allocator, func, new_target);

    // 2. Let calleeContext be a new ECMAScript code execution context.
    callee_context.* = .{
        // 3. Set the Function of calleeContext to func.
        .origin = .{ .function = &func.object },

        // 4. Let calleeRealm be func.[[Realm]].
        // 5. Set the Realm of calleeContext to calleeRealm.
        .realm = func.fields.realm,

        // 6. Set the ScriptOrModule of calleeContext to func.[[ScriptOrModule]].
        .script_or_module = func.fields.script_or_module,

        .ecmascript_code = .{
            // 8. Set the LexicalEnvironment of calleeContext to localEnv.
            .lexical_environment = .{ .function_environment = local_env },

            // 9. Set the VariableEnvironment of calleeContext to localEnv.
            .variable_environment = .{ .function_environment = local_env },

            // 10. Set the PrivateEnvironment of calleeContext to func.[[PrivateEnvironment]].
            .private_environment = func.fields.private_environment,
        },
    };

    // 11. If callerContext is not already suspended, suspend callerContext.

    // 12. Push calleeContext onto the execution context stack; calleeContext is now the running
    //     execution context.
    try agent.execution_context_stack.append(agent.gc_allocator, callee_context);

    // 13. NOTE: Any exception objects produced after this point are associated with calleeRealm.
    // 14. Return calleeContext.
}

/// 10.2.1.2 OrdinaryCallBindThis ( func, calleeContext, thisArg )
/// https://tc39.es/ecma262/#sec-ordinarycallbindthis
pub fn ordinaryCallBindThis(
    agent: *Agent,
    func: *ECMAScriptFunction,
    callee_context: *ExecutionContext,
    this_arg: Value,
) std.mem.Allocator.Error!void {
    // 1. Let thisMode be func.[[ThisMode]].
    const this_mode = func.fields.flags.this_mode;

    // 2. If thisMode is lexical, return unused.
    if (this_mode == .lexical) return;

    // 3. Let calleeRealm be func.[[Realm]].
    const callee_realm = func.fields.realm;

    // 4. Let localEnv be the LexicalEnvironment of calleeContext.
    const local_env = callee_context.ecmascript_code.lexical_environment;

    const this_value = blk: {
        // 5. If thisMode is strict, then
        if (this_mode == .strict) {
            // a. Let thisValue be thisArg.
            break :blk this_arg;
        } else {
            // 6. Else,
            // a. If thisArg is either undefined or null, then
            if (this_arg.isUndefined() or this_arg.isNull()) {
                // i. Let globalEnv be calleeRealm.[[GlobalEnv]].
                const global_env = callee_realm.global_env;

                // ii. Assert: globalEnv is a Global Environment Record.
                // iii. Let thisValue be globalEnv.[[GlobalThisValue]].
                break :blk Value.from(global_env.global_this_value);
            } else {
                // b. Else,
                // i. Let thisValue be ! ToObject(thisArg).
                // ii. NOTE: ToObject produces wrapper objects using calleeRealm.
                break :blk Value.from(this_arg.toObject(agent) catch |err| try noexcept(err));
            }
        }
    };

    // 7. Assert: localEnv is a Function Environment Record.
    // 8. Assert: The next step never returns an abrupt completion because
    //    localEnv.[[ThisBindingStatus]] is not initialized.
    // 9. Perform ! BindThisValue(localEnv, thisValue).
    local_env.function_environment.bindThisValue(agent, this_value) catch unreachable;

    // 10. Return unused.
}

/// 10.2.1.4 OrdinaryCallEvaluateBody ( func, argList )
/// https://tc39.es/ecma262/#sec-ordinarycallevaluatebody
pub fn ordinaryCallEvaluateBody(
    agent: *Agent,
    func: *ECMAScriptFunction,
    arg_list: Arguments,
) Agent.Error!Value {
    // 1. Return ? EvaluateBody of func.[[ECMAScriptCode]] with arguments func and argList.
    const function_body = func.fields.ecmascript_code;

    // 10.2.1.3 Runtime Semantics: EvaluateBody
    // https://tc39.es/ecma262/#sec-runtime-semantics-evaluatebody
    return switch (function_body.type) {
        // FunctionBody : FunctionStatementList
        // 1. Return ? EvaluateFunctionBody of FunctionBody with arguments func and argList.
        // ConciseBody : ExpressionBody
        // 1. Return ? EvaluateConciseBody of ConciseBody with arguments func and argList.
        .normal => evaluateFunctionBody(agent, func, arg_list),

        // GeneratorBody : FunctionBody
        // 1. Return ? EvaluateGeneratorBody of GeneratorBody with arguments func and argList.
        .generator => evaluateGeneratorBody(agent, func, arg_list),

        // AsyncGeneratorBody : FunctionBody
        // 1. Return ? EvaluateAsyncGeneratorBody of AsyncGeneratorBody with arguments func and
        //    argList.
        .async_generator => evaluateAsyncGeneratorBody(agent, func, arg_list),

        // AsyncFunctionBody : FunctionBody
        // 1. Return ? EvaluateAsyncFunctionBody of AsyncFunctionBody with arguments func and
        //    argList.
        // AsyncConciseBody : ExpressionBody
        // 1. Return ? EvaluateAsyncConciseBody of AsyncConciseBody with arguments func and argList.
        .async => evaluateAsyncFunctionBody(agent, func, arg_list),
    };
}

/// 15.2.3 Runtime Semantics: EvaluateFunctionBody
/// https://tc39.es/ecma262/#sec-runtime-semantics-evaluatefunctionbody
fn evaluateFunctionBody(
    agent: *Agent,
    func: *ECMAScriptFunction,
    arg_list: Arguments,
) Agent.Error!Value {
    // FunctionBody : FunctionStatementList

    const bc = try func.fields.compile(agent);
    var temp_vm: ?interpreter.Vm = null;
    defer if (temp_vm) |*vm| vm.deinit();

    const vm = agent.active_vm orelse blk: {
        // Create a temporary VM if none is active. This happens when draining the job queue
        // for example.
        temp_vm = try interpreter.Vm.init(agent, bc);
        break :blk &temp_vm.?;
    };

    // 1. Perform ? FunctionDeclarationInstantiation(funcObj, argList).
    // NOTE: FDI is handled via the generated bytecode.

    // 2. Perform ? Evaluation of FunctionStatementList.
    // 3. NOTE: If the previous step resulted in a normal completion, then evaluation finished by
    //    proceeding past the end of the FunctionStatementList.
    try vm.pushCallFrame(bc, arg_list.values);
    errdefer vm.popCallFrame();
    const result = try vm.run(.{});

    // 4. Return ReturnCompletion(undefined).
    return switch (result) {
        .@"return" => |value| value orelse .undefined,
        .yield => unreachable,
    };
}

/// 15.5.2 Runtime Semantics: EvaluateGeneratorBody
/// https://tc39.es/ecma262/#sec-runtime-semantics-evaluategeneratorbody
fn evaluateGeneratorBody(
    agent: *Agent,
    func: *ECMAScriptFunction,
    arg_list: Arguments,
) Agent.Error!Value {
    // GeneratorBody : FunctionBody
    // 1. Perform ? FunctionDeclarationInstantiation(funcObj, argList).
    const bc = try func.fields.compile(agent);
    var temp_vm: ?interpreter.Vm = null;
    defer if (temp_vm) |*vm| vm.deinit();

    const vm = agent.active_vm orelse blk: {
        // Create a temporary VM if none is active. This happens when draining the job queue
        // for example.
        temp_vm = try interpreter.Vm.init(agent, bc);
        break :blk &temp_vm.?;
    };

    try vm.pushCallFrame(bc, arg_list.values);
    errdefer vm.popCallFrame();
    const result = try vm.run(.{});
    const initial_suspension = switch (result) {
        .yield => |suspension| suspension,
        .@"return" => unreachable,
    };
    errdefer agent.gc_allocator.free(initial_suspension.stack);
    std.debug.assert(initial_suspension.yield_reg == .none);

    // 2. Let gen be ? OrdinaryCreateFromConstructor(funcObj, "%GeneratorPrototype%",
    //    « [[GeneratorState]], [[GeneratorContext]], [[GeneratorBrand]] »).
    const gen = try ordinaryCreateFromConstructor(
        builtins.Generator,
        agent,
        &func.object,
        .generator_prototype,
        .{
            // 3. Set gen.[[GeneratorBrand]] to empty.
            // 4. Set gen.[[GeneratorState]] to suspended-start.
            .generator_state = .suspended_start,
            .generator_context = undefined,
            .evaluation_state = undefined,
        },
    );

    // 5. Perform GeneratorStart(gen, FunctionBody).
    try generatorStart(agent, gen, func, initial_suspension);

    // 6. Return ReturnCompletion(gen).
    return Value.from(&gen.object);
}

/// 15.6.2 Runtime Semantics: EvaluateAsyncGeneratorBody
/// https://tc39.es/ecma262/#sec-runtime-semantics-evaluateasyncgeneratorbody
fn evaluateAsyncGeneratorBody(
    agent: *Agent,
    func: *ECMAScriptFunction,
    arg_list: Arguments,
) Agent.Error!Value {
    // AsyncGeneratorBody : FunctionBody
    // 1. Perform ? FunctionDeclarationInstantiation(funcObj, argList).
    const bc = try func.fields.compile(agent);
    var temp_vm: ?interpreter.Vm = null;
    defer if (temp_vm) |*vm| vm.deinit();

    const vm = agent.active_vm orelse blk: {
        // Create a temporary VM if none is active. This happens when draining the job queue
        // for example.
        temp_vm = try interpreter.Vm.init(agent, bc);
        break :blk &temp_vm.?;
    };

    try vm.pushCallFrame(bc, arg_list.values);
    errdefer vm.popCallFrame();
    const result = try vm.run(.{});
    const initial_suspension = switch (result) {
        .yield => |suspension| suspension,
        .@"return" => unreachable,
    };
    errdefer agent.gc_allocator.free(initial_suspension.stack);
    std.debug.assert(initial_suspension.yield_reg == .none);

    // 2. Let gen be ? OrdinaryCreateFromConstructor(funcObj, "%AsyncGeneratorPrototype%",
    //    « [[AsyncGeneratorState]], [[AsyncGeneratorContext]], [[AsyncGeneratorQueue]],
    //    [[GeneratorBrand]] »).
    const gen = try ordinaryCreateFromConstructor(
        builtins.AsyncGenerator,
        agent,
        &func.object,
        .async_generator_prototype,
        .{
            // 3. Set gen.[[GeneratorBrand]] to empty.
            // 4. Set gen.[[AsyncGeneratorState]] to suspended-start.
            .async_generator_state = .suspended_start,
            .async_generator_context = undefined,
            .async_generator_queue = undefined,
            .evaluation_state = undefined,
        },
    );

    // 5. Perform AsyncGeneratorStart(gen, FunctionBody).
    try asyncGeneratorStart(agent, gen, func, initial_suspension);

    // 6. Return ReturnCompletion(gen).
    return Value.from(&gen.object);
}

/// 15.8.4 Runtime Semantics: EvaluateAsyncFunctionBody
/// https://tc39.es/ecma262/#sec-runtime-semantics-evaluateasyncfunctionbody
fn evaluateAsyncFunctionBody(
    agent: *Agent,
    func: *ECMAScriptFunction,
    arg_list: Arguments,
) std.mem.Allocator.Error!Value {
    // AsyncFunctionBody : FunctionBody
    const realm = agent.currentRealm();

    // 1. Let promiseCapability be ! NewPromiseCapability(%Promise%).
    const promise_capability = newPromiseCapability(
        agent,
        Value.from(try realm.intrinsic(.promise)),
    ) catch |err| try noexcept(err);

    // 2. Let completion be Completion(FunctionDeclarationInstantiation(funcObj, argList)).
    // 3. If completion is an abrupt completion, then
    //     a. Perform ! Call(promiseCapability.[[Reject]], undefined, « completion.[[Value]] »).
    // 4. Else,
    //     a. Perform AsyncFunctionStart(promiseCapability, FunctionBody).
    // NOTE: FDI is handled via the generated bytecode.
    try asyncFunctionStart(agent, promise_capability, .{ .ecmascript_function = .{
        .function = func,
        .arguments = arg_list.values,
    } });

    // 5. Return ReturnCompletion(promiseCapability.[[Promise]]).
    return Value.from(promise_capability.promise);
}

/// 10.2.2 [[Construct]] ( argList, newTarget )
/// https://tc39.es/ecma262/#sec-ecmascript-function-objects-construct-argumentslist-newtarget
fn construct(
    agent: *Agent,
    obj: *Object,
    arg_list: Arguments,
    new_target: *Object,
) Agent.Error!*Object {
    const func = obj.as(ECMAScriptFunction);

    if (agent.platform.checkStackOverflow()) {
        return agent.throwException(.internal_error, "Stack overflow", .{});
    }

    // 1. Let callerContext be the running execution context.
    // NOTE: This is only used to restore the context, which is a simple pop().

    // 2. Let kind be func.[[ConstructorKind]].
    const kind = func.fields.flags.constructor_kind;

    var this_arg: *Object = undefined;

    // 3. If kind is base, then
    if (kind == .base) {
        // a. Let thisArg be ? OrdinaryCreateFromConstructor(newTarget, "%Object.prototype%").
        const this_arg_object = try ordinaryCreateFromConstructor(
            builtins.Object,
            agent,
            new_target,
            .object_prototype,
            {},
        );
        this_arg = &this_arg_object.object;
    }

    // 4. Let calleeContext be PrepareForOrdinaryCall(func, newTarget).
    var callee_context: ExecutionContext = undefined;
    try prepareForOrdinaryCall(agent, func, new_target, &callee_context);

    // 5. Assert: calleeContext is now the running execution context.
    std.debug.assert(&callee_context == agent.runningExecutionContext());

    // 6. If kind is base, then
    if (kind == .base) {
        // a. Perform OrdinaryCallBindThis(func, calleeContext, thisArg).
        try ordinaryCallBindThis(agent, func, &callee_context, Value.from(this_arg));

        // b. Let initializeResult be Completion(InitializeInstanceElements(thisArg, func)).
        const initialize_result = this_arg.initializeInstanceElements(
            agent,
            &func.object,
        );

        // c. If initializeResult is an abrupt completion, then
        initialize_result catch |err| {
            // i. Remove calleeContext from the execution context stack and restore callerContext as
            //    the running execution context.
            _ = agent.execution_context_stack.pop().?;

            // ii. Return ? initializeResult.
            return err;
        };
    }

    // 7. Let ctorEnv be the LexicalEnvironment of calleeContext.
    const ctor_env = callee_context.ecmascript_code.lexical_environment;

    // 8. Let result be Completion(OrdinaryCallEvaluateBody(func, argList)).
    const result = ordinaryCallEvaluateBody(agent, func, arg_list);

    // 9. Remove calleeContext from the execution context stack and restore callerContext as the
    //    running execution context.
    _ = agent.execution_context_stack.pop().?;

    // 10. If result is a throw completion, return ? result.
    // 11. Assert: result is a return completion.
    const value = try result;

    // 12. If result.[[Value]] is an Object, return result.[[Value]].
    if (value.isObject()) return value.asObject();

    // 13. If kind is base, return thisArg.
    if (kind == .base) return this_arg;

    // 14. If result.[[Value]] is not undefined, throw a TypeError exception.
    if (!value.isUndefined()) {
        return agent.throwException(
            .type_error,
            "Constructor must return an object or undefined",
            .{},
        );
    }

    // 15. Let thisBinding be ? ctorEnv.GetThisBinding().
    const this_binding = try ctor_env.getThisBinding(agent);

    // 16. Assert: thisBinding is an Object.
    std.debug.assert(this_binding.isObject());

    // 17. Return thisBinding.
    return this_binding.asObject();
}

/// 10.2.3 OrdinaryFunctionCreate ( proto, sourceText, paramList, body, thisMode, envRecord, privateEnv )
/// https://tc39.es/ecma262/#sec-ordinaryfunctioncreate
pub fn ordinaryFunctionCreate(
    agent: *Agent,
    proto: *Object,
    source_text: SourceText,
    param_list: ast.FormalParameters,
    body: ast.FunctionBody,
    this_mode: enum { lexical_this, non_lexical_this },
    env: Environment,
    private_env: ?*PrivateEnvironment,
) std.mem.Allocator.Error!*ECMAScriptFunction {
    // 7. Let strict be IsStrict(body).
    const strict = body.strict;

    // 1. Let internalSlotsList be the internal slots listed in Table 26.
    // 2. Let func be OrdinaryObjectCreate(proto, internalSlotsList).
    const func = try ECMAScriptFunction.create(agent, .{
        // 3. Set func.[[Call]] to the definition specified in 10.2.1.
        .internal_methods = internal_methods,
        .prototype = proto,
        .fields = .{
            // 4. Set func.[[SourceText]] to sourceText.
            .source_text = source_text,

            // 5. Set func.[[FormalParameters]] to paramList.
            .formal_parameters = param_list,

            // 6. Set func.[[ECMAScriptCode]] to body.
            .ecmascript_code = body,

            .flags = .{
                // 8. Set func.[[Strict]] to strict.
                .strict = strict,

                // 9. If thisMode is lexical-this, set func.[[ThisMode]] to lexical.
                // 10. Else if strict is true, set func.[[ThisMode]] to strict.
                // 11. Else, set func.[[ThisMode]] to global.
                .this_mode = switch (this_mode) {
                    .lexical_this => .lexical,
                    else => if (strict) .strict else .global,
                },

                // 12. Set func.[[IsClassConstructor]] to false.
                .is_class_constructor = false,

                // NOTE: Not in the spec but we need to provide a value
                .constructor_kind = .base,
            },

            // 13. Set func.[[Environment]] to envRecord.
            .environment = env,

            // 14. Set func.[[PrivateEnvironment]] to privateEnv.
            .private_environment = private_env,

            // 15. Set func.[[ScriptOrModule]] to GetActiveScriptOrModule().
            .script_or_module = agent.getActiveScriptOrModule().?,

            // 16. Set func.[[Realm]] to the current Realm Record.
            .realm = agent.currentRealm(),

            // 17. Set func.[[HomeObject]] to undefined.
            .home_object = null,

            // 18. Set func.[[Fields]] to a new empty List.
            // 19. Set func.[[PrivateMethods]] to a new empty List.
            // 20. Set func.[[ClassFieldInitializerName]] to empty.
            .class_data = null,

            .initial_name = null,
        },
    });

    // 21. Let length be the ExpectedArgumentCount of paramList.
    const length = param_list.expectedArgumentCount();

    // 22. Perform SetFunctionLength(func, length).
    try setFunctionLength(agent, &func.object, @floatFromInt(length));

    // 23. Return func.
    return func;
}

pub fn ordinaryFunctionCreateFast(
    agent: *Agent,
    source_text: SourceText,
    parameter_list: ast.FormalParameters,
    body: ast.FunctionBody,
    env: Environment,
    private_env: ?*PrivateEnvironment,
    name: *const String,
) std.mem.Allocator.Error!*ECMAScriptFunction {
    const length: u53 = @intCast(parameter_list.expectedArgumentCount());
    const strict = body.strict;

    const realm = agent.currentRealm();
    const function_shape, const function_offsets = try realm.shape(.ordinary_function);
    const prototype_shape, const prototype_offsets = try realm.shape(.ordinary_function_prototype);

    const func = try ECMAScriptFunction.createWithShape(agent, .{
        .shape = function_shape,
        .fields = .{
            .source_text = source_text,
            .formal_parameters = parameter_list,
            .ecmascript_code = body,
            .flags = .{
                .constructor_kind = .base,
                .this_mode = if (strict) .strict else .global,
                .strict = strict,
                .is_class_constructor = false,
            },
            .environment = env,
            .private_environment = private_env,
            .script_or_module = agent.getActiveScriptOrModule().?,
            .realm = realm,
            .home_object = null,
            .class_data = null,
            .initial_name = name,
        },
    });

    const proto = try builtins.Object.createWithShape(agent, .{ .shape = prototype_shape });
    proto.object.setValueAtPropertyOffset(prototype_offsets.constructor, Value.from(&func.object));

    func.object.setValueAtPropertyOffset(function_offsets.length, Value.from(length));
    func.object.setValueAtPropertyOffset(function_offsets.name, Value.from(name));
    func.object.setValueAtPropertyOffset(function_offsets.prototype, Value.from(&proto.object));

    return func;
}

/// 10.2.4 AddRestrictedFunctionProperties ( func, realm )
/// https://tc39.es/ecma262/#sec-addrestrictedfunctionproperties
pub fn addRestrictedFunctionProperties(
    agent: *Agent,
    func: *Object,
    realm: *Realm,
) std.mem.Allocator.Error!void {
    // 1. Assert: realm.[[Intrinsics]].[[%ThrowTypeError%]] exists and has been initialized.
    // 2. Let thrower be realm.[[Intrinsics]].[[%ThrowTypeError%]].
    const thrower = try realm.intrinsic(.throw_type_error);

    const property_desc: Object.CompletePropertyDescriptor = .{
        .value_or_accessor = .{
            .accessor = .{
                .getter = thrower,
                .setter = thrower,
            },
        },
        .attributes = .builtin_default,
    };

    // 3. Perform ! DefinePropertyOrThrow(func, "caller", PropertyDescriptor { [[Getter]]: thrower,
    //    [[Setter]]: thrower, [[Enumerable]]: false, [[Configurable]]: true }).
    try func.definePropertyDirect(
        agent,
        PropertyKey.from("caller"),
        property_desc,
    );

    // 4. Perform ! DefinePropertyOrThrow(func, "arguments", PropertyDescriptor {
    //    [[Getter]]: thrower, [[Setter]]: thrower, [[Enumerable]]: false,
    //    [[Configurable]]: true }).
    try func.definePropertyDirect(
        agent,
        PropertyKey.from("arguments"),
        property_desc,
    );

    // 5. Return unused.
}

/// 10.2.5 MakeConstructor ( func [ , writableProto [ , proto ] ] )
/// https://tc39.es/ecma262/#sec-makeconstructor
pub fn makeConstructor(
    agent: *Agent,
    func: *Object,
    args: struct {
        writable_proto: bool = true,
        proto: ?*Object = null,
    },
) std.mem.Allocator.Error!void {
    const realm = agent.currentRealm();

    // 1. If func is an ECMAScript function object, then
    if (func.is(ECMAScriptFunction)) {
        // a. Assert: IsConstructor(func) is false.
        std.debug.assert(func.internalMethods() == internal_methods);

        // b. Assert: func is an extensible object that does not have a "prototype" own property.
        std.debug.assert(
            func.extensible() and !func.containsProperty(PropertyKey.from("prototype")),
        );

        // c. Set func.[[Construct]] to the definition specified in 10.2.2.
        try func.setInternalMethods(agent, internal_methods_constructor);
    } else {
        // 2. Else,
        // NOTE: ClassDefinitionEvaluation may synthesize the default constructor for a class via
        //       CreateBuiltinFunction with a [[Construct]] internal method followed by calling
        //       MakeConstructor on it to wire up the prototype/constructor properties.
        std.debug.assert(func.internalMethods() == builtins.builtin_function.internal_methods or
            func.internalMethods() == builtins.builtin_function.internal_methods_constructor);

        // a. Set func.[[Construct]] to the definition specified in 10.3.2.
        try func.setInternalMethods(agent, builtins.builtin_function.internal_methods_constructor);
    }

    // 3. Set func.[[ConstructorKind]] to base.
    if (func.cast(ECMAScriptFunction)) |ecmascript_function| {
        ecmascript_function.fields.flags.constructor_kind = .base;
    } else if (func.cast(BuiltinFunction)) |builtin_function| {
        if (builtin_function.fields.flags.is_class_constructor) {
            const class_constructor_fields = builtin_function.fields.additionalFieldsAs(ClassConstructorFields);
            class_constructor_fields.constructor_kind = .base;
        }
    }

    // 4. If writableProto is not present, set writableProto to true.
    // NOTE: This is done via the default argument.

    // 5. If proto is not present, then
    const proto = args.proto orelse blk: {
        // a. Set proto to OrdinaryObjectCreate(%Object.prototype%).
        const proto = try ordinaryObjectCreate(agent, try realm.intrinsic(.object_prototype));

        // b. Perform ! DefinePropertyOrThrow(proto, "constructor", PropertyDescriptor {
        //    [[Value]]: func, [[Writable]]: writableProto, [[Enumerable]]: false,
        //    [[Configurable]]: true }).
        try proto.definePropertyDirect(agent, PropertyKey.from("constructor"), .{
            .value_or_accessor = .{
                .value = Value.from(func),
            },
            .attributes = .{
                .writable = args.writable_proto,
                .enumerable = false,
                .configurable = true,
            },
        });

        break :blk proto;
    };

    // 6. Perform ! DefinePropertyOrThrow(func, "prototype", PropertyDescriptor { [[Value]]: proto,
    //    [[Writable]]: writableProto, [[Enumerable]]: false, [[Configurable]]: false }).
    try func.definePropertyDirect(agent, PropertyKey.from("prototype"), .{
        .value_or_accessor = .{
            .value = Value.from(proto),
        },
        .attributes = .{
            .writable = args.writable_proto,
            .enumerable = false,
            .configurable = false,
        },
    });

    // 7. Return unused.
}

/// 10.2.6 MakeClassConstructor ( func )
/// https://tc39.es/ecma262/#sec-makeclassconstructor
pub fn makeClassConstructor(func: *ECMAScriptFunction) void {
    // 1. Assert: func.[[IsClassConstructor]] is false.
    std.debug.assert(!func.fields.flags.is_class_constructor);

    // 2. Set func.[[IsClassConstructor]] to true.
    func.fields.flags.is_class_constructor = true;

    // 3. Return unused.
}

/// 10.2.7 MakeMethod ( func, homeObj )
/// https://tc39.es/ecma262/#sec-makemethod
pub fn makeMethod(func: *ECMAScriptFunction, home_obj: *Object) void {
    // 1. Assert: homeObj is an ordinary object.
    // 2. Set func.[[HomeObject]] to homeObj.
    func.fields.home_object = home_obj;

    // 3. Return unused.
}

/// 10.2.8 DefineMethodProperty ( homeObj, name, closure, enumerable )
/// https://tc39.es/ecma262/#sec-definemethodproperty
pub fn defineMethodProperty(
    agent: *Agent,
    home_obj: *Object,
    name: PropertyKeyOrPrivateName,
    closure: *Object,
    enumerable: bool,
) Agent.Error!?PrivateMethodDefinition {
    // 1. Assert: homeObj is an ordinary, extensible object.

    switch (name) {
        .private_name => |private_name| {
            // 2. If name is a Private Name, return PrivateElement { [[Key]]: name,
            //    [[Kind]]: method, [[Value]]: closure }.
            const private_element: PrivateElement = .{ .method = closure };
            return .{ .private_name = private_name, .private_element = private_element };
        },
        .property_key => |property_key| {
            // 3. Let propertyDesc be the PropertyDescriptor { [[Value]]: closure,
            //    [[Writable]]: true, [[Enumerable]]: enumerable, [[Configurable]]: true }.
            const property_desc: PropertyDescriptor = .{
                .value = Value.from(closure),
                .writable = true,
                .enumerable = enumerable,
                .configurable = true,
            };

            // 4. Perform ? DefinePropertyOrThrow(homeObj, name, propertyDesc).
            try home_obj.definePropertyOrThrow(
                agent,
                property_key,
                property_desc,
            );

            // 5. NOTE: DefinePropertyOrThrow only returns an abrupt completion when attempting to
            //    define a class static method whose name is "prototype".

            // 6. Return empty.
            return null;
        },
    }
}

/// 10.2.9 SetFunctionName ( func, name [ , prefix ] )
/// https://tc39.es/ecma262/#sec-setfunctionname
pub fn setFunctionName(
    agent: *Agent,
    func: *Object,
    key: anytype,
    prefix: ?[]const u8,
) std.mem.Allocator.Error!void {
    comptime std.debug.assert(@TypeOf(key) == PropertyKey or @TypeOf(key) == PropertyKeyOrPrivateName);

    // 1. Assert: func is an extensible object that does not have a "name" own property.
    std.debug.assert(
        func.extensible() and !func.containsProperty(PropertyKey.from("name")),
    );

    var name: *const String = switch (if (@TypeOf(key) == PropertyKey) PropertyKeyOrPrivateName{ .property_key = key } else key) {
        .property_key => |property_key| switch (try property_key.toStringOrSymbol(agent)) {
            .string => |string| string,

            // 2. If name is a Symbol, then
            .symbol => |symbol| blk: {
                // a. Let description be name.[[Description]].
                const description = symbol.description orelse {
                    // b. If description is undefined, set name to the empty String.
                    break :blk .empty;
                };

                // c. Else, set name to the string-concatenation of "[", description, and "]".
                break :blk try String.concat(agent, &.{
                    String.fromLiteral("["),
                    description,
                    String.fromLiteral("]"),
                });
            },
        },
        // 3. Else if name is a Private Name, then
        .private_name => |private_name| blk: {
            // a. Set name to name.[[Description]].
            break :blk private_name.symbol.description.?;
        },
    };

    // 4. Let initialName be name.
    var initial_name = name;

    // 5. If prefix is present, then
    if (prefix != null) {
        // a. Let prefixedName be the string-concatenation of prefix, the code unit 0x0020 (SPACE),
        //    and name.
        const prefixed_name = try String.concat(agent, &.{
            try String.fromAscii(agent, prefix.?),
            String.fromLiteral(" "),
            name,
        });

        // b. Set initialName to prefixedName.
        initial_name = prefixed_name;

        // Normative Optional, Legacy
        // c. Set initialName to an implementation-defined choice of either name or prefixedName.

        // d. Set name to prefixedName.
        name = prefixed_name;
    }

    // 6. If func has an [[InitialName]] internal slot, set func.[[InitialName]] to initialName.
    if (func.cast(BuiltinFunction)) |builtin_function| {
        builtin_function.fields.initial_name = initial_name;
    } else if (func.cast(ECMAScriptFunction)) |ecmascript_function| {
        ecmascript_function.fields.initial_name = initial_name;
    }

    // 7. Perform ! DefinePropertyOrThrow(func, "name", PropertyDescriptor { [[Value]]: name,
    //    [[Writable]]: false, [[Enumerable]]: false, [[Configurable]]: true }).
    try func.definePropertyDirect(agent, PropertyKey.from("name"), .{
        .value_or_accessor = .{
            .value = Value.from(name),
        },
        .attributes = .{
            .writable = false,
            .enumerable = false,
            .configurable = true,
        },
    });

    // 8. Return unused.
}

/// 10.2.10 SetFunctionLength ( func, length )
/// https://tc39.es/ecma262/#sec-setfunctionlength
pub fn setFunctionLength(agent: *Agent, func: *Object, length: f64) std.mem.Allocator.Error!void {
    std.debug.assert(
        std.math.isPositiveInf(length) or
            (std.math.isFinite(length) and std.math.trunc(length) == length and length >= 0),
    );

    // 1. Assert: func is an extensible object that does not have a "length" own property.
    std.debug.assert(
        func.extensible() and !func.containsProperty(PropertyKey.from("length")),
    );

    // 2. Perform ! DefinePropertyOrThrow(func, "length", PropertyDescriptor { [[Value]]: 𝔽(length),
    //    [[Writable]]: false, [[Enumerable]]: false, [[Configurable]]: true }).
    try func.definePropertyDirect(agent, PropertyKey.from("length"), .{
        .value_or_accessor = .{
            .value = Value.from(length),
        },
        .attributes = .{
            .writable = false,
            .enumerable = false,
            .configurable = true,
        },
    });

    // 3. Return unused.
}
