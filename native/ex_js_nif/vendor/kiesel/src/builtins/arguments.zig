//! 10.4.4 Arguments Exotic Objects
//! https://tc39.es/ecma262/#sec-arguments-exotic-objects

const builtin = @import("builtin");
const std = @import("std");

const ast = @import("../language/ast.zig");
const builtins = @import("../builtins.zig");
const execution = @import("../execution.zig");
const types = @import("../types.zig");
const utils = @import("../utils.zig");

const Agent = execution.Agent;
const Environment = execution.Environment;
const MakeObject = types.MakeObject;
const Object = types.Object;
const PropertyDescriptor = types.PropertyDescriptor;
const PropertyKey = types.PropertyKey;
const String = types.String;
const Value = types.Value;
const noexcept = utils.noexcept;
const ordinaryDefineOwnProperty = builtins.ordinaryDefineOwnProperty;
const ordinaryDelete = builtins.ordinaryDelete;
const ordinaryGet = builtins.ordinaryGet;
const ordinaryGetOwnProperty = builtins.ordinaryGetOwnProperty;
const ordinarySet = builtins.ordinarySet;
const sameValue = types.sameValue;

pub const internal_methods = Object.InternalMethods.initComptime(.{
    .getOwnProperty = getOwnProperty,
    .defineOwnProperty = defineOwnProperty,
    .get = get,
    .set = set,
    .delete = delete,
});

/// 10.4.4.1 [[GetOwnProperty]] ( propertyKey )
/// https://tc39.es/ecma262/#sec-arguments-exotic-objects-getownproperty-p
fn getOwnProperty(
    agent: *Agent,
    obj: *Object,
    property_key: PropertyKey,
) std.mem.Allocator.Error!?PropertyDescriptor {
    // 1. Let propertyDesc be OrdinaryGetOwnProperty(args, propertyKey).
    var property_desc = (ordinaryGetOwnProperty(obj, property_key) catch unreachable) orelse {
        // 2. If propertyDesc is undefined, return undefined.
        return null;
    };

    // 3. Let map be args.[[ParameterMap]].
    const map = &obj.as(Arguments).fields.parameter_map;

    // 4. Let isMapped be ! HasOwnProperty(map, propertyKey).
    const is_mapped = map.has(property_key);

    // 5. If isMapped is true, then
    if (is_mapped) {
        // a. Set propertyDesc.[[Value]] to ! Get(map, propertyKey).
        property_desc.value = map.get(agent, property_key);
    }

    // 6. Return propertyDesc.
    return property_desc;
}

/// 10.4.4.2 [[DefineOwnProperty]] ( propertyKey, propertyDesc )
/// https://tc39.es/ecma262/#sec-arguments-exotic-objects-defineownproperty-p-desc
fn defineOwnProperty(
    agent: *Agent,
    obj: *Object,
    property_key: PropertyKey,
    property_desc: PropertyDescriptor,
) std.mem.Allocator.Error!bool {
    // 1. Let map be args.[[ParameterMap]].
    const map = &obj.as(Arguments).fields.parameter_map;

    // 2. Let isMapped be ! HasOwnProperty(map, propertyKey).
    const is_mapped = map.has(property_key);

    // 3. Let newArgDesc be propertyDesc.
    var new_arg_property_desc = property_desc;

    // 4. If isMapped is true and IsDataDescriptor(propertyDesc) is true, then
    if (is_mapped and property_desc.isDataDescriptor()) {
        // a. If propertyDesc does not have a [[Value]] field, propertyDesc has a [[Writable]]
        //    field, and propertyDesc.[[Writable]] is false, then
        if (property_desc.value == null and property_desc.writable == false) {
            // i. Set newArgDesc to a copy of propertyDesc.

            // ii. Set newArgDesc.[[Value]] to ! Get(map, propertyKey).
            new_arg_property_desc.value = map.get(agent, property_key);
        }
    }

    // 5. Let allowed be ! OrdinaryDefineOwnProperty(args, propertyKey, newArgDesc).
    const allowed = ordinaryDefineOwnProperty(
        agent,
        obj,
        property_key,
        new_arg_property_desc,
    ) catch |err| try noexcept(err);

    // 6. If allowed is false, return false.
    if (!allowed) return false;

    // 7. If isMapped is true, then
    if (is_mapped) {
        // a. If IsAccessorDescriptor(propertyDesc) is true, then
        if (property_desc.isAccessorDescriptor()) {
            // i. Perform ! map.[[Delete]](propertyKey).
            map.delete(property_key);
        } else {
            // b. Else,
            // i. If propertyDesc has a [[Value]] field, then
            if (property_desc.value) |value| {
                // 1. Assert: The following Set will succeed, since formal parameters mapped by
                //    arguments objects are always writable.
                // 2. Perform ! Set(map, propertyKey, propertyDesc.[[Value]], false).
                map.set(agent, property_key, value);
            }

            // ii. If propertyDesc has a [[Writable]] field and propertyDesc.[[Writable]] is false,
            //     then
            if (property_desc.writable == false) {
                // 1. Perform ! map.[[Delete]](propertyKey).
                map.delete(property_key);
            }
        }
    }

    // 8. Return true.
    return true;
}

