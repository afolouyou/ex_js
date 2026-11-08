//! 25.4 The Atomics Object
//! https://tc39.es/ecma262/#sec-atomics-object

const builtin = @import("builtin");
const std = @import("std");

const builtins = @import("../builtins.zig");
const execution = @import("../execution.zig");
const types = @import("../types.zig");
const utils = @import("../utils.zig");

const Agent = execution.Agent;
const Arguments = types.Arguments;
const BigInt = types.BigInt;
const Object = types.Object;
const PromiseCapability = builtins.promise.PromiseCapability;
const PropertyKey = types.PropertyKey;
const Realm = execution.Realm;
const TypedArrayWithBufferWitness = builtins.typed_array.TypedArrayWithBufferWitness;
const Value = types.Value;
const getModifySetValueInBuffer = builtins.getModifySetValueInBuffer;
const getValueFromBuffer = builtins.getValueFromBuffer;
const isSharedArrayBuffer = builtins.isSharedArrayBuffer;
const newPromiseCapability = builtins.newPromiseCapability;
const noexcept = utils.noexcept;
const numericToRawBytes = builtins.numericToRawBytes;
const ordinaryObjectCreate = builtins.ordinaryObjectCreate;
const rawBytesToNumeric = builtins.rawBytesToNumeric;
const sameValue = types.sameValue;
const setValueInBuffer = builtins.setValueInBuffer;
const typedArrayElementSize = builtins.typedArrayElementSize;
const typedArrayLength = builtins.typedArrayLength;
const validateTypedArray = builtins.validateTypedArray;
const validateTypedArrayBounds = builtins.validateTypedArrayBounds;

/// 25.4.3.1 ValidateIntegerTypedArray ( ta, waitable )
/// https://tc39.es/ecma262/#sec-validateintegertypedarray
fn validateIntegerTypedArray(
    agent: *Agent,
    typed_array_value: Value,
    waitable: bool,
) Agent.Error!TypedArrayWithBufferWitness {
    // 1. NOTE: Bounds checking is not a synchronizing operation when ta's backing buffer is a
    //    growable SharedArrayBuffer.

    // 2. Let taRecord be ? ValidateTypedArray(ta, unordered).
    const ta = try validateTypedArray(agent, typed_array_value, .unordered);
    const typed_array = ta.object;

    // 3. Let elementType be TypedArrayElementType(ta).
    const element_type = typed_array.fields.element_type;

    // 4. If IsNoTearConfiguration(elementType, seq-cst) is false, throw a TypeError exception.
    if (!element_type.isNoTearConfiguration(.seq_cst)) {
        return agent.throwException(
            .type_error,
            "Atomic operations are only supported on integer typed arrays",
            .{},
        );
    }

    // 5. If waitable is true and elementType is neither int32 nor bigint64, throw a TypeError
    //    exception.
    if (waitable and element_type != .int32 and element_type != .bigint64) {
        return agent.throwException(
            .type_error,
            "Only Int32Array and BigInt64Array can be waited on, got {s}",
            .{element_type.typedArrayName()},
        );
    }

    // 6. Return taRecord.
    return ta;
}

/// 25.4.3.2 ValidateAtomicAccess ( taRecord, requestIndex )
/// https://tc39.es/ecma262/#sec-validateatomicaccess
fn validateAtomicAccess(
    agent: *Agent,
    ta: TypedArrayWithBufferWitness,
    request_index: Value,
) Agent.Error!u53 {
    // 1. Let length be TypedArrayLength(taRecord).
    const length = typedArrayLength(ta);

    // 2. Let accessIndex be ? ToIndex(requestIndex).
    const access_index = try request_index.toIndex(agent);

    // 3. Assert: accessIndex ≥ 0.
    // 4. If accessIndex ≥ length, throw a RangeError exception.
    if (access_index >= @backingInt(length)) {
        return agent.throwException(
            .range_error,
            "Invalid index {d} for typed array with length {d}",
            .{ access_index, length },
        );
    }

    // 5. Let ta be taRecord.[[Object]].
    const typed_array = ta.object;

    // 6. Let elementSize be TypedArrayElementSize(ta).
    const element_size = typedArrayElementSize(typed_array);

    // 7. Let offset be ta.[[ByteOffset]].
    const offset = typed_array.fields.byte_offset;

    // 8. Return (accessIndex × elementSize) + offset.
    return (access_index * element_size) + @backingInt(offset);
}

