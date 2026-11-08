//! 8 Temporal.Instant Objects
//! https://tc39.es/proposal-temporal/#sec-temporal-instant-objects

const std = @import("std");

const temporal_rs = @import("temporal_rs");

const builtins = @import("../../builtins.zig");
const execution = @import("../../execution.zig");
const types = @import("../../types.zig");
const utils = @import("../../utils.zig");

const Agent = execution.Agent;
const Arguments = types.Arguments;
const BigInt = types.BigInt;
const MakeObject = types.MakeObject;
const Object = types.Object;
const PropertyKey = types.PropertyKey;
const Realm = execution.Realm;
const String = types.String;
const Value = types.Value;
const createBuiltinFunction = builtins.createBuiltinFunction;
const createTemporalDuration = builtins.createTemporalDuration;
const createTemporalZonedDateTime = builtins.createTemporalZonedDateTime;
const getTemporalDifferenceSettingsWithoutValidation = builtins.getTemporalDifferenceSettingsWithoutValidation;
const getTemporalFractionalSecondDigitsOption = builtins.getTemporalFractionalSecondDigitsOption;
const getTemporalRoundingIncrementOption = builtins.getTemporalRoundingIncrementOption;
const getTemporalRoundingModeOption = builtins.getTemporalRoundingModeOption;
const getTemporalUnitValuedOption = builtins.getTemporalUnitValuedOption;
const noexcept = utils.noexcept;
const numberToBigInt = builtins.numberToBigInt;
const ordinaryCreateFromConstructor = builtins.ordinaryCreateFromConstructor;
const ordinaryObjectCreate = builtins.ordinaryObjectCreate;
const toTemporalDuration = builtins.toTemporalDuration;
const toTemporalTimeZoneIdentifier = builtins.toTemporalTimeZoneIdentifier;
const validateTemporalUnitValue = builtins.validateTemporalUnitValue;