/// 10.4.4.3 [[Get]] ( propertyKey, receiver )
/// https://tc39.es/ecma262/#sec-arguments-exotic-objects-get-p-receiver
fn get(
    agent: *Agent,
    obj: *Object,
    property_key: PropertyKey,
    receiver: Value,
) Agent.Error!Value {
    // 1. Let map be args.[[ParameterMap]].
    const map = &obj.as(Arguments).fields.parameter_map;

    // 2. Let isMapped be ! HasOwnProperty(map, propertyKey).
    const is_mapped = map.has(property_key);

    // 3. If isMapped is false, return ? OrdinaryGet(args, propertyKey, receiver).
    if (!is_mapped) {
        return ordinaryGet(agent, obj, property_key, receiver);
    }

    // 4. Assert: map contains a formal parameter mapping for propertyKey.
    // 5. Return ! Get(map, propertyKey).
    return map.get(agent, property_key);
}

/// 10.4.4.4 [[Set]] ( propertyKey, value, receiver )
/// https://tc39.es/ecma262/#sec-arguments-exotic-objects-set-p-v-receiver
fn set(
    agent: *Agent,
    obj: *Object,
    property_key: PropertyKey,
    value: Value,
    receiver: Value,
) Agent.Error!bool {
    // 1. If SameValue(args, receiver) is false, then
    //     a. Let isMapped be false.
    // 2. Else,
    if (sameValue(Value.from(obj), receiver)) {
        // a. Let map be args.[[ParameterMap]].
        const map = &obj.as(Arguments).fields.parameter_map;

        // b. Let isMapped be ! HasOwnProperty(map, propertyKey).
        const is_mapped = map.has(property_key);

        // 3. If isMapped is true, then
        if (is_mapped) {
            // a. Assert: The following Set will succeed, since formal parameters mapped by
            //    arguments objects are always writable.
            // b. Perform ! Set(map, propertyKey, value, false).
            map.set(agent, property_key, value);
        }
    }

    // 4. Return ? OrdinarySet(args, propertyKey, value, receiver).
    return ordinarySet(agent, obj, property_key, value, receiver);
}

/// 10.4.4.5 [[Delete]] ( propertyKey )
/// https://tc39.es/ecma262/#sec-arguments-exotic-objects-delete-p
fn delete(agent: *Agent, obj: *Object, property_key: PropertyKey) Agent.Error!bool {
    // 1. Let map be args.[[ParameterMap]].
    const map = &obj.as(Arguments).fields.parameter_map;

    // 2. Let isMapped be ! HasOwnProperty(map, propertyKey).
    const is_mapped = map.has(property_key);

    // 3. Let result be ? OrdinaryDelete(args, propertyKey).
    const result = try ordinaryDelete(agent, obj, property_key);

    // 4. If result is true and isMapped is true, then
    if (result and is_mapped) {
        // a. Perform ! map.[[Delete]](propertyKey).
        map.delete(property_key);
    }

    // 5. Return result.
    return result;
}

