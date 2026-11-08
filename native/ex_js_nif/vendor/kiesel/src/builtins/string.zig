//! 22.1 String Objects
//! https://tc39.es/ecma262/#sec-string-objects

const std = @import("std");

const icu4zig = @import("icu4zig");

const build_options = @import("build-options");
const builtins = @import("../builtins.zig");
const execution = @import("../execution.zig");
const types = @import("../types.zig");
const utils = @import("../utils.zig");

const Agent = execution.Agent;
const Arguments = types.Arguments;
const MakeObject = types.MakeObject;
const Object = types.Object;
const PropertyDescriptor = types.PropertyDescriptor;
const Realm = execution.Realm;
const StringIterator = builtins.StringIterator;
const Value = types.Value;
const PropertyKey = types.PropertyKey;
const createArrayFromList = types.createArrayFromList;
const createArrayFromListMapToValue = types.createArrayFromListMapToValue;
const createBuiltinFunction = builtins.createBuiltinFunction;
const getPrototypeFromConstructor = builtins.getPrototypeFromConstructor;
const isCompatiblePropertyDescriptor = builtins.isCompatiblePropertyDescriptor;
const noexcept = utils.noexcept;
const ordinaryDefineOwnProperty = builtins.ordinaryDefineOwnProperty;
const ordinaryGetOwnProperty = builtins.ordinaryGetOwnProperty;
const regExpCreate = builtins.regExpCreate;

pub const StringPadPlacement = enum { start, end };

/// 22.1.3.17.2 StringPad ( string, maxLength, fillString, placement )
/// https://tc39.es/ecma262/#sec-stringpad
pub fn stringPad(
    agent: *Agent,
    string: *const types.String,
    max_length: u32,
    fill_string: *const types.String,
    placement: StringPadPlacement,
) Agent.Error!*const types.String {
    // 1. Let stringLength be the length of string.
    const string_length = string.length;

    // 2. If maxLength ≤ stringLength, return string.
    if (max_length <= string_length) return string;

    // 3. If fillString is the empty String, return string.
    if (fill_string.isEmpty()) return string;

    // 4. Let fillLength be maxLength - stringLength.
    const fill_length = max_length - string_length;

    // 5. Let truncatedStringFiller be the String value consisting of repeated concatenations of
    //    fillString truncated to length fillLength.
    const truncated_string_filler = switch (fill_string.asAsciiOrUtf16()) {
        .ascii => |ascii| blk: {
            const repeated_code_units = try agent.gc_allocator.alloc(u8, fill_length);
            var i: u32 = 0;
            while (i < fill_length) : (i += fill_string.length) {
                const copy_end = @min(i + fill_string.length, fill_length);
                const dest = repeated_code_units[i..copy_end];
                @memcpy(dest, ascii[0..dest.len]);
            }
            break :blk try types.String.fromAscii(agent, repeated_code_units);
        },
        .utf16 => |utf16| blk: {
            const repeated_code_units = try agent.gc_allocator.alloc(u16, fill_length);
            var i: u32 = 0;
            while (i < fill_length) : (i += fill_string.length) {
                const copy_end = @min(i + fill_string.length, fill_length);
                const dest = repeated_code_units[i..copy_end];
                @memcpy(dest, utf16[0..dest.len]);
            }
            // No truncation, assume resulting string must be UTF-16
            if (fill_length >= fill_string.length) {
                break :blk try types.String.fromUtf16(agent, repeated_code_units);
            }
            // Check if fill string contains non-ASCII code units
            for (repeated_code_units) |c| {
                if (c > 0x7F) {
                    break :blk try types.String.fromUtf16(agent, repeated_code_units);
                }
            }
            // Fill string was truncated to only ASCII code units, convert
            const repeated_code_units_ascii = try agent.gc_allocator.alloc(u8, fill_length);
            for (repeated_code_units, 0..) |c, i_| {
                repeated_code_units_ascii[i_] = @intCast(c);
            }
            agent.gc_allocator.free(repeated_code_units);
            break :blk try types.String.fromAscii(agent, repeated_code_units_ascii);
        },
    };

    switch (placement) {
        // 6. If placement is start, return the string-concatenation of truncatedStringFiller and
        //    string.
        .start => return types.String.concat(agent, &.{
            truncated_string_filler,
            string,
        }),
        // 7. Return the string-concatenation of string and truncatedStringFiller.
        .end => return types.String.concat(agent, &.{
            string,
            truncated_string_filler,
        }),
    }
}

/// 22.1.3.19.1 GetSubstitution ( matched, string, position, captures, namedCaptures, replacementTemplate )
/// https://tc39.es/ecma262/#sec-getsubstitution
pub fn getSubstitution(
    agent: *Agent,
    matched: *const types.String,
    string: *const types.String,
    position: u32,
    captures: []const ?*const types.String,
    named_captures: ?*Object,
    replacement_template: *const types.String,
) Agent.Error!*const types.String {
    // 1. Let stringLength be the length of string.
    const string_length = string.length;

    // 2. Assert: position ≤ stringLength.
    std.debug.assert(position <= string_length);

    // 3. Let result be the empty String.
    var result: types.String.Builder = .empty;
    defer result.deinit(agent.gc_allocator);

    // 4. Let templateRemainder be replacementTemplate.
    var template_reminder = replacement_template;

    // 5. Repeat, while templateRemainder is not the empty String,
    while (!template_reminder.isEmpty()) {
        // a. NOTE: The following steps isolate ref (a prefix of templateRemainder), determine
        //    refReplacement (its replacement), and then append that replacement to result.
        // b. If templateRemainder starts with "$$", then
        const ref, const ref_replacement = if (template_reminder.startsWith(types.String.fromLiteral("$$"))) blk: {
            // i. Let ref be "$$".
            const ref = types.String.fromLiteral("$$");

            // ii. Let refReplacement be "$".
            const ref_replacement = types.String.fromLiteral("$");

            break :blk .{ ref, ref_replacement };
        } else if (template_reminder.startsWith(types.String.fromLiteral("$`"))) blk: {
            // c. Else if templateRemainder starts with "$`", then
            // i. Let ref be "$`".
            const ref = types.String.fromLiteral("$`");

            // ii. Let refReplacement be the substring of string from 0 to position.
            const ref_replacement = try string.substring(agent, 0, position);

            break :blk .{ ref, ref_replacement };
        } else if (template_reminder.startsWith(types.String.fromLiteral("$&"))) blk: {
            // d. Else if templateRemainder starts with "$&", then
            // i. Let ref be "$&".
            const ref = types.String.fromLiteral("$&");

            // ii. Let refReplacement be matched.
            const ref_replacement = matched;

            break :blk .{ ref, ref_replacement };
        } else if (template_reminder.startsWith(types.String.fromLiteral("$'"))) blk: {
            // e. Else if templateRemainder starts with "$'" (0x0024 (DOLLAR SIGN) followed by
            //    0x0027 (APOSTROPHE)), then
            // i. Let ref be "$'".
            const ref = types.String.fromLiteral("$'");

            // ii. Let matchLength be the length of matched.
            const match_length = matched.length;

            // iii. Let tailPosition be position + matchLength.
            const tail_position = position +| match_length;

            // iv. Let refReplacement be the substring of string from min(tailPosition,
            //     stringLength).
            // v. NOTE: tailPosition can exceed stringLength only if this abstract operation was
            //    invoked by a call to the intrinsic %Symbol.replace% method of %RegExp.prototype%
            //    on an object whose "exec" property is not the intrinsic %RegExp.prototype.exec%.
            const ref_replacement = try string.substring(
                agent,
                @min(tail_position, string_length),
                null,
            );

            break :blk .{ ref, ref_replacement };
        } else if (template_reminder.length >= 2 and
            template_reminder.codeUnitAt(0) == '$' and
            std.ascii.isDigit(@truncate(template_reminder.codeUnitAt(1))))
        blk: {
            // f. Else if templateRemainder starts with "$" followed by 1 or more decimal digits,
            //    then
            // i. If templateRemainder starts with "$" followed by 2 or more decimal digits, let
            //    digitCount be 2; else let digitCount be 1.
            var digit_count: u2 = if (template_reminder.length >= 3 and
                std.ascii.isDigit(@truncate(template_reminder.codeUnitAt(1))) and
                std.ascii.isDigit(@truncate(template_reminder.codeUnitAt(2)))) 2 else 1;

            // ii. Let digits be the substring of templateRemainder from 1 to 1 + digitCount.
            var digits = (try template_reminder.substring(
                agent,
                1,
                1 + digit_count,
            )).asAscii();

            // iii. Let index be ℝ(StringToNumber(digits)).
            var index = std.fmt.parseInt(usize, digits, 10) catch unreachable;

            // iv. Assert: 0 ≤ index ≤ 99.
            std.debug.assert(index <= 99);

            // v. Let captureLength be the number of elements in captures.
            const capture_length = captures.len;

            // vi. If index > captureLength and digitCount = 2, then
            if (index > capture_length and digit_count == 2) {
                // 1. NOTE: When a two-digit replacement pattern specifies an index exceeding the
                //    count of capturing groups, it is treated as a one-digit replacement pattern
                //    followed by a literal digit.

                // 2. Set digitCount to 1.
                digit_count = 1;

                // 3. Set digits to the substring of digits from 0 to 1.
                digits = digits[0..1];

                // 4. Set index to ℝ(StringToNumber(digits)).
                index = std.fmt.parseInt(usize, digits, 10) catch unreachable;
            }

            // vii. Let ref be the substring of templateRemainder from 0 to 1 + digitCount.
            const ref = try template_reminder.substring(agent, 0, 1 + digit_count);

            // viii. If 1 ≤ index ≤ captureLength, then
            const ref_replacement: *const types.String = if (index >= 1 and index <= capture_length) blk_ref_replacement: {
                // 1. Let capture be captures[index - 1].
                const capture = captures[index - 1];

                // 2. If capture is undefined, then
                if (capture == null) {
                    // a. Let refReplacement be the empty String.
                    break :blk_ref_replacement .empty;
                } else {
                    // 3. Else,
                    // a. Let refReplacement be capture.
                    break :blk_ref_replacement capture.?;
                }
            } else blk_ref_replacement: {
                // ix. Else,
                // 1. Let refReplacement be ref.
                break :blk_ref_replacement ref;
            };

            break :blk .{ ref, ref_replacement };
        } else if (template_reminder.startsWith(types.String.fromLiteral("$<"))) blk: {
            // g. Else if templateRemainder starts with "$<", then
            // i. Let gtPosition be StringIndexOf(templateRemainder, ">", 0).
            const gt_position = template_reminder.indexOf(types.String.fromLiteral(">"), 0);

            // ii. If gtPosition is not-found or namedCaptures is undefined, then
            if (gt_position == null or named_captures == null) {
                // 1. Let ref be "$<".
                const ref = types.String.fromLiteral("$<");

                // 2. Let refReplacement be ref.
                const ref_replacement = ref;

                break :blk .{ ref, ref_replacement };
            } else {
                // iii. Else,
                // 1. Let ref be the substring of templateRemainder from 0 to gtPosition + 1.
                const ref = try template_reminder.substring(agent, 0, gt_position.? + 1);

                // 2. Let groupName be the substring of templateRemainder from 2 to gtPosition.
                const group_name = try template_reminder.substring(agent, 2, gt_position.?);

                // 3. Assert: namedCaptures is an Object.
                std.debug.assert(named_captures != null);

                // 4. Let capture be ? Get(namedCaptures, groupName).
                const capture = try named_captures.?.get(agent, PropertyKey.from(group_name));

                // 5. If capture is undefined, then
                //     a. Let refReplacement be the empty String.
                // 6. Else,
                //     a. Let refReplacement be ? ToString(capture).
                const ref_replacement: *const types.String = if (capture.isUndefined())
                    .empty
                else
                    try capture.toString(agent);

                break :blk .{ ref, ref_replacement };
            }
        } else blk: {
            // h. Else,
            // i. Let ref be the substring of templateRemainder from 0 to 1.
            const ref = try template_reminder.substring(agent, 0, 1);

            // ii. Let refReplacement be ref.
            const ref_replacement = ref;

            break :blk .{ ref, ref_replacement };
        };

        // i. Let refLength be the length of ref.
        const ref_length = ref.length;

        // j. Set templateRemainder to the substring of templateRemainder from refLength.
        template_reminder = try template_reminder.substring(agent, ref_length, null);

        // k. Set result to the string-concatenation of result and refReplacement.
        try result.appendString(agent.gc_allocator, ref_replacement);
    }

    // 6. Return result.
    return result.build(agent);
}

