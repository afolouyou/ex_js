//! 9 Temporal.PlainYearMonth Objects
//! https://tc39.es/proposal-temporal/#sec-temporal-plainyearmonth-objects

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
const createTemporalDuration = builtins.createTemporalDuration;
const getTemporalCalendarIdentifierWithISODefault = builtins.getTemporalCalendarIdentifierWithISODefault;
const getTemporalDifferenceSettingsWithoutValidation = builtins.getTemporalDifferenceSettingsWithoutValidation;
const getTemporalOverflowOption = builtins.getTemporalOverflowOption;
const getTemporalShowCalendarNameOption = builtins.getTemporalShowCalendarNameOption;
const isPartialTemporalObject = builtins.isPartialTemporalObject;
const isValidISODate = builtins.isValidISODate;
const noexcept = utils.noexcept;
const ordinaryCreateFromConstructor = builtins.ordinaryCreateFromConstructor;
const ordinaryObjectCreate = builtins.ordinaryObjectCreate;
const prepareCalendarFields = builtins.prepareCalendarFields;
const toTemporalDuration = builtins.toTemporalDuration;

/// 9.2 Properties of the Temporal.PlainYearMonth Constructor
/// https://tc39.es/proposal-temporal/#sec-properties-of-the-temporal-plainyearmonth-constructor
pub const constructor = struct {
    pub fn create(agent: *Agent, realm: *Realm) std.mem.Allocator.Error!*Object {
        const builtin_function = try createBuiltinFunction(
            agent,
            .{ .constructor = impl },
            2,
            "PlainYearMonth",
            .{ .realm = realm, .proto = try realm.intrinsic(.function_prototype) },
        );
        return &builtin_function.object;
    }

    pub fn init(agent: *Agent, realm: *Realm, object: *Object) std.mem.Allocator.Error!void {
        try object.defineBuiltinFunction(agent, "compare", compare, 2, realm);
        try object.defineBuiltinFunction(agent, "from", from, 1, realm);

        // 9.2.1 Temporal.PlainYearMonth.prototype
        // https://tc39.es/proposal-temporal/#sec-temporal.plainyearmonth.prototype
        try object.defineBuiltinPropertyWithAttributes(
            agent,
            "prototype",
            Value.from(try realm.intrinsic(.temporal_plain_year_month_prototype)),
            .{
                .writable = false,
                .enumerable = false,
                .configurable = false,
            },
        );
    }

    /// 9.1.1 Temporal.PlainYearMonth ( isoYear, isoMonth [ , calendar [ , referenceISODay ] ] )
    /// https://tc39.es/proposal-temporal/#sec-temporal.plainyearmonth
    fn impl(agent: *Agent, arguments: Arguments, maybe_new_target: ?*Object) Agent.Error!Value {
        const iso_year_value = arguments.get(0);
        const iso_month_value = arguments.get(1);
        var calendar_value = arguments.get(2);
        var reference_iso_day_value = arguments.get(3);

        // 1. If NewTarget is undefined, throw a TypeError exception.
        const new_target = maybe_new_target orelse {
            return agent.throwException(
                .type_error,
                "Temporal.PlainYearMonth must be constructed with 'new'",
                .{},
            );
        };

        // 2. If referenceISODay is undefined, then
        //     a. Set referenceISODay to 1𝔽.
        if (reference_iso_day_value.isUndefined()) reference_iso_day_value = Value.from(1);

        // 3. Let y be ? ToIntegerWithTruncation(isoYear).
        const iso_year = try iso_year_value.toIntegerWithTruncation(agent);

        // 4. Let m be ? ToIntegerWithTruncation(isoMonth).
        const iso_month = try iso_month_value.toIntegerWithTruncation(agent);

        // 5. If calendar is undefined, set calendar to "iso8601".
        if (calendar_value.isUndefined()) calendar_value = Value.from("iso8601");

        // 6. If calendar is not a String, throw a TypeError exception.
        if (!calendar_value.isString()) {
            return agent.throwException(.type_error, "Calendar is not a string", .{});
        }

        // 7. Set calendar to ? CanonicalizeCalendar(calendar).
        const calendar = try canonicalizeCalendar(agent, calendar_value.asString());

        // 8. Let ref be ? ToIntegerWithTruncation(referenceISODay).
        const reference_iso_day = try reference_iso_day_value.toIntegerWithTruncation(agent);

        // 9. If IsValidISODate(y, m, ref) is false, throw a RangeError exception.
        if (!isValidISODate(iso_year, iso_month, reference_iso_day)) {
            return agent.throwException(.range_error, "Invalid ISO date", .{});
        }

        // 10. Let isoDate be CreateISODateRecord(y, m, ref).
        // 11. Return ? CreateTemporalYearMonth(isoDate, calendar, NewTarget).
        const temporal_rs_plain_year_month = try builtins.temporal.extractResult(
            agent,
            temporal_rs.c.temporal_rs_PlainYearMonth_try_new_with_overflow(
                @intFromFloat(iso_year),
                @intFromFloat(iso_month),
                temporal_rs.toOption(temporal_rs.c.OptionU8, @intFromFloat(reference_iso_day)),
                calendar,
                temporal_rs.c.ArithmeticOverflow_Reject,
            ),
        );
        errdefer temporal_rs.c.temporal_rs_PlainYearMonth_destroy(temporal_rs_plain_year_month.?);
        const plain_year_month = try createTemporalYearMonth(agent, temporal_rs_plain_year_month.?, new_target);
        return Value.from(&plain_year_month.object);
    }

    /// 9.2.3 Temporal.PlainYearMonth.compare ( one, two )
    /// https://tc39.es/proposal-temporal/#sec-temporal.plainyearmonth.compare
    fn compare(agent: *Agent, _: Value, arguments: Arguments) Agent.Error!Value {
        const one_value = arguments.get(0);
        const two_value = arguments.get(1);

        // 1. Set one to ? ToTemporalYearMonth(one).
        const one = try toTemporalPlainYearMonth(agent, one_value, null);

        // 2. Set two to ? ToTemporalYearMonth(two).
        const two = try toTemporalPlainYearMonth(agent, two_value, null);

        // 3. Return 𝔽(CompareISODate(one.[[ISODate]], two.[[ISODate]])).
        return Value.from(
            temporal_rs.c.temporal_rs_PlainYearMonth_compare(one.fields.inner, two.fields.inner),
        );
    }

    /// 9.2.2 Temporal.PlainYearMonth.from ( item [ , options ] )
    /// https://tc39.es/proposal-temporal/#sec-temporal.plainyearmonth.from
    fn from(agent: *Agent, _: Value, arguments: Arguments) Agent.Error!Value {
        const item = arguments.get(0);
        const options = arguments.get(1);

        // 1. Return ? ToTemporalYearMonth(item, options).
        const plain_year_month = try toTemporalPlainYearMonth(agent, item, options);
        return Value.from(&plain_year_month.object);
    }
};

