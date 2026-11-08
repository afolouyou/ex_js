const std = @import("std");

pub const c = @import("c");

const Opaque = struct {
    gpa: std.mem.Allocator,
};

export fn lre_check_stack_overflow(_: ?*anyopaque, _: usize) c_int {
    // TODO: Implement stack overflow check
    return 0;
}

export fn lre_check_timeout(_: ?*anyopaque) c_int {
    // This can be used to implement RegExp aborts e.g. on SIGINT.
    return 0;
}

export fn lre_realloc(opaque_ptr: ?*anyopaque, maybe_ptr: ?*anyopaque, size: usize) ?*anyopaque {
    // This doesn't provide the old allocation size needed when forwarding to the Zig allocator,
    // so we allocate extra space to store the size before the usable allocation.
    const @"opaque" = @as(*Opaque, @ptrCast(@alignCast(opaque_ptr.?)));
    const gpa = @"opaque".gpa;
    if (maybe_ptr) |ptr| {
        const header_ptr = @as([*]align(@alignOf(usize)) u8, @ptrCast(@alignCast(ptr))) - @sizeOf(usize);
        const old_size = @as(*usize, @ptrCast(header_ptr)).*;
        const old_total_size = old_size + @sizeOf(usize);
        const old_mem: []align(@alignOf(usize)) u8 = header_ptr[0..old_total_size];
        if (size == 0) {
            gpa.free(old_mem);
            return null;
        }
        const new_total_size = size + @sizeOf(usize);
        const new_mem = gpa.realloc(old_mem, new_total_size) catch return null;
        @as(*usize, @ptrCast(new_mem.ptr)).* = size;
        return new_mem.ptr + @sizeOf(usize);
    } else {
        const total_size = size + @sizeOf(usize);
        const mem = gpa.alignedAlloc(u8, .of(usize), total_size) catch return null;
        @as(*usize, @ptrCast(mem.ptr)).* = size;
        return mem.ptr + @sizeOf(usize);
    }
}

pub const Flag = enum {
    global,
    ignorecase,
    multiline,
    dotall,
    unicode,
    sticky,
    indices,
    unicode_sets,
};

// TODO: Change to u9 once https://codeberg.org/ziglang/zig/issues/37127 is fixed
pub const Flags = packed struct(u16) {
    global: bool,
    ignorecase: bool,
    multiline: bool,
    dotall: bool,
    unicode: bool,
    sticky: bool,
    indices: bool,
    named_groups: bool,
    unicode_sets: bool,
    _: u7,

    pub const empty: Flags = .{
        .global = false,
        .ignorecase = false,
        .multiline = false,
        .dotall = false,
        .unicode = false,
        .sticky = false,
        .indices = false,
        .named_groups = false,
        .unicode_sets = false,
        ._ = 0,
    };

    pub fn parse(str: []const u8) ?Flags {
        var flags = empty;
        for (str) |char| switch (char) {
            'd' => {
                if (flags.indices) return null;
                flags.indices = true;
            },
            'g' => {
                if (flags.global) return null;
                flags.global = true;
            },
            'i' => {
                if (flags.ignorecase) return null;
                flags.ignorecase = true;
            },
            'm' => {
                if (flags.multiline) return null;
                flags.multiline = true;
            },
            's' => {
                if (flags.dotall) return null;
                flags.dotall = true;
            },
            'u' => {
                if (flags.unicode) return null;
                flags.unicode = true;
            },
            'v' => {
                if (flags.unicode_sets) return null;
                flags.unicode_sets = true;
            },
            'y' => {
                if (flags.sticky) return null;
                flags.sticky = true;
            },
            else => return null,
        };
        if (flags.unicode and flags.unicode_sets) return null;
        return flags;
    }

    pub fn isSet(flags: Flags, flag: Flag) bool {
        return switch (flag) {
            inline else => |tag| @field(flags, @tagName(tag)),
        };
    }
};

// TODO: Use https://codeberg.org/ziglang/zig/pulls/31250 once/if it lands
comptime {
    for (@typeInfo(Flags).@"struct".field_names, 0..) |name, i| {
        if (std.mem.eql(u8, name, "_")) continue;
        var buf: [name.len]u8 = undefined;
        const lre_flag_name = "LRE_FLAG_" ++ std.ascii.upperString(&buf, name);
        std.debug.assert((1 << i) == @field(c, lre_flag_name));
    }
}

