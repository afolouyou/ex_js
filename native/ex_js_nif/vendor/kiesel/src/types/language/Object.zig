//! 6.1.7 The Object Type
//! https://tc39.es/ecma262/#sec-object-type

const std = @import("std");

const builtins = @import("../../builtins.zig");
const execution = @import("../../execution.zig");
const spec = @import("../spec.zig");
const types = @import("../../types.zig");
const utils = @import("../../utils.zig");

const Agent = execution.Agent;
const Arguments = types.Arguments;
const Behaviour = builtins.builtin_function.Behaviour;
const ClassConstructorFields = builtins.builtin_function.ClassConstructorFields;
const ClassFieldDefinition = types.ClassFieldDefinition;
const PreferredType = Value.PreferredType;
const PrivateElement = types.PrivateElement;
const PrivateName = types.PrivateName;
const PropertyDescriptor = spec.PropertyDescriptor;
const Realm = execution.Realm;
const String = types.String;
const Value = types.Value;
const createArrayFromList = types.createArrayFromList;
const createBuiltinFunction = builtins.createBuiltinFunction;
const noexcept = utils.noexcept;
const ordinaryObjectCreate = builtins.ordinaryObjectCreate;
const sameValue = types.sameValue;
const validateNonRevokedProxy = builtins.validateNonRevokedProxy;

pub const CompletePropertyDescriptor = @import("Object/CompletePropertyDescriptor.zig");
pub const IndexedProperties = @import("Object/IndexedProperties.zig");
pub const InternalMethods = @import("Object/InternalMethods.zig");
pub const PropertyKey = @import("Object/property_key.zig").PropertyKey;
pub const Shape = @import("Object/Shape.zig");

const Object = @This();

tag: Tag,
shape: *Shape,
properties: Properties,
extra_data: ?*ExtraData,

pub const Properties = union(enum) {
    fixed: [4]Value,
    dynamic: std.ArrayList(Value),

    pub const empty: Properties = .{ .fixed = undefined };
};

pub const ExtraData = struct {
    /// [[PrivateElements]]
    private_elements: PrivateName.HashMap(PrivateElement),
    lazy_properties: PropertyKey.HashMap(LazyProperty),
    indexed_properties: Object.IndexedProperties,
};

pub const LazyProperty = struct {
    pub const Initializer = union(enum) {
        value: *const fn (*Agent, *Realm) std.mem.Allocator.Error!Value,
        accessor: *const fn (*Agent, *Realm) std.mem.Allocator.Error!Accessor,
    };

    realm: *Realm,
    initializer: Initializer,
};

pub const Accessor = struct {
    getter: ?*Object,
    setter: ?*Object,
};

pub const Tag = enum(u16) {
    // ECMA-262
    arguments,
    array,
    array_buffer,
    array_iterator,
    async_disposable_stack,
    async_from_sync_iterator,
    async_generator,
    big_int,
    boolean,
    bound_function,
    builtin_function,
    data_view,
    date,
    disposable_stack,
    ecmascript_function,
    @"error",
    finalization_registry,
    for_in_iterator,
    generator,
    iterator,
    iterator_helper,
    map,
    map_iterator,
    module_namespace,
    number,
    object,
    promise,
    proxy,
    raw_json,
    reg_exp,
    reg_exp_string_iterator,
    set,
    set_iterator,
    string,
    string_iterator,
    symbol,
    temporal_duration,
    temporal_instant,
    temporal_plain_date,
    temporal_plain_date_time,
    temporal_plain_month_day,
    temporal_plain_time,
    temporal_plain_year_month,
    temporal_zoned_date_time,
    typed_array,
    weak_map,
    weak_ref,
    weak_set,
    wrap_for_valid_iterator,

    // ECMA-402
    intl_collator,
    intl_date_time_format,
    intl_display_names,
    intl_duration_format,
    intl_list_format,
    intl_locale,
    intl_number_format,
    intl_plural_rules,
    intl_relative_time_format,
    intl_segmenter,
    intl_segments,
    intl_segment_iterator,

    // Custom
    _,
};

pub const IntegrityLevel = enum {
    sealed,
    frozen,
};

pub const EnumerationKind = enum {
    key,
    value,
    key_value,
};

pub fn format(self: *const Object, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    _ = self;
    // TODO: Print the actual object type.
    try writer.writeAll("[object Object]");
}

pub fn is(self: *const Object, comptime T: type) bool {
    return self.tag == T.tag;
}

pub fn as(self: *const Object, comptime T: type) *T {
    std.debug.assert(self.is(T));
    // Casting alignment is safe because we allocate objects as *T
    return @alignCast(@constCast(@fieldParentPtr("object", self)));
}

pub fn cast(self: *const Object, comptime T: type) ?*T {
    return if (self.is(T)) self.as(T) else null;
}

fn propertyPtr(self: *Object, offset: Shape.Property.Offset) *Value {
    return switch (self.properties) {
        .fixed => &self.properties.fixed[@backingInt(offset)],
        .dynamic => &self.properties.dynamic.items[@backingInt(offset)],
    };
}

pub fn ensureProperties(
    self: *Object,
    allocator: std.mem.Allocator,
    count: usize,
) std.mem.Allocator.Error!void {
    switch (self.properties) {
        .fixed => |fixed| {
            if (count <= fixed.len) return;
            var dynamic: std.ArrayList(Value) = try .initCapacity(allocator, count);
            dynamic.items.len = count;
            @memcpy(dynamic.items[0..fixed.len], &fixed);
            self.properties = .{ .dynamic = dynamic };
        },
        .dynamic => |*dynamic| {
            if (count <= dynamic.items.len) return;
            // Unlike arrays most objects stay small, so we don't want to use
            // `ensureTotalCapacity()`'s super-linear growth for properties.
            try dynamic.ensureTotalCapacityPrecise(allocator, count);
            dynamic.items.len = count;
        },
    }
}

pub fn ensureExtraData(self: *Object, allocator: std.mem.Allocator) std.mem.Allocator.Error!*ExtraData {
    if (self.extra_data) |extra_data| return extra_data;

    const extra_data = try allocator.create(ExtraData);
    extra_data.* = .{
        .private_elements = .empty,
        .lazy_properties = .empty,
        .indexed_properties = .empty,
    };
    self.extra_data = extra_data;
    return extra_data;
}

pub fn indexedProperties(self: *const Object) *const IndexedProperties {
    if (self.extra_data) |extra_data| return &extra_data.indexed_properties;
    return comptime &.{ .storage = .none };
}

pub fn ensureIndexedProperties(self: *Object, allocator: std.mem.Allocator) std.mem.Allocator.Error!*IndexedProperties {
    const extra_data = try self.ensureExtraData(allocator);
    return &extra_data.indexed_properties;
}

pub fn internalMethods(self: *const Object) *const InternalMethods {
    return self.shape.internal_methods;
}

pub fn setInternalMethods(
    self: *Object,
    agent: *Agent,
    new_internal_methods: *const InternalMethods,
) std.mem.Allocator.Error!void {
    self.shape = try self.shape.setInternalMethods(agent.gc_allocator, new_internal_methods);
}

pub fn prototype(self: *const Object) ?*Object {
    return self.shape.prototype;
}

pub fn setPrototype(self: *Object, agent: *Agent, new_prototype: ?*Object) std.mem.Allocator.Error!void {
    if (self.prototype() == new_prototype) return;
    self.shape = try self.shape.setPrototype(agent.gc_allocator, new_prototype);
}

pub fn extensible(self: *const Object) bool {
    return self.shape.extensible;
}

pub fn setNonExtensible(self: *Object, agent: *Agent) std.mem.Allocator.Error!void {
    if (!self.extensible()) return;
    self.shape = try self.shape.setNonExtensible(agent.gc_allocator);
}

pub fn isHTMLDDA(self: *const Object) bool {
    return self.shape.is_htmldda;
}

