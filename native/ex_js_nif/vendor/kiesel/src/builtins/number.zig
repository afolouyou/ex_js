//! 21.1 Number Objects
//! https://tc39.es/ecma262/#sec-number-objects

const std = @import("std");

const builtins = @import("../builtins.zig");
const execution = @import("../execution.zig");
const types = @import("../types.zig");
const utils = @import("../utils.zig");

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

/// 21.1.2 Properties of the Number Constructor
/// https://tc39.es/ecma262/#sec-properties-of-the-number-constructor
pub const constructor = struct {
    pub fn create(agent: *Agent, realm: *Realm) std.mem.Allocator.Error!*Object {
        const builtin_function = try createBuiltinFunction(
            agent,
            .{ .constructor = impl },
            1,
            "Number",
            .{ .realm = realm, .proto = try realm.intrinsic(.function_prototype) },
        );
        return &builtin_function.object;
    }

    pub fn init(agent: *Agent, realm: *Realm, object: *Object) std.mem.Allocator.Error!void {
        // 21.1.2.1 Number.EPSILON
        // https://tc39.es/ecma262/#sec-number.epsilon
        try object.defineBuiltinPropertyWithAttributes(
            agent,
            "EPSILON",
            Value.from(std.math.floatEps(f64)),
            .none,
        );

        // 21.1.2.6 Number.MAX_SAFE_INTEGER
        // https://tc39.es/ecma262/#sec-number.max_safe_integer
        try object.defineBuiltinPropertyWithAttributes(
            agent,
            "MAX_SAFE_INTEGER",
            Value.from(std.math.maxInt(u53)),
            .none,
        );

        // 21.1.2.7 Number.MAX_VALUE
        // https://tc39.es/ecma262/#sec-number.max_value
        try object.defineBuiltinPropertyWithAttributes(
            agent,
            "MAX_VALUE",
            Value.from(std.math.floatMax(f64)),
            .none,
        );

        // 21.1.2.8 Number.MIN_SAFE_INTEGER
        // https://tc39.es/ecma262/#sec-number.min_safe_integer
        try object.defineBuiltinPropertyWithAttributes(
            agent,
            "MIN_SAFE_INTEGER",
            Value.from(-@as(f64, @floatFromInt(std.math.maxInt(u53)))),
            .none,
        );

        // 21.1.2.9 Number.MIN_VALUE
        // https://tc39.es/ecma262/#sec-number.min_value
        try object.defineBuiltinPropertyWithAttributes(
            agent,
            "MIN_VALUE",
            Value.from(std.math.floatTrueMin(f64)),
            .none,
        );

        // 21.1.2.10 Number.NaN
        // https://tc39.es/ecma262/#sec-number.nan
        try object.defineBuiltinPropertyWithAttributes(
            agent,
            "NaN",
            .nan,
            .none,
        );

        // 21.1.2.11 Number.NEGATIVE_INFINITY
        // https://tc39.es/ecma262/#sec-number.negative_infinity
        try object.defineBuiltinPropertyWithAttributes(
            agent,
            "NEGATIVE_INFINITY",
            .negative_infinity,
            .none,
        );

        // 21.1.2.12 Number.parseFloat ( string )
        // https://tc39.es/ecma262/#sec-number.parsefloat
        try object.defineBuiltinProperty(agent, "parseFloat", Value.from(
            try realm.intrinsic(.parse_float),
        ));

        // 21.1.2.13 Number.parseInt ( string, radix )
        // https://tc39.es/ecma262/#sec-number.parseint
        try object.defineBuiltinProperty(agent, "parseInt", Value.from(
            try realm.intrinsic(.parse_int),
        ));

        // 21.1.2.14 Number.POSITIVE_INFINITY
        // https://tc39.es/ecma262/#sec-number.positive_infinity
        try object.defineBuiltinPropertyWithAttributes(
            agent,
            "POSITIVE_INFINITY",
            .infinity,
            .none,
        );

        try object.defineBuiltinFunction(agent, "isFinite", isFinite, 1, realm);
        try object.defineBuiltinFunction(agent, "isInteger", isInteger, 1, realm);
        try object.defineBuiltinFunction(agent, "isNaN", isNaN, 1, realm);
        try object.defineBuiltinFunction(agent, "isSafeInteger", isSafeInteger, 1, realm);

        // 21.1.2.15 Number.prototype
        // https://tc39.es/ecma262/#sec-number.prototype
        try object.defineBuiltinPropertyWithAttributes(
            agent,
            "prototype",
            Value.from(try realm.intrinsic(.number_prototype)),
            .none,
        );
    }

    /// 21.1.1.1 Number ( value )
    /// https://tc39.es/ecma262/#sec-number-constructor-number-value
    fn impl(agent: *Agent, arguments: Arguments, new_target: ?*Object) Agent.Error!Value {
        const value = arguments.get(0);

        const n = blk: {
            // 1. If value is present, then
            if (arguments.count() != 0) {
                // a. Let primitive be ? ToNumeric(value).
                const primitive = try value.toNumeric(agent);

                // b. If primitive is a BigInt, let n be 𝔽(ℝ(primitive)).
                if (primitive == .big_int) {
                    break :blk types.Number.from(primitive.big_int.asFloat());
                }

                // c. Else, let n be primitive.
                break :blk primitive.number;
            } else {
                // 2. Else,
                // a. Let n be +0𝔽.
                break :blk types.Number.from(0);
            }
        };

        // 3. If NewTarget is undefined, return n.
        if (new_target == null) return Value.from(n);

        // 4. Let obj be ? OrdinaryCreateFromConstructor(NewTarget, "%Number.prototype%",
        //    « [[NumberData]] »).
        const number = try ordinaryCreateFromConstructor(
            Number,
            agent,
            new_target.?,
            .number_prototype,
            .{
                // 5. Set obj.[[NumberData]] to n.
                .number_data = n,
            },
        );

        // 6. Return obj.
        return Value.from(&number.object);
    }

    /// 21.1.2.2 Number.isFinite ( number )
    /// https://tc39.es/ecma262/#sec-number.isfinite
    fn isFinite(_: *Agent, _: Value, arguments: Arguments) Agent.Error!Value {
        const number = arguments.get(0);

        // 1. If number is not a Number, return false.
        if (!number.isNumber()) return .false;

        // 2. If number is not finite, return false.
        if (!number.asNumber().isFinite()) return .false;

        // 3. Return true.
        return .true;
    }

    /// 21.1.2.3 Number.isInteger ( number )
    /// https://tc39.es/ecma262/#sec-number.isinteger
    fn isInteger(_: *Agent, _: Value, arguments: Arguments) Agent.Error!Value {
        const number = arguments.get(0);

        // 1. If number is an integral Number, return true.
        if (number.isNumber() and number.asNumber().isIntegral()) return .true;

        // 2. Return false.
        return .false;
    }

    /// 21.1.2.4 Number.isNaN ( number )
    /// https://tc39.es/ecma262/#sec-number.isnan
    fn isNaN(_: *Agent, _: Value, arguments: Arguments) Agent.Error!Value {
        const number = arguments.get(0);

        // 1. If number is not a Number, return false.
        if (!number.isNumber()) return .false;

        // 2. If number is NaN, return true.
        if (number.asNumber().isNan()) return .true;

        // 3. Return false.
        return .false;
    }

    /// 21.1.2.5 Number.isSafeInteger ( number )
    /// https://tc39.es/ecma262/#sec-number.issafeinteger
    fn isSafeInteger(_: *Agent, _: Value, arguments: Arguments) Agent.Error!Value {
        const number = arguments.get(0);

        // 1. If number is an integral Number, then
        if (number.isNumber() and number.asNumber().isIntegral()) {
            // a. If abs(ℝ(number)) ≤ 2**53 - 1, return true.
            if (@abs(number.asNumber().asFloat()) <= @as(f64, @floatFromInt(std.math.maxInt(u53)))) {
                return .true;
            }
        }

        // 2. Return false.
        return .false;
    }
};

