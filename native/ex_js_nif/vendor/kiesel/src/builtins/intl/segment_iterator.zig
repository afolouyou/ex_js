//! 19.6 Segment Iterator Objects
//! https://tc39.es/ecma402/#sec-segment-iterator-objects

const std = @import("std");

const builtins = @import("../../builtins.zig");
const execution = @import("../../execution.zig");
const types = @import("../../types.zig");

const Agent = execution.Agent;
const Arguments = types.Arguments;
const MakeObject = types.MakeObject;
const Object = types.Object;
const PropertyKey = types.PropertyKey;
const Realm = execution.Realm;
const String = types.String;
const Value = types.Value;
const createIteratorResultObject = types.createIteratorResultObject;
const findBoundary = builtins.intl.findBoundary;
const ordinaryObjectCreate = builtins.ordinaryObjectCreate;

/// 19.6.1 CreateSegmentIterator ( segmenter, string )
/// https://tc39.es/ecma402/#sec-createsegmentiterator
pub fn createSegmentIterator(
    agent: *Agent,
    segmenter: *builtins.intl.Segmenter,
    string: *const String,
) std.mem.Allocator.Error!*SegmentIterator {
    const realm = agent.currentRealm();

    // 1. Let internalSlotsList be « [[IteratingSegmenter]], [[IteratedString]],
    //    [[IteratedStringNextSegmentCodeUnitIndex]] ».
    // 2. Let iterator be OrdinaryObjectCreate(%IntlSegmentIteratorPrototype%, internalSlotsList).
    const iterator = SegmentIterator.create(agent, .{
        .prototype = try realm.intrinsic(.intl_segment_iterator_prototype),
        .fields = .{
            // 3. Set iterator.[[IteratingSegmenter]] to segmenter.
            .iterating_segmenter = segmenter,

            // 4. Set iterator.[[IteratedString]] to string.
            .iterated_string = string,

            // 5. Set iterator.[[IteratedStringNextSegmentCodeUnitIndex]] to 0.
            .iterated_string_next_segment_code_unit_index = 0,
        },
    });

    // 6. Return iterator.
    return iterator;
}

/// 19.6.2 The %IntlSegmentIteratorPrototype% Object
/// https://tc39.es/ecma402/#sec-%intlsegmentiteratorprototype%-object
pub const prototype = struct {
    pub fn create(agent: *Agent, realm: *Realm) std.mem.Allocator.Error!*Object {
        return ordinaryObjectCreate(agent, try realm.intrinsic(.iterator_prototype));
    }

    pub fn init(agent: *Agent, realm: *Realm, object: *Object) std.mem.Allocator.Error!void {
        try object.defineBuiltinFunction(agent, "next", next, 0, realm);

        // 19.6.2.2 %IntlSegmentIteratorPrototype% [ %Symbol.toStringTag% ]
        // https://tc39.es/ecma402/#sec-%intlsegmentiteratorprototype%.%symbol.tostringtag%
        try object.defineBuiltinPropertyWithAttributes(
            agent,
            "Symbol.toStringTag",
            Value.from("Segmenter String Iterator"),
            .{
                .writable = false,
                .enumerable = false,
                .configurable = true,
            },
        );
    }

    /// 19.6.2.1 %IntlSegmentIteratorPrototype%.next ( )
    /// https://tc39.es/ecma402/#sec-%intlsegmentiteratorprototype%.next
    fn next(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let iterator be the this value.
        // 2. Perform ? RequireInternalSlot(iterator, [[IteratingSegmenter]]).
        const iterator = try this_value.requireInternalSlot(agent, SegmentIterator);

        // 3. Let segmenter be iterator.[[IteratingSegmenter]].
        const segmenter = iterator.fields.iterating_segmenter;

        // 4. Let string be iterator.[[IteratedString]].
        const string = iterator.fields.iterated_string;

        // 5. Let startIndex be iterator.[[IteratedStringNextSegmentCodeUnitIndex]].
        const start_index = iterator.fields.iterated_string_next_segment_code_unit_index;

        // 6. Let length be the length of string.
        const length = string.length;

        // 7. If startIndex ≥ length, then
        if (start_index >= length) {
            // a. Return CreateIteratorResultObject(undefined, true).
            return Value.from(try createIteratorResultObject(agent, .undefined, true));
        }

        // 8. Let endIndex be FindBoundary(segmenter, string, startIndex, after).
        const boundary_after = findBoundary(segmenter, string, start_index, .after);
        const end_index = boundary_after.index;
        const is_word_like = boundary_after.is_word_like orelse false;

        // 9. Set iterator.[[IteratedStringNextSegmentCodeUnitIndex]] to endIndex.
        iterator.fields.iterated_string_next_segment_code_unit_index = end_index;

        // 10. Let segmentData be CreateSegmentDataObject(segmenter, string, startIndex, endIndex).
        const segment_data = try createSegmentDataObject(
            agent,
            segmenter,
            string,
            start_index,
            end_index,
            is_word_like,
        );

        // 11. Return CreateIteratorResultObject(segmentData, false).
        return Value.from(try createIteratorResultObject(agent, Value.from(segment_data), false));
    }
};

