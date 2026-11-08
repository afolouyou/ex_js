//! 16.1.4 Script Records
//! https://tc39.es/ecma262/#sec-script-records

const std = @import("std");

const ast = @import("ast.zig");
const ast_printing = @import("ast_printing.zig");
const execution = @import("../execution.zig");
const interpreter = @import("../interpreter.zig");
const language = @import("../language.zig");
const types = @import("../types.zig");

const Agent = execution.Agent;
const ExecutionContext = execution.ExecutionContext;
const GlobalEnvironment = execution.GlobalEnvironment;
const Module = language.Module;
const ModuleRequest = language.ModuleRequest;
const Parser = language.Parser;
const Realm = execution.Realm;
const String = types.String;
const Value = types.Value;
const instantiateAsyncFunctionObject = language.instantiateAsyncFunctionObject;
const instantiateAsyncGeneratorFunctionObject = language.instantiateAsyncGeneratorFunctionObject;
const instantiateGeneratorFunctionObject = language.instantiateGeneratorFunctionObject;
const instantiateOrdinaryFunctionObject = language.instantiateOrdinaryFunctionObject;

const Script = @This();

/// [[Realm]]
realm: *Realm,

/// [[ECMAScriptCode]]
ecmascript_code: ast.Script,

/// [[LoadedModules]]
loaded_modules: ModuleRequest.HashMap(Module),

/// [[HostDefined]]
host_defined: ?*anyopaque,

source: []const u8,

pub fn print(self: Script, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try ast_printing.printScript(self.ecmascript_code, writer, 0);
}

/// 16.1.5 ParseScript ( sourceText, realm, hostDefined )
/// https://tc39.es/ecma262/#sec-parse-script
pub fn parse(
    source_text: []const u8,
    realm: *Realm,
    host_defined: ?*anyopaque,
    options: Parser.Options,
) Parser.Error!*Script {
    const agent = realm.agent;

    const source = try agent.gc_allocator.dupeSentinel(u8, source_text, 0);

    // 1. Let script be ParseText(sourceText, Script).
    // 2. If script is a List of errors, return script.
    const script = try Parser.parse(ast.Script, agent.gc_allocator, source, options);

    // 3. Return Script Record { [[Realm]]: realm, [[ECMAScriptCode]]: script,
    //    [[LoadedModules]]: « », [[HostDefined]]: hostDefined }.
    const self = try agent.gc_allocator.create(Script);
    self.* = .{
        .realm = realm,
        .ecmascript_code = script,
        .loaded_modules = .empty,
        .host_defined = host_defined,
        .source = source,
    };
    return self;
}

/// 16.1.6 ScriptEvaluation ( scriptRecord )
/// https://tc39.es/ecma262/#sec-runtime-semantics-scriptevaluation
pub fn evaluate(self: *Script, name: []const u8) Agent.Error!Value {
    const agent = self.realm.agent;

    // 1. Let globalEnv be scriptRecord.[[Realm]].[[GlobalEnv]].
    const global_env = self.realm.global_env;

    // 2. Let scriptContext be a new ECMAScript code execution context.
    var script_context: ExecutionContext = .{
        // 3. Set the Function of scriptContext to null.
        .origin = .script,

        // 4. Set the Realm of scriptContext to scriptRecord.[[Realm]].
        .realm = self.realm,

        // 5. Set the ScriptOrModule of scriptContext to scriptRecord.
        .script_or_module = .{ .script = self },

        .ecmascript_code = .{
            // 6. Set the VariableEnvironment of scriptContext to globalEnv.
            .variable_environment = .{ .global_environment = global_env },

            // 7. Set the LexicalEnvironment of scriptContext to globalEnv.
            .lexical_environment = .{ .global_environment = global_env },

            // 8. Set the PrivateEnvironment of scriptContext to null.
            .private_environment = null,
        },
    };

    // 9. Suspend the running execution context.

    // 10. Push scriptContext onto the execution context stack; scriptContext is now the running
    //     execution context.
    try agent.execution_context_stack.append(agent.gc_allocator, &script_context);

    // 11. Let scriptNode be scriptRecord.[[ECMAScriptCode]].
    const script = self.ecmascript_code;

    // 12. Let result be Completion(GlobalDeclarationInstantiation(scriptNode, globalEnv)).
    const result_no_value = globalDeclarationInstantiation(agent, script, global_env, self.source);

    // 13. If result is a normal completion, then
    const result: Agent.Error!Value = if (result_no_value) |_| blk: {
        // a. Set result to Completion(Evaluation of scriptNode).
        // b. If result is a normal completion and result.[[Value]] is empty, then
        if (interpreter.compileAndRun(agent, .{ .script = &script }, name)) |value|
            // i. Set result to NormalCompletion(undefined).
            break :blk value orelse .undefined
        else |err|
            break :blk err;
    } else |err| err;

    // 14. Suspend scriptContext and remove it from the execution context stack.
    _ = agent.execution_context_stack.pop().?;

    // 15. Assert: The execution context stack is not empty.
    std.debug.assert(agent.execution_context_stack.items.len > 0);

    // 16. Resume the context that is now on the top of the execution context stack as the running
    //     execution context.

    // 17. Return ? result.
    return try result;
}

