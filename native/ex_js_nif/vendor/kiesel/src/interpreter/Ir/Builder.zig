const std = @import("std");

const ast = @import("../../language/ast.zig");
const interpreter = @import("../../interpreter.zig");
const utils = @import("../../utils.zig");

const Constant = @import("constant_folding.zig").Constant;
const Ir = interpreter.Ir;

const computeLiveness = @import("liveness.zig").computeLiveness;
const computeLiveRanges = @import("live_ranges.zig").computeLiveRanges;
const constantFold = @import("constant_folding.zig").constantFold;
const containsSlice = utils.containsSlice;
const foldInst = @import("inst_folding.zig").foldInst;

pub const Builder = @This();

gpa: std.mem.Allocator,
name: []const u8,
root_node: Ast,
in_strict_mode: bool,
instructions: std.MultiArrayList(Ir.Inst),
extra: std.ArrayList(u32),
strings: std.StringArrayHashMapUnmanaged(void),
big_ints: BigIntArrayHashMap(void),
functions: std.ArrayList(Ir.Function),
classes: std.ArrayList(Ir.Class),
breakable_stack: std.ArrayList(*BreakableContext),
scope_depth: u16,
template_object_count: u16,

pub const Ast = union(enum) {
    script: *const ast.Script,
    module: *const ast.Module,
    function: struct {
        parameters: *const ast.FormalParameters,
        body: *const ast.FunctionBody,
    },
    eval: struct {
        script: *const ast.Script,
        strict: bool,
    },
};

const BigIntContext = struct {
    pub fn hash(_: @This(), key: std.math.big.int.Const) u32 {
        var hasher: std.hash.Wyhash = .init(0);
        hasher.update(@ptrCast(&key.positive));
        for (key.limbs) |limb| {
            hasher.update(@ptrCast(&limb));
        }
        return @truncate(hasher.final());
    }

    pub fn eql(_: @This(), a: std.math.big.int.Const, b: std.math.big.int.Const, _: usize) bool {
        return a.eql(b);
    }
};

fn BigIntArrayHashMap(comptime V: type) type {
    return std.array_hash_map.Custom(std.math.big.int.Const, V, BigIntContext, true);
}

const BreakableContext = struct {
    label: ?[]const u8,
    continue_target: JumpTarget,
    break_target: JumpTarget,
    result_ref: Ir.Inst.Ref,
    scope_depth: u16 = 0,
    iterator_ref: Ir.Inst.Ref = .none,

    const JumpTarget = union(enum) {
        known: Ir.Inst.Ref,
        deferred: std.ArrayList(DeferredJump),
    };

    const DeferredJump = struct {
        inst: Deferred,
        value: Ir.Inst.Ref,
    };

    fn deinit(ctx: *BreakableContext, gpa: std.mem.Allocator) void {
        switch (ctx.continue_target) {
            .known => {},
            .deferred => |*list| list.deinit(gpa),
        }
        switch (ctx.break_target) {
            .known => {},
            .deferred => |*list| list.deinit(gpa),
        }
    }

    fn setDeferredBreaks(ctx: *BreakableContext, target: Ir.Inst.Ref) void {
        for (ctx.break_target.deferred.items) |jump| {
            jump.inst.set(.{ .br = .{
                .target = target,
                .value = jump.value,
            } });
        }
    }

    fn setDeferredContinues(ctx: *BreakableContext, target: Ir.Inst.Ref) void {
        for (ctx.continue_target.deferred.items) |jump| {
            jump.inst.set(.{ .br = .{
                .target = target,
                .value = jump.value,
            } });
        }
    }
};

pub const Error = error{OutOfMemory};

pub fn init(gpa: std.mem.Allocator, name: []const u8, root_node: Ast) Builder {
    const in_strict_mode = switch (root_node) {
        .script => |script| script.scriptIsStrict(),
        .module => true,
        .function => |function| function.body.strict,
        .eval => |eval| eval.strict or eval.script.scriptIsStrict(),
    };
    return .{
        .gpa = gpa,
        .name = name,
        .root_node = root_node,
        .in_strict_mode = in_strict_mode,
        .instructions = .empty,
        .extra = .empty,
        .strings = .empty,
        .big_ints = .empty,
        .functions = .empty,
        .classes = .empty,
        .breakable_stack = .empty,
        .scope_depth = 0,
        .template_object_count = 0,
    };
}

pub fn deinit(b: *Builder) void {
    b.instructions.deinit(b.gpa);
    b.extra.deinit(b.gpa);
    for (b.strings.keys()) |key| b.gpa.free(key);
    b.strings.deinit(b.gpa);
    for (b.big_ints.keys()) |big_int| b.gpa.free(big_int.limbs);
    b.big_ints.deinit(b.gpa);
    b.functions.deinit(b.gpa);
    for (b.classes.items) |class| b.gpa.free(class.element_names);
    b.classes.deinit(b.gpa);
    for (b.breakable_stack.items) |ctx| {
        ctx.deinit(b.gpa);
        b.gpa.destroy(ctx);
    }
    b.breakable_stack.deinit(b.gpa);
}

pub fn build(b: *Builder) Error!Ir {
    const result = switch (b.root_node) {
        .script => |script| try b.lowerScript(script),
        .module => |module| try b.lowerModule(module),
        .function => |function| try b.lowerFunction(function.parameters, function.body),
        .eval => |eval| try b.lowerScript(eval.script),
    };
    _ = try b.addInst(.{
        .tag = .@"return",
        .data = .{ .ref = result },
    });

    const name = try b.gpa.dupe(u8, b.name);
    errdefer b.gpa.free(name);

    var instructions = b.instructions.toOwnedSlice();
    errdefer instructions.deinit(b.gpa);

    const extra = try b.extra.toOwnedSlice(b.gpa);
    errdefer b.gpa.free(extra);

    const strings = try b.gpa.dupe([]const u8, b.strings.keys());
    errdefer b.gpa.free(strings);
    b.strings.clearRetainingCapacity(); // Transfer ownership
    errdefer for (strings) |string| b.gpa.free(string);

    const big_ints = try b.gpa.dupe(std.math.big.int.Const, b.big_ints.keys());
    errdefer b.gpa.free(big_ints);
    b.big_ints.clearRetainingCapacity(); // Transfer ownership
    errdefer for (big_ints) |big_int| b.gpa.free(big_int.limbs);

    const functions = try b.functions.toOwnedSlice(b.gpa);
    errdefer b.gpa.free(functions);

    const classes = try b.classes.toOwnedSlice(b.gpa);
    errdefer {
        for (classes) |class| b.gpa.free(class.element_names);
        b.gpa.free(classes);
    }

    var ir: Ir = .{
        .name = name,
        .instructions = instructions,
        .extra = extra,
        .strings = strings,
        .big_ints = big_ints,
        .functions = functions,
        .classes = classes,
        .liveness = undefined,
        .live_ranges = undefined,
    };

    ir.liveness = try computeLiveness(b.gpa, &ir);
    errdefer ir.liveness.deinit(b.gpa);

    ir.live_ranges = try computeLiveRanges(b.gpa, &ir);
    errdefer b.gpa.free(ir.live_ranges);

    return ir;
}

fn addInst(b: *Builder, inst: Ir.Inst) std.mem.Allocator.Error!Ir.Inst.Ref {
    if (foldInst(b, inst)) |ref| return ref;
    const index: Ir.Inst.Index = @fromBackingInt(@intCast(b.instructions.len));
    try b.instructions.append(b.gpa, inst);
    return index.toRef();
}

const Deferred = struct {
    b: *Builder,
    index: Ir.Inst.Index,

    const Data = union {
        br: Ir.Inst.Br,
        br_cond: Ir.Inst.BrCond,
        exception_handler: Ir.Inst.ExceptionHandler,
    };

    fn set(d: Deferred, data: Data) void {
        const slice = d.b.instructions.slice();
        const i = @backingInt(d.index);
        switch (slice.items(.tag)[i]) {
            .br => slice.items(.data)[i] = .{ .br = data.br },
            .br_cond => {
                const ei = @backingInt(slice.items(.data)[i].br_cond);
                d.b.extra.items[ei] = @backingInt(data.br_cond.condition);
                d.b.extra.items[ei + 1] = @backingInt(data.br_cond.then_target);
                d.b.extra.items[ei + 2] = @backingInt(data.br_cond.else_target);
            },
            .exception_handler => {
                const ei = @backingInt(slice.items(.data)[i].exception_handler);
                d.b.extra.items[ei] = @backingInt(data.exception_handler.start);
                d.b.extra.items[ei + 1] = @backingInt(data.exception_handler.end);
                d.b.extra.items[ei + 2] = @backingInt(data.exception_handler.target);
                d.b.extra.items[ei + 3] = data.exception_handler.scope_depth;
            },
            else => unreachable,
        }
    }
};

fn addInstDeferred(b: *Builder, tag: Ir.Inst.Tag) std.mem.Allocator.Error!Deferred {
    const data: Ir.Inst.Data = switch (tag) {
        .br => .{ .br = undefined },
        .br_cond => blk: {
            const extra_index: Ir.ExtraIndex = @fromBackingInt(@intCast(b.extra.items.len));
            try b.extra.appendNTimes(b.gpa, undefined, 3);
            break :blk .{ .br_cond = extra_index };
        },
        .exception_handler => blk: {
            const extra_index: Ir.ExtraIndex = @fromBackingInt(@intCast(b.extra.items.len));
            try b.extra.appendNTimes(b.gpa, undefined, 4);
            break :blk .{ .exception_handler = extra_index };
        },
        else => unreachable,
    };
    const ref = try b.addInst(.{
        .tag = tag,
        .data = data,
    });
    return .{ .b = b, .index = ref.toIndex().? };
}

fn addLabel(b: *Builder) std.mem.Allocator.Error!Ir.Inst.Ref {
    return b.addInst(.{
        .tag = .label,
        .data = .{ .none = {} },
    });
}

fn addExtra(b: *Builder, comptime T: type, extra: T) std.mem.Allocator.Error!Ir.ExtraIndex {
    const extra_index: Ir.ExtraIndex = @fromBackingInt(@intCast(b.extra.items.len));
    const info = @typeInfo(T).@"struct";
    try b.extra.ensureUnusedCapacity(b.gpa, info.field_names.len);
    inline for (info.field_names, info.field_types) |field_name, field_type| {
        const value = @field(extra, field_name);
        b.extra.appendAssumeCapacity(switch (field_type) {
            u32 => value,
            Ir.Inst.Ref,
            Ir.StringIndex,
            => @backingInt(value),
            else => comptime unreachable,
        });
    }
    return extra_index;
}

fn addFunction(b: *Builder, function: Ir.Function) std.mem.Allocator.Error!Ir.Function.Index {
    const index: Ir.Function.Index = @fromBackingInt(@intCast(b.functions.items.len));
    try b.functions.append(b.gpa, function);
    return index;
}

fn addClass(b: *Builder, class: Ir.Class) std.mem.Allocator.Error!Ir.Class.Index {
    const index: Ir.Class.Index = @fromBackingInt(@intCast(b.classes.items.len));
    try b.classes.append(b.gpa, class);
    return index;
}

fn setAnonymousFunctionName(b: *Builder, ref: Ir.Inst.Ref, string_index: Ir.StringIndex) void {
    const index = ref.toIndex().?;
    const inst = b.instructions.get(@backingInt(index));
    switch (inst.tag) {
        .create_function => {
            const function_index = inst.data.create_function;
            const function = &b.functions.items[@backingInt(function_index)];
            if (function.name == .none) {
                function.name = .{ .default = string_index };
            }
        },
        .create_class => {
            const class_index = inst.data.create_class;
            const class = &b.classes.items[@backingInt(class_index)];
            if (class.name == .none) {
                class.name = .{ .default = string_index };
            }
        },
        else => unreachable,
    }
}

fn pushBreakableContext(b: *Builder, ctx: BreakableContext) std.mem.Allocator.Error!*BreakableContext {
    const heap_ctx = try b.gpa.create(BreakableContext);
    heap_ctx.* = ctx;
    heap_ctx.scope_depth = b.scope_depth;
    try b.breakable_stack.append(b.gpa, heap_ctx);
    return heap_ctx;
}

fn popBreakableContext(b: *Builder) void {
    const ctx = b.breakable_stack.pop().?;
    ctx.deinit(b.gpa);
    b.gpa.destroy(ctx);
}

fn findBreakableContext(b: *Builder, label: ?[]const u8) *BreakableContext {
    if (label) |l| {
        var it = std.mem.reverseIterator(b.breakable_stack.items);
        while (it.next()) |ctx| {
            if (ctx.label) |ctx_label| {
                if (std.mem.eql(u8, ctx_label, l)) {
                    return ctx;
                }
            }
        }
        unreachable;
    }
    return b.breakable_stack.last().?;
}

fn internString(b: *Builder, string: []const u8) std.mem.Allocator.Error!Ir.StringIndex {
    const gop = try b.strings.getOrPut(b.gpa, string);
    if (!gop.found_existing) {
        gop.key_ptr.* = try b.gpa.dupe(u8, string);
    }
    return @fromBackingInt(@intCast(gop.index));
}

fn internBigInt(b: *Builder, big_int: std.math.big.int.Const) std.mem.Allocator.Error!Ir.BigIntIndex {
    const gop = try b.big_ints.getOrPut(b.gpa, big_int);
    if (!gop.found_existing) {
        gop.key_ptr.limbs = try b.gpa.dupe(std.math.big.Limb, big_int.limbs);
    }
    return @fromBackingInt(@intCast(gop.index));
}

fn lowerConstant(b: *Builder, constant: Constant) Error!Ir.Inst.Ref {
    return switch (constant) {
        .undefined => b.addInst(.{
            .tag = .undefined,
            .data = .{ .none = {} },
        }),
        .null => b.addInst(.{
            .tag = .null,
            .data = .{ .none = {} },
        }),
        .boolean => |boolean| b.addInst(.{
            .tag = if (boolean) .true else .false,
            .data = .{ .none = {} },
        }),
        .number => |number| b.addInst(.{
            .tag = .number,
            .data = .{ .number = number },
        }),
        .big_int => |big_int| {
            const big_int_index = try b.internBigInt(big_int);
            return b.addInst(.{
                .tag = .big_int,
                .data = .{ .big_int = big_int_index },
            });
        },
        .string => |string| {
            const string_index = try b.internString(string);
            return b.addInst(.{
                .tag = .string,
                .data = .{ .string = string_index },
            });
        },
    };
}

fn lowerScript(b: *Builder, script: *const ast.Script) Error!Ir.Inst.Ref {
    std.debug.assert(!script.statement_list.containsUsing());
    return b.lowerStatementList(&script.statement_list);
}

fn lowerModule(b: *Builder, module: *const ast.Module) Error!Ir.Inst.Ref {
    var has_using = false;
    for (module.module_item_list.items) |module_item| {
        switch (module_item) {
            // InitializeEnvironment is responsible for creating the bindings.
            .import_declaration => {},
            .export_declaration => |*export_decl| _ = try b.lowerExportDeclaration(export_decl),
            .statement_list_item => |stmt_list_item| {
                switch (stmt_list_item) {
                    .statement => |stmt| _ = try b.lowerStatement(stmt),
                    .declaration => |decl| _ = try b.lowerDeclaration(decl),
                }
                if (stmt_list_item.containsUsing()) has_using = true;
            },
        }
    }

    if (has_using) {
        _ = try b.addInst(.{
            .tag = .dispose_resources,
            .data = .{ .none = {} },
        });
    }

    return .none;
}

fn lowerExportDeclaration(b: *Builder, export_decl: *const ast.ExportDeclaration) Error!Ir.Inst.Ref {
    switch (export_decl.*) {
        .export_from,
        .named_exports,
        => return .none,
        .variable_statement => |*var_stmt| return b.lowerVariableStatement(var_stmt),
        .declaration => |decl| return b.lowerDeclaration(decl),
        .default_hoistable_declaration => return .none, // Handled by InitializeEnvironment
        .default_class_declaration => |*class_decl| {
            const value = try b.lowerClassDeclaration(class_decl);
            if (class_decl.identifier == null) {
                const string_index = try b.internString("*default*");
                _ = try b.addInst(.{
                    .tag = .initialize_binding,
                    .data = .{ .set_binding = .{
                        .name = string_index,
                        .value = value,
                    } },
                });
            }
            return .none;
        },
        .default_expression => |*expr| {
            const value = try b.lowerExpression(expr);
            const string_index = try b.internString("*default*");
            if (expr.isAnonymousFunctionDefinition()) {
                b.setAnonymousFunctionName(value, string_index);
            }
            _ = try b.addInst(.{
                .tag = .initialize_binding,
                .data = .{ .set_binding = .{
                    .name = string_index,
                    .value = value,
                } },
            });
            return .none;
        },
    }
}

fn lowerFunction(b: *Builder, formal_parameters: *const ast.FormalParameters, function_body: *const ast.FunctionBody) Error!Ir.Inst.Ref {
    const has_using = function_body.statement_list.containsUsing();

    try b.lowerFunctionDeclarationInstantiation(formal_parameters, function_body);

    switch (function_body.type) {
        .generator, .async_generator => {
            // Emit a synthetic yield after FDI so the rest of the bytecode resumes later.
            _ = try b.addInst(.{
                .tag = .yield,
                .data = .{ .ref = .none },
            });
        },
        else => {},
    }

    _ = try b.lowerStatementList(&function_body.statement_list);

    if (has_using) {
        _ = try b.addInst(.{
            .tag = .dispose_resources,
            .data = .{ .none = {} },
        });
    }

    // Implicit return is added in `build()`
    return .none;
}

