//! 7 Temporal.Duration Objects
//! https://tc39.es/proposal-temporal/#sec-temporal-duration-objects

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
const createBuiltinFunction = builtins.createBuiltinFunction;
const getTemporalFractionalSecondDigitsOption = builtins.getTemporalFractionalSecondDigitsOption;
const getTemporalRelativeToOption = builtins.getTemporalRelativeToOption;
const getTemporalRoundingIncrementOption = builtins.getTemporalRoundingIncrementOption;
const getTemporalRoundingModeOption = builtins.getTemporalRoundingModeOption;
const getTemporalUnitValuedOption = builtins.getTemporalUnitValuedOption;
const noexcept = utils.noexcept;
const ordinaryCreateFromConstructor = builtins.ordinaryCreateFromConstructor;
const ordinaryObjectCreate = builtins.ordinaryObjectCreate;
const validateTemporalUnitValue = builtins.validateTemporalUnitValue;

/// 7.2 Properties of the Temporal.Duration Constructor
/// https://tc39.es/proposal-temporal/#sec-properties-of-the-temporal-duration-constructor
pub const constructor = struct {
    pub fn create(agent: *Agent, realm: *Realm) std.mem.Allocator.Error!*Object {
        const builtin_function = try createBuiltinFunction(
            agent,
            .{ .constructor = impl },
            0,
            "Duration",
            .{ .realm = realm, .proto = try realm.intrinsic(.function_prototype) },
        );
        return &builtin_function.object;
    }

    pub fn init(agent: *Agent, realm: *Realm, object: *Object) std.mem.Allocator.Error!void {
        try object.defineBuiltinFunction(agent, "compare", compare, 2, realm);
        try object.defineBuiltinFunction(agent, "from", from, 1, realm);

        // 7.2.1 Temporal.Duration.prototype
        // https://tc39.es/proposal-temporal/#sec-temporal.duration.prototype
        try object.defineBuiltinPropertyWithAttributes(
            agent,
            "prototype",
            Value.from(try realm.intrinsic(.temporal_duration_prototype)),
            .{
                .writable = false,
                .enumerable = false,
                .configurable = false,
            },
        );
    }

    /// 7.1.1 Temporal.Duration ( [ years [ , months [ , weeks [ , days [ , hours [ , minutes [ , seconds [ , milliseconds [ , microseconds [ , nanoseconds ] ] ] ] ] ] ] ] ] ] )
    /// https://tc39.es/proposal-temporal/#sec-temporal.duration
    fn impl(agent: *Agent, arguments: Arguments, maybe_new_target: ?*Object) Agent.Error!Value {
        const years_value = arguments.get(0);
        const months_value = arguments.get(1);
        const weeks_value = arguments.get(2);
        const days_value = arguments.get(3);
        const hours_value = arguments.get(4);
        const minutes_value = arguments.get(5);
        const seconds_value = arguments.get(6);
        const milliseconds_value = arguments.get(7);
        const microseconds_value = arguments.get(8);
        const nanoseconds_value = arguments.get(9);

        // 1. If NewTarget is undefined, throw a TypeError exception.
        const new_target = maybe_new_target orelse {
            return agent.throwException(
                .type_error,
                "Temporal.Duration must be constructed with 'new'",
                .{},
            );
        };

        // 2. If years is undefined, let y be 0; else let y be ? ToIntegerIfIntegral(years).
        const years = if (years_value.isUndefined()) 0 else try years_value.toIntegerIfIntegral(agent);

        // 3. If months is undefined, let mo be 0; else let mo be ? ToIntegerIfIntegral(months).
        const months = if (months_value.isUndefined()) 0 else try months_value.toIntegerIfIntegral(agent);

        // 4. If weeks is undefined, let w be 0; else let w be ? ToIntegerIfIntegral(weeks).
        const weeks = if (weeks_value.isUndefined()) 0 else try weeks_value.toIntegerIfIntegral(agent);

        // 5. If days is undefined, let d be 0; else let d be ? ToIntegerIfIntegral(days).
        const days = if (days_value.isUndefined()) 0 else try days_value.toIntegerIfIntegral(agent);

        // 6. If hours is undefined, let h be 0; else let h be ? ToIntegerIfIntegral(hours).
        const hours = if (hours_value.isUndefined()) 0 else try hours_value.toIntegerIfIntegral(agent);

        // 7. If minutes is undefined, let m be 0; else let m be ? ToIntegerIfIntegral(minutes).
        const minutes = if (minutes_value.isUndefined()) 0 else try minutes_value.toIntegerIfIntegral(agent);

        // 8. If seconds is undefined, let s be 0; else let s be ? ToIntegerIfIntegral(seconds).
        const seconds = if (seconds_value.isUndefined()) 0 else try seconds_value.toIntegerIfIntegral(agent);

        // 9. If milliseconds is undefined, let ms be 0; else let ms be ? ToIntegerIfIntegral(
        //    milliseconds).
        const milliseconds = if (milliseconds_value.isUndefined()) 0 else try milliseconds_value.toIntegerIfIntegral(agent);

        // 10. If microseconds is undefined, let mis be 0; else let mis be ? ToIntegerIfIntegral(
        //     microseconds).
        const microseconds = if (microseconds_value.isUndefined()) 0 else try microseconds_value.toIntegerIfIntegral(agent);

        // 11. If nanoseconds is undefined, let ns be 0; else let ns be ? ToIntegerIfIntegral(
        //     nanoseconds).
        const nanoseconds = if (nanoseconds_value.isUndefined()) 0 else try nanoseconds_value.toIntegerIfIntegral(agent);

        // 12. Return ? CreateTemporalDuration(y, mo, w, d, h, m, s, ms, mis, ns, NewTarget).
        const temporal_rs_duration = try builtins.temporal.extractResult(
            agent,
            temporal_rs.c.temporal_rs_Duration_try_new(
                std.math.lossyCast(i64, years),
                std.math.lossyCast(i64, months),
                std.math.lossyCast(i64, weeks),
                std.math.lossyCast(i64, days),
                std.math.lossyCast(i64, hours),
                std.math.lossyCast(i64, minutes),
                std.math.lossyCast(i64, seconds),
                std.math.lossyCast(i64, milliseconds),
                microseconds,
                nanoseconds,
            ),
        );
        errdefer temporal_rs.c.temporal_rs_Duration_destroy(temporal_rs_duration.?);
        const duration = try createTemporalDuration(agent, temporal_rs_duration.?, new_target);
        return Value.from(&duration.object);
    }

    /// 7.2.3 Temporal.Duration.compare ( one, two [ , options ] )
    /// https://tc39.es/proposal-temporal/#sec-temporal.duration.compare
    fn compare(agent: *Agent, _: Value, arguments: Arguments) Agent.Error!Value {
        const one_value = arguments.get(0);
        const two_value = arguments.get(1);
        const options_value = arguments.get(2);

        // 1. Set one to ? ToTemporalDuration(one).
        const one = try toTemporalDuration(agent, one_value);

        // 2. Set two to ? ToTemporalDuration(two).
        const two = try toTemporalDuration(agent, two_value);

        // 3. Let resolvedOptions be ? GetOptionsObject(options).
        const options = try options_value.getOptionsObject(agent);

        // 4. Let relativeToRecord be ? GetTemporalRelativeToOption(resolvedOptions).
        const relative_to = try getTemporalRelativeToOption(agent, options);
        defer relative_to.deinit();

        // 5. If one.[[Years]] = two.[[Years]], and one.[[Months]] = two.[[Months]], and
        //    one.[[Weeks]] = two.[[Weeks]], and one.[[Days]] = two.[[Days]], and
        //    one.[[Hours]] = two.[[Hours]], and one.[[Minutes]] = two.[[Minutes]], and
        //    one.[[Seconds]] = two.[[Seconds]], and one.[[Milliseconds]] = two.[[Milliseconds]],
        //    and one.[[Microseconds]] = two.[[Microseconds]], and
        //    one.[[Nanoseconds]] = two.[[Nanoseconds]], then
        //     a. Return +0𝔽.
        // 6. Let zonedRelativeTo be relativeToRecord.[[ZonedRelativeTo]].
        // 7. Let plainRelativeTo be relativeToRecord.[[PlainRelativeTo]].
        // 8. Let largestUnit1 be DefaultTemporalLargestUnit(one).
        // 9. Let largestUnit2 be DefaultTemporalLargestUnit(two).
        // 10. Let duration1 be ToInternalDurationRecord(one).
        // 11. Let duration2 be ToInternalDurationRecord(two).
        // 12. If zonedRelativeTo is not undefined, and TemporalUnitCategory(largestUnit1) is date
        //     or TemporalUnitCategory(largestUnit2) is date, then
        //     a. Let timeZone be zonedRelativeTo.[[TimeZone]].
        //     b. Let calendar be zonedRelativeTo.[[Calendar]].
        //     c. Let after1 be ? AddZonedDateTime(zonedRelativeTo.[[EpochNanoseconds]], timeZone,
        //        calendar, duration1, constrain).
        //     d. Let after2 be ? AddZonedDateTime(zonedRelativeTo.[[EpochNanoseconds]], timeZone,
        //        calendar, duration2, constrain).
        //     e. If after1 > after2, return 1𝔽.
        //     f. If after1 < after2, return -1𝔽.
        //     g. Return +0𝔽.
        // 13. If IsCalendarUnit(largestUnit1) is true or IsCalendarUnit(largestUnit2) is true, then
        //     a. If plainRelativeTo is undefined, throw a RangeError exception.
        //     b. Let days1 be ? DateDurationDays(duration1.[[Date]], plainRelativeTo).
        //     c. Let days2 be ? DateDurationDays(duration2.[[Date]], plainRelativeTo).
        // 14. Else,
        //     a. Let days1 be one.[[Days]].
        //     b. Let days2 be two.[[Days]].
        // 15. Let timeDuration1 be ? Add24HourDaysToTimeDuration(duration1.[[Time]], days1).
        // 16. Let timeDuration2 be ? Add24HourDaysToTimeDuration(duration2.[[Time]], days2).
        // 17. Return 𝔽(CompareTimeDuration(timeDuration1, timeDuration2)).
        const result = try builtins.temporal.extractResult(
            agent,
            temporal_rs.c.temporal_rs_Duration_compare(
                one.fields.inner,
                two.fields.inner,
                relative_to.toRust(),
            ),
        );
        return Value.from(result);
    }

    /// 7.2.2 Temporal.Duration.from ( item )
    /// https://tc39.es/proposal-temporal/#sec-temporal.duration.from
    fn from(agent: *Agent, _: Value, arguments: Arguments) Agent.Error!Value {
        const item = arguments.get(0);

        // 1. Return ? ToTemporalDuration(item).
        const duration = try toTemporalDuration(agent, item);
        return Value.from(&duration.object);
    }
};

