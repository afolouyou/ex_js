//! 17 PluralRules Objects
//! https://tc39.es/ecma402/#pluralrules-objects

const std = @import("std");

const icu4zig = @import("icu4zig");

const abstract_operations = @import("abstract_operations.zig");
const builtins = @import("../../builtins.zig");
const execution = @import("../../execution.zig");
const types = @import("../../types.zig");

const Agent = execution.Agent;
const Arguments = types.Arguments;
const IntlMathematicalValue = builtins.intl.number_format.IntlMathematicalValue;
const MakeObject = types.MakeObject;
const Object = types.Object;
const PropertyKey = types.PropertyKey;
const Realm = execution.Realm;
const String = types.String;
const Value = types.Value;
const createArrayFromList = types.createArrayFromList;
const createBuiltinFunction = builtins.createBuiltinFunction;
const ordinaryCreateFromConstructor = builtins.ordinaryCreateFromConstructor;
const ordinaryObjectCreate = builtins.ordinaryObjectCreate;
const resolveOptions = abstract_operations.resolveOptions;
const setNumberFormatDigitOptions = builtins.intl.number_format.constructor.setNumberFormatDigitOptions;
const toIntlMathematicalValue = builtins.intl.number_format.toIntlMathematicalValue;

/// 17.2 Properties of the Intl.PluralRules Constructor
/// https://tc39.es/ecma402/#sec-properties-of-intl-pluralrules-constructor
pub const constructor = struct {
    pub fn create(agent: *Agent, realm: *Realm) std.mem.Allocator.Error!*Object {
        const builtin_function = try createBuiltinFunction(
            agent,
            .{ .constructor = impl },
            0,
            "PluralRules",
            .{ .realm = realm, .proto = try realm.intrinsic(.function_prototype) },
        );
        return &builtin_function.object;
    }

    pub fn init(agent: *Agent, realm: *Realm, object: *Object) std.mem.Allocator.Error!void {
        // 17.2.1 Intl.PluralRules.prototype
        // https://tc39.es/ecma402/#sec-intl.pluralrules.prototype
        try object.defineBuiltinPropertyWithAttributes(
            agent,
            "prototype",
            Value.from(try realm.intrinsic(.intl_plural_rules_prototype)),
            .none,
        );
    }

    /// 17.1.1 Intl.PluralRules ( [ locales [ , options ] ] )
    /// https://tc39.es/ecma402/#sec-intl.pluralrules
    fn impl(agent: *Agent, arguments: Arguments, new_target: ?*Object) Agent.Error!Value {
        const locales = arguments.get(0);
        const options_value = arguments.get(1);

        // 1. If NewTarget is undefined, throw a TypeError exception.
        if (new_target == null) {
            return agent.throwException(
                .type_error,
                "Intl.PluralRules must be constructed with 'new'",
                .{},
            );
        }

        // 2. Let pluralRules be ? OrdinaryCreateFromConstructor(NewTarget,
        //    "%Intl.PluralRules.prototype%", « [[InitializedPluralRules]], [[Locale]], [[Type]],
        //    [[Notation]], [[CompactDisplay]], [[MinimumIntegerDigits]], [[MinimumFractionDigits]],
        //    [[MaximumFractionDigits]], [[MinimumSignificantDigits]], [[MaximumSignificantDigits]],
        //    [[RoundingType]], [[RoundingIncrement]], [[RoundingMode]],
        //    [[ComputedRoundingPriority]], [[TrailingZeroDisplay]] »).
        const plural_rules = try ordinaryCreateFromConstructor(
            PluralRules,
            agent,
            new_target.?,
            .intl_plural_rules_prototype,
            .{
                .locale = undefined,
                .type = undefined,
                .notation = undefined,
                .compact_display = null,
                .minimum_integer_digits = undefined,
                .minimum_fraction_digits = null,
                .maximum_fraction_digits = null,
                .minimum_significant_digits = null,
                .maximum_significant_digits = null,
                .rounding_type = undefined,
                .computed_rounding_priority = undefined,
                .rounding_increment = undefined,
                .rounding_mode = undefined,
                .trailing_zero_display = undefined,
            },
        );

        // 3. Let optionsResolution be ? ResolveOptions(%Intl.PluralRules%,
        //    %Intl.PluralRules%.[[LocaleData]], locales, options, « coerce-options »).
        const options_resolution = try resolveOptions(
            agent,
            &.{},
            locales,
            options_value,
            .{ .coerce_options = true },
        );

        // 4. Set options to optionsResolution.[[Options]].
        const options = options_resolution.options;

        // 5. Let resolvedLocale be optionsResolution.[[ResolvedLocale]].
        const resolved_locale = options_resolution.resolved_locale;
        const locale = resolved_locale.locale;

        // 6. Set pluralRules.[[Locale]] to resolvedLocale.[[Locale]].
        plural_rules.fields.locale = locale;

        // 7. Let type be ? GetOption(options, "type", string, « "cardinal", "ordinal" »,
        //    "cardinal").
        const type_string = try options.getOption(
            agent,
            "type",
            .string,
            &.{ String.fromLiteral("cardinal"), String.fromLiteral("ordinal") },
            String.fromLiteral("cardinal"),
        );
        const @"type" = std.StaticStringMap(PluralRules.Fields.Type).initComptime(&.{
            .{ "cardinal", .cardinal },
            .{ "ordinal", .ordinal },
        }).get(type_string.asAscii()).?;

        // 8. Set pluralRules.[[Type]] to type.
        plural_rules.fields.type = @"type";

        // 9. Let notation be ? GetOption(options, "notation", string, « "standard", "scientific",
        //    "engineering", "compact" », "standard").
        const notation_string = try options.getOption(
            agent,
            "notation",
            .string,
            &.{
                String.fromLiteral("standard"),
                String.fromLiteral("scientific"),
                String.fromLiteral("engineering"),
                String.fromLiteral("compact"),
            },
            String.fromLiteral("standard"),
        );
        const notation = std.StaticStringMap(PluralRules.Fields.Notation).initComptime(&.{
            .{ "standard", .standard },
            .{ "scientific", .scientific },
            .{ "engineering", .engineering },
            .{ "compact", .compact },
        }).get(notation_string.asAscii()).?;

        // 10. Set pluralRules.[[Notation]] to notation.
        plural_rules.fields.notation = notation;

        // 11. Let compactDisplay be ? GetOption(options, "compactDisplay", string, « "short",
        //     "long" », "short").
        const compact_display_string = try options.getOption(
            agent,
            "compactDisplay",
            .string,
            &.{ String.fromLiteral("short"), String.fromLiteral("long") },
            String.fromLiteral("short"),
        );
        const compact_display = std.StaticStringMap(
            PluralRules.Fields.CompactDisplay,
        ).initComptime(&.{
            .{ "short", .short },
            .{ "long", .long },
        }).get(compact_display_string.asAscii()).?;

        // 12. If notation is "compact", then
        if (notation == .compact) {
            // a. Set pluralRules.[[CompactDisplay]] to compactDisplay.
            plural_rules.fields.compact_display = compact_display;
        }

        // 13. Perform ? SetNumberFormatDigitOptions(pluralRules, options, 0, 3, notation).
        try setNumberFormatDigitOptions(
            PluralRules,
            agent,
            plural_rules,
            options,
            0,
            3,
            notation,
        );

        // 14. Return pluralRules.
        return Value.from(&plural_rules.object);
    }
};