/// 10.2.11 FunctionDeclarationInstantiation ( func, argList )
/// https://tc39.es/ecma262/#sec-functiondeclarationinstantiation
fn lowerFunctionDeclarationInstantiation(b: *Builder, formal_parameters: *const ast.FormalParameters, function_body: *const ast.FunctionBody) Error!void {
    // 1. Let calleeContext be the running execution context.
    // NOTE: The function's execution context is set up by `prepareForOrdinaryCall()` at runtime.

    // 2. Let code be func.[[ECMAScriptCode]].
    // NOTE: This is `function_body`.

    // 3. Let strict be func.[[Strict]].
    const strict = b.in_strict_mode;

    // 4. Let formals be func.[[FormalParameters]].
    // NOTE: This is `formal_parameters`.

    // 5. Let paramNames be the BoundNames of formals.
    var param_names: std.ArrayList(ast.Identifier) = .empty;
    defer param_names.deinit(b.gpa);
    try formal_parameters.collectBoundNames(b.gpa, &param_names);

    // 6. If paramNames has any duplicate entries, let hasDuplicates be true; else let hasDuplicates
    //    be false.
    const has_duplicates = blk: {
        var seen: std.array_hash_map.String(void) = .empty;
        defer seen.deinit(b.gpa);
        for (param_names.items) |name| {
            const gop = try seen.getOrPut(b.gpa, name);
            if (gop.found_existing) break :blk true;
        }
        break :blk false;
    };

    // 7. Let simpleParamList be IsSimpleParameterList of formals.
    const simple_param_list = formal_parameters.isSimpleParameterList();

    // 8. Let hasParamExprs be ContainsExpression of formals.
    const has_param_exprs = formal_parameters.containsExpression();

    // 9. Let variableNames be the VarDeclaredNames of code.
    var variable_names: std.ArrayList(ast.Identifier) = .empty;
    defer variable_names.deinit(b.gpa);
    try function_body.collectVarDeclaredNames(b.gpa, &variable_names);

    // 10. Let variableDecls be the VarScopedDeclarations of code.
    var variable_decls: std.ArrayList(ast.VarScopedDeclaration) = .empty;
    defer variable_decls.deinit(b.gpa);
    try function_body.collectVarScopedDeclarations(b.gpa, &variable_decls);

    // 11. Let lexicalNames be the LexicallyDeclaredNames of code.
    var lexical_names: std.ArrayList(ast.Identifier) = .empty;
    defer lexical_names.deinit(b.gpa);
    try function_body.collectLexicallyDeclaredNames(b.gpa, &lexical_names);

    // 12. Let funcNames be a new empty List.
    var func_names: std.array_hash_map.String(void) = .empty;
    defer func_names.deinit(b.gpa);

    // 13. Let funcsToInitialize be a new empty List.
    var funcs_to_initialize: std.ArrayList(ast.HoistableDeclaration) = .empty;
    defer funcs_to_initialize.deinit(b.gpa);

    // 14. For each element variableDecl of variableDecls, in reverse List order, do
    var it = std.mem.reverseIterator(variable_decls.items);
    while (it.next()) |variable_decl| {
        // a. If variableDecl is neither a VariableDeclaration nor a ForBinding nor a
        //    BindingIdentifier, then
        if (variable_decl == .hoistable_declaration) {
            // i. Assert: variableDecl is either a FunctionDeclaration, a GeneratorDeclaration, an
            //    AsyncFunctionDeclaration, or an AsyncGeneratorDeclaration.
            const hoistable_decl = variable_decl.hoistable_declaration;

            // ii. Let funcName be the sole element of the BoundNames of variableDecl.
            const func_name = switch (hoistable_decl) {
                inline else => |func_decl| func_decl.identifier.?,
            };

            // iii. If funcNames does not contain funcName, then
            const gop = try func_names.getOrPut(b.gpa, func_name);
            if (!gop.found_existing) {
                // 1. Insert funcName as the first element of funcNames.
                // 2. NOTE: If there are multiple function declarations for the same name, the last
                //    declaration is used.
                // 3. Insert variableDecl as the first element of funcsToInitialize.
                // NOTE: AFAICT the order isn't observable, so we can append.
                try funcs_to_initialize.append(b.gpa, hoistable_decl);
            }
        }
    }

    // 15. Let argumentsObjNeeded be true.
    // OPTIMIZATION: If nothing accesses the arguments object we don't need to create one.
    //               This is determined during parsing, with a deopt when using eval.
    var arguments_obj_needed = formal_parameters.arguments_object_needed or function_body.arguments_object_needed;

    // 16. If func.[[ThisMode]] is lexical, then
    //     a. NOTE: Arrow functions never have an arguments object.
    //     b. Set argumentsObjNeeded to false.
    // NOTE: This is done by setting arguments_object_needed to false during parsing.

    // 17. Else if paramNames contains "arguments", then
    if (containsSlice(param_names.items, "arguments")) {
        // a. Set argumentsObjNeeded to false.
        arguments_obj_needed = false;
    }

    // 18. Else if hasParamExprs is false, then
    else if (!has_param_exprs) {
        // a. If funcNames contains "arguments" or lexicalNames contains "arguments", then
        if (func_names.contains("arguments") or containsSlice(lexical_names.items, "arguments")) {
            // i. Set argumentsObjNeeded to false.
            arguments_obj_needed = false;
        }
    }

    // 19. If strict is true or hasParamExprs is false, then
    if (strict or !has_param_exprs) {
        // a. NOTE: Only a single Environment Record is needed for the parameters, since calls to
        //    `eval` in strict mode code cannot create new bindings which are visible outside of the
        //    `eval`.

        // b. Let envRecord be the LexicalEnvironment of calleeContext.
        // NOTE: The function environment created by `prepareForOrdinaryCall()` is used directly.
    } else {
        // 20. Else,

        // a. NOTE: A separate Environment Record is needed to ensure that bindings created by
        //    direct eval calls in the formal parameter list are outside the environment where
        //    parameters are declared.

        // b. Let calleeEnv be the LexicalEnvironment of calleeContext.
        // c. Let envRecord be NewDeclarativeEnvironment(calleeEnv).
        _ = try b.addInst(.{
            .tag = .push_scope,
            .data = .{ .none = {} },
        });
        b.scope_depth += 1;

        // d. Assert: The VariableEnvironment of calleeContext and calleeEnv are the same
        //    Environment Record.

        // e. Set the LexicalEnvironment of calleeContext to envRecord.
        // NOTE: This is handled by `push_scope`.
    }

    var already_declared: std.array_hash_map.String(void) = .empty;
    defer already_declared.deinit(b.gpa);

    // 21. For each String paramName of paramNames, do
    for (param_names.items) |param_name| {
        // a. Let alreadyDeclared be ! envRecord.HasBinding(paramName).
        const gop = try already_declared.getOrPut(b.gpa, param_name);

        // b. NOTE: Early errors ensure that duplicate parameter names can only occur in non-strict
        //    functions that do not have parameter default values or rest parameters.

        // c. If alreadyDeclared is false, then
        if (!gop.found_existing) {
            // i. Perform ! envRecord.CreateMutableBinding(paramName, false).
            const string_index = try b.internString(param_name);
            _ = try b.addInst(.{
                .tag = .create_mutable_binding,
                .data = .{ .string = string_index },
            });

            // ii. If hasDuplicates is true, then
            if (has_duplicates) {
                // 1. Perform ! envRecord.InitializeBinding(paramName, undefined).
                const undefined_ref = try b.addInst(.{
                    .tag = .undefined,
                    .data = .{ .none = {} },
                });
                _ = try b.addInst(.{
                    .tag = .initialize_binding,
                    .data = .{ .set_binding = .{
                        .name = string_index,
                        .value = undefined_ref,
                    } },
                });
            }
        }
    }

    // 22. If argumentsObjNeeded is true, then
    const param_bindings_has_arguments = if (arguments_obj_needed) blk: {
        // a. If strict is true or simpleParamList is false, then
        const ao = if (strict or !simple_param_list) ao_blk: {
            // i. Let argumentsObj be CreateUnmappedArgumentsObject(argList).
            break :ao_blk try b.addInst(.{
                .tag = .create_unmapped_arguments_object,
                .data = .{ .none = {} },
            });
        } else ao_blk: {
            // b. Else,
            // i. NOTE: A mapped argument object is only provided for non-strict functions that
            //    don't have a rest parameter, any parameter default value initializers, or any
            //    destructured parameters.

            // ii. Let argumentsObj be CreateMappedArgumentsObject(func, formals, argList,
            //     envRecord).
            break :ao_blk try b.addInst(.{
                .tag = .create_mapped_arguments_object,
                .data = .{ .none = {} },
            });
        };

        // c. If strict is true, then
        const arguments_string = try b.internString("arguments");
        if (strict) {
            // i. Perform ! envRecord.CreateImmutableBinding("arguments", false).
            _ = try b.addInst(.{
                .tag = .create_immutable_binding,
                .data = .{ .string = arguments_string },
            });

            // ii. NOTE: In strict mode code early errors prevent attempting to assign to this
            //     binding, so its mutability is not observable.
        } else {
            // d. Else,
            // i. Perform ! envRecord.CreateMutableBinding("arguments", false).
            _ = try b.addInst(.{
                .tag = .create_mutable_binding,
                .data = .{ .string = arguments_string },
            });
        }

        // e. Perform ! envRecord.InitializeBinding("arguments", argumentsObj).
        _ = try b.addInst(.{
            .tag = .initialize_binding,
            .data = .{ .set_binding = .{
                .name = arguments_string,
                .value = ao,
            } },
        });

        // f. Let paramBindings be the list-concatenation of paramNames and « "arguments" ».
        break :blk true;
    } else blk: {
        // 23. Else,
        // a. Let paramBindings be paramNames.
        break :blk false;
    };

    // 24. Let iteratorRecord be CreateListIteratorRecord(argList).
    // NOTE: This is done with a manual loop below.

    // 25. If hasDuplicates is true, then
    //     a. Let usedEnv be undefined.
    // 26. Else,
    //     a. Let usedEnv be envRecord.
    // NOTE: The binding tag (`set_binding` vs `initialize_binding`) controls whether we use
    //       the environment or not.
    const binding_tag: Ir.Inst.Tag = if (has_duplicates) .set_binding else .initialize_binding;
    const binding_op: BindingOp = if (has_duplicates) .set else .initialize;

    // 27. NOTE: The following step cannot return a ReturnCompletion because the only way such a
    //     completion can arise in expression position is by use of YieldExpression, which is
    //     forbidden in parameter lists by Early Error rules in 15.5.1 and 15.6.1.

    // 28. Perform ? IteratorBindingInitialization of formals with arguments iteratorRecord and
    //     usedEnv.
    for (formal_parameters.items, 0..) |item, i| switch (item) {
        .formal_parameter => |param| switch (param.binding_element) {
            .single_name_binding => |binding| {
                const string_index = try b.internString(binding.binding_identifier);
                const arg_value = try b.addInst(.{
                    .tag = .get_argument,
                    .data = .{ .argument = @intCast(i) },
                });
                const default_expr, const anonymous_function_name = if (binding.initializer) |*expr|
                    .{ expr, if (expr.isAnonymousFunctionDefinition()) string_index else null }
                else
                    .{ null, null };
                const value = try b.lowerDefaultExpression(arg_value, default_expr, anonymous_function_name);
                _ = try b.addInst(.{
                    .tag = binding_tag,
                    .data = .{ .set_binding = .{
                        .name = string_index,
                        .value = value,
                    } },
                });
            },
            .binding_pattern_and_expression => |bpe| {
                const arg_value = try b.addInst(.{
                    .tag = .get_argument,
                    .data = .{ .argument = @intCast(i) },
                });
                const value = try b.lowerDefaultExpression(arg_value, if (bpe.initializer) |*expr| expr else null, null);
                _ = try b.lowerBindingPattern(&bpe.binding_pattern, value, binding_op);
            },
        },
        .function_rest_parameter => |rest_param| switch (rest_param.binding_rest_element) {
            .binding_identifier => |identifier| {
                const string_index = try b.internString(identifier);
                const rest_value = try b.addInst(.{
                    .tag = .get_rest_arguments,
                    .data = .{ .argument = @intCast(i) },
                });
                _ = try b.addInst(.{
                    .tag = binding_tag,
                    .data = .{ .set_binding = .{
                        .name = string_index,
                        .value = rest_value,
                    } },
                });
            },
            .binding_pattern => |*pattern| {
                const rest_value = try b.addInst(.{
                    .tag = .get_rest_arguments,
                    .data = .{ .argument = @intCast(i) },
                });
                _ = try b.lowerBindingPattern(pattern, rest_value, binding_op);
            },
        },
    };

    // 29. If hasParamExprs is false, then
    if (!has_param_exprs) {
        // a. NOTE: Only a single Environment Record is needed for the parameters and top-level
        //    vars.

        // b. Let instantiatedVariableNames be a copy of the List paramBindings.
        var instantiated_variable_names: std.array_hash_map.String(void) = .empty;
        defer instantiated_variable_names.deinit(b.gpa);
        for (param_names.items) |name| {
            try instantiated_variable_names.put(b.gpa, name, {});
        }
        if (param_bindings_has_arguments) {
            try instantiated_variable_names.put(b.gpa, "arguments", {});
        }

        // c. For each element name of variableNames, do
        for (variable_names.items) |name| {
            // i. If instantiatedVariableNames does not contain name, then
            const gop = try instantiated_variable_names.getOrPut(b.gpa, name);
            if (!gop.found_existing) {
                // 1. Append name to instantiatedVariableNames.
                // 2. Perform ! envRecord.CreateMutableBinding(name, false).
                // 3. Perform ! envRecord.InitializeBinding(name, undefined).
                const string_index = try b.internString(name);
                _ = try b.addInst(.{
                    .tag = .create_var_binding,
                    .data = .{ .string = string_index },
                });
            }
        }

        // d. Let variableEnv be envRecord.
        // NOTE: No separate environment needed.
    } else {
        // 30. Else,
        // a. NOTE: A separate Environment Record is needed to ensure that closures created by
        //    expressions in the formal parameter list do not have visibility of declarations in the
        //    function body.

        // b. Let variableEnv be NewDeclarativeEnvironment(envRecord).
        // c. Set the VariableEnvironment of calleeContext to variableEnv.
        _ = try b.addInst(.{
            .tag = .push_var_scope,
            .data = .{ .none = {} },
        });
        b.scope_depth += 1;

        // d. Let instantiatedVariableNames be a new empty List.
        var instantiated_variable_names: std.array_hash_map.String(void) = .empty;
        defer instantiated_variable_names.deinit(b.gpa);

        // e. For each element name of variableNames, do
        for (variable_names.items) |name| {
            // i. If instantiatedVariableNames does not contain name, then
            const gop = try instantiated_variable_names.getOrPut(b.gpa, name);
            if (!gop.found_existing) {
                // 1. Append name to instantiatedVariableNames.

                // 3. If paramBindings does not contain name or funcNames contains name, then
                const is_in_parameter_bindings = containsSlice(param_names.items, name) or
                    (param_bindings_has_arguments and std.mem.eql(u8, name, "arguments"));
                if (!is_in_parameter_bindings or func_names.contains(name)) {
                    // a. Let initialValue be undefined.
                    // 2. Perform ! variableEnv.CreateMutableBinding(name, false).
                    // 5. Perform ! variableEnv.InitializeBinding(name, initialValue).
                    const string_index = try b.internString(name);
                    _ = try b.addInst(.{
                        .tag = .create_var_binding,
                        .data = .{ .string = string_index },
                    });
                } else {
                    // 4. Else,
                    //     a. Let initialValue be ! envRecord.GetBindingValue(name, false).
                    // NOTE: We must read the value *before* creating the binding in varEnv, because
                    //       get_binding walks the environment chain and would find the uninitialized
                    //       binding in varEnv instead of the initialized one in env. This reorder is
                    //       equivalent because env.GetBindingValue has no side effects on varEnv.
                    const string_index = try b.internString(name);
                    const initial_value = try b.addInst(.{
                        .tag = .get_binding,
                        .data = .{ .string = string_index },
                    });

                    // 2. Perform ! variableEnv.CreateMutableBinding(name, false).
                    _ = try b.addInst(.{
                        .tag = .create_mutable_binding,
                        .data = .{ .string = string_index },
                    });

                    // 5. Perform ! variableEnv.InitializeBinding(name, initialValue).
                    _ = try b.addInst(.{
                        .tag = .initialize_binding,
                        .data = .{ .set_binding = .{
                            .name = string_index,
                            .value = initial_value,
                        } },
                    });
                }

                // 6. NOTE: A var with the same name as a formal parameter initially has the same
                //    value as the corresponding initialized parameter.
            }
        }
    }

    // 31. If strict is true, then
    if (strict) {
        // a. Let lexicalEnv be variableEnv.
        // NOTE: No separate environment needed.
    } else {
        // 32. Else,
        // a. If the host is a web browser or otherwise supports Block-Level Function Declarations
        //    Web Legacy Compatibility Semantics, then
        //    [...]

        // b. Let lexicalEnv be NewDeclarativeEnvironment(variableEnv).
        _ = try b.addInst(.{
            .tag = .push_scope,
            .data = .{ .none = {} },
        });
        b.scope_depth += 1;

        // c. NOTE: Non-strict functions use a separate Environment Record for top-level lexical
        //    declarations so that a direct eval can determine whether any var scoped declarations
        //    introduced by the eval code conflict with pre-existing top-level lexically scoped
        //    declarations. This is not needed for strict functions because a strict direct eval
        //    always places all declarations into a new Environment Record.
    }

    // 33. Set the LexicalEnvironment of calleeContext to lexicalEnv.
    // NOTE: This is handled by `push_scope` above.

    // 34. Let lexicalDecls be the LexicallyScopedDeclarations of code.
    var lexical_decls: std.ArrayList(ast.LexicallyScopedDeclaration) = .empty;
    defer lexical_decls.deinit(b.gpa);
    try function_body.collectLexicallyScopedDeclarations(b.gpa, &lexical_decls);

    var bound_names: std.ArrayList(ast.Identifier) = .empty;
    defer bound_names.deinit(b.gpa);

    // 35. For each element lexicalDecl of lexicalDecls, do
    for (lexical_decls.items) |lexical_decl| {
        // a. NOTE: A lexically declared name cannot be the same as a function/generator
        //    declaration, formal parameter, or a var name. Lexically declared names are only
        //    instantiated here but not initialized.

        // b. For each element name of the BoundNames of lexicalDecl, do
        bound_names.clearRetainingCapacity();
        try lexical_decl.collectBoundNames(b.gpa, &bound_names);

        for (bound_names.items) |name| {
            const string_index = try b.internString(name);

            // i. If IsConstantDeclaration of lexicalDecl is true, then
            if (lexical_decl.isConstantDeclaration()) {
                // 1. Perform ! lexicalEnv.CreateImmutableBinding(name, true).
                _ = try b.addInst(.{
                    .tag = .create_immutable_binding,
                    .data = .{ .string = string_index },
                });
            } else {
                // ii. Else,
                // 1. Perform ! lexicalEnv.CreateMutableBinding(name, false).
                _ = try b.addInst(.{
                    .tag = .create_mutable_binding,
                    .data = .{ .string = string_index },
                });
            }
        }
    }

    // 36. Let privateEnv be the PrivateEnvironment of calleeContext.
    // NOTE: When `create_function` executes at runtime, the VM captures the current execution
    //       context's private environment in the new function object.

    // 37. For each Parse Node funcDecl of funcsToInitialize, do
    for (funcs_to_initialize.items) |hoistable_decl| {
        // a. Let funcName be the sole element of the BoundNames of funcDecl.
        // b. Let funcObj be InstantiateFunctionObject of funcDecl with arguments lexicalEnv and
        //    privateEnv.
        const string_index, const func_ref = switch (hoistable_decl) {
            inline else => |func_decl, tag| blk: {
                const string_index = try b.internString(func_decl.identifier.?);
                const function_index = try b.addFunction(.{
                    .source_range = func_decl.source_range,
                    .name = .{ .identifier = string_index },
                    .parameters = func_decl.formal_parameters,
                    .body = func_decl.function_body,
                    .kind = switch (tag) {
                        .function_declaration => .normal,
                        .generator_declaration => .generator,
                        .async_function_declaration => .async,
                        .async_generator_declaration => .async_generator,
                    },
                });
                const func_ref = try b.addInst(.{
                    .tag = .create_function,
                    .data = .{ .create_function = function_index },
                });
                break :blk .{ string_index, func_ref };
            },
        };

        // c. Perform ! variableEnv.SetMutableBinding(funcName, funcObj, false).
        _ = try b.addInst(.{
            .tag = .set_binding,
            .data = .{ .set_binding = .{
                .name = string_index,
                .value = func_ref,
            } },
        });
    }

    // 38. Return unused.
}

/// 14.2.3 BlockDeclarationInstantiation ( code, envRecord )
/// https://tc39.es/ecma262/#sec-blockdeclarationinstantiation
fn lowerBlockDeclarationInstantiation(
    b: *Builder,
    ast_node: union(enum) {
        block: *const ast.Block,
        case_block: *const ast.CaseBlock,
    },
) Error!void {
    // 1. Let decls be the LexicallyScopedDeclarations of code.
    var decls: std.ArrayList(ast.LexicallyScopedDeclaration) = .empty;
    defer decls.deinit(b.gpa);
    switch (ast_node) {
        .block => |block| try block.statement_list.collectLexicallyScopedDeclarations(b.gpa, &decls),
        .case_block => |case_block| try case_block.collectLexicallyScopedDeclarations(b.gpa, &decls),
    }

    // 2. Let privateEnv be the running execution context's PrivateEnvironment.

    var bound_names: std.ArrayList(ast.Identifier) = .empty;
    defer bound_names.deinit(b.gpa);

    // 3. For each element decl of decls, do
    for (decls.items) |decl| {
        // a. For each element name of the BoundNames of decl, do
        bound_names.clearRetainingCapacity();
        try decl.collectBoundNames(b.gpa, &bound_names);
        for (bound_names.items) |name| {
            // i. If IsConstantDeclaration of decl is true, then
            //     1. Perform ! envRecord.CreateImmutableBinding(name, true).
            // ii. Else,
            //     1. If the host is a web browser or otherwise supports Block-Level Function
            //        Declarations Web Legacy Compatibility Semantics, then
            //        [...]
            //     2. Else,
            //         a. Perform ! envRecord.CreateMutableBinding(name, false).
            const tag: Ir.Inst.Tag = if (decl.isConstantDeclaration())
                .create_immutable_binding
            else
                .create_mutable_binding;
            const string_index = try b.internString(name);
            _ = try b.addInst(.{
                .tag = tag,
                .data = .{ .string = string_index },
            });
        }

        // b. If decl is either a FunctionDeclaration, a GeneratorDeclaration, an
        //    AsyncFunctionDeclaration, or an AsyncGeneratorDeclaration, then
        if (decl == .hoistable_declaration) {
            const hoistable_decl = decl.hoistable_declaration;

            // i. Let funcName be the sole element of the BoundNames of decl.
            // ii. Let funcObj be InstantiateFunctionObject of decl with arguments envRecord and
            //     privateEnv.
            // iii. If the host is a web browser or otherwise supports Block-Level Function
            //      Declarations Web Legacy Compatibility Semantics, then
            //      [...]
            // iv. Else,
            //     1. Perform ! envRecord.InitializeBinding(funcName, funcObj).
            const string_index, const function_ref = switch (hoistable_decl) {
                inline else => |func_decl, tag| blk: {
                    const string_index = try b.internString(func_decl.identifier.?);
                    const function_index = try b.addFunction(.{
                        .source_range = func_decl.source_range,
                        .name = .{ .identifier = string_index },
                        .parameters = func_decl.formal_parameters,
                        .body = func_decl.function_body,
                        .kind = switch (tag) {
                            .function_declaration => .normal,
                            .generator_declaration => .generator,
                            .async_function_declaration => .async,
                            .async_generator_declaration => .async_generator,
                        },
                    });
                    const function_ref = try b.addInst(.{
                        .tag = .create_function,
                        .data = .{ .create_function = function_index },
                    });
                    break :blk .{ string_index, function_ref };
                },
            };
            _ = try b.addInst(.{
                .tag = .initialize_binding,
                .data = .{ .set_binding = .{
                    .name = string_index,
                    .value = function_ref,
                } },
            });
        }
    }

    // 4. Return unused.
}

fn lowerStatementList(b: *Builder, stmt_list: *const ast.StatementList) Error!Ir.Inst.Ref {
    var last: Ir.Inst.Ref = .none;
    for (stmt_list.items) |item| {
        const result = switch (item) {
            .statement => |stmt| try b.lowerStatement(stmt),
            .declaration => |decl| try b.lowerDeclaration(decl),
        };
        if (result != .none) {
            last = result;
        }
    }
    return last;
}

fn lowerStatement(b: *Builder, stmt: *const ast.Statement) Error!Ir.Inst.Ref {
    return switch (stmt.*) {
        .block_statement => |*block_stmt| try b.lowerBlockStatement(block_stmt, null),
        .variable_statement => |*var_stmt| try b.lowerVariableStatement(var_stmt),
        .empty_statement => .none,
        .expression_statement => |expr_stmt| try b.lowerExpression(&expr_stmt.expression),
        .if_statement => |*if_stmt| try b.lowerIfStatement(if_stmt),
        .breakable_statement => |*brk_stmt| try b.lowerBreakableStatement(brk_stmt, null),
        .continue_statement => |*cont_stmt| try b.lowerContinueStatement(cont_stmt),
        .break_statement => |*brk_stmt| try b.lowerBreakStatement(brk_stmt),
        .return_statement => |*ret_stmt| try b.lowerReturnStatement(ret_stmt),
        .with_statement => |*with_stmt| try b.lowerWithStatement(with_stmt),
        .labelled_statement => |*lbl_stmt| try b.lowerLabelledStatement(lbl_stmt),
        .throw_statement => |*throw_stmt| try b.lowerThrowStatement(throw_stmt),
        .try_statement => |*try_stmt| try b.lowerTryStatement(try_stmt),
        .debugger_statement => .none,
    };
}

fn lowerDeclaration(b: *Builder, decl: *const ast.Declaration) Error!Ir.Inst.Ref {
    switch (decl.*) {
        .hoistable_declaration => {}, // Handled by GDI/FDI before execution
        .class_declaration => |*class_decl| _ = try b.lowerClassDeclaration(class_decl),
        .lexical_declaration => |*lex_decl| _ = try b.lowerLexicalDeclaration(lex_decl),
    }
    return .none;
}

fn lowerBlockStatement(b: *Builder, block_stmt: *const ast.BlockStatement, breakable_ctx: ?*BreakableContext) Error!Ir.Inst.Ref {
    return b.lowerBlock(&block_stmt.block, breakable_ctx);
}

fn lowerBlock(b: *Builder, block: *const ast.Block, breakable_ctx: ?*BreakableContext) Error!Ir.Inst.Ref {
    const stmt_list = &block.statement_list;
    const has_scope = stmt_list.hasLexicallyScopedDeclarations();
    const has_using = stmt_list.containsUsing();

    if (has_scope) {
        _ = try b.addInst(.{
            .tag = .push_scope,
            .data = .{ .none = {} },
        });
        b.scope_depth += 1;
        try b.lowerBlockDeclarationInstantiation(.{ .block = block });
    }

    const result = if (breakable_ctx) |ctx| blk: {
        try b.lowerBreakableStatementList(stmt_list, ctx);
        break :blk ctx.result_ref;
    } else try b.lowerStatementList(stmt_list);

    if (has_scope) {
        if (has_using) {
            _ = try b.addInst(.{
                .tag = .dispose_resources,
                .data = .{ .none = {} },
            });
        }
        _ = try b.addInst(.{
            .tag = .pop_scope,
            .data = .{ .none = {} },
        });
        b.scope_depth -= 1;
    }

    return result;
}

fn lowerVariableStatement(b: *Builder, var_stmt: *const ast.VariableStatement) Error!Ir.Inst.Ref {
    for (var_stmt.variable_declaration_list.items) |*var_decl| {
        _ = try b.lowerVariableDeclaration(var_decl);
    }
    return .none;
}

