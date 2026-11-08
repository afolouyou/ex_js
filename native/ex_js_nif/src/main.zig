const std = @import("std");
const kiesel = @import("kiesel");
const c = @import("erl_nif");

// BDWGC's thread-registration API is hidden from the translated `gc.h`
// bindings (guarded by GC_THREADS), but the symbols are exported by libgc.
const GC_SUCCESS = 0;

const GC_stack_base = extern struct {
    mem_base: ?*anyopaque,
};

extern fn GC_thread_is_registered() c_int;
extern fn GC_get_stack_base(stack_base: *GC_stack_base) c_int;
extern fn GC_register_my_thread(stack_base: *const GC_stack_base) c_int;
extern fn GC_allow_register_threads() void;
extern fn GC_malloc_uncollectable(size: usize) ?*anyopaque;
extern fn GC_free(ptr: ?*anyopaque) void;

const Agent = kiesel.execution.Agent;
const Platform = Agent.Platform;
const Realm = kiesel.execution.Realm;
const Script = kiesel.language.Script;
const Diagnostics = kiesel.language.Diagnostics;
const Object = kiesel.types.Object;
const PropertyKey = kiesel.types.PropertyKey;
const String = kiesel.types.String;
const Value = kiesel.types.Value;

const Limits = struct {
    max_depth: u32 = 64,
    max_collection_size: u32 = 10_000,
    max_string_bytes: u32 = 1_048_576,
    max_source_bytes: u32 = 1_048_576,
};

const Context = struct {
    mutex: *c.ErlNifMutex,
    owner: c.ErlNifPid,
    limits: Limits,
    evaluations: u64,

    // Per-context writers so independent contexts never share mutable state.
    stdout_buffer: [4096]u8,
    stderr_buffer: [4096]u8,
    stdout_writer: std.Io.Writer,
    stderr_writer: std.Io.Writer,

    platform: Platform,
    agent: Agent,
    closed: bool,
};

var resource_type: ?*c.ErlNifResourceType = null;

/// Kiesel has process-global state (e.g. pretty-printing platform), so all
/// engine operations are serialized across contexts. Per-context mutexes still
/// protect each context's own state.
var engine_mutex: ?*c.ErlNifMutex = null;

fn lockEngine() void {
    if (engine_mutex) |mutex| c.enif_mutex_lock(mutex);
}

fn unlockEngine() void {
    if (engine_mutex) |mutex| c.enif_mutex_unlock(mutex);
}

/// The NIF resource only stores a pointer. The Context itself lives in GC
/// memory (as an uncollectable block) so BDWGC scans Agent/Realm references;
/// BEAM-allocated memory is invisible to it.
const ContextSlot = *Context;

var gc_lock: std.atomic.Mutex = .unlocked;
var gc_threads_allowed: bool = false;

threadlocal var gc_thread_registered: bool = false;

/// BDWGC needs to know every thread whose stack may reference GC-managed
/// objects. BEAM scheduler threads are not registered automatically, so each
/// thread entering the NIF registers itself once.
fn ensureGcThread() void {
    if (gc_thread_registered) return;

    if (GC_thread_is_registered() != 0) {
        gc_thread_registered = true;
        return;
    }

    var stack_base: GC_stack_base = undefined;
    if (GC_get_stack_base(&stack_base) == GC_SUCCESS) {
        if (GC_register_my_thread(&stack_base) == GC_SUCCESS) {
            gc_thread_registered = true;
        }
    }
}

fn ensureGc() void {
    while (!gc_lock.tryLock()) std.atomic.spinLoopHint();
    defer gc_lock.unlock();
    kiesel.gc.init();
    kiesel.gc.disableWarnings();
    if (!gc_threads_allowed) {
        GC_allow_register_threads();
        gc_threads_allowed = true;
    }
}

fn checkStackOverflow() bool {
    return false;
}

fn contextDestructor(env: ?*c.ErlNifEnv, obj: ?*anyopaque) callconv(.c) void {
    _ = env;
    const slot: *ContextSlot = @ptrCast(@alignCast(obj.?));
    const ctx = slot.*;

    lockEngine();
    defer unlockEngine();

    if (!ctx.closed) {
        ctx.agent.deinit();
        ctx.platform.deinit();
        ctx.closed = true;
    }
    c.enif_mutex_destroy(ctx.mutex);
    GC_free(ctx);
}