/// 17.3 Properties of the Intl.PluralRules Prototype Object
/// https://tc39.es/ecma402/#sec-properties-of-intl-pluralrules-prototype-object
pub const prototype = struct {
    pub fn create(agent: *Agent, realm: *Realm) std.mem.Allocator.Error!*Object {
        return ordinaryObjectCreate(agent, try realm.intrinsic(.object_prototype));
    }

    pub fn init(agent: *Agent, realm: *Realm, object: *Object) std.mem.Allocator.Error!void {
        try object.defineBuiltinFunction(agent, "resolvedOptions", resolvedOptions, 0, realm);
        try object.defineBuiltinFunction(agent, "select", select, 1, realm);
        try object.defineBuiltinFunction(agent, "selectRange", selectRange, 2, realm);

        // 17.3.1 Intl.PluralRules.prototype.constructor
        // https://tc39.es/ecma402/#sec-intl.pluralrules.prototype.constructor
        try object.defineBuiltinProperty(
            agent,
            "constructor",
            Value.from(try realm.intrinsic(.intl_plural_rules)),
        );

        // 17.3.5 Intl.PluralRules.prototype [ %Symbol.toStringTag% ]
        // https://tc39.es/ecma402/#sec-intl.pluralrules.prototype-%symbol.tostringtag%
        try object.defineBuiltinPropertyWithAttributes(
            agent,
            "Symbol.toStringTag",
            Value.from("Intl.PluralRules"),
            .{
                .writable = false,
                .enumerable = false,
                .configurable = true,
            },
        );
    }

    /// 17.3.2 Intl.PluralRules.prototype.resolvedOptions ( )
    /// https://tc39.es/ecma402/#sec-intl.pluralrules.prototype.resolvedoptions
    fn resolvedOptions(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        const realm = agent.currentRealm();

        // 1. Let pr be the this value.
        // 2. Perform ? RequireInternalSlot(pr, [[InitializedPluralRules]]).
        const plural_rules = try this_value.requireInternalSlot(agent, PluralRules);

        // 3. Let options be OrdinaryObjectCreate(%Object.prototype%).
        const options = try ordinaryObjectCreate(
            agent,
            try realm.intrinsic(.object_prototype),
        );

        // 4. Let pluralCategories be a List of Strings containing all possible results of
        //    PluralRuleSelect for the selected locale pr.[[Locale]], sorted according to the
        //    following order: "zero", "one", "two", "few", "many", "other".
        var plural_categories = blk: {
            const plural_rules_ = icu4zig.PluralRules.init(
                plural_rules.fields.locale,
                switch (plural_rules.fields.type) {
                    .cardinal => .cardinal,
                    .ordinal => .ordinal,
                },
            );
            defer plural_rules_.deinit();
            const plural_categories = plural_rules_.categories();
            var array_list: std.ArrayList(Value) = .empty;
            if (plural_categories.zero) try array_list.append(agent.gc_allocator, Value.from("zero"));
            if (plural_categories.one) try array_list.append(agent.gc_allocator, Value.from("one"));
            if (plural_categories.two) try array_list.append(agent.gc_allocator, Value.from("two"));
            if (plural_categories.few) try array_list.append(agent.gc_allocator, Value.from("few"));
            if (plural_categories.many) try array_list.append(agent.gc_allocator, Value.from("many"));
            if (plural_categories.other) try array_list.append(agent.gc_allocator, Value.from("other"));
            break :blk array_list;
        };
        defer plural_categories.deinit(agent.gc_allocator);

        // 5. For each row of Table 32, except the header row, in table order, do
        //     a. Let propertyKey be the Property value of the current row.
        //     b. If propertyKey is "pluralCategories", then
        //         i. Let value be CreateArrayFromList(pluralCategories).
        //     c. Else,
        //         i. Let value be the value of pr's internal slot whose name is the Internal Slot
        //            value of the current row.
        //     d. If value is not undefined, then
        //         i. If there is a Conversion value in the current row, then
        //             1. Assert: The Conversion value of the current row is number.
        //             2. Set value to 𝔽(value).
        //         ii. Perform ! CreateDataPropertyOrThrow(options, propertyKey, value).
        const resolved_options = plural_rules.fields.resolvedOptions();
        try options.createDataPropertyDirect(
            agent,
            PropertyKey.from("locale"),
            Value.from(
                try String.fromAscii(
                    agent,
                    try plural_rules.fields.locale.toString(agent.gc_allocator),
                ),
            ),
        );
        try options.createDataPropertyDirect(
            agent,
            PropertyKey.from("type"),
            Value.from(resolved_options.type),
        );
        try options.createDataPropertyDirect(
            agent,
            PropertyKey.from("notation"),
            Value.from(resolved_options.notation),
        );
        if (resolved_options.compact_display) |compact_display| {
            try options.createDataPropertyDirect(
                agent,
                PropertyKey.from("compactDisplay"),
                Value.from(compact_display),
            );
        }
        const plural_categories_array = try createArrayFromList(agent, plural_categories.items);
        try options.createDataPropertyDirect(
            agent,
            PropertyKey.from("pluralCategories"),
            Value.from(&plural_categories_array.object),
        );

        // TODO: minimumIntegerDigits, minimumFractionDigits, maximumFractionDigits,
        //       minimumSignificantDigits, maximumSignificantDigits, roundingIncrement,
        //       roundingMode, roundingPriority, trailingZeroDisplay

        // 6. Return options.
        return Value.from(options);
    }

    /// 17.3.3 Intl.PluralRules.prototype.select ( value )
    /// https://tc39.es/ecma402/#sec-intl.pluralrules.prototype.select
    fn select(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const value = arguments.get(0);

        // 1. Let pr be the this value.
        // 2. Perform ? RequireInternalSlot(pr, [[InitializedPluralRules]]).
        const plural_rules = try this_value.requireInternalSlot(agent, PluralRules);

        // 3. Let n be ? ToIntlMathematicalValue(value).
        const n = try toIntlMathematicalValue(agent, value);
        defer n.deinit();

        // 4. Return ResolvePlural(pr, n).[[PluralCategory]].
        const plural_category = resolvePlural(plural_rules, n).plural_category;
        return Value.from(try String.fromAscii(agent, @tagName(plural_category)));
    }

    /// 17.3.4 Intl.PluralRules.prototype.selectRange ( start, end )
    /// https://tc39.es/ecma402/#sec-intl.pluralrules.prototype.selectrange
    fn selectRange(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const start = arguments.get(0);
        const end = arguments.get(1);

        // 1. Let pr be the this value.
        // 2. Perform ? RequireInternalSlot(pr, [[InitializedPluralRules]]).
        const plural_rules = try this_value.requireInternalSlot(agent, PluralRules);

        // 3. If start is undefined or end is undefined, throw a TypeError exception.
        if (start.isUndefined() or end.isUndefined()) {
            return agent.throwException(
                .type_error,
                "Plural range start and end must not be undefined",
                .{},
            );
        }

        // 4. Let x be ? ToIntlMathematicalValue(start).
        const x = try toIntlMathematicalValue(agent, start);
        defer x.deinit();

        // 5. Let y be ? ToIntlMathematicalValue(end).
        const y = try toIntlMathematicalValue(agent, end);
        defer y.deinit();

        // 6. Return ? ResolvePluralRange(pr, x, y).
        const plural_category = try resolvePluralRange(agent, plural_rules, x, y);
        return Value.from(try String.fromAscii(agent, @tagName(plural_category)));
    }
};