/// 10.4.3.1 [[GetOwnProperty]] ( propertyKey )
/// https://tc39.es/ecma262/#sec-string-exotic-objects-getownproperty-p
fn getOwnProperty(
    agent: *Agent,
    obj: *Object,
    property_key: PropertyKey,
) std.mem.Allocator.Error!?PropertyDescriptor {
    // 1. Let propertyDesc be OrdinaryGetOwnProperty(string, propertyKey).
    const property_desc = ordinaryGetOwnProperty(obj, property_key) catch unreachable;

    // 2. If propertyDesc is not undefined, return propertyDesc.
    if (property_desc != null) return property_desc;

    // 3. Return StringGetOwnProperty(string, propertyKey).
    return stringGetOwnProperty(agent, obj.as(String), property_key);
}

/// 10.4.3.2 [[DefineOwnProperty]] ( propertyKey, propertyDesc )
/// https://tc39.es/ecma262/#sec-string-exotic-objects-defineownproperty-p-desc
fn defineOwnProperty(
    agent: *Agent,
    obj: *Object,
    property_key: PropertyKey,
    property_desc: PropertyDescriptor,
) std.mem.Allocator.Error!bool {
    const string = obj.as(String);

    // 1. Let stringDesc be StringGetOwnProperty(string, propertyKey).
    const maybe_string_desc = try stringGetOwnProperty(agent, string, property_key);

    // 2. If stringDesc is not undefined, then
    if (maybe_string_desc) |string_desc| {
        // a. Let extensible be string.[[Extensible]].
        const extensible = string.object.extensible();

        // b. Return IsCompatiblePropertyDescriptor(extensible, propertyDesc, stringDesc).
        return isCompatiblePropertyDescriptor(
            extensible,
            property_desc,
            string_desc,
        );
    }

    // 3. Return ! OrdinaryDefineOwnProperty(string, propertyKey, propertyDesc).
    return ordinaryDefineOwnProperty(
        agent,
        obj,
        property_key,
        property_desc,
    ) catch |err| try noexcept(err);
}

/// 10.4.3.3 [[OwnPropertyKeys]] ( )
/// https://tc39.es/ecma262/#sec-string-exotic-objects-ownpropertykeys
fn ownPropertyKeys(agent: *Agent, obj: *Object) std.mem.Allocator.Error![]PropertyKey {
    const indexed_properties = obj.indexedProperties();

    // 2. Let string be obj.[[StringData]].
    // 3. Assert: string is a String.
    const string = obj.as(String).fields.string_data;

    // 4. Let length be the length of string.
    const length = string.length;

    // 1. Let keys be a new empty List.
    var keys = try std.ArrayList(PropertyKey).initCapacity(
        agent.gc_allocator,
        indexed_properties.count() +
            obj.shape.properties.count() +
            length,
    );

    // 5. For each integer i such that 0 ≤ i < length, in ascending order, do
    for (0..length) |i| {
        // a. Append ! ToString(𝔽(i)) to keys.
        keys.appendAssumeCapacity(PropertyKey.from(@as(PropertyKey.IntegerIndex, @intCast(i))));
    }

    // 6. For each own property key propertyKey of obj such that propertyKey is an array index and
    //    ! ToIntegerOrInfinity(propertyKey) ≥ length, in ascending numeric index order, do
    //     a. Append propertyKey to keys.
    switch (indexed_properties.storage) {
        .none => {},
        inline .sparse_value, .sparse_property_descriptor => |sparse| {
            var it = sparse.keyIterator();
            while (it.next()) |index| {
                if (index.* < length) continue;
                const property_key = PropertyKey.from(@as(PropertyKey.IntegerIndex, @intCast(index.*)));
                keys.appendAssumeCapacity(property_key);
            }
            std.mem.sortUnstable(PropertyKey, keys.items, {}, struct {
                fn lessThanFn(_: void, a: PropertyKey, b: PropertyKey) bool {
                    return a.integer_index < b.integer_index;
                }
            }.lessThanFn);
        },
        else => {
            for (length..indexed_properties.count()) |index| {
                const property_key = PropertyKey.from(@as(PropertyKey.IntegerIndex, @intCast(index)));
                keys.appendAssumeCapacity(property_key);
            }
        },
    }

    // 7. For each own property key propertyKey of obj such that propertyKey is a String and
    //    propertyKey is not an array index, in ascending chronological order of property creation,
    //    do
    for (obj.shape.properties.keys()) |property_key| {
        if (property_key == .string or property_key == .integer_index) {
            std.debug.assert(!property_key.isArrayIndex());

            // a. Append propertyKey to keys.
            keys.appendAssumeCapacity(property_key);
        }
    }

    // 8. For each own property key propertyKey of obj such that propertyKey is a Symbol, in
    //    ascending chronological order of property creation, do
    for (obj.shape.properties.keys()) |property_key| {
        if (property_key == .symbol) {
            // a. Append propertyKey to keys.
            keys.appendAssumeCapacity(property_key);
        }
    }

    // 9. Return keys.
    return keys.toOwnedSlice(agent.gc_allocator);
}

/// 10.4.3.4 StringCreate ( value, proto )
/// https://tc39.es/ecma262/#sec-stringcreate
pub fn stringCreate(
    agent: *Agent,
    value: *const types.String,
    proto: *Object,
) std.mem.Allocator.Error!*String {
    // 1. Let string be MakeBasicObject(« [[Prototype]], [[Extensible]], [[StringData]] »).
    const string_obj = try String.create(agent, .{
        // 2. Set string.[[Prototype]] to proto.
        .prototype = proto,

        .fields = .{
            // 3. Set string.[[StringData]] to value.
            .string_data = value,
        },

        .internal_methods = .initComptime(.{
            // 4. Set string.[[GetOwnProperty]] as specified in 10.4.3.1.
            .getOwnProperty = getOwnProperty,

            // 5. Set string.[[DefineOwnProperty]] as specified in 10.4.3.2.
            .defineOwnProperty = defineOwnProperty,

            // 6. Set string.[[OwnPropertyKeys]] as specified in 10.4.3.3.
            .ownPropertyKeys = ownPropertyKeys,
        }),
    });

    // 7. Let length be the length of value.
    const length = value.length;

    // 8. Perform ! DefinePropertyOrThrow(string, "length", PropertyDescriptor {
    //    [[Value]]: 𝔽(length), [[Writable]]: false, [[Enumerable]]: false,
    //    [[Configurable]]: false }).
    try string_obj.object.definePropertyDirect(agent, PropertyKey.from("length"), .{
        .value_or_accessor = .{
            .value = Value.from(length),
        },
        .attributes = .none,
    });

    // 9. Return string.
    return string_obj;
}

/// 10.4.3.5 StringGetOwnProperty ( string, propertyKey )
/// https://tc39.es/ecma262/#sec-stringgetownproperty
fn stringGetOwnProperty(
    agent: *Agent,
    string_obj: *const String,
    property_key: PropertyKey,
) std.mem.Allocator.Error!?PropertyDescriptor {
    // 1. If propertyKey is not a String, return undefined.
    // 2. Let numericIndex be CanonicalNumericIndexString(propertyKey).
    // 3. If numericIndex is not an integral Number, return undefined.
    // 4. If numericIndex is -0𝔽 or numericIndex < -0𝔽, return undefined.
    if (property_key != .integer_index) return null;
    if (property_key.integer_index > std.math.maxInt(u32) - 1) return null;
    const numeric_index: u32 = @intCast(property_key.integer_index);

    // 5. Let stringData be string.[[StringData]].
    // 6. Assert: stringData is a String.
    const string = string_obj.fields.string_data;

    // 7. Let length be the length of stringData.
    const length = string.length;

    // 8. If ℝ(numericIndex) ≥ length, return undefined.
    if (numeric_index >= length) return null;

    // 9. Let resultString be the substring of stringData from ℝ(numericIndex) to
    //    ℝ(numericIndex) + 1.
    const result_string = try string.substring(agent, numeric_index, numeric_index + 1);

    // 10. Return the PropertyDescriptor { [[Value]]: resultString, [[Writable]]: false,
    //     [[Enumerable]]: true, [[Configurable]]: false }.
    return .{
        .value = Value.from(result_string),
        .writable = false,
        .enumerable = true,
        .configurable = false,
    };
}

/// 22.1.2 Properties of the String Constructor
/// https://tc39.es/ecma262/#sec-properties-of-the-string-constructor
pub const constructor = struct {
    pub fn create(agent: *Agent, realm: *Realm) std.mem.Allocator.Error!*Object {
        const builtin_function = try createBuiltinFunction(
            agent,
            .{ .constructor = impl },
            1,
            "String",
            .{ .realm = realm, .proto = try realm.intrinsic(.function_prototype) },
        );
        return &builtin_function.object;
    }

    pub fn init(agent: *Agent, realm: *Realm, object: *Object) std.mem.Allocator.Error!void {
        try object.defineBuiltinFunction(agent, "fromCharCode", fromCharCode, 1, realm);
        try object.defineBuiltinFunction(agent, "fromCodePoint", fromCodePoint, 1, realm);
        try object.defineBuiltinFunction(agent, "raw", raw, 1, realm);

        // 22.1.2.3 String.prototype
        // https://tc39.es/ecma262/#sec-string.prototype
        try object.defineBuiltinPropertyWithAttributes(
            agent,
            "prototype",
            Value.from(try realm.intrinsic(.string_prototype)),
            .none,
        );
    }

    /// 22.1.1.1 String ( value )
    /// https://tc39.es/ecma262/#sec-string-constructor-string-value
    fn impl(agent: *Agent, arguments: Arguments, new_target: ?*Object) Agent.Error!Value {
        const value = arguments.get(0);

        const string: *const types.String = blk: {
            // 1. If value is not present, then
            if (arguments.count() == 0) {
                // a. Let string be the empty String.
                break :blk .empty;
            } else {
                // 2. Else,
                // a. If NewTarget is undefined and value is a Symbol, return
                //    SymbolDescriptiveString(value).
                if (new_target == null and value.isSymbol()) {
                    return Value.from(try value.asSymbol().descriptiveString(agent));
                }

                // b. Let string be ? ToString(value).
                break :blk try value.toString(agent);
            }
        };

        // 3. If NewTarget is undefined, return string.
        if (new_target == null) return Value.from(string);

        // 4. Return StringCreate(string, ? GetPrototypeFromConstructor(NewTarget,
        //    "%String.prototype%")).
        const string_obj = try stringCreate(
            agent,
            string,
            try getPrototypeFromConstructor(agent, new_target.?, .string_prototype),
        );
        return Value.from(&string_obj.object);
    }

    /// 22.1.2.1 String.fromCharCode ( ...codeUnits )
    /// https://tc39.es/ecma262/#sec-string.fromcharcode
    fn fromCharCode(agent: *Agent, _: Value, arguments: Arguments) Agent.Error!Value {
        const gpa = agent.gpa;

        // 1. Let result be the empty String.
        // NOTE: This allocates the exact needed capacity upfront
        // SAFETY: This builder can use a GPA as it only stores u16 code unit segments.
        var result = try types.String.Builder.initCapacity(
            gpa,
            @intCast(arguments.count()),
        );
        defer result.deinit(gpa);

        // 2. For each element next of codeUnits, do
        for (arguments.values) |next| {
            // a. Let nextCU be the code unit whose numeric value is ℝ(? ToUint16(next)).
            const next_code_unit = try next.toUint16(agent);

            // b. Set result to the string-concatenation of result and nextCU.
            result.appendCodeUnitAssumeCapacity(next_code_unit);
        }

        // 3. Return result.
        return Value.from(try result.build(agent));
    }

    /// 22.1.2.2 String.fromCodePoint ( ...codePoints )
    /// https://tc39.es/ecma262/#sec-string.fromcodepoint
    fn fromCodePoint(agent: *Agent, _: Value, arguments: Arguments) Agent.Error!Value {
        const gpa = agent.gpa;

        // 1. Let result be the empty String.
        // NOTE: This allocates the exact needed capacity upfront
        // SAFETY: This builder can use a GPA as it only stores u21 code point segments.
        var result = try types.String.Builder.initCapacity(
            gpa,
            @intCast(arguments.count()),
        );
        defer result.deinit(gpa);

        // 2. For each element next of codePoints, do
        for (arguments.values) |next| {
            // a. Let nextCP be ? ToNumber(next).
            const next_code_point = try next.toNumber(agent);

            // b. If nextCP is not an integral Number, throw a RangeError exception.
            if (!next_code_point.isIntegral()) {
                return agent.throwException(
                    .range_error,
                    "Cannot convert non-integral number to code point",
                    .{},
                );
            }

            // c. If ℝ(nextCP) < 0 or ℝ(nextCP) > 0x10FFFF, throw a RangeError exception.
            if (next_code_point.asFloat() < 0 or next_code_point.asFloat() > 0x10FFFF) {
                return agent.throwException(
                    .range_error,
                    "Invalid code point {f}",
                    .{next_code_point},
                );
            }

            // d. Set result to the string-concatenation of result and UTF16EncodeCodePoint(
            //    ℝ(nextCP)).
            result.appendCodePointAssumeCapacity(@intFromFloat(next_code_point.asFloat()));
        }

        // 3. Assert: If codePoints is empty, then result is the empty String.
        // 4. Return result.
        return Value.from(try result.build(agent));
    }

    /// 22.1.2.4 String.raw ( template, ...substitutions )
    /// https://tc39.es/ecma262/#sec-string.raw
    fn raw(agent: *Agent, _: Value, arguments: Arguments) Agent.Error!Value {
        const template = arguments.get(0);
        const substitutions = if (arguments.count() <= 1) &[_]Value{} else arguments.values[1..];

        // 1. Let substitutionCount be the number of elements in substitutions.
        const substitution_count = substitutions.len;

        // 2. Let cooked be ? ToObject(template).
        const cooked = try template.toObject(agent);

        // 3. Let literals be ? ToObject(? Get(cooked, "raw")).
        const literals = try (try cooked.get(agent, PropertyKey.from("raw"))).toObject(agent);

        // 4. Let literalCount be ? LengthOfArrayLike(literals).
        const literal_count = try literals.lengthOfArrayLike(agent);

        // 5. If literalCount ≤ 0, return the empty String.
        if (literal_count == 0) return Value.from("");

        // 6. Let result be the empty String.
        var result: types.String.Builder = .empty;
        defer result.deinit(agent.gc_allocator);

        // 7. Let nextIndex be 0.
        var next_index: u53 = 0;

        // 8. Repeat,
        while (true) : (next_index += 1) {
            // a. Let nextLiteralValue be ? Get(literals, ! ToString(𝔽(nextIndex))).
            const next_literal_value = try literals.get(agent, PropertyKey.from(next_index));

            // b. Let nextLiteral be ? ToString(nextLiteralValue).
            const next_literal = try next_literal_value.toString(agent);

            // c. Set result to the string-concatenation of result and nextLiteral.
            try result.appendString(agent.gc_allocator, next_literal);

            // d. If nextIndex + 1 = literalCount, return result.
            if (next_index + 1 == literal_count) return Value.from(try result.build(agent));

            // e. If nextIndex < substitutionCount, then
            if (next_index < substitution_count) {
                // i. Let nextSubValue be substitutions[nextIndex].
                const next_substitution_value = substitutions[@intCast(next_index)];

                // ii. Let nextSub be ? ToString(nextSubValue).
                const next_substitution = try next_substitution_value.toString(agent);

                // iii. Set result to the string-concatenation of result and nextSub.
                try result.appendString(agent.gc_allocator, next_substitution);
            }

            // f. Set nextIndex to nextIndex + 1.
        }
    }
};

