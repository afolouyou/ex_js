//! 15 Locale Objects
//! https://tc39.es/ecma402/#locale-objects

const std = @import("std");

const icu4zig = @import("icu4zig");

const builtins = @import("../../builtins.zig");
const execution = @import("../../execution.zig");
const types = @import("../../types.zig");
const utils = @import("../../utils.zig");

const Agent = execution.Agent;
const Arguments = types.Arguments;
const MakeObject = types.MakeObject;
const Object = types.Object;
const Realm = execution.Realm;
const String = types.String;
const Value = types.Value;
const createBuiltinFunction = builtins.createBuiltinFunction;
const noexcept = utils.noexcept;
const ordinaryCreateFromConstructor = builtins.ordinaryCreateFromConstructor;
const ordinaryObjectCreate = builtins.ordinaryObjectCreate;

/// 15.1.2 UpdateLanguageId ( tag, options )
/// https://tc39.es/ecma402/#sec-updatelanguageid
fn updateLanguageId(
    agent: *Agent,
    tag: icu4zig.Locale,
    options: *Object,
) Agent.Error!icu4zig.Locale {
    const gpa = agent.gpa;
    var new_tag = tag.clone();

    // 1. Let baseName be GetLocaleBaseName(tag).
    // 2. Let language be ? GetOption(options, "language", string, empty, GetLocaleLanguage(
    //    baseName)).
    const maybe_language = try options.getOption(agent, "language", .string, null, null);

    // 3. If language cannot be matched by the `unicode_language_subtag` Unicode locale nonterminal,
    //    throw a RangeError exception.
    if (maybe_language) |language| {
        const language_utf8 = try language.toUtf8(gpa);
        defer gpa.free(language_utf8);
        new_tag.setLanguage(language_utf8) catch {
            return agent.throwException(.range_error, "Invalid language subtag '{s}'", .{language_utf8});
        };
    }

    // 4. Let script be ? GetOption(options, "script", string, empty, GetLocaleScript(baseName)).
    const maybe_script = try options.getOption(agent, "script", .string, null, null);

    // 5. If script is not undefined, then
    if (maybe_script) |script| {
        // a. If script cannot be matched by the `unicode_script_subtag` Unicode locale nonterminal,
        //    throw a RangeError exception.
        const script_utf8 = try script.toUtf8(gpa);
        defer gpa.free(script_utf8);
        new_tag.setScript(script_utf8) catch {
            return agent.throwException(
                .range_error,
                "Invalid script subtag '{s}'",
                .{script_utf8},
            );
        };
    }

    // 6. Let region be ? GetOption(options, "region", string, empty, GetLocaleRegion(baseName)).
    const maybe_region = try options.getOption(agent, "region", .string, null, null);

    // 7. If region is not undefined, then
    if (maybe_region) |region| {
        // a. If region cannot be matched by the `unicode_region_subtag` Unicode locale nonterminal,
        //    throw a RangeError exception.
        const region_utf8 = try region.toUtf8(gpa);
        defer gpa.free(region_utf8);
        new_tag.setRegion(region_utf8) catch {
            return agent.throwException(
                .range_error,
                "Invalid region subtag '{s}'",
                .{region_utf8},
            );
        };
    }

    // 8. Let variants be ? GetOption(options, "variants", string, empty, GetLocaleVariants(
    //    baseName)).
    const maybe_variants = try options.getOption(agent, "variants", .string, null, null);

    // 9. If variants is not undefined, then
    if (maybe_variants) |variants| {
        const variants_utf8 = try variants.toUtf8(gpa);
        defer gpa.free(variants_utf8);

        new_tag.clearVariants();

        // a. If variants is the empty String, throw a RangeError exception.
        if (variants.isEmpty()) {
            return agent.throwException(.range_error, "Variants subtag must not be empty", .{});
        }

        // b. Let lowerVariants be the ASCII-lowercase of variants.
        const lower_variants = std.ascii.lowerString(variants_utf8, variants_utf8);

        // c. Let variantSubtags be StringSplitToList(lowerVariants, "-").
        var it = std.mem.splitScalar(u8, lower_variants, '-');

        // d. For each element variant of variantSubtags, do
        while (it.next()) |variant| {
            const added = new_tag.addVariant(variant) catch {
                // i. If variant cannot be matched by the `unicode_variant_subtag` Unicode locale
                //    nonterminal, throw a RangeError exception.
                return agent.throwException(
                    .range_error,
                    "Invalid variant subtag '{s}'",
                    .{variant},
                );
            };

            // e. If variantSubtags contains any duplicate elements, throw a RangeError exception.
            if (!added) {
                return agent.throwException(
                    .range_error,
                    "Duplicate variant subtag '{s}'",
                    .{variant},
                );
            }
        }
    }

    // 10-15.
    // NOTE: These are done as part of step 3.a., 5.a., 7.a., and 9.d.

    // 16. Return newTag.
    return new_tag;
}

