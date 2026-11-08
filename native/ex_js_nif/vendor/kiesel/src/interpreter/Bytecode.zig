const std = @import("std");

const ast = @import("../language/ast.zig");

const Bytecode = @This();

name: []const u8,
code: []const u8,
local_count: u16,
register_count: u16,
get_property_ic_count: u16,
get_property_computed_ic_count: u16,
set_property_ic_count: u16,
set_property_computed_ic_count: u16,
strings: []const []const u8,
big_ints: []const std.math.big.int.Const,
functions: []const Function,
classes: []const Class,
exception_handlers: []const ExceptionHandler,

pub const Builder = @import("Bytecode/Builder.zig");

pub const Local = enum(u16) { _ };

pub const Reg = enum(u16) {
    /// Used for `return`/`yield` instructions to indicate no register
    none = std.math.maxInt(u16),
    _,
};

pub const StringIndex = enum(u32) {
    _,

    pub fn slice(index: StringIndex, bc: *const Bytecode) []const u8 {
        return bc.strings[@backingInt(index)];
    }
};

pub const BigIntIndex = enum(u16) {
    _,

    pub fn value(index: BigIntIndex, bc: *const Bytecode) std.math.big.int.Const {
        return bc.big_ints[@backingInt(index)];
    }
};

pub const GetPropertyIcIndex = enum(u16) { _ };
pub const GetPropertyComputedIcIndex = enum(u16) { _ };
pub const SetPropertyIcIndex = enum(u16) { _ };
pub const SetPropertyComputedIcIndex = enum(u16) { _ };

