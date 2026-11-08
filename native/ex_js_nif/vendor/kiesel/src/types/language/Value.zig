//! 6.1 ECMAScript Language Types
//! https://tc39.es/ecma262/#sec-ecmascript-language-types

const builtin = @import("builtin");
const std = @import("std");

const build_options = @import("build-options");
const builtins = @import("../../builtins.zig");
const execution = @import("../../execution.zig");
const pretty_printing = @import("../../pretty_printing.zig");
const types = @import("../../types.zig");
const utils = @import("../../utils.zig");

const Agent = execution.Agent;
const Arguments = types.Arguments;
const BigInt = types.BigInt;
const Number = types.Number;
const Object = types.Object;
const PrivateName = types.PrivateName;
const PropertyDescriptor = types.PropertyDescriptor;
const PropertyKey = types.PropertyKey;
const String = types.String;
const Symbol = types.Symbol;
const arrayCreate = builtins.arrayCreate;
const getIterator = types.getIterator;
const isZigString = utils.isZigString;
const keyForSymbol = builtins.keyForSymbol;
const noexcept = utils.noexcept;
const ordinaryObjectCreate = builtins.ordinaryObjectCreate;
const prettyPrintValue = pretty_printing.prettyPrintValue;
const stringCreate = builtins.stringCreate;
const validateNonRevokedProxy = builtins.validateNonRevokedProxy;

pub const Weak = @import("Value/weak.zig").Weak;

const Value = @This();

pub const PreferredType = enum { string, number };

pub const Numeric = union(enum) {
    number: Number,
    big_int: *const BigInt,

    pub fn sameType(x: Numeric, y: Numeric) bool {
        return std.meta.activeTag(x) == std.meta.activeTag(y);
    }
};

pub const Type = enum {
    /// 6.1.1 The Undefined Type
    /// https://tc39.es/ecma262/#sec-ecmascript-language-types-undefined-type
    undefined,

    /// 6.1.2 The Null Type
    /// https://tc39.es/ecma262/#sec-ecmascript-language-types-null-type
    null,

    /// 6.1.3 The Boolean Type
    /// https://tc39.es/ecma262/#sec-ecmascript-language-types-boolean-type
    boolean,

    /// 6.1.4 The String Type
    /// https://tc39.es/ecma262/#sec-ecmascript-language-types-string-type
    string,

    /// 6.1.5 The Symbol Type
    /// https://tc39.es/ecma262/#sec-ecmascript-language-types-symbol-type
    symbol,

    /// 6.1.6.1 The Number Type
    /// https://tc39.es/ecma262/#sec-ecmascript-language-types-number-type
    number,

    /// 6.1.6.2 The BigInt Type
    /// https://tc39.es/ecma262/#sec-ecmascript-language-types-bigint-type
    big_int,

    /// 6.1.7 The Object Type
    /// https://tc39.es/ecma262/#sec-object-type
    object,
};

const TaggedUnionImpl = union(enum) {
    uninitialized,
    undefined,
    null,
    boolean: bool,
    string: *const String,
    symbol: *const Symbol,
    number_i32: i32,
    number_f64: f64,
    big_int: *const BigInt,
    object: *Object,

    pub inline fn from(value: anytype) TaggedUnionImpl {
        const T = @TypeOf(value);
        const is_number = switch (@typeInfo(T)) {
            .int, .comptime_int, .float, .comptime_float => true,
            else => false,
        };
        if (T == bool) {
            return .{ .boolean = value };
        } else if (isZigString(T)) {
            const string = String.fromLiteral(value);
            return .{ .string = string };
        } else if (is_number or T == Number) {
            const number = if (T == Number) value else Number.from(value);
            return switch (number) {
                .i32 => |x| .{ .number_i32 = x },
                .f64 => |x| .{ .number_f64 = x },
            };
        } else if (@typeInfo(T) == .pointer) {
            switch (@typeInfo(T).pointer.child) {
                BigInt => return .{ .big_int = value },
                Object => return .{ .object = value },
                String => return .{ .string = value },
                Symbol => return .{ .symbol = value },
                else => {},
            }
        }
        @compileError("from() called with incompatible type " ++ @typeName(T));
    }

    pub fn @"type"(self: TaggedUnionImpl) Type {
        return switch (self) {
            .uninitialized => unreachable,
            .undefined => .undefined,
            .null => .null,
            .boolean => .boolean,
            .string => .string,
            .symbol => .symbol,
            .number_i32, .number_f64 => .number,
            .big_int => .big_int,
            .object => .object,
        };
    }

    pub fn isBoolean(self: TaggedUnionImpl) bool {
        return self == .boolean;
    }

    pub fn asBoolean(self: TaggedUnionImpl) bool {
        return self.boolean;
    }

    pub fn isString(self: TaggedUnionImpl) bool {
        return self == .string;
    }

    pub fn asString(self: TaggedUnionImpl) *const String {
        return self.string;
    }

    pub fn isSymbol(self: TaggedUnionImpl) bool {
        return self == .symbol;
    }

    pub fn asSymbol(self: TaggedUnionImpl) *const Symbol {
        return self.symbol;
    }

    pub fn isNumber(self: TaggedUnionImpl) bool {
        return switch (self) {
            .number_i32, .number_f64 => true,
            else => false,
        };
    }

    pub fn asNumber(self: TaggedUnionImpl) Number {
        return switch (self) {
            .number_i32 => |number_i32| .{ .i32 = number_i32 },
            .number_f64 => |number_f64| .{ .f64 = number_f64 },
            else => unreachable,
        };
    }

    pub fn isBigInt(self: TaggedUnionImpl) bool {
        return self == .big_int;
    }

    pub fn asBigInt(self: TaggedUnionImpl) *const BigInt {
        return self.big_int;
    }

    pub fn isObject(self: TaggedUnionImpl) bool {
        return self == .object;
    }

    pub fn asObject(self: TaggedUnionImpl) *Object {
        return self.object;
    }
};

/// NaN boxing is a technique of hiding extra variants and payloads within an
/// f64. For reference, this is the layout of a f64:
///
/// - Sign (1 bit)
/// - Exponent (11 bits)
/// - Fraction (52 bits)
///
/// A NaN value must have all the exponent bits set to 1 and at least one
/// fraction bit set to 1.
const NanBoxingImpl = enum(u64) {
    /// NaN with the quiet bit (highest fraction bit) set.
    const nan_mask: u64 = 0x7ff8000000000000;
    const payload_len = 48;

    uninitialized = initBits(.uninitialized, {}),
    undefined = initBits(.undefined, {}),
    null = initBits(.null, {}),
    boolean_false = initBits(.boolean, false),
    boolean_true = initBits(.boolean, true),
    number_nan = nan_mask,
    _,

    /// We always have the highest bit in the 52 bits of the fraction field
    /// (the quiet bit) set. Then, we use the 3 bits below the quiet bit as
    /// a tag for non-f64 values (except f64-NaN itself).
    ///
    /// For pointer values the sign bit is set.
    const Tag = enum(u16) {
        number_f64 = 0x0000,
        number_i32 = 0x0001,
        uninitialized = 0x0002,
        undefined = 0x0003,
        null = 0x0004,
        boolean = 0x0005,
        object = 0x8001,
        string = 0x8002,
        symbol = 0x8003,
        big_int = 0x8004,

        fn Payload(comptime tag: Tag) type {
            return switch (tag) {
                .number_f64 => f64,
                .number_i32 => i32,
                .uninitialized,
                .undefined,
                .null,
                => void,
                .boolean => bool,
                .object => *Object,
                .string => *const String,
                .symbol => *const Symbol,
                .big_int => *const BigInt,
            };
        }
    };

    fn initBits(comptime tag: Tag, payload: tag.Payload()) u64 {
        const T = @TypeOf(payload);
        const tag_bits: u64 = @as(u64, @backingInt(tag)) << payload_len;
        comptime std.debug.assert(tag_bits & nan_mask == 0);
        if (T == f64) {
            return @bitCast(payload);
        } else if (@typeInfo(T) == .pointer) {
            const ptr_bits = @intFromPtr(payload);
            std.debug.assert(nan_mask & ptr_bits == 0);
            return nan_mask | tag_bits | ptr_bits;
        } else if (@sizeOf(T) != 0) {
            // @bitCast() doesn't work on void
            const payload_bits: @Int(.unsigned, @bitSizeOf(T)) = @bitCast(payload);
            return nan_mask | tag_bits | payload_bits;
        } else {
            return nan_mask | tag_bits;
        }
    }

    fn init(comptime tag: Tag, payload: tag.Payload()) NanBoxingImpl {
        return @fromBackingInt(initBits(tag, payload));
    }

    /// If the NaN bits are set, then parses the tag from the fraction section.
    /// Otherwise, returns number_f64.
    fn getTag(self: NanBoxingImpl) Tag {
        const bits: u64 = @backingInt(self);
        // Decode only the top 16-bit header, which generates better assembly than a 64-bit mask.
        const header_bits: u16 = @truncate(bits >> payload_len);
        const header_nan_mask: u16 = @truncate(nan_mask >> payload_len);
        return if (header_bits & header_nan_mask == header_nan_mask)
            @fromBackingInt(header_bits & ~header_nan_mask)
        else
            .number_f64;
    }

    fn getPayload(self: NanBoxingImpl, comptime tag: Tag) tag.Payload() {
        std.debug.assert(self.getTag() == tag);
        const T = tag.Payload();
        const bits: u64 = @backingInt(self);
        if (@typeInfo(T) == .pointer) {
            const ptr_bits: if (@sizeOf(T) >= 8) u48 else usize = @truncate(bits);
            return @ptrFromInt(ptr_bits);
        } else {
            const payload_bits: @Int(.unsigned, @bitSizeOf(T)) = @truncate(bits);
            return @bitCast(payload_bits);
        }
    }

    pub inline fn from(value: anytype) NanBoxingImpl {
        const T = @TypeOf(value);
        const is_number = switch (@typeInfo(T)) {
            .int, .comptime_int, .float, .comptime_float => true,
            else => false,
        };
        if (T == bool) {
            return if (value) .boolean_true else .boolean_false;
        } else if (isZigString(T)) {
            const string = String.fromLiteral(value);
            return init(.string, string);
        } else if (is_number or T == Number) {
            const number = if (T == Number) value else Number.from(value);
            switch (number) {
                .i32 => |x| return init(.number_i32, x),
                .f64 => |x| {
                    // Normalize all NaN values to avoid type confusion vulnerabilities.
                    return if (std.math.isNan(x)) .number_nan else init(.number_f64, x);
                },
            }
        } else if (@typeInfo(T) == .pointer) {
            switch (@typeInfo(T).pointer.child) {
                Object => return init(.object, value),
                String => return init(.string, value),
                Symbol => return init(.symbol, value),
                BigInt => return init(.big_int, value),
                else => {},
            }
        }
        @compileError("from() called with incompatible type " ++ @typeName(T));
    }

    pub fn @"type"(self: NanBoxingImpl) Type {
        return switch (self.getTag()) {
            .uninitialized => unreachable,
            .undefined => .undefined,
            .null => .null,
            .boolean => .boolean,
            .string => .string,
            .symbol => .symbol,
            .number_i32, .number_f64 => .number,
            .big_int => .big_int,
            .object => .object,
        };
    }

    pub fn isBoolean(self: NanBoxingImpl) bool {
        return self.getTag() == .boolean;
    }

    pub fn asBoolean(self: NanBoxingImpl) bool {
        return switch (self) {
            .boolean_false => false,
            .boolean_true => true,
            else => unreachable,
        };
    }

    pub fn isString(self: NanBoxingImpl) bool {
        return self.getTag() == .string;
    }

    pub fn asString(self: NanBoxingImpl) *const String {
        return self.getPayload(.string);
    }

    pub fn isSymbol(self: NanBoxingImpl) bool {
        return self.getTag() == .symbol;
    }

    pub fn asSymbol(self: NanBoxingImpl) *const Symbol {
        return self.getPayload(.symbol);
    }

    pub fn isNumber(self: NanBoxingImpl) bool {
        return switch (self.getTag()) {
            .number_i32, .number_f64 => true,
            else => false,
        };
    }

    pub fn asNumber(self: NanBoxingImpl) Number {
        return switch (self.getTag()) {
            .number_i32 => .{ .i32 = self.getPayload(.number_i32) },
            .number_f64 => .{ .f64 = self.getPayload(.number_f64) },
            else => unreachable,
        };
    }

    pub fn isBigInt(self: NanBoxingImpl) bool {
        return self.getTag() == .big_int;
    }

    pub fn asBigInt(self: NanBoxingImpl) *const BigInt {
        return self.getPayload(.big_int);
    }

    pub fn isObject(self: NanBoxingImpl) bool {
        return self.getTag() == .object;
    }

    pub fn asObject(self: NanBoxingImpl) *Object {
        return self.getPayload(.object);
    }
};