fn nifLoad(env: ?*c.ErlNifEnv, priv_data: ?*?*anyopaque, load_info: c.ERL_NIF_TERM) callconv(.c) c_int {
    _ = priv_data;
    _ = load_info;

    var tried: c.ErlNifResourceFlags = undefined;
    resource_type = c.enif_open_resource_type(
        env,
        null,
        "ex_js_context",
        contextDestructor,
        @as(c.ErlNifResourceFlags, @intCast(c.ERL_NIF_RT_CREATE | c.ERL_NIF_RT_TAKEOVER)),
        &tried,
    );

    engine_mutex = c.enif_mutex_create(@constCast("ex_js_engine"));

    return if (resource_type != null and engine_mutex != null) 0 else 1;
}

pub export fn nif_init() ?*c.ErlNifEntry {
    return &nif_entry;
}

fn makeBinary(env: ?*c.ErlNifEnv, bytes: []const u8) !c.ERL_NIF_TERM {
    var bin: c.ErlNifBinary = undefined;
    if (c.enif_alloc_binary(bytes.len, &bin) == 0) return error.OutOfMemory;
    @memcpy(bin.data[0..bytes.len], bytes);
    return c.enif_make_binary(env, &bin);
}

fn makeOkTuple(env: ?*c.ErlNifEnv, value: c.ERL_NIF_TERM) c.ERL_NIF_TERM {
    return c.enif_make_tuple2(env, c.enif_make_atom(env, "ok"), value);
}

fn makeError(env: ?*c.ErlNifEnv, reason: [*:0]const u8) c.ERL_NIF_TERM {
    return c.enif_make_tuple2(
        env,
        c.enif_make_atom(env, "error"),
        c.enif_make_atom(env, reason),
    );
}

fn isOwner(env: ?*c.ErlNifEnv, ctx: *const Context) bool {
    var self_pid: c.ErlNifPid = undefined;
    _ = c.enif_self(env, &self_pid);
    return c.enif_is_identical(self_pid.pid, ctx.owner.pid) != 0;
}

fn makeErrorMap(
    env: ?*c.ErlNifEnv,
    name: []const u8,
    message: []const u8,
) c.ERL_NIF_TERM {
    const name_bin = makeBinary(env, name) catch return makeError(env, "out_of_memory");
    const message_bin = makeBinary(env, message) catch return makeError(env, "out_of_memory");

    var map = c.enif_make_new_map(env);
    var out: c.ERL_NIF_TERM = undefined;
    _ = c.enif_make_map_put(env, map, c.enif_make_atom(env, "name"), name_bin, &out);
    map = out;
    _ = c.enif_make_map_put(env, map, c.enif_make_atom(env, "message"), message_bin, &out);
    map = out;

    return c.enif_make_tuple2(env, c.enif_make_atom(env, "error"), map);
}

fn exceptionToErrorTerm(env: ?*c.ErlNifEnv, agent: *Agent) c.ERL_NIF_TERM {
    const exception = agent.exception orelse {
        return makeErrorMap(env, "Error", "unknown JavaScript exception");
    };

    var name_buf: ?[]u8 = null;
    var message_buf: ?[]u8 = null;
    defer if (name_buf) |b| agent.gpa.free(b);
    defer if (message_buf) |b| agent.gpa.free(b);

    if (exception.value.get(agent, PropertyKey.from("name"))) |name_value| {
        if (name_value.toString(agent)) |name_string| {
            name_buf = name_string.toUtf8(agent.gpa) catch null;
        } else |_| {}
    } else |_| {}

    if (exception.value.get(agent, PropertyKey.from("message"))) |message_value| {
        if (message_value.toString(agent)) |message_string| {
            message_buf = message_string.toUtf8(agent.gpa) catch null;
        } else |_| {}
    } else |_| {}

    const name: []const u8 = name_buf orelse "Error";
    const message: []const u8 = message_buf orelse "";

    return makeErrorMap(env, name, message);
}

fn convErrorToTerm(env: ?*c.ErlNifEnv, err: anyerror) c.ERL_NIF_TERM {
    return switch (err) {
        error.OutOfMemory => makeError(env, "out_of_memory"),
        error.UnsupportedValue => makeError(env, "unsupported_value"),
        error.MaxDepthExceeded => makeError(env, "max_depth_exceeded"),
        error.CollectionTooLarge => makeError(env, "collection_too_large"),
        error.StringTooLarge => makeError(env, "string_too_large"),
        else => makeError(env, "conversion_failed"),
    };
}

