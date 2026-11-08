//! Fast path implementations for `Array.prototype` methods.

const std = @import("std");

const builtins = @import("../builtins.zig");
const execution = @import("../execution.zig");
const types = @import("../types.zig");

const Agent = execution.Agent;
const Object = types.Object;
const PropertyKey = types.PropertyKey;
const Value = types.Value;
const isStrictlyEqual = types.isStrictlyEqual;
const sameValueZero = types.sameValueZero;

const FindViaPredicateDirection = builtins.array.FindViaPredicateDirection;
const FindViaPredicateResult = builtins.array.FindViaPredicateResult;

fn findLastScalarPos(comptime T: type, slice: []const T, start_index: usize, value: T) ?usize {
    var i: usize = start_index;
    while (true) : (i -= 1) {
        if (slice[i] == value) return i;
        if (i == 0) return null;
    }
}

fn toI32(value: Value) ?i32 {
    if (!value.isNumber()) return null;
    switch (value.asNumber()) {
        .i32 => |x| return x,
        .f64 => |x| {
            // This function coerces -0 to 0 which matches SameValueZero semantics.
            // It's the caller's responsibility to check whether the value can actually be stored.
            if (!std.math.isFinite(x) or
                x < std.math.minInt(i32) or
                x > std.math.maxInt(i32) or
                @trunc(x) != x) return null;
            return @intFromFloat(x);
        },
    }
}

fn toF64(value: Value) ?f64 {
    if (!value.isNumber()) return null;
    return value.asNumber().asFloat();
}

fn cb(
    agent: *Agent,
    obj: *Object,
    callback: *Object,
    this_arg: Value,
    value: Value,
    index: usize,
) Agent.Error!void {
    std.debug.assert(callback.internalMethods().call != null);
    _ = try callback.call(
        agent,
        this_arg,
        &.{ value, Value.from(@as(u53, @intCast(index))), Value.from(obj) },
    );
}

fn cbToBool(
    agent: *Agent,
    obj: *Object,
    callback: *Object,
    this_arg: Value,
    value: Value,
    index: usize,
) Agent.Error!bool {
    std.debug.assert(callback.internalMethods().call != null);
    const result = try callback.call(
        agent,
        this_arg,
        &.{ value, Value.from(@as(u53, @intCast(index))), Value.from(obj) },
    );
    return result.toBoolean();
}

/// Fast path for `Array.prototype.every()`.
///
/// Only applicable to objects that meet the following requirements:
/// - Dense indexed property storage with at least `length` items
/// - Ordinary internal methods: `[[HasProperty]]`, `[[Get]]`
///
/// If the indexed property storage is modified in a way that changes its type or size iteration
/// will continue on the slow path from the returned index.
pub fn every(
    agent: *Agent,
    obj: *Object,
    length: u53,
    callback: *Object,
    this_arg: Value,
) Agent.Error!?union(enum) {
    done: bool,
    continue_slow: usize,
} {
    const indexed_properties = obj.indexedProperties();
    const has_ordinary_internal_methods = obj.internalMethods().flags.supersetOf(comptime .initMany(&.{
        .ordinary_has_property,
        .ordinary_get,
        // Dependencies of ordinary [[HasProperty]] and [[Get]]
        .ordinary_get_own_property,
        .ordinary_get_prototype_of,
    }));
    if (!has_ordinary_internal_methods or
        indexed_properties.count() < length) return null;

    const end_index: usize = @intCast(length);
    switch (indexed_properties.storage) {
        .none => {},
        .dense_i32 => |*dense_i32| for (0..end_index) |index| {
            const value = Value.from(dense_i32.items[index]);
            if (!try cbToBool(agent, obj, callback, this_arg, value, index)) {
                return .{ .done = false };
            }
            if (indexed_properties.storage != .dense_i32 or
                dense_i32.items.len < end_index)
                return .{ .continue_slow = index + 1 };
        },
        .dense_f64 => |*dense_f64| for (0..end_index) |index| {
            const value = Value.from(dense_f64.items[index]);
            if (!try cbToBool(agent, obj, callback, this_arg, value, index)) {
                return .{ .done = false };
            }
            if (indexed_properties.storage != .dense_f64 or
                dense_f64.items.len < end_index)
                return .{ .continue_slow = index + 1 };
        },
        .dense_value => |*dense_value| for (0..end_index) |index| {
            const value = dense_value.items[index];
            if (!try cbToBool(agent, obj, callback, this_arg, value, index)) {
                return .{ .done = false };
            }
            if (indexed_properties.storage != .dense_value or
                dense_value.items.len < end_index)
                return .{ .continue_slow = index + 1 };
        },
        .sparse_value, .sparse_property_descriptor => return null,
    }
    return .{ .done = true };
}

