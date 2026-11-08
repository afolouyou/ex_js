const std = @import("std");

const temporal_rs = @import("temporal_rs");

const build_options = @import("build-options");
const builtins = @import("builtins.zig");
const execution = @import("execution.zig");
const types = @import("types.zig");

const Agent = execution.Agent;
const BigInt = types.BigInt;
const Object = types.Object;
const String = types.String;
const Value = types.Value;
const fmtToDateString = builtins.date.fmtToDateString;
const makeTypedArrayWithBufferWitnessRecord = builtins.makeTypedArrayWithBufferWitnessRecord;
const ordinaryOwnPropertyKeys = builtins.ordinaryOwnPropertyKeys;
const typedArrayLength = builtins.typedArrayLength;
const weakRefDeref = builtins.weakRefDeref;

const State = struct {
    seen_objects: std.AutoHashMapUnmanaged(*const Object, usize),
    print_in_progress: bool,
    platform: *const Agent.Platform,
};

var fba_buf: [64 * 1024]u8 = undefined;
var fba = std.heap.FixedBufferAllocator.init(&fba_buf);
var arena = std.heap.ArenaAllocator.init(fba.allocator());
pub var state: State = .{
    .seen_objects = .empty,
    .print_in_progress = false,
    .platform = undefined, // Set whenever an `Agent` is created
};

fn asciiString(ascii: []const u8) *const String {
    const string = arena.allocator().create(String) catch unreachable;
    string.* = .{
        .data = .{ .owned_ascii = ascii.ptr },
        .length = @intCast(ascii.len),
        .hash = undefined,
    };
    return string;
}

fn bigInt(value: anytype) *const BigInt {
    var managed = std.math.big.int.Managed.initSet(arena.allocator(), value) catch unreachable;
    errdefer managed.deinit();
    const big_int = arena.allocator().create(BigInt) catch unreachable;
    big_int.* = .{ .managed = managed };
    return big_int;
}

const PrettyPrintError = std.Io.Terminal.SetColorError;

fn prettyPrintArray(
    array: *const builtins.Array,
    terminal: std.Io.Terminal,
) PrettyPrintError!void {
    const length = array.fields.length;
    const indexed_properties = array.object.indexedProperties();

    try terminal.setColor(.white);
    try terminal.writer.writeAll("[");
    try terminal.setColor(.reset);
    if (length != 0) try terminal.writer.writeAll(" ");
    for (0..length) |i| {
        if (indexed_properties.get(@intCast(i))) |property_descriptor| {
            switch (property_descriptor.value_or_accessor) {
                .value => |value| {
                    try terminal.writer.print("{f}", .{value.fmtPretty(terminal.mode)});
                },
                .accessor => {
                    try terminal.setColor(.dim);
                    try terminal.writer.writeAll("<accessor>");
                    try terminal.setColor(.reset);
                },
            }
        } else {
            try terminal.setColor(.dim);
            try terminal.writer.writeAll("<empty>");
            try terminal.setColor(.reset);
        }
        if (i + 1 < length) try terminal.writer.writeAll(", ");
    }
    if (length != 0) try terminal.writer.writeAll(" ");
    try terminal.setColor(.white);
    try terminal.writer.writeAll("]");
    try terminal.setColor(.reset);
}

fn prettyPrintArrayBuffer(
    array_buffer: *const builtins.ArrayBuffer,
    terminal: std.Io.Terminal,
) PrettyPrintError!void {
    if (array_buffer.fields.data_block) |data_block| {
        try terminal.setColor(.white);
        if (data_block.shared) {
            try terminal.writer.writeAll("SharedArrayBuffer(");
        } else {
            try terminal.writer.writeAll("ArrayBuffer(");
        }
        try terminal.setColor(.reset);
        try terminal.writer.print("byteLength: {f}", .{
            Value.from(@backingInt(array_buffer.fields.byte_length)).fmtPretty(terminal.mode),
        });
        if (array_buffer.fields.max_byte_length.unwrap()) |max_byte_length| {
            try terminal.writer.print(", maxByteLength: {f}", .{
                Value.from(@backingInt(max_byte_length)).fmtPretty(terminal.mode),
            });
        }
        if (data_block.bytes.len != 0) {
            try terminal.writer.writeAll(", data: ");
            try terminal.setColor(.dim);
            // Like std.fmt.fmtSliceHexLower() but with a space between each bytes
            const charset = "0123456789abcdef";
            var buf: [2]u8 = undefined;
            for (data_block.bytes, 0..) |c, i| {
                if (i != 0) try terminal.writer.writeAll(" ");
                buf[0] = charset[c >> 4];
                buf[1] = charset[c & 15];
                try terminal.writer.writeAll(&buf);
            }
            try terminal.setColor(.reset);
        }
        try terminal.setColor(.white);
        try terminal.writer.writeAll(")");
        try terminal.setColor(.reset);
    } else {
        try terminal.setColor(.white);
        try terminal.writer.writeAll("ArrayBuffer(");
        try terminal.setColor(.dim);
        try terminal.writer.writeAll("<detached>");
        try terminal.setColor(.white);
        try terminal.writer.writeAll(")");
        try terminal.setColor(.reset);
    }
}

fn prettyPrintArrayIterator(
    array_iterator: *const builtins.ArrayIterator,
    terminal: std.Io.Terminal,
) PrettyPrintError!void {
    try terminal.setColor(.white);
    try terminal.writer.writeAll("%ArrayIterator%(");
    try terminal.setColor(.reset);
    switch (array_iterator.fields) {
        .state => |state_| {
            try terminal.writer.print("{f}", .{Value.from(state_.iterated_array_like).fmtPretty(terminal.mode)});
        },
        .completed => {
            try terminal.setColor(.dim);
            try terminal.writer.writeAll("<completed>");
            try terminal.setColor(.reset);
        },
    }
    try terminal.setColor(.white);
    try terminal.writer.writeAll(")");
    try terminal.setColor(.reset);
}

fn prettyPrintAsyncDisposableStack(
    async_disposable_stack: *const builtins.AsyncDisposableStack,
    terminal: std.Io.Terminal,
) PrettyPrintError!void {
    try terminal.setColor(.white);
    try terminal.writer.writeAll("AsyncDisposableStack(");
    try terminal.setColor(.reset);
    switch (async_disposable_stack.fields) {
        .pending => |disposable_resource_stack| {
            for (disposable_resource_stack.items, 0..) |resource, i| {
                if (i != 0) try terminal.writer.writeAll(", ");
                const value = if (resource.resource_value) |obj| Value.from(obj) else Value.undefined;
                try terminal.writer.print("{f}", .{value.fmtPretty(terminal.mode)});
            }
        },
        .disposed => {
            try terminal.setColor(.dim);
            try terminal.writer.writeAll("<disposed>");
            try terminal.setColor(.reset);
        },
    }
    try terminal.setColor(.white);
    try terminal.writer.writeAll(")");
    try terminal.setColor(.reset);
}

fn prettyPrintAsyncGenerator(
    async_gen: *const builtins.AsyncGenerator,
    terminal: std.Io.Terminal,
) PrettyPrintError!void {
    try terminal.setColor(.white);
    try terminal.writer.writeAll("AsyncGenerator(");
    try terminal.setColor(.reset);
    switch (async_gen.fields.async_generator_state) {
        .suspended_start => {
            try terminal.setColor(.cyan);
            try terminal.writer.writeAll("<suspended-start>");
            try terminal.setColor(.reset);
        },
        .suspended_yield => {
            try terminal.setColor(.cyan);
            try terminal.writer.writeAll("<suspended-yield>");
            try terminal.setColor(.reset);
        },
        .executing => {
            try terminal.setColor(.green);
            try terminal.writer.writeAll("<executing>");
            try terminal.setColor(.reset);
        },
        .draining_queue => {
            try terminal.setColor(.cyan);
            try terminal.writer.writeAll("<draining-queue>");
            try terminal.setColor(.reset);
        },
        .completed => {
            try terminal.setColor(.dim);
            try terminal.writer.writeAll("<completed>");
            try terminal.setColor(.reset);
        },
    }
    try terminal.setColor(.white);
    try terminal.writer.writeAll(")");
    try terminal.setColor(.reset);
}

