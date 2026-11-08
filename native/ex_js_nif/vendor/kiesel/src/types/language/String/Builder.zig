const std = @import("std");

const execution = @import("../../../execution.zig");
const types = @import("../../../types.zig");

const Agent = execution.Agent;
const String = types.String;

const Builder = @This();

segments: std.ArrayList(Segment),

pub const Segment = union(enum) {
    string: *const String,
    char: u8,
    code_unit: u16,
    code_point: u21,
};

pub const empty: Builder = .{
    .segments = .empty,
};

pub fn initCapacity(
    allocator: std.mem.Allocator,
    capacity: u32,
) std.mem.Allocator.Error!Builder {
    var builder: Builder = .empty;
    try builder.segments.ensureUnusedCapacity(allocator, capacity);
    return builder;
}

pub fn deinit(self: *Builder, allocator: std.mem.Allocator) void {
    self.segments.deinit(allocator);
}

pub fn appendSegment(self: *Builder, allocator: std.mem.Allocator, segment: Segment) std.mem.Allocator.Error!void {
    try self.segments.append(allocator, segment);
}

pub fn appendSegmentAssumeCapacity(self: *Builder, segment: Segment) void {
    self.segments.appendAssumeCapacity(segment);
}

pub fn appendString(self: *Builder, allocator: std.mem.Allocator, string: *const String) std.mem.Allocator.Error!void {
    try self.segments.append(allocator, .{ .string = string });
}

pub fn appendStringAssumeCapacity(self: *Builder, string: *const String) void {
    self.segments.appendAssumeCapacity(.{ .string = string });
}

pub fn appendChar(self: *Builder, allocator: std.mem.Allocator, char: u8) std.mem.Allocator.Error!void {
    try self.segments.append(allocator, .{ .char = char });
}

pub fn appendCharAssumeCapacity(self: *Builder, char: u8) void {
    self.segments.appendAssumeCapacity(.{ .char = char });
}

pub fn appendCodeUnit(self: *Builder, allocator: std.mem.Allocator, code_unit: u16) std.mem.Allocator.Error!void {
    try self.segments.append(allocator, .{ .code_unit = code_unit });
}

pub fn appendCodeUnitAssumeCapacity(self: *Builder, code_unit: u16) void {
    self.segments.appendAssumeCapacity(.{ .code_unit = code_unit });
}

pub fn appendCodePoint(self: *Builder, allocator: std.mem.Allocator, code_point: u21) std.mem.Allocator.Error!void {
    try self.segments.append(allocator, .{ .code_point = code_point });
}

pub fn appendCodePointAssumeCapacity(self: *Builder, code_point: u21) void {
    self.segments.appendAssumeCapacity(.{ .code_point = code_point });
}

fn buildImpl(self: Builder, allocator: std.mem.Allocator) std.mem.Allocator.Error!String.AsciiOrUtf16 {
    var is_ascii = true;
    var capacity: u32 = 0;
    for (self.segments.items) |segment| switch (segment) {
        .string => |string| {
            is_ascii &= string.isAscii();
            capacity += string.length;
        },
        .char => |char| {
            is_ascii &= char <= 0x7F;
            capacity += 1;
        },
        .code_unit => |code_unit| {
            is_ascii &= code_unit <= 0x7F;
            capacity += 1;
        },
        .code_point => |code_point| {
            is_ascii &= code_point <= 0x7F;
            capacity += if (code_point < 0x10000) 1 else 2;
        },
    };
    if (is_ascii) {
        var result: std.ArrayList(u8) = try .initCapacity(allocator, capacity);
        for (self.segments.items) |segment| switch (segment) {
            .string => |string| result.appendSliceAssumeCapacity(string.asAscii()),
            .char => |char| result.appendAssumeCapacity(char),
            .code_unit => |code_unit| result.appendAssumeCapacity(@intCast(code_unit)),
            .code_point => |code_point| result.appendAssumeCapacity(@intCast(code_point)),
        };
        return .{ .ascii = try result.toOwnedSlice(allocator) };
    } else {
        var result: std.ArrayList(u16) = try .initCapacity(allocator, capacity);
        for (self.segments.items) |segment| switch (segment) {
            .string => |string| switch (string.asAsciiOrUtf16()) {
                .ascii => |ascii| for (ascii) |c| result.appendAssumeCapacity(c),
                .utf16 => |utf16| result.appendSliceAssumeCapacity(utf16),
            },
            .char => |char| result.appendAssumeCapacity(char),
            .code_unit => |code_unit| result.appendAssumeCapacity(code_unit),
            .code_point => |code_point| if (code_point < 0x10000) {
                result.appendAssumeCapacity(@intCast(code_point));
            } else {
                result.appendAssumeCapacity(@intCast(0xd800 | ((code_point - 0x10000) >> 10)));
                result.appendAssumeCapacity(@intCast(0xdc00 | ((code_point - 0x10000) & 0x3ff)));
            },
        };
        return .{ .utf16 = try result.toOwnedSlice(allocator) };
    }
}

pub fn build(self: Builder, agent: *Agent) std.mem.Allocator.Error!*const String {
    const slice = try buildImpl(self, agent.gc_allocator);
    return switch (slice) {
        .ascii => |ascii| String.fromAscii(agent, ascii),
        .utf16 => |utf16| String.fromUtf16(agent, utf16),
    };
}

pub fn buildAlloc(self: Builder, allocator: std.mem.Allocator) std.mem.Allocator.Error!*const String {
    const slice = try buildImpl(self, allocator);
    return switch (slice) {
        .ascii => |ascii| String.fromAsciiAlloc(allocator, ascii),
        .utf16 => |utf16| String.fromUtf16Alloc(allocator, utf16),
    };
}
