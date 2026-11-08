//! 22.2 RegExp (Regular Expression) Objects
//! https://tc39.es/ecma262/#sec-regexp-regular-expression-objects

const std = @import("std");

const libregexp = @import("libregexp");

const build_options = @import("build-options");
const builtins = @import("../builtins.zig");
const execution = @import("../execution.zig");
const types = @import("../types.zig");

const Agent = execution.Agent;
const Arguments = types.Arguments;
const MakeObject = types.MakeObject;
const Object = types.Object;
const PropertyKey = types.PropertyKey;
const Realm = execution.Realm;
const String = types.String;
const Value = types.Value;
const arrayCreateFast = builtins.arrayCreateFast;
const arrayCreateFastWithShape = builtins.arrayCreateFastWithShape;
const createArrayFromList = types.createArrayFromList;
const createBuiltinFunction = builtins.createBuiltinFunction;
const createRegExpStringIterator = builtins.createRegExpStringIterator;
const getSubstitution = builtins.getSubstitution;
const ordinaryCreateFromConstructor = builtins.ordinaryCreateFromConstructor;
const ordinaryObjectCreate = builtins.ordinaryObjectCreate;
const sameValue = types.sameValue;

fn compileRegexp(
    agent: *Agent,
    pattern: *const String,
    flags: *const String,
) Agent.Error!libregexp.Bytecode {
    const gpa = agent.gpa;

    const parsed_flags = blk: {
        if (flags.isEmpty()) break :blk libregexp.Flags.empty;
        switch (flags.asAsciiOrUtf16()) {
            .ascii => |ascii| if (libregexp.Flags.parse(ascii)) |parsed_flags|
                break :blk parsed_flags,
            .utf16 => {},
        }
        return agent.throwException(
            .syntax_error,
            "Invalid RegExp flags '{f}'",
            .{flags.fmtEscaped()},
        );
    };

    // NOTE: Despite passing in the buffer length below, this needs to be null-terminated.
    const buf = switch (pattern.asAsciiOrUtf16()) {
        .ascii => |ascii| try gpa.dupeSentinel(u8, ascii, 0),
        .utf16 => |utf16| blk: {
            if (parsed_flags.unicode or parsed_flags.unicode_sets) {
                break :blk try std.unicode.wtf16LeToWtf8AllocZ(gpa, utf16);
            }
            var cesu8: std.ArrayList(u8) = .empty;
            defer cesu8.deinit(gpa);
            var encoded: [3]u8 = undefined;
            for (utf16) |code_unit| {
                const len = std.unicode.wtf8Encode(code_unit, &encoded) catch unreachable;
                try cesu8.appendSlice(gpa, encoded[0..len]);
            }
            break :blk try cesu8.toOwnedSliceSentinel(gpa, 0);
        },
    };
    defer gpa.free(buf);

    var error_msg: []const u8 = undefined;
    const re_bytecode = libregexp.compile(
        agent.gc_allocator,
        buf,
        parsed_flags,
        &error_msg,
    ) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        error.LreError => {
            defer agent.gc_allocator.free(error_msg);
            return agent.throwException(
                .syntax_error,
                "Invalid RegExp pattern: {s}",
                .{error_msg},
            );
        },
    };
    return re_bytecode;
}

/// 22.2.3.1 RegExpCreate ( pattern, flags )
/// https://tc39.es/ecma262/#sec-regexpcreate
pub fn regExpCreate(agent: *Agent, pattern: Value, flags: Value) Agent.Error!*RegExp {
    const realm = agent.currentRealm();

    // 1. Let obj be ! RegExpAlloc(%RegExp%).
    const shape, _ = try realm.shape(.reg_exp_object);
    const regexp = try RegExp.createWithShape(agent, .{
        .shape = shape,
        .fields = .{
            .original_source = undefined,
            .original_flags = undefined,
            .re_bytecode = undefined,
        },
    });

    // 2. Return ? RegExpInitialize(obj, pattern, flags).
    return regExpInitialize(agent, regexp, pattern, flags);
}

pub fn regExpCreateFast(
    agent: *Agent,
    pattern: *const String,
    flags: *const String,
) Agent.Error!*RegExp {
    if (!build_options.enable_libregexp) {
        return agent.throwException(.internal_error, "RegExp support is disabled", .{});
    }
    const re_bytecode = try compileRegexp(agent, pattern, flags);
    const realm = agent.currentRealm();
    const shape, const offsets = try realm.shape(.reg_exp_object);
    const regexp = try RegExp.createWithShape(agent, .{
        .shape = shape,
        .fields = .{
            .original_source = pattern,
            .original_flags = flags,
            .re_bytecode = re_bytecode,
        },
    });
    regexp.object.setValueAtPropertyOffset(offsets.last_index, Value.from(0));
    return regexp;
}

/// 22.2.3.2 RegExpAlloc ( newTarget )
/// https://tc39.es/ecma262/#sec-regexpalloc
fn regExpAlloc(agent: *Agent, new_target: *Object) Agent.Error!*RegExp {
    // 1. Let obj be ? OrdinaryCreateFromConstructor(newTarget, "%RegExp.prototype%",
    //    « [[OriginalSource]], [[OriginalFlags]], [[RegExpRecord]], [[RegExpMatcher]] »).
    const regexp = try ordinaryCreateFromConstructor(
        RegExp,
        agent,
        new_target,
        .reg_exp_prototype,
        .{
            .original_source = undefined,
            .original_flags = undefined,
            .re_bytecode = undefined,
        },
    );

    // 2. Perform ! DefinePropertyOrThrow(obj, "lastIndex", PropertyDescriptor { [[Writable]]: true,
    //    [[Enumerable]]: false, [[Configurable]]: false }).
    try regexp.object.definePropertyDirect(agent, PropertyKey.from("lastIndex"), .{
        .value_or_accessor = .{
            .value = .undefined,
        },
        .attributes = .{
            .writable = true,
            .enumerable = false,
            .configurable = false,
        },
    });

    // 3. Return obj.
    return regexp;
}

/// 22.2.3.3 RegExpInitialize ( obj, pattern, flags )
/// https://tc39.es/ecma262/#sec-regexpinitialize
fn regExpInitialize(
    agent: *Agent,
    regexp: *RegExp,
    pattern_value: Value,
    flags_value: Value,
) Agent.Error!*RegExp {
    if (!build_options.enable_libregexp) {
        return agent.throwException(.internal_error, "RegExp support is disabled", .{});
    }

    // 1. If pattern is undefined, set pattern to the empty String.
    // 2. Else, set pattern to ? ToString(pattern).
    const pattern: *const String = if (pattern_value.isUndefined()) .empty else try pattern_value.toString(agent);

    // 3. If flags is undefined, set flags to the empty String.
    // 4. Else, set flags to ? ToString(flags).
    const flags: *const String = if (flags_value.isUndefined()) .empty else try flags_value.toString(agent);

    // 5. If flags contains any code unit other than "d", "g", "i", "m", "s", "u", "v", or "y",
    //    throw a SyntaxError exception.
    // 6. If flags contains any code unit more than once, throw a SyntaxError exception.
    // 7. If flags contains "i", let i be true; else let i be false.
    // 8. If flags contains "m", let m be true; else let m be false.
    // 9. If flags contains "s", let s be true; else let s be false.
    // 10. If flags contains "u", let u be true; else let u be false.
    // 11. If flags contains "v", let v be true; else let v be false.
    // TODO: 12. If u is true or v is true, then
    //     a. Let patternText be StringToCodePoints(pattern).
    // 13. Else,
    //     a. Let patternText be the result of interpreting each of pattern's 16-bit elements as a
    //        Unicode BMP code point. UTF-16 decoding is not applied to the elements.
    // 14. Let parseResult be ParsePattern(patternText, u, v).
    // 15. If parseResult is a non-empty List of SyntaxError objects, throw a SyntaxError exception.
    // 16. Assert: parseResult is a Pattern Parse Node.
    const re_bytecode = try compileRegexp(agent, pattern, flags);

    // 17. Set obj.[[OriginalSource]] to pattern.
    regexp.fields.original_source = pattern;

    // 18. Set obj.[[OriginalFlags]] to flags.
    regexp.fields.original_flags = flags;

    // 19. Let capturingGroupsCount be CountLeftCapturingParensWithin(parseResult).
    // 20. Let regexpRecord be the RegExp Record { [[IgnoreCase]]: i, [[Multiline]]: m,
    //     [[DotAll]]: s, [[Unicode]]: u, [[UnicodeSets]]: v,
    //     [[CapturingGroupsCount]]: capturingGroupsCount }.
    // 21. Set obj.[[RegExpRecord]] to regexpRecord.
    // 22. Set obj.[[RegExpMatcher]] to CompilePattern of parseResult with argument regexpRecord.
    regexp.fields.re_bytecode = re_bytecode;

    // 23. Perform ? Set(obj, "lastIndex", +0𝔽, true).
    try regexp.object.set(agent, PropertyKey.from("lastIndex"), Value.from(0), .throw);

    // 24. Return obj.
    return regexp;
}

/// 22.2.7.1 RegExpExec ( regexp, string )
/// https://tc39.es/ecma262/#sec-regexpexec
pub fn regExpExec(agent: *Agent, regexp: *Object, string: *const String) Agent.Error!?*Object {
    // 1. Let exec be ? Get(regexp, "exec").
    const exec = try regexp.get(agent, PropertyKey.from("exec"));

    // 2. If IsCallable(exec) is true, then
    if (exec.isCallable()) {
        // a. Let result be ? Call(exec, regexp, « string »).
        const result = try exec.asObject().call(agent, Value.from(regexp), &.{Value.from(string)});

        // b. If result is not an Object and result is not null, throw a TypeError exception.
        if (!result.isObject() and !result.isNull()) {
            return agent.throwException(
                .type_error,
                "RegExp exec function must return object or null",
                .{},
            );
        }

        // c. Return result.
        return if (result.isObject()) result.asObject() else null;
    }

    // 3. Perform ? RequireInternalSlot(regexp, [[RegExpMatcher]]).
    // 4. Return ? RegExpBuiltinExec(regexp, string).
    return regExpBuiltinExec(
        agent,
        try Value.from(regexp).requireInternalSlot(agent, RegExp),
        string,
    );
}