/// 19.6.3 Properties of Segment Iterator Instances
/// https://tc39.es/ecma402/#sec-properties-of-segment-iterator-instances
pub const SegmentIterator = MakeObject(.{
    .Fields = struct {
        iterating_segmenter: *builtins.intl.Segmenter,
        iterated_string: *const String,
        iterated_string_next_segment_code_unit_index: u32,
    },
    .tag = .intl_segment_iterator,
    .display_name = "Intl.SegmentIterator",
});

/// 19.7.1 CreateSegmentDataObject ( segmenter, string, startIndex, endIndex )
/// https://tc39.es/ecma402/#sec-createsegmentdataobject
pub fn createSegmentDataObject(
    agent: *Agent,
    segmenter: *builtins.intl.Segmenter,
    string: *const String,
    start_index: u32,
    end_index: u32,
    is_word_like: bool,
) std.mem.Allocator.Error!*Object {
    const realm = agent.currentRealm();

    // 1. Let length be the length of string.
    const length = string.length;

    // 2. Assert: endIndex ≤ length.
    std.debug.assert(end_index <= length);

    // 3. Assert: startIndex < endIndex.
    std.debug.assert(start_index < end_index);

    // 4. Let result be OrdinaryObjectCreate(%Object.prototype%).
    const result = try ordinaryObjectCreate(agent, try realm.intrinsic(.object_prototype));

    // 5. Let segment be the substring of string from startIndex to endIndex.
    const segment = try string.substring(agent, start_index, end_index);

    // 6. Perform ! CreateDataPropertyOrThrow(result, "segment", segment).
    try result.createDataPropertyDirect(
        agent,
        PropertyKey.from("segment"),
        Value.from(segment),
    );

    // 7. Perform ! CreateDataPropertyOrThrow(result, "index", 𝔽(startIndex)).
    try result.createDataPropertyDirect(
        agent,
        PropertyKey.from("index"),
        Value.from(start_index),
    );

    // 8. Perform ! CreateDataPropertyOrThrow(result, "input", string).
    try result.createDataPropertyDirect(
        agent,
        PropertyKey.from("input"),
        Value.from(string),
    );

    // 9. Let granularity be segmenter.[[SegmenterGranularity]].
    const granularity = segmenter.fields.segmenter_granularity;

    // 10. If granularity is "word", then
    if (granularity == .word) {
        // a. Let isWordLike be a Boolean indicating whether the segment in string is "word-like"
        //    according to locale segmenter.[[Locale]].

        // b. Perform ! CreateDataPropertyOrThrow(result, "isWordLike", isWordLike).
        try result.createDataPropertyDirect(
            agent,
            PropertyKey.from("isWordLike"),
            Value.from(is_word_like),
        );
    }

    // 11. Return result.
    return result;
}
