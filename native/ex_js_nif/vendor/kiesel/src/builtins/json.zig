//! 25.5 The JSON Object
//! https://tc39.es/ecma262/#sec-json-object

const std = @import("std");

const builtins = @import("../builtins.zig");
const execution = @import("../execution.zig");
const types = @import("../types.zig");
const utils = @import("../utils.zig");

const Agent = execution.Agent;
const Arguments = types.Arguments;
const MakeObject = types.MakeObject;
const Object = types.Object;
const PropertyKey = types.PropertyKey;
const Realm = execution.Realm;
const String = types.String;
const Value = types.Value;
const arrayCreateFast = builtins.arrayCreateFast;
const noexcept = utils.noexcept;
const ordinaryObjectCreate = builtins.ordinaryObjectCreate;
const ordinaryObjectCreateWithType = builtins.ordinaryObjectCreateWithType;

pub const RawJSON = MakeObject(.{
    .tag = .raw_json,
    .display_name = "RawJSON",
});

/// Recursively convert a `std.json.Value` to a JS `Value`.
fn convertJsonValue(agent: *Agent, value: std.json.Value) std.mem.Allocator.Error!Value {
    return switch (value) {
        .null => .null,
        .bool => |x| Value.from(x),
        .float => |x| Value.from(x),
        .integer => |x| Value.from(@as(f64, @floatFromInt(x))),
        .string => |x| Value.from(
            try String.fromUtf8(agent, try agent.gc_allocator.dupe(u8, x)),
        ),
        .number_string => |x| Value.from(std.fmt.parseFloat(f64, x) catch unreachable),
        .array => |x| blk: {
            const array = try arrayCreateFast(agent, 0);
            for (x.items, 0..) |value_i, i| {
                try array.object.createDataPropertyDirect(
                    agent,
                    PropertyKey.from(@as(PropertyKey.IntegerIndex, @intCast(i))),
                    try convertJsonValue(agent, value_i),
                );
            }
            break :blk Value.from(&array.object);
        },
        .object => |x| blk: {
            const realm = agent.currentRealm();
            const obj = try ordinaryObjectCreate(
                agent,
                try realm.intrinsic(.object_prototype),
            );
            var it = x.iterator();
            while (it.next()) |entry| {
                try obj.createDataPropertyDirect(
                    agent,
                    PropertyKey.from(
                        try String.fromUtf8(agent, try agent.gc_allocator.dupe(u8, entry.key_ptr.*)),
                    ),
                    try convertJsonValue(agent, entry.value_ptr.*),
                );
            }
            break :blk Value.from(obj);
        },
    };
}

/// 25.5.2.1 ParseJSON ( text )
/// https://tc39.es/ecma262/#sec-ParseJSON
pub fn parseJSON(agent: *Agent, text: []const u8) Agent.Error!Value {
    // 1. If StringToCodePoints(text) is not a valid JSON text as specified in ECMA-404, throw a
    //    SyntaxError exception.
    // 2. Let scriptString be the string-concatenation of "(", text, and ");".
    // 3. Let script be ParseText(scriptString, Script).
    // 4. NOTE: The early error rules defined in 13.2.5.1 have special handling for the above
    //    invocation of ParseText.
    // 5. Assert: script is a Parse Node.
    // 6. Let result be ! Evaluation of script.
    // 7. NOTE: The PropertyDefinitionEvaluation semantics defined in 13.2.5.6 have special handling
    //    for the above evaluation.
    // 8. Assert: result is either a String, a Number, a Boolean, an Object that is defined by
    //    either an ArrayLiteral or an ObjectLiteral, or null.
    // 9. Return the Record { [[ParseNode]]: script, [[Value]]: result }.
    const parsed = std.json.parseFromSlice(
        std.json.Value,
        agent.gc_allocator,
        text,
        .{ .duplicate_field_behavior = .use_last },
    ) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        error.SyntaxError, error.UnexpectedEndOfInput => {
            return agent.throwException(.syntax_error, "Invalid JSON document", .{});
        },
        else => unreachable,
    };
    defer parsed.deinit();
    return convertJsonValue(agent, parsed.value);
}

/// 25.5.2.2 JSON Parse Record
/// https://tc39.es/ecma262/#sec-json-parse-record
const JSONParseRecord = struct {
    /// [[Value]]
    value: Value,

    // These are mutually exclusive so we use a tagged union.
    contents: Contents,

    const Contents = union(enum) {
        /// [[ParseNode]]
        primitive: []const u8,

        /// [[Elements]]
        array: []const JSONParseRecord,

        /// [[Entries]]
        object: String.HashMap(JSONParseRecord),
    };
};