/// 22.2.7.2 RegExpBuiltinExec ( regexp, string )
/// https://tc39.es/ecma262/#sec-regexpbuiltinexec
pub fn regExpBuiltinExec(agent: *Agent, regexp: *RegExp, string: *const String) Agent.Error!?*Object {
    if (!build_options.enable_libregexp) {
        return agent.throwException(.internal_error, "RegExp support is disabled", .{});
    }

    const gpa = agent.gpa;

    // 1. Let length be the length of string.
    const length = string.length;

    // 2. Let lastIndex be ℝ(? ToLength(! Get(regexp, "lastIndex"))).
    const last_index_value = regexp.object.getPropertyValueDirect(PropertyKey.from("lastIndex"));
    var last_index: libregexp.CodeUnitIndex = @fromBackingInt(
        std.math.lossyCast(u32, try last_index_value.toLength(agent)),
    );

    const re_bytecode = regexp.fields.re_bytecode;
    const capture_count = re_bytecode.captureCount();

    // libregexp's capture count includes the matched string
    std.debug.assert(capture_count >= 1);

    // 3. Let flags be regexp.[[OriginalFlags]].
    const re_flags = re_bytecode.flags();

    // 4. If flags contains "g", let global be true; else let global be false.
    // 5. If flags contains "y", let sticky be true; else let sticky be false.
    // 6. If flags contains "d", let hasIndices be true; else let hasIndices be false.

    // 7. If global is false and sticky is false, set lastIndex to 0.
    if (!re_flags.global and !re_flags.sticky) {
        last_index = @fromBackingInt(0);
    }

    // 8-13.
    const maybe_captures = if (@backingInt(last_index) > length) null else libregexp.exec(
        gpa,
        re_bytecode,
        switch (string.asAsciiOrUtf16()) {
            .ascii => |ascii| .{ .ascii = ascii },
            .utf16 => |utf16| .{ .utf16 = utf16 },
        },
        last_index,
    ) catch |err| {
        const reason = switch (err) {
            error.OutOfMemory => "Out of memory",
            error.Timeout => "Timeout exceeded",
            else => unreachable,
        };
        return agent.throwException(.internal_error, "Failed to execute RegExp: {s}", .{reason});
    };
    const captures = maybe_captures orelse {
        if (@backingInt(last_index) > length or re_flags.global or re_flags.sticky) {
            try regexp.object.set(
                agent,
                PropertyKey.from("lastIndex"),
                Value.from(0),
                .throw,
            );
        }
        return null;
    };
    defer gpa.free(captures);
    var match = captures[0].?;
    last_index = match.start_index;

    // 14. Let endIndex be result.[[EndIndex]].
    // 15. If fullUnicode is true, set endIndex to GetStringIndex(string, endIndex).
    const end_index = match.end_index;

    // 16. If global is true or sticky is true, then
    if (re_flags.global or re_flags.sticky) {
        // a. Perform ? Set(regexp, "lastIndex", 𝔽(endIndex), true).
        try regexp.object.set(
            agent,
            PropertyKey.from("lastIndex"),
            Value.from(@backingInt(end_index)),
            .throw,
        );
    }

    // 17. Let capturingGroupsCount be the number of elements in result.[[Captures]].
    const capturing_groups_count = capture_count - 1;

    // 18. Assert: capturingGroupsCount = regexp.[[RegExpRecord]].[[CapturingGroupsCount]].
    // 19. Assert: capturingGroupsCount < 2**32 - 1.
    std.debug.assert(capturing_groups_count < std.math.maxInt(u32));

    // 20. Let array be ! ArrayCreate(capturingGroupsCount + 1).
    // 21. Assert: The mathematical value of array's "length" property is capturingGroupsCount + 1.
    const realm = agent.currentRealm();
    const array_shape, const array_offsets = try realm.shape(.reg_exp_exec_object);
    const array = try arrayCreateFastWithShape(agent, @intCast(capturing_groups_count + 1), array_shape);
    const array_indexed_properties = try array.object.ensureIndexedProperties(agent.gc_allocator);

    // 22. Perform ! CreateDataPropertyOrThrow(array, "index", 𝔽(lastIndex)).
    array.object.setValueAtPropertyOffset(array_offsets.index, Value.from(@backingInt(last_index)));

    // 23. Perform ! CreateDataPropertyOrThrow(array, "input", string).
    array.object.setValueAtPropertyOffset(array_offsets.input, Value.from(string));

    // 24. Let match be the Match Record { [[StartIndex]]: lastIndex, [[EndIndex]]: endIndex }.
    match = .{ .start_index = last_index, .end_index = end_index };

    // 25. Let indices be a new empty List.
    var indices: std.ArrayList(?libregexp.Match) = try .initCapacity(gpa, capturing_groups_count + 1);
    defer indices.deinit(gpa);

    // 26. Let groupNames be a new empty List.
    var group_names: std.ArrayList(?[]const u8) = try .initCapacity(gpa, capturing_groups_count + 1);
    defer group_names.deinit(gpa);

    // 27. Append match to indices.
    indices.appendAssumeCapacity(match);

    // 28. Let matchedSubstring be GetMatchString(string, match).
    const matched_substring = try getMatchString(agent, string, match);

    // 29. Perform ! CreateDataPropertyOrThrow(array, "0", matchedSubstring).
    try array_indexed_properties.set(
        agent.gc_allocator,
        0,
        .{
            .value_or_accessor = .{
                .value = Value.from(matched_substring),
            },
            .attributes = .all,
        },
    );

    var group_names_it = re_bytecode.groupNames();
    const has_groups = re_flags.named_groups;

    // 30. If regexp contains any GroupName, then
    const groups: Value = if (has_groups) blk: {
        // a. Let groups be OrdinaryObjectCreate(null).
        break :blk Value.from(try ordinaryObjectCreate(agent, null));

        // b. Let hasGroups be true.
    } else blk: {
        // 31. Else,
        // a. Let groups be undefined.
        break :blk .undefined;

        // b. Let hasGroups be false.
    };

    // 32. Perform ! CreateDataPropertyOrThrow(array, "groups", groups).
    array.object.setValueAtPropertyOffset(array_offsets.groups, groups);

    // 33. Let matchedGroupNames be a new empty List.
    var matched_group_names: std.StringHashMapUnmanaged(void) = .empty;
    defer matched_group_names.deinit(gpa);

    // 34. For each integer i such that 1 ≤ i ≤ capturingGroupsCount, in ascending order, do
    var i: usize = 1;
    while (i <= capturing_groups_count) : (i += 1) {
        var captured_value: Value = undefined;

        // a. Let capture be ith element of result.[[Captures]].
        const capture_i = captures[i];

        // b. If capture is undefined, then
        if (capture_i == null) {
            // i. Let capturedValue be undefined.
            captured_value = .undefined;

            // ii. Append undefined to indices.
            indices.appendAssumeCapacity(null);
        } else {
            // c. Else,
            // i. Let captureStart be capture.[[StartIndex]].
            // ii. Let captureEnd be capture.[[EndIndex]].
            // iii. If fullUnicode is true, then
            //     1. Set captureStart to GetStringIndex(string, captureStart).
            //     2. Set captureEnd to GetStringIndex(string, captureEnd).
            // iv. Let captureRecord be the Match Record { [[StartIndex]]: captureStart,
            //     [[EndIndex]]: captureEnd }.
            const capture = capture_i.?;

            // v. Let capturedValue be GetMatchString(string, captureRecord).
            captured_value = Value.from(try getMatchString(agent, string, capture));

            // vi. Append captureRecord to indices.
            indices.appendAssumeCapacity(capture);
        }

        // d. Perform ! CreateDataPropertyOrThrow(array, ! ToString(𝔽(i)), capturedValue).
        // OPTIMIZATION: Because the array is created with the right length we can set indexed
        //               properties directly here.
        try array_indexed_properties.set(
            agent.gc_allocator,
            @intCast(i),
            .{
                .value_or_accessor = .{
                    .value = captured_value,
                },
                .attributes = .all,
            },
        );

        // e. If the ith capture of regexp was defined with a GroupName, then
        if (group_names_it.next()) |group_name| {
            // i. Let groupName be the CapturingGroupName of that GroupName.
            // ii. If matchedGroupNames contains groupName, then
            if (matched_group_names.contains(group_name)) {
                // 1. Assert: capturedValue is undefined.
                std.debug.assert(captured_value.isUndefined());

                // 2. Append undefined to groupNames.
                group_names.appendAssumeCapacity(null);
            } else {
                // iii. Else,
                // 1. If capturedValue is not undefined, append groupName to matchedGroupNames.
                if (!captured_value.isUndefined()) {
                    try matched_group_names.put(gpa, group_name, {});
                }

                // 2. NOTE: If there are multiple groups named groupName, groups may already have an
                //    groupName property at this point. However, because groups is an ordinary
                //    object whose properties are all writable data properties, the call to
                //    CreateDataPropertyOrThrow is nevertheless guaranteed to succeed.

                // 3. Perform ! CreateDataPropertyOrThrow(groups, groupName, capturedValue).
                const property_key = PropertyKey.from(
                    try String.fromUtf8(agent, group_name),
                );
                try groups.asObject().createDataPropertyDirect(agent, property_key, captured_value);

                // 4. Append groupName to groupNames.
                group_names.appendAssumeCapacity(group_name);
            }
        } else {
            // f. Else,
            // i. Append undefined to groupNames.
            group_names.appendAssumeCapacity(null);
        }
    }

    // 35. If hasIndices is true, then
    if (re_flags.indices) {
        // a. Let indicesArray be MakeMatchIndicesIndexPairArray(string, indices, groupNames,
        //    hasGroups).
        const indices_array = try makeMatchIndicesIndexPairArray(
            agent,
            string,
            indices.items,
            group_names.items,
            has_groups,
        );

        // b. Perform ! CreateDataPropertyOrThrow(array, "indices", indicesArray).
        try array.object.createDataPropertyDirect(
            agent,
            PropertyKey.from("indices"),
            Value.from(&indices_array.object),
        );
    }

    // 36. Return array.
    return &array.object;
}