/// 10.4.4.6 CreateUnmappedArgumentsObject ( argList )
/// https://tc39.es/ecma262/#sec-createunmappedargumentsobject
pub fn createUnmappedArgumentsObject(
    agent: *Agent,
    arg_list: []const Value,
) std.mem.Allocator.Error!*Arguments {
    const realm = agent.currentRealm();

    // 1. Let length be the number of elements in argList.
    const length = arg_list.len;

    // 2. Let obj be OrdinaryObjectCreate(%Object.prototype%, « [[ParameterMap]] »).
    const shape, const offsets = try realm.shape(.unmapped_arguments_object);
    const arguments = try Arguments.createWithShape(agent, .{
        .shape = shape,
        .fields = .{
            // 3. Set obj.[[ParameterMap]] to undefined.
            .parameter_map = undefined,
        },
    });

    // 4. Perform ! DefinePropertyOrThrow(obj, "length", PropertyDescriptor { [[Value]]: 𝔽(length),
    //    [[Writable]]: true, [[Enumerable]]: false, [[Configurable]]: true }).
    arguments.object.setValueAtPropertyOffset(offsets.length, Value.from(@as(u53, @intCast(length))));

    // 5. Let index be 0.
    // 6. Repeat, while index < length,
    for (arg_list, 0..) |value, index| {
        // a. Let value be argList[index].
        // b. Perform ! CreateDataPropertyOrThrow(obj, ! ToString(𝔽(index)), value).
        try arguments.object.createDataPropertyDirect(
            agent,
            PropertyKey.from(@as(PropertyKey.IntegerIndex, @intCast(index))),
            value,
        );

        // c. Set index to index + 1.
    }

    // 7. Perform ! DefinePropertyOrThrow(obj, %Symbol.iterator%, PropertyDescriptor {
    //    [[Value]]: %Array.prototype.values%, [[Writable]]: true, [[Enumerable]]: false,
    //    [[Configurable]]: true }).
    arguments.object.setValueAtPropertyOffset(
        offsets.symbol_iterator,
        Value.from(try realm.intrinsic(.array_prototype_values)),
    );

    // 8. Perform ! DefinePropertyOrThrow(obj, "callee", PropertyDescriptor {
    //    [[Getter]]: %ThrowTypeError%, [[Setter]]: %ThrowTypeError%, [[Enumerable]]: false,
    //    [[Configurable]]: false }).
    arguments.object.setAccessorAtPropertyOffset(offsets.callee, .{
        .getter = try realm.intrinsic(.throw_type_error),
        .setter = try realm.intrinsic(.throw_type_error),
    });

    // 9. Return obj.
    return arguments;
}

