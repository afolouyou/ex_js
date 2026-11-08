//! 6.1.4 The String Type
//! https://tc39.es/ecma262/#sec-ecmascript-language-types-string-type

const std = @import("std");

const execution = @import("../../execution.zig");
const language = @import("../../language.zig");

const Agent = execution.Agent;
const Tokenizer = language.Tokenizer;

fn utf8IsAscii(utf8: []const u8) bool {
    var remaining = utf8;
    if (std.simd.suggestVectorLength(u8)) |chunk_len| {
        const Chunk = @Vector(chunk_len, u8);
        while (remaining.len >= chunk_len) {
            const chunk: Chunk = remaining[0..chunk_len].*;
            const mask: Chunk = @splat(0x80);
            if (@reduce(.Or, chunk & mask == mask)) return false;
            remaining = remaining[chunk_len..];
        }
    }
    for (remaining) |c| {
        if (c > 0x7F) return false;
    }
    return true;
}

fn utf16IsAscii(utf16: []const u16) bool {
    var remaining = utf16;
    if (std.simd.suggestVectorLength(u16)) |chunk_len| {
        const Chunk = @Vector(chunk_len, u16);
        while (remaining.len >= chunk_len) {
            const chunk: Chunk = remaining[0..chunk_len].*;
            const mask: Chunk = @splat(std.mem.nativeToLittle(u16, 0x7F));
            if (@reduce(.Or, chunk | mask != mask)) return false;
            remaining = remaining[chunk_len..];
        }
    }
    for (remaining) |c| {
        if (c > 0x7F) return false;
    }
    return true;
}

const String = @This();

/// https://tc39.es/ecma262/#ASCII-word-characters
pub const ascii_word_characters = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_";

/// The definition of white space is the union of WhiteSpace and LineTerminator.
pub const whitespace_code_points = blk: {
    const single_byte = Tokenizer.single_byte_whitespace ++ Tokenizer.single_byte_line_terminators;
    const multi_byte = Tokenizer.multi_byte_whitespace ++ Tokenizer.multi_byte_line_terminators;
    var code_points: [single_byte.len + multi_byte.len]u21 = undefined;
    var i: usize = 0;
    for (single_byte) |c| {
        code_points[i] = c;
        i += 1;
    }
    for (multi_byte) |utf8| {
        code_points[i] = std.unicode.utf8Decode(utf8) catch unreachable;
        i += 1;
    }
    break :blk code_points;
};

const whitespace_ascii = blk: {
    var len = 0;
    for (whitespace_code_points) |code_point| {
        if (code_point <= 0x7F) len += 1;
    }
    var code_units: [len]u8 = undefined;
    var i: usize = 0;
    for (whitespace_code_points) |code_point| {
        if (code_point <= 0x7F) {
            code_units[i] = @intCast(code_point);
            i += 1;
        }
    }
    break :blk code_units;
};

const whitespace_utf16 = blk: {
    // All whitespace code points are encoded with a single UTF-16 code unit
    const len = whitespace_code_points.len;
    var code_units: [len]u16 = undefined;
    for (whitespace_code_points, 0..) |code_point, i| {
        code_units[i] = @intCast(code_point);
    }
    break :blk code_units;
};

const single_code_unit_strings = blk: {
    @setEvalBranchQuota(100_000);
    var strings: [256]*const String = undefined;
    for (0..256) |i| {
        const utf8: []const u8 = &std.unicode.utf8EncodeComptime(@intCast(i));
        strings[i] = fromLiteral(utf8);
    }
    break :blk strings;
};

pub const empty = fromLiteral("");

pub const Builder = @import("String/Builder.zig");
pub const Cache = @import("String/Cache.zig");
pub const CodeUnitIterator = @import("String/CodeUnitIterator.zig");

data: Data,
length: u32,
hash: u64,

const Data = union(enum) {
    empty,
    owned_ascii: [*]const u8,
    owned_utf16: [*]const u16,
    static_ascii: [*]const u8,
    static_utf16: [*]const u16,
    slice_ascii: Slice,
    slice_utf16: Slice,
};

const Slice = struct {
    string: *const String,
    start: u32,
};

pub fn format(self: *const String, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.print("\"{f}\"", .{self.fmtEscaped()});
}

pub fn formatRaw(self: *const String, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    switch (self.asAsciiOrUtf16()) {
        .ascii => |ascii| try writer.print("{s}", .{ascii}),
        .utf16 => |utf16| try writer.print("{f}", .{std.unicode.fmtUtf16Le(utf16)}),
    }
}

pub fn fmtRaw(self: *const String) std.fmt.Alt(*const String, formatRaw) {
    return .{ .data = self };
}

pub fn formatEscaped(self: *const String, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    var it = self.codeUnitIterator();
    while (it.next()) |code_unit| {
        const code_point = if (std.unicode.utf16IsHighSurrogate(code_unit)) blk: {
            const code_unit_low = it.next() orelse {
                try writer.print("\\u{x:0>4}", .{code_unit});
                break;
            };
            break :blk std.unicode.utf16DecodeSurrogatePair(&.{ code_unit, code_unit_low }) catch {
                try writer.print("\\u{x:0>4}\\u{x:0>4}", .{ code_unit, code_unit_low });
                continue;
            };
        } else if (std.unicode.utf16IsLowSurrogate(code_unit)) {
            try writer.print("\\u{x:0>4}", .{code_unit});
            continue;
        } else code_unit;
        switch (code_point) {
            // Control characters excluding those handled below
            0x00...0x07, 0x0E...0x1F, 0x7F => try writer.print("\\x{x:0>2}", .{code_point}),
            0x08 => try writer.writeAll("\\b"),
            0x09 => try writer.writeAll("\\t"),
            0x0A => try writer.writeAll("\\n"),
            0x0B => try writer.writeAll("\\v"),
            0x0C => try writer.writeAll("\\f"),
            0x0D => try writer.writeAll("\\r"),
            '\\' => try writer.writeAll("\\\\"),
            else => {
                var buf: [4]u8 = undefined;
                // Unpaired surrogates are handled above, out-of-range code points are not possible
                const len = std.unicode.utf8Encode(code_point, &buf) catch unreachable;
                try writer.writeAll(buf[0..len]);
            },
        }
    }
}