fn prettyPrintDataView(
    date: *const builtins.DataView,
    terminal: std.Io.Terminal,
) PrettyPrintError!void {
    const viewed_array_buffer = date.fields.viewed_array_buffer;
    const byte_offset = date.fields.byte_offset;

    try terminal.setColor(.white);
    try terminal.writer.writeAll("DataView(");
    try terminal.setColor(.reset);
    try terminal.writer.print("arrayBuffer: {f}", .{Value.from(&viewed_array_buffer.object).fmtPretty(terminal.mode)});
    if (date.fields.byte_length.unwrap()) |byte_length| {
        try terminal.writer.print(", byteLength: {f}", .{Value.from(@backingInt(byte_length)).fmtPretty(terminal.mode)});
    }
    if (byte_offset != .zero) {
        try terminal.writer.print(", byteOffset: {f}", .{Value.from(@backingInt(byte_offset)).fmtPretty(terminal.mode)});
    }
    try terminal.setColor(.white);
    try terminal.writer.writeAll(")");
    try terminal.setColor(.reset);
}

fn prettyPrintDate(
    date: *const builtins.Date,
    terminal: std.Io.Terminal,
) PrettyPrintError!void {
    const date_value = date.fields.date_value;
    const platform = state.platform;

    try terminal.setColor(.white);
    try terminal.writer.writeAll("Date(");
    if (!std.math.isNan(date_value)) {
        try terminal.writer.print("{f}", .{
            Value.from(asciiString(arena.allocator().print(
                "{f}",
                .{fmtToDateString(platform, date_value)},
            ) catch return)).fmtPretty(terminal.mode),
        });
    } else {
        try terminal.setColor(.dim);
        try terminal.writer.writeAll("<invalid>");
        try terminal.setColor(.reset);
    }
    try terminal.setColor(.white);
    try terminal.writer.writeAll(")");
    try terminal.setColor(.reset);
}

fn prettyPrintDisposableStack(
    disposable_stack: *const builtins.DisposableStack,
    terminal: std.Io.Terminal,
) PrettyPrintError!void {
    try terminal.setColor(.white);
    try terminal.writer.writeAll("DisposableStack(");
    try terminal.setColor(.reset);
    switch (disposable_stack.fields) {
        .pending => |disposable_resource_stack| {
            for (disposable_resource_stack.items, 0..) |resource, i| {
                if (i != 0) try terminal.writer.writeAll(", ");
                const value = if (resource.resource_value) |obj| Value.from(obj) else Value.undefined;
                try terminal.writer.print("{f}", .{value.fmtPretty(terminal.mode)});
            }
        },
        .disposed => {
            try terminal.setColor(.dim);
            try terminal.writer.writeAll("<disposed>");
            try terminal.setColor(.reset);
        },
    }
    try terminal.setColor(.white);
    try terminal.writer.writeAll(")");
    try terminal.setColor(.reset);
}

fn prettyPrintError(
    @"error": *const builtins.Error,
    terminal: std.Io.Terminal,
) PrettyPrintError!void {
    try terminal.setColor(.white);
    try terminal.writer.print("{f}(", .{@"error".fields.name.fmtRaw()});
    try terminal.setColor(.reset);
    if (!@"error".fields.message.isEmpty()) {
        try terminal.writer.print("{f}", .{Value.from(@"error".fields.message).fmtPretty(terminal.mode)});
    }
    try terminal.setColor(.white);
    try terminal.writer.writeAll(")");
    try terminal.setColor(.reset);
}

fn prettyPrintFinalizationRegistry(
    finalization_registry: *const builtins.FinalizationRegistry,
    terminal: std.Io.Terminal,
) PrettyPrintError!void {
    try terminal.setColor(.white);
    try terminal.writer.writeAll("FinalizationRegistry(");
    try terminal.setColor(.reset);
    try terminal.writer.print("{f}", .{
        Value.from(finalization_registry.fields.cleanup_callback.callback).fmtPretty(terminal.mode),
    });
    try terminal.setColor(.white);
    try terminal.writer.writeAll(")");
    try terminal.setColor(.reset);
}

fn prettyPrintGenerator(
    gen: *const builtins.Generator,
    terminal: std.Io.Terminal,
) PrettyPrintError!void {
    try terminal.setColor(.white);
    try terminal.writer.writeAll("Generator(");
    try terminal.setColor(.reset);
    switch (gen.fields.generator_state) {
        .suspended_start => {
            try terminal.setColor(.cyan);
            try terminal.writer.writeAll("<suspended-start>");
            try terminal.setColor(.reset);
        },
        .suspended_yield => {
            try terminal.setColor(.cyan);
            try terminal.writer.writeAll("<suspended-yield>");
            try terminal.setColor(.reset);
        },
        .executing => {
            try terminal.setColor(.green);
            try terminal.writer.writeAll("<executing>");
            try terminal.setColor(.reset);
        },
        .completed => {
            try terminal.setColor(.dim);
            try terminal.writer.writeAll("<completed>");
            try terminal.setColor(.reset);
        },
    }
    try terminal.setColor(.white);
    try terminal.writer.writeAll(")");
    try terminal.setColor(.reset);
}

fn prettyPrintIterator(
    _: *const builtins.Iterator,
    terminal: std.Io.Terminal,
) PrettyPrintError!void {
    try terminal.setColor(.white);
    try terminal.writer.writeAll("Iterator()");
    try terminal.setColor(.reset);
}

fn prettyPrintIteratorHelper(
    iterator_helper: *const builtins.IteratorHelper,
    terminal: std.Io.Terminal,
) PrettyPrintError!void {
    try terminal.setColor(.white);
    try terminal.writer.writeAll("%IteratorHelper%(");
    try terminal.setColor(.reset);
    switch (iterator_helper.fields) {
        .state => |state_| {
            for (state_.underlying_iterators, 0..) |iterator, i| {
                if (i != 0) try terminal.writer.writeAll(", ");
                try terminal.writer.print("{f}", .{Value.from(iterator.iterator).fmtPretty(terminal.mode)});
            }
        },
        .completed => {
            try terminal.setColor(.dim);
            try terminal.writer.writeAll("<completed>");
            try terminal.setColor(.reset);
        },
    }
    try terminal.setColor(.white);
    try terminal.writer.writeAll(")");
    try terminal.setColor(.reset);
}

fn prettyPrintMap(
    map: *const builtins.Map,
    terminal: std.Io.Terminal,
) PrettyPrintError!void {
    const map_data = map.fields.map_data;

    try terminal.setColor(.white);
    try terminal.writer.writeAll("Map(");
    try terminal.setColor(.reset);
    var it = map_data.iterator();
    while (it.next()) |entry| {
        try terminal.writer.print("{f} → {f}", .{ entry.key_ptr.fmtPretty(terminal.mode), entry.value_ptr.fmtPretty(terminal.mode) });
        if (it.index < map_data.count()) {
            try terminal.writer.writeAll(", ");
        }
    }
    try terminal.setColor(.white);
    try terminal.writer.writeAll(")");
    try terminal.setColor(.reset);
}

fn prettyPrintMapIterator(
    map_iterator: *const builtins.MapIterator,
    terminal: std.Io.Terminal,
) PrettyPrintError!void {
    try terminal.setColor(.white);
    try terminal.writer.writeAll("%MapIterator%(");
    try terminal.setColor(.reset);
    switch (map_iterator.fields) {
        .state => |state_| {
            try terminal.writer.print("{f}", .{Value.from(&state_.map.object).fmtPretty(terminal.mode)});
        },
        .completed => {
            try terminal.setColor(.dim);
            try terminal.writer.writeAll("<completed>");
            try terminal.setColor(.reset);
        },
    }
    try terminal.setColor(.white);
    try terminal.writer.writeAll(")");
    try terminal.setColor(.reset);
}

fn prettyPrintPromise(
    promise: *const builtins.Promise,
    terminal: std.Io.Terminal,
) PrettyPrintError!void {
    const promise_state = promise.fields.promise_state;

    try terminal.setColor(.white);
    try terminal.writer.writeAll("Promise(");
    try terminal.setColor(.reset);
    switch (promise_state) {
        .pending => {
            try terminal.setColor(.dim);
            try terminal.writer.writeAll("<pending>");
            try terminal.setColor(.reset);
        },
        .fulfilled => {
            try terminal.setColor(.green);
            try terminal.writer.writeAll("<fulfilled>");
            try terminal.setColor(.reset);
            try terminal.writer.print(" {f}", .{promise.fields.promise_result.fmtPretty(terminal.mode)});
        },
        .rejected => {
            try terminal.setColor(.red);
            try terminal.writer.writeAll("<rejected>");
            try terminal.setColor(.reset);
            try terminal.writer.print(" {f}", .{promise.fields.promise_result.fmtPretty(terminal.mode)});
        },
    }
    try terminal.setColor(.white);
    try terminal.writer.writeAll(")");
    try terminal.setColor(.reset);
}