fn valueToTerm(
    env: ?*c.ErlNifEnv,
    agent: *Agent,
    value: Value,
    limits: Limits,
    depth: u32,
) anyerror!c.ERL_NIF_TERM {
    if (value.isUndefined() or value.isNull()) {
        return c.enif_make_atom(env, "nil");
    }
    if (value.isBoolean()) {
        return if (value.asBoolean())
            c.enif_make_atom(env, "true")
        else
            c.enif_make_atom(env, "false");
    }
    if (value.isNumber()) {
        const number = value.asNumber().asFloat();
        if (std.math.isNan(number)) return c.enif_make_atom(env, "nan");
        if (std.math.isPositiveInf(number)) return c.enif_make_atom(env, "infinity");
        if (std.math.isNegativeInf(number)) return c.enif_make_atom(env, "negative_infinity");

        const max_safe: f64 = 9007199254740991.0;
        if (number >= -max_safe and number <= max_safe and @floor(number) == number) {
            return c.enif_make_int64(env, @intFromFloat(number));
        }
        return c.enif_make_double(env, number);
    }
    if (value.isString()) {
        const utf8 = try value.asString().toUtf8(agent.gc_allocator);
        defer agent.gc_allocator.free(utf8);
        if (utf8.len > limits.max_string_bytes) return error.StringTooLarge;
        return makeBinary(env, utf8);
    }
    if (value.isBigInt()) {
        return error.UnsupportedValue;
    }
    if (value.isCallable()) {
        return error.UnsupportedValue;
    }
    if (value.isObject()) {
        if (depth == 0) return error.MaxDepthExceeded;

        const obj = value.asObject();
        const is_array = value.isArray(agent) catch false;

        if (is_array) {
            const length_value = try obj.get(agent, PropertyKey.from("length"));
            const length_float = if (length_value.isNumber())
                length_value.asNumber().asFloat()
            else
                0.0;
            const length: u32 = if (length_float > 0 and length_float < 4294967295.0)
                @intFromFloat(length_float)
            else
                0;
            if (length > limits.max_collection_size) return error.CollectionTooLarge;

            var list_term = c.enif_make_list(env, 0);
            var i: u32 = length;
            while (i > 0) {
                i -= 1;
                const element = try obj.get(agent, PropertyKey.from(@as(PropertyKey.IntegerIndex, i)));
                const element_term = try valueToTerm(env, agent, element, limits, depth - 1);
                list_term = c.enif_make_list_cell(env, element_term, list_term);
            }
            return list_term;
        }

        var properties = try Object.enumerableOwnProperties(obj, agent, .key_value);
        defer properties.deinit(agent.gc_allocator);
        if (properties.items.len > limits.max_collection_size) return error.CollectionTooLarge;

        var map_term = c.enif_make_new_map(env);
        for (properties.items) |entry| {
            const key_value = try entry.get(agent, PropertyKey.from(0));
            const entry_value = try entry.get(agent, PropertyKey.from(1));

            const key_string = try key_value.toString(agent);
            const key_utf8 = try key_string.toUtf8(agent.gc_allocator);
            if (key_utf8.len > limits.max_string_bytes) return error.StringTooLarge;

            const key_term = try makeBinary(env, key_utf8);
            const entry_term = try valueToTerm(env, agent, entry_value, limits, depth - 1);

            var out: c.ERL_NIF_TERM = undefined;
            _ = c.enif_make_map_put(env, map_term, key_term, entry_term, &out);
            map_term = out;
        }
        return map_term;
    }

    return error.UnsupportedValue;
}