/// 22.2.7.3 AdvanceStringIndex ( string, index, unicode )
/// https://tc39.es/ecma262/#sec-advancestringindex
pub fn advanceStringIndex(string: *const String, index_: u53, unicode: bool) u54 {
    // 1. Assert: index ≤ 2**53 - 1.
    const index: u54 = @intCast(index_);

    // 2. If unicode is false, return index + 1.
    if (!unicode) return index + 1;

    // 3. Let length be the length of string.
    const length = string.length;

    // 4. If index + 1 ≥ length, return index + 1.
    if (index + 1 >= length) return index + 1;

    // 5. Let codePoint be CodePointAt(string, index).
    const code_point = string.codePointAt(@intCast(index));

    // 6. Return index + codePoint.[[CodeUnitCount]].
    return index + code_point.code_unit_count;
}

/// 22.2.7.6 GetMatchString ( string, match )
/// https://tc39.es/ecma262/#sec-getmatchstring
fn getMatchString(
    agent: *Agent,
    string: *const String,
    match: libregexp.Match,
) std.mem.Allocator.Error!*const String {
    // 1. Assert: match.[[StartIndex]] ≤ match.[[EndIndex]] ≤ the length of string.
    std.debug.assert(@backingInt(match.start_index) <= @backingInt(match.end_index));
    std.debug.assert(@backingInt(match.end_index) <= string.length);

    // 2. Return the substring of string from match.[[StartIndex]] to match.[[EndIndex]].
    return string.substring(agent, @backingInt(match.start_index), @backingInt(match.end_index));
}

/// 22.2.7.7 GetMatchIndexPair ( string, match )
/// https://tc39.es/ecma262/#sec-getmatchindexpair
fn getMatchIndexPair(
    agent: *Agent,
    string: *const String,
    match: libregexp.Match,
) std.mem.Allocator.Error!*builtins.Array {
    // 1. Assert: match.[[StartIndex]] ≤ match.[[EndIndex]] ≤ the length of string.
    std.debug.assert(@backingInt(match.start_index) <= @backingInt(match.end_index));
    std.debug.assert(@backingInt(match.end_index) <= string.length);

    // 2. Return CreateArrayFromList(« 𝔽(match.[[StartIndex]]), 𝔽(match.[[EndIndex]]) »).
    return createArrayFromList(agent, &.{
        Value.from(@backingInt(match.start_index)),
        Value.from(@backingInt(match.end_index)),
    });
}

/// 22.2.7.8 MakeMatchIndicesIndexPairArray ( string, indices, groupNames, hasGroups )
/// https://tc39.es/ecma262/#sec-makematchindicesindexpairarray
fn makeMatchIndicesIndexPairArray(
    agent: *Agent,
    string: *const String,
    indices: []const ?libregexp.Match,
    group_names: []const ?[]const u8,
    has_groups: bool,
) std.mem.Allocator.Error!*builtins.Array {
    // 1. Let n be the number of elements in indices.
    const n = indices.len;

    // 2. Assert: n < 2**32 - 1.
    std.debug.assert(n < std.math.maxInt(u32));

    // 3. Assert: groupNames has n - 1 elements.
    // 4. NOTE: The groupNames List contains elements aligned with the indices List starting at
    //    indices[1].
    std.debug.assert(group_names.len == n - 1);

    // 5. Let array be ! ArrayCreate(n).
    const array = try arrayCreateFast(agent, 0);

    // 6. If hasGroups is true, then
    const groups: Value = if (has_groups) blk: {
        // a. Let groups be OrdinaryObjectCreate(null).
        break :blk Value.from(try ordinaryObjectCreate(agent, null));
    } else blk: {
        // 7. Else,
        // a. Let groups be undefined.
        break :blk .undefined;
    };

    // 8. Perform ! CreateDataPropertyOrThrow(array, "groups", groups).
    try array.object.createDataPropertyDirect(agent, PropertyKey.from("groups"), groups);

    // 9. For each integer i such that 0 ≤ i < n, in ascending order, do
    var i: usize = 0;
    while (i < n) : (i += 1) {
        // a. Let matchIndices be indices[i].
        const match_indices = indices[i];

        // b. If matchIndices is not undefined, then
        const match_index_pair: Value = if (match_indices != null) blk: {
            // i. Let matchIndexPair be GetMatchIndexPair(string, matchIndices).
            const match_index_pair = try getMatchIndexPair(agent, string, match_indices.?);
            break :blk Value.from(&match_index_pair.object);
        } else blk: {
            // c. Else,
            // i. Let matchIndexPair be undefined.
            break :blk .undefined;
        };

        // d. Perform ! CreateDataPropertyOrThrow(array, ! ToString(𝔽(i)), matchIndexPair).
        try array.object.createDataPropertyDirect(
            agent,
            PropertyKey.from(@as(PropertyKey.IntegerIndex, @intCast(i))),
            match_index_pair,
        );

        // e. If i > 0, then
        if (i > 0) {
            // i. Let name be groupNames[i - 1].
            // ii. If name is not undefined, then
            if (group_names[i - 1]) |group_name| {
                // 1. Assert: groups is not undefined.
                std.debug.assert(!groups.isUndefined());

                // 2. NOTE: If there are multiple groups named name, groups may already have an name
                //    property at this point. However, because groups is an ordinary object whose
                //    properties are all writable data properties, the call to
                //    CreateDataPropertyOrThrow is nevertheless guaranteed to succeed.

                // 3. Perform ! CreateDataPropertyOrThrow(groups, name, matchIndexPair).
                const property_key = PropertyKey.from(
                    try String.fromUtf8(agent, try agent.gc_allocator.dupe(u8, group_name)),
                );
                try groups.asObject().createDataPropertyDirect(
                    agent,
                    property_key,
                    match_index_pair,
                );
            }
        }
    }

    // 10. Return array.
    return array;
}

