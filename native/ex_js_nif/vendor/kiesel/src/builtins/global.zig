//! 19 The Global Object
//! https://tc39.es/ecma262/#sec-global-object

const std = @import("std");

const build_options = @import("build-options");
const builtins = @import("../builtins.zig");
const execution = @import("../execution.zig");
const types = @import("../types.zig");
const utils = @import("../utils.zig");

const Agent = execution.Agent;
const Arguments = types.Arguments;
const Object = types.Object;
const PropertyDescriptor = types.PropertyDescriptor;
const Realm = execution.Realm;
const String = types.String;
const Value = types.Value;
const createBuiltinFunction = builtins.createBuiltinFunction;
const parseDigits = utils.parseDigits;
const performEval = builtins.performEval;

const module = @This();

const GlobalObjectProperty = struct {
    []const u8,
    union(enum) {
        property_descriptor: PropertyDescriptor,
        lazy_property: Object.LazyProperty.Initializer,
    },
};

fn LazyIntrinsicInitializer(
    comptime field: Realm.Intrinsic,
) Object.LazyProperty.Initializer {
    return .{
        .value = struct {
            fn initializer(_: *Agent, realm: *Realm) std.mem.Allocator.Error!Value {
                return Value.from(try realm.intrinsic(field));
            }
        }.initializer,
    };
}

const num_properties = 62 +
    (if (build_options.enable_annex_b) 2 else 0) +
    (if (build_options.enable_intl) 1 else 0) +
    (if (build_options.enable_temporal) 1 else 0);