/// 16.1.7 GlobalDeclarationInstantiation ( script, envRecord )
/// https://tc39.es/ecma262/#sec-globaldeclarationinstantiation
pub fn globalDeclarationInstantiation(
    agent: *Agent,
    script: ast.Script,
    env: *GlobalEnvironment,
    source: []const u8,
) Agent.Error!void {
    // 1. Let lexicalNames be the LexicallyDeclaredNames of script.
    var lexical_names: std.ArrayList(ast.Identifier) = .empty;
    defer lexical_names.deinit(agent.gc_allocator);
    try script.collectLexicallyDeclaredNames(agent.gc_allocator, &lexical_names);

    // 2. Let variableNames be the VarDeclaredNames of script.
    var variable_names: std.ArrayList(ast.Identifier) = .empty;
    defer variable_names.deinit(agent.gc_allocator);
    try script.collectVarDeclaredNames(agent.gc_allocator, &variable_names);

    // 3. For each element name of lexicalNames, do
    for (lexical_names.items) |name_utf8| {
        const name = try String.fromUtf8(agent, name_utf8);

        // a. If HasLexicalDeclaration(envRecord, name) is true, throw a SyntaxError exception.
        if (env.hasLexicalDeclaration(name)) {
            return agent.throwException(
                .syntax_error,
                "Global environment already has a lexical declaration '{f}'",
                .{name.fmtRaw()},
            );
        }

        // b. Let hasRestrictedGlobal be ? HasRestrictedGlobalProperty(envRecord, name).
        const has_restricted_global = try env.hasRestrictedGlobalProperty(agent, name);

        // c. NOTE: Global `var` and `function` bindings (except those that are introduced by
        //    non-strict direct eval) are non-configurable and are therefore restricted global
        //    properties.

        // d. If hasRestrictedGlobal is true, throw a SyntaxError exception.
        if (has_restricted_global) {
            return agent.throwException(
                .syntax_error,
                "Global object already has a non-configurable property '{f}'",
                .{name.fmtRaw()},
            );
        }
    }

    // 4. For each element name of variableNames, do
    for (variable_names.items) |name_utf8| {
        const name = try String.fromUtf8(agent, name_utf8);

        // a. If HasLexicalDeclaration(envRecord, name) is true, throw a SyntaxError exception.
        if (env.hasLexicalDeclaration(name)) {
            return agent.throwException(
                .syntax_error,
                "Global environment already has a lexical declaration '{f}'",
                .{name.fmtRaw()},
            );
        }
    }

    // 5. Let variableDecls be the VarScopedDeclarations of script.
    var variable_decls: std.ArrayList(ast.VarScopedDeclaration) = .empty;
    defer variable_decls.deinit(agent.gc_allocator);
    try script.collectVarScopedDeclarations(agent.gc_allocator, &variable_decls);

    // 6. Let funcsToInitialize be a new empty List.
    var funcs_to_initialize: std.ArrayList(ast.HoistableDeclaration) = .empty;
    defer funcs_to_initialize.deinit(agent.gc_allocator);

    // 7. Let declaredFuncNames be a new empty List.
    var declared_func_names: String.HashMap(void) = .empty;
    defer declared_func_names.deinit(agent.gc_allocator);

    // 8. For each element variableDecl of variableDecls, in reverse List order, do
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
                // 1. Let funcDefinable be ? CanDeclareGlobalFunction(envRecord, funcName).
                const func_definable = try env.canDeclareGlobalFunction(agent, func_name);

                // 2. If funcDefinable is false, throw a TypeError exception.
                if (!func_definable) {
                    return agent.throwException(
                        .type_error,
                        "Cannot declare '{f}' in global environment",
                        .{func_name.fmtRaw()},
                    );
                }

                // 3. Append funcName to declaredFuncNames.
                try declared_func_names.putNoClobber(agent.gc_allocator, func_name, {});

                // 4. Insert variableDecl as the first element of funcsToInitialize.
                // NOTE: AFAICT the order isn't observable, so we can append.
                try funcs_to_initialize.append(agent.gc_allocator, hoistable_decl);
            }
        }
    }

    // 9. Let declaredVariableNames be a new empty List.
    var declared_variable_names: String.HashMap(void) = .empty;
    defer declared_variable_names.deinit(agent.gc_allocator);

    var bound_names: std.ArrayList(ast.Identifier) = .empty;
    defer bound_names.deinit(agent.gc_allocator);

    // 10. For each element variableDecl of variableDecls, do
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
                    // a. Let variableDefinable be ? CanDeclareGlobalVar(envRecord, name).
                    const variable_definable = try env.canDeclareGlobalVar(agent, name);

                    // b. If variableDefinable is false, throw a TypeError exception.
                    if (!variable_definable) {
                        return agent.throwException(
                            .type_error,
                            "Cannot declare '{f}' in global environment",
                            .{name.fmtRaw()},
                        );
                    }

                    // c. If declaredVariableNames does not contain name, then
                    if (!declared_variable_names.contains(name)) {
                        // i. Append name to declaredVariableNames.
                        try declared_variable_names.putNoClobber(agent.gc_allocator, name, {});
                    }
                }
            }
        }
    }

    // 11. NOTE: No abnormal terminations occur after this algorithm step if the global object is an
    //     ordinary object. However, if the global object is a Proxy exotic object it may exhibit
    //     behaviours that cause abnormal terminations in some of the following steps.

    // 12. If the host is a web browser or otherwise supports Block-Level Function Declarations Web
    //     Legacy Compatibility Semantics, then
    //     [...]

    // 13. Let lexicalDecls be the LexicallyScopedDeclarations of script.
    var lexical_decls: std.ArrayList(ast.LexicallyScopedDeclaration) = .empty;
    defer lexical_decls.deinit(agent.gc_allocator);
    try script.collectLexicallyScopedDeclarations(agent.gc_allocator, &lexical_decls);

    // 14. Let privateEnv be null.
    const private_env = null;

    // 15. For each element lexicalDecl of lexicalDecls, do
    for (lexical_decls.items) |lexical_decl| {
        // a. NOTE: Lexically declared names are only instantiated here but not initialized.

        bound_names.clearRetainingCapacity();
        try lexical_decl.collectBoundNames(agent.gc_allocator, &bound_names);

        // b. For each element name of the BoundNames of lexicalDecl, do
        for (bound_names.items) |name_utf8| {
            const name = try String.fromUtf8(agent, name_utf8);

            // i. If IsConstantDeclaration of lexicalDecl is true, then
            if (lexical_decl.isConstantDeclaration()) {
                // 1. Perform ? envRecord.CreateImmutableBinding(name, true).
                try env.createImmutableBinding(agent, name, true);
            } else {
                // ii. Else,
                // 1. Perform ? envRecord.CreateMutableBinding(name, false).
                try env.createMutableBinding(agent, name, false);
            }
        }
    }

    // 16. For each Parse Node funcDecl of funcsToInitialize, do
    for (funcs_to_initialize.items) |hoistable_decl| {
        // a. Let funcName be the sole element of the BoundNames of funcDecl.
        const func_name = switch (hoistable_decl) {
            inline else => |func_decl| try String.fromUtf8(agent, func_decl.identifier.?),
        };

        // b. Let funcObj be InstantiateFunctionObject of funcDecl with arguments envRecord and
        //    privateEnv.
        const func_obj = try switch (hoistable_decl) {
            .function_declaration => |func_decl| instantiateOrdinaryFunctionObject(agent, func_decl, .{ .global_environment = env }, private_env, source),
            .generator_declaration => |gen_decl| instantiateGeneratorFunctionObject(agent, gen_decl, .{ .global_environment = env }, private_env, source),
            .async_function_declaration => |async_func_decl| instantiateAsyncFunctionObject(agent, async_func_decl, .{ .global_environment = env }, private_env, source),
            .async_generator_declaration => |async_gen_decl| instantiateAsyncGeneratorFunctionObject(agent, async_gen_decl, .{ .global_environment = env }, private_env, source),
        };

        // c. Perform ? CreateGlobalFunctionBinding(envRecord, funcName, funcObj, false).
        try env.createGlobalFunctionBinding(
            agent,
            func_name,
            func_obj,
            false,
        );
    }

    // 17. For each String variableName of declaredVariableNames, do
    var it_ = declared_variable_names.keyIterator();
    while (it_.next()) |ptr| {
        const variable_name = ptr.*;

        // a. Perform ? CreateGlobalVarBinding(envRecord, variableName, false).
        try env.createGlobalVarBinding(agent, variable_name, false);
    }

    // 18. Return unused.
}
