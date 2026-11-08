//! 23.2 TypedArray Objects
//! https://tc39.es/ecma262/#sec-typedarray-objects

const std = @import("std");

const builtins = @import("../builtins.zig");
const execution = @import("../execution.zig");
const types = @import("../types.zig");
const utils = @import("../utils.zig");

const Agent = execution.Agent;
const Arguments = types.Arguments;
const ArrayLength = types.ArrayLength;
const AutoArrayLength = types.AutoArrayLength;
const AutoByteLength = types.AutoByteLength;
const BigInt = types.BigInt;
const ByteLength = types.ByteLength;
const ByteOffset = types.ByteOffset;
const DetachedByteLength = types.DetachedByteLength;
const MakeObject = types.MakeObject;
const Object = types.Object;
const OptionalArrayLength = types.OptionalArrayLength;
const Order = builtins.array_buffer.Order;
const PropertyDescriptor = types.PropertyDescriptor;
const PropertyKey = types.PropertyKey;
const Realm = execution.Realm;
const String = types.String;
const Value = types.Value;
const allocateArrayBuffer = builtins.allocateArrayBuffer;
const arrayBufferByteLength = builtins.arrayBufferByteLength;
const cloneArrayBuffer = builtins.cloneArrayBuffer;
const createArrayIterator = builtins.createArrayIterator;
const createBuiltinFunction = builtins.createBuiltinFunction;
const findViaPredicate = builtins.findViaPredicate;
const getIteratorFromMethod = types.getIteratorFromMethod;
const getPrototypeFromConstructor = builtins.getPrototypeFromConstructor;
const getValueFromBuffer = builtins.getValueFromBuffer;
const isDetachedBuffer = builtins.isDetachedBuffer;
const isFixedLengthArrayBuffer = builtins.isFixedLengthArrayBuffer;
const isSharedArrayBuffer = builtins.isSharedArrayBuffer;
const isStrictlyEqual = types.isStrictlyEqual;
const noexcept = utils.noexcept;
const ordinaryDefineOwnProperty = builtins.ordinaryDefineOwnProperty;
const ordinaryDelete = builtins.ordinaryDelete;
const ordinaryGet = builtins.ordinaryGet;
const ordinaryGetOwnProperty = builtins.ordinaryGetOwnProperty;
const ordinaryHasProperty = builtins.ordinaryHasProperty;
const ordinaryObjectCreate = builtins.ordinaryObjectCreate;
const ordinaryPreventExtensions = builtins.ordinaryPreventExtensions;
const ordinarySet = builtins.ordinarySet;
const sameValueZero = types.sameValueZero;
const setValueInBuffer = builtins.setValueInBuffer;
const sortIndexedProperties = builtins.sortIndexedProperties;

// Table 69: The TypedArray Constructors
// https://tc39.es/ecma262/#table-the-typedarray-constructors

pub const int8_array = struct {
    pub const constructor = MakeTypedArrayConstructor(.int8);
    pub const prototype = MakeTypedArrayPrototype(.int8);
};
pub const uint8_array = struct {
    pub const constructor = MakeTypedArrayConstructor(.uint8);
    pub const prototype = MakeTypedArrayPrototype(.uint8);
};
pub const uint8_clamped_array = struct {
    pub const constructor = MakeTypedArrayConstructor(.uint8_clamped);
    pub const prototype = MakeTypedArrayPrototype(.uint8_clamped);
};
pub const int16_array = struct {
    pub const constructor = MakeTypedArrayConstructor(.int16);
    pub const prototype = MakeTypedArrayPrototype(.int16);
};
pub const uint16_array = struct {
    pub const constructor = MakeTypedArrayConstructor(.uint16);
    pub const prototype = MakeTypedArrayPrototype(.uint16);
};
pub const int32_array = struct {
    pub const constructor = MakeTypedArrayConstructor(.int32);
    pub const prototype = MakeTypedArrayPrototype(.int32);
};
pub const uint32_array = struct {
    pub const constructor = MakeTypedArrayConstructor(.uint32);
    pub const prototype = MakeTypedArrayPrototype(.uint32);
};
pub const big_int64_array = struct {
    pub const constructor = MakeTypedArrayConstructor(.bigint64);
    pub const prototype = MakeTypedArrayPrototype(.bigint64);
};
pub const big_uint64_array = struct {
    pub const constructor = MakeTypedArrayConstructor(.biguint64);
    pub const prototype = MakeTypedArrayPrototype(.biguint64);
};
pub const float16_array = struct {
    pub const constructor = MakeTypedArrayConstructor(.float16);
    pub const prototype = MakeTypedArrayPrototype(.float16);
};
pub const float32_array = struct {
    pub const constructor = MakeTypedArrayConstructor(.float32);
    pub const prototype = MakeTypedArrayPrototype(.float32);
};
pub const float64_array = struct {
    pub const constructor = MakeTypedArrayConstructor(.float64);
    pub const prototype = MakeTypedArrayPrototype(.float64);
};

pub const ElementType = enum {
    int8,
    uint8,
    uint8_clamped,
    int16,
    uint16,
    int32,
    uint32,
    bigint64,
    biguint64,
    float16,
    float32,
    float64,

    pub fn @"type"(comptime self: ElementType) type {
        return switch (self) {
            .int8 => i8,
            .uint8 => u8,
            .uint8_clamped => u8,
            .int16 => i16,
            .uint16 => u16,
            .int32 => i32,
            .uint32 => u32,
            .bigint64 => i64,
            .biguint64 => u64,
            .float16 => f16,
            .float32 => f32,
            .float64 => f64,
        };
    }

    pub inline fn elementSize(self: ElementType) u4 {
        return switch (self) {
            .int8 => 1,
            .uint8 => 1,
            .uint8_clamped => 1,
            .int16 => 2,
            .uint16 => 2,
            .int32 => 4,
            .uint32 => 4,
            .bigint64 => 8,
            .biguint64 => 8,
            .float16 => 2,
            .float32 => 4,
            .float64 => 8,
        };
    }

    pub inline fn typedArrayName(self: ElementType) []const u8 {
        return switch (self) {
            .int8 => "Int8Array",
            .uint8 => "Uint8Array",
            .uint8_clamped => "Uint8ClampedArray",
            .int16 => "Int16Array",
            .uint16 => "Uint16Array",
            .int32 => "Int32Array",
            .uint32 => "Uint32Array",
            .bigint64 => "BigInt64Array",
            .biguint64 => "BigUint64Array",
            .float16 => "Float16Array",
            .float32 => "Float32Array",
            .float64 => "Float64Array",
        };
    }

    pub inline fn constructorIntrinsic(self: ElementType) Realm.Intrinsic {
        return switch (self) {
            .int8 => .int8_array,
            .uint8 => .uint8_array,
            .uint8_clamped => .uint8_clamped_array,
            .int16 => .int16_array,
            .uint16 => .uint16_array,
            .int32 => .int32_array,
            .uint32 => .uint32_array,
            .bigint64 => .big_int64_array,
            .biguint64 => .big_uint64_array,
            .float16 => .float16_array,
            .float32 => .float32_array,
            .float64 => .float64_array,
        };
    }

    pub inline fn prototypeIntrinsic(self: ElementType) Realm.Intrinsic {
        return switch (self) {
            .int8 => .int8_array_prototype,
            .uint8 => .uint8_array_prototype,
            .uint8_clamped => .uint8_clamped_array_prototype,
            .int16 => .int16_array_prototype,
            .uint16 => .uint16_array_prototype,
            .int32 => .int32_array_prototype,
            .uint32 => .uint32_array_prototype,
            .bigint64 => .big_int64_array_prototype,
            .biguint64 => .big_uint64_array_prototype,
            .float16 => .float16_array_prototype,
            .float32 => .float32_array_prototype,
            .float64 => .float64_array_prototype,
        };
    }

    pub fn conversationOperation(
        comptime self: ElementType,
    ) fn (Value, *Agent) Agent.Error!self.type() {
        const field_name = switch (self) {
            .int8 => "toInt8",
            .uint8 => "toUint8",
            .uint8_clamped => "toUint8Clamp",
            .int16 => "toInt16",
            .uint16 => "toUint16",
            .int32 => "toInt32",
            .uint32 => "toUint32",
            .bigint64 => "toBigInt64",
            .biguint64 => "toBigUint64",
            else => comptime unreachable,
        };
        return @field(Value, field_name);
    }

    /// 25.1.3.11 IsUnclampedIntegerElementType ( type )
    /// https://tc39.es/ecma262/#sec-isunclampedintegerelementtype
    pub inline fn isUnclampedIntegerElementType(self: ElementType) bool {
        return switch (self) {
            // 1. If type is one of int8, uint8, int16, uint16, int32, or uint32, return true.
            .int8, .uint8, .int16, .uint16, .int32, .uint32 => true,

            // 2. Return false.
            else => false,
        };
    }

    /// 25.1.3.12 IsBigIntElementType ( type )
    /// https://tc39.es/ecma262/#sec-isbigintelementtype
    pub inline fn isBigIntElementType(self: ElementType) bool {
        return switch (self) {
            // 1. If type is either biguint64 or bigint64, return true.
            .biguint64, .bigint64 => true,

            // 2. Return false.
            else => false,
        };
    }

    /// 25.1.3.13 IsNoTearConfiguration ( type, order )
    /// https://tc39.es/ecma262/#sec-isnotearconfiguration
    pub inline fn isNoTearConfiguration(self: ElementType, order: Order) bool {
        // 1. If IsUnclampedIntegerElementType(type) is true, return true.
        if (self.isUnclampedIntegerElementType()) return true;

        // 2. If IsBigIntElementType(type) is true and order is seq-cst, return true.
        if (self.isBigIntElementType() and order == .seq_cst) return true;

        // 3. Return false.
        return false;
    }
};

/// 10.4.5.1 [[PreventExtensions]] ( )
/// https://tc39.es/ecma262/#sec-typedarray-preventextensions
fn preventExtensions(agent: *Agent, obj: *Object) std.mem.Allocator.Error!bool {
    // 1. NOTE: The extensibility-related invariants specified in 6.1.7.3 do not allow this method
    //    to return true when obj can gain (or lose and then regain) properties, which might occur
    //    for properties with integer index names when its underlying buffer is resized.

    // 2. If IsTypedArrayFixedLength(obj) is false, return false.
    if (!isTypedArrayFixedLength(obj.as(TypedArray))) return false;

    // 3. Return OrdinaryPreventExtensions(obj).
    return ordinaryPreventExtensions(agent, obj);
}

/// 10.4.5.2 [[GetOwnProperty]] ( propertyKey )
/// https://tc39.es/ecma262/#sec-typedarray-getownproperty
fn getOwnProperty(
    agent: *Agent,
    obj: *Object,
    property_key: PropertyKey,
) std.mem.Allocator.Error!?PropertyDescriptor {
    // 1. If propertyKey is a String, then
    //     a. Let numericIndex be CanonicalNumericIndexString(propertyKey).
    //     b. If numericIndex is not undefined, then
    if (try property_key.canonicalNumericIndex(agent)) |numeric_index| {
        // i. Let value be TypedArrayGetElement(obj, numericIndex).
        const value = try typedArrayGetElement(agent, obj.as(TypedArray), numeric_index);

        // ii. If value is undefined, return undefined.
        if (value.isUndefined()) return null;

        // iii. Return the PropertyDescriptor { [[Value]]: value, [[Writable]]: true,
        //      [[Enumerable]]: true, [[Configurable]]: true }.
        return .{ .value = value, .writable = true, .enumerable = true, .configurable = true };
    }

    // 2. Return OrdinaryGetOwnProperty(obj, propertyKey).
    return ordinaryGetOwnProperty(obj, property_key);
}

/// 10.4.5.3 [[HasProperty]] ( propertyKey )
/// https://tc39.es/ecma262/#sec-typedarray-hasproperty
fn hasProperty(agent: *Agent, obj: *Object, property_key: PropertyKey) Agent.Error!bool {
    // 1. If propertyKey is a String, then
    //     a. Let numericIndex be CanonicalNumericIndexString(propertyKey).
    //     b. If numericIndex is not undefined, return IsValidIntegerIndex(obj, numericIndex).
    if (try property_key.canonicalNumericIndex(agent)) |numeric_index| {
        return isValidIntegerIndex(obj.as(TypedArray), numeric_index);
    }

    // 2. Return ? OrdinaryHasProperty(obj, propertyKey).
    return ordinaryHasProperty(agent, obj, property_key);
}

/// 10.4.5.4 [[DefineOwnProperty]] ( propertyKey, propertyDesc )
/// https://tc39.es/ecma262/#sec-typedarray-defineownproperty
fn defineOwnProperty(
    agent: *Agent,
    obj: *Object,
    property_key: PropertyKey,
    property_desc: PropertyDescriptor,
) Agent.Error!bool {
    // 1. If propertyKey is a String, then
    //     a. Let numericIndex be CanonicalNumericIndexString(propertyKey).
    //     b. If numericIndex is not undefined, then
    if (try property_key.canonicalNumericIndex(agent)) |numeric_index| {
        // i. If IsValidIntegerIndex(obj, numericIndex) is false, return false.
        if (!isValidIntegerIndex(obj.as(TypedArray), numeric_index)) return false;

        // ii. If propertyDesc has a [[Configurable]] field and propertyDesc.[[Configurable]] is
        //     false, return false.
        if (property_desc.configurable == false) return false;

        // iii. If propertyDesc has an [[Enumerable]] field and propertyDesc.[[Enumerable]] is
        //      false, return false.
        if (property_desc.enumerable == false) return false;

        // iv. If IsAccessorDescriptor(propertyDesc) is true, return false.
        if (property_desc.isAccessorDescriptor()) return false;

        // v. If propertyDesc has a [[Writable]] field and propertyDesc.[[Writable]] is false,
        //    return false.
        if (property_desc.writable == false) return false;

        // vi. If propertyDesc has a [[Value]] field, perform ? TypedArraySetElement(obj,
        //     numericIndex, propertyDesc.[[Value]]).
        if (property_desc.value) |value| {
            try typedArraySetElement(agent, obj.as(TypedArray), numeric_index, value);
        }

        // vii. Return true.
        return true;
    }

    // 2. Return ! OrdinaryDefineOwnProperty(obj, propertyKey, propertyDesc).
    return ordinaryDefineOwnProperty(
        agent,
        obj,
        property_key,
        property_desc,
    ) catch |err| try noexcept(err);
}

/// 10.4.5.5 [[Get]] ( propertyKey, receiver )
/// https://tc39.es/ecma262/#sec-typedarray-get
fn get(
    agent: *Agent,
    obj: *Object,
    property_key: PropertyKey,
    receiver: Value,
) Agent.Error!Value {
    // 1. If propertyKey is a String, then
    //     a. Let numericIndex be CanonicalNumericIndexString(propertyKey).
    //     b. If numericIndex is not undefined, then
    if (try property_key.canonicalNumericIndex(agent)) |numeric_index| {
        // i. Return TypedArrayGetElement(obj, numericIndex).
        return typedArrayGetElement(agent, obj.as(TypedArray), numeric_index);
    }

    // 2. Return ? OrdinaryGet(obj, propertyKey, receiver).
    return ordinaryGet(agent, obj, property_key, receiver);
}

/// 10.4.5.6 [[Set]] ( propertyKey, value, receiver )
/// https://tc39.es/ecma262/#sec-typedarray-set
fn set(
    agent: *Agent,
    obj: *Object,
    property_key: PropertyKey,
    value: Value,
    receiver: Value,
) Agent.Error!bool {
    // 1. If propertyKey is a String, then
    //     a. Let numericIndex be CanonicalNumericIndexString(propertyKey).
    //     b. If numericIndex is not undefined, then
    if (try property_key.canonicalNumericIndex(agent)) |numeric_index| {
        // i. If SameValue(obj, receiver) is true, then
        if (receiver.isObject() and obj == receiver.asObject()) {
            // 1. Perform ? TypedArraySetElement(obj, numericIndex, value).
            try typedArraySetElement(agent, obj.as(TypedArray), numeric_index, value);

            // 2. Return true.
            return true;
        }

        // ii. If IsValidIntegerIndex(obj, numericIndex) is false, return true.
        if (!isValidIntegerIndex(obj.as(TypedArray), numeric_index)) return true;
    }

    // 2. Return ? OrdinarySet(obj, propertyKey, value, receiver).
    return ordinarySet(agent, obj, property_key, value, receiver);
}

/// 10.4.5.7 [[Delete]] ( propertyKey )
/// https://tc39.es/ecma262/#sec-typedarray-delete
fn delete(agent: *Agent, obj: *Object, property_key: PropertyKey) std.mem.Allocator.Error!bool {
    // 1. If propertyKey is a String, then
    //     a. Let numericIndex be CanonicalNumericIndexString(propertyKey).
    //     b. If numericIndex is not undefined, then
    if (try property_key.canonicalNumericIndex(agent)) |numeric_index| {
        // i. If IsValidIntegerIndex(obj, numericIndex) is false, return true.
        // ii. Return false.
        return !isValidIntegerIndex(obj.as(TypedArray), numeric_index);
    }

    // 2. Return ! OrdinaryDelete(obj, propertyKey).
    return ordinaryDelete(agent, obj, property_key) catch |err| try noexcept(err);
}

/// 10.4.5.8 [[OwnPropertyKeys]] ( )
/// https://tc39.es/ecma262/#sec-typedarray-ownpropertykeys
fn ownPropertyKeys(agent: *Agent, obj: *Object) std.mem.Allocator.Error![]PropertyKey {
    // 1. Let taRecord be MakeTypedArrayWithBufferWitnessRecord(obj, seq-cst).
    const ta_record = makeTypedArrayWithBufferWitnessRecord(obj.as(TypedArray), .seq_cst);

    // 2. Let keys be a new empty List.
    var keys = try std.ArrayList(PropertyKey).initCapacity(
        agent.gc_allocator,
        obj.shape.properties.count() + if (!isTypedArrayOutOfBounds(ta_record))
            @as(usize, @intCast(@backingInt(typedArrayLength(ta_record))))
        else
            0,
    );

    // 3. If IsTypedArrayOutOfBounds(taRecord) is false, then
    if (!isTypedArrayOutOfBounds(ta_record)) {
        // a. Let length be TypedArrayLength(taRecord).
        const length = typedArrayLength(ta_record);

        // b. For each integer i such that 0 ≤ i < length, in ascending order, do
        var i: u53 = 0;
        while (i < @backingInt(length)) : (i += 1) {
            // i. Append ! ToString(𝔽(i)) to keys.
            keys.appendAssumeCapacity(PropertyKey.from(i));
        }
    }

    // 4. For each own property key propertyKey of obj such that propertyKey is a String and
    //    propertyKey is not an integer index, in ascending chronological order of property
    //    creation, do
    for (obj.shape.properties.keys()) |property_key| {
        if (property_key == .string) {
            // a. Append propertyKey to keys.
            keys.appendAssumeCapacity(property_key);
        }
    }

    // 5. For each own property key propertyKey of obj such that propertyKey is a Symbol, in
    //    ascending chronological order of property creation, do
    for (obj.shape.properties.keys()) |property_key| {
        if (property_key == .symbol) {
            // a. Append propertyKey to keys.
            keys.appendAssumeCapacity(property_key);
        }
    }

    // 6. Return keys.
    return keys.toOwnedSlice(agent.gc_allocator);
}

/// 10.4.5.9 TypedArray With Buffer Witness Records
/// https://tc39.es/ecma262/#sec-typedarray-with-buffer-witness-records
pub const TypedArrayWithBufferWitness = struct {
    /// [[Object]]
    object: *TypedArray,

    /// [[CachedBufferByteLength]]
    cached_buffer_byte_length: DetachedByteLength,
};

/// 10.4.5.10 MakeTypedArrayWithBufferWitnessRecord ( obj, order )
/// https://tc39.es/ecma262/#sec-maketypedarraywithbufferwitnessrecord
pub fn makeTypedArrayWithBufferWitnessRecord(
    obj: *TypedArray,
    order: Order,
) TypedArrayWithBufferWitness {
    // 1. Let buffer be obj.[[ViewedArrayBuffer]].
    const buffer = obj.fields.viewed_array_buffer;

    // 2. If IsDetachedBuffer(buffer) is true, then
    const byte_length: DetachedByteLength = if (isDetachedBuffer(buffer)) blk: {
        // a. Let byteLength be detached.
        break :blk .detached;
    } else blk: {
        // 3. Else,
        // a. Let byteLength be ArrayBufferByteLength(buffer, order).
        break :blk arrayBufferByteLength(buffer, order).toDetached();
    };

    // 4. Return the TypedArray With Buffer Witness Record { [[Object]]: obj,
    //    [[CachedBufferByteLength]]: byteLength }.
    return .{ .object = obj, .cached_buffer_byte_length = byte_length };
}

/// 10.4.5.12 TypedArrayByteLength ( taRecord )
/// https://tc39.es/ecma262/#sec-typedarraybytelength
pub fn typedArrayByteLength(ta_record: TypedArrayWithBufferWitness) ByteLength {
    // 1. Assert: IsTypedArrayOutOfBounds(taRecord) is false.
    std.debug.assert(!isTypedArrayOutOfBounds(ta_record));

    // 2. Let obj be taRecord.[[Object]].
    const typed_array = ta_record.object;

    // 3. If obj.[[ByteLength]] is not auto, return obj.[[ByteLength]].
    if (typed_array.fields.byte_length != .auto) {
        return @fromBackingInt(@intCast(@backingInt(typed_array.fields.byte_length)));
    }

    // 4. Let length be TypedArrayLength(taRecord).
    const length = typedArrayLength(ta_record);

    // 5. Let elementSize be TypedArrayElementSize(obj).
    const element_size = typedArrayElementSize(typed_array);

    // 6. NOTE: The returned byte length is always an integer multiple of elementSize, even when the
    //    underlying buffer has been resized to a non-integer multiple.
    // 7. Return length × elementSize.
    return @fromBackingInt(@backingInt(length) * element_size);
}

