const builtin = @import("builtin");
const std = @import("std");

const ast = @import("../language/ast.zig");

const Ir = @This();

name: []const u8,
instructions: std.MultiArrayList(Inst).Slice,
extra: []const u32,
strings: []const []const u8,
big_ints: []const std.math.big.int.Const,
functions: []const Function,
classes: []const Class,
liveness: std.bit_set.Dynamic,
live_ranges: []const LiveRange,

pub const Builder = @import("Ir/Builder.zig");
pub const LiveRange = @import("Ir/live_ranges.zig").LiveRange;

pub const ExtraIndex = enum(u32) { _ };

pub const StringIndex = enum(u32) {
    _,

    pub fn slice(index: StringIndex, ir: *const Ir) []const u8 {
        return ir.strings[@backingInt(index)];
    }
};

pub const BigIntIndex = enum(u16) {
    _,

    pub fn value(index: BigIntIndex, ir: *const Ir) std.math.big.int.Const {
        return ir.big_ints[@backingInt(index)];
    }
};

pub const Function = struct {
    source_range: ast.SourceRange,
    name: Name,
    parameters: ast.FormalParameters,
    body: ast.FunctionBody,
    kind: Kind,

    pub const Index = enum(u16) {
        _,

        pub fn ptr(index: Index, ir: *const Ir) *const Function {
            return &ir.functions[@backingInt(index)];
        }
    };

    pub const Name = union(enum) {
        none,
        identifier: StringIndex,
        default: StringIndex,
    };

    pub const Kind = enum {
        normal,
        arrow,
        generator,
        async,
        async_arrow,
        async_generator,
    };
};

pub const Class = struct {
    source_range: ast.SourceRange,
    name: Name,
    class_tail: ast.ClassTail,
    heritage: Inst.Ref,
    element_names: []const Inst.Ref,

    pub const Index = enum(u16) {
        _,

        pub fn ptr(index: Index, ir: *const Ir) *const Class {
            return &ir.classes[@backingInt(index)];
        }
    };

    pub const Name = union(enum) {
        none,
        identifier: StringIndex,
        default: StringIndex,
    };
};