/// 7.3 Properties of the Temporal.Duration Prototype Object
/// https://tc39.es/proposal-temporal/#sec-properties-of-the-temporal-duration-prototype-object
pub const prototype = struct {
    pub fn create(agent: *Agent, realm: *Realm) std.mem.Allocator.Error!*Object {
        return ordinaryObjectCreate(agent, try realm.intrinsic(.object_prototype));
    }

    pub fn init(agent: *Agent, realm: *Realm, object: *Object) std.mem.Allocator.Error!void {
        try object.defineBuiltinFunction(agent, "abs", abs, 0, realm);
        try object.defineBuiltinFunction(agent, "add", add, 1, realm);
        try object.defineBuiltinAccessor(agent, "blank", blank, null, realm);
        try object.defineBuiltinAccessor(agent, "days", days, null, realm);
        try object.defineBuiltinAccessor(agent, "hours", hours, null, realm);
        try object.defineBuiltinAccessor(agent, "microseconds", microseconds, null, realm);
        try object.defineBuiltinAccessor(agent, "milliseconds", milliseconds, null, realm);
        try object.defineBuiltinAccessor(agent, "minutes", minutes, null, realm);
        try object.defineBuiltinAccessor(agent, "months", months, null, realm);
        try object.defineBuiltinAccessor(agent, "nanoseconds", nanoseconds, null, realm);
        try object.defineBuiltinFunction(agent, "negated", negated, 0, realm);
        try object.defineBuiltinFunction(agent, "round", round, 1, realm);
        try object.defineBuiltinAccessor(agent, "seconds", seconds, null, realm);
        try object.defineBuiltinAccessor(agent, "sign", sign, null, realm);
        try object.defineBuiltinFunction(agent, "subtract", subtract, 1, realm);
        try object.defineBuiltinFunction(agent, "toJSON", toJSON, 0, realm);
        try object.defineBuiltinFunction(agent, "toLocaleString", toLocaleString, 0, realm);
        try object.defineBuiltinFunction(agent, "toString", toString, 0, realm);
        try object.defineBuiltinFunction(agent, "total", total, 1, realm);
        try object.defineBuiltinFunction(agent, "valueOf", valueOf, 0, realm);
        try object.defineBuiltinAccessor(agent, "weeks", weeks, null, realm);
        try object.defineBuiltinFunction(agent, "with", with, 1, realm);
        try object.defineBuiltinAccessor(agent, "years", years, null, realm);

        // 7.3.1 Temporal.Duration.prototype.constructor
        // https://tc39.es/proposal-temporal/#sec-temporal.duration.prototype.constructor
        try object.defineBuiltinProperty(
            agent,
            "constructor",
            Value.from(try realm.intrinsic(.temporal_duration)),
        );

        // 7.3.2 Temporal.Duration.prototype[ %Symbol.toStringTag% ]
        // https://tc39.es/proposal-temporal/#sec-temporal.duration.prototype-%symbol.tostringtag%
        try object.defineBuiltinPropertyWithAttributes(
            agent,
            "Symbol.toStringTag",
            Value.from("Temporal.Duration"),
            .{
                .writable = false,
                .enumerable = false,
                .configurable = true,
            },
        );
    }

    /// 7.3.17 Temporal.Duration.prototype.abs ( )
    /// https://tc39.es/proposal-temporal/#sec-temporal.duration.prototype.abs
    fn abs(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let duration be the this value.
        // 2. Perform ? RequireInternalSlot(duration, [[InitializedTemporalDuration]]).
        const duration = try this_value.requireInternalSlot(agent, Duration);

        // 3. Return ! CreateTemporalDuration(abs(duration.[[Years]]), abs(duration.[[Months]]),
        //    abs(duration.[[Weeks]]), abs(duration.[[Days]]), abs(duration.[[Hours]]), abs(
        //    duration.[[Minutes]]), abs(duration.[[Seconds]]), abs(duration.[[Milliseconds]]), abs(
        //    duration.[[Microseconds]]), abs(duration.[[Nanoseconds]])).
        const temporal_rs_duration = temporal_rs.c.temporal_rs_Duration_abs(duration.fields.inner);
        errdefer temporal_rs.c.temporal_rs_Duration_destroy(temporal_rs_duration);
        const new_duration = createTemporalDuration(
            agent,
            temporal_rs_duration.?,
            null,
        ) catch |err| try noexcept(err);
        return Value.from(&new_duration.object);
    }

    /// 7.3.18 Temporal.Duration.prototype.add ( other )
    /// https://tc39.es/proposal-temporal/#sec-temporal.duration.prototype.add
    fn add(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const other = arguments.get(0);

        // 1. Let duration be the this value.
        // 2. Perform ? RequireInternalSlot(duration, [[InitializedTemporalDuration]]).
        const duration = try this_value.requireInternalSlot(agent, Duration);

        // 3. Return ? AddDurations(add, duration, other).
        const new_duration = try addDurations(agent, .add, duration, other);
        return Value.from(&new_duration.object);
    }

    /// 7.3.14 get Temporal.Duration.prototype.blank
    /// https://tc39.es/proposal-temporal/#sec-get-temporal.duration.prototype.blank
    fn blank(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let duration be the this value.
        // 2. Perform ? RequireInternalSlot(duration, [[InitializedTemporalDuration]]).
        const duration = try this_value.requireInternalSlot(agent, Duration);

        // 3. If DurationSign(duration) = 0, return true.
        // 4. Return false.
        return Value.from(temporal_rs.c.temporal_rs_Duration_is_zero(duration.fields.inner));
    }

    /// 7.3.6 get Temporal.Duration.prototype.days
    /// https://tc39.es/proposal-temporal/#sec-get-temporal.duration.prototype.days
    fn days(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let duration be the this value.
        // 2. Perform ? RequireInternalSlot(duration, [[InitializedTemporalDuration]]).
        const duration = try this_value.requireInternalSlot(agent, Duration);

        // 3. Return 𝔽(duration.[[Days]]).
        return Value.from(
            @as(f64, @floatFromInt(temporal_rs.c.temporal_rs_Duration_days(duration.fields.inner))),
        );
    }

    /// 7.3.7 get Temporal.Duration.prototype.hours
    /// https://tc39.es/proposal-temporal/#sec-get-temporal.duration.prototype.hours
    fn hours(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let duration be the this value.
        // 2. Perform ? RequireInternalSlot(duration, [[InitializedTemporalDuration]]).
        const duration = try this_value.requireInternalSlot(agent, Duration);

        // 3. Return 𝔽(duration.[[Hours]]).
        return Value.from(
            @as(f64, @floatFromInt(temporal_rs.c.temporal_rs_Duration_hours(duration.fields.inner))),
        );
    }

    /// 7.3.11 get Temporal.Duration.prototype.microseconds
    /// https://tc39.es/proposal-temporal/#sec-get-temporal.duration.prototype.microseconds
    fn microseconds(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let duration be the this value.
        // 2. Perform ? RequireInternalSlot(duration, [[InitializedTemporalDuration]]).
        const duration = try this_value.requireInternalSlot(agent, Duration);

        // 3. Return 𝔽(duration.[[Microseconds]]).
        return Value.from(temporal_rs.c.temporal_rs_Duration_microseconds(duration.fields.inner));
    }

    /// 7.3.10 get Temporal.Duration.prototype.milliseconds
    /// https://tc39.es/proposal-temporal/#sec-get-temporal.duration.prototype.milliseconds
    fn milliseconds(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let duration be the this value.
        // 2. Perform ? RequireInternalSlot(duration, [[InitializedTemporalDuration]]).
        const duration = try this_value.requireInternalSlot(agent, Duration);

        // 3. Return 𝔽(duration.[[Milliseconds]]).
        return Value.from(
            @as(f64, @floatFromInt(temporal_rs.c.temporal_rs_Duration_milliseconds(duration.fields.inner))),
        );
    }

    /// 7.3.8 get Temporal.Duration.prototype.minutes
    /// https://tc39.es/proposal-temporal/#sec-get-temporal.duration.prototype.minutes
    fn minutes(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let duration be the this value.
        // 2. Perform ? RequireInternalSlot(duration, [[InitializedTemporalDuration]]).
        const duration = try this_value.requireInternalSlot(agent, Duration);

        // 3. Return 𝔽(duration.[[Minutes]]).
        return Value.from(
            @as(f64, @floatFromInt(temporal_rs.c.temporal_rs_Duration_minutes(duration.fields.inner))),
        );
    }

    /// 7.3.4 get Temporal.Duration.prototype.months
    /// https://tc39.es/proposal-temporal/#sec-get-temporal.duration.prototype.months
    fn months(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let duration be the this value.
        // 2. Perform ? RequireInternalSlot(duration, [[InitializedTemporalDuration]]).
        const duration = try this_value.requireInternalSlot(agent, Duration);

        // 3. Return 𝔽(duration.[[Months]]).
        return Value.from(
            @as(f64, @floatFromInt(temporal_rs.c.temporal_rs_Duration_months(duration.fields.inner))),
        );
    }

    /// 7.3.12 get Temporal.Duration.prototype.nanoseconds
    /// https://tc39.es/proposal-temporal/#sec-get-temporal.duration.prototype.nanoseconds
    fn nanoseconds(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let duration be the this value.
        // 2. Perform ? RequireInternalSlot(duration, [[InitializedTemporalDuration]]).
        const duration = try this_value.requireInternalSlot(agent, Duration);

        // 3. Return 𝔽(duration.[[Nanoseconds]]).
        return Value.from(temporal_rs.c.temporal_rs_Duration_nanoseconds(duration.fields.inner));
    }

    /// 7.3.20 Temporal.Duration.prototype.round ( roundTo )
    /// https://tc39.es/proposal-temporal/#sec-temporal.duration.prototype.round
    fn round(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const round_to = arguments.get(0);

        // 1. Let duration be the this value.
        // 2. Perform ? RequireInternalSlot(duration, [[InitializedTemporalDuration]]).
        const duration = try this_value.requireInternalSlot(agent, Duration);

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

        // 6. Let smallestUnitPresent be true.
        // 7. Let largestUnitPresent be true.
        // 8. NOTE: The following steps read options and perform independent validation in
        //    alphabetical order (GetTemporalRelativeToOption reads "relativeTo",
        //    GetRoundingIncrementOption reads "roundingIncrement" and GetRoundingModeOption reads
        //    "roundingMode").

        // 9. Let largestUnit be ? GetTemporalUnitValuedOption(roundTo, "largestUnit", unset).
        const largest_unit = try getTemporalUnitValuedOption(
            agent,
            options,
            "largestUnit",
            .unset,
        );

        // 10. Let relativeToRecord be ? GetTemporalRelativeToOption(roundTo).
        const relative_to = try getTemporalRelativeToOption(agent, options);
        defer relative_to.deinit();

        // 11. Let zonedRelativeTo be relativeToRecord.[[ZonedRelativeTo]].
        // 12. Let plainRelativeTo be relativeToRecord.[[PlainRelativeTo]].

        // 13. Let roundingIncrement be ? GetRoundingIncrementOption(roundTo).
        const rounding_increment = try getTemporalRoundingIncrementOption(agent, options);

        // 14. Let roundingMode be ? GetRoundingModeOption(roundTo, half-expand).
        const rounding_mode = try getTemporalRoundingModeOption(
            agent,
            options,
            temporal_rs.c.RoundingMode_HalfExpand,
        );

        // 15. Let smallestUnit be ? GetTemporalUnitValuedOption(roundTo, "smallestUnit", unset).
        const smallest_unit = try getTemporalUnitValuedOption(
            agent,
            options,
            "smallestUnit",
            .unset,
        );

        // 16. Perform ? ValidateTemporalUnitValue(smallestUnit, datetime).
        try validateTemporalUnitValue(agent, smallest_unit, "smallestUnit", .datetime, &.{});

        // 17. If smallestUnit is unset, then
        //     a. Set smallestUnitPresent to false.
        //     b. Set smallestUnit to nanosecond.
        // 18. Let existingLargestUnit be DefaultTemporalLargestUnit(duration).
        // 19. Let defaultLargestUnit be LargerOfTwoTemporalUnits(existingLargestUnit,
        //     smallestUnit).
        // 20. If largestUnit is unset, then
        //     a. Set largestUnitPresent to false.
        //     b. Set largestUnit to defaultLargestUnit.
        // 21. Else if largestUnit is auto, then
        //     a. Set largestUnit to defaultLargestUnit.
        // 22. If smallestUnitPresent is false and largestUnitPresent is false, throw a RangeError
        //     exception.
        // 23. If LargerOfTwoTemporalUnits(largestUnit, smallestUnit) is not largestUnit, throw a
        //     RangeError exception.
        // 24. Let maximum be MaximumTemporalDurationRoundingIncrement(smallestUnit).
        // 25. If maximum is not unset, perform ? ValidateTemporalRoundingIncrement(
        //     roundingIncrement, maximum, false).
        // 26. If roundingIncrement > 1, and largestUnit is not smallestUnit, and
        //     TemporalUnitCategory(smallestUnit) is date, throw a RangeError exception.
        // 27. If zonedRelativeTo is not undefined, then
        //     a. Let internalDuration be ToInternalDurationRecord(duration).
        //     b. Let timeZone be zonedRelativeTo.[[TimeZone]].
        //     c. Let calendar be zonedRelativeTo.[[Calendar]].
        //     d. Let relativeEpochNs be zonedRelativeTo.[[EpochNanoseconds]].
        //     e. Let targetEpochNs be ? AddZonedDateTime(relativeEpochNs, timeZone, calendar,
        //        internalDuration, constrain).
        //     f. Set internalDuration to ? DifferenceZonedDateTimeWithRounding(relativeEpochNs,
        //        targetEpochNs, timeZone, calendar, largestUnit, roundingIncrement, smallestUnit,
        //        roundingMode).
        //     g. If TemporalUnitCategory(largestUnit) is date, set largestUnit to hour.
        //     h. Return ? TemporalDurationFromInternal(internalDuration, largestUnit).
        // 28. If plainRelativeTo is not undefined, then
        //     a. Let internalDuration be ToInternalDurationRecordWith24HourDays(duration).
        //     b. Let targetTime be AddTime(MidnightTimeRecord(), internalDuration.[[Time]]).
        //     c. Let calendar be plainRelativeTo.[[Calendar]].
        //     d. Let dateDuration be ! AdjustDateDurationRecord(internalDuration.[[Date]],
        //        targetTime.[[Days]]).
        //     e. Let targetDate be ? CalendarDateAdd(calendar, plainRelativeTo.[[ISODate]],
        //        dateDuration, constrain).
        //     f. Let isoDateTime be CombineISODateAndTimeRecord(plainRelativeTo.[[ISODate]],
        //        MidnightTimeRecord()).
        //     g. Let targetDateTime be CombineISODateAndTimeRecord(targetDate, targetTime).
        //     h. Set internalDuration to ? DifferencePlainDateTimeWithRounding(isoDateTime,
        //        targetDateTime, calendar, largestUnit, roundingIncrement, smallestUnit,
        //        roundingMode).
        //     i. Return ? TemporalDurationFromInternal(internalDuration, largestUnit).
        // 29. If IsCalendarUnit(existingLargestUnit) is true or IsCalendarUnit(largestUnit) is
        //     true, throw a RangeError exception.
        // 30. Assert: IsCalendarUnit(smallestUnit) is false.
        // 31. Let internalDuration be ToInternalDurationRecordWith24HourDays(duration).
        // 32. If smallestUnit is day, then
        //     a. Let fractionalDays be TotalTimeDuration(internalDuration.[[Time]], day).
        //     b. Let days be RoundNumberToIncrement(fractionalDays, roundingIncrement,
        //        roundingMode).
        //     c. Let dateDuration be ? CreateDateDurationRecord(0, 0, 0, days).
        //     d. Set internalDuration to CombineDateAndTimeDuration(dateDuration, 0).
        // 33. Else,
        //     a. Let timeDuration be ? RoundTimeDuration(internalDuration.[[Time]],
        //        roundingIncrement, smallestUnit, roundingMode).
        //     b. Set internalDuration to CombineDateAndTimeDuration(ZeroDateDuration(),
        //        timeDuration).
        // 34. Return ? TemporalDurationFromInternal(internalDuration, largestUnit).
        const temporal_rs_duration = try builtins.temporal.extractResult(
            agent,
            temporal_rs.c.temporal_rs_Duration_round(
                duration.fields.inner,
                .{
                    .largest_unit = temporal_rs.toUnitOption(largest_unit),
                    .smallest_unit = temporal_rs.toUnitOption(smallest_unit),
                    .rounding_mode = temporal_rs.toRoundingModeOption(rounding_mode),
                    .increment = temporal_rs.toOption(temporal_rs.c.OptionU32, rounding_increment),
                },
                relative_to.toRust(),
            ),
        );
        errdefer temporal_rs.c.temporal_rs_Duration_destroy(temporal_rs_duration.?);
        const new_duration = createTemporalDuration(
            agent,
            temporal_rs_duration.?,
            null,
        ) catch |err| try noexcept(err);
        return Value.from(&new_duration.object);
    }

    /// 7.3.16 Temporal.Duration.prototype.negated ( )
    /// https://tc39.es/proposal-temporal/#sec-temporal.duration.prototype.negated
    fn negated(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let duration be the this value.
        // 2. Perform ? RequireInternalSlot(duration, [[InitializedTemporalDuration]]).
        const duration = try this_value.requireInternalSlot(agent, Duration);

        // 3. Return CreateNegatedTemporalDuration(duration).
        const temporal_rs_duration = temporal_rs.c.temporal_rs_Duration_negated(duration.fields.inner);
        errdefer temporal_rs.c.temporal_rs_Duration_destroy(temporal_rs_duration.?);
        const new_duration = createTemporalDuration(
            agent,
            temporal_rs_duration.?,
            null,
        ) catch |err| try noexcept(err);
        return Value.from(&new_duration.object);
    }

    /// 7.3.9 get Temporal.Duration.prototype.seconds
    /// https://tc39.es/proposal-temporal/#sec-get-temporal.duration.prototype.seconds
    fn seconds(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let duration be the this value.
        // 2. Perform ? RequireInternalSlot(duration, [[InitializedTemporalDuration]]).
        const duration = try this_value.requireInternalSlot(agent, Duration);

        // 3. Return 𝔽(duration.[[Seconds]]).
        return Value.from(
            @as(f64, @floatFromInt(temporal_rs.c.temporal_rs_Duration_seconds(duration.fields.inner))),
        );
    }

    /// 7.3.13 get Temporal.Duration.prototype.sign
    /// https://tc39.es/proposal-temporal/#sec-get-temporal.duration.prototype.sign
    fn sign(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let duration be the this value.
        // 2. Perform ? RequireInternalSlot(duration, [[InitializedTemporalDuration]]).
        const duration = try this_value.requireInternalSlot(agent, Duration);

        // 3. Return 𝔽(DurationSign(duration)).
        return Value.from(temporal_rs.c.temporal_rs_Duration_sign(duration.fields.inner));
    }

    /// 7.3.19 Temporal.Duration.prototype.subtract ( other )
    /// https://tc39.es/proposal-temporal/#sec-temporal.duration.prototype.subtract
    fn subtract(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const other = arguments.get(0);

        // 1. Let duration be the this value.
        // 2. Perform ? RequireInternalSlot(duration, [[InitializedTemporalDuration]]).
        const duration = try this_value.requireInternalSlot(agent, Duration);

        // 3. Return ? AddDurations(subtract, duration, other).
        const new_duration = try addDurations(
            agent,
            .subtract,
            duration,
            other,
        );
        return Value.from(&new_duration.object);
    }

    /// 7.3.23 Temporal.Duration.prototype.toJSON ( )
    /// https://tc39.es/proposal-temporal/#sec-temporal.duration.prototype.tojson
    fn toJSON(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let duration be the this value.
        // 2. Perform ? RequireInternalSlot(duration, [[InitializedTemporalDuration]]).
        const duration = try this_value.requireInternalSlot(agent, Duration);

        // 3. Return TemporalDurationToString(duration, auto).
        var write = temporal_rs.DiplomatWrite.init(agent.gc_allocator);
        try builtins.temporal.extractResult(
            agent,
            temporal_rs.c.temporal_rs_Duration_to_string(
                duration.fields.inner,
                temporal_rs.to_string_rounding_options_auto,
                &write.inner,
            ),
        );
        return Value.from(try String.fromAscii(agent, try write.toOwnedSlice()));
    }

    /// 7.3.24 Temporal.Duration.prototype.toLocaleString ( [ locales [ , options ] ] )
    /// https://tc39.es/proposal-temporal/#sec-temporal.duration.prototype.tolocalestring
    fn toLocaleString(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let duration be the this value.
        // 2. Perform ? RequireInternalSlot(duration, [[InitializedTemporalDuration]]).
        const duration = try this_value.requireInternalSlot(agent, Duration);

        // 3. Return TemporalDurationToString(duration, auto).
        var write = temporal_rs.DiplomatWrite.init(agent.gc_allocator);
        try builtins.temporal.extractResult(
            agent,
            temporal_rs.c.temporal_rs_Duration_to_string(
                duration.fields.inner,
                temporal_rs.to_string_rounding_options_auto,
                &write.inner,
            ),
        );
        return Value.from(try String.fromAscii(agent, try write.toOwnedSlice()));
    }

    /// 7.3.22 Temporal.Duration.prototype.toString ( [ options ] )
    /// https://tc39.es/proposal-temporal/#sec-temporal.duration.prototype.tostring
    fn toString(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const options_value = arguments.get(0);

        // 1. Let duration be the this value.
        // 2. Perform ? RequireInternalSlot(duration, [[InitializedTemporalDuration]]).
        const duration = try this_value.requireInternalSlot(agent, Duration);

        // 3. Let resolvedOptions be ? GetOptionsObject(options).
        const options = try options_value.getOptionsObject(agent);

        // 4. NOTE: The following steps read options and perform independent validation in
        //    alphabetical order (GetTemporalFractionalSecondDigitsOption reads
        //    "fractionalSecondDigits" and GetRoundingModeOption reads "roundingMode").

        // 5. Let digits be ? GetTemporalFractionalSecondDigitsOption(resolvedOptions).
        const precision = try getTemporalFractionalSecondDigitsOption(agent, options);

        // 6. Let roundingMode be ? GetRoundingModeOption(resolvedOptions, trunc).
        const rounding_mode = try getTemporalRoundingModeOption(
            agent,
            options,
            temporal_rs.c.RoundingMode_Trunc,
        );

        // 7. Let smallestUnit be ? GetTemporalUnitValuedOption(resolvedOptions, "smallestUnit",
        //    unset).
        const smallest_unit = try getTemporalUnitValuedOption(
            agent,
            options,
            "smallestUnit",
            .unset,
        );

        // 8. Perform ? ValidateTemporalUnitValue(smallestUnit, time).
        try validateTemporalUnitValue(agent, smallest_unit, "smallestUnit", .time, &.{});

        // 9. If smallestUnit is either hour or minute, throw a RangeError exception.
        // 10. Let precision be ToSecondsStringPrecisionRecord(smallestUnit, digits).
        // 11. If precision.[[Unit]] is nanosecond and precision.[[Increment]] = 1, then
        //     a. Return TemporalDurationToString(duration, precision.[[Precision]]).
        // 12. Let largestUnit be DefaultTemporalLargestUnit(duration).
        // 13. Let internalDuration be ToInternalDurationRecord(duration).
        // 14. Let timeDuration be ? RoundTimeDuration(internalDuration.[[Time]],
        //     precision.[[Increment]], precision.[[Unit]], roundingMode).
        // 15. Set internalDuration to CombineDateAndTimeDuration(internalDuration.[[Date]],
        //     timeDuration).
        // 16. Let roundedLargestUnit be LargerOfTwoTemporalUnits(largestUnit, second).
        // 17. Let roundedDuration be ? TemporalDurationFromInternal(internalDuration,
        //     roundedLargestUnit).
        // 18. Return TemporalDurationToString(roundedDuration, precision.[[Precision]]).
        var write = temporal_rs.DiplomatWrite.init(agent.gc_allocator);
        try builtins.temporal.extractResult(
            agent,
            temporal_rs.c.temporal_rs_Duration_to_string(
                duration.fields.inner,
                .{
                    .precision = precision,
                    .smallest_unit = temporal_rs.toUnitOption(smallest_unit),
                    .rounding_mode = temporal_rs.toRoundingModeOption(rounding_mode),
                },
                &write.inner,
            ),
        );
        return Value.from(try String.fromAscii(agent, try write.toOwnedSlice()));
    }

    /// 7.3.21 Temporal.Duration.prototype.total ( totalOf )
    /// https://tc39.es/proposal-temporal/#sec-temporal.duration.prototype.total
    fn total(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const total_of = arguments.get(0);

        // 1. Let duration be the this value.
        // 2. Perform ? RequireInternalSlot(duration, [[InitializedTemporalDuration]]).
        const duration = try this_value.requireInternalSlot(agent, Duration);

        // 3. If totalOf is undefined, throw a TypeError exception.
        if (total_of.isUndefined()) {
            return agent.throwException(.type_error, "Argument must not be undefined", .{});
        }

        // 4. If totalOf is a String, then
        const options = if (total_of.isString()) blk: {
            // a. Let paramString be totalOf.
            const param_string = total_of.asString();

            // b. Set totalOf to OrdinaryObjectCreate(null).
            const options = try ordinaryObjectCreate(agent, null);

            // c. Perform ! CreateDataPropertyOrThrow(totalOf, "unit", paramString).
            try options.createDataPropertyDirect(
                agent,
                PropertyKey.from("unit"),
                Value.from(param_string),
            );

            break :blk options;
        } else blk: {
            // 5. Else,
            // a. Set totalOf to ? GetOptionsObject(totalOf).
            break :blk try total_of.getOptionsObject(agent);
        };

        // 6. NOTE: The following steps read options and perform independent validation in
        //    alphabetical order (GetTemporalRelativeToOption reads "relativeTo").

        // 7. Let relativeToRecord be ? GetTemporalRelativeToOption(totalOf).
        const relative_to = try getTemporalRelativeToOption(agent, options);
        defer relative_to.deinit();

        // 8. Let zonedRelativeTo be relativeToRecord.[[ZonedRelativeTo]].
        // 9. Let plainRelativeTo be relativeToRecord.[[PlainRelativeTo]].

        // 10. Let unit be ? GetTemporalUnitValuedOption(totalOf, "unit", required).
        const unit = try getTemporalUnitValuedOption(agent, options, "unit", .required);

        // 11. Perform ? ValidateTemporalUnitValue(unit, datetime).
        try validateTemporalUnitValue(agent, unit, "unit", .datetime, &.{});

        // 12. If zonedRelativeTo is not undefined, then
        //     a. Let internalDuration be ToInternalDurationRecord(duration).
        //     b. Let timeZone be zonedRelativeTo.[[TimeZone]].
        //     c. Let calendar be zonedRelativeTo.[[Calendar]].
        //     d. Let relativeEpochNs be zonedRelativeTo.[[EpochNanoseconds]].
        //     e. Let targetEpochNs be ? AddZonedDateTime(relativeEpochNs, timeZone, calendar,
        //        internalDuration, constrain).
        //     f. Let total be ? DifferenceZonedDateTimeWithTotal(relativeEpochNs, targetEpochNs,
        //        timeZone, calendar, unit).
        // 13. Else if plainRelativeTo is not undefined, then
        //     a. Let internalDuration be ToInternalDurationRecordWith24HourDays(duration).
        //     b. Let targetTime be AddTime(MidnightTimeRecord(), internalDuration.[[Time]]).
        //     c. Let calendar be plainRelativeTo.[[Calendar]].
        //     d. Let dateDuration be ! AdjustDateDurationRecord(internalDuration.[[Date]],
        //        targetTime.[[Days]]).
        //     e. Let targetDate be ? CalendarDateAdd(calendar, plainRelativeTo.[[ISODate]],
        //        dateDuration, constrain).
        //     f. Let isoDateTime be CombineISODateAndTimeRecord(plainRelativeTo.[[ISODate]],
        //        MidnightTimeRecord()).
        //     g. Let targetDateTime be CombineISODateAndTimeRecord(targetDate, targetTime).
        //     h. Let total be ? DifferencePlainDateTimeWithTotal(isoDateTime, targetDateTime,
        //        calendar, unit).
        // 14. Else,
        //     a. Let largestUnit be DefaultTemporalLargestUnit(duration).
        //     b. If IsCalendarUnit(largestUnit) is true or IsCalendarUnit(unit) is true, throw a
        //        RangeError exception.
        //     c. Let internalDuration be ToInternalDurationRecordWith24HourDays(duration).
        //     d. Let total be TotalTimeDuration(internalDuration.[[Time]], unit).
        // 15. Return 𝔽(total).
        const result = try builtins.temporal.extractResult(
            agent,
            temporal_rs.c.temporal_rs_Duration_total(
                duration.fields.inner,
                unit.?,
                relative_to.toRust(),
            ),
        );
        return Value.from(result);
    }

    /// 7.3.25 Temporal.Duration.prototype.valueOf ( )
    /// https://tc39.es/proposal-temporal/#sec-temporal.duration.prototype.valueof
    fn valueOf(agent: *Agent, _: Value, _: Arguments) Agent.Error!Value {
        // 1. Throw a TypeError exception.
        return agent.throwException(
            .type_error,
            "Cannot convert Temporal.Duration to primitive value",
            .{},
        );
    }

    /// 7.3.5 get Temporal.Duration.prototype.weeks
    /// https://tc39.es/proposal-temporal/#sec-get-temporal.duration.prototype.weeks
    fn weeks(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let duration be the this value.
        // 2. Perform ? RequireInternalSlot(duration, [[InitializedTemporalDuration]]).
        const duration = try this_value.requireInternalSlot(agent, Duration);

        // 3. Return 𝔽(duration.[[Weeks]]).
        return Value.from(
            @as(f64, @floatFromInt(temporal_rs.c.temporal_rs_Duration_weeks(duration.fields.inner))),
        );
    }

    /// 7.3.15 Temporal.Duration.prototype.with ( temporalDurationLike )
    /// https://tc39.es/proposal-temporal/#sec-temporal.duration.prototype.with
    fn with(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const temporal_duration_like_value = arguments.get(0);

        // 1. Let duration be the this value.
        // 2. Perform ? RequireInternalSlot(duration, [[InitializedTemporalDuration]]).
        const duration = try this_value.requireInternalSlot(agent, Duration);

        // 3. Let temporalDurationLike be ? ToTemporalPartialDurationRecord(temporalDurationLike).
        const temporal_duration_like = try toTemporalPartialDuration(
            agent,
            temporal_duration_like_value,
        );

        // 4. If temporalDurationLike.[[Years]] is not undefined, then
        //     a. Let years be temporalDurationLike.[[Years]].
        // 5. Else,
        //     a. Let years be duration.[[Years]].
        const years_ = temporal_rs.fromOption(temporal_duration_like.years) orelse
            temporal_rs.c.temporal_rs_Duration_years(duration.fields.inner);

        // 6. If temporalDurationLike.[[Months]] is not undefined, then
        //     a. Let months be temporalDurationLike.[[Months]].
        // 7. Else,
        //     a. Let months be duration.[[Months]].
        const months_ = temporal_rs.fromOption(temporal_duration_like.months) orelse
            temporal_rs.c.temporal_rs_Duration_months(duration.fields.inner);

        // 8. If temporalDurationLike.[[Weeks]] is not undefined, then
        //     a. Let weeks be temporalDurationLike.[[Weeks]].
        // 9. Else,
        //     a. Let weeks be duration.[[Weeks]].
        const weeks_ = temporal_rs.fromOption(temporal_duration_like.weeks) orelse
            temporal_rs.c.temporal_rs_Duration_weeks(duration.fields.inner);

        // 10. If temporalDurationLike.[[Days]] is not undefined, then
        //     a. Let days be temporalDurationLike.[[Days]].
        // 11. Else,
        //     a. Let days be duration.[[Days]].
        const days_ = temporal_rs.fromOption(temporal_duration_like.days) orelse
            temporal_rs.c.temporal_rs_Duration_days(duration.fields.inner);

        // 12. If temporalDurationLike.[[Hours]] is not undefined, then
        //     a. Let hours be temporalDurationLike.[[Hours]].
        // 13. Else,
        //     a. Let hours be duration.[[Hours]].
        const hours_ = temporal_rs.fromOption(temporal_duration_like.hours) orelse
            temporal_rs.c.temporal_rs_Duration_hours(duration.fields.inner);

        // 14. If temporalDurationLike.[[Minutes]] is not undefined, then
        //     a. Let minutes be temporalDurationLike.[[Minutes]].
        // 15. Else,
        //     a. Let minutes be duration.[[Minutes]].
        const minutes_ = temporal_rs.fromOption(temporal_duration_like.minutes) orelse
            temporal_rs.c.temporal_rs_Duration_minutes(duration.fields.inner);

        // 16. If temporalDurationLike.[[Seconds]] is not undefined, then
        //     a. Let seconds be temporalDurationLike.[[Seconds]].
        // 17. Else,
        //     a. Let seconds be duration.[[Seconds]].
        const seconds_ = temporal_rs.fromOption(temporal_duration_like.seconds) orelse
            temporal_rs.c.temporal_rs_Duration_seconds(duration.fields.inner);

        // 18. If temporalDurationLike.[[Milliseconds]] is not undefined, then
        //     a. Let milliseconds be temporalDurationLike.[[Milliseconds]].
        // 19. Else,
        //     a. Let milliseconds be duration.[[Milliseconds]].
        const milliseconds_ = temporal_rs.fromOption(temporal_duration_like.milliseconds) orelse
            temporal_rs.c.temporal_rs_Duration_milliseconds(duration.fields.inner);

        // 20. If temporalDurationLike.[[Microseconds]] is not undefined, then
        //     a. Let microseconds be temporalDurationLike.[[Microseconds]].
        // 21. Else,
        //     a. Let microseconds be duration.[[Microseconds]].
        const microseconds_ = temporal_rs.fromOption(temporal_duration_like.microseconds) orelse
            temporal_rs.c.temporal_rs_Duration_microseconds(duration.fields.inner);

        // 22. If temporalDurationLike.[[Nanoseconds]] is not undefined, then
        //     a. Let nanoseconds be temporalDurationLike.[[Nanoseconds]].
        // 23. Else,
        //     a. Let nanoseconds be duration.[[Nanoseconds]].
        const nanoseconds_ = temporal_rs.fromOption(temporal_duration_like.nanoseconds) orelse
            temporal_rs.c.temporal_rs_Duration_nanoseconds(duration.fields.inner);

        // 24. Return ? CreateTemporalDuration(years, months, weeks, days, hours, minutes, seconds,
        //     milliseconds, microseconds, nanoseconds).
        const temporal_rs_duration = try builtins.temporal.extractResult(
            agent,
            temporal_rs.c.temporal_rs_Duration_try_new(
                years_,
                months_,
                weeks_,
                days_,
                hours_,
                minutes_,
                seconds_,
                milliseconds_,
                microseconds_,
                nanoseconds_,
            ),
        );
        errdefer temporal_rs.c.temporal_rs_Duration_destroy(temporal_rs_duration.?);
        const new_duration = try createTemporalDuration(agent, temporal_rs_duration.?, null);
        return Value.from(&new_duration.object);
    }

    /// 7.3.3 get Temporal.Duration.prototype.years
    /// https://tc39.es/proposal-temporal/#sec-get-temporal.duration.prototype.years
    fn years(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let duration be the this value.
        // 2. Perform ? RequireInternalSlot(duration, [[InitializedTemporalDuration]]).
        const duration = try this_value.requireInternalSlot(agent, Duration);

        // 3. Return 𝔽(duration.[[Years]]).
        return Value.from(
            @as(f64, @floatFromInt(temporal_rs.c.temporal_rs_Duration_years(duration.fields.inner))),
        );
    }
};

