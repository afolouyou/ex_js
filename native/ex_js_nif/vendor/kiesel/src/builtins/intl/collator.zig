//! 10 Collator Objects
//! https://tc39.es/ecma402/#collator-objects

const std = @import("std");

const icu4zig = @import("icu4zig");

const abstract_operations = @import("abstract_operations.zig");
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
const canonicalizeLocaleList = abstract_operations.canonicalizeLocaleList;
const createArrayFromListMapToValue = types.createArrayFromListMapToValue;
const createBuiltinFunction = builtins.createBuiltinFunction;
const ordinaryCreateFromConstructor = builtins.ordinaryCreateFromConstructor;
const ordinaryObjectCreate = builtins.ordinaryObjectCreate;
const resolveOptions = abstract_operations.resolveOptions;

/// 10.2 Properties of the Intl.Collator Constructor
/// https://tc39.es/ecma402/#sec-properties-of-the-intl-collator-constructor
pub const constructor = struct {
    pub fn create(agent: *Agent, realm: *Realm) std.mem.Allocator.Error!*Object {
        const builtin_function = try createBuiltinFunction(
            agent,
            .{ .constructor = impl },
            0,
            "Collator",
            .{ .realm = realm, .proto = try realm.intrinsic(.function_prototype) },
        );
        return &builtin_function.object;
    }

    pub fn init(agent: *Agent, realm: *Realm, object: *Object) std.mem.Allocator.Error!void {
        // 10.2.1 Intl.Collator.prototype
        // https://tc39.es/ecma402/#sec-intl.collator.prototype
        try object.defineBuiltinPropertyWithAttributes(
            agent,
            "prototype",
            Value.from(try realm.intrinsic(.intl_collator_prototype)),
            .none,
        );
    }

    /// 10.1.1 Intl.Collator ( [ locales [ , options ] ] )
    /// https://tc39.es/ecma402/#sec-intl.collator
    fn impl(agent: *Agent, arguments: Arguments, new_target: ?*Object) Agent.Error!Value {
        const locales = arguments.get(0);
        const options_value = arguments.get(1);

        // 1. If NewTarget is undefined, let newTarget be the active function object, else let
        //    newTarget be NewTarget.
        const new_target_ = new_target orelse agent.activeFunctionObject();

        // 2. Let internalSlotsList be « [[InitializedCollator]], [[Locale]], [[Usage]],
        //    [[Collation]], [[Numeric]], [[CaseFirst]], [[Sensitivity]], [[IgnorePunctuation]],
        //    [[BoundCompare]] ».
        // 3. Let collator be ? OrdinaryCreateFromConstructor(newTarget,
        //    "%Intl.Collator.prototype%", internalSlotsList).
        const collator = try ordinaryCreateFromConstructor(
            Collator,
            agent,
            new_target_,
            .intl_collator_prototype,
            .{
                .locale = undefined,
                .usage = undefined,
                .options = .{},
                .bound_compare = null,
            },
        );

        // 4. NOTE: The source of locale data for ResolveOptions depends upon the "usage" property
        //    of options, but the following two steps must observably precede that lookup (and must
        //    not observably repeat inside ResolveOptions).

        // 5. Let requestedLocales be ? CanonicalizeLocaleList(locales).
        const requested_locales = try canonicalizeLocaleList(agent, locales);

        // 6. Set options to ? CoerceOptionsToObject(options).
        const options = try options_value.coerceOptionsToObject(agent);

        // 7. Let usage be ? GetOption(options, "usage", string, « "sort", "search" », "sort").
        const usage_string = try options.getOption(
            agent,
            "usage",
            .string,
            &.{ String.fromLiteral("sort"), String.fromLiteral("search") },
            String.fromLiteral("sort"),
        );
        const usage = std.StaticStringMap(Collator.Fields.Usage).initComptime(&.{
            .{ "sort", .sort },
            .{ "search", .search },
        }).get(usage_string.asAscii()).?;

        // 8. Set collator.[[Usage]] to usage.
        collator.fields.usage = usage;

        // TODO: 9-10.

        // 11. Let optionsResolution be ? ResolveOptions(%Intl.Collator%, localeData,
        //     CreateArrayFromList(requestedLocales), options).
        const array = try createArrayFromListMapToValue(agent, icu4zig.Locale, requested_locales.items, struct {
            fn mapFn(agent_: *Agent, locale: icu4zig.Locale) std.mem.Allocator.Error!Value {
                const locale_string = try locale.toString(agent_.gc_allocator);
                var it = std.mem.splitSequence(u8, locale_string, "-x-");
                return Value.from(try String.fromAscii(agent_, it.next().?));
            }
        }.mapFn);
        const options_resolution = try resolveOptions(
            agent,
            &.{
                .{ .key = "co", .property = "collation" },
                .{ .key = "kn", .property = "numeric", .type = .boolean },
                .{ .key = "kf", .property = "caseFirst", .values = &.{
                    String.fromLiteral("upper"),
                    String.fromLiteral("lower"),
                    String.fromLiteral("false"),
                } },
            },
            Value.from(&array.object),
            options_value,
            .{},
        );

        // 12. Let resolvedLocale be optionsResolution.[[ResolvedLocale]].
        const resolved_locale = options_resolution.resolved_locale;
        const locale = resolved_locale.locale;

        // 13. Set collator.[[Locale]] to resolvedLocale.[[Locale]].
        collator.fields.locale = locale;

        // TODO: 14-18.

        // 19. If usage is "sort", let defaultSensitivity be "variant". Otherwise, let
        //     defaultSensitivity be resolvedLocaleData.[[sensitivity]].
        // 20. Set collator.[[Sensitivity]] to ? GetOption(options, "sensitivity", string, « "base",
        //     "accent", "case", "variant" », defaultSensitivity).
        var maybe_sensitivity_string = try options.getOption(
            agent,
            "sensitivity",
            .string,
            &.{
                String.fromLiteral("base"),
                String.fromLiteral("accent"),
                String.fromLiteral("case"),
                String.fromLiteral("variant"),
            },
            null,
        );
        if (maybe_sensitivity_string == null and usage == .sort) {
            maybe_sensitivity_string = String.fromLiteral("variant");
        }
        if (maybe_sensitivity_string) |sensitivity_string| {
            const strength, const case_level = std.StaticStringMap(
                struct { icu4zig.Collator.Strength, ?icu4zig.Collator.CaseLevel },
            ).initComptime(&.{
                // See https://docs.rs/icu/latest/icu/collator/enum.Strength.html#variants for the
                // mapping of ECMA-402 sensitivity to ICU4X collator options.
                .{ "base", .{ .primary, .off } },
                .{ "accent", .{ .secondary, null } },
                .{ "case", .{ .primary, .on } },
                .{ "variant", .{ .tertiary, null } },
            }).get(sensitivity_string.asAscii()).?;
            collator.fields.options.strength = strength;
            collator.fields.options.case_level = case_level;
        }

        // 21. Let defaultIgnorePunctuation be resolvedLocaleData.[[ignorePunctuation]].
        // 22. Set collator.[[IgnorePunctuation]] to ? GetOption(options, "ignorePunctuation",
        //     boolean, empty, defaultIgnorePunctuation).
        const maybe_ignore_punctuation = try options.getOption(
            agent,
            "ignorePunctuation",
            .boolean,
            null,
            null,
        );
        if (maybe_ignore_punctuation) |ignore_punctuation| {
            collator.fields.options.max_variable = if (ignore_punctuation) .space else .punctuation;
        }

        // 23. Return collator.
        return Value.from(&collator.object);
    }
};