/// 22.1.3 Properties of the String Prototype Object
/// https://tc39.es/ecma262/#sec-properties-of-the-string-prototype-object
pub const prototype = struct {
    pub fn create(agent: *Agent, realm: *Realm) std.mem.Allocator.Error!*Object {
        const string = try stringCreate(
            agent,
            .empty,
            try realm.intrinsic(.object_prototype),
        );
        return &string.object;
    }

    pub fn init(agent: *Agent, realm: *Realm, object: *Object) std.mem.Allocator.Error!void {
        try object.defineBuiltinFunction(agent, "at", at, 1, realm);
        try object.defineBuiltinFunction(agent, "charAt", charAt, 1, realm);
        try object.defineBuiltinFunction(agent, "charCodeAt", charCodeAt, 1, realm);
        try object.defineBuiltinFunction(agent, "codePointAt", codePointAt, 1, realm);
        try object.defineBuiltinFunction(agent, "concat", concat, 1, realm);
        try object.defineBuiltinFunction(agent, "endsWith", endsWith, 1, realm);
        try object.defineBuiltinFunction(agent, "includes", includes, 1, realm);
        try object.defineBuiltinFunction(agent, "indexOf", indexOf, 1, realm);
        try object.defineBuiltinFunction(agent, "isWellFormed", isWellFormed, 0, realm);
        try object.defineBuiltinFunction(agent, "lastIndexOf", lastIndexOf, 1, realm);
        try object.defineBuiltinFunction(agent, "localeCompare", localeCompare, 1, realm);
        try object.defineBuiltinFunction(agent, "match", match, 1, realm);
        try object.defineBuiltinFunction(agent, "matchAll", matchAll, 1, realm);
        try object.defineBuiltinFunction(agent, "normalize", normalize, 0, realm);
        try object.defineBuiltinFunction(agent, "padEnd", padEnd, 1, realm);
        try object.defineBuiltinFunction(agent, "padStart", padStart, 1, realm);
        try object.defineBuiltinFunction(agent, "repeat", repeat, 1, realm);
        try object.defineBuiltinFunction(agent, "replace", replace, 2, realm);
        try object.defineBuiltinFunction(agent, "replaceAll", replaceAll, 2, realm);
        try object.defineBuiltinFunction(agent, "search", search, 1, realm);
        try object.defineBuiltinFunction(agent, "slice", slice, 2, realm);
        try object.defineBuiltinFunction(agent, "split", split, 2, realm);
        try object.defineBuiltinFunction(agent, "startsWith", startsWith, 1, realm);
        try object.defineBuiltinFunction(agent, "substring", substring, 2, realm);
        try object.defineBuiltinFunction(agent, "toLocaleLowerCase", toLocaleLowerCase, 0, realm);
        try object.defineBuiltinFunction(agent, "toLocaleUpperCase", toLocaleUpperCase, 0, realm);
        try object.defineBuiltinFunction(agent, "toLowerCase", toLowerCase, 0, realm);
        try object.defineBuiltinFunction(agent, "toString", toString, 0, realm);
        try object.defineBuiltinFunction(agent, "toUpperCase", toUpperCase, 0, realm);
        try object.defineBuiltinFunction(agent, "toWellFormed", toWellFormed, 0, realm);
        try object.defineBuiltinFunction(agent, "trim", trim, 0, realm);
        try object.defineBuiltinFunction(agent, "trimEnd", trimEnd, 0, realm);
        try object.defineBuiltinFunction(agent, "trimStart", trimStart, 0, realm);
        try object.defineBuiltinFunction(agent, "valueOf", valueOf, 0, realm);
        try object.defineBuiltinFunction(agent, "Symbol.iterator", @"Symbol.iterator", 0, realm);

        // 22.1.3.6 String.prototype.constructor
        // https://tc39.es/ecma262/#sec-string.prototype.constructor
        try object.defineBuiltinProperty(
            agent,
            "constructor",
            Value.from(try realm.intrinsic(.string)),
        );

        if (build_options.enable_annex_b) {
            try object.defineBuiltinFunction(agent, "substr", substr, 2, realm);
            try object.defineBuiltinFunction(agent, "anchor", anchor, 1, realm);
            try object.defineBuiltinFunction(agent, "big", big, 0, realm);
            try object.defineBuiltinFunction(agent, "blink", blink, 0, realm);
            try object.defineBuiltinFunction(agent, "bold", bold, 0, realm);
            try object.defineBuiltinFunction(agent, "fixed", fixed, 0, realm);
            try object.defineBuiltinFunction(agent, "fontcolor", fontcolor, 1, realm);
            try object.defineBuiltinFunction(agent, "fontsize", fontsize, 1, realm);
            try object.defineBuiltinFunction(agent, "italics", italics, 0, realm);
            try object.defineBuiltinFunction(agent, "link", link, 1, realm);
            try object.defineBuiltinFunction(agent, "small", small, 0, realm);
            try object.defineBuiltinFunction(agent, "strike", strike, 0, realm);
            try object.defineBuiltinFunction(agent, "sub", sub, 0, realm);
            try object.defineBuiltinFunction(agent, "sup", sup, 0, realm);

            // B.2.2.15 String.prototype.trimLeft ( )
            // https://tc39.es/ecma262/#String.prototype.trimleft
            const string_prototype_trim_start = object.getPropertyValueDirect(PropertyKey.from("trimStart"));
            try object.defineBuiltinProperty(agent, "trimLeft", string_prototype_trim_start);

            // B.2.2.16 String.prototype.trimRight ( )
            // https://tc39.es/ecma262/#String.prototype.trimright
            const string_prototype_trim_end = object.getPropertyValueDirect(PropertyKey.from("trimEnd"));
            try object.defineBuiltinProperty(agent, "trimRight", string_prototype_trim_end);
        }
    }

    /// 22.1.3.35.1 ThisStringValue ( arg )
    /// https://tc39.es/ecma262/#sec-thisstringvalue
    fn thisStringValue(agent: *Agent, arg: Value) error{ExceptionThrown}!*const types.String {
        // 1. If arg is a String, return arg.
        if (arg.isString()) return arg.asString();

        // 2. If arg is an Object and arg has a [[StringData]] internal slot, then
        if (arg.castObject(String)) |string| {
            // a. Let string be arg.[[StringData]].
            // b. Assert: string is a String.
            // c. Return string.
            return string.fields.string_data;
        }

        // 3. Throw a TypeError exception.
        return agent.throwException(
            .type_error,
            "This value must be a string or String object",
            .{},
        );
    }

    /// 22.1.3.1 String.prototype.at ( index )
    /// https://tc39.es/ecma262/#sec-string.prototype.at
    fn at(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const index = arguments.get(0);

        // 1. Let thisValue be the this value.

        // 2. Perform ? RequireObjectCoercible(thisValue).
        try this_value.requireObjectCoercible(agent);

        // 3. Let string be ? ToString(thisValue).
        const string = try this_value.toString(agent);

        // 4. Let length be the length of string.
        const length = string.length;

        // 5. Let k be ? ToAbsoluteIndex(index, length).
        const k_f64 = try index.toAbsoluteIndex(agent, length);

        // 6. If k < 0 or k ≥ length, return undefined.
        if (k_f64 < 0 or k_f64 >= @as(f64, @floatFromInt(length))) return .undefined;
        const k = std.math.lossyCast(u32, k_f64);

        // 7. Return the substring of string from k to k + 1.
        return Value.from(try string.substring(agent, k, k + 1));
    }

    /// 22.1.3.2 String.prototype.charAt ( position )
    /// https://tc39.es/ecma262/#sec-string.prototype.charat
    fn charAt(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const position_value = arguments.get(0);

        // 1. Let thisValue be the this value.

        // 2. Perform ? RequireObjectCoercible(thisValue).
        try this_value.requireObjectCoercible(agent);

        // 3. Let string be ? ToString(thisValue).
        const string = try this_value.toString(agent);

        // 4. Set position to ? ToIntegerOrInfinity(position).
        const position_f64 = try position_value.toIntegerOrInfinity(agent);

        // 5. Let size be the length of string.
        const size = string.length;

        // 6. If position < 0 or position ≥ size, return the empty String.
        if (position_f64 < 0 or position_f64 >= @as(f64, @floatFromInt(size))) return Value.from("");
        const position = std.math.lossyCast(u32, position_f64);

        // 7. Return the substring of string from position to position + 1.
        return Value.from(try string.substring(agent, position, position + 1));
    }

    /// 22.1.3.3 String.prototype.charCodeAt ( position )
    /// https://tc39.es/ecma262/#sec-string.prototype.charcodeat
    fn charCodeAt(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const position_value = arguments.get(0);

        // 1. Let thisValue be the this value.

        // 2. Perform ? RequireObjectCoercible(thisValue).
        try this_value.requireObjectCoercible(agent);

        // 3. Let string be ? ToString(thisValue).
        const string = try this_value.toString(agent);

        // 4. Set position to ? ToIntegerOrInfinity(position).
        const position_f64 = try position_value.toIntegerOrInfinity(agent);

        // 5. Let size be the length of string.
        const size = string.length;

        // 6. If position < 0 or position ≥ size, return NaN.
        if (position_f64 < 0 or position_f64 >= @as(f64, @floatFromInt(size))) return .nan;
        const position = std.math.lossyCast(u32, position_f64);

        // 7. Return the Number value for the numeric value of the code unit at index position
        //    within the String string.
        return Value.from(string.codeUnitAt(position));
    }

    /// 22.1.3.4 String.prototype.codePointAt ( position )
    /// https://tc39.es/ecma262/#sec-string.prototype.codepointat
    fn codePointAt(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const position_value = arguments.get(0);

        // 1. Let thisValue be the this value.

        // 2. Perform ? RequireObjectCoercible(thisValue).
        try this_value.requireObjectCoercible(agent);

        // 3. Let string be ? ToString(thisValue).
        const string = try this_value.toString(agent);

        // 4. Set position to ? ToIntegerOrInfinity(position).
        const position_f64 = try position_value.toIntegerOrInfinity(agent);

        // 5. Let size be the length of string.
        const size = string.length;

        // 6. If position < 0 or position ≥ size, return undefined.
        if (position_f64 < 0 or position_f64 >= @as(f64, @floatFromInt(size))) return .undefined;
        const position = std.math.lossyCast(u32, position_f64);

        // 7. Let codePoint be CodePointAt(string, position).
        const code_point = string.codePointAt(position);

        // 8. Return 𝔽(codePoint.[[CodePoint]]).
        return Value.from(code_point.code_point);
    }

    /// 22.1.3.5 String.prototype.concat ( ...args )
    /// https://tc39.es/ecma262/#sec-string.prototype.concat
    fn concat(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        // 1. Let thisValue be the this value.

        // 2. Perform ? RequireObjectCoercible(thisValue).
        try this_value.requireObjectCoercible(agent);

        // 3. Let string be ? ToString(thisValue).
        const string = try this_value.toString(agent);

        // 4. Let result be string.
        // NOTE: This allocates the exact needed capacity upfront
        var result = try types.String.Builder.initCapacity(agent.gc_allocator, @intCast(arguments.count() + 1));
        defer result.deinit(agent.gc_allocator);
        result.appendStringAssumeCapacity(string);

        // 5. For each element next of args, do
        for (arguments.values) |next| {
            // a. Let nextString be ? ToString(next).
            const next_string = try next.toString(agent);

            // b. Set result to the string-concatenation of result and nextString.
            result.appendStringAssumeCapacity(next_string);
        }

        // 6. Return result.
        return Value.from(try result.build(agent));
    }

    /// 22.1.3.7 String.prototype.endsWith ( searchString [ , endPosition ] )
    /// https://tc39.es/ecma262/#sec-string.prototype.endswith
    fn endsWith(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const search_value = arguments.get(0);
        const end_position = arguments.get(1);

        // 1. Let thisValue be the this value.

        // 2. Perform ? RequireObjectCoercible(thisValue).
        try this_value.requireObjectCoercible(agent);

        // 3. Let string be ? ToString(thisValue).
        const string = try this_value.toString(agent);

        // 4. Let isRegexp be ? IsRegExp(searchString).
        const is_regexp = try search_value.isRegExp(agent);

        // 5. If isRegexp is true, throw a TypeError exception.
        if (is_regexp) {
            return agent.throwException(
                .type_error,
                "String.prototype.endsWith() argument must not be a regular expression",
                .{},
            );
        }

        // 6. Set searchString to ? ToString(searchString).
        const search_string = try search_value.toString(agent);

        // 7. Let length be the length of string.
        const length = string.length;

        // 8. If endPosition is undefined, let end be length; else let end be the result of clamping
        //    ? ToIntegerOrInfinity(endPosition) between 0 and length.
        const end = if (end_position.isUndefined())
            length
        else
            std.math.clamp(
                std.math.lossyCast(u32, try end_position.toIntegerOrInfinity(agent)),
                0,
                length,
            );

        // 9. Let searchLength be the length of searchString.
        const search_length = search_string.length;

        // 10. If searchLength = 0, return true.
        if (search_length == 0) return .true;

        // 11. Let start be end - searchLength.
        // 12. If start < 0, return false.
        const start = std.math.sub(u32, end, search_length) catch return .false;

        // 13. Let substring be the substring of string from start to end.
        const substring_ = try string.substring(agent, start, end);

        // 14. If substring is searchString, return true.
        if (substring_.eql(search_string)) return .true;

        // 15. Return false.
        return .false;
    }

    /// 22.1.3.8 String.prototype.includes ( searchString [ , position ] )
    /// https://tc39.es/ecma262/#sec-string.prototype.includes
    fn includes(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const search_value = arguments.get(0);
        const position_value = arguments.get(1);

        // 1. Let thisValue be the this value.

        // 2. Perform ? RequireObjectCoercible(thisValue).
        try this_value.requireObjectCoercible(agent);

        // 3. Let string be ? ToString(thisValue).
        const string = try this_value.toString(agent);

        // 4. Let isRegexp be ? IsRegExp(searchString).
        const is_regexp = try search_value.isRegExp(agent);

        // 5. If isRegexp is true, throw a TypeError exception.
        if (is_regexp) {
            return agent.throwException(
                .type_error,
                "String.prototype.includes() argument must not be a regular expression",
                .{},
            );
        }

        // 6. Set searchString to ? ToString(searchString).
        const search_string = try search_value.toString(agent);

        // 7. Let length be the length of string.
        const length = string.length;

        // 8. Let start be the result of clamping ? ToIntegerOrInfinity(position) between 0 and
        //    length.
        // 9. Assert: If position is undefined, then start is 0.
        const start = std.math.clamp(
            std.math.lossyCast(u32, try position_value.toIntegerOrInfinity(agent)),
            0,
            length,
        );

        // 10. Let index be StringIndexOf(string, searchString, start).
        const index = string.indexOf(search_string, start);

        // 11. If index is not-found, return false.
        // 12. Return true.
        return Value.from(index != null);
    }

    /// 22.1.3.9 String.prototype.indexOf ( searchString [ , position ] )
    /// https://tc39.es/ecma262/#sec-string.prototype.indexof
    fn indexOf(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const search_value = arguments.get(0);
        const position_value = arguments.get(1);

        // 1. Let thisValue be the this value.

        // 2. Perform ? RequireObjectCoercible(thisValue).
        try this_value.requireObjectCoercible(agent);

        // 3. Let string be ? ToString(thisValue).
        const string = try this_value.toString(agent);

        // 4. Set searchString to ? ToString(searchString).
        const search_string = try search_value.toString(agent);

        // 5. Let length be the length of string.
        const length = string.length;

        // 6. Let start be the result of clamping ? ToIntegerOrInfinity(position) between 0 and
        //    length.
        // 7. Assert: If position is undefined, then start is 0.
        const start = std.math.clamp(
            std.math.lossyCast(u32, try position_value.toIntegerOrInfinity(agent)),
            0,
            length,
        );

        // 8. Let result be StringIndexOf(string, searchString, start).
        // 9. If result is not-found, return -1𝔽.
        // 10. Return 𝔽(result).
        return if (string.indexOf(search_string, start)) |result|
            Value.from(@as(u53, @intCast(result)))
        else
            Value.from(-1);
    }

    /// 22.1.3.10 String.prototype.isWellFormed ( )
    /// https://tc39.es/ecma262/#sec-string.prototype.iswellformed
    fn isWellFormed(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let thisValue be the this value.

        // 2. Perform ? RequireObjectCoercible(thisValue).
        try this_value.requireObjectCoercible(agent);

        // 3. Let string be ? ToString(thisValue).
        const string = try this_value.toString(agent);

        // 4. Return IsStringWellFormedUnicode(string).
        return Value.from(string.isWellFormedUnicode());
    }

    /// 22.1.3.11 String.prototype.lastIndexOf ( searchString [ , position ] )
    /// https://tc39.es/ecma262/#sec-string.prototype.lastindexof
    fn lastIndexOf(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const search_value = arguments.get(0);
        const position_value = arguments.get(1);

        // 1. Let thisValue be the this value.

        // 2. Perform ? RequireObjectCoercible(thisValue).
        try this_value.requireObjectCoercible(agent);

        // 3. Let string be ? ToString(thisValue).
        const string = try this_value.toString(agent);

        // 4. Set searchString to ? ToString(searchString).
        const search_string = try search_value.toString(agent);

        // 5. Let numberPosition be ? ToNumber(position).
        const number_position = try position_value.toNumber(agent);

        // 6. Let length be the length of string.
        const length = string.length;

        // 7. Let searchLength be the length of searchString.
        const search_length = search_string.length;

        // 8. Let maxStart be length - searchLength.
        // 9. If maxStart < 0, return -1𝔽.
        if (length < search_length) return Value.from(-1);
        const max_start = length - search_length;

        // 10. If numberPosition is NaN, let start be maxStart; else let start be the result of
        //     clamping ! ToIntegerOrInfinity(numberPosition) between 0 and maxStart.
        // 11. Assert: If position is undefined, then start is maxStart.
        const start = if (number_position.isNan())
            max_start
        else
            std.math.clamp(
                std.math.lossyCast(u32, Value.from(number_position).toIntegerOrInfinity(agent) catch unreachable),
                0,
                max_start,
            );

        // 12. Let result be StringLastIndexOf(string, searchString, start).
        // 13. If result is not-found, return -1𝔽.
        // 14. Return 𝔽(result).
        return if (string.lastIndexOf(search_string, start)) |result|
            Value.from(@as(u53, @intCast(result)))
        else
            Value.from(-1);
    }

    /// 22.1.3.12 String.prototype.localeCompare ( that [ , reserved1 [ , reserved2 ] ] )
    /// https://tc39.es/ecma262/#sec-string.prototype.localecompare
    fn localeCompare(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        if (build_options.enable_intl) {
            return localeCompareIntl(agent, this_value, arguments);
        }

        const gpa = agent.gpa;
        const that = arguments.get(0);

        // 1. Let thisValue be the this value.

        // 2. Perform ? RequireObjectCoercible(thisValue).
        try this_value.requireObjectCoercible(agent);

        // 3. Let string be ? ToString(thisValue).
        const string = try this_value.toString(agent);

        // 4. Let thatValue be ? ToString(that).
        const that_value = try that.toString(agent);

        const order = if (string.isAscii() and that_value.isAscii()) blk: {
            break :blk std.mem.order(u8, string.asAscii(), that_value.asAscii());
        } else if (string.isUtf16() and that_value.isUtf16()) blk: {
            break :blk std.mem.order(u16, string.asUtf16(), that_value.asUtf16());
        } else if (string.isAscii() and that_value.isUtf16()) blk: {
            const string_utf16 = try string.toUtf16(gpa);
            defer gpa.free(string_utf16);
            break :blk std.mem.order(u16, string_utf16, that_value.asUtf16());
        } else if (string.isUtf16() and that_value.isAscii()) blk: {
            const that_value_utf16 = try that_value.toUtf16(gpa);
            defer gpa.free(that_value_utf16);
            break :blk std.mem.order(u16, string.asUtf16(), that_value_utf16);
        } else unreachable;
        return switch (order) {
            .lt => Value.from(-1),
            .gt => Value.from(1),
            .eq => Value.from(0),
        };
    }

    /// 20.1.1 String.prototype.localeCompare ( that [ , locales [ , options ] ] )
    /// https://tc39.es/ecma402/#sup-String.prototype.localeCompare
    fn localeCompareIntl(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const that = arguments.get(0);
        const locales = arguments.get(1);
        const options = arguments.get(2);

        // 1. Let thisValue be ? RequireObjectCoercible(this value).
        try this_value.requireObjectCoercible(agent);

        // 2. Let string be ? ToString(thisValue).
        const string = try this_value.toString(agent);

        // 3. Let thatValue be ? ToString(that).
        const that_value = try that.toString(agent);

        const realm = agent.currentRealm();

        // 4. Let collator be ? Construct(%Intl.Collator%, « locales, options »).
        const collator_constructor = try realm.intrinsic(.intl_collator);
        const collator = try collator_constructor.construct(
            agent,
            &.{ locales, options },
            null,
        );

        // 5. Return CompareStrings(collator, string, thatValue).
        return builtins.intl.collator.compareStrings(
            agent.gc_allocator,
            collator.as(builtins.intl.Collator),
            string,
            that_value,
        );
    }

    /// 22.1.3.13 String.prototype.match ( regexpOrPattern )
    /// https://tc39.es/ecma262/#sec-string.prototype.match
    fn match(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const regexp_or_pattern = arguments.get(0);

        // 1. Let thisValue be the this value.

        // 2. Perform ? RequireObjectCoercible(thisValue).
        try this_value.requireObjectCoercible(agent);

        // 3. If regexpOrPattern is an Object, then
        if (regexp_or_pattern.isObject()) {
            // a. Let matcher be ? GetMethod(regexpOrPattern, %Symbol.match%).
            const maybe_matcher = try regexp_or_pattern.getMethod(
                agent,
                PropertyKey.from(agent.well_known_symbols.match),
            );

            // b. If matcher is not undefined, then
            if (maybe_matcher) |matcher| {
                // i. Return ? Call(matcher, regexpOrPattern, « thisValue »).
                return matcher.call(agent, regexp_or_pattern, &.{this_value});
            }
        }

        // 4. Let string be ? ToString(thisValue).
        const string = try this_value.toString(agent);

        // 5. Let regexp be ? RegExpCreate(regexpOrPattern, undefined).
        const regexp = try regExpCreate(agent, regexp_or_pattern, .undefined);

        // 6. Return ? Invoke(regexp, %Symbol.match%, « string »).
        return regexp.object.invoke(
            agent,
            PropertyKey.from(agent.well_known_symbols.match),
            &.{Value.from(string)},
        );
    }

    /// 22.1.3.14 String.prototype.matchAll ( regexpOrPattern )
    /// https://tc39.es/ecma262/#sec-string.prototype.matchall
    fn matchAll(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const regexp_or_pattern = arguments.get(0);

        // 1. Let thisValue be the this value.

        // 2. Perform ? RequireObjectCoercible(thisValue).
        try this_value.requireObjectCoercible(agent);

        // 3. If regexpOrPattern is an Object, then
        if (regexp_or_pattern.isObject()) {
            // a. Let isRegexp be ? IsRegExp(regexpOrPattern).
            const is_regexp = try regexp_or_pattern.isRegExp(agent);

            // b. If isRegexp is true, then
            if (is_regexp) {
                // i. Let flags be ? Get(regexpOrPattern, "flags").
                const flags = try regexp_or_pattern.asObject().get(
                    agent,
                    PropertyKey.from("flags"),
                );

                // ii. Perform ? RequireObjectCoercible(flags).
                try flags.requireObjectCoercible(agent);

                // iii. If ? ToString(flags) does not contain "g", throw a TypeError exception.
                if ((try flags.toString(agent)).indexOf(types.String.fromLiteral("g"), 0) == null) {
                    return agent.throwException(
                        .type_error,
                        "RegExp object must have the 'g' flag set",
                        .{},
                    );
                }
            }

            // c. Let matcher be ? GetMethod(regexpOrPattern, %Symbol.matchAll%).
            const maybe_matcher = try regexp_or_pattern.getMethod(
                agent,
                PropertyKey.from(agent.well_known_symbols.match_all),
            );

            // d. If matcher is not undefined, then
            if (maybe_matcher) |matcher| {
                // i. Return ? Call(matcher, regexpOrPattern, « thisValue »).
                return matcher.call(agent, regexp_or_pattern, &.{this_value});
            }
        }

        // 4. Let string be ? ToString(thisValue).
        const string = try this_value.toString(agent);

        // 5. Let regexp be ? RegExpCreate(regexpOrPattern, "g").
        const regexp = try regExpCreate(agent, regexp_or_pattern, Value.from("g"));

        // 6. Return ? Invoke(regexp, %Symbol.matchAll%, « string »).
        return regexp.object.invoke(
            agent,
            PropertyKey.from(agent.well_known_symbols.match_all),
            &.{Value.from(string)},
        );
    }

    /// 22.1.3.15 String.prototype.normalize ( [ form ] )
    /// https://tc39.es/ecma262/#sec-string.prototype.normalize
    fn normalize(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        // Not an Intl function but we need ICU4X regardless.
        if (!build_options.enable_intl) {
            return agent.throwException(.internal_error, "Intl support is disabled", .{});
        }

        const gpa = agent.gpa;
        const form_value = arguments.get(0);

        // 1. Let thisValue be the this value.

        // 2. Perform ? RequireObjectCoercible(thisValue).
        try this_value.requireObjectCoercible(agent);

        // 3. Let string be ? ToString(thisValue).
        const string = try this_value.toString(agent);

        // 4. If form is undefined, set form to "NFC".
        // 5. Else, set form to ? ToString(form).
        const form = if (form_value.isUndefined())
            types.String.fromLiteral("NFC")
        else
            try form_value.toString(agent);

        // 6. If form is not one of "NFC", "NFD", "NFKC", or "NFKD", throw a RangeError exception.
        // 7. Let normal be the String value that is the result of normalizing string into the
        //    normalization form named by form as specified in the latest Unicode Standard,
        //    Normalization Forms.
        // NOTE: ICU4X only supports UTF-8 for this, so unpaired surrogates are not handled
        //       correctly here.
        const utf8 = try string.toUtf8(gpa);
        defer gpa.free(utf8);
        const utf8_normalized = if (form.eql(types.String.fromLiteral("NFC"))) blk: {
            const normalizer: icu4zig.ComposingNormalizer = .init(.nfc);
            defer normalizer.deinit();
            break :blk try normalizer.normalize(agent.gc_allocator, utf8);
        } else if (form.eql(types.String.fromLiteral("NFD"))) blk: {
            const normalizer: icu4zig.DecomposingNormalizer = .init(.nfd);
            defer normalizer.deinit();
            break :blk try normalizer.normalize(agent.gc_allocator, utf8);
        } else if (form.eql(types.String.fromLiteral("NFKC"))) blk: {
            const normalizer: icu4zig.ComposingNormalizer = .init(.nfkc);
            defer normalizer.deinit();
            break :blk try normalizer.normalize(agent.gc_allocator, utf8);
        } else if (form.eql(types.String.fromLiteral("NFKD"))) blk: {
            const normalizer: icu4zig.DecomposingNormalizer = .init(.nfkd);
            defer normalizer.deinit();
            break :blk try normalizer.normalize(agent.gc_allocator, utf8);
        } else {
            return agent.throwException(.range_error, "Invalid normalization form", .{});
        };

        // 8. Return normal.
        return Value.from(try types.String.fromUtf8(agent, utf8_normalized));
    }

    /// 22.1.3.16 String.prototype.padEnd ( maxLength [ , fillString ] )
    /// https://tc39.es/ecma262/#sec-string.prototype.padend
    fn padEnd(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const max_length = arguments.get(0);
        const fill_string = arguments.get(1);

        // 1. Let thisValue be the this value.

        // 2. Perform ? RequireObjectCoercible(thisValue).
        try this_value.requireObjectCoercible(agent);

        // 3. Return ? StringPaddingBuiltinsImpl(thisValue, maxLength, fillString, end).
        return Value.from(
            try stringPaddingBuiltinsImpl(agent, this_value, max_length, fill_string, .end),
        );
    }

    /// 22.1.3.17 String.prototype.padStart ( maxLength [ , fillString ] )
    /// https://tc39.es/ecma262/#sec-string.prototype.padstart
    fn padStart(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const max_length = arguments.get(0);
        const fill_string = arguments.get(1);

        // 1. Let thisValue be the this value.

        // 2. Perform ? RequireObjectCoercible(thisValue).
        try this_value.requireObjectCoercible(agent);

        // 3. Return ? StringPaddingBuiltinsImpl(thisValue, maxLength, fillString, start).
        return Value.from(
            try stringPaddingBuiltinsImpl(agent, this_value, max_length, fill_string, .start),
        );
    }

    /// 22.1.3.17.1 StringPaddingBuiltinsImpl ( thisValue, maxLength, fillString, placement )
    /// https://tc39.es/ecma262/#sec-stringpaddingbuiltinsimpl
    fn stringPaddingBuiltinsImpl(
        agent: *Agent,
        this_value: Value,
        max_length: Value,
        fill_string_value: Value,
        placement: StringPadPlacement,
    ) Agent.Error!*const types.String {
        // 1. Let string be ? ToString(thisValue).
        const string = try this_value.toString(agent);

        // 2. Let intMaxLength be ℝ(? ToLength(maxLength)).
        const int_max_length = try max_length.toLength(agent);

        // 3. Let stringLength be the length of string.
        const string_length = string.length;

        // 4. If intMaxLength ≤ stringLength, return string.
        if (int_max_length <= string_length) return string;

        // 5. If fillString is undefined, set fillString to the String value consisting solely of
        //    the code unit 0x0020 (SPACE).
        // 6. Else, set fillString to ? ToString(fillString).
        const fill_string = if (fill_string_value.isUndefined())
            types.String.fromLiteral(" ")
        else
            try fill_string_value.toString(agent);

        if (int_max_length > std.math.maxInt(u32)) {
            return agent.throwException(.range_error, "Maximum string length exceeded", .{});
        }

        // 7. Return StringPad(string, intMaxLength, fillString, placement).
        return stringPad(
            agent,
            string,
            @intCast(int_max_length),
            fill_string,
            placement,
        );
    }

    /// 22.1.3.18 String.prototype.repeat ( count )
    /// https://tc39.es/ecma262/#sec-string.prototype.repeat
    fn repeat(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const count = arguments.get(0);

        // 1. Let thisValue be the this value.

        // 2. Perform ? RequireObjectCoercible(thisValue).
        try this_value.requireObjectCoercible(agent);

        // 3. Let string be ? ToString(thisValue).
        const string = try this_value.toString(agent);

        // 4. Let n be ? ToIntegerOrInfinity(count).
        const n = try count.toIntegerOrInfinity(agent);

        // 5. If n < 0 or n = +∞, throw a RangeError exception.
        if (n < 0 or std.math.isPositiveInf(n)) {
            return agent.throwException(
                .range_error,
                "Repeat count must be a positive finite number",
                .{},
            );
        }

        // 6. If n = 0, return the empty String.
        if (n == 0) return Value.from("");

        if (string.isEmpty()) return Value.from("");

        // 7. Return the String value that is made from n copies of string appended together.
        const n_u32 = std.math.lossyCast(u32, n);
        return Value.from(try string.repeat(agent, n_u32));
    }

    /// 22.1.3.19 String.prototype.replace ( searchValue, replaceValue )
    /// https://tc39.es/ecma262/#sec-string.prototype.replace
    fn replace(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const search_value = arguments.get(0);
        var replace_value = arguments.get(1);

        // 1. Let thisValue be the this value.

        // 2. Perform ? RequireObjectCoercible(thisValue).
        try this_value.requireObjectCoercible(agent);

        // 3. If searchValue is an Object, then
        if (search_value.isObject()) {
            // a. Let replacer be ? GetMethod(searchValue, %Symbol.replace%).
            const maybe_replacer = try search_value.getMethod(
                agent,
                PropertyKey.from(agent.well_known_symbols.replace),
            );

            // b. If replacer is not undefined, then
            if (maybe_replacer) |replacer| {
                // i. Return ? Call(replacer, searchValue, « thisValue, replaceValue »).
                return replacer.call(agent, search_value, &.{ this_value, replace_value });
            }
        }

        // 4. Let string be ? ToString(thisValue).
        const string = try this_value.toString(agent);

        // 5. Let searchString be ? ToString(searchValue).
        const search_string = try search_value.toString(agent);

        // 6. Let functionalReplace be IsCallable(replaceValue).
        const functional_replace = replace_value.isCallable();

        // 7. If functionalReplace is false, then
        if (!functional_replace and !replace_value.isString()) {
            // a. Set replaceValue to ? ToString(replaceValue).
            replace_value = Value.from(try replace_value.toString(agent));
        }

        // 8. Let searchLength be the length of searchString.
        const search_length = search_string.length;

        // 9. Let position be StringIndexOf(string, searchString, 0).
        const position = string.indexOf(search_string, 0) orelse {
            // 10. If position is not-found, return string.
            return Value.from(string);
        };

        // 11. Let preceding be the substring of string from 0 to position.
        const preceding = try string.substring(agent, 0, position);

        // 12. Let following be the substring of string from position + searchLength.
        const following = try string.substring(agent, position + search_length, null);

        // 13. If functionalReplace is true, then
        const replacement = if (functional_replace) blk: {
            // a. Let replacement be ? ToString(? Call(replaceValue, undefined, « searchString,
            //    𝔽(position), string »)).
            break :blk try (try replace_value.call(
                agent,
                .undefined,
                &.{
                    Value.from(search_string),
                    Value.from(@as(f64, @floatFromInt(position))),
                    Value.from(string),
                },
            )).toString(agent);
        } else blk: {
            // 14. Else,
            // a. Assert: replaceValue is a String.
            std.debug.assert(replace_value.isString());

            // b. Let captures be a new empty List.
            // c. Let replacement be ! GetSubstitution(searchString, string, position, captures,
            //    undefined, replaceValue).
            break :blk getSubstitution(
                agent,
                search_string,
                string,
                position,
                &.{},
                null,
                replace_value.asString(),
            ) catch |err| try noexcept(err);
        };

        // 15. Return the string-concatenation of preceding, replacement, and following.
        return Value.from(
            try types.String.concat(agent, &.{ preceding, replacement, following }),
        );
    }

    /// 22.1.3.20 String.prototype.replaceAll ( searchValue, replaceValue )
    /// https://tc39.es/ecma262/#sec-string.prototype.replaceall
    fn replaceAll(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const search_value = arguments.get(0);
        var replace_value = arguments.get(1);

        // 1. Let thisValue be the this value.

        // 2. Perform ? RequireObjectCoercible(thisValue).
        try this_value.requireObjectCoercible(agent);

        // 3. If searchValue is an Object, then
        if (search_value.isObject()) {
            // a. Let isRegexp be ? IsRegExp(searchValue).
            const is_regexp = try search_value.isRegExp(agent);

            // b. If isRegexp is true, then
            if (is_regexp) {
                // i. Let flags be ? Get(searchValue, "flags").
                const flags = try search_value.get(agent, PropertyKey.from("flags"));

                // ii. Perform ? RequireObjectCoercible(flags).
                try flags.requireObjectCoercible(agent);

                // iii. If ? ToString(flags) does not contain "g", throw a TypeError exception.
                if ((try flags.toString(agent)).indexOf(types.String.fromLiteral("g"), 0) == null) {
                    return agent.throwException(
                        .type_error,
                        "RegExp object must have the 'g' flag set",
                        .{},
                    );
                }
            }

            // c. Let replacer be ? GetMethod(searchValue, %Symbol.replace%).
            const maybe_replacer = try search_value.getMethod(
                agent,
                PropertyKey.from(agent.well_known_symbols.replace),
            );

            // d. If replacer is not undefined, then
            if (maybe_replacer) |replacer| {
                // i. Return ? Call(replacer, searchValue, « thisValue, replaceValue »).
                return replacer.call(agent, search_value, &.{ this_value, replace_value });
            }
        }

        // 4. Let string be ? ToString(thisValue).
        const string = try this_value.toString(agent);

        // 5. Let searchString be ? ToString(searchValue).
        const search_string = try search_value.toString(agent);

        // 6. Let functionalReplace be IsCallable(replaceValue).
        const functional_replace = replace_value.isCallable();

        // 7. If functionalReplace is false, then
        if (!functional_replace and !replace_value.isString()) {
            // a. Set replaceValue to ? ToString(replaceValue).
            replace_value = Value.from(try replace_value.toString(agent));
        }

        // 8. Let searchLength be the length of searchString.
        const search_length = search_string.length;

        // 9. Let advanceBy be max(1, searchLength).
        const advance_by = @max(1, search_length);

        // 10. Let matchPositions be a new empty List.
        var match_positions: std.ArrayList(u32) = .empty;
        defer match_positions.deinit(agent.gc_allocator);

        // 11. Let position be StringIndexOf(string, searchString, 0).
        var maybe_position = string.indexOf(search_string, 0);

        // 12. Repeat, while position is not not-found,
        while (maybe_position) |position| {
            // a. Append position to matchPositions.
            try match_positions.append(agent.gc_allocator, position);

            // b. Set position to StringIndexOf(string, searchString, position + advanceBy).
            maybe_position = string.indexOf(search_string, position + advance_by);
        }

        // 13. Let endOfLastMatch be 0.
        var end_of_last_match: u32 = 0;

        // 14. Let result be the empty String.
        var result: *const types.String = .empty;

        // 15. For each element matchPosition of matchPositions, do
        for (match_positions.items) |match_position| {
            // a. Let preserved be the substring of string from endOfLastMatch to matchPosition.
            const preserved = try string.substring(agent, end_of_last_match, match_position);

            // b. If functionalReplace is true, then
            const replacement = if (functional_replace) blk: {
                // i. Let replacement be ? ToString(? Call(replaceValue, undefined, « searchString,
                //    𝔽(matchPosition), string »)).
                break :blk try (try replace_value.asObject().call(
                    agent,
                    .undefined,
                    &.{
                        Value.from(search_string),
                        Value.from(match_position),
                        Value.from(string),
                    },
                )).toString(agent);
            } else blk: {
                // c. Else,
                // i. Assert: replaceValue is a String.
                std.debug.assert(replace_value.isString());

                // ii. Let captures be a new empty List.
                // iii. Let replacement be ! GetSubstitution(searchString, string, matchPosition,
                //      captures, undefined, replaceValue).
                break :blk getSubstitution(
                    agent,
                    search_string,
                    string,
                    match_position,
                    &.{},
                    null,
                    replace_value.asString(),
                ) catch |err| try noexcept(err);
            };

            // d. Set result to the string-concatenation of result, preserved, and replacement.
            result = try types.String.concat(agent, &.{ result, preserved, replacement });

            // e. Set endOfLastMatch to matchPosition + searchLength.
            end_of_last_match = match_position + search_length;
        }

        // 16. If endOfLastMatch < the length of string, then
        if (end_of_last_match < string.length) {
            // a. Set result to the string-concatenation of result and the substring of string from
            //    endOfLastMatch.
            result = try types.String.concat(agent, &.{
                result,
                try string.substring(agent, end_of_last_match, null),
            });
        }

        // 17. Return result.
        return Value.from(result);
    }

    /// 22.1.3.21 String.prototype.search ( regexpOrPattern )
    /// https://tc39.es/ecma262/#sec-string.prototype.search
    fn search(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const regexp_or_pattern = arguments.get(0);

        // 1. Let thisValue be the this value.

        // 2. Perform ? RequireObjectCoercible(thisValue).
        try this_value.requireObjectCoercible(agent);

        // 3. If regexpOrPattern is an Object, then
        if (regexp_or_pattern.isObject()) {
            // a. Let searcher be ? GetMethod(regexpOrPattern, %Symbol.search%).
            const maybe_searcher = try regexp_or_pattern.getMethod(
                agent,
                PropertyKey.from(agent.well_known_symbols.search),
            );

            // b. If searcher is not undefined, then
            if (maybe_searcher) |searcher| {
                // i. Return ? Call(searcher, regexpOrPattern, « thisValue »).
                return searcher.call(agent, regexp_or_pattern, &.{this_value});
            }
        }

        // 4. Let string be ? ToString(thisValue).
        const string = try this_value.toString(agent);

        // 5. Let regexp be ? RegExpCreate(regexpOrPattern, undefined).
        const regexp = try regExpCreate(agent, regexp_or_pattern, .undefined);

        // 6. Return ? Invoke(regexp, %Symbol.search%, « string »).
        return regexp.object.invoke(
            agent,
            PropertyKey.from(agent.well_known_symbols.search),
            &.{Value.from(string)},
        );
    }

    /// 22.1.3.22 String.prototype.slice ( start, end )
    /// https://tc39.es/ecma262/#sec-string.prototype.slice
    fn slice(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const start = arguments.get(0);
        const end = arguments.get(1);

        // 1. Let thisValue be the this value.

        // 2. Perform ? RequireObjectCoercible(thisValue).
        try this_value.requireObjectCoercible(agent);

        // 3. Let string be ? ToString(thisValue).
        const string = try this_value.toString(agent);

        // 4. Let length be the length of string.
        const length = string.length;

        // 5. Let from be ? ToClampedIndex(start, length).
        const from = std.math.lossyCast(u32, try start.toClampedIndex(agent, length));

        // 6. If end is undefined, let to be length; else let to be ? ToClampedIndex(end, length).
        const to = if (end.isUndefined())
            length
        else
            std.math.lossyCast(u32, try end.toClampedIndex(agent, length));

        // 7. If from ≥ to, return the empty String.
        if (from >= to) return Value.from("");

        // 8. Return the substring of string from from to to.
        return Value.from(try string.substring(agent, from, to));
    }

    /// 22.1.3.23 String.prototype.split ( separator, limit )
    /// https://tc39.es/ecma262/#sec-string.prototype.split
    fn split(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const gpa = agent.gpa;
        const separator_value = arguments.get(0);
        const limit_value = arguments.get(1);

        // 1. Let thisValue be the this value.

        // 2. Perform ? RequireObjectCoercible(thisValue).
        try this_value.requireObjectCoercible(agent);

        // 3. If separator is an Object, then
        if (separator_value.isObject()) {
            // a. Let splitter be ? GetMethod(separator, %Symbol.split%).
            const maybe_splitter = try separator_value.getMethod(
                agent,
                PropertyKey.from(agent.well_known_symbols.split),
            );

            // b. If splitter is not undefined, then
            if (maybe_splitter) |splitter| {
                // i. Return ? Call(splitter, separator, « thisValue, limit »).
                return splitter.call(agent, separator_value, &.{ this_value, limit_value });
            }
        }

        // 4. Let string be ? ToString(thisValue).
        const string = try this_value.toString(agent);

        // 5. If limit is undefined, let lim be 2**32 - 1; else let lim be ℝ(? ToUint32(limit)).
        const limit = if (limit_value.isUndefined())
            std.math.maxInt(u32)
        else
            try limit_value.toUint32(agent);

        // 6. Let separatorString be ? ToString(separator).
        const separator_string = try separator_value.toString(agent);

        // 7. If lim = 0, then
        if (limit == 0) {
            // a. Return CreateArrayFromList(« »).
            const array = try createArrayFromList(agent, &.{});
            return Value.from(&array.object);
        }

        // 8. If separator is undefined, then
        if (separator_value.isUndefined()) {
            // a. Return CreateArrayFromList(« string »).
            const array = try createArrayFromList(agent, &.{Value.from(string)});
            return Value.from(&array.object);
        }

        // 9. Let separatorLength be the length of separatorString.
        const separator_length = separator_string.length;

        // 10. If separatorLength = 0, then
        if (separator_length == 0) {
            // a. Let stringLength be the length of string.
            const string_length = string.length;

            // b. Let outLength be the result of clamping lim between 0 and stringLength.
            const out_length = std.math.clamp(limit, 0, string_length);

            // c. Let head be the substring of string from 0 to outLength.
            const head = try string.substring(agent, 0, out_length);

            // d. Let codeUnits be a List consisting of the sequence of code units that are the
            //    elements of head.
            const code_units = try head.toUtf16(gpa);
            defer gpa.free(code_units);

            // e. Return CreateArrayFromList(codeUnits).
            const array = try createArrayFromListMapToValue(agent, u16, code_units, struct {
                fn mapFn(agent_: *Agent, code_unit: u16) std.mem.Allocator.Error!Value {
                    const code_unit_string = if (code_unit > 0x7F) blk: {
                        var utf16 = try agent_.gc_allocator.alloc(u16, 1);
                        utf16[0] = code_unit;
                        break :blk try types.String.fromUtf16(agent_, utf16);
                    } else blk: {
                        var ascii = try agent_.gc_allocator.alloc(u8, 1);
                        ascii[0] = @intCast(code_unit);
                        break :blk try types.String.fromAscii(agent_, ascii);
                    };
                    return Value.from(code_unit_string);
                }
            }.mapFn);
            return Value.from(&array.object);
        }

        // 11. If string is the empty String, return CreateArrayFromList(« string »).
        if (string.isEmpty()) {
            const array = try createArrayFromList(agent, &.{Value.from(string)});
            return Value.from(&array.object);
        }

        // 12. Let substrings be a new empty List.
        var substrings: std.ArrayList(*const types.String) = .empty;
        defer substrings.deinit(agent.gc_allocator);

        // 13. Let searchStart be 0.
        var search_start: u32 = 0;

        // 14. Let matchIndex be StringIndexOf(string, separatorString, 0).
        var match_index = string.indexOf(separator_string, 0);

        // 15. Repeat, while matchIndex is not not-found,
        while (match_index != null) {
            // a. Let substring be the substring of string from searchStart to matchIndex.
            const substring_ = try string.substring(agent, search_start, match_index.?);

            // b. Append substring to substrings.
            try substrings.append(agent.gc_allocator, substring_);

            // c. If the number of elements in substrings is lim, return CreateArrayFromList(
            //    substrings).
            if (substrings.items.len == limit) {
                const array = try createArrayFromListMapToValue(agent, *const types.String, substrings.items, struct {
                    fn mapFn(_: *Agent, string_: *const types.String) std.mem.Allocator.Error!Value {
                        return Value.from(string_);
                    }
                }.mapFn);
                return Value.from(&array.object);
            }

            // d. Set searchStart to matchIndex + separatorLength.
            search_start = match_index.? + separator_length;

            // e. Set matchIndex to StringIndexOf(string, separatorString, searchStart).
            match_index = string.indexOf(separator_string, search_start);
        }

        // 16. Let substring be the substring of string from searchStart.
        const substring_ = try string.substring(agent, search_start, null);

        // 17. Append substring to substrings.
        try substrings.append(agent.gc_allocator, substring_);

        // 18. Return CreateArrayFromList(substrings).
        const array = try createArrayFromListMapToValue(agent, *const types.String, substrings.items, struct {
            fn mapFn(_: *Agent, string_: *const types.String) std.mem.Allocator.Error!Value {
                return Value.from(string_);
            }
        }.mapFn);
        return Value.from(&array.object);
    }

    /// 22.1.3.24 String.prototype.startsWith ( searchString [ , position ] )
    /// https://tc39.es/ecma262/#sec-string.prototype.startswith
    fn startsWith(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const search_value = arguments.get(0);
        const position_value = arguments.get(1);

        // 1. Let thisValue be the this value.

        // 2. Perform ? RequireObjectCoercible(thisValue).
        try this_value.requireObjectCoercible(agent);

        // 3. Let string be ? ToString(thisValue).
        const string = try this_value.toString(agent);

        // 4. Let isRegexp be ? IsRegExp(searchString).
        const is_regexp = try search_value.isRegExp(agent);

        // 5. If isRegexp is true, throw a TypeError exception.
        if (is_regexp) {
            return agent.throwException(
                .type_error,
                "String.prototype.startsWith() argument must not be a regular expression",
                .{},
            );
        }

        // 6. Set searchString to ? ToString(searchString).
        const search_string = try search_value.toString(agent);

        // 7. Let length be the length of string.
        const length = string.length;

        // 8. Let start be the result of clamping ? ToIntegerOrInfinity(position) between 0 and
        //    length.
        // 9. Assert: If position is undefined, then start is 0.
        const start = std.math.clamp(
            std.math.lossyCast(u32, try position_value.toIntegerOrInfinity(agent)),
            0,
            length,
        );

        // 10. Let searchLength be the length of searchString.
        const search_length = search_string.length;

        // 11. If searchLength = 0, return true.
        if (search_length == 0) return .true;

        // 12. Let end be start + searchLength.
        const end = start +| search_length;

        // 13. If end > length, return false.
        if (end > length) return .false;

        // 14. Let substring be the substring of string from start to end.
        const substring_ = try string.substring(agent, start, end);

        // 15. If substring is searchString, return true.
        if (substring_.eql(search_string)) return .true;

        // 16. Return false.
        return .false;
    }

    /// 22.1.3.25 String.prototype.substring ( start, end )
    /// https://tc39.es/ecma262/#sec-string.prototype.substring
    fn substring(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const start = arguments.get(0);
        const end = arguments.get(1);

        // 1. Let thisValue be the this value.

        // 2. Perform ? RequireObjectCoercible(thisValue).
        try this_value.requireObjectCoercible(agent);

        // 3. Let string be ? ToString(thisValue).
        const string = try this_value.toString(agent);

        // 4. Let length be the length of string.
        const length = string.length;

        // 5. Let finalStart be the result of clamping ? ToIntegerOrInfinity(start) between 0 and
        //    length.
        // 6. Assert: If start is undefined, then finalStart is 0.
        const final_start = std.math.clamp(
            std.math.lossyCast(u32, try start.toIntegerOrInfinity(agent)),
            0,
            length,
        );

        // 7. If end is undefined, let finalEnd be length; else let finalEnd be the result of
        //    clamping ? ToIntegerOrInfinity(end) between 0 and length.
        const final_end = if (end.isUndefined())
            length
        else
            std.math.clamp(
                std.math.lossyCast(u32, try end.toIntegerOrInfinity(agent)),
                0,
                length,
            );

        // 8. Let from be min(finalStart, finalEnd).
        const from = @min(final_start, final_end);

        // 9. Let to be max(finalStart, finalEnd).
        const to = @max(final_start, final_end);

        // 10. Return the substring of string from from to to.
        return Value.from(try string.substring(agent, from, to));
    }

    /// 22.1.3.26 String.prototype.toLocaleLowerCase ( [ reserved1 [ , reserved2 ] ] )
    /// https://tc39.es/ecma262/#sec-string.prototype.tolocalelowercase
    fn toLocaleLowerCase(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        if (build_options.enable_intl) {
            return toLocaleLowerCaseIntl(agent, this_value, arguments);
        }
        return toLowerCase(agent, this_value, arguments);
    }

    /// 20.1.2 String.prototype.toLocaleLowerCase ( [ locales ] )
    /// https://tc39.es/ecma402/#sup-string.prototype.tolocalelowercase
    fn toLocaleLowerCaseIntl(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const locales = arguments.get(0);

        // 1. Let thisValue be ? RequireObjectCoercible(this value).
        try this_value.requireObjectCoercible(agent);

        // 2. Let string be ? ToString(thisValue).
        const string = try this_value.toString(agent);

        // 3. Return ? TransformCase(string, locales, lower).
        return Value.from(try transformCase(agent, string, locales, .lower));
    }

    /// 20.1.2.1 TransformCase ( string, locales, targetCase )
    /// https://tc39.es/ecma402/#sec-transform-case
    fn transformCase(
        agent: *Agent,
        string: *const types.String,
        locales: Value,
        target_case: enum { lower, upper },
    ) Agent.Error!*const types.String {
        const gpa = agent.gpa;

        // 1. Let requestedLocales be ? CanonicalizeLocaleList(locales).
        const requested_locales = try builtins.intl.canonicalizeLocaleList(agent, locales);

        // 2. If requestedLocales is not an empty List, then
        //     a. Let requestedLocale be requestedLocales[0].
        // 3. Else,
        //     a. Let requestedLocale be DefaultLocale().
        const resolved_locale = if (requested_locales.items.len != 0)
            requested_locales.items[0]
        else
            agent.platform.default_locale;

        // 4. Let availableLocales be an Available Locales List which includes the language tags for
        //    which the Unicode Character Database contains language-sensitive case mappings. If the
        //    implementation supports additional locale-sensitive case mappings, availableLocales
        //    should also include their corresponding language tags.
        // 5. Let match be LookupMatchingLocaleByPrefix(availableLocales, « requestedLocale »).
        // 6. If match is not undefined, let locale be match.[[locale]]; else let locale be "und".
        // 7. Let codePoints be StringToCodePoints(string).
        // 8. If targetCase is lower, then
        //     a. Let newCodePoints be a List whose elements are the result of a lowercase
        //        transformation of codePoints according to an implementation-derived algorithm
        //        using locale or the Unicode Default Case Conversion algorithm.
        // 9. Else,
        //     a. Assert: targetCase is upper.
        //     b. Let newCodePoints be a List whose elements are the result of an uppercase
        //        transformation of codePoints according to an implementation-derived algorithm
        //        using locale or the Unicode Default Case Conversion algorithm.
        // 10. Return CodePointsToString(newCodePoints).
        // NOTE: ICU4X only supports UTF-8 for this, so unpaired surrogates are not handled
        //       correctly here.
        const utf8 = try string.toUtf8(gpa);
        defer gpa.free(utf8);
        const case_mapper = icu4zig.CaseMapper.init();
        defer case_mapper.deinit();
        const utf8_transformed = switch (target_case) {
            .lower => try case_mapper.lowercase(agent.gc_allocator, utf8, resolved_locale),
            .upper => try case_mapper.uppercase(agent.gc_allocator, utf8, resolved_locale),
        };
        return types.String.fromUtf8(agent, utf8_transformed);
    }

    /// 22.1.3.27 String.prototype.toLocaleUpperCase ( [ reserved1 [ , reserved2 ] ] )
    /// https://tc39.es/ecma262/#sec-string.prototype.tolocaleuppercase
    fn toLocaleUpperCase(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        if (build_options.enable_intl) {
            return toLocaleUpperCaseIntl(agent, this_value, arguments);
        }
        return toUpperCase(agent, this_value, arguments);
    }

    /// 20.1.3 String.prototype.toLocaleUpperCase ( [ locales ] )
    /// https://tc39.es/ecma402/#sup-string.prototype.tolocaleuppercase
    fn toLocaleUpperCaseIntl(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const locales = arguments.get(0);

        // 1. Let thisValue be ? RequireObjectCoercible(this value).
        try this_value.requireObjectCoercible(agent);

        // 2. Let string be ? ToString(thisValue).
        const string = try this_value.toString(agent);

        // 3. Return ? TransformCase(string, locales, upper).
        return Value.from(try transformCase(agent, string, locales, .upper));
    }

    /// 22.1.3.28 String.prototype.toLowerCase ( )
    /// https://tc39.es/ecma262/#sec-string.prototype.tolowercase
    fn toLowerCase(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        const gpa = agent.gpa;

        // 1. Let thisValue be the this value.

        // 2. Perform ? RequireObjectCoercible(thisValue).
        try this_value.requireObjectCoercible(agent);

        // 3. Let string be ? ToString(thisValue).
        const string = try this_value.toString(agent);

        // 4. Let sText be StringToCodePoints(string).
        // 5. Let lowerText be toLowercase(sText), according to the Unicode Default Case Conversion
        //    algorithm.
        // 6. Let lowercaseString be CodePointsToString(lowerText).
        const lowercase_string = if (build_options.enable_intl) blk: {
            // NOTE: ICU4X only supports UTF-8 for this, so unpaired surrogates are not handled
            //       correctly here.
            const utf8 = try string.toUtf8(gpa);
            defer gpa.free(utf8);
            const case_mapper = icu4zig.CaseMapper.init();
            defer case_mapper.deinit();
            const locale = icu4zig.Locale.unknown();
            defer locale.deinit();
            const utf8_lowercase = try case_mapper.lowercase(agent.gc_allocator, utf8, locale);
            break :blk try types.String.fromUtf8(agent, utf8_lowercase);
        } else blk: {
            // NOTE: Without Intl enabled we can't do what the spec asks for, fall back to ASCII.
            break :blk try string.toLowerCaseAscii(agent);
        };

        // 7. Return lowercaseString.
        return Value.from(lowercase_string);
    }

    /// 22.1.3.29 String.prototype.toString ( )
    /// https://tc39.es/ecma262/#sec-string.prototype.tostring
    fn toString(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Return ? ThisStringValue(this value).
        return Value.from(try thisStringValue(agent, this_value));
    }

    /// 22.1.3.30 String.prototype.toUpperCase ( )
    /// https://tc39.es/ecma262/#sec-string.prototype.touppercase
    fn toUpperCase(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // NOTE: The spec simply references toLowerCase() for this, so the steps below are inferred.
        const gpa = agent.gpa;

        // 1. Let thisValue be the this value.

        // 2. Perform ? RequireObjectCoercible(thisValue).
        try this_value.requireObjectCoercible(agent);

        // 3. Let string be ? ToString(thisValue).
        const string = try this_value.toString(agent);

        // 4. Let sText be StringToCodePoints(string).
        // 5. Let upperText be toUppercase(sText), according to the Unicode Default Case Conversion
        //    algorithm.
        // 6. Let uppercaseString be CodePointsToString(upperText).
        const uppercase_string = if (build_options.enable_intl) blk: {
            // NOTE: ICU4X only supports UTF-8 for this, so unpaired surrogates are not handled
            //       correctly here.
            const utf8 = try string.toUtf8(gpa);
            defer gpa.free(utf8);
            const case_mapper = icu4zig.CaseMapper.init();
            defer case_mapper.deinit();
            const locale = icu4zig.Locale.unknown();
            defer locale.deinit();
            const utf8_uppercase = try case_mapper.uppercase(agent.gc_allocator, utf8, locale);
            break :blk try types.String.fromUtf8(agent, utf8_uppercase);
        } else blk: {
            // NOTE: Without Intl enabled we can't do what the spec asks for, fall back to ASCII.
            break :blk try string.toUpperCaseAscii(agent);
        };

        // 7. Return uppercaseString.
        return Value.from(uppercase_string);
    }

    /// 22.1.3.31 String.prototype.toWellFormed ( )
    /// https://tc39.es/ecma262/#sec-string.prototype.towellformed
    fn toWellFormed(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        const gpa = agent.gpa;

        // 1. Let thisValue be the this value.

        // 2. Perform ? RequireObjectCoercible(thisValue).
        try this_value.requireObjectCoercible(agent);

        // 3. Let string be ? ToString(thisValue).
        const string = try this_value.toString(agent);

        // 4. Let stringLength be the length of string.
        const string_length = string.length;

        // OPTIMIZATION: If the array is empty the result will be an empty string
        if (string_length == 0) return Value.from(types.String.empty);

        // 5. Let k be 0.
        var k: u32 = 0;

        // 6. Let result be the empty String.
        // NOTE: This allocates the exact needed capacity upfront
        // SAFETY: This builder can use a GPA as it only stores u21 code point segments.
        var result = try types.String.Builder.initCapacity(gpa, string_length);
        defer result.deinit(gpa);

        // 7. Repeat, while k < stringLength,
        while (k < string_length) {
            // a. Let codePoint be CodePointAt(string, k).
            const code_point = string.codePointAt(k);

            // b. If codePoint.[[IsUnpairedSurrogate]] is true, then
            if (code_point.is_unpaired_surrogate) {
                // i. Set result to the string-concatenation of result and 0xFFFD (REPLACEMENT
                //    CHARACTER).
                result.appendCodePointAssumeCapacity(std.unicode.replacement_character);
            } else {
                // c. Else,
                // i. Set result to the string-concatenation of result and UTF16EncodeCodePoint(
                //    codePoint.[[CodePoint]]).
                result.appendCodePointAssumeCapacity(code_point.code_point);
            }

            // d. Set k to k + codePoint.[[CodeUnitCount]].
            k += code_point.code_unit_count;
        }

        // 8. Return result.
        return Value.from(try result.build(agent));
    }

    /// 22.1.3.32 String.prototype.trim ( )
    /// https://tc39.es/ecma262/#sec-string.prototype.trim
    fn trim(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let thisValue be the this value.
        // 2. Return ? TrimString(thisValue, start+end).
        return Value.from(try trimString(agent, this_value, .@"start+end"));
    }

    /// 22.1.3.32.1 TrimString ( arg, where )
    /// https://tc39.es/ecma262/#sec-trimstring
    fn trimString(
        agent: *Agent,
        arg: Value,
        where: enum { start, end, @"start+end" },
    ) Agent.Error!*const types.String {
        // 1. Perform ? RequireObjectCoercible(arg).
        try arg.requireObjectCoercible(agent);

        // 2. Let string be ? ToString(arg).
        const string = try arg.toString(agent);

        const trimmed_string = switch (where) {
            // 3. If where is start, then
            .start => blk: {
                // a. Let trimmedString be the String value that is a copy of string with leading
                //    white space removed.
                break :blk try string.trimStart(agent);
            },

            // 4. Else if where is end, then
            .end => blk: {
                // a. Let trimmedString be the String value that is a copy of string with trailing
                //    white space removed.
                break :blk try string.trimEnd(agent);
            },

            // 5. Else,
            //     a. Assert: where is start+end.
            .@"start+end" => blk: {
                // b. Let trimmedString be the String value that is a copy of string with both
                //    leading and trailing white space removed.
                break :blk try string.trim(agent);
            },
        };

        // 6. Return trimmedString.
        return trimmed_string;
    }

    /// 22.1.3.33 String.prototype.trimEnd ( )
    /// https://tc39.es/ecma262/#sec-string.prototype.trimend
    fn trimEnd(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let string be the this value.
        // 2. Return ? TrimString(string, end).
        return Value.from(try trimString(agent, this_value, .end));
    }

    /// 22.1.3.34 String.prototype.trimStart ( )
    /// https://tc39.es/ecma262/#sec-string.prototype.trimstart
    fn trimStart(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let string be the this value.
        // 2. Return ? TrimString(string, start).
        return Value.from(try trimString(agent, this_value, .start));
    }

    /// 22.1.3.35 String.prototype.valueOf ( )
    /// https://tc39.es/ecma262/#sec-string.prototype.valueof
    fn valueOf(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Return ? ThisStringValue(this value).
        return Value.from(try thisStringValue(agent, this_value));
    }

    /// 22.1.3.36 String.prototype [ %Symbol.iterator% ] ( )
    /// https://tc39.es/ecma262/#sec-string.prototype-%symbol.iterator%
    fn @"Symbol.iterator"(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        const realm = agent.currentRealm();

        // 1. Let string be the this value.
        // 2. Perform ? RequireObjectCoercible(string).
        try this_value.requireObjectCoercible(agent);

        // 3. Set string to ? ToString(string).
        const string = try this_value.toString(agent);

        // 4. Let closure be a new Abstract Closure with no parameters that captures s and performs
        //    the following steps when called:
        //    [...]
        // 5. Return CreateIteratorFromClosure(closure, "%StringIteratorPrototype%",
        //    %StringIteratorPrototype%).
        const string_iterator = try StringIterator.create(agent, .{
            .prototype = try realm.intrinsic(.string_iterator_prototype),
            .fields = .{
                .state = .{ .string = string, .position = 0 },
            },
        });
        return Value.from(&string_iterator.object);
    }

    /// B.2.2.1 String.prototype.substr ( start, length )
    /// https://tc39.es/ecma262/#sec-string.prototype.substr
    fn substr(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const start = arguments.get(0);
        const length = arguments.get(1);

        // 1. Let obj be the this value.
        const obj = this_value;

        // 2. Perform ? RequireObjectCoercible(obj).
        try obj.requireObjectCoercible(agent);

        // 3. Let string be ? ToString(obj).
        const string = try obj.toString(agent);

        // 4. Let size be the length of string.
        const size = string.length;

        // 5. Let intStart be ? ToClampedIndex(start, size).
        const int_start = std.math.lossyCast(u32, try start.toClampedIndex(agent, size));

        // 6. If length is undefined, let intLength be size; else let intLength be the result of
        //    clamping ? ToIntegerOrInfinity(length) between 0 and size.
        const int_length = if (length.isUndefined())
            size
        else
            std.math.lossyCast(u32, std.math.clamp(
                try length.toIntegerOrInfinity(agent),
                0,
                @as(f64, @floatFromInt(size)),
            ));

        // 7. Let intEnd be min(intStart + intLength, size).
        const int_end = @min(int_start +| int_length, size);

        // 8. Return the substring of string from intStart to intEnd.
        return Value.from(
            try string.substring(agent, int_start, int_end),
        );
    }

    /// B.2.2.2.1 CreateHTML ( contents, tag, attr, attrValue )
    /// https://tc39.es/ecma262/#sec-createhtml
    fn createHTML(
        agent: *Agent,
        contents: Value,
        tag: []const u8,
        maybe_attr: ?struct { name: []const u8, value: Value },
    ) Agent.Error!*const types.String {
        // 1. Perform ? RequireObjectCoercible(contents).
        try contents.requireObjectCoercible(agent);

        // 2. Let contentsString be ? ToString(contents).
        const contents_string = try contents.toString(agent);

        // 3. Let part1 be the string-concatenation of "<" and tag.
        // 5. Let part2 be the string-concatenation of part1 and ">".
        // 6. Let part3 be the string-concatenation of part2 and contentsString.
        // 7. Let part4 be the string-concatenation of part3, "</", tag, and ">".
        // 8. Return part4.

        // 4. If attr is not the empty String, then
        if (maybe_attr) |attr| {
            // a. Let attrValueString be ? ToString(attrValue).
            const attr_value_string = try attr.value.toString(agent);

            // b. Let escapedAttrValue be the String value that is the same as attrValueString
            //    except that each occurrence of the code unit 0x0022 (QUOTATION MARK) in
            //    attrValueString has been replaced with the six code unit sequence "&quot;".
            const escaped_attr_value = try attr_value_string.replace(
                agent,
                "\"",
                "&quot;",
            );

            // c. Set part1 to the string-concatenation of:- part1
            //    - the code unit 0x0020 (SPACE)
            //    - attr
            //    - the code unit 0x003D (EQUALS SIGN)
            //    - the code unit 0x0022 (QUOTATION MARK)
            //    - escapedAttrValue
            //    - the code unit 0x0022 (QUOTATION MARK)
            return types.String.fromUtf8(agent, try agent.gc_allocator.print(
                "<{[tag]s} {[attribute]s}=\"{[value]f}\">{[string]f}</{[tag]s}>",
                .{
                    .string = contents_string.fmtRaw(),
                    .tag = tag,
                    .attribute = attr.name,
                    .value = escaped_attr_value.fmtRaw(),
                },
            ));
        }

        return types.String.fromUtf8(agent, try agent.gc_allocator.print(
            "<{[tag]s}>{[string]f}</{[tag]s}>",
            .{ .string = contents_string.fmtRaw(), .tag = tag },
        ));
    }

    /// B.2.2.2 String.prototype.anchor ( name )
    /// https://tc39.es/ecma262/#sec-string.prototype.anchor
    fn anchor(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const name = arguments.get(0);

        // 1. Let string be the this value.
        // 2. Return ? CreateHTML(string, "a", "name", name).
        return Value.from(
            try createHTML(agent, this_value, "a", .{ .name = "name", .value = name }),
        );
    }

    /// B.2.2.3 String.prototype.big ( )
    /// https://tc39.es/ecma262/#sec-string.prototype.big
    fn big(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let string be the this value.
        // 2. Return ? CreateHTML(string, "big", "", "").
        return Value.from(try createHTML(agent, this_value, "big", null));
    }

    /// B.2.2.4 String.prototype.blink ( )
    /// https://tc39.es/ecma262/#sec-string.prototype.blink
    fn blink(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let string be the this value.
        // 2. Return ? CreateHTML(string, "blink", "", "").
        return Value.from(try createHTML(agent, this_value, "blink", null));
    }

    /// B.2.2.5 String.prototype.bold ( )
    /// https://tc39.es/ecma262/#sec-string.prototype.bold
    fn bold(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let string be the this value.
        // 2. Return ? CreateHTML(string, "b", "", "").
        return Value.from(try createHTML(agent, this_value, "b", null));
    }

    /// B.2.2.6 String.prototype.fixed ( )
    /// https://tc39.es/ecma262/#sec-string.prototype.fixed
    fn fixed(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let string be the this value.
        // 2. Return ? CreateHTML(string, "tt", "", "").
        return Value.from(try createHTML(agent, this_value, "tt", null));
    }

    /// B.2.2.7 String.prototype.fontcolor ( colour )
    /// https://tc39.es/ecma262/#sec-string.prototype.fontcolor
    fn fontcolor(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const colour = arguments.get(0);

        // 1. Let string be the this value.
        // 2. Return ? CreateHTML(string, "font", "color", colour).
        return Value.from(
            try createHTML(agent, this_value, "font", .{ .name = "color", .value = colour }),
        );
    }

    /// B.2.2.8 String.prototype.fontsize ( size )
    /// https://tc39.es/ecma262/#sec-string.prototype.fontsize
    fn fontsize(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const size = arguments.get(0);

        // 1. Let string be the this value.
        // 2. Return ? CreateHTML(string, "font", "size", size).
        return Value.from(
            try createHTML(agent, this_value, "font", .{ .name = "size", .value = size }),
        );
    }

    /// B.2.2.9 String.prototype.italics ( )
    /// https://tc39.es/ecma262/#sec-string.prototype.italics
    fn italics(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let string be the this value.
        // 2. Return ? CreateHTML(string, "i", "", "").
        return Value.from(try createHTML(agent, this_value, "i", null));
    }

    /// B.2.2.10 String.prototype.link ( url )
    /// https://tc39.es/ecma262/#sec-string.prototype.link
    fn link(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const url = arguments.get(0);

        // 1. Let string be the this value.
        // 2. Return ? CreateHTML(string, "a", "href", url).
        return Value.from(
            try createHTML(agent, this_value, "a", .{ .name = "href", .value = url }),
        );
    }

    /// B.2.2.11 String.prototype.small ( )
    /// https://tc39.es/ecma262/#sec-string.prototype.small
    fn small(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let string be the this value.
        // 2. Return ? CreateHTML(string, "small", "", "").
        return Value.from(try createHTML(agent, this_value, "small", null));
    }

    /// B.2.2.12 String.prototype.strike ( )
    /// https://tc39.es/ecma262/#sec-string.prototype.strike
    fn strike(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let string be the this value.
        // 2. Return ? CreateHTML(string, "strike", "", "").
        return Value.from(try createHTML(agent, this_value, "strike", null));
    }

    /// B.2.2.13 String.prototype.sub ( )
    /// https://tc39.es/ecma262/#sec-string.prototype.sub
    fn sub(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let string be the this value.
        // 2. Return ? CreateHTML(string, "sub", "", "").
        return Value.from(try createHTML(agent, this_value, "sub", null));
    }

    /// B.2.2.14 String.prototype.sup ( )
    /// https://tc39.es/ecma262/#sec-string.prototype.sup
    fn sup(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let string be the this value.
        // 2. Return ? CreateHTML(string, "sup", "", "").
        return Value.from(try createHTML(agent, this_value, "sup", null));
    }
};

/// 22.1.4 Properties of String Instances
/// https://tc39.es/ecma262/#sec-properties-of-string-instances
pub const String = MakeObject(.{
    .Fields = struct {
        /// [[StringData]]
        string_data: *const types.String,
    },
    .tag = .string,
    .display_name = "String",
});