pub fn setIsHTMLDDA(self: *Object, agent: *Agent) std.mem.Allocator.Error!void {
    if (self.isHTMLDDA()) return;
    self.shape = try self.shape.setIsHTMLDDA(agent.gc_allocator);
}

pub fn containsProperty(self: *Object, property_key: PropertyKey) bool {
    if (property_key.isArrayIndex()) {
        const extra_data = self.extra_data orelse return false;
        return extra_data.indexed_properties.contains(@intCast(property_key.integer_index));
    }
    return self.shape.properties.contains(property_key);
}

pub fn getPropertyCreateLazyIfNeeded(
    self: *Object,
    property_key: PropertyKey,
) std.mem.Allocator.Error!?CompletePropertyDescriptor {
    if (property_key.isArrayIndex()) {
        const extra_data = self.extra_data orelse return null;
        return extra_data.indexed_properties.get(@intCast(property_key.integer_index));
    }
    const property = self.shape.properties.get(property_key) orelse return null;
    switch (property.type) {
        .value => {
            var value = self.propertyPtr(property.offset);
            if (value.isUninitialized()) {
                @branchHint(.unlikely);
                const extra_data = self.extra_data.?;
                const lazy_property = extra_data.lazy_properties.fetchRemove(property_key).?.value;
                const realm = lazy_property.realm;
                const agent = realm.agent;
                value.* = try lazy_property.initializer.value(agent, realm);
            }
            return .{
                .value_or_accessor = .{ .value = value.* },
                .attributes = property.attributes,
            };
        },
        .accessor => {
            var getter_value = self.propertyPtr(property.offset);
            var setter_value = self.propertyPtr(@fromBackingInt(@backingInt(property.offset) + 1));
            if (getter_value.isUninitialized()) {
                @branchHint(.unlikely);
                std.debug.assert(setter_value.isUninitialized());
                const extra_data = self.extra_data.?;
                const lazy_property = extra_data.lazy_properties.fetchRemove(property_key).?.value;
                const realm = lazy_property.realm;
                const agent = realm.agent;
                const accessor = try lazy_property.initializer.accessor(agent, realm);
                getter_value.* = if (accessor.getter) |getter| Value.from(getter) else .null;
                setter_value.* = if (accessor.setter) |setter| Value.from(setter) else .null;
            }
            return .{
                .value_or_accessor = .{ .accessor = .{
                    .getter = if (getter_value.isObject()) getter_value.asObject() else null,
                    .setter = if (setter_value.isObject()) setter_value.asObject() else null,
                } },
                .attributes = property.attributes,
            };
        },
    }
}

pub fn setProperty(
    self: *Object,
    allocator: std.mem.Allocator,
    property_key: PropertyKey,
    property_desc: CompletePropertyDescriptor,
) std.mem.Allocator.Error!void {
    if (property_key.isArrayIndex()) {
        const indexed_properties = try self.ensureIndexedProperties(allocator);
        return indexed_properties.set(allocator, @intCast(property_key.integer_index), property_desc);
    }
    const value_or_accessor = property_desc.value_or_accessor;
    const attributes = property_desc.attributes;
    const property_type: Shape.Property.Type = switch (value_or_accessor) {
        .value => .value,
        .accessor => .accessor,
    };
    if (self.shape.properties.get(property_key)) |property| {
        const property_attributes_change = property.attributes != attributes;
        const property_type_change = property.type != property_type;
        if (property_attributes_change or property_type_change) {
            self.shape = try self.shape.setProperty(
                allocator,
                property_key,
                attributes,
                property_type,
            );
        }
        if (property_type_change) {
            const new_property = self.shape.properties.get(property_key).?;
            // Clear value(s) at the previous offset(s)
            switch (property.type) {
                .value => {
                    self.setValueAtPropertyOffset(property.offset, undefined);
                },
                .accessor => {
                    // We can't use `setAccessorAtPropertyOffset()` here because it branches on the args
                    self.propertyPtr(property.offset).* = undefined;
                    self.propertyPtr(@fromBackingInt(@backingInt(property.offset) + 1)).* = undefined;
                },
            }
            switch (value_or_accessor) {
                .value => |value| {
                    try self.ensureProperties(allocator, @backingInt(new_property.offset) + 1);
                    self.setValueAtPropertyOffset(new_property.offset, value);
                },
                .accessor => |accessor| {
                    try self.ensureProperties(allocator, @backingInt(new_property.offset) + 2);
                    self.setAccessorAtPropertyOffset(new_property.offset, accessor);
                },
            }
        } else {
            switch (value_or_accessor) {
                .value => |value| {
                    self.setValueAtPropertyOffset(property.offset, value);
                },
                .accessor => |accessor| {
                    self.setAccessorAtPropertyOffset(property.offset, accessor);
                },
            }
        }
    } else {
        const offset = self.shape.next_offset;
        self.shape = try self.shape.setProperty(
            allocator,
            property_key,
            attributes,
            property_type,
        );
        switch (value_or_accessor) {
            .value => |value| {
                try self.ensureProperties(allocator, @backingInt(offset) + 1);
                self.setValueAtPropertyOffset(offset, value);
            },
            .accessor => |accessor| {
                try self.ensureProperties(allocator, @backingInt(offset) + 2);
                self.setAccessorAtPropertyOffset(offset, accessor);
            },
        }
    }
}

pub fn removeProperty(
    self: *Object,
    allocator: std.mem.Allocator,
    property_key: PropertyKey,
) std.mem.Allocator.Error!void {
    if (property_key.isArrayIndex()) {
        const extra_data = self.extra_data.?;
        return extra_data.indexed_properties.remove(allocator, @intCast(property_key.integer_index));
    }
    const property = self.shape.properties.get(property_key).?;
    self.shape = try self.shape.deleteProperty(allocator, property_key);
    // By overwriting the value and keeping subsequent offsets intact we can make property
    // deletions part of the regular transition chain without making them unique and invalidating
    // ICs. Additionally we save the cost of moving all elements after this one around, at the
    // memory cost of wasting one element.
    switch (property.type) {
        .value => {
            self.setValueAtPropertyOffset(property.offset, undefined);
        },
        .accessor => {
            // We can't use `setAccessorAtPropertyOffset()` here because it branches on the args
            self.propertyPtr(property.offset).* = undefined;
            self.propertyPtr(@fromBackingInt(@backingInt(property.offset) + 1)).* = undefined;
        },
    }
}

pub fn getValueAtPropertyOffset(self: *const Object, offset: Shape.Property.Offset) Value {
    const value = @constCast(self).propertyPtr(offset).*;
    std.debug.assert(!value.isUninitialized());
    return value;
}

pub fn setValueAtPropertyOffset(self: *Object, offset: Shape.Property.Offset, value: Value) void {
    self.propertyPtr(offset).* = value;
}

pub fn setAccessorAtPropertyOffset(
    self: *Object,
    offset: Shape.Property.Offset,
    accessor: Accessor,
) void {
    const getter_value: Value = if (accessor.getter) |getter| Value.from(getter) else .null;
    const setter_value: Value = if (accessor.setter) |setter| Value.from(setter) else .null;
    self.propertyPtr(offset).* = getter_value;
    self.propertyPtr(@fromBackingInt(@backingInt(offset) + 1)).* = setter_value;
}

pub fn getIndexedFast(self: *const Object, index: u32) ?Value {
    const extra_data = self.extra_data orelse return null;
    const has_ordinary_internal_methods = self.internalMethods().flags.supersetOf(comptime .initMany(&.{
        .ordinary_get,
        // Dependencies of ordinary [[Get]]
        .ordinary_get_own_property,
        .ordinary_get_prototype_of,
    }));
    if (!has_ordinary_internal_methods) {
        @branchHint(.unlikely);
        return null;
    }

    switch (extra_data.indexed_properties.storage) {
        .dense_i32 => |dense_i32| {
            if (index >= dense_i32.items.len) return null;
            return Value.from(dense_i32.items[index]);
        },
        .dense_f64 => |dense_f64| {
            if (index >= dense_f64.items.len) return null;
            return Value.from(dense_f64.items[index]);
        },
        .dense_value => |dense_value| {
            if (index >= dense_value.items.len) return null;
            return dense_value.items[index];
        },
        .none, .sparse_value, .sparse_property_descriptor => return null,
    }
}