comptime {
    // Let's make sure the size doesn't quietly change
    switch (Impl) {
        TaggedUnionImpl => switch (builtin.target.ptrBitWidth()) {
            // Only some 32-bit platforms have certain bitpacking optimizations applied
            32 => std.debug.assert(@sizeOf(Impl) == 12 or @sizeOf(Impl) == 16),
            64 => std.debug.assert(@sizeOf(Impl) == 16),
            else => unreachable,
        },
        NanBoxingImpl => std.debug.assert(@sizeOf(Impl) == 8),
        else => unreachable,
    }
}

const Impl = if (build_options.enable_nan_boxing) NanBoxingImpl else TaggedUnionImpl;
impl: Impl,

/// Sentinel value to avoid the memory overhead of `?Value`.
pub const uninitialized: Value = .{ .impl = Impl.uninitialized };

pub const @"undefined": Value = .{ .impl = Impl.undefined };
pub const @"null": Value = .{ .impl = Impl.null };
pub const @"true": Value = from(true);
pub const @"false": Value = from(false);
pub const nan: Value = from(std.math.nan(f64));
pub const infinity: Value = from(std.math.inf(f64));
pub const negative_infinity: Value = from(-std.math.inf(f64));

pub fn format(self: Value, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    switch (self.type()) {
        .undefined => try writer.writeAll("undefined"),
        .null => try writer.writeAll("null"),
        .boolean => try writer.writeAll(if (self.asBoolean()) "true" else "false"),
        .string => try writer.print("{f}", .{self.asString()}),
        .symbol => try writer.print("{f}", .{self.asSymbol()}),
        .number => try writer.print("{f}", .{self.asNumber()}),
        .big_int => try writer.print("{f}", .{self.asBigInt()}),
        .object => try writer.print("{f}", .{self.asObject()}),
    }
}

const FormatPrettyData = struct {
    value: Value,
    terminal_mode: ?std.Io.Terminal.Mode,
};

fn formatPretty(data: FormatPrettyData, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    const mode = data.terminal_mode orelse pretty_printing.state.platform.terminal_mode;
    const terminal: std.Io.Terminal = .{
        .writer = writer,
        .mode = mode,
    };
    return prettyPrintValue(data.value, terminal) catch |err| switch (err) {
        // From `std.Io.Terminal.setColor()`
        error.Canceled, error.Unexpected => {},
        error.WriteFailed => |e| return e,
    };
}

pub fn fmtPretty(
    self: Value,
    terminal_mode: ?std.Io.Terminal.Mode,
) std.fmt.Alt(FormatPrettyData, formatPretty) {
    return .{ .data = .{
        .value = self,
        .terminal_mode = terminal_mode,
    } };
}

pub inline fn from(value: anytype) Value {
    return .{ .impl = Impl.from(value) };
}

pub fn @"type"(self: Value) Type {
    std.debug.assert(!self.isUninitialized());
    return self.impl.type();
}

pub fn isUninitialized(value: Value) bool {
    return value.impl == .uninitialized;
}

pub fn isUndefined(self: Value) bool {
    return self.impl == .undefined;
}

pub fn isNull(self: Value) bool {
    return self.impl == .null;
}

pub fn isBoolean(self: Value) bool {
    return self.impl.isBoolean();
}

pub fn asBoolean(self: Value) bool {
    return self.impl.asBoolean();
}

pub fn isString(self: Value) bool {
    return self.impl.isString();
}

pub fn asString(self: Value) *const String {
    return self.impl.asString();
}

pub fn isSymbol(self: Value) bool {
    return self.impl.isSymbol();
}

pub fn asSymbol(self: Value) *const Symbol {
    return self.impl.asSymbol();
}

pub fn isNumber(self: Value) bool {
    return self.impl.isNumber();
}

pub fn asNumber(self: Value) Number {
    return self.impl.asNumber();
}

pub fn isBigInt(self: Value) bool {
    return self.impl.isBigInt();
}

pub fn asBigInt(self: Value) *const BigInt {
    return self.impl.asBigInt();
}

pub fn isObject(self: Value) bool {
    return self.impl.isObject();
}

pub fn asObject(self: Value) *Object {
    return self.impl.asObject();
}

pub fn castObject(self: Value, comptime T: type) ?*T {
    if (self.isObject()) {
        if (self.asObject().is(T)) {
            return self.asObject().as(T);
        }
    }
    return null;
}

/// Leaks an implementation detail, use with care.
pub fn __isI32(self: Value) bool {
    return switch (Impl) {
        NanBoxingImpl => self.impl.getTag() == .number_i32,
        TaggedUnionImpl => self.impl == .number_i32,
        else => comptime unreachable,
    };
}

/// Leaks an implementation detail, use with care.
pub fn __asI32(self: Value) i32 {
    return switch (Impl) {
        NanBoxingImpl => self.impl.getPayload(.number_i32),
        TaggedUnionImpl => self.impl.number_i32,
        else => comptime unreachable,
    };
}

/// Leaks an implementation detail, use with care.
pub fn __isF64(self: Value) bool {
    return switch (Impl) {
        NanBoxingImpl => self.impl.getTag() == .number_f64,
        TaggedUnionImpl => self.impl == .number_f64,
        else => comptime unreachable,
    };
}

/// Leaks an implementation detail, use with care.
pub fn __asF64(self: Value) f64 {
    return switch (Impl) {
        NanBoxingImpl => self.impl.getPayload(.number_f64),
        TaggedUnionImpl => self.impl.number_f64,
        else => comptime unreachable,
    };
}

/// Leaks an implementation detail, use with care.
pub fn __toF64(self: Value) f64 {
    return if (self.__isF64()) self.__asF64() else @floatFromInt(self.__asI32());
}

/// Return a string according to the 'typeof' operator semantics.
pub fn typeof(self: Value) *const String {
    // Excerpt from https://tc39.es/ecma262/#sec-typeof-operator-runtime-semantics-evaluation
    return switch (self.type()) {
        // 4. If val is undefined, return "undefined".
        .undefined => String.fromLiteral("undefined"),

        // 5. If val is null, return "object".
        .null => String.fromLiteral("object"),

        // 6. If val is a String, return "string".
        .string => String.fromLiteral("string"),

        // 7. If val is a Symbol, return "symbol".
        .symbol => String.fromLiteral("symbol"),

        // 8. If val is a Boolean, return "boolean".
        .boolean => String.fromLiteral("boolean"),

        // 9. If val is a Number, return "number".
        .number => String.fromLiteral("number"),

        // 10. If val is a BigInt, return "bigint".
        .big_int => String.fromLiteral("bigint"),

        // 11. Assert: val is an Object.
        .object => blk: {
            // 12. If the host is a web browser or otherwise supports The [[IsHTMLDDA]] Internal
            //     Slot, then
            if (build_options.enable_annex_b) {
                // a. If val has an [[IsHTMLDDA]] internal slot, return "undefined".
                if (self.asObject().isHTMLDDA()) break :blk String.fromLiteral("undefined");
            }

            // 13. If val has a [[Call]] internal method, return "function".
            if (self.asObject().internalMethods().call) |_| break :blk String.fromLiteral("function");

            // 14. Return "object".
            break :blk String.fromLiteral("object");
        },
    };
}

/// 6.2.6.5 ToPropertyDescriptor ( obj )
/// https://tc39.es/ecma262/#sec-topropertydescriptor
pub fn toPropertyDescriptor(self: Value, agent: *Agent) Agent.Error!PropertyDescriptor {
    // 1. If obj is not an Object, throw a TypeError exception.
    if (!self.isObject()) {
        return agent.throwException(.type_error, "{f} is not an Object", .{self});
    }
    const obj = self.asObject();

    // 2. Let propertyDesc be a new Property Descriptor that initially has no fields.
    var property_desc: PropertyDescriptor = .{};

    // 3. Let hasEnumerable be ? HasProperty(obj, "enumerable").
    const has_enumerable = try obj.hasProperty(agent, PropertyKey.from("enumerable"));

    // 4. If hasEnumerable is true, then
    if (has_enumerable) {
        // a. Let enumerable be ToBoolean(? Get(obj, "enumerable")).
        const enumerable = (try obj.get(
            agent,
            PropertyKey.from("enumerable"),
        )).toBoolean();

        // b. Set propertyDesc.[[Enumerable]] to enumerable.
        property_desc.enumerable = enumerable;
    }

    // 5. Let hasConfigurable be ? HasProperty(obj, "configurable").
    const has_configurable = try obj.hasProperty(
        agent,
        PropertyKey.from("configurable"),
    );

    // 6. If hasConfigurable is true, then
    if (has_configurable) {
        // a. Let configurable be ToBoolean(? Get(obj, "configurable")).
        const configurable = (try obj.get(
            agent,
            PropertyKey.from("configurable"),
        )).toBoolean();

        // b. Set propertyDesc.[[Configurable]] to configurable.
        property_desc.configurable = configurable;
    }

    // 7. Let hasValue be ? HasProperty(obj, "value").
    const has_value = try obj.hasProperty(agent, PropertyKey.from("value"));

    // 8. If hasValue is true, then
    if (has_value) {
        // a. Let value be ? Get(obj, "value").
        const value = try obj.get(agent, PropertyKey.from("value"));

        // b. Set propertyDesc.[[Value]] to value.
        property_desc.value = value;
    }

    // 9. Let hasWritable be ? HasProperty(obj, "writable").
    const has_writable = try obj.hasProperty(agent, PropertyKey.from("writable"));

    // 10. If hasWritable is true, then
    if (has_writable) {
        // a. Let writable be ToBoolean(? Get(obj, "writable")).
        const writable = (try obj.get(
            agent,
            PropertyKey.from("writable"),
        )).toBoolean();

        // b. Set propertyDesc.[[Writable]] to writable.
        property_desc.writable = writable;
    }

    // 11. Let hasGet be ? HasProperty(obj, "get").
    const has_get = try obj.hasProperty(agent, PropertyKey.from("get"));

    // 12. If hasGet is true, then
    if (has_get) {
        // a. Let getter be ? Get(obj, "get").
        const getter = try obj.get(agent, PropertyKey.from("get"));

        // b. If IsCallable(getter) is false and getter is not undefined, throw a TypeError
        //    exception.
        if (!getter.isCallable() and !getter.isUndefined()) {
            return agent.throwException(.type_error, "{f} is not callable", .{getter});
        }

        // c. Set propertyDesc.[[Getter]] to getter.
        property_desc.getter = if (!getter.isUndefined()) getter.asObject() else @as(?*Object, null);
    }

    // 13. Let hasSet be ? HasProperty(obj, "set").
    const has_set = try obj.hasProperty(agent, PropertyKey.from("set"));

    // 14. If hasSet is true, then
    if (has_set) {
        // a. Let setter be ? Get(obj, "set").
        const setter = try obj.get(agent, PropertyKey.from("set"));

        // b. If IsCallable(setter) is false and setter is not undefined, throw a TypeError
        //    exception.
        if (!setter.isCallable() and !setter.isUndefined()) {
            return agent.throwException(.type_error, "{f} is not callable", .{setter});
        }

        // c. Set propertyDesc.[[Setter]] to setter.
        property_desc.setter = if (!setter.isUndefined()) setter.asObject() else @as(?*Object, null);
    }

    // 15. If propertyDesc has a [[Getter]] field or propertyDesc has a [[Setter]] field, then
    if (property_desc.getter != null or property_desc.setter != null) {
        // a. If propertyDesc has a [[Value]] field or propertyDesc has a [[Writable]] field, throw
        //    a TypeError exception.
        if (property_desc.value != null or property_desc.writable != null) {
            return agent.throwException(
                .type_error,
                "Descriptor with 'get' or 'set' property must not have 'value' or 'writable property'",
                .{},
            );
        }
    }

    // 16. Return propertyDesc.
    return property_desc;
}

