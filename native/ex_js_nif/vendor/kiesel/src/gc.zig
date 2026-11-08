const std = @import("std");

const bdwgc = @import("bdwgc");

const build_options = @import("build-options");

pub const allocator = bdwgc.allocator;
pub const allocator_atomic = bdwgc.allocator_atomic;

pub fn init() void {
    if (bdwgc.isInitCalled()) return;
    bdwgc.init();
    if (build_options.enable_nan_boxing) {
        bdwgc.setPointerMask(std.math.maxInt(u48));
    }
    bdwgc.startMarkThreads();
}

pub fn disable() void {
    bdwgc.disable();
}

pub fn collect() void {
    bdwgc.gcollect();
}

pub fn disableWarnings() void {
    bdwgc.disableWarnings();
}

pub fn size(ptr: *const anyopaque) usize {
    return bdwgc.size(ptr);
}

pub fn FinalizerData(comptime T: type) type {
    return struct {
        nextFinalizerFunc: ?*const fn (*anyopaque, ?*anyopaque) callconv(.c) void = null,
        next_finalizer_data: ?*anyopaque = null,
        data: T,
    };
}

pub fn registerFinalizer(
    object: *anyopaque,
    /// Must be a `*FinalizerData(T)`.
    finalizer_data: anytype,
    comptime finalizer: *const fn (object: *anyopaque, data: *@TypeOf(finalizer_data.data)) void,
) void {
    if (bdwgc.registerFinalizer(
        object,
        struct {
            fn func(object_: *anyopaque, data: ?*anyopaque) callconv(.c) void {
                const finalizer_data_: @TypeOf(finalizer_data) = @ptrCast(@alignCast(data));
                finalizer(object_, &finalizer_data_.data);
                if (finalizer_data_.nextFinalizerFunc) |nextFinalizerFunc| {
                    nextFinalizerFunc(object_, finalizer_data_.next_finalizer_data);
                }
            }
        }.func,
        finalizer_data,
    )) |old| {
        finalizer_data.nextFinalizerFunc = old.finalizer;
        finalizer_data.next_finalizer_data = old.data;
    }
}

/// Asserts that the link has not already been registered with an object.
pub fn registerDisappearingLink(link: *?*anyopaque, object: *const anyopaque) std.mem.Allocator.Error!void {
    bdwgc.registerDisappearingLink(link, object) catch |err| switch (err) {
        error.DuplicateLink => unreachable,
        error.OutOfMemory => |e| return e,
    };
}
