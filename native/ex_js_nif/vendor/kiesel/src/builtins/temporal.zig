//! 1 The Temporal Object
//! https://tc39.es/proposal-temporal/#sec-temporal-objects

const std = @import("std");

const temporal_rs = @import("temporal_rs");

const builtins = @import("../builtins.zig");
const execution = @import("../execution.zig");
const types = @import("../types.zig");
const utils = @import("../utils.zig");

const Agent = execution.Agent;
const Object = types.Object;
const PropertyKey = types.PropertyKey;
const Realm = execution.Realm;
const String = types.String;
const StringParser = utils.StringParser;
const Value = types.Value;
const ordinaryObjectCreate = builtins.ordinaryObjectCreate;

comptime {
    const build_options = @import("build-options");
    if (!build_options.enable_temporal) @compileError("Temporal is not enabled");
}

pub const duration = @import("./temporal/duration.zig");
pub const instant = @import("./temporal/instant.zig");
pub const now = @import("./temporal/now.zig");
pub const plain_date = @import("./temporal/plain_date.zig");
pub const plain_date_time = @import("./temporal/plain_date_time.zig");
pub const plain_month_day = @import("./temporal/plain_month_day.zig");
pub const plain_time = @import("./temporal/plain_time.zig");
pub const plain_year_month = @import("./temporal/plain_year_month.zig");
pub const zoned_date_time = @import("./temporal/zoned_date_time.zig");

pub const Duration = duration.Duration;
pub const Instant = instant.Instant;
pub const PlainDate = plain_date.PlainDate;
pub const PlainDateTime = plain_date_time.PlainDateTime;
pub const PlainMonthDay = plain_month_day.PlainMonthDay;
pub const PlainTime = plain_time.PlainTime;
pub const PlainYearMonth = plain_year_month.PlainYearMonth;
pub const ZonedDateTime = zoned_date_time.ZonedDateTime;

pub fn extractResult(agent: *Agent, result: anytype) Agent.Error!temporal_rs.Success(@TypeOf(result)) {
    if (temporal_rs.success(result)) |x| return x;
    const message = if (temporal_rs.fromOption(result.unnamed_0.err.msg)) |sv|
        temporal_rs.fromDiplomatStringView(sv)
    else
        "";
    switch (result.unnamed_0.err.kind) {
        temporal_rs.c.ErrorKind_Generic => return agent.throwException(.internal_error, "{s}", .{message}),
        temporal_rs.c.ErrorKind_Type => return agent.throwException(.type_error, "{s}", .{message}),
        temporal_rs.c.ErrorKind_Range => return agent.throwException(.range_error, "{s}", .{message}),
        temporal_rs.c.ErrorKind_Syntax => return agent.throwException(.syntax_error, "{s}", .{message}),
        temporal_rs.c.ErrorKind_Assert => @panic("temporal_rs assertion failed"),
        else => unreachable,
    }
}

pub const namespace = struct {
    pub fn create(agent: *Agent, realm: *Realm) std.mem.Allocator.Error!*Object {
        return ordinaryObjectCreate(agent, try realm.intrinsic(.object_prototype));
    }

    pub fn init(agent: *Agent, realm: *Realm, object: *Object) std.mem.Allocator.Error!void {
        // 1.1.1 Temporal [ %Symbol.toStringTag% ]
        // https://tc39.es/proposal-temporal/#sec-temporal-%symbol.tostringtag%
        try object.defineBuiltinPropertyWithAttributes(
            agent,
            "Symbol.toStringTag",
            Value.from("Temporal"),
            .{
                .writable = false,
                .enumerable = false,
                .configurable = true,
            },
        );

        // 1.2.7 Temporal.Duration ( . . . )
        // https://tc39.es/proposal-temporal/#sec-temporal-duration
        try object.defineBuiltinProperty(
            agent,
            "Duration",
            Value.from(try realm.intrinsic(.temporal_duration)),
        );

        // 1.2.1 Temporal.Instant ( . . . )
        // https://tc39.es/proposal-temporal/#sec-temporal-instant
        try object.defineBuiltinProperty(
            agent,
            "Instant",
            Value.from(try realm.intrinsic(.temporal_instant)),
        );

        // 1.2.3 Temporal.PlainDate ( . . . )
        // https://tc39.es/proposal-temporal/#sec-temporal-plaindate
        try object.defineBuiltinProperty(
            agent,
            "PlainDate",
            Value.from(try realm.intrinsic(.temporal_plain_date)),
        );

        // 1.2.2 Temporal.PlainDateTime ( . . . )
        // https://tc39.es/proposal-temporal/#sec-temporal-plaindatetime
        try object.defineBuiltinProperty(
            agent,
            "PlainDateTime",
            Value.from(try realm.intrinsic(.temporal_plain_date_time)),
        );

        // 1.2.6 Temporal.PlainMonthDay ( . . . )
        // https://tc39.es/proposal-temporal/#sec-temporal-plainmonthday
        try object.defineBuiltinProperty(
            agent,
            "PlainMonthDay",
            Value.from(try realm.intrinsic(.temporal_plain_month_day)),
        );

        // 1.2.4 Temporal.PlainTime ( . . . )
        // https://tc39.es/proposal-temporal/#sec-temporal-plaintime
        try object.defineBuiltinProperty(
            agent,
            "PlainTime",
            Value.from(try realm.intrinsic(.temporal_plain_time)),
        );

        // 1.2.5 Temporal.PlainYearMonth ( . . . )
        // https://tc39.es/proposal-temporal/#sec-temporal-plainyearmonth
        try object.defineBuiltinProperty(
            agent,
            "PlainYearMonth",
            Value.from(try realm.intrinsic(.temporal_plain_year_month)),
        );

        // 1.2.8 Temporal.ZonedDateTime ( . . . )
        // https://tc39.es/proposal-temporal/#sec-temporal-zoneddatetime
        try object.defineBuiltinProperty(
            agent,
            "ZonedDateTime",
            Value.from(try realm.intrinsic(.temporal_zoned_date_time)),
        );

        // 1.3.1 Temporal.Now
        // https://tc39.es/proposal-temporal/#sec-temporal-now
        try object.defineBuiltinProperty(
            agent,
            "Now",
            Value.from(try realm.intrinsic(.temporal_now)),
        );
    }
};

/// 11.1.8 ToTemporalTimeZoneIdentifier ( temporalTimeZoneLike )
/// https://tc39.es/proposal-temporal/#sec-temporal-totemporaltimezoneidentifier
pub fn toTemporalTimeZoneIdentifier(
    agent: *Agent,
    temporal_time_zone_like: Value,
) Agent.Error!temporal_rs.c.TimeZone {
    const gpa = agent.gpa;

    // 1. If temporalTimeZoneLike is an Object and temporalTimeZoneLike has an
    //    [[InitializedTemporalZonedDateTime]] internal slot, return
    //    temporalTimeZoneLike.[[TimeZone]].
    if (temporal_time_zone_like.castObject(ZonedDateTime)) |zoned_date_time_| {
        return temporal_rs.c.temporal_rs_ZonedDateTime_timezone(zoned_date_time_.fields.inner);
    }

    // 2. If temporalTimeZoneLike is not a String, throw a TypeError exception.
    if (!temporal_time_zone_like.isString()) {
        return agent.throwException(
            .type_error,
            "Time zone must be a string or Temporal.ZonedDateTime object",
            .{},
        );
    }

    // 3. Let parseResult be ? ParseTemporalTimeZoneString(temporalTimeZoneLike).
    // 4. Let offsetMinutes be parseResult.[[OffsetMinutes]].
    // 5. If offsetMinutes is not empty, return FormatOffsetTimeZoneIdentifier(offsetMinutes).
    // 6. Let name be parseResult.[[Name]].
    // 7. Let timeZoneIdentifierRecord be GetAvailableNamedTimeZoneIdentifier(name).
    // 8. If timeZoneIdentifierRecord is empty, throw a RangeError exception.
    // 9. Return timeZoneIdentifierRecord.[[Identifier]].
    const time_zone_utf8 = try temporal_time_zone_like.asString().toUtf8(gpa);
    defer gpa.free(time_zone_utf8);
    return builtins.temporal.extractResult(
        agent,
        temporal_rs.c.temporal_rs_TimeZone_try_from_str(
            temporal_rs.toDiplomatStringView(time_zone_utf8),
        ),
    );
}

