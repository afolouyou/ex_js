//! 19.5 Segments Objects
//! https://tc39.es/ecma402/#sec-segments-objects

const std = @import("std");

const builtins = @import("../../builtins.zig");
const execution = @import("../../execution.zig");
const types = @import("../../types.zig");

const Agent = execution.Agent;
const Arguments = types.Arguments;
const MakeObject = types.MakeObject;
const Object = types.Object;
const Realm = execution.Realm;
const String = types.String;
const Value = types.Value;
const createSegmentDataObject = builtins.intl.createSegmentDataObject;
const createSegmentIterator = builtins.intl.createSegmentIterator;
const findBoundary = builtins.intl.findBoundary;
const ordinaryObjectCreate = builtins.ordinaryObjectCreate;
const ordinaryObjectCreateWithType = builtins.ordinaryObjectCreateWithType;

/// 19.5.1 CreateSegmentsObject ( segmenter, string )
/// https://tc39.es/ecma402/#sec-createsegmentsobject
pub fn createSegmentsObject(
    agent: *Agent,
    segmenter: *builtins.intl.Segmenter,
    string: *const String,
) std.mem.Allocator.Error!*Segments {
    const realm = agent.currentRealm();

    // 1. Let internalSlotsList be « [[SegmentsSegmenter]], [[SegmentsString]] ».
    // 2. Let segments be OrdinaryObjectCreate(%IntlSegmentsPrototype%, internalSlotsList).
    const segments = try ordinaryObjectCreateWithType(
        Segments,
        agent,
        try realm.intrinsic(.intl_segments_prototype),
        .{
            // 3. Set segments.[[SegmentsSegmenter]] to segmenter.
            .segments_segmenter = segmenter,

            // 4. Set segments.[[SegmentsString]] to string.
            .segments_string = string,
        },
    );

    // 5. Return segments.
    return segments;
}

/// 19.5.2 The %IntlSegmentsPrototype% Object
/// https://tc39.es/ecma402/#sec-%intlsegmentsprototype%-object
pub const prototype = struct {
    pub fn create(agent: *Agent, realm: *Realm) std.mem.Allocator.Error!*Object {
        return ordinaryObjectCreate(agent, try realm.intrinsic(.object_prototype));
    }

    pub fn init(agent: *Agent, realm: *Realm, object: *Object) std.mem.Allocator.Error!void {
        try object.defineBuiltinFunction(agent, "containing", containing, 1, realm);
        try object.defineBuiltinFunction(agent, "Symbol.iterator", @"Symbol.iterator", 0, realm);
    }

    /// 19.5.2.1 %IntlSegmentsPrototype%.containing ( index )
    /// https://tc39.es/ecma402/#sec-%intlsegmentsprototype%.containing
    fn containing(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const index = arguments.get(0);

        // 1. Let segments be the this value.
        // 2. Perform ? RequireInternalSlot(segments, [[SegmentsSegmenter]]).
        const segments = try this_value.requireInternalSlot(agent, Segments);

        // 3. Let segmenter be segments.[[SegmentsSegmenter]].
        const segmenter = segments.fields.segments_segmenter;

        // 4. Let string be segments.[[SegmentsString]].
        const string = segments.fields.segments_string;

        // 5. Let length be the length of string.
        const length = string.length;

        // 6. Let n be ? ToIntegerOrInfinity(index).
        const n = try index.toIntegerOrInfinity(agent);

        // 7. If n < 0 or n ≥ length, return undefined.
        if (n < 0 or n >= @as(f64, @floatFromInt(length))) return .undefined;

        // 8. Let startIndex be FindBoundary(segmenter, string, n, before).
        const boundary_before = findBoundary(segmenter, string, @intFromFloat(n), .before);
        const start_index = boundary_before.index;

        // 9. Let endIndex be FindBoundary(segmenter, string, n, after).
        const boundary_after = findBoundary(segmenter, string, @intFromFloat(n), .after);
        const end_index = boundary_after.index;
        const is_word_like = boundary_after.is_word_like orelse false;

        // 10. Return CreateSegmentDataObject(segmenter, string, startIndex, endIndex).
        return Value.from(
            try createSegmentDataObject(
                agent,
                segmenter,
                string,
                start_index,
                end_index,
                is_word_like,
            ),
        );
    }

    /// 19.5.2.2 %IntlSegmentsPrototype% [ %Symbol.iterator% ] ( )
    /// https://tc39.es/ecma402/#sec-%intlsegmentsprototype%-%symbol.iterator%
    fn @"Symbol.iterator"(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let segments be the this value.
        // 2. Perform ? RequireInternalSlot(segments, [[SegmentsSegmenter]]).
        const segments = try this_value.requireInternalSlot(agent, Segments);

        // 3. Let segmenter be segments.[[SegmentsSegmenter]].
        const segmenter = segments.fields.segments_segmenter;

        // 4. Let string be segments.[[SegmentsString]].
        const string = segments.fields.segments_string;

        // 5. Return CreateSegmentIterator(segmenter, string).
        const segment_iterator = try createSegmentIterator(agent, segmenter, string);
        return Value.from(&segment_iterator.object);
    }
};

/// 19.5.3 Properties of Segments Instances
/// https://tc39.es/ecma402/#sec-properties-of-segments-instances
pub const Segments = MakeObject(.{
    .Fields = struct {
        /// [[SegmentsSegmenter]]
        segments_segmenter: *builtins.intl.Segmenter,

        /// [[SegmentsString]]
        segments_string: *const String,
    },
    .tag = .intl_segments,
    .display_name = "Intl.Segments",
});
