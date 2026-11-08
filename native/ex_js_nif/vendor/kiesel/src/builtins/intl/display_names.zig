//! 12 DisplayNames Objects
//! https://tc39.es/ecma402/#intl-displaynames-objects

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
const createBuiltinFunction = builtins.createBuiltinFunction;
const ordinaryCreateFromConstructor = builtins.ordinaryCreateFromConstructor;
const ordinaryObjectCreate = builtins.ordinaryObjectCreate;
const resolveOptions = abstract_operations.resolveOptions;

/// 12.2 Properties of the Intl.DisplayNames Constructor
/// https://tc39.es/ecma402/#sec-properties-of-intl-displaynames-constructor
pub const constructor = struct {
    pub fn create(agent: *Agent, realm: *Realm) std.mem.Allocator.Error!*Object {
        const builtin_function = try createBuiltinFunction(
            agent,
            .{ .constructor = impl },
            2,
            "DisplayNames",
            .{ .realm = realm, .proto = try realm.intrinsic(.function_prototype) },
        );
        return &builtin_function.object;
    }

    pub fn init(agent: *Agent, realm: *Realm, object: *Object) std.mem.Allocator.Error!void {
        // 12.2.1 Intl.DisplayNames.prototype
        // https://tc39.es/ecma402/#sec-Intl.DisplayNames.prototype
        try object.defineBuiltinPropertyWithAttributes(
            agent,
            "prototype",
            Value.from(try realm.intrinsic(.intl_display_names_prototype)),
            .none,
        );
    }

    /// 12.1.1 Intl.DisplayNames ( locales, options )
    /// https://tc39.es/ecma402/#sec-Intl.DisplayNames
    fn impl(agent: *Agent, arguments: Arguments, new_target: ?*Object) Agent.Error!Value {
        const locales = arguments.get(0);
        const options_value = arguments.get(1);

        // 1. If NewTarget is undefined, throw a TypeError exception.
        if (new_target == null) {
            return agent.throwException(
                .type_error,
                "Intl.DisplayNames must be constructed with 'new'",
                .{},
            );
        }

        // 2. Let displayNames be ? OrdinaryCreateFromConstructor(NewTarget,
        //    "%Intl.DisplayNames.prototype%", « [[InitializedDisplayNames]], [[Locale]], [[Style]],
        //    [[Type]], [[Fallback]], [[LanguageDisplay]], [[Fields]] »).
        const display_names = try ordinaryCreateFromConstructor(
            DisplayNames,
            agent,
            new_target.?,
            .intl_display_names_prototype,
            .{
                .locale = undefined,
                .type = undefined,
                .options = .{
                    .style = undefined,
                    .fallback = undefined,
                    .language_display = undefined,
                },
            },
        );

        // 3. Let optionsResolution be ? ResolveOptions(%Intl.DisplayNames%,
        //    %Intl.DisplayNames%.[[LocaleData]], locales, options, « require-options »).
        const options_resolution = try resolveOptions(
            agent,
            &.{},
            locales,
            options_value,
            .{ .require_options = true },
        );

        // 4. Set options to optionsResolution.[[Options]].
        const options = options_resolution.options;

        // 5. Let resolvedLocale be optionsResolution.[[ResolvedLocale]].
        const resolved_locale = options_resolution.resolved_locale;

        // 6. Let style be ? GetOption(options, "style", string, « "narrow", "short", "long" »,
        //    "long").
        const style_string = try options.getOption(
            agent,
            "style",
            .string,
            &.{
                String.fromLiteral("narrow"),
                String.fromLiteral("short"),
                String.fromLiteral("long"),
            },
            String.fromLiteral("long"),
        );
        const style = std.StaticStringMap(icu4zig.DisplayNamesOptions.Style).initComptime(&.{
            .{ "narrow", .narrow },
            .{ "short", .short },
            .{ "long", .long },
        }).get(style_string.asAscii()).?;

        // 7. Set displayNames.[[Style]] to style.
        display_names.fields.options.style = style;

        // 8. Let type be ? GetOption(options, "type", string, « "language", "region", "script",
        //    "currency", "calendar", "dateTimeField" », required).
        const type_string = try options.getOption(
            agent,
            "type",
            .string,
            &.{
                String.fromLiteral("language"),
                String.fromLiteral("region"),
                String.fromLiteral("script"),
                String.fromLiteral("currency"),
                String.fromLiteral("calendar"),
                String.fromLiteral("dateTimeField"),
            },
            .required,
        );

        const @"type" = std.StaticStringMap(DisplayNames.Fields.Type).initComptime(&.{
            .{ "language", .language },
            .{ "region", .region },
            .{ "script", .script },
            .{ "currency", .currency },
            .{ "calendar", .calendar },
            .{ "dateTimeField", .date_time_field },
        }).get(type_string.asAscii()).?;

        // 9. Set displayNames.[[Type]] to type.
        display_names.fields.type = @"type";

        // 10. Let fallback be ? GetOption(options, "fallback", string, « "code", "none" », "code").
        const fallback_string = try options.getOption(
            agent,
            "fallback",
            .string,
            &.{
                String.fromLiteral("code"),
                String.fromLiteral("none"),
            },
            String.fromLiteral("code"),
        );
        const fallback = std.StaticStringMap(icu4zig.DisplayNamesOptions.Fallback).initComptime(&.{
            .{ "code", .code },
            .{ "none", .none },
        }).get(fallback_string.asAscii()).?;

        // 11. Set displayNames.[[Fallback]] to fallback.
        display_names.fields.options.fallback = fallback;

        // 12. Set displayNames.[[Locale]] to resolvedLocale.[[Locale]].
        display_names.fields.locale = resolved_locale.locale;

        // 13. Let resolvedLocaleData be resolvedLocale.[[LocaleData]].
        // 14. Let types be resolvedLocaleData.[[types]].
        // 15. Assert: types is a Record (see 12.2.3).

        // 16. Let languageDisplay be ? GetOption(options, "languageDisplay", string, « "dialect",
        //     "standard" », "dialect").
        const language_display_string = try options.getOption(
            agent,
            "languageDisplay",
            .string,
            &.{
                String.fromLiteral("dialect"),
                String.fromLiteral("standard"),
            },
            String.fromLiteral("dialect"),
        );
        const language_display = std.StaticStringMap(
            icu4zig.DisplayNamesOptions.LanguageDisplay,
        ).initComptime(&.{
            .{ "dialect", .dialect },
            .{ "standard", .standard },
        }).get(language_display_string.asAscii()).?;

        // 17. Let typeFields be types.[[<type>]].
        // 18. Assert: typeFields is a Record (see 12.2.3).
        // 19. If type is "language", then
        //     a. Set displayNames.[[LanguageDisplay]] to languageDisplay.
        //     b. Set typeFields to typeFields.[[<languageDisplay>]].
        //     c. Assert: typeFields is a Record (see 12.2.3).
        // NOTE: We do this unconditionally as it's part of the options struct.
        display_names.fields.options.language_display = language_display;

        // 20. Let styleFields be typeFields.[[<style>]].
        // 21. Assert: styleFields is a Record (see 12.2.3).
        // 22. Set displayNames.[[Fields]] to styleFields.

        // 23. Return displayNames.
        return Value.from(&display_names.object);
    }
};

