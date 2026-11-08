const builtin = @import("builtin");
const std = @import("std");

const args = @import("args");
const icu4zig = @import("icu4zig");
const kiesel = @import("kiesel");
const known_folders = @import("known-folders");
const temporal_rs = @import("temporal_rs");

const Editor = @import("zigline").Editor;

const Agent = kiesel.execution.Agent;
const Arguments = kiesel.types.Arguments;
const Diagnostics = kiesel.language.Diagnostics;
const HostHooks = kiesel.execution.HostHooks;
const ImportedModulePayload = kiesel.language.ImportedModulePayload;
const ImportedModuleReferrer = kiesel.language.ImportedModuleReferrer;
const Module = kiesel.language.Module;
const ModuleRequest = kiesel.language.ModuleRequest;
const Object = kiesel.types.Object;
const PropertyKey = kiesel.types.PropertyKey;
const Realm = kiesel.execution.Realm;
const Script = kiesel.language.Script;
const ScriptOrModule = kiesel.execution.ScriptOrModule;
const SourceTextModule = kiesel.language.SourceTextModule;
const String = kiesel.types.String;
const Token = kiesel.language.Token;
const Tokenizer = kiesel.language.Tokenizer;
const Value = kiesel.types.Value;
const createTextModule = kiesel.language.createTextModule;
const finishLoadingImportedModule = kiesel.language.finishLoadingImportedModule;
const noexcept = kiesel.utils.noexcept;
const ordinaryObjectCreate = kiesel.builtins.ordinaryObjectCreate;
const parseJSONModule = kiesel.language.parseJSONModule;
const regExpCreateFast = kiesel.builtins.regExpCreateFast;
const regExpExec = kiesel.builtins.regExpExec;
const temporaryChange = kiesel.utils.temporaryChange;

var tracked_promise_rejections: std.array_hash_map.Auto(
    *kiesel.builtins.Promise,
    HostHooks.PromiseRejectionTrackerOperation,
) = .empty;

var module_cache: ModuleRequest.HashMap(Module) = .empty;

// Python REPL my beloved 🐍
const repl_preamble = std.fmt.comptimePrint(
    \\Kiesel {[kiesel]f} [Zig {[zig]f}] on {[os]t}
    \\Use {[eof]s} to exit.
    \\
, .{
    .kiesel = kiesel.version,
    .zig = builtin.zig_version,
    .os = builtin.target.os.tag,
    .eof = if (builtin.target.os.tag == .windows) "Ctrl+Z followed by Enter" else "Ctrl+D",
});

const ScriptOrModuleHostDefined = struct {
    base_dir: []const u8,
};

const RealmHostDefined = struct {
    args: []const []const u8,
    environ_map: *const std.process.Environ.Map,
};

fn resolveModulePath(
    gpa: std.mem.Allocator,
    script_or_module: ScriptOrModule,
    specifier: []const u8,
) std.mem.Allocator.Error![]const u8 {
    const host_defined_ptr = switch (script_or_module) {
        .script => |script| script.host_defined,
        .module => |module| switch (module) {
            .source_text_module => |m| m.host_defined,
            .synthetic_module => unreachable,
        },
    };
    const host_defined: *ScriptOrModuleHostDefined = @ptrCast(@alignCast(host_defined_ptr.?));
    const base_dir: []const u8 = host_defined.base_dir;
    std.debug.assert(std.Io.Dir.path.isAbsolute(base_dir));
    const resolved_path = try std.Io.Dir.path.resolve(gpa, &.{ base_dir, specifier });
    std.debug.assert(std.Io.Dir.path.isAbsolute(resolved_path));
    return resolved_path;
}

fn initializeRealm(agent: *Agent, realm: *Realm) std.mem.Allocator.Error!void {
    // Ensure caller has not popped the realm yet
    std.debug.assert(agent.currentRealm() == realm);

    // Disable debug printing for internal script evaluation (node pls fix)
    const tmp = temporaryChange(&agent.options.debug, .{});
    defer tmp.restore();

    // Polyfill a basic console.log, too many things expect it to exist.
    // We can't invoke eval() directly as functions need an active script or module.
    const script = Script.parse(
        \\Object.defineProperties(globalThis, {
        \\    console: {
        \\        value: {
        \\            log(...args) {
        \\                Kiesel.print(args.join(" "));
        \\            },
        \\        },
        \\        writable: true,
        \\        enumerable: false,
        \\        configurable: true,
        \\    },
        \\});
    , realm, null, .{}) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        error.ParseError => unreachable,
    };
    _ = script.evaluate("polyfill") catch |err| try noexcept(err);

    try realm.global_object.defineBuiltinPropertyLazy(
        agent,
        "Kiesel",
        struct {
            fn initializer(agent_: *Agent, realm_: *Realm) std.mem.Allocator.Error!Value {
                return Value.from(try Kiesel.create(agent_, realm_));
            }
        }.initializer,
        realm,
        .builtin_default,
    );
}