/// Fast path for `Array.prototype.fill()`.
///
/// Only applicable to objects that meet the following requirements:
/// - Dense indexed property storage after migration for the given `value`
/// - Ordinary internal methods: `[[Set]]`
/// - If the length is non-zero and the object has no property storage yet the object must be
///   extensible
pub fn fill(
    allocator: std.mem.Allocator,
    obj: *Object,
    length: u53,
    start: u53,
    end: u53,
    value: Value,
) std.mem.Allocator.Error!?void {
    const has_ordinary_internal_methods = obj.internalMethods().flags.supersetOf(comptime .initMany(&.{
        .ordinary_set,
        // Dependencies of ordinary [[Set]]
        .ordinary_get_own_property,
        .ordinary_get_prototype_of,
        .ordinary_is_extensible,
        .ordinary_define_own_property,
    }));
    // Arrays have a custom `[[DefineOwnProperty]]` but are eligible for this fast path (obviously).
    if (!has_ordinary_internal_methods and !obj.is(builtins.Array)) return null;
    if (start > std.math.maxInt(Object.IndexedProperties.Index) or
        end > std.math.maxInt(Object.IndexedProperties.Index)) return null;
    if (length > 0 and
        obj.indexedProperties().storage == .none and
        !obj.extensible()) return null;

    if (start >= end) return;
    const start_index: usize = @intCast(start);
    const end_index: usize = @intCast(@min(end, length));

    const indexed_properties = try obj.ensureIndexedProperties(allocator);
    try indexed_properties.migrateStorageIfNeeded(allocator, 0, .{
        .value_or_accessor = .{ .value = value },
        .attributes = .all,
    });
    switch (indexed_properties.storage) {
        .none => unreachable,
        .dense_i32 => |*dense_i32| {
            try dense_i32.ensureTotalCapacity(allocator, end_index);
            if (dense_i32.items.len < end_index) dense_i32.items.len = end_index;
            @memset(dense_i32.items[start_index..end_index], value.__asI32());
        },
        .dense_f64 => |*dense_f64| {
            try dense_f64.ensureTotalCapacity(allocator, end_index);
            if (dense_f64.items.len < end) dense_f64.items.len = end_index;
            @memset(dense_f64.items[start_index..end_index], value.__toF64());
        },
        .dense_value => |*dense_value| {
            try dense_value.ensureTotalCapacity(allocator, end_index);
            if (dense_value.items.len < end) dense_value.items.len = end_index;
            @memset(dense_value.items[start_index..end_index], value);
        },
        .sparse_value, .sparse_property_descriptor => return null,
    }
}

