//! 9.6 Agents
//! https://tc39.es/ecma262/#sec-agents

const builtin = @import("builtin");
const std = @import("std");

const builtins = @import("../builtins.zig");
const environments = @import("environments.zig");
const interpreter = @import("../interpreter.zig");
const pretty_printing = @import("../pretty_printing.zig");
const types = @import("../types.zig");
const utils = @import("../utils.zig");

const Environment = environments.Environment;
const ExecutionContext = @import("ExecutionContext.zig");
const HostHooks = @import("HostHooks.zig");
const Job = @import("Job.zig");
const Object = types.Object;
const PropertyKey = types.PropertyKey;
const Realm = @import("Realm.zig");
const String = types.String;
const Symbol = types.Symbol;
const Value = types.Value;
const noexcept = utils.noexcept;

const Agent = @This();

gpa: std.mem.Allocator,
io: std.Io,
gc_allocator: std.mem.Allocator,
gc_allocator_atomic: std.mem.Allocator,
options: Options,
exception: ?Exception,
well_known_symbols: WellKnownSymbols,
global_symbol_registry: String.HashMap(*const Symbol),
host_hooks: HostHooks,
execution_context_stack: std.ArrayList(*ExecutionContext),
queued_jobs: std.ArrayList(QueuedJob),
empty_shape: *Object.Shape,
iterator_record_shape: ?*Object.Shape,
string_cache: String.Cache,
platform: *const Platform,
active_vm: ?*interpreter.Vm,

/// [[LittleEndian]]
little_endian: bool = builtin.target.cpu.arch.endian() == .little,

/// [[ModuleAsyncEvaluationCount]]
module_async_evaluation_count: u32 = 0,

pub const Exception = @import("Agent/Exception.zig");
pub const Platform = @import("Agent/Platform.zig");
pub const WellKnownSymbols = @import("Agent/WellKnownSymbols.zig");

pub const Options = struct {
    debug: struct {
        print_ast: bool = false,
        print_bytecode: bool = false,
        print_ir: bool = false,
    } = .{},
};

pub const Error = std.mem.Allocator.Error || error{ExceptionThrown};

pub const QueuedJob = struct {
    job: Job,
    realm: ?*Realm,
};

pub fn init(
    gpa: std.mem.Allocator,
    io: std.Io,
    platform: *const Agent.Platform,
    options: Options,
) std.mem.Allocator.Error!Agent {
    pretty_printing.state.platform = platform;
    return .{
        .gpa = gpa,
        .io = io,
        // TODO: Do we want to remove these aliases? In that case you'd have to type out
        //       `agent.platform.gc_allocator.alloc()` every time, or we remove both levels of
        //       indirection and make it `agent.alloc()`.
        .gc_allocator = platform.gc_allocator,
        .gc_allocator_atomic = platform.gc_allocator_atomic,
        .options = options,
        .exception = null,
        .well_known_symbols = .init,
        .global_symbol_registry = .empty,
        .host_hooks = .{},
        .execution_context_stack = .empty,
        .queued_jobs = .empty,
        .empty_shape = try .init(platform.gc_allocator),
        .iterator_record_shape = null,
        .string_cache = .empty,
        .platform = platform,
        .active_vm = null,
    };
}

pub fn deinit(self: *Agent) void {
    self.global_symbol_registry.deinit(self.gc_allocator);
    self.execution_context_stack.deinit(self.gc_allocator);
    self.queued_jobs.deinit(self.gc_allocator);
    self.empty_shape.deinit(self.gc_allocator);
    self.string_cache.entries.deinit(self.gc_allocator);
}

pub fn ensureIteratorRecordShape(self: *Agent) std.mem.Allocator.Error!*Object.Shape {
    if (self.iterator_record_shape) |shape| return shape;
    const shape = try Object.Shape.init(self.gc_allocator);
    try shape.setPropertyWithoutTransition(self.gc_allocator, PropertyKey.from("iterator"), .all, .value);
    try shape.setPropertyWithoutTransition(self.gc_allocator, PropertyKey.from("nextMethod"), .all, .value);
    try shape.setPropertyWithoutTransition(self.gc_allocator, PropertyKey.from("done"), .all, .value);
    self.iterator_record_shape = shape;
    return shape;
}

pub fn drainJobQueue(self: *Agent) void {
    while (self.queued_jobs.items.len != 0) {
        const queued_job = self.queued_jobs.orderedRemove(0);
        const current_realm = self.runningExecutionContext().realm;
        if (queued_job.realm) |new_realm| {
            self.runningExecutionContext().realm = new_realm;
        }
        _ = queued_job.job.func(queued_job.job.captures) catch {};
        self.runningExecutionContext().realm = current_realm;
    }
}

