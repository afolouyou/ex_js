const std = @import("std");

const interpreter = @import("../../interpreter.zig");

const Bytecode = interpreter.Bytecode;
const Ir = interpreter.Ir;

const LinearScanRegisterAllocation = @import("LinearScanRegisterAllocation.zig");

const Builder = @This();

gpa: std.mem.Allocator,
ir: *const Ir,
lsra: LinearScanRegisterAllocation,
blocks: std.ArrayList(Block),
current_block: Block.Index,
label_blocks: std.AutoHashMapUnmanaged(Ir.Inst.Ref, Block.Index),
exception_handlers: std.ArrayList(ExceptionHandler),
array_states: std.ArrayList(ArrayState),
locals: std.AutoHashMapUnmanaged(Ir.StringIndex, Bytecode.Local),
get_property_ic_count: u16,
get_property_computed_ic_count: u16,
set_property_ic_count: u16,
set_property_computed_ic_count: u16,

const ExceptionHandler = struct {
    start: Block.Index,
    end: Block.Index,
    target: Block.Index,
    exception_reg: Bytecode.Reg,
    scope_depth: u16,
};

const ArrayState = struct {
    index: u32,
    len: u32,
    has_spread: bool,
};

pub const Error = error{OutOfMemory};

pub fn init(gpa: std.mem.Allocator, ir: *const Ir) std.mem.Allocator.Error!Builder {
    const lsra: LinearScanRegisterAllocation = try .init(gpa, ir.live_ranges);
    return .{
        .gpa = gpa,
        .ir = ir,
        .lsra = lsra,
        .blocks = .empty,
        .current_block = undefined, // Initialized in `build()`
        .label_blocks = .empty,
        .exception_handlers = .empty,
        .array_states = .empty,
        .locals = .empty,
        .get_property_ic_count = 0,
        .get_property_computed_ic_count = 0,
        .set_property_ic_count = 0,
        .set_property_computed_ic_count = 0,
    };
}

pub fn deinit(b: *Builder) void {
    b.lsra.deinit(b.gpa);
    b.blocks.deinit(b.gpa);
    b.label_blocks.deinit(b.gpa);
    b.exception_handlers.deinit(b.gpa);
    b.array_states.deinit(b.gpa);
    b.locals.deinit(b.gpa);
}

fn computeRPO(
    b: *const Builder,
    block: Block.Index,
    visited: *std.AutoHashMapUnmanaged(Block.Index, void),
    out: *std.ArrayList(Block.Index),
) std.mem.Allocator.Error!void {
    const start = out.items.len;
    try b.computeRPOInner(block, visited, out);
    std.mem.reverse(Block.Index, out.items[start..]);
}

fn computeRPOInner(
    b: *const Builder,
    block: Block.Index,
    visited: *std.AutoHashMapUnmanaged(Block.Index, void),
    out: *std.ArrayList(Block.Index),
) std.mem.Allocator.Error!void {
    const gop = try visited.getOrPut(b.gpa, block);
    if (gop.found_existing) return;

    switch (b.blocks.items[@backingInt(block)].terminator) {
        .none, .noreturn => {},
        .jump => |target| try b.computeRPOInner(target, visited, out),
        .branch => |br| {
            try b.computeRPOInner(br.else_block, visited, out);
            try b.computeRPOInner(br.then_block, visited, out);
        },
    }

    try out.append(b.gpa, block);
}

const CanOptimizeLocals = union(enum) {
    none,
    body: u32,
    all,
};

fn canOptimizeLocals(b: *const Builder) CanOptimizeLocals {
    const tags = b.ir.instructions.items(.tag);

    // We don't have escape analysis yet so we deopt whenever an instruction
    // *could* interfere. Ugly but works :^)
    for (tags, 0..) |tag, i| {
        const index: Ir.Inst.Index = @fromBackingInt(@intCast(i));
        if (!index.liveness(b.ir)) continue;
        switch (tag) {
            .create_function,
            .create_class,
            .call_direct_eval,
            .call_direct_eval_strict,
            .create_mapped_arguments_object,
            .push_with_scope,
            => return .none,
            else => {},
        }
    }

    // Parameters with default expressions emit a `br_cond` before
    // `push_var_scope` for the undefined check. Their bindings can't be
    // optimized as locals since the default value may reference the parameter
    // itself within the TDZ.
    if (std.mem.findScalar(Ir.Inst.Tag, tags, .push_var_scope)) |push_var_scope_pos| {
        if (std.mem.findScalar(Ir.Inst.Tag, tags[0..push_var_scope_pos], .br_cond)) |_| {
            return .{ .body = @intCast(push_var_scope_pos + 1) };
        }
    }

    return .all;
}

/// Collect bindings to optimize as fast locals:
///
/// - var declarations (`create_var_binding`)
/// - function parameters (`create_mutable_binding`)
/// - unmapped arguments object (`create_immutable_binding`)
///
/// We stop after the first `get_argument` to not collect let/const bindings.
/// Bindings shadowed by let/const are deopted so env lookups work.
fn collectLocals(b: *Builder) Error!void {
    const start = switch (b.canOptimizeLocals()) {
        .none => return,
        .body => |start| start,
        .all => 0,
    };
    var past_prologue = std.mem.findScalar(Ir.Inst.Tag, b.ir.instructions.items(.tag), .get_argument) == null;
    var bindings: std.array_hash_map.Auto(Ir.StringIndex, void) = .empty;
    defer bindings.deinit(b.gpa);
    for (b.ir.instructions.items(.tag)[start..], b.ir.instructions.items(.data)[start..], 0..) |tag, data, i| {
        const index: Ir.Inst.Index = @fromBackingInt(@intCast(i));
        if (!index.liveness(b.ir)) continue;
        switch (tag) {
            .get_argument => past_prologue = true,
            .create_var_binding => {
                try bindings.put(b.gpa, data.string, {});
            },
            .create_mutable_binding, .create_immutable_binding => {
                if (!past_prologue) {
                    try bindings.put(b.gpa, data.string, {});
                } else if (bindings.contains(data.string)) {
                    _ = bindings.orderedRemove(data.string);
                }
            },
            else => {},
        }
    }

    try b.locals.ensureUnusedCapacity(b.gpa, @intCast(bindings.count()));
    for (bindings.keys(), 0..) |name, i| {
        b.locals.putAssumeCapacity(name, @fromBackingInt(@intCast(i)));
    }
}

