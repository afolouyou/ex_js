const std = @import("std");

const Value = @import("../Value.zig");
const Object = @import("../Object.zig");
const Symbol = @import("../Symbol.zig");

/// A value that does not prevent the underlying data from being garbage
/// collected. Only supports object and symbol types.
pub const Weak = union(enum) {
    object: MaskedPtr(*Object),
    symbol: MaskedPtr(*const Symbol),

    pub fn init(value: Value) Weak {
        return switch (value.type()) {
            .object => .{ .object = .init(value.asObject()) },
            .symbol => .{ .symbol = .init(value.asSymbol()) },
            else => unreachable,
        };
    }

    /// The returned value may have already been garbage collected.
    pub fn get(weak: Weak) Value {
        return switch (weak) {
            .object => |object_ptr| Value.from(object_ptr.get()),
            .symbol => |symbol_ptr| Value.from(symbol_ptr.get()),
        };
    }

    /// The returned pointer may have already been garbage collected.
    pub fn getPtr(weak: Weak) *anyopaque {
        return switch (weak) {
            .object => |object_ptr| object_ptr.get(),
            .symbol => |symbol_ptr| @constCast(symbol_ptr.get()),
        };
    }

    /// Shortcut for the SameValue AO applied on two weak values (i.e. pointer equality)
    pub fn sameValue(a: Weak, b: Weak) bool {
        // The tags must be the same if they point to the same value.
        return a.getPtr() == b.getPtr();
    }

    pub fn HashMap(comptime V: type) type {
        return std.HashMapUnmanaged(Value.Weak, V, struct {
            pub fn hash(_: @This(), weak: Weak) u64 {
                // Store the masked version of the pointers.
                return switch (weak) {
                    .object => |object| @backingInt(object),
                    .symbol => |symbol| @backingInt(symbol),
                };
            }
            pub fn eql(_: @This(), a: Weak, b: Weak) bool {
                // We must use the shortcut version of SameValue to avoid reading
                // garbage collected pointers when we remove finalized keys.
                return a.sameValue(b);
            }
        }, std.hash_map.default_max_load_percentage);
    }
};

fn MaskedPtr(comptime T: type) type {
    return enum(usize) {
        _,

        pub fn init(ptr: T) @This() {
            return @fromBackingInt(~@intFromPtr(ptr));
        }

        pub fn get(masked_ptr: @This()) T {
            const masked_bits: usize = @backingInt(masked_ptr);
            return @ptrFromInt(~masked_bits);
        }
    };
}