/// 12.1.1 CanonicalizeCalendar ( id )
/// https://tc39.es/proposal-temporal/#sec-temporal-canonicalizecalendar
pub fn canonicalizeCalendar(
    agent: *Agent,
    id: *const String,
) Agent.Error!temporal_rs.c.AnyCalendarKind {
    const gpa = agent.gpa;

    // 1. Let calendars be AvailableCalendars().
    // 2. If calendars does not contain the ASCII-lowercase of id, throw a RangeError exception.
    // 3. Return CanonicalizeUValue("ca", id).
    const calendar_utf8 = try id.toUtf8(gpa);
    defer gpa.free(calendar_utf8);
    _ = std.ascii.lowerString(calendar_utf8, calendar_utf8);
    const calendar = temporal_rs.fromOption(
        temporal_rs.c.temporal_rs_AnyCalendarKind_get_for_str(
            temporal_rs.toDiplomatStringView(calendar_utf8),
        ),
    ) orelse {
        return agent.throwException(
            .range_error,
            "Invalid calendar '{f}'",
            .{id.fmtEscaped()},
        );
    };
    return calendar;
}

/// 12.2.1 ParseMonthCode ( argument )
/// https://tc39.es/proposal-temporal/#sec-temporal-parsemonthcode
fn parseMonthCode(agent: *Agent, argument: Value) Agent.Error![]const u8 {
    // 1. Let monthCode be ? ToPrimitive(argument, string).
    const month_code = try argument.toPrimitive(agent, .string);

    // 2. If monthCode is not a String, throw a TypeError exception.
    if (!month_code.isString()) {
        return agent.throwException(.type_error, "Month code must be a string", .{});
    }

    // 3. If ParseText(StringToCodePoints(monthCode), MonthCode) is a List of errors, throw a
    //    RangeError exception.
    const month_code_utf8 = try month_code.asString().toUtf8(agent.gc_allocator);
    parseMonthCodeImpl(month_code_utf8) catch {
        return agent.throwException(.range_error, "Invalid month code", .{});
    };

    // 4. Let isLeapMonth be false.
    // 5. If the length of monthCode = 4, then
    //     a. Assert: The fourth code unit of monthCode is 0x004C (LATIN CAPITAL LETTER L).
    //     b. Set isLeapMonth to true.
    // 6. Let monthCodeDigits be the substring of monthCode from 1 to 3.
    // 7. Let monthNumber be ℝ(StringToNumber(monthCodeDigits)).
    // 8. Return the Record { [[MonthNumber]]: monthNumber, [[IsLeapMonth]]: isLeapMonth }.
    // NOTE: We return the string directly instead of going through CreateMonthCode.
    return month_code_utf8;
}

fn parseMonthCodeImpl(string: []const u8) error{InvalidFormat}!void {
    // MonthCode :::
    //     M00L
    //     M0 NonZeroDigit L[opt]
    //     M NonZeroDigit DecimalDigit L[opt]
    var parser = StringParser.init(string);
    if (parser.consume() != 'M') return error.InvalidFormat;
    const month = parser.consumeDigits(u8, 2) orelse return error.InvalidFormat;
    if (parser.peek() == 'L')
        _ = parser.consume() orelse unreachable
    else if (month == 0)
        return error.InvalidFormat;
    // Did we reach the end of the string?
    if (parser.peek() != null) return error.InvalidFormat;
}

test parseMonthCodeImpl {
    {
        const test_cases = [_][]const u8{
            "M00L", "M01",  "M01L", "M09",  "M09L",
            "M90",  "M90L", "M99",  "M99L",
        };
        for (test_cases) |test_case| {
            try parseMonthCodeImpl(test_case);
        }
    }
    {
        const test_cases = [_][]const u8{
            "",     "01",    "01L",  "M00",   "M00l",
            "M01 ", "M01L ", " M01", " M01L",
        };
        for (test_cases) |test_case| {
            try std.testing.expectError(error.InvalidFormat, parseMonthCodeImpl(test_case));
        }
    }
}

const FieldName = enum {
    era,
    era_year,
    year,
    month,
    month_code,
    day,
    hour,
    minute,
    second,
    millisecond,
    microsecond,
    nanosecond,
    offset,
    time_zone,
};

const PrepareCalendarFieldsResult = struct {
    date: temporal_rs.c.PartialDate,
    time: temporal_rs.c.PartialTime,
    offset: temporal_rs.c.OptionStringView,
    timezone: temporal_rs.c.TimeZone_option,
};