pub fn build(b: *Builder) Error!Bytecode {
    std.debug.assert(b.blocks.items.len == 0);
    try b.blocks.append(b.gpa, .empty);
    b.current_block = .root;

    // Pre-create blocks for all labels
    for (b.ir.instructions.items(.tag), 0..) |tag, i| {
        const index: Ir.Inst.Index = @fromBackingInt(@intCast(i));
        if (!index.liveness(b.ir)) continue;
        if (tag != .label) continue;
        try b.blocks.append(b.gpa, .empty);
        const block_index: Block.Index = @fromBackingInt(@intCast(b.blocks.items.len - 1));
        try b.label_blocks.put(b.gpa, index.toRef(), block_index);
    }

    try b.collectLocals();

    // Lower alive instructions
    for (b.ir.instructions.items(.tag), b.ir.instructions.items(.data), 0..) |tag, data, i| {
        const index: Ir.Inst.Index = @fromBackingInt(@intCast(i));
        if (!index.liveness(b.ir)) continue;
        const dest = index.toRef();
        switch (tag) {
            .undefined => try b.lowerUndefined(dest),
            .null => try b.lowerNull(dest),
            .true => try b.lowerTrue(dest),
            .false => try b.lowerFalse(dest),
            .number => try b.lowerNumber(data.number, dest),
            .string => try b.lowerString(data.string, dest),
            .big_int => try b.lowerBigInt(data.big_int, dest),
            .create_array => try b.lowerCreateArray(data.array, dest),
            .array_push => try b.lowerArrayPush(data.binary),
            .array_spread => try b.lowerArraySpread(data.binary),
            .create_object => try b.lowerCreateObject(data.object, dest),
            .object_set => try b.lowerObjectSet(data.set_property),
            .object_set_computed => try b.lowerObjectSetComputed(data.set_property_computed),
            .object_set_prototype => try b.lowerObjectSetPrototype(data.binary),
            .object_spread => try b.lowerObjectSpread(data.binary),
            .create_reg_exp => try b.lowerCreateRegExp(data.reg_exp, dest),
            .this => try b.lowerThis(dest),
            .label => try b.lowerLabel(dest),
            .br => try b.lowerBr(data.br),
            .br_cond => try b.lowerBrCond(data.br_cond),
            .exception_handler => try b.lowerExceptionHandler(data.exception_handler, dest),
            .to_boolean => try b.lowerToBoolean(data.ref, dest),
            .to_number => try b.lowerToNumber(data.ref, dest),
            .to_numeric => try b.lowerToNumeric(data.ref, dest),
            .to_string => try b.lowerToString(data.ref, dest),
            .to_object => try b.lowerToObject(data.ref, dest),
            .increment => try b.lowerIncrement(data.ref, dest),
            .decrement => try b.lowerDecrement(data.ref, dest),
            .negate => try b.lowerNegate(data.ref, dest),
            .bitwise_not => try b.lowerBitwiseNot(data.ref, dest),
            .logical_not => try b.lowerLogicalNot(data.ref, dest),
            .is_nullish => try b.lowerIsNullish(data.ref, dest),
            .typeof => try b.lowerTypeof(data.ref, dest),
            .typeof_binding => try b.lowerTypeofBinding(data.string, dest),
            .spread => try b.lowerSpread(data.ref, dest),
            .add => try b.lowerAdd(data.binary, dest),
            .sub => try b.lowerSub(data.binary, dest),
            .mul => try b.lowerMul(data.binary, dest),
            .div => try b.lowerDiv(data.binary, dest),
            .rem => try b.lowerRem(data.binary, dest),
            .exp => try b.lowerExp(data.binary, dest),
            .shift_left => try b.lowerShiftLeft(data.binary, dest),
            .shift_right => try b.lowerShiftRight(data.binary, dest),
            .shift_right_unsigned => try b.lowerShiftRightUnsigned(data.binary, dest),
            .bitwise_and => try b.lowerBitwiseAnd(data.binary, dest),
            .bitwise_or => try b.lowerBitwiseOr(data.binary, dest),
            .bitwise_xor => try b.lowerBitwiseXor(data.binary, dest),
            .lt => try b.lowerLt(data.binary, dest),
            .gt => try b.lowerGt(data.binary, dest),
            .lt_eq => try b.lowerLtEq(data.binary, dest),
            .gt_eq => try b.lowerGtEq(data.binary, dest),
            .instanceof => try b.lowerInstanceof(data.binary, dest),
            .in => try b.lowerIn(data.binary, dest),
            .eq => try b.lowerEq(data.binary, dest),
            .not_eq => try b.lowerNotEq(data.binary, dest),
            .eq_strict => try b.lowerEqStrict(data.binary, dest),
            .not_eq_strict => try b.lowerNotEqStrict(data.binary, dest),
            .push_scope => try b.lowerPushScope(),
            .push_catch_scope => try b.lowerPushCatchScope(),
            .push_var_scope => try b.lowerPushVarScope(),
            .push_with_scope => try b.lowerPushWithScope(data.ref),
            .pop_scope => try b.lowerPopScope(),
            .create_var_binding => try b.lowerCreateVarBinding(data.string),
            .create_mutable_binding => try b.lowerCreateMutableBinding(data.string),
            .create_immutable_binding => try b.lowerCreateImmutableBinding(data.string),
            .initialize_binding => try b.lowerInitializeBinding(data.set_binding.name, data.set_binding.value, dest),
            .get_binding => try b.lowerGetBinding(data.string, dest),
            .get_property => try b.lowerGetProperty(data.get_property, dest),
            .get_property_computed => try b.lowerGetPropertyComputed(data.get_property_computed, dest),
            .get_property_indexed => try b.lowerGetPropertyIndexed(data.get_property_indexed, dest),
            .set_binding => try b.lowerSetBinding(data.set_binding.name, data.set_binding.value, false, dest),
            .set_binding_strict => try b.lowerSetBinding(data.set_binding.name, data.set_binding.value, true, dest),
            .set_property => try b.lowerSetProperty(data.set_property, false, dest),
            .set_property_strict => try b.lowerSetProperty(data.set_property, true, dest),
            .set_property_computed => try b.lowerSetPropertyComputed(data.set_property_computed, false, dest),
            .set_property_computed_strict => try b.lowerSetPropertyComputed(data.set_property_computed, true, dest),
            .set_property_indexed => try b.lowerSetPropertyIndexed(data.set_property_indexed, false, dest),
            .set_property_indexed_strict => try b.lowerSetPropertyIndexed(data.set_property_indexed, true, dest),
            .delete_binding => try b.lowerDeleteBinding(data.string, dest),
            .delete_property => try b.lowerDeleteProperty(data.delete_property, false, dest),
            .delete_property_strict => try b.lowerDeleteProperty(data.delete_property, true, dest),
            .delete_property_computed => try b.lowerDeletePropertyComputed(data.delete_property_computed, false, dest),
            .delete_property_computed_strict => try b.lowerDeletePropertyComputed(data.delete_property_computed, true, dest),
            .delete_property_indexed => try b.lowerDeletePropertyIndexed(data.delete_property_indexed, false, dest),
            .delete_property_indexed_strict => try b.lowerDeletePropertyIndexed(data.delete_property_indexed, true, dest),
            .copy_data_properties => try b.lowerCopyDataProperties(data.copy_data_properties, dest),
            .call => try b.lowerCall(data.call, dest),
            .call_direct_eval => try b.lowerCallDirectEval(data.call, dest, false),
            .call_direct_eval_strict => try b.lowerCallDirectEval(data.call, dest, true),
            .construct => try b.lowerConstruct(data.construct, dest),
            .get_template_object => try b.lowerGetTemplateObject(data.get_template_object, dest),
            .get_iterator => try b.lowerGetIterator(data.ref, dest),
            .get_async_iterator => try b.lowerGetAsyncIterator(data.ref, dest),
            .get_for_in_iterator => try b.lowerGetForInIterator(data.ref, dest),
            .iterator_step => try b.lowerIteratorStep(data.ref, dest),
            .iterator_step_value => try b.lowerIteratorStepValue(data.ref, dest),
            .iterator_step_value_async => try b.lowerIteratorStepValueAsync(data.ref, dest),
            .iterator_close => try b.lowerIteratorClose(data.ref),
            .iterator_is_done => try b.lowerIteratorIsDone(data.ref, dest),
            .iterator_collect => try b.lowerIteratorCollect(data.ref, dest),
            .throw => try b.lowerThrow(data.ref),
            .throw_reference_error => try b.lowerThrowReferenceError(),
            .@"return" => try b.lowerReturn(data.ref),
            .await => try b.lowerAwait(data.ref, dest),
            .yield => try b.lowerYield(data.ref, dest),
            .yield_star => try b.lowerYieldStar(data.ref, dest),
            .create_function => try b.lowerCreateFunction(data.create_function, dest),
            .create_class => try b.lowerCreateClass(data.create_class, dest),
            .create_unmapped_arguments_object => try b.lowerCreateUnmappedArgumentsObject(dest),
            .create_mapped_arguments_object => try b.lowerCreateMappedArgumentsObject(dest),
            .get_argument => try b.lowerGetArgument(data.argument, dest),
            .get_rest_arguments => try b.lowerGetRestArguments(data.argument, dest),
            .get_new_target => try b.lowerGetNewTarget(dest),
            .as_getter => try b.lowerAsGetter(data.ref, dest),
            .as_setter => try b.lowerAsSetter(data.ref, dest),
            .super_call => try b.lowerSuperCall(data.super_call, dest),
            .get_super_property => try b.lowerGetSuperProperty(data.string, dest),
            .get_super_property_computed => try b.lowerGetSuperPropertyComputed(data.ref, dest),
            .set_super_property => try b.lowerSetSuperProperty(data.set_property, false, dest),
            .set_super_property_strict => try b.lowerSetSuperProperty(data.set_property, true, dest),
            .set_super_property_computed => try b.lowerSetSuperPropertyComputed(data.set_property_computed, false, dest),
            .set_super_property_computed_strict => try b.lowerSetSuperPropertyComputed(data.set_property_computed, true, dest),
            .create_private_element => try b.lowerCreatePrivateElement(data.string, dest),
            .resolve_private_element => try b.lowerResolvePrivateElement(data.string, dest),
            .push_private_scope => try b.lowerPushPrivateScope(),
            .pop_private_scope => try b.lowerPopPrivateScope(),
            .get_private_element => try b.lowerGetPrivateElement(data.get_property, dest),
            .set_private_element => try b.lowerSetPrivateElement(data.set_property, dest),
            .has_private_element => try b.lowerHasPrivateElement(data.binary, dest),
            .import_call => try b.lowerImportCall(data.binary, dest),
            .get_import_meta => try b.lowerGetImportMeta(dest),
            .add_disposable_resource_sync => try b.lowerAddDisposableResourceSync(data.ref),
            .add_disposable_resource_async => try b.lowerAddDisposableResourceAsync(data.ref),
            .dispose_resources => try b.lowerDisposeResources(),
        }
    }

    std.debug.assert(b.terminated());

    // Order blocks in reverse post-order
    var ordered: std.ArrayList(Block.Index) = .empty;
    defer ordered.deinit(b.gpa);
    var visited: std.AutoHashMapUnmanaged(Block.Index, void) = .empty;
    defer visited.deinit(b.gpa);
    for (0..b.blocks.items.len) |i| {
        const block: Block.Index = @fromBackingInt(@intCast(i));
        if (!visited.contains(block)) {
            try b.computeRPO(block, &visited, &ordered);
        }
    }

    // Assign offsets
    var offset: u32 = 0;
    for (ordered.items, 0..) |block_index, i| {
        const block = &b.blocks.items[@backingInt(block_index)];
        block.offset = offset;
        offset += block.size();
        const next = if (i + 1 < ordered.items.len) ordered.items[i + 1] else null;
        offset += block.terminatorSize(next);
    }

    // Encode bytecode
    var aw: std.Io.Writer.Allocating = .init(b.gpa);
    errdefer aw.deinit();

    for (ordered.items, 0..) |block_index, i| {
        const block = &b.blocks.items[@backingInt(block_index)];
        const next = if (i + 1 < ordered.items.len) ordered.items[i + 1] else null;
        block.encode(&aw.writer, b.blocks.items, next) catch |err| switch (err) {
            error.WriteFailed => return error.OutOfMemory,
        };
    }

    const name = try b.gpa.dupe(u8, b.ir.name);
    errdefer b.gpa.free(name);

    const code = try aw.toOwnedSlice();
    errdefer b.gpa.free(code);

    var strings_list: std.ArrayList([]const u8) = try .initCapacity(b.gpa, b.ir.strings.len);
    defer strings_list.deinit(b.gpa);
    errdefer for (strings_list.items) |string| b.gpa.free(string);
    for (b.ir.strings) |string| {
        const cloned = try b.gpa.dupe(u8, string);
        strings_list.appendAssumeCapacity(cloned);
    }
    const strings = try strings_list.toOwnedSlice(b.gpa);
    errdefer {
        for (strings) |string| b.gpa.free(string);
        b.gpa.free(strings);
    }

    var big_ints_list: std.ArrayList(std.math.big.int.Const) = try .initCapacity(b.gpa, b.ir.big_ints.len);
    defer big_ints_list.deinit(b.gpa);
    errdefer for (big_ints_list.items) |big_int| b.gpa.free(big_int.limbs);
    for (b.ir.big_ints) |big_int| {
        const cloned: std.math.big.int.Const = .{
            .limbs = try b.gpa.dupe(std.math.big.Limb, big_int.limbs),
            .positive = big_int.positive,
        };
        big_ints_list.appendAssumeCapacity(cloned);
    }
    const big_ints = try big_ints_list.toOwnedSlice(b.gpa);
    errdefer {
        for (big_ints) |big_int| b.gpa.free(big_int.limbs);
        b.gpa.free(big_ints);
    }

    var functions_list: std.ArrayList(Bytecode.Function) = try .initCapacity(b.gpa, b.ir.functions.len);
    defer functions_list.deinit(b.gpa);
    for (b.ir.functions) |function| {
        functions_list.appendAssumeCapacity(.{
            .source_range = function.source_range,
            .name = switch (function.name) {
                .none => .none,
                .identifier => |s| .{ .identifier = @fromBackingInt(@backingInt(s)) },
                .default => |s| .{ .default = @fromBackingInt(@backingInt(s)) },
            },
            .parameters = function.parameters,
            .body = function.body,
            .kind = @fromBackingInt(@backingInt(function.kind)),
        });
    }
    const functions = try functions_list.toOwnedSlice(b.gpa);
    errdefer b.gpa.free(functions);

    var classes_list: std.ArrayList(Bytecode.Class) = try .initCapacity(b.gpa, b.ir.classes.len);
    defer classes_list.deinit(b.gpa);
    for (b.ir.classes) |class| {
        const element_name_regs = try b.gpa.alloc(Bytecode.Reg, class.element_names.len);
        for (class.element_names, element_name_regs) |name_ref, *reg| {
            reg.* = switch (name_ref) {
                .none => .none,
                _ => b.resolve(name_ref),
            };
        }
        classes_list.appendAssumeCapacity(.{
            .source_range = class.source_range,
            .name = switch (class.name) {
                .none => .none,
                .identifier => |s| .{ .identifier = @fromBackingInt(@backingInt(s)) },
                .default => |s| .{ .default = @fromBackingInt(@backingInt(s)) },
            },
            .class_tail = class.class_tail,
            .heritage = switch (class.heritage) {
                .none => .none,
                _ => b.resolve(class.heritage),
            },
            .element_names = element_name_regs,
        });
    }
    const classes = try classes_list.toOwnedSlice(b.gpa);
    errdefer {
        for (classes) |class| b.gpa.free(class.element_names);
        b.gpa.free(classes);
    }

    var exception_handlers_list: std.ArrayList(Bytecode.ExceptionHandler) = try .initCapacity(b.gpa, b.exception_handlers.items.len);
    defer exception_handlers_list.deinit(b.gpa);
    for (b.exception_handlers.items) |handler| {
        exception_handlers_list.appendAssumeCapacity(.{
            .start = b.blocks.items[@backingInt(handler.start)].offset,
            .end = b.blocks.items[@backingInt(handler.end)].offset,
            .target = b.blocks.items[@backingInt(handler.target)].offset,
            .exception_reg = handler.exception_reg,
            .scope_depth = handler.scope_depth,
        });
    }
    const exception_handlers = try exception_handlers_list.toOwnedSlice(b.gpa);
    errdefer b.gpa.free(exception_handlers);

    return .{
        .name = name,
        .code = code,
        .local_count = @intCast(b.locals.count()),
        .register_count = b.lsra.count(),
        .get_property_ic_count = b.get_property_ic_count,
        .get_property_computed_ic_count = b.get_property_computed_ic_count,
        .set_property_ic_count = b.set_property_ic_count,
        .set_property_computed_ic_count = b.set_property_computed_ic_count,
        .strings = strings,
        .big_ints = big_ints,
        .functions = functions,
        .classes = classes,
        .exception_handlers = exception_handlers,
    };
}