fn lowerVariableDeclaration(b: *Builder, var_decl: *const ast.VariableDeclaration) Error!Ir.Inst.Ref {
    // GlobalDeclarationInstantiation is responsible for creating the bindings and initializing them to undefined.
    switch (var_decl.*) {
        .binding_identifier => |binding| {
            if (binding.initializer) |*init_expr| {
                const value = try b.lowerExpression(init_expr);
                const string_index = try b.internString(binding.binding_identifier);
                if (init_expr.isAnonymousFunctionDefinition()) {
                    b.setAnonymousFunctionName(value, string_index);
                }
                _ = try b.addInst(.{
                    .tag = .set_binding,
                    .data = .{ .set_binding = .{
                        .name = string_index,
                        .value = value,
                    } },
                });
            }
        },
        .binding_pattern => |pattern| {
            const value = try b.lowerExpression(&pattern.initializer);
            _ = try b.lowerBindingPattern(&pattern.binding_pattern, value, .set);
        },
    }
    return .none;
}

fn lowerIfStatement(b: *Builder, if_stmt: *const ast.IfStatement) Error!Ir.Inst.Ref {
    if (try constantFold(b.gpa, &if_stmt.test_expression)) |constant| {
        defer constant.deinit(b.gpa);
        const result = if (constant.isTruthy())
            try b.lowerStatement(if_stmt.consequent_statement)
        else if (if_stmt.alternate_statement) |stmt|
            try b.lowerStatement(stmt)
        else
            Ir.Inst.Ref.none;
        return if (result != .none) result else try b.addInst(.{
            .tag = .undefined,
            .data = .{ .none = {} },
        });
    }

    const test_result = try b.addInst(.{
        .tag = .to_boolean,
        .data = .{ .ref = try b.lowerExpression(&if_stmt.test_expression) },
    });
    const test_br_cond = try b.addInstDeferred(.br_cond);

    const then_label = try b.addLabel();
    const then_value = try b.lowerStatement(if_stmt.consequent_statement);
    const then_result = if (then_value != .none) then_value else try b.addInst(.{
        .tag = .undefined,
        .data = .{ .none = {} },
    });
    const then_br = try b.addInstDeferred(.br);

    const else_label = try b.addLabel();
    const else_value = if (if_stmt.alternate_statement) |stmt|
        try b.lowerStatement(stmt)
    else
        Ir.Inst.Ref.none;
    const else_result = if (else_value != .none) else_value else try b.addInst(.{
        .tag = .undefined,
        .data = .{ .none = {} },
    });
    const else_br = try b.addInstDeferred(.br);

    const end_label = try b.addLabel();

    test_br_cond.set(.{ .br_cond = .{
        .condition = test_result,
        .then_target = then_label,
        .else_target = else_label,
    } });
    then_br.set(.{ .br = .{
        .target = end_label,
        .value = then_result,
    } });
    else_br.set(.{ .br = .{
        .target = end_label,
        .value = else_result,
    } });

    return end_label;
}

fn lowerBreakableStatement(b: *Builder, brk_stmt: *const ast.BreakableStatement, label: ?[]const u8) Error!Ir.Inst.Ref {
    return switch (brk_stmt.*) {
        .iteration_statement => |iter_stmt| switch (iter_stmt) {
            .do_while_statement => |*do_while_stmt| try b.lowerDoWhileStatement(do_while_stmt, label),
            .while_statement => |*while_stmt| try b.lowerWhileStatement(while_stmt, label),
            .for_statement => |*for_stmt| try b.lowerForStatement(for_stmt, label),
            .for_in_of_statement => |*for_in_of_stmt| try b.lowerForInOfStatement(for_in_of_stmt, label),
        },
        .switch_statement => |*switch_stmt| try b.lowerSwitchStatement(switch_stmt, label),
    };
}

fn lowerBreakableStatementList(b: *Builder, stmt_list: *const ast.StatementList, ctx: *BreakableContext) Error!void {
    for (stmt_list.items) |item| {
        const result = switch (item) {
            .statement => |stmt| try b.lowerStatement(stmt),
            .declaration => |decl| try b.lowerDeclaration(decl),
        };
        if (result != .none) ctx.result_ref = result;
    }
}

fn lowerDoWhileStatement(b: *Builder, do_while_stmt: *const ast.DoWhileStatement, label: ?[]const u8) Error!Ir.Inst.Ref {
    const body_label = try b.addLabel();

    const undefined_ref = try b.addInst(.{
        .tag = .undefined,
        .data = .{ .none = {} },
    });

    const breakable_ctx = try b.pushBreakableContext(.{
        .label = label,
        .continue_target = .{ .deferred = .empty },
        .break_target = .{ .deferred = .empty },
        .result_ref = undefined_ref,
    });
    defer b.popBreakableContext();

    const body_block_stmt: *const ast.BlockStatement = switch (do_while_stmt.consequent_statement.*) {
        .block_statement => |*block_stmt| block_stmt,
        else => &.{ .block = .{ .statement_list = .{ .items = &.{
            .{ .statement = do_while_stmt.consequent_statement },
        } } } },
    };
    _ = try b.lowerBlockStatement(body_block_stmt, breakable_ctx);
    const body_result = breakable_ctx.result_ref;
    const body_br = try b.addInstDeferred(.br);

    const test_label = try b.addLabel();
    const test_result = try b.addInst(.{
        .tag = .to_boolean,
        .data = .{ .ref = try b.lowerExpression(&do_while_stmt.test_expression) },
    });
    const test_br_cond = try b.addInstDeferred(.br_cond);

    const continue_label = try b.addLabel();
    const continue_br = try b.addInstDeferred(.br);

    const exit_label = try b.addLabel();
    const exit_br = try b.addInstDeferred(.br);

    const end_label = try b.addLabel();

    breakable_ctx.setDeferredContinues(test_label);
    breakable_ctx.setDeferredBreaks(end_label);

    body_br.set(.{ .br = .{
        .target = test_label,
        .value = body_result,
    } });
    test_br_cond.set(.{ .br_cond = .{
        .condition = test_result,
        .then_target = continue_label,
        .else_target = exit_label,
    } });
    continue_br.set(.{ .br = .{
        .target = body_label,
        .value = test_label,
    } });
    exit_br.set(.{ .br = .{
        .target = end_label,
        .value = test_label,
    } });

    return end_label;
}

fn lowerWhileStatement(b: *Builder, while_stmt: *const ast.WhileStatement, label: ?[]const u8) Error!Ir.Inst.Ref {
    if (try constantFold(b.gpa, &while_stmt.test_expression)) |constant| {
        defer constant.deinit(b.gpa);
        if (!constant.isTruthy()) {
            return try b.addInst(.{
                .tag = .undefined,
                .data = .{ .none = {} },
            });
        }
    }

    const undefined_ref = try b.addInst(.{
        .tag = .undefined,
        .data = .{ .none = {} },
    });
    const entry_br = try b.addInstDeferred(.br);

    const test_label = try b.addLabel();
    const test_result = try b.addInst(.{
        .tag = .to_boolean,
        .data = .{ .ref = try b.lowerExpression(&while_stmt.test_expression) },
    });
    const test_br_cond = try b.addInstDeferred(.br_cond);

    const body_label = try b.addLabel();

    const breakable_ctx = try b.pushBreakableContext(.{
        .label = label,
        .continue_target = .{ .known = test_label },
        .break_target = .{ .deferred = .empty },
        .result_ref = undefined_ref,
    });
    defer b.popBreakableContext();

    const body_block_stmt: *const ast.BlockStatement = switch (while_stmt.consequent_statement.*) {
        .block_statement => |*block_stmt| block_stmt,
        else => &.{ .block = .{ .statement_list = .{ .items = &.{
            .{ .statement = while_stmt.consequent_statement },
        } } } },
    };
    _ = try b.lowerBlockStatement(body_block_stmt, breakable_ctx);
    const body_result = breakable_ctx.result_ref;
    const body_br = try b.addInstDeferred(.br);

    const exit_label = try b.addLabel();
    const exit_br = try b.addInstDeferred(.br);

    const end_label = try b.addLabel();

    breakable_ctx.setDeferredBreaks(end_label);

    entry_br.set(.{ .br = .{
        .target = test_label,
        .value = undefined_ref,
    } });
    test_br_cond.set(.{ .br_cond = .{
        .condition = test_result,
        .then_target = body_label,
        .else_target = exit_label,
    } });
    body_br.set(.{ .br = .{
        .target = test_label,
        .value = body_result,
    } });
    exit_br.set(.{ .br = .{
        .target = end_label,
        .value = test_label,
    } });

    return end_label;
}

fn lowerForStatement(b: *Builder, for_stmt: *const ast.ForStatement, label: ?[]const u8) Error!Ir.Inst.Ref {
    const has_scope, const has_using = blk: {
        if (for_stmt.initializer) |initializer| switch (initializer) {
            .lexical_declaration => |lex_decl| {
                const has_using = switch (lex_decl.type) {
                    .using, .await_using => true,
                    else => false,
                };
                break :blk .{ true, has_using };
            },
            else => {},
        };
        break :blk .{ false, false };
    };

    if (has_scope) {
        const lex_decl = &for_stmt.initializer.?.lexical_declaration;
        _ = try b.addInst(.{
            .tag = .push_scope,
            .data = .{ .none = {} },
        });
        b.scope_depth += 1;

        const binding_tag: Ir.Inst.Tag = if (lex_decl.isConstantDeclaration())
            .create_immutable_binding
        else
            .create_mutable_binding;
        for (lex_decl.binding_list.items) |lex_binding| {
            switch (lex_binding) {
                .binding_identifier => |binding| {
                    const string_index = try b.internString(binding.binding_identifier);
                    _ = try b.addInst(.{
                        .tag = binding_tag,
                        .data = .{ .string = string_index },
                    });
                },
                .binding_pattern => |pattern| {
                    var bound_names: std.ArrayList(ast.Identifier) = .empty;
                    defer bound_names.deinit(b.gpa);
                    try pattern.binding_pattern.collectBoundNames(b.gpa, &bound_names);
                    for (bound_names.items) |name| {
                        const string_index = try b.internString(name);
                        _ = try b.addInst(.{
                            .tag = binding_tag,
                            .data = .{ .string = string_index },
                        });
                    }
                },
            }
        }
    }

    if (for_stmt.initializer) |initializer| {
        _ = switch (initializer) {
            .expression => |*expr| try b.lowerExpression(expr),
            .variable_statement => |*var_stmt| try b.lowerVariableStatement(var_stmt),
            .lexical_declaration => |*lex_decl| try b.lowerLexicalDeclaration(lex_decl),
        };
    }

    if (for_stmt.test_expression) |*test_expr| {
        if (try constantFold(b.gpa, test_expr)) |constant| {
            defer constant.deinit(b.gpa);
            if (!constant.isTruthy()) {
                if (has_scope) {
                    if (has_using) {
                        _ = try b.addInst(.{
                            .tag = .dispose_resources,
                            .data = .{ .none = {} },
                        });
                    }
                    _ = try b.addInst(.{
                        .tag = .pop_scope,
                        .data = .{ .none = {} },
                    });
                    b.scope_depth -= 1;
                }
                return b.addInst(.{
                    .tag = .undefined,
                    .data = .{ .none = {} },
                });
            }
        }
    }

    const undefined_ref = try b.addInst(.{
        .tag = .undefined,
        .data = .{ .none = {} },
    });
    const entry_br = try b.addInstDeferred(.br);

    const test_label = try b.addLabel();
    const test_result = if (for_stmt.test_expression) |*test_expr|
        try b.addInst(.{
            .tag = .to_boolean,
            .data = .{ .ref = try b.lowerExpression(test_expr) },
        })
    else
        try b.addInst(.{
            .tag = .true,
            .data = .{ .none = {} },
        });
    const test_br_cond = try b.addInstDeferred(.br_cond);

    const body_label = try b.addLabel();

    const breakable_ctx = try b.pushBreakableContext(.{
        .label = label,
        .continue_target = .{ .deferred = .empty },
        .break_target = .{ .deferred = .empty },
        .result_ref = undefined_ref,
    });
    defer b.popBreakableContext();

    const body_block_stmt: *const ast.BlockStatement = switch (for_stmt.consequent_statement.*) {
        .block_statement => |*block_stmt| block_stmt,
        else => &.{ .block = .{ .statement_list = .{ .items = &.{
            .{ .statement = for_stmt.consequent_statement },
        } } } },
    };
    _ = try b.lowerBlockStatement(body_block_stmt, breakable_ctx);
    const body_result = breakable_ctx.result_ref;

    const body_br = try b.addInstDeferred(.br);

    const continue_label = try b.addLabel();
    if (for_stmt.increment_expression) |*update_expr| {
        _ = try b.lowerExpression(update_expr);
    }
    const continue_br = try b.addInstDeferred(.br);

    const exit_label = try b.addLabel();
    const exit_br = try b.addInstDeferred(.br);

    const end_label = try b.addLabel();

    if (has_scope) {
        if (has_using) {
            _ = try b.addInst(.{
                .tag = .dispose_resources,
                .data = .{ .none = {} },
            });
        }
        _ = try b.addInst(.{
            .tag = .pop_scope,
            .data = .{ .none = {} },
        });
        b.scope_depth -= 1;
    }

    breakable_ctx.setDeferredContinues(continue_label);
    breakable_ctx.setDeferredBreaks(end_label);

    entry_br.set(.{ .br = .{
        .target = test_label,
        .value = undefined_ref,
    } });
    test_br_cond.set(.{ .br_cond = .{
        .condition = test_result,
        .then_target = body_label,
        .else_target = exit_label,
    } });
    body_br.set(.{ .br = .{
        .target = continue_label,
        .value = body_result,
    } });
    continue_br.set(.{ .br = .{
        .target = test_label,
        .value = continue_label,
    } });
    exit_br.set(.{ .br = .{
        .target = end_label,
        .value = test_label,
    } });

    return end_label;
}

const IterationKind = enum {
    enumerate,
    iterate,
    async_iterate,
};

const ForInOfHeadEvaluation = struct {
    iterator: Ir.Inst.Ref,
    skip_br_cond: ?Deferred,
};

/// 14.7.5.6 ForIn/OfHeadEvaluation ( uninitializedBoundNames, expr, iterationKind )
/// https://tc39.es/ecma262/#sec-runtime-semantics-forinofheadevaluation
fn lowerForInOfHeadEvaluation(
    b: *Builder,
    uninitialized_bound_names: []const ast.Identifier,
    expr: *const ast.Expression,
    iteration_kind: IterationKind,
) Error!ForInOfHeadEvaluation {
    // 1. Let oldEnv be the running execution context's LexicalEnvironment.

    // 2. If uninitializedBoundNames is not empty, then
    if (uninitialized_bound_names.len > 0) {
        // a. Assert: uninitializedBoundNames has no duplicate entries.
        // b. Let newEnv be NewDeclarativeEnvironment(oldEnv).
        _ = try b.addInst(.{
            .tag = .push_scope,
            .data = .{ .none = {} },
        });
        b.scope_depth += 1;

        // c. For each String name of uninitializedBoundNames, do
        for (uninitialized_bound_names) |name| {
            // i. Perform ! newEnv.CreateMutableBinding(name, false).
            const string_index = try b.internString(name);
            _ = try b.addInst(.{
                .tag = .create_mutable_binding,
                .data = .{ .string = string_index },
            });
        }

        // d. Set the running execution context's LexicalEnvironment to newEnv.
    }

    // 3. Let exprRef be Completion(Evaluation of expr).
    const expr_value = try b.lowerExpression(expr);

    // 4. Set the running execution context's LexicalEnvironment to oldEnv.
    if (uninitialized_bound_names.len > 0) {
        _ = try b.addInst(.{
            .tag = .pop_scope,
            .data = .{ .none = {} },
        });
        b.scope_depth -= 1;
    }

    // 5. Let exprValue be ? GetValue(? exprRef).
    // 6. If iterationKind is enumerate, then
    //    a. If exprValue is either undefined or null, then
    //       i. Return Completion Record { [[Type]]: break, [[Value]]: empty, [[Target]]: empty }.
    //    b. Let obj be ! ToObject(exprValue).
    //    c. Let iterator be EnumerateObjectProperties(obj).
    //    d. Let nextMethod be ! GetV(iterator, "next").
    //    e. Return the Iterator Record { [[Iterator]]: iterator, [[NextMethod]]: nextMethod,
    //       [[Done]]: false }.
    // 7. Assert: iterationKind is either iterate or async-iterate.
    // 8. If iterationKind is async-iterate, let iteratorKind be async.
    // 9. Else, let iteratorKind be sync.
    // 10. Return ? GetIterator(exprValue, iteratorKind).
    var skip_br_cond: ?Deferred = null;
    if (iteration_kind == .enumerate) {
        const is_nullish = try b.addInst(.{
            .tag = .is_nullish,
            .data = .{ .ref = expr_value },
        });
        skip_br_cond = try b.addInstDeferred(.br_cond);
        const setup_label = try b.addLabel();
        skip_br_cond.?.set(.{ .br_cond = .{
            .condition = is_nullish,
            .then_target = .none,
            .else_target = setup_label,
        } });
    }
    const iterator = try b.addInst(.{
        .tag = switch (iteration_kind) {
            .enumerate => .get_for_in_iterator,
            .iterate => .get_iterator,
            .async_iterate => .get_async_iterator,
        },
        .data = .{ .ref = expr_value },
    });

    return .{
        .iterator = iterator,
        .skip_br_cond = skip_br_cond,
    };
}

fn lowerForInOfStatement(b: *Builder, for_in_of_stmt: *const ast.ForInOfStatement, label: ?[]const u8) Error!Ir.Inst.Ref {
    const has_scope, const has_using = blk: {
        switch (for_in_of_stmt.initializer) {
            .for_declaration => |*for_decl| {
                const has_using = switch (for_decl.type) {
                    .using, .await_using => true,
                    else => false,
                };
                break :blk .{ true, has_using };
            },
            else => {},
        }
        break :blk .{ false, false };
    };

    const iteration_kind: IterationKind = switch (for_in_of_stmt.type) {
        .in => .enumerate,
        .of => .iterate,
        .async_of => .async_iterate,
    };

    var uninitialized_bound_names: std.ArrayList(ast.Identifier) = .empty;
    defer uninitialized_bound_names.deinit(b.gpa);
    switch (for_in_of_stmt.initializer) {
        .for_declaration => |for_decl| {
            try for_decl.for_binding.collectBoundNames(b.gpa, &uninitialized_bound_names);
        },
        else => {},
    }

    const undefined_ref = try b.addInst(.{
        .tag = .undefined,
        .data = .{ .none = {} },
    });

    const head_eval = try b.lowerForInOfHeadEvaluation(
        uninitialized_bound_names.items,
        &for_in_of_stmt.expression,
        iteration_kind,
    );
    const iterator = head_eval.iterator;

    var skip_label: Ir.Inst.Ref = .none;
    var skip_br: Deferred = undefined;

    const entry_br = try b.addInstDeferred(.br);

    const test_label = try b.addLabel();

    const next_value = try b.addInst(.{
        .tag = if (iteration_kind == .async_iterate) .iterator_step_value_async else .iterator_step_value,
        .data = .{ .ref = iterator },
    });
    const is_done = try b.addInst(.{
        .tag = .iterator_is_done,
        .data = .{ .ref = iterator },
    });
    // NOTE: We invert the condition to ensure the body block (then target, else target by default)
    //       is placed within the surrounding try/catch handler ranges during block linearization.
    //       (Yes, this is a hack.)
    const should_continue = try b.addInst(.{
        .tag = .logical_not,
        .data = .{ .ref = is_done },
    });
    const test_br_cond = try b.addInstDeferred(.br_cond);

    const body_label = try b.addLabel();

    const breakable_ctx = try b.pushBreakableContext(.{
        .label = label,
        .continue_target = .{ .deferred = .empty },
        .break_target = .{ .deferred = .empty },
        .result_ref = undefined_ref,
        .iterator_ref = if (iteration_kind != .enumerate) iterator else .none,
    });
    defer b.popBreakableContext();

    switch (for_in_of_stmt.initializer) {
        .expression => |*expr| switch (expr.*) {
            .primary_expression => |prim_expr| switch (prim_expr) {
                .identifier_reference => |identifier| {
                    const string_index = try b.internString(identifier);
                    _ = try b.addInst(.{
                        .tag = if (b.in_strict_mode) .set_binding_strict else .set_binding,
                        .data = .{ .set_binding = .{
                            .name = string_index,
                            .value = next_value,
                        } },
                    });
                },
                else => unreachable,
            },
            .member_expression => |*member_expr| {
                const base = try b.lowerExpression(member_expr.expression);
                switch (member_expr.property) {
                    .identifier => |identifier| {
                        const string_index = try b.internString(identifier);
                        const tag: Ir.Inst.Tag = if (b.in_strict_mode)
                            .set_property_strict
                        else
                            .set_property;
                        const extra_index = try b.addExtra(Ir.Inst.SetProperty, .{
                            .base = base,
                            .name = string_index,
                            .value = next_value,
                        });
                        _ = try b.addInst(.{
                            .tag = tag,
                            .data = .{ .set_property = extra_index },
                        });
                    },
                    .expression => |prop_expr| blk: {
                        if (try constantFold(b.gpa, prop_expr)) |constant| {
                            defer constant.deinit(b.gpa);
                            if (constant.toIndex()) |index| {
                                const tag: Ir.Inst.Tag = if (b.in_strict_mode)
                                    .set_property_indexed_strict
                                else
                                    .set_property_indexed;
                                const extra_index = try b.addExtra(Ir.Inst.SetPropertyIndexed, .{
                                    .base = base,
                                    .index = index,
                                    .value = next_value,
                                });
                                _ = try b.addInst(.{
                                    .tag = tag,
                                    .data = .{ .set_property_indexed = extra_index },
                                });
                                break :blk;
                            }
                        }
                        const property = try b.lowerExpression(prop_expr);
                        const tag: Ir.Inst.Tag = if (b.in_strict_mode)
                            .set_property_computed_strict
                        else
                            .set_property_computed;
                        const extra_index = try b.addExtra(Ir.Inst.SetPropertyComputed, .{
                            .base = base,
                            .property = property,
                            .value = next_value,
                        });
                        _ = try b.addInst(.{
                            .tag = tag,
                            .data = .{ .set_property_computed = extra_index },
                        });
                    },
                    .private_identifier => |private_identifier| {
                        const string_index = try b.internString(private_identifier);
                        const extra_index = try b.addExtra(Ir.Inst.SetProperty, .{
                            .base = base,
                            .name = string_index,
                            .value = next_value,
                        });
                        _ = try b.addInst(.{
                            .tag = .set_private_element,
                            .data = .{ .set_property = extra_index },
                        });
                    },
                }
            },
            .super_property => |super_prop| switch (super_prop) {
                .identifier => |identifier| {
                    const string_index = try b.internString(identifier);
                    const tag: Ir.Inst.Tag = if (b.in_strict_mode)
                        .set_super_property_strict
                    else
                        .set_super_property;
                    const extra_index = try b.addExtra(Ir.Inst.SetProperty, .{
                        .base = .none,
                        .name = string_index,
                        .value = next_value,
                    });
                    _ = try b.addInst(.{
                        .tag = tag,
                        .data = .{ .set_property = extra_index },
                    });
                },
                .expression => |prop_expr| {
                    const property = try b.lowerExpression(prop_expr);
                    const tag: Ir.Inst.Tag = if (b.in_strict_mode)
                        .set_super_property_computed_strict
                    else
                        .set_super_property_computed;
                    const extra_index = try b.addExtra(Ir.Inst.SetPropertyComputed, .{
                        .base = .none,
                        .property = property,
                        .value = next_value,
                    });
                    _ = try b.addInst(.{
                        .tag = tag,
                        .data = .{ .set_property_computed = extra_index },
                    });
                },
            },
            .assignment_pattern => |*assignment_pattern| {
                _ = try b.lowerAssignmentPattern(assignment_pattern, next_value);
            },
            .call_expression => |*call_expr| {
                _ = try b.lowerCallExpression(call_expr);
                _ = try b.addInst(.{
                    .tag = .throw_reference_error,
                    .data = .{ .none = {} },
                });
            },
            else => unreachable,
        },
        .for_binding => |for_binding| switch (for_binding) {
            .binding_identifier => |identifier| {
                const string_index = try b.internString(identifier);
                const tag: Ir.Inst.Tag = if (b.in_strict_mode)
                    .set_binding_strict
                else
                    .set_binding;
                _ = try b.addInst(.{
                    .tag = tag,
                    .data = .{ .set_binding = .{
                        .name = string_index,
                        .value = next_value,
                    } },
                });
            },
            .binding_pattern => |*binding_pattern| {
                _ = try b.lowerBindingPattern(binding_pattern, next_value, .set);
            },
        },
        .for_declaration => |for_decl| {
            _ = try b.addInst(.{
                .tag = .push_scope,
                .data = .{ .none = {} },
            });
            b.scope_depth += 1;

            switch (for_decl.for_binding) {
                .binding_identifier => |identifier| {
                    const tag: Ir.Inst.Tag = switch (for_decl.type) {
                        .let => .create_mutable_binding,
                        .@"const", .using, .await_using => .create_immutable_binding,
                    };
                    const string_index = try b.internString(identifier);
                    _ = try b.addInst(.{
                        .tag = tag,
                        .data = .{ .string = string_index },
                    });
                    switch (for_decl.type) {
                        .using => _ = try b.addInst(.{
                            .tag = .add_disposable_resource_sync,
                            .data = .{ .ref = next_value },
                        }),
                        .await_using => _ = try b.addInst(.{
                            .tag = .add_disposable_resource_async,
                            .data = .{ .ref = next_value },
                        }),
                        else => {},
                    }
                    _ = try b.addInst(.{
                        .tag = .initialize_binding,
                        .data = .{ .set_binding = .{
                            .name = string_index,
                            .value = next_value,
                        } },
                    });
                },
                .binding_pattern => |*binding_pattern| {
                    const tag: Ir.Inst.Tag = switch (for_decl.type) {
                        .let => .create_mutable_binding,
                        .@"const" => .create_immutable_binding,
                        .using, .await_using => unreachable,
                    };
                    var bound_names: std.ArrayList(ast.Identifier) = .empty;
                    defer bound_names.deinit(b.gpa);
                    try binding_pattern.collectBoundNames(b.gpa, &bound_names);
                    for (bound_names.items) |name| {
                        const string_index = try b.internString(name);
                        _ = try b.addInst(.{
                            .tag = tag,
                            .data = .{ .string = string_index },
                        });
                    }
                    _ = try b.lowerBindingPattern(binding_pattern, next_value, .initialize);
                },
            }
        },
    }

    const body_block_stmt: *const ast.BlockStatement = switch (for_in_of_stmt.consequent_statement.*) {
        .block_statement => |*block_stmt| block_stmt,
        else => &.{ .block = .{ .statement_list = .{ .items = &.{
            .{ .statement = for_in_of_stmt.consequent_statement },
        } } } },
    };
    _ = try b.lowerBlockStatement(body_block_stmt, breakable_ctx);

    if (has_scope) {
        if (has_using) {
            _ = try b.addInst(.{
                .tag = .dispose_resources,
                .data = .{ .none = {} },
            });
        }
        _ = try b.addInst(.{
            .tag = .pop_scope,
            .data = .{ .none = {} },
        });
        b.scope_depth -= 1;
    }

    const body_result = breakable_ctx.result_ref;
    const body_br = try b.addInstDeferred(.br);

    const exit_label = try b.addLabel();
    const exit_br = try b.addInstDeferred(.br);

    if (iteration_kind == .enumerate) {
        skip_label = try b.addLabel();
        skip_br = try b.addInstDeferred(.br);
    }

    const end_label = try b.addLabel();

    breakable_ctx.setDeferredContinues(test_label);
    breakable_ctx.setDeferredBreaks(end_label);

    if (head_eval.skip_br_cond) |skip_br_cond| {
        const inst = b.instructions.get(@backingInt(skip_br_cond.index));
        const extra_index = @backingInt(inst.data.br_cond);
        // Set then_target which was initialized as .none
        b.extra.items[extra_index + 1] = @backingInt(skip_label);
        skip_br.set(.{ .br = .{
            .target = end_label,
            .value = undefined_ref,
        } });
    }
    entry_br.set(.{ .br = .{
        .target = test_label,
        .value = undefined_ref,
    } });
    test_br_cond.set(.{ .br_cond = .{
        .condition = should_continue,
        .then_target = body_label,
        .else_target = exit_label,
    } });
    body_br.set(.{ .br = .{
        .target = test_label,
        .value = body_result,
    } });
    exit_br.set(.{ .br = .{
        .target = end_label,
        .value = test_label,
    } });

    return end_label;
}

