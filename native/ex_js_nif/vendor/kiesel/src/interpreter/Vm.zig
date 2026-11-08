const std = @import("std");

const builtins = @import("../builtins.zig");
const execution = @import("../execution.zig");
const interpreter = @import("../interpreter.zig");
const language = @import("../language.zig");
const types = @import("../types.zig");
const utils = @import("../utils.zig");

const Agent = execution.Agent;
const BigInt = types.BigInt;
const Bytecode = interpreter.Bytecode;
const DisposableResource = types.DisposableResource;
const Iterator = types.Iterator;
const Object = types.Object;
const PrivateName = types.PrivateName;
const PropertyKey = types.PropertyKey;
const String = types.String;
const Value = types.Value;

const addDisposableResource = types.addDisposableResource;
const applyStringOrNumericBinaryOperator = language.runtime.applyStringOrNumericBinaryOperator;
const arrayCreateFast = builtins.arrayCreateFast;
const await = builtins.await;
const classDefinitionEvaluation = language.runtime.classDefinitionEvaluation;
const createArrayFromList = types.createArrayFromList;
const createForInIterator = builtins.createForInIterator;
const createMappedArgumentsObject = builtins.createMappedArgumentsObject;
const createUnmappedArgumentsObject = builtins.createUnmappedArgumentsObject;
const directEval = language.runtime.directEval;
const disposeResources = types.disposeResources;
const evaluateCall = language.runtime.evaluateCall;
const evaluateImportCall = language.runtime.evaluateImportCall;
const evaluateImportMeta = language.runtime.evaluateImportMeta;
const evaluateNew = language.runtime.evaluateNew;
const evaluateSuperCall = language.runtime.evaluateSuperCall;
const evaluateYieldStar = language.runtime.evaluateYieldStar;
const getIterator = types.getIterator;
const getIteratorDirect = types.getIteratorDirect;
const getTemplateObject = language.runtime.getTemplateObject;
const instantiateArrowFunctionExpression = language.runtime.instantiateArrowFunctionExpression;
const instantiateAsyncArrowFunctionExpression = language.runtime.instantiateAsyncArrowFunctionExpression;
const instantiateAsyncFunctionExpression = language.runtime.instantiateAsyncFunctionExpression;
const instantiateAsyncGeneratorFunctionExpression = language.runtime.instantiateAsyncGeneratorFunctionExpression;
const instantiateGeneratorFunctionExpression = language.runtime.instantiateGeneratorFunctionExpression;
const instantiateOrdinaryFunctionExpression = language.runtime.instantiateOrdinaryFunctionExpression;
const isLessThan = types.isLessThan;
const isLooselyEqual = types.isLooselyEqual;
const isStrictlyEqual = types.isStrictlyEqual;
const makeMethod = builtins.makeMethod;
const newDeclarativeEnvironment = execution.newDeclarativeEnvironment;
const newObjectEnvironment = execution.newObjectEnvironment;
const newPrivateEnvironment = execution.newPrivateEnvironment;
const noexcept = utils.noexcept;
const ordinaryObjectCreateFast = builtins.ordinaryObjectCreateFast;
const yield = builtins.yield;

const ic = @import("Vm/ic.zig");

const Vm = @This();

agent: *Agent,
stack: std.ArrayList(Value),
call_stack: std.ArrayList(CallFrame),
per_bytecode_cache: std.AutoHashMapUnmanaged(*const Bytecode, PerBytecodeCache),
frame: *CallFrame,
locals: []Value,
regs: []Value,
cache_slots: CacheSlots,
get_property_ics: []ic.GetProperty,
get_property_computed_ics: []ic.GetPropertyComputed,
set_property_ics: []ic.SetProperty,
set_property_computed_ics: []ic.SetPropertyComputed,

pub const Pc = enum(u32) {
    start = 0,
    _,

    pub fn offsetBy(pc: Pc, offset: i32) Pc {
        if (offset >= 0) {
            return @fromBackingInt(@backingInt(pc) + @as(u32, @intCast(offset)));
        } else {
            return @fromBackingInt(@backingInt(pc) - @as(u32, @intCast(-offset)));
        }
    }
};

pub const CallFrame = struct {
    bytecode: *const Bytecode,
    stack_base: u32,
    argument_count: u16,
    scope_depth: u16,

    pub fn stackLen(frame: *const CallFrame) usize {
        return 1 + frame.argument_count + frame.bytecode.local_count + frame.bytecode.register_count;
    }
};

pub const GeneratorSuspension = struct {
    stack: []Value,
    argument_count: u16,
    local_count: u16,
    scope_depth: u16,
    saved_pc: Pc,
    yield_reg: Bytecode.Reg,

    pub fn regs(suspension: *const GeneratorSuspension) []Value {
        const regs_start = 1 + suspension.argument_count + suspension.local_count;
        return suspension.stack[regs_start..];
    }
};

pub const RunResult = union(enum) {
    @"return": ?Value,
    yield: GeneratorSuspension,
};

pub const RunOptions = struct {
    start_pc: Pc = .start,
};

const cache_slots_align = @max(@alignOf(String), @alignOf(BigInt), @alignOf(Bytecode));
const CacheSlots = []?*align(cache_slots_align) const anyopaque;

const PerBytecodeCache = struct {
    cache_slots: CacheSlots,
    get_property_ics: []ic.GetProperty,
    get_property_computed_ics: []ic.GetPropertyComputed,
    set_property_ics: []ic.SetProperty,
    set_property_computed_ics: []ic.SetPropertyComputed,
};

pub fn init(
    agent: *Agent,
    bytecode: *const Bytecode,
) Agent.Error!Vm {
    var vm: Vm = .{
        .agent = agent,
        .stack = .empty,
        .call_stack = .empty,
        .per_bytecode_cache = .empty,
        .frame = undefined,
        .locals = undefined,
        .regs = undefined,
        .cache_slots = undefined,
        .get_property_ics = undefined,
        .get_property_computed_ics = undefined,
        .set_property_ics = undefined,
        .set_property_computed_ics = undefined,
    };
    try vm.pushCallFrame(bytecode, &.{});
    return vm;
}

pub fn deinit(vm: *Vm) void {
    std.debug.assert(vm.frame.stack_base == 0);
    std.debug.assert(vm.frame.argument_count == 0);
    std.debug.assert(vm.stack.items.len == vm.frame.stackLen());
    std.debug.assert(vm.call_stack.items.len == 1);
    vm.stack.deinit(vm.agent.gc_allocator);
    vm.call_stack.deinit(vm.agent.gc_allocator);

    var it = vm.per_bytecode_cache.iterator();
    while (it.next()) |entry| {
        // Values might outlive the VM and need to be GC'd, but we can free the array
        vm.agent.gc_allocator.free(entry.value_ptr.cache_slots);
        vm.agent.gc_allocator.free(entry.value_ptr.get_property_ics);
        vm.agent.gc_allocator.free(entry.value_ptr.get_property_computed_ics);
        vm.agent.gc_allocator.free(entry.value_ptr.set_property_ics);
        vm.agent.gc_allocator.free(entry.value_ptr.set_property_computed_ics);
    }
    vm.per_bytecode_cache.deinit(vm.agent.gc_allocator);
}

