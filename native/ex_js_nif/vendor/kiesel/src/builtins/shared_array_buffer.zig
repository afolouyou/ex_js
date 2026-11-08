//! 25.2 SharedArrayBuffer Objects
//! https://tc39.es/ecma262/#sec-sharedarraybuffer-objects

const std = @import("std");

const builtins = @import("../builtins.zig");
const execution = @import("../execution.zig");
const types = @import("../types.zig");

const Agent = execution.Agent;
const Arguments = types.Arguments;
const ArrayBuffer = builtins.ArrayBuffer;
const ByteLength = types.ByteLength;
const DataBlock = types.DataBlock;
const Object = types.Object;
const OptionalByteLength = types.OptionalByteLength;
const Realm = execution.Realm;
const Value = types.Value;
const arrayBufferByteLength = builtins.arrayBufferByteLength;
const copyDataBlockBytes = types.copyDataBlockBytes;
const createBuiltinFunction = builtins.createBuiltinFunction;
const createSharedByteDataBlock = types.createSharedByteDataBlock;
const getArrayBufferMaxByteLengthOption = builtins.getArrayBufferMaxByteLengthOption;
const isFixedLengthArrayBuffer = builtins.isFixedLengthArrayBuffer;
const ordinaryCreateFromConstructor = builtins.ordinaryCreateFromConstructor;
const ordinaryObjectCreate = builtins.ordinaryObjectCreate;

/// 25.2.2.1 AllocateSharedArrayBuffer ( ctor, byteLength [ , maxByteLength ] )
/// https://tc39.es/ecma262/#sec-allocatesharedarraybuffer
pub fn allocateSharedArrayBuffer(
    agent: *Agent,
    ctor: *Object,
    byte_length: ByteLength,
    max_byte_length: OptionalByteLength,
) Agent.Error!*ArrayBuffer {
    // 1. Let slots be « [[ArrayBufferData]] ».

    // 2. If maxByteLength is present and maxByteLength is not empty, let allocatingGrowableBuffer
    //    be true; else let allocatingGrowableBuffer be false.
    const allocating_growable_buffer = max_byte_length != .none;

    // 3. If allocatingGrowableBuffer is true, then
    if (allocating_growable_buffer) {
        // a. If byteLength > maxByteLength, throw a RangeError exception.
        if (@backingInt(byte_length) > @backingInt(max_byte_length)) {
            return agent.throwException(.range_error, "Maximum buffer size exceeded", .{});
        }

        // NOTE: Checking for a reasonable size below the theoretical limit is non-standard but also
        //       done in other engines (and tested by test262)
        if (@backingInt(max_byte_length) > @backingInt(DataBlock.max_byte_length)) {
            return agent.throwException(.range_error, "Maximum buffer size exceeded", .{});
        }

        // b. Append [[ArrayBufferByteLengthData]] and [[ArrayBufferMaxByteLength]] to slots.
    }
    // 4. Else,
    //     a. Append [[ArrayBufferByteLength]] to slots.

    // 5. Let obj be ? OrdinaryCreateFromConstructor(ctor, "%SharedArrayBuffer.prototype%", slots).
    const array_buffer = try ordinaryCreateFromConstructor(
        builtins.ArrayBuffer,
        agent,
        ctor,
        .shared_array_buffer_prototype,
        .{
            .data_block = undefined,
            .byte_length = undefined,
            .detach_key = undefined,
            .max_byte_length = .none,
        },
    );

    // 6. If allocatingGrowableBuffer is true, let allocationLength be maxByteLength; else let
    //    allocationLength be byteLength.
    const allocation_length = max_byte_length.unwrap() orelse byte_length;

    // 7. Let block be ? CreateSharedByteDataBlock(allocationLength).
    const block = try createSharedByteDataBlock(agent, allocation_length);

    // 8. Set obj.[[ArrayBufferData]] to block.
    array_buffer.fields.data_block = block;

    // 9. If allocatingGrowableBuffer is true, then
    if (allocating_growable_buffer) {
        // a. Assert: byteLength ≤ maxByteLength.
        std.debug.assert(@backingInt(byte_length) <= @backingInt(max_byte_length));

        // b. Let byteLengthBlock be ? CreateSharedByteDataBlock(8).
        // c. Perform SetValueInBuffer(byteLengthBlock, 0, biguint64, ℤ(byteLength), true, seq-cst).
        // d. Set obj.[[ArrayBufferByteLengthData]] to byteLengthBlock.
        // NOTE: This is done with atomic load/store of the byte length
        array_buffer.fields.byte_length = byte_length;

        // e. Set obj.[[ArrayBufferMaxByteLength]] to maxByteLength.
        array_buffer.fields.max_byte_length = max_byte_length;
    } else {
        // 10. Else,
        // a. Set obj.[[ArrayBufferByteLength]] to byteLength.
        array_buffer.fields.byte_length = byte_length;
    }

    // 11. Return obj.
    return array_buffer;
}

