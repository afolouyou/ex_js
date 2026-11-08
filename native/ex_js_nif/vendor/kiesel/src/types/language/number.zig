//! 6.1.6.1 The Number Type
//! https://tc39.es/ecma262/#sec-ecmascript-language-types-number-type

const builtin = @import("builtin");
const std = @import("std");

const execution = @import("../../execution.zig");
const types = @import("../../types.zig");
const utils = @import("../../utils.zig");

const Agent = execution.Agent;
const String = types.String;
const Value = types.Value;

pub const Number = union(enum) {
    f64: f64,
    // OPTIMIZATION: Instead of always storing floats we also have a Number type that stores an
    // i32 internally.
    i32: i32,

    pub fn format(self: Number, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .f64 => |x| {
                if (std.math.isNan(x)) {
                    try writer.writeAll("NaN");
                } else if (std.math.isPositiveInf(x)) {
                    try writer.writeAll("Infinity");
                } else if (std.math.isNegativeInf(x)) {
                    try writer.writeAll("-Infinity");
                } else {
                    try writer.print("{d}", .{x});
                }
            },
            .i32 => |x| try writer.print("{d}", .{x}),
        }
    }

    pub fn fmt(self: Number, radix: u8) Format {
        return .{ .number = self, .radix = radix };
    }

    const Format = struct {
        number: Number,
        radix: u8,

        pub fn format(f: Format, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            try f.number.toStringImpl(writer, f.radix);
        }
    };

    pub inline fn from(number: anytype) Number {
        const T = @TypeOf(number);
        switch (@typeInfo(T)) {
            .int, .comptime_int => {
                if (@typeInfo(T) == .int and @typeInfo(T).int.bits > 53) {
                    @compileError("Number.from() is only safe up to 53 bit integers");
                }
                if (std.math.cast(i32, number)) |x| {
                    return .{ .i32 = x };
                }
                return .{ .f64 = @floatFromInt(number) };
            },
            .float, .comptime_float => {
                if (!std.math.signbit(@as(f64, number)) and
                    number <= @as(f64, @floatFromInt(std.math.maxInt(i32))) and
                    number >= @as(f64, @floatFromInt(std.math.minInt(i32))) and
                    number == @as(f64, @floatFromInt(@as(i32, @intFromFloat(number)))))
                {
                    return .{ .i32 = @intFromFloat(number) };
                }
                return .{ .f64 = @as(f64, number) };
            },
            else => @compileError("Number.from() called with incompatible type " ++ @typeName(T)),
        }
    }

    pub fn asFloat(self: Number) f64 {
        return switch (self) {
            .f64 => |x| x,
            .i32 => |x| @as(f64, @floatFromInt(x)),
        };
    }

    pub fn isNan(self: Number) bool {
        return switch (self) {
            .f64 => |x| std.math.isNan(x),
            .i32 => false,
        };
    }

    pub fn isPositiveInf(self: Number) bool {
        return switch (self) {
            .f64 => |x| std.math.isPositiveInf(x),
            .i32 => false,
        };
    }

    pub fn isNegativeInf(self: Number) bool {
        return switch (self) {
            .f64 => |x| std.math.isNegativeInf(x),
            .i32 => false,
        };
    }

    pub fn isZero(self: Number) bool {
        return switch (self) {
            .f64 => |x| x == 0,
            .i32 => |x| x == 0,
        };
    }

    pub fn isPositiveZero(self: Number) bool {
        return switch (self) {
            .f64 => |x| std.math.isPositiveZero(x),
            .i32 => |x| x == 0,
        };
    }

    pub fn isNegativeZero(self: Number) bool {
        return switch (self) {
            .f64 => |x| std.math.isNegativeZero(x),
            .i32 => false,
        };
    }

    pub fn isFinite(self: Number) bool {
        return switch (self) {
            .f64 => |x| std.math.isFinite(x),
            .i32 => true,
        };
    }

    /// https://tc39.es/ecma262/#integral-number
    pub fn isIntegral(self: Number) bool {
        return switch (self) {
            .f64 => |x| std.math.isFinite(x) and x == @trunc(x),
            .i32 => true,
        };
    }

    pub fn truncate(self: Number) Number {
        return switch (self) {
            .f64 => |x| .{ .f64 = @trunc(x) },
            .i32 => |x| .{ .i32 = x },
        };
    }

    pub fn ceil(self: Number) Number {
        return switch (self) {
            .f64 => |x| .{ .f64 = @ceil(x) },
            .i32 => |x| .{ .i32 = x },
        };
    }

    pub fn floor(self: Number) Number {
        return switch (self) {
            .f64 => |x| .{ .f64 = @floor(x) },
            .i32 => |x| .{ .i32 = x },
        };
    }

    pub fn toInt32(self: Number) i32 {
        switch (self) {
            .f64 => |x| {
                // OPTIMIZATION: ARMv8.3-A has an instruction for this :^)
                if (comptime builtin.target.cpu.arch.isAarch64() and
                    std.Target.aarch64.featureSetHas(builtin.target.cpu.features, .jsconv))
                {
                    return asm volatile (
                        \\fjcvtzs w0, d1
                        : [ret] "={w0}" (-> i32),
                        : [number] "{d1}" (x),
                        : .{});
                }
                if (!std.math.isFinite(x) or x == 0) return 0;
                return Value.toFixedSizeInteger(@trunc(x), i32);
            },
            .i32 => |x| return x,
        }
    }

    pub fn toUint32(self: Number) u32 {
        switch (self) {
            .f64 => |x| {
                if (!std.math.isFinite(x) or x == 0) return 0;
                return Value.toFixedSizeInteger(@trunc(x), u32);
            },
            .i32 => |x| return @bitCast(x),
        }
    }

    pub fn toFloat16(self: Number) f16 {
        return utils.float16.__truncdfhf2(self.asFloat());
    }

    /// 6.1.6.1.1 Number::unaryMinus ( number )
    /// https://tc39.es/ecma262/#sec-numeric-types-number-unaryMinus
    pub fn unaryMinus(number: Number) Number {
        // 1. If number is NaN, return NaN.
        if (number.isNan()) return number;

        // 2. Return the negation of number; that is, compute a Number with the same magnitude but
        //    opposite sign.
        return if (number.isZero())
            .{ .f64 = -number.asFloat() }
        else switch (number) {
            .f64 => |x| .{ .f64 = -x },
            .i32 => |x| if (-%x != x)
                .{ .i32 = -x }
            else
                .{ .f64 = -number.asFloat() },
        };
    }

    /// 6.1.6.1.2 Number::bitwiseNOT ( number )
    /// https://tc39.es/ecma262/#sec-numeric-types-number-bitwiseNOT
    pub fn bitwiseNOT(number: Number) Number {
        // 1. Let oldValue be ! ToInt32(number).
        const old_value = number.toInt32();

        // 2. Return the bitwise complement of oldValue. The mathematical value of the result is
        //    exactly representable as a 32-bit two's complement bit string.
        return .{ .i32 = ~old_value };
    }

    /// 6.1.6.1.3 Number::exponentiate ( base, exponent )
    /// https://tc39.es/ecma262/#sec-numeric-types-number-exponentiate
    pub fn exponentiate(base: Number, exponent: Number) Number {
        // 1. If exponent is NaN, return NaN.
        if (exponent.isNan()) return .{ .f64 = std.math.nan(f64) };

        // 2. If exponent is either +0𝔽 or -0𝔽, return 1𝔽.
        if (exponent.isZero()) return .{ .i32 = 1 };

        // 3. If base is NaN, return NaN.
        if (base.isNan()) return .{ .f64 = std.math.nan(f64) };

        // 4. If base is +∞𝔽, then
        if (base.isPositiveInf()) {
            // a. If exponent > +0𝔽, return +∞𝔽.
            // b. Return +0𝔽.
            return if (exponent.asFloat() > 0)
                .{ .f64 = std.math.inf(f64) }
            else
                .{ .i32 = 0 };
        }

        // 5. If base is -∞𝔽, then
        if (base.isNegativeInf()) {
            // a. If exponent > +0𝔽, then
            if (exponent.asFloat() > 0) {
                // i. If exponent is an odd integral Number, return -∞𝔽.
                // ii. Return +∞𝔽.
                return if (exponent.isIntegral() and @mod(exponent.asFloat(), 2) != 0)
                    .{ .f64 = -std.math.inf(f64) }
                else
                    .{ .f64 = std.math.inf(f64) };
            }

            // b. If exponent is an odd integral Number, return -0𝔽.
            // c. Return +0𝔽.
            return if (exponent.isIntegral() and @mod(exponent.asFloat(), 2) != 0)
                .{ .f64 = -0.0 }
            else
                .{ .i32 = 0 };
        }

        // 6. If base is +0𝔽, then
        if (base.isPositiveZero()) {
            // a. If exponent > +0𝔽, return +0𝔽.
            // b. Return +∞𝔽.
            return if (exponent.asFloat() > 0)
                .{ .i32 = 0 }
            else
                .{ .f64 = std.math.inf(f64) };
        }

        // 7. If base is -0𝔽, then
        if (base.isNegativeZero()) {
            // a. If exponent > +0𝔽, then
            if (exponent.asFloat() > 0) {
                // i. If exponent is an odd integral Number, return -0𝔽.
                // ii. Return +0𝔽.
                return if (exponent.isIntegral() and @mod(exponent.asFloat(), 2) != 0)
                    .{ .f64 = -0.0 }
                else
                    .{ .i32 = 0 };
            }

            // b. If exponent is an odd integral Number, return -∞𝔽.
            // c. Return +∞𝔽.
            return if (exponent.isIntegral() and @mod(exponent.asFloat(), 2) != 0)
                .{ .f64 = -std.math.inf(f64) }
            else
                .{ .f64 = std.math.inf(f64) };
        }

        // 8. Assert: base is finite and is neither +0𝔽 nor -0𝔽.
        std.debug.assert(base.isFinite() and !base.isZero());

        // 9. If exponent is +∞𝔽, then
        if (exponent.isPositiveInf()) {
            // a. If abs(ℝ(base)) > 1, return +∞𝔽.
            // b. If abs(ℝ(base)) = 1, return NaN.
            // c. Return +0𝔽.
            return if (@abs(base.asFloat()) > 1)
                .{ .f64 = std.math.inf(f64) }
            else if (@abs(base.asFloat()) == 1)
                .{ .f64 = std.math.nan(f64) }
            else
                .{ .i32 = 0 };
        }

        // 10. If exponent is -∞𝔽, then
        if (exponent.isNegativeInf()) {
            // a. If abs(ℝ(base)) > 1, return +0𝔽.
            // b. If abs(ℝ(base)) = 1, return NaN.
            // c. Return +∞𝔽.
            return if (@abs(base.asFloat()) > 1)
                .{ .i32 = 0 }
            else if (@abs(base.asFloat()) == 1)
                .{ .f64 = std.math.nan(f64) }
            else
                .{ .f64 = std.math.inf(f64) };
        }

        // 11. Assert: exponent is finite and is neither +0𝔽 nor -0𝔽.
        std.debug.assert(exponent.isFinite() and !exponent.isZero());

        // 12. If base < -0𝔽 and exponent is not an integral Number, return NaN.
        if (base.asFloat() < 0 and !exponent.isIntegral())
            return .{ .f64 = std.math.nan(f64) };

        // 13. Return an implementation-approximated Number value representing the result of raising
        //     ℝ(base) to the ℝ(exponent) power.
        return from(std.math.pow(f64, base.asFloat(), exponent.asFloat()));
    }

    /// 6.1.6.1.4 Number::multiply ( x, y )
    /// https://tc39.es/ecma262/#sec-numeric-types-number-multiply
    pub fn multiply(x: Number, y: Number) Number {
        // 1-6.
        if (x == .i32 and y == .i32) {
            if (std.math.mul(i32, x.i32, y.i32) catch null) |result| return .{ .i32 = result };
        }
        return from(x.asFloat() * y.asFloat());
    }

    /// 6.1.6.1.5 Number::divide ( x, y )
    /// https://tc39.es/ecma262/#sec-numeric-types-number-divide
    pub fn divide(x: Number, y: Number) Number {
        // 1-8.
        return from(x.asFloat() / y.asFloat());
    }

    /// 6.1.6.1.6 Number::remainder ( numerator, denominator )
    /// https://tc39.es/ecma262/#sec-numeric-types-number-remainder
    pub fn remainder(numerator: Number, denominator: Number) Number {
        // 1. If numerator is NaN or denominator is NaN, return NaN.
        if (numerator.isNan() or denominator.isNan()) return .{ .f64 = std.math.nan(f64) };

        // 2. If numerator is either +∞𝔽 or -∞𝔽, return NaN.
        if (numerator.isPositiveInf() or numerator.isNegativeInf()) return .{ .f64 = std.math.nan(f64) };

        // 3. If denominator is either +∞𝔽 or -∞𝔽, return numerator.
        if (denominator.isPositiveInf() or denominator.isNegativeInf()) return numerator;

        // 4. If denominator is either +0𝔽 or -0𝔽, return NaN.
        if (denominator.isZero()) return .{ .f64 = std.math.nan(f64) };

        // 5. If numerator is either +0𝔽 or -0𝔽, return numerator.
        if (numerator.isZero()) return numerator;

        // 6. Assert: numerator and denominator are finite and non-zero.
        std.debug.assert(numerator.isFinite() and numerator.asFloat() != 0);
        std.debug.assert(denominator.isFinite() and denominator.asFloat() != 0);

        // 7. Let quotient be ℝ(numerator) / ℝ(denominator).
        // 8. Let truncatedQuotient be truncate(quotient).
        // 9. Let remainder be ℝ(numerator) - (ℝ(denominator) × truncatedQuotient).
        // 10. If remainder = 0 and numerator < -0𝔽, return -0𝔽.
        // 11. Return 𝔽(remainder).
        return from(@rem(numerator.asFloat(), denominator.asFloat()));
    }

    /// 6.1.6.1.7 Number::add ( x, y )
    /// https://tc39.es/ecma262/#sec-numeric-types-number-add
    pub fn add(x: Number, y: Number) Number {
        // 1-8.
        if (x == .i32 and y == .i32) {
            if (std.math.add(i32, x.i32, y.i32) catch null) |result| return .{ .i32 = result };
        }
        return from(x.asFloat() + y.asFloat());
    }

    /// 6.1.6.1.8 Number::subtract ( x, y )
    /// https://tc39.es/ecma262/#sec-numeric-types-number-subtract
    pub fn subtract(x: Number, y: Number) Number {
        // 1. Return Number::add(x, Number::unaryMinus(y)).
        if (x == .i32 and y == .i32) {
            if (std.math.sub(i32, x.i32, y.i32) catch null) |result| return .{ .i32 = result };
        }
        return from(x.asFloat() - y.asFloat());
    }

    /// 6.1.6.1.9 Number::leftShift ( x, y )
    /// https://tc39.es/ecma262/#sec-numeric-types-number-leftShift
    pub fn leftShift(x: Number, y: Number) Number {
        // 1. Let leftNumber be ! ToInt32(x).
        const left_number = x.toInt32();

        // 2. Let rightNumber be ! ToUint32(y).
        const right_number = y.toUint32();

        // 3. Let shiftCount be ℝ(rightNumber) modulo 32.
        const shift_count: u5 = @intCast(@mod(right_number, 32));

        // 4. Return the result of left shifting leftNumber by shiftCount bits. The mathematical
        //    value of the result is exactly representable as a 32-bit two's complement bit string.
        return .{ .i32 = left_number << shift_count };
    }

    /// 6.1.6.1.10 Number::signedRightShift ( x, y )
    /// https://tc39.es/ecma262/#sec-numeric-types-number-signedRightShift
    pub fn signedRightShift(x: Number, y: Number) Number {
        // 1. Let leftNumber be ! ToInt32(x).
        const left_number = x.toInt32();

        // 2. Let rightNumber be ! ToUint32(y).
        const right_number = y.toUint32();

        // 3. Let shiftCount be ℝ(rightNumber) modulo 32.
        const shift_count: u5 = @intCast(@mod(right_number, 32));

        // 4. Return the result of performing a sign-extending right shift of leftNumber by
        //    shiftCount bits. The most significant bit is propagated. The mathematical value of the
        //    result is exactly representable as a 32-bit two's complement bit string.
        return .{ .i32 = left_number >> shift_count };
    }

    /// 6.1.6.1.11 Number::unsignedRightShift ( x, y )
    /// https://tc39.es/ecma262/#sec-numeric-types-number-unsignedRightShift
    pub fn unsignedRightShift(x: Number, y: Number) Number {
        // 1. Let leftNumber be ! ToUint32(x).
        const left_number = x.toUint32();

        // 2. Let rightNumber be ! ToUint32(y).
        const right_number = y.toUint32();

        // 3. Let shiftCount be ℝ(rightNumber) modulo 32.
        const shift_count: u5 = @intCast(@mod(right_number, 32));

        // 4. Return the result of performing a zero-filling right shift of leftNumber by shiftCount
        //    bits. Vacated bits are filled with zero. The mathematical value of the result is
        //    exactly representable as a 32-bit unsigned bit string.
        return from(left_number >> shift_count);
    }

    /// 6.1.6.1.12 Number::lessThan ( x, y )
    /// https://tc39.es/ecma262/#sec-numeric-types-number-lessThan
    pub fn lessThan(x: Number, y: Number) ?bool {
        // 1. If x is NaN, return undefined.
        if (x.isNan()) return null;

        // 2. If y is NaN, return undefined.
        if (y.isNan()) return null;

        // 3. If x is y, return false.
        if (x.sameValue(y)) return false;

        // 4. If x is +0𝔽 and y is -0𝔽, return false.
        if (x.isPositiveZero() and y.isNegativeZero()) return false;

        // 5. If x is -0𝔽 and y is +0𝔽, return false.
        if (x.isNegativeZero() and y.isPositiveZero()) return false;

        // 6. If x is +∞𝔽, return false.
        if (x.isPositiveInf()) return false;

        // 7. If y is +∞𝔽, return true.
        if (y.isPositiveInf()) return true;

        // 8. If y is -∞𝔽, return false.
        if (y.isNegativeInf()) return false;

        // 9. If x is -∞𝔽, return true.
        if (x.isNegativeInf()) return true;

        // 10. Assert: x and y are finite.
        std.debug.assert(std.math.isFinite(x.asFloat()) and std.math.isFinite(y.asFloat()));

        // 11. If ℝ(x) < ℝ(y), return true.
        // 12. Return false.
        return x.asFloat() < y.asFloat();
    }

    /// 6.1.6.1.13 Number::equal ( x, y )
    /// https://tc39.es/ecma262/#sec-numeric-types-number-equal
    pub fn equal(x: Number, y: Number) bool {
        // 1. If x is NaN, return false.
        if (x.isNan()) return false;

        // 2. If y is NaN, return false.
        if (y.isNan()) return false;

        // 3. If x is y, return true.
        // 4. If x is +0𝔽 and y is -0𝔽, return true.
        // 5. If x is -0𝔽 and y is +0𝔽, return true.
        // 6. Return false.
        return x.asFloat() == y.asFloat();
    }

    /// 6.1.6.1.14 Number::sameValue ( x, y )
    /// https://tc39.es/ecma262/#sec-numeric-types-number-sameValue
    pub fn sameValue(x: Number, y: Number) bool {
        // 1. If x is NaN and y is NaN, return true.
        if (x.isNan() and y.isNan()) return true;

        // 2. If x is +0𝔽 and y is -0𝔽, return false.
        if (x.isPositiveZero() and y.isNegativeZero()) return false;

        // 3. If x is -0𝔽 and y is +0𝔽, return false.
        if (x.isNegativeZero() and y.isPositiveZero()) return false;

        // 4. If x is y, return true.
        // 5. Return false.
        return x.asFloat() == y.asFloat();
    }

    /// 6.1.6.1.15 Number::sameValueZero ( x, y )
    /// https://tc39.es/ecma262/#sec-numeric-types-number-sameValueZero
    pub fn sameValueZero(x: Number, y: Number) bool {
        // 1. If x is NaN and y is NaN, return true.
        if (x.isNan() and y.isNan()) return true;

        // 2. If x is +0𝔽 and y is -0𝔽, return true.
        // 3. If x is -0𝔽 and y is +0𝔽, return true.
        // 4. If x is y, return true.
        // 5. Return false.
        return x.asFloat() == y.asFloat();
    }

    /// 6.1.6.1.16 NumberBitwiseOp ( op, x, y )
    /// https://tc39.es/ecma262/#sec-numberbitwiseop
    fn numberBitwiseOp(comptime op: enum { @"&", @"^", @"|" }, x: Number, y: Number) i32 {
        // 1. Let leftNumber be ! ToInt32(x).
        const left_number = x.toInt32();

        // 2. Let rightNumber be ! ToInt32(y).
        const right_number = y.toInt32();

        // 3. Let leftBits be the 32-bit two's complement bit string representing ℝ(leftNumber).
        // 4. Let rightBits be the 32-bit two's complement bit string representing ℝ(rightNumber).

        const result = switch (op) {
            // 5. If op is `&`, then
            // a. Let result be the result of applying the bitwise AND operation to leftBits and
            //    rightBits.
            .@"&" => left_number & right_number,

            // 6. Else if op is `^`, then
            // a. Let result be the result of applying the bitwise exclusive OR (XOR) operation to
            //    leftBits and rightBits.
            .@"^" => left_number ^ right_number,

            // 7. Else,
            // a. Assert: op is `|`.
            // b. Let result be the result of applying the bitwise inclusive OR operation to
            //    leftBits and rightBits.
            .@"|" => left_number | right_number,
        };

        // 8. Return the Number value for the integer represented by the 32-bit two's complement bit
        //    string result.
        return result;
    }

    /// 6.1.6.1.17 Number::bitwiseAND ( x, y )
    /// https://tc39.es/ecma262/#sec-numeric-types-number-bitwiseAND
    pub fn bitwiseAND(x: Number, y: Number) Number {
        // 1. Return NumberBitwiseOp(`&`, x, y).
        return .{ .i32 = numberBitwiseOp(.@"&", x, y) };
    }

    /// 6.1.6.1.18 Number::bitwiseXOR ( x, y )
    /// https://tc39.es/ecma262/#sec-numeric-types-number-bitwiseXOR
    pub fn bitwiseXOR(x: Number, y: Number) Number {
        // 1. Return NumberBitwiseOp(`^`, x, y).
        return .{ .i32 = numberBitwiseOp(.@"^", x, y) };
    }

    /// 6.1.6.1.19 Number::bitwiseOR ( x, y )
    /// https://tc39.es/ecma262/#sec-numeric-types-number-bitwiseOR
    pub fn bitwiseOR(x: Number, y: Number) Number {
        // 1. Return NumberBitwiseOp(`|`, x, y).
        return .{ .i32 = numberBitwiseOp(.@"|", x, y) };
    }

    pub fn toString(
        self: Number,
        agent: *Agent,
        radix: u8,
    ) std.mem.Allocator.Error!*const String {
        // Handle special cases so they can return static strings
        if (self.isNan()) return String.fromLiteral("NaN");
        if (self.isPositiveInf()) return String.fromLiteral("Infinity");
        if (self.isNegativeInf()) return String.fromLiteral("-Infinity");

        var aw: std.Io.Writer.Allocating = .init(agent.gc_allocator);
        defer aw.deinit();
        aw.writer.print("{f}", .{self.fmt(radix)}) catch |err| switch (err) {
            error.WriteFailed => return error.OutOfMemory,
        };
        return String.fromAscii(agent, try aw.toOwnedSlice());
    }

    /// 6.1.6.1.20 Number::toString ( x, radix )
    /// https://tc39.es/ecma262/#sec-numeric-types-number-tostring
    fn toStringImpl(self: Number, writer: *std.Io.Writer, radix: u8) std.Io.Writer.Error!void {
        std.debug.assert(radix >= 2);
        std.debug.assert(radix <= 36);

        // 1. If x is NaN, return "NaN".
        if (self.isNan()) {
            try writer.writeAll("NaN");
            return;
        }

        // 2. If x is either +0𝔽 or -0𝔽, return "0".
        if (self.isPositiveZero() or self.isNegativeZero()) {
            try writer.writeByte('0');
            return;
        }

        // 3. If x < -0𝔽, return the string-concatenation of "-" and Number::toString(-x, radix).
        if (self.asFloat() < 0) {
            try writer.writeByte('-');
            try self.unaryMinus().toStringImpl(writer, radix);
            return;
        }

        // 4. If x is +∞𝔽, return "Infinity".
        if (self.isPositiveInf()) {
            try writer.writeAll("Infinity");
            return;
        }

        // TODO: Implement steps 5-12 according to spec!
        switch (self) {
            .f64 => |x| if (@abs(x) >= 1e-6 and @abs(x) < 1e21)
                try writer.print("{d}", .{x})
            else if (@abs(x) < 1)
                try writer.print("{e}", .{x})
            else {
                var buffer: [32]u8 = undefined;
                const scientific = std.mem.print(&buffer, "{e}", .{x}) catch |err| switch (err) {
                    error.NoSpaceLeft => unreachable,
                };
                const exponent_index = std.mem.findScalar(u8, scientific, 'e').?;
                try writer.writeAll(scientific[0 .. exponent_index + 1]);
                const exponent = scientific[exponent_index + 1 ..];
                if (exponent[0] != '-') {
                    try writer.writeByte('+');
                }
                try writer.writeAll(exponent);
            },
            .i32 => |x| try writer.printInt(x, radix, .lower, .{}),
        }
    }
};

test "format" {
    const test_cases = [_]struct { Number, []const u8 }{
        .{ Number.from(0), "0" },
        .{ Number.from(-0.0), "-0" },
        .{ Number.from(123), "123" },
        .{ Number.from(123.456), "123.456" },
        .{ Number.from(-42), "-42" },
        .{ Number.from(std.math.nan(f64)), "NaN" },
        .{ Number.from(std.math.inf(f64)), "Infinity" },
        .{ Number.from(-std.math.inf(f64)), "-Infinity" },
    };
    for (test_cases) |test_case| {
        const number, const expected = test_case;
        try std.testing.expectFmt(expected, "{f}", .{number});
    }
}