/// 10.4.4.7 CreateMappedArgumentsObject ( func, formals, argList, envRecord )
/// https://tc39.es/ecma262/#sec-createmappedargumentsobject
pub fn createMappedArgumentsObject(
    agent: *Agent,
    func: *builtins.ECMAScriptFunction,
    formals: ast.FormalParameters,
    arg_list: []const Value,
    env: Environment,
) std.mem.Allocator.Error!*Arguments {
    const realm = agent.currentRealm();

    // 1. Assert: formals does not contain a rest parameter, any binding patterns, or any
    //    initializers. It may contain duplicate identifiers.
    if (builtin.optimize.runtimeSafety()) {
        for (formals.items) |item| {
            std.debug.assert(item == .formal_parameter);
        }
    }

    // 2. Let length be the number of elements in argList.
    const length = arg_list.len;

    // 3. Let obj be MakeBasicObject(« [[Prototype]], [[Extensible]], [[ParameterMap]] »).
    // 4. Set obj.[[GetOwnProperty]] as specified in 10.4.4.1.
    // 5. Set obj.[[DefineOwnProperty]] as specified in 10.4.4.2.
    // 6. Set obj.[[Get]] as specified in 10.4.4.3.
    // 7. Set obj.[[Set]] as specified in 10.4.4.4.
    // 8. Set obj.[[Delete]] as specified in 10.4.4.5.
    // 9. Set obj.[[Prototype]] to %Object.prototype%.
    // NOTE: This is done via the shape.
    const shape, const offsets = try realm.shape(.mapped_arguments_object);
    const arguments = try Arguments.createWithShape(agent, .{
        .shape = shape,
        .fields = .{
            // 10. Let map be OrdinaryObjectCreate(null).
            // 11. Set obj.[[ParameterMap]] to map.
            .parameter_map = .{
                // Temporarily set to empty so that creating properties below doesn't invoke IB.
                .items = &.{},
                .environment = env,
            },
        },
    });

    // 12. Let paramNames be the BoundNames of formals.
    var param_names: std.ArrayList(ast.Identifier) = .empty;
    defer param_names.deinit(agent.gc_allocator);
    try formals.collectBoundNames(agent.gc_allocator, &param_names);

    // 13. Let paramCount be the number of elements in paramNames.
    const param_count = param_names.items.len;

    // 14. Let index be 0.
    // 15. Repeat, while index < length,
    for (arg_list, 0..) |value, index| {
        // a. Let value be argList[index].
        // b. Perform ! CreateDataPropertyOrThrow(obj, ! ToString(𝔽(index)), value).
        try arguments.object.createDataPropertyDirect(
            agent,
            PropertyKey.from(@as(PropertyKey.IntegerIndex, @intCast(index))),
            value,
        );

        // c. Set index to index + 1.
    }

    // 16. Perform ! DefinePropertyOrThrow(obj, "length", PropertyDescriptor { [[Value]]: 𝔽(length),
    //     [[Writable]]: true, [[Enumerable]]: false, [[Configurable]]: true }).
    arguments.object.setValueAtPropertyOffset(offsets.length, Value.from(@as(u53, @intCast(length))));

    // 17. Let mappedNames be a new empty List.
    var mapped_names: String.HashMap(void) = .empty;
    defer mapped_names.deinit(agent.gc_allocator);

    const map = &arguments.fields.parameter_map;
    map.items = try agent.gc_allocator.alloc(?*const String, @min(param_count, length));
    @memset(map.items, null);

    // 18. Set index to paramCount - 1.
    var maybe_index: ?u53 = std.math.sub(u53, @intCast(param_count), 1) catch null;

    // 19. Repeat, while index ≥ 0,
    while (maybe_index != null) : (maybe_index = (std.math.sub(u53, maybe_index.?, 1) catch null)) {
        // a. Let name be paramNames[index].
        const index: usize = @intCast(maybe_index.?);
        const name = try String.fromUtf8(agent, param_names.items[index]);

        const gop = try mapped_names.getOrPut(agent.gc_allocator, name);

        // b. If mappedNames does not contain name, then
        if (!gop.found_existing) {
            // i. Append name to mappedNames.

            // ii. If index < length, then
            if (index < length) {
                // 1. Let getter be MakeArgGetter(name, envRecord).
                // 2. Let setter be MakeArgSetter(name, envRecord).
                // 3. Perform ! map.[[DefineOwnProperty]](! ToString(𝔽(index)), PropertyDescriptor {
                //    [[Setter]]: setter, [[Getter]]: getter, [[Enumerable]]: false,
                //    [[Configurable]]: true }).
                // NOTE: The getter and setter are implemented via the ParameterMap methods.
                map.items[index] = name;
            }
        }

        // c. Set index to index - 1.
    }

    // 20. Perform ! DefinePropertyOrThrow(obj, %Symbol.iterator%, PropertyDescriptor {
    //     [[Value]]: %Array.prototype.values%, [[Writable]]: true, [[Enumerable]]: false,
    //     [[Configurable]]: true }).
    arguments.object.setValueAtPropertyOffset(
        offsets.symbol_iterator,
        Value.from(try realm.intrinsic(.array_prototype_values)),
    );

    // 21. Perform ! DefinePropertyOrThrow(obj, "callee", PropertyDescriptor { [[Value]]: func,
    //     [[Writable]]: true, [[Enumerable]]: false, [[Configurable]]: true }).
    arguments.object.setValueAtPropertyOffset(offsets.callee, Value.from(&func.object));

    // 22. Return obj.
    return arguments;
}

const ParameterMap = struct {
    items: []?*const String,
    environment: Environment,

    pub fn has(self: *const ParameterMap, property_key: PropertyKey) bool {
        if (property_key != .integer_index) return false;
        const index: usize = @intCast(property_key.integer_index);
        return index < self.items.len and self.items[index] != null;
    }

    pub fn get(self: *const ParameterMap, agent: *Agent, property_key: PropertyKey) Value {
        const index: usize = @intCast(property_key.integer_index);
        const name = self.items[index].?;
        // Bindings are always initialized before this is called, so this can't fail.
        return self.environment.getBindingValue(agent, name, false) catch unreachable;
    }

    pub fn set(self: *ParameterMap, agent: *Agent, property_key: PropertyKey, value: Value) void {
        const index: usize = @intCast(property_key.integer_index);
        const name = self.items[index].?;
        // Bindings are always initialized before this is called, so this can't fail.
        self.environment.setMutableBinding(agent, name, value, false) catch unreachable;
    }

    pub fn delete(self: *ParameterMap, property_key: PropertyKey) void {
        const index: usize = @intCast(property_key.integer_index);
        self.items[index] = null;
    }
};

pub const Arguments = MakeObject(.{
    .Fields = struct {
        /// [[ParameterMap]]
        parameter_map: ParameterMap,
    },
    .tag = .arguments,
    .display_name = "Arguments",
});