/// 25.4.3.3 ValidateAtomicAccessOnIntegerTypedArray ( ta, requestIndex )
/// https://tc39.es/ecma262/#sec-validateatomicaccessonintegertypedarray
fn validateAtomicAccessOnIntegerTypedArray(
    agent: *Agent,
    typed_array: Value,
    request_index: Value,
) Agent.Error!u53 {
    // 1. Let taRecord be ? ValidateIntegerTypedArray(ta, false).
    const ta = try validateIntegerTypedArray(agent, typed_array, false);

    // 2. Return ? ValidateAtomicAccess(taRecord, requestIndex).
    return validateAtomicAccess(agent, ta, request_index);
}

/// 25.4.3.4 RevalidateAtomicAccess ( ta, byteIndexInBuffer )
/// https://tc39.es/ecma262/#sec-revalidateatomicaccess
fn revalidateAtomicAccess(
    agent: *Agent,
    typed_array: *const builtins.TypedArray,
    byte_index_in_buffer: u53,
) Agent.Error!void {
    // 1. NOTE: Bounds checking is not a synchronizing operation when ta's backing buffer is a
    //    growable SharedArrayBuffer.

    // 2. Let taRecord be ? ValidateTypedArrayBounds(ta, unordered).
    const ta = try validateTypedArrayBounds(agent, typed_array, .unordered);

    // 3. Assert: byteIndexInBuffer ≥ ta.[[ByteOffset]].
    std.debug.assert(byte_index_in_buffer >= @backingInt(typed_array.fields.byte_offset));

    // 4. If byteIndexInBuffer ≥ taRecord.[[CachedBufferByteLength]], throw a RangeError exception.
    if (byte_index_in_buffer >= @backingInt(ta.cached_buffer_byte_length)) {
        return agent.throwException(
            .range_error,
            "Invalid index {d} for buffer with byte length {d}",
            .{ byte_index_in_buffer, ta.cached_buffer_byte_length },
        );
    }

    // 5. Return unused.
}

