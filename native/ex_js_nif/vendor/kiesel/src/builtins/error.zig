//! 20.5 Error Objects
//! https://tc39.es/ecma262/#sec-error-objects

const std = @import("std");

const builtins = @import("../builtins.zig");
const execution = @import("../execution.zig");
const types = @import("../types.zig");

const Agent = execution.Agent;
const Arguments = types.Arguments;
const MakeObject = types.MakeObject;
const Object = types.Object;
const PropertyKey = types.PropertyKey;
const Realm = execution.Realm;
const String = types.String;
const Value = types.Value;
const createBuiltinFunction = builtins.createBuiltinFunction;
const ordinaryCreateFromConstructor = builtins.ordinaryCreateFromConstructor;
const ordinaryObjectCreate = builtins.ordinaryObjectCreate;

/// 20.5.2 Properties of the Error Constructor
/// https://tc39.es/ecma262/#sec-properties-of-the-error-constructor
pub const constructor = struct {
    pub fn create(agent: *Agent, realm: *Realm) std.mem.Allocator.Error!*Object {
        const builtin_function = try createBuiltinFunction(
            agent,
            .{ .constructor = impl },
            1,
            "Error",
            .{ .realm = realm, .proto = try realm.intrinsic(.function_prototype) },
        );
        return &builtin_function.object;
    }

    pub fn init(agent: *Agent, realm: *Realm, object: *Object) std.mem.Allocator.Error!void {
        try object.defineBuiltinFunction(agent, "isError", isError, 1, realm);

        // 20.5.2.2 Error.prototype
        // https://tc39.es/ecma262/#sec-error.prototype
        try object.defineBuiltinPropertyWithAttributes(
            agent,
            "prototype",
            Value.from(try realm.intrinsic(.error_prototype)),
            .none,
        );
    }

    /// 20.5.1.1 Error ( message [ , options ] )
    /// https://tc39.es/ecma262/#sec-error-message
    fn impl(agent: *Agent, arguments: Arguments, new_target: ?*Object) Agent.Error!Value {
        const message = arguments.get(0);
        const options = arguments.get(1);

        // 1. If NewTarget is undefined, let newTarget be the active function object; else let
        //    newTarget be NewTarget.
        const new_target_ = new_target orelse agent.activeFunctionObject();

        // 2. Let obj be ? OrdinaryCreateFromConstructor(newTarget, "%Error.prototype%",
        //    « [[ErrorData]] »).
        const @"error" = try ordinaryCreateFromConstructor(
            Error,
            agent,
            new_target_,
            .error_prototype,
            .{
                // Non-standard
                .name = String.fromLiteral("Error"),
                .message = .empty,
                .stack_trace = try agent.captureStackTrace(.{
                    .limit = agent.activeFunctionObject(),
                }),
            },
        );

        // Non-standard
        std.debug.assert(@"error".object.internalMethods() == Object.InternalMethods.default);
        try @"error".object.setInternalMethods(agent, .initComptime(.{ .set = internalSet }));

        // 3. If message is not undefined, then
        if (!message.isUndefined()) {
            // a. Let messageString be ? ToString(message).
            const message_string = try message.toString(agent);

            // b. Perform CreateNonEnumerableDataPropertyOrThrow(obj, "message", messageString).
            try @"error".object.createNonEnumerableDataPropertyOrThrow(
                agent,
                PropertyKey.from("message"),
                Value.from(message_string),
            );

            @"error".fields.message = message_string;
        }

        // 4. Perform ? InstallErrorCause(obj, options).
        try installErrorCause(agent, &@"error".object, options);

        // 5. Return obj.
        return Value.from(&@"error".object);
    }

    /// 20.5.2.1 Error.isError ( arg )
    /// https://tc39.es/ecma262/#sec-error.iserror
    fn isError(_: *Agent, _: Value, arguments: Arguments) Agent.Error!Value {
        const arg = arguments.get(0);

        // 1. If arg is not an Object, return false.
        if (!arg.isObject()) return .false;

        // 2. If arg does not have an [[ErrorData]] internal slot, return false.
        // 3. Return true.
        return Value.from(arg.asObject().is(builtins.Error));
    }
};

/// Custom [[Set]] to intercept .name and .message property changes
///
/// NOTE: Ignoring non-string values matches SpiderMonkey, V8 only remembers the original name and
///       message and doesn't act on property changes.
pub fn internalSet(
    agent: *Agent,
    obj: *Object,
    property_key: PropertyKey,
    value: Value,
    receiver: Value,
) Agent.Error!bool {
    if (property_key == .string and value.isString()) {
        if (property_key.string.eql(String.fromLiteral("name"))) {
            obj.as(Error).fields.name = value.asString();
        } else if (property_key.string.eql(String.fromLiteral("message"))) {
            obj.as(Error).fields.message = value.asString();
        }
    }
    return builtins.ordinarySet(agent, obj, property_key, value, receiver);
}