fn prettyPrintProxy(
    proxy: *const builtins.Proxy,
    terminal: std.Io.Terminal,
) PrettyPrintError!void {
    const proxy_target = proxy.fields.proxy_target;
    const proxy_handler = proxy.fields.proxy_handler;

    try terminal.setColor(.white);
    try terminal.writer.writeAll("Proxy(");
    try terminal.setColor(.reset);
    if (proxy_target != null and proxy_handler != null) {
        try terminal.writer.print("target: {f}, handler: {f}", .{
            Value.from(proxy_target.?).fmtPretty(terminal.mode),
            Value.from(proxy_handler.?).fmtPretty(terminal.mode),
        });
    } else {
        try terminal.setColor(.dim);
        try terminal.writer.writeAll("<revoked>");
        try terminal.setColor(.reset);
    }
    try terminal.setColor(.white);
    try terminal.writer.writeAll(")");
    try terminal.setColor(.reset);
}

fn prettyPrintRegExp(
    reg_exp: *const builtins.RegExp,
    terminal: std.Io.Terminal,
) PrettyPrintError!void {
    const original_source = reg_exp.fields.original_source;
    const original_flags = reg_exp.fields.original_flags;

    try terminal.setColor(.white);
    try terminal.writer.writeAll("RegExp(");
    try terminal.setColor(.green);
    try terminal.writer.print("/{f}/{f}", .{ original_source.fmtRaw(), original_flags.fmtRaw() });
    try terminal.setColor(.white);
    try terminal.writer.writeAll(")");
    try terminal.setColor(.reset);
}

fn prettyPrintRegExpStringIterator(
    reg_exp_string_iterator: *const builtins.RegExpStringIterator,
    terminal: std.Io.Terminal,
) PrettyPrintError!void {
    try terminal.setColor(.white);
    try terminal.writer.writeAll("%RegExpStringIterator%(");
    try terminal.setColor(.reset);
    switch (reg_exp_string_iterator.fields) {
        .state => |state_| {
            try terminal.writer.print("{f}, {f}", .{
                Value.from(state_.iterating_regexp).fmtPretty(terminal.mode),
                Value.from(state_.iterated_string).fmtPretty(terminal.mode),
            });
        },
        .completed => {
            try terminal.setColor(.dim);
            try terminal.writer.writeAll("<completed>");
            try terminal.setColor(.reset);
        },
    }
    try terminal.setColor(.white);
    try terminal.writer.writeAll(")");
    try terminal.setColor(.reset);
}

fn prettyPrintSet(
    set: *const builtins.Set,
    terminal: std.Io.Terminal,
) PrettyPrintError!void {
    const set_data = set.fields.set_data;

    try terminal.setColor(.white);
    try terminal.writer.writeAll("Set(");
    try terminal.setColor(.reset);
    var it = set_data.iterator();
    while (it.next()) |entry| {
        try terminal.writer.print("{f}", .{entry.key_ptr.fmtPretty(terminal.mode)});
        if (it.index < set_data.count()) {
            try terminal.writer.writeAll(", ");
        }
    }
    try terminal.setColor(.white);
    try terminal.writer.writeAll(")");
    try terminal.setColor(.reset);
}

fn prettyPrintSetIterator(
    set_iterator: *const builtins.SetIterator,
    terminal: std.Io.Terminal,
) PrettyPrintError!void {
    try terminal.setColor(.white);
    try terminal.writer.writeAll("%SetIterator%(");
    try terminal.setColor(.reset);
    switch (set_iterator.fields) {
        .state => |state_| {
            try terminal.writer.print("{f}", .{Value.from(&state_.set.object).fmtPretty(terminal.mode)});
        },
        .completed => {
            try terminal.setColor(.dim);
            try terminal.writer.writeAll("<completed>");
            try terminal.setColor(.reset);
        },
    }
    try terminal.setColor(.white);
    try terminal.writer.writeAll(")");
    try terminal.setColor(.reset);
}

fn prettyPrintStringIterator(
    string_iterator: *const builtins.StringIterator,
    terminal: std.Io.Terminal,
) PrettyPrintError!void {
    try terminal.setColor(.white);
    try terminal.writer.writeAll("%StringIterator%(");
    try terminal.setColor(.reset);
    switch (string_iterator.fields) {
        .state => |state_| {
            try terminal.writer.print("{f}", .{Value.from(state_.string).fmtPretty(terminal.mode)});
        },
        .completed => {
            try terminal.setColor(.dim);
            try terminal.writer.writeAll("<completed>");
            try terminal.setColor(.reset);
        },
    }
    try terminal.setColor(.white);
    try terminal.writer.writeAll(")");
    try terminal.setColor(.reset);
}

fn prettyPrintTypedArray(
    typed_array: *const builtins.TypedArray,
    terminal: std.Io.Terminal,
) PrettyPrintError!void {
    const element_type = typed_array.fields.element_type;
    const viewed_array_buffer = typed_array.fields.viewed_array_buffer;

    try terminal.setColor(.white);
    try terminal.writer.print("{s}(", .{element_type.typedArrayName()});
    try terminal.setColor(.reset);
    if (viewed_array_buffer.fields.data_block) |data_block| {
        const ta = makeTypedArrayWithBufferWitnessRecord(@constCast(typed_array), .seq_cst);
        const array_length = typedArrayLength(ta);
        const byte_offset = typed_array.fields.byte_offset;
        try terminal.writer.print("length: {f}", .{Value.from(@backingInt(array_length)).fmtPretty(terminal.mode)});
        if (data_block.bytes.len != 0) {
            try terminal.writer.writeAll(", data: ");
            try terminal.setColor(.white);
            try terminal.writer.writeAll("[");
            try terminal.setColor(.reset);
            try terminal.writer.writeAll(" ");
            switch (element_type) {
                inline else => |@"type"| {
                    const element_size = @"type".elementSize();
                    var i: u53 = 0;
                    while (i < data_block.bytes.len) : (i += element_size) {
                        const bytes: *[element_size]u8 = @ptrCast(
                            data_block.bytes[@intCast(@backingInt(byte_offset) + i)..@intCast(@backingInt(byte_offset) + i + element_size)],
                        );
                        const value = std.mem.bytesAsValue(@"type".type(), bytes).*;
                        const numeric = if (@"type".isBigIntElementType())
                            Value.from(bigInt(value))
                        else
                            Value.from(value);
                        if (i != 0) try terminal.writer.writeAll(", ");
                        try terminal.writer.print("{f}", .{numeric.fmtPretty(terminal.mode)});
                    }
                },
            }
            try terminal.writer.writeAll(" ");
            try terminal.setColor(.white);
            try terminal.writer.writeAll("]");
            try terminal.setColor(.reset);
        }
    } else {
        // Underlying ArrayBuffer has been detached, mirror behavior of .length getter
        try terminal.writer.print("length: {f}", .{Value.from(0).fmtPretty(terminal.mode)});
    }
    try terminal.setColor(.white);
    try terminal.writer.writeAll(")");
    try terminal.setColor(.reset);
}

fn prettyPrintWeakMap(
    map: *const builtins.WeakMap,
    terminal: std.Io.Terminal,
) PrettyPrintError!void {
    const weak_map_data = map.fields.weak_map_data;

    try terminal.setColor(.white);
    try terminal.writer.writeAll("WeakMap(");
    try terminal.setColor(.reset);
    var it = weak_map_data.iterator();
    while (it.next()) |entry| {
        try terminal.writer.print("{f} → {f}", .{ entry.key_ptr.get().fmtPretty(terminal.mode), entry.value_ptr.fmtPretty(terminal.mode) });
        if (it.index < weak_map_data.count()) {
            try terminal.writer.writeAll(", ");
        }
    }
    try terminal.setColor(.white);
    try terminal.writer.writeAll(")");
    try terminal.setColor(.reset);
}

fn prettyPrintWeakRef(
    weak_ref: *const builtins.WeakRef,
    terminal: std.Io.Terminal,
) PrettyPrintError!void {
    try terminal.setColor(.white);
    try terminal.writer.writeAll("WeakRef(");
    try terminal.setColor(.reset);
    try prettyPrintValue(weakRefDeref(weak_ref), terminal);
    try terminal.setColor(.white);
    try terminal.writer.writeAll(")");
    try terminal.setColor(.reset);
}

fn prettyPrintWeakSet(
    weak_set: *const builtins.WeakSet,
    terminal: std.Io.Terminal,
) PrettyPrintError!void {
    const weak_set_data = weak_set.fields.weak_set_data;

    try terminal.setColor(.white);
    try terminal.writer.writeAll("WeakSet(");
    try terminal.setColor(.reset);
    var it = weak_set_data.iterator();
    while (it.next()) |entry| {
        try terminal.writer.print("{f}", .{entry.key_ptr.get().fmtPretty(terminal.mode)});
        if (it.index < weak_set_data.count()) {
            try terminal.writer.writeAll(", ");
        }
    }
    try terminal.setColor(.white);
    try terminal.writer.writeAll(")");
    try terminal.setColor(.reset);
}