const Kiesel = struct {
    pub fn create(agent: *Agent, realm: *Realm) std.mem.Allocator.Error!*Object {
        const kiesel_object = try ordinaryObjectCreate(agent, try realm.intrinsic(.object_prototype));
        try kiesel_object.defineBuiltinPropertyLazy(
            agent,
            "args",
            struct {
                fn initializer(agent_: *Agent, realm_: *Realm) std.mem.Allocator.Error!Value {
                    const gpa = agent_.gpa;
                    const io = agent_.io;
                    const host_defined: *RealmHostDefined = @ptrCast(@alignCast(realm_.host_defined.?));

                    const exe_path = std.process.executablePathAlloc(io, gpa) catch |err| switch (err) {
                        error.OutOfMemory => |e| return e,
                        else => null,
                    };
                    defer if (exe_path) |path| gpa.free(path);

                    const args_array = try kiesel.builtins.arrayCreateFast(agent_, @intCast(host_defined.args.len + 1));
                    try args_array.object.createDataPropertyDirect(
                        agent_,
                        PropertyKey.from(0),
                        if (exe_path) |path| blk: {
                            // paths are not guaranteed to be valid UTF-8
                            const path_utf8 = try agent_.gc_allocator.print("{f}", .{std.unicode.fmtUtf8(path)});
                            break :blk Value.from(try String.fromUtf8(agent_, path_utf8));
                        } else Value.from(""),
                    );
                    for (host_defined.args, 0..) |arg, i| {
                        // argv entries are not guaranteed to be valid UTF-8
                        const arg_utf8 = try agent_.gc_allocator.print("{f}", .{std.unicode.fmtUtf8(arg)});
                        try args_array.object.createDataPropertyDirect(
                            agent_,
                            PropertyKey.from(@as(PropertyKey.IntegerIndex, @intCast(i + 1))),
                            Value.from(try String.fromUtf8(agent_, arg_utf8)),
                        );
                    }
                    _ = args_array.object.setIntegrityLevel(
                        agent_,
                        .frozen,
                    ) catch |err| try noexcept(err);
                    return Value.from(&args_array.object);
                }
            }.initializer,
            realm,
            .builtin_default,
        );
        if (kiesel.build_options.enable_annex_b) {
            try kiesel_object.defineBuiltinFunction(agent, "createIsHTMLDDA", createIsHTMLDDA, 0, realm);
        }
        try kiesel_object.defineBuiltinFunction(agent, "createRealm", createRealm, 0, realm);
        try kiesel_object.defineBuiltinFunction(agent, "detachArrayBuffer", detachArrayBuffer, 1, realm);
        try kiesel_object.defineBuiltinPropertyLazy(
            agent,
            "env",
            struct {
                fn initializer(agent_: *Agent, realm_: *Realm) std.mem.Allocator.Error!Value {
                    const host_defined: *RealmHostDefined = @ptrCast(@alignCast(realm_.host_defined.?));

                    const env_object = try ordinaryObjectCreate(agent_, null);
                    for (host_defined.environ_map.keys(), host_defined.environ_map.values()) |key, value| {
                        // Environment variables are not guaranteed to be valid UTF-8
                        const key_utf8 = try agent_.gc_allocator.print("{f}", .{std.unicode.fmtUtf8(key)});
                        const value_utf8 = try agent_.gc_allocator.print("{f}", .{std.unicode.fmtUtf8(value)});
                        try env_object.createDataPropertyDirect(
                            agent_,
                            PropertyKey.from(try String.fromUtf8(agent_, key_utf8)),
                            Value.from(try String.fromUtf8(agent_, value_utf8)),
                        );
                    }
                    _ = env_object.setIntegrityLevel(agent_, .frozen) catch |err| try noexcept(err);
                    return Value.from(env_object);
                }
            }.initializer,
            realm,
            .builtin_default,
        );
        try kiesel_object.defineBuiltinFunction(agent, "evalScript", evalScript, 1, realm);
        try kiesel_object.defineBuiltinFunction(agent, "isMerlin", isMerlin, 1, realm);
        try kiesel_object.defineBuiltinFunction(agent, "print", print, 1, realm);
        try kiesel_object.defineBuiltinFunction(agent, "ptr", ptr, 1, realm);
        try kiesel_object.defineBuiltinFunction(agent, "readFile", readFile_, 1, realm);
        try kiesel_object.defineBuiltinFunction(agent, "readLine", readLine, 0, realm);
        try kiesel_object.defineBuiltinFunction(agent, "readStdin", readStdin, 0, realm);
        try kiesel_object.defineBuiltinFunction(agent, "sleep", sleep, 1, realm);
        try kiesel_object.defineBuiltinFunction(agent, "writeFile", writeFile, 2, realm);
        if (kiesel.build_options.enable_libgc) {
            const gc_object = try ordinaryObjectCreate(agent, try realm.intrinsic(.object_prototype));
            try gc_object.defineBuiltinFunction(agent, "collect", collect, 0, realm);
            try kiesel_object.defineBuiltinProperty(agent, "gc", Value.from(gc_object));
        }
        if (builtin.target.os.tag == .linux) {
            try kiesel_object.defineBuiltinFunction(agent, "asm", @"asm", 1, realm);
            try kiesel_object.defineBuiltinFunction(agent, "syscall", syscall, 1, realm);
            const sysno_object = try ordinaryObjectCreate(agent, try realm.intrinsic(.object_prototype));
            const sysno_names = comptime blk: {
                @setEvalBranchQuota(100_000);
                var names: [std.enums.values(std.os.linux.SYS).len]*const String = undefined;
                for (std.enums.values(std.os.linux.SYS), 0..) |value, i| {
                    var buf: [@tagName(value).len]u8 = undefined;
                    _ = std.ascii.upperString(&buf, @tagName(value));
                    const final = buf;
                    names[i] = String.fromLiteral(&final);
                }
                break :blk names;
            };
            for (sysno_names, std.enums.values(std.os.linux.SYS)) |name, value| {
                try sysno_object.definePropertyDirect(
                    agent,
                    PropertyKey.from(name),
                    .{
                        .value_or_accessor = .{ .value = Value.from(@as(u53, @intCast(@backingInt(value)))) },
                        .attributes = .builtin_default,
                    },
                );
            }
            try kiesel_object.defineBuiltinProperty(agent, "Sysno", Value.from(sysno_object));
        }
        return kiesel_object;
    }

    fn @"asm"(agent: *Agent, _: Value, arguments: Arguments) Agent.Error!Value {
        const buffer_value = arguments.get(0);
        const array_buffer = try buffer_value.requireInternalSlot(agent, kiesel.builtins.ArrayBuffer);
        if (kiesel.builtins.isDetachedBuffer(array_buffer)) {
            return agent.throwException(.type_error, "ArrayBuffer is detached", .{});
        }
        const data = array_buffer.fields.data_block.?.bytes;
        if (data.len == 0) {
            return agent.throwException(.type_error, "ArrayBuffer has zero length", .{});
        }
        const data_exec = std.posix.mmap(
            null,
            data.len,
            .{ .READ = true, .WRITE = true, .EXEC = true },
            .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
            -1,
            0,
        ) catch |err| {
            return agent.throwException(.internal_error, "mmap failed: {t}", .{err});
        };
        @memcpy(data_exec, data);
        @as(*const fn () callconv(.c) void, @ptrCast(data_exec))();
        return .undefined;
    }

    fn collect(_: *Agent, _: Value, _: Arguments) Agent.Error!Value {
        kiesel.gc.collect();
        return .undefined;
    }

    fn createIsHTMLDDA(agent: *Agent, _: Value, _: Arguments) Agent.Error!Value {
        const realm = agent.currentRealm();
        const is_htmldda = try kiesel.builtins.Object.create(agent, .{
            .prototype = try realm.intrinsic(.object_prototype),
            .is_htmldda = true,
            .internal_methods = .initComptime(.{
                .call = struct {
                    /// This is required by [test262](https://github.com/tc39/test262/blob/main/INTERPRETING.md#host-defined-functions).
                    ///
                    /// What should happen when the function is being called with something
                    /// other than no arguments or an empty string is unclear and different
                    /// test262 runtimes disagree on this:
                    ///
                    /// - JSC: [Returns null unconditionally](https://github.com/WebKit/WebKit/blob/b571ec5131dcca906981b9a477d7b71e9605b6a6/Source/JavaScriptCore/jsc.cpp#L2818-L2827)
                    /// - V8: [Returns null unconditionally](https://source.chromium.org/chromium/chromium/src/+/main:v8/src/runtime/runtime-test.cc;l=1038-1055;drc=ca3478a884cd4d1c5d7897ded9838773ca1c4fd3)
                    /// - QuickJS: [Returns null unconditionally](https://github.com/quickjs-ng/quickjs/blob/6868fb9e2516fde4a7a3fcef113a6bb1e5ecc957/run-test262.c#L753-L757)
                    /// - LibJS: [Returns undefined](https://github.com/SerenityOS/serenity/blob/9a207da36845e18dc4f747d8ecc98fbc0e11545c/Userland/Libraries/LibJS/Contrib/Test262/IsHTMLDDA.cpp#L20-L32)
                    /// - SpiderMonkey: [Throws](https://searchfox.org/mozilla-central/rev/c130c69b7b863d5e28ab9524b65c27c7a9507c48/js/src/shell/js.cpp#7071-7085)
                    ///
                    /// We pick the most common one :^)
                    fn call(_: *Agent, _: *Object, _: Value, _: Arguments) Agent.Error!Value {
                        return .null;
                    }
                }.call,
            }),
        });
        return Value.from(&is_htmldda.object);
    }

    fn createRealm(agent: *Agent, _: Value, _: Arguments) Agent.Error!Value {
        const caller_realm = agent.currentRealm();
        try Realm.initializeHostDefinedRealm(agent, .{});
        const realm = agent.currentRealm();
        realm.host_defined = caller_realm.host_defined;
        try initializeRealm(agent, realm);
        _ = agent.execution_context_stack.pop().?;
        return Value.from(realm.global_object);
    }

    fn detachArrayBuffer(agent: *Agent, _: Value, arguments: Arguments) Agent.Error!Value {
        const array_buffer_value = arguments.get(0);
        const array_buffer = try array_buffer_value.requireInternalSlot(agent, kiesel.builtins.ArrayBuffer);
        if (kiesel.builtins.isSharedArrayBuffer(array_buffer)) {
            return agent.throwException(
                .type_error,
                "{f} is not an ArrayBuffer object",
                .{array_buffer_value},
            );
        }
        try kiesel.builtins.detachArrayBuffer(agent, array_buffer, null);
        return .undefined;
    }

    /// Algorithm from https://github.com/tc39/test262/blob/main/INTERPRETING.md
    fn evalScript(agent: *Agent, _: Value, arguments: Arguments) Agent.Error!Value {
        const gpa = agent.gpa;

        const source_text = try (try arguments.get(0).toString(agent)).toWtf8(gpa);
        defer gpa.free(source_text);

        // 1. Let hostDefined be any host-defined values for the provided sourceText (obtained in
        //    an implementation dependent manner)
        const host_defined = switch (agent.getActiveScriptOrModule().?) {
            .script => |script| script.host_defined,
            .module => |module| switch (module) {
                .source_text_module => |m| m.host_defined,
                .synthetic_module => unreachable,
            },
        };

        // 2. Let realm be the current Realm Record.
        const realm = agent.currentRealm();

        var diagnostics: Diagnostics = .init(gpa, .{
            .source = source_text,
            .file_name = "evalScript",
        });
        defer diagnostics.deinit();

        // 3. Let s be ParseScript(sourceText, realm, hostDefined).
        const script = Script.parse(source_text, realm, host_defined, .{
            .diagnostics = &diagnostics,
        }) catch |err| switch (err) {
            error.OutOfMemory => |e| return e,
            // 4. If s is a List of errors, then
            error.ParseError => {
                // a. Let error be the first element of s.
                const parse_error = diagnostics.first().?;

                // b. Return Completion{[[Type]]: throw, [[Value]]: error, [[Target]]: empty}.
                return agent.throwException(.syntax_error, "{f}", .{parse_error.fmt(&diagnostics)});
            },
        };

        // 5. Let status be ScriptEvaluation(s).
        // 6. Return Completion(status).
        return script.evaluate("evalScript");
    }

    fn isMerlin(agent: *Agent, _: Value, arguments: Arguments) Agent.Error!Value {
        const value = arguments.get(0);
        const string = try value.toString(agent);
        // See https://github.com/DerMolly/is-merlin/blob/main/src/index.ts for the source of the regexp
        const regexp = try regExpCreateFast(
            agent,
            String.fromLiteral("[mM][eE][rR][lL][iI][nN]|[rR][uU][hH][rR][-_\\s]*[sS][cC][hH][oO][lL][zZ]"),
            .empty,
        );
        const match = try regExpExec(agent, &regexp.object, string);
        return Value.from(match != null);
    }

    fn print(agent: *Agent, _: Value, arguments: Arguments) Agent.Error!Value {
        const stdout = agent.platform.stdout;
        const value = arguments.get(0);
        const options = try arguments.get(1).coerceOptionsToObject(agent);
        const newline = try options.getOption(agent, "newline", .boolean, null, true);
        const pretty = try options.getOption(agent, "pretty", .boolean, null, false);
        const end = if (newline) "\n" else "";
        if (pretty)
            stdout.print("{f}{s}", .{ value.fmtPretty(null), end }) catch {}
        else
            stdout.print("{f}{s}", .{ (try value.toString(agent)).fmtRaw(), end }) catch {};
        stdout.flush() catch {};
        return .undefined;
    }

    fn ptr(agent: *Agent, _: Value, arguments: Arguments) Agent.Error!Value {
        const value = arguments.get(0);
        const value_ptr: ?*const anyopaque = if (value.isString()) blk: {
            const string_utf8 = try value.asString().toUtf8(agent.gc_allocator);
            break :blk string_utf8.ptr;
        } else if (value.isObject() and value.asObject().is(kiesel.builtins.ArrayBuffer)) blk: {
            const array_buffer = value.asObject().as(kiesel.builtins.ArrayBuffer);
            if (array_buffer.fields.data_block) |data_block| {
                if (data_block.bytes.len != 0) {
                    break :blk data_block.bytes.ptr;
                }
            }
            break :blk null;
        } else {
            return agent.throwException(.type_error, "Cannot get pointer for value {f}", .{value});
        };
        return Value.from(std.math.lossyCast(f64, @intFromPtr(value_ptr)));
    }

    fn readFile_(agent: *Agent, _: Value, arguments: Arguments) Agent.Error!Value {
        const gpa = agent.gpa;
        const io = agent.io;
        const path = try (try arguments.get(0).toString(agent)).toUtf8(gpa);
        defer gpa.free(path);
        const bytes = readFile(agent.gc_allocator, io, path) catch |err| switch (err) {
            error.OutOfMemory => |e| return e,
            else => return agent.throwException(
                .type_error,
                "Error while reading file: {t}",
                .{err},
            ),
        };
        if (!std.unicode.utf8ValidateSlice(bytes)) {
            return agent.throwException(.type_error, "Invalid UTF-8", .{});
        }
        return Value.from(try String.fromUtf8(agent, bytes));
    }

    fn readLine(agent: *Agent, _: Value, _: Arguments) Agent.Error!Value {
        const io = agent.io;
        var stdin_buf: [1024]u8 = undefined;
        var stdin_reader = std.Io.File.stdin().reader(io, &stdin_buf);
        const stdin = &stdin_reader.interface;

        var allocating_writer: std.Io.Writer.Allocating = .init(agent.gc_allocator);
        defer allocating_writer.deinit();
        const writer = &allocating_writer.writer;

        _ = stdin.streamDelimiterEnding(writer, '\n') catch |err| {
            return agent.throwException(
                .type_error,
                "Error while reading from stdin: {t}",
                .{err},
            );
        };
        if (!std.unicode.utf8ValidateSlice(allocating_writer.written())) {
            return agent.throwException(.type_error, "Invalid UTF-8", .{});
        }
        return Value.from(try String.fromUtf8(agent, try allocating_writer.toOwnedSlice()));
    }

    fn readStdin(agent: *Agent, _: Value, _: Arguments) Agent.Error!Value {
        const io = agent.io;
        var stdin_buf: [1024]u8 = undefined;
        var stdin_reader = std.Io.File.stdin().reader(io, &stdin_buf);
        const stdin = &stdin_reader.interface;

        const bytes = stdin.allocRemaining(
            agent.gc_allocator,
            .unlimited,
        ) catch |err| {
            return agent.throwException(
                .type_error,
                "Error while reading from stdin: {t}",
                .{err},
            );
        };
        if (!std.unicode.utf8ValidateSlice(bytes)) {
            return agent.throwException(.type_error, "Invalid UTF-8", .{});
        }
        return Value.from(try String.fromUtf8(agent, bytes));
    }

    fn sleep(agent: *Agent, _: Value, arguments: Arguments) Agent.Error!Value {
        const io = agent.io;
        const milliseconds = try arguments.get(0).toNumber(agent);
        if (milliseconds.asFloat() < 0 or !milliseconds.isFinite()) {
            return agent.throwException(
                .range_error,
                "Sleep duration must be a positive finite number",
                .{},
            );
        }
        const nanoseconds = std.math.lossyCast(i96, milliseconds.asFloat() * 1_000_000);
        io.sleep(.fromNanoseconds(nanoseconds), .real) catch {};
        return .undefined;
    }

    fn writeFile(agent: *Agent, _: Value, arguments: Arguments) Agent.Error!Value {
        const gpa = agent.gpa;
        const io = agent.io;
        const path = try (try arguments.get(0).toString(agent)).toUtf8(gpa);
        defer gpa.free(path);
        const contents = try (try arguments.get(1).toString(agent)).toUtf8(gpa);
        defer gpa.free(contents);

        const file = std.Io.Dir.cwd().createFile(io, path, .{}) catch |err| {
            return agent.throwException(.type_error, "Error while opening file: {t}", .{err});
        };
        defer file.close(io);
        file.writeStreamingAll(io, contents) catch |err| {
            return agent.throwException(.type_error, "Error while writing file: {t}", .{err});
        };
        return .undefined;
    }

    fn syscall(agent: *Agent, _: Value, arguments: Arguments) Agent.Error!Value {
        const number_value = try arguments.get(0).toLength(agent);
        const number = std.enums.fromInt(std.os.linux.SYS, number_value) orelse {
            return agent.throwException(.range_error, "Invalid syscall number {d}", .{number_value});
        };
        const result = switch (arguments.count() -| 1) {
            0 => blk: {
                break :blk std.os.linux.syscall0(number);
            },
            1 => blk: {
                const arg1 = try arguments.get(1).toLength(agent);
                break :blk std.os.linux.syscall1(number, std.math.lossyCast(usize, arg1));
            },
            2 => blk: {
                const arg1 = try arguments.get(1).toLength(agent);
                const arg2 = try arguments.get(2).toLength(agent);
                break :blk std.os.linux.syscall2(number, std.math.lossyCast(usize, arg1), std.math.lossyCast(usize, arg2));
            },
            3 => blk: {
                const arg1 = try arguments.get(1).toLength(agent);
                const arg2 = try arguments.get(2).toLength(agent);
                const arg3 = try arguments.get(3).toLength(agent);
                break :blk std.os.linux.syscall3(number, std.math.lossyCast(usize, arg1), std.math.lossyCast(usize, arg2), std.math.lossyCast(usize, arg3));
            },
            4 => blk: {
                const arg1 = try arguments.get(1).toLength(agent);
                const arg2 = try arguments.get(2).toLength(agent);
                const arg3 = try arguments.get(3).toLength(agent);
                const arg4 = try arguments.get(4).toLength(agent);
                break :blk std.os.linux.syscall4(number, std.math.lossyCast(usize, arg1), std.math.lossyCast(usize, arg2), std.math.lossyCast(usize, arg3), std.math.lossyCast(usize, arg4));
            },
            5 => blk: {
                const arg1 = try arguments.get(1).toLength(agent);
                const arg2 = try arguments.get(2).toLength(agent);
                const arg3 = try arguments.get(3).toLength(agent);
                const arg4 = try arguments.get(4).toLength(agent);
                const arg5 = try arguments.get(5).toLength(agent);
                break :blk std.os.linux.syscall5(number, std.math.lossyCast(usize, arg1), std.math.lossyCast(usize, arg2), std.math.lossyCast(usize, arg3), std.math.lossyCast(usize, arg4), std.math.lossyCast(usize, arg5));
            },
            6 => blk: {
                const arg1 = try arguments.get(1).toLength(agent);
                const arg2 = try arguments.get(2).toLength(agent);
                const arg3 = try arguments.get(3).toLength(agent);
                const arg4 = try arguments.get(4).toLength(agent);
                const arg5 = try arguments.get(5).toLength(agent);
                const arg6 = try arguments.get(6).toLength(agent);
                break :blk std.os.linux.syscall6(number, std.math.lossyCast(usize, arg1), std.math.lossyCast(usize, arg2), std.math.lossyCast(usize, arg3), std.math.lossyCast(usize, arg4), std.math.lossyCast(usize, arg5), std.math.lossyCast(usize, arg6));
            },
            else => return agent.throwException(.type_error, "Too many syscall arguments", .{}),
        };
        return Value.from(std.math.lossyCast(f64, result));
    }
};

