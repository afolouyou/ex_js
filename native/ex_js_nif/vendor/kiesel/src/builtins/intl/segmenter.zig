//! 19 Segmenter Objects
//! https://tc39.es/ecma402/#segmenter-objects

const std = @import("std");

const icu4zig = @import("icu4zig");

const abstract_operations = @import("abstract_operations.zig");
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
const createBuiltinFunction = builtins.createBuiltinFunction;
const createSegmentsObject = builtins.intl.createSegmentsObject;
const ordinaryCreateFromConstructor = builtins.ordinaryCreateFromConstructor;
const ordinaryObjectCreate = builtins.ordinaryObjectCreate;
const resolveOptions = abstract_operations.resolveOptions;

/// 19.2 Properties of the Intl.Segmenter Constructor
/// https://tc39.es/ecma402/#sec-properties-of-intl-segmenter-constructor
pub const constructor = struct {
    pub fn create(agent: *Agent, realm: *Realm) std.mem.Allocator.Error!*Object {
        const builtin_function = try createBuiltinFunction(
            agent,
            .{ .constructor = impl },
            0,
            "Segmenter",
            .{ .realm = realm, .proto = try realm.intrinsic(.function_prototype) },
        );
        return &builtin_function.object;
    }

    pub fn init(agent: *Agent, realm: *Realm, object: *Object) std.mem.Allocator.Error!void {
        // 19.2.1 Intl.Segmenter.prototype
        // https://tc39.es/ecma402/#sec-intl.segmenter.prototype
        try object.defineBuiltinPropertyWithAttributes(
            agent,
            "prototype",
            Value.from(try realm.intrinsic(.intl_segmenter_prototype)),
            .none,
        );
    }

    /// 19.1.1 Intl.Segmenter ( [ locales [ , options ] ] )
    /// https://tc39.es/ecma402/#sec-intl.segmenter
    fn impl(agent: *Agent, arguments: Arguments, new_target: ?*Object) Agent.Error!Value {
        const locales = arguments.get(0);
        const options_value = arguments.get(1);

        // 1. If NewTarget is undefined, throw a TypeError exception.
        if (new_target == null) {
            return agent.throwException(
                .type_error,
                "Intl.Segmenter must be constructed with 'new'",
                .{},
            );
        }

        // 2. Let internalSlotsList be « [[InitializedSegmenter]], [[Locale]],
        //    [[SegmenterGranularity]] ».
        // 3. Let segmenter be ? OrdinaryCreateFromConstructor(NewTarget,
        //    "%Intl.Segmenter.prototype%", internalSlotsList).
        const segmenter = try ordinaryCreateFromConstructor(
            Segmenter,
            agent,
            new_target.?,
            .intl_segmenter_prototype,
            .{ .locale = undefined, .segmenter_granularity = undefined },
        );

        // 4. Let optionsResolution be ? ResolveOptions(%Intl.Segmenter%,
        //    %Intl.Segmenter%.[[LocaleData]], locales, options).
        const options_resolution = try resolveOptions(
            agent,
            &.{},
            locales,
            options_value,
            .{},
        );

        // 5. Set options to optionsResolution.[[Options]].
        const options = options_resolution.options;

        // 6. Let resolvedLocale be optionsResolution.[[ResolvedLocale]].
        const resolved_locale = options_resolution.resolved_locale;
        const locale = resolved_locale.locale;

        // 7. Set segmenter.[[Locale]] to resolvedLocale.[[Locale]].
        segmenter.fields.locale = locale;

        // 8. Let granularity be ? GetOption(options, "granularity", string, « "grapheme", "word",
        //    "sentence" », "grapheme").
        const granularity_string = try options.getOption(
            agent,
            "granularity",
            .string,
            &.{
                String.fromLiteral("grapheme"),
                String.fromLiteral("word"),
                String.fromLiteral("sentence"),
            },
            String.fromLiteral("grapheme"),
        );
        const granularity = std.StaticStringMap(
            Segmenter.Fields.SegmenterGranularity,
        ).initComptime(&.{
            .{ "grapheme", .grapheme },
            .{ "word", .word },
            .{ "sentence", .sentence },
        }).get(granularity_string.asAscii()).?;

        // 9. Set segmenter.[[SegmenterGranularity]] to granularity.
        segmenter.fields.segmenter_granularity = granularity;

        // 10. Return segmenter.
        return Value.from(&segmenter.object);
    }
};

