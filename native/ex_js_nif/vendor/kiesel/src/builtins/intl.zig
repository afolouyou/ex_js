//! 8 The Intl Object
//! https://tc39.es/ecma402/#intl-object

const std = @import("std");

const icu4zig = @import("icu4zig");

const abstract_operations = @import("intl/abstract_operations.zig");
const builtins = @import("../builtins.zig");
const execution = @import("../execution.zig");
const types = @import("../types.zig");

const Agent = execution.Agent;
const Arguments = types.Arguments;
const Object = types.Object;
const Realm = execution.Realm;
const String = types.String;
const Value = types.Value;
const availableCalendars = abstract_operations.availableCalendars;
const availableCanonicalCollations = abstract_operations.availableCanonicalCollations;
const availableCanonicalCurrencies = abstract_operations.availableCanonicalCurrencies;
const availableCanonicalNumberingSystems = abstract_operations.availableCanonicalNumberingSystems;
const availableCanonicalUnits = abstract_operations.availableCanonicalUnits;
const availablePrimaryTimeZoneIdentifiers = abstract_operations.availablePrimaryTimeZoneIdentifiers;
const createArrayFromListMapToValue = types.createArrayFromListMapToValue;
const ordinaryObjectCreate = builtins.ordinaryObjectCreate;

comptime {
    const build_options = @import("build-options");
    if (!build_options.enable_intl) @compileError("Intl is not enabled");
}

pub const collator = @import("./intl/collator.zig");
pub const date_time_format = @import("./intl/date_time_format.zig");
pub const display_names = @import("./intl/display_names.zig");
pub const duration_format = @import("./intl/duration_format.zig");
pub const list_format = @import("./intl/list_format.zig");
pub const locale = @import("./intl/locale.zig");
pub const number_format = @import("./intl/number_format.zig");
pub const plural_rules = @import("./intl/plural_rules.zig");
pub const relative_time_format = @import("./intl/relative_time_format.zig");
pub const segment_iterator = @import("./intl/segment_iterator.zig");
pub const segmenter = @import("./intl/segmenter.zig");
pub const segments = @import("./intl/segments.zig");

pub const Collator = collator.Collator;
pub const DateTimeFormat = date_time_format.DateTimeFormat;
pub const DisplayNames = display_names.DisplayNames;
pub const DurationFormat = duration_format.DurationFormat;
pub const ListFormat = list_format.ListFormat;
pub const Locale = locale.Locale;
pub const NumberFormat = number_format.NumberFormat;
pub const PluralRules = plural_rules.PluralRules;
pub const RelativeTimeFormat = relative_time_format.RelativeTimeFormat;
pub const SegmentIterator = segment_iterator.SegmentIterator;
pub const Segmenter = segmenter.Segmenter;
pub const Segments = segments.Segments;

pub const canonicalizeLocaleList = abstract_operations.canonicalizeLocaleList;
pub const createSegmentDataObject = segment_iterator.createSegmentDataObject;
pub const createSegmentIterator = segment_iterator.createSegmentIterator;
pub const createSegmentsObject = segments.createSegmentsObject;
pub const findBoundary = segmenter.findBoundary;