pub fn run(vm: *Vm, options: RunOptions) Agent.Error!RunResult {
    const previous_vm = vm.agent.active_vm;
    vm.agent.active_vm = vm;
    defer vm.agent.active_vm = previous_vm;

    // Caching the bytecode slice below depends on the call stack depth remaining the same within
    // one `run()` call, so we maintain the invariant that nested calls need their own `run()` call
    // and must not leave call frames behind. This is asserted after each instruction.
    const initial_call_stack_depth = vm.call_stack.items.len;

    var code = vm.frame.bytecode.code;
    var pc = options.start_pc;

    loop: switch (Bytecode.Inst.decodeTag(code[@backingInt(pc)..])) {
        inline else => |tag| {
            @setEvalBranchQuota(3_000);
            const data = Bytecode.Inst.decodeData(code[@backingInt(pc) + 1 ..], tag);
            const inst_size = comptime Bytecode.Inst.encodedSize(tag);
            const inst_pc = pc;
            pc = pc.offsetBy(inst_size);
            const maybe_error = switch (tag) {
                .jump => vm.executeJump(data.i32, &pc),
                .jump_if_true => vm.executeJumpIfTrue(data.reg_i32[0], data.reg_i32[1], &pc),
                .jump_if_false => vm.executeJumpIfFalse(data.reg_i32[0], data.reg_i32[1], &pc),
                .load_undefined => vm.executeLoadUndefined(data.reg),
                .load_null => vm.executeLoadNull(data.reg),
                .load_true => vm.executeLoadTrue(data.reg),
                .load_false => vm.executeLoadFalse(data.reg),
                .load_number_i8 => vm.executeLoadNumberI8(data.reg_i8[0], data.reg_i8[1]),
                .load_number_i32 => vm.executeLoadNumberI32(data.reg_i32[0], data.reg_i32[1]),
                .load_number_f64 => vm.executeLoadNumberF64(data.reg_f64[0], data.reg_f64[1]),
                .load_string => vm.executeLoadString(data.reg_string[0], data.reg_string[1]),
                .load_big_int => vm.executeLoadBigInt(data.reg_big_int[0], data.reg_big_int[1]),
                .move => vm.executeMove(data.reg_reg[0], data.reg_reg[1]),
                .create_array => vm.executeCreateArray(data.reg_u32[0], data.reg_u32[1]),
                .array_push => vm.executeArrayPush(data.reg_reg[0], data.reg_reg[1]),
                .array_push_hole => vm.executeArrayPushHole(data.reg),
                .array_set => vm.executeArraySet(data.reg_reg_u32[0], data.reg_reg_u32[1], data.reg_reg_u32[2]),
                .array_spread => vm.executeArraySpread(data.reg_reg[0], data.reg_reg[1]),
                .create_object => vm.executeCreateObject(data.reg_u32[0], data.reg_u32[1]),
                .object_set => vm.executeObjectSet(data.reg_string_reg[0], data.reg_string_reg[1], data.reg_string_reg[2]),
                .object_set_computed => vm.executeObjectSetComputed(data.reg_reg_reg[0], data.reg_reg_reg[1], data.reg_reg_reg[2]),
                .object_set_getter => vm.executeObjectSetGetter(data.reg_string_reg[0], data.reg_string_reg[1], data.reg_string_reg[2]),
                .object_set_getter_computed => vm.executeObjectSetGetterComputed(data.reg_reg_reg[0], data.reg_reg_reg[1], data.reg_reg_reg[2]),
                .object_set_setter => vm.executeObjectSetSetter(data.reg_string_reg[0], data.reg_string_reg[1], data.reg_string_reg[2]),
                .object_set_setter_computed => vm.executeObjectSetSetterComputed(data.reg_reg_reg[0], data.reg_reg_reg[1], data.reg_reg_reg[2]),
                .object_set_prototype => vm.executeObjectSetPrototype(data.reg_reg[0], data.reg_reg[1]),
                .object_spread => vm.executeObjectSpread(data.reg_reg[0], data.reg_reg[1]),
                .create_reg_exp => vm.executeCreateRegExp(data.reg_string_string[0], data.reg_string_string[1], data.reg_string_string[2]),
                .resolve_this_binding => vm.executeResolveThisBinding(data.reg),
                .to_boolean => vm.executeToBoolean(data.reg_reg[0], data.reg_reg[1]),
                .to_number => vm.executeToNumber(data.reg_reg[0], data.reg_reg[1]),
                .to_numeric => vm.executeToNumeric(data.reg_reg[0], data.reg_reg[1]),
                .to_string => vm.executeToString(data.reg_reg[0], data.reg_reg[1]),
                .to_object => vm.executeToObject(data.reg_reg[0], data.reg_reg[1]),
                .increment => vm.executeIncrement(data.reg_reg[0], data.reg_reg[1]),
                .decrement => vm.executeDecrement(data.reg_reg[0], data.reg_reg[1]),
                .negate => vm.executeNegate(data.reg_reg[0], data.reg_reg[1]),
                .bitwise_not => vm.executeBitwiseNot(data.reg_reg[0], data.reg_reg[1]),
                .logical_not => vm.executeLogicalNot(data.reg_reg[0], data.reg_reg[1]),
                .is_nullish => vm.executeIsNullish(data.reg_reg[0], data.reg_reg[1]),
                .typeof => vm.executeTypeof(data.reg_reg[0], data.reg_reg[1]),
                .typeof_local => vm.executeTypeofLocal(data.reg_local[0], data.reg_local[1]),
                .typeof_binding => vm.executeTypeofBinding(data.reg_string[0], data.reg_string[1]),
                .add => vm.executeAdd(data.reg_reg_reg[0], data.reg_reg_reg[1], data.reg_reg_reg[2]),
                .sub => vm.executeSub(data.reg_reg_reg[0], data.reg_reg_reg[1], data.reg_reg_reg[2]),
                .mul => vm.executeMul(data.reg_reg_reg[0], data.reg_reg_reg[1], data.reg_reg_reg[2]),
                .div => vm.executeDiv(data.reg_reg_reg[0], data.reg_reg_reg[1], data.reg_reg_reg[2]),
                .rem => vm.executeRem(data.reg_reg_reg[0], data.reg_reg_reg[1], data.reg_reg_reg[2]),
                .exp => vm.executeExp(data.reg_reg_reg[0], data.reg_reg_reg[1], data.reg_reg_reg[2]),
                .shift_left => vm.executeShiftLeft(data.reg_reg_reg[0], data.reg_reg_reg[1], data.reg_reg_reg[2]),
                .shift_right => vm.executeShiftRight(data.reg_reg_reg[0], data.reg_reg_reg[1], data.reg_reg_reg[2]),
                .shift_right_unsigned => vm.executeShiftRightUnsigned(data.reg_reg_reg[0], data.reg_reg_reg[1], data.reg_reg_reg[2]),
                .bitwise_and => vm.executeBitwiseAnd(data.reg_reg_reg[0], data.reg_reg_reg[1], data.reg_reg_reg[2]),
                .bitwise_or => vm.executeBitwiseOr(data.reg_reg_reg[0], data.reg_reg_reg[1], data.reg_reg_reg[2]),
                .bitwise_xor => vm.executeBitwiseXor(data.reg_reg_reg[0], data.reg_reg_reg[1], data.reg_reg_reg[2]),
                .lt => vm.executeLt(data.reg_reg_reg[0], data.reg_reg_reg[1], data.reg_reg_reg[2]),
                .gt => vm.executeGt(data.reg_reg_reg[0], data.reg_reg_reg[1], data.reg_reg_reg[2]),
                .lt_eq => vm.executeLtEq(data.reg_reg_reg[0], data.reg_reg_reg[1], data.reg_reg_reg[2]),
                .gt_eq => vm.executeGtEq(data.reg_reg_reg[0], data.reg_reg_reg[1], data.reg_reg_reg[2]),
                .instanceof => vm.executeInstanceOf(data.reg_reg_reg[0], data.reg_reg_reg[1], data.reg_reg_reg[2]),
                .in => vm.executeIn(data.reg_reg_reg[0], data.reg_reg_reg[1], data.reg_reg_reg[2]),
                .eq => vm.executeEq(data.reg_reg_reg[0], data.reg_reg_reg[1], data.reg_reg_reg[2]),
                .not_eq => vm.executeNotEq(data.reg_reg_reg[0], data.reg_reg_reg[1], data.reg_reg_reg[2]),
                .eq_strict => vm.executeEqStrict(data.reg_reg_reg[0], data.reg_reg_reg[1], data.reg_reg_reg[2]),
                .not_eq_strict => vm.executeNotEqStrict(data.reg_reg_reg[0], data.reg_reg_reg[1], data.reg_reg_reg[2]),
                .push_scope => vm.executePushScope(),
                .push_catch_scope => vm.executePushCatchScope(),
                .push_var_scope => vm.executePushVarScope(),
                .push_with_scope => vm.executePushWithScope(data.reg),
                .pop_scope => vm.executePopScope(),
                .create_var_binding => vm.executeCreateVarBinding(data.string),
                .create_mutable_binding => vm.executeCreateMutableBinding(data.string),
                .create_immutable_binding => vm.executeCreateImmutableBinding(data.string),
                .initialize_binding => vm.executeInitializeBinding(data.string_reg[0], data.string_reg[1]),
                .get_local => vm.executeGetLocal(data.reg_local[0], data.reg_local[1]),
                .get_binding => vm.executeGetBinding(data.reg_string[0], data.reg_string[1]),
                .get_property => vm.executeGetProperty(data.reg_reg_string_get_property_ic[0], data.reg_reg_string_get_property_ic[1], data.reg_reg_string_get_property_ic[2], data.reg_reg_string_get_property_ic[3]),
                .get_property_computed => vm.executeGetPropertyComputed(data.reg_reg_reg_get_property_computed_ic[0], data.reg_reg_reg_get_property_computed_ic[1], data.reg_reg_reg_get_property_computed_ic[2], data.reg_reg_reg_get_property_computed_ic[3]),
                .get_property_indexed => vm.executeGetPropertyIndexed(data.reg_reg_u32[0], data.reg_reg_u32[1], data.reg_reg_u32[2]),
                .set_local => vm.executeSetLocal(data.local_reg[0], data.local_reg[1]),
                .set_binding => vm.executeSetBinding(data.string_reg[0], data.string_reg[1], false),
                .set_binding_strict => vm.executeSetBinding(data.string_reg[0], data.string_reg[1], true),
                .set_property => vm.executeSetProperty(data.reg_reg_string_set_property_ic[0], data.reg_reg_string_set_property_ic[1], data.reg_reg_string_set_property_ic[2], data.reg_reg_string_set_property_ic[3], false),
                .set_property_strict => vm.executeSetProperty(data.reg_reg_string_set_property_ic[0], data.reg_reg_string_set_property_ic[1], data.reg_reg_string_set_property_ic[2], data.reg_reg_string_set_property_ic[3], true),
                .set_property_computed => vm.executeSetPropertyComputed(data.reg_reg_reg_set_property_computed_ic[0], data.reg_reg_reg_set_property_computed_ic[1], data.reg_reg_reg_set_property_computed_ic[2], data.reg_reg_reg_set_property_computed_ic[3], false),
                .set_property_computed_strict => vm.executeSetPropertyComputed(data.reg_reg_reg_set_property_computed_ic[0], data.reg_reg_reg_set_property_computed_ic[1], data.reg_reg_reg_set_property_computed_ic[2], data.reg_reg_reg_set_property_computed_ic[3], true),
                .set_property_indexed => vm.executeSetPropertyIndexed(data.reg_reg_u32[0], data.reg_reg_u32[1], data.reg_reg_u32[2], false),
                .set_property_indexed_strict => vm.executeSetPropertyIndexed(data.reg_reg_u32[0], data.reg_reg_u32[1], data.reg_reg_u32[2], true),
                .delete_binding => vm.executeDeleteBinding(data.reg_string[0], data.reg_string[1]),
                .delete_property => vm.executeDeleteProperty(data.reg_reg_string[0], data.reg_reg_string[1], data.reg_reg_string[2], false),
                .delete_property_strict => vm.executeDeleteProperty(data.reg_reg_string[0], data.reg_reg_string[1], data.reg_reg_string[2], true),
                .delete_property_computed => vm.executeDeletePropertyComputed(data.reg_reg_reg[0], data.reg_reg_reg[1], data.reg_reg_reg[2], false),
                .delete_property_computed_strict => vm.executeDeletePropertyComputed(data.reg_reg_reg[0], data.reg_reg_reg[1], data.reg_reg_reg[2], true),
                .delete_property_indexed => vm.executeDeletePropertyIndexed(data.reg_reg_u32[0], data.reg_reg_u32[1], data.reg_reg_u32[2], false),
                .delete_property_indexed_strict => vm.executeDeletePropertyIndexed(data.reg_reg_u32[0], data.reg_reg_u32[1], data.reg_reg_u32[2], true),
                .copy_data_properties => vm.executeCopyDataProperties(data.reg_reg_reg[0], data.reg_reg_reg[1], data.reg_reg_reg[2]),
                .call => vm.executeCall(data.reg_reg_reg[0], data.reg_reg_reg[1], data.reg_reg_reg[2]),
                .call0 => vm.executeCallN(0, data.reg_reg[0], data.reg_reg[1], .{}),
                .call1 => vm.executeCallN(1, data.reg_reg_reg[0], data.reg_reg_reg[1], .{data.reg_reg_reg[2]}),
                .call2 => vm.executeCallN(2, data.reg_reg_reg_reg[0], data.reg_reg_reg_reg[1], .{ data.reg_reg_reg_reg[2], data.reg_reg_reg_reg[3] }),
                .call_property => vm.executeCallProperty(data.reg_reg_reg_reg[0], data.reg_reg_reg_reg[1], data.reg_reg_reg_reg[2], data.reg_reg_reg_reg[3]),
                .call_property0 => vm.executeCallPropertyN(0, data.reg_reg_reg[0], data.reg_reg_reg[1], data.reg_reg_reg[2], .{}),
                .call_property1 => vm.executeCallPropertyN(1, data.reg_reg_reg_reg[0], data.reg_reg_reg_reg[1], data.reg_reg_reg_reg[2], .{data.reg_reg_reg_reg[3]}),
                .call_property2 => vm.executeCallPropertyN(2, data.reg_reg_reg_reg_reg[0], data.reg_reg_reg_reg_reg[1], data.reg_reg_reg_reg_reg[2], .{ data.reg_reg_reg_reg_reg[3], data.reg_reg_reg_reg_reg[4] }),
                .call_direct_eval => vm.executeCallDirectEval(data.reg_reg_reg[0], data.reg_reg_reg[1], data.reg_reg_reg[2], false),
                .call_direct_eval_strict => vm.executeCallDirectEval(data.reg_reg_reg[0], data.reg_reg_reg[1], data.reg_reg_reg[2], true),
                .construct => vm.executeConstruct(data.reg_reg_reg[0], data.reg_reg_reg[1], data.reg_reg_reg[2]),
                .construct0 => vm.executeConstructN(0, data.reg_reg[0], data.reg_reg[1], .{}),
                .construct1 => vm.executeConstructN(1, data.reg_reg_reg[0], data.reg_reg_reg[1], .{data.reg_reg_reg[2]}),
                .construct2 => vm.executeConstructN(2, data.reg_reg_reg_reg[0], data.reg_reg_reg_reg[1], .{ data.reg_reg_reg_reg[2], data.reg_reg_reg_reg[3] }),
                .get_template_object => vm.executeGetTemplateObject(data.reg_reg_reg_u16[0], data.reg_reg_reg_u16[1], data.reg_reg_reg_u16[2], data.reg_reg_reg_u16[3]),
                .get_iterator => vm.executeGetIterator(data.reg_reg[0], data.reg_reg[1]),
                .get_async_iterator => vm.executeGetAsyncIterator(data.reg_reg[0], data.reg_reg[1]),
                .get_for_in_iterator => vm.executeGetForInIterator(data.reg_reg[0], data.reg_reg[1]),
                .iterator_step => vm.executeIteratorStep(data.reg_reg[0], data.reg_reg[1]),
                .iterator_step_value => vm.executeIteratorStepValue(data.reg_reg[0], data.reg_reg[1]),
                .iterator_step_value_async => vm.executeIteratorStepValueAsync(data.reg_reg[0], data.reg_reg[1]),
                .iterator_close => vm.executeIteratorClose(data.reg),
                .iterator_is_done => vm.executeIteratorIsDone(data.reg_reg[0], data.reg_reg[1]),
                .iterator_collect => vm.executeIteratorCollect(data.reg_reg[0], data.reg_reg[1]),
                .throw => vm.executeThrow(data.reg),
                .throw_reference_error => vm.executeThrowReferenceError(),
                .@"return" => return vm.executeReturn(data.reg),
                .await => vm.executeAwait(data.reg_reg[0], data.reg_reg[1]),
                .yield => return vm.executeYield(data.reg_reg[0], data.reg_reg[1], pc),
                .yield_star => if (vm.executeYieldStar(data.reg_reg[0], data.reg_reg[1], inst_pc)) |maybe_result| if (maybe_result) |result| return result else {} else |err| err,
                .create_function => vm.executeCreateFunction(data.reg_function[0], data.reg_function[1]),
                .create_class => vm.executeCreateClass(data.reg_class[0], data.reg_class[1]),
                .set_home_object => vm.executeSetHomeObject(data.reg_reg[0], data.reg_reg[1]),
                .create_unmapped_arguments_object => vm.executeCreateUnmappedArgumentsObject(data.reg),
                .create_mapped_arguments_object => vm.executeCreateMappedArgumentsObject(data.reg),
                .get_argument => vm.executeGetArgument(data.reg_u16[0], data.reg_u16[1]),
                .get_rest_arguments => vm.executeGetRestArguments(data.reg_u16[0], data.reg_u16[1]),
                .get_new_target => vm.executeGetNewTarget(data.reg),
                .super_call => vm.executeSuperCall(data.reg_reg[0], data.reg_reg[1]),
                .get_super_property => vm.executeGetSuperProperty(data.reg_string[0], data.reg_string[1]),
                .get_super_property_computed => vm.executeGetSuperPropertyComputed(data.reg_reg[0], data.reg_reg[1]),
                .set_super_property => vm.executeSetSuperProperty(data.reg_string[0], data.reg_string[1], false),
                .set_super_property_strict => vm.executeSetSuperProperty(data.reg_string[0], data.reg_string[1], true),
                .set_super_property_computed => vm.executeSetSuperPropertyComputed(data.reg_reg[0], data.reg_reg[1], false),
                .set_super_property_computed_strict => vm.executeSetSuperPropertyComputed(data.reg_reg[0], data.reg_reg[1], true),
                .create_private_element => vm.executeCreatePrivateElement(data.reg_string[0], data.reg_string[1]),
                .resolve_private_element => vm.executeResolvePrivateElement(data.reg_string[0], data.reg_string[1]),
                .push_private_scope => vm.executePushPrivateScope(),
                .pop_private_scope => vm.executePopPrivateScope(),
                .get_private_element => vm.executeGetPrivateElement(data.reg_reg_string[0], data.reg_reg_string[1], data.reg_reg_string[2]),
                .set_private_element => vm.executeSetPrivateElement(data.reg_string_reg[0], data.reg_string_reg[1], data.reg_string_reg[2]),
                .has_private_element => vm.executeHasPrivateElement(data.reg_reg_reg[0], data.reg_reg_reg[1], data.reg_reg_reg[2]),
                .import_call => vm.executeImportCall(data.reg_reg_reg[0], data.reg_reg_reg[1], data.reg_reg_reg[2]),
                .get_import_meta => vm.executeGetImportMeta(data.reg),
                .add_disposable_resource_sync => vm.executeAddDisposableResource(data.reg, .sync_dispose),
                .add_disposable_resource_async => vm.executeAddDisposableResource(data.reg, .async_dispose),
                .dispose_resources => vm.executeDisposeResources(),
            };
            std.debug.assert(vm.call_stack.items.len == initial_call_stack_depth);
            switch (@typeInfo(@TypeOf(maybe_error))) {
                .void => {},
                .error_union => |u| {
                    comptime std.debug.assert(u.payload == void);
                    maybe_error catch |err| {
                        try @call(.never_inline, handleError, .{ vm, err, inst_pc, &pc });
                    };
                },
                else => comptime unreachable,
            }
            continue :loop Bytecode.Inst.decodeTag(code[@backingInt(pc)..]);
        },
    }
}

fn handleError(vm: *Vm, err: Agent.Error, inst_pc: Pc, pc: *Pc) Agent.Error!void {
    switch (err) {
        error.OutOfMemory => return err,
        error.ExceptionThrown => {
            const execution_context = vm.agent.runningExecutionContext();
            const maybe_handler = vm.frame.bytecode.findExceptionHandler(@backingInt(inst_pc));
            const target_scope_depth = if (maybe_handler) |handler| handler.scope_depth else 0;
            while (true) {
                const env = execution_context.ecmascript_code.lexical_environment;
                if (env.declarativeEnv()) |decl_env| dispose: {
                    if (decl_env.disposable_resource_stack.items.len == 0) break :dispose;
                    _ = disposeResources(
                        vm.agent,
                        &decl_env.disposable_resource_stack,
                        @as(Agent.Error!Value, err),
                    ) catch |e| switch (e) {
                        error.OutOfMemory => return error.OutOfMemory,
                        error.ExceptionThrown => {},
                    };
                }
                if (vm.frame.scope_depth == target_scope_depth) break;
                vm.frame.scope_depth -= 1;
                execution_context.ecmascript_code.lexical_environment = env.outerEnv().?;
            }
            const handler = maybe_handler orelse return err;
            const exception = vm.agent.clearException();
            vm.load(handler.exception_reg, exception.value);
            pc.* = @fromBackingInt(handler.target);
        },
    }
}

pub fn @"resume"(
    vm: *Vm,
    callee_bytecode: *const Bytecode,
    suspension: GeneratorSuspension,
) Agent.Error!RunResult {
    const cache = try vm.ensurePerBytecodeCache(callee_bytecode);

    const stack_base: u32 = @intCast(vm.stack.items.len);
    const argument_count = suspension.argument_count;
    const local_count = callee_bytecode.local_count;
    const register_count = callee_bytecode.register_count;

    std.debug.assert(suspension.stack.len == 1 + argument_count + local_count + register_count);
    try vm.stack.appendSlice(vm.agent.gc_allocator, suspension.stack);

    try vm.call_stack.append(vm.agent.gc_allocator, .{
        .bytecode = callee_bytecode,
        .stack_base = stack_base,
        .argument_count = argument_count,
        .scope_depth = suspension.scope_depth,
    });
    vm.updateCachedFields(cache);
    errdefer vm.popCallFrame();
    return vm.run(.{ .start_pc = suspension.saved_pc });
}