/// Add Likely Subtags
/// https://unicode.org/reports/tr35/#Likely_Subtags
fn addLikelySubtags(gpa: std.mem.Allocator, input_locale: icu4zig.Locale) std.mem.Allocator.Error!icu4zig.Locale {
    var cloned = input_locale.clone();
    const locale_expander = icu4zig.LocaleExpander.init();
    defer locale_expander.deinit();
    _ = locale_expander.maximize(&cloned);
    const language = try cloned.language(gpa);
    defer gpa.free(language);
    if (!std.mem.eql(u8, language, "und")) return cloned;
    // NOTE: As of ICU4X 2.3.0, LocaleExpander no longer expands "und" to "en-Latn-US"
    cloned.setLanguage("en") catch unreachable;
    cloned.setScript("Latn") catch unreachable;
    if (try cloned.region(gpa)) |region|
        gpa.free(region)
    else
        cloned.setRegion("US") catch unreachable;
    return cloned;
}

/// Remove Likely Subtags
/// https://unicode.org/reports/tr35/#Likely_Subtags
fn removeLikelySubtags(gpa: std.mem.Allocator, input_locale: icu4zig.Locale) std.mem.Allocator.Error!icu4zig.Locale {
    var cloned = try addLikelySubtags(gpa, input_locale);
    const locale_expander = icu4zig.LocaleExpander.init();
    defer locale_expander.deinit();
    _ = locale_expander.minimize(&cloned);
    return cloned;
}