/// 7.4 Properties of Temporal.Duration Instances
/// https://tc39.es/proposal-temporal/#sec-properties-of-temporal-duration-instances
pub const Duration = MakeObject(.{
    .Fields = struct {
        inner: *temporal_rs.c.Duration,
    },
    .finalizer = struct {
        fn finalizer(object: *Object) void {
            temporal_rs.c.temporal_rs_Duration_destroy(object.as(Duration).fields.inner);
        }
    }.finalizer,
    .tag = .temporal_duration,
    .display_name = "Temporal.Duration",
});

/// 7.5.12 ToTemporalDuration ( item )
/// https://tc39.es/proposal-temporal/#sec-temporal-totemporalduration
pub fn toTemporalDuration(agent: *Agent, item: Value) Agent.Error!*Duration {
    // 1. If item is an Object and item has an [[InitializedTemporalDuration]] internal slot, then
    if (item.castObject(Duration)) |duration| {
        // a. Return ! CreateTemporalDuration(item.[[Years]], item.[[Months]], item.[[Weeks]],
        //    item.[[Days]], item.[[Hours]], item.[[Minutes]], item.[[Seconds]],
        //    item.[[Milliseconds]], item.[[Microseconds]], item.[[Nanoseconds]]).
        const temporal_rs_duration = temporal_rs.c.temporal_rs_Duration_clone(
            duration.fields.inner,
        );
        errdefer temporal_rs.c.temporal_rs_Duration_destroy(temporal_rs_duration.?);
        return createTemporalDuration(agent, temporal_rs_duration.?, null);
    }

    // 2. If item is not an Object, then
    if (!item.isObject()) {
        // a. If item is not a String, throw a TypeError exception.
        if (!item.isString()) {
            return agent.throwException(.type_error, "Duration must be a string or object", .{});
        }

        // b. Return ? ParseTemporalDurationString(item).
        const temporal_rs_duration = switch (item.asString().asAsciiOrUtf16()) {
            .ascii => |ascii| try builtins.temporal.extractResult(
                agent,
                temporal_rs.c.temporal_rs_Duration_from_utf8(
                    temporal_rs.toDiplomatStringView(ascii),
                ),
            ),
            .utf16 => |utf16| try builtins.temporal.extractResult(
                agent,
                temporal_rs.c.temporal_rs_Duration_from_utf16(
                    temporal_rs.toDiplomatString16View(utf16),
                ),
            ),
        };
        errdefer temporal_rs.c.temporal_rs_Duration_destroy(temporal_rs_duration.?);
        return createTemporalDuration(agent, temporal_rs_duration.?, null);
    }

    // 3. Let result be a new Partial Duration Record with each field set to 0.
    // 4. Let partial be ? ToTemporalPartialDurationRecord(item).
    const partial = try toTemporalPartialDuration(agent, item);

    // 5. If partial.[[Years]] is not undefined, set result.[[Years]] to partial.[[Years]].
    // 6. If partial.[[Months]] is not undefined, set result.[[Months]] to partial.[[Months]].
    // 7. If partial.[[Weeks]] is not undefined, set result.[[Weeks]] to partial.[[Weeks]].
    // 8. If partial.[[Days]] is not undefined, set result.[[Days]] to partial.[[Days]].
    // 9. If partial.[[Hours]] is not undefined, set result.[[Hours]] to partial.[[Hours]].
    // 10. If partial.[[Minutes]] is not undefined, set result.[[Minutes]] to partial.[[Minutes]].
    // 11. If partial.[[Seconds]] is not undefined, set result.[[Seconds]] to partial.[[Seconds]].
    // 12. If partial.[[Milliseconds]] is not undefined, set result.[[Milliseconds]] to
    //     partial.[[Milliseconds]].
    // 13. If partial.[[Microseconds]] is not undefined, set result.[[Microseconds]] to
    //     partial.[[Microseconds]].
    // 14. If partial.[[Nanoseconds]] is not undefined, set result.[[Nanoseconds]] to
    //     partial.[[Nanoseconds]].
    // 15. Return ? CreateTemporalDuration(result.[[Years]], result.[[Months]], result.[[Weeks]],
    //     result.[[Days]], result.[[Hours]], result.[[Minutes]], result.[[Seconds]],
    //     result.[[Milliseconds]], result.[[Microseconds]], result.[[Nanoseconds]]).
    const temporal_rs_duration = try builtins.temporal.extractResult(
        agent,
        temporal_rs.c.temporal_rs_Duration_from_partial_duration(partial),
    );
    errdefer temporal_rs.c.temporal_rs_Duration_destroy(temporal_rs_duration.?);
    return createTemporalDuration(agent, temporal_rs_duration.?, null);
}