fn ensurePerBytecodeCache(vm: *Vm, bytecode: *const Bytecode) std.mem.Allocator.Error!PerBytecodeCache {
    const gop = try vm.per_bytecode_cache.getOrPut(vm.agent.gc_allocator, bytecode);
    if (!gop.found_existing) {
        const total_len = bytecode.strings.len + bytecode.big_ints.len + bytecode.functions.len;
        const Ptr = @typeInfo(CacheSlots).pointer.child;
        const cache_slots = try vm.agent.gc_allocator.alloc(Ptr, total_len);
        errdefer vm.agent.gc_allocator.free(cache_slots);
        @memset(cache_slots, null);
        const get_property_ics = try vm.agent.gc_allocator.alloc(ic.GetProperty, bytecode.get_property_ic_count);
        errdefer vm.agent.gc_allocator.free(get_property_ics);
        @memset(get_property_ics, .empty);
        const get_property_computed_ics = try vm.agent.gc_allocator.alloc(ic.GetPropertyComputed, bytecode.get_property_computed_ic_count);
        errdefer vm.agent.gc_allocator.free(get_property_computed_ics);
        @memset(get_property_computed_ics, .empty);
        const set_property_ics = try vm.agent.gc_allocator.alloc(ic.SetProperty, bytecode.set_property_ic_count);
        errdefer vm.agent.gc_allocator.free(set_property_ics);
        @memset(set_property_ics, .empty);
        const set_property_computed_ics = try vm.agent.gc_allocator.alloc(ic.SetPropertyComputed, bytecode.set_property_computed_ic_count);
        errdefer vm.agent.gc_allocator.free(set_property_computed_ics);
        @memset(set_property_computed_ics, .empty);
        gop.value_ptr.* = .{
            .cache_slots = cache_slots,
            .get_property_ics = get_property_ics,
            .get_property_computed_ics = get_property_computed_ics,
            .set_property_ics = set_property_ics,
            .set_property_computed_ics = set_property_computed_ics,
        };
    }
    return gop.value_ptr.*;
}

fn updateCachedFields(vm: *Vm, cache: PerBytecodeCache) void {
    const frame = vm.call_stack.lastPtr().?;
    const locals_start = frame.stack_base + 1 + frame.argument_count;
    const regs_start = locals_start + frame.bytecode.local_count;
    vm.frame = frame;
    vm.locals = vm.stack.items[locals_start..][0..frame.bytecode.local_count];
    vm.regs = vm.stack.items[regs_start..][0..frame.bytecode.register_count];
    vm.cache_slots = cache.cache_slots;
    vm.get_property_ics = cache.get_property_ics;
    vm.get_property_computed_ics = cache.get_property_computed_ics;
    vm.set_property_ics = cache.set_property_ics;
    vm.set_property_computed_ics = cache.set_property_computed_ics;
}

pub fn pushCallFrame(
    vm: *Vm,
    callee_bytecode: *const Bytecode,
    args: []const Value,
) std.mem.Allocator.Error!void {
    const cache = try vm.ensurePerBytecodeCache(callee_bytecode);

    const stack_base: u32 = @intCast(vm.stack.items.len);
    const argument_count: u16 = @intCast(args.len);
    const local_count = callee_bytecode.local_count;
    const register_count = callee_bytecode.register_count;

    const stack_len = 1 + argument_count + local_count + register_count;
    try vm.stack.ensureUnusedCapacity(vm.agent.gc_allocator, stack_len);
    vm.stack.appendAssumeCapacity(.uninitialized);
    vm.stack.appendSliceAssumeCapacity(args);
    // Locals usually start out as undefined anyway so we we avoid initialization via `set_local`.
    vm.stack.appendNTimesAssumeCapacity(.undefined, local_count);
    // Registers however are not valid to read before a write.
    vm.stack.appendNTimesAssumeCapacity(undefined, register_count);

    try vm.call_stack.append(vm.agent.gc_allocator, .{
        .bytecode = callee_bytecode,
        .stack_base = stack_base,
        .argument_count = argument_count,
        .scope_depth = 0,
    });
    vm.updateCachedFields(cache);
}

pub fn popCallFrame(vm: *Vm) void {
    std.debug.assert(vm.call_stack.items.len > 1);

    const stack_len = vm.frame.stackLen();
    vm.stack.shrinkRetainingCapacity(vm.stack.items.len - stack_len);
    _ = vm.call_stack.pop().?;

    const frame = vm.call_stack.lastPtr().?;
    const cache = vm.per_bytecode_cache.get(frame.bytecode).?;
    vm.updateCachedFields(cache);
}

fn arguments(vm: *Vm) []const Value {
    const args_start = vm.frame.stack_base + 1;
    return vm.stack.items[args_start..][0..vm.frame.argument_count];
}

fn store(vm: *Vm, reg: Bytecode.Reg) Value {
    std.debug.assert(reg != .none);
    return vm.regs[@backingInt(reg)];
}

fn load(vm: *Vm, reg: Bytecode.Reg, value: Value) void {
    std.debug.assert(reg != .none);
    vm.regs[@backingInt(reg)] = value;
}

fn getString(vm: *Vm, index: Bytecode.StringIndex) std.mem.Allocator.Error!*const String {
    const cache_index = @backingInt(index);
    if (vm.cache_slots[cache_index]) |ptr| {
        @branchHint(.likely);
        return @ptrCast(ptr);
    }
    const wtf8 = index.slice(vm.frame.bytecode);
    const string = try String.fromWtf8(vm.agent, try vm.agent.gc_allocator.dupe(u8, wtf8));
    vm.cache_slots[cache_index] = @ptrCast(@alignCast(string));
    return string;
}

fn getBigInt(vm: *Vm, index: Bytecode.BigIntIndex) std.mem.Allocator.Error!*const BigInt {
    const cache_index = vm.frame.bytecode.strings.len + @backingInt(index);
    if (vm.cache_slots[cache_index]) |ptr| {
        @branchHint(.likely);
        return @ptrCast(ptr);
    }
    const @"const" = index.value(vm.frame.bytecode);
    const managed = try @"const".toManaged(vm.agent.gc_allocator);
    const big_int = try BigInt.fromManaged(vm.agent, managed);
    vm.cache_slots[cache_index] = @ptrCast(@alignCast(big_int));
    return big_int;
}

fn getFunction(vm: *Vm, index: Bytecode.Function.Index) *const Bytecode.Function {
    return index.ptr(vm.frame.bytecode);
}

fn getClass(vm: *Vm, index: Bytecode.Class.Index) *const Bytecode.Class {
    return index.ptr(vm.frame.bytecode);
}

fn Ic(comptime IcIndex: type) type {
    return switch (IcIndex) {
        Bytecode.GetPropertyIcIndex => ic.GetProperty,
        Bytecode.GetPropertyComputedIcIndex => ic.GetPropertyComputed,
        Bytecode.SetPropertyIcIndex => ic.SetProperty,
        Bytecode.SetPropertyComputedIcIndex => ic.SetPropertyComputed,
        else => comptime unreachable,
    };
}

fn getIc(vm: *Vm, index: anytype) *Ic(@TypeOf(index)) {
    return switch (@TypeOf(index)) {
        Bytecode.GetPropertyIcIndex => &vm.get_property_ics[@backingInt(index)],
        Bytecode.GetPropertyComputedIcIndex => &vm.get_property_computed_ics[@backingInt(index)],
        Bytecode.SetPropertyIcIndex => &vm.set_property_ics[@backingInt(index)],
        Bytecode.SetPropertyComputedIcIndex => &vm.set_property_computed_ics[@backingInt(index)],
        else => comptime unreachable,
    };
}

fn toObjectForPropertyAccess(agent: *Agent, value: Value) Agent.Error!*Object {
    if (value.isObject()) {
        @branchHint(.likely);
        return value.asObject();
    }
    if (value.isString()) {
        // TODO: Optimize 'length' property access on strings, for now everything goes through the
        //       custom [[GetOwnProperty]] implementation
        return value.toObject(agent);
    }
    return try value.synthesizePrototype(agent) orelse {
        // Null or undefined, guaranteed to throw
        _ = try value.toObject(agent);
        unreachable;
    };
}

fn iteratorToObject(agent: *Agent, iterator: Iterator) std.mem.Allocator.Error!*Object {
    const iterator_obj = &(try builtins.Object.createWithShape(agent, .{
        .shape = try agent.ensureIteratorRecordShape(),
    })).object;
    iterator_obj.setValueAtPropertyOffset(@fromBackingInt(0), Value.from(iterator.iterator));
    iterator_obj.setValueAtPropertyOffset(@fromBackingInt(1), iterator.next_method);
    iterator_obj.setValueAtPropertyOffset(@fromBackingInt(2), Value.from(iterator.done));
    return iterator_obj;
}

fn objectToIterator(iterator_obj: *const Object) Iterator {
    return .{
        .iterator = iterator_obj.getValueAtPropertyOffset(@fromBackingInt(0)).asObject(),
        .next_method = iterator_obj.getValueAtPropertyOffset(@fromBackingInt(1)),
        .done = iterator_obj.getValueAtPropertyOffset(@fromBackingInt(2)).toBoolean(),
    };
}

fn argsArrayToList(
    gpa: std.mem.Allocator,
    args_array: *const builtins.Array,
) std.mem.Allocator.Error!std.ArrayList(Value) {
    const args_len = args_array.fields.length;

    var args_list: std.ArrayList(Value) = try .initCapacity(gpa, args_len);
    errdefer comptime unreachable;

    const extra_data = args_array.object.extra_data orelse {
        std.debug.assert(args_len == 0);
        return args_list;
    };
    std.debug.assert(args_len == extra_data.indexed_properties.count());

    switch (extra_data.indexed_properties.storage) {
        .dense_i32 => |dense_i32| for (dense_i32.items) |value| {
            args_list.appendAssumeCapacity(Value.from(value));
        },
        .dense_f64 => |dense_f64| for (dense_f64.items) |value| {
            args_list.appendAssumeCapacity(Value.from(value));
        },
        .dense_value => |dense_value| args_list.appendSliceAssumeCapacity(dense_value.items),
        // Bytecode lowering only emits dense argument arrays
        .none, .sparse_value, .sparse_property_descriptor => unreachable,
    }

    return args_list;
}

fn executeJump(_: *Vm, offset: i32, pc: *Pc) void {
    pc.* = pc.offsetBy(offset);
}

fn executeJumpIfTrue(vm: *Vm, reg: Bytecode.Reg, offset: i32, pc: *Pc) void {
    if (vm.store(reg).asBoolean()) {
        pc.* = pc.offsetBy(offset);
    }
}

fn executeJumpIfFalse(vm: *Vm, reg: Bytecode.Reg, offset: i32, pc: *Pc) void {
    if (!vm.store(reg).asBoolean()) {
        pc.* = pc.offsetBy(offset);
    }
}

fn executeLoadUndefined(vm: *Vm, reg: Bytecode.Reg) void {
    vm.load(reg, .undefined);
}

fn executeLoadNull(vm: *Vm, reg: Bytecode.Reg) void {
    vm.load(reg, .null);
}

fn executeLoadTrue(vm: *Vm, reg: Bytecode.Reg) void {
    vm.load(reg, .true);
}

fn executeLoadFalse(vm: *Vm, reg: Bytecode.Reg) void {
    vm.load(reg, .false);
}

fn executeLoadNumberI8(vm: *Vm, reg: Bytecode.Reg, value: i8) void {
    vm.load(reg, Value.from(value));
}

fn executeLoadNumberI32(vm: *Vm, reg: Bytecode.Reg, value: i32) void {
    vm.load(reg, Value.from(value));
}

fn executeLoadNumberF64(vm: *Vm, reg: Bytecode.Reg, value: f64) void {
    vm.load(reg, Value.from(value));
}

fn executeLoadString(vm: *Vm, reg: Bytecode.Reg, index: Bytecode.StringIndex) std.mem.Allocator.Error!void {
    const string = try vm.getString(index);
    vm.load(reg, Value.from(string));
}

fn executeLoadBigInt(vm: *Vm, reg: Bytecode.Reg, index: Bytecode.BigIntIndex) std.mem.Allocator.Error!void {
    const big_int = try vm.getBigInt(index);
    vm.load(reg, Value.from(big_int));
}

fn executeMove(vm: *Vm, dest: Bytecode.Reg, src: Bytecode.Reg) void {
    vm.load(dest, vm.store(src));
}

fn executeCreateArray(vm: *Vm, dst: Bytecode.Reg, length: u32) std.mem.Allocator.Error!void {
    const array = try arrayCreateFast(vm.agent, length);
    vm.load(dst, Value.from(&array.object));
}

fn executeArrayPush(vm: *Vm, array_reg: Bytecode.Reg, elem_reg: Bytecode.Reg) std.mem.Allocator.Error!void {
    const array_value = vm.store(array_reg);
    const elem_value = vm.store(elem_reg);
    const array = array_value.asObject().as(builtins.Array);
    const index = array.fields.length;
    try array.object.createDataPropertyDirect(
        vm.agent,
        PropertyKey.from(@as(PropertyKey.IntegerIndex, index)),
        elem_value,
    );
}

fn executeArrayPushHole(vm: *Vm, array_reg: Bytecode.Reg) void {
    const array_value = vm.store(array_reg);
    const array = array_value.asObject().as(builtins.Array);
    array.fields.length += 1;
}

fn executeArraySet(vm: *Vm, array_reg: Bytecode.Reg, elem_reg: Bytecode.Reg, index: u32) std.mem.Allocator.Error!void {
    const array_value = vm.store(array_reg);
    const elem_value = vm.store(elem_reg);
    const array = array_value.asObject().as(builtins.Array);
    const indexed_properties = try array.object.ensureIndexedProperties(vm.agent.gc_allocator);
    try indexed_properties.set(vm.agent.gc_allocator, index, .{
        .value_or_accessor = .{ .value = elem_value },
        .attributes = .all,
    });
}

fn executeArraySpread(vm: *Vm, array_reg: Bytecode.Reg, value_reg: Bytecode.Reg) Agent.Error!void {
    const array_value = vm.store(array_reg);
    const spread_value = vm.store(value_reg);
    const array = array_value.asObject();
    var iterator = try getIterator(vm.agent, spread_value, .sync);
    var next_index: u53 = array.as(builtins.Array).fields.length;
    while (try iterator.stepValue(vm.agent)) |next| : (next_index += 1) {
        try array.createDataPropertyDirect(vm.agent, PropertyKey.from(next_index), next);
    }
}

fn executeCreateObject(vm: *Vm, dst: Bytecode.Reg, property_count: u32) std.mem.Allocator.Error!void {
    const object = try ordinaryObjectCreateFast(vm.agent);
    try object.ensureProperties(vm.agent.gc_allocator, property_count);
    vm.load(dst, Value.from(object));
}

fn executeObjectSet(vm: *Vm, object_reg: Bytecode.Reg, key_index: Bytecode.StringIndex, value_reg: Bytecode.Reg) std.mem.Allocator.Error!void {
    const object = vm.store(object_reg).asObject();
    const property_key = PropertyKey.from(try vm.getString(key_index));
    const property_value = vm.store(value_reg);
    try object.createDataPropertyDirect(vm.agent, property_key, property_value);
}