pub fn setIndexedFast(self: *Object, allocator: std.mem.Allocator, index: u32, value: Value) std.mem.Allocator.Error!bool {
    const extra_data = self.extra_data orelse return false;
    const has_ordinary_internal_methods = self.internalMethods().flags.supersetOf(comptime .initMany(&.{
        .ordinary_set,
        // Dependencies of ordinary [[Set]]
        .ordinary_get_own_property,
        .ordinary_get_prototype_of,
        .ordinary_is_extensible,
        .ordinary_define_own_property,
    }));
    // Arrays have a custom [[DefineOwnProperty]] but it doesn't interfere with writeable
    // in-bounds indexed properties.
    if (!has_ordinary_internal_methods and !self.is(builtins.Array)) {
        @branchHint(.unlikely);
        return false;
    }

    switch (extra_data.indexed_properties.storage) {
        .dense_i32 => |dense_i32| {
            if (index >= dense_i32.items.len) return false;
            if (value.__isI32()) {
                dense_i32.items[index] = value.__asI32();
                return true;
            }
        },
        .dense_f64 => |dense_f64| {
            if (index >= dense_f64.items.len) return false;
            if (value.isNumber()) {
                dense_f64.items[index] = value.__toF64();
                return true;
            }
        },
        .dense_value => |dense_value| {
            if (index >= dense_value.items.len) return false;
            dense_value.items[index] = value;
            return true;
        },
        .none, .sparse_value, .sparse_property_descriptor => return false,
    }
    try extra_data.indexed_properties.set(allocator, index, .{
        .value_or_accessor = .{ .value = value },
        .attributes = .all,
    });
    return true;
}

/// Assumes the property exists, is a data property, and not lazy.
pub fn getPropertyValueDirect(self: *const Object, property_key: PropertyKey) Value {
    if (property_key.isArrayIndex()) {
        const index: u32 = @intCast(property_key.integer_index);
        const extra_data = self.extra_data.?;
        return switch (extra_data.indexed_properties.storage) {
            .none => unreachable,
            .dense_i32 => |dense_i32| Value.from(dense_i32.items[index]),
            .dense_f64 => |dense_f64| Value.from(dense_f64.items[index]),
            .dense_value => |dense_value| dense_value.items[index],
            .sparse_value => |sparse_value| sparse_value.get(index).?,
            .sparse_property_descriptor => |sparse_property_descriptor| sparse_property_descriptor.get(index).?.value_or_accessor.value,
        };
    }
    const property = self.shape.properties.get(property_key).?;
    std.debug.assert(property.type == .value);
    return self.getValueAtPropertyOffset(property.offset);
}

/// Fast version of `createDataPropertyOrThrow()` that assumes the property does not exist yet or
/// looking it up is free of side effects. This allows us to bypass `[[DefineOwnProperty]]` and
/// thus `[[GetOwnProperty]]` and `[[IsExtensible]]`.
pub fn createDataPropertyDirect(
    self: *Object,
    agent: *Agent,
    property_key: PropertyKey,
    value: Value,
) std.mem.Allocator.Error!void {
    return self.definePropertyDirect(agent, property_key, .{
        .value_or_accessor = .{ .value = value },
        .attributes = .all,
    });
}

/// Fast version of `definePropertyOrThrow()` that assumes the property does not exist yet or
/// looking it up is free of side effects. This allows us to bypass `[[DefineOwnProperty]]` and
/// thus `[[GetOwnProperty]]` and `[[IsExtensible]]`.
pub fn definePropertyDirect(
    self: *Object,
    agent: *Agent,
    property_key: PropertyKey,
    property_desc: CompletePropertyDescriptor,
) std.mem.Allocator.Error!void {
    const has_ordinary_internal_methods = self.internalMethods().flags.supersetOf(comptime .initMany(&.{
        .ordinary_define_own_property,
        .ordinary_get_own_property,
        .ordinary_is_extensible,
    }));
    // Arrays have a custom `[[DefineOwnProperty]]` but only use it for indexed properties and
    // 'length' so we can use the fast path for everything else.
    const use_fast_path_for_array =
        self.is(builtins.Array) and
        !property_key.isArrayIndex() and
        !property_key.isLength();

    if (has_ordinary_internal_methods or use_fast_path_for_array) {
        try self.setProperty(agent.gc_allocator, property_key, property_desc);
    } else {
        const result = self.internalMethods().defineOwnProperty(
            agent,
            self,
            property_key,
            property_desc.toPropertyDescriptor(),
        ) catch |err| try noexcept(err);
        std.debug.assert(result);
    }
}

// NOTE: A lot of this behaviour is implied for all builtins and described at the end of
// https://tc39.es/ecma262/#sec-ecmascript-standard-built-in-objects.

fn getFunctionName(comptime name: []const u8) []const u8 {
    if (comptime std.mem.startsWith(u8, name, "Symbol.")) {
        return std.fmt.comptimePrint("[{s}]", .{name});
    }
    return name;
}

fn getPropertyKey(comptime name: []const u8, agent: *Agent) PropertyKey {
    if (comptime std.mem.startsWith(u8, name, "Symbol.")) {
        const field = comptime std.StaticStringMap(
            std.meta.FieldEnum(Agent.WellKnownSymbols),
        ).initComptime(&.{
            .{ "Symbol.asyncDispose", .async_dispose },
            .{ "Symbol.asyncIterator", .async_iterator },
            .{ "Symbol.dispose", .dispose },
            .{ "Symbol.hasInstance", .has_instance },
            .{ "Symbol.isConcatSpreadable", .is_concat_spreadable },
            .{ "Symbol.iterator", .iterator },
            .{ "Symbol.match", .match },
            .{ "Symbol.matchAll", .match_all },
            .{ "Symbol.replace", .replace },
            .{ "Symbol.search", .search },
            .{ "Symbol.species", .species },
            .{ "Symbol.split", .split },
            .{ "Symbol.toPrimitive", .to_primitive },
            .{ "Symbol.toStringTag", .to_string_tag },
            .{ "Symbol.unscopables", .unscopables },
        }).get(name).?;
        return PropertyKey.from(@field(agent.well_known_symbols, @tagName(field)));
    }
    comptime for (name) |c| switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '_' => {},
        else => unreachable,
    };
    return PropertyKey.from(name);
}

pub fn defineBuiltinAccessor(
    self: *Object,
    agent: *Agent,
    comptime name: []const u8,
    comptime getter: ?Behaviour.Function,
    comptime setter: ?Behaviour.Function,
    realm: *Realm,
) std.mem.Allocator.Error!void {
    return self.defineBuiltinAccessorWithAttributes(
        agent,
        name,
        getter,
        setter,
        realm,
        .{ .enumerable = false, .configurable = true },
    );
}