/// 25.2.2.2 IsSharedArrayBuffer ( obj )
/// https://tc39.es/ecma262/#sec-issharedarraybuffer
pub fn isSharedArrayBuffer(array_buffer: *const ArrayBuffer) bool {
    // 1. If obj.[[ArrayBufferData]] is a Shared Data Block, return true.
    // 2. Return false.
    const data_block = array_buffer.fields.data_block orelse return false;
    return data_block.shared;
}

/// 25.2.2.3 IsGrowableSharedArrayBuffer ( obj )
/// https://tc39.es/ecma262/#sec-isgrowablesharedarraybuffer
pub fn isGrowableSharedArrayBuffer(array_buffer: *const ArrayBuffer) bool {
    // 1. If IsSharedArrayBuffer(obj) is true and obj has an [[ArrayBufferByteLengthData]] internal
    //    slot, return true.
    // 2. Return false.
    return isSharedArrayBuffer(array_buffer) and array_buffer.fields.max_byte_length != .none;
}

/// 25.2.4 Properties of the SharedArrayBuffer Constructor
/// https://tc39.es/ecma262/#sec-properties-of-the-sharedarraybuffer-constructor
pub const constructor = struct {
    pub fn create(agent: *Agent, realm: *Realm) std.mem.Allocator.Error!*Object {
        const builtin_function = try createBuiltinFunction(
            agent,
            .{ .constructor = impl },
            1,
            "SharedArrayBuffer",
            .{ .realm = realm, .proto = try realm.intrinsic(.function_prototype) },
        );
        return &builtin_function.object;
    }

    pub fn init(agent: *Agent, realm: *Realm, object: *Object) std.mem.Allocator.Error!void {
        try object.defineBuiltinAccessor(agent, "Symbol.species", @"Symbol.species", null, realm);

        // 25.2.4.1 SharedArrayBuffer.prototype
        // https://tc39.es/ecma262/#sec-sharedarraybuffer.prototype
        try object.defineBuiltinPropertyWithAttributes(
            agent,
            "prototype",
            Value.from(try realm.intrinsic(.shared_array_buffer_prototype)),
            .none,
        );
    }

    /// 25.2.3.1 SharedArrayBuffer ( length [ , options ] )
    /// https://tc39.es/ecma262/#sec-sharedarraybuffer-length
    fn impl(agent: *Agent, arguments: Arguments, new_target: ?*Object) Agent.Error!Value {
        const length = arguments.get(0);
        const options = arguments.get(1);

        // 1. If NewTarget is undefined, throw a TypeError exception.
        if (new_target == null) {
            return agent.throwException(
                .type_error,
                "SharedArrayBuffer must be constructed with 'new'",
                .{},
            );
        }

        // 2. Let byteLength be ? ToIndex(length).
        const byte_length: ByteLength = @fromBackingInt(try length.toIndex(agent));

        // 3. Let requestedMaxByteLength be ? GetArrayBufferMaxByteLengthOption(options).
        const requested_max_byte_length = try getArrayBufferMaxByteLengthOption(agent, options);

        // 4. Return ? AllocateSharedArrayBuffer(NewTarget, byteLength, requestedMaxByteLength).
        const shared_array_buffer = try allocateSharedArrayBuffer(
            agent,
            new_target.?,
            byte_length,
            requested_max_byte_length,
        );
        return Value.from(&shared_array_buffer.object);
    }

    /// 25.2.4.2 get SharedArrayBuffer [ %Symbol.species% ]
    /// https://tc39.es/ecma262/#sec-sharedarraybuffer-%symbol.species%
    fn @"Symbol.species"(_: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Return the this value.
        return this_value;
    }
};

