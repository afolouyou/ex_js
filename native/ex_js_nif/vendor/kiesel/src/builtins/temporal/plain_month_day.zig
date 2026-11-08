//! 10 Temporal.PlainMonthDay Objects
//! https://tc39.es/proposal-temporal/#sec-temporal-plainmonthday-objects

const std = @import("std");

const temporal_rs = @import("temporal_rs");

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
const canonicalizeCalendar = builtins.canonicalizeCalendar;
const createBuiltinFunction = builtins.createBuiltinFunction;
const createTemporalDate = builtins.createTemporalDate;
const getTemporalCalendarIdentifierWithISODefault = builtins.getTemporalCalendarIdentifierWithISODefault;
const getTemporalOverflowOption = builtins.getTemporalOverflowOption;
const getTemporalShowCalendarNameOption = builtins.getTemporalShowCalendarNameOption;
const isPartialTemporalObject = builtins.isPartialTemporalObject;
const isValidISODate = builtins.isValidISODate;
const noexcept = utils.noexcept;
const ordinaryCreateFromConstructor = builtins.ordinaryCreateFromConstructor;
const ordinaryObjectCreate = builtins.ordinaryObjectCreate;
const prepareCalendarFields = builtins.prepareCalendarFields;

/// 10.2 Properties of the Temporal.PlainMonthDay Constructor
/// https://tc39.es/proposal-temporal/#sec-properties-of-the-temporal-plainmonthday-constructor
pub const constructor = struct {
    pub fn create(agent: *Agent, realm: *Realm) std.mem.Allocator.Error!*Object {
        const builtin_function = try createBuiltinFunction(
            agent,
            .{ .constructor = impl },
            2,
            "PlainMonthDay",
            .{ .realm = realm, .proto = try realm.intrinsic(.function_prototype) },
        );
        return &builtin_function.object;
    }

    pub fn init(agent: *Agent, realm: *Realm, object: *Object) std.mem.Allocator.Error!void {
        try object.defineBuiltinFunction(agent, "from", from, 1, realm);

        // 10.2.1 Temporal.PlainMonthDay.prototype
        // https://tc39.es/proposal-temporal/#sec-temporal.plainmonthday.prototype
        try object.defineBuiltinPropertyWithAttributes(
            agent,
            "prototype",
            Value.from(try realm.intrinsic(.temporal_plain_month_day_prototype)),
            .{
                .writable = false,
                .enumerable = false,
                .configurable = false,
            },
        );
    }

    /// 10.1.1 Temporal.PlainMonthDay ( isoMonth, isoDay [ , calendar [ , referenceISOYear ] ] )
    /// https://tc39.es/proposal-temporal/#sec-temporal.plainmonthday
    fn impl(agent: *Agent, arguments: Arguments, maybe_new_target: ?*Object) Agent.Error!Value {
        const iso_month_value = arguments.get(0);
        const iso_day_value = arguments.get(1);
        var calendar_value = arguments.get(2);
        var reference_iso_year_value = arguments.get(3);

        // 1. If NewTarget is undefined, throw a TypeError exception.
        const new_target = maybe_new_target orelse {
            return agent.throwException(
                .type_error,
                "Temporal.PlainMonthDay must be constructed with 'new'",
                .{},
            );
        };

        // 2. If referenceISOYear is undefined, then
        //     a. Set referenceISOYear to 1972𝔽 (the first ISO 8601 leap year after the epoch).
        if (reference_iso_year_value.isUndefined()) reference_iso_year_value = Value.from(1972);

        // 3. Let m be ? ToIntegerWithTruncation(isoMonth).
        const iso_month = try iso_month_value.toIntegerWithTruncation(agent);

        // 4. Let d be ? ToIntegerWithTruncation(isoDay).
        const iso_day = try iso_day_value.toIntegerWithTruncation(agent);

        // 5. If calendar is undefined, set calendar to "iso8601".
        if (calendar_value.isUndefined()) calendar_value = Value.from("iso8601");

        // 6. If calendar is not a String, throw a TypeError exception.
        if (!calendar_value.isString()) {
            return agent.throwException(.type_error, "Calendar is not a string", .{});
        }

        // 7. Set calendar to ? CanonicalizeCalendar(calendar).
        const calendar = try canonicalizeCalendar(agent, calendar_value.asString());

        // 8. Let y be ? ToIntegerWithTruncation(referenceISOYear).
        const reference_iso_year = try reference_iso_year_value.toIntegerWithTruncation(agent);

        // 9. If IsValidISODate(y, m, d) is false, throw a RangeError exception.
        if (!isValidISODate(reference_iso_year, iso_month, iso_day)) {
            return agent.throwException(.range_error, "Invalid ISO date", .{});
        }

        // 10. Let isoDate be CreateISODateRecord(y, m, d).
        // 11. Return ? CreateTemporalMonthDay(isoDate, calendar, NewTarget).
        const temporal_rs_plain_month_day = try builtins.temporal.extractResult(
            agent,
            temporal_rs.c.temporal_rs_PlainMonthDay_try_new_with_overflow(
                @intFromFloat(iso_month),
                @intFromFloat(iso_day),
                calendar,
                temporal_rs.c.ArithmeticOverflow_Reject,
                temporal_rs.toOption(temporal_rs.c.OptionI32, @intFromFloat(reference_iso_year)),
            ),
        );
        errdefer temporal_rs.c.temporal_rs_PlainMonthDay_destroy(temporal_rs_plain_month_day.?);
        const plain_month_day = try createTemporalMonthDay(agent, temporal_rs_plain_month_day.?, new_target);
        return Value.from(&plain_month_day.object);
    }

    /// 10.2.2 Temporal.PlainMonthDay.from ( item [ , options ] )
    /// https://tc39.es/proposal-temporal/#sec-temporal.plainmonthday.from
    fn from(agent: *Agent, _: Value, arguments: Arguments) Agent.Error!Value {
        const item = arguments.get(0);
        const options = arguments.get(1);

        // 1. Return ? ToTemporalMonthDay(item, options).
        const plain_month_day = try toTemporalPlainMonthDay(agent, item, options);
        return Value.from(&plain_month_day.object);
    }
};