/// 20.5.3 Properties of the Error Prototype Object
/// https://tc39.es/ecma262/#sec-properties-of-the-error-prototype-object
pub const prototype = struct {
    pub fn create(agent: *Agent, realm: *Realm) std.mem.Allocator.Error!*Object {
        return ordinaryObjectCreate(agent, try realm.intrinsic(.object_prototype));
    }

    pub fn init(agent: *Agent, realm: *Realm, object: *Object) std.mem.Allocator.Error!void {
        // 20.5.3.1 Error.prototype.constructor
        // https://tc39.es/ecma262/#sec-error.prototype.constructor
        try object.defineBuiltinProperty(
            agent,
            "constructor",
            Value.from(try realm.intrinsic(.@"error")),
        );

        // 20.5.3.2 Error.prototype.message
        // https://tc39.es/ecma262/#sec-error.prototype.message
        try object.defineBuiltinProperty(
            agent,
            "message",
            Value.from(""),
        );

        // 20.5.3.3 Error.prototype.name
        // https://tc39.es/ecma262/#sec-error.prototype.name
        try object.defineBuiltinProperty(
            agent,
            "name",
            Value.from("Error"),
        );

        try object.defineBuiltinAccessor(agent, "stack", stackGetter, stackSetter, realm);
        try object.defineBuiltinFunction(agent, "toString", toString, 0, realm);
    }

    /// 20.5.3.1.1 get Error.prototype.stack
    /// https://tc39.es/proposal-error-stack-accessor/#sec-get-error.prototype.stack
    fn stackGetter(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let E be the this value.
        // 2. If E is not an Object, throw a TypeError exception.
        if (!this_value.isObject()) {
            return agent.throwException(.type_error, "{f} is not an Object", .{this_value});
        }

        // 3. If E does not have an [[ErrorData]] internal slot, return undefined.
        const @"error" = this_value.asObject().cast(Error) orelse return .undefined;

        // 4. Return an implementation-defined string that represents the stack trace of E.
        const exception: Agent.Exception = .{
            .value = Value.from(&@"error".object),
            .stack_trace = @"error".fields.stack_trace,
        };
        const string = try String.fromUtf8(agent, try agent.gc_allocator.print(
            "{f}",
            .{exception.fmtPretty(agent, .no_color)},
        ));
        return Value.from(string);
    }

    /// 20.5.3.1.2 set Error.prototype.stack
    /// https://tc39.es/proposal-error-stack-accessor/#sec-set-error.prototype.stack
    fn stackSetter(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const realm = agent.currentRealm();
        const value = arguments.get(0);

        // 1. Let E be the this value.
        // 2. If E is not an Object, throw a TypeError exception.
        if (!this_value.isObject()) {
            return agent.throwException(.type_error, "{f} is not an Object", .{this_value});
        }

        // 3. If v is not a String, throw a TypeError exception.
        if (!value.isString()) {
            return agent.throwException(.type_error, "{f} is not a string", .{value});
        }

        // 4. Perform ? SetterThatIgnoresPrototypeProperties(this value, %Error.prototype%, "stack",
        //    v).
        try this_value.setterThatIgnoresPrototypeProperties(
            agent,
            try realm.intrinsic(.error_prototype),
            PropertyKey.from("stack"),
            value,
        );

        // 5. Return undefined.
        return .undefined;
    }

    /// 20.5.3.4 Error.prototype.toString ( )
    /// https://tc39.es/ecma262/#sec-error.prototype.tostring
    fn toString(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let obj be the this value.
        // 2. If obj is not an Object, throw a TypeError exception.
        if (!this_value.isObject()) {
            return agent.throwException(.type_error, "{f} is not an Object", .{this_value});
        }
        const obj = this_value.asObject();

        // 3. Let name be ? Get(obj, "name").
        const name = try obj.get(agent, PropertyKey.from("name"));

        // 4. If name is undefined, set name to "Error"; else set name to ? ToString(name).
        const name_string = if (name.isUndefined()) String.fromLiteral("Error") else try name.toString(agent);

        // 5. Let message be ? Get(obj, "message").
        const message = try obj.get(agent, PropertyKey.from("message"));

        // 6. If message is undefined, set message to the empty String; else set message to
        //    ? ToString(message).
        const message_string: *const String = if (message.isUndefined()) .empty else try message.toString(agent);

        // 7. If name is the empty String, return message.
        if (name_string.isEmpty()) return Value.from(message_string);

        // 8. If message is the empty String, return name.
        if (message_string.isEmpty()) return Value.from(name_string);

        // 9. Return the string-concatenation of name, the code unit 0x003A (COLON), the code unit
        //    0x0020 (SPACE), and message.
        return Value.from(
            try String.concat(agent, &.{ name_string, String.fromLiteral(": "), message_string }),
        );
    }
};

