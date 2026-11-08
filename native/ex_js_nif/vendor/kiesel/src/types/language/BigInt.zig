//! 6.1.6.2 The BigInt Type
//! https://tc39.es/ecma262/#sec-ecmascript-language-types-bigint-type

const std = @import("std");

const execution = @import("../../execution.zig");
const types = @import("../../types.zig");

const Agent = execution.Agent;
const String = types.String;

const BigInt = @This();

managed: std.math.big.int.Managed,

pub const zero = fromLiteral(0);
pub const one = fromLiteral(1);

pub fn format(self: *const BigInt, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.print("{f}n", .{self.managed});
}

pub fn fmt(self: *const BigInt, gpa: std.mem.Allocator, radix: u8) Format {
    std.debug.assert(radix >= 2);
    std.debug.assert(radix <= 36);
    return .{ .big_int = self, .allocator = gpa, .radix = radix };
}

const Format = struct {
    big_int: *const BigInt,
    allocator: std.mem.Allocator,
    radix: u8,

    pub fn format(f: Format, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        f.big_int.toStringImpl(f.allocator, writer, f.radix) catch return error.WriteFailed;
    }
};

pub fn fromLiteral(comptime value: anytype) *const BigInt {
    const managed: std.math.big.int.Managed = comptime blk: {
        var limbs: [std.math.big.int.calcLimbLen(value)]std.math.big.Limb = undefined;
        var managed = std.math.big.int.Mutable.init(&limbs, value).toManaged(undefined);
        const limbs_final = limbs;
        managed.limbs = @constCast(&limbs_final);
        break :blk managed;
    };
    const big_int: *const BigInt = comptime &.{ .managed = managed };
    return big_int;
}

pub fn fromManaged(agent: *Agent, managed: std.math.big.int.Managed) std.mem.Allocator.Error!*const BigInt {
    const big_int = try agent.gc_allocator.create(BigInt);
    big_int.* = .{ .managed = managed };
    return big_int;
}

pub fn fromValue(agent: *Agent, value: anytype) std.mem.Allocator.Error!*const BigInt {
    var managed = try std.math.big.int.Managed.initSet(agent.gc_allocator, value);
    errdefer managed.deinit();
    const big_int = try agent.gc_allocator.create(BigInt);
    big_int.* = .{ .managed = managed };
    return big_int;
}

const FromStringError =
    std.mem.Allocator.Error ||
    error{ InvalidBase, InvalidCharacter };

pub fn fromString(
    agent: *Agent,
    base: u8,
    value: []const u8,
) FromStringError!*const BigInt {
    var managed = try std.math.big.int.Managed.init(agent.gc_allocator);
    errdefer managed.deinit();
    try managed.setString(base, value);
    const big_int = try agent.gc_allocator.create(BigInt);
    big_int.* = .{ .managed = managed };
    return big_int;
}

pub fn asFloat(self: *const BigInt) f64 {
    return self.managed.toFloat(f64, .nearest_even)[0];
}

pub fn orderWithFloat(
    self: *const BigInt,
    gpa: std.mem.Allocator,
    value: f64,
    round: std.math.big.int.Round,
) std.mem.Allocator.Error!std.math.Order {
    std.debug.assert(std.math.isFinite(value));
    var temp = try std.math.big.int.Managed.init(gpa);
    defer temp.deinit();

    const Repr = std.math.FloatRepr(f64);
    const repr: Repr = @bitCast(value);
    const biased_exp = @backingInt(repr.exponent);
    const bias = @backingInt(Repr.BiasedExponent.zero);
    const int_bits = (biased_exp -| (bias - 1));
    const limb_bits = @bitSizeOf(std.math.big.Limb);
    const needed = std.math.divCeil(usize, int_bits, limb_bits) catch unreachable;
    try temp.ensureCapacity(needed);

    var mutable = temp.toMutable();
    _ = mutable.setFloat(value, round);
    return self.managed.toConst().order(mutable.toConst());
}

