//! 16 NumberFormat Objects
//! https://tc39.es/ecma402/#numberformat-objects

const std = @import("std");

const icu4zig = @import("icu4zig");

const abstract_operations = @import("abstract_operations.zig");
const build_options = @import("build-options");
const builtins = @import("../../builtins.zig");
const execution = @import("../../execution.zig");
const types = @import("../../types.zig");

const Agent = execution.Agent;
const Arguments = types.Arguments;
const MakeObject = types.MakeObject;
const Object = types.Object;
const PropertyKey = types.PropertyKey;
const Realm = execution.Realm;
const String = types.String;
const Value = types.Value;
const createBuiltinFunction = builtins.createBuiltinFunction;
const defaultNumberOption = abstract_operations.defaultNumberOption;
const getBooleanOrStringNumberFormatOption = abstract_operations.getBooleanOrStringNumberFormatOption;
const getNumberOption = abstract_operations.getNumberOption;
const isWellFormedCurrencyCode = abstract_operations.isWellFormedCurrencyCode;
const isWellFormedUnitIdentifier = abstract_operations.isWellFormedUnitIdentifier;
const ordinaryCreateFromConstructor = builtins.ordinaryCreateFromConstructor;
const ordinaryObjectCreate = builtins.ordinaryObjectCreate;
const resolveOptions = abstract_operations.resolveOptions;

/// 16.1.1.1 ChainNumberFormat ( numberFormat, newTarget, this )
/// https://tc39.es/ecma402/#sec-chainnumberformat
fn chainNumberFormat(
    agent: *Agent,
    number_format: *NumberFormat,
    new_target: ?*Object,
    this: ?Value,
) Agent.Error!Value {
    const realm = agent.currentRealm();

    // 1. If newTarget is undefined and ? OrdinaryHasInstance(%Intl.NumberFormat%, this) is true,
    //    then
    if (new_target == null and
        try Value.from(try realm.intrinsic(.intl_number_format)).ordinaryHasInstance(
            agent,
            this.?,
        ))
    {
        // a. Perform ? DefinePropertyOrThrow(this, %Intl%.[[FallbackSymbol]], PropertyDescriptor {
        //    [[Value]]: numberFormat, [[Writable]]: false, [[Enumerable]]: false,
        //    [[Configurable]]: false }).
        try this.?.asObject().definePropertyOrThrow(
            agent,
            PropertyKey.from(try realm.intrinsic(.intl_fallback_symbol)),
            .{
                .value = Value.from(&number_format.object),
                .writable = false,
                .enumerable = false,
                .configurable = false,
            },
        );

        // b. Return this.
        return this.?;
    }

    // 2. Return numberFormat.
    return Value.from(&number_format.object);
}