pub inline fn toPrimitive(self: Value, agent: *Agent, preferred_type: ?PreferredType) Agent.Error!Value {
    // OPTIMIZATION: Inline the fast path.
    if (!self.isObject()) {
        @branchHint(.likely);
        return self;
    }
    return self.toPrimitiveImpl(agent, preferred_type);
}

/// 7.1.1 ToPrimitive ( input [ , preferredType ] )
/// https://tc39.es/ecma262/#sec-toprimitive
fn toPrimitiveImpl(self: Value, agent: *Agent, preferred_type: ?PreferredType) Agent.Error!Value {
    // 1. If input is an Object, then
    if (self.isObject()) {
        // a. Let exoticToPrimitive be ? GetMethod(input, %Symbol.toPrimitive%).
        const maybe_exotic_to_primitive = try self.getMethod(
            agent,
            PropertyKey.from(agent.well_known_symbols.to_primitive),
        );

        // b. If exoticToPrimitive is not undefined, then
        if (maybe_exotic_to_primitive) |exotic_to_primitive| {
            const hint = blk: {
                // i. If preferredType is not present, then
                if (preferred_type == null) {
                    // 1. Let hint be "default".
                    break :blk String.fromLiteral("default");
                }
                break :blk switch (preferred_type.?) {
                    // ii. Else if preferredType is string, then
                    //     1. Let hint be "string".
                    .string => String.fromLiteral("string"),
                    // iii. Else,
                    //     1. Assert: preferredType is number.
                    //     2. Let hint be "number".
                    .number => String.fromLiteral("number"),
                };
            };

            // iv. Let result be ? Call(exoticToPrimitive, input, « hint »).
            const result = try exotic_to_primitive.call(agent, self, &.{from(hint)});

            // v. If result is not an Object, return result.
            if (!result.isObject()) return result;

            // vi. Throw a TypeError exception.
            return agent.throwException(
                .type_error,
                "Could not convert object to primitive",
                .{},
            );
        }

        // c. If preferredType is not present, set preferredType to number.
        // d. Return ? OrdinaryToPrimitive(input, preferredType).
        return self.asObject().ordinaryToPrimitive(agent, preferred_type orelse .number);
    }

    // 2. Return input.
    // NOTE: This is handled by the fast path.
    unreachable;
}

pub inline fn toBoolean(arg: Value) bool {
    // OPTIMIZATION: Inline the fast path.
    if (arg.isBoolean()) {
        @branchHint(.likely);
        return arg.asBoolean();
    }
    return arg.toBooleanImpl();
}

/// 7.1.2 ToBoolean ( arg )
/// https://tc39.es/ecma262/#sec-toboolean
fn toBooleanImpl(arg: Value) bool {
    switch (arg.type()) {
        // 1. If arg is a Boolean, return arg.
        // NOTE: This is handled by the fast path.
        .boolean => unreachable,

        // 2. If arg is one of undefined, null, +0𝔽, -0𝔽, NaN, 0ℤ, or the empty String, return
        //    false.
        .undefined, .null => return false,
        .number => if (arg.asNumber().isZero() or arg.asNumber().isNan()) {
            return false;
        },
        .big_int => if (arg.asBigInt().managed.eqlZero()) {
            return false;
        },
        .string => if (arg.asString().isEmpty()) {
            return false;
        },
        else => {},
    }

    // 3. If the host is a web browser or otherwise supports The [[IsHTMLDDA]] Internal Slot, then
    if (build_options.enable_annex_b) {
        // a. If arg is an Object and arg has an [[IsHTMLDDA]] internal slot, return false.
        if (arg.isObject() and arg.asObject().isHTMLDDA()) return false;
    }

    // 4. Return true.
    return true;
}

/// 7.1.3 ToNumeric ( arg )
/// https://tc39.es/ecma262/#sec-tonumeric
pub fn toNumeric(arg: Value, agent: *Agent) Agent.Error!Numeric {
    // 1. Let primitiveValue be ? ToPrimitive(arg, number).
    const primitive_value = try arg.toPrimitive(agent, .number);

    // 2. If primitiveValue is a BigInt, return primitiveValue.
    if (primitive_value.isBigInt()) return .{ .big_int = primitive_value.asBigInt() };

    // 3. Return ? ToNumber(primitiveValue).
    return .{ .number = try primitive_value.toNumber(agent) };
}

pub inline fn toNumber(arg: Value, agent: *Agent) Agent.Error!Number {
    // OPTIMIZATION: Inline the fast path.
    if (arg.isNumber()) {
        @branchHint(.likely);
        return arg.asNumber();
    }
    return arg.toNumberImpl(agent);
}

/// 7.1.4 ToNumber ( arg )
/// https://tc39.es/ecma262/#sec-tonumber
fn toNumberImpl(arg: Value, agent: *Agent) Agent.Error!Number {
    switch (arg.type()) {
        // 1. If arg is a Number, return arg.
        // NOTE: This is handled by the fast path.
        .number => unreachable,

        // 2. If arg is either a Symbol or a BigInt, throw a TypeError exception.
        .symbol => return agent.throwException(
            .type_error,
            "Cannot convert Symbol to number",
            .{},
        ),
        .big_int => return agent.throwException(
            .type_error,
            "Cannot convert BigInt to number",
            .{},
        ),

        // 3. If arg is undefined, return NaN.
        .undefined => return Number.from(std.math.nan(f64)),

        // 4. If arg is either null or false, return +0𝔽.
        // 5. If arg is true, return 1𝔽.
        .null => return Number.from(0),
        .boolean => return Number.from(@intFromBool(arg.asBoolean())),

        // 6. If arg is a String, return StringToNumber(arg).
        .string => return stringToNumber(agent, arg.asString()),

        // 7. Assert: arg is an Object.
        .object => {
            // 8. Let primitiveValue be ? ToPrimitive(arg, number).
            const primitive_value = try arg.toPrimitive(agent, .number);

            // 9. Assert: primitiveValue is not an Object.
            std.debug.assert(!primitive_value.isObject());

            // 10. Return ? ToNumber(primitiveValue).
            return primitive_value.toNumber(agent);
        },
    }
}

pub inline fn toIntegerOrInfinity(arg: Value, agent: *Agent) Agent.Error!f64 {
    // OPTIMIZATION: Inline the fast path.
    if (arg.__isI32()) {
        @branchHint(.likely);
        return @floatFromInt(arg.__asI32());
    }
    return arg.toIntegerOrInfinityImpl(agent);
}

/// 7.1.5 ToIntegerOrInfinity ( arg )
/// https://tc39.es/ecma262/#sec-tointegerorinfinity
fn toIntegerOrInfinityImpl(arg: Value, agent: *Agent) Agent.Error!f64 {
    // 1. Let number be ? ToNumber(arg).
    const number = try arg.toNumber(agent);

    // 2. If number is one of NaN, +0𝔽, or -0𝔽, return 0.
    if (number.isNan() or number.asFloat() == 0) return 0;

    // 3. If number is +∞𝔽, return +∞.
    if (number.isPositiveInf()) return std.math.inf(f64);

    // 4. If number is -∞𝔽, return -∞.
    if (number.isNegativeInf()) return -std.math.inf(f64);

    // 5. Return truncate(ℝ(number)).
    const truncated = number.truncate().asFloat();
    // Normalize negative zero
    return if (truncated == 0) 0 else truncated;
}

/// 7.1.6 SnapToInteger ( arg, nonIntHandling [ , minimum [ , maximum ] ] )
/// https://tc39.es/ecma262/#sec-snaptointeger
pub fn snapToInteger(
    arg: Value,
    agent: *Agent,
    non_int_handling: enum { reject, truncate },
    comptime maybe_minimum: ?comptime_int,
    comptime maybe_maximum: ?comptime_int,
) Agent.Error!f64 {
    // 1. Let number be ? ToNumber(arg).
    const number = try arg.toNumber(agent);

    // 2. If number is one of NaN, +∞𝔽, or -∞𝔽, throw a RangeError exception.
    if (!number.isFinite()) {
        return agent.throwException(.range_error, "Value must be a finite number", .{});
    }

    // 3. Let mv be ℝ(number).
    var mv = number.asFloat();

    // 4. If nonIntHandling is truncate, set mv to truncate(mv).
    if (non_int_handling == .truncate) {
        mv = @trunc(mv);
    }

    // 5. If mv is not an integer, throw a RangeError exception.
    if (mv != @trunc(mv)) {
        return agent.throwException(.range_error, "Value must be an integer", .{});
    }

    // 6. If minimum is present and mv < minimum, throw a RangeError exception.
    if (maybe_minimum) |minimum| {
        if (mv < minimum) {
            return agent.throwException(
                .range_error,
                "Value must not be less than {}",
                .{minimum},
            );
        }
    }

    // 7. If maximum is present and mv > maximum, throw a RangeError exception.
    if (maybe_maximum) |maximum| {
        if (mv > maximum) {
            return agent.throwException(
                .range_error,
                "Value must not be greater than {}",
                .{maximum},
            );
        }
    }

    // 8. Return mv.
    return mv;
}

/// 7.1.7 ToFixedSizeInteger ( int, signed, bitWidth )
/// https://tc39.es/ecma262/#sec-tofixedsizeinteger
pub fn toFixedSizeInteger(int: f64, comptime T: type) T {
    const info = @typeInfo(T).int;
    comptime std.debug.assert(info.bits <= 32); // Not used for bigint

    // 1. If int = +∞ or int = -∞, return 0.
    std.debug.assert(!std.math.isNan(int));
    if (!std.math.isFinite(int)) return 0;

    // OPTIMIZATION: Avoid modulo if the number is already in int range.
    if (info.signedness == .signed) {
        if (int >= std.math.minInt(T) and int <= std.math.maxInt(T)) {
            return @intFromFloat(int);
        }
    } else {
        if (int >= 0 and int <= std.math.maxInt(T)) {
            return @intFromFloat(int);
        }
    }

    // 2. Let fixedInt be int modulo 2**bitWidth.
    const fixed_int: @Int(.unsigned, info.bits) = @intFromFloat(@mod(int, comptime std.math.pow(f64, 2, info.bits)));

    // 3. NOTE: The following step does not change the two's complement representation of fixedInt.
    // 4. If signed is signed and fixedInt ≥ 2**(bitWidth - 1), set fixedInt to
    //    fixedInt - 2**bitWidth.
    // 5. Return fixedInt.
    return @bitCast(fixed_int);
}

/// 7.1.8 ToInt32 ( arg )
/// https://tc39.es/ecma262/#sec-toint32
pub fn toInt32(arg: Value, agent: *Agent) Agent.Error!i32 {
    // OPTIMIZATION: Fast path for i32 values
    if (arg.__isI32()) {
        @branchHint(.likely);
        return arg.__asI32();
    }

    // 1. Let int be ? ToIntegerOrInfinity(arg).
    // 2. Return 𝔽(ToFixedSizeInteger(int, signed, 32)).
    const number = try arg.toNumber(agent);
    return number.toInt32();
}

/// 7.1.9 ToUint32 ( arg )
/// https://tc39.es/ecma262/#sec-touint32
pub fn toUint32(arg: Value, agent: *Agent) Agent.Error!u32 {
    // OPTIMIZATION: Fast path for i32 values
    if (arg.__isI32()) {
        @branchHint(.likely);
        return @bitCast(arg.__asI32());
    }

    // 1. Let int be ? ToIntegerOrInfinity(arg).
    const int = try arg.toIntegerOrInfinity(agent);

    // 2. Return 𝔽(ToFixedSizeInteger(int, unsigned, 32)).
    return toFixedSizeInteger(int, u32);
}

/// 7.1.10 ToInt16 ( arg )
/// https://tc39.es/ecma262/#sec-toint16
pub fn toInt16(arg: Value, agent: *Agent) Agent.Error!i16 {
    // OPTIMIZATION: Fast path for i32 values
    if (arg.__isI32()) {
        @branchHint(.likely);
        const fixed_int: u16 = @truncate(@as(u32, @bitCast(arg.__asI32())));
        return @bitCast(fixed_int);
    }

    // 1. Let int be ? ToIntegerOrInfinity(arg).
    const int = try arg.toIntegerOrInfinity(agent);

    // 2. Return 𝔽(ToFixedSizeInteger(int, signed, 16)).
    return toFixedSizeInteger(int, i16);
}

