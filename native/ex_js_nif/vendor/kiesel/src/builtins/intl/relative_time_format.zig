//! 18 RelativeTimeFormat Objects
//! https://tc39.es/ecma402/#relativetimeformat-objects

const std = @import("std");

const icu4zig = @import("icu4zig");

const abstract_operations = @import("abstract_operations.zig");
const builtins = @import("../../builtins.zig");
const execution = @import("../../execution.zig");
const types = @import("../../types.zig");

const Agent = execution.Agent;
const Arguments = types.Arguments;
const MakeObject = types.MakeObject;
const Number = types.Number;
const Object = types.Object;
const PropertyKey = types.PropertyKey;
const Realm = execution.Realm;
const String = types.String;
const Value = types.Value;
const createBuiltinFunction = builtins.createBuiltinFunction;
const ordinaryCreateFromConstructor = builtins.ordinaryCreateFromConstructor;
const ordinaryObjectCreate = builtins.ordinaryObjectCreate;
const resolveOptions = abstract_operations.resolveOptions;

/// 18.2 Properties of the Intl.RelativeTimeFormat Constructor
/// https://tc39.es/ecma402/#sec-properties-of-intl-relativetimeformat-constructor
pub const constructor = struct {
    pub fn create(agent: *Agent, realm: *Realm) std.mem.Allocator.Error!*Object {
        const builtin_function = try createBuiltinFunction(
            agent,
            .{ .constructor = impl },
            0,
            "RelativeTimeFormat",
            .{ .realm = realm, .proto = try realm.intrinsic(.function_prototype) },
        );
        return &builtin_function.object;
    }

    pub fn init(agent: *Agent, realm: *Realm, object: *Object) std.mem.Allocator.Error!void {
        // 18.2.1 Intl.RelativeTimeFormat.prototype
        // https://tc39.es/ecma402/#sec-Intl.RelativeTimeFormat.prototype
        try object.defineBuiltinPropertyWithAttributes(
            agent,
            "prototype",
            Value.from(try realm.intrinsic(.intl_relative_time_format_prototype)),
            .none,
        );
    }

    /// 18.1.1 Intl.RelativeTimeFormat ( [ locales [ , options ] ] )
    /// https://tc39.es/ecma402/#sec-Intl.RelativeTimeFormat
    fn impl(agent: *Agent, arguments: Arguments, maybe_new_target: ?*Object) Agent.Error!Value {
        const locales = arguments.get(0);
        const options_value = arguments.get(1);

        // 1. If NewTarget is undefined, throw a TypeError exception.
        const new_target = maybe_new_target orelse {
            return agent.throwException(
                .type_error,
                "Intl.RelativeTimeFormat must be constructed with 'new'",
                .{},
            );
        };

        // 2. Let relativeTimeFormat be ? OrdinaryCreateFromConstructor(NewTarget,
        //    "%Intl.RelativeTimeFormat.prototype%", « [[InitializedRelativeTimeFormat]],
        //    [[Locale]], [[LocaleData]], [[Style]], [[Numeric]], [[NumberFormat]],
        //    [[NumberingSystem]], [[PluralRules]] »).
        const relative_time_format = try ordinaryCreateFromConstructor(
            RelativeTimeFormat,
            agent,
            new_target,
            .intl_relative_time_format_prototype,
            .{
                .locale = undefined,
                .style = undefined,
                .numeric = undefined,
                .numbering_system = undefined,
            },
        );

        // 3. Let optionsResolution be ? ResolveOptions(%Intl.RelativeTimeFormat%,
        //    %Intl.RelativeTimeFormat%.[[LocaleData]], locales, options, « coerce-options »).
        const options_resolution = try resolveOptions(
            agent,
            &.{
                .{ .key = "nu", .property = "numberingSystem" },
            },
            locales,
            options_value,
            .{ .coerce_options = true },
        );

        // 4. Set options to optionsResolution.[[Options]].
        const options = options_resolution.options;

        // 5. Let resolvedLocale be optionsResolution.[[ResolvedLocale]].
        const resolved_locale = options_resolution.resolved_locale;

        // 6. Let locale be resolvedLocale.[[Locale]].
        const locale = resolved_locale.locale;

        // 7. Set relativeTimeFormat.[[Locale]] to locale.
        // 8. Set relativeTimeFormat.[[LocaleData]] to resolvedLocale.[[LocaleData]].
        relative_time_format.fields.locale = locale;

        // 9. Set relativeTimeFormat.[[NumberingSystem]] to resolvedLocale.[[nu]].
        const numbering_system = if (try locale.getUnicodeExtension(agent.gc_allocator, "nu")) |nu|
            try String.fromAscii(agent, nu)
        else
            resolved_locale.options.nu orelse String.fromLiteral("latn");
        relative_time_format.fields.numbering_system = numbering_system;

        // 10. Let style be ? GetOption(options, "style", string, « "long", "short", "narrow" »,
        //     "long").
        const style_string = try options.getOption(
            agent,
            "style",
            .string,
            &.{
                String.fromLiteral("long"),
                String.fromLiteral("short"),
                String.fromLiteral("narrow"),
            },
            String.fromLiteral("long"),
        );
        const style = std.StaticStringMap(RelativeTimeFormat.Fields.Style).initComptime(&.{
            .{ "long", .long },
            .{ "short", .short },
            .{ "narrow", .narrow },
        }).get(style_string.asAscii()).?;

        // 11. Set relativeTimeFormat.[[Style]] to style.
        relative_time_format.fields.style = style;

        // 12. Let numeric be ? GetOption(options, "numeric", string, « "always", "auto" »,
        //     "always").
        const numeric_string = try options.getOption(
            agent,
            "numeric",
            .string,
            &.{
                String.fromLiteral("always"),
                String.fromLiteral("auto"),
            },
            String.fromLiteral("always"),
        );
        const numeric = std.StaticStringMap(RelativeTimeFormat.Fields.Numeric).initComptime(&.{
            .{ "always", .always },
            .{ "auto", .auto },
        }).get(numeric_string.asAscii()).?;

        // 13. Set relativeTimeFormat.[[Numeric]] to numeric.
        relative_time_format.fields.numeric = numeric;

        // 14. Let nfOptions be OrdinaryObjectCreate(null).
        // 15. Perform ! CreateDataPropertyOrThrow(nfOptions, "numberingSystem",
        //     relativeTimeFormat.[[NumberingSystem]]).
        // 16. Let relativeTimeFormat.[[NumberFormat]] be ! Construct(%Intl.NumberFormat%, « locale,
        //     nfOptions »).
        // 17. Let relativeTimeFormat.[[PluralRules]] be ! Construct(%Intl.PluralRules%,
        //     « locale »).

        // 18. Return relativeTimeFormat.
        return Value.from(&relative_time_format.object);
    }
};