/// 22.2.5 Properties of the RegExp Constructor
/// https://tc39.es/ecma262/#sec-properties-of-the-regexp-constructor
pub const constructor = struct {
    pub fn create(agent: *Agent, realm: *Realm) std.mem.Allocator.Error!*Object {
        const builtin_function = try createBuiltinFunction(
            agent,
            .{ .constructor = impl },
            2,
            "RegExp",
            .{ .realm = realm, .proto = try realm.intrinsic(.function_prototype) },
        );
        return &builtin_function.object;
    }

    pub fn init(agent: *Agent, realm: *Realm, object: *Object) std.mem.Allocator.Error!void {
        try object.defineBuiltinFunction(agent, "escape", escape, 1, realm);
        try object.defineBuiltinAccessor(agent, "Symbol.species", @"Symbol.species", null, realm);

        // 22.2.5.2 RegExp.prototype
        // https://tc39.es/ecma262/#sec-regexp.prototype
        try object.defineBuiltinPropertyWithAttributes(
            agent,
            "prototype",
            Value.from(try realm.intrinsic(.reg_exp_prototype)),
            .none,
        );
    }

    /// 22.2.4.1 RegExp ( patternOrRegexp, flags )
    /// https://tc39.es/ecma262/#sec-regexp-pattern-flags
    fn impl(agent: *Agent, arguments: Arguments, maybe_new_target: ?*Object) Agent.Error!Value {
        const pattern_or_regexp = arguments.get(0);
        var flags = arguments.get(1);

        // 1. Let patternIsRegExp be ? IsRegExp(patternOrRegexp).
        const pattern_is_regexp = try pattern_or_regexp.isRegExp(agent);

        // 2. If NewTarget is undefined, then
        const new_target = maybe_new_target orelse blk: {
            // a. Let newTarget be the active function object.
            const active_func = agent.activeFunctionObject();

            // b. If patternIsRegExp is true and flags is undefined, then
            if (pattern_is_regexp and flags.isUndefined()) {
                // i. Let patternCtor be ? Get(patternOrRegexp, "constructor").
                const pattern_ctor = try pattern_or_regexp.asObject().get(
                    agent,
                    PropertyKey.from("constructor"),
                );

                // ii. If SameValue(newTarget, patternCtor) is true, return patternOrRegexp.
                if (sameValue(Value.from(active_func), pattern_ctor)) return pattern_or_regexp;
            }

            break :blk active_func;
        };

        // 3. Else,
        //     a. Let newTarget be NewTarget.

        var pattern: Value = undefined;

        // 4. If patternOrRegexp is an Object and patternOrRegexp has a [[RegExpMatcher]] internal
        //    slot, then
        if (pattern_or_regexp.castObject(RegExp)) |obj| {
            // a. Let patternSource be patternOrRegexp.[[OriginalSource]].
            pattern = Value.from(obj.fields.original_source);

            // b. If flags is undefined, set flags to patternOrRegexp.[[OriginalFlags]].
            if (flags.isUndefined()) {
                flags = Value.from(obj.fields.original_flags);
            }
        }
        // 5. Else if patternIsRegExp is true, then
        else if (pattern_is_regexp) {
            // a. Let patternSource be ? Get(patternOrRegexp, "source").
            pattern = try pattern_or_regexp.asObject().get(agent, PropertyKey.from("source"));

            // b. If flags is undefined, then
            if (flags.isUndefined()) {
                // i. Set flags to ? Get(patternOrRegexp, "flags").
                flags = try pattern_or_regexp.asObject().get(agent, PropertyKey.from("flags"));
            }
        } else {
            // 6. Else,
            // a. Let patternSource be patternOrRegexp.
            pattern = pattern_or_regexp;
        }

        // 7. Let obj be ? RegExpAlloc(newTarget).
        const regexp = try regExpAlloc(agent, new_target);

        // 8. Return ? RegExpInitialize(obj, patternSource, flags).
        _ = try regExpInitialize(agent, regexp, pattern, flags);
        return Value.from(&regexp.object);
    }

    /// 22.2.5.1 RegExp.escape ( string )
    /// https://tc39.es/ecma262/#sec-regexp.escape
    fn escape(agent: *Agent, _: Value, arguments: Arguments) Agent.Error!Value {
        const string_value = arguments.get(0);

        // 1. If string is not a String, throw a TypeError exception.
        if (!string_value.isString()) {
            return agent.throwException(.type_error, "{f} is not a string", .{string_value});
        }
        const string = string_value.asString();

        // 2. Let escaped be the empty String.
        var escaped: String.Builder = .empty;
        defer escaped.deinit(agent.gc_allocator);

        // 3. Let codePointList be StringToCodePoints(string).
        // 4. For each code point codePoint of codePointList, do
        var position: u32 = 0;
        while (position < string.length) {
            const code_point = string.codePointAt(position);
            defer position += code_point.code_unit_count;

            // a. If escaped is the empty String and codePoint is matched by either DecimalDigit or
            //    AsciiLetter, then
            if (position == 0 and std.ascii.isAlphanumeric(std.math.cast(u8, code_point.code_point) orelse 0)) {
                // i. NOTE: Escaping a leading digit ensures that output corresponds with pattern
                //    text which may be used after a `\0` character escape or a DecimalEscape such
                //    as `\1` and still match string rather than be interpreted as an extension of
                //    the preceding escape sequence. Escaping a leading ASCII letter does the same
                //    for the context after `\c`.
                // ii. Let numericValue be the numeric value of codePoint.
                // iii. Let hex be Number::toString(𝔽(numericValue), 16).
                // iv. Assert: The length of hex is 2.
                // v. Set escaped to the string-concatenation of the code unit 0x005C (REVERSE
                //    SOLIDUS), "x", and hex.
                try escaped.appendString(
                    agent.gc_allocator,
                    try String.fromAscii(
                        agent,
                        try agent.gc_allocator.print("\\x{x}", .{code_point.code_point}),
                    ),
                );
            } else {
                // b. Else,
                // i. Set escaped to the string-concatenation of escaped and EncodeForRegExpEscape(
                //    codePoint).
                try encodeForRegExpEscape(agent.gc_allocator, &escaped, code_point);
            }
        }

        // 5. Return escaped.
        return Value.from(try escaped.build(agent));
    }

    /// 22.2.5.1.1 EncodeForRegExpEscape ( codePoint )
    /// https://tc39.es/ecma262/#sec-encodeforregexpescape
    fn encodeForRegExpEscape(
        allocator: std.mem.Allocator,
        escaped: *String.Builder,
        code_point: String.CodePoint,
    ) std.mem.Allocator.Error!void {
        var hex_escape = false;
        switch (code_point.code_point) {
            // 1. If codePoint is matched by SyntaxCharacter or codePoint is U+002F (SOLIDUS), then
            '^', '$', '\\', '.', '*', '+', '?', '(', ')', '[', ']', '{', '}', '|', '/' => {
                // a. Return the string-concatenation of 0x005C (REVERSE SOLIDUS) and
                //    UTF16EncodeCodePoint(codePoint).
                try escaped.appendChar(allocator, '\\');
                try escaped.appendChar(allocator, @intCast(code_point.code_point));
                return;
            },

            // 2. If codePoint is a code point listed in the “Code Point” column of Table 63, then
            '\t'...'\r' => {
                // a. Return the string-concatenation of 0x005C (REVERSE SOLIDUS) and the string in
                //    the “ControlEscape” column of the row whose “Code Point” column contains
                //    codePoint.
                try escaped.appendChar(allocator, '\\');
                try escaped.appendChar(
                    allocator,
                    ([5]u8{ 't', 'n', 'v', 'f', 'r' })[code_point.code_point - 0x09],
                );
                return;
            },

            // 3. Let otherPunctuators be the string-concatenation of ",-=<>#&!%:;@~'`" and the code
            //    unit 0x0022 (QUOTATION MARK).
            // 4. Let toEscape be StringToCodePoints(otherPunctuators).
            ',', '-', '=', '<', '>', '#', '&', '!', '%', ':', ';', '@', '~', '\'', '`', '"' => {
                hex_escape = true;
            },

            else => {},
        }

        // 5. If toEscape contains codePoint, codePoint is matched by either WhiteSpace or
        //    LineTerminator, or codePoint has the same numeric value as a leading surrogate or
        //    trailing surrogate, then
        if (hex_escape or
            std.mem.findScalar(u21, &String.whitespace_code_points, code_point.code_point) != null or
            code_point.is_unpaired_surrogate)
        {
            // a. Let codePointNumber be the numeric value of codePoint.
            // b. If codePointNumber ≤ 0xFF, then
            if (code_point.code_point <= 0xff) {
                // i. Let hex be Number::toString(𝔽(codePointNumber), 16).
                // ii. Return the string-concatenation of the code unit 0x005C (REVERSE SOLIDUS),
                //     "x", and StringPad(hex, 2, "0", start).
                const hex = try allocator.print("\\x{x:0>2}", .{code_point.code_point});
                // TODO: Support appending an ASCII slice to String.Builder
                for (hex) |c| {
                    try escaped.appendChar(allocator, c);
                }
                return;
            }

            // c. Let escaped be the empty String.
            // d. Let codeUnits be UTF16EncodeCodePoint(codePoint).
            // e. For each code unit codeUnit of codeUnits, do
            // i. Set escaped to the string-concatenation of escaped and UnicodeEscape(codeUnit).
            // f. Return escaped.
            const hex = try allocator.print("\\u{x:0>4}", .{code_point.code_point});
            // TODO: Support appending an ASCII slice to String.Builder
            for (hex) |c| {
                try escaped.appendChar(allocator, c);
            }
            return;
        }

        // 6. Return UTF16EncodeCodePoint(codePoint).
        try escaped.appendCodePoint(allocator, code_point.code_point);
    }

    /// 22.2.5.3 get RegExp [ %Symbol.species% ]
    /// https://tc39.es/ecma262/#sec-get-regexp-%symbol.species%
    fn @"Symbol.species"(_: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Return the this value.
        return this_value;
    }
};

