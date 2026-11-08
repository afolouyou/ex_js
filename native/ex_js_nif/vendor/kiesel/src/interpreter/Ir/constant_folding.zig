const std = @import("std");

const ast = @import("../../language/ast.zig");
const language = @import("../../language.zig");
const types = @import("../../types.zig");

const Number = types.Number;
const Tokenizer = language.Tokenizer;

pub const Constant = union(enum) {
    undefined,
    null,
    boolean: bool,
    number: f64,
    big_int: std.math.big.int.Const,
    string: []const u8,

    pub fn isTruthy(constant: Constant) bool {
        return switch (constant) {
            .undefined, .null => false,
            .boolean => |boolean| boolean,
            .number => |number| number != 0 and !std.math.isNan(number),
            .big_int => |big_int| !big_int.eqlZero(),
            .string => |string| string.len > 0,
        };
    }

    pub fn isNullish(constant: Constant) bool {
        return switch (constant) {
            .undefined, .null => true,
            else => false,
        };
    }

    pub fn toIndex(constant: Constant) ?u32 {
        switch (constant) {
            .number => |n| {
                if (n == @floor(n) and n >= 0 and n <= std.math.maxInt(u32)) {
                    return @intFromFloat(n);
                }
            },
            else => {},
        }
        return null;
    }

    pub fn deinit(constant: Constant, gpa: std.mem.Allocator) void {
        switch (constant) {
            .big_int => |big_int| gpa.free(big_int.limbs),
            .string => |string| gpa.free(string),
            else => {},
        }
    }

    pub fn isStrictlyEqual(lhs: Constant, rhs: Constant) ?bool {
        if (@backingInt(lhs) != @backingInt(rhs)) return false;
        return switch (lhs) {
            .undefined, .null => true,
            .number => |number| {
                if (std.math.isNan(number) or std.math.isNan(rhs.number)) return false;
                return number == rhs.number;
            },
            .big_int => |big_int| big_int.order(rhs.big_int) == .eq,
            .string => |string| {
                // TODO: Support equality constant folding for strings with escape sequences
                if (std.mem.findScalar(u8, string, '\\') != null or
                    std.mem.findScalar(u8, rhs.string, '\\') != null) return null;
                return std.mem.eql(u8, string, rhs.string);
            },
            .boolean => |boolean| boolean == rhs.boolean,
        };
    }

    pub fn isLooselyEqual(lhs: Constant, rhs: Constant) ?bool {
        if (@backingInt(lhs) == @backingInt(rhs)) return lhs.isStrictlyEqual(rhs);
        if (lhs == .null and rhs == .undefined) return true;
        if (lhs == .undefined and rhs == .null) return true;
        // The rest requires type coercion, bail out
        return null;
    }

    pub fn isLessThan(lhs: Constant, rhs: Constant) ?bool {
        if (lhs == .number and rhs == .number) {
            if (std.math.isNan(lhs.number) or std.math.isNan(rhs.number)) return null;
            return lhs.number < rhs.number;
        }
        if (lhs == .big_int and rhs == .big_int) {
            return lhs.big_int.order(rhs.big_int) == .lt;
        }
        // The rest requires type coercion, bail out
        return null;
    }
};

pub fn constantFold(
    gpa: std.mem.Allocator,
    expr: *const ast.Expression,
) std.mem.Allocator.Error!?Constant {
    switch (expr.*) {
        .primary_expression => |prim_expr| switch (prim_expr) {
            .literal => |*literal| return try constantFoldLiteral(gpa, literal),
            else => {},
        },
        .unary_expression => |*unary_expr| return constantFoldUnaryExpression(gpa, unary_expr),
        .binary_expression => |*bin_expr| return constantFoldBinaryExpression(gpa, bin_expr),
        .relational_expression => |*rel_expr| return constantFoldRelationalExpression(gpa, rel_expr),
        .equality_expression => |*eq_expr| return constantFoldEqualityExpression(gpa, eq_expr),
        .logical_expression => |*log_expr| return constantFoldLogicalExpression(gpa, log_expr),
        else => {},
    }
    return null;
}

