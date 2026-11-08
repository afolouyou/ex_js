//! 6.1.5.1 Well-Known Symbols
//! https://tc39.es/ecma262/#sec-well-known-symbols

const types = @import("../../types.zig");

const String = types.String;
const Symbol = types.Symbol;

const WellKnownSymbols = @This();

async_dispose: *const Symbol,
async_iterator: *const Symbol,
dispose: *const Symbol,
has_instance: *const Symbol,
is_concat_spreadable: *const Symbol,
iterator: *const Symbol,
match: *const Symbol,
match_all: *const Symbol,
replace: *const Symbol,
search: *const Symbol,
species: *const Symbol,
split: *const Symbol,
to_primitive: *const Symbol,
to_string_tag: *const Symbol,
unscopables: *const Symbol,

pub const init: WellKnownSymbols = .{
    .async_dispose = Symbol.initComptime(String.fromLiteral("Symbol.asyncDispose")),
    .async_iterator = Symbol.initComptime(String.fromLiteral("Symbol.asyncIterator")),
    .dispose = Symbol.initComptime(String.fromLiteral("Symbol.dispose")),
    .has_instance = Symbol.initComptime(String.fromLiteral("Symbol.hasInstance")),
    .is_concat_spreadable = Symbol.initComptime(String.fromLiteral("Symbol.isConcatSpreadable")),
    .iterator = Symbol.initComptime(String.fromLiteral("Symbol.iterator")),
    .match = Symbol.initComptime(String.fromLiteral("Symbol.match")),
    .match_all = Symbol.initComptime(String.fromLiteral("Symbol.matchAll")),
    .replace = Symbol.initComptime(String.fromLiteral("Symbol.replace")),
    .search = Symbol.initComptime(String.fromLiteral("Symbol.search")),
    .species = Symbol.initComptime(String.fromLiteral("Symbol.species")),
    .split = Symbol.initComptime(String.fromLiteral("Symbol.split")),
    .to_primitive = Symbol.initComptime(String.fromLiteral("Symbol.toPrimitive")),
    .to_string_tag = Symbol.initComptime(String.fromLiteral("Symbol.toStringTag")),
    .unscopables = Symbol.initComptime(String.fromLiteral("Symbol.unscopables")),
};