pub const Inst = struct {
    tag: Tag,
    data: Data,

    pub const Tag = enum(u8) {
        undefined,
        null,
        true,
        false,
        number,
        string,
        big_int,
        create_array,
        array_push,
        array_spread,
        create_object,
        object_set,
        object_set_computed,
        object_set_prototype,
        object_spread,
        create_reg_exp,
        this,

        label,
        br,
        br_cond,
        exception_handler,

        to_boolean,
        to_number,
        to_numeric,
        to_string,
        to_object,
        increment,
        decrement,
        negate,
        bitwise_not,
        logical_not,
        is_nullish,
        typeof,
        typeof_binding,
        spread,

        add,
        sub,
        mul,
        div,
        rem,
        exp,
        shift_left,
        shift_right,
        shift_right_unsigned,
        bitwise_and,
        bitwise_or,
        bitwise_xor,

        lt,
        gt,
        lt_eq,
        gt_eq,
        instanceof,
        in,

        eq,
        not_eq,
        eq_strict,
        not_eq_strict,

        push_scope,
        push_catch_scope,
        push_var_scope,
        push_with_scope,
        pop_scope,
        create_var_binding,
        create_mutable_binding,
        create_immutable_binding,
        initialize_binding,

        get_binding,
        get_property,
        get_property_computed,
        get_property_indexed,
        set_binding,
        set_binding_strict,
        set_property,
        set_property_strict,
        set_property_computed,
        set_property_computed_strict,
        set_property_indexed,
        set_property_indexed_strict,
        delete_binding,
        delete_property,
        delete_property_strict,
        delete_property_computed,
        delete_property_computed_strict,
        delete_property_indexed,
        delete_property_indexed_strict,
        copy_data_properties,

        call,
        call_direct_eval,
        call_direct_eval_strict,
        construct,

        get_template_object,

        get_iterator,
        get_async_iterator,
        get_for_in_iterator,
        iterator_step,
        iterator_step_value,
        iterator_step_value_async,
        iterator_close,
        iterator_is_done,
        iterator_collect,

        throw,
        throw_reference_error,
        @"return",
        await,
        yield,
        yield_star,

        create_function,
        create_class,
        create_unmapped_arguments_object,
        create_mapped_arguments_object,
        get_argument,
        get_rest_arguments,
        get_new_target,

        as_getter,
        as_setter,

        super_call,
        get_super_property,
        get_super_property_computed,
        set_super_property,
        set_super_property_strict,
        set_super_property_computed,
        set_super_property_computed_strict,

        push_private_scope,
        pop_private_scope,
        create_private_element,
        resolve_private_element,
        get_private_element,
        set_private_element,
        has_private_element,

        import_call,
        get_import_meta,

        add_disposable_resource_sync,
        add_disposable_resource_async,
        dispose_resources,

        pub fn hint(tag: Tag) ?TypeHint {
            return switch (tag) {
                .undefined,
                => .undefined,

                .null,
                => .null,

                .true,
                .false,
                .to_boolean,
                .logical_not,
                .is_nullish,
                .lt,
                .lt_eq,
                .gt,
                .gt_eq,
                .instanceof,
                .in,
                .eq,
                .not_eq,
                .eq_strict,
                .not_eq_strict,
                .delete_binding,
                .delete_property,
                .delete_property_strict,
                .delete_property_computed,
                .delete_property_computed_strict,
                .delete_property_indexed,
                .delete_property_indexed_strict,
                .iterator_is_done,
                .has_private_element,
                => .boolean,

                .string,
                .to_string,
                .typeof,
                .typeof_binding,
                => .string,

                .number,
                .to_number,
                => .number,

                .big_int,
                => .big_int,

                .create_array,
                .create_object,
                .create_reg_exp,
                .to_object,
                .construct,
                .get_template_object,
                .create_function,
                .create_class,
                .create_unmapped_arguments_object,
                .create_mapped_arguments_object,
                .get_rest_arguments,
                .as_getter,
                .as_setter,
                .super_call,
                .get_iterator,
                .get_async_iterator,
                .get_for_in_iterator,
                .import_call,
                .get_import_meta,
                => .object,

                else => null,
            };
        }
    };

    pub const Data = union {
        none: void,
        ref: Ref,
        boolean: bool,
        number: f64,
        string: StringIndex,
        big_int: BigIntIndex,
        array: Array,
        object: Object,
        reg_exp: RegExp,
        br: Br,
        br_cond: ExtraIndex,
        exception_handler: ExtraIndex,
        binary: Binary,
        get_property: GetProperty,
        get_property_computed: GetPropertyComputed,
        get_property_indexed: GetPropertyIndexed,
        set_binding: SetBinding,
        set_property: ExtraIndex,
        set_property_computed: ExtraIndex,
        set_property_indexed: ExtraIndex,
        delete_property: DeleteProperty,
        delete_property_computed: DeletePropertyComputed,
        delete_property_indexed: DeletePropertyIndexed,
        copy_data_properties: ExtraIndex,
        call: ExtraIndex,
        construct: ExtraIndex,
        get_template_object: ExtraIndex,
        create_function: Function.Index,
        create_class: Class.Index,
        argument: u16,
        super_call: ExtraIndex,

        // Make sure we don't accidentally add a field to make this union
        // bigger than expected. Note that in safety builds, Zig is allowed
        // to insert a secret field for safety checks.
        comptime {
            if (!builtin.optimize.runtimeSafety()) {
                std.debug.assert(@sizeOf(Data) == 8);
            }
        }
    };

    pub const TypeHint = enum {
        undefined,
        null,
        boolean,
        string,
        number,
        big_int,
        object,
    };

    pub const data_tags = std.enums.directEnumArray(Tag, std.meta.FieldEnum(Data), 0, .{
        .undefined = .none,
        .null = .none,
        .true = .none,
        .false = .none,
        .number = .number,
        .string = .string,
        .big_int = .big_int,
        .create_array = .array,
        .array_push = .binary,
        .array_spread = .binary,
        .create_object = .object,
        .object_set = .set_property,
        .object_set_computed = .set_property_computed,
        .object_set_prototype = .binary,
        .object_spread = .binary,
        .create_reg_exp = .reg_exp,
        .this = .none,
        .label = .none,
        .br = .br,
        .br_cond = .br_cond,
        .exception_handler = .exception_handler,
        .to_boolean = .ref,
        .to_number = .ref,
        .to_numeric = .ref,
        .to_string = .ref,
        .to_object = .ref,
        .increment = .ref,
        .decrement = .ref,
        .negate = .ref,
        .bitwise_not = .ref,
        .logical_not = .ref,
        .is_nullish = .ref,
        .typeof = .ref,
        .typeof_binding = .string,
        .spread = .ref,
        .add = .binary,
        .sub = .binary,
        .mul = .binary,
        .div = .binary,
        .rem = .binary,
        .exp = .binary,
        .shift_left = .binary,
        .shift_right = .binary,
        .shift_right_unsigned = .binary,
        .bitwise_and = .binary,
        .bitwise_or = .binary,
        .bitwise_xor = .binary,
        .lt = .binary,
        .gt = .binary,
        .lt_eq = .binary,
        .gt_eq = .binary,
        .instanceof = .binary,
        .in = .binary,
        .eq = .binary,
        .not_eq = .binary,
        .eq_strict = .binary,
        .not_eq_strict = .binary,
        .push_scope = .none,
        .push_catch_scope = .none,
        .push_var_scope = .none,
        .push_with_scope = .ref,
        .pop_scope = .none,
        .create_var_binding = .string,
        .create_mutable_binding = .string,
        .create_immutable_binding = .string,
        .initialize_binding = .set_binding,
        .get_binding = .string,
        .get_property = .get_property,
        .get_property_computed = .get_property_computed,
        .get_property_indexed = .get_property_indexed,
        .set_binding = .set_binding,
        .set_binding_strict = .set_binding,
        .set_property = .set_property,
        .set_property_strict = .set_property,
        .set_property_computed = .set_property_computed,
        .set_property_computed_strict = .set_property_computed,
        .set_property_indexed = .set_property_indexed,
        .set_property_indexed_strict = .set_property_indexed,
        .delete_binding = .string,
        .delete_property = .delete_property,
        .delete_property_strict = .delete_property,
        .delete_property_computed = .delete_property_computed,
        .delete_property_computed_strict = .delete_property_computed,
        .delete_property_indexed = .delete_property_indexed,
        .delete_property_indexed_strict = .delete_property_indexed,
        .copy_data_properties = .copy_data_properties,
        .call = .call,
        .call_direct_eval = .call,
        .call_direct_eval_strict = .call,
        .construct = .construct,
        .get_template_object = .get_template_object,
        .get_iterator = .ref,
        .get_async_iterator = .ref,
        .get_for_in_iterator = .ref,
        .iterator_step = .ref,
        .iterator_step_value = .ref,
        .iterator_step_value_async = .ref,
        .iterator_close = .ref,
        .iterator_is_done = .ref,
        .iterator_collect = .ref,
        .throw = .ref,
        .throw_reference_error = .none,
        .@"return" = .ref,
        .await = .ref,
        .yield = .ref,
        .yield_star = .ref,
        .create_function = .create_function,
        .create_class = .create_class,
        .create_unmapped_arguments_object = .none,
        .create_mapped_arguments_object = .none,
        .get_argument = .argument,
        .get_rest_arguments = .argument,
        .get_new_target = .none,
        .as_getter = .ref,
        .as_setter = .ref,
        .super_call = .super_call,
        .get_super_property = .string,
        .get_super_property_computed = .ref,
        .set_super_property = .set_property,
        .set_super_property_strict = .set_property,
        .set_super_property_computed = .set_property_computed,
        .set_super_property_computed_strict = .set_property_computed,
        .push_private_scope = .none,
        .pop_private_scope = .none,
        .create_private_element = .string,
        .resolve_private_element = .string,
        .get_private_element = .get_property,
        .set_private_element = .set_property,
        .has_private_element = .binary,
        .import_call = .binary,
        .get_import_meta = .none,
        .add_disposable_resource_sync = .ref,
        .add_disposable_resource_async = .ref,
        .dispose_resources = .none,
    });

    // Inline data types (8 bytes)
    pub const Array = packed struct(u32) { len: u31, has_spread: bool };
    pub const Object = struct { property_count: u32 };
    pub const RegExp = struct { pattern: StringIndex, flags: StringIndex };
    pub const Br = struct { target: Ref, value: Ref };
    pub const Binary = struct { lhs: Ref, rhs: Ref };
    pub const GetProperty = struct { base: Ref, name: StringIndex };
    pub const GetPropertyComputed = struct { base: Ref, property: Ref };
    pub const GetPropertyIndexed = struct { base: Ref, index: u32 };
    pub const SetBinding = struct { name: StringIndex, value: Ref };
    pub const DeleteProperty = struct { base: Ref, name: StringIndex };
    pub const DeletePropertyComputed = struct { base: Ref, property: Ref };
    pub const DeletePropertyIndexed = struct { base: Ref, index: u32 };

    // Extra data types (>8 bytes)
    pub const BrCond = struct { condition: Ref, then_target: Ref, else_target: Ref };
    pub const ExceptionHandler = struct { start: Ref, end: Ref, target: Ref, scope_depth: u16 };
    pub const SetProperty = struct { base: Ref, name: StringIndex, value: Ref };
    pub const SetPropertyComputed = struct { base: Ref, property: Ref, value: Ref };
    pub const SetPropertyIndexed = struct { base: Ref, index: u32, value: Ref };
    pub const CopyDataProperties = struct { source: Ref, excluded_len: u32 };
    pub const Call = struct { callee: Ref, this_value: Ref, args_len: u32 };
    pub const Construct = struct { constructor: Ref, args_len: u32 };
    pub const GetTemplateObject = struct { raw: Ref, cooked: Ref, id: u32 };
    pub const SuperCall = struct { args_len: u32 };

    pub const Ref = enum(u32) {
        none,
        _,

        const static_len = 1;

        pub fn toIndex(ref: Ref) ?Inst.Index {
            if (@backingInt(ref) < static_len) return null;
            return @fromBackingInt(@backingInt(ref) - static_len);
        }
    };

    pub const Index = enum(u32) {
        start,
        _,

        pub fn inst(index: Index, ir: *const Ir) Inst {
            return ir.instructions.get(@backingInt(index));
        }

        pub fn liveness(index: Index, ir: *const Ir) bool {
            return ir.liveness.isSet(@backingInt(index));
        }

        pub fn liveRange(index: Index, ir: *const Ir) LiveRange {
            return ir.live_ranges[@backingInt(index)];
        }

        pub fn toRef(index: Index) Inst.Ref {
            return @fromBackingInt(Ref.static_len + @backingInt(index));
        }
    };

    pub fn print(inst: Inst, ir: *const Ir, terminal: std.Io.Terminal) PrintError!void {
        try terminal.writer.print("{t}", .{inst.tag});
        try printData(ir, inst.tag, inst.data, terminal);
    }

    pub fn collectRefs(
        inst: Inst,
        ir: *const Ir,
        gpa: std.mem.Allocator,
        uses: *std.ArrayList(Ref),
    ) std.mem.Allocator.Error!void {
        const data_tag = data_tags[@backingInt(inst.tag)];
        switch (data_tag) {
            .none,
            .boolean,
            .number,
            .string,
            .big_int,
            .array,
            .argument,
            .create_function,
            => {},
            .ref => try uses.append(gpa, inst.data.ref),
            .copy_data_properties => {
                const extra = ir.extraData(CopyDataProperties, inst.data.copy_data_properties);
                try uses.append(gpa, extra.data.source);
                const excluded = ir.refSlice(extra.end, extra.data.excluded_len);
                for (excluded) |prop| {
                    if (prop != .none) try uses.append(gpa, prop);
                }
            },
            .call,
            => {
                const extra = ir.extraData(Call, inst.data.call);
                try uses.append(gpa, extra.data.callee);
                if (extra.data.this_value != .none) try uses.append(gpa, extra.data.this_value);
                const args = ir.refSlice(extra.end, extra.data.args_len);
                for (args) |arg| try uses.append(gpa, arg);
            },
            .construct => {
                const extra = ir.extraData(Construct, inst.data.construct);
                try uses.append(gpa, extra.data.constructor);
                const args = ir.refSlice(extra.end, extra.data.args_len);
                for (args) |arg| try uses.append(gpa, arg);
            },
            .get_template_object => {
                const extra = ir.extraData(GetTemplateObject, inst.data.get_template_object);
                try uses.append(gpa, extra.data.raw);
                try uses.append(gpa, extra.data.cooked);
            },
            .create_class => {
                const class = ir.classes[@backingInt(inst.data.create_class)];
                if (class.heritage != .none) try uses.append(gpa, class.heritage);
                for (class.element_names) |name_ref| {
                    if (name_ref != .none) try uses.append(gpa, name_ref);
                }
            },
            .super_call => {
                const extra = ir.extraData(SuperCall, inst.data.super_call);
                const args = ir.refSlice(extra.end, extra.data.args_len);
                for (args) |arg| try uses.append(gpa, arg);
            },
            inline else => |dt| {
                const field_data = @field(inst.data, @tagName(dt));
                const FieldType = @TypeOf(field_data);
                if (FieldType == ExtraIndex) {
                    const ExtraType = switch (dt) {
                        .br_cond => BrCond,
                        .exception_handler => ExceptionHandler,
                        .set_property => SetProperty,
                        .set_property_computed => SetPropertyComputed,
                        .set_property_indexed => SetPropertyIndexed,
                        else => comptime unreachable,
                    };
                    const extra = ir.extraData(ExtraType, field_data);
                    const info = @typeInfo(ExtraType).@"struct";
                    inline for (info.field_names, info.field_types) |field_name, field_type| {
                        if (field_type == Ref) {
                            try uses.append(gpa, @field(extra.data, field_name));
                        }
                    }
                } else {
                    const info = @typeInfo(FieldType).@"struct";
                    inline for (info.field_names, info.field_types) |field_name, field_type| {
                        if (field_type == Ref) {
                            try uses.append(gpa, @field(field_data, field_name));
                        }
                    }
                }
            },
        }
    }
};

