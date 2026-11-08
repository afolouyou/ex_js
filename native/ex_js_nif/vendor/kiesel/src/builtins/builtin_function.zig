//! 10.3 Built-in Function Objects
//! https://tc39.es/ecma262/#sec-built-in-function-objects

const std = @import("std");

const builtins = @import("../builtins.zig");
const execution = @import("../execution.zig");
const types = @import("../types.zig");
const utils = @import("../utils.zig");

const Agent = execution.Agent;
const Arguments = types.Arguments;
const ClassFieldDefinition = types.ClassFieldDefinition;
const ConstructorKind = builtins.ecmascript_function.ConstructorKind;
const ExecutionContext = execution.ExecutionContext;
const MakeObject = types.MakeObject;
const Object = types.Object;
const PrivateMethodDefinition = types.PrivateMethodDefinition;
const PropertyKey = types.PropertyKey;
const Realm = execution.Realm;
const SourceText = builtins.ecmascript_function.SourceText;
const String = types.String;
const Value = types.Value;
const asyncFunctionStart = builtins.asyncFunctionStart;
const newPromiseCapability = builtins.newPromiseCapability;
const noexcept = utils.noexcept;
const setFunctionLength = builtins.setFunctionLength;
const setFunctionName = builtins.setFunctionName;

pub const Behaviour = union(enum) {
    pub const Function = fn (*Agent, Value, Arguments) Agent.Error!Value;
    pub const Constructor = fn (*Agent, Arguments, ?*Object) Agent.Error!Value;
    pub const ConstructorWithThis = fn (*Agent, ?Value, Arguments, ?*Object) Agent.Error!Value;

    function: *const Function,
    constructor: *const Constructor,
    constructor_with_this: *const ConstructorWithThis,
};

pub const Flags = packed struct(u2) {
    /// [[Async]]
    async: bool,

    is_class_constructor: bool,
};

pub const ClassConstructorFields = struct {
    /// [[ConstructorKind]]
    constructor_kind: ConstructorKind,

    /// [[SourceText]]
    source_text: SourceText,

    /// [[PrivateMethods]]
    private_methods: []const PrivateMethodDefinition,

    /// [[Fields]]
    fields: []const ClassFieldDefinition,
};

pub const BuiltinFunction = MakeObject(.{
    .Fields = struct {
        behaviour: Behaviour,

        /// [[Realm]]
        realm: *Realm,

        /// [[InitialName]]
        initial_name: ?*const String,

        flags: Flags,
        additional_fields: ?*anyopaque,

        pub fn additionalFieldsAs(self: *const @This(), comptime T: type) *T {
            return @ptrCast(@alignCast(self.additional_fields.?));
        }
    },
    .tag = .builtin_function,
    .display_name = "Builtin Function",
});

pub const internal_methods = Object.InternalMethods.initComptime(.{
    .call = call,
});

pub const internal_methods_constructor = Object.InternalMethods.initComptime(.{
    .call = call,
    .construct = construct,
});

/// 10.3.1 [[Call]] ( thisArg, argList )
/// https://tc39.es/ecma262/#sec-built-in-function-objects-call-thisargument-argumentslist
fn call(
    agent: *Agent,
    func: *Object,
    this_arg: Value,
    arg_list: Arguments,
) Agent.Error!Value {
    const function = func.as(BuiltinFunction);

    // 1. Return ? BuiltinCallOrConstruct(func, thisArg, argList, undefined).
    return builtinCallOrConstruct(agent, function, this_arg, arg_list, null);
}

/// 10.3.2 [[Construct]] ( argList, newTarget )
/// https://tc39.es/ecma262/#sec-built-in-function-objects-construct-argumentslist-newtarget
pub fn construct(
    agent: *Agent,
    func: *Object,
    arg_list: Arguments,
    new_target: *Object,
) Agent.Error!*Object {
    const function = func.as(BuiltinFunction);

    // 1. Let result be ? BuiltinCallOrConstruct(func, uninitialized, argList, newTarget).
    const result = try builtinCallOrConstruct(agent, function, null, arg_list, new_target);

    // 2. Assert: result is an Object.
    // 3. Return result.
    return result.asObject();
}