fn lowerSwitchStatement(b: *Builder, switch_stmt: *const ast.SwitchStatement, label: ?[]const u8) Error!Ir.Inst.Ref {
    const discriminant = try b.lowerExpression(&switch_stmt.expression);

    var lexical_decls: std.ArrayList(ast.LexicallyScopedDeclaration) = .empty;
    defer lexical_decls.deinit(b.gpa);
    try switch_stmt.case_block.collectLexicallyScopedDeclarations(b.gpa, &lexical_decls);

    const has_scope = lexical_decls.items.len > 0;

    if (has_scope) {
        _ = try b.addInst(.{
            .tag = .push_scope,
            .data = .{ .none = {} },
        });
        b.scope_depth += 1;
        try b.lowerBlockDeclarationInstantiation(.{ .case_block = &switch_stmt.case_block });
    }

    const undefined_ref = try b.addInst(.{
        .tag = .undefined,
        .data = .{ .none = {} },
    });
    const entry_br = try b.addInstDeferred(.br);

    const breakable_ctx = try b.pushBreakableContext(.{
        .label = label,
        .continue_target = .{ .deferred = .empty },
        .break_target = .{ .deferred = .empty },
        .result_ref = undefined_ref,
    });
    defer b.popBreakableContext();

    const items = switch_stmt.case_block.items;

    var case_branches: std.ArrayList(struct { br_cond: Deferred, index: u32 }) = .empty;
    defer case_branches.deinit(b.gpa);

    var default_index: ?u32 = null;

    const check_start = try b.addLabel();
    for (items, 0..) |item, i| {
        switch (item) {
            .case_clause => |case_clause| {
                const case_value = try b.lowerExpression(&case_clause.expression);
                const condition = try b.addInst(.{
                    .tag = .eq_strict,
                    .data = .{ .binary = .{
                        .lhs = discriminant,
                        .rhs = case_value,
                    } },
                });
                const case_br_cond = try b.addInstDeferred(.br_cond);
                try case_branches.append(b.gpa, .{
                    .br_cond = case_br_cond,
                    .index = @intCast(i),
                });

                const next_check = try b.addLabel();
                case_br_cond.set(.{ .br_cond = .{
                    .condition = condition,
                    .then_target = .none,
                    .else_target = next_check,
                } });
            },
            .default_clause => default_index = @intCast(i),
        }
    }
    const default_br = try b.addInstDeferred(.br);

    const body_labels = try b.gpa.alloc(Ir.Inst.Ref, items.len);
    defer b.gpa.free(body_labels);
    for (items, 0..) |item, i| {
        body_labels[i] = try b.addLabel();
        switch (item) {
            .case_clause => |case_clause| try b.lowerBreakableStatementList(&case_clause.statement_list, breakable_ctx),
            .default_clause => |default_clause| try b.lowerBreakableStatementList(&default_clause.statement_list, breakable_ctx),
        }
    }

    const exit_br = try b.addInstDeferred(.br);

    const end_label = try b.addLabel();

    if (has_scope) {
        _ = try b.addInst(.{
            .tag = .pop_scope,
            .data = .{ .none = {} },
        });
        b.scope_depth -= 1;
    }

    breakable_ctx.setDeferredBreaks(end_label);

    // Forward continues to parent context
    if (b.breakable_stack.items.len >= 2) {
        const parent_ctx = b.breakable_stack.items[b.breakable_stack.items.len - 2];
        for (breakable_ctx.continue_target.deferred.items) |jump| {
            switch (parent_ctx.continue_target) {
                .known => |target| jump.inst.set(.{ .br = .{
                    .target = target,
                    .value = jump.value,
                } }),
                .deferred => |*list| try list.append(b.gpa, jump),
            }
        }
    }

    entry_br.set(.{ .br = .{
        .target = check_start,
        .value = undefined_ref,
    } });
    for (case_branches.items) |item| {
        const inst = b.instructions.get(@backingInt(item.br_cond.index));
        const extra_index = @backingInt(inst.data.br_cond);
        // Set then_target which was initialized as .none
        b.extra.items[extra_index + 1] = @backingInt(body_labels[item.index]);
    }
    default_br.set(.{ .br = .{
        .target = if (default_index) |index| body_labels[index] else end_label,
        .value = undefined_ref,
    } });
    exit_br.set(.{ .br = .{
        .target = end_label,
        .value = breakable_ctx.result_ref,
    } });

    return end_label;
}

fn lowerContinueStatement(b: *Builder, cont_stmt: *const ast.ContinueStatement) Error!Ir.Inst.Ref {
    const current_ctx = b.breakable_stack.last().?;
    const target_ctx = b.findBreakableContext(cont_stmt.label);
    const value = current_ctx.result_ref;

    var it = std.mem.reverseIterator(b.breakable_stack.items);
    while (it.next()) |ctx| {
        if (ctx == target_ctx) break;
        if (ctx.iterator_ref != .none) {
            _ = try b.addInst(.{
                .tag = .iterator_close,
                .data = .{ .ref = ctx.iterator_ref },
            });
        }
    }

    const scope_pops = b.scope_depth - target_ctx.scope_depth;
    for (0..scope_pops) |_| {
        _ = try b.addInst(.{
            .tag = .pop_scope,
            .data = .{ .none = {} },
        });
    }

    switch (target_ctx.continue_target) {
        .known => |target| {
            _ = try b.addInst(.{
                .tag = .br,
                .data = .{ .br = .{
                    .target = target,
                    .value = value,
                } },
            });
        },
        .deferred => |*list| {
            const deferred = try b.addInstDeferred(.br);
            try list.append(b.gpa, .{
                .inst = deferred,
                .value = value,
            });
        },
    }
    return .none;
}

fn lowerBreakStatement(b: *Builder, brk_stmt: *const ast.BreakStatement) Error!Ir.Inst.Ref {
    const current_ctx = b.breakable_stack.last().?;
    const target_ctx = b.findBreakableContext(brk_stmt.label);
    const value = current_ctx.result_ref;

    var it = std.mem.reverseIterator(b.breakable_stack.items);
    while (it.next()) |ctx| {
        if (ctx.iterator_ref != .none) {
            _ = try b.addInst(.{
                .tag = .iterator_close,
                .data = .{ .ref = ctx.iterator_ref },
            });
        }
        if (ctx == target_ctx) break;
    }

    const scope_pops = b.scope_depth - target_ctx.scope_depth;
    for (0..scope_pops) |_| {
        _ = try b.addInst(.{
            .tag = .pop_scope,
            .data = .{ .none = {} },
        });
    }

    switch (target_ctx.break_target) {
        .known => |target| {
            _ = try b.addInst(.{
                .tag = .br,
                .data = .{ .br = .{
                    .target = target,
                    .value = value,
                } },
            });
        },
        .deferred => |*list| {
            const deferred = try b.addInstDeferred(.br);
            try list.append(b.gpa, .{
                .inst = deferred,
                .value = value,
            });
        },
    }
    return .none;
}

fn lowerReturnStatement(b: *Builder, ret_stmt: *const ast.ReturnStatement) Error!Ir.Inst.Ref {
    const value = if (ret_stmt.expression) |*expr|
        try b.lowerExpression(expr)
    else
        Ir.Inst.Ref.none;

    var it = std.mem.reverseIterator(b.breakable_stack.items);
    while (it.next()) |ctx| {
        if (ctx.iterator_ref != .none) {
            _ = try b.addInst(.{
                .tag = .iterator_close,
                .data = .{ .ref = ctx.iterator_ref },
            });
        }
    }

    _ = try b.addInst(.{
        .tag = .@"return",
        .data = .{ .ref = value },
    });
    return .none;
}

fn lowerWithStatement(b: *Builder, with_stmt: *const ast.WithStatement) Error!Ir.Inst.Ref {
    const expr_value = try b.lowerExpression(&with_stmt.expression);
    const object = try b.addInst(.{
        .tag = .to_object,
        .data = .{ .ref = expr_value },
    });

    _ = try b.addInst(.{
        .tag = .push_with_scope,
        .data = .{ .ref = object },
    });
    b.scope_depth += 1;

    const value = try b.lowerStatement(with_stmt.statement);
    const result = if (value != .none) value else try b.addInst(.{
        .tag = .undefined,
        .data = .{ .none = {} },
    });

    _ = try b.addInst(.{
        .tag = .pop_scope,
        .data = .{ .none = {} },
    });
    b.scope_depth -= 1;

    return result;
}

fn lowerLabelledStatement(b: *Builder, lbl_stmt: *const ast.LabelledStatement) Error!Ir.Inst.Ref {
    const label = lbl_stmt.label_identifier;
    return switch (lbl_stmt.labelled_item) {
        .statement => |stmt| switch (stmt.*) {
            .breakable_statement => |*brk_stmt| try b.lowerBreakableStatement(brk_stmt, label),
            else => {
                const undefined_ref = try b.addInst(.{
                    .tag = .undefined,
                    .data = .{ .none = {} },
                });

                const breakable_ctx = try b.pushBreakableContext(.{
                    .label = label,
                    .continue_target = .{ .deferred = .empty },
                    .break_target = .{ .deferred = .empty },
                    .result_ref = undefined_ref,
                });
                defer b.popBreakableContext();

                const result = switch (stmt.*) {
                    .block_statement => |*block_stmt| try b.lowerBlockStatement(block_stmt, breakable_ctx),
                    else => try b.lowerStatement(stmt),
                };
                if (result != .none) breakable_ctx.result_ref = result;

                const result_br = try b.addInstDeferred(.br);

                const end_label = try b.addLabel();
                breakable_ctx.setDeferredBreaks(end_label);

                result_br.set(.{ .br = .{
                    .target = end_label,
                    .value = breakable_ctx.result_ref,
                } });

                return end_label;
            },
        },
        .function_declaration => .none, // Handled by GDI/FDI before execution
    };
}

fn lowerThrowStatement(b: *Builder, throw_stmt: *const ast.ThrowStatement) Error!Ir.Inst.Ref {
    const value = try b.lowerExpression(&throw_stmt.expression);
    _ = try b.addInst(.{
        .tag = .throw,
        .data = .{ .ref = value },
    });
    return .none;
}

fn lowerTryStatement(b: *Builder, try_stmt: *const ast.TryStatement) Error!Ir.Inst.Ref {
    const scope_depth = b.scope_depth;

    const try_label = try b.addLabel();
    const try_value = try b.lowerBlock(&try_stmt.try_block, null);
    const try_result = if (try_value != .none) try_value else try b.addInst(.{
        .tag = .undefined,
        .data = .{ .none = {} },
    });

    const try_end_label = try b.addLabel();
    const try_end_br = try b.addInstDeferred(.br);

    var catch_label: Ir.Inst.Ref = undefined;
    var catch_handler: Deferred = undefined;
    var catch_result: Ir.Inst.Ref = undefined;
    var catch_br: Deferred = undefined;

    if (try_stmt.catch_block) |*catch_block| {
        catch_label = try b.addLabel();
        catch_handler = try b.addInstDeferred(.exception_handler);
        const exception_value = catch_handler.index.toRef();

        if (try_stmt.catch_parameter) |catch_parameter| {
            _ = try b.addInst(.{
                .tag = .push_catch_scope,
                .data = .{ .none = {} },
            });
            b.scope_depth += 1;

            var bound_names: std.ArrayList(ast.Identifier) = .empty;
            defer bound_names.deinit(b.gpa);
            try catch_parameter.collectBoundNames(b.gpa, &bound_names);
            for (bound_names.items) |name| {
                const string_index = try b.internString(name);
                _ = try b.addInst(.{
                    .tag = .create_mutable_binding,
                    .data = .{ .string = string_index },
                });
            }

            switch (catch_parameter) {
                .binding_identifier => |identifier| {
                    const string_index = try b.internString(identifier);
                    _ = try b.addInst(.{
                        .tag = .initialize_binding,
                        .data = .{ .set_binding = .{
                            .name = string_index,
                            .value = exception_value,
                        } },
                    });
                },
                .binding_pattern => |*binding_pattern| {
                    _ = try b.lowerBindingPattern(binding_pattern, exception_value, .initialize);
                },
            }
        }

        const catch_value = try b.lowerBlock(catch_block, null);
        catch_result = if (catch_value != .none) catch_value else try b.addInst(.{
            .tag = .undefined,
            .data = .{ .none = {} },
        });

        if (try_stmt.catch_parameter != null) {
            _ = try b.addInst(.{
                .tag = .pop_scope,
                .data = .{ .none = {} },
            });
            b.scope_depth -= 1;
        }

        catch_br = try b.addInstDeferred(.br);
    }

    var finally_throw_label: Ir.Inst.Ref = undefined;
    var finally_handler: Deferred = undefined;
    var finally_label: Ir.Inst.Ref = undefined;
    var finally_br: Deferred = undefined;

    if (try_stmt.finally_block) |*finally_block| {
        finally_throw_label = try b.addLabel();
        finally_handler = try b.addInstDeferred(.exception_handler);
        const exception_value = finally_handler.index.toRef();
        _ = try b.lowerBlock(finally_block, null);
        _ = try b.addInst(.{
            .tag = .throw,
            .data = .{ .ref = exception_value },
        });

        finally_label = try b.addLabel();
        _ = try b.lowerBlock(finally_block, null);
        finally_br = try b.addInstDeferred(.br);
    }

    const end_label = try b.addLabel();

    const normal_target = if (try_stmt.finally_block != null) finally_label else end_label;

    try_end_br.set(.{ .br = .{
        .target = normal_target,
        .value = try_result,
    } });

    if (try_stmt.catch_block != null) {
        catch_handler.set(.{ .exception_handler = .{
            .start = try_label,
            .end = try_end_label,
            .target = catch_label,
            .scope_depth = scope_depth,
        } });
        catch_br.set(.{ .br = .{
            .target = normal_target,
            .value = catch_result,
        } });
    }

    if (try_stmt.finally_block != null) {
        finally_handler.set(.{ .exception_handler = .{
            .start = if (try_stmt.catch_block != null) catch_label else try_label,
            .end = finally_throw_label,
            .target = finally_throw_label,
            .scope_depth = scope_depth,
        } });
        finally_br.set(.{ .br = .{
            .target = end_label,
            .value = finally_label,
        } });
    }

    return end_label;
}

fn lowerClassDeclaration(b: *Builder, class_decl: *const ast.ClassDeclaration) Error!Ir.Inst.Ref {
    const name: Ir.Class.Name = if (class_decl.identifier) |identifier|
        .{ .identifier = try b.internString(identifier) }
    else
        .{ .default = try b.internString("default") };

    const heritage = try b.lowerClassHeritage(class_decl.class_tail.class_heritage);

    _ = try b.addInst(.{
        .tag = .push_private_scope,
        .data = .{ .none = {} },
    });
    const element_names = try b.lowerClassElementNames(&class_decl.class_tail.class_body);

    const class_index = try b.addClass(.{
        .source_range = class_decl.source_range,
        .name = name,
        .class_tail = class_decl.class_tail,
        .heritage = heritage,
        .element_names = element_names,
    });
    const value = try b.addInst(.{
        .tag = .create_class,
        .data = .{ .create_class = class_index },
    });
    _ = try b.addInst(.{
        .tag = .pop_private_scope,
        .data = .{ .none = {} },
    });
    if (class_decl.identifier) |identifier| {
        const string_index = try b.internString(identifier);
        _ = try b.addInst(.{
            .tag = .initialize_binding,
            .data = .{ .set_binding = .{
                .name = string_index,
                .value = value,
            } },
        });
    }
    return value;
}

fn lowerLexicalDeclaration(b: *Builder, lex_decl: *const ast.LexicalDeclaration) Error!Ir.Inst.Ref {
    for (lex_decl.binding_list.items) |*lex_binding| {
        _ = try b.lowerLexicalBinding(lex_binding, lex_decl.type);
    }
    return .none;
}

fn lowerLexicalBinding(
    b: *Builder,
    lex_binding: *const ast.LexicalBinding,
    lex_decl_type: ast.LexicalDeclaration.Type,
) Error!Ir.Inst.Ref {
    // GlobalDeclarationInstantiation is responsible for creating the bindings.
    return switch (lex_binding.*) {
        .binding_identifier => |binding| {
            const value = if (binding.initializer) |*init_expr|
                try b.lowerExpression(init_expr)
            else
                try b.addInst(.{
                    .tag = .undefined,
                    .data = .{ .none = {} },
                });
            const string_index = try b.internString(binding.binding_identifier);
            if (binding.initializer != null and binding.initializer.?.isAnonymousFunctionDefinition()) {
                b.setAnonymousFunctionName(value, string_index);
            }
            switch (lex_decl_type) {
                .using => _ = try b.addInst(.{
                    .tag = .add_disposable_resource_sync,
                    .data = .{ .ref = value },
                }),
                .await_using => _ = try b.addInst(.{
                    .tag = .add_disposable_resource_async,
                    .data = .{ .ref = value },
                }),
                else => {},
            }
            return b.addInst(.{
                .tag = .initialize_binding,
                .data = .{ .set_binding = .{
                    .name = string_index,
                    .value = value,
                } },
            });
        },
        .binding_pattern => |p| {
            const value = try b.lowerExpression(&p.initializer);
            return try b.lowerBindingPattern(&p.binding_pattern, value, .initialize);
        },
    };
}

fn lowerPropertyName(b: *Builder, property_name: *const ast.PropertyName) Error!Ir.Inst.Ref {
    return switch (property_name.*) {
        .literal_property_name => |literal| switch (literal) {
            .identifier => |identifier| blk: {
                const string_index = try b.internString(identifier);
                break :blk try b.addInst(.{
                    .tag = .string,
                    .data = .{ .string = string_index },
                });
            },
            .string_literal => |str_lit| blk: {
                const expr: ast.Expression = .{
                    .primary_expression = .{
                        .literal = .{ .string = str_lit },
                    },
                };
                break :blk try b.lowerExpression(&expr);
            },
            .numeric_literal => |num_lit| blk: {
                const expr: ast.Expression = .{
                    .primary_expression = .{
                        .literal = .{ .numeric = num_lit },
                    },
                };
                break :blk try b.lowerExpression(&expr);
            },
        },
        .computed_property_name => |*expr| try b.lowerExpression(expr),
    };
}