/// Fast path for `findViaPredicate()`, i.e. any of the following:
/// - `Array.prototype.find()`
/// - `Array.prototype.findIndex()`
/// - `Array.prototype.findLast()`
/// - `Array.prototype.findLastIndex()`
///
/// Only applicable to objects that meet the following requirements:
/// - Dense indexed property storage with at least `length` items
/// - Ordinary internal methods: `[[Get]]`
///
/// If the indexed property storage is modified in a way that changes its type or size iteration
/// will continue on the slow path from the returned index.
pub fn findViaPredicate(
    agent: *Agent,
    obj: *Object,
    length: u53,
    comptime direction: FindViaPredicateDirection,
    predicate: *Object,
    this_arg: Value,
) Agent.Error!?union(enum) {
    done: FindViaPredicateResult,
    continue_slow: ?usize,
} {
    const indexed_properties = obj.indexedProperties();
    const has_ordinary_internal_methods = obj.internalMethods().flags.supersetOf(comptime .initMany(&.{
        .ordinary_get,
        // Dependencies of ordinary [[Get]]
        .ordinary_get_own_property,
        .ordinary_get_prototype_of,
    }));
    if (!has_ordinary_internal_methods or
        indexed_properties.count() < length) return null;

    const end_index: usize = @intCast(length);
    switch (indexed_properties.storage) {
        .none => {},
        .dense_i32 => |*dense_i32| switch (direction) {
            .ascending => for (0..end_index) |index| {
                const value = Value.from(dense_i32.items[index]);
                if (try cbToBool(agent, obj, predicate, this_arg, value, index)) {
                    return .{ .done = .{ .index = Value.from(@as(u53, @intCast(index))), .value = value } };
                }
                if (indexed_properties.storage != .dense_i32 or
                    dense_i32.items.len < end_index)
                    return .{ .continue_slow = index + 1 };
            },
            .descending => for (0..end_index) |tmp| {
                const index = end_index - tmp - 1;
                const value = Value.from(dense_i32.items[index]);
                if (try cbToBool(agent, obj, predicate, this_arg, value, index)) {
                    return .{ .done = .{ .index = Value.from(@as(u53, @intCast(index))), .value = value } };
                }
                if (indexed_properties.storage != .dense_i32 or
                    dense_i32.items.len < end_index)
                    return .{ .continue_slow = std.math.sub(usize, index, 1) catch null };
            },
        },
        .dense_f64 => |*dense_f64| switch (direction) {
            .ascending => for (0..end_index) |index| {
                const value = Value.from(dense_f64.items[index]);
                if (try cbToBool(agent, obj, predicate, this_arg, value, index)) {
                    return .{ .done = .{ .index = Value.from(@as(u53, @intCast(index))), .value = value } };
                }
                if (indexed_properties.storage != .dense_f64 or
                    dense_f64.items.len < end_index)
                    return .{ .continue_slow = index + 1 };
            },
            .descending => for (0..end_index) |tmp| {
                const index = end_index - tmp - 1;
                const value = Value.from(dense_f64.items[index]);
                if (try cbToBool(agent, obj, predicate, this_arg, value, index)) {
                    return .{ .done = .{ .index = Value.from(@as(u53, @intCast(index))), .value = value } };
                }
                if (indexed_properties.storage != .dense_f64 or
                    dense_f64.items.len < end_index)
                    return .{ .continue_slow = std.math.sub(usize, index, 1) catch null };
            },
        },
        .dense_value => |*dense_value| switch (direction) {
            .ascending => for (0..end_index) |index| {
                const value = dense_value.items[index];
                if (try cbToBool(agent, obj, predicate, this_arg, value, index)) {
                    return .{ .done = .{ .index = Value.from(@as(u53, @intCast(index))), .value = value } };
                }
                if (indexed_properties.storage != .dense_value or
                    dense_value.items.len < end_index)
                    return .{ .continue_slow = index + 1 };
            },
            .descending => for (0..end_index) |tmp| {
                const index = end_index - tmp - 1;
                const value = dense_value.items[index];
                if (try cbToBool(agent, obj, predicate, this_arg, value, index)) {
                    return .{ .done = .{ .index = Value.from(@as(u53, @intCast(index))), .value = value } };
                }
                if (indexed_properties.storage != .dense_value or
                    dense_value.items.len < end_index)
                    return .{ .continue_slow = std.math.sub(usize, index, 1) catch null };
            },
        },
        .sparse_value, .sparse_property_descriptor => return null,
    }
    return .{ .done = .{ .index = Value.from(-1), .value = .undefined } };
}