/// 10.3.3 BuiltinCallOrConstruct ( func, thisArg, argList, newTarget )
/// https://tc39.es/ecma262/#sec-builtincallorconstruct
pub fn builtinCallOrConstruct(
    agent: *Agent,
    builtin_function: *BuiltinFunction,
    this_arg: ?Value,
    arg_list: Arguments,
    new_target: ?*Object,
) Agent.Error!Value {
    // 1. Let callerContext be the running execution context.
    // 2. If callerContext is not already suspended, suspend callerContext.

    // 3. Let calleeContext be a new execution context.
    var callee_context: ExecutionContext = .{
        // 4. Set the Function of calleeContext to func.
        .origin = .{ .function = &builtin_function.object },

        // 5. Let calleeRealm be func.[[Realm]].
        // 6. Set the Realm of calleeContext to calleeRealm.
        .realm = builtin_function.fields.realm,

        // 7. Set the ScriptOrModule of calleeContext to null.
        .script_or_module = null,

        .ecmascript_code = undefined,
    };

    // 8. Perform any necessary implementation-defined initialization of calleeContext.

    // 9. Push calleeContext onto the execution context stack; calleeContext is now the running
    //    execution context.
    try agent.execution_context_stack.append(agent.gc_allocator, &callee_context);

    // 10. If func.[[Async]] is true, then
    if (builtin_function.fields.flags.async) {
        const realm = agent.currentRealm();

        // a. Let promiseCapability be ! NewPromiseCapability(%Promise%).
        const promise_capability = newPromiseCapability(
            agent,
            Value.from(try realm.intrinsic(.promise)),
        ) catch |err| try noexcept(err);

        const Captures = struct {
            builtin_function: *BuiltinFunction,
            this_arg: ?Value,
            arg_list: Arguments,
            new_target: ?*Object,
        };
        const captures = try agent.gc_allocator.create(Captures);
        captures.* = .{
            .builtin_function = builtin_function,
            .this_arg = this_arg,
            .arg_list = arg_list,
            .new_target = new_target,
        };

        // b. Let resultsClosure be a new Abstract Closure with no parameters that captures func,
        //    thisArg, argList, and newTarget and performs the following steps when called:
        const resultsClosure = struct {
            fn func(agent_: *Agent, captures_ptr: *anyopaque) Agent.Error!Value {
                const captures_: *Captures = @ptrCast(@alignCast(captures_ptr));
                const builtin_function_ = captures_.builtin_function;
                const this_arg_ = captures_.this_arg;
                const arg_list_ = captures_.arg_list;
                const new_target_ = captures_.new_target;

                // i. Let result be the Completion Record that is the result of evaluating func in a
                //    manner that conforms to the specification of func. If thisArg is
                //    uninitialized, the this value is uninitialized; else thisArg provides the this
                //    value. argList provides the named parameters. newTarget provides the NewTarget
                //    value.
                // ii. NOTE: If func is defined in this document, “the specification of func” is the
                //     behaviour specified for it via algorithm steps or other means.
                const result = switch (builtin_function_.fields.behaviour) {
                    .function => |function| function(agent_, this_arg_.?, arg_list_),
                    .constructor => |constructor| constructor(agent_, arg_list_, new_target_),
                    .constructor_with_this => |constructor| constructor(agent_, this_arg_, arg_list_, new_target_),
                };

                // iii. Return Completion(result).
                return result;
            }
        }.func;

        // c. Perform AsyncFunctionStart(promiseCapability, resultsClosure).
        try asyncFunctionStart(agent, promise_capability, .{
            .abstract_closure = .{
                .func = resultsClosure,
                .captures = captures,
            },
        });

        // d. Remove calleeContext from the execution context stack and restore callerContext as the
        //    running execution context.
        _ = agent.execution_context_stack.pop().?;

        // e. Return promiseCapability.[[Promise]].
        return Value.from(promise_capability.promise);
    }

    // 11. Let result be the Completion Record that is the result of evaluating func in a manner
    //     that conforms to the specification of func. If thisArg is uninitialized, the this value
    //     is uninitialized; else thisArg provides the this value. argList provides the named
    //     parameters. newTarget provides the NewTarget value.
    // 12. NOTE: If func is defined in this document, “the specification of func” is the behaviour
    //     specified for it via algorithm steps or other means.
    const result = switch (builtin_function.fields.behaviour) {
        .function => |function| function(agent, this_arg.?, arg_list),
        .constructor => |constructor| constructor(agent, arg_list, new_target),
        .constructor_with_this => |constructor| constructor(agent, this_arg, arg_list, new_target),
    };

    // 13. Remove calleeContext from the execution context stack and restore callerContext as the
    //     running execution context.
    _ = agent.execution_context_stack.pop().?;

    // 14. Return ? result.
    return result;
}

