//! 22.2.9 RegExp String Iterator Objects
//! https://tc39.es/ecma262/#sec-regexp-string-iterator-objects

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
const advanceStringIndex = builtins.advanceStringIndex;
const createIteratorResultObject = types.createIteratorResultObject;
const ordinaryObjectCreate = builtins.ordinaryObjectCreate;
const regExpExec = builtins.regExpExec;

/// 22.2.9.1 CreateRegExpStringIterator ( regexp, string, global, fullUnicode )
/// https://tc39.es/ecma262/#sec-createregexpstringiterator
pub fn createRegExpStringIterator(
    agent: *Agent,
    regexp: *Object,
    string: *const String,
    global: bool,
    full_unicode: bool,
) std.mem.Allocator.Error!*RegExpStringIterator {
    const realm = agent.currentRealm();

    // 1. Let iterator be OrdinaryObjectCreate(%RegExpStringIteratorPrototype%,
    //    « [[IteratingRegExp]], [[IteratedString]], [[Global]], [[Unicode]], [[Done]] »).
    const iterator = try RegExpStringIterator.create(agent, .{
        .prototype = try realm.intrinsic(.reg_exp_string_iterator_prototype),
        .fields = .{
            .state = .{
                // 2. Set iterator.[[IteratingRegExp]] to regexp.
                .iterating_regexp = regexp,

                // 3. Set iterator.[[IteratedString]] to string.
                .iterated_string = string,

                // 4. Set iterator.[[Global]] to global.
                .global = global,

                // 5. Set iterator.[[Unicode]] to fullUnicode.
                .unicode = full_unicode,

                // 6. Set iterator.[[Done]] to false.
            },
        },
    });

    // 7. Return iterator.
    return iterator;
}

/// 22.2.9.2 The %RegExpStringIteratorPrototype% Object
/// https://tc39.es/ecma262/#sec-%regexpstringiteratorprototype%-object
pub const prototype = struct {
    pub fn create(agent: *Agent, realm: *Realm) std.mem.Allocator.Error!*Object {
        return ordinaryObjectCreate(agent, try realm.intrinsic(.iterator_prototype));
    }

    pub fn init(agent: *Agent, realm: *Realm, object: *Object) std.mem.Allocator.Error!void {
        try object.defineBuiltinFunction(agent, "next", next, 0, realm);

        // 22.2.9.2.2 %RegExpStringIteratorPrototype% [ %Symbol.toStringTag% ]
        // https://tc39.es/ecma262/#sec-%regexpstringiteratorprototype%-%symbol.tostringtag%
        try object.defineBuiltinPropertyWithAttributes(
            agent,
            "Symbol.toStringTag",
            Value.from("RegExp String Iterator"),
            .{
                .writable = false,
                .enumerable = false,
                .configurable = true,
            },
        );
    }

    /// 22.2.9.2.1 %RegExpStringIteratorPrototype%.next ( )
    /// https://tc39.es/ecma262/#sec-%regexpstringiteratorprototype%.next
    fn next(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let iteratorObj be the this value.
        // 2. If iteratorObj is not an Object, throw a TypeError exception.
        // 3. If iteratorObj does not have all of the internal slots of a RegExp String Iterator
        //    Object Instance (see 22.2.9.3), throw a TypeError exception.
        const regexp_string_iterator = try this_value.requireInternalSlot(agent, RegExpStringIterator);

        // 4. If iteratorObj.[[Done]] is true, then
        if (regexp_string_iterator.fields == .completed) {
            // a. Return CreateIteratorResultObject(undefined, true).
            return Value.from(try createIteratorResultObject(agent, .undefined, true));
        }

        // 5. Let regexp be iteratorObj.[[IteratingRegExp]].
        const regexp = regexp_string_iterator.fields.state.iterating_regexp;

        // 6. Let string be iteratorObj.[[IteratedString]].
        const string = regexp_string_iterator.fields.state.iterated_string;

        // 7. Let global be iteratorObj.[[Global]].
        const global = regexp_string_iterator.fields.state.global;

        // 8. Let fullUnicode be iteratorObj.[[Unicode]].
        const full_unicode = regexp_string_iterator.fields.state.unicode;

        // 9. Let match be ? RegExpExec(regexp, string).
        const match = try regExpExec(agent, regexp, string) orelse {
            // 10. If match is null, then

            // a. Set iteratorObj.[[Done]] to true.
            regexp_string_iterator.fields = .completed;

            // b. Return CreateIteratorResultObject(undefined, true).
            return Value.from(try createIteratorResultObject(agent, .undefined, true));
        };

        // 11. If global is false, then
        if (!global) {
            // a. Set iteratorObj.[[Done]] to true.
            regexp_string_iterator.fields = .completed;

            // b. Return CreateIteratorResultObject(match, false).
            return Value.from(try createIteratorResultObject(agent, Value.from(match), false));
        }

        // 12. Let matchString be ? ToString(? Get(match, "0")).
        const match_string = try (try match.get(agent, PropertyKey.from(0))).toString(agent);

        // 13. If matchString is the empty String, then
        if (match_string.isEmpty()) {
            // a. Let thisIndex be ℝ(? ToLength(? Get(regexp, "lastIndex"))).
            const this_index = try (try regexp.get(agent, PropertyKey.from("lastIndex"))).toLength(agent);

            // b. Let nextIndex be AdvanceStringIndex(string, thisIndex, fullUnicode).
            const next_index = advanceStringIndex(string, this_index, full_unicode);

            // c. Perform ? Set(regexp, "lastIndex", 𝔽(nextIndex), true).
            try regexp.set(
                agent,
                PropertyKey.from("lastIndex"),
                Value.from(@as(f64, @floatFromInt(next_index))),
                .throw,
            );
        }

        // 14. Return CreateIteratorResultObject(match, false).
        return Value.from(try createIteratorResultObject(agent, Value.from(match), false));
    }
};

/// 22.2.9.3 Properties of RegExp String Iterator Instances
/// https://tc39.es/ecma262/#sec-properties-of-regexp-string-iterator-instances
pub const RegExpStringIterator = MakeObject(.{
    .Fields = union(enum) {
        state: struct {
            /// [[IteratingRegExp]]
            iterating_regexp: *Object,

            /// [[IteratedString]]
            iterated_string: *const String,

            /// [[Global]]
            global: bool,

            /// [[Unicode]]
            unicode: bool,
        },
        completed,
    },
    .tag = .reg_exp_string_iterator,
    .display_name = "RegExp String Iterator",
});