/// Fast path for `Array.prototype.forEach()`.
///
/// Only applicable to objects that meet the following requirements:
/// - Dense indexed property storage with at least `length` items
/// - Ordinary internal methods: `[[HasProperty]]`, `[[Get]]`
///
/// If the indexed property storage is modified in a way that changes its type or size iteration
/// will continue on the slow path from the returned index.
pub fn forEach(
    agent: *Agent,
    obj: *Object,
    length: u53,
    callback: *Object,
    this_arg: Value,
) Agent.Error!?union(enum) {
    done,
    continue_slow: usize,
} {
    const indexed_properties = obj.indexedProperties();
    const has_ordinary_internal_methods = obj.internalMethods().flags.supersetOf(comptime .initMany(&.{
        .ordinary_has_property,
        .ordinary_get,
        // Dependencies of ordinary [[HasProperty]] and [[Get]]
        .ordinary_get_own_property,
        .ordinary_get_prototype_of,
    }));
    if (!has_ordinary_internal_methods or
        indexed_properties.count() < length) return null;

    const end_index: usize = @intCast(length);
    switch (indexed_properties.storage) {
        .none => {},
        .dense_i32 => |*dense_i32| for (0..end_index) |index| {
            const value = Value.from(dense_i32.items[index]);
            try cb(agent, obj, callback, this_arg, value, index);
            if (indexed_properties.storage != .dense_i32 or
                dense_i32.items.len < end_index)
                return .{ .continue_slow = index + 1 };
        },
        .dense_f64 => |*dense_f64| for (0..end_index) |index| {
            const value = Value.from(dense_f64.items[index]);
            try cb(agent, obj, callback, this_arg, value, index);
            if (indexed_properties.storage != .dense_f64 or
                dense_f64.items.len < end_index)
                return .{ .continue_slow = index + 1 };
        },
        .dense_value => |*dense_value| for (0..end_index) |index| {
            const value = dense_value.items[index];
            try cb(agent, obj, callback, this_arg, value, index);
            if (indexed_properties.storage != .dense_value or
                dense_value.items.len < end_index)
                return .{ .continue_slow = index + 1 };
        },
        .sparse_value, .sparse_property_descriptor => return null,
    }
    return .done;
}

/// Fast path for `Array.prototype.includes()`.
///
/// Only applicable to objects that meet the following requirements:
/// - Dense indexed property storage with at least `length` items
/// - Ordinary internal methods: `[[Get]]`
pub fn includes(obj: *Object, length: u53, from_index: u53, search_element: Value) ?bool {
    const indexed_properties = obj.indexedProperties();
    const has_ordinary_internal_methods = obj.internalMethods().flags.supersetOf(comptime .initMany(&.{
        .ordinary_get,
        // Dependencies of ordinary [[Get]]
        .ordinary_get_own_property,
        .ordinary_get_prototype_of,
    }));
    if (!has_ordinary_internal_methods or
        indexed_properties.count() < length or
        from_index > std.math.maxInt(Object.IndexedProperties.Index)) return null;

    if (from_index >= length) return false;
    const start_index: usize = @intCast(from_index);
    const end_index: usize = @intCast(length);
    switch (indexed_properties.storage) {
        .none => {},
        .dense_i32 => |dense_i32| {
            const search_element_i32 = toI32(search_element) orelse return false;
            return std.mem.findScalarPos(
                i32,
                dense_i32.items[0..end_index],
                start_index,
                search_element_i32,
            ) != null;
        },
        .dense_f64 => |dense_f64| {
            const search_element_f64 = toF64(search_element) orelse return false;
            // `sameValueZero()` treats NaN as equal to NaN, so this needs special handling.
            if (std.math.isNan(search_element_f64)) {
                for (dense_f64.items[start_index..end_index]) |value| {
                    if (std.math.isNan(value)) return true;
                }
                return false;
            }
            return std.mem.findScalarPos(
                f64,
                dense_f64.items[0..end_index],
                start_index,
                search_element_f64,
            ) != null;
        },
        .dense_value => |dense_value| {
            for (dense_value.items[start_index..end_index]) |value| {
                if (sameValueZero(search_element, value)) return true;
            }
        },
        .sparse_value, .sparse_property_descriptor => return null,
    }
    return false;
}