/// 6.1.6.2.1 BigInt::unaryMinus ( bigint )
/// https://tc39.es/ecma262/#sec-numeric-types-bigint-unaryMinus
pub fn unaryMinus(self: *const BigInt, agent: *Agent) std.mem.Allocator.Error!*const BigInt {
    // 1. If bigint = 0ℤ, return 0ℤ.
    if (self.managed.eqlZero()) return self;

    // 2. Return -bigint.
    var result = try self.managed.clone();
    result.negate();
    return fromManaged(agent, result);
}

/// 6.1.6.2.2 BigInt::bitwiseNOT ( bigint )
/// https://tc39.es/ecma262/#sec-numeric-types-bigint-bitwiseNOT
pub fn bitwiseNOT(self: *const BigInt, agent: *Agent) std.mem.Allocator.Error!*const BigInt {
    // 1. Return -bigint - 1ℤ.
    var result = try self.managed.clone();
    result.negate();
    try result.sub(&result, &one.managed);
    return fromManaged(agent, result);
}

/// 6.1.6.2.3 BigInt::exponentiate ( base, exponent )
/// https://tc39.es/ecma262/#sec-numeric-types-bigint-exponentiate
pub fn exponentiate(base: *const BigInt, agent: *Agent, exponent: *const BigInt) Agent.Error!*const BigInt {
    // 1. If exponent < 0ℤ, throw a RangeError exception.
    if (!exponent.managed.isPositive() and !exponent.managed.eqlZero()) {
        return agent.throwException(.range_error, "Exponent must be positive", .{});
    }

    // 2. If base = 0ℤ and exponent = 0ℤ, return 1ℤ.
    // NOTE: This also applies if the base is not zero.
    if (exponent.managed.eqlZero()) return one;

    // 3. Return base raised to the power exponent.
    var result = try base.managed.clone();
    var exponent_cloned = try exponent.managed.clone();
    defer exponent_cloned.deinit();
    exponent_cloned.abs();
    while (exponent_cloned.order(one.managed) == .gt) {
        try result.mul(&result, &base.managed);
        try exponent_cloned.sub(&exponent_cloned, &one.managed);
    }
    return fromManaged(agent, result);
}

/// 6.1.6.2.4 BigInt::multiply ( x, y )
/// https://tc39.es/ecma262/#sec-numeric-types-bigint-multiply
pub fn multiply(x: *const BigInt, agent: *Agent, y: *const BigInt) std.mem.Allocator.Error!*const BigInt {
    // 1. Return x × y.
    var result = try std.math.big.int.Managed.init(agent.gc_allocator);
    try result.mul(&x.managed, &y.managed);
    return fromManaged(agent, result);
}

/// 6.1.6.2.5 BigInt::divide ( x, y )
/// https://tc39.es/ecma262/#sec-numeric-types-bigint-divide
pub fn divide(x: *const BigInt, agent: *Agent, y: *const BigInt) Agent.Error!*const BigInt {
    // 1. If y = 0ℤ, throw a RangeError exception.
    if (y.managed.eqlZero()) return agent.throwException(.range_error, "Division by zero", .{});

    // 2. Let quotient be ℝ(x) / ℝ(y).
    // 3. Return ℤ(truncate(quotient)).
    var quotient = try std.math.big.int.Managed.init(agent.gc_allocator);
    var r = try std.math.big.int.Managed.init(agent.gc_allocator);
    try quotient.divTrunc(&r, &x.managed, &y.managed);
    return fromManaged(agent, quotient);
}

