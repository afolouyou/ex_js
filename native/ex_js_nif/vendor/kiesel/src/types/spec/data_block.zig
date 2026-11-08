//! 6.2.9 Data Blocks
//! https://tc39.es/ecma262/#sec-data-blocks

const std = @import("std");

const execution = @import("../../execution.zig");
const types = @import("../../types.zig");

const Agent = execution.Agent;
const ByteLength = types.ByteLength;

pub const DataBlock = struct {
    bytes: []u8,
    shared: bool,

    /// Arbitrary size limit (32 GiB)
    pub const max_byte_length: ByteLength = @fromBackingInt(1024 * 1024 * 1024 * 32);

    pub fn resize(
        self: *DataBlock,
        allocator: std.mem.Allocator,
        size: ByteLength,
    ) std.mem.Allocator.Error!void {
        const old_size = self.bytes.len;
        const new_size = std.math.cast(usize, @backingInt(size)) orelse return error.OutOfMemory;
        self.bytes = try allocator.realloc(self.bytes, new_size);
        if (new_size > old_size) {
            @memset(self.bytes[old_size..], 0);
        }
    }
};

/// 6.2.9.1 CreateByteDataBlock ( size )
/// https://tc39.es/ecma262/#sec-createbytedatablock
pub fn createByteDataBlock(agent: *Agent, size: ByteLength) Agent.Error!DataBlock {
    // 1. If size > 2**53 - 1, throw a RangeError exception.

    // NOTE: Checking for a reasonable size below the theoretical limit is non-standard but also
    //       done in other engines (and tested by test262)
    if (@backingInt(size) > @backingInt(DataBlock.max_byte_length)) {
        return agent.throwException(.range_error, "Cannot allocate buffer of size {d}", .{size});
    }

    const size_casted = std.math.cast(usize, @backingInt(size)) orelse {
        return agent.throwException(.range_error, "Cannot allocate buffer of size {d}", .{size});
    };

    // 2. Let dataBlock be a new Data Block value consisting of size bytes. If it is impossible to
    //    create such a Data Block, throw a RangeError exception.
    const bytes = agent.gc_allocator.alloc(u8, size_casted) catch {
        return agent.throwException(.range_error, "Cannot allocate buffer of size {d}", .{size});
    };
    const data_block: DataBlock = .{ .bytes = bytes, .shared = false };

    // 3. Set all of the bytes of dataBlock to 0.
    @memset(data_block.bytes, 0);

    // 4. Return dataBlock.
    return data_block;
}

/// 6.2.9.2 CreateSharedByteDataBlock ( size )
/// https://tc39.es/ecma262/#sec-createsharedbytedatablock
pub fn createSharedByteDataBlock(agent: *Agent, size: ByteLength) Agent.Error!DataBlock {
    // NOTE: Checking for a reasonable size below the theoretical limit is non-standard but also
    //       done in other engines (and tested by test262)
    if (@backingInt(size) > @backingInt(DataBlock.max_byte_length)) {
        return agent.throwException(.range_error, "Cannot allocate buffer of size {d}", .{size});
    }

    const size_casted = std.math.cast(usize, @backingInt(size)) orelse {
        return agent.throwException(.range_error, "Cannot allocate buffer of size {d}", .{size});
    };

    // 1. Let dataBlock be a new Shared Data Block value consisting of size bytes. If it is
    //    impossible to create such a Shared Data Block, throw a RangeError exception.
    const bytes = agent.gc_allocator.alloc(u8, size_casted) catch {
        return agent.throwException(.range_error, "Cannot allocate buffer of size {d}", .{size});
    };
    const data_block: DataBlock = .{ .bytes = bytes, .shared = true };

    // 2. Let agentRecord be the Agent Record of the surrounding agent.
    // 3. Let execution be agentRecord.[[CandidateExecution]].
    // 4. Let eventsRecord be the Agent Events Record of execution.[[EventsRecords]] whose
    //    [[AgentSignifier]] is AgentSignifier().
    // 5. Let zero be « 0 ».
    // 6. For each index index of dataBlock, do
    //     a. Append WriteSharedMemory { [[Order]]: init, [[NoTear]]: true, [[Block]]: dataBlock,
    //        [[ByteIndex]]: index, [[ElementSize]]: 1, [[Payload]]: zero } to
    //        eventsRecord.[[EventList]].
    @memset(data_block.bytes, 0);

    // 7. Return dataBlock.
    return data_block;
}

/// 6.2.9.3 CopyDataBlockBytes ( toBlock, toIndex, fromBlock, fromIndex, count )
/// https://tc39.es/ecma262/#sec-copydatablockbytes
pub fn copyDataBlockBytes(
    to_block: DataBlock,
    to_index: u53,
    from_block: DataBlock,
    from_index: u53,
    count: u53,
) void {
    // 1. Assert: fromBlock and toBlock are distinct values.

    // 2. Let fromSize be the number of bytes in fromBlock.
    const from_size = from_block.bytes.len;

    // 3. Assert: fromIndex + count ≤ fromSize.
    std.debug.assert(from_index + count <= from_size);

    // 4. Let toSize be the number of bytes in toBlock.
    const to_size = to_block.bytes.len;

    // 5. Assert: toIndex + count ≤ toSize.
    std.debug.assert(to_index + count <= to_size);

    // 6. Repeat, while count > 0,
    //     TODO: a. If fromBlock is a Shared Data Block, then
    //              [...]
    //     b. Else,
    //         i. Assert: toBlock is not a Shared Data Block.
    //         ii. Set toBlock[toIndex] to fromBlock[fromIndex].
    //     c. Set toIndex to toIndex + 1.
    //     d. Set fromIndex to fromIndex + 1.
    //     e. Set count to count - 1.
    @memcpy(
        to_block.bytes[@intCast(to_index)..@intCast(to_index + count)],
        from_block.bytes[@intCast(from_index)..@intCast(from_index + count)],
    );

    // 7. Return unused.
}