/// 25.5.2.3 CreateJSONParseRecord ( parseNode, key, value )
/// https://tc39.es/ecma262/#sec-createjsonparserecord
fn createJSONParseRecord(
    agent: *Agent,
    scanner: *std.json.Scanner,
    value: Value,
) std.mem.Allocator.Error!JSONParseRecord {
    const gpa = agent.gpa;

    // 1. Let typedValueNode be ShallowestContainedJSONValue(parseNode).
    // 2. Assert: typedValueNode is not empty.
    // 3. Let elements be a new empty List.
    // 4. Let entries be a new empty List.
    var contents: JSONParseRecord.Contents = .{ .primitive = "" };

    // 5. If value is an Object, then
    if (value.isObject()) {
        // a. Let isArray be ! IsArray(value).
        // b. If isArray is true, then
        if (value.asObject().cast(builtins.Array)) |array| {
            // i. Assert: typedValueNode is an ArrayLiteral Parse Node.
            {
                const token = scanner.next() catch |err| switch (err) {
                    error.OutOfMemory => |e| return e,
                    else => unreachable,
                };
                std.debug.assert(token == .array_begin);
            }

            // ii. Let contentNodes be the JSONArrayLiteralContentNodes of typedValueNode.
            // iii. Let length be the number of elements in contentNodes.
            // iv. Let valueLength be ! LengthOfArrayLike(value).
            // v. Assert: valueLength is length.
            const length = array.fields.length;
            const elements = try agent.gc_allocator.alloc(JSONParseRecord, length);

            // vi. Let index be 0.
            // vii. Repeat, while index < length,
            for (elements, 0..) |*element, index| {
                // 1. Let propertyName be ! ToString(𝔽(index)).
                const property_name = PropertyKey.from(@as(PropertyKey.IntegerIndex, @intCast(index)));

                // 2. Let elementParseRecord be CreateJSONParseRecord(contentNodes[index],
                //    propertyName, ! Get(value, propertyName)).
                const element_parse_record = try createJSONParseRecord(
                    agent,
                    scanner,
                    value.asObject().getPropertyValueDirect(property_name),
                );

                // 3. Append elementParseRecord to elements.
                element.* = element_parse_record;

                // 4. Set index to index + 1.
            }
            contents = .{ .array = elements };

            {
                const token = scanner.next() catch |err| switch (err) {
                    error.OutOfMemory => |e| return e,
                    else => unreachable,
                };
                std.debug.assert(token == .array_end);
            }
        } else {
            // c. Else,
            // i. Assert: typedValueNode is an ObjectLiteral Parse Node.
            {
                const token = scanner.next() catch |err| switch (err) {
                    error.OutOfMemory => |e| return e,
                    else => unreachable,
                };
                std.debug.assert(token == .object_begin);
            }

            // ii. Let propertyNodes be the PropertyDefinitionNodes of typedValueNode.
            // Stores owned keys and slices into `scanner.input`.
            var property_nodes: std.StringHashMapUnmanaged([]const u8) = .empty;
            defer {
                var it = property_nodes.iterator();
                while (it.next()) |entry| gpa.free(entry.key_ptr.*);
                property_nodes.deinit(gpa);
            }
            while (scanner.peekNextTokenType() catch unreachable != .object_end) {
                const token = scanner.nextAlloc(gpa, .alloc_always) catch |err| switch (err) {
                    error.OutOfMemory => |e| return e,
                    else => unreachable,
                };

                _ = scanner.peekNextTokenType() catch unreachable;
                const start = scanner.cursor;
                scanner.skipValue() catch |err| switch (err) {
                    error.OutOfMemory => |e| return e,
                    else => unreachable,
                };
                const end = scanner.cursor;
                const gop = try property_nodes.getOrPut(gpa, token.allocated_string);
                if (gop.found_existing) gpa.free(token.allocated_string);
                gop.value_ptr.* = scanner.input[start..end];
            }

            {
                const token = scanner.next() catch |err| switch (err) {
                    error.OutOfMemory => |e| return e,
                    else => unreachable,
                };
                std.debug.assert(token == .object_end);
            }

            var entries: String.HashMap(JSONParseRecord) = .empty;
            try entries.ensureTotalCapacity(agent.gc_allocator, property_nodes.count());

            // iii. NOTE: Because value was produced from JSON text and has not been modified, all
            //      of its property keys are Strings and will be exhaustively enumerated.
            // iv. Let keys be ! EnumerableOwnProperties(value, key).
            // v. For each String propertyKey of keys, do
            var it = property_nodes.iterator();
            while (it.next()) |entry| {
                // 1. NOTE: In the case of JSON text specifying multiple name/value pairs with the
                //    same name for a single object (such as `{"a":"lost","a":"kept"}`), the value
                //    for the corresponding property of the resulting ECMAScript object is specified
                //    by the last pair with that name.
                // 2. Let propertyDefinition be empty.
                // 3. For each Parse Node propertyNode of propertyNodes, do
                //     a. Let propertyName be the PropName of propertyNode.
                //     b. If propertyName is propertyKey, set propertyDefinition to propertyNode.
                // 4. Assert: propertyDefinition is PropertyDefinition : PropertyName :
                //    AssignmentExpression .
                // 5. Let propertyValueNode be the AssignmentExpression of propertyDefinition.

                var sub_scanner = std.json.Scanner.initCompleteInput(gpa, entry.value_ptr.*);
                defer sub_scanner.deinit();

                const key = try String.fromUtf8(
                    agent,
                    try agent.gc_allocator.dupe(u8, entry.key_ptr.*),
                );
                const property_key = PropertyKey.from(key);

                // 6. Let entryParseRecord be CreateJSONParseRecord(propertyValueNode, propertyKey,
                //    ! Get(value, propertyKey)).
                const entry_parse_record = try createJSONParseRecord(
                    agent,
                    &sub_scanner,
                    value.asObject().getPropertyValueDirect(property_key),
                );

                // 7. Append entryParseRecord to entries.
                entries.putAssumeCapacityNoClobber(key, entry_parse_record);
            }
            contents = .{ .object = entries };
        }
    } else {
        // 6. Else,
        // a. Assert: typedValueNode is neither an ArrayLiteral Parse Node nor an ObjectLiteral
        //    Parse Node.
        _ = scanner.peekNextTokenType() catch unreachable;
        const start = scanner.cursor;
        scanner.skipValue() catch |err| switch (err) {
            error.OutOfMemory => |e| return e,
            else => unreachable,
        };
        contents = .{ .primitive = scanner.input[start..scanner.cursor] };
    }

    // 7. Return the JSON Parse Record { [[ParseNode]]: typedValueNode, [[Key]]: key,
    //    [[Value]]: value, [[Elements]]: elements, [[Entries]]: entries }.
    return .{
        .value = value,
        .contents = contents,
    };
}

