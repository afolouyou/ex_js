const std = @import("std");

const Diagnostics = @This();

gpa: std.mem.Allocator,
source: []const u8,
file_name: ?[]const u8,
message_bytes: std.ArrayList(u8),
errors: std.ArrayList(Error),

pub const Error = struct {
    offset: u32,
    message_start: u32,
    message_len: u32,

    pub fn fmt(err: *const Error, d: *const Diagnostics) Format {
        return .{ .err = err, .d = d };
    }

    pub fn fmtHint(err: *const Error, d: *const Diagnostics) FormatHint {
        return .{ .err = err, .d = d };
    }

    fn message(err: *const Error, d: *const Diagnostics) []const u8 {
        return d.message_bytes.items[err.message_start..][0..err.message_len];
    }

    const Format = struct {
        err: *const Error,
        d: *const Diagnostics,

        pub fn format(f: Format, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            const loc = f.d.location(f.err.offset);
            try writer.print("{s} ({s}:{d}:{d})", .{
                f.err.message(f.d),
                f.d.file_name orelse "<unknown>",
                loc.line,
                loc.column,
            });
        }
    };

    const FormatHint = struct {
        err: *const Error,
        d: *const Diagnostics,

        pub fn format(f: FormatHint, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            const loc = f.d.location(f.err.offset);
            // NOTE: only '\n' advances the line counter - for \r\n newlines this doesn't matter, and
            //       LS/PS are rare enough to not matter for now.
            var line_iterator = std.mem.splitScalar(u8, f.d.source, '\n');
            var i: u32 = 0;
            const source_line = while (line_iterator.next()) |source_line| : (i += 1) {
                if (i == loc.line - 1) break source_line;
            } else unreachable;
            try writer.print("{s}\n{c: >[2]}", .{
                source_line,
                '^',
                loc.column, // 1-indexed, which is fine as this means 'width' in this context
            });
        }
    };
};

pub const Options = struct {
    source: []const u8,
    file_name: ?[]const u8,
};

pub fn init(gpa: std.mem.Allocator, options: Options) Diagnostics {
    return .{
        .gpa = gpa,
        .source = options.source,
        .file_name = options.file_name,
        .message_bytes = .empty,
        .errors = .empty,
    };
}

pub fn deinit(d: *Diagnostics) void {
    d.message_bytes.deinit(d.gpa);
    d.errors.deinit(d.gpa);
}

pub fn emit(
    d: *Diagnostics,
    offset: u32,
    comptime fmt: []const u8,
    args: anytype,
) std.mem.Allocator.Error!void {
    const start = d.message_bytes.items.len;
    errdefer d.message_bytes.shrinkRetainingCapacity(start);

    try d.message_bytes.print(d.gpa, fmt, args);
    try d.errors.append(d.gpa, .{
        .offset = offset,
        .message_start = @intCast(start),
        .message_len = @intCast(d.message_bytes.items.len - start),
    });
}

pub fn hasErrors(d: *const Diagnostics) bool {
    return d.errors.items.len != 0;
}

pub fn first(d: *const Diagnostics) ?Error {
    return if (d.errors.items.len == 0) null else d.errors.items[0];
}

const Location = struct { line: u32, column: u32 };

fn location(d: *const Diagnostics, offset: u32) Location {
    var line: u32 = 1;
    var column: u32 = 1;
    for (d.source[0..offset]) |c| {
        if (c == '\n') {
            line += 1;
            column = 1;
        } else {
            column += 1;
        }
    }
    return .{ .line = line, .column = column };
}

test {
    var diagnostics: Diagnostics = .init(std.testing.allocator, .{
        .source =
        \\var x = ;
        \\let let = 1;
        ,
        .file_name = "file.js",
    });
    defer diagnostics.deinit();

    try std.testing.expect(!diagnostics.hasErrors());
    try std.testing.expect(diagnostics.first() == null);

    try diagnostics.emit(8, "Unexpected token '{s}'", .{";"});
    try diagnostics.emit(14, "Lexical declaration must not have binding named '{s}'", .{"let"});

    try std.testing.expect(diagnostics.hasErrors());

    {
        const err = diagnostics.first().?;
        try std.testing.expectFmt(
            "Unexpected token ';' (file.js:1:9)",
            "{f}",
            .{err.fmt(&diagnostics)},
        );
        try std.testing.expectFmt(
            \\var x = ;
            \\        ^
        ,
            "{f}",
            .{err.fmtHint(&diagnostics)},
        );
    }

    {
        const err = diagnostics.errors.items[1];
        try std.testing.expectFmt(
            "Lexical declaration must not have binding named 'let' (file.js:2:5)",
            "{f}",
            .{err.fmt(&diagnostics)},
        );
        try std.testing.expectFmt(
            \\let let = 1;
            \\    ^
        ,
            "{f}",
            .{err.fmtHint(&diagnostics)},
        );
    }
}