/// 16.2 Properties of the Intl.NumberFormat Constructor
/// https://tc39.es/ecma402/#sec-properties-of-intl-numberformat-constructor
pub const constructor = struct {
    pub fn create(agent: *Agent, realm: *Realm) std.mem.Allocator.Error!*Object {
        const builtin_function = try createBuiltinFunction(
            agent,
            .{ .constructor_with_this = impl },
            0,
            "NumberFormat",
            .{ .realm = realm, .proto = try realm.intrinsic(.function_prototype) },
        );
        return &builtin_function.object;
    }

    pub fn init(agent: *Agent, realm: *Realm, object: *Object) std.mem.Allocator.Error!void {
        // 16.2.1 Intl.NumberFormat.prototype
        // https://tc39.es/ecma402/#sec-intl.numberformat.prototype
        try object.defineBuiltinPropertyWithAttributes(
            agent,
            "prototype",
            Value.from(try realm.intrinsic(.intl_number_format_prototype)),
            .none,
        );
    }

    /// 16.1.1 Intl.NumberFormat ( [ locales [ , options ] ] )
    /// https://tc39.es/ecma402/#sec-intl.numberformat
    fn impl(
        agent: *Agent,
        this_value: ?Value,
        arguments: Arguments,
        maybe_new_target: ?*Object,
    ) Agent.Error!Value {
        const locales = arguments.get(0);
        const options_value = arguments.get(1);

        // 1. If NewTarget is undefined, let newTarget be the active function object, else let
        //    newTarget be NewTarget.
        const new_target = maybe_new_target orelse agent.activeFunctionObject();

        // 2. Let numberFormat be ? OrdinaryCreateFromConstructor(newTarget,
        //    "%Intl.NumberFormat.prototype%", « [[InitializedNumberFormat]], [[Locale]],
        //    [[LocaleData]], [[NumberingSystem]], [[Style]], [[Unit]], [[UnitDisplay]],
        //    [[Currency]], [[CurrencyDisplay]], [[CurrencySign]], [[MinimumIntegerDigits]],
        //    [[MinimumFractionDigits]], [[MaximumFractionDigits]], [[MinimumSignificantDigits]],
        //    [[MaximumSignificantDigits]], [[RoundingType]], [[Notation]], [[CompactDisplay]],
        //    [[UseGrouping]], [[SignDisplay]], [[RoundingIncrement]], [[RoundingMode]],
        //    [[ComputedRoundingPriority]], [[TrailingZeroDisplay]], [[BoundFormat]] »).
        const number_format = try ordinaryCreateFromConstructor(
            NumberFormat,
            agent,
            new_target,
            .intl_number_format_prototype,
            .{
                .locale = undefined,
                .numbering_system = undefined,
                .style = undefined,
                .currency = null,
                .currency_display = null,
                .currency_sign = null,
                .unit = null,
                .unit_display = null,
                .minimum_integer_digits = undefined,
                .minimum_fraction_digits = null,
                .maximum_fraction_digits = null,
                .minimum_significant_digits = null,
                .maximum_significant_digits = null,
                .use_grouping = undefined,
                .rounding_type = undefined,
                .computed_rounding_priority = undefined,
                .notation = undefined,
                .compact_display = null,
                .sign_display = undefined,
                .rounding_increment = undefined,
                .rounding_mode = undefined,
                .trailing_zero_display = undefined,
                .bound_format = null,
            },
        );

        // 3. Let optionsResolution be ? ResolveOptions(%Intl.NumberFormat%,
        //    %Intl.NumberFormat%.[[LocaleData]], locales, options, « coerce-options »).
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
        const locale = resolved_locale.locale;

        // 6. Set numberFormat.[[Locale]] to resolvedLocale.[[Locale]].
        // 7. Set numberFormat.[[LocaleData]] to resolvedLocale.[[LocaleData]].
        number_format.fields.locale = locale;

        // 8. Set numberFormat.[[NumberingSystem]] to resolvedLocale.[[nu]].
        const numbering_system = if (try locale.getUnicodeExtension(agent.gc_allocator, "nu")) |nu|
            try String.fromAscii(agent, nu)
        else
            resolved_locale.options.nu orelse String.fromLiteral("latn");
        number_format.fields.numbering_system = numbering_system;

        // 9. Perform ? SetNumberFormatUnitOptions(numberFormat, options).
        try setNumberFormatUnitOptions(agent, number_format, options);

        // 10. Let style be numberFormat.[[Style]].
        const style = number_format.fields.style;

        // 11. Let notation be ? GetOption(options, "notation", string, « "standard", "scientific",
        //     "engineering", "compact" », "standard").
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
        const notation = std.StaticStringMap(NumberFormat.Fields.Notation).initComptime(&.{
            .{ "standard", .standard },
            .{ "scientific", .scientific },
            .{ "engineering", .engineering },
            .{ "compact", .compact },
        }).get(notation_string.asAscii()).?;

        // 12. Set numberFormat.[[Notation]] to notation.
        number_format.fields.notation = notation;

        var mnfd_default: u8 = undefined;
        var mxfd_default: u8 = undefined;

        // 13. If style is "currency" and notation is "standard", then
        if (style == .currency and number_format.fields.notation == .standard) {
            // a. Let currency be numberFormat.[[Currency]].
            const currency = number_format.fields.currency.?;

            // b. Let cDigits be CurrencyDigits(currency).
            const currency_digits = currencyDigits(currency);

            // c. Let mnfdDefault be cDigits.
            mnfd_default = currency_digits;

            // d. Let mxfdDefault be cDigits.
            mxfd_default = currency_digits;
        }
        // 14. Else,
        else {
            // a. Let mnfdDefault be 0.
            mnfd_default = 0;

            // b. If style is "percent", then
            if (style == .percent) {
                // i. Let mxfdDefault be 0.
                mxfd_default = 0;
            }
            // c. Else,
            else {
                // i. Let mxfdDefault be 3.
                mxfd_default = 3;
            }
        }

        // 15. Perform ? SetNumberFormatDigitOptions(numberFormat, options, mnfdDefault,
        //     mxfdDefault, notation).
        try setNumberFormatDigitOptions(
            NumberFormat,
            agent,
            number_format,
            options,
            mnfd_default,
            mxfd_default,
            notation,
        );

        // 16. Let compactDisplay be ? GetOption(options, "compactDisplay", string, « "short",
        //     "long" », "short").
        const compact_display_string = try options.getOption(
            agent,
            "compactDisplay",
            .string,
            &.{ String.fromLiteral("short"), String.fromLiteral("long") },
            String.fromLiteral("short"),
        );
        const compact_display = std.StaticStringMap(NumberFormat.Fields.CompactDisplay).initComptime(&.{
            .{ "short", .short },
            .{ "long", .long },
        }).get(compact_display_string.asAscii()).?;

        // 17. Let defaultUseGrouping be "auto".
        var default_use_grouping = String.fromLiteral("auto");

        // 18. If notation is "compact", then
        if (notation == .compact) {
            // a. Set numberFormat.[[CompactDisplay]] to compactDisplay.
            number_format.fields.compact_display = compact_display;

            // b. Set defaultUseGrouping to "min2".
            default_use_grouping = String.fromLiteral("min2");
        }

        // 19. NOTE: For historical reasons, the strings "true" and "false" are accepted and
        //     replaced with the default value.
        // 20. Let useGrouping be ? GetBooleanOrStringNumberFormatOption(options, "useGrouping",
        //     « "min2", "auto", "always", "true", "false" », defaultUseGrouping).
        var use_grouping_boolean_or_string = try getBooleanOrStringNumberFormatOption(
            agent,
            options,
            "useGrouping",
            &.{
                String.fromLiteral("min2"),
                String.fromLiteral("auto"),
                String.fromLiteral("always"),
                String.fromLiteral("true"),
                String.fromLiteral("false"),
            },
            default_use_grouping,
        );

        switch (use_grouping_boolean_or_string) {
            .string => |value| {
                // 21. If useGrouping is "true" or useGrouping is "false", set useGrouping to
                //     defaultUseGrouping.
                if (value.eql(String.fromLiteral("true")) or value.eql(String.fromLiteral("false"))) {
                    use_grouping_boolean_or_string = .{
                        .string = default_use_grouping,
                    };
                }
            },
            .bool => |value| {
                // 22. If useGrouping is true, set useGrouping to "always".
                use_grouping_boolean_or_string = .{
                    .string = if (value)
                        String.fromLiteral("always")
                    else
                        String.fromLiteral("false"),
                };
            },
        }

        const use_grouping = std.StaticStringMap(NumberFormat.Fields.UseGrouping).initComptime(&.{
            .{ "min2", .min2 },
            .{ "auto", .auto },
            .{ "always", .always },
            .{ "false", .false },
        }).get(use_grouping_boolean_or_string.string.asAscii()).?;

        // 23. Set numberFormat.[[UseGrouping]] to useGrouping.
        number_format.fields.use_grouping = use_grouping;

        // 24. Let signDisplay be ? GetOption(options, "signDisplay", string, « "auto", "never",
        //     "always", "exceptZero", "negative" », "auto").
        const sign_display_string = try options.getOption(
            agent,
            "signDisplay",
            .string,
            &.{
                String.fromLiteral("auto"),
                String.fromLiteral("never"),
                String.fromLiteral("always"),
                String.fromLiteral("exceptZero"),
                String.fromLiteral("negative"),
            },
            String.fromLiteral("auto"),
        );
        const sign_display = std.StaticStringMap(NumberFormat.Fields.SignDisplay).initComptime(&.{
            .{ "auto", .auto },
            .{ "never", .never },
            .{ "always", .always },
            .{ "exceptZero", .except_zero },
            .{ "negative", .negative },
        }).get(sign_display_string.asAscii()).?;

        // 25. Set numberFormat.[[SignDisplay]] to signDisplay.
        number_format.fields.sign_display = sign_display;

        // 26. If the implementation supports the normative optional constructor mode of 4.3 Note 1,
        //     then
        if (build_options.enable_annex_b) {
            // a. Let this be the this value.
            // b. Return ? ChainNumberFormat(numberFormat, NewTarget, this).
            return chainNumberFormat(agent, number_format, maybe_new_target, this_value);
        }

        // 27. Return numberFormat.
        return Value.from(&number_format.object);
    }

    /// 16.1.2 SetNumberFormatDigitOptions ( intlObj, options, mnfdDefault, mxfdDefault, notation )
    /// https://tc39.es/ecma402/#sec-setnumberformatdigitoptions
    pub fn setNumberFormatDigitOptions(
        comptime T: type,
        agent: *Agent,
        intl_obj: *T,
        options: *Object,
        mnfd_default: u8,
        mxfd_default_arg: u8,
        notation: T.Fields.Notation,
    ) Agent.Error!void {
        var mxfd_default = mxfd_default_arg;

        // 1. Let mnid be ? GetNumberOption(options, "minimumIntegerDigits", 1, 21, 1).
        const mnid = (try getNumberOption(agent, options, "minimumIntegerDigits", 1, 21, 1)).?;

        // 2. Let mnfd be ? Get(options, "minimumFractionDigits").
        const mnfd_value = try options.get(agent, PropertyKey.from("minimumFractionDigits"));

        // 3. Let mxfd be ? Get(options, "maximumFractionDigits").
        const mxfd_value = try options.get(agent, PropertyKey.from("maximumFractionDigits"));

        // 4. Let mnsd be ? Get(options, "minimumSignificantDigits").
        const mnsd_value = try options.get(agent, PropertyKey.from("minimumSignificantDigits"));

        // 5. Let mxsd be ? Get(options, "maximumSignificantDigits").
        const mxsd_value = try options.get(agent, PropertyKey.from("maximumSignificantDigits"));

        // 6. Set intlObj.[[MinimumIntegerDigits]] to mnid.
        intl_obj.fields.minimum_integer_digits = @intCast(mnid);

        // 7. Let roundingIncrement be ? GetNumberOption(options, "roundingIncrement", 1, 5000, 1).
        const rounding_increment_value = (try getNumberOption(agent, options, "roundingIncrement", 1, 5000, 1)).?;

        // 8. If roundingIncrement is not in « 1, 2, 5, 10, 20, 25, 50, 100, 200, 250, 500, 1000,
        //    2000, 2500, 5000 », throw a RangeError exception.
        const rounding_increment = std.enums.fromInt(
            T.Fields.RoundingIncrement,
            rounding_increment_value,
        ) orelse {
            return agent.throwException(
                .range_error,
                "Invalid value for option 'roundingIncrement'",
                .{},
            );
        };

        // 9. Let roundingMode be ? GetOption(options, "roundingMode", string, « "ceil", "floor",
        //    "expand", "trunc", "halfCeil", "halfFloor", "halfExpand", "halfTrunc", "halfEven" »,
        //    "halfExpand").
        const rounding_mode_string = try options.getOption(
            agent,
            "roundingMode",
            .string,
            &.{
                String.fromLiteral("ceil"),
                String.fromLiteral("floor"),
                String.fromLiteral("expand"),
                String.fromLiteral("trunc"),
                String.fromLiteral("halfCeil"),
                String.fromLiteral("halfFloor"),
                String.fromLiteral("halfExpand"),
                String.fromLiteral("halfTrunc"),
                String.fromLiteral("halfEven"),
            },
            String.fromLiteral("halfExpand"),
        );
        const rounding_mode = std.StaticStringMap(
            T.Fields.RoundingMode,
        ).initComptime(&.{
            .{ "ceil", .ceil },
            .{ "floor", .floor },
            .{ "expand", .expand },
            .{ "trunc", .trunc },
            .{ "halfCeil", .half_ceil },
            .{ "halfFloor", .half_floor },
            .{ "halfExpand", .half_expand },
            .{ "halfTrunc", .half_trunc },
            .{ "halfEven", .half_even },
        }).get(rounding_mode_string.asAscii()).?;

        // 10. Let roundingPriority be ? GetOption(options, "roundingPriority", string, « "auto",
        //     "morePrecision", "lessPrecision" », "auto").
        const rounding_priority_string = try options.getOption(
            agent,
            "roundingPriority",
            .string,
            &.{
                String.fromLiteral("auto"),
                String.fromLiteral("morePrecision"),
                String.fromLiteral("lessPrecision"),
            },
            String.fromLiteral("auto"),
        );
        const rounding_priority = std.StaticStringMap(
            T.Fields.RoundingPriority,
        ).initComptime(&.{
            .{ "auto", .auto },
            .{ "morePrecision", .more_precision },
            .{ "lessPrecision", .less_precision },
        }).get(rounding_priority_string.asAscii()).?;

        // 11. Let trailingZeroDisplay be ? GetOption(options, "trailingZeroDisplay", string,
        //     « "auto", "stripIfInteger" », "auto").
        const trailing_zero_display_string = try options.getOption(
            agent,
            "trailingZeroDisplay",
            .string,
            &.{ String.fromLiteral("auto"), String.fromLiteral("stripIfInteger") },
            String.fromLiteral("auto"),
        );
        const trailing_zero_display = std.StaticStringMap(
            T.Fields.TrailingZeroDisplay,
        ).initComptime(&.{
            .{ "auto", .auto },
            .{ "stripIfInteger", .strip_if_integer },
        }).get(trailing_zero_display_string.asAscii()).?;

        // 12. NOTE: All fields required by SetNumberFormatDigitOptions have now been read from
        //     options. The remainder of this AO interprets the options and may throw exceptions.

        // 13. If roundingIncrement is not 1, set mxfdDefault to mnfdDefault.
        if (rounding_increment != .@"1") mxfd_default = mnfd_default;

        // 14. Set intlObj.[[RoundingIncrement]] to roundingIncrement.
        intl_obj.fields.rounding_increment = rounding_increment;

        // 15. Set intlObj.[[RoundingMode]] to roundingMode.
        intl_obj.fields.rounding_mode = rounding_mode;

        // 16. Set intlObj.[[TrailingZeroDisplay]] to trailingZeroDisplay.
        intl_obj.fields.trailing_zero_display = trailing_zero_display;

        // 17. If mnsd is undefined and mxsd is undefined, let hasSd be false. Otherwise, let hasSd
        //     be true.
        const has_sd = if (mnsd_value.isUndefined() and mxsd_value.isUndefined()) false else true;

        // 18. If mnfd is undefined and mxfd is undefined, let hasFd be false. Otherwise, let hasFd
        //     be true.
        const has_fd = if (mnfd_value.isUndefined() and mxfd_value.isUndefined()) false else true;

        // 19. Let needSd be true.
        var need_sd = true;

        // 20. Let needFd be true.
        var need_fd = true;

        // 21. If roundingPriority is "auto", then
        if (rounding_priority == .auto) {
            // a. Set needSd to hasSd.
            need_sd = has_sd;

            // b. If needSd is true, or hasFd is false and notation is "compact", then
            if (need_sd or (!has_fd and notation == .compact)) {
                // i. Set needFd to false.
                need_fd = false;
            }
        }

        // 22. If needSd is true, then
        if (need_sd) {
            // a. If hasSd is true, then
            if (has_sd) {
                // i. Set intlObj.[[MinimumSignificantDigits]] to ? DefaultNumberOption(mnsd, 1, 21,
                //    1).
                intl_obj.fields.minimum_significant_digits = @intCast((try defaultNumberOption(
                    agent,
                    mnsd_value,
                    "minimumSignificantDigits",
                    1,
                    21,
                    1,
                )).?);

                // ii. Set intlObj.[[MaximumSignificantDigits]] to ? DefaultNumberOption(mxsd,
                //     intlObj.[[MinimumSignificantDigits]], 21, 21).
                intl_obj.fields.maximum_significant_digits = @intCast((try defaultNumberOption(
                    agent,
                    mxsd_value,
                    "maximumSignificantDigits",
                    intl_obj.fields.minimum_significant_digits.?,
                    21,
                    21,
                )).?);
            }
            // b. Else,
            else {
                // i. Set intlObj.[[MinimumSignificantDigits]] to 1.
                intl_obj.fields.minimum_significant_digits = 1;

                // ii. Set intlObj.[[MaximumSignificantDigits]] to 21.
                intl_obj.fields.maximum_significant_digits = 21;
            }
        }

        // 23. If needFd is true, then
        if (need_fd) {
            // a. If hasFd is true, then
            if (has_fd) {
                // i. Set mnfd to ? DefaultNumberOption(mnfd, 0, 100, undefined).
                const maybe_mnfd = try defaultNumberOption(
                    agent,
                    mnfd_value,
                    "minimumFractionDigits",
                    0,
                    100,
                    null,
                );

                // ii. Set mxfd to ? DefaultNumberOption(mxfd, 0, 100, undefined).
                const maybe_mxfd = try defaultNumberOption(
                    agent,
                    mxfd_value,
                    "maximumFractionDigits",
                    0,
                    100,
                    null,
                );

                // iii. If mnfd is undefined, set mnfd to min(mnfdDefault, mxfd).
                const mnfd: u8 = @intCast(maybe_mnfd orelse @min(mnfd_default, maybe_mxfd.?));

                // iv. Else if mxfd is undefined, set mxfd to max(mxfdDefault, mnfd).
                const mxfd: u8 = @intCast(maybe_mxfd orelse @max(mxfd_default, maybe_mnfd.?));

                // v. Else if mnfd is greater than mxfd, throw a RangeError exception.
                if (mnfd > mxfd) {
                    return agent.throwException(
                        .range_error,
                        "Value of option 'minimumFractionDigits' must not be greater than 'maximumFractionDigits'",
                        .{},
                    );
                }

                // vi. Set intlObj.[[MinimumFractionDigits]] to mnfd.
                intl_obj.fields.minimum_fraction_digits = mnfd;

                // vii. Set intlObj.[[MaximumFractionDigits]] to mxfd.
                intl_obj.fields.maximum_fraction_digits = mxfd;
            }
            // b. Else,
            else {
                // i. Set intlObj.[[MinimumFractionDigits]] to mnfdDefault.
                intl_obj.fields.minimum_fraction_digits = mnfd_default;

                // ii. Set intlObj.[[MaximumFractionDigits]] to mxfdDefault.
                intl_obj.fields.maximum_fraction_digits = mxfd_default;
            }
        }

        // 24. If needSd is false and needFd is false, then
        if (!need_sd and !need_fd) {
            // a. Set intlObj.[[MinimumFractionDigits]] to 0.
            intl_obj.fields.minimum_fraction_digits = 0;

            // b. Set intlObj.[[MaximumFractionDigits]] to 0.
            intl_obj.fields.maximum_fraction_digits = 0;

            // c. Set intlObj.[[MinimumSignificantDigits]] to 1.
            intl_obj.fields.minimum_significant_digits = 0;

            // d. Set intlObj.[[MaximumSignificantDigits]] to 2.
            intl_obj.fields.maximum_significant_digits = 0;

            // e. Set intlObj.[[RoundingType]] to more-precision.
            intl_obj.fields.rounding_type = .more_precision;

            // f. Set intlObj.[[ComputedRoundingPriority]] to "morePrecision".
            intl_obj.fields.computed_rounding_priority = .more_precision;
        }
        // 25. Else if roundingPriority is "morePrecision", then
        else if (rounding_priority == .more_precision) {
            // a. Set intlObj.[[RoundingType]] to more-precision.
            intl_obj.fields.rounding_type = .more_precision;

            // b. Set intlObj.[[ComputedRoundingPriority]] to "morePrecision".
            intl_obj.fields.computed_rounding_priority = .more_precision;
        }
        // 26. Else if roundingPriority is "lessPrecision", then
        else if (rounding_priority == .less_precision) {
            // a. Set intlObj.[[RoundingType]] to less-precision.
            intl_obj.fields.rounding_type = .less_precision;

            // b. Set intlObj.[[ComputedRoundingPriority]] to "lessPrecision".
            intl_obj.fields.computed_rounding_priority = .less_precision;
        }
        // 27. Else if hasSd is true, then
        else if (has_sd) {
            // a. Set intlObj.[[RoundingType]] to significant-digits.
            intl_obj.fields.rounding_type = .significant_digits;

            // b. Set intlObj.[[ComputedRoundingPriority]] to "auto".
            intl_obj.fields.computed_rounding_priority = .auto;
        }
        // 28. Else,
        else {
            // a. Set intlObj.[[RoundingType]] to fraction-digits.
            intl_obj.fields.rounding_type = .fraction_digits;

            // b. Set intlObj.[[ComputedRoundingPriority]] to "auto".
            intl_obj.fields.computed_rounding_priority = .auto;
        }

        // 29. If roundingIncrement is not 1, then
        if (rounding_increment != .@"1") {
            // a. If intlObj.[[RoundingType]] is not fraction-digits, throw a TypeError exception.
            if (intl_obj.fields.rounding_type != .fraction_digits) {
                return agent.throwException(
                    .type_error,
                    "Invalid value for option 'roundingIncrement'",
                    .{},
                );
            }

            // b. If intlObj.[[MaximumFractionDigits]] is not intlObj.[[MinimumFractionDigits]],
            //    throw a RangeError exception.
            if (intl_obj.fields.maximum_fraction_digits != intl_obj.fields.minimum_fraction_digits) {
                return agent.throwException(
                    .range_error,
                    "Options 'maximumFractionDigits' and 'minimumFractionDigits' must be equal",
                    .{},
                );
            }
        }

        // 30. Return unused.
    }

    /// 16.1.3 SetNumberFormatUnitOptions ( intlObj, options )
    /// https://tc39.es/ecma402/#sec-setnumberformatunitoptions
    fn setNumberFormatUnitOptions(agent: *Agent, number_format: *NumberFormat, options: *Object) Agent.Error!void {
        // 1. Let style be ? GetOption(options, "style", string, « "decimal", "percent", "currency",
        //    "unit" », "decimal").
        const style_string = try options.getOption(
            agent,
            "style",
            .string,
            &.{
                String.fromLiteral("decimal"),
                String.fromLiteral("percent"),
                String.fromLiteral("currency"),
                String.fromLiteral("unit"),
            },
            String.fromLiteral("decimal"),
        );
        const style = std.StaticStringMap(NumberFormat.Fields.Style).initComptime(&.{
            .{ "decimal", .decimal },
            .{ "percent", .percent },
            .{ "currency", .currency },
            .{ "unit", .unit },
        }).get(style_string.asAscii()).?;

        // 2. Set intlObj.[[Style]] to style.
        number_format.fields.style = style;

        // 3. Let currency be ? GetOption(options, "currency", string, empty, undefined).
        const currency = try options.getOption(agent, "currency", .string, null, null);

        // 4. If currency is undefined, then
        if (currency == null) {
            // a. If style is "currency", throw a TypeError exception.
            if (style == .currency) {
                return agent.throwException(.type_error, "Option 'currency' is required", .{});
            }
        }
        // 5. Else,
        else {
            // a. If IsWellFormedCurrencyCode(currency) is false, throw a RangeError exception.
            if (!isWellFormedCurrencyCode(currency.?)) {
                return agent.throwException(
                    .range_error,
                    "Invalid currency '{f}'",
                    .{currency.?.fmtEscaped()},
                );
            }
        }

        // 6. Let currencyDisplay be ? GetOption(options, "currencyDisplay", string, « "code",
        //    "symbol", "narrowSymbol", "name" », "symbol").
        const currency_display_string = try options.getOption(
            agent,
            "currencyDisplay",
            .string,
            &.{
                String.fromLiteral("code"),
                String.fromLiteral("symbol"),
                String.fromLiteral("narrowSymbol"),
                String.fromLiteral("name"),
            },
            String.fromLiteral("symbol"),
        );
        const currency_display = std.StaticStringMap(NumberFormat.Fields.CurrencyDisplay).initComptime(&.{
            .{ "code", .code },
            .{ "symbol", .symbol },
            .{ "narrowSymbol", .narrow_symbol },
            .{ "name", .name },
        }).get(currency_display_string.asAscii()).?;

        // 7. Let currencySign be ? GetOption(options, "currencySign", string, « "standard",
        //    "accounting" », "standard").
        const currency_sign_string = try options.getOption(
            agent,
            "currencySign",
            .string,
            &.{ String.fromLiteral("standard"), String.fromLiteral("accounting") },
            String.fromLiteral("standard"),
        );
        const currency_sign = std.StaticStringMap(NumberFormat.Fields.CurrencySign).initComptime(&.{
            .{ "standard", .standard },
            .{ "accounting", .accounting },
        }).get(currency_sign_string.asAscii()).?;

        // 8. Let unit be ? GetOption(options, "unit", string, empty, undefined).
        const unit = try options.getOption(agent, "unit", .string, null, null);

        // 9. If unit is undefined, then
        if (unit == null) {
            // a. If style is "unit", throw a TypeError exception.
            if (style == .unit) {
                return agent.throwException(.type_error, "Option 'unit' is required", .{});
            }
        }
        // 10. Else,
        else {
            // a. If IsWellFormedUnitIdentifier(unit) is false, throw a RangeError exception.
            if (!isWellFormedUnitIdentifier(unit.?)) {
                return agent.throwException(
                    .range_error,
                    "Invalid unit '{f}'",
                    .{unit.?.fmtEscaped()},
                );
            }
        }

        // 11. Let unitDisplay be ? GetOption(options, "unitDisplay", string, « "short", "narrow",
        //     "long" », "short").
        const unit_display_string = try options.getOption(
            agent,
            "unitDisplay",
            .string,
            &.{
                String.fromLiteral("short"),
                String.fromLiteral("narrow"),
                String.fromLiteral("long"),
            },
            String.fromLiteral("short"),
        );
        const unit_display = std.StaticStringMap(NumberFormat.Fields.UnitDisplay).initComptime(&.{
            .{ "short", .short },
            .{ "narrow", .narrow },
            .{ "long", .long },
        }).get(unit_display_string.asAscii()).?;

        // 12. If style is "currency", then
        if (style == .currency) {
            // a. Set intlObj.[[Currency]] to the ASCII-uppercase of currency.
            number_format.fields.currency = try currency.?.toUpperCaseAscii(agent);

            // b. Set intlObj.[[CurrencyDisplay]] to currencyDisplay.
            number_format.fields.currency_display = currency_display;

            // c. Set intlObj.[[CurrencySign]] to currencySign.
            number_format.fields.currency_sign = currency_sign;
        }

        // 13. If style is "unit", then
        if (style == .unit) {
            // a. Set intlObj.[[Unit]] to unit.
            number_format.fields.unit = unit;

            // b. Set intlObj.[[UnitDisplay]] to unitDisplay.
            number_format.fields.unit_display = unit_display;
        }

        // 14. Return unused.
    }
};