/// 17.4 Properties of Intl.PluralRules Instances
/// https://tc39.es/ecma402/#sec-properties-of-intl-pluralrules-instances
pub const PluralRules = MakeObject(.{
    .Fields = struct {
        pub const Type = enum { cardinal, ordinal };
        pub const Notation = enum { standard, scientific, engineering, compact };
        pub const CompactDisplay = enum { short, long };
        pub const RoundingType = enum { fraction_digits, significant_digits, more_precision, less_precision };
        pub const RoundingPriority = enum { auto, more_precision, less_precision };
        pub const RoundingIncrement = enum(u16) {
            @"1" = 1,
            @"2" = 2,
            @"5" = 5,
            @"10" = 10,
            @"20" = 20,
            @"25" = 25,
            @"50" = 50,
            @"100" = 100,
            @"200" = 200,
            @"250" = 250,
            @"500" = 500,
            @"1000" = 1000,
            @"2000" = 2000,
            @"2500" = 2500,
            @"5000" = 5000,
        };
        pub const RoundingMode = enum {
            ceil,
            floor,
            expand,
            trunc,
            half_ceil,
            half_floor,
            half_expand,
            half_trunc,
            half_even,
        };
        pub const TrailingZeroDisplay = enum { auto, strip_if_integer };

        /// [[Locale]]
        locale: icu4zig.Locale,

        /// [[Type]]
        type: Type,

        /// [[Notation]]
        notation: Notation,

        /// [[CompactDisplay]]
        compact_display: ?CompactDisplay,

        /// [[MinimumIntegerDigits]]
        minimum_integer_digits: u8,

        /// [[MinimumFractionDigits]]
        minimum_fraction_digits: ?u8,

        /// [[MaximumFractionDigits]]
        maximum_fraction_digits: ?u8,

        /// [[MinimumSignificantDigits]]
        minimum_significant_digits: ?u8,

        /// [[MaximumSignificantDigits]]
        maximum_significant_digits: ?u8,

        /// [[RoundingType]]
        rounding_type: RoundingType,

        /// [[ComputedRoundingPriority]]
        computed_rounding_priority: RoundingPriority,

        /// [[RoundingIncrement]]
        rounding_increment: RoundingIncrement,

        /// [[RoundingMode]]
        rounding_mode: RoundingMode,

        /// [[TrailingZeroDisplay]]
        trailing_zero_display: TrailingZeroDisplay,

        pub const ResolvedOptions = struct {
            type: *const String,
            notation: *const String,
            compact_display: ?*const String,
            minimum_integer_digits: u8,
            minimum_fraction_digits: ?u8,
            maximum_fraction_digits: ?u8,
            minimum_significant_digits: ?u8,
            maximum_significant_digits: ?u8,
            rounding_increment: u16,
            rounding_mode: *const String,
            rounding_priority: *const String,
            trailing_zero_display: *const String,
        };

        pub fn resolvedOptions(self: @This()) ResolvedOptions {
            return .{
                .type = switch (self.type) {
                    .cardinal => String.fromLiteral("cardinal"),
                    .ordinal => String.fromLiteral("ordinal"),
                },
                .notation = switch (self.notation) {
                    .standard => String.fromLiteral("standard"),
                    .scientific => String.fromLiteral("scientific"),
                    .engineering => String.fromLiteral("engineering"),
                    .compact => String.fromLiteral("compact"),
                },
                .compact_display = if (self.compact_display) |compact_display|
                    switch (compact_display) {
                        .short => String.fromLiteral("short"),
                        .long => String.fromLiteral("long"),
                    }
                else
                    null,
                .minimum_integer_digits = self.minimum_integer_digits,
                .minimum_fraction_digits = self.minimum_fraction_digits,
                .maximum_fraction_digits = self.maximum_fraction_digits,
                .minimum_significant_digits = self.minimum_significant_digits,
                .maximum_significant_digits = self.maximum_significant_digits,
                .rounding_increment = @backingInt(self.rounding_increment),
                .rounding_mode = switch (self.rounding_mode) {
                    .ceil => String.fromLiteral("ceil"),
                    .floor => String.fromLiteral("floor"),
                    .expand => String.fromLiteral("expand"),
                    .trunc => String.fromLiteral("trunc"),
                    .half_ceil => String.fromLiteral("halfCeil"),
                    .half_floor => String.fromLiteral("halfFloor"),
                    .half_expand => String.fromLiteral("halfExpand"),
                    .half_trunc => String.fromLiteral("halfTrunc"),
                    .half_even => String.fromLiteral("halfEven"),
                },
                .rounding_priority = switch (self.computed_rounding_priority) {
                    .auto => String.fromLiteral("auto"),
                    .more_precision => String.fromLiteral("morePrecision"),
                    .less_precision => String.fromLiteral("lessPrecision"),
                },
                .trailing_zero_display = switch (self.trailing_zero_display) {
                    .auto => String.fromLiteral("auto"),
                    .strip_if_integer => String.fromLiteral("stripIfInteger"),
                },
            };
        }
    },
    .tag = .intl_plural_rules,
    .display_name = "Intl.PluralRules",
});