/// 10.3 Properties of the Intl.Collator Prototype Object
/// https://tc39.es/ecma402/#sec-properties-of-the-intl-collator-prototype-object
pub const prototype = struct {
    pub fn create(agent: *Agent, realm: *Realm) std.mem.Allocator.Error!*Object {
        return ordinaryObjectCreate(agent, try realm.intrinsic(.object_prototype));
    }

    pub fn init(agent: *Agent, realm: *Realm, object: *Object) std.mem.Allocator.Error!void {
        try object.defineBuiltinFunction(agent, "resolvedOptions", resolvedOptions, 0, realm);
        try object.defineBuiltinAccessor(agent, "compare", compare, null, realm);

        // 10.3.1 Intl.Collator.prototype.constructor
        // https://tc39.es/ecma402/#sec-intl.collator.prototype.constructor
        try object.defineBuiltinProperty(
            agent,
            "constructor",
            Value.from(try realm.intrinsic(.intl_collator)),
        );

        // 10.3.4 Intl.Collator.prototype [ %Symbol.toStringTag% ]
        // https://tc39.es/ecma402/#sec-intl.collator.prototype-%symbol.tostringtag%
        try object.defineBuiltinPropertyWithAttributes(
            agent,
            "Symbol.toStringTag",
            Value.from("Intl.Collator"),
            .{
                .writable = false,
                .enumerable = false,
                .configurable = true,
            },
        );
    }

    /// 10.3.2 Intl.Collator.prototype.resolvedOptions ( )
    /// https://tc39.es/ecma402/#sec-intl.collator.prototype.resolvedoptions
    fn resolvedOptions(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        const realm = agent.currentRealm();

        // 1. Let collator be the this value.
        // 2. Perform ? RequireInternalSlot(collator, [[InitializedCollator]]).
        const collator = try this_value.requireInternalSlot(agent, Collator);

        // 3. Let options be OrdinaryObjectCreate(%Object.prototype%).
        const options = try ordinaryObjectCreate(
            agent,
            try realm.intrinsic(.object_prototype),
        );

        // 4. For each row of Table 3, except the header row, in table order, do
        //     a. Let propertyKey be the Property value of the current row.
        //     b. Let value be the value of collator's internal slot whose name is the Internal Slot
        //        value of the current row.
        //     c. If the current row has an Extension Key value, then
        //         i. Let extensionKey be the Extension Key value of the current row.
        //         ii. If %Intl.Collator%.[[RelevantExtensionKeys]] does not contain extensionKey,
        //             then
        //             1. Set value to undefined.
        //     d. If value is not undefined, then
        //         i. Perform ! CreateDataPropertyOrThrow(options, propertyKey, value).
        const resolved_options = collator.fields.resolvedOptions();
        try options.createDataPropertyDirect(
            agent,
            PropertyKey.from("locale"),
            Value.from(
                try String.fromAscii(
                    agent,
                    try collator.fields.locale.toString(agent.gc_allocator),
                ),
            ),
        );
        try options.createDataPropertyDirect(
            agent,
            PropertyKey.from("usage"),
            Value.from(resolved_options.usage),
        );
        try options.createDataPropertyDirect(
            agent,
            PropertyKey.from("sensitivity"),
            Value.from(resolved_options.sensitivity),
        );
        try options.createDataPropertyDirect(
            agent,
            PropertyKey.from("ignorePunctuation"),
            Value.from(resolved_options.ignore_punctuation),
        );
        try options.createDataPropertyDirect(
            agent,
            PropertyKey.from("collation"),
            Value.from(resolved_options.collation),
        );
        try options.createDataPropertyDirect(
            agent,
            PropertyKey.from("numeric"),
            Value.from(resolved_options.numeric),
        );
        try options.createDataPropertyDirect(
            agent,
            PropertyKey.from("caseFirst"),
            Value.from(resolved_options.case_first),
        );

        // 5. Return options.
        return Value.from(options);
    }

    /// 10.3.3 get Intl.Collator.prototype.compare
    /// https://tc39.es/ecma402/#sec-intl.collator.prototype.compare
    fn compare(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let collator be the this value.
        // 2. Perform ? RequireInternalSlot(collator, [[InitializedCollator]]).
        const collator = try this_value.requireInternalSlot(agent, Collator);

        // 3. If collator.[[BoundCompare]] is undefined, then
        if (collator.fields.bound_compare == null) {
            // a. Let func be a new built-in function object as defined in 10.3.3.1.
            // b. Set func.[[Collator]] to collator.
            const Captures = struct {
                collator: *Collator,
            };
            const captures = try agent.gc_allocator.create(Captures);
            captures.* = .{ .collator = collator };

            const collator_compare_function = struct {
                /// 10.3.3.1 Collator Compare Functions
                /// https://tc39.es/ecma402/#sec-collator-compare-functions
                fn func(agent_: *Agent, _: Value, arguments: Arguments) Agent.Error!Value {
                    const function = agent_.activeFunctionObject();
                    const captures_ = function.as(builtins.BuiltinFunction).fields.additionalFieldsAs(Captures);
                    const x = arguments.get(0);
                    const y = arguments.get(1);

                    // 1. Let collator be func.[[Collator]].
                    // 2. Assert: collator is an Object and collator has an [[InitializedCollator]]
                    //    internal slot.
                    const collator_ = captures_.collator;

                    // 3. If x is not provided, let x be undefined.
                    // 4. If y is not provided, let y be undefined.
                    // 5. Let xString be ? ToString(x).
                    // 6. Let yString be ? ToString(y).
                    const x_string = try x.toString(agent_);
                    const y_string = try y.toString(agent_);

                    // 7. Return CompareStrings(collator, xString, yString).
                    return compareStrings(agent_.gc_allocator, collator_, x_string, y_string);
                }
            }.func;

            const func = try createBuiltinFunction(
                agent,
                .{ .function = collator_compare_function },
                2,
                "",
                .{ .additional_fields = captures },
            );

            // c. Set collator.[[BoundCompare]] to func.
            collator.fields.bound_compare = func;
        }

        // 4. Return collator.[[BoundCompare]].
        return Value.from(&collator.fields.bound_compare.?.object);
    }
};

