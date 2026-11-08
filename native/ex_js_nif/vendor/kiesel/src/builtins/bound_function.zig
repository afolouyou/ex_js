//! 10.4.1 Bound Function Exotic Objects
//! https://tc39.es/ecma262/#sec-bound-function-exotic-objects

const std = @import("std");

const execution = @import("../execution.zig");
const types = @import("../types.zig");

const Agent = execution.Agent;
const Arguments = types.Arguments;
const MakeObject = types.MakeObject;
const Object = types.Object;
const Value = types.Value;

/// 10.4.1.1 [[Call]] ( thisArg, argList )
/// https://tc39.es/ecma262/#sec-bound-function-exotic-objects-call-thisargument-argumentslist
fn call(agent: *Agent, obj: *Object, _: Value, arg_list: Arguments) Agent.Error!Value {
    const gpa = agent.gpa;
    const function = obj.as(BoundFunction);

    // 1. Let target be func.[[BoundTargetFunction]].
    const target = function.fields.bound_target_function;

    // 2. Let boundThis be func.[[BoundThis]].
    const bound_this = function.fields.bound_this;

    // 3. Let boundArgs be func.[[BoundArguments]].
    const bound_args = function.fields.bound_arguments;

    // 4. Let args be the list-concatenation of boundArgs and argList.
    const args = try std.mem.concat(gpa, Value, &.{ bound_args, arg_list.values });
    defer gpa.free(args);

    // 5. Return ? Call(target, boundThis, args).
    return target.call(agent, bound_this, args);
}

/// 10.4.1.2 [[Construct]] ( argList, newTarget )
/// https://tc39.es/ecma262/#sec-bound-function-exotic-objects-construct-argumentslist-newtarget
fn construct(
    agent: *Agent,
    obj: *Object,
    arg_list: Arguments,
    new_target: *Object,
) Agent.Error!*Object {
    const gpa = agent.gpa;
    const function = obj.as(BoundFunction);

    // 1. Let target be func.[[BoundTargetFunction]].
    const target = function.fields.bound_target_function;

    // 2. Assert: IsConstructor(target) is true.
    std.debug.assert(Value.from(target).isConstructor());

    // 3. Let boundArgs be func.[[BoundArguments]].
    const bound_args = function.fields.bound_arguments;

    // 4. Let args be the list-concatenation of boundArgs and argList.
    const args = try std.mem.concat(gpa, Value, &.{ bound_args, arg_list.values });
    defer gpa.free(args);

    // 5. If SameValue(func, newTarget) is true, set newTarget to target.
    const new_target_ = if (obj == new_target) target else new_target;

    // 6. Return ? Construct(target, args, newTarget).
    return target.construct(agent, args, new_target_);
}

/// 10.4.1.3 BoundFunctionCreate ( targetFunc, boundThis, boundArgs )
/// https://tc39.es/ecma262/#sec-boundfunctioncreate
pub fn boundFunctionCreate(
    agent: *Agent,
    target_func: *Object,
    bound_this: Value,
    bound_args: []const Value,
) Agent.Error!*BoundFunction {
    // 1. Let proto be ? targetFunc.[[GetPrototypeOf]]().
    const proto = try target_func.internalMethods().getPrototypeOf(agent, target_func);

    // 2. Let internalSlotsList be the list-concatenation of « [[Prototype]], [[Extensible]] » and
    //    the internal slots listed in Table 27.
    // 3. Let obj be MakeBasicObject(internalSlotsList).
    const bound_function = try BoundFunction.create(agent, .{
        // 4. Set obj.[[Prototype]] to proto.
        .prototype = proto,

        // 5. Set obj.[[Call]] as specified in 10.4.1.1.
        // 6. If IsConstructor(targetFunc) is true, then
        //     a. Set obj.[[Construct]] as specified in 10.4.1.2.
        .internal_methods = if (Value.from(target_func).isConstructor())
            .initComptime(.{ .call = call, .construct = construct })
        else
            .initComptime(.{ .call = call }),

        .fields = .{
            // 7. Set obj.[[BoundTargetFunction]] to targetFunc.
            .bound_target_function = target_func,

            // 8. Set obj.[[BoundThis]] to boundThis.
            .bound_this = bound_this,

            // 9. Set obj.[[BoundArguments]] to boundArgs.
            .bound_arguments = try agent.gc_allocator.dupe(Value, bound_args),
        },
    });

    // 10. Return obj.
    return bound_function;
}

/// Table 31: Internal Slots of Bound Function Exotic Objects
/// https://tc39.es/ecma262/#table-internal-slots-of-bound-function-exotic-objects
pub const BoundFunction = MakeObject(.{
    .Fields = struct {
        /// [[BoundTargetFunction]]
        bound_target_function: *Object,

        /// [[BoundThis]]
        bound_this: Value,

        /// [[BoundArguments]]
        bound_arguments: []const Value,
    },
    .tag = .bound_function,
    .display_name = "Bound Function",
});
