const std = @import("std");

const build_options = @import("build-options");
const types = @import("../../../types.zig");

const Object = types.Object;
const InternalMethods = Object.InternalMethods;
const PropertyKey = types.PropertyKey;

const Shape = @This();

pub const Transition = union(enum) {
    set_internal_methods: *const InternalMethods,
    set_prototype: ?*Object,
    set_non_extensible,
    set_is_htmldda,
    set_property: struct { PropertyKey, Property.Attributes, Property.Type },
    delete_property: PropertyKey,

    pub fn hash(self: Transition) u64 {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(std.mem.asBytes(&std.meta.activeTag(self)));
        switch (self) {
            .set_internal_methods => |internal_methods| {
                hasher.update(std.mem.asBytes(&internal_methods));
            },
            .set_prototype => |prototype| {
                hasher.update(std.mem.asBytes(&prototype));
            },
            .set_non_extensible, .set_is_htmldda => {},
            .set_property => |property| {
                const property_key, const attributes, const property_type = property;
                hasher.update(std.mem.asBytes(&property_key.hash()));
                hasher.update(std.mem.asBytes(&attributes));
                hasher.update(std.mem.asBytes(&property_type));
            },
            .delete_property => |property_key| {
                hasher.update(std.mem.asBytes(&property_key.hash()));
            },
        }
        return hasher.final();
    }

    pub fn eql(a: Transition, b: Transition) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .set_internal_methods => a.set_internal_methods == b.set_internal_methods,
            .set_prototype => return a.set_prototype == b.set_prototype,
            .set_non_extensible, .set_is_htmldda => true,
            .set_property => a.set_property[0].eql(b.set_property[0]) and
                a.set_property[1] == b.set_property[1],
            .delete_property => a.delete_property.eql(b.delete_property),
        };
    }

    pub fn HashMap(comptime V: type) type {
        return std.HashMapUnmanaged(Transition, V, struct {
            pub fn hash(_: @This(), transition: Transition) u64 {
                return transition.hash();
            }

            pub fn eql(_: @This(), a: Transition, b: Transition) bool {
                return a.eql(b);
            }
        }, std.hash_map.default_max_load_percentage);
    }
};

pub const Property = struct {
    offset: Offset,
    type: Type,
    attributes: Attributes,

    pub const Offset = enum(u32) {
        zero = 0,
        _,
    };

    pub const Type = enum {
        value,
        accessor,
    };

    pub const Attributes = packed struct(u3) {
        writable: bool,
        enumerable: bool,
        configurable: bool,

        pub const all: Attributes = .{
            .writable = true,
            .enumerable = true,
            .configurable = true,
        };

        pub const none: Attributes = .{
            .writable = false,
            .enumerable = false,
            .configurable = false,
        };

        pub const builtin_default: Attributes = .{
            .writable = true,
            .enumerable = false,
            .configurable = true,
        };
    };
};

const TransitionCount = enum(u8) {
    zero = 0,

    /// This shape is no longer transitioning.
    unique = std.math.maxInt(u8),

    /// This shape has reached the maximum number of transitions and will be made unique the next
    /// time a transition is requested.
    ///
    /// The value is made up, here is what some other engines use:
    /// - V8:     1536 - https://source.chromium.org/chromium/chromium/src/+/main:v8/src/objects/transitions.h;l=149;drc=b047b59ea986553e7e56c1ede3d4a6bac33db846
    /// - SM:   32-100 - https://searchfox.org/firefox-main/rev/ccf89bb4e01e2a64f86cce9a39757535df9a693d/js/src/vm/PropMap.h#624-625
    /// - JSC: 128/512 - https://github.com/WebKit/WebKit/blob/f906531f9489f965c27ea3c5b7a5a819513d0270/Source/JavaScriptCore/runtime/Structure.h#L209-L211
    /// - LibJS:    64 - https://github.com/SerenityOS/serenity/blob/db49c7322225aa0671c6f61f20f5c4a5a6327307/Userland/Libraries/LibJS/Runtime/Object.cpp#L1220
    max = 64,

    /// Number of transitions that led to this shape.
    _,
};

