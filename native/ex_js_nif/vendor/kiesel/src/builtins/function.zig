//! 20.2 Function Objects
//! https://tc39.es/ecma262/#sec-function-objects

const std = @import("std");

const ast = @import("../language/ast.zig");
const builtins = @import("../builtins.zig");
const execution = @import("../execution.zig");
const language = @import("../language.zig");
const types = @import("../types.zig");

const Agent = execution.Agent;
const Arguments = types.Arguments;
const BuiltinFunction = builtins.BuiltinFunction;
const ClassConstructorFields = builtins.builtin_function.ClassConstructorFields;
const Diagnostics = language.Diagnostics;
const ECMAScriptFunction = builtins.ECMAScriptFunction;
const Object = types.Object;
const Parser = language.Parser;
const PropertyKey = types.PropertyKey;
const Realm = execution.Realm;
const String = types.String;
const Value = types.Value;
const boundFunctionCreate = builtins.boundFunctionCreate;
const createBuiltinFunction = builtins.createBuiltinFunction;
const getPrototypeFromConstructor = builtins.getPrototypeFromConstructor;
const makeConstructor = builtins.makeConstructor;
const ordinaryFunctionCreate = builtins.ordinaryFunctionCreate;
const ordinaryObjectCreate = builtins.ordinaryObjectCreate;
const setFunctionLength = builtins.setFunctionLength;
const setFunctionName = builtins.setFunctionName;

fn GrammarSymbol(comptime T: type) type {
    return struct {
        type: type = T,
        acceptFn: fn (*Parser) Parser.AcceptError!T = undefined,
    };
}

/// 20.2.2 Properties of the Function Constructor
/// https://tc39.es/ecma262/#sec-properties-of-the-function-constructor
pub const constructor = struct {
    pub fn create(agent: *Agent, realm: *Realm) std.mem.Allocator.Error!*Object {
        const builtin_function = try createBuiltinFunction(
            agent,
            .{ .constructor = impl },
            1,
            "Function",
            .{ .realm = realm, .proto = try realm.intrinsic(.function_prototype) },
        );
        return &builtin_function.object;
    }

    pub fn init(agent: *Agent, realm: *Realm, object: *Object) std.mem.Allocator.Error!void {
        // 20.2.2.1 Function.prototype
        // https://tc39.es/ecma262/#sec-function.prototype
        try object.defineBuiltinPropertyWithAttributes(
            agent,
            "prototype",
            Value.from(realm.intrinsic(.function_prototype) catch unreachable),
            .none,
        );
    }

    /// 20.2.1.1 Function ( ...paramArgs, bodyArg )
    /// https://tc39.es/ecma262/#sec-function-p1-p2-pn-body
    fn impl(agent: *Agent, arguments: Arguments, new_target: ?*Object) Agent.Error!Value {
        const param_args = arguments.values[0..arguments.count() -| 1];
        const maybe_body_arg = arguments.getOrNull(arguments.count() -| 1);

        // 1. Let ctor be the active function object.
        const ctor = agent.activeFunctionObject();

        // 2. If bodyArg is not present, set bodyArg to the empty String.
        const body_arg = maybe_body_arg orelse Value.from("");

        // 3. Return ? CreateDynamicFunction(ctor, NewTarget, normal, paramArgs, bodyArg).
        const ecmascript_function = try createDynamicFunction(
            agent,
            ctor,
            new_target,
            .normal,
            param_args,
            body_arg,
        );
        return Value.from(&ecmascript_function.object);
    }
};