/// 6.1.6.2.6 BigInt::remainder ( numerator, denominator )
/// https://tc39.es/ecma262/#sec-numeric-types-bigint-remainder
pub fn remainder(
    numerator: *const BigInt,
    agent: *Agent,
    denominator: *const BigInt,
) Agent.Error!*const BigInt {
    // 1. If denominator = 0ℤ, throw a RangeError exception.
    if (denominator.managed.eqlZero()) return agent.throwException(.range_error, "Division by zero", .{});

    // 2. If numerator = 0ℤ, return 0ℤ.
    if (numerator.managed.eqlZero()) return numerator;

    // 3. Let quotient be ℝ(numerator) / ℝ(denominator).
    // 4. Let truncatedQuotient be ℤ(truncate(quotient)).
    // 5. Return numerator - (denominator × truncatedQuotient).
    var quotient = try std.math.big.int.Managed.init(agent.gc_allocator);
    defer quotient.deinit();
    var r = try std.math.big.int.Managed.init(agent.gc_allocator);
    try quotient.divTrunc(&r, &numerator.managed, &denominator.managed);
    return fromManaged(agent, r);
}

/// 6.1.6.2.7 BigInt::add ( x, y )
/// https://tc39.es/ecma262/#sec-numeric-types-bigint-add
pub fn add(x: *const BigInt, agent: *Agent, y: *const BigInt) std.mem.Allocator.Error!*const BigInt {
    // 1. Return x + y.
    var result = try std.math.big.int.Managed.init(agent.gc_allocator);
    try result.add(&x.managed, &y.managed);
    return fromManaged(agent, result);
}

/// 6.1.6.2.8 BigInt::subtract ( x, y )
/// https://tc39.es/ecma262/#sec-numeric-types-bigint-subtract
pub fn subtract(x: *const BigInt, agent: *Agent, y: *const BigInt) std.mem.Allocator.Error!*const BigInt {
    // 1. Return x - y.
    var result = try std.math.big.int.Managed.init(agent.gc_allocator);
    try result.sub(&x.managed, &y.managed);
    return fromManaged(agent, result);
}

/// 6.1.6.2.9 BigInt::leftShift ( x, y )
/// https://tc39.es/ecma262/#sec-numeric-types-bigint-leftShift
pub fn leftShift(x: *const BigInt, agent: *Agent, y: *const BigInt) Agent.Error!*const BigInt {
    // 1. If y < 0ℤ, then
    //     a. Return ℤ(floor(ℝ(x) / 2**(-ℝ(y)))).
    // 2. Return x × 2ℤ**y.
    var result = try std.math.big.int.Managed.init(agent.gc_allocator);
    try result.shiftLeft(
        &x.managed,
        y.managed.toInt(usize) catch return agent.throwException(
            .internal_error,
            "Cannot left-shift BigInt by more than {d} bits",
            .{std.math.maxInt(usize)},
        ),
    );
    return fromManaged(agent, result);
}

/// 6.1.6.2.10 BigInt::signedRightShift ( x, y )
/// https://tc39.es/ecma262/#sec-numeric-types-bigint-signedRightShift
pub fn signedRightShift(x: *const BigInt, agent: *Agent, y: *const BigInt) Agent.Error!*const BigInt {
    // 1. Return BigInt::leftShift(x, -y).
    var result = try std.math.big.int.Managed.init(agent.gc_allocator);
    try result.shiftRight(
        &x.managed,
        y.managed.toInt(usize) catch return agent.throwException(
            .internal_error,
            "Cannot right-shift BigInt by more than {d} bits",
            .{std.math.maxInt(usize)},
        ),
    );
    return fromManaged(agent, result);
}

/// 6.1.6.2.11 BigInt::unsignedRightShift ( x, y )
/// https://tc39.es/ecma262/#sec-numeric-types-bigint-unsignedRightShift
pub fn unsignedRightShift(_: *const BigInt, agent: *Agent, _: *const BigInt) error{ExceptionThrown}!*const BigInt {
    // 1. Throw a TypeError exception.
    return agent.throwException(
        .type_error,
        "Unsigned right-shift is not supported for BigInts",
        .{},
    );
}

/// 6.1.6.2.12 BigInt::lessThan ( x, y )
/// https://tc39.es/ecma262/#sec-numeric-types-bigint-lessThan
pub fn lessThan(x: *const BigInt, y: *const BigInt) bool {
    // 1. If ℝ(x) < ℝ(y), return true.
    // 2. Return false.
    return x.managed.order(y.managed) == .lt;
}