const Block = struct {
    instructions: std.ArrayList(Bytecode.Inst),
    terminator: Terminator,
    offset: u32,

    const empty: Block = .{
        .instructions = .empty,
        .terminator = .none,
        .offset = 0,
    };

    const Index = enum(u32) {
        root = 0,
        _,
    };

    const Condition = enum {
        truthy,
        falsy,
    };

    const Terminator = union(enum) {
        none,
        jump: Block.Index,
        branch: struct {
            condition: Condition,
            condition_reg: Bytecode.Reg,
            then_block: Block.Index,
            else_block: Block.Index,
        },
        noreturn,
    };

    fn size(block: *const Block) u32 {
        var total: u32 = 0;
        for (block.instructions.items) |inst| {
            total += Bytecode.Inst.encodedSize(inst.tag);
        }
        return total;
    }

    fn terminatorSize(block: *const Block, next: ?Block.Index) u32 {
        return switch (block.terminator) {
            .none => unreachable,
            .noreturn => 0,
            .jump => |target| if (target == next) 0 else Bytecode.Inst.encodedSize(.jump),
            .branch => |br| blk: {
                const jump_cond_tag: Bytecode.Inst.Tag = switch (br.condition) {
                    .truthy => .jump_if_true,
                    .falsy => .jump_if_false,
                };
                const jump_cond_size: u32 = Bytecode.Inst.encodedSize(jump_cond_tag);
                const jump_size: u32 = if (br.else_block == next) 0 else Bytecode.Inst.encodedSize(.jump);
                break :blk jump_cond_size + jump_size;
            },
        };
    }

    fn encode(
        block: *const Block,
        writer: *std.Io.Writer,
        blocks: []const Block,
        next: ?Block.Index,
    ) std.Io.Writer.Error!void {
        for (block.instructions.items) |inst| {
            try inst.encode(writer);
        }

        const jump_size = comptime Bytecode.Inst.encodedSize(.jump);
        const jump_cond_size = comptime Bytecode.Inst.encodedSize(.jump_if_true);

        switch (block.terminator) {
            .none => unreachable,
            .noreturn => {},
            .jump => |target| {
                if (target != next) {
                    const current_offset = block.offset + block.size();
                    const target_relative: i32 =
                        @as(i32, @intCast(blocks[@backingInt(target)].offset)) -
                        @as(i32, @intCast(current_offset + jump_size));
                    try (Bytecode.Inst{
                        .tag = .jump,
                        .data = .{ .i32 = target_relative },
                    }).encode(writer);
                }
            },
            .branch => |br| {
                const jump_cond_tag: Bytecode.Inst.Tag = switch (br.condition) {
                    .truthy => .jump_if_true,
                    .falsy => .jump_if_false,
                };
                const after_jump_cond = block.offset + block.size() + jump_cond_size;
                const then_relative: i32 =
                    @as(i32, @intCast(blocks[@backingInt(br.then_block)].offset)) -
                    @as(i32, @intCast(after_jump_cond));
                try (Bytecode.Inst{
                    .tag = jump_cond_tag,
                    .data = .{ .reg_i32 = .{
                        br.condition_reg,
                        then_relative,
                    } },
                }).encode(writer);
                if (br.else_block != next) {
                    const current_offset = after_jump_cond;
                    const else_relative: i32 =
                        @as(i32, @intCast(blocks[@backingInt(br.else_block)].offset)) -
                        @as(i32, @intCast(current_offset + jump_size));
                    try (Bytecode.Inst{
                        .tag = .jump,
                        .data = .{ .i32 = else_relative },
                    }).encode(writer);
                }
            },
        }
    }

    fn deinit(block: *Block, gpa: std.mem.Allocator) void {
        block.instructions.deinit(gpa);
    }
};

fn terminated(b: *const Builder) bool {
    const block = &b.blocks.items[@backingInt(b.current_block)];
    return block.terminator != .none;
}

fn jump(b: *Builder, target: Block.Index) void {
    std.debug.assert(!b.terminated());
    const block = &b.blocks.items[@backingInt(b.current_block)];
    block.terminator = .{ .jump = target };
}

fn branch(
    b: *Builder,
    condition: Block.Condition,
    condition_reg: Bytecode.Reg,
    then_block: Block.Index,
    else_block: Block.Index,
) void {
    std.debug.assert(!b.terminated());
    const block = &b.blocks.items[@backingInt(b.current_block)];
    block.terminator = .{ .branch = .{
        .condition = condition,
        .condition_reg = condition_reg,
        .then_block = then_block,
        .else_block = else_block,
    } };
}

fn @"noreturn"(b: *Builder) void {
    std.debug.assert(!b.terminated());
    const block = &b.blocks.items[@backingInt(b.current_block)];
    block.terminator = .noreturn;
}

fn emit(b: *Builder, inst: Bytecode.Inst) Error!void {
    const block = &b.blocks.items[@backingInt(b.current_block)];
    try block.instructions.append(b.gpa, inst);
}

fn emitUnaryOp(
    b: *Builder,
    tag: Bytecode.Inst.Tag,
    operand: Ir.Inst.Ref,
    dest: Ir.Inst.Ref,
) Error!void {
    const dest_reg = b.resolve(dest);
    const operand_reg = b.resolve(operand);
    try b.emit(.{
        .tag = tag,
        .data = .{ .reg_reg = .{
            dest_reg,
            operand_reg,
        } },
    });
}

fn emitBinaryOp(
    b: *Builder,
    tag: Bytecode.Inst.Tag,
    lhs: Ir.Inst.Ref,
    rhs: Ir.Inst.Ref,
    dest: Ir.Inst.Ref,
) Error!void {
    const dest_reg = b.resolve(dest);
    const lhs_reg = b.resolve(lhs);
    const rhs_reg = b.resolve(rhs);
    try b.emit(.{
        .tag = tag,
        .data = .{ .reg_reg_reg = .{
            dest_reg,
            lhs_reg,
            rhs_reg,
        } },
    });
}

fn emitMoveIfNeeded(b: *Builder, src: Ir.Inst.Ref, dest: Ir.Inst.Ref) Error!void {
    var index = dest.toIndex().?;
    const inst = index.inst(b.ir);
    if (inst.tag == .br) {
        const br = inst.data.br;
        index = br.target.toIndex().?;
    }
    const live_range = index.liveRange(b.ir);
    if (live_range.end <= @backingInt(index)) return;

    const src_reg = switch (src) {
        .none => return,
        _ => b.resolve(src),
    };
    const dest_reg = b.resolve(dest);
    if (src_reg == dest_reg) return;

    try b.emit(.{
        .tag = .move,
        .data = .{ .reg_reg = .{
            dest_reg,
            src_reg,
        } },
    });
}

fn emitArgumentsArray(b: *Builder, args: []const Ir.Inst.Ref, dest_reg: Bytecode.Reg) Error!void {
    try b.emit(.{
        .tag = .create_array,
        .data = .{ .reg_u32 = .{ dest_reg, 0 } },
    });
    for (args) |arg| {
        const tag: Bytecode.Inst.Tag = blk: {
            if (arg.toIndex()) |arg_index| {
                const arg_inst = arg_index.inst(b.ir);
                if (arg_inst.tag == .spread) {
                    break :blk .array_spread;
                }
            }
            break :blk .array_push;
        };
        // For spread args, `lowerSpread()` will have moved the value into `arg_reg` so we use that
        // unconditionally instead of resolving the spread value ref.
        const arg_reg = b.resolve(arg);
        try b.emit(.{
            .tag = tag,
            .data = .{ .reg_reg = .{
                dest_reg,
                arg_reg,
            } },
        });
    }
}

fn resolve(b: *Builder, ref: Ir.Inst.Ref) Bytecode.Reg {
    const index = ref.toIndex().?;
    const reg = b.lsra.allocations[@backingInt(index)];
    std.debug.assert(reg != .none); // Live instructions must have allocations
    return reg;
}

const IcKind = enum {
    get_property,
    get_property_computed,
    set_property,
    set_property_computed,
};