fn prettyPrintWrapForValidIterator(
    wrap_for_valid_iterator: *const builtins.WrapForValidIterator,
    terminal: std.Io.Terminal,
) PrettyPrintError!void {
    try terminal.setColor(.white);
    try terminal.writer.writeAll("%WrapForValidIterator%(");
    try terminal.setColor(.reset);
    try terminal.writer.print("{f}", .{Value.from(wrap_for_valid_iterator.fields.iterated.iterator).fmtPretty(terminal.mode)});
    try terminal.setColor(.white);
    try terminal.writer.writeAll(")");
    try terminal.setColor(.reset);
}

fn prettyPrintIntlCollator(
    intl_collator: *const builtins.intl.Collator,
    terminal: std.Io.Terminal,
) PrettyPrintError!void {
    const locale = intl_collator.fields.locale;

    const resolved_options = intl_collator.fields.resolvedOptions();

    try terminal.setColor(.white);
    try terminal.writer.writeAll("Intl.Collator(");
    try terminal.setColor(.reset);
    try terminal.writer.print("{f}, usage: {f}, sensitivity: {f}, ignorePunctuation: " ++
        "{f}, collation: {f}, numeric: {f}, caseFirst: {f}", .{
        Value.from(asciiString(locale.toString(arena.allocator()) catch return)).fmtPretty(terminal.mode),
        Value.from(resolved_options.usage).fmtPretty(terminal.mode),
        Value.from(resolved_options.sensitivity).fmtPretty(terminal.mode),
        Value.from(resolved_options.ignore_punctuation).fmtPretty(terminal.mode),
        Value.from(resolved_options.collation).fmtPretty(terminal.mode),
        Value.from(resolved_options.numeric).fmtPretty(terminal.mode),
        Value.from(resolved_options.case_first).fmtPretty(terminal.mode),
    });
    try terminal.setColor(.white);
    try terminal.writer.writeAll(")");
    try terminal.setColor(.reset);
}

fn prettyPrintIntlDateTimeFormat(
    intl_date_time_format: *const builtins.intl.DateTimeFormat,
    terminal: std.Io.Terminal,
) PrettyPrintError!void {
    const locale = intl_date_time_format.fields.locale;

    const resolved_options = intl_date_time_format.fields.resolvedOptions();

    try terminal.setColor(.white);
    try terminal.writer.writeAll("Intl.DateTimeFormat(");
    try terminal.setColor(.reset);
    try terminal.writer.print("{f}, calendar: {f}, numberingSystem: {f}, timeZone: {f}", .{
        Value.from(asciiString(locale.toString(arena.allocator()) catch return)).fmtPretty(terminal.mode),
        Value.from(resolved_options.calendar).fmtPretty(terminal.mode),
        Value.from(resolved_options.numbering_system).fmtPretty(terminal.mode),
        Value.from(resolved_options.time_zone).fmtPretty(terminal.mode),
    });
    if (resolved_options.date_style) |date_style| {
        try terminal.writer.print(", dateStyle: {f}", .{Value.from(date_style).fmtPretty(terminal.mode)});
    }
    if (resolved_options.time_style) |time_style| {
        try terminal.writer.print(", timeStyle: {f}", .{Value.from(time_style).fmtPretty(terminal.mode)});
    }
    try terminal.setColor(.white);
    try terminal.writer.writeAll(")");
    try terminal.setColor(.reset);
}

fn prettyPrintIntlDisplayNames(
    intl_display_names: *const builtins.intl.DisplayNames,
    terminal: std.Io.Terminal,
) PrettyPrintError!void {
    const locale = intl_display_names.fields.locale;

    const resolved_options = intl_display_names.fields.resolvedOptions();

    try terminal.setColor(.white);
    try terminal.writer.writeAll("Intl.DisplayNames(");
    try terminal.setColor(.reset);
    if (intl_display_names.fields.type == .language) {
        try terminal.writer.print("{f}, style: {f}, type: {f}, fallback: {f}, languageDisplay: {f}", .{
            Value.from(asciiString(locale.toString(arena.allocator()) catch return)).fmtPretty(terminal.mode),
            Value.from(resolved_options.style).fmtPretty(terminal.mode),
            Value.from(resolved_options.type).fmtPretty(terminal.mode),
            Value.from(resolved_options.fallback).fmtPretty(terminal.mode),
            Value.from(resolved_options.language_display).fmtPretty(terminal.mode),
        });
    } else {
        try terminal.writer.print("{f}, style: {f}, type: {f}, fallback: {f}", .{
            Value.from(asciiString(locale.toString(arena.allocator()) catch return)).fmtPretty(terminal.mode),
            Value.from(resolved_options.style).fmtPretty(terminal.mode),
            Value.from(resolved_options.type).fmtPretty(terminal.mode),
            Value.from(resolved_options.fallback).fmtPretty(terminal.mode),
        });
    }
    try terminal.setColor(.white);
    try terminal.writer.writeAll(")");
    try terminal.setColor(.reset);
}

fn prettyPrintIntlDurationFormat(
    intl_duration_format: *const builtins.intl.DurationFormat,
    terminal: std.Io.Terminal,
) PrettyPrintError!void {
    const locale = intl_duration_format.fields.locale;

    const resolved_options = intl_duration_format.fields.resolvedOptions();

    try terminal.setColor(.white);
    try terminal.writer.writeAll("Intl.DurationFormat(");
    try terminal.setColor(.reset);
    try terminal.writer.print("{f}, numberingSystem: {f}, style: {f}, years: {f}, " ++
        "yearsDisplay: {f}, months: {f}, monthsDisplay: {f}, weeks: {f}, " ++
        "weeksDisplay: {f}, days: {f}, daysDisplay: {f}, hours: {f}, " ++
        "hoursDisplay: {f}, minutes: {f}, minutesDisplay: {f}, seconds: {f}, " ++
        "secondsDisplay: {f}, milliseconds: {f}, millisecondsDisplay: {f}, " ++
        "microseconds: {f}, microsecondsDisplay: {f}, nanoseconds: {f}, " ++
        "nanosecondsDisplay: {f}", .{
        Value.from(asciiString(locale.toString(arena.allocator()) catch return)).fmtPretty(terminal.mode),
        Value.from(resolved_options.numbering_system).fmtPretty(terminal.mode),
        Value.from(resolved_options.style).fmtPretty(terminal.mode),
        Value.from(resolved_options.years).fmtPretty(terminal.mode),
        Value.from(resolved_options.years_display).fmtPretty(terminal.mode),
        Value.from(resolved_options.months).fmtPretty(terminal.mode),
        Value.from(resolved_options.months_display).fmtPretty(terminal.mode),
        Value.from(resolved_options.weeks).fmtPretty(terminal.mode),
        Value.from(resolved_options.weeks_display).fmtPretty(terminal.mode),
        Value.from(resolved_options.days).fmtPretty(terminal.mode),
        Value.from(resolved_options.days_display).fmtPretty(terminal.mode),
        Value.from(resolved_options.hours).fmtPretty(terminal.mode),
        Value.from(resolved_options.hours_display).fmtPretty(terminal.mode),
        Value.from(resolved_options.minutes).fmtPretty(terminal.mode),
        Value.from(resolved_options.minutes_display).fmtPretty(terminal.mode),
        Value.from(resolved_options.seconds).fmtPretty(terminal.mode),
        Value.from(resolved_options.seconds_display).fmtPretty(terminal.mode),
        Value.from(resolved_options.milliseconds).fmtPretty(terminal.mode),
        Value.from(resolved_options.milliseconds_display).fmtPretty(terminal.mode),
        Value.from(resolved_options.microseconds).fmtPretty(terminal.mode),
        Value.from(resolved_options.microseconds_display).fmtPretty(terminal.mode),
        Value.from(resolved_options.nanoseconds).fmtPretty(terminal.mode),
        Value.from(resolved_options.nanoseconds_display).fmtPretty(terminal.mode),
    });
    if (resolved_options.fractional_digits) |fractional_digits| {
        try terminal.writer.print(", fractionalDigits: {f}", .{Value.from(fractional_digits).fmtPretty(terminal.mode)});
    }
    try terminal.setColor(.white);
    try terminal.writer.writeAll(")");
    try terminal.setColor(.reset);
}

fn prettyPrintIntlListFormat(
    intl_list_format: *const builtins.intl.ListFormat,
    terminal: std.Io.Terminal,
) PrettyPrintError!void {
    const locale = intl_list_format.fields.locale;

    const resolved_options = intl_list_format.fields.resolvedOptions();

    try terminal.setColor(.white);
    try terminal.writer.writeAll("Intl.ListFormat(");
    try terminal.setColor(.reset);
    try terminal.writer.print("{f}, type: {f}, style: {f}", .{
        Value.from(asciiString(locale.toString(arena.allocator()) catch return)).fmtPretty(terminal.mode),
        Value.from(resolved_options.type).fmtPretty(terminal.mode),
        Value.from(resolved_options.style).fmtPretty(terminal.mode),
    });
    try terminal.setColor(.white);
    try terminal.writer.writeAll(")");
    try terminal.setColor(.reset);
}