/// 12.3.3 PrepareCalendarFields ( calendar, fields, calendarFieldNames, nonCalendarFieldNames, requiredFieldNames )
/// https://tc39.es/proposal-temporal/#sec-temporal-preparecalendarfields
pub fn prepareCalendarFields(
    agent: *Agent,
    calendar: temporal_rs.c.AnyCalendarKind,
    fields: *Object,
    calendar_and_non_calendar_field_names: std.enums.EnumSet(FieldName),
    required_field_names: enum {
        none,
        partial,
        time_zone,
    },
) Agent.Error!PrepareCalendarFieldsResult {
    // 1. Assert: If requiredFieldNames is a List, requiredFieldNames contains zero or one of each
    //    of the elements of calendarFieldNames and nonCalendarFieldNames.
    // 2. Let fieldNames be the list-concatenation of calendarFieldNames and nonCalendarFieldNames.
    // 3. Let extraFieldNames be CalendarExtraFields(calendar, calendarFieldNames).
    // 4. Set fieldNames to the list-concatenation of fieldNames and extraFieldNames.
    // 5. Assert: fieldNames contains no duplicate elements.
    var field_names = calendar_and_non_calendar_field_names;
    // See: https://tc39.es/proposal-intl-era-monthcode/#sec-temporal-calendarsupportsera
    const calendar_supports_era = switch (calendar) {
        temporal_rs.c.AnyCalendarKind_Chinese,
        temporal_rs.c.AnyCalendarKind_Dangi,
        temporal_rs.c.AnyCalendarKind_Iso,
        => false,
        else => true,
    };
    if (calendar_supports_era) {
        field_names.insert(.era);
        field_names.insert(.era_year);
    }

    // 6. Let result be a Calendar Fields Record with all fields equal to unset.
    var result: PrepareCalendarFieldsResult = .{
        .date = .{
            .year = temporal_rs.toOption(temporal_rs.c.OptionI32, null),
            .month = temporal_rs.toOption(temporal_rs.c.OptionU8, null),
            .month_code = .{ .data = null },
            .day = temporal_rs.toOption(temporal_rs.c.OptionU8, null),
            .era = .{ .data = null },
            .era_year = temporal_rs.toOption(temporal_rs.c.OptionI32, null),
            .calendar = calendar,
        },
        .time = .{
            .hour = temporal_rs.toOption(temporal_rs.c.OptionU8, null),
            .minute = temporal_rs.toOption(temporal_rs.c.OptionU8, null),
            .second = temporal_rs.toOption(temporal_rs.c.OptionU8, null),
            .millisecond = temporal_rs.toOption(temporal_rs.c.OptionU16, null),
            .microsecond = temporal_rs.toOption(temporal_rs.c.OptionU16, null),
            .nanosecond = temporal_rs.toOption(temporal_rs.c.OptionU16, null),
        },
        .offset = temporal_rs.toOption(temporal_rs.c.OptionStringView, null),
        .timezone = temporal_rs.toTimeZoneOption(null),
    };

    // 7. Let any be false.
    var any = false;

    // 8. Let sortedPropertyNames be a List whose elements are the values in the Property Key column
    //    of Table 19 corresponding to the elements of fieldNames, sorted according to lexicographic
    //    code unit order.
    const sorted_field_names: []const FieldName = &.{
        .day,
        .era,
        .era_year,
        .hour,
        .microsecond,
        .millisecond,
        .minute,
        .month,
        .month_code,
        .nanosecond,
        .offset,
        .second,
        .time_zone,
        .year,
    };

    // 9. For each property name property of sortedPropertyNames, do
    inline for (sorted_field_names) |field_name| {
        if (field_names.contains(field_name)) {
            // a. Let key be the value in the Enumeration Key column of Table 19 corresponding to
            //    the row whose Property Key value is property.
            // NOTE: We do this the other way around.
            const property_name = switch (field_name) {
                .era => "era",
                .era_year => "eraYear",
                .year => "year",
                .month => "month",
                .month_code => "monthCode",
                .day => "day",
                .hour => "hour",
                .minute => "minute",
                .second => "second",
                .millisecond => "millisecond",
                .microsecond => "microsecond",
                .nanosecond => "nanosecond",
                .offset => "offset",
                .time_zone => "timeZone",
            };

            // b. Let value be ? Get(fields, property).
            const value = try fields.get(agent, PropertyKey.from(property_name));

            // c. If value is not undefined, then
            if (!value.isUndefined()) {
                // i. Set any to true.
                any = true;

                // ii-ix.
                switch (field_name) {
                    .era => {
                        const era_string = try value.toString(agent);
                        const era = try era_string.toUtf8(agent.gc_allocator);
                        result.date.era = temporal_rs.toDiplomatStringView(era);
                    },
                    .month_code => {
                        const month_code = try parseMonthCode(agent, value);
                        result.date.month_code = temporal_rs.toDiplomatStringView(month_code);
                    },
                    .offset => {
                        const offset = try toOffsetString(agent, value);
                        result.offset = temporal_rs.toOption(
                            temporal_rs.c.OptionStringView,
                            temporal_rs.toDiplomatStringView(offset),
                        );
                    },
                    .time_zone => {
                        result.timezone = temporal_rs.toTimeZoneOption(
                            try toTemporalTimeZoneIdentifier(agent, value),
                        );
                    },
                    else => {
                        const result_field_name, const conversion, const T = switch (field_name) {
                            .era_year => .{ "date", Value.toIntegerWithTruncation, i32 },
                            .year => .{ "date", Value.toIntegerWithTruncation, i32 },
                            .month => .{ "date", Value.toPositiveIntegerWithTruncation, u8 },
                            .day => .{ "date", Value.toPositiveIntegerWithTruncation, u8 },
                            .hour => .{ "time", Value.toIntegerWithTruncation, u8 },
                            .minute => .{ "time", Value.toIntegerWithTruncation, u8 },
                            .second => .{ "time", Value.toIntegerWithTruncation, u8 },
                            .millisecond => .{ "time", Value.toIntegerWithTruncation, u16 },
                            .microsecond => .{ "time", Value.toIntegerWithTruncation, u16 },
                            .nanosecond => .{ "time", Value.toIntegerWithTruncation, u16 },
                            else => comptime unreachable,
                        };
                        @field(@field(result, result_field_name), @tagName(field_name)) = .{
                            .is_ok = true,
                            .unnamed_0 = .{ .ok = std.math.lossyCast(T, try conversion(value, agent)) },
                        };
                    },
                }
            } else if (field_name == .time_zone and required_field_names == .time_zone) {
                // d. Else if requiredFieldNames is a List, then
                //     i. If requiredFieldNames contains key, throw a TypeError exception.
                //     ii. Set result's field whose name is given in the Field Name column of the
                //         same row to the corresponding Default value of the same row.
                return agent.throwException(.type_error, "Missing required 'timeZone' field", .{});
            }
        }
    }

    // 10. If requiredFieldNames is partial and any is false, throw a TypeError exception.
    if (required_field_names == .partial and !any) {
        return agent.throwException(.type_error, "At least one field must be present", .{});
    }

    // 11. Return result.
    return result;
}

/// 12.3.10 ToTemporalCalendarIdentifier ( temporalCalendarLike )
/// https://tc39.es/proposal-temporal/#sec-temporal-totemporalcalendaridentifier
pub fn toTemporalCalendarIdentifier(
    agent: *Agent,
    temporal_calendar_like: Value,
) Agent.Error!temporal_rs.c.AnyCalendarKind {
    const gpa = agent.gpa;

    // 1. If temporalCalendarLike is an Object and temporalCalendarLike has an
    //    [[InitializedTemporalDate]], [[InitializedTemporalDateTime]],
    //    [[InitializedTemporalMonthDay]], [[InitializedTemporalYearMonth]], or
    //    [[InitializedTemporalZonedDateTime]] internal slot, return
    //    temporalCalendarLike.[[Calendar]].
    if (temporal_calendar_like.isObject()) {
        const obj = temporal_calendar_like.asObject();
        if (switch (obj.tag) {
            .temporal_plain_date => temporal_rs.c.temporal_rs_PlainDate_calendar(
                obj.as(builtins.temporal.PlainDate).fields.inner,
            ),
            .temporal_plain_date_time => temporal_rs.c.temporal_rs_PlainDateTime_calendar(
                obj.as(builtins.temporal.PlainDateTime).fields.inner,
            ),
            .temporal_plain_month_day => temporal_rs.c.temporal_rs_PlainMonthDay_calendar(
                obj.as(builtins.temporal.PlainMonthDay).fields.inner,
            ),
            .temporal_plain_year_month => temporal_rs.c.temporal_rs_PlainYearMonth_calendar(
                obj.as(builtins.temporal.PlainYearMonth).fields.inner,
            ),
            .temporal_zoned_date_time => temporal_rs.c.temporal_rs_ZonedDateTime_calendar(
                obj.as(builtins.temporal.ZonedDateTime).fields.inner,
            ),
            else => null,
        }) |calendar| {
            return temporal_rs.c.temporal_rs_Calendar_kind(calendar);
        }
    }

    // 2. If temporalCalendarLike is not a String, throw a TypeError exception.
    if (!temporal_calendar_like.isString()) {
        return agent.throwException(
            .type_error,
            "Calendar must be a string or object",
            .{},
        );
    }

    // 3. Let identifier be ? ParseTemporalCalendarString(temporalCalendarLike).
    // 4. Return ? CanonicalizeCalendar(identifier).
    const calendar_utf8 = try temporal_calendar_like.asString().toUtf8(gpa);
    defer gpa.free(calendar_utf8);
    const calendar = temporal_rs.fromOption(
        temporal_rs.c.temporal_rs_AnyCalendarKind_parse_temporal_calendar_string(
            temporal_rs.toDiplomatStringView(calendar_utf8),
        ),
    ) orelse {
        return agent.throwException(.range_error, "Invalid calendar string", .{});
    };
    return calendar;
}