/// 18.3 Properties of the Intl.RelativeTimeFormat Prototype Object
/// https://tc39.es/ecma402/#sec-properties-of-intl-relativetimeformat-prototype-object
pub const prototype = struct {
    pub fn create(agent: *Agent, realm: *Realm) std.mem.Allocator.Error!*Object {
        return ordinaryObjectCreate(agent, try realm.intrinsic(.object_prototype));
    }

    pub fn init(agent: *Agent, realm: *Realm, object: *Object) std.mem.Allocator.Error!void {
        try object.defineBuiltinFunction(agent, "resolvedOptions", resolvedOptions, 0, realm);
        try object.defineBuiltinFunction(agent, "format", format, 2, realm);

        // 18.3.1 Intl.RelativeTimeFormat.prototype.constructor
        // https://tc39.es/ecma402/#sec-Intl.RelativeTimeFormat.prototype.constructor
        try object.defineBuiltinProperty(
            agent,
            "constructor",
            Value.from(try realm.intrinsic(.intl_relative_time_format)),
        );

        // 18.3.5 Intl.RelativeTimeFormat.prototype [ %Symbol.toStringTag% ]
        // https://tc39.es/ecma402/#sec-Intl.RelativeTimeFormat.prototype-toStringTag
        try object.defineBuiltinPropertyWithAttributes(
            agent,
            "Symbol.toStringTag",
            Value.from("Intl.RelativeTimeFormat"),
            .{
                .writable = false,
                .enumerable = false,
                .configurable = true,
            },
        );
    }

    /// 18.3.2 Intl.RelativeTimeFormat.prototype.resolvedOptions ( )
    /// https://tc39.es/ecma402/#sec-intl.relativetimeformat.prototype.resolvedoptions
    fn resolvedOptions(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        const realm = agent.currentRealm();

        // 1. Let relativeTimeFormat be the this value.
        // 2. Perform ? RequireInternalSlot(relativeTimeFormat, [[InitializedRelativeTimeFormat]]).
        const relative_time_format = try this_value.requireInternalSlot(agent, RelativeTimeFormat);

        // 3. Let options be OrdinaryObjectCreate(%Object.prototype%).
        const options = try ordinaryObjectCreate(
            agent,
            try realm.intrinsic(.object_prototype),
        );

        // 4. For each row of Table 33, except the header row, in table order, do
        //     a. Let propertyKey be the Property value of the current row.
        //     b. Let value be the value of relativeTimeFormat's internal slot whose name is the
        //        Internal Slot value of the current row.
        //     c. Assert: value is not undefined.
        //     d. Perform ! CreateDataPropertyOrThrow(options, propertyKey, value).
        const resolved_options = relative_time_format.fields.resolvedOptions();
        try options.createDataPropertyDirect(
            agent,
            PropertyKey.from("locale"),
            Value.from(
                try String.fromAscii(
                    agent,
                    try relative_time_format.fields.locale.toString(agent.gc_allocator),
                ),
            ),
        );
        try options.createDataPropertyDirect(
            agent,
            PropertyKey.from("style"),
            Value.from(resolved_options.style),
        );
        try options.createDataPropertyDirect(
            agent,
            PropertyKey.from("numeric"),
            Value.from(resolved_options.numeric),
        );
        try options.createDataPropertyDirect(
            agent,
            PropertyKey.from("numberingSystem"),
            Value.from(resolved_options.numbering_system),
        );

        // 5. Return options.
        return Value.from(options);
    }

    /// 18.3.3 Intl.RelativeTimeFormat.prototype.format ( value, unit )
    /// https://tc39.es/ecma402/#sec-Intl.RelativeTimeFormat.prototype.format
    fn format(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const value_value = arguments.get(0);
        const unit_value = arguments.get(1);

        // 1. Let relativeTimeFormat be the this value.
        // 2. Perform ? RequireInternalSlot(relativeTimeFormat, [[InitializedRelativeTimeFormat]]).
        const relative_time_format = try this_value.requireInternalSlot(agent, RelativeTimeFormat);

        // 3. Set value to ? ToNumber(value).
        const value = try value_value.toNumber(agent);

        // 4. Set unit to ? ToString(unit).
        const unit = try unit_value.toString(agent);

        // 5. Return ? FormatRelativeTime(relativeTimeFormat, value, unit).
        return formatRelativeTime(agent, relative_time_format, value, unit);
    }
};