/// 10.3.3.2 CompareStrings ( collator, x, y )
/// https://tc39.es/ecma402/#sec-collator-comparestrings
pub fn compareStrings(
    allocator: std.mem.Allocator,
    collator_object: *const Collator,
    x: *const String,
    y: *const String,
) std.mem.Allocator.Error!Value {
    const collator = icu4zig.Collator.init(
        collator_object.fields.locale,
        collator_object.fields.options,
    );
    defer collator.deinit();

    const order = if (x.isAscii() and y.isAscii()) blk: {
        break :blk collator.compareUtf8(x.asAscii(), y.asAscii());
    } else if (x.isUtf16() and y.isUtf16()) blk: {
        break :blk collator.compareUtf16(x.asUtf16(), y.asUtf16());
    } else if (x.isAscii() and y.isUtf16()) blk: {
        const x_utf16 = try x.toUtf16(allocator);
        defer allocator.free(x_utf16);
        break :blk collator.compareUtf16(x_utf16, y.asUtf16());
    } else if (x.isUtf16() and y.isAscii()) blk: {
        const y_utf16 = try y.toUtf16(allocator);
        defer allocator.free(y_utf16);
        break :blk collator.compareUtf16(x.asUtf16(), y_utf16);
    } else unreachable;
    return switch (order) {
        .lt => Value.from(-1),
        .gt => Value.from(1),
        .eq => Value.from(0),
    };
}