fn prettyPrintIntlLocale(
    intl_locale: *const builtins.intl.Locale,
    terminal: std.Io.Terminal,
) PrettyPrintError!void {
    const locale = intl_locale.fields.locale;

    try terminal.setColor(.white);
    try terminal.writer.writeAll("Intl.Locale(");
    try terminal.setColor(.reset);
    try terminal.writer.print("{f}", .{
        Value.from(asciiString(locale.toString(arena.allocator()) catch return)).fmtPretty(terminal.mode),
    });
    try terminal.setColor(.white);
    try terminal.writer.writeAll(")");
    try terminal.setColor(.reset);
}

fn prettyPrintIntlNumberFormat(
    intl_number_format: *const builtins.intl.NumberFormat,
    terminal: std.Io.Terminal,
) PrettyPrintError!void {
    const locale = intl_number_format.fields.locale;

    const resolved_options = intl_number_format.fields.resolvedOptions();

    try terminal.setColor(.white);
    try terminal.writer.writeAll("Intl.NumberFormat(");
    try terminal.setColor(.reset);
    try terminal.writer.print("{f}, numberingSystem: {f}, style: {f}", .{
        Value.from(asciiString(locale.toString(arena.allocator()) catch return)).fmtPretty(terminal.mode),
        Value.from(resolved_options.numbering_system).fmtPretty(terminal.mode),
        Value.from(resolved_options.style).fmtPretty(terminal.mode),
    });
    if (resolved_options.currency) |currency| {
        try terminal.writer.print(", currency: {f}", .{Value.from(currency).fmtPretty(terminal.mode)});
    }
    if (resolved_options.currency_display) |currency_display| {
        try terminal.writer.print(", currencyDisplay: {f}", .{Value.from(currency_display).fmtPretty(terminal.mode)});
    }
    if (resolved_options.currency_sign) |currency_sign| {
        try terminal.writer.print(", currencySign: {f}", .{Value.from(currency_sign).fmtPretty(terminal.mode)});
    }
    if (resolved_options.unit) |unit| {
        try terminal.writer.print(", unit: {f}", .{Value.from(unit).fmtPretty(terminal.mode)});
    }
    if (resolved_options.unit_display) |unit_display| {
        try terminal.writer.print(", unitDisplay: {f}", .{Value.from(unit_display).fmtPretty(terminal.mode)});
    }
    try terminal.writer.print(", minimumIntegerDigits: {f}", .{
        Value.from(resolved_options.minimum_integer_digits).fmtPretty(terminal.mode),
    });
    if (resolved_options.minimum_fraction_digits) |minimum_fraction_digits| {
        try terminal.writer.print(", minimumFractionDigits: {f}", .{Value.from(minimum_fraction_digits).fmtPretty(terminal.mode)});
    }
    if (resolved_options.maximum_fraction_digits) |maximum_fraction_digits| {
        try terminal.writer.print(", maximumFractionDigits: {f}", .{Value.from(maximum_fraction_digits).fmtPretty(terminal.mode)});
    }
    if (resolved_options.minimum_significant_digits) |minimum_significant_digits| {
        try terminal.writer.print(", minimumSignificantDigits: {f}", .{Value.from(minimum_significant_digits).fmtPretty(terminal.mode)});
    }
    if (resolved_options.maximum_significant_digits) |maximum_significant_digits| {
        try terminal.writer.print(", maximumSignificantDigits: {f}", .{Value.from(maximum_significant_digits).fmtPretty(terminal.mode)});
    }
    try terminal.writer.print(", useGrouping: {f}, notation: {f}", .{
        switch (resolved_options.use_grouping) {
            .false => Value.false,
            .string => |string| Value.from(string),
        }.fmtPretty(terminal.mode),
        Value.from(resolved_options.notation).fmtPretty(terminal.mode),
    });
    if (resolved_options.compact_display) |compact_display| {
        try terminal.writer.print(", compactDisplay: {f}", .{Value.from(compact_display).fmtPretty(terminal.mode)});
    }
    try terminal.writer.print(", signDisplay: {f}, roundingIncrement: {f}, roundingMode: {f}, " ++
        "roundingPriority: {f}, trailingZeroDisplay: {f}", .{
        Value.from(resolved_options.sign_display).fmtPretty(terminal.mode),
        Value.from(resolved_options.rounding_increment).fmtPretty(terminal.mode),
        Value.from(resolved_options.rounding_mode).fmtPretty(terminal.mode),
        Value.from(resolved_options.rounding_priority).fmtPretty(terminal.mode),
        Value.from(resolved_options.trailing_zero_display).fmtPretty(terminal.mode),
    });
    try terminal.setColor(.white);
    try terminal.writer.writeAll(")");
    try terminal.setColor(.reset);
}

fn prettyPrintIntlPluralRules(
    intl_plural_rules: *const builtins.intl.PluralRules,
    terminal: std.Io.Terminal,
) PrettyPrintError!void {
    const locale = intl_plural_rules.fields.locale;

    const resolved_options = intl_plural_rules.fields.resolvedOptions();

    try terminal.setColor(.white);
    try terminal.writer.writeAll("Intl.PluralRules(");
    try terminal.setColor(.reset);
    try terminal.writer.print("{f}, type: {f}, notation: {f}", .{
        Value.from(asciiString(locale.toString(arena.allocator()) catch return)).fmtPretty(terminal.mode),
        Value.from(resolved_options.type).fmtPretty(terminal.mode),
        Value.from(resolved_options.notation).fmtPretty(terminal.mode),
    });
    if (resolved_options.compact_display) |compact_display| {
        try terminal.writer.print(", compactDisplay: {f}", .{
            Value.from(compact_display).fmtPretty(terminal.mode),
        });
    }
    try terminal.writer.print(", minimumIntegerDigits: {f}", .{
        Value.from(resolved_options.minimum_integer_digits).fmtPretty(terminal.mode),
    });
    if (resolved_options.minimum_fraction_digits) |minimum_fraction_digits| {
        try terminal.writer.print(", minimumFractionDigits: {f}", .{Value.from(minimum_fraction_digits).fmtPretty(terminal.mode)});
    }
    if (resolved_options.maximum_fraction_digits) |maximum_fraction_digits| {
        try terminal.writer.print(", maximumFractionDigits: {f}", .{Value.from(maximum_fraction_digits).fmtPretty(terminal.mode)});
    }
    if (resolved_options.minimum_significant_digits) |minimum_significant_digits| {
        try terminal.writer.print(", minimumSignificantDigits: {f}", .{Value.from(minimum_significant_digits).fmtPretty(terminal.mode)});
    }
    if (resolved_options.maximum_significant_digits) |maximum_significant_digits| {
        try terminal.writer.print(", maximumSignificantDigits: {f}", .{Value.from(maximum_significant_digits).fmtPretty(terminal.mode)});
    }
    try terminal.writer.print(", roundingIncrement: {f}, roundingMode: {f}, " ++
        "roundingPriority: {f}, trailingZeroDisplay: {f}", .{
        Value.from(resolved_options.rounding_increment).fmtPretty(terminal.mode),
        Value.from(resolved_options.rounding_mode).fmtPretty(terminal.mode),
        Value.from(resolved_options.rounding_priority).fmtPretty(terminal.mode),
        Value.from(resolved_options.trailing_zero_display).fmtPretty(terminal.mode),
    });
    try terminal.setColor(.white);
    try terminal.writer.writeAll(")");
    try terminal.setColor(.reset);
}

fn prettyPrintIntlRelativeTimeFormat(
    intl_relative_time_format: *const builtins.intl.RelativeTimeFormat,
    terminal: std.Io.Terminal,
) PrettyPrintError!void {
    const locale = intl_relative_time_format.fields.locale;

    const resolved_options = intl_relative_time_format.fields.resolvedOptions();

    try terminal.setColor(.white);
    try terminal.writer.writeAll("Intl.RelativeTimeFormat(");
    try terminal.setColor(.reset);
    try terminal.writer.print("{f}, style: {f}, numeric: {f}, numberingSystem: {f}", .{
        Value.from(asciiString(locale.toString(arena.allocator()) catch return)).fmtPretty(terminal.mode),
        Value.from(resolved_options.style).fmtPretty(terminal.mode),
        Value.from(resolved_options.numeric).fmtPretty(terminal.mode),
        Value.from(resolved_options.numbering_system).fmtPretty(terminal.mode),
    });
    try terminal.setColor(.white);
    try terminal.writer.writeAll(")");
    try terminal.setColor(.reset);
}