fn termToValue(
    env: ?*c.ErlNifEnv,
    agent: *Agent,
    term: c.ERL_NIF_TERM,
    limits: Limits,
    depth: u32,
) anyerror!Value {
    if (depth == 0) return error.MaxDepthExceeded;

    if (c.enif_is_atom(env, term) != 0) {
        if (c.enif_is_identical(term, c.enif_make_atom(env, "nil")) != 0) {
            return Value.null;
        }
        if (c.enif_is_identical(term, c.enif_make_atom(env, "true")) != 0) {
            return Value.true;
        }
        if (c.enif_is_identical(term, c.enif_make_atom(env, "false")) != 0) {
            return Value.false;
        }
        return error.UnsupportedValue;
    }

    var int_value: c.ErlNifSInt64 = undefined;
    if (c.enif_get_int64(env, term, &int_value) != 0) {
        return Value.from(@as(f64, @floatFromInt(int_value)));
    }

    var double_value: f64 = undefined;
    if (c.enif_get_double(env, term, &double_value) != 0) {
        return Value.from(double_value);
    }

    var bin: c.ErlNifBinary = undefined;
    if (c.enif_inspect_binary(env, term, &bin) != 0) {
        if (bin.size > limits.max_string_bytes) return error.StringTooLarge;
        // String.fromUtf8 takes ownership of ASCII buffers, and the JS value
        // outlives this NIF call, so the bytes must live in GC memory.
        const bytes = try agent.gc_allocator.dupe(u8, bin.data[0..bin.size]);
        const string = try String.fromUtf8(agent, bytes);
        return Value.from(string);
    }

    if (c.enif_is_list(env, term) != 0) {
        var values: std.ArrayList(Value) = .empty;
        defer values.deinit(agent.gpa);

        var tail = term;
        while (true) {
            var head: c.ERL_NIF_TERM = undefined;
            var next: c.ERL_NIF_TERM = undefined;
            if (c.enif_get_list_cell(env, tail, &head, &next) == 0) break;
            try values.append(agent.gpa, try termToValue(env, agent, head, limits, depth - 1));
            if (values.items.len > limits.max_collection_size) return error.CollectionTooLarge;
            tail = next;
        }
        if (c.enif_is_empty_list(env, tail) == 0) return error.UnsupportedValue;

        const array = try kiesel.builtins.arrayCreateFast(agent, @intCast(values.items.len));
        for (values.items, 0..) |element, index| {
            try array.object.createDataPropertyDirect(
                agent,
                PropertyKey.from(@as(PropertyKey.IntegerIndex, @intCast(index))),
                element,
            );
        }
        return Value.from(&array.object);
    }

    if (c.enif_is_map(env, term) != 0) {
        var map_size: usize = 0;
        if (c.enif_get_map_size(env, term, &map_size) != 0 and
            map_size > limits.max_collection_size)
        {
            return error.CollectionTooLarge;
        }

        const obj = try kiesel.builtins.ordinaryObjectCreate(agent, null);

        var iterator: c.ErlNifMapIterator = undefined;
        if (c.enif_map_iterator_create(env, term, &iterator, c.ERL_NIF_MAP_ITERATOR_FIRST) == 0) {
            return error.UnsupportedValue;
        }
        defer c.enif_map_iterator_destroy(env, &iterator);

        var key_term: c.ERL_NIF_TERM = undefined;
        var value_term: c.ERL_NIF_TERM = undefined;

        while (c.enif_map_iterator_get_pair(env, &iterator, &key_term, &value_term) != 0) {
            const key_utf8 = try termToUtf8(agent, env, key_term, limits);

            const key_string = try String.fromUtf8(agent, key_utf8);
            const obj_value = try termToValue(env, agent, value_term, limits, depth - 1);

            try obj.createDataPropertyDirect(agent, PropertyKey.from(key_string), obj_value);

            if (c.enif_map_iterator_next(env, &iterator) == 0) break;
        }

        return Value.from(obj);
    }

    return error.UnsupportedValue;
}

fn termToUtf8(
    agent: *Agent,
    env: ?*c.ErlNifEnv,
    term: c.ERL_NIF_TERM,
    limits: Limits,
) anyerror![]u8 {
    var bin: c.ErlNifBinary = undefined;
    if (c.enif_inspect_binary(env, term, &bin) != 0) {
        if (bin.size > limits.max_string_bytes) return error.StringTooLarge;
        return agent.gc_allocator.dupe(u8, bin.data[0..bin.size]);
    }

    if (c.enif_is_atom(env, term) != 0) {
        var length: c_uint = 0;
        if (c.enif_get_atom_length(env, term, &length, c.ERL_NIF_UTF8) == 0) {
            return error.UnsupportedValue;
        }
        if (length > limits.max_string_bytes) return error.StringTooLarge;
        const buffer = try agent.gc_allocator.alloc(u8, @as(usize, length) + 1);
        errdefer agent.gc_allocator.free(buffer);
        if (c.enif_get_atom(env, term, buffer.ptr, length + 1, c.ERL_NIF_UTF8) == 0) {
            return error.UnsupportedValue;
        }
        return buffer[0..length];
    }

    return error.UnsupportedValue;
}

fn injectBindings(
    env: ?*c.ErlNifEnv,
    agent: *Agent,
    realm: *Realm,
    bindings: c.ERL_NIF_TERM,
    limits: Limits,
) anyerror!void {
    var iterator: c.ErlNifMapIterator = undefined;
    if (c.enif_map_iterator_create(env, bindings, &iterator, c.ERL_NIF_MAP_ITERATOR_FIRST) == 0) {
        return error.InvalidBinding;
    }
    defer c.enif_map_iterator_destroy(env, &iterator);

    var key_term: c.ERL_NIF_TERM = undefined;
    var value_term: c.ERL_NIF_TERM = undefined;

    while (c.enif_map_iterator_get_pair(env, &iterator, &key_term, &value_term) != 0) {
        const key_utf8 = try termToUtf8(agent, env, key_term, limits);

        const key_string = try String.fromUtf8(agent, key_utf8);
        const js_value = try termToValue(env, agent, value_term, limits, limits.max_depth);

        try realm.global_object.createDataPropertyDirect(
            agent,
            PropertyKey.from(key_string),
            js_value,
        );

        if (c.enif_map_iterator_next(env, &iterator) == 0) break;
    }
}