/// Fast path for `Array.prototype.indexOf()`.
///
/// Only applicable to objects that meet the following requirements:
/// - Dense indexed property storage with at least `length` items
/// - Ordinary internal methods: `[[HasProperty]]`, `[[Get]]`
pub fn indexOf(obj: *Object, length: u53, from_index: u53, search_element: Value) ?Value {
    const indexed_properties = obj.indexedProperties();
    const has_ordinary_internal_methods = obj.internalMethods().flags.supersetOf(comptime .initMany(&.{
        .ordinary_has_property,
        .ordinary_get,
        // Dependencies of ordinary [[HasProperty]] and [[Get]]
        .ordinary_get_own_property,
        .ordinary_get_prototype_of,
    }));
    if (!has_ordinary_internal_methods or
        indexed_properties.count() < length or
        from_index > std.math.maxInt(Object.IndexedProperties.Index)) return null;

    if (from_index >= length) return Value.from(-1);
    const start_index: usize = @intCast(from_index);
    const end_index: usize = @intCast(length);
    switch (indexed_properties.storage) {
        .none => {},
        .dense_i32 => |dense_i32| {
            const search_element_i32 = toI32(search_element) orelse return Value.from(-1);
            if (std.mem.findScalarPos(
                i32,
                dense_i32.items[0..end_index],
                start_index,
                search_element_i32,
            )) |index| {
                return Value.from(@as(u53, @intCast(index)));
            }
        },
        .dense_f64 => |dense_f64| {
            const search_element_f64 = toF64(search_element) orelse return Value.from(-1);
            if (std.mem.findScalarPos(
                f64,
                dense_f64.items[0..end_index],
                start_index,
                search_element_f64,
            )) |index| {
                return Value.from(@as(u53, @intCast(index)));
            }
        },
        .dense_value => |dense_value| {
            for (dense_value.items[start_index..end_index], start_index..) |element, index| {
                if (isStrictlyEqual(search_element, element)) {
                    return Value.from(@as(u53, @intCast(index)));
                }
            }
        },
        .sparse_value, .sparse_property_descriptor => return null,
    }
    return Value.from(-1);
}

/// Fast path for `Array.prototype.lastIndexOf()`.
///
/// Only applicable to objects that meet the following requirements:
/// - Dense indexed property storage with at least `length` items
/// - Ordinary internal methods: `[[HasProperty]]`, `[[Get]]`
pub fn lastIndexOf(obj: *Object, length: u53, from_index: u53, search_element: Value) ?Value {
    const indexed_properties = obj.indexedProperties();
    const has_ordinary_internal_methods = obj.internalMethods().flags.supersetOf(comptime .initMany(&.{
        .ordinary_has_property,
        .ordinary_get,
        // Dependencies of ordinary [[HasProperty]] and [[Get]]
        .ordinary_get_own_property,
        .ordinary_get_prototype_of,
    }));
    if (!has_ordinary_internal_methods or
        indexed_properties.count() < length or
        from_index > std.math.maxInt(Object.IndexedProperties.Index)) return null;

    if (from_index >= length) return Value.from(-1);
    const start_index: usize = @intCast(from_index);
    switch (indexed_properties.storage) {
        .none => {},
        .dense_i32 => |dense_i32| {
            const search_element_i32 = toI32(search_element) orelse return Value.from(-1);
            if (findLastScalarPos(
                i32,
                dense_i32.items,
                start_index,
                search_element_i32,
            )) |index| {
                return Value.from(@as(u53, @intCast(index)));
            }
        },
        .dense_f64 => |dense_f64| {
            const search_element_f64 = toF64(search_element) orelse return Value.from(-1);
            if (findLastScalarPos(
                f64,
                dense_f64.items,
                start_index,
                search_element_f64,
            )) |index| {
                return Value.from(@as(u53, @intCast(index)));
            }
        },
        .dense_value => |dense_value| {
            for (0..start_index + 1) |tmp| {
                const index = start_index - tmp;
                const element = dense_value.items[index];
                if (isStrictlyEqual(search_element, element)) {
                    return Value.from(@as(u53, @intCast(index)));
                }
            }
        },
        .sparse_value, .sparse_property_descriptor => return null,
    }
    return Value.from(-1);
}