fn constantFoldLiteral(
    gpa: std.mem.Allocator,
    literal: *const ast.Literal,
) std.mem.Allocator.Error!Constant {
    return switch (literal.*) {
        .null => .null,
        .boolean => |boolean| .{ .boolean = boolean },
        .numeric => |numeric| blk: {
            const value = try numeric.numericValue(gpa);
            if (value.isNumber()) {
                const n = value.asNumber().asFloat();
                break :blk .{ .number = n };
            } else {
                const js_big_int = value.asBigInt();
                defer {
                    @constCast(js_big_int).managed.deinit();
                    gpa.destroy(js_big_int);
                }
                const big_int = js_big_int.managed.toConst();
                break :blk .{ .big_int = .{
                    .limbs = try gpa.dupe(std.math.big.Limb, big_int.limbs),
                    .positive = big_int.positive,
                } };
            }
        },
        .string => |s| blk: {
            const sl: Tokenizer.StringLiteral = .{ .text = s.text };
            var aw: std.Io.Writer.Allocating = .init(gpa);
            errdefer aw.deinit();
            const valid = sl.value(&aw.writer) catch return error.OutOfMemory;
            std.debug.assert(valid);
            break :blk .{ .string = try aw.toOwnedSlice() };
        },
    };
}

fn constantFoldUnaryExpression(
    gpa: std.mem.Allocator,
    unary_expr: *const ast.UnaryExpression,
) std.mem.Allocator.Error!?Constant {
    if (try constantFold(gpa, unary_expr.expression)) |operand| {
        defer operand.deinit(gpa);
        switch (unary_expr.operator) {
            .@"+" => switch (operand) {
                .undefined => return .{ .number = std.math.nan(f64) },
                .null => return .{ .number = 0 },
                .boolean => |boolean| return .{ .number = if (boolean) 1 else 0 },
                .number => |number| return .{ .number = number },
                else => {},
            },
            .@"-" => switch (operand) {
                .undefined => return .{ .number = std.math.nan(f64) },
                .null => return .{ .number = -0.0 },
                .boolean => |boolean| return .{ .number = if (boolean) -1 else -0.0 },
                .number => |number| return .{ .number = -number },
                else => {},
            },
            .@"!" => return .{ .boolean = !operand.isTruthy() },
            .@"~" => switch (operand) {
                .undefined, .null => return .{ .number = -1 },
                .boolean => |boolean| return .{ .number = if (boolean) -2 else -1 },
                .number => |number| return .{ .number = Number.from(number).bitwiseNOT().asFloat() },
                else => {},
            },
            .void => return .undefined,
            .typeof => {
                const @"type" = switch (operand) {
                    .undefined => "undefined",
                    .null => "object",
                    .boolean => "boolean",
                    .number => "number",
                    .big_int => "bigint",
                    .string => "string",
                };
                return .{ .string = try gpa.dupe(u8, @"type") };
            },
            .delete => return .{ .boolean = true },
        }
    }
    return null;
}

/// See: https://tc39.es/ecma262/#sec-applystringornumericbinaryoperator
fn constantFoldBinaryExpression(
    gpa: std.mem.Allocator,
    bin_expr: *const ast.BinaryExpression,
) std.mem.Allocator.Error!?Constant {
    if (try constantFold(gpa, bin_expr.lhs_expression)) |lhs| {
        defer lhs.deinit(gpa);
        if (try constantFold(gpa, bin_expr.rhs_expression)) |rhs| {
            defer rhs.deinit(gpa);
            switch (bin_expr.operator) {
                .@"+" => {
                    if (lhs == .string or rhs == .string) {
                        const lhs_str = switch (lhs) {
                            .undefined => "undefined",
                            .null => "null",
                            .boolean => |boolean| if (boolean) "true" else "false",
                            .number => |number| blk: {
                                var aw: std.Io.Writer.Allocating = .init(gpa);
                                defer aw.deinit();
                                aw.writer.print("{f}", .{Number.from(number).fmt(10)}) catch |err| switch (err) {
                                    error.WriteFailed => return error.OutOfMemory,
                                };
                                break :blk try aw.toOwnedSlice();
                            },
                            .big_int => |big_int| try big_int.toStringAlloc(gpa, 10, .lower),
                            .string => |string| string,
                        };
                        defer switch (lhs) {
                            .number, .big_int => gpa.free(lhs_str),
                            else => {},
                        };
                        const rhs_str = switch (rhs) {
                            .undefined => "undefined",
                            .null => "null",
                            .boolean => |boolean| if (boolean) "true" else "false",
                            .number => |number| blk: {
                                var aw: std.Io.Writer.Allocating = .init(gpa);
                                defer aw.deinit();
                                aw.writer.print("{f}", .{Number.from(number).fmt(10)}) catch |err| switch (err) {
                                    error.WriteFailed => return error.OutOfMemory,
                                };
                                break :blk try aw.toOwnedSlice();
                            },
                            .big_int => |big_int| try big_int.toStringAlloc(gpa, 10, .lower),
                            .string => |string| string,
                        };
                        defer switch (rhs) {
                            .number, .big_int => gpa.free(rhs_str),
                            else => {},
                        };
                        const result = try std.mem.concat(gpa, u8, &.{ lhs_str, rhs_str });
                        return .{ .string = result };
                    } else if (lhs == .number and rhs == .number) {
                        const result = lhs.number + rhs.number;
                        return .{ .number = result };
                    } else if (lhs == .big_int and rhs == .big_int) {
                        const big_int = try constantFoldBinaryBigIntExpression(gpa, .add, lhs.big_int, rhs.big_int);
                        return .{ .big_int = big_int };
                    } else if (lhs == .boolean and rhs == .boolean) {
                        // Y tho
                        const number: f64 = if (lhs.boolean and rhs.boolean)
                            2
                        else if (lhs.boolean or rhs.boolean)
                            1
                        else
                            0;
                        return .{ .number = number };
                    }
                },
                .@"-" => {
                    // At this point, non-numerics and !SameType(lhs, rhs)
                    // cause TypeErrors
                    if (lhs == .number and rhs == .number) {
                        return .{ .number = lhs.number - rhs.number };
                    } else if (lhs == .big_int and rhs == .big_int) {
                        const big_int = try constantFoldBinaryBigIntExpression(gpa, .sub, lhs.big_int, rhs.big_int);
                        return .{ .big_int = big_int };
                    }
                },
                else => {},
            }
        }
    }
    return null;
}