pub fn defineBuiltinAccessorWithAttributes(
    self: *Object,
    agent: *Agent,
    comptime name: []const u8,
    comptime getter: ?Behaviour.Function,
    comptime setter: ?Behaviour.Function,
    realm: *Realm,
    attributes: struct {
        enumerable: bool,
        configurable: bool,
    },
) std.mem.Allocator.Error!void {
    comptime std.debug.assert(getter != null or setter != null);
    const getter_function = if (getter) |function| blk: {
        const function_name = std.fmt.comptimePrint("get {s}", .{comptime getFunctionName(name)});
        break :blk try createBuiltinFunction(
            agent,
            .{ .function = function },
            0,
            function_name,
            .{ .realm = realm },
        );
    } else {};
    const setter_function = if (setter) |function| blk: {
        const function_name = std.fmt.comptimePrint("set {s}", .{comptime getFunctionName(name)});
        break :blk try createBuiltinFunction(
            agent,
            .{ .function = function },
            1,
            function_name,
            .{ .realm = realm },
        );
    } else {};
    const property_key = getPropertyKey(name, agent);
    const attributes_: Object.Shape.Property.Attributes = .{
        .writable = false,
        .enumerable = attributes.enumerable,
        .configurable = attributes.configurable,
    };
    if (!self.shape.isUnique()) {
        self.shape = try self.shape.makeUnique(agent.gc_allocator);
    }
    const offset = self.shape.next_offset;
    try self.shape.setPropertyWithoutTransition(
        agent.gc_allocator,
        property_key,
        attributes_,
        .accessor,
    );
    try self.ensureProperties(agent.gc_allocator, @backingInt(offset) + 2);
    self.setAccessorAtPropertyOffset(offset, .{
        .getter = if (@TypeOf(getter_function) != void) &getter_function.object else null,
        .setter = if (@TypeOf(setter_function) != void) &setter_function.object else null,
    });
}

pub fn defineBuiltinFunction(
    self: *Object,
    agent: *Agent,
    comptime name: []const u8,
    comptime function: Behaviour.Function,
    comptime length: u32,
    realm: *Realm,
) std.mem.Allocator.Error!void {
    return self.defineBuiltinFunctionWithAttributes(
        agent,
        name,
        function,
        length,
        realm,
        .builtin_default,
    );
}

pub fn defineBuiltinFunctionWithAttributes(
    self: *Object,
    agent: *Agent,
    comptime name: []const u8,
    comptime function: Behaviour.Function,
    comptime length: u32,
    realm: *Realm,
    attributes: Object.Shape.Property.Attributes,
) std.mem.Allocator.Error!void {
    const function_name = comptime getFunctionName(name);
    const builtin_function = try createBuiltinFunction(
        agent,
        .{ .function = function },
        length,
        function_name,
        .{ .realm = realm },
    );
    try self.defineBuiltinPropertyWithAttributes(
        agent,
        name,
        Value.from(&builtin_function.object),
        attributes,
    );
}

pub fn defineBuiltinAsyncFunction(
    self: *Object,
    agent: *Agent,
    comptime name: []const u8,
    comptime function: Behaviour.Function,
    comptime length: u32,
    realm: *Realm,
) std.mem.Allocator.Error!void {
    return self.defineBuiltinAsyncFunctionWithAttributes(
        agent,
        name,
        function,
        length,
        realm,
        .builtin_default,
    );
}

pub fn defineBuiltinAsyncFunctionWithAttributes(
    self: *Object,
    agent: *Agent,
    comptime name: []const u8,
    comptime function: Behaviour.Function,
    comptime length: u32,
    realm: *Realm,
    attributes: Object.Shape.Property.Attributes,
) std.mem.Allocator.Error!void {
    const function_name = comptime getFunctionName(name);
    const builtin_function = try createBuiltinFunction(
        agent,
        .{ .function = function },
        length,
        function_name,
        .{
            .realm = realm,
            .flags = .{ .async = true, .is_class_constructor = false },
        },
    );
    try self.defineBuiltinPropertyWithAttributes(
        agent,
        name,
        Value.from(&builtin_function.object),
        attributes,
    );
}

pub fn defineBuiltinFunctionLazy(
    self: *Object,
    agent: *Agent,
    comptime name: []const u8,
    comptime function: Behaviour.Function,
    comptime length: u32,
    realm: *Realm,
    attributes: Object.Shape.Property.Attributes,
) std.mem.Allocator.Error!void {
    const function_name = comptime getFunctionName(name);
    try self.defineBuiltinPropertyLazy(
        agent,
        name,
        struct {
            fn initializer(agent_: *Agent, realm_: *Realm) std.mem.Allocator.Error!Value {
                const builtin_function = try createBuiltinFunction(
                    agent_,
                    .{ .function = function },
                    length,
                    function_name,
                    .{ .realm = realm_ },
                );
                return Value.from(&builtin_function.object);
            }
        }.initializer,
        realm,
        attributes,
    );
}

pub fn defineBuiltinProperty(
    self: *Object,
    agent: *Agent,
    comptime name: []const u8,
    value: Value,
) std.mem.Allocator.Error!void {
    return self.defineBuiltinPropertyWithAttributes(agent, name, value, .builtin_default);
}

pub fn defineBuiltinPropertyWithAttributes(
    self: *Object,
    agent: *Agent,
    comptime name: []const u8,
    value: Value,
    attributes: Object.Shape.Property.Attributes,
) std.mem.Allocator.Error!void {
    const property_key = getPropertyKey(name, agent);
    if (!self.shape.isUnique()) {
        self.shape = try self.shape.makeUnique(agent.gc_allocator);
    }
    const offset = self.shape.next_offset;
    try self.shape.setPropertyWithoutTransition(
        agent.gc_allocator,
        property_key,
        attributes,
        .value,
    );
    try self.ensureProperties(agent.gc_allocator, @backingInt(offset) + 1);
    self.setValueAtPropertyOffset(offset, value);
}

pub fn defineBuiltinPropertyLazy(
    self: *Object,
    agent: *Agent,
    comptime name: []const u8,
    comptime initializer: fn (*Agent, *Realm) std.mem.Allocator.Error!Value,
    realm: *Realm,
    attributes: Object.Shape.Property.Attributes,
) std.mem.Allocator.Error!void {
    const property_key = getPropertyKey(name, agent);
    const extra_data = try self.ensureExtraData(agent.gc_allocator);
    if (!self.shape.isUnique()) {
        self.shape = try self.shape.makeUnique(agent.gc_allocator);
    }
    const offset = self.shape.next_offset;
    try self.shape.setPropertyWithoutTransition(
        agent.gc_allocator,
        property_key,
        attributes,
        .value,
    );
    try self.ensureProperties(agent.gc_allocator, @backingInt(offset) + 1);
    self.setValueAtPropertyOffset(offset, .uninitialized);
    try extra_data.lazy_properties.putNoClobber(
        agent.gc_allocator,
        property_key,
        .{
            .realm = realm,
            .initializer = .{ .value = initializer },
        },
    );
}

/// 7.1.1.1 OrdinaryToPrimitive ( obj, hint )
/// https://tc39.es/ecma262/#sec-ordinarytoprimitive
pub fn ordinaryToPrimitive(obj: *Object, agent: *Agent, hint: PreferredType) Agent.Error!Value {
    const method_names = switch (hint) {
        // 1. If hint is string, then
        //     a. Let methodNames be « "toString", "valueOf" ».
        .string => [_]PropertyKey{ PropertyKey.from("toString"), PropertyKey.from("valueOf") },
        // 2. Else,
        //     a. Let methodNames be « "valueOf", "toString" ».
        else => [_]PropertyKey{ PropertyKey.from("valueOf"), PropertyKey.from("toString") },
    };

    // 3. For each element name of methodNames, do
    for (method_names) |name| {
        // a. Let method be ? Get(obj, name).
        const method = try obj.get(agent, name);

        // b. If IsCallable(method) is true, then
        if (method.isCallable()) {
            // i. Let result be ? Call(method, obj).
            const result = try method.asObject().call(agent, Value.from(obj), &.{});

            // ii. If result is not an Object, return result.
            if (!result.isObject()) return result;
        }
    }

    // 4. Throw a TypeError exception.
    return agent.throwException(.type_error, "Could not convert object to {t}", .{hint});
}

/// 7.2.5 IsExtensible ( obj )
/// https://tc39.es/ecma262/#sec-isextensible-o
pub fn isExtensible(obj: *Object, agent: *Agent) Agent.Error!bool {
    // 1. Return ? obj.[[IsExtensible]]().
    return obj.internalMethods().isExtensible(agent, obj);
}