/// 18.4 Properties of Intl.RelativeTimeFormat Instances
/// https://tc39.es/ecma402/#sec-properties-of-intl-relativetimeformat-instances
pub const RelativeTimeFormat = MakeObject(.{
    .Fields = struct {
        pub const Style = enum { long, short, narrow };
        pub const Numeric = enum { always, auto };

        /// [[Locale]]
        locale: icu4zig.Locale,

        /// [[Style]]
        style: Style,

        /// [[Numeric]]
        numeric: Numeric,

        /// [[NumberingSystem]]
        numbering_system: *const String,

        // TODO: [[NumberFormat]], [[PluralRules]]

        pub const ResolvedOptions = struct {
            style: *const String,
            numeric: *const String,
            numbering_system: *const String,
        };

        pub fn resolvedOptions(self: @This()) ResolvedOptions {
            return .{
                .style = switch (self.style) {
                    .long => String.fromLiteral("long"),
                    .short => String.fromLiteral("short"),
                    .narrow => String.fromLiteral("narrow"),
                },
                .numeric = switch (self.numeric) {
                    .always => String.fromLiteral("always"),
                    .auto => String.fromLiteral("auto"),
                },
                .numbering_system = self.numbering_system,
            };
        }
    },
    .tag = .intl_relative_time_format,
    .display_name = "Intl.RelativeTimeFormat",
});

