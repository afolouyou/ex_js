const std = @import("std");

const builtins = @import("../builtins.zig");
const execution = @import("../execution.zig");
const interpreter = @import("../interpreter.zig");
const language = @import("../language.zig");
const types = @import("../types.zig");

const Agent = execution.Agent;
const Parser = language.Parser;
const Realm = execution.Realm;
const Script = language.Script;
const Value = types.Value;

const ExpectedResult = union(enum) {
    value: ?LiteralValue,
    promise: struct { fulfilled: LiteralValue },
    exception,
    ignore,

    const LiteralValue = union(enum) {
        undefined,
        number: i32,
        string: []const u8,

        fn toValue(comptime self: LiteralValue) Value {
            return switch (self) {
                .undefined => .undefined,
                .number => |number| Value.from(number),
                .string => |string| Value.from(string),
            };
        }
    };
};

const TestCase = struct {
    source: [:0]const u8,
    expected_result: ExpectedResult,
    expected_output: []const u8,
};

const test_cases: []const TestCase = @import("test_cases.zon");

fn testInterpreter(
    gpa: std.mem.Allocator,
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
    source: [:0]const u8,
    comptime expected_result: ExpectedResult,
    expected_output: []const u8,
) !void {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();

    var arena_instance: std.heap.ArenaAllocator = .init(gpa);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    const script = try Parser.parse(language.ast.Script, arena, source, .{});

    var platform: Agent.Platform = .default(io, environ_map);
    defer platform.deinit();
    platform.stdout = &aw.writer;
    platform.stderr = &aw.writer;
    platform.terminal_mode = .no_color;

    var agent: Agent = try .init(gpa, io, &platform, .{
        .debug = .{
            .print_ir = true,
            .print_bytecode = true,
        },
    });
    defer agent.deinit();

    try Realm.initializeHostDefinedRealm(&agent, .{});

    const realm = agent.currentRealm();

    const script_record = try agent.gc_allocator.create(Script);
    script_record.* = .{
        .realm = realm,
        .ecmascript_code = script,
        .loaded_modules = .empty,
        .host_defined = null,
        .source = source,
    };

    const test_context = try agent.gc_allocator.create(execution.ExecutionContext);
    test_context.* = .{
        .origin = .script,
        .realm = realm,
        .script_or_module = .{ .script = script_record },
        .ecmascript_code = .{
            .variable_environment = .{ .global_environment = realm.global_env },
            .lexical_environment = .{ .global_environment = realm.global_env },
            .private_environment = null,
        },
    };
    try agent.execution_context_stack.append(agent.gc_allocator, test_context);
    defer _ = agent.execution_context_stack.pop().?;

    try Script.globalDeclarationInstantiation(&agent, script, realm.global_env, source);

    const result = interpreter.compileAndRun(&agent, .{ .script = &script }, "test");

    if (result) |value| switch (expected_result) {
        .value => |expected| if (expected != null) {
            if (value == null) return error.TestExpectedEqual;
            if (!expected.?.toValue().isStrictlyEqual(value.?)) return error.TestExpectedEqual;
        } else if (value != null) return error.TestExpectedEqual,
        .promise => |expected| {
            agent.drainJobQueue();
            const promise = (value orelse return error.TestExpectedEqual).asObject().as(builtins.Promise);
            try std.testing.expectEqual(.fulfilled, promise.fields.promise_state);
            if (!expected.fulfilled.toValue().isStrictlyEqual(promise.fields.promise_result)) return error.TestExpectedEqual;
        },
        .exception => return error.TestExpectedException,
        .ignore => {},
    } else |err| switch (expected_result) {
        .exception => try std.testing.expectEqual(error.ExceptionThrown, err),
        else => return err,
    }

    try std.testing.expectEqualStrings(expected_output, aw.written());
}

test {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var environ_map = try std.process.Environ.createMap(.empty, gpa);
    defer environ_map.deinit();
    inline for (test_cases) |test_case| {
        try testInterpreter(
            gpa,
            io,
            &environ_map,
            test_case.source,
            test_case.expected_result,
            test_case.expected_output,
        );
    }
}