/// 22.2.6 Properties of the RegExp Prototype Object
/// https://tc39.es/ecma262/#sec-properties-of-the-regexp-prototype-object
pub const prototype = struct {
    pub fn create(agent: *Agent, realm: *Realm) std.mem.Allocator.Error!*Object {
        return ordinaryObjectCreate(agent, try realm.intrinsic(.object_prototype));
    }

    pub fn init(agent: *Agent, realm: *Realm, object: *Object) std.mem.Allocator.Error!void {
        if (!build_options.enable_libregexp) return;

        try object.defineBuiltinAccessor(agent, "dotAll", dotAll, null, realm);
        try object.defineBuiltinFunction(agent, "exec", exec, 1, realm);
        try object.defineBuiltinAccessor(agent, "flags", flags, null, realm);
        try object.defineBuiltinAccessor(agent, "global", global, null, realm);
        try object.defineBuiltinAccessor(agent, "hasIndices", hasIndices, null, realm);
        try object.defineBuiltinAccessor(agent, "ignoreCase", ignoreCase, null, realm);
        try object.defineBuiltinFunction(agent, "Symbol.match", @"Symbol.match", 1, realm);
        try object.defineBuiltinFunction(agent, "Symbol.matchAll", @"Symbol.matchAll", 1, realm);
        try object.defineBuiltinAccessor(agent, "multiline", multiline, null, realm);
        try object.defineBuiltinFunction(agent, "Symbol.replace", @"Symbol.replace", 2, realm);
        try object.defineBuiltinFunction(agent, "Symbol.search", @"Symbol.search", 1, realm);
        try object.defineBuiltinAccessor(agent, "source", source, null, realm);
        try object.defineBuiltinFunction(agent, "Symbol.split", @"Symbol.split", 2, realm);
        try object.defineBuiltinAccessor(agent, "sticky", sticky, null, realm);
        try object.defineBuiltinFunction(agent, "test", @"test", 1, realm);
        try object.defineBuiltinFunction(agent, "toString", toString, 0, realm);
        try object.defineBuiltinAccessor(agent, "unicode", unicode, null, realm);
        try object.defineBuiltinAccessor(agent, "unicodeSets", unicodeSets, null, realm);

        // 22.2.6.1 RegExp.prototype.constructor
        // https://tc39.es/ecma262/#sec-regexp.prototype.constructor
        try object.defineBuiltinProperty(
            agent,
            "constructor",
            Value.from(try realm.intrinsic(.reg_exp)),
        );

        if (build_options.enable_annex_b) {
            try object.defineBuiltinFunction(agent, "compile", compile, 2, realm);
        }
    }

    /// 22.2.6.2 RegExp.prototype.exec ( string )
    /// https://tc39.es/ecma262/#sec-regexp.prototype.exec
    fn exec(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        // 1. Let regexp be the this value.
        // 2. Perform ? RequireInternalSlot(regexp, [[RegExpMatcher]]).
        const regexp = try this_value.requireInternalSlot(agent, RegExp);

        // 3. Set string to ? ToString(string).
        const string = try arguments.get(0).toString(agent);

        // 4. Return ? RegExpBuiltinExec(regexp, string).
        return if (try regExpBuiltinExec(agent, regexp, string)) |object|
            Value.from(object)
        else
            .null;
    }

    /// 22.2.6.3 get RegExp.prototype.dotAll
    /// https://tc39.es/ecma262/#sec-get-regexp.prototype.dotAll
    fn dotAll(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let regexp be the this value.
        // 2. Let codeUnit be the code unit 0x0073 (LATIN SMALL LETTER S).
        // 3. Return ? RegExpHasFlag(regexp, codeUnit).
        return regExpHasFlag(agent, this_value, .dotall);
    }

    /// 22.2.6.4 get RegExp.prototype.flags
    /// https://tc39.es/ecma262/#sec-get-regexp.prototype.flags
    fn flags(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let regexp be the this value.
        // 2. If regexp is not an Object, throw a TypeError exception.
        if (!this_value.isObject()) {
            return agent.throwException(.type_error, "{f} is not an Object", .{this_value});
        }
        const regexp = this_value.asObject();

        // 3. Let codeUnits be a new empty List.
        var code_units = try std.ArrayList(u8).initCapacity(agent.gc_allocator, 8);

        // 4. Let hasIndices be ToBoolean(? Get(regexp, "hasIndices")).
        // 5. If hasIndices is true, append the code unit 0x0064 (LATIN SMALL LETTER D) to
        //    codeUnits.
        if ((try regexp.get(agent, PropertyKey.from("hasIndices"))).toBoolean()) {
            code_units.appendAssumeCapacity('d');
        }

        // 6. Let global be ToBoolean(? Get(regexp, "global")).
        // 7. If global is true, append the code unit 0x0067 (LATIN SMALL LETTER G) to codeUnits.
        if ((try regexp.get(agent, PropertyKey.from("global"))).toBoolean()) {
            code_units.appendAssumeCapacity('g');
        }

        // 8. Let ignoreCase be ToBoolean(? Get(regexp, "ignoreCase")).
        // 9. If ignoreCase is true, append the code unit 0x0069 (LATIN SMALL LETTER I) to
        //    codeUnits.
        if ((try regexp.get(agent, PropertyKey.from("ignoreCase"))).toBoolean()) {
            code_units.appendAssumeCapacity('i');
        }

        // 10. Let multiline be ToBoolean(? Get(regexp, "multiline")).
        // 11. If multiline is true, append the code unit 0x006D (LATIN SMALL LETTER M) to
        //     codeUnits.
        if ((try regexp.get(agent, PropertyKey.from("multiline"))).toBoolean()) {
            code_units.appendAssumeCapacity('m');
        }

        // 12. Let dotAll be ToBoolean(? Get(regexp, "dotAll")).
        // 13. If dotAll is true, append the code unit 0x0073 (LATIN SMALL LETTER S) to codeUnits.
        if ((try regexp.get(agent, PropertyKey.from("dotAll"))).toBoolean()) {
            code_units.appendAssumeCapacity('s');
        }

        // 14. Let unicode be ToBoolean(? Get(regexp, "unicode")).
        // 15. If unicode is true, append the code unit 0x0075 (LATIN SMALL LETTER U) to codeUnits.
        if ((try regexp.get(agent, PropertyKey.from("unicode"))).toBoolean()) {
            code_units.appendAssumeCapacity('u');
        }

        // 16. Let unicodeSets be ToBoolean(? Get(regexp, "unicodeSets")).
        // 17. If unicodeSets is true, append the code unit 0x0076 (LATIN SMALL LETTER V) to
        //     codeUnits.
        if ((try regexp.get(agent, PropertyKey.from("unicodeSets"))).toBoolean()) {
            code_units.appendAssumeCapacity('v');
        }

        // 18. Let sticky be ToBoolean(? Get(regexp, "sticky")).
        // 19. If sticky is true, append the code unit 0x0079 (LATIN SMALL LETTER Y) to codeUnits.
        if ((try regexp.get(agent, PropertyKey.from("sticky"))).toBoolean()) {
            code_units.appendAssumeCapacity('y');
        }

        // 20. Return the String value whose code units are the elements of the List codeUnits. If
        //     codeUnits has no elements, the empty String is returned.
        return Value.from(
            try String.fromAscii(
                agent,
                try code_units.toOwnedSlice(agent.gc_allocator),
            ),
        );
    }

    /// 22.2.6.4.1 RegExpHasFlag ( regexp, codeUnit )
    /// https://tc39.es/ecma262/#sec-regexphasflag
    fn regExpHasFlag(agent: *Agent, regexp_value: Value, flag: libregexp.Flag) Agent.Error!Value {
        // 1. If regexp is not an Object, throw a TypeError exception.
        if (!regexp_value.isObject()) {
            return agent.throwException(.type_error, "{f} is not an Object", .{regexp_value});
        }

        // 2. If regexp does not have an [[OriginalFlags]] internal slot, then
        const regexp = regexp_value.asObject().cast(RegExp) orelse {
            const realm = agent.currentRealm();

            // a. If SameValue(regexp, %RegExp.prototype%) is true, return undefined.
            if (regexp_value.asObject() == try realm.intrinsic(.reg_exp_prototype)) {
                return .undefined;
            }

            // b. Throw a TypeError exception.
            return agent.throwException(.type_error, "This value must be a RegExp object", .{});
        };

        // 3. Let flags be regexp.[[OriginalFlags]].
        const re_bytecode = regexp.fields.re_bytecode;
        const re_flags = re_bytecode.flags();

        // 4. If flags contains codeUnit, return true.
        // 5. Return false.
        return Value.from(re_flags.isSet(flag));
    }

    /// 22.2.6.5 get RegExp.prototype.global
    /// https://tc39.es/ecma262/#sec-get-regexp.prototype.global
    fn global(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let regexp be the this value.
        // 2. Let codeUnit be the code unit 0x0067 (LATIN SMALL LETTER G).
        // 3. Return ? RegExpHasFlag(regexp, codeUnit).
        return regExpHasFlag(agent, this_value, .global);
    }

    /// 22.2.6.6 get RegExp.prototype.hasIndices
    /// https://tc39.es/ecma262/#sec-get-regexp.prototype.hasIndices
    fn hasIndices(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let regexp be the this value.
        // 2. Let codeUnit be the code unit 0x0064 (LATIN SMALL LETTER D).
        // 3. Return ? RegExpHasFlag(regexp, codeUnit).
        return regExpHasFlag(agent, this_value, .indices);
    }

    /// 22.2.6.7 get RegExp.prototype.ignoreCase
    /// https://tc39.es/ecma262/#sec-get-regexp.prototype.ignorecase
    fn ignoreCase(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let regexp be the this value.
        // 2. Let codeUnit be the code unit 0x0069 (LATIN SMALL LETTER I).
        // 3. Return ? RegExpHasFlag(regexp, codeUnit).
        return regExpHasFlag(agent, this_value, .ignorecase);
    }

    /// 22.2.6.8 RegExp.prototype [ %Symbol.match% ] ( string )
    /// https://tc39.es/ecma262/#sec-regexp.prototype-%symbol.match%
    fn @"Symbol.match"(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const string_value = arguments.get(0);

        // 1. Let regexp be the this value.
        // 2. If regexp is not an Object, throw a TypeError exception.
        if (!this_value.isObject()) {
            return agent.throwException(.type_error, "{f} is not an Object", .{this_value});
        }
        const regexp = this_value.asObject();

        // 3. Set string to ? ToString(string).
        const string = try string_value.toString(agent);

        // 4. Let flags be ? ToString(? Get(regexp, "flags")).
        const flags_ = try (try regexp.get(agent, PropertyKey.from("flags"))).toString(agent);

        // 5. If flags does not contain "g", return ? RegExpExec(regexp, string).
        if (flags_.indexOf(String.fromLiteral("g"), 0) == null) {
            return if (try regExpExec(agent, regexp, string)) |object|
                Value.from(object)
            else
                .null;
        }

        // 6. If flags contains "u" or flags contains "v", let fullUnicode be true; else let
        //    fullUnicode be false.
        const full_unicode = flags_.indexOf(String.fromLiteral("u"), 0) != null or
            flags_.indexOf(String.fromLiteral("v"), 0) != null;

        // 7. Perform ? Set(regexp, "lastIndex", +0𝔽, true).
        try regexp.set(agent, PropertyKey.from("lastIndex"), Value.from(0), .throw);

        // 8. Let array be ! ArrayCreate(0).
        const array = try arrayCreateFast(agent, 0);

        // 9. Let matchCount be 0.
        var match_count: u53 = 0;

        // 10. Repeat,
        while (true) : (match_count += 1) {
            // a. Let result be ? RegExpExec(regexp, string).
            const result = try regExpExec(agent, regexp, string);

            // b. If result is null, then
            if (result == null) {
                // i. If matchCount = 0, return null.
                if (match_count == 0) return .null;

                // ii. Return array.
                return Value.from(&array.object);
            }

            // c. Let matchString be ? ToString(? Get(result, "0")).
            const match_string = try (try result.?.get(agent, PropertyKey.from(0))).toString(agent);

            // d. Perform ! CreateDataPropertyOrThrow(array, ! ToString(𝔽(matchCount)),
            //    matchString).
            try array.object.createDataPropertyDirect(
                agent,
                PropertyKey.from(match_count),
                Value.from(match_string),
            );

            // e. If matchString is the empty String, then
            if (match_string.isEmpty()) {
                // i. Let thisIndex be ℝ(? ToLength(? Get(regexp, "lastIndex"))).
                const this_index = try (try regexp.get(
                    agent,
                    PropertyKey.from("lastIndex"),
                )).toLength(agent);

                // ii. Let nextIndex be AdvanceStringIndex(string, thisIndex, fullUnicode).
                const next_index = advanceStringIndex(string, this_index, full_unicode);

                // iii. Perform ? Set(regexp, "lastIndex", 𝔽(nextIndex), true).
                try regexp.set(
                    agent,
                    PropertyKey.from("lastIndex"),
                    Value.from(@as(f64, @floatFromInt(next_index))),
                    .throw,
                );
            }

            // f. Set matchCount to matchCount + 1.
        }
    }

    /// 22.2.6.9 RegExp.prototype [ %Symbol.matchAll% ] ( string )
    /// https://tc39.es/ecma262/#sec-regexp-prototype-%symbol.matchall%
    fn @"Symbol.matchAll"(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const string_value = arguments.get(0);
        const realm = agent.currentRealm();

        // 1. Let regexp be the this value.
        // 2. If regexp is not an Object, throw a TypeError exception.
        if (!this_value.isObject()) {
            return agent.throwException(.type_error, "{f} is not an Object", .{this_value});
        }
        const regexp = this_value.asObject();

        // 3. Set string to ? ToString(string).
        const string = try string_value.toString(agent);

        // 4. Let speciesCtor be ? SpeciesConstructor(regexp, %RegExp%).
        const species_ctor = try regexp.speciesConstructor(
            agent,
            try realm.intrinsic(.reg_exp),
        );

        // 5. Let flags be ? ToString(? Get(regexp, "flags")).
        const flags_ = try (try regexp.get(agent, PropertyKey.from("flags"))).toString(agent);

        // 6. Let matcher be ? Construct(speciesCtor, « regexp, flags »).
        const matcher = try species_ctor.construct(
            agent,
            &.{ Value.from(regexp), Value.from(flags_) },
            null,
        );

        // 7. Let lastIndex be ? ToLength(? Get(regexp, "lastIndex")).
        const last_index = try (try regexp.get(agent, PropertyKey.from("lastIndex"))).toLength(agent);

        // 8. Perform ? Set(matcher, "lastIndex", lastIndex, true).
        try matcher.set(agent, PropertyKey.from("lastIndex"), Value.from(last_index), .throw);

        // 9. If flags contains "g", let global be true.
        // 10. Else, let global be false.
        const global_ = flags_.indexOf(String.fromLiteral("g"), 0) != null;

        // 11. If flags contains "u" or flags contains "v", let fullUnicode be true.
        // 12. Else, let fullUnicode be false.
        const full_unicode = flags_.indexOf(String.fromLiteral("u"), 0) != null or
            flags_.indexOf(String.fromLiteral("v"), 0) != null;

        // 13. Return CreateRegExpStringIterator(matcher, string, global, fullUnicode).
        const regexp_string_iterator = try createRegExpStringIterator(
            agent,
            matcher,
            string,
            global_,
            full_unicode,
        );
        return Value.from(&regexp_string_iterator.object);
    }

    /// 22.2.6.10 get RegExp.prototype.multiline
    /// https://tc39.es/ecma262/#sec-get-regexp.prototype.multiline
    fn multiline(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let regexp be the this value.
        // 2. Let codeUnit be the code unit 0x006D (LATIN SMALL LETTER M).
        // 3. Return ? RegExpHasFlag(regexp, codeUnit).
        return regExpHasFlag(agent, this_value, .multiline);
    }

    /// 22.2.6.11 RegExp.prototype [ %Symbol.replace% ] ( string, replaceValue )
    /// https://tc39.es/ecma262/#sec-regexp.prototype-%symbol.replace%
    fn @"Symbol.replace"(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const string_value = arguments.get(0);
        var replace_value = arguments.get(1);

        // 1. Let regexp be the this value.
        // 2. If regexp is not an Object, throw a TypeError exception.
        if (!this_value.isObject()) {
            return agent.throwException(.type_error, "{f} is not an Object", .{this_value});
        }
        const regexp = this_value.asObject();

        // 3. Set string to ? ToString(string).
        const string = try string_value.toString(agent);

        // 4. Let stringLength be the length of string.
        const string_length = string.length;

        // 5. Let functionalReplace be IsCallable(replaceValue).
        const functional_replace = replace_value.isCallable();

        // 6. If functionalReplace is false, then
        if (!functional_replace) {
            // a. Set replaceValue to ? ToString(replaceValue).
            replace_value = Value.from(try replace_value.toString(agent));
        }

        // 7. Let flags be ? ToString(? Get(regexp, "flags")).
        const flags_ = try (try regexp.get(agent, PropertyKey.from("flags"))).toString(agent);

        // 8. If flags contains "g", let global be true; else let global be false.
        const global_ = flags_.indexOf(String.fromLiteral("g"), 0) != null;

        // 9. If global is true, then
        if (global_) {
            // a. Perform ? Set(regexp, "lastIndex", +0𝔽, true).
            try regexp.set(agent, PropertyKey.from("lastIndex"), Value.from(0), .throw);
        }

        // 10. Let results be a new empty List.
        var results: std.ArrayList(*Object) = .empty;
        defer results.deinit(agent.gc_allocator);

        // 11. Let done be false.
        // 12. Repeat, while done is false,
        while (true) {
            // a. Let result be ? RegExpExec(regexp, string).
            const result = try regExpExec(agent, regexp, string) orelse {
                // b. If result is null, then
                //     i. Set done to true.
                break;
            };

            // c. Else,
            // i. Append result to results.
            try results.append(agent.gc_allocator, result);

            // ii. If global is false, then
            if (!global_) {
                // 1. Set done to true.
                break;
            }

            // iii. Else,
            // 1. Let matchString be ? ToString(? Get(result, "0")).
            const match_string = try (try result.get(agent, PropertyKey.from(0))).toString(agent);

            // 2. If matchString is the empty String, then
            if (match_string.isEmpty()) {
                // a. Let thisIndex be ℝ(? ToLength(? Get(regexp, "lastIndex"))).
                const this_index = try (try regexp.get(agent, PropertyKey.from("lastIndex"))).toLength(agent);

                // b. If flags contains "u" or flags contains "v", let fullUnicode be true; else let
                //    fullUnicode be false.
                const full_unicode = flags_.indexOf(String.fromLiteral("u"), 0) != null or
                    flags_.indexOf(String.fromLiteral("v"), 0) != null;

                // c. Let nextIndex be AdvanceStringIndex(string, thisIndex, fullUnicode).
                const next_index = advanceStringIndex(string, this_index, full_unicode);

                // d. Perform ? Set(regexp, "lastIndex", 𝔽(nextIndex), true).
                try regexp.set(
                    agent,
                    PropertyKey.from("lastIndex"),
                    Value.from(@as(f64, @floatFromInt(next_index))),
                    .throw,
                );
            }
        }

        // 13. Let accumulatedResult be the empty String.
        var accumulated_result: String.Builder = .empty;
        defer accumulated_result.deinit(agent.gc_allocator);

        // 14. Let nextSourcePosition be 0.
        var next_source_position: u32 = 0;

        // 15. For each element result of results, do
        for (results.items) |result| {
            // a. Let resultLength be ? LengthOfArrayLike(result).
            const result_length = try result.lengthOfArrayLike(agent);

            // b. Let capturesCount be max(resultLength - 1, 0).
            const captures_count = result_length -| 1;

            // c. Let matched be ? ToString(? Get(result, "0")).
            const matched = try (try result.get(agent, PropertyKey.from(0))).toString(agent);

            // d. Let matchLength be the length of matched.
            const matched_length = matched.length;

            // e. Let position be ? ToIntegerOrInfinity(? Get(result, "index")).
            const position_f64 = try (try result.get(agent, PropertyKey.from("index"))).toIntegerOrInfinity(agent);

            // f. Set position to the result of clamping position between 0 and stringLength.
            const position = std.math.clamp(
                std.math.lossyCast(u32, position_f64),
                0,
                string_length,
            );

            // g. Let captures be a new empty List.
            var captures = try std.ArrayList(?*const String).initCapacity(
                agent.gc_allocator,
                @intCast(captures_count),
            );
            defer captures.deinit(agent.gc_allocator);

            // h. Let captureNumber be 1.
            var capture_number: u53 = 1;

            // i. Repeat, while captureNumber ≤ capturesCount,
            while (capture_number <= captures_count) : (capture_number += 1) {
                var capture_string: ?*const String = null;

                // i. Let capture be ? Get(result, ! ToString(𝔽(captureNumber))).
                var capture = try result.get(agent, PropertyKey.from(capture_number));

                // ii. If capture is not undefined, then
                if (!capture.isUndefined()) {
                    // 1. Set capture to ? ToString(capture).
                    capture_string = try capture.toString(agent);
                }

                // iii. Append capture to captures.
                captures.appendAssumeCapacity(capture_string);

                // iv. NOTE: When captureNumber = 1, the preceding step puts the first element into
                //     captures (at index 0). More generally, the captureNumberth capture (the
                //     characters captured by the captureNumberth set of capturing parentheses) is
                //     at captures[captureNumber - 1].

                // v. Set captureNumber to captureNumber + 1.
            }

            // j. Let namedCaptures be ? Get(result, "groups").
            var named_captures = try result.get(agent, PropertyKey.from("groups"));

            // k. If functionalReplace is true, then
            const replacement_string = if (functional_replace) blk: {
                // i. Let replacerArgs be the list-concatenation of « matched », captures, and
                //    « 𝔽(position), string ».
                var replacer_args = try std.ArrayList(Value).initCapacity(
                    agent.gc_allocator,
                    captures.items.len + 3 + @intFromBool(!named_captures.isUndefined()),
                );
                replacer_args.appendAssumeCapacity(Value.from(matched));
                for (captures.items) |capture| replacer_args.appendAssumeCapacity(
                    if (capture) |s| Value.from(s) else .null,
                );
                replacer_args.appendAssumeCapacity(Value.from(position));
                replacer_args.appendAssumeCapacity(Value.from(string));

                // ii. If namedCaptures is not undefined, then
                if (!named_captures.isUndefined()) {
                    // 1. Append namedCaptures to replacerArgs.
                    replacer_args.appendAssumeCapacity(named_captures);
                }

                // iii. Let replacementValue be ? Call(replaceValue, undefined, replacerArgs).
                const replacement_value = try replace_value.asObject().call(
                    agent,
                    .undefined,
                    replacer_args.items,
                );

                // iv. Let replacementString be ? ToString(replacementValue).
                break :blk try replacement_value.toString(agent);
            } else blk: {
                // l. Else,
                // i. If namedCaptures is not undefined, then
                const named_captures_object: ?*Object = if (!named_captures.isUndefined()) blk_obj: {
                    // 1. Set namedCaptures to ? ToObject(namedCaptures).
                    break :blk_obj try named_captures.toObject(agent);
                } else null;

                // ii. Let replacementString be ? GetSubstitution(matched, string, position,
                //     captures, namedCaptures, replaceValue).
                break :blk try getSubstitution(
                    agent,
                    matched,
                    string,
                    position,
                    captures.items,
                    named_captures_object,
                    replace_value.asString(),
                );
            };

            // m. If position ≥ nextSourcePosition, then
            if (position >= next_source_position) {
                // i. NOTE: position should not normally move backwards. If it does, it is an
                //    indication of an ill-behaving RegExp subclass or use of an access triggered
                //    side-effect to change the global flag or other characteristics of regexp. In
                //    such cases, the corresponding substitution is ignored.

                // ii. Set accumulatedResult to the string-concatenation of accumulatedResult, the
                //     substring of string from nextSourcePosition to position, and
                //     replacementString.
                try accumulated_result.appendString(
                    agent.gc_allocator,
                    try string.substring(agent, next_source_position, position),
                );
                try accumulated_result.appendString(agent.gc_allocator, replacement_string);

                // iii. Set nextSourcePosition to position + matchLength.
                next_source_position = position + matched_length;
            }
        }

        // 16. If nextSourcePosition ≥ stringLength, return accumulatedResult.
        // 17. Return the string-concatenation of accumulatedResult and the substring of string from
        //     nextSourcePosition.
        if (next_source_position < string_length) {
            try accumulated_result.appendString(
                agent.gc_allocator,
                try string.substring(agent, next_source_position, null),
            );
        }
        return Value.from(try accumulated_result.build(agent));
    }

    /// 22.2.6.12 RegExp.prototype [ %Symbol.search% ] ( string )
    /// https://tc39.es/ecma262/#sec-regexp.prototype-%symbol.search%
    fn @"Symbol.search"(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const string_value = arguments.get(0);

        // 1. Let regexp be the this value.
        // 2. If regexp is not an Object, throw a TypeError exception.
        if (!this_value.isObject()) {
            return agent.throwException(.type_error, "{f} is not an Object", .{this_value});
        }
        const regexp = this_value.asObject();

        // 3. Set string to ? ToString(string).
        const string = try string_value.toString(agent);

        // 4. Let previousLastIndex be ? Get(regexp, "lastIndex").
        const previous_last_index = try regexp.get(agent, PropertyKey.from("lastIndex"));

        // 5. If previousLastIndex is not +0𝔽, then
        if (!sameValue(previous_last_index, Value.from(0))) {
            // a. Perform ? Set(regexp, "lastIndex", +0𝔽, true).
            try regexp.set(agent, PropertyKey.from("lastIndex"), Value.from(0), .throw);
        }

        // 6. Let result be ? RegExpExec(regexp, string).
        const result = try regExpExec(agent, regexp, string);

        // 7. Let currentLastIndex be ? Get(regexp, "lastIndex").
        const current_last_index = try regexp.get(agent, PropertyKey.from("lastIndex"));

        // 8. If SameValue(currentLastIndex, previousLastIndex) is false, then
        if (!sameValue(current_last_index, previous_last_index)) {
            // a. Perform ? Set(regexp, "lastIndex", previousLastIndex, true).
            try regexp.set(agent, PropertyKey.from("lastIndex"), previous_last_index, .throw);
        }

        // 9. If result is null, return -1𝔽.
        if (result == null) return Value.from(-1);

        // 10. Return ? Get(result, "index").
        return try result.?.get(agent, PropertyKey.from("index"));
    }

    /// 22.2.6.13 get RegExp.prototype.source
    /// https://tc39.es/ecma262/#sec-get-regexp.prototype.source
    fn source(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let regexp be the this value.
        // 2. If regexp is not an Object, throw a TypeError exception.
        if (!this_value.isObject()) {
            return agent.throwException(.type_error, "{f} is not an Object", .{this_value});
        }
        // 3. If regexp does not have an [[OriginalSource]] internal slot, then
        const regexp = this_value.asObject().cast(RegExp) orelse {
            const realm = agent.currentRealm();

            // a. If SameValue(regexp, %RegExp.prototype%) is true, return "(?:)".
            if (this_value.asObject() == try realm.intrinsic(.reg_exp_prototype)) {
                return Value.from("(?:)");
            }

            // b. Throw a TypeError exception.
            return agent.throwException(.type_error, "This value must be a RegExp object", .{});
        };

        // 4. Assert: regexp has an [[OriginalFlags]] internal slot.
        // 5. Let source be regexp.[[OriginalSource]].
        const source_ = regexp.fields.original_source;

        // 6. Let flags be regexp.[[OriginalFlags]].
        const re_bytecode = regexp.fields.re_bytecode;
        const re_flags = re_bytecode.flags();

        // 7. Return EscapeRegExpPattern(source, flags).
        return Value.from(try escapeRegExpPattern(agent, source_, re_flags));
    }

    /// 22.2.6.13.1 EscapeRegExpPattern ( pattern, flags )
    /// https://tc39.es/ecma262/#sec-escaperegexppattern
    fn escapeRegExpPattern(
        agent: *Agent,
        pattern: *const String,
        _: libregexp.Flags,
    ) std.mem.Allocator.Error!*const String {
        // TODO: 1-4.
        // 5. The code points `/` or any LineTerminator occurring in the pattern shall be escaped in
        //    escapedPattern as necessary to ensure that the string-concatenation of "/",
        //    escapedPattern, "/", and flags can be parsed (in an appropriate lexical context) as a
        //    RegularExpressionLiteral that behaves identically to the constructed regular
        //    expression. For example, if pattern is "/", then escapedPattern could be "\/" or
        //    "\u002F", among other possibilities, but not "/", because `///` followed by flags
        //    would be parsed as a SingleLineComment rather than a RegularExpressionLiteral. If
        //    pattern is the empty String, this specification can be met by letting escapedPattern
        //    be "(?:)".
        // 6. Return escapedPattern.
        if (pattern.isEmpty()) return String.fromLiteral("(?:)");
        var escaped_pattern: *const String = pattern;
        escaped_pattern = try escaped_pattern.replace(agent, "/", "\\/");
        escaped_pattern = try escaped_pattern.replace(agent, "\r", "\\r");
        escaped_pattern = try escaped_pattern.replace(agent, "\n", "\\n");
        // TODO: Handle LS and PS line terminators
        return escaped_pattern;
    }

    /// 22.2.6.14 RegExp.prototype [ %Symbol.split% ] ( string, limit )
    /// https://tc39.es/ecma262/#sec-regexp.prototype-%symbol.split%
    fn @"Symbol.split"(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const realm = agent.currentRealm();
        const string_value = arguments.get(0);
        const limit_value = arguments.get(1);

        // 1. Let regexp be the this value.
        // 2. If regexp is not an Object, throw a TypeError exception.
        if (!this_value.isObject()) {
            return agent.throwException(.type_error, "{f} is not an Object", .{this_value});
        }
        const regexp = this_value.asObject();

        // 3. Set string to ? ToString(string).
        const string = try string_value.toString(agent);

        // 4. Let speciesCtor be ? SpeciesConstructor(regexp, %RegExp%).
        const species_ctor = try regexp.speciesConstructor(
            agent,
            try realm.intrinsic(.reg_exp),
        );

        // 5. Let flags be ? ToString(? Get(regexp, "flags")).
        const flags_ = try (try regexp.get(agent, PropertyKey.from("flags"))).toString(agent);

        // 6. If flags contains "u" or flags contains "v", let unicodeMatching be true.
        // 7. Else, let unicodeMatching be false.
        const unicode_matching = flags_.indexOf(String.fromLiteral("u"), 0) != null or
            flags_.indexOf(String.fromLiteral("v"), 0) != null;

        // 8. If flags contains "y", let newFlags be flags.
        // 9. Else, let newFlags be the string-concatenation of flags and "y".
        const new_flags = if (flags_.indexOf(String.fromLiteral("y"), 0) != null)
            flags_
        else
            try String.concat(agent, &.{ flags_, String.fromLiteral("y") });

        // 10. Let splitter be ? Construct(speciesCtor, « regexp, newFlags »).
        const splitter = try species_ctor.construct(
            agent,
            &.{ Value.from(regexp), Value.from(new_flags) },
            null,
        );

        // 11. Let array be ! ArrayCreate(0).
        const array = try arrayCreateFast(agent, 0);

        // 12. Let lengthA be 0.
        var length_array: u32 = 0;

        // 13. If limit is undefined, let lim be 2**32 - 1; else let lim be ℝ(? ToUint32(limit)).
        const limit = if (limit_value.isUndefined())
            std.math.maxInt(u32)
        else
            try limit_value.toUint32(agent);

        // 14. If lim = 0, return array.
        if (limit == 0) return Value.from(&array.object);

        // 15. If string is the empty String, then
        if (string.isEmpty()) {
            // a. Let matchResult be ? RegExpExec(splitter, string).
            const match_result = try regExpExec(agent, splitter, string);

            // b. If matchResult is not null, return array.
            if (match_result != null) return Value.from(&array.object);

            // c. Perform ! CreateDataPropertyOrThrow(array, "0", string).
            try array.object.createDataPropertyDirect(agent, PropertyKey.from(0), Value.from(string));

            // d. Return array.
            return Value.from(&array.object);
        }

        // 16. Let size be the length of string.
        const size = string.length;

        // 17. Let lastMatchEnd be 0.
        var last_match_end: u53 = 0;

        // 18. Let searchIndex be lastMatchEnd.
        var search_index: u53 = last_match_end;

        // 19. Repeat, while searchIndex < size,
        while (search_index < size) {
            // a. Perform ? Set(splitter, "lastIndex", 𝔽(searchIndex), true).
            try splitter.set(agent, PropertyKey.from("lastIndex"), Value.from(search_index), .throw);

            // b. Let matchResult be ? RegExpExec(splitter, string).
            const match_result = try regExpExec(agent, splitter, string);

            // c. If matchResult is null, then
            if (match_result == null) {
                // i. Set searchIndex to AdvanceStringIndex(string, searchIndex, unicodeMatching).
                search_index = std.math.cast(
                    u53,
                    advanceStringIndex(string, search_index, unicode_matching),
                ) orelse break;
            } else {
                // d. Else,
                // i. Let matchEnd be ℝ(? ToLength(? Get(splitter, "lastIndex"))).
                var match_end = try (try splitter.get(agent, PropertyKey.from("lastIndex"))).toLength(agent);

                // ii. Set matchEnd to min(matchEnd, size).
                match_end = @min(match_end, size);

                // iii. If matchEnd = lastMatchEnd, then
                if (match_end == last_match_end) {
                    // 1. Set searchIndex to AdvanceStringIndex(string, searchIndex,
                    //    unicodeMatching).
                    search_index = std.math.cast(
                        u53,
                        advanceStringIndex(string, search_index, unicode_matching),
                    ) orelse break;
                } else {
                    // iv. Else,
                    // 1. Let substring be the substring of string from lastMatchEnd to searchIndex.
                    const substring = try string.substring(agent, @intCast(last_match_end), @intCast(search_index));

                    // 2. Perform ! CreateDataPropertyOrThrow(array, ! ToString(𝔽(lengthA)),
                    //    substring).
                    try array.object.createDataPropertyDirect(
                        agent,
                        PropertyKey.from(@as(PropertyKey.IntegerIndex, @intCast(length_array))),
                        Value.from(substring),
                    );

                    // 3. Set lengthA to lengthA + 1.
                    length_array += 1;

                    // 4. If lengthA = lim, return array.
                    if (length_array == limit) return Value.from(&array.object);

                    // 5. Set lastMatchEnd to matchEnd.
                    last_match_end = match_end;

                    // 6. Let numberOfCaptures be ? LengthOfArrayLike(matchResult).
                    var number_of_captures = try match_result.?.lengthOfArrayLike(agent);

                    // 7. Set numberOfCaptures to max(numberOfCaptures - 1, 0).
                    if (number_of_captures > 0) number_of_captures -= 1;

                    // 8. Let captureIndex be 1.
                    var capture_index: u53 = 1;

                    // 9. Repeat, while captureIndex ≤ numberOfCaptures,
                    while (capture_index <= number_of_captures) : (capture_index += 1) {
                        // a. Let nextCapture be ? Get(matchResult, ! ToString(𝔽(captureIndex))).
                        const next_capture = try match_result.?.get(agent, PropertyKey.from(capture_index));

                        // b. Perform ! CreateDataPropertyOrThrow(array, ! ToString(𝔽(lengthA)),
                        //    nextCapture).
                        try array.object.createDataPropertyDirect(
                            agent,
                            PropertyKey.from(@as(PropertyKey.IntegerIndex, @intCast(length_array))),
                            next_capture,
                        );

                        // c. Set captureIndex to captureIndex + 1.

                        // d. Set lengthA to lengthA + 1.
                        length_array += 1;

                        // e. If lengthA = lim, return array.
                        if (length_array == limit) return Value.from(&array.object);
                    }

                    // 10. Set searchIndex to lastMatchEnd.
                    search_index = last_match_end;
                }
            }
        }

        // 20. Let substring be the substring of string from lastMatchEnd to size.
        const substring = try string.substring(agent, @intCast(last_match_end), size);

        // 21. Perform ! CreateDataPropertyOrThrow(array, ! ToString(𝔽(lengthA)), substring).
        try array.object.createDataPropertyDirect(
            agent,
            PropertyKey.from(@as(PropertyKey.IntegerIndex, @intCast(length_array))),
            Value.from(substring),
        );

        // 22. Return array.
        return Value.from(&array.object);
    }

    /// 22.2.6.15 get RegExp.prototype.sticky
    /// https://tc39.es/ecma262/#sec-get-regexp.prototype.sticky
    fn sticky(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let regexp be the this value.
        // 2. Let codeUnit be the code unit 0x0079 (LATIN SMALL LETTER Y).
        // 3. Return ? RegExpHasFlag(regexp, codeUnit).
        return regExpHasFlag(agent, this_value, .sticky);
    }

    /// 22.2.6.16 RegExp.prototype.test ( string )
    /// https://tc39.es/ecma262/#sec-regexp.prototype.test
    fn @"test"(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        // 1. Let regexp be the this value.
        // 2. If regexp is not an Object, throw a TypeError exception.
        if (!this_value.isObject()) {
            return agent.throwException(.type_error, "{f} is not an Object", .{this_value});
        }
        const regexp = this_value.asObject();

        // 3. Set string to ? ToString(string).
        const string = try arguments.get(0).toString(agent);

        // 4. Let match be ? RegExpExec(regexp, string).
        const match = try regExpExec(agent, regexp, string);

        // 5. If match is null, return false.
        // 6. Return true.
        return Value.from(match != null);
    }

    /// 22.2.6.17 RegExp.prototype.toString ( )
    /// https://tc39.es/ecma262/#sec-regexp.prototype.tostring
    fn toString(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let regexp be the this value.
        // 2. If regexp is not an Object, throw a TypeError exception.
        if (!this_value.isObject()) {
            return agent.throwException(.type_error, "{f} is not an Object", .{this_value});
        }
        const regexp = this_value.asObject();

        // 3. Let pattern be ? ToString(? Get(regexp, "source")).
        const pattern = try (try regexp.get(agent, PropertyKey.from("source"))).toString(agent);

        // 4. Let flags be ? ToString(? Get(regexp, "flags")).
        const flags_ = try (try regexp.get(agent, PropertyKey.from("flags"))).toString(agent);

        // 5. Let result be the string-concatenation of "/", pattern, "/", and flags.
        const result = try String.concat(agent, &.{
            String.fromLiteral("/"),
            pattern,
            String.fromLiteral("/"),
            flags_,
        });

        // 6. Return result.
        return Value.from(result);
    }

    /// 22.2.6.18 get RegExp.prototype.unicode
    /// https://tc39.es/ecma262/#sec-get-regexp.prototype.unicode
    fn unicode(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let regexp be the this value.
        // 2. Let codeUnit be the code unit 0x0075 (LATIN SMALL LETTER U).
        // 3. Return ? RegExpHasFlag(regexp, codeUnit).
        return regExpHasFlag(agent, this_value, .unicode);
    }

    /// 22.2.6.19 get RegExp.prototype.unicodeSets
    /// https://tc39.es/ecma262/#sec-get-regexp.prototype.unicodesets
    fn unicodeSets(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let regexp be the this value.
        // 2. Let codeUnit be the code unit 0x0076 (LATIN SMALL LETTER V).
        // 3. Return ? RegExpHasFlag(regexp, codeUnit).
        return regExpHasFlag(agent, this_value, .unicode_sets);
    }

    /// B.2.4.1 RegExp.prototype.compile ( pattern, flags )
    /// https://tc39.es/ecma262/#sec-regexp.prototype.compile
    fn compile(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        var pattern = arguments.get(0);
        var flags_ = arguments.get(1);

        // 1. Let obj be the this value.
        // 2. Perform ? RequireInternalSlot(obj, [[RegExpMatcher]]).
        const regexp = try this_value.requireInternalSlot(agent, RegExp);

        // 3. If pattern is an Object and pattern has a [[RegExpMatcher]] internal slot, then
        if (pattern.castObject(RegExp)) |pattern_regexp| {
            // a. If flags is not undefined, throw a TypeError exception.
            if (!flags_.isUndefined()) {
                return agent.throwException(
                    .type_error,
                    "Flags must be undefined when pattern is a RegExp object, got {f}",
                    .{flags_},
                );
            }

            // c. Set pattern to pattern.[[OriginalSource]].
            pattern = Value.from(pattern_regexp.fields.original_source);

            // b. Set flags to pattern.[[OriginalFlags]].
            flags_ = Value.from(pattern_regexp.fields.original_flags);
        }

        // 4. Return ? RegExpInitialize(obj, pattern, flags).
        _ = try regExpInitialize(agent, regexp, pattern, flags_);
        return Value.from(&regexp.object);
    }
};

/// 22.2.8 Properties of RegExp Instances
/// https://tc39.es/ecma262/#sec-properties-of-regexp-instances
pub const RegExp = MakeObject(.{
    .Fields = struct {
        /// [[OriginalSource]]
        original_source: *const String,

        /// [[OriginalFlags]]
        original_flags: *const String,

        /// [[RegExpRecord]]
        re_bytecode: libregexp.Bytecode,
    },
    .tag = .reg_exp,
    .display_name = "RegExp",
});