/// Fast path for `Array.prototype.reverse()`.
///
/// Only applicable to objects that meet the following requirements:
/// - Dense indexed property storage with exactly `length` items
/// - Ordinary internal methods: `[[HasProperty]]`, `[[Get]]`, `[[Set]]`, `[[Delete]]`
pub fn reverse(obj: *Object, length: u53) ?void {
    const indexed_properties = obj.indexedProperties();
    const has_ordinary_internal_methods = obj.internalMethods().flags.supersetOf(comptime .initMany(&.{
        .ordinary_has_property,
        .ordinary_get,
        .ordinary_set,
        .ordinary_delete,
        // Dependencies of ordinary [[HasProperty]], [[Get]], [[Set]], and [[Delete]]
        .ordinary_get_own_property,
        .ordinary_get_prototype_of,
        .ordinary_is_extensible,
        .ordinary_define_own_property,
    }));
    // Arrays have a custom `[[DefineOwnProperty]]` but are eligible for this fast path (obviously).
    if (!has_ordinary_internal_methods and !obj.is(builtins.Array)) return null;
    if (indexed_properties.count() != length) return null;

    switch (indexed_properties.storage) {
        .none => {},
        .dense_i32 => |dense_i32| {
            std.mem.reverse(i32, dense_i32.items);
        },
        .dense_f64 => |dense_f64| {
            std.mem.reverse(f64, dense_f64.items);
        },
        .dense_value => |dense_value| {
            std.mem.reverse(Value, dense_value.items);
        },
        .sparse_value, .sparse_property_descriptor => return null,
    }
}

/// Fast path for `Array.prototype.pop()`.
///
/// Only applicable to objects that meet the following requirements:
/// - Dense indexed property storage with exactly `length` items
/// - Ordinary internal methods: `[[HasProperty]]`, `[[Get]]`, `[[Set]]`, `[[Delete]]`
pub fn pop(agent: *Agent, obj: *Object, length: u53) Agent.Error!?Value {
    const has_ordinary_internal_methods = obj.internalMethods().flags.supersetOf(comptime .initMany(&.{
        .ordinary_has_property,
        .ordinary_get,
        .ordinary_set,
        .ordinary_delete,
        // Dependencies of ordinary [[HasProperty]], [[Get]], [[Set]], and [[Delete]]
        .ordinary_get_own_property,
        .ordinary_get_prototype_of,
        .ordinary_is_extensible,
        .ordinary_define_own_property,
    }));
    // Arrays have a custom `[[DefineOwnProperty]]` but are eligible for this fast path (obviously).
    if (!has_ordinary_internal_methods and !obj.is(builtins.Array)) return null;
    if (obj.indexedProperties().count() != length) return null;

    if (length == 0) {
        try obj.set(agent, PropertyKey.from("length"), Value.from(0), .throw);
        return .undefined;
    }

    var extra_data = obj.extra_data.?;
    const indexed_properties = &extra_data.indexed_properties;
    const element: Value = switch (indexed_properties.storage) {
        .none => unreachable,
        .dense_i32 => |*dense_i32| Value.from(dense_i32.pop().?),
        .dense_f64 => |*dense_f64| Value.from(dense_f64.pop().?),
        .dense_value => |*dense_value| dense_value.pop().?,
        .sparse_value, .sparse_property_descriptor => return null,
    };
    try obj.set(agent, PropertyKey.from("length"), Value.from(length - 1), .throw);
    return element;
}

/// Fast path for `Array.prototype.push()`.
///
/// Only applicable to objects that meet the following requirements:
/// - Dense indexed property storage with exactly `length` items
/// - Ordinary internal methods: `[[Set]]`
/// - If the object has no property storage yet and `values.len` > 0 it must be extensible
/// - No indexed properties on the prototype chain
pub fn push(agent: *Agent, obj: *Object, length: u53, values: []const Value) Agent.Error!?Value {
    const has_ordinary_internal_methods = obj.internalMethods().flags.supersetOf(comptime .initMany(&.{
        .ordinary_set,
        // Dependencies of ordinary [[Set]]
        .ordinary_get_own_property,
        .ordinary_get_prototype_of,
        .ordinary_is_extensible,
        .ordinary_define_own_property,
    }));
    // Arrays have a custom `[[DefineOwnProperty]]` but are eligible for this fast path as long as
    // their length is writable.
    if (!has_ordinary_internal_methods) {
        const array = obj.cast(builtins.Array) orelse return null;
        if (!array.fields.length_writable) return null;
    }
    if (obj.indexedProperties().count() != length) return null;
    var prototype = obj.prototype();
    while (prototype) |p| : (prototype = p.prototype()) {
        if (p.indexedProperties().count() > 0) return null;
    }

    const new_length = std.math.add(u53, length, @intCast(values.len)) catch return null;
    if (new_length > std.math.maxInt(Object.IndexedProperties.Index)) return null;
    if (values.len > 0 and
        obj.indexedProperties().storage == .none and
        !obj.extensible()) return null;

    const indexed_properties = try obj.ensureIndexedProperties(agent.gc_allocator);
    for (values, 0..) |value, i| {
        try indexed_properties.set(
            agent.gc_allocator,
            @intCast(length + i),
            .{ .value_or_accessor = .{ .value = value }, .attributes = .all },
        );
    }
    try obj.set(agent, PropertyKey.from("length"), Value.from(new_length), .throw);
    return Value.from(new_length);
}