/// 7.3.2 Get ( obj, propertyKey )
/// https://tc39.es/ecma262/#sec-get-o-p
pub fn get(obj: *Object, agent: *Agent, property_key: PropertyKey) Agent.Error!Value {
    // 1. Return ? obj.[[Get]](propertyKey, obj).
    return obj.internalMethods().get(agent, obj, property_key, Value.from(obj));
}

/// 7.3.4 Set ( obj, propertyKey, value, throw )
/// https://tc39.es/ecma262/#sec-set-o-p-v-throw
pub fn set(
    obj: *Object,
    agent: *Agent,
    property_key: PropertyKey,
    value: Value,
    throw: enum { throw, ignore },
) Agent.Error!void {
    // 1. Let success be ? obj.[[Set]](propertyKey, value, obj).
    const success = try obj.internalMethods().set(
        agent,
        obj,
        property_key,
        value,
        Value.from(obj),
    );

    // 2. If success is false and throw is true, throw a TypeError exception.
    if (!success and throw == .throw)
        return agent.throwException(.type_error, "Could not set property", .{});

    // 3. Return unused.
}

/// 7.3.5 CreateDataProperty ( obj, propertyKey, value )
/// https://tc39.es/ecma262/#sec-createdataproperty
pub fn createDataProperty(obj: *Object, agent: *Agent, property_key: PropertyKey, value: Value) Agent.Error!bool {
    // 1. Let newDesc be the PropertyDescriptor { [[Value]]: value, [[Writable]]: true,
    //    [[Enumerable]]: true, [[Configurable]]: true }.
    const new_descriptor: PropertyDescriptor = .{
        .value = value,
        .writable = true,
        .enumerable = true,
        .configurable = true,
    };

    // 2. Return ? obj.[[DefineOwnProperty]](propertyKey, newDesc).
    return obj.internalMethods().defineOwnProperty(agent, obj, property_key, new_descriptor);
}

/// 7.3.6 CreateDataPropertyOrThrow ( obj, propertyKey, value )
/// https://tc39.es/ecma262/#sec-createdatapropertyorthrow
pub fn createDataPropertyOrThrow(
    obj: *Object,
    agent: *Agent,
    property_key: PropertyKey,
    value: Value,
) Agent.Error!void {
    // 1. Let success be ? CreateDataProperty(obj, propertyKey, value).
    const success = try obj.createDataProperty(agent, property_key, value);

    // 2. If success is false, throw a TypeError exception.
    if (!success)
        return agent.throwException(.type_error, "Could not create data property", .{});

    // 3. Return unused.
}

/// 7.3.7 CreateNonEnumerableDataPropertyOrThrow ( obj, propertyKey, value )
/// https://tc39.es/ecma262/#sec-createnonenumerabledatapropertyorthrow
pub fn createNonEnumerableDataPropertyOrThrow(
    obj: *Object,
    agent: *Agent,
    property_key: PropertyKey,
    value: Value,
) std.mem.Allocator.Error!void {
    // 1. Assert: obj is an ordinary, extensible object with no non-configurable properties.
    std.debug.assert(
        obj.extensible() and for (obj.shape.properties.values()) |entry| {
            if (!entry.attributes.configurable) break false;
        } else true and switch (obj.indexedProperties().storage) {
            .sparse_property_descriptor => |sparse_property_descriptor| blk: {
                var it = sparse_property_descriptor.valueIterator();
                break :blk while (it.next()) |entry| {
                    if (!entry.attributes.configurable) break false;
                } else true;
            },
            else => true,
        },
    );

    // 2. Let newDesc be the PropertyDescriptor { [[Value]]: value, [[Writable]]: true,
    //    [[Enumerable]]: false, [[Configurable]]: true }.
    const new_desc: CompletePropertyDescriptor = .{
        .value_or_accessor = .{
            .value = value,
        },
        .attributes = .builtin_default,
    };

    // 3. Perform ! DefinePropertyOrThrow(obj, propertyKey, newDesc).
    try obj.definePropertyDirect(agent, property_key, new_desc);

    // 4. Return unused.
}

/// 7.3.8 DefinePropertyOrThrow ( obj, propertyKey, propertyDesc )
/// https://tc39.es/ecma262/#sec-definepropertyorthrow
pub fn definePropertyOrThrow(
    obj: *Object,
    agent: *Agent,
    property_key: PropertyKey,
    property_desc: PropertyDescriptor,
) Agent.Error!void {
    // 1. Let success be ? obj.[[DefineOwnProperty]](propertyKey, propertyDesc).
    const success = try obj.internalMethods().defineOwnProperty(
        agent,
        obj,
        property_key,
        property_desc,
    );

    // 2. If success is false, throw a TypeError exception.
    if (!success)
        return agent.throwException(.type_error, "Could not define property", .{});

    // 3. Return unused.
}

/// 7.3.9 DeletePropertyOrThrow ( obj, propertyKey )
/// https://tc39.es/ecma262/#sec-deletepropertyorthrow
pub fn deletePropertyOrThrow(obj: *Object, agent: *Agent, property_key: PropertyKey) Agent.Error!void {
    // 1. Let success be ? obj.[[Delete]](propertyKey).
    const success = try obj.internalMethods().delete(agent, obj, property_key);

    // 2. If success is false, throw a TypeError exception.
    if (!success)
        return agent.throwException(.type_error, "Could not delete property", .{});

    // 3. Return unused.
}

/// 7.3.10 GetMethod ( value, propertyKey )
/// https://tc39.es/ecma262/#sec-getmethod
pub fn getMethod(obj: *Object, agent: *Agent, property_key: PropertyKey) Agent.Error!?*Object {
    // 1. Let func be ? GetV(value, propertyKey).
    const func = try obj.get(agent, property_key);

    // 2. If func is either undefined or null, return undefined.
    if (func.isUndefined() or func.isNull()) return null;

    // 3. If IsCallable(func) is false, throw a TypeError exception.
    if (!func.isCallable()) {
        return agent.throwException(.type_error, "{f} is not callable", .{Value.from(obj)});
    }

    // 4. Return func.
    return func.asObject();
}

/// 7.3.11 HasProperty ( obj, propertyKey )
/// https://tc39.es/ecma262/#sec-hasproperty
pub fn hasProperty(obj: *Object, agent: *Agent, property_key: PropertyKey) Agent.Error!bool {
    // 1. Return ? obj.[[HasProperty]](propertyKey).
    return obj.internalMethods().hasProperty(agent, obj, property_key);
}

/// 7.3.12 HasOwnProperty ( obj, propertyKey )
/// https://tc39.es/ecma262/#sec-hasownproperty
pub fn hasOwnProperty(obj: *Object, agent: *Agent, property_key: PropertyKey) Agent.Error!bool {
    // 1. Let propertyDesc be ? obj.[[GetOwnProperty]](propertyKey).
    const property_desc = try obj.internalMethods().getOwnProperty(agent, obj, property_key);

    // 2. If propertyDesc is undefined, return false.
    // 3. Return true.
    return property_desc != null;
}

/// 7.3.13 Call ( func, thisValue [ , argList ] )
/// https://tc39.es/ecma262/#sec-call
pub fn call(
    func: *Object,
    agent: *Agent,
    this_value: Value,
    arg_list: []const Value,
) Agent.Error!Value {
    // 1. If argList is not present, set argList to a new empty List.
    // 2. If IsCallable(func) is false, throw a TypeError exception.
    // 3. Return ? func.[[Call]](thisValue, argList).
    return func.internalMethods().call.?(agent, func, this_value, Arguments.from(arg_list));
}

/// 7.3.14 Construct ( ctor [ , argList [ , newTarget ] ] )
/// https://tc39.es/ecma262/#sec-construct
pub fn construct(
    ctor: *Object,
    agent: *Agent,
    arg_list: []const Value,
    maybe_new_target: ?*Object,
) Agent.Error!*Object {
    // 1. If newTarget is not present, set newTarget to ctor.
    const new_target = maybe_new_target orelse ctor;

    // 2. If argList is not present, set argList to a new empty List.

    // 3. Return ? ctor.[[Construct]](argList, newTarget).
    return ctor.internalMethods().construct.?(agent, ctor, Arguments.from(arg_list), new_target);
}