pub fn globalObjectProperties(realm: *Realm) [num_properties]GlobalObjectProperty {
    // NOTE: For the sake of compactness we're breaking the line length recommendations here.
    return [_]GlobalObjectProperty{
        // 19.1.1 globalThis
        // https://tc39.es/ecma262/#sec-globalthis
        .{ "globalThis", .{ .property_descriptor = .{ .value = Value.from(realm.global_env.global_this_value), .writable = true, .enumerable = false, .configurable = true } } },

        // 19.1.2 Infinity
        // https://tc39.es/ecma262/#sec-value-properties-of-the-global-object-infinity
        .{ "Infinity", .{ .property_descriptor = .{ .value = .infinity, .writable = false, .enumerable = false, .configurable = false } } },

        // 19.1.3 NaN
        // https://tc39.es/ecma262/#sec-value-properties-of-the-global-object-nan
        .{ "NaN", .{ .property_descriptor = .{ .value = .nan, .writable = false, .enumerable = false, .configurable = false } } },

        // 19.1.4 undefined
        // https://tc39.es/ecma262/#sec-undefined
        .{ "undefined", .{ .property_descriptor = .{ .value = .undefined, .writable = false, .enumerable = false, .configurable = false } } },

        // 19.2.1 eval ( source )
        // https://tc39.es/ecma262/#sec-eval-x
        .{ "eval", .{ .lazy_property = LazyIntrinsicInitializer(.eval) } },

        // 19.2.2 isFinite ( value )
        // https://tc39.es/ecma262/#sec-isfinite-number
        .{ "isFinite", .{ .lazy_property = LazyIntrinsicInitializer(.is_finite) } },

        // 19.2.3 isNaN ( value )
        // https://tc39.es/ecma262/#sec-isnan-number
        .{ "isNaN", .{ .lazy_property = LazyIntrinsicInitializer(.is_nan) } },

        // 19.2.4 parseFloat ( string )
        // https://tc39.es/ecma262/#sec-parsefloat-string
        .{ "parseFloat", .{ .lazy_property = LazyIntrinsicInitializer(.parse_float) } },

        // 19.2.5 parseInt ( string, radix )
        // https://tc39.es/ecma262/#sec-parseint-string-radix
        .{ "parseInt", .{ .lazy_property = LazyIntrinsicInitializer(.parse_int) } },

        // 19.2.6.1 decodeURI ( encodedURI )
        // https://tc39.es/ecma262/#sec-decodeuri-encodeduri
        .{ "decodeURI", .{ .lazy_property = LazyIntrinsicInitializer(.decode_uri) } },

        // 19.2.6.2 decodeURIComponent ( encodedURIComponent )
        // https://tc39.es/ecma262/#sec-decodeuricomponent-encodeduricomponent
        .{ "decodeURIComponent", .{ .lazy_property = LazyIntrinsicInitializer(.decode_uri_component) } },

        // 19.2.6.3 encodeURI ( uri )
        // https://tc39.es/ecma262/#sec-encodeuri-uri
        .{ "encodeURI", .{ .lazy_property = LazyIntrinsicInitializer(.encode_uri) } },

        // 19.2.6.4 encodeURIComponent ( uriComponent )
        // https://tc39.es/ecma262/#sec-encodeuricomponent-uricomponent
        .{ "encodeURIComponent", .{ .lazy_property = LazyIntrinsicInitializer(.encode_uri_component) } },

        // 19.3.1 AggregateError ( . . . )
        // https://tc39.es/ecma262/#sec-constructor-properties-of-the-global-object-aggregate-error
        .{ "AggregateError", .{ .lazy_property = LazyIntrinsicInitializer(.aggregate_error) } },

        // 19.3.2 Array ( . . . )
        // https://tc39.es/ecma262/#sec-constructor-properties-of-the-global-object-array
        .{ "Array", .{ .lazy_property = LazyIntrinsicInitializer(.array) } },

        // 19.3.3 ArrayBuffer ( . . . )
        // https://tc39.es/ecma262/#sec-constructor-properties-of-the-global-object-arraybuffer
        .{ "ArrayBuffer", .{ .lazy_property = LazyIntrinsicInitializer(.array_buffer) } },

        // 19.3.4 AsyncDisposableStack ( . . . )
        // https://tc39.es/ecma262/#sec-constructor-properties-of-the-global-object-asyncdisposablestack
        .{ "AsyncDisposableStack", .{ .lazy_property = LazyIntrinsicInitializer(.async_disposable_stack) } },

        // 19.3.5 BigInt ( . . . )
        // https://tc39.es/ecma262/#sec-constructor-properties-of-the-global-object-bigint
        .{ "BigInt", .{ .lazy_property = LazyIntrinsicInitializer(.big_int) } },

        // 19.3.6 BigInt64Array ( . . . )
        // https://tc39.es/ecma262/#sec-constructor-properties-of-the-global-object-bigint64array
        .{ "BigInt64Array", .{ .lazy_property = LazyIntrinsicInitializer(.big_int64_array) } },

        // 19.3.7 BigUint64Array ( . . . )
        // https://tc39.es/ecma262/#sec-constructor-properties-of-the-global-object-biguint64array
        .{ "BigUint64Array", .{ .lazy_property = LazyIntrinsicInitializer(.big_uint64_array) } },

        // 19.3.8 Boolean ( . . . )
        // https://tc39.es/ecma262/#sec-constructor-properties-of-the-global-object-boolean
        .{ "Boolean", .{ .lazy_property = LazyIntrinsicInitializer(.boolean) } },

        // 19.3.9 DataView ( . . . )
        // https://tc39.es/ecma262/#sec-constructor-properties-of-the-global-object-dataview
        .{ "DataView", .{ .lazy_property = LazyIntrinsicInitializer(.data_view) } },

        // 19.3.10 Date ( . . . )
        // https://tc39.es/ecma262/#sec-constructor-properties-of-the-global-object-date
        .{ "Date", .{ .lazy_property = LazyIntrinsicInitializer(.date) } },

        // 19.3.11 DisposableStack ( . . . )
        // https://tc39.es/ecma262/#sec-constructor-properties-of-the-global-object-disposablestack
        .{ "DisposableStack", .{ .lazy_property = LazyIntrinsicInitializer(.disposable_stack) } },

        // 19.3.12 Error ( . . . )
        // https://tc39.es/ecma262/#sec-constructor-properties-of-the-global-object-error
        .{ "Error", .{ .lazy_property = LazyIntrinsicInitializer(.@"error") } },

        // 19.3.13 EvalError ( . . . )
        // https://tc39.es/ecma262/#sec-constructor-properties-of-the-global-object-evalerror
        .{ "EvalError", .{ .lazy_property = LazyIntrinsicInitializer(.eval_error) } },

        // 19.3.14 FinalizationRegistry ( . . . )
        // https://tc39.es/ecma262/#sec-constructor-properties-of-the-global-object-finalization-registry
        .{ "FinalizationRegistry", .{ .lazy_property = LazyIntrinsicInitializer(.finalization_registry) } },

        // 19.3.15 Float16Array ( . . . )
        // https://tc39.es/ecma262/#sec-float16array
        .{ "Float16Array", .{ .lazy_property = LazyIntrinsicInitializer(.float16_array) } },

        // 19.3.16 Float32Array ( . . . )
        // https://tc39.es/ecma262/#sec-float32array
        .{ "Float32Array", .{ .lazy_property = LazyIntrinsicInitializer(.float32_array) } },

        // 19.3.17 Float64Array ( . . . )
        // https://tc39.es/ecma262/#sec-float64array
        .{ "Float64Array", .{ .lazy_property = LazyIntrinsicInitializer(.float64_array) } },

        // 19.3.18 Function ( . . . )
        // https://tc39.es/ecma262/#sec-constructor-properties-of-the-global-object-function
        .{ "Function", .{ .lazy_property = LazyIntrinsicInitializer(.function) } },

        // 19.3.19 Int8Array ( . . . )
        // https://tc39.es/ecma262/#sec-int8array
        .{ "Int8Array", .{ .lazy_property = LazyIntrinsicInitializer(.int8_array) } },

        // 19.3.20 Int16Array ( . . . )
        // https://tc39.es/ecma262/#sec-int16array
        .{ "Int16Array", .{ .lazy_property = LazyIntrinsicInitializer(.int16_array) } },

        // 19.3.21 Int32Array ( . . . )
        // https://tc39.es/ecma262/#sec-int32array
        .{ "Int32Array", .{ .lazy_property = LazyIntrinsicInitializer(.int32_array) } },

        // 19.3.22 Iterator ( . . . )
        // https://tc39.es/ecma262/#sec-constructor-properties-of-the-global-object-iterator
        .{ "Iterator", .{ .lazy_property = LazyIntrinsicInitializer(.iterator) } },

        // 19.3.23 Map ( . . . )
        // https://tc39.es/ecma262/#sec-map
        .{ "Map", .{ .lazy_property = LazyIntrinsicInitializer(.map) } },

        // 19.3.24 Number ( . . . )
        // https://tc39.es/ecma262/#sec-constructor-properties-of-the-global-object-number
        .{ "Number", .{ .lazy_property = LazyIntrinsicInitializer(.number) } },

        // 19.3.25 Object ( . . . )
        // https://tc39.es/ecma262/#sec-constructor-properties-of-the-global-object-object
        .{ "Object", .{ .lazy_property = LazyIntrinsicInitializer(.object) } },

        // 19.3.26 Promise ( . . . )
        // https://tc39.es/ecma262/#sec-constructor-properties-of-the-global-object-promise
        .{ "Promise", .{ .lazy_property = LazyIntrinsicInitializer(.promise) } },

        // 19.3.27 Proxy ( . . . )
        // https://tc39.es/ecma262/#sec-constructor-properties-of-the-global-object-proxy
        .{ "Proxy", .{ .lazy_property = LazyIntrinsicInitializer(.proxy) } },

        // 19.3.28 RangeError ( . . . )
        // https://tc39.es/ecma262/#sec-constructor-properties-of-the-global-object-rangeerror
        .{ "RangeError", .{ .lazy_property = LazyIntrinsicInitializer(.range_error) } },

        // 19.3.29 ReferenceError ( . . . )
        // https://tc39.es/ecma262/#sec-constructor-properties-of-the-global-object-referenceerror
        .{ "ReferenceError", .{ .lazy_property = LazyIntrinsicInitializer(.reference_error) } },

        // 19.3.30 RegExp ( . . . )
        // https://tc39.es/ecma262/#sec-constructor-properties-of-the-global-object-regexp
        .{ "RegExp", .{ .lazy_property = LazyIntrinsicInitializer(.reg_exp) } },

        // 19.3.31 Set ( . . . )
        // https://tc39.es/ecma262/#sec-set
        .{ "Set", .{ .lazy_property = LazyIntrinsicInitializer(.set) } },

        // 19.3.32 SharedArrayBuffer ( . . . )
        // https://tc39.es/ecma262/#sec-constructor-properties-of-the-global-object-sharedarraybuffer
        .{ "SharedArrayBuffer", .{ .lazy_property = LazyIntrinsicInitializer(.shared_array_buffer) } },

        // 19.3.33 String ( . . . )
        // https://tc39.es/ecma262/#sec-constructor-properties-of-the-global-object-string
        .{ "String", .{ .lazy_property = LazyIntrinsicInitializer(.string) } },

        // 19.3.34 SuppressedError ( . . . )
        // https://tc39.es/ecma262/#sec-constructor-properties-of-the-global-object-suppressederror
        .{ "SuppressedError", .{ .lazy_property = LazyIntrinsicInitializer(.suppressed_error) } },

        // 19.3.35 Symbol ( . . . )
        // https://tc39.es/ecma262/#sec-constructor-properties-of-the-global-object-symbol
        .{ "Symbol", .{ .lazy_property = LazyIntrinsicInitializer(.symbol) } },

        // 19.3.36 SyntaxError ( . . . )
        // https://tc39.es/ecma262/#sec-constructor-properties-of-the-global-object-syntaxerror
        .{ "SyntaxError", .{ .lazy_property = LazyIntrinsicInitializer(.syntax_error) } },

        // 19.3.37 TypeError ( . . . )
        // https://tc39.es/ecma262/#sec-constructor-properties-of-the-global-object-typeerror
        .{ "TypeError", .{ .lazy_property = LazyIntrinsicInitializer(.type_error) } },

        // 19.3.38 Uint8Array ( . . . )
        // https://tc39.es/ecma262/#sec-constructor-properties-of-the-global-object-uint8array
        .{ "Uint8Array", .{ .lazy_property = LazyIntrinsicInitializer(.uint8_array) } },

        // 19.3.39 Uint8ClampedArray ( . . . )
        // https://tc39.es/ecma262/#sec-uint8clampedarray
        .{ "Uint8ClampedArray", .{ .lazy_property = LazyIntrinsicInitializer(.uint8_clamped_array) } },

        // 19.3.40 Uint16Array ( . . . )
        // https://tc39.es/ecma262/#sec-uint16array
        .{ "Uint16Array", .{ .lazy_property = LazyIntrinsicInitializer(.uint16_array) } },

        // 19.3.41 Uint32Array ( . . . )
        // https://tc39.es/ecma262/#sec-uint32array
        .{ "Uint32Array", .{ .lazy_property = LazyIntrinsicInitializer(.uint32_array) } },

        // 19.3.42 URIError ( . . . )
        // https://tc39.es/ecma262/#sec-constructor-properties-of-the-global-object-urierror
        .{ "URIError", .{ .lazy_property = LazyIntrinsicInitializer(.uri_error) } },

        // 19.3.43 WeakMap ( . . . )
        // https://tc39.es/ecma262/#sec-constructor-properties-of-the-global-object-weakmap
        .{ "WeakMap", .{ .lazy_property = LazyIntrinsicInitializer(.weak_map) } },

        // 19.3.44 WeakRef ( . . . )
        // https://tc39.es/ecma262/#sec-constructor-properties-of-the-global-object-weakref
        .{ "WeakRef", .{ .lazy_property = LazyIntrinsicInitializer(.weak_ref) } },

        // 19.3.45 WeakSet ( . . . )
        // https://tc39.es/ecma262/#sec-constructor-properties-of-the-global-object-weakset
        .{ "WeakSet", .{ .lazy_property = LazyIntrinsicInitializer(.weak_set) } },

        // 19.4.1 Atomics
        // https://tc39.es/ecma262/#sec-atomics
        .{ "Atomics", .{ .lazy_property = LazyIntrinsicInitializer(.atomics) } },

        // 19.4.2 JSON
        // https://tc39.es/ecma262/#sec-json
        .{ "JSON", .{ .lazy_property = LazyIntrinsicInitializer(.json) } },

        // 19.4.3 Math
        // https://tc39.es/ecma262/#sec-math
        .{ "Math", .{ .lazy_property = LazyIntrinsicInitializer(.math) } },

        // 19.4.4 Reflect
        // https://tc39.es/ecma262/#sec-reflect
        .{ "Reflect", .{ .lazy_property = LazyIntrinsicInitializer(.reflect) } },
    } ++ (if (build_options.enable_annex_b) [_]GlobalObjectProperty{
        .{ "escape", .{ .lazy_property = LazyIntrinsicInitializer(.escape) } },
        .{ "unescape", .{ .lazy_property = LazyIntrinsicInitializer(.unescape) } },
    } else .{}) ++ (if (build_options.enable_intl) [_]GlobalObjectProperty{
        .{ "Intl", .{ .lazy_property = LazyIntrinsicInitializer(.intl) } },
    } else .{}) ++ (if (build_options.enable_temporal) [_]GlobalObjectProperty{
        .{ "Temporal", .{ .lazy_property = LazyIntrinsicInitializer(.temporal) } },
    } else .{});
}