/// 12.3.11 GetTemporalCalendarIdentifierWithISODefault ( item )
/// https://tc39.es/proposal-temporal/#sec-temporal-gettemporalcalendarslotvaluewithisodefault
pub fn getTemporalCalendarIdentifierWithISODefault(
    agent: *Agent,
    item: *Object,
) Agent.Error!temporal_rs.c.AnyCalendarKind {
    // 1. If item has an [[InitializedTemporalDate]], [[InitializedTemporalDateTime]],
    //    [[InitializedTemporalMonthDay]], [[InitializedTemporalYearMonth]], or
    //    [[InitializedTemporalZonedDateTime]] internal slot, then
    if (switch (item.tag) {
        .temporal_plain_date => temporal_rs.c.temporal_rs_PlainDate_calendar(
            item.as(builtins.temporal.PlainDate).fields.inner,
        ),
        .temporal_plain_date_time => temporal_rs.c.temporal_rs_PlainDateTime_calendar(
            item.as(builtins.temporal.PlainDateTime).fields.inner,
        ),
        .temporal_plain_month_day => temporal_rs.c.temporal_rs_PlainMonthDay_calendar(
            item.as(builtins.temporal.PlainMonthDay).fields.inner,
        ),
        .temporal_plain_year_month => temporal_rs.c.temporal_rs_PlainYearMonth_calendar(
            item.as(builtins.temporal.PlainYearMonth).fields.inner,
        ),
        .temporal_zoned_date_time => temporal_rs.c.temporal_rs_ZonedDateTime_calendar(
            item.as(builtins.temporal.ZonedDateTime).fields.inner,
        ),
        else => null,
    }) |calendar| {
        // a. Return item.[[Calendar]].
        return temporal_rs.c.temporal_rs_Calendar_kind(calendar);
    }

    // 2. Let calendarLike be ? Get(item, "calendar").
    const calendar_like = try item.get(agent, PropertyKey.from("calendar"));

    // 3. If calendarLike is undefined, return "iso8601".
    if (calendar_like.isUndefined()) return temporal_rs.c.AnyCalendarKind_Iso;

    // 4. Return ? ToTemporalCalendarIdentifier(calendarLike).
    return toTemporalCalendarIdentifier(agent, calendar_like);
}

/// 13.6 GetTemporalOverflowOption ( options )
/// https://tc39.es/proposal-temporal/#sec-temporal-gettemporaloverflowoption
pub fn getTemporalOverflowOption(
    agent: *Agent,
    options: *Object,
) Agent.Error!temporal_rs.c.ArithmeticOverflow {
    // 1. Let stringValue be ? GetOption(options, "overflow", string, « "constrain", "reject" »,
    //    "constrain").
    const string_value = try options.getOption(
        agent,
        "overflow",
        .string,
        &.{
            String.fromLiteral("constrain"),
            String.fromLiteral("reject"),
        },
        String.fromLiteral("constrain"),
    );

    // 2. If stringValue is "constrain", return constrain.
    // 3. Return reject.
    const arithmetic_overflow_map = std.StaticStringMap(
        temporal_rs.c.ArithmeticOverflow,
    ).initComptime(&.{
        .{ "constrain", temporal_rs.c.ArithmeticOverflow_Constrain },
        .{ "reject", temporal_rs.c.ArithmeticOverflow_Reject },
    });
    return arithmetic_overflow_map.get(string_value.asAscii()).?;
}

/// 13.7 GetTemporalDisambiguationOption ( options )
/// https://tc39.es/proposal-temporal/#sec-temporal-gettemporaldisambiguationoption
pub fn getTemporalDisambiguationOption(
    agent: *Agent,
    options: *Object,
) Agent.Error!temporal_rs.c.Disambiguation {
    // 1. Let stringValue be ? GetOption(options, "disambiguation", string, « "compatible",
    //    "earlier", "later", "reject" », "compatible").
    const string_value = try options.getOption(
        agent,
        "disambiguation",
        .string,
        &.{
            String.fromLiteral("compatible"),
            String.fromLiteral("earlier"),
            String.fromLiteral("later"),
            String.fromLiteral("reject"),
        },
        String.fromLiteral("compatible"),
    );

    // 2. If stringValue is "compatible", return compatible.
    // 3. If stringValue is "earlier", return earlier.
    // 4. If stringValue is "later", return later.
    // 5. Return reject.
    const disambiguation_map = std.StaticStringMap(
        temporal_rs.c.Disambiguation,
    ).initComptime(&.{
        .{ "compatible", temporal_rs.c.Disambiguation_Compatible },
        .{ "earlier", temporal_rs.c.Disambiguation_Earlier },
        .{ "later", temporal_rs.c.Disambiguation_Later },
        .{ "reject", temporal_rs.c.Disambiguation_Reject },
    });
    return disambiguation_map.get(string_value.asAscii()).?;
}

/// 13.9 GetTemporalOffsetOption ( options, fallback )
/// https://tc39.es/proposal-temporal/#sec-temporal-gettemporaloffsetoption
pub fn getTemporalOffsetOption(
    agent: *Agent,
    options: *Object,
    fallback: temporal_rs.c.OffsetDisambiguation,
) Agent.Error!temporal_rs.c.OffsetDisambiguation {
    // 1. If fallback is prefer, let stringFallback be "prefer".
    // 2. Else if fallback is use, let stringFallback be "use".
    // 3. Else if fallback is ignore, let stringFallback be "ignore".
    // 4. Else, let stringFallback be "reject".
    // 5. Let stringValue be ? GetOption(options, "offset", string, « "prefer", "use", "ignore",
    //    "reject" », stringFallback).
    const string_value = try options.getOption(
        agent,
        "offset",
        .string,
        &.{
            String.fromLiteral("prefer"),
            String.fromLiteral("use"),
            String.fromLiteral("ignore"),
            String.fromLiteral("reject"),
        },
        switch (fallback) {
            temporal_rs.c.OffsetDisambiguation_Prefer => String.fromLiteral("prefer"),
            temporal_rs.c.OffsetDisambiguation_Use => String.fromLiteral("use"),
            temporal_rs.c.OffsetDisambiguation_Ignore => String.fromLiteral("ignore"),
            temporal_rs.c.OffsetDisambiguation_Reject => String.fromLiteral("reject"),
            else => unreachable,
        },
    );

    // 6. If stringValue is "prefer", return prefer.
    // 7. If stringValue is "use", return use.
    // 8. If stringValue is "ignore", return ignore.
    // 9. Return reject.
    const offset_disambiguation_map = std.StaticStringMap(
        temporal_rs.c.OffsetDisambiguation,
    ).initComptime(&.{
        .{ "prefer", temporal_rs.c.OffsetDisambiguation_Prefer },
        .{ "use", temporal_rs.c.OffsetDisambiguation_Use },
        .{ "ignore", temporal_rs.c.OffsetDisambiguation_Ignore },
        .{ "reject", temporal_rs.c.OffsetDisambiguation_Reject },
    });
    return offset_disambiguation_map.get(string_value.asAscii()).?;
}