pub fn deinit(ir: *Ir, gpa: std.mem.Allocator) void {
    gpa.free(ir.name);
    ir.instructions.deinit(gpa);
    gpa.free(ir.extra);
    for (ir.strings) |string| gpa.free(string);
    gpa.free(ir.strings);
    for (ir.big_ints) |big_int| gpa.free(big_int.limbs);
    gpa.free(ir.big_ints);
    gpa.free(ir.functions);
    for (ir.classes) |class| gpa.free(class.element_names);
    gpa.free(ir.classes);
    ir.liveness.deinit(gpa);
    gpa.free(ir.live_ranges);
}

pub fn ExtraData(comptime T: type) type {
    return struct { data: T, end: ExtraIndex };
}

pub fn extraData(ir: *const Ir, comptime T: type, extra_index: ExtraIndex) ExtraData(T) {
    const info = @typeInfo(T).@"struct";
    var i: usize = @backingInt(extra_index);
    var result: T = undefined;
    inline for (info.field_names, info.field_types) |field_name, field_type| {
        @field(result, field_name) = switch (field_type) {
            u16 => @intCast(ir.extra[i]),
            u32 => ir.extra[i],
            Inst.Ref,
            StringIndex,
            => @fromBackingInt(ir.extra[i]),
            else => comptime unreachable,
        };
        i += 1;
    }
    return .{
        .data = result,
        .end = @fromBackingInt(@intCast(i)),
    };
}