/// 10.4.5.13 TypedArrayLength ( taRecord )
/// https://tc39.es/ecma262/#sec-typedarraylength
pub fn typedArrayLength(ta_record: TypedArrayWithBufferWitness) ArrayLength {
    // 1. Assert: IsTypedArrayOutOfBounds(taRecord) is false.
    std.debug.assert(!isTypedArrayOutOfBounds(ta_record));

    // 2. Let obj be taRecord.[[Object]].
    const typed_array = ta_record.object;

    // 3. If obj.[[ArrayLength]] is not auto, return obj.[[ArrayLength]].
    if (typed_array.fields.array_length != .auto) {
        return @fromBackingInt(@intCast(@backingInt(typed_array.fields.array_length)));
    }

    // 4. Assert: IsFixedLengthArrayBuffer(obj.[[ViewedArrayBuffer]]) is false.
    std.debug.assert(!isFixedLengthArrayBuffer(typed_array.fields.viewed_array_buffer));

    // 5. Let byteOffset be obj.[[ByteOffset]].
    const byte_offset = typed_array.fields.byte_offset;

    // 6. Let elementSize be TypedArrayElementSize(obj).
    const element_size = typedArrayElementSize(typed_array);

    // 7. Let byteLength be taRecord.[[CachedBufferByteLength]].
    const byte_length = ta_record.cached_buffer_byte_length;

    // 8. Assert: byteLength is not detached.
    std.debug.assert(byte_length != .detached);

    // 9. Return floor((byteLength - byteOffset) / elementSize).
    return @fromBackingInt(@intCast(@divFloor(@backingInt(byte_length) - @backingInt(byte_offset), element_size)));
}

/// 10.4.5.14 IsTypedArrayOutOfBounds ( taRecord )
/// https://tc39.es/ecma262/#sec-istypedarrayoutofbounds
pub fn isTypedArrayOutOfBounds(ta_record: TypedArrayWithBufferWitness) bool {
    // 1. Let obj be taRecord.[[Object]].
    const typed_array = ta_record.object;

    // 2. Let bufferByteLength be taRecord.[[CachedBufferByteLength]].
    const buffer_byte_length = ta_record.cached_buffer_byte_length;

    // 3. If IsDetachedBuffer(obj.[[ViewedArrayBuffer]]) is true, then
    if (isDetachedBuffer(typed_array.fields.viewed_array_buffer)) {
        // a. Assert: bufferByteLength is detached.
        std.debug.assert(buffer_byte_length == .detached);

        // b. Return true.
        return true;
    }

    // 4. Assert: bufferByteLength is a non-negative integer.
    std.debug.assert(buffer_byte_length != .detached);

    // 5. Let byteOffsetStart be obj.[[ByteOffset]].
    const byte_offset_start = typed_array.fields.byte_offset;

    // 6. If obj.[[ArrayLength]] is auto, then
    const byte_offset_end: ByteOffset = if (typed_array.fields.array_length == .auto) blk: {
        // a. Let byteOffsetEnd be bufferByteLength.
        break :blk @fromBackingInt(@intCast(@backingInt(buffer_byte_length)));
    } else blk: {
        // 7. Else,
        // a. Let elementSize be TypedArrayElementSize(obj).
        const element_size = typedArrayElementSize(typed_array);

        // b. Let arrayByteLength be obj.[[ArrayLength]] × elementSize.
        const array_byte_length = std.math.mul(
            u53,
            @backingInt(typed_array.fields.array_length.unwrap().?),
            element_size,
        ) catch return true;

        // c. Let byteOffsetEnd be byteOffsetStart + arrayByteLength.
        const byte_offset_end = std.math.add(
            u53,
            @backingInt(byte_offset_start),
            array_byte_length,
        ) catch return true;

        break :blk @fromBackingInt(byte_offset_end);
    };

    // 8. NOTE: A 0-length TypedArray whose [[ByteOffset]] is bufferByteLength is not considered
    //    out-of-bounds.

    // 9. If byteOffsetStart > bufferByteLength or byteOffsetEnd > bufferByteLength, return true.
    if (@backingInt(byte_offset_start) > @backingInt(buffer_byte_length) or
        @backingInt(byte_offset_end) > @backingInt(buffer_byte_length)) return true;

    // 10. Return false.
    return false;
}

/// 10.4.5.15 IsTypedArrayFixedLength ( obj )
/// https://tc39.es/ecma262/#sec-istypedarrayfixedlength
fn isTypedArrayFixedLength(typed_array: *const TypedArray) bool {
    // 1. If obj.[[ArrayLength]] is auto, return false.
    if (typed_array.fields.array_length == .auto) return false;

    // 2. Let buffer be obj.[[ViewedArrayBuffer]].
    const buffer = typed_array.fields.viewed_array_buffer;

    // 3. If IsFixedLengthArrayBuffer(buffer) is false and IsSharedArrayBuffer(buffer) is false,
    //    return false.
    if (!isFixedLengthArrayBuffer(buffer) and !isSharedArrayBuffer(buffer)) return false;

    // 4. Return true.
    return true;
}

/// 10.4.5.16 IsValidIntegerIndex ( obj, index )
/// https://tc39.es/ecma262/#sec-isvalidintegerindex
fn isValidIntegerIndex(
    typed_array: *const TypedArray,
    index: PropertyKey.CanonicalNumericIndex,
) bool {
    // 1. If IsDetachedBuffer(obj.[[ViewedArrayBuffer]]) is true, return false.
    if (isDetachedBuffer(typed_array.fields.viewed_array_buffer)) return false;

    // 2. If index is not an integral Number, return false.
    // 3. If index is -0𝔽 or index < -0𝔽, return false.
    if (index != .integer_index) return false;

    // 4. Let taRecord be MakeTypedArrayWithBufferWitnessRecord(obj, unordered).
    // 5. NOTE: Bounds checking is not a synchronizing operation when obj's backing buffer is a
    //    growable SharedArrayBuffer.
    const ta_record = makeTypedArrayWithBufferWitnessRecord(@constCast(typed_array), .unordered);

    // 6. If IsTypedArrayOutOfBounds(taRecord) is true, return false.
    if (isTypedArrayOutOfBounds(ta_record)) return false;

    // 7. Let length be TypedArrayLength(taRecord).
    const length = typedArrayLength(ta_record);

    // 8. If ℝ(index) ≥ length, return false.
    if (index.integer_index >= @backingInt(length)) return false;

    // 9. Return true.
    return true;
}

/// 10.4.5.17 TypedArrayGetElement ( obj, index )
/// https://tc39.es/ecma262/#sec-typedarraygetelement
fn typedArrayGetElement(
    agent: *Agent,
    typed_array: *const TypedArray,
    index: PropertyKey.CanonicalNumericIndex,
) std.mem.Allocator.Error!Value {
    // 1. If IsValidIntegerIndex(obj, index) is false, return undefined.
    if (!isValidIntegerIndex(typed_array, index)) return .undefined;

    // 2. Let offset be obj.[[ByteOffset]].
    const offset = typed_array.fields.byte_offset;

    // 3. Let elementSize be TypedArrayElementSize(obj).
    const element_size = typedArrayElementSize(typed_array);

    // 4. Let byteIndexInBuffer be (ℝ(index) × elementSize) + offset.
    const byte_index_in_buffer = (index.integer_index * element_size) + @backingInt(offset);

    // 5. Let elementType be TypedArrayElementType(obj).
    switch (typed_array.fields.element_type) {
        inline else => |element_type| {
            // 6. Return GetValueFromBuffer(obj.[[ViewedArrayBuffer]], byteIndexInBuffer,
            //    elementType, true, unordered).
            const value = getValueFromBuffer(
                agent,
                typed_array.fields.viewed_array_buffer,
                byte_index_in_buffer,
                element_type,
                true,
                .unordered,
                null,
            );
            return if (element_type.isBigIntElementType())
                Value.from(try BigInt.fromValue(agent, value))
            else
                Value.from(value);
        },
    }
}

/// 10.4.5.18 TypedArraySetElement ( obj, index, value )
/// https://tc39.es/ecma262/#sec-typedarraysetelement
fn typedArraySetElement(
    agent: *Agent,
    typed_array: *const TypedArray,
    index: PropertyKey.CanonicalNumericIndex,
    value: Value,
) Agent.Error!void {
    // 1. If obj.[[ContentType]] is bigint, let number be ? ToBigInt(value).
    // 2. Else, let number be ? ToNumber(value).
    const number = if (typed_array.fields.content_type == .bigint)
        Value.from(try value.toBigInt(agent))
    else
        Value.from(try value.toNumber(agent));

    // 3. If IsValidIntegerIndex(obj, index) is true, then
    if (isValidIntegerIndex(typed_array, index)) {
        // a. Let offset be obj.[[ByteOffset]].
        const offset = typed_array.fields.byte_offset;

        // b. Let elementSize be TypedArrayElementSize(obj).
        const element_size = typedArrayElementSize(typed_array);

        // c. Let byteIndexInBuffer be (ℝ(index) × elementSize) + offset.
        const byte_index_in_buffer = (index.integer_index * element_size) + @backingInt(offset);

        // d. Let elementType be TypedArrayElementType(obj).
        switch (typed_array.fields.element_type) {
            inline else => |element_type| {
                // e. Perform SetValueInBuffer(obj.[[ViewedArrayBuffer]], byteIndexInBuffer,
                //    elementType, number, true, unordered).
                try setValueInBuffer(
                    agent,
                    typed_array.fields.viewed_array_buffer,
                    byte_index_in_buffer,
                    element_type,
                    number,
                    true,
                    .unordered,
                    null,
                );
            },
        }
    }

    // 4. Return unused.
}

/// 23.2.2 Properties of the %TypedArray% Intrinsic Object
/// https://tc39.es/ecma262/#sec-properties-of-the-%typedarray%-intrinsic-object
pub const constructor = struct {
    pub fn create(agent: *Agent, realm: *Realm) std.mem.Allocator.Error!*Object {
        const builtin_function = try createBuiltinFunction(
            agent,
            .{ .constructor = impl },
            0,
            "TypedArray",
            .{ .realm = realm, .proto = try realm.intrinsic(.function_prototype) },
        );
        return &builtin_function.object;
    }

    pub fn init(agent: *Agent, realm: *Realm, object: *Object) std.mem.Allocator.Error!void {
        try object.defineBuiltinFunction(agent, "from", from, 1, realm);
        try object.defineBuiltinFunction(agent, "of", of, 0, realm);
        try object.defineBuiltinAccessor(agent, "Symbol.species", @"Symbol.species", null, realm);

        // 23.2.2.3 %TypedArray%.prototype
        // https://tc39.es/ecma262/#sec-%typedarray%.prototype
        try object.defineBuiltinPropertyWithAttributes(
            agent,
            "prototype",
            Value.from(try realm.intrinsic(.typed_array_prototype)),
            .none,
        );
    }

    /// 23.2.1.1 %TypedArray% ( )
    /// https://tc39.es/ecma262/#sec-%typedarray%
    fn impl(agent: *Agent, _: Arguments, _: ?*Object) Agent.Error!Value {
        // 1. Throw a TypeError exception.
        return agent.throwException(
            .type_error,
            "TypedArray abstract superclass cannot be constructed",
            .{},
        );
    }

    /// 23.2.2.1 %TypedArray%.from ( source [ , mapper [ , thisArg ] ] )
    /// https://tc39.es/ecma262/#sec-%typedarray%.from
    fn from(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const source = arguments.get(0);
        const mapper_value = arguments.get(1);
        const this_arg = arguments.get(2);

        // 1. Let ctor be the this value.
        const ctor = this_value;

        // 2. If IsConstructor(ctor) is false, throw a TypeError exception.
        if (!ctor.isConstructor()) {
            return agent.throwException(.type_error, "{f} is not a constructor", .{ctor});
        }

        // 3. If mapper is undefined, then
        const maybe_mapper = if (mapper_value.isUndefined()) blk: {
            // a. Let mapping be false.
            break :blk null;
        } else blk: {
            // 4. Else,
            // a. If IsCallable(mapper) is false, throw a TypeError exception.
            if (!mapper_value.isCallable()) {
                return agent.throwException(.type_error, "{f} is not callable", .{mapper_value});
            }

            // b. Let mapping be true.
            break :blk mapper_value.asObject();
        };

        // 5. Let usingIterator be ? GetMethod(source, %Symbol.iterator%).
        const using_iterator = try source.getMethod(
            agent,
            PropertyKey.from(agent.well_known_symbols.iterator),
        );

        // 6. If usingIterator is not undefined, then
        if (using_iterator != null) {
            // a. Let values be ? IteratorToList(? GetIteratorFromMethod(source, usingIterator)).
            var iterator = try getIteratorFromMethod(agent, source, using_iterator.?);
            const values = try iterator.toList(agent);
            defer agent.gc_allocator.free(values);

            // b. Let length be the number of elements in values.
            const length: ArrayLength = @fromBackingInt(@intCast(values.len));

            // c. Let targetObj be ? TypedArrayCreateFromConstructor(ctor, « 𝔽(length) »).
            const typed_array = try typedArrayCreateFromConstructor(
                agent,
                ctor.asObject(),
                &.{Value.from(@backingInt(length))},
            );

            // d. Let k be 0.
            // e. Repeat, while k < length,
            for (values, 0..) |k_value, k| {
                // i. Let kValue be values[k].

                // ii. If mapping is true, then
                const mapped_value = if (maybe_mapper) |mapper| blk: {
                    // 1. Let mappedValue be ? Call(mapper, thisArg, « kValue, 𝔽(k) »).
                    break :blk try mapper.call(
                        agent,
                        this_arg,
                        &.{ k_value, Value.from(@as(u53, @intCast(k))) },
                    );
                } else blk: {
                    // iii. Else,
                    // 1. Let mappedValue be kValue.
                    break :blk k_value;
                };

                // iv. Perform ? TypedArraySetElement(targetObj, 𝔽(k), mappedValue).
                try typedArraySetElement(
                    agent,
                    typed_array,
                    .{ .integer_index = @intCast(k) },
                    mapped_value,
                );

                // v. Set k to k + 1.
            }

            // f. Return targetObj.
            return Value.from(&typed_array.object);
        }

        // 7. NOTE: source is not an iterable object, so assume it is already an array-like object.

        // 8. Let arrayLike be ! ToObject(source).
        const array_like = source.toObject(agent) catch |err| try noexcept(err);

        // 9. Let length be ? LengthOfArrayLike(arrayLike).
        const length: ArrayLength = @fromBackingInt(try array_like.lengthOfArrayLike(agent));

        // 10. Let targetObj be ? TypedArrayCreateFromConstructor(ctor, « 𝔽(length) »).
        const typed_array = try typedArrayCreateFromConstructor(
            agent,
            ctor.asObject(),
            &.{Value.from(@backingInt(length))},
        );

        // 11. Let k be 0.
        var k: u53 = 0;

        // 12. Repeat, while k < length,
        while (k < @backingInt(length)) : (k += 1) {
            // a. Let propertyKey be ! ToString(𝔽(k)).
            const property_key = PropertyKey.from(k);

            // b. Let kValue be ? Get(arrayLike, propertyKey).
            const k_value = try array_like.get(agent, property_key);

            // c. If mapping is true, then
            const mapped_value = if (maybe_mapper) |mapper| blk: {
                // i. Let mappedValue be ? Call(mapper, thisArg, « kValue, 𝔽(k) »).
                break :blk try mapper.call(agent, this_arg, &.{ k_value, Value.from(k) });
            } else blk: {
                // d. Else,
                // i. Let mappedValue be kValue.
                break :blk k_value;
            };

            // e. Perform ? TypedArraySetElement(targetObj, 𝔽(k), mappedValue).
            try typedArraySetElement(agent, typed_array, .{ .integer_index = k }, mapped_value);

            // f. Set k to k + 1.
        }

        // 13. Return targetObj.
        return Value.from(&typed_array.object);
    }

    /// 23.2.2.2 %TypedArray%.of ( ...items )
    /// https://tc39.es/ecma262/#sec-%typedarray%.of
    fn of(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        // 1. Let length be the number of elements in items.
        const length = arguments.count();

        // 2. Let ctor be the this value.
        const ctor = this_value;

        // 3. If IsConstructor(ctor) is false, throw a TypeError exception.
        if (!ctor.isConstructor()) {
            return agent.throwException(.type_error, "{f} is not a constructor", .{ctor});
        }

        // 4. Let newObj be ? TypedArrayCreateFromConstructor(ctor, « 𝔽(length) »).
        const typed_array = try typedArrayCreateFromConstructor(
            agent,
            ctor.asObject(),
            &.{Value.from(@as(u53, @intCast(length)))},
        );

        // 5. Let k be 0.
        // 6. Repeat, while k < length,
        for (arguments.values, 0..) |k_value, k| {
            // a. Let kValue be items[k].

            // b. Perform ? TypedArraySetElement(newObj, 𝔽(k), kValue).
            try typedArraySetElement(
                agent,
                typed_array,
                .{ .integer_index = @intCast(k) },
                k_value,
            );

            // c. Set k to k + 1.
        }

        // 7. Return newObj.
        return Value.from(&typed_array.object);
    }

    /// 23.2.2.4 get %TypedArray% [ %Symbol.species% ]
    /// https://tc39.es/ecma262/#sec-get-%typedarray%-%symbol.species%
    fn @"Symbol.species"(_: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Return the this value.
        return this_value;
    }
};

