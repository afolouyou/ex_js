//! 5 Temporal.PlainDateTime Objects
//! https://tc39.es/proposal-temporal/#sec-temporal-plaindatetime-objects

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
const PropertyKey = types.PropertyKey;
const Realm = execution.Realm;
const String = types.String;
const Value = types.Value;
const canonicalizeCalendar = builtins.canonicalizeCalendar;
const createBuiltinFunction = builtins.createBuiltinFunction;
const createTemporalDate = builtins.createTemporalDate;
const createTemporalDuration = builtins.createTemporalDuration;
const createTemporalTime = builtins.createTemporalTime;
const createTemporalZonedDateTime = builtins.createTemporalZonedDateTime;
const getTemporalCalendarIdentifierWithISODefault = builtins.getTemporalCalendarIdentifierWithISODefault;
const getTemporalDifferenceSettingsWithoutValidation = builtins.getTemporalDifferenceSettingsWithoutValidation;
const getTemporalDisambiguationOption = builtins.getTemporalDisambiguationOption;
const getTemporalFractionalSecondDigitsOption = builtins.getTemporalFractionalSecondDigitsOption;
const getTemporalOverflowOption = builtins.getTemporalOverflowOption;
const getTemporalRoundingIncrementOption = builtins.getTemporalRoundingIncrementOption;
const getTemporalRoundingModeOption = builtins.getTemporalRoundingModeOption;
const getTemporalShowCalendarNameOption = builtins.getTemporalShowCalendarNameOption;
const getTemporalUnitValuedOption = builtins.getTemporalUnitValuedOption;
const isPartialTemporalObject = builtins.isPartialTemporalObject;
const isValidISODate = builtins.isValidISODate;
const isValidTime = builtins.isValidTime;
const noexcept = utils.noexcept;
const ordinaryCreateFromConstructor = builtins.ordinaryCreateFromConstructor;
const ordinaryObjectCreate = builtins.ordinaryObjectCreate;
const prepareCalendarFields = builtins.prepareCalendarFields;
const toTemporalCalendarIdentifier = builtins.toTemporalCalendarIdentifier;
const toTemporalDuration = builtins.toTemporalDuration;
const toTemporalTimeZoneIdentifier = builtins.toTemporalTimeZoneIdentifier;
const toTimeRecordOrMidnight = builtins.toTimeRecordOrMidnight;
const validateTemporalUnitValue = builtins.validateTemporalUnitValue;

/// 5.2 Properties of the Temporal.PlainDateTime Constructor
/// https://tc39.es/proposal-temporal/#sec-properties-of-the-temporal-plaindatetime-constructor
pub const constructor = struct {
    pub fn create(agent: *Agent, realm: *Realm) std.mem.Allocator.Error!*Object {
        const builtin_function = try createBuiltinFunction(
            agent,
            .{ .constructor = impl },
            3,
            "PlainDateTime",
            .{ .realm = realm, .proto = try realm.intrinsic(.function_prototype) },
        );
        return &builtin_function.object;
    }

    pub fn init(agent: *Agent, realm: *Realm, object: *Object) std.mem.Allocator.Error!void {
        try object.defineBuiltinFunction(agent, "compare", compare, 2, realm);
        try object.defineBuiltinFunction(agent, "from", from, 1, realm);

        // 5.2.1 Temporal.PlainDateTime.prototype
        // https://tc39.es/proposal-temporal/#sec-temporal.plaindatetime.prototype
        try object.defineBuiltinPropertyWithAttributes(
            agent,
            "prototype",
            Value.from(try realm.intrinsic(.temporal_plain_date_time_prototype)),
            .{
                .writable = false,
                .enumerable = false,
                .configurable = false,
            },
        );
    }

    /// 5.1.1 Temporal.PlainDateTime ( isoYear, isoMonth, isoDay [ , hour [ , minute [ , second [ , millisecond [ , microsecond [ , nanosecond [ , calendar ] ] ] ] ] ] ] )
    /// https://tc39.es/proposal-temporal/#sec-temporal.plaindatetime
    fn impl(agent: *Agent, arguments: Arguments, maybe_new_target: ?*Object) Agent.Error!Value {
        const iso_year_value = arguments.get(0);
        const iso_month_value = arguments.get(1);
        const iso_day_value = arguments.get(2);
        const hour_value = arguments.get(3);
        const minute_value = arguments.get(4);
        const second_value = arguments.get(5);
        const millisecond_value = arguments.get(6);
        const microsecond_value = arguments.get(7);
        const nanosecond_value = arguments.get(8);
        var calendar_value = arguments.get(9);

        // 1. If NewTarget is undefined, throw a TypeError exception.
        const new_target = maybe_new_target orelse {
            return agent.throwException(
                .type_error,
                "Temporal.PlainDateTime must be constructed with 'new'",
                .{},
            );
        };

        // 2. Set isoYear to ? ToIntegerWithTruncation(isoYear).
        const iso_year = try iso_year_value.toIntegerWithTruncation(agent);

        // 3. Set isoMonth to ? ToIntegerWithTruncation(isoMonth).
        const iso_month = try iso_month_value.toIntegerWithTruncation(agent);

        // 4. Set isoDay to ? ToIntegerWithTruncation(isoDay).
        const iso_day = try iso_day_value.toIntegerWithTruncation(agent);

        // 5. If hour is undefined, set hour to 0; else set hour to ? ToIntegerWithTruncation(hour).
        const hour = if (hour_value.isUndefined()) 0 else try hour_value.toIntegerWithTruncation(agent);

        // 6. If minute is undefined, set minute to 0; else set minute to ? ToIntegerWithTruncation(
        //    minute).
        const minute = if (minute_value.isUndefined()) 0 else try minute_value.toIntegerWithTruncation(agent);

        // 7. If second is undefined, set second to 0; else set second to ? ToIntegerWithTruncation(
        //    second).
        const second = if (second_value.isUndefined()) 0 else try second_value.toIntegerWithTruncation(agent);

        // 8. If millisecond is undefined, set millisecond to 0; else set millisecond to
        //    ? ToIntegerWithTruncation(millisecond).
        const millisecond = if (millisecond_value.isUndefined()) 0 else try millisecond_value.toIntegerWithTruncation(agent);

        // 9. If microsecond is undefined, set microsecond to 0; else set microsecond to
        //    ? ToIntegerWithTruncation(microsecond).
        const microsecond = if (microsecond_value.isUndefined()) 0 else try microsecond_value.toIntegerWithTruncation(agent);

        // 10. If nanosecond is undefined, set nanosecond to 0; else set nanosecond to
        //     ? ToIntegerWithTruncation(nanosecond).
        const nanosecond = if (nanosecond_value.isUndefined()) 0 else try nanosecond_value.toIntegerWithTruncation(agent);

        // 11. If calendar is undefined, set calendar to "iso8601".
        if (calendar_value.isUndefined()) calendar_value = Value.from("iso8601");

        // 12. If calendar is not a String, throw a TypeError exception.
        if (!calendar_value.isString()) {
            return agent.throwException(.type_error, "Calendar is not a string", .{});
        }

        // 13. Set calendar to ? CanonicalizeCalendar(calendar).
        const calendar = try canonicalizeCalendar(agent, calendar_value.asString());

        // 14. If IsValidISODate(isoYear, isoMonth, isoDay) is false, throw a RangeError exception.
        if (!isValidISODate(iso_year, iso_month, iso_day)) {
            return agent.throwException(.range_error, "Invalid ISO date", .{});
        }

        // 15. Let isoDate be CreateISODateRecord(isoYear, isoMonth, isoDay).

        // 16. If IsValidTime(hour, minute, second, millisecond, microsecond, nanosecond) is false,
        //     throw a RangeError exception.
        if (!isValidTime(hour, minute, second, millisecond, microsecond, nanosecond)) {
            return agent.throwException(.range_error, "Invalid time", .{});
        }

        // 17. Let time be CreateTimeRecord(hour, minute, second, millisecond, microsecond,
        //     nanosecond).
        // 18. Let isoDateTime be CombineISODateAndTimeRecord(isoDate, time).
        // 19. Return ? CreateTemporalDateTime(isoDateTime, calendar, NewTarget).
        const temporal_rs_plain_date_time = try builtins.temporal.extractResult(
            agent,
            temporal_rs.c.temporal_rs_PlainDateTime_try_new(
                @intFromFloat(iso_year),
                @intFromFloat(iso_month),
                @intFromFloat(iso_day),
                @intFromFloat(hour),
                @intFromFloat(minute),
                @intFromFloat(second),
                @intFromFloat(millisecond),
                @intFromFloat(microsecond),
                @intFromFloat(nanosecond),
                calendar,
            ),
        );
        errdefer temporal_rs.c.temporal_rs_PlainDateTime_destroy(temporal_rs_plain_date_time.?);
        const plain_date_time = try createTemporalDateTime(agent, temporal_rs_plain_date_time.?, new_target);
        return Value.from(&plain_date_time.object);
    }

    /// 5.2.3 Temporal.PlainDateTime.compare ( one, two )
    /// https://tc39.es/proposal-temporal/#sec-temporal.plaindatetime.compare
    fn compare(agent: *Agent, _: Value, arguments: Arguments) Agent.Error!Value {
        const one_value = arguments.get(0);
        const two_value = arguments.get(1);

        // 1. Set one to ? ToTemporalDateTime(one).
        const one = try toTemporalPlainDateTime(agent, one_value, null);

        // 2. Set two to ? ToTemporalDateTime(two).
        const two = try toTemporalPlainDateTime(agent, two_value, null);

        // 3. Return 𝔽(CompareISODateTime(one.[[ISODateTime]], two.[[ISODateTime]])).
        return Value.from(
            temporal_rs.c.temporal_rs_PlainDateTime_compare(
                one.fields.inner,
                two.fields.inner,
            ),
        );
    }

    /// 5.2.2 Temporal.PlainDateTime.from ( item [ , options ] )
    /// https://tc39.es/proposal-temporal/#sec-temporal.plaindatetime.from
    fn from(agent: *Agent, _: Value, arguments: Arguments) Agent.Error!Value {
        const item = arguments.get(0);
        const options = arguments.get(1);

        // 1. Return ? ToTemporalDateTime(item, options).
        const plain_date_time = try toTemporalPlainDateTime(agent, item, options);
        return Value.from(&plain_date_time.object);
    }
};