fn IcIndex(comptime kind: IcKind) type {
    return switch (kind) {
        .get_property => Bytecode.GetPropertyIcIndex,
        .get_property_computed => Bytecode.GetPropertyComputedIcIndex,
        .set_property => Bytecode.SetPropertyIcIndex,
        .set_property_computed => Bytecode.SetPropertyComputedIcIndex,
    };
}

fn nextIcIndex(b: *Builder, comptime kind: IcKind) IcIndex(kind) {
    const count = switch (kind) {
        .get_property => &b.get_property_ic_count,
        .get_property_computed => &b.get_property_computed_ic_count,
        .set_property => &b.set_property_ic_count,
        .set_property_computed => &b.set_property_computed_ic_count,
    };
    const index: IcIndex(kind) = @fromBackingInt(count.*);
    count.* += 1;
    return index;
}

fn lowerUndefined(b: *Builder, dest: Ir.Inst.Ref) Error!void {
    const dest_reg = b.resolve(dest);
    try b.emit(.{
        .tag = .load_undefined,
        .data = .{ .reg = dest_reg },
    });
}

fn lowerNull(b: *Builder, dest: Ir.Inst.Ref) Error!void {
    const dest_reg = b.resolve(dest);
    try b.emit(.{
        .tag = .load_null,
        .data = .{ .reg = dest_reg },
    });
}

fn lowerTrue(b: *Builder, dest: Ir.Inst.Ref) Error!void {
    const dest_reg = b.resolve(dest);
    try b.emit(.{
        .tag = .load_true,
        .data = .{ .reg = dest_reg },
    });
}

fn lowerFalse(b: *Builder, dest: Ir.Inst.Ref) Error!void {
    const dest_reg = b.resolve(dest);
    try b.emit(.{
        .tag = .load_false,
        .data = .{ .reg = dest_reg },
    });
}

fn lowerNumber(b: *Builder, n: f64, dest: Ir.Inst.Ref) Error!void {
    const dest_reg = b.resolve(dest);
    if (n == @floor(n) and !std.math.isNegativeZero(n)) {
        if (n >= std.math.minInt(i8) and n <= std.math.maxInt(i8)) {
            try b.emit(.{
                .tag = .load_number_i8,
                .data = .{ .reg_i8 = .{ dest_reg, @intFromFloat(n) } },
            });
            return;
        }
        if (n >= std.math.minInt(i32) and n <= std.math.maxInt(i32)) {
            try b.emit(.{
                .tag = .load_number_i32,
                .data = .{ .reg_i32 = .{ dest_reg, @intFromFloat(n) } },
            });
            return;
        }
    }
    try b.emit(.{
        .tag = .load_number_f64,
        .data = .{ .reg_f64 = .{ dest_reg, n } },
    });
}

fn lowerString(b: *Builder, string_index: Ir.StringIndex, dest: Ir.Inst.Ref) Error!void {
    const dest_reg = b.resolve(dest);
    const bytecode_string_index: Bytecode.StringIndex = @fromBackingInt(@backingInt(string_index));
    try b.emit(.{
        .tag = .load_string,
        .data = .{ .reg_string = .{
            dest_reg,
            bytecode_string_index,
        } },
    });
}

fn lowerBigInt(b: *Builder, big_int_index: Ir.BigIntIndex, dest: Ir.Inst.Ref) Error!void {
    const dest_reg = b.resolve(dest);
    const bytecode_big_int_index: Bytecode.BigIntIndex = @fromBackingInt(@backingInt(big_int_index));
    try b.emit(.{
        .tag = .load_big_int,
        .data = .{ .reg_big_int = .{
            dest_reg,
            bytecode_big_int_index,
        } },
    });
}

fn lowerCreateArray(b: *Builder, data: Ir.Inst.Array, dest: Ir.Inst.Ref) Error!void {
    const dest_reg = b.resolve(dest);
    try b.emit(.{
        .tag = .create_array,
        .data = .{ .reg_u32 = .{
            dest_reg,
            if (data.has_spread) 0 else data.len,
        } },
    });

    if (data.len > 0) {
        try b.array_states.append(b.gpa, .{
            .index = 0,
            .len = data.len,
            .has_spread = data.has_spread,
        });
    }
}

fn lowerArrayPush(b: *Builder, data: Ir.Inst.Binary) Error!void {
    const array_reg = b.resolve(data.lhs);
    const state = b.array_states.lastPtr().?;
    defer {
        state.index += 1;
        if (state.index == state.len) {
            _ = b.array_states.pop().?;
        }
    }

    if (data.rhs == .none) {
        if (state.has_spread) {
            try b.emit(.{
                .tag = .array_push_hole,
                .data = .{ .reg = array_reg },
            });
        } else {
            // Holes are implicit for arrays without spread
        }
    } else {
        const elem_reg = b.resolve(data.rhs);
        if (state.has_spread) {
            try b.emit(.{
                .tag = .array_push,
                .data = .{ .reg_reg = .{
                    array_reg,
                    elem_reg,
                } },
            });
        } else {
            try b.emit(.{
                .tag = .array_set,
                .data = .{ .reg_reg_u32 = .{
                    array_reg,
                    elem_reg,
                    state.index,
                } },
            });
        }
    }
}

fn lowerArraySpread(b: *Builder, data: Ir.Inst.Binary) Error!void {
    const array_reg = b.resolve(data.lhs);
    const value_reg = b.resolve(data.rhs);
    const state = b.array_states.lastPtr().?;
    std.debug.assert(state.has_spread);
    defer {
        state.index += 1;
        if (state.index == state.len) {
            _ = b.array_states.pop().?;
        }
    }

    try b.emit(.{
        .tag = .array_spread,
        .data = .{ .reg_reg = .{
            array_reg,
            value_reg,
        } },
    });
}

fn lowerCreateObject(b: *Builder, data: Ir.Inst.Object, dest: Ir.Inst.Ref) Error!void {
    const dest_reg = b.resolve(dest);
    try b.emit(.{
        .tag = .create_object,
        .data = .{ .reg_u32 = .{
            dest_reg,
            data.property_count,
        } },
    });
}

fn lowerObjectSet(b: *Builder, extra_index: Ir.ExtraIndex) Error!void {
    const extra = b.ir.extraData(Ir.Inst.SetProperty, extra_index);
    const object_reg = b.resolve(extra.data.base);
    const value_reg = b.resolve(extra.data.value);
    const name_index: Bytecode.StringIndex = @fromBackingInt(@backingInt(extra.data.name));

    const value_index = extra.data.value.toIndex().?;
    const value_inst = value_index.inst(b.ir);

    switch (value_inst.tag) {
        .as_getter, .as_setter, .create_function => {
            try b.emit(.{
                .tag = .set_home_object,
                .data = .{ .reg_reg = .{
                    value_reg,
                    object_reg,
                } },
            });
        },
        else => {},
    }

    try b.emit(.{
        .tag = switch (value_inst.tag) {
            .as_getter => .object_set_getter,
            .as_setter => .object_set_setter,
            else => .object_set,
        },
        .data = .{ .reg_string_reg = .{
            object_reg,
            name_index,
            value_reg,
        } },
    });
}

fn lowerObjectSetComputed(b: *Builder, extra_index: Ir.ExtraIndex) Error!void {
    const extra = b.ir.extraData(Ir.Inst.SetPropertyComputed, extra_index);
    const object_reg = b.resolve(extra.data.base);
    const key_reg = b.resolve(extra.data.property);
    const value_reg = b.resolve(extra.data.value);

    const value_index = extra.data.value.toIndex().?;
    const value_inst = value_index.inst(b.ir);

    switch (value_inst.tag) {
        .as_getter, .as_setter, .create_function => {
            try b.emit(.{
                .tag = .set_home_object,
                .data = .{ .reg_reg = .{
                    value_reg,
                    object_reg,
                } },
            });
        },
        else => {},
    }

    try b.emit(.{
        .tag = switch (value_inst.tag) {
            .as_getter => .object_set_getter_computed,
            .as_setter => .object_set_setter_computed,
            else => .object_set_computed,
        },
        .data = .{ .reg_reg_reg = .{
            object_reg,
            key_reg,
            value_reg,
        } },
    });
}

fn lowerObjectSetPrototype(b: *Builder, data: Ir.Inst.Binary) Error!void {
    const object_reg = b.resolve(data.lhs);
    const value_reg = b.resolve(data.rhs);
    try b.emit(.{
        .tag = .object_set_prototype,
        .data = .{ .reg_reg = .{
            object_reg,
            value_reg,
        } },
    });
}

fn lowerObjectSpread(b: *Builder, data: Ir.Inst.Binary) Error!void {
    const object_reg = b.resolve(data.lhs);
    const value_reg = b.resolve(data.rhs);
    try b.emit(.{
        .tag = .object_spread,
        .data = .{ .reg_reg = .{
            object_reg,
            value_reg,
        } },
    });
}

fn lowerCreateRegExp(b: *Builder, data: Ir.Inst.RegExp, dest: Ir.Inst.Ref) Error!void {
    const dest_reg = b.resolve(dest);
    const pattern_index: Bytecode.StringIndex = @fromBackingInt(@backingInt(data.pattern));
    const flags_index: Bytecode.StringIndex = @fromBackingInt(@backingInt(data.flags));
    try b.emit(.{
        .tag = .create_reg_exp,
        .data = .{ .reg_string_string = .{
            dest_reg,
            pattern_index,
            flags_index,
        } },
    });
}

fn lowerThis(b: *Builder, dest: Ir.Inst.Ref) Error!void {
    const dest_reg = b.resolve(dest);
    try b.emit(.{
        .tag = .resolve_this_binding,
        .data = .{ .reg = dest_reg },
    });
}

fn lowerLabel(b: *Builder, dest: Ir.Inst.Ref) Error!void {
    const label_block = b.label_blocks.get(dest).?;
    if (!b.terminated()) {
        b.jump(label_block);
    }
    b.current_block = label_block;
}

fn lowerBr(b: *Builder, data: Ir.Inst.Br) Error!void {
    try b.emitMoveIfNeeded(data.value, data.target);
    const target_block = b.label_blocks.get(data.target).?;
    b.jump(target_block);
}

fn lowerBrCond(b: *Builder, extra_index: Ir.ExtraIndex) Error!void {
    const extra = b.ir.extraData(Ir.Inst.BrCond, extra_index);
    const then_block = b.label_blocks.get(extra.data.then_target).?;
    const else_block = b.label_blocks.get(extra.data.else_target).?;
    const cond_reg = b.resolve(extra.data.condition);
    b.branch(.truthy, cond_reg, then_block, else_block);
}

