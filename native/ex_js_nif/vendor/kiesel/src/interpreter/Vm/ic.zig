const std = @import("std");

const execution = @import("../../execution.zig");
const types = @import("../../types.zig");
const utils = @import("../../utils.zig");

const Agent = execution.Agent;
const BoundedArray = utils.BoundedArray;
const Object = types.Object;
const PropertyKey = types.PropertyKey;
const Value = types.Value;

fn State(comptime Entry: type, comptime Key: type) type {
    return union(enum) {
        empty,
        monomorphic: Entry,
        polymorphic: Entries,
        megamorphic,

        const Entries = BoundedArray(Entry, 4);

        fn get(state: *const @This(), key: Key) ?struct { *const Entry, *Object } {
            switch (state.*) {
                .empty, .megamorphic => {},
                .monomorphic => |*entry| {
                    if (entry.resolve(key)) |holder| return .{ entry, holder };
                },
                .polymorphic => |*entries| {
                    for (entries.slice()) |*entry| {
                        if (entry.resolve(key)) |holder| return .{ entry, holder };
                    }
                },
            }
            return null;
        }

        fn add(state: *@This(), new_entry: Entry) void {
            switch (state.*) {
                .empty => {
                    state.* = .{ .monomorphic = new_entry };
                },
                .monomorphic => |*entry| {
                    var entries: Entries = .empty;
                    entries.append(entry.*) catch unreachable;
                    entries.append(new_entry) catch unreachable;
                    state.* = .{ .polymorphic = entries };
                },
                .polymorphic => |*entries| {
                    entries.append(new_entry) catch {
                        state.* = .megamorphic;
                    };
                },
                .megamorphic => {},
            }
        }
    };
}

const ProtoShapes = BoundedArray(*const Object.Shape, 4);

pub const GetProperty = struct {
    const Entry = struct {
        receiver_shape: *const Object.Shape,
        proto_shapes: ProtoShapes,
        offset: Object.Shape.Property.Offset,
        type: Object.Shape.Property.Type,

        fn resolve(entry: *const Entry, key: Key) ?*Object {
            if (key.receiver.shape != entry.receiver_shape) return null;
            var current = key.receiver;
            for (entry.proto_shapes.slice()) |proto_shape| {
                current = current.shape.prototype.?;
                if (current.shape != proto_shape) return null;
            }
            return current;
        }
    };
    const Key = struct {
        receiver: *Object,
    };

    state: State(Entry, Key),

    pub const empty: GetProperty = .{ .state = .empty };

    pub fn get(
        ic: *const GetProperty,
        agent: *Agent,
        receiver: *Object,
        base_value: Value,
    ) Agent.Error!?Value {
        const key: Key = .{ .receiver = receiver };
        const entry, const holder = ic.state.get(key) orelse return null;

        const has_ordinary_internal_methods = holder.internalMethods().flags.supersetOf(
            comptime .initMany(&.{
                .ordinary_get,
                .ordinary_get_own_property,
            }),
        );
        // Assert IC update invariants are upheld
        std.debug.assert(has_ordinary_internal_methods);
        std.debug.assert(!holder.shape.isUnique());

        switch (entry.type) {
            .value => return holder.getValueAtPropertyOffset(entry.offset),
            .accessor => {
                const getter_value = holder.getValueAtPropertyOffset(entry.offset);
                if (getter_value.isNull()) {
                    @branchHint(.unlikely);
                    return .undefined;
                }
                const getter = getter_value.asObject();
                return try getter.call(agent, base_value, &.{});
            },
        }
    }

    pub fn update(
        ic: *GetProperty,
        receiver: *Object,
        property_key: PropertyKey,
    ) void {
        var proto_shapes: ProtoShapes = .empty;
        var current: *Object = receiver;
        const property = while (true) {
            const has_ordinary_internal_methods = current.internalMethods().flags.supersetOf(
                comptime .initMany(&.{
                    .ordinary_get,
                    .ordinary_get_own_property,
                }),
            );
            if (!has_ordinary_internal_methods) return;
            if (current.shape.isUnique()) return;

            if (current.shape.properties.get(property_key)) |property| break property;

            const proto = current.shape.prototype orelse return;
            proto_shapes.append(proto.shape) catch return;
            current = proto;
        };

        ic.state.add(.{
            .receiver_shape = receiver.shape,
            .proto_shapes = proto_shapes,
            .offset = property.offset,
            .type = property.type,
        });
    }
};