/// 23.2.3 Properties of the %TypedArray% Prototype Object
/// https://tc39.es/ecma262/#sec-properties-of-the-%typedarrayprototype%-object
pub const prototype = struct {
    pub fn create(agent: *Agent, realm: *Realm) std.mem.Allocator.Error!*Object {
        return ordinaryObjectCreate(agent, try realm.intrinsic(.object_prototype));
    }

    pub fn init(agent: *Agent, realm: *Realm, object: *Object) std.mem.Allocator.Error!void {
        try object.defineBuiltinFunction(agent, "at", at, 1, realm);
        try object.defineBuiltinAccessor(agent, "buffer", buffer, null, realm);
        try object.defineBuiltinAccessor(agent, "byteLength", byteLength, null, realm);
        try object.defineBuiltinAccessor(agent, "byteOffset", byteOffset, null, realm);
        try object.defineBuiltinFunction(agent, "copyWithin", copyWithin, 2, realm);
        try object.defineBuiltinFunction(agent, "entries", entries, 0, realm);
        try object.defineBuiltinFunction(agent, "every", every, 1, realm);
        try object.defineBuiltinFunction(agent, "fill", fill, 1, realm);
        try object.defineBuiltinFunction(agent, "filter", filter, 1, realm);
        try object.defineBuiltinFunction(agent, "find", find, 1, realm);
        try object.defineBuiltinFunction(agent, "findIndex", findIndex, 1, realm);
        try object.defineBuiltinFunction(agent, "findLast", findLast, 1, realm);
        try object.defineBuiltinFunction(agent, "findLastIndex", findLastIndex, 1, realm);
        try object.defineBuiltinFunction(agent, "forEach", forEach, 1, realm);
        try object.defineBuiltinFunction(agent, "includes", includes, 1, realm);
        try object.defineBuiltinFunction(agent, "indexOf", indexOf, 1, realm);
        try object.defineBuiltinFunction(agent, "join", join, 1, realm);
        try object.defineBuiltinFunction(agent, "keys", keys, 0, realm);
        try object.defineBuiltinFunction(agent, "lastIndexOf", lastIndexOf, 1, realm);
        try object.defineBuiltinAccessor(agent, "length", length, null, realm);
        try object.defineBuiltinFunction(agent, "map", map, 1, realm);
        try object.defineBuiltinFunction(agent, "reduce", reduce, 1, realm);
        try object.defineBuiltinFunction(agent, "reduceRight", reduceRight, 1, realm);
        try object.defineBuiltinFunction(agent, "reverse", reverse, 0, realm);
        try object.defineBuiltinFunction(agent, "set", set_, 1, realm);
        try object.defineBuiltinFunction(agent, "slice", slice, 2, realm);
        try object.defineBuiltinFunction(agent, "some", some, 1, realm);
        try object.defineBuiltinFunction(agent, "sort", sort, 1, realm);
        try object.defineBuiltinFunction(agent, "subarray", subarray, 2, realm);
        try object.defineBuiltinFunction(agent, "toLocaleString", toLocaleString, 0, realm);
        try object.defineBuiltinFunction(agent, "toReversed", toReversed, 0, realm);
        try object.defineBuiltinFunction(agent, "toSorted", toSorted, 1, realm);
        try object.defineBuiltinFunction(agent, "values", values, 0, realm);
        try object.defineBuiltinFunction(agent, "with", with, 2, realm);
        try object.defineBuiltinAccessor(agent, "Symbol.toStringTag", @"Symbol.toStringTag", null, realm);

        // 23.2.3.5 %TypedArray%.prototype.constructor
        // https://tc39.es/ecma262/#sec-%typedarray%.prototype.constructor
        try object.defineBuiltinProperty(
            agent,
            "constructor",
            Value.from(try realm.intrinsic(.typed_array)),
        );

        // 23.2.3.34 %TypedArray%.prototype.toString ( )
        // https://tc39.es/ecma262/#sec-%typedarray%.prototype.tostring
        try object.defineBuiltinProperty(agent, "toString", Value.from(try realm.intrinsic(.array_prototype_to_string)));

        // 23.2.3.37 %TypedArray%.prototype [ %Symbol.iterator% ] ( )
        // https://tc39.es/ecma262/#sec-%typedarray%.prototype-%symbol.iterator%
        const typed_array_prototype_values = object.getPropertyValueDirect(PropertyKey.from("values"));
        try object.defineBuiltinProperty(agent, "Symbol.iterator", typed_array_prototype_values);
    }

    /// 23.2.3.1 %TypedArray%.prototype.at ( index )
    /// https://tc39.es/ecma262/#sec-%typedarray%.prototype.at
    fn at(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const index = arguments.get(0);

        // 1. Let obj be the this value.
        // 2. Let taRecord be ? ValidateTypedArray(obj, seq-cst).
        const ta_record = try validateTypedArray(agent, this_value, .seq_cst);
        const typed_array = ta_record.object;

        // 3. Let length be TypedArrayLength(taRecord).
        const length_ = typedArrayLength(ta_record);

        // 4. Let k be ? ToAbsoluteIndex(index, length).
        const k_f64 = try index.toAbsoluteIndex(agent, @backingInt(length_));

        // 5. If k < 0 or k ≥ length, return undefined.
        if (k_f64 < 0 or k_f64 >= @as(f64, @floatFromInt(@backingInt(length_)))) return .undefined;
        const k: u53 = @intFromFloat(k_f64);

        // 6. Return TypedArrayGetElement(obj, 𝔽(k)).
        return typedArrayGetElement(agent, typed_array, .{ .integer_index = k });
    }

    /// 23.2.3.2 get %TypedArray%.prototype.buffer
    /// https://tc39.es/ecma262/#sec-get-%typedarray%.prototype.buffer
    fn buffer(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let obj be the this value.
        // 2. Perform ? RequireInternalSlot(obj, [[TypedArrayName]]).
        // 3. Assert: obj has a [[ViewedArrayBuffer]] internal slot.
        const typed_array = try this_value.requireInternalSlot(agent, TypedArray);

        // 4. Let buffer be obj.[[ViewedArrayBuffer]].
        const buffer_ = typed_array.fields.viewed_array_buffer;

        // 5. Return buffer.
        return Value.from(&buffer_.object);
    }

    /// 23.2.3.3 get %TypedArray%.prototype.byteLength
    /// https://tc39.es/ecma262/#sec-get-%typedarray%.prototype.bytelength
    fn byteLength(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let obj be the this value.
        // 2. Perform ? RequireInternalSlot(obj, [[TypedArrayName]]).
        // 3. Assert: obj has a [[ViewedArrayBuffer]] internal slot.
        const typed_array = try this_value.requireInternalSlot(agent, TypedArray);

        // 4. Let taRecord be MakeTypedArrayWithBufferWitnessRecord(obj, seq-cst).
        const ta_record = makeTypedArrayWithBufferWitnessRecord(typed_array, .seq_cst);

        // 5. If IsTypedArrayOutOfBounds(taRecord) is true, return +0𝔽.
        if (isTypedArrayOutOfBounds(ta_record)) return Value.from(0);

        // 6. Let size be TypedArrayByteLength(taRecord).
        const size = typedArrayByteLength(ta_record);

        // 7. Return 𝔽(size).
        return Value.from(@backingInt(size));
    }

    /// 23.2.3.4 get %TypedArray%.prototype.byteOffset
    /// https://tc39.es/ecma262/#sec-get-%typedarray%.prototype.byteoffset
    fn byteOffset(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let obj be the this value.
        // 2. Perform ? RequireInternalSlot(obj, [[TypedArrayName]]).
        // 3. Assert: obj has a [[ViewedArrayBuffer]] internal slot.
        const typed_array = try this_value.requireInternalSlot(agent, TypedArray);

        // 4. Let taRecord be MakeTypedArrayWithBufferWitnessRecord(obj, seq-cst).
        const ta_record = makeTypedArrayWithBufferWitnessRecord(typed_array, .seq_cst);

        // 5. If IsTypedArrayOutOfBounds(taRecord) is true, return +0𝔽.
        if (isTypedArrayOutOfBounds(ta_record)) return Value.from(0);

        // 6. Let offset be obj.[[ByteOffset]].
        const offset = typed_array.fields.byte_offset;

        // 7. Return 𝔽(offset).
        return Value.from(@backingInt(offset));
    }

    /// 23.2.3.6 %TypedArray%.prototype.copyWithin ( target, start [ , end ] )
    /// https://tc39.es/ecma262/#sec-%typedarray%.prototype.copywithin
    fn copyWithin(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const target = arguments.get(0);
        const start = arguments.get(1);
        const end = arguments.get(2);

        // 1. Let obj be the this value.
        // 2. Let taRecord be ? ValidateTypedArray(obj, seq-cst).
        var ta_record = try validateTypedArray(agent, this_value, .seq_cst);
        const typed_array = ta_record.object;

        // 3. Let length be TypedArrayLength(taRecord).
        var length_ = typedArrayLength(ta_record);

        // 4. Let targetIndex be ? ToClampedIndex(target, length).
        const target_index = try target.toClampedIndex(agent, @backingInt(length_));

        // 5. Let startIndex be ? ToClampedIndex(start, length).
        const start_index = try start.toClampedIndex(agent, @backingInt(length_));

        // 6. If end is undefined, let endIndex be length; else let endIndex be ? ToClampedIndex(
        //    end, length).
        const end_index = if (end.isUndefined())
            @backingInt(length_)
        else
            try end.toClampedIndex(agent, @backingInt(length_));

        // 7. Let count be min(endIndex - startIndex, length - targetIndex).
        var count = @min(end_index -| start_index, @backingInt(length_) -| target_index);

        // 8. If count > 0, then
        if (count > 0) {
            // a. NOTE: The copying must be performed in a manner that preserves the bit-level
            //    encoding of the source data.

            // b. Let buffer be obj.[[ViewedArrayBuffer]].
            const buffer_ = typed_array.fields.viewed_array_buffer;

            // c. Set taRecord to ? ValidateTypedArrayBounds(obj, seq-cst).
            ta_record = try validateTypedArrayBounds(agent, typed_array, .seq_cst);

            // d. Set length to TypedArrayLength(taRecord).
            length_ = typedArrayLength(ta_record);

            // e. NOTE: Side-effects of the above steps may have reduced the size of obj, in which
            //    case copying should proceed with the longest still-applicable prefix.
            // f. Set count to min(count, length - startIndex, length - targetIndex).
            count = @min(count, @backingInt(length_) - start_index, @backingInt(length_) - target_index);

            // g. Let elementSize be TypedArrayElementSize(obj).
            const element_size = typedArrayElementSize(typed_array);

            // h. Let byteOffset be obj.[[ByteOffset]].
            const byte_offset = typed_array.fields.byte_offset;

            // i. Let toByteIndex be (targetIndex × elementSize) + byteOffset.
            var to_byte_index = (target_index * element_size) + @backingInt(byte_offset);

            // j. Let fromByteIndex be (startIndex × elementSize) + byteOffset.
            var from_byte_index = (start_index * element_size) + @backingInt(byte_offset);

            // k. Let countBytes be count × elementSize.
            var count_bytes = count * element_size;

            // l. If fromByteIndex < toByteIndex and toByteIndex < fromByteIndex + countBytes, then
            const direction: i2 = if (from_byte_index < to_byte_index and
                to_byte_index < (from_byte_index + count_bytes))
            blk: {
                // ii. Set fromByteIndex to fromByteIndex + countBytes - 1.
                from_byte_index += count_bytes - 1;

                // iii. Set toByteIndex to toByteIndex + countBytes - 1.
                to_byte_index += count_bytes - 1;

                // i. Let direction be -1.
                break :blk -1;
            } else blk: {
                // m. Else,
                // i. Let direction be 1.
                break :blk 1;
            };

            // n. Repeat, while countBytes > 0,
            while (count_bytes > 0) {
                // i. Assert: fromByteIndex ≥ 0 and toByteIndex ≥ 0.

                // ii. Let value be GetValueFromBuffer(buffer, fromByteIndex, uint8, true,
                //     unordered).
                const value = getValueFromBuffer(
                    agent,
                    buffer_,
                    from_byte_index,
                    .uint8,
                    true,
                    .unordered,
                    null,
                );

                // iii. Perform SetValueInBuffer(buffer, toByteIndex, uint8, value, true,
                //      unordered).
                try setValueInBuffer(
                    agent,
                    buffer_,
                    to_byte_index,
                    .uint8,
                    Value.from(value),
                    true,
                    .unordered,
                    null,
                );

                // iv. Set fromByteIndex to fromByteIndex + direction.
                if (direction == 1) from_byte_index += 1 else from_byte_index -|= 1;

                // v. Set toByteIndex to toByteIndex + direction.
                if (direction == 1) to_byte_index += 1 else to_byte_index -|= 1;

                // vi. Set countBytes to countBytes - 1.
                count_bytes -= 1;
            }
        }

        // 9. Return obj.
        return Value.from(&typed_array.object);
    }

    /// 23.2.3.7 %TypedArray%.prototype.entries ( )
    /// https://tc39.es/ecma262/#sec-%typedarray%.prototype.entries
    fn entries(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let obj be the this value.
        // 2. Perform ? ValidateTypedArray(obj, seq-cst).
        const ta_record = try validateTypedArray(agent, this_value, .seq_cst);
        const typed_array = ta_record.object;

        // 3. Return CreateArrayIterator(obj, key+value).
        const array_iterator = try createArrayIterator(agent, &typed_array.object, .key_value);
        return Value.from(&array_iterator.object);
    }

    /// 23.2.3.8 %TypedArray%.prototype.every ( callback [ , thisArg ] )
    /// https://tc39.es/ecma262/#sec-%typedarray%.prototype.every
    fn every(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const callback_value = arguments.get(0);
        const this_arg = arguments.get(1);

        // 1. Let obj be the this value.
        // 2. Let taRecord be ? ValidateTypedArray(obj, seq-cst).
        const ta_record = try validateTypedArray(agent, this_value, .seq_cst);
        const typed_array = ta_record.object;

        // 3. Let length be TypedArrayLength(taRecord).
        const length_ = typedArrayLength(ta_record);

        // 4. If IsCallable(callback) is false, throw a TypeError exception.
        if (!callback_value.isCallable()) {
            return agent.throwException(.type_error, "{f} is not callable", .{callback_value});
        }
        const callback = callback_value.asObject();

        // 5. Let k be 0.
        var k: u53 = 0;

        // 6. Repeat, while k < length,
        while (k < @backingInt(length_)) : (k += 1) {
            // a. Let kValue be TypedArrayGetElement(obj, 𝔽(k)).
            const k_value = try typedArrayGetElement(agent, typed_array, .{ .integer_index = k });

            // b. Let testResult be ToBoolean(? Call(callback, thisArg, « kValue, 𝔽(k), obj »)).
            const test_result = (try callback.call(
                agent,
                this_arg,
                &.{ k_value, Value.from(k), Value.from(&typed_array.object) },
            )).toBoolean();

            // c. If testResult is false, return false.
            if (!test_result) return .false;

            // d. Set k to k + 1.
        }

        // 7. Return true.
        return .true;
    }

    /// 23.2.3.9 %TypedArray%.prototype.fill ( value [ , start [ , end ] ] )
    /// https://tc39.es/ecma262/#sec-%typedarray%.prototype.fill
    fn fill(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        var value = arguments.get(0);
        const start = arguments.get(1);
        const end = arguments.get(2);

        // 1. Let obj be the this value.
        // 2. Let taRecord be ? ValidateTypedArray(obj, seq-cst).
        var ta_record = try validateTypedArray(agent, this_value, .seq_cst);
        const typed_array = ta_record.object;

        // 3. Let length be TypedArrayLength(taRecord).
        var length_ = typedArrayLength(ta_record);

        // 4. If obj.[[ContentType]] is bigint, set value to ? ToBigInt(value).
        // 5. Else, set value to ? ToNumber(value).
        value = if (typed_array.fields.content_type == .bigint)
            Value.from(try value.toBigInt(agent))
        else
            Value.from(try value.toNumber(agent));

        // 6. Let startIndex be ? ToClampedIndex(start, length).
        const start_index = try start.toClampedIndex(agent, @backingInt(length_));

        // 7. If end is undefined, let endIndex be length; else let endIndex be ? ToClampedIndex(
        //    end, length).
        var end_index = if (end.isUndefined())
            @backingInt(length_)
        else
            try end.toClampedIndex(agent, @backingInt(length_));

        // 8. Set taRecord to ? ValidateTypedArrayBounds(obj, seq-cst).
        ta_record = try validateTypedArrayBounds(agent, typed_array, .seq_cst);

        // 9. Set length to TypedArrayLength(taRecord).
        length_ = typedArrayLength(ta_record);

        // 10. Set endIndex to min(endIndex, length).
        end_index = @min(end_index, @backingInt(length_));

        // 11. Let k be startIndex.
        var k: u53 = start_index;

        // 12. Repeat, while k < endIndex,
        while (k < end_index) : (k += 1) {
            // a. Perform ! TypedArraySetElement(obj, 𝔽(k), value).
            typedArraySetElement(
                agent,
                typed_array,
                .{ .integer_index = k },
                value,
            ) catch |err| try noexcept(err);

            // b. Set k to k + 1.
        }

        // 13. Return obj.
        return Value.from(&typed_array.object);
    }

    /// 23.2.3.10 %TypedArray%.prototype.filter ( callback [ , thisArg ] )
    /// https://tc39.es/ecma262/#sec-%typedarray%.prototype.filter
    fn filter(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const callback_value = arguments.get(0);
        const this_arg = arguments.get(1);

        // 1. Let obj be the this value.
        // 2. Let taRecord be ? ValidateTypedArray(obj, seq-cst).
        const ta_record = try validateTypedArray(agent, this_value, .seq_cst);
        const typed_array = ta_record.object;

        // 3. Let length be TypedArrayLength(taRecord).
        const length_ = typedArrayLength(ta_record);

        // 4. If IsCallable(callback) is false, throw a TypeError exception.
        if (!callback_value.isCallable()) {
            return agent.throwException(.type_error, "{f} is not callable", .{callback_value});
        }
        const callback = callback_value.asObject();

        // 5. Let kept be a new empty List.
        var kept: std.ArrayList(Value) = .empty;
        defer kept.deinit(agent.gc_allocator);

        // 6. Let captured be 0.
        var captured: u53 = 0;

        // 7. Let k be 0.
        var k: u53 = 0;

        // 8. Repeat, while k < length,
        while (k < @backingInt(length_)) : (k += 1) {
            // a. Let kValue be TypedArrayGetElement(obj, 𝔽(k)).
            const k_value = try typedArrayGetElement(agent, typed_array, .{ .integer_index = k });

            // b. Let selected be ToBoolean(? Call(callback, thisArg, « kValue, 𝔽(k), obj »)).
            const selected = (try callback.call(
                agent,
                this_arg,
                &.{ k_value, Value.from(k), Value.from(&typed_array.object) },
            )).toBoolean();

            // c. If selected is true, then
            if (selected) {
                // i. Append kValue to kept.
                try kept.append(agent.gc_allocator, k_value);

                // ii. Set captured to captured + 1.
                captured += 1;
            }

            // d. Set k to k + 1.
        }

        // 9. Let result be ? TypedArraySpeciesCreate(obj, « 𝔽(captured) »).
        const result_array = try typedArraySpeciesCreate(
            agent,
            typed_array,
            &.{Value.from(captured)},
        );

        // 10. Let n be 0.
        // 11. For each element element of kept, do
        for (kept.items, 0..) |element, n| {
            // a. Perform ! TypedArraySetElement(result, 𝔽(n), element).
            typedArraySetElement(
                agent,
                result_array,
                .{ .integer_index = @intCast(n) },
                element,
            ) catch |err| try noexcept(err);

            // b. Set n to n + 1.
        }

        // 12. Return result.
        return Value.from(&result_array.object);
    }

    /// 23.2.3.11 %TypedArray%.prototype.find ( predicate [ , thisArg ] )
    /// https://tc39.es/ecma262/#sec-%typedarray%.prototype.find
    fn find(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const predicate = arguments.get(0);
        const this_arg = arguments.get(1);

        // 1. Let obj be the this value.
        // 2. Let taRecord be ? ValidateTypedArray(obj, seq-cst).
        const ta_record = try validateTypedArray(agent, this_value, .seq_cst);
        const typed_array = ta_record.object;

        // 3. Let length be TypedArrayLength(taRecord).
        const length_ = typedArrayLength(ta_record);

        // 4. Let findRecord be ? FindViaPredicate(obj, length, ascending, predicate, thisArg).
        const find_record = try findViaPredicate(
            agent,
            &typed_array.object,
            @backingInt(length_),
            .ascending,
            predicate,
            this_arg,
        );

        // 5. Return findRecord.[[Value]].
        return find_record.value;
    }

    /// 23.2.3.12 %TypedArray%.prototype.findIndex ( predicate [ , thisArg ] )
    /// https://tc39.es/ecma262/#sec-%typedarray%.prototype.findindex
    fn findIndex(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const predicate = arguments.get(0);
        const this_arg = arguments.get(1);

        // 1. Let obj be the this value.
        // 2. Let taRecord be ? ValidateTypedArray(obj, seq-cst).
        const ta_record = try validateTypedArray(agent, this_value, .seq_cst);
        const typed_array = ta_record.object;

        // 3. Let length be TypedArrayLength(taRecord).
        const length_ = typedArrayLength(ta_record);

        // 4. Let findRecord be ? FindViaPredicate(obj, length, ascending, predicate, thisArg).
        const find_record = try findViaPredicate(
            agent,
            &typed_array.object,
            @backingInt(length_),
            .ascending,
            predicate,
            this_arg,
        );

        // 5. Return findRecord.[[Index]].
        return find_record.index;
    }

    /// 23.2.3.13 %TypedArray%.prototype.findLast ( predicate [ , thisArg ] )
    /// https://tc39.es/ecma262/#sec-%typedarray%.prototype.findlast
    fn findLast(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const predicate = arguments.get(0);
        const this_arg = arguments.get(1);

        // 1. Let obj be the this value.
        // 2. Let taRecord be ? ValidateTypedArray(obj, seq-cst).
        const ta_record = try validateTypedArray(agent, this_value, .seq_cst);
        const typed_array = ta_record.object;

        // 3. Let length be TypedArrayLength(taRecord).
        const length_ = typedArrayLength(ta_record);

        // 4. Let findRecord be ? FindViaPredicate(obj, length, descending, predicate, thisArg).
        const find_record = try findViaPredicate(
            agent,
            &typed_array.object,
            @backingInt(length_),
            .descending,
            predicate,
            this_arg,
        );

        // 5. Return findRecord.[[Value]].
        return find_record.value;
    }

    /// 23.2.3.14 %TypedArray%.prototype.findLastIndex ( predicate [ , thisArg ] )
    /// https://tc39.es/ecma262/#sec-%typedarray%.prototype.findlastindex
    fn findLastIndex(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const predicate = arguments.get(0);
        const this_arg = arguments.get(1);

        // 1. Let obj be the this value.
        // 2. Let taRecord be ? ValidateTypedArray(obj, seq-cst).
        const ta_record = try validateTypedArray(agent, this_value, .seq_cst);
        const typed_array = ta_record.object;

        // 3. Let length be TypedArrayLength(taRecord).
        const length_ = typedArrayLength(ta_record);

        // 4. Let findRecord be ? FindViaPredicate(obj, length, descending, predicate, thisArg).
        const find_record = try findViaPredicate(
            agent,
            &typed_array.object,
            @backingInt(length_),
            .descending,
            predicate,
            this_arg,
        );

        // 5. Return findRecord.[[Index]].
        return find_record.index;
    }

    /// 23.2.3.15 %TypedArray%.prototype.forEach ( callback [ , thisArg ] )
    /// https://tc39.es/ecma262/#sec-%typedarray%.prototype.foreach
    fn forEach(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const callback_value = arguments.get(0);
        const this_arg = arguments.get(1);

        // 1. Let obj be the this value.
        // 2. Let taRecord be ? ValidateTypedArray(obj, seq-cst).
        const ta_record = try validateTypedArray(agent, this_value, .seq_cst);
        const typed_array = ta_record.object;

        // 3. Let length be TypedArrayLength(taRecord).
        const length_ = typedArrayLength(ta_record);

        // 4. If IsCallable(callback) is false, throw a TypeError exception.
        if (!callback_value.isCallable()) {
            return agent.throwException(.type_error, "{f} is not callable", .{callback_value});
        }
        const callback = callback_value.asObject();

        // 5. Let k be 0.
        var k: u53 = 0;

        // 6. Repeat, while k < length,
        while (k < @backingInt(length_)) : (k += 1) {
            // a. Let kValue be TypedArrayGetElement(obj, 𝔽(k)).
            const k_value = try typedArrayGetElement(agent, typed_array, .{ .integer_index = k });

            // b. Perform ? Call(callback, thisArg, « kValue, 𝔽(k), obj »).
            _ = try callback.call(
                agent,
                this_arg,
                &.{ k_value, Value.from(k), Value.from(&typed_array.object) },
            );

            // c. Set k to k + 1.
        }

        // 7. Return undefined.
        return .undefined;
    }

    /// 23.2.3.16 %TypedArray%.prototype.includes ( searchElement [ , fromIndex ] )
    /// https://tc39.es/ecma262/#sec-%typedarray%.prototype.includes
    fn includes(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const search_element = arguments.get(0);
        const from_index = arguments.get(1);

        // 1. Let obj be the this value.
        // 2. Let taRecord be ? ValidateTypedArray(obj, seq-cst).
        const ta_record = try validateTypedArray(agent, this_value, .seq_cst);
        const typed_array = ta_record.object;

        // 3. Let length be TypedArrayLength(taRecord).
        const length_ = typedArrayLength(ta_record);

        // 4. If length = 0, return false.
        if (length_ == .zero) return .false;

        // 5. Let k be ? ToClampedIndex(fromIndex, length).
        var k = try from_index.toClampedIndex(agent, @backingInt(length_));

        // 6. Repeat, while k < length,
        while (k < @backingInt(length_)) : (k += 1) {
            // a. Let elementK be TypedArrayGetElement(obj, 𝔽(k)).
            const element_k = try typedArrayGetElement(
                agent,
                typed_array,
                .{ .integer_index = k },
            );

            // b. If SameValueZero(searchElement, elementK) is true, return true.
            if (sameValueZero(search_element, element_k)) return .true;

            // c. Set k to k + 1.
        }

        // 7. Return false.
        return .false;
    }

    /// 23.2.3.17 %TypedArray%.prototype.indexOf ( searchElement [ , fromIndex ] )
    /// https://tc39.es/ecma262/#sec-%typedarray%.prototype.indexof
    fn indexOf(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const search_element = arguments.get(0);
        const from_index = arguments.get(1);

        // 1. Let obj be the this value.
        // 2. Let taRecord be ? ValidateTypedArray(obj, seq-cst).
        const ta_record = try validateTypedArray(agent, this_value, .seq_cst);
        const typed_array = ta_record.object;

        // 3. Let length be TypedArrayLength(taRecord).
        const length_ = typedArrayLength(ta_record);

        // 4. If length = 0, return -1𝔽.
        if (length_ == .zero) return Value.from(-1);

        // 5. Let k be ? ToClampedIndex(fromIndex, length).
        var k = try from_index.toClampedIndex(agent, @backingInt(length_));

        // 6. Repeat, while k < length,
        while (k < @backingInt(length_)) : (k += 1) {
            // a. Let propertyKey be ! ToString(𝔽(k)).
            const property_key = PropertyKey.from(k);

            // b. Let kPresent be ! HasProperty(obj, propertyKey).
            const k_present = typed_array.object.hasProperty(
                agent,
                property_key,
            ) catch |err| try noexcept(err);

            // c. If kPresent is true, then
            if (k_present) {
                // i. Let elementK be TypedArrayGetElement(obj, 𝔽(k)).
                const element_k = try typedArrayGetElement(
                    agent,
                    typed_array,
                    .{ .integer_index = k },
                );

                // ii. If IsStrictlyEqual(searchElement, elementK) is true, return 𝔽(k).
                if (isStrictlyEqual(search_element, element_k)) return Value.from(k);
            }

            // d. Set k to k + 1.
        }

        // 7. Return -1𝔽.
        return Value.from(-1);
    }

    /// 23.2.3.18 %TypedArray%.prototype.join ( separator )
    /// https://tc39.es/ecma262/#sec-%typedarray%.prototype.join
    fn join(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const separator = arguments.get(0);

        // 1. Let obj be the this value.
        // 2. Let taRecord be ? ValidateTypedArray(obj, seq-cst).
        const ta_record = try validateTypedArray(agent, this_value, .seq_cst);
        const typed_array = ta_record.object;

        // 3. Let length be TypedArrayLength(taRecord).
        const length_ = typedArrayLength(ta_record);

        // 4. If separator is undefined, let separatorString be ",".
        // 5. Else, let separatorString be ? ToString(separator).
        const separator_string: String.Builder.Segment = if (separator.isUndefined())
            .{ .char = ',' }
        else
            .{ .string = try separator.toString(agent) };

        // OPTIMIZATION: If the array is empty the result will be an empty string
        if (length_ == .zero) return Value.from(String.empty);

        // 6. Let result be the empty String.
        // NOTE: This allocates the maximum needed capacity upfront
        const capacity = std.math.cast(u32, @as(u64, @backingInt(length_)) * 2 - 1) orelse
            return error.OutOfMemory;
        var result = try String.Builder.initCapacity(agent.gc_allocator, capacity);
        defer result.deinit(agent.gc_allocator);

        // 7. Let k be 0.
        var k: u53 = 0;

        // 8. Repeat, while k < length,
        while (k < @backingInt(length_)) : (k += 1) {
            // a. If k > 0, set result to the string-concatenation of result and separatorString.
            if (k > 0) result.appendSegmentAssumeCapacity(separator_string);

            // b. Let element be TypedArrayGetElement(obj, 𝔽(k)).
            const element = try typedArrayGetElement(agent, typed_array, .{ .integer_index = k });

            // c. If element is not undefined, then
            if (!element.isUndefined()) {
                // i. Let elementString be ! ToString(element).
                const element_string = element.toString(agent) catch |err| try noexcept(err);

                // ii. Set result to the string-concatenation of result and elementString.
                result.appendStringAssumeCapacity(element_string);
            }

            // d. Set k to k + 1.
        }

        // 9. Return result.
        return Value.from(try result.build(agent));
    }

    /// 23.2.3.19 %TypedArray%.prototype.keys ( )
    /// https://tc39.es/ecma262/#sec-%typedarray%.prototype.keys
    fn keys(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let obj be the this value.
        // 2. Perform ? ValidateTypedArray(obj, seq-cst).
        const ta_record = try validateTypedArray(agent, this_value, .seq_cst);
        const typed_array = ta_record.object;

        // 3. Return CreateArrayIterator(obj, key).
        const array_iterator = try createArrayIterator(agent, &typed_array.object, .key);
        return Value.from(&array_iterator.object);
    }

    /// 23.2.3.20 %TypedArray%.prototype.lastIndexOf ( searchElement [ , fromIndex ] )
    /// https://tc39.es/ecma262/#sec-%typedarray%.prototype.lastindexof
    fn lastIndexOf(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const search_element = arguments.get(0);
        const from_index = arguments.get(1);

        // 1. Let obj be the this value.
        // 2. Let taRecord be ? ValidateTypedArray(obj, seq-cst).
        const ta_record = try validateTypedArray(agent, this_value, .seq_cst);
        const typed_array = ta_record.object;

        // 3. Let length be TypedArrayLength(taRecord).
        const length_ = typedArrayLength(ta_record);

        // 4. If length = 0, return -1𝔽.
        if (length_ == .zero) return Value.from(-1);

        // 5. If fromIndex is not present, let k be length - 1; else let k be min(? ToAbsoluteIndex(
        //    fromIndex, length), length - 1).
        var k: u53 = if (arguments.count() <= 1)
            @backingInt(length_) - 1
        else blk: {
            const absolute = try from_index.toAbsoluteIndex(agent, @backingInt(length_));
            if (absolute < 0) return Value.from(-1);
            break :blk @as(u53, @intFromFloat(@min(absolute, @as(f64, @floatFromInt(@backingInt(length_) - 1)))));
        };

        // 6. Repeat, while k ≥ 0,
        while (k >= 0) : (k -|= 1) {
            // a. Let propertyKey be ! ToString(𝔽(k)).
            const property_key = PropertyKey.from(k);

            // b. Let kPresent be ! HasProperty(obj, propertyKey).
            const k_present = typed_array.object.hasProperty(
                agent,
                property_key,
            ) catch |err| try noexcept(err);

            // c. If kPresent is true, then
            if (k_present) {
                // i. Let elementK be TypedArrayGetElement(obj, 𝔽(k)).
                const element_k = try typedArrayGetElement(
                    agent,
                    typed_array,
                    .{ .integer_index = k },
                );

                // ii. If IsStrictlyEqual(searchElement, elementK) is true, return 𝔽(k).
                if (isStrictlyEqual(search_element, element_k)) return Value.from(k);
            }

            // d. Set k to k - 1.
            if (k == 0) break;
        }

        // 7. Return -1𝔽.
        return Value.from(-1);
    }

    /// 23.2.3.21 get %TypedArray%.prototype.length
    /// https://tc39.es/ecma262/#sec-get-%typedarray%.prototype.length
    fn length(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let obj be the this value.
        // 2. Perform ? RequireInternalSlot(obj, [[TypedArrayName]]).
        // 3. Assert: obj has [[ViewedArrayBuffer]] and [[ArrayLength]] internal slots.
        const typed_array = try this_value.requireInternalSlot(agent, TypedArray);

        // 4. Let taRecord be MakeTypedArrayWithBufferWitnessRecord(obj, seq-cst).
        const ta_record = makeTypedArrayWithBufferWitnessRecord(typed_array, .seq_cst);

        // 5. If IsTypedArrayOutOfBounds(taRecord) is true, return +0𝔽.
        if (isTypedArrayOutOfBounds(ta_record)) return Value.from(0);

        // 6. Let length be TypedArrayLength(taRecord).
        const length_ = typedArrayLength(ta_record);

        // 7. Return 𝔽(length).
        return Value.from(@backingInt(length_));
    }

    /// 23.2.3.22 %TypedArray%.prototype.map ( callback [ , thisArg ] )
    /// https://tc39.es/ecma262/#sec-%typedarray%.prototype.map
    fn map(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const callback_value = arguments.get(0);
        const this_arg = arguments.get(1);

        // 1. Let obj be the this value.
        // 2. Let taRecord be ? ValidateTypedArray(obj, seq-cst).
        const ta_record = try validateTypedArray(agent, this_value, .seq_cst);
        const typed_array = ta_record.object;

        // 3. Let length be TypedArrayLength(taRecord).
        const length_ = typedArrayLength(ta_record);

        // 4. If IsCallable(callback) is false, throw a TypeError exception.
        if (!callback_value.isCallable()) {
            return agent.throwException(.type_error, "{f} is not callable", .{callback_value});
        }
        const callback = callback_value.asObject();

        // 5. Let result be ? TypedArraySpeciesCreate(obj, « 𝔽(length) »).
        const result_array = try typedArraySpeciesCreate(
            agent,
            typed_array,
            &.{Value.from(@backingInt(length_))},
        );

        // 6. Let k be 0.
        var k: u53 = 0;

        // 7. Repeat, while k < length,
        while (k < @backingInt(length_)) : (k += 1) {
            // a. Let kValue be TypedArrayGetElement(obj, 𝔽(k)).
            const k_value = try typedArrayGetElement(agent, typed_array, .{ .integer_index = k });

            // b. Let mappedValue be ? Call(callback, thisArg, « kValue, 𝔽(k), obj »).
            const mapped_value = try callback.call(
                agent,
                this_arg,
                &.{ k_value, Value.from(k), Value.from(&typed_array.object) },
            );

            // c. Perform ? TypedArraySetElement(result, 𝔽(k), mappedValue).
            try typedArraySetElement(agent, result_array, .{ .integer_index = k }, mapped_value);

            // d. Set k to k + 1.
        }

        // 8. Return result.
        return Value.from(&result_array.object);
    }

    /// 23.2.3.23 %TypedArray%.prototype.reduce ( callback [ , initialValue ] )
    /// https://tc39.es/ecma262/#sec-%typedarray%.prototype.reduce
    fn reduce(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const callback_value = arguments.get(0);
        const initial_value = arguments.getOrNull(1);

        // 1. Let obj be the this value.
        // 2. Let taRecord be ? ValidateTypedArray(obj, seq-cst).
        const ta_record = try validateTypedArray(agent, this_value, .seq_cst);
        const typed_array = ta_record.object;

        // 3. Let length be TypedArrayLength(taRecord).
        const length_ = typedArrayLength(ta_record);

        // 4. If IsCallable(callback) is false, throw a TypeError exception.
        if (!callback_value.isCallable()) {
            return agent.throwException(.type_error, "{f} is not callable", .{callback_value});
        }
        const callback = callback_value.asObject();

        // 5. If length = 0 and initialValue is not present, throw a TypeError exception.
        if (length_ == .zero and initial_value == null) {
            return agent.throwException(
                .type_error,
                "Cannot reduce empty typed array without initial value",
                .{},
            );
        }

        // 6. Let k be 0.
        var k: u53 = 0;

        // 7. Let accumulator be undefined.
        var accumulator: Value = undefined;

        // 8. If initialValue is present, then
        if (initial_value != null) {
            // a. Set accumulator to initialValue.
            accumulator = initial_value.?;
        } else {
            // 9. Else,
            // a. Set accumulator to TypedArrayGetElement(obj, 𝔽(k)).
            accumulator = try typedArrayGetElement(agent, typed_array, .{ .integer_index = k });

            // b. Set k to k + 1.
            k += 1;
        }

        // 10. Repeat, while k < length,
        while (k < @backingInt(length_)) : (k += 1) {
            // a. Let kValue be TypedArrayGetElement(obj, 𝔽(k)).
            const k_value = try typedArrayGetElement(agent, typed_array, .{ .integer_index = k });

            // b. Set accumulator to ? Call(callback, undefined, « accumulator, kValue, 𝔽(k),
            //    obj »).
            accumulator = try callback.call(
                agent,
                .undefined,
                &.{ accumulator, k_value, Value.from(k), Value.from(&typed_array.object) },
            );

            // c. Set k to k + 1.
        }

        // 11. Return accumulator.
        return accumulator;
    }

    /// 23.2.3.24 %TypedArray%.prototype.reduceRight ( callback [ , initialValue ] )
    /// https://tc39.es/ecma262/#sec-%typedarray%.prototype.reduceright
    fn reduceRight(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const callback_value = arguments.get(0);
        const initial_value = arguments.getOrNull(1);

        // 1. Let obj be the this value.
        // 2. Let taRecord be ? ValidateTypedArray(obj, seq-cst).
        const ta_record = try validateTypedArray(agent, this_value, .seq_cst);
        const typed_array = ta_record.object;

        // 3. Let length be TypedArrayLength(taRecord).
        const length_ = typedArrayLength(ta_record);

        // 4. If IsCallable(callback) is false, throw a TypeError exception.
        if (!callback_value.isCallable()) {
            return agent.throwException(.type_error, "{f} is not callable", .{callback_value});
        }
        const callback = callback_value.asObject();

        // 5. If length = 0 and initialValue is not present, throw a TypeError exception.
        if (length_ == .zero and initial_value == null) {
            return agent.throwException(
                .type_error,
                "Cannot reduce empty typed array without initial value",
                .{},
            );
        }

        // 6. Let k be length - 1.
        var k: ?u53 = std.math.sub(u53, @backingInt(length_), 1) catch null;

        // 7. Let accumulator be undefined.
        var accumulator: Value = undefined;

        // 8. If initialValue is present, then
        if (initial_value != null) {
            // a. Set accumulator to initialValue.
            accumulator = initial_value.?;
        } else {
            // 9. Else,
            // a. Set accumulator to TypedArrayGetElement(obj, 𝔽(k)).
            accumulator = try typedArrayGetElement(agent, typed_array, .{ .integer_index = k.? });

            // b. Set k to k - 1.
            if (k != null) k = std.math.sub(u53, k.?, 1) catch null;
        }

        // 10. Repeat, while k ≥ 0,
        while (k != null) : (k = (std.math.sub(u53, k.?, 1) catch null)) {
            // a. Let kValue be TypedArrayGetElement(obj, 𝔽(k)).
            const k_value = try typedArrayGetElement(agent, typed_array, .{ .integer_index = k.? });

            // b. Set accumulator to ? Call(callback, undefined, « accumulator, kValue, 𝔽(k),
            //    obj »).
            accumulator = try callback.call(
                agent,
                .undefined,
                &.{ accumulator, k_value, Value.from(k.?), Value.from(&typed_array.object) },
            );

            // c. Set k to k - 1.
        }

        // 11. Return accumulator.
        return accumulator;
    }

    /// 23.2.3.25 %TypedArray%.prototype.reverse ( )
    /// https://tc39.es/ecma262/#sec-%typedarray%.prototype.reverse
    fn reverse(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let obj be the this value.
        // 2. Let taRecord be ? ValidateTypedArray(obj, seq-cst).
        const ta_record = try validateTypedArray(agent, this_value, .seq_cst);
        const typed_array = ta_record.object;

        // 3. Let length be TypedArrayLength(taRecord).
        const length_ = typedArrayLength(ta_record);

        // 4. Let middle be floor(length / 2).
        const middle = @divFloor(@backingInt(length_), 2);

        // 5. Let lower be 0.
        var lower: u53 = 0;

        // 6. Repeat, while lower ≠ middle,
        while (lower != middle) {
            // a. Let upper be length - lower - 1.
            const upper = @backingInt(length_) - lower - 1;

            // b. Let lowerValue be TypedArrayGetElement(obj, 𝔽(lower)).
            const lower_value = try typedArrayGetElement(
                agent,
                typed_array,
                .{ .integer_index = lower },
            );

            // c. Let upperValue be TypedArrayGetElement(obj, 𝔽(upper)).
            const upper_value = try typedArrayGetElement(
                agent,
                typed_array,
                .{ .integer_index = upper },
            );

            // d. Perform ! TypedArraySetElement(obj, 𝔽(lower), upperValue).
            typedArraySetElement(
                agent,
                typed_array,
                .{ .integer_index = lower },
                upper_value,
            ) catch |err| try noexcept(err);

            // e. Perform ! TypedArraySetElement(obj, 𝔽(upper), lowerValue).
            typedArraySetElement(
                agent,
                typed_array,
                .{ .integer_index = upper },
                lower_value,
            ) catch |err| try noexcept(err);

            // f. Set lower to lower + 1.
            lower += 1;
        }

        // 7. Return obj.
        return Value.from(&typed_array.object);
    }

    /// 23.2.3.26 %TypedArray%.prototype.set ( source [ , offset ] )
    /// https://tc39.es/ecma262/#sec-%typedarray%.prototype.set
    fn set_(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const source = arguments.get(0);
        const offset = arguments.get(1);

        // 1. Let target be the this value.
        // 2. Perform ? RequireInternalSlot(target, [[TypedArrayName]]).
        // 3. Assert: target has a [[ViewedArrayBuffer]] internal slot.
        const target = try this_value.requireInternalSlot(agent, TypedArray);

        // 4. Let targetOffset be ? ToIntegerOrInfinity(offset).
        const target_offset = try offset.toIntegerOrInfinity(agent);

        // 5. If targetOffset < 0, throw a RangeError exception.
        if (target_offset < 0) {
            return agent.throwException(.range_error, "Offset must not be negative", .{});
        }

        // 6. If source is an Object that has a [[TypedArrayName]] internal slot, then
        if (source.castObject(TypedArray)) |source_typed_array| {
            // a. Perform ? SetTypedArrayFromTypedArray(target, targetOffset, source).
            try setTypedArrayFromTypedArray(agent, target, target_offset, source_typed_array);
        } else {
            // 7. Else,
            // a. Perform ? SetTypedArrayFromArrayLike(target, targetOffset, source).
            try setTypedArrayFromArrayLike(agent, target, target_offset, source);
        }

        // 8. Return undefined.
        return .undefined;
    }

    /// 23.2.3.26.1 SetTypedArrayFromArrayLike ( target, targetOffset, source )
    /// https://tc39.es/ecma262/#sec-settypedarrayfromarraylike
    fn setTypedArrayFromArrayLike(
        agent: *Agent,
        target: *const TypedArray,
        target_offset_f64: f64,
        source_value: Value,
    ) Agent.Error!void {
        std.debug.assert(target_offset_f64 >= 0);

        // 1. Let targetRecord be ? ValidateTypedArrayBounds(target, seq-cst).
        const target_ta = try validateTypedArrayBounds(agent, target, .seq_cst);

        // 2. Let targetLength be TypedArrayLength(targetRecord).
        const target_length = typedArrayLength(target_ta);

        // 3. Set source to ? ToObject(source).
        const source = try source_value.toObject(agent);

        // 4. Let sourceLength be ? LengthOfArrayLike(source).
        const source_length: ArrayLength = @fromBackingInt(try source.lengthOfArrayLike(agent));

        // 5. If targetOffset = +∞, throw a RangeError exception.
        if (target_offset_f64 == std.math.inf(f64)) {
            return agent.throwException(.range_error, "Offset must not be infinite", .{});
        }

        // 6. If sourceLength + targetOffset > targetLength, throw a RangeError exception.
        if (if (std.math.add(u53, @backingInt(source_length), std.math.lossyCast(u53, target_offset_f64))) |x|
            x > @backingInt(target_length)
        else |_|
            true)
        {
            return agent.throwException(
                .range_error,
                "Offset {d} and source length {d} are out of range for target length {d}",
                .{ target_offset_f64, source_length, target_length },
            );
        }

        const target_offset: u53 = @intFromFloat(target_offset_f64);

        // 7. Let k be 0.
        var k: u53 = 0;

        // 8. Repeat, while k < sourceLength,
        while (k < @backingInt(source_length)) : (k += 1) {
            // a. Let propertyKey be ! ToString(𝔽(k)).
            const property_key = PropertyKey.from(k);

            // b. Let value be ? Get(source, propertyKey).
            const value = try source.get(agent, property_key);

            // c. Let targetIndex be 𝔽(targetOffset + k).
            const target_index = target_offset + k;

            // d. Perform ? TypedArraySetElement(target, targetIndex, value).
            try typedArraySetElement(agent, target, .{ .integer_index = target_index }, value);

            // e. Set k to k + 1.
        }

        // 9. Return unused.
    }

    /// 23.2.3.26.2 SetTypedArrayFromTypedArray ( target, targetOffset, source )
    /// https://tc39.es/ecma262/#sec-settypedarrayfromtypedarray
    fn setTypedArrayFromTypedArray(
        agent: *Agent,
        target: *TypedArray,
        target_offset: f64,
        source: *TypedArray,
    ) Agent.Error!void {
        std.debug.assert(target_offset >= 0);

        // 1. Let targetBuffer be target.[[ViewedArrayBuffer]].
        const target_buffer = target.fields.viewed_array_buffer;

        // 2. Let targetRecord be ? ValidateTypedArrayBounds(target, seq-cst).
        const target_ta = try validateTypedArrayBounds(agent, target, .seq_cst);

        // 3. Let targetLength be TypedArrayLength(targetRecord).
        const target_length = typedArrayLength(target_ta);

        // 4. Let sourceBuffer be source.[[ViewedArrayBuffer]].
        var source_buffer = source.fields.viewed_array_buffer;

        // 5. Let sourceRecord be ? ValidateTypedArrayBounds(source, seq-cst).
        const source_record = try validateTypedArrayBounds(agent, source, .seq_cst);

        // 6. Let sourceLength be TypedArrayLength(sourceRecord).
        const source_length = typedArrayLength(source_record);

        // 7. Let targetType be TypedArrayElementType(target).
        const target_type = target.fields.element_type;

        // 8. Let targetElementSize be TypedArrayElementSize(target).
        const target_element_size = typedArrayElementSize(target);

        // 9. Let targetByteOffset be target.[[ByteOffset]].
        const target_byte_offset = target.fields.byte_offset;

        // 10. Let sourceType be TypedArrayElementType(source).
        const source_type = source.fields.element_type;

        // 11. Let sourceElementSize be TypedArrayElementSize(source).
        const source_element_size = typedArrayElementSize(source);

        // 12. Let sourceByteOffset be source.[[ByteOffset]].
        const source_byte_offset = source.fields.byte_offset;

        // 13. If targetOffset = +∞, throw a RangeError exception.
        if (target_offset == std.math.inf(f64)) {
            return agent.throwException(.range_error, "Offset must not be infinite", .{});
        }

        // 14. If sourceLength + targetOffset > targetLength, throw a RangeError exception.
        if (if (std.math.add(u53, @backingInt(source_length), std.math.lossyCast(u53, target_offset))) |x|
            x > @backingInt(target_length)
        else |_|
            true)
        {
            return agent.throwException(
                .range_error,
                "Offset {d} and source length {d} are out of range for target length {d}",
                .{ target_offset, source_length, target_length },
            );
        }

        // 15. If target.[[ContentType]] is not source.[[ContentType]], throw a TypeError exception.
        if (target.fields.content_type != source.fields.content_type) {
            return agent.throwException(
                .type_error,
                "Cannot convert between BigInt and Number typed arrays",
                .{},
            );
        }

        // 16. If IsSharedArrayBuffer(sourceBuffer) is true, IsSharedArrayBuffer(targetBuffer) is
        //     true, and sourceBuffer.[[ArrayBufferData]] is targetBuffer.[[ArrayBufferData]], let
        //     sameSharedArrayBuffer be true; else let sameSharedArrayBuffer be false.
        const same_shared_array_buffer =
            isSharedArrayBuffer(source_buffer) and
            isSharedArrayBuffer(target_buffer) and
            source_buffer.fields.data_block.?.bytes.ptr == target_buffer.fields.data_block.?.bytes.ptr;

        // 17. If SameValue(sourceBuffer, targetBuffer) is true or sameSharedArrayBuffer is true,
        //     then
        var source_byte_index = if (source_buffer == target_buffer or same_shared_array_buffer) blk: {
            // a. Let sourceByteLength be TypedArrayByteLength(sourceRecord).
            const source_byte_length = typedArrayByteLength(source_record);

            // b. Set sourceBuffer to ? CloneArrayBuffer(sourceBuffer, sourceByteOffset,
            //    sourceByteLength).
            source_buffer = try cloneArrayBuffer(
                agent,
                source_buffer,
                source_byte_offset,
                source_byte_length,
            );

            // c. Let sourceByteIndex be 0.
            break :blk 0;
        } else blk: {
            // 18. Else,
            // a. Let sourceByteIndex be sourceByteOffset.
            break :blk @backingInt(source_byte_offset);
        };

        // 19. Let targetByteIndex be (targetOffset × targetElementSize) + targetByteOffset.
        var target_byte_index = (@as(u53, @intFromFloat(target_offset)) * target_element_size) + @backingInt(target_byte_offset);

        // 20. Let limit be targetByteIndex + (targetElementSize × sourceLength).
        const limit = target_byte_index + (target_element_size * @backingInt(source_length));

        // 21. If sourceType is targetType, then
        if (source_type == target_type) {
            // a. NOTE: The transfer must be performed in a manner that preserves the bit-level
            //    encoding of the source data.
            // b. Repeat, while targetByteIndex < limit,
            while (target_byte_index < limit) : ({
                source_byte_index += 1;
                target_byte_index += 1;
            }) {
                // i. Let value be GetValueFromBuffer(sourceBuffer, sourceByteIndex, uint8, true,
                //    unordered).
                const value = getValueFromBuffer(
                    agent,
                    source_buffer,
                    source_byte_index,
                    .uint8,
                    true,
                    .unordered,
                    null,
                );

                // ii. Perform SetValueInBuffer(targetBuffer, targetByteIndex, uint8, value, true,
                //     unordered).
                try setValueInBuffer(
                    agent,
                    target_buffer,
                    target_byte_index,
                    .uint8,
                    Value.from(value),
                    true,
                    .unordered,
                    null,
                );

                // iii. Set sourceByteIndex to sourceByteIndex + 1.
                // iv. Set targetByteIndex to targetByteIndex + 1.
            }
        } else {
            // 22. Else,
            // a. Repeat, while targetByteIndex < limit,
            while (target_byte_index < limit) : ({
                source_byte_index += source_element_size;
                target_byte_index += target_element_size;
            }) {
                const value = switch (source_type) {
                    inline else => |@"type"| value: {
                        // i. Let value be GetValueFromBuffer(sourceBuffer, sourceByteIndex,
                        //    sourceType, true, unordered).
                        const value = getValueFromBuffer(
                            agent,
                            source_buffer,
                            source_byte_index,
                            @"type",
                            true,
                            .unordered,
                            null,
                        );
                        break :value if (@"type".isBigIntElementType())
                            Value.from(try BigInt.fromValue(agent, value))
                        else
                            Value.from(value);
                    },
                };

                switch (target_type) {
                    inline else => |@"type"| {
                        // ii. Perform SetValueInBuffer(targetBuffer, targetByteIndex, targetType,
                        //     value, true, unordered).
                        try setValueInBuffer(
                            agent,
                            target_buffer,
                            target_byte_index,
                            @"type",
                            value,
                            true,
                            .unordered,
                            null,
                        );
                    },
                }

                // iii. Set sourceByteIndex to sourceByteIndex + sourceElementSize.
                // iv. Set targetByteIndex to targetByteIndex + targetElementSize.
            }
        }

        // 23. Return unused.
    }

    /// 23.2.3.27 %TypedArray%.prototype.slice ( start, end )
    /// https://tc39.es/ecma262/#sec-%typedarray%.prototype.slice
    fn slice(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const start = arguments.get(0);
        const end = arguments.get(1);

        // 1. Let obj be the this value.
        // 2. Let taRecord be ? ValidateTypedArray(obj, seq-cst).
        var ta_record = try validateTypedArray(agent, this_value, .seq_cst);
        const typed_array = ta_record.object;

        // 3. Let sourceArrayLength be TypedArrayLength(taRecord).
        const source_array_length = @backingInt(typedArrayLength(ta_record));

        // 4. Let startIndex be ? ToClampedIndex(start, sourceArrayLength).
        const start_index = try start.toClampedIndex(agent, source_array_length);

        // 5. If end is undefined, let endIndex be sourceArrayLength; else let endIndex be
        //    ? ToClampedIndex(end, sourceArrayLength).
        var end_index = if (end.isUndefined())
            source_array_length
        else
            try end.toClampedIndex(agent, source_array_length);

        // 6. Let countBytes be max(endIndex - startIndex, 0).
        var count_bytes = end_index -| start_index;

        // 7. Let resultArray be ? TypedArraySpeciesCreate(obj, « 𝔽(countBytes) »).
        const result_array = try typedArraySpeciesCreate(
            agent,
            typed_array,
            &.{Value.from(count_bytes)},
        );

        // 8. If countBytes > 0, then
        if (count_bytes > 0) {
            // a. Set taRecord to ? ValidateTypedArrayBounds(obj, seq-cst).
            ta_record = try validateTypedArrayBounds(agent, typed_array, .seq_cst);

            // b. Set endIndex to min(endIndex, TypedArrayLength(taRecord)).
            end_index = @min(end_index, @backingInt(typedArrayLength(ta_record)));

            // c. Set countBytes to max(endIndex - startIndex, 0).
            count_bytes = end_index -| start_index;

            // d. Let sourceType be TypedArrayElementType(obj).
            const source_type = typed_array.fields.element_type;

            // e. Let targetType be TypedArrayElementType(resultArray).
            const target_type = result_array.fields.element_type;

            // f. If sourceType is targetType, then
            if (source_type == target_type) {
                // i. NOTE: The transfer must be performed in a manner that preserves the bit-level
                //    encoding of the source data.

                // ii. Let sourceBuffer be obj.[[ViewedArrayBuffer]].
                const source_buffer = typed_array.fields.viewed_array_buffer;

                // iii. Let targetBuffer be resultArray.[[ViewedArrayBuffer]].
                const target_buffer = result_array.fields.viewed_array_buffer;

                // iv. Let elementSize be TypedArrayElementSize(obj).
                const element_size = typedArrayElementSize(typed_array);

                // v. Let sourceByteOffset be obj.[[ByteOffset]].
                const source_byte_offset = typed_array.fields.byte_offset;

                // vi. Let sourceByteIndex be (startIndex × elementSize) + sourceByteOffset.
                var source_byte_index = (start_index * element_size) + @backingInt(source_byte_offset);

                // vii. Let targetByteIndex be resultArray.[[ByteOffset]].
                var target_byte_index = @backingInt(result_array.fields.byte_offset);

                // viii. Let endByteIndex be targetByteIndex + (countBytes × elementSize).
                const end_byte_index = target_byte_index + (count_bytes * element_size);

                // ix. Repeat, while targetByteIndex < endByteIndex,
                while (target_byte_index < end_byte_index) : ({
                    source_byte_index += 1;
                    target_byte_index += 1;
                }) {
                    // 1. Let value be GetValueFromBuffer(sourceBuffer, sourceByteIndex, uint8,
                    //    true, unordered).
                    const value = getValueFromBuffer(
                        agent,
                        source_buffer,
                        source_byte_index,
                        .uint8,
                        true,
                        .unordered,
                        null,
                    );

                    // 2. Perform SetValueInBuffer(targetBuffer, targetByteIndex, uint8, value,
                    //    true, unordered).
                    try setValueInBuffer(
                        agent,
                        target_buffer,
                        target_byte_index,
                        .uint8,
                        Value.from(value),
                        true,
                        .unordered,
                        null,
                    );

                    // 3. Set sourceByteIndex to sourceByteIndex + 1.
                    // 4. Set targetByteIndex to targetByteIndex + 1.
                }
            } else {
                // g. Else,
                // i. Let n be 0.
                var n: u53 = 0;

                // ii. Let k be startIndex.
                var k: u53 = start_index;

                // iii. Repeat, while k < endIndex,
                while (k < end_index) : ({
                    k += 1;
                    n += 1;
                }) {
                    // 1. Let kValue be TypedArrayGetElement(obj, 𝔽(k)).
                    const k_value = try typedArrayGetElement(
                        agent,
                        typed_array,
                        .{ .integer_index = k },
                    );

                    // 2. Perform ! TypedArraySetElement(resultArray, 𝔽(n), kValue).
                    typedArraySetElement(
                        agent,
                        result_array,
                        .{ .integer_index = n },
                        k_value,
                    ) catch |err| try noexcept(err);

                    // 3. Set k to k + 1.
                    // 4. Set n to n + 1.
                }
            }
        }

        // 9. Return resultArray.
        return Value.from(&result_array.object);
    }

    /// 23.2.3.28 %TypedArray%.prototype.some ( callback [ , thisArg ] )
    /// https://tc39.es/ecma262/#sec-%typedarray%.prototype.some
    fn some(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const callback_value = arguments.get(0);
        const this_arg = arguments.get(1);

        // 1. Let obj be the this value.
        // 2. Let taRecord be ? ValidateTypedArray(obj, seq-cst).
        const ta_record = try validateTypedArray(agent, this_value, .seq_cst);
        const typed_array = ta_record.object;

        // 3. Let length be TypedArrayLength(taRecord).
        const length_ = typedArrayLength(ta_record);

        // 4. If IsCallable(callback) is false, throw a TypeError exception.
        if (!callback_value.isCallable()) {
            return agent.throwException(.type_error, "{f} is not callable", .{callback_value});
        }
        const callback = callback_value.asObject();

        // 5. Let k be 0.
        var k: u53 = 0;

        // 6. Repeat, while k < length,
        while (k < @backingInt(length_)) : (k += 1) {
            // a. Let kValue be TypedArrayGetElement(obj, 𝔽(k)).
            const k_value = try typedArrayGetElement(agent, typed_array, .{ .integer_index = k });

            // b. Let testResult be ToBoolean(? Call(callback, thisArg, « kValue, 𝔽(k), obj »)).
            const test_result = (try callback.call(
                agent,
                this_arg,
                &.{ k_value, Value.from(k), Value.from(&typed_array.object) },
            )).toBoolean();

            // c. If testResult is true, return true.
            if (test_result) return .true;

            // d. Set k to k + 1.
        }

        // 7. Return false.
        return .false;
    }

    /// 23.2.3.29 %TypedArray%.prototype.sort ( comparator )
    /// https://tc39.es/ecma262/#sec-%typedarray%.prototype.sort
    fn sort(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const comparator = arguments.get(0);

        // 1. If comparator is not undefined and IsCallable(comparator) is false, throw a TypeError
        //    exception.
        if (!comparator.isUndefined() and !comparator.isCallable()) {
            return agent.throwException(.type_error, "{f} is not callable", .{comparator});
        }

        // 2. Let obj be the this value.
        // 3. Let taRecord be ? ValidateTypedArray(obj, seq-cst).
        const ta_record = try validateTypedArray(agent, this_value, .seq_cst);
        const typed_array = ta_record.object;

        // 4. Let length be TypedArrayLength(taRecord).
        const length_ = typedArrayLength(ta_record);

        // 5. NOTE: The following closure performs a numeric comparison rather than the string
        //    comparison used in 23.1.3.30.
        // 6. Let sortCompare be a new Abstract Closure with parameters (x, y) that captures
        //    comparator and performs the following steps when called:
        const sortCompare = struct {
            fn func(agent_: *Agent, x: Value, y: Value, comparator_: ?*Object) Agent.Error!std.math.Order {
                // a. Return ? CompareTypedArrayElements(x, y, comparator).
                return compareTypedArrayElements(agent_, x, y, comparator_);
            }
        }.func;

        // 7. Let sortedList be ? SortIndexedProperties(obj, length, sortCompare,
        //    read-through-holes).
        const sorted_list = try sortIndexedProperties(
            agent,
            &typed_array.object,
            @backingInt(length_),
            .{
                .impl = sortCompare,
                .comparator = if (!comparator.isUndefined()) comparator.asObject() else null,
            },
            .read_through_holes,
        );
        std.debug.assert(sorted_list.len == @backingInt(length_));

        // 8. Let j be 0.
        // 9. Repeat, while j < length,
        for (sorted_list, 0..) |value, j| {
            // a. Perform ! TypedArraySetElement(obj, 𝔽(j), sortedList[j]).
            typedArraySetElement(
                agent,
                typed_array,
                .{ .integer_index = @intCast(j) },
                value,
            ) catch |err| try noexcept(err);

            // b. Set j to j + 1.
        }

        // 10. Return obj.
        return Value.from(&typed_array.object);
    }

    /// 23.2.3.30 %TypedArray%.prototype.subarray ( start, end )
    /// https://tc39.es/ecma262/#sec-%typedarray%.prototype.subarray
    fn subarray(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const start = arguments.get(0);
        const end = arguments.get(1);

        // 1. Let obj be the this value.
        // 2. Perform ? RequireInternalSlot(obj, [[TypedArrayName]]).
        // 3. Assert: obj has a [[ViewedArrayBuffer]] internal slot.
        const typed_array = try this_value.requireInternalSlot(agent, TypedArray);

        // 4. Let buffer be obj.[[ViewedArrayBuffer]].
        const buffer_ = typed_array.fields.viewed_array_buffer;

        // 5. Let sourceRecord be MakeTypedArrayWithBufferWitnessRecord(obj, seq-cst).
        const source_record = makeTypedArrayWithBufferWitnessRecord(typed_array, .seq_cst);

        // 6. If IsTypedArrayOutOfBounds(sourceRecord) is true, then
        const source_length: u53 = if (isTypedArrayOutOfBounds(source_record)) blk: {
            // a. Let sourceLength be 0.
            break :blk 0;
        } else blk: {
            // 7. Else,
            // a. Let sourceLength be TypedArrayLength(sourceRecord).
            break :blk @backingInt(typedArrayLength(source_record));
        };

        // 8. Let startIndex be ? ToClampedIndex(start, sourceLength).
        const start_index = try start.toClampedIndex(agent, source_length);

        // 9. Let elementSize be TypedArrayElementSize(obj).
        const element_size = typedArrayElementSize(typed_array);

        // 10. Let sourceByteOffset be obj.[[ByteOffset]].
        const source_byte_offset = typed_array.fields.byte_offset;

        // 11. Let beginByteOffset be sourceByteOffset + (startIndex × elementSize).
        const begin_byte_offset = @backingInt(source_byte_offset) + (start_index * element_size);

        // 12. If obj.[[ArrayLength]] is auto and end is undefined, then
        if (typed_array.fields.array_length == .auto and end.isUndefined()) {
            // a. Return ? TypedArraySpeciesCreate(obj, « buffer, 𝔽(beginByteOffset) »).
            const new_typed_array = try typedArraySpeciesCreate(agent, typed_array, &.{
                Value.from(&buffer_.object),
                Value.from(begin_byte_offset),
            });
            return Value.from(&new_typed_array.object);
        }

        // 13. If end is undefined, let endIndex be sourceLength; else let endIndex be
        //     ? ToClampedIndex(end, sourceLength).
        const end_index = if (end.isUndefined())
            source_length
        else
            try end.toClampedIndex(agent, source_length);

        // 14. Let newLength be max(endIndex - startIndex, 0).
        const new_length = end_index -| start_index;

        // 15. Return ? TypedArraySpeciesCreate(obj, « buffer, 𝔽(beginByteOffset), 𝔽(newLength) »).
        const new_typed_array = try typedArraySpeciesCreate(agent, typed_array, &.{
            Value.from(&buffer_.object),
            Value.from(begin_byte_offset),
            Value.from(new_length),
        });
        return Value.from(&new_typed_array.object);
    }

    /// 23.2.3.31 %TypedArray%.prototype.toLocaleString ( [ reserved1 [ , reserved2 ] ] )
    /// https://tc39.es/ecma262/#sec-%typedarray%.prototype.tolocalestring
    fn toLocaleString(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let array be ? ToObject(this value).
        const ta_record = try validateTypedArray(agent, this_value, .seq_cst);
        const array = this_value.asObject();

        // 2. Let length be ? LengthOfArrayLike(array).
        const length_ = typedArrayLength(ta_record);

        // OPTIMIZATION: If the array is empty the result will be an empty string
        if (length_ == .zero) return Value.from(String.empty);

        // 3. Let separator be the implementation-defined list-separator String value appropriate
        //    for the host environment's current locale (such as ", ").
        const separator = String.fromLiteral(", ");

        // 4. Let result be the empty String.
        // NOTE: This allocates the maximum needed capacity upfront
        const capacity = std.math.cast(u32, @as(u64, @backingInt(length_)) * 2 - 1) orelse
            return error.OutOfMemory;
        var result = try String.Builder.initCapacity(agent.gc_allocator, capacity);
        defer result.deinit(agent.gc_allocator);

        // 5. Let k be 0.
        var k: u53 = 0;

        // 6. Repeat, while k < length,
        while (k < @backingInt(length_)) : (k += 1) {
            // a. If k > 0, set R to the string-concatenation of R and separator.
            if (k > 0) result.appendStringAssumeCapacity(separator);

            // b. Let element be ? Get(array, ! ToString(𝔽(k))).
            const element = array.get(agent, PropertyKey.from(k)) catch |err| try noexcept(err);

            // c. If element is neither undefined nor null, then
            if (!element.isUndefined() and !element.isNull()) {
                // i. Let elementString be ? ToString(? Invoke(element, "toLocaleString")).
                const string = try (try element.invoke(
                    agent,
                    PropertyKey.from("toLocaleString"),
                    &.{},
                )).toString(agent);

                // ii. Set result to the string-concatenation of result and elementString.
                result.appendStringAssumeCapacity(string);
            }

            // d. Set k to k + 1.
        }

        // 7. Return result.
        return Value.from(try result.build(agent));
    }

    /// 23.2.3.32 %TypedArray%.prototype.toReversed ( )
    /// https://tc39.es/ecma262/#sec-%typedarray%.prototype.toreversed
    fn toReversed(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let obj be the this value.
        // 2. Let taRecord be ? ValidateTypedArray(obj, seq-cst).
        const ta_record = try validateTypedArray(agent, this_value, .seq_cst);
        const typed_array = ta_record.object;

        // 3. Let length be TypedArrayLength(taRecord).
        const length_ = typedArrayLength(ta_record);

        // 4. Let resultArray be ? TypedArrayCreateSameType(obj, length).
        const result_array = try typedArrayCreateSameType(agent, typed_array, length_);

        // 5. Let k be 0.
        var k: u53 = 0;

        // 6. Repeat, while k < length,
        while (k < @backingInt(length_)) : (k += 1) {
            // a. Let from be length - k - 1.
            const from = @backingInt(length_) - k - 1;

            // b. Let fromValue be TypedArrayGetElement(obj, 𝔽(from)).
            const from_value = try typedArrayGetElement(
                agent,
                typed_array,
                .{ .integer_index = from },
            );

            // c. Perform ! TypedArraySetElement(resultArray, 𝔽(k), fromValue).
            typedArraySetElement(
                agent,
                result_array,
                .{ .integer_index = k },
                from_value,
            ) catch |err| try noexcept(err);

            // d. Set k to k + 1.
        }

        // 7. Return resultArray.
        return Value.from(&result_array.object);
    }

    /// 23.2.3.33 %TypedArray%.prototype.toSorted ( comparator )
    /// https://tc39.es/ecma262/#sec-%typedarray%.prototype.tosorted
    fn toSorted(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const comparator = arguments.get(0);

        // 1. If comparator is not undefined and IsCallable(comparator) is false, throw a TypeError
        //    exception.
        if (!comparator.isUndefined() and !comparator.isCallable()) {
            return agent.throwException(.type_error, "{f} is not callable", .{comparator});
        }

        // 2. Let obj be the this value.
        // 3. Let taRecord be ? ValidateTypedArray(obj, seq-cst).
        const ta_record = try validateTypedArray(agent, this_value, .seq_cst);
        const typed_array = ta_record.object;

        // 4. Let length be TypedArrayLength(taRecord).
        const length_ = typedArrayLength(ta_record);

        // 5. Let resultArray be ? TypedArrayCreateSameType(obj, length).
        const result_array = try typedArrayCreateSameType(agent, typed_array, length_);

        // 6. NOTE: The following closure performs a numeric comparison rather than the string
        //    comparison used in 23.1.3.34.
        // 7. Let sortCompare be a new Abstract Closure with parameters (x, y) that captures
        //    comparator and performs the following steps when called:
        const sortCompare = struct {
            fn func(agent_: *Agent, x: Value, y: Value, comparator_: ?*Object) Agent.Error!std.math.Order {
                // a. Return ? CompareTypedArrayElements(x, y, comparator).
                return compareTypedArrayElements(agent_, x, y, comparator_);
            }
        }.func;

        // 8. Let sortedList be ? SortIndexedProperties(obj, length, sortCompare,
        //    read-through-holes).
        const sorted_list = try sortIndexedProperties(
            agent,
            &typed_array.object,
            @backingInt(length_),
            .{
                .impl = sortCompare,
                .comparator = if (!comparator.isUndefined()) comparator.asObject() else null,
            },
            .read_through_holes,
        );
        std.debug.assert(sorted_list.len == @backingInt(length_));

        // 9. Let j be 0.
        // 10. Repeat, while j < length,
        for (sorted_list, 0..) |value, j| {
            // a. Perform ! TypedArraySetElement(resultArray, 𝔽(j), sortedList[j]).
            typedArraySetElement(
                agent,
                result_array,
                .{ .integer_index = @intCast(j) },
                value,
            ) catch |err| try noexcept(err);

            // b. Set j to j + 1.
        }

        // 11. Return resultArray.
        return Value.from(&result_array.object);
    }

    /// 23.2.3.35 %TypedArray%.prototype.values ( )
    /// https://tc39.es/ecma262/#sec-%typedarray%.prototype.values
    fn values(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let obj be the this value.
        // 2. Perform ? ValidateTypedArray(obj, seq-cst).
        const ta_record = try validateTypedArray(agent, this_value, .seq_cst);
        const typed_array = ta_record.object;

        // 3. Return CreateArrayIterator(obj, value).
        const array_iterator = try createArrayIterator(agent, &typed_array.object, .value);
        return Value.from(&array_iterator.object);
    }

    /// 23.2.3.36 %TypedArray%.prototype.with ( index, value )
    /// https://tc39.es/ecma262/#sec-%typedarray%.prototype.with
    fn with(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const index = arguments.get(0);
        const value = arguments.get(1);

        // 1. Let obj be the this value.
        // 2. Let taRecord be ? ValidateTypedArray(obj, seq-cst).
        const ta_record = try validateTypedArray(agent, this_value, .seq_cst);
        const typed_array = ta_record.object;

        // 3. Let length be TypedArrayLength(taRecord).
        const length_ = typedArrayLength(ta_record);

        // 4. Let actualIndex be ? ToAbsoluteIndex(index, length).
        const actual_index_f64 = try index.toAbsoluteIndex(agent, @backingInt(length_));

        // 5. If obj.[[ContentType]] is bigint, let numericValue be ? ToBigInt(value).
        // 6. Else, let numericValue be ? ToNumber(value).
        const numeric_value = if (typed_array.fields.content_type == .bigint)
            Value.from(try value.toBigInt(agent))
        else
            Value.from(try value.toNumber(agent));

        // 7. If IsValidIntegerIndex(obj, 𝔽(actualIndex)) is false, throw a RangeError exception.
        if (actual_index_f64 < 0 or
            actual_index_f64 > std.math.maxInt(PropertyKey.IntegerIndex) or
            !isValidIntegerIndex(typed_array, .{ .integer_index = @intFromFloat(actual_index_f64) }))
        {
            return agent.throwException(
                .range_error,
                "Invalid index {d} for typed array of length {d}",
                .{ actual_index_f64, length_ },
            );
        }
        const actual_index: u53 = @intFromFloat(actual_index_f64);

        // 8. Let resultArray be ? TypedArrayCreateSameType(obj, length).
        const result_array = try typedArrayCreateSameType(agent, typed_array, length_);

        // 9. Let k be 0.
        var k: u53 = 0;

        // 10. Repeat, while k < length,
        while (k < @backingInt(length_)) : (k += 1) {
            // a. If k = actualIndex, let fromValue be numericValue.
            // b. Else, let fromValue be TypedArrayGetElement(obj, 𝔽(k)).
            const from_value = if (k == actual_index)
                numeric_value
            else
                try typedArrayGetElement(agent, typed_array, .{ .integer_index = k });

            // c. Perform ! TypedArraySetElement(resultArray, 𝔽(k), fromValue).
            typedArraySetElement(
                agent,
                result_array,
                .{ .integer_index = k },
                from_value,
            ) catch |err| try noexcept(err);

            // d. Set k to k + 1.
        }

        // 11. Return resultArray.
        return Value.from(&result_array.object);
    }

    /// 23.2.3.38 get %TypedArray%.prototype [ %Symbol.toStringTag% ]
    /// https://tc39.es/ecma262/#sec-get-%typedarray%.prototype-%symbol.tostringtag%
    fn @"Symbol.toStringTag"(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let obj be the this value.
        // 2. If obj is not an Object, return undefined.
        // 3. If obj does not have a [[TypedArrayName]] internal slot, return undefined.
        const typed_array = this_value.castObject(TypedArray) orelse return .undefined;

        // 4. Let name be obj.[[TypedArrayName]].
        const name = typed_array.fields.element_type.typedArrayName();

        // 5. Assert: name is a String.
        // 6. Return name.
        return Value.from(try String.fromAscii(agent, name));
    }
};

