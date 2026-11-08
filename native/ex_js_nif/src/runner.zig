const std = @import("std");
const kiesel = @import("kiesel");

const Agent = kiesel.execution.Agent;
const Platform = Agent.Platform;
const Realm = kiesel.execution.Realm;
const Script = kiesel.language.Script;
const Diagnostics = kiesel.language.Diagnostics;
const PropertyKey = kiesel.types.PropertyKey;
const String = kiesel.types.String;
const Value = kiesel.types.Value;

var stdout_buffer: [8192]u8 = undefined;
var stderr_buffer: [8192]u8 = undefined;
var protocol_buffer: [8192]u8 = undefined;
var platform_stdout: std.Io.Writer = undefined;
var platform_stderr: std.Io.Writer = undefined;

fn checkStackOverflow() bool {
    return false;
}

fn writeResponse(out: *std.Io.Writer, text: []const u8) !void {
    const len: u32 = @intCast(text.len);
    const header = std.mem.toBytes(std.mem.nativeToBig(u32, len));
    try out.writeAll(&header);
    try out.writeAll(text);
}

fn writeError(out: *std.Io.Writer, name: []const u8, message: []const u8) !void {
    var buffer: [8192]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    writer.print("ERR {s} {s}", .{ name, message }) catch {
        return writeResponse(out, "ERR InternalError message too large");
    };
    try writeResponse(out, writer.buffered());
}

fn exceptionNameMessage(agent: *Agent) struct { name: []const u8, message: []const u8 } {
    const exception = agent.exception;

    var name: []const u8 = "Error";
    var message: []const u8 = "";

    if (exception) |ex| {
        if (ex.value.get(agent, PropertyKey.from("name"))) |name_value| {
            if (name_value.toString(agent)) |name_string| {
                if (name_string.toUtf8(agent.gpa)) |utf8| {
                    name = utf8;
                } else |_| {}
            } else |_| {}
        } else |_| {}

        if (ex.value.get(agent, PropertyKey.from("message"))) |message_value| {
            if (message_value.toString(agent)) |message_string| {
                if (message_string.toUtf8(agent.gpa)) |utf8| {
                    message = utf8;
                } else |_| {}
            } else |_| {}
        } else |_| {}
    }

    return .{ .name = name, .message = message };
}

fn writeException(agent: *Agent, out: *std.Io.Writer) !void {
    const info = exceptionNameMessage(agent);
    try writeError(out, info.name, info.message);
}

fn stringify(agent: *Agent, value: Value) Agent.Error!?*const String {
    const global = agent.currentRealm().global_object;
    const json = try global.get(agent, PropertyKey.from("JSON"));
    if (!json.isObject()) return null;

    const stringify_fn = try json.asObject().get(agent, PropertyKey.from("stringify"));
    if (!stringify_fn.isCallable()) return null;

    const result = try stringify_fn.call(agent, json, &.{value});
    if (!result.isString()) return null;
    return result.asString();
}

fn respondEval(
    agent: *Agent,
    realm: *Realm,
    source: []const u8,
    out: *std.Io.Writer,
) !void {
    var diagnostics = Diagnostics.init(agent.gpa, .{
        .source = source,
        .file_name = "isolated",
    });
    defer diagnostics.deinit();

    const script = Script.parse(source, realm, null, .{
        .diagnostics = &diagnostics,
    }) catch |err| switch (err) {
        error.OutOfMemory => return writeResponse(out, "ERR InternalError out of memory"),
        error.ParseError => {
            const parse_error = diagnostics.first() orelse {
                return writeError(out, "SyntaxError", "failed to parse script");
            };
            const message = agent.gpa.print("{f}", .{parse_error.fmt(&diagnostics)}) catch {
                return writeError(out, "SyntaxError", "failed to parse script");
            };
            defer agent.gpa.free(message);
            return writeError(out, "SyntaxError", message);
        },
    };

    const result = script.evaluate("isolated") catch |err| switch (err) {
        error.OutOfMemory => return writeResponse(out, "ERR InternalError out of memory"),
        error.ExceptionThrown => return writeException(agent, out),
    };

    const json = stringify(agent, result) catch |err| switch (err) {
        error.OutOfMemory => return writeResponse(out, "ERR InternalError out of memory"),
        error.ExceptionThrown => return writeException(agent, out),
    };

    if (json) |string| {
        const utf8 = string.toUtf8(agent.gc_allocator) catch {
            return writeResponse(out, "ERR InternalError out of memory");
        };
        var buffer = std.Io.Writer.Allocating.init(agent.gpa);
        defer buffer.deinit();
        buffer.writer.print("OK {s}", .{utf8}) catch {
            return writeResponse(out, "ERR InternalError out of memory");
        };
        try writeResponse(out, buffer.written());
    } else {
        try writeResponse(out, "OK null");
    }
}

pub fn main() !u8 {
    const io = std.Io.Threaded.global_single_threaded.io();
    const gpa = std.heap.page_allocator;

    kiesel.gc.init();
    kiesel.gc.disableWarnings();

    platform_stdout = std.Io.Writer.fixed(&stdout_buffer);
    platform_stderr = std.Io.Writer.fixed(&stderr_buffer);

    var platform: Platform = .{
        .gc_allocator = kiesel.gc.allocator,
        .gc_allocator_atomic = kiesel.gc.allocator_atomic,
        .stdout = &platform_stdout,
        .stderr = &platform_stderr,
        .terminal_mode = .no_color,
        .default_locale = {},
        .default_time_zone = {},
        .checkStackOverflow = &checkStackOverflow,
    };

    var agent = try Agent.init(gpa, io, &platform, .{});
    defer agent.deinit();

    try Realm.initializeHostDefinedRealm(&agent, .{});
    const realm = agent.currentRealm();

    var stdin_buffer: [4096]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(io, &stdin_buffer);
    const stdin = &stdin_reader.interface;

    var stdout_writer = std.Io.File.stdout().writer(io, &protocol_buffer);
    const out = &stdout_writer.interface;

    while (true) {
        const header = stdin.take(4) catch break;
        const len = std.mem.bigToNative(u32, std.mem.bytesToValue(u32, header));
        if (len == 0 or len > 16 * 1024 * 1024) break;

        const payload = stdin.readAllocAll(gpa, len) catch break;
        defer gpa.free(payload);
        if (payload.len == 0) break;

        switch (payload[0]) {
            'C' => {
                kiesel.gc.collect();
                try writeResponse(out, "OK null");
            },
            'E' => try respondEval(&agent, realm, payload[1..], out),
            else => try writeError(out, "ProtocolError", "invalid request"),
        }

        out.flush() catch break;
    }

    return 0;
}