fn executeObjectSetComputed(vm: *Vm, object_reg: Bytecode.Reg, key_reg: Bytecode.Reg, value_reg: Bytecode.Reg) Agent.Error!void {
    const object = vm.store(object_reg).asObject();
    const property_key = try vm.store(key_reg).toPropertyKey(vm.agent);
    const property_value = vm.store(value_reg);
    try object.createDataPropertyDirect(vm.agent, property_key, property_value);
}

fn executeObjectSetGetter(vm: *Vm, object_reg: Bytecode.Reg, key_index: Bytecode.StringIndex, func_reg: Bytecode.Reg) Agent.Error!void {
    const object = vm.store(object_reg).asObject();
    const property_key = PropertyKey.from(try vm.getString(key_index));
    const function = vm.store(func_reg).asObject();
    try object.definePropertyOrThrow(vm.agent, property_key, .{ .getter = function, .enumerable = true, .configurable = true });
}

fn executeObjectSetGetterComputed(vm: *Vm, object_reg: Bytecode.Reg, key_reg: Bytecode.Reg, func_reg: Bytecode.Reg) Agent.Error!void {
    const object = vm.store(object_reg).asObject();
    const property_key = try vm.store(key_reg).toPropertyKey(vm.agent);
    const function = vm.store(func_reg).asObject();
    try object.definePropertyOrThrow(vm.agent, property_key, .{ .getter = function, .enumerable = true, .configurable = true });
}

fn executeObjectSetSetter(vm: *Vm, object_reg: Bytecode.Reg, key_index: Bytecode.StringIndex, func_reg: Bytecode.Reg) Agent.Error!void {
    const object = vm.store(object_reg).asObject();
    const property_key = PropertyKey.from(try vm.getString(key_index));
    const function = vm.store(func_reg).asObject();
    try object.definePropertyOrThrow(vm.agent, property_key, .{ .setter = function, .enumerable = true, .configurable = true });
}

fn executeObjectSetSetterComputed(vm: *Vm, object_reg: Bytecode.Reg, key_reg: Bytecode.Reg, func_reg: Bytecode.Reg) Agent.Error!void {
    const object = vm.store(object_reg).asObject();
    const property_key = try vm.store(key_reg).toPropertyKey(vm.agent);
    const function = vm.store(func_reg).asObject();
    try object.definePropertyOrThrow(vm.agent, property_key, .{ .setter = function, .enumerable = true, .configurable = true });
}

fn executeObjectSetPrototype(vm: *Vm, object_reg: Bytecode.Reg, value_reg: Bytecode.Reg) std.mem.Allocator.Error!void {
    const object = vm.store(object_reg).asObject();
    const proto = vm.store(value_reg);

    if (proto.isObject() or proto.isNull()) {
        std.debug.assert(object.internalMethods().flags.contains(.ordinary_set_prototype_of));
        try object.setPrototype(vm.agent, if (proto.isObject()) proto.asObject() else null);
    }
}

fn executeObjectSpread(vm: *Vm, object_reg: Bytecode.Reg, value_reg: Bytecode.Reg) Agent.Error!void {
    const object = vm.store(object_reg).asObject();
    const spread_value = vm.store(value_reg);
    const excluded_items: []const PropertyKey = &.{};
    try object.copyDataProperties(vm.agent, spread_value, excluded_items);
}

fn executeCreateRegExp(vm: *Vm, dst: Bytecode.Reg, pattern_index: Bytecode.StringIndex, flags_index: Bytecode.StringIndex) Agent.Error!void {
    const pattern = try vm.getString(pattern_index);
    const flags = try vm.getString(flags_index);
    const reg_exp = try builtins.regExpCreateFast(vm.agent, pattern, flags);
    vm.load(dst, Value.from(&reg_exp.object));
}

fn executeResolveThisBinding(vm: *Vm, reg: Bytecode.Reg) Agent.Error!void {
    const cached_this_value = &vm.stack.items[vm.frame.stack_base];
    if (cached_this_value.isUninitialized()) {
        @branchHint(.unlikely);
        cached_this_value.* = try vm.agent.resolveThisBinding();
    }
    vm.load(reg, cached_this_value.*);
}

fn executeToBoolean(vm: *Vm, dst: Bytecode.Reg, src: Bytecode.Reg) void {
    const value = vm.store(src);
    vm.load(dst, Value.from(value.toBoolean()));
}

fn executeToNumber(vm: *Vm, dst: Bytecode.Reg, src: Bytecode.Reg) Agent.Error!void {
    const value = vm.store(src);
    const number = try value.toNumber(vm.agent);
    vm.load(dst, Value.from(number));
}

fn executeToNumeric(vm: *Vm, dst: Bytecode.Reg, src: Bytecode.Reg) Agent.Error!void {
    const value = vm.store(src);
    const numeric = try value.toNumeric(vm.agent);
    vm.load(dst, switch (numeric) {
        .number => |number| Value.from(number),
        .big_int => |big_int| Value.from(big_int),
    });
}

fn executeToString(vm: *Vm, dst: Bytecode.Reg, src: Bytecode.Reg) Agent.Error!void {
    const value = vm.store(src);
    const string = try value.toString(vm.agent);
    vm.load(dst, Value.from(string));
}

fn executeToObject(vm: *Vm, dst: Bytecode.Reg, src: Bytecode.Reg) Agent.Error!void {
    const value = vm.store(src);
    const object = try value.toObject(vm.agent);
    vm.load(dst, Value.from(object));
}

fn executeIncrement(vm: *Vm, dst: Bytecode.Reg, src: Bytecode.Reg) Agent.Error!void {
    const value = vm.store(src);
    const new_value = switch (value.type()) {
        .number => Value.from(value.asNumber().add(.{ .i32 = 1 })),
        .big_int => Value.from(try value.asBigInt().add(vm.agent, .one)),
        else => unreachable,
    };
    vm.load(dst, new_value);
}

fn executeDecrement(vm: *Vm, dst: Bytecode.Reg, src: Bytecode.Reg) Agent.Error!void {
    const value = vm.store(src);
    const new_value = switch (value.type()) {
        .number => Value.from(value.asNumber().subtract(.{ .i32 = 1 })),
        .big_int => Value.from(try value.asBigInt().subtract(vm.agent, .one)),
        else => unreachable,
    };
    vm.load(dst, new_value);
}

fn executeNegate(vm: *Vm, dst: Bytecode.Reg, src: Bytecode.Reg) Agent.Error!void {
    const value = vm.store(src);

    // OPTIMIZATION: Fast path for number values
    if (value.isNumber()) {
        @branchHint(.likely);
        if (value.__isI32()) {
            const i = value.__asI32();
            if (i != 0 and i != std.math.minInt(i32)) {
                vm.load(dst, Value.from(-i));
                return;
            }
        }
        vm.load(dst, Value.from(-value.__toF64()));
        return;
    }

    const numeric = try value.toNumeric(vm.agent);
    vm.load(dst, switch (numeric) {
        .number => |n| Value.from(n.unaryMinus()),
        .big_int => |b| Value.from(try b.unaryMinus(vm.agent)),
    });
}

fn executeBitwiseNot(vm: *Vm, dst: Bytecode.Reg, src: Bytecode.Reg) Agent.Error!void {
    const value = vm.store(src);

    // OPTIMIZATION: Fast path for i32 values
    if (value.__isI32()) {
        @branchHint(.likely);
        vm.load(dst, Value.from(~value.__asI32()));
        return;
    }

    const numeric = try value.toNumeric(vm.agent);
    vm.load(dst, switch (numeric) {
        .number => |n| Value.from(n.bitwiseNOT()),
        .big_int => |b| Value.from(try b.bitwiseNOT(vm.agent)),
    });
}

fn executeLogicalNot(vm: *Vm, dst: Bytecode.Reg, src: Bytecode.Reg) void {
    const value = vm.store(src);
    vm.load(dst, Value.from(!value.toBoolean()));
}

fn executeIsNullish(vm: *Vm, dst: Bytecode.Reg, src: Bytecode.Reg) void {
    const value = vm.store(src);
    vm.load(dst, Value.from(value.isNull() or value.isUndefined()));
}

fn executeTypeof(vm: *Vm, dst: Bytecode.Reg, src: Bytecode.Reg) void {
    const value = vm.store(src);
    vm.load(dst, Value.from(value.typeof()));
}

fn executeTypeofLocal(vm: *Vm, dst: Bytecode.Reg, local: Bytecode.Local) void {
    const value = vm.locals[@backingInt(local)];
    vm.load(dst, Value.from(value.typeof()));
}

fn executeTypeofBinding(vm: *Vm, dst: Bytecode.Reg, name_index: Bytecode.StringIndex) Agent.Error!void {
    const name = try vm.getString(name_index);

    const execution_context = vm.agent.runningExecutionContext();
    var env = execution_context.ecmascript_code.lexical_environment;
    while (true) {
        if (try env.getBindingValueIfExists(vm.agent, name, true)) |value| {
            vm.load(dst, Value.from(value.typeof()));
            return;
        }
        env = env.outerEnv() orelse {
            @branchHint(.unlikely);
            vm.load(dst, Value.from("undefined"));
            return;
        };
    }
}

fn executeAdd(vm: *Vm, dst: Bytecode.Reg, lhs: Bytecode.Reg, rhs: Bytecode.Reg) Agent.Error!void {
    const lhs_value = vm.store(lhs);
    const rhs_value = vm.store(rhs);

    // OPTIMIZATION: Fast path for number values
    if (lhs_value.isNumber() and rhs_value.isNumber()) {
        @branchHint(.likely);
        if (lhs_value.__isI32() and rhs_value.__isI32()) {
            if (std.math.add(i32, lhs_value.__asI32(), rhs_value.__asI32())) |result| {
                vm.load(dst, Value.from(result));
                return;
            } else |_| {}
        }
        vm.load(dst, Value.from(lhs_value.__toF64() + rhs_value.__toF64()));
        return;
    }

    // OPTIMIZATION: Fast path for string values
    if (lhs_value.isString() and rhs_value.isString()) {
        vm.load(dst, Value.from(
            try String.concat(vm.agent, &.{ lhs_value.asString(), rhs_value.asString() }),
        ));
        return;
    }

    const result = try applyStringOrNumericBinaryOperator(vm.agent, lhs_value, .@"+", rhs_value);
    vm.load(dst, result);
}

fn executeSub(vm: *Vm, dst: Bytecode.Reg, lhs: Bytecode.Reg, rhs: Bytecode.Reg) Agent.Error!void {
    const lhs_value = vm.store(lhs);
    const rhs_value = vm.store(rhs);

    // OPTIMIZATION: Fast path for number values
    if (lhs_value.isNumber() and rhs_value.isNumber()) {
        @branchHint(.likely);
        if (lhs_value.__isI32() and rhs_value.__isI32()) {
            if (std.math.sub(i32, lhs_value.__asI32(), rhs_value.__asI32())) |result| {
                vm.load(dst, Value.from(result));
                return;
            } else |_| {}
        }
        vm.load(dst, Value.from(lhs_value.__toF64() - rhs_value.__toF64()));
        return;
    }

    const result = try applyStringOrNumericBinaryOperator(vm.agent, lhs_value, .@"-", rhs_value);
    vm.load(dst, result);
}

fn executeMul(vm: *Vm, dst: Bytecode.Reg, lhs: Bytecode.Reg, rhs: Bytecode.Reg) Agent.Error!void {
    const lhs_value = vm.store(lhs);
    const rhs_value = vm.store(rhs);

    // OPTIMIZATION: Fast path for number values
    if (lhs_value.isNumber() and rhs_value.isNumber()) {
        @branchHint(.likely);
        if (lhs_value.__isI32() and rhs_value.__isI32()) {
            if (std.math.mul(i32, lhs_value.__asI32(), rhs_value.__asI32())) |result| {
                vm.load(dst, Value.from(result));
                return;
            } else |_| {}
        }
        vm.load(dst, Value.from(lhs_value.__toF64() * rhs_value.__toF64()));
        return;
    }

    const result = try applyStringOrNumericBinaryOperator(vm.agent, lhs_value, .@"*", rhs_value);
    vm.load(dst, result);
}

fn executeDiv(vm: *Vm, dst: Bytecode.Reg, lhs: Bytecode.Reg, rhs: Bytecode.Reg) Agent.Error!void {
    const lhs_value = vm.store(lhs);
    const rhs_value = vm.store(rhs);

    // OPTIMIZATION: Fast path for number values
    if (lhs_value.isNumber() and rhs_value.isNumber()) {
        @branchHint(.likely);
        vm.load(dst, Value.from(lhs_value.__toF64() / rhs_value.__toF64()));
        return;
    }

    const result = try applyStringOrNumericBinaryOperator(vm.agent, lhs_value, .@"/", rhs_value);
    vm.load(dst, result);
}

fn executeRem(vm: *Vm, dst: Bytecode.Reg, lhs: Bytecode.Reg, rhs: Bytecode.Reg) Agent.Error!void {
    const lhs_value = vm.store(lhs);
    const rhs_value = vm.store(rhs);

    // OPTIMIZATION: Fast path for number values
    if (lhs_value.isNumber() and rhs_value.isNumber()) {
        @branchHint(.likely);
        if (lhs_value.__isI32() and rhs_value.__isI32()) {
            if (std.math.rem(i32, lhs_value.__asI32(), rhs_value.__asI32())) |result| {
                vm.load(dst, if (result == 0 and lhs_value.__asI32() < 0)
                    Value.from(-0.0)
                else
                    Value.from(result));
                return;
            } else |_| {}
        }
        vm.load(dst, Value.from(lhs_value.asNumber().remainder(rhs_value.asNumber())));
        return;
    }

    const result = try applyStringOrNumericBinaryOperator(vm.agent, lhs_value, .@"%", rhs_value);
    vm.load(dst, result);
}

fn executeExp(vm: *Vm, dst: Bytecode.Reg, lhs: Bytecode.Reg, rhs: Bytecode.Reg) Agent.Error!void {
    const lhs_value = vm.store(lhs);
    const rhs_value = vm.store(rhs);

    // OPTIMIZATION: Fast path for number values
    if (lhs_value.isNumber() and rhs_value.isNumber()) {
        @branchHint(.likely);
        if (lhs_value.__isI32() and rhs_value.__isI32()) {
            if (std.math.powi(i32, lhs_value.__asI32(), rhs_value.__asI32())) |result| {
                vm.load(dst, Value.from(result));
                return;
            } else |_| {}
        }
        vm.load(dst, Value.from(lhs_value.asNumber().exponentiate(rhs_value.asNumber())));
        return;
    }

    const result = try applyStringOrNumericBinaryOperator(vm.agent, lhs_value, .@"**", rhs_value);
    vm.load(dst, result);
}