/// 23.2.4.1 TypedArrayCreateFromConstructor ( ctor, argList )
/// https://tc39.es/ecma262/#sec-typedarraycreatefromconstructor
fn typedArrayCreateFromConstructor(
    agent: *Agent,
    ctor: *Object,
    arg_list: []const Value,
) Agent.Error!*TypedArray {
    // 1. Let ta be ? Construct(ctor, argList).
    const typed_array_obj = try ctor.construct(agent, arg_list, null);

    // 2. Let taRecord be ? ValidateTypedArray(ta, seq-cst).
    const ta_record = try validateTypedArray(agent, Value.from(typed_array_obj), .seq_cst);

    // 3. Assert: ta has all the internal slots mentioned in Properties of TypedArray Instances.
    const typed_array = ta_record.object;

    // 4. If the number of elements in argList is 1 and argList[0] is a Number, then
    if (arg_list.len == 1 and arg_list[0].isNumber()) {
        // a. If IsTypedArrayOutOfBounds(taRecord) is true, throw a TypeError exception.
        if (isTypedArrayOutOfBounds(ta_record)) {
            return agent.throwException(.type_error, "Typed array is out of bounds", .{});
        }

        // b. Let length be TypedArrayLength(taRecord).
        const length = typedArrayLength(ta_record);

        // c. If length < ℝ(argList[0]), throw a TypeError exception.
        if (@as(f64, @floatFromInt(@backingInt(length))) < arg_list[0].asNumber().asFloat()) {
            return agent.throwException(
                .type_error,
                "Typed array must have at least length {d}, got {d}",
                .{ arg_list[0].asNumber().asFloat(), length },
            );
        }
    }

    // 5. Return ta.
    return typed_array;
}