/// 5.3 Properties of the Temporal.PlainDateTime Prototype Object
/// https://tc39.es/proposal-temporal/#sec-properties-of-the-temporal-plaindatetime-prototype-object
pub const prototype = struct {
    pub fn create(agent: *Agent, realm: *Realm) std.mem.Allocator.Error!*Object {
        return ordinaryObjectCreate(agent, try realm.intrinsic(.object_prototype));
    }

    pub fn init(agent: *Agent, realm: *Realm, object: *Object) std.mem.Allocator.Error!void {
        try object.defineBuiltinFunction(agent, "add", add, 1, realm);
        try object.defineBuiltinAccessor(agent, "calendarId", calendarId, null, realm);
        try object.defineBuiltinAccessor(agent, "day", day, null, realm);
        try object.defineBuiltinAccessor(agent, "dayOfWeek", dayOfWeek, null, realm);
        try object.defineBuiltinAccessor(agent, "dayOfYear", dayOfYear, null, realm);
        try object.defineBuiltinAccessor(agent, "daysInMonth", daysInMonth, null, realm);
        try object.defineBuiltinAccessor(agent, "daysInWeek", daysInWeek, null, realm);
        try object.defineBuiltinAccessor(agent, "daysInYear", daysInYear, null, realm);
        try object.defineBuiltinFunction(agent, "equals", equals, 1, realm);
        try object.defineBuiltinAccessor(agent, "era", era, null, realm);
        try object.defineBuiltinAccessor(agent, "eraYear", eraYear, null, realm);
        try object.defineBuiltinAccessor(agent, "hour", hour, null, realm);
        try object.defineBuiltinAccessor(agent, "inLeapYear", inLeapYear, null, realm);
        try object.defineBuiltinAccessor(agent, "microsecond", microsecond, null, realm);
        try object.defineBuiltinAccessor(agent, "millisecond", millisecond, null, realm);
        try object.defineBuiltinAccessor(agent, "minute", minute, null, realm);
        try object.defineBuiltinAccessor(agent, "month", month, null, realm);
        try object.defineBuiltinAccessor(agent, "monthCode", monthCode, null, realm);
        try object.defineBuiltinAccessor(agent, "monthsInYear", monthsInYear, null, realm);
        try object.defineBuiltinAccessor(agent, "nanosecond", nanosecond, null, realm);
        try object.defineBuiltinFunction(agent, "round", round, 1, realm);
        try object.defineBuiltinAccessor(agent, "second", second, null, realm);
        try object.defineBuiltinFunction(agent, "since", since, 1, realm);
        try object.defineBuiltinFunction(agent, "subtract", subtract, 1, realm);
        try object.defineBuiltinFunction(agent, "toJSON", toJSON, 0, realm);
        try object.defineBuiltinFunction(agent, "toLocaleString", toLocaleString, 0, realm);
        try object.defineBuiltinFunction(agent, "toPlainDate", toPlainDate, 0, realm);
        try object.defineBuiltinFunction(agent, "toPlainTime", toPlainTime, 0, realm);
        try object.defineBuiltinFunction(agent, "toString", toString, 0, realm);
        try object.defineBuiltinFunction(agent, "toZonedDateTime", toZonedDateTime, 1, realm);
        try object.defineBuiltinFunction(agent, "until", until, 1, realm);
        try object.defineBuiltinFunction(agent, "valueOf", valueOf, 0, realm);
        try object.defineBuiltinAccessor(agent, "weekOfYear", weekOfYear, null, realm);
        try object.defineBuiltinFunction(agent, "with", with, 1, realm);
        try object.defineBuiltinFunction(agent, "withCalendar", withCalendar, 1, realm);
        try object.defineBuiltinFunction(agent, "withPlainTime", withPlainTime, 0, realm);
        try object.defineBuiltinAccessor(agent, "year", year, null, realm);
        try object.defineBuiltinAccessor(agent, "yearOfWeek", yearOfWeek, null, realm);

        // 5.3.1 Temporal.PlainDateTime.prototype.constructor
        // https://tc39.es/proposal-temporal/#sec-temporal.plaindatetime.prototype.constructor
        try object.defineBuiltinProperty(
            agent,
            "constructor",
            Value.from(try realm.intrinsic(.temporal_plain_date_time)),
        );

        // 5.3.2 Temporal.PlainDateTime.prototype[ %Symbol.toStringTag% ]
        // https://tc39.es/proposal-temporal/#sec-temporal.plaindatetime.prototype-%symbol.tostringtag%
        try object.defineBuiltinPropertyWithAttributes(
            agent,
            "Symbol.toStringTag",
            Value.from("Temporal.PlainDateTime"),
            .{
                .writable = false,
                .enumerable = false,
                .configurable = true,
            },
        );
    }

    /// 5.3.28 Temporal.PlainDateTime.prototype.add ( temporalDurationLike [ , options ] )
    /// https://tc39.es/proposal-temporal/#sec-temporal.plaindatetime.prototype.add
    fn add(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const temporal_duration_like = arguments.get(0);
        const options = arguments.get(1);

        // 1. Let plainDateTime be the this value.
        // 2. Perform ? RequireInternalSlot(plainDateTime, [[InitializedTemporalDateTime]]).
        const plain_date_time = try this_value.requireInternalSlot(agent, PlainDateTime);

        // 3. Return ? AddDurationToDateTime(add, plainDateTime, temporalDurationLike, options).
        const new_plain_date_time = try addDurationToDateTime(
            agent,
            .add,
            plain_date_time,
            temporal_duration_like,
            options,
        );
        return Value.from(&new_plain_date_time.object);
    }

    /// 5.3.3 get Temporal.PlainDateTime.prototype.calendarId
    /// https://tc39.es/proposal-temporal/#sec-get-temporal.plaindatetime.prototype.calendarid
    fn calendarId(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let plainDateTime be the this value.
        // 2. Perform ? RequireInternalSlot(plainDateTime, [[InitializedTemporalDateTime]]).
        const plain_date_time = try this_value.requireInternalSlot(agent, PlainDateTime);

        // 3. Return plainDateTime.[[Calendar]].
        const temporal_rs_calendar = temporal_rs.c.temporal_rs_PlainDateTime_calendar(
            plain_date_time.fields.inner,
        );
        const calendar_id = temporal_rs.fromDiplomatStringView(
            temporal_rs.c.temporal_rs_Calendar_identifier(temporal_rs_calendar.?),
        );
        return Value.from(
            try String.fromAscii(agent, try agent.gc_allocator.dupe(u8, calendar_id)),
        );
    }

    /// 5.3.9 get Temporal.PlainDateTime.prototype.day
    /// https://tc39.es/proposal-temporal/#sec-get-temporal.plaindatetime.prototype.day
    fn day(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let plainDateTime be the this value.
        // 2. Perform ? RequireInternalSlot(plainDateTime, [[InitializedTemporalDateTime]]).
        const plain_date_time = try this_value.requireInternalSlot(agent, PlainDateTime);

        // 3. Return 𝔽(CalendarISOToDate(plainDateTime.[[Calendar]],
        //    plainDateTime.[[ISODateTime]].[[ISODate]]).[[Day]]).
        return Value.from(
            temporal_rs.c.temporal_rs_PlainDateTime_day(plain_date_time.fields.inner),
        );
    }

    /// 5.3.16 get Temporal.PlainDateTime.prototype.dayOfWeek
    /// https://tc39.es/proposal-temporal/#sec-get-temporal.plaindatetime.prototype.dayofweek
    fn dayOfWeek(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let plainDateTime be the this value.
        // 2. Perform ? RequireInternalSlot(plainDateTime, [[InitializedTemporalDateTime]]).
        const plain_date_time = try this_value.requireInternalSlot(agent, PlainDateTime);

        // 3. Return 𝔽(CalendarISOToDate(plainDateTime.[[Calendar]],
        //    plainDateTime.[[ISODateTime]].[[ISODate]]).[[DayOfWeek]]).
        return Value.from(
            temporal_rs.c.temporal_rs_PlainDateTime_day_of_week(plain_date_time.fields.inner),
        );
    }

    /// 5.3.17 get Temporal.PlainDateTime.prototype.dayOfYear
    /// https://tc39.es/proposal-temporal/#sec-get-temporal.plaindatetime.prototype.dayofyear
    fn dayOfYear(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let plainDateTime be the this value.
        // 2. Perform ? RequireInternalSlot(plainDateTime, [[InitializedTemporalDateTime]]).
        const plain_date_time = try this_value.requireInternalSlot(agent, PlainDateTime);

        // 3. Return 𝔽(CalendarISOToDate(plainDateTime.[[Calendar]],
        //    plainDateTime.[[ISODateTime]].[[ISODate]]).[[DayOfYear]]).
        return Value.from(
            temporal_rs.c.temporal_rs_PlainDateTime_day_of_year(plain_date_time.fields.inner),
        );
    }

    /// 5.3.21 get Temporal.PlainDateTime.prototype.daysInMonth
    /// https://tc39.es/proposal-temporal/#sec-get-temporal.plaindatetime.prototype.daysinmonth
    fn daysInMonth(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let plainDateTime be the this value.
        // 2. Perform ? RequireInternalSlot(plainDateTime, [[InitializedTemporalDateTime]]).
        const plain_date_time = try this_value.requireInternalSlot(agent, PlainDateTime);

        // 3. Return 𝔽(CalendarISOToDate(plainDateTime.[[Calendar]],
        //    plainDateTime.[[ISODateTime]].[[ISODate]]).[[DaysInMonth]]).
        return Value.from(
            temporal_rs.c.temporal_rs_PlainDateTime_days_in_month(plain_date_time.fields.inner),
        );
    }

    /// 5.3.20 get Temporal.PlainDateTime.prototype.daysInWeek
    /// https://tc39.es/proposal-temporal/#sec-get-temporal.plaindatetime.prototype.daysinweek
    fn daysInWeek(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let plainDateTime be the this value.
        // 2. Perform ? RequireInternalSlot(plainDateTime, [[InitializedTemporalDateTime]]).
        const plain_date_time = try this_value.requireInternalSlot(agent, PlainDateTime);

        // 3. Return 𝔽(CalendarISOToDate(plainDateTime.[[Calendar]],
        //    plainDateTime.[[ISODateTime]].[[ISODate]]).[[DaysInWeek]]).
        return Value.from(
            temporal_rs.c.temporal_rs_PlainDateTime_days_in_week(plain_date_time.fields.inner),
        );
    }

    /// 5.3.22 get Temporal.PlainDateTime.prototype.daysInYear
    /// https://tc39.es/proposal-temporal/#sec-get-temporal.plaindatetime.prototype.daysinyear
    fn daysInYear(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let plainDateTime be the this value.
        // 2. Perform ? RequireInternalSlot(plainDateTime, [[InitializedTemporalDateTime]]).
        const plain_date_time = try this_value.requireInternalSlot(agent, PlainDateTime);

        // 3. Return 𝔽(CalendarISOToDate(plainDateTime.[[Calendar]],
        //    plainDateTime.[[ISODateTime]].[[ISODate]]).[[DaysInYear]]).
        return Value.from(
            temporal_rs.c.temporal_rs_PlainDateTime_days_in_year(plain_date_time.fields.inner),
        );
    }

    /// 5.3.33 Temporal.PlainDateTime.prototype.equals ( other )
    /// https://tc39.es/proposal-temporal/#sec-temporal.plaindatetime.prototype.equals
    fn equals(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const other_value = arguments.get(0);

        // 1. Let plainDateTime be the this value.
        // 2. Perform ? RequireInternalSlot(plainDateTime, [[InitializedTemporalDateTime]]).
        const plain_date_time = try this_value.requireInternalSlot(agent, PlainDateTime);

        // 3. Set other to ? ToTemporalDateTime(other).
        const other = try toTemporalPlainDateTime(agent, other_value, null);

        // 4. If CompareISODateTime(plainDateTime.[[ISODateTime]], other.[[ISODateTime]]) ≠ 0,
        //    return false.
        // 5. Return CalendarEquals(plainDateTime.[[Calendar]], other.[[Calendar]]).
        return Value.from(
            temporal_rs.c.temporal_rs_PlainDateTime_equals(
                plain_date_time.fields.inner,
                other.fields.inner,
            ),
        );
    }

    /// 5.3.4 get Temporal.PlainDateTime.prototype.era
    /// https://tc39.es/proposal-temporal/#sec-get-temporal.plaindatetime.prototype.era
    fn era(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let plainDateTime be the this value.
        // 2. Perform ? RequireInternalSlot(plainDateTime, [[InitializedTemporalDateTime]]).
        const plain_date_time = try this_value.requireInternalSlot(agent, PlainDateTime);

        // 3. Return CalendarISOToDate(plainDateTime.[[Calendar]],
        //    plainDateTime.[[ISODateTime]].[[ISODate]]).[[Era]].
        var write = temporal_rs.DiplomatWrite.init(agent.gc_allocator);
        temporal_rs.c.temporal_rs_PlainDateTime_era(plain_date_time.fields.inner, &write.inner);
        if (write.inner.len == 0) {
            std.debug.assert(write.inner.cap == 0); // Nothing to free
            return .undefined;
        }
        return Value.from(try String.fromAscii(agent, try write.toOwnedSlice()));
    }

    /// 5.3.5 get Temporal.PlainDateTime.prototype.eraYear
    /// https://tc39.es/proposal-temporal/#sec-get-temporal.plaindatetime.prototype.erayear
    fn eraYear(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let plainDateTime be the this value.
        // 2. Perform ? RequireInternalSlot(plainDateTime, [[InitializedTemporalDateTime]]).
        const plain_date_time = try this_value.requireInternalSlot(agent, PlainDateTime);

        // 3. Let result be CalendarISOToDate(plainDateTime.[[Calendar]],
        //    plainDateTime.[[ISODateTime]].[[ISODate]]).[[EraYear]].
        const result = temporal_rs.c.temporal_rs_PlainDateTime_era_year(
            plain_date_time.fields.inner,
        );

        // 4. If result is undefined, return undefined.
        if (!result.is_ok) return .undefined;

        // 5. Return 𝔽(result).
        return Value.from(result.unnamed_0.ok);
    }

    /// 5.3.10 get Temporal.PlainDateTime.prototype.hour
    /// https://tc39.es/proposal-temporal/#sec-get-temporal.plaindatetime.prototype.hour
    fn hour(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let plainDateTime be the this value.
        // 2. Perform ? RequireInternalSlot(plainDateTime, [[InitializedTemporalDateTime]]).
        const plain_date_time = try this_value.requireInternalSlot(agent, PlainDateTime);

        // 3. Return 𝔽(plainDateTime.[[ISODateTime]].[[Time]].[[Hour]]).
        return Value.from(
            temporal_rs.c.temporal_rs_PlainDateTime_hour(plain_date_time.fields.inner),
        );
    }

    /// 5.3.24 get Temporal.PlainDateTime.prototype.inLeapYear
    /// https://tc39.es/proposal-temporal/#sec-get-temporal.plaindatetime.prototype.inleapyear
    fn inLeapYear(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let plainDateTime be the this value.
        // 2. Perform ? RequireInternalSlot(plainDateTime, [[InitializedTemporalDateTime]]).
        const plain_date_time = try this_value.requireInternalSlot(agent, PlainDateTime);

        // 3. Return CalendarISOToDate(plainDateTime.[[Calendar]],
        //    plainDateTime.[[ISODateTime]].[[ISODate]]).[[InLeapYear]].
        return Value.from(
            temporal_rs.c.temporal_rs_PlainDateTime_in_leap_year(plain_date_time.fields.inner),
        );
    }

    /// 5.3.14 get Temporal.PlainDateTime.prototype.microsecond
    /// https://tc39.es/proposal-temporal/#sec-get-temporal.plaindatetime.prototype.microsecond
    fn microsecond(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let plainDateTime be the this value.
        // 2. Perform ? RequireInternalSlot(plainDateTime, [[InitializedTemporalDateTime]]).
        const plain_date_time = try this_value.requireInternalSlot(agent, PlainDateTime);

        // 3. Return 𝔽(plainDateTime.[[ISODateTime]].[[Time]].[[Microsecond]]).
        return Value.from(
            temporal_rs.c.temporal_rs_PlainDateTime_microsecond(plain_date_time.fields.inner),
        );
    }

    /// 5.3.13 get Temporal.PlainDateTime.prototype.millisecond
    /// https://tc39.es/proposal-temporal/#sec-get-temporal.plaindatetime.prototype.millisecond
    fn millisecond(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let plainDateTime be the this value.
        // 2. Perform ? RequireInternalSlot(plainDateTime, [[InitializedTemporalDateTime]]).
        const plain_date_time = try this_value.requireInternalSlot(agent, PlainDateTime);

        // 3. Return 𝔽(plainDateTime.[[ISODateTime]].[[Time]].[[Millisecond]]).
        return Value.from(
            temporal_rs.c.temporal_rs_PlainDateTime_millisecond(plain_date_time.fields.inner),
        );
    }

    /// 5.3.11 get Temporal.PlainDateTime.prototype.minute
    /// https://tc39.es/proposal-temporal/#sec-get-temporal.plaindatetime.prototype.minute
    fn minute(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let plainDateTime be the this value.
        // 2. Perform ? RequireInternalSlot(plainDateTime, [[InitializedTemporalDateTime]]).
        const plain_date_time = try this_value.requireInternalSlot(agent, PlainDateTime);

        // 3. Return 𝔽(plainDateTime.[[ISODateTime]].[[Time]].[[Minute]]).
        return Value.from(
            temporal_rs.c.temporal_rs_PlainDateTime_minute(plain_date_time.fields.inner),
        );
    }

    /// 5.3.7 get Temporal.PlainDateTime.prototype.month
    /// https://tc39.es/proposal-temporal/#sec-get-temporal.plaindatetime.prototype.month
    fn month(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let plainDateTime be the this value.
        // 2. Perform ? RequireInternalSlot(plainDateTime, [[InitializedTemporalDateTime]]).
        const plain_date_time = try this_value.requireInternalSlot(agent, PlainDateTime);

        // 3. Return 𝔽(CalendarISOToDate(plainDateTime.[[Calendar]],
        //    plainDateTime.[[ISODateTime]].[[ISODate]]).[[Month]]).
        return Value.from(
            temporal_rs.c.temporal_rs_PlainDateTime_month(plain_date_time.fields.inner),
        );
    }

    /// 5.3.8 get Temporal.PlainDateTime.prototype.monthCode
    /// https://tc39.es/proposal-temporal/#sec-get-temporal.plaindatetime.prototype.monthcode
    fn monthCode(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let plainDateTime be the this value.
        // 2. Perform ? RequireInternalSlot(plainDateTime, [[InitializedTemporalDateTime]]).
        const plain_date_time = try this_value.requireInternalSlot(agent, PlainDateTime);

        // 3. Return CalendarISOToDate(plainDateTime.[[Calendar]],
        //    plainDateTime.[[ISODateTime]].[[ISODate]]).[[MonthCode]].
        var write = temporal_rs.DiplomatWrite.init(agent.gc_allocator);
        temporal_rs.c.temporal_rs_PlainDateTime_month_code(
            plain_date_time.fields.inner,
            &write.inner,
        );
        return Value.from(try String.fromAscii(agent, try write.toOwnedSlice()));
    }

    /// 5.3.23 get Temporal.PlainDateTime.prototype.monthsInYear
    /// https://tc39.es/proposal-temporal/#sec-get-temporal.plaindatetime.prototype.monthsinyear
    fn monthsInYear(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let plainDateTime be the this value.
        // 2. Perform ? RequireInternalSlot(plainDateTime, [[InitializedTemporalDateTime]]).
        const plain_date_time = try this_value.requireInternalSlot(agent, PlainDateTime);

        // 3. Return 𝔽(CalendarISOToDate(plainDateTime.[[Calendar]],
        //    plainDateTime.[[ISODateTime]].[[ISODate]]).[[MonthsInYear]]).
        return Value.from(
            temporal_rs.c.temporal_rs_PlainDateTime_months_in_year(plain_date_time.fields.inner),
        );
    }

    /// 5.3.15 get Temporal.PlainDateTime.prototype.nanosecond
    /// https://tc39.es/proposal-temporal/#sec-get-temporal.plaindatetime.prototype.nanosecond
    fn nanosecond(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let plainDateTime be the this value.
        // 2. Perform ? RequireInternalSlot(plainDateTime, [[InitializedTemporalDateTime]]).
        const plain_date_time = try this_value.requireInternalSlot(agent, PlainDateTime);

        // 3. Return 𝔽(plainDateTime.[[ISODateTime]].[[Time]].[[Nanosecond]]).
        return Value.from(
            temporal_rs.c.temporal_rs_PlainDateTime_nanosecond(plain_date_time.fields.inner),
        );
    }

    /// 5.3.32 Temporal.PlainDateTime.prototype.round ( roundTo )
    /// https://tc39.es/proposal-temporal/#sec-temporal.plaindatetime.prototype.round
    fn round(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const round_to = arguments.get(0);

        // 1. Let plainDateTime be the this value.
        // 2. Perform ? RequireInternalSlot(plainDateTime, [[InitializedTemporalDateTime]]).
        const plain_date_time = try this_value.requireInternalSlot(agent, PlainDateTime);

        // 3. If roundTo is undefined, throw a TypeError exception.
        if (round_to.isUndefined()) {
            return agent.throwException(.type_error, "Argument must not be undefined", .{});
        }

        // 4. If roundTo is a String, then
        const options = if (round_to.isString()) blk: {
            // a. Let paramString be roundTo.
            const param_string = round_to.asString();

            // b. Set roundTo to OrdinaryObjectCreate(null).
            const options = try ordinaryObjectCreate(agent, null);

            // c. Perform ! CreateDataPropertyOrThrow(roundTo, "smallestUnit", paramString).
            try options.createDataPropertyDirect(
                agent,
                PropertyKey.from("smallestUnit"),
                Value.from(param_string),
            );

            break :blk options;
        } else blk: {
            // 5. Else,
            // a. Set roundTo to ? GetOptionsObject(roundTo).
            break :blk try round_to.getOptionsObject(agent);
        };

        // 6. NOTE: The following steps read options and perform independent validation in
        //    alphabetical order (GetRoundingIncrementOption reads "roundingIncrement" and
        //    GetRoundingModeOption reads "roundingMode").

        // 7. Let roundingIncrement be ? GetRoundingIncrementOption(roundTo).
        const rounding_increment = try getTemporalRoundingIncrementOption(agent, options);

        // 8. Let roundingMode be ? GetRoundingModeOption(roundTo, half-expand).
        const rounding_mode = try getTemporalRoundingModeOption(
            agent,
            options,
            temporal_rs.c.RoundingMode_HalfExpand,
        );

        // 9. Let smallestUnit be ? GetTemporalUnitValuedOption(roundTo, "smallestUnit", required).
        const smallest_unit = try getTemporalUnitValuedOption(
            agent,
            options,
            "smallestUnit",
            .required,
        );

        // 10. Perform ? ValidateTemporalUnitValue(smallestUnit, time, « day »).
        try validateTemporalUnitValue(
            agent,
            smallest_unit,
            "smallestUnit",
            .time,
            &.{temporal_rs.c.Unit_Day},
        );

        // 11. If smallestUnit is day, then
        //     a. Let maximum be 1.
        //     b. Let inclusive be true.
        // 12. Else,
        //     a. Let maximum be MaximumTemporalDurationRoundingIncrement(smallestUnit).
        //     b. Assert: maximum is not unset.
        //     c. Let inclusive be false.
        // 13. Perform ? ValidateTemporalRoundingIncrement(roundingIncrement, maximum, inclusive).
        // 14. If smallestUnit is nanosecond and roundingIncrement = 1, then
        //     a. Return ! CreateTemporalDateTime(plainDateTime.[[ISODateTime]],
        //        plainDateTime.[[Calendar]]).
        // 15. Let result be RoundISODateTime(plainDateTime.[[ISODateTime]], roundingIncrement,
        //     smallestUnit, roundingMode).
        // 16. Return ? CreateTemporalDateTime(result, plainDateTime.[[Calendar]]).
        const temporal_rs_plain_date_time = try builtins.temporal.extractResult(
            agent,
            temporal_rs.c.temporal_rs_PlainDateTime_round(
                plain_date_time.fields.inner,
                .{
                    .largest_unit = temporal_rs.toUnitOption(null),
                    .smallest_unit = temporal_rs.toUnitOption(smallest_unit),
                    .rounding_mode = temporal_rs.toRoundingModeOption(rounding_mode),
                    .increment = temporal_rs.toOption(temporal_rs.c.OptionU32, rounding_increment),
                },
            ),
        );
        errdefer temporal_rs.c.temporal_rs_PlainDateTime_destroy(temporal_rs_plain_date_time.?);
        const new_plain_date_time = createTemporalDateTime(
            agent,
            temporal_rs_plain_date_time.?,
            null,
        ) catch |err| try noexcept(err);
        return Value.from(&new_plain_date_time.object);
    }

    /// 5.3.12 get Temporal.PlainDateTime.prototype.second
    /// https://tc39.es/proposal-temporal/#sec-get-temporal.plaindatetime.prototype.second
    fn second(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let plainDateTime be the this value.
        // 2. Perform ? RequireInternalSlot(plainDateTime, [[InitializedTemporalDateTime]]).
        const plain_date_time = try this_value.requireInternalSlot(agent, PlainDateTime);

        // 3. Return 𝔽(plainDateTime.[[ISODateTime]].[[Time]].[[Second]]).
        return Value.from(
            temporal_rs.c.temporal_rs_PlainDateTime_second(plain_date_time.fields.inner),
        );
    }

    /// 5.3.31 Temporal.PlainDateTime.prototype.since ( other [ , options ] )
    /// https://tc39.es/proposal-temporal/#sec-temporal.plaindatetime.prototype.since
    fn since(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const other = arguments.get(0);
        const options = arguments.get(1);

        // 1. Let plainDateTime be the this value.
        // 2. Perform ? RequireInternalSlot(plainDateTime, [[InitializedTemporalDateTime]]).
        const plain_date_time = try this_value.requireInternalSlot(agent, PlainDateTime);

        // 3. Return ? DifferenceTemporalPlainDateTime(since, plainDateTime, other, options).
        const duration = try differenceTemporalPlainDateTime(
            agent,
            .since,
            plain_date_time,
            other,
            options,
        );
        return Value.from(&duration.object);
    }

    /// 5.3.29 Temporal.PlainDateTime.prototype.subtract ( temporalDurationLike [ , options ] )
    /// https://tc39.es/proposal-temporal/#sec-temporal.plaindatetime.prototype.subtract
    fn subtract(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const temporal_duration_like = arguments.get(0);
        const options = arguments.get(1);

        // 1. Let plainDateTime be the this value.
        // 2. Perform ? RequireInternalSlot(plainDateTime, [[InitializedTemporalDateTime]]).
        const plain_date_time = try this_value.requireInternalSlot(agent, PlainDateTime);

        // 3. Return ? AddDurationToDateTime(subtract, plainDateTime, temporalDurationLike,
        //    options).
        const new_plain_time = try addDurationToDateTime(
            agent,
            .subtract,
            plain_date_time,
            temporal_duration_like,
            options,
        );
        return Value.from(&new_plain_time.object);
    }

    /// 5.3.36 Temporal.PlainDateTime.prototype.toJSON ( )
    /// https://tc39.es/proposal-temporal/#sec-temporal.plaindatetime.prototype.tojson
    fn toJSON(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let plainDateTime be the this value.
        // 2. Perform ? RequireInternalSlot(plainDateTime, [[InitializedTemporalDateTime]]).
        const plain_date_time = try this_value.requireInternalSlot(agent, PlainDateTime);

        // 3. Return ISODateTimeToString(plainDateTime.[[ISODateTime]], plainDateTime.[[Calendar]],
        //    auto, auto).
        var write = temporal_rs.DiplomatWrite.init(agent.gc_allocator);
        try builtins.temporal.extractResult(
            agent,
            temporal_rs.c.temporal_rs_PlainDateTime_to_ixdtf_string(
                plain_date_time.fields.inner,
                temporal_rs.to_string_rounding_options_auto,
                temporal_rs.c.DisplayCalendar_Auto,
                &write.inner,
            ),
        );
        return Value.from(try String.fromAscii(agent, try write.toOwnedSlice()));
    }

    /// 5.3.35 Temporal.PlainDateTime.prototype.toLocaleString ( [ locales [ , options ] ] )
    /// https://tc39.es/proposal-temporal/#sec-temporal.plaindatetime.prototype.tolocalestring
    fn toLocaleString(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let plainDateTime be the this value.
        // 2. Perform ? RequireInternalSlot(plainDateTime, [[InitializedTemporalDateTime]]).
        const plain_date_time = try this_value.requireInternalSlot(agent, PlainDateTime);

        // 3. Return ISODateTimeToString(plainDateTime.[[ISODateTime]], plainDateTime.[[Calendar]],
        //    auto, auto).
        var write = temporal_rs.DiplomatWrite.init(agent.gc_allocator);
        try builtins.temporal.extractResult(
            agent,
            temporal_rs.c.temporal_rs_PlainDateTime_to_ixdtf_string(
                plain_date_time.fields.inner,
                temporal_rs.to_string_rounding_options_auto,
                temporal_rs.c.DisplayCalendar_Auto,
                &write.inner,
            ),
        );
        return Value.from(try String.fromAscii(agent, try write.toOwnedSlice()));
    }

    /// 5.3.39 Temporal.PlainDateTime.prototype.toPlainDate ( )
    /// https://tc39.es/proposal-temporal/#sec-temporal.plaindatetime.prototype.toplaindate
    fn toPlainDate(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let plainDateTime be the this value.
        // 2. Perform ? RequireInternalSlot(plainDateTime, [[InitializedTemporalDateTime]]).
        const plain_date_time = try this_value.requireInternalSlot(agent, PlainDateTime);

        // 3. Return ! CreateTemporalDate(plainDateTime.[[ISODateTime]].[[ISODate]],
        //    plainDateTime.[[Calendar]]).
        const temporal_rs_plain_date = temporal_rs.c.temporal_rs_PlainDateTime_to_plain_date(
            plain_date_time.fields.inner,
        );
        errdefer temporal_rs.c.temporal_rs_PlainDate_destroy(temporal_rs_plain_date.?);
        const plain_date = createTemporalDate(
            agent,
            temporal_rs_plain_date.?,
            null,
        ) catch |err| try noexcept(err);
        return Value.from(&plain_date.object);
    }

    /// 5.3.40 Temporal.PlainDateTime.prototype.toPlainTime ( )
    /// https://tc39.es/proposal-temporal/#sec-temporal.plaindatetime.prototype.toplaintime
    fn toPlainTime(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let plainDateTime be the this value.
        // 2. Perform ? RequireInternalSlot(plainDateTime, [[InitializedTemporalDateTime]]).
        const plain_date_time = try this_value.requireInternalSlot(agent, PlainDateTime);

        // 3. Return ! CreateTemporalTime(plainDateTime.[[ISODateTime]].[[Time]]).
        const temporal_rs_plain_time = temporal_rs.c.temporal_rs_PlainDateTime_to_plain_time(
            plain_date_time.fields.inner,
        );
        errdefer temporal_rs.c.temporal_rs_PlainTime_destroy(temporal_rs_plain_time.?);
        const plain_time = createTemporalTime(
            agent,
            temporal_rs_plain_time.?,
            null,
        ) catch |err| try noexcept(err);
        return Value.from(&plain_time.object);
    }

    /// 5.3.34 Temporal.PlainDateTime.prototype.toString ( [ options ] )
    /// https://tc39.es/proposal-temporal/#sec-temporal.plaindatetime.prototype.tostring
    fn toString(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const options_value = arguments.get(0);

        // 1. Let plainDateTime be the this value.
        // 2. Perform ? RequireInternalSlot(plainDateTime, [[InitializedTemporalDateTime]]).
        const plain_date_time = try this_value.requireInternalSlot(agent, PlainDateTime);

        // 3. Let resolvedOptions be ? GetOptionsObject(options).
        const options = try options_value.getOptionsObject(agent);

        // 4. NOTE: The following steps read options and perform independent validation in
        //    alphabetical order (GetTemporalShowCalendarNameOption reads "calendarName",
        //    GetTemporalFractionalSecondDigitsOption reads "fractionalSecondDigits", and
        //    GetRoundingModeOption reads "roundingMode").

        // 5. Let showCalendar be ? GetTemporalShowCalendarNameOption(resolvedOptions).
        const show_calendar = try getTemporalShowCalendarNameOption(agent, options);

        // 6. Let digits be ? GetTemporalFractionalSecondDigitsOption(resolvedOptions).
        const precision = try getTemporalFractionalSecondDigitsOption(agent, options);

        // 7. Let roundingMode be ? GetRoundingModeOption(resolvedOptions, trunc).
        const rounding_mode = try getTemporalRoundingModeOption(
            agent,
            options,
            temporal_rs.c.RoundingMode_Trunc,
        );

        // 8. Let smallestUnit be ? GetTemporalUnitValuedOption(resolvedOptions, "smallestUnit",
        //    unset).
        const smallest_unit = try getTemporalUnitValuedOption(
            agent,
            options,
            "smallestUnit",
            .unset,
        );

        // 9. Perform ? ValidateTemporalUnitValue(smallestUnit, time).
        try validateTemporalUnitValue(agent, smallest_unit, "smallestUnit", .time, &.{});

        // 10. If smallestUnit is hour, throw a RangeError exception.
        if (smallest_unit == temporal_rs.c.Unit_Hour) {
            return agent.throwException(
                .range_error,
                "Invalid value for option 'smallestUnit'",
                .{},
            );
        }

        // 11. Let precision be ToSecondsStringPrecisionRecord(smallestUnit, digits).
        // 12. Let result be RoundISODateTime(plainDateTime.[[ISODateTime]],
        //     precision.[[Increment]], precision.[[Unit]], roundingMode).
        // 13. If ISODateTimeWithinLimits(result) is false, throw a RangeError exception.
        // 14. Return ISODateTimeToString(result, plainDateTime.[[Calendar]],
        //     precision.[[Precision]], showCalendar).
        var write = temporal_rs.DiplomatWrite.init(agent.gc_allocator);
        try builtins.temporal.extractResult(
            agent,
            temporal_rs.c.temporal_rs_PlainDateTime_to_ixdtf_string(
                plain_date_time.fields.inner,
                .{
                    .precision = precision,
                    .smallest_unit = temporal_rs.toUnitOption(smallest_unit),
                    .rounding_mode = temporal_rs.toRoundingModeOption(rounding_mode),
                },
                show_calendar,
                &write.inner,
            ),
        );
        return Value.from(try String.fromAscii(agent, try write.toOwnedSlice()));
    }

    /// 5.3.38 Temporal.PlainDateTime.prototype.toZonedDateTime ( temporalTimeZoneLike [ , options ] )
    /// https://tc39.es/proposal-temporal/#sec-temporal.plaindatetime.prototype.tozoneddatetime
    fn toZonedDateTime(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const temporal_time_zone_like = arguments.get(0);
        const options_value = arguments.get(1);

        // 1. Let plainDateTime be the this value.
        // 2. Perform ? RequireInternalSlot(plainDateTime, [[InitializedTemporalDateTime]]).
        const plain_date_time = try this_value.requireInternalSlot(agent, PlainDateTime);

        // 3. Let timeZone be ? ToTemporalTimeZoneIdentifier(temporalTimeZoneLike).
        const time_zone = try toTemporalTimeZoneIdentifier(agent, temporal_time_zone_like);

        // 4. Let resolvedOptions be ? GetOptionsObject(options).
        const options = try options_value.getOptionsObject(agent);

        // 5. Let disambiguation be ? GetTemporalDisambiguationOption(resolvedOptions).
        const disambiguation = try getTemporalDisambiguationOption(agent, options);

        // 6. Let epochNs be ? GetEpochNanosecondsFor(timeZone, plainDateTime.[[ISODateTime]],
        //    disambiguation).
        // 7. Return ! CreateTemporalZonedDateTime(epochNs, timeZone, plainDateTime.[[Calendar]]).
        const temporal_rs_zoned_date_time = try builtins.temporal.extractResult(
            agent,
            temporal_rs.c.temporal_rs_PlainDateTime_to_zoned_date_time(
                plain_date_time.fields.inner,
                time_zone,
                disambiguation,
            ),
        );
        errdefer temporal_rs.c.temporal_rs_ZonedDateTime_destroy(temporal_rs_zoned_date_time.?);
        const zoned_date_time = createTemporalZonedDateTime(
            agent,
            temporal_rs_zoned_date_time.?,
            null,
        ) catch |err| try noexcept(err);
        return Value.from(&zoned_date_time.object);
    }

    /// 5.3.30 Temporal.PlainDateTime.prototype.until ( other [ , options ] )
    /// https://tc39.es/proposal-temporal/#sec-temporal.plaindatetime.prototype.until
    fn until(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const other = arguments.get(0);
        const options = arguments.get(1);

        // 1. Let plainDateTime be the this value.
        // 2. Perform ? RequireInternalSlot(plainDateTime, [[InitializedTemporalDateTime]]).
        const plain_date_time = try this_value.requireInternalSlot(agent, PlainDateTime);

        // 3. Return ? DifferenceTemporalPlainDateTime(until, plainDateTime, other, options).
        const duration = try differenceTemporalPlainDateTime(
            agent,
            .until,
            plain_date_time,
            other,
            options,
        );
        return Value.from(&duration.object);
    }

    /// 5.3.37 Temporal.PlainDateTime.prototype.valueOf ( )
    /// https://tc39.es/proposal-temporal/#sec-temporal.plaindatetime.prototype.valueof
    fn valueOf(agent: *Agent, _: Value, _: Arguments) Agent.Error!Value {
        // 1. Throw a TypeError exception.
        return agent.throwException(
            .type_error,
            "Cannot convert Temporal.PlainDateTime to primitive value",
            .{},
        );
    }

    /// 5.3.18 get Temporal.PlainDateTime.prototype.weekOfYear
    /// https://tc39.es/proposal-temporal/#sec-get-temporal.plaindatetime.prototype.weekofyear
    fn weekOfYear(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let plainDateTime be the this value.
        // 2. Perform ? RequireInternalSlot(plainDateTime, [[InitializedTemporalDateTime]]).
        const plain_date_time = try this_value.requireInternalSlot(agent, PlainDateTime);

        // 3. Let result be CalendarISOToDate(plainDateTime.[[Calendar]],
        //    plainDateTime.[[ISODateTime]].[[ISODate]]).[[WeekOfYear]].[[Week]].
        const result = temporal_rs.c.temporal_rs_PlainDateTime_week_of_year(
            plain_date_time.fields.inner,
        );

        // 4. If result is undefined, return undefined.
        if (!result.is_ok) return .undefined;

        // 5. Return 𝔽(result).
        return Value.from(result.unnamed_0.ok);
    }

    /// 5.3.25 Temporal.PlainDateTime.prototype.with ( temporalDateTimeLike [ , options ] )
    /// https://tc39.es/proposal-temporal/#sec-temporal.plaindatetime.prototype.with
    fn with(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const temporal_date_time_like = arguments.get(0);
        const options_value = arguments.get(1);

        // 1. Let plainDateTime be the this value.
        // 2. Perform ? RequireInternalSlot(plainDateTime, [[InitializedTemporalDateTime]]).
        const plain_date_time = try this_value.requireInternalSlot(agent, PlainDateTime);

        // 3. If ? IsPartialTemporalObject(temporalDateTimeLike) is false, throw a TypeError
        //    exception.
        if (!try isPartialTemporalObject(agent, temporal_date_time_like)) {
            return agent.throwException(
                .type_error,
                "Argument must be a partial Temporal object",
                .{},
            );
        }

        // 4. Let calendar be plainDateTime.[[Calendar]].
        const calendar = temporal_rs.c.temporal_rs_Calendar_kind(
            temporal_rs.c.temporal_rs_PlainDateTime_calendar(plain_date_time.fields.inner),
        );

        // 5. Let fields be ISODateToFields(calendar, plainDateTime.[[ISODateTime]].[[ISODate]],
        //    date).
        // 6. Set fields.[[Hour]] to plainDateTime.[[ISODateTime]].[[Time]].[[Hour]].
        // 7. Set fields.[[Minute]] to plainDateTime.[[ISODateTime]].[[Time]].[[Minute]].
        // 8. Set fields.[[Second]] to plainDateTime.[[ISODateTime]].[[Time]].[[Second]].
        // 9. Set fields.[[Millisecond]] to plainDateTime.[[ISODateTime]].[[Time]].[[Millisecond]].
        // 10. Set fields.[[Microsecond]] to plainDateTime.[[ISODateTime]].[[Time]].[[Microsecond]].
        // 11. Set fields.[[Nanosecond]] to plainDateTime.[[ISODateTime]].[[Time]].[[Nanosecond]].
        // 12. Let partialDateTime be ? PrepareCalendarFields(calendar, temporalDateTimeLike,
        //     « year, month, month-code, day », « hour, minute, second, millisecond, microsecond,
        //     nanosecond », partial).
        // 13. Set fields to CalendarMergeFields(calendar, fields, partialDateTime).
        const fields = try prepareCalendarFields(
            agent,
            calendar,
            temporal_date_time_like.asObject(),
            .initMany(&.{
                .year,
                .month,
                .month_code,
                .day,
                .hour,
                .minute,
                .second,
                .millisecond,
                .microsecond,
                .nanosecond,
            }),
            .partial,
        );
        const partial: temporal_rs.c.PartialDateTime = .{
            .date = fields.date,
            .time = fields.time,
        };

        // 14. Let resolvedOptions be ? GetOptionsObject(options).
        const options = try options_value.getOptionsObject(agent);

        // 15. Let overflow be ? GetTemporalOverflowOption(resolvedOptions).
        const overflow = try getTemporalOverflowOption(agent, options);

        // 16. Let result be ? InterpretTemporalDateTimeFields(calendar, fields, overflow).
        // 17. Return ? CreateTemporalDateTime(result, calendar).
        const temporal_rs_plain_date_time = try builtins.temporal.extractResult(
            agent,
            temporal_rs.c.temporal_rs_PlainDateTime_with(
                plain_date_time.fields.inner,
                partial,
                temporal_rs.toArithmeticOverflowOption(overflow),
            ),
        );
        errdefer temporal_rs.c.temporal_rs_PlainDateTime_destroy(temporal_rs_plain_date_time.?);
        const new_plain_date_time = createTemporalDateTime(
            agent,
            temporal_rs_plain_date_time.?,
            null,
        ) catch |err| try noexcept(err);
        return Value.from(&new_plain_date_time.object);
    }

    /// 5.3.27 Temporal.PlainDateTime.prototype.withCalendar ( calendarLike )
    /// https://tc39.es/proposal-temporal/#sec-temporal.plaindatetime.prototype.withcalendar
    fn withCalendar(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const calendar_like = arguments.get(0);

        // 1. Let plainDateTime be the this value.
        // 2. Perform ? RequireInternalSlot(plainDateTime, [[InitializedTemporalDateTime]]).
        const plain_date_time = try this_value.requireInternalSlot(agent, PlainDateTime);

        // 3. Let calendar be ? ToTemporalCalendarIdentifier(calendarLike).
        const calendar = try toTemporalCalendarIdentifier(agent, calendar_like);

        // 4. Return ! CreateTemporalDateTime(plainDateTime.[[ISODateTime]], calendar).
        const temporal_rs_plain_date_time = temporal_rs.c.temporal_rs_PlainDateTime_with_calendar(
            plain_date_time.fields.inner,
            calendar,
        );
        errdefer temporal_rs.c.temporal_rs_PlainDateTime_destroy(temporal_rs_plain_date_time.?);
        const new_plain_date_time = createTemporalDateTime(
            agent,
            temporal_rs_plain_date_time.?,
            null,
        ) catch |err| try noexcept(err);
        return Value.from(&new_plain_date_time.object);
    }

    /// 5.3.26 Temporal.PlainDateTime.prototype.withPlainTime ( [ plainTimeLike ] )
    /// https://tc39.es/proposal-temporal/#sec-temporal.plaindatetime.prototype.withplaintime
    fn withPlainTime(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const plain_time_like = arguments.get(0);

        // 1. Let plainDateTime be the this value.
        // 2. Perform ? RequireInternalSlot(plainDateTime, [[InitializedTemporalDateTime]]).
        const plain_date_time = try this_value.requireInternalSlot(agent, PlainDateTime);

        // 3. Let time be ? ToTimeRecordOrMidnight(plainTimeLike).
        const maybe_time = try toTimeRecordOrMidnight(agent, plain_time_like);

        // 4. Let isoDateTime be CombineISODateAndTimeRecord(
        //    plainDateTime.[[ISODateTime]].[[ISODate]], time).
        // 5. Return ? CreateTemporalDateTime(isoDateTime, plainDateTime.[[Calendar]]).
        const temporal_rs_plain_date_time = try builtins.temporal.extractResult(
            agent,
            temporal_rs.c.temporal_rs_PlainDateTime_with_time(
                plain_date_time.fields.inner,
                maybe_time,
            ),
        );
        errdefer temporal_rs.c.temporal_rs_PlainDateTime_destroy(temporal_rs_plain_date_time.?);
        const new_plain_date_time = createTemporalDateTime(
            agent,
            temporal_rs_plain_date_time.?,
            null,
        ) catch |err| try noexcept(err);
        return Value.from(&new_plain_date_time.object);
    }

    /// 5.3.6 get Temporal.PlainDateTime.prototype.year
    /// https://tc39.es/proposal-temporal/#sec-get-temporal.plaindatetime.prototype.year
    fn year(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let plainDateTime be the this value.
        // 2. Perform ? RequireInternalSlot(plainDateTime, [[InitializedTemporalDateTime]]).
        const plain_date_time = try this_value.requireInternalSlot(agent, PlainDateTime);

        // 3. Return 𝔽(CalendarISOToDate(plainDateTime.[[Calendar]],
        //    plainDateTime.[[ISODateTime]].[[ISODate]]).[[Year]]).
        return Value.from(
            temporal_rs.c.temporal_rs_PlainDateTime_year(plain_date_time.fields.inner),
        );
    }

    /// 5.3.19 get Temporal.PlainDateTime.prototype.yearOfWeek
    /// https://tc39.es/proposal-temporal/#sec-get-temporal.plaindatetime.prototype.yearofweek
    fn yearOfWeek(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let plainDateTime be the this value.
        // 2. Perform ? RequireInternalSlot(plainDateTime, [[InitializedTemporalDateTime]]).
        const plain_date_time = try this_value.requireInternalSlot(agent, PlainDateTime);

        // 3. Let result be CalendarISOToDate(plainDateTime.[[Calendar]],
        //    plainDateTime.[[ISODateTime]].[[ISODate]]).[[WeekOfYear]].[[Year]].
        const result = temporal_rs.c.temporal_rs_PlainDateTime_year_of_week(
            plain_date_time.fields.inner,
        );

        // 4. If result is undefined, return undefined.
        if (!result.is_ok) return .undefined;

        // 5. Return 𝔽(result).
        return Value.from(result.unnamed_0.ok);
    }
};