pub const GroupNamesIterator = struct {
    ptr: ?[*:0]const u8,

    pub fn next(it: *GroupNamesIterator) ?[]const u8 {
        const ptr = it.ptr orelse return null;
        const name = std.mem.span(ptr);
        it.ptr = ptr + name.len + c.LRE_GROUP_NAME_TRAILER_LEN;
        return if (name.len == 0) null else name;
    }
};

pub const Bytecode = struct {
    raw: [*]const u8,

    pub fn flags(bc: Bytecode) Flags {
        return @fromBackingInt(@intCast(c.lre_get_flags(bc.raw)));
    }

    pub fn allocCount(bc: Bytecode) u32 {
        return @intCast(c.lre_get_alloc_count(bc.raw));
    }

    pub fn captureCount(bc: Bytecode) u32 {
        return @intCast(c.lre_get_capture_count(bc.raw));
    }

    pub fn groupNames(bc: Bytecode) GroupNamesIterator {
        return .{ .ptr = c.lre_get_groupnames(bc.raw) };
    }
};

pub const CodeUnitIndex = enum(u32) { _ };

/// 22.2.7.5 Match Records
/// https://tc39.es/ecma262/#sec-match-records
pub const Match = struct {
    /// [[StartIndex]]
    start_index: CodeUnitIndex,

    /// [[EndIndex]]
    end_index: CodeUnitIndex,
};

pub const CompileError = std.mem.Allocator.Error || error{LreError};

pub fn compile(
    gpa: std.mem.Allocator,
    pattern: [:0]const u8,
    flags: Flags,
    error_msg: *[]const u8,
) CompileError!Bytecode {
    var bytecode_len: c_int = undefined;
    var error_msg_buf: [64]u8 = undefined;
    var @"opaque": Opaque = .{ .gpa = gpa };
    const bytecode = c.lre_compile(
        &bytecode_len,
        &error_msg_buf,
        error_msg_buf.len,
        pattern.ptr,
        pattern.len,
        @backingInt(flags),
        &@"opaque",
    ) orelse {
        const str = std.mem.span(@as([*:0]const u8, @ptrCast(&error_msg_buf)));
        if (std.mem.eql(u8, str, "out of memory")) return error.OutOfMemory;
        error_msg.* = try gpa.dupe(u8, str);
        return error.LreError;
    };
    return .{ .raw = bytecode };
}

pub const ExecSubject = union(enum) {
    ascii: []const u8,
    utf16: []const u16,
};

pub const ExecError = std.mem.Allocator.Error || error{Timeout};

pub fn exec(
    gpa: std.mem.Allocator,
    bytecode: Bytecode,
    subject: ExecSubject,
    last_index: CodeUnitIndex,
) ExecError!?[]?Match {
    const captures_raw = try gpa.alloc(?*u8, bytecode.allocCount());
    defer gpa.free(captures_raw);

    var @"opaque": Opaque = .{ .gpa = gpa };
    const ret = c.lre_exec(
        @ptrCast(captures_raw),
        bytecode.raw,
        switch (subject) {
            .ascii => |ascii| @ptrCast(ascii),
            .utf16 => |utf16| @ptrCast(utf16),
        },
        @intCast(@backingInt(last_index)),
        switch (subject) {
            .ascii => |ascii| @intCast(ascii.len),
            .utf16 => |utf16| @intCast(utf16.len),
        },
        // 0 = 8 bit chars, 1 = 16 bit chars, 2 = 16 bit chars, UTF-16 (set internally via the u flag)
        switch (subject) {
            .ascii => 0,
            .utf16 => 1,
        },
        &@"opaque",
    );
    if (ret < 0) switch (ret) {
        c.LRE_RET_MEMORY_ERROR => return error.OutOfMemory,
        c.LRE_RET_TIMEOUT => return error.Timeout,
        else => unreachable,
    };
    if (ret == 0) return null;

    const shift = @intFromBool(subject == .utf16);
    const subject_start: [*]const u8 = switch (subject) {
        .ascii => |ascii| ascii.ptr,
        .utf16 => |utf16| @ptrCast(utf16.ptr),
    };

    const captures = try gpa.alloc(?Match, bytecode.captureCount());
    for (captures, 0..) |*match, i| {
        const capture = captures_raw[2 * i ..][0..2];
        if (capture[0] == null or capture[1] == null) {
            match.* = null;
            continue;
        }
        const start_index = (@intFromPtr(capture[0]) - @intFromPtr(subject_start)) >> shift;
        const end_index = (@intFromPtr(capture[1]) - @intFromPtr(subject_start)) >> shift;
        match.* = .{
            .start_index = @fromBackingInt(@intCast(start_index)),
            .end_index = @fromBackingInt(@intCast(end_index)),
        };
    }
    return captures;
}