/// 7.1.11 ToUint16 ( arg )
/// https://tc39.es/ecma262/#sec-touint16
pub fn toUint16(arg: Value, agent: *Agent) Agent.Error!u16 {
    // OPTIMIZATION: Fast path for i32 values
    if (arg.__isI32()) {
        @branchHint(.likely);
        return @truncate(@as(u32, @bitCast(arg.__asI32())));
    }

    // 1. Let int be ? ToIntegerOrInfinity(arg).
    const int = try arg.toIntegerOrInfinity(agent);

    // 2. Return 𝔽(ToFixedSizeInteger(int, unsigned, 16)).
    return toFixedSizeInteger(int, u16);
}

/// 7.1.12 ToInt8 ( arg )
/// https://tc39.es/ecma262/#sec-toint8
pub fn toInt8(arg: Value, agent: *Agent) Agent.Error!i8 {
    // OPTIMIZATION: Fast path for i32 values
    if (arg.__isI32()) {
        @branchHint(.likely);
        const fixed_int: u8 = @truncate(@as(u32, @bitCast(arg.__asI32())));
        return @bitCast(fixed_int);
    }

    // 1. Let int be ? ToIntegerOrInfinity(arg).
    const int = try arg.toIntegerOrInfinity(agent);

    // 2. Return 𝔽(ToFixedSizeInteger(int, signed, 8)).
    return toFixedSizeInteger(int, i8);
}

/// 7.1.13 ToUint8 ( arg )
/// https://tc39.es/ecma262/#sec-touint8
pub fn toUint8(arg: Value, agent: *Agent) Agent.Error!u8 {
    // OPTIMIZATION: Fast path for i32 values
    if (arg.__isI32()) {
        @branchHint(.likely);
        return @truncate(@as(u32, @bitCast(arg.__asI32())));
    }

    // 1. Let int be ? ToIntegerOrInfinity(arg).
    const int = try arg.toIntegerOrInfinity(agent);

    // 2. Return 𝔽(ToFixedSizeInteger(int, unsigned, 8)).
    return toFixedSizeInteger(int, u8);
}

/// 7.1.14 ToUint8Clamp ( arg )
/// https://tc39.es/ecma262/#sec-touint8clamp
pub fn toUint8Clamp(arg: Value, agent: *Agent) Agent.Error!u8 {
    // 1. Let number be ? ToNumber(arg).
    const number = try arg.toNumber(agent);

    // 2. If number is NaN, return +0𝔽.
    if (number.isNan()) return 0;

    // 3. Let mv be the extended mathematical value of number.
    // 4. Let clamped be the result of clamping mv between 0 and 255.
    const clamped = std.math.clamp(number.asFloat(), 0, 255);

    // 5. Let f be floor(clamped).
    const f = @floor(clamped);
    const f_int: u8 = @intFromFloat(f);

    // 6. If clamped < f + 0.5, return 𝔽(f).
    if (clamped < f + 0.5) return f_int;

    // 7. If clamped > f + 0.5, return 𝔽(f + 1).
    if (clamped > f + 0.5) return f_int + 1;

    // 8. If f is even, return 𝔽(f).
    if (f_int % 2 == 0) return f_int;

    // 9. Return 𝔽(f + 1).
    return f_int + 1;
}

pub inline fn toBigInt(arg: Value, agent: *Agent) Agent.Error!*const BigInt {
    // OPTIMIZATION: Inline the fast path.
    if (arg.isBigInt()) {
        @branchHint(.likely);
        return arg.asBigInt();
    }
    return arg.toBigIntImpl(agent);
}

/// 7.1.15 ToBigInt ( arg )
/// https://tc39.es/ecma262/#sec-tobigint
fn toBigIntImpl(arg: Value, agent: *Agent) Agent.Error!*const BigInt {
    // 1. Let prim be ? ToPrimitive(argument, number).
    const primitive = try arg.toPrimitive(agent, .number);

    // 2. Return the value that prim corresponds to in Table 12.
    return switch (primitive.type()) {
        // Throw a TypeError exception.
        .undefined => agent.throwException(.type_error, "Cannot convert undefined to BigInt", .{}),
        .null => agent.throwException(.type_error, "Cannot convert null to BigInt", .{}),
        .number => agent.throwException(.type_error, "Cannot convert number to BigInt", .{}),
        .symbol => agent.throwException(.type_error, "Cannot convert symbol to BigInt", .{}),

        // Return 1n if prim is true and 0n if prim is false.
        .boolean => if (primitive.asBoolean())
            .one
        else
            .zero,

        // Return prim.
        // NOTE: This is handled by the fast path.
        .big_int => primitive.asBigInt(),

        .string => {
            // 1. Let n be StringToBigInt(prim).
            const n = try stringToBigInt(agent, primitive.asString());

            // 2. If n is undefined, throw a SyntaxError exception.
            // 3. Return n.
            return n orelse agent.throwException(
                .syntax_error,
                "Cannot convert string to BigInt",
                .{},
            );
        },

        .object => unreachable,
    };
}

/// 7.1.17 ToBigInt64 ( arg )
/// https://tc39.es/ecma262/#sec-tobigint64
pub fn toBigInt64(arg: Value, agent: *Agent) Agent.Error!i64 {
    // 1. Let int be ℝ(? ToBigInt(arg)).
    const int = try arg.toBigInt(agent);

    // 2. Return ℤ(ToFixedSizeInteger(int, signed, 64)).
    var int64bit = try std.math.big.int.Managed.init(agent.gc_allocator);
    try int64bit.truncate(&int.managed, .signed, 64);
    return int64bit.toInt(i64) catch unreachable;
}

/// 7.1.18 ToBigUint64 ( arg )
/// https://tc39.es/ecma262/#sec-tobiguint64
pub fn toBigUint64(arg: Value, agent: *Agent) Agent.Error!u64 {
    // 1. Let int be ℝ(? ToBigInt(arg)).
    const int = try arg.toBigInt(agent);

    // 2. Return ℤ(ToFixedSizeInteger(int, unsigned, 64)).
    var int64bit = try std.math.big.int.Managed.init(agent.gc_allocator);
    try int64bit.truncate(&int.managed, .unsigned, 64);
    return int64bit.toInt(u64) catch unreachable;
}

pub inline fn toString(arg: Value, agent: *Agent) Agent.Error!*const String {
    // OPTIMIZATION: Inline the fast path.
    if (arg.isString()) {
        @branchHint(.likely);
        return arg.asString();
    }
    return arg.toStringImpl(agent);
}

/// 7.1.19 ToString ( arg )
/// https://tc39.es/ecma262/#sec-tostring
fn toStringImpl(arg: Value, agent: *Agent) Agent.Error!*const String {
    return switch (arg.type()) {
        // 1. If arg is a String, return arg.
        // NOTE: This is handled by the fast path.
        .string => unreachable,

        // 2. If arg is a Symbol, throw a TypeError exception.
        .symbol => return agent.throwException(
            .type_error,
            "Cannot convert Symbol to string",
            .{},
        ),

        // 3. If arg is undefined, return "undefined".
        .undefined => String.fromLiteral("undefined"),

        // 4. If arg is null, return "null".
        .null => String.fromLiteral("null"),

        // 5. If arg is true, return "true".
        // 6. If arg is false, return "false".
        .boolean => if (arg.asBoolean())
            String.fromLiteral("true")
        else
            String.fromLiteral("false"),

        // 7. If arg is a Number, return Number::toString(arg, 10).
        .number => arg.asNumber().toString(agent, 10),

        // 8. If arg is a BigInt, return BigInt::toString(arg, 10).
        .big_int => arg.asBigInt().toString(agent, 10),

        // 9. Assert: arg is an Object.
        .object => {
            // 10. Let primitiveValue be ? ToPrimitive(arg, string).
            const primitive_value = try arg.toPrimitive(agent, .string);

            // 11. Assert: primitiveValue is not an Object.
            std.debug.assert(!primitive_value.isObject());

            // 12. Return ? ToString(primitiveValue).
            return primitive_value.toString(agent);
        },
    };
}

pub inline fn toObject(arg: Value, agent: *Agent) Agent.Error!*Object {
    // OPTIMIZATION: Inline the fast path.
    if (arg.isObject()) {
        @branchHint(.likely);
        return arg.asObject();
    }
    return arg.toObjectImpl(agent);
}

/// 7.1.20 ToObject ( arg )
/// https://tc39.es/ecma262/#sec-toobject
fn toObjectImpl(arg: Value, agent: *Agent) Agent.Error!*Object {
    const realm = agent.currentRealm();
    return switch (arg.type()) {
        // 1. If arg is either undefined or null, throw a TypeError exception.
        .undefined => agent.throwException(.type_error, "Cannot convert undefined to Object", .{}),
        .null => agent.throwException(.type_error, "Cannot convert null to Object", .{}),

        // 2. If arg is a Boolean, return a new Boolean object whose [[BooleanData]] internal slot
        //    is set to arg. See 20.3 for a description of Boolean objects.
        .boolean => {
            const boolean = try builtins.Boolean.create(agent, .{
                .fields = .{ .boolean_data = arg.asBoolean() },
                .prototype = try realm.intrinsic(.boolean_prototype),
            });
            return &boolean.object;
        },

        // 3. If arg is a Number, return a new Number object whose [[NumberData]] internal slot is
        //    set to arg. See 21.1 for a description of Number objects.
        .number => {
            const number = try builtins.Number.create(agent, .{
                .fields = .{ .number_data = arg.asNumber() },
                .prototype = try realm.intrinsic(.number_prototype),
            });
            return &number.object;
        },

        // 4. If arg is a String, return a new String object whose [[StringData]] internal slot is
        //    set to arg. See 22.1 for a description of String objects.
        .string => {
            const string = try stringCreate(
                agent,
                arg.asString(),
                try realm.intrinsic(.string_prototype),
            );
            return &string.object;
        },

        // 5. If arg is a Symbol, return a new Symbol object whose [[SymbolData]] internal slot is
        //    set to arg. See 20.4 for a description of Symbol objects.
        .symbol => {
            const symbol = try builtins.Symbol.create(agent, .{
                .fields = .{ .symbol_data = arg.asSymbol() },
                .prototype = try realm.intrinsic(.symbol_prototype),
            });
            return &symbol.object;
        },

        // 6. If arg is a BigInt, return a new BigInt object whose [[BigIntData]] internal slot is
        //    set to arg. See 21.2 for a description of BigInt objects.
        .big_int => {
            const big_int = try builtins.BigInt.create(agent, .{
                .fields = .{ .big_int_data = arg.asBigInt() },
                .prototype = try realm.intrinsic(.big_int_prototype),
            });
            return &big_int.object;
        },

        // 7. Assert: arg is an Object.
        // 8. Return arg.
        // NOTE: This is handled by the fast path.
        .object => unreachable,
    };
}

/// 7.1.21 ToPropertyKey ( arg )
/// https://tc39.es/ecma262/#sec-topropertykey
pub fn toPropertyKey(arg: Value, agent: *Agent) Agent.Error!PropertyKey {
    // 1. Let key be ? ToPrimitive(arg, string).
    const key = try arg.toPrimitive(agent, .string);

    // 2. If key is a Symbol, then
    if (key.isSymbol()) {
        // a. Return key.
        return PropertyKey.from(key.asSymbol());
    }

    // OPTIMIZATION: If we have a number that fits into an `PropertyKey.IntegerIndex` there's
    //               no need to do a string conversion and back.
    if (key.isNumber() and key.asNumber().isIntegral()) {
        switch (key.asNumber()) {
            .i32 => |value| if (value >= 0) {
                return PropertyKey.from(@as(PropertyKey.IntegerIndex, @intCast(value)));
            },
            .f64 => |value| if (value >= 0 and value <= std.math.maxInt(PropertyKey.IntegerIndex)) {
                return PropertyKey.from(@as(PropertyKey.IntegerIndex, @intFromFloat(value)));
            },
        }
    }

    // 3. Return ! ToString(key).
    const string = key.toString(agent) catch |err| try noexcept(err);
    return PropertyKey.from(string);
}

/// 7.1.22 ToLength ( arg )
/// https://tc39.es/ecma262/#sec-tolength
pub fn toLength(self: Value, agent: *Agent) Agent.Error!u53 {
    // OPTIMIZATION: Fast path for i32 values
    if (self.__isI32()) {
        @branchHint(.likely);
        return @max(0, self.__asI32());
    }

    // 1. Let length be ? ToIntegerOrInfinity(arg).
    const length = try self.toIntegerOrInfinity(agent);

    // 2. Let clampedLength be the result of clamping length between 0 and 2**53 - 1.
    const clamped_length = std.math.clamp(length, 0, std.math.maxInt(u53));

    // 3. Return 𝔽(clampedLength).
    return @intFromFloat(clamped_length);
}

