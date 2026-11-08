//! 3 Temporal.PlainDate Objects
//! https://tc39.es/proposal-temporal/#sec-temporal-plaindate-objects

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
const createTemporalDateTime = builtins.createTemporalDateTime;
const createTemporalDuration = builtins.createTemporalDuration;
const createTemporalMonthDay = builtins.createTemporalMonthDay;
const createTemporalYearMonth = builtins.createTemporalYearMonth;
const createTemporalZonedDateTime = builtins.createTemporalZonedDateTime;
const getTemporalCalendarIdentifierWithISODefault = builtins.getTemporalCalendarIdentifierWithISODefault;
const getTemporalDifferenceSettingsWithoutValidation = builtins.getTemporalDifferenceSettingsWithoutValidation;
const getTemporalOverflowOption = builtins.getTemporalOverflowOption;
const getTemporalShowCalendarNameOption = builtins.getTemporalShowCalendarNameOption;
const isPartialTemporalObject = builtins.isPartialTemporalObject;
const noexcept = utils.noexcept;
const ordinaryCreateFromConstructor = builtins.ordinaryCreateFromConstructor;
const ordinaryObjectCreate = builtins.ordinaryObjectCreate;
const prepareCalendarFields = builtins.prepareCalendarFields;
const toTemporalCalendarIdentifier = builtins.toTemporalCalendarIdentifier;
const toTemporalDuration = builtins.toTemporalDuration;
const toTemporalPlainTime = builtins.toTemporalPlainTime;
const toTemporalTimeZoneIdentifier = builtins.toTemporalTimeZoneIdentifier;
const toTimeRecordOrMidnight = builtins.toTimeRecordOrMidnight;

/// 3.2 Properties of the Temporal.PlainDate Constructor
/// https://tc39.es/proposal-temporal/#sec-properties-of-the-temporal-plaindate-constructor
pub const constructor = struct {
    pub fn create(agent: *Agent, realm: *Realm) std.mem.Allocator.Error!*Object {
        const builtin_function = try createBuiltinFunction(
            agent,
            .{ .constructor = impl },
            3,
            "PlainDate",
            .{ .realm = realm, .proto = try realm.intrinsic(.function_prototype) },
        );
        return &builtin_function.object;
    }

    pub fn init(agent: *Agent, realm: *Realm, object: *Object) std.mem.Allocator.Error!void {
        try object.defineBuiltinFunction(agent, "compare", compare, 2, realm);
        try object.defineBuiltinFunction(agent, "from", from, 1, realm);

        // 3.2.1 Temporal.PlainDate.prototype
        // https://tc39.es/proposal-temporal/#sec-temporal.plaindate.prototype
        try object.defineBuiltinPropertyWithAttributes(
            agent,
            "prototype",
            Value.from(try realm.intrinsic(.temporal_plain_date_prototype)),
            .{
                .writable = false,
                .enumerable = false,
                .configurable = false,
            },
        );
    }

    /// 3.1.1 Temporal.PlainDate ( isoYear, isoMonth, isoDay [ , calendar ] )
    /// https://tc39.es/proposal-temporal/#sec-temporal.plaindate
    fn impl(agent: *Agent, arguments: Arguments, maybe_new_target: ?*Object) Agent.Error!Value {
        const iso_year_value = arguments.get(0);
        const iso_month_value = arguments.get(1);
        const iso_day_value = arguments.get(2);
        var calendar_value = arguments.get(3);

        // 1. If NewTarget is undefined, throw a TypeError exception.
        const new_target = maybe_new_target orelse {
            return agent.throwException(
                .type_error,
                "Temporal.PlainDate must be constructed with 'new'",
                .{},
            );
        };

        // 2. Let y be ? ToIntegerWithTruncation(isoYear).
        const iso_year = try iso_year_value.toIntegerWithTruncation(agent);

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

        // 8. If IsValidISODate(y, m, d) is false, throw a RangeError exception.
        if (!isValidISODate(iso_year, iso_month, iso_day)) {
            return agent.throwException(.range_error, "Invalid ISO date", .{});
        }

        // 9. Let isoDate be CreateISODateRecord(y, m, d).
        // 10. Return ? CreateTemporalDate(isoDate, calendar, NewTarget).
        const temporal_rs_plain_date = try builtins.temporal.extractResult(
            agent,
            temporal_rs.c.temporal_rs_PlainDate_try_new(
                @intFromFloat(iso_year),
                @intFromFloat(iso_month),
                @intFromFloat(iso_day),
                calendar,
            ),
        );
        errdefer temporal_rs.c.temporal_rs_PlainDate_destroy(temporal_rs_plain_date.?);
        std.debug.assert(temporal_rs.c.temporal_rs_PlainDate_is_valid(temporal_rs_plain_date.?));
        const plain_time = try createTemporalDate(agent, temporal_rs_plain_date.?, new_target);
        return Value.from(&plain_time.object);
    }

    /// 3.2.3 Temporal.PlainDate.compare ( one, two )
    /// https://tc39.es/proposal-temporal/#sec-temporal.plaindate.compare
    fn compare(agent: *Agent, _: Value, arguments: Arguments) Agent.Error!Value {
        const one_value = arguments.get(0);
        const two_value = arguments.get(1);

        // 1. Set one to ? ToTemporalDate(one).
        const one = try toTemporalPlainDate(agent, one_value, null);

        // 2. Set two to ? ToTemporalDate(two).
        const two = try toTemporalPlainDate(agent, two_value, null);

        // 3. Return 𝔽(CompareISODate(one.[[ISODate]], two.[[ISODate]])).
        return Value.from(
            temporal_rs.c.temporal_rs_PlainDate_compare(one.fields.inner, two.fields.inner),
        );
    }

    /// 3.2.2 Temporal.PlainDate.from ( item [ , options ] )
    /// https://tc39.es/proposal-temporal/#sec-temporal.plaindate.from
    fn from(agent: *Agent, _: Value, arguments: Arguments) Agent.Error!Value {
        const item = arguments.get(0);
        const options = arguments.get(1);

        // 1. Return ? ToTemporalDate(item, options).
        const plain_date = try toTemporalPlainDate(agent, item, options);
        return Value.from(&plain_date.object);
    }
};