fn lowerExceptionHandler(b: *Builder, extra_index: Ir.ExtraIndex, exception_ref: Ir.Inst.Ref) Error!void {
    const extra = b.ir.extraData(Ir.Inst.ExceptionHandler, extra_index);
    const start_block = b.label_blocks.get(extra.data.start).?;
    const end_block = b.label_blocks.get(extra.data.end).?;
    const target_block = b.label_blocks.get(extra.data.target).?;
    const exception_reg = b.resolve(exception_ref);
    const scope_depth = extra.data.scope_depth;
    try b.exception_handlers.append(b.gpa, .{
        .start = start_block,
        .end = end_block,
        .target = target_block,
        .exception_reg = exception_reg,
        .scope_depth = scope_depth,
    });
}

fn lowerToBoolean(b: *Builder, value: Ir.Inst.Ref, dest: Ir.Inst.Ref) Error!void {
    try b.emitUnaryOp(.to_boolean, value, dest);
}

fn lowerToNumber(b: *Builder, value: Ir.Inst.Ref, dest: Ir.Inst.Ref) Error!void {
    try b.emitUnaryOp(.to_number, value, dest);
}

fn lowerToNumeric(b: *Builder, value: Ir.Inst.Ref, dest: Ir.Inst.Ref) Error!void {
    try b.emitUnaryOp(.to_numeric, value, dest);
}

fn lowerToString(b: *Builder, value: Ir.Inst.Ref, dest: Ir.Inst.Ref) Error!void {
    try b.emitUnaryOp(.to_string, value, dest);
}

fn lowerToObject(b: *Builder, value: Ir.Inst.Ref, dest: Ir.Inst.Ref) Error!void {
    try b.emitUnaryOp(.to_object, value, dest);
}

fn lowerIncrement(b: *Builder, value: Ir.Inst.Ref, dest: Ir.Inst.Ref) Error!void {
    try b.emitUnaryOp(.increment, value, dest);
}

fn lowerDecrement(b: *Builder, value: Ir.Inst.Ref, dest: Ir.Inst.Ref) Error!void {
    try b.emitUnaryOp(.decrement, value, dest);
}

fn lowerNegate(b: *Builder, value: Ir.Inst.Ref, dest: Ir.Inst.Ref) Error!void {
    try b.emitUnaryOp(.negate, value, dest);
}

fn lowerBitwiseNot(b: *Builder, value: Ir.Inst.Ref, dest: Ir.Inst.Ref) Error!void {
    try b.emitUnaryOp(.bitwise_not, value, dest);
}

fn lowerLogicalNot(b: *Builder, value: Ir.Inst.Ref, dest: Ir.Inst.Ref) Error!void {
    try b.emitUnaryOp(.logical_not, value, dest);
}

fn lowerIsNullish(b: *Builder, value: Ir.Inst.Ref, dest: Ir.Inst.Ref) Error!void {
    try b.emitUnaryOp(.is_nullish, value, dest);
}

fn lowerTypeof(b: *Builder, value: Ir.Inst.Ref, dest: Ir.Inst.Ref) Error!void {
    try b.emitUnaryOp(.typeof, value, dest);
}

fn lowerTypeofBinding(b: *Builder, name_index: Ir.StringIndex, dest: Ir.Inst.Ref) Error!void {
    const dest_reg = b.resolve(dest);
    if (b.locals.get(name_index)) |local| {
        try b.emit(.{
            .tag = .typeof_local,
            .data = .{ .reg_local = .{
                dest_reg,
                local,
            } },
        });
    } else {
        const name_index_: Bytecode.StringIndex = @fromBackingInt(@backingInt(name_index));
        try b.emit(.{
            .tag = .typeof_binding,
            .data = .{ .reg_string = .{
                dest_reg,
                name_index_,
            } },
        });
    }
}

fn lowerSpread(b: *Builder, value: Ir.Inst.Ref, dest: Ir.Inst.Ref) Error!void {
    try b.emitMoveIfNeeded(value, dest);
}

fn lowerAdd(b: *Builder, data: Ir.Inst.Binary, dest: Ir.Inst.Ref) Error!void {
    try b.emitBinaryOp(.add, data.lhs, data.rhs, dest);
}

fn lowerSub(b: *Builder, data: Ir.Inst.Binary, dest: Ir.Inst.Ref) Error!void {
    try b.emitBinaryOp(.sub, data.lhs, data.rhs, dest);
}

fn lowerMul(b: *Builder, data: Ir.Inst.Binary, dest: Ir.Inst.Ref) Error!void {
    try b.emitBinaryOp(.mul, data.lhs, data.rhs, dest);
}

fn lowerDiv(b: *Builder, data: Ir.Inst.Binary, dest: Ir.Inst.Ref) Error!void {
    try b.emitBinaryOp(.div, data.lhs, data.rhs, dest);
}

fn lowerRem(b: *Builder, data: Ir.Inst.Binary, dest: Ir.Inst.Ref) Error!void {
    try b.emitBinaryOp(.rem, data.lhs, data.rhs, dest);
}

fn lowerExp(b: *Builder, data: Ir.Inst.Binary, dest: Ir.Inst.Ref) Error!void {
    try b.emitBinaryOp(.exp, data.lhs, data.rhs, dest);
}

fn lowerShiftLeft(b: *Builder, data: Ir.Inst.Binary, dest: Ir.Inst.Ref) Error!void {
    try b.emitBinaryOp(.shift_left, data.lhs, data.rhs, dest);
}

fn lowerShiftRight(b: *Builder, data: Ir.Inst.Binary, dest: Ir.Inst.Ref) Error!void {
    try b.emitBinaryOp(.shift_right, data.lhs, data.rhs, dest);
}

fn lowerShiftRightUnsigned(b: *Builder, data: Ir.Inst.Binary, dest: Ir.Inst.Ref) Error!void {
    try b.emitBinaryOp(.shift_right_unsigned, data.lhs, data.rhs, dest);
}

fn lowerBitwiseAnd(b: *Builder, data: Ir.Inst.Binary, dest: Ir.Inst.Ref) Error!void {
    try b.emitBinaryOp(.bitwise_and, data.lhs, data.rhs, dest);
}

fn lowerBitwiseOr(b: *Builder, data: Ir.Inst.Binary, dest: Ir.Inst.Ref) Error!void {
    try b.emitBinaryOp(.bitwise_or, data.lhs, data.rhs, dest);
}

fn lowerBitwiseXor(b: *Builder, data: Ir.Inst.Binary, dest: Ir.Inst.Ref) Error!void {
    try b.emitBinaryOp(.bitwise_xor, data.lhs, data.rhs, dest);
}

fn lowerLt(b: *Builder, data: Ir.Inst.Binary, dest: Ir.Inst.Ref) Error!void {
    try b.emitBinaryOp(.lt, data.lhs, data.rhs, dest);
}

fn lowerGt(b: *Builder, data: Ir.Inst.Binary, dest: Ir.Inst.Ref) Error!void {
    try b.emitBinaryOp(.gt, data.lhs, data.rhs, dest);
}

fn lowerLtEq(b: *Builder, data: Ir.Inst.Binary, dest: Ir.Inst.Ref) Error!void {
    try b.emitBinaryOp(.lt_eq, data.lhs, data.rhs, dest);
}

fn lowerGtEq(b: *Builder, data: Ir.Inst.Binary, dest: Ir.Inst.Ref) Error!void {
    try b.emitBinaryOp(.gt_eq, data.lhs, data.rhs, dest);
}

fn lowerInstanceof(b: *Builder, data: Ir.Inst.Binary, dest: Ir.Inst.Ref) Error!void {
    try b.emitBinaryOp(.instanceof, data.lhs, data.rhs, dest);
}

fn lowerIn(b: *Builder, data: Ir.Inst.Binary, dest: Ir.Inst.Ref) Error!void {
    try b.emitBinaryOp(.in, data.lhs, data.rhs, dest);
}

fn lowerEq(b: *Builder, data: Ir.Inst.Binary, dest: Ir.Inst.Ref) Error!void {
    try b.emitBinaryOp(.eq, data.lhs, data.rhs, dest);
}

fn lowerNotEq(b: *Builder, data: Ir.Inst.Binary, dest: Ir.Inst.Ref) Error!void {
    try b.emitBinaryOp(.not_eq, data.lhs, data.rhs, dest);
}

fn lowerEqStrict(b: *Builder, data: Ir.Inst.Binary, dest: Ir.Inst.Ref) Error!void {
    try b.emitBinaryOp(.eq_strict, data.lhs, data.rhs, dest);
}

fn lowerNotEqStrict(b: *Builder, data: Ir.Inst.Binary, dest: Ir.Inst.Ref) Error!void {
    try b.emitBinaryOp(.not_eq_strict, data.lhs, data.rhs, dest);
}

fn lowerPushScope(b: *Builder) Error!void {
    try b.emit(.{
        .tag = .push_scope,
        .data = .{ .none = {} },
    });
}

fn lowerPushCatchScope(b: *Builder) Error!void {
    try b.emit(.{
        .tag = .push_catch_scope,
        .data = .{ .none = {} },
    });
}

fn lowerPushVarScope(b: *Builder) Error!void {
    try b.emit(.{
        .tag = .push_var_scope,
        .data = .{ .none = {} },
    });
}

fn lowerPushWithScope(b: *Builder, ref: Ir.Inst.Ref) Error!void {
    const object_reg = b.resolve(ref);
    try b.emit(.{
        .tag = .push_with_scope,
        .data = .{ .reg = object_reg },
    });
}

fn lowerPopScope(b: *Builder) Error!void {
    try b.emit(.{
        .tag = .pop_scope,
        .data = .{ .none = {} },
    });
}

fn lowerCreateVarBinding(b: *Builder, name_index: Ir.StringIndex) Error!void {
    if (b.locals.get(name_index)) |_| {
        // Implicitly initialized to undefined via the Vm.
    } else {
        const name_index_: Bytecode.StringIndex = @fromBackingInt(@backingInt(name_index));
        try b.emit(.{
            .tag = .create_var_binding,
            .data = .{ .string = name_index_ },
        });
    }
}

fn lowerCreateMutableBinding(b: *Builder, name_index: Ir.StringIndex) Error!void {
    if (b.locals.get(name_index)) |_| {
        // Implicitly initialized to undefined via the Vm.
    } else {
        const name_index_: Bytecode.StringIndex = @fromBackingInt(@backingInt(name_index));
        try b.emit(.{
            .tag = .create_mutable_binding,
            .data = .{ .string = name_index_ },
        });
    }
}

