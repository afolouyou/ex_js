const std = @import("std");

const builtins = @import("../builtins.zig");
const execution = @import("../execution.zig");
const types = @import("../types.zig");

const Agent = execution.Agent;
const Arguments = types.Arguments;
const Iterator = types.Iterator;
const MakeObject = types.MakeObject;
const Object = types.Object;
const PropertyKey = types.PropertyKey;
const Realm = execution.Realm;
const Value = types.Value;
const createIteratorResultObject = types.createIteratorResultObject;
const ordinaryObjectCreate = builtins.ordinaryObjectCreate;

/// 27.1.3.2.2.1 The %WrapForValidIteratorPrototype% Object
/// https://tc39.es/ecma262/#sec-%wrapforvaliditeratorprototype%-object
pub const prototype = struct {
    pub fn create(agent: *Agent, realm: *Realm) std.mem.Allocator.Error!*Object {
        return ordinaryObjectCreate(agent, try realm.intrinsic(.iterator_prototype));
    }

    pub fn init(agent: *Agent, realm: *Realm, object: *Object) std.mem.Allocator.Error!void {
        try object.defineBuiltinFunction(agent, "next", next, 0, realm);
        try object.defineBuiltinFunction(agent, "return", @"return", 0, realm);
    }

    /// 27.1.3.2.2.1.1 %WrapForValidIteratorPrototype%.next ( )
    /// https://tc39.es/ecma262/#sec-%wrapforvaliditeratorprototype%.next
    fn next(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let obj be this value.
        // 2. Perform ? RequireInternalSlot(obj, [[Iterated]]).
        const wrap_for_valid_iterator = try this_value.requireInternalSlot(agent, WrapForValidIterator);

        // 3. Let iteratorRecord be obj.[[Iterated]].
        const iterator = wrap_for_valid_iterator.fields.iterated;

        // 4. Return ? Call(iteratorRecord.[[NextMethod]], iteratorRecord.[[Iterator]]).
        return iterator.next_method.call(agent, Value.from(iterator.iterator), &.{});
    }

    /// 27.1.3.2.2.1.2 %WrapForValidIteratorPrototype%.return ( )
    /// https://tc39.es/ecma262/#sec-%wrapforvaliditeratorprototype%.return
    fn @"return"(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let obj be this value.
        // 2. Perform ? RequireInternalSlot(obj, [[Iterated]]).
        const wrap_for_valid_iterator = try this_value.requireInternalSlot(agent, WrapForValidIterator);

        // 3. Let iterator be obj.[[Iterated]].[[Iterator]].
        // 4. Assert: iterator is an Object.
        const iterator = wrap_for_valid_iterator.fields.iterated.iterator;

        // 5. Let returnMethod be ? GetMethod(iterator, "return").
        const return_method = try iterator.getMethod(agent, PropertyKey.from("return")) orelse {
            // 6. If returnMethod is undefined, then
            //     a. Return CreateIteratorResultObject(undefined, true).
            return Value.from(try createIteratorResultObject(agent, .undefined, true));
        };

        // 7. Return ? Call(returnMethod, iterator).
        return return_method.call(agent, Value.from(iterator), &.{});
    }
};

pub const WrapForValidIterator = MakeObject(.{
    .Fields = struct {
        /// [[Iterated]]
        iterated: Iterator,
    },
    .tag = .wrap_for_valid_iterator,
    .display_name = "WrapForValidIterator",
});