/// Fast path for `Array.prototype.shift()`.
///
/// Only applicable to objects that meet the following requirements:
/// - Dense indexed property storage with exactly `length` items
/// - Ordinary internal methods: `[[HasProperty]]`, `[[Get]]`, `[[Set]]`, `[[Delete]]`
pub fn shift(agent: *Agent, obj: *Object, length: u53) Agent.Error!?Value {
    const has_ordinary_internal_methods = obj.internalMethods().flags.supersetOf(comptime .initMany(&.{
        .ordinary_has_property,
        .ordinary_get,
        .ordinary_set,
        .ordinary_delete,
        // Dependencies of ordinary [[HasProperty]], [[Get]], [[Set]], and [[Delete]]
        .ordinary_get_own_property,
        .ordinary_get_prototype_of,
        .ordinary_is_extensible,
        .ordinary_define_own_property,
    }));
    // Arrays have a custom `[[DefineOwnProperty]]` but are eligible for this fast path (obviously).
    if (!has_ordinary_internal_methods and !obj.is(builtins.Array)) return null;
    if (obj.indexedProperties().count() != length) return null;

    if (length == 0) {
        try obj.set(agent, PropertyKey.from("length"), Value.from(0), .throw);
        return .undefined;
    }

    var extra_data = obj.extra_data.?;
    const indexed_properties = &extra_data.indexed_properties;
    const element: Value = switch (indexed_properties.storage) {
        .none => unreachable,
        .dense_i32 => |*dense_i32| Value.from(dense_i32.orderedRemove(0)),
        .dense_f64 => |*dense_f64| Value.from(dense_f64.orderedRemove(0)),
        .dense_value => |*dense_value| dense_value.orderedRemove(0),
        .sparse_value, .sparse_property_descriptor => return null,
    };
    try obj.set(agent, PropertyKey.from("length"), Value.from(length - 1), .throw);
    return element;
}

/// Fast path for `Array.prototype.some()`.
///
/// Only applicable to objects that meet the following requirements:
/// - Dense indexed property storage with at least `length` items
/// - Ordinary internal methods: `[[HasProperty]]`, `[[Get]]`
///
/// If the indexed property storage is modified in a way that changes its type or size iteration
/// will continue on the slow path from the returned index.
pub fn some(
    agent: *Agent,
    obj: *Object,
    length: u53,
    callback: *Object,
    this_arg: Value,
) Agent.Error!?union(enum) {
    done: bool,
    continue_slow: usize,
} {
    const indexed_properties = obj.indexedProperties();
    const has_ordinary_internal_methods = obj.internalMethods().flags.supersetOf(comptime .initMany(&.{
        .ordinary_has_property,
        .ordinary_get,
        // Dependencies of ordinary [[HasProperty]] and [[Get]]
        .ordinary_get_own_property,
        .ordinary_get_prototype_of,
    }));
    if (!has_ordinary_internal_methods or
        indexed_properties.count() < length) return null;

    const end_index: usize = @intCast(length);
    switch (indexed_properties.storage) {
        .none => {},
        .dense_i32 => |*dense_i32| for (0..end_index) |index| {
            const value = Value.from(dense_i32.items[index]);
            if (try cbToBool(agent, obj, callback, this_arg, value, index)) {
                return .{ .done = true };
            }
            if (indexed_properties.storage != .dense_i32 or
                dense_i32.items.len < end_index)
                return .{ .continue_slow = index + 1 };
        },
        .dense_f64 => |*dense_f64| for (0..end_index) |index| {
            const value = Value.from(dense_f64.items[index]);
            if (try cbToBool(agent, obj, callback, this_arg, value, index)) {
                return .{ .done = true };
            }
            if (indexed_properties.storage != .dense_f64 or
                dense_f64.items.len < end_index)
                return .{ .continue_slow = index + 1 };
        },
        .dense_value => |*dense_value| for (0..end_index) |index| {
            const value = dense_value.items[index];
            if (try cbToBool(agent, obj, callback, this_arg, value, index)) {
                return .{ .done = true };
            }
            if (indexed_properties.storage != .dense_value or
                dense_value.items.len < end_index)
                return .{ .continue_slow = index + 1 };
        },
        .sparse_value, .sparse_property_descriptor => return null,
    }
    return .{ .done = false };
}

