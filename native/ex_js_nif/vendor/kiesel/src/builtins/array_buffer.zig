//! 25.1 ArrayBuffer Objects
//! https://tc39.es/ecma262/#sec-arraybuffer-objects

const std = @import("std");

const builtins = @import("../builtins.zig");
const execution = @import("../execution.zig");
const types = @import("../types.zig");
const utils = @import("../utils.zig");

const Agent = execution.Agent;
const Arguments = types.Arguments;
const ByteLength = types.ByteLength;
const ByteOffset = types.ByteOffset;
const DataBlock = types.DataBlock;
const ElementType = builtins.typed_array.ElementType;
const MakeObject = types.MakeObject;
const Object = types.Object;
const OptionalByteLength = types.OptionalByteLength;
const PropertyKey = types.PropertyKey;
const Realm = execution.Realm;
const Value = types.Value;
const copyDataBlockBytes = types.copyDataBlockBytes;
const createBuiltinFunction = builtins.createBuiltinFunction;
const createByteDataBlock = types.createByteDataBlock;
const isGrowableSharedArrayBuffer = builtins.isGrowableSharedArrayBuffer;
const isSharedArrayBuffer = builtins.isSharedArrayBuffer;
const noexcept = utils.noexcept;
const ordinaryCreateFromConstructor = builtins.ordinaryCreateFromConstructor;
const ordinaryObjectCreate = builtins.ordinaryObjectCreate;
const sameValue = types.sameValue;

pub const Order = enum {
    seq_cst,
    unordered,
};

/// 25.1.3.1 AllocateArrayBuffer ( ctor, byteLength [ , maxByteLength ] )
/// https://tc39.es/ecma262/#sec-allocatearraybuffer
pub fn allocateArrayBuffer(
    agent: *Agent,
    ctor: *Object,
    byte_length: ByteLength,
    max_byte_length: OptionalByteLength,
) Agent.Error!*ArrayBuffer {
    // 1. Let slots be « [[ArrayBufferData]], [[ArrayBufferByteLength]], [[ArrayBufferDetachKey]] ».

    // 2. If maxByteLength is present and maxByteLength is not empty, let allocatingResizableBuffer
    //    be true; else let allocatingResizableBuffer be false.
    const allocating_resizable_buffer = max_byte_length != .none;

    // 3. If allocatingResizableBuffer is true, then
    if (allocating_resizable_buffer) {
        // a. If byteLength > maxByteLength, throw a RangeError exception.
        if (@backingInt(byte_length) > @backingInt(max_byte_length)) {
            return agent.throwException(.range_error, "Maximum buffer size exceeded", .{});
        }

        // NOTE: Checking for a reasonable size below the theoretical limit is non-standard but also
        //       done in other engines (and tested by test262)
        if (@backingInt(max_byte_length) > @backingInt(DataBlock.max_byte_length)) {
            return agent.throwException(.range_error, "Maximum buffer size exceeded", .{});
        }

        // b. Append [[ArrayBufferMaxByteLength]] to slots.
    }

    // 4. Let obj be ? OrdinaryCreateFromConstructor(ctor, "%ArrayBuffer.prototype%", slots).
    const array_buffer = try ordinaryCreateFromConstructor(
        ArrayBuffer,
        agent,
        ctor,
        .array_buffer_prototype,
        .{
            .data_block = undefined,
            .byte_length = undefined,
            .detach_key = .undefined,
            .max_byte_length = .none,
        },
    );

    // 5. Let block be ? CreateByteDataBlock(byteLength).
    const block = try createByteDataBlock(agent, byte_length);

    // 6. Set obj.[[ArrayBufferData]] to block.
    array_buffer.fields.data_block = block;

    // 7. Set obj.[[ArrayBufferByteLength]] to byteLength.
    array_buffer.fields.byte_length = byte_length;

    // 8. If allocatingResizableBuffer is true, then
    if (allocating_resizable_buffer) {
        // a. If it is not possible to create a Data Block block consisting of maxByteLength bytes,
        //    throw a RangeError exception.
        // b. NOTE: Resizable ArrayBuffers are designed to be implementable with in-place growth.
        //    Implementations may throw if, for example, virtual memory cannot be reserved up front.

        // c. Set obj.[[ArrayBufferMaxByteLength]] to maxByteLength.
        array_buffer.fields.max_byte_length = max_byte_length;
    }

    // 9. Return obj.
    return array_buffer;
}

/// 25.1.3.2 ArrayBufferByteLength ( arrayBuffer, order )
/// https://tc39.es/ecma262/#sec-arraybufferbytelength
pub fn arrayBufferByteLength(array_buffer: *const ArrayBuffer, order: Order) ByteLength {
    // 1. If IsGrowableSharedArrayBuffer(arrayBuffer) is true, then
    if (isGrowableSharedArrayBuffer(array_buffer)) {
        // a. Let bufferByteLengthBlock be arrayBuffer.[[ArrayBufferByteLengthData]].
        // b. Let rawLength be GetRawBytesFromSharedBlock(bufferByteLengthBlock, 0, biguint64, true,
        //    order).
        // c. Let agentRecord be the Agent Record of the surrounding agent.
        // d. Let isLittleEndian be agentRecord.[[LittleEndian]].
        // e. Return ℝ(RawBytesToNumeric(biguint64, rawLength, isLittleEndian)).
        const ptr: *const usize = @ptrCast(&array_buffer.fields.byte_length);
        const value = switch (order) {
            .seq_cst => @atomicLoad(usize, ptr, .seq_cst),
            .unordered => @atomicLoad(usize, ptr, .unordered),
        };
        return @fromBackingInt(@intCast(value));
    }

    // 2. Assert: IsDetachedBuffer(arrayBuffer) is false.
    std.debug.assert(!isDetachedBuffer(array_buffer));

    // 3. Return arrayBuffer.[[ArrayBufferByteLength]].
    return array_buffer.fields.byte_length;
}

