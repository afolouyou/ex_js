const std = @import("std");

const build_options = @import("build-options");

const ast = @import("../language/ast.zig");
const execution = @import("../execution.zig");
const interpreter = @import("../interpreter.zig");
const language = @import("../language.zig");
const types = @import("../types.zig");
const utils = @import("../utils.zig");

const Agent = execution.Agent;
const Diagnostics = language.Diagnostics;
const Environment = execution.Environment;
const ExecutionContext = execution.ExecutionContext;
const Parser = language.Parser;
const PrivateEnvironment = execution.PrivateEnvironment;
const String = types.String;
const Value = types.Value;
const instantiateAsyncFunctionObject = language.instantiateAsyncFunctionObject;
const instantiateAsyncGeneratorFunctionObject = language.instantiateAsyncGeneratorFunctionObject;
const instantiateGeneratorFunctionObject = language.instantiateGeneratorFunctionObject;
const instantiateOrdinaryFunctionObject = language.instantiateOrdinaryFunctionObject;
const newDeclarativeEnvironment = execution.newDeclarativeEnvironment;
const noexcept = utils.noexcept;

/// 19.2.1.1 PerformEval ( source, strictCaller, direct )
/// https://tc39.es/ecma262/#sec-performeval
pub fn performEval(
    agent: *Agent,
    source: Value,
    strict_caller: bool,
    direct: bool,
) Agent.Error!Value {
    const gpa = agent.gpa;

    // 1. Assert: If direct is false, then strictCaller is also false.
    if (!direct) std.debug.assert(!strict_caller);

    // 2. If source is not a String, return source.
    if (!source.isString()) return source;

    // 3. Let evalRealm be the current Realm Record.
    // 4. NOTE: In the case of a direct eval, evalRealm is the realm of both the caller of `eval`
    //    and of the `eval` function itself.
    const eval_realm = agent.currentRealm();

    // 5. Perform ? HostEnsureCanCompileStrings(evalRealm, « », source, direct).
    try agent.host_hooks.hostEnsureCanCompileStrings(eval_realm, &.{}, source.asString(), direct);

    // 6. Let inFunc be false.
    var in_func = false;

    // 7. Let inMethod be false.
    var in_method = false;

    // 8. Let inDerivedCtor be false.
    var in_derived_ctor = false;

    // 9. Let inClassFieldInitializer be false.
    var in_class_field_initializer = false;

    // 10. If direct is true, then
    if (direct) {
        // a. Let thisEnvRecord be GetThisEnvironment().
        const this_env = agent.getThisEnvironment();

        // b. If thisEnvRecord is a Function Environment Record, then
        if (this_env == .function_environment) {
            // i. Let func be thisEnvRecord.[[FunctionObject]].
            const func = this_env.function_environment.function_object;

            // ii. Set inFunc to true.
            in_func = true;

            // iii. Set inMethod to thisEnvRecord.HasSuperBinding().
            in_method = this_env.hasSuperBinding();

            // iv. If func.[[ConstructorKind]] is derived, set inDerivedCtor to true.
            in_derived_ctor = func.fields.flags.constructor_kind == .derived;

            // v. Let classFieldInitializerName be func.[[ClassFieldInitializerName]].
            const class_field_initializer_name = if (func.fields.class_data) |class_data|
                class_data.class_field_initializer_name
            else
                null;

            // vi. If classFieldInitializerName is not empty, set inClassFieldInitializer to true.
            if (class_field_initializer_name != null) in_class_field_initializer = true;
        }
    }

    // 11. Perform the following substeps in an implementation-defined order, possibly interleaving
    //     parsing and error detection:

    const source_wtf8 = try source.asString().toWtf8(gpa);
    defer gpa.free(source_wtf8);
    // Stored in ExecutionContext.origin, must be GC'd
    const source_text = try agent.gc_allocator.dupeSentinel(u8, source_wtf8, 0);

    var diagnostics: Diagnostics = .init(gpa, .{
        .source = source_text,
        .file_name = "eval",
    });
    defer diagnostics.deinit();

    // a. Let script be ParseText(source, Script).
    const script = Parser.parse(ast.Script, agent.gc_allocator, source_text, .{
        .diagnostics = &diagnostics,
        .state = .{
            // e-g.
            .in_strict_mode = strict_caller,
            .new_target_allowed = in_func,
            .in_method_definition = in_method,
            // TODO: The state should track whether we're in a *derived* constructor
            .in_class_constructor = in_derived_ctor,
            // h. If inClassFieldInitializer is true and ContainsArguments of body is true, throw
            //    a SyntaxError exception.
            .arguments_disallowed = in_class_field_initializer,
        },
    }) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        error.ParseError => {
            // b. If script is a List of errors, throw a SyntaxError exception.
            const parse_error = diagnostics.first().?;
            return agent.throwException(.syntax_error, "{f}", .{parse_error.fmt(&diagnostics)});
        },
    };

    // c. If script Contains ScriptBody is false, return undefined.
    if (script.statement_list.items.len == 0) return .undefined;

    // d. Let body be the ScriptBody of script.
    const body = script;

    // 12. If strictCaller is true, let strictEval be true.
    // 13. Else, let strictEval be ScriptIsStrict of script.
    const strict_eval = strict_caller or script.scriptIsStrict();

    // 14. Let runningContext be the running execution context.
    // 15. NOTE: If direct is true, runningContext will be the execution context that performed the
    //     direct eval. If direct is false, runningContext will be the execution context for the
    //     invocation of the `eval` function.
    const running_context = agent.runningExecutionContext();

    var lexical_env: Environment = undefined;
    var variable_env: Environment = undefined;
    var private_env: ?*PrivateEnvironment = undefined;

    // 16. If direct is true, then
    if (direct) {
        // a. Let lexicalEnv be NewDeclarativeEnvironment(runningContext's LexicalEnvironment).
        lexical_env = .{
            .declarative_environment = try newDeclarativeEnvironment(
                agent.gc_allocator,
                running_context.ecmascript_code.lexical_environment,
            ),
        };

        // b. Let variableEnv be runningContext's VariableEnvironment.
        variable_env = running_context.ecmascript_code.variable_environment;

        // c. Let privateEnv be runningContext's PrivateEnvironment.
        private_env = running_context.ecmascript_code.private_environment;
    } else {
        // 17. Else,
        // a. Let lexicalEnv be NewDeclarativeEnvironment(evalRealm.[[GlobalEnv]]).
        lexical_env = .{
            .declarative_environment = try newDeclarativeEnvironment(
                agent.gc_allocator,
                .{ .global_environment = eval_realm.global_env },
            ),
        };

        // b. Let variableEnv be evalRealm.[[GlobalEnv]].
        variable_env = .{ .global_environment = eval_realm.global_env };

        // c. Let privateEnv be null.
        private_env = null;
    }

    // 18. If strictEval is true, set variableEnv to lexicalEnv.
    if (strict_eval) variable_env = lexical_env;

    // 19. If runningContext is not already suspended, suspend runningContext.

    // 20. Let evalContext be a new ECMAScript code execution context.
    var eval_context: ExecutionContext = .{
        // 21. Set evalContext's Function to null.
        .origin = .{ .eval = source_text },

        // 22. Set evalContext's Realm to evalRealm.
        .realm = eval_realm,

        // 23. Set evalContext's ScriptOrModule to runningContext's ScriptOrModule.
        .script_or_module = running_context.script_or_module,

        .ecmascript_code = .{
            // 24. Set evalContext's VariableEnvironment to variableEnv.
            .variable_environment = variable_env,

            // 25. Set evalContext's LexicalEnvironment to lexicalEnv.
            .lexical_environment = lexical_env,

            // 26. Set evalContext's PrivateEnvironment to privateEnv.
            .private_environment = private_env,
        },
    };

    // 27. Push evalContext onto the execution context stack; evalContext is now the running
    //     execution context.
    try agent.execution_context_stack.append(agent.gc_allocator, &eval_context);

    // 28. Let result be Completion(EvalDeclarationInstantiation(body, variableEnv, lexicalEnv,
    //     privateEnv, strictEval)).
    const result_no_value = evalDeclarationInstantiation(
        agent,
        body,
        variable_env,
        lexical_env,
        private_env,
        strict_eval,
        source_text,
    );

    // 29. If result is a normal completion, then
    const result: Agent.Error!Value = if (result_no_value) |_| blk: {
        // a. Set result to Completion(Evaluation of body).
        // 30. If result is a normal completion and result.[[Value]] is empty, then
        if (interpreter.compileAndRun(
            agent,
            .{ .eval = .{ .script = &body, .strict = strict_eval } },
            "<eval>",
        )) |value|
            // a. Set result to NormalCompletion(undefined).
            break :blk value orelse .undefined
        else |err|
            break :blk err;
    } else |err| err;

    // 31. Suspend evalContext and remove it from the execution context stack.
    _ = agent.execution_context_stack.pop().?;

    // 32. Resume the context that is now on the top of the execution context stack as the running
    //     execution context.

    // 33. Return ? result.
    return result;
}