fn prettyPrintIntlSegmenter(
    intl_segmenter: *const builtins.intl.Segmenter,
    terminal: std.Io.Terminal,
) PrettyPrintError!void {
    const locale = intl_segmenter.fields.locale;

    const resolved_options = intl_segmenter.fields.resolvedOptions();

    try terminal.setColor(.white);
    try terminal.writer.writeAll("Intl.Segmenter(");
    try terminal.setColor(.reset);
    try terminal.writer.print("{f}, granularity: {f}", .{
        Value.from(asciiString(locale.toString(arena.allocator()) catch return)).fmtPretty(terminal.mode),
        Value.from(resolved_options.granularity).fmtPretty(terminal.mode),
    });
    try terminal.setColor(.white);
    try terminal.writer.writeAll(")");
    try terminal.setColor(.reset);
}

fn prettyPrintTemporalDuration(
    temporal_duration: *const builtins.temporal.Duration,
    terminal: std.Io.Terminal,
) PrettyPrintError!void {
    const years = temporal_rs.c.temporal_rs_Duration_years(temporal_duration.fields.inner);
    const months = temporal_rs.c.temporal_rs_Duration_months(temporal_duration.fields.inner);
    const weeks = temporal_rs.c.temporal_rs_Duration_weeks(temporal_duration.fields.inner);
    const days = temporal_rs.c.temporal_rs_Duration_days(temporal_duration.fields.inner);
    const hours = temporal_rs.c.temporal_rs_Duration_hours(temporal_duration.fields.inner);
    const minutes = temporal_rs.c.temporal_rs_Duration_minutes(temporal_duration.fields.inner);
    const seconds = temporal_rs.c.temporal_rs_Duration_seconds(temporal_duration.fields.inner);
    const milliseconds = temporal_rs.c.temporal_rs_Duration_milliseconds(temporal_duration.fields.inner);
    const microseconds = temporal_rs.c.temporal_rs_Duration_microseconds(temporal_duration.fields.inner);
    const nanoseconds = temporal_rs.c.temporal_rs_Duration_nanoseconds(temporal_duration.fields.inner);

    try terminal.setColor(.white);
    try terminal.writer.writeAll("Temporal.Duration(");
    try terminal.setColor(.reset);
    try terminal.writer.print("{f}, {f}, {f}, {f}, {f}, {f}, {f}, {f}, {f}, {f}", .{
        Value.from(@as(f64, @floatFromInt(years))).fmtPretty(terminal.mode),
        Value.from(@as(f64, @floatFromInt(months))).fmtPretty(terminal.mode),
        Value.from(@as(f64, @floatFromInt(weeks))).fmtPretty(terminal.mode),
        Value.from(@as(f64, @floatFromInt(days))).fmtPretty(terminal.mode),
        Value.from(@as(f64, @floatFromInt(hours))).fmtPretty(terminal.mode),
        Value.from(@as(f64, @floatFromInt(minutes))).fmtPretty(terminal.mode),
        Value.from(@as(f64, @floatFromInt(seconds))).fmtPretty(terminal.mode),
        Value.from(@as(f64, @floatFromInt(milliseconds))).fmtPretty(terminal.mode),
        Value.from(microseconds).fmtPretty(terminal.mode),
        Value.from(nanoseconds).fmtPretty(terminal.mode),
    });
    try terminal.setColor(.white);
    try terminal.writer.writeAll(")");
    try terminal.setColor(.reset);
}

fn prettyPrintTemporalInstant(
    temporal_instant: *const builtins.temporal.Instant,
    terminal: std.Io.Terminal,
) PrettyPrintError!void {
    const epoch_nanoseconds = temporal_rs.fromI128Nanoseconds(
        temporal_rs.c.temporal_rs_Instant_epoch_nanoseconds(temporal_instant.fields.inner),
    );

    try terminal.setColor(.white);
    try terminal.writer.writeAll("Temporal.Instant(");
    try terminal.setColor(.reset);
    try terminal.writer.print("{f}", .{
        Value.from(bigInt(epoch_nanoseconds)).fmtPretty(terminal.mode),
    });
    try terminal.setColor(.white);
    try terminal.writer.writeAll(")");
    try terminal.setColor(.reset);
}

fn prettyPrintTemporalPlainDate(
    temporal_plain_date: *const builtins.temporal.PlainDate,
    terminal: std.Io.Terminal,
) PrettyPrintError!void {
    const year = temporal_rs.c.temporal_rs_PlainDate_year(temporal_plain_date.fields.inner);
    const month = temporal_rs.c.temporal_rs_PlainDate_month(temporal_plain_date.fields.inner);
    const day = temporal_rs.c.temporal_rs_PlainDate_day(temporal_plain_date.fields.inner);
    const calendar = temporal_rs.c.temporal_rs_PlainDate_calendar(temporal_plain_date.fields.inner);
    const calendar_id = temporal_rs.fromDiplomatStringView(temporal_rs.c.temporal_rs_Calendar_identifier(calendar));

    try terminal.setColor(.white);
    try terminal.writer.writeAll("Temporal.PlainDate(");
    try terminal.setColor(.reset);
    try terminal.writer.print("{f}, {f}, {f}, {f}", .{
        Value.from(year).fmtPretty(terminal.mode),
        Value.from(month).fmtPretty(terminal.mode),
        Value.from(day).fmtPretty(terminal.mode),
        Value.from(asciiString(calendar_id)).fmtPretty(terminal.mode),
    });
    try terminal.setColor(.white);
    try terminal.writer.writeAll(")");
    try terminal.setColor(.reset);
}

fn prettyPrintTemporalPlainDateTime(
    temporal_plain_date_time: *const builtins.temporal.PlainDateTime,
    terminal: std.Io.Terminal,
) PrettyPrintError!void {
    const year = temporal_rs.c.temporal_rs_PlainDateTime_year(temporal_plain_date_time.fields.inner);
    const month = temporal_rs.c.temporal_rs_PlainDateTime_month(temporal_plain_date_time.fields.inner);
    const day = temporal_rs.c.temporal_rs_PlainDateTime_day(temporal_plain_date_time.fields.inner);
    const hour = temporal_rs.c.temporal_rs_PlainDateTime_hour(temporal_plain_date_time.fields.inner);
    const minute = temporal_rs.c.temporal_rs_PlainDateTime_minute(temporal_plain_date_time.fields.inner);
    const second = temporal_rs.c.temporal_rs_PlainDateTime_second(temporal_plain_date_time.fields.inner);
    const millisecond = temporal_rs.c.temporal_rs_PlainDateTime_millisecond(temporal_plain_date_time.fields.inner);
    const microsecond = temporal_rs.c.temporal_rs_PlainDateTime_microsecond(temporal_plain_date_time.fields.inner);
    const nanosecond = temporal_rs.c.temporal_rs_PlainDateTime_nanosecond(temporal_plain_date_time.fields.inner);
    const calendar = temporal_rs.c.temporal_rs_PlainDateTime_calendar(temporal_plain_date_time.fields.inner);
    const calendar_id = temporal_rs.fromDiplomatStringView(temporal_rs.c.temporal_rs_Calendar_identifier(calendar));

    try terminal.setColor(.white);
    try terminal.writer.writeAll("Temporal.PlainDateTime(");
    try terminal.setColor(.reset);
    try terminal.writer.print("{f}, {f}, {f}, {f}, {f}, {f}, {f}, {f}, {f}, {f}", .{
        Value.from(year).fmtPretty(terminal.mode),
        Value.from(month).fmtPretty(terminal.mode),
        Value.from(day).fmtPretty(terminal.mode),
        Value.from(hour).fmtPretty(terminal.mode),
        Value.from(minute).fmtPretty(terminal.mode),
        Value.from(second).fmtPretty(terminal.mode),
        Value.from(millisecond).fmtPretty(terminal.mode),
        Value.from(microsecond).fmtPretty(terminal.mode),
        Value.from(nanosecond).fmtPretty(terminal.mode),
        Value.from(asciiString(calendar_id)).fmtPretty(terminal.mode),
    });
    try terminal.setColor(.white);
    try terminal.writer.writeAll(")");
    try terminal.setColor(.reset);
}