/// 25.5.2.4 InternalizeJSONProperty ( holder, name, reviver, parseRecord )
/// https://tc39.es/ecma262/#sec-internalizejsonproperty
fn internalizeJSONProperty(
    agent: *Agent,
    holder: *Object,
    name: PropertyKey,
    reviver: *Object,
    maybe_parse_record: ?JSONParseRecord,
) Agent.Error!Value {
    std.debug.assert(reviver.internalMethods().call != null);
    const realm = agent.currentRealm();

    // 1. Let value be ? Get(holder, name).
    const value = try holder.get(agent, name);

    // 2. Let context be OrdinaryObjectCreate(%Object.prototype%).
    const context = try ordinaryObjectCreate(
        agent,
        try realm.intrinsic(.object_prototype),
    );

    const records: union(enum) {
        array: []const JSONParseRecord,
        object: *const String.HashMap(JSONParseRecord),
        none,
    } = blk: {
        // 3. If parseRecord is a JSON Parse Record and SameValue(parseRecord.[[Value]], value) is
        //    true, then
        const parse_record = maybe_parse_record orelse break :blk .none;
        if (!value.sameValue(parse_record.value)) break :blk .none;
        switch (parse_record.contents) {
            // a. If value is not an Object, then
            .primitive => |source| {
                // i. Let parseNode be parseRecord.[[ParseNode]].
                // ii. Assert: parseNode is neither an ArrayLiteral Parse Node nor an ObjectLiteral
                //     Parse Node.
                // iii. Let sourceText be the source text matched by parseNode.
                // iv. Perform ! CreateDataPropertyOrThrow(context, "source", CodePointsToString(
                //     sourceText)).
                const source_text = try String.fromUtf8(
                    agent,
                    try agent.gc_allocator.dupe(u8, source),
                );
                try context.createDataPropertyDirect(
                    agent,
                    PropertyKey.from("source"),
                    Value.from(source_text),
                );
                break :blk .none;
            },

            // b. Let elementRecords be parseRecord.[[Elements]].
            .array => |elements| break :blk .{ .array = elements },

            // c. Let entryRecords be parseRecord.[[Entries]].
            .object => |*entries| break :blk .{ .object = entries },
        }

        // 4. Else,
        //     a. Let elementRecords be a new empty List.
        //     b. Let entryRecords be a new empty List.
        // NOTE: This is handled upfront.
        comptime unreachable;
    };

    // 5. If value is an Object, then
    if (value.isObject()) {
        // a. Let isArray be ? IsArray(value).
        const is_array = try value.isArray(agent);

        // b. If isArray is true, then
        if (is_array) {
            // i. Let elementRecordsLength be the number of elements in elementRecords.
            const element_records = switch (records) {
                .array => |elements| elements,
                .object, .none => &.{},
            };
            const element_records_length = element_records.len;

            // ii. Let length be ? LengthOfArrayLike(value).
            const length = try value.asObject().lengthOfArrayLike(agent);

            // iii. Let index be 0.
            var index: u53 = 0;

            // iv. Repeat, while index < length,
            while (index < length) : (index += 1) {
                // 1. Let propertyKey be ! ToString(𝔽(index)).
                const property_key = PropertyKey.from(index);

                // 2. If index < elementRecordsLength, let elementRecord be elementRecords[index];
                //    else let elementRecord be empty.
                const element_record = if (index < element_records_length)
                    element_records[@intCast(index)]
                else
                    null;

                // 3. Let newElement be ? InternalizeJSONProperty(value, propertyKey, reviver,
                //    elementRecord).
                const new_element = try internalizeJSONProperty(
                    agent,
                    value.asObject(),
                    property_key,
                    reviver,
                    element_record,
                );

                // 4. If newElement is undefined, then
                if (new_element.isUndefined()) {
                    // a. Perform ? value.[[Delete]](propertyKey).
                    _ = try value.asObject().internalMethods().delete(
                        agent,
                        value.asObject(),
                        property_key,
                    );
                } else {
                    // 5. Else,
                    // a. Perform ? CreateDataProperty(value, propertyKey, newElement).
                    _ = try value.asObject().createDataProperty(agent, property_key, new_element);
                }

                // 6. Set index to index + 1.
            }
        } else {
            // c. Else,
            // i. Let keys be ? EnumerableOwnProperties(value, key).
            var keys = try value.asObject().enumerableOwnProperties(agent, .key);
            defer keys.deinit(agent.gc_allocator);

            // ii. For each String propertyKey of keys, do
            for (keys.items) |key| {
                const property_key = try key.toPropertyKey(agent);

                // 1. If there exists an element entry of entryRecords such that entry.[[Key]] is
                //    propertyKey, let entryRecord be entry; else let entryRecord be empty.
                const entry_record = switch (records) {
                    .object => |entries| entries.get(key.asString()),
                    .array, .none => null,
                };

                // 2. Let newElement be ? InternalizeJSONProperty(value, propertyKey, reviver,
                //    entryRecord).
                const new_element = try internalizeJSONProperty(
                    agent,
                    value.asObject(),
                    property_key,
                    reviver,
                    entry_record,
                );

                // 3. If newElement is undefined, then
                if (new_element.isUndefined()) {
                    // a. Perform ? value.[[Delete]](propertyKey).
                    _ = try value.asObject().internalMethods().delete(
                        agent,
                        value.asObject(),
                        property_key,
                    );
                } else {
                    // 4. Else,
                    // a. Perform ? CreateDataProperty(value, propertyKey, newElement).
                    _ = try value.asObject().createDataProperty(agent, property_key, new_element);
                }
            }
        }
    }

    // 6. Return ? Call(reviver, holder, « name, value, context »).
    return reviver.call(agent, Value.from(holder), &.{
        name.toValue(agent) catch unreachable,
        value,
        Value.from(context),
    });
}

/// 25.5.4.1 JSON Serialization Record
/// https://tc39.es/ecma262/#sec-json-serialization-record
const JSONSerialization = struct {
    pub const Stack = std.AutoHashMapUnmanaged(*Object, void);

    /// [[ReplacerFunction]]
    replacer_function: ?*Object,

    /// [[PropertyList]]
    property_list: ?PropertyKey.ArrayHashMap(void),

    /// [[Gap]]
    gap: *const String,

    /// [[Stack]]
    stack: Stack,

    /// [[Indent]]
    indent: *const String,
};