pub fn fmtEscaped(self: *const String) std.fmt.Alt(*const String, formatEscaped) {
    return .{ .data = self };
}

pub inline fn fromLiteral(comptime utf8: []const u8) *const String {
    @setEvalBranchQuota(10_000);
    if (utf8.len == 0) {
        return &.{ .data = .empty, .length = 0, .hash = 0 };
    }
    comptime {
        if (utf8IsAscii(utf8)) {
            const ascii = utf8;
            return &.{
                .data = .{ .static_ascii = ascii.ptr },
                .length = @intCast(ascii.len),
                .hash = std.hash.Wyhash.hash(0, ascii),
            };
        } else {
            const utf16 = std.unicode.utf8ToUtf16LeStringLiteral(utf8);
            return &.{
                .data = .{ .static_utf16 = utf16.ptr },
                .length = @intCast(utf16.len),
                .hash = std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(utf16)),
            };
        }
    }
}

pub fn fromUtf8(agent: *Agent, utf8: []const u8) std.mem.Allocator.Error!*const String {
    std.debug.assert(utf8.len <= std.math.maxInt(u32));
    if (utf8.len == 0) return empty;
    const result = try agent.string_cache.getOrPut(agent, .{ .utf8 = utf8 });
    if (!result.found_existing) {
        if (utf8IsAscii(utf8)) {
            const ascii = utf8;
            result.string.* = .{
                .data = .{ .owned_ascii = ascii.ptr },
                .length = @intCast(ascii.len),
                .hash = std.hash.Wyhash.hash(0, ascii),
            };
        } else {
            const utf16 = std.unicode.utf8ToUtf16LeAlloc(agent.gc_allocator, utf8) catch |err| switch (err) {
                error.InvalidUtf8 => @panic("Invalid UTF-8"),
                error.OutOfMemory => |e| return e,
            };
            result.string.* = .{
                .data = .{ .owned_utf16 = utf16.ptr },
                .length = @intCast(utf16.len),
                .hash = std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(utf16)),
            };
        }
    }
    return result.string;
}

// The parser, AST, and parts of codegen need to create strings from UTF-8 slices but do not
// currently have access to the agent, so we skip caching them. This can be revisited later.
pub fn fromUtf8Alloc(allocator: std.mem.Allocator, utf8: []const u8) std.mem.Allocator.Error!*const String {
    std.debug.assert(utf8.len <= std.math.maxInt(u32));
    if (utf8.len == 0) return empty;
    if (utf8IsAscii(utf8)) {
        return fromAsciiAlloc(allocator, utf8);
    } else {
        const utf16 = std.unicode.utf8ToUtf16LeAlloc(allocator, utf8) catch |err| switch (err) {
            error.InvalidUtf8 => @panic("Invalid UTF-8"),
            error.OutOfMemory => |e| return e,
        };
        errdefer allocator.free(utf16);
        return fromUtf16Alloc(allocator, utf16);
    }
}

pub fn fromWtf8(agent: *Agent, wtf8: []const u8) std.mem.Allocator.Error!*const String {
    std.debug.assert(wtf8.len <= std.math.maxInt(u32));
    if (wtf8.len == 0) return empty;
    const result = try agent.string_cache.getOrPut(agent, .{ .utf8 = wtf8 });
    if (!result.found_existing) {
        if (utf8IsAscii(wtf8)) {
            const ascii = wtf8;
            result.string.* = .{
                .data = .{ .owned_ascii = ascii.ptr },
                .length = @intCast(ascii.len),
                .hash = std.hash.Wyhash.hash(0, ascii),
            };
        } else {
            const utf16 = try wtf8ToUtf16LeAlloc(agent.gc_allocator, wtf8);
            result.string.* = .{
                .data = .{ .owned_utf16 = utf16.ptr },
                .length = @intCast(utf16.len),
                .hash = std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(utf16)),
            };
        }
    }
    return result.string;
}

pub fn fromWtf8Alloc(allocator: std.mem.Allocator, wtf8: []const u8) std.mem.Allocator.Error!*const String {
    std.debug.assert(wtf8.len <= std.math.maxInt(u32));
    if (wtf8.len == 0) return empty;
    if (utf8IsAscii(wtf8)) {
        return fromAsciiAlloc(allocator, wtf8);
    } else {
        // FIXME: Align ownership semantics with `fromUtf8Alloc()`
        defer allocator.free(wtf8);
        const utf16 = try wtf8ToUtf16LeAlloc(allocator, wtf8);
        errdefer allocator.free(utf16);
        return fromUtf16Alloc(allocator, utf16);
    }
}

fn wtf8ToUtf16LeAlloc(allocator: std.mem.Allocator, wtf8: []const u8) std.mem.Allocator.Error![]u16 {
    var result: std.ArrayList(u16) = try .initCapacity(allocator, @intCast(wtf8.len));
    var i: usize = 0;
    while (i < wtf8.len) {
        const len = std.unicode.utf8ByteSequenceLength(wtf8[i]) catch unreachable;
        const code_point = std.unicode.wtf8Decode(wtf8[i..][0..len]) catch unreachable;
        if (code_point < 0x10000) {
            result.appendAssumeCapacity(@intCast(code_point));
        } else {
            result.appendAssumeCapacity(@intCast(0xd800 | ((code_point - 0x10000) >> 10)));
            result.appendAssumeCapacity(@intCast(0xdc00 | ((code_point - 0x10000) & 0x3ff)));
        }
        i += len;
    }
    return result.toOwnedSlice(allocator);
}

pub fn fromAscii(agent: *Agent, ascii: []const u8) std.mem.Allocator.Error!*const String {
    std.debug.assert(ascii.len <= std.math.maxInt(u32));
    if (ascii.len == 0) return empty;
    const result = try agent.string_cache.getOrPut(agent, .{ .utf8 = ascii });
    if (!result.found_existing) {
        result.string.* = .{
            .data = .{ .owned_ascii = ascii.ptr },
            .length = @intCast(ascii.len),
            .hash = std.hash.Wyhash.hash(0, ascii),
        };
    }
    return result.string;
}

pub fn fromAsciiAlloc(allocator: std.mem.Allocator, ascii: []const u8) std.mem.Allocator.Error!*const String {
    std.debug.assert(ascii.len <= std.math.maxInt(u32));
    if (ascii.len == 0) return empty;
    const string = try allocator.create(String);
    string.* = .{
        .data = .{ .owned_ascii = ascii.ptr },
        .length = @intCast(ascii.len),
        .hash = std.hash.Wyhash.hash(0, ascii),
    };
    return string;
}

