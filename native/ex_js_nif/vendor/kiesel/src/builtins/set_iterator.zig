//! 24.2.6 Set Iterator Objects
//! https://tc39.es/ecma262/#sec-set-iterator-objects

const std = @import("std");

const builtins = @import("../builtins.zig");
const execution = @import("../execution.zig");
const types = @import("../types.zig");

const Agent = execution.Agent;
const Arguments = types.Arguments;
const MakeObject = types.MakeObject;
const Object = types.Object;
const Realm = execution.Realm;
const Set = builtins.Set;
const Value = types.Value;
const createArrayFromList = types.createArrayFromList;
const createIteratorResultObject = types.createIteratorResultObject;
const ordinaryObjectCreate = builtins.ordinaryObjectCreate;

/// 24.2.6.1 CreateSetIterator ( set, kind )
/// https://tc39.es/ecma262/#sec-createsetiterator
pub fn createSetIterator(
    agent: *Agent,
    set_value: Value,
    kind: Object.EnumerationKind,
) Agent.Error!*SetIterator {
    const realm = agent.currentRealm();

    // 1. Perform ? RequireInternalSlot(set, [[SetData]]).
    const set = try set_value.requireInternalSlot(agent, Set);

    // 2. Let closure be a new Abstract Closure with no parameters that captures set and kind and
    //    performs the following steps when called:
    //    [...]
    // 3. Return CreateIteratorFromClosure(closure, "%SetIteratorPrototype%",
    //    %SetIteratorPrototype%).
    return SetIterator.create(agent, .{
        .prototype = try realm.intrinsic(.set_iterator_prototype),
        .fields = .{ .state = .{ .set = set, .kind = kind, .index = 0 } },
    });
}

/// 24.2.6.2 The %SetIteratorPrototype% Object
/// https://tc39.es/ecma262/#sec-%setiteratorprototype%-object
pub const prototype = struct {
    pub fn create(agent: *Agent, realm: *Realm) std.mem.Allocator.Error!*Object {
        return ordinaryObjectCreate(agent, try realm.intrinsic(.iterator_prototype));
    }

    pub fn init(agent: *Agent, realm: *Realm, object: *Object) std.mem.Allocator.Error!void {
        try object.defineBuiltinFunction(agent, "next", next, 0, realm);

        // 24.2.6.2.2 %SetIteratorPrototype% [ %Symbol.toStringTag% ]
        // https://tc39.es/ecma262/#sec-%setiteratorprototype%-%symbol.tostringtag%
        try object.defineBuiltinPropertyWithAttributes(
            agent,
            "Symbol.toStringTag",
            Value.from("Set Iterator"),
            .{
                .writable = false,
                .enumerable = false,
                .configurable = true,
            },
        );
    }

    /// 24.2.6.2.1 %SetIteratorPrototype%.next ( )
    /// https://tc39.es/ecma262/#sec-%setiteratorprototype%.next
    fn next(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Return ? GeneratorResume(this value, empty, "%SetIteratorPrototype%").
        // NOTE: Instead of using generators this implements one loop iteration of the
        //       CreateSetIterator closure. State is kept track of through the SetIterator
        //       instance instead of as local variables. This should not be observable.

        // 1. Let state be ? GeneratorValidate(gen, genBrand).
        const set_iterator = try this_value.requireInternalSlot(agent, SetIterator);

        // 2. If state is completed, return CreateIteratorResultObject(undefined, true).
        if (set_iterator.fields == .completed) {
            return Value.from(try createIteratorResultObject(agent, .undefined, true));
        }

        const set = set_iterator.fields.state.set;
        const kind = set_iterator.fields.state.kind;
        var index = set_iterator.fields.state.index;

        std.debug.assert(kind != .key);

        if (index == 0) set.fields.active_iterators += 1;

        // a. Let index be 0.

        // b. Let entries be set.[[SetData]].
        const entries = &set.fields.set_data;

        // c. Let numEntries be the number of elements in entries.
        const num_entries = entries.count();

        // d. Repeat, while index < numEntries,
        const entry = while (index < num_entries) : (index += 1) {
            // i. Let e be entries[index].
            const entry = entries.entries.get(index);

            // ii. Set index to index + 1.

            // iii. If e is not empty, then
            if (!entry.key.isUninitialized()) {
                index += 1;
                break entry;
            }
        } else {
            // e. Return NormalCompletion(unused).
            set_iterator.fields = .completed;
            set.fields.active_iterators -= 1;
            try set.fields.compactIfNeeded(agent.gc_allocator);
            return Value.from(try createIteratorResultObject(agent, .undefined, true));
        };

        set_iterator.fields.state.index = index;
        const value = entry.key;

        switch (kind) {
            // 1. If kind is key+value, then
            .key_value => {
                // a. Let result be CreateArrayFromList(« entry, entry »).
                const result = try createArrayFromList(agent, &.{ value, value });

                // b. Perform ? GeneratorYield(CreateIteratorResultObject(result, false)).
                return Value.from(
                    try createIteratorResultObject(agent, Value.from(&result.object), false),
                );
            },

            // 2. Else,
            //     a. Assert: kind is value.
            .value => {
                // b. Perform ? GeneratorYield(CreateIteratorResultObject(entry, false)).
                return Value.from(try createIteratorResultObject(agent, value, false));
            },

            .key => unreachable,
        }

        // 3. NOTE: The number of elements in entries may have increased while execution of this
        //    abstract operation was paused by GeneratorYield.
        // 4. Set entriesCount to the number of elements in entries.
    }
};

pub const SetIterator = MakeObject(.{
    .Fields = union(enum) {
        state: struct {
            set: *Set,
            kind: Object.EnumerationKind,
            index: usize,
        },
        completed,
    },
    .tag = .set_iterator,
    .display_name = "Set Iterator",
});