const ErrorType = enum {
    // NativeError types
    aggregate_error,
    eval_error,
    range_error,
    reference_error,
    syntax_error,
    type_error,
    uri_error,

    // Non-standard internal error
    internal_error,

    fn T(self: @This()) type {
        return switch (self) {
            .aggregate_error => builtins.AggregateError,
            .eval_error => builtins.EvalError,
            .range_error => builtins.RangeError,
            .reference_error => builtins.ReferenceError,
            .syntax_error => builtins.SyntaxError,
            .type_error => builtins.TypeError,
            .uri_error => builtins.URIError,
            .internal_error => builtins.Error,
        };
    }

    fn intrinsic(self: @This()) Realm.Intrinsic {
        return switch (self) {
            .aggregate_error => .aggregate_error,
            .eval_error => .eval_error,
            .range_error => .range_error,
            .reference_error => .reference_error,
            .syntax_error => .syntax_error,
            .type_error => .type_error,
            .uri_error => .uri_error,
            .internal_error => .@"error",
        };
    }
};

pub fn createErrorObject(
    self: *Agent,
    comptime error_type: ErrorType,
    comptime fmt: []const u8,
    args: anytype,
) std.mem.Allocator.Error!*error_type.T() {
    const realm = self.currentRealm();
    const constructor = try realm.intrinsic(error_type.intrinsic());
    const message = try self.gc_allocator.print(fmt, args);
    const error_object = constructor.construct(
        self,
        &.{Value.from(try String.fromUtf8(self, message))},
        null,
    ) catch |err| try noexcept(err);
    const @"error" = error_object.as(error_type.T());
    if (error_type == .internal_error) {
        // We don't have a dedicated type for this, but let's at least adjust the name
        @"error".fields.name = String.fromLiteral("InternalError");
    }
    return @"error";
}

pub fn clearException(self: *Agent) Exception {
    defer self.exception = null;
    return self.exception.?;
}

/// 5.2.4.2 Throw
/// https://tc39.es/ecma262/#sec-throw-an-exception
pub fn throwException(
    self: *Agent,
    comptime error_type: ErrorType,
    comptime fmt: []const u8,
    args: anytype,
) error{ExceptionThrown} {
    const value = if (self.createErrorObject(
        error_type,
        fmt,
        args,
    )) |error_object|
        Value.from(&error_object.object)
    else |_|
        Value.from("Out of memory");
    self.exception = .{
        .value = value,
        .stack_trace = self.captureStackTrace(.{}) catch &.{},
    };
    return error.ExceptionThrown;
}

pub const CaptureStackTraceOptions = struct {
    limit: ?*Object = null,
};

/// Capture stack frames for an exception, skipping the Realm's root execution context and the
/// script or module execution context if present.
pub fn captureStackTrace(self: *const Agent, options: CaptureStackTraceOptions) std.mem.Allocator.Error!Exception.StackTrace {
    var stack_trace: std.ArrayList(Exception.StackFrame) = .empty;
    errdefer stack_trace.deinit(self.gc_allocator);
    for (self.execution_context_stack.items) |execution_context| {
        switch (execution_context.origin) {
            .function => |function| if (options.limit) |limit| {
                if (function == limit) break;
            },
            .eval => {},
            .script, .module, .realm => continue,
        }
        try stack_trace.append(self.gc_allocator, .{
            .origin = execution_context.origin,
        });
    }
    return stack_trace.toOwnedSlice(self.gc_allocator);
}

/// https://tc39.es/ecma262/#running-execution-context
pub fn runningExecutionContext(self: *const Agent) *ExecutionContext {
    // At any point in time, there is at most one execution context per agent that is actually
    // executing code. This is known as the agent's running execution context.
    // The running execution context is always the top element of this stack.
    std.debug.assert(self.execution_context_stack.items.len > 0);
    return self.execution_context_stack.last().?;
}

/// https://tc39.es/ecma262/#current-realm
pub fn currentRealm(self: *const Agent) *Realm {
    // The value of the Realm component of the running execution context is also called the current
    // Realm Record.
    return self.runningExecutionContext().realm;
}

/// https://tc39.es/ecma262/#active-function-object
pub fn activeFunctionObject(self: *const Agent) *Object {
    // The value of the Function component of the running execution context is also called the
    // active function object.
    return self.runningExecutionContext().origin.function;
}