fn lowerDefaultExpression(b: *Builder, value: Ir.Inst.Ref, default_expr: ?*const ast.Expression, anonymous_function_name: ?Ir.StringIndex) Error!Ir.Inst.Ref {
    if (default_expr) |expr| {
        const is_undefined = try b.addInst(.{
            .tag = .eq_strict,
            .data = .{ .binary = .{
                .lhs = value,
                .rhs = try b.addInst(.{
                    .tag = .undefined,
                    .data = .{ .none = {} },
                }),
            } },
        });
        const br_cond = try b.addInstDeferred(.br_cond);

        const then_label = try b.addInst(.{
            .tag = .label,
            .data = .{ .none = {} },
        });
        const default_value = try b.lowerExpression(expr);
        if (anonymous_function_name) |string_index| {
            b.setAnonymousFunctionName(default_value, string_index);
        }
        const then_br = try b.addInstDeferred(.br);

        const else_label = try b.addInst(.{
            .tag = .label,
            .data = .{ .none = {} },
        });
        const else_br = try b.addInstDeferred(.br);

        const end_label = try b.addInst(.{
            .tag = .label,
            .data = .{ .none = {} },
        });

        br_cond.set(.{ .br_cond = .{
            .condition = is_undefined,
            .then_target = then_label,
            .else_target = else_label,
        } });
        then_br.set(.{ .br = .{
            .target = end_label,
            .value = default_value,
        } });
        else_br.set(.{ .br = .{
            .target = end_label,
            .value = value,
        } });

        return end_label;
    }
    return value;
}

fn lowerAssignmentPattern(b: *Builder, pattern: *const ast.AssignmentPattern, value: Ir.Inst.Ref) Error!Ir.Inst.Ref {
    return switch (pattern.*) {
        .object_assignment_pattern => |*object_pattern| try b.lowerObjectAssignmentPattern(object_pattern, value),
        .array_assignment_pattern => |*array_pattern| try b.lowerArrayAssignmentPattern(array_pattern, value),
    };
}

fn lowerArrayAssignmentPattern(b: *Builder, pattern: *const ast.ArrayAssignmentPattern, array_value: Ir.Inst.Ref) Error!Ir.Inst.Ref {
    var last_ref: Ir.Inst.Ref = .none;

    const iterator_ref = try b.addInst(.{
        .tag = .get_iterator,
        .data = .{ .ref = array_value },
    });

    for (pattern.elements) |element| switch (element) {
        .elision => {
            _ = try b.addInst(.{
                .tag = .iterator_step,
                .data = .{ .ref = iterator_ref },
            });
        },
        .assignment_element => |assignment_element| {
            const next_value = try b.addInst(.{
                .tag = .iterator_step_value,
                .data = .{ .ref = iterator_ref },
            });
            switch (assignment_element.destructuring_assignment_target) {
                .assignment_pattern => |*assignment_pattern| {
                    const default_expr = if (assignment_element.initializer) |*expr| expr else null;
                    const value = try b.lowerDefaultExpression(next_value, default_expr, null);
                    last_ref = try b.lowerAssignmentPattern(assignment_pattern, value);
                },
                .identifier_reference => |identifier_reference| {
                    const string_index = try b.internString(identifier_reference);
                    const default_expr, const anonymous_function_name = if (assignment_element.initializer) |*expr|
                        .{ expr, if (expr.isAnonymousFunctionDefinition()) string_index else null }
                    else
                        .{ null, null };
                    const value = try b.lowerDefaultExpression(next_value, default_expr, anonymous_function_name);
                    last_ref = try b.lowerDestructuringAssignmentTarget(&assignment_element.destructuring_assignment_target, value);
                },
                .member_expression, .super_property => {
                    const default_expr = if (assignment_element.initializer) |*expr| expr else null;
                    const value = try b.lowerDefaultExpression(next_value, default_expr, null);
                    last_ref = try b.lowerDestructuringAssignmentTarget(&assignment_element.destructuring_assignment_target, value);
                },
            }
        },
        .assignment_rest_element => |rest| {
            const rest_array = try b.addInst(.{
                .tag = .iterator_collect,
                .data = .{ .ref = iterator_ref },
            });
            last_ref = try b.lowerDestructuringAssignmentTarget(&rest.destructuring_assignment_target, rest_array);
        },
    };

    const iterator_done = try b.addInst(.{
        .tag = .iterator_is_done,
        .data = .{ .ref = iterator_ref },
    });
    const close_cond = try b.addInstDeferred(.br_cond);

    const close_label = try b.addLabel();
    _ = try b.addInst(.{
        .tag = .iterator_close,
        .data = .{ .ref = iterator_ref },
    });

    const done_label = try b.addLabel();

    close_cond.set(.{ .br_cond = .{
        .condition = iterator_done,
        .then_target = done_label,
        .else_target = close_label,
    } });

    return last_ref;
}

fn lowerObjectAssignmentPattern(b: *Builder, pattern: *const ast.ObjectAssignmentPattern, object_value: Ir.Inst.Ref) Error!Ir.Inst.Ref {
    const object = try b.addInst(.{
        .tag = .to_object,
        .data = .{ .ref = object_value },
    });

    var last_ref = object;

    for (pattern.properties) |property| switch (property) {
        .assignment_property => |assignment_property| switch (assignment_property) {
            .identifier_reference_and_expression => |binding| {
                const string_index = try b.internString(binding.identifier_reference);
                const prop_value = try b.addInst(.{
                    .tag = .get_property,
                    .data = .{ .get_property = .{
                        .base = object,
                        .name = string_index,
                    } },
                });
                const default_expr, const anonymous_function_name = if (binding.initializer) |*expr|
                    .{ expr, if (expr.isAnonymousFunctionDefinition()) string_index else null }
                else
                    .{ null, null };
                const value = try b.lowerDefaultExpression(prop_value, default_expr, anonymous_function_name);
                const tag: Ir.Inst.Tag = if (b.in_strict_mode) .set_binding_strict else .set_binding;
                last_ref = try b.addInst(.{
                    .tag = tag,
                    .data = .{ .set_binding = .{
                        .name = string_index,
                        .value = value,
                    } },
                });
            },
            .property_name_and_assignment_element => |pnae| {
                const key_ref = try b.lowerPropertyName(&pnae.property_name);
                const prop_value = try b.addInst(.{
                    .tag = .get_property_computed,
                    .data = .{ .get_property_computed = .{
                        .base = object,
                        .property = key_ref,
                    } },
                });
                switch (pnae.assignment_element.destructuring_assignment_target) {
                    .assignment_pattern => |*assignment_pattern| {
                        const default_expr = if (pnae.assignment_element.initializer) |*expr| expr else null;
                        const value = try b.lowerDefaultExpression(prop_value, default_expr, null);
                        last_ref = try b.lowerAssignmentPattern(assignment_pattern, value);
                    },
                    .identifier_reference => |identifier_reference| {
                        const string_index = try b.internString(identifier_reference);
                        const default_expr, const anonymous_function_name = if (pnae.assignment_element.initializer) |*expr|
                            .{ expr, if (expr.isAnonymousFunctionDefinition()) string_index else null }
                        else
                            .{ null, null };
                        const value = try b.lowerDefaultExpression(prop_value, default_expr, anonymous_function_name);
                        last_ref = try b.lowerDestructuringAssignmentTarget(&pnae.assignment_element.destructuring_assignment_target, value);
                    },
                    .member_expression, .super_property => {
                        const default_expr = if (pnae.assignment_element.initializer) |*expr| expr else null;
                        const value = try b.lowerDefaultExpression(prop_value, default_expr, null);
                        last_ref = try b.lowerDestructuringAssignmentTarget(&pnae.assignment_element.destructuring_assignment_target, value);
                    },
                }
            },
        },
        .assignment_rest_property => |rest_property| {
            var excluded_names: std.ArrayList(Ir.Inst.Ref) = .empty;
            defer excluded_names.deinit(b.gpa);

            for (pattern.properties) |p| switch (p) {
                .assignment_property => |ap| switch (ap) {
                    .identifier_reference_and_expression => |binding| {
                        const string_index = try b.internString(binding.identifier_reference);
                        const name_ref = try b.addInst(.{
                            .tag = .string,
                            .data = .{ .string = string_index },
                        });
                        try excluded_names.append(b.gpa, name_ref);
                    },
                    .property_name_and_assignment_element => |pnae| {
                        const key_ref = try b.lowerPropertyName(&pnae.property_name);
                        try excluded_names.append(b.gpa, key_ref);
                    },
                },
                .assignment_rest_property => {},
            };

            const extra_index: Ir.ExtraIndex = @fromBackingInt(@intCast(b.extra.items.len));
            const excluded_len: u32 = @intCast(excluded_names.items.len);
            try b.extra.append(b.gpa, @backingInt(object));
            try b.extra.append(b.gpa, excluded_len);
            try b.extra.appendSlice(b.gpa, @ptrCast(excluded_names.items));

            const rest_obj = try b.addInst(.{
                .tag = .copy_data_properties,
                .data = .{ .copy_data_properties = extra_index },
            });

            last_ref = try b.lowerDestructuringAssignmentTarget(&rest_property.destructuring_assignment_target, rest_obj);
        },
    };

    return last_ref;
}

fn lowerDestructuringAssignmentTarget(b: *Builder, target: *const ast.DestructuringAssignmentTarget, value: Ir.Inst.Ref) Error!Ir.Inst.Ref {
    switch (target.*) {
        .identifier_reference => |identifier_reference| {
            const string_index = try b.internString(identifier_reference);
            const tag: Ir.Inst.Tag = if (b.in_strict_mode) .set_binding_strict else .set_binding;
            return b.addInst(.{
                .tag = tag,
                .data = .{ .set_binding = .{
                    .name = string_index,
                    .value = value,
                } },
            });
        },
        .member_expression => |*member_expr| {
            const base = try b.lowerExpression(member_expr.expression);
            switch (member_expr.property) {
                .identifier => |identifier| {
                    const string_index = try b.internString(identifier);
                    const tag: Ir.Inst.Tag = if (b.in_strict_mode)
                        .set_property_strict
                    else
                        .set_property;
                    const extra_index = try b.addExtra(Ir.Inst.SetProperty, .{
                        .base = base,
                        .name = string_index,
                        .value = value,
                    });
                    return b.addInst(.{
                        .tag = tag,
                        .data = .{ .set_property = extra_index },
                    });
                },
                .expression => |expr| {
                    if (try constantFold(b.gpa, expr)) |constant| {
                        defer constant.deinit(b.gpa);
                        if (constant.toIndex()) |index| {
                            const tag: Ir.Inst.Tag = if (b.in_strict_mode)
                                .set_property_indexed_strict
                            else
                                .set_property_indexed;
                            const extra_index = try b.addExtra(Ir.Inst.SetPropertyIndexed, .{
                                .base = base,
                                .index = index,
                                .value = value,
                            });
                            return b.addInst(.{
                                .tag = tag,
                                .data = .{ .set_property_indexed = extra_index },
                            });
                        }
                    }
                    const property = try b.lowerExpression(expr);
                    const tag: Ir.Inst.Tag = if (b.in_strict_mode)
                        .set_property_computed_strict
                    else
                        .set_property_computed;
                    const extra_index = try b.addExtra(Ir.Inst.SetPropertyComputed, .{
                        .base = base,
                        .property = property,
                        .value = value,
                    });
                    return b.addInst(.{
                        .tag = tag,
                        .data = .{ .set_property_computed = extra_index },
                    });
                },
                .private_identifier => |private_identifier| {
                    const string_index = try b.internString(private_identifier);
                    const extra_index = try b.addExtra(Ir.Inst.SetProperty, .{
                        .base = base,
                        .name = string_index,
                        .value = value,
                    });
                    return b.addInst(.{
                        .tag = .set_private_element,
                        .data = .{ .set_property = extra_index },
                    });
                },
            }
        },
        .super_property => |super_prop| switch (super_prop) {
            .identifier => |identifier| {
                const string_index = try b.internString(identifier);
                const tag: Ir.Inst.Tag = if (b.in_strict_mode)
                    .set_super_property_strict
                else
                    .set_super_property;
                const extra_index = try b.addExtra(Ir.Inst.SetProperty, .{
                    .base = .none,
                    .name = string_index,
                    .value = value,
                });
                return b.addInst(.{
                    .tag = tag,
                    .data = .{ .set_property = extra_index },
                });
            },
            .expression => |prop_expr| {
                const property = try b.lowerExpression(prop_expr);
                const tag: Ir.Inst.Tag = if (b.in_strict_mode)
                    .set_super_property_computed_strict
                else
                    .set_super_property_computed;
                const extra_index = try b.addExtra(Ir.Inst.SetPropertyComputed, .{
                    .base = .none,
                    .property = property,
                    .value = value,
                });
                return b.addInst(.{
                    .tag = tag,
                    .data = .{ .set_property_computed = extra_index },
                });
            },
        },
        .assignment_pattern => |*assignment_pattern| {
            return b.lowerAssignmentPattern(assignment_pattern, value);
        },
    }
}

const BindingOp = enum { set, initialize };

fn lowerBindingPattern(b: *Builder, pattern: *const ast.BindingPattern, value: Ir.Inst.Ref, binding_op: BindingOp) Error!Ir.Inst.Ref {
    return switch (pattern.*) {
        .array_binding_pattern => |*array_pattern| try b.lowerArrayBindingPattern(array_pattern, value, binding_op),
        .object_binding_pattern => |*object_pattern| try b.lowerObjectBindingPattern(object_pattern, value, binding_op),
    };
}

fn lowerArrayBindingPattern(b: *Builder, pattern: *const ast.ArrayBindingPattern, array_value: Ir.Inst.Ref, binding_op: BindingOp) Error!Ir.Inst.Ref {
    var last_ref: Ir.Inst.Ref = .none;

    const iterator_ref = try b.addInst(.{
        .tag = .get_iterator,
        .data = .{ .ref = array_value },
    });

    for (pattern.elements) |element| switch (element) {
        .elision => {
            _ = try b.addInst(.{
                .tag = .iterator_step,
                .data = .{ .ref = iterator_ref },
            });
        },
        .binding_element => |binding_element| {
            const next_value = try b.addInst(.{
                .tag = .iterator_step_value,
                .data = .{ .ref = iterator_ref },
            });
            switch (binding_element) {
                .single_name_binding => |binding| {
                    const string_index = try b.internString(binding.binding_identifier);
                    const default_expr, const anonymous_function_name = if (binding.initializer) |*expr|
                        .{ expr, if (expr.isAnonymousFunctionDefinition()) string_index else null }
                    else
                        .{ null, null };
                    const value = try b.lowerDefaultExpression(next_value, default_expr, anonymous_function_name);
                    const tag: Ir.Inst.Tag = switch (binding_op) {
                        .initialize => .initialize_binding,
                        .set => if (b.in_strict_mode) .set_binding_strict else .set_binding,
                    };
                    last_ref = try b.addInst(.{
                        .tag = tag,
                        .data = .{ .set_binding = .{
                            .name = string_index,
                            .value = value,
                        } },
                    });
                },
                .binding_pattern_and_expression => |bpe| {
                    const default_expr = if (bpe.initializer) |*expr| expr else null;
                    const value = try b.lowerDefaultExpression(next_value, default_expr, null);
                    last_ref = try b.lowerBindingPattern(&bpe.binding_pattern, value, binding_op);
                },
            }
        },
        .binding_rest_element => |rest| {
            const rest_array = try b.addInst(.{
                .tag = .iterator_collect,
                .data = .{ .ref = iterator_ref },
            });
            switch (rest) {
                .binding_identifier => |identifier| {
                    const string_index = try b.internString(identifier);
                    const tag: Ir.Inst.Tag = switch (binding_op) {
                        .initialize => .initialize_binding,
                        .set => if (b.in_strict_mode) .set_binding_strict else .set_binding,
                    };
                    last_ref = try b.addInst(.{
                        .tag = tag,
                        .data = .{ .set_binding = .{
                            .name = string_index,
                            .value = rest_array,
                        } },
                    });
                },
                .binding_pattern => |*binding_pattern| {
                    last_ref = try b.lowerBindingPattern(binding_pattern, rest_array, binding_op);
                },
            }
        },
    };

    const iterator_done = try b.addInst(.{
        .tag = .iterator_is_done,
        .data = .{ .ref = iterator_ref },
    });
    const close_cond = try b.addInstDeferred(.br_cond);

    const close_label = try b.addLabel();
    _ = try b.addInst(.{
        .tag = .iterator_close,
        .data = .{ .ref = iterator_ref },
    });

    const done_label = try b.addLabel();

    close_cond.set(.{ .br_cond = .{
        .condition = iterator_done,
        .then_target = done_label,
        .else_target = close_label,
    } });

    return last_ref;
}

fn lowerObjectBindingPattern(b: *Builder, pattern: *const ast.ObjectBindingPattern, object_value: Ir.Inst.Ref, binding_op: BindingOp) Error!Ir.Inst.Ref {
    const object = try b.addInst(.{
        .tag = .to_object,
        .data = .{ .ref = object_value },
    });

    var last_ref = object;

    for (pattern.properties) |property| switch (property) {
        .binding_property => |binding_property| switch (binding_property) {
            .single_name_binding => |binding| {
                const string_index = try b.internString(binding.binding_identifier);
                const prop_value = try b.addInst(.{
                    .tag = .get_property,
                    .data = .{ .get_property = .{
                        .base = object,
                        .name = string_index,
                    } },
                });
                const default_expr, const anonymous_function_name = if (binding.initializer) |*expr|
                    .{ expr, if (expr.isAnonymousFunctionDefinition()) string_index else null }
                else
                    .{ null, null };
                const value = try b.lowerDefaultExpression(prop_value, default_expr, anonymous_function_name);
                const tag: Ir.Inst.Tag = switch (binding_op) {
                    .initialize => .initialize_binding,
                    .set => if (b.in_strict_mode) .set_binding_strict else .set_binding,
                };
                last_ref = try b.addInst(.{
                    .tag = tag,
                    .data = .{ .set_binding = .{
                        .name = string_index,
                        .value = value,
                    } },
                });
            },
            .property_name_and_binding_element => |pnbe| {
                const key_ref = try b.lowerPropertyName(&pnbe.property_name);
                const prop_value = try b.addInst(.{
                    .tag = .get_property_computed,
                    .data = .{ .get_property_computed = .{
                        .base = object,
                        .property = key_ref,
                    } },
                });
                switch (pnbe.binding_element) {
                    .single_name_binding => |binding| {
                        const string_index = try b.internString(binding.binding_identifier);
                        const default_expr, const anonymous_function_name = if (binding.initializer) |*expr|
                            .{ expr, if (expr.isAnonymousFunctionDefinition()) string_index else null }
                        else
                            .{ null, null };
                        const value = try b.lowerDefaultExpression(prop_value, default_expr, anonymous_function_name);
                        const tag: Ir.Inst.Tag = switch (binding_op) {
                            .initialize => .initialize_binding,
                            .set => if (b.in_strict_mode) .set_binding_strict else .set_binding,
                        };
                        last_ref = try b.addInst(.{
                            .tag = tag,
                            .data = .{ .set_binding = .{
                                .name = string_index,
                                .value = value,
                            } },
                        });
                    },
                    .binding_pattern_and_expression => |bpe| {
                        const default_expr = if (bpe.initializer) |*expr| expr else null;
                        const value = try b.lowerDefaultExpression(prop_value, default_expr, null);
                        last_ref = try b.lowerBindingPattern(&bpe.binding_pattern, value, binding_op);
                    },
                }
            },
        },
        .binding_rest_property => |rest_property| {
            var excluded_names: std.ArrayList(Ir.Inst.Ref) = .empty;
            defer excluded_names.deinit(b.gpa);

            for (pattern.properties) |p| switch (p) {
                .binding_property => |binding_property| switch (binding_property) {
                    .single_name_binding => |binding| {
                        const string_index = try b.internString(binding.binding_identifier);
                        const name_ref = try b.addInst(.{
                            .tag = .string,
                            .data = .{ .string = string_index },
                        });
                        try excluded_names.append(b.gpa, name_ref);
                    },
                    .property_name_and_binding_element => |pnbe| {
                        const key_ref = try b.lowerPropertyName(&pnbe.property_name);
                        try excluded_names.append(b.gpa, key_ref);
                    },
                },
                .binding_rest_property => {},
            };

            const extra_index: Ir.ExtraIndex = @fromBackingInt(@intCast(b.extra.items.len));
            const excluded_len: u32 = @intCast(excluded_names.items.len);
            try b.extra.append(b.gpa, @backingInt(object));
            try b.extra.append(b.gpa, excluded_len);
            try b.extra.appendSlice(b.gpa, @ptrCast(excluded_names.items));

            const rest_obj = try b.addInst(.{
                .tag = .copy_data_properties,
                .data = .{ .copy_data_properties = extra_index },
            });

            const string_index = try b.internString(rest_property.binding_identifier);
            const tag: Ir.Inst.Tag = switch (binding_op) {
                .initialize => .initialize_binding,
                .set => if (b.in_strict_mode) .set_binding_strict else .set_binding,
            };
            last_ref = try b.addInst(.{
                .tag = tag,
                .data = .{ .set_binding = .{
                    .name = string_index,
                    .value = rest_obj,
                } },
            });
        },
    };

    return last_ref;
}