fn lowerCreateImmutableBinding(b: *Builder, name_index: Ir.StringIndex) Error!void {
    if (b.locals.get(name_index)) |_| {
        // Implicitly initialized to undefined via the Vm.
    } else {
        const name_index_: Bytecode.StringIndex = @fromBackingInt(@backingInt(name_index));
        try b.emit(.{
            .tag = .create_immutable_binding,
            .data = .{ .string = name_index_ },
        });
    }
}

fn lowerInitializeBinding(b: *Builder, name_index: Ir.StringIndex, value: Ir.Inst.Ref, dest: Ir.Inst.Ref) Error!void {
    const value_reg = b.resolve(value);
    if (b.locals.get(name_index)) |local| {
        try b.emit(.{
            .tag = .set_local,
            .data = .{ .local_reg = .{
                local,
                value_reg,
            } },
        });
    } else {
        const name_index_: Bytecode.StringIndex = @fromBackingInt(@backingInt(name_index));
        try b.emit(.{
            .tag = .initialize_binding,
            .data = .{ .string_reg = .{
                name_index_,
                value_reg,
            } },
        });
    }
    try b.emitMoveIfNeeded(value, dest);
}

fn lowerGetBinding(b: *Builder, name_index: Ir.StringIndex, dest: Ir.Inst.Ref) Error!void {
    const dest_reg = b.resolve(dest);
    if (b.locals.get(name_index)) |local| {
        try b.emit(.{
            .tag = .get_local,
            .data = .{ .reg_local = .{
                dest_reg,
                local,
            } },
        });
    } else {
        const name_index_: Bytecode.StringIndex = @fromBackingInt(@backingInt(name_index));
        try b.emit(.{
            .tag = .get_binding,
            .data = .{ .reg_string = .{
                dest_reg,
                name_index_,
            } },
        });
    }
}

fn lowerGetProperty(b: *Builder, data: Ir.Inst.GetProperty, dest: Ir.Inst.Ref) Error!void {
    const dest_reg = b.resolve(dest);
    const base_reg = b.resolve(data.base);
    const name_index: Bytecode.StringIndex = @fromBackingInt(@backingInt(data.name));
    const ic_index = b.nextIcIndex(.get_property);
    try b.emit(.{
        .tag = .get_property,
        .data = .{ .reg_reg_string_get_property_ic = .{
            dest_reg,
            base_reg,
            name_index,
            ic_index,
        } },
    });
}

fn lowerGetPropertyComputed(b: *Builder, data: Ir.Inst.GetPropertyComputed, dest: Ir.Inst.Ref) Error!void {
    const dest_reg = b.resolve(dest);
    const base_reg = b.resolve(data.base);
    const property_reg = b.resolve(data.property);
    const ic_index = b.nextIcIndex(.get_property_computed);
    try b.emit(.{
        .tag = .get_property_computed,
        .data = .{ .reg_reg_reg_get_property_computed_ic = .{
            dest_reg,
            base_reg,
            property_reg,
            ic_index,
        } },
    });
}

fn lowerGetPropertyIndexed(b: *Builder, data: Ir.Inst.GetPropertyIndexed, dest: Ir.Inst.Ref) Error!void {
    const dest_reg = b.resolve(dest);
    const base_reg = b.resolve(data.base);
    try b.emit(.{
        .tag = .get_property_indexed,
        .data = .{ .reg_reg_u32 = .{
            dest_reg,
            base_reg,
            data.index,
        } },
    });
}

fn lowerSetBinding(b: *Builder, name_index: Ir.StringIndex, value: Ir.Inst.Ref, strict: bool, dest: Ir.Inst.Ref) Error!void {
    const value_reg = b.resolve(value);
    if (b.locals.get(name_index)) |local| {
        try b.emit(.{
            .tag = .set_local,
            .data = .{ .local_reg = .{
                local,
                value_reg,
            } },
        });
    } else {
        const name_index_: Bytecode.StringIndex = @fromBackingInt(@backingInt(name_index));
        const tag: Bytecode.Inst.Tag = if (strict)
            .set_binding_strict
        else
            .set_binding;
        try b.emit(.{
            .tag = tag,
            .data = .{ .string_reg = .{
                name_index_,
                value_reg,
            } },
        });
    }
    try b.emitMoveIfNeeded(value, dest);
}

fn lowerSetProperty(b: *Builder, extra_index: Ir.ExtraIndex, strict: bool, dest: Ir.Inst.Ref) Error!void {
    const extra = b.ir.extraData(Ir.Inst.SetProperty, extra_index);
    const base_reg = b.resolve(extra.data.base);
    const value_reg = b.resolve(extra.data.value);
    const name_index: Bytecode.StringIndex = @fromBackingInt(@backingInt(extra.data.name));
    const ic_index = b.nextIcIndex(.set_property);
    const tag: Bytecode.Inst.Tag = if (strict)
        .set_property_strict
    else
        .set_property;
    try b.emit(.{
        .tag = tag,
        .data = .{ .reg_reg_string_set_property_ic = .{
            base_reg,
            value_reg,
            name_index,
            ic_index,
        } },
    });
    try b.emitMoveIfNeeded(extra.data.value, dest);
}

fn lowerSetPropertyComputed(b: *Builder, extra_index: Ir.ExtraIndex, strict: bool, dest: Ir.Inst.Ref) Error!void {
    const extra = b.ir.extraData(Ir.Inst.SetPropertyComputed, extra_index);
    const base_reg = b.resolve(extra.data.base);
    const property_reg = b.resolve(extra.data.property);
    const value_reg = b.resolve(extra.data.value);
    const ic_index = b.nextIcIndex(.set_property_computed);
    const tag: Bytecode.Inst.Tag = if (strict)
        .set_property_computed_strict
    else
        .set_property_computed;
    try b.emit(.{
        .tag = tag,
        .data = .{ .reg_reg_reg_set_property_computed_ic = .{
            base_reg,
            property_reg,
            value_reg,
            ic_index,
        } },
    });
    try b.emitMoveIfNeeded(extra.data.value, dest);
}

fn lowerSetPropertyIndexed(b: *Builder, extra_index: Ir.ExtraIndex, strict: bool, dest: Ir.Inst.Ref) Error!void {
    const extra = b.ir.extraData(Ir.Inst.SetPropertyIndexed, extra_index);
    const base_reg = b.resolve(extra.data.base);
    const value_reg = b.resolve(extra.data.value);
    const tag: Bytecode.Inst.Tag = if (strict)
        .set_property_indexed_strict
    else
        .set_property_indexed;
    try b.emit(.{
        .tag = tag,
        .data = .{ .reg_reg_u32 = .{
            base_reg,
            value_reg,
            extra.data.index,
        } },
    });
    try b.emitMoveIfNeeded(extra.data.value, dest);
}

fn lowerDeleteBinding(b: *Builder, name_index: Ir.StringIndex, dest: Ir.Inst.Ref) Error!void {
    const dest_reg = b.resolve(dest);
    if (b.locals.get(name_index)) |_| {
        try b.emit(.{
            .tag = .load_false,
            .data = .{ .reg = dest_reg },
        });
    } else {
        const name_index_: Bytecode.StringIndex = @fromBackingInt(@backingInt(name_index));
        try b.emit(.{
            .tag = .delete_binding,
            .data = .{ .reg_string = .{
                dest_reg,
                name_index_,
            } },
        });
    }
}

fn lowerDeleteProperty(b: *Builder, data: Ir.Inst.DeleteProperty, strict: bool, dest: Ir.Inst.Ref) Error!void {
    const dest_reg = b.resolve(dest);
    const base_reg = b.resolve(data.base);
    const name_index: Bytecode.StringIndex = @fromBackingInt(@backingInt(data.name));
    const tag: Bytecode.Inst.Tag = if (strict)
        .delete_property_strict
    else
        .delete_property;
    try b.emit(.{
        .tag = tag,
        .data = .{ .reg_reg_string = .{
            dest_reg,
            base_reg,
            name_index,
        } },
    });
}

fn lowerDeletePropertyComputed(b: *Builder, data: Ir.Inst.DeletePropertyComputed, strict: bool, dest: Ir.Inst.Ref) Error!void {
    const dest_reg = b.resolve(dest);
    const base_reg = b.resolve(data.base);
    const property_reg = b.resolve(data.property);
    const tag: Bytecode.Inst.Tag = if (strict)
        .delete_property_computed_strict
    else
        .delete_property_computed;
    try b.emit(.{
        .tag = tag,
        .data = .{ .reg_reg_reg = .{
            dest_reg,
            base_reg,
            property_reg,
        } },
    });
}

fn lowerDeletePropertyIndexed(b: *Builder, data: Ir.Inst.DeletePropertyIndexed, strict: bool, dest: Ir.Inst.Ref) Error!void {
    const dest_reg = b.resolve(dest);
    const base_reg = b.resolve(data.base);
    const tag: Bytecode.Inst.Tag = if (strict)
        .delete_property_indexed_strict
    else
        .delete_property_indexed;
    try b.emit(.{
        .tag = tag,
        .data = .{ .reg_reg_u32 = .{
            dest_reg,
            base_reg,
            data.index,
        } },
    });
}

fn lowerCopyDataProperties(b: *Builder, extra_index: Ir.ExtraIndex, dest: Ir.Inst.Ref) Error!void {
    const extra = b.ir.extraData(Ir.Inst.CopyDataProperties, extra_index);
    const dest_reg = b.resolve(dest);
    const source_reg = b.resolve(extra.data.source);
    const excluded = b.ir.refSlice(extra.end, extra.data.excluded_len);

    if (excluded.len == 0) {
        try b.emit(.{
            .tag = .copy_data_properties,
            .data = .{ .reg_reg_reg = .{
                dest_reg,
                source_reg,
                .none,
            } },
        });
        return;
    }

    const excluded_reg = try b.lsra.allocateTemp(b.gpa);
    defer b.lsra.freeTemp(excluded_reg);
    try b.emit(.{
        .tag = .create_array,
        .data = .{ .reg_u32 = .{
            excluded_reg,
            0,
        } },
    });
    for (excluded) |prop| {
        const prop_reg = b.resolve(prop);
        try b.emit(.{
            .tag = .array_push,
            .data = .{ .reg_reg = .{
                excluded_reg,
                prop_reg,
            } },
        });
    }

    try b.emit(.{
        .tag = .copy_data_properties,
        .data = .{ .reg_reg_reg = .{
            dest_reg,
            source_reg,
            excluded_reg,
        } },
    });
}