pub fn fromUtf16(agent: *Agent, utf16: []const u16) std.mem.Allocator.Error!*const String {
    std.debug.assert(utf16.len <= std.math.maxInt(u32));
    if (utf16.len == 0) return empty;
    std.debug.assert(!utf16IsAscii(utf16));
    const result = try agent.string_cache.getOrPut(agent, .{ .utf16 = utf16 });
    if (!result.found_existing) {
        result.string.* = .{
            .data = .{ .owned_utf16 = utf16.ptr },
            .length = @intCast(utf16.len),
            .hash = std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(utf16)),
        };
    }
    return result.string;
}

pub fn fromUtf16Alloc(allocator: std.mem.Allocator, utf16: []const u16) std.mem.Allocator.Error!*const String {
    std.debug.assert(utf16.len <= std.math.maxInt(u32));
    if (utf16.len == 0) return empty;
    std.debug.assert(!utf16IsAscii(utf16));
    const string = try allocator.create(String);
    string.* = .{
        .data = .{ .owned_utf16 = utf16.ptr },
        .length = @intCast(utf16.len),
        .hash = std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(utf16)),
    };
    return string;
}

pub fn fromStringSliced(agent: *Agent, string: *const String, inclusive_start: u32, exclusive_end: u32) std.mem.Allocator.Error!*const String {
    std.debug.assert(inclusive_start <= exclusive_end and exclusive_end <= string.length);
    // TODO: It probably makes sense to have a minimum length for slices. For example string
    // indexing should not keep the entire original string alive for a single character slice.
    // This can be solved when we have inline string storage.
    const length = exclusive_end - inclusive_start;
    if (length == 0) return empty;
    if (length == string.length) return string;
    if (string.isUtf16()) {
        std.debug.assert(!utf16IsAscii(string.asUtf16()[inclusive_start..exclusive_end]));
    }
    const result = try agent.string_cache.getOrPut(agent, switch (string.asAsciiOrUtf16()) {
        .ascii => |ascii| .{ .utf8 = ascii[inclusive_start..exclusive_end] },
        .utf16 => |utf16| .{ .utf16 = utf16[inclusive_start..exclusive_end] },
    });
    if (!result.found_existing) {
        const slice_string, const start = switch (string.data) {
            .empty => unreachable,
            // Avoid nested slices
            .slice_ascii, .slice_utf16 => |slice| .{ slice.string, slice.start + inclusive_start },
            else => .{ string, inclusive_start },
        };
        result.string.* = switch (string.asAsciiOrUtf16()) {
            .ascii => |ascii| .{
                .data = .{ .slice_ascii = .{ .string = slice_string, .start = start } },
                .length = length,
                .hash = std.hash.Wyhash.hash(0, ascii[inclusive_start..exclusive_end]),
            },
            .utf16 => |utf16| .{
                .data = .{ .slice_utf16 = .{ .string = slice_string, .start = start } },
                .length = length,
                .hash = std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(utf16[inclusive_start..exclusive_end])),
            },
        };
    }
    return result.string;
}

pub fn isEmpty(self: *const String) bool {
    return self.length == 0;
}

pub fn isAscii(self: *const String) bool {
    return switch (self.data) {
        .empty, .owned_ascii, .static_ascii, .slice_ascii => true,
        else => false,
    };
}

pub fn isUtf16(self: *const String) bool {
    return switch (self.data) {
        .owned_utf16, .static_utf16, .slice_utf16 => true,
        else => false,
    };
}

pub fn asAscii(self: *const String) []const u8 {
    return switch (self.data) {
        .empty => &.{},
        .owned_ascii, .static_ascii => |ascii| ascii[0..self.length],
        .slice_ascii => |slice| switch (slice.string.data) {
            .owned_ascii, .static_ascii => |ascii| ascii[slice.start..][0..self.length],
            .empty, .owned_utf16, .static_utf16, .slice_ascii, .slice_utf16 => unreachable,
        },
        .owned_utf16, .static_utf16, .slice_utf16 => unreachable,
    };
}

pub fn asUtf16(self: *const String) []const u16 {
    return switch (self.data) {
        .empty, .owned_ascii, .static_ascii, .slice_ascii => unreachable,
        .owned_utf16, .static_utf16 => |utf16| utf16[0..self.length],
        .slice_utf16 => |slice| switch (slice.string.data) {
            .owned_utf16, .static_utf16 => |utf16| utf16[slice.start..][0..self.length],
            .empty, .owned_ascii, .static_ascii, .slice_ascii, .slice_utf16 => unreachable,
        },
    };
}

pub const AsciiOrUtf16 = union(enum) {
    ascii: []const u8,
    utf16: []const u16,
};

pub fn asAsciiOrUtf16(self: *const String) AsciiOrUtf16 {
    return switch (self.data) {
        .empty => .{ .ascii = &.{} },
        .owned_ascii, .static_ascii => |ascii| .{ .ascii = ascii[0..self.length] },
        .owned_utf16, .static_utf16 => |utf16| .{ .utf16 = utf16[0..self.length] },
        .slice_ascii => |slice| switch (slice.string.data) {
            .owned_ascii, .static_ascii => |ascii| .{ .ascii = ascii[slice.start..][0..self.length] },
            .empty, .owned_utf16, .static_utf16, .slice_ascii, .slice_utf16 => unreachable,
        },
        .slice_utf16 => |slice| switch (slice.string.data) {
            .owned_utf16, .static_utf16 => |utf16| .{ .utf16 = utf16[slice.start..][0..self.length] },
            .empty, .owned_ascii, .static_ascii, .slice_ascii, .slice_utf16 => unreachable,
        },
    };
}

pub fn toUtf8(self: *const String, allocator: std.mem.Allocator) std.mem.Allocator.Error![]u8 {
    return switch (self.asAsciiOrUtf16()) {
        .ascii => |ascii| allocator.dupe(u8, ascii),
        .utf16 => |utf16| allocator.print("{f}", .{std.unicode.fmtUtf16Le(utf16)}),
    };
}