/// 7.1.24 ToIndex ( arg )
/// https://tc39.es/ecma262/#sec-toindex
pub fn toIndex(arg: Value, agent: *Agent) Agent.Error!u53 {
    // OPTIMIZATION: Fast path for i32 values
    if (arg.__isI32() and arg.__asI32() >= 0) {
        @branchHint(.likely);
        return @intCast(arg.__asI32());
    }

    // 1. Let int be ? ToIntegerOrInfinity(arg).
    const int = try arg.toIntegerOrInfinity(agent);

    // 2. If int is not in the inclusive interval from 0 to 2**53 - 1, throw a RangeError exception.
    if (int < 0 or int > std.math.maxInt(u53))
        return agent.throwException(.range_error, "Value is not not a valid index", .{});

    // 3. Return int.
    return @intFromFloat(int);
}

/// 7.1.25 ToAbsoluteIndex ( value, length )
/// https://tc39.es/ecma262/#sec-toabsoluteindex
pub fn toAbsoluteIndex(value: Value, agent: *Agent, length: u53) Agent.Error!f64 {
    // 1. Let int be ? ToIntegerOrInfinity(value).
    var int = try value.toIntegerOrInfinity(agent);

    // 2. If int is finite and int < 0, set int to length + int.
    if (std.math.isFinite(int) and int < 0) {
        int = @as(f64, @floatFromInt(length)) + int;
    }

    // 3. Return int.
    return int;
}

/// 7.1.26 ToClampedIndex ( value, length )
/// https://tc39.es/ecma262/#sec-toclampedindex
pub fn toClampedIndex(value: Value, agent: *Agent, length: u53) Agent.Error!u53 {
    // 1. Let index be ? ToAbsoluteIndex(value, length).
    const index = try value.toAbsoluteIndex(agent, length);

    // 2. Return the result of clamping index between 0 and length.
    return std.math.clamp(std.math.lossyCast(u53, index), 0, length);
}

/// 7.2.1 RequireObjectCoercible ( arg )
/// https://tc39.es/ecma262/#sec-requireobjectcoercible
pub fn requireObjectCoercible(arg: Value, agent: *Agent) error{ExceptionThrown}!void {
    return switch (arg.type()) {
        // 1. If arg is either undefined or null, throw a TypeError exception.
        .undefined => agent.throwException(.type_error, "Cannot convert undefined to Object", .{}),
        .null => agent.throwException(.type_error, "Cannot convert null to Object", .{}),

        // 2. Return unused.
        else => {},
    };
}

/// 7.2.2 IsArray ( arg )
/// https://tc39.es/ecma262/#sec-isarray
pub fn isArray(arg: Value, agent: *Agent) error{ExceptionThrown}!bool {
    // 1. If arg is not an Object, return false.
    if (!arg.isObject()) return false;
    const obj = arg.asObject();

    // 2. If arg is an Array exotic object, return true.
    if (obj.is(builtins.Array)) return true;

    // 3. If arg is a Proxy exotic object, then
    if (obj.cast(builtins.Proxy)) |proxy| {
        // a. Perform ? ValidateNonRevokedProxy(arg).
        try validateNonRevokedProxy(agent, proxy);

        // b. Let proxyTarget be arg.[[ProxyTarget]].
        const proxy_target = proxy.fields.proxy_target.?;

        // c. Return ? IsArray(proxyTarget).
        return from(proxy_target).isArray(agent);
    }

    // 4. Return false.
    return false;
}

/// 7.2.3 IsCallable ( arg )
/// https://tc39.es/ecma262/#sec-iscallable
pub fn isCallable(arg: Value) bool {
    // 1. If arg is not an Object, return false.
    if (!arg.isObject()) return false;
    const obj = arg.asObject();

    // 2. If arg has a [[Call]] internal method, return true.
    if (obj.internalMethods().call != null) return true;

    // 3. Return false.
    return false;
}

/// 7.2.4 IsConstructor ( arg )
/// https://tc39.es/ecma262/#sec-isconstructor
pub fn isConstructor(arg: Value) bool {
    // 1. If arg is not an Object, return false.
    if (!arg.isObject()) return false;
    const obj = arg.asObject();

    // 2. If arg has a [[Construct]] internal method, return true.
    if (obj.internalMethods().construct != null) return true;

    // 3. Return false.
    return false;
}

/// 7.2.6 IsRegExp ( arg )
/// https://tc39.es/ecma262/#sec-isregexp
pub fn isRegExp(arg: Value, agent: *Agent) Agent.Error!bool {
    // 1. If arg is not an Object, return false.
    if (!arg.isObject()) return false;
    const obj = arg.asObject();

    // 2. Let matcher be ? Get(arg, %Symbol.match%).
    const matcher = try obj.get(
        agent,
        PropertyKey.from(agent.well_known_symbols.match),
    );

    // 3. If matcher is not undefined, return ToBoolean(matcher).
    if (!matcher.isUndefined()) return matcher.toBoolean();

    // 4. If arg has a [[RegExpMatcher]] internal slot, return true.
    if (obj.is(builtins.RegExp)) return true;

    // 5. Return false.
    return false;
}

/// 7.3.3 GetV ( value, propertyKey )
/// https://tc39.es/ecma262/#sec-getv
pub fn get(value: Value, agent: *Agent, property_key: PropertyKey) Agent.Error!Value {
    // 1. Let obj be ? ToObject(value).
    const obj = try value.toObject(agent);

    // 2. Return ? obj.[[Get]](propertyKey, value).
    return obj.internalMethods().get(agent, obj, property_key, value);
}

/// 7.3.10 GetMethod ( value, propertyKey )
/// https://tc39.es/ecma262/#sec-getmethod
pub fn getMethod(value: Value, agent: *Agent, property_key: PropertyKey) Agent.Error!?*Object {
    // 1. Let func be ? GetV(value, propertyKey).
    const func = try value.get(agent, property_key);

    // 2. If func is either undefined or null, return undefined.
    if (func.isUndefined() or func.isNull()) return null;

    // 3. If IsCallable(func) is false, throw a TypeError exception.
    if (!func.isCallable()) {
        return agent.throwException(.type_error, "{f} is not callable", .{value});
    }

    // 4. Return func.
    return func.asObject();
}

/// 7.3.13 Call ( func, thisValue [ , argList ] )
/// https://tc39.es/ecma262/#sec-call
pub fn call(
    value: Value,
    agent: *Agent,
    this_value: Value,
    arg_list: []const Value,
) Agent.Error!Value {
    // 1. If argList is not present, set argList to a new empty List.

    // 2. If IsCallable(func) is false, throw a TypeError exception.
    if (!value.isCallable()) {
        return agent.throwException(.type_error, "{f} is not callable", .{value});
    }
    const func = value.asObject();

    // 3. Return ? func.[[Call]](thisValue, argList).
    return func.internalMethods().call.?(
        agent,
        func,
        this_value,
        Arguments.from(arg_list),
    );
}

const ValidElementTypes = enum {
    all,
    property_key,
};

/// 7.3.19 CreateListFromArrayLike ( obj [ , validElementTypes ] )
/// https://tc39.es/ecma262/#sec-createlistfromarraylike
pub fn createListFromArrayLike(
    value: Value,
    agent: *Agent,
    maybe_valid_element_types: ?ValidElementTypes,
) Agent.Error![]Value {
    // 1. If validElementTypes is not present, set validElementTypes to all.
    const valid_element_types = maybe_valid_element_types orelse .all;

    // 2. If obj is not an Object, throw a TypeError exception.
    if (!value.isObject()) {
        return agent.throwException(.type_error, "{f} is not an Object", .{value});
    }
    const obj = value.asObject();

    // 3. Let length be ? LengthOfArrayLike(obj).
    const length = try obj.lengthOfArrayLike(agent);

    // 4. Let list be a new empty List.
    if (length > std.math.maxInt(usize)) return error.OutOfMemory;
    var list = try std.ArrayList(Value).initCapacity(agent.gc_allocator, @intCast(length));
    defer list.deinit(agent.gc_allocator);

    // 5. Let index be 0.
    var index: u53 = 0;

    // 6. Repeat, while index < length,
    while (index < length) : (index += 1) {
        // a. Let indexName be ! ToString(𝔽(index)).
        const index_name = PropertyKey.from(index);

        // b. Let next be ? Get(obj, indexName).
        const next = try obj.get(agent, index_name);

        // c. If validElementTypes is property-key and next is not a property key, throw a TypeError
        //    exception.
        if (valid_element_types == .property_key and switch (next.type()) {
            .string, .symbol => false,
            else => true,
        }) {
            return agent.throwException(
                .type_error,
                "Array element {f} must be a string or symbol",
                .{next},
            );
        }

        // d. Append next to list.
        list.appendAssumeCapacity(next);

        // e. Set index to index + 1.
    }

    // 7. Return list.
    return list.toOwnedSlice(agent.gc_allocator);
}

/// 7.3.20 Invoke ( value, propertyKey [ , argList ] )
/// https://tc39.es/ecma262/#sec-invoke
pub fn invoke(
    value: Value,
    agent: *Agent,
    property_key: PropertyKey,
    arg_list: []const Value,
) Agent.Error!Value {
    // 1. If argList is not present, set argList to a new empty List.

    // 2. Let func be ? GetV(value, propertyKey).
    const func = try value.get(agent, property_key);

    // 3. Return ? Call(func, value, argList).
    return func.call(agent, value, arg_list);
}

/// 7.3.21 OrdinaryHasInstance ( ctor, instance )
/// https://tc39.es/ecma262/#sec-ordinaryhasinstance
pub fn ordinaryHasInstance(value: Value, agent: *Agent, instance_value: Value) Agent.Error!bool {
    // 1. If IsCallable(ctor) is false, return false.
    if (!value.isCallable()) return false;
    const ctor = value.asObject();

    // 2. If ctor has a [[BoundTargetFunction]] internal slot, then
    if (ctor.is(builtins.BoundFunction)) {
        // a. Let boundCtor be ctor.[[BoundTargetFunction]].
        const bound_ctor = ctor.as(builtins.BoundFunction).fields.bound_target_function;

        // b. Return ? InstanceofOperator(instance, boundCtor).
        return instance_value.instanceofOperator(agent, from(bound_ctor));
    }

    // 3. If instance is not an Object, return false.
    if (!instance_value.isObject()) return false;
    var instance = instance_value.asObject();

    // 4. Let proto be ? Get(ctor, "prototype").
    const proto = try ctor.get(agent, PropertyKey.from("prototype"));

    // 5. If proto is not an Object, throw a TypeError exception.
    if (!proto.isObject()) {
        return agent.throwException(.type_error, "'prototype' property must be an object", .{});
    }

    // 6. Repeat,
    while (true) {
        // a. Set instance to ? instance.[[GetPrototypeOf]]().
        instance = try instance.internalMethods().getPrototypeOf(agent, instance) orelse {
            // b. If instance is null, return false.
            return false;
        };

        // c. If SameValue(proto, instance) is true, return true.
        if (proto.asObject() == instance) return true;
    }
}

/// 7.3.34 AddValueToKeyedGroup ( groups, key, value )
/// https://tc39.es/ecma262/#sec-add-value-to-keyed-group
fn addValueToKeyedGroup(
    agent: *Agent,
    groups: anytype,
    key: anytype,
    value: Value,
) std.mem.Allocator.Error!void {
    // 1. For each Record { [[Key]], [[Elements]] } group of groups, do
    //     a. If SameValue(group.[[Key]], key) is true, then
    if (groups.getPtr(key)) |group| {
        // i. Assert: Exactly one element of groups meets this criterion.
        // ii. Append value to group.[[Elements]].
        try group.append(agent.gc_allocator, value);

        // iii. Return unused.
    } else {
        // 2. Let group be the Record { [[Key]]: key, [[Elements]]: « value » }.
        // 3. Append group to groups.
        var group: std.ArrayList(Value) = .empty;
        try group.append(agent.gc_allocator, value);
        try groups.putNoClobber(agent.gc_allocator, key, group);

        // 4. Return unused.
    }
}

const KeyCoercion = enum { property, collection };

fn GroupByContainer(comptime key_coercion: KeyCoercion) type {
    return switch (key_coercion) {
        .property => PropertyKey.ArrayHashMap(std.ArrayList(Value)),
        .collection => Value.ArrayHashMap(std.ArrayList(Value), sameValue),
    };
}