/// 13.10 GetTemporalShowCalendarNameOption ( options )
/// https://tc39.es/proposal-temporal/#sec-temporal-gettemporalshowcalendarnameoption
pub fn getTemporalShowCalendarNameOption(
    agent: *Agent,
    options: *Object,
) Agent.Error!temporal_rs.c.DisplayCalendar {
    // 1. Let stringValue be ? GetOption(options, "calendarName", string, « "auto", "always",
    //    "never", "critical" », "auto").
    const string_value = try options.getOption(
        agent,
        "calendarName",
        .string,
        &.{
            String.fromLiteral("auto"),
            String.fromLiteral("always"),
            String.fromLiteral("never"),
            String.fromLiteral("critical"),
        },
        String.fromLiteral("auto"),
    );

    // 2. If stringValue is "always", return always.
    // 3. If stringValue is "never", return never.
    // 4. If stringValue is "critical", return critical.
    // 5. Return auto.
    const display_calendar_map = std.StaticStringMap(
        temporal_rs.c.DisplayCalendar,
    ).initComptime(&.{
        .{ "auto", temporal_rs.c.DisplayCalendar_Auto },
        .{ "always", temporal_rs.c.DisplayCalendar_Always },
        .{ "never", temporal_rs.c.DisplayCalendar_Never },
        .{ "critical", temporal_rs.c.DisplayCalendar_Critical },
    });
    return display_calendar_map.get(string_value.asAscii()).?;
}

/// 13.11 GetTemporalShowTimeZoneNameOption ( options )
/// https://tc39.es/proposal-temporal/#sec-temporal-gettemporalshowtimezonenameoption
pub fn getTemporalShowTimeZoneNameOption(
    agent: *Agent,
    options: *Object,
) Agent.Error!temporal_rs.c.DisplayTimeZone {
    // 1. Let stringValue be ? GetOption(options, "timeZoneName", string, « "auto", "never",
    //    "critical" », "auto").
    const string_value = try options.getOption(
        agent,
        "timeZoneName",
        .string,
        &.{
            String.fromLiteral("auto"),
            String.fromLiteral("never"),
            String.fromLiteral("critical"),
        },
        String.fromLiteral("auto"),
    );

    // 2. If stringValue is "never", return never.
    // 3. If stringValue is "critical", return critical.
    // 4. Return auto.
    const display_time_zone_map = std.StaticStringMap(
        temporal_rs.c.DisplayTimeZone,
    ).initComptime(&.{
        .{ "auto", temporal_rs.c.DisplayTimeZone_Auto },
        .{ "never", temporal_rs.c.DisplayTimeZone_Never },
        .{ "critical", temporal_rs.c.DisplayTimeZone_Critical },
    });
    return display_time_zone_map.get(string_value.asAscii()).?;
}

/// 13.12 GetTemporalShowOffsetOption ( options )
/// https://tc39.es/proposal-temporal/#sec-temporal-gettemporalshowoffsetoption
pub fn getTemporalShowOffsetOption(
    agent: *Agent,
    options: *Object,
) Agent.Error!temporal_rs.c.DisplayOffset {
    // 1. Let stringValue be ? GetOption(options, "offset", string, « "auto", "never" », "auto").
    const string_value = try options.getOption(
        agent,
        "offset",
        .string,
        &.{
            String.fromLiteral("auto"),
            String.fromLiteral("never"),
        },
        String.fromLiteral("auto"),
    );

    // 2. If stringValue is "never", return never.
    // 3. Return auto.
    const display_offset_map = std.StaticStringMap(
        temporal_rs.c.DisplayOffset,
    ).initComptime(&.{
        .{ "auto", temporal_rs.c.DisplayOffset_Auto },
        .{ "never", temporal_rs.c.DisplayOffset_Never },
    });
    return display_offset_map.get(string_value.asAscii()).?;
}

/// 13.13 GetDirectionOption ( options )
/// https://tc39.es/proposal-temporal/#sec-temporal-getdirectionoption
pub fn getTemporalDirectionOption(
    agent: *Agent,
    options: *Object,
) Agent.Error!temporal_rs.c.TransitionDirection {
    // 1. Let stringValue be ? GetOption(options, "direction", string, « "next", "previous" »,
    //    required).
    const string_value = try options.getOption(
        agent,
        "direction",
        .string,
        &.{
            String.fromLiteral("next"),
            String.fromLiteral("previous"),
        },
        .required,
    );

    // 2. If stringValue is "next", return next.
    // 3. Return previous.
    const transition_direction_map = std.StaticStringMap(
        temporal_rs.c.TransitionDirection,
    ).initComptime(&.{
        .{ "next", temporal_rs.c.TransitionDirection_Next },
        .{ "previous", temporal_rs.c.TransitionDirection_Previous },
    });
    return transition_direction_map.get(string_value.asAscii()).?;
}

/// 13.15 GetTemporalFractionalSecondDigitsOption ( options )
/// https://tc39.es/proposal-temporal/#sec-temporal-gettemporalfractionalseconddigitsoption
pub fn getTemporalFractionalSecondDigitsOption(
    agent: *Agent,
    options: *Object,
) Agent.Error!temporal_rs.c.Precision {
    // 1. Let digitsValue be ? Get(options, "fractionalSecondDigits").
    const digits_value = try options.get(agent, PropertyKey.from("fractionalSecondDigits"));

    // 2. If digitsValue is undefined, return auto.
    if (digits_value.isUndefined()) {
        return .{
            .is_minute = false,
            .precision = temporal_rs.toOption(temporal_rs.c.OptionU8, null),
        };
    }

    // 3. If digitsValue is not a Number, then
    if (!digits_value.isNumber()) {
        // a. If ? ToString(digitsValue) is not "auto", throw a RangeError exception.
        if (!(try digits_value.toString(agent)).eql(String.fromLiteral("auto"))) {
            return agent.throwException(
                .range_error,
                "Invalid fractionalSecondDigits option {f}",
                .{digits_value},
            );
        }

        // b. Return auto.
        return .{
            .is_minute = false,
            .precision = temporal_rs.toOption(temporal_rs.c.OptionU8, null),
        };
    }

    // 4. If digitsValue is one of NaN, +∞𝔽, or -∞𝔽, throw a RangeError exception.
    if (!digits_value.asNumber().isFinite()) {
        return agent.throwException(
            .range_error,
            "Invalid fractionalSecondDigits option {f}",
            .{digits_value.asNumber()},
        );
    }

    // 5. Let digitCount be floor(ℝ(digitsValue)).
    const digit_count = digits_value.asNumber().floor().asFloat();

    // 6. If digitCount < 0 or digitCount > 9, throw a RangeError exception.
    if (digit_count < 0 or digit_count > 9) {
        return agent.throwException(
            .range_error,
            "Invalid fractionalSecondDigits option {f}",
            .{digits_value},
        );
    }

    // 7. Return digitCount.
    return .{
        .is_minute = false,
        .precision = temporal_rs.toOption(temporal_rs.c.OptionU8, @intFromFloat(digit_count)),
    };
}