/// 25.1.3.3 ArrayBufferCopyAndDetach ( arrayBuffer, newLength, preserveResizability )
pub fn arrayBufferCopyAndDetach(
    agent: *Agent,
    array_buffer_value: Value,
    new_length: Value,
    preserve_resizability: enum { preserve_resizability, fixed_length },
) Agent.Error!*ArrayBuffer {
    const realm = agent.currentRealm();

    // 1. Perform ? RequireInternalSlot(arrayBuffer, [[ArrayBufferData]]).
    const array_buffer = try array_buffer_value.requireInternalSlot(agent, ArrayBuffer);

    // 2. If IsSharedArrayBuffer(arrayBuffer) is true, throw a TypeError exception.
    if (isSharedArrayBuffer(array_buffer)) {
        return agent.throwException(
            .type_error,
            "{f} is not an ArrayBuffer object",
            .{array_buffer_value},
        );
    }

    // 3. If newLength is undefined, then
    const new_byte_length: ByteLength = if (new_length.isUndefined()) blk: {
        // a. Let newByteLength be arrayBuffer.[[ArrayBufferByteLength]].
        break :blk array_buffer.fields.byte_length;
    } else blk: {
        // 4. Else,
        // a. Let newByteLength be ? ToIndex(newLength).
        break :blk @fromBackingInt(try new_length.toIndex(agent));
    };

    // 5. If IsDetachedBuffer(arrayBuffer) is true, throw a TypeError exception.
    if (isDetachedBuffer(array_buffer)) {
        return agent.throwException(.type_error, "ArrayBuffer is detached", .{});
    }

    // 6. If preserveResizability is preserve-resizability and IsFixedLengthArrayBuffer(arrayBuffer)
    //    is false, then
    const new_max_byte_length: OptionalByteLength = if (preserve_resizability == .preserve_resizability and
        !isFixedLengthArrayBuffer(array_buffer))
    blk: {
        // a. Let newMaxByteLength be arrayBuffer.[[ArrayBufferMaxByteLength]].
        break :blk array_buffer.fields.max_byte_length;
    } else blk: {
        // 7. Else,
        // a. Let newMaxByteLength be empty.
        break :blk .none;
    };

    // 8. If arrayBuffer.[[ArrayBufferDetachKey]] is not undefined, throw a TypeError exception.
    if (!array_buffer.fields.detach_key.isUndefined()) {
        return agent.throwException(.type_error, "ArrayBuffer detach key does not match", .{});
    }

    // 9. Let newBuffer be ? AllocateArrayBuffer(%ArrayBuffer%, newByteLength, newMaxByteLength).
    const new_buffer = try allocateArrayBuffer(
        agent,
        try realm.intrinsic(.array_buffer),
        new_byte_length,
        new_max_byte_length,
    );

    // 10. Let copyLength be min(newByteLength, arrayBuffer.[[ArrayBufferByteLength]]).
    const copy_length = @min(
        @backingInt(new_byte_length),
        @backingInt(array_buffer.fields.byte_length),
    );

    // 11. Let fromBlock be arrayBuffer.[[ArrayBufferData]].
    const from_block = array_buffer.fields.data_block.?;

    // 12. Let toBlock be newBuffer.[[ArrayBufferData]].
    const to_block = new_buffer.fields.data_block.?;

    // 13. Perform CopyDataBlockBytes(toBlock, 0, fromBlock, 0, copyLength).
    copyDataBlockBytes(to_block, 0, from_block, 0, copy_length);

    // 14. NOTE: Neither creation of the new Data Block nor copying from the old Data Block are
    //     observable. Implementations may implement this method as a zero-copy move or a realloc.
    // TODO: Implement this as mentioned :^)

    // 15. Perform ! DetachArrayBuffer(arrayBuffer).
    detachArrayBuffer(agent, array_buffer, null) catch unreachable;

    // 16. Return newBuffer.
    return new_buffer;
}

/// 25.1.3.4 IsDetachedBuffer ( arrayBuffer )
/// https://tc39.es/ecma262/#sec-isdetachedbuffer
pub fn isDetachedBuffer(array_buffer: *const ArrayBuffer) bool {
    // 1. If arrayBuffer.[[ArrayBufferData]] is null, return true.
    // 2. Return false.
    return array_buffer.fields.data_block == null;
}

/// 25.1.3.5 DetachArrayBuffer ( arrayBuffer [ , key ] )
/// https://tc39.es/ecma262/#sec-detacharraybuffer
pub fn detachArrayBuffer(
    agent: *Agent,
    array_buffer: *ArrayBuffer,
    maybe_key: ?Value,
) error{ExceptionThrown}!void {
    // 1. Assert: IsSharedArrayBuffer(arrayBuffer) is false.
    std.debug.assert(!isSharedArrayBuffer(array_buffer));

    // 2. If key is not present, set key to undefined.
    const key: Value = maybe_key orelse .undefined;

    // 3. If arrayBuffer.[[ArrayBufferDetachKey]] is not key, throw a TypeError exception.
    if (!sameValue(array_buffer.fields.detach_key, key)) {
        return agent.throwException(.type_error, "ArrayBuffer detach key does not match", .{});
    }

    // 4. Set arrayBuffer.[[ArrayBufferData]] to null.
    if (array_buffer.fields.data_block) |data_block| {
        agent.gc_allocator.free(data_block.bytes);
        array_buffer.fields.data_block = null;
    }

    // 5. Set arrayBuffer.[[ArrayBufferByteLength]] to 0.
    array_buffer.fields.byte_length = .zero;

    // 6. Return unused.
}

