//! 20.3 Boolean Objects
//! https://tc39.es/ecma262/#sec-boolean-objects

const std = @import("std");

const builtins = @import("../builtins.zig");
const execution = @import("../execution.zig");
const types = @import("../types.zig");

const Agent = execution.Agent;
const Arguments = types.Arguments;
const MakeObject = types.MakeObject;
const Object = types.Object;
const Realm = execution.Realm;
const Value = types.Value;
const createBuiltinFunction = builtins.createBuiltinFunction;
const ordinaryCreateFromConstructor = builtins.ordinaryCreateFromConstructor;

/// 20.3.2 Properties of the Boolean Constructor
/// https://tc39.es/ecma262/#sec-properties-of-the-boolean-constructor
pub const constructor = struct {
    pub fn create(agent: *Agent, realm: *Realm) std.mem.Allocator.Error!*Object {
        const builtin_function = try createBuiltinFunction(
            agent,
            .{ .constructor = impl },
            1,
            "Boolean",
            .{ .realm = realm, .proto = try realm.intrinsic(.function_prototype) },
        );
        return &builtin_function.object;
    }

    pub fn init(agent: *Agent, realm: *Realm, object: *Object) std.mem.Allocator.Error!void {
        // 20.3.2.1 Boolean.prototype
        // https://tc39.es/ecma262/#sec-boolean.prototype
        try object.defineBuiltinPropertyWithAttributes(
            agent,
            "prototype",
            Value.from(try realm.intrinsic(.boolean_prototype)),
            .none,
        );
    }

    /// 20.3.1.1 Boolean ( value )
    /// https://tc39.es/ecma262/#sec-boolean-constructor-boolean-value
    fn impl(agent: *Agent, arguments: Arguments, new_target: ?*Object) Agent.Error!Value {
        const value = arguments.get(0);

        // 1. Let bool be ToBoolean(value).
        const @"bool" = value.toBoolean();

        // 2. If NewTarget is undefined, return bool.
        if (new_target == null) return Value.from(@"bool");

        // 3. Let obj be ? OrdinaryCreateFromConstructor(NewTarget, "%Boolean.prototype%",
        //    « [[BooleanData]] »).
        const boolean = try ordinaryCreateFromConstructor(
            Boolean,
            agent,
            new_target.?,
            .boolean_prototype,
            .{
                // 4. Set obj.[[BooleanData]] to bool.
                .boolean_data = @"bool",
            },
        );

        // 5. Return obj.
        return Value.from(&boolean.object);
    }
};

/// 20.3.3 Properties of the Boolean Prototype Object
/// https://tc39.es/ecma262/#sec-properties-of-the-boolean-prototype-object
pub const prototype = struct {
    pub fn create(agent: *Agent, realm: *Realm) std.mem.Allocator.Error!*Object {
        const boolean = try Boolean.create(agent, .{
            .fields = .{
                .boolean_data = false,
            },
            .prototype = try realm.intrinsic(.object_prototype),
        });
        return &boolean.object;
    }

    pub fn init(agent: *Agent, realm: *Realm, object: *Object) std.mem.Allocator.Error!void {
        try object.defineBuiltinFunction(agent, "toString", toString, 0, realm);
        try object.defineBuiltinFunction(agent, "valueOf", valueOf, 0, realm);

        // 20.3.3.1 Boolean.prototype.constructor
        // https://tc39.es/ecma262/#sec-boolean.prototype.constructor
        try object.defineBuiltinProperty(
            agent,
            "constructor",
            Value.from(try realm.intrinsic(.boolean)),
        );
    }

    /// 20.3.3.3.1 ThisBooleanValue ( arg )
    /// https://tc39.es/ecma262/#sec-thisbooleanvalue
    fn thisBooleanValue(agent: *Agent, arg: Value) error{ExceptionThrown}!bool {
        // 1. If arg is a Boolean, return arg.
        if (arg.isBoolean()) return arg.asBoolean();

        // 2. If arg is an Object and arg has a [[BooleanData]] internal slot, then
        if (arg.castObject(Boolean)) |boolean| {
            // a. Let bool be arg.[[BooleanData]].
            // b. Assert: bool is a Boolean.
            // c. Return bool.
            return boolean.fields.boolean_data;
        }

        // 3. Throw a TypeError exception.
        return agent.throwException(
            .type_error,
            "This value must be a boolean or Boolean object",
            .{},
        );
    }

    /// 20.3.3.2 Boolean.prototype.toString ( )
    /// https://tc39.es/ecma262/#sec-boolean.prototype.tostring
    fn toString(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let bool be ? ThisBooleanValue(this value).
        const @"bool" = try thisBooleanValue(agent, this_value);

        // 2. If bool is true, return "true".
        // 3. Return "false".
        return if (@"bool") Value.from("true") else Value.from("false");
    }

    /// 20.3.3.3 Boolean.prototype.valueOf ( )
    /// https://tc39.es/ecma262/#sec-boolean.prototype.valueof
    fn valueOf(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Return ? ThisBooleanValue(this value).
        return Value.from(try thisBooleanValue(agent, this_value));
    }
};

/// 20.3.4 Properties of Boolean Instances
/// https://tc39.es/ecma262/#sec-properties-of-boolean-instances
pub const Boolean = MakeObject(.{
    .Fields = struct {
        /// [[BooleanData]]
        boolean_data: bool,
    },
    .tag = .boolean,
    .display_name = "Boolean",
});