/// 23.2.4.2 TypedArrayCreateSameType ( exemplar, length )
/// https://tc39.es/ecma262/#sec-typedarray-create-same-type
fn typedArrayCreateSameType(
    agent: *Agent,
    exemplar: *const TypedArray,
    length: ArrayLength,
) Agent.Error!*TypedArray {
    const realm = agent.currentRealm();

    // 1. Let ctor be the intrinsic object associated with the constructor name
    //    exemplar.[[TypedArrayName]] in Table 71.
    const ctor = switch (exemplar.fields.element_type) {
        inline else => |element_type| try realm.intrinsic(element_type.constructorIntrinsic()),
    };

    // 2. Let result be ? TypedArrayCreateFromConstructor(ctor, « 𝔽(length) »).
    const result_array = try typedArrayCreateFromConstructor(
        agent,
        ctor,
        &.{Value.from(@backingInt(length))},
    );

    // 3. Assert: result has [[TypedArrayName]] and [[ContentType]] internal slots.
    // 4. Assert: result.[[ContentType]] is exemplar.[[ContentType]].
    std.debug.assert(result_array.fields.content_type == exemplar.fields.content_type);

    // 5. Return result.
    return result_array;
}

/// 23.2.4.3 TypedArraySpeciesCreate ( exemplar, argList )
/// https://tc39.es/ecma262/#typedarray-species-create
fn typedArraySpeciesCreate(
    agent: *Agent,
    exemplar: *const TypedArray,
    arg_list: []const Value,
) Agent.Error!*TypedArray {
    const realm = agent.currentRealm();

    // 1. Let defaultCtor be the intrinsic object associated with the constructor name
    //    exemplar.[[TypedArrayName]] in Table 71.
    const default_ctor = switch (exemplar.fields.element_type) {
        inline else => |element_type| try realm.intrinsic(element_type.constructorIntrinsic()),
    };

    // 2. Let ctor be ? SpeciesConstructor(exemplar, defaultCtor).
    const ctor = try @constCast(exemplar).object.speciesConstructor(
        agent,
        default_ctor,
    );

    // 3. Let result be ? TypedArrayCreateFromConstructor(ctor, argList).
    const result_array = try typedArrayCreateFromConstructor(agent, ctor, arg_list);

    // 4. If result.[[ContentType]] is not exemplar.[[ContentType]], throw a TypeError exception.
    if (result_array.fields.content_type != exemplar.fields.content_type) {
        return agent.throwException(
            .type_error,
            "Cannot convert between BigInt and Number typed arrays",
            .{},
        );
    }

    // 5. Return result.
    return result_array;
}