/// 7.3.15 SetIntegrityLevel ( obj, level )
/// https://tc39.es/ecma262/#sec-setintegritylevel
pub fn setIntegrityLevel(obj: *Object, agent: *Agent, level: IntegrityLevel) Agent.Error!bool {
    // 1. Let status be ? obj.[[PreventExtensions]]().
    const status = try obj.internalMethods().preventExtensions(agent, obj);

    // 2. If status is false, return false.
    if (!status) return false;

    // 3. Let keys be ? obj.[[OwnPropertyKeys]]().
    const keys = try obj.internalMethods().ownPropertyKeys(agent, obj);
    defer agent.gc_allocator.free(keys);

    switch (level) {
        // 4. If level is sealed, then
        .sealed => {
            // a. For each element key of keys, do
            for (keys) |property_key| {
                // i. Perform ? DefinePropertyOrThrow(obj, key, PropertyDescriptor {
                //    [[Configurable]]: false }).
                try obj.definePropertyOrThrow(agent, property_key, .{ .configurable = false });
            }
        },

        // 5. Else,
        .frozen => {
            // a. Assert: level is frozen.

            // b. For each element key of keys, do
            for (keys) |property_key| {
                // i. Let currentDesc be ? obj.[[GetOwnProperty]](key).
                const maybe_current_desc = try obj.internalMethods().getOwnProperty(
                    agent,
                    obj,
                    property_key,
                );

                // ii. If currentDesc is not undefined, then
                if (maybe_current_desc) |current_desc| {
                    // 1. If IsAccessorDescriptor(currentDesc) is true, then
                    const property_desc: PropertyDescriptor = if (current_desc.isAccessorDescriptor()) blk: {
                        // a. Let propertyDesc be the PropertyDescriptor {
                        //    [[Configurable]]: false }.
                        break :blk .{ .configurable = false };
                    } else blk: {
                        // 2. Else,
                        // a. Let propertyDesc be the PropertyDescriptor { [[Configurable]]: false,
                        //    [[Writable]]: false }.
                        break :blk .{ .configurable = false, .writable = false };
                    };

                    // 3. Perform ? DefinePropertyOrThrow(obj, key, propertyDesc).
                    try obj.definePropertyOrThrow(agent, property_key, property_desc);
                }
            }
        },
    }

    // 6. Return true.
    return true;
}

/// 7.3.16 TestIntegrityLevel ( obj, level )
/// https://tc39.es/ecma262/#sec-testintegritylevel
pub fn testIntegrityLevel(obj: *Object, agent: *Agent, level: IntegrityLevel) Agent.Error!bool {
    // 1. Let extensible be ? IsExtensible(obj).
    const extensible_ = try obj.isExtensible(agent);

    // 2. If extensible is true, return false.
    // 3. NOTE: If the object is extensible, none of its properties are examined.
    if (extensible_) return false;

    // 4. Let keys be ? obj.[[OwnPropertyKeys]]().
    const keys = try obj.internalMethods().ownPropertyKeys(agent, obj);
    defer agent.gc_allocator.free(keys);

    // 5. For each element key of keys, do
    for (keys) |property_key| {
        // a. Let currentDesc be ? obj.[[GetOwnProperty]](key).
        const maybe_current_desc = try obj.internalMethods().getOwnProperty(
            agent,
            obj,
            property_key,
        );

        // b. If currentDesc is not undefined, then
        if (maybe_current_desc) |current_desc| {
            // i. If currentDesc.[[Configurable]] is true, return false.
            if (current_desc.configurable.?) return false;

            // ii. If level is frozen and IsDataDescriptor(currentDesc) is true, then
            if (level == .frozen and current_desc.isDataDescriptor()) {
                // 1. If currentDesc.[[Writable]] is true, return false.
                if (current_desc.writable.?) return false;
            }
        }
    }

    // 6. Return true.
    return true;
}

/// 7.3.18 LengthOfArrayLike ( obj )
/// https://tc39.es/ecma262/#sec-lengthofarraylike
pub fn lengthOfArrayLike(obj: *Object, agent: *Agent) Agent.Error!u53 {
    // 1. Return ℝ(? ToLength(? Get(obj, "length"))).
    return (try obj.get(agent, PropertyKey.from("length"))).toLength(agent);
}

/// 7.3.20 Invoke ( value, propertyKey [ , argList ] )
/// https://tc39.es/ecma262/#sec-invoke
pub fn invoke(
    obj: *Object,
    agent: *Agent,
    property_key: PropertyKey,
    arg_list: []const Value,
) Agent.Error!Value {
    // 1. If argList is not present, set argList to a new empty List.

    // 2. Let func be ? GetV(value, propertyKey).
    const func = try obj.get(agent, property_key);

    // 3. Return ? Call(func, value, argList).
    return func.call(agent, Value.from(obj), arg_list);
}

/// 7.3.22 SpeciesConstructor ( obj, defaultCtor )
/// https://tc39.es/ecma262/#sec-speciesconstructor
pub fn speciesConstructor(obj: *Object, agent: *Agent, default_ctor: *Object) Agent.Error!*Object {
    // 1. Let ctor be ? Get(obj, "constructor").
    const ctor = try obj.get(agent, PropertyKey.from("constructor"));

    // 2. If ctor is undefined, return defaultCtor.
    if (ctor.isUndefined()) return default_ctor;

    // 3. If ctor is not an Object, throw a TypeError exception.
    if (!ctor.isObject()) {
        return agent.throwException(.type_error, "{f} is not an Object", .{ctor});
    }

    // 4. Let species be ? Get(ctor, %Symbol.species%).
    const species = try ctor.asObject().get(
        agent,
        PropertyKey.from(agent.well_known_symbols.species),
    );

    // 5. If species is either undefined or null, return defaultCtor.
    if (species.isUndefined() or species.isNull()) return default_ctor;

    // 6. If IsConstructor(species) is true, return species.
    if (species.isConstructor()) return species.asObject();

    // 7. Throw a TypeError exception.
    return agent.throwException(
        .type_error,
        "Object's [Symbol.species] property must be a constructor",
        .{},
    );
}

/// 7.3.23 EnumerableOwnProperties ( obj, kind )
/// https://tc39.es/ecma262/#sec-enumerableownproperties
pub fn enumerableOwnProperties(
    obj: *Object,
    agent: *Agent,
    comptime kind: EnumerationKind,
) Agent.Error!std.ArrayList(Value) {
    // 1. Let ownKeys be ? obj.[[OwnPropertyKeys]]().
    const own_keys = try obj.internalMethods().ownPropertyKeys(agent, obj);
    defer agent.gc_allocator.free(own_keys);

    // 2. Let results be a new empty List.
    var results: std.ArrayList(Value) = .empty;

    // 3. For each element key of ownKeys, do
    for (own_keys) |key| {
        // a. If key is a String, then
        if (key == .string or key == .integer_index) {
            // i. Let propertyDesc be ? obj.[[GetOwnProperty]](key).
            const property_desc = try obj.internalMethods().getOwnProperty(agent, obj, key);

            // ii. If propertyDesc is not undefined and propertyDesc.[[Enumerable]] is true, then
            if (property_desc != null and property_desc.?.enumerable == true) {
                // 1. If kind is key, then
                if (kind == .key) {
                    // a. Append key to results.
                    try results.append(agent.gc_allocator, try key.toValue(agent));
                } else {
                    // 2. Else,
                    // a. Let value be ? Get(obj, key).
                    const value = try obj.get(agent, key);

                    // b. If kind is value, then
                    if (kind == .value) {
                        // i. Append value to results.
                        try results.append(agent.gc_allocator, value);
                    } else {
                        // c. Else,
                        // i. Assert: kind is key+value.
                        std.debug.assert(kind == .key_value);

                        // ii. Let entry be CreateArrayFromList(« key, value »).
                        const entry = try createArrayFromList(
                            agent,
                            &.{ try key.toValue(agent), value },
                        );

                        // iii. Append entry to results.
                        try results.append(agent.gc_allocator, Value.from(&entry.object));
                    }
                }
            }
        }
    }

    // 4. Return results.
    return results;
}