fn lowerExpression(b: *Builder, expr: *const ast.Expression) Error!Ir.Inst.Ref {
    if (try constantFold(b.gpa, expr)) |constant| {
        defer constant.deinit(b.gpa);
        return b.lowerConstant(constant);
    }
    return switch (expr.*) {
        .primary_expression => |prim_expr| switch (prim_expr) {
            .this => try b.lowerThis(),
            .identifier_reference => |identifier| try b.lowerIdentifierReference(identifier),
            .literal => unreachable, // Guaranteed to constant-fold
            .array_literal => |*array_lit| try b.lowerArrayLiteral(array_lit),
            .object_literal => |*object_lit| try b.lowerObjectLiteral(object_lit),
            .function_expression => |*func_expr| try b.lowerFunctionExpression(func_expr),
            .class_expression => |*class_expr| try b.lowerClassExpression(class_expr),
            .generator_expression => |*gen_expr| try b.lowerFunctionExpression(gen_expr),
            .async_function_expression => |*async_expr| try b.lowerFunctionExpression(async_expr),
            .async_generator_expression => |*async_gen_expr| try b.lowerFunctionExpression(async_gen_expr),
            .regular_expression_literal => |*regexp_lit| try b.lowerRegularExpressionLiteral(regexp_lit),
            .template_literal => |*template_lit| try b.lowerTemplateLiteral(template_lit),
            .arrow_function => |*arrow_func| try b.lowerArrowFunction(arrow_func),
            .async_arrow_function => |*async_arrow_func| try b.lowerArrowFunction(async_arrow_func),
        },
        .member_expression => |*member_expr| try b.lowerMemberExpression(member_expr, null),
        .super_property => |*super_prop| try b.lowerSuperProperty(super_prop, null),
        .meta_property => |meta_prop| switch (meta_prop) {
            .new_target => try b.lowerNewTarget(),
            .import_meta => try b.lowerImportMeta(),
        },
        .new_expression => |*new_expr| try b.lowerNewExpression(new_expr),
        .call_expression => |*call_expr| try b.lowerCallExpression(call_expr),
        .super_call => |*super_call| try b.lowerSuperCall(super_call),
        .import_call => |*import_call| try b.lowerImportCall(import_call),
        .optional_expression => |*opt_expr| try b.lowerOptionalExpression(opt_expr),
        .update_expression => |*update_expr| try b.lowerUpdateExpression(update_expr),
        .unary_expression => |*unary_expr| try b.lowerUnaryExpression(unary_expr),
        .binary_expression => |*bin_expr| try b.lowerBinaryExpression(bin_expr),
        .relational_expression => |*rel_expr| try b.lowerRelationalExpression(rel_expr),
        .equality_expression => |*eq_expr| try b.lowerEqualityExpression(eq_expr),
        .logical_expression => |*log_expr| try b.lowerLogicalExpression(log_expr),
        .conditional_expression => |*cond_expr| try b.lowerConditionalExpression(cond_expr),
        .assignment_expression => |*assign_expr| try b.lowerAssignmentExpression(assign_expr),
        .sequence_expression => |*seq_expr| try b.lowerSequenceExpression(seq_expr),
        .await_expression => |*await_expr| try b.lowerAwaitExpression(await_expr),
        .yield_expression => |*yield_expr| try b.lowerYieldExpression(yield_expr),
        .tagged_template => |*tagged_template| try b.lowerTaggedTemplate(tagged_template),
        .assignment_pattern => unreachable, // Only valid as assignment LHS
    };
}

fn lowerThis(b: *Builder) Error!Ir.Inst.Ref {
    return b.addInst(.{
        .tag = .this,
        .data = .{ .none = {} },
    });
}

fn lowerIdentifierReference(b: *Builder, identifier: []const u8) Error!Ir.Inst.Ref {
    const string_index = try b.internString(identifier);
    return b.addInst(.{
        .tag = .get_binding,
        .data = .{ .string = string_index },
    });
}

fn lowerArrayLiteral(b: *Builder, array_lit: *const ast.ArrayLiteral) Error!Ir.Inst.Ref {
    const has_spread = for (array_lit.element_list) |elem| {
        if (elem == .spread) break true;
    } else false;

    const array_ref = try b.addInst(.{
        .tag = .create_array,
        .data = .{ .array = .{
            .len = @intCast(array_lit.element_list.len),
            .has_spread = has_spread,
        } },
    });

    for (array_lit.element_list) |elem| {
        switch (elem) {
            .elision => {
                _ = try b.addInst(.{
                    .tag = .array_push,
                    .data = .{ .binary = .{
                        .lhs = array_ref,
                        .rhs = .none,
                    } },
                });
            },
            .expression => |*expr| {
                const value = try b.lowerExpression(expr);
                _ = try b.addInst(.{
                    .tag = .array_push,
                    .data = .{ .binary = .{
                        .lhs = array_ref,
                        .rhs = value,
                    } },
                });
            },
            .spread => |*expr| {
                const value = try b.lowerExpression(expr);
                _ = try b.addInst(.{
                    .tag = .array_spread,
                    .data = .{ .binary = .{
                        .lhs = array_ref,
                        .rhs = value,
                    } },
                });
            },
        }
    }

    return array_ref;
}

fn lowerObjectLiteral(b: *Builder, object_lit: *const ast.ObjectLiteral) Error!Ir.Inst.Ref {
    const Key = union(enum) {
        string: Ir.StringIndex,
        computed: Ir.Inst.Ref,
    };

    const property_count = try object_lit.property_definition_list.propertyCount(b.gpa);

    const object_ref = try b.addInst(.{
        .tag = .create_object,
        .data = .{ .object = .{ .property_count = @intCast(property_count) } },
    });

    for (object_lit.property_definition_list.items) |prop_def| {
        switch (prop_def) {
            .identifier_reference => |identifier| {
                const string_index = try b.internString(identifier);
                const value_ref = try b.addInst(.{
                    .tag = .get_binding,
                    .data = .{ .string = string_index },
                });
                const extra_index = try b.addExtra(Ir.Inst.SetProperty, .{
                    .base = object_ref,
                    .name = string_index,
                    .value = value_ref,
                });
                _ = try b.addInst(.{
                    .tag = .object_set,
                    .data = .{ .set_property = extra_index },
                });
            },
            .spread => |*expr| {
                const value_ref = try b.lowerExpression(expr);
                _ = try b.addInst(.{
                    .tag = .object_spread,
                    .data = .{ .binary = .{
                        .lhs = object_ref,
                        .rhs = value_ref,
                    } },
                });
            },
            .method_definition => |method_def| {
                const property_name = &method_def.class_element_name.property_name;
                const key: Key = if (property_name.* == .literal_property_name and
                    property_name.literal_property_name == .identifier)
                    .{ .string = try b.internString(
                        property_name.literal_property_name.identifier,
                    ) }
                else blk: {
                    const key_ref = try b.lowerPropertyName(property_name);
                    const key_index = key_ref.toIndex().?;
                    const key_inst = b.instructions.get(@backingInt(key_index));
                    break :blk if (key_inst.tag == .string)
                        .{ .string = key_inst.data.string }
                    else
                        .{ .computed = key_ref };
                };
                const method_ref = switch (method_def.method) {
                    .get, .set => |func_expr| blk: {
                        const name: Ir.Function.Name = if (property_name.* == .literal_property_name and
                            property_name.literal_property_name == .identifier)
                        name: {
                            const prefix: []const u8 = if (method_def.method == .get) "get " else "set ";
                            const identifier = property_name.literal_property_name.identifier;
                            const prefixed = try b.gpa.print("{s}{s}", .{ prefix, identifier });
                            defer b.gpa.free(prefixed);
                            break :name .{ .default = try b.internString(prefixed) };
                        } else .none;
                        const function_index = try b.addFunction(.{
                            .source_range = func_expr.source_range,
                            .name = name,
                            .parameters = func_expr.formal_parameters,
                            .body = func_expr.function_body,
                            .kind = .normal,
                        });
                        const func_ref = try b.addInst(.{
                            .tag = .create_function,
                            .data = .{ .create_function = function_index },
                        });
                        break :blk try b.addInst(.{
                            .tag = if (method_def.method == .get) .as_getter else .as_setter,
                            .data = .{ .ref = func_ref },
                        });
                    },
                    inline else => |func_expr, tag| blk: {
                        const name: Ir.Function.Name = if (property_name.* == .literal_property_name and
                            property_name.literal_property_name == .identifier)
                            .{ .default = try b.internString(
                                property_name.literal_property_name.identifier,
                            ) }
                        else
                            .none;
                        const function_index = try b.addFunction(.{
                            .source_range = func_expr.source_range,
                            .name = name,
                            .parameters = func_expr.formal_parameters,
                            .body = func_expr.function_body,
                            .kind = switch (tag) {
                                .method => .normal,
                                .generator => .generator,
                                .async => .async,
                                .async_generator => .async_generator,
                                .get, .set => unreachable,
                            },
                        });
                        break :blk try b.addInst(.{
                            .tag = .create_function,
                            .data = .{ .create_function = function_index },
                        });
                    },
                };
                switch (key) {
                    .string => |string_index| {
                        const extra_index = try b.addExtra(Ir.Inst.SetProperty, .{
                            .base = object_ref,
                            .name = string_index,
                            .value = method_ref,
                        });
                        _ = try b.addInst(.{
                            .tag = .object_set,
                            .data = .{ .set_property = extra_index },
                        });
                    },
                    .computed => |key_ref| {
                        const extra_index = try b.addExtra(Ir.Inst.SetPropertyComputed, .{
                            .base = object_ref,
                            .property = key_ref,
                            .value = method_ref,
                        });
                        _ = try b.addInst(.{
                            .tag = .object_set_computed,
                            .data = .{ .set_property_computed = extra_index },
                        });
                    },
                }
            },
            .property_name_and_expression => |*prop| if (try prop.property_name.eql(b.gpa, "__proto__")) {
                const value_ref = try b.lowerExpression(&prop.expression);
                _ = try b.addInst(.{
                    .tag = .object_set_prototype,
                    .data = .{ .binary = .{
                        .lhs = object_ref,
                        .rhs = value_ref,
                    } },
                });
            } else {
                const key: Key = if (prop.property_name == .literal_property_name and
                    prop.property_name.literal_property_name == .identifier)
                    .{ .string = try b.internString(
                        prop.property_name.literal_property_name.identifier,
                    ) }
                else blk: {
                    const key_ref = try b.lowerPropertyName(&prop.property_name);
                    const key_index = key_ref.toIndex().?;
                    const key_inst = b.instructions.get(@backingInt(key_index));
                    break :blk if (key_inst.tag == .string)
                        .{ .string = key_inst.data.string }
                    else
                        .{ .computed = key_ref };
                };
                const value_ref = try b.lowerExpression(&prop.expression);
                switch (key) {
                    .string => |string_index| {
                        if (prop.expression.isAnonymousFunctionDefinition()) {
                            b.setAnonymousFunctionName(value_ref, string_index);
                        }
                        const extra_index = try b.addExtra(Ir.Inst.SetProperty, .{
                            .base = object_ref,
                            .name = string_index,
                            .value = value_ref,
                        });
                        _ = try b.addInst(.{
                            .tag = .object_set,
                            .data = .{ .set_property = extra_index },
                        });
                    },
                    .computed => |key_ref| {
                        const extra_index = try b.addExtra(Ir.Inst.SetPropertyComputed, .{
                            .base = object_ref,
                            .property = key_ref,
                            .value = value_ref,
                        });
                        _ = try b.addInst(.{
                            .tag = .object_set_computed,
                            .data = .{ .set_property_computed = extra_index },
                        });
                    },
                }
            },
        }
    }

    return object_ref;
}

fn lowerClassExpression(b: *Builder, class_expr: *const ast.ClassExpression) Error!Ir.Inst.Ref {
    const name: Ir.Class.Name = if (class_expr.identifier) |identifier|
        .{ .identifier = try b.internString(identifier) }
    else
        .none;

    const heritage = try b.lowerClassHeritage(class_expr.class_tail.class_heritage);

    _ = try b.addInst(.{
        .tag = .push_private_scope,
        .data = .{ .none = {} },
    });
    const element_names = try b.lowerClassElementNames(&class_expr.class_tail.class_body);

    const class_index = try b.addClass(.{
        .source_range = class_expr.source_range,
        .name = name,
        .class_tail = class_expr.class_tail,
        .heritage = heritage,
        .element_names = element_names,
    });
    const result = try b.addInst(.{
        .tag = .create_class,
        .data = .{ .create_class = class_index },
    });
    _ = try b.addInst(.{
        .tag = .pop_private_scope,
        .data = .{ .none = {} },
    });
    return result;
}

fn lowerClassHeritage(b: *Builder, class_heritage: ?*const ast.Expression) Error!Ir.Inst.Ref {
    if (class_heritage) |heritage| {
        return b.lowerExpression(heritage);
    }
    return .none;
}

fn lowerClassElementNames(b: *Builder, class_body: *const ast.ClassBody) Error![]const Ir.Inst.Ref {
    var names: std.ArrayList(Ir.Inst.Ref) = .empty;
    var private_names: std.StringHashMapUnmanaged(Ir.Inst.Ref) = .empty;
    defer private_names.deinit(b.gpa);
    for (class_body.class_element_list.items) |class_element| {
        switch (try class_element.classElementKind(b.gpa)) {
            .constructor_method, .empty => continue,
            .non_constructor_method => {},
        }
        const name_ref: Ir.Inst.Ref = switch (class_element) {
            .method_definition, .static_method_definition => |method_def| try b.lowerClassElementName(&method_def.class_element_name, &private_names),
            .field_definition, .static_field_definition => |field_def| try b.lowerClassElementName(&field_def.class_element_name, &private_names),
            .class_static_block, .empty_statement => .none,
        };
        try names.append(b.gpa, name_ref);
    }
    return names.toOwnedSlice(b.gpa);
}

fn lowerClassElementName(b: *Builder, class_element_name: *const ast.ClassElementName, private_names: *std.StringHashMapUnmanaged(Ir.Inst.Ref)) Error!Ir.Inst.Ref {
    return switch (class_element_name.*) {
        .property_name => |*property_name| try b.lowerPropertyName(property_name),
        .private_identifier => |private_identifier| {
            const gop = try private_names.getOrPut(b.gpa, private_identifier);
            if (gop.found_existing) {
                return gop.value_ptr.*;
            }
            const string_index = try b.internString(private_identifier);
            const ref = try b.addInst(.{
                .tag = .create_private_element,
                .data = .{ .string = string_index },
            });
            gop.value_ptr.* = ref;
            return ref;
        },
    };
}

fn lowerFunctionExpression(b: *Builder, func_expr: anytype) Error!Ir.Inst.Ref {
    const name: Ir.Function.Name = if (func_expr.identifier) |identifier|
        .{ .identifier = try b.internString(identifier) }
    else
        .none;

    const function_index = try b.addFunction(.{
        .source_range = func_expr.source_range,
        .name = name,
        .parameters = func_expr.formal_parameters,
        .body = func_expr.function_body,
        .kind = switch (func_expr.function_body.type) {
            .normal => .normal,
            .generator => .generator,
            .async => .async,
            .async_generator => .async_generator,
        },
    });

    return b.addInst(.{
        .tag = .create_function,
        .data = .{ .create_function = function_index },
    });
}

fn lowerRegularExpressionLiteral(b: *Builder, regexp_lit: *const ast.RegularExpressionLiteral) Error!Ir.Inst.Ref {
    const pattern_index = try b.internString(regexp_lit.pattern);
    const flags_index = try b.internString(regexp_lit.flags);
    return b.addInst(.{
        .tag = .create_reg_exp,
        .data = .{ .reg_exp = .{
            .pattern = pattern_index,
            .flags = flags_index,
        } },
    });
}

fn lowerTemplateLiteral(b: *Builder, template_lit: *const ast.TemplateLiteral) Error!Ir.Inst.Ref {
    var result: Ir.Inst.Ref = .none;
    for (template_lit.spans, 0..) |span, i| {
        std.debug.assert(if (i % 2 == 0) span == .template else span == .expression);
        const span_ref: Ir.Inst.Ref = switch (span) {
            .expression => |expr| blk: {
                const expr_ref = try b.lowerExpression(&expr);
                break :blk try b.addInst(.{
                    .tag = .to_string,
                    .data = .{ .ref = expr_ref },
                });
            },
            .template => |template| blk: {
                var aw: std.Io.Writer.Allocating = .init(b.gpa);
                defer aw.deinit();
                const valid = template.value(&aw.writer) catch return error.OutOfMemory;
                std.debug.assert(valid);
                if (aw.written().len == 0) continue;
                const string_index = try b.internString(aw.written());
                break :blk try b.addInst(.{
                    .tag = .string,
                    .data = .{ .string = string_index },
                });
            },
        };

        if (result == .none) {
            result = span_ref;
        } else {
            result = try b.addInst(.{
                .tag = .add,
                .data = .{ .binary = .{
                    .lhs = result,
                    .rhs = span_ref,
                } },
            });
        }
    }
    // There is always at least one span, but it may have been skipped if empty.
    if (result == .none) {
        const string_index = try b.internString("");
        return b.addInst(.{
            .tag = .string,
            .data = .{ .string = string_index },
        });
    }
    return result;
}

fn lowerArrowFunction(b: *Builder, arrow_func: anytype) Error!Ir.Inst.Ref {
    const function_index = try b.addFunction(.{
        .source_range = arrow_func.source_range,
        .name = .none,
        .parameters = arrow_func.formal_parameters,
        .body = arrow_func.function_body,
        .kind = switch (arrow_func.function_body.type) {
            .normal => .arrow,
            .async => .async_arrow,
            .generator, .async_generator => unreachable,
        },
    });

    return b.addInst(.{
        .tag = .create_function,
        .data = .{ .create_function = function_index },
    });
}

fn lowerMemberExpression(b: *Builder, member_expr: *const ast.MemberExpression, base_out: ?*Ir.Inst.Ref) Error!Ir.Inst.Ref {
    const base = try b.lowerExpression(member_expr.expression);
    if (base_out) |ptr| ptr.* = base;
    switch (member_expr.property) {
        .expression => |expr| {
            if (try constantFold(b.gpa, expr)) |constant| {
                defer constant.deinit(b.gpa);
                if (constant.toIndex()) |index| {
                    return b.addInst(.{
                        .tag = .get_property_indexed,
                        .data = .{ .get_property_indexed = .{
                            .base = base,
                            .index = index,
                        } },
                    });
                }
                if (constant == .string) {
                    const string_index = try b.internString(constant.string);
                    return b.addInst(.{
                        .tag = .get_property,
                        .data = .{ .get_property = .{
                            .base = base,
                            .name = string_index,
                        } },
                    });
                }
            }
            const property = try b.lowerExpression(expr);
            return b.addInst(.{
                .tag = .get_property_computed,
                .data = .{ .get_property_computed = .{
                    .base = base,
                    .property = property,
                } },
            });
        },
        .identifier => |identifier| {
            const string_index = try b.internString(identifier);
            return b.addInst(.{
                .tag = .get_property,
                .data = .{ .get_property = .{
                    .base = base,
                    .name = string_index,
                } },
            });
        },
        .private_identifier => |private_identifier| {
            const string_index = try b.internString(private_identifier);
            return b.addInst(.{
                .tag = .get_private_element,
                .data = .{ .get_property = .{
                    .base = base,
                    .name = string_index,
                } },
            });
        },
    }
}

fn lowerArguments(b: *Builder, arguments: ast.Arguments) Error!std.ArrayList(Ir.Inst.Ref) {
    var args: std.ArrayList(Ir.Inst.Ref) = try .initCapacity(b.gpa, arguments.len);
    errdefer args.deinit(b.gpa);

    for (arguments) |arg| {
        const arg_ref: Ir.Inst.Ref = switch (arg) {
            .expression => |*expr| try b.lowerExpression(expr),
            .spread => |*expr| blk: {
                const value = try b.lowerExpression(expr);
                break :blk try b.addInst(.{
                    .tag = .spread,
                    .data = .{ .ref = value },
                });
            },
        };
        args.appendAssumeCapacity(arg_ref);
    }

    return args;
}

fn lowerSuperProperty(b: *Builder, super_prop: *const ast.SuperProperty, base_out: ?*Ir.Inst.Ref) Error!Ir.Inst.Ref {
    if (base_out) |ptr| ptr.* = try b.lowerThis();
    return switch (super_prop.*) {
        .identifier => |identifier| blk: {
            const string_index = try b.internString(identifier);
            break :blk try b.addInst(.{
                .tag = .get_super_property,
                .data = .{ .string = string_index },
            });
        },
        .expression => |expr| blk: {
            const property = try b.lowerExpression(expr);
            break :blk try b.addInst(.{
                .tag = .get_super_property_computed,
                .data = .{ .ref = property },
            });
        },
    };
}

fn lowerNewTarget(b: *Builder) Error!Ir.Inst.Ref {
    return b.addInst(.{
        .tag = .get_new_target,
        .data = .{ .none = {} },
    });
}

fn lowerImportMeta(b: *Builder) Error!Ir.Inst.Ref {
    return b.addInst(.{
        .tag = .get_import_meta,
        .data = .{ .none = {} },
    });
}

fn lowerNewExpression(b: *Builder, new_expr: *const ast.NewExpression) Error!Ir.Inst.Ref {
    const constructor = try b.lowerExpression(new_expr.expression);

    var args = try b.lowerArguments(new_expr.arguments);
    defer args.deinit(b.gpa);

    const extra_index = try b.addExtra(Ir.Inst.Construct, .{
        .constructor = constructor,
        .args_len = @intCast(args.items.len),
    });
    try b.extra.appendSlice(b.gpa, @ptrCast(args.items));

    return b.addInst(.{
        .tag = .construct,
        .data = .{ .construct = extra_index },
    });
}

fn lowerCallExpression(b: *Builder, call_expr: *const ast.CallExpression) Error!Ir.Inst.Ref {
    var this_value: Ir.Inst.Ref = .none;
    const callee = switch (call_expr.expression.*) {
        .member_expression => |*member_expr| try b.lowerMemberExpression(member_expr, &this_value),
        .super_property => |*super_prop| try b.lowerSuperProperty(super_prop, &this_value),
        else => try b.lowerExpression(call_expr.expression),
    };

    var args = try b.lowerArguments(call_expr.arguments);
    defer args.deinit(b.gpa);

    const extra_index = try b.addExtra(Ir.Inst.Call, .{
        .callee = callee,
        .this_value = this_value,
        .args_len = @intCast(args.items.len),
    });
    try b.extra.appendSlice(b.gpa, @ptrCast(args.items));

    const is_direct_eval = call_expr.expression.* == .primary_expression and
        call_expr.expression.primary_expression == .identifier_reference and
        std.mem.eql(u8, call_expr.expression.primary_expression.identifier_reference, "eval");

    const tag: Ir.Inst.Tag = if (is_direct_eval)
        (if (b.in_strict_mode) .call_direct_eval_strict else .call_direct_eval)
    else
        .call;

    return b.addInst(.{
        .tag = tag,
        .data = .{ .call = extra_index },
    });
}

fn lowerSuperCall(b: *Builder, super_call: *const ast.SuperCall) Error!Ir.Inst.Ref {
    var args = try b.lowerArguments(super_call.arguments);
    defer args.deinit(b.gpa);

    const extra_index = try b.addExtra(Ir.Inst.SuperCall, .{
        .args_len = @intCast(args.items.len),
    });
    try b.extra.appendSlice(b.gpa, @ptrCast(args.items));

    return b.addInst(.{
        .tag = .super_call,
        .data = .{ .super_call = extra_index },
    });
}

fn lowerImportCall(b: *Builder, import_call: *const ast.ImportCall) Error!Ir.Inst.Ref {
    const specifier = try b.lowerExpression(import_call.specifier_expression);
    const options = if (import_call.options_expression) |expr|
        try b.lowerExpression(expr)
    else
        try b.addInst(.{
            .tag = .undefined,
            .data = .{ .none = {} },
        });
    return b.addInst(.{
        .tag = .import_call,
        .data = .{ .binary = .{ .lhs = specifier, .rhs = options } },
    });
}