/// Fast path for `Array.prototype.unshift()`.
///
/// Only applicable to objects that meet the following requirements:
/// - Dense indexed property storage with exactly `length` items
/// - Ordinary internal methods: `[[Set]]`
/// - If the object has no property storage yet and `values.len` > 0 it must be extensible
/// - No indexed properties on the prototype chain
pub fn unshift(
    agent: *Agent,
    obj: *Object,
    length: u53,
    values: []const Value,
) Agent.Error!?Value {
    const has_ordinary_internal_methods = obj.internalMethods().flags.supersetOf(comptime .initMany(&.{
        .ordinary_set,
        // Dependencies of ordinary [[Set]]
        .ordinary_get_own_property,
        .ordinary_get_prototype_of,
        .ordinary_is_extensible,
        .ordinary_define_own_property,
    }));
    // Arrays have a custom `[[DefineOwnProperty]]` but are eligible for this fast path as long as
    // their length is writable.
    if (!has_ordinary_internal_methods) {
        const array = obj.cast(builtins.Array) orelse return null;
        if (!array.fields.length_writable) return null;
    }
    if (obj.indexedProperties().count() != length) return null;
    var prototype = obj.prototype();
    while (prototype) |p| : (prototype = p.prototype()) {
        if (p.indexedProperties().count() > 0) return null;
    }

    const new_length = std.math.add(u53, length, @intCast(values.len)) catch return null;
    if (new_length > std.math.maxInt(Object.IndexedProperties.Index)) return null;
    if (values.len > 0 and
        obj.indexedProperties().storage == .none and
        !obj.extensible()) return null;

    const indexed_properties = try obj.ensureIndexedProperties(agent.gc_allocator);
    switch (indexed_properties.storage) {
        .none => {
            for (values, 0..) |value, i| {
                try indexed_properties.set(
                    agent.gc_allocator,
                    @intCast(i),
                    .{ .value_or_accessor = .{ .value = value }, .attributes = .all },
                );
            }
        },
        .dense_i32 => |*dense_i32| {
            for (values) |value| {
                // Negative zero requires a storage migration to f64, bail out.
                if (value.isNumber() and value.asNumber().isNegativeZero()) return null;
                _ = toI32(value) orelse return null;
            }
            const slots = try dense_i32.addManyAt(agent.gc_allocator, 0, values.len);
            for (values, slots) |value, *slot| {
                slot.* = toI32(value).?;
            }
        },
        .dense_f64 => |*dense_f64| {
            for (values) |value| {
                _ = toF64(value) orelse return null;
            }
            const slots = try dense_f64.addManyAt(agent.gc_allocator, 0, values.len);
            for (values, slots) |value, *slot| {
                slot.* = toF64(value).?;
            }
        },
        .dense_value => |*dense_value| {
            try dense_value.insertSlice(agent.gc_allocator, 0, values);
        },
        .sparse_value, .sparse_property_descriptor => return null,
    }

    try obj.set(agent, PropertyKey.from("length"), Value.from(new_length), .throw);
    return Value.from(new_length);
}