/// 9.3 Properties of the Temporal.PlainYearMonth Prototype Object
/// https://tc39.es/proposal-temporal/#sec-properties-of-the-temporal-plainyearmonth-prototype-object
pub const prototype = struct {
    pub fn create(agent: *Agent, realm: *Realm) std.mem.Allocator.Error!*Object {
        return ordinaryObjectCreate(agent, try realm.intrinsic(.object_prototype));
    }

    pub fn init(agent: *Agent, realm: *Realm, object: *Object) std.mem.Allocator.Error!void {
        try object.defineBuiltinFunction(agent, "add", add, 1, realm);
        try object.defineBuiltinAccessor(agent, "calendarId", calendarId, null, realm);
        try object.defineBuiltinAccessor(agent, "daysInMonth", daysInMonth, null, realm);
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
        try object.defineBuiltinFunction(agent, "toPlainDate", toPlainDate, 1, realm);
        try object.defineBuiltinFunction(agent, "toString", toString, 0, realm);
        try object.defineBuiltinFunction(agent, "until", until, 1, realm);
        try object.defineBuiltinFunction(agent, "valueOf", valueOf, 0, realm);
        try object.defineBuiltinFunction(agent, "with", with, 1, realm);
        try object.defineBuiltinAccessor(agent, "year", year, null, realm);

        // 9.3.1 Temporal.PlainYearMonth.prototype.constructor
        // https://tc39.es/proposal-temporal/#sec-temporal.plainyearmonth.prototype.constructor
        try object.defineBuiltinProperty(
            agent,
            "constructor",
            Value.from(try realm.intrinsic(.temporal_plain_year_month)),
        );

        // 9.3.2 Temporal.PlainYearMonth.prototype[ %Symbol.toStringTag% ]
        // https://tc39.es/proposal-temporal/#sec-temporal.plainyearmonth.prototype-%symbol.tostringtag%
        try object.defineBuiltinPropertyWithAttributes(
            agent,
            "Symbol.toStringTag",
            Value.from("Temporal.PlainYearMonth"),
            .{
                .writable = false,
                .enumerable = false,
                .configurable = true,
            },
        );
    }

    /// 9.3.14 Temporal.PlainYearMonth.prototype.add ( temporalDurationLike [ , options ] )
    /// https://tc39.es/proposal-temporal/#sec-temporal.plainyearmonth.prototype.add
    fn add(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const temporal_duration_like = arguments.get(0);
        const options = arguments.get(1);

        // 1. Let plainYearMonth be the this value.
        // 2. Perform ? RequireInternalSlot(plainYearMonth, [[InitializedTemporalYearMonth]]).
        const plain_year_month = try this_value.requireInternalSlot(agent, PlainYearMonth);

        // 3. Return ? AddDurationToYearMonth(add, plainYearMonth, temporalDurationLike, options).
        const new_plain_year_month = try addDurationToYearMonth(
            agent,
            .add,
            plain_year_month,
            temporal_duration_like,
            options,
        );
        return Value.from(&new_plain_year_month.object);
    }

    /// 9.3.3 get Temporal.PlainYearMonth.prototype.calendarId
    /// https://tc39.es/proposal-temporal/#sec-get-temporal.plainyearmonth.prototype.calendarid
    fn calendarId(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let plainYearMonth be the this value.
        // 2. Perform ? RequireInternalSlot(plainYearMonth, [[InitializedTemporalYearMonth]]).
        const plain_year_month = try this_value.requireInternalSlot(agent, PlainYearMonth);

        // 3. Return plainYearMonth.[[Calendar]].
        const temporal_rs_calendar = temporal_rs.c.temporal_rs_PlainYearMonth_calendar(
            plain_year_month.fields.inner,
        );
        const calendar_id = temporal_rs.fromDiplomatStringView(
            temporal_rs.c.temporal_rs_Calendar_identifier(temporal_rs_calendar.?),
        );
        return Value.from(
            try String.fromAscii(agent, try agent.gc_allocator.dupe(u8, calendar_id)),
        );
    }

    /// 9.3.10 get Temporal.PlainYearMonth.prototype.daysInMonth
    /// https://tc39.es/proposal-temporal/#sec-get-temporal.plainyearmonth.prototype.daysinmonth
    fn daysInMonth(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let plainYearMonth be the this value.
        // 2. Perform ? RequireInternalSlot(plainYearMonth, [[InitializedTemporalYearMonth]]).
        const plain_year_month = try this_value.requireInternalSlot(agent, PlainYearMonth);

        // 3. Return 𝔽(CalendarISOToDate(plainYearMonth.[[Calendar]],
        //    plainYearMonth.[[ISODate]]).[[DaysInMonth]]).
        return Value.from(temporal_rs.c.temporal_rs_PlainYearMonth_days_in_month(plain_year_month.fields.inner));
    }

    /// 9.3.9 get Temporal.PlainYearMonth.prototype.daysInYear
    /// https://tc39.es/proposal-temporal/#sec-get-temporal.plainyearmonth.prototype.daysinyear
    fn daysInYear(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let plainYearMonth be the this value.
        // 2. Perform ? RequireInternalSlot(plainYearMonth, [[InitializedTemporalYearMonth]]).
        const plain_year_month = try this_value.requireInternalSlot(agent, PlainYearMonth);

        // 3. Return 𝔽(CalendarISOToDate(plainYearMonth.[[Calendar]],
        //    plainYearMonth.[[ISODate]]).[[DaysInYear]]).
        return Value.from(
            temporal_rs.c.temporal_rs_PlainYearMonth_days_in_year(plain_year_month.fields.inner),
        );
    }

    /// 9.3.18 Temporal.PlainYearMonth.prototype.equals ( other )
    /// https://tc39.es/proposal-temporal/#sec-temporal.plainyearmonth.prototype.equals
    fn equals(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const other_value = arguments.get(0);

        // 1. Let plainYearMonth be the this value.
        // 2. Perform ? RequireInternalSlot(plainYearMonth, [[InitializedTemporalYearMonth]]).
        const plain_year_month = try this_value.requireInternalSlot(agent, PlainYearMonth);

        // 3. Set other to ? ToTemporalYearMonth(other).
        const other = try toTemporalPlainYearMonth(agent, other_value, null);

        // 4. If CompareISODate(plainYearMonth.[[ISODate]], other.[[ISODate]]) ≠ 0, return false.
        // 5. Return CalendarEquals(plainYearMonth.[[Calendar]], other.[[Calendar]]).
        return Value.from(
            temporal_rs.c.temporal_rs_PlainYearMonth_equals(
                plain_year_month.fields.inner,
                other.fields.inner,
            ),
        );
    }

    /// 9.3.4 get Temporal.PlainYearMonth.prototype.era
    /// https://tc39.es/proposal-temporal/#sec-get-temporal.plainyearmonth.prototype.era
    fn era(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let plainYearMonth be the this value.
        // 2. Perform ? RequireInternalSlot(plainYearMonth, [[InitializedTemporalYearMonth]]).
        const plain_year_month = try this_value.requireInternalSlot(agent, PlainYearMonth);

        // 3. Return CalendarISOToDate(plainYearMonth.[[Calendar]],
        //    plainYearMonth.[[ISODate]]).[[Era]].
        var write = temporal_rs.DiplomatWrite.init(agent.gc_allocator);
        temporal_rs.c.temporal_rs_PlainYearMonth_era(plain_year_month.fields.inner, &write.inner);
        if (write.inner.len == 0) {
            std.debug.assert(write.inner.cap == 0); // Nothing to free
            return .undefined;
        }
        return Value.from(try String.fromAscii(agent, try write.toOwnedSlice()));
    }

    /// 9.3.5 get Temporal.PlainYearMonth.prototype.eraYear
    /// https://tc39.es/proposal-temporal/#sec-get-temporal.plainyearmonth.prototype.erayear
    fn eraYear(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let plainYearMonth be the this value.
        // 2. Perform ? RequireInternalSlot(plainYearMonth, [[InitializedTemporalYearMonth]]).
        const plain_year_month = try this_value.requireInternalSlot(agent, PlainYearMonth);

        // 3. Let result be CalendarISOToDate(plainYearMonth.[[Calendar]],
        //    plainYearMonth.[[ISODate]]).[[EraYear]].
        const result = temporal_rs.c.temporal_rs_PlainYearMonth_era_year(
            plain_year_month.fields.inner,
        );

        // 4. If result is undefined, return undefined.
        if (!result.is_ok) return .undefined;

        // 5. Return 𝔽(result).
        return Value.from(result.unnamed_0.ok);
    }

    /// 9.3.12 get Temporal.PlainYearMonth.prototype.inLeapYear
    /// https://tc39.es/proposal-temporal/#sec-get-temporal.plainyearmonth.prototype.inleapyear
    fn inLeapYear(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let plainYearMonth be the this value.
        // 2. Perform ? RequireInternalSlot(plainYearMonth, [[InitializedTemporalYearMonth]]).
        const plain_year_month = try this_value.requireInternalSlot(agent, PlainYearMonth);

        // 3. Return CalendarISOToDate(plainYearMonth.[[Calendar]],
        //    plainYearMonth.[[ISODate]]).[[InLeapYear]].
        return Value.from(
            temporal_rs.c.temporal_rs_PlainYearMonth_in_leap_year(plain_year_month.fields.inner),
        );
    }

    /// 9.3.7 get Temporal.PlainYearMonth.prototype.month
    /// https://tc39.es/proposal-temporal/#sec-get-temporal.plainyearmonth.prototype.month
    fn month(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let plainYearMonth be the this value.
        // 2. Perform ? RequireInternalSlot(plainYearMonth, [[InitializedTemporalYearMonth]]).
        const plain_year_month = try this_value.requireInternalSlot(agent, PlainYearMonth);

        // 3. Return 𝔽(CalendarISOToDate(plainYearMonth.[[Calendar]],
        //    plainYearMonth.[[ISODate]]).[[Month]]).
        return Value.from(
            temporal_rs.c.temporal_rs_PlainYearMonth_month(plain_year_month.fields.inner),
        );
    }

    /// 9.3.8 get Temporal.PlainYearMonth.prototype.monthCode
    /// https://tc39.es/proposal-temporal/#sec-get-temporal.plainyearmonth.prototype.monthcode
    fn monthCode(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let plainYearMonth be the this value.
        // 2. Perform ? RequireInternalSlot(plainYearMonth, [[InitializedTemporalYearMonth]]).
        const plain_year_month = try this_value.requireInternalSlot(agent, PlainYearMonth);

        // 3. Return CalendarISOToDate(plainYearMonth.[[Calendar]],
        //    plainYearMonth.[[ISODate]]).[[MonthCode]].
        var write = temporal_rs.DiplomatWrite.init(agent.gc_allocator);
        temporal_rs.c.temporal_rs_PlainYearMonth_month_code(
            plain_year_month.fields.inner,
            &write.inner,
        );
        return Value.from(try String.fromAscii(agent, try write.toOwnedSlice()));
    }

    /// 9.3.11 get Temporal.PlainYearMonth.prototype.monthsInYear
    /// https://tc39.es/proposal-temporal/#sec-get-temporal.plainyearmonth.prototype.monthsinyear
    fn monthsInYear(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let plainYearMonth be the this value.
        // 2. Perform ? RequireInternalSlot(plainYearMonth, [[InitializedTemporalYearMonth]]).
        const plain_year_month = try this_value.requireInternalSlot(agent, PlainYearMonth);

        // 3. Return 𝔽(CalendarISOToDate(plainYearMonth.[[Calendar]],
        //    plainYearMonth.[[ISODate]]).[[MonthsInYear]]).
        return Value.from(
            temporal_rs.c.temporal_rs_PlainYearMonth_months_in_year(plain_year_month.fields.inner),
        );
    }

    /// 9.3.17 Temporal.PlainYearMonth.prototype.since ( other [ , options ] )
    /// https://tc39.es/proposal-temporal/#sec-temporal.plainyearmonth.prototype.since
    fn since(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const other = arguments.get(0);
        const options = arguments.get(1);

        // 1. Let plainYearMonth be the this value.
        // 2. Perform ? RequireInternalSlot(plainYearMonth, [[InitializedTemporalYearMonth]]).
        const plain_year_month = try this_value.requireInternalSlot(agent, PlainYearMonth);

        // 3. Return ? DifferenceTemporalPlainYearMonth(since, plainYearMonth, other, options).
        const duration = try differenceTemporalPlainYearMonth(
            agent,
            .since,
            plain_year_month,
            other,
            options,
        );
        return Value.from(&duration.object);
    }

    /// 9.3.15 Temporal.PlainYearMonth.prototype.subtract ( temporalDurationLike [ , options ] )
    /// https://tc39.es/proposal-temporal/#sec-temporal.plainyearmonth.prototype.subtract
    fn subtract(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const temporal_duration_like = arguments.get(0);
        const options = arguments.get(1);

        // 1. Let plainYearMonth be the this value.
        // 2. Perform ? RequireInternalSlot(plainYearMonth, [[InitializedTemporalYearMonth]]).
        const plain_year_month = try this_value.requireInternalSlot(agent, PlainYearMonth);

        // 3. Return ? AddDurationToYearMonth(subtract, plainYearMonth, temporalDurationLike,
        //    options).
        const new_plain_year_month = try addDurationToYearMonth(
            agent,
            .subtract,
            plain_year_month,
            temporal_duration_like,
            options,
        );
        return Value.from(&new_plain_year_month.object);
    }

    /// 9.3.21 Temporal.PlainYearMonth.prototype.toJSON ( )
    /// https://tc39.es/proposal-temporal/#sec-temporal.plainyearmonth.prototype.tojson
    fn toJSON(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let plainYearMonth be the this value.
        // 2. Perform ? RequireInternalSlot(plainYearMonth, [[InitializedTemporalYearMonth]]).
        const plain_year_month = try this_value.requireInternalSlot(agent, PlainYearMonth);

        // 3. Return TemporalYearMonthToString(plainYearMonth, auto).
        var write = temporal_rs.DiplomatWrite.init(agent.gc_allocator);
        temporal_rs.c.temporal_rs_PlainYearMonth_to_ixdtf_string(
            plain_year_month.fields.inner,
            temporal_rs.c.DisplayCalendar_Auto,
            &write.inner,
        );
        return Value.from(try String.fromAscii(agent, try write.toOwnedSlice()));
    }

    /// 9.3.20 Temporal.PlainYearMonth.prototype.toLocaleString ( [ locales [ , options ] ] )
    /// https://tc39.es/proposal-temporal/#sec-temporal.plainyearmonth.prototype.tolocalestring
    fn toLocaleString(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let plainYearMonth be the this value.
        // 2. Perform ? RequireInternalSlot(plainYearMonth, [[InitializedTemporalYearMonth]]).
        const plain_year_month = try this_value.requireInternalSlot(agent, PlainYearMonth);

        // 3. Return TemporalYearMonthToString(plainYearMonth, auto).
        var write = temporal_rs.DiplomatWrite.init(agent.gc_allocator);
        temporal_rs.c.temporal_rs_PlainYearMonth_to_ixdtf_string(
            plain_year_month.fields.inner,
            temporal_rs.c.DisplayCalendar_Auto,
            &write.inner,
        );
        return Value.from(try String.fromAscii(agent, try write.toOwnedSlice()));
    }

    /// 9.3.23 Temporal.PlainYearMonth.prototype.toPlainDate ( item )
    /// https://tc39.es/proposal-temporal/#sec-temporal.plainyearmonth.prototype.toplaindate
    fn toPlainDate(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const item = arguments.get(0);

        // 1. Let plainYearMonth be the this value.
        // 2. Perform ? RequireInternalSlot(plainYearMonth, [[InitializedTemporalYearMonth]]).
        const plain_year_month = try this_value.requireInternalSlot(agent, PlainYearMonth);

        // 3. If item is not an Object, throw a TypeError exception.
        if (!item.isObject()) {
            return agent.throwException(.type_error, "Item must be an object", .{});
        }

        // 4. Let calendar be plainYearMonth.[[Calendar]].
        const calendar = temporal_rs.c.temporal_rs_Calendar_kind(
            temporal_rs.c.temporal_rs_PlainYearMonth_calendar(plain_year_month.fields.inner),
        );

        // 5. Let fields be ISODateToFields(calendar, plainYearMonth.[[ISODate]], year-month).
        // 6. Let inputFields be ? PrepareCalendarFields(calendar, item, « day », « », « »).
        // 7. Let mergedFields be CalendarMergeFields(calendar, fields, inputFields).
        const fields = try prepareCalendarFields(
            agent,
            calendar,
            item.asObject(),
            .initOne(.day),
            .none,
        );
        const partial = fields.date;

        // 8. Let isoDate be ? CalendarDateFromFields(calendar, mergedFields, constrain).
        const temporal_rs_plain_date = try builtins.temporal.extractResult(
            agent,
            temporal_rs.c.temporal_rs_PlainYearMonth_to_plain_date(
                plain_year_month.fields.inner,
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

    /// 9.3.19 Temporal.PlainYearMonth.prototype.toString ( [ options ] )
    /// https://tc39.es/proposal-temporal/#sec-temporal.plainyearmonth.prototype.tostring
    fn toString(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const options_value = arguments.get(0);

        // 1. Let plainYearMonth be the this value.
        // 2. Perform ? RequireInternalSlot(plainYearMonth, [[InitializedTemporalYearMonth]]).
        const plain_year_month = try this_value.requireInternalSlot(agent, PlainYearMonth);

        // 3. Let resolvedOptions be ? GetOptionsObject(options).
        const options = try options_value.getOptionsObject(agent);

        // 4. Let showCalendar be ? GetTemporalShowCalendarNameOption(resolvedOptions).
        const show_calendar = try getTemporalShowCalendarNameOption(agent, options);

        // 5. Return TemporalYearMonthToString(plainYearMonth, showCalendar).
        var write = temporal_rs.DiplomatWrite.init(agent.gc_allocator);
        temporal_rs.c.temporal_rs_PlainYearMonth_to_ixdtf_string(
            plain_year_month.fields.inner,
            show_calendar,
            &write.inner,
        );
        return Value.from(try String.fromAscii(agent, try write.toOwnedSlice()));
    }

    /// 9.3.16 Temporal.PlainYearMonth.prototype.until ( other [ , options ] )
    /// https://tc39.es/proposal-temporal/#sec-temporal.plainyearmonth.prototype.until
    fn until(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const other = arguments.get(0);
        const options = arguments.get(1);

        // 1. Let plainYearMonth be the this value.
        // 2. Perform ? RequireInternalSlot(plainYearMonth, [[InitializedTemporalYearMonth]]).
        const plain_year_month = try this_value.requireInternalSlot(agent, PlainYearMonth);

        // 3. Return ? DifferenceTemporalPlainYearMonth(until, plainYearMonth, other, options).
        const duration = try differenceTemporalPlainYearMonth(
            agent,
            .until,
            plain_year_month,
            other,
            options,
        );
        return Value.from(&duration.object);
    }

    /// 9.3.22 Temporal.PlainYearMonth.prototype.valueOf ( )
    /// https://tc39.es/proposal-temporal/#sec-temporal.plainyearmonth.prototype.valueof
    fn valueOf(agent: *Agent, _: Value, _: Arguments) Agent.Error!Value {
        // 1. Throw a TypeError exception.
        return agent.throwException(
            .type_error,
            "Cannot convert Temporal.PlainYearMonth to primitive value",
            .{},
        );
    }

    /// 9.3.13 Temporal.PlainYearMonth.prototype.with ( temporalYearMonthLike [ , options ] )
    /// https://tc39.es/proposal-temporal/#sec-temporal.plainyearmonth.prototype.with
    fn with(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const temporal_year_month_like = arguments.get(0);
        const options_value = arguments.get(1);

        // 1. Let plainYearMonth be the this value.
        // 2. Perform ? RequireInternalSlot(plainYearMonth, [[InitializedTemporalYearMonth]]).
        const plain_year_month = try this_value.requireInternalSlot(agent, PlainYearMonth);

        // 3. If ? IsPartialTemporalObject(temporalYearMonthLike) is false, throw a TypeError
        //    exception.
        if (!try isPartialTemporalObject(agent, temporal_year_month_like)) {
            return agent.throwException(
                .type_error,
                "Argument must be a partial Temporal object",
                .{},
            );
        }

        // 4. Let calendar be plainYearMonth.[[Calendar]].
        const calendar = temporal_rs.c.temporal_rs_Calendar_kind(
            temporal_rs.c.temporal_rs_PlainYearMonth_calendar(plain_year_month.fields.inner),
        );

        // 5. Let fields be ISODateToFields(calendar, plainYearMonth.[[ISODate]], year-month).
        // 6. Let partialYearMonth be ? PrepareCalendarFields(calendar, temporalYearMonthLike,
        //    « year, month, month-code », « », partial).
        // 7. Set fields to CalendarMergeFields(calendar, fields, partialYearMonth).
        const fields = try prepareCalendarFields(
            agent,
            calendar,
            temporal_year_month_like.asObject(),
            .initMany(&.{ .year, .month, .month_code }),
            .partial,
        );
        const partial = fields.date;

        // 8. Let resolvedOptions be ? GetOptionsObject(options).
        const options = try options_value.getOptionsObject(agent);

        // 9. Let overflow be ? GetTemporalOverflowOption(resolvedOptions).
        const overflow = try getTemporalOverflowOption(agent, options);

        // 10. Let isoDate be ? CalendarYearMonthFromFields(calendar, fields, overflow).
        // 11. Return ! CreateTemporalYearMonth(isoDate, calendar).
        const temporal_rs_plain_year_month = try builtins.temporal.extractResult(
            agent,
            temporal_rs.c.temporal_rs_PlainYearMonth_with(
                plain_year_month.fields.inner,
                partial,
                temporal_rs.toArithmeticOverflowOption(overflow),
            ),
        );
        errdefer temporal_rs.c.temporal_rs_PlainYearMonth_destroy(temporal_rs_plain_year_month.?);
        const new_plain_year_month = createTemporalYearMonth(
            agent,
            temporal_rs_plain_year_month.?,
            null,
        ) catch |err| try noexcept(err);
        return Value.from(&new_plain_year_month.object);
    }

    /// 9.3.6 get Temporal.PlainYearMonth.prototype.year
    /// https://tc39.es/proposal-temporal/#sec-get-temporal.plainyearmonth.prototype.year
    fn year(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let plainYearMonth be the this value.
        // 2. Perform ? RequireInternalSlot(plainYearMonth, [[InitializedTemporalYearMonth]]).
        const plain_year_month = try this_value.requireInternalSlot(agent, PlainYearMonth);

        // 3. Return 𝔽(CalendarISOToDate(plainYearMonth.[[Calendar]],
        //    plainYearMonth.[[ISODate]]).[[Year]]).
        return Value.from(
            temporal_rs.c.temporal_rs_PlainYearMonth_year(plain_year_month.fields.inner),
        );
    }
};

/// 9.4 Properties of Temporal.PlainYearMonth Instances
/// https://tc39.es/proposal-temporal/#sec-properties-of-temporal-plainyearmonth-instances
pub const PlainYearMonth = MakeObject(.{
    .Fields = struct {
        inner: *temporal_rs.c.PlainYearMonth,
    },
    .finalizer = struct {
        fn finalizer(object: *Object) void {
            temporal_rs.c.temporal_rs_PlainYearMonth_destroy(object.as(PlainYearMonth).fields.inner);
        }
    }.finalizer,
    .tag = .temporal_plain_year_month,
    .display_name = "Temporal.PlainYearMonth",
});

/// 9.5.2 ToTemporalYearMonth ( item [ , options ] )
/// https://tc39.es/proposal-temporal/#sec-temporal-totemporalyearmonth
pub fn toTemporalPlainYearMonth(
    agent: *Agent,
    item: Value,
    maybe_options_value: ?Value,
) Agent.Error!*PlainYearMonth {
    // 1. If options is not present, set options to undefined.
    const options_value: Value = maybe_options_value orelse .undefined;

    // 2. If item is an Object, then
    const temporal_rs_plain_year_month = if (item.isObject()) blk: {
        // a. If item has an [[InitializedTemporalYearMonth]] internal slot, then
        if (item.asObject().cast(PlainYearMonth)) |plain_year_month| {
            // i. Let resolvedOptions be ? GetOptionsObject(options).
            const options = try options_value.getOptionsObject(agent);

            // ii. Perform ? GetTemporalOverflowOption(resolvedOptions).
            _ = try getTemporalOverflowOption(agent, options);

            // iii. Return ! CreateTemporalYearMonth(item.[[ISODate]], item.[[Calendar]]).
            break :blk temporal_rs.c.temporal_rs_PlainYearMonth_clone(
                plain_year_month.fields.inner,
            );
        }

        // b. Let calendar be ? GetTemporalCalendarIdentifierWithISODefault(item).
        const calendar = try getTemporalCalendarIdentifierWithISODefault(agent, item.asObject());

        // c. Let fields be ? PrepareCalendarFields(calendar, item, « year, month, month-code », «»,
        //    «»).
        const fields = try prepareCalendarFields(
            agent,
            calendar,
            item.asObject(),
            .initMany(&.{ .year, .month, .month_code }),
            .none,
        );
        const partial = fields.date;

        // d. Let resolvedOptions be ? GetOptionsObject(options).
        const options = try options_value.getOptionsObject(agent);

        // e. Let overflow be ? GetTemporalOverflowOption(resolvedOptions).
        const overflow = try getTemporalOverflowOption(agent, options);

        // f. Let isoDate be ? CalendarYearMonthFromFields(calendar, fields, overflow).
        // g. Return ! CreateTemporalYearMonth(isoDate, calendar).
        break :blk try builtins.temporal.extractResult(
            agent,
            temporal_rs.c.temporal_rs_PlainYearMonth_from_partial(
                partial,
                temporal_rs.toArithmeticOverflowOption(overflow),
            ),
        );
    } else blk: {
        // 3. If item is not a String, throw a TypeError exception.
        if (!item.isString()) {
            return agent.throwException(
                .type_error,
                "Plain yearmonth must be a string or object",
                .{},
            );
        }

        // 4. Let result be ? ParseISODateTime(item, « TemporalYearMonthString »).
        // 5. Let calendar be result.[[Calendar]].
        // 6. If calendar is empty, set calendar to "iso8601".
        // 7. Set calendar to ? CanonicalizeCalendar(calendar).
        const parsed_year_month = switch (item.asString().asAsciiOrUtf16()) {
            .ascii => |ascii| try builtins.temporal.extractResult(
                agent,
                temporal_rs.c.temporal_rs_ParsedDate_year_month_from_utf8(
                    temporal_rs.toDiplomatStringView(ascii),
                ),
            ),
            .utf16 => |utf16| try builtins.temporal.extractResult(
                agent,
                temporal_rs.c.temporal_rs_ParsedDate_year_month_from_utf16(
                    temporal_rs.toDiplomatString16View(utf16),
                ),
            ),
        };
        defer temporal_rs.c.temporal_rs_ParsedDate_destroy(parsed_year_month.?);

        // 8. Let resolvedOptions be ? GetOptionsObject(options).
        const options = try options_value.getOptionsObject(agent);

        // 9. Perform ? GetTemporalOverflowOption(resolvedOptions).
        _ = try getTemporalOverflowOption(agent, options);

        // 10. Let isoDate be CreateISODateRecord(result.[[Year]], result.[[Month]],
        //     result.[[Day]]).
        // 11. If ISOYearMonthWithinLimits(isoDate) is false, throw a RangeError exception.
        // 12. Set result to ISODateToFields(calendar, isoDate, year-month).
        // 13. NOTE: The following operation is called with constrain regardless of overflow, in
        //     order for the calendar to store a canonical value in the [[Day]] field of the
        //     [[ISODate]] internal slot of the result.
        // 14. Set isoDate to ? CalendarYearMonthFromFields(calendar, result, constrain).
        // 15. Return ! CreateTemporalYearMonth(isoDate, calendar).
        break :blk try builtins.temporal.extractResult(
            agent,
            temporal_rs.c.temporal_rs_PlainYearMonth_from_parsed(parsed_year_month.?),
        );
    };
    errdefer temporal_rs.c.temporal_rs_PlainYearMonth_destroy(temporal_rs_plain_year_month.?);

    return createTemporalYearMonth(
        agent,
        temporal_rs_plain_year_month.?,
        null,
    ) catch |err| try noexcept(err);
}

/// 9.5.5 CreateTemporalYearMonth ( isoDate, calendar [ , newTarget ] )
/// https://tc39.es/proposal-temporal/#sec-temporal-createtemporalyearmonth
pub fn createTemporalYearMonth(
    agent: *Agent,
    inner: *temporal_rs.c.PlainYearMonth,
    maybe_new_target: ?*Object,
) Agent.Error!*PlainYearMonth {
    const realm = agent.currentRealm();

    // 1. If ISOYearMonthWithinLimits(isoDate) is false, throw a RangeError exception.

    // 2. If newTarget is not present, set newTarget to %Temporal.PlainYearMonth%.
    const new_target = maybe_new_target orelse try realm.intrinsic(.temporal_plain_year_month);

    // 3. Let object be ? OrdinaryCreateFromConstructor(newTarget,
    //    "%Temporal.PlainYearMonth.prototype%", « [[InitializedTemporalYearMonth]], [[ISODate]],
    //    [[Calendar]] »).
    // 4. Set object.[[ISODate]] to isoDate.
    // 5. Set object.[[Calendar]] to calendar.
    // 6. Return object.
    return ordinaryCreateFromConstructor(
        PlainYearMonth,
        agent,
        new_target,
        .temporal_plain_year_month_prototype,
        .{ .inner = inner },
    );
}

/// 9.5.7 DifferenceTemporalPlainYearMonth ( operation, yearMonth, other, options )
/// https://tc39.es/proposal-temporal/#sec-temporal-differencetemporalplainyearmonth
fn differenceTemporalPlainYearMonth(
    agent: *Agent,
    operation: enum { since, until },
    plain_year_month: *const PlainYearMonth,
    other_value: Value,
    options_value: Value,
) Agent.Error!*builtins.temporal.Duration {
    // 1. Set other to ? ToTemporalYearMonth(other).
    const other = try toTemporalPlainYearMonth(agent, other_value, null);

    // 2. Let calendar be yearMonth.[[Calendar]].
    // 3. If CalendarEquals(calendar, other.[[Calendar]]) is false, throw a RangeError exception.
    if (temporal_rs.c.temporal_rs_Calendar_kind(
        temporal_rs.c.temporal_rs_PlainYearMonth_calendar(plain_year_month.fields.inner),
    ) != temporal_rs.c.temporal_rs_Calendar_kind(
        temporal_rs.c.temporal_rs_PlainYearMonth_calendar(other.fields.inner),
    )) {
        return agent.throwException(
            .range_error,
            "Difference requires equal calendars",
            .{},
        );
    }

    // 4. Let resolvedOptions be ? GetOptionsObject(options).
    const options = try options_value.getOptionsObject(agent);

    // 5. Let settings be ? GetDifferenceSettings(operation, resolvedOptions, date, « week, day »,
    //    month, year).
    const settings = try getTemporalDifferenceSettingsWithoutValidation(agent, options);

    // 6. If CompareISODate(yearMonth.[[ISODate]], other.[[ISODate]]) = 0, return
    //    ! CreateTemporalDuration(0, 0, 0, 0, 0, 0, 0, 0, 0, 0).
    // 7. Let thisFields be ISODateToFields(calendar, yearMonth.[[ISODate]], year-month).
    // 8. Set thisFields.[[Day]] to 1.
    // 9. Let thisDate be ? CalendarDateFromFields(calendar, thisFields, constrain).
    // 10. Let otherFields be ISODateToFields(calendar, other.[[ISODate]], year-month).
    // 11. Set otherFields.[[Day]] to 1.
    // 12. Let otherDate be ? CalendarDateFromFields(calendar, otherFields, constrain).
    // 13. Let dateDifference be CalendarDateUntil(calendar, thisDate, otherDate,
    //     settings.[[LargestUnit]]).
    // 14. Let yearsMonthsDifference be ! AdjustDateDurationRecord(dateDifference, 0, 0).
    // 15. Let duration be CombineDateAndTimeDuration(yearsMonthsDifference, 0).
    // 16. If settings.[[SmallestUnit]] is not month or settings.[[RoundingIncrement]] ≠ 1, then
    //     a. Let isoDateTime be CombineISODateAndTimeRecord(thisDate, MidnightTimeRecord()).
    //     b. Let originEpochNs be GetUTCEpochNanoseconds(isoDateTime).
    //     c. Let isoDateTimeOther be CombineISODateAndTimeRecord(otherDate, MidnightTimeRecord()).
    //     d. Let destEpochNs be GetUTCEpochNanoseconds(isoDateTimeOther).
    //     e. Set duration to ? RoundRelativeDuration(duration, originEpochNs, destEpochNs,
    //        isoDateTime, unset, calendar, settings.[[LargestUnit]],
    //        settings.[[RoundingIncrement]], settings.[[SmallestUnit]], settings.[[RoundingMode]]).
    // 17. Let result be ! TemporalDurationFromInternal(duration, day).
    // 18. If operation is since, set result to CreateNegatedTemporalDuration(result).
    // 19. Return result.
    const temporal_rs_duration = switch (operation) {
        .since => try builtins.temporal.extractResult(
            agent,
            temporal_rs.c.temporal_rs_PlainYearMonth_since(
                plain_year_month.fields.inner,
                other.fields.inner,
                settings,
            ),
        ),
        .until => try builtins.temporal.extractResult(
            agent,
            temporal_rs.c.temporal_rs_PlainYearMonth_until(
                plain_year_month.fields.inner,
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

/// 9.5.8 AddDurationToYearMonth ( operation, yearMonth, temporalDurationLike, options )
/// https://tc39.es/proposal-temporal/#sec-temporal-adddurationtoyearmonth
fn addDurationToYearMonth(
    agent: *Agent,
    operation: enum { add, subtract },
    plain_year_month: *const PlainYearMonth,
    temporal_duration_like: Value,
    options_value: Value,
) Agent.Error!*PlainYearMonth {
    // 1. Let duration be ? ToTemporalDuration(temporalDurationLike).
    const duration = try toTemporalDuration(agent, temporal_duration_like);

    // 2. If operation is subtract, set duration to CreateNegatedTemporalDuration(duration).
    // 3. Let internalDuration be ToInternalDurationRecord(duration).

    // 4. Let resolvedOptions be ? GetOptionsObject(options).
    const options = try options_value.getOptionsObject(agent);

    // 5. Let overflow be ? GetTemporalOverflowOption(resolvedOptions).
    const overflow = try getTemporalOverflowOption(agent, options);

    // 6. Let durationToAdd be internalDuration.[[Date]].
    // 7. If durationToAdd.[[Weeks]] ≠ 0, or durationToAdd.[[Days]] ≠ 0, or
    //    internalDuration.[[Time]] ≠ 0, throw a RangeError exception.
    // 8. Let calendar be yearMonth.[[Calendar]].
    // 9. Let fields be ISODateToFields(calendar, yearMonth.[[ISODate]], year-month).
    // 10. Set fields.[[Day]] to 1.
    // 11. Let date be ? CalendarDateFromFields(calendar, fields, constrain).
    // 12. Let addedDate be ? CalendarDateAdd(calendar, date, durationToAdd, overflow).
    // 13. Let addedDateFields be ISODateToFields(calendar, addedDate, year-month).
    // 14. Let isoDate be ? CalendarYearMonthFromFields(calendar, addedDateFields, overflow).
    // 15. Return ! CreateTemporalYearMonth(isoDate, calendar).
    const temporal_rs_plain_year_month = switch (operation) {
        .add => try builtins.temporal.extractResult(
            agent,
            temporal_rs.c.temporal_rs_PlainYearMonth_add(
                plain_year_month.fields.inner,
                duration.fields.inner,
                overflow,
            ),
        ),
        .subtract => try builtins.temporal.extractResult(
            agent,
            temporal_rs.c.temporal_rs_PlainYearMonth_subtract(
                plain_year_month.fields.inner,
                duration.fields.inner,
                overflow,
            ),
        ),
    };
    errdefer temporal_rs.c.temporal_rs_PlainYearMonth_destroy(temporal_rs_plain_year_month.?);
    return createTemporalYearMonth(
        agent,
        temporal_rs_plain_year_month.?,
        null,
    ) catch |err| try noexcept(err);
}