fn lowerOptionalExpression(b: *Builder, opt_expr: *const ast.OptionalExpression) Error!Ir.Inst.Ref {
    const first_property = opt_expr.properties[0];

    var this_value: Ir.Inst.Ref = .none;
    const base = switch (opt_expr.expression.*) {
        .member_expression => |*member_expr| blk: {
            if (first_property == .arguments) {
                break :blk try b.lowerMemberExpression(member_expr, &this_value);
            } else {
                break :blk try b.lowerMemberExpression(member_expr, null);
            }
        },
        else => try b.lowerExpression(opt_expr.expression),
    };

    const is_nullish = try b.addInst(.{
        .tag = .is_nullish,
        .data = .{ .ref = base },
    });
    const nullish_br = try b.addInstDeferred(.br_cond);

    const properties_label = try b.addLabel();

    var current = base;
    for (opt_expr.properties, 0..) |property, i| {
        const next_is_call = i + 1 < opt_expr.properties.len and opt_expr.properties[i + 1] == .arguments;

        current = switch (property) {
            .arguments => |arguments| blk: {
                var args = try b.lowerArguments(arguments);
                defer args.deinit(b.gpa);

                const extra_index = try b.addExtra(Ir.Inst.Call, .{
                    .callee = current,
                    .this_value = this_value,
                    .args_len = @intCast(args.items.len),
                });
                try b.extra.appendSlice(b.gpa, @ptrCast(args.items));

                this_value = .none;
                break :blk try b.addInst(.{
                    .tag = .call,
                    .data = .{ .call = extra_index },
                });
            },
            .expression => |expr| blk: {
                if (next_is_call) this_value = current;

                if (try constantFold(b.gpa, expr)) |constant| {
                    defer constant.deinit(b.gpa);
                    if (constant.toIndex()) |index| {
                        break :blk try b.addInst(.{
                            .tag = .get_property_indexed,
                            .data = .{ .get_property_indexed = .{
                                .base = current,
                                .index = index,
                            } },
                        });
                    }
                    if (constant == .string) {
                        const string_index = try b.internString(constant.string);
                        break :blk try b.addInst(.{
                            .tag = .get_property,
                            .data = .{ .get_property = .{
                                .base = current,
                                .name = string_index,
                            } },
                        });
                    }
                }
                const prop = try b.lowerExpression(expr);
                break :blk try b.addInst(.{
                    .tag = .get_property_computed,
                    .data = .{ .get_property_computed = .{
                        .base = current,
                        .property = prop,
                    } },
                });
            },
            .identifier => |identifier| blk: {
                if (next_is_call) this_value = current;

                const string_index = try b.internString(identifier);
                break :blk try b.addInst(.{
                    .tag = .get_property,
                    .data = .{ .get_property = .{
                        .base = current,
                        .name = string_index,
                    } },
                });
            },
            .private_identifier => |private_identifier| blk: {
                const string_index = try b.internString(private_identifier);
                break :blk try b.addInst(.{
                    .tag = .get_private_element,
                    .data = .{ .get_property = .{
                        .base = current,
                        .name = string_index,
                    } },
                });
            },
        };
    }
    const properties_br = try b.addInstDeferred(.br);

    const short_circuit_label = try b.addLabel();
    const undefined_ref = try b.addInst(.{
        .tag = .undefined,
        .data = .{ .none = {} },
    });
    const short_circuit_br = try b.addInstDeferred(.br);

    const end_label = try b.addLabel();

    nullish_br.set(.{ .br_cond = .{
        .condition = is_nullish,
        .then_target = short_circuit_label,
        .else_target = properties_label,
    } });
    properties_br.set(.{ .br = .{
        .target = end_label,
        .value = current,
    } });
    short_circuit_br.set(.{ .br = .{
        .target = end_label,
        .value = undefined_ref,
    } });

    return end_label;
}

fn lowerUpdateExpression(b: *Builder, update_expr: *const ast.UpdateExpression) Error!Ir.Inst.Ref {
    const Lhs = union(enum) {
        binding: Ir.StringIndex,
        property: struct { base: Ir.Inst.Ref, name: Ir.StringIndex },
        property_indexed: struct { base: Ir.Inst.Ref, index: u32 },
        property_computed: struct { base: Ir.Inst.Ref, property: Ir.Inst.Ref },
        private_element: struct { base: Ir.Inst.Ref, name: Ir.StringIndex },
        super_property: Ir.StringIndex,
        super_property_computed: Ir.Inst.Ref,
    };

    var lhs: Lhs = undefined;
    const current_value = switch (update_expr.expression.*) {
        .primary_expression => |prim_expr| switch (prim_expr) {
            .identifier_reference => |identifier| blk: {
                const string_index = try b.internString(identifier);
                lhs = .{ .binding = string_index };
                break :blk try b.addInst(.{
                    .tag = .get_binding,
                    .data = .{ .string = string_index },
                });
            },
            else => unreachable,
        },
        .member_expression => |*member_expr| blk: {
            const base = try b.lowerExpression(member_expr.expression);
            switch (member_expr.property) {
                .identifier => |identifier| {
                    const string_index = try b.internString(identifier);
                    lhs = .{ .property = .{ .base = base, .name = string_index } };
                    break :blk try b.addInst(.{
                        .tag = .get_property,
                        .data = .{ .get_property = .{
                            .base = base,
                            .name = string_index,
                        } },
                    });
                },
                .expression => |expr| {
                    if (try constantFold(b.gpa, expr)) |constant| {
                        defer constant.deinit(b.gpa);
                        if (constant.toIndex()) |index| {
                            lhs = .{ .property_indexed = .{ .base = base, .index = index } };
                            break :blk try b.addInst(.{
                                .tag = .get_property_indexed,
                                .data = .{ .get_property_indexed = .{
                                    .base = base,
                                    .index = index,
                                } },
                            });
                        }
                    }
                    const property = try b.lowerExpression(expr);
                    lhs = .{ .property_computed = .{ .base = base, .property = property } };
                    break :blk try b.addInst(.{
                        .tag = .get_property_computed,
                        .data = .{ .get_property_computed = .{
                            .base = base,
                            .property = property,
                        } },
                    });
                },
                .private_identifier => |private_identifier| {
                    const string_index = try b.internString(private_identifier);
                    lhs = .{ .private_element = .{ .base = base, .name = string_index } };
                    break :blk try b.addInst(.{
                        .tag = .get_private_element,
                        .data = .{ .get_property = .{
                            .base = base,
                            .name = string_index,
                        } },
                    });
                },
            }
        },
        .super_property => |super_prop| switch (super_prop) {
            .identifier => |identifier| blk: {
                const string_index = try b.internString(identifier);
                lhs = .{ .super_property = string_index };
                break :blk try b.addInst(.{
                    .tag = .get_super_property,
                    .data = .{ .string = string_index },
                });
            },
            .expression => |expr| blk: {
                const property = try b.lowerExpression(expr);
                lhs = .{ .super_property_computed = property };
                break :blk try b.addInst(.{
                    .tag = .get_super_property_computed,
                    .data = .{ .ref = property },
                });
            },
        },
        .call_expression => |*call_expr| {
            _ = try b.lowerCallExpression(call_expr);
            return b.addInst(.{
                .tag = .throw_reference_error,
                .data = .{ .none = {} },
            });
        },
        else => unreachable,
    };

    const update_tag: Ir.Inst.Tag = switch (update_expr.operator) {
        .@"++" => .increment,
        .@"--" => .decrement,
    };
    const numeric_value = try b.addInst(.{
        .tag = .to_numeric,
        .data = .{ .ref = current_value },
    });
    const updated_value = try b.addInst(.{
        .tag = update_tag,
        .data = .{ .ref = numeric_value },
    });

    switch (lhs) {
        .binding => |string_index| {
            const set_tag: Ir.Inst.Tag = if (b.in_strict_mode)
                .set_binding_strict
            else
                .set_binding;
            _ = try b.addInst(.{
                .tag = set_tag,
                .data = .{ .set_binding = .{
                    .name = string_index,
                    .value = updated_value,
                } },
            });
        },
        .property => |property| {
            const extra_index = try b.addExtra(Ir.Inst.SetProperty, .{
                .base = property.base,
                .name = property.name,
                .value = updated_value,
            });
            const set_tag: Ir.Inst.Tag = if (b.in_strict_mode)
                .set_property_strict
            else
                .set_property;
            _ = try b.addInst(.{
                .tag = set_tag,
                .data = .{ .set_property = extra_index },
            });
        },
        .property_indexed => |property| {
            const extra_index = try b.addExtra(Ir.Inst.SetPropertyIndexed, .{
                .base = property.base,
                .index = property.index,
                .value = updated_value,
            });
            const set_tag: Ir.Inst.Tag = if (b.in_strict_mode)
                .set_property_indexed_strict
            else
                .set_property_indexed;
            _ = try b.addInst(.{
                .tag = set_tag,
                .data = .{ .set_property_indexed = extra_index },
            });
        },
        .property_computed => |property| {
            const extra_index = try b.addExtra(Ir.Inst.SetPropertyComputed, .{
                .base = property.base,
                .property = property.property,
                .value = updated_value,
            });
            const set_tag: Ir.Inst.Tag = if (b.in_strict_mode)
                .set_property_computed_strict
            else
                .set_property_computed;
            _ = try b.addInst(.{
                .tag = set_tag,
                .data = .{ .set_property_computed = extra_index },
            });
        },
        .private_element => |property| {
            const extra_index = try b.addExtra(Ir.Inst.SetProperty, .{
                .base = property.base,
                .name = property.name,
                .value = updated_value,
            });
            _ = try b.addInst(.{
                .tag = .set_private_element,
                .data = .{ .set_property = extra_index },
            });
        },
        .super_property => |string_index| {
            const extra_index = try b.addExtra(Ir.Inst.SetProperty, .{
                .base = .none,
                .name = string_index,
                .value = updated_value,
            });
            const set_tag: Ir.Inst.Tag = if (b.in_strict_mode)
                .set_super_property_strict
            else
                .set_super_property;
            _ = try b.addInst(.{
                .tag = set_tag,
                .data = .{ .set_property = extra_index },
            });
        },
        .super_property_computed => |property| {
            const extra_index = try b.addExtra(Ir.Inst.SetPropertyComputed, .{
                .base = .none,
                .property = property,
                .value = updated_value,
            });
            const set_tag: Ir.Inst.Tag = if (b.in_strict_mode)
                .set_super_property_computed_strict
            else
                .set_super_property_computed;
            _ = try b.addInst(.{
                .tag = set_tag,
                .data = .{ .set_property_computed = extra_index },
            });
        },
    }

    return switch (update_expr.type) {
        .prefix => updated_value,
        .postfix => numeric_value,
    };
}

fn lowerUnaryExpression(b: *Builder, unary_expr: *const ast.UnaryExpression) Error!Ir.Inst.Ref {
    if (unary_expr.operator == .typeof and
        unary_expr.expression.* == .primary_expression and
        unary_expr.expression.primary_expression == .identifier_reference)
    {
        const identifier = unary_expr.expression.primary_expression.identifier_reference;
        const string_index = try b.internString(identifier);
        return b.addInst(.{
            .tag = .typeof_binding,
            .data = .{ .string = string_index },
        });
    }
    if (unary_expr.operator == .delete and
        unary_expr.expression.* == .primary_expression and
        unary_expr.expression.primary_expression == .identifier_reference)
    {
        const identifier = unary_expr.expression.primary_expression.identifier_reference;
        const string_index = try b.internString(identifier);
        return b.addInst(.{
            .tag = .delete_binding,
            .data = .{ .string = string_index },
        });
    }
    if (unary_expr.operator == .delete and unary_expr.expression.* == .member_expression) {
        const member_expr = unary_expr.expression.member_expression;
        const base = try b.lowerExpression(member_expr.expression);
        switch (member_expr.property) {
            .expression => |expr| {
                if (try constantFold(b.gpa, expr)) |constant| {
                    defer constant.deinit(b.gpa);
                    if (constant.toIndex()) |index| {
                        const tag: Ir.Inst.Tag = if (b.in_strict_mode)
                            .delete_property_indexed_strict
                        else
                            .delete_property_indexed;
                        return b.addInst(.{
                            .tag = tag,
                            .data = .{ .delete_property_indexed = .{
                                .base = base,
                                .index = index,
                            } },
                        });
                    }
                }
                const property = try b.lowerExpression(expr);
                const tag: Ir.Inst.Tag = if (b.in_strict_mode)
                    .delete_property_computed_strict
                else
                    .delete_property_computed;
                return b.addInst(.{
                    .tag = tag,
                    .data = .{ .delete_property_computed = .{
                        .base = base,
                        .property = property,
                    } },
                });
            },
            .identifier => |identifier| {
                const string_index = try b.internString(identifier);
                const tag: Ir.Inst.Tag = if (b.in_strict_mode)
                    .delete_property_strict
                else
                    .delete_property;
                return b.addInst(.{
                    .tag = tag,
                    .data = .{ .delete_property = .{
                        .base = base,
                        .name = string_index,
                    } },
                });
            },
            .private_identifier => unreachable,
        }
    }
    const operand = try b.lowerExpression(unary_expr.expression);
    return switch (unary_expr.operator) {
        .@"+" => b.addInst(.{
            .tag = .to_number,
            .data = .{ .ref = operand },
        }),
        .@"-" => b.addInst(.{
            .tag = .negate,
            .data = .{ .ref = operand },
        }),
        .@"~" => b.addInst(.{
            .tag = .bitwise_not,
            .data = .{ .ref = operand },
        }),
        .@"!" => b.addInst(.{
            .tag = .logical_not,
            .data = .{ .ref = operand },
        }),
        .typeof => b.addInst(.{
            .tag = .typeof,
            .data = .{ .ref = operand },
        }),
        .delete => b.addInst(.{
            .tag = .true,
            .data = .{ .none = {} },
        }),
        .void => b.addInst(.{
            .tag = .undefined,
            .data = .{ .none = {} },
        }),
    };
}

fn lowerBinaryExpression(b: *Builder, bin_expr: *const ast.BinaryExpression) Error!Ir.Inst.Ref {
    const lhs = try b.lowerExpression(bin_expr.lhs_expression);
    const rhs = try b.lowerExpression(bin_expr.rhs_expression);
    const tag: Ir.Inst.Tag = switch (bin_expr.operator) {
        .@"+" => .add,
        .@"-" => .sub,
        .@"*" => .mul,
        .@"/" => .div,
        .@"%" => .rem,
        .@"**" => .exp,
        .@"<<" => .shift_left,
        .@">>" => .shift_right,
        .@">>>" => .shift_right_unsigned,
        .@"&" => .bitwise_and,
        .@"^" => .bitwise_xor,
        .@"|" => .bitwise_or,
    };
    return b.addInst(.{
        .tag = tag,
        .data = .{ .binary = .{
            .lhs = lhs,
            .rhs = rhs,
        } },
    });
}

fn lowerRelationalExpression(b: *Builder, rel_expr: *const ast.RelationalExpression) Error!Ir.Inst.Ref {
    switch (rel_expr.lhs) {
        .expression => |expr| {
            const lhs = try b.lowerExpression(expr);
            const rhs = try b.lowerExpression(rel_expr.rhs_expression);
            const tag: Ir.Inst.Tag = switch (rel_expr.operator) {
                .@"<" => .lt,
                .@">" => .gt,
                .@"<=" => .lt_eq,
                .@">=" => .gt_eq,
                .instanceof => .instanceof,
                .in => .in,
            };
            return b.addInst(.{
                .tag = tag,
                .data = .{ .binary = .{
                    .lhs = lhs,
                    .rhs = rhs,
                } },
            });
        },
        .private_identifier => |private_identifier| {
            const string_index = try b.internString(private_identifier);
            const name = try b.addInst(.{
                .tag = .resolve_private_element,
                .data = .{ .string = string_index },
            });
            const rhs = try b.lowerExpression(rel_expr.rhs_expression);
            return b.addInst(.{
                .tag = .has_private_element,
                .data = .{ .binary = .{
                    .lhs = name,
                    .rhs = rhs,
                } },
            });
        },
    }
}

fn lowerEqualityExpression(b: *Builder, eq_expr: *const ast.EqualityExpression) Error!Ir.Inst.Ref {
    const lhs = try b.lowerExpression(eq_expr.lhs_expression);
    const rhs = try b.lowerExpression(eq_expr.rhs_expression);
    const tag: Ir.Inst.Tag = switch (eq_expr.operator) {
        .@"==" => .eq,
        .@"!=" => .not_eq,
        .@"===" => .eq_strict,
        .@"!==" => .not_eq_strict,
    };
    return b.addInst(.{
        .tag = tag,
        .data = .{ .binary = .{
            .lhs = lhs,
            .rhs = rhs,
        } },
    });
}

fn lowerLogicalExpression(b: *Builder, log_expr: *const ast.LogicalExpression) Error!Ir.Inst.Ref {
    const lhs = try b.lowerExpression(log_expr.lhs_expression);

    const condition, const then_target_is_rhs = switch (log_expr.operator) {
        .@"&&" => .{ try b.addInst(.{
            .tag = .to_boolean,
            .data = .{ .ref = lhs },
        }), true },
        .@"||" => .{ try b.addInst(.{
            .tag = .to_boolean,
            .data = .{ .ref = lhs },
        }), false },
        .@"??" => .{ try b.addInst(.{
            .tag = .is_nullish,
            .data = .{ .ref = lhs },
        }), true },
    };
    const br_cond = try b.addInstDeferred(.br_cond);

    const lhs_label = try b.addLabel();
    const lhs_br = try b.addInstDeferred(.br);

    const rhs_label = try b.addLabel();
    const rhs = try b.lowerExpression(log_expr.rhs_expression);
    const rhs_br = try b.addInstDeferred(.br);

    const end_label = try b.addLabel();

    br_cond.set(.{ .br_cond = .{
        .condition = condition,
        .then_target = if (then_target_is_rhs) rhs_label else lhs_label,
        .else_target = if (then_target_is_rhs) lhs_label else rhs_label,
    } });
    lhs_br.set(.{ .br = .{
        .target = end_label,
        .value = lhs,
    } });
    rhs_br.set(.{ .br = .{
        .target = end_label,
        .value = rhs,
    } });

    return end_label;
}

fn lowerConditionalExpression(b: *Builder, cond_expr: *const ast.ConditionalExpression) Error!Ir.Inst.Ref {
    if (try constantFold(b.gpa, cond_expr.test_expression)) |constant| {
        defer constant.deinit(b.gpa);
        return if (constant.isTruthy())
            try b.lowerExpression(cond_expr.consequent_expression)
        else
            try b.lowerExpression(cond_expr.alternate_expression);
    }

    const test_result = try b.addInst(.{
        .tag = .to_boolean,
        .data = .{ .ref = try b.lowerExpression(cond_expr.test_expression) },
    });
    const test_br_cond = try b.addInstDeferred(.br_cond);

    const then_label = try b.addLabel();
    const then_value = try b.lowerExpression(cond_expr.consequent_expression);
    const then_br = try b.addInstDeferred(.br);

    const else_label = try b.addLabel();
    const else_value = try b.lowerExpression(cond_expr.alternate_expression);
    const else_br = try b.addInstDeferred(.br);

    const end_label = try b.addLabel();

    test_br_cond.set(.{ .br_cond = .{
        .condition = test_result,
        .then_target = then_label,
        .else_target = else_label,
    } });
    then_br.set(.{ .br = .{
        .target = end_label,
        .value = then_value,
    } });
    else_br.set(.{ .br = .{
        .target = end_label,
        .value = else_value,
    } });

    return end_label;
}

fn lowerAssignmentExpression(b: *Builder, assign_expr: *const ast.AssignmentExpression) Error!Ir.Inst.Ref {
    return switch (assign_expr.operator) {
        .@"=" => try b.lowerSimpleAssignmentExpression(assign_expr),
        .@"&&=", .@"||=", .@"??=" => try b.lowerLogicalCompoundAssignmentExpression(assign_expr),
        else => try b.lowerBinaryCompoundAssignmentExpression(assign_expr),
    };
}

fn lowerSimpleAssignmentExpression(b: *Builder, assign_expr: *const ast.AssignmentExpression) Error!Ir.Inst.Ref {
    switch (assign_expr.lhs_expression.*) {
        .primary_expression => |prim_expr| switch (prim_expr) {
            .identifier_reference => |identifier| {
                const value = try b.lowerExpression(assign_expr.rhs_expression);
                const string_index = try b.internString(identifier);
                if (assign_expr.rhs_expression.isAnonymousFunctionDefinition()) {
                    b.setAnonymousFunctionName(value, string_index);
                }
                return b.addInst(.{
                    .tag = if (b.in_strict_mode)
                        .set_binding_strict
                    else
                        .set_binding,
                    .data = .{ .set_binding = .{
                        .name = string_index,
                        .value = value,
                    } },
                });
            },
            else => unreachable,
        },
        .member_expression => |*member_expr| {
            const base = try b.lowerExpression(member_expr.expression);
            switch (member_expr.property) {
                .identifier => |identifier| {
                    const value = try b.lowerExpression(assign_expr.rhs_expression);
                    const string_index = try b.internString(identifier);
                    const tag: Ir.Inst.Tag = if (b.in_strict_mode)
                        .set_property_strict
                    else
                        .set_property;
                    const extra_index = try b.addExtra(Ir.Inst.SetProperty, .{
                        .base = base,
                        .name = string_index,
                        .value = value,
                    });
                    return b.addInst(.{
                        .tag = tag,
                        .data = .{ .set_property = extra_index },
                    });
                },
                .expression => |expr| {
                    if (try constantFold(b.gpa, expr)) |constant| {
                        defer constant.deinit(b.gpa);
                        if (constant.toIndex()) |index| {
                            const value = try b.lowerExpression(assign_expr.rhs_expression);
                            const tag: Ir.Inst.Tag = if (b.in_strict_mode)
                                .set_property_indexed_strict
                            else
                                .set_property_indexed;
                            const extra_index = try b.addExtra(Ir.Inst.SetPropertyIndexed, .{
                                .base = base,
                                .index = index,
                                .value = value,
                            });
                            return b.addInst(.{
                                .tag = tag,
                                .data = .{ .set_property_indexed = extra_index },
                            });
                        }
                    }
                    const property = try b.lowerExpression(expr);
                    const value = try b.lowerExpression(assign_expr.rhs_expression);
                    const tag: Ir.Inst.Tag = if (b.in_strict_mode)
                        .set_property_computed_strict
                    else
                        .set_property_computed;
                    const extra_index = try b.addExtra(Ir.Inst.SetPropertyComputed, .{
                        .base = base,
                        .property = property,
                        .value = value,
                    });
                    return b.addInst(.{
                        .tag = tag,
                        .data = .{ .set_property_computed = extra_index },
                    });
                },
                .private_identifier => |private_identifier| {
                    const string_index = try b.internString(private_identifier);
                    const value = try b.lowerExpression(assign_expr.rhs_expression);
                    const extra_index = try b.addExtra(Ir.Inst.SetProperty, .{
                        .base = base,
                        .name = string_index,
                        .value = value,
                    });
                    return b.addInst(.{
                        .tag = .set_private_element,
                        .data = .{ .set_property = extra_index },
                    });
                },
            }
        },
        .super_property => |super_prop| switch (super_prop) {
            .identifier => |identifier| {
                const value = try b.lowerExpression(assign_expr.rhs_expression);
                const string_index = try b.internString(identifier);
                const tag: Ir.Inst.Tag = if (b.in_strict_mode)
                    .set_super_property_strict
                else
                    .set_super_property;
                const extra_index = try b.addExtra(Ir.Inst.SetProperty, .{
                    .base = .none,
                    .name = string_index,
                    .value = value,
                });
                return b.addInst(.{
                    .tag = tag,
                    .data = .{ .set_property = extra_index },
                });
            },
            .expression => |prop_expr| {
                const property = try b.lowerExpression(prop_expr);
                const value = try b.lowerExpression(assign_expr.rhs_expression);
                const tag: Ir.Inst.Tag = if (b.in_strict_mode)
                    .set_super_property_computed_strict
                else
                    .set_super_property_computed;
                const extra_index = try b.addExtra(Ir.Inst.SetPropertyComputed, .{
                    .base = .none,
                    .property = property,
                    .value = value,
                });
                return b.addInst(.{
                    .tag = tag,
                    .data = .{ .set_property_computed = extra_index },
                });
            },
        },
        .assignment_pattern => |*assignment_pattern| {
            const value = try b.lowerExpression(assign_expr.rhs_expression);
            _ = try b.lowerAssignmentPattern(assignment_pattern, value);
            return value;
        },
        .call_expression => |*call_expr| {
            _ = try b.lowerCallExpression(call_expr);
            return b.addInst(.{
                .tag = .throw_reference_error,
                .data = .{ .none = {} },
            });
        },
        else => unreachable,
    }
}