/// 25.1.3.6 CloneArrayBuffer ( sourceBuffer, sourceByteOffset, sourceLength )
/// https://tc39.es/ecma262/#sec-clonearraybuffer
pub fn cloneArrayBuffer(
    agent: *Agent,
    source_buffer: *const ArrayBuffer,
    source_byte_offset: ByteOffset,
    source_length: ByteLength,
) Agent.Error!*ArrayBuffer {
    const realm = agent.currentRealm();

    // 1. Assert: IsDetachedBuffer(sourceBuffer) is false.
    std.debug.assert(!isDetachedBuffer(source_buffer));

    // 2. Let targetBuffer be ? AllocateArrayBuffer(%ArrayBuffer%, sourceLength).
    const target_buffer = try allocateArrayBuffer(
        agent,
        try realm.intrinsic(.array_buffer),
        source_length,
        .none,
    );

    // 3. Let sourceBlock be sourceBuffer.[[ArrayBufferData]].
    const source_block = source_buffer.fields.data_block.?;

    // 4. Let targetBlock be targetBuffer.[[ArrayBufferData]].
    const target_block = target_buffer.fields.data_block.?;

    // 5. Perform CopyDataBlockBytes(targetBlock, 0, sourceBlock, sourceByteOffset, sourceLength).
    copyDataBlockBytes(
        target_block,
        0,
        source_block,
        @backingInt(source_byte_offset),
        @backingInt(source_length),
    );

    // 6. Return targetBuffer.
    return target_buffer;
}

/// 25.1.3.7 GetArrayBufferMaxByteLengthOption ( options )
/// https://tc39.es/ecma262/#sec-getarraybuffermaxbytelengthoption
pub fn getArrayBufferMaxByteLengthOption(
    agent: *Agent,
    options: Value,
) Agent.Error!OptionalByteLength {
    // 1. If options is not an Object, return empty.
    if (!options.isObject()) return .none;

    // 2. Let maxByteLength be ? Get(options, "maxByteLength").
    const max_byte_length = try options.asObject().get(agent, PropertyKey.from("maxByteLength"));

    // 3. If maxByteLength is undefined, return empty.
    if (max_byte_length.isUndefined()) return .none;

    // 4. Return ? ToIndex(maxByteLength).
    return @fromBackingInt(try max_byte_length.toIndex(agent));
}

/// 25.1.3.9 IsFixedLengthArrayBuffer ( arrayBuffer )
/// https://tc39.es/ecma262/#sec-isfixedlengtharraybuffer
pub fn isFixedLengthArrayBuffer(array_buffer: *const ArrayBuffer) bool {
    // 1. If arrayBuffer has an [[ArrayBufferMaxByteLength]] internal slot, return false.
    // 2. Return true.
    return array_buffer.fields.max_byte_length == .none;
}

/// 25.1.3.14 RawBytesToNumeric ( type, rawBytes, isLittleEndian )
/// https://tc39.es/ecma262/#sec-rawbytestonumeric
pub fn rawBytesToNumeric(
    comptime @"type": ElementType,
    raw_bytes: []const u8,
    is_little_endian: bool,
) @"type".type() {
    // 1. Let elementSize be the Element Size value specified in Table 71 for Element Type type.
    const element_size = @"type".elementSize();

    var bytes: [element_size]u8 = undefined;
    @memcpy(&bytes, raw_bytes);

    // 2. If isLittleEndian is false, reverse the order of the elements of rawBytes.
    if (!is_little_endian) std.mem.reverse(u8, &bytes);

    // 3-9.
    return std.mem.bytesToValue(@"type".type(), &bytes);
}

/// 25.1.3.15 GetRawBytesFromSharedBlock ( block, byteIndex, type, isTypedArray, order )
/// https://tc39.es/ecma262/#sec-getrawbytesfromsharedblock
pub fn getRawBytesFromSharedBlock(
    block: DataBlock,
    byte_index: u53,
    comptime @"type": ElementType,
    is_typed_array: bool,
    order: Order,
) [@sizeOf(@"type".type())]u8 {
    // 1. Let elementSize be the Element Size value specified in Table 71 for Element Type type.
    const element_size = @"type".elementSize();

    // TODO: 2-11.
    _ = is_typed_array;
    _ = order;
    return block.bytes[@intCast(byte_index)..][0..element_size].*;
}

/// 25.1.3.16 GetValueFromBuffer ( arrayBuffer, byteIndex, type, isTypedArray, order [ , isLittleEndian ] )
/// https://tc39.es/ecma262/#sec-getvaluefrombuffer
pub fn getValueFromBuffer(
    agent: *Agent,
    array_buffer: *const ArrayBuffer,
    byte_index: u53,
    comptime @"type": ElementType,
    is_typed_array: bool,
    order: Order,
    maybe_is_little_endian: ?bool,
) @"type".type() {
    // 1. Assert: IsDetachedBuffer(arrayBuffer) is false.
    std.debug.assert(!isDetachedBuffer(array_buffer));

    // 2. Assert: There are sufficient bytes in arrayBuffer starting at byteIndex to represent a
    //    value of type.
    std.debug.assert(array_buffer.fields.data_block.?.bytes.len >= byte_index + @"type".elementSize());

    // 3. Let block be arrayBuffer.[[ArrayBufferData]].
    const block = array_buffer.fields.data_block.?;

    // 4. Let elementSize be the Element Size value specified in Table 71 for Element Type type.
    const element_size = @"type".elementSize();

    // 5. If IsSharedArrayBuffer(arrayBuffer) is true, then
    const raw_value = if (isSharedArrayBuffer(array_buffer)) blk: {
        // a. Assert: block is a Shared Data Block.
        std.debug.assert(block.shared);

        // b. Let rawValue be GetRawBytesFromSharedBlock(block, byteIndex, type, isTypedArray,
        //    order).
        break :blk &getRawBytesFromSharedBlock(block, byte_index, @"type", is_typed_array, order);
    } else blk: {
        // 6. Else,
        // a. Let rawValue be a List whose elements are bytes from block at indices in the interval
        //    from byteIndex (inclusive) to byteIndex + elementSize (exclusive).
        break :blk block.bytes[@intCast(byte_index)..@intCast(byte_index + element_size)];
    };

    // 7. Assert: The number of elements in rawValue is elementSize.
    std.debug.assert(raw_value.len == element_size);

    // 8. If isLittleEndian is not present, then
    //     a. Let agentRecord be the Agent Record of the surrounding agent.
    //     b. Set isLittleEndian to agentRecord.[[LittleEndian]].
    const is_little_endian = maybe_is_little_endian orelse agent.little_endian;

    // 9. Return RawBytesToNumeric(type, rawValue, isLittleEndian).
    return rawBytesToNumeric(@"type", raw_value, is_little_endian);
}