/// 23.2.4.4 ValidateTypedArray ( obj, order )
/// https://tc39.es/ecma262/#sec-validatetypedarray
pub fn validateTypedArray(
    agent: *Agent,
    typed_array_value: Value,
    order: Order,
) error{ExceptionThrown}!TypedArrayWithBufferWitness {
    // 1. Perform ? RequireInternalSlot(obj, [[TypedArrayName]]).
    // 2. Assert: obj has a [[ViewedArrayBuffer]] internal slot.
    const typed_array = try typed_array_value.requireInternalSlot(agent, TypedArray);

    // 3. Return ? ValidateTypedArrayBounds(obj, order).
    return validateTypedArrayBounds(agent, typed_array, order);
}

/// 23.2.4.5 ValidateTypedArrayBounds ( ta, order )
/// https://tc39.es/ecma262/#sec-validatetypedarraybounds
pub fn validateTypedArrayBounds(
    agent: *Agent,
    typed_array: *const TypedArray,
    order: Order,
) error{ExceptionThrown}!TypedArrayWithBufferWitness {
    // 1. Let taRecord be MakeTypedArrayWithBufferWitnessRecord(ta, order).
    const ta_record = makeTypedArrayWithBufferWitnessRecord(@constCast(typed_array), order);

    // 2. If IsTypedArrayOutOfBounds(taRecord) is true, throw a TypeError exception.
    if (isTypedArrayOutOfBounds(ta_record)) {
        return agent.throwException(.type_error, "Typed array is out of bounds", .{});
    }

    // 3. Return taRecord.
    return ta_record;
}

/// 23.2.4.6 TypedArrayElementSize ( obj )
/// https://tc39.es/ecma262/#sec-typedarrayelementsize
pub fn typedArrayElementSize(typed_array: *const TypedArray) u4 {
    // 1. Return the Element Size value specified in Table 71 for obj.[[TypedArrayName]].
    return typed_array.fields.element_type.elementSize();
}

/// 23.2.4.8 CompareTypedArrayElements ( x, y, comparator )
/// https://tc39.es/ecma262/#sec-comparetypedarrayelements
pub fn compareTypedArrayElements(
    agent: *Agent,
    x: Value,
    y: Value,
    maybe_comparator: ?*Object,
) Agent.Error!std.math.Order {
    // 1. Assert: x is a Number and y is a Number, or x is a BigInt and y is a BigInt.
    std.debug.assert((x.isNumber() and y.isNumber()) or (x.isBigInt() and y.isBigInt()));

    // 2. If comparator is not undefined, then
    if (maybe_comparator) |comparator| {
        // a. Let result be ? ToNumber(? Call(comparator, undefined, « x, y »)).
        const result = try (try comparator.call(agent, .undefined, &.{ x, y })).toNumber(agent);

        // b. If result is NaN, return +0𝔽.
        if (result.isNan()) return .eq;

        // c. Return result.
        return if (result.isZero()) .eq else if (result.asFloat() < 0) .lt else .gt;
    }

    if (x.isNumber() and y.isNumber()) {
        // 3. If x is NaN and y is NaN, return +0𝔽.
        if (x.asNumber().isNan() and y.asNumber().isNan()) return .eq;

        // 4. If x is NaN, return 1𝔽.
        if (x.asNumber().isNan()) return .gt;

        // 5. If y is NaN, return -1𝔽.
        if (y.asNumber().isNan()) return .lt;

        // 6. If x < y, return -1𝔽.
        if (x.asNumber().lessThan(y.asNumber()).?) return .lt;

        // 7. If x > y, return 1𝔽.
        if (y.asNumber().lessThan(x.asNumber()).?) return .gt;

        // 8. If x is -0𝔽 and y is +0𝔽, return -1𝔽.
        if (x.asNumber().isNegativeZero() and y.asNumber().isPositiveZero()) return .lt;

        // 9. If x is +0𝔽 and y is -0𝔽, return 1𝔽.
        if (x.asNumber().isPositiveZero() and y.asNumber().isNegativeZero()) return .gt;
    } else {
        // 6-7.
        if (x.asBigInt().lessThan(y.asBigInt())) return .lt;
        if (y.asBigInt().lessThan(x.asBigInt())) return .gt;
    }

    // 10. Return +0𝔽.
    return .eq;
}

/// 23.2.5.1.1 AllocateTypedArray ( ctorName, newTarget, defaultProto [ , length ] )
/// https://tc39.es/ecma262/#sec-allocatetypedarray
pub fn allocateTypedArray(
    agent: *Agent,
    comptime element_type: ElementType,
    new_target: *Object,
    comptime default_proto: Realm.Intrinsic,
    maybe_length: OptionalArrayLength,
) Agent.Error!*TypedArray {
    // 1. Let proto be ? GetPrototypeFromConstructor(newTarget, defaultProto).
    const proto = try getPrototypeFromConstructor(agent, new_target, default_proto);

    // 2. Let obj be TypedArrayCreate(proto).
    // 3. Assert: obj.[[ViewedArrayBuffer]] is undefined.
    const typed_array = try TypedArray.create(agent, .{
        // 10.4.5.11 TypedArrayCreate ( proto )
        // https://tc39.es/ecma262/#sec-typedarraycreate
        // 1. Let internalSlotsList be « [[Prototype]], [[Extensible]], [[ViewedArrayBuffer]],
        //    [[TypedArrayName]], [[ContentType]], [[ByteLength]], [[ByteOffset]],
        //    [[ArrayLength]] ».
        // 2. Let ta be MakeBasicObject(internalSlotsList).
        .internal_methods = .initComptime(.{
            // 3. Set ta.[[PreventExtensions]] as specified in 10.4.5.1.
            .preventExtensions = preventExtensions,

            // 4. Set ta.[[GetOwnProperty]] as specified in 10.4.5.2.
            .getOwnProperty = getOwnProperty,

            // 5. Set ta.[[HasProperty]] as specified in 10.4.5.3.
            .hasProperty = hasProperty,

            // 6. Set ta.[[DefineOwnProperty]] as specified in 10.4.5.4.
            .defineOwnProperty = defineOwnProperty,

            // 7. Set ta.[[Get]] as specified in 10.4.5.5.
            .get = get,

            // 8. Set ta.[[Set]] as specified in 10.4.5.6.
            .set = set,

            // 9. Set ta.[[Delete]] as specified in 10.4.5.7.
            .delete = delete,

            // 10. Set ta.[[OwnPropertyKeys]] as specified in 10.4.5.8.
            .ownPropertyKeys = ownPropertyKeys,
        }),

        // 11. Set ta.[[Prototype]] to proto.
        .prototype = proto,

        // 12. Return ta.

        .fields = .{
            // NOTE: This is either set via allocateTypedArrayBuffer() below, or at the call site.
            .viewed_array_buffer = undefined,

            // 4. Set obj.[[TypedArrayName]] to ctorName.
            .element_type = element_type,

            // 5. If ctorName is either "BigInt64Array" or "BigUint64Array", set obj.[[ContentType]]
            //    to bigint.
            // 6. Else, set obj.[[ContentType]] to number.
            .content_type = switch (element_type) {
                .bigint64, .biguint64 => .bigint,
                else => .number,
            },

            // 7. If length is not present, then
            // NOTE: We do this unconditionally here and skip the branch below instead.

            // a. Set obj.[[ByteLength]] to 0.
            .byte_length = .zero,

            // b. Set obj.[[ByteOffset]] to 0.
            .byte_offset = .zero,

            // c. Set obj.[[ArrayLength]] to 0.
            .array_length = .zero,
        },
    });

    // 7. If length is not present, then
    // 8. Else,
    if (maybe_length.unwrap()) |length| {
        // a. Perform ? AllocateTypedArrayBuffer(obj, length).
        try allocateTypedArrayBuffer(agent, typed_array, length);
    }

    // 9. Return obj.
    return typed_array;
}

/// 23.2.5.1.2 InitializeTypedArrayFromTypedArray ( obj, sourceArray )
/// https://tc39.es/ecma262/#sec-initializetypedarrayfromtypedarray
fn initializeTypedArrayFromTypedArray(
    agent: *Agent,
    typed_array: *TypedArray,
    source_array: *const TypedArray,
) Agent.Error!void {
    const realm = agent.currentRealm();

    // 1. Let sourceData be sourceArray.[[ViewedArrayBuffer]].
    const source_data = source_array.fields.viewed_array_buffer;

    // 2. Let elementType be TypedArrayElementType(obj).
    const element_type = typed_array.fields.element_type;

    // 3. Let elementSize be TypedArrayElementSize(obj).
    const element_size = typedArrayElementSize(typed_array);

    // 4. Let sourceType be TypedArrayElementType(sourceArray).
    const source_type = source_array.fields.element_type;

    // 5. Let sourceElementSize be TypedArrayElementSize(sourceArray).
    const source_element_size = typedArrayElementSize(source_array);

    // 6. Let sourceByteOffset be sourceArray.[[ByteOffset]].
    const source_byte_offset = source_array.fields.byte_offset;

    // 7. Let sourceRecord be ? ValidateTypedArrayBounds(sourceArray, seq-cst).
    const source_record = try validateTypedArrayBounds(agent, source_array, .seq_cst);

    // 8. Let elementLength be TypedArrayLength(sourceRecord).
    const element_length = typedArrayLength(source_record);

    // 9. Let byteLength be elementSize × elementLength.
    const byte_length: ByteLength = @fromBackingInt(std.math.mul(u53, element_size, @backingInt(element_length)) catch {
        return agent.throwException(
            .range_error,
            "Invalid typed array length {d}",
            .{element_length},
        );
    });

    // 10. If elementType is sourceType, then
    const array_buffer = if (element_type == source_type) blk: {
        // a. Let data be ? CloneArrayBuffer(sourceData, sourceByteOffset, byteLength).
        break :blk try cloneArrayBuffer(
            agent,
            source_data,
            source_byte_offset,
            byte_length,
        );
    } else blk: {
        // 11. Else,
        // a. Let data be ? AllocateArrayBuffer(%ArrayBuffer%, byteLength).
        const array_buffer = try allocateArrayBuffer(
            agent,
            try realm.intrinsic(.array_buffer),
            byte_length,
            .none,
        );

        // b. If sourceArray.[[ContentType]] is not obj.[[ContentType]], throw a TypeError
        //    exception.
        if (source_array.fields.content_type != typed_array.fields.content_type) {
            return agent.throwException(
                .type_error,
                "Cannot convert between BigInt and Number typed arrays",
                .{},
            );
        }

        // c. Let sourceByteIndex be sourceByteOffset.
        var source_byte_index = @backingInt(source_byte_offset);

        // d. Let targetByteIndex be 0.
        var target_byte_index: u53 = 0;

        // e. Let count be elementLength.
        var count = @backingInt(element_length);

        // f. Repeat, while count > 0,
        while (count > 0) : (count -= 1) {
            const value = switch (source_type) {
                inline else => |@"type"| value: {
                    // i. Let value be GetValueFromBuffer(sourceData, sourceByteIndex, sourceType,
                    //    true, unordered).
                    const value = getValueFromBuffer(
                        agent,
                        source_data,
                        source_byte_index,
                        @"type",
                        true,
                        .unordered,
                        null,
                    );
                    break :value if (@"type".isBigIntElementType())
                        Value.from(try BigInt.fromValue(agent, value))
                    else
                        Value.from(value);
                },
            };

            switch (element_type) {
                inline else => |@"type"| {
                    // ii. Perform SetValueInBuffer(data, targetByteIndex, elementType, value, true,
                    //     unordered).
                    try setValueInBuffer(
                        agent,
                        array_buffer,
                        target_byte_index,
                        @"type",
                        value,
                        true,
                        .unordered,
                        null,
                    );
                },
            }

            // iii. Set sourceByteIndex to sourceByteIndex + sourceElementSize.
            source_byte_index += source_element_size;

            // iv. Set targetByteIndex to targetByteIndex + elementSize.
            target_byte_index += element_size;

            // v. Set count to count - 1.
        }

        break :blk array_buffer;
    };

    // 12. Set obj.[[ViewedArrayBuffer]] to data.
    typed_array.fields.viewed_array_buffer = array_buffer;

    // 13. Set obj.[[ByteLength]] to byteLength.
    typed_array.fields.byte_length = byte_length.toAuto();

    // 14. Set obj.[[ByteOffset]] to 0.
    typed_array.fields.byte_offset = .zero;

    // 15. Set obj.[[ArrayLength]] to elementLength.
    typed_array.fields.array_length = element_length.toAuto();

    // 16. Return unused.
}