fn run(gpa: std.mem.Allocator, realm: *Realm, source_text: []const u8, options: struct {
    base_dir: []const u8,
    origin: union(enum) {
        repl,
        command,
        path: []const u8,
    },
    module: bool,
    print_promise_rejection_warnings: bool,
}) !Value {
    const agent = realm.agent;
    const stdout = agent.platform.stdout;
    const stderr = agent.platform.stderr;
    const debug_print =
        agent.options.debug.print_ast or
        agent.options.debug.print_ir or
        agent.options.debug.print_bytecode;

    const host_defined = try agent.gc_allocator.create(ScriptOrModuleHostDefined);
    host_defined.* = .{ .base_dir = options.base_dir };

    const file_name: []const u8 = switch (options.origin) {
        .repl => "repl",
        .command => "command",
        .path => |path| path,
    };

    var diagnostics: Diagnostics = .init(gpa, .{
        .source = source_text,
        .file_name = file_name,
    });
    defer diagnostics.deinit();

    const parse_result: error{ ParseError, OutOfMemory }!ScriptOrModule = if (options.module) blk: {
        break :blk if (SourceTextModule.parse(source_text, realm, host_defined, .{
            .diagnostics = &diagnostics,
        })) |source_text_module| .{
            .module = .{ .source_text_module = source_text_module },
        } else |err| err;
    } else blk: {
        break :blk if (Script.parse(source_text, realm, host_defined, .{
            .diagnostics = &diagnostics,
        })) |script| .{ .script = script } else |err| err;
    };

    const script_or_module = parse_result catch |err| switch (err) {
        error.ParseError => {
            const parse_error = diagnostics.first().?;
            const syntax_error = try agent.createErrorObject(
                .syntax_error,
                "{f}",
                .{parse_error.fmt(&diagnostics)},
            );
            const exception: Agent.Exception = .{
                .value = Value.from(&syntax_error.object),
                .stack_trace = &.{},
            };
            try stderr.print("{f}\nUncaught exception: {f}\n", .{
                parse_error.fmtHint(&diagnostics),
                exception.fmtPretty(agent, null),
            });
            try stderr.flush();
            return error.AlreadyReported;
        },
        error.OutOfMemory => |e| return e,
    };

    if (agent.options.debug.print_ast) {
        switch (script_or_module) {
            .script => |script| try script.print(stdout),
            .module => |module| try module.source_text_module.print(stdout),
        }
        try stdout.flush();
    }

    defer {
        agent.drainJobQueue();

        // Report tracked promise rejections
        if (options.print_promise_rejection_warnings) {
            var it = tracked_promise_rejections.iterator();
            while (it.next()) |entry| {
                const promise = entry.key_ptr.*;
                const operation = entry.value_ptr.*;
                switch (operation) {
                    .reject => stderr.print(
                        "A promise was rejected without any handlers: {f}\n",
                        .{Value.from(&promise.object).fmtPretty(null)},
                    ) catch {},
                    .handle => stderr.print(
                        "A handler was added to an already rejected promise: {f}\n",
                        .{Value.from(&promise.object).fmtPretty(null)},
                    ) catch {},
                }
                stderr.flush() catch {};
            }
        }
        tracked_promise_rejections.clearAndFree(agent.gc_allocator);
    }

    return switch (script_or_module) {
        .script => |script| script.evaluate(file_name),
        .module => |module| blk: {
            const module_path = resolveModulePath(
                agent.gc_allocator,
                script_or_module,
                options.origin.path,
            ) catch |err| break :blk err;
            const cache_key: ModuleRequest = .{
                .specifier = try String.fromUtf8(agent, module_path),
                .attributes = &.{},
            };
            try module_cache.putNoClobber(agent.gc_allocator, cache_key, module);
            var promise = module.loadRequestedModules(agent, null) catch |err| break :blk err;
            std.debug.assert(agent.queued_jobs.items.len == 0);
            switch (promise.fields.promise_state) {
                .pending => unreachable,
                .rejected => {
                    tracked_promise_rejections.clearAndFree(agent.gc_allocator);
                    agent.exception = .{
                        .value = promise.fields.promise_result,
                        // TODO: Capture stack when rejecting a promise
                        .stack_trace = &.{},
                    };
                    break :blk error.ExceptionThrown;
                },
                .fulfilled => {
                    module.link(agent) catch |err| break :blk err;
                    promise = module.evaluate(agent) catch |err| break :blk err;
                    std.debug.assert(agent.queued_jobs.items.len == 0);
                    switch (promise.fields.promise_state) {
                        .pending => unreachable,
                        .rejected => {
                            tracked_promise_rejections.clearAndFree(agent.gc_allocator);
                            agent.exception = .{
                                .value = promise.fields.promise_result,
                                // TODO: Capture stack when rejecting a promise
                                .stack_trace = &.{},
                            };
                            break :blk error.ExceptionThrown;
                        },
                        .fulfilled => {
                            break :blk Value.undefined;
                        },
                    }
                },
            }
        },
    } catch |err| switch (err) {
        error.OutOfMemory => {
            if (debug_print) try stderr.writeByte('\n');
            try stderr.writeAll("Out of memory\n");
            try stderr.flush();
            return error.AlreadyReported;
        },
        error.ExceptionThrown => {
            const exception = agent.clearException();
            if (debug_print) try stderr.writeByte('\n');
            try stderr.print("Uncaught exception: {f}\n", .{
                exception.fmtPretty(agent, null),
            });
            try stderr.flush();
            return error.AlreadyReported;
        },
    };
}