fn executeShiftLeft(vm: *Vm, dst: Bytecode.Reg, lhs: Bytecode.Reg, rhs: Bytecode.Reg) Agent.Error!void {
    const lhs_value = vm.store(lhs);
    const rhs_value = vm.store(rhs);

    // OPTIMIZATION: Fast path for i32 values
    if (lhs_value.__isI32() and rhs_value.__isI32()) {
        @branchHint(.likely);
        const shift_count: u5 = @intCast(@mod(@as(u32, @bitCast(rhs_value.__asI32())), 32));
        vm.load(dst, Value.from(lhs_value.__asI32() << shift_count));
        return;
    }

    const result = try applyStringOrNumericBinaryOperator(vm.agent, lhs_value, .@"<<", rhs_value);
    vm.load(dst, result);
}

fn executeShiftRight(vm: *Vm, dst: Bytecode.Reg, lhs: Bytecode.Reg, rhs: Bytecode.Reg) Agent.Error!void {
    const lhs_value = vm.store(lhs);
    const rhs_value = vm.store(rhs);

    // OPTIMIZATION: Fast path for i32 values
    if (lhs_value.__isI32() and rhs_value.__isI32()) {
        @branchHint(.likely);
        const shift_count: u5 = @intCast(@mod(@as(u32, @bitCast(rhs_value.__asI32())), 32));
        vm.load(dst, Value.from(lhs_value.__asI32() >> shift_count));
        return;
    }

    const result = try applyStringOrNumericBinaryOperator(vm.agent, lhs_value, .@">>", rhs_value);
    vm.load(dst, result);
}

fn executeShiftRightUnsigned(vm: *Vm, dst: Bytecode.Reg, lhs: Bytecode.Reg, rhs: Bytecode.Reg) Agent.Error!void {
    const lhs_value = vm.store(lhs);
    const rhs_value = vm.store(rhs);

    // OPTIMIZATION: Fast path for i32 values
    if (lhs_value.__isI32() and rhs_value.__isI32()) {
        @branchHint(.likely);
        const shift_count: u5 = @intCast(@mod(@as(u32, @bitCast(rhs_value.__asI32())), 32));
        vm.load(dst, Value.from(@as(u32, @bitCast(lhs_value.__asI32())) >> shift_count));
        return;
    }

    const result = try applyStringOrNumericBinaryOperator(vm.agent, lhs_value, .@">>>", rhs_value);
    vm.load(dst, result);
}

fn executeBitwiseAnd(vm: *Vm, dst: Bytecode.Reg, lhs: Bytecode.Reg, rhs: Bytecode.Reg) Agent.Error!void {
    const lhs_value = vm.store(lhs);
    const rhs_value = vm.store(rhs);

    // OPTIMIZATION: Fast path for i32 values
    if (lhs_value.__isI32() and rhs_value.__isI32()) {
        @branchHint(.likely);
        vm.load(dst, Value.from(lhs_value.__asI32() & rhs_value.__asI32()));
        return;
    }

    const result = try applyStringOrNumericBinaryOperator(vm.agent, lhs_value, .@"&", rhs_value);
    vm.load(dst, result);
}

fn executeBitwiseOr(vm: *Vm, dst: Bytecode.Reg, lhs: Bytecode.Reg, rhs: Bytecode.Reg) Agent.Error!void {
    const lhs_value = vm.store(lhs);
    const rhs_value = vm.store(rhs);

    // OPTIMIZATION: Fast path for i32 values
    if (lhs_value.__isI32() and rhs_value.__isI32()) {
        @branchHint(.likely);
        vm.load(dst, Value.from(lhs_value.__asI32() | rhs_value.__asI32()));
        return;
    }

    const result = try applyStringOrNumericBinaryOperator(vm.agent, lhs_value, .@"|", rhs_value);
    vm.load(dst, result);
}

fn executeBitwiseXor(vm: *Vm, dst: Bytecode.Reg, lhs: Bytecode.Reg, rhs: Bytecode.Reg) Agent.Error!void {
    const lhs_value = vm.store(lhs);
    const rhs_value = vm.store(rhs);

    // OPTIMIZATION: Fast path for i32 values
    if (lhs_value.__isI32() and rhs_value.__isI32()) {
        @branchHint(.likely);
        vm.load(dst, Value.from(lhs_value.__asI32() ^ rhs_value.__asI32()));
        return;
    }

    const result = try applyStringOrNumericBinaryOperator(vm.agent, lhs_value, .@"^", rhs_value);
    vm.load(dst, result);
}

fn executeLt(vm: *Vm, dst: Bytecode.Reg, lhs: Bytecode.Reg, rhs: Bytecode.Reg) Agent.Error!void {
    const lhs_value = vm.store(lhs);
    const rhs_value = vm.store(rhs);

    // OPTIMIZATION: Fast path for number values
    if (lhs_value.isNumber() and rhs_value.isNumber()) {
        @branchHint(.likely);
        if (lhs_value.__isI32() and rhs_value.__isI32()) {
            vm.load(dst, Value.from(lhs_value.__asI32() < rhs_value.__asI32()));
        } else {
            vm.load(dst, Value.from(lhs_value.__toF64() < rhs_value.__toF64()));
        }
        return;
    }

    const result = try isLessThan(vm.agent, lhs_value, rhs_value, .left_first);
    vm.load(dst, Value.from(result orelse false));
}

fn executeGt(vm: *Vm, dst: Bytecode.Reg, lhs: Bytecode.Reg, rhs: Bytecode.Reg) Agent.Error!void {
    const lhs_value = vm.store(lhs);
    const rhs_value = vm.store(rhs);

    // OPTIMIZATION: Fast path for number values
    if (lhs_value.isNumber() and rhs_value.isNumber()) {
        @branchHint(.likely);
        if (lhs_value.__isI32() and rhs_value.__isI32()) {
            vm.load(dst, Value.from(lhs_value.__asI32() > rhs_value.__asI32()));
        } else {
            vm.load(dst, Value.from(lhs_value.__toF64() > rhs_value.__toF64()));
        }
        return;
    }

    const result = try isLessThan(vm.agent, rhs_value, lhs_value, .right_first);
    vm.load(dst, Value.from(result orelse false));
}

fn executeLtEq(vm: *Vm, dst: Bytecode.Reg, lhs: Bytecode.Reg, rhs: Bytecode.Reg) Agent.Error!void {
    const lhs_value = vm.store(lhs);
    const rhs_value = vm.store(rhs);

    // OPTIMIZATION: Fast path for number values
    if (lhs_value.isNumber() and rhs_value.isNumber()) {
        @branchHint(.likely);
        if (lhs_value.__isI32() and rhs_value.__isI32()) {
            vm.load(dst, Value.from(lhs_value.__asI32() <= rhs_value.__asI32()));
        } else {
            vm.load(dst, Value.from(lhs_value.__toF64() <= rhs_value.__toF64()));
        }
        return;
    }

    const result = try isLessThan(vm.agent, rhs_value, lhs_value, .right_first);
    vm.load(dst, Value.from(!(result orelse true)));
}

fn executeGtEq(vm: *Vm, dst: Bytecode.Reg, lhs: Bytecode.Reg, rhs: Bytecode.Reg) Agent.Error!void {
    const lhs_value = vm.store(lhs);
    const rhs_value = vm.store(rhs);

    // OPTIMIZATION: Fast path for number values
    if (lhs_value.isNumber() and rhs_value.isNumber()) {
        @branchHint(.likely);
        if (lhs_value.__isI32() and rhs_value.__isI32()) {
            vm.load(dst, Value.from(lhs_value.__asI32() >= rhs_value.__asI32()));
        } else {
            vm.load(dst, Value.from(lhs_value.__toF64() >= rhs_value.__toF64()));
        }
        return;
    }

    const result = try isLessThan(vm.agent, lhs_value, rhs_value, .left_first);
    vm.load(dst, Value.from(!(result orelse true)));
}

fn executeInstanceOf(vm: *Vm, dst: Bytecode.Reg, lhs: Bytecode.Reg, rhs: Bytecode.Reg) Agent.Error!void {
    const lhs_value = vm.store(lhs);
    const rhs_value = vm.store(rhs);

    const result = try lhs_value.instanceofOperator(vm.agent, rhs_value);
    vm.load(dst, Value.from(result));
}

fn executeIn(vm: *Vm, dst: Bytecode.Reg, lhs: Bytecode.Reg, rhs: Bytecode.Reg) Agent.Error!void {
    const lhs_value = vm.store(lhs);
    const rhs_value = vm.store(rhs);

    if (!rhs_value.isObject()) {
        @branchHint(.unlikely);
        return vm.agent.throwException(
            .type_error,
            "Right-hand side of 'in' operator must be an object",
            .{},
        );
    }

    const result = try rhs_value.asObject().hasProperty(
        vm.agent,
        try lhs_value.toPropertyKey(vm.agent),
    );
    vm.load(dst, Value.from(result));
}

fn executeEq(vm: *Vm, dst: Bytecode.Reg, lhs: Bytecode.Reg, rhs: Bytecode.Reg) Agent.Error!void {
    const lhs_value = vm.store(lhs);
    const rhs_value = vm.store(rhs);

    // OPTIMIZATION: Fast path for number values
    if (lhs_value.isNumber() and rhs_value.isNumber()) {
        @branchHint(.likely);
        if (lhs_value.__isI32() and rhs_value.__isI32()) {
            vm.load(dst, Value.from(lhs_value.__asI32() == rhs_value.__asI32()));
        } else {
            vm.load(dst, Value.from(lhs_value.__toF64() == rhs_value.__toF64()));
        }
        return;
    }

    const result = try isLooselyEqual(vm.agent, rhs_value, lhs_value);
    vm.load(dst, Value.from(result));
}

fn executeNotEq(vm: *Vm, dst: Bytecode.Reg, lhs: Bytecode.Reg, rhs: Bytecode.Reg) Agent.Error!void {
    const lhs_value = vm.store(lhs);
    const rhs_value = vm.store(rhs);

    // OPTIMIZATION: Fast path for number values
    if (lhs_value.isNumber() and rhs_value.isNumber()) {
        @branchHint(.likely);
        if (lhs_value.__isI32() and rhs_value.__isI32()) {
            vm.load(dst, Value.from(lhs_value.__asI32() != rhs_value.__asI32()));
        } else {
            vm.load(dst, Value.from(lhs_value.__toF64() != rhs_value.__toF64()));
        }
        return;
    }

    const result = !try isLooselyEqual(vm.agent, rhs_value, lhs_value);
    vm.load(dst, Value.from(result));
}

fn executeEqStrict(vm: *Vm, dst: Bytecode.Reg, lhs: Bytecode.Reg, rhs: Bytecode.Reg) void {
    const lhs_value = vm.store(lhs);
    const rhs_value = vm.store(rhs);

    // OPTIMIZATION: Fast path for number values
    if (lhs_value.isNumber() and rhs_value.isNumber()) {
        @branchHint(.likely);
        if (lhs_value.__isI32() and rhs_value.__isI32()) {
            vm.load(dst, Value.from(lhs_value.__asI32() == rhs_value.__asI32()));
        } else {
            vm.load(dst, Value.from(lhs_value.__toF64() == rhs_value.__toF64()));
        }
        return;
    }

    const result = isStrictlyEqual(lhs_value, rhs_value);
    vm.load(dst, Value.from(result));
}

fn executeNotEqStrict(vm: *Vm, dst: Bytecode.Reg, lhs: Bytecode.Reg, rhs: Bytecode.Reg) void {
    const lhs_value = vm.store(lhs);
    const rhs_value = vm.store(rhs);

    // OPTIMIZATION: Fast path for number values
    if (lhs_value.isNumber() and rhs_value.isNumber()) {
        @branchHint(.likely);
        if (lhs_value.__isI32() and rhs_value.__isI32()) {
            vm.load(dst, Value.from(lhs_value.__asI32() != rhs_value.__asI32()));
        } else {
            vm.load(dst, Value.from(lhs_value.__toF64() != rhs_value.__toF64()));
        }
        return;
    }

    const result = !isStrictlyEqual(lhs_value, rhs_value);
    vm.load(dst, Value.from(result));
}

fn executePushScope(vm: *Vm) std.mem.Allocator.Error!void {
    const execution_context = vm.agent.runningExecutionContext();
    const old_env = execution_context.ecmascript_code.lexical_environment;
    const env = try newDeclarativeEnvironment(vm.agent.gc_allocator, old_env);
    execution_context.ecmascript_code.lexical_environment = .{ .declarative_environment = env };
    vm.frame.scope_depth += 1;
}

fn executePushCatchScope(vm: *Vm) std.mem.Allocator.Error!void {
    const execution_context = vm.agent.runningExecutionContext();
    const old_env = execution_context.ecmascript_code.lexical_environment;
    const env = try newDeclarativeEnvironment(vm.agent.gc_allocator, old_env);
    execution_context.ecmascript_code.lexical_environment = .{ .declarative_environment = env };
    env.is_catch_env = true;
    vm.frame.scope_depth += 1;
}

fn executePushVarScope(vm: *Vm) std.mem.Allocator.Error!void {
    const execution_context = vm.agent.runningExecutionContext();
    const old_env = execution_context.ecmascript_code.lexical_environment;
    const env = try newDeclarativeEnvironment(vm.agent.gc_allocator, old_env);
    execution_context.ecmascript_code.lexical_environment = .{ .declarative_environment = env };
    execution_context.ecmascript_code.variable_environment = .{ .declarative_environment = env };
    vm.frame.scope_depth += 1;
}

fn executePushWithScope(vm: *Vm, object_reg: Bytecode.Reg) std.mem.Allocator.Error!void {
    const object = vm.store(object_reg).asObject();
    const execution_context = vm.agent.runningExecutionContext();
    const old_env = execution_context.ecmascript_code.lexical_environment;
    const env = try newObjectEnvironment(vm.agent.gc_allocator, object, true, old_env);
    execution_context.ecmascript_code.lexical_environment = .{ .object_environment = env };
    vm.frame.scope_depth += 1;
}

fn executePopScope(vm: *Vm) void {
    const execution_context = vm.agent.runningExecutionContext();
    execution_context.ecmascript_code.lexical_environment = execution_context.ecmascript_code.lexical_environment.outerEnv().?;
    vm.frame.scope_depth -= 1;
}

fn executeCreateVarBinding(vm: *Vm, name_index: Bytecode.StringIndex) Agent.Error!void {
    const name = try vm.getString(name_index);
    const execution_context = vm.agent.runningExecutionContext();
    const env = execution_context.ecmascript_code.lexical_environment;
    try env.createMutableBinding(vm.agent, name, false);
    try env.initializeBinding(vm.agent, name, .undefined);
}

fn executeCreateMutableBinding(vm: *Vm, name_index: Bytecode.StringIndex) Agent.Error!void {
    const name = try vm.getString(name_index);
    const execution_context = vm.agent.runningExecutionContext();
    const env = execution_context.ecmascript_code.lexical_environment;
    try env.createMutableBinding(vm.agent, name, false);
}

fn executeCreateImmutableBinding(vm: *Vm, name_index: Bytecode.StringIndex) Agent.Error!void {
    const name = try vm.getString(name_index);
    const execution_context = vm.agent.runningExecutionContext();
    const env = execution_context.ecmascript_code.lexical_environment;
    try env.createImmutableBinding(vm.agent, name, true);
}