/// 10.3 Properties of the Temporal.PlainMonthDay Prototype Object
/// https://tc39.es/proposal-temporal/#sec-properties-of-the-temporal-plainmonthday-prototype-object
pub const prototype = struct {
    pub fn create(agent: *Agent, realm: *Realm) std.mem.Allocator.Error!*Object {
        return ordinaryObjectCreate(agent, try realm.intrinsic(.object_prototype));
    }

    pub fn init(agent: *Agent, realm: *Realm, object: *Object) std.mem.Allocator.Error!void {
        try object.defineBuiltinAccessor(agent, "calendarId", calendarId, null, realm);
        try object.defineBuiltinAccessor(agent, "day", day, null, realm);
        try object.defineBuiltinFunction(agent, "equals", equals, 1, realm);
        try object.defineBuiltinAccessor(agent, "monthCode", monthCode, null, realm);
        try object.defineBuiltinFunction(agent, "toJSON", toJSON, 0, realm);
        try object.defineBuiltinFunction(agent, "toLocaleString", toLocaleString, 0, realm);
        try object.defineBuiltinFunction(agent, "toPlainDate", toPlainDate, 1, realm);
        try object.defineBuiltinFunction(agent, "toString", toString, 0, realm);
        try object.defineBuiltinFunction(agent, "valueOf", valueOf, 0, realm);
        try object.defineBuiltinFunction(agent, "with", with, 1, realm);

        // 10.3.1 Temporal.PlainMonthDay.prototype.constructor
        // https://tc39.es/proposal-temporal/#sec-temporal.plainmonthday.prototype.constructor
        try object.defineBuiltinProperty(
            agent,
            "constructor",
            Value.from(try realm.intrinsic(.temporal_plain_month_day)),
        );

        // 10.3.2 Temporal.PlainMonthDay.prototype[ %Symbol.toStringTag% ]
        // https://tc39.es/proposal-temporal/#sec-temporal.plainmonthday.prototype-%symbol.tostringtag%
        try object.defineBuiltinPropertyWithAttributes(
            agent,
            "Symbol.toStringTag",
            Value.from("Temporal.PlainMonthDay"),
            .{
                .writable = false,
                .enumerable = false,
                .configurable = true,
            },
        );
    }

    /// 10.3.3 get Temporal.PlainMonthDay.prototype.calendarId
    /// https://tc39.es/proposal-temporal/#sec-get-temporal.plainmonthday.prototype.calendarid
    fn calendarId(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let plainMonthDay be the this value.
        // 2. Perform ? RequireInternalSlot(plainMonthDay, [[InitializedTemporalMonthDay]]).
        const plain_month_day = try this_value.requireInternalSlot(agent, PlainMonthDay);

        // 3. Return plainMonthDay.[[Calendar]].
        const temporal_rs_calendar = temporal_rs.c.temporal_rs_PlainMonthDay_calendar(
            plain_month_day.fields.inner,
        );
        const calendar_id = temporal_rs.fromDiplomatStringView(
            temporal_rs.c.temporal_rs_Calendar_identifier(temporal_rs_calendar.?),
        );
        return Value.from(
            try String.fromAscii(agent, try agent.gc_allocator.dupe(u8, calendar_id)),
        );
    }

    /// 10.3.5 get Temporal.PlainMonthDay.prototype.day
    /// https://tc39.es/proposal-temporal/#sec-get-temporal.plainmonthday.prototype.day
    fn day(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let plainMonthDay be the this value.
        // 2. Perform ? RequireInternalSlot(plainMonthDay, [[InitializedTemporalMonthDay]]).
        const plain_month_day = try this_value.requireInternalSlot(agent, PlainMonthDay);

        // 3. Return 𝔽(CalendarISOToDate(plainMonthDay.[[Calendar]],
        //    plainMonthDay.[[ISODate]]).[[Day]]).
        return Value.from(temporal_rs.c.temporal_rs_PlainMonthDay_day(plain_month_day.fields.inner));
    }

    /// 10.3.7 Temporal.PlainMonthDay.prototype.equals ( other )
    /// https://tc39.es/proposal-temporal/#sec-temporal.plainmonthday.prototype.equals
    fn equals(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const other_value = arguments.get(0);

        // 1. Let plainMonthDay be the this value.
        // 2. Perform ? RequireInternalSlot(plainMonthDay, [[InitializedTemporalMonthDay]]).
        const plain_month_day = try this_value.requireInternalSlot(agent, PlainMonthDay);

        // 3. Set other to ? ToTemporalMonthDay(other).
        const other = try toTemporalPlainMonthDay(agent, other_value, null);

        // 4. If CompareISODate(plainMonthDay.[[ISODate]], other.[[ISODate]]) ≠ 0, return false.
        // 5. Return CalendarEquals(plainMonthDay.[[Calendar]], other.[[Calendar]]).
        return Value.from(
            temporal_rs.c.temporal_rs_PlainMonthDay_equals(
                plain_month_day.fields.inner,
                other.fields.inner,
            ),
        );
    }

    /// 10.3.4 get Temporal.PlainMonthDay.prototype.monthCode
    /// https://tc39.es/proposal-temporal/#sec-get-temporal.plainmonthday.prototype.monthcode
    fn monthCode(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let plainMonthDay be the this value.
        // 2. Perform ? RequireInternalSlot(plainMonthDay, [[InitializedTemporalMonthDay]]).
        const plain_month_day = try this_value.requireInternalSlot(agent, PlainMonthDay);

        // 3. Return CalendarISOToDate(plainMonthDay.[[Calendar]],
        //    plainMonthDay.[[ISODate]]).[[MonthCode]].
        var write = temporal_rs.DiplomatWrite.init(agent.gc_allocator);
        temporal_rs.c.temporal_rs_PlainMonthDay_month_code(
            plain_month_day.fields.inner,
            &write.inner,
        );
        return Value.from(try String.fromAscii(agent, try write.toOwnedSlice()));
    }

    /// 10.3.10 Temporal.PlainMonthDay.prototype.toJSON ( )
    /// https://tc39.es/proposal-temporal/#sec-temporal.plainmonthday.prototype.tojson
    fn toJSON(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let plainMonthDay be the this value.
        // 2. Perform ? RequireInternalSlot(plainMonthDay, [[InitializedTemporalMonthDay]]).
        const plain_month_day = try this_value.requireInternalSlot(agent, PlainMonthDay);

        // 3. Return TemporalMonthDayToString(plainMonthDay, auto).
        var write = temporal_rs.DiplomatWrite.init(agent.gc_allocator);
        temporal_rs.c.temporal_rs_PlainMonthDay_to_ixdtf_string(
            plain_month_day.fields.inner,
            temporal_rs.c.DisplayCalendar_Auto,
            &write.inner,
        );
        return Value.from(try String.fromAscii(agent, try write.toOwnedSlice()));
    }

    /// 10.3.9 Temporal.PlainMonthDay.prototype.toLocaleString ( [ locales [ , options ] ] )
    /// https://tc39.es/proposal-temporal/#sec-temporal.plainmonthday.prototype.tolocalestring
    fn toLocaleString(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let plainMonthDay be the this value.
        // 2. Perform ? RequireInternalSlot(plainMonthDay, [[InitializedTemporalMonthDay]]).
        const plain_month_day = try this_value.requireInternalSlot(agent, PlainMonthDay);

        // 3. Return TemporalMonthDayToString(plainMonthDay, auto).
        var write = temporal_rs.DiplomatWrite.init(agent.gc_allocator);
        temporal_rs.c.temporal_rs_PlainMonthDay_to_ixdtf_string(
            plain_month_day.fields.inner,
            temporal_rs.c.DisplayCalendar_Auto,
            &write.inner,
        );
        return Value.from(try String.fromAscii(agent, try write.toOwnedSlice()));
    }

    /// 10.3.12 Temporal.PlainMonthDay.prototype.toPlainDate ( item )
    /// https://tc39.es/proposal-temporal/#sec-temporal.plainmonthday.prototype.toplaindate
    fn toPlainDate(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const item = arguments.get(0);

        // 1. Let plainMonthDay be the this value.
        // 2. Perform ? RequireInternalSlot(plainMonthDay, [[InitializedTemporalMonthDay]]).
        const plain_month_day = try this_value.requireInternalSlot(agent, PlainMonthDay);

        // 3. If item is not an Object, throw a TypeError exception.
        if (!item.isObject()) {
            return agent.throwException(.type_error, "Item must be an object", .{});
        }

        // 4. Let calendar be plainMonthDay.[[Calendar]].
        const calendar = temporal_rs.c.temporal_rs_Calendar_kind(
            temporal_rs.c.temporal_rs_PlainMonthDay_calendar(plain_month_day.fields.inner),
        );

        // 5. Let fields be ISODateToFields(calendar, plainMonthDay.[[ISODate]], month-day).
        // 6. Let inputFields be ? PrepareCalendarFields(calendar, item, « year », « », « »).
        // 7. Let mergedFields be CalendarMergeFields(calendar, fields, inputFields).
        const fields = try prepareCalendarFields(
            agent,
            calendar,
            item.asObject(),
            .initOne(.year),
            .none,
        );
        const partial = fields.date;

        // 8. Let isoDate be ? CalendarDateFromFields(calendar, mergedFields, constrain).
        const temporal_rs_plain_date = try builtins.temporal.extractResult(
            agent,
            temporal_rs.c.temporal_rs_PlainMonthDay_to_plain_date(
                plain_month_day.fields.inner,
                temporal_rs.toPartialDateOption(partial),
            ),
        );
        errdefer temporal_rs.c.temporal_rs_PlainDate_destroy(temporal_rs_plain_date.?);

        // 9. Return ! CreateTemporalDate(isoDate, calendar).
        const plain_date = createTemporalDate(
            agent,
            temporal_rs_plain_date.?,
            null,
        ) catch |err| try noexcept(err);
        return Value.from(&plain_date.object);
    }

    /// 10.3.8 Temporal.PlainMonthDay.prototype.toString ( [ options ] )
    /// https://tc39.es/proposal-temporal/#sec-temporal.plainmonthday.prototype.tostring
    fn toString(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const options_value = arguments.get(0);

        // 1. Let plainMonthDay be the this value.
        // 2. Perform ? RequireInternalSlot(plainMonthDay, [[InitializedTemporalMonthDay]]).
        const plain_month_day = try this_value.requireInternalSlot(agent, PlainMonthDay);

        // 3. Let resolvedOptions be ? GetOptionsObject(options).
        const options = try options_value.getOptionsObject(agent);

        // 4. Let showCalendar be ? GetTemporalShowCalendarNameOption(resolvedOptions).
        const show_calendar = try getTemporalShowCalendarNameOption(agent, options);

        // 5. Return TemporalMonthDayToString(plainMonthDay, showCalendar).
        var write = temporal_rs.DiplomatWrite.init(agent.gc_allocator);
        temporal_rs.c.temporal_rs_PlainMonthDay_to_ixdtf_string(
            plain_month_day.fields.inner,
            show_calendar,
            &write.inner,
        );
        return Value.from(try String.fromAscii(agent, try write.toOwnedSlice()));
    }

    /// 10.3.11 Temporal.PlainMonthDay.prototype.valueOf ( )
    /// https://tc39.es/proposal-temporal/#sec-temporal.plainmonthday.prototype.valueof
    fn valueOf(agent: *Agent, _: Value, _: Arguments) Agent.Error!Value {
        // 1. Throw a TypeError exception.
        return agent.throwException(
            .type_error,
            "Cannot convert Temporal.PlainMonthDay to primitive value",
            .{},
        );
    }

    /// 10.3.6 Temporal.PlainMonthDay.prototype.with ( temporalMonthDayLike [ , options ] )
    /// https://tc39.es/proposal-temporal/#sec-temporal.plainmonthday.prototype.with
    fn with(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const temporal_month_day_like = arguments.get(0);
        const options_value = arguments.get(1);

        // 1. Let plainMonthDay be the this value.
        // 2. Perform ? RequireInternalSlot(plainMonthDay, [[InitializedTemporalMonthDay]]).
        const plain_month_day = try this_value.requireInternalSlot(agent, PlainMonthDay);

        // 3. If ? IsPartialTemporalObject(temporalMonthDayLike) is false, throw a TypeError
        //    exception.
        if (!try isPartialTemporalObject(agent, temporal_month_day_like)) {
            return agent.throwException(
                .type_error,
                "Argument must be a partial temporal object",
                .{},
            );
        }

        // 4. Let calendar be plainMonthDay.[[Calendar]].
        const calendar = temporal_rs.c.temporal_rs_Calendar_kind(
            temporal_rs.c.temporal_rs_PlainMonthDay_calendar(plain_month_day.fields.inner),
        );

        // 5. Let fields be ISODateToFields(calendar, plainMonthDay.[[ISODate]], month-day).
        // 6. Let partialMonthDay be ? PrepareCalendarFields(calendar, temporalMonthDayLike, « year,
        //    month, month-code, day », « », partial).
        // 7. Set fields to CalendarMergeFields(calendar, fields, partialMonthDay).
        const fields = try prepareCalendarFields(
            agent,
            calendar,
            temporal_month_day_like.asObject(),
            .initMany(&.{ .year, .month, .month_code, .day }),
            .partial,
        );
        const partial = fields.date;

        // 8. Let resolvedOptions be ? GetOptionsObject(options).
        const options = try options_value.getOptionsObject(agent);

        // 9. Let overflow be ? GetTemporalOverflowOption(resolvedOptions).
        const overflow = try getTemporalOverflowOption(agent, options);

        // 10. Let isoDate be ? CalendarMonthDayFromFields(calendar, fields, overflow).
        // 11. Return ! CreateTemporalMonthDay(isoDate, calendar).
        const temporal_rs_plain_month_day = try builtins.temporal.extractResult(
            agent,
            temporal_rs.c.temporal_rs_PlainMonthDay_with(
                plain_month_day.fields.inner,
                partial,
                temporal_rs.toArithmeticOverflowOption(overflow),
            ),
        );
        errdefer temporal_rs.c.temporal_rs_PlainMonthDay_destroy(temporal_rs_plain_month_day.?);
        const new_plain_month_day = createTemporalMonthDay(
            agent,
            temporal_rs_plain_month_day.?,
            null,
        ) catch |err| try noexcept(err);
        return Value.from(&new_plain_month_day.object);
    }
};

