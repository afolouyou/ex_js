const std = @import("std");

const interpreter = @import("../../interpreter.zig");

const Ir = interpreter.Ir;

pub fn computeLiveness(
    gpa: std.mem.Allocator,
    ir: *const Ir,
) std.mem.Allocator.Error!std.bit_set.Dynamic {
    var reachable: std.bit_set.Dynamic = try .initEmpty(gpa, ir.instructions.len);
    defer reachable.deinit(gpa);
    var live: std.bit_set.Dynamic = try .initEmpty(gpa, ir.instructions.len);
    errdefer live.deinit(gpa);

    // Pass 1: Reachability analysis (forward pass from start)
    try markReachable(gpa, ir, &reachable, .start);

    // Pass 2: Liveness analysis (backward pass from side-effect instructions)
    var it = reachable.iterator(.{ .kind = .set });
    while (it.next()) |i| {
        const inst = ir.instructions.get(i);
        switch (inst.tag) {
            .undefined,
            .null,
            .true,
            .false,
            .number,
            .string,
            .big_int,
            => {},
            else => try markLive(gpa, ir, &live, @fromBackingInt(@intCast(i))),
        }
    }

    return live;
}

fn markReachable(
    gpa: std.mem.Allocator,
    ir: *const Ir,
    reachable: *std.bit_set.Dynamic,
    start: Ir.Inst.Index,
) std.mem.Allocator.Error!void {
    const ExceptionHandler = struct {
        start: Ir.Inst.Index,
        end: Ir.Inst.Index,
        target: Ir.Inst.Index,
    };

    var exception_handlers: std.ArrayList(ExceptionHandler) = .empty;
    defer exception_handlers.deinit(gpa);

    for (ir.instructions.items(.tag), ir.instructions.items(.data)) |tag, data| {
        if (tag != .exception_handler) continue;
        const extra = ir.extraData(Ir.Inst.ExceptionHandler, data.exception_handler);
        try exception_handlers.append(gpa, .{
            .start = extra.data.start.toIndex().?,
            .end = extra.data.end.toIndex().?,
            .target = extra.data.target.toIndex().?,
        });
    }

    var worklist: std.ArrayList(Ir.Inst.Index) = .empty;
    defer worklist.deinit(gpa);
    try worklist.append(gpa, start);

    while (worklist.pop()) |index| {
        const i = @backingInt(index);
        if (reachable.isSet(i)) continue;
        reachable.set(i);

        const inst = ir.instructions.get(i);

        for (exception_handlers.items) |handler| {
            if (i >= @backingInt(handler.start) and
                i < @backingInt(handler.end) and
                !reachable.isSet(@backingInt(handler.target)))
            {
                try worklist.append(gpa, handler.target);
            }
        }

        switch (inst.tag) {
            .br => {
                const target_index = inst.data.br.target.toIndex().?;
                if (!reachable.isSet(@backingInt(target_index))) {
                    try worklist.append(gpa, target_index);
                }
                continue; // Unconditional branch never reaches next instruction
            },
            .br_cond => {
                const extra = ir.extraData(Ir.Inst.BrCond, inst.data.br_cond);
                const then_index = extra.data.then_target.toIndex().?;
                const else_index = extra.data.else_target.toIndex().?;
                if (!reachable.isSet(@backingInt(then_index))) {
                    try worklist.append(gpa, then_index);
                }
                if (!reachable.isSet(@backingInt(else_index))) {
                    try worklist.append(gpa, else_index);
                }
                continue; // Conditional branch doesn't fall through
            },
            .throw,
            .throw_reference_error,
            .@"return",
            => continue,
            else => {},
        }
        if (i + 1 < ir.instructions.len and !reachable.isSet(i + 1)) {
            try worklist.append(gpa, @fromBackingInt(i + 1));
        }
    }
}

fn markLive(
    gpa: std.mem.Allocator,
    ir: *const Ir,
    live: *std.bit_set.Dynamic,
    start: Ir.Inst.Index,
) std.mem.Allocator.Error!void {
    var worklist: std.ArrayList(Ir.Inst.Index) = .empty;
    defer worklist.deinit(gpa);
    try worklist.append(gpa, start);

    while (worklist.pop()) |index| {
        const i = @backingInt(index);
        if (live.isSet(i)) continue;
        live.set(i);

        const inst = ir.instructions.get(i);

        var uses: std.ArrayList(Ir.Inst.Ref) = .empty;
        defer uses.deinit(gpa);
        try inst.collectRefs(ir, gpa, &uses);

        for (uses.items) |use| {
            if (use.toIndex()) |use_index| {
                try worklist.append(gpa, use_index);
            }
        }
    }
}