/// 20.2.1.1.1 CreateDynamicFunction ( ctor, newTarget, kind, paramArgs, bodyArg )
/// https://tc39.es/ecma262/#sec-createdynamicfunction
pub fn createDynamicFunction(
    agent: *Agent,
    ctor: *Object,
    maybe_new_target: ?*Object,
    comptime kind: enum {
        normal,
        generator,
        async,
        async_generator,
    },
    param_args: []const Value,
    body_arg: Value,
) Agent.Error!*ECMAScriptFunction {
    const gpa = agent.gpa;
    const realm = agent.currentRealm();

    // 1. If newTarget is undefined, set newTarget to ctor.
    const new_target = maybe_new_target orelse ctor;

    comptime var prefix: []const u8 = undefined;
    comptime var fallback_proto: Realm.Intrinsic = undefined;
    comptime var expr_grammar: GrammarSymbol(switch (kind) {
        .normal => ast.FunctionExpression,
        .generator => ast.GeneratorExpression,
        .async => ast.AsyncFunctionExpression,
        .async_generator => ast.AsyncGeneratorExpression,
    }) = .{};
    comptime var body_grammar: GrammarSymbol(ast.FunctionBody) = .{};
    comptime var param_grammar: GrammarSymbol(ast.FormalParameters) = .{};

    switch (kind) {
        // 2. If kind is normal, then
        .normal => {
            // a. Let prefix be "function".
            prefix = "function";

            // b. Let exprGrammar be the grammar symbol FunctionExpression.
            expr_grammar.acceptFn = struct {
                fn accept(parser: *Parser) Parser.AcceptError!ast.FunctionExpression {
                    return parser.acceptFunctionExpression();
                }
            }.accept;

            // c. Let bodyGrammar be the grammar symbol FunctionBody[~Yield, ~Await].
            body_grammar.acceptFn = struct {
                fn accept(parser: *Parser) Parser.AcceptError!ast.FunctionBody {
                    return parser.acceptFunctionBody(.normal);
                }
            }.accept;

            // d. Let paramGrammar be the grammar symbol FormalParameters[~Yield, ~Await].
            param_grammar.acceptFn = struct {
                fn accept(parser: *Parser) Parser.AcceptError!ast.FormalParameters {
                    return parser.acceptFormalParameters();
                }
            }.accept;

            // e. Let fallbackProto be "%Function.prototype%".
            fallback_proto = .function_prototype;
        },

        // 3. Else if kind is generator, then
        .generator => {
            // a. Let prefix be "function*".
            prefix = "function*";

            // b. Let exprGrammar be the grammar symbol GeneratorExpression.
            expr_grammar.acceptFn = struct {
                fn accept(parser: *Parser) Parser.AcceptError!ast.GeneratorExpression {
                    return parser.acceptGeneratorExpression();
                }
            }.accept;

            // c. Let bodyGrammar be the grammar symbol GeneratorBody.
            body_grammar.acceptFn = struct {
                fn accept(parser: *Parser) Parser.AcceptError!ast.FunctionBody {
                    return parser.acceptFunctionBody(.generator);
                }
            }.accept;

            // d. Let paramGrammar be the grammar symbol FormalParameters[+Yield, ~Await].
            param_grammar.acceptFn = struct {
                fn accept(parser: *Parser) Parser.AcceptError!ast.FormalParameters {
                    return parser.acceptFormalParameters();
                }
            }.accept;

            // e. Let fallbackProto be "%GeneratorFunction.prototype%".
            fallback_proto = .generator_function_prototype;
        },

        // 4. Else if kind is async, then
        .async => {
            // a. Let prefix be "async function".
            prefix = "async function";

            // b. Let exprGrammar be the grammar symbol AsyncFunctionExpression.
            expr_grammar.acceptFn = struct {
                fn accept(parser: *Parser) Parser.AcceptError!ast.AsyncFunctionExpression {
                    return parser.acceptAsyncFunctionExpression();
                }
            }.accept;

            // c. Let bodyGrammar be the grammar symbol AsyncFunctionBody.
            body_grammar.acceptFn = struct {
                fn accept(parser: *Parser) Parser.AcceptError!ast.FunctionBody {
                    return parser.acceptFunctionBody(.async);
                }
            }.accept;

            // d. Let paramGrammar be the grammar symbol FormalParameters[~Yield, +Await].
            param_grammar.acceptFn = struct {
                fn accept(parser: *Parser) Parser.AcceptError!ast.FormalParameters {
                    return parser.acceptFormalParameters();
                }
            }.accept;

            // e. Let fallbackProto be "%AsyncFunction.prototype%".
            fallback_proto = .async_function_prototype;
        },

        // 5. Else,
        .async_generator => {
            // a. Assert: kind is async-generator.

            // b. Let prefix be "async function*".
            prefix = "async function*";

            // c. Let exprGrammar be the grammar symbol AsyncGeneratorExpression.
            expr_grammar.acceptFn = struct {
                fn accept(parser: *Parser) Parser.AcceptError!ast.AsyncGeneratorExpression {
                    return parser.acceptAsyncGeneratorExpression();
                }
            }.accept;

            // d. Let bodyGrammar be the grammar symbol AsyncGeneratorBody.
            body_grammar.acceptFn = struct {
                fn accept(parser: *Parser) Parser.AcceptError!ast.FunctionBody {
                    return parser.acceptFunctionBody(.async_generator);
                }
            }.accept;

            // e. Let paramGrammar be the grammar symbol FormalParameters[+Yield, +Await].
            param_grammar.acceptFn = struct {
                fn accept(parser: *Parser) Parser.AcceptError!ast.FormalParameters {
                    return parser.acceptFormalParameters();
                }
            }.accept;

            // f. Let fallbackProto be "%AsyncGeneratorFunction.prototype%".
            fallback_proto = .async_generator_function_prototype;
        },
    }

    // 6. Let argCount be the number of elements in paramArgs.
    const arg_count = param_args.len;

    // 7. Let paramStrings be a new empty List.
    var param_strings = try std.ArrayList(*const String).initCapacity(
        agent.gc_allocator,
        param_args.len,
    );
    defer param_strings.deinit(agent.gc_allocator);

    // 8. For each element arg of paramArgs, do
    for (param_args) |arg| {
        // a. Append ? ToString(arg) to paramStrings.
        param_strings.appendAssumeCapacity(try arg.toString(agent));
    }

    // 9. Let bodyString be ? ToString(bodyArg).
    const body_string = try body_arg.toString(agent);

    // 10. Let currentRealm be the current Realm Record.
    const current_realm = realm;

    // 11. Perform ? HostEnsureCanCompileStrings(currentRealm, paramStrings, bodyString, false).
    try agent.host_hooks.hostEnsureCanCompileStrings(current_realm, param_strings.items, body_string, false);

    // 12. Let paramString be the empty String.
    var result: String.Builder = .empty;
    defer result.deinit(agent.gc_allocator);

    // 13. If argCount > 0, then
    if (arg_count > 0) {
        // a. Set paramString to paramStrings[0].
        // b. Let k be 1.
        // c. Repeat, while k < argCount,
        //     i. Let nextArgString be paramStrings[k].
        //     ii. Set paramString to the string-concatenation of paramString, "," (a comma), and
        //         nextArgString.
        //     iii. Set k to k + 1.
        for (param_strings.items, 0..) |next_arg_string, k| {
            if (k > 0) try result.appendChar(agent.gc_allocator, ',');
            try result.appendString(agent.gc_allocator, next_arg_string);
        }
    }

    const parameters_wtf8 = try (try result.build(agent)).toWtf8(gpa);
    defer gpa.free(parameters_wtf8);
    const parameters_string = try gpa.dupeSentinel(u8, parameters_wtf8, 0);
    defer gpa.free(parameters_string);

    // 14. Let bodyParseString be the string-concatenation of 0x000A (LINE FEED), bodyString, and
    //     0x000A (LINE FEED).
    const body_wtf8 = try body_string.toWtf8(gpa);
    defer gpa.free(body_wtf8);
    const body_parse_string = try gpa.printSentinel("\n{s}\n", .{body_wtf8}, 0);
    defer gpa.free(body_parse_string);

    // 15. Let sourceString be the string-concatenation of prefix, " anonymous(", paramString,
    //     0x000A (LINE FEED), ") {", bodyParseString, and "}".
    // 16. Let sourceText be StringToCodePoints(sourceString).
    const source_text = try agent.gc_allocator.printSentinel(
        "{[prefix]s} anonymous({[parameters_string]s}\n) {{{[body_parse_string]s}}}",
        .{ .prefix = prefix, .parameters_string = parameters_string, .body_parse_string = body_parse_string },
        0,
    );

    const state: Parser.State = switch (kind) {
        .normal => .{},
        .generator => .{ .in_generator_function = true },
        .async => .{ .in_async_function = true },
        .async_generator => .{ .in_async_function = true, .in_generator_function = true },
    };

    // 17. Let params be ParseText(paramString, paramGrammar).
    const params = blk: {
        var diagnostics: Diagnostics = .init(gpa, .{
            .source = parameters_string,
            .file_name = "Function",
        });
        defer diagnostics.deinit();

        break :blk Parser.parseNode(param_grammar.type, param_grammar.acceptFn, agent.gc_allocator, parameters_string, .{
            .diagnostics = &diagnostics,
            .state = state,
        }) catch |err| switch (err) {
            error.OutOfMemory => |e| return e,
            error.ParseError => {
                // 18. If params is a List of errors, throw a SyntaxError exception.
                const parse_error = diagnostics.first().?;
                return agent.throwException(.syntax_error, "{f}", .{parse_error.fmt(&diagnostics)});
            },
        };
    };

    // 19. Let body be ParseText(bodyParseString, bodyGrammar).
    const body = blk: {
        var diagnostics: Diagnostics = .init(gpa, .{
            .source = body_parse_string,
            .file_name = "Function",
        });
        defer diagnostics.deinit();

        break :blk Parser.parseNode(body_grammar.type, body_grammar.acceptFn, agent.gc_allocator, body_parse_string, .{
            .diagnostics = &diagnostics,
            .state = state,
        }) catch |err| switch (err) {
            error.OutOfMemory => |e| return e,
            error.ParseError => {
                // 20. If body is a List of errors, throw a SyntaxError exception.
                const parse_error = diagnostics.first().?;
                return agent.throwException(.syntax_error, "{f}", .{parse_error.fmt(&diagnostics)});
            },
        };
    };

    // 21. NOTE: The parameters and body are parsed separately to ensure that each is valid alone.
    //     For example, `new Function("/*", "*/ ) {")` does not evaluate to a function.

    // 22. NOTE: If this step is reached, sourceText must have the syntax of exprGrammar (although
    //     the reverse implication does not hold). The purpose of the next two steps is to enforce
    //     any Early Error rules which apply to exprGrammar directly.

    // 23. Let expr be ParseText(sourceText, exprGrammar).
    {
        var diagnostics: Diagnostics = .init(gpa, .{
            .source = source_text,
            .file_name = "Function",
        });
        defer diagnostics.deinit();

        _ = Parser.parseNode(expr_grammar.type, expr_grammar.acceptFn, agent.gc_allocator, source_text, .{
            .diagnostics = &diagnostics,
        }) catch |err| switch (err) {
            error.OutOfMemory => |e| return e,
            error.ParseError => {
                // 24. If expr is a List of errors, throw a SyntaxError exception.
                const parse_error = diagnostics.first().?;
                return agent.throwException(.syntax_error, "{f}", .{parse_error.fmt(&diagnostics)});
            },
        };
    }

    // 25. Let funcProto be ? GetPrototypeFromConstructor(newTarget, fallbackProto).
    const func_proto = try getPrototypeFromConstructor(agent, new_target, fallback_proto);

    // 26. Let envRecord be currentRealm.[[GlobalEnv]].
    const env = current_realm.global_env;

    // 27. Let privateEnv be null.
    const private_env = null;

    // 28. Let func be OrdinaryFunctionCreate(funcProto, sourceText, params, body, non-lexical-this,
    //     envRecord, privateEnv).
    const source = try String.fromWtf8(agent, source_text);
    const func = try ordinaryFunctionCreate(
        agent,
        func_proto,
        .{ .string = source },
        params,
        body,
        .non_lexical_this,
        .{ .global_environment = env },
        private_env,
    );

    // 29. Perform SetFunctionName(func, "anonymous").
    try setFunctionName(agent, &func.object, PropertyKey.from("anonymous"), null);

    switch (kind) {
        // 30. If kind is generator, then
        .generator => {
            // a. Let protoProto be OrdinaryObjectCreate(%GeneratorPrototype%).
            const proto_proto = try ordinaryObjectCreate(
                agent,
                try realm.intrinsic(.generator_prototype),
            );

            // b. Perform ! DefinePropertyOrThrow(func, "prototype", PropertyDescriptor {
            //    [[Value]]: protoProto, [[Writable]]: true, [[Enumerable]]: false,
            //    [[Configurable]]: false }).
            try func.object.definePropertyDirect(agent, PropertyKey.from("prototype"), .{
                .value_or_accessor = .{
                    .value = Value.from(proto_proto),
                },
                .attributes = .{
                    .writable = true,
                    .enumerable = false,
                    .configurable = false,
                },
            });
        },

        // 31. Else if kind is async-generator, then
        .async_generator => {
            // a. Let protoProto be OrdinaryObjectCreate(%AsyncGeneratorPrototype%).
            const proto_proto = try ordinaryObjectCreate(
                agent,
                try realm.intrinsic(.async_generator_prototype),
            );

            // b. Perform ! DefinePropertyOrThrow(func, "prototype", PropertyDescriptor {
            //    [[Value]]: protoProto, [[Writable]]: true, [[Enumerable]]: false,
            //    [[Configurable]]: false }).
            try func.object.definePropertyDirect(agent, PropertyKey.from("prototype"), .{
                .value_or_accessor = .{
                    .value = Value.from(proto_proto),
                },
                .attributes = .{
                    .writable = true,
                    .enumerable = false,
                    .configurable = false,
                },
            });
        },

        // 32. Else if kind is normal, then
        .normal => {
            // a. Perform MakeConstructor(func).
            try makeConstructor(agent, &func.object, .{});
        },

        // 33. NOTE: Functions whose kind is async are not constructable and do not have a
        //     [[Construct]] internal method or a "prototype" property.
        .async => {},
    }

    // 34. Return func.
    return func;
}