/// 17.5.2 ResolvePlural ( pluralRules, n )
/// https://tc39.es/ecma402/#sec-resolveplural
pub fn resolvePlural(plural_rules_object: *const PluralRules, n: IntlMathematicalValue) struct {
    /// [[PluralCategory]]
    plural_category: icu4zig.PluralRules.PluralCategory,

    // TODO: [[FormattedString]]
} {
    const decimal = switch (n) {
        // 1. If n is not-a-number, then
        //     a. Let formattedString be an ILD String value indicating the NaN value.
        //     b. Return the Record { [[PluralCategory]]: "other",
        //        [[FormattedString]]: formattedString }.
        // 2. If n is positive-infinity, then
        //     a. Let formattedString be an ILD String value indicating positive infinity.
        //     b. Return the Record { [[PluralCategory]]: "other",
        //        [[FormattedString]]: formattedString }.
        // 3. If n is negative-infinity, then
        //     a. Let formattedString be an ILD String value indicating negative infinity.
        //     b. Return the Record { [[PluralCategory]]: "other",
        //        [[FormattedString]]: formattedString }.
        .not_a_number, .positive_infinity, .negative_infinity => {
            return .{ .plural_category = .other };
        },
        .negative_zero => icu4zig.Decimal.fromDoubleWithRoundTripPrecision(-0.0) catch unreachable,
        .mathematical_value => |decimal| decimal,
    };
    defer if (n == .negative_zero) decimal.deinit();

    // TODO: 4. Let res be FormatNumericToString(pluralRules, n).
    // TODO: 5. Let formattedString be res.[[FormattedString]].

    // 6. Let locale be pluralRules.[[Locale]].
    const locale = plural_rules_object.fields.locale;

    // 7. Let type be pluralRules.[[Type]].
    const @"type" = plural_rules_object.fields.type;

    // 8. Let notation be pluralRules.[[Notation]].
    const notation = plural_rules_object.fields.notation;

    // 9. Let compactDisplay be pluralRules.[[CompactDisplay]].
    const compact_display = plural_rules_object.fields.compact_display;

    // 10. Let pluralCategory be PluralRuleSelect(locale, type, notation, compactDisplay,
    //     formattedString).
    // TODO: Use these once ICU4X supports it.
    _ = notation;
    _ = compact_display;
    const plural_rules = icu4zig.PluralRules.init(locale, switch (@"type") {
        .cardinal => .cardinal,
        .ordinal => .ordinal,
    });
    defer plural_rules.deinit();
    const plural_category = plural_rules.categoryFor(decimal);

    // 11. Return the Record { [[PluralCategory]]: pluralCategory,
    //     [[FormattedString]]: formattedString }.
    return .{ .plural_category = plural_category };
}

