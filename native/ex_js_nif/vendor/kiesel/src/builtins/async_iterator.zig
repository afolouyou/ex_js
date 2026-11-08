const std = @import("std");

const builtins = @import("../builtins.zig");
const execution = @import("../execution.zig");
const types = @import("../types.zig");
const utils = @import("../utils.zig");

const Agent = execution.Agent;
const Arguments = types.Arguments;
const Object = types.Object;
const PropertyKey = types.PropertyKey;
const Realm = execution.Realm;
const Value = types.Value;
const createBuiltinFunction = builtins.createBuiltinFunction;
const newPromiseCapability = builtins.newPromiseCapability;
const noexcept = utils.noexcept;
const ordinaryObjectCreate = builtins.ordinaryObjectCreate;
const performPromiseThen = builtins.performPromiseThen;
const promiseResolve = builtins.promiseResolve;

/// 27.1.4 The %AsyncIteratorPrototype% Object
/// https://tc39.es/ecma262/#sec-asynciteratorprototype
pub const prototype = struct {
    pub fn create(agent: *Agent, realm: *Realm) std.mem.Allocator.Error!*Object {
        return ordinaryObjectCreate(agent, try realm.intrinsic(.object_prototype));
    }

    pub fn init(agent: *Agent, realm: *Realm, object: *Object) std.mem.Allocator.Error!void {
        try object.defineBuiltinFunction(agent, "Symbol.asyncDispose", @"Symbol.asyncDispose", 0, realm);
        try object.defineBuiltinFunction(agent, "Symbol.asyncIterator", @"Symbol.asyncIterator", 0, realm);
    }

    /// 27.1.4.1 %AsyncIteratorPrototype% [ %Symbol.asyncDispose% ] ( )
    /// https://tc39.es/ecma262/#sec-%asynciteratorprototype%-%symbol.asyncdispose%
    fn @"Symbol.asyncDispose"(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        const realm = agent.currentRealm();

        // 1. Let obj be the this value.

        // 2. Let promiseCapability be ! NewPromiseCapability(%Promise%).
        const promise_capability = newPromiseCapability(
            agent,
            Value.from(try realm.intrinsic(.promise)),
        ) catch |err| try noexcept(err);

        // 3. Let return be Completion(GetMethod(obj, "return")).
        const maybe_return = this_value.getMethod(agent, PropertyKey.from("return")) catch |err| {
            // 4. IfAbruptRejectPromise(return, promiseCapability).
            return Value.from(try promise_capability.rejectPromise(agent, err));
        };

        // 5. If return is undefined, then
        const @"return" = maybe_return orelse {
            // a. Perform ! Call(promiseCapability.[[Resolve]], undefined, « undefined »).
            _ = promise_capability.resolve.call(
                agent,
                .undefined,
                &.{.undefined},
            ) catch |err| try noexcept(err);

            return Value.from(promise_capability.promise);
        };

        // 6. Else,
        // a. Let result be Completion(Call(return, obj, « »)).
        const result = @"return".call(agent, this_value, &.{}) catch |err| {
            // b. IfAbruptRejectPromise(result, promiseCapability).
            return Value.from(try promise_capability.rejectPromise(agent, err));
        };

        // c. Let resultWrapper be Completion(PromiseResolve(%Promise%, result)).
        const result_wrapper = promiseResolve(agent, try realm.intrinsic(.promise), result) catch |err| {
            // d. IfAbruptRejectPromise(resultWrapper, promiseCapability).
            return Value.from(try promise_capability.rejectPromise(agent, err));
        };

        // e. Let unwrap be a new Abstract Closure with no parameters that captures nothing and
        //    performs the following steps when called:
        const unwrap = struct {
            fn func(_: *Agent, _: Value, _: Arguments) Agent.Error!Value {
                // i. Return undefined.
                return .undefined;
            }
        }.func;

        // f. Let onFulfilled be CreateBuiltinFunction(unwrap, 1, "", « »).
        const on_fulfilled = try createBuiltinFunction(agent, .{ .function = unwrap }, 1, "", .{});

        // g. Perform PerformPromiseThen(resultWrapper, onFulfilled, undefined, promiseCapability).
        _ = try performPromiseThen(
            agent,
            result_wrapper.as(builtins.Promise),
            Value.from(&on_fulfilled.object),
            .undefined,
            promise_capability,
        );

        // 7. Return promiseCapability.[[Promise]].
        return Value.from(promise_capability.promise);
    }

    /// 27.1.4.2 %AsyncIteratorPrototype% [ %Symbol.asyncIterator% ] ( )
    /// https://tc39.es/ecma262/#sec-%asynciteratorprototype%-%symbol.asynciterator%
    fn @"Symbol.asyncIterator"(_: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Return the this value.
        return this_value;
    }
};