fn readLimit(
    env: ?*c.ErlNifEnv,
    opts: c.ERL_NIF_TERM,
    key: [*:0]const u8,
    default: u32,
) u32 {
    const key_term = c.enif_make_atom(env, key);
    var value: c.ERL_NIF_TERM = undefined;
    if (c.enif_get_map_value(env, opts, key_term, &value) != 0) {
        var int_value: c.ErlNifSInt64 = undefined;
        if (c.enif_get_int64(env, value, &int_value) != 0 and
            int_value > 0 and int_value <= std.math.maxInt(u32))
        {
            return @intCast(int_value);
        }
    }
    return default;
}

fn getContext(
    env: ?*c.ErlNifEnv,
    term: c.ERL_NIF_TERM,
) ?*Context {
    const rt = resource_type orelse return null;
    var obj: ?*anyopaque = null;
    if (c.enif_get_resource(env, term, rt, &obj) == 0 or obj == null) {
        return null;
    }
    const slot: *ContextSlot = @ptrCast(@alignCast(obj.?));
    return slot.*;
}

pub export fn exjsNew(env: ?*c.ErlNifEnv, argc: c_int, argv: [*c]const c.ERL_NIF_TERM) c.ERL_NIF_TERM {
    if (argc != 1) return c.enif_make_badarg(env);
    if (c.enif_is_map(env, argv[0]) == 0) return c.enif_make_badarg(env);

    lockEngine();
    defer unlockEngine();

    ensureGc();
    ensureGcThread();

    const opts = argv[0];
    const limits: Limits = .{
        .max_depth = readLimit(env, opts, "max_depth", 64),
        .max_collection_size = readLimit(env, opts, "max_collection_size", 10_000),
        .max_string_bytes = readLimit(env, opts, "max_string_bytes", 1_048_576),
        .max_source_bytes = readLimit(env, opts, "max_source_bytes", 1_048_576),
    };

    const rt = resource_type orelse return c.enif_make_badarg(env);

    const mutex = c.enif_mutex_create(@constCast("ex_js_ctx")) orelse
        return makeError(env, "mutex_create_failed");

    const ctx_mem = GC_malloc_uncollectable(@sizeOf(Context)) orelse {
        c.enif_mutex_destroy(mutex);
        return makeError(env, "alloc_failed");
    };
    const ctx: *Context = @ptrCast(@alignCast(ctx_mem));

    ctx.* = .{
        .mutex = mutex,
        .owner = undefined,
        .limits = limits,
        .evaluations = 0,
        .stdout_buffer = undefined,
        .stderr_buffer = undefined,
        .stdout_writer = undefined,
        .stderr_writer = undefined,
        .platform = undefined,
        .agent = undefined,
        .closed = false,
    };

    _ = c.enif_self(env, &ctx.owner);

    ctx.stdout_writer = std.Io.Writer.fixed(&ctx.stdout_buffer);
    ctx.stderr_writer = std.Io.Writer.fixed(&ctx.stderr_buffer);

    ctx.platform = .{
        .gc_allocator = kiesel.gc.allocator,
        .gc_allocator_atomic = kiesel.gc.allocator_atomic,
        .stdout = &ctx.stdout_writer,
        .stderr = &ctx.stderr_writer,
        .terminal_mode = .no_color,
        .default_locale = {},
        .default_time_zone = {},
        .checkStackOverflow = &checkStackOverflow,
    };

    const io = std.Io.Threaded.global_single_threaded.io();

    ctx.agent = Agent.init(std.heap.page_allocator, io, &ctx.platform, .{}) catch {
        ctx.closed = true;
        c.enif_mutex_destroy(mutex);
        GC_free(ctx);
        return makeError(env, "agent_init_failed");
    };

    Realm.initializeHostDefinedRealm(&ctx.agent, .{}) catch {
        ctx.agent.deinit();
        ctx.closed = true;
        c.enif_mutex_destroy(mutex);
        GC_free(ctx);
        return makeError(env, "realm_init_failed");
    };

    const slot_ptr = c.enif_alloc_resource(rt, @sizeOf(ContextSlot)) orelse {
        ctx.agent.deinit();
        ctx.closed = true;
        c.enif_mutex_destroy(mutex);
        GC_free(ctx);
        return makeError(env, "alloc_failed");
    };
    const slot: *ContextSlot = @ptrCast(@alignCast(slot_ptr));
    slot.* = ctx;

    const term = c.enif_make_resource(env, slot_ptr);
    c.enif_release_resource(slot_ptr);

    return makeOkTuple(env, term);
}