/// 12.3 Properties of the Intl.DisplayNames Prototype Object
/// https://tc39.es/ecma402/#sec-properties-of-intl-displaynames-prototype-object
pub const prototype = struct {
    pub fn create(agent: *Agent, realm: *Realm) std.mem.Allocator.Error!*Object {
        return ordinaryObjectCreate(agent, try realm.intrinsic(.object_prototype));
    }

    pub fn init(agent: *Agent, realm: *Realm, object: *Object) std.mem.Allocator.Error!void {
        try object.defineBuiltinFunction(agent, "resolvedOptions", resolvedOptions, 0, realm);
        try object.defineBuiltinFunction(agent, "of", of, 1, realm);

        // 12.3.1 Intl.DisplayNames.prototype.constructor
        // https://tc39.es/ecma402/#sec-Intl.DisplayNames.prototype.constructor
        try object.defineBuiltinProperty(
            agent,
            "constructor",
            Value.from(try realm.intrinsic(.intl_display_names)),
        );

        // 12.3.4 Intl.DisplayNames.prototype [ %Symbol.toStringTag% ]
        // https://tc39.es/ecma402/#sec-intl.displaynames.prototype-%symbol.tostringtag%
        try object.defineBuiltinPropertyWithAttributes(
            agent,
            "Symbol.toStringTag",
            Value.from("Intl.DisplayNames"),
            .{
                .writable = false,
                .enumerable = false,
                .configurable = true,
            },
        );
    }

    /// 12.3.2 Intl.DisplayNames.prototype.resolvedOptions ( )
    /// https://tc39.es/ecma402/#sec-Intl.DisplayNames.prototype.resolvedOptions
    fn resolvedOptions(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        const realm = agent.currentRealm();

        // 1. Let displayNames be this value.
        // 2. Perform ? RequireInternalSlot(displayNames, [[InitializedDisplayNames]]).
        const display_names = try this_value.requireInternalSlot(agent, DisplayNames);

        // 3. Let options be OrdinaryObjectCreate(%Object.prototype%).
        const options = try ordinaryObjectCreate(
            agent,
            try realm.intrinsic(.object_prototype),
        );

        // 4. For each row of Table 18, except the header row, in table order, do
        //     a. Let propertyKey be the Property value of the current row.
        //     b. Let value be the value of displayNames's internal slot whose name is the Internal
        //        Slot value of the current row.
        //     c. If value is not undefined, then
        //         i. Perform ! CreateDataPropertyOrThrow(options, propertyKey, value).
        const resolved_options = display_names.fields.resolvedOptions();
        try options.createDataPropertyDirect(
            agent,
            PropertyKey.from("locale"),
            Value.from(
                try String.fromAscii(
                    agent,
                    try display_names.fields.locale.toString(agent.gc_allocator),
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
            PropertyKey.from("type"),
            Value.from(resolved_options.type),
        );
        try options.createDataPropertyDirect(
            agent,
            PropertyKey.from("fallback"),
            Value.from(resolved_options.fallback),
        );
        if (display_names.fields.type == .language) {
            try options.createDataPropertyDirect(
                agent,
                PropertyKey.from("languageDisplay"),
                Value.from(resolved_options.language_display),
            );
        }

        // 5. Return options.
        return Value.from(options);
    }

    /// 12.3.3 Intl.DisplayNames.prototype.of ( code )
    /// https://tc39.es/ecma402/#sec-Intl.DisplayNames.prototype.of
    fn of(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const gpa = agent.gpa;
        const code_value = arguments.get(0);

        // 1. Let displayNames be this value.
        // 2. Perform ? RequireInternalSlot(displayNames, [[InitializedDisplayNames]]).
        const display_names = try this_value.requireInternalSlot(agent, DisplayNames);

        // 3. Set code to ? ToString(code).
        const code = try code_value.toString(agent);

        // 4. Set code to ? CanonicalCodeForDisplayNames(displayNames.[[Type]], code).
        // 5. Let fields be displayNames.[[Fields]].
        // 6. If fields has a field [[<code>]], return fields.[[<code>]].
        // 7. If displayNames.[[Fallback]] is "code", return code.
        // 8. Return undefined.
        const code_utf8 = try code.toUtf8(gpa);
        defer gpa.free(code_utf8);
        // ICU4X LocaleDisplayNamesFormatter and RegionDisplayNames return an error for at least
        // the 'und' locale, other engines seem to fall back to 'en' in that case.
        // LocaleNamesUnstable does not error but returns the code unchanged so we check for 'und'
        // manually.
        const fallback_locale = icu4zig.Locale.fromString("en") catch unreachable;
        defer fallback_locale.deinit();
        const value = switch (display_names.fields.type) {
            .language => blk: {
                const locale_display_names_formatter = icu4zig.LocaleDisplayNamesFormatter.init(
                    display_names.fields.locale,
                    display_names.fields.options,
                ) catch icu4zig.LocaleDisplayNamesFormatter.init(
                    fallback_locale,
                    display_names.fields.options,
                ) catch unreachable;
                defer locale_display_names_formatter.deinit();
                const locale = icu4zig.Locale.fromString(code_utf8) catch {
                    return agent.throwException(
                        .range_error,
                        "Invalid language '{f}'",
                        .{code.fmtEscaped()},
                    );
                };
                break :blk try locale_display_names_formatter.of(agent.gc_allocator, locale);
            },
            .region => blk: {
                const region_display_names = icu4zig.RegionDisplayNames.init(
                    display_names.fields.locale,
                    display_names.fields.options,
                ) catch icu4zig.RegionDisplayNames.init(
                    fallback_locale,
                    display_names.fields.options,
                ) catch unreachable;
                defer region_display_names.deinit();
                break :blk region_display_names.of(agent.gc_allocator, code_utf8) catch |err| switch (err) {
                    error.OutOfMemory => |e| return e,
                    error.Subtag => return agent.throwException(
                        .range_error,
                        "Invalid region '{f}'",
                        .{code.fmtEscaped()},
                    ),
                };
            },
            .script => blk: {
                // Scripts only have one name in CLDR, so style doesn't matter - always use the full name.
                const locale = if (display_names.fields.locale.normalizingEq("und"))
                    fallback_locale
                else
                    display_names.fields.locale;
                break :blk try icu4zig.locale_names_unstable.forScriptHeavy(
                    agent.gc_allocator,
                    locale,
                    code_utf8,
                );
            },
            .currency,
            .calendar,
            .date_time_field,
            => return agent.throwException(
                .internal_error,
                "Unsupported Intl.DisplayNames type '{t}'",
                .{display_names.fields.type},
            ),
        };
        if (value.len == 0) return .undefined;
        return Value.from(try String.fromUtf8(agent, value));
    }
};

/// 12.4 Properties of Intl.DisplayNames Instances
/// https://tc39.es/ecma402/#sec-properties-of-intl-displaynames-instances
pub const DisplayNames = MakeObject(.{
    .Fields = struct {
        pub const Type = enum {
            language,
            region,
            script,
            currency,
            calendar,
            date_time_field,
        };

        /// [[Locale]]
        locale: icu4zig.Locale,

        /// [[Type]]
        type: Type,

        /// [[Style]], [[Fallback]], [[LanguageDisplay]]
        options: icu4zig.DisplayNamesOptions,

        pub const ResolvedOptions = struct {
            style: *const String,
            type: *const String,
            fallback: *const String,
            language_display: *const String,
        };

        pub fn resolvedOptions(self: @This()) ResolvedOptions {
            const @"type" = switch (self.type) {
                .language => String.fromLiteral("language"),
                .region => String.fromLiteral("region"),
                .script => String.fromLiteral("script"),
                .currency => String.fromLiteral("currency"),
                .calendar => String.fromLiteral("calendar"),
                .date_time_field => String.fromLiteral("dateTimeField"),
            };
            const style = switch (self.options.style.?) {
                .narrow => String.fromLiteral("narrow"),
                .short => String.fromLiteral("short"),
                .long => String.fromLiteral("long"),
                .menu => String.fromLiteral("menu"),
            };
            const fallback = switch (self.options.fallback.?) {
                .code => String.fromLiteral("code"),
                .none => String.fromLiteral("none"),
            };
            const language_display = switch (self.options.language_display.?) {
                .dialect => String.fromLiteral("dialect"),
                .standard => String.fromLiteral("standard"),
            };
            return .{
                .style = style,
                .type = @"type",
                .fallback = fallback,
                .language_display = language_display,
            };
        }
    },
    .tag = .intl_display_names,
    .display_name = "Intl.DisplayNames",
});