pub fn refSlice(ir: *const Ir, start: ExtraIndex, len: u32) []const Inst.Ref {
    return @ptrCast(ir.extra[@backingInt(start)..][0..len]);
}

pub const PrintError = std.Io.Terminal.SetColorError;

pub fn print(ir: *const Ir, terminal: std.Io.Terminal) PrintError!void {
    try terminal.setColor(.bold);
    try terminal.writer.print("IR ({s})\n", .{ir.name});
    try terminal.setColor(.reset);
    for (0..ir.instructions.len) |i| {
        const inst = ir.instructions.get(i);
        const live_range = ir.live_ranges[i];
        const is_live = ir.liveness.isSet(i);

        var buf: [16]u8 = undefined;
        const label = std.mem.print(&buf, "%{d}", .{i}) catch unreachable;
        try terminal.writer.print("{s: >4}: ", .{label});

        try terminal.setColor(.dim);
        try terminal.writer.print("[{d: >3}..{d: <3}] {s: >4}", .{
            live_range.start,
            live_range.end,
            if (is_live) "" else "dead",
        });
        _ = try terminal.writer.splatByteAll(' ', 18);
        try terminal.setColor(.reset);

        try inst.print(ir, terminal);
        try terminal.writer.writeByte('\n');
    }
}

fn printData(
    ir: *const Ir,
    tag: Inst.Tag,
    data: Inst.Data,
    terminal: std.Io.Terminal,
) PrintError!void {
    const data_tag = Inst.data_tags[@backingInt(tag)];
    if (data_tag == .none) return;

    try terminal.writer.writeByte(' ');
    switch (data_tag) {
        .none => {},
        inline .boolean,
        .number,
        .string,
        .big_int,
        .array,
        .ref,
        .argument,
        .create_function,
        => |dt| {
            const field_data = @field(data, @tagName(dt));
            try printField(ir, field_data, terminal);
        },
        .copy_data_properties => {
            const extra = ir.extraData(Inst.CopyDataProperties, data.copy_data_properties);
            try printField(ir, extra.data.source, terminal);
            try terminal.writer.writeAll(", [");
            const excluded = ir.refSlice(extra.end, extra.data.excluded_len);
            for (excluded, 0..) |prop, j| {
                if (j > 0) try terminal.writer.writeAll(", ");
                try printField(ir, prop, terminal);
            }
            try terminal.writer.writeByte(']');
        },
        .call => {
            const extra = ir.extraData(Inst.Call, data.call);
            try printField(ir, extra.data.callee, terminal);
            try terminal.writer.writeAll(", ");
            try printField(ir, extra.data.this_value, terminal);
            try terminal.writer.writeAll(", [");
            const args = ir.refSlice(extra.end, extra.data.args_len);
            for (args, 0..) |arg, j| {
                if (j > 0) try terminal.writer.writeAll(", ");
                try printField(ir, arg, terminal);
            }
            try terminal.writer.writeByte(']');
        },
        .construct => {
            const extra = ir.extraData(Inst.Construct, data.construct);
            try printField(ir, extra.data.constructor, terminal);
            try terminal.writer.writeAll(", [");
            const args = ir.refSlice(extra.end, extra.data.args_len);
            for (args, 0..) |arg, j| {
                if (j > 0) try terminal.writer.writeAll(", ");
                try printField(ir, arg, terminal);
            }
            try terminal.writer.writeByte(']');
        },
        .get_template_object => {
            const extra = ir.extraData(Inst.GetTemplateObject, data.get_template_object);
            try printField(ir, extra.data.raw, terminal);
            try terminal.writer.writeAll(", ");
            try printField(ir, extra.data.cooked, terminal);
            try terminal.writer.writeAll(", ");
            try printField(ir, extra.data.id, terminal);
        },
        .create_class => {
            const class = data.create_class.ptr(ir);
            try printField(ir, data.create_class, terminal);
            try terminal.writer.writeAll(", ");
            try printField(ir, class.heritage, terminal);
            if (class.element_names.len > 0) {
                try terminal.writer.writeAll(", [");
                for (class.element_names, 0..) |name_ref, j| {
                    if (j > 0) try terminal.writer.writeAll(", ");
                    try printField(ir, name_ref, terminal);
                }
                try terminal.writer.writeByte(']');
            }
        },
        .super_call => {
            const extra = ir.extraData(Inst.SuperCall, data.super_call);
            try terminal.writer.writeByte('[');
            const args = ir.refSlice(extra.end, extra.data.args_len);
            for (args, 0..) |arg, j| {
                if (j > 0) try terminal.writer.writeAll(", ");
                try printField(ir, arg, terminal);
            }
            try terminal.writer.writeByte(']');
        },
        inline else => |dt| {
            const field_data = @field(data, @tagName(dt));
            const FieldType = @TypeOf(field_data);
            if (FieldType == ExtraIndex) {
                const ExtraType = switch (dt) {
                    .br_cond => Inst.BrCond,
                    .exception_handler => Inst.ExceptionHandler,
                    .set_property => Inst.SetProperty,
                    .set_property_computed => Inst.SetPropertyComputed,
                    .set_property_indexed => Inst.SetPropertyIndexed,
                    else => comptime unreachable,
                };
                const extra = ir.extraData(ExtraType, field_data);
                const info = @typeInfo(ExtraType).@"struct";
                inline for (info.field_names, 0..) |field_name, j| {
                    if (j > 0) try terminal.writer.writeAll(", ");
                    try printField(ir, @field(extra.data, field_name), terminal);
                }
            } else {
                const info = @typeInfo(FieldType).@"struct";
                inline for (info.field_names, 0..) |field_name, j| {
                    if (j > 0) try terminal.writer.writeAll(", ");
                    try printField(ir, @field(field_data, field_name), terminal);
                }
            }
        },
    }
}

