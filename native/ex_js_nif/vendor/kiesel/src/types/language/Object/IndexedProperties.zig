const std = @import("std");

const types = @import("../../../types.zig");

const CompletePropertyDescriptor = Object.CompletePropertyDescriptor;
const Object = types.Object;
const Value = types.Value;

const IndexedProperties = @This();

storage: Storage,

pub const empty: IndexedProperties = .{
    .storage = .none,
};

pub const Index = u32;

pub const Storage = union(Type) {
    pub const Type = enum {
        none,
        dense_i32,
        dense_f64,
        dense_value,
        sparse_value,
        sparse_property_descriptor,
    };

    none,
    dense_i32: std.ArrayList(i32),
    dense_f64: std.ArrayList(f64),
    dense_value: std.ArrayList(Value),
    sparse_value: std.AutoHashMapUnmanaged(Index, Value),
    sparse_property_descriptor: std.AutoHashMapUnmanaged(Index, CompletePropertyDescriptor),

    pub fn isDense(self: *const Storage) bool {
        return switch (self) {
            .dense_i32, .dense_f64, .dense_value => true,
            else => false,
        };
    }
};

fn propertyDescriptorFromValue(value: Value) CompletePropertyDescriptor {
    return .{
        .value_or_accessor = .{
            .value = value,
        },
        .attributes = .all,
    };
}

pub fn migrateStorageIfNeeded(
    self: *IndexedProperties,
    allocator: std.mem.Allocator,
    index: Index,
    maybe_property_descriptor: ?CompletePropertyDescriptor,
) std.mem.Allocator.Error!void {
    const old_storage_type = std.meta.activeTag(self.storage);
    const new_storage_type: Storage.Type = blk: {
        // Property set or addition
        if (maybe_property_descriptor) |property_descriptor| {
            if (old_storage_type == .sparse_property_descriptor or // No downgrades
                property_descriptor.value_or_accessor == .accessor or // Accessor property
                property_descriptor.attributes != Object.Shape.Property.Attributes.all // Non-default properties
            ) {
                break :blk .sparse_property_descriptor;
            }
            if (old_storage_type == .sparse_value or // No downgrades
                index > self.count() // Created an array hole
            ) {
                break :blk .sparse_value;
            }
            if (property_descriptor.value_or_accessor.value.__isI32()) {
                switch (old_storage_type) {
                    .none => break :blk .dense_i32,
                    else => return,
                }
            }
            if (property_descriptor.value_or_accessor.value.__isF64()) {
                switch (old_storage_type) {
                    .none, .dense_i32 => break :blk .dense_f64,
                    else => return,
                }
            }
            break :blk .dense_value;
        }
        // Property removal
        else switch (old_storage_type) {
            .none => unreachable,
            .dense_i32, .dense_f64, .dense_value => {
                if (index + 1 == self.count()) {
                    if (index == 0) break :blk .none;
                    break :blk old_storage_type;
                }
                break :blk .sparse_value;
            },
            .sparse_value, .sparse_property_descriptor => break :blk old_storage_type,
        }
    };
    if (old_storage_type != new_storage_type) {
        try self.migrateStorage(allocator, new_storage_type);
    }
}

