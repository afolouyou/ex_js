//! 20.5.8 SuppressedError Objects
//! https://tc39.es/ecma262/#sec-suppressederror-objects

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

/// 20.5.8.1 The SuppressedError Constructor
/// https://tc39.es/ecma262/#sec-suppressederror-constructor
pub const constructor = struct {
    pub fn create(agent: *Agent, realm: *Realm) std.mem.Allocator.Error!*Object {
        const builtin_function = try createBuiltinFunction(
            agent,
            .{ .constructor = impl },
            3,
            "SuppressedError",
            .{ .realm = realm, .proto = try realm.intrinsic(.@"error") },
        );
        return &builtin_function.object;
    }

    pub fn init(agent: *Agent, realm: *Realm, object: *Object) std.mem.Allocator.Error!void {
        // 20.5.8.2.1 SuppressedError.prototype
        // https://tc39.es/ecma262/#sec-suppressederror.prototype
        try object.defineBuiltinPropertyWithAttributes(
            agent,
            "prototype",
            Value.from(try realm.intrinsic(.suppressed_error_prototype)),
            .none,
        );
    }

    /// 20.5.8.1.1 SuppressedError ( error, suppressed, message )
    /// https://tc39.es/ecma262/#sec-suppressederror
    fn impl(agent: *Agent, arguments: Arguments, new_target: ?*Object) Agent.Error!Value {
        const @"error" = arguments.get(0);
        const suppressed = arguments.get(1);
        const message = arguments.get(2);

        // 1. If NewTarget is undefined, let newTarget be the active function object; else let
        //    newTarget be NewTarget.
        const new_target_ = new_target orelse agent.activeFunctionObject();

        // 2. Let obj be ? OrdinaryCreateFromConstructor(newTarget, "%SuppressedError.prototype%",
        //    « [[ErrorData]] »).
        const suppressed_error = try ordinaryCreateFromConstructor(
            SuppressedError,
            agent,
            new_target_,
            .suppressed_error_prototype,
            .{
                // Non-standard
                .name = String.fromLiteral("SuppressedError"),
                .message = .empty,
                .stack_trace = try agent.captureStackTrace(.{
                    .limit = agent.activeFunctionObject(),
                }),
            },
        );

        // 3. If message is not undefined, then
        if (!message.isUndefined()) {
            // a. Let messageString be ? ToString(message).
            const message_string = try message.toString(agent);

            // b. Perform CreateNonEnumerableDataPropertyOrThrow(obj, "message", messageString).
            try suppressed_error.object.createNonEnumerableDataPropertyOrThrow(
                agent,
                PropertyKey.from("message"),
                Value.from(message_string),
            );

            suppressed_error.fields.message = message_string;
        }

        // 4. Perform CreateNonEnumerableDataPropertyOrThrow(obj, "error", error).
        try suppressed_error.object.createNonEnumerableDataPropertyOrThrow(
            agent,
            PropertyKey.from("error"),
            @"error",
        );

        // 5. Perform CreateNonEnumerableDataPropertyOrThrow(obj, "suppressed", suppressed).
        try suppressed_error.object.createNonEnumerableDataPropertyOrThrow(
            agent,
            PropertyKey.from("suppressed"),
            suppressed,
        );

        // 6. Return obj.
        return Value.from(&suppressed_error.object);
    }
};

/// 20.5.8.3 Properties of the SuppressedError Prototype Object
/// https://tc39.es/ecma262/#sec-properties-of-the-suppressederror-prototype-object
pub const prototype = struct {
    pub fn create(agent: *Agent, realm: *Realm) std.mem.Allocator.Error!*Object {
        return ordinaryObjectCreate(agent, try realm.intrinsic(.error_prototype));
    }

    pub fn init(agent: *Agent, realm: *Realm, object: *Object) std.mem.Allocator.Error!void {
        // 20.5.8.3.1 SuppressedError.prototype.constructor
        // https://tc39.es/ecma262/#sec-suppressederror.prototype.constructor
        try object.defineBuiltinProperty(
            agent,
            "constructor",
            Value.from(try realm.intrinsic(.suppressed_error)),
        );

        // 20.5.8.3.2 SuppressedError.prototype.message
        // https://tc39.es/ecma262/#sec-suppressederror.prototype.message
        try object.defineBuiltinProperty(
            agent,
            "message",
            Value.from(""),
        );

        // 20.5.8.3.3 SuppressedError.prototype.name
        // https://tc39.es/ecma262/#sec-suppressederror.prototype.name
        try object.defineBuiltinProperty(
            agent,
            "name",
            Value.from("SuppressedError"),
        );
    }
};

/// 20.5.8.4 Properties of SuppressedError Instances
/// https://tc39.es/ecma262/#sec-properties-of-suppressederror-instances
pub const SuppressedError = MakeObject(.{
    // NOTE: This shares a tag with the plain Error objects as it is identified by the same
    //       internal slot in the spec and thus subtypes are not distinguishable. For this
    //       reason the Fields type must be identical for Object.as() casts to work.
    .Fields = builtins.Error.Fields,
    .tag = .@"error",
    .display_name = "SuppressedError",
});