fn printField(ir: *const Ir, value: anytype, terminal: std.Io.Terminal) PrintError!void {
    const T = @TypeOf(value);
    switch (T) {
        bool => {
            try terminal.setColor(.blue);
            try terminal.writer.print("{}", .{value});
            try terminal.setColor(.reset);
        },
        u16,
        u32,
        i32,
        f64,
        => {
            try terminal.setColor(.magenta);
            try terminal.writer.print("{}", .{value});
            try terminal.setColor(.reset);
        },
        Inst.Ref => if (value.toIndex()) |index| {
            try terminal.setColor(.blue);
            try terminal.writer.print("%{d}", .{@backingInt(index)});
            try terminal.setColor(.reset);
        } else {
            try terminal.setColor(.dim);
            try terminal.writer.print("none", .{});
            try terminal.setColor(.reset);
        },
        Inst.Array => {
            try terminal.setColor(.magenta);
            try terminal.writer.print("{}", .{value.len});
            try terminal.setColor(.reset);
            if (value.has_spread) {
                try terminal.setColor(.dim);
                try terminal.writer.writeAll(" (spread)");
                try terminal.setColor(.reset);
            }
        },
        // ExtraIndex should be handled in `printData()`
        StringIndex => {
            const str = value.slice(ir);
            try terminal.setColor(.yellow);
            try terminal.writer.print("@{d}", .{@backingInt(value)});
            try terminal.setColor(.reset);
            try terminal.writer.writeAll(" (");
            try terminal.setColor(.green);
            try terminal.writer.print("\"{s}\"", .{str});
            try terminal.setColor(.reset);
            try terminal.writer.writeByte(')');
        },
        BigIntIndex => {
            const big_int = value.value(ir);
            try terminal.setColor(.yellow);
            try terminal.writer.print("@{d}", .{@backingInt(value)});
            try terminal.setColor(.reset);
            try terminal.writer.writeAll(" (");
            try terminal.setColor(.magenta);
            try big_int.formatNumber(terminal.writer, .{});
            try terminal.writer.writeByte('n');
            try terminal.setColor(.reset);
            try terminal.writer.writeByte(')');
        },
        Function.Index,
        Class.Index,
        => {
            try terminal.setColor(.yellow);
            try terminal.writer.print("@{d}", .{@backingInt(value)});
            try terminal.setColor(.reset);
        },
        else => comptime unreachable,
    }
}