/// 7.3.24 GetFunctionRealm ( func )
/// https://tc39.es/ecma262/#sec-getfunctionrealm
pub fn getFunctionRealm(func: *const Object, agent: *Agent) error{ExceptionThrown}!*Realm {
    // 1. If func has a [[Realm]] internal slot, then
    if (func.internalMethods().call != null) {
        // a. Return func.[[Realm]].
        if (func.cast(builtins.BuiltinFunction)) |builtin_function| {
            return builtin_function.fields.realm;
        } else if (func.cast(builtins.ECMAScriptFunction)) |ecmascript_function| {
            return ecmascript_function.fields.realm;
        } else if (!(func.is(builtins.BoundFunction) or func.is(builtins.Proxy))) {
            @panic("Unhandled function type in getFunctionRealm()");
        }
    }

    // 2. If func is a bound function exotic object, then
    if (func.cast(builtins.BoundFunction)) |bound_function| {
        // a. Let boundTargetFunc be func.[[BoundTargetFunction]].
        const bound_target_func = bound_function.fields.bound_target_function;

        // b. Return ? GetFunctionRealm(boundTargetFunc).
        return bound_target_func.getFunctionRealm(agent);
    }

    // 3. If func is a Proxy exotic object, then
    if (func.cast(builtins.Proxy)) |proxy| {
        // a. Perform ? ValidateNonRevokedProxy(func).
        try validateNonRevokedProxy(agent, proxy);

        // b. Let proxyTarget be func.[[ProxyTarget]].
        const proxy_target = proxy.fields.proxy_target.?;

        // c. Assert: proxyTarget is a function object.
        std.debug.assert(proxy_target.internalMethods().call != null);

        // d. Return ? GetFunctionRealm(proxyTarget).
        return proxy_target.getFunctionRealm(agent);
    }

    // 4. Return the current Realm Record.
    return agent.currentRealm();
}

/// 7.3.25 CopyDataProperties ( target, source, excludedItems )
/// https://tc39.es/ecma262/#sec-copydataproperties
pub fn copyDataProperties(
    target: *Object,
    agent: *Agent,
    source: Value,
    excluded_items: []const PropertyKey,
) Agent.Error!void {
    // 1. If source is either undefined or null, return unused.
    if (source.isUndefined() or source.isNull()) return;

    // 2. Let from be ! ToObject(source).
    const from = source.toObject(agent) catch |err| try noexcept(err);

    // 3. Let keys be ? from.[[OwnPropertyKeys]]().
    const keys = try from.internalMethods().ownPropertyKeys(agent, from);
    defer agent.gc_allocator.free(keys);

    // 4. For each element nextKey of keys, do
    for (keys) |next_key| {
        // a. Let excluded be false.
        // b. For each element element of excludedItems, do
        const excluded = for (excluded_items) |element| {
            // i. If SameValue(element, nextKey) is true, then
            if (element.eql(next_key)) {
                // 1. Set excluded to true.
                break true;
            }
        } else false;

        // c. If excluded is false, then
        if (!excluded) {
            // i. Let propertyDesc be ? from.[[GetOwnProperty]](nextKey).
            const property_desc = try from.internalMethods().getOwnProperty(
                agent,
                from,
                next_key,
            );

            // ii. If propertyDesc is not undefined and propertyDesc.[[Enumerable]] is true, then
            if (property_desc != null and property_desc.?.enumerable == true) {
                // 1. Let propertyValue be ? Get(from, nextKey).
                const property_value = try from.get(agent, next_key);

                // 2. Perform ! CreateDataPropertyOrThrow(target, nextKey, propertyValue).
                try target.createDataPropertyDirect(agent, next_key, property_value);
            }
        }
    }

    // 5. Return unused.
}

/// 7.3.26 PrivateElementFind ( obj, privateName )
/// https://tc39.es/ecma262/#sec-privateelementfind
pub fn privateElementFind(obj: *const Object, private_name: PrivateName) ?*PrivateElement {
    // 1. If obj.[[PrivateElements]] contains a PrivateElement entry such that entry.[[Key]] is
    //    privateName, then
    //     a. Return entry.
    // 2. Return empty.
    const extra_data = obj.extra_data orelse return null;
    return extra_data.private_elements.getPtr(private_name);
}

/// 7.3.27 PrivateFieldAdd ( obj, privateName, value )
/// https://tc39.es/ecma262/#sec-privatefieldadd
pub fn privateFieldAdd(obj: *Object, agent: *Agent, private_name: PrivateName, value: Value) Agent.Error!void {
    // 1. If the host is a web browser, then
    //     a. Perform ? HostEnsureCanAddPrivateElement(obj).
    try agent.host_hooks.hostEnsureCanAddPrivateElement(agent, obj);

    // 2. Let entry be PrivateElementFind(obj, privateName).
    const entry = obj.privateElementFind(private_name);

    // 3. If entry is not empty, throw a TypeError exception.
    if (entry != null) {
        return agent.throwException(
            .type_error,
            "Private element '{f}' already exists",
            .{private_name},
        );
    }

    // 4. Append PrivateElement { [[Key]]: privateName, [[Kind]]: field, [[Value]]: value } to
    //    obj.[[PrivateElements]].
    const extra_data = try obj.ensureExtraData(agent.gc_allocator);
    try extra_data.private_elements.putNoClobber(agent.gc_allocator, private_name, .{ .field = value });

    // 5. Return unused.
}

/// 7.3.28 PrivateMethodOrAccessorAdd ( obj, method )
/// https://tc39.es/ecma262/#sec-privatemethodoraccessoradd
pub fn privateMethodOrAccessorAdd(
    obj: *Object,
    agent: *Agent,
    private_name: PrivateName,
    method: PrivateElement,
) Agent.Error!void {
    // 1. Assert: method.[[Kind]] is either method or accessor.
    std.debug.assert(method == .method or method == .accessor);

    // 2. If the host is a web browser, then
    //     a. Perform ? HostEnsureCanAddPrivateElement(obj).
    try agent.host_hooks.hostEnsureCanAddPrivateElement(agent, obj);

    // 3. Let entry be PrivateElementFind(obj, method.[[Key]]).
    const entry = obj.privateElementFind(private_name);

    // 4. If entry is not empty, throw a TypeError exception.
    if (entry != null) {
        return agent.throwException(
            .type_error,
            "Private element '{f}' already exists",
            .{private_name},
        );
    }

    // 5. Append method to obj.[[PrivateElements]].
    const extra_data = try obj.ensureExtraData(agent.gc_allocator);
    try extra_data.private_elements.putNoClobber(agent.gc_allocator, private_name, method);

    // 6. Return unused.
}

/// 7.3.30 PrivateGet ( obj, privateName )
/// https://tc39.es/ecma262/#sec-privateget
pub fn privateGet(obj: *Object, agent: *Agent, private_name: PrivateName) Agent.Error!Value {
    // 1. Let entry be PrivateElementFind(obj, privateName).
    const entry = obj.privateElementFind(private_name) orelse {
        // 2. If entry is empty, throw a TypeError exception.
        return agent.throwException(
            .type_error,
            "Private element '{f}' doesn't exist",
            .{private_name},
        );
    };

    switch (entry.*) {
        // 3. If entry.[[Kind]] is either field or method, then
        //     a. Return entry.[[Value]].
        .field => |value| return value,
        .method => |object| return Value.from(object),

        // 4. Assert: entry.[[Kind]] is accessor.
        .accessor => |accessor| {
            // 5. If entry.[[Getter]] is undefined, throw a TypeError exception.
            // 6. Let getter be entry.[[Getter]].
            const getter = accessor.getter orelse {
                return agent.throwException(
                    .type_error,
                    "Private element '{f}' has no getter",
                    .{private_name},
                );
            };

            // 7. Return ? Call(getter, obj).
            return getter.call(agent, Value.from(obj), &.{});
        },
    }
}

