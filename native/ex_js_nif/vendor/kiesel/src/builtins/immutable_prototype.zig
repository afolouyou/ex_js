//! 10.4.7 Immutable Prototype Exotic Objects
//! https://tc39.es/ecma262/#sec-immutable-prototype-exotic-objects

const execution = @import("../execution.zig");
const types = @import("../types.zig");

const Agent = execution.Agent;
const Object = types.Object;

/// 10.4.7.1 [[SetPrototypeOf]] ( proto )
/// https://tc39.es/ecma262/#sec-immutable-prototype-exotic-objects-setprototypeof-v
pub fn setPrototypeOf(agent: *Agent, obj: *Object, proto: ?*Object) Agent.Error!bool {
    // 1. Return ? SetImmutablePrototype(obj, proto).
    return setImmutablePrototype(agent, obj, proto);
}

/// 10.4.7.2 SetImmutablePrototype ( obj, proto )
/// https://tc39.es/ecma262/#sec-set-immutable-prototype
pub fn setImmutablePrototype(
    agent: *Agent,
    obj: *Object,
    proto: ?*Object,
) Agent.Error!bool {
    // 1. Let current be ? obj.[[GetPrototypeOf]]().
    const current = try obj.internalMethods().getPrototypeOf(agent, obj);

    // 2. If SameValue(proto, current) is true, return true.
    if (proto == current) return true;

    // 3. Return false.
    return false;
}