/// 25.4.3.14 DoWait ( mode, ta, index, value, timeout )
/// https://tc39.es/ecma262/#sec-dowait
fn doWait(
    agent: *Agent,
    mode: enum { sync, async },
    typed_array_value: Value,
    index: Value,
    value: Value,
    timeout: Value,
) Agent.Error!Value {
    const realm = agent.currentRealm();

    // 1. Let taRecord be ? ValidateIntegerTypedArray(ta, true).
    const ta = try validateIntegerTypedArray(agent, typed_array_value, true);

    // 2. Let buffer be taRecord.[[Object]].[[ViewedArrayBuffer]].
    const buffer = ta.object.fields.viewed_array_buffer;

    // 3. If IsSharedArrayBuffer(buffer) is false, throw a TypeError exception.
    if (!isSharedArrayBuffer(buffer)) {
        return agent.throwException(
            .type_error,
            "TypedArray must be backed by a SharedArrayBuffer",
            .{},
        );
    }

    // 4. Let byteIndexInBuffer be ? ValidateAtomicAccess(taRecord, index).
    const byte_index_in_buffer = try validateAtomicAccess(agent, ta, index);

    const typed_array = typed_array_value.asObject().as(builtins.TypedArray);

    // 5. Let elementType be TypedArrayElementType(ta).
    const element_type = typed_array.fields.element_type;

    // 6. Assert: elementType is either bigint64 or int32.
    // 7. If elementType is bigint64, let expected be ? ToBigInt64(value); else let expected be
    //    ? ToInt32(value).
    const expected = switch (element_type) {
        .bigint64 => Value.from(try BigInt.fromValue(agent, try value.toBigInt64(agent))),
        .int32 => Value.from(try value.toInt32(agent)),
        else => unreachable,
    };

    // 8. Let timeoutNumber be ? ToNumber(timeout).
    const timeout_number = try timeout.toNumber(agent);

    // 9. If timeoutNumber is either NaN or +∞𝔽, let realTimeout be +∞.
    // 10. Else if timeoutNumber is -∞𝔽, let realTimeout be 0.
    // 11. Else, let realTimeout be max(ℝ(timeoutNumber), 0).
    const real_timeout = if (timeout_number.isNan() or timeout_number.isPositiveInf())
        std.math.inf(f64)
    else if (timeout_number.isNegativeInf())
        0
    else
        @max(timeout_number.asFloat(), 0);

    // 12. If mode is sync and AgentCanSuspend() is false, throw a TypeError exception.

    // 13. Let block be buffer.[[ArrayBufferData]].
    const block = buffer.fields.data_block;

    // TODO: 14. Let waiterList be GetWaiterList(block, byteIndexInBuffer).
    _ = block;

    var promise_capability: PromiseCapability = undefined;
    var result_obj: *Object = undefined;

    // 15. If mode is sync, then
    if (mode == .sync) {
        // a. Let promiseCapability be blocking.
        // b. Let resultObj be undefined.
    } else {
        // 16. Else,
        // a. Let promiseCapability be ! NewPromiseCapability(%Promise%).
        promise_capability = newPromiseCapability(
            agent,
            Value.from(try realm.intrinsic(.promise)),
        ) catch |err| try noexcept(err);

        // b. Let resultObj be OrdinaryObjectCreate(%Object.prototype%).
        result_obj = try ordinaryObjectCreate(
            agent,
            try realm.intrinsic(.object_prototype),
        );
    }

    // TODO: 17. Perform EnterCriticalSection(waiterList).

    // 18. Let witness be GetValueFromBuffer(buffer, byteIndexInBuffer, elementType, true, seq-cst).
    const witness = switch (element_type) {
        .uint8_clamped, .float16, .float32, .float64 => unreachable,
        inline else => |@"type"| blk: {
            const witness = getValueFromBuffer(
                agent,
                buffer,
                byte_index_in_buffer,
                @"type",
                true,
                .seq_cst,
                null,
            );
            break :blk if (@"type".isBigIntElementType())
                Value.from(try BigInt.fromValue(agent, witness))
            else
                Value.from(witness);
        },
    };

    // 19. If expected ≠ witness, then
    if (!sameValue(expected, witness)) {
        // TODO: a. Perform LeaveCriticalSection(waiterList).

        // b. If mode is sync, return "not-equal".
        if (mode == .sync) return Value.from("not-equal");

        // c. Perform ! CreateDataPropertyOrThrow(resultObj, "async", false).
        try result_obj.createDataPropertyDirect(
            agent,
            PropertyKey.from("async"),
            .false,
        );

        // d. Perform ! CreateDataPropertyOrThrow(resultObj, "value", "not-equal").
        try result_obj.createDataPropertyDirect(
            agent,
            PropertyKey.from("value"),
            Value.from("not-equal"),
        );

        // e. Return resultObj.
        return Value.from(result_obj);
    }

    // 20. If realTimeout = 0 and mode is async, then
    if (real_timeout == 0 and mode == .async) {
        // a. NOTE: There is no special handling of synchronous immediate timeouts. Asynchronous
        //    immediate timeouts have special handling in order to fail fast and avoid unnecessary
        //    Promise jobs.

        // TODO: b. Perform LeaveCriticalSection(waiterList).

        // c. Perform ! CreateDataPropertyOrThrow(resultObj, "async", false).
        try result_obj.createDataPropertyDirect(
            agent,
            PropertyKey.from("async"),
            .false,
        );

        // d. Perform ! CreateDataPropertyOrThrow(resultObj, "value", "timed-out").
        try result_obj.createDataPropertyDirect(
            agent,
            PropertyKey.from("value"),
            Value.from("timed-out"),
        );

        // e. Return resultObj.
        return Value.from(result_obj);
    }

    // TODO: 21-30.
    const waiter = .{ .result = "timed-out" };

    // 31. If mode is sync, return waiterRecord.[[Result]].
    if (mode == .sync) return Value.from(waiter.result);

    // 32. Perform ! CreateDataPropertyOrThrow(resultObj, "async", true).
    try result_obj.createDataPropertyDirect(
        agent,
        PropertyKey.from("async"),
        .true,
    );

    // 33. Perform ! CreateDataPropertyOrThrow(resultObj, "value", promiseCapability.[[Promise]]).
    try result_obj.createDataPropertyDirect(
        agent,
        PropertyKey.from("value"),
        Value.from(promise_capability.promise),
    );

    // 34. Return resultObj.
    return Value.from(result_obj);
}