pub export fn exjsEval(env: ?*c.ErlNifEnv, argc: c_int, argv: [*c]const c.ERL_NIF_TERM) c.ERL_NIF_TERM {
    if (argc < 2 or argc > 3) return c.enif_make_badarg(env);

    lockEngine();
    defer unlockEngine();

    ensureGc();
    ensureGcThread();

    const ctx = getContext(env, argv[0]) orelse return makeError(env, "invalid_context");

    if (!isOwner(env, ctx)) return makeError(env, "not_owner");

    c.enif_mutex_lock(ctx.mutex);
    defer c.enif_mutex_unlock(ctx.mutex);

    if (ctx.closed) return makeError(env, "context_closed");

    var bin: c.ErlNifBinary = undefined;
    if (c.enif_inspect_binary(env, argv[1], &bin) == 0) {
        return makeError(env, "invalid_source");
    }
    const source = bin.data[0..bin.size];
    if (source.len > ctx.limits.max_source_bytes) {
        return makeError(env, "source_too_large");
    }

    ctx.evaluations += 1;

    const realm = ctx.agent.currentRealm();

    if (argc == 3) {
        injectBindings(env, &ctx.agent, realm, argv[2], ctx.limits) catch |err| {
            return switch (err) {
                error.InvalidBinding => makeError(env, "invalid_bindings"),
                error.UnsupportedValue => makeError(env, "unsupported_binding_value"),
                error.MaxDepthExceeded => makeError(env, "max_depth_exceeded"),
                error.CollectionTooLarge => makeError(env, "collection_too_large"),
                error.StringTooLarge => makeError(env, "string_too_large"),
                error.ExceptionThrown => exceptionToErrorTerm(env, &ctx.agent),
                error.OutOfMemory => makeError(env, "out_of_memory"),
                else => makeError(env, "bindings_failed"),
            };
        };
    }

    var diagnostics = Diagnostics.init(ctx.agent.gpa, .{
        .source = source,
        .file_name = "eval",
    });
    defer diagnostics.deinit();

    const script = Script.parse(source, realm, null, .{
        .diagnostics = &diagnostics,
    }) catch |err| switch (err) {
        error.OutOfMemory => return makeError(env, "out_of_memory"),
        error.ParseError => {
            const parse_error = diagnostics.first() orelse {
                return makeErrorMap(env, "SyntaxError", "failed to parse script");
            };
            const message = ctx.agent.gpa.print("{f}", .{parse_error.fmt(&diagnostics)}) catch {
                return makeErrorMap(env, "SyntaxError", "failed to parse script");
            };
            defer ctx.agent.gpa.free(message);
            return makeErrorMap(env, "SyntaxError", message);
        },
    };

    const result = script.evaluate("eval") catch |err| switch (err) {
        error.OutOfMemory => return makeError(env, "out_of_memory"),
        error.ExceptionThrown => return exceptionToErrorTerm(env, &ctx.agent),
    };

    const term = valueToTerm(env, &ctx.agent, result, ctx.limits, ctx.limits.max_depth) catch |err| {
        return switch (err) {
            error.ExceptionThrown => exceptionToErrorTerm(env, &ctx.agent),
            else => convErrorToTerm(env, err),
        };
    };

    return makeOkTuple(env, term);
}

fn termListToValues(
    env: ?*c.ErlNifEnv,
    agent: *Agent,
    term: c.ERL_NIF_TERM,
    limits: Limits,
) anyerror![]Value {
    var values: std.ArrayList(Value) = .empty;
    errdefer values.deinit(agent.gpa);

    var tail = term;
    while (true) {
        var head: c.ERL_NIF_TERM = undefined;
        var next: c.ERL_NIF_TERM = undefined;
        if (c.enif_get_list_cell(env, tail, &head, &next) == 0) break;
        try values.append(agent.gpa, try termToValue(env, agent, head, limits, limits.max_depth));
        if (values.items.len > limits.max_collection_size) return error.CollectionTooLarge;
        tail = next;
    }
    if (c.enif_is_empty_list(env, tail) == 0) return error.UnsupportedValue;

    return values.toOwnedSlice(agent.gpa);
}