pub fn toWtf8(self: *const String, allocator: std.mem.Allocator) std.mem.Allocator.Error![]u8 {
    return switch (self.asAsciiOrUtf16()) {
        .ascii => |ascii| allocator.dupe(u8, ascii),
        .utf16 => |utf16| std.unicode.wtf16LeToWtf8Alloc(allocator, utf16),
    };
}

pub fn toUtf16(self: *const String, allocator: std.mem.Allocator) std.mem.Allocator.Error![]u16 {
    return switch (self.asAsciiOrUtf16()) {
        .ascii => |ascii| blk: {
            const utf16 = try allocator.alloc(u16, self.length);
            for (ascii, 0..) |c, i| utf16[i] = c;
            break :blk utf16;
        },
        .utf16 => |utf16| allocator.dupe(u16, utf16),
    };
}

pub fn codeUnitIterator(self: *const String) CodeUnitIterator {
    return .{ .index = 0, .string = self };
}

pub fn eql(self: *const String, other: *const String) bool {
    if (self == other) return true;
    if (self.hash != other.hash) return false;
    if (self.isAscii() and other.isAscii()) {
        return std.mem.eql(u8, self.asAscii(), other.asAscii());
    }
    if (self.isUtf16() and other.isUtf16()) {
        return std.mem.eql(u16, self.asUtf16(), other.asUtf16());
    }
    // We currently maintain the invariant that strings are stored in their ideal encoding, so we
    // can skip doing code unit comparions here.
    return false;
}

pub fn startsWith(self: *const String, other: *const String) bool {
    if (self.isAscii() and other.isAscii()) {
        return std.mem.startsWith(u8, self.asAscii(), other.asAscii());
    }
    if (self.isUtf16() and other.isUtf16()) {
        return std.mem.startsWith(u16, self.asUtf16(), other.asUtf16());
    }
    if (other.isEmpty()) return true;
    if (self.length < other.length) return false;
    var it1 = self.codeUnitIterator();
    var it2 = other.codeUnitIterator();
    for (0..other.length) |_| {
        const c1 = it1.next().?;
        const c2 = it2.next().?;
        if (c1 != c2) return false;
    }
    return true;
}

/// https://tc39.es/ecma262/#substring
pub fn substring(
    self: *const String,
    agent: *Agent,
    inclusive_start: u32,
    maybe_exclusive_end: ?u32,
) std.mem.Allocator.Error!*const String {
    const exclusive_end = maybe_exclusive_end orelse self.length;
    if (inclusive_start == 0 and exclusive_end == self.length) {
        return self;
    }
    if (self.isEmpty() or
        inclusive_start == self.length or
        exclusive_end == 0 or
        inclusive_start == exclusive_end)
    {
        return empty;
    }
    if (exclusive_end - inclusive_start == 1) {
        const code_unit = self.codeUnitAt(inclusive_start);
        if (code_unit < single_code_unit_strings.len) {
            return single_code_unit_strings[code_unit];
        }
    }
    switch (self.asAsciiOrUtf16()) {
        .ascii => {
            return fromStringSliced(agent, self, inclusive_start, exclusive_end);
        },
        .utf16 => |utf16| {
            // We currently maintain the invariant that strings are stored in their ideal encoding,
            // so if slicing changes the string to ASCII-only we have to allocate.
            const utf16_substring = utf16[inclusive_start..exclusive_end];
            if (utf16IsAscii(utf16_substring)) {
                const ascii = try agent.gc_allocator.alloc(u8, utf16_substring.len);
                for (utf16_substring, 0..) |code_unit, i| {
                    ascii[i] = @intCast(code_unit);
                }
                return fromAscii(agent, ascii);
            } else {
                return fromStringSliced(agent, self, inclusive_start, exclusive_end);
            }
        },
    }
}

/// 6.1.4.1 StringIndexOf ( string, searchValue, fromIndex )
/// https://tc39.es/ecma262/#sec-stringindexof
pub fn indexOf(self: *const String, search_value: *const String, from_index: u32) ?u32 {
    // 1. Let length be the length of string.
    const length = self.length;
    const search_length = search_value.length;

    // 2. If searchValue is the empty String and fromIndex ≤ length, return fromIndex.
    if (search_value.isEmpty() and from_index <= length) return from_index;

    // 3. Let searchLength be the length of searchValue.
    // 4. For each integer i such that fromIndex ≤ i ≤ length - searchLength, in ascending order, do
    //     a. Let candidate be the substring of string from i to i + searchLength.
    //     b. If candidate is searchValue, return i.
    // 5. Return not-found.
    if (from_index >= length or search_length > length) return null;
    if (self.isAscii() and search_value.isAscii()) {
        return if (std.mem.find(
            u8,
            self.asAscii()[from_index..],
            search_value.asAscii(),
        )) |index|
            @as(u32, @intCast(index)) + from_index
        else
            null;
    }
    if (self.isUtf16() and search_value.isUtf16()) {
        return if (std.mem.find(
            u16,
            self.asUtf16()[from_index..],
            search_value.asUtf16(),
        )) |index|
            @as(u32, @intCast(index)) + from_index
        else
            null;
    }
    var i: u32 = from_index;
    const end = length - search_length;
    outer: while (i <= end) : (i += 1) {
        for (0..search_length) |n| {
            if (self.codeUnitAt(i + @as(u32, @intCast(n))) != search_value.codeUnitAt(@intCast(n))) continue :outer;
        }
        return i;
    }
    return null;
}

/// 6.1.4.2 StringLastIndexOf ( string, searchValue, fromIndex )
/// https://tc39.es/ecma262/#sec-stringlastindexof
pub fn lastIndexOf(self: *const String, search_value: *const String, from_index: u32) ?u32 {
    // 1. Let length be the length of string.
    const length = self.length;

    // 2. Let searchLength be the length of searchValue.
    const search_length = search_value.length;

    // 3. Assert: fromIndex + searchLength ≤ length.
    // 4. For each integer i such that 0 ≤ i ≤ fromIndex, in descending order, do
    //     a. Let candidate be the substring of string from i to i + searchLength.
    //     b. If candidate is searchValue, return i.
    // 5. Return not-found.
    if (search_value.isEmpty() and from_index <= length) return from_index;
    if (from_index >= length or search_length > length) return null;
    if (self.isAscii() and search_value.isAscii()) {
        const end = std.math.clamp(from_index + search_length, 0, length);
        return if (std.mem.findLast(
            u8,
            self.asAscii()[0..end],
            search_value.asAscii(),
        )) |index|
            @as(u32, @intCast(index))
        else
            null;
    }
    if (self.isUtf16() and search_value.isUtf16()) {
        const end = std.math.clamp(from_index + search_length, 0, length);
        return if (std.mem.findLast(
            u16,
            self.asUtf16()[0..end],
            search_value.asUtf16(),
        )) |index|
            @as(u32, @intCast(index))
        else
            null;
    }
    var i = std.math.sub(u32, length - search_length, from_index) catch return null;
    outer: while (true) : (i -= 1) {
        for (0..search_length) |n| {
            if (self.codeUnitAt(i + @as(u32, @intCast(n))) != search_value.codeUnitAt(@intCast(n))) continue :outer;
        }
        return i;
    }
}