/// 21.1.3 Properties of the Number Prototype Object
/// https://tc39.es/ecma262/#sec-properties-of-the-number-prototype-object
pub const prototype = struct {
    pub fn create(agent: *Agent, realm: *Realm) std.mem.Allocator.Error!*Object {
        const number = try Number.create(agent, .{
            .fields = .{
                .number_data = types.Number.from(0),
            },
            .prototype = try realm.intrinsic(.object_prototype),
        });
        return &number.object;
    }

    pub fn init(agent: *Agent, realm: *Realm, object: *Object) std.mem.Allocator.Error!void {
        try object.defineBuiltinFunction(agent, "toExponential", toExponential, 1, realm);
        try object.defineBuiltinFunction(agent, "toFixed", toFixed, 1, realm);
        try object.defineBuiltinFunction(agent, "toLocaleString", toLocaleString, 0, realm);
        try object.defineBuiltinFunction(agent, "toPrecision", toPrecision, 1, realm);
        try object.defineBuiltinFunction(agent, "toString", toString, 1, realm);
        try object.defineBuiltinFunction(agent, "valueOf", valueOf, 0, realm);

        // 21.1.3.1 Number.prototype.constructor
        // https://tc39.es/ecma262/#sec-number.prototype.constructor
        try object.defineBuiltinProperty(
            agent,
            "constructor",
            Value.from(try realm.intrinsic(.number)),
        );
    }

    /// 21.1.3.7.1 ThisNumberValue ( arg )
    /// https://tc39.es/ecma262/#sec-thisnumbervalue
    fn thisNumberValue(agent: *Agent, arg: Value) error{ExceptionThrown}!types.Number {
        // 1. If arg is a Number, return arg.
        if (arg.isNumber()) return arg.asNumber();

        // 2. If arg is an Object and arg has a [[NumberData]] internal slot, then
        if (arg.castObject(Number)) |number| {
            // a. Let number be arg.[[NumberData]].
            // b. Assert: number is a Number.
            // c. Return number.
            return number.fields.number_data;
        }

        // 3. Throw a TypeError exception.
        return agent.throwException(
            .type_error,
            "This value must be a number or Number object",
            .{},
        );
    }

    /// 21.1.3.2 Number.prototype.toExponential ( fractionDigits )
    /// https://tc39.es/ecma262/#sec-number.prototype.toexponential
    fn toExponential(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const fraction_digits_value = arguments.get(0);

        // 1. Let x be ? ThisNumberValue(this value).
        const x_number = try thisNumberValue(agent, this_value);

        // 2. Let f be ? ToIntegerOrInfinity(fractionDigits).
        // 3. Assert: If fractionDigits is undefined, then f is 0.
        const fraction_digits_f64 = try fraction_digits_value.toIntegerOrInfinity(agent);

        // 4. If x is not finite, return Number::toString(x, 10).
        if (!x_number.isFinite()) {
            return Value.from(try x_number.toString(agent, 10));
        }

        // 5. If f < 0 or f > 100, throw a RangeError exception.
        if (!std.math.isFinite(fraction_digits_f64)) {
            return agent.throwException(.range_error, "Fraction digits must be a finite number", .{});
        }
        if (fraction_digits_f64 < 0 or fraction_digits_f64 > 100) {
            return agent.throwException(.range_error, "Fraction digits must be in range 0-100", .{});
        }
        const fraction_digits: usize = @intFromFloat(fraction_digits_f64);

        // 6. Set x to ℝ(x).
        var x = x_number.asFloat();
        if (std.math.isNegativeZero(x)) x = 0;

        // 7. Let s be the empty String.
        var sign: []const u8 = "";

        // 8. If x < 0, then
        if (x < 0) {
            // a. Set s to "-".
            sign = "-";

            // b. Set x to -x.
            x = -x;
        }

        // 9-15.
        var formatted = if (fraction_digits_value.isUndefined())
            try agent.gc_allocator.print("{s}{e}", .{ sign, x })
        else
            try agent.gc_allocator.print("{s}{e:.[2]}", .{ sign, x, fraction_digits });
        // Zig omits the '+' for positive exponents, so we need to add it ourselves
        if (std.mem.find(u8, formatted, "e-") == null) {
            const index = std.mem.find(u8, formatted, "e").?;
            formatted = try agent.gc_allocator.print(
                "{s}e+{s}",
                .{ formatted[0..index], formatted[index + 1 ..] },
            );
        }
        return Value.from(try String.fromAscii(agent, formatted));
    }

    /// 21.1.3.3 Number.prototype.toFixed ( fractionDigits )
    /// https://tc39.es/ecma262/#sec-number.prototype.tofixed
    fn toFixed(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const fraction_digits_value = arguments.get(0);

        // 1. Let number be ? ThisNumberValue(this value).
        const number = try thisNumberValue(agent, this_value);

        // 2. Let fractionCount be ? ToIntegerOrInfinity(fractionDigits).
        // 3. Assert: If fractionDigits is undefined, then fractionCount is 0.
        const fraction_digits_f64 = try fraction_digits_value.toIntegerOrInfinity(agent);

        // 4. If fractionCount is not finite, throw a RangeError exception.
        if (!std.math.isFinite(fraction_digits_f64)) {
            return agent.throwException(.range_error, "Fraction digits must be a finite number", .{});
        }

        // 5. If fractionCount < 0 or fractionCount > 100, throw a RangeError exception.
        if (fraction_digits_f64 < 0 or fraction_digits_f64 > 100) {
            return agent.throwException(.range_error, "Fraction digits must be in range 0-100", .{});
        }
        const fraction_digits: usize = @intFromFloat(fraction_digits_f64);

        // 6. If number is not finite, return Number::toString(number, 10).
        if (!number.isFinite()) {
            return Value.from(try number.toString(agent, 10));
        }

        // 7. Set number to ℝ(number).
        var number_f64 = number.asFloat();

        // 8. Let sign be the empty String.
        var sign: []const u8 = "";

        // 9. If number < 0, then
        if (number_f64 < 0) {
            // a. Set sign to "-".
            sign = "-";

            // b. Set number to -number.
            number_f64 = -number_f64;
        }

        // 10. If number ≥ 10**21, then
        if (number_f64 >= 1e21) {
            // a. Let digitString be ! ToString(𝔽(number)).
            return Value.from(Value.from(number_f64).toString(agent) catch |err| try noexcept(err));
        }

        // 11. Else,
        //     a. Let intValue be an integer for which intValue / 10**fractionCount - number is as
        //        close to zero as possible. If there are two such intValue, pick the larger
        //        intValue.
        //     b. If intValue = 0, let digitString be "0"; else let digitString be the String value
        //        consisting of the digits of the decimal representation of intValue (in order, with
        //        no leading zeroes).
        //     c. If fractionCount ≠ 0, then
        //         i. Let digitCount be the length of digitString.
        //         ii. If digitCount ≤ fractionCount, then
        //             1. Let zeroPad be the String value consisting of
        //                fractionCount + 1 - digitCount occurrences of the code unit 0x0030 (DIGIT
        //                ZERO).
        //             2. Set digitString to the string-concatenation of zeroPad and digitString.
        //             3. Set digitCount to fractionCount + 1.
        //         iii. Let intPart be the first digitCount - fractionCount code units of
        //              digitString.
        //         iv. Let fractionalPart be the other fractionCount code units of digitString.
        //         v. Set digitString to the string-concatenation of intPart, ".", and
        //            fractionalPart.
        // 12. Return the string-concatenation of sign and digitString.
        return Value.from(
            try String.fromAscii(agent, try agent.gc_allocator.print(
                "{s}{d:.[2]}",
                .{ sign, number_f64, fraction_digits },
            )),
        );
    }

    /// 21.1.3.4 Number.prototype.toLocaleString ( [ reserved1 [ , reserved2 ] ] )
    /// https://tc39.es/ecma262/#sec-number.prototype.tolocalestring
    fn toLocaleString(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        const number = try thisNumberValue(agent, this_value);
        return Value.from(try number.toString(agent, 10));
    }

    /// 21.1.3.5 Number.prototype.toPrecision ( precision )
    /// https://tc39.es/ecma262/#sec-number.prototype.toprecision
    fn toPrecision(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const precision_value = arguments.get(0);

        // 1. Let number be ? ThisNumberValue(this value).
        const number = try thisNumberValue(agent, this_value);

        // 2. If precision is undefined, return ! ToString(number).
        if (precision_value.isUndefined()) {
            return Value.from(Value.from(number).toString(agent) catch |err| try noexcept(err));
        }

        // 3. Let precisionCount be ? ToIntegerOrInfinity(precision).
        const precision_count = try precision_value.toIntegerOrInfinity(agent);

        // 4. If number is not finite, return Number::toString(number, 10).
        if (!number.isFinite()) {
            return Value.from(try number.toString(agent, 10));
        }

        // 5. If precisionCount < 1 or precisionCount > 100, throw a RangeError exception.
        if (precision_count < 1 or precision_count > 100) {
            return agent.throwException(.range_error, "Precision must be in range 1-100", .{});
        }
        const precision: usize = @intFromFloat(precision_count);

        // 6. Set number to ℝ(number).
        var number_f64 = number.asFloat();

        // 7. Let sign be the empty String.
        var sign: []const u8 = "";

        // 8. If number < 0, then
        if (number_f64 < 0) {
            // a. Set sign to the code unit 0x002D (HYPHEN-MINUS).
            sign = "-";

            // b. Set number to -number.
            number_f64 = -number_f64;
        }

        var exponent: i64 = undefined;
        var significand: []const u8 = undefined;

        // 9. If number = 0, then
        if (number_f64 == 0) {
            // a. Let significand be the String value consisting of precisionCount occurrences of
            //    the code unit 0x0030 (DIGIT ZERO).
            significand = try agent.gc_allocator.print("{s:0>[1]}", .{ "", precision });

            // b. Let exponent be 0.
            exponent = 0;
        } else {
            // 10. Else,
            // a. Let exponent and intSignificand be integers such that
            //    10**(precisionCount - 1) ≤ intSignificand < 10**precisionCount and for which
            //    intSignificand × 10**(exponent - precisionCount + 1) - number is as close to zero
            //    as possible. If there are two such sets of exponent and intSignificand, pick the
            //    exponent and intSignificand for which
            //    intSignificand × 10**(exponent - precisionCount + 1) is larger.
            exponent = @intFromFloat(@floor(std.math.log10(number_f64)));
            const int_significand = @round(
                number_f64 / std.math.pow(
                    f64,
                    10,
                    @floatFromInt(exponent - @as(i64, @intCast(precision)) + 1),
                ),
            );

            // b. Let significand be the String value consisting of the digits of the decimal
            //    representation of intSignificand (in order, with no leading zeroes).
            significand = try agent.gc_allocator.print("{d}", .{int_significand});

            // c. If exponent < -6 or exponent ≥ precisionCount, then
            if (exponent < -6 or exponent >= precision) {
                // i. Assert: exponent ≠ 0.
                std.debug.assert(exponent != 0);

                // ii. If precisionCount ≠ 1, then
                if (precision != 1) {
                    // 1. Let intPart be the first code unit of significand.
                    const int_part = significand[0..1];

                    // 2. Let fractionalPart be the other precisionCount - 1 code units of
                    //    significand.
                    const fractional_part = significand[1..];

                    // 3. Set significand to the string-concatenation of intPart, ".", and
                    //    fractionalPart.
                    significand = try agent.gc_allocator.print(
                        "{s}.{s}",
                        .{ int_part, fractional_part },
                    );
                }

                var exponent_sign: u8 = undefined;

                // iii. If exponent > 0, then
                if (exponent > 0) {
                    // 1. Let exponentSign be the code unit 0x002B (PLUS SIGN).
                    exponent_sign = '+';
                } else {
                    // iv. Else,
                    // 1. Assert: exponent < 0.
                    std.debug.assert(exponent < 0);

                    // 2. Let exponentSign be the code unit 0x002D (HYPHEN-MINUS).
                    exponent_sign = '-';

                    // 3. Set exponent to -exponent.
                    exponent = -exponent;
                }

                // v. Let exponentDigits be the String value consisting of the digits of the decimal
                //    representation of exponent (in order, with no leading zeroes).
                // vi. Return the string-concatenation of sign, significand, the code unit 0x0065
                //     (LATIN SMALL LETTER E), exponentSign, and exponentDigits.
                return Value.from(
                    try String.fromAscii(agent, try agent.gc_allocator.print(
                        "{s}{s}e{c}{d}",
                        .{ sign, significand, exponent_sign, exponent },
                    )),
                );
            }
        }

        // 11. If exponent = precisionCount - 1, return the string-concatenation of sign and
        //     significand.
        if (exponent == precision - 1) {
            return Value.from(
                try String.fromAscii(agent, try agent.gc_allocator.print(
                    "{s}{s}",
                    .{ sign, significand },
                )),
            );
        }

        // 12. If exponent ≥ 0, then
        if (exponent >= 0) {
            // a. Set significand to the string-concatenation of the first exponent + 1 code units
            //    of significand, the code unit 0x002E (FULL STOP), and the remaining
            //    precisionCount - (exponent + 1) code units of significand.
            significand = try agent.gc_allocator.print(
                "{s}.{s}",
                .{ significand[0..@intCast(exponent + 1)], significand[@intCast(exponent + 1)..] },
            );
        } else {
            // 13. Else,
            // a. Set significand to the string-concatenation of the code unit 0x0030 (DIGIT ZERO),
            //    the code unit 0x002E (FULL STOP), -(exponent + 1) occurrences of the code unit
            //    0x0030 (DIGIT ZERO), and the String significand.
            significand = try agent.gc_allocator.print(
                "0.{s:0>[2]}{s}",
                .{ "", significand, @as(usize, @intCast(-(exponent + 1))) },
            );
        }

        // 14. Return the string-concatenation of sign and significand.
        return Value.from(
            try String.fromAscii(agent, try agent.gc_allocator.print(
                "{s}{s}",
                .{ sign, significand },
            )),
        );
    }

    /// 21.1.3.6 Number.prototype.toString ( [ radix ] )
    /// https://tc39.es/ecma262/#sec-number.prototype.tostring
    fn toString(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const radix = arguments.get(0);

        // 1. Let x be ? ThisNumberValue(this value).
        const x = try thisNumberValue(agent, this_value);

        // 2. If radix is undefined, let radixMV be 10.
        // 3. Else, let radixMV be ? SnapToInteger(radix, truncate, 2, 36).
        const radix_mv = if (radix.isUndefined())
            10
        else
            try radix.snapToInteger(agent, .truncate, 2, 36);

        // 4. Return Number::toString(x, radixMV).
        return Value.from(try x.toString(agent, @intFromFloat(radix_mv)));
    }

    /// 21.1.3.7 Number.prototype.valueOf ( )
    /// https://tc39.es/ecma262/#sec-number.prototype.valueof
    fn valueOf(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Return ? ThisNumberValue(this value).
        return Value.from(try thisNumberValue(agent, this_value));
    }
};

/// 21.1.4 Properties of Number Instances
/// https://tc39.es/ecma262/#sec-properties-of-number-instances
pub const Number = MakeObject(.{
    .Fields = struct {
        /// [[NumberData]]
        number_data: types.Number,
    },
    .tag = .number,
    .display_name = "Number",
});