/// 10.3.4 CreateBuiltinFunction ( behaviour, length, name, additionalInternalSlotsList [ , realm [ , proto [ , prefix [ , async ] ] ] ] )
/// https://tc39.es/ecma262/#sec-createbuiltinfunction
pub fn createBuiltinFunction(
    agent: *Agent,
    comptime behaviour: Behaviour,
    comptime length: u32,
    comptime maybe_name: ?[]const u8,
    args: struct {
        realm: ?*Realm = null,
        // NOTE: I don't think any builtin functions are created with a null prototype,
        //       so the null state can serve as 'not present'.
        proto: ?*Object = null,
        prefix: ?[]const u8 = null,
        flags: Flags = .{ .async = false, .is_class_constructor = false },
        additional_fields: ?*anyopaque = null,
    },
) std.mem.Allocator.Error!*BuiltinFunction {
    // 1. If realm is not present, set realm to the current Realm Record.
    const realm = args.realm orelse agent.currentRealm();

    // 2. If proto is not present, set proto to realm.[[Intrinsics]].[[%Function.prototype%]].
    const proto = args.proto orelse try realm.intrinsic(.function_prototype);

    // 3. If async is not present, set async to false.

    // 4. Let internalSlotsList be a List containing the names of all the internal slots that 10.3
    //    requires for the built-in function object that is about to be created.
    // 5. Append the elements of additionalInternalSlotsList to internalSlotsList.

    // 6. Let func be a new built-in function object that, when called, performs the action
    //    described by behaviour using the provided arguments as the values of the corresponding
    //    parameters specified by behaviour. The new function object has internal slots whose names
    //    are the elements of internalSlotsList, and an [[InitialName]] internal slot.
    const func = try BuiltinFunction.create(agent, .{
        .internal_methods = switch (behaviour) {
            .function => internal_methods,
            .constructor, .constructor_with_this => internal_methods_constructor,
        },

        // 7. Set func.[[Async]] to async.
        // NOTE: This is done via `flags`.

        // 8. Set func.[[Prototype]] to proto.
        .prototype = proto,

        // 9. Set func.[[Extensible]] to true.
        .extensible = true,

        .fields = .{
            .behaviour = behaviour,

            // 10. Set func.[[Realm]] to realm.
            .realm = realm,

            // 11. Set func.[[InitialName]] to null.
            .initial_name = null,

            .flags = args.flags,
            .additional_fields = args.additional_fields,
        },
    });

    // 12. Perform SetFunctionLength(func, length).
    try setFunctionLength(agent, &func.object, @floatFromInt(length));

    // 13. If prefix is not present, then
    //     a. Perform SetFunctionName(func, name).
    // 14. Else,
    //     a. Perform SetFunctionName(func, name, prefix).
    // NOTE: We make the name optional because classDefinitionEvaluation() calls createBuiltinFunction()
    //       with a runtime-known name and we want to keep the assertion in setFunctionName() to
    //       ensure it only gets called once. It's the caller's responsibility to install the
    //       function name after the fact.
    if (maybe_name) |name| {
        try setFunctionName(agent, &func.object, PropertyKey.from(name), args.prefix);
    }

    // 15. Return func.
    return func;
}