/// 9.4.1 GetActiveScriptOrModule ( )
/// https://tc39.es/ecma262/#sec-getactivescriptormodule
pub fn getActiveScriptOrModule(self: *const Agent) ?ExecutionContext.ScriptOrModule {
    // 1. If the execution context stack is empty, return null.
    if (self.execution_context_stack.items.len == 0) return null;

    // 2. Let executionContext be the topmost execution context on the execution context stack whose
    //    ScriptOrModule component is not null.
    // 3. If no such execution context exists, return null.
    // 4. Return executionContext's ScriptOrModule.
    var it = std.mem.reverseIterator(self.execution_context_stack.items);
    while (it.next()) |execution_context| {
        if (execution_context.script_or_module) |script_or_module|
            return script_or_module;
    }
    return null;
}

/// 9.4.3 GetThisEnvironment ( )
/// https://tc39.es/ecma262/#sec-getthisenvironment
pub fn getThisEnvironment(self: *const Agent) Environment {
    // 1. Let envRecord be the running execution context's LexicalEnvironment.
    var env = self.runningExecutionContext().ecmascript_code.lexical_environment;

    // 2. Repeat,
    while (true) {
        // a. Let exists be envRecord.HasThisBinding().
        const exists = env.hasThisBinding();

        // b. If exists is true, return envRecord.
        if (exists) return env;

        // c. Let outer be envRecord.[[OuterEnv]].
        const outer = env.outerEnv();

        // d. Assert: outer is not null.
        std.debug.assert(outer != null);

        // e. Set envRecord to outer.
        env = outer.?;
    }

    // NOTE: The loop in step 2 will always terminate because the list of environments always ends
    //       with the global environment which has a this binding.
    unreachable;
}

/// 9.4.4 ResolveThisBinding ( )
/// https://tc39.es/ecma262/#sec-resolvethisbinding
pub fn resolveThisBinding(self: *Agent) Error!Value {
    // 1. Let envRecord be GetThisEnvironment().
    const env = self.getThisEnvironment();

    // 2. Return ? envRecord.GetThisBinding().
    return env.getThisBinding(self);
}

/// 9.4.5 GetNewTarget ( )
/// https://tc39.es/ecma262/#sec-getnewtarget
pub fn getNewTarget(self: *const Agent) ?*Object {
    // 1. Let envRecord be GetThisEnvironment().
    const env = self.getThisEnvironment();

    // 2. Assert: envRecord has a [[NewTarget]] field.
    std.debug.assert(env == .function_environment);

    // 3. Return envRecord.[[NewTarget]].
    return env.function_environment.new_target;
}

/// 9.4.6 GetGlobalObject ( )
/// https://tc39.es/ecma262/#sec-getglobalobject
pub fn getGlobalObject(self: *const Agent) *Object {
    // 1. Let currentRealm be the current Realm Record.
    const current_realm = self.currentRealm();

    // 2. Return currentRealm.[[GlobalObject]].
    return current_realm.global_object;
}

/// 9.6.3 IncrementModuleAsyncEvaluationCount ( )
/// https://tc39.es/ecma262/#sec-IncrementModuleAsyncEvaluationCount
pub fn incrementModuleAsyncEvaluationCount(self: *Agent) u32 {
    // 1. Let agentRecord be the Agent Record of the surrounding agent.
    // 2. Let count be agentRecord.[[ModuleAsyncEvaluationCount]].
    // 3. Set agentRecord.[[ModuleAsyncEvaluationCount]] to count + 1.
    defer self.module_async_evaluation_count += 1;

    // 4. Return count.
    return self.module_async_evaluation_count;
}

test init {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var environ_map = try std.process.Environ.createMap(.empty, gpa);
    defer environ_map.deinit();
    var platform: Platform = .default(io, &environ_map);
    defer platform.deinit();
    // Ensure Agent teardown is leak-free
    platform.gc_allocator = std.testing.allocator;
    platform.gc_allocator_atomic = std.testing.allocator;
    var agent = try init(gpa, io, &platform, .{});
    defer agent.deinit();
}

test "well_known_symbols" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var environ_map = try std.process.Environ.createMap(.empty, gpa);
    defer environ_map.deinit();
    const platform: Platform = .default(io, &environ_map);
    defer platform.deinit();
    var agent = try init(gpa, io, &platform, .{});
    defer agent.deinit();
    const unscopables = agent.well_known_symbols.unscopables;
    try std.testing.expectEqualStrings(unscopables.description.?.asAscii(), "Symbol.unscopables");
}