/// 25.2.5 Properties of the SharedArrayBuffer Prototype Object
/// https://tc39.es/ecma262/#sec-properties-of-the-sharedarraybuffer-prototype-object
pub const prototype = struct {
    pub fn create(agent: *Agent, realm: *Realm) std.mem.Allocator.Error!*Object {
        return ordinaryObjectCreate(agent, try realm.intrinsic(.object_prototype));
    }

    pub fn init(agent: *Agent, realm: *Realm, object: *Object) std.mem.Allocator.Error!void {
        try object.defineBuiltinAccessor(agent, "byteLength", byteLength, null, realm);
        try object.defineBuiltinFunction(agent, "grow", grow, 1, realm);
        try object.defineBuiltinAccessor(agent, "growable", growable, null, realm);
        try object.defineBuiltinAccessor(agent, "maxByteLength", maxByteLength, null, realm);
        try object.defineBuiltinFunction(agent, "slice", slice, 2, realm);

        // 25.2.5.2 SharedArrayBuffer.prototype.constructor
        // https://tc39.es/ecma262/#sec-sharedarraybuffer.prototype.constructor
        try object.defineBuiltinProperty(
            agent,
            "constructor",
            Value.from(try realm.intrinsic(.shared_array_buffer)),
        );

        // 25.2.5.7 SharedArrayBuffer.prototype [ %Symbol.toStringTag% ]
        // https://tc39.es/ecma262/#sec-sharedarraybuffer.prototype-%symbol.tostringtag%
        try object.defineBuiltinPropertyWithAttributes(
            agent,
            "Symbol.toStringTag",
            Value.from("SharedArrayBuffer"),
            .{
                .writable = false,
                .enumerable = false,
                .configurable = true,
            },
        );
    }

    /// 25.2.5.1 get SharedArrayBuffer.prototype.byteLength
    /// https://tc39.es/ecma262/#sec-get-sharedarraybuffer.prototype.bytelength
    fn byteLength(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let obj be the this value.
        // 2. Perform ? RequireInternalSlot(obj, [[ArrayBufferData]]).
        const array_buffer = try this_value.requireInternalSlot(agent, ArrayBuffer);

        // 3. If IsSharedArrayBuffer(obj) is false, throw a TypeError exception.
        if (!isSharedArrayBuffer(array_buffer)) {
            return agent.throwException(
                .type_error,
                "{f} is not a SharedArrayBuffer object",
                .{this_value},
            );
        }

        // 4. Let length be ArrayBufferByteLength(obj, seq-cst).
        const length = arrayBufferByteLength(array_buffer, .seq_cst);

        // 5. Return 𝔽(length).
        return Value.from(@backingInt(length));
    }

    /// 25.2.5.3 SharedArrayBuffer.prototype.grow ( newLength )
    /// https://tc39.es/ecma262/#sec-sharedarraybuffer.prototype.grow
    fn grow(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const new_length = arguments.get(0);

        // 1. Let obj be the this value.
        // 2. Perform ? RequireInternalSlot(obj, [[ArrayBufferMaxByteLength]]).
        var array_buffer = try this_value.requireInternalSlot(agent, ArrayBuffer);

        // 3. If IsSharedArrayBuffer(obj) is false, throw a TypeError exception.
        if (!isSharedArrayBuffer(array_buffer)) {
            return agent.throwException(
                .type_error,
                "{f} is not a SharedArrayBuffer object",
                .{this_value},
            );
        }

        if (array_buffer.fields.max_byte_length == .none) {
            return agent.throwException(.type_error, "SharedArrayBuffer is not growable", .{});
        }

        // 4. Let newByteLength be ? ToIndex(newLength).
        const new_byte_length: ByteLength = @fromBackingInt(try new_length.toIndex(agent));

        // 5. Let hostHandled be ? HostGrowSharedArrayBuffer(obj, newByteLength).
        const host_handled = try agent.host_hooks.hostGrowSharedArrayBuffer(
            array_buffer,
            new_byte_length,
        );

        // 6. If hostHandled is handled, return undefined.
        if (host_handled == .handled) return .undefined;

        // 7. Let agentRecord be the Agent Record of the surrounding agent.
        // 8. Let isLittleEndian be agentRecord.[[LittleEndian]].
        // 9. Let byteLengthBlock be obj.[[ArrayBufferByteLengthData]].
        // 10. Let currentByteLengthRawBytes be GetRawBytesFromSharedBlock(byteLengthBlock, 0,
        //     biguint64, true, seq-cst).
        // 11. Let newByteLengthRawBytes be NumericToRawBytes(biguint64, ℤ(newByteLength),
        //     isLittleEndian).
        // 12. Repeat,
        // a. NOTE: This is a compare-and-exchange loop to ensure that parallel, racing grows of the
        //    same buffer are totally ordered, are not lost, and do not silently do nothing. The
        //    loop exits if it was able to attempt to grow uncontended.
        // b. Let currentByteLength be ℝ(RawBytesToNumeric(biguint64, currentByteLengthRawBytes,
        //    isLittleEndian)).
        const ptr: *usize = @ptrCast(&array_buffer.fields.byte_length);
        const current_byte_length: ByteLength = @fromBackingInt(@intCast(@atomicLoad(usize, ptr, .seq_cst)));

        // c. If newByteLength = currentByteLength, return undefined.
        if (new_byte_length == current_byte_length) return .undefined;

        // d. If newByteLength < currentByteLength or
        //    newByteLength > obj.[[ArrayBufferMaxByteLength]], throw a RangeError exception.
        if (@backingInt(new_byte_length) < @backingInt(current_byte_length)) {
            return agent.throwException(.range_error, "Cannot shrink buffer", .{});
        }
        if (@backingInt(new_byte_length) > @backingInt(array_buffer.fields.max_byte_length)) {
            return agent.throwException(.range_error, "Maximum buffer size exceeded", .{});
        }

        // e. Let byteLengthDelta be newByteLength - currentByteLength.
        // f. If it is impossible to create a new Shared Data Block value consisting of
        //    byteLengthDelta bytes, throw a RangeError exception.
        // g. NOTE: No new Shared Data Block is constructed and used here. The observable behaviour
        //    of growable SharedArrayBuffers is specified by allocating a max-sized Shared Data
        //    Block at construction time, and this step captures the requirement that
        //    implementations that run out of memory must throw a RangeError.
        // h. Let readByteLengthRawBytes be AtomicCompareExchangeInSharedBlock(byteLengthBlock, 0,
        //    8, currentByteLengthRawBytes, newByteLengthRawBytes).
        // i. If ByteListEqual(readByteLengthRawBytes, currentByteLengthRawBytes) is true, return
        //    undefined.
        // j. Set currentByteLengthRawBytes to readByteLengthRawBytes.
        @atomicStore(usize, ptr, @intCast(@backingInt(new_byte_length)), .seq_cst);
        return .undefined;
    }

    /// 25.2.5.4 get SharedArrayBuffer.prototype.growable
    /// https://tc39.es/ecma262/#sec-get-sharedarraybuffer.prototype.growable
    fn growable(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let obj be the this value.
        // 2. Perform ? RequireInternalSlot(obj, [[ArrayBufferData]]).
        const array_buffer = try this_value.requireInternalSlot(agent, ArrayBuffer);

        // 3. If IsSharedArrayBuffer(obj) is false, throw a TypeError exception.
        if (!isSharedArrayBuffer(array_buffer)) {
            return agent.throwException(
                .type_error,
                "{f} is not a SharedArrayBuffer object",
                .{this_value},
            );
        }

        // 4. If IsFixedLengthArrayBuffer(obj) is false, return true.
        // 5. Return false.
        return Value.from(!isFixedLengthArrayBuffer(array_buffer));
    }

    /// 25.2.5.5 get SharedArrayBuffer.prototype.maxByteLength
    /// https://tc39.es/ecma262/#sec-get-sharedarraybuffer.prototype.maxbytelength
    fn maxByteLength(agent: *Agent, this_value: Value, _: Arguments) Agent.Error!Value {
        // 1. Let obj be the this value.
        // 2. Perform ? RequireInternalSlot(obj, [[ArrayBufferData]]).
        const array_buffer = try this_value.requireInternalSlot(agent, ArrayBuffer);

        // 3. If IsSharedArrayBuffer(obj) is false, throw a TypeError exception.
        if (!isSharedArrayBuffer(array_buffer)) {
            return agent.throwException(
                .type_error,
                "{f} is not a SharedArrayBuffer object",
                .{this_value},
            );
        }

        // 4. If IsFixedLengthArrayBuffer(obj) is true, then
        const length = if (isFixedLengthArrayBuffer(array_buffer)) blk: {
            // a. Let length be obj.[[ArrayBufferByteLength]].
            break :blk array_buffer.fields.byte_length;
        } else blk: {
            // 5. Else,
            // a. Let length be obj.[[ArrayBufferMaxByteLength]].
            break :blk array_buffer.fields.max_byte_length.unwrap().?;
        };

        // 6. Return 𝔽(length).
        return Value.from(@backingInt(length));
    }

    /// 25.2.5.6 SharedArrayBuffer.prototype.slice ( start, end )
    /// https://tc39.es/ecma262/#sec-sharedarraybuffer.prototype.slice
    fn slice(agent: *Agent, this_value: Value, arguments: Arguments) Agent.Error!Value {
        const realm = agent.currentRealm();
        const start = arguments.get(0);
        const end = arguments.get(1);

        // 1. Let obj be the this value.
        // 2. Perform ? RequireInternalSlot(obj, [[ArrayBufferData]]).
        const array_buffer = try this_value.requireInternalSlot(agent, ArrayBuffer);

        // 3. If IsSharedArrayBuffer(obj) is false, throw a TypeError exception.
        if (!isSharedArrayBuffer(array_buffer)) {
            return agent.throwException(
                .type_error,
                "{f} is not a SharedArrayBuffer object",
                .{this_value},
            );
        }

        // 4. Let length be ArrayBufferByteLength(obj, seq-cst).
        const length = arrayBufferByteLength(array_buffer, .seq_cst);

        // 5. Let first be ? ToClampedIndex(start, length).
        const first = try start.toClampedIndex(agent, @backingInt(length));

        // 6. If end is undefined, let final be length; else let final be ? ToClampedIndex(end,
        //    length).
        const final = if (end.isUndefined())
            @backingInt(length)
        else
            try end.toClampedIndex(agent, @backingInt(length));

        // 7. Let newLength be max(final - first, 0).
        const new_length = final -| first;

        // 8. Let ctor be ? SpeciesConstructor(obj, %SharedArrayBuffer%).
        const ctor = try array_buffer.object.speciesConstructor(
            agent,
            try realm.intrinsic(.shared_array_buffer),
        );

        // 9. Let new be ? Construct(ctor, « 𝔽(newLength) »).
        const new_object = try ctor.construct(agent, &.{Value.from(new_length)}, null);

        // 10. Perform ? RequireInternalSlot(new, [[ArrayBufferData]]).
        const new = try Value.from(new_object).requireInternalSlot(agent, ArrayBuffer);

        // 11. If IsSharedArrayBuffer(new) is false, throw a TypeError exception.
        if (!isSharedArrayBuffer(new)) {
            return agent.throwException(
                .type_error,
                "{f} is not a SharedArrayBuffer object",
                .{Value.from(new_object)},
            );
        }

        // 12. If new.[[ArrayBufferData]] is obj.[[ArrayBufferData]], throw a TypeError exception.
        if (new.fields.data_block.?.bytes.ptr == array_buffer.fields.data_block.?.bytes.ptr) {
            return agent.throwException(
                .type_error,
                "Species constructor must return a new buffer",
                .{},
            );
        }

        // 13. If ArrayBufferByteLength(new, seq-cst) < newLength, throw a TypeError exception.
        if (@backingInt(arrayBufferByteLength(new, .seq_cst)) < new_length) {
            return agent.throwException(.type_error, "SharedArrayBuffer is too small", .{});
        }

        // 14. Let fromBlock be obj.[[ArrayBufferData]].
        const from_block = array_buffer.fields.data_block.?;

        // 15. Let toBlock be new.[[ArrayBufferData]].
        const to_block = new.fields.data_block.?;

        // 16. Perform CopyDataBlockBytes(toBlock, 0, fromBlock, first, newLength).
        copyDataBlockBytes(to_block, 0, from_block, first, new_length);

        // 17. Return new.
        return Value.from(&new.object);
    }
};