/// 20.2.3 Properties of the Function Prototype Object
/// https://tc39.es/ecma262/#sec-properties-of-the-function-prototype-object
pub const prototype = struct {
    pub fn create(agent: *Agent, realm: *Realm) std.mem.Allocator.Error!*Object {
        const builtin_function = try createBuiltinFunction(
            agent,
            .{ .function = function },
            0,
            "",
            .{ .realm = realm, .proto = try realm.intrinsic(.object_prototype) },
        );
        return &builtin_function.object;
    }

    pub fn init(agent: *Agent, realm: *Realm, object: *Object) std.mem.Allocator.Error!void {
        try object.defineBuiltinFunction(agent, "apply", apply, 2, realm);
        try object.defineBuiltinFunction(agent, "bind", bind, 1, realm);
        try object.defineBuiltinFunction(agent, "call", call, 1, realm);
        try object.defineBuiltinFunction(agent, "toString", toString, 0, realm);
        try object.defineBuiltinFunctionWithAttributes(
            agent,
            "Symbol.hasInstance",
            @"Symbol.hasInstance",
            1,
            realm,
            .none,
        );

        // 20.2.3.4 Function.prototype.constructor
        // https://tc39.es/ecma262/#sec-function.prototype.constructor
        try object.defineBuiltinProperty(
            agent,
            "constructor",
            Value.from(try realm.intrinsic(.function)),
        );
    }

    fn function(_: *Agent, _: Value, _: Arguments) Agent.Error!Value {
        return .undefined;
    }

    /// 20.2.3.1 Function.prototype.apply ( thisArg, argArray )
    /// https://tc39.es/ecma262/#sec-function.prototype.apply
    fn apply(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const this_arg = arguments.get(0);
        const arg_array = arguments.get(1);

        // 1. Let func be the this value.
        // 2. If IsCallable(func) is false, throw a TypeError exception.
        if (!this_value.isCallable()) {
            return agent.throwException(.type_error, "{f} is not a function", .{this_value});
        }
        const func = this_value.asObject();

        // 3. If argArray is either undefined or null, then
        if (arg_array.isUndefined() or arg_array.isNull()) {
            // a. Perform PrepareForTailCall().
            // b. Return ? Call(func, thisArg).
            return func.call(agent, this_arg, &.{});
        }

        // 4. Let argList be ? CreateListFromArrayLike(argArray).
        const arg_list = try arg_array.createListFromArrayLike(agent, null);

        // 5. Perform PrepareForTailCall().
        // 6. Return ? Call(func, thisArg, argList).
        return func.call(agent, this_arg, arg_list);
    }

    /// 20.2.3.2 Function.prototype.bind ( thisArg, ...args )
    /// https://tc39.es/ecma262/#sec-function.prototype.bind
    fn bind(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const this_arg = arguments.get(0);
        const args = if (arguments.count() <= 1) &[_]Value{} else arguments.values[1..];

        // 1. Let target be the this value.
        const target = this_value;

        // 2. If IsCallable(target) is false, throw a TypeError exception.
        if (!target.isCallable()) {
            return agent.throwException(.type_error, "{f} is not a function", .{target});
        }

        // 3. Let boundFunc be ? BoundFunctionCreate(target, thisArg, args).
        const bound_func = try boundFunctionCreate(agent, target.asObject(), this_arg, args);

        // 4. Let length be 0.
        var length: f64 = 0;

        // 5. Let targetHasLength be ? HasOwnProperty(target, "length").
        const target_has_length = try target.asObject().hasOwnProperty(agent, PropertyKey.from("length"));

        // 6. If targetHasLength is true, then
        if (target_has_length) {
            // a. Let targetLength be ? Get(target, "length").
            const target_length = try target.asObject().get(agent, PropertyKey.from("length"));

            // b. If targetLength is a Number, then
            if (target_length.isNumber()) {
                // i. Let targetLengthAsInt be ! ToIntegerOrInfinity(targetLength).
                const target_length_as_int = target_length.toIntegerOrInfinity(agent) catch unreachable;

                // ii. If targetLengthAsInt = +∞, then
                if (std.math.isPositiveInf(target_length_as_int)) {
                    // 1. Set length to +∞.
                    length = std.math.inf(f64);
                }
                // iii. Else if targetLengthAsInt = -∞, then
                else if (std.math.isNegativeInf(target_length_as_int)) {
                    // 1. Set length to 0.
                    length = 0;
                } else {
                    // iv. Else,
                    // 1. Let argCount be the number of elements in args.
                    const arg_count = args.len;

                    // 2. Set length to max(targetLengthAsInt - argCount, 0).
                    length = @max(target_length_as_int - @as(f64, @floatFromInt(arg_count)), 0);
                }
            }
        }

        // 7. Perform SetFunctionLength(boundFunc, length).
        try setFunctionLength(agent, &bound_func.object, length);

        // 8. Let targetName be ? Get(target, "name").
        var target_name = try target.asObject().get(agent, PropertyKey.from("name"));

        // 9. If targetName is not a String, set targetName to the empty String.
        if (!target_name.isString()) target_name = Value.from("");

        // 10. Perform SetFunctionName(boundFunc, targetName, "bound").
        try setFunctionName(agent, &bound_func.object, PropertyKey.from(target_name.asString()), "bound");

        // 11. Return boundFunc.
        return Value.from(&bound_func.object);
    }

    /// 20.2.3.3 Function.prototype.call ( thisArg, ...args )
    /// https://tc39.es/ecma262/#sec-function.prototype.call
    fn call(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const this_arg = arguments.get(0);
        const args = if (arguments.count() <= 1) &[_]Value{} else arguments.values[1..];

        // 1. Let func be the this value.
        // 2. If IsCallable(func) is false, throw a TypeError exception.
        if (!this_value.isCallable()) {
            return agent.throwException(.type_error, "{f} is not a function", .{this_value});
        }
        const func = this_value.asObject();

        // 3. Perform PrepareForTailCall().
        // 4. Return ? Call(func, thisArg, args).
        return func.call(agent, this_arg, args);
    }

    /// 20.2.3.5 Function.prototype.toString ( )
    /// https://tc39.es/ecma262/#sec-function.prototype.tostring
    fn toString(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let func be the this value.
        // 2. If func is an Object, func has a [[SourceText]] internal slot, func.[[SourceText]] is
        //    a sequence of Unicode code points, and HostHasSourceTextAvailable(func) is true, then
        //     a. Return CodePointsToString(func.[[SourceText]]).
        if (this_value.castObject(ECMAScriptFunction)) |ecmascript_function| {
            const source_text = try ecmascript_function.fields.source_text.resolve(agent);
            return Value.from(source_text);
        } else if (this_value.castObject(BuiltinFunction)) |builtin_function| {
            if (builtin_function.fields.flags.is_class_constructor) {
                const class_constructor_fields = builtin_function.fields.additionalFieldsAs(ClassConstructorFields);
                const source_text = try class_constructor_fields.source_text.resolve(agent);
                return Value.from(source_text);
            }
        }

        // 3. If func is a built-in function object, return an implementation-defined String source
        //    code representation of func. The representation must have the syntax of a
        //    NativeFunction. Additionally, if func has an [[InitialName]] internal slot and
        //    func.[[InitialName]] is a String, the portion of the returned String that would be
        //    matched by NativeFunctionAccessor[opt] PropertyName must be func.[[InitialName]].
        if (this_value.castObject(BuiltinFunction)) |builtin_function| {
            const name: *const String = builtin_function.fields.initial_name orelse .empty;
            const source_text = try agent.gc_allocator.print(
                "function {f}() {{ [native code] }}",
                .{name.fmtRaw()},
            );
            return Value.from(try String.fromAscii(agent, source_text));
        }

        // 4. If func is an Object and IsCallable(func) is true, return an implementation-defined
        //    String source code representation of func. The representation must have the syntax of
        //    a NativeFunction.
        if (this_value.isCallable()) return Value.from("function () { [native code] }");

        // 5. Throw a TypeError exception.
        return agent.throwException(.type_error, "{f} is not a function", .{this_value});
    }

    /// 20.2.3.6 Function.prototype [ %Symbol.hasInstance% ] ( value )
    /// https://tc39.es/ecma262/#sec-function.prototype-%symbol.hasinstance%
    fn @"Symbol.hasInstance"(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const value = arguments.get(0);

        // 1. Let thisValue be the this value.
        // 2. Return ? OrdinaryHasInstance(thisValue, value).
        return Value.from(try this_value.ordinaryHasInstance(agent, value));
    }
};