/// 23.2.5.1.3 InitializeTypedArrayFromArrayBuffer ( obj, buffer, byteOffset, length )
/// https://tc39.es/ecma262/#sec-initializetypedarrayfromarraybuffer
fn initializeTypedArrayFromArrayBuffer(
    agent: *Agent,
    typed_array: *TypedArray,
    buffer: *builtins.ArrayBuffer,
    byte_offset: Value,
    length: Value,
) Agent.Error!void {
    // 1. Let elementSize be TypedArrayElementSize(obj).
    const element_size = typedArrayElementSize(typed_array);

    // 2. Let offset be ? ToIndex(byteOffset).
    const offset: ByteOffset = @fromBackingInt(try byte_offset.toIndex(agent));

    // 3. If offset modulo elementSize ≠ 0, throw a RangeError exception.
    if (@mod(@backingInt(offset), element_size) != 0) {
        return agent.throwException(
            .range_error,
            "Offset must be multiple of {d}, got {d}",
            .{ element_size, offset },
        );
    }

    // 4. Let bufferIsFixedLength be IsFixedLengthArrayBuffer(buffer).
    const buffer_is_fixed_length = isFixedLengthArrayBuffer(buffer);

    // 5. If length is not undefined, then
    //     a. Let newLength be ? ToIndex(length).
    const new_length: u53 = if (!length.isUndefined()) try length.toIndex(agent) else undefined;

    // 6. If IsDetachedBuffer(buffer) is true, throw a TypeError exception.
    if (isDetachedBuffer(buffer)) {
        return agent.throwException(.type_error, "ArrayBuffer is detached", .{});
    }

    // 7. Let bufferByteLength be ArrayBufferByteLength(buffer, seq-cst).
    const buffer_byte_length = arrayBufferByteLength(buffer, .seq_cst);

    // 8. If length is undefined and bufferIsFixedLength is false, then
    if (length.isUndefined() and !buffer_is_fixed_length) {
        // a. If offset > bufferByteLength, throw a RangeError exception.
        if (@backingInt(offset) > @backingInt(buffer_byte_length)) {
            return agent.throwException(
                .range_error,
                "Offset must not exceed buffer byte length {d}, got {d}",
                .{ buffer_byte_length, offset },
            );
        }

        // b. Set obj.[[ByteLength]] to auto.
        typed_array.fields.byte_length = .auto;

        // c. Set obj.[[ArrayLength]] to auto.
        typed_array.fields.array_length = .auto;
    } else {
        // 9. Else,
        // a. If length is undefined, then
        const new_byte_length: ByteLength = if (length.isUndefined()) blk: {
            // i. If bufferByteLength modulo elementSize ≠ 0, throw a RangeError exception.
            if (@mod(@backingInt(buffer_byte_length), element_size) != 0) {
                return agent.throwException(
                    .range_error,
                    "Buffer byte length must be multiple of {d}, got {d}",
                    .{ element_size, buffer_byte_length },
                );
            }

            // ii. Let newByteLength be bufferByteLength - offset.
            const new_byte_length = std.math.sub(
                u53,
                @backingInt(buffer_byte_length),
                @backingInt(offset),
            ) catch {
                // iii. If newByteLength < 0, throw a RangeError exception.
                return agent.throwException(
                    .range_error,
                    "Offset must not exceed buffer byte length {d}, got {d}",
                    .{ buffer_byte_length, offset },
                );
            };

            break :blk @fromBackingInt(new_byte_length);
        } else blk: {
            // b. Else,
            // i. Let newByteLength be newLength × elementSize.
            const new_byte_length = std.math.mul(u53, new_length, element_size) catch {
                return agent.throwException(
                    .range_error,
                    "Invalid typed array length {d}",
                    .{new_length},
                );
            };

            // ii. If offset + newByteLength > bufferByteLength, throw a RangeError exception.
            if (if (std.math.add(u53, @backingInt(offset), new_byte_length)) |x|
                x > @backingInt(buffer_byte_length)
            else |_|
                true)
            {
                return agent.throwException(
                    .range_error,
                    "Offset {d} and byte length {d} are out of range for buffer byte length {d}",
                    .{ offset, new_byte_length, buffer_byte_length },
                );
            }

            break :blk @fromBackingInt(new_byte_length);
        };

        // c. Set obj.[[ByteLength]] to newByteLength.
        typed_array.fields.byte_length = new_byte_length.toAuto();

        // d. Set obj.[[ArrayLength]] to newByteLength / elementSize.
        typed_array.fields.array_length = @fromBackingInt(@divExact(@backingInt(new_byte_length), element_size));
    }

    // 10. Set obj.[[ViewedArrayBuffer]] to buffer.
    typed_array.fields.viewed_array_buffer = buffer;

    // 11. Set obj.[[ByteOffset]] to offset.
    typed_array.fields.byte_offset = offset;

    // 12. Return unused.
}

/// 23.2.5.1.4 InitializeTypedArrayFromList ( obj, values )
/// https://tc39.es/ecma262/#sec-initializetypedarrayfromlist
fn initializeTypedArrayFromList(
    agent: *Agent,
    typed_array: *TypedArray,
    values: []const Value,
) Agent.Error!void {
    // 1. Let length be the number of elements in values.
    // NOTE: allocateTypedArrayBuffer() will throw a nice error if this is too large, so truncating is fine
    const length: ArrayLength = @fromBackingInt(@intCast(values.len));

    // 2. Perform ? AllocateTypedArrayBuffer(obj, length).
    try allocateTypedArrayBuffer(agent, typed_array, length);

    // 3. Let k be 0.
    // 4. Repeat, while k < length,
    for (values, 0..) |k_value, k| {
        // a. Let kValue be values[k].

        // b. Perform ? TypedArraySetElement(obj, 𝔽(k), kValue).
        try typedArraySetElement(
            agent,
            typed_array,
            .{ .integer_index = @intCast(k) },
            k_value,
        );

        // c. Set k to k + 1.
    }

    // 5. Return unused.
}

/// 23.2.5.1.5 InitializeTypedArrayFromArrayLike ( obj, arrayLike )
/// https://tc39.es/ecma262/#sec-initializetypedarrayfromarraylike
fn initializeTypedArrayFromArrayLike(
    agent: *Agent,
    typed_array: *TypedArray,
    array_like: *Object,
) Agent.Error!void {
    // 1. Let length be ? LengthOfArrayLike(arrayLike).
    const length: ArrayLength = @fromBackingInt(try array_like.lengthOfArrayLike(agent));

    // 2. Perform ? AllocateTypedArrayBuffer(obj, length).
    try allocateTypedArrayBuffer(agent, typed_array, length);

    // 3. Let k be 0.
    var k: u53 = 0;

    // 4. Repeat, while k < length,
    while (k < @backingInt(length)) : (k += 1) {
        // a. Let propertyKey be ! ToString(𝔽(k)).
        const property_key = PropertyKey.from(k);

        // b. Let kValue be ? Get(arrayLike, propertyKey).
        const k_value = try array_like.get(agent, property_key);

        // c. Perform ? TypedArraySetElement(obj, 𝔽(k), kValue).
        try typedArraySetElement(agent, typed_array, .{ .integer_index = k }, k_value);

        // d. Set k to k + 1.
    }

    // 5. Return unused.
}

/// 23.2.5.1.6 AllocateTypedArrayBuffer ( obj, length )
/// https://tc39.es/ecma262/#sec-allocatetypedarraybuffer
fn allocateTypedArrayBuffer(
    agent: *Agent,
    typed_array: *TypedArray,
    length: ArrayLength,
) Agent.Error!void {
    const realm = agent.currentRealm();

    // 1. Assert: obj.[[ViewedArrayBuffer]] is undefined.

    // 2. Let elementSize be TypedArrayElementSize(obj).
    const element_size = typedArrayElementSize(typed_array);

    // 3. Let byteLength be elementSize × length.
    const byte_length: ByteLength = @fromBackingInt(std.math.mul(u53, element_size, @backingInt(length)) catch {
        return agent.throwException(
            .range_error,
            "Invalid typed array length {d}",
            .{length},
        );
    });

    // 4. Let data be ? AllocateArrayBuffer(%ArrayBuffer%, byteLength).
    const array_buffer = try allocateArrayBuffer(
        agent,
        try realm.intrinsic(.array_buffer),
        byte_length,
        .none,
    );

    // 5. Set obj.[[ViewedArrayBuffer]] to data.
    typed_array.fields.viewed_array_buffer = array_buffer;

    // 6. Set obj.[[ByteLength]] to byteLength.
    typed_array.fields.byte_length = byte_length.toAuto();

    // 7. Set obj.[[ByteOffset]] to 0.
    typed_array.fields.byte_offset = .zero;

    // 8. Set obj.[[ArrayLength]] to length.
    typed_array.fields.array_length = length.toAuto();

    // 9. Return unused.
}

/// 23.3.3.1 ValidateUint8Array ( ta )
/// https://tc39.es/ecma262/#sec-validateuint8array
pub fn validateUint8Array(agent: *Agent, value: Value) error{ExceptionThrown}!*TypedArray {
    // 1. Perform ? RequireInternalSlot(ta, [[TypedArrayName]]).
    const typed_array = try value.requireInternalSlot(agent, TypedArray);

    // 2. If ta.[[TypedArrayName]] is not "Uint8Array", throw a TypeError exception.
    if (typed_array.fields.element_type != .uint8) {
        return agent.throwException(.type_error, "Typed array is not a Uint8Array", .{});
    }

    // 3. Return unused.
    return typed_array;
}

/// 23.3.3.2 GetUint8ArrayBytes ( ta )
/// https://tc39.es/ecma262/#sec-getuint8arraybytes
pub fn getUint8ArrayBytes(agent: *Agent, typed_array: *const TypedArray) Agent.Error![]const u8 {
    std.debug.assert(typed_array.fields.element_type == .uint8);

    // 1. Let buffer be ta.[[ViewedArrayBuffer]].
    const buffer = typed_array.fields.viewed_array_buffer;

    // 2. Let taRecord be ? ValidateTypedArrayBounds(ta, seq-cst).
    const ta_record = try validateTypedArrayBounds(agent, typed_array, .seq_cst);

    // 3. Let length be TypedArrayLength(taRecord).
    const length = typedArrayLength(ta_record);

    // 4. Let byteOffset be ta.[[ByteOffset]].
    const byte_offset = typed_array.fields.byte_offset;

    // 5. Let bytes be a new empty List.
    // 6. Let index be 0.
    // 7. Repeat, while index < length,
    //     a. Let byteIndex be byteOffset + index.
    //     b. Let byte be ℝ(GetValueFromBuffer(buffer, byteIndex, uint8, true, unordered)).
    //     c. Append byte to bytes.
    //     d. Set index to index + 1.
    // 8. Return bytes.
    return buffer.fields.data_block.?.bytes[@intCast(@backingInt(byte_offset))..@intCast(@backingInt(byte_offset) + @backingInt(length))];
}

/// 23.3.3.3 SetUint8ArrayBytes ( into, bytes )
/// https://tc39.es/ecma262/#sec-setuint8arraybytes
fn setUint8ArrayBytes(agent: *Agent, into: *TypedArray, bytes: []const u8) void {
    std.debug.assert(into.fields.element_type == .uint8);

    // 1. Let offset be into.[[ByteOffset]].
    const offset = into.fields.byte_offset;

    // 2. Let length be the number of elements in bytes.
    // 3. Let index be 0.
    // 4. Repeat, while index < length,
    for (bytes, 0..) |byte, index| {
        // a. Let byte be bytes[index].
        // b. Let byteIndexInBuffer be index + offset.
        const byte_index_in_buffer = @as(u53, @intCast(index)) + @backingInt(offset);

        // c. Perform SetValueInBuffer(into.[[ViewedArrayBuffer]], byteIndexInBuffer, uint8,
        //    𝔽(byte), true, unordered).
        setValueInBuffer(
            agent,
            into.fields.viewed_array_buffer,
            byte_index_in_buffer,
            .uint8,
            Value.from(byte),
            true,
            .unordered,
            null,
        ) catch unreachable;

        // d. Set index to index + 1.
    }

    // 5. Return unused.
}

const Alphabet = enum {
    base64,
    base64url,
};

const LastChunkHandling = enum {
    loose,
    strict,
    stop_before_partial,
};

const FromBase64Result = struct {
    read: usize,
    bytes: []const u8,
    @"error": ?*builtins.SyntaxError,
};

/// 23.3.3.7 FromBase64 ( string, alphabet, lastChunkHandling [ , maxLength ] )
/// https://tc39.es/ecma262/#sec-frombase64
fn fromBase64Impl(
    agent: *Agent,
    string: *const String,
    alphabet: Alphabet,
    last_chunk_handling: LastChunkHandling,
    maybe_max_length: ?u53,
) std.mem.Allocator.Error!FromBase64Result {
    // 1. If maxLength is not present, then
    //     a. Set maxLength to 2**53 - 1.
    //     b. NOTE: Because the input is a String, the length of Strings is limited to 2**53 - 1
    //        characters, and the output requires no more bytes than the input has characters, this
    //        limit can never be reached. However, it is editorially convenient to use a finite
    //        value for maxLength.
    const max_length = maybe_max_length orelse std.math.maxInt(u53);

    // 2. NOTE: The order of validation and decoding in the algorithm below is not observable.
    //    Implementations are encouraged to perform them in whatever order is most efficient,
    //    possibly interleaving validation with decoding.

    // 3. If maxLength = 0, then
    if (max_length == 0) {
        // a. Return the Record { [[Read]]: 0, [[Bytes]]: « », [[Error]]: none }.
        return .{ .read = 0, .bytes = &.{}, .@"error" = null };
    }

    // 4-10.
    // NOTE: This doesn't pass all tests. std.base64 has an awful API so I didn't bother with
    //       supporting partial decoding.
    const source = switch (string.asAsciiOrUtf16()) {
        .ascii => |ascii| switch (last_chunk_handling) {
            .loose => if (std.mem.findScalar(u8, ascii, '=')) |end| blk: {
                for (ascii[end..]) |c| {
                    if (c != '=') {
                        const @"error" = try agent.createErrorObject(
                            .syntax_error,
                            "Invalid base64 string",
                            .{},
                        );
                        return .{ .read = 0, .bytes = &.{}, .@"error" = @"error" };
                    }
                }
                break :blk ascii[0..end];
            } else ascii,
            .strict => ascii,
            .stop_before_partial => ascii[0 .. ascii.len - (ascii.len % 4)],
        },
        .utf16 => {
            const @"error" = try agent.createErrorObject(
                .syntax_error,
                "Invalid base64 string",
                .{},
            );
            return .{ .read = 0, .bytes = &.{}, .@"error" = @"error" };
        },
    };
    // NOTE: For some reason urlSafeBase64DecoderWithIgnore() doesn't set the pad char so we do this manually.
    const decoder = std.base64.Base64DecoderWithIgnore.init(
        switch (alphabet) {
            .base64 => std.base64.standard_alphabet_chars,
            .base64url => std.base64.url_safe_alphabet_chars,
        },
        if (last_chunk_handling == .loose) null else '=',
        "\t\n\u{c}\r ",
    );
    const dest = try agent.gc_allocator.alloc(u8, decoder.calcSizeUpperBound(source.len));
    const dest_len = decoder.decode(dest, source) catch {
        const @"error" = try agent.createErrorObject(
            .syntax_error,
            "Invalid base64 string",
            .{},
        );
        return .{ .read = 0, .bytes = &.{}, .@"error" = @"error" };
    };
    // This is wrong when max_length is set, but `decode()` doesn't tell us the actual value.
    const read = source.len;
    const bytes = dest[0..@min(dest_len, max_length)];
    return .{ .read = read, .bytes = bytes, .@"error" = null };
}

const FromHexResult = struct {
    read: usize,
    bytes: []const u8,
    @"error": ?*builtins.SyntaxError,
};

/// 23.3.3.8 FromHex ( string [ , maxLength ] )
/// https://tc39.es/ecma262/#sec-fromhex
fn fromHexImpl(
    agent: *Agent,
    string: *const String,
    maybe_max_length: ?u53,
) std.mem.Allocator.Error!FromHexResult {
    // 1. If maxLength is not present, set maxLength to 2**53 - 1.
    const max_length = maybe_max_length orelse std.math.maxInt(u53);

    // 2. Let length be the length of string.
    const length = string.length;

    // 3. Let bytes be a new empty List.

    // 4. Let read be 0.
    var read: usize = 0;

    // 5. If length modulo 2 ≠ 0, then
    if (length % 2 != 0) {
        // a. Let error be a newly created SyntaxError object.
        const @"error" = try agent.createErrorObject(
            .syntax_error,
            "Invalid hex string, length must be a multiple of two",
            .{},
        );

        // b. Return the Record { [[Read]]: read, [[Bytes]]: bytes, [[Error]]: error }.
        return .{ .read = read, .bytes = &.{}, .@"error" = @"error" };
    }

    var bytes: std.ArrayList(u8) = try .initCapacity(agent.gc_allocator, length / 2);
    var it = string.codeUnitIterator();

    // 6. Repeat, while read < length and the number of elements in bytes < maxLength,
    while (read < length and bytes.items.len < max_length) {
        // a. Let hexits be the substring of string from read to read + 2.
        const hexits: [2]u8 = .{
            std.math.lossyCast(u8, it.next().?),
            std.math.lossyCast(u8, it.next().?),
        };

        // b. If hexits contains any code units which are not in "0123456789abcdefABCDEF", then
        if (!std.ascii.isHex(hexits[0]) or !std.ascii.isHex(hexits[1])) {
            // i. Let error be a newly created SyntaxError object.
            const @"error" = try agent.createErrorObject(
                .syntax_error,
                "Invalid hex string, characters must be hex digits",
                .{},
            );

            // ii. Return the Record { [[Read]]: read, [[Bytes]]: bytes, [[Error]]: error }.
            return .{
                .read = read,
                .bytes = try bytes.toOwnedSlice(agent.gc_allocator),
                .@"error" = @"error",
            };
        }

        // c. Set read to read + 2.
        read += 2;

        // d. Let byte be the integer value represented by hexits in base-16 notation, using the
        //    letters A through F and a through f for digits with values 10 through 15.
        const hi = std.fmt.charToDigit(hexits[0], 16) catch unreachable;
        const lo = std.fmt.charToDigit(hexits[1], 16) catch unreachable;
        const byte = (hi << 4) | lo;

        // e. Append byte to bytes.
        bytes.appendAssumeCapacity(byte);
    }

    // 7. Return the Record { [[Read]]: read, [[Bytes]]: bytes, [[Error]]: none }.
    return .{
        .read = read,
        .bytes = try bytes.toOwnedSlice(agent.gc_allocator),
        .@"error" = null,
    };
}