/// 7.5.18 ToTemporalPartialDurationRecord ( temporalDurationLike )
/// https://tc39.es/proposal-temporal/#sec-temporal-totemporalpartialdurationrecord
pub fn toTemporalPartialDuration(
    agent: *Agent,
    temporal_duration_like_value: Value,
) Agent.Error!temporal_rs.c.PartialDuration {
    // 1. If temporalDurationLike is not an Object, throw a TypeError exception.
    if (!temporal_duration_like_value.isObject()) {
        return agent.throwException(.type_error, "Duration-like must be an object", .{});
    }
    const temporal_duration_like = temporal_duration_like_value.asObject();

    // 2. Let result be a new partial Duration Record with each field set to undefined.
    var result: temporal_rs.c.PartialDuration = .{
        .years = temporal_rs.toOption(temporal_rs.c.OptionI64, null),
        .months = temporal_rs.toOption(temporal_rs.c.OptionI64, null),
        .weeks = temporal_rs.toOption(temporal_rs.c.OptionI64, null),
        .days = temporal_rs.toOption(temporal_rs.c.OptionI64, null),
        .hours = temporal_rs.toOption(temporal_rs.c.OptionI64, null),
        .minutes = temporal_rs.toOption(temporal_rs.c.OptionI64, null),
        .seconds = temporal_rs.toOption(temporal_rs.c.OptionI64, null),
        .milliseconds = temporal_rs.toOption(temporal_rs.c.OptionI64, null),
        .microseconds = temporal_rs.toOption(temporal_rs.c.OptionF64, null),
        .nanoseconds = temporal_rs.toOption(temporal_rs.c.OptionF64, null),
    };

    // 3. NOTE: The following steps read properties and perform independent validation in
    //    alphabetical order.

    // 4. Let days be ? Get(temporalDurationLike, "days").
    const days = try temporal_duration_like.get(agent, PropertyKey.from("days"));

    // 5. If days is not undefined, set result.[[Days]] to ? ToIntegerIfIntegral(days).
    if (!days.isUndefined()) {
        result.days = temporal_rs.toOption(
            temporal_rs.c.OptionI64,
            std.math.lossyCast(i64, try days.toIntegerIfIntegral(agent)),
        );
    }

    // 6. Let hours be ? Get(temporalDurationLike, "hours").
    const hours = try temporal_duration_like.get(agent, PropertyKey.from("hours"));

    // 7. If hours is not undefined, set result.[[Hours]] to ? ToIntegerIfIntegral(hours).
    if (!hours.isUndefined()) {
        result.hours = temporal_rs.toOption(
            temporal_rs.c.OptionI64,
            std.math.lossyCast(i64, try hours.toIntegerIfIntegral(agent)),
        );
    }

    // 8. Let microseconds be ? Get(temporalDurationLike, "microseconds").
    const microseconds = try temporal_duration_like.get(agent, PropertyKey.from("microseconds"));

    // 9. If microseconds is not undefined, set result.[[Microseconds]] to ? ToIntegerIfIntegral(
    //    microseconds).
    if (!microseconds.isUndefined()) {
        result.microseconds = temporal_rs.toOption(
            temporal_rs.c.OptionF64,
            try microseconds.toIntegerIfIntegral(agent),
        );
    }

    // 10. Let milliseconds be ? Get(temporalDurationLike, "milliseconds").
    const milliseconds = try temporal_duration_like.get(agent, PropertyKey.from("milliseconds"));

    // 11. If milliseconds is not undefined, set result.[[Milliseconds]] to ? ToIntegerIfIntegral(
    //     milliseconds).
    if (!milliseconds.isUndefined()) {
        result.milliseconds = temporal_rs.toOption(
            temporal_rs.c.OptionI64,
            std.math.lossyCast(i64, try milliseconds.toIntegerIfIntegral(agent)),
        );
    }

    // 12. Let minutes be ? Get(temporalDurationLike, "minutes").
    const minutes = try temporal_duration_like.get(agent, PropertyKey.from("minutes"));

    // 13. If minutes is not undefined, set result.[[Minutes]] to ? ToIntegerIfIntegral(minutes).
    if (!minutes.isUndefined()) {
        result.minutes = temporal_rs.toOption(
            temporal_rs.c.OptionI64,
            std.math.lossyCast(i64, try minutes.toIntegerIfIntegral(agent)),
        );
    }

    // 14. Let months be ? Get(temporalDurationLike, "months").
    const months = try temporal_duration_like.get(agent, PropertyKey.from("months"));

    // 15. If months is not undefined, set result.[[Months]] to ? ToIntegerIfIntegral(months).
    if (!months.isUndefined()) {
        result.months = temporal_rs.toOption(
            temporal_rs.c.OptionI64,
            std.math.lossyCast(i64, try months.toIntegerIfIntegral(agent)),
        );
    }

    // 16. Let nanoseconds be ? Get(temporalDurationLike, "nanoseconds").
    const nanoseconds = try temporal_duration_like.get(agent, PropertyKey.from("nanoseconds"));

    // 17. If nanoseconds is not undefined, set result.[[Nanoseconds]] to ? ToIntegerIfIntegral(
    //     nanoseconds).
    if (!nanoseconds.isUndefined()) {
        result.nanoseconds = temporal_rs.toOption(
            temporal_rs.c.OptionF64,
            try nanoseconds.toIntegerIfIntegral(agent),
        );
    }

    // 18. Let seconds be ? Get(temporalDurationLike, "seconds").
    const seconds = try temporal_duration_like.get(agent, PropertyKey.from("seconds"));

    // 19. If seconds is not undefined, set result.[[Seconds]] to ? ToIntegerIfIntegral(seconds).
    if (!seconds.isUndefined()) {
        result.seconds = temporal_rs.toOption(
            temporal_rs.c.OptionI64,
            std.math.lossyCast(i64, try seconds.toIntegerIfIntegral(agent)),
        );
    }

    // 20. Let weeks be ? Get(temporalDurationLike, "weeks").
    const weeks = try temporal_duration_like.get(agent, PropertyKey.from("weeks"));

    // 21. If weeks is not undefined, set result.[[Weeks]] to ? ToIntegerIfIntegral(weeks).
    if (!weeks.isUndefined()) {
        result.weeks = temporal_rs.toOption(
            temporal_rs.c.OptionI64,
            std.math.lossyCast(i64, try weeks.toIntegerIfIntegral(agent)),
        );
    }

    // 22. Let years be ? Get(temporalDurationLike, "years").
    const years = try temporal_duration_like.get(agent, PropertyKey.from("years"));

    // 23. If years is not undefined, set result.[[Years]] to ? ToIntegerIfIntegral(years).
    if (!years.isUndefined()) {
        result.years = temporal_rs.toOption(
            temporal_rs.c.OptionI64,
            std.math.lossyCast(i64, try years.toIntegerIfIntegral(agent)),
        );
    }

    // 24. If years is undefined, and months is undefined, and weeks is undefined, and days is
    //     undefined, and hours is undefined, and minutes is undefined, and seconds is undefined,
    //     and milliseconds is undefined, and microseconds is undefined, and nanoseconds is
    //     undefined, throw a TypeError exception.
    if (!result.years.is_ok and !result.months.is_ok and !result.weeks.is_ok and
        !result.days.is_ok and !result.hours.is_ok and !result.minutes.is_ok and
        !result.seconds.is_ok and !result.milliseconds.is_ok and !result.microseconds.is_ok and
        !result.nanoseconds.is_ok)
    {
        return agent.throwException(
            .type_error,
            "Duration-like object must have at least one field defined",
            .{},
        );
    }

    // 25. Return result.
    return result;
}