/// 15.2 Properties of the Intl.Locale Constructor
/// https://tc39.es/ecma402/#sec-properties-of-intl-locale-constructor
pub const constructor = struct {
    pub fn create(agent: *Agent, realm: *Realm) std.mem.Allocator.Error!*Object {
        const builtin_function = try createBuiltinFunction(
            agent,
            .{ .constructor = impl },
            1,
            "Locale",
            .{ .realm = realm, .proto = try realm.intrinsic(.function_prototype) },
        );
        return &builtin_function.object;
    }

    pub fn init(agent: *Agent, realm: *Realm, object: *Object) std.mem.Allocator.Error!void {
        // 15.2.1 Intl.Locale.prototype
        // https://tc39.es/ecma402/#sec-Intl.Locale.prototype
        try object.defineBuiltinPropertyWithAttributes(
            agent,
            "prototype",
            Value.from(try realm.intrinsic(.intl_locale_prototype)),
            .none,
        );
    }

    /// 15.1.1 Intl.Locale ( tag [ , options ] )
    /// https://tc39.es/ecma402/#sec-Intl.Locale
    fn impl(agent: *Agent, arguments: Arguments, new_target: ?*Object) Agent.Error!Value {
        const gpa = agent.gpa;
        const tag_value = arguments.get(0);
        const options_value = arguments.get(1);

        // 1. If NewTarget is undefined, throw a TypeError exception.
        if (new_target == null) {
            return agent.throwException(
                .type_error,
                "Intl.Locale must be constructed with 'new'",
                .{},
            );
        }

        // 2. Let localeExtensionKeys be %Intl.Locale%.[[LocaleExtensionKeys]].
        // 3. Let internalSlotsList be « [[InitializedLocale]], [[Locale]], [[Calendar]],
        //    [[Collation]], [[FirstDayOfWeek]], [[HourCycle]], [[NumberingSystem]] ».
        // TODO: 4. If localeExtensionKeys contains "kf", then
        //     a. Append [[CaseFirst]] to internalSlotsList.
        // TODO: 5. If localeExtensionKeys contains "kn", then
        //     a. Append [[Numeric]] to internalSlotsList.
        // 6. Let locale be ? OrdinaryCreateFromConstructor(NewTarget, "%Intl.Locale.prototype%",
        //    internalSlotsList).
        const locale = try ordinaryCreateFromConstructor(
            Locale,
            agent,
            new_target.?,
            .intl_locale_prototype,
            .{ .locale = undefined },
        );

        // 7. If tag is not a String and tag is not an Object, throw a TypeError exception.
        if (!tag_value.isString() and !tag_value.isObject()) {
            return agent.throwException(.type_error, "Locale must be string or object", .{});
        }

        // 8. If tag is an Object and tag has an [[InitializedLocale]] internal slot, then
        const tag_string = if (tag_value.castObject(Locale)) |tag_locale| blk: {
            // a. Set tag to tag.[[Locale]].
            break :blk try String.fromAscii(
                agent,
                try tag_locale.fields.locale.toString(agent.gc_allocator),
            );
        } else blk: {
            // 9. Else,
            // a. Set tag to ? ToString(tag).
            break :blk try tag_value.toString(agent);
        };

        // 10. Set options to ? CoerceOptionsToObject(options).
        const options = try options_value.coerceOptionsToObject(agent);

        // 11. If IsWellFormedLanguageTag(tag) is false, throw a RangeError exception.
        // 12. NOTE: Because LanguageId canonicalization can alter tag in arbitrary ways according
        //     to Alias Rules from `supplementalMetadata.xml`, it is necessary to perform such
        //     canonicalization before applying overrides from options.
        // 13. Set tag to CanonicalizeUnicodeLocaleId(tag).
        const tag_utf8 = try tag_string.toUtf8(gpa);
        defer gpa.free(tag_utf8);
        var tag = icu4zig.Locale.fromString(tag_utf8) catch {
            return agent.throwException(
                .range_error,
                "Invalid locale identifier {f}",
                .{tag_string},
            );
        };

        // 14. Set tag to ? UpdateLanguageId(tag, options).
        tag = try updateLanguageId(agent, tag, options);

        // 15. Let opt be a new Record.

        // 16. Let calendar be ? GetOption(options, "calendar", string, empty, undefined).
        const maybe_calendar = try options.getOption(
            agent,
            "calendar",
            .string,
            null,
            null,
        );

        // 17. If calendar is not undefined, then
        if (maybe_calendar) |calendar| {
            // a. If calendar cannot be matched by the `type` Unicode locale nonterminal, throw a
            //    RangeError exception.
            const calendar_utf8 = try calendar.toUtf8(gpa);
            defer gpa.free(calendar_utf8);
            var value: []const u8 = calendar_utf8;
            // NOTE: Valid strings are length 3-8 but ICU4X doesn't reject length 0 or 2
            var it = std.mem.splitScalar(u8, value, '-');
            while (it.next()) |part| if (part.len < 3) {
                value = "x";
                break;
            };
            tag.setUnicodeExtension("ca", value) catch {
                return agent.throwException(
                    .range_error,
                    "Invalid u-ca subtag '{s}'",
                    .{calendar_utf8},
                );
            };
        }

        // 18. Set opt.[[ca]] to calendar.
        // NOTE: This is done as part of step 16.a.

        // 19. Let collation be ? GetOption(options, "collation", string, empty, undefined).
        const maybe_collation = try options.getOption(
            agent,
            "collation",
            .string,
            null,
            null,
        );

        // 20. If collation is not undefined, then
        if (maybe_collation) |collation| {
            // a. If collation cannot be matched by the `type` Unicode locale nonterminal, throw a
            //    RangeError exception.
            const collation_utf8 = try collation.toUtf8(gpa);
            defer gpa.free(collation_utf8);
            var value: []const u8 = collation_utf8;
            // NOTE: Valid strings are length 3-8 but ICU4X doesn't reject length 0 or 2
            var it = std.mem.splitScalar(u8, value, '-');
            while (it.next()) |part| if (part.len < 3) {
                value = "x";
                break;
            };
            tag.setUnicodeExtension("co", value) catch {
                return agent.throwException(
                    .range_error,
                    "Invalid u-co subtag '{s}'",
                    .{collation_utf8},
                );
            };
        }

        // 21. Set opt.[[co]] to collation.
        // NOTE: This is done as part of step 19.a.

        // 22. Let fw be ? GetOption(options, "firstDayOfWeek", string, empty, undefined).
        const maybe_fw = try options.getOption(agent, "firstDayOfWeek", .string, null, null);

        // 23. If fw is not undefined, then
        if (maybe_fw) |fw| {
            // a. Set fw to WeekdayToUValue(fw).
            // b. If fw cannot be matched by the `type` Unicode locale nonterminal, throw a
            //    RangeError exception.
            const fw_utf8 = try fw.toUtf8(gpa);
            defer gpa.free(fw_utf8);
            var value: []const u8 = weekdayToUValue(fw_utf8);
            // NOTE: Valid strings are length 3-8 but ICU4X doesn't reject length 0 or 2
            var it = std.mem.splitScalar(u8, value, '-');
            while (it.next()) |part| if (part.len < 3) {
                value = "x";
                break;
            };
            tag.setUnicodeExtension("fw", value) catch {
                return agent.throwException(
                    .range_error,
                    "Invalid u-fw subtag '{s}'",
                    .{fw_utf8},
                );
            };
        }

        // 24. Set opt.[[fw]] to fw.
        // NOTE: This is done as part of step 22.a.

        // 25. Let hc be ? GetOption(options, "hourCycle", string, « "h11", "h12", "h23", "h24" »,
        //     undefined).
        const maybe_hc = try options.getOption(
            agent,
            "hourCycle",
            .string,
            &.{
                String.fromLiteral("h11"),
                String.fromLiteral("h12"),
                String.fromLiteral("h23"),
                String.fromLiteral("h24"),
            },
            null,
        );

        // 26. Set opt.[[hc]] to hc.
        if (maybe_hc) |hc| {
            tag.setUnicodeExtension("hc", hc.asAscii()) catch unreachable;
        }

        // 27. Let kf be ? GetOption(options, "caseFirst", string, « "upper", "lower", "false" »,
        //     undefined).
        const maybe_kf = try options.getOption(
            agent,
            "caseFirst",
            .string,
            &.{
                String.fromLiteral("upper"),
                String.fromLiteral("lower"),
                String.fromLiteral("false"),
            },
            null,
        );

        // 28. Set opt.[[kf]] to kf.
        if (maybe_kf) |kf| {
            tag.setUnicodeExtension("kf", kf.asAscii()) catch unreachable;
        }

        // 29. Let kn be ? GetOption(options, "numeric", boolean, empty, undefined).
        const maybe_kn = try options.getOption(agent, "numeric", .boolean, null, null);

        // 30. If kn is not undefined, set kn to ! ToString(kn).
        // 31. Set opt.[[kn]] to kn.
        if (maybe_kn) |kn| {
            tag.setUnicodeExtension("kn", if (kn) "true" else "false") catch unreachable;
        }

        // 32. Let numberingSystem be ? GetOption(options, "numberingSystem", string, empty,
        //     undefined).
        const maybe_numbering_system = try options.getOption(
            agent,
            "numberingSystem",
            .string,
            null,
            null,
        );

        // 33. If numberingSystem is not undefined, then
        if (maybe_numbering_system) |numbering_system| {
            // a. If numberingSystem cannot be matched by the `type` Unicode locale nonterminal,
            //    throw a RangeError exception.
            const numbering_system_utf8 = try numbering_system.toUtf8(gpa);
            defer gpa.free(numbering_system_utf8);
            var value: []const u8 = numbering_system_utf8;
            // NOTE: Valid strings are length 3-8 but ICU4X doesn't reject length 0 or 2
            var it = std.mem.splitScalar(u8, value, '-');
            while (it.next()) |part| if (part.len < 3) {
                value = "x";
                break;
            };
            tag.setUnicodeExtension("nu", value) catch {
                return agent.throwException(
                    .range_error,
                    "Invalid u-nu subtag '{s}'",
                    .{numbering_system_utf8},
                );
            };
        }

        // 34. Set opt.[[nu]] to numberingSystem.
        // NOTE: This is done as part of step 32.a.

        locale.fields = .{
            // 35. Let localeRecord be MakeLocaleRecord(tag, opt, localeExtensionKeys).
            // 36. Set locale.[[Locale]] to localeRecord.[[locale]].
            // 37. Set locale.[[Calendar]] to localeRecord.[[ca]].
            // 38. Set locale.[[Collation]] to localeRecord.[[co]].
            // 39. Set locale.[[FirstDayOfWeek]] to localeRecord.[[fw]].
            // 40. Set locale.[[HourCycle]] to localeRecord.[[hc]].
            // 41. If localeExtensionKeys contains "kf", then
            //     a. Set locale.[[CaseFirst]] to localeRecord.[[kf]].
            // 42. If localeExtensionKeys contains "kn", then
            //     a. If localeRecord.[[kn]] is either "true" or the empty String, then
            //         i. Set locale.[[Numeric]] to true.
            //     b. Else,
            //         i. Set locale.[[Numeric]] to false.
            // 43. Set locale.[[NumberingSystem]] to localeRecord.[[nu]].
            .locale = tag,
        };

        // 44. Return locale.
        return Value.from(&locale.object);
    }
};