/// 6.1.6.2.13 BigInt::equal ( x, y )
/// https://tc39.es/ecma262/#sec-numeric-types-bigint-equal
pub fn equal(x: *const BigInt, y: *const BigInt) bool {
    // 1. If ℝ(x) = ℝ(y), return true.
    // 2. Return false.
    return x.managed.eql(y.managed);
}

/// 6.1.6.2.18 BigInt::bitwiseAND ( x, y )
/// https://tc39.es/ecma262/#sec-numeric-types-bigint-bitwiseAND
pub fn bitwiseAND(x: *const BigInt, agent: *Agent, y: *const BigInt) std.mem.Allocator.Error!*const BigInt {
    // 1. Return BigIntBitwiseOp(`&`, x, y).
    var result = try std.math.big.int.Managed.init(agent.gc_allocator);
    try result.bitAnd(&x.managed, &y.managed);
    return fromManaged(agent, result);
}

/// 6.1.6.2.19 BigInt::bitwiseXOR ( x, y )
/// https://tc39.es/ecma262/#sec-numeric-types-bigint-bitwiseXOR
pub fn bitwiseXOR(x: *const BigInt, agent: *Agent, y: *const BigInt) std.mem.Allocator.Error!*const BigInt {
    // 1. Return BigIntBitwiseOp(`^`, x, y).
    var result = try std.math.big.int.Managed.init(agent.gc_allocator);
    try result.bitXor(&x.managed, &y.managed);
    return fromManaged(agent, result);
}

/// 6.1.6.2.20 BigInt::bitwiseOR ( x, y )
/// https://tc39.es/ecma262/#sec-numeric-types-bigint-bitwiseOR
pub fn bitwiseOR(x: *const BigInt, agent: *Agent, y: *const BigInt) std.mem.Allocator.Error!*const BigInt {
    // 1. Return BigIntBitwiseOp(`|`, x, y).
    var result = try std.math.big.int.Managed.init(agent.gc_allocator);
    try result.bitOr(&x.managed, &y.managed);
    return fromManaged(agent, result);
}

pub fn toString(
    self: *const BigInt,
    agent: *Agent,
    radix: u8,
) std.mem.Allocator.Error!*const String {
    var aw: std.Io.Writer.Allocating = .init(agent.gc_allocator);
    defer aw.deinit();
    aw.writer.print("{f}", .{self.fmt(agent.gc_allocator, radix)}) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
    };
    return String.fromAscii(agent, try aw.toOwnedSlice());
}

/// 6.1.6.2.21 BigInt::toString ( x, radix )
/// https://tc39.es/ecma262/#sec-numeric-types-bigint-tostring
fn toStringImpl(
    self: *const BigInt,
    gpa: std.mem.Allocator,
    writer: *std.Io.Writer,
    radix: u8,
) (std.mem.Allocator.Error || std.Io.Writer.Error)!void {
    std.debug.assert(radix >= 2);
    std.debug.assert(radix <= 36);
    // 1. If x < 0ℤ, return the string-concatenation of "-" and BigInt::toString(-x, radix).
    // 2. Return the String value consisting of the representation of x using radix radix.
    const string = self.managed.toString(gpa, radix, .lower) catch |err| switch (err) {
        error.InvalidBase => unreachable,
        error.OutOfMemory => |e| return e,
    };
    defer gpa.free(string);
    try writer.writeAll(string);
}

test format {
    const test_cases = [_]struct { *const BigInt, []const u8 }{
        .{ zero, "0n" },
        .{ fromLiteral(123), "123n" },
        .{ fromLiteral(-42), "-42n" },
        .{ fromLiteral(9223372036854775807), "9223372036854775807n" },
    };
    for (test_cases) |test_case| {
        const big_int, const expected = test_case;
        try std.testing.expectFmt(expected, "{f}", .{big_int});
    }
}