fn lowerCall(b: *Builder, extra_index: Ir.ExtraIndex, dest: Ir.Inst.Ref) Error!void {
    const extra = b.ir.extraData(Ir.Inst.Call, extra_index);
    const dest_reg = b.resolve(dest);
    const callee_reg = b.resolve(extra.data.callee);
    const this_reg = switch (extra.data.this_value) {
        .none => .none,
        _ => |ref| b.resolve(ref),
    };
    const args = b.ir.refSlice(extra.end, extra.data.args_len);

    const has_spread = for (args) |arg| {
        if (arg.toIndex()) |arg_index| {
            const arg_inst = arg_index.inst(b.ir);
            if (arg_inst.tag == .spread) {
                break true;
            }
        }
    } else false;

    if (args.len <= 2 and !has_spread) {
        try b.emit(switch (this_reg) {
            .none => switch (args.len) {
                0 => .{ .tag = .call0, .data = .{ .reg_reg = .{ dest_reg, callee_reg } } },
                1 => .{ .tag = .call1, .data = .{ .reg_reg_reg = .{ dest_reg, callee_reg, b.resolve(args[0]) } } },
                2 => .{ .tag = .call2, .data = .{ .reg_reg_reg_reg = .{ dest_reg, callee_reg, b.resolve(args[0]), b.resolve(args[1]) } } },
                else => unreachable,
            },
            else => switch (args.len) {
                0 => .{ .tag = .call_property0, .data = .{ .reg_reg_reg = .{ dest_reg, callee_reg, this_reg } } },
                1 => .{ .tag = .call_property1, .data = .{ .reg_reg_reg_reg = .{ dest_reg, callee_reg, this_reg, b.resolve(args[0]) } } },
                2 => .{ .tag = .call_property2, .data = .{ .reg_reg_reg_reg_reg = .{ dest_reg, callee_reg, this_reg, b.resolve(args[0]), b.resolve(args[1]) } } },
                else => unreachable,
            },
        });
        return;
    }

    const args_reg = try b.lsra.allocateTemp(b.gpa);
    defer b.lsra.freeTemp(args_reg);
    try b.emitArgumentsArray(args, args_reg);

    switch (extra.data.this_value) {
        .none => try b.emit(.{
            .tag = .call,
            .data = .{ .reg_reg_reg = .{
                dest_reg,
                callee_reg,
                args_reg,
            } },
        }),
        else => try b.emit(.{
            .tag = .call_property,
            .data = .{ .reg_reg_reg_reg = .{
                dest_reg,
                callee_reg,
                this_reg,
                args_reg,
            } },
        }),
    }
}

fn lowerCallDirectEval(b: *Builder, extra_index: Ir.ExtraIndex, dest: Ir.Inst.Ref, strict: bool) Error!void {
    const extra = b.ir.extraData(Ir.Inst.Call, extra_index);
    const dest_reg = b.resolve(dest);
    const callee_reg = b.resolve(extra.data.callee);
    const args = b.ir.refSlice(extra.end, extra.data.args_len);

    const args_reg = try b.lsra.allocateTemp(b.gpa);
    defer b.lsra.freeTemp(args_reg);
    try b.emitArgumentsArray(args, args_reg);

    try b.emit(.{
        .tag = if (strict) .call_direct_eval_strict else .call_direct_eval,
        .data = .{ .reg_reg_reg = .{
            dest_reg,
            callee_reg,
            args_reg,
        } },
    });
}

fn lowerConstruct(b: *Builder, extra_index: Ir.ExtraIndex, dest: Ir.Inst.Ref) Error!void {
    const extra = b.ir.extraData(Ir.Inst.Construct, extra_index);
    const dest_reg = b.resolve(dest);
    const constructor_reg = b.resolve(extra.data.constructor);
    const args = b.ir.refSlice(extra.end, extra.data.args_len);

    const has_spread = for (args) |arg| {
        if (arg.toIndex()) |arg_index| {
            const arg_inst = arg_index.inst(b.ir);
            if (arg_inst.tag == .spread) {
                break true;
            }
        }
    } else false;

    if (args.len <= 2 and !has_spread) {
        try b.emit(switch (args.len) {
            0 => .{ .tag = .construct0, .data = .{ .reg_reg = .{ dest_reg, constructor_reg } } },
            1 => .{ .tag = .construct1, .data = .{ .reg_reg_reg = .{ dest_reg, constructor_reg, b.resolve(args[0]) } } },
            2 => .{ .tag = .construct2, .data = .{ .reg_reg_reg_reg = .{ dest_reg, constructor_reg, b.resolve(args[0]), b.resolve(args[1]) } } },
            else => unreachable,
        });
        return;
    }

    const args_reg = try b.lsra.allocateTemp(b.gpa);
    defer b.lsra.freeTemp(args_reg);
    try b.emitArgumentsArray(args, args_reg);

    try b.emit(.{
        .tag = .construct,
        .data = .{ .reg_reg_reg = .{
            dest_reg,
            constructor_reg,
            args_reg,
        } },
    });
}

fn lowerGetTemplateObject(b: *Builder, extra_index: Ir.ExtraIndex, dest: Ir.Inst.Ref) Error!void {
    const extra = b.ir.extraData(Ir.Inst.GetTemplateObject, extra_index);
    const dest_reg = b.resolve(dest);
    const raw_reg = b.resolve(extra.data.raw);
    const cooked_reg = b.resolve(extra.data.cooked);

    try b.emit(.{
        .tag = .get_template_object,
        .data = .{ .reg_reg_reg_u16 = .{
            dest_reg,
            raw_reg,
            cooked_reg,
            @intCast(extra.data.id),
        } },
    });
}

fn lowerGetIterator(b: *Builder, value: Ir.Inst.Ref, dest: Ir.Inst.Ref) Error!void {
    const dest_reg = b.resolve(dest);
    const value_reg = b.resolve(value);
    try b.emit(.{
        .tag = .get_iterator,
        .data = .{ .reg_reg = .{
            dest_reg,
            value_reg,
        } },
    });
}

fn lowerGetAsyncIterator(b: *Builder, value: Ir.Inst.Ref, dest: Ir.Inst.Ref) Error!void {
    const dest_reg = b.resolve(dest);
    const value_reg = b.resolve(value);
    try b.emit(.{
        .tag = .get_async_iterator,
        .data = .{ .reg_reg = .{
            dest_reg,
            value_reg,
        } },
    });
}

fn lowerGetForInIterator(b: *Builder, value: Ir.Inst.Ref, dest: Ir.Inst.Ref) Error!void {
    const dest_reg = b.resolve(dest);
    const value_reg = b.resolve(value);
    try b.emit(.{
        .tag = .get_for_in_iterator,
        .data = .{ .reg_reg = .{
            dest_reg,
            value_reg,
        } },
    });
}

fn lowerIteratorStep(b: *Builder, iterator: Ir.Inst.Ref, dest: Ir.Inst.Ref) Error!void {
    const dest_reg = b.resolve(dest);
    const iterator_reg = b.resolve(iterator);
    try b.emit(.{
        .tag = .iterator_step,
        .data = .{ .reg_reg = .{
            dest_reg,
            iterator_reg,
        } },
    });
}

fn lowerIteratorStepValue(b: *Builder, iterator: Ir.Inst.Ref, dest: Ir.Inst.Ref) Error!void {
    const dest_reg = b.resolve(dest);
    const iterator_reg = b.resolve(iterator);
    try b.emit(.{
        .tag = .iterator_step_value,
        .data = .{ .reg_reg = .{
            dest_reg,
            iterator_reg,
        } },
    });
}

fn lowerIteratorStepValueAsync(b: *Builder, iterator: Ir.Inst.Ref, dest: Ir.Inst.Ref) Error!void {
    const dest_reg = b.resolve(dest);
    const iterator_reg = b.resolve(iterator);
    try b.emit(.{
        .tag = .iterator_step_value_async,
        .data = .{ .reg_reg = .{
            dest_reg,
            iterator_reg,
        } },
    });
}

fn lowerIteratorClose(b: *Builder, iterator: Ir.Inst.Ref) Error!void {
    const iterator_reg = b.resolve(iterator);
    try b.emit(.{
        .tag = .iterator_close,
        .data = .{ .reg = iterator_reg },
    });
}

fn lowerIteratorIsDone(b: *Builder, iterator: Ir.Inst.Ref, dest: Ir.Inst.Ref) Error!void {
    const dest_reg = b.resolve(dest);
    const iterator_reg = b.resolve(iterator);
    try b.emit(.{
        .tag = .iterator_is_done,
        .data = .{ .reg_reg = .{
            dest_reg,
            iterator_reg,
        } },
    });
}

fn lowerIteratorCollect(b: *Builder, iterator: Ir.Inst.Ref, dest: Ir.Inst.Ref) Error!void {
    const dest_reg = b.resolve(dest);
    const iterator_reg = b.resolve(iterator);
    try b.emit(.{
        .tag = .iterator_collect,
        .data = .{ .reg_reg = .{
            dest_reg,
            iterator_reg,
        } },
    });
}

fn lowerThrow(b: *Builder, value: Ir.Inst.Ref) Error!void {
    const value_reg = b.resolve(value);
    try b.emit(.{
        .tag = .throw,
        .data = .{ .reg = value_reg },
    });
    b.noreturn();
}

fn lowerThrowReferenceError(b: *Builder) Error!void {
    try b.emit(.{
        .tag = .throw_reference_error,
        .data = .{ .none = {} },
    });
    b.noreturn();
}

fn lowerReturn(b: *Builder, value: Ir.Inst.Ref) Error!void {
    const ret_reg = switch (value) {
        .none => .none,
        _ => b.resolve(value),
    };
    try b.emit(.{
        .tag = .@"return",
        .data = .{ .reg = ret_reg },
    });
    b.noreturn();
}

fn lowerAwait(b: *Builder, value: Ir.Inst.Ref, dest: Ir.Inst.Ref) Error!void {
    const dest_reg = b.resolve(dest);
    const value_reg = b.resolve(value);
    try b.emit(.{
        .tag = .await,
        .data = .{ .reg_reg = .{
            dest_reg,
            value_reg,
        } },
    });
}

fn lowerYield(b: *Builder, value: Ir.Inst.Ref, dest: Ir.Inst.Ref) Error!void {
    switch (value) {
        .none => {
            try b.emit(.{
                .tag = .yield,
                .data = .{ .reg_reg = .{ .none, .none } },
            });
        },
        _ => {
            const dest_reg = b.resolve(dest);
            const value_reg = b.resolve(value);
            try b.emit(.{
                .tag = .yield,
                .data = .{ .reg_reg = .{
                    dest_reg,
                    value_reg,
                } },
            });
        },
    }
}