const SingularRelativeTimeUnit = enum {
    second,
    minute,
    hour,
    day,
    week,
    month,
    quarter,
    year,
};

/// 18.5.1 SingularRelativeTimeUnit ( unit )
/// https://tc39.es/ecma402/#sec-singularrelativetimeunit
fn singularRelativeTimeUnit(
    agent: *Agent,
    unit_string: *const String,
) Agent.Error!SingularRelativeTimeUnit {
    // 1. If unit is "seconds", return "second".
    // 2. If unit is "minutes", return "minute".
    // 3. If unit is "hours", return "hour".
    // 4. If unit is "days", return "day".
    // 5. If unit is "weeks", return "week".
    // 6. If unit is "months", return "month".
    // 7. If unit is "quarters", return "quarter".
    // 8. If unit is "years", return "year".
    // 9. If unit is not one of "second", "minute", "hour", "day", "week", "month", "quarter", or
    //    "year", throw a RangeError exception.
    // 10. Return unit.
    const unit_map = std.StaticStringMap(SingularRelativeTimeUnit).initComptime(&.{
        .{ "second", .second },
        .{ "seconds", .second },
        .{ "minute", .minute },
        .{ "minutes", .minute },
        .{ "hour", .hour },
        .{ "hours", .hour },
        .{ "day", .day },
        .{ "days", .day },
        .{ "week", .week },
        .{ "weeks", .week },
        .{ "month", .month },
        .{ "months", .month },
        .{ "quarter", .quarter },
        .{ "quarters", .quarter },
        .{ "year", .year },
        .{ "years", .year },
    });
    switch (unit_string.asAsciiOrUtf16()) {
        .ascii => |unit_ascii| if (unit_map.get(unit_ascii)) |unit| return unit,
        .utf16 => {},
    }
    return agent.throwException(.range_error, "Invalid unit '{f}'", .{unit_string.fmtEscaped()});
}

/// 18.5.4 FormatRelativeTime ( relativeTimeFormat, value, unit )
/// https://tc39.es/ecma402/#sec-FormatRelativeTime
fn formatRelativeTime(
    agent: *Agent,
    relative_time_format: *const RelativeTimeFormat,
    value_number: Number,
    unit_string: *const String,
) Agent.Error!Value {
    // 1. Let parts be ? PartitionRelativeTimePattern(relativeTimeFormat, value, unit).
    // 2. Let result be the empty String.
    // 3. For each Record { [[Type]], [[Value]], [[Unit]] } part of parts, do
    //     a. Set result to the string-concatenation of result and part.[[Value]].
    // 4. Return result.
    if (!value_number.isFinite()) {
        return agent.throwException(.range_error, "Value must be finite", .{});
    }
    const value = value_number.asFloat();
    const unit = try singularRelativeTimeUnit(agent, unit_string);
    // TODO: This is blocked on missing C APIs in ICU4X. https://github.com/unicode-org/icu4x/issues/802
    _ = relative_time_format;
    _ = value;
    _ = unit;
    return agent.throwException(.internal_error, "Duration formatting not implemented", .{});
}