/// 20.5.4 Properties of Error Instances
/// https://tc39.es/ecma262/#sec-properties-of-error-instances
pub const Error = MakeObject(.{
    .Fields = struct {
        // NOTE: We store the name and message separately for pretty-printing without property lookups.
        name: *const String,
        message: *const String,
        stack_trace: Agent.Exception.StackTrace,
    },
    .tag = .@"error",
    .display_name = "Error",
});

/// 20.5.5.1 EvalError
/// https://tc39.es/ecma262/#sec-native-error-types-used-in-this-standard-evalerror
pub const eval_error = struct {
    pub const constructor = MakeNativeErrorConstructor("EvalError");
    pub const prototype = MakeNativeErrorPrototype("EvalError");
    pub const EvalError = MakeNativeError("EvalError");
};

/// 20.5.5.2 RangeError
/// https://tc39.es/ecma262/#sec-native-error-types-used-in-this-standard-rangeerror
pub const range_error = struct {
    pub const constructor = MakeNativeErrorConstructor("RangeError");
    pub const prototype = MakeNativeErrorPrototype("RangeError");
    pub const RangeError = MakeNativeError("RangeError");
};

/// 20.5.5.3 ReferenceError
/// https://tc39.es/ecma262/#sec-native-error-types-used-in-this-standard-referenceerror
pub const reference_error = struct {
    pub const constructor = MakeNativeErrorConstructor("ReferenceError");
    pub const prototype = MakeNativeErrorPrototype("ReferenceError");
    pub const ReferenceError = MakeNativeError("ReferenceError");
};

/// 20.5.5.4 SyntaxError
/// https://tc39.es/ecma262/#sec-native-error-types-used-in-this-standard-syntaxerror
pub const syntax_error = struct {
    pub const constructor = MakeNativeErrorConstructor("SyntaxError");
    pub const prototype = MakeNativeErrorPrototype("SyntaxError");
    pub const SyntaxError = MakeNativeError("SyntaxError");
};

/// 20.5.5.5 TypeError
/// https://tc39.es/ecma262/#sec-native-error-types-used-in-this-standard-typeerror
pub const type_error = struct {
    pub const constructor = MakeNativeErrorConstructor("TypeError");
    pub const prototype = MakeNativeErrorPrototype("TypeError");
    pub const TypeError = MakeNativeError("TypeError");
};

/// 20.5.5.6 URIError
/// https://tc39.es/ecma262/#sec-native-error-types-used-in-this-standard-urierror
pub const uri_error = struct {
    pub const constructor = MakeNativeErrorConstructor("URIError");
    pub const prototype = MakeNativeErrorPrototype("URIError");
    pub const URIError = MakeNativeError("URIError");
};

/// 20.5.6.2 Properties of the NativeError Constructors
/// https://tc39.es/ecma262/#sec-properties-of-the-nativeerror-constructors
fn MakeNativeErrorConstructor(comptime name: []const u8) type {
    const namespace, const proto_intrinsic = std.StaticStringMap(
        struct { type, Realm.Intrinsic },
    ).initComptime(.{
        .{ "EvalError", .{ eval_error, .eval_error_prototype } },
        .{ "RangeError", .{ range_error, .range_error_prototype } },
        .{ "ReferenceError", .{ reference_error, .reference_error_prototype } },
        .{ "SyntaxError", .{ syntax_error, .syntax_error_prototype } },
        .{ "TypeError", .{ type_error, .type_error_prototype } },
        .{ "URIError", .{ uri_error, .uri_error_prototype } },
    }).get(name).?;

    return struct {
        pub fn create(agent: *Agent, realm: *Realm) std.mem.Allocator.Error!*Object {
            const builtin_function = try createBuiltinFunction(
                agent,
                .{ .constructor = impl },
                1,
                name,
                .{ .realm = realm, .proto = try realm.intrinsic(.@"error") },
            );
            return &builtin_function.object;
        }

        pub fn init(agent: *Agent, realm: *Realm, object: *Object) std.mem.Allocator.Error!void {
            // 20.5.6.2.1 NativeError.prototype
            // https://tc39.es/ecma262/#sec-nativeerror.prototype
            try object.defineBuiltinPropertyWithAttributes(
                agent,
                "prototype",
                Value.from(try realm.intrinsic(proto_intrinsic)),
                .none,
            );
        }

        /// 20.5.6.1.1 NativeError ( message [ , options ] )
        /// https://tc39.es/ecma262/#sec-nativeerror
        fn impl(agent: *Agent, arguments: Arguments, new_target: ?*Object) Agent.Error!Value {
            const message = arguments.get(0);
            const options = arguments.get(1);

            const T = @field(namespace, name);

            // 1. If NewTarget is undefined, let newTarget be the active function object; else let
            //    newTarget be NewTarget.
            const new_target_ = new_target orelse agent.activeFunctionObject();

            // 2. Let obj be ? OrdinaryCreateFromConstructor(newTarget, "%NativeError.prototype%",
            //    « [[ErrorData]] »).
            const @"error" = try ordinaryCreateFromConstructor(
                T,
                agent,
                new_target_,
                proto_intrinsic,
                .{
                    // Non-standard
                    .name = String.fromLiteral(name),
                    .message = .empty,
                    .stack_trace = try agent.captureStackTrace(.{
                        .limit = agent.activeFunctionObject(),
                    }),
                },
            );

            // Non-standard
            std.debug.assert(@"error".object.internalMethods() == Object.InternalMethods.default);
            try @"error".object.setInternalMethods(agent, .initComptime(.{ .set = internalSet }));

            // 3. If message is not undefined, then
            if (!message.isUndefined()) {
                // a. Let messageString be ? ToString(message).
                const message_string = try message.toString(agent);

                // b. Perform CreateNonEnumerableDataPropertyOrThrow(obj, "message", messageString).
                try @"error".object.createNonEnumerableDataPropertyOrThrow(
                    agent,
                    PropertyKey.from("message"),
                    Value.from(message_string),
                );

                @"error".fields.message = message_string;
            }

            // 4. Perform ? InstallErrorCause(obj, options).
            try installErrorCause(agent, &@"error".object, options);

            // 5. Return obj.
            return Value.from(&@"error".object);
        }
    };
}