/// 10.4 Properties of Temporal.PlainMonthDay Instances
/// https://tc39.es/proposal-temporal/#sec-properties-of-temporal-plainmonthday-instances
pub const PlainMonthDay = MakeObject(.{
    .Fields = struct {
        inner: *temporal_rs.c.PlainMonthDay,
    },
    .finalizer = struct {
        fn finalizer(object: *Object) void {
            temporal_rs.c.temporal_rs_PlainMonthDay_destroy(object.as(PlainMonthDay).fields.inner);
        }
    }.finalizer,
    .tag = .temporal_plain_month_day,
    .display_name = "Temporal.PlainMonthDay",
});

/// 10.5.1 ToTemporalMonthDay ( item [ , options ] )
/// https://tc39.es/proposal-temporal/#sec-temporal-totemporalmonthday
pub fn toTemporalPlainMonthDay(
    agent: *Agent,
    item: Value,
    maybe_options_value: ?Value,
) Agent.Error!*PlainMonthDay {
    // 1. If options is not present, set options to undefined.
    const options_value: Value = maybe_options_value orelse .undefined;

    // 2. If item is an Object, then
    const temporal_rs_plain_month_day = if (item.isObject()) blk: {
        // a. If item has an [[InitializedTemporalMonthDay]] internal slot, then
        if (item.asObject().cast(PlainMonthDay)) |plain_month_day| {
            // i. Let resolvedOptions be ? GetOptionsObject(options).
            const options = try options_value.getOptionsObject(agent);

            // ii. Perform ? GetTemporalOverflowOption(resolvedOptions).
            _ = try getTemporalOverflowOption(agent, options);

            // iii. Return ! CreateTemporalMonthDay(item.[[ISODate]], item.[[Calendar]]).
            break :blk temporal_rs.c.temporal_rs_PlainMonthDay_clone(plain_month_day.fields.inner);
        }

        // b. Let calendar be ? GetTemporalCalendarIdentifierWithISODefault(item).
        const calendar = try getTemporalCalendarIdentifierWithISODefault(agent, item.asObject());

        // c. Let fields be ? PrepareCalendarFields(calendar, item, « year, month, month-code,
        //    day », «», «»).
        const fields = try prepareCalendarFields(
            agent,
            calendar,
            item.asObject(),
            .initMany(&.{ .year, .month, .month_code, .day }),
            .none,
        );
        const partial = fields.date;

        // d. Let resolvedOptions be ? GetOptionsObject(options).
        const options = try options_value.getOptionsObject(agent);

        // e. Let overflow be ? GetTemporalOverflowOption(resolvedOptions).
        const overflow = try getTemporalOverflowOption(agent, options);

        // f. Let isoDate be ? CalendarMonthDayFromFields(calendar, fields, overflow).
        // g. Return ! CreateTemporalMonthDay(isoDate, calendar).
        break :blk try builtins.temporal.extractResult(
            agent,
            temporal_rs.c.temporal_rs_PlainMonthDay_from_partial(
                partial,
                temporal_rs.toArithmeticOverflowOption(overflow),
            ),
        );
    } else blk: {
        // 3. If item is not a String, throw a TypeError exception.
        if (!item.isString()) {
            return agent.throwException(
                .type_error,
                "Plain monthday must be a string or object",
                .{},
            );
        }

        // 4. Let result be ? ParseISODateTime(item, « TemporalMonthDayString »).
        // 5. Let calendar be result.[[Calendar]].
        // 6. If calendar is empty, set calendar to "iso8601".
        // 7. Set calendar to ? CanonicalizeCalendar(calendar).
        const parsed_month_day = switch (item.asString().asAsciiOrUtf16()) {
            .ascii => |ascii| try builtins.temporal.extractResult(
                agent,
                temporal_rs.c.temporal_rs_ParsedDate_month_day_from_utf8(
                    temporal_rs.toDiplomatStringView(ascii),
                ),
            ),
            .utf16 => |utf16| try builtins.temporal.extractResult(
                agent,
                temporal_rs.c.temporal_rs_ParsedDate_month_day_from_utf16(
                    temporal_rs.toDiplomatString16View(utf16),
                ),
            ),
        };
        defer temporal_rs.c.temporal_rs_ParsedDate_destroy(parsed_month_day.?);

        // 8. Let resolvedOptions be ? GetOptionsObject(options).
        const options = try options_value.getOptionsObject(agent);

        // 9. Perform ? GetTemporalOverflowOption(resolvedOptions).
        _ = try getTemporalOverflowOption(agent, options);

        // 10. If calendar is "iso8601", then
        //     a. Let referenceISOYear be 1972 (the first ISO 8601 leap year after the epoch).
        //     b. Let isoDate be CreateISODateRecord(referenceISOYear, result.[[Month]],
        //        result.[[Day]]).
        //     c. Return ! CreateTemporalMonthDay(isoDate, calendar).
        // 11. Let isoDate be CreateISODateRecord(result.[[Year]], result.[[Month]],
        //     result.[[Day]]).
        // 12. If ISODateWithinLimits(isoDate) is false, throw a RangeError exception.
        // 13. Set result to ISODateToFields(calendar, isoDate, month-day).
        // 14. NOTE: The following operation is called with constrain regardless of overflow, in
        //     order for the calendar to store a canonical value in the [[Year]] field of the
        //     [[ISODate]] internal slot of the result.
        // 15. Set isoDate to ? CalendarMonthDayFromFields(calendar, result, constrain).
        // 16. Return ! CreateTemporalMonthDay(isoDate, calendar).
        break :blk try builtins.temporal.extractResult(
            agent,
            temporal_rs.c.temporal_rs_PlainMonthDay_from_parsed(parsed_month_day.?),
        );
    };
    errdefer temporal_rs.c.temporal_rs_PlainMonthDay_destroy(temporal_rs_plain_month_day.?);

    return createTemporalMonthDay(
        agent,
        temporal_rs_plain_month_day.?,
        null,
    ) catch |err| try noexcept(err);
}

