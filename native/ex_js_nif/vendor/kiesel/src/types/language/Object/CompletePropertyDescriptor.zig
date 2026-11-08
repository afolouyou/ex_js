//! Like the regular `PropertyDescriptor` but only with complete states - either value or accessor,
//! all attributes set - representable.

const types = @import("../../../types.zig");

const Object = types.Object;
const PropertyDescriptor = types.PropertyDescriptor;
const Value = types.Value;

const CompletePropertyDescriptor = @This();

value_or_accessor: ValueOrAccessor,
attributes: Object.Shape.Property.Attributes,

pub const ValueOrAccessor = union(enum) {
    value: Value,
    accessor: Object.Accessor,
};

pub fn toPropertyDescriptor(self: *const CompletePropertyDescriptor) PropertyDescriptor {
    return switch (self.value_or_accessor) {
        .value => |value| .{
            .value = value,
            .writable = self.attributes.writable,
            .enumerable = self.attributes.enumerable,
            .configurable = self.attributes.configurable,
        },
        .accessor => |accessor| .{
            .getter = if (accessor.getter) |object| object else @as(?*Object, null),
            .setter = if (accessor.setter) |object| object else @as(?*Object, null),
            .enumerable = self.attributes.enumerable,
            .configurable = self.attributes.configurable,
        },
    };
}