/// 15.3 Properties of the Intl.Locale Prototype Object
/// https://tc39.es/ecma402/#sec-properties-of-intl-locale-prototype-object
pub const prototype = struct {
    pub fn create(agent: *Agent, realm: *Realm) std.mem.Allocator.Error!*Object {
        return ordinaryObjectCreate(agent, try realm.intrinsic(.object_prototype));
    }

    pub fn init(agent: *Agent, realm: *Realm, object: *Object) std.mem.Allocator.Error!void {
        try object.defineBuiltinAccessor(agent, "baseName", baseName, null, realm);
        try object.defineBuiltinAccessor(agent, "calendar", calendar, null, realm);
        try object.defineBuiltinAccessor(agent, "caseFirst", caseFirst, null, realm);
        try object.defineBuiltinAccessor(agent, "collation", collation, null, realm);
        try object.defineBuiltinAccessor(agent, "firstDayOfWeek", firstDayOfWeek, null, realm);
        try object.defineBuiltinAccessor(agent, "hourCycle", hourCycle, null, realm);
        try object.defineBuiltinAccessor(agent, "language", language, null, realm);
        try object.defineBuiltinFunction(agent, "maximize", maximize, 0, realm);
        try object.defineBuiltinFunction(agent, "minimize", minimize, 0, realm);
        try object.defineBuiltinAccessor(agent, "numberingSystem", numberingSystem, null, realm);
        try object.defineBuiltinAccessor(agent, "numeric", numeric, null, realm);
        try object.defineBuiltinAccessor(agent, "region", region, null, realm);
        try object.defineBuiltinAccessor(agent, "script", script, null, realm);
        try object.defineBuiltinFunction(agent, "toString", toString, 0, realm);
        try object.defineBuiltinAccessor(agent, "variants", variants, null, realm);

        // 15.3.1 Intl.Locale.prototype.constructor
        // https://tc39.es/ecma402/#sec-Intl.Locale.prototype.constructor
        try object.defineBuiltinProperty(
            agent,
            "constructor",
            Value.from(try realm.intrinsic(.intl_locale)),
        );

        // 15.3.24 Intl.Locale.prototype [ %Symbol.toStringTag% ]
        // https://tc39.es/ecma402/#sec-intl.locale.prototype-%symbol.tostringtag%
        try object.defineBuiltinPropertyWithAttributes(
            agent,
            "Symbol.toStringTag",
            Value.from("Intl.Locale"),
            .{
                .writable = false,
                .enumerable = false,
                .configurable = true,
            },
        );
    }

    /// 15.3.2 get Intl.Locale.prototype.baseName
    /// https://tc39.es/ecma402/#sec-Intl.Locale.prototype.baseName
    fn baseName(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let loc be the this value.
        // 2. Perform ? RequireInternalSlot(loc, [[InitializedLocale]]).
        const locale = try this_value.requireInternalSlot(agent, Locale);

        // 3. Return GetLocaleBaseName(loc.[[Locale]]).
        return Value.from(
            try String.fromAscii(agent, try locale.fields.locale.basename(agent.gc_allocator)),
        );
    }

    /// 15.3.3 get Intl.Locale.prototype.calendar
    /// https://tc39.es/ecma402/#sec-Intl.Locale.prototype.calendar
    fn calendar(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let loc be the this value.
        // 2. Perform ? RequireInternalSlot(loc, [[InitializedLocale]]).
        const locale = try this_value.requireInternalSlot(agent, Locale);

        // 3. Return loc.[[Calendar]].
        return Value.from(
            try String.fromAscii(
                agent,
                locale.fields.locale.getUnicodeExtension(
                    agent.gc_allocator,
                    "ca",
                ) catch |err| switch (err) {
                    error.OutOfMemory => |e| return e,
                } orelse return .undefined,
            ),
        );
    }

    /// 15.3.4 get Intl.Locale.prototype.caseFirst
    /// https://tc39.es/ecma402/#sec-Intl.Locale.prototype.caseFirst
    fn caseFirst(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let loc be the this value.
        // 2. Perform ? RequireInternalSlot(loc, [[InitializedLocale]]).
        const locale = try this_value.requireInternalSlot(agent, Locale);

        // 3. Return loc.[[CaseFirst]].
        return Value.from(
            try String.fromAscii(
                agent,
                locale.fields.locale.getUnicodeExtension(
                    agent.gc_allocator,
                    "kf",
                ) catch |err| switch (err) {
                    error.OutOfMemory => |e| return e,
                } orelse return .undefined,
            ),
        );
    }

    /// 15.3.5 get Intl.Locale.prototype.collation
    /// https://tc39.es/ecma402/#sec-Intl.Locale.prototype.collation
    fn collation(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let loc be the this value.
        // 2. Perform ? RequireInternalSlot(loc, [[InitializedLocale]]).
        const locale = try this_value.requireInternalSlot(agent, Locale);

        // 3. Return loc.[[Collation]].
        return Value.from(
            try String.fromAscii(
                agent,
                locale.fields.locale.getUnicodeExtension(
                    agent.gc_allocator,
                    "co",
                ) catch |err| switch (err) {
                    error.OutOfMemory => |e| return e,
                } orelse return .undefined,
            ),
        );
    }

    /// 15.3.6 get Intl.Locale.prototype.firstDayOfWeek
    /// https://tc39.es/ecma402/#sec-Intl.Locale.prototype.firstDayOfWeek
    fn firstDayOfWeek(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let loc be the this value.
        // 2. Perform ? RequireInternalSlot(loc, [[InitializedLocale]]).
        const locale = try this_value.requireInternalSlot(agent, Locale);

        // 3. Return loc.[[FirstDayOfWeek]].
        return Value.from(
            try String.fromAscii(
                agent,
                locale.fields.locale.getUnicodeExtension(
                    agent.gc_allocator,
                    "fw",
                ) catch |err| switch (err) {
                    error.OutOfMemory => |e| return e,
                } orelse return .undefined,
            ),
        );
    }

    /// 15.3.7 get Intl.Locale.prototype.hourCycle
    /// https://tc39.es/ecma402/#sec-Intl.Locale.prototype.hourCycle
    fn hourCycle(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let loc be the this value.
        // 2. Perform ? RequireInternalSlot(loc, [[InitializedLocale]]).
        const locale = try this_value.requireInternalSlot(agent, Locale);

        // 3. Return loc.[[HourCycle]].
        return Value.from(
            try String.fromAscii(
                agent,
                locale.fields.locale.getUnicodeExtension(
                    agent.gc_allocator,
                    "hc",
                ) catch |err| switch (err) {
                    error.OutOfMemory => |e| return e,
                } orelse return .undefined,
            ),
        );
    }

    /// 15.3.8 get Intl.Locale.prototype.language
    /// https://tc39.es/ecma402/#sec-Intl.Locale.prototype.language
    fn language(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let loc be the this value.
        // 2. Perform ? RequireInternalSlot(loc, [[InitializedLocale]]).
        const locale = try this_value.requireInternalSlot(agent, Locale);

        // 3. Return GetLocaleLanguage(loc.[[Locale]]).
        return Value.from(
            try String.fromAscii(
                agent,
                try locale.fields.locale.language(agent.gc_allocator),
            ),
        );
    }

    /// 15.3.9 Intl.Locale.prototype.maximize ( )
    /// https://tc39.es/ecma402/#sec-Intl.Locale.prototype.maximize
    fn maximize(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        const gpa = agent.gpa;
        const realm = agent.currentRealm();

        // 1. Let loc be the this value.
        // 2. Perform ? RequireInternalSlot(loc, [[InitializedLocale]]).
        const locale = try this_value.requireInternalSlot(agent, Locale);

        // 3. Let maximal be the result of the Add Likely Subtags algorithm applied to
        //    loc.[[Locale]]. If an error is signaled, set maximal to loc.[[Locale]].
        const maximal = try addLikelySubtags(gpa, locale.fields.locale);

        // 4. Return ! Construct(%Intl.Locale%, « maximal »).
        const new_locale = ordinaryCreateFromConstructor(
            Locale,
            agent,
            try realm.intrinsic(.intl_locale),
            .intl_locale_prototype,
            .{ .locale = maximal },
        ) catch |err| try noexcept(err);
        return Value.from(&new_locale.object);
    }

    /// 15.3.10 Intl.Locale.prototype.minimize ( )
    /// https://tc39.es/ecma402/#sec-Intl.Locale.prototype.minimize
    fn minimize(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        const gpa = agent.gpa;
        const realm = agent.currentRealm();

        // 1. Let loc be the this value.
        // 2. Perform ? RequireInternalSlot(loc, [[InitializedLocale]]).
        const locale = try this_value.requireInternalSlot(agent, Locale);

        // 3. Let minimal be the result of the Remove Likely Subtags algorithm applied to
        //    loc.[[Locale]]. If an error is signaled, set minimal to loc.[[Locale]].
        const minimal = try removeLikelySubtags(gpa, locale.fields.locale);

        // 4. Return ! Construct(%Intl.Locale%, « minimal »).
        const new_locale = ordinaryCreateFromConstructor(
            Locale,
            agent,
            try realm.intrinsic(.intl_locale),
            .intl_locale_prototype,
            .{ .locale = minimal },
        ) catch |err| try noexcept(err);
        return Value.from(&new_locale.object);
    }

    /// 15.3.11 get Intl.Locale.prototype.numberingSystem
    /// https://tc39.es/ecma402/#sec-Intl.Locale.prototype.numberingSystem
    fn numberingSystem(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let loc be the this value.
        // 2. Perform ? RequireInternalSlot(loc, [[InitializedLocale]]).
        const locale = try this_value.requireInternalSlot(agent, Locale);

        // 3. Return loc.[[NumberingSystem]].
        return Value.from(
            try String.fromAscii(
                agent,
                locale.fields.locale.getUnicodeExtension(
                    agent.gc_allocator,
                    "nu",
                ) catch |err| switch (err) {
                    error.OutOfMemory => |e| return e,
                } orelse return .undefined,
            ),
        );
    }

    /// 15.3.12 get Intl.Locale.prototype.numeric
    /// https://tc39.es/ecma402/#sec-Intl.Locale.prototype.numeric
    fn numeric(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let loc be the this value.
        // 2. Perform ? RequireInternalSlot(loc, [[InitializedLocale]]).
        const locale = try this_value.requireInternalSlot(agent, Locale);

        // 3. Return loc.[[Numeric]].
        const value = locale.fields.locale.getUnicodeExtension(
            agent.gc_allocator,
            "kn",
        ) catch |err| switch (err) {
            error.OutOfMemory => |e| return e,
        } orelse return .false;
        return Value.from(value.len == 0 or std.mem.eql(u8, value, "true"));
    }

    /// 15.3.13 get Intl.Locale.prototype.region
    /// https://tc39.es/ecma402/#sec-Intl.Locale.prototype.region
    fn region(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let loc be the this value.
        // 2. Perform ? RequireInternalSlot(loc, [[InitializedLocale]]).
        const locale = try this_value.requireInternalSlot(agent, Locale);

        // 3. Return GetLocaleRegion(loc.[[Locale]]).
        return Value.from(
            try String.fromAscii(
                agent,
                try locale.fields.locale.region(agent.gc_allocator) orelse return .undefined,
            ),
        );
    }

    /// 15.3.14 get Intl.Locale.prototype.script
    /// https://tc39.es/ecma402/#sec-Intl.Locale.prototype.script
    fn script(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let loc be the this value.
        // 2. Perform ? RequireInternalSlot(loc, [[InitializedLocale]]).
        const locale = try this_value.requireInternalSlot(agent, Locale);

        // 3. Return GetLocaleScript(loc.[[Locale]]).
        return Value.from(
            try String.fromAscii(
                agent,
                try locale.fields.locale.script(agent.gc_allocator) orelse return .undefined,
            ),
        );
    }

    /// 15.3.15 Intl.Locale.prototype.toString ( )
    /// https://tc39.es/ecma402/#sec-Intl.Locale.prototype.toString
    fn toString(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let loc be the this value.
        // 2. Perform ? RequireInternalSlot(loc, [[InitializedLocale]]).
        const locale = try this_value.requireInternalSlot(agent, Locale);

        // 3. Return loc.[[Locale]].
        return Value.from(
            try String.fromAscii(agent, try locale.fields.locale.toString(agent.gc_allocator)),
        );
    }

    /// 15.3.23 get Intl.Locale.prototype.variants
    /// https://tc39.es/ecma402/#sec-Intl.Locale.prototype.variants
    fn variants(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let loc be the this value.
        // 2. Perform ? RequireInternalSlot(loc, [[InitializedLocale]]).
        const locale = try this_value.requireInternalSlot(agent, Locale);

        // 3. Return GetLocaleVariants(loc.[[Locale]]).
        const value = try locale.fields.locale.variants(agent.gc_allocator);
        if (value.len == 0) return .undefined;
        return Value.from(try String.fromAscii(agent, value));
    }
};

/// 15.4 Properties of Intl.Locale Instances
/// https://tc39.es/ecma402/#sec-properties-of-intl-locale-instances
pub const Locale = MakeObject(.{
    .Fields = struct {
        /// [[Locale]]
        locale: icu4zig.Locale,
    },
    .tag = .intl_locale,
    .display_name = "Intl.Locale",
});

/// 15.5.15 WeekdayToUValue ( fw )
/// https://tc39.es/ecma402/#sec-weekdaytouvalue
fn weekdayToUValue(weekday: []const u8) []const u8 {
    // 1. For each row of Table 26, except the header row, in table order, do
    //     a. Let weekday be the Weekday value of the current row.
    //     b. Let string be the String value of the current row.
    //     c. If fw is equal to weekday, return string.
    // 2. Return fw.
    return std.StaticStringMap([]const u8).initComptime(&.{
        .{ "0", "sun" },
        .{ "1", "mon" },
        .{ "2", "tue" },
        .{ "3", "wed" },
        .{ "4", "thu" },
        .{ "5", "fri" },
        .{ "6", "sat" },
        .{ "7", "sun" },
    }).get(weekday) orelse weekday;
}