/// 19.3 Properties of the Intl.Segmenter Prototype Object
/// https://tc39.es/ecma402/#sec-properties-of-intl-segmenter-prototype-object
pub const prototype = struct {
    pub fn create(agent: *Agent, realm: *Realm) std.mem.Allocator.Error!*Object {
        return ordinaryObjectCreate(agent, try realm.intrinsic(.object_prototype));
    }

    pub fn init(agent: *Agent, realm: *Realm, object: *Object) std.mem.Allocator.Error!void {
        try object.defineBuiltinFunction(agent, "resolvedOptions", resolvedOptions, 0, realm);
        try object.defineBuiltinFunction(agent, "segment", segment, 1, realm);

        // 19.3.1 Intl.Segmenter.prototype.constructor
        // https://tc39.es/ecma402/#sec-intl.segmenter.prototype.constructor
        try object.defineBuiltinProperty(
            agent,
            "constructor",
            Value.from(try realm.intrinsic(.intl_segmenter)),
        );

        // 19.3.4 Intl.Segmenter.prototype [ %Symbol.toStringTag% ]
        // https://tc39.es/ecma402/#sec-intl.segmenter.prototype-%symbol.tostringtag%
        try object.defineBuiltinPropertyWithAttributes(
            agent,
            "Symbol.toStringTag",
            Value.from("Intl.Segmenter"),
            .{
                .writable = false,
                .enumerable = false,
                .configurable = true,
            },
        );
    }

    /// 19.3.2 Intl.Segmenter.prototype.resolvedOptions ( )
    /// https://tc39.es/ecma402/#sec-intl.segmenter.prototype.resolvedoptions
    fn resolvedOptions(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        const realm = agent.currentRealm();

        // 1. Let segmenter be the this value.
        // 2. Perform ? RequireInternalSlot(segmenter, [[InitializedSegmenter]]).
        const segmenter = try this_value.requireInternalSlot(agent, Segmenter);

        // 3. Let options be OrdinaryObjectCreate(%Object.prototype%).
        const options = try ordinaryObjectCreate(
            agent,
            try realm.intrinsic(.object_prototype),
        );

        // 4. For each row of Table 34, except the header row, in table order, do
        //     a. Let propertyKey be the Property value of the current row.
        //     b. Let value be the value of segmenter's internal slot whose name is the Internal
        //        Slot value of the current row.
        //     c. Assert: value is not undefined.
        //     d. Perform ! CreateDataPropertyOrThrow(options, propertyKey, value).
        const resolved_options = segmenter.fields.resolvedOptions();
        try options.createDataPropertyDirect(
            agent,
            PropertyKey.from("locale"),
            Value.from(
                try String.fromAscii(
                    agent,
                    try segmenter.fields.locale.toString(agent.gc_allocator),
                ),
            ),
        );
        try options.createDataPropertyDirect(
            agent,
            PropertyKey.from("granularity"),
            Value.from(resolved_options.granularity),
        );

        // 5. Return options.
        return Value.from(options);
    }

    /// 19.3.3 Intl.Segmenter.prototype.segment ( string )
    /// https://tc39.es/ecma402/#sec-intl.segmenter.prototype.segment
    fn segment(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const string_value = arguments.get(0);

        // 1. Let segmenter be the this value.
        // 2. Perform ? RequireInternalSlot(segmenter, [[InitializedSegmenter]]).
        const segmenter = try this_value.requireInternalSlot(agent, Segmenter);

        // 3. Set string to ? ToString(string).
        const string = try string_value.toString(agent);

        // 4. Return CreateSegmentsObject(segmenter, string).
        const segments = try createSegmentsObject(agent, segmenter, string);
        return Value.from(&segments.object);
    }
};

/// 19.4 Properties of Intl.Segmenter Instances
/// https://tc39.es/ecma402/#sec-properties-of-intl-segmenter-instances
pub const Segmenter = MakeObject(.{
    .Fields = struct {
        pub const ResolvedOptions = struct {
            granularity: *const String,
        };

        pub const SegmenterGranularity = enum {
            grapheme,
            word,
            sentence,
        };

        /// [[Locale]]
        locale: icu4zig.Locale,

        /// [[SegmenterGranularity]]
        segmenter_granularity: SegmenterGranularity,

        pub fn resolvedOptions(self: @This()) ResolvedOptions {
            const granularity = switch (self.segmenter_granularity) {
                .grapheme => String.fromLiteral("grapheme"),
                .word => String.fromLiteral("word"),
                .sentence => String.fromLiteral("sentence"),
            };
            return .{ .granularity = granularity };
        }
    },
    .tag = .intl_segmenter,
    .display_name = "Intl.Segmenter",
});