transition_count: TransitionCount,
next_offset: Property.Offset,
transitions: Transition.HashMap(*Shape),
properties: PropertyKey.ArrayHashMap(Property),
internal_methods: *const InternalMethods,

/// [[Prototype]]
prototype: ?*Object,

/// [[Extensible]]
extensible: bool,

/// [[IsHTMLDDA]]
is_htmldda: if (build_options.enable_annex_b) bool else void,

pub fn init(allocator: std.mem.Allocator) std.mem.Allocator.Error!*Shape {
    const self = try allocator.create(Shape);
    self.* = .{
        .transition_count = .zero,
        .next_offset = .zero,
        .transitions = .empty,
        .properties = .empty,
        .internal_methods = .default,
        .prototype = null,
        .extensible = true,
        .is_htmldda = if (build_options.enable_annex_b) false,
    };
    return self;
}

pub fn deinit(self: *Shape, allocator: std.mem.Allocator) void {
    self.transitions.deinit(allocator);
    self.properties.deinit(allocator);
    allocator.destroy(self);
}

pub fn isUnique(self: *const Shape) bool {
    return self.transition_count == .unique;
}

pub fn makeUnique(self: *const Shape, allocator: std.mem.Allocator) std.mem.Allocator.Error!*Shape {
    std.debug.assert(self.transition_count != .unique);
    const shape = try self.clone(allocator);
    shape.transition_count = .unique;
    return shape;
}

fn clone(self: *const Shape, allocator: std.mem.Allocator) std.mem.Allocator.Error!*Shape {
    const shape = try allocator.create(Shape);
    errdefer allocator.destroy(shape);
    shape.* = .{
        .transition_count = self.transition_count,
        .next_offset = self.next_offset,
        .transitions = .empty,
        .properties = try self.properties.clone(allocator),
        .internal_methods = self.internal_methods,
        .prototype = self.prototype,
        .extensible = self.extensible,
        .is_htmldda = self.is_htmldda,
    };
    return shape;
}

fn getOrCreateShape(
    self: *Shape,
    allocator: std.mem.Allocator,
    transition: Transition,
) std.mem.Allocator.Error!*Shape {
    std.debug.assert(@backingInt(self.transition_count) < @backingInt(TransitionCount.max));
    const shape_gop = try self.transitions.getOrPut(allocator, transition);
    if (shape_gop.found_existing) return shape_gop.value_ptr.*;
    const shape = try self.clone(allocator);
    shape.transition_count = @fromBackingInt(@backingInt(self.transition_count) + 1);
    shape_gop.value_ptr.* = shape;
    return shape;
}

pub fn setInternalMethods(
    self: *Shape,
    allocator: std.mem.Allocator,
    internal_methods: *const InternalMethods,
) std.mem.Allocator.Error!*Shape {
    const shape = switch (self.transition_count) {
        .unique => self,
        .max => try self.makeUnique(allocator),
        else => try self.getOrCreateShape(allocator, .{ .set_internal_methods = internal_methods }),
    };
    shape.internal_methods = internal_methods;
    return shape;
}

pub fn setInternalMethodsWithoutTransition(self: *Shape, internal_methods: *const InternalMethods) void {
    // It's not valid to alter a shape that's part of a transition chain.
    std.debug.assert(self.transition_count == .zero or self.transition_count == .unique);
    self.internal_methods = internal_methods;
}

pub fn setPrototype(
    self: *Shape,
    allocator: std.mem.Allocator,
    prototype: ?*Object,
) std.mem.Allocator.Error!*Shape {
    const shape = switch (self.transition_count) {
        .unique => self,
        .max => try self.makeUnique(allocator),
        else => try self.getOrCreateShape(allocator, .{ .set_prototype = prototype }),
    };
    shape.prototype = prototype;
    return shape;
}

pub fn setPrototypeWithoutTransition(self: *Shape, prototype: ?*Object) void {
    // It's not valid to alter a shape that's part of a transition chain.
    std.debug.assert(self.transition_count == .zero or self.transition_count == .unique);
    self.prototype = prototype;
}