/// 5.4 Properties of Temporal.PlainDateTime Instances
/// https://tc39.es/proposal-temporal/#sec-properties-of-temporal-plaindatetime-instances
pub const PlainDateTime = MakeObject(.{
    .Fields = struct {
        inner: *temporal_rs.c.PlainDateTime,
    },
    .finalizer = struct {
        fn finalizer(object: *Object) void {
            temporal_rs.c.temporal_rs_PlainDateTime_destroy(object.as(PlainDateTime).fields.inner);
        }
    }.finalizer,
    .tag = .temporal_plain_date_time,
    .display_name = "Temporal.PlainDateTime",
});

/// 5.5.8 CreateTemporalDateTime ( isoDateTime, calendar [ , newTarget ] )
/// https://tc39.es/proposal-temporal/#sec-temporal-createtemporaldatetime
pub fn createTemporalDateTime(
    agent: *Agent,
    inner: *temporal_rs.c.PlainDateTime,
    maybe_new_target: ?*Object,
) Agent.Error!*PlainDateTime {
    const realm = agent.currentRealm();

    // 1. If ISODateTimeWithinLimits(isoDateTime) is false, throw a RangeError exception.

    // 2. If newTarget is not present, set newTarget to %Temporal.PlainDateTime%.
    const new_target = maybe_new_target orelse try realm.intrinsic(.temporal_plain_date_time);

    // 3. Let object be ? OrdinaryCreateFromConstructor(newTarget,
    //    "%Temporal.PlainDateTime.prototype%", « [[InitializedTemporalDateTime]], [[ISODateTime]],
    //    [[Calendar]] »).
    // 4. Set object.[[ISODateTime]] to isoDateTime.
    // 5. Set object.[[Calendar]] to calendar.
    // 6. Return object.
    return ordinaryCreateFromConstructor(
        PlainDateTime,
        agent,
        new_target,
        .temporal_plain_date_time_prototype,
        .{ .inner = inner },
    );
}