/// 7.2.7 Static Semantics: IsStringWellFormedUnicode ( string )
/// https://tc39.es/ecma262/#sec-isstringwellformedunicode
pub fn isWellFormedUnicode(self: *const String) bool {
    if (self.isAscii()) return true;

    // 1. Let length be the length of string.
    const length = self.length;

    // 2. Let k be 0.
    var k: u32 = 0;

    // 3. Repeat, while k < length,
    while (k < length) {
        // a. Let codePoint be CodePointAt(string, k).
        const code_point = self.codePointAt(k);

        // b. If codePoint.[[IsUnpairedSurrogate]] is true, return false.
        if (code_point.is_unpaired_surrogate) return false;

        // c. Set k to k + codePoint.[[CodeUnitCount]].
        k += code_point.code_unit_count;
    }

    // 4. Return true.
    return true;
}

pub const CodePoint = struct {
    code_point: u21,
    code_unit_count: u2,
    is_unpaired_surrogate: bool,
};

/// 11.1.4 Static Semantics: CodePointAt ( string, position )
/// https://tc39.es/ecma262/#sec-codepointat
pub fn codePointAt(self: *const String, position: u32) CodePoint {
    // 1. Let size be the length of string.
    const size = self.length;

    // 2. Assert: position ≥ 0 and position < size.
    std.debug.assert(position >= 0 and position < size);

    switch (self.asAsciiOrUtf16()) {
        .ascii => |ascii| {
            return .{ .code_point = ascii[position], .code_unit_count = 1, .is_unpaired_surrogate = false };
        },
        .utf16 => |utf16| {
            // 3. Let first be the code unit at index position within string.
            const first = utf16[position];

            // 4. Let codePoint be the code point whose numeric value is the numeric value of first.
            var code_point: u21 = first;

            // 5. If first is neither a leading surrogate nor a trailing surrogate, then
            if (!std.unicode.utf16IsHighSurrogate(first) and !std.unicode.utf16IsLowSurrogate(first)) {
                // a. Return the Record { [[CodePoint]]: codePoint, [[CodeUnitCount]]: 1,
                //    [[IsUnpairedSurrogate]]: false }.
                return .{ .code_point = code_point, .code_unit_count = 1, .is_unpaired_surrogate = false };
            }

            // 6. If first is a trailing surrogate or position + 1 = size, then
            if (std.unicode.utf16IsLowSurrogate(first) or position + 1 == size) {
                // a. Return the Record { [[CodePoint]]: codePoint, [[CodeUnitCount]]: 1,
                //    [[IsUnpairedSurrogate]]: true }.
                return .{ .code_point = code_point, .code_unit_count = 1, .is_unpaired_surrogate = true };
            }

            // 7. Let second be the code unit at index position + 1 within string.
            const second = utf16[position + 1];

            // 8. If second is not a trailing surrogate, then
            if (!std.unicode.utf16IsLowSurrogate(second)) {
                // a. Return the Record { [[CodePoint]]: codePoint, [[CodeUnitCount]]: 1,
                //    [[IsUnpairedSurrogate]]: true }.
                return .{ .code_point = code_point, .code_unit_count = 1, .is_unpaired_surrogate = true };
            }

            // 9. Set codePoint to UTF16SurrogatePairToCodePoint(first, second).
            code_point = std.unicode.utf16DecodeSurrogatePair(&.{ first, second }) catch unreachable;

            // 10. Return the Record { [[CodePoint]]: codePoint, [[CodeUnitCount]]: 2,
            //     [[IsUnpairedSurrogate]]: false }.
            return .{ .code_point = code_point, .code_unit_count = 2, .is_unpaired_surrogate = false };
        },
    }
}

pub fn codeUnitAt(self: *const String, index: u32) u16 {
    return switch (self.asAsciiOrUtf16()) {
        .ascii => |ascii| ascii[index],
        .utf16 => |utf16| utf16[index],
    };
}

pub fn toLowerCaseAscii(self: *const String, agent: *Agent) std.mem.Allocator.Error!*const String {
    if (self.isEmpty()) return empty;
    switch (self.asAsciiOrUtf16()) {
        .ascii => |ascii| {
            const output = try agent.gc_allocator.alloc(u8, ascii.len);
            for (ascii, 0..) |c, i| {
                output[i] = std.ascii.toLower(c);
            }
            return fromAscii(agent, output);
        },
        .utf16 => |utf16| {
            const output = try agent.gc_allocator.alloc(u16, utf16.len);
            for (utf16, 0..) |c, i| {
                output[i] = if (c < 128) std.ascii.toLower(@intCast(c)) else c;
            }
            return fromUtf16(agent, output);
        },
    }
}

pub fn toUpperCaseAscii(self: *const String, agent: *Agent) std.mem.Allocator.Error!*const String {
    if (self.isEmpty()) return empty;
    switch (self.asAsciiOrUtf16()) {
        .ascii => |ascii| {
            const output = try agent.gc_allocator.alloc(u8, ascii.len);
            for (ascii, 0..) |c, i| {
                output[i] = std.ascii.toUpper(c);
            }
            return fromAscii(agent, output);
        },
        .utf16 => |utf16| {
            const output = try agent.gc_allocator.alloc(u16, utf16.len);
            for (utf16, 0..) |c, i| {
                output[i] = if (c < 128) std.ascii.toUpper(@intCast(c)) else c;
            }
            return fromUtf16(agent, output);
        },
    }
}