/// 7.3.35 GroupBy ( items, callback, keyCoercion )
/// https://tc39.es/ecma262/#sec-groupby
pub fn groupBy(
    self: Value,
    agent: *Agent,
    callback_value: Value,
    comptime key_coercion: KeyCoercion,
) Agent.Error!GroupByContainer(key_coercion) {
    // 1. Perform ? RequireObjectCoercible(items).
    try self.requireObjectCoercible(agent);

    // 2. If IsCallable(callback) is false, throw a TypeError exception.
    if (!callback_value.isCallable()) {
        return agent.throwException(.type_error, "{f} is not callable", .{callback_value});
    }
    const callback = callback_value.asObject();

    // 3. Let groups be a new empty List.
    var groups: GroupByContainer(key_coercion) = .empty;

    // 4. Let iteratorRecord be ? GetIterator(items, sync).
    var iterator = try getIterator(agent, self, .sync);

    // 5. Let k be 0.
    var k: u53 = 0;

    // 6. Repeat,
    while (true) : (k += 1) {
        // a. If k ≥ 2**53 - 1, then
        if (k == std.math.maxInt(u53)) {
            // i. Let error be ThrowCompletion(a newly created TypeError object).
            const @"error" = agent.throwException(
                .type_error,
                "Cannot group more than 2^53-1 items",
                .{},
            );

            // ii. Return ? IteratorClose(iteratorRecord, error).
            return iterator.close(agent, @as(Agent.Error!GroupByContainer(key_coercion), @"error"));
        }

        // b. Let next be ? IteratorStepValue(iteratorRecord).
        const next = try iterator.stepValue(agent);

        // c. If next is done, then
        //     i. Return groups.
        // d. Let value be next.
        const value = next orelse return groups;

        // e. Let key be Completion(Call(callback, undefined, « value, 𝔽(k) »)).
        const key = callback.call(agent, @"undefined", &.{ value, from(k) }) catch |err| {
            // f. IfAbruptCloseIterator(key, iteratorRecord).
            return iterator.close(agent, @as(Agent.Error!GroupByContainer(key_coercion), err));
        };

        // g. If keyCoercion is property, then
        const coerced_key = if (key_coercion == .property) blk: {
            // i. Set key to Completion(ToPropertyKey(key)).
            break :blk key.toPropertyKey(agent) catch |err| {
                // ii. IfAbruptCloseIterator(key, iteratorRecord).
                return iterator.close(agent, @as(Agent.Error!GroupByContainer(key_coercion), err));
            };
        } else blk: {
            // h. Else,
            // i. Assert: keyCoercion is collection.
            std.debug.assert(key_coercion == .collection);

            // ii. Set key to CanonicalizeKeyedCollectionKey(key).
            break :blk key.canonicalizeKeyedCollectionKey();
        };

        // i. Perform AddValueToKeyedGroup(groups, key, value).
        try addValueToKeyedGroup(agent, &groups, coerced_key, value);

        // j. Set k to k + 1.
    }
}

/// 7.3.37 SetterThatIgnoresPrototypeProperties ( thisValue, home, propertyKey, value )
/// https://tc39.es/ecma262/#sec-SetterThatIgnoresPrototypeProperties
pub fn setterThatIgnoresPrototypeProperties(
    self: Value,
    agent: *Agent,
    home: *Object,
    property_key: PropertyKey,
    value: Value,
) Agent.Error!void {
    // 1. If thisValue is not an Object, then
    if (!self.isObject()) {
        // a. Throw a TypeError exception.
        return agent.throwException(.type_error, "{f} is not an Object", .{self});
    }
    const this_value = self.asObject();

    // 2. If SameValue(thisValue, home) is true, then
    if (this_value == home) {
        // a. NOTE: Throwing here emulates assignment to a non-writable data property on the home
        //    object in strict mode code.
        // b. Throw a TypeError exception.
        // TODO: Implement nicer PropertyKey formatting
        return agent.throwException(
            .type_error,
            "Cannot set property '{any}' on object",
            .{property_key},
        );
    }

    // 3. Let propertyDesc be ? thisValue.[[GetOwnProperty]](propertyKey).
    const property_desc = try this_value.internalMethods().getOwnProperty(
        agent,
        this_value,
        property_key,
    );

    // 4. If propertyDesc is undefined, then
    if (property_desc == null) {
        // a. Perform ? CreateDataPropertyOrThrow(thisValue, propertyKey, value).
        try this_value.createDataPropertyOrThrow(agent, property_key, value);
    } else {
        // 5. Else,
        // a. Perform ? Set(thisValue, propertyKey, value, true).
        try this_value.set(agent, property_key, value, .throw);
    }

    // 6. Return unused.
}

/// 9.13 CanBeHeldWeakly ( arg )
/// https://tc39.es/ecma262/#sec-canbeheldweakly
pub fn canBeHeldWeakly(arg: Value, agent: *Agent) bool {
    // 1. If arg is an Object, return true.
    if (arg.isObject()) return true;

    // 2. If arg is a Symbol and KeyForSymbol(arg) is undefined, return true.
    if (arg.isSymbol() and keyForSymbol(agent, arg.asSymbol()) == null) return true;

    // 3. Return false.
    return false;
}

/// 10.1.15 RequireInternalSlot ( obj, internalSlot )
/// https://tc39.es/ecma262/#sec-requireinternalslot
pub fn requireInternalSlot(
    obj: Value,
    agent: *Agent,
    comptime T: type,
) error{ExceptionThrown}!*T {
    // 1. If obj is not an Object, throw a TypeError exception.
    if (!obj.isObject()) {
        return agent.throwException(.type_error, "{f} is not an Object", .{obj});
    }

    // 2. If obj does not have an internalSlot internal slot, throw a TypeError exception.
    if (!obj.asObject().is(T)) {
        return agent.throwException(.type_error, "{f} is not a {s} object", .{ obj, T.display_name });
    }

    // 3. Return unused.
    // NOTE: Returning the object here allows for direct assignment of the object at the call site.
    return obj.asObject().as(T);
}

/// 13.10.2 InstanceofOperator ( value, target )
/// https://tc39.es/ecma262/#sec-instanceofoperator
pub fn instanceofOperator(value: Value, agent: *Agent, target: Value) Agent.Error!bool {
    // 1. If target is not an Object, throw a TypeError exception.
    if (!target.isObject()) {
        return agent.throwException(
            .type_error,
            "Right-hand side of 'instanceof' operator must be an object",
            .{},
        );
    }

    // 2. Let instOfHandler be ? GetMethod(target, %Symbol.hasInstance%).
    const maybe_instanceof_handler = try target.getMethod(
        agent,
        PropertyKey.from(agent.well_known_symbols.has_instance),
    );

    // 3. If instOfHandler is not undefined, then
    if (maybe_instanceof_handler) |instanceof_handler| {
        // a. Return ToBoolean(? Call(instOfHandler, target, « value »)).
        return (try from(instanceof_handler).call(agent, target, &.{value})).toBoolean();
    }

    // 4. If IsCallable(target) is false, throw a TypeError exception.
    if (!target.isCallable()) {
        return agent.throwException(.type_error, "{f} is not callable", .{target});
    }

    // 5. Return ? OrdinaryHasInstance(target, value).
    return target.ordinaryHasInstance(agent, value);
}

/// 24.5.1 CanonicalizeKeyedCollectionKey ( key )
/// https://tc39.es/ecma262/#sec-canonicalizekeyedcollectionkey
pub fn canonicalizeKeyedCollectionKey(key: Value) Value {
    // 1. If key is -0𝔽, return +0𝔽.
    if (key.isNumber() and key.asNumber().isNegativeZero()) return from(0);

    // 2. Return key.
    return key;
}

/// 27.5.1.6 IsPromise ( arg )
/// https://tc39.es/ecma262/#sec-ispromise
pub fn isPromise(arg: Value) bool {
    // 1. If arg is not an Object, return false.
    if (!arg.isObject()) return false;

    // 2. If arg does not have a [[PromiseState]] internal slot, return false.
    if (!arg.asObject().is(builtins.Promise)) return false;

    // 3. Return true.
    return true;
}

/// Non-standard helper to get the right prototype for a primitive value, if applicable.
pub fn synthesizePrototype(self: Value, agent: *Agent) std.mem.Allocator.Error!?*Object {
    const realm = agent.currentRealm();

    return switch (self.type()) {
        .null, .undefined => null,
        .boolean => try realm.intrinsic(.boolean_prototype),
        .string => try realm.intrinsic(.string_prototype),
        .symbol => try realm.intrinsic(.symbol_prototype),
        .number => try realm.intrinsic(.number_prototype),
        .big_int => try realm.intrinsic(.big_int_prototype),
        .object => null,
    };
}

/// Non-standard helper to turn a symbol value into a private name.
pub fn toPrivateName(self: Value) ?PrivateName {
    if (!self.isSymbol() or !self.asSymbol().is_private) return null;
    return .{ .symbol = self.asSymbol() };
}

/// 7.1.4.1.1 StringToNumber ( string )
/// https://tc39.es/ecma262/#sec-stringtonumber
pub fn stringToNumber(
    agent: *Agent,
    string: *const String,
) std.mem.Allocator.Error!Number {
    // 1. Let literal be ParseText(string, StringNumericLiteral).
    // 2. If literal is a List of errors, return NaN.
    // 3. Return the StringNumericValue of literal.
    const gpa = agent.gpa;
    const trimmed_string = try (try string.trim(agent)).toUtf8(gpa);
    defer gpa.free(trimmed_string);
    if (trimmed_string.len == 0) return Number.from(0);
    if (std.mem.eql(u8, trimmed_string, "-Infinity")) return Number.from(-std.math.inf(f64));
    if (std.mem.eql(u8, trimmed_string, "+Infinity")) return Number.from(std.math.inf(f64));
    if (std.mem.eql(u8, trimmed_string, "Infinity")) return Number.from(std.math.inf(f64));
    // Ensure we don't pass things that `std.fmt.parse{Float,Int}()` would understand:
    // - "inf"
    // - signed numbers with base prefixes
    // - floats with base prefixes
    // - numbers with underscore separators
    if (std.ascii.startsWithIgnoreCase(trimmed_string, "inf") or
        ((std.ascii.startsWithIgnoreCase(trimmed_string, "0b") or
            std.ascii.startsWithIgnoreCase(trimmed_string, "0o") or
            std.ascii.startsWithIgnoreCase(trimmed_string, "0x")) and
            (std.mem.findScalar(u8, trimmed_string, '.') != null or
                std.mem.findAny(u8, trimmed_string, "pP") != null)) or
        (std.mem.findAny(u8, trimmed_string, "+-") == 0 and
            (std.ascii.startsWithIgnoreCase(trimmed_string[1..], "0b") or
                std.ascii.startsWithIgnoreCase(trimmed_string[1..], "0o") or
                std.ascii.startsWithIgnoreCase(trimmed_string[1..], "0x"))) or
        std.mem.findScalar(u8, trimmed_string, '_') != null)
    {
        return Number.from(std.math.nan(f64));
    }
    if (std.fmt.parseFloat(f64, trimmed_string)) |float|
        return Number.from(float)
    else |_| if (std.fmt.parseInt(i32, trimmed_string, 0)) |int|
        return Number.from(int)
    else |_|
        return Number.from(std.math.nan(f64));
}

/// 7.1.16 StringToBigInt ( string )
/// https://tc39.es/ecma262/#sec-stringtobigint
pub fn stringToBigInt(
    agent: *Agent,
    string: *const String,
) std.mem.Allocator.Error!?*const BigInt {
    // 1. Let literal be ParseText(string, StringIntegerLiteral).
    // 2. If literal is a List of errors, return undefined.
    // 3. Let mv be the MV of literal.
    // 4. Assert: mv is an integer.
    // 5. Return ℤ(mv).
    // TODO: Implement the proper string parsing grammar!
    const gpa = agent.gpa;
    const trimmed_string = try (try string.trim(agent)).toUtf8(gpa);
    defer gpa.free(trimmed_string);
    if (trimmed_string.len == 0) return .zero;
    // Unlike std.fmt.parseFloat() and std.fmt.parseInt() with base 0, std.math.big.int.Managed.setString()
    // doesn't like the prefix so we have to cut it off manually.
    const base: u8, const value = if (std.ascii.startsWithIgnoreCase(trimmed_string, "0b")) blk: {
        const value = trimmed_string[2..];
        if (value.len == 0) return null;
        break :blk .{ 2, value };
    } else if (std.ascii.startsWithIgnoreCase(trimmed_string, "0o")) blk: {
        const value = trimmed_string[2..];
        if (value.len == 0) return null;
        break :blk .{ 8, value };
    } else if (std.ascii.startsWithIgnoreCase(trimmed_string, "0x")) blk: {
        const value = trimmed_string[2..];
        if (value.len == 0) return null;
        break :blk .{ 16, value };
    } else blk: {
        break :blk .{ 10, trimmed_string };
    };
    return BigInt.fromString(agent, base, value) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        error.InvalidCharacter => return null,
        error.InvalidBase => unreachable,
    };
}