/// 20.5.6.3 Properties of the NativeError Prototype Objects
/// https://tc39.es/ecma262/#sec-properties-of-the-nativeerror-prototype-objects
fn MakeNativeErrorPrototype(comptime name: []const u8) type {
    const ctor_intrinsic = std.StaticStringMap(Realm.Intrinsic).initComptime(.{
        .{ "EvalError", .eval_error },
        .{ "RangeError", .range_error },
        .{ "ReferenceError", .reference_error },
        .{ "SyntaxError", .syntax_error },
        .{ "TypeError", .type_error },
        .{ "URIError", .uri_error },
    }).get(name).?;

    return struct {
        pub fn create(agent: *Agent, realm: *Realm) std.mem.Allocator.Error!*Object {
            return ordinaryObjectCreate(agent, try realm.intrinsic(.error_prototype));
        }

        pub fn init(agent: *Agent, realm: *Realm, object: *Object) std.mem.Allocator.Error!void {
            // 20.5.6.3.1 NativeError.prototype.constructor
            // https://tc39.es/ecma262/#sec-nativeerror.prototype.constructor
            try object.defineBuiltinProperty(
                agent,
                "constructor",
                Value.from(try realm.intrinsic(ctor_intrinsic)),
            );

            // 20.5.6.3.2 NativeError.prototype.message
            // https://tc39.es/ecma262/#sec-nativeerror.prototype.message
            try object.defineBuiltinProperty(
                agent,
                "message",
                Value.from(""),
            );

            // 20.5.6.3.3 NativeError.prototype.name
            // https://tc39.es/ecma262/#sec-nativeerror.prototype.name
            try object.defineBuiltinProperty(
                agent,
                "name",
                Value.from(name),
            );
        }
    };
}

/// 20.5.6.4 Properties of NativeError Instances
/// https://tc39.es/ecma262/#sec-properties-of-nativeerror-instances
fn MakeNativeError(comptime name: []const u8) type {
    return MakeObject(.{
        // NOTE: This shares a tag with the plain Error objects as it is identified by the same
        //       internal slot in the spec and thus subtypes are not distinguishable. For this
        //       reason the Fields type must be identical for Object.as() casts to work.
        .Fields = Error.Fields,
        .tag = .@"error",
        .display_name = name,
    });
}

/// 20.5.9.1 InstallErrorCause ( obj, options )
/// https://tc39.es/ecma262/#sec-installerrorcause
pub fn installErrorCause(agent: *Agent, obj: *Object, options: Value) Agent.Error!void {
    // 1. If options is an Object and ? HasProperty(options, "cause") is true, then
    if (options.isObject() and
        try options.asObject().hasProperty(agent, PropertyKey.from("cause")))
    {
        // a. Let cause be ? Get(options, "cause").
        const cause = try options.get(agent, PropertyKey.from("cause"));

        // b. Perform CreateNonEnumerableDataPropertyOrThrow(obj, "cause", cause).
        try obj.createNonEnumerableDataPropertyOrThrow(
            agent,
            PropertyKey.from("cause"),
            cause,
        );
    }

    // 2. Return unused.
}