/// 25.5.4.2 SerializeJSONProperty ( state, key, holder )
/// https://tc39.es/ecma262/#sec-serializejsonproperty
fn serializeJSONProperty(
    agent: *Agent,
    state: *JSONSerialization,
    key: PropertyKey,
    holder: *Object,
) Agent.Error!?*const String {
    // 1. Let value be ? Get(holder, key).
    var value = try holder.get(agent, key);

    // 2. If value is an Object or value is a BigInt, then
    if (value.isObject() or value.isBigInt()) {
        // a. Let toJSON be ? GetV(value, "toJSON").
        const to_json = try value.get(agent, PropertyKey.from("toJSON"));

        // b. If IsCallable(toJSON) is true, then
        if (to_json.isCallable()) {
            // i. Set value to ? Call(toJSON, value, « key »).
            value = try to_json.asObject().call(agent, value, &.{try key.toValue(agent)});
        }
    }

    // 3. If state.[[ReplacerFunction]] is not undefined, then
    if (state.replacer_function) |replacer_function| {
        // a. Set value to ? Call(state.[[ReplacerFunction]], holder, « key, value »).
        value = try replacer_function.call(
            agent,
            Value.from(holder),
            &.{ try key.toValue(agent), value },
        );
    }

    // 4. If value is an Object, then
    if (value.isObject()) {
        // a. If value has an [[IsRawJSON]] internal slot, then
        if (value.asObject().is(RawJSON)) {
            // i. Let rawJSON be ! Get(value, "rawJSON").
            const raw_json = value.asObject().getValueAtPropertyOffset(@fromBackingInt(0));

            // ii. Assert: rawJSON is a String.
            std.debug.assert(raw_json.isString());

            // iii. Return rawJSON.
            return raw_json.asString();
        }

        // b. If value has a [[NumberData]] internal slot, then
        if (value.asObject().is(builtins.Number)) {
            // i. Set value to ? ToNumber(value).
            value = Value.from(try value.toNumber(agent));
        }
        // c. Else if value has a [[StringData]] internal slot, then
        else if (value.asObject().is(builtins.String)) {
            // i. Set value to ? ToString(value).
            value = Value.from(try value.toString(agent));
        }
        // d. Else if value has a [[BooleanData]] internal slot, then
        else if (value.asObject().cast(builtins.Boolean)) |boolean| {
            // i. Set value to value.[[BooleanData]].
            value = Value.from(boolean.fields.boolean_data);
        }
        // e. Else if value has a [[BigIntData]] internal slot, then
        else if (value.asObject().cast(builtins.BigInt)) |big_int| {
            // i. Set value to value.[[BigIntData]].
            value = Value.from(big_int.fields.big_int_data);
        }
    }

    switch (value.type()) {
        // 5. If value is null, return "null".
        .null => return String.fromLiteral("null"),

        // 6. If value is true, return "true".
        // 7. If value is false, return "false".
        .boolean => return if (value.asBoolean()) String.fromLiteral("true") else String.fromLiteral("false"),

        // 8. If value is a String, return QuoteJSONString(value).
        .string => return try quoteJSONString(agent, value.asString()),

        // 9. If value is a Number, then
        .number => {
            // a. If value is finite, return ! ToString(value).
            if (value.asNumber().isFinite()) return try value.asNumber().toString(agent, 10);

            // b. Return "null".
            return String.fromLiteral("null");
        },

        // 10. If value is a BigInt, throw a TypeError exception.
        .big_int => return agent.throwException(.type_error, "Cannot serialize BigInt to JSON", .{}),

        // 11. If value is an Object and IsCallable(value) is false, then
        .object => if (!value.isCallable()) {
            // a. Let isArray be ? IsArray(value).
            const is_array = try value.isArray(agent);

            // b. If isArray is true, then
            if (is_array) {
                // i. Return ? SerializeJSONArray(state, value).
                return try serializeJSONArray(agent, state, value.asObject());
            }

            // c. Return ? SerializeJSONObject(state, value).
            return try serializeJSONObject(agent, state, value.asObject());
        },

        else => {},
    }

    // 12. Return undefined.
    return null;
}