pub fn trimStart(self: *const String, agent: *Agent) std.mem.Allocator.Error!*const String {
    if (self.isEmpty()) return empty;
    var start: u32 = 0;
    switch (self.asAsciiOrUtf16()) {
        .ascii => |ascii| {
            while (start < self.length and std.mem.findScalar(u8, &whitespace_ascii, ascii[start]) != null) : (start += 1) {}
        },
        .utf16 => |utf16| {
            while (start < self.length and std.mem.findScalar(u16, &whitespace_utf16, utf16[start]) != null) : (start += 1) {}
        },
    }
    return self.substring(agent, start, null);
}

pub fn trimEnd(self: *const String, agent: *Agent) std.mem.Allocator.Error!*const String {
    if (self.isEmpty()) return empty;
    var end: u32 = self.length;
    switch (self.asAsciiOrUtf16()) {
        .ascii => |ascii| {
            while (end > 0 and std.mem.findScalar(u8, &whitespace_ascii, ascii[end - 1]) != null) : (end -= 1) {}
        },
        .utf16 => |utf16| {
            while (end > 0 and std.mem.findScalar(u16, &whitespace_utf16, utf16[end - 1]) != null) : (end -= 1) {}
        },
    }
    return self.substring(agent, 0, end);
}

pub fn trim(self: *const String, agent: *Agent) std.mem.Allocator.Error!*const String {
    if (self.isEmpty()) return empty;
    var start: u32 = 0;
    var end: u32 = self.length;
    switch (self.asAsciiOrUtf16()) {
        .ascii => |ascii| {
            while (start < end and std.mem.findScalar(u8, &whitespace_ascii, ascii[start]) != null) : (start += 1) {}
            while (end > start and std.mem.findScalar(u8, &whitespace_ascii, ascii[end - 1]) != null) : (end -= 1) {}
        },
        .utf16 => |utf16| {
            while (start < end and std.mem.findScalar(u16, &whitespace_utf16, utf16[start]) != null) : (start += 1) {}
            while (end > start and std.mem.findScalar(u16, &whitespace_utf16, utf16[end - 1]) != null) : (end -= 1) {}
        },
    }
    return self.substring(agent, start, end);
}

pub fn replace(
    self: *const String,
    agent: *Agent,
    needle: []const u8,
    replacement: []const u8,
) std.mem.Allocator.Error!*const String {
    // For now this only deals with simple ASCII replacements.
    switch (self.asAsciiOrUtf16()) {
        .ascii => |ascii| {
            const output = try std.mem.replaceOwned(
                u8,
                agent.gc_allocator,
                ascii,
                needle,
                replacement,
            );
            return fromAscii(agent, output);
        },
        .utf16 => |utf16| {
            const needle_utf16 = std.unicode.utf8ToUtf16LeAlloc(agent.gc_allocator, needle) catch |err| switch (err) {
                error.InvalidUtf8 => @panic("Invalid UTF-8"),
                error.OutOfMemory => |e| return e,
            };
            const replacement_utf16 = std.unicode.utf8ToUtf16LeAlloc(agent.gc_allocator, replacement) catch |err| switch (err) {
                error.InvalidUtf8 => @panic("Invalid UTF-8"),
                error.OutOfMemory => |e| return e,
            };
            const output = try std.mem.replaceOwned(
                u16,
                agent.gc_allocator,
                utf16,
                needle_utf16,
                replacement_utf16,
            );
            return fromUtf16(agent, output);
        },
    }
}

pub fn repeat(
    self: *const String,
    agent: *Agent,
    n: u32,
) std.mem.Allocator.Error!*const String {
    if (n == 0) return empty;
    if (n == 1) return self;
    switch (self.asAsciiOrUtf16()) {
        .ascii => |ascii| {
            const result = try agent.gc_allocator.alloc(u8, ascii.len * n);
            for (0..n) |i| {
                @memcpy(result[i * ascii.len ..][0..ascii.len], ascii);
            }
            return fromAscii(agent, result);
        },
        .utf16 => |utf16| {
            const result = try agent.gc_allocator.alloc(u16, utf16.len * n);
            for (0..n) |i| {
                @memcpy(result[i * utf16.len ..][0..utf16.len], utf16);
            }
            return fromUtf16(agent, result);
        },
    }
}

pub fn concat(
    agent: *Agent,
    strings: []const *const String,
) std.mem.Allocator.Error!*const String {
    // OPTIMIZATION: Fast path for concatenating two strings
    // This should eventually be replaced with rope strings.
    if (strings.len == 2) {
        const lhs = strings[0];
        const rhs = strings[1];
        if (lhs.isEmpty()) return rhs;
        if (rhs.isEmpty()) return lhs;
        if (lhs.isAscii() and rhs.isAscii()) {
            const result = try agent.gc_allocator.alloc(u8, lhs.length + rhs.length);
            @memcpy(result[0..lhs.length], lhs.asAscii());
            @memcpy(result[lhs.length..], rhs.asAscii());
            return fromAscii(agent, result);
        } else {
            const result = try agent.gc_allocator.alloc(u16, lhs.length + rhs.length);
            if (lhs.isUtf16()) {
                @memcpy(result[0..lhs.length], lhs.asUtf16());
            } else {
                for (lhs.asAscii(), 0..) |c, i| result[i] = c;
            }
            if (rhs.isUtf16()) {
                @memcpy(result[lhs.length..], rhs.asUtf16());
            } else {
                for (rhs.asAscii(), lhs.length..) |c, i| result[i] = c;
            }
            return fromUtf16(agent, result);
        }
    }
    const gpa = agent.gpa;
    // SAFETY: This builder can use a GPA as it only stores strings rooted via the argument slice.
    var builder = try Builder.initCapacity(gpa, @intCast(strings.len));
    defer builder.deinit(gpa);
    for (strings) |string| builder.appendStringAssumeCapacity(string);
    return builder.build(agent);
}

pub fn HashMap(comptime V: type) type {
    return std.HashMapUnmanaged(*const String, V, struct {
        pub fn hash(_: @This(), key: *const String) u64 {
            return key.hash;
        }

        pub fn eql(_: @This(), a: *const String, b: *const String) bool {
            return a.eql(b);
        }
    }, std.hash_map.default_max_load_percentage);
}