fn GlobalFunction(comptime options: struct { name: []const u8, length: u32 }) type {
    return struct {
        pub fn create(agent: *Agent, realm: *Realm) std.mem.Allocator.Error!*Object {
            const builtin_function = try createBuiltinFunction(
                agent,
                .{ .function = @field(module, options.name) },
                options.length,
                options.name,
                .{ .realm = realm },
            );
            return &builtin_function.object;
        }
        pub fn init(_: *Agent, _: *Realm, _: *Object) std.mem.Allocator.Error!void {}
    };
}

pub const eval_function = GlobalFunction(.{ .name = "eval", .length = 1 });
pub const is_finite_function = GlobalFunction(.{ .name = "isFinite", .length = 1 });
pub const is_nan_function = GlobalFunction(.{ .name = "isNaN", .length = 1 });
pub const parse_float_function = GlobalFunction(.{ .name = "parseFloat", .length = 1 });
pub const parse_int_function = GlobalFunction(.{ .name = "parseInt", .length = 2 });
pub const decode_uri_function = GlobalFunction(.{ .name = "decodeURI", .length = 1 });
pub const decode_uri_component_function = GlobalFunction(.{ .name = "decodeURIComponent", .length = 1 });
pub const encode_uri_function = GlobalFunction(.{ .name = "encodeURI", .length = 1 });
pub const encode_uri_component_function = GlobalFunction(.{ .name = "encodeURIComponent", .length = 1 });
pub const escape_function = if (build_options.enable_annex_b)
    GlobalFunction(.{ .name = "escape", .length = 1 })