/// 25.5.4.3 QuoteJSONString ( value )
/// https://tc39.es/ecma262/#sec-quotejsonstring
fn quoteJSONString(agent: *Agent, value: *const String) std.mem.Allocator.Error!*const String {
    // 1. Let product be the String value consisting solely of the code unit 0x0022 (QUOTATION
    //    MARK).
    var product: std.ArrayList(u8) = .empty;
    try product.append(agent.gc_allocator, '"');

    // 2. For each code point codePoint of StringToCodePoints(value), do
    var it = value.codeUnitIterator();
    while (it.next()) |code_point| {
        // a. If codePoint is listed in the “Code Point” column of Table 78, then
        if (code_point == 0x08 or
            code_point == 0x09 or
            code_point == 0x0A or
            code_point == 0x0C or
            code_point == 0x0D or
            code_point == 0x22 or
            code_point == 0x5C)
        {
            // i. Set product to the string-concatenation of product and the escape sequence for
            //    codePoint as specified in the “Escape Sequence” column of the corresponding row.
            switch (code_point) {
                0x08 => try product.appendSlice(agent.gc_allocator, "\\b"),
                0x09 => try product.appendSlice(agent.gc_allocator, "\\t"),
                0x0A => try product.appendSlice(agent.gc_allocator, "\\n"),
                0x0C => try product.appendSlice(agent.gc_allocator, "\\f"),
                0x0D => try product.appendSlice(agent.gc_allocator, "\\r"),
                0x22 => try product.appendSlice(agent.gc_allocator, "\\\""),
                0x5C => try product.appendSlice(agent.gc_allocator, "\\\\"),
                else => unreachable,
            }
        }
        // b. Else if codePoint has a numeric value less than 0x0020 (SPACE) or codePoint has the
        //    same numeric value as a leading surrogate or trailing surrogate, then
        else if (code_point < 0x20 or std.unicode.utf16IsLowSurrogate(code_point) or std.unicode.utf16IsHighSurrogate(code_point)) {
            // i. Let unit be the code unit whose numeric value is the numeric value of codePoint.
            // ii. Set product to the string-concatenation of product and UnicodeEscape(unit).
            try product.appendSlice(agent.gc_allocator, try unicodeEscape(agent, code_point));
        } else {
            // c. Else,
            // i. Set product to the string-concatenation of product and UTF16EncodeCodePoint(
            //    codePoint).
            try product.appendSlice(
                agent.gc_allocator,
                std.unicode.utf16LeToUtf8Alloc(agent.gc_allocator, &.{code_point}) catch |err| switch (err) {
                    error.OutOfMemory => |e| return e,
                    error.DanglingSurrogateHalf,
                    error.ExpectedSecondSurrogateHalf,
                    error.UnexpectedSecondSurrogateHalf,
                    => unreachable,
                },
            );
        }
    }

    // 3. Set product to the string-concatenation of product and the code unit 0x0022 (QUOTATION
    //    MARK).
    try product.append(agent.gc_allocator, '"');

    // 4. Return product.
    return String.fromUtf8(agent, try product.toOwnedSlice(agent.gc_allocator));
}

/// 25.5.4.4 UnicodeEscape ( codeUnit )
/// https://tc39.es/ecma262/#sec-unicodeescape
fn unicodeEscape(agent: *Agent, code_unit: u16) std.mem.Allocator.Error![]const u8 {
    // 1. Let n be the numeric value of codeUnit.
    // 2. Assert: n ≤ 0xFFFF.
    // 3. Let hex be the String representation of n, formatted as a lowercase hexadecimal number.
    // 4. Return the string-concatenation of the code unit 0x005C (REVERSE SOLIDUS), "u", and
    //    StringPad(hex, 4, "0", start).
    return agent.gc_allocator.print("\\u{x:0>4}", .{code_unit});
}

/// 25.5.4.5 SerializeJSONObject ( state, value )
/// https://tc39.es/ecma262/#sec-serializejsonobject
fn serializeJSONObject(
    agent: *Agent,
    state: *JSONSerialization,
    value: *Object,
) error{ OutOfMemory, ExceptionThrown }!*const String {
    // 1. If state.[[Stack]] contains value, throw a TypeError exception because the structure is
    //    cyclical.
    if (state.stack.contains(value)) {
        return agent.throwException(.type_error, "Cannot serialize cyclic object to JSON", .{});
    }

    // 2. Append value to state.[[Stack]].
    try state.stack.put(agent.gc_allocator, value, {});

    // 3. Let stepBack be state.[[Indent]].
    const step_back = state.indent;

    // 4. Set state.[[Indent]] to the string-concatenation of state.[[Indent]] and state.[[Gap]].
    state.indent = try String.concat(agent, &.{ state.indent, state.gap });

    // 5. If state.[[PropertyList]] is not undefined, then
    //     a. Let keys be state.[[PropertyList]].
    // 6. Else,
    //     a. Let keys be ? EnumerableOwnProperties(value, key).
    var keys = state.property_list orelse blk: {
        var keys = try value.enumerableOwnProperties(agent, .key);
        defer keys.deinit(agent.gc_allocator);
        var converted: PropertyKey.ArrayHashMap(void) = .empty;
        try converted.ensureUnusedCapacity(agent.gc_allocator, keys.items.len);
        for (keys.items) |key| {
            converted.putAssumeCapacityNoClobber(key.toPropertyKey(agent) catch |err| try noexcept(err), {});
        }
        break :blk converted;
    };
    defer if (state.property_list == null) keys.deinit(agent.gc_allocator);

    // 7. Let partial be a new empty List.
    var partial = try std.ArrayList([]const u8).initCapacity(agent.gc_allocator, keys.count());
    defer partial.deinit(agent.gc_allocator);

    // 8. For each element propertyKey of keys, do
    for (keys.keys()) |property_key| {
        // a. Let stringP be ? SerializeJSONProperty(state, propertyKey, value).
        const string_property = try serializeJSONProperty(
            agent,
            state,
            property_key,
            value,
        );

        // b. If stringP is not undefined, then
        if (string_property != null) {
            // i. Let member be QuoteJSONString(propertyKey).
            // ii. Set member to the string-concatenation of member and ":".
            // iii. If state.[[Gap]] is not the empty String, then
            //     1. Set member to the string-concatenation of member and the code unit 0x0020
            //        (SPACE).
            // iv. Set member to the string-concatenation of member and stringP.
            const member = try agent.gc_allocator.print("{f}:{s}{f}", .{
                (try quoteJSONString(
                    agent,
                    (try property_key.toStringOrSymbol(agent)).string,
                )).fmtRaw(),
                if (!state.gap.isEmpty()) " " else "",
                string_property.?.fmtRaw(),
            });

            // v. Append member to partial.
            try partial.append(agent.gc_allocator, member);
        }
    }

    // 9. If partial is empty, then
    const final = if (partial.items.len == 0) blk: {
        // a. Let final be "{}".
        break :blk String.fromLiteral("{}");
    } else blk: {
        // 10. Else,
        // a. If state.[[Gap]] is the empty String, then
        if (state.gap.isEmpty()) {
            // i. Let properties be the String value formed by concatenating all the element Strings
            //    of partial with each adjacent pair of Strings separated with the code unit 0x002C
            //    (COMMA). A comma is not inserted either before the first String or after the last
            //    String.
            const properties = try std.mem.join(agent.gc_allocator, ",", partial.items);

            // ii. Let final be the string-concatenation of "{", properties, and "}".
            break :blk String.fromUtf8(
                agent,
                try agent.gc_allocator.print("{{{s}}}", .{properties}),
            );
        } else {
            // b. Else,
            // i. Let separator be the string-concatenation of the code unit 0x002C (COMMA), the
            //    code unit 0x000A (LINE FEED), and state.[[Indent]].
            const separator = try agent.gc_allocator.print(",\n{f}", .{state.indent.fmtRaw()});

            // ii. Let properties be the String value formed by concatenating all the element
            //     Strings of partial with each adjacent pair of Strings separated with separator.
            //     The separator String is not inserted either before the first String or after the
            //     last String.
            const properties = try std.mem.join(agent.gc_allocator, separator, partial.items);

            // iii. Let final be the string-concatenation of "{", the code unit 0x000A (LINE FEED),
            //      state.[[Indent]], properties, the code unit 0x000A (LINE FEED), stepBack, and
            //      "}".
            break :blk String.fromUtf8(agent, try agent.gc_allocator.print(
                "{{\n{f}{s}\n{f}}}",
                .{ state.indent.fmtRaw(), properties, step_back.fmtRaw() },
            ));
        }
    };

    // 11. Remove the last element of state.[[Stack]].
    _ = state.stack.remove(value);

    // 12. Set state.[[Indent]] to stepBack.
    state.indent = step_back;

    // 13. Return final.
    return final;
}