/// 7.5.19 CreateTemporalDuration ( years, months, weeks, days, hours, minutes, seconds, milliseconds, microseconds, nanoseconds [ , newTarget ] )
/// https://tc39.es/proposal-temporal/#sec-temporal-createtemporalduration
pub fn createTemporalDuration(
    agent: *Agent,
    inner: *temporal_rs.c.Duration,
    maybe_new_target: ?*Object,
) Agent.Error!*Duration {
    const realm = agent.currentRealm();

    // 1. If IsValidDuration(years, months, weeks, days, hours, minutes, seconds, milliseconds,
    //    microseconds, nanoseconds) is false, throw a RangeError exception.

    // 2. If newTarget is not present, set newTarget to %Temporal.Duration%.
    const new_target = maybe_new_target orelse try realm.intrinsic(.temporal_duration);

    // 3. Let object be ? OrdinaryCreateFromConstructor(newTarget, "%Temporal.Duration.prototype%",
    //    « [[InitializedTemporalDuration]], [[Years]], [[Months]], [[Weeks]], [[Days]], [[Hours]],
    //    [[Minutes]], [[Seconds]], [[Milliseconds]], [[Microseconds]], [[Nanoseconds]] »).
    // 4. Set object.[[Years]] to ℝ(𝔽(years)).
    // 5. Set object.[[Months]] to ℝ(𝔽(months)).
    // 6. Set object.[[Weeks]] to ℝ(𝔽(weeks)).
    // 7. Set object.[[Days]] to ℝ(𝔽(days)).
    // 8. Set object.[[Hours]] to ℝ(𝔽(hours)).
    // 9. Set object.[[Minutes]] to ℝ(𝔽(minutes)).
    // 10. Set object.[[Seconds]] to ℝ(𝔽(seconds)).
    // 11. Set object.[[Milliseconds]] to ℝ(𝔽(milliseconds)).
    // 12. Set object.[[Microseconds]] to ℝ(𝔽(microseconds)).
    // 13. Set object.[[Nanoseconds]] to ℝ(𝔽(nanoseconds)).
    // 14. Return object.
    return ordinaryCreateFromConstructor(
        Duration,
        agent,
        new_target,
        .temporal_duration_prototype,
        .{ .inner = inner },
    );
}

