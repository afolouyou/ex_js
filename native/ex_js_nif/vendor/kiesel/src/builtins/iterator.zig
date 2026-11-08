//! 27.1.3 Iterator Objects
//! https://tc39.es/ecma262/#sec-iterator-objects

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
const createArrayFromList = types.createArrayFromList;
const createBuiltinFunction = builtins.createBuiltinFunction;
const getIterator = types.getIterator;
const getIteratorDirect = types.getIteratorDirect;
const getIteratorFlattenable = types.getIteratorFlattenable;
const ordinaryCreateFromConstructor = builtins.ordinaryCreateFromConstructor;
const ordinaryObjectCreate = builtins.ordinaryObjectCreate;
const sameValueZero = types.sameValueZero;

/// 27.1.3.1 The Iterator Constructor
/// https://tc39.es/ecma262/#sec-iterator-constructor
pub const constructor = struct {
    pub fn create(agent: *Agent, realm: *Realm) std.mem.Allocator.Error!*Object {
        const builtin_function = try createBuiltinFunction(
            agent,
            .{ .constructor = impl },
            0,
            "Iterator",
            .{ .realm = realm, .proto = try realm.intrinsic(.function_prototype) },
        );
        return &builtin_function.object;
    }

    pub fn init(agent: *Agent, realm: *Realm, object: *Object) std.mem.Allocator.Error!void {
        try object.defineBuiltinFunction(agent, "concat", concat, 0, realm);
        try object.defineBuiltinFunction(agent, "from", from, 1, realm);
        try object.defineBuiltinFunction(agent, "zip", zip, 1, realm);
        try object.defineBuiltinFunction(agent, "zipKeyed", zipKeyed, 1, realm);

        // 27.1.3.2.3 Iterator.prototype
        // https://tc39.es/ecma262/#sec-iterator.prototype
        try object.defineBuiltinPropertyWithAttributes(
            agent,
            "prototype",
            Value.from(try realm.intrinsic(.iterator_prototype)),
            .none,
        );
    }

    /// 27.1.3.1.1 Iterator ( )
    /// https://tc39.es/ecma262/#sec-iterator
    fn impl(agent: *Agent, _: Arguments, new_target: ?*Object) Agent.Error!Value {
        // 1. If NewTarget is either undefined or the active function object, throw a TypeError
        //    exception.
        if (new_target == null or new_target.? == agent.activeFunctionObject()) {
            return agent.throwException(
                .type_error,
                "Iterator must not be constructed directly",
                .{},
            );
        }

        // 2. Return ? OrdinaryCreateFromConstructor(NewTarget, "%Iterator.prototype%").
        const iterator = try ordinaryCreateFromConstructor(
            Iterator,
            agent,
            new_target.?,
            .iterator_prototype,
            {},
        );
        return Value.from(&iterator.object);
    }

    /// 27.1.3.2.1 Iterator.concat ( ...items )
    /// https://tc39.es/ecma262/#sec-iterator.concat
    fn concat(agent: *Agent, _: Value, arguments: Arguments) Agent.Error!Value {
        const realm = agent.currentRealm();

        const Iterable = struct {
            /// [[OpenMethod]]
            open_method: *Object,

            /// [[Iterable]]
            iterable: *Object,
        };

        // 1. Let iterables be a new empty List.
        const iterables = try agent.gc_allocator.alloc(Iterable, arguments.count());
        errdefer agent.gc_allocator.free(iterables);

        // 2. For each element item of items, do
        for (arguments.values, 0..) |item, i| {
            // a. If item is not an Object, throw a TypeError exception.
            if (!item.isObject()) {
                return agent.throwException(.type_error, "{f} is not an Object", .{item});
            }

            // b. Let method be ? GetMethod(item, %Symbol.iterator%).
            const method = try item.getMethod(
                agent,
                PropertyKey.from(agent.well_known_symbols.iterator),
            ) orelse {
                // c. If method is undefined, throw a TypeError exception.
                return agent.throwException(
                    .type_error,
                    "Object has no Symbol.iterator method",
                    .{},
                );
            };

            // d. Append the Record { [[OpenMethod]]: method, [[Iterable]]: item } to iterables.
            iterables[i] = .{ .open_method = method, .iterable = item.asObject() };
        }

        const Captures = struct {
            iterables: []const Iterable,
            index: usize,
            inner_iterator: ?types.Iterator,
        };
        const captures = try agent.gc_allocator.create(Captures);
        captures.* = .{
            .iterables = iterables,
            .index = 0,
            .inner_iterator = null,
        };

        // 3. Let closure be a new Abstract Closure with no parameters that captures iterables and
        //    performs the following steps when called:
        const closure = struct {
            fn func(agent_: *Agent, iterator_helper: *builtins.IteratorHelper) Agent.Error!?Value {
                const captures_ = iterator_helper.fields.state.capturesAs(Captures);
                const iterables_ = captures_.iterables;
                const index = &captures_.index;
                const inner_iterator_ = &captures_.inner_iterator;

                const State = enum { outer, inner };
                const state: State = if (inner_iterator_.* == null)
                    .outer
                else
                    .inner;

                // a. For each Record iterable of iterables, do
                loop: switch (state) {
                    .outer => {
                        if (index.* >= iterables_.len) return null;
                        const iterable = iterables_[index.*];
                        index.* += 1;

                        // i. Let iterator be ? Call(iterable.[[OpenMethod]],
                        //    iterable.[[Iterable]]).
                        const iterator = try iterable.open_method.call(
                            agent_,
                            Value.from(iterable.iterable),
                            &.{},
                        );

                        // ii. If iterator is not an Object, throw a TypeError exception.
                        if (!iterator.isObject()) {
                            return agent_.throwException(.type_error, "{f} is not an Object", .{iterator});
                        }

                        // iii. Let iteratorRecord be ? GetIteratorDirect(iterator).
                        inner_iterator_.* = try getIteratorDirect(agent_, iterator.asObject());

                        continue :loop .inner;
                    },
                    .inner => {
                        // iv. Let innerAlive be true.
                        // v. Repeat, while innerAlive is true,
                        //     1. Let innerValue be ? IteratorStepValue(iteratorRecord).
                        //     2. If innerValue is done, then
                        //         a. Set innerAlive to false.
                        //     3. Else,
                        //         a. Let completion be Completion(Yield(innerValue)).
                        //         b. If completion is an abrupt completion, then
                        //             i. Return ? IteratorClose(iteratorRecord, completion).
                        if (try inner_iterator_.*.?.stepValue(agent_)) |value| return value;
                        inner_iterator_.* = null;
                        continue :loop .outer;
                    },
                }

                // b. Return ReturnCompletion(undefined).
            }
        }.func;

        const abruptClosure = struct {
            fn func(agent_: *Agent, iterator_helper: *builtins.IteratorHelper) Agent.Error!void {
                // 3.a.v.3.b.
                const captures_ = iterator_helper.fields.state.capturesAs(Captures);
                if (captures_.inner_iterator) |inner_iterator| {
                    _ = try inner_iterator.close(agent_, @as(Agent.Error!void, {}));
                }
            }
        }.func;

        // 4. Let gen be CreateIteratorFromClosure(closure, "Iterator Helper",
        //    %IteratorHelperPrototype%, « [[UnderlyingIterators]] »).
        const gen = try builtins.IteratorHelper.create(agent, .{
            .prototype = try realm.intrinsic(.iterator_helper_prototype),
            .fields = .{
                .state = .{
                    // 5. Set gen.[[UnderlyingIterators]] to a new empty List.
                    .underlying_iterators = &.{},

                    .closure = closure,
                    .abruptClosure = abruptClosure,
                    .captures = captures,
                },
            },
        });

        // 6. Return gen.
        return Value.from(&gen.object);
    }

    /// 27.1.3.2.2 Iterator.from ( obj )
    /// https://tc39.es/ecma262/#sec-iterator.from
    fn from(agent: *Agent, _: Value, arguments: Arguments) Agent.Error!Value {
        const realm = agent.currentRealm();
        const obj = arguments.get(0);

        // 1. Let iteratorRecord be ? GetIteratorFlattenable(obj, iterate-string-primitives).
        const iterator = try getIteratorFlattenable(agent, obj, .iterate_string_primitives);

        // 2. Let hasInstance be ? OrdinaryHasInstance(%Iterator%, iteratorRecord.[[Iterator]]).
        const has_instance = try Value.from(
            try realm.intrinsic(.iterator),
        ).ordinaryHasInstance(agent, Value.from(iterator.iterator));

        // 3. If hasInstance is true, then
        if (has_instance) {
            // a. Return iteratorRecord.[[Iterator]].
            return Value.from(iterator.iterator);
        }

        // 4. Let wrapper be OrdinaryObjectCreate(%WrapForValidIteratorPrototype%,
        //    « [[Iterated]] »).
        const wrapper = try builtins.WrapForValidIterator.create(agent, .{
            .prototype = try realm.intrinsic(.wrap_for_valid_iterator_prototype),
            .fields = .{
                // 5. Set wrapper.[[Iterated]] to iteratorRecord.
                .iterated = iterator,
            },
        });

        // 6. Return wrapper.
        return Value.from(&wrapper.object);
    }

    /// 27.1.3.2.4 Iterator.zip ( iterables [ , options ] )
    /// https://tc39.es/ecma262/#sec-iterator.zip
    fn zip(agent: *Agent, _: Value, arguments: Arguments) Agent.Error!Value {
        const iterables = arguments.get(0);
        const options_value = arguments.get(1);

        // 1. If iterables is not an Object, throw a TypeError exception.
        if (!iterables.isObject()) {
            return agent.throwException(.type_error, "{f} is not an Object", .{iterables});
        }

        // 2. Set options to ? GetOptionsObject(options).
        const options = try options_value.getOptionsObject(agent);

        // 3. Let mode be ? Get(options, "mode").
        var mode_value = try options.get(agent, PropertyKey.from("mode"));

        // 4. If mode is undefined, set mode to "shortest".
        // 5. If mode is not one of "shortest", "longest", or "strict", throw a TypeError exception.
        const mode: ZipMode = blk: {
            if (mode_value.isUndefined()) break :blk .shortest;
            if (mode_value.isString()) {
                if (mode_value.asString().eql(String.fromLiteral("shortest"))) break :blk .shortest;
                if (mode_value.asString().eql(String.fromLiteral("longest"))) break :blk .longest;
                if (mode_value.asString().eql(String.fromLiteral("strict"))) break :blk .strict;
            }
            return agent.throwException(.type_error, "Invalid mode {f}", .{mode_value});
        };

        // 6. Let paddingOption be undefined.
        var padding_option: ?*Object = null;

        // 7. If mode is "longest", then
        if (mode == .longest) {
            // a. Set paddingOption to ? Get(options, "padding").
            const padding_option_value = try options.get(agent, PropertyKey.from("padding"));

            // b. If paddingOption is not undefined and paddingOption is not an Object, throw a
            //    TypeError exception.
            if (!padding_option_value.isUndefined() and !padding_option_value.isObject()) {
                return agent.throwException(
                    .type_error,
                    "{f} is not an Object",
                    .{padding_option_value},
                );
            }
            if (padding_option_value.isObject()) {
                padding_option = padding_option_value.asObject();
            }
        }

        // 8. Let iters be a new empty List.
        var iters: std.ArrayList(types.Iterator) = .empty;
        defer iters.deinit(agent.gc_allocator);

        // 9. Let padding be a new empty List.
        var padding: std.ArrayList(Value) = .empty;
        defer padding.deinit(agent.gc_allocator);

        // 10. Let inputIter be ? GetIterator(iterables, sync).
        var input_iter = try getIterator(agent, iterables, .sync);

        // 11. Let next be not-started.
        // 12. Repeat, while next is not done,
        while (true) {
            // a. Set next to Completion(IteratorStepValue(inputIter)).
            const next = input_iter.stepValue(agent) catch |err| {
                // b. IfAbruptCloseIterators(next, iters).
                return types.Iterator.closeAll(agent, iters.items, @as(Agent.Error!Value, err));
            } orelse break;

            // c. If next is not done, then
            // i. Let iter be Completion(GetIteratorFlattenable(next, reject-primitives)).
            const iter = getIteratorFlattenable(agent, next, .reject_primitives) catch |err| {
                // ii. Let needClosing be the list-concatenation of « inputIter » and iters.
                var need_closing: std.ArrayList(types.Iterator) = .empty;
                defer need_closing.deinit(agent.gc_allocator);
                try need_closing.append(agent.gc_allocator, input_iter);
                try need_closing.appendSlice(agent.gc_allocator, iters.items);

                // iii. IfAbruptCloseIterators(iter, needClosing).
                return types.Iterator.closeAll(
                    agent,
                    need_closing.items,
                    @as(Agent.Error!Value, err),
                );
            };

            // iv. Append iter to iters.
            try iters.append(agent.gc_allocator, iter);
        }

        // 13. Let iterCount be the number of elements in iters.
        const iter_count = iters.items.len;

        // 14. If mode is "longest", then
        if (mode == .longest) {
            // a. If paddingOption is undefined, then
            if (padding_option == null) {
                // i. Repeat iterCount times:
                for (0..iter_count) |_| {
                    // 1. Append undefined to padding.
                    try padding.append(agent.gc_allocator, .undefined);
                }
            } else {
                // b. Else,
                // i. Let paddingIter be Completion(GetIterator(paddingOption, sync)).
                var padding_iter = getIterator(
                    agent,
                    Value.from(padding_option.?),
                    .sync,
                ) catch |err| {
                    // ii. IfAbruptCloseIterators(paddingIter, iters).
                    return types.Iterator.closeAll(
                        agent,
                        iters.items,
                        @as(Agent.Error!Value, err),
                    );
                };

                // iii. Let usingIterator be true.
                var using_iterator = true;

                // iv. Repeat iterCount times:
                for (0..iter_count) |_| {
                    // 1. If usingIterator is true, then
                    if (using_iterator) {
                        // a. Set next to Completion(IteratorStepValue(paddingIter)).
                        const maybe_next = padding_iter.stepValue(agent) catch |err| {
                            // b. IfAbruptCloseIterators(next, iters).
                            return types.Iterator.closeAll(
                                agent,
                                iters.items,
                                @as(Agent.Error!Value, err),
                            );
                        };

                        // c. If next is done, then
                        //     i. Set usingIterator to false.
                        // d. Else,
                        //     i. Append next to padding.
                        if (maybe_next) |next| {
                            try padding.append(agent.gc_allocator, next);
                        } else {
                            using_iterator = false;
                        }
                    }

                    // 2. If usingIterator is false, append undefined to padding.
                    if (!using_iterator) {
                        try padding.append(agent.gc_allocator, .undefined);
                    }
                }

                // v. If usingIterator is true, then
                if (using_iterator) {
                    // 1. Let completion be Completion(IteratorClose(paddingIter, NormalCompletion(
                    //    unused))).
                    padding_iter.close(agent, @as(Agent.Error!void, {})) catch |err| {
                        // 2. IfAbruptCloseIterators(completion, iters).
                        return types.Iterator.closeAll(
                            agent,
                            iters.items,
                            @as(Agent.Error!Value, err),
                        );
                    };
                }
            }
        }

        // 15. Let finishResults be a new Abstract Closure with parameters (results) that captures
        //     nothing and performs the following steps when called:
        //     a. Return CreateArrayFromList(results).
        // 16. Return IteratorZip(iters, mode, padding, finishResults).
        return iteratorZip(
            agent,
            try iters.toOwnedSlice(agent.gc_allocator),
            mode,
            try padding.toOwnedSlice(agent.gc_allocator),
            .array,
        );
    }

    /// 27.1.3.2.5 Iterator.zipKeyed ( iterables [ , options ] )
    /// https://tc39.es/ecma262/#sec-iterator.zipkeyed
    fn zipKeyed(agent: *Agent, _: Value, arguments: Arguments) Agent.Error!Value {
        const iterables_value = arguments.get(0);
        const options_value = arguments.get(1);

        // 1. If iterables is not an Object, throw a TypeError exception.
        if (!iterables_value.isObject()) {
            return agent.throwException(.type_error, "{f} is not an Object", .{iterables_value});
        }
        const iterables = iterables_value.asObject();

        // 2. Set options to ? GetOptionsObject(options).
        const options = try options_value.getOptionsObject(agent);

        // 3. Let mode be ? Get(options, "mode").
        var mode_value = try options.get(agent, PropertyKey.from("mode"));

        // 4. If mode is undefined, set mode to "shortest".
        // 5. If mode is not one of "shortest", "longest", or "strict", throw a TypeError exception.
        const mode: ZipMode = blk: {
            if (mode_value.isUndefined()) break :blk .shortest;
            if (mode_value.isString()) {
                if (mode_value.asString().eql(String.fromLiteral("shortest"))) break :blk .shortest;
                if (mode_value.asString().eql(String.fromLiteral("longest"))) break :blk .longest;
                if (mode_value.asString().eql(String.fromLiteral("strict"))) break :blk .strict;
            }
            return agent.throwException(.type_error, "Invalid mode {f}", .{mode_value});
        };

        // 6. Let paddingOption be undefined.
        var padding_option: ?*Object = null;

        // 7. If mode is "longest", then
        if (mode == .longest) {
            // a. Set paddingOption to ? Get(options, "padding").
            const padding_option_value = try options.get(agent, PropertyKey.from("padding"));

            // b. If paddingOption is not undefined and paddingOption is not an Object, throw a
            //    TypeError exception.
            if (!padding_option_value.isUndefined() and !padding_option_value.isObject()) {
                return agent.throwException(.type_error, "padding must be an Object", .{});
            }
            if (padding_option_value.isObject()) {
                padding_option = padding_option_value.asObject();
            }
        }

        // 8. Let iters be a new empty List.
        var iters: std.ArrayList(types.Iterator) = .empty;
        defer iters.deinit(agent.gc_allocator);

        // 9. Let padding be a new empty List.
        var padding: std.ArrayList(Value) = .empty;
        defer padding.deinit(agent.gc_allocator);

        // 10. Let allKeys be ? iterables.[[OwnPropertyKeys]]().
        const all_keys = try iterables.internalMethods().ownPropertyKeys(
            agent,
            iterables,
        );
        defer agent.gc_allocator.free(all_keys);

        // 11. Let keys be a new empty List.
        var keys: std.ArrayList(PropertyKey) = .empty;
        defer keys.deinit(agent.gc_allocator);

        // 12. For each element key of allKeys, do
        for (all_keys) |key| {
            // a. Let propertyDesc be Completion(iterables.[[GetOwnProperty]](key)).
            const property_desc = iterables.internalMethods().getOwnProperty(
                agent,
                iterables,
                key,
            ) catch |err| {
                // b. IfAbruptCloseIterators(propertyDesc, iters).
                return types.Iterator.closeAll(agent, iters.items, @as(Agent.Error!Value, err));
            };

            // c. If propertyDesc is not undefined and propertyDesc.[[Enumerable]] is true, then
            if (property_desc != null and property_desc.?.enumerable == true) {
                // i. Let value be Completion(Get(iterables, key)).
                const value = iterables.get(agent, key) catch |err| {
                    // ii. IfAbruptCloseIterators(value, iters).
                    return types.Iterator.closeAll(
                        agent,
                        iters.items,
                        @as(Agent.Error!Value, err),
                    );
                };

                // iii. If value is not undefined, then
                if (!value.isUndefined()) {
                    // 1. Append key to keys.
                    try keys.append(agent.gc_allocator, key);

                    // 2. Let iter be Completion(GetIteratorFlattenable(value, reject-primitives)).
                    const iter = getIteratorFlattenable(
                        agent,
                        value,
                        .reject_primitives,
                    ) catch |err| {
                        // 3. IfAbruptCloseIterators(iter, iters).
                        return types.Iterator.closeAll(
                            agent,
                            iters.items,
                            @as(Agent.Error!Value, err),
                        );
                    };

                    // 4. Append iter to iters.
                    try iters.append(agent.gc_allocator, iter);
                }
            }
        }

        // 13. Let iterCount be the number of elements in iters.
        const iter_count = iters.items.len;

        // 14. If mode is "longest", then
        if (mode == .longest) {
            // a. If paddingOption is undefined, then
            if (padding_option == null) {
                // i. Repeat iterCount times:
                for (0..iter_count) |_| {
                    // 1. Append undefined to padding.
                    try padding.append(agent.gc_allocator, .undefined);
                }
            } else {
                // b. Else,
                // i. For each element key of keys, do
                for (keys.items) |key| {
                    // 1. Let value be Completion(Get(paddingOption, key)).
                    const value = padding_option.?.get(agent, key) catch |err| {
                        // 2. IfAbruptCloseIterators(value, iters).
                        return types.Iterator.closeAll(
                            agent,
                            iters.items,
                            @as(Agent.Error!Value, err),
                        );
                    };

                    // 3. Append value to padding.
                    try padding.append(agent.gc_allocator, value);
                }
            }
        }

        // 15. Let finishResults be a new Abstract Closure with parameters (results) that captures
        //     keys and iterCount and performs the following steps when called:
        //     a. Let obj be OrdinaryObjectCreate(null).
        //     b. For each integer i such that 0 ≤ i < iterCount, in ascending order, do
        //         i. Perform ! CreateDataPropertyOrThrow(obj, keys[i], results[i]).
        //     c. Return obj.
        // 16. Return IteratorZip(iters, mode, padding, finishResults).
        return iteratorZip(
            agent,
            try iters.toOwnedSlice(agent.gc_allocator),
            mode,
            try padding.toOwnedSlice(agent.gc_allocator),
            .{ .object = try keys.toOwnedSlice(agent.gc_allocator) },
        );
    }

    const ZipMode = enum { shortest, longest, strict };
    const FinishResults = union(enum) {
        array,
        object: []PropertyKey,
    };

    fn removeFromOpenIters(open_iters: *std.ArrayList(types.Iterator), iter: types.Iterator) void {
        for (open_iters.items, 0..) |open_iter, idx| {
            if (open_iter.iterator == iter.iterator) {
                _ = open_iters.orderedRemove(idx);
                break;
            }
        }
    }

    /// 27.1.3.4.1 IteratorZip ( iters, mode, padding, finishResults )
    /// https://tc39.es/ecma262/#sec-iteratorzip
    fn iteratorZip(
        agent: *Agent,
        iters: []types.Iterator,
        mode: ZipMode,
        padding: []Value,
        finish_results: FinishResults,
    ) Agent.Error!Value {
        const realm = agent.currentRealm();

        // 1. Let iterCount be the number of elements in iters.
        // 2. Let openIters be a copy of iters.
        var open_iters: std.ArrayList(types.Iterator) = .empty;
        try open_iters.appendSlice(agent.gc_allocator, iters);

        const Captures = struct {
            iters: []types.Iterator,
            open_iters: std.ArrayList(types.Iterator),
            mode: ZipMode,
            padding: []Value,
            finish_results: FinishResults,
        };
        const captures = try agent.gc_allocator.create(Captures);
        captures.* = .{
            .iters = iters,
            .open_iters = open_iters,
            .mode = mode,
            .padding = padding,
            .finish_results = finish_results,
        };

        // 3. Let closure be a new Abstract Closure with no parameters that captures iters,
        //    iterCount, openIters, mode, padding, and finishResults and performs the following
        //    steps when called:
        const closure = struct {
            fn func(agent_: *Agent, iterator_helper: *builtins.IteratorHelper) Agent.Error!?Value {
                const captures_ = iterator_helper.fields.state.capturesAs(Captures);
                const iters_ = captures_.iters;
                const open_iters_ = &captures_.open_iters;
                const mode_ = captures_.mode;
                const padding_ = captures_.padding;
                const finish_results_ = captures_.finish_results;
                const iter_count = iters_.len;

                // a. If iterCount = 0, return ReturnCompletion(undefined).
                if (iter_count == 0) return null;

                // b. Repeat,
                // i. Let results be a new empty List.
                var results: std.ArrayList(Value) = .empty;
                defer results.deinit(agent_.gc_allocator);

                // ii. Assert: openIters is not empty.
                std.debug.assert(open_iters_.items.len > 0);

                // iii. For each integer i such that 0 ≤ i < iterCount, in ascending order, do
                for (0..iter_count) |i| {
                    var result: Value = undefined;

                    // 1. Let iter be iters[i].
                    var iter = iters_[i];

                    // 2. If iter is null, then
                    if (iter.done) {
                        // a. Assert: mode is "longest".
                        std.debug.assert(mode_ == .longest);

                        // b. Let result be padding[i].
                        result = padding_[i];
                    } else {
                        // 3. Else,
                        // a. Let result be Completion(IteratorStepValue(iter)).
                        const maybe_result = iter.stepValue(agent_) catch |err| {
                            // b. If result is an abrupt completion, then
                            // i. Remove iter from openIters.
                            removeFromOpenIters(open_iters_, iter);
                            // ii. Return ? IteratorCloseAll(openIters, result).
                            return types.Iterator.closeAll(
                                agent_,
                                open_iters_.items,
                                @as(Agent.Error!?Value, err),
                            );
                        };

                        // c. Set result to ! result.
                        // d. If result is done, then
                        if (maybe_result) |value| {
                            result = value;
                        } else {
                            // i. Remove iter from openIters.
                            removeFromOpenIters(open_iters_, iter);

                            switch (mode_) {
                                // ii. If mode is "shortest", then
                                .shortest => {
                                    // 1. Return ? IteratorCloseAll(openIters, ReturnCompletion(
                                    //    undefined)).
                                    iterator_helper.fields = .completed;
                                    return types.Iterator.closeAll(
                                        agent_,
                                        open_iters_.items,
                                        @as(Agent.Error!?Value, null),
                                    );
                                },
                                // iii. Else if mode is "strict", then
                                .strict => {
                                    // 1. If i ≠ 0, then
                                    if (i != 0) {
                                        // a. Return ? IteratorCloseAll(openIters, ThrowCompletion(a
                                        //    newly created TypeError object)).
                                        const @"error" = agent_.throwException(
                                            .type_error,
                                            "Iterators finished at different lengths in strict mode",
                                            .{},
                                        );
                                        return types.Iterator.closeAll(
                                            agent_,
                                            open_iters_.items,
                                            @as(Agent.Error!?Value, @"error"),
                                        );
                                    }

                                    // 2. For each integer k such that 1 ≤ k < iterCount, in
                                    //    ascending order, do
                                    for (1..iter_count) |k| {
                                        // a. Assert: iters[k] is not null.
                                        std.debug.assert(!iters_[k].done);

                                        // b. Let open be Completion(IteratorStep(iters[k])).
                                        const open = iters_[k].step(agent_) catch |err| {
                                            // c. If open is an abrupt completion, then
                                            // i. Remove iters[k] from openIters.
                                            removeFromOpenIters(open_iters_, iters_[k]);

                                            // ii. Return ? IteratorCloseAll(openIters, open).
                                            return types.Iterator.closeAll(
                                                agent_,
                                                open_iters_.items,
                                                @as(Agent.Error!?Value, err),
                                            );
                                        };

                                        // d. Set open to ! open.
                                        // e. If open is done, then
                                        if (open == null) {
                                            // i. Remove iters[k] from openIters.
                                            removeFromOpenIters(open_iters_, iters_[k]);
                                        } else {
                                            // f. Else,
                                            // i. Return ? IteratorCloseAll(openIters,
                                            //    ThrowCompletion(a newly created TypeError
                                            //    object)).
                                            const @"error" = agent_.throwException(
                                                .type_error,
                                                "Iterators finished at different lengths in strict mode",
                                                .{},
                                            );
                                            return types.Iterator.closeAll(
                                                agent_,
                                                open_iters_.items,
                                                @as(Agent.Error!?Value, @"error"),
                                            );
                                        }
                                    }

                                    // 3. Return ReturnCompletion(undefined).
                                    return null;
                                },
                                // iv. Else,
                                //     1. Assert: mode is "longest".
                                .longest => {
                                    // 2. If openIters is empty, return ReturnCompletion(undefined).
                                    if (open_iters_.items.len == 0) return null;

                                    // 3. Set iters[i] to null.
                                    // (We mark done flag, which we check above)

                                    // 4. Set result to padding[i].
                                    result = padding_[i];
                                },
                            }
                        }
                    }

                    // 4. Append result to results.
                    try results.append(agent_.gc_allocator, result);
                }

                // iv. Set results to finishResults(results).
                const final_result = switch (finish_results_) {
                    // Iterator.zip
                    .array => blk: {
                        // 15.a. Return CreateArrayFromList(results).
                        const array = try createArrayFromList(agent_, results.items);
                        break :blk Value.from(&array.object);
                    },
                    // Iterator.zipKeyed
                    .object => |keys| blk: {
                        // 15.a. Let obj be OrdinaryObjectCreate(null).
                        const obj = try ordinaryObjectCreate(agent_, null);

                        // 15.b. For each integer i such that 0 ≤ i < iterCount, in ascending order,
                        //       do
                        for (0..iter_count) |i| {
                            // 15.b.i. Perform ! CreateDataPropertyOrThrow(obj, keys[i], results[i]).
                            try obj.createDataPropertyOrThrow(agent_, keys[i], results.items[i]);
                        }

                        // 15.c. Return obj.
                        break :blk Value.from(obj);
                    },
                };

                // v. Let completion be Completion(Yield(results)).
                // vi. IfAbruptCloseIterators(completion, openIters).
                return final_result;
            }
        }.func;

        const abruptClosure = struct {
            fn func(agent_: *Agent, iterator_helper: *builtins.IteratorHelper) Agent.Error!void {
                // 3.b.vi.
                const captures_ = iterator_helper.fields.state.capturesAs(Captures);
                const open_iters_ = captures_.open_iters;
                _ = try types.Iterator.closeAll(
                    agent_,
                    open_iters_.items,
                    @as(Agent.Error!void, {}),
                );
            }
        }.func;

        // 4. Let gen be CreateIteratorFromClosure(closure, "Iterator Helper",
        //    %IteratorHelperPrototype%, « [[UnderlyingIterators]] »).
        const gen = try builtins.IteratorHelper.create(agent, .{
            .prototype = try realm.intrinsic(.iterator_helper_prototype),
            .fields = .{
                .state = .{
                    // 5. Set gen.[[UnderlyingIterators]] to openIters.
                    .underlying_iterators = open_iters.items,

                    .closure = closure,
                    .abruptClosure = abruptClosure,
                    .captures = captures,
                },
            },
        });

        // 6. Return gen.
        return Value.from(&gen.object);
    }
};