/// 16.3 Properties of the Intl.NumberFormat Prototype Object
/// https://tc39.es/ecma402/#sec-properties-of-intl-numberformat-prototype-object
pub const prototype = struct {
    pub fn create(agent: *Agent, realm: *Realm) std.mem.Allocator.Error!*Object {
        return ordinaryObjectCreate(agent, try realm.intrinsic(.object_prototype));
    }

    pub fn init(agent: *Agent, realm: *Realm, object: *Object) std.mem.Allocator.Error!void {
        try object.defineBuiltinFunction(agent, "resolvedOptions", resolvedOptions, 0, realm);
        try object.defineBuiltinAccessor(agent, "format", format, null, realm);
        try object.defineBuiltinFunction(agent, "formatRange", formatRange, 2, realm);

        // 16.3.1 Intl.NumberFormat.prototype.constructor
        // https://tc39.es/ecma402/#sec-intl.numberformat.prototype.constructor
        try object.defineBuiltinProperty(
            agent,
            "constructor",
            Value.from(try realm.intrinsic(.intl_number_format)),
        );

        // 16.3.7 Intl.NumberFormat.prototype [ %Symbol.toStringTag% ]
        // https://tc39.es/ecma402/#sec-intl.numberformat.prototype-%symbol.tostringtag%
        try object.defineBuiltinPropertyWithAttributes(
            agent,
            "Symbol.toStringTag",
            Value.from("Intl.NumberFormat"),
            .{
                .writable = false,
                .enumerable = false,
                .configurable = true,
            },
        );
    }

    /// 16.3.2 Intl.NumberFormat.prototype.resolvedOptions ( )
    /// https://tc39.es/ecma402/#sec-intl.numberformat.prototype.resolvedoptions
    fn resolvedOptions(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        const realm = agent.currentRealm();

        // 1. Let nf be the this value.
        // 2. If the implementation supports the normative optional constructor mode of 4.3 Note 1,
        //    then
        //     a. Set nf to ? UnwrapNumberFormat(nf).
        const number_format_value = if (build_options.enable_annex_b)
            try unwrapNumberFormat(agent, this_value)
        else
            this_value;

        // 3. Perform ? RequireInternalSlot(nf, [[InitializedNumberFormat]]).
        const number_format = try number_format_value.requireInternalSlot(agent, NumberFormat);

        // 4. Let options be OrdinaryObjectCreate(%Object.prototype%).
        const options = try ordinaryObjectCreate(
            agent,
            try realm.intrinsic(.object_prototype),
        );

        // 5. For each row of Table 28, except the header row, in table order, do
        // a. Let propertyKey be the Property value of the current row.
        // b. Let value be the value of nf's internal slot whose name is the Internal Slot value of
        //    the current row.
        // c. If value is not undefined, then
        //     i. If there is a Conversion value in the current row, then
        //             1. Assert: The Conversion value of the current row is number.
        //             2. Set value to 𝔽(value).
        //     ii. Perform ! CreateDataPropertyOrThrow(options, propertyKey, value).
        const resolved_options = number_format.fields.resolvedOptions();
        try options.createDataPropertyDirect(
            agent,
            PropertyKey.from("locale"),
            Value.from(
                try String.fromAscii(
                    agent,
                    try number_format.fields.locale.toString(agent.gc_allocator),
                ),
            ),
        );
        try options.createDataPropertyDirect(
            agent,
            PropertyKey.from("numberingSystem"),
            Value.from(resolved_options.numbering_system),
        );
        try options.createDataPropertyDirect(
            agent,
            PropertyKey.from("style"),
            Value.from(resolved_options.style),
        );
        if (resolved_options.currency) |currency| {
            try options.createDataPropertyDirect(
                agent,
                PropertyKey.from("currency"),
                Value.from(currency),
            );
        }
        if (resolved_options.currency_display) |currency_display| {
            try options.createDataPropertyDirect(
                agent,
                PropertyKey.from("currencyDisplay"),
                Value.from(currency_display),
            );
        }
        if (resolved_options.currency_sign) |currency_sign| {
            try options.createDataPropertyDirect(
                agent,
                PropertyKey.from("currencySign"),
                Value.from(currency_sign),
            );
        }
        if (resolved_options.unit) |unit| {
            try options.createDataPropertyDirect(
                agent,
                PropertyKey.from("unit"),
                Value.from(unit),
            );
        }
        if (resolved_options.unit_display) |unit_display| {
            try options.createDataPropertyDirect(
                agent,
                PropertyKey.from("unitDisplay"),
                Value.from(unit_display),
            );
        }
        try options.createDataPropertyDirect(
            agent,
            PropertyKey.from("minimumIntegerDigits"),
            Value.from(resolved_options.minimum_integer_digits),
        );
        if (resolved_options.minimum_fraction_digits) |minimum_fraction_digits| {
            try options.createDataPropertyDirect(
                agent,
                PropertyKey.from("minimumFractionDigits"),
                Value.from(minimum_fraction_digits),
            );
        }
        if (resolved_options.maximum_fraction_digits) |maximum_fraction_digits| {
            try options.createDataPropertyDirect(
                agent,
                PropertyKey.from("maximumFractionDigits"),
                Value.from(maximum_fraction_digits),
            );
        }
        if (resolved_options.minimum_significant_digits) |minimum_significant_digits| {
            try options.createDataPropertyDirect(
                agent,
                PropertyKey.from("minimumSignificantDigits"),
                Value.from(minimum_significant_digits),
            );
        }
        if (resolved_options.maximum_significant_digits) |maximum_significant_digits| {
            try options.createDataPropertyDirect(
                agent,
                PropertyKey.from("maximumSignificantDigits"),
                Value.from(maximum_significant_digits),
            );
        }
        try options.createDataPropertyDirect(
            agent,
            PropertyKey.from("useGrouping"),
            switch (resolved_options.use_grouping) {
                .false => .false,
                .string => |string| Value.from(string),
            },
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
        try options.createDataPropertyDirect(
            agent,
            PropertyKey.from("signDisplay"),
            Value.from(resolved_options.sign_display),
        );
        try options.createDataPropertyDirect(
            agent,
            PropertyKey.from("roundingIncrement"),
            Value.from(resolved_options.rounding_increment),
        );
        try options.createDataPropertyDirect(
            agent,
            PropertyKey.from("roundingMode"),
            Value.from(resolved_options.rounding_mode),
        );
        try options.createDataPropertyDirect(
            agent,
            PropertyKey.from("roundingPriority"),
            Value.from(resolved_options.rounding_priority),
        );
        try options.createDataPropertyDirect(
            agent,
            PropertyKey.from("trailingZeroDisplay"),
            Value.from(resolved_options.trailing_zero_display),
        );

        // 6. Return options.
        return Value.from(options);
    }

    /// 16.3.3 get Intl.NumberFormat.prototype.format
    /// https://tc39.es/ecma402/#sec-intl.numberformat.prototype.format
    fn format(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let nf be the this value.
        // 2. If the implementation supports the normative optional constructor mode of 4.3 Note 1,
        //    then
        //     a. Set nf to ? UnwrapNumberFormat(nf).
        const number_format_value = if (build_options.enable_annex_b)
            try unwrapNumberFormat(agent, this_value)
        else
            this_value;

        // 3. Perform ? RequireInternalSlot(nf, [[InitializedNumberFormat]]).
        const number_format = try number_format_value.requireInternalSlot(agent, NumberFormat);

        // 4. If nf.[[BoundFormat]] is undefined, then
        if (number_format.fields.bound_format == null) {
            // a. Let func be a new built-in function object as defined in Number Format Functions
            //    (16.5.2).
            // b. Set func.[[NumberFormat]] to nf.
            const Captures = struct {
                number_format: *NumberFormat,
            };
            const captures = try agent.gc_allocator.create(Captures);
            captures.* = .{ .number_format = number_format };

            const number_format_function = struct {
                /// 16.5.2 Number Format Functions
                /// https://tc39.es/ecma402/#sec-number-format-functions
                fn func(agent_: *Agent, _: Value, arguments: Arguments) Agent.Error!Value {
                    const value = arguments.get(0);
                    const function = agent_.activeFunctionObject();
                    const captures_ = function.as(builtins.BuiltinFunction).fields.additionalFieldsAs(Captures);

                    // 1. Let nf be func.[[NumberFormat]].
                    // 2. Assert: nf is an Object and nf has an [[InitializedNumberFormat]] internal
                    //    slot.
                    const number_format_ = captures_.number_format;

                    // 3. If value is not provided, let value be undefined.

                    // 4. Let x be ? ToIntlMathematicalValue(value).
                    const x = try toIntlMathematicalValue(agent_, value);
                    defer x.deinit();

                    // 5. Return FormatNumeric(nf, x).
                    return formatNumeric(agent_, number_format_, x);
                }
            }.func;

            const bound_format = try createBuiltinFunction(
                agent,
                .{ .function = number_format_function },
                2,
                "",
                .{ .additional_fields = captures },
            );

            // c. Set nf.[[BoundFormat]] to func.
            number_format.fields.bound_format = bound_format;
        }

        // 5. Return nf.[[BoundFormat]].
        return Value.from(&number_format.fields.bound_format.?.object);
    }

    /// 16.3.4 Intl.NumberFormat.prototype.formatRange ( start, end )
    /// https://tc39.es/ecma402/#sec-intl.numberformat.prototype.formatrange
    fn formatRange(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const start = arguments.get(0);
        const end = arguments.get(1);

        // 1. Let nf be the this value.
        // 2. Perform ? RequireInternalSlot(nf, [[InitializedNumberFormat]]).
        const number_format = try this_value.requireInternalSlot(agent, NumberFormat);

        // 3. If start is undefined or end is undefined, throw a TypeError exception.
        if (start.isUndefined() or end.isUndefined()) {
            return agent.throwException(.type_error, "Argument must not be undefined", .{});
        }

        // 4. Let x be ? ToIntlMathematicalValue(start).
        const x = try toIntlMathematicalValue(agent, start);

        // 5. Let y be ? ToIntlMathematicalValue(end).
        const y = try toIntlMathematicalValue(agent, end);

        // 6. Return ? FormatNumericRange(nf, x, y).
        return formatNumericRange(agent, number_format, x, y);
    }
};

/// 16.4 Properties of Intl.NumberFormat Instances
/// https://tc39.es/ecma402/#sec-properties-of-intl-numberformat-instances
pub const NumberFormat = MakeObject(.{
    .Fields = struct {
        pub const Style = enum { decimal, currency, percent, unit };
        pub const CurrencyDisplay = enum { code, symbol, narrow_symbol, name };
        pub const CurrencySign = enum { standard, accounting };
        pub const UnitDisplay = enum { short, narrow, long };
        pub const UseGrouping = enum { always, min2, auto, false };
        pub const RoundingType = enum { fraction_digits, significant_digits, more_precision, less_precision };
        pub const RoundingPriority = enum { auto, more_precision, less_precision };
        pub const Notation = enum { standard, scientific, engineering, compact };
        pub const CompactDisplay = enum { short, long };
        pub const SignDisplay = enum { auto, always, never, except_zero, negative };
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

        /// [[NumberingSystem]]
        numbering_system: *const String,

        /// [[Style]]
        style: Style,

        /// [[Currency]]
        currency: ?*const String,

        /// [[CurrencyDisplay]]
        currency_display: ?CurrencyDisplay,

        /// [[CurrencySign]]
        currency_sign: ?CurrencySign,

        /// [[Unit]]
        unit: ?*const String,

        /// [[UnitDisplay]]
        unit_display: ?UnitDisplay,

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

        /// [[UseGrouping]]
        use_grouping: UseGrouping,

        /// [[RoundingType]]
        rounding_type: RoundingType,

        /// [[ComputedRoundingPriority]]
        computed_rounding_priority: RoundingPriority,

        /// [[Notation]]
        notation: Notation,

        /// [[CompactDisplay]]
        compact_display: ?CompactDisplay,

        /// [[SignDisplay]]
        sign_display: SignDisplay,

        /// [[RoundingIncrement]]
        rounding_increment: RoundingIncrement,

        /// [[RoundingMode]]
        rounding_mode: RoundingMode,

        /// [[TrailingZeroDisplay]]
        trailing_zero_display: TrailingZeroDisplay,

        /// [[BoundFormat]]
        bound_format: ?*builtins.BuiltinFunction,

        pub const ResolvedOptions = struct {
            numbering_system: *const String,
            style: *const String,
            currency: ?*const String,
            currency_display: ?*const String,
            currency_sign: ?*const String,
            unit: ?*const String,
            unit_display: ?*const String,
            minimum_integer_digits: u8,
            minimum_fraction_digits: ?u8,
            maximum_fraction_digits: ?u8,
            minimum_significant_digits: ?u8,
            maximum_significant_digits: ?u8,
            use_grouping: union(enum) {
                false,
                string: *const String,
            },
            notation: *const String,
            compact_display: ?*const String,
            sign_display: *const String,
            rounding_increment: u16,
            rounding_mode: *const String,
            rounding_priority: *const String,
            trailing_zero_display: *const String,
        };

        pub fn resolvedOptions(self: @This()) ResolvedOptions {
            return .{
                .numbering_system = self.numbering_system,
                .style = switch (self.style) {
                    .decimal => String.fromLiteral("decimal"),
                    .currency => String.fromLiteral("currency"),
                    .percent => String.fromLiteral("percent"),
                    .unit => String.fromLiteral("unit"),
                },
                .currency = self.currency,
                .currency_display = if (self.currency_display) |currency_display|
                    switch (currency_display) {
                        .code => String.fromLiteral("code"),
                        .symbol => String.fromLiteral("symbol"),
                        .narrow_symbol => String.fromLiteral("narrowSymbol"),
                        .name => String.fromLiteral("name"),
                    }
                else
                    null,
                .currency_sign = if (self.currency_sign) |currency_sign|
                    switch (currency_sign) {
                        .standard => String.fromLiteral("standard"),
                        .accounting => String.fromLiteral("accounting"),
                    }
                else
                    null,
                .unit = self.unit,
                .unit_display = if (self.unit_display) |unit_display|
                    switch (unit_display) {
                        .short => String.fromLiteral("short"),
                        .narrow => String.fromLiteral("narrow"),
                        .long => String.fromLiteral("long"),
                    }
                else
                    null,
                .minimum_integer_digits = self.minimum_integer_digits,
                .minimum_fraction_digits = self.minimum_fraction_digits,
                .maximum_fraction_digits = self.maximum_fraction_digits,
                .minimum_significant_digits = self.minimum_significant_digits,
                .maximum_significant_digits = self.maximum_significant_digits,
                .use_grouping = switch (self.use_grouping) {
                    .always => .{ .string = String.fromLiteral("always") },
                    .min2 => .{ .string = String.fromLiteral("min2") },
                    .auto => .{ .string = String.fromLiteral("auto") },
                    .false => .false,
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
                .sign_display = switch (self.sign_display) {
                    .auto => String.fromLiteral("auto"),
                    .always => String.fromLiteral("always"),
                    .never => String.fromLiteral("never"),
                    .except_zero => String.fromLiteral("exceptZero"),
                    .negative => String.fromLiteral("negative"),
                },
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
    .tag = .intl_number_format,
    .display_name = "Intl.NumberFormat",
});

/// 16.5.1 CurrencyDigits ( currency )
/// https://tc39.es/ecma402/#sec-currencydigits
fn currencyDigits(currency: *const String) u8 {
    // 1. Assert: IsWellFormedCurrencyCode(currency) is true.
    std.debug.assert(isWellFormedCurrencyCode(currency));

    // 2. Return a non-negative integer indicating the number of fractional digits used when
    //    formatting quantities of the currency corresponding to currency. If there is no available
    //    information on the number of digits to be used, return 2.
    return 2;
}

/// 16.5.6 FormatNumeric ( numberFormat, x )
/// https://tc39.es/ecma402/#sec-formatnumber
fn formatNumeric(
    agent: *Agent,
    number_format: *const NumberFormat,
    x: IntlMathematicalValue,
) std.mem.Allocator.Error!Value {
    // 1. Let parts be PartitionNumberPattern(numberFormat, x).
    // 2. Let result be the empty String.
    // 3. For each Record { [[Type]], [[Value]] } part of parts, do
    //     a. Set result to the string-concatenation of result and part.[[Value]].
    // 4. Return result.
    const result = try formatNumericImpl(agent.gc_allocator, number_format, x);
    return Value.from(try String.fromUtf8(agent, result));
}

fn formatNumericImpl(
    allocator: std.mem.Allocator,
    number_format: *const NumberFormat,
    x: IntlMathematicalValue,
) std.mem.Allocator.Error![]const u8 {
    const decimal = switch (x) {
        .positive_infinity => return "∞",
        .negative_infinity => return "-∞",
        .not_a_number => return "NaN",
        .negative_zero => return "-0",
        .mathematical_value => |decimal| decimal,
    };
    // TODO: Draw the rest of the owl
    const decimal_formatter = icu4zig.DecimalFormatter.init(
        number_format.fields.locale,
        switch (number_format.fields.use_grouping) {
            .always => .always,
            .min2 => .min2,
            .auto => .auto,
            .false => .never,
        },
    );
    defer decimal_formatter.deinit();
    return decimal_formatter.format(allocator, decimal);
}

/// 16.5.10 UnwrapNumberFormat ( nf )
/// https://tc39.es/ecma402/#sec-unwrapnumberformat
fn unwrapNumberFormat(agent: *Agent, number_format_value: Value) Agent.Error!Value {
    const realm = agent.currentRealm();

    // 1. If nf is not an Object, throw a TypeError exception.
    if (!number_format_value.isObject()) {
        return agent.throwException(.type_error, "Intl receiver must be an object", .{});
    }
    const number_format = number_format_value.asObject();

    // 2. If nf does not have an [[InitializedNumberFormat]] internal slot and
    //    ? OrdinaryHasInstance(%Intl.NumberFormat%, nf) is true, then
    if (!number_format.is(NumberFormat) and
        try Value.from(try realm.intrinsic(.intl_number_format)).ordinaryHasInstance(
            agent,
            number_format_value,
        ))
    {
        // a. Return ? Get(nf, %Intl%.[[FallbackSymbol]]).
        return number_format.get(
            agent,
            PropertyKey.from(try realm.intrinsic(.intl_fallback_symbol)),
        );
    }

    // 3. Return nf.
    return number_format_value;
}

/// https://tc39.es/ecma402/#intl-mathematical-value
pub const IntlMathematicalValue = union(enum) {
    positive_infinity,
    negative_infinity,
    not_a_number,
    negative_zero,
    mathematical_value: icu4zig.Decimal,

    pub fn deinit(self: IntlMathematicalValue) void {
        switch (self) {
            .mathematical_value => |decimal| decimal.deinit(),
            else => {},
        }
    }
};

/// 16.5.16 ToIntlMathematicalValue ( value )
/// https://tc39.es/ecma402/#sec-tointlmathematicalvalue
pub fn toIntlMathematicalValue(agent: *Agent, value: Value) Agent.Error!IntlMathematicalValue {
    const gpa = agent.gpa;

    // 1. Let primValue be ? ToPrimitive(value, number).
    const primitive_value = try value.toPrimitive(agent, .number);

    // 2. If primValue is a BigInt, return ℝ(primValue).
    if (primitive_value.isBigInt()) {
        var aw: std.Io.Writer.Allocating = .init(agent.gpa);
        defer aw.deinit();
        aw.writer.print("{f}", .{primitive_value.asBigInt().fmt(agent.gpa, 10)}) catch |err| switch (err) {
            error.WriteFailed => return error.OutOfMemory,
        };
        const decimal = icu4zig.Decimal.fromString(aw.written()) catch unreachable;
        return .{ .mathematical_value = decimal };
    }

    // 3. If primValue is a String, then
    const str = if (primitive_value.isString()) blk: {
        // a. Let str be primValue.
        break :blk primitive_value.asString();
    } else blk: {
        // 4. Else,
        // a. Let x be ? ToNumber(primValue).
        const x = try primitive_value.toNumber(agent);

        // b. If x is -0𝔽, return negative-zero.
        if (x.isNegativeZero()) return .negative_zero;

        // c. Let str be Number::toString(x, 10).
        break :blk try x.toString(agent, 10);
    };

    // 5. Let text be StringToCodePoints(str).
    // 6. Let literal be ParseText(text, StringNumericLiteral).
    // 7. If literal is a List of errors, return not-a-number.
    // 8. Let intlMV be the StringIntlMV of literal.
    // 9. If intlMV is a mathematical value, then
    //     a. Let rounded be RoundMVResult(abs(intlMV)).
    //     b. If rounded is +∞𝔽 and intlMV < 0, return negative-infinity.
    //     c. If rounded is +∞𝔽, return positive-infinity.
    //     d. If rounded is +0𝔽 and intlMV < 0, return negative-zero.
    //     e. If rounded is +0𝔽, return 0.
    // 10. Return intlMV.
    const number = try Value.from(str).toNumber(agent);
    if (number.isNan()) return .not_a_number;
    if (number.isNegativeInf()) return .negative_infinity;
    if (number.isPositiveInf()) return .positive_infinity;
    if (number.isNegativeZero()) return .negative_zero;
    const str_utf8 = try str.toUtf8(gpa);
    defer gpa.free(str_utf8);
    return if (icu4zig.Decimal.fromString(str_utf8)) |decimal|
        .{ .mathematical_value = decimal }
    else |_|
        .not_a_number;
}

/// 16.5.22 FormatNumericRange ( numberFormat, x, y )
/// https://tc39.es/ecma402/#sec-formatnumericrange
fn formatNumericRange(
    agent: *Agent,
    number_format: *const NumberFormat,
    x: IntlMathematicalValue,
    y: IntlMathematicalValue,
) std.mem.Allocator.Error!Value {
    // 1. Let parts be ? PartitionNumberRangePattern(numberFormat, x, y).
    // 2. Let result be the empty String.
    // 3. For each element part of parts, do
    //     a. Set result to the string-concatenation of result and part.[[Value]].
    // 4. Return result.
    const result_x = try formatNumericImpl(agent.gc_allocator, number_format, x);
    const result_y = try formatNumericImpl(agent.gc_allocator, number_format, y);
    if (std.mem.eql(u8, result_x, result_y)) {
        const result = try std.mem.concat(agent.gc_allocator, u8, &.{ "≈", result_x });
        return Value.from(try String.fromUtf8(agent, result));
    } else {
        const result = try std.mem.concat(agent.gc_allocator, u8, &.{ result_x, "–", result_y });
        return Value.from(try String.fromUtf8(agent, result));
    }
}