pub const GetPropertyComputed = struct {
    const Entry = struct {
        receiver_shape: *const Object.Shape,
        proto_shapes: ProtoShapes,
        property_key: PropertyKey,
        offset: Object.Shape.Property.Offset,
        type: Object.Shape.Property.Type,

        fn resolve(entry: *const Entry, key: Key) ?*Object {
            if (!key.property_key.eql(entry.property_key)) return null;
            if (key.receiver.shape != entry.receiver_shape) return null;
            var current = key.receiver;
            for (entry.proto_shapes.slice()) |proto_shape| {
                current = current.shape.prototype.?;
                if (current.shape != proto_shape) return null;
            }
            return current;
        }
    };
    const Key = struct {
        receiver: *Object,
        property_key: PropertyKey,
    };

    state: State(Entry, Key),

    pub const empty: GetPropertyComputed = .{ .state = .empty };

    pub fn get(
        ic: *const GetPropertyComputed,
        agent: *Agent,
        receiver: *Object,
        base_value: Value,
        property_key: PropertyKey,
    ) Agent.Error!?Value {
        if (property_key == .integer_index) return null;
        const key: Key = .{ .receiver = receiver, .property_key = property_key };
        const entry, const holder = ic.state.get(key) orelse return null;

        const has_ordinary_internal_methods = holder.internalMethods().flags.supersetOf(
            comptime .initMany(&.{
                .ordinary_get,
                .ordinary_get_own_property,
            }),
        );
        // Assert IC update invariants are upheld
        std.debug.assert(has_ordinary_internal_methods);
        std.debug.assert(!holder.shape.isUnique());

        switch (entry.type) {
            .value => return holder.getValueAtPropertyOffset(entry.offset),
            .accessor => {
                const getter_value = holder.getValueAtPropertyOffset(entry.offset);
                if (getter_value.isNull()) {
                    @branchHint(.unlikely);
                    return .undefined;
                }
                const getter = getter_value.asObject();
                return try getter.call(agent, base_value, &.{});
            },
        }
    }

    pub fn update(
        ic: *GetPropertyComputed,
        receiver: *Object,
        property_key: PropertyKey,
    ) void {
        // Indices go through their own indexed property fast path
        if (property_key == .integer_index) return;

        var proto_shapes: ProtoShapes = .empty;
        var current: *Object = receiver;
        const property = while (true) {
            const has_ordinary_internal_methods = current.internalMethods().flags.supersetOf(
                comptime .initMany(&.{
                    .ordinary_get,
                    .ordinary_get_own_property,
                }),
            );
            if (!has_ordinary_internal_methods) return;
            if (current.shape.isUnique()) return;

            if (current.shape.properties.get(property_key)) |property| break property;

            const proto = current.shape.prototype orelse return;
            proto_shapes.append(proto.shape) catch return;
            current = proto;
        };

        ic.state.add(.{
            .receiver_shape = receiver.shape,
            .proto_shapes = proto_shapes,
            .property_key = property_key,
            .offset = property.offset,
            .type = property.type,
        });
    }
};

