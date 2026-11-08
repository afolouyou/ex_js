const std = @import("std");

const execution = @import("../../../execution.zig");
const types = @import("../../../types.zig");
const utils = @import("../../../utils.zig");

const Agent = execution.Agent;
const String = types.String;
const Symbol = types.Symbol;
const Value = types.Value;
const isZigString = utils.isZigString;
const noexcept = utils.noexcept;

/// A property key is either a String or a Symbol. All Strings and Symbols, including the empty
/// String, are valid as property keys.
pub const PropertyKey = union(enum) {
    /// An integer index is a property name n such that CanonicalNumericIndexString(n) returns an
    /// integral Number in the inclusive interval from +0𝔽 to 𝔽(2^53 - 1).
    /// https://tc39.es/ecma262/#integer-index
    pub const IntegerIndex = u53;

    pub const CanonicalNumericIndex = union(enum) {
        /// An integer index.
        integer_index: IntegerIndex,

        /// A canonical numeric string, i.e. passing a `ToNumber`/`ToString` roundtrip.
        ///
        /// This is used for detection only so the value is omitted.
        numeric_string,
    };

    string: *const String,
    symbol: *const Symbol,

    // OPTIMIZATION: If the string is known to be an integer index, store it as a number.
    integer_index: IntegerIndex,

    pub inline fn from(value: anytype) PropertyKey {
        const T = @TypeOf(value);
        if (isZigString(T)) {
            if (comptime !std.meta.isError(utils.parseDigits(IntegerIndex, value, 10))) {
                @compileError("Creating a numeric PropertyKey from a string literal is not supported, use comptime_int instead.");
            }
            return .{ .string = String.fromLiteral(value) };
        } else if (@typeInfo(T) == .pointer) {
            switch (@typeInfo(T).pointer.child) {
                String => {
                    // FIXME: This should use CanonicalNumericIndexString to reject numeric strings that
                    //        are not canonical.
                    if (!value.isAscii()) return .{ .string = value };
                    if (utils.parseDigits(IntegerIndex, value.asAscii(), 10)) |integer_index| {
                        return .{ .integer_index = integer_index };
                    } else |_| {
                        return .{ .string = value };
                    }
                },
                Symbol => return .{ .symbol = value },
                else => {},
            }
        } else if (T == IntegerIndex or @typeInfo(T) == .comptime_int) {
            return .{ .integer_index = @as(IntegerIndex, value) };
        }
        @compileError("PropertyKey.from() called with incompatible type " ++ @typeName(T));
    }

    /// An array index is an integer index n such that CanonicalNumericIndexString(n) returns an
    /// integral Number in the inclusive interval from +0𝔽 to 𝔽(2^32 - 2).
    pub fn isArrayIndex(self: PropertyKey) bool {
        return self == .integer_index and self.integer_index <= (std.math.maxInt(u32) - 1);
    }

    // This is so common that it's useful to have a dedicated method for it.
    pub fn isLength(self: PropertyKey) bool {
        return self == .string and self.string.eql(String.fromLiteral("length"));
    }

    /// 7.1.23 CanonicalNumericIndexString ( arg )
    /// https://tc39.es/ecma262/#sec-canonicalnumericindexstring
    pub fn canonicalNumericIndex(
        self: PropertyKey,
        agent: *Agent,
    ) std.mem.Allocator.Error!?CanonicalNumericIndex {
        switch (self) {
            // Also handles symbols for simplicity, this makes it possible to use a single if
            // branch with null unwrapping at the call site.
            .symbol => return null,
            .integer_index => |integer_index| return .{ .integer_index = integer_index },
            .string => |string| {
                // 1. If arg is "-0", return -0𝔽.
                // 2. Let n be ! ToNumber(arg).
                // 3. If ! ToString(n) is arg, return n.
                // 4. Return undefined.
                const ascii = switch (string.asAsciiOrUtf16()) {
                    .ascii => |ascii| ascii,
                    .utf16 => return null,
                };
                // Do some manual validation to avoid allocations where possible
                if (ascii.len == 0) return null;
                if (std.mem.eql(u8, ascii, "-0") or
                    std.mem.eql(u8, ascii, "NaN") or
                    std.mem.eql(u8, ascii, "Infinity") or
                    std.mem.eql(u8, ascii, "-Infinity")) return .numeric_string;
                if (!std.ascii.isDigit(ascii[0]) and ascii[0] != '-') return null;
                const n = Value.from(string).toNumber(agent) catch |err| try noexcept(err);
                if (string.eql(try n.toString(agent, 10))) return .numeric_string;
                return null;
            },
        }
    }

    pub fn hash(self: PropertyKey) u64 {
        return switch (self) {
            .string => |string| string.hash,
            .symbol => |symbol| std.hash_map.getAutoHashFn(*const Symbol, void)({}, symbol),
            .integer_index => |integer_index| std.hash_map.getAutoHashFn(PropertyKey.IntegerIndex, void)({}, integer_index),
        };
    }

    pub fn eql(a: PropertyKey, b: PropertyKey) bool {
        return switch (a) {
            .string => |a_string| switch (b) {
                .string => |b_string| a_string.eql(b_string),
                .symbol => false,
                .integer_index => |b_integer_index| eqlStringAndIntegerIndex(a_string, b_integer_index),
            },
            .symbol => |a_symbol| switch (b) {
                .string => false,
                .symbol => |b_symbol| a_symbol == b_symbol,
                .integer_index => false,
            },
            .integer_index => |a_integer_index| switch (b) {
                .string => |b_string| eqlStringAndIntegerIndex(b_string, a_integer_index),
                .symbol => false,
                .integer_index => |b_integer_index| a_integer_index == b_integer_index,
            },
        };
    }

    fn eqlStringAndIntegerIndex(string: *const String, index: IntegerIndex) bool {
        const len = comptime std.fmt.count("{d}", .{std.math.maxInt(IntegerIndex)});
        var buf: [len]u8 = undefined;
        const ascii = std.mem.print(&buf, "{d}", .{index}) catch unreachable;
        const index_string: *const String = &.{
            .data = .{ .owned_ascii = ascii.ptr },
            .length = @intCast(ascii.len),
            .hash = std.hash.Wyhash.hash(0, ascii),
        };
        return string.eql(index_string);
    }

    /// Non-standard helper to convert a `PropertyKey` to a `Value` - they *are* plain (string or
    /// symbol) values in the spec.
    pub fn toValue(self: PropertyKey, agent: *Agent) std.mem.Allocator.Error!Value {
        return switch (self) {
            .string => |string| Value.from(string),
            .symbol => |symbol| Value.from(symbol),
            .integer_index => |integer_index| Value.from(try String.fromAscii(agent, try agent.gc_allocator.print(
                "{d}",
                .{integer_index},
            ))),
        };
    }

    /// Non-standard helper to convert a `PropertyKey` to a `[]const u8` or `Symbol` (i.e. bypassing
    /// the integer index optimization).
    pub fn toStringOrSymbol(self: PropertyKey, agent: *Agent) std.mem.Allocator.Error!union(enum) {
        string: *const String,
        symbol: *const Symbol,
    } {
        return switch (self) {
            .string => |string| .{ .string = string },
            .symbol => |symbol| .{ .symbol = symbol },
            .integer_index => |integer_index| .{
                .string = try String.fromAscii(agent, try agent.gc_allocator.print(
                    "{d}",
                    .{integer_index},
                )),
            },
        };
    }

    pub fn HashMap(comptime V: type) type {
        return std.HashMapUnmanaged(PropertyKey, V, struct {
            pub fn hash(_: anytype, property_key: PropertyKey) u64 {
                return property_key.hash();
            }

            pub fn eql(_: anytype, a: PropertyKey, b: PropertyKey) bool {
                return a.eql(b);
            }
        }, std.hash_map.default_max_load_percentage);
    }

    pub fn ArrayHashMap(comptime V: type) type {
        return std.array_hash_map.Custom(PropertyKey, V, struct {
            pub fn hash(_: @This(), property_key: PropertyKey) u32 {
                return @truncate(property_key.hash());
            }

            pub fn eql(_: @This(), a: PropertyKey, b: PropertyKey, _: usize) bool {
                return a.eql(b);
            }
        }, false);
    }
};