else
    @compileError("Annex B is not enabled");
pub const unescape_function = if (build_options.enable_annex_b)
    GlobalFunction(.{ .name = "unescape", .length = 1 })
else
    @compileError("Annex B is not enabled");

/// 19.2.1 eval ( source )
/// https://tc39.es/ecma262/#sec-eval-x
fn eval(agent: *Agent, _: Value, arguments: Arguments) Agent.Error!Value {
    const source = arguments.get(0);

    // 1. Return ? PerformEval(source, false, false).
    return performEval(agent, source, false, false);
}

/// 19.2.2 isFinite ( value )
/// https://tc39.es/ecma262/#sec-isfinite-number
fn isFinite(agent: *Agent, _: Value, arguments: Arguments) Agent.Error!Value {
    const value = arguments.get(0);

    // 1. Let number be ? ToNumber(value).
    const number = try value.toNumber(agent);

    // 2. If number is finite, return true.
    // 3. Return false.
    return Value.from(number.isFinite());
}

/// 19.2.3 isNaN ( value )
/// https://tc39.es/ecma262/#sec-isnan-number
fn isNaN(agent: *Agent, _: Value, arguments: Arguments) Agent.Error!Value {
    const value = arguments.get(0);

    // 1. Let number be ? ToNumber(value).
    const number = try value.toNumber(agent);

    // 2. If number is NaN, return true.
    // 3. Return false.
    return Value.from(number.isNan());
}

/// 19.2.4 parseFloat ( string )
/// https://tc39.es/ecma262/#sec-parsefloat-string
fn parseFloat(agent: *Agent, _: Value, arguments: Arguments) Agent.Error!Value {
    const gpa = agent.gpa;
    const string_value = arguments.get(0);

    // 1. Let inputString be ? ToString(string).
    const input_string = try string_value.toString(agent);

    // 2. Let trimmedString be ! TrimString(inputString, start).
    var trimmed_string = try (try input_string.trimStart(agent)).toUtf8(gpa);
    defer gpa.free(trimmed_string);

    // 3. Let trimmed be StringToCodePoints(trimmedString).
    // 4. Let trimmedPrefix be the longest prefix of trimmed that satisfies the syntax of a
    //    StrDecimalLiteral, which might be trimmed itself. If there is no such prefix, return NaN.
    // 5. Let parsedNumber be ParseText(trimmedPrefix, StrDecimalLiteral).
    // 6. Assert: parsedNumber is a Parse Node.
    // 7. Return the StringNumericValue of parsedNumber.
    if (std.mem.startsWith(u8, trimmed_string, "-Infinity")) return .negative_infinity;
    if (std.mem.startsWith(u8, trimmed_string, "+Infinity")) return .infinity;
    if (std.mem.startsWith(u8, trimmed_string, "Infinity")) return .infinity;
    // Don't pass other strings starting with "inf" to `std.fmt.parseFloat()`
    if (std.ascii.startsWithIgnoreCase(trimmed_string, "inf")) return .nan;
    // Limit to characters valid for StrDecimalLiteral before brute forcing
    var length = for (trimmed_string, 0..) |c, i| {
        if (!std.ascii.isDigit(c) and std.mem.findScalar(u8, "+-.eE", c) == null) break i;
    } else trimmed_string.len;
    while (length != 0) : (length -= 1) {
        if (std.fmt.parseFloat(f64, trimmed_string[0..length])) |result|
            return Value.from(result)
        else |_| {}
    }
    return .nan;
}