pub const SetProperty = struct {
    const Entry = struct {
        receiver_shape: *const Object.Shape,
        offset: Object.Shape.Property.Offset,
        type: Object.Shape.Property.Type,

        fn resolve(entry: *const Entry, key: Key) ?*Object {
            if (key.receiver.shape != entry.receiver_shape) return null;
            return key.receiver;
        }
    };
    const Key = struct {
        receiver: *Object,
    };

    state: State(Entry, Key),

    pub const empty: SetProperty = .{ .state = .empty };

    pub fn set(
        ic: *const SetProperty,
        agent: *Agent,
        receiver: *Object,
        base_value: Value,
        value: Value,
    ) Agent.Error!bool {
        const key: Key = .{ .receiver = receiver };
        const entry, const holder = ic.state.get(key) orelse return false;

        const has_ordinary_internal_methods = holder.internalMethods().flags.supersetOf(
            comptime .initMany(&.{
                .ordinary_set,
                .ordinary_get_own_property,
            }),
        );
        // Assert IC update invariants are upheld
        std.debug.assert(has_ordinary_internal_methods);
        std.debug.assert(!holder.shape.isUnique());

        switch (entry.type) {
            .value => {
                holder.setValueAtPropertyOffset(entry.offset, value);
                return true;
            },
            .accessor => {
                const setter_value = holder.getValueAtPropertyOffset(
                    @fromBackingInt(@backingInt(entry.offset) + 1),
                );
                if (setter_value.isNull()) {
                    @branchHint(.unlikely);
                    return false;
                }
                const setter = setter_value.asObject();
                _ = try setter.call(agent, base_value, &.{value});
                return true;
            },
        }
    }

    pub fn update(
        ic: *SetProperty,
        receiver: *Object,
        property_key: PropertyKey,
    ) void {
        const has_ordinary_internal_methods = receiver.internalMethods().flags.supersetOf(
            comptime .initMany(&.{
                .ordinary_set,
                .ordinary_get_own_property,
            }),
        );
        if (!has_ordinary_internal_methods) return;
        if (receiver.shape.isUnique()) return;

        const property = receiver.shape.properties.get(property_key) orelse return;
        if (property.type == .value and !property.attributes.writable) return;

        ic.state.add(.{
            .receiver_shape = receiver.shape,
            .offset = property.offset,
            .type = property.type,
        });
    }
};

pub const SetPropertyComputed = struct {
    const Entry = struct {
        receiver_shape: *const Object.Shape,
        property_key: PropertyKey,
        offset: Object.Shape.Property.Offset,
        type: Object.Shape.Property.Type,

        fn resolve(entry: *const Entry, key: Key) ?*Object {
            if (!key.property_key.eql(entry.property_key)) return null;
            if (key.receiver.shape != entry.receiver_shape) return null;
            return key.receiver;
        }
    };
    const Key = struct {
        receiver: *Object,
        property_key: PropertyKey,
    };

    state: State(Entry, Key),

    pub const empty: SetPropertyComputed = .{ .state = .empty };

    pub fn set(
        ic: *const SetPropertyComputed,
        agent: *Agent,
        receiver: *Object,
        base_value: Value,
        property_key: PropertyKey,
        value: Value,
    ) Agent.Error!bool {
        if (property_key == .integer_index) return false;
        const key: Key = .{ .receiver = receiver, .property_key = property_key };
        const entry, const holder = ic.state.get(key) orelse return false;

        const has_ordinary_internal_methods = holder.internalMethods().flags.supersetOf(
            comptime .initMany(&.{
                .ordinary_set,
                .ordinary_get_own_property,
            }),
        );
        // Assert IC update invariants are upheld
        std.debug.assert(has_ordinary_internal_methods);
        std.debug.assert(!holder.shape.isUnique());

        switch (entry.type) {
            .value => {
                holder.setValueAtPropertyOffset(entry.offset, value);
                return true;
            },
            .accessor => {
                const setter_value = holder.getValueAtPropertyOffset(
                    @fromBackingInt(@backingInt(entry.offset) + 1),
                );
                if (setter_value.isNull()) {
                    @branchHint(.unlikely);
                    return false;
                }
                const setter = setter_value.asObject();
                _ = try setter.call(agent, base_value, &.{value});
                return true;
            },
        }
    }

    pub fn update(
        ic: *SetPropertyComputed,
        receiver: *Object,
        property_key: PropertyKey,
    ) void {
        // Indices go through their own indexed property fast path
        if (property_key == .integer_index) return;

        const has_ordinary_internal_methods = receiver.internalMethods().flags.supersetOf(
            comptime .initMany(&.{
                .ordinary_set,
                .ordinary_get_own_property,
            }),
        );
        if (!has_ordinary_internal_methods) return;
        if (receiver.shape.isUnique()) return;

        const property = receiver.shape.properties.get(property_key) orelse return;
        if (property.type == .value and !property.attributes.writable) return;

        ic.state.add(.{
            .receiver_shape = receiver.shape,
            .property_key = property_key,
            .offset = property.offset,
            .type = property.type,
        });
    }
};