/// 8.2 Properties of the Temporal.Instant Constructor
/// https://tc39.es/proposal-temporal/#sec-properties-of-the-temporal-instant-constructor
pub const constructor = struct {
    pub fn create(agent: *Agent, realm: *Realm) std.mem.Allocator.Error!*Object {
        const builtin_function = try createBuiltinFunction(
            agent,
            .{ .constructor = impl },
            1,
            "Instant",
            .{ .realm = realm, .proto = try realm.intrinsic(.function_prototype) },
        );
        return &builtin_function.object;
    }

    pub fn init(agent: *Agent, realm: *Realm, object: *Object) std.mem.Allocator.Error!void {
        try object.defineBuiltinFunction(agent, "compare", compare, 2, realm);
        try object.defineBuiltinFunction(agent, "from", from, 1, realm);
        try object.defineBuiltinFunction(agent, "fromEpochMilliseconds", fromEpochMilliseconds, 1, realm);
        try object.defineBuiltinFunction(agent, "fromEpochNanoseconds", fromEpochNanoseconds, 1, realm);

        // 8.2.1 Temporal.Instant.prototype
        // https://tc39.es/proposal-temporal/#sec-temporal.instant.prototype
        try object.defineBuiltinPropertyWithAttributes(
            agent,
            "prototype",
            Value.from(try realm.intrinsic(.temporal_instant_prototype)),
            .{
                .writable = false,
                .enumerable = false,
                .configurable = false,
            },
        );
    }

    /// 8.1.1 Temporal.Instant ( epochNanoseconds )
    /// https://tc39.es/proposal-temporal/#sec-temporal.instant
    fn impl(agent: *Agent, arguments: Arguments, maybe_new_target: ?*Object) Agent.Error!Value {
        const epoch_nanoseconds_value = arguments.get(0);

        // 1. If NewTarget is undefined, throw a TypeError exception.
        const new_target = maybe_new_target orelse {
            return agent.throwException(
                .type_error,
                "Temporal.Instant must be constructed with 'new'",
                .{},
            );
        };

        // 2. Let epochNanoseconds be ? ToBigInt(epochNanoseconds).
        const epoch_nanoseconds_bigint = try epoch_nanoseconds_value.toBigInt(agent);
        const epoch_nanoseconds = temporal_rs.toI128Nanoseconds(
            epoch_nanoseconds_bigint.managed.toInt(i128) catch std.math.maxInt(i128),
        );

        // 3. If IsValidEpochNanoseconds(epochNanoseconds) is false, throw a RangeError exception.
        if (!temporal_rs.c.temporal_rs_I128Nanoseconds_is_valid(epoch_nanoseconds)) {
            return agent.throwException(
                .range_error,
                "Invalid epoch nanoseconds {f}",
                .{epoch_nanoseconds_bigint.managed},
            );
        }

        // 4. Return ? CreateTemporalInstant(epochNanoseconds, NewTarget).
        const temporal_rs_instant = try builtins.temporal.extractResult(
            agent,
            temporal_rs.c.temporal_rs_Instant_try_new(epoch_nanoseconds),
        );
        errdefer temporal_rs.c.temporal_rs_Instant_destroy(temporal_rs_instant.?);
        const instant = try createTemporalInstant(agent, temporal_rs_instant.?, new_target);
        return Value.from(&instant.object);
    }

    /// 8.2.5 Temporal.Instant.compare ( one, two )
    /// https://tc39.es/proposal-temporal/#sec-temporal.instant.compare
    fn compare(agent: *Agent, _: Value, arguments: Arguments) Agent.Error!Value {
        const one_value = arguments.get(0);
        const two_value = arguments.get(1);

        // 1. Set one to ? ToTemporalInstant(one).
        const one = try toTemporalInstant(agent, one_value);

        // 2. Set two to ? ToTemporalInstant(two).
        const two = try toTemporalInstant(agent, two_value);

        // 3. Return 𝔽(CompareEpochNanoseconds(one.[[EpochNanoseconds]], two.[[EpochNanoseconds]])).
        return Value.from(
            temporal_rs.c.temporal_rs_Instant_compare(one.fields.inner, two.fields.inner),
        );
    }

    /// 8.2.2 Temporal.Instant.from ( item )
    /// https://tc39.es/proposal-temporal/#sec-temporal.instant.from
    fn from(agent: *Agent, _: Value, arguments: Arguments) Agent.Error!Value {
        const item = arguments.get(0);

        // 1. Return ? ToTemporalInstant(item).
        const instant = try toTemporalInstant(agent, item);
        return Value.from(&instant.object);
    }

    /// 8.2.3 Temporal.Instant.fromEpochMilliseconds ( epochMilliseconds )
    /// https://tc39.es/proposal-temporal/#sec-temporal.instant.fromepochmilliseconds
    fn fromEpochMilliseconds(agent: *Agent, _: Value, arguments: Arguments) Agent.Error!Value {
        const epoch_milliseconds_value = arguments.get(0);

        // 1. Set epochMilliseconds to ? ToNumber(epochMilliseconds).
        const epoch_milliseconds_number = try epoch_milliseconds_value.toNumber(agent);

        // 2. Set epochMilliseconds to ? NumberToBigInt(epochMilliseconds).
        const epoch_milliseconds_bigint = try numberToBigInt(agent, epoch_milliseconds_number);
        const epoch_milliseconds = epoch_milliseconds_bigint.managed.toInt(i64) catch std.math.maxInt(i64);

        // 3. Let epochNanoseconds be epochMilliseconds × ℤ(10**6).
        // 4. If IsValidEpochNanoseconds(epochNanoseconds) is false, throw a RangeError exception.
        // 5. Return ! CreateTemporalInstant(epochNanoseconds).
        const temporal_rs_instant = try builtins.temporal.extractResult(
            agent,
            temporal_rs.c.temporal_rs_Instant_from_epoch_milliseconds(epoch_milliseconds),
        );
        errdefer temporal_rs.c.temporal_rs_Instant_destroy(temporal_rs_instant.?);
        const instant = createTemporalInstant(
            agent,
            temporal_rs_instant.?,
            null,
        ) catch |err| try noexcept(err);
        return Value.from(&instant.object);
    }

    /// 8.2.4 Temporal.Instant.fromEpochNanoseconds ( epochNanoseconds )
    /// https://tc39.es/proposal-temporal/#sec-temporal.instant.fromepochnanoseconds
    fn fromEpochNanoseconds(agent: *Agent, _: Value, arguments: Arguments) Agent.Error!Value {
        const epoch_nanoseconds_value = arguments.get(0);

        // 1. Set epochNanoseconds to ? ToBigInt(epochNanoseconds).
        const epoch_nanoseconds_bigint = try epoch_nanoseconds_value.toBigInt(agent);
        const epoch_nanoseconds = temporal_rs.toI128Nanoseconds(
            epoch_nanoseconds_bigint.managed.toInt(i128) catch std.math.maxInt(i128),
        );

        // 2. If IsValidEpochNanoseconds(epochNanoseconds) is false, throw a RangeError exception.
        // 3. Return ! CreateTemporalInstant(epochNanoseconds).
        const temporal_rs_instant = try builtins.temporal.extractResult(
            agent,
            temporal_rs.c.temporal_rs_Instant_try_new(epoch_nanoseconds),
        );
        errdefer temporal_rs.c.temporal_rs_Instant_destroy(temporal_rs_instant.?);
        const instant = createTemporalInstant(
            agent,
            temporal_rs_instant.?,
            null,
        ) catch |err| try noexcept(err);
        return Value.from(&instant.object);
    }
};