fn executeInitializeBinding(
    vm: *Vm,
    name_index: Bytecode.StringIndex,
    value_reg: Bytecode.Reg,
) Agent.Error!void {
    const name = try vm.getString(name_index);
    const value = vm.store(value_reg);

    const execution_context = vm.agent.runningExecutionContext();
    const env = execution_context.ecmascript_code.lexical_environment;
    try env.initializeBinding(vm.agent, name, value);
}

fn executeGetLocal(vm: *Vm, dst: Bytecode.Reg, local: Bytecode.Local) void {
    const value = vm.locals[@backingInt(local)];
    vm.load(dst, value);
}

fn executeGetBinding(vm: *Vm, dst: Bytecode.Reg, name_index: Bytecode.StringIndex) Agent.Error!void {
    const name = try vm.getString(name_index);

    const execution_context = vm.agent.runningExecutionContext();
    var env = execution_context.ecmascript_code.lexical_environment;
    while (true) {
        if (try env.getBindingValueIfExists(vm.agent, name, true)) |result| {
            vm.load(dst, result);
            return;
        }
        env = env.outerEnv() orelse {
            @branchHint(.unlikely);
            return vm.agent.throwException(
                .reference_error,
                "'{f}' is not defined",
                .{name.fmtRaw()},
            );
        };
    }
}

fn executeGetProperty(
    vm: *Vm,
    dst: Bytecode.Reg,
    base_reg: Bytecode.Reg,
    name_index: Bytecode.StringIndex,
    ic_index: Bytecode.GetPropertyIcIndex,
) Agent.Error!void {
    const base_value = vm.store(base_reg);
    const get_property_ic = vm.getIc(ic_index);

    if (base_value.isObject()) {
        @branchHint(.likely);
        const base_object = base_value.asObject();
        if (try get_property_ic.get(vm.agent, base_object, base_value)) |value| {
            vm.load(dst, value);
            return;
        }
    }

    const base_object = try toObjectForPropertyAccess(vm.agent, base_value);
    const property_key = PropertyKey.from(try vm.getString(name_index));
    const result = try base_object.internalMethods().get(
        vm.agent,
        base_object,
        property_key,
        base_value,
    );

    if (base_value.isObject()) {
        get_property_ic.update(base_object, property_key);
    }

    vm.load(dst, result);
}

fn executeGetPropertyComputed(
    vm: *Vm,
    dst: Bytecode.Reg,
    base_reg: Bytecode.Reg,
    property_reg: Bytecode.Reg,
    ic_index: Bytecode.GetPropertyComputedIcIndex,
) Agent.Error!void {
    const base_value = vm.store(base_reg);
    const property_value = vm.store(property_reg);
    const property_is_index = property_value.__isI32() and property_value.__asI32() >= 0;

    // OPTIMIZATION: Fast path for ordinary objects with dense storage and no out of bounds access
    if (base_value.isObject() and property_is_index) {
        @branchHint(.likely);
        const index: u32 = @intCast(property_value.__asI32());
        if (base_value.asObject().getIndexedFast(index)) |value| {
            vm.load(dst, value);
            return;
        }
    }

    // OPTIMIZATION: Fast path for string indexing
    if (base_value.isString() and property_is_index) {
        @branchHint(.likely);
        const index: u32 = @intCast(property_value.__asI32());
        const string = base_value.asString();
        if (index < string.length) {
            const result = try string.substring(vm.agent, index, index + 1);
            vm.load(dst, Value.from(result));
            return;
        }
        // Fall through to prototype chain lookup for out of bounds access
    }

    const get_property_computed_ic = vm.getIc(ic_index);

    const base_object, const property_key = if (base_value.isObject()) blk: {
        @branchHint(.likely);
        const base_object = base_value.asObject();
        const property_key = try property_value.toPropertyKey(vm.agent);
        if (try get_property_computed_ic.get(vm.agent, base_object, base_value, property_key)) |value| {
            vm.load(dst, value);
            return;
        }
        break :blk .{ base_object, property_key };
    } else blk: {
        const base_object = try toObjectForPropertyAccess(vm.agent, base_value);
        const property_key = try property_value.toPropertyKey(vm.agent);
        break :blk .{ base_object, property_key };
    };

    const result = try base_object.internalMethods().get(
        vm.agent,
        base_object,
        property_key,
        base_value,
    );

    if (base_value.isObject()) {
        get_property_computed_ic.update(base_value.asObject(), property_key);
    }

    vm.load(dst, result);
}

fn executeGetPropertyIndexed(
    vm: *Vm,
    dst: Bytecode.Reg,
    base_reg: Bytecode.Reg,
    index: u32,
) Agent.Error!void {
    const base_value = vm.store(base_reg);

    // OPTIMIZATION: Fast path for ordinary objects with dense storage and no out of bounds access
    if (base_value.isObject()) {
        @branchHint(.likely);
        if (base_value.asObject().getIndexedFast(index)) |value| {
            vm.load(dst, value);
            return;
        }
    }

    // OPTIMIZATION: Fast path for string indexing
    if (base_value.isString()) {
        @branchHint(.likely);
        const string = base_value.asString();
        if (index < string.length) {
            const result = try string.substring(vm.agent, index, index + 1);
            vm.load(dst, Value.from(result));
            return;
        }
        // Fall through to prototype chain lookup for out of bounds access
    }

    const base_object = try toObjectForPropertyAccess(vm.agent, base_value);
    const property_key = PropertyKey.from(@as(u53, index));
    const result = try base_object.internalMethods().get(
        vm.agent,
        base_object,
        property_key,
        base_value,
    );

    vm.load(dst, result);
}

fn executeSetLocal(vm: *Vm, local: Bytecode.Local, value_reg: Bytecode.Reg) void {
    vm.locals[@backingInt(local)] = vm.store(value_reg);
}

fn executeSetBinding(
    vm: *Vm,
    name_index: Bytecode.StringIndex,
    value_reg: Bytecode.Reg,
    comptime strict: bool,
) Agent.Error!void {
    const name = try vm.getString(name_index);
    const value = vm.store(value_reg);

    const execution_context = vm.agent.runningExecutionContext();
    var env = execution_context.ecmascript_code.lexical_environment;
    while (true) {
        if (try env.setMutableBindingIfExists(vm.agent, name, value, strict)) return;
        env = env.outerEnv() orelse {
            @branchHint(.unlikely);
            if (strict) {
                return vm.agent.throwException(
                    .reference_error,
                    "'{f}' is not defined",
                    .{name.fmtRaw()},
                );
            }
            const global_obj = vm.agent.getGlobalObject();
            try global_obj.set(vm.agent, PropertyKey.from(name), value, .ignore);
            return;
        };
    }
}

fn executeSetProperty(
    vm: *Vm,
    base_reg: Bytecode.Reg,
    value_reg: Bytecode.Reg,
    name_index: Bytecode.StringIndex,
    ic_index: Bytecode.SetPropertyIcIndex,
    comptime strict: bool,
) Agent.Error!void {
    const base_value = vm.store(base_reg);
    const value = vm.store(value_reg);
    const set_property_ic = vm.getIc(ic_index);

    if (base_value.isObject()) {
        @branchHint(.likely);
        const base_object = base_value.asObject();
        if (try set_property_ic.set(vm.agent, base_object, base_value, value)) return;
    }

    const base_object = try toObjectForPropertyAccess(vm.agent, base_value);
    const property_key = PropertyKey.from(try vm.getString(name_index));
    const success = try base_object.internalMethods().set(
        vm.agent,
        base_object,
        property_key,
        value,
        base_value,
    );
    if (!success) {
        @branchHint(.unlikely);
        if (strict) {
            return vm.agent.throwException(.type_error, "Could not set property", .{});
        }
        return;
    }

    if (base_value.isObject()) {
        set_property_ic.update(base_object, property_key);
    }
}

fn executeSetPropertyComputed(
    vm: *Vm,
    base_reg: Bytecode.Reg,
    property_reg: Bytecode.Reg,
    value_reg: Bytecode.Reg,
    ic_index: Bytecode.SetPropertyComputedIcIndex,
    comptime strict: bool,
) Agent.Error!void {
    const base_value = vm.store(base_reg);
    const property_value = vm.store(property_reg);
    const value = vm.store(value_reg);
    const property_is_index = property_value.__isI32() and property_value.__asI32() >= 0;

    // OPTIMIZATION: Fast path for ordinary objects with dense storage and no out of bounds access
    if (base_value.isObject() and property_is_index) {
        @branchHint(.likely);
        const index: u32 = @intCast(property_value.__asI32());
        if (try base_value.asObject().setIndexedFast(vm.agent.gc_allocator, index, value)) {
            return;
        }
    }

    const set_property_computed_ic = vm.getIc(ic_index);

    const base_object, const property_key = if (base_value.isObject()) blk: {
        @branchHint(.likely);
        const base_object = base_value.asObject();
        const property_key = try property_value.toPropertyKey(vm.agent);
        if (try set_property_computed_ic.set(vm.agent, base_object, base_value, property_key, value)) return;
        break :blk .{ base_object, property_key };
    } else blk: {
        const base_object = try toObjectForPropertyAccess(vm.agent, base_value);
        const property_key = try property_value.toPropertyKey(vm.agent);
        break :blk .{ base_object, property_key };
    };

    const success = try base_object.internalMethods().set(
        vm.agent,
        base_object,
        property_key,
        value,
        base_value,
    );
    if (!success) {
        @branchHint(.unlikely);
        if (strict) {
            return vm.agent.throwException(.type_error, "Could not set property", .{});
        }
        return;
    }

    if (base_value.isObject()) {
        set_property_computed_ic.update(base_value.asObject(), property_key);
    }
}

fn executeSetPropertyIndexed(
    vm: *Vm,
    base_reg: Bytecode.Reg,
    value_reg: Bytecode.Reg,
    index: u32,
    comptime strict: bool,
) Agent.Error!void {
    const base_value = vm.store(base_reg);
    const value = vm.store(value_reg);

    // OPTIMIZATION: Fast path for ordinary objects with dense storage and no out of bounds access
    if (base_value.isObject()) {
        @branchHint(.likely);
        if (try base_value.asObject().setIndexedFast(vm.agent.gc_allocator, index, value)) {
            return;
        }
    }

    const base_object = try toObjectForPropertyAccess(vm.agent, base_value);
    const property_key = PropertyKey.from(@as(u53, index));
    const success = try base_object.internalMethods().set(
        vm.agent,
        base_object,
        property_key,
        value,
        base_value,
    );
    if (!success) {
        @branchHint(.unlikely);
        if (strict) {
            return vm.agent.throwException(.type_error, "Could not set property", .{});
        }
        return;
    }
}

fn executeDeleteBinding(vm: *Vm, dst: Bytecode.Reg, name_index: Bytecode.StringIndex) Agent.Error!void {
    const name = try vm.getString(name_index);

    var env = vm.agent.runningExecutionContext().ecmascript_code.lexical_environment;
    while (!try env.hasBinding(vm.agent, name)) {
        env = env.outerEnv() orelse {
            @branchHint(.unlikely);
            vm.load(dst, .true);
            return;
        };
    }

    const result = try env.deleteBinding(vm.agent, name);
    vm.load(dst, Value.from(result));
}

fn executeDeleteProperty(
    vm: *Vm,
    dst: Bytecode.Reg,
    base_reg: Bytecode.Reg,
    name_index: Bytecode.StringIndex,
    comptime strict: bool,
) Agent.Error!void {
    const base_value = vm.store(base_reg);
    const base_object = try toObjectForPropertyAccess(vm.agent, base_value);
    const property_key = PropertyKey.from(try vm.getString(name_index));
    const delete_status = try base_object.internalMethods().delete(
        vm.agent,
        base_object,
        property_key,
    );
    if (!delete_status and strict) {
        @branchHint(.unlikely);
        return vm.agent.throwException(.type_error, "Could not delete property", .{});
    }
    vm.load(dst, Value.from(delete_status));
}

fn executeDeletePropertyComputed(
    vm: *Vm,
    dst: Bytecode.Reg,
    base_reg: Bytecode.Reg,
    property_reg: Bytecode.Reg,
    comptime strict: bool,
) Agent.Error!void {
    const base_value = vm.store(base_reg);
    const property_value = vm.store(property_reg);
    const base_object = try toObjectForPropertyAccess(vm.agent, base_value);
    const property_key = try property_value.toPropertyKey(vm.agent);
    const delete_status = try base_object.internalMethods().delete(
        vm.agent,
        base_object,
        property_key,
    );
    if (!delete_status and strict) {
        @branchHint(.unlikely);
        return vm.agent.throwException(.type_error, "Could not delete property", .{});
    }
    vm.load(dst, Value.from(delete_status));
}

fn executeDeletePropertyIndexed(
    vm: *Vm,
    dst: Bytecode.Reg,
    base_reg: Bytecode.Reg,
    index: u32,
    comptime strict: bool,
) Agent.Error!void {
    const base_value = vm.store(base_reg);
    const base_object = try toObjectForPropertyAccess(vm.agent, base_value);
    const property_key = PropertyKey.from(@as(u53, index));
    const delete_status = try base_object.internalMethods().delete(
        vm.agent,
        base_object,
        property_key,
    );
    if (!delete_status and strict) {
        @branchHint(.unlikely);
        return vm.agent.throwException(.type_error, "Could not delete property", .{});
    }
    vm.load(dst, Value.from(delete_status));
}

fn executeCopyDataProperties(vm: *Vm, dest: Bytecode.Reg, source_reg: Bytecode.Reg, excluded_reg: Bytecode.Reg) Agent.Error!void {
    const gpa = vm.agent.gpa;
    const source_value = vm.store(source_reg);

    const target = try ordinaryObjectCreateFast(vm.agent);
    if (excluded_reg == .none) {
        const excluded_items: []const PropertyKey = &.{};
        try target.copyDataProperties(vm.agent, source_value, excluded_items);
    } else {
        const excluded_object = vm.store(excluded_reg).asObject();
        const excluded_len = excluded_object.as(builtins.Array).fields.length;

        var excluded_items: std.ArrayList(PropertyKey) = try .initCapacity(gpa, excluded_len);
        defer excluded_items.deinit(gpa);
        for (0..excluded_len) |i| {
            const descriptor = excluded_object.extra_data.?.indexed_properties.get(@intCast(i)).?;
            const prop_key = PropertyKey.from(descriptor.value_or_accessor.value.asString());
            excluded_items.appendAssumeCapacity(prop_key);
        }

        try target.copyDataProperties(vm.agent, source_value, excluded_items.items);
    }

    vm.load(dest, Value.from(target));
}