/// 23.2.6 Properties of the TypedArray Constructors
/// https://tc39.es/ecma262/#sec-properties-of-the-typedarray-constructors
fn MakeTypedArrayConstructor(comptime element_type: ElementType) type {
    const name = element_type.typedArrayName();
    const proto_intrinsic = element_type.prototypeIntrinsic();
    return struct {
        pub fn create(agent: *Agent, realm: *Realm) std.mem.Allocator.Error!*Object {
            const builtin_function = try createBuiltinFunction(
                agent,
                .{ .constructor = impl },
                3,
                name,
                .{ .realm = realm, .proto = try realm.intrinsic(.typed_array) },
            );
            return &builtin_function.object;
        }

        pub fn init(agent: *Agent, realm: *Realm, object: *Object) std.mem.Allocator.Error!void {
            // 23.2.6.1 TypedArray.BYTES_PER_ELEMENT
            // https://tc39.es/ecma262/#sec-typedarray.bytes_per_element
            try object.defineBuiltinPropertyWithAttributes(
                agent,
                "BYTES_PER_ELEMENT",
                Value.from(element_type.elementSize()),
                .none,
            );

            // 23.2.6.2 TypedArray.prototype
            // https://tc39.es/ecma262/#sec-typedarray.prototype
            try object.defineBuiltinPropertyWithAttributes(
                agent,
                "prototype",
                Value.from(try realm.intrinsic(proto_intrinsic)),
                .none,
            );

            if (element_type == .uint8) {
                try object.defineBuiltinFunction(agent, "fromBase64", fromBase64, 1, realm);
                try object.defineBuiltinFunction(agent, "fromHex", fromHex, 1, realm);
            }
        }

        /// 23.2.5.1 TypedArray ( ...args )
        /// https://tc39.es/ecma262/#sec-typedarray
        fn impl(agent: *Agent, arguments: Arguments, new_target: ?*Object) Agent.Error!Value {
            // 1. If NewTarget is undefined, throw a TypeError exception.
            if (new_target == null) {
                return agent.throwException(
                    .type_error,
                    name ++ " must be constructed with 'new'",
                    .{},
                );
            }

            // 2. Let ctorName be the String value of the Constructor Name value specified in Table
            //    71 for this TypedArray constructor.
            // 3. Let proto be `"%TypedArray.prototype%"`.

            // 4. Let numberOfArgs be the number of elements in args.
            const number_of_args = arguments.count();

            // 5. If numberOfArgs = 0, return ? AllocateTypedArray(ctorName, NewTarget, proto, 0).
            if (number_of_args == 0) {
                const typed_array = try allocateTypedArray(
                    agent,
                    element_type,
                    new_target.?,
                    proto_intrinsic,
                    @fromBackingInt(0),
                );
                return Value.from(&typed_array.object);
            }

            // 6. Let firstArg be args[0].
            const first_arg = arguments.get(0);

            // 7. If firstArg is an Object, then
            if (first_arg.isObject()) {
                // a. Let obj be ? AllocateTypedArray(ctorName, NewTarget, proto).
                const typed_array = try allocateTypedArray(
                    agent,
                    element_type,
                    new_target.?,
                    proto_intrinsic,
                    .none,
                );

                // b. If firstArg has a [[TypedArrayName]] internal slot, then
                if (first_arg.asObject().cast(TypedArray)) |first_arg_typed_array| {
                    // i. Perform ? InitializeTypedArrayFromTypedArray(obj, firstArg).
                    try initializeTypedArrayFromTypedArray(
                        agent,
                        typed_array,
                        first_arg_typed_array,
                    );
                }
                // c. Else if firstArg has an [[ArrayBufferData]] internal slot, then
                else if (first_arg.asObject().cast(builtins.ArrayBuffer)) |array_buffer| {
                    // i. If numberOfArgs > 1, let byteOffset be args[1]; else let byteOffset be
                    //    undefined.
                    const byte_offset = arguments.get(1);

                    // ii. If numberOfArgs > 2, let length be args[2]; else let length be undefined.
                    const length = arguments.get(2);

                    // iii. Perform ? InitializeTypedArrayFromArrayBuffer(obj, firstArg, byteOffset,
                    //      length).
                    try initializeTypedArrayFromArrayBuffer(
                        agent,
                        typed_array,
                        array_buffer,
                        byte_offset,
                        length,
                    );
                } else {
                    // d. Else,
                    // i. Assert: firstArg is an Object and firstArg does not have either a
                    //    [[TypedArrayName]] or an [[ArrayBufferData]] internal slot.
                    std.debug.assert(
                        first_arg.isObject() and
                            !first_arg.asObject().is(TypedArray) and
                            !first_arg.asObject().is(builtins.ArrayBuffer),
                    );

                    // ii. Let usingIterator be ? GetMethod(firstArg, %Symbol.iterator%).
                    const using_iterator = try first_arg.getMethod(
                        agent,
                        PropertyKey.from(agent.well_known_symbols.iterator),
                    );

                    // iii. If usingIterator is not undefined, then
                    if (using_iterator != null) {
                        // 1. Let values be ? IteratorToList(? GetIteratorFromMethod(firstArg,
                        //    usingIterator)).
                        var iterator = try getIteratorFromMethod(
                            agent,
                            first_arg,
                            using_iterator.?,
                        );
                        const values = try iterator.toList(agent);
                        defer agent.gc_allocator.free(values);

                        // 2. Perform ? InitializeTypedArrayFromList(obj, values).
                        try initializeTypedArrayFromList(agent, typed_array, values);
                    } else {
                        // iv. Else,
                        // 1. NOTE: firstArg is not an iterable object, so assume it is already an
                        //    array-like object.
                        // 2. Perform ? InitializeTypedArrayFromArrayLike(obj, firstArg).
                        try initializeTypedArrayFromArrayLike(
                            agent,
                            typed_array,
                            first_arg.asObject(),
                        );
                    }
                }

                // e. Return obj.
                return Value.from(&typed_array.object);
            }

            // 8. Assert: firstArg is not an Object.
            std.debug.assert(!first_arg.isObject());

            // 9. Let elementLength be ? ToIndex(firstArg).
            const element_length: ArrayLength = @fromBackingInt(try first_arg.toIndex(agent));

            // 10. Return ? AllocateTypedArray(ctorName, NewTarget, proto, elementLength).
            const typed_array = try allocateTypedArray(
                agent,
                element_type,
                new_target.?,
                proto_intrinsic,
                element_length.toOptional(),
            );
            return Value.from(&typed_array.object);
        }

        /// 23.3.1.1 Uint8Array.fromBase64 ( string [ , options ] )
        /// https://tc39.es/ecma262/#sec-uint8array.frombase64
        fn fromBase64(agent: *Agent, _: Value, arguments: Arguments) Agent.Error!Value {
            const realm = agent.currentRealm();
            const string_value = arguments.get(0);
            const options_value = arguments.get(1);

            // 1. If string is not a String, throw a TypeError exception.
            if (!string_value.isString()) {
                return agent.throwException(.type_error, "{f} is not a string", .{string_value});
            }
            const string = string_value.asString();

            // 2. Let optionsObj be ? GetOptionsObject(options).
            const options = try options_value.getOptionsObject(agent);

            // 3. Let alphabet be ? Get(optionsObj, "alphabet").
            var alphabet_value = try options.get(agent, PropertyKey.from("alphabet"));

            // 4. If alphabet is undefined, set alphabet to "base64".
            // 5. If alphabet is neither "base64" nor "base64url", throw a TypeError exception.
            const alphabet: Alphabet = blk: {
                if (alphabet_value.isUndefined()) break :blk .base64;
                if (alphabet_value.isString()) {
                    if (alphabet_value.asString().eql(String.fromLiteral("base64"))) break :blk .base64;
                    if (alphabet_value.asString().eql(String.fromLiteral("base64url"))) break :blk .base64url;
                }
                return agent.throwException(.type_error, "Invalid alphabet {f}", .{alphabet_value});
            };

            // 6. Let lastChunkHandling be ? Get(optionsObj, "lastChunkHandling").
            var last_chunk_handling_value = try options.get(agent, PropertyKey.from("lastChunkHandling"));

            // 7. If lastChunkHandling is undefined, set lastChunkHandling to "loose".
            // 8. If lastChunkHandling is not one of "loose", "strict", or "stop-before-partial",
            //    throw a TypeError exception.
            const last_chunk_handling: LastChunkHandling = blk: {
                if (last_chunk_handling_value.isUndefined()) break :blk .loose;
                if (last_chunk_handling_value.isString()) {
                    if (last_chunk_handling_value.asString().eql(String.fromLiteral("loose"))) break :blk .loose;
                    if (last_chunk_handling_value.asString().eql(String.fromLiteral("strict"))) break :blk .strict;
                    if (last_chunk_handling_value.asString().eql(String.fromLiteral("stop-before-partial"))) break :blk .stop_before_partial;
                }
                return agent.throwException(
                    .type_error,
                    "Invalid lastChunkHandling {f}",
                    .{last_chunk_handling_value},
                );
            };

            // 9. Let result be FromBase64(string, alphabet, lastChunkHandling).
            const result = try fromBase64Impl(agent, string, alphabet, last_chunk_handling, null);

            // 10. If result.[[Error]] is not none, then
            if (result.@"error") |@"error"| {
                // a. Throw result.[[Error]].
                agent.exception = .{
                    .value = Value.from(&@"error".object),
                    .stack_trace = agent.captureStackTrace(.{}) catch &.{},
                };
                return error.ExceptionThrown;
            }

            // 11. Let resultLength be the number of elements in result.[[Bytes]].
            const result_length: OptionalArrayLength = @fromBackingInt(@intCast(result.bytes.len));

            // 12. Let ta be ? AllocateTypedArray("Uint8Array", %Uint8Array%,
            //     "%Uint8Array.prototype%", resultLength).
            const typed_array = try allocateTypedArray(
                agent,
                .uint8,
                try realm.intrinsic(.uint8_array),
                .uint8_array_prototype,
                result_length,
            );

            // 13. Assert: ta.[[ViewedArrayBuffer]].[[ArrayBufferByteLength]] is the number of
            //     elements in result.[[Bytes]].
            std.debug.assert(
                @backingInt(typed_array.fields.viewed_array_buffer.fields.byte_length) == result.bytes.len,
            );

            // 14. Set the value at each index of ta.[[ViewedArrayBuffer]].[[ArrayBufferData]] to
            //     the value at the corresponding index of result.[[Bytes]].
            const block = typed_array.fields.viewed_array_buffer.fields.data_block.?;
            @memcpy(block.bytes, result.bytes);

            // 15. Return ta.
            return Value.from(&typed_array.object);
        }

        /// 23.3.1.2 Uint8Array.fromHex ( string )
        /// https://tc39.es/ecma262/#sec-uint8array.fromhex
        fn fromHex(agent: *Agent, _: Value, arguments: Arguments) Agent.Error!Value {
            const realm = agent.currentRealm();
            const string_value = arguments.get(0);

            // 1. If string is not a String, throw a TypeError exception.
            if (!string_value.isString()) {
                return agent.throwException(.type_error, "{f} is not a string", .{string_value});
            }
            const string = string_value.asString();

            // 2. Let result be FromHex(string).
            const result = try fromHexImpl(agent, string, null);

            // 3. If result.[[Error]] is not none, then
            if (result.@"error") |@"error"| {
                // a. Throw result.[[Error]].
                agent.exception = .{
                    .value = Value.from(&@"error".object),
                    .stack_trace = agent.captureStackTrace(.{}) catch &.{},
                };
                return error.ExceptionThrown;
            }

            // 4. Let resultLength be the number of elements in result.[[Bytes]].
            const result_length: OptionalArrayLength = @fromBackingInt(@intCast(result.bytes.len));

            // 5. Let ta be ? AllocateTypedArray("Uint8Array", %Uint8Array%,
            //    "%Uint8Array.prototype%", resultLength).
            const typed_array = try allocateTypedArray(
                agent,
                .uint8,
                try realm.intrinsic(.uint8_array),
                .uint8_array_prototype,
                result_length,
            );

            // 6. Assert: ta.[[ViewedArrayBuffer]].[[ArrayBufferByteLength]] is the number of
            //    elements in result.[[Bytes]].
            std.debug.assert(
                @backingInt(typed_array.fields.viewed_array_buffer.fields.byte_length) == result.bytes.len,
            );

            // 7. Set the value at each index of ta.[[ViewedArrayBuffer]].[[ArrayBufferData]] to the
            //    value at the corresponding index of result.[[Bytes]].
            const block = typed_array.fields.viewed_array_buffer.fields.data_block.?;
            @memcpy(block.bytes, result.bytes);

            // 8. Return ta.
            return Value.from(&typed_array.object);
        }
    };
}

/// 23.2.7 Properties of the TypedArray Prototype Objects
/// https://tc39.es/ecma262/#sec-properties-of-typedarray-prototype-objects
fn MakeTypedArrayPrototype(comptime element_type: ElementType) type {
    const ctor_intrinsic = element_type.constructorIntrinsic();
    return struct {
        pub fn create(agent: *Agent, realm: *Realm) std.mem.Allocator.Error!*Object {
            return ordinaryObjectCreate(agent, try realm.intrinsic(.typed_array_prototype));
        }

        pub fn init(agent: *Agent, realm: *Realm, object: *Object) std.mem.Allocator.Error!void {
            // 23.2.7.1 TypedArray.prototype.BYTES_PER_ELEMENT
            // https://tc39.es/ecma262/#sec-typedarray.prototype.bytes_per_element
            try object.defineBuiltinPropertyWithAttributes(
                agent,
                "BYTES_PER_ELEMENT",
                Value.from(element_type.elementSize()),
                .none,
            );

            // 23.2.7.2 TypedArray.prototype.constructor
            // https://tc39.es/ecma262/#sec-typedarray.prototype.constructor
            try object.defineBuiltinProperty(
                agent,
                "constructor",
                Value.from(try realm.intrinsic(ctor_intrinsic)),
            );

            if (element_type == .uint8) {
                try object.defineBuiltinFunction(agent, "setFromBase64", setFromBase64, 1, realm);
                try object.defineBuiltinFunction(agent, "setFromHex", setFromHex, 1, realm);
                try object.defineBuiltinFunction(agent, "toBase64", toBase64, 0, realm);
                try object.defineBuiltinFunction(agent, "toHex", toHex, 0, realm);
            }
        }

        /// 23.3.2.1 Uint8Array.prototype.setFromBase64 ( string [ , options ] )
        /// https://tc39.es/ecma262/#sec-uint8array.prototype.setfrombase64
        fn setFromBase64(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
            const realm = agent.currentRealm();
            const string_value = arguments.get(0);
            const options_value = arguments.get(1);

            // 1. Let into be the this value.
            // 2. Perform ? ValidateUint8Array(into).
            const into = try validateUint8Array(agent, this_value);

            // 3. If string is not a String, throw a TypeError exception.
            if (!string_value.isString()) {
                return agent.throwException(.type_error, "Argument must be a string", .{});
            }
            const string = string_value.asString();

            // 4. Let optionsObj be ? GetOptionsObject(options).
            const options = try options_value.getOptionsObject(agent);

            // 5. Let alphabet be ? Get(optionsObj, "alphabet").
            var alphabet_value = try options.get(agent, PropertyKey.from("alphabet"));

            // 6. If alphabet is undefined, set alphabet to "base64".
            // 7. If alphabet is neither "base64" nor "base64url", throw a TypeError exception.
            const alphabet: Alphabet = blk: {
                if (alphabet_value.isUndefined()) break :blk .base64;
                if (alphabet_value.isString()) {
                    if (alphabet_value.asString().eql(String.fromLiteral("base64"))) break :blk .base64;
                    if (alphabet_value.asString().eql(String.fromLiteral("base64url"))) break :blk .base64url;
                }
                return agent.throwException(.type_error, "Invalid alphabet {f}", .{alphabet_value});
            };

            // 8. Let lastChunkHandling be ? Get(optionsObj, "lastChunkHandling").
            var last_chunk_handling_value = try options.get(agent, PropertyKey.from("lastChunkHandling"));

            // 9. If lastChunkHandling is undefined, set lastChunkHandling to "loose".
            // 10. If lastChunkHandling is not one of "loose", "strict", or "stop-before-partial",
            //     throw a TypeError exception.
            const last_chunk_handling: LastChunkHandling = blk: {
                if (last_chunk_handling_value.isUndefined()) break :blk .loose;
                if (last_chunk_handling_value.isString()) {
                    if (last_chunk_handling_value.asString().eql(String.fromLiteral("loose"))) break :blk .loose;
                    if (last_chunk_handling_value.asString().eql(String.fromLiteral("strict"))) break :blk .strict;
                    if (last_chunk_handling_value.asString().eql(String.fromLiteral("stop-before-partial"))) break :blk .stop_before_partial;
                }
                return agent.throwException(
                    .type_error,
                    "Invalid lastChunkHandling {f}",
                    .{last_chunk_handling_value},
                );
            };

            // 11. Let taRecord be ? ValidateTypedArrayBounds(into, seq-cst).
            const ta_record = try validateTypedArrayBounds(agent, into, .seq_cst);

            // 12. Let byteLength be TypedArrayLength(taRecord).
            const byte_length = @backingInt(typedArrayLength(ta_record));

            // 13. Let result be FromBase64(string, alphabet, lastChunkHandling, byteLength).
            const result = try fromBase64Impl(
                agent,
                string,
                alphabet,
                last_chunk_handling,
                byte_length,
            );

            // 14. Let bytes be result.[[Bytes]].
            const bytes = result.bytes;

            // 15. Let written be the number of elements in bytes.
            const written = bytes.len;

            // 16. NOTE: FromBase64 does not invoke any user code, so the ArrayBuffer backing into
            //     cannot have been detached or shrunk.

            // 17. Assert: written ≤ byteLength.
            std.debug.assert(written <= byte_length);

            // 18. Perform SetUint8ArrayBytes(into, bytes).
            setUint8ArrayBytes(agent, into, bytes);

            // 19. If result.[[Error]] is not none, then
            if (result.@"error") |@"error"| {
                // a. Throw result.[[Error]].
                agent.exception = .{
                    .value = Value.from(&@"error".object),
                    .stack_trace = agent.captureStackTrace(.{}) catch &.{},
                };
                return error.ExceptionThrown;
            }

            // 20. Let resultObj be OrdinaryObjectCreate(%Object.prototype%).
            const result_obj = try ordinaryObjectCreate(
                agent,
                try realm.intrinsic(.object_prototype),
            );

            // 21. Perform ! CreateDataPropertyOrThrow(resultObj, "read", 𝔽(result.[[Read]])).
            try result_obj.createDataPropertyDirect(
                agent,
                PropertyKey.from("read"),
                Value.from(@as(u53, @intCast(result.read))),
            );

            // 22. Perform ! CreateDataPropertyOrThrow(resultObj, "written", 𝔽(written)).
            try result_obj.createDataPropertyDirect(
                agent,
                PropertyKey.from("written"),
                Value.from(@as(u53, @intCast(written))),
            );

            // 23. Return resultObj.
            return Value.from(result_obj);
        }

        /// 23.3.2.2 Uint8Array.prototype.setFromHex ( string )
        /// https://tc39.es/ecma262/#sec-uint8array.prototype.setfromhex
        fn setFromHex(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
            const realm = agent.currentRealm();
            const string_value = arguments.get(0);

            // 1. Let into be the this value.
            // 2. Perform ? ValidateUint8Array(into).
            const into = try validateUint8Array(agent, this_value);

            // 3. If string is not a String, throw a TypeError exception.
            if (!string_value.isString()) {
                return agent.throwException(.type_error, "{f} is not a string", .{string_value});
            }
            const string = string_value.asString();

            // 4. Let taRecord be ? ValidateTypedArrayBounds(into, seq-cst).
            const ta_record = try validateTypedArrayBounds(agent, into, .seq_cst);

            // 5. Let byteLength be TypedArrayLength(taRecord).
            const byte_length = typedArrayLength(ta_record);

            // 6. Let result be FromHex(string, byteLength).
            const result = try fromHexImpl(agent, string, @backingInt(byte_length));

            // 7. Let bytes be result.[[Bytes]].
            const bytes = result.bytes;

            // 8. Let written be the number of elements in bytes.
            const written = bytes.len;

            // 9. NOTE: FromHex does not invoke any user code, so the ArrayBuffer backing into
            //    cannot have been detached or shrunk.

            // 10. Assert: written ≤ byteLength.
            std.debug.assert(written <= @backingInt(byte_length));

            // 11. Perform SetUint8ArrayBytes(into, bytes).
            setUint8ArrayBytes(agent, into, bytes);

            // 12. If result.[[Error]] is not none, then
            if (result.@"error") |@"error"| {
                // a. Throw result.[[Error]].
                agent.exception = .{
                    .value = Value.from(&@"error".object),
                    .stack_trace = agent.captureStackTrace(.{}) catch &.{},
                };
                return error.ExceptionThrown;
            }

            // 13. Let resultObj be OrdinaryObjectCreate(%Object.prototype%).
            const result_obj = try ordinaryObjectCreate(
                agent,
                try realm.intrinsic(.object_prototype),
            );

            // 14. Perform ! CreateDataPropertyOrThrow(resultObj, "read", 𝔽(result.[[Read]])).
            try result_obj.createDataPropertyDirect(
                agent,
                PropertyKey.from("read"),
                Value.from(@as(u53, @intCast(result.read))),
            );

            // 15. Perform ! CreateDataPropertyOrThrow(resultObj, "written", 𝔽(written)).
            try result_obj.createDataPropertyDirect(
                agent,
                PropertyKey.from("written"),
                Value.from(@as(u53, @intCast(written))),
            );

            // 16. Return resultObj.
            return Value.from(result_obj);
        }

        /// 23.3.2.3 Uint8Array.prototype.toBase64 ( [ options ] )
        /// https://tc39.es/ecma262/#sec-uint8array.prototype.tobase64
        fn toBase64(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
            const options_value = arguments.get(0);

            // 1. Let obj be the this value.
            // 2. Perform ? ValidateUint8Array(obj).
            const typed_array = try validateUint8Array(agent, this_value);

            // 3. Let optionsObj be ? GetOptionsObject(options).
            const options = try options_value.getOptionsObject(agent);

            // 4. Let alphabet be ? Get(optionsObj, "alphabet").
            const alphabet_value = try options.get(agent, PropertyKey.from("alphabet"));

            // 5. If alphabet is undefined, set alphabet to "base64".
            // 6. If alphabet is neither "base64" nor "base64url", throw a TypeError exception.
            const alphabet: Alphabet = blk: {
                if (alphabet_value.isUndefined()) break :blk .base64;
                if (alphabet_value.isString()) {
                    if (alphabet_value.asString().eql(String.fromLiteral("base64"))) break :blk .base64;
                    if (alphabet_value.asString().eql(String.fromLiteral("base64url"))) break :blk .base64url;
                }
                return agent.throwException(.type_error, "Invalid alphabet {f}", .{alphabet_value});
            };

            // 7. Let omitPadding be ToBoolean(? Get(optionsObj, "omitPadding")).
            const omit_padding = (try options.get(agent, PropertyKey.from("omitPadding"))).toBoolean();

            // 8. Let toEncode be ? GetUint8ArrayBytes(obj).
            const to_encode = try getUint8ArrayBytes(agent, typed_array);

            // 9. If alphabet is "base64", then
            const codecs = switch (alphabet) {
                .base64 => blk: {
                    // a. Let outAscii be the sequence of code points which results from encoding
                    //    toEncode according to the base64 encoding specified in section 4 of
                    //    RFC 4648. Padding is included if and only if omitPadding is false.
                    break :blk if (omit_padding) std.base64.standard_no_pad else std.base64.standard;
                },
                // 10. Else,
                // a. Assert: alphabet is "base64url".
                .base64url => blk: {
                    // b. Let outAscii be the sequence of code points which results from encoding
                    //    toEncode according to the base64url encoding specified in section 5 of
                    //    RFC 4648. Padding is included if and only if omitPadding is false.
                    break :blk if (omit_padding) std.base64.url_safe_no_pad else std.base64.url_safe;
                },
            };
            const out_ascii = try agent.gc_allocator.alloc(u8, codecs.Encoder.calcSize(to_encode.len));
            const encoded = codecs.Encoder.encode(out_ascii, to_encode);
            std.debug.assert(encoded.len == out_ascii.len);

            // 11. Return CodePointsToString(outAscii).
            return Value.from(try String.fromAscii(agent, out_ascii));
        }

        /// 23.3.2.4 Uint8Array.prototype.toHex ( )
        /// https://tc39.es/ecma262/#sec-uint8array.prototype.tohex
        fn toHex(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
            // 1. Let obj be the this value.
            // 2. Perform ? ValidateUint8Array(obj).
            const typed_array = try validateUint8Array(agent, this_value);

            // 3. Let toEncode be ? GetUint8ArrayBytes(obj).
            const to_encode = try getUint8ArrayBytes(agent, typed_array);

            // 4. Let out be the empty String.
            // 5. For each byte byte of toEncode, do
            //     a. Let hex be Number::toString(𝔽(byte), 16).
            //     b. Set hex to StringPad(hex, 2, "0", start).
            //     c. Set out to the string-concatenation of out and hex.
            // 6. Return out.
            return Value.from(try String.fromAscii(agent, try agent.gc_allocator.print(
                "{x}",
                .{to_encode},
            )));
        }
    };
}

/// 23.2.8 Properties of TypedArray Instances
/// https://tc39.es/ecma262/#sec-properties-of-typedarray-instances
pub const TypedArray = MakeObject(.{
    .Fields = struct {
        /// [[TypedArrayName]]
        element_type: ElementType,

        /// [[ContentType]]
        content_type: enum { bigint, number },

        /// [[ViewedArrayBuffer]]
        viewed_array_buffer: *builtins.ArrayBuffer,

        /// [[ByteLength]]
        byte_length: AutoByteLength,

        /// [[ByteOffset]]
        byte_offset: ByteOffset,

        /// [[ArrayLength]]
        array_length: AutoArrayLength,
    },
    .tag = .typed_array,
    .display_name = "TypedArray",
});