/// 5.5.6 ToTemporalDateTime ( item [ , options ] )
/// https://tc39.es/proposal-temporal/#sec-temporal-totemporaldatetime
pub fn toTemporalPlainDateTime(
    agent: *Agent,
    item: Value,
    maybe_options_value: ?Value,
) Agent.Error!*PlainDateTime {
    // 1. If options is not present, set options to undefined.
    const options_value: Value = maybe_options_value orelse .undefined;

    // 2. If item is an Object, then
    const temporal_rs_plain_date_time = if (item.isObject()) blk: {
        // a. If item has an [[InitializedTemporalDateTime]] internal slot, then
        if (item.asObject().cast(PlainDateTime)) |plain_date_time| {
            // i. Let resolvedOptions be ? GetOptionsObject(options).
            const options = try options_value.getOptionsObject(agent);

            // ii. Perform ? GetTemporalOverflowOption(resolvedOptions).
            _ = try getTemporalOverflowOption(agent, options);

            // iii. Return ! CreateTemporalDateTime(item.[[ISODateTime]], item.[[Calendar]]).
            break :blk temporal_rs.c.temporal_rs_PlainDateTime_clone(plain_date_time.fields.inner);
        }

        // b. If item has an [[InitializedTemporalZonedDateTime]] internal slot, then
        if (item.asObject().cast(builtins.temporal.ZonedDateTime)) |zoned_date_time| {
            // i. Let isoDateTime be GetISODateTimeFor(item.[[TimeZone]],
            //    item.[[EpochNanoseconds]]).

            // ii. Let resolvedOptions be ? GetOptionsObject(options).
            const options = try options_value.getOptionsObject(agent);

            // iii. Perform ? GetTemporalOverflowOption(resolvedOptions).
            _ = try getTemporalOverflowOption(agent, options);

            // iv. Return ! CreateTemporalDateTime(isoDateTime, item.[[Calendar]]).
            break :blk temporal_rs.c.temporal_rs_ZonedDateTime_to_plain_datetime(
                zoned_date_time.fields.inner,
            );
        }

        // c. If item has an [[InitializedTemporalDate]] internal slot, then
        if (item.asObject().cast(builtins.temporal.PlainDate)) |plain_date| {
            // i. Let resolvedOptions be ? GetOptionsObject(options).
            const options = try options_value.getOptionsObject(agent);

            // ii. Perform ? GetTemporalOverflowOption(resolvedOptions).
            _ = try getTemporalOverflowOption(agent, options);

            // iii. Let isoDateTime be CombineISODateAndTimeRecord(item.[[ISODate]],
            //      MidnightTimeRecord()).
            // iv. Return ? CreateTemporalDateTime(isoDateTime, item.[[Calendar]]).
            const midnight = try builtins.temporal.extractResult(
                agent,
                temporal_rs.c.temporal_rs_PlainTime_try_new(0, 0, 0, 0, 0, 0),
            );
            defer temporal_rs.c.temporal_rs_PlainTime_destroy(midnight.?);
            break :blk try builtins.temporal.extractResult(
                agent,
                temporal_rs.c.temporal_rs_PlainDate_to_plain_date_time(
                    plain_date.fields.inner,
                    midnight.?,
                ),
            );
        }

        // d. Let calendar be ? GetTemporalCalendarIdentifierWithISODefault(item).
        const calendar = try getTemporalCalendarIdentifierWithISODefault(agent, item.asObject());

        // e. Let fields be ? PrepareCalendarFields(calendar, item, « year, month, month-code,
        //    day », « hour, minute, second, millisecond, microsecond, nanosecond », «»).
        const fields = try prepareCalendarFields(
            agent,
            calendar,
            item.asObject(),
            .initMany(&.{
                .year,
                .month,
                .month_code,
                .day,
                .hour,
                .minute,
                .second,
                .millisecond,
                .microsecond,
                .nanosecond,
            }),
            .none,
        );
        const partial: temporal_rs.c.PartialDateTime = .{
            .date = fields.date,
            .time = fields.time,
        };

        // f. Let resolvedOptions be ? GetOptionsObject(options).
        const options = try options_value.getOptionsObject(agent);

        // g. Let overflow be ? GetTemporalOverflowOption(resolvedOptions).
        const overflow = try getTemporalOverflowOption(agent, options);

        // h. Let result be ? InterpretTemporalDateTimeFields(calendar, fields, overflow).
        // i. Return ? CreateTemporalDateTime(result, calendar).
        break :blk try builtins.temporal.extractResult(
            agent,
            temporal_rs.c.temporal_rs_PlainDateTime_from_partial(
                partial,
                temporal_rs.toArithmeticOverflowOption(overflow),
            ),
        );
    } else blk: {
        // 3. If item is not a String, throw a TypeError exception.
        if (!item.isString()) {
            return agent.throwException(
                .type_error,
                "Plain date must be a string or object",
                .{},
            );
        }

        // 4. Let result be ? ParseISODateTime(item, « TemporalDateTimeString[~Zoned] »).
        // 5. If result.[[Time]] is start-of-day, let time be MidnightTimeRecord(); else let time be
        //    result.[[Time]].
        // 6. Let calendar be result.[[Calendar]].
        // 7. If calendar is empty, set calendar to "iso8601".
        // 8. Set calendar to ? CanonicalizeCalendar(calendar).
        const parsed_date_time = switch (item.asString().asAsciiOrUtf16()) {
            .ascii => |ascii| try builtins.temporal.extractResult(
                agent,
                temporal_rs.c.temporal_rs_ParsedDateTime_from_utf8(
                    temporal_rs.toDiplomatStringView(ascii),
                ),
            ),
            .utf16 => |utf16| try builtins.temporal.extractResult(
                agent,
                temporal_rs.c.temporal_rs_ParsedDateTime_from_utf16(
                    temporal_rs.toDiplomatString16View(utf16),
                ),
            ),
        };
        defer temporal_rs.c.temporal_rs_ParsedDateTime_destroy(parsed_date_time.?);

        // 9. Let resolvedOptions be ? GetOptionsObject(options).
        const options = try options_value.getOptionsObject(agent);

        // 10. Perform ? GetTemporalOverflowOption(resolvedOptions).
        _ = try getTemporalOverflowOption(agent, options);

        // 11. Let isoDate be CreateISODateRecord(result.[[Year]], result.[[Month]],
        //     result.[[Day]]).
        // 12. Let isoDateTime be CombineISODateAndTimeRecord(isoDate, time).
        // 13. Return ? CreateTemporalDateTime(isoDateTime, calendar).
        break :blk try builtins.temporal.extractResult(
            agent,
            temporal_rs.c.temporal_rs_PlainDateTime_from_parsed(parsed_date_time.?),
        );
    };
    errdefer temporal_rs.c.temporal_rs_PlainDateTime_destroy(temporal_rs_plain_date_time.?);

    return createTemporalDateTime(
        agent,
        temporal_rs_plain_date_time.?,
        null,
    ) catch |err| try noexcept(err);
}

