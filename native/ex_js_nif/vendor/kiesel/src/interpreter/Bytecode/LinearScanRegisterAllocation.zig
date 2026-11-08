//! Linear Scan Register Allocation
//!
//! Based on: https://web.cs.ucla.edu/~palsberg/course/cs132/linearscan.pdf

const std = @import("std");

const interpreter = @import("../../interpreter.zig");

const Bytecode = interpreter.Bytecode;
const Ir = interpreter.Ir;

const LinearScanRegisterAllocation = @This();

allocations: []Bytecode.Reg,
num_allocations: u16,
free_temp_regs: std.bit_set.Dynamic,

const ActiveRange = struct {
    index: u32,
    end: u32,
};

pub fn init(
    gpa: std.mem.Allocator,
    live_ranges: []const Ir.LiveRange,
) std.mem.Allocator.Error!LinearScanRegisterAllocation {
    var allocations = try gpa.alloc(Bytecode.Reg, live_ranges.len);
    errdefer gpa.free(allocations);
    @memset(allocations, .none);

    var active: std.ArrayList(ActiveRange) = .empty;
    defer active.deinit(gpa);

    var free_regs: std.bit_set.Dynamic = .{};
    defer free_regs.deinit(gpa);

    for (live_ranges, 0..) |live_range, i| {
        // Expire old ranges
        var j: usize = 0;
        while (j < active.items.len) {
            if (active.items[j].end < live_range.start) {
                const reg = allocations[active.items[j].index];
                std.debug.assert(reg != .none);
                free_regs.set(@backingInt(reg));
                _ = active.swapRemove(j);
            } else {
                j += 1;
            }
        }

        const reg = free_regs.findFirstSet() orelse blk: {
            const new_reg = free_regs.bit_length;
            try free_regs.resize(gpa, new_reg + 1, true);
            break :blk new_reg;
        };

        // Use register without marking active for dead values
        if (live_range.end == live_range.start) {
            allocations[i] = @fromBackingInt(@intCast(reg));
            continue;
        }

        // Allocate register and mark used
        allocations[i] = @fromBackingInt(@intCast(reg));
        free_regs.unset(reg);
        try active.append(gpa, .{ .index = @intCast(i), .end = live_range.end });
    }

    return .{
        .allocations = allocations,
        .num_allocations = @intCast(free_regs.bit_length),
        .free_temp_regs = .{},
    };
}

pub fn deinit(lsra: *LinearScanRegisterAllocation, gpa: std.mem.Allocator) void {
    gpa.free(lsra.allocations);
    lsra.free_temp_regs.deinit(gpa);
}

pub fn allocateTemp(lsra: *LinearScanRegisterAllocation, gpa: std.mem.Allocator) std.mem.Allocator.Error!Bytecode.Reg {
    const reg = lsra.free_temp_regs.findFirstSet() orelse blk: {
        const new_reg = lsra.free_temp_regs.bit_length;
        try lsra.free_temp_regs.resize(gpa, new_reg + 1, true);
        break :blk new_reg;
    };
    lsra.free_temp_regs.unset(reg);
    return @fromBackingInt(lsra.num_allocations + @as(u16, @intCast(reg)));
}

pub fn freeTemp(lsra: *LinearScanRegisterAllocation, reg: Bytecode.Reg) void {
    lsra.free_temp_regs.set(@backingInt(reg) - lsra.num_allocations);
}

pub fn count(lsra: *LinearScanRegisterAllocation) u16 {
    return lsra.num_allocations + @as(u16, @intCast(lsra.free_temp_regs.bit_length));
}