/// 8.3 Properties of the Temporal.Instant Prototype Object
/// https://tc39.es/proposal-temporal/#sec-properties-of-the-temporal-instant-prototype-object
pub const prototype = struct {
    pub fn create(agent: *Agent, realm: *Realm) std.mem.Allocator.Error!*Object {
        return ordinaryObjectCreate(agent, try realm.intrinsic(.object_prototype));
    }

    pub fn init(agent: *Agent, realm: *Realm, object: *Object) std.mem.Allocator.Error!void {
        try object.defineBuiltinFunction(agent, "add", add, 1, realm);
        try object.defineBuiltinAccessor(agent, "epochMilliseconds", epochMilliseconds, null, realm);
        try object.defineBuiltinAccessor(agent, "epochNanoseconds", epochNanoseconds, null, realm);
        try object.defineBuiltinFunction(agent, "equals", equals, 1, realm);
        try object.defineBuiltinFunction(agent, "round", round, 1, realm);
        try object.defineBuiltinFunction(agent, "since", since, 1, realm);
        try object.defineBuiltinFunction(agent, "subtract", subtract, 1, realm);
        try object.defineBuiltinFunction(agent, "toJSON", toJSON, 0, realm);
        try object.defineBuiltinFunction(agent, "toLocaleString", toLocaleString, 0, realm);
        try object.defineBuiltinFunction(agent, "toString", toString, 0, realm);
        try object.defineBuiltinFunction(agent, "toZonedDateTimeISO", toZonedDateTimeISO, 1, realm);
        try object.defineBuiltinFunction(agent, "until", until, 1, realm);
        try object.defineBuiltinFunction(agent, "valueOf", valueOf, 0, realm);

        // 8.3.1 Temporal.Instant.prototype.constructor
        // https://tc39.es/proposal-temporal/#sec-temporal.instant.prototype.constructor
        try object.defineBuiltinProperty(
            agent,
            "constructor",
            Value.from(try realm.intrinsic(.temporal_instant)),
        );

        // 8.3.2 Temporal.Instant.prototype[ %Symbol.toStringTag% ]
        // https://tc39.es/proposal-temporal/#sec-temporal.instant.prototype-%symbol.tostringtag%
        try object.defineBuiltinPropertyWithAttributes(
            agent,
            "Symbol.toStringTag",
            Value.from("Temporal.Instant"),
            .{
                .writable = false,
                .enumerable = false,
                .configurable = true,
            },
        );
    }

    /// 8.3.5 Temporal.Instant.prototype.add ( temporalDurationLike )
    /// https://tc39.es/proposal-temporal/#sec-temporal.instant.prototype.add
    fn add(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const temporal_duration_like = arguments.get(0);

        // 1. Let instant be the this value.
        // 2. Perform ? RequireInternalSlot(instant, [[InitializedTemporalInstant]]).
        const instant = try this_value.requireInternalSlot(agent, Instant);

        // 3. Return ? AddDurationToInstant(add, instant, temporalDurationLike).
        const new_instant = try addDurationToInstant(
            agent,
            .add,
            instant,
            temporal_duration_like,
        );
        return Value.from(&new_instant.object);
    }

    /// 8.3.3 get Temporal.Instant.prototype.epochMilliseconds
    /// https://tc39.es/proposal-temporal/#sec-get-temporal.instant.prototype.epochmilliseconds
    fn epochMilliseconds(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let instant be the this value.
        // 2. Perform ? RequireInternalSlot(instant, [[InitializedTemporalInstant]]).
        const instant = try this_value.requireInternalSlot(agent, Instant);

        // 3. Let ns be instant.[[EpochNanoseconds]].
        // 4. Let ms be floor(ℝ(ns) / 10**6).
        const ms = temporal_rs.c.temporal_rs_Instant_epoch_milliseconds(instant.fields.inner);

        // 5. Return 𝔽(ms).
        return Value.from(@as(f64, @floatFromInt(ms)));
    }

    /// 8.3.4 get Temporal.Instant.prototype.epochNanoseconds
    /// https://tc39.es/proposal-temporal/#sec-get-temporal.instant.prototype.epochnanoseconds
    fn epochNanoseconds(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let instant be the this value.
        // 2. Perform ? RequireInternalSlot(instant, [[InitializedTemporalInstant]]).
        const instant = try this_value.requireInternalSlot(agent, Instant);

        // 3. Return instant.[[EpochNanoseconds]].
        const ns = temporal_rs.fromI128Nanoseconds(
            temporal_rs.c.temporal_rs_Instant_epoch_nanoseconds(instant.fields.inner),
        );
        return Value.from(try BigInt.fromValue(agent, ns));
    }

    /// 8.3.10 Temporal.Instant.prototype.equals ( other )
    /// https://tc39.es/proposal-temporal/#sec-temporal.instant.prototype.equals
    fn equals(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const other_value = arguments.get(0);

        // 1. Let instant be the this value.
        // 2. Perform ? RequireInternalSlot(instant, [[InitializedTemporalInstant]]).
        const instant = try this_value.requireInternalSlot(agent, Instant);

        // 3. Set other to ? ToTemporalInstant(other).
        const other = try toTemporalInstant(agent, other_value);

        // 4. If instant.[[EpochNanoseconds]] ≠ other.[[EpochNanoseconds]], return false.
        // 5. Return true.
        return Value.from(
            temporal_rs.c.temporal_rs_Instant_equals(
                instant.fields.inner,
                other.fields.inner,
            ),
        );
    }

    /// 8.3.9 Temporal.Instant.prototype.round ( roundTo )
    /// https://tc39.es/proposal-temporal/#sec-temporal.instant.prototype.round
    fn round(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const round_to = arguments.get(0);

        // 1. Let instant be the this value.
        // 2. Perform ? RequireInternalSlot(instant, [[InitializedTemporalInstant]]).
        const instant = try this_value.requireInternalSlot(agent, Instant);

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

        // 11. If smallestUnit is hour, then
        //     a. Let maximum be HoursPerDay.
        // 12. Else if smallestUnit is minute, then
        //     a. Let maximum be MinutesPerHour × HoursPerDay.
        // 13. Else if smallestUnit is second, then
        //     a. Let maximum be SecondsPerMinute × MinutesPerHour × HoursPerDay.
        // 14. Else if smallestUnit is millisecond, then
        //     a. Let maximum be ℝ(msPerDay).
        // 15. Else if smallestUnit is microsecond, then
        //     a. Let maximum be 10**3 × ℝ(msPerDay).
        // 16. Else,
        //     a. Assert: smallestUnit is nanosecond.
        //     b. Let maximum be nsPerDay.
        // 17. Perform ? ValidateTemporalRoundingIncrement(roundingIncrement, maximum, true).
        // 18. Let roundedNs be RoundTemporalInstant(instant.[[EpochNanoseconds]],
        //     roundingIncrement, smallestUnit, roundingMode).
        // 19. Return ! CreateTemporalInstant(roundedNs).
        const temporal_rs_instant = try builtins.temporal.extractResult(
            agent,
            temporal_rs.c.temporal_rs_Instant_round(
                instant.fields.inner,
                .{
                    .largest_unit = temporal_rs.toUnitOption(null),
                    .smallest_unit = temporal_rs.toUnitOption(smallest_unit),
                    .rounding_mode = temporal_rs.toRoundingModeOption(rounding_mode),
                    .increment = temporal_rs.toOption(temporal_rs.c.OptionU32, rounding_increment),
                },
            ),
        );
        errdefer temporal_rs.c.temporal_rs_Instant_destroy(temporal_rs_instant.?);
        const new_instant = createTemporalInstant(
            agent,
            temporal_rs_instant.?,
            null,
        ) catch |err| try noexcept(err);
        return Value.from(&new_instant.object);
    }

    /// 8.3.8 Temporal.Instant.prototype.since ( other [ , options ] )
    /// https://tc39.es/proposal-temporal/#sec-temporal.instant.prototype.since
    fn since(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const other = arguments.get(0);
        const options = arguments.get(1);

        // 1. Let instant be the this value.
        // 2. Perform ? RequireInternalSlot(instant, [[InitializedTemporalInstant]]).
        const instant = try this_value.requireInternalSlot(agent, Instant);

        // 3. Return ? DifferenceTemporalInstant(since, instant, other, options).
        const duration = try differenceTemporalInstant(agent, .since, instant, other, options);
        return Value.from(&duration.object);
    }

    /// 8.3.6 Temporal.Instant.prototype.subtract ( temporalDurationLike )
    /// https://tc39.es/proposal-temporal/#sec-temporal.instant.prototype.subtract
    fn subtract(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const temporal_duration_like = arguments.get(0);

        // 1. Let instant be the this value.
        // 2. Perform ? RequireInternalSlot(instant, [[InitializedTemporalInstant]]).
        const instant = try this_value.requireInternalSlot(agent, Instant);

        // 3. Return ? AddDurationToInstant(subtract, instant, temporalDurationLike).
        const new_instant = try addDurationToInstant(
            agent,
            .subtract,
            instant,
            temporal_duration_like,
        );
        return Value.from(&new_instant.object);
    }

    /// 8.3.13 Temporal.Instant.prototype.toJSON ( )
    /// https://tc39.es/proposal-temporal/#sec-temporal.instant.prototype.tojson
    fn toJSON(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let instant be the this value.
        // 2. Perform ? RequireInternalSlot(instant, [[InitializedTemporalInstant]]).
        const instant = try this_value.requireInternalSlot(agent, Instant);

        // 3. Return TemporalInstantToString(instant, undefined, auto).
        var write = temporal_rs.DiplomatWrite.init(agent.gc_allocator);
        try builtins.temporal.extractResult(
            agent,
            temporal_rs.c.temporal_rs_Instant_to_ixdtf_string_with_compiled_data(
                instant.fields.inner,
                temporal_rs.toTimeZoneOption(null),
                temporal_rs.to_string_rounding_options_auto,
                &write.inner,
            ),
        );
        return Value.from(try String.fromAscii(agent, try write.toOwnedSlice()));
    }

    /// 8.3.12 Temporal.Instant.prototype.toLocaleString ( [ locales [ , options ] ] )
    /// https://tc39.es/proposal-temporal/#sec-temporal.instant.prototype.tolocalestring
    fn toLocaleString(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let instant be the this value.
        // 2. Perform ? RequireInternalSlot(instant, [[InitializedTemporalInstant]]).
        const instant = try this_value.requireInternalSlot(agent, Instant);

        // 3. Return TemporalInstantToString(instant, undefined, auto).
        var write = temporal_rs.DiplomatWrite.init(agent.gc_allocator);
        try builtins.temporal.extractResult(
            agent,
            temporal_rs.c.temporal_rs_Instant_to_ixdtf_string_with_compiled_data(
                instant.fields.inner,
                temporal_rs.toTimeZoneOption(null),
                temporal_rs.to_string_rounding_options_auto,
                &write.inner,
            ),
        );
        return Value.from(try String.fromAscii(agent, try write.toOwnedSlice()));
    }

    /// 8.3.11 Temporal.Instant.prototype.toString ( [ options ] )
    /// https://tc39.es/proposal-temporal/#sec-temporal.instant.prototype.tostring
    fn toString(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const options_value = arguments.get(0);

        // 1. Let instant be the this value.
        // 2. Perform ? RequireInternalSlot(instant, [[InitializedTemporalInstant]]).
        const instant = try this_value.requireInternalSlot(agent, Instant);

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

        // 8. Let timeZone be ? Get(resolvedOptions, "timeZone").
        const time_zone_value = try options.get(agent, PropertyKey.from("timeZone"));

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

        var time_zone: ?temporal_rs.c.TimeZone = null;

        // 11. If timeZone is not undefined, then
        if (!time_zone_value.isUndefined()) {
            // a. Set timeZone to ? ToTemporalTimeZoneIdentifier(timeZone).
            time_zone = try toTemporalTimeZoneIdentifier(agent, time_zone_value);
        }

        // 12. Let precision be ToSecondsStringPrecisionRecord(smallestUnit, digits).
        // 13. Let roundedNs be RoundTemporalInstant(instant.[[EpochNanoseconds]],
        //     precision.[[Increment]], precision.[[Unit]], roundingMode).
        // 14. Let roundedInstant be ! CreateTemporalInstant(roundedNs).
        // 15. Return TemporalInstantToString(roundedInstant, timeZone, precision.[[Precision]]).
        var write = temporal_rs.DiplomatWrite.init(agent.gc_allocator);
        try builtins.temporal.extractResult(
            agent,
            temporal_rs.c.temporal_rs_Instant_to_ixdtf_string_with_compiled_data(
                instant.fields.inner,
                temporal_rs.toTimeZoneOption(time_zone),
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

    /// 8.3.15 Temporal.Instant.prototype.toZonedDateTimeISO ( timeZone )
    /// https://tc39.es/proposal-temporal/#sec-temporal.instant.prototype.tozoneddatetimeiso
    fn toZonedDateTimeISO(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const time_zone_value = arguments.get(0);

        // 1. Let instant be the this value.
        // 2. Perform ? RequireInternalSlot(instant, [[InitializedTemporalInstant]]).
        const instant = try this_value.requireInternalSlot(agent, Instant);

        // 3. Set timeZone to ? ToTemporalTimeZoneIdentifier(timeZone).
        const time_zone = try toTemporalTimeZoneIdentifier(agent, time_zone_value);

        // 4. Return ! CreateTemporalZonedDateTime(instant.[[EpochNanoseconds]], timeZone,
        //    "iso8601").
        const temporal_rs_zoned_date_time = try builtins.temporal.extractResult(
            agent,
            temporal_rs.c.temporal_rs_Instant_to_zoned_date_time_iso(
                instant.fields.inner,
                time_zone,
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

    /// 8.3.7 Temporal.Instant.prototype.until ( other [ , options ] )
    /// https://tc39.es/proposal-temporal/#sec-temporal.instant.prototype.until
    fn until(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const other = arguments.get(0);
        const options = arguments.get(1);

        // 1. Let instant be the this value.
        // 2. Perform ? RequireInternalSlot(instant, [[InitializedTemporalInstant]]).
        const instant = try this_value.requireInternalSlot(agent, Instant);

        // 3. Return ? DifferenceTemporalInstant(until, instant, other, options).
        const duration = try differenceTemporalInstant(agent, .until, instant, other, options);
        return Value.from(&duration.object);
    }

    /// 8.3.14 Temporal.Instant.prototype.valueOf ( )
    /// https://tc39.es/proposal-temporal/#sec-temporal.instant.prototype.valueof
    fn valueOf(agent: *Agent, _: Value, _: Arguments) Agent.Error!Value {
        // 1. Throw a TypeError exception.
        return agent.throwException(
            .type_error,
            "Cannot convert Temporal.Instant to primitive value",
            .{},
        );
    }
};

/// 8.4 Properties of Temporal.Instant Instances
/// https://tc39.es/proposal-temporal/#sec-properties-of-temporal-instant-instances
pub const Instant = MakeObject(.{
    .Fields = struct {
        inner: *temporal_rs.c.Instant,
    },
    .finalizer = struct {
        fn finalizer(object: *Object) void {
            temporal_rs.c.temporal_rs_Instant_destroy(object.as(Instant).fields.inner);
        }
    }.finalizer,
    .tag = .temporal_instant,
    .display_name = "Temporal.Instant",
});

/// nsMaxInstant = 10**8 × nsPerDay = 8.64 × 10**21
/// https://tc39.es/proposal-temporal/#eqn-nsMaxInstant
pub const ns_max_instant = 8640000000000000000000;

/// nsPerDay = 10**6 × ℝ(msPerDay) = 8.64 × 10**13
/// https://tc39.es/proposal-temporal/#eqn-nsPerDay
pub const ns_per_day = 86400000000000;

/// nsMinInstant = -nsMaxInstant = -8.64 × 10**21
/// https://tc39.es/proposal-temporal/#eqn-nsMinInstant
pub const ns_min_instant = -8640000000000000000000;

/// 8.5.2 CreateTemporalInstant ( epochNanoseconds [ , newTarget ] )
/// https://tc39.es/proposal-temporal/#sec-temporal-createtemporalinstant
pub fn createTemporalInstant(
    agent: *Agent,
    inner: *temporal_rs.c.Instant,
    maybe_new_target: ?*Object,
) Agent.Error!*Instant {
    const realm = agent.currentRealm();

    // 1. Assert: IsValidEpochNanoseconds(epochNanoseconds) is true.

    // 2. If newTarget is not present, set newTarget to %Temporal.Instant%.
    const new_target = maybe_new_target orelse try realm.intrinsic(.temporal_instant);

    // 3. Let object be ? OrdinaryCreateFromConstructor(newTarget, "%Temporal.Instant.prototype%",
    //    « [[InitializedTemporalInstant]], [[EpochNanoseconds]] »).
    // 4. Set object.[[EpochNanoseconds]] to epochNanoseconds.
    // 5. Return object.
    return ordinaryCreateFromConstructor(
        Instant,
        agent,
        new_target,
        .temporal_instant_prototype,
        .{ .inner = inner },
    );
}

/// 8.5.3 ToTemporalInstant ( item )
/// https://tc39.es/proposal-temporal/#sec-temporal-totemporalinstant
pub fn toTemporalInstant(agent: *Agent, item_: Value) Agent.Error!*Instant {
    var item = item_;

    // 1. If item is an Object, then
    if (item.isObject()) {
        // a. If item has an [[InitializedTemporalInstant]] or [[InitializedTemporalZonedDateTime]]
        //    internal slot, then
        if (item.asObject().is(Instant) or item.asObject().is(builtins.temporal.ZonedDateTime)) {
            // i. Return ! CreateTemporalInstant(item.[[EpochNanoseconds]]).
            const temporal_rs_instant = if (item.asObject().cast(Instant)) |instant|
                temporal_rs.c.temporal_rs_Instant_clone(instant.fields.inner)
            else if (item.asObject().cast(builtins.temporal.ZonedDateTime)) |zoned_date_time|
                temporal_rs.c.temporal_rs_ZonedDateTime_to_instant(zoned_date_time.fields.inner)
            else
                unreachable;
            errdefer temporal_rs.c.temporal_rs_Instant_destroy(temporal_rs_instant.?);
            return createTemporalInstant(
                agent,
                temporal_rs_instant.?,
                null,
            ) catch |err| try noexcept(err);
        }

        // b. NOTE: This use of ToPrimitive allows Instant-like objects to be converted.
        // c. Set item to ? ToPrimitive(item, string).
        item = try item.toPrimitive(agent, .string);
    }

    // 2. If item is not a String, throw a TypeError exception.
    if (!item.isString()) {
        return agent.throwException(.type_error, "Instant must be a string or object", .{});
    }

    // 3. Let parsed be ? ParseISODateTime(item, « TemporalInstantString »).
    // 4. Assert: Either parsed.[[TimeZone]].[[OffsetString]] is not empty or
    //    parsed.[[TimeZone]].[[Z]] is true, but not both.
    // 5. If parsed.[[TimeZone]].[[Z]] is true, let offsetNanoseconds be 0; else let
    //    offsetNanoseconds be ! ParseDateTimeUTCOffset(parsed.[[TimeZone]].[[OffsetString]]).
    // 6. Let time be parsed.[[Time]].
    // 7. Assert: time is not start-of-day.
    // 8. Let balanced be BalanceISODateTime(parsed.[[Year]], parsed.[[Month]], parsed.[[Day]],
    //    time.[[Hour]], time.[[Minute]], time.[[Second]], time.[[Millisecond]],
    //    time.[[Microsecond]], time.[[Nanosecond]] - offsetNanoseconds).
    // 9. Perform ? CheckISODaysRange(balanced.[[ISODate]]).
    // 10. Let epochNanoseconds be GetUTCEpochNanoseconds(balanced).
    // 11. If IsValidEpochNanoseconds(epochNanoseconds) is false, throw a RangeError exception.
    // 12. Return ! CreateTemporalInstant(epochNanoseconds).
    const temporal_rs_instant = switch (item.asString().asAsciiOrUtf16()) {
        .ascii => |ascii| try builtins.temporal.extractResult(
            agent,
            temporal_rs.c.temporal_rs_Instant_from_utf8(
                temporal_rs.toDiplomatStringView(ascii),
            ),
        ),
        .utf16 => |utf16| try builtins.temporal.extractResult(
            agent,
            temporal_rs.c.temporal_rs_Instant_from_utf16(
                temporal_rs.toDiplomatString16View(utf16),
            ),
        ),
    };
    errdefer temporal_rs.c.temporal_rs_Instant_destroy(temporal_rs_instant.?);
    return createTemporalInstant(agent, temporal_rs_instant.?, null);
}

/// 8.5.9 DifferenceTemporalInstant ( operation, instant, other, options )
/// https://tc39.es/proposal-temporal/#sec-temporal-differencetemporalinstant
fn differenceTemporalInstant(
    agent: *Agent,
    operation: enum { since, until },
    instant: *const Instant,
    other_value: Value,
    options_value: Value,
) Agent.Error!*builtins.temporal.Duration {
    // 1. Set other to ? ToTemporalInstant(other).
    const other = try toTemporalInstant(agent, other_value);

    // 2. Let resolvedOptions be ? GetOptionsObject(options).
    const options = try options_value.getOptionsObject(agent);

    // 3. Let settings be ? GetDifferenceSettings(operation, resolvedOptions, time, « », nanosecond,
    //    second).
    const settings = try getTemporalDifferenceSettingsWithoutValidation(agent, options);

    // 4. Let internalDuration be DifferenceInstant(instant.[[EpochNanoseconds]],
    //    other.[[EpochNanoseconds]], settings.[[RoundingIncrement]], settings.[[SmallestUnit]],
    //    settings.[[RoundingMode]]).
    // 5. Let result be ! TemporalDurationFromInternal(internalDuration, settings.[[LargestUnit]]).
    // 6. If operation is since, set result to CreateNegatedTemporalDuration(result).
    // 7. Return result.
    const temporal_rs_duration = switch (operation) {
        .since => try builtins.temporal.extractResult(
            agent,
            temporal_rs.c.temporal_rs_Instant_since(
                instant.fields.inner,
                other.fields.inner,
                settings,
            ),
        ),
        .until => try builtins.temporal.extractResult(
            agent,
            temporal_rs.c.temporal_rs_Instant_until(
                instant.fields.inner,
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

/// 8.5.10 AddDurationToInstant ( operation, instant, temporalDurationLike )
/// https://tc39.es/proposal-temporal/#sec-temporal-adddurationtoinstant
fn addDurationToInstant(
    agent: *Agent,
    operation: enum { add, subtract },
    instant: *const Instant,
    temporal_duration_like: Value,
) Agent.Error!*Instant {
    // 1. Let duration be ? ToTemporalDuration(temporalDurationLike).
    const duration = try toTemporalDuration(agent, temporal_duration_like);

    // 2. If operation is subtract, set duration to CreateNegatedTemporalDuration(duration).
    // 3. Let largestUnit be DefaultTemporalLargestUnit(duration).
    // 4. If TemporalUnitCategory(largestUnit) is date, throw a RangeError exception.
    // 5. Let internalDuration be ToInternalDurationRecordWith24HourDays(duration).
    // 6. Let ns be ? AddInstant(instant.[[EpochNanoseconds]], internalDuration.[[Time]]).
    // 7. Return ! CreateTemporalInstant(ns).
    const temporal_rs_instant = switch (operation) {
        .add => try builtins.temporal.extractResult(
            agent,
            temporal_rs.c.temporal_rs_Instant_add(
                instant.fields.inner,
                duration.fields.inner,
            ),
        ),
        .subtract => try builtins.temporal.extractResult(
            agent,
            temporal_rs.c.temporal_rs_Instant_subtract(
                instant.fields.inner,
                duration.fields.inner,
            ),
        ),
    };
    errdefer temporal_rs.c.temporal_rs_Instant_destroy(temporal_rs_instant.?);
    return createTemporalInstant(
        agent,
        temporal_rs_instant.?,
        null,
    ) catch |err| try noexcept(err);
}