pub const namespace = struct {
    pub fn create(agent: *Agent, realm: *Realm) std.mem.Allocator.Error!*Object {
        return ordinaryObjectCreate(agent, try realm.intrinsic(.object_prototype));
    }

    pub fn init(agent: *Agent, realm: *Realm, object: *Object) std.mem.Allocator.Error!void {
        try object.defineBuiltinFunction(agent, "getCanonicalLocales", getCanonicalLocales, 1, realm);
        try object.defineBuiltinFunction(agent, "supportedValuesOf", supportedValuesOf, 1, realm);

        // 8.1.1 Intl [ %Symbol.toStringTag% ]
        // https://tc39.es/ecma402/#sec-intl-%symbol.tostringtag%
        try object.defineBuiltinPropertyWithAttributes(
            agent,
            "Symbol.toStringTag",
            Value.from("Intl"),
            .{
                .writable = false,
                .enumerable = false,
                .configurable = true,
            },
        );

        // 8.2.1 Intl.Collator ( . . . )
        // https://tc39.es/ecma402/#sec-intl.collator-intro
        try object.defineBuiltinProperty(
            agent,
            "Collator",
            Value.from(try realm.intrinsic(.intl_collator)),
        );

        // 8.2.2 Intl.DateTimeFormat ( . . . )
        // https://tc39.es/ecma402/#sec-intl.datetimeformat-intro
        try object.defineBuiltinProperty(
            agent,
            "DateTimeFormat",
            Value.from(try realm.intrinsic(.intl_date_time_format)),
        );

        // 8.2.3 Intl.DisplayNames ( . . . )
        // https://tc39.es/ecma402/#sec-intl.displaynames-intro
        try object.defineBuiltinProperty(
            agent,
            "DisplayNames",
            Value.from(try realm.intrinsic(.intl_display_names)),
        );

        // 8.2.4 Intl.DurationFormat ( . . . )
        // https://tc39.es/ecma402/#sec-intl.durationformat-intro
        try object.defineBuiltinProperty(
            agent,
            "DurationFormat",
            Value.from(try realm.intrinsic(.intl_duration_format)),
        );

        // 8.2.5 Intl.ListFormat ( . . . )
        // https://tc39.es/ecma402/#sec-intl.listformat-intro
        try object.defineBuiltinProperty(
            agent,
            "ListFormat",
            Value.from(try realm.intrinsic(.intl_list_format)),
        );

        // 8.2.6 Intl.Locale ( . . . )
        // https://tc39.es/ecma402/#sec-intl.locale-intro
        try object.defineBuiltinProperty(
            agent,
            "Locale",
            Value.from(try realm.intrinsic(.intl_locale)),
        );

        // 8.2.7 Intl.NumberFormat ( . . . )
        // https://tc39.es/ecma402/#sec-intl.numberformat-intro
        try object.defineBuiltinProperty(
            agent,
            "NumberFormat",
            Value.from(try realm.intrinsic(.intl_number_format)),
        );

        // 8.2.8 Intl.PluralRules ( . . . )
        // https://tc39.es/ecma402/#sec-intl.pluralrules-intro
        try object.defineBuiltinProperty(
            agent,
            "PluralRules",
            Value.from(try realm.intrinsic(.intl_plural_rules)),
        );

        // 8.2.9 Intl.RelativeTimeFormat ( . . . )
        // https://tc39.es/ecma402/#sec-intl.relativetimeformat-intro
        try object.defineBuiltinProperty(
            agent,
            "RelativeTimeFormat",
            Value.from(try realm.intrinsic(.intl_relative_time_format)),
        );

        // 8.2.10 Intl.Segmenter ( . . . )
        // https://tc39.es/ecma402/#sec-intl.segmenter-intro
        try object.defineBuiltinProperty(
            agent,
            "Segmenter",
            Value.from(try realm.intrinsic(.intl_segmenter)),
        );
    }

    /// 8.3.1 Intl.getCanonicalLocales ( locales )
    /// https://tc39.es/ecma402/#sec-intl.getcanonicallocales
    fn getCanonicalLocales(agent: *Agent, _: Value, arguments: Arguments) Agent.Error!Value {
        const locales = arguments.get(0);

        // 1. Let localeList be ? CanonicalizeLocaleList(locales).
        var locale_list = try canonicalizeLocaleList(agent, locales);
        defer locale_list.deinit(agent.gc_allocator);

        // 2. Return CreateArrayFromList(localeList).
        const array = try createArrayFromListMapToValue(agent, icu4zig.Locale, locale_list.items, struct {
            fn mapFn(agent_: *Agent, locale_: icu4zig.Locale) std.mem.Allocator.Error!Value {
                return Value.from(
                    try String.fromAscii(agent_, try locale_.toString(agent_.gc_allocator)),
                );
            }
        }.mapFn);
        return Value.from(&array.object);
    }

    /// 8.3.2 Intl.supportedValuesOf ( key )
    /// https://tc39.es/ecma402/#sec-intl.supportedvaluesof
    fn supportedValuesOf(agent: *Agent, _: Value, arguments: Arguments) Agent.Error!Value {
        // 1. Set key to ? ToString(key).
        const key_string = try arguments.get(0).toString(agent);

        const Key = enum {
            calendar,
            collation,
            currency,
            numbering_system,
            time_zone,
            unit,
        };
        const key_map = std.StaticStringMap(Key).initComptime(&.{
            .{ "calendar", .calendar },
            .{ "collation", .collation },
            .{ "currency", .currency },
            .{ "numberingSystem", .numbering_system },
            .{ "timeZone", .time_zone },
            .{ "unit", .unit },
        });
        const key = blk: {
            switch (key_string.asAsciiOrUtf16()) {
                .ascii => |key_ascii| if (key_map.get(key_ascii)) |key| break :blk key,
                .utf16 => {},
            }
            return agent.throwException(.range_error, "Invalid key '{f}'", .{key_string.fmtEscaped()});
        };

        const list = switch (key) {
            // 2. If key is "calendar", then
            .calendar => blk: {
                // a. Let list be a new empty List.
                // b. For each element identifier of AvailableCalendars(), do
                //     i. Let canonical be CanonicalizeUValue("ca", identifier).
                //     ii. If identifier is canonical, then
                //         1. Append identifier to list.
                break :blk availableCalendars();
            },
            // 3. Else if key is "collation", then
            .collation => blk: {
                // a. Let list be AvailableCanonicalCollations( ).
                break :blk availableCanonicalCollations();
            },
            // 4. Else if key is "currency", then
            .currency => blk: {
                // a. Let list be AvailableCanonicalCurrencies( ).
                break :blk availableCanonicalCurrencies();
            },
            // 5. Else if key is "numberingSystem", then
            .numbering_system => blk: {
                // a. Let list be AvailableCanonicalNumberingSystems( ).
                break :blk availableCanonicalNumberingSystems();
            },
            // 6. Else if key is "timeZone", then
            .time_zone => blk: {
                // a. Let list be AvailablePrimaryTimeZoneIdentifiers( ).
                break :blk try availablePrimaryTimeZoneIdentifiers(agent);
            },
            // 7. Else if key is "unit", then
            .unit => blk: {
                // a. Let list be AvailableCanonicalUnits( ).
                break :blk availableCanonicalUnits();
            },
            // 8. Else,
            //     a. Throw a RangeError exception.
        };
        defer switch (key) {
            .time_zone => agent.gc_allocator.free(list),
            else => {},
        };

        // 9. Return CreateArrayFromList( list ).
        const array = try createArrayFromListMapToValue(agent, *const String, list, struct {
            fn mapFn(_: *Agent, string: *const String) std.mem.Allocator.Error!Value {
                return Value.from(string);
            }
        }.mapFn);
        return Value.from(&array.object);
    }
};
