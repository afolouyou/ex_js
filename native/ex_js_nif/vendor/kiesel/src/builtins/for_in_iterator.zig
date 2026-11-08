//! 14.7.5.10 For-In Iterator Objects
//! https://tc39.es/ecma262/#sec-for-in-iterator-objects

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
const Value = types.Value;
const createIteratorResultObject = types.createIteratorResultObject;
const ordinaryObjectCreate = builtins.ordinaryObjectCreate;

/// 14.7.5.10.1 CreateForInIterator ( obj )
/// https://tc39.es/ecma262/#sec-createforiniterator
pub fn createForInIterator(agent: *Agent, obj: *Object) std.mem.Allocator.Error!*ForInIterator {
    const realm = agent.currentRealm();

    // 1. Let iterator be OrdinaryObjectCreate(%ForInIteratorPrototype%, « [[Object]],
    //    [[ObjectWasVisited]], [[VisitedKeys]], [[RemainingKeys]] »).
    // 6. Return iterator.
    return ForInIterator.create(agent, .{
        .prototype = try realm.intrinsic(.for_in_iterator_prototype),
        .fields = .{
            .state = .{
                // 2. Set iterator.[[Object]] to obj.
                .object = obj,

                // 3. Set iterator.[[ObjectWasVisited]] to false.
                .object_was_visited = false,

                // 4. Set iterator.[[VisitedKeys]] to a new empty List.
                .visited_keys = .empty,

                // 5. Set iterator.[[RemainingKeys]] to a new empty List.
                .remaining_keys = .empty,
            },
        },
    });
}

/// 14.7.5.10.2 The %ForInIteratorPrototype% Object
/// https://tc39.es/ecma262/#sec-%foriniteratorprototype%-object
pub const prototype = struct {
    pub fn create(agent: *Agent, realm: *Realm) std.mem.Allocator.Error!*Object {
        return ordinaryObjectCreate(agent, try realm.intrinsic(.iterator_prototype));
    }

    pub fn init(agent: *Agent, realm: *Realm, object: *Object) std.mem.Allocator.Error!void {
        try object.defineBuiltinFunction(agent, "next", next, 0, realm);
    }

    /// 14.7.5.10.2.1 %ForInIteratorPrototype%.next ( )
    /// https://tc39.es/ecma262/#sec-%foriniteratorprototype%.next
    fn next(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let iterator be the this value.
        // 2. Assert: iterator is an Object.
        // 3. Assert: iterator has all of the internal slots of a For-In Iterator instance
        //    (14.7.5.10.3).
        std.debug.assert(this_value.isObject());
        std.debug.assert(this_value.asObject().is(ForInIterator));
        const for_in_iterator = this_value.asObject().as(ForInIterator);

        if (for_in_iterator.fields == .completed) {
            return Value.from(try createIteratorResultObject(agent, .undefined, true));
        }

        // 4. Let obj be iterator.[[Object]].
        var obj = for_in_iterator.fields.state.object;

        // 5. Repeat,
        while (true) {
            // a. If iterator.[[ObjectWasVisited]] is false, then
            if (!for_in_iterator.fields.state.object_was_visited) {
                // i. Let keys be ? obj.[[OwnPropertyKeys]]().
                const keys = try obj.internalMethods().ownPropertyKeys(agent, obj);
                defer agent.gc_allocator.free(keys);

                // ii. For each element key of keys, do
                for (keys) |key| {
                    // 1. If key is a String, then
                    if (key == .string or key == .integer_index) {
                        // a. Append key to iterator.[[RemainingKeys]].
                        try for_in_iterator.fields.state.remaining_keys.append(agent.gc_allocator, key);
                    }
                }

                // iii. Set iterator.[[ObjectWasVisited]] to true.
                for_in_iterator.fields.state.object_was_visited = true;
            }

            // b. Repeat, while iterator.[[RemainingKeys]] is not empty,
            while (for_in_iterator.fields.state.remaining_keys.items.len != 0) {
                // i. Let key be the first element of iterator.[[RemainingKeys]].
                // ii. Remove the first element from iterator.[[RemainingKeys]].
                const key = for_in_iterator.fields.state.remaining_keys.orderedRemove(0);

                // iii. If iterator.[[VisitedKeys]] does not contain key, then
                if (!for_in_iterator.fields.state.visited_keys.contains(key)) {
                    // 1. Let propertyDesc be ? obj.[[GetOwnProperty]](key).
                    const property_desc = try obj.internalMethods().getOwnProperty(
                        agent,
                        obj,
                        key,
                    );

                    // 2. If propertyDesc is not undefined, then
                    if (property_desc != null) {
                        // a. Append key to iterator.[[VisitedKeys]].
                        try for_in_iterator.fields.state.visited_keys.putNoClobber(
                            agent.gc_allocator,
                            key,
                            {},
                        );

                        // b. If propertyDesc.[[Enumerable]] is true, return
                        //    CreateIteratorResultObject(key, false).
                        if (property_desc.?.enumerable == true) {
                            return Value.from(
                                try createIteratorResultObject(
                                    agent,
                                    try key.toValue(agent),
                                    false,
                                ),
                            );
                        }
                    }
                }
            }

            // c. Set obj to ? obj.[[GetPrototypeOf]]().
            obj = (try obj.internalMethods().getPrototypeOf(agent, obj)) orelse {
                // f. If obj is null, return CreateIteratorResultObject(undefined, true).
                for_in_iterator.fields = .completed;
                return Value.from(try createIteratorResultObject(agent, .undefined, true));
            };

            // d. Set iterator.[[Object]] to obj.
            for_in_iterator.fields.state.object = obj;

            // e. Set iterator.[[ObjectWasVisited]] to false.
            for_in_iterator.fields.state.object_was_visited = false;
        }
    }
};

/// 14.7.5.10.3 Properties of For-In Iterator Instances
/// https://tc39.es/ecma262/#sec-properties-of-for-in-iterator-instances
pub const ForInIterator = MakeObject(.{
    .Fields = union(enum) {
        state: struct {
            /// [[Object]]
            object: *Object,

            /// [[ObjectWasVisited]]
            object_was_visited: bool,

            /// [[VisitedKeys]]
            visited_keys: PropertyKey.ArrayHashMap(void),

            /// [[RemainingKeys]]
            remaining_keys: std.ArrayList(PropertyKey),
        },
        completed,
    },
    .tag = .for_in_iterator,
    .display_name = "For-In Iterator",
});
