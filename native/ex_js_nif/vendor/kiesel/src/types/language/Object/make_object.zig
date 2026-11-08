const std = @import("std");

const build_options = @import("build-options");
const execution = @import("../../../execution.zig");
const gc = @import("../../../gc.zig");
const types = @import("../../../types.zig");

const Agent = execution.Agent;
const InternalMethods = @import("InternalMethods.zig");
const Object = types.Object;

pub fn MakeObject(
    comptime options: struct {
        Fields: type = void,
        finalizer: ?fn (object: *Object) void = null,
        tag: Object.Tag,
        display_name: []const u8,
    },
) type {
    const has_fields = options.Fields != void;
    const has_is_htmldda = @FieldType(Object.Shape, "is_htmldda") != void;

    // FIXME: Can we dedupe this?
    const Args = if (has_fields and has_is_htmldda) struct {
        fields: options.Fields,
        prototype: ?*Object,
        extensible: bool = true,
        is_htmldda: bool = false,
        internal_methods: *const InternalMethods = .default,
    } else if (has_fields) struct {
        fields: options.Fields,
        prototype: ?*Object,
        extensible: bool = true,
        internal_methods: *const InternalMethods = .default,
    } else if (has_is_htmldda) struct {
        prototype: ?*Object,
        extensible: bool = true,
        is_htmldda: bool = false,
        internal_methods: *const InternalMethods = .default,
    } else struct {
        prototype: ?*Object,
        extensible: bool = true,
        internal_methods: *const InternalMethods = .default,
    };

    const ArgsWithShape = if (has_fields) struct {
        fields: options.Fields,
        shape: *Object.Shape,
    } else struct {
        shape: *Object.Shape,
    };

    return struct {
        const Self = @This();

        pub const Fields = options.Fields;
        pub const tag = options.tag;
        pub const display_name = options.display_name;

        fields: Fields,
        object: Object,

        pub fn create(agent: *Agent, args: Args) std.mem.Allocator.Error!*Self {
            const self = try agent.gc_allocator.create(Self);
            errdefer agent.gc_allocator.destroy(self);
            self.* = .{
                .fields = if (has_fields) args.fields,
                .object = .{
                    .tag = options.tag,
                    .shape = agent.empty_shape,
                    .properties = .empty,
                    .extra_data = null,
                },
            };
            if (args.internal_methods != Object.InternalMethods.default) {
                try self.object.setInternalMethods(agent, args.internal_methods);
            }
            if (args.prototype != null) {
                try self.object.setPrototype(agent, args.prototype);
            }
            if (!args.extensible) {
                try self.object.setNonExtensible(agent);
            }
            if (has_is_htmldda and args.is_htmldda) {
                try self.object.setIsHTMLDDA(agent);
            }
            if (build_options.enable_libgc) {
                if (options.finalizer) |finalizer| {
                    try self.addFinalizer(agent, finalizer);
                }
            }
            return self;
        }

        pub fn createWithShape(agent: *Agent, args: ArgsWithShape) std.mem.Allocator.Error!*Self {
            const self = try agent.gc_allocator.create(Self);
            errdefer agent.gc_allocator.destroy(self);
            self.* = .{
                .fields = if (has_fields) args.fields,
                .object = .{
                    .tag = options.tag,
                    .shape = args.shape,
                    .properties = .empty,
                    .extra_data = null,
                },
            };
            try self.object.ensureProperties(
                agent.gc_allocator,
                @backingInt(args.shape.next_offset),
            );
            if (build_options.enable_libgc) {
                if (options.finalizer) |finalizer| {
                    try self.addFinalizer(agent, finalizer);
                }
            }
            return self;
        }

        fn addFinalizer(
            self: *Self,
            agent: *Agent,
            comptime finalizerImpl: fn (object: *Object) void,
        ) std.mem.Allocator.Error!void {
            const finalizer_data = try agent.gc_allocator.create(gc.FinalizerData(void));
            finalizer_data.* = .{ .data = {} };
            gc.registerFinalizer(self, finalizer_data, struct {
                fn finalizer(ptr: *anyopaque, _: *void) void {
                    const self_: *Self = @ptrCast(@alignCast(ptr));
                    finalizerImpl(&self_.object);
                }
            }.finalizer);
        }
    };
}