pub fn migrateStorage(
    self: *IndexedProperties,
    allocator: std.mem.Allocator,
    new_storage_type: Storage.Type,
) std.mem.Allocator.Error!void {
    const old_storage_type = std.meta.activeTag(self.storage);
    std.debug.assert(@backingInt(old_storage_type) < @backingInt(new_storage_type) or
        new_storage_type == .none);
    self.storage = switch (new_storage_type) {
        .none => blk: {
            switch (self.storage) {
                .none => unreachable,
                .dense_i32 => |*dense_i32| dense_i32.deinit(allocator),
                .dense_f64 => |*dense_f64| dense_f64.deinit(allocator),
                .dense_value => |*dense_value| dense_value.deinit(allocator),
                .sparse_value => |*sparse_value| sparse_value.deinit(allocator),
                .sparse_property_descriptor => |*sparse_property_descriptor| sparse_property_descriptor.deinit(allocator),
            }
            break :blk .none;
        },
        .dense_i32 => blk: {
            const dense_i32: std.ArrayList(i32) = .empty;
            switch (self.storage) {
                .none => {},
                .dense_i32, .dense_f64, .dense_value, .sparse_value, .sparse_property_descriptor => unreachable,
            }
            break :blk .{ .dense_i32 = dense_i32 };
        },
        .dense_f64 => blk: {
            var dense_f64: std.ArrayList(f64) = .empty;
            switch (self.storage) {
                .none => {},
                .dense_i32 => |*dense_i32| {
                    try dense_f64.resize(allocator, dense_i32.items.len);
                    for (dense_i32.items, 0..) |value, i| {
                        dense_f64.items[i] = @floatFromInt(value);
                    }
                    dense_i32.deinit(allocator);
                },
                .dense_f64, .dense_value, .sparse_value, .sparse_property_descriptor => unreachable,
            }
            break :blk .{ .dense_f64 = dense_f64 };
        },
        .dense_value => blk: {
            var dense_value: std.ArrayList(Value) = .empty;
            switch (self.storage) {
                .none => {},
                .dense_i32 => |*dense_i32| {
                    try dense_value.resize(allocator, dense_i32.items.len);
                    for (dense_i32.items, 0..) |value, i| {
                        dense_value.items[i] = Value.from(value);
                    }
                    dense_i32.deinit(allocator);
                },
                .dense_f64 => |*dense_f64| {
                    try dense_value.resize(allocator, dense_f64.items.len);
                    for (dense_f64.items, 0..) |value, i| {
                        dense_value.items[i] = Value.from(value);
                    }
                    dense_f64.deinit(allocator);
                },
                .dense_value, .sparse_value, .sparse_property_descriptor => unreachable,
            }
            break :blk .{ .dense_value = dense_value };
        },
        .sparse_value => blk: {
            var sparse_value: std.AutoHashMapUnmanaged(Index, Value) = .empty;
            switch (self.storage) {
                .none => {},
                .dense_i32 => |*dense_i32| {
                    try sparse_value.ensureTotalCapacity(
                        allocator,
                        @intCast(dense_i32.items.len),
                    );
                    for (dense_i32.items, 0..) |value, i| {
                        sparse_value.putAssumeCapacity(@intCast(i), Value.from(value));
                    }
                    dense_i32.deinit(allocator);
                },
                .dense_f64 => |*dense_f64| {
                    try sparse_value.ensureTotalCapacity(
                        allocator,
                        @intCast(dense_f64.items.len),
                    );
                    for (dense_f64.items, 0..) |value, i| {
                        sparse_value.putAssumeCapacity(@intCast(i), Value.from(value));
                    }
                    dense_f64.deinit(allocator);
                },
                .dense_value => |*dense_value| {
                    try sparse_value.ensureTotalCapacity(
                        allocator,
                        @intCast(dense_value.items.len),
                    );
                    for (dense_value.items, 0..) |value, i| {
                        sparse_value.putAssumeCapacity(@intCast(i), value);
                    }
                    dense_value.deinit(allocator);
                },
                .sparse_value, .sparse_property_descriptor => unreachable,
            }
            break :blk .{ .sparse_value = sparse_value };
        },
        .sparse_property_descriptor => blk: {
            var sparse_property_descriptor: std.AutoHashMapUnmanaged(Index, CompletePropertyDescriptor) = .empty;
            switch (self.storage) {
                .none => {},
                .dense_i32 => |*dense_i32| {
                    try sparse_property_descriptor.ensureTotalCapacity(
                        allocator,
                        @intCast(dense_i32.items.len),
                    );
                    for (dense_i32.items, 0..) |value, i| {
                        sparse_property_descriptor.putAssumeCapacity(
                            @intCast(i),
                            propertyDescriptorFromValue(Value.from(value)),
                        );
                    }
                    dense_i32.deinit(allocator);
                },
                .dense_f64 => |*dense_f64| {
                    try sparse_property_descriptor.ensureTotalCapacity(
                        allocator,
                        @intCast(dense_f64.items.len),
                    );
                    for (dense_f64.items, 0..) |value, i| {
                        sparse_property_descriptor.putAssumeCapacity(
                            @intCast(i),
                            propertyDescriptorFromValue(Value.from(value)),
                        );
                    }
                    dense_f64.deinit(allocator);
                },
                .dense_value => |*dense_value| {
                    try sparse_property_descriptor.ensureTotalCapacity(
                        allocator,
                        @intCast(dense_value.items.len),
                    );
                    for (dense_value.items, 0..) |value, i| {
                        sparse_property_descriptor.putAssumeCapacity(
                            @intCast(i),
                            propertyDescriptorFromValue(value),
                        );
                    }
                    dense_value.deinit(allocator);
                },
                .sparse_value => |*sparse_value| {
                    try sparse_property_descriptor.ensureTotalCapacity(
                        allocator,
                        sparse_value.count(),
                    );
                    var it = sparse_value.iterator();
                    while (it.next()) |entry| {
                        sparse_property_descriptor.putAssumeCapacity(
                            entry.key_ptr.*,
                            propertyDescriptorFromValue(entry.value_ptr.*),
                        );
                    }
                    sparse_value.deinit(allocator);
                },
                .sparse_property_descriptor => unreachable,
            }
            break :blk .{ .sparse_property_descriptor = sparse_property_descriptor };
        },
    };
}