/// 13.17 GetTemporalUnitValuedOption ( options, key, default )
/// https://tc39.es/proposal-temporal/#sec-temporal-gettemporalunitvaluedoption
pub fn getTemporalUnitValuedOption(
    agent: *Agent,
    options: *Object,
    comptime key: []const u8,
    comptime default: enum { required, unset },
) Agent.Error!?temporal_rs.c.Unit {
    // 1. Let allowedStrings be a List containing all values in the "Singular property name" and
    //    "Plural property name" columns of Table 21, except the header row.
    // 2. Append "auto" to allowedStrings.
    // 3. NOTE: For each singular Temporal unit name that is contained within allowedStrings, the
    //    corresponding plural name is also contained within it.
    const allowed_strings: []const *const String = &.{
        String.fromLiteral("auto"),
        String.fromLiteral("year"),
        String.fromLiteral("years"),
        String.fromLiteral("month"),
        String.fromLiteral("months"),
        String.fromLiteral("week"),
        String.fromLiteral("weeks"),
        String.fromLiteral("day"),
        String.fromLiteral("days"),
        String.fromLiteral("hour"),
        String.fromLiteral("hours"),
        String.fromLiteral("minute"),
        String.fromLiteral("minutes"),
        String.fromLiteral("second"),
        String.fromLiteral("seconds"),
        String.fromLiteral("millisecond"),
        String.fromLiteral("milliseconds"),
        String.fromLiteral("microsecond"),
        String.fromLiteral("microseconds"),
        String.fromLiteral("nanosecond"),
        String.fromLiteral("nanoseconds"),
    };

    // 4. If default is unset, then
    //     a. Let defaultValue be undefined.
    // 5. Else,
    //     a. Let defaultValue be default.
    // 6. Let value be ? GetOption(options, key, string, allowedStrings, defaultValue).
    const value = switch (default) {
        .unset => try options.getOption(
            agent,
            key,
            .string,
            allowed_strings,
            null,
        ) orelse {
            // 7. If value is undefined, return unset.
            return null;
        },
        .required => try options.getOption(
            agent,
            key,
            .string,
            allowed_strings,
            .required,
        ),
    };

    // 8. If value is "auto", return auto.
    // 9. Return the value in the "Value" column of Table 21 corresponding to the row with value in
    //    its "Singular property name" or "Plural property name" column.
    const unit_map = std.StaticStringMap(temporal_rs.c.Unit).initComptime(&.{
        .{ "auto", temporal_rs.c.Unit_Auto },
        .{ "year", temporal_rs.c.Unit_Year },
        .{ "years", temporal_rs.c.Unit_Year },
        .{ "month", temporal_rs.c.Unit_Month },
        .{ "months", temporal_rs.c.Unit_Month },
        .{ "week", temporal_rs.c.Unit_Week },
        .{ "weeks", temporal_rs.c.Unit_Week },
        .{ "day", temporal_rs.c.Unit_Day },
        .{ "days", temporal_rs.c.Unit_Day },
        .{ "hour", temporal_rs.c.Unit_Hour },
        .{ "hours", temporal_rs.c.Unit_Hour },
        .{ "minute", temporal_rs.c.Unit_Minute },
        .{ "minutes", temporal_rs.c.Unit_Minute },
        .{ "second", temporal_rs.c.Unit_Second },
        .{ "seconds", temporal_rs.c.Unit_Second },
        .{ "millisecond", temporal_rs.c.Unit_Millisecond },
        .{ "milliseconds", temporal_rs.c.Unit_Millisecond },
        .{ "microsecond", temporal_rs.c.Unit_Microsecond },
        .{ "microseconds", temporal_rs.c.Unit_Microsecond },
        .{ "nanosecond", temporal_rs.c.Unit_Nanosecond },
        .{ "nanoseconds", temporal_rs.c.Unit_Nanosecond },
    });
    return unit_map.get(value.asAscii()).?;
}

/// 13.18 ValidateTemporalUnitValue ( value, unitGroup [ , extraValues ] )
/// https://tc39.es/proposal-temporal/#sec-temporal-validatetemporalunitvaluedoption
pub fn validateTemporalUnitValue(
    agent: *Agent,
    maybe_value: ?temporal_rs.c.Unit,
    key: []const u8,
    unit_group: enum { date, time, datetime },
    extra_values: []const temporal_rs.c.Unit,
) Agent.Error!void {
    // 1. If value is unset, return unused.
    const value = maybe_value orelse return;

    // 2. If extraValues is present and extraValues contains value, return unused.
    if (std.mem.findScalar(temporal_rs.c.Unit, extra_values, value) != null) return;

    // 3. Let category be the value in the “Category” column of the row of Table 21 whose “Value”
    //    column contains value. If there is no such row, throw a RangeError exception.
    const category: enum { date, time } = switch (value) {
        temporal_rs.c.Unit_Auto => {
            return agent.throwException(.range_error, "Invalid value for option '{s}'", .{key});
        },
        temporal_rs.c.Unit_Year,
        temporal_rs.c.Unit_Month,
        temporal_rs.c.Unit_Week,
        temporal_rs.c.Unit_Day,
        => .date,
        temporal_rs.c.Unit_Hour,
        temporal_rs.c.Unit_Minute,
        temporal_rs.c.Unit_Second,
        temporal_rs.c.Unit_Millisecond,
        temporal_rs.c.Unit_Microsecond,
        temporal_rs.c.Unit_Nanosecond,
        => .time,
        else => unreachable,
    };

    // 4. If category is date and unitGroup is either date or datetime, return unused.
    // 5. If category is time and unitGroup is either time or datetime, return unused.
    switch (category) {
        .date => if (unit_group == .date or unit_group == .datetime) return,
        .time => if (unit_group == .time or unit_group == .datetime) return,
    }

    // 6. Throw a RangeError exception.
    return agent.throwException(.range_error, "Invalid value for option '{s}'", .{key});
}

