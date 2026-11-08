//! 20.4 Symbol Objects
//! https://tc39.es/ecma262/#sec-symbol-objects

const std = @import("std");

const builtins = @import("../builtins.zig");
const execution = @import("../execution.zig");
const types = @import("../types.zig");

const Agent = execution.Agent;
const Arguments = types.Arguments;
const MakeObject = types.MakeObject;
const Object = types.Object;
const Realm = execution.Realm;
const String = types.String;
const Value = types.Value;
const createBuiltinFunction = builtins.createBuiltinFunction;
const ordinaryObjectCreate = builtins.ordinaryObjectCreate;

/// 20.4.2 Properties of the Symbol Constructor
/// https://tc39.es/ecma262/#sec-properties-of-the-symbol-constructor
pub const constructor = struct {
    pub fn create(agent: *Agent, realm: *Realm) std.mem.Allocator.Error!*Object {
        const builtin_function = try createBuiltinFunction(
            agent,
            .{ .constructor = impl },
            0,
            "Symbol",
            .{ .realm = realm, .proto = try realm.intrinsic(.function_prototype) },
        );
        return &builtin_function.object;
    }

    pub fn init(agent: *Agent, realm: *Realm, object: *Object) std.mem.Allocator.Error!void {
        // 20.4.2.1 Symbol.asyncDispose
        // https://tc39.es/ecma262/#sec-symbol.asyncdispose
        try object.defineBuiltinPropertyWithAttributes(
            agent,
            "asyncDispose",
            Value.from(agent.well_known_symbols.async_dispose),
            .none,
        );

        // 20.4.2.2 Symbol.asyncIterator
        // https://tc39.es/ecma262/#sec-symbol.asynciterator
        try object.defineBuiltinPropertyWithAttributes(
            agent,
            "asyncIterator",
            Value.from(agent.well_known_symbols.async_iterator),
            .none,
        );

        // 20.4.2.3 Symbol.dispose
        // https://tc39.es/ecma262/#sec-symbol.dispose
        try object.defineBuiltinPropertyWithAttributes(
            agent,
            "dispose",
            Value.from(agent.well_known_symbols.dispose),
            .none,
        );

        try object.defineBuiltinFunction(agent, "for", @"for", 1, realm);

        // 20.4.2.5 Symbol.hasInstance
        // https://tc39.es/ecma262/#sec-symbol.hasinstance
        try object.defineBuiltinPropertyWithAttributes(
            agent,
            "hasInstance",
            Value.from(agent.well_known_symbols.has_instance),
            .none,
        );

        // 20.4.2.6 Symbol.isConcatSpreadable
        // https://tc39.es/ecma262/#sec-symbol.isconcatspreadable
        try object.defineBuiltinPropertyWithAttributes(
            agent,
            "isConcatSpreadable",
            Value.from(agent.well_known_symbols.is_concat_spreadable),
            .none,
        );

        // 20.4.2.7 Symbol.iterator
        // https://tc39.es/ecma262/#sec-symbol.iterator
        try object.defineBuiltinPropertyWithAttributes(
            agent,
            "iterator",
            Value.from(agent.well_known_symbols.iterator),
            .none,
        );

        try object.defineBuiltinFunction(agent, "keyFor", keyFor, 1, realm);

        // 20.4.2.9 Symbol.match
        // https://tc39.es/ecma262/#sec-symbol.match
        try object.defineBuiltinPropertyWithAttributes(
            agent,
            "match",
            Value.from(agent.well_known_symbols.match),
            .none,
        );

        // 20.4.2.10 Symbol.matchAll
        // https://tc39.es/ecma262/#sec-symbol.matchall
        try object.defineBuiltinPropertyWithAttributes(
            agent,
            "matchAll",
            Value.from(agent.well_known_symbols.match_all),
            .none,
        );

        // 20.4.2.11 Symbol.prototype
        // https://tc39.es/ecma262/#sec-symbol.prototype
        try object.defineBuiltinPropertyWithAttributes(
            agent,
            "prototype",
            Value.from(try realm.intrinsic(.symbol_prototype)),
            .none,
        );

        // 20.4.2.12 Symbol.replace
        // https://tc39.es/ecma262/#sec-symbol.replace
        try object.defineBuiltinPropertyWithAttributes(
            agent,
            "replace",
            Value.from(agent.well_known_symbols.replace),
            .none,
        );

        // 20.4.2.13 Symbol.search
        // https://tc39.es/ecma262/#sec-symbol.search
        try object.defineBuiltinPropertyWithAttributes(
            agent,
            "search",
            Value.from(agent.well_known_symbols.search),
            .none,
        );

        // 20.4.2.14 Symbol.species
        // https://tc39.es/ecma262/#sec-symbol.species
        try object.defineBuiltinPropertyWithAttributes(
            agent,
            "species",
            Value.from(agent.well_known_symbols.species),
            .none,
        );

        // 20.4.2.15 Symbol.split
        // https://tc39.es/ecma262/#sec-symbol.split
        try object.defineBuiltinPropertyWithAttributes(
            agent,
            "split",
            Value.from(agent.well_known_symbols.split),
            .none,
        );

        // 20.4.2.16 Symbol.toPrimitive
        // https://tc39.es/ecma262/#sec-symbol.toprimitive
        try object.defineBuiltinPropertyWithAttributes(
            agent,
            "toPrimitive",
            Value.from(agent.well_known_symbols.to_primitive),
            .none,
        );

        // 20.4.2.17 Symbol.toStringTag
        // https://tc39.es/ecma262/#sec-symbol.tostringtag
        try object.defineBuiltinPropertyWithAttributes(
            agent,
            "toStringTag",
            Value.from(agent.well_known_symbols.to_string_tag),
            .none,
        );

        // 20.4.2.18 Symbol.unscopables
        // https://tc39.es/ecma262/#sec-symbol.unscopables
        try object.defineBuiltinPropertyWithAttributes(
            agent,
            "unscopables",
            Value.from(agent.well_known_symbols.unscopables),
            .none,
        );
    }

    /// 20.4.1.1 Symbol ( [ description ] )
    /// https://tc39.es/ecma262/#sec-symbol-description
    fn impl(agent: *Agent, arguments: Arguments, new_target: ?*Object) Agent.Error!Value {
        const description = arguments.get(0);

        // 1. If NewTarget is not undefined, throw a TypeError exception.
        if (new_target != null) {
            return agent.throwException(.type_error, "Symbol is not a constructor", .{});
        }

        const description_string = blk: {
            // 2. If description is undefined, let descString be undefined.
            if (description.isUndefined()) break :blk null;

            // 3. Else, let descString be ? ToString(description).
            break :blk try description.toString(agent);
        };

        // 4. Return a new Symbol whose [[Description]] is descString.
        return Value.from(try types.Symbol.init(agent, description_string));
    }

    /// 20.4.2.4 Symbol.for ( key )
    /// https://tc39.es/ecma262/#sec-symbol.for
    fn @"for"(agent: *Agent, _: Value, arguments: Arguments) Agent.Error!Value {
        const key = arguments.get(0);

        // 1. Let stringKey be ? ToString(key).
        const string_key = try key.toString(agent);

        // 2. Let agentRecord be the Agent Record of the surrounding agent.
        // 3. Let globalSymbolRegistry be agentRecord.[[GlobalSymbolRegistry]].
        // 4. For each element element of globalSymbolRegistry, do
        const gop = try agent.global_symbol_registry.getOrPut(agent.gc_allocator, string_key);
        if (gop.found_existing) {
            // a. If element.[[Key]] is stringKey, return element.[[Symbol]].
            return Value.from(gop.value_ptr.*);
        }

        // 5. Assert: globalSymbolRegistry does not currently contain an entry for stringKey.

        // 6. Let newSymbol be a new Symbol whose [[Description]] is stringKey.
        const new_symbol = try types.Symbol.init(agent, string_key);

        // 7. Append the GlobalSymbolRegistry Record { [[Key]]: stringKey, [[Symbol]]: newSymbol }
        //    to globalSymbolRegistry.
        gop.value_ptr.* = new_symbol;

        // 8. Return newSymbol.
        return Value.from(new_symbol);
    }

    /// 20.4.2.8 Symbol.keyFor ( symbol )
    /// https://tc39.es/ecma262/#sec-symbol.keyfor
    fn keyFor(agent: *Agent, _: Value, arguments: Arguments) Agent.Error!Value {
        const symbol = arguments.get(0);

        // 1. If symbol is not a Symbol, throw a TypeError exception.
        if (!symbol.isSymbol()) {
            return agent.throwException(.type_error, "{f} is not a Symbol", .{symbol});
        }

        // 2. Return KeyForSymbol(symbol).
        return Value.from(keyForSymbol(agent, symbol.asSymbol()) orelse return .undefined);
    }
};