fn executeCall(
    vm: *Vm,
    dest: Bytecode.Reg,
    callee_reg: Bytecode.Reg,
    args_reg: Bytecode.Reg,
) Agent.Error!void {
    const gpa = vm.agent.gpa;
    const callee_value = vm.store(callee_reg);
    const args_value = vm.store(args_reg);
    const args_array = args_value.asObject().as(builtins.Array);

    var buffer: [@sizeOf(Value) * 8]u8 = undefined;
    var bfa_state: std.heap.BufferFirstAllocator = .init(&buffer, gpa);
    const bfa = bfa_state.allocator();

    var args_list = try argsArrayToList(bfa, args_array);
    defer args_list.deinit(bfa);

    const result = try evaluateCall(vm.agent, callee_value, .undefined, args_list.items);
    vm.load(dest, result);
}

fn executeCallN(
    vm: *Vm,
    comptime N: comptime_int,
    dest: Bytecode.Reg,
    callee_reg: Bytecode.Reg,
    arg_regs: [N]Bytecode.Reg,
) Agent.Error!void {
    const callee_value = vm.store(callee_reg);

    var args: [N]Value = undefined;
    inline for (0..N) |i| args[i] = vm.store(arg_regs[i]);

    const result = try evaluateCall(vm.agent, callee_value, .undefined, &args);
    vm.load(dest, result);
}

fn executeCallProperty(
    vm: *Vm,
    dest: Bytecode.Reg,
    callee_reg: Bytecode.Reg,
    this_reg: Bytecode.Reg,
    args_reg: Bytecode.Reg,
) Agent.Error!void {
    const gpa = vm.agent.gpa;
    const callee_value = vm.store(callee_reg);
    const this_value = vm.store(this_reg);
    const args_value = vm.store(args_reg);
    const args_array = args_value.asObject().as(builtins.Array);

    var buffer: [@sizeOf(Value) * 8]u8 = undefined;
    var bfa_state: std.heap.BufferFirstAllocator = .init(&buffer, gpa);
    const bfa = bfa_state.allocator();

    var args_list = try argsArrayToList(bfa, args_array);
    defer args_list.deinit(bfa);

    const result = try evaluateCall(vm.agent, callee_value, this_value, args_list.items);
    vm.load(dest, result);
}

fn executeCallPropertyN(
    vm: *Vm,
    comptime N: comptime_int,
    dest: Bytecode.Reg,
    callee_reg: Bytecode.Reg,
    this_reg: Bytecode.Reg,
    arg_regs: [N]Bytecode.Reg,
) Agent.Error!void {
    const callee_value = vm.store(callee_reg);
    const this_value = vm.store(this_reg);

    var args: [N]Value = undefined;
    inline for (0..N) |i| args[i] = vm.store(arg_regs[i]);

    const result = try evaluateCall(vm.agent, callee_value, this_value, &args);
    vm.load(dest, result);
}

fn executeCallDirectEval(
    vm: *Vm,
    dest: Bytecode.Reg,
    callee_reg: Bytecode.Reg,
    args_reg: Bytecode.Reg,
    strict: bool,
) Agent.Error!void {
    const gpa = vm.agent.gpa;
    const callee_value = vm.store(callee_reg);
    const args_value = vm.store(args_reg);
    const args_array = args_value.asObject().as(builtins.Array);

    var buffer: [@sizeOf(Value) * 8]u8 = undefined;
    var bfa_state: std.heap.BufferFirstAllocator = .init(&buffer, gpa);
    const bfa = bfa_state.allocator();

    var args_list = try argsArrayToList(bfa, args_array);
    defer args_list.deinit(bfa);

    const realm = vm.agent.currentRealm();
    const eval = try realm.intrinsic(.eval);

    const result = if (callee_value.sameValue(Value.from(eval)))
        try directEval(vm.agent, args_list.items, strict)
    else
        try evaluateCall(vm.agent, callee_value, .undefined, args_list.items);
    vm.load(dest, result);
}

fn executeConstruct(
    vm: *Vm,
    dest: Bytecode.Reg,
    constructor_reg: Bytecode.Reg,
    args_reg: Bytecode.Reg,
) Agent.Error!void {
    const gpa = vm.agent.gpa;
    const constructor = vm.store(constructor_reg);
    const args_value = vm.store(args_reg);
    const args_array = args_value.asObject().as(builtins.Array);

    var buffer: [@sizeOf(Value) * 8]u8 = undefined;
    var bfa_state: std.heap.BufferFirstAllocator = .init(&buffer, gpa);
    const bfa = bfa_state.allocator();

    var args_list = try argsArrayToList(bfa, args_array);
    defer args_list.deinit(bfa);

    const result = try evaluateNew(vm.agent, constructor, args_list.items);
    vm.load(dest, Value.from(result));
}

fn executeConstructN(
    vm: *Vm,
    comptime N: comptime_int,
    dest: Bytecode.Reg,
    constructor_reg: Bytecode.Reg,
    arg_regs: [N]Bytecode.Reg,
) Agent.Error!void {
    const constructor = vm.store(constructor_reg);

    var args: [N]Value = undefined;
    inline for (0..N) |i| args[i] = vm.store(arg_regs[i]);

    const result = try evaluateNew(vm.agent, constructor, &args);
    vm.load(dest, Value.from(result));
}

fn executeGetTemplateObject(vm: *Vm, dest: Bytecode.Reg, raw_reg: Bytecode.Reg, cooked_reg: Bytecode.Reg, template_id: u16) Agent.Error!void {
    const cache_key = std.hash.Wyhash.hash(template_id, std.mem.asBytes(&vm.frame.bytecode));
    const raw = vm.store(raw_reg).asObject().as(builtins.Array);
    const cooked = vm.store(cooked_reg).asObject().as(builtins.Array);
    const template = try getTemplateObject(vm.agent, cache_key, raw, cooked);
    vm.load(dest, Value.from(&template.object));
}

fn executeGetIterator(vm: *Vm, dest: Bytecode.Reg, value_reg: Bytecode.Reg) Agent.Error!void {
    const value = vm.store(value_reg);
    const iterator = try getIterator(vm.agent, value, .sync);
    const iterator_obj = try iteratorToObject(vm.agent, iterator);
    vm.load(dest, Value.from(iterator_obj));
}

fn executeGetAsyncIterator(vm: *Vm, dest: Bytecode.Reg, value_reg: Bytecode.Reg) Agent.Error!void {
    const value = vm.store(value_reg);
    const iterator = try getIterator(vm.agent, value, .async);
    const iterator_obj = try iteratorToObject(vm.agent, iterator);
    vm.load(dest, Value.from(iterator_obj));
}

fn executeGetForInIterator(vm: *Vm, dest: Bytecode.Reg, value_reg: Bytecode.Reg) Agent.Error!void {
    const value = vm.store(value_reg);
    const object = value.toObject(vm.agent) catch |err| try noexcept(err);
    const for_in_iterator = try createForInIterator(vm.agent, object);
    const iterator = try getIteratorDirect(vm.agent, &for_in_iterator.object);
    const iterator_obj = try iteratorToObject(vm.agent, iterator);
    vm.load(dest, Value.from(iterator_obj));
}

fn executeIteratorStep(vm: *Vm, dest: Bytecode.Reg, iterator_reg: Bytecode.Reg) Agent.Error!void {
    const iterator_obj = vm.store(iterator_reg).asObject();
    var iterator = objectToIterator(iterator_obj);

    if (try iterator.step(vm.agent)) |next| {
        vm.load(dest, Value.from(next));
    } else {
        vm.load(dest, .undefined);
        iterator_obj.setValueAtPropertyOffset(@fromBackingInt(2), .true);
    }
}

fn executeIteratorStepValue(vm: *Vm, dest: Bytecode.Reg, iterator_reg: Bytecode.Reg) Agent.Error!void {
    const iterator_obj = vm.store(iterator_reg).asObject();
    var iterator = objectToIterator(iterator_obj);

    if (try iterator.stepValue(vm.agent)) |next| {
        vm.load(dest, next);
    } else {
        vm.load(dest, .undefined);
        iterator_obj.setValueAtPropertyOffset(@fromBackingInt(2), .true);
    }
}

fn executeIteratorStepValueAsync(vm: *Vm, dest: Bytecode.Reg, iterator_reg: Bytecode.Reg) Agent.Error!void {
    const iterator_obj = vm.store(iterator_reg).asObject();

    const iterator_inner = iterator_obj.getValueAtPropertyOffset(@fromBackingInt(0)).asObject();
    const next_method = iterator_obj.getValueAtPropertyOffset(@fromBackingInt(1));

    // Implements steps 8.a-f. of ForIn/OfBodyEvaluation for async iterators.
    // https://tc39.es/ecma262/#sec-runtime-semantics-forin-div-ofbodyevaluation-lhs-stmt-iterator-lhskind-labelset

    // a. Let nextResult be ? Call(iteratorRecord.[[NextMethod]], iteratorRecord.[[Iterator]]).
    const next_result = next_method.call(vm.agent, Value.from(iterator_inner), &.{}) catch |err| {
        iterator_obj.setValueAtPropertyOffset(@fromBackingInt(2), .true);
        return err;
    };

    // b. If iteratorKind is async, set nextResult to ? Await(nextResult).
    const awaited_result = await(vm.agent, next_result) catch |err| {
        iterator_obj.setValueAtPropertyOffset(@fromBackingInt(2), .true);
        return err;
    };

    // c. If nextResult is not an Object, throw a TypeError exception.
    if (!awaited_result.isObject()) {
        iterator_obj.setValueAtPropertyOffset(@fromBackingInt(2), .true);
        return vm.agent.throwException(.type_error, "{f} is not an Object", .{awaited_result});
    }

    // d. Let done be ? IteratorComplete(nextResult).
    const done = try Iterator.complete(vm.agent, awaited_result.asObject());

    // e. If done is true, return V.
    if (done) {
        iterator_obj.setValueAtPropertyOffset(@fromBackingInt(2), .true);
        vm.load(dest, .undefined);
        return;
    }

    // f. Let nextValue be ? IteratorValue(nextResult).
    const value = Iterator.value(vm.agent, awaited_result.asObject()) catch |err| {
        iterator_obj.setValueAtPropertyOffset(@fromBackingInt(2), .true);
        return err;
    };

    vm.load(dest, value);
}

fn executeIteratorClose(vm: *Vm, iterator_reg: Bytecode.Reg) Agent.Error!void {
    const iterator_obj = vm.store(iterator_reg).asObject();
    var iterator = objectToIterator(iterator_obj);
    if (iterator.done) return;
    try iterator.close(vm.agent, @as(Agent.Error!void, {}));
}

fn executeIteratorIsDone(vm: *Vm, dest: Bytecode.Reg, iterator_reg: Bytecode.Reg) void {
    const iterator_obj = vm.store(iterator_reg).asObject();
    const done = iterator_obj.getValueAtPropertyOffset(@fromBackingInt(2));
    vm.load(dest, done);
}

fn executeIteratorCollect(vm: *Vm, dest: Bytecode.Reg, iterator_reg: Bytecode.Reg) Agent.Error!void {
    const iterator_obj = vm.store(iterator_reg).asObject();
    var iterator = objectToIterator(iterator_obj);

    var values: std.ArrayList(Value) = .empty;
    defer values.deinit(vm.agent.gc_allocator);
    while (try iterator.stepValue(vm.agent)) |next| {
        try values.append(vm.agent.gc_allocator, next);
    }
    iterator_obj.setValueAtPropertyOffset(@fromBackingInt(2), .true);

    const array = try createArrayFromList(vm.agent, values.items);
    vm.load(dest, Value.from(&array.object));
}

fn executeThrow(vm: *Vm, value_reg: Bytecode.Reg) Agent.Error!void {
    const value = vm.store(value_reg);
    vm.agent.exception = .{
        .value = value,
        .stack_trace = try vm.agent.captureStackTrace(.{}),
    };
    return error.ExceptionThrown;
}

fn executeThrowReferenceError(vm: *Vm) Agent.Error!void {
    // Only emitted for web-compat assignment
    return vm.agent.throwException(.reference_error, "Invalid assignment to function call", .{});
}

fn executeReturn(vm: *Vm, reg: Bytecode.Reg) RunResult {
    const return_value: ?Value = if (reg != .none) vm.store(reg) else null;
    if (vm.call_stack.items.len > 1) vm.popCallFrame();
    return .{ .@"return" = return_value };
}

fn executeAwait(vm: *Vm, dest: Bytecode.Reg, value_reg: Bytecode.Reg) Agent.Error!void {
    const value = vm.store(value_reg);
    const result = try await(vm.agent, value);
    vm.load(dest, result);
}

fn executeYield(vm: *Vm, dest: Bytecode.Reg, value_reg: Bytecode.Reg, pc: Pc) Agent.Error!RunResult {
    // The initial `yield` instruction inserted after FDI doesn't have a register.
    if (dest != .none) {
        const value = vm.store(value_reg);
        _ = try yield(vm.agent, value);
    } else {
        std.debug.assert(value_reg == .none);
    }

    const stack_len = vm.frame.stackLen();
    const stack = try vm.agent.gc_allocator.dupe(
        Value,
        vm.stack.items[vm.frame.stack_base..][0..stack_len],
    );

    const frame = vm.frame.*;
    std.debug.assert(vm.call_stack.items.len > 1);
    vm.popCallFrame();

    return .{ .yield = .{
        .stack = stack,
        .argument_count = frame.argument_count,
        .local_count = frame.bytecode.local_count,
        .scope_depth = frame.scope_depth,
        .saved_pc = pc,
        .yield_reg = dest,
    } };
}

fn executeYieldStar(vm: *Vm, reg: Bytecode.Reg, iter_reg: Bytecode.Reg, pc: Pc) Agent.Error!?RunResult {
    const iterator_obj = vm.store(iter_reg).asObject();
    var iterator = objectToIterator(iterator_obj);
    const received_value = vm.store(reg);

    // TODO: Handle throw/return completions
    switch (try evaluateYieldStar(vm.agent, &iterator, .{ .normal = received_value })) {
        .done => |value| {
            vm.load(reg, value);
            return null;
        },
        .@"return" => |value| return .{ .@"return" = value },
        .yield => {},
    }

    const stack_len = vm.frame.stackLen();
    const stack = try vm.agent.gc_allocator.dupe(
        Value,
        vm.stack.items[vm.frame.stack_base..][0..stack_len],
    );

    const frame = vm.frame.*;
    std.debug.assert(vm.call_stack.items.len > 1);
    vm.popCallFrame();

    return .{ .yield = .{
        .stack = stack,
        .argument_count = frame.argument_count,
        .local_count = frame.bytecode.local_count,
        .scope_depth = frame.scope_depth,
        .saved_pc = pc,
        .yield_reg = reg,
    } };
}