pub fn ArrayHashMap(comptime V: type) type {
    return std.array_hash_map.Custom(*const String, V, struct {
        pub fn hash(_: @This(), key: *const String) u32 {
            return @truncate(key.hash);
        }

        pub fn eql(_: @This(), a: *const String, b: *const String, _: usize) bool {
            return a.eql(b);
        }
    }, false);
}

test format {
    const test_cases = [_]struct { *const String, []const u8 }{
        .{ empty, "\"\"" },
        .{ fromLiteral("foo"), "\"foo\"" },
        .{ fromLiteral("123"), "\"123\"" },
        .{ fromLiteral("äöüß😎"), "\"äöüß😎\"" },
        .{
            fromLiteral("\x00\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0A\x0B\x0C\x0D\x0E\x0F\\"),
            "\"\\x00\\x01\\x02\\x03\\x04\\x05\\x06\\x07\\b\\t\\n\\v\\f\\r\\x0e\\x0f\\\\\"",
        },
        .{
            &.{ .data = .{ .static_utf16 = &.{0xd83d} }, .length = 1, .hash = undefined },
            "\"\\ud83d\"",
        },
    };
    for (test_cases) |test_case| {
        const string, const expected = test_case;
        try std.testing.expectFmt(expected, "{f}", .{string});
    }
}

test empty {
    try std.testing.expectEqual(.empty, std.meta.activeTag(empty.data));
    try std.testing.expectEqualSlices(u8, "", empty.asAscii());
    try std.testing.expectEqual(0, empty.length);
    try std.testing.expectEqual(0, empty.hash);
}

test fromLiteral {
    {
        const string = fromLiteral("");
        try std.testing.expectEqual(empty, string);
    }
    {
        const string = fromLiteral("foo");
        try std.testing.expectEqual(.static_ascii, std.meta.activeTag(string.data));
        try std.testing.expectEqualSlices(u8, "foo", string.asAscii());
        try std.testing.expectEqual(3, string.length);
        try std.testing.expectEqual(0xa94472b2b241e867, string.hash);
    }
    {
        const string = fromLiteral("😎");
        try std.testing.expectEqual(.static_utf16, std.meta.activeTag(string.data));
        try std.testing.expectEqualSlices(u16, &.{ 0xD83D, 0xDE0E }, string.asUtf16());
        try std.testing.expectEqual(2, string.length);
        try std.testing.expectEqual(0x21e24ace07bf6072, string.hash);
    }
    {
        const a = fromLiteral("foo");
        const b = fromLiteral("foo");
        // Comptime function caching guarantees deduplication
        try std.testing.expectEqual(a, b);
    }
}

test fromUtf8 {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var environ_map = try std.process.Environ.createMap(.empty, gpa);
    defer environ_map.deinit();
    const platform: Agent.Platform = .default(io, &environ_map);
    defer platform.deinit();
    var agent = try Agent.init(gpa, io, &platform, .{});
    defer agent.deinit();
    {
        const string = try fromUtf8(&agent, "");
        try std.testing.expectEqual(empty, string);
    }
    {
        const string = try fromUtf8(&agent, "foo");
        try std.testing.expectEqual(.owned_ascii, std.meta.activeTag(string.data));
        try std.testing.expectEqualSlices(u8, "foo", string.asAscii());
        try std.testing.expectEqual(3, string.length);
        try std.testing.expectEqual(0xa94472b2b241e867, string.hash);
    }
    {
        const string = try fromUtf8(&agent, "😎");
        try std.testing.expectEqual(.owned_utf16, std.meta.activeTag(string.data));
        try std.testing.expectEqualSlices(u16, &.{ 0xD83D, 0xDE0E }, string.asUtf16());
        try std.testing.expectEqual(2, string.length);
        try std.testing.expectEqual(0x21e24ace07bf6072, string.hash);
    }
    {
        const a = try fromUtf8(&agent, "foo");
        const b = try fromUtf8(&agent, "foo");
        // String cache weakly guarantees deduplication
        try std.testing.expectEqual(a, b);
    }
}

test fromAscii {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var environ_map = try std.process.Environ.createMap(.empty, gpa);
    defer environ_map.deinit();
    const platform: Agent.Platform = .default(io, &environ_map);
    defer platform.deinit();
    var agent = try Agent.init(gpa, io, &platform, .{});
    defer agent.deinit();
    {
        const string = try fromAscii(&agent, "");
        try std.testing.expectEqual(empty, string);
    }
    {
        const string = try fromAscii(&agent, "foo");
        try std.testing.expectEqual(.owned_ascii, std.meta.activeTag(string.data));
        try std.testing.expectEqualSlices(u8, "foo", string.asAscii());
        try std.testing.expectEqual(3, string.length);
        try std.testing.expectEqual(0xa94472b2b241e867, string.hash);
    }
    {
        const a = try fromAscii(&agent, "foo");
        const b = try fromAscii(&agent, "foo");
        // String cache weakly guarantees deduplication
        try std.testing.expectEqual(a, b);
    }
}

test fromUtf16 {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var environ_map = try std.process.Environ.createMap(.empty, gpa);
    defer environ_map.deinit();
    const platform: Agent.Platform = .default(io, &environ_map);
    defer platform.deinit();
    var agent = try Agent.init(gpa, io, &platform, .{});
    defer agent.deinit();
    {
        const string = try fromUtf16(&agent, &.{});
        try std.testing.expectEqual(empty, string);
    }
    {
        const string = try fromUtf16(&agent, std.unicode.utf8ToUtf16LeStringLiteral("😎"));
        try std.testing.expectEqual(.owned_utf16, std.meta.activeTag(string.data));
        try std.testing.expectEqualSlices(u16, &.{ 0xD83D, 0xDE0E }, string.asUtf16());
        try std.testing.expectEqual(2, string.length);
        try std.testing.expectEqual(0x21e24ace07bf6072, string.hash);
    }
    {
        const a = try fromUtf16(&agent, std.unicode.utf8ToUtf16LeStringLiteral("😎"));
        const b = try fromUtf16(&agent, std.unicode.utf8ToUtf16LeStringLiteral("😎"));
        // String cache weakly guarantees deduplication
        try std.testing.expectEqual(a, b);
    }
}