/// 27.1.3.3 Properties of the Iterator Prototype Object
/// https://tc39.es/ecma262/#sec-%iterator.prototype%-object
pub const prototype = struct {
    pub fn create(agent: *Agent, realm: *Realm) std.mem.Allocator.Error!*Object {
        return ordinaryObjectCreate(agent, try realm.intrinsic(.object_prototype));
    }

    pub fn init(agent: *Agent, realm: *Realm, object: *Object) std.mem.Allocator.Error!void {
        try object.defineBuiltinFunction(agent, "chunks", chunks, 1, realm);
        try object.defineBuiltinFunction(agent, "drop", drop, 1, realm);
        try object.defineBuiltinFunction(agent, "every", every, 1, realm);
        try object.defineBuiltinFunction(agent, "filter", filter, 1, realm);
        try object.defineBuiltinFunction(agent, "find", find, 1, realm);
        try object.defineBuiltinFunction(agent, "flatMap", flatMap, 1, realm);
        try object.defineBuiltinFunction(agent, "forEach", forEach, 1, realm);
        try object.defineBuiltinFunction(agent, "includes", includes, 1, realm);
        try object.defineBuiltinFunction(agent, "join", join, 1, realm);
        try object.defineBuiltinFunction(agent, "map", map, 1, realm);
        try object.defineBuiltinFunction(agent, "reduce", reduce, 1, realm);
        try object.defineBuiltinFunction(agent, "some", some, 1, realm);
        try object.defineBuiltinFunction(agent, "take", take, 1, realm);
        try object.defineBuiltinFunction(agent, "toArray", toArray, 0, realm);
        try object.defineBuiltinFunction(agent, "windows", windows, 1, realm);
        try object.defineBuiltinFunction(agent, "Symbol.dispose", @"Symbol.dispose", 0, realm);
        try object.defineBuiltinFunction(agent, "Symbol.iterator", @"Symbol.iterator", 0, realm);

        // 27.1.3.3.1 Iterator.prototype.constructor
        // https://tc39.es/ecma262/#sec-iterator.prototype.constructor
        try object.defineBuiltinAccessor(
            agent,
            "constructor",
            struct {
                /// 27.1.3.3.1.1 get Iterator.prototype.constructor
                /// https://tc39.es/ecma262/#sec-get-iterator.prototype.constructor
                fn get(agent_: *Agent, _: Value, _: Arguments) Agent.Error!Value {
                    const realm_ = agent_.currentRealm();

                    // 1. Return %Iterator%.
                    return Value.from(try realm_.intrinsic(.iterator));
                }
            }.get,
            struct {
                /// 27.1.3.3.1.2 set Iterator.prototype.constructor
                /// https://tc39.es/ecma262/#sec-set-iterator.prototype.constructor
                fn set(agent_: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
                    const realm_ = agent_.currentRealm();
                    const value = arguments.get(0);

                    // 1. Perform ? SetterThatIgnoresPrototypeProperties(this value,
                    //    %Iterator.prototype%, "constructor", v).
                    try this_value.setterThatIgnoresPrototypeProperties(
                        agent_,
                        try realm_.intrinsic(.iterator_prototype),
                        PropertyKey.from("constructor"),
                        value,
                    );

                    // 2. Return undefined.
                    return .undefined;
                }
            }.set,
            realm,
        );

        // 27.1.3.3.15 Iterator.prototype [ %Symbol.toStringTag% ]
        // https://tc39.es/ecma262/#sec-iterator.prototype-%symbol.tostringtag%
        try object.defineBuiltinAccessor(
            agent,
            "Symbol.toStringTag",
            struct {
                /// 27.1.3.3.15.1 get Iterator.prototype [ %Symbol.toStringTag% ]
                /// https://tc39.es/ecma262/#sec-get-iterator.prototype-%symbol.tostringtag%
                fn get(_: *Agent, _: Value, _: Arguments) Agent.Error!Value {
                    // 1. Return "Iterator".
                    return Value.from("Iterator");
                }
            }.get,
            struct {
                /// 27.1.3.3.15.2 set Iterator.prototype [ %Symbol.toStringTag% ]
                /// https://tc39.es/ecma262/#sec-set-iterator.prototype-%symbol.tostringtag%
                fn set(agent_: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
                    const realm_ = agent_.currentRealm();
                    const value = arguments.get(0);

                    // 1. Perform ? SetterThatIgnoresPrototypeProperties(this value,
                    //    %Iterator.prototype%, %Symbol.toStringTag%, v).
                    try this_value.setterThatIgnoresPrototypeProperties(
                        agent_,
                        try realm_.intrinsic(.iterator_prototype),
                        PropertyKey.from(agent_.well_known_symbols.to_string_tag),
                        value,
                    );

                    // 2. Return undefined.
                    return .undefined;
                }
            }.set,
            realm,
        );
    }

    /// 1 Iterator.prototype.chunks ( chunkSize )
    /// https://tc39.es/proposal-iterator-chunking/#sec-iterator.prototype.chunks
    fn chunks(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const realm = agent.currentRealm();
        const chunk_size_value = arguments.get(0);

        // 1. Let O be the this value.
        // 2. If O is not an Object, throw a TypeError exception.
        if (!this_value.isObject()) {
            return agent.throwException(.type_error, "{f} is not an Object", .{this_value});
        }
        const obj = this_value.asObject();

        // 3. Let iterated be the Iterator Record { [[Iterator]]: O, [[NextMethod]]: undefined,
        //    [[Done]]: false }.
        var iterated: types.Iterator = .{
            .iterator = obj,
            .next_method = .undefined,
            .done = false,
        };

        // 4. If chunkSize is not an integral Number, then
        if (!chunk_size_value.isNumber() or !chunk_size_value.asNumber().isIntegral()) {
            // a. Let error be ThrowCompletion(a newly created TypeError object).
            const @"error" = agent.throwException(
                .type_error,
                "Chunk size must be an integral number",
                .{},
            );

            // b. Return ? IteratorClose(iterated, error).
            return iterated.close(agent, @as(Agent.Error!Value, @"error"));
        }

        // 5. If chunkSize is not in the inclusive interval from 1𝔽 to 𝔽(2**32 - 1), then
        const chunk_size_float = chunk_size_value.asNumber().asFloat();
        if (chunk_size_float < 1 or chunk_size_float > std.math.maxInt(u32)) {
            // a. Let error be ThrowCompletion(a newly created RangeError object).
            const @"error" = agent.throwException(
                .range_error,
                "Chunk size must be in the inclusive interval from 1 to 2^32 - 1",
                .{},
            );

            // b. Return ? IteratorClose(iterated, error).
            return iterated.close(agent, @as(Agent.Error!Value, @"error"));
        }
        const chunk_size: u32 = @intFromFloat(chunk_size_float);

        // 6. Set iterated to ? GetIteratorDirect(O).
        iterated = try getIteratorDirect(agent, obj);

        const iterated_list = try agent.gc_allocator.alloc(types.Iterator, 1);
        iterated_list[0] = iterated;

        const Captures = struct {
            iterated: *types.Iterator,
            chunk_size: u32,
            buffer: std.ArrayList(Value),
        };
        const captures = try agent.gc_allocator.create(Captures);
        captures.* = .{
            .iterated = &iterated_list[0],
            .chunk_size = chunk_size,
            .buffer = .empty,
        };

        // 7. Let closure be a new Abstract Closure with no parameters that captures iterated and
        //    chunkSize and performs the following steps when called:
        const closure = struct {
            fn func(agent_: *Agent, iterator_helper: *builtins.IteratorHelper) Agent.Error!?Value {
                const captures_ = iterator_helper.fields.state.capturesAs(Captures);
                const iterated_ = captures_.iterated;
                const chunk_size_ = captures_.chunk_size;
                const buffer = &captures_.buffer;

                // a. Let buffer be a new empty List.
                // b. Repeat,
                while (true) {
                    // i. Let value be ? IteratorStepValue(iterated).
                    // ii. If value is done, then
                    const value = try iterated_.stepValue(agent_) orelse {
                        // 1. If buffer is not empty, then
                        if (buffer.items.len != 0) {
                            defer buffer.clearAndFree(agent_.gc_allocator);

                            // a. Perform Completion(Yield(CreateArrayFromList(buffer))).
                            const array = try createArrayFromList(agent_, buffer.items);
                            return Value.from(&array.object);
                        }

                        // 2. Return ReturnCompletion(undefined).
                        return null;
                    };

                    // iii. Append value to buffer.
                    try buffer.append(agent_.gc_allocator, value);

                    // iv. If the number of elements in buffer is ℝ(chunkSize), then
                    if (buffer.items.len == chunk_size_) {
                        defer buffer.clearRetainingCapacity();

                        // 1. Let completion be Completion(Yield(CreateArrayFromList(buffer))).
                        const array = try createArrayFromList(agent_, buffer.items);

                        // 2. IfAbruptCloseIterator(completion, iterated).
                        // 3. Set buffer to a new empty List.
                        return Value.from(&array.object);
                    }
                }
            }
        }.func;

        // 8. Let result be CreateIteratorFromClosure(closure, "Iterator Helper",
        //    %IteratorHelperPrototype%, « [[UnderlyingIterators]] »).
        const result = try builtins.IteratorHelper.create(agent, .{
            .prototype = try realm.intrinsic(.iterator_helper_prototype),
            .fields = .{
                .state = .{
                    // 9. Set result.[[UnderlyingIterators]] to « iterated ».
                    .underlying_iterators = iterated_list,

                    .closure = closure,
                    .captures = captures,
                },
            },
        });

        // 10. Return result.
        return Value.from(&result.object);
    }

    /// 27.1.3.3.2 Iterator.prototype.drop ( limit )
    /// https://tc39.es/ecma262/#sec-iterator.prototype.drop
    fn drop(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const realm = agent.currentRealm();
        const limit = arguments.get(0);

        // 1. Let obj be the this value.
        // 2. If obj is not an Object, throw a TypeError exception.
        if (!this_value.isObject()) {
            return agent.throwException(.type_error, "{f} is not an Object", .{this_value});
        }
        const obj = this_value.asObject();

        // 3. Let iterated be the Iterator Record { [[Iterator]]: obj, [[NextMethod]]: undefined,
        //    [[Done]]: false }.
        var iterated: types.Iterator = .{
            .iterator = obj,
            .next_method = .undefined,
            .done = false,
        };

        // 4. Let numberLimit be Completion(ToNumber(limit)).
        const number_limit = limit.toNumber(agent) catch |err| {
            // 5. IfAbruptCloseIterator(numberLimit, iterated).
            return iterated.close(agent, @as(Agent.Error!Value, err));
        };

        // 6. If numberLimit is NaN, then
        if (number_limit.isNan()) {
            // a. Let error be ThrowCompletion(a newly created RangeError object).
            const @"error" = agent.throwException(
                .range_error,
                "Limit must not be NaN",
                .{},
            );

            // b. Return ? IteratorClose(iterated, error).
            return iterated.close(agent, @as(Agent.Error!Value, @"error"));
        }

        // 7. If numberLimit is finite and numberLimit > 𝔽(2**53 - 1), then
        if (number_limit.isFinite() and number_limit.asFloat() > std.math.maxInt(u53)) {
            // a. Let error be ThrowCompletion(a newly created RangeError object).
            const @"error" = agent.throwException(
                .range_error,
                "Limit must not exceed 2^53-1",
                .{},
            );

            // b. Return ? IteratorClose(iterated, error).
            return iterated.close(agent, @as(Agent.Error!Value, @"error"));
        }

        // 8. Let intLimit be ! ToIntegerOrInfinity(numberLimit).
        const int_limit = Value.from(number_limit).toIntegerOrInfinity(agent) catch unreachable;

        // 9. If intLimit < 0, then
        if (int_limit < 0) {
            // a. Let error be ThrowCompletion(a newly created RangeError object).
            const @"error" = agent.throwException(
                .range_error,
                "Limit must be a positive number",
                .{},
            );

            // b. Return ? IteratorClose(iterated, error).
            return iterated.close(agent, @as(Agent.Error!Value, @"error"));
        }

        // 10. Set iterated to ? GetIteratorDirect(obj).
        iterated = try getIteratorDirect(agent, obj);

        const iterated_list = try agent.gc_allocator.alloc(types.Iterator, 1);
        iterated_list[0] = iterated;

        const Captures = struct {
            iterated: *types.Iterator,
            int_limit: f64,
        };
        const captures = try agent.gc_allocator.create(Captures);
        captures.* = .{
            .iterated = &iterated_list[0],
            .int_limit = int_limit,
        };

        // 11. Let closure be a new Abstract Closure with no parameters that captures iterated and
        //     intLimit and performs the following steps when called:
        const closure = struct {
            fn func(agent_: *Agent, iterator_helper: *builtins.IteratorHelper) Agent.Error!?Value {
                const captures_ = iterator_helper.fields.state.capturesAs(Captures);
                const iterated_ = captures_.iterated;

                // a. Let remaining be 𝔽(intLimit).
                const remaining = &captures_.int_limit;

                // b. Repeat, while remaining > +0𝔽,
                while (remaining.* > 0) {
                    // i. Set remaining to remaining - 1𝔽.
                    remaining.* -= 1;

                    // ii. Let next be ? IteratorStep(iterated).
                    _ = try iterated_.step(agent_) orelse {
                        // iii. If next is done, return ReturnCompletion(undefined).
                        return null;
                    };
                }

                // c. Repeat,

                // i. Let value be ? IteratorStepValue(iterated).
                // ii. If value is done, return ReturnCompletion(undefined).
                const value = (try iterated_.stepValue(agent_)) orelse return null;

                // iii. Let completion be Completion(Yield(value)).
                // iv. IfAbruptCloseIterator(completion, iterated).
                return value;
            }
        }.func;

        // 12. Let result be CreateIteratorFromClosure(closure, "Iterator Helper",
        //     %IteratorHelperPrototype%, « [[UnderlyingIterators]] »).
        const result = try builtins.IteratorHelper.create(agent, .{
            .prototype = try realm.intrinsic(.iterator_helper_prototype),
            .fields = .{
                .state = .{
                    // 13. Set result.[[UnderlyingIterators]] to « iterated ».
                    .underlying_iterators = iterated_list,

                    .closure = closure,
                    .captures = captures,
                },
            },
        });

        // 14. Return result.
        return Value.from(&result.object);
    }

    /// 27.1.3.3.3 Iterator.prototype.every ( predicate )
    /// https://tc39.es/ecma262/#sec-iterator.prototype.every
    fn every(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const predicate_value = arguments.get(0);

        // 1. Let obj be the this value.
        // 2. If obj is not an Object, throw a TypeError exception.
        if (!this_value.isObject()) {
            return agent.throwException(.type_error, "{f} is not an Object", .{this_value});
        }
        const obj = this_value.asObject();

        // 3. Let iterated be the Iterator Record { [[Iterator]]: obj, [[NextMethod]]: undefined,
        //    [[Done]]: false }.
        var iterated: types.Iterator = .{
            .iterator = obj,
            .next_method = .undefined,
            .done = false,
        };

        // 4. If IsCallable(predicate) is false, then
        if (!predicate_value.isCallable()) {
            // a. Let error be ThrowCompletion(a newly created TypeError object).
            const @"error" = agent.throwException(
                .type_error,
                "{f} is not callable",
                .{predicate_value},
            );

            // b. Return ? IteratorClose(iterated, error).
            return iterated.close(agent, @as(Agent.Error!Value, @"error"));
        }
        const predicate = predicate_value.asObject();

        // 5. Set iterated to ? GetIteratorDirect(obj).
        iterated = try getIteratorDirect(agent, obj);

        // 6. Let counter be +0𝔽.
        var counter: f64 = 0;

        // 7. Repeat,
        //     a. Let value be ? IteratorStepValue(iterated).
        //     b. If value is done, return true.
        while (try iterated.stepValue(agent)) |value| {
            // c. Let result be Completion(Call(predicate, undefined, « value, counter »)).
            const result = predicate.call(
                agent,
                .undefined,
                &.{ value, Value.from(counter) },
            ) catch |err| {
                // d. IfAbruptCloseIterator(result, iterated).
                return iterated.close(agent, @as(Agent.Error!Value, err));
            };

            // e. If ToBoolean(result) is false, return ? IteratorClose(iterated, NormalCompletion(
            //    false)).
            if (!result.toBoolean()) {
                return try iterated.close(agent, @as(Agent.Error!Value, .false));
            }

            // f. NOTE: The following step will not change counter once it reaches 2**53𝔽.
            // g. Set counter to counter + 1𝔽.
            counter += 1;
        }
        return .true;
    }

    /// 27.1.3.3.4 Iterator.prototype.filter ( predicate )
    /// https://tc39.es/ecma262/#sec-iterator.prototype.filter
    fn filter(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const realm = agent.currentRealm();
        const predicate_value = arguments.get(0);

        // 1. Let obj be the this value.
        // 2. If obj is not an Object, throw a TypeError exception.
        if (!this_value.isObject()) {
            return agent.throwException(.type_error, "{f} is not an Object", .{this_value});
        }
        const obj = this_value.asObject();

        // 3. Let iterated be the Iterator Record { [[Iterator]]: obj, [[NextMethod]]: undefined,
        //    [[Done]]: false }.
        var iterated: types.Iterator = .{
            .iterator = obj,
            .next_method = .undefined,
            .done = false,
        };

        // 4. If IsCallable(predicate) is false, then
        if (!predicate_value.isCallable()) {
            // a. Let error be ThrowCompletion(a newly created TypeError object).
            const @"error" = agent.throwException(
                .type_error,
                "{f} is not callable",
                .{predicate_value},
            );

            // b. Return ? IteratorClose(iterated, error).
            return iterated.close(agent, @as(Agent.Error!Value, @"error"));
        }
        const predicate = predicate_value.asObject();

        // 5. Set iterated to ? GetIteratorDirect(obj).
        iterated = try getIteratorDirect(agent, obj);

        const iterated_list = try agent.gc_allocator.alloc(types.Iterator, 1);
        iterated_list[0] = iterated;

        const Captures = struct {
            iterated: *types.Iterator,
            predicate: *Object,
            counter: f64,
        };
        const captures = try agent.gc_allocator.create(Captures);
        captures.* = .{
            .iterated = &iterated_list[0],
            .predicate = predicate,
            .counter = 0,
        };

        // 6. Let closure be a new Abstract Closure with no parameters that captures iterated and
        //    predicate and performs the following steps when called:
        const closure = struct {
            fn func(agent_: *Agent, iterator_helper: *builtins.IteratorHelper) Agent.Error!?Value {
                const captures_ = iterator_helper.fields.state.capturesAs(Captures);
                const iterated_ = captures_.iterated;
                const predicate_ = captures_.predicate;

                // a. Let counter be +0𝔽.
                const counter = &captures_.counter;

                // b. Repeat,
                //     i. Let value be ? IteratorStepValue(iterated).
                //     ii. If value is done, return ReturnCompletion(undefined).
                while (try iterated_.stepValue(agent_)) |value| {
                    // iii. Let selected be Completion(Call(predicate, undefined, « value,
                    //      counter »)).
                    const selected = predicate_.call(
                        agent_,
                        .undefined,
                        &.{ value, Value.from(counter.*) },
                    ) catch |err| {
                        // iv. IfAbruptCloseIterator(selected, iterated).
                        return iterated_.close(agent_, @as(Agent.Error!?Value, err));
                    };

                    // vi. NOTE: The following step will not change counter once it reaches 2**53𝔽.
                    // vii. Set counter to counter + 1𝔽.
                    defer counter.* += 1;

                    // v. If ToBoolean(selected) is true, then
                    if (selected.toBoolean()) {
                        // 1. Let completion be Completion(Yield(value)).
                        // 2. IfAbruptCloseIterator(completion, iterated).
                        return value;
                    }
                }
                return null;
            }
        }.func;

        // 7. Let result be CreateIteratorFromClosure(closure, "Iterator Helper",
        //    %IteratorHelperPrototype%, « [[UnderlyingIterators]] »).
        const result = try builtins.IteratorHelper.create(agent, .{
            .prototype = try realm.intrinsic(.iterator_helper_prototype),
            .fields = .{
                .state = .{
                    // 8. Set result.[[UnderlyingIterators]] to « iterated ».
                    .underlying_iterators = iterated_list,

                    .closure = closure,
                    .captures = captures,
                },
            },
        });

        // 9. Return result.
        return Value.from(&result.object);
    }

    /// 27.1.3.3.5 Iterator.prototype.find ( predicate )
    /// https://tc39.es/ecma262/#sec-iterator.prototype.find
    fn find(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const predicate_value = arguments.get(0);

        // 1. Let obj be the this value.
        // 2. If obj is not an Object, throw a TypeError exception.
        if (!this_value.isObject()) {
            return agent.throwException(.type_error, "{f} is not an Object", .{this_value});
        }
        const obj = this_value.asObject();

        // 3. Let iterated be the Iterator Record { [[Iterator]]: obj, [[NextMethod]]: undefined,
        //    [[Done]]: false }.
        var iterated: types.Iterator = .{
            .iterator = obj,
            .next_method = .undefined,
            .done = false,
        };

        // 4. If IsCallable(predicate) is false, then
        if (!predicate_value.isCallable()) {
            // a. Let error be ThrowCompletion(a newly created TypeError object).
            const @"error" = agent.throwException(
                .type_error,
                "{f} is not callable",
                .{predicate_value},
            );

            // b. Return ? IteratorClose(iterated, error).
            return iterated.close(agent, @as(Agent.Error!Value, @"error"));
        }
        const predicate = predicate_value.asObject();

        // 5. Set iterated to ? GetIteratorDirect(obj).
        iterated = try getIteratorDirect(agent, obj);

        // 6. Let counter be +0𝔽.
        var counter: f64 = 0;

        // 7. Repeat,
        //     a. Let value be ? IteratorStepValue(iterated).
        //     b. If value is done, return undefined.
        while (try iterated.stepValue(agent)) |value| {
            // c. Let result be Completion(Call(predicate, undefined, « value, counter »)).
            const result = predicate.call(
                agent,
                .undefined,
                &.{ value, Value.from(counter) },
            ) catch |err| {
                // d. IfAbruptCloseIterator(result, iterated).
                return iterated.close(agent, @as(Agent.Error!Value, err));
            };

            // e. If ToBoolean(result) is true, return ? IteratorClose(iterated, NormalCompletion(
            //    value)).
            if (result.toBoolean()) {
                return iterated.close(agent, @as(Agent.Error!Value, value));
            }

            // f. NOTE: The following step will not change counter once it reaches 2**53𝔽.
            // g. Set counter to counter + 1𝔽.
            counter += 1;
        }
        return .undefined;
    }

    /// 1 Iterator.prototype.includes ( searchElement [ , skippedElements ] )
    /// https://tc39.es/proposal-iterator-includes/#sec-iterator.prototype.includes
    fn includes(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const search_element = arguments.get(0);
        const skipped_elements = arguments.get(1);

        // 1. Let obj be the this value.
        // 2. If obj is not an Object, throw a TypeError exception.
        if (!this_value.isObject()) {
            return agent.throwException(.type_error, "{f} is not an Object", .{this_value});
        }
        const obj = this_value.asObject();

        // 3. Let iterated be the Iterator Record { [[Iterator]]: obj, [[NextMethod]]: undefined,
        //    [[Done]]: false }.
        var iterated: types.Iterator = .{
            .iterator = obj,
            .next_method = .undefined,
            .done = false,
        };

        const to_skip: f64 = blk: {
            // 4. If skippedElements is undefined, then
            //     a. Let toSkip be +0𝔽.
            if (skipped_elements.isUndefined()) break :blk 0;

            // 5. Else,
            //     a. If skippedElements is not one of +∞𝔽, -∞𝔽, or an integral Number, then
            if (skipped_elements.isNumber() and
                (skipped_elements.asNumber().isPositiveInf() or
                    skipped_elements.asNumber().isNegativeInf() or
                    skipped_elements.asNumber().isIntegral()))
            {
                break :blk skipped_elements.asNumber().asFloat();
            }

            // i. Let error be ThrowCompletion(a newly created TypeError object).
            const @"error" = agent.throwException(
                .type_error,
                "Skipped elements must be an integral number",
                .{},
            );

            // ii. Return ? IteratorClose(iterated, error).
            return iterated.close(agent, @as(Agent.Error!Value, @"error"));

            // b. Let toSkip be skippedElements.
        };

        // 6. If toSkip < -0𝔽, then
        if (to_skip < 0) {
            // a. Let error be ThrowCompletion(a newly created RangeError object).
            const @"error" = agent.throwException(
                .range_error,
                "Skipped elements must not be negative",
                .{},
            );

            // b. Return ? IteratorClose(iterated, error).
            return iterated.close(agent, @as(Agent.Error!Value, @"error"));
        }

        // 7. If toSkip is finite and toSkip > 𝔽(2**53 - 1), then
        if (std.math.isFinite(to_skip) and to_skip > std.math.maxInt(u53)) {
            // a. Let error be ThrowCompletion(a newly created RangeError object).
            const @"error" = agent.throwException(
                .range_error,
                "Skipped elements must not exceed 2^53 - 1",
                .{},
            );

            // b. Return ? IteratorClose(iterated, error).
            return iterated.close(agent, @as(Agent.Error!Value, @"error"));
        }

        // 8. Let skipped be +0𝔽.
        var skipped: f64 = 0;

        // 9. Set iterated to ? GetIteratorDirect(obj).
        iterated = try getIteratorDirect(agent, obj);

        // 10. Repeat,
        //     a. Let value be ? IteratorStepValue(iterated).
        //     b. If value is done, return false.
        while (try iterated.stepValue(agent)) |value| {
            // c. If skipped < toSkip, then
            if (skipped < to_skip) {
                // i. Set skipped to skipped + 1𝔽.
                skipped += 1;
            }
            // d. Else if SameValueZero(value, searchElement) is true, then
            else if (sameValueZero(value, search_element)) {
                // i. Return ? IteratorClose(iterated, NormalCompletion(true)).
                return iterated.close(agent, @as(Agent.Error!Value, .true));
            }
        }
        return .false;
    }

    /// 1 Iterator.prototype.join ( separator )
    /// https://tc39.es/proposal-iterator-join/#sec-iterator.prototype.join
    fn join(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const separator = arguments.get(0);

        // 1. Let obj be the this value.
        // 2. If obj is not an Object, throw a TypeError exception.
        if (!this_value.isObject()) {
            return agent.throwException(.type_error, "{f} is not an Object", .{this_value});
        }
        const obj = this_value.asObject();

        // 3. Let iterated be the Iterator Record { [[Iterator]]: obj, [[NextMethod]]: undefined,
        //    [[Done]]: false }.
        var iterated: types.Iterator = .{
            .iterator = obj,
            .next_method = .undefined,
            .done = false,
        };

        // 4. If separator is undefined, then
        const separator_string: String.Builder.Segment = if (separator.isUndefined())
            // a. Let sep be ",".
            .{ .char = ',' }
        else blk: {
            // 5. Else,
            // a. Let sep be Completion(ToString(separator)).
            const string = separator.toString(agent) catch |err| {
                // b. IfAbruptCloseIterator(sep, iterated).
                return iterated.close(agent, @as(Agent.Error!Value, err));
            };
            break :blk .{ .string = string };
        };

        // 6. Set iterated to ? GetIteratorDirect(obj).
        iterated = try getIteratorDirect(agent, obj);

        // 7. Let result be the empty String.
        var result: String.Builder = .empty;
        defer result.deinit(agent.gc_allocator);

        // 8. Let first be true.
        var first = true;

        // 9. Repeat,
        //     a. Let value be ? IteratorStepValue(iterated).
        //     b. If value is done, return result.
        while (try iterated.stepValue(agent)) |value| {
            // c. If first is true, then
            if (first) {
                // i. Set first to false.
                first = false;
            } else {
                // d. Else,
                // i. Set result to the string-concatenation of result and sep.
                try result.appendSegment(agent.gc_allocator, separator_string);
            }

            // e. If value is neither undefined nor null, then
            if (!value.isUndefined() and !value.isNull()) {
                // i. Let valueString be Completion(ToString(value)).
                const value_string = value.toString(agent) catch |err| {
                    // ii. IfAbruptCloseIterator(valueString, iterated).
                    return iterated.close(agent, @as(Agent.Error!Value, err));
                };

                // iii. Set result to the string-concatenation of result and valueString.
                try result.appendString(agent.gc_allocator, value_string);
            }
        }
        return Value.from(try result.build(agent));
    }

    /// 27.1.3.3.6 Iterator.prototype.flatMap ( mapper )
    /// https://tc39.es/ecma262/#sec-iterator.prototype.flatmap
    fn flatMap(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const realm = agent.currentRealm();
        const mapper_value = arguments.get(0);

        // 1. Let obj be the this value.
        // 2. If obj is not an Object, throw a TypeError exception.
        if (!this_value.isObject()) {
            return agent.throwException(.type_error, "{f} is not an Object", .{this_value});
        }
        const obj = this_value.asObject();

        // 3. Let iterated be the Iterator Record { [[Iterator]]: obj, [[NextMethod]]: undefined,
        //    [[Done]]: false }.
        var iterated: types.Iterator = .{
            .iterator = obj,
            .next_method = .undefined,
            .done = false,
        };

        // 4. If IsCallable(mapper) is false, then
        if (!mapper_value.isCallable()) {
            // a. Let error be ThrowCompletion(a newly created TypeError object).
            const @"error" = agent.throwException(
                .type_error,
                "{f} is not callable",
                .{mapper_value},
            );

            // b. Return ? IteratorClose(iterated, error).
            return iterated.close(agent, @as(Agent.Error!Value, @"error"));
        }
        const mapper = mapper_value.asObject();

        // 5. Set iterated to ? GetIteratorDirect(obj).
        iterated = try getIteratorDirect(agent, obj);

        const iterated_list = try agent.gc_allocator.alloc(types.Iterator, 1);
        iterated_list[0] = iterated;

        const Captures = struct {
            iterated: *types.Iterator,
            mapper: *Object,
            counter: f64,
            inner_iterator: ?types.Iterator,
        };
        const captures = try agent.gc_allocator.create(Captures);
        captures.* = .{
            .iterated = &iterated_list[0],
            .mapper = mapper,
            .counter = 0,
            .inner_iterator = null,
        };

        // 6. Let closure be a new Abstract Closure with no parameters that captures iterated and
        //    mapper and performs the following steps when called:
        const closure = struct {
            fn func(agent_: *Agent, iterator_helper: *builtins.IteratorHelper) Agent.Error!?Value {
                const captures_ = iterator_helper.fields.state.capturesAs(Captures);
                const iterated_ = captures_.iterated;
                const mapper_ = captures_.mapper;
                const inner_iterator_ = &captures_.inner_iterator;

                // a. Let counter be +0𝔽.
                const counter_ = &captures_.counter;

                const State = enum { outer, inner };
                const state: State = if (inner_iterator_.* == null)
                    .outer
                else
                    .inner;

                // b. Repeat,
                loop: switch (state) {
                    .outer => {
                        // i. Let value be ? IteratorStepValue(iterated).
                        // ii. If value is done, return ReturnCompletion(undefined).
                        const value = (try iterated_.stepValue(agent_)) orelse return null;

                        // iii. Let mapped be Completion(Call(mapper, undefined, « value,
                        //      counter »)).
                        const mapped = mapper_.call(
                            agent_,
                            .undefined,
                            &.{ value, Value.from(counter_.*) },
                        ) catch |err| {
                            // iv. IfAbruptCloseIterator(mapped, iterated).
                            return iterated_.close(agent_, @as(Agent.Error!?Value, err));
                        };

                        // v. Let innerIterator be Completion(GetIteratorFlattenable(mapped,
                        //    reject-primitives)).
                        inner_iterator_.* = getIteratorFlattenable(
                            agent_,
                            mapped,
                            .reject_primitives,
                        ) catch |err| {
                            // vi. IfAbruptCloseIterator(innerIterator, iterated).
                            return iterated_.close(agent_, @as(Agent.Error!?Value, err));
                        };

                        continue :loop .inner;
                    },
                    .inner => {
                        // vii. Let innerAlive be true.
                        // viii. Repeat, while innerAlive is true,

                        // 1. Let innerValue be Completion(IteratorStepValue(innerIterator)).
                        const inner_value = inner_iterator_.*.?.stepValue(agent_) catch |err| {
                            // 2. IfAbruptCloseIterator(innerValue, iterated).
                            return iterated_.close(agent_, @as(Agent.Error!?Value, err));
                        };

                        // 3. If innerValue is done, then
                        //     a. Set innerAlive to false.
                        // 4. Else,
                        //     a. Let completion be Completion(Yield(innerValue)).
                        //     b. If completion is an abrupt completion, then
                        //         i. Let backupCompletion be Completion(IteratorClose(
                        //            innerIterator, completion)).
                        //         ii. IfAbruptCloseIterator(backupCompletion, iterated).
                        //         iii. Return ? IteratorClose(iterated, completion).
                        if (inner_value) |value| return value;

                        // ix. NOTE: The following step will not change counter once it reaches
                        //     2**53𝔽.
                        // x. Set counter to counter + 1𝔽.
                        counter_.* += 1;

                        continue :loop .outer;
                    },
                }
            }
        }.func;

        const abruptClosure = struct {
            fn func(agent_: *Agent, iterator_helper: *builtins.IteratorHelper) Agent.Error!void {
                // 6.b.viii.4.b.
                const captures_ = iterator_helper.fields.state.capturesAs(Captures);
                if (captures_.inner_iterator) |inner_iterator| {
                    inner_iterator.close(agent_, @as(Agent.Error!void, {})) catch |err| {
                        return captures_.iterated.close(agent_, @as(Agent.Error!void, err));
                    };
                }
                try captures_.iterated.close(agent_, @as(Agent.Error!void, {}));
            }
        }.func;

        // 7. Let result be CreateIteratorFromClosure(closure, "Iterator Helper",
        //    %IteratorHelperPrototype%, « [[UnderlyingIterators]] »).
        const result = try builtins.IteratorHelper.create(agent, .{
            .prototype = try realm.intrinsic(.iterator_helper_prototype),
            .fields = .{
                .state = .{
                    // 8. Set result.[[UnderlyingIterators]] to « iterated ».
                    .underlying_iterators = iterated_list,

                    .closure = closure,
                    .abruptClosure = abruptClosure,
                    .captures = captures,
                },
            },
        });

        // 9. Return result.
        return Value.from(&result.object);
    }

    /// 27.1.3.3.7 Iterator.prototype.forEach ( procedure )
    /// https://tc39.es/ecma262/#sec-iterator.prototype.foreach
    fn forEach(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const procedure_value = arguments.get(0);

        // 1. Let obj be the this value.
        // 2. If obj is not an Object, throw a TypeError exception.
        if (!this_value.isObject()) {
            return agent.throwException(.type_error, "{f} is not an Object", .{this_value});
        }
        const obj = this_value.asObject();

        // 3. Let iterated be the Iterator Record { [[Iterator]]: obj, [[NextMethod]]: undefined,
        //    [[Done]]: false }.
        var iterated: types.Iterator = .{
            .iterator = obj,
            .next_method = .undefined,
            .done = false,
        };

        // 4. If IsCallable(procedure) is false, then
        if (!procedure_value.isCallable()) {
            // a. Let error be ThrowCompletion(a newly created TypeError object).
            const @"error" = agent.throwException(
                .type_error,
                "{f} is not callable",
                .{procedure_value},
            );

            // b. Return ? IteratorClose(iterated, error).
            return iterated.close(agent, @as(Agent.Error!Value, @"error"));
        }
        const procedure = procedure_value.asObject();

        // 5. Set iterated to ? GetIteratorDirect(obj).
        iterated = try getIteratorDirect(agent, obj);

        // 6. Let counter be +0𝔽.
        var counter: f64 = 0;

        // 7. Repeat,
        //     a. Let value be ? IteratorStepValue(iterated).
        //     b. If value is done, return undefined.
        while (try iterated.stepValue(agent)) |value| {
            // c. Let result be Completion(Call(procedure, undefined, « value, counter »)).
            _ = procedure.call(agent, .undefined, &.{ value, Value.from(counter) }) catch |err| {
                // d. IfAbruptCloseIterator(result, iterated).
                return iterated.close(agent, @as(Agent.Error!Value, err));
            };

            // e. NOTE: The following step will not change counter once it reaches 2**53𝔽.
            // f. Set counter to counter + 1𝔽.
            counter += 1;
        }
        return .undefined;
    }

    /// 27.1.3.3.8 Iterator.prototype.map ( mapper )
    /// https://tc39.es/ecma262/#sec-iterator.prototype.map
    fn map(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const realm = agent.currentRealm();
        const mapper_value = arguments.get(0);

        // 1. Let obj be the this value.
        // 2. If obj is not an Object, throw a TypeError exception.
        if (!this_value.isObject()) {
            return agent.throwException(.type_error, "{f} is not an Object", .{this_value});
        }
        const obj = this_value.asObject();

        // 3. Let iterated be the Iterator Record { [[Iterator]]: obj, [[NextMethod]]: undefined,
        //    [[Done]]: false }.
        var iterated: types.Iterator = .{
            .iterator = obj,
            .next_method = .undefined,
            .done = false,
        };

        // 4. If IsCallable(mapper) is false, then
        if (!mapper_value.isCallable()) {
            // a. Let error be ThrowCompletion(a newly created TypeError object).
            const @"error" = agent.throwException(
                .type_error,
                "{f} is not callable",
                .{mapper_value},
            );

            // b. Return ? IteratorClose(iterated, error).
            return iterated.close(agent, @as(Agent.Error!Value, @"error"));
        }
        const mapper = mapper_value.asObject();

        // 5. Set iterated to ? GetIteratorDirect(obj).
        iterated = try getIteratorDirect(agent, obj);

        const iterated_list = try agent.gc_allocator.alloc(types.Iterator, 1);
        iterated_list[0] = iterated;

        const Captures = struct {
            iterated: *types.Iterator,
            mapper: *Object,
            counter: f64,
        };
        const captures = try agent.gc_allocator.create(Captures);
        captures.* = .{
            .iterated = &iterated_list[0],
            .mapper = mapper,
            .counter = 0,
        };

        // 6. Let closure be a new Abstract Closure with no parameters that captures iterated and
        //    mapper and performs the following steps when called:
        const closure = struct {
            fn func(agent_: *Agent, iterator_helper: *builtins.IteratorHelper) Agent.Error!?Value {
                const captures_ = iterator_helper.fields.state.capturesAs(Captures);
                const iterated_ = captures_.iterated;
                const mapper_ = captures_.mapper;

                // a. Let counter be +0𝔽.
                const counter = &captures_.counter;

                // b. Repeat,

                // i. Let value be ? IteratorStepValue(iterated).
                // ii. If value is done, return ReturnCompletion(undefined).
                const value = (try iterated_.stepValue(agent_)) orelse return null;

                // iii. Let mapped be Completion(Call(mapper, undefined, « value, counter »)).
                const mapped = mapper_.call(
                    agent_,
                    .undefined,
                    &.{ value, Value.from(counter.*) },
                ) catch |err| {
                    // iv. IfAbruptCloseIterator(mapped, iterated).
                    return iterated_.close(agent_, @as(Agent.Error!?Value, err));
                };

                // vii. NOTE: The following step will not change counter once it reaches 2**53𝔽.
                // viii. Set counter to counter + 1𝔽.
                defer counter.* += 1;

                // v. Let completion be Completion(Yield(mapped)).
                // vi. IfAbruptCloseIterator(completion, iterated).
                return mapped;
            }
        }.func;

        // 7. Let result be CreateIteratorFromClosure(closure, "Iterator Helper",
        //    %IteratorHelperPrototype%, « [[UnderlyingIterators]] »).
        const result = try builtins.IteratorHelper.create(agent, .{
            .prototype = try realm.intrinsic(.iterator_helper_prototype),
            .fields = .{
                .state = .{
                    // 8. Set result.[[UnderlyingIterators]] to « iterated ».
                    .underlying_iterators = iterated_list,

                    .closure = closure,
                    .captures = captures,
                },
            },
        });

        // 9. Return result.
        return Value.from(&result.object);
    }

    /// 27.1.3.3.9 Iterator.prototype.reduce ( reducer [ , initialValue ] )
    /// https://tc39.es/ecma262/#sec-iterator.prototype.reduce
    fn reduce(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const reducer_value = arguments.get(0);
        const initial_value = arguments.getOrNull(1);

        // 1. Let obj be the this value.
        // 2. If obj is not an Object, throw a TypeError exception.
        if (!this_value.isObject()) {
            return agent.throwException(.type_error, "{f} is not an Object", .{this_value});
        }
        const obj = this_value.asObject();

        // 3. Let iterated be the Iterator Record { [[Iterator]]: obj, [[NextMethod]]: undefined,
        //    [[Done]]: false }.
        var iterated: types.Iterator = .{
            .iterator = obj,
            .next_method = .undefined,
            .done = false,
        };

        // 4. If IsCallable(reducer) is false, then
        if (!reducer_value.isCallable()) {
            // a. Let error be ThrowCompletion(a newly created TypeError object).
            const @"error" = agent.throwException(
                .type_error,
                "{f} is not callable",
                .{reducer_value},
            );

            // b. Return ? IteratorClose(iterated, error).
            return iterated.close(agent, @as(Agent.Error!Value, @"error"));
        }
        const reducer = reducer_value.asObject();

        // 5. Set iterated to ? GetIteratorDirect(obj).
        iterated = try getIteratorDirect(agent, obj);

        var accumulator: Value = undefined;
        var counter: f64 = undefined;

        // 6. If initialValue is not present, then
        if (initial_value == null) {
            // a. Let accumulator be ? IteratorStepValue(iterated).
            accumulator = (try iterated.stepValue(agent)) orelse {
                // b. If accumulator is done, throw a TypeError exception.
                return agent.throwException(
                    .type_error,
                    "Cannot reduce empty iterator without initial value",
                    .{},
                );
            };

            // c. Let counter be 1𝔽.
            counter = 1;
        } else {
            // 7. Else,
            // a. Let accumulator be initialValue.
            accumulator = initial_value.?;

            // b. Let counter be +0𝔽.
            counter = 0;
        }

        // 8. Repeat,
        //     a. Let value be ? IteratorStepValue(iterated).
        //     b. If value is done, return accumulator.
        while (try iterated.stepValue(agent)) |value| {
            // c. Let result be Completion(Call(reducer, undefined, « accumulator, value,
            //    counter »)).
            const result = reducer.call(
                agent,
                .undefined,
                &.{ accumulator, value, Value.from(counter) },
            ) catch |err| {
                // d. IfAbruptCloseIterator(result, iterated).
                return iterated.close(agent, @as(Agent.Error!Value, err));
            };

            // e. Set accumulator to result.
            accumulator = result;

            // f. NOTE: The following step will not change counter once it reaches 2**53𝔽.
            // g. Set counter to counter + 1𝔽.
            counter += 1;
        }
        return accumulator;
    }

    /// 27.1.3.3.10 Iterator.prototype.some ( predicate )
    /// https://tc39.es/ecma262/#sec-iterator.prototype.some
    fn some(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const predicate_value = arguments.get(0);

        // 1. Let obj be the this value.
        // 2. If obj is not an Object, throw a TypeError exception.
        if (!this_value.isObject()) {
            return agent.throwException(.type_error, "{f} is not an Object", .{this_value});
        }
        const obj = this_value.asObject();

        // 3. Let iterated be the Iterator Record { [[Iterator]]: obj, [[NextMethod]]: undefined,
        //    [[Done]]: false }.
        var iterated: types.Iterator = .{
            .iterator = obj,
            .next_method = .undefined,
            .done = false,
        };

        // 4. If IsCallable(predicate) is false, then
        if (!predicate_value.isCallable()) {
            // a. Let error be ThrowCompletion(a newly created TypeError object).
            const @"error" = agent.throwException(
                .type_error,
                "{f} is not callable",
                .{predicate_value},
            );

            // b. Return ? IteratorClose(iterated, error).
            return iterated.close(agent, @as(Agent.Error!Value, @"error"));
        }
        const predicate = predicate_value.asObject();

        // 5. Set iterated to ? GetIteratorDirect(obj).
        iterated = try getIteratorDirect(agent, obj);

        // 6. Let counter be +0𝔽.
        var counter: f64 = 0;

        // 7. Repeat,
        //     a. Let value be ? IteratorStepValue(iterated).
        //     b. If value is done, return false.
        while (try iterated.stepValue(agent)) |value| {
            // c. Let result be Completion(Call(predicate, undefined, « value, counter »)).
            const result = predicate.call(
                agent,
                .undefined,
                &.{ value, Value.from(counter) },
            ) catch |err| {
                // d. IfAbruptCloseIterator(result, iterated).
                return iterated.close(agent, @as(Agent.Error!Value, err));
            };

            // e. If ToBoolean(result) is true, return ? IteratorClose(iterated, NormalCompletion(
            //    true)).
            if (result.toBoolean()) {
                return try iterated.close(agent, @as(Agent.Error!Value, .true));
            }

            // f. NOTE: The following step will not change counter once it reaches 2**53𝔽.
            // g. Set counter to counter + 1𝔽.
            counter += 1;
        }
        return .false;
    }

    /// 27.1.3.3.11 Iterator.prototype.take ( limit )
    /// https://tc39.es/ecma262/#sec-iterator.prototype.take
    fn take(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const realm = agent.currentRealm();
        const limit = arguments.get(0);

        // 1. Let obj be the this value.
        // 2. If obj is not an Object, throw a TypeError exception.
        if (!this_value.isObject()) {
            return agent.throwException(.type_error, "{f} is not an Object", .{this_value});
        }
        const obj = this_value.asObject();

        // 3. Let iterated be the Iterator Record { [[Iterator]]: obj, [[NextMethod]]: undefined,
        //    [[Done]]: false }.
        var iterated: types.Iterator = .{
            .iterator = obj,
            .next_method = .undefined,
            .done = false,
        };

        // 4. Let numberLimit be Completion(ToNumber(limit)).
        const number_limit = limit.toNumber(agent) catch |err| {
            // 5. IfAbruptCloseIterator(numberLimit, iterated).
            return iterated.close(agent, @as(Agent.Error!Value, err));
        };

        // 6. If numberLimit is NaN, then
        if (number_limit.isNan()) {
            // a. Let error be ThrowCompletion(a newly created RangeError object).
            const @"error" = agent.throwException(
                .range_error,
                "Limit must not be NaN",
                .{},
            );

            // b. Return ? IteratorClose(iterated, error).
            return iterated.close(agent, @as(Agent.Error!Value, @"error"));
        }

        // 7. If numberLimit is finite and numberLimit > 𝔽(2**53 - 1), then
        if (number_limit.isFinite() and number_limit.asFloat() > std.math.maxInt(u53)) {
            // a. Let error be ThrowCompletion(a newly created RangeError object).
            const @"error" = agent.throwException(
                .range_error,
                "Limit must not exceed 2^53-1",
                .{},
            );

            // b. Return ? IteratorClose(iterated, error).
            return iterated.close(agent, @as(Agent.Error!Value, @"error"));
        }

        // 8. Let intLimit be ! ToIntegerOrInfinity(numberLimit).
        const int_limit = Value.from(number_limit).toIntegerOrInfinity(agent) catch unreachable;

        // 9. If intLimit < 0, then
        if (int_limit < 0) {
            // a. Let error be ThrowCompletion(a newly created RangeError object).
            const @"error" = agent.throwException(
                .range_error,
                "Limit must be a positive number",
                .{},
            );

            // b. Return ? IteratorClose(iterated, error).
            return iterated.close(agent, @as(Agent.Error!Value, @"error"));
        }

        // 10. Set iterated to ? GetIteratorDirect(obj).
        iterated = try getIteratorDirect(agent, obj);

        const iterated_list = try agent.gc_allocator.alloc(types.Iterator, 1);
        iterated_list[0] = iterated;

        const Captures = struct {
            iterated: *types.Iterator,
            int_limit: f64,
        };
        const captures = try agent.gc_allocator.create(Captures);
        captures.* = .{
            .iterated = &iterated_list[0],
            .int_limit = int_limit,
        };

        // 11. Let closure be a new Abstract Closure with no parameters that captures iterated and
        //     intLimit and performs the following steps when called:
        const closure = struct {
            fn func(agent_: *Agent, iterator_helper: *builtins.IteratorHelper) Agent.Error!?Value {
                const captures_ = iterator_helper.fields.state.capturesAs(Captures);
                const iterated_ = captures_.iterated;

                // a. Let remaining be 𝔽(intLimit).
                const remaining = &captures_.int_limit;

                // b. Repeat,
                while (true) {
                    // i. If remaining is +0𝔽, then
                    if (remaining.* == 0) {
                        // 1. Return ? IteratorClose(iterated, ReturnCompletion(undefined)).
                        iterator_helper.fields = .completed;
                        return iterated_.close(agent_, @as(Agent.Error!?Value, null));
                    }

                    // ii. Set remaining to remaining - 1𝔽.
                    remaining.* -= 1;

                    // iii. Let value be ? IteratorStepValue(iterated).
                    // iv. If value is done, return ReturnCompletion(undefined).
                    const value = (try iterated_.stepValue(agent_)) orelse return null;

                    // v. Let completion be Completion(Yield(value)).
                    // vi. IfAbruptCloseIterator(completion, iterated).
                    return value;
                }
            }
        }.func;

        // 12. Let result be CreateIteratorFromClosure(closure, "Iterator Helper",
        //     %IteratorHelperPrototype%, « [[UnderlyingIterators]] »).
        const result = try builtins.IteratorHelper.create(agent, .{
            .prototype = try realm.intrinsic(.iterator_helper_prototype),
            .fields = .{
                .state = .{
                    // 13. Set result.[[UnderlyingIterators]] to « iterated ».
                    .underlying_iterators = iterated_list,

                    .closure = closure,
                    .captures = captures,
                },
            },
        });

        // 14. Return result.
        return Value.from(&result.object);
    }

    /// 27.1.3.3.12 Iterator.prototype.toArray ( )
    /// https://tc39.es/ecma262/#sec-iterator.prototype.toarray
    fn toArray(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let obj be the this value.
        // 2. If obj is not an Object, throw a TypeError exception.
        if (!this_value.isObject()) {
            return agent.throwException(.type_error, "{f} is not an Object", .{this_value});
        }
        const obj = this_value.asObject();

        // 3. Let iterated be ? GetIteratorDirect(obj).
        var iterated = try getIteratorDirect(agent, obj);

        // 4. Let items be a new empty List.
        var items: std.ArrayList(Value) = .empty;
        defer items.deinit(agent.gc_allocator);

        // 5. Repeat,
        //     a. Let value be ? IteratorStepValue(iterated).
        //     b. If value is done, return CreateArrayFromList(items).
        while (try iterated.stepValue(agent)) |value| {
            // c. Append value to items.
            try items.append(agent.gc_allocator, value);
        }
        const array = try createArrayFromList(agent, items.items);
        return Value.from(&array.object);
    }

    /// 2 Iterator.prototype.windows ( windowSize [ , undersized ] )
    /// https://tc39.es/proposal-iterator-chunking/#sec-iterator.prototype.windows
    fn windows(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const realm = agent.currentRealm();
        const window_size_value = arguments.get(0);
        const undersized_value = arguments.get(1);

        // 1. Let O be the this value.
        // 2. If O is not an Object, throw a TypeError exception.
        if (!this_value.isObject()) {
            return agent.throwException(.type_error, "{f} is not an Object", .{this_value});
        }
        const obj = this_value.asObject();

        // 3. Let iterated be the Iterator Record { [[Iterator]]: O, [[NextMethod]]: undefined,
        //    [[Done]]: false }.
        var iterated: types.Iterator = .{
            .iterator = obj,
            .next_method = .undefined,
            .done = false,
        };

        // 4. If windowSize is not an integral Number, then
        if (!window_size_value.isNumber() or !window_size_value.asNumber().isIntegral()) {
            // a. Let error be ThrowCompletion(a newly created TypeError object).
            const @"error" = agent.throwException(
                .type_error,
                "Window size must be an integral number",
                .{},
            );

            // b. Return ? IteratorClose(iterated, error).
            return iterated.close(agent, @as(Agent.Error!Value, @"error"));
        }

        // 5. If windowSize is not in the inclusive interval from 1𝔽 to 𝔽(2**32 - 1), then
        const window_size_float = window_size_value.asNumber().asFloat();
        if (window_size_float < 1 or window_size_float > std.math.maxInt(u32)) {
            // a. Let error be ThrowCompletion(a newly created RangeError object).
            const @"error" = agent.throwException(
                .range_error,
                "Window size must be in the inclusive interval from 1 to 2^32 - 1",
                .{},
            );

            // b. Return ? IteratorClose(iterated, error).
            return iterated.close(agent, @as(Agent.Error!Value, @"error"));
        }
        const window_size: u32 = @intFromFloat(window_size_float);

        const Undersized = enum { only_full, allow_partial };

        // 6. If undersized is undefined, set undersized to "only-full".
        // 7. If undersized is neither "only-full" nor "allow-partial", then
        const undersized: Undersized = blk: {
            if (undersized_value.isUndefined()) break :blk .only_full;
            if (undersized_value.isString()) {
                if (undersized_value.asString().eql(String.fromLiteral("only-full"))) break :blk .only_full;
                if (undersized_value.asString().eql(String.fromLiteral("allow-partial"))) break :blk .allow_partial;
            }

            // a. Let error be ThrowCompletion(a newly created TypeError object).
            const @"error" = agent.throwException(
                .type_error,
                "Invalid undersized {f}",
                .{undersized_value},
            );

            // b. Return ? IteratorClose(iterated, error).
            return iterated.close(agent, @as(Agent.Error!Value, @"error"));
        };

        // 8. Set iterated to ? GetIteratorDirect(O).
        iterated = try getIteratorDirect(agent, obj);

        const iterated_list = try agent.gc_allocator.alloc(types.Iterator, 1);
        iterated_list[0] = iterated;

        const Captures = struct {
            iterated: *types.Iterator,
            window_size: u32,
            undersized: Undersized,
            buffer: std.ArrayList(Value),
        };
        const captures = try agent.gc_allocator.create(Captures);
        captures.* = .{
            .iterated = &iterated_list[0],
            .window_size = window_size,
            .undersized = undersized,
            .buffer = .empty,
        };

        // 9. Let closure be a new Abstract Closure with no parameters that captures iterated,
        //    windowSize, and undersized and performs the following steps when called:
        const closure = struct {
            fn func(agent_: *Agent, iterator_helper: *builtins.IteratorHelper) Agent.Error!?Value {
                const captures_ = iterator_helper.fields.state.capturesAs(Captures);
                const iterated_ = captures_.iterated;
                const window_size_ = captures_.window_size;
                const undersized_ = captures_.undersized;
                const buffer = &captures_.buffer;

                // a. Let buffer be a new empty List.
                // b. Repeat,
                while (true) {
                    // i. Let value be ? IteratorStepValue(iterated).
                    // ii. If value is done, then
                    const value = try iterated_.stepValue(agent_) orelse {
                        defer buffer.clearAndFree(agent_.gc_allocator);

                        // 1. If undersized is "allow-partial", buffer is not empty, and the number
                        //    of elements in buffer < ℝ(windowSize), then
                        if (undersized_ == .allow_partial and
                            buffer.items.len != 0 and
                            buffer.items.len < window_size_)
                        {
                            // a. Perform Completion(Yield(CreateArrayFromList(buffer))).
                            const array = try createArrayFromList(agent_, buffer.items);
                            return Value.from(&array.object);
                        }

                        // 2. Return ReturnCompletion(undefined).
                        return null;
                    };

                    // iii. If the number of elements in buffer is ℝ(windowSize), then
                    if (buffer.items.len == window_size_) {
                        // 1. Remove the first element from buffer.
                        _ = buffer.orderedRemove(0);
                    }

                    // iv. Append value to buffer.
                    try buffer.append(agent_.gc_allocator, value);

                    // v. If the number of elements in buffer is ℝ(windowSize), then
                    if (buffer.items.len == window_size_) {
                        // 1. Let completion be Completion(Yield(CreateArrayFromList(buffer))).
                        const array = try createArrayFromList(agent_, buffer.items);

                        // 2. IfAbruptCloseIterator(completion, iterated).
                        return Value.from(&array.object);
                    }
                }
            }
        }.func;

        // 10. Let result be CreateIteratorFromClosure(closure, "Iterator Helper",
        //     %IteratorHelperPrototype%, « [[UnderlyingIterators]] »).
        const result = try builtins.IteratorHelper.create(agent, .{
            .prototype = try realm.intrinsic(.iterator_helper_prototype),
            .fields = .{
                .state = .{
                    // 11. Set result.[[UnderlyingIterators]] to « iterated ».
                    .underlying_iterators = iterated_list,

                    .closure = closure,
                    .captures = captures,
                },
            },
        });

        // 12. Return result.
        return Value.from(&result.object);
    }

    /// 27.1.3.3.13 Iterator.prototype [ %Symbol.dispose% ] ( )
    /// https://tc39.es/ecma262/#sec-iterator.prototype-%symbol.dispose%
    fn @"Symbol.dispose"(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let obj be the this value.
        // 2. Let return be ? GetMethod(obj, "return").
        const maybe_return = try this_value.getMethod(agent, PropertyKey.from("return"));

        // 3. If return is not undefined, then
        if (maybe_return) |@"return"| {
            // a. Perform ? Call(return, obj).
            _ = try @"return".call(agent, this_value, &.{});
        }

        // 4. Return undefined.
        return .undefined;
    }

    /// 27.1.3.3.14 Iterator.prototype [ %Symbol.iterator% ] ( )
    /// https://tc39.es/ecma262/#sec-iterator.prototype-%symbol.iterator%
    fn @"Symbol.iterator"(_: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Return the this value.
        return this_value;
    }
};

pub const Iterator = MakeObject(.{
    .tag = .iterator,
    .display_name = "Iterator",
});
