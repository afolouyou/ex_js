//! 4 Temporal.PlainTime Objects
//! https://tc39.es/proposal-temporal/#sec-temporal-plaintime-objects

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
const createTemporalDuration = builtins.createTemporalDuration;
const getTemporalDifferenceSettingsWithoutValidation = builtins.getTemporalDifferenceSettingsWithoutValidation;
const getTemporalFractionalSecondDigitsOption = builtins.getTemporalFractionalSecondDigitsOption;
const getTemporalOverflowOption = builtins.getTemporalOverflowOption;
const getTemporalRoundingIncrementOption = builtins.getTemporalRoundingIncrementOption;
const getTemporalRoundingModeOption = builtins.getTemporalRoundingModeOption;
const getTemporalUnitValuedOption = builtins.getTemporalUnitValuedOption;
const isPartialTemporalObject = builtins.isPartialTemporalObject;
const noexcept = utils.noexcept;
const ordinaryCreateFromConstructor = builtins.ordinaryCreateFromConstructor;
const ordinaryObjectCreate = builtins.ordinaryObjectCreate;
const toTemporalDuration = builtins.toTemporalDuration;
const validateTemporalUnitValue = builtins.validateTemporalUnitValue;

/// 4.2 Properties of the Temporal.PlainTime Constructor
/// https://tc39.es/proposal-temporal/#sec-properties-of-the-temporal-plaintime-constructor
pub const constructor = struct {
    pub fn create(agent: *Agent, realm: *Realm) std.mem.Allocator.Error!*Object {
        const builtin_function = try createBuiltinFunction(
            agent,
            .{ .constructor = impl },
            0,
            "PlainTime",
            .{ .realm = realm, .proto = try realm.intrinsic(.function_prototype) },
        );
        return &builtin_function.object;
    }

    pub fn init(agent: *Agent, realm: *Realm, object: *Object) std.mem.Allocator.Error!void {
        try object.defineBuiltinFunction(agent, "compare", compare, 2, realm);
        try object.defineBuiltinFunction(agent, "from", from, 1, realm);

        // 4.2.1 Temporal.PlainTime.prototype
        // https://tc39.es/proposal-temporal/#sec-temporal.plaintime.prototype
        try object.defineBuiltinPropertyWithAttributes(
            agent,
            "prototype",
            Value.from(try realm.intrinsic(.temporal_plain_time_prototype)),
            .{
                .writable = false,
                .enumerable = false,
                .configurable = false,
            },
        );
    }

    /// 4.1.1 Temporal.PlainTime ( [ hour [ , minute [ , second [ , millisecond [ , microsecond [ , nanosecond ] ] ] ] ] ] )
    /// https://tc39.es/proposal-temporal/#sec-temporal.plaintime
    fn impl(agent: *Agent, arguments: Arguments, maybe_new_target: ?*Object) Agent.Error!Value {
        const hour_value = arguments.get(0);
        const minute_value = arguments.get(1);
        const second_value = arguments.get(2);
        const millisecond_value = arguments.get(3);
        const microsecond_value = arguments.get(4);
        const nanosecond_value = arguments.get(5);

        // 1. If NewTarget is undefined, throw a TypeError exception.
        const new_target = maybe_new_target orelse {
            return agent.throwException(
                .type_error,
                "Temporal.PlainTime must be constructed with 'new'",
                .{},
            );
        };

        // 2. If hour is undefined, set hour to 0; else set hour to ? ToIntegerWithTruncation(hour).
        const hour = if (hour_value.isUndefined()) 0 else try hour_value.toIntegerWithTruncation(agent);

        // 3. If minute is undefined, set minute to 0; else set minute to ? ToIntegerWithTruncation(
        //    minute).
        const minute = if (minute_value.isUndefined()) 0 else try minute_value.toIntegerWithTruncation(agent);

        // 4. If second is undefined, set second to 0; else set second to ? ToIntegerWithTruncation(
        //    second).
        const second = if (second_value.isUndefined()) 0 else try second_value.toIntegerWithTruncation(agent);

        // 5. If millisecond is undefined, set millisecond to 0; else set millisecond to
        //    ? ToIntegerWithTruncation(millisecond).
        const millisecond = if (millisecond_value.isUndefined()) 0 else try millisecond_value.toIntegerWithTruncation(agent);

        // 6. If microsecond is undefined, set microsecond to 0; else set microsecond to
        //    ? ToIntegerWithTruncation(microsecond).
        const microsecond = if (microsecond_value.isUndefined()) 0 else try microsecond_value.toIntegerWithTruncation(agent);

        // 7. If nanosecond is undefined, set nanosecond to 0; else set nanosecond to
        //    ? ToIntegerWithTruncation(nanosecond).
        const nanosecond = if (nanosecond_value.isUndefined()) 0 else try nanosecond_value.toIntegerWithTruncation(agent);

        // 8. If IsValidTime(hour, minute, second, millisecond, microsecond, nanosecond) is false,
        //    throw a RangeError exception.
        if (!isValidTime(hour, minute, second, millisecond, microsecond, nanosecond)) {
            return agent.throwException(.range_error, "Invalid time", .{});
        }

        // 9. Let time be CreateTimeRecord(hour, minute, second, millisecond, microsecond,
        //    nanosecond).
        // 10. Return ? CreateTemporalTime(time, NewTarget).
        const temporal_rs_plain_time = try builtins.temporal.extractResult(
            agent,
            temporal_rs.c.temporal_rs_PlainTime_try_new(
                @intFromFloat(hour),
                @intFromFloat(minute),
                @intFromFloat(second),
                @intFromFloat(millisecond),
                @intFromFloat(microsecond),
                @intFromFloat(nanosecond),
            ),
        );
        errdefer temporal_rs.c.temporal_rs_PlainTime_destroy(temporal_rs_plain_time.?);
        const plain_time = try createTemporalTime(agent, temporal_rs_plain_time.?, new_target);
        return Value.from(&plain_time.object);
    }

    /// 4.2.3 Temporal.PlainTime.compare ( one, two )
    /// https://tc39.es/proposal-temporal/#sec-temporal.plaintime.compare
    fn compare(agent: *Agent, _: Value, arguments: Arguments) Agent.Error!Value {
        const one_value = arguments.get(0);
        const two_value = arguments.get(1);

        // 1. Set one to ? ToTemporalTime(one).
        const one = try toTemporalPlainTime(agent, one_value, null);

        // 2. Set two to ? ToTemporalTime(two).
        const two = try toTemporalPlainTime(agent, two_value, null);

        // 3. Return 𝔽(CompareTimeRecord(one.[[Time]], two.[[Time]])).
        return Value.from(
            temporal_rs.c.temporal_rs_PlainTime_compare(
                one.fields.inner,
                two.fields.inner,
            ),
        );
    }

    /// 4.2.2 Temporal.PlainTime.from ( item [ , options ] )
    /// https://tc39.es/proposal-temporal/#sec-temporal.plaintime.from
    fn from(agent: *Agent, _: Value, arguments: Arguments) Agent.Error!Value {
        const item = arguments.get(0);
        const options = arguments.get(1);

        // 1. Return ? ToTemporalTime(item, options).
        const plain_time = try toTemporalPlainTime(agent, item, options);
        return Value.from(&plain_time.object);
    }
};