/// 25.4.3.17 AtomicReadModifyWrite ( ta, index, value, op )
/// https://tc39.es/ecma262/#sec-atomicreadmodifywrite
fn atomicReadModifyWrite(
    agent: *Agent,
    typed_array_value: Value,
    index: Value,
    value: Value,
    comptime op: std.lang.AtomicRmwOp,
) Agent.Error!Value {
    // 1. Let byteIndexInBuffer be ? ValidateAtomicAccessOnIntegerTypedArray(ta, index).
    const byte_index_in_buffer = try validateAtomicAccessOnIntegerTypedArray(
        agent,
        typed_array_value,
        index,
    );
    const typed_array = typed_array_value.asObject().as(builtins.TypedArray);

    // 2. If ta.[[ContentType]] is bigint, let coerced be ? ToBigInt(value).
    // 3. Else, let coerced be 𝔽(? ToIntegerOrInfinity(value)).
    const coerced = if (typed_array.fields.content_type == .bigint)
        Value.from(try value.toBigInt(agent))
    else
        Value.from(try value.toIntegerOrInfinity(agent));

    // 4. Perform ? RevalidateAtomicAccess(ta, byteIndexInBuffer).
    try revalidateAtomicAccess(agent, typed_array, byte_index_in_buffer);

    // 5. Let buffer be ta.[[ViewedArrayBuffer]].
    const buffer = typed_array.fields.viewed_array_buffer;

    // 6. Let elementType be TypedArrayElementType(ta).
    switch (typed_array.fields.element_type) {
        .uint8_clamped, .float16, .float32, .float64 => unreachable,
        inline else => |@"type"| {
            // Bypass 'expected 32-bit integer type or smaller; found 64-bit integer type' for @atomicRmw()
            if (comptime @bitSizeOf(@"type".type()) > builtin.target.ptrBitWidth()) {
                return agent.throwException(
                    .internal_error,
                    "Atomic operation on {s} not supported on this platform",
                    .{@"type".typedArrayName()},
                );
            }
            // 7. Return GetModifySetValueInBuffer(buffer, byteIndexInBuffer, elementType, coerced,
            //    op).
            const modified_value = try getModifySetValueInBuffer(
                agent,
                buffer,
                byte_index_in_buffer,
                @"type",
                coerced,
                op,
            );
            return if (@"type".isBigIntElementType())
                Value.from(try BigInt.fromValue(agent, modified_value))
            else
                Value.from(modified_value);
        },
    }
}