const AnySegmenter = union(enum) {
    grapheme: icu4zig.GraphemeClusterSegmenter,
    word: icu4zig.WordSegmenter,
    sentence: icu4zig.SentenceSegmenter,

    const BreakIterator = union(enum) {
        grapheme_utf8: icu4zig.GraphemeClusterSegmenter.GraphemeClusterBreakIteratorUtf8,
        grapheme_utf16: icu4zig.GraphemeClusterSegmenter.GraphemeClusterBreakIteratorUtf16,
        word_utf8: icu4zig.WordSegmenter.WordBreakIteratorUtf8,
        word_utf16: icu4zig.WordSegmenter.WordBreakIteratorUtf16,
        sentence_utf8: icu4zig.SentenceSegmenter.SentenceBreakIteratorUtf8,
        sentence_utf16: icu4zig.SentenceSegmenter.SentenceBreakIteratorUtf16,

        fn deinit(self: BreakIterator) void {
            switch (self) {
                .grapheme_utf8 => |iterator| iterator.deinit(),
                .grapheme_utf16 => |iterator| iterator.deinit(),
                .word_utf8 => |iterator| iterator.deinit(),
                .word_utf16 => |iterator| iterator.deinit(),
                .sentence_utf8 => |iterator| iterator.deinit(),
                .sentence_utf16 => |iterator| iterator.deinit(),
            }
        }
    };

    fn segment(self: AnySegmenter, string: *const String) BreakIterator {
        return switch (self) {
            .grapheme => |segmenter| switch (string.asAsciiOrUtf16()) {
                .ascii => |ascii| .{ .grapheme_utf8 = segmenter.segmentUtf8(ascii) },
                .utf16 => |utf16| .{ .grapheme_utf16 = segmenter.segmentUtf16(utf16) },
            },
            .word => |segmenter| switch (string.asAsciiOrUtf16()) {
                .ascii => |ascii| .{ .word_utf8 = segmenter.segmentUtf8(ascii) },
                .utf16 => |utf16| .{ .word_utf16 = segmenter.segmentUtf16(utf16) },
            },
            .sentence => |segmenter| switch (string.asAsciiOrUtf16()) {
                .ascii => |ascii| .{ .sentence_utf8 = segmenter.segmentUtf8(ascii) },
                .utf16 => |utf16| .{ .sentence_utf16 = segmenter.segmentUtf16(utf16) },
            },
        };
    }

    fn deinit(self: AnySegmenter) void {
        switch (self) {
            .grapheme => |segmenter| segmenter.deinit(),
            .word => |segmenter| segmenter.deinit(),
            .sentence => |segmenter| segmenter.deinit(),
        }
    }
};

const Boundary = struct {
    index: u32,
    is_word_like: ?bool = null,
};

/// 19.8.1 FindBoundary ( segmenter, string, startIndex, direction )
/// https://tc39.es/ecma402/#sec-findboundary
pub fn findBoundary(
    segmenter: *builtins.intl.Segmenter,
    string: *const String,
    start_index: u32,
    direction: enum { before, after },
) Boundary {
    // 1. Let length be the length of string.
    const length = string.length;

    // 2. Assert: startIndex < length.
    std.debug.assert(start_index < length);

    // 3. Let locale be segmenter.[[Locale]].

    // 4. Let granularity be segmenter.[[SegmenterGranularity]].
    const granularity = segmenter.fields.segmenter_granularity;

    // 5. If direction is before, then
    if (direction == .before) {
        // a. Search string for the last segmentation boundary that is preceded by at most
        //    startIndex code units from the beginning, using locale locale and text element
        //    granularity granularity.
        // b. If a boundary is found, return the count of code units in string preceding it.
        if (findBoundaryBefore(string, start_index, granularity)) |boundary| return boundary;

        // c. Return 0.
        return .{ .index = 0 };
    }

    // 6. Assert: direction is after.
    std.debug.assert(direction == .after);

    // 7. Search string for the first segmentation boundary that follows the code unit at index
    //    startIndex, using locale locale and text element granularity granularity.
    // 8. If a boundary is found, return the count of code units in string preceding it.
    if (findBoundaryAfter(string, start_index, granularity)) |boundary| return boundary;

    // 9. Return length.
    return .{ .index = length };
}

fn findBoundaryBefore(
    string: *const String,
    start_index: u32,
    granularity: builtins.intl.Segmenter.Fields.SegmenterGranularity,
) ?Boundary {
    const segmenter: AnySegmenter = switch (granularity) {
        .grapheme => .{ .grapheme = .init() },
        .word => .{ .word = .init() },
        .sentence => .{ .sentence = .init() },
    };
    defer segmenter.deinit();
    var iterator = segmenter.segment(string);
    defer iterator.deinit();
    var previous_index: u32 = 0;
    return switch (iterator) {
        inline .grapheme_utf8,
        .grapheme_utf16,
        .sentence_utf8,
        .sentence_utf16,
        => |*it| while (it.next()) |index| : (previous_index = @intCast(index)) {
            if (index > start_index) break .{ .index = previous_index };
        } else null,
        inline .word_utf8,
        .word_utf16,
        => |*it| while (it.next()) |index| : (previous_index = @intCast(index)) {
            if (index > start_index) break .{ .index = previous_index, .is_word_like = it.isWordLike() };
        } else null,
    };
}

fn findBoundaryAfter(
    string: *const String,
    start_index: u32,
    granularity: builtins.intl.Segmenter.Fields.SegmenterGranularity,
) ?Boundary {
    const segmenter: AnySegmenter = switch (granularity) {
        .grapheme => .{ .grapheme = .init() },
        .word => .{ .word = .init() },
        .sentence => .{ .sentence = .init() },
    };
    defer segmenter.deinit();
    var iterator = segmenter.segment(string);
    defer iterator.deinit();
    return switch (iterator) {
        inline .grapheme_utf8,
        .grapheme_utf16,
        .sentence_utf8,
        .sentence_utf16,
        => |*it| while (it.next()) |index| {
            if (index > start_index) break .{ .index = @intCast(index) };
        } else null,
        inline .word_utf8, .word_utf16 => |*it| while (it.next()) |index| {
            if (index > start_index) return .{ .index = @intCast(index), .is_word_like = it.isWordLike() };
        } else null,
    };
}