fn lowerBinaryCompoundAssignmentExpression(b: *Builder, assign_expr: *const ast.AssignmentExpression) Error!Ir.Inst.Ref {
    const binary_tag: Ir.Inst.Tag = switch (assign_expr.operator) {
        .@"+=" => .add,
        .@"-=" => .sub,
        .@"*=" => .mul,
        .@"/=" => .div,
        .@"%=" => .rem,
        .@"**=" => .exp,
        .@"<<=" => .shift_left,
        .@">>=" => .shift_right,
        .@">>>=" => .shift_right_unsigned,
        .@"&=" => .bitwise_and,
        .@"^=" => .bitwise_xor,
        .@"|=" => .bitwise_or,
        else => unreachable,
    };
    switch (assign_expr.lhs_expression.*) {
        .primary_expression => |prim_expr| switch (prim_expr) {
            .identifier_reference => |identifier| {
                const string_index = try b.internString(identifier);
                const current_value = try b.addInst(.{
                    .tag = .get_binding,
                    .data = .{ .string = string_index },
                });
                const rhs = try b.lowerExpression(assign_expr.rhs_expression);
                const result = try b.addInst(.{
                    .tag = binary_tag,
                    .data = .{ .binary = .{
                        .lhs = current_value,
                        .rhs = rhs,
                    } },
                });
                return b.addInst(.{
                    .tag = if (b.in_strict_mode) .set_binding_strict else .set_binding,
                    .data = .{ .set_binding = .{
                        .name = string_index,
                        .value = result,
                    } },
                });
            },
            else => unreachable,
        },
        .member_expression => |*member_expr| {
            const base = try b.lowerExpression(member_expr.expression);
            switch (member_expr.property) {
                .identifier => |identifier| {
                    const string_index = try b.internString(identifier);
                    const current_value = try b.addInst(.{
                        .tag = .get_property,
                        .data = .{ .get_property = .{
                            .base = base,
                            .name = string_index,
                        } },
                    });
                    const rhs = try b.lowerExpression(assign_expr.rhs_expression);
                    const result = try b.addInst(.{
                        .tag = binary_tag,
                        .data = .{ .binary = .{
                            .lhs = current_value,
                            .rhs = rhs,
                        } },
                    });
                    const set_tag: Ir.Inst.Tag = if (b.in_strict_mode)
                        .set_property_strict
                    else
                        .set_property;
                    const extra_index = try b.addExtra(Ir.Inst.SetProperty, .{
                        .base = base,
                        .name = string_index,
                        .value = result,
                    });
                    return b.addInst(.{
                        .tag = set_tag,
                        .data = .{ .set_property = extra_index },
                    });
                },
                .expression => |expr| {
                    if (try constantFold(b.gpa, expr)) |constant| {
                        defer constant.deinit(b.gpa);
                        if (constant.toIndex()) |index| {
                            const current_value = try b.addInst(.{
                                .tag = .get_property_indexed,
                                .data = .{ .get_property_indexed = .{
                                    .base = base,
                                    .index = index,
                                } },
                            });
                            const rhs = try b.lowerExpression(assign_expr.rhs_expression);
                            const result = try b.addInst(.{
                                .tag = binary_tag,
                                .data = .{ .binary = .{
                                    .lhs = current_value,
                                    .rhs = rhs,
                                } },
                            });
                            const set_tag: Ir.Inst.Tag = if (b.in_strict_mode)
                                .set_property_indexed_strict
                            else
                                .set_property_indexed;
                            const extra_index = try b.addExtra(Ir.Inst.SetPropertyIndexed, .{
                                .base = base,
                                .index = index,
                                .value = result,
                            });
                            return b.addInst(.{
                                .tag = set_tag,
                                .data = .{ .set_property_indexed = extra_index },
                            });
                        }
                        if (constant == .string) {
                            const string_index = try b.internString(constant.string);
                            const current_value = try b.addInst(.{
                                .tag = .get_property,
                                .data = .{ .get_property = .{
                                    .base = base,
                                    .name = string_index,
                                } },
                            });
                            const rhs = try b.lowerExpression(assign_expr.rhs_expression);
                            const result = try b.addInst(.{
                                .tag = binary_tag,
                                .data = .{ .binary = .{
                                    .lhs = current_value,
                                    .rhs = rhs,
                                } },
                            });
                            const set_tag: Ir.Inst.Tag = if (b.in_strict_mode)
                                .set_property_strict
                            else
                                .set_property;
                            const extra_index = try b.addExtra(Ir.Inst.SetProperty, .{
                                .base = base,
                                .name = string_index,
                                .value = result,
                            });
                            return b.addInst(.{
                                .tag = set_tag,
                                .data = .{ .set_property = extra_index },
                            });
                        }
                    }
                    const property = try b.lowerExpression(expr);
                    const current_value = try b.addInst(.{
                        .tag = .get_property_computed,
                        .data = .{ .get_property_computed = .{
                            .base = base,
                            .property = property,
                        } },
                    });
                    const rhs = try b.lowerExpression(assign_expr.rhs_expression);
                    const result = try b.addInst(.{
                        .tag = binary_tag,
                        .data = .{ .binary = .{
                            .lhs = current_value,
                            .rhs = rhs,
                        } },
                    });
                    const set_tag: Ir.Inst.Tag = if (b.in_strict_mode)
                        .set_property_computed_strict
                    else
                        .set_property_computed;
                    const extra_index = try b.addExtra(Ir.Inst.SetPropertyComputed, .{
                        .base = base,
                        .property = property,
                        .value = result,
                    });
                    return b.addInst(.{
                        .tag = set_tag,
                        .data = .{ .set_property_computed = extra_index },
                    });
                },
                .private_identifier => |private_identifier| {
                    const string_index = try b.internString(private_identifier);
                    const current_value = try b.addInst(.{
                        .tag = .get_private_element,
                        .data = .{ .get_property = .{
                            .base = base,
                            .name = string_index,
                        } },
                    });
                    const rhs = try b.lowerExpression(assign_expr.rhs_expression);
                    const result = try b.addInst(.{
                        .tag = binary_tag,
                        .data = .{ .binary = .{
                            .lhs = current_value,
                            .rhs = rhs,
                        } },
                    });
                    const extra_index = try b.addExtra(Ir.Inst.SetProperty, .{
                        .base = base,
                        .name = string_index,
                        .value = result,
                    });
                    return b.addInst(.{
                        .tag = .set_private_element,
                        .data = .{ .set_property = extra_index },
                    });
                },
            }
        },
        .super_property => |super_prop| switch (super_prop) {
            .identifier => |identifier| {
                const string_index = try b.internString(identifier);
                const current_value = try b.addInst(.{
                    .tag = .get_super_property,
                    .data = .{ .string = string_index },
                });
                const rhs = try b.lowerExpression(assign_expr.rhs_expression);
                const result = try b.addInst(.{
                    .tag = binary_tag,
                    .data = .{ .binary = .{
                        .lhs = current_value,
                        .rhs = rhs,
                    } },
                });
                const set_tag: Ir.Inst.Tag = if (b.in_strict_mode)
                    .set_super_property_strict
                else
                    .set_super_property;
                const extra_index = try b.addExtra(Ir.Inst.SetProperty, .{
                    .base = .none,
                    .name = string_index,
                    .value = result,
                });
                return b.addInst(.{
                    .tag = set_tag,
                    .data = .{ .set_property = extra_index },
                });
            },
            .expression => |expr| {
                const property = try b.lowerExpression(expr);
                const current_value = try b.addInst(.{
                    .tag = .get_super_property_computed,
                    .data = .{ .ref = property },
                });
                const rhs = try b.lowerExpression(assign_expr.rhs_expression);
                const result = try b.addInst(.{
                    .tag = binary_tag,
                    .data = .{ .binary = .{
                        .lhs = current_value,
                        .rhs = rhs,
                    } },
                });
                const set_tag: Ir.Inst.Tag = if (b.in_strict_mode)
                    .set_super_property_computed_strict
                else
                    .set_super_property_computed;
                const extra_index = try b.addExtra(Ir.Inst.SetPropertyComputed, .{
                    .base = .none,
                    .property = property,
                    .value = result,
                });
                return b.addInst(.{
                    .tag = set_tag,
                    .data = .{ .set_property_computed = extra_index },
                });
            },
        },
        .call_expression => |*call_expr| {
            _ = try b.lowerCallExpression(call_expr);
            return b.addInst(.{
                .tag = .throw_reference_error,
                .data = .{ .none = {} },
            });
        },
        else => unreachable,
    }
}

fn lowerLogicalCompoundAssignmentExpression(b: *Builder, assign_expr: *const ast.AssignmentExpression) Error!Ir.Inst.Ref {
    const Lhs = union(enum) {
        binding: Ir.StringIndex,
        property: struct { base: Ir.Inst.Ref, name: Ir.StringIndex },
        property_indexed: struct { base: Ir.Inst.Ref, index: u32 },
        property_computed: struct { base: Ir.Inst.Ref, property: Ir.Inst.Ref },
        private_element: struct { base: Ir.Inst.Ref, name: Ir.StringIndex },
        super_property: Ir.StringIndex,
        super_property_computed: Ir.Inst.Ref,
    };

    var lhs: Lhs = undefined;
    const current_value: Ir.Inst.Ref = switch (assign_expr.lhs_expression.*) {
        .primary_expression => |prim_expr| switch (prim_expr) {
            .identifier_reference => |identifier| blk: {
                const string_index = try b.internString(identifier);
                lhs = .{ .binding = string_index };
                break :blk try b.addInst(.{
                    .tag = .get_binding,
                    .data = .{ .string = string_index },
                });
            },
            else => unreachable,
        },
        .member_expression => |*member_expr| blk: {
            const base = try b.lowerExpression(member_expr.expression);
            switch (member_expr.property) {
                .identifier => |identifier| {
                    const string_index = try b.internString(identifier);
                    lhs = .{ .property = .{
                        .base = base,
                        .name = string_index,
                    } };
                    break :blk try b.addInst(.{
                        .tag = .get_property,
                        .data = .{ .get_property = .{
                            .base = base,
                            .name = string_index,
                        } },
                    });
                },
                .expression => |expr| {
                    if (try constantFold(b.gpa, expr)) |constant| {
                        defer constant.deinit(b.gpa);
                        if (constant.toIndex()) |index| {
                            lhs = .{ .property_indexed = .{
                                .base = base,
                                .index = index,
                            } };
                            break :blk try b.addInst(.{
                                .tag = .get_property_indexed,
                                .data = .{ .get_property_indexed = .{
                                    .base = base,
                                    .index = index,
                                } },
                            });
                        }
                        if (constant == .string) {
                            const string_index = try b.internString(constant.string);
                            lhs = .{ .property = .{
                                .base = base,
                                .name = string_index,
                            } };
                            break :blk try b.addInst(.{
                                .tag = .get_property,
                                .data = .{ .get_property = .{
                                    .base = base,
                                    .name = string_index,
                                } },
                            });
                        }
                    }
                    const property = try b.lowerExpression(expr);
                    lhs = .{ .property_computed = .{
                        .base = base,
                        .property = property,
                    } };
                    break :blk try b.addInst(.{
                        .tag = .get_property_computed,
                        .data = .{ .get_property_computed = .{
                            .base = base,
                            .property = property,
                        } },
                    });
                },
                .private_identifier => |private_identifier| {
                    const string_index = try b.internString(private_identifier);
                    lhs = .{ .private_element = .{
                        .base = base,
                        .name = string_index,
                    } };
                    break :blk try b.addInst(.{
                        .tag = .get_private_element,
                        .data = .{ .get_property = .{
                            .base = base,
                            .name = string_index,
                        } },
                    });
                },
            }
        },
        .super_property => |super_prop| blk: {
            switch (super_prop) {
                .identifier => |identifier| {
                    const string_index = try b.internString(identifier);
                    lhs = .{ .super_property = string_index };
                    break :blk try b.addInst(.{
                        .tag = .get_super_property,
                        .data = .{ .string = string_index },
                    });
                },
                .expression => |expr| {
                    const property = try b.lowerExpression(expr);
                    lhs = .{ .super_property_computed = property };
                    break :blk try b.addInst(.{
                        .tag = .get_super_property_computed,
                        .data = .{ .ref = property },
                    });
                },
            }
        },
        else => unreachable,
    };

    const condition, const then_target_is_assign = switch (assign_expr.operator) {
        .@"&&=" => .{ try b.addInst(.{
            .tag = .to_boolean,
            .data = .{ .ref = current_value },
        }), true },
        .@"||=" => .{ try b.addInst(.{
            .tag = .to_boolean,
            .data = .{ .ref = current_value },
        }), false },
        .@"??=" => .{ try b.addInst(.{
            .tag = .is_nullish,
            .data = .{ .ref = current_value },
        }), true },
        else => unreachable,
    };
    const br_cond = try b.addInstDeferred(.br_cond);

    const assign_label = try b.addLabel();

    const rhs = try b.lowerExpression(assign_expr.rhs_expression);
    switch (lhs) {
        .binding => |name| {
            const tag: Ir.Inst.Tag = if (b.in_strict_mode)
                .set_binding_strict
            else
                .set_binding;
            _ = try b.addInst(.{
                .tag = tag,
                .data = .{ .set_binding = .{
                    .name = name,
                    .value = rhs,
                } },
            });
        },
        .property => |p| {
            const tag: Ir.Inst.Tag = if (b.in_strict_mode)
                .set_property_strict
            else
                .set_property;
            const extra_index = try b.addExtra(Ir.Inst.SetProperty, .{
                .base = p.base,
                .name = p.name,
                .value = rhs,
            });
            _ = try b.addInst(.{
                .tag = tag,
                .data = .{ .set_property = extra_index },
            });
        },
        .property_indexed => |p| {
            const tag: Ir.Inst.Tag = if (b.in_strict_mode)
                .set_property_indexed_strict
            else
                .set_property_indexed;
            const extra_index = try b.addExtra(Ir.Inst.SetPropertyIndexed, .{
                .base = p.base,
                .index = p.index,
                .value = rhs,
            });
            _ = try b.addInst(.{
                .tag = tag,
                .data = .{ .set_property_indexed = extra_index },
            });
        },
        .property_computed => |p| {
            const tag: Ir.Inst.Tag = if (b.in_strict_mode)
                .set_property_computed_strict
            else
                .set_property_computed;
            const extra_index = try b.addExtra(Ir.Inst.SetPropertyComputed, .{
                .base = p.base,
                .property = p.property,
                .value = rhs,
            });
            _ = try b.addInst(.{
                .tag = tag,
                .data = .{ .set_property_computed = extra_index },
            });
        },
        .private_element => |p| {
            const extra_index = try b.addExtra(Ir.Inst.SetProperty, .{
                .base = p.base,
                .name = p.name,
                .value = rhs,
            });
            _ = try b.addInst(.{
                .tag = .set_private_element,
                .data = .{ .set_property = extra_index },
            });
        },
        .super_property => |string_index| {
            const tag: Ir.Inst.Tag = if (b.in_strict_mode)
                .set_super_property_strict
            else
                .set_super_property;
            const extra_index = try b.addExtra(Ir.Inst.SetProperty, .{
                .base = .none,
                .name = string_index,
                .value = rhs,
            });
            _ = try b.addInst(.{
                .tag = tag,
                .data = .{ .set_property = extra_index },
            });
        },
        .super_property_computed => |property| {
            const tag: Ir.Inst.Tag = if (b.in_strict_mode)
                .set_super_property_computed_strict
            else
                .set_super_property_computed;
            const extra_index = try b.addExtra(Ir.Inst.SetPropertyComputed, .{
                .base = .none,
                .property = property,
                .value = rhs,
            });
            _ = try b.addInst(.{
                .tag = tag,
                .data = .{ .set_property_computed = extra_index },
            });
        },
    }

    const assign_br = try b.addInstDeferred(.br);

    const skip_label = try b.addLabel();
    const skip_br = try b.addInstDeferred(.br);

    const end_label = try b.addLabel();

    br_cond.set(.{ .br_cond = .{
        .condition = condition,
        .then_target = if (then_target_is_assign) assign_label else skip_label,
        .else_target = if (then_target_is_assign) skip_label else assign_label,
    } });
    assign_br.set(.{ .br = .{
        .target = end_label,
        .value = rhs,
    } });
    skip_br.set(.{ .br = .{
        .target = end_label,
        .value = current_value,
    } });

    return end_label;
}

fn lowerSequenceExpression(b: *Builder, seq_expr: *const ast.SequenceExpression) Error!Ir.Inst.Ref {
    var last: Ir.Inst.Ref = undefined;
    for (seq_expr.expressions) |*expr| {
        last = try b.lowerExpression(expr);
    }
    return last;
}

fn lowerAwaitExpression(b: *Builder, await_expr: *const ast.AwaitExpression) Error!Ir.Inst.Ref {
    const value = try b.lowerExpression(await_expr.expression);
    return b.addInst(.{
        .tag = .await,
        .data = .{ .ref = value },
    });
}

fn lowerYieldExpression(b: *Builder, yield_expr: *const ast.YieldExpression) Error!Ir.Inst.Ref {
    switch (yield_expr.*) {
        .none => {
            const value = try b.addInst(.{
                .tag = .undefined,
                .data = .{ .none = {} },
            });
            return b.addInst(.{
                .tag = .yield,
                .data = .{ .ref = value },
            });
        },
        .expression => |expr| {
            const value = try b.lowerExpression(expr);
            return b.addInst(.{
                .tag = .yield,
                .data = .{ .ref = value },
            });
        },
        .delegate => |expr| {
            const value = try b.lowerExpression(expr);
            const iterator = try b.addInst(.{
                .tag = switch (b.root_node.function.body.type) {
                    .generator => .get_iterator,
                    .async_generator => .get_async_iterator,
                    else => unreachable,
                },
                .data = .{ .ref = value },
            });
            return b.addInst(.{
                .tag = .yield_star,
                .data = .{ .ref = iterator },
            });
        },
    }
}

fn lowerTaggedTemplate(b: *Builder, tagged_template: *const ast.TaggedTemplate) Error!Ir.Inst.Ref {
    var this_value: Ir.Inst.Ref = .none;
    const callee = switch (tagged_template.expression.*) {
        .member_expression => |*member_expr| try b.lowerMemberExpression(member_expr, &this_value),
        else => try b.lowerExpression(tagged_template.expression),
    };

    const template_literal = &tagged_template.template_literal;

    var raw_indices: std.ArrayList(Ir.StringIndex) = .empty;
    defer raw_indices.deinit(b.gpa);
    var cooked_indices: std.ArrayList(?Ir.StringIndex) = .empty;
    defer cooked_indices.deinit(b.gpa);

    for (template_literal.spans, 0..) |span, i| {
        if (i % 2 != 0) {
            std.debug.assert(span == .expression);
            continue;
        }

        var aw: std.Io.Writer.Allocating = .init(b.gpa);
        defer aw.deinit();
        {
            const valid = span.template.rawValue(&aw.writer) catch return error.OutOfMemory;
            std.debug.assert(valid);
            try raw_indices.append(b.gpa, try b.internString(aw.written()));
        }
        aw.clearRetainingCapacity();
        {
            const valid = span.template.value(&aw.writer) catch return error.OutOfMemory;
            if (valid)
                try cooked_indices.append(b.gpa, try b.internString(aw.written()))
            else
                try cooked_indices.append(b.gpa, null);
        }
    }

    const raw_array = blk: {
        const array_ref = try b.addInst(.{
            .tag = .create_array,
            .data = .{ .array = .{
                .len = @intCast(raw_indices.items.len),
                .has_spread = false,
            } },
        });
        for (raw_indices.items) |string_index| {
            const ref = try b.addInst(.{ .tag = .string, .data = .{
                .string = string_index,
            } });
            _ = try b.addInst(.{
                .tag = .array_push,
                .data = .{ .binary = .{
                    .lhs = array_ref,
                    .rhs = ref,
                } },
            });
        }
        break :blk array_ref;
    };

    const cooked_array = blk: {
        const array_ref = try b.addInst(.{
            .tag = .create_array,
            .data = .{ .array = .{
                .len = @intCast(cooked_indices.items.len),
                .has_spread = false,
            } },
        });
        for (cooked_indices.items) |maybe_string_index| {
            const ref = if (maybe_string_index) |string_index|
                try b.addInst(.{
                    .tag = .string,
                    .data = .{ .string = string_index },
                })
            else
                try b.addInst(.{
                    .tag = .undefined,
                    .data = .{ .none = {} },
                });
            _ = try b.addInst(.{
                .tag = .array_push,
                .data = .{ .binary = .{
                    .lhs = array_ref,
                    .rhs = ref,
                } },
            });
        }
        break :blk array_ref;
    };

    const template_id = b.template_object_count;
    b.template_object_count += 1;
    const get_template_object_extra_index = try b.addExtra(Ir.Inst.GetTemplateObject, .{
        .raw = raw_array,
        .cooked = cooked_array,
        .id = template_id,
    });

    const template_object = try b.addInst(.{
        .tag = .get_template_object,
        .data = .{ .get_template_object = get_template_object_extra_index },
    });

    const substitution_count = template_literal.spans.len / 2;
    var args: std.ArrayList(Ir.Inst.Ref) = try .initCapacity(b.gpa, 1 + substitution_count);
    defer args.deinit(b.gpa);
    args.appendAssumeCapacity(template_object);

    for (template_literal.spans, 0..) |span, i| {
        if (i % 2 == 0) {
            std.debug.assert(span == .template);
            continue;
        }
        const expr_ref = try b.lowerExpression(&span.expression);
        args.appendAssumeCapacity(expr_ref);
    }

    const call_extra_index = try b.addExtra(Ir.Inst.Call, .{
        .callee = callee,
        .this_value = this_value,
        .args_len = @intCast(args.items.len),
    });
    try b.extra.appendSlice(b.gpa, @ptrCast(args.items));

    return b.addInst(.{
        .tag = .call,
        .data = .{ .call = call_extra_index },
    });
}