pub fn setNonExtensible(
    self: *Shape,
    allocator: std.mem.Allocator,
) std.mem.Allocator.Error!*Shape {
    const shape = switch (self.transition_count) {
        .unique => self,
        .max => try self.makeUnique(allocator),
        else => try self.getOrCreateShape(allocator, .set_non_extensible),
    };
    shape.extensible = false;
    return shape;
}

pub fn setNonExtensibleWithoutTransition(self: *Shape) void {
    // It's not valid to alter a shape that's part of a transition chain.
    std.debug.assert(self.transition_count == .zero or self.transition_count == .unique);
    self.extensible = false;
}

pub fn setIsHTMLDDA(
    self: *Shape,
    allocator: std.mem.Allocator,
) std.mem.Allocator.Error!*Shape {
    const shape = switch (self.transition_count) {
        .unique => self,
        .max => try self.makeUnique(allocator),
        else => try self.getOrCreateShape(allocator, .set_is_htmldda),
    };
    shape.is_htmldda = true;
    return shape;
}

pub fn setIsHTMLDDAWithoutTransition(self: *Shape) void {
    // It's not valid to alter a shape that's part of a transition chain.
    std.debug.assert(self.transition_count == .zero or self.transition_count == .unique);
    self.is_htmldda = true;
}

pub fn setProperty(
    self: *Shape,
    allocator: std.mem.Allocator,
    property_key: PropertyKey,
    attributes: Property.Attributes,
    property_type: Property.Type,
) std.mem.Allocator.Error!*Shape {
    const shape = switch (self.transition_count) {
        .unique => self,
        .max => try self.makeUnique(allocator),
        else => try self.getOrCreateShape(allocator, .{
            .set_property = .{ property_key, attributes, property_type },
        }),
    };
    const property_gop = try shape.properties.getOrPut(allocator, property_key);
    if (property_gop.found_existing and property_type == property_gop.value_ptr.type) {
        property_gop.value_ptr.*.attributes = attributes;
        return shape;
    }
    property_gop.value_ptr.* = .{
        .offset = shape.next_offset,
        .type = property_type,
        .attributes = attributes,
    };
    shape.next_offset = switch (property_type) {
        .value => @fromBackingInt(@backingInt(shape.next_offset) + 1),
        .accessor => @fromBackingInt(@backingInt(shape.next_offset) + 2),
    };
    return shape;
}

pub fn setPropertyWithoutTransition(
    self: *Shape,
    allocator: std.mem.Allocator,
    property_key: PropertyKey,
    attributes: Property.Attributes,
    property_type: Property.Type,
) std.mem.Allocator.Error!void {
    // It's not valid to alter a shape that's part of a transition chain.
    std.debug.assert(self.transition_count == .zero or self.transition_count == .unique);
    const property_gop = try self.properties.getOrPut(allocator, property_key);
    if (property_gop.found_existing and property_type == property_gop.value_ptr.type) {
        property_gop.value_ptr.*.attributes = attributes;
        return;
    }
    property_gop.value_ptr.* = .{
        .offset = self.next_offset,
        .type = property_type,
        .attributes = attributes,
    };
    self.next_offset = switch (property_type) {
        .value => @fromBackingInt(@backingInt(self.next_offset) + 1),
        .accessor => @fromBackingInt(@backingInt(self.next_offset) + 2),
    };
}

pub fn deleteProperty(
    self: *Shape,
    allocator: std.mem.Allocator,
    property_key: PropertyKey,
) std.mem.Allocator.Error!*Shape {
    const shape = switch (self.transition_count) {
        .unique => self,
        .max => try self.makeUnique(allocator),
        else => try self.getOrCreateShape(allocator, .{ .delete_property = property_key }),
    };
    // No-op if we got the shape from a previous transition
    _ = shape.properties.orderedRemove(property_key);
    return shape;
}

pub fn deletePropertyWithoutTransition(self: *Shape, property_key: PropertyKey) void {
    // It's not valid to alter a shape that's part of a transition chain.
    std.debug.assert(self.transition_count == .zero or self.transition_count == .unique);
    const removed = self.properties.orderedRemove(property_key);
    std.debug.assert(removed);
}