/// 19.2.5 parseInt ( string, radix )
/// https://tc39.es/ecma262/#sec-parseint-string-radix
fn parseInt(agent: *Agent, _: Value, arguments: Arguments) Agent.Error!Value {
    const gpa = agent.gpa;
    const string_value = arguments.get(0);
    const radix_value = arguments.get(1);

    // 1. Let inputString be ? ToString(string).
    const input_string = try string_value.toString(agent);

    // 2. Let radixMV be ℝ(? ToInt32(radix)).
    var radix = try radix_value.toInt32(agent);

    // 3. If radixMV ≠ 0 and radixMV is not in the inclusive interval from 2 to 36, return NaN.
    if (radix != 0 and (radix < 2 or radix > 36)) return .nan;

    // 4. Let trimmedString be ! TrimString(inputString, start).
    const trimmed_string_alloc = try (try input_string.trimStart(agent)).toUtf8(gpa);
    defer gpa.free(trimmed_string_alloc);
    var trimmed_string: []const u8 = trimmed_string_alloc;

    // 5. If trimmedString is the empty String, return NaN.
    if (trimmed_string.len == 0) return .nan;

    // 6. Let sign be 1.
    var sign: f64 = 1;

    // 7. If the first code unit of trimmedString is the code unit 0x002D (HYPHEN-MINUS), then
    if (trimmed_string[0] == '-') {
        // a. Set sign to -1.
        sign = -1;

        // b. Set trimmedString to the substring of trimmedString from 1.
        trimmed_string = trimmed_string[1..];
    }
    // 8. Else if the first code unit of trimmedString is the code unit 0x002B (PLUS SIGN), then
    else if (trimmed_string[0] == '+') {
        // a. Set trimmedString to the substring of trimmedString from 1.
        trimmed_string = trimmed_string[1..];
    }

    // 9. If radixMV = 0 or radixMV = 16, then
    if (radix == 0 or radix == 16) {
        // a. If the length of trimmedString ≥ 2 and the substring of trimmedString from 0 to 2 is
        //    either "0x" or "0X", then
        if (std.mem.startsWith(u8, trimmed_string, "0x") or
            std.mem.startsWith(u8, trimmed_string, "0X"))
        {
            // i. Set trimmedString to the substring of trimmedString from 2.
            trimmed_string = trimmed_string[2..];

            // ii. Set radixMV to 16.
            radix = 16;
        }
    }

    // 10. If radixMV = 0, set radixMV to 10.
    if (radix == 0) radix = 10;

    // 11. If trimmedString contains a code unit that is not a radix-radixMV digit, let end be the
    //     index within trimmedString of the first such code unit; else let end be the length of
    //     trimmedString.
    // 12. Let numberString be the substring of trimmedString from 0 to end.
    // 13. If numberString is empty, return NaN.
    // 14. Let mathInt be the integer value that is represented by numberString in radix-radixMV
    //     notation, using the letters A through Z and a through z for digits with values 10
    //     through 35. (However, if radixMV = 10 and numberString contains more than 20 significant
    //     digits, every significant digit after the 20th may be replaced by a 0 digit, at the
    //     option of the implementation; and if radixMV is not one of 2, 4, 8, 10, 16, or 32, then
    //     mathInt may be an implementation-approximated integer representing the integer value
    //     denoted by numberString in radix-radixMV notation.)
    var math_int: ?f64 = null;
    for (trimmed_string) |c| {
        const digit = std.fmt.charToDigit(c, @intCast(radix)) catch break;
        if (math_int == null) math_int = 0;
        math_int.? *= @floatFromInt(radix);
        math_int.? += @floatFromInt(digit);
    }

    if (math_int == null) return .nan;

    // 15. If sign = -1 and mathInt = 0, return -0𝔽.
    if (sign == -1 and math_int.? == 0) return Value.from(-0.0);

    // 16. Return 𝔽(sign × mathInt).
    return Value.from(sign * math_int.?);
}

/// 19.2.6.1 decodeURI ( encodedURI )
/// https://tc39.es/ecma262/#sec-decodeuri-encodeduri
fn decodeURI(agent: *Agent, _: Value, arguments: Arguments) Agent.Error!Value {
    const encoded_uri = arguments.get(0);

    // 1. Let uriString be ? ToString(encodedURI).
    const uri_string = try encoded_uri.toString(agent);

    // 2. Let preserveEscapeSet be ";/?:@&=+$,#".
    const preserve_escape_set = ";/?:@&=+$,#";

    // 3. Return ? Decode(uriString, preserveEscapeSet).
    return Value.from(try decode(agent, uri_string, preserve_escape_set));
}

/// 19.2.6.2 decodeURIComponent ( encodedURIComponent )
/// https://tc39.es/ecma262/#sec-decodeuricomponent-encodeduricomponent
fn decodeURIComponent(agent: *Agent, _: Value, arguments: Arguments) Agent.Error!Value {
    const encoded_uri_component = arguments.get(0);

    // 1. Let componentString be ? ToString(encodedURIComponent).
    const component_string = try encoded_uri_component.toString(agent);

    // 2. Let preserveEscapeSet be the empty String.
    const preserve_escape_set = "";

    // 3. Return ? Decode(componentString, preserveEscapeSet).
    return Value.from(try decode(agent, component_string, preserve_escape_set));
}