/// 10.4 Properties of Intl.Collator Instances
/// https://tc39.es/ecma402/#sec-properties-of-intl-collator-instances
pub const Collator = MakeObject(.{
    .Fields = struct {
        pub const Usage = enum {
            sort,
            search,
        };

        /// [[Locale]]
        locale: icu4zig.Locale,

        /// [[Usage]]
        usage: Usage,

        /// [[Sensitivity]], [[IgnorePunctuation]], [[Collation]], [[Numeric]], [[CaseFirst]]
        options: icu4zig.Collator.Options,

        /// [[BoundCompare]]
        bound_compare: ?*builtins.BuiltinFunction,

        pub const ResolvedOptions = struct {
            usage: *const String,
            sensitivity: *const String,
            ignore_punctuation: bool,
            collation: *const String,
            numeric: bool,
            case_first: *const String,
        };

        pub fn resolvedOptions(self: @This()) ResolvedOptions {
            const collator = icu4zig.Collator.init(self.locale, self.options);
            defer collator.deinit();
            const resolved_options = collator.resolvedOptions();

            const usage = switch (self.usage) {
                .sort => String.fromLiteral("sort"),
                .search => String.fromLiteral("search"),
            };
            const sensitivity = if (resolved_options.strength == .primary and resolved_options.case_level == .off)
                String.fromLiteral("base")
            else if (resolved_options.strength == .primary and resolved_options.case_level == .on)
                String.fromLiteral("case")
            else if (resolved_options.strength == .secondary)
                String.fromLiteral("accent")
            else if (resolved_options.strength == .tertiary)
                String.fromLiteral("variant")
            else
                unreachable;
            const ignore_punctuation = resolved_options.max_variable == .space;
            const collation = String.fromLiteral("default");
            const numeric = resolved_options.numeric == .on;
            const case_first = switch (resolved_options.case_first) {
                .upper => String.fromLiteral("upper"),
                .lower => String.fromLiteral("lower"),
                .off => String.fromLiteral("false"),
            };
            return .{
                .usage = usage,
                .sensitivity = sensitivity,
                .ignore_punctuation = ignore_punctuation,
                .collation = collation,
                .numeric = numeric,
                .case_first = case_first,
            };
        }
    },
    .tag = .intl_collator,
    .display_name = "Intl.Collator",
});