fn lowerYieldStar(b: *Builder, value: Ir.Inst.Ref, dest: Ir.Inst.Ref) Error!void {
    const dest_reg = b.resolve(dest);
    const value_reg = b.resolve(value);
    try b.emit(.{
        .tag = .load_undefined,
        .data = .{ .reg = dest_reg },
    });
    try b.emit(.{
        .tag = .yield_star,
        .data = .{ .reg_reg = .{
            dest_reg,
            value_reg,
        } },
    });
}

fn lowerCreateFunction(b: *Builder, function_index: Ir.Function.Index, dest: Ir.Inst.Ref) Error!void {
    const dest_reg = b.resolve(dest);
    const bytecode_function_index: Bytecode.Function.Index = @fromBackingInt(@backingInt(function_index));
    try b.emit(.{
        .tag = .create_function,
        .data = .{ .reg_function = .{
            dest_reg,
            bytecode_function_index,
        } },
    });
}

fn lowerCreateClass(b: *Builder, class_index: Ir.Class.Index, dest: Ir.Inst.Ref) Error!void {
    const dest_reg = b.resolve(dest);
    const bytecode_class_index: Bytecode.Class.Index = @fromBackingInt(@backingInt(class_index));
    try b.emit(.{
        .tag = .create_class,
        .data = .{ .reg_class = .{
            dest_reg,
            bytecode_class_index,
        } },
    });
}

fn lowerCreateUnmappedArgumentsObject(b: *Builder, dest: Ir.Inst.Ref) Error!void {
    const dest_reg = b.resolve(dest);
    try b.emit(.{
        .tag = .create_unmapped_arguments_object,
        .data = .{ .reg = dest_reg },
    });
}

fn lowerCreateMappedArgumentsObject(b: *Builder, dest: Ir.Inst.Ref) Error!void {
    const dest_reg = b.resolve(dest);
    try b.emit(.{
        .tag = .create_mapped_arguments_object,
        .data = .{ .reg = dest_reg },
    });
}

fn lowerGetArgument(b: *Builder, arg_index: u16, dest: Ir.Inst.Ref) Error!void {
    const dest_reg = b.resolve(dest);
    try b.emit(.{
        .tag = .get_argument,
        .data = .{ .reg_u16 = .{
            dest_reg,
            arg_index,
        } },
    });
}

fn lowerGetRestArguments(b: *Builder, start_index: u16, dest: Ir.Inst.Ref) Error!void {
    const dest_reg = b.resolve(dest);
    try b.emit(.{
        .tag = .get_rest_arguments,
        .data = .{ .reg_u16 = .{
            dest_reg,
            start_index,
        } },
    });
}

fn lowerGetNewTarget(b: *Builder, dest: Ir.Inst.Ref) Error!void {
    const dest_reg = b.resolve(dest);
    try b.emit(.{
        .tag = .get_new_target,
        .data = .{ .reg = dest_reg },
    });
}

fn lowerAsGetter(b: *Builder, ref: Ir.Inst.Ref, dest: Ir.Inst.Ref) Error!void {
    try b.emitMoveIfNeeded(ref, dest);
}

fn lowerAsSetter(b: *Builder, ref: Ir.Inst.Ref, dest: Ir.Inst.Ref) Error!void {
    try b.emitMoveIfNeeded(ref, dest);
}

fn lowerSuperCall(b: *Builder, extra_index: Ir.ExtraIndex, dest: Ir.Inst.Ref) Error!void {
    const extra = b.ir.extraData(Ir.Inst.SuperCall, extra_index);
    const dest_reg = b.resolve(dest);
    const args = b.ir.refSlice(extra.end, extra.data.args_len);

    const args_reg = try b.lsra.allocateTemp(b.gpa);
    defer b.lsra.freeTemp(args_reg);
    try b.emitArgumentsArray(args, args_reg);

    try b.emit(.{
        .tag = .super_call,
        .data = .{ .reg_reg = .{
            dest_reg,
            args_reg,
        } },
    });
}

fn lowerGetSuperProperty(b: *Builder, name_index: Ir.StringIndex, dest: Ir.Inst.Ref) Error!void {
    const dest_reg = b.resolve(dest);
    const name_index_: Bytecode.StringIndex = @fromBackingInt(@backingInt(name_index));
    try b.emit(.{
        .tag = .get_super_property,
        .data = .{ .reg_string = .{
            dest_reg,
            name_index_,
        } },
    });
}

fn lowerGetSuperPropertyComputed(b: *Builder, property: Ir.Inst.Ref, dest: Ir.Inst.Ref) Error!void {
    const dest_reg = b.resolve(dest);
    const property_reg = b.resolve(property);
    try b.emit(.{
        .tag = .get_super_property_computed,
        .data = .{ .reg_reg = .{
            dest_reg,
            property_reg,
        } },
    });
}

fn lowerSetSuperProperty(b: *Builder, extra_index: Ir.ExtraIndex, comptime strict: bool, dest: Ir.Inst.Ref) Error!void {
    const extra = b.ir.extraData(Ir.Inst.SetProperty, extra_index);
    const value_reg = b.resolve(extra.data.value);
    const name_index: Bytecode.StringIndex = @fromBackingInt(@backingInt(extra.data.name));
    const tag: Bytecode.Inst.Tag = if (strict)
        .set_super_property_strict
    else
        .set_super_property;
    try b.emit(.{
        .tag = tag,
        .data = .{ .reg_string = .{
            value_reg,
            name_index,
        } },
    });
    try b.emitMoveIfNeeded(extra.data.value, dest);
}

fn lowerSetSuperPropertyComputed(b: *Builder, extra_index: Ir.ExtraIndex, comptime strict: bool, dest: Ir.Inst.Ref) Error!void {
    const extra = b.ir.extraData(Ir.Inst.SetPropertyComputed, extra_index);
    const property_reg = b.resolve(extra.data.property);
    const value_reg = b.resolve(extra.data.value);
    const tag: Bytecode.Inst.Tag = if (strict)
        .set_super_property_computed_strict
    else
        .set_super_property_computed;
    try b.emit(.{
        .tag = tag,
        .data = .{ .reg_reg = .{
            property_reg,
            value_reg,
        } },
    });
    try b.emitMoveIfNeeded(extra.data.value, dest);
}

fn lowerPushPrivateScope(b: *Builder) Error!void {
    try b.emit(.{
        .tag = .push_private_scope,
        .data = .{ .none = {} },
    });
}

fn lowerPopPrivateScope(b: *Builder) Error!void {
    try b.emit(.{
        .tag = .pop_private_scope,
        .data = .{ .none = {} },
    });
}

fn lowerCreatePrivateElement(b: *Builder, name_index: Ir.StringIndex, dest: Ir.Inst.Ref) Error!void {
    const dest_reg = b.resolve(dest);
    const name_index_: Bytecode.StringIndex = @fromBackingInt(@backingInt(name_index));
    try b.emit(.{
        .tag = .create_private_element,
        .data = .{ .reg_string = .{
            dest_reg,
            name_index_,
        } },
    });
}

fn lowerResolvePrivateElement(b: *Builder, name_index: Ir.StringIndex, dest: Ir.Inst.Ref) Error!void {
    const dest_reg = b.resolve(dest);
    const name_index_: Bytecode.StringIndex = @fromBackingInt(@backingInt(name_index));
    try b.emit(.{
        .tag = .resolve_private_element,
        .data = .{ .reg_string = .{
            dest_reg,
            name_index_,
        } },
    });
}

fn lowerGetPrivateElement(b: *Builder, data: Ir.Inst.GetProperty, dest: Ir.Inst.Ref) Error!void {
    const dest_reg = b.resolve(dest);
    const base_reg = b.resolve(data.base);
    const name_index: Bytecode.StringIndex = @fromBackingInt(@backingInt(data.name));
    try b.emit(.{
        .tag = .get_private_element,
        .data = .{ .reg_reg_string = .{
            dest_reg,
            base_reg,
            name_index,
        } },
    });
}

fn lowerSetPrivateElement(b: *Builder, extra_index: Ir.ExtraIndex, dest: Ir.Inst.Ref) Error!void {
    const extra = b.ir.extraData(Ir.Inst.SetProperty, extra_index);
    const base_reg = b.resolve(extra.data.base);
    const name_index: Bytecode.StringIndex = @fromBackingInt(@backingInt(extra.data.name));
    const value_reg = b.resolve(extra.data.value);
    try b.emit(.{
        .tag = .set_private_element,
        .data = .{ .reg_string_reg = .{
            base_reg,
            name_index,
            value_reg,
        } },
    });
    try b.emitMoveIfNeeded(extra.data.value, dest);
}

fn lowerHasPrivateElement(b: *Builder, data: Ir.Inst.Binary, dest: Ir.Inst.Ref) Error!void {
    try b.emitBinaryOp(.has_private_element, data.lhs, data.rhs, dest);
}

fn lowerImportCall(b: *Builder, binary: Ir.Inst.Binary, dest: Ir.Inst.Ref) Error!void {
    const dest_reg = b.resolve(dest);
    const specifier_reg = b.resolve(binary.lhs);
    const options_reg = b.resolve(binary.rhs);
    try b.emit(.{
        .tag = .import_call,
        .data = .{ .reg_reg_reg = .{
            dest_reg,
            specifier_reg,
            options_reg,
        } },
    });
}

fn lowerGetImportMeta(b: *Builder, dest: Ir.Inst.Ref) Error!void {
    const dest_reg = b.resolve(dest);
    try b.emit(.{
        .tag = .get_import_meta,
        .data = .{ .reg = dest_reg },
    });
}

fn lowerAddDisposableResourceSync(b: *Builder, value: Ir.Inst.Ref) Error!void {
    const value_reg = b.resolve(value);
    try b.emit(.{
        .tag = .add_disposable_resource_sync,
        .data = .{ .reg = value_reg },
    });
}

fn lowerAddDisposableResourceAsync(b: *Builder, value: Ir.Inst.Ref) Error!void {
    const value_reg = b.resolve(value);
    try b.emit(.{
        .tag = .add_disposable_resource_async,
        .data = .{ .reg = value_reg },
    });
}

fn lowerDisposeResources(b: *Builder) Error!void {
    try b.emit(.{
        .tag = .dispose_resources,
        .data = .{ .none = {} },
    });
}