test fromStringSliced {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var environ_map = try std.process.Environ.createMap(.empty, gpa);
    defer environ_map.deinit();
    const platform: Agent.Platform = .default(io, &environ_map);
    defer platform.deinit();
    var agent = try Agent.init(gpa, io, &platform, .{});
    defer agent.deinit();
    const parent = fromLiteral("foobarbaz");
    {
        const string = try fromStringSliced(&agent, parent, 0, 0);
        try std.testing.expectEqual(empty, string);
    }
    {
        const string = try fromStringSliced(&agent, parent, 0, 9);
        try std.testing.expectEqual(parent, string);
    }
    {
        const string = try fromStringSliced(&agent, parent, 0, 6);
        try std.testing.expectEqual(.slice_ascii, std.meta.activeTag(string.data));
        try std.testing.expectEqual(parent, string.data.slice_ascii.string);
        try std.testing.expectEqual(0, string.data.slice_ascii.start);
        try std.testing.expectEqualSlices(u8, "foobar", string.asAscii());
        try std.testing.expectEqual(6, string.length);
        try std.testing.expectEqual(0xb9d35b96e1f6fe2, string.hash);
    }
    {
        const parent_sliced = try fromStringSliced(&agent, parent, 3, 9);
        const string = try fromStringSliced(&agent, parent_sliced, 3, 6);
        try std.testing.expectEqual(.slice_ascii, std.meta.activeTag(string.data));
        try std.testing.expectEqual(parent, string.data.slice_ascii.string);
        try std.testing.expectEqual(6, string.data.slice_ascii.start);
        try std.testing.expectEqualSlices(u8, "baz", string.asAscii());
        try std.testing.expectEqual(3, string.length);
        try std.testing.expectEqual(0xff605a97715ddf78, string.hash);
    }
}

test trimStart {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var environ_map = try std.process.Environ.createMap(.empty, gpa);
    defer environ_map.deinit();
    const platform: Agent.Platform = .default(io, &environ_map);
    defer platform.deinit();
    var agent = try Agent.init(gpa, io, &platform, .{});
    defer agent.deinit();
    {
        const parent = fromLiteral(" \n\r\t \n\r\t");
        const string = try parent.trimStart(&agent);
        try std.testing.expectEqual(empty, string);
    }
    {
        const parent = fromLiteral("foo");
        const string = try parent.trimStart(&agent);
        try std.testing.expectEqual(parent, string);
    }
    {
        const parent = fromLiteral(" \n\r\t \n\r\tfoo \n\r\t \n\r\t");
        const string = try parent.trimStart(&agent);
        try std.testing.expect(string.eql(String.fromLiteral("foo \n\r\t \n\r\t")));
    }
}

test trimEnd {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var environ_map = try std.process.Environ.createMap(.empty, gpa);
    defer environ_map.deinit();
    const platform: Agent.Platform = .default(io, &environ_map);
    defer platform.deinit();
    var agent = try Agent.init(gpa, io, &platform, .{});
    defer agent.deinit();
    {
        const parent = fromLiteral(" \n\r\t \n\r\t");
        const string = try parent.trimEnd(&agent);
        try std.testing.expectEqual(empty, string);
    }
    {
        const parent = fromLiteral("foo");
        const string = try parent.trimEnd(&agent);
        try std.testing.expectEqual(parent, string);
    }
    {
        const parent = fromLiteral(" \n\r\t \n\r\tfoo \n\r\t \n\r\t");
        const string = try parent.trimEnd(&agent);
        try std.testing.expect(string.eql(String.fromLiteral(" \n\r\t \n\r\tfoo")));
    }
}

test trim {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var environ_map = try std.process.Environ.createMap(.empty, gpa);
    defer environ_map.deinit();
    const platform: Agent.Platform = .default(io, &environ_map);
    defer platform.deinit();
    var agent = try Agent.init(gpa, io, &platform, .{});
    defer agent.deinit();
    {
        const parent = fromLiteral(" \n\r\t \n\r\t");
        const string = try parent.trim(&agent);
        try std.testing.expectEqual(empty, string);
    }
    {
        const parent = fromLiteral("foo");
        const string = try parent.trim(&agent);
        try std.testing.expectEqual(parent, string);
    }
    {
        const parent = fromLiteral(" \n\r\t \n\r\tfoo \n\r\t \n\r\t");
        const string = try parent.trim(&agent);
        try std.testing.expect(string.eql(String.fromLiteral("foo")));
    }
}

test repeat {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var environ_map = try std.process.Environ.createMap(.empty, gpa);
    defer environ_map.deinit();
    const platform: Agent.Platform = .default(io, &environ_map);
    defer platform.deinit();
    var agent = try Agent.init(gpa, io, &platform, .{});
    defer agent.deinit();
    {
        const parent = fromLiteral("foo");
        const string = try parent.repeat(&agent, 0);
        try std.testing.expectEqual(empty, string);
    }
    {
        const parent = fromLiteral("foo");
        const string = try parent.repeat(&agent, 1);
        try std.testing.expectEqual(string, string);
    }
    {
        const parent = fromLiteral("foo");
        const string = try parent.repeat(&agent, 3);
        try std.testing.expect(string.eql(String.fromLiteral("foofoofoo")));
    }
}

test concat {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var environ_map = try std.process.Environ.createMap(.empty, gpa);
    defer environ_map.deinit();
    const platform: Agent.Platform = .default(io, &environ_map);
    defer platform.deinit();
    var agent = try Agent.init(gpa, io, &platform, .{});
    defer agent.deinit();
    {
        const string = try String.concat(&agent, &.{});
        try std.testing.expectEqual(empty, string);
    }
    {
        const string = try String.concat(&agent, &.{
            String.fromLiteral("foo"),
        });
        try std.testing.expect(string.eql(String.fromLiteral("foo")));
    }
    {
        const string = try String.concat(&agent, &.{
            String.fromLiteral("foo"),
            String.fromLiteral("bar"),
        });
        try std.testing.expectEqual(.owned_ascii, std.meta.activeTag(string.data));
        try std.testing.expect(string.eql(String.fromLiteral("foobar")));
    }
    {
        const string = try String.concat(&agent, &.{
            String.fromLiteral("foo"),
            String.fromLiteral("bar"),
            String.fromLiteral("äöü"),
        });
        try std.testing.expectEqual(.owned_utf16, std.meta.activeTag(string.data));
        try std.testing.expect(string.eql(String.fromLiteral("foobaräöü")));
    }
}