/// 7.2.8 SameType ( x, y )
/// https://tc39.es/ecma262/#sec-sametype
pub fn sameType(x: Value, y: Value) bool {
    // 1. If x is undefined and y is undefined, return true.
    // 2. If x is null and y is null, return true.
    // 3. If x is a Boolean and y is a Boolean, return true.
    // 4. If x is a Number and y is a Number, return true.
    // 5. If x is a BigInt and y is a BigInt, return true.
    // 6. If x is a Symbol and y is a Symbol, return true.
    // 7. If x is a String and y is a String, return true.
    // 8. If x is an Object and y is an Object, return true.
    // 9. Return false.
    switch (Impl) {
        NanBoxingImpl => {
            const x_tag = x.impl.getTag();
            const y_tag = y.impl.getTag();
            return x_tag == y_tag or
                (x_tag == .number_i32 and y_tag == .number_f64) or
                (x_tag == .number_f64 and y_tag == .number_i32);
        },
        TaggedUnionImpl => {
            const x_tag = std.meta.activeTag(x.impl);
            const y_tag = std.meta.activeTag(y.impl);
            return x_tag == y_tag or
                (x_tag == .number_i32 and y_tag == .number_f64) or
                (x_tag == .number_f64 and y_tag == .number_i32);
        },
        else => comptime unreachable,
    }
}

/// 7.2.9 SameValue ( x, y )
/// https://tc39.es/ecma262/#sec-samevalue
pub fn sameValue(x: Value, y: Value) bool {
    // 1. If SameType(x, y) is false, return false.
    if (!sameType(x, y)) return false;

    // 2. If x is a Number, then
    if (x.isNumber()) {
        // a. Return Number::sameValue(x, y).
        return x.asNumber().sameValue(y.asNumber());
    }

    // 3. Return SameValueNonNumber(x, y).
    return sameValueNonNumber(x, y);
}

/// 7.2.10 SameValueZero ( x, y )
/// https://tc39.es/ecma262/#sec-samevaluezero
pub fn sameValueZero(x: Value, y: Value) bool {
    // 1. If SameType(x, y) is false, return false.
    if (!sameType(x, y)) return false;

    // 2. If x is a Number, then
    if (x.isNumber()) {
        // a. Return Number::sameValueZero(x, y).
        return x.asNumber().sameValueZero(y.asNumber());
    }

    // 3. Return SameValueNonNumber(x, y).
    return sameValueNonNumber(x, y);
}

/// 7.2.11 SameValueNonNumber ( x, y )
/// https://tc39.es/ecma262/#sec-samevaluenonnumber
pub fn sameValueNonNumber(x: Value, y: Value) bool {
    // 1. Assert: SameType(x, y) is true.
    std.debug.assert(sameType(x, y));

    return switch (x.type()) {
        // 2. If x is either undefined or null, return true.
        .undefined, .null => true,

        // 3. If x is a BigInt, then
        //     a. Return BigInt::equal(x, y).
        .big_int => x.asBigInt().equal(y.asBigInt()),

        // 4. If x is a String, then
        //     a. If x and y have the same length and the same code units in the same positions,
        //        return true.
        //     b. Return false.
        .string => x.asString().eql(y.asString()),

        // 5. If x is a Boolean, then
        //     a. If x is true and y is true, return true.
        //     b. If x is false and y is false, return true.
        //     c. Return false.
        .boolean => x.asBoolean() == y.asBoolean(),

        // 6. NOTE: All other ECMAScript language values are compared by identity.
        // 7. If x is y, return true.
        // 8. Return false.
        .symbol => x.asSymbol() == y.asSymbol(),
        .object => x.asObject() == y.asObject(),

        .number => unreachable,
    };
}

/// 7.2.12 IsLessThan ( x, y, leftFirst )
/// https://tc39.es/ecma262/#sec-islessthan
pub fn isLessThan(
    agent: *Agent,
    x: Value,
    y: Value,
    order: enum { left_first, right_first },
) Agent.Error!?bool {
    var px: Value = undefined;
    var py: Value = undefined;

    // 1. If leftFirst is true, then
    if (order == .left_first) {
        // a. Let px be ? ToPrimitive(x, number).
        px = try x.toPrimitive(agent, .number);

        // b. Let py be ? ToPrimitive(y, number).
        py = try y.toPrimitive(agent, .number);
    } else {
        // 2. Else,
        // a. NOTE: The order of evaluation needs to be reversed to preserve left to right
        //    evaluation.

        // b. Let py be ? ToPrimitive(y, number).
        py = try y.toPrimitive(agent, .number);

        // c. Let px be ? ToPrimitive(x, number).
        px = try x.toPrimitive(agent, .number);
    }

    // 3. If px is a String and py is a String, then
    if (px.isString() and py.isString()) {
        // a. Let lx be the length of px.
        const lx = px.asString().length;

        // b. Let ly be the length of py.
        const ly = py.asString().length;

        // c. For each integer i such that 0 ≤ i < min(lx, ly), in ascending order, do
        for (0..@min(lx, ly)) |i| {
            // i. Let cx be the numeric value of the code unit at index i within px.
            const cx = px.asString().codeUnitAt(@intCast(i));

            // ii. Let cy be the numeric value of the code unit at index i within py.
            const cy = py.asString().codeUnitAt(@intCast(i));

            // iii. If cx < cy, return true.
            if (cx < cy) return true;

            // iv. If cx > cy, return false.
            if (cx > cy) return false;
        }

        // d. If lx < ly, return true.
        if (lx < ly) return true;

        // e. Return false.
        return false;
    }

    // 4. If px is a BigInt and py is a String, then
    if (px.isBigInt() and py.isString()) {
        // a. Let ny be StringToBigInt(py).
        // b. If ny is undefined, return undefined.
        const ny = try stringToBigInt(agent, py.asString()) orelse return null;

        // c. Return BigInt::lessThan(px, ny).
        return px.asBigInt().lessThan(ny);
    }

    // 5. If px is a String and py is a BigInt, then
    if (px.isString() and py.isBigInt()) {
        // a. Let nx be StringToBigInt(px).
        // b. If nx is undefined, return undefined.
        const nx = try stringToBigInt(agent, px.asString()) orelse return null;

        // c. Return BigInt::lessThan(nx, py).
        return nx.lessThan(py.asBigInt());
    }

    // 6. NOTE: Because px and py are primitive values, evaluation order is not important.

    // 7. Let nx be ? ToNumeric(px).
    const nx = try px.toNumeric(agent);

    // 8. Let ny be ? ToNumeric(py).
    const ny = try py.toNumeric(agent);

    // 9. If SameType(nx, ny) is true, then
    if (Numeric.sameType(nx, ny)) {
        // a. If nx is a Number, return Number::lessThan(nx, ny).
        if (nx == .number) {
            return nx.number.lessThan(ny.number);
        }

        // b. Assert: nx is a BigInt.
        std.debug.assert(nx == .big_int);

        // c. Return BigInt::lessThan(nx, ny).
        return nx.big_int.lessThan(ny.big_int);
    }

    // 10. Assert: nx is a BigInt and ny is a Number, or nx is a Number and ny is a BigInt.
    std.debug.assert((nx == .big_int and ny == .number) or (nx == .number and ny == .big_int));

    // 11. If nx is NaN or ny is NaN, return undefined.
    if ((nx == .number and nx.number.isNan()) or
        (ny == .number and ny.number.isNan())) return null;

    // 12. If nx is -∞𝔽 or ny is +∞𝔽, return true.
    if ((nx == .number and nx.number.isNegativeInf()) or
        (ny == .number and ny.number.isPositiveInf())) return true;

    // 13. If nx is +∞𝔽 or ny is -∞𝔽, return false.
    if ((nx == .number and nx.number.isPositiveInf()) or
        (ny == .number and ny.number.isNegativeInf())) return false;

    // 14. If ℝ(nx) < ℝ(ny), return true.
    // 15. Return false.
    const gpa = agent.gpa;
    return switch (nx) {
        .number => (try ny.big_int.orderWithFloat(gpa, nx.number.asFloat(), .floor)) == .gt,
        .big_int => (try nx.big_int.orderWithFloat(gpa, ny.number.asFloat(), .ceil)) == .lt,
    };
}

/// 7.2.13 IsLooselyEqual ( x, y )
/// https://tc39.es/ecma262/#sec-islooselyequal
pub fn isLooselyEqual(agent: *Agent, x: Value, y: Value) Agent.Error!bool {
    // 1. If SameType(x, y) is true, then
    if (sameType(x, y)) {
        // a. Return IsStrictlyEqual(x, y).
        return isStrictlyEqual(x, y);
    }

    // 2. If x is null and y is undefined, return true.
    if (x.isNull() and y.isUndefined()) return true;

    // 3. If x is undefined and y is null, return true.
    if (x.isUndefined() and y.isNull()) return true;

    // 4. If the host is a web browser or otherwise supports The [[IsHTMLDDA]] Internal Slot, then
    if (build_options.enable_annex_b) {
        // a. If x is an Object, x has an [[IsHTMLDDA]] internal slot, and y is either undefined or
        //    null, return true.
        if (x.isObject() and x.asObject().isHTMLDDA() and (y.isUndefined() or y.isNull())) return true;

        // b. If x is either undefined or null, y is an Object, and y has an [[IsHTMLDDA]] internal
        //    slot, return true.
        if ((x.isUndefined() or x.isNull()) and y.isObject() and y.asObject().isHTMLDDA()) return true;
    }

    // 5. If x is a Number and y is a String, return ! IsLooselyEqual(x, ! ToNumber(y)).
    if (x.isNumber() and y.isString()) {
        return isLooselyEqual(
            agent,
            x,
            from(y.toNumber(agent) catch unreachable),
        ) catch unreachable;
    }

    // 6. If x is a String and y is a Number, return ! IsLooselyEqual(! ToNumber(x), y).
    if (x.isString() and y.isNumber()) {
        return isLooselyEqual(
            agent,
            from(x.toNumber(agent) catch unreachable),
            y,
        ) catch unreachable;
    }

    // 7. If x is a BigInt and y is a String, then
    if (x.isBigInt() and y.isString()) {
        // a. Let n be StringToBigInt(y).
        const n = try stringToBigInt(agent, y.asString()) orelse {
            // b. If n is undefined, return false.
            return false;
        };

        // c. Return ! IsLooselyEqual(x, n).
        return isLooselyEqual(agent, x, from(n));
    }

    // 8. If x is a String and y is a BigInt, return ! IsLooselyEqual(y, x).
    if (x.isString() and y.isBigInt()) return isLooselyEqual(agent, y, x) catch unreachable;

    // 9. If x is a Boolean, return ! IsLooselyEqual(! ToNumber(x), y).
    if (x.isBoolean()) {
        return isLooselyEqual(
            agent,
            from(x.toNumber(agent) catch unreachable),
            y,
        ) catch unreachable;
    }

    // 10. If y is a Boolean, return ! IsLooselyEqual(x, ! ToNumber(y)).
    if (y.isBoolean()) {
        return isLooselyEqual(
            agent,
            x,
            from(y.toNumber(agent) catch unreachable),
        ) catch unreachable;
    }

    // 11. If x is either a String, a Number, a BigInt, or a Symbol and y is an Object, return
    //     ! IsLooselyEqual(x, ? ToPrimitive(y)).
    if ((x.isString() or x.isNumber() or x.isBigInt() or x.isSymbol()) and y.isObject()) {
        return isLooselyEqual(agent, x, try y.toPrimitive(agent, null)) catch unreachable;
    }

    // 12. If x is an Object and y is either a String, a Number, a BigInt, or a Symbol, return
    //     ! IsLooselyEqual(? ToPrimitive(x), y).
    if (x.isObject() and (y.isString() or y.isNumber() or y.isBigInt() or y.isSymbol())) {
        return isLooselyEqual(agent, try x.toPrimitive(agent, null), y) catch unreachable;
    }

    // 13. If x is a BigInt and y is a Number, or if x is a Number and y is a BigInt, then
    if ((x.isBigInt() and y.isNumber()) or (x.isNumber() and y.isBigInt())) {
        const gpa = agent.gpa;
        const number = if (x.isNumber()) x.asNumber() else y.asNumber();
        const big_int = if (x.isBigInt()) x.asBigInt() else y.asBigInt();

        // a. If x is not finite or y is not finite, return false.
        // b. If ℝ(x) = ℝ(y), return true.
        // c. Return false.
        if (!number.isIntegral()) return false;
        return (try big_int.orderWithFloat(gpa, number.asFloat(), .nearest_even)) == .eq;
    }

    // 14. Return false.
    return false;
}