/// 19.2.6.3 encodeURI ( uri )
/// https://tc39.es/ecma262/#sec-encodeuri-uri
fn encodeURI(agent: *Agent, _: Value, arguments: Arguments) Agent.Error!Value {
    const uri = arguments.get(0);

    // 1. Let uriString be ? ToString(uri).
    const uri_string = try uri.toString(agent);

    // 2. Let extraUnescaped be ";/?:@&=+$,#".
    const extra_unescaped = ";/?:@&=+$,#";

    // 3. Return ? Encode(uriString, extraUnescaped).
    return Value.from(try encode(agent, uri_string, extra_unescaped));
}

/// 19.2.6.4 encodeURIComponent ( uriComponent )
/// https://tc39.es/ecma262/#sec-encodeuricomponent-uricomponent
fn encodeURIComponent(agent: *Agent, _: Value, arguments: Arguments) Agent.Error!Value {
    const uri_component = arguments.get(0);

    // 1. Let componentString be ? ToString(uriComponent).
    const component_string = try uri_component.toString(agent);

    // 2. Let extraUnescaped be the empty String.
    const extra_unescaped = "";

    // 3. Return ? Encode(componentString, extraUnescaped).
    return Value.from(try encode(agent, component_string, extra_unescaped));
}

/// 19.2.6.5 Encode ( string, extraUnescaped )
/// https://tc39.es/ecma262/#sec-encode
fn encode(
    agent: *Agent,
    string: *const String,
    comptime extra_unescaped: []const u8,
) Agent.Error!*const String {
    // 3. Let alwaysUnescaped be the string-concatenation of the ASCII word characters and
    //    "-.!~*'()".
    const always_unescaped = String.ascii_word_characters ++ "-.!~*'()";

    // 4. Let unescapedSet be the string-concatenation of alwaysUnescaped and extraUnescaped.
    const unescaped_set = always_unescaped ++ extra_unescaped;

    // OPTIMIZATION: If the string is ASCII we don't have to handle unpaired surrogates.
    if (string.isAscii()) {
        var allocating_writer: std.Io.Writer.Allocating = .init(agent.gc_allocator);
        defer allocating_writer.deinit();
        const writer = &allocating_writer.writer;
        std.Uri.Component.percentEncode(writer, string.asAscii(), struct {
            fn isValidChar(code_unit: u8) bool {
                return std.mem.findScalar(u8, unescaped_set, code_unit) != null;
            }
        }.isValidChar) catch |err| switch (err) {
            error.WriteFailed => return error.OutOfMemory,
        };
        return String.fromAscii(agent, try allocating_writer.toOwnedSlice());
    }

    // 1. Let length be the length of string.
    const length = string.length;

    // 2. Let result be the empty String.
    var result: String.Builder = .empty;
    defer result.deinit(agent.gc_allocator);

    // 5. Let k be 0.
    var k: u32 = 0;

    // 6. Repeat, while k < length,
    while (k < length) {
        // a. Let codeUnit be the code unit at index k within string.
        const code_unit = string.codeUnitAt(k);

        // b. If unescapedSet contains codeUnit, then
        if (code_unit <= std.math.maxInt(u8) and
            std.mem.findScalar(u8, unescaped_set, @intCast(code_unit)) != null)
        {
            // i. Set k to k + 1.
            k += 1;

            // ii. Set result to the string-concatenation of result and codeUnit.
            try result.appendChar(agent.gc_allocator, @intCast(code_unit));
        } else {
            // c. Else,
            // i. Let codePoint be CodePointAt(string, k).
            const code_point = string.codePointAt(k);

            // ii. If codePoint.[[IsUnpairedSurrogate]] is true, throw a URIError exception.
            if (code_point.is_unpaired_surrogate) {
                return agent.throwException(.uri_error, "URI contains unpaired surrogate", .{});
            }

            // iii. Set k to k + codePoint.[[CodeUnitCount]].
            k += code_point.code_unit_count;

            // iv. Let octets be the List of octets resulting by applying the UTF-8 transformation
            //     to codePoint.[[CodePoint]].
            var buf: [4]u8 = undefined;
            const size = std.unicode.utf8Encode(code_point.code_point, &buf) catch unreachable;

            // v. For each element octet of octets, do
            for (buf[0..size]) |byte| {
                // 1. Let hex be the String representation of octet, formatted as an uppercase
                //    hexadecimal number.
                // 2. Set result to the string-concatenation of result, "%", and StringPad(hex, 2,
                //    "0", start).
                try result.appendString(
                    agent.gc_allocator,
                    try String.fromAscii(agent, try agent.gc_allocator.print("%{X:0>2}", .{byte})),
                );
            }
        }
    }

    // 7. Return result.
    return result.build(agent);
}