/// 10.5.2 CreateTemporalMonthDay ( isoDate, calendar [ , newTarget ] )
/// https://tc39.es/proposal-temporal/#sec-temporal-createtemporalmonthday
pub fn createTemporalMonthDay(
    agent: *Agent,
    inner: *temporal_rs.c.PlainMonthDay,
    maybe_new_target: ?*Object,
) Agent.Error!*PlainMonthDay {
    const realm = agent.currentRealm();

    // 1. If ISODateWithinLimits(isoDate) is false, throw a RangeError exception.

    // 2. If newTarget is not present, set newTarget to %Temporal.PlainMonthDay%.
    const new_target = maybe_new_target orelse try realm.intrinsic(.temporal_plain_month_day);

    // 3. Let object be ? OrdinaryCreateFromConstructor(newTarget,
    //    "%Temporal.PlainMonthDay.prototype%", « [[InitializedTemporalMonthDay]], [[ISODate]],
    //    [[Calendar]] »).
    // 4. Set object.[[ISODate]] to isoDate.
    // 5. Set object.[[Calendar]] to calendar.
    // 6. Return object.
    return ordinaryCreateFromConstructor(
        PlainMonthDay,
        agent,
        new_target,
        .temporal_plain_month_day_prototype,
        .{ .inner = inner },
    );
}