/// 25.1.3.17 NumericToRawBytes ( type, value, isLittleEndian )
/// https://tc39.es/ecma262/#sec-numerictorawbytes
pub fn numericToRawBytes(
    agent: *Agent,
    comptime element_type: ElementType,
    value: Value,
    is_little_endian: bool,
) std.mem.Allocator.Error![@sizeOf(element_type.type())]u8 {
    var raw_bytes = switch (element_type) {
        // 1. If type is float16, then
        .float16 => blk: {
            // a. Let rawBytes be a List whose elements are the 2 bytes that are the result of
            //    converting value to IEEE 754-2019 binary16 format using roundTiesToEven mode. The
            //    bytes are arranged in little endian order. If value is NaN, rawBytes may be set to
            //    any implementation chosen IEEE 754-2019 binary16 format NaN encoding. An
            //    implementation must always choose the same encoding for each implementation
            //    distinguishable NaN value.
            break :blk std.mem.toBytes(
                if (value.asNumber().isNan())
                    std.math.nan(f16)
                else
                    value.asNumber().toFloat16(),
            );
        },
        // 2. Else if type is float32, then
        .float32 => blk: {
            // a. Let rawBytes be a List whose elements are the 4 bytes that are the result of
            //    converting value to IEEE 754-2019 binary32 format using roundTiesToEven mode. The
            //    bytes are arranged in little endian order. If value is NaN, rawBytes may be set to
            //    any implementation chosen IEEE 754-2019 binary32 format NaN encoding. An
            //    implementation must always choose the same encoding for each implementation
            //    distinguishable NaN value.
            break :blk std.mem.toBytes(
                if (value.asNumber().isNan())
                    std.math.nan(f32)
                else
                    @as(f32, @floatCast(value.asNumber().asFloat())),
            );
        },
        // 3. Else if type is float64, then
        .float64 => blk: {
            // a. Let rawBytes be a List whose elements are the 8 bytes that are the IEEE 754-2019
            //    binary64 format encoding of value. The bytes are arranged in little endian order.
            //    If value is NaN, rawBytes may be set to any implementation chosen IEEE 754-2019
            //    binary64 format NaN encoding. An implementation must always choose the same
            //    encoding for each implementation distinguishable NaN value.
            break :blk std.mem.toBytes(
                if (value.asNumber().isNan())
                    std.math.nan(f64)
                else
                    value.asNumber().asFloat(),
            );
        },
        // 4. Else,
        else => blk: {
            // a. Let n be the Element Size value specified in Table 71 for Element Type type.

            // b. Let conversionOperation be the abstract operation named in the “Conversion
            //    Operation” column of Table 71 for Element Type type.
            const conversionOperation = element_type.conversationOperation();

            // c. Let intValue be ℝ(! conversionOperation(value)).
            const int_value = conversionOperation(value, agent) catch |err| try noexcept(err);

            // d. If intValue ≥ 0, then
            //     i. Let rawBytes be a List whose elements are the n-byte binary encoding of
            //        intValue. The bytes are ordered in little endian order.
            // e. Else,
            //     i. Let rawBytes be a List whose elements are the n-byte binary two's complement
            //        encoding of intValue. The bytes are ordered in little endian order.
            break :blk std.mem.toBytes(int_value);
        },
    };

    // 5. If isLittleEndian is false, reverse the order of the elements of rawBytes.
    if (!is_little_endian) std.mem.reverse(u8, &raw_bytes);

    // 6. Return rawBytes.
    return raw_bytes;
}

/// 25.1.3.18 SetValueInBuffer ( arrayBuffer, byteIndex, type, value, isTypedArray, order [ , isLittleEndian ] )
/// https://tc39.es/ecma262/#sec-setvalueinbuffer
pub fn setValueInBuffer(
    agent: *Agent,
    array_buffer: *ArrayBuffer,
    byte_index: u53,
    comptime @"type": ElementType,
    value: Value,
    is_typed_array: bool,
    order: Order,
    maybe_is_little_endian: ?bool,
) std.mem.Allocator.Error!void {
    // 1. Assert: IsDetachedBuffer(arrayBuffer) is false.
    std.debug.assert(!isDetachedBuffer(array_buffer));

    // 2. Assert: There are sufficient bytes in arrayBuffer starting at byteIndex to represent a
    //    value of type.
    std.debug.assert(array_buffer.fields.data_block.?.bytes.len >= byte_index + @"type".elementSize());

    // 3. Assert: value is a BigInt if IsBigIntElementType(type) is true; else, value is a Number.
    std.debug.assert(if (@"type".isBigIntElementType()) value.isBigInt() else value.isNumber());

    // 4. Let block be arrayBuffer.[[ArrayBufferData]].
    const block = array_buffer.fields.data_block.?;

    // 5. Let elementSize be the Element Size value specified in Table 71 for Element Type type.
    const element_size = @"type".elementSize();

    // 6. Let agentRecord be the Agent Record of the surrounding agent.
    // 7. If isLittleEndian is not present, then
    //     a. Set isLittleEndian to agentRecord.[[LittleEndian]].
    const is_little_endian = maybe_is_little_endian orelse agent.little_endian;

    // 8. Let rawBytes be NumericToRawBytes(type, value, isLittleEndian).
    const raw_bytes = try numericToRawBytes(agent, @"type", value, is_little_endian);

    // 9. If IsSharedArrayBuffer(arrayBuffer) is true, then
    if (isSharedArrayBuffer(array_buffer)) {
        // a. Let execution be agentRecord.[[CandidateExecution]].
        // b. Let eventsRecord be the Agent Events Record of execution.[[EventsRecords]] whose
        //    [[AgentSignifier]] is AgentSignifier().
        // c. If isTypedArray is true and IsNoTearConfiguration(type, order) is true, let noTear be
        //    true; else let noTear be false.
        // d. Append WriteSharedMemory { [[Order]]: order, [[NoTear]]: noTear, [[Block]]: block,
        //    [[ByteIndex]]: byteIndex, [[ElementSize]]: elementSize, [[Payload]]: rawBytes } to
        //    eventsRecord.[[EventList]].
        // TODO: Implement using correct ordering
        _ = order;
        _ = is_typed_array;
        @memcpy(block.bytes[@intCast(byte_index)..@intCast(byte_index + element_size)], &raw_bytes);
    } else {
        // 10. Else,
        // a. Store the individual bytes of rawBytes into block, starting at block[byteIndex].
        @memcpy(block.bytes[@intCast(byte_index)..@intCast(byte_index + element_size)], &raw_bytes);
    }

    // 11. Return unused.
}

