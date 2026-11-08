//! Pre-configured shapes for common objects.

const std = @import("std");

const builtins = @import("../../builtins.zig");
const execution = @import("../../execution.zig");
const types = @import("../../types.zig");

const Realm = execution.Realm;
const Object = types.Object;
const PropertyKey = types.PropertyKey;

const Shapes = @This();

array: ?*Object.Shape,
array_iterator: ?*Object.Shape,
ordinary_object: ?*Object.Shape,
ordinary_function: ?*Object.Shape,
ordinary_function_prototype: ?*Object.Shape,
unmapped_arguments_object: ?*Object.Shape,
mapped_arguments_object: ?*Object.Shape,
reg_exp_object: ?*Object.Shape,
reg_exp_exec_object: ?*Object.Shape,

pub const init: Shapes = blk: {
    var shapes: Shapes = undefined;
    const info = @typeInfo(Shapes).@"struct";
    for (info.field_names) |field_name| {
        @field(shapes, field_name) = null;
    }
    break :blk shapes;
};

pub fn Result(comptime field: std.meta.FieldEnum(Shapes)) type {
    return switch (field) {
        .array, .array_iterator, .ordinary_object => *Object.Shape,
        .ordinary_function => struct { *Object.Shape, OrdinaryFunctionOffsets },
        .ordinary_function_prototype => struct { *Object.Shape, OrdinaryFunctionPrototypeOffsets },
        .unmapped_arguments_object => struct { *Object.Shape, UnmappedArgumentsObjectOffsets },
        .mapped_arguments_object => struct { *Object.Shape, MappedArgumentsObjectOffsets },
        .reg_exp_object => struct { *Object.Shape, RegExpObjectOffsets },
        .reg_exp_exec_object => struct { *Object.Shape, RegExpExecObjectOffsets },
    };
}

pub fn getOrCreate(
    self: *Shapes,
    realm: *Realm,
    comptime field: std.meta.FieldEnum(Shapes),
) std.mem.Allocator.Error!Result(field) {
    const shape = @field(self, @tagName(field)) orelse blk: {
        const shape = switch (field) {
            .array => try createArray(realm),
            .array_iterator => try createArrayIterator(realm),
            .ordinary_object => try createOrdinaryObject(realm),
            .ordinary_function => try createOrdinaryFunction(realm),
            .ordinary_function_prototype => try createOrdinaryFunctionPrototype(realm),
            .unmapped_arguments_object => try createUnmappedArgumentsObject(realm),
            .mapped_arguments_object => try createMappedArgumentsObject(realm),
            .reg_exp_object => try createRegExpObject(realm),
            .reg_exp_exec_object => try createRegExpExecObject(realm),
        };
        @field(self, @tagName(field)) = shape;
        break :blk shape;
    };
    return switch (field) {
        .array,
        .array_iterator,
        .ordinary_object,
        => shape,
        else => .{ shape, .init },
    };
}

fn createArray(realm: *Realm) std.mem.Allocator.Error!*Object.Shape {
    const agent = realm.agent;
    const shape = try Object.Shape.init(agent.gc_allocator);
    shape.setInternalMethodsWithoutTransition(builtins.array.internal_methods);
    shape.setPrototypeWithoutTransition(try realm.intrinsic(.array_prototype));
    return shape;
}

fn createArrayIterator(realm: *Realm) std.mem.Allocator.Error!*Object.Shape {
    const agent = realm.agent;
    const shape = try Object.Shape.init(agent.gc_allocator);
    shape.setPrototypeWithoutTransition(try realm.intrinsic(.array_iterator_prototype));
    return shape;
}

fn createOrdinaryObject(realm: *Realm) std.mem.Allocator.Error!*Object.Shape {
    const agent = realm.agent;
    const shape = try Object.Shape.init(agent.gc_allocator);
    shape.setPrototypeWithoutTransition(try realm.intrinsic(.object_prototype));
    return shape;
}

const OrdinaryFunctionOffsets = struct {
    length: Object.Shape.Property.Offset,
    name: Object.Shape.Property.Offset,
    prototype: Object.Shape.Property.Offset,

    const init: OrdinaryFunctionOffsets = .{
        .length = @fromBackingInt(0),
        .name = @fromBackingInt(1),
        .prototype = @fromBackingInt(2),
    };
};

fn createOrdinaryFunction(realm: *Realm) std.mem.Allocator.Error!*Object.Shape {
    const agent = realm.agent;
    const shape = try Object.Shape.init(agent.gc_allocator);
    shape.setInternalMethodsWithoutTransition(builtins.ecmascript_function.internal_methods_constructor);
    shape.setPrototypeWithoutTransition(try realm.intrinsic(.function_prototype));
    try shape.setPropertyWithoutTransition(
        agent.gc_allocator,
        PropertyKey.from("length"),
        .{ .writable = false, .enumerable = false, .configurable = true },
        .value,
    );
    try shape.setPropertyWithoutTransition(
        agent.gc_allocator,
        PropertyKey.from("name"),
        .{ .writable = false, .enumerable = false, .configurable = true },
        .value,
    );
    try shape.setPropertyWithoutTransition(
        agent.gc_allocator,
        PropertyKey.from("prototype"),
        .{ .writable = true, .enumerable = false, .configurable = false },
        .value,
    );
    return shape;
}