const ReadFileError = std.Io.File.OpenError || std.Io.Reader.LimitedAllocError;

fn readFile(gpa: std.mem.Allocator, io: std.Io, path: []const u8) ReadFileError![]const u8 {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var file_reader = file.reader(io, &.{});
    const reader = &file_reader.interface;
    return reader.allocRemaining(gpa, .unlimited);
}

const GetHistoryPathError =
    known_folders.Error ||
    std.mem.Allocator.Error ||
    std.Io.Dir.CreateDirPathError ||
    std.Io.File.OpenError;

fn getHistoryPath(gpa: std.mem.Allocator, io: std.Io, environ_map: *const std.process.Environ.Map) GetHistoryPathError![]const u8 {
    const data_path = try known_folders.getPath(io, gpa, environ_map, .data) orelse ".";
    defer gpa.free(data_path);

    const kiesel_data_path = try std.Io.Dir.path.join(gpa, &.{ data_path, "kiesel" });
    defer gpa.free(kiesel_data_path);

    std.Io.Dir.cwd().createDirPath(io, kiesel_data_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    const history_path = try std.Io.Dir.path.join(gpa, &.{ kiesel_data_path, "history" });
    errdefer gpa.free(history_path);

    const file = try std.Io.Dir.cwd().createFile(io, history_path, .{ .truncate = false });
    file.close(io);

    return history_path;
}

fn printVersionInfo(writer: *std.Io.Writer) std.Io.Writer.Error!void {
    const enabled_features, const disabled_features = comptime blk: {
        var enabled_features: []const []const u8 = &.{};
        var disabled_features: []const []const u8 = &.{};
        const info = @typeInfo(kiesel.build_options).@"struct";
        for (info.decl_names) |decl_name| {
            if (std.mem.startsWith(u8, decl_name, "enable_")) {
                const feature = decl_name["enable_".len..];
                if (@field(kiesel.build_options, decl_name)) {
                    enabled_features = enabled_features ++ .{feature};
                } else {
                    disabled_features = disabled_features ++ .{feature};
                }
            }
        }
        break :blk .{ enabled_features, disabled_features };
    };
    try writer.print("Kiesel {f}\n\n", .{kiesel.version});
    try writer.print("Zig version        {s}\n", .{builtin.zig_version_string});
    if (kiesel.build_options.enable_intl or kiesel.build_options.enable_temporal) {
        try writer.print("Rust version       {s}\n", .{kiesel.zement.rustcVersion()});
    }
    try writer.print("Target             {t}-{t}-{t}\n", .{ builtin.target.cpu.arch, builtin.target.os.tag, builtin.target.abi });
    try writer.print("Optimize           {t}\n", .{builtin.optimize});
    if (enabled_features.len > 0) {
        try writer.writeAll("Enabled features   ");
        for (enabled_features, 0..) |feature, i| {
            if (i != 0) try writer.writeByte(' ');
            try writer.writeAll(feature);
        }
        try writer.writeByte('\n');
    }
    if (disabled_features.len > 0) {
        try writer.writeAll("Disabled features  ");
        for (disabled_features, 0..) |feature, i| {
            if (i != 0) try writer.writeByte(' ');
            try writer.writeAll(feature);
        }
        try writer.writeByte('\n');
    }
}

fn printValueDebugInfo(value: Value, terminal: std.Io.Terminal) std.Io.Terminal.SetColorError!void {
    // Porffor REPL my beloved 💜
    try terminal.setColor(.blue);
    switch (value.type()) {
        .number => try terminal.writer.print(" (type: {t})", .{value.asNumber()}),
        .string => try terminal.writer.print(" (ptr: 0x{x}, type: {t}, length: {d}, hash: 0x{x})", .{
            @intFromPtr(value.asString()),
            value.asString().data,
            value.asString().length,
            value.asString().hash,
        }),
        .symbol => try terminal.writer.print(" (ptr: 0x{x})", .{@intFromPtr(value.asSymbol())}),
        .object => {
            const object = value.asObject();
            const indexed_properties = object.indexedProperties();
            try terminal.writer.print(" (ptr: 0x{x}, shape: 0x{x}, indexed: {t}, tag: {t})", .{
                @intFromPtr(object),
                @intFromPtr(object.shape),
                indexed_properties.storage,
                object.tag,
            });
        },
        else => {},
    }
    try terminal.setColor(.reset);
}

fn repl(
    gpa: std.mem.Allocator,
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
    realm: *Realm,
    options: struct {
        base_dir: []const u8,
        debug: bool,
        print_promise_rejection_warnings: bool,
    },
) !void {
    const agent = realm.agent;
    const stdout = agent.platform.stdout;
    const debug_print =
        agent.options.debug.print_ast or
        agent.options.debug.print_ir or
        agent.options.debug.print_bytecode;

    try stdout.writeAll(repl_preamble);
    try stdout.flush();

    var editor = Editor.init(gpa, io, .{});
    defer editor.deinit();

    var handler: struct {
        editor: *Editor,
        realm: *Realm,
        string_arena: std.heap.ArenaAllocator,
        completion_buffer: ?[]Editor.CompletionSuggestion = null,

        pub fn display_refresh(self: *@This()) void {
            self.editor.stripStyles();

            const line = self.editor.getBufferedLine() catch return;
            defer self.editor.allocator.free(line);

            // NOTE: zigline always returns valid UTF-8.
            const source = self.editor.allocator.dupeSentinel(u8, line, 0) catch return;
            defer self.editor.allocator.free(source);

            var tokenizer: Tokenizer = .init(self.editor.allocator, source);
            defer tokenizer.deinit();

            while (tokenizer.next() catch null) |token| {
                self.editor.stylize(
                    .{ .begin = @backingInt(token.start), .end = @backingInt(token.end) },
                    switch (token.tag) {
                        .keyword_await,
                        .keyword_break,
                        .keyword_catch,
                        .keyword_class,
                        .keyword_const,
                        .keyword_continue,
                        .keyword_debugger,
                        .keyword_default,
                        .keyword_delete,
                        .keyword_enum,
                        .keyword_export,
                        .keyword_extends,
                        .keyword_function,
                        .keyword_import,
                        .keyword_in,
                        .keyword_instanceof,
                        .keyword_new,
                        .keyword_return,
                        .keyword_super,
                        .keyword_this,
                        .keyword_typeof,
                        .keyword_var,
                        .keyword_void,
                        => .{ .foreground = .{ .xterm = .blue }, .bold = true },

                        .line_comment,
                        .multiline_comment,
                        .html_open_comment,
                        .html_close_comment,
                        .hashbang_comment,
                        .keyword_case,
                        .keyword_do,
                        .keyword_else,
                        .keyword_finally,
                        .keyword_for,
                        .keyword_if,
                        .keyword_switch,
                        .keyword_throw,
                        .keyword_try,
                        .keyword_while,
                        .keyword_with,
                        .keyword_yield,
                        => .{ .foreground = .{ .xterm = .cyan } },

                        .keyword_false, .keyword_true => .{ .foreground = .{ .xterm = .blue } },
                        .keyword_null => .{ .foreground = .{ .xterm = .yellow } },
                        .number_literal, .bigint_literal => .{ .foreground = .{ .xterm = .magenta } },
                        .regexp_literal,
                        .string_literal,
                        .template_literal,
                        .template_literal_head,
                        .template_literal_middle,
                        .template_literal_tail,
                        => .{ .foreground = .{ .xterm = .green } },
                        else => .{},
                    },
                ) catch continue;
            }
        }

        pub fn tab_complete(self: *@This()) ![]const Editor.CompletionSuggestion {
            const gpa_ = self.editor.allocator;

            _ = self.string_arena.reset(.{ .retain_with_limit = 4096 });
            const string_arena = self.string_arena.allocator();

            const line = self.editor.getBufferedLineUpTo(self.editor.cursor) catch return &.{};
            defer self.editor.allocator.free(line);

            // NOTE: zigline always returns valid UTF-8.
            const source = self.editor.allocator.dupeSentinel(u8, line, 0) catch return &.{};
            defer self.editor.allocator.free(source);

            var tokenizer: Tokenizer = .init(self.editor.allocator, source);
            defer tokenizer.deinit();

            var token_window: [3]?Token = .{ null, null, null };
            while (tokenizer.next() catch null) |token| {
                switch (token.tag) {
                    .line_comment,
                    .multiline_comment,
                    .html_open_comment,
                    .html_close_comment,
                    .hashbang_comment,
                    => continue,
                    else => {},
                }
                // Shift tokens in the window to the left
                token_window[0] = token_window[1];
                token_window[1] = token_window[2];
                token_window[2] = token;
            }

            if (token_window[2] == null)
                token_window[2] = .{ .tag = .identifier, .start = @fromBackingInt(0), .end = @fromBackingInt(0) };

            if (self.completion_buffer == null)
                self.completion_buffer = try self.editor.allocator.alloc(Editor.CompletionSuggestion, 256);

            var suggestions: std.ArrayList(Editor.CompletionSuggestion) = .initBuffer(self.completion_buffer.?);
            var seen: String.HashMap(void) = .empty;
            defer seen.deinit(self.editor.allocator);

            // (k1)(.)(prop) OR (_)(k1)(.) -> complete property names of k1, starting with prop (if present)
            // (_)(_)(ident) -> complete global object property names starting with ident.
            const is_property_completion_partial = token_window[2].?.tag == .period and token_window[1] != null and token_window[1].?.tag == .identifier;
            const is_property_completion_full = token_window[2].?.tag == .identifier and token_window[1] != null and token_window[1].?.tag == .period and token_window[0] != null and token_window[0].?.tag == .identifier;
            const is_global_object_property_completion = token_window[2].?.tag == .identifier and (token_window[1] == null or token_window[1].?.tag != .period);

            const object = if (is_property_completion_partial or is_property_completion_full) b: {
                const object_name = if (is_property_completion_partial) token_window[1].?.text(source) else token_window[0].?.text(source);
                const object_name_string = String.fromUtf8(self.realm.agent, object_name) catch return &.{};
                if (!(self.realm.global_env.hasBinding(self.realm.agent, object_name_string) catch false)) return &.{};

                const object_value = self.realm.global_env.getBindingValue(self.realm.agent, object_name_string, true) catch return &.{};
                if (!object_value.isObject()) return &.{};
                break :b object_value.asObject();
            } else if (is_global_object_property_completion) self.realm.global_object else return &.{};

            const prefix_utf8 = if (token_window[2].?.tag == .identifier) token_window[2].?.text(source) else "";
            const prefix = String.fromUtf8(self.realm.agent, prefix_utf8) catch return &.{};

            for (object.shape.properties.keys()) |key| {
                const property_name = switch (key) {
                    .string => |string| string,
                    else => continue,
                };
                if (!property_name.startsWith(prefix)) continue;
                const gop = seen.getOrPut(gpa_, property_name) catch return &.{};
                if (gop.found_existing) continue;
                const property_name_utf8 = property_name.toUtf8(string_arena) catch return &.{};
                suggestions.appendBounded(.{
                    .text = property_name_utf8,
                    .invariant_offset = prefix_utf8.len,
                }) catch break; // OOM -> stop producing suggestions.
            }

            // (_)(_)(ident) -> complete global names starting with ident
            if (is_global_object_property_completion) {
                var it = self.realm.global_env.declarative_record.bindings.keyIterator();
                while (it.next()) |binding_name_ptr| {
                    const binding_name = binding_name_ptr.*;
                    if (!binding_name.startsWith(prefix)) continue;
                    const gop = seen.getOrPut(gpa_, binding_name) catch return &.{};
                    if (gop.found_existing) continue;
                    const binding_name_utf8 = binding_name.toUtf8(string_arena) catch return &.{};
                    suggestions.appendBounded(.{
                        .text = binding_name_utf8,
                        .invariant_offset = prefix_utf8.len,
                    }) catch break;
                }
            }

            std.mem.sort(Editor.CompletionSuggestion, suggestions.items, {}, struct {
                fn lessThanFn(
                    _: void,
                    lhs: Editor.CompletionSuggestion,
                    rhs: Editor.CompletionSuggestion,
                ) bool {
                    return std.mem.lessThan(u8, lhs.text, rhs.text);
                }
            }.lessThanFn);

            return suggestions.items;
        }
    } = .{
        .editor = &editor,
        .realm = realm,
        .string_arena = .init(gpa),
    };

    editor.setHandler(&handler);
    defer {
        if (handler.completion_buffer) |buffer| {
            gpa.free(buffer);
            handler.completion_buffer = null;
        }
        handler.string_arena.deinit();
    }

    const history_path = if (builtin.target.os.tag != .wasi) try getHistoryPath(gpa, io, environ_map);
    defer if (builtin.target.os.tag != .wasi) gpa.free(history_path);

    if (builtin.target.os.tag != .wasi) editor.loadHistory(history_path) catch {
        try stdout.writeAll("Failed to load history\n");
        try stdout.flush();
    };
    defer if (builtin.target.os.tag != .wasi) editor.saveHistory(history_path) catch {
        stdout.writeAll("Failed to save history\n") catch {};
        stdout.flush() catch {};
    };

    var lines: usize = 0;
    while (true) {
        const source_text = editor.getLine("> ") catch |err| switch (err) {
            error.Eof => break,
            else => return err,
        };
        defer gpa.free(source_text);

        // Directly show another prompt when spamming enter, whitespace is evaluated
        // however (and will print 'undefined').
        if (source_text.len == 0) continue;

        try editor.addToHistory(source_text);
        lines += 1;

        const result = run(gpa, realm, source_text, .{
            .base_dir = options.base_dir,
            .origin = .repl,
            .module = false,
            .print_promise_rejection_warnings = options.print_promise_rejection_warnings,
        }) catch |err| switch (err) {
            // Handled exception & printed something, carry on
            error.AlreadyReported => continue,
            else => return err,
        };
        if (debug_print) try stdout.writeByte('\n');
        try stdout.print("{f}", .{result.fmtPretty(null)});
        if (options.debug) {
            const terminal: std.Io.Terminal = .{
                .writer = stdout,
                .mode = agent.platform.terminal_mode,
            };
            try printValueDebugInfo(result, terminal);
        }
        try stdout.writeAll("\n");
        try stdout.flush();
    }
    switch (lines) {
        0 => {},
        1 => {
            try stdout.writeAll("Thanks for using Kiesel to evaluate one line of JavaScript :)\n");
            try stdout.flush();
        },
        else => {
            try stdout.print("Thanks for using Kiesel to evaluate {d} lines of JavaScript :)\n", .{lines});
            try stdout.flush();
        },
    }
}

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    const environ_map = init.environ_map;

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buffer);
    const stderr = &stderr_writer.interface;

    const Options = struct {
        command: ?[]const u8 = null,
        debug: bool = false,
        @"disable-gc": bool = false,
        module: ?bool = null,
        @"print-ast": bool = false,
        @"print-bytecode": bool = false,
        @"print-ir": bool = false,
        @"print-gc-warnings": bool = false,
        @"print-promise-rejection-warnings": bool = true,
        @"print-result": bool = false,
        version: bool = false,
        help: bool = false,

        pub const shorthands = .{
            .c = "command",
            .d = "debug",
            .m = "module",
            .p = "print-result",
            .v = "version",
            .h = "help",
        };

        pub const meta = .{
            .usage_summary = "[options] [file]",
            .option_docs = .{
                .command = "Run the given code instead of reading from a file",
                .debug = "Enable debug mode",
                .@"disable-gc" = "Disable garbage collection",
                .module = "Run code as a module instead of a script",
                .@"print-ast" = "Print the parsed AST",
                .@"print-bytecode" = "Print the generated bytecode",
                .@"print-ir" = "Print the generated IR",
                .@"print-gc-warnings" = "Print GC warnings, e.g. OOM",
                .@"print-promise-rejection-warnings" = "Print promise rejection warnings",
                .@"print-result" = "Print the evaluated result",
                .version = "Print version information and exit",
                .help = "Print help text and exit",
            },
        };
    };
    const parsed_args = args.parseForCurrentProcess(Options, init, .print) catch return 1;
    defer parsed_args.deinit();

    const maybe_path = if (parsed_args.options.command == null and parsed_args.positionals.len > 0)
        parsed_args.positionals[0]
    else
        null;

    if (parsed_args.options.version) {
        try printVersionInfo(stdout);
        try stdout.flush();
        return 0;
    }
    if (parsed_args.options.help) {
        try args.printHelp(Options, "kiesel", stdout);
        try stdout.flush();
        return 0;
    }
    if (parsed_args.options.module != null) {
        if (maybe_path == null) {
            try stderr.writeAll("-m/--module option must not be used in REPL mode\n");
            try stderr.flush();
            return 1;
        }
        if (parsed_args.options.command != null) {
            try stderr.writeAll("-m/--module option must not be used with -c/--command\n");
            try stderr.flush();
            return 1;
        }
    }

    const run_as_module =
        parsed_args.options.module orelse
        if (maybe_path) |path| std.mem.endsWith(u8, path, ".mjs") else false;

    if (kiesel.build_options.enable_libgc and parsed_args.options.@"disable-gc") {
        kiesel.gc.disable();
    }
    if (kiesel.build_options.enable_libgc and !parsed_args.options.@"print-gc-warnings") {
        kiesel.gc.disableWarnings();
    }
    var platform: Agent.Platform = .default(io, environ_map);
    defer platform.deinit();
    var agent = try Agent.init(gpa, io, &platform, .{
        .debug = .{
            .print_ast = parsed_args.options.@"print-ast",
            .print_bytecode = parsed_args.options.@"print-bytecode",
            .print_ir = parsed_args.options.@"print-ir",
        },
    });
    defer agent.deinit();

    if (kiesel.build_options.enable_intl) {
        if (environ_map.get("LANG")) |lang| {
            const lang_trimmed = std.mem.cutSuffix(u8, lang, ".UTF-8") orelse lang;
            if (icu4zig.Locale.fromString(lang_trimmed)) |locale|
                platform.default_locale = locale
            else |_| {}
        }
    }

    if (kiesel.build_options.enable_temporal) {
        if (environ_map.get("TZ")) |tz| {
            const string_view = temporal_rs.toDiplomatStringView(tz);
            if (temporal_rs.success(
                temporal_rs.c.temporal_rs_TimeZone_try_from_identifier_str(string_view),
            ) orelse temporal_rs.success(
                temporal_rs.c.temporal_rs_TimeZone_try_from_offset_str(string_view),
            )) |time_zone| {
                platform.default_time_zone = time_zone;
            }
        }
    }

    defer tracked_promise_rejections.deinit(agent.gc_allocator);
    defer module_cache.deinit(agent.gc_allocator);

    agent.host_hooks.hostGetSupportedImportAttributes = struct {
        fn func(agent_: *Agent) std.mem.Allocator.Error!HostHooks.SupportedImportAttributes {
            var supported_import_attributes: HostHooks.SupportedImportAttributes = .empty;
            try supported_import_attributes.put(agent_.gc_allocator, String.fromLiteral("type"), {});
            return supported_import_attributes;
        }
    }.func;

    agent.host_hooks.hostLoadImportedModule = struct {
        fn func(
            agent_: *Agent,
            referrer: ImportedModuleReferrer,
            module_request: ModuleRequest,
            _: ?*anyopaque,
            payload: ImportedModulePayload,
        ) std.mem.Allocator.Error!void {
            const result = blk: {
                const script_or_module: ScriptOrModule = switch (referrer) {
                    .script => |script| .{ .script = script },
                    .module => |source_text_module| .{
                        .module = .{ .source_text_module = source_text_module },
                    },
                    .realm => unreachable,
                };
                const specifier_utf8 = try module_request.specifier.toUtf8(agent_.gc_allocator);
                defer agent_.gc_allocator.free(specifier_utf8);
                const module_path = resolveModulePath(
                    agent_.gc_allocator,
                    script_or_module,
                    specifier_utf8,
                ) catch |err| break :blk err;
                // NOTE: The spec says that the same (referrer, moduleRequest) pair must resolve to
                // the same cached module, but also that the actual mapping is host-defined.
                // When a module is loaded via dynamic import the referrer is a script, which then
                // doesn't have a cache hit if the module imports itself (referrer is a module) and
                // causes infinite recursion.
                // I haven't checked any of the major engines but at least Boa, LibJS, and QuickJS
                // all use only the module name/path:
                // - https://github.com/boa-dev/boa/blob/fc2a6e09969772feba98eaa89aaf89ca4797e925/core/engine/src/module/loader.rs#L248C5-L248C15
                // - https://github.com/SerenityOS/serenity/blob/648b36f3c53bf3fd83a8dbf5fc788046abe10e29/Userland/Libraries/LibJS/Runtime/VM.cpp#L481-L487
                // - https://github.com/bellard/quickjs/blob/36911f0d3ab1a4c190a4d5cbe7c2db225a455389/quickjs.c#L27590-L27596
                const cache_key: ModuleRequest = .{
                    .specifier = try String.fromUtf8(agent_, module_path),
                    .attributes = module_request.attributes,
                };
                if (module_cache.get(cache_key)) |module| break :blk module;
                if (loadImportedModule(agent_, module_request, module_path)) |module| {
                    try module_cache.putNoClobber(agent_.gc_allocator, cache_key, module);
                    break :blk module;
                } else |err| break :blk err;
            };
            try finishLoadingImportedModule(agent_, referrer, module_request, payload, result);
        }

        const Type = enum {
            json,
            text,

            pub fn fromString(string: *const String) ?Type {
                if (!string.isAscii()) return null;
                return std.StaticStringMap(Type).initComptime(&.{
                    .{ "json", .json },
                    .{ "text", .text },
                }).get(string.asAscii());
            }
        };

        fn loadImportedModule(
            agent_: *Agent,
            module_request: ModuleRequest,
            module_path: []const u8,
        ) Agent.Error!Module {
            const gpa_ = agent_.gpa;
            const io_ = agent_.io;
            const realm = agent_.currentRealm();
            const raw_source_text = readFile(gpa_, io_, module_path) catch |err| {
                return agent_.throwException(
                    .internal_error,
                    "Failed to import '{f}': {t}",
                    .{ module_request.specifier.fmtEscaped(), err },
                );
            };
            defer gpa_.free(raw_source_text);

            const source_text = try gpa_.print("{f}", .{
                std.unicode.fmtUtf8(raw_source_text),
            });
            defer gpa_.free(source_text);

            for (module_request.attributes) |entry| {
                // If moduleRequest.[[Attributes]] has an entry entry such that entry.[[Key]] is
                // "type", then
                if (entry.key.eql(String.fromLiteral("type"))) {
                    // 1. Let type be entry.[[Value]].
                    const @"type" = Type.fromString(entry.value) orelse {
                        return agent_.throwException(
                            .internal_error,
                            "Failed to import '{f}' with unknown module type '{f}'",
                            .{ module_request.specifier.fmtEscaped(), entry.value.fmtEscaped() },
                        );
                    };

                    switch (@"type") {
                        // 2. If type is "json", the host environment must perform
                        //    FinishLoadingImportedModule(referrer, moduleRequest, payload, result),
                        //    where result is either the Completion Record returned by an invocation
                        //    of ParseJSONModule or a throw completion.
                        .json => {
                            const synthetic_module = try parseJSONModule(agent_, source_text);
                            return .{ .synthetic_module = synthetic_module };
                        },

                        // 3. If type is "text", the host environment must perform
                        //    FinishLoadingImportedModule(referrer, moduleRequest, payload, result),
                        //    where result is either the Completion Record returned by an invocation
                        //    of CreateTextModule or a throw completion.
                        .text => {
                            const synthetic_module = try createTextModule(agent_, source_text);
                            return .{ .synthetic_module = synthetic_module };
                        },
                    }
                }
            }

            const host_defined = try agent_.gc_allocator.create(ScriptOrModuleHostDefined);
            host_defined.* = .{ .base_dir = std.Io.Dir.path.dirname(module_path).? };

            var diagnostics: Diagnostics = .init(gpa_, .{
                .source = source_text,
                .file_name = std.Io.Dir.path.basename(module_path),
            });
            defer diagnostics.deinit();

            const source_text_module = SourceTextModule.parse(source_text, realm, host_defined, .{
                .diagnostics = &diagnostics,
            }) catch |err| switch (err) {
                error.OutOfMemory => |e| return e,
                error.ParseError => {
                    const parse_error = diagnostics.first().?;
                    return agent_.throwException(
                        .syntax_error,
                        "{f}",
                        .{parse_error.fmt(&diagnostics)},
                    );
                },
            };
            return .{ .source_text_module = source_text_module };
        }
    }.func;

    agent.host_hooks.hostPromiseRejectionTracker = struct {
        fn func(
            agent_: *Agent,
            promise: *kiesel.builtins.Promise,
            operation: HostHooks.PromiseRejectionTrackerOperation,
        ) void {
            if (tracked_promise_rejections.get(promise)) |previous_operation| {
                // Don't report `Promise.reject().catch(handler)` evaluated in a single script
                if (previous_operation == .reject and operation == .handle) {
                    _ = tracked_promise_rejections.orderedRemove(promise);
                    return;
                }
            }
            tracked_promise_rejections.put(agent_.gc_allocator, promise, operation) catch {};
        }
    }.func;

    var host_defined: RealmHostDefined = .{
        .args = parsed_args.positionals,
        .environ_map = environ_map,
    };

    try Realm.initializeHostDefinedRealm(&agent, .{});
    const realm = agent.currentRealm();
    realm.host_defined = &host_defined;
    try initializeRealm(&agent, realm);

    const cwd = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd);
    std.debug.assert(std.Io.Dir.path.isAbsolute(cwd));

    const debug_print =
        agent.options.debug.print_ast or
        agent.options.debug.print_ir or
        agent.options.debug.print_bytecode;

    if (maybe_path) |path| {
        const raw_source_text = try readFile(gpa, io, path);
        defer gpa.free(raw_source_text);
        // Source is expected to be UTF-8, replace invalid byte sequences with U+FFFD.
        const source_text = try gpa.print("{f}", .{
            std.unicode.fmtUtf8(raw_source_text),
        });
        defer gpa.free(source_text);
        const resolved_path = try std.Io.Dir.path.resolve(gpa, &.{ cwd, path });
        defer gpa.free(resolved_path);
        std.debug.assert(std.Io.Dir.path.isAbsolute(resolved_path));
        const result = run(gpa, realm, source_text, .{
            .base_dir = std.Io.Dir.path.dirname(resolved_path).?,
            .origin = .{ .path = path },
            .module = run_as_module,
            .print_promise_rejection_warnings = parsed_args.options.@"print-promise-rejection-warnings",
        }) catch |err| switch (err) {
            error.AlreadyReported => return 1,
            else => return err,
        };
        if (parsed_args.options.@"print-result") {
            if (debug_print) try stdout.writeByte('\n');
            try stdout.print("{f}\n", .{result.fmtPretty(null)});
            try stdout.flush();
        }
    } else if (parsed_args.options.command) |raw_source_text| {
        std.debug.assert(!run_as_module);
        // Source is expected to be UTF-8, replace invalid byte sequences with U+FFFD.
        const source_text = try gpa.print("{f}", .{
            std.unicode.fmtUtf8(raw_source_text),
        });
        defer gpa.free(source_text);
        const result = run(gpa, realm, source_text, .{
            .base_dir = cwd,
            .origin = .command,
            .module = false,
            .print_promise_rejection_warnings = parsed_args.options.@"print-promise-rejection-warnings",
        }) catch |err| switch (err) {
            error.AlreadyReported => return 1,
            else => return err,
        };
        if (parsed_args.options.@"print-result") {
            if (debug_print) try stdout.writeByte('\n');
            try stdout.print("{f}\n", .{result.fmtPretty(null)});
            try stdout.flush();
        }
    } else {
        std.debug.assert(!run_as_module);
        try repl(gpa, io, environ_map, realm, .{
            .base_dir = cwd,
            .debug = parsed_args.options.debug,
            .print_promise_rejection_warnings = parsed_args.options.@"print-promise-rejection-warnings",
        });
    }
    return 0;
}