/// 25.1.3.19 GetModifySetValueInBuffer ( arrayBuffer, byteIndex, type, value, op )
/// https://tc39.es/ecma262/#sec-getmodifysetvalueinbuffer
pub fn getModifySetValueInBuffer(
    agent: *Agent,
    array_buffer: *ArrayBuffer,
    byte_index: u53,
    comptime @"type": ElementType,
    value: Value,
    comptime op: std.lang.AtomicRmwOp,
) std.mem.Allocator.Error!@"type".type() {
    // 1. Assert: IsDetachedBuffer(arrayBuffer) is false.
    std.debug.assert(!isDetachedBuffer(array_buffer));

    // 2. Assert: There are sufficient bytes in arrayBuffer starting at byteIndex to represent a
    //    value of type.
    std.debug.assert(array_buffer.fields.data_block.?.bytes.len >= byte_index + @"type".elementSize());

    // 3. Assert: value is a BigInt if IsBigIntElementType(type) is true; else, value is a Number.
    std.debug.assert(if (@"type".isBigIntElementType()) value.isBigInt() else value.isNumber());

    // 4. Let block be arrayBuffer.[[ArrayBufferData]].
    const block = array_buffer.fields.data_block.?;

    // 5. Let elementSize be the Element Size value specified in Table 71 for Element Type type.
    const element_size = @"type".elementSize();

    // 6. Let agentRecord be the Agent Record of the surrounding agent.
    // 7. Let isLittleEndian be agentRecord.[[LittleEndian]].
    const is_little_endian = agent.little_endian;

    // 8. Let rawBytes be NumericToRawBytes(type, value, isLittleEndian).
    const raw_bytes = try numericToRawBytes(agent, @"type", value, is_little_endian);

    var previous: @"type".type() = undefined;

    // 9. If IsSharedArrayBuffer(arrayBuffer) is true, then
    if (isSharedArrayBuffer(array_buffer)) {
        // a. Let execution be agentRecord.[[CandidateExecution]].
        // b. Let eventsRecord be the Agent Events Record of execution.[[EventsRecords]] whose
        //    [[AgentSignifier]] is AgentSignifier().
        // c. Let rawBytesRead be a List of length elementSize whose elements are
        //    nondeterministically chosen byte values.
        // d. NOTE: In implementations, rawBytesRead is the result of a load-link, of a
        //    load-exclusive, or of an operand of a read-modify-write instruction on the underlying
        //    hardware. The nondeterminism is a semantic prescription of the memory model to
        //    describe observable behaviour of hardware with weak consistency.
        // e. Let rmwEvent be ReadModifyWriteSharedMemory { [[Order]]: seq-cst, [[NoTear]]: true,
        //    [[Block]]: block, [[ByteIndex]]: byteIndex, [[ElementSize]]: elementSize,
        //    [[Payload]]: rawBytes, [[ModifyOp]]: op }.
        // f. Append rmwEvent to eventsRecord.[[EventList]].
        // g. Append Chosen Value Record { [[Event]]: rmwEvent, [[ChosenValue]]: rawBytesRead } to
        //    execution.[[ChosenValues]].
        const ptr = std.mem.bytesAsValue(
            @"type".type(),
            block.bytes[@intCast(byte_index)..@intCast(byte_index + element_size)],
        );
        previous = @atomicRmw(
            @"type".type(),
            @as(*@"type".type(), @alignCast(ptr)),
            op,
            std.mem.bytesToValue(@"type".type(), &raw_bytes),
            .seq_cst,
        );
    } else {
        // 10. Else,
        // a. Let rawBytesRead be a List of length elementSize whose elements are the sequence of
        //    elementSize bytes starting with block[byteIndex].
        // b. Let rawBytesModified be op(rawBytesRead, rawBytes).
        // c. Store the individual bytes of rawBytesModified into block, starting at
        //    block[byteIndex].
        const ptr = std.mem.bytesAsValue(
            @"type".type(),
            block.bytes[@intCast(byte_index)..@intCast(byte_index + element_size)],
        );
        previous = @atomicRmw(
            @"type".type(),
            @as(*@"type".type(), @alignCast(ptr)),
            op,
            std.mem.bytesToValue(@"type".type(), &raw_bytes),
            .seq_cst,
        );
    }

    // 11. Return RawBytesToNumeric(type, rawBytesRead, isLittleEndian).
    return rawBytesToNumeric(@"type", std.mem.asBytes(&previous), is_little_endian);
}