/// 25.5.4.6 SerializeJSONArray ( state, value )
/// https://tc39.es/ecma262/#sec-serializejsonarray
fn serializeJSONArray(
    agent: *Agent,
    state: *JSONSerialization,
    value: *Object,
) error{ OutOfMemory, ExceptionThrown }!*const String {
    // 1. If state.[[Stack]] contains value, throw a TypeError exception because the structure is
    //    cyclical.
    if (state.stack.contains(value)) {
        return agent.throwException(.type_error, "Cannot serialize cyclic array to JSON", .{});
    }

    // 2. Append value to state.[[Stack]].
    try state.stack.put(agent.gc_allocator, value, {});

    // 3. Let stepBack be state.[[Indent]].
    const step_back = state.indent;

    // 4. Set state.[[Indent]] to the string-concatenation of state.[[Indent]] and state.[[Gap]].
    state.indent = try String.concat(agent, &.{ state.indent, state.gap });

    // 6. Let length be ? LengthOfArrayLike(value).
    const length = try value.lengthOfArrayLike(agent);

    // 5. Let partial be a new empty List.
    var partial = try std.ArrayList([]const u8).initCapacity(agent.gc_allocator, @intCast(length));
    defer partial.deinit(agent.gc_allocator);

    // 7. Let index be 0.
    var index: u53 = 0;

    // 8. Repeat, while index < length,
    while (index < length) : (index += 1) {
        // a. Let stringP be ? SerializeJSONProperty(state, ! ToString(𝔽(index)), value).
        const string_property = try serializeJSONProperty(
            agent,
            state,
            PropertyKey.from(index),
            value,
        );

        // b. If stringP is undefined, then
        if (string_property == null) {
            // i. Append "null" to partial.
            partial.appendAssumeCapacity("null");
        } else {
            // c. Else,
            // i. Append stringP to partial.
            partial.appendAssumeCapacity(try string_property.?.toUtf8(agent.gc_allocator));
        }

        // d. Set index to index + 1.
    }

    // 9. If partial is empty, then
    const final = if (partial.items.len == 0) blk: {
        // a. Let final be "[]".
        break :blk String.fromLiteral("[]");
    } else blk: {
        // 10. Else,
        // a. If state.[[Gap]] is the empty String, then
        if (state.gap.isEmpty()) {
            // i. Let properties be the String value formed by concatenating all the element Strings
            //    of partial with each adjacent pair of Strings separated with the code unit 0x002C
            //    (COMMA). A comma is not inserted either before the first String or after the last
            //    String.
            const properties = try std.mem.join(agent.gc_allocator, ",", partial.items);

            // ii. Let final be the string-concatenation of "[", properties, and "]".
            break :blk try String.fromUtf8(
                agent,
                try agent.gc_allocator.print("[{s}]", .{properties}),
            );
        } else {
            // b. Else,
            // i. Let separator be the string-concatenation of the code unit 0x002C (COMMA), the
            //    code unit 0x000A (LINE FEED), and state.[[Indent]].
            const separator = try agent.gc_allocator.print(",\n{f}", .{state.indent.fmtRaw()});

            // ii. Let properties be the String value formed by concatenating all the element
            //     Strings of partial with each adjacent pair of Strings separated with separator.
            //     The separator String is not inserted either before the first String or after the
            //     last String.
            const properties = try std.mem.join(agent.gc_allocator, separator, partial.items);

            // iii. Let final be the string-concatenation of "[", the code unit 0x000A (LINE FEED),
            //      state.[[Indent]], properties, the code unit 0x000A (LINE FEED), stepBack, and
            //      "]".
            break :blk try String.fromUtf8(agent, try agent.gc_allocator.print(
                "[\n{f}{s}\n{f}]",
                .{ state.indent.fmtRaw(), properties, step_back.fmtRaw() },
            ));
        }
    };

    // 11. Remove the last element of state.[[Stack]].
    _ = state.stack.remove(value);

    // 12. Set state.[[Indent]] to stepBack.
    state.indent = step_back;

    // 13. Return final.
    return final;
}