/// 13.19 GetTemporalRelativeToOption ( options )
/// https://tc39.es/proposal-temporal/#sec-temporal-gettemporalrelativetooption
pub fn getTemporalRelativeToOption(agent: *Agent, options: *Object) Agent.Error!temporal_rs.RelativeTo {
    // 1. Let value be ? Get(options, "relativeTo").
    const value = try options.get(agent, PropertyKey.from("relativeTo"));

    // 2. If value is undefined, return the Record { [[PlainRelativeTo]]: undefined,
    //    [[ZonedRelativeTo]]: undefined }.
    if (value.isUndefined()) return .none;

    // 3. Let offsetBehaviour be option.
    // 4. Let matchBehaviour be match-exactly.

    // 5. If value is an Object, then
    const partial: temporal_rs.c.PartialZonedDateTime = if (value.isObject()) blk: {
        // a. If value has an [[InitializedTemporalZonedDateTime]] internal slot, then
        if (value.asObject().cast(builtins.temporal.ZonedDateTime)) |zoned_date_time_| {
            // i. Return the Record { [[PlainRelativeTo]]: undefined, [[ZonedRelativeTo]]: value }.
            return .{
                .borrowed_zoned_date_time = zoned_date_time_.fields.inner,
            };
        }

        // b. If value has an [[InitializedTemporalDate]] internal slot, then
        if (value.asObject().cast(builtins.temporal.PlainDate)) |plain_date_| {
            // i. Return the Record { [[PlainRelativeTo]]: value, [[ZonedRelativeTo]]: undefined }.
            return .{
                .borrowed_plain_date = plain_date_.fields.inner,
            };
        }

        // c. If value has an [[InitializedTemporalDateTime]] internal slot, then
        if (value.asObject().cast(builtins.temporal.PlainDateTime)) |plain_date_time_| {
            // i. Let plainDate be ! CreateTemporalDate(value.[[ISODateTime]].[[ISODate]],
            //    value.[[Calendar]]).
            const temporal_rs_plain_date = temporal_rs.c.temporal_rs_PlainDateTime_to_plain_date(
                plain_date_time_.fields.inner,
            );

            // ii. Return the Record { [[PlainRelativeTo]]: plainDate,
            //     [[ZonedRelativeTo]]: undefined }.
            return .{ .owned_plain_date = temporal_rs_plain_date.? };
        }

        // d. Let calendar be ? GetTemporalCalendarIdentifierWithISODefault(value).
        const calendar = try getTemporalCalendarIdentifierWithISODefault(agent, value.asObject());

        // e. Let fields be ? PrepareCalendarFields(calendar, value, « year, month, month-code,
        //    day », « hour, minute, second, millisecond, microsecond, nanosecond, offset,
        //    time-zone », «»).
        const fields = try prepareCalendarFields(
            agent,
            calendar,
            value.asObject(),
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
                .offset,
                .time_zone,
            }),
            .none,
        );
        const partial: temporal_rs.c.PartialZonedDateTime = .{
            .date = fields.date,
            .time = fields.time,
            .timezone = fields.timezone,
            .offset = fields.offset,
        };

        // f. Let result be ? InterpretTemporalDateTimeFields(calendar, fields, constrain).
        // g. Let timeZone be fields.[[TimeZone]].
        // h. Let offsetString be fields.[[OffsetString]].
        // i. If offsetString is unset, then
        // i. Set offsetBehaviour to wall.
        // j. Let isoDate be result.[[ISODate]].
        // k. Let time be result.[[Time]].
        break :blk partial;
    } else {
        // 6. Else,
        // a. If value is not a String, throw a TypeError exception.
        if (!value.isString()) {
            return agent.throwException(
                .type_error,
                "'relativeTo' option value must be a string or object",
                .{},
            );
        }

        // b. Let result be ? ParseISODateTime(value, « TemporalDateTimeString[+Zoned],
        //    TemporalDateTimeString[~Zoned] »).
        // c. Let offsetString be result.[[TimeZone]].[[OffsetString]].
        // d. Let annotation be result.[[TimeZone]].[[TimeZoneAnnotation]].
        // e. If annotation is empty, then
        //     i. Let timeZone be unset.
        // f. Else,
        //     i. Let timeZone be ? ToTemporalTimeZoneIdentifier(annotation).
        //     ii. If result.[[TimeZone]].[[Z]] is true, then
        //         1. Set offsetBehaviour to exact.
        //     iii. Else if offsetString is empty, then
        //         1. Set offsetBehaviour to wall.
        //     iv. Set matchBehaviour to match-minutes.
        //     v. If offsetString is not empty, then
        //         1. Let offsetParseResult be ParseText(StringToCodePoints(offsetString),
        //            UTCOffset[+SubMinutePrecision]).
        //         2. Assert: offsetParseResult is a Parse Node.
        //         3. If offsetParseResult contains more than one MinuteSecond Parse Node, set
        //            matchBehaviour to match-exactly.
        // g. Let calendar be result.[[Calendar]].
        // h. If calendar is empty, set calendar to "iso8601".
        // i. Set calendar to ? CanonicalizeCalendar(calendar).
        // j. Let isoDate be CreateISODateRecord(result.[[Year]], result.[[Month]], result.[[Day]]).
        // k. Let time be result.[[Time]].
        const owned_relative_to = switch (value.asString().asAsciiOrUtf16()) {
            .ascii => |ascii| try builtins.temporal.extractResult(
                agent,
                temporal_rs.c.temporal_rs_OwnedRelativeTo_from_utf8(
                    temporal_rs.toDiplomatStringView(ascii),
                ),
            ),
            .utf16 => |utf16| try builtins.temporal.extractResult(
                agent,
                temporal_rs.c.temporal_rs_OwnedRelativeTo_from_utf16(
                    temporal_rs.toDiplomatString16View(utf16),
                ),
            ),
        };
        return temporal_rs.RelativeTo.fromOwned(owned_relative_to);
    };

    // 7. If timeZone is unset, then
    if (!partial.timezone.is_ok) {
        // a. Let plainDate be ? CreateTemporalDate(isoDate, calendar).
        const temporal_rs_plain_date = try builtins.temporal.extractResult(
            agent,
            temporal_rs.c.temporal_rs_PlainDate_from_partial(
                partial.date,
                temporal_rs.toArithmeticOverflowOption(temporal_rs.c.ArithmeticOverflow_Constrain),
            ),
        );

        // b. Return the Record { [[PlainRelativeTo]]: plainDate, [[ZonedRelativeTo]]: undefined }.
        return .{ .owned_plain_date = temporal_rs_plain_date.? };
    }

    // 8. If offsetBehaviour is option, then
    //     a. Let offsetNs be ! ParseDateTimeUTCOffset(offsetString).
    // 9. Else,
    //     a. Let offsetNs be 0.
    // 10. Let epochNanoseconds be ? InterpretISODateTimeOffset(isoDate, time, offsetBehaviour,
    //     offsetNs, timeZone, compatible, reject, matchBehaviour).
    // 11. Let zonedRelativeTo be ! CreateTemporalZonedDateTime(epochNanoseconds, timeZone,
    //     calendar).
    const temporal_rs_zoned_date_time = try builtins.temporal.extractResult(
        agent,
        temporal_rs.c.temporal_rs_ZonedDateTime_from_partial(
            partial,
            temporal_rs.toArithmeticOverflowOption(temporal_rs.c.ArithmeticOverflow_Constrain),
            temporal_rs.toDisambiguationOption(temporal_rs.c.Disambiguation_Compatible),
            temporal_rs.toOffsetDisambiguationOption(temporal_rs.c.OffsetDisambiguation_Reject),
        ),
    );

    // 12. Return the Record { [[PlainRelativeTo]]: undefined,
    //     [[ZonedRelativeTo]]: zonedRelativeTo }.
    return .{ .owned_zoned_date_time = temporal_rs_zoned_date_time.? };
}

/// 13.24 IsPartialTemporalObject ( value )
/// https://tc39.es/proposal-temporal/#sec-temporal-ispartialtemporalobject
pub fn isPartialTemporalObject(agent: *Agent, value: Value) Agent.Error!bool {
    // 1. If value is not an Object, return false.
    if (!value.isObject()) return false;

    // 2. If value has an [[InitializedTemporalDate]], [[InitializedTemporalDateTime]],
    //    [[InitializedTemporalMonthDay]], [[InitializedTemporalTime]],
    //    [[InitializedTemporalYearMonth]], or [[InitializedTemporalZonedDateTime]] internal slot,
    //    return false.
    if (value.asObject().is(PlainDate) or
        value.asObject().is(PlainDateTime) or
        value.asObject().is(PlainMonthDay) or
        value.asObject().is(PlainTime) or
        value.asObject().is(PlainYearMonth) or
        value.asObject().is(ZonedDateTime))
    {
        return false;
    }

    // 3. Let calendarProperty be ? Get(value, "calendar").
    const calendar_property = try value.asObject().get(agent, PropertyKey.from("calendar"));

    // 4. If calendarProperty is not undefined, return false.
    if (!calendar_property.isUndefined()) return false;

    // 5. Let timeZoneProperty be ? Get(value, "timeZone").
    const time_zone_property = try value.asObject().get(agent, PropertyKey.from("timeZone"));

    // 6. If timeZoneProperty is not undefined, return false.
    if (!time_zone_property.isUndefined()) return false;

    // 7. Return true.
    return true;
}

/// 13.41 ToOffsetString ( argument )
/// https://tc39.es/proposal-temporal/#sec-temporal-tooffsetstring
fn toOffsetString(agent: *Agent, argument: Value) Agent.Error![]const u8 {
    // 1. Let offset be ? ToPrimitive(argument, string).
    const offset = try argument.toPrimitive(agent, .string);

    // 2. If offset is not a String, throw a TypeError exception.
    if (!offset.isString()) {
        return agent.throwException(.type_error, "Offset must be a string", .{});
    }

    // 3. Perform ? ParseDateTimeUTCOffset(offset).
    // 4. Return offset.
    const offset_utf8 = try offset.asString().toUtf8(agent.gc_allocator);
    _ = try builtins.temporal.extractResult(
        agent,
        temporal_rs.c.temporal_rs_TimeZone_try_from_offset_str(
            temporal_rs.toDiplomatStringView(offset_utf8),
        ),
    );
    return offset_utf8;
}