/// 4.3 Properties of the Temporal.PlainTime Prototype Object
/// https://tc39.es/proposal-temporal/#sec-properties-of-the-temporal-plaintime-prototype-object
pub const prototype = struct {
    pub fn create(agent: *Agent, realm: *Realm) std.mem.Allocator.Error!*Object {
        return ordinaryObjectCreate(agent, try realm.intrinsic(.object_prototype));
    }

    pub fn init(agent: *Agent, realm: *Realm, object: *Object) std.mem.Allocator.Error!void {
        try object.defineBuiltinFunction(agent, "add", add, 1, realm);
        try object.defineBuiltinFunction(agent, "equals", equals, 1, realm);
        try object.defineBuiltinAccessor(agent, "hour", hour, null, realm);
        try object.defineBuiltinAccessor(agent, "microsecond", microsecond, null, realm);
        try object.defineBuiltinAccessor(agent, "millisecond", millisecond, null, realm);
        try object.defineBuiltinAccessor(agent, "minute", minute, null, realm);
        try object.defineBuiltinAccessor(agent, "nanosecond", nanosecond, null, realm);
        try object.defineBuiltinFunction(agent, "round", round, 1, realm);
        try object.defineBuiltinAccessor(agent, "second", second, null, realm);
        try object.defineBuiltinFunction(agent, "since", since, 1, realm);
        try object.defineBuiltinFunction(agent, "subtract", subtract, 1, realm);
        try object.defineBuiltinFunction(agent, "toJSON", toJSON, 0, realm);
        try object.defineBuiltinFunction(agent, "toLocaleString", toLocaleString, 0, realm);
        try object.defineBuiltinFunction(agent, "toString", toString, 0, realm);
        try object.defineBuiltinFunction(agent, "until", until, 1, realm);
        try object.defineBuiltinFunction(agent, "valueOf", valueOf, 0, realm);
        try object.defineBuiltinFunction(agent, "with", with, 1, realm);

        // 4.3.1 Temporal.PlainTime.prototype.constructor
        // https://tc39.es/proposal-temporal/#sec-temporal.plaintime.prototype.constructor
        try object.defineBuiltinProperty(
            agent,
            "constructor",
            Value.from(try realm.intrinsic(.temporal_plain_time)),
        );

        // 4.3.2 Temporal.PlainTime.prototype[ %Symbol.toStringTag% ]
        // https://tc39.es/proposal-temporal/#sec-temporal.plaintime.prototype-%symbol.tostringtag%
        try object.defineBuiltinPropertyWithAttributes(
            agent,
            "Symbol.toStringTag",
            Value.from("Temporal.PlainTime"),
            .{
                .writable = false,
                .enumerable = false,
                .configurable = true,
            },
        );
    }

    /// 4.3.9 Temporal.PlainTime.prototype.add ( temporalDurationLike )
    /// https://tc39.es/proposal-temporal/#sec-temporal.plaintime.prototype.add
    fn add(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const temporal_duration_like = arguments.get(0);

        // 1. Let plainTime be the this value.
        // 2. Perform ? RequireInternalSlot(plainTime, [[InitializedTemporalTime]]).
        const plain_time = try this_value.requireInternalSlot(agent, PlainTime);

        // 3. Return ? AddDurationToTime(add, plainTime, temporalDurationLike).
        const new_plain_time = try addDurationToTime(
            agent,
            .add,
            plain_time,
            temporal_duration_like,
        );
        return Value.from(&new_plain_time.object);
    }

    /// 4.3.15 Temporal.PlainTime.prototype.equals ( other )
    /// https://tc39.es/proposal-temporal/#sec-temporal.plaintime.prototype.equals
    fn equals(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const other_value = arguments.get(0);

        // 1. Let plainTime be the this value.
        // 2. Perform ? RequireInternalSlot(plainTime, [[InitializedTemporalTime]]).
        const plain_time = try this_value.requireInternalSlot(agent, PlainTime);

        // 3. Set other to ? ToTemporalTime(other).
        const other = try toTemporalPlainTime(agent, other_value, null);

        // 4. If CompareTimeRecord(plainTime.[[Time]], other.[[Time]]) = 0, return true.
        // 5. Return false.
        return Value.from(
            temporal_rs.c.temporal_rs_PlainTime_equals(
                plain_time.fields.inner,
                other.fields.inner,
            ),
        );
    }

    /// 4.3.3 get Temporal.PlainTime.prototype.hour
    /// https://tc39.es/proposal-temporal/#sec-get-temporal.plaintime.prototype.hour
    fn hour(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let plainTime be the this value.
        // 2. Perform ? RequireInternalSlot(plainTime, [[InitializedTemporalTime]]).
        const plain_time = try this_value.requireInternalSlot(agent, PlainTime);

        // 3. Return 𝔽(plainTime.[[Time]].[[Hour]]).
        return Value.from(temporal_rs.c.temporal_rs_PlainTime_hour(plain_time.fields.inner));
    }

    /// 4.3.7 get Temporal.PlainTime.prototype.microsecond
    /// https://tc39.es/proposal-temporal/#sec-get-temporal.plaintime.prototype.microsecond
    fn microsecond(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let plainTime be the this value.
        // 2. Perform ? RequireInternalSlot(plainTime, [[InitializedTemporalTime]]).
        const plain_time = try this_value.requireInternalSlot(agent, PlainTime);

        // 3. Return 𝔽(plainTime.[[Time]].[[Microsecond]]).
        return Value.from(temporal_rs.c.temporal_rs_PlainTime_microsecond(plain_time.fields.inner));
    }

    /// 4.3.6 get Temporal.PlainTime.prototype.millisecond
    /// https://tc39.es/proposal-temporal/#sec-get-temporal.plaintime.prototype.millisecond
    fn millisecond(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let plainTime be the this value.
        // 2. Perform ? RequireInternalSlot(plainTime, [[InitializedTemporalTime]]).
        const plain_time = try this_value.requireInternalSlot(agent, PlainTime);

        // 3. Return 𝔽(plainTime.[[Time]].[[Millisecond]]).
        return Value.from(temporal_rs.c.temporal_rs_PlainTime_millisecond(plain_time.fields.inner));
    }

    /// 4.3.4 get Temporal.PlainTime.prototype.minute
    /// https://tc39.es/proposal-temporal/#sec-get-temporal.plaintime.prototype.minute
    fn minute(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let plainTime be the this value.
        // 2. Perform ? RequireInternalSlot(plainTime, [[InitializedTemporalTime]]).
        const plain_time = try this_value.requireInternalSlot(agent, PlainTime);

        // 3. Return 𝔽(plainTime.[[Time]].[[Minute]]).
        return Value.from(temporal_rs.c.temporal_rs_PlainTime_minute(plain_time.fields.inner));
    }

    /// 4.3.8 get Temporal.PlainTime.prototype.nanosecond
    /// https://tc39.es/proposal-temporal/#sec-get-temporal.plaintime.prototype.nanosecond
    fn nanosecond(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let plainTime be the this value.
        // 2. Perform ? RequireInternalSlot(plainTime, [[InitializedTemporalTime]]).
        const plain_time = try this_value.requireInternalSlot(agent, PlainTime);

        // 3. Return 𝔽(plainTime.[[Time]].[[Nanosecond]]).
        return Value.from(temporal_rs.c.temporal_rs_PlainTime_nanosecond(plain_time.fields.inner));
    }

    /// 4.3.14 Temporal.PlainTime.prototype.round ( roundTo )
    /// https://tc39.es/proposal-temporal/#sec-temporal.plaintime.prototype.round
    fn round(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const round_to = arguments.get(0);

        // 1. Let plainTime be the this value.
        // 2. Perform ? RequireInternalSlot(plainTime, [[InitializedTemporalTime]]).
        const plain_time = try this_value.requireInternalSlot(agent, PlainTime);

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

        // 10. Perform ? ValidateTemporalUnitValue(smallestUnit, time).
        try validateTemporalUnitValue(agent, smallest_unit, "smallestUnit", .time, &.{});

        // 11. Let maximum be MaximumTemporalDurationRoundingIncrement(smallestUnit).
        // 12. Assert: maximum is not unset.
        // 13. Perform ? ValidateTemporalRoundingIncrement(roundingIncrement, maximum, false).
        // 14. Let result be RoundTime(plainTime.[[Time]], roundingIncrement, smallestUnit,
        //     roundingMode).
        // 15. Return ! CreateTemporalTime(result).
        const temporal_rs_plain_time = try builtins.temporal.extractResult(
            agent,
            temporal_rs.c.temporal_rs_PlainTime_round(
                plain_time.fields.inner,
                .{
                    .largest_unit = temporal_rs.toUnitOption(null),
                    .smallest_unit = temporal_rs.toUnitOption(smallest_unit),
                    .rounding_mode = temporal_rs.toRoundingModeOption(rounding_mode),
                    .increment = temporal_rs.toOption(temporal_rs.c.OptionU32, rounding_increment),
                },
            ),
        );
        errdefer temporal_rs.c.temporal_rs_PlainTime_destroy(temporal_rs_plain_time.?);
        const new_plain_time = createTemporalTime(
            agent,
            temporal_rs_plain_time.?,
            null,
        ) catch |err| try noexcept(err);
        return Value.from(&new_plain_time.object);
    }

    /// 4.3.5 get Temporal.PlainTime.prototype.second
    /// https://tc39.es/proposal-temporal/#sec-get-temporal.plaintime.prototype.second
    fn second(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let plainTime be the this value.
        // 2. Perform ? RequireInternalSlot(plainTime, [[InitializedTemporalTime]]).
        const plain_time = try this_value.requireInternalSlot(agent, PlainTime);

        // 3. Return 𝔽(plainTime.[[Time]].[[Second]]).
        return Value.from(temporal_rs.c.temporal_rs_PlainTime_second(plain_time.fields.inner));
    }

    /// 4.3.13 Temporal.PlainTime.prototype.since ( other [ , options ] )
    /// https://tc39.es/proposal-temporal/#sec-temporal.plaintime.prototype.since
    fn since(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const other = arguments.get(0);
        const options = arguments.get(1);

        // 1. Let plainTime be the this value.
        // 2. Perform ? RequireInternalSlot(plainTime, [[InitializedTemporalTime]]).
        const plain_time = try this_value.requireInternalSlot(agent, PlainTime);

        // 3. Return ? DifferenceTemporalPlainTime(since, plainTime, other, options).
        const duration = try differenceTemporalPlainTime(
            agent,
            .since,
            plain_time,
            other,
            options,
        );
        return Value.from(&duration.object);
    }

    /// 4.3.10 Temporal.PlainTime.prototype.subtract ( temporalDurationLike )
    /// https://tc39.es/proposal-temporal/#sec-temporal.plaintime.prototype.subtract
    fn subtract(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const temporal_duration_like = arguments.get(0);

        // 1. Let plainTime be the this value.
        // 2. Perform ? RequireInternalSlot(plainTime, [[InitializedTemporalTime]]).
        const plain_time = try this_value.requireInternalSlot(agent, PlainTime);

        // 3. Return ? AddDurationToTime(subtract, plainTime, temporalDurationLike).
        const new_plain_time = try addDurationToTime(
            agent,
            .subtract,
            plain_time,
            temporal_duration_like,
        );
        return Value.from(&new_plain_time.object);
    }

    /// 4.3.18 Temporal.PlainTime.prototype.toJSON ( )
    /// https://tc39.es/proposal-temporal/#sec-temporal.plaintime.prototype.tojson
    fn toJSON(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let plainTime be the this value.
        // 2. Perform ? RequireInternalSlot(plainTime, [[InitializedTemporalTime]]).
        const plain_time = try this_value.requireInternalSlot(agent, PlainTime);

        // 3. Return TimeRecordToString(plainTime.[[Time]], auto).
        var write = temporal_rs.DiplomatWrite.init(agent.gc_allocator);
        try builtins.temporal.extractResult(
            agent,
            temporal_rs.c.temporal_rs_PlainTime_to_ixdtf_string(
                plain_time.fields.inner,
                temporal_rs.to_string_rounding_options_auto,
                &write.inner,
            ),
        );
        return Value.from(try String.fromAscii(agent, try write.toOwnedSlice()));
    }

    /// 4.3.17 Temporal.PlainTime.prototype.toLocaleString ( [ locales [ , options ] ] )
    /// https://tc39.es/proposal-temporal/#sec-temporal.plaintime.prototype.tolocalestring
    fn toLocaleString(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let plainTime be the this value.
        // 2. Perform ? RequireInternalSlot(plainTime, [[InitializedTemporalTime]]).
        const plain_time = try this_value.requireInternalSlot(agent, PlainTime);

        // 3. Return TimeRecordToString(plainTime.[[Time]], auto).
        var write = temporal_rs.DiplomatWrite.init(agent.gc_allocator);
        try builtins.temporal.extractResult(
            agent,
            temporal_rs.c.temporal_rs_PlainTime_to_ixdtf_string(
                plain_time.fields.inner,
                temporal_rs.to_string_rounding_options_auto,
                &write.inner,
            ),
        );
        return Value.from(try String.fromAscii(agent, try write.toOwnedSlice()));
    }

    /// 4.3.16 Temporal.PlainTime.prototype.toString ( [ options ] )
    /// https://tc39.es/proposal-temporal/#sec-temporal.plaintime.prototype.tostring
    fn toString(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const options_value = arguments.get(0);

        // 1. Let plainTime be the this value.
        // 2. Perform ? RequireInternalSlot(plainTime, [[InitializedTemporalTime]]).
        const plain_time = try this_value.requireInternalSlot(agent, PlainTime);

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

        // 9. If smallestUnit is hour, throw a RangeError exception.
        if (smallest_unit == temporal_rs.c.Unit_Hour) {
            return agent.throwException(
                .range_error,
                "Invalid value for option 'smallestUnit'",
                .{},
            );
        }

        // 10. Let precision be ToSecondsStringPrecisionRecord(smallestUnit, digits).
        // 11. Let roundResult be RoundTime(plainTime.[[Time]], precision.[[Increment]],
        //     precision.[[Unit]], roundingMode).
        // 12. Return TimeRecordToString(roundResult, precision.[[Precision]]).
        var write = temporal_rs.DiplomatWrite.init(agent.gc_allocator);
        try builtins.temporal.extractResult(
            agent,
            temporal_rs.c.temporal_rs_PlainTime_to_ixdtf_string(
                plain_time.fields.inner,
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

    /// 4.3.12 Temporal.PlainTime.prototype.until ( other [ , options ] )
    /// https://tc39.es/proposal-temporal/#sec-temporal.plaintime.prototype.until
    fn until(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const other = arguments.get(0);
        const options = arguments.get(1);

        // 1. Let plainTime be the this value.
        // 2. Perform ? RequireInternalSlot(plainTime, [[InitializedTemporalTime]]).
        const plain_time = try this_value.requireInternalSlot(agent, PlainTime);

        // 3. Return ? DifferenceTemporalPlainTime(until, plainTime, other, options).
        const duration = try differenceTemporalPlainTime(
            agent,
            .until,
            plain_time,
            other,
            options,
        );
        return Value.from(&duration.object);
    }

    /// 4.3.19 Temporal.PlainTime.prototype.valueOf ( )
    /// https://tc39.es/proposal-temporal/#sec-temporal.plaintime.prototype.valueof
    fn valueOf(agent: *Agent, _: Value, _: Arguments) Agent.Error!Value {
        // 1. Throw a TypeError exception.
        return agent.throwException(
            .type_error,
            "Cannot convert Temporal.PlainTime to primitive value",
            .{},
        );
    }

    /// 4.3.11 Temporal.PlainTime.prototype.with ( temporalTimeLike [ , options ] )
    /// https://tc39.es/proposal-temporal/#sec-temporal.plaintime.prototype.with
    fn with(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const temporal_date_like = arguments.get(0);
        const options_value = arguments.get(1);

        // 1. Let plainTime be the this value.
        // 2. Perform ? RequireInternalSlot(plainTime, [[InitializedTemporalTime]]).
        const plain_time = try this_value.requireInternalSlot(agent, PlainTime);

        // 3. If ? IsPartialTemporalObject(temporalTimeLike) is false, throw a TypeError exception.
        if (!try isPartialTemporalObject(agent, temporal_date_like)) {
            return agent.throwException(
                .type_error,
                "Argument must be a partial Temporal object",
                .{},
            );
        }

        // 4. Let partialTime be ? ToTemporalTimeRecord(temporalTimeLike, partial).
        const record = try toTemporalTimeRecord(
            agent,
            temporal_date_like.asObject(),
            .partial,
        );

        // 5. If partialTime.[[Hour]] is not undefined, then
        //     a. Let hour be partialTime.[[Hour]].
        // 6. Else,
        //     a. Let hour be plainTime.[[Time]].[[Hour]].
        // 7. If partialTime.[[Minute]] is not undefined, then
        //     a. Let minute be partialTime.[[Minute]].
        // 8. Else,
        //     a. Let minute be plainTime.[[Time]].[[Minute]].
        // 9. If partialTime.[[Second]] is not undefined, then
        //     a. Let second be partialTime.[[Second]].
        // 10. Else,
        //     a. Let second be plainTime.[[Time]].[[Second]].
        // 11. If partialTime.[[Millisecond]] is not undefined, then
        //     a. Let millisecond be partialTime.[[Millisecond]].
        // 12. Else,
        //     a. Let millisecond be plainTime.[[Time]].[[Millisecond]].
        // 13. If partialTime.[[Microsecond]] is not undefined, then
        //     a. Let microsecond be partialTime.[[Microsecond]].
        // 14. Else,
        //     a. Let microsecond be plainTime.[[Time]].[[Microsecond]].
        // 15. If partialTime.[[Nanosecond]] is not undefined, then
        //     a. Let nanosecond be partialTime.[[Nanosecond]].
        // 16. Else,
        //     a. Let nanosecond be plainTime.[[Time]].[[Nanosecond]].

        // 17. Let resolvedOptions be ? GetOptionsObject(options).
        const options = try options_value.getOptionsObject(agent);

        // 18. Let overflow be ? GetTemporalOverflowOption(resolvedOptions).
        const overflow = try getTemporalOverflowOption(agent, options);

        // 19. Let result be ? RegulateTime(hour, minute, second, millisecond, microsecond,
        //     nanosecond, overflow).
        const partial = try record.regulate(agent, overflow);

        // 20. Return ! CreateTemporalTime(result).
        const temporal_rs_plain_time = try builtins.temporal.extractResult(
            agent,
            temporal_rs.c.temporal_rs_PlainTime_with(
                plain_time.fields.inner,
                partial,
                temporal_rs.toArithmeticOverflowOption(overflow),
            ),
        );
        errdefer temporal_rs.c.temporal_rs_PlainTime_destroy(temporal_rs_plain_time.?);
        const new_plain_time = createTemporalTime(
            agent,
            temporal_rs_plain_time.?,
            null,
        ) catch |err| try noexcept(err);
        return Value.from(&new_plain_time.object);
    }
};

/// 4.4 Properties of Temporal.PlainTime Instances
/// https://tc39.es/proposal-temporal/#sec-properties-of-temporal-plaintime-instances
pub const PlainTime = MakeObject(.{
    .Fields = struct {
        inner: *temporal_rs.c.PlainTime,
    },
    .finalizer = struct {
        fn finalizer(object: *Object) void {
            temporal_rs.c.temporal_rs_PlainTime_destroy(object.as(PlainTime).fields.inner);
        }
    }.finalizer,
    .tag = .temporal_plain_time,
    .display_name = "Temporal.PlainTime",
});

/// 4.5.11 CreateTemporalTime ( time [ , newTarget ] )
/// https://tc39.es/proposal-temporal/#sec-temporal-createtemporaltime
pub fn createTemporalTime(
    agent: *Agent,
    inner: *temporal_rs.c.PlainTime,
    maybe_new_target: ?*Object,
) Agent.Error!*PlainTime {
    const realm = agent.currentRealm();

    // 1. If newTarget is not present, set newTarget to %Temporal.PlainTime%.
    const new_target = maybe_new_target orelse try realm.intrinsic(.temporal_plain_time);

    // 2. Let object be ? OrdinaryCreateFromConstructor(newTarget, "%Temporal.PlainTime.prototype%",
    //    « [[InitializedTemporalTime]], [[Time]] »).
    // 3. Set object.[[Time]] to time.
    // 4. Return object.
    return ordinaryCreateFromConstructor(
        PlainTime,
        agent,
        new_target,
        .temporal_plain_time_prototype,
        .{ .inner = inner },
    );
}

/// 4.5.6 ToTemporalTime ( item [ , options ] )
/// https://tc39.es/proposal-temporal/#sec-temporal-totemporaltime
pub fn toTemporalPlainTime(
    agent: *Agent,
    item: Value,
    maybe_options_value: ?Value,
) Agent.Error!*PlainTime {
    // 1. If options is not present, set options to undefined.
    const options_value: Value = maybe_options_value orelse .undefined;

    // 2. If item is an Object, then
    const temporal_rs_plain_time = if (item.isObject()) blk: {
        // a. If item has an [[InitializedTemporalTime]] internal slot, then
        if (item.asObject().cast(builtins.temporal.PlainTime)) |plain_time| {
            // i. Let resolvedOptions be ? GetOptionsObject(options).
            const options = try options_value.getOptionsObject(agent);

            // ii. Perform ? GetTemporalOverflowOption(resolvedOptions).
            _ = try getTemporalOverflowOption(agent, options);

            // iii. Return ! CreateTemporalTime(item.[[Time]]).
            break :blk temporal_rs.c.temporal_rs_PlainTime_clone(plain_time.fields.inner);
        }

        // b. If item has an [[InitializedTemporalDateTime]] internal slot, then
        if (item.asObject().cast(builtins.temporal.PlainDateTime)) |plain_date_time| {
            // i. Let resolvedOptions be ? GetOptionsObject(options).
            const options = try options_value.getOptionsObject(agent);

            // ii. Perform ? GetTemporalOverflowOption(resolvedOptions).
            _ = try getTemporalOverflowOption(agent, options);

            // iii. Return ! CreateTemporalTime(item.[[ISODateTime]].[[Time]]).
            break :blk temporal_rs.c.temporal_rs_PlainDateTime_to_plain_time(
                plain_date_time.fields.inner,
            );
        }

        // c. If item has an [[InitializedTemporalZonedDateTime]] internal slot, then
        if (item.asObject().cast(builtins.temporal.ZonedDateTime)) |zoned_date_time| {
            // i. Let isoDateTime be GetISODateTimeFor(item.[[TimeZone]],
            //    item.[[EpochNanoseconds]]).

            // ii. Let resolvedOptions be ? GetOptionsObject(options).
            const options = try options_value.getOptionsObject(agent);

            // iii. Perform ? GetTemporalOverflowOption(resolvedOptions).
            _ = try getTemporalOverflowOption(agent, options);

            // iv. Return ! CreateTemporalTime(isoDateTime.[[Time]]).
            break :blk temporal_rs.c.temporal_rs_ZonedDateTime_to_plain_time(
                zoned_date_time.fields.inner,
            );
        }

        // d. Let result be ? ToTemporalTimeRecord(item).
        const result = try toTemporalTimeRecord(agent, item.asObject(), .complete);

        // e. Let resolvedOptions be ? GetOptionsObject(options).
        const options = try options_value.getOptionsObject(agent);

        // f. Let overflow be ? GetTemporalOverflowOption(resolvedOptions).
        const overflow = try getTemporalOverflowOption(agent, options);

        // g. Set result to ? RegulateTime(result.[[Hour]], result.[[Minute]], result.[[Second]],
        //    result.[[Millisecond]], result.[[Microsecond]], result.[[Nanosecond]], overflow).
        const partial = try result.regulate(agent, overflow);
        break :blk try builtins.temporal.extractResult(
            agent,
            temporal_rs.c.temporal_rs_PlainTime_from_partial(
                partial,
                temporal_rs.toArithmeticOverflowOption(overflow),
            ),
        );
    } else blk: {
        // 3. Else,

        // a. If item is not a String, throw a TypeError exception.
        if (!item.isString()) {
            return agent.throwException(
                .type_error,
                "Plain time must be a string or object",
                .{},
            );
        }

        // b. Let parseResult be ? ParseISODateTime(item, « TemporalTimeString »).
        // c. Assert: parseResult.[[Time]] is not start-of-day.
        // d. Set result to parseResult.[[Time]].
        // e. NOTE: A successful parse using TemporalTimeString guarantees absence of ambiguity with
        //    respect to any ISO 8601 date-only, year-month, or month-day representation.
        const temporal_rs_plain_time = switch (item.asString().asAsciiOrUtf16()) {
            .ascii => |ascii| try builtins.temporal.extractResult(
                agent,
                temporal_rs.c.temporal_rs_PlainTime_from_utf8(
                    temporal_rs.toDiplomatStringView(ascii),
                ),
            ),
            .utf16 => |utf16| try builtins.temporal.extractResult(
                agent,
                temporal_rs.c.temporal_rs_PlainTime_from_utf16(
                    temporal_rs.toDiplomatString16View(utf16),
                ),
            ),
        };

        // f. Let resolvedOptions be ? GetOptionsObject(options).
        const options = try options_value.getOptionsObject(agent);

        // g. Perform ? GetTemporalOverflowOption(resolvedOptions).
        _ = try getTemporalOverflowOption(agent, options);

        break :blk temporal_rs_plain_time;
    };
    errdefer temporal_rs.c.temporal_rs_PlainTime_destroy(temporal_rs_plain_time.?);

    // 4. Return ! CreateTemporalTime(result).
    return createTemporalTime(
        agent,
        temporal_rs_plain_time.?,
        null,
    ) catch |err| try noexcept(err);
}

/// 4.5.7 ToTimeRecordOrMidnight ( item )
/// https://tc39.es/proposal-temporal/#sec-temporal-totimerecordormidnight
pub fn toTimeRecordOrMidnight(agent: *Agent, item: Value) Agent.Error!?*temporal_rs.c.PlainTime {
    // 1. If item is undefined, return MidnightTimeRecord().
    if (item.isUndefined()) return null;

    // 2. Let plainTime be ? ToTemporalTime(item).
    const plain_time = try toTemporalPlainTime(agent, item, null);

    // 3. Return plainTime.[[Time]].
    return temporal_rs.c.temporal_rs_PlainTime_clone(plain_time.fields.inner);
}

/// Table 5: TemporalTimeLike Record Fields
/// https://tc39.es/proposal-temporal/#table-temporal-temporaltimelike-record-fields
const TemporalTimeLike = struct {
    hour: ?f64,
    minute: ?f64,
    second: ?f64,
    millisecond: ?f64,
    microsecond: ?f64,
    nanosecond: ?f64,

    /// 4.5.8 RegulateTime ( hour, minute, second, millisecond, microsecond, nanosecond, overflow )
    /// https://tc39.es/proposal-temporal/#sec-temporal-regulatetime
    fn regulate(
        self: TemporalTimeLike,
        agent: *Agent,
        overflow: temporal_rs.c.ArithmeticOverflow,
    ) Agent.Error!temporal_rs.c.PartialTime {
        var partial: temporal_rs.c.PartialTime = .{};

        // 1. If overflow is constrain, then
        if (overflow == temporal_rs.c.ArithmeticOverflow_Constrain) {
            // a. Set hour to the result of clamping hour between 0 and 23.
            if (self.hour) |hour| {
                partial.hour = temporal_rs.toOption(
                    temporal_rs.c.OptionU8,
                    @intFromFloat(std.math.clamp(hour, 0, 23)),
                );
            }

            // b. Set minute to the result of clamping minute between 0 and 59.
            if (self.minute) |minute| {
                partial.minute = temporal_rs.toOption(
                    temporal_rs.c.OptionU8,
                    @intFromFloat(std.math.clamp(minute, 0, 59)),
                );
            }

            // c. Set second to the result of clamping second between 0 and 59.
            if (self.second) |second| {
                partial.second = temporal_rs.toOption(
                    temporal_rs.c.OptionU8,
                    @intFromFloat(std.math.clamp(second, 0, 59)),
                );
            }

            // d. Set millisecond to the result of clamping millisecond between 0 and 999.
            if (self.millisecond) |millisecond| {
                partial.millisecond = temporal_rs.toOption(
                    temporal_rs.c.OptionU16,
                    @intFromFloat(std.math.clamp(millisecond, 0, 999)),
                );
            }

            // e. Set microsecond to the result of clamping microsecond between 0 and 999.
            if (self.microsecond) |microsecond| {
                partial.microsecond = temporal_rs.toOption(
                    temporal_rs.c.OptionU16,
                    @intFromFloat(std.math.clamp(microsecond, 0, 999)),
                );
            }

            // f. Set nanosecond to the result of clamping nanosecond between 0 and 999.
            if (self.nanosecond) |nanosecond| {
                partial.nanosecond = temporal_rs.toOption(
                    temporal_rs.c.OptionU16,
                    @intFromFloat(std.math.clamp(nanosecond, 0, 999)),
                );
            }
        } else {
            // 2. Else,
            // a. Assert: overflow is reject.
            std.debug.assert(overflow == temporal_rs.c.ArithmeticOverflow_Reject);

            // b. If IsValidTime(hour, minute, second, millisecond, microsecond, nanosecond) is
            //    false, throw a RangeError exception.
            if (!isValidTime(
                self.hour orelse 0,
                self.minute orelse 0,
                self.second orelse 0,
                self.millisecond orelse 0,
                self.microsecond orelse 0,
                self.nanosecond orelse 0,
            )) {
                return agent.throwException(.range_error, "Invalid time", .{});
            }

            if (self.hour) |hour| {
                partial.hour = temporal_rs.toOption(temporal_rs.c.OptionU8, @intFromFloat(hour));
            }
            if (self.minute) |minute| {
                partial.minute = temporal_rs.toOption(temporal_rs.c.OptionU8, @intFromFloat(minute));
            }
            if (self.second) |second| {
                partial.second = temporal_rs.toOption(temporal_rs.c.OptionU8, @intFromFloat(second));
            }
            if (self.millisecond) |millisecond| {
                partial.millisecond = temporal_rs.toOption(temporal_rs.c.OptionU16, @intFromFloat(millisecond));
            }
            if (self.microsecond) |microsecond| {
                partial.microsecond = temporal_rs.toOption(temporal_rs.c.OptionU16, @intFromFloat(microsecond));
            }
            if (self.nanosecond) |nanosecond| {
                partial.nanosecond = temporal_rs.toOption(temporal_rs.c.OptionU16, @intFromFloat(nanosecond));
            }
        }

        // 3. Return CreateTimeRecord(hour, minute, second, millisecond, microsecond,nanosecond).
        return partial;
    }
};

/// 4.5.9 IsValidTime ( hour, minute, second, millisecond, microsecond, nanosecond )
/// https://tc39.es/proposal-temporal/#sec-temporal-isvalidtime
pub fn isValidTime(
    hour: f64,
    minute: f64,
    second: f64,
    millisecond: f64,
    microsecond: f64,
    nanosecond: f64,
) bool {
    // 1. If hour < 0 or hour > 23, return false.
    if (hour < 0 or hour > 23) return false;

    // 2. If minute < 0 or minute > 59, return false.
    if (minute < 0 or minute > 59) return false;

    // 3. If second < 0 or second > 59, return false.
    if (second < 0 or second > 59) return false;

    // 4. If millisecond < 0 or millisecond > 999, return false.
    if (millisecond < 0 or millisecond > 999) return false;

    // 5. If microsecond < 0 or microsecond > 999, return false.
    if (microsecond < 0 or microsecond > 999) return false;

    // 6. If nanosecond < 0 or nanosecond > 999, return false.
    if (nanosecond < 0 or nanosecond > 999) return false;

    // 7. Return true.
    return true;
}

/// 4.5.12 ToTemporalTimeRecord ( temporalTimeLike [ , completeness ] )
/// https://tc39.es/proposal-temporal/#sec-temporal-totemporaltimerecord
fn toTemporalTimeRecord(
    agent: *Agent,
    temporal_time_like: *Object,
    completeness: enum { partial, complete },
) Agent.Error!TemporalTimeLike {
    // 1. If completeness is not present, set completeness to complete.

    // 2. If completeness is complete, then
    //     a. Let result be a new TemporalTimeLike Record with each field set to 0.
    // 3. Else,
    //     a. Let result be a new TemporalTimeLike Record with each field set to unset.
    var result: TemporalTimeLike = switch (completeness) {
        .complete => .{
            .hour = 0,
            .minute = 0,
            .second = 0,
            .millisecond = 0,
            .microsecond = 0,
            .nanosecond = 0,
        },
        .partial => .{
            .hour = null,
            .minute = null,
            .second = null,
            .millisecond = null,
            .microsecond = null,
            .nanosecond = null,
        },
    };

    // 4. Let any be false.
    var any = false;

    // 5. Let hour be ? Get(temporalTimeLike, "hour").
    const hour = try temporal_time_like.get(agent, PropertyKey.from("hour"));

    // 6. If hour is not undefined, then
    if (!hour.isUndefined()) {
        // a. Set result.[[Hour]] to ? ToIntegerWithTruncation(hour).
        result.hour = try hour.toIntegerWithTruncation(agent);

        // b. Set any to true.
        any = true;
    }

    // 7. Let microsecond be ? Get(temporalTimeLike, "microsecond").
    const microsecond = try temporal_time_like.get(agent, PropertyKey.from("microsecond"));

    // 8. If microsecond is not undefined, then
    if (!microsecond.isUndefined()) {
        // a. Set result.[[Microsecond]] to ? ToIntegerWithTruncation(microsecond).
        result.microsecond = try microsecond.toIntegerWithTruncation(agent);

        // b. Set any to true.
        any = true;
    }

    // 9. Let millisecond be ? Get(temporalTimeLike, "millisecond").
    const millisecond = try temporal_time_like.get(agent, PropertyKey.from("millisecond"));

    // 10. If millisecond is not undefined, then
    if (!millisecond.isUndefined()) {
        // a. Set result.[[Millisecond]] to ? ToIntegerWithTruncation(millisecond).
        result.millisecond = try millisecond.toIntegerWithTruncation(agent);

        // b. Set any to true.
        any = true;
    }

    // 11. Let minute be ? Get(temporalTimeLike, "minute").
    const minute = try temporal_time_like.get(agent, PropertyKey.from("minute"));

    // 12. If minute is not undefined, then
    if (!minute.isUndefined()) {
        // a. Set result.[[Minute]] to ? ToIntegerWithTruncation(minute).
        result.minute = try minute.toIntegerWithTruncation(agent);

        // b. Set any to true.
        any = true;
    }

    // 13. Let nanosecond be ? Get(temporalTimeLike, "nanosecond").
    const nanosecond = try temporal_time_like.get(agent, PropertyKey.from("nanosecond"));

    // 14. If nanosecond is not undefined, then
    if (!nanosecond.isUndefined()) {
        // a. Set result.[[Nanosecond]] to ? ToIntegerWithTruncation(nanosecond).
        result.nanosecond = try nanosecond.toIntegerWithTruncation(agent);

        // b. Set any to true.
        any = true;
    }

    // 15. Let second be ? Get(temporalTimeLike, "second").
    const second = try temporal_time_like.get(agent, PropertyKey.from("second"));

    // 16. If second is not undefined, then
    if (!second.isUndefined()) {
        // a. Set result.[[Second]] to ? ToIntegerWithTruncation(second).
        result.second = try second.toIntegerWithTruncation(agent);

        // b. Set any to true.
        any = true;
    }

    // 17. If any is false, throw a TypeError exception.
    if (!any) {
        return agent.throwException(.type_error, "Missing plain time field", .{});
    }

    // 18. Return result.
    return result;
}

/// 4.5.17 DifferenceTemporalPlainTime ( operation, temporalTime, other, options )
/// https://tc39.es/proposal-temporal/#sec-temporal-differencetemporalplaintime
fn differenceTemporalPlainTime(
    agent: *Agent,
    operation: enum { since, until },
    plain_time: *const PlainTime,
    other_value: Value,
    options_value: Value,
) Agent.Error!*builtins.temporal.Duration {
    // 1. Set other to ? ToTemporalTime(other).
    const other = try toTemporalPlainTime(agent, other_value, null);

    // 2. Let resolvedOptions be ? GetOptionsObject(options).
    const options = try options_value.getOptionsObject(agent);

    // 3. Let settings be ? GetDifferenceSettings(operation, resolvedOptions, time, « », nanosecond,
    //    hour).
    const settings = try getTemporalDifferenceSettingsWithoutValidation(agent, options);

    // 4. Let timeDuration be DifferenceTime(temporalTime.[[Time]], other.[[Time]]).
    // 5. Set timeDuration to ! RoundTimeDuration(timeDuration, settings.[[RoundingIncrement]],
    //    settings.[[SmallestUnit]], settings.[[RoundingMode]]).
    // 6. Let duration be CombineDateAndTimeDuration(ZeroDateDuration(), timeDuration).
    // 7. Let result be ! TemporalDurationFromInternal(duration, settings.[[LargestUnit]]).
    // 8. If operation is since, set result to CreateNegatedTemporalDuration(result).
    // 9. Return result.
    const temporal_rs_duration = switch (operation) {
        .since => try builtins.temporal.extractResult(
            agent,
            temporal_rs.c.temporal_rs_PlainTime_since(
                plain_time.fields.inner,
                other.fields.inner,
                settings,
            ),
        ),
        .until => try builtins.temporal.extractResult(
            agent,
            temporal_rs.c.temporal_rs_PlainTime_until(
                plain_time.fields.inner,
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

/// 4.5.18 AddDurationToTime ( operation, temporalTime, temporalDurationLike )
/// https://tc39.es/proposal-temporal/#sec-temporal-adddurationtotime
fn addDurationToTime(
    agent: *Agent,
    operation: enum { add, subtract },
    plain_time: *const PlainTime,
    temporal_duration_like: Value,
) Agent.Error!*PlainTime {
    // 1. Let duration be ? ToTemporalDuration(temporalDurationLike).
    const duration = try toTemporalDuration(agent, temporal_duration_like);

    // 2. If operation is subtract, set duration to CreateNegatedTemporalDuration(duration).
    // 3. Let internalDuration be ToInternalDurationRecord(duration).
    // 4. Let result be AddTime(temporalTime.[[Time]], internalDuration.[[Time]]).
    const temporal_rs_plain_time = switch (operation) {
        .add => try builtins.temporal.extractResult(
            agent,
            temporal_rs.c.temporal_rs_PlainTime_add(
                plain_time.fields.inner,
                duration.fields.inner,
            ),
        ),
        .subtract => try builtins.temporal.extractResult(
            agent,
            temporal_rs.c.temporal_rs_PlainTime_subtract(
                plain_time.fields.inner,
                duration.fields.inner,
            ),
        ),
    };
    errdefer temporal_rs.c.temporal_rs_PlainTime_destroy(temporal_rs_plain_time.?);

    // 5. Return ! CreateTemporalTime(result).
    return createTemporalTime(
        agent,
        temporal_rs_plain_time.?,
        null,
    ) catch |err| try noexcept(err);
}