/// 3.3 Properties of the Temporal.PlainDate Prototype Object
/// https://tc39.es/proposal-temporal/#sec-properties-of-the-temporal-plaindate-prototype-object
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
        try object.defineBuiltinAccessor(agent, "inLeapYear", inLeapYear, null, realm);
        try object.defineBuiltinAccessor(agent, "month", month, null, realm);
        try object.defineBuiltinAccessor(agent, "monthCode", monthCode, null, realm);
        try object.defineBuiltinAccessor(agent, "monthsInYear", monthsInYear, null, realm);
        try object.defineBuiltinFunction(agent, "since", since, 1, realm);
        try object.defineBuiltinFunction(agent, "subtract", subtract, 1, realm);
        try object.defineBuiltinFunction(agent, "toJSON", toJSON, 0, realm);
        try object.defineBuiltinFunction(agent, "toLocaleString", toLocaleString, 0, realm);
        try object.defineBuiltinFunction(agent, "toPlainDateTime", toPlainDateTime, 0, realm);
        try object.defineBuiltinFunction(agent, "toPlainMonthDay", toPlainMonthDay, 0, realm);
        try object.defineBuiltinFunction(agent, "toPlainYearMonth", toPlainYearMonth, 0, realm);
        try object.defineBuiltinFunction(agent, "toString", toString, 0, realm);
        try object.defineBuiltinFunction(agent, "toZonedDateTime", toZonedDateTime, 1, realm);
        try object.defineBuiltinFunction(agent, "until", until, 1, realm);
        try object.defineBuiltinFunction(agent, "valueOf", valueOf, 0, realm);
        try object.defineBuiltinAccessor(agent, "weekOfYear", weekOfYear, null, realm);
        try object.defineBuiltinFunction(agent, "with", with, 1, realm);
        try object.defineBuiltinFunction(agent, "withCalendar", withCalendar, 1, realm);
        try object.defineBuiltinAccessor(agent, "year", year, null, realm);
        try object.defineBuiltinAccessor(agent, "yearOfWeek", yearOfWeek, null, realm);

        // 3.3.1 Temporal.PlainDate.prototype.constructor
        // https://tc39.es/proposal-temporal/#sec-temporal.plaindate.prototype.constructor
        try object.defineBuiltinProperty(
            agent,
            "constructor",
            Value.from(try realm.intrinsic(.temporal_plain_date)),
        );

        // 3.3.2 Temporal.PlainDate.prototype[ %Symbol.toStringTag% ]
        // https://tc39.es/proposal-temporal/#sec-temporal.plaindate.prototype-%symbol.tostringtag%
        try object.defineBuiltinPropertyWithAttributes(
            agent,
            "Symbol.toStringTag",
            Value.from("Temporal.PlainDate"),
            .{
                .writable = false,
                .enumerable = false,
                .configurable = true,
            },
        );
    }

    /// 3.3.21 Temporal.PlainDate.prototype.add ( temporalDurationLike [ , options ] )
    /// https://tc39.es/proposal-temporal/#sec-temporal.plaindate.prototype.add
    fn add(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const temporal_duration_like = arguments.get(0);
        const options = arguments.get(1);

        // 1. Let plainDate be the this value.
        // 2. Perform ? RequireInternalSlot(plainDate, [[InitializedTemporalDate]]).
        const plain_date = try this_value.requireInternalSlot(agent, PlainDate);

        // 3. Return ? AddDurationToDate(add, plainDate, temporalDurationLike, options).
        const new_plain_date = try addDurationToDate(
            agent,
            .add,
            plain_date,
            temporal_duration_like,
            options,
        );
        return Value.from(&new_plain_date.object);
    }

    /// 3.3.3 get Temporal.PlainDate.prototype.calendarId
    /// https://tc39.es/proposal-temporal/#sec-get-temporal.plaindate.prototype.calendarid
    fn calendarId(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let plainDate be the this value.
        // 2. Perform ? RequireInternalSlot(plainDate, [[InitializedTemporalDate]]).
        const plain_date = try this_value.requireInternalSlot(agent, PlainDate);

        // 3. Return plainDate.[[Calendar]].
        const temporal_rs_calendar = temporal_rs.c.temporal_rs_PlainDate_calendar(
            plain_date.fields.inner,
        );
        const calendar_id = temporal_rs.fromDiplomatStringView(
            temporal_rs.c.temporal_rs_Calendar_identifier(temporal_rs_calendar.?),
        );
        return Value.from(
            try String.fromAscii(agent, try agent.gc_allocator.dupe(u8, calendar_id)),
        );
    }

    /// 3.3.9 get Temporal.PlainDate.prototype.day
    /// https://tc39.es/proposal-temporal/#sec-get-temporal.plaindate.prototype.day
    fn day(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let plainDate be the this value.
        // 2. Perform ? RequireInternalSlot(plainDate, [[InitializedTemporalDate]]).
        const plain_date = try this_value.requireInternalSlot(agent, PlainDate);

        // 3. Return 𝔽(CalendarISOToDate(plainDate.[[Calendar]], plainDate.[[ISODate]]).[[Day]]).
        return Value.from(temporal_rs.c.temporal_rs_PlainDate_day(plain_date.fields.inner));
    }

    /// 3.3.10 get Temporal.PlainDate.prototype.dayOfWeek
    /// https://tc39.es/proposal-temporal/#sec-get-temporal.plaindate.prototype.dayofweek
    fn dayOfWeek(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let plainDate be the this value.
        // 2. Perform ? RequireInternalSlot(plainDate, [[InitializedTemporalDate]]).
        const plain_date = try this_value.requireInternalSlot(agent, PlainDate);

        // 3. Return 𝔽(CalendarISOToDate(plainDate.[[Calendar]],
        //    plainDate.[[ISODate]]).[[DayOfWeek]]).
        return Value.from(
            temporal_rs.c.temporal_rs_PlainDate_day_of_week(plain_date.fields.inner),
        );
    }

    /// 3.3.11 get Temporal.PlainDate.prototype.dayOfYear
    /// https://tc39.es/proposal-temporal/#sec-get-temporal.plaindate.prototype.dayofyear
    fn dayOfYear(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let plainDate be the this value.
        // 2. Perform ? RequireInternalSlot(plainDate, [[InitializedTemporalDate]]).
        const plain_date = try this_value.requireInternalSlot(agent, PlainDate);

        // 3. Return 𝔽(CalendarISOToDate(plainDate.[[Calendar]],
        //    plainDate.[[ISODate]]).[[DayOfYear]]).
        return Value.from(temporal_rs.c.temporal_rs_PlainDate_day_of_year(plain_date.fields.inner));
    }

    /// 3.3.15 get Temporal.PlainDate.prototype.daysInMonth
    /// https://tc39.es/proposal-temporal/#sec-get-temporal.plaindate.prototype.daysinmonth
    fn daysInMonth(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let plainDate be the this value.
        // 2. Perform ? RequireInternalSlot(plainDate, [[InitializedTemporalDate]]).
        const plain_date = try this_value.requireInternalSlot(agent, PlainDate);

        // 3. Return 𝔽(CalendarISOToDate(plainDate.[[Calendar]],
        //    plainDate.[[ISODate]]).[[DaysInMonth]]).
        return Value.from(temporal_rs.c.temporal_rs_PlainDate_days_in_month(plain_date.fields.inner));
    }

    /// 3.3.14 get Temporal.PlainDate.prototype.daysInWeek
    /// https://tc39.es/proposal-temporal/#sec-get-temporal.plaindate.prototype.daysinweek
    fn daysInWeek(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let plainDate be the this value.
        // 2. Perform ? RequireInternalSlot(plainDate, [[InitializedTemporalDate]]).
        const plain_date = try this_value.requireInternalSlot(agent, PlainDate);

        // 3. Return 𝔽(CalendarISOToDate(plainDate.[[Calendar]],
        //    plainDate.[[ISODate]]).[[DaysInWeek]]).
        return Value.from(
            temporal_rs.c.temporal_rs_PlainDate_days_in_week(plain_date.fields.inner),
        );
    }

    /// 3.3.16 get Temporal.PlainDate.prototype.daysInYear
    /// https://tc39.es/proposal-temporal/#sec-get-temporal.plaindate.prototype.daysinyear
    fn daysInYear(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let plainDate be the this value.
        // 2. Perform ? RequireInternalSlot(plainDate, [[InitializedTemporalDate]]).
        const plain_date = try this_value.requireInternalSlot(agent, PlainDate);

        // 3. Return 𝔽(CalendarISOToDate(plainDate.[[Calendar]],
        //    plainDate.[[ISODate]]).[[DaysInYear]]).
        return Value.from(temporal_rs.c.temporal_rs_PlainDate_days_in_year(plain_date.fields.inner));
    }

    /// 3.3.27 Temporal.PlainDate.prototype.equals ( other )
    /// https://tc39.es/proposal-temporal/#sec-temporal.plaindate.prototype.equals
    fn equals(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const other_value = arguments.get(0);

        // 1. Let plainDate be the this value.
        // 2. Perform ? RequireInternalSlot(plainDate, [[InitializedTemporalDate]]).
        const plain_date = try this_value.requireInternalSlot(agent, PlainDate);

        // 3. Set other to ? ToTemporalDate(other).
        const other = try toTemporalPlainDate(agent, other_value, null);

        // 4. If CompareISODate(plainDate.[[ISODate]], other.[[ISODate]]) ≠ 0, return false.
        // 5. Return CalendarEquals(plainDate.[[Calendar]], other.[[Calendar]]).
        return Value.from(
            temporal_rs.c.temporal_rs_PlainDate_equals(
                plain_date.fields.inner,
                other.fields.inner,
            ),
        );
    }

    /// 3.3.4 get Temporal.PlainDate.prototype.era
    /// https://tc39.es/proposal-temporal/#sec-get-temporal.plaindate.prototype.era
    fn era(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let plainDate be the this value.
        // 2. Perform ? RequireInternalSlot(plainDate, [[InitializedTemporalDate]]).
        const plain_date = try this_value.requireInternalSlot(agent, PlainDate);

        // 3. Return CalendarISOToDate(plainDate.[[Calendar]], plainDate.[[ISODate]]).[[Era]].
        var write = temporal_rs.DiplomatWrite.init(agent.gc_allocator);
        temporal_rs.c.temporal_rs_PlainDate_era(plain_date.fields.inner, &write.inner);
        if (write.inner.len == 0) {
            std.debug.assert(write.inner.cap == 0); // Nothing to free
            return .undefined;
        }
        return Value.from(try String.fromAscii(agent, try write.toOwnedSlice()));
    }

    /// 3.3.5 get Temporal.PlainDate.prototype.eraYear
    /// https://tc39.es/proposal-temporal/#sec-get-temporal.plaindate.prototype.erayear
    fn eraYear(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let plainDate be the this value.
        // 2. Perform ? RequireInternalSlot(plainDate, [[InitializedTemporalDate]]).
        const plain_date = try this_value.requireInternalSlot(agent, PlainDate);

        // 3. Let result be CalendarISOToDate(plainDate.[[Calendar]],
        //    plainDate.[[ISODate]]).[[EraYear]].
        const result = temporal_rs.c.temporal_rs_PlainDate_era_year(plain_date.fields.inner);

        // 4. If result is undefined, return undefined.
        if (!result.is_ok) return .undefined;

        // 5. Return 𝔽(result).
        return Value.from(result.unnamed_0.ok);
    }

    /// 3.3.18 get Temporal.PlainDate.prototype.inLeapYear
    /// https://tc39.es/proposal-temporal/#sec-get-temporal.plaindate.prototype.inleapyear
    fn inLeapYear(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let plainDate be the this value.
        // 2. Perform ? RequireInternalSlot(plainDate, [[InitializedTemporalDate]]).
        const plain_date = try this_value.requireInternalSlot(agent, PlainDate);

        // 3. Return CalendarISOToDate(plainDate.[[Calendar]],
        //    plainDate.[[ISODate]]).[[InLeapYear]].
        return Value.from(temporal_rs.c.temporal_rs_PlainDate_in_leap_year(plain_date.fields.inner));
    }

    /// 3.3.7 get Temporal.PlainDate.prototype.month
    /// https://tc39.es/proposal-temporal/#sec-get-temporal.plaindate.prototype.month
    fn month(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let plainDate be the this value.
        // 2. Perform ? RequireInternalSlot(plainDate, [[InitializedTemporalDate]]).
        const plain_date = try this_value.requireInternalSlot(agent, PlainDate);

        // 3. Return 𝔽(CalendarISOToDate(plainDate.[[Calendar]], plainDate.[[ISODate]]).[[Month]]).
        return Value.from(temporal_rs.c.temporal_rs_PlainDate_month(plain_date.fields.inner));
    }

    /// 3.3.8 get Temporal.PlainDate.prototype.monthCode
    /// https://tc39.es/proposal-temporal/#sec-get-temporal.plaindate.prototype.monthcode
    fn monthCode(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let plainDate be the this value.
        // 2. Perform ? RequireInternalSlot(plainDate, [[InitializedTemporalDate]]).
        const plain_date = try this_value.requireInternalSlot(agent, PlainDate);

        // 3. Return CalendarISOToDate(plainDate.[[Calendar]], plainDate.[[ISODate]]).[[MonthCode]].
        var write = temporal_rs.DiplomatWrite.init(agent.gc_allocator);
        temporal_rs.c.temporal_rs_PlainDate_month_code(plain_date.fields.inner, &write.inner);
        return Value.from(try String.fromAscii(agent, try write.toOwnedSlice()));
    }

    /// 3.3.17 get Temporal.PlainDate.prototype.monthsInYear
    /// https://tc39.es/proposal-temporal/#sec-get-temporal.plaindate.prototype.monthsinyear
    fn monthsInYear(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let plainDate be the this value.
        // 2. Perform ? RequireInternalSlot(plainDate, [[InitializedTemporalDate]]).
        const plain_date = try this_value.requireInternalSlot(agent, PlainDate);

        // 3. Return 𝔽(CalendarISOToDate(plainDate.[[Calendar]],
        //    plainDate.[[ISODate]]).[[MonthsInYear]]).
        return Value.from(temporal_rs.c.temporal_rs_PlainDate_months_in_year(plain_date.fields.inner));
    }

    /// 3.3.26 Temporal.PlainDate.prototype.since ( other [ , options ] )
    /// https://tc39.es/proposal-temporal/#sec-temporal.plaindate.prototype.since
    fn since(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const other = arguments.get(0);
        const options = arguments.get(1);

        // 1. Let plainDate be the this value.
        // 2. Perform ? RequireInternalSlot(plainDate, [[InitializedTemporalDate]]).
        const plain_date = try this_value.requireInternalSlot(agent, PlainDate);

        // 3. Return ? DifferenceTemporalPlainDate(since, plainDate, other, options).
        const duration = try differenceTemporalPlainDate(
            agent,
            .since,
            plain_date,
            other,
            options,
        );
        return Value.from(&duration.object);
    }

    /// 3.3.22 Temporal.PlainDate.prototype.subtract ( temporalDurationLike [ , options ] )
    /// https://tc39.es/proposal-temporal/#sec-temporal.plaindate.prototype.subtract
    fn subtract(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const temporal_duration_like = arguments.get(0);
        const options = arguments.get(1);

        // 1. Let plainDate be the this value.
        // 2. Perform ? RequireInternalSlot(plainDate, [[InitializedTemporalDate]]).
        const plain_date = try this_value.requireInternalSlot(agent, PlainDate);

        // 3. Return ? AddDurationToDate(subtract, plainDate, temporalDurationLike, options).
        const new_plain_date = try addDurationToDate(
            agent,
            .subtract,
            plain_date,
            temporal_duration_like,
            options,
        );
        return Value.from(&new_plain_date.object);
    }

    /// 3.3.32 Temporal.PlainDate.prototype.toJSON ( )
    /// https://tc39.es/proposal-temporal/#sec-temporal.plaindate.prototype.tojson
    fn toJSON(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let plainDate be the this value.
        // 2. Perform ? RequireInternalSlot(plainDate, [[InitializedTemporalDate]]).
        const plain_date = try this_value.requireInternalSlot(agent, PlainDate);

        // 3. Return TemporalDateToString(plainDate, auto).
        var write = temporal_rs.DiplomatWrite.init(agent.gc_allocator);
        temporal_rs.c.temporal_rs_PlainDate_to_ixdtf_string(
            plain_date.fields.inner,
            temporal_rs.c.DisplayCalendar_Auto,
            &write.inner,
        );
        return Value.from(try String.fromAscii(agent, try write.toOwnedSlice()));
    }

    /// 3.3.31 Temporal.PlainDate.prototype.toLocaleString ( [ locales [ , options ] ] )
    /// https://tc39.es/proposal-temporal/#sec-temporal.plaindate.prototype.tolocalestring
    fn toLocaleString(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let plainDate be the this value.
        // 2. Perform ? RequireInternalSlot(plainDate, [[InitializedTemporalDate]]).
        const plain_date = try this_value.requireInternalSlot(agent, PlainDate);

        // 3. Return TemporalDateToString(plainDate, auto).
        var write = temporal_rs.DiplomatWrite.init(agent.gc_allocator);
        temporal_rs.c.temporal_rs_PlainDate_to_ixdtf_string(
            plain_date.fields.inner,
            temporal_rs.c.DisplayCalendar_Auto,
            &write.inner,
        );
        return Value.from(try String.fromAscii(agent, try write.toOwnedSlice()));
    }

    /// 3.3.28 Temporal.PlainDate.prototype.toPlainDateTime ( [ temporalTime ] )
    /// https://tc39.es/proposal-temporal/#sec-temporal.plaindate.prototype.toplaindatetime
    fn toPlainDateTime(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const temporal_time = arguments.get(0);

        // 1. Let plainDate be the this value.
        // 2. Perform ? RequireInternalSlot(plainDate, [[InitializedTemporalDate]]).
        const plain_date = try this_value.requireInternalSlot(agent, PlainDate);

        // 3. Let time be ? ToTimeRecordOrMidnight(temporalTime).
        const maybe_time = try toTimeRecordOrMidnight(agent, temporal_time);

        // 4. Let isoDateTime be CombineISODateAndTimeRecord(plainDate.[[ISODate]], time).
        // 5. Return ? CreateTemporalDateTime(isoDateTime, plainDate.[[Calendar]]).
        const temporal_rs_plain_date_time = try builtins.temporal.extractResult(
            agent,
            temporal_rs.c.temporal_rs_PlainDate_to_plain_date_time(
                plain_date.fields.inner,
                maybe_time,
            ),
        );
        errdefer temporal_rs.c.temporal_rs_PlainDateTime_destroy(temporal_rs_plain_date_time.?);
        const plain_date_time = createTemporalDateTime(
            agent,
            temporal_rs_plain_date_time.?,
            null,
        ) catch |err| try noexcept(err);
        return Value.from(&plain_date_time.object);
    }

    /// 3.3.20 Temporal.PlainDate.prototype.toPlainMonthDay ( )
    /// https://tc39.es/proposal-temporal/#sec-temporal.plaindate.prototype.toplainmonthday
    fn toPlainMonthDay(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let plainDate be the this value.
        // 2. Perform ? RequireInternalSlot(plainDate, [[InitializedTemporalDate]]).
        const plain_date = try this_value.requireInternalSlot(agent, PlainDate);

        // 3. Let calendar be plainDate.[[Calendar]].
        // 4. Let fields be ISODateToFields(calendar, plainDate.[[ISODate]], date).
        // 5. Let isoDate be ? CalendarMonthDayFromFields(calendar, fields, constrain).
        const temporal_rs_plain_month_day = try builtins.temporal.extractResult(
            agent,
            temporal_rs.c.temporal_rs_PlainDate_to_plain_month_day(plain_date.fields.inner),
        );
        errdefer temporal_rs.c.temporal_rs_PlainMonthDay_destroy(temporal_rs_plain_month_day.?);

        // 6. Return ! CreateTemporalMonthDay(isoDate, calendar).
        const plain_month_day = createTemporalMonthDay(
            agent,
            temporal_rs_plain_month_day.?,
            null,
        ) catch |err| try noexcept(err);
        return Value.from(&plain_month_day.object);

        // 7. NOTE: The call to CalendarMonthDayFromFields is necessary in order to create a
        //    PlainMonthDay object with the [[Year]] field of the [[ISODate]] internal slot set
        //    correctly.
    }

    /// 3.3.19 Temporal.PlainDate.prototype.toPlainYearMonth ( )
    /// https://tc39.es/proposal-temporal/#sec-temporal.plaindate.prototype.toplainyearmonth
    fn toPlainYearMonth(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let plainDate be the this value.
        // 2. Perform ? RequireInternalSlot(plainDate, [[InitializedTemporalDate]]).
        const plain_date = try this_value.requireInternalSlot(agent, PlainDate);

        // 3. Let calendar be plainDate.[[Calendar]].
        // 4. Let fields be ISODateToFields(calendar, plainDate.[[ISODate]], date).
        // 5. Let isoDate be ? CalendarYearMonthFromFields(calendar, fields, constrain).
        const temporal_rs_plain_year_month = try builtins.temporal.extractResult(
            agent,
            temporal_rs.c.temporal_rs_PlainDate_to_plain_year_month(plain_date.fields.inner),
        );
        errdefer temporal_rs.c.temporal_rs_PlainYearMonth_destroy(temporal_rs_plain_year_month.?);

        // 6. Return ! CreateTemporalYearMonth(isoDate, calendar).
        const plain_year_month = createTemporalYearMonth(
            agent,
            temporal_rs_plain_year_month.?,
            null,
        ) catch |err| try noexcept(err);
        return Value.from(&plain_year_month.object);

        // 7. NOTE: The call to CalendarYearMonthFromFields is necessary in order to create a
        //    PlainYearMonth object with the [[Day]] field of the [[ISODate]] internal slot set
        //    correctly.
    }

    /// 3.3.30 Temporal.PlainDate.prototype.toString ( [ options ] )
    /// https://tc39.es/proposal-temporal/#sec-temporal.plaindate.prototype.tostring
    fn toString(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const options_value = arguments.get(0);

        // 1. Let plainDate be the this value.
        // 2. Perform ? RequireInternalSlot(plainDate, [[InitializedTemporalDate]]).
        const plain_date = try this_value.requireInternalSlot(agent, PlainDate);

        // 3. Let resolvedOptions be ? GetOptionsObject(options).
        const options = try options_value.getOptionsObject(agent);

        // 4. Let showCalendar be ? GetTemporalShowCalendarNameOption(resolvedOptions).
        const show_calendar = try getTemporalShowCalendarNameOption(agent, options);

        // 5. Return TemporalDateToString(plainDate, showCalendar).
        var write = temporal_rs.DiplomatWrite.init(agent.gc_allocator);
        temporal_rs.c.temporal_rs_PlainDate_to_ixdtf_string(
            plain_date.fields.inner,
            show_calendar,
            &write.inner,
        );
        return Value.from(try String.fromAscii(agent, try write.toOwnedSlice()));
    }

    /// 3.3.29 Temporal.PlainDate.prototype.toZonedDateTime ( item )
    /// https://tc39.es/proposal-temporal/#sec-temporal.plaindate.prototype.tozoneddatetime
    fn toZonedDateTime(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const item = arguments.get(0);

        // 1. Let plainDate be the this value.
        // 2. Perform ? RequireInternalSlot(plainDate, [[InitializedTemporalDate]]).
        const plain_date = try this_value.requireInternalSlot(agent, PlainDate);

        // 3. If item is an Object, then
        const time_zone, const plain_time_value: Value = if (item.isObject()) blk: {
            // a. Let timeZoneLike be ? Get(item, "timeZone").
            const time_zone_like = try item.asObject().get(agent, PropertyKey.from("timeZone"));

            // b. If timeZoneLike is undefined, then
            if (time_zone_like.isUndefined()) {
                // i. Let timeZone be ? ToTemporalTimeZoneIdentifier(item).
                const time_zone = try toTemporalTimeZoneIdentifier(agent, item);

                // ii. Let temporalTime be undefined.
                break :blk .{ time_zone, .undefined };
            } else {
                // c. Else,
                // i. Let timeZone be ? ToTemporalTimeZoneIdentifier(timeZoneLike).
                const time_zone = try toTemporalTimeZoneIdentifier(agent, time_zone_like);

                // ii. Let temporalTime be ? Get(item, "plainTime").
                const plain_time = try item.get(agent, PropertyKey.from("plainTime"));

                break :blk .{ time_zone, plain_time };
            }
        } else blk: {
            // 4. Else,
            // a. Let timeZone be ? ToTemporalTimeZoneIdentifier(item).
            const time_zone = try toTemporalTimeZoneIdentifier(agent, item);

            // b. Let temporalTime be undefined.
            break :blk .{ time_zone, .undefined };
        };

        // 5. If temporalTime is undefined, then
        const maybe_plain_time = if (plain_time_value.isUndefined()) blk: {
            // a. Let epochNs be ? GetStartOfDay(timeZone, plainDate.[[ISODate]]).
            // NOTE: This is handled by passing null to temporal_rs.
            break :blk null;
        } else blk: {
            // 6. Else,
            // a. Set temporalTime to ? ToTemporalTime(temporalTime).
            break :blk try toTemporalPlainTime(agent, plain_time_value, null);

            // b. Let isoDateTime be CombineISODateAndTimeRecord(plainDate.[[ISODate]],
            //    temporalTime.[[Time]]).
            // c. If ISODateTimeWithinLimits(isoDateTime) is false, throw a RangeError exception.
            // d. Let epochNs be ? GetEpochNanosecondsFor(timeZone, isoDateTime, compatible).
        };

        // 7. Return ! CreateTemporalZonedDateTime(epochNs, timeZone, plainDate.[[Calendar]]).
        const temporal_rs_zoned_date_time = try builtins.temporal.extractResult(
            agent,
            temporal_rs.c.temporal_rs_PlainDate_to_zoned_date_time(
                plain_date.fields.inner,
                time_zone,
                if (maybe_plain_time) |plain_time| plain_time.fields.inner else null,
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

    /// 3.3.25 Temporal.PlainDate.prototype.until ( other [ , options ] )
    /// https://tc39.es/proposal-temporal/#sec-temporal.plaindate.prototype.until
    fn until(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const other = arguments.get(0);
        const options = arguments.get(1);

        // 1. Let plainDate be the this value.
        // 2. Perform ? RequireInternalSlot(plainDate, [[InitializedTemporalDate]]).
        const plain_date = try this_value.requireInternalSlot(agent, PlainDate);

        // 3. Return ? DifferenceTemporalPlainDate(until, plainDate, other, options).
        const duration = try differenceTemporalPlainDate(
            agent,
            .until,
            plain_date,
            other,
            options,
        );
        return Value.from(&duration.object);
    }

    /// 3.3.33 Temporal.PlainDate.prototype.valueOf ( )
    /// https://tc39.es/proposal-temporal/#sec-temporal.plaindate.prototype.valueof
    fn valueOf(agent: *Agent, _: Value, _: Arguments) Agent.Error!Value {
        // 1. Throw a TypeError exception.
        return agent.throwException(
            .type_error,
            "Cannot convert Temporal.PlainDate to primitive value",
            .{},
        );
    }

    /// 3.3.12 get Temporal.PlainDate.prototype.weekOfYear
    /// https://tc39.es/proposal-temporal/#sec-get-temporal.plaindate.prototype.weekofyear
    fn weekOfYear(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let plainDate be the this value.
        // 2. Perform ? RequireInternalSlot(plainDate, [[InitializedTemporalDate]]).
        const plain_date = try this_value.requireInternalSlot(agent, PlainDate);

        // 3. Let result be CalendarISOToDate(plainDate.[[Calendar]],
        //    plainDate.[[ISODate]]).[[WeekOfYear]].[[Week]].
        const result = temporal_rs.c.temporal_rs_PlainDate_week_of_year(plain_date.fields.inner);

        // 4. If result is undefined, return undefined.
        if (!result.is_ok) return .undefined;

        // 5. Return 𝔽(result).
        return Value.from(result.unnamed_0.ok);
    }

    /// 3.3.23 Temporal.PlainDate.prototype.with ( temporalDateLike [ , options ] )
    /// https://tc39.es/proposal-temporal/#sec-temporal.plaindate.prototype.with
    fn with(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const temporal_date_like = arguments.get(0);
        const options_value = arguments.get(1);

        // 1. Let plainDate be the this value.
        // 2. Perform ? RequireInternalSlot(plainDate, [[InitializedTemporalDate]]).
        const plain_date = try this_value.requireInternalSlot(agent, PlainDate);

        // 3. If ? IsPartialTemporalObject(temporalDateLike) is false, throw a TypeError exception.
        if (!try isPartialTemporalObject(agent, temporal_date_like)) {
            return agent.throwException(
                .type_error,
                "Argument must be a partial Temporal object",
                .{},
            );
        }

        // 4. Let calendar be plainDate.[[Calendar]].
        const calendar = temporal_rs.c.temporal_rs_Calendar_kind(
            temporal_rs.c.temporal_rs_PlainDate_calendar(plain_date.fields.inner),
        );

        // 5. Let fields be ISODateToFields(calendar, plainDate.[[ISODate]], date).
        // 6. Let partialDate be ? PrepareCalendarFields(calendar, temporalDateLike, « year, month,
        //    month-code, day », « », partial).
        // 7. Set fields to CalendarMergeFields(calendar, fields, partialDate).
        const fields = try prepareCalendarFields(
            agent,
            calendar,
            temporal_date_like.asObject(),
            .initMany(&.{ .year, .month, .month_code, .day }),
            .partial,
        );
        const partial = fields.date;

        // 8. Let resolvedOptions be ? GetOptionsObject(options).
        const options = try options_value.getOptionsObject(agent);

        // 9. Let overflow be ? GetTemporalOverflowOption(resolvedOptions).
        const overflow = try getTemporalOverflowOption(agent, options);

        // 10. Let isoDate be ? CalendarDateFromFields(calendar, fields, overflow).
        // 11. Return ! CreateTemporalDate(isoDate, calendar).
        const temporal_rs_plain_date = try builtins.temporal.extractResult(
            agent,
            temporal_rs.c.temporal_rs_PlainDate_with(
                plain_date.fields.inner,
                partial,
                temporal_rs.toArithmeticOverflowOption(overflow),
            ),
        );
        errdefer temporal_rs.c.temporal_rs_PlainDate_destroy(temporal_rs_plain_date.?);
        const new_plain_date = createTemporalDate(
            agent,
            temporal_rs_plain_date.?,
            null,
        ) catch |err| try noexcept(err);
        return Value.from(&new_plain_date.object);
    }

    /// 3.3.24 Temporal.PlainDate.prototype.withCalendar ( calendarLike )
    /// https://tc39.es/proposal-temporal/#sec-temporal.plaindate.prototype.withcalendar
    fn withCalendar(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const calendar_like = arguments.get(0);

        // 1. Let plainDate be the this value.
        // 2. Perform ? RequireInternalSlot(plainDate, [[InitializedTemporalDate]]).
        const plain_date = try this_value.requireInternalSlot(agent, PlainDate);

        // 3. Let calendar be ? ToTemporalCalendarIdentifier(calendarLike).
        const calendar = try toTemporalCalendarIdentifier(agent, calendar_like);

        // 4. Return ! CreateTemporalDate(plainDate.[[ISODate]], calendar).
        const temporal_rs_plain_date = temporal_rs.c.temporal_rs_PlainDate_with_calendar(
            plain_date.fields.inner,
            calendar,
        );
        errdefer temporal_rs.c.temporal_rs_PlainDate_destroy(temporal_rs_plain_date.?);
        const new_plain_date = createTemporalDate(
            agent,
            temporal_rs_plain_date.?,
            null,
        ) catch |err| try noexcept(err);
        return Value.from(&new_plain_date.object);
    }

    /// 3.3.6 get Temporal.PlainDate.prototype.year
    /// https://tc39.es/proposal-temporal/#sec-get-temporal.plaindate.prototype.year
    fn year(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let plainDate be the this value.
        // 2. Perform ? RequireInternalSlot(plainDate, [[InitializedTemporalDate]]).
        const plain_date = try this_value.requireInternalSlot(agent, PlainDate);

        // 3. Return 𝔽(CalendarISOToDate(plainDate.[[Calendar]], plainDate.[[ISODate]]).[[Year]]).
        return Value.from(temporal_rs.c.temporal_rs_PlainDate_year(plain_date.fields.inner));
    }

    /// 3.3.13 get Temporal.PlainDate.prototype.yearOfWeek
    /// https://tc39.es/proposal-temporal/#sec-get-temporal.plaindate.prototype.yearofweek
    fn yearOfWeek(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let plainDate be the this value.
        // 2. Perform ? RequireInternalSlot(plainDate, [[InitializedTemporalDate]]).
        const plain_date = try this_value.requireInternalSlot(agent, PlainDate);

        // 3. Let result be CalendarISOToDate(plainDate.[[Calendar]],
        //    plainDate.[[ISODate]]).[[WeekOfYear]].[[Year]].
        const result = temporal_rs.c.temporal_rs_PlainDate_year_of_week(plain_date.fields.inner);

        // 4. If result is undefined, return undefined.
        if (!result.is_ok) return .undefined;

        // 5. Return 𝔽(result).
        return Value.from(result.unnamed_0.ok);
    }
};

/// 3.4 Properties of Temporal.PlainDate Instances
/// https://tc39.es/proposal-temporal/#sec-properties-of-temporal-plaindate-instances
pub const PlainDate = MakeObject(.{
    .Fields = struct {
        inner: *temporal_rs.c.PlainDate,
    },
    .finalizer = struct {
        fn finalizer(object: *Object) void {
            temporal_rs.c.temporal_rs_PlainDate_destroy(object.as(PlainDate).fields.inner);
        }
    }.finalizer,
    .tag = .temporal_plain_date,
    .display_name = "Temporal.PlainDate",
});

/// 3.5.3 CreateTemporalDate ( isoDate, calendar [ , newTarget ] )
/// https://tc39.es/proposal-temporal/#sec-temporal-createtemporaldate
pub fn createTemporalDate(
    agent: *Agent,
    inner: *temporal_rs.c.PlainDate,
    maybe_new_target: ?*Object,
) Agent.Error!*PlainDate {
    const realm = agent.currentRealm();

    // 1. If ISODateWithinLimits(isoDate) is false, throw a RangeError exception.

    // 2. If newTarget is not present, set newTarget to %Temporal.PlainDate%.
    const new_target = maybe_new_target orelse try realm.intrinsic(.temporal_plain_date);

    // 3. Let object be ? OrdinaryCreateFromConstructor(newTarget, "%Temporal.PlainDate.prototype%",
    //    « [[InitializedTemporalDate]], [[ISODate]], [[Calendar]] »).
    // 4. Set object.[[ISODate]] to isoDate.
    // 5. Set object.[[Calendar]] to calendar.
    // 6. Return object.
    return ordinaryCreateFromConstructor(
        PlainDate,
        agent,
        new_target,
        .temporal_plain_date_prototype,
        .{ .inner = inner },
    );
}

/// 3.5.4 ToTemporalDate ( item [ , options ] )
/// https://tc39.es/proposal-temporal/#sec-temporal-totemporaldate
pub fn toTemporalPlainDate(
    agent: *Agent,
    item: Value,
    maybe_options_value: ?Value,
) Agent.Error!*PlainDate {
    // 1. If options is not present, set options to undefined.
    const options_value: Value = maybe_options_value orelse .undefined;

    // 2. If item is an Object, then
    const temporal_rs_plain_date = if (item.isObject()) blk: {
        // a. If item has an [[InitializedTemporalDate]] internal slot, then
        if (item.asObject().cast(PlainDate)) |plain_date| {
            // i. Let resolvedOptions be ? GetOptionsObject(options).
            const options = try options_value.getOptionsObject(agent);

            // ii. Perform ? GetTemporalOverflowOption(resolvedOptions).
            _ = try getTemporalOverflowOption(agent, options);

            // iii. Return ! CreateTemporalDate(item.[[ISODate]], item.[[Calendar]]).
            break :blk temporal_rs.c.temporal_rs_PlainDate_clone(plain_date.fields.inner);
        }

        // b. If item has an [[InitializedTemporalZonedDateTime]] internal slot, then
        if (item.asObject().cast(builtins.temporal.ZonedDateTime)) |zoned_date_time| {
            // i. Let isoDateTime be GetISODateTimeFor(item.[[TimeZone]],
            //    item.[[EpochNanoseconds]]).

            // ii. Let resolvedOptions be ? GetOptionsObject(options).
            const options = try options_value.getOptionsObject(agent);

            // iii. Perform ? GetTemporalOverflowOption(resolvedOptions).
            _ = try getTemporalOverflowOption(agent, options);

            // iv. Return ! CreateTemporalDate(isoDateTime.[[ISODate]], item.[[Calendar]]).
            break :blk temporal_rs.c.temporal_rs_ZonedDateTime_to_plain_date(
                zoned_date_time.fields.inner,
            );
        }

        // c. If item has an [[InitializedTemporalDateTime]] internal slot, then
        if (item.asObject().cast(builtins.temporal.PlainDateTime)) |plain_date_time| {
            // i. Let resolvedOptions be ? GetOptionsObject(options).
            const options = try options_value.getOptionsObject(agent);

            // ii. Perform ? GetTemporalOverflowOption(resolvedOptions).
            _ = try getTemporalOverflowOption(agent, options);

            // iii. Return ! CreateTemporalDate(item.[[ISODateTime]].[[ISODate]],
            //      item.[[Calendar]]).
            break :blk temporal_rs.c.temporal_rs_PlainDateTime_to_plain_date(
                plain_date_time.fields.inner,
            );
        }

        // d. Let calendar be ? GetTemporalCalendarIdentifierWithISODefault(item).
        const calendar = try getTemporalCalendarIdentifierWithISODefault(agent, item.asObject());

        // e. Let fields be ? PrepareCalendarFields(calendar, item, « year, month, month-code,
        //    day », «», «»).
        const fields = try prepareCalendarFields(
            agent,
            calendar,
            item.asObject(),
            .initMany(&.{ .year, .month, .month_code, .day }),
            .none,
        );
        const partial = fields.date;

        // f. Let resolvedOptions be ? GetOptionsObject(options).
        const options = try options_value.getOptionsObject(agent);

        // g. Let overflow be ? GetTemporalOverflowOption(resolvedOptions).
        const overflow = try getTemporalOverflowOption(agent, options);

        // h. Let isoDate be ? CalendarDateFromFields(calendar, fields, overflow).
        // i. Return ! CreateTemporalDate(isoDate, calendar).
        break :blk try builtins.temporal.extractResult(
            agent,
            temporal_rs.c.temporal_rs_PlainDate_from_partial(
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
        // 5. Let calendar be result.[[Calendar]].
        // 6. If calendar is empty, set calendar to "iso8601".
        // 7. Set calendar to ? CanonicalizeCalendar(calendar).
        const parsed_date = switch (item.asString().asAsciiOrUtf16()) {
            .ascii => |ascii| try builtins.temporal.extractResult(
                agent,
                temporal_rs.c.temporal_rs_ParsedDate_from_utf8(
                    temporal_rs.toDiplomatStringView(ascii),
                ),
            ),
            .utf16 => |utf16| try builtins.temporal.extractResult(
                agent,
                temporal_rs.c.temporal_rs_ParsedDate_from_utf16(
                    temporal_rs.toDiplomatString16View(utf16),
                ),
            ),
        };
        defer temporal_rs.c.temporal_rs_ParsedDate_destroy(parsed_date.?);

        // 8. Let resolvedOptions be ? GetOptionsObject(options).
        const options = try options_value.getOptionsObject(agent);

        // 9. Perform ? GetTemporalOverflowOption(resolvedOptions).
        _ = try getTemporalOverflowOption(agent, options);

        // 10. Let isoDate be CreateISODateRecord(result.[[Year]], result.[[Month]],
        //     result.[[Day]]).
        // 11. Return ? CreateTemporalDate(isoDate, calendar).
        break :blk try builtins.temporal.extractResult(
            agent,
            temporal_rs.c.temporal_rs_PlainDate_from_parsed(parsed_date.?),
        );
    };
    errdefer temporal_rs.c.temporal_rs_PlainDate_destroy(temporal_rs_plain_date.?);

    return createTemporalDate(
        agent,
        temporal_rs_plain_date.?,
        null,
    ) catch |err| try noexcept(err);
}

/// 3.5.8 IsValidISODate ( year, month, day )
/// https://tc39.es/proposal-temporal/#sec-temporal-isvalidisodate
pub fn isValidISODate(year: f64, month: f64, day: f64) bool {
    // 1. If month < 1 or month > 12, return false.
    if (month < 1 or month > 12) return false;

    const year_int = std.math.lossyCast(std.time.epoch.Year, year);
    const month_int = std.math.lossyCast(@typeInfo(std.time.epoch.Month).@"enum".tag_type, month);

    // 2. Let daysInMonth be ISODaysInMonth(year, month).
    const days_in_month = std.time.epoch.getDaysInMonth(
        year_int,
        @fromBackingInt(month_int),
    );

    // 3. If day < 1 or day > daysInMonth, return false; else return true.
    return if (day < 1 or day > @as(f64, @floatFromInt(days_in_month))) false else true;
}

/// 3.5.14 DifferenceTemporalPlainDate ( operation, temporalDate, other, options )
/// https://tc39.es/proposal-temporal/#sec-temporal-differencetemporalplaindate
fn differenceTemporalPlainDate(
    agent: *Agent,
    operation: enum { since, until },
    plain_date: *const PlainDate,
    other_value: Value,
    options_value: Value,
) Agent.Error!*builtins.temporal.Duration {
    // 1. Set other to ? ToTemporalDate(other).
    const other = try toTemporalPlainDate(agent, other_value, null);

    // 2. If CalendarEquals(temporalDate.[[Calendar]], other.[[Calendar]]) is false, throw a
    //    RangeError exception.
    if (temporal_rs.c.temporal_rs_Calendar_kind(
        temporal_rs.c.temporal_rs_PlainDate_calendar(plain_date.fields.inner),
    ) != temporal_rs.c.temporal_rs_Calendar_kind(
        temporal_rs.c.temporal_rs_PlainDate_calendar(other.fields.inner),
    )) {
        return agent.throwException(
            .range_error,
            "Difference requires equal calendars",
            .{},
        );
    }

    // 3. Let resolvedOptions be ? GetOptionsObject(options).
    const options = try options_value.getOptionsObject(agent);

    // 4. Let settings be ? GetDifferenceSettings(operation, resolvedOptions, date, « », day, day).
    const settings = try getTemporalDifferenceSettingsWithoutValidation(agent, options);

    // 5. If CompareISODate(temporalDate.[[ISODate]], other.[[ISODate]]) = 0, then
    //     a. Return ! CreateTemporalDuration(0, 0, 0, 0, 0, 0, 0, 0, 0, 0).
    // 6. Let dateDifference be CalendarDateUntil(temporalDate.[[Calendar]],
    //    temporalDate.[[ISODate]], other.[[ISODate]], settings.[[LargestUnit]]).
    // 7. Let duration be CombineDateAndTimeDuration(dateDifference, 0).
    // 8. If settings.[[SmallestUnit]] is not day or settings.[[RoundingIncrement]] ≠ 1, then
    //     a. Let isoDateTime be CombineISODateAndTimeRecord(temporalDate.[[ISODate]],
    //        MidnightTimeRecord()).
    //     b. Let originEpochNs be GetUTCEpochNanoseconds(isoDateTime).
    //     c. Let isoDateTimeOther be CombineISODateAndTimeRecord(other.[[ISODate]],
    //        MidnightTimeRecord()).
    //     d. Let destEpochNs be GetUTCEpochNanoseconds(isoDateTimeOther).
    //     e. Set duration to ? RoundRelativeDuration(duration, originEpochNs, destEpochNs,
    //        isoDateTime, unset, temporalDate.[[Calendar]], settings.[[LargestUnit]],
    //        settings.[[RoundingIncrement]], settings.[[SmallestUnit]], settings.[[RoundingMode]]).
    // 9. Let result be ! TemporalDurationFromInternal(duration, day).
    // 10. If operation is since, set result to CreateNegatedTemporalDuration(result).
    // 11. Return result.
    const temporal_rs_duration = switch (operation) {
        .since => try builtins.temporal.extractResult(
            agent,
            temporal_rs.c.temporal_rs_PlainDate_since(
                plain_date.fields.inner,
                other.fields.inner,
                settings,
            ),
        ),
        .until => try builtins.temporal.extractResult(
            agent,
            temporal_rs.c.temporal_rs_PlainDate_until(
                plain_date.fields.inner,
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

/// 3.5.15 AddDurationToDate ( operation, temporalDate, temporalDurationLike, options )
/// https://tc39.es/proposal-temporal/#sec-temporal-adddurationtodate
fn addDurationToDate(
    agent: *Agent,
    operation: enum { add, subtract },
    plain_date: *const PlainDate,
    temporal_duration_like: Value,
    options_value: Value,
) Agent.Error!*PlainDate {
    // 1. Let calendar be temporalDate.[[Calendar]].

    // 2. Let duration be ? ToTemporalDuration(temporalDurationLike).
    const duration = try toTemporalDuration(agent, temporal_duration_like);

    // 3. If operation is subtract, set duration to CreateNegatedTemporalDuration(duration).
    // 4. Let dateDuration be ToDateDurationRecordWithoutTime(duration).

    // 5. Let resolvedOptions be ? GetOptionsObject(options).
    const options = try options_value.getOptionsObject(agent);

    // 6. Let overflow be ? GetTemporalOverflowOption(resolvedOptions).
    const overflow = try getTemporalOverflowOption(agent, options);

    // 7. Let result be ? CalendarDateAdd(calendar, temporalDate.[[ISODate]], dateDuration,
    //    overflow).
    // 8. Return ! CreateTemporalDate(result, calendar).
    const temporal_rs_plain_date = switch (operation) {
        .add => try builtins.temporal.extractResult(
            agent,
            temporal_rs.c.temporal_rs_PlainDate_add(
                plain_date.fields.inner,
                duration.fields.inner,
                temporal_rs.toArithmeticOverflowOption(overflow),
            ),
        ),
        .subtract => try builtins.temporal.extractResult(
            agent,
            temporal_rs.c.temporal_rs_PlainDate_subtract(
                plain_date.fields.inner,
                duration.fields.inner,
                temporal_rs.toArithmeticOverflowOption(overflow),
            ),
        ),
    };
    errdefer temporal_rs.c.temporal_rs_PlainDate_destroy(temporal_rs_plain_date.?);
    return createTemporalDate(
        agent,
        temporal_rs_plain_date.?,
        null,
    ) catch |err| try noexcept(err);
}