pub fn count(self: *const IndexedProperties) usize {
    switch (self.storage) {
        .none => return 0,
        .dense_i32 => |dense_i32| return dense_i32.items.len,
        .dense_f64 => |dense_f64| return dense_f64.items.len,
        .dense_value => |dense_value| return dense_value.items.len,
        .sparse_value => |sparse_value| return sparse_value.count(),
        .sparse_property_descriptor => |sparse_property_descriptor| return sparse_property_descriptor.count(),
    }
}

pub fn contains(self: *const IndexedProperties, index: Index) bool {
    switch (self.storage) {
        .none => return false,
        .dense_i32 => |dense_i32| return index < dense_i32.items.len,
        .dense_f64 => |dense_f64| return index < dense_f64.items.len,
        .dense_value => |dense_value| return index < dense_value.items.len,
        .sparse_value => |sparse_value| return sparse_value.contains(index),
        .sparse_property_descriptor => |sparse_property_descriptor| return sparse_property_descriptor.contains(index),
    }
}

pub fn get(self: *const IndexedProperties, index: Index) ?CompletePropertyDescriptor {
    switch (self.storage) {
        .none => return null,
        .dense_i32 => |dense_i32| {
            if (dense_i32.items.len <= index) return null;
            return propertyDescriptorFromValue(Value.from(dense_i32.items[index]));
        },
        .dense_f64 => |dense_f64| {
            if (dense_f64.items.len <= index) return null;
            return propertyDescriptorFromValue(Value.from(dense_f64.items[index]));
        },
        .dense_value => |dense_value| {
            if (dense_value.items.len <= index) return null;
            return propertyDescriptorFromValue(dense_value.items[index]);
        },
        .sparse_value => |sparse_value| {
            const value = sparse_value.get(index) orelse return null;
            return propertyDescriptorFromValue(value);
        },
        .sparse_property_descriptor => |sparse_property_descriptor| {
            return sparse_property_descriptor.get(index);
        },
    }
}

pub fn set(
    self: *IndexedProperties,
    allocator: std.mem.Allocator,
    index: Index,
    property_descriptor: CompletePropertyDescriptor,
) std.mem.Allocator.Error!void {
    try self.migrateStorageIfNeeded(allocator, index, property_descriptor);
    switch (self.storage) {
        .none => unreachable,
        .dense_i32 => |*dense_i32| {
            if (index >= dense_i32.items.len) try dense_i32.resize(allocator, index + 1);
            dense_i32.items[index] = property_descriptor.value_or_accessor.value.__asI32();
        },
        .dense_f64 => |*dense_f64| {
            if (index >= dense_f64.items.len) try dense_f64.resize(allocator, index + 1);
            dense_f64.items[index] = property_descriptor.value_or_accessor.value.__toF64();
        },
        .dense_value => |*dense_value| {
            if (index >= dense_value.items.len) try dense_value.resize(allocator, index + 1);
            dense_value.items[index] = property_descriptor.value_or_accessor.value;
        },
        .sparse_value => |*sparse_value| {
            try sparse_value.put(allocator, index, property_descriptor.value_or_accessor.value);
        },
        .sparse_property_descriptor => |*sparse_property_descriptor| {
            try sparse_property_descriptor.put(allocator, index, property_descriptor);
        },
    }
}

pub fn remove(
    self: *IndexedProperties,
    allocator: std.mem.Allocator,
    index: Index,
) std.mem.Allocator.Error!void {
    try self.migrateStorageIfNeeded(allocator, index, null);
    switch (self.storage) {
        .none => {},
        .dense_i32 => |*dense_i32| _ = dense_i32.pop().?,
        .dense_f64 => |*dense_f64| _ = dense_f64.pop().?,
        .dense_value => |*dense_value| _ = dense_value.pop().?,
        .sparse_value => |*sparse_value| {
            const removed = sparse_value.remove(index);
            std.debug.assert(removed);
        },
        .sparse_property_descriptor => |*sparse_property_descriptor| {
            const removed = sparse_property_descriptor.remove(index);
            std.debug.assert(removed);
        },
    }
}
