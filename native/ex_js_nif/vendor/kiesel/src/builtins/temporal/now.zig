//! 2 The Temporal.Now Object
//! https://tc39.es/proposal-temporal/#sec-temporal-now-object

const std = @import("std");

const temporal_rs = @import("temporal_rs");

const builtins = @import("../../builtins.zig");
const execution = @import("../../execution.zig");
const types = @import("../../types.zig");
const utils = @import("../../utils.zig");

const Agent = execution.Agent;
const Arguments = types.Arguments;
const Object = types.Object;
const Realm = execution.Realm;
const String = types.String;
const Value = types.Value;
const createTemporalDate = builtins.createTemporalDate;
const createTemporalDateTime = builtins.createTemporalDateTime;
const createTemporalInstant = builtins.createTemporalInstant;
const createTemporalTime = builtins.createTemporalTime;
const createTemporalZonedDateTime = builtins.createTemporalZonedDateTime;
const noexcept = utils.noexcept;
const ordinaryObjectCreate = builtins.ordinaryObjectCreate;
const systemTimeZoneIdentifier = builtins.systemTimeZoneIdentifier;
const toTemporalTimeZoneIdentifier = builtins.toTemporalTimeZoneIdentifier;

pub const namespace = struct {
    pub fn create(agent: *Agent, realm: *Realm) std.mem.Allocator.Error!*Object {
        return ordinaryObjectCreate(agent, try realm.intrinsic(.object_prototype));
    }

    pub fn init(agent: *Agent, realm: *Realm, object: *Object) std.mem.Allocator.Error!void {
        try object.defineBuiltinFunction(agent, "instant", instant, 0, realm);
        try object.defineBuiltinFunction(agent, "plainDateISO", plainDateISO, 0, realm);
        try object.defineBuiltinFunction(agent, "plainDateTimeISO", plainDateTimeISO, 0, realm);
        try object.defineBuiltinFunction(agent, "plainTimeISO", plainTimeISO, 0, realm);
        try object.defineBuiltinFunction(agent, "timeZoneId", timeZoneId, 0, realm);
        try object.defineBuiltinFunction(agent, "zonedDateTimeISO", zonedDateTimeISO, 0, realm);

        // 2.1.1 Temporal.Now [ %Symbol.toStringTag% ]
        // https://tc39.es/proposal-temporal/#sec-temporal-now-%symbol.tostringtag%
        try object.defineBuiltinPropertyWithAttributes(
            agent,
            "Symbol.toStringTag",
            Value.from("Temporal.Now"),
            .{
                .writable = false,
                .enumerable = false,
                .configurable = true,
            },
        );
    }

    /// 2.2.2 Temporal.Now.instant ( )
    /// https://tc39.es/proposal-temporal/#sec-temporal.now.instant
    fn instant(agent: *Agent, _: Value, _: Arguments) Agent.Error!Value {
        // 1. Let ns be SystemUTCEpochNanoseconds().
        const ns = systemUTCEpochNanoseconds(agent);

        // 2. Return ! CreateTemporalInstant(ns).
        const temporal_rs_instant = try builtins.temporal.extractResult(
            agent,
            temporal_rs.c.temporal_rs_Instant_try_new(ns),
        );
        errdefer temporal_rs.c.temporal_rs_Instant_destroy(temporal_rs_instant.?);
        const instant_ = createTemporalInstant(
            agent,
            temporal_rs_instant.?,
            null,
        ) catch |err| try noexcept(err);
        return Value.from(&instant_.object);
    }

    /// 2.2.5 Temporal.Now.plainDateISO ( [ temporalTimeZoneLike ] )
    /// https://tc39.es/proposal-temporal/#sec-temporal.now.plaindateiso
    fn plainDateISO(agent: *Agent, _: Value, arguments: Arguments) Agent.Error!Value {
        const temporal_time_zone_like = arguments.get(0);

        // 1. Let isoDateTime be ? SystemDateTime(temporalTimeZoneLike).
        const time_zone, const epoch_ns = try systemDateTime(agent, temporal_time_zone_like);

        // 2. Return ! CreateTemporalDate(isoDateTime.[[ISODate]], "iso8601").
        const temporal_rs_plain_date = try builtins.temporal.extractResult(
            agent,
            temporal_rs.c.temporal_rs_PlainDate_from_epoch_nanoseconds(epoch_ns, time_zone),
        );
        errdefer temporal_rs.c.temporal_rs_PlainDate_destroy(temporal_rs_plain_date.?);
        const plain_date = createTemporalDate(
            agent,
            temporal_rs_plain_date.?,
            null,
        ) catch |err| try noexcept(err);
        return Value.from(&plain_date.object);
    }

    /// 2.2.3 Temporal.Now.plainDateTimeISO ( [ temporalTimeZoneLike ] )
    /// https://tc39.es/proposal-temporal/#sec-temporal.now.plaindatetimeiso
    fn plainDateTimeISO(agent: *Agent, _: Value, arguments: Arguments) Agent.Error!Value {
        const temporal_time_zone_like = arguments.get(0);

        // 1. Let isoDateTime be ? SystemDateTime(temporalTimeZoneLike).
        const time_zone, const epoch_ns = try systemDateTime(agent, temporal_time_zone_like);

        // 2. Return ! CreateTemporalDateTime(isoDateTime, "iso8601").
        const temporal_rs_plain_date_time = try builtins.temporal.extractResult(
            agent,
            temporal_rs.c.temporal_rs_PlainDateTime_from_epoch_nanoseconds(epoch_ns, time_zone),
        );
        errdefer temporal_rs.c.temporal_rs_PlainDateTime_destroy(temporal_rs_plain_date_time.?);
        const plain_date_time = createTemporalDateTime(
            agent,
            temporal_rs_plain_date_time.?,
            null,
        ) catch |err| try noexcept(err);
        return Value.from(&plain_date_time.object);
    }

    /// 2.2.6 Temporal.Now.plainTimeISO ( [ temporalTimeZoneLike ] )
    /// https://tc39.es/proposal-temporal/#sec-temporal.now.plaintimeiso
    fn plainTimeISO(agent: *Agent, _: Value, arguments: Arguments) Agent.Error!Value {
        const temporal_time_zone_like = arguments.get(0);

        // 1. Let isoDateTime be ? SystemDateTime(temporalTimeZoneLike).
        const time_zone, const epoch_ns = try systemDateTime(agent, temporal_time_zone_like);

        // 2. Return ! CreateTemporalTime(isoDateTime.[[Time]]).
        const temporal_rs_plain_time = try builtins.temporal.extractResult(
            agent,
            temporal_rs.c.temporal_rs_PlainTime_from_epoch_nanoseconds(epoch_ns, time_zone),
        );
        errdefer temporal_rs.c.temporal_rs_PlainTime_destroy(temporal_rs_plain_time.?);
        const plain_time = createTemporalTime(
            agent,
            temporal_rs_plain_time.?,
            null,
        ) catch |err| try noexcept(err);
        return Value.from(&plain_time.object);
    }

    /// 2.2.1 Temporal.Now.timeZoneId ( )
    /// https://tc39.es/proposal-temporal/#sec-temporal.now.timezoneid
    fn timeZoneId(agent: *Agent, _: Value, _: Arguments) Agent.Error!Value {
        // 1. Return SystemTimeZoneIdentifier().
        const time_zone = systemTimeZoneIdentifier(agent.platform);
        var write = temporal_rs.DiplomatWrite.init(agent.gc_allocator);
        temporal_rs.c.temporal_rs_TimeZone_identifier(time_zone, &write.inner);
        return Value.from(try String.fromAscii(agent, try write.toOwnedSlice()));
    }

    /// 2.2.4 Temporal.Now.zonedDateTimeISO ( [ temporalTimeZoneLike ] )
    /// https://tc39.es/proposal-temporal/#sec-temporal.now.zoneddatetimeiso
    fn zonedDateTimeISO(agent: *Agent, _: Value, arguments: Arguments) Agent.Error!Value {
        const temporal_time_zone_like = arguments.get(0);

        // 1. If temporalTimeZoneLike is undefined, then
        const time_zone = if (temporal_time_zone_like.isUndefined()) blk: {
            // a. Let timeZone be SystemTimeZoneIdentifier().
            break :blk systemTimeZoneIdentifier(agent.platform);
        } else blk: {
            // 2. Else,
            // a. Let timeZone be ? ToTemporalTimeZoneIdentifier(temporalTimeZoneLike).
            break :blk try toTemporalTimeZoneIdentifier(agent, temporal_time_zone_like);
        };

        // 3. Let ns be SystemUTCEpochNanoseconds().
        const ns = systemUTCEpochNanoseconds(agent);

        // 4. Return ! CreateTemporalZonedDateTime(ns, timeZone, "iso8601").
        const temporal_rs_zoned_date_time = try builtins.temporal.extractResult(
            agent,
            temporal_rs.c.temporal_rs_ZonedDateTime_try_new(
                ns,
                temporal_rs.c.AnyCalendarKind_Iso,
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
};

/// 2.3.3 SystemUTCEpochNanoseconds ( )
/// https://tc39.es/proposal-temporal/#sec-temporal-systemutcepochnanoseconds
pub fn systemUTCEpochNanoseconds(agent: *Agent) temporal_rs.c.I128Nanoseconds {
    // NOTE: The host implementation can get the global object itself if needed, passing the agent
    //       is enough.
    // 1. Let global be GetGlobalObject().
    // 2. Let nowNs be HostSystemUTCEpochNanoseconds(global).
    const now_ns = agent.host_hooks.hostSystemUTCEpochNanoseconds(agent);

    // 3. Return ℤ(nowNs).
    return temporal_rs.toI128Nanoseconds(now_ns);
}

/// 2.3.4 SystemDateTime ( temporalTimeZoneLike )
/// https://tc39.es/proposal-temporal/#sec-temporal-systemdatetime
pub fn systemDateTime(
    agent: *Agent,
    temporal_time_zone_like: Value,
) Agent.Error!struct { temporal_rs.c.TimeZone, temporal_rs.c.I128Nanoseconds } {
    // 1. If temporalTimeZoneLike is undefined, then
    const time_zone = if (temporal_time_zone_like.isUndefined()) blk: {
        // a. Let timeZone be SystemTimeZoneIdentifier().
        break :blk systemTimeZoneIdentifier(agent.platform);
    } else blk: {
        // 2. Else,
        // a. Let timeZone be ? ToTemporalTimeZoneIdentifier(temporalTimeZoneLike).
        break :blk try toTemporalTimeZoneIdentifier(agent, temporal_time_zone_like);
    };

    // 3. Let epochNs be SystemUTCEpochNanoseconds().
    const epoch_ns = systemUTCEpochNanoseconds(agent);

    // 4. Return GetISODateTimeFor(timeZone, epochNs).
    return .{ time_zone, epoch_ns };
}