/// 5.5.15 DifferenceTemporalPlainDateTime ( operation, dateTime, other, options )
/// https://tc39.es/proposal-temporal/#sec-temporal-differencetemporalplaindatetime
fn differenceTemporalPlainDateTime(
    agent: *Agent,
    operation: enum { since, until },
    plain_date_time: *const PlainDateTime,
    other_value: Value,
    options_value: Value,
) Agent.Error!*builtins.temporal.Duration {
    // 1. Set other to ? ToTemporalDateTime(other).
    const other = try toTemporalPlainDateTime(agent, other_value, null);

    // 2. If CalendarEquals(dateTime.[[Calendar]], other.[[Calendar]]) is false, throw a RangeError
    //    exception.
    if (temporal_rs.c.temporal_rs_Calendar_kind(
        temporal_rs.c.temporal_rs_PlainDateTime_calendar(plain_date_time.fields.inner),
    ) != temporal_rs.c.temporal_rs_Calendar_kind(
        temporal_rs.c.temporal_rs_PlainDateTime_calendar(other.fields.inner),
    )) {
        return agent.throwException(
            .range_error,
            "Difference requires equal calendars",
            .{},
        );
    }

    // 3. Let resolvedOptions be ? GetOptionsObject(options).
    const options = try options_value.getOptionsObject(agent);

    // 4. Let settings be ? GetDifferenceSettings(operation, resolvedOptions, datetime, « »,
    //    nanosecond, day).
    const settings = try getTemporalDifferenceSettingsWithoutValidation(agent, options);

    // 5. If CompareISODateTime(dateTime.[[ISODateTime]], other.[[ISODateTime]]) = 0, return
    //    ! CreateTemporalDuration(0, 0, 0, 0, 0, 0, 0, 0, 0, 0).
    // 6. Let internalDuration be ? DifferencePlainDateTimeWithRounding(dateTime.[[ISODateTime]],
    //    other.[[ISODateTime]], dateTime.[[Calendar]], settings.[[LargestUnit]],
    //    settings.[[RoundingIncrement]], settings.[[SmallestUnit]], settings.[[RoundingMode]]).
    // 7. Let result be ! TemporalDurationFromInternal(internalDuration, settings.[[LargestUnit]]).
    // 8. If operation is since, set result to CreateNegatedTemporalDuration(result).
    // 9. Return result.
    const temporal_rs_duration = switch (operation) {
        .since => try builtins.temporal.extractResult(
            agent,
            temporal_rs.c.temporal_rs_PlainDateTime_since(
                plain_date_time.fields.inner,
                other.fields.inner,
                settings,
            ),
        ),
        .until => try builtins.temporal.extractResult(
            agent,
            temporal_rs.c.temporal_rs_PlainDateTime_until(
                plain_date_time.fields.inner,
                other.fields.inner,
                settings,
            ),
        ),
    };
    errdefer temporal_rs.c.temporal_rs_Duration_destroy(temporal_rs_duration.?);
    return createTemporalDuration(
        agent,
        temporal_rs_duration.?,
        null,
    ) catch |err| try noexcept(err);
}