/// 13.43 GetDifferenceSettings ( operation, options, unitGroup, disallowedUnits, fallbackSmallestUnit, smallestLargestDefaultUnit )
/// https://tc39.es/proposal-temporal/#sec-temporal-getdifferencesettings
pub fn getTemporalDifferenceSettingsWithoutValidation(
    agent: *Agent,
    options: *Object,
) Agent.Error!temporal_rs.c.DifferenceSettings {
    // 1. NOTE: The following steps read options and perform independent validation in alphabetical
    //    order.

    // 2. Let largestUnit be ? GetTemporalUnitValuedOption(options, "largestUnit", unset).
    const largest_unit = try getTemporalUnitValuedOption(
        agent,
        options,
        "largestUnit",
        .unset,
    );

    // 3. Let roundingIncrement be ? GetRoundingIncrementOption(options).
    const rounding_increment = try getTemporalRoundingIncrementOption(agent, options);

    // 4. Let roundingMode be ? GetRoundingModeOption(options, trunc).
    const rounding_mode = try getTemporalRoundingModeOption(
        agent,
        options,
        temporal_rs.c.RoundingMode_Trunc,
    );

    // 5. Let smallestUnit be ? GetTemporalUnitValuedOption(options, "smallestUnit", unset).
    const smallest_unit = try getTemporalUnitValuedOption(
        agent,
        options,
        "smallestUnit",
        .unset,
    );

    // 6. Perform ? ValidateTemporalUnitValue(largestUnit, unitGroup, « auto »).
    // 7. If largestUnit is unset, then
    //     a. Set largestUnit to auto.
    // 8. If disallowedUnits contains largestUnit, throw a RangeError exception.
    // 9. Perform ? ValidateTemporalUnitValue(smallestUnit, unitGroup).
    // 10. If smallestUnit is unset, then
    //     a. Set smallestUnit to fallbackSmallestUnit.
    // 11. If disallowedUnits contains smallestUnit, throw a RangeError exception.
    // 12. Let defaultLargestUnit be LargerOfTwoTemporalUnits(smallestLargestDefaultUnit,
    //     smallestUnit).
    // 13. If largestUnit is auto, set largestUnit to defaultLargestUnit.
    // 14. If LargerOfTwoTemporalUnits(largestUnit, smallestUnit) is not largestUnit, throw a
    //     RangeError exception.
    // 15. Let maximum be MaximumTemporalDurationRoundingIncrement(smallestUnit).
    // 16. If maximum is not unset, perform ? ValidateTemporalRoundingIncrement(roundingIncrement,
    //     maximum, false).
    // 17. If operation is since, then
    //     a. Set roundingMode to NegateRoundingMode(roundingMode).
    // NOTE: These steps are handled by temporal_rs.

    // 18. Return the Record { [[SmallestUnit]]: smallestUnit, [[LargestUnit]]: largestUnit,
    //     [[RoundingMode]]: roundingMode, [[RoundingIncrement]]: roundingIncrement, }.
    return .{
        .largest_unit = temporal_rs.toUnitOption(largest_unit),
        .smallest_unit = temporal_rs.toUnitOption(smallest_unit),
        .rounding_mode = temporal_rs.toRoundingModeOption(rounding_mode),
        .increment = temporal_rs.toOption(temporal_rs.c.OptionU32, rounding_increment),
    };
}

/// 14.5.2.2 GetRoundingModeOption ( options, fallback )
/// https://tc39.es/proposal-temporal/#sec-temporal-getroundingmodeoption
pub fn getTemporalRoundingModeOption(
    agent: *Agent,
    options: *Object,
    fallback: temporal_rs.c.RoundingMode,
) Agent.Error!temporal_rs.c.RoundingMode {
    // 1. Let allowedStrings be the List of Strings from the "String Identifier" column of Table 28.
    // 2. Let stringFallback be the value from the "String Identifier" column of the row with
    //    fallback in its "Rounding Mode" column.
    // 3. Let stringValue be ? GetOption(options, "roundingMode", string, allowedStrings,
    //    stringFallback).
    const rounding_mode = try options.getOption(
        agent,
        "roundingMode",
        .string,
        &.{
            String.fromLiteral("ceil"),
            String.fromLiteral("floor"),
            String.fromLiteral("expand"),
            String.fromLiteral("trunc"),
            String.fromLiteral("halfCeil"),
            String.fromLiteral("halfFloor"),
            String.fromLiteral("halfExpand"),
            String.fromLiteral("halfTrunc"),
            String.fromLiteral("halfEven"),
        },
        switch (fallback) {
            temporal_rs.c.RoundingMode_Ceil => String.fromLiteral("ceil"),
            temporal_rs.c.RoundingMode_Floor => String.fromLiteral("floor"),
            temporal_rs.c.RoundingMode_Expand => String.fromLiteral("expand"),
            temporal_rs.c.RoundingMode_Trunc => String.fromLiteral("trunc"),
            temporal_rs.c.RoundingMode_HalfCeil => String.fromLiteral("halfCeil"),
            temporal_rs.c.RoundingMode_HalfFloor => String.fromLiteral("halfFloor"),
            temporal_rs.c.RoundingMode_HalfExpand => String.fromLiteral("halfExpand"),
            temporal_rs.c.RoundingMode_HalfTrunc => String.fromLiteral("halfTrunc"),
            temporal_rs.c.RoundingMode_HalfEven => String.fromLiteral("halfEven"),
            else => unreachable,
        },
    );

    // 4. Return the value from the "Rounding Mode" column of the row with stringValue in its
    //    "String Identifier" column.
    const rounding_mode_map = std.StaticStringMap(temporal_rs.c.RoundingMode).initComptime(&.{
        .{ "ceil", temporal_rs.c.RoundingMode_Ceil },
        .{ "floor", temporal_rs.c.RoundingMode_Floor },
        .{ "expand", temporal_rs.c.RoundingMode_Expand },
        .{ "trunc", temporal_rs.c.RoundingMode_Trunc },
        .{ "halfCeil", temporal_rs.c.RoundingMode_HalfCeil },
        .{ "halfFloor", temporal_rs.c.RoundingMode_HalfFloor },
        .{ "halfExpand", temporal_rs.c.RoundingMode_HalfExpand },
        .{ "halfTrunc", temporal_rs.c.RoundingMode_HalfTrunc },
        .{ "halfEven", temporal_rs.c.RoundingMode_HalfEven },
    });
    return rounding_mode_map.get(rounding_mode.asAscii()).?;
}

/// 14.5.2.3 GetRoundingIncrementOption ( options )
/// https://tc39.es/proposal-temporal/#sec-temporal-getroundingincrementoption
pub fn getTemporalRoundingIncrementOption(agent: *Agent, options: *Object) Agent.Error!u32 {
    // 1. Let value be ? Get(options, "roundingIncrement").
    const value = try options.get(agent, PropertyKey.from("roundingIncrement"));

    // 2. If value is undefined, return 1𝔽.
    if (value.isUndefined()) return 1;

    // 3. Let integerIncrement be ? ToIntegerWithTruncation(value).
    const integer_increment = try value.toIntegerWithTruncation(agent);

    // 4. If integerIncrement < 1 or integerIncrement > 10**9, throw a RangeError exception.
    if (integer_increment < 1 or integer_increment > 1000000000) {
        return agent.throwException(
            .range_error,
            "Invalid value for option 'roundingIncrement'",
            .{},
        );
    }

    // 5. Return integerIncrement.
    return @intFromFloat(integer_increment);
}