pub const namespace = struct {
    pub fn create(agent: *Agent, realm: *Realm) std.mem.Allocator.Error!*Object {
        return ordinaryObjectCreate(agent, try realm.intrinsic(.object_prototype));
    }

    pub fn init(agent: *Agent, realm: *Realm, object: *Object) std.mem.Allocator.Error!void {
        try object.defineBuiltinFunction(agent, "add", add, 3, realm);
        try object.defineBuiltinFunction(agent, "and", @"and", 3, realm);
        try object.defineBuiltinFunction(agent, "compareExchange", compareExchange, 4, realm);
        try object.defineBuiltinFunction(agent, "exchange", exchange, 3, realm);
        try object.defineBuiltinFunction(agent, "isLockFree", isLockFree, 1, realm);
        try object.defineBuiltinFunction(agent, "load", load, 2, realm);
        try object.defineBuiltinFunction(agent, "notify", notify, 3, realm);
        try object.defineBuiltinFunction(agent, "or", @"or", 3, realm);
        try object.defineBuiltinFunction(agent, "pause", pause, 0, realm);
        try object.defineBuiltinFunction(agent, "store", store, 3, realm);
        try object.defineBuiltinFunction(agent, "sub", sub, 3, realm);
        try object.defineBuiltinFunction(agent, "wait", wait, 4, realm);
        try object.defineBuiltinFunction(agent, "waitAsync", waitAsync, 4, realm);
        try object.defineBuiltinFunction(agent, "xor", xor, 3, realm);

        // 25.4.18 Atomics [ %Symbol.toStringTag% ]
        // https://tc39.es/ecma262/#sec-atomics-%symbol.tostringtag%
        try object.defineBuiltinPropertyWithAttributes(
            agent,
            "Symbol.toStringTag",
            Value.from("Atomics"),
            .{
                .writable = false,
                .enumerable = false,
                .configurable = true,
            },
        );
    }

    /// 25.4.4 Atomics.add ( ta, index, value )
    /// https://tc39.es/ecma262/#sec-atomics.add
    fn add(agent: *Agent, _: Value, arguments: Arguments) Agent.Error!Value {
        const typed_array = arguments.get(0);
        const index = arguments.get(1);
        const value = arguments.get(2);

        // 1. Let add be a new read-modify-write modification function with parameters (xBytes,
        //    yBytes) that captures ta and performs the following steps atomically when called:
        //     a-j.
        // 2. Return ? AtomicReadModifyWrite(ta, index, value, add).
        return atomicReadModifyWrite(agent, typed_array, index, value, .Add);
    }

    /// 25.4.5 Atomics.and ( ta, index, value )
    /// https://tc39.es/ecma262/#sec-atomics.and
    fn @"and"(agent: *Agent, _: Value, arguments: Arguments) Agent.Error!Value {
        const typed_array = arguments.get(0);
        const index = arguments.get(1);
        const value = arguments.get(2);

        // 1. Let and be a new read-modify-write modification function with parameters (xBytes,
        //    yBytes) that captures nothing and performs the following steps atomically when called:
        //     a. Return ByteListBitwiseOp(`&`, xBytes, yBytes).
        // 2. Return ? AtomicReadModifyWrite(ta, index, value, and).
        return atomicReadModifyWrite(agent, typed_array, index, value, .And);
    }

    /// 25.4.6 Atomics.compareExchange ( ta, index, expectedValue, replacementValue )
    /// https://tc39.es/ecma262/#sec-atomics.compareexchange
    fn compareExchange(agent: *Agent, _: Value, arguments: Arguments) Agent.Error!Value {
        const typed_array_value = arguments.get(0);
        const index = arguments.get(1);
        const expected_value = arguments.get(2);
        const replacement_value = arguments.get(3);

        // 1. Let byteIndexInBuffer be ? ValidateAtomicAccessOnIntegerTypedArray(ta, index).
        const byte_index_in_buffer = try validateAtomicAccessOnIntegerTypedArray(
            agent,
            typed_array_value,
            index,
        );
        const typed_array = typed_array_value.asObject().as(builtins.TypedArray);

        // 2. Let buffer be ta.[[ViewedArrayBuffer]].
        const buffer = typed_array.fields.viewed_array_buffer;

        // 3. Let block be buffer.[[ArrayBufferData]].
        // NOTE: This is only safe to access after step 6.

        // 4. If ta.[[ContentType]] is bigint, then
        const expected, const replacement = if (typed_array.fields.content_type == .bigint) .{
            // a. Let expected be ? ToBigInt(expectedValue).
            Value.from(try expected_value.toBigInt(agent)),

            // b. Let replacement be ? ToBigInt(replacementValue).
            Value.from(try replacement_value.toBigInt(agent)),
        } else .{
            // 5. Else,
            // a. Let expected be 𝔽(? ToIntegerOrInfinity(expectedValue)).
            Value.from(try expected_value.toIntegerOrInfinity(agent)),

            // b. Let replacement be 𝔽(? ToIntegerOrInfinity(replacementValue)).
            Value.from(try replacement_value.toIntegerOrInfinity(agent)),
        };

        // 6. Perform ? RevalidateAtomicAccess(ta, byteIndexInBuffer).
        try revalidateAtomicAccess(agent, typed_array, byte_index_in_buffer);

        const block = buffer.fields.data_block.?;

        // 7. Let elementType be TypedArrayElementType(ta).
        // 8. Let elementSize be TypedArrayElementSize(ta).

        // 9. Let agentRecord be the Agent Record of the surrounding agent.
        // 10. Let isLittleEndian be agentRecord.[[LittleEndian]].
        const is_little_endian = agent.little_endian;

        switch (typed_array.fields.element_type) {
            .uint8_clamped, .float16, .float32, .float64 => unreachable,
            inline else => |@"type"| {
                // Bypass 'expected 32-bit integer type or smaller; found 64-bit integer type' for @cmpxchgStrong()
                if (comptime @bitSizeOf(@"type".type()) > builtin.target.ptrBitWidth()) {
                    return agent.throwException(
                        .internal_error,
                        "Atomic operation on {s} not supported on this platform",
                        .{@"type".typedArrayName()},
                    );
                }
                // 11. Let expectedBytes be NumericToRawBytes(elementType, expected,
                //     isLittleEndian).
                const expected_bytes = try numericToRawBytes(
                    agent,
                    @"type",
                    expected,
                    is_little_endian,
                );

                // 12. Let replacementBytes be NumericToRawBytes(elementType, replacement,
                //     isLittleEndian).
                const replacement_bytes = try numericToRawBytes(
                    agent,
                    @"type",
                    replacement,
                    is_little_endian,
                );

                const raw_bytes_read = block.bytes[@intCast(byte_index_in_buffer)..@intCast(byte_index_in_buffer + @"type".elementSize())];
                var previous = std.mem.bytesToValue(@"type".type(), raw_bytes_read);

                // 13. If IsSharedArrayBuffer(buffer) is true, then
                if (isSharedArrayBuffer(buffer)) {
                    // a. Let rawBytesRead be AtomicCompareExchangeInSharedBlock(block,
                    //    byteIndexInBuffer, elementSize, expectedBytes, replacementBytes).
                    const ptr = std.mem.bytesAsValue(@"type".type(), raw_bytes_read);
                    _ = @cmpxchgStrong(
                        @"type".type(),
                        @as(*@"type".type(), @alignCast(ptr)),
                        std.mem.bytesToValue(@"type".type(), &expected_bytes),
                        std.mem.bytesToValue(@"type".type(), &replacement_bytes),
                        .seq_cst,
                        .seq_cst,
                    );
                } else {
                    // 14. Else,
                    // a. Let rawBytesRead be a List of length elementSize whose elements are the
                    //    sequence of elementSize bytes starting with block[byteIndexInBuffer].
                    // b. If ByteListEqual(rawBytesRead, expectedBytes) is true, then
                    if (std.mem.eql(u8, raw_bytes_read, &expected_bytes)) {
                        // i. Store the individual bytes of replacementBytes into block, starting at
                        //    block[byteIndexInBuffer].
                        @memcpy(raw_bytes_read, &replacement_bytes);
                    }
                }

                // 15. Return RawBytesToNumeric(elementType, rawBytesRead, isLittleEndian).
                const value = rawBytesToNumeric(
                    @"type",
                    std.mem.asBytes(&previous),
                    is_little_endian,
                );
                return if (@"type".isBigIntElementType())
                    Value.from(try BigInt.fromValue(agent, value))
                else
                    Value.from(value);
            },
        }
    }

    /// 25.4.7 Atomics.exchange ( ta, index, value )
    /// https://tc39.es/ecma262/#sec-atomics.exchange
    fn exchange(agent: *Agent, _: Value, arguments: Arguments) Agent.Error!Value {
        const typed_array = arguments.get(0);
        const index = arguments.get(1);
        const value = arguments.get(2);

        // 1. Let second be a new read-modify-write modification function with parameters (oldBytes,
        //    newBytes) that captures nothing and performs the following steps atomically when
        //    called:
        //     a. Return newBytes.
        // 2. Return ? AtomicReadModifyWrite(ta, index, value, second).
        return atomicReadModifyWrite(agent, typed_array, index, value, .Xchg);
    }

    /// 25.4.8 Atomics.isLockFree ( size )
    /// https://tc39.es/ecma262/#sec-atomics.islockfree
    fn isLockFree(agent: *Agent, _: Value, arguments: Arguments) Agent.Error!Value {
        const size = arguments.get(0);

        // 1. Let n be ? ToIntegerOrInfinity(size).
        const n = try size.toIntegerOrInfinity(agent);

        // NOTE: Everyone but LibJS hardcodes these, so we might as well :^)
        // 2. Let agentRecord be the Agent Record of the surrounding agent.
        // 3. If n = 1, return agentRecord.[[IsLockFree1]].
        // 4. If n = 2, return agentRecord.[[IsLockFree2]].
        // 5. If n = 4, return true.
        // 6. If n = 8, return agentRecord.[[IsLockFree8]].
        if (n == 1 or n == 2 or n == 4 or n == 8) return .true;

        // 7. Return false.
        return .false;
    }

    /// 25.4.9 Atomics.load ( ta, index )
    /// https://tc39.es/ecma262/#sec-atomics.load
    fn load(agent: *Agent, _: Value, arguments: Arguments) Agent.Error!Value {
        const typed_array_value = arguments.get(0);
        const index = arguments.get(1);

        // 1. Let byteIndexInBuffer be ? ValidateAtomicAccessOnIntegerTypedArray(ta, index).
        const byte_index_in_buffer = try validateAtomicAccessOnIntegerTypedArray(
            agent,
            typed_array_value,
            index,
        );
        const typed_array = typed_array_value.asObject().as(builtins.TypedArray);

        // 2. Perform ? RevalidateAtomicAccess(ta, byteIndexInBuffer).
        try revalidateAtomicAccess(agent, typed_array, byte_index_in_buffer);

        // 3. Let buffer be ta.[[ViewedArrayBuffer]].
        const buffer = typed_array.fields.viewed_array_buffer;

        // 4. Let elementType be TypedArrayElementType(ta).
        switch (typed_array.fields.element_type) {
            .uint8_clamped, .float16, .float32, .float64 => unreachable,
            inline else => |@"type"| {
                // 5. Return GetValueFromBuffer(buffer, byteIndexInBuffer, elementType, true,
                //    seq-cst).
                const value = getValueFromBuffer(
                    agent,
                    buffer,
                    byte_index_in_buffer,
                    @"type",
                    true,
                    .seq_cst,
                    null,
                );
                return if (@"type".isBigIntElementType())
                    Value.from(try BigInt.fromValue(agent, value))
                else
                    Value.from(value);
            },
        }
    }

    /// 25.4.10 Atomics.notify ( ta, index, count )
    /// https://tc39.es/ecma262/#sec-atomics.notify
    fn notify(agent: *Agent, _: Value, arguments: Arguments) Agent.Error!Value {
        const typed_array_value = arguments.get(0);
        const index = arguments.get(1);
        const count_value = arguments.get(2);

        // 1. Let taRecord be ? ValidateIntegerTypedArray(ta, true).
        const ta = try validateIntegerTypedArray(agent, typed_array_value, true);

        // 2. Let byteIndexInBuffer be ? ValidateAtomicAccess(taRecord, index).
        const byte_index_in_buffer = try validateAtomicAccess(agent, ta, index);
        const typed_array = typed_array_value.asObject().as(builtins.TypedArray);

        // 3. If count is undefined, then
        const count = if (count_value.isUndefined()) blk: {
            // a. Set count to +∞.
            break :blk std.math.inf(f64);
        } else blk: {
            // 4. Else,
            // a. Let intCount be ? ToIntegerOrInfinity(count).
            const int_count = try count_value.toIntegerOrInfinity(agent);

            // b. Set count to max(intCount, 0).
            break :blk @max(int_count, 0);
        };

        // 5. Let buffer be ta.[[ViewedArrayBuffer]].
        const buffer = typed_array.fields.viewed_array_buffer;

        // 6. Let block be buffer.[[ArrayBufferData]].
        // 7. If IsSharedArrayBuffer(buffer) is false, return +0𝔽.
        if (!isSharedArrayBuffer(buffer)) return Value.from(0);
        const block = buffer.fields.data_block.?;

        // TODO: 8. Let waiterList be GetWaiterList(block, byteIndexInBuffer).
        _ = block;
        _ = byte_index_in_buffer;

        // TODO: 9-13.
        _ = count;
        const waiters_count = 0;

        // 14. Return 𝔽(waitersCount).
        return Value.from(waiters_count);
    }

    /// 25.4.11 Atomics.or ( ta, index, value )
    /// https://tc39.es/ecma262/#sec-atomics.or
    fn @"or"(agent: *Agent, _: Value, arguments: Arguments) Agent.Error!Value {
        const typed_array = arguments.get(0);
        const index = arguments.get(1);
        const value = arguments.get(2);

        // 1. Let or be a new read-modify-write modification function with parameters (xBytes,
        //    yBytes) that captures nothing and performs the following steps atomically when called:
        //     a. Return ByteListBitwiseOp(`|`, xBytes, yBytes).
        // 2. Return ? AtomicReadModifyWrite(ta, index, value, or).
        return atomicReadModifyWrite(agent, typed_array, index, value, .Or);
    }

    /// 25.4.12 Atomics.pause ( )
    /// https://tc39.es/ecma262/#sec-atomics.pause
    fn pause(_: *Agent, _: Value, _: Arguments) Agent.Error!Value {
        // 1. If the execution environment of the ECMAScript implementation supports signaling to
        //    the operating system or CPU that the current executing code is in a spin-wait loop,
        //    send that signal.
        std.atomic.spinLoopHint();

        // 2. Return undefined.
        return .undefined;
    }

    /// 25.4.13 Atomics.store ( ta, index, value )
    /// https://tc39.es/ecma262/#sec-atomics.store
    fn store(agent: *Agent, _: Value, arguments: Arguments) Agent.Error!Value {
        const typed_array_value = arguments.get(0);
        const index = arguments.get(1);
        const value = arguments.get(2);

        // 1. Let byteIndexInBuffer be ? ValidateAtomicAccessOnIntegerTypedArray(ta, index).
        const byte_index_in_buffer = try validateAtomicAccessOnIntegerTypedArray(
            agent,
            typed_array_value,
            index,
        );
        const typed_array = typed_array_value.asObject().as(builtins.TypedArray);

        // 2. If ta.[[ContentType]] is bigint, let coerced be ? ToBigInt(value).
        // 3. Else, let coerced be 𝔽(? ToIntegerOrInfinity(value)).
        const coerced = if (typed_array.fields.content_type == .bigint)
            Value.from(try value.toBigInt(agent))
        else
            Value.from(try value.toIntegerOrInfinity(agent));

        // 4. Perform ? RevalidateAtomicAccess(ta, byteIndexInBuffer).
        try revalidateAtomicAccess(agent, typed_array, byte_index_in_buffer);

        // 5. Let buffer be ta.[[ViewedArrayBuffer]].
        const buffer = typed_array.fields.viewed_array_buffer;

        // 6. Let elementType be TypedArrayElementType(ta).
        switch (typed_array.fields.element_type) {
            .uint8_clamped, .float16, .float32, .float64 => unreachable,
            inline else => |@"type"| {
                // 7. Perform SetValueInBuffer(buffer, byteIndexInBuffer, elementType, coerced,
                //    true, seq-cst).
                try setValueInBuffer(
                    agent,
                    buffer,
                    byte_index_in_buffer,
                    @"type",
                    coerced,
                    true,
                    .seq_cst,
                    null,
                );
            },
        }

        // 8. Return coerced.
        return coerced;
    }

    /// 25.4.14 Atomics.sub ( ta, index, value )
    /// https://tc39.es/ecma262/#sec-atomics.sub
    fn sub(agent: *Agent, _: Value, arguments: Arguments) Agent.Error!Value {
        const typed_array = arguments.get(0);
        const index = arguments.get(1);
        const value = arguments.get(2);

        // 1. Let subtract be a new read-modify-write modification function with parameters (xBytes,
        //    yBytes) that captures ta and performs the following steps atomically when called:
        //     a-j.
        // 2. Return ? AtomicReadModifyWrite(ta, index, value, subtract).
        return atomicReadModifyWrite(agent, typed_array, index, value, .Sub);
    }

    /// 25.4.15 Atomics.wait ( ta, index, value, timeout )
    /// https://tc39.es/ecma262/#sec-atomics.wait
    fn wait(agent: *Agent, _: Value, arguments: Arguments) Agent.Error!Value {
        const typed_array = arguments.get(0);
        const index = arguments.get(1);
        const value = arguments.get(2);
        const timeout = arguments.get(3);

        // 1. Return ? DoWait(sync, ta, index, value, timeout).
        return doWait(agent, .sync, typed_array, index, value, timeout);
    }

    /// 25.4.16 Atomics.waitAsync ( ta, index, value, timeout )
    /// https://tc39.es/ecma262/#sec-atomics.waitasync
    fn waitAsync(agent: *Agent, _: Value, arguments: Arguments) Agent.Error!Value {
        const typed_array = arguments.get(0);
        const index = arguments.get(1);
        const value = arguments.get(2);
        const timeout = arguments.get(3);

        // 1. Return ? DoWait(async, ta, index, value, timeout).
        return doWait(agent, .async, typed_array, index, value, timeout);
    }

    /// 25.4.17 Atomics.xor ( ta, index, value )
    /// https://tc39.es/ecma262/#sec-atomics.xor
    fn xor(agent: *Agent, _: Value, arguments: Arguments) Agent.Error!Value {
        const typed_array = arguments.get(0);
        const index = arguments.get(1);
        const value = arguments.get(2);

        // 1. Let xor be a new read-modify-write modification function with parameters (xBytes,
        //    yBytes) that captures nothing and performs the following steps atomically when called:
        //     a. Return ByteListBitwiseOp(`^`, xBytes, yBytes).
        // 2. Return ? AtomicReadModifyWrite(ta, index, value, xor).
        return atomicReadModifyWrite(agent, typed_array, index, value, .Xor);
    }
};
