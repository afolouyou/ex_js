//! Insertion-time IR instruction peephole optimizations and elisions.

const Ir = @import("../Ir.zig");

pub fn foldInst(b: *Ir.Builder, inst: Ir.Inst) ?Ir.Inst.Ref {
    if (b.instructions.len == 0) {
        @branchHint(.unlikely);
        return null;
    }

    switch (inst.tag) {
        .to_boolean => return foldRedundantCast(b, .boolean, inst),
        .to_object => return foldRedundantCast(b, .object, inst),
        .to_string => return foldRedundantCast(b, .string, inst),
        .to_number => return foldRedundantCast(b, .number, inst),
        .to_numeric => {
            const target = deref(b, inst.data.ref) orelse return null;
            const hint = target.tag.hint() orelse return null;
            return switch (hint) {
                .number, .big_int => inst.data.ref,
                else => null,
            };
        },
        // `!!x` is ToBoolean()
        .logical_not => {
            const index, const last = lastOperand(b, inst.data.ref) orelse return null;
            if (last.tag != .logical_not) return null;
            b.instructions.set(@backingInt(index), .{
                .tag = .to_boolean,
                .data = last.data,
            });
            return index.toRef();
        },
        // `add x 1` -> `increment x` and `sub x 1` -> `decrement x` when `x`
        // is known to be a number
        .add, .sub => {
            const lhs = deref(b, inst.data.binary.lhs) orelse return null;
            const hint = lhs.tag.hint() orelse return null;
            if (hint != .number) return null;
            const index, const rhs = lastOperand(b, inst.data.binary.rhs) orelse return null;
            if (rhs.tag != .number or rhs.data.number != 1) return null;
            b.instructions.set(@backingInt(index), .{
                .tag = if (inst.tag == .add) .increment else .decrement,
                .data = .{ .ref = inst.data.binary.lhs },
            });
            return index.toRef();
        },
        else => {},
    }
    return null;
}

fn deref(b: *const Ir.Builder, ref: Ir.Inst.Ref) ?Ir.Inst {
    const index = ref.toIndex() orelse return null;
    return b.instructions.get(@backingInt(index));
}

/// The most recently emitted instruction, if `ref` refers to it. Asserts at
/// least one instruction has been emitted so far.
fn lastOperand(b: *const Ir.Builder, ref: Ir.Inst.Ref) ?struct { Ir.Inst.Index, Ir.Inst } {
    const index: Ir.Inst.Index = @fromBackingInt(@intCast(b.instructions.len - 1));
    if (ref != index.toRef()) return null;
    return .{ index, b.instructions.get(@backingInt(index)) };
}

fn foldRedundantCast(b: *const Ir.Builder, comptime ty: Ir.Inst.TypeHint, inst: Ir.Inst) ?Ir.Inst.Ref {
    const target = deref(b, inst.data.ref) orelse return null;
    return if (target.tag.hint() == ty) inst.data.ref else null;
}