fn constantFoldBinaryBigIntExpression(
    gpa: std.mem.Allocator,
    comptime op: enum { add, sub },
    lhs: std.math.big.int.Const,
    rhs: std.math.big.int.Const,
) std.mem.Allocator.Error!std.math.big.int.Const {
    var result_managed: std.math.big.int.Managed = try .init(gpa);
    errdefer result_managed.deinit();
    try result_managed.ensureCapacity(@max(lhs.limbs.len, rhs.limbs.len) + 1);
    var result = result_managed.toMutable();
    switch (op) {
        .add => result.add(lhs, rhs),
        .sub => result.sub(lhs, rhs),
    }
    return .{
        .limbs = try gpa.realloc(result_managed.limbs, result.len),
        .positive = result.positive,
    };
}

fn constantFoldRelationalExpression(
    gpa: std.mem.Allocator,
    rel_expr: *const ast.RelationalExpression,
) std.mem.Allocator.Error!?Constant {
    const lhs_expr = switch (rel_expr.lhs) {
        .expression => |expr| expr,
        .private_identifier => return null,
    };
    if (try constantFold(gpa, lhs_expr)) |lhs| {
        defer lhs.deinit(gpa);
        if (try constantFold(gpa, rel_expr.rhs_expression)) |rhs| {
            defer rhs.deinit(gpa);
            switch (rel_expr.operator) {
                .@"<" => if (lhs.isLessThan(rhs)) |result| return .{ .boolean = result },
                .@">" => if (rhs.isLessThan(lhs)) |result| return .{ .boolean = result },
                .@"<=" => if (rhs.isLessThan(lhs)) |result| return .{ .boolean = !result },
                .@">=" => if (lhs.isLessThan(rhs)) |result| return .{ .boolean = !result },
                .instanceof, .in => {},
            }
        }
    }
    return null;
}

fn constantFoldEqualityExpression(
    gpa: std.mem.Allocator,
    eq_expr: *const ast.EqualityExpression,
) std.mem.Allocator.Error!?Constant {
    if (try constantFold(gpa, eq_expr.lhs_expression)) |lhs| {
        defer lhs.deinit(gpa);
        if (try constantFold(gpa, eq_expr.rhs_expression)) |rhs| {
            defer rhs.deinit(gpa);
            switch (eq_expr.operator) {
                .@"==" => if (lhs.isLooselyEqual(rhs)) |result| return .{ .boolean = result },
                .@"!=" => if (lhs.isLooselyEqual(rhs)) |result| return .{ .boolean = !result },
                .@"===" => if (lhs.isStrictlyEqual(rhs)) |result| return .{ .boolean = result },
                .@"!==" => if (lhs.isStrictlyEqual(rhs)) |result| return .{ .boolean = !result },
            }
        }
    }
    return null;
}

fn constantFoldLogicalExpression(
    gpa: std.mem.Allocator,
    log_expr: *const ast.LogicalExpression,
) std.mem.Allocator.Error!?Constant {
    if (try constantFold(gpa, log_expr.lhs_expression)) |lhs| {
        switch (log_expr.operator) {
            .@"&&" => if (!lhs.isTruthy()) return lhs,
            .@"||" => if (lhs.isTruthy()) return lhs,
            .@"??" => if (!lhs.isNullish()) return lhs,
        }
        lhs.deinit(gpa);
        if (try constantFold(gpa, log_expr.rhs_expression)) |rhs| {
            return rhs;
        }
    }
    return null;
}