/// 25.1.5 Properties of the ArrayBuffer Constructor
/// https://tc39.es/ecma262/#sec-properties-of-the-arraybuffer-constructor
pub const constructor = struct {
    pub fn create(agent: *Agent, realm: *Realm) std.mem.Allocator.Error!*Object {
        const builtin_function = try createBuiltinFunction(
            agent,
            .{ .constructor = impl },
            1,
            "ArrayBuffer",
            .{ .realm = realm, .proto = try realm.intrinsic(.function_prototype) },
        );
        return &builtin_function.object;
    }

    pub fn init(agent: *Agent, realm: *Realm, object: *Object) std.mem.Allocator.Error!void {
        try object.defineBuiltinFunction(agent, "isView", isView, 1, realm);
        try object.defineBuiltinAccessor(agent, "Symbol.species", @"Symbol.species", null, realm);

        // 25.1.5.2 ArrayBuffer.prototype
        // https://tc39.es/ecma262/#sec-arraybuffer.prototype
        try object.defineBuiltinPropertyWithAttributes(
            agent,
            "prototype",
            Value.from(try realm.intrinsic(.array_buffer_prototype)),
            .none,
        );
    }

    /// 25.1.4.1 ArrayBuffer ( length [ , options ] )
    /// https://tc39.es/ecma262/#sec-arraybuffer-length
    fn impl(agent: *Agent, arguments: Arguments, new_target: ?*Object) Agent.Error!Value {
        const length = arguments.get(0);
        const options = arguments.get(1);

        // 1. If NewTarget is undefined, throw a TypeError exception.
        if (new_target == null) {
            return agent.throwException(
                .type_error,
                "ArrayBuffer must be constructed with 'new'",
                .{},
            );
        }

        // 2. Let byteLength be ? ToIndex(length).
        const byte_length: ByteLength = @fromBackingInt(try length.toIndex(agent));

        // 3. Let requestedMaxByteLength be ? GetArrayBufferMaxByteLengthOption(options).
        const requested_max_byte_length = try getArrayBufferMaxByteLengthOption(agent, options);

        // 4. Return ? AllocateArrayBuffer(NewTarget, byteLength, requestedMaxByteLength).
        const array_buffer = try allocateArrayBuffer(
            agent,
            new_target.?,
            byte_length,
            requested_max_byte_length,
        );
        return Value.from(&array_buffer.object);
    }

    /// 25.1.5.1 ArrayBuffer.isView ( arg )
    /// https://tc39.es/ecma262/#sec-arraybuffer.isview
    fn isView(_: *Agent, _: Value, arguments: Arguments) Agent.Error!Value {
        const arg = arguments.get(0);

        // 1. If arg is not an Object, return false.
        if (!arg.isObject()) return .false;

        // 2. If arg has a [[ViewedArrayBuffer]] internal slot, return true.
        // 3. Return false.
        return Value.from(arg.asObject().is(builtins.DataView) or arg.asObject().is(builtins.TypedArray));
    }

    /// 25.1.5.3 get ArrayBuffer [ %Symbol.species% ]
    /// https://tc39.es/ecma262/#sec-get-arraybuffer-%symbol.species%
    fn @"Symbol.species"(_: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Return the this value.
        return this_value;
    }
};