/// 19.2.6.6 Decode ( string, preserveEscapeSet )
/// https://tc39.es/ecma262/#sec-decode
fn decode(
    agent: *Agent,
    string: *const String,
    comptime preserve_escape_set: []const u8,
) Agent.Error!*const String {
    const gpa = agent.gpa;
    var buffer: [@sizeOf(u16) * 64]u8 = undefined;
    var bfa_state: std.heap.BufferFirstAllocator = .init(&buffer, gpa);
    const bfa = bfa_state.allocator();

    const input = try string.toUtf16(bfa);
    defer bfa.free(input);

    // 1. Let length be the length of string.
    const length = input.len;

    // 2. Let result be the empty String.
    // SAFETY: This builder can use a GPA as it only stores u8/u16/u21 char/code unit/code point segments.
    var result: String.Builder = .empty;
    defer result.deinit(gpa);

    // 3. Let k be 0.
    var k: usize = 0;

    // 4. Repeat, while k < length,
    while (k < length) : (k += 1) {
        // a. Let codeUnit be the code unit at index k within string.
        const code_unit = input[k];

        // b. Let segment be codeUnit.

        // c. If codeUnit is the code unit 0x0025 (PERCENT SIGN), then
        if (code_unit == '%') {
            // i. If k + 3 > length, throw a URIError exception.
            if (k + 3 > length) {
                return agent.throwException(.uri_error, "Escape sequence must be of form '%XX'", .{});
            }

            // ii. Let escape be the substring of string from k to k + 3.
            const escape_ = input[k .. k + 3];

            // iii. Let firstOctet be ParseHexOctet(string, k + 1).
            const first_octet = parseHexOctet(input, k + 1) orelse {
                // iv. If firstOctet is not an integer, throw a URIError exception.
                return agent.throwException(.uri_error, "Escape sequence must be hex digits", .{});
            };

            // v. Set k to k + 2.
            k += 2;

            // vi. Let n be the number of leading 1 bits in firstOctet.
            const byte_sequence_length = std.unicode.utf8ByteSequenceLength(first_octet) catch null;

            // vii. If n = 0, then
            if (byte_sequence_length == 1) {
                // 1. Let asciiChar be the code unit whose numeric value is firstOctet.
                // 2. If preserveEscapeSet contains asciiChar, set segment to escape; else set
                //    segment to asciiChar.
                if (std.mem.findScalar(u8, preserve_escape_set, first_octet) != null) {
                    try result.appendSegment(gpa, .{ .char = '%' });
                    try result.appendSegment(gpa, .{ .char = @intCast(escape_[1]) });
                    try result.appendSegment(gpa, .{ .char = @intCast(escape_[2]) });
                } else {
                    try result.appendSegment(gpa, .{ .char = first_octet });
                }
            } else {
                // viii. Else,
                // 1. If n = 1 or n > 4, throw a URIError exception.
                if (byte_sequence_length == null) {
                    return agent.throwException(.uri_error, "Invalid UTF-8 start byte", .{});
                }

                // 2. Let octets be « firstOctet ».
                var octets = [4]u8{ first_octet, 0, 0, 0 };

                // 3. Let j be 1.
                var j: u3 = 1;

                // 4. Repeat, while j < n,
                while (j < byte_sequence_length.?) : (j += 1) {
                    // a. Set k to k + 1.
                    k += 1;

                    // b. If k + 3 > length, throw a URIError exception.
                    // c. If the code unit at index k within string is not the code unit 0x0025
                    //    (PERCENT SIGN), throw a URIError exception.
                    if (k + 3 > length or input[k] != '%') {
                        return agent.throwException(.uri_error, "Escape sequence must be of form '%XX'", .{});
                    }

                    // d. Let continuationByte be ParseHexOctet(string, k + 1).
                    const continuation_byte = parseHexOctet(input, k + 1) orelse {
                        // e. If continuationByte is not an integer, throw a URIError exception.
                        return agent.throwException(.uri_error, "Escape sequence must be hex digits", .{});
                    };

                    // f. Append continuationByte to octets.
                    octets[j] = continuation_byte;

                    // g. Set k to k + 2.
                    k += 2;

                    // h. Set j to j + 1.
                }

                // 5. Assert: The length of octets is n.
                // 6. If octets does not contain a valid UTF-8 encoding of a Unicode code point,
                //    throw a URIError exception.
                const code_point = std.unicode.utf8Decode(octets[0..byte_sequence_length.?]) catch {
                    return agent.throwException(.uri_error, "Invalid UTF-8 byte sequence", .{});
                };

                // 7. Let codePoint be the code point obtained by applying the UTF-8 transformation
                //    to octets, that is, from a List of octets into a 21-bit value.
                // 8. Set segment to UTF16EncodeCodePoint(codePoint).
                try result.appendSegment(gpa, .{ .code_point = code_point });
            }
        } else {
            try result.appendSegment(gpa, .{ .code_unit = code_unit });
        }

        // d. Set result to the string-concatenation of result and segment.
        // e. Set k to k + 1.
    }

    // 5. Return result.
    return result.build(agent);
}

/// 19.2.6.7 ParseHexOctet ( string, position )
/// https://tc39.es/ecma262/#sec-parsehexoctet
fn parseHexOctet(string: []const u16, position: usize) ?u8 {
    // 1. Let length be the length of string.
    const length = string.len;

    // 2. Assert: position + 2 ≤ length.
    std.debug.assert(position + 2 <= length);

    // 3. Let hexDigits be the substring of string from position to position + 2.
    const hex_digits = string[position .. position + 2];

    // 4. Let parseResult be ParseText(hexDigits, HexDigits[~Sep]).
    // 5. If parseResult is not a Parse Node, return parseResult.
    // 6. Let n be the MV of parseResult.
    // 7. Assert: n is in the inclusive interval from 0 to 255.
    var buf: [2]u8 = undefined;
    buf[0] = std.math.cast(u8, hex_digits[0]) orelse return null;
    buf[1] = std.math.cast(u8, hex_digits[1]) orelse return null;
    const n = parseDigits(u8, &buf, 16) catch return null;

    // 8. Return n.
    return n;
}