const OrdinaryFunctionPrototypeOffsets = struct {
    constructor: Object.Shape.Property.Offset,

    pub const init: OrdinaryFunctionPrototypeOffsets = .{
        .constructor = @fromBackingInt(0),
    };
};

fn createOrdinaryFunctionPrototype(realm: *Realm) std.mem.Allocator.Error!*Object.Shape {
    const agent = realm.agent;
    const shape = try Object.Shape.init(agent.gc_allocator);
    shape.setPrototypeWithoutTransition(try realm.intrinsic(.object_prototype));
    try shape.setPropertyWithoutTransition(
        agent.gc_allocator,
        PropertyKey.from("constructor"),
        .builtin_default,
        .value,
    );
    return shape;
}

const UnmappedArgumentsObjectOffsets = struct {
    length: Object.Shape.Property.Offset,
    symbol_iterator: Object.Shape.Property.Offset,
    callee: Object.Shape.Property.Offset,

    const init: UnmappedArgumentsObjectOffsets = .{
        .length = @fromBackingInt(0),
        .symbol_iterator = @fromBackingInt(1),
        .callee = @fromBackingInt(2),
    };
};

fn createUnmappedArgumentsObject(realm: *Realm) std.mem.Allocator.Error!*Object.Shape {
    const agent = realm.agent;
    const shape = try Object.Shape.init(agent.gc_allocator);
    shape.setPrototypeWithoutTransition(try realm.intrinsic(.object_prototype));
    try shape.setPropertyWithoutTransition(
        agent.gc_allocator,
        PropertyKey.from("length"),
        .builtin_default,
        .value,
    );
    try shape.setPropertyWithoutTransition(
        agent.gc_allocator,
        PropertyKey.from(agent.well_known_symbols.iterator),
        .builtin_default,
        .value,
    );
    try shape.setPropertyWithoutTransition(
        agent.gc_allocator,
        PropertyKey.from("callee"),
        .none,
        .accessor,
    );
    return shape;
}

const MappedArgumentsObjectOffsets = struct {
    length: Object.Shape.Property.Offset,
    symbol_iterator: Object.Shape.Property.Offset,
    callee: Object.Shape.Property.Offset,

    const init: MappedArgumentsObjectOffsets = .{
        .length = @fromBackingInt(0),
        .symbol_iterator = @fromBackingInt(1),
        .callee = @fromBackingInt(2),
    };
};

fn createMappedArgumentsObject(realm: *Realm) std.mem.Allocator.Error!*Object.Shape {
    const agent = realm.agent;
    const shape = try Object.Shape.init(agent.gc_allocator);
    shape.setInternalMethodsWithoutTransition(builtins.arguments.internal_methods);
    shape.setPrototypeWithoutTransition(try realm.intrinsic(.object_prototype));
    try shape.setPropertyWithoutTransition(
        agent.gc_allocator,
        PropertyKey.from("length"),
        .builtin_default,
        .value,
    );
    try shape.setPropertyWithoutTransition(
        agent.gc_allocator,
        PropertyKey.from(agent.well_known_symbols.iterator),
        .builtin_default,
        .value,
    );
    try shape.setPropertyWithoutTransition(
        agent.gc_allocator,
        PropertyKey.from("callee"),
        .builtin_default,
        .value,
    );
    return shape;
}

const RegExpObjectOffsets = struct {
    last_index: Object.Shape.Property.Offset,

    const init: RegExpObjectOffsets = .{
        .last_index = @fromBackingInt(0),
    };
};

fn createRegExpObject(realm: *Realm) std.mem.Allocator.Error!*Object.Shape {
    const agent = realm.agent;
    const shape = try Object.Shape.init(agent.gc_allocator);
    shape.setPrototypeWithoutTransition(try realm.intrinsic(.reg_exp_prototype));
    try shape.setPropertyWithoutTransition(
        agent.gc_allocator,
        PropertyKey.from("lastIndex"),
        .{ .writable = true, .enumerable = false, .configurable = false },
        .value,
    );
    return shape;
}

const RegExpExecObjectOffsets = struct {
    index: Object.Shape.Property.Offset,
    input: Object.Shape.Property.Offset,
    groups: Object.Shape.Property.Offset,

    const init: RegExpExecObjectOffsets = .{
        .index = @fromBackingInt(0),
        .input = @fromBackingInt(1),
        .groups = @fromBackingInt(2),
    };
};

fn createRegExpExecObject(realm: *Realm) std.mem.Allocator.Error!*Object.Shape {
    const agent = realm.agent;
    const shape = try Object.Shape.init(agent.gc_allocator);
    shape.setInternalMethodsWithoutTransition(builtins.array.internal_methods);
    shape.setPrototypeWithoutTransition(try realm.intrinsic(.array_prototype));
    try shape.setPropertyWithoutTransition(
        agent.gc_allocator,
        PropertyKey.from("index"),
        .all,
        .value,
    );
    try shape.setPropertyWithoutTransition(
        agent.gc_allocator,
        PropertyKey.from("input"),
        .all,
        .value,
    );
    try shape.setPropertyWithoutTransition(
        agent.gc_allocator,
        PropertyKey.from("groups"),
        .all,
        .value,
    );
    return shape;
}