/// 25.1.6 Properties of the ArrayBuffer Prototype Object
/// https://tc39.es/ecma262/#sec-properties-of-the-arraybuffer-prototype-object
pub const prototype = struct {
    pub fn create(agent: *Agent, realm: *Realm) std.mem.Allocator.Error!*Object {
        return ordinaryObjectCreate(agent, try realm.intrinsic(.object_prototype));
    }

    pub fn init(agent: *Agent, realm: *Realm, object: *Object) std.mem.Allocator.Error!void {
        try object.defineBuiltinAccessor(agent, "byteLength", byteLength, null, realm);
        try object.defineBuiltinAccessor(agent, "detached", detached, null, realm);
        try object.defineBuiltinAccessor(agent, "maxByteLength", maxByteLength, null, realm);
        try object.defineBuiltinAccessor(agent, "resizable", resizable, null, realm);
        try object.defineBuiltinFunction(agent, "resize", resize, 1, realm);
        try object.defineBuiltinFunction(agent, "slice", slice, 2, realm);
        try object.defineBuiltinFunction(agent, "transfer", transfer, 0, realm);
        try object.defineBuiltinFunction(agent, "transferToFixedLength", transferToFixedLength, 0, realm);

        // 25.1.6.2 ArrayBuffer.prototype.constructor
        // https://tc39.es/ecma262/#sec-arraybuffer.prototype.constructor
        try object.defineBuiltinProperty(
            agent,
            "constructor",
            Value.from(try realm.intrinsic(.array_buffer)),
        );

        // 25.1.6.10 ArrayBuffer.prototype [ %Symbol.toStringTag% ]
        // https://tc39.es/ecma262/#sec-arraybuffer.prototype-%symbol.tostringtag%
        try object.defineBuiltinPropertyWithAttributes(
            agent,
            "Symbol.toStringTag",
            Value.from("ArrayBuffer"),
            .{
                .writable = false,
                .enumerable = false,
                .configurable = true,
            },
        );
    }

    /// 25.1.6.1 get ArrayBuffer.prototype.byteLength
    /// https://tc39.es/ecma262/#sec-get-arraybuffer.prototype.bytelength
    fn byteLength(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let obj be the this value.
        // 2. Perform ? RequireInternalSlot(obj, [[ArrayBufferData]]).
        const array_buffer = try this_value.requireInternalSlot(agent, ArrayBuffer);

        // 3. If IsSharedArrayBuffer(obj) is true, throw a TypeError exception.
        if (isSharedArrayBuffer(array_buffer)) {
            return agent.throwException(
                .type_error,
                "{f} is not an ArrayBuffer object",
                .{this_value},
            );
        }

        // 4. If IsDetachedBuffer(obj) is true, return +0𝔽.
        if (isDetachedBuffer(array_buffer)) return Value.from(0);

        // 5. Let length be obj.[[ArrayBufferByteLength]].
        const length = @backingInt(array_buffer.fields.byte_length);

        // 6. Return 𝔽(length).
        return Value.from(length);
    }

    /// 25.1.6.3 get ArrayBuffer.prototype.detached
    /// https://tc39.es/ecma262/#sec-get-arraybuffer.prototype.detached
    fn detached(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let obj be the this value.
        // 2. Perform ? RequireInternalSlot(obj, [[ArrayBufferData]]).
        const array_buffer = try this_value.requireInternalSlot(agent, ArrayBuffer);

        // 3. If IsSharedArrayBuffer(obj) is true, throw a TypeError exception.
        if (isSharedArrayBuffer(array_buffer)) {
            return agent.throwException(
                .type_error,
                "{f} is not an ArrayBuffer object",
                .{this_value},
            );
        }

        // 4. Return IsDetachedBuffer(obj).
        return Value.from(isDetachedBuffer(array_buffer));
    }

    /// 25.1.6.4 get ArrayBuffer.prototype.maxByteLength
    /// https://tc39.es/ecma262/#sec-get-arraybuffer.prototype.maxbytelength
    fn maxByteLength(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let obj be the this value.
        // 2. Perform ? RequireInternalSlot(obj, [[ArrayBufferData]]).
        const array_buffer = try this_value.requireInternalSlot(agent, ArrayBuffer);

        // 3. If IsSharedArrayBuffer(obj) is true, throw a TypeError exception.
        if (isSharedArrayBuffer(array_buffer)) {
            return agent.throwException(
                .type_error,
                "{f} is not an ArrayBuffer object",
                .{this_value},
            );
        }

        // 4. If IsDetachedBuffer(obj) is true, return +0𝔽.
        if (isDetachedBuffer(array_buffer)) return Value.from(0);

        // 5. If IsFixedLengthArrayBuffer(obj) is true, then
        const length = if (isFixedLengthArrayBuffer(array_buffer)) blk: {
            // a. Let length be obj.[[ArrayBufferByteLength]].
            break :blk array_buffer.fields.byte_length;
        } else blk: {
            // 6. Else,
            // a. Let length be obj.[[ArrayBufferMaxByteLength]].
            break :blk array_buffer.fields.max_byte_length.unwrap().?;
        };

        // 7. Return 𝔽(length).
        return Value.from(@backingInt(length));
    }

    /// 25.1.6.5 get ArrayBuffer.prototype.resizable
    /// https://tc39.es/ecma262/#sec-get-arraybuffer.prototype.resizable
    fn resizable(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let obj be the this value.
        // 2. Perform ? RequireInternalSlot(obj, [[ArrayBufferData]]).
        const array_buffer = try this_value.requireInternalSlot(agent, ArrayBuffer);

        // 3. If IsSharedArrayBuffer(obj) is true, throw a TypeError exception.
        if (isSharedArrayBuffer(array_buffer)) {
            return agent.throwException(
                .type_error,
                "{f} is not an ArrayBuffer object",
                .{this_value},
            );
        }

        // 4. If IsFixedLengthArrayBuffer(obj) is false, return true.
        // 5. Return false.
        return Value.from(!isFixedLengthArrayBuffer(array_buffer));
    }

    /// 25.1.6.6 ArrayBuffer.prototype.resize ( newLength )
    /// https://tc39.es/ecma262/#sec-arraybuffer.prototype.resize
    fn resize(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const new_length = arguments.get(0);

        // 1. Let obj be the this value.
        // 2. Perform ? RequireInternalSlot(obj, [[ArrayBufferMaxByteLength]]).
        const array_buffer = try this_value.requireInternalSlot(agent, ArrayBuffer);

        // 3. If IsSharedArrayBuffer(obj) is true, throw a TypeError exception.
        if (isSharedArrayBuffer(array_buffer)) {
            return agent.throwException(
                .type_error,
                "{f} is not an ArrayBuffer object",
                .{this_value},
            );
        }

        if (isFixedLengthArrayBuffer(array_buffer)) {
            return agent.throwException(.type_error, "ArrayBuffer is not resizable", .{});
        }

        // 4. Let newByteLength be ? ToIndex(newLength).
        const new_byte_length: ByteLength = @fromBackingInt(try new_length.toIndex(agent));

        // 5. If IsDetachedBuffer(obj) is true, throw a TypeError exception.
        if (isDetachedBuffer(array_buffer)) {
            return agent.throwException(.type_error, "ArrayBuffer is detached", .{});
        }

        // 6. If newByteLength > obj.[[ArrayBufferMaxByteLength]], throw a RangeError exception.
        if (@backingInt(new_byte_length) > @backingInt(array_buffer.fields.max_byte_length)) {
            return agent.throwException(.range_error, "Maximum buffer size exceeded", .{});
        }

        // 7. Let hostHandled be ? HostResizeArrayBuffer(obj, newByteLength).
        const host_handled = try agent.host_hooks.hostResizeArrayBuffer(array_buffer, new_byte_length);

        // 8. If hostHandled is handled, return undefined.
        if (host_handled == .handled) return .undefined;

        // 9. Let oldBlock be obj.[[ArrayBufferData]].
        // 10. Let newBlock be ? CreateByteDataBlock(newByteLength).
        // 11. Let copyLength be min(newByteLength, obj.[[ArrayBufferByteLength]]).
        // 12. Perform CopyDataBlockBytes(newBlock, 0, oldBlock, 0, copyLength).
        // 13. NOTE: Neither creation of the new Data Block nor copying from the old Data Block are
        //     observable. Implementations may implement this method as in-place growth or
        //     shrinkage.
        // 14. Set obj.[[ArrayBufferData]] to newBlock.
        array_buffer.fields.data_block.?.resize(agent.gc_allocator, new_byte_length) catch {
            return agent.throwException(
                .range_error,
                "Cannot resize buffer to size {d}",
                .{new_byte_length},
            );
        };

        // 15. Set obj.[[ArrayBufferByteLength]] to newByteLength.
        array_buffer.fields.byte_length = new_byte_length;

        // 16. Return undefined.
        return .undefined;
    }

    /// 25.1.6.7 ArrayBuffer.prototype.slice ( start, end )
    /// https://tc39.es/ecma262/#sec-arraybuffer.prototype.slice
    fn slice(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const realm = agent.currentRealm();
        const start = arguments.get(0);
        const end = arguments.get(1);

        // 1. Let obj be the this value.
        // 2. Perform ? RequireInternalSlot(obj, [[ArrayBufferData]]).
        const array_buffer = try this_value.requireInternalSlot(agent, ArrayBuffer);

        // 3. If IsSharedArrayBuffer(obj) is true, throw a TypeError exception.
        if (isSharedArrayBuffer(array_buffer)) {
            return agent.throwException(
                .type_error,
                "{f} is not an ArrayBuffer object",
                .{this_value},
            );
        }

        // 4. If IsDetachedBuffer(obj) is true, throw a TypeError exception.
        if (isDetachedBuffer(array_buffer)) {
            return agent.throwException(.type_error, "ArrayBuffer is detached", .{});
        }

        // 5. Let length be obj.[[ArrayBufferByteLength]].
        const length = @backingInt(array_buffer.fields.byte_length);

        // 6. Let first be ? ToClampedIndex(start, length).
        const first = try start.toClampedIndex(agent, length);

        // 7. If end is undefined, let final be length; else let final be ? ToClampedIndex(end,
        //    length).
        const final = if (end.isUndefined())
            length
        else
            try end.toClampedIndex(agent, length);

        // 8. Let newLength be max(final - first, 0).
        const new_length: ByteLength = @fromBackingInt(final -| first);

        // 9. Let ctor be ? SpeciesConstructor(obj, %ArrayBuffer%).
        const ctor = try array_buffer.object.speciesConstructor(
            agent,
            try realm.intrinsic(.array_buffer),
        );

        // 10. Let new be ? Construct(ctor, « 𝔽(newLength) »).
        const new_object = try ctor.construct(
            agent,
            &.{Value.from(@backingInt(new_length))},
            null,
        );

        // 11. Perform ? RequireInternalSlot(new, [[ArrayBufferData]]).
        const new = try Value.from(new_object).requireInternalSlot(agent, ArrayBuffer);

        // 12. If IsSharedArrayBuffer(new) is true, throw a TypeError exception.
        if (isSharedArrayBuffer(new)) {
            return agent.throwException(
                .type_error,
                "{f} is not an ArrayBuffer object",
                .{Value.from(new_object)},
            );
        }

        // 13. If IsDetachedBuffer(new) is true, throw a TypeError exception.
        if (isDetachedBuffer(new)) {
            return agent.throwException(.type_error, "ArrayBuffer is detached", .{});
        }

        // 14. If SameValue(new, obj) is true, throw a TypeError exception.
        if (new == array_buffer) {
            return agent.throwException(
                .type_error,
                "Species constructor must return a new object",
                .{},
            );
        }

        // 15. If new.[[ArrayBufferByteLength]] < newLength, throw a TypeError exception.
        if (@backingInt(new.fields.byte_length) < @backingInt(new_length)) {
            return agent.throwException(.type_error, "ArrayBuffer is too small", .{});
        }

        // 16. NOTE: Side-effects of the above steps may have detached or resized obj.
        // 17. If IsDetachedBuffer(obj) is true, throw a TypeError exception.
        if (isDetachedBuffer(array_buffer)) {
            return agent.throwException(.type_error, "ArrayBuffer is detached", .{});
        }

        // 18. Let fromBlock be obj.[[ArrayBufferData]].
        const from_block = array_buffer.fields.data_block.?;

        // 19. Let toBlock be new.[[ArrayBufferData]].
        const to_block = new.fields.data_block.?;

        // 20. Let currentLength be obj.[[ArrayBufferByteLength]].
        const current_length = array_buffer.fields.byte_length;

        // 21. Let maxCount be currentLength - first.
        const max_count = @backingInt(current_length) -| first;

        // 22. If maxCount > 0, then
        if (max_count > 0) {
            // a. Let count be min(newLength, maxCount).
            const count = @min(@backingInt(new_length), max_count);

            // b. Perform CopyDataBlockBytes(toBlock, 0, fromBlock, first, count).
            copyDataBlockBytes(to_block, 0, from_block, first, count);
        }

        // 23. Return new.
        return Value.from(&new.object);
    }

    /// 25.1.6.8 ArrayBuffer.prototype.transfer ( [ newLength ] )
    /// https://tc39.es/ecma262/#sec-arraybuffer.prototype.transfer
    fn transfer(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const new_length = arguments.get(0);

        // 1. Let obj be the this value.
        // 2. Return ? ArrayBufferCopyAndDetach(obj, newLength, preserve-resizability).
        const array_buffer = try arrayBufferCopyAndDetach(agent, this_value, new_length, .preserve_resizability);
        return Value.from(&array_buffer.object);
    }

    /// 25.1.6.9 ArrayBuffer.prototype.transferToFixedLength ( [ newLength ] )
    /// https://tc39.es/ecma262/#sec-arraybuffer.prototype.transfertofixedlength
    fn transferToFixedLength(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const new_length = arguments.get(0);

        // 1. Let obj be the this value.
        // 2. Return ? ArrayBufferCopyAndDetach(obj, newLength, fixed-length).
        const array_buffer = try arrayBufferCopyAndDetach(agent, this_value, new_length, .fixed_length);
        return Value.from(&array_buffer.object);
    }
};

/// 25.1.7 Properties of ArrayBuffer Instances
/// https://tc39.es/ecma262/#sec-properties-of-the-arraybuffer-instances
pub const ArrayBuffer = MakeObject(.{
    .Fields = struct {
        /// [[ArrayBufferData]]
        data_block: ?DataBlock,

        /// [[ArrayBufferByteLength]]
        byte_length: ByteLength,

        /// [[ArrayBufferDetachKey]]
        detach_key: Value,

        /// [[ArrayBufferMaxByteLength]]
        max_byte_length: OptionalByteLength,
    },
    .tag = .array_buffer,
    .display_name = "ArrayBuffer",
});