/// 7.2.14 IsStrictlyEqual ( x, y )
/// https://tc39.es/ecma262/#sec-isstrictlyequal
pub fn isStrictlyEqual(x: Value, y: Value) bool {
    // 1. If SameType(x, y) is false, return false.
    if (!sameType(x, y)) return false;

    // 2. If x is a Number, then
    if (x.isNumber()) {
        // a. Return Number::equal(x, y).
        return x.asNumber().equal(y.asNumber());
    }

    // 3. Return SameValueNonNumber(x, y).
    return sameValueNonNumber(x, y);
}

/// 7.3.17 CreateArrayFromList ( elements )
/// https://tc39.es/ecma262/#sec-createarrayfromlist
pub fn createArrayFromList(
    agent: *Agent,
    elements: []const Value,
) std.mem.Allocator.Error!*builtins.Array {
    // OPTIMIZATION: We set the right length upfront and set properties directly below to bypass
    //               Array's defineOwnProperty() which does a lot of extra work.

    // 1. Let array be ! ArrayCreate(0).
    const array = arrayCreate(agent, @intCast(elements.len), null) catch |err| try noexcept(err);
    const indexed_properties = try array.object.ensureIndexedProperties(agent.gc_allocator);

    // 2. Let n be 0.
    // 3. For each element element of elements, do
    for (elements, 0..) |element, n| {
        // a. Perform ! CreateDataPropertyOrThrow(array, ! ToString(𝔽(n)), element).
        // NOTE: This could use createDataPropertyDirect() but since we created the array with the
        //       right length upfront directly setting indexed properties is faster.
        try indexed_properties.set(agent.gc_allocator, @intCast(n), .{
            .value_or_accessor = .{
                .value = element,
            },
            .attributes = .all,
        });

        // b. Set n to n + 1.
    }

    // 4. Return array.
    return array;
}

pub fn createArrayFromListMapToValue(
    agent: *Agent,
    comptime T: type,
    elements: []const T,
    mapFn: fn (*Agent, T) std.mem.Allocator.Error!Value,
) std.mem.Allocator.Error!*builtins.Array {
    // OPTIMIZATION: We set the right length upfront and set properties directly below to bypass
    //               Array's defineOwnProperty() which does a lot of extra work.

    // 1. Let array be ! ArrayCreate(0).
    const array = arrayCreate(agent, @intCast(elements.len), null) catch |err| try noexcept(err);
    const indexed_properties = try array.object.ensureIndexedProperties(agent.gc_allocator);

    // 2. Let n be 0.
    // 3. For each element e of elements, do
    for (elements, 0..) |element, n| {
        // a. Perform ! CreateDataPropertyOrThrow(array, ! ToString(𝔽(n)), e).
        // NOTE: This could use createDataPropertyDirect() but since we created the array with the
        //       right length upfront directly setting indexed properties is faster.
        try indexed_properties.set(agent.gc_allocator, @intCast(n), .{
            .value_or_accessor = .{
                .value = try mapFn(agent, element),
            },
            .attributes = .all,
        });

        // b. Set n to n + 1.
    }

    // 4. Return array.
    return array;
}

/// 7.3.36 GetOptionsObject ( options )
/// https://tc39.es/ecma262/#sec-getoptionsobject
pub fn getOptionsObject(self: Value, agent: *Agent) Agent.Error!*Object {
    // 1. If options is undefined, then
    if (self.isUndefined()) {
        // a. Return OrdinaryObjectCreate(null).
        return ordinaryObjectCreate(agent, null);
    }

    // 2. If options is an Object, then
    if (self.isObject()) {
        // a. Return options.
        return self.asObject();
    }

    // 3. Throw a TypeError exception.
    return agent.throwException(
        .type_error,
        "Options must either be an object or undefined",
        .{},
    );
}

/// 9.2.10 CoerceOptionsToObject ( options )
/// https://tc39.es/ecma402/#sec-coerceoptionstoobject
pub fn coerceOptionsToObject(self: Value, agent: *Agent) Agent.Error!*Object {
    // 1. If options is undefined, then
    if (self.isUndefined()) {
        // a. Return OrdinaryObjectCreate(null).
        return ordinaryObjectCreate(agent, null);
    }

    // 2. Return ? ToObject(options).
    return self.toObject(agent);
}

/// 13.39 ToPositiveIntegerWithTruncation ( argument )
/// https://tc39.es/proposal-temporal/#sec-topositiveintegerwithtruncation
pub fn toPositiveIntegerWithTruncation(self: Value, agent: *Agent) Agent.Error!f64 {
    // 1. Let integer be ? ToIntegerWithTruncation(argument).
    const integer = try self.toIntegerWithTruncation(agent);

    // 2. If integer ≤ 0, throw a RangeError exception.
    if (integer <= 0) {
        return agent.throwException(.range_error, "{f} is not a positive number", .{self});
    }

    // 3. Return integer.
    return integer;
}

/// 13.40 ToIntegerWithTruncation ( argument )
/// https://tc39.es/proposal-temporal/#sec-tointegerwithtruncation
pub fn toIntegerWithTruncation(self: Value, agent: *Agent) Agent.Error!f64 {
    // 1. Let number be ? ToNumber(argument).
    const number = try self.toNumber(agent);

    // 2. If number is one of NaN, +∞𝔽, or -∞𝔽, throw a RangeError exception.
    if (!number.isFinite()) {
        return agent.throwException(.range_error, "{f} is not a finite number", .{self});
    }

    // 3. Return truncate(ℝ(number)).
    return number.truncate().asFloat();
}

/// 14.5.1.1 ToIntegerIfIntegral ( argument )
/// https://tc39.es/proposal-temporal/#sec-tointegerifintegral
pub fn toIntegerIfIntegral(self: Value, agent: *Agent) Agent.Error!f64 {
    // 1. Let number be ? ToNumber(argument).
    const number = try self.toNumber(agent);

    // 2. If number is not an integral Number, throw a RangeError exception.
    if (!number.isIntegral()) {
        return agent.throwException(.range_error, "{f} is not an integral number", .{self});
    }

    // 3. Return ℝ(number).
    return number.asFloat();
}

pub fn hash(value: Value) u32 {
    const value_hash = switch (value.type()) {
        .undefined, .null => 0,
        .boolean => std.array_hash_map.getAutoHashFn(bool, void)({}, value.asBoolean()),
        .string => @as(u32, @truncate(value.asString().hash)),
        .symbol => std.array_hash_map.getAutoHashStratFn(*const Symbol, void, .Shallow)({}, value.asSymbol()),
        .number => switch (value.asNumber()) {
            .i32 => |n| std.array_hash_map.getAutoHashFn(i32, void)({}, n),
            .f64 => |n| std.array_hash_map.getAutoHashFn(i64, void)({}, @bitCast(n)),
        },
        .big_int => std.array_hash_map.getAutoHashStratFn(*const BigInt, void, .Shallow)({}, value.asBigInt()),
        .object => std.array_hash_map.getAutoHashStratFn(*Object, void, .Shallow)({}, value.asObject()),
    };
    const tag: u32 = @backingInt(value.type());
    return tag ^ value_hash;
}

pub fn ArrayHashMap(comptime V: type, comptime eqlFn: fn (Value, Value) bool) type {
    return std.array_hash_map.Custom(Value, V, struct {
        pub fn hash(_: @This(), key: Value) u32 {
            return key.hash();
        }

        pub fn eql(_: @This(), a: Value, b: Value, _: usize) bool {
            return eqlFn(a, b);
        }
    }, false);
}

test format {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var environ_map = try std.process.Environ.createMap(.empty, gpa);
    defer environ_map.deinit();
    const platform: Agent.Platform = .default(io, &environ_map);
    defer platform.deinit();
    var agent = try Agent.init(gpa, io, &platform, .{});
    defer agent.deinit();
    const symbol_without_description: Symbol = .{ .description = null };
    const symbol_with_description: Symbol = .{ .description = String.fromLiteral("foo") };
    const big_int = BigInt.fromLiteral(123);
    const object = try ordinaryObjectCreate(&agent, null);
    const test_cases = [_]struct { Value, []const u8 }{
        .{ @"undefined", "undefined" },
        .{ @"null", "null" },
        .{ from(true), "true" },
        .{ from(false), "false" },
        .{ from("foo"), "\"foo\"" },
        .{ from(&symbol_without_description), "Symbol()" },
        .{ from(&symbol_with_description), "Symbol(\"foo\")" },
        .{ from(big_int), "123n" },
        .{ from(object), "[object Object]" },
    };
    for (test_cases) |test_case| {
        const value, const expected = test_case;
        try std.testing.expectFmt(expected, "{f}", .{value});
    }
}

test uninitialized {
    const value: Value = .uninitialized;
    try std.testing.expect(value.isUninitialized());
}

test @"undefined" {
    const value: Value = .undefined;
    try std.testing.expect(value.isUndefined());
}

test @"null" {
    const value: Value = .null;
    try std.testing.expect(value.isNull());
}

test @"true" {
    const value: Value = .true;
    try std.testing.expect(value.isBoolean());
    try std.testing.expectEqual(value.asBoolean(), true);
}

test @"false" {
    const value: Value = .false;
    try std.testing.expect(value.isBoolean());
    try std.testing.expectEqual(value.asBoolean(), false);
}

test nan {
    const value: Value = .nan;
    try std.testing.expect(value.isNumber());
    try std.testing.expect(value.asNumber().isNan());
}

test infinity {
    const value: Value = .infinity;
    try std.testing.expect(value.isNumber());
    try std.testing.expect(value.asNumber().isPositiveInf());
}

test negative_infinity {
    const value: Value = .negative_infinity;
    try std.testing.expect(value.isNumber());
    try std.testing.expect(value.asNumber().isNegativeInf());
}

test from {
    {
        const value = Value.from(true);
        try std.testing.expect(value.isBoolean());
        try std.testing.expectEqual(value.asBoolean(), true);
    }
    {
        const value = Value.from(false);
        try std.testing.expect(value.isBoolean());
        try std.testing.expectEqual(value.asBoolean(), false);
    }
    {
        const value = Value.from("foo");
        try std.testing.expect(value.isString());
        try std.testing.expectEqual(value.asString().asAscii(), "foo");
    }
    {
        const value = Value.from(123.456);
        try std.testing.expect(value.isNumber());
        try std.testing.expectEqual(value.asNumber().f64, 123.456);
    }
    {
        const value = Value.from(123);
        try std.testing.expect(value.isNumber());
        try std.testing.expectEqual(value.asNumber().i32, 123);
    }
    {
        const value = Value.from(std.math.inf(f64));
        try std.testing.expect(value.isNumber());
        try std.testing.expectEqual(value.asNumber().f64, std.math.inf(f64));
    }
    {
        const value = Value.from(std.math.nan(f64));
        try std.testing.expect(value.isNumber());
        try std.testing.expect(value.asNumber().isNan());
    }
    {
        const symbol = Symbol.initComptime(null);
        const value = Value.from(symbol);
        try std.testing.expect(value.isSymbol());
        try std.testing.expectEqual(value.asSymbol(), symbol);
    }
    {
        const big_int = BigInt.fromLiteral(123);
        const value = Value.from(big_int);
        try std.testing.expect(value.isBigInt());
        try std.testing.expectEqual(value.asBigInt(), big_int);
    }
    {
        const object: *Object = @ptrFromInt(0x8000);
        const value = Value.from(object);
        try std.testing.expect(value.isObject());
        try std.testing.expectEqual(value.asObject(), object);
    }
}