pub export fn exjsSet(env: ?*c.ErlNifEnv, argc: c_int, argv: [*c]const c.ERL_NIF_TERM) c.ERL_NIF_TERM {
    if (argc != 3) return c.enif_make_badarg(env);

    lockEngine();
    defer unlockEngine();

    ensureGc();
    ensureGcThread();

    const ctx = getContext(env, argv[0]) orelse return makeError(env, "invalid_context");
    if (!isOwner(env, ctx)) return makeError(env, "not_owner");

    c.enif_mutex_lock(ctx.mutex);
    defer c.enif_mutex_unlock(ctx.mutex);

    if (ctx.closed) return makeError(env, "context_closed");

    const name = termToUtf8(&ctx.agent, env, argv[1], ctx.limits) catch |err| {
        return convErrorToTerm(env, err);
    };

    const js_value = termToValue(env, &ctx.agent, argv[2], ctx.limits, ctx.limits.max_depth) catch |err| {
        return switch (err) {
            error.ExceptionThrown => exceptionToErrorTerm(env, &ctx.agent),
            else => convErrorToTerm(env, err),
        };
    };

    const key_string = String.fromUtf8(&ctx.agent, name) catch {
        return makeError(env, "out_of_memory");
    };

    const realm = ctx.agent.currentRealm();
    realm.global_object.createDataPropertyDirect(
        &ctx.agent,
        PropertyKey.from(key_string),
        js_value,
    ) catch |err| switch (err) {
        error.OutOfMemory => return makeError(env, "out_of_memory"),
    };

    return c.enif_make_atom(env, "ok");
}

pub export fn exjsGet(env: ?*c.ErlNifEnv, argc: c_int, argv: [*c]const c.ERL_NIF_TERM) c.ERL_NIF_TERM {
    if (argc != 2) return c.enif_make_badarg(env);

    lockEngine();
    defer unlockEngine();

    ensureGc();
    ensureGcThread();

    const ctx = getContext(env, argv[0]) orelse return makeError(env, "invalid_context");
    if (!isOwner(env, ctx)) return makeError(env, "not_owner");

    c.enif_mutex_lock(ctx.mutex);
    defer c.enif_mutex_unlock(ctx.mutex);

    if (ctx.closed) return makeError(env, "context_closed");

    const name = termToUtf8(&ctx.agent, env, argv[1], ctx.limits) catch |err| {
        return convErrorToTerm(env, err);
    };

    const key_string = String.fromUtf8(&ctx.agent, name) catch {
        return makeError(env, "out_of_memory");
    };
    const key = PropertyKey.from(key_string);

    const realm = ctx.agent.currentRealm();
    const global = realm.global_object;

    const exists = global.hasProperty(&ctx.agent, key) catch |err| switch (err) {
        error.ExceptionThrown => return exceptionToErrorTerm(env, &ctx.agent),
        error.OutOfMemory => return makeError(env, "out_of_memory"),
    };
    if (!exists) return makeError(env, "not_found");

    const result = global.get(&ctx.agent, key) catch |err| switch (err) {
        error.ExceptionThrown => return exceptionToErrorTerm(env, &ctx.agent),
        error.OutOfMemory => return makeError(env, "out_of_memory"),
    };

    const term = valueToTerm(env, &ctx.agent, result, ctx.limits, ctx.limits.max_depth) catch |err| {
        return switch (err) {
            error.ExceptionThrown => exceptionToErrorTerm(env, &ctx.agent),
            else => convErrorToTerm(env, err),
        };
    };

    return makeOkTuple(env, term);
}

pub export fn exjsCall(env: ?*c.ErlNifEnv, argc: c_int, argv: [*c]const c.ERL_NIF_TERM) c.ERL_NIF_TERM {
    if (argc != 3) return c.enif_make_badarg(env);

    lockEngine();
    defer unlockEngine();

    ensureGc();
    ensureGcThread();

    const ctx = getContext(env, argv[0]) orelse return makeError(env, "invalid_context");
    if (!isOwner(env, ctx)) return makeError(env, "not_owner");

    c.enif_mutex_lock(ctx.mutex);
    defer c.enif_mutex_unlock(ctx.mutex);

    if (ctx.closed) return makeError(env, "context_closed");

    const name = termToUtf8(&ctx.agent, env, argv[1], ctx.limits) catch |err| {
        return convErrorToTerm(env, err);
    };

    const key_string = String.fromUtf8(&ctx.agent, name) catch {
        return makeError(env, "out_of_memory");
    };
    const key = PropertyKey.from(key_string);

    const realm = ctx.agent.currentRealm();
    const global = realm.global_object;

    const exists = global.hasProperty(&ctx.agent, key) catch |err| switch (err) {
        error.ExceptionThrown => return exceptionToErrorTerm(env, &ctx.agent),
        error.OutOfMemory => return makeError(env, "out_of_memory"),
    };
    if (!exists) return makeError(env, "not_found");

    const function = global.get(&ctx.agent, key) catch |err| switch (err) {
        error.ExceptionThrown => return exceptionToErrorTerm(env, &ctx.agent),
        error.OutOfMemory => return makeError(env, "out_of_memory"),
    };

    if (!function.isCallable()) return makeError(env, "not_callable");

    const arguments = termListToValues(env, &ctx.agent, argv[2], ctx.limits) catch |err| {
        return switch (err) {
            error.ExceptionThrown => exceptionToErrorTerm(env, &ctx.agent),
            else => convErrorToTerm(env, err),
        };
    };
    defer ctx.agent.gpa.free(arguments);

    const result = function.call(
        &ctx.agent,
        Value.from(global),
        arguments,
    ) catch |err| switch (err) {
        error.ExceptionThrown => return exceptionToErrorTerm(env, &ctx.agent),
        error.OutOfMemory => return makeError(env, "out_of_memory"),
    };

    const term = valueToTerm(env, &ctx.agent, result, ctx.limits, ctx.limits.max_depth) catch |err| {
        return switch (err) {
            error.ExceptionThrown => exceptionToErrorTerm(env, &ctx.agent),
            else => convErrorToTerm(env, err),
        };
    };

    return makeOkTuple(env, term);
}