/// 20.4.3 Properties of the Symbol Prototype Object
/// https://tc39.es/ecma262/#sec-properties-of-the-symbol-prototype-object
pub const prototype = struct {
    pub fn create(agent: *Agent, realm: *Realm) std.mem.Allocator.Error!*Object {
        return ordinaryObjectCreate(agent, try realm.intrinsic(.object_prototype));
    }

    pub fn init(agent: *Agent, realm: *Realm, object: *Object) std.mem.Allocator.Error!void {
        try object.defineBuiltinAccessor(agent, "description", description, null, realm);
        try object.defineBuiltinFunction(agent, "toString", toString, 0, realm);
        try object.defineBuiltinFunction(agent, "valueOf", valueOf, 0, realm);
        try object.defineBuiltinFunctionWithAttributes(
            agent,
            "Symbol.toPrimitive",
            @"Symbol.toPrimitive",
            1,
            realm,
            .{
                .writable = false,
                .enumerable = false,
                .configurable = true,
            },
        );

        // 20.4.3.1 Symbol.prototype.constructor
        // https://tc39.es/ecma262/#sec-symbol.prototype.constructor
        try object.defineBuiltinProperty(
            agent,
            "constructor",
            Value.from(try realm.intrinsic(.symbol)),
        );

        // 20.4.3.6 Symbol.prototype [ %Symbol.toStringTag% ]
        // https://tc39.es/ecma262/#sec-symbol.prototype-%symbol.tostringtag%
        try object.defineBuiltinPropertyWithAttributes(
            agent,
            "Symbol.toStringTag",
            Value.from("Symbol"),
            .{
                .writable = false,
                .enumerable = false,
                .configurable = true,
            },
        );
    }

    /// 20.4.3.4.1 ThisSymbolValue ( arg )
    /// https://tc39.es/ecma262/#sec-thissymbolvalue
    fn thisSymbolValue(agent: *Agent, arg: Value) error{ExceptionThrown}!*const types.Symbol {
        // 1. If arg is a Symbol, return arg.
        if (arg.isSymbol()) return arg.asSymbol();

        // 2. If arg is an Object and arg has a [[SymbolData]] internal slot, then
        if (arg.castObject(Symbol)) |symbol| {
            // a. Let symbol be arg.[[SymbolData]].
            // b. Assert: symbol is a Symbol.
            // c. Return symbol.
            return symbol.fields.symbol_data;
        }

        // 3. Throw a TypeError exception.
        return agent.throwException(
            .type_error,
            "This value must be a symbol or Symbol object",
            .{},
        );
    }

    /// 20.4.3.2 get Symbol.prototype.description
    /// https://tc39.es/ecma262/#sec-symbol.prototype.description
    fn description(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let symbol be ? ThisSymbolValue(this value).
        const symbol = try thisSymbolValue(agent, this_value);

        // 2. Return symbol.[[Description]].
        return Value.from(symbol.description orelse return .undefined);
    }

    /// 20.4.3.3 Symbol.prototype.toString ( )
    /// https://tc39.es/ecma262/#sec-symbol.prototype.tostring
    fn toString(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let symbol be ? ThisSymbolValue(this value).
        const symbol = try thisSymbolValue(agent, this_value);

        // 2. Return SymbolDescriptiveString(symbol).
        return Value.from(try symbol.descriptiveString(agent));
    }

    /// 20.4.3.4 Symbol.prototype.valueOf ( )
    /// https://tc39.es/ecma262/#sec-symbol.prototype.valueof
    fn valueOf(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Return ? ThisSymbolValue(this value).
        return Value.from(try thisSymbolValue(agent, this_value));
    }

    /// 20.4.3.5 Symbol.prototype [ %Symbol.toPrimitive% ] ( hint )
    /// https://tc39.es/ecma262/#sec-symbol.prototype-%symbol.toprimitive%
    fn @"Symbol.toPrimitive"(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Return ? ThisSymbolValue(this value).
        // NOTE: The argument is ignored.
        return Value.from(try thisSymbolValue(agent, this_value));
    }
};

/// 20.4.4 Properties of Symbol Instances
/// https://tc39.es/ecma262/#sec-properties-of-symbol-instances
pub const Symbol = MakeObject(.{
    .Fields = struct {
        /// [[SymbolData]]
        symbol_data: *const types.Symbol,
    },
    .tag = .symbol,
    .display_name = "Symbol",
});

/// 20.4.5.2 KeyForSymbol ( symbol )
/// https://tc39.es/ecma262/#sec-keyforsymbol
pub fn keyForSymbol(agent: *Agent, symbol: *const types.Symbol) ?*const String {
    // 1. Let agentRecord be the Agent Record of the surrounding agent.
    // 2. Let globalSymbolRegistry be agentRecord.[[GlobalSymbolRegistry]].
    // 3. For each element element of globalSymbolRegistry, do
    var it = agent.global_symbol_registry.iterator();
    while (it.next()) |entry| {
        // a. If SameValue(element.[[Symbol]], symbol) is true, return element.[[Key]].
        if (entry.value_ptr.* == symbol) return entry.key_ptr.*;
    }

    // 4. Assert: globalSymbolRegistry does not currently contain an entry for symbol.
    // 5. Return undefined.
    return null;
}