/// 7.5.41 AddDurations ( operation, duration, other )
/// https://tc39.es/proposal-temporal/#sec-temporal-adddurations
fn addDurations(
    agent: *Agent,
    operation: enum { add, subtract },
    duration: *const Duration,
    other_value: Value,
) Agent.Error!*Duration {
    // 1. Set other to ? ToTemporalDuration(other).
    const other = try toTemporalDuration(agent, other_value);

    // 2. If operation is subtract, set other to CreateNegatedTemporalDuration(other).
    // 3. Let largestUnit1 be DefaultTemporalLargestUnit(duration).
    // 4. Let largestUnit2 be DefaultTemporalLargestUnit(other).
    // 5. Let largestUnit be LargerOfTwoTemporalUnits(largestUnit1, largestUnit2).
    // 6. If IsCalendarUnit(largestUnit) is true, throw a RangeError exception.
    // 7. Let d1 be ToInternalDurationRecordWith24HourDays(duration).
    // 8. Let d2 be ToInternalDurationRecordWith24HourDays(other).
    // 9. Let timeResult be ? AddTimeDuration(d1.[[Time]], d2.[[Time]]).
    // 10. Let result be CombineDateAndTimeDuration(ZeroDateDuration(), timeResult).
    // 11. Return ? TemporalDurationFromInternal(result, largestUnit).
    const temporal_rs_duration = switch (operation) {
        .add => try builtins.temporal.extractResult(
            agent,
            temporal_rs.c.temporal_rs_Duration_add(
                duration.fields.inner,
                other.fields.inner,
            ),
        ),
        .subtract => try builtins.temporal.extractResult(
            agent,
            temporal_rs.c.temporal_rs_Duration_subtract(
                duration.fields.inner,
                other.fields.inner,
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