/// B.2.1.1 escape ( string )
/// https://tc39.es/ecma262/#sec-escape-string
fn escape(agent: *Agent, _: Value, arguments: Arguments) Agent.Error!Value {
    const string_value = arguments.get(0);

    // 1. Set string to ? ToString(string).
    const string = try string_value.toString(agent);

    // 3. Let result be the empty String.
    // NOTE: This allocates the exact needed capacity upfront
    var result = try String.Builder.initCapacity(agent.gc_allocator, string.length);
    defer result.deinit(agent.gc_allocator);

    // 4. Let unescapedSet be the string-concatenation of the ASCII word characters and "@*+-./".
    const unescaped_set = String.ascii_word_characters ++ "@*+-./";

    // 2. Let length be the length of string.
    // 5. Let k be 0.
    // 6. Repeat, while k < length,
    //     a. Let codeUnit be the code unit at index k within string.
    var it = string.codeUnitIterator();
    while (it.next()) |code_unit| {
        // b. If unescapedSet contains codeUnit, then
        const s: String.Builder.Segment = if (code_unit < 256 and std.mem.findScalar(u8, unescaped_set, @intCast(code_unit)) != null) blk: {
            // i. Let nextPart be codeUnit.
            break :blk .{ .char = @intCast(code_unit) };
        } else blk: {
            // c. Else,
            // i. Let codeUnitNumber be the numeric value of codeUnit.
            // ii. If codeUnitNumber < 256, then
            if (code_unit < 256) {
                // 1. Let hex be the String representation of codeUnitNumber, formatted as an
                //    uppercase hexadecimal number.
                // 2. Let nextPart be the string-concatenation of "%" and StringPad(hex, 2, "0",
                //    start).
                break :blk .{
                    .string = try String.fromAscii(agent, try agent.gc_allocator.print(
                        "%{X}",
                        .{&.{@as(u8, @intCast(code_unit))}},
                    )),
                };
            } else {
                // iii. Else,
                // 1. Let hex be the String representation of codeUnitNumber, formatted as an
                //    uppercase hexadecimal number.
                // 2. Let nextPart be the string-concatenation of "%u" and StringPad(hex, 4, "0",
                //    start).
                var bytes = std.mem.toBytes(code_unit);
                std.mem.reverse(u8, &bytes);
                break :blk .{
                    .string = try String.fromAscii(agent, try agent.gc_allocator.print(
                        "%u{X}",
                        .{&bytes},
                    )),
                };
            }
        };

        // d. Set result to the string-concatenation of result and nextPart.
        result.appendSegmentAssumeCapacity(s);

        // e. Set k to k + 1.
    }

    // 7. Return result.
    return Value.from(try result.build(agent));
}

/// B.2.1.2 unescape ( string )
/// https://tc39.es/ecma262/#sec-unescape-string
fn unescape(agent: *Agent, _: Value, arguments: Arguments) Agent.Error!Value {
    const gpa = agent.gpa;
    const string_value = arguments.get(0);

    // 1. Set string to ? ToString(string).
    const string = try string_value.toString(agent);

    // 2. Let length be the length of string.
    const length = string.length;

    // 3. Let result be the empty String.
    // SAFETY: This builder can use a GPA as it only stores u16 code unit segments.
    var result: String.Builder = .empty;
    defer result.deinit(gpa);

    const code_units = try string.toUtf16(gpa);
    defer gpa.free(code_units);

    // 4. Let k be 0.
    var k: u32 = 0;

    // 5. Repeat, while k < length,
    while (k < length) : (k += 1) {
        // a. Let codeUnit be the code unit at index k within string.
        var code_unit = code_units[k];

        // b. If codeUnit is the code unit 0x0025 (PERCENT SIGN), then
        if (code_unit == '%') {
            // i. Let hexDigits be the empty String.
            var hex_digits: []const u16 = &.{};

            // ii. Let optionalAdvance be 0.
            var optional_advance: u32 = 0;

            // iii. If k + 5 < length and the code unit at index k + 1 within string is the code
            //      unit 0x0075 (LATIN SMALL LETTER U), then
            if (k + 5 < length and code_units[k + 1] == 'u') {
                // 1. Set hexDigits to the substring of string from k + 2 to k + 6.
                hex_digits = code_units[k + 2 .. k + 6];

                // 2. Set optionalAdvance to 5.
                optional_advance = 5;
            }
            // iv. Else if k + 3 ≤ length, then
            else if (k + 3 <= length) {
                // 1. Set hexDigits to the substring of string from k + 1 to k + 3.
                hex_digits = code_units[k + 1 .. k + 3];

                // 2. Set optionalAdvance to 2.
                optional_advance = 2;
            }

            // NOTE: This will succeed if all code points are ASCII, which is required for the hex
            //       parsing to work anyway.
            var buf: [4]u8 = undefined;
            if (std.unicode.utf16LeToUtf8(&buf, hex_digits) catch null) |end| {
                // v. Let parseResult be ParseText(hexDigits, HexDigits[~Sep]).
                // vi. If parseResult is a Parse Node, then
                if (parseDigits(u16, buf[0..end], 16)) |n| {
                    // 1. Let codeUnitNumber be the MV of parseResult.
                    // 2. Set codeUnit to the code unit whose numeric value is codeUnitNumber.
                    code_unit = n;

                    // 3. Set k to k + optionalAdvance.
                    k += optional_advance;
                } else |_| {}
            }
        }

        // c. Set result to the string-concatenation of result and codeUnit.
        try result.appendCodeUnit(gpa, code_unit);

        // d. Set k to k + 1.
    }

    // 6. Return result.
    return Value.from(try result.build(agent));
}