/// 17.5.4 ResolvePluralRange ( pluralRules, x, y )
/// https://tc39.es/ecma402/#sec-resolvepluralrange
fn resolvePluralRange(
    agent: *Agent,
    plural_rules_object: *const PluralRules,
    x: IntlMathematicalValue,
    y: IntlMathematicalValue,
) Agent.Error!icu4zig.PluralRules.PluralCategory {
    // 1. If x is not-a-number or y is not-a-number, throw a RangeError exception.
    const decimal_x = switch (x) {
        .not_a_number => {
            return agent.throwException(
                .range_error,
                "Plural range start and end must be a number",
                .{},
            );
        },
        .positive_infinity, .negative_infinity => return .other,
        .negative_zero => icu4zig.Decimal.fromDoubleWithRoundTripPrecision(-0.0) catch unreachable,
        .mathematical_value => |decimal| decimal,
    };
    defer if (x == .negative_zero) decimal_x.deinit();

    const decimal_y = switch (y) {
        .not_a_number => {
            return agent.throwException(
                .range_error,
                "Plural range start and end must be a number",
                .{},
            );
        },
        .positive_infinity, .negative_infinity => return .other,
        .negative_zero => icu4zig.Decimal.fromDoubleWithRoundTripPrecision(-0.0) catch unreachable,
        .mathematical_value => |decimal| decimal,
    };
    defer if (y == .negative_zero) decimal_y.deinit();

    // 2. Let xResult be ResolvePlural(pluralRules, x).
    // 3. Let yResult be ResolvePlural(pluralRules, y).
    // 4. If xResult.[[FormattedString]] is yResult.[[FormattedString]], then
    //     a. Return xResult.[[PluralCategory]].

    // 5. Let locale be pluralRules.[[Locale]].
    const locale = plural_rules_object.fields.locale;

    // 6. Let type be pluralRules.[[Type]].
    const @"type" = plural_rules_object.fields.type;

    // 7. Let notation be pluralRules.[[Notation]].
    const notation = plural_rules_object.fields.notation;

    // 8. Let compactDisplay be pluralRules.[[CompactDisplay]].
    const compact_display = plural_rules_object.fields.compact_display;

    // 9. Return PluralRuleSelectRange(locale, type, notation, compactDisplay,
    //    xResult.[[PluralCategory]], yResult.[[PluralCategory]]).
    // TODO: Use these once ICU4X supports it.
    _ = notation;
    _ = compact_display;
    const plural_rules_with_ranges = icu4zig.PluralRulesWithRanges.init(locale, switch (@"type") {
        .cardinal => .cardinal,
        .ordinal => .ordinal,
    });
    defer plural_rules_with_ranges.deinit();
    return plural_rules_with_ranges.categoryForRange(decimal_x, decimal_y);
}