/// 19.2.1.3 EvalDeclarationInstantiation ( body, variableEnv, lexicalEnv, privateEnv, strict )
/// https://tc39.es/ecma262/#sec-evaldeclarationinstantiation
fn evalDeclarationInstantiation(
    agent: *Agent,
    body: ast.Script,
    variable_env: Environment,
    lexical_env: Environment,
    private_env: ?*PrivateEnvironment,
    strict: bool,
    source: []const u8,
) Agent.Error!void {
    // 1. Let variableNames be the VarDeclaredNames of body.
    var variable_names: std.ArrayList(ast.Identifier) = .empty;
    defer variable_names.deinit(agent.gc_allocator);
    try body.collectVarDeclaredNames(agent.gc_allocator, &variable_names);

    // 2. Let variableDecls be the VarScopedDeclarations of body.
    var variable_decls: std.ArrayList(ast.VarScopedDeclaration) = .empty;
    defer variable_decls.deinit(agent.gc_allocator);
    try body.collectVarScopedDeclarations(agent.gc_allocator, &variable_decls);

    // 3. If strict is false, then
    if (!strict) {
        // a. If variableEnv is a Global Environment Record, then
        if (variable_env == .global_environment) {
            // i. For each element name of variableNames, do
            for (variable_names.items) |name_utf8| {
                const name = try String.fromUtf8(agent, name_utf8);

                // 1. If HasLexicalDeclaration(variableEnv, name) is true, throw a SyntaxError
                //    exception.
                if (variable_env.global_environment.hasLexicalDeclaration(name)) {
                    return agent.throwException(
                        .syntax_error,
                        "Global environment already has a lexical declaration '{f}'",
                        .{name.fmtRaw()},
                    );
                }

                // 2. NOTE: `eval` will not create a global var declaration that would be shadowed
                //    by a global lexical declaration.
            }
        }

        // b. Let thisEnv be lexicalEnv.
        var this_env = lexical_env;

        // c. Assert: The following loop will terminate.
        // d. Repeat, while thisEnv and variableEnv are not the same Environment Record,
        while (!std.meta.eql(this_env, variable_env)) {
            // i. If thisEnv is not an Object Environment Record, then
            if (this_env != .object_environment) {
                // 1. NOTE: The environment of with statements cannot contain any lexical
                //    declaration so it doesn't need to be checked for var/let hoisting conflicts.

                // 2. For each element name of variableNames, do
                for (variable_names.items) |name_utf8| {
                    const name = try String.fromUtf8(agent, name_utf8);

                    // a. If ! thisEnv.HasBinding(name) is true, then
                    if (this_env.hasBinding(agent, name) catch |err| try noexcept(err)) {
                        // i. If the host is a web browser or otherwise supports VariableStatements
                        //    in Catch Blocks, then
                        //     1. If thisEnv is not the Environment Record for a Catch clause, throw
                        //        a SyntaxError exception.
                        // ii. Else,
                        //     1. Throw a SyntaxError exception.
                        if (!build_options.enable_annex_b or
                            this_env != .declarative_environment or
                            !this_env.declarative_environment.is_catch_env)
                        {
                            return agent.throwException(
                                .syntax_error,
                                "Var declaration '{f}' is also lexically declared",
                                .{name.fmtRaw()},
                            );
                        }
                    }

                    // b. NOTE: A direct eval will not hoist var declaration over a like-named
                    //    lexical declaration.
                }
            }

            // ii. Set thisEnv to thisEnv.[[OuterEnv]].
            this_env = this_env.outerEnv().?;
        }
    }

    // TODO: 4-7.

    // 8. Let funcsToInitialize be a new empty List.
    var funcs_to_initialize: std.ArrayList(ast.HoistableDeclaration) = .empty;
    defer funcs_to_initialize.deinit(agent.gc_allocator);

    // 9. Let declaredFuncNames be a new empty List.
    var declared_func_names: String.HashMap(void) = .empty;
    defer declared_func_names.deinit(agent.gc_allocator);

    // 10. For each element variableDecl of variableDecls, in reverse List order, do
    var it = std.mem.reverseIterator(variable_decls.items);
    while (it.next()) |variable_decl| {
        // a. If variableDecl is not either a VariableDeclaration, a ForBinding, or a
        //    BindingIdentifier, then
        if (variable_decl == .hoistable_declaration) {
            // i. Assert: variableDecl is either a FunctionDeclaration, a GeneratorDeclaration, an
            //    AsyncFunctionDeclaration, or an AsyncGeneratorDeclaration.
            const hoistable_decl = variable_decl.hoistable_declaration;

            // ii. NOTE: If there are multiple function declarations for the same name, the last
            //     declaration is used.

            // iii. Let funcName be the sole element of the BoundNames of variableDecl.
            const func_name = switch (hoistable_decl) {
                inline else => |func_decl| try String.fromUtf8(agent, func_decl.identifier.?),
            };

            // iv. If declaredFuncNames does not contain funcName, then
            if (!declared_func_names.contains(func_name)) {
                // 1. If variableEnv is a Global Environment Record, then
                if (variable_env == .global_environment) {
                    // a. Let funcDefinable be ? CanDeclareGlobalFunction(variableEnv, funcName).
                    const func_definable = try variable_env.global_environment.canDeclareGlobalFunction(
                        agent,
                        func_name,
                    );

                    // b. If funcDefinable is false, throw a TypeError exception.
                    if (!func_definable) {
                        return agent.throwException(
                            .type_error,
                            "Cannot declare '{f}' in global environment",
                            .{func_name.fmtRaw()},
                        );
                    }
                }

                // 2. Append funcName to declaredFuncNames.
                try declared_func_names.putNoClobber(agent.gc_allocator, func_name, {});

                // 3. Insert variableDecl as the first element of funcsToInitialize.
                // NOTE: AFAICT the order isn't observable, so we can append.
                try funcs_to_initialize.append(agent.gc_allocator, hoistable_decl);
            }
        }
    }

    // 11. Let declaredVariableNames be a new empty List.
    var declared_variable_names: String.HashMap(void) = .empty;
    defer declared_variable_names.deinit(agent.gc_allocator);

    var bound_names: std.ArrayList(ast.Identifier) = .empty;
    defer bound_names.deinit(agent.gc_allocator);

    // 12. For each element variableDecl of variableDecls, do
    for (variable_decls.items) |variable_decl| {
        // a. If variableDecl is either a VariableDeclaration, a ForBinding, or a BindingIdentifier,
        //    then
        if (variable_decl == .variable_declaration) {
            bound_names.clearRetainingCapacity();
            try variable_decl.variable_declaration.collectBoundNames(agent.gc_allocator, &bound_names);

            // i. For each String name of the BoundNames of variableDecl, do
            for (bound_names.items) |name_utf8| {
                const name = try String.fromUtf8(agent, name_utf8);

                // 1. If declaredFuncNames does not contain name, then
                if (!declared_func_names.contains(name)) {
                    // a. If variableEnv is a Global Environment Record, then
                    if (variable_env == .global_environment) {
                        // i. Let variableDefinable be ? CanDeclareGlobalVar(variableEnv, name).
                        const variable_definable = try variable_env.global_environment.canDeclareGlobalVar(
                            agent,
                            name,
                        );

                        // ii. If variableDefinable is false, throw a TypeError exception.
                        if (!variable_definable) {
                            return agent.throwException(
                                .type_error,
                                "Cannot declare '{f}' in global environment",
                                .{name.fmtRaw()},
                            );
                        }
                    }

                    // b. If declaredVariableNames does not contain name, then
                    if (!declared_variable_names.contains(name)) {
                        // i. Append name to declaredVariableNames.
                        try declared_variable_names.putNoClobber(agent.gc_allocator, name, {});
                    }
                }
            }
        }
    }

    // 13. If strict is false and the host is a web browser or otherwise supports Block-Level
    //     Function Declarations Web Legacy Compatibility Semantics, then
    //     [...]

    // 14. NOTE: No abnormal terminations occur after this algorithm step unless variableEnv is a
    //     Global Environment Record and the global object is a Proxy exotic object.

    // 15. Let lexicalDecls be the LexicallyScopedDeclarations of body.
    var lexical_decls: std.ArrayList(ast.LexicallyScopedDeclaration) = .empty;
    defer lexical_decls.deinit(agent.gc_allocator);
    try body.collectLexicallyScopedDeclarations(agent.gc_allocator, &lexical_decls);

    // 16. For each element lexicalDecl of lexicalDecls, do
    for (lexical_decls.items) |lexical_decl| {
        // a. NOTE: Lexically declared names are only instantiated here but not initialized.

        bound_names.clearRetainingCapacity();
        try lexical_decl.collectBoundNames(agent.gc_allocator, &bound_names);

        // b. For each element name of the BoundNames of lexicalDecl, do
        for (bound_names.items) |name_utf8| {
            const name = try String.fromUtf8(agent, name_utf8);

            // i. If IsConstantDeclaration of lexicalDecl is true, then
            if (lexical_decl.isConstantDeclaration()) {
                // 1. Perform ? lexicalEnv.CreateImmutableBinding(name, true).
                try lexical_env.createImmutableBinding(agent, name, true);
            } else {
                // ii. Else,
                // 1. Perform ? lexicalEnv.CreateMutableBinding(name, false).
                try lexical_env.createMutableBinding(agent, name, false);
            }
        }
    }

    // 17. For each Parse Node funcDecl of funcsToInitialize, do
    for (funcs_to_initialize.items) |hoistable_decl| {
        // a. Let funcName be the sole element of the BoundNames of funcDecl.
        const func_name = switch (hoistable_decl) {
            inline else => |func_decl| try String.fromUtf8(agent, func_decl.identifier.?),
        };

        // b. Let funcObj be InstantiateFunctionObject of funcDecl with arguments lexicalEnv and
        //    privateEnv.
        const func_obj = try switch (hoistable_decl) {
            .function_declaration => |func_decl| instantiateOrdinaryFunctionObject(agent, func_decl, lexical_env, private_env, source),
            .generator_declaration => |gen_decl| instantiateGeneratorFunctionObject(agent, gen_decl, lexical_env, private_env, source),
            .async_function_declaration => |async_func_decl| instantiateAsyncFunctionObject(agent, async_func_decl, lexical_env, private_env, source),
            .async_generator_declaration => |async_gen_decl| instantiateAsyncGeneratorFunctionObject(agent, async_gen_decl, lexical_env, private_env, source),
        };

        // c. If variableEnv is a Global Environment Record, then
        if (variable_env == .global_environment) {
            // i. Perform ? CreateGlobalFunctionBinding(variableEnv, funcName, funcObj, true).
            try variable_env.global_environment.createGlobalFunctionBinding(
                agent,
                func_name,
                func_obj,
                true,
            );
        } else {
            // d. Else,
            // i. Let bindingExists be ! variableEnv.HasBinding(funcName).
            const binding_exists = variable_env.hasBinding(
                agent,
                func_name,
            ) catch |err| try noexcept(err);

            // ii. If bindingExists is false, then
            if (!binding_exists) {
                // 1. NOTE: The following invocation cannot return an abrupt completion because of
                //    the validation preceding step 14.

                // 2. Perform ! variableEnv.CreateMutableBinding(funcName, true).
                variable_env.createMutableBinding(
                    agent,
                    func_name,
                    true,
                ) catch |err| try noexcept(err);

                // 3. Perform ! variableEnv.InitializeBinding(funcName, funcObj).
                variable_env.initializeBinding(
                    agent,
                    func_name,
                    Value.from(&func_obj.object),
                ) catch |err| try noexcept(err);
            } else {
                // iii. Else,
                // 1. Perform ! variableEnv.SetMutableBinding(funcName, funcObj, false).
                variable_env.setMutableBinding(
                    agent,
                    func_name,
                    Value.from(&func_obj.object),
                    false,
                ) catch |err| try noexcept(err);
            }
        }
    }

    // 18. For each String variableName of declaredVariableNames, do
    var it_ = declared_variable_names.keyIterator();
    while (it_.next()) |ptr| {
        const variable_name = ptr.*;

        // a. If variableEnv is a Global Environment Record, then
        if (variable_env == .global_environment) {
            // i. Perform ? CreateGlobalVarBinding(variableEnv, variableName, true).
            try variable_env.global_environment.createGlobalVarBinding(agent, variable_name, true);
        } else {
            // b. Else,
            // i. Let bindingExists be ! variableEnv.HasBinding(variableName).
            const binding_exists = variable_env.hasBinding(
                agent,
                variable_name,
            ) catch |err| try noexcept(err);

            // ii. If bindingExists is false, then
            if (!binding_exists) {
                // 1. NOTE: The following invocation cannot return an abrupt completion because of
                //    the validation preceding step 14.
                // 2. Perform ! variableEnv.CreateMutableBinding(variableName, true).
                variable_env.createMutableBinding(agent, variable_name, true) catch |err| try noexcept(err);

                // 3. Perform ! variableEnv.InitializeBinding(variableName, undefined).
                variable_env.initializeBinding(agent, variable_name, .undefined) catch |err| try noexcept(err);
            }
        }
    }

    // 19. Return unused.
}