pub const Function = struct {
    source_range: ast.SourceRange,
    name: Name,
    parameters: ast.FormalParameters,
    body: ast.FunctionBody,
    kind: Kind,

    pub const Index = enum(u16) {
        _,

        pub fn ptr(index: Index, bc: *const Bytecode) *const Function {
            return &bc.functions[@backingInt(index)];
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
    heritage: Reg,
    element_names: []const Reg,

    pub const Index = enum(u16) {
        _,

        pub fn ptr(index: Index, bc: *const Bytecode) *const Class {
            return &bc.classes[@backingInt(index)];
        }
    };

    pub const Name = union(enum) {
        none,
        identifier: StringIndex,
        default: StringIndex,
    };
};

pub const ExceptionHandler = struct {
    start: u32,
    end: u32,
    target: u32,
    exception_reg: Reg,
    scope_depth: u16,
};

pub const Inst = struct {
    tag: Tag,
    data: Data,

    pub const Tag = enum(u8) {
        jump,
        jump_if_true,
        jump_if_false,

        load_undefined,
        load_null,
        load_true,
        load_false,
        load_number_i8,
        load_number_i32,
        load_number_f64,
        load_string,
        load_big_int,
        move,

        create_array,
        array_push,
        array_push_hole,
        array_set,
        array_spread,

        create_object,
        object_set,
        object_set_computed,
        object_set_getter,
        object_set_getter_computed,
        object_set_setter,
        object_set_setter_computed,
        object_set_prototype,
        object_spread,

        create_reg_exp,

        resolve_this_binding,

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
        typeof_local,
        typeof_binding,

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

        push_catch_scope,
        push_scope,
        push_var_scope,
        push_with_scope,
        pop_scope,
        create_var_binding,
        create_mutable_binding,
        create_immutable_binding,
        initialize_binding,

        get_local,
        get_binding,
        get_property,
        get_property_computed,
        get_property_indexed,
        set_local,
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
        call0,
        call1,
        call2,
        call_property,
        call_property0,
        call_property1,
        call_property2,
        call_direct_eval,
        call_direct_eval_strict,
        construct,
        construct0,
        construct1,
        construct2,

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
        set_home_object,
        create_unmapped_arguments_object,
        create_mapped_arguments_object,
        get_argument,
        get_rest_arguments,
        get_new_target,

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
    };

    pub const Data = union {
        none: void,
        i32: i32,
        reg: Reg,
        reg_reg: struct { Reg, Reg },
        reg_reg_reg: struct { Reg, Reg, Reg },
        reg_reg_reg_reg: struct { Reg, Reg, Reg, Reg },
        reg_reg_reg_reg_reg: struct { Reg, Reg, Reg, Reg, Reg },
        reg_reg_u32: struct { Reg, Reg, u32 },
        reg_reg_reg_u16: struct { Reg, Reg, Reg, u16 },
        reg_i8: struct { Reg, i8 },
        reg_u16: struct { Reg, u16 },
        reg_i32: struct { Reg, i32 },
        reg_u32: struct { Reg, u32 },
        reg_f64: struct { Reg, f64 },
        reg_local: struct { Reg, Local },
        reg_string: struct { Reg, StringIndex },
        reg_reg_string: struct { Reg, Reg, StringIndex },
        reg_big_int: struct { Reg, BigIntIndex },
        reg_string_reg: struct { Reg, StringIndex, Reg },
        reg_string_string: struct { Reg, StringIndex, StringIndex },
        reg_reg_string_get_property_ic: struct { Reg, Reg, StringIndex, GetPropertyIcIndex },
        reg_reg_reg_get_property_computed_ic: struct { Reg, Reg, Reg, GetPropertyComputedIcIndex },
        reg_reg_string_set_property_ic: struct { Reg, Reg, StringIndex, SetPropertyIcIndex },
        reg_reg_reg_set_property_computed_ic: struct { Reg, Reg, Reg, SetPropertyComputedIcIndex },
        reg_function: struct { Reg, Function.Index },
        reg_class: struct { Reg, Class.Index },
        local_reg: struct { Local, Reg },
        string: StringIndex,
        string_reg: struct { StringIndex, Reg },
    };

    pub const data_tags = blk: {
        @setEvalBranchQuota(2_000);
        break :blk std.enums.directEnumArray(Tag, std.meta.FieldEnum(Data), 0, .{
            .jump = .i32,
            .jump_if_true = .reg_i32,
            .jump_if_false = .reg_i32,
            .load_undefined = .reg,
            .load_null = .reg,
            .load_true = .reg,
            .load_false = .reg,
            .load_number_i8 = .reg_i8,
            .load_number_i32 = .reg_i32,
            .load_number_f64 = .reg_f64,
            .load_string = .reg_string,
            .load_big_int = .reg_big_int,
            .move = .reg_reg,
            .create_array = .reg_u32,
            .array_push = .reg_reg,
            .array_push_hole = .reg,
            .array_set = .reg_reg_u32,
            .array_spread = .reg_reg,
            .create_object = .reg_u32,
            .object_set = .reg_string_reg,
            .object_set_computed = .reg_reg_reg,
            .object_set_getter = .reg_string_reg,
            .object_set_getter_computed = .reg_reg_reg,
            .object_set_setter = .reg_string_reg,
            .object_set_setter_computed = .reg_reg_reg,
            .object_set_prototype = .reg_reg,
            .object_spread = .reg_reg,
            .create_reg_exp = .reg_string_string,
            .resolve_this_binding = .reg,
            .to_boolean = .reg_reg,
            .to_number = .reg_reg,
            .to_numeric = .reg_reg,
            .to_string = .reg_reg,
            .to_object = .reg_reg,
            .increment = .reg_reg,
            .decrement = .reg_reg,
            .negate = .reg_reg,
            .bitwise_not = .reg_reg,
            .logical_not = .reg_reg,
            .is_nullish = .reg_reg,
            .typeof = .reg_reg,
            .typeof_local = .reg_local,
            .typeof_binding = .reg_string,
            .add = .reg_reg_reg,
            .sub = .reg_reg_reg,
            .mul = .reg_reg_reg,
            .div = .reg_reg_reg,
            .rem = .reg_reg_reg,
            .exp = .reg_reg_reg,
            .shift_left = .reg_reg_reg,
            .shift_right = .reg_reg_reg,
            .shift_right_unsigned = .reg_reg_reg,
            .bitwise_and = .reg_reg_reg,
            .bitwise_or = .reg_reg_reg,
            .bitwise_xor = .reg_reg_reg,
            .lt = .reg_reg_reg,
            .gt = .reg_reg_reg,
            .lt_eq = .reg_reg_reg,
            .gt_eq = .reg_reg_reg,
            .instanceof = .reg_reg_reg,
            .in = .reg_reg_reg,
            .eq = .reg_reg_reg,
            .not_eq = .reg_reg_reg,
            .eq_strict = .reg_reg_reg,
            .not_eq_strict = .reg_reg_reg,
            .push_scope = .none,
            .push_catch_scope = .none,
            .push_var_scope = .none,
            .push_with_scope = .reg,
            .pop_scope = .none,
            .create_var_binding = .string,
            .create_mutable_binding = .string,
            .create_immutable_binding = .string,
            .initialize_binding = .string_reg,
            .get_local = .reg_local,
            .get_binding = .reg_string,
            .get_property = .reg_reg_string_get_property_ic,
            .get_property_computed = .reg_reg_reg_get_property_computed_ic,
            .get_property_indexed = .reg_reg_u32,
            .set_local = .local_reg,
            .set_binding = .string_reg,
            .set_binding_strict = .string_reg,
            .set_property = .reg_reg_string_set_property_ic,
            .set_property_strict = .reg_reg_string_set_property_ic,
            .set_property_computed = .reg_reg_reg_set_property_computed_ic,
            .set_property_computed_strict = .reg_reg_reg_set_property_computed_ic,
            .set_property_indexed = .reg_reg_u32,
            .set_property_indexed_strict = .reg_reg_u32,
            .delete_binding = .reg_string,
            .delete_property = .reg_reg_string,
            .delete_property_strict = .reg_reg_string,
            .delete_property_computed = .reg_reg_reg,
            .delete_property_computed_strict = .reg_reg_reg,
            .delete_property_indexed = .reg_reg_u32,
            .delete_property_indexed_strict = .reg_reg_u32,
            .copy_data_properties = .reg_reg_reg,
            .call = .reg_reg_reg,
            .call0 = .reg_reg,
            .call1 = .reg_reg_reg,
            .call2 = .reg_reg_reg_reg,
            .call_property = .reg_reg_reg_reg,
            .call_property0 = .reg_reg_reg,
            .call_property1 = .reg_reg_reg_reg,
            .call_property2 = .reg_reg_reg_reg_reg,
            .call_direct_eval = .reg_reg_reg,
            .call_direct_eval_strict = .reg_reg_reg,
            .construct = .reg_reg_reg,
            .construct0 = .reg_reg,
            .construct1 = .reg_reg_reg,
            .construct2 = .reg_reg_reg_reg,
            .get_template_object = .reg_reg_reg_u16,
            .get_iterator = .reg_reg,
            .get_async_iterator = .reg_reg,
            .get_for_in_iterator = .reg_reg,
            .iterator_step = .reg_reg,
            .iterator_step_value = .reg_reg,
            .iterator_step_value_async = .reg_reg,
            .iterator_close = .reg,
            .iterator_is_done = .reg_reg,
            .iterator_collect = .reg_reg,
            .throw = .reg,
            .throw_reference_error = .none,
            .@"return" = .reg,
            .await = .reg_reg,
            .yield = .reg_reg,
            .yield_star = .reg_reg,
            .create_function = .reg_function,
            .create_class = .reg_class,
            .set_home_object = .reg_reg,
            .create_unmapped_arguments_object = .reg,
            .create_mapped_arguments_object = .reg,
            .get_argument = .reg_u16,
            .get_rest_arguments = .reg_u16,
            .get_new_target = .reg,
            .super_call = .reg_reg,
            .get_super_property = .reg_string,
            .get_super_property_computed = .reg_reg,
            .set_super_property = .reg_string,
            .set_super_property_strict = .reg_string,
            .set_super_property_computed = .reg_reg,
            .set_super_property_computed_strict = .reg_reg,
            .push_private_scope = .none,
            .pop_private_scope = .none,
            .create_private_element = .reg_string,
            .resolve_private_element = .reg_string,
            .get_private_element = .reg_reg_string,
            .set_private_element = .reg_string_reg,
            .has_private_element = .reg_reg_reg,
            .import_call = .reg_reg_reg,
            .get_import_meta = .reg,
            .add_disposable_resource_sync = .reg,
            .add_disposable_resource_async = .reg,
            .dispose_resources = .none,
        });
    };

    pub fn print(inst: Inst, bc: *const Bytecode, terminal: std.Io.Terminal) PrintError!void {
        try terminal.writer.print("{t}", .{inst.tag});
        try printData(bc, inst.tag, inst.data, terminal);
    }

    /// Decode an instruction from the given bytecode slice.
    ///
    /// Returns a tuple containing the decoded instruction and the number of
    /// consumed bytes, or `null` if decoding fails.
    pub fn decode(code: []const u8) ?struct { Inst, u4 } {
        if (code.len == 0) return null;
        const tag = std.enums.fromInt(Tag, code[0]) orelse return null;
        const size = encodedSize(tag);
        if (code.len < size) return null;
        const data = decodeData(code[1..], tag);
        const inst: Inst = .{ .tag = tag, .data = data };
        return .{ inst, size };
    }

    /// Decode an instruction tag from the given bytecode slice.
    ///
    /// Assumes the slice is non-empty and the first byte is a valid tag.
    pub inline fn decodeTag(code: []const u8) Tag {
        return @fromBackingInt(code[0]);
    }

    /// Decode instruction data from the given bytecode slice.
    ///
    /// Assumes the slice has enough bytes.
    pub inline fn decodeData(code: []const u8, tag: Tag) Data {
        const data_tag = data_tags[@backingInt(tag)];
        switch (data_tag) {
            inline else => |field| {
                const FieldType = @TypeOf(@field(@as(Data, undefined), @tagName(field)));
                const type_info = @typeInfo(FieldType);

                if (FieldType == void) {
                    return @unionInit(Data, @tagName(field), {});
                }

                if (type_info == .@"struct") {
                    var result: FieldType = undefined;
                    var offset: usize = 0;
                    const info = type_info.@"struct";
                    inline for (info.field_types, 0..) |field_type, i| {
                        result[i] = decodeField(field_type, code[offset..]);
                        offset += @sizeOf(field_type);
                    }
                    return @unionInit(Data, @tagName(field), result);
                }

                return @unionInit(Data, @tagName(field), decodeField(FieldType, code));
            },
        }
    }

    inline fn decodeField(comptime T: type, code: []const u8) T {
        return switch (T) {
            Reg,
            Local,
            BigIntIndex,
            Function.Index,
            Class.Index,
            GetPropertyIcIndex,
            GetPropertyComputedIcIndex,
            SetPropertyIcIndex,
            SetPropertyComputedIcIndex,
            => @fromBackingInt(std.mem.readInt(u16, code[0..2], .little)),
            StringIndex => @fromBackingInt(std.mem.readInt(u32, code[0..4], .little)),
            i8 => @bitCast(code[0]),
            u16 => std.mem.readInt(u16, code[0..2], .little),
            i32 => std.mem.readInt(i32, code[0..4], .little),
            u32 => std.mem.readInt(u32, code[0..4], .little),
            f64 => @bitCast(std.mem.readInt(u64, code[0..8], .little)),
            void => {},
            else => comptime unreachable,
        };
    }

    pub fn encode(inst: Inst, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.writeInt(u8, @backingInt(inst.tag), .little);
        const data_tag = data_tags[@backingInt(inst.tag)];
        switch (data_tag) {
            inline else => |field| {
                const field_value = @field(inst.data, @tagName(field));
                const FieldType = @TypeOf(field_value);
                const type_info = @typeInfo(FieldType);

                if (FieldType == void) return;

                if (type_info == .@"struct") {
                    const info = type_info.@"struct";
                    inline for (info.field_types, 0..) |field_type, i| {
                        try encodeField(field_type, field_value[i], writer);
                    }
                } else {
                    try encodeField(FieldType, field_value, writer);
                }
            },
        }
    }

    fn encodeField(comptime T: type, value: T, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (T) {
            Reg,
            Local,
            BigIntIndex,
            Function.Index,
            Class.Index,
            GetPropertyIcIndex,
            GetPropertyComputedIcIndex,
            SetPropertyIcIndex,
            SetPropertyComputedIcIndex,
            => try writer.writeInt(u16, @backingInt(value), .little),
            StringIndex => try writer.writeInt(u32, @backingInt(value), .little),
            i8 => try writer.writeByte(@bitCast(value)),
            u16 => try writer.writeInt(u16, value, .little),
            i32 => try writer.writeInt(i32, value, .little),
            u32 => try writer.writeInt(u32, value, .little),
            f64 => try writer.writeInt(u64, @bitCast(value), .little),
            void => {},
            else => comptime unreachable,
        }
    }

    pub fn encodedSize(tag: Tag) u4 {
        return encoded_sizes[@backingInt(tag)];
    }

    const encoded_sizes = blk: {
        var sizes: [@typeInfo(Tag).@"enum".field_names.len]u4 = @splat(1);
        for (0..sizes.len) |i| {
            const FieldType = @TypeOf(@field(@as(Data, undefined), @tagName(data_tags[i])));
            const type_info = @typeInfo(FieldType);
            if (type_info == .@"struct") {
                const info = type_info.@"struct";
                for (info.field_types) |field_type| {
                    sizes[i] += @sizeOf(field_type);
                }
            } else {
                sizes[i] += @sizeOf(FieldType);
            }
        }
        break :blk sizes;
    };
};

pub fn deinit(bc: *const Bytecode, gpa: std.mem.Allocator) void {
    gpa.free(bc.name);
    gpa.free(bc.code);
    for (bc.strings) |string| gpa.free(string);
    gpa.free(bc.strings);
    for (bc.big_ints) |big_int| gpa.free(big_int.limbs);
    gpa.free(bc.big_ints);
    gpa.free(bc.functions);
    for (bc.classes) |class| gpa.free(class.element_names);
    gpa.free(bc.classes);
    gpa.free(bc.exception_handlers);
}

pub fn findExceptionHandler(bc: *const Bytecode, offset: u32) ?ExceptionHandler {
    var best_handler: ?ExceptionHandler = null;
    var best_span: u32 = 0;
    for (bc.exception_handlers) |handler| {
        if (offset < handler.start or offset >= handler.end) continue;
        const span = handler.end - handler.start;
        if (best_handler == null or span <= best_span) {
            best_handler = handler;
            best_span = span;
        }
    }
    return best_handler;
}

pub const Iterator = struct {
    code: []const u8,
    offset: u32,

    pub const Entry = struct {
        offset: u32,
        inst: Bytecode.Inst,
    };

    pub fn next(it: *Iterator) error{InvalidInstruction}!?Entry {
        if (it.offset >= it.code.len) return null;
        const inst, const size = Bytecode.Inst.decode(it.code[it.offset..]) orelse {
            return error.InvalidInstruction;
        };
        const offset = it.offset;
        it.offset += size;
        return .{ .offset = offset, .inst = inst };
    }
};

pub fn iterator(bc: *const Bytecode) Iterator {
    return .{
        .code = bc.code,
        .offset = 0,
    };
}

pub const PrintError = std.Io.Terminal.SetColorError;

pub fn print(bc: *const Bytecode, terminal: std.Io.Terminal) PrintError!void {
    try terminal.setColor(.bold);
    try terminal.writer.print("Bytecode ({s})\n", .{bc.name});
    try terminal.setColor(.reset);
    var it = bc.iterator();
    while (it.next() catch |err| switch (err) {
        error.InvalidInstruction => {
            try terminal.setColor(.red);
            try terminal.writer.print("Invalid instruction at offset {d}\n", .{it.offset});
            try terminal.setColor(.reset);
            return;
        },
    }) |entry| {
        const size = it.offset - entry.offset;

        try terminal.writer.print("{d: >4}: ", .{entry.offset});

        try terminal.setColor(.dim);
        for (bc.code[entry.offset..][0..size]) |byte| {
            try terminal.writer.print("{x:0>2} ", .{byte});
        }
        _ = try terminal.writer.splatByteAll(' ', (11 - size) * 3);
        try terminal.setColor(.reset);

        try entry.inst.print(bc, terminal);
        try terminal.writer.writeByte('\n');
    }

    if (bc.exception_handlers.len > 0) {
        try terminal.writer.writeByte('\n');
        try terminal.setColor(.bold);
        try terminal.writer.writeAll("Exception handlers\n");
        try terminal.setColor(.reset);

        for (bc.exception_handlers) |handler| {
            try terminal.writer.print("  [{d: >4}..{d: <4}) → {d: >4}, ", .{
                handler.start,
                handler.end,
                handler.target,
            });
            try printField(bc, handler.exception_reg, terminal);
            try terminal.writer.print(", {d}\n", .{handler.scope_depth});
        }
    }
}

fn printData(
    bc: *const Bytecode,
    tag: Inst.Tag,
    data: Inst.Data,
    terminal: std.Io.Terminal,
) PrintError!void {
    const data_tag = Inst.data_tags[@backingInt(tag)];
    if (data_tag == .none) return;
    switch (tag) {
        .@"return" => if (data.reg == .none) return,
        .yield => if (data.reg_reg[1] == .none) return,
        else => {},
    }

    try terminal.writer.writeByte(' ');
    switch (data_tag) {
        .none => {},
        inline .i32,
        .reg,
        .string,
        => |dt| {
            const field_data = @field(data, @tagName(dt));
            try printField(bc, field_data, terminal);
        },
        inline else => |dt| {
            const field_data = @field(data, @tagName(dt));
            const info = @typeInfo(@TypeOf(field_data)).@"struct";
            inline for (info.field_names, 0..) |field_name, i| {
                if (i > 0) try terminal.writer.writeAll(", ");
                const value = @field(field_data, field_name);
                try printField(bc, value, terminal);
            }
        },
    }
}

fn printField(
    bc: *const Bytecode,
    value: anytype,
    terminal: std.Io.Terminal,
) PrintError!void {
    const T = @TypeOf(value);
    switch (T) {
        i8,
        u16,
        i32,
        u32,
        f64,
        => {
            try terminal.setColor(.magenta);
            try terminal.writer.print("{}", .{value});
            try terminal.setColor(.reset);
        },
        Local => {
            try terminal.setColor(.cyan);
            try terminal.writer.print("l{d}", .{@backingInt(value)});
            try terminal.setColor(.reset);
        },
        Reg => {
            try terminal.setColor(.blue);
            try terminal.writer.print("r{d}", .{@backingInt(value)});
            try terminal.setColor(.reset);
        },
        StringIndex => {
            const str = value.slice(bc);
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
            const big_int = value.value(bc);
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
        GetPropertyIcIndex,
        GetPropertyComputedIcIndex,
        SetPropertyIcIndex,
        SetPropertyComputedIcIndex,
        => {
            try terminal.setColor(.yellow);
            try terminal.writer.print("@{d}", .{@backingInt(value)});
            try terminal.setColor(.reset);
        },
        else => comptime unreachable,
    }
}
