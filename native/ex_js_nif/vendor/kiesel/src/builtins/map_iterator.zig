//! 24.1.5 Map Iterator Objects
//! https://tc39.es/ecma262/#sec-map-iterator-objects

const std = @import("std");

const builtins = @import("../builtins.zig");
const execution = @import("../execution.zig");
const types = @import("../types.zig");

const Agent = execution.Agent;
const Arguments = types.Arguments;
const MakeObject = types.MakeObject;
const Map = builtins.Map;
const Object = types.Object;
const Realm = execution.Realm;
const Value = types.Value;
const createArrayFromList = types.createArrayFromList;
const createIteratorResultObject = types.createIteratorResultObject;
const ordinaryObjectCreate = builtins.ordinaryObjectCreate;

/// 24.1.5.1 CreateMapIterator ( map, kind )
/// https://tc39.es/ecma262/#sec-createmapiterator
pub fn createMapIterator(
    agent: *Agent,
    map_value: Value,
    kind: Object.EnumerationKind,
) Agent.Error!*MapIterator {
    const realm = agent.currentRealm();

    // 1. Perform ? RequireInternalSlot(map, [[MapData]]).
    const map = try map_value.requireInternalSlot(agent, Map);

    // 2. Let closure be a new Abstract Closure with no parameters that captures map and kind and
    //    performs the following steps when called:
    //    [...]
    // 3. Return CreateIteratorFromClosure(closure, "%MapIteratorPrototype%",
    //    %MapIteratorPrototype%).
    return MapIterator.create(agent, .{
        .prototype = try realm.intrinsic(.map_iterator_prototype),
        .fields = .{ .state = .{ .map = map, .kind = kind, .index = 0 } },
    });
}

/// 24.1.5.2 The %MapIteratorPrototype% Object
/// https://tc39.es/ecma262/#sec-%mapiteratorprototype%-object
pub const prototype = struct {
    pub fn create(agent: *Agent, realm: *Realm) std.mem.Allocator.Error!*Object {
        return ordinaryObjectCreate(agent, try realm.intrinsic(.iterator_prototype));
    }

    pub fn init(agent: *Agent, realm: *Realm, object: *Object) std.mem.Allocator.Error!void {
        try object.defineBuiltinFunction(agent, "next", next, 0, realm);

        // 23.1.5.2.2 %ArrayIteratorPrototype% [ %Symbol.toStringTag% ]
        // https://tc39.es/ecma262/#sec-%arrayiteratorprototype%-%symbol.tostringtag%
        try object.defineBuiltinPropertyWithAttributes(
            agent,
            "Symbol.toStringTag",
            Value.from("Map Iterator"),
            .{
                .writable = false,
                .enumerable = false,
                .configurable = true,
            },
        );
    }

    /// 24.1.5.2.1 %MapIteratorPrototype%.next ( )
    /// https://tc39.es/ecma262/#sec-%mapiteratorprototype%.next
    fn next(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Return ? GeneratorResume(this value, empty, "%MapIteratorPrototype%").
        // NOTE: Instead of using generators this implements one loop iteration of the
        //       CreateMapIterator closure. State is kept track of through the MapIterator
        //       instance instead of as local variables. This should not be observable.

        // 1. Let state be ? GeneratorValidate(gen, genBrand).
        const map_iterator = try this_value.requireInternalSlot(agent, MapIterator);

        // 2. If state is completed, return CreateIteratorResultObject(undefined, true).
        if (map_iterator.fields == .completed) {
            return Value.from(try createIteratorResultObject(agent, .undefined, true));
        }

        const map = map_iterator.fields.state.map;
        const kind = map_iterator.fields.state.kind;
        var index = map_iterator.fields.state.index;

        if (index == 0) map.fields.active_iterators += 1;

        // a. Let entries be map.[[MapData]].
        const entries = &map.fields.map_data;

        // b. Let index be 0.

        // c. Let numEntries be the number of elements in entries.
        const num_entries = entries.count();

        // d. Repeat, while index < numEntries,
        const entry = while (index < num_entries) : (index += 1) {
            // i. Let e be entries[index].
            const entry = entries.entries.get(index);

            // ii. Set index to index + 1.

            // iii. If e.[[Key]] is not empty, then
            if (!entry.key.isUninitialized()) {
                index += 1;
                break entry;
            }
        } else {
            // e. Return NormalCompletion(unused).
            map_iterator.fields = .completed;
            map.fields.active_iterators -= 1;
            try map.fields.compactIfNeeded(agent.gc_allocator);
            return Value.from(try createIteratorResultObject(agent, .undefined, true));
        };

        map_iterator.fields.state.index = index;
        const key = entry.key;
        const value = entry.value;

        const result = switch (kind) {
            // 1. If kind is key, then
            //     a. Let result be entry.[[Key]].
            .key => key,

            // 2. Else if kind is value, then
            //     a. Let result be entry.[[Value]].
            .value => value,

            // 3. Else,
            //     a. Assert: kind is key+value.
            //     b. Let result be CreateArrayFromList(« entry.[[Key]], entry.[[Value]] »).
            .key_value => blk: {
                const array = try createArrayFromList(agent, &.{ key, value });
                break :blk Value.from(&array.object);
            },
        };

        // 4. Perform ? GeneratorYield(CreateIteratorResultObject(result, false)).
        return Value.from(try createIteratorResultObject(agent, result, false));

        // 5. NOTE: The number of elements in entries may have increased while execution of this
        //    abstract operation was paused by GeneratorYield.
        // 6. Set entriesCount to the number of elements in entries.
    }
};

pub const MapIterator = MakeObject(.{
    .Fields = union(enum) {
        state: struct {
            map: *Map,
            kind: Object.EnumerationKind,
            index: usize,
        },
        completed,
    },
    .tag = .map_iterator,
    .display_name = "Map Iterator",
});