pub export fn exjsInfo(env: ?*c.ErlNifEnv, argc: c_int, argv: [*c]const c.ERL_NIF_TERM) c.ERL_NIF_TERM {
    if (argc != 1) return c.enif_make_badarg(env);

    const ctx = getContext(env, argv[0]) orelse return makeError(env, "invalid_context");
    if (!isOwner(env, ctx)) return makeError(env, "not_owner");

    c.enif_mutex_lock(ctx.mutex);
    defer c.enif_mutex_unlock(ctx.mutex);

    if (ctx.closed) return makeError(env, "context_closed");

    var map = c.enif_make_new_map(env);
    var out: c.ERL_NIF_TERM = undefined;
    _ = c.enif_make_map_put(
        env,
        map,
        c.enif_make_atom(env, "evaluations"),
        c.enif_make_uint64(env, ctx.evaluations),
        &out,
    );
    map = out;

    return makeOkTuple(env, map);
}

pub export fn exjsClose(env: ?*c.ErlNifEnv, argc: c_int, argv: [*c]const c.ERL_NIF_TERM) c.ERL_NIF_TERM {
    if (argc != 1) return c.enif_make_badarg(env);

    lockEngine();
    defer unlockEngine();

    const ctx = getContext(env, argv[0]) orelse return makeError(env, "invalid_context");
    if (!isOwner(env, ctx)) return makeError(env, "not_owner");

    c.enif_mutex_lock(ctx.mutex);
    defer c.enif_mutex_unlock(ctx.mutex);

    if (ctx.closed) return makeError(env, "context_already_closed");

    ctx.agent.deinit();
    ctx.platform.deinit();
    ctx.closed = true;

    return c.enif_make_atom(env, "ok");
}

var nif_funcs = [_]c.ErlNifFunc{
    .{
        .name = "nif_new",
        .arity = 1,
        .fptr = exjsNew,
        .flags = @intCast(c.ERL_NIF_DIRTY_JOB_CPU_BOUND),
    },
    .{
        .name = "nif_eval",
        .arity = 2,
        .fptr = exjsEval,
        .flags = @intCast(c.ERL_NIF_DIRTY_JOB_CPU_BOUND),
    },
    .{
        .name = "nif_eval",
        .arity = 3,
        .fptr = exjsEval,
        .flags = @intCast(c.ERL_NIF_DIRTY_JOB_CPU_BOUND),
    },
    .{ .name = "nif_info", .arity = 1, .fptr = exjsInfo, .flags = 0 },
    .{
        .name = "nif_close",
        .arity = 1,
        .fptr = exjsClose,
        .flags = @intCast(c.ERL_NIF_DIRTY_JOB_CPU_BOUND),
    },
    .{
        .name = "nif_set",
        .arity = 3,
        .fptr = exjsSet,
        .flags = @intCast(c.ERL_NIF_DIRTY_JOB_CPU_BOUND),
    },
    .{
        .name = "nif_get",
        .arity = 2,
        .fptr = exjsGet,
        .flags = @intCast(c.ERL_NIF_DIRTY_JOB_CPU_BOUND),
    },
    .{
        .name = "nif_call",
        .arity = 3,
        .fptr = exjsCall,
        .flags = @intCast(c.ERL_NIF_DIRTY_JOB_CPU_BOUND),
    },
};

var nif_entry: c.ErlNifEntry = .{
    .major = c.ERL_NIF_MAJOR_VERSION,
    .minor = c.ERL_NIF_MINOR_VERSION,
    .name = "Elixir.ExJS",
    .num_of_funcs = @intCast(nif_funcs.len),
    .funcs = &nif_funcs,
    .load = nifLoad,
    .reload = null,
    .upgrade = null,
    .unload = null,
    .vm_variant = c.ERL_NIF_VM_VARIANT,
    .options = 1,
    .sizeof_ErlNifResourceTypeInit = @sizeOf(c.ErlNifResourceTypeInit),
    .min_erts = c.ERL_NIF_MIN_ERTS_VERSION,
};