pub const namespace = struct {
    pub fn create(agent: *Agent, realm: *Realm) std.mem.Allocator.Error!*Object {
        return ordinaryObjectCreate(agent, try realm.intrinsic(.object_prototype));
    }

    pub fn init(agent: *Agent, realm: *Realm, object: *Object) std.mem.Allocator.Error!void {
        // 25.5.5 JSON [ %Symbol.toStringTag% ]
        // https://tc39.es/ecma262/#sec-json-%symbol.tostringtag%
        try object.defineBuiltinPropertyWithAttributes(
            agent,
            "Symbol.toStringTag",
            Value.from("JSON"),
            .{
                .writable = false,
                .enumerable = false,
                .configurable = true,
            },
        );

        try object.defineBuiltinFunction(agent, "isRawJSON", isRawJSON, 1, realm);
        try object.defineBuiltinFunction(agent, "parse", parse, 2, realm);
        try object.defineBuiltinFunction(agent, "rawJSON", rawJSON, 1, realm);
        try object.defineBuiltinFunction(agent, "stringify", stringify, 3, realm);
    }

    /// 25.5.1 JSON.isRawJSON ( obj )
    /// https://tc39.es/ecma262/#sec-json.israwjson
    fn isRawJSON(_: *Agent, _: Value, arguments: Arguments) Agent.Error!Value {
        const obj = arguments.get(0);

        // 1. If obj is an Object and obj has an [[IsRawJSON]] internal slot, return true.
        // 2. Return false.
        return Value.from(obj.isObject() and obj.asObject().is(RawJSON));
    }

    /// 25.5.2 JSON.parse ( text [ , reviver ] )
    /// https://tc39.es/ecma262/#sec-json.parse
    fn parse(agent: *Agent, _: Value, arguments: Arguments) Agent.Error!Value {
        const gpa = agent.gpa;
        const realm = agent.currentRealm();
        const text = arguments.get(0);
        const reviver = arguments.get(1);

        // 1. Let jsonString be ? ToString(text).
        const json_string = try (try text.toString(agent)).toUtf8(gpa);
        defer gpa.free(json_string);

        // 2. Let parseResult be ? ParseJSON(jsonString).
        // 3. Let unfiltered be parseResult.[[Value]].
        const unfiltered = try parseJSON(agent, json_string);

        // 4. If IsCallable(reviver) is false, return unfiltered.
        if (!reviver.isCallable()) return unfiltered;

        // 5. Let root be OrdinaryObjectCreate(%Object.prototype%).
        const root = try ordinaryObjectCreate(
            agent,
            try realm.intrinsic(.object_prototype),
        );

        // 6. Let rootName be the empty String.
        const root_name = PropertyKey.from("");

        // 7. Perform ! CreateDataPropertyOrThrow(root, rootName, unfiltered).
        try root.createDataPropertyDirect(agent, root_name, unfiltered);

        // 8. Let snapshot be CreateJSONParseRecord(parseResult.[[ParseNode]], rootName,
        //    unfiltered).
        var scanner = std.json.Scanner.initCompleteInput(gpa, json_string);
        defer scanner.deinit();
        const snapshot = try createJSONParseRecord(agent, &scanner, unfiltered);

        // 9. Return ? InternalizeJSONProperty(root, rootName, reviver, snapshot).
        return internalizeJSONProperty(agent, root, root_name, reviver.asObject(), snapshot);
    }

    /// 25.5.3 JSON.rawJSON ( text )
    /// https://tc39.es/ecma262/#sec-json.rawjson
    fn rawJSON(agent: *Agent, _: Value, arguments: Arguments) Agent.Error!Value {
        const gpa = agent.gpa;
        const text = arguments.get(0);

        // 1. Let jsonString be ? ToString(text).
        const json_string = try text.toString(agent);

        // 2. If jsonString is the empty String, throw a SyntaxError exception.
        // 3. If the first code unit of jsonString is not either an ASCII lowercase letter code unit
        //    (0x0061 through 0x007A, inclusive), an ASCII digit code unit (0x0030 through 0x0039,
        //    inclusive), 0x0022 (QUOTATION MARK), or 0x002D (HYPHEN-MINUS), throw a SyntaxError
        //    exception.
        // 4. If the last code unit of jsonString is not either an ASCII lowercase letter code unit
        //    (0x0061 through 0x007A, inclusive), an ASCII digit code unit (0x0030 through 0x0039,
        //    inclusive), or 0x0022 (QUOTATION MARK), throw a SyntaxError exception.
        // 5. Let parseResult be ? ParseJSON(jsonString).
        // 6. Assert: parseResult.[[Value]] is either a String, a Number, a Boolean, or null.
        const json_string_utf8 = try json_string.toUtf8(gpa);
        defer gpa.free(json_string_utf8);
        const json_whitespace = [_]u8{ '\t', '\n', '\r', ' ' };
        if (json_string_utf8.len == 0 or
            std.mem.findScalar(u8, &json_whitespace, json_string_utf8[0]) != null or
            std.mem.findScalar(u8, &json_whitespace, json_string_utf8[json_string_utf8.len - 1]) != null)
        {
            return agent.throwException(.syntax_error, "Raw JSON value must not have leading or trailing whitespace", .{});
        }
        const parse_result = try parseJSON(agent, json_string_utf8);
        if (parse_result.isObject()) {
            return agent.throwException(.syntax_error, "Raw JSON value must be a primitive", .{});
        }

        // 7. Let internalSlotsList be « [[IsRawJSON]] ».
        // 8. Let obj be OrdinaryObjectCreate(null, internalSlotsList).
        const raw_json = try ordinaryObjectCreateWithType(RawJSON, agent, null, {});

        // 9. Perform ! CreateDataPropertyOrThrow(obj, "rawJSON", jsonString).
        try raw_json.object.createDataPropertyDirect(
            agent,
            PropertyKey.from("rawJSON"),
            Value.from(json_string),
        );

        // 10. Perform ! SetIntegrityLevel(obj, frozen).
        _ = raw_json.object.setIntegrityLevel(agent, .frozen) catch |err| try noexcept(err);

        // 11. Return obj.
        return Value.from(&raw_json.object);
    }

    /// 25.5.4 JSON.stringify ( value [ , replacer [ , space ] ] )
    /// https://tc39.es/ecma262/#sec-json.stringify
    fn stringify(agent: *Agent, _: Value, arguments: Arguments) Agent.Error!Value {
        const realm = agent.currentRealm();
        const value = arguments.get(0);
        const replacer = arguments.get(1);
        var space = arguments.get(2);

        // 1. Let stack be a new empty List.
        var stack: JSONSerialization.Stack = .empty;
        defer stack.deinit(agent.gc_allocator);

        // 2. Let indent be the empty String.
        const indent: *const String = .empty;

        // 3. Let propertyList be undefined.
        var property_list: ?PropertyKey.ArrayHashMap(void) = null;
        defer if (property_list) |*p| p.deinit(agent.gc_allocator);

        // 4. Let replacerFunc be undefined.
        var replacer_func: ?*Object = null;

        // 5. If replacer is an Object, then
        if (replacer.isObject()) {
            // a. If IsCallable(replacer) is true, then
            if (replacer.isCallable()) {
                // i. Set replacerFunc to replacer.
                replacer_func = replacer.asObject();
            } else {
                // b. Else,
                // i. Let isArray be ? IsArray(replacer).
                const is_array = try replacer.isArray(agent);

                // ii. If isArray is true, then
                if (is_array) {
                    // 1. Set propertyList to a new empty List.
                    property_list = .empty;

                    // 2. Let length be ? LengthOfArrayLike(replacer).
                    const length = try replacer.asObject().lengthOfArrayLike(agent);

                    // 3. Let k be 0.
                    var k: u53 = 0;

                    // 4. Repeat, while k < length,
                    while (k < length) : (k += 1) {
                        // a. Let propertyKey be ! ToString(𝔽(k)).
                        const property_key = PropertyKey.from(k);

                        // b. Let propertyValue be ? Get(replacer, propertyKey).
                        const property_value = try replacer.asObject().get(agent, property_key);

                        // c. Let item be undefined.
                        var item: ?PropertyKey = null;

                        // d. If propertyValue is a String, then
                        if (property_value.isString()) {
                            // i. Set item to propertyValue.
                            item = PropertyKey.from(property_value.asString());
                        }
                        // e. Else if propertyValue is a Number, then
                        else if (property_value.isNumber()) {
                            // i. Set item to ! ToString(propertyValue).
                            item = PropertyKey.from(
                                try property_value.asNumber().toString(agent, 10),
                            );
                        }
                        // f. Else if propertyValue is an Object, then
                        else if (property_value.isObject()) {
                            // i. If propertyValue has a [[StringData]] or [[NumberData]] internal
                            //    slot, set item to ? ToString(propertyValue).
                            if (property_value.asObject().is(builtins.String) or property_value.asObject().is(builtins.Number)) {
                                item = PropertyKey.from(try property_value.toString(agent));
                            }
                        }

                        // g. If item is not undefined and propertyList does not contain item, then
                        if (item != null and !property_list.?.contains(item.?)) {
                            // i. Append item to propertyList.
                            try property_list.?.putNoClobber(agent.gc_allocator, item.?, {});
                        }

                        // h. Set k to k + 1.
                    }
                }
            }
        }

        // 6. If space is an Object, then
        if (space.isObject()) {
            // a. If space has a [[NumberData]] internal slot, then
            if (space.asObject().is(builtins.Number)) {
                // i. Set space to ? ToNumber(space).
                space = Value.from(try space.toNumber(agent));
            }
            // b. Else if space has a [[StringData]] internal slot, then
            else if (space.asObject().is(builtins.String)) {
                // i. Set space to ? ToString(space).
                space = Value.from(try space.toString(agent));
            }
        }

        // 7. If space is a Number, then
        const gap: *const String = if (space.isNumber()) blk: {
            // a. Let spaceMV be ! ToIntegerOrInfinity(space).
            // b. Set spaceMV to min(10, spaceMV).
            const space_mv = @min(10, space.toIntegerOrInfinity(agent) catch unreachable);

            // c. If spaceMV < 1, let gap be the empty String; else let gap be the String value
            //    containing spaceMV occurrences of the code unit 0x0020 (SPACE).
            if (space_mv < 1)
                break :blk .empty
            else {
                const s = try agent.gc_allocator.alloc(u8, @intFromFloat(space_mv));
                @memset(s, ' ');
                break :blk try String.fromAscii(agent, s);
            }
        } else if (space.isString()) blk: {
            // 8. Else if space is a String, then
            // a. If the length of space ≤ 10, let gap be space; else let gap be the substring of
            //    space from 0 to 10.
            break :blk if (space.asString().length <= 10)
                space.asString()
            else
                try space.asString().substring(agent, 0, 10);
        } else blk: {
            // 9. Else,
            // a. Let gap be the empty String.
            break :blk .empty;
        };

        // 10. Let wrapper be OrdinaryObjectCreate(%Object.prototype%).
        const wrapper = try ordinaryObjectCreate(
            agent,
            try realm.intrinsic(.object_prototype),
        );

        // 11. Perform ! CreateDataPropertyOrThrow(wrapper, the empty String, value).
        try wrapper.createDataPropertyDirect(agent, PropertyKey.from(""), value);

        // 12. Let state be the JSON Serialization Record { [[ReplacerFunction]]: replacerFunc,
        //     [[Stack]]: stack, [[Indent]]: indent, [[Gap]]: gap, [[PropertyList]]: propertyList }.
        var state: JSONSerialization = .{
            .replacer_function = replacer_func,
            .stack = stack,
            .indent = indent,
            .gap = gap,
            .property_list = property_list,
        };

        // 13. Return ? SerializeJSONProperty(state, the empty String, wrapper).
        return if (try serializeJSONProperty(agent, &state, PropertyKey.from(""), wrapper)) |string|
            Value.from(string)
        else
            .undefined;
    }
};
