const std = @import("std");

const interpreter = @import("../../interpreter.zig");

const Ir = interpreter.Ir;

pub const LiveRange = struct {
    start: u32,
    end: u32,
};

pub fn computeLiveRanges(
    gpa: std.mem.Allocator,
    ir: *const Ir,
) std.mem.Allocator.Error![]LiveRange {
    var live_ranges = try gpa.alloc(LiveRange, ir.instructions.len);

    for (live_ranges, 0..) |*live_range, i| {
        live_range.* = .{ .start = @intCast(i), .end = @intCast(i) };
    }

    // Pass 1: Compute live ranges from direct uses
    for (0..ir.instructions.len) |inst_index| {
        const inst = ir.instructions.get(inst_index);

        var uses: std.ArrayList(Ir.Inst.Ref) = .empty;
        defer uses.deinit(gpa);
        try inst.collectRefs(ir, gpa, &uses);

        for (uses.items) |use| {
            if (use.toIndex()) |index| {
                const live_range = &live_ranges[@backingInt(index)];
                live_range.end = @max(live_range.end, @as(u32, @intCast(inst_index)));
            }
        }
    }

    // Pass 2: Extend live ranges across back-edges
    for (0..ir.instructions.len) |inst_index| {
        const inst = ir.instructions.get(inst_index);
        const index = switch (inst.tag) {
            .br => blk: {
                if (inst.data.br.target.toIndex()) |target_index| {
                    if (@backingInt(target_index) < inst_index) {
                        break :blk target_index;
                    }
                }
                continue;
            },
            .br_cond => {
                // br_cond currently only creates forward jumps
                const extra = ir.extraData(Ir.Inst.BrCond, inst.data.br_cond);
                if (extra.data.then_target.toIndex()) |target_index| {
                    std.debug.assert(@backingInt(target_index) >= inst_index);
                }
                if (extra.data.else_target.toIndex()) |target_index| {
                    std.debug.assert(@backingInt(target_index) >= inst_index);
                }
                continue;
            },
            else => continue,
        };
        for (live_ranges) |*live_range| {
            if (live_range.start <= @backingInt(index) and live_range.end >= @backingInt(index)) {
                live_range.end = @max(live_range.end, @as(u32, @intCast(inst_index)));
            }
        }
    }

    return live_ranges;
}