fn prettyPrintTemporalPlainMonthDay(
    temporal_plain_month_day: *const builtins.temporal.PlainMonthDay,
    terminal: std.Io.Terminal,
) PrettyPrintError!void {
    var write = temporal_rs.DiplomatWrite.init(arena.allocator());
    temporal_rs.c.temporal_rs_PlainMonthDay_month_code(temporal_plain_month_day.fields.inner, &write.inner);
    const month_code = write.toOwnedSlice() catch return;
    const day = temporal_rs.c.temporal_rs_PlainMonthDay_day(temporal_plain_month_day.fields.inner);
    const calendar = temporal_rs.c.temporal_rs_PlainMonthDay_calendar(temporal_plain_month_day.fields.inner);
    const calendar_id = temporal_rs.fromDiplomatStringView(temporal_rs.c.temporal_rs_Calendar_identifier(calendar));

    try terminal.setColor(.white);
    try terminal.writer.writeAll("Temporal.PlainMonthDay(");
    try terminal.setColor(.reset);
    try terminal.writer.print("{f}, {f}, {f}", .{
        Value.from(asciiString(month_code)).fmtPretty(terminal.mode),
        Value.from(day).fmtPretty(terminal.mode),
        Value.from(asciiString(calendar_id)).fmtPretty(terminal.mode),
    });
    try terminal.setColor(.white);
    try terminal.writer.writeAll(")");
    try terminal.setColor(.reset);
}

fn prettyPrintTemporalPlainTime(
    temporal_plain_time: *const builtins.temporal.PlainTime,
    terminal: std.Io.Terminal,
) PrettyPrintError!void {
    const hour = temporal_rs.c.temporal_rs_PlainTime_hour(temporal_plain_time.fields.inner);
    const minute = temporal_rs.c.temporal_rs_PlainTime_minute(temporal_plain_time.fields.inner);
    const second = temporal_rs.c.temporal_rs_PlainTime_second(temporal_plain_time.fields.inner);
    const millisecond = temporal_rs.c.temporal_rs_PlainTime_millisecond(temporal_plain_time.fields.inner);
    const microsecond = temporal_rs.c.temporal_rs_PlainTime_microsecond(temporal_plain_time.fields.inner);
    const nanosecond = temporal_rs.c.temporal_rs_PlainTime_nanosecond(temporal_plain_time.fields.inner);

    try terminal.setColor(.white);
    try terminal.writer.writeAll("Temporal.PlainTime(");
    try terminal.setColor(.reset);
    try terminal.writer.print("{f}, {f}, {f}, {f}, {f}, {f}", .{
        Value.from(hour).fmtPretty(terminal.mode),
        Value.from(minute).fmtPretty(terminal.mode),
        Value.from(second).fmtPretty(terminal.mode),
        Value.from(millisecond).fmtPretty(terminal.mode),
        Value.from(microsecond).fmtPretty(terminal.mode),
        Value.from(nanosecond).fmtPretty(terminal.mode),
    });
    try terminal.setColor(.white);
    try terminal.writer.writeAll(")");
    try terminal.setColor(.reset);
}

fn prettyPrintTemporalPlainYearMonth(
    temporal_plain_year_month: *const builtins.temporal.PlainYearMonth,
    terminal: std.Io.Terminal,
) PrettyPrintError!void {
    const year = temporal_rs.c.temporal_rs_PlainYearMonth_year(temporal_plain_year_month.fields.inner);
    const month = temporal_rs.c.temporal_rs_PlainYearMonth_month(temporal_plain_year_month.fields.inner);
    const calendar = temporal_rs.c.temporal_rs_PlainYearMonth_calendar(temporal_plain_year_month.fields.inner);
    const calendar_id = temporal_rs.fromDiplomatStringView(temporal_rs.c.temporal_rs_Calendar_identifier(calendar));

    try terminal.setColor(.white);
    try terminal.writer.writeAll("Temporal.PlainYearMonth(");
    try terminal.setColor(.reset);
    try terminal.writer.print("{f}, {f}, {f}", .{
        Value.from(year).fmtPretty(terminal.mode),
        Value.from(month).fmtPretty(terminal.mode),
        Value.from(asciiString(calendar_id)).fmtPretty(terminal.mode),
    });
    try terminal.setColor(.white);
    try terminal.writer.writeAll(")");
    try terminal.setColor(.reset);
}

fn prettyPrintTemporalZonedDateTime(
    temporal_zoned_date_time: *const builtins.temporal.ZonedDateTime,
    terminal: std.Io.Terminal,
) PrettyPrintError!void {
    const epoch_nanoseconds = temporal_rs.fromI128Nanoseconds(
        temporal_rs.c.temporal_rs_ZonedDateTime_epoch_nanoseconds(temporal_zoned_date_time.fields.inner),
    );
    const time_zone = temporal_rs.c.temporal_rs_ZonedDateTime_timezone(temporal_zoned_date_time.fields.inner);
    var write = temporal_rs.DiplomatWrite.init(arena.allocator());
    temporal_rs.c.temporal_rs_TimeZone_identifier(time_zone, &write.inner);
    const time_zone_id = write.toOwnedSlice() catch return;
    const calendar = temporal_rs.c.temporal_rs_ZonedDateTime_calendar(temporal_zoned_date_time.fields.inner);
    const calendar_id = temporal_rs.fromDiplomatStringView(temporal_rs.c.temporal_rs_Calendar_identifier(calendar));

    try terminal.setColor(.white);
    try terminal.writer.writeAll("Temporal.ZonedDateTime(");
    try terminal.setColor(.reset);
    try terminal.writer.print("{f}, {f}, {f}", .{
        Value.from(bigInt(epoch_nanoseconds)).fmtPretty(terminal.mode),
        Value.from(asciiString(time_zone_id)).fmtPretty(terminal.mode),
        Value.from(asciiString(calendar_id)).fmtPretty(terminal.mode),
    });
    try terminal.setColor(.white);
    try terminal.writer.writeAll(")");
    try terminal.setColor(.reset);
}

fn prettyPrintPrimitiveWrapper(
    object: anytype,
    terminal: std.Io.Terminal,
) PrettyPrintError!void {
    const T = std.meta.Child(@TypeOf(object));
    const name, const value = switch (T) {
        builtins.BigInt => .{ "BigInt", Value.from(object.fields.big_int_data) },
        builtins.Boolean => .{ "Boolean", Value.from(object.fields.boolean_data) },
        builtins.Number => .{ "Number", Value.from(object.fields.number_data) },
        builtins.String => .{ "String", Value.from(object.fields.string_data) },
        builtins.Symbol => .{ "Symbol", Value.from(object.fields.symbol_data) },
        else => @panic("Unhandled object type in prettyPrintPrimitiveWrapper()"),
    };

    try terminal.setColor(.white);
    try terminal.writer.writeAll(name);
    try terminal.writer.writeAll("(");
    try terminal.setColor(.reset);
    try terminal.writer.print("{f}", .{value.fmtPretty(terminal.mode)});
    try terminal.setColor(.white);
    try terminal.writer.writeAll(")");
    try terminal.setColor(.reset);
}

fn prettyPrintFunction(
    object: *const Object,
    terminal: std.Io.Terminal,
) PrettyPrintError!void {
    var target = object;
    while (target.cast(builtins.BoundFunction)) |func| : (target = func.fields.bound_target_function) {}

    const name = if (target.cast(builtins.ECMAScriptFunction)) |func|
        func.fields.initial_name.?
    else if (target.cast(builtins.BuiltinFunction)) |func|
        func.fields.initial_name orelse String.empty
    else
        unreachable;

    try terminal.setColor(.bold);
    try terminal.setColor(.blue);
    if (object.is(builtins.BoundFunction)) {
        try terminal.writer.writeAll("bound ");
    }
    if (target.cast(builtins.ECMAScriptFunction)) |ecmascript_function| {
        const function_body = ecmascript_function.fields.ecmascript_code;
        switch (function_body.type) {
            .normal => try terminal.writer.writeAll("fn "),
            .generator => try terminal.writer.writeAll("fn* "),
            .async => try terminal.writer.writeAll("async fn "),
            .async_generator => try terminal.writer.writeAll("async fn* "),
        }
    } else {
        try terminal.writer.writeAll("fn ");
    }
    try terminal.setColor(.reset);
    if (!name.isEmpty()) {
        try terminal.writer.print("{f}", .{name.fmtRaw()});
    } else {
        try terminal.setColor(.dim);
        try terminal.writer.writeAll("<anonymous>");
        try terminal.setColor(.reset);
    }
}