/// 7.3.31 PrivateSet ( obj, privateName, value )
/// https://tc39.es/ecma262/#sec-privateset
pub fn privateSet(obj: *Object, agent: *Agent, private_name: PrivateName, value: Value) Agent.Error!void {
    // 1. Let entry be PrivateElementFind(obj, privateName).
    const entry = obj.privateElementFind(private_name) orelse {
        // 2. If entry is empty, throw a TypeError exception.
        return agent.throwException(
            .type_error,
            "Private element '{f}' doesn't exist",
            .{private_name},
        );
    };

    switch (entry.*) {
        // 3. If entry.[[Kind]] is method, throw a TypeError exception.
        .method => {
            return agent.throwException(
                .type_error,
                "Private element '{f}' is a method and cannot be set",
                .{private_name},
            );
        },

        // 4. If entry.[[Kind]] is field, then
        .field => |*value_ptr| {
            // a. Set entry.[[Value]] to value.
            value_ptr.* = value;
        },

        // 5. Else,
        //     a. Assert: entry.[[Kind]] is accessor.
        .accessor => |accessor| {
            // c. Let setter be entry.[[Setter]].
            // b. If entry.[[Setter]] is undefined, throw a TypeError exception.
            const setter = accessor.setter orelse {
                return agent.throwException(
                    .type_error,
                    "Private element '{f}' has no setter",
                    .{private_name},
                );
            };

            // d. Perform ? Call(setter, obj, « value »).
            _ = try setter.call(agent, Value.from(obj), &.{value});
        },
    }

    // 6. Return unused.
}

/// 7.3.32 DefineField ( receiver, fieldRecord )
/// https://tc39.es/ecma262/#sec-definefield
pub fn defineField(receiver: *Object, agent: *Agent, field: ClassFieldDefinition) Agent.Error!void {
    // 1. Let fieldName be fieldRecord.[[Name]].

    // 2. Let initializer be fieldRecord.[[Initializer]].
    // 3. If initializer is not empty, then
    const init_value: Value = if (field.initializer) |initializer| blk: {
        // a. Let initValue be ? Call(initializer, receiver).
        break :blk try initializer.object.call(agent, Value.from(receiver), &.{});
    } else blk: {
        // 4. Else,
        // a. Let initValue be undefined.
        break :blk .undefined;
    };

    switch (field.name) {
        // 5. If fieldName is a Private Name, then
        .private_name => |private_name| {
            // a. Perform ? PrivateFieldAdd(receiver, fieldName, initValue).
            try receiver.privateFieldAdd(agent, private_name, init_value);
        },
        // 6. Else,
        .property_key => |property_key| {
            // a. Assert: fieldName is a property key.
            // b. Perform ? CreateDataPropertyOrThrow(receiver, fieldName, initValue).
            try receiver.createDataPropertyOrThrow(agent, property_key, init_value);
        },
    }

    // 7. Return unused.
}

/// 7.3.33 InitializeInstanceElements ( obj, ctor )
/// https://tc39.es/ecma262/#sec-initializeinstanceelements
pub fn initializeInstanceElements(
    obj: *Object,
    agent: *Agent,
    ctor: *Object,
) Agent.Error!void {
    // 1. Let methods be ctor.[[PrivateMethods]].
    const methods = if (ctor.cast(builtins.ECMAScriptFunction)) |ecmascript_function| blk: {
        break :blk if (ecmascript_function.fields.class_data) |class_data|
            class_data.private_methods
        else
            &.{};
    } else if (ctor.cast(builtins.BuiltinFunction)) |builtin_function| blk: {
        const class_constructor_fields = builtin_function.fields.additionalFieldsAs(ClassConstructorFields);
        break :blk class_constructor_fields.private_methods;
    } else unreachable;

    // 2. For each PrivateElement method of methods, do
    for (methods) |method| {
        // a. Perform ? PrivateMethodOrAccessorAdd(obj, method).
        try obj.privateMethodOrAccessorAdd(agent, method.private_name, method.private_element);
    }

    // 3. Let fields be ctor.[[Fields]].
    const fields = if (ctor.cast(builtins.ECMAScriptFunction)) |ecmascript_function| blk: {
        break :blk if (ecmascript_function.fields.class_data) |class_data|
            class_data.fields
        else
            &.{};
    } else if (ctor.cast(builtins.BuiltinFunction)) |builtin_function| blk: {
        const class_constructor_fields = builtin_function.fields.additionalFieldsAs(ClassConstructorFields);
        break :blk class_constructor_fields.fields;
    } else unreachable;

    // 4. For each element fieldRecord of fields, do
    for (fields) |field| {
        // a. Perform ? DefineField(obj, fieldRecord).
        try obj.defineField(agent, field);
    }

    // 5. Return unused.
}

pub const OptionType = enum {
    boolean,
    string,

    pub fn T(self: OptionType) type {
        return switch (self) {
            .boolean => bool,
            .string => *const String,
        };
    }
};

/// 9.2.11 GetOption ( options, propertyKey, type, values, default )
/// https://tc39.es/ecma402/#sec-getoption
pub fn getOption(
    self: *Object,
    agent: *Agent,
    comptime property_key: []const u8,
    comptime @"type": OptionType,
    values: ?[]const @"type".T(),
    default: anytype,
) Agent.Error!if (@TypeOf(default) == @TypeOf(null)) ?@"type".T() else @"type".T() {
    if (@TypeOf(default) != @TypeOf(null) and @TypeOf(default) != @"type".T() and default != .required) {
        @compileError("Invalid value for default parameter");
    }

    // 1. Let value be ? Get(options, propertyKey).
    const value = try self.get(agent, PropertyKey.from(property_key));

    // 2. If value is undefined, then
    if (value.isUndefined()) {
        // a. If default is required, throw a TypeError exception.
        if (@TypeOf(default) == @TypeOf(.required)) {
            return agent.throwException(
                .type_error,
                "Required option '{s}' must not be undefined",
                .{property_key},
            );
        }

        // b. Return default.
        return default;
    }

    const coerced_value = switch (@"type") {
        // 3. If type is boolean, then
        .boolean => blk: {
            // a. Set value to ToBoolean(value).
            break :blk value.toBoolean();
        },

        // 4. Else,
        //     a. Assert: type is string.
        .string => blk: {
            // b. Set value to ? ToString(value).
            break :blk try value.toString(agent);
        },
    };

    // 5. If values is not empty and values does not contain value, throw a RangeError exception.
    if (values != null) {
        for (values.?) |permitted_value| {
            if (sameValue(Value.from(coerced_value), Value.from(permitted_value))) break;
        } else {
            return agent.throwException(
                .range_error,
                "Invalid value for option '{s}'",
                .{property_key},
            );
        }
    }

    // 6. Return value.
    return coerced_value;
}

test format {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var environ_map = try std.process.Environ.createMap(.empty, gpa);
    defer environ_map.deinit();
    const platform: Agent.Platform = .default(io, &environ_map);
    defer platform.deinit();
    var agent_ = try Agent.init(gpa, io, &platform, .{});
    defer agent_.deinit();

    const test_cases = [_]struct { *Object, []const u8 }{
        .{ try ordinaryObjectCreate(&agent_, null), "[object Object]" },
    };
    for (test_cases) |test_case| {
        const object, const expected = test_case;
        try std.testing.expectFmt(expected, "{f}", .{object});
    }
}