/// 5.5.16 AddDurationToDateTime ( operation, dateTime, temporalDurationLike, options )
/// https://tc39.es/proposal-temporal/#sec-temporal-adddurationtodatetime
fn addDurationToDateTime(
    agent: *Agent,
    operation: enum { add, subtract },
    plain_date_time: *const PlainDateTime,
    temporal_duration_like: Value,
    options_value: Value,
) Agent.Error!*PlainDateTime {
    // 1. Let duration be ? ToTemporalDuration(temporalDurationLike).
    const duration = try toTemporalDuration(agent, temporal_duration_like);

    // 2. If operation is subtract, set duration to CreateNegatedTemporalDuration(duration).

    // 3. Let resolvedOptions be ? GetOptionsObject(options).
    const options = try options_value.getOptionsObject(agent);

    // 4. Let overflow be ? GetTemporalOverflowOption(resolvedOptions).
    const overflow = try getTemporalOverflowOption(agent, options);

    // 5. Let internalDuration be ToInternalDurationRecordWith24HourDays(duration).
    // 6. Let timeResult be AddTime(dateTime.[[ISODateTime]].[[Time]], internalDuration.[[Time]]).
    // 7. Let dateDuration be ? AdjustDateDurationRecord(internalDuration.[[Date]],
    //    timeResult.[[Days]]).
    // 8. Let addedDate be ? CalendarDateAdd(dateTime.[[Calendar]],
    //    dateTime.[[ISODateTime]].[[ISODate]], dateDuration, overflow).
    // 9. Let result be CombineISODateAndTimeRecord(addedDate, timeResult).
    // 10. Return ? CreateTemporalDateTime(result, dateTime.[[Calendar]]).
    const temporal_rs_plain_date_time = switch (operation) {
        .add => try builtins.temporal.extractResult(
            agent,
            temporal_rs.c.temporal_rs_PlainDateTime_add(
                plain_date_time.fields.inner,
                duration.fields.inner,
                temporal_rs.toArithmeticOverflowOption(overflow),
            ),
        ),
        .subtract => try builtins.temporal.extractResult(
            agent,
            temporal_rs.c.temporal_rs_PlainDateTime_subtract(
                plain_date_time.fields.inner,
                duration.fields.inner,
                temporal_rs.toArithmeticOverflowOption(overflow),
            ),
        ),
    };
    errdefer temporal_rs.c.temporal_rs_PlainDateTime_destroy(temporal_rs_plain_date_time.?);
    return createTemporalDateTime(
        agent,
        temporal_rs_plain_date_time.?,
        null,
    ) catch |err| try noexcept(err);
}