fn prettyPrintObject(
    object: *Object,
    terminal: std.Io.Terminal,
) PrettyPrintError!void {
    const property_keys = ordinaryOwnPropertyKeys(arena.allocator(), object) catch return;

    try terminal.setColor(.white);
    try terminal.writer.writeAll("{");
    try terminal.setColor(.reset);

    var printed_properties: usize = 0;
    for (property_keys) |property_key| {
        const property_desc = (object.getPropertyCreateLazyIfNeeded(property_key) catch return).?;
        if (!property_desc.attributes.enumerable) continue;

        if (printed_properties > 0) try terminal.writer.writeAll(",");
        printed_properties += 1;
        try terminal.writer.writeAll(" ");

        switch (property_key) {
            .string => |string| {
                try terminal.writer.writeAll("\"");
                try terminal.setColor(.bold);
                try terminal.writer.print("{f}", .{string.fmtEscaped()});
                try terminal.setColor(.reset);
                try terminal.writer.writeAll("\"");
            },
            .symbol => |symbol| {
                try terminal.writer.writeAll("[");
                try terminal.setColor(.bold);
                try terminal.writer.print("{f}", .{symbol});
                try terminal.setColor(.reset);
                try terminal.writer.writeAll("]");
            },
            .integer_index => |integer_index| {
                try terminal.writer.writeAll("\"");
                try terminal.setColor(.bold);
                try terminal.writer.print("{d}", .{integer_index});
                try terminal.setColor(.reset);
                try terminal.writer.writeAll("\"");
            },
        }
        try terminal.writer.writeAll(": ");

        switch (property_desc.value_or_accessor) {
            .value => |value| {
                try terminal.writer.print("{f}", .{value.fmtPretty(terminal.mode)});
            },
            .accessor => {
                try terminal.setColor(.dim);
                try terminal.writer.writeAll("<accessor>");
                try terminal.setColor(.reset);
            },
        }
    }
    if (printed_properties > 0) try terminal.writer.writeAll(" ");

    try terminal.setColor(.white);
    try terminal.writer.writeAll("}");
    try terminal.setColor(.reset);
}

pub fn prettyPrintValue(
    value: Value,
    terminal: std.Io.Terminal,
) PrettyPrintError!void {
    const print_in_progress = state.print_in_progress;
    state.print_in_progress = true;
    defer if (!print_in_progress) {
        state.seen_objects.clearAndFree(arena.allocator());
        state.print_in_progress = false;
        _ = arena.reset(.retain_capacity);
    };

    if (value.isObject()) {
        const object = value.asObject();
        if (state.seen_objects.get(object)) |i| {
            try terminal.setColor(.dim);
            try terminal.writer.print("<ref #{d}>", .{i});
            try terminal.setColor(.reset);
            return;
        }
        state.seen_objects.putNoClobber(arena.allocator(), object, state.seen_objects.count()) catch return;

        inline for (.{
            .{ builtins.Array, prettyPrintArray },
            .{ builtins.ArrayBuffer, prettyPrintArrayBuffer },
            .{ builtins.ArrayIterator, prettyPrintArrayIterator },
            .{ builtins.AsyncDisposableStack, prettyPrintAsyncDisposableStack },
            .{ builtins.AsyncGenerator, prettyPrintAsyncGenerator },
            .{ builtins.BigInt, prettyPrintPrimitiveWrapper },
            .{ builtins.Boolean, prettyPrintPrimitiveWrapper },
            .{ builtins.DataView, prettyPrintDataView },
            .{ builtins.Date, prettyPrintDate },
            .{ builtins.DisposableStack, prettyPrintDisposableStack },
            .{ builtins.Error, prettyPrintError },
            .{ builtins.FinalizationRegistry, prettyPrintFinalizationRegistry },
            .{ builtins.Generator, prettyPrintGenerator },
            .{ builtins.Iterator, prettyPrintIterator },
            .{ builtins.IteratorHelper, prettyPrintIteratorHelper },
            .{ builtins.Map, prettyPrintMap },
            .{ builtins.MapIterator, prettyPrintMapIterator },
            .{ builtins.Number, prettyPrintPrimitiveWrapper },
            .{ builtins.Promise, prettyPrintPromise },
            .{ builtins.Proxy, prettyPrintProxy },
            .{ builtins.RegExp, prettyPrintRegExp },
            .{ builtins.RegExpStringIterator, prettyPrintRegExpStringIterator },
            .{ builtins.Set, prettyPrintSet },
            .{ builtins.SetIterator, prettyPrintSetIterator },
            .{ builtins.String, prettyPrintPrimitiveWrapper },
            .{ builtins.StringIterator, prettyPrintStringIterator },
            .{ builtins.Symbol, prettyPrintPrimitiveWrapper },
            .{ builtins.TypedArray, prettyPrintTypedArray },
            .{ builtins.WeakMap, prettyPrintWeakMap },
            .{ builtins.WeakRef, prettyPrintWeakRef },
            .{ builtins.WeakSet, prettyPrintWeakSet },
            .{ builtins.WrapForValidIterator, prettyPrintWrapForValidIterator },
        } ++ (if (build_options.enable_intl) .{
            .{ builtins.intl.Collator, prettyPrintIntlCollator },
            .{ builtins.intl.DateTimeFormat, prettyPrintIntlDateTimeFormat },
            .{ builtins.intl.DisplayNames, prettyPrintIntlDisplayNames },
            .{ builtins.intl.DurationFormat, prettyPrintIntlDurationFormat },
            .{ builtins.intl.ListFormat, prettyPrintIntlListFormat },
            .{ builtins.intl.Locale, prettyPrintIntlLocale },
            .{ builtins.intl.NumberFormat, prettyPrintIntlNumberFormat },
            .{ builtins.intl.PluralRules, prettyPrintIntlPluralRules },
            .{ builtins.intl.RelativeTimeFormat, prettyPrintIntlRelativeTimeFormat },
            .{ builtins.intl.Segmenter, prettyPrintIntlSegmenter },
        } else .{}) ++ (if (build_options.enable_temporal) .{
            .{ builtins.temporal.Duration, prettyPrintTemporalDuration },
            .{ builtins.temporal.Instant, prettyPrintTemporalInstant },
            .{ builtins.temporal.PlainDate, prettyPrintTemporalPlainDate },
            .{ builtins.temporal.PlainDateTime, prettyPrintTemporalPlainDateTime },
            .{ builtins.temporal.PlainMonthDay, prettyPrintTemporalPlainMonthDay },
            .{ builtins.temporal.PlainTime, prettyPrintTemporalPlainTime },
            .{ builtins.temporal.PlainYearMonth, prettyPrintTemporalPlainYearMonth },
            .{ builtins.temporal.ZonedDateTime, prettyPrintTemporalZonedDateTime },
        } else .{})) |entry| {
            const T, const prettyPrintFn = entry;
            if (object.cast(T)) |ptr| return prettyPrintFn(ptr, terminal);
        }
        // NOTE: This needs to go before pretty-printing functions as it has [[Call]] but no name.
        if (build_options.enable_annex_b and object.isHTMLDDA()) {
            // Keep colors in sync with undefined and null below :^)
            try terminal.setColor(.bright_black);
            try terminal.writer.writeAll("[[");
            try terminal.setColor(.yellow);
            try terminal.writer.writeAll("IsHTMLDDA");
            try terminal.setColor(.bright_black);
            try terminal.writer.writeAll("]]");
            try terminal.setColor(.reset);
            return;
        }
        if (object.internalMethods().call != null)
            return prettyPrintFunction(object, terminal);
        return prettyPrintObject(object, terminal);
    }

    const color: std.Io.Terminal.Color = switch (value.type()) {
        .undefined => .bright_black,
        .null => .yellow,
        .boolean => .blue,
        .string => .green,
        .symbol => .cyan,
        .number => .magenta,
        .big_int => .magenta,
        .object => unreachable,
    };
    try terminal.setColor(color);
    try terminal.writer.print("{f}", .{value});
    try terminal.setColor(.reset);
}

pub fn prettyPrintException(
    agent: *Agent,
    exception: Agent.Exception,
    terminal: std.Io.Terminal,
) PrettyPrintError!void {
    const old_exception = agent.exception;
    defer agent.exception = old_exception;
    if (exception.value.toString(agent)) |string| {
        try terminal.setColor(.red);
        try terminal.writer.print("{f}", .{string.fmtRaw()});
        try terminal.setColor(.reset);
    } else |_| {
        try terminal.writer.print("{f}", .{exception.value.fmtPretty(terminal.mode)});
    }
    var it = std.mem.reverseIterator(exception.stack_trace);
    while (it.next()) |stack_frame| {
        try terminal.writer.writeAll("\n  at ");
        switch (stack_frame.origin) {
            .function => |function| {
                try terminal.writer.print("{f}", .{Value.from(function).fmtPretty(terminal.mode)});
            },
            .eval => {
                // Keep this in sync with prettyPrintFunction()
                try terminal.setColor(.bold);
                try terminal.setColor(.blue);
                try terminal.writer.writeAll("fn");
                try terminal.setColor(.reset);
                try terminal.writer.writeAll(" eval");
            },
            // These should never be recorded
            .realm, .script, .module => unreachable,
        }
    }
}