fn executeCreateFunction(vm: *Vm, dest: Bytecode.Reg, function_index: Bytecode.Function.Index) Agent.Error!void {
    const execution_context = vm.agent.runningExecutionContext();
    const function = vm.getFunction(function_index);
    const identifier: ?[]const u8 = switch (function.name) {
        .identifier => |name_index| name_index.slice(vm.frame.bytecode),
        .none, .default => null,
    };
    const default_name: ?[]const u8 = switch (function.name) {
        .default => |name_index| name_index.slice(vm.frame.bytecode),
        .none, .identifier => null,
    };
    const cache_index =
        vm.frame.bytecode.strings.len +
        vm.frame.bytecode.big_ints.len +
        @backingInt(function_index);
    const cached_bytecode: *const Bytecode = if (vm.cache_slots[cache_index]) |ptr| blk: {
        @branchHint(.likely);
        break :blk @ptrCast(ptr);
    } else blk: {
        const name = identifier orelse default_name orelse "";
        const bytecode = try vm.agent.gc_allocator.create(Bytecode);
        errdefer vm.agent.gc_allocator.destroy(bytecode);
        bytecode.* = try interpreter.compile(vm.agent, name, .{
            .function = .{
                .parameters = &function.parameters,
                .body = &function.body,
            },
        });
        vm.cache_slots[cache_index] = @ptrCast(@alignCast(bytecode));
        break :blk bytecode;
    };
    const source: []const u8 = switch (execution_context.origin) {
        .eval => |source| source,
        else => switch (execution_context.script_or_module.?) {
            .script => |script| script.source,
            .module => |module| module.source_text_module.source,
        },
    };
    const function_obj = switch (function.kind) {
        .normal => try instantiateOrdinaryFunctionExpression(
            vm.agent,
            .{
                .identifier = identifier,
                .formal_parameters = function.parameters,
                .function_body = function.body,
                .source_range = function.source_range,
            },
            default_name,
            source,
        ),
        .arrow => try instantiateArrowFunctionExpression(
            vm.agent,
            .{
                .formal_parameters = function.parameters,
                .function_body = function.body,
                .source_range = function.source_range,
            },
            default_name,
            source,
        ),
        .generator => try instantiateGeneratorFunctionExpression(
            vm.agent,
            .{
                .identifier = identifier,
                .formal_parameters = function.parameters,
                .function_body = function.body,
                .source_range = function.source_range,
            },
            default_name,
            source,
        ),
        .async => try instantiateAsyncFunctionExpression(
            vm.agent,
            .{
                .identifier = identifier,
                .formal_parameters = function.parameters,
                .function_body = function.body,
                .source_range = function.source_range,
            },
            default_name,
            source,
        ),
        .async_arrow => try instantiateAsyncArrowFunctionExpression(
            vm.agent,
            .{
                .formal_parameters = function.parameters,
                .function_body = function.body,
                .source_range = function.source_range,
            },
            default_name,
            source,
        ),
        .async_generator => try instantiateAsyncGeneratorFunctionExpression(
            vm.agent,
            .{
                .identifier = identifier,
                .formal_parameters = function.parameters,
                .function_body = function.body,
                .source_range = function.source_range,
            },
            default_name,
            source,
        ),
    };
    function_obj.fields.cached_bytecode = cached_bytecode;
    vm.load(dest, Value.from(&function_obj.object));
}

fn executeCreateClass(vm: *Vm, dest: Bytecode.Reg, class_index: Bytecode.Class.Index) Agent.Error!void {
    const execution_context = vm.agent.runningExecutionContext();
    const class = vm.getClass(class_index);
    const class_binding: ?*const String = switch (class.name) {
        .identifier => |name_index| try vm.getString(name_index),
        .none, .default => null,
    };
    const class_name: *const String = switch (class.name) {
        .identifier => |name_index| try vm.getString(name_index),
        .default => |name_index| try vm.getString(name_index),
        .none => .empty,
    };
    const heritage: ?Value = switch (class.heritage) {
        .none => null,
        else => vm.store(class.heritage),
    };
    const element_names = try vm.agent.gc_allocator.alloc(Value, class.element_names.len);
    defer vm.agent.gc_allocator.free(element_names);
    for (class.element_names, element_names) |name_reg, *value| {
        value.* = switch (name_reg) {
            .none => .undefined,
            else => vm.store(name_reg),
        };
    }
    const source = switch (execution_context.origin) {
        .eval => |source| source,
        else => switch (execution_context.script_or_module.?) {
            .script => |script| script.source,
            .module => |module| module.source_text_module.source,
        },
    };
    const class_obj = try classDefinitionEvaluation(
        vm.agent,
        class.class_tail,
        class_binding,
        class_name,
        class.source_range,
        source,
        heritage,
        element_names,
    );
    vm.load(dest, Value.from(class_obj));
}

fn executeSetHomeObject(vm: *Vm, function_reg: Bytecode.Reg, home_object_reg: Bytecode.Reg) void {
    const function_value = vm.store(function_reg);
    const home_object_value = vm.store(home_object_reg);
    const function = function_value.asObject().as(builtins.ECMAScriptFunction);
    makeMethod(function, home_object_value.asObject());
}

fn executeCreateUnmappedArgumentsObject(vm: *Vm, dest: Bytecode.Reg) std.mem.Allocator.Error!void {
    const arguments_object = try createUnmappedArgumentsObject(vm.agent, vm.arguments());
    vm.load(dest, Value.from(&arguments_object.object));
}

fn executeCreateMappedArgumentsObject(vm: *Vm, dest: Bytecode.Reg) std.mem.Allocator.Error!void {
    const execution_context = vm.agent.runningExecutionContext();
    const function = execution_context.origin.function.as(builtins.ECMAScriptFunction);
    const arguments_object = try createMappedArgumentsObject(
        vm.agent,
        function,
        function.fields.formal_parameters,
        vm.arguments(),
        execution_context.ecmascript_code.lexical_environment,
    );
    vm.load(dest, Value.from(&arguments_object.object));
}

fn executeGetArgument(vm: *Vm, dest: Bytecode.Reg, arg_index: u16) void {
    const args = vm.arguments();
    const value: Value = if (arg_index < args.len) args[arg_index] else .undefined;
    vm.load(dest, value);
}

fn executeGetRestArguments(vm: *Vm, dest: Bytecode.Reg, start_index: u16) std.mem.Allocator.Error!void {
    const args = vm.arguments();
    const rest_args = args[@min(start_index, args.len)..];
    const array = try createArrayFromList(vm.agent, rest_args);
    vm.load(dest, Value.from(&array.object));
}

fn executeGetNewTarget(vm: *Vm, reg: Bytecode.Reg) void {
    const value: Value = if (vm.agent.getNewTarget()) |new_target|
        Value.from(new_target)
    else
        .undefined;
    vm.load(reg, value);
}

fn executeSuperCall(
    vm: *Vm,
    dest: Bytecode.Reg,
    args_reg: Bytecode.Reg,
) Agent.Error!void {
    const gpa = vm.agent.gpa;
    const args_value = vm.store(args_reg);
    const args_array = args_value.asObject().as(builtins.Array);

    var buffer: [@sizeOf(Value) * 8]u8 = undefined;
    var bfa_state: std.heap.BufferFirstAllocator = .init(&buffer, gpa);
    const bfa = bfa_state.allocator();

    var args_list = try argsArrayToList(bfa, args_array);
    defer args_list.deinit(bfa);

    const result = try evaluateSuperCall(vm.agent, args_list.items);
    vm.load(dest, result);
}

fn executeGetSuperProperty(vm: *Vm, dest: Bytecode.Reg, name_index: Bytecode.StringIndex) Agent.Error!void {
    const env = vm.agent.getThisEnvironment();
    const actual_this = try env.getThisBinding(vm.agent);
    const base = env.function_environment.getSuperBase();
    const base_value: Value = switch (base) {
        .undefined => .undefined,
        .object => |maybe_object| if (maybe_object) |o| Value.from(o) else .null,
    };
    const base_object = try base_value.toObject(vm.agent);
    const property_key = PropertyKey.from(try vm.getString(name_index));
    const result = try base_object.internalMethods().get(vm.agent, base_object, property_key, actual_this);
    vm.load(dest, result);
}

fn executeGetSuperPropertyComputed(vm: *Vm, dest: Bytecode.Reg, property_reg: Bytecode.Reg) Agent.Error!void {
    const property_value = vm.store(property_reg);
    const env = vm.agent.getThisEnvironment();
    const actual_this = try env.getThisBinding(vm.agent);
    const base = env.function_environment.getSuperBase();
    const base_value: Value = switch (base) {
        .undefined => .undefined,
        .object => |maybe_object| if (maybe_object) |o| Value.from(o) else .null,
    };
    const base_object = try base_value.toObject(vm.agent);
    const property_key = try property_value.toPropertyKey(vm.agent);
    const result = try base_object.internalMethods().get(vm.agent, base_object, property_key, actual_this);
    vm.load(dest, result);
}

fn executeSetSuperProperty(vm: *Vm, value_reg: Bytecode.Reg, name_index: Bytecode.StringIndex, comptime strict: bool) Agent.Error!void {
    const value = vm.store(value_reg);
    const env = vm.agent.getThisEnvironment();
    const actual_this = try env.getThisBinding(vm.agent);
    const base = env.function_environment.getSuperBase();
    const base_value: Value = switch (base) {
        .undefined => .undefined,
        .object => |maybe_object| if (maybe_object) |o| Value.from(o) else .null,
    };
    const base_object = try base_value.toObject(vm.agent);
    const property_key = PropertyKey.from(try vm.getString(name_index));
    const succeeded = try base_object.internalMethods().set(vm.agent, base_object, property_key, value, actual_this);
    if (!succeeded and strict) {
        @branchHint(.unlikely);
        return vm.agent.throwException(.type_error, "Could not set super property", .{});
    }
}

fn executeSetSuperPropertyComputed(vm: *Vm, property_reg: Bytecode.Reg, value_reg: Bytecode.Reg, comptime strict: bool) Agent.Error!void {
    const property_value = vm.store(property_reg);
    const value = vm.store(value_reg);
    const env = vm.agent.getThisEnvironment();
    const actual_this = try env.getThisBinding(vm.agent);
    const base = env.function_environment.getSuperBase();
    const base_value: Value = switch (base) {
        .undefined => .undefined,
        .object => |maybe_object| if (maybe_object) |o| Value.from(o) else .null,
    };
    const base_object = try base_value.toObject(vm.agent);
    const property_key = try property_value.toPropertyKey(vm.agent);
    const succeeded = try base_object.internalMethods().set(vm.agent, base_object, property_key, value, actual_this);
    if (!succeeded and strict) {
        @branchHint(.unlikely);
        return vm.agent.throwException(.type_error, "Could not set super property", .{});
    }
}

fn executeCreatePrivateElement(vm: *Vm, dest: Bytecode.Reg, name_index: Bytecode.StringIndex) Agent.Error!void {
    const name = try vm.getString(name_index);
    const name_utf8 = try name.toUtf8(vm.agent.gc_allocator);

    const execution_context = vm.agent.runningExecutionContext();
    const private_env = execution_context.ecmascript_code.private_environment.?;
    const private_name = try PrivateName.init(vm.agent.gc_allocator, name);

    try private_env.names.putNoClobber(vm.agent.gc_allocator, name_utf8, private_name);
    vm.load(dest, Value.from(private_name.symbol));
}

fn executeResolvePrivateElement(vm: *Vm, dest: Bytecode.Reg, name_index: Bytecode.StringIndex) Agent.Error!void {
    const name = name_index.slice(vm.frame.bytecode);

    const execution_context = vm.agent.runningExecutionContext();
    const private_env = execution_context.ecmascript_code.private_environment.?;
    const private_name = private_env.resolvePrivateIdentifier(name);

    vm.load(dest, Value.from(private_name.symbol));
}

fn executePushPrivateScope(vm: *Vm) std.mem.Allocator.Error!void {
    const execution_context = vm.agent.runningExecutionContext();
    const private_env = try newPrivateEnvironment(
        vm.agent.gc_allocator,
        execution_context.ecmascript_code.private_environment,
    );
    execution_context.ecmascript_code.private_environment = private_env;
}

fn executePopPrivateScope(vm: *Vm) void {
    const execution_context = vm.agent.runningExecutionContext();
    execution_context.ecmascript_code.private_environment = execution_context.ecmascript_code.private_environment.?.outer_private_environment;
}

fn executeGetPrivateElement(vm: *Vm, dest: Bytecode.Reg, base_reg: Bytecode.Reg, name_index: Bytecode.StringIndex) Agent.Error!void {
    const base_value = vm.store(base_reg);
    const name = name_index.slice(vm.frame.bytecode);

    const execution_context = vm.agent.runningExecutionContext();
    const private_env = execution_context.ecmascript_code.private_environment.?;
    const private_name = private_env.resolvePrivateIdentifier(name);

    const base_object = try base_value.toObject(vm.agent);
    const result = try base_object.privateGet(vm.agent, private_name);
    vm.load(dest, result);
}

fn executeSetPrivateElement(vm: *Vm, base_reg: Bytecode.Reg, name_index: Bytecode.StringIndex, value_reg: Bytecode.Reg) Agent.Error!void {
    const base_value = vm.store(base_reg);
    const value = vm.store(value_reg);
    const name = name_index.slice(vm.frame.bytecode);

    const execution_context = vm.agent.runningExecutionContext();
    const private_env = execution_context.ecmascript_code.private_environment.?;
    const private_name = private_env.resolvePrivateIdentifier(name);

    const base_object = try base_value.toObject(vm.agent);
    try base_object.privateSet(vm.agent, private_name, value);
}

fn executeHasPrivateElement(vm: *Vm, dest: Bytecode.Reg, symbol_reg: Bytecode.Reg, object_reg: Bytecode.Reg) Agent.Error!void {
    const symbol_value = vm.store(symbol_reg);
    const object_value = vm.store(object_reg);

    if (!object_value.isObject()) {
        return vm.agent.throwException(
            .type_error,
            "Right-hand side of 'in' operator must be an object",
            .{},
        );
    }

    const private_name = symbol_value.toPrivateName().?;
    const result = object_value.asObject().privateElementFind(private_name) != null;
    vm.load(dest, Value.from(result));
}

fn executeImportCall(vm: *Vm, dest: Bytecode.Reg, specifier_reg: Bytecode.Reg, options_reg: Bytecode.Reg) Agent.Error!void {
    const specifier = vm.store(specifier_reg);
    const options = vm.store(options_reg);
    const result = try evaluateImportCall(vm.agent, specifier, options);
    vm.load(dest, result);
}

fn executeGetImportMeta(vm: *Vm, dest: Bytecode.Reg) std.mem.Allocator.Error!void {
    const result = try evaluateImportMeta(vm.agent);
    vm.load(dest, result);
}

fn executeAddDisposableResource(
    vm: *Vm,
    value_reg: Bytecode.Reg,
    comptime kind: DisposableResource.Kind,
) Agent.Error!void {
    const value = vm.store(value_reg);
    const execution_context = vm.agent.runningExecutionContext();
    const env = execution_context.ecmascript_code.lexical_environment;
    const decl_env = env.declarativeEnv().?;
    try addDisposableResource(vm.agent, &decl_env.disposable_resource_stack, value, kind, null);
}

fn executeDisposeResources(vm: *Vm) Agent.Error!void {
    const execution_context = vm.agent.runningExecutionContext();
    const env = execution_context.ecmascript_code.lexical_environment;
    const decl_env = env.declarativeEnv().?;
    _ = try disposeResources(
        vm.agent,
        &decl_env.disposable_resource_stack,
        @as(Agent.Error!Value, .undefined),
    );
}
