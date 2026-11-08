const std = @import("std");

const unicode_id = @import("unicode-id");

const utils = @import("../utils.zig");

const Token = @import("Token.zig");
const parseDigits = utils.parseDigits;

const Tokenizer = @This();

gpa: std.mem.Allocator,
/// Null-terminated so we can switch on the null byte instead of having to
/// check if the index is out of bounds after every advancement.
source: [:0]const u8,
index: u32,
token_window: [2]?Token,
operand_expected: bool,
context_stack: std.ArrayList(Context),
template_stack: std.ArrayList(u32),

pub const Context = struct {
    tag: Tag,
    is_expr: bool,

    const Tag = enum {
        left_curly_bracket,
        left_parenthesis,
        keyword_function,
    };
};

pub fn init(gpa: std.mem.Allocator, source: [:0]const u8) Tokenizer {
    return .{
        .gpa = gpa,
        .source = source,
        .index = 0,
        .operand_expected = true,
        .token_window = .{ null, null },
        .context_stack = .empty,
        .template_stack = .empty,
    };
}

pub fn deinit(t: *Tokenizer) void {
    t.context_stack.deinit(t.gpa);
    t.template_stack.deinit(t.gpa);
}

pub fn next(t: *Tokenizer) std.mem.Allocator.Error!?Token {
    var start = t.index;
    var tag: Token.Tag = undefined;

    const State = enum {
        start,
        question_mark,
        double_question_mark,
        period,
        less_than,
        double_less_than,
        greater_than,
        double_greater_than,
        triple_greater_than,
        equals,
        double_equals,
        exclamation_mark,
        exclamation_mark_equals,
        plus,
        minus,
        asterisk,
        double_asterisk,
        percent,
        ampersand,
        double_ampersand,
        pipe,
        double_pipe,
        caret,
        slash,
        slash_operator,
        line_comment,
        multiline_comment,
        multiline_comment_asterisk,
        html_open_comment,
        html_close_comment,
        hashbang_comment,
        hash,
        private_identifier,
        identifier_name,
        numeric_literal,
        string_literal,
        regexp_literal,
        template_literal,
        multi_byte_whitespace_or_line_terminator,
    };
    state: switch (State.start) {
        .start => switch (t.source[t.index]) {
            // Single byte whitespace and line terminators, multi-byte are handled below
            ' ',
            '\t',
            '\n',
            '\r',
            0x0B, // \v
            0x0C, // \f
            => {
                t.index += 1;
                start = t.index;
                continue :state .start;
            },
            0 => {
                if (t.index == t.source.len) return null;
                t.index += 1;
                tag = .invalid;
            },
            '{' => {
                if (t.template_stack.items.len > 0) {
                    const depth = &t.template_stack.items[t.template_stack.items.len - 1];
                    depth.* += 1;
                }
                t.index += 1;
                tag = .left_curly_bracket;
            },
            '}' => {
                if (t.template_stack.items.len > 0) {
                    const depth = &t.template_stack.items[t.template_stack.items.len - 1];
                    if (depth.* == 0) continue :state .template_literal;
                    depth.* -= 1;
                }
                t.index += 1;
                tag = .right_curly_bracket;
            },
            '(' => {
                t.index += 1;
                tag = .left_parenthesis;
            },
            ')' => {
                t.index += 1;
                tag = .right_parenthesis;
            },
            '[' => {
                t.index += 1;
                tag = .left_square_bracket;
            },
            ']' => {
                t.index += 1;
                tag = .right_square_bracket;
            },
            ';' => {
                t.index += 1;
                tag = .semicolon;
            },
            ',' => {
                t.index += 1;
                tag = .comma;
            },
            '~' => {
                t.index += 1;
                tag = .tilde;
            },
            ':' => {
                t.index += 1;
                tag = .colon;
            },
            '?' => continue :state .question_mark,
            '.' => continue :state .period,
            '<' => continue :state .less_than,
            '>' => continue :state .greater_than,
            '=' => continue :state .equals,
            '!' => continue :state .exclamation_mark,
            '+' => continue :state .plus,
            '-' => continue :state .minus,
            '*' => continue :state .asterisk,
            '%' => continue :state .percent,
            '&' => continue :state .ampersand,
            '|' => continue :state .pipe,
            '^' => continue :state .caret,
            '/' => continue :state .slash,
            '#' => continue :state .hash,
            'a'...'z', 'A'...'Z', '$', '_' => continue :state .identifier_name,
            '0'...'9' => continue :state .numeric_literal,
            '"', '\'' => continue :state .string_literal,
            '`' => continue :state .template_literal,
            // Whitespace:
            // U+00A0: "\xC2\xA0"
            // U+1680: "\xE1\x9A\x80"
            // U+2000: "\xE2\x80\x80"
            // ...
            // U+200A: "\xE2\x80\x8A"
            // U+202F: "\xE2\x80\xAF"
            // U+205F: "\xE2\x81\x9F"
            // U+3000: "\xE3\x80\x80"
            // U+FEFF: "\xEF\xBB\xBF"
            // Line terminators:
            // U+2028: "\xE2\x80\xA8"
            // U+2029: "\xE2\x80\xA9"
            0xC2, 0xE1, 0xE2, 0xE3, 0xEF => continue :state .multi_byte_whitespace_or_line_terminator,
            '\\' => {
                if (parseUnicodeEscapeSequence(t.source[t.index..])) |parsed| {
                    t.index += parsed.len - 1;
                    continue :state .identifier_name;
                }
                t.index += 1;
                tag = .invalid;
            },
            else => {
                // Assert that the switch prongs above are exhaustive
                std.debug.assert(std.mem.findScalar(u8, &single_byte_whitespace, t.source[t.index]) == null);
                std.debug.assert(std.mem.findScalar(u8, &single_byte_line_terminators, t.source[t.index]) == null);
                if (parseCodePoint(t.source[t.index..])) |parsed| {
                    if (canCodePointStartId(parsed.code_point)) {
                        t.index += parsed.len - 1;
                        continue :state .identifier_name;
                    }
                }
                t.index += 1;
                tag = .invalid;
            },
        },
        .question_mark => {
            t.index += 1;
            switch (t.source[t.index]) {
                '?' => continue :state .double_question_mark,
                '.' => {
                    if (std.ascii.isDigit(t.source[t.index + 1])) {
                        // `?.` is not permitted to be followed by a decimal digit (§12.8), so
                        // `a?.3` is `a ? .3`. Leave the `.` for the numeric literal.
                        tag = .question_mark;
                    } else {
                        t.index += 1;
                        tag = .question_mark_period;
                    }
                },
                else => tag = .question_mark,
            }
        },
        .double_question_mark => {
            t.index += 1;
            switch (t.source[t.index]) {
                '=' => {
                    t.index += 1;
                    tag = .double_question_mark_equals;
                },
                else => tag = .double_question_mark,
            }
        },
        .period => {
            if (std.mem.startsWith(u8, t.source[t.index..], "...")) {
                t.index += 3;
                tag = .ellipsis;
            } else if (std.ascii.isDigit(t.source[t.index + 1])) {
                // A leading `.` followed by a digit starts a numeric literal (e.g. `.5`)
                continue :state .numeric_literal;
            } else {
                t.index += 1;
                tag = .period;
            }
        },
        .less_than => {
            t.index += 1;
            switch (t.source[t.index]) {
                '<' => continue :state .double_less_than,
                '=' => {
                    t.index += 1;
                    tag = .less_than_equals;
                },
                '!' => {
                    if (t.source[t.index + 1] == '-' and
                        t.source[t.index + 2] == '-')
                    {
                        t.index += 2;
                        continue :state .html_open_comment;
                    }
                    tag = .less_than;
                },
                else => tag = .less_than,
            }
        },
        .double_less_than => {
            t.index += 1;
            switch (t.source[t.index]) {
                '=' => {
                    t.index += 1;
                    tag = .double_less_than_equals;
                },
                else => tag = .double_less_than,
            }
        },
        .greater_than => {
            t.index += 1;
            switch (t.source[t.index]) {
                '>' => continue :state .double_greater_than,
                '=' => {
                    t.index += 1;
                    tag = .greater_than_equals;
                },
                else => tag = .greater_than,
            }
        },
        .double_greater_than => {
            t.index += 1;
            switch (t.source[t.index]) {
                '>' => continue :state .triple_greater_than,
                '=' => {
                    t.index += 1;
                    tag = .double_greater_than_equals;
                },
                else => tag = .double_greater_than,
            }
        },
        .triple_greater_than => {
            t.index += 1;
            switch (t.source[t.index]) {
                '=' => {
                    t.index += 1;
                    tag = .triple_greater_than_equals;
                },
                else => tag = .triple_greater_than,
            }
        },
        .equals => {
            t.index += 1;
            switch (t.source[t.index]) {
                '=' => continue :state .double_equals,
                '>' => {
                    t.index += 1;
                    tag = .equals_greater_than;
                },
                else => tag = .equals,
            }
        },
        .double_equals => {
            t.index += 1;
            switch (t.source[t.index]) {
                '=' => {
                    t.index += 1;
                    tag = .triple_equals;
                },
                else => tag = .double_equals,
            }
        },
        .exclamation_mark => {
            t.index += 1;
            switch (t.source[t.index]) {
                '=' => continue :state .exclamation_mark_equals,
                else => tag = .exclamation_mark,
            }
        },
        .exclamation_mark_equals => {
            t.index += 1;
            switch (t.source[t.index]) {
                '=' => {
                    t.index += 1;
                    tag = .exclamation_mark_double_equals;
                },
                else => tag = .exclamation_mark_equals,
            }
        },
        .plus => {
            t.index += 1;
            switch (t.source[t.index]) {
                '+' => {
                    t.index += 1;
                    tag = .double_plus;
                },
                '=' => {
                    t.index += 1;
                    tag = .plus_equals;
                },
                else => tag = .plus,
            }
        },
        .minus => {
            t.index += 1;
            switch (t.source[t.index]) {
                '-' => {
                    if (t.source[t.index + 1] == '>') blk: {
                        if (t.token_window[1]) |prev_token| {
                            const trivia = t.source[@backingInt(prev_token.end)..t.index];
                            if (findLineTerminator(trivia) == null) break :blk;
                        }
                        t.index += 1;
                        continue :state .html_close_comment;
                    }
                    t.index += 1;
                    tag = .double_minus;
                },
                '=' => {
                    t.index += 1;
                    tag = .minus_equals;
                },
                else => tag = .minus,
            }
        },
        .asterisk => {
            t.index += 1;
            switch (t.source[t.index]) {
                '=' => {
                    t.index += 1;
                    tag = .asterisk_equals;
                },
                '*' => continue :state .double_asterisk,
                else => tag = .asterisk,
            }
        },
        .double_asterisk => {
            t.index += 1;
            switch (t.source[t.index]) {
                '=' => {
                    t.index += 1;
                    tag = .double_asterisk_equals;
                },
                else => tag = .double_asterisk,
            }
        },
        .percent => {
            t.index += 1;
            switch (t.source[t.index]) {
                '=' => {
                    t.index += 1;
                    tag = .percent_equals;
                },
                else => tag = .percent,
            }
        },
        .ampersand => {
            t.index += 1;
            switch (t.source[t.index]) {
                '&' => continue :state .double_ampersand,
                '=' => {
                    t.index += 1;
                    tag = .ampersand_equals;
                },
                else => tag = .ampersand,
            }
        },
        .double_ampersand => {
            t.index += 1;
            switch (t.source[t.index]) {
                '=' => {
                    t.index += 1;
                    tag = .double_ampersand_equals;
                },
                else => tag = .double_ampersand,
            }
        },
        .pipe => {
            t.index += 1;
            switch (t.source[t.index]) {
                '|' => continue :state .double_pipe,
                '=' => {
                    t.index += 1;
                    tag = .pipe_equals;
                },
                else => tag = .pipe,
            }
        },
        .double_pipe => {
            t.index += 1;
            switch (t.source[t.index]) {
                '=' => {
                    t.index += 1;
                    tag = .double_pipe_equals;
                },
                else => tag = .double_pipe,
            }
        },
        .caret => {
            t.index += 1;
            switch (t.source[t.index]) {
                '=' => {
                    t.index += 1;
                    tag = .caret_equals;
                },
                else => tag = .caret,
            }
        },
        .slash => {
            if (t.operand_expected and t.source[t.index + 1] != '/' and t.source[t.index + 1] != '*') {
                continue :state .regexp_literal;
            }
            continue :state .slash_operator;
        },
        .slash_operator => {
            t.index += 1;
            switch (t.source[t.index]) {
                '/' => continue :state .line_comment,
                '*' => continue :state .multiline_comment,
                '=' => {
                    t.index += 1;
                    tag = .slash_equals;
                },
                else => tag = .slash,
            }
        },
        .line_comment,
        .html_open_comment,
        .html_close_comment,
        .hashbang_comment,
        => |state| {
            t.index += 1;
            if (lineTerminatorLen(t.source[t.index..]) != null or t.index == t.source.len) {
                tag = switch (state) {
                    .line_comment => .line_comment,
                    .html_open_comment => .html_open_comment,
                    .html_close_comment => .html_close_comment,
                    .hashbang_comment => .hashbang_comment,
                    else => unreachable,
                };
            } else {
                continue :state state;
            }
        },
        .multiline_comment => {
            t.index += 1;
            switch (t.source[t.index]) {
                0 => if (t.index == t.source.len) {
                    tag = .invalid;
                } else {
                    continue :state .multiline_comment;
                },
                '*' => continue :state .multiline_comment_asterisk,
                else => continue :state .multiline_comment,
            }
        },
        .multiline_comment_asterisk => {
            if (t.source[t.index + 1] == '/') {
                t.index += 2;
                tag = .multiline_comment;
            } else {
                continue :state .multiline_comment;
            }
        },
        .hash => {
            if (t.index == 0 and t.source[1] == '!') {
                t.index += 1;
                continue :state .hashbang_comment;
            }
            t.index += 1;
            switch (t.source[t.index]) {
                'a'...'z', 'A'...'Z', '$', '_' => continue :state .private_identifier,
                '\\' => if (parseUnicodeEscapeSequence(t.source[t.index..])) |parsed| {
                    t.index += parsed.len - 1;
                    continue :state .private_identifier;
                },
                0x80...0xFF => if (parseCodePoint(t.source[t.index..])) |parsed| {
                    if (canCodePointStartId(parsed.code_point)) {
                        t.index += parsed.len - 1;
                        continue :state .private_identifier;
                    }
                },
                else => {},
            }
            tag = .invalid;
        },
        .private_identifier => {
            t.index += 1;
            switch (t.source[t.index]) {
                'a'...'z', 'A'...'Z', '$', '_', '0'...'9' => continue :state .private_identifier,
                '\\' => if (parseUnicodeEscapeSequence(t.source[t.index..])) |parsed| {
                    t.index += parsed.len - 1;
                    continue :state .private_identifier;
                },
                0x80...0xFF => if (parseCodePoint(t.source[t.index..])) |parsed| {
                    if (canCodePointContinueId(parsed.code_point)) {
                        t.index += parsed.len - 1;
                        continue :state .private_identifier;
                    }
                },
                else => {},
            }
            tag = .private_identifier;
        },
        .identifier_name => {
            t.index += 1;
            switch (t.source[t.index]) {
                'a'...'z', 'A'...'Z', '$', '_', '0'...'9' => continue :state .identifier_name,
                '\\' => if (parseUnicodeEscapeSequence(t.source[t.index..])) |parsed| {
                    t.index += parsed.len - 1;
                    continue :state .identifier_name;
                },
                0x80...0xFF => if (parseCodePoint(t.source[t.index..])) |parsed| {
                    if (canCodePointContinueId(parsed.code_point)) {
                        t.index += parsed.len - 1;
                        continue :state .identifier_name;
                    }
                },
                else => {},
            }
            const identifier_name = t.source[start..t.index];
            // A keyword cannot contain a UnicodeEscapeSequence, so an identifier name with an
            // escape is always an identifier.
            if (std.mem.findScalar(u8, identifier_name, '\\') == null) {
                tag = keywords.get(identifier_name) orelse .identifier;
            } else {
                tag = .identifier;
            }
        },
        .numeric_literal => {
            std.debug.assert(std.ascii.isDigit(t.source[t.index]) or t.source[t.index] == '.');
            var consumed: u32 = undefined;
            if (NumericLiteral.parse(t.source[t.index..], &consumed)) |literal| {
                tag = switch (literal.kind) {
                    .number => .number_literal,
                    .big_int => .bigint_literal,
                };
            } else {
                tag = .invalid;
            }
            t.index += consumed;
        },
        .string_literal => {
            std.debug.assert(t.source[t.index] == '"' or t.source[t.index] == '\'');
            var consumed: u32 = undefined;
            if (StringLiteral.parse(t.source[t.index..], &consumed)) |_| {
                tag = .string_literal;
            } else {
                tag = .invalid;
            }
            t.index += consumed;
        },
        .regexp_literal => {
            std.debug.assert(t.source[t.index] == '/');
            if (RegExpLiteral.parse(t.source[t.index..])) |literal| {
                t.index += @intCast(literal.text.len);
                tag = .regexp_literal;
            } else {
                continue :state .slash_operator;
            }
        },
        .template_literal => {
            std.debug.assert(t.source[t.index] == '`' or t.source[t.index] == '}');
            var consumed: u32 = undefined;
            if (Template.parse(t.source[t.index..], &consumed)) |template| {
                switch (template.kind()) {
                    .no_substitution => tag = .template_literal,
                    .head => {
                        try t.template_stack.append(t.gpa, 0);
                        tag = .template_literal_head;
                    },
                    .middle => {
                        const depth = t.template_stack.getLast();
                        std.debug.assert(depth == 0);
                        tag = .template_literal_middle;
                    },
                    .tail => {
                        _ = t.template_stack.pop().?;
                        tag = .template_literal_tail;
                    },
                }
            } else {
                tag = .invalid;
            }
            t.index += consumed;
        },
        .multi_byte_whitespace_or_line_terminator => {
            // This could probably be a bit faster than linear search, but these are the non-ASCII
            // edge cases so it doesn't matter a whole lot.
            const needles = multi_byte_whitespace ++ multi_byte_line_terminators;
            for (&needles) |needle| {
                if (std.mem.startsWith(u8, t.source[t.index..], needle)) {
                    t.index += @intCast(needle.len);
                    start = t.index;
                    continue :state .start;
                }
            }
            // These leading bytes also prefix valid identifier starts (e.g. U+1E00), so fall back
            // to the identifier check before giving up.
            if (parseCodePoint(t.source[t.index..])) |parsed| {
                if (canCodePointStartId(parsed.code_point)) {
                    t.index += parsed.len - 1;
                    continue :state .identifier_name;
                }
            }
            t.index += 1;
            tag = .invalid;
        },
    }
    const token: Token = .{
        .tag = tag,
        .start = @fromBackingInt(start),
        .end = @fromBackingInt(t.index),
    };
    switch (tag) {
        .line_comment,
        .multiline_comment,
        .html_open_comment,
        .html_close_comment,
        .hashbang_comment,
        => {},
        else => try t.updateState(token),
    }
    return token;
}

fn updateState(t: *Tokenizer, token: Token) std.mem.Allocator.Error!void {
    const operand_expected, const context: ?Context = if (t.token_window[1]) |prev_token| switch (token.tag) {
        // A `{` may be a block or an object literal, recorded for the matching `}`.
        .left_curly_bracket => .{ true, .{
            .tag = .left_curly_bracket,
            .is_expr = t.curlyBracketIsExpr(token.start),
        } },
        // A `(` after a control flow keyword is a statement head, otherwise it starts an expression
        // or a parameter list.
        .left_parenthesis => .{ true, .{
            .tag = .left_parenthesis,
            .is_expr = switch (prev_token.tag) {
                .keyword_catch,
                .keyword_for,
                .keyword_if,
                .keyword_switch,
                .keyword_while,
                .keyword_with,
                => false,
                .keyword_await => if (t.token_window[0]) |prev_prev_token|
                    prev_prev_token.tag != .keyword_for
                else
                    true,
                else => true,
            },
        } },
        // After `}`, an operand is expected when the braces were a block or a declaration's body,
        // because a statement follows. It is not expected when they were an object literal or a
        // function/class expression, which are operands themselves.
        .right_curly_bracket => blk: {
            const context = t.context_stack.pop() orelse break :blk .{ true, null };
            var operand_expected = !context.is_expr;
            if (t.context_stack.getLastOrNull()) |parent| {
                if (parent.tag == .keyword_function) {
                    _ = t.context_stack.pop().?;
                    operand_expected = !parent.is_expr;
                }
            }
            break :blk .{ operand_expected, null };
        },
        // After `)`, an operand is expected only if the parens were a statement head like
        // `if (cond)`. A parenthesized expression like `(a)` is itself an operand.
        .right_parenthesis => blk: {
            const context = t.context_stack.pop() orelse break :blk .{ true, null };
            const operand_expected = !context.is_expr;
            break :blk .{ operand_expected, null };
        },
        // A `function`/`class` keyword pushes a `keyword_function` context, marking its body's `{`
        // as a block rather than an object literal. The context's `is_expr` records whether the
        // function/class is an expression, which sets the operand state after the body's `}`.
        .keyword_function, .keyword_class => .{ false, .{
            .tag = .keyword_function,
            .is_expr = t.functionIsExpr(token.start),
        } },
        // A `:` means the preceding `function`/`class` was a property name, not a function/class,
        // so its `keyword_function` context is popped.
        .colon => blk: {
            if (t.context_stack.getLastOrNull()) |parent| {
                if (parent.tag == .keyword_function) {
                    _ = t.context_stack.pop().?;
                }
            }
            break :blk .{ true, null };
        },
        // An identifier ends an operand. The exception is `of` in a `for ... of`, which expects the
        // next operand when the previous token ended an operand. After `.`/`?.` it is a property
        // name, so the exception does not apply.
        .identifier => blk: {
            const operand_expected = switch (prev_token.tag) {
                .period, .question_mark_period => false,
                else => std.mem.eql(u8, t.source[@backingInt(token.start)..t.index], "of") and !t.operand_expected,
            };
            break :blk .{ operand_expected, null };
        },
        // Any other token derives `operand_expected` from its own tag, except after a property
        // access.
        else => blk: {
            const operand_expected = switch (prev_token.tag) {
                .period, .question_mark_period => !token.tag.isKeyword() and token.tag.beforeExpr(),
                else => token.tag.beforeExpr(),
            };
            break :blk .{ operand_expected, null };
        },
    } else switch (token.tag) {
        // A leading `{` is always a block, never an object literal.
        .left_curly_bracket => .{ true, .{
            .tag = .left_curly_bracket,
            .is_expr = false,
        } },
        // A leading `(` is always an expression.
        .left_parenthesis => .{ true, .{
            .tag = .left_parenthesis,
            .is_expr = true,
        } },
        // A leading `}`, `)`, or `:` expects an operand.
        .right_curly_bracket, .right_parenthesis, .colon => .{ true, null },
        // A leading `function`/`class` is a declaration, not an expression.
        .keyword_function, .keyword_class => .{ false, .{
            .tag = .keyword_function,
            .is_expr = false,
        } },
        // A leading identifier is itself an operand, so no operand is expected after it.
        .identifier => .{ false, null },
        else => .{ token.tag.beforeExpr(), null },
    };
    t.token_window[0] = t.token_window[1];
    t.token_window[1] = token;
    t.operand_expected = operand_expected;
    if (context) |c| try t.context_stack.append(t.gpa, c);
}

fn curlyBracketIsExpr(t: *const Tokenizer, start: Token.ByteOffset) bool {
    const prev_token = t.token_window[1] orelse return false;
    if (t.context_stack.getLastOrNull()) |parent| {
        if (parent.tag == .keyword_function) return false;
    }
    return switch (prev_token.tag) {
        .colon, .left_curly_bracket => if (t.context_stack.getLastOrNull()) |parent|
            parent.tag != .left_curly_bracket or parent.is_expr
        else
            false,
        .keyword_return => findLineTerminator(t.source[@backingInt(prev_token.end)..@backingInt(start)]) == null,
        .keyword_do,
        .keyword_else,
        .keyword_finally,
        .keyword_try,
        .right_curly_bracket,
        .right_parenthesis,
        .semicolon,
        .equals_greater_than,
        => false,
        .identifier => true,
        else => t.operand_expected,
    };
}

fn functionIsExpr(t: *const Tokenizer, start: Token.ByteOffset) bool {
    const prev_token = t.token_window[1] orelse return false;
    return switch (prev_token.tag) {
        .colon, .left_curly_bracket => if (t.context_stack.getLastOrNull()) |parent|
            parent.tag != .left_curly_bracket
        else
            true,
        .keyword_return => findLineTerminator(t.source[@backingInt(prev_token.end)..@backingInt(start)]) == null,
        .keyword_else => false,
        .semicolon => if (t.context_stack.getLastOrNull()) |parent|
            parent.tag == .left_parenthesis and !parent.is_expr
        else
            false,
        else => prev_token.tag.beforeExpr(),
    };
}

fn writeCodeUnit(w: *std.Io.Writer, code_unit: u16) std.Io.Writer.Error!void {
    var buffer: [3]u8 = undefined;
    const len = std.unicode.wtf8Encode(code_unit, &buffer) catch unreachable;
    try w.writeAll(buffer[0..len]);
}

fn writeCodePoint(w: *std.Io.Writer, code_point: u21) std.Io.Writer.Error!void {
    var buffer: [4]u8 = undefined;
    const len = std.unicode.wtf8Encode(code_point, &buffer) catch unreachable;
    try w.writeAll(buffer[0..len]);
}

const CodePoint = struct {
    code_point: u21,
    len: u32,
};

fn parseCodePoint(source: []const u8) ?CodePoint {
    if (source.len == 0) return null;
    switch (source[0]) {
        '\\' => return parseUnicodeEscapeSequence(source),
        0x80...0xFF => |c| {
            const len = std.unicode.utf8ByteSequenceLength(c) catch return null;
            if (source.len < len) return null;
            const code_point = std.unicode.wtf8Decode(source[0..len]) catch return null;
            return .{ .code_point = code_point, .len = @intCast(len) };
        },
        else => |c| return .{ .code_point = c, .len = 1 },
    }
}

const LegacyOctalEscape = struct {
    code_point: u8,
    /// 2...4
    len: u3,
};

/// https://tc39.es/ecma262/#prod-LegacyOctalEscapeSequence
fn parseLegacyOctalEscapeSequence(source: []const u8) ?LegacyOctalEscape {
    if (source.len < 2 or source[0] != '\\') return null;
    var code_point: u8 = 0;
    var i: u3 = 1;
    while (i < source.len and i < 4) : (i += 1) {
        const c = source[i];
        if (c < '0' or c > '7') break;
        code_point = std.math.mul(u8, code_point, 8) catch break;
        code_point += c - '0';
    }
    if (i == 1) return null;
    if (i == 2 and code_point == 0) return null;
    return .{ .code_point = code_point, .len = i };
}

/// https://tc39.es/ecma262/#prod-HexEscapeSequence
fn parseHexEscapeSequence(source: []const u8) ?u8 {
    if (source.len < 4 or source[0] != '\\' or source[1] != 'x') return null;
    return parseDigits(u8, source[2..4], 16) catch return null;
}

/// https://tc39.es/ecma262/#prod-UnicodeEscapeSequence
fn parseUnicodeEscapeSequence(source: []const u8) ?CodePoint {
    if (source.len < 3 or source[0] != '\\' or source[1] != 'u') return null;
    if (source[2] == '{') {
        const len = std.mem.findScalar(u8, source[3..], '}') orelse return null;
        if (len == 0) return null;
        const digits = source[3..][0..len];
        const code_point = parseDigits(u21, digits, 16) catch return null;
        if (code_point > 0x10FFFF) return null;
        return .{ .code_point = code_point, .len = @intCast(len + 4) };
    } else {
        if (source.len < 6) return null;
        const digits = source[2..6];
        const code_point = parseDigits(u16, digits, 16) catch return null;
        return .{ .code_point = code_point, .len = 6 };
    }
}

/// https://tc39.es/ecma262/#prod-IdentifierStartChar
fn canCodePointStartId(code_point: u21) bool {
    return code_point == '$' or code_point == '_' or unicode_id.canStartId(code_point);
}

/// https://tc39.es/ecma262/#prod-IdentifierPartChar
fn canCodePointContinueId(code_point: u21) bool {
    return code_point == '$' or unicode_id.canContinueId(code_point);
}

/// 12.2 White Space
/// https://tc39.es/ecma262/#sec-white-space
pub const single_byte_whitespace = [_]u8{
    0x09, // <TAB>
    0x0B, // <VT>
    0x0C, // <FF>
    0x20, // <USP>
};

/// 12.2 White Space
/// https://tc39.es/ecma262/#sec-white-space
pub const multi_byte_whitespace = [_][]const u8{
    "\u{00A0}",
    "\u{1680}",
    "\u{2000}",
    "\u{2001}",
    "\u{2002}",
    "\u{2003}",
    "\u{2004}",
    "\u{2005}",
    "\u{2006}",
    "\u{2007}",
    "\u{2008}",
    "\u{2009}",
    "\u{200A}",
    "\u{202F}",
    "\u{205F}",
    "\u{3000}",
    "\u{FEFF}",
};

/// 12.3 Line Terminators
/// https://tc39.es/ecma262/#sec-line-terminators
pub const single_byte_line_terminators = [_]u8{
    0x0A, // <LF>
    0x0D, // <CR>
};

/// 12.3 Line Terminators
/// https://tc39.es/ecma262/#sec-line-terminators
pub const multi_byte_line_terminators = [_][]const u8{
    "\u{2028}",
    "\u{2029}",
};

pub fn findLineTerminator(source: []const u8) ?u32 {
    var i: u32 = 0;
    while (std.mem.findAny(u8, source[i..], "\n\r\xE2")) |offset| : (i += 1) {
        i += @intCast(offset);
        if (source[i] != 0xE2) return i;
        for (multi_byte_line_terminators) |terminator| {
            if (std.mem.startsWith(u8, source[i..], terminator)) return i;
        }
    }
    return null;
}

pub fn lineTerminatorLen(source: []const u8) ?u2 {
    if (source.len == 0) return null;
    switch (source[0]) {
        '\n' => return 1,
        '\r' => return if (source.len >= 2 and source[1] == '\n') 2 else 1,
        0xE2 => for (multi_byte_line_terminators) |terminator| {
            if (std.mem.startsWith(u8, source, terminator)) {
                return @intCast(terminator.len);
            }
        },
        else => {},
    }
    return null;
}

/// 12.7.1 Identifier Names
/// https://tc39.es/ecma262/#sec-identifier-names
pub const IdentifierName = struct {
    text: []const u8,

    /// 12.9.4.2 Static Semantics: SV
    /// https://tc39.es/ecma262/#sec-static-semantics-sv
    ///
    /// Writes UTF-8 encoded bytes.
    pub fn value(id: *const IdentifierName, w: *std.Io.Writer) std.Io.Writer.Error!bool {
        if (std.mem.findScalar(u8, id.text, '\\') == null) {
            try w.writeAll(id.text);
            return true;
        }
        var i: u32 = 0;
        while (i < id.text.len) {
            const parsed = parseCodePoint(id.text[i..]) orelse return false;
            const valid = if (i == 0)
                canCodePointStartId(parsed.code_point)
            else
                canCodePointContinueId(parsed.code_point);
            if (!valid) return false;
            try writeCodePoint(w, parsed.code_point);
            i += parsed.len;
        }
        return true;
    }

    pub fn validate(id: *const IdentifierName) bool {
        var dw: std.Io.Writer.Discarding = .init(&.{});
        return id.value(&dw.writer) catch unreachable;
    }
};

/// 12.7.2 Keywords and Reserved Words
/// https://tc39.es/ecma262/#sec-keywords-and-reserved-words
const keywords: std.StaticStringMap(Token.Tag) = .initComptime(.{
    .{ "await", .keyword_await },
    .{ "break", .keyword_break },
    .{ "case", .keyword_case },
    .{ "catch", .keyword_catch },
    .{ "class", .keyword_class },
    .{ "const", .keyword_const },
    .{ "continue", .keyword_continue },
    .{ "debugger", .keyword_debugger },
    .{ "default", .keyword_default },
    .{ "delete", .keyword_delete },
    .{ "do", .keyword_do },
    .{ "else", .keyword_else },
    .{ "enum", .keyword_enum },
    .{ "export", .keyword_export },
    .{ "extends", .keyword_extends },
    .{ "false", .keyword_false },
    .{ "finally", .keyword_finally },
    .{ "for", .keyword_for },
    .{ "function", .keyword_function },
    .{ "if", .keyword_if },
    .{ "import", .keyword_import },
    .{ "in", .keyword_in },
    .{ "instanceof", .keyword_instanceof },
    .{ "new", .keyword_new },
    .{ "null", .keyword_null },
    .{ "return", .keyword_return },
    .{ "super", .keyword_super },
    .{ "switch", .keyword_switch },
    .{ "this", .keyword_this },
    .{ "throw", .keyword_throw },
    .{ "true", .keyword_true },
    .{ "try", .keyword_try },
    .{ "typeof", .keyword_typeof },
    .{ "var", .keyword_var },
    .{ "void", .keyword_void },
    .{ "while", .keyword_while },
    .{ "with", .keyword_with },
    .{ "yield", .keyword_yield },
});

/// 12.9.3 Numeric Literals
/// https://tc39.es/ecma262/#sec-literals-numeric-literals
pub const NumericLiteral = struct {
    text: []const u8,
    kind: Kind,
    base: Base,

    pub const Kind = enum {
        number,
        big_int,
    };

    pub const Base = enum(u8) {
        binary = 2,
        octal = 8,
        decimal = 10,
        hexadecimal = 16,

        fn isValidDigit(base: Base, c: u8) bool {
            _ = std.fmt.charToDigit(c, @backingInt(base)) catch return false;
            return true;
        }
    };

    pub fn parse(source: []const u8, consumed: *u32) ?NumericLiteral {
        var i: u32 = 0;
        defer consumed.* = i;
        var base: Base = .decimal;

        const State = enum {
            start,
            zero,
            decimal_integer,
            legacy_octal,
            non_octal_decimal,
            radix_prefix,
            radix_digits,
            fraction_period,
            fraction_digits,
            fraction_separator,
            exponent_indicator,
            exponent_sign,
            exponent_digits,
            exponent_separator,
            decimal_separator,
            radix_separator,
        };
        var state: State = .start;
        const kind: Kind = while (i < source.len) : (i += 1) {
            const c = source[i];
            switch (state) {
                .start => switch (c) {
                    '0' => state = .zero,
                    '1'...'9' => state = .decimal_integer,
                    '.' => state = .fraction_period,
                    else => return null,
                },
                .zero => switch (c) {
                    'x', 'X' => {
                        base = .hexadecimal;
                        state = .radix_prefix;
                    },
                    'o', 'O' => {
                        base = .octal;
                        state = .radix_prefix;
                    },
                    'b', 'B' => {
                        base = .binary;
                        state = .radix_prefix;
                    },
                    'n' => {
                        i += 1;
                        break .big_int;
                    },
                    '.' => state = .fraction_period,
                    'e', 'E' => state = .exponent_indicator,
                    '0'...'7' => {
                        base = .octal;
                        state = .legacy_octal;
                    },
                    '8', '9' => state = .non_octal_decimal,
                    else => break .number,
                },
                .decimal_integer => switch (c) {
                    '0'...'9' => state = .decimal_integer,
                    '_' => state = .decimal_separator,
                    '.' => state = .fraction_period,
                    'e', 'E' => state = .exponent_indicator,
                    'n' => {
                        i += 1;
                        break .big_int;
                    },
                    else => break .number,
                },
                .decimal_separator => switch (c) {
                    '0'...'9' => state = .decimal_integer,
                    else => return null,
                },
                .legacy_octal => switch (c) {
                    '0'...'7' => state = .legacy_octal,
                    '8', '9' => {
                        base = .decimal;
                        state = .non_octal_decimal;
                    },
                    else => break .number,
                },
                .non_octal_decimal => switch (c) {
                    '0'...'9' => state = .non_octal_decimal,
                    '.' => state = .fraction_period,
                    'e', 'E' => state = .exponent_indicator,
                    else => break .number,
                },
                .radix_prefix => switch (c) {
                    '0'...'9', 'a'...'f', 'A'...'F' => {
                        if (base.isValidDigit(c)) {
                            state = .radix_digits;
                        } else {
                            break .number;
                        }
                    },
                    else => return null,
                },
                .radix_digits => switch (c) {
                    '0'...'9', 'a'...'f', 'A'...'F' => {
                        if (base.isValidDigit(c)) {
                            state = .radix_digits;
                        } else {
                            break .number;
                        }
                    },
                    '_' => state = .radix_separator,
                    'n' => {
                        i += 1;
                        break .big_int;
                    },
                    else => break .number,
                },
                .radix_separator => switch (c) {
                    '0'...'9', 'a'...'f', 'A'...'F' => {
                        if (base.isValidDigit(c)) {
                            state = .radix_digits;
                        } else {
                            break .number;
                        }
                    },
                    else => return null,
                },
                .fraction_period => switch (c) {
                    '0'...'9' => state = .fraction_digits,
                    'e', 'E' => state = .exponent_indicator,
                    else => break .number,
                },
                .fraction_digits => switch (c) {
                    '0'...'9' => state = .fraction_digits,
                    '_' => state = .fraction_separator,
                    'e', 'E' => state = .exponent_indicator,
                    else => break .number,
                },
                .fraction_separator => switch (c) {
                    '0'...'9' => state = .fraction_digits,
                    else => return null,
                },
                .exponent_indicator => switch (c) {
                    '+', '-' => state = .exponent_sign,
                    '0'...'9' => state = .exponent_digits,
                    else => return null,
                },
                .exponent_sign => switch (c) {
                    '0'...'9' => state = .exponent_digits,
                    else => return null,
                },
                .exponent_digits => switch (c) {
                    '0'...'9' => state = .exponent_digits,
                    '_' => state = .exponent_separator,
                    else => break .number,
                },
                .exponent_separator => switch (c) {
                    '0'...'9' => state = .exponent_digits,
                    else => return null,
                },
            }
        } else switch (state) {
            .start => unreachable,
            .radix_prefix,
            .radix_separator,
            .decimal_separator,
            .fraction_separator,
            .exponent_indicator,
            .exponent_sign,
            .exponent_separator,
            => return null,
            else => .number,
        };
        // "The SourceCharacter immediately following a NumericLiteral must not be an
        // IdentifierStart or DecimalDigit."
        if (i < source.len) {
            const is_identifier_start = if (parseCodePoint(source[i..])) |parsed|
                canCodePointStartId(parsed.code_point)
            else
                false;
            if (std.ascii.isDigit(source[i]) or is_identifier_start) {
                while (i < source.len) {
                    const parsed = parseCodePoint(source[i..]) orelse break;
                    if (!canCodePointContinueId(parsed.code_point)) break;
                    i += parsed.len;
                }
                return null;
            }
        }
        return .{ .text = source[0..i], .base = base, .kind = kind };
    }

    /// 12.9.3.3 Static Semantics: NumericValue
    /// https://tc39.es/ecma262/#sec-numericvalue
    pub fn numberValue(l: *const NumericLiteral, gpa: std.mem.Allocator) std.mem.Allocator.Error!f64 {
        std.debug.assert(std.ascii.isDigit(l.text[0]) or l.text[0] == '.');
        const start: u32 = switch (l.base) {
            .decimal => 0,
            .octal => if (l.text.len >= 2 and (l.text[1] == 'o' or l.text[1] == 'O')) 2 else 1,
            .binary, .hexadecimal => 2,
        };
        return switch (l.base) {
            .decimal => std.fmt.parseFloat(f64, l.text[start..]) catch unreachable,
            else => blk: {
                var managed = try std.math.big.int.Managed.init(gpa);
                defer managed.deinit();
                managed.setString(@backingInt(l.base), l.text[start..]) catch |err| switch (err) {
                    error.InvalidBase, error.InvalidCharacter => unreachable,
                    error.OutOfMemory => |e| return e,
                };
                break :blk managed.toFloat(f64, .nearest_even)[0];
            },
        };
    }

    /// 12.9.3.3 Static Semantics: NumericValue
    /// https://tc39.es/ecma262/#sec-numericvalue
    pub fn bigIntValue(l: *const NumericLiteral, gpa: std.mem.Allocator) std.mem.Allocator.Error!std.math.big.int.Managed {
        std.debug.assert(l.text[l.text.len - 1] == 'n');
        const start: u32 = switch (l.base) {
            .decimal => 0,
            .octal, .binary, .hexadecimal => 2,
        };
        var managed = try std.math.big.int.Managed.init(gpa);
        errdefer managed.deinit();
        managed.setString(@backingInt(l.base), l.text[start .. l.text.len - 1]) catch |err| switch (err) {
            error.InvalidBase, error.InvalidCharacter => unreachable,
            error.OutOfMemory => |e| return e,
        };
        return managed;
    }
};

/// 12.9.4 String Literals
/// https://tc39.es/ecma262/#sec-literals-string-literals
pub const StringLiteral = struct {
    text: []const u8,

    pub fn parse(source: []const u8, consumed: *u32) ?StringLiteral {
        const quote = source[0];
        var i: u32 = 1;

        const State = enum {
            start,
            escape,
        };
        var state: State = .start;
        while (i < source.len) : (i += 1) {
            const c = source[i];
            switch (state) {
                .start => switch (c) {
                    '\\' => state = .escape,
                    '\n', '\r' => {
                        consumed.* = i;
                        return null;
                    },
                    else => {
                        if (c == quote) {
                            consumed.* = i + 1;
                            return .{ .text = source[0 .. i + 1] };
                        }
                        state = .start;
                    },
                },
                .escape => {
                    if (lineTerminatorLen(source[i..])) |len| {
                        i += len - 1;
                    }
                    state = .start;
                },
            }
        }
        consumed.* = @intCast(source.len);
        return null;
    }

    /// 12.9.4.2 Static Semantics: SV
    /// https://tc39.es/ecma262/#sec-static-semantics-sv
    ///
    /// Writes WTF-8 encoded bytes.
    pub fn value(l: *const StringLiteral, w: *std.Io.Writer) std.Io.Writer.Error!bool {
        std.debug.assert(l.text[0] == '"' or l.text[0] == '\'');
        std.debug.assert(l.text[0] == l.text[l.text.len - 1]);
        const str = l.text[1 .. l.text.len - 1];
        // We can skip the loop if there are no escapes or line terminators
        if (std.mem.findAny(u8, str, "\\\n\r\xE2") == null) {
            try w.writeAll(str);
            return true;
        }
        var i: u32 = 0;
        while (i < str.len) : (i += 1) {
            const c = str[i];
            if (c != '\\') {
                const parsed = parseCodePoint(str[i..]) orelse return false;
                try writeCodePoint(w, parsed.code_point);
                i += parsed.len - 1;
                continue;
            }
            const escape = str[i + 1];
            switch (escape) {
                'b' => {
                    try writeCodeUnit(w, 0x08);
                    i += 1;
                },
                't' => {
                    try writeCodeUnit(w, 0x09);
                    i += 1;
                },
                'n' => {
                    try writeCodeUnit(w, 0x0A);
                    i += 1;
                },
                'v' => {
                    try writeCodeUnit(w, 0x0B);
                    i += 1;
                },
                'f' => {
                    try writeCodeUnit(w, 0x0C);
                    i += 1;
                },
                'r' => {
                    try writeCodeUnit(w, 0x0D);
                    i += 1;
                },
                '"' => {
                    try writeCodeUnit(w, '"');
                    i += 1;
                },
                '\'' => {
                    try writeCodeUnit(w, '\'');
                    i += 1;
                },
                '\\' => {
                    try writeCodeUnit(w, '\\');
                    i += 1;
                },
                '8', '9' => {
                    try writeCodeUnit(w, escape);
                    i += 1;
                },
                '0'...'7' => {
                    if (parseLegacyOctalEscapeSequence(str[i..])) |parsed| {
                        try writeCodeUnit(w, parsed.code_point);
                        i += parsed.len - 1;
                    } else {
                        std.debug.assert(str[i + 1] == '0');
                        try writeCodeUnit(w, 0x00);
                        i += 1;
                    }
                },
                'x' => {
                    const byte = parseHexEscapeSequence(str[i..]) orelse return false;
                    try writeCodeUnit(w, byte);
                    i += 3;
                },
                'u' => {
                    const parsed = parseUnicodeEscapeSequence(str[i..]) orelse return false;
                    try writeCodePoint(w, parsed.code_point);
                    i += parsed.len - 1;
                },
                else => {
                    if (lineTerminatorLen(str[i + 1 ..])) |len| {
                        i += len;
                    } else if (parseCodePoint(str[i + 1 ..])) |parsed| {
                        try writeCodePoint(w, parsed.code_point);
                        i += parsed.len;
                    } else {
                        return false;
                    }
                },
            }
        }
        return true;
    }

    pub fn validate(l: *const StringLiteral) bool {
        var dw: std.Io.Writer.Discarding = .init(&.{});
        return l.value(&dw.writer) catch unreachable;
    }
};

/// 12.9.5 Regular Expression Literals
/// https://tc39.es/ecma262/#sec-literals-regular-expression-literals
pub const RegExpLiteral = struct {
    text: []const u8,

    pub fn parse(source: []const u8) ?RegExpLiteral {
        var i: u32 = 1;

        const State = enum {
            chars,
            escape,
            character_class,
            character_class_escape,
        };
        var state: State = .chars;
        while (i < source.len) : (i += 1) {
            const c = source[i];
            // RegularExpressionNonTerminator :: SourceCharacter but not LineTerminator
            if (lineTerminatorLen(source[i..])) |_| return null;
            switch (state) {
                .chars => switch (c) {
                    '\\' => state = .escape,
                    '[' => state = .character_class,
                    '/' => {
                        i += 1;
                        // https://tc39.es/ecma262/#prod-RegularExpressionFlags
                        while (parseCodePoint(source[i..])) |parsed| : (i += parsed.len) {
                            if (parsed.code_point != '$' and !unicode_id.canContinueId(parsed.code_point)) break;
                        }
                        return .{ .text = source[0..i] };
                    },
                    else => state = .chars,
                },
                .escape => state = .chars,
                .character_class => switch (c) {
                    '\\' => state = .character_class_escape,
                    ']' => state = .chars,
                    else => state = .character_class,
                },
                .character_class_escape => state = .character_class,
            }
        }
        return null;
    }

    pub fn pattern(l: *const RegExpLiteral) []const u8 {
        std.debug.assert(l.text[0] == '/');
        const closing_slash = std.mem.lastIndexOfScalar(u8, l.text, '/').?;
        return l.text[1..closing_slash];
    }

    pub fn flags(l: *const RegExpLiteral) []const u8 {
        std.debug.assert(l.text[0] == '/');
        const closing_slash = std.mem.lastIndexOfScalar(u8, l.text, '/').?;
        return l.text[closing_slash + 1 ..];
    }
};

/// 12.9.6 Template Literal Lexical Components
/// https://tc39.es/ecma262/#sec-template-literal-lexical-components
pub const Template = struct {
    text: []const u8,

    pub const Kind = enum {
        no_substitution,
        head,
        middle,
        tail,
    };

    fn characters(t: *const Template) []const u8 {
        const end = switch (t.kind()) {
            .no_substitution, .tail => t.text.len - 1,
            .head, .middle => t.text.len - 2,
        };
        return t.text[1..end];
    }

    pub fn kind(t: *const Template) Kind {
        if (t.text[0] == '`') {
            return if (std.mem.endsWith(u8, t.text, "${")) .head else .no_substitution;
        } else {
            std.debug.assert(t.text[0] == '}');
            return if (std.mem.endsWith(u8, t.text, "${")) .middle else .tail;
        }
    }

    pub fn parse(source: []const u8, consumed: *u32) ?Template {
        var i: u32 = 1;
        while (i < source.len) : (i += 1) {
            switch (source[i]) {
                '`' => {
                    consumed.* = i + 1;
                    return .{ .text = source[0 .. i + 1] };
                },
                '$' => {
                    if (i + 1 < source.len and source[i + 1] == '{') {
                        consumed.* = i + 2;
                        return .{ .text = source[0 .. i + 2] };
                    }
                },
                '\\' => {
                    const escape = source[i..];
                    if (escape.len < 2) {
                        consumed.* = i;
                        return null;
                    }
                    const maybe_len: ?u32 = switch (escape[1]) {
                        'x' => if (parseHexEscapeSequence(escape)) |_| 4 else null,
                        'u' => if (parseUnicodeEscapeSequence(escape)) |parsed| parsed.len else null,
                        '0' => if (escape.len >= 3 and std.ascii.isDigit(escape[2])) null else 2,
                        '1'...'9' => null,
                        else => if (lineTerminatorLen(escape[1..])) |len| @as(u32, len) + 1 else 2,
                    };
                    if (maybe_len) |len| i += len - 1;
                },
                else => {},
            }
        }
        consumed.* = @intCast(source.len);
        return null;
    }

    /// 12.9.6.1 Static Semantics: TV
    /// https://tc39.es/ecma262/#sec-template-literal-lexical-components
    ///
    /// Writes WTF-8 encoded bytes.
    pub fn value(t: *const Template, w: *std.Io.Writer) std.Io.Writer.Error!bool {
        std.debug.assert(t.text[0] == '`' or t.text[0] == '}');
        const str = t.characters();
        // We can skip the loop if there are no escapes or line terminators
        if (std.mem.findAny(u8, str, "\\\n\r\xE2") == null) {
            try w.writeAll(str);
            return true;
        }
        var i: u32 = 0;
        while (i < str.len) : (i += 1) {
            const c = str[i];
            if (c == '\r') {
                // <CR> and <CR><LF> are normalized to <LF>
                try writeCodeUnit(w, '\n');
                i += if (i + 1 < str.len and str[i + 1] == '\n') 1 else 0;
                continue;
            }
            if (c != '\\') {
                const parsed = parseCodePoint(str[i..]) orelse return false;
                try writeCodePoint(w, parsed.code_point);
                i += parsed.len - 1;
                continue;
            }
            const escape = str[i + 1];
            switch (escape) {
                'b' => {
                    try writeCodeUnit(w, 0x08);
                    i += 1;
                },
                't' => {
                    try writeCodeUnit(w, 0x09);
                    i += 1;
                },
                'n' => {
                    try writeCodeUnit(w, 0x0A);
                    i += 1;
                },
                'v' => {
                    try writeCodeUnit(w, 0x0B);
                    i += 1;
                },
                'f' => {
                    try writeCodeUnit(w, 0x0C);
                    i += 1;
                },
                'r' => {
                    try writeCodeUnit(w, 0x0D);
                    i += 1;
                },
                '"' => {
                    try writeCodeUnit(w, '"');
                    i += 1;
                },
                '\'' => {
                    try writeCodeUnit(w, '\'');
                    i += 1;
                },
                '\\' => {
                    try writeCodeUnit(w, '\\');
                    i += 1;
                },
                '0' => {
                    if (i + 2 < str.len and std.ascii.isDigit(str[i + 2])) return false;
                    try writeCodeUnit(w, 0x00);
                    i += 1;
                },
                '1'...'9' => return false,
                'x' => {
                    const byte = parseHexEscapeSequence(str[i..]) orelse return false;
                    try writeCodeUnit(w, byte);
                    i += 3;
                },
                'u' => {
                    const parsed = parseUnicodeEscapeSequence(str[i..]) orelse return false;
                    try writeCodePoint(w, parsed.code_point);
                    i += parsed.len - 1;
                },
                else => {
                    if (lineTerminatorLen(str[i + 1 ..])) |len| {
                        i += len;
                    } else if (parseCodePoint(str[i + 1 ..])) |parsed| {
                        try writeCodePoint(w, parsed.code_point);
                        i += parsed.len;
                    } else {
                        return false;
                    }
                },
            }
        }
        return true;
    }

    /// 12.9.6.2 Static Semantics: TRV
    /// https://tc39.es/ecma262/#sec-static-semantics-trv
    ///
    /// Writes UTF-8 encoded bytes.
    pub fn rawValue(t: *const Template, w: *std.Io.Writer) std.Io.Writer.Error!bool {
        std.debug.assert(t.text[0] == '`' or t.text[0] == '}');
        const str = t.characters();
        // We can skip the loop if there are no line terminators
        if (std.mem.findAny(u8, str, "\n\r\xE2") == null) {
            try w.writeAll(str);
            return true;
        }
        var i: u32 = 0;
        while (i < str.len) : (i += 1) {
            const c = str[i];
            if (c == '\r') {
                // <CR> and <CR><LF> are normalized to <LF>
                try writeCodeUnit(w, '\n');
                i += if (i + 1 < str.len and str[i + 1] == '\n') 1 else 0;
                continue;
            }
            if (c != '\\') {
                const parsed = parseCodePoint(str[i..]) orelse return false;
                try writeCodePoint(w, parsed.code_point);
                i += parsed.len - 1;
                continue;
            }
            if (lineTerminatorLen(str[i + 1 ..])) |_| {
                try writeCodeUnit(w, '\\');
                i += 1;
                if (str[i] == '\r') {
                    // <CR> and <CR><LF> are normalized to <LF>
                    try writeCodeUnit(w, '\n');
                    i += if (i + 1 < str.len and str[i + 1] == '\n') 1 else 0;
                } else {
                    const parsed = parseCodePoint(str[i..]) orelse return false;
                    try writeCodePoint(w, parsed.code_point);
                    i += parsed.len - 1;
                }
            } else {
                try writeCodeUnit(w, '\\');
            }
        }
        return true;
    }

    pub fn validate(l: *const Template) bool {
        var dw: std.Io.Writer.Discarding = .init(&.{});
        return l.value(&dw.writer) catch unreachable;
    }
};

fn testTokenizer(source: [:0]const u8, expected_tokens: []const Token) !void {
    const gpa = std.testing.allocator;
    var tokens: std.ArrayList(Token) = .empty;
    defer tokens.deinit(gpa);
    var t: Tokenizer = .init(gpa, source);
    defer t.deinit();
    while (try t.next()) |token| {
        try tokens.append(gpa, token);
    }
    try std.testing.expectEqualSlices(Token, expected_tokens, tokens.items);
}

test "empty" {
    try testTokenizer("", &.{});
}

test "whitespace and line terminators" {
    // Single-byte whitespace
    try testTokenizer(" \t\x0B\x0C", &.{});
    // Multi-byte whitespace (U+00A0, U+1680, U+2000-U+200A, U+202F, U+205F, U+3000, U+3000, U+FEFF)
    try testTokenizer("\u{00A0}\u{1680}\u{2000}\u{2001}\u{2002}\u{2003}\u{2004}\u{2005}\u{2006}\u{2007}" ++
        "\u{2008}\u{2009}\u{200A}\u{202F}\u{205F}\u{3000}\u{FEFF}", &.{});
    // Line terminators
    try testTokenizer("\n\r\u{2028}\u{2029}", &.{});
}

test "comments" {
    try testTokenizer("//", &.{
        .{ .tag = .line_comment, .start = @fromBackingInt(0), .end = @fromBackingInt(2) },
    });
    try testTokenizer("// foo", &.{
        .{ .tag = .line_comment, .start = @fromBackingInt(0), .end = @fromBackingInt(6) },
    });
    try testTokenizer("foo // foo", &.{
        .{ .tag = .identifier, .start = @fromBackingInt(0), .end = @fromBackingInt(3) },
        .{ .tag = .line_comment, .start = @fromBackingInt(4), .end = @fromBackingInt(10) },
    });
    try testTokenizer("/**/", &.{
        .{ .tag = .multiline_comment, .start = @fromBackingInt(0), .end = @fromBackingInt(4) },
    });
    try testTokenizer("/* foo */", &.{
        .{ .tag = .multiline_comment, .start = @fromBackingInt(0), .end = @fromBackingInt(9) },
    });
    try testTokenizer("foo /* foo */", &.{
        .{ .tag = .identifier, .start = @fromBackingInt(0), .end = @fromBackingInt(3) },
        .{ .tag = .multiline_comment, .start = @fromBackingInt(4), .end = @fromBackingInt(13) },
    });
    try testTokenizer("<!--", &.{
        .{ .tag = .html_open_comment, .start = @fromBackingInt(0), .end = @fromBackingInt(4) },
    });
    try testTokenizer("<!-- foo", &.{
        .{ .tag = .html_open_comment, .start = @fromBackingInt(0), .end = @fromBackingInt(8) },
    });
    try testTokenizer("foo <!-- foo", &.{
        .{ .tag = .identifier, .start = @fromBackingInt(0), .end = @fromBackingInt(3) },
        .{ .tag = .html_open_comment, .start = @fromBackingInt(4), .end = @fromBackingInt(12) },
    });
    try testTokenizer("\n-->", &.{
        .{ .tag = .html_close_comment, .start = @fromBackingInt(1), .end = @fromBackingInt(4) },
    });
    try testTokenizer("\n--> foo", &.{
        .{ .tag = .html_close_comment, .start = @fromBackingInt(1), .end = @fromBackingInt(8) },
    });
    try testTokenizer("#!/usr/bin/env kiesel", &.{
        .{ .tag = .hashbang_comment, .start = @fromBackingInt(0), .end = @fromBackingInt(21) },
    });
    // A line terminator ends a single-line comment
    try testTokenizer("// foo\nbar", &.{
        .{ .tag = .line_comment, .start = @fromBackingInt(0), .end = @fromBackingInt(6) },
        .{ .tag = .identifier, .start = @fromBackingInt(7), .end = @fromBackingInt(10) },
    });
    try testTokenizer("// foo\u{2028}bar", &.{
        .{ .tag = .line_comment, .start = @fromBackingInt(0), .end = @fromBackingInt(6) },
        .{ .tag = .identifier, .start = @fromBackingInt(9), .end = @fromBackingInt(12) },
    });
    try testTokenizer("// foo\u{2029}bar", &.{
        .{ .tag = .line_comment, .start = @fromBackingInt(0), .end = @fromBackingInt(6) },
        .{ .tag = .identifier, .start = @fromBackingInt(9), .end = @fromBackingInt(12) },
    });
    try testTokenizer("<!-- foo\nbar", &.{
        .{ .tag = .html_open_comment, .start = @fromBackingInt(0), .end = @fromBackingInt(8) },
        .{ .tag = .identifier, .start = @fromBackingInt(9), .end = @fromBackingInt(12) },
    });
    try testTokenizer("<!-- foo\u{2028}bar", &.{
        .{ .tag = .html_open_comment, .start = @fromBackingInt(0), .end = @fromBackingInt(8) },
        .{ .tag = .identifier, .start = @fromBackingInt(11), .end = @fromBackingInt(14) },
    });
    try testTokenizer("\n--> foo\nbar", &.{
        .{ .tag = .html_close_comment, .start = @fromBackingInt(1), .end = @fromBackingInt(8) },
        .{ .tag = .identifier, .start = @fromBackingInt(9), .end = @fromBackingInt(12) },
    });
    try testTokenizer("\n-->foo\u{2028}bar", &.{
        .{ .tag = .html_close_comment, .start = @fromBackingInt(1), .end = @fromBackingInt(7) },
        .{ .tag = .identifier, .start = @fromBackingInt(10), .end = @fromBackingInt(13) },
    });
    // An embedded null byte that is not the terminator must not end the comment
    try testTokenizer("/* \x00 */", &.{
        .{ .tag = .multiline_comment, .start = @fromBackingInt(0), .end = @fromBackingInt(7) },
    });
    try testTokenizer("// \x00foo\nbar", &.{
        .{ .tag = .line_comment, .start = @fromBackingInt(0), .end = @fromBackingInt(7) },
        .{ .tag = .identifier, .start = @fromBackingInt(8), .end = @fromBackingInt(11) },
    });
    try testTokenizer("/* foo", &.{
        .{ .tag = .invalid, .start = @fromBackingInt(0), .end = @fromBackingInt(6) },
    });
    try testTokenizer("/*/", &.{
        .{ .tag = .invalid, .start = @fromBackingInt(0), .end = @fromBackingInt(3) },
    });
    // A HTML close comment requires a line terminator before it
    try testTokenizer("foo -->", &.{
        .{ .tag = .identifier, .start = @fromBackingInt(0), .end = @fromBackingInt(3) },
        .{ .tag = .double_minus, .start = @fromBackingInt(4), .end = @fromBackingInt(6) },
        .{ .tag = .greater_than, .start = @fromBackingInt(6), .end = @fromBackingInt(7) },
    });
    try testTokenizer("foo /* */-->", &.{
        .{ .tag = .identifier, .start = @fromBackingInt(0), .end = @fromBackingInt(3) },
        .{ .tag = .multiline_comment, .start = @fromBackingInt(4), .end = @fromBackingInt(9) },
        .{ .tag = .double_minus, .start = @fromBackingInt(9), .end = @fromBackingInt(11) },
        .{ .tag = .greater_than, .start = @fromBackingInt(11), .end = @fromBackingInt(12) },
    });
    // Only valid at the very start of the source
    try testTokenizer(" #!", &.{
        .{ .tag = .invalid, .start = @fromBackingInt(1), .end = @fromBackingInt(2) },
        .{ .tag = .exclamation_mark, .start = @fromBackingInt(2), .end = @fromBackingInt(3) },
    });
}

test "identifiers" {
    try testTokenizer("foo bar $a _b c1 äöü", &.{
        .{ .tag = .identifier, .start = @fromBackingInt(0), .end = @fromBackingInt(3) },
        .{ .tag = .identifier, .start = @fromBackingInt(4), .end = @fromBackingInt(7) },
        .{ .tag = .identifier, .start = @fromBackingInt(8), .end = @fromBackingInt(10) },
        .{ .tag = .identifier, .start = @fromBackingInt(11), .end = @fromBackingInt(13) },
        .{ .tag = .identifier, .start = @fromBackingInt(14), .end = @fromBackingInt(16) },
        .{ .tag = .identifier, .start = @fromBackingInt(17), .end = @fromBackingInt(23) },
    });
}

test "private identifiers" {
    try testTokenizer("#foo #bar #$a #_b #c1 #äöü", &.{
        .{ .tag = .private_identifier, .start = @fromBackingInt(0), .end = @fromBackingInt(4) },
        .{ .tag = .private_identifier, .start = @fromBackingInt(5), .end = @fromBackingInt(9) },
        .{ .tag = .private_identifier, .start = @fromBackingInt(10), .end = @fromBackingInt(13) },
        .{ .tag = .private_identifier, .start = @fromBackingInt(14), .end = @fromBackingInt(17) },
        .{ .tag = .private_identifier, .start = @fromBackingInt(18), .end = @fromBackingInt(21) },
        .{ .tag = .private_identifier, .start = @fromBackingInt(22), .end = @fromBackingInt(29) },
    });
    try testTokenizer("# #1", &.{
        .{ .tag = .invalid, .start = @fromBackingInt(0), .end = @fromBackingInt(1) },
        .{ .tag = .invalid, .start = @fromBackingInt(2), .end = @fromBackingInt(3) },
        .{ .tag = .number_literal, .start = @fromBackingInt(3), .end = @fromBackingInt(4) },
    });
}

test "keywords" {
    try testTokenizer("await break case catch class const continue debugger default delete do " ++
        "else enum export extends false finally for function if import in instanceof new null " ++
        "return super switch this throw true try typeof var void while with yield", &.{
        .{ .tag = .keyword_await, .start = @fromBackingInt(0), .end = @fromBackingInt(5) },
        .{ .tag = .keyword_break, .start = @fromBackingInt(6), .end = @fromBackingInt(11) },
        .{ .tag = .keyword_case, .start = @fromBackingInt(12), .end = @fromBackingInt(16) },
        .{ .tag = .keyword_catch, .start = @fromBackingInt(17), .end = @fromBackingInt(22) },
        .{ .tag = .keyword_class, .start = @fromBackingInt(23), .end = @fromBackingInt(28) },
        .{ .tag = .keyword_const, .start = @fromBackingInt(29), .end = @fromBackingInt(34) },
        .{ .tag = .keyword_continue, .start = @fromBackingInt(35), .end = @fromBackingInt(43) },
        .{ .tag = .keyword_debugger, .start = @fromBackingInt(44), .end = @fromBackingInt(52) },
        .{ .tag = .keyword_default, .start = @fromBackingInt(53), .end = @fromBackingInt(60) },
        .{ .tag = .keyword_delete, .start = @fromBackingInt(61), .end = @fromBackingInt(67) },
        .{ .tag = .keyword_do, .start = @fromBackingInt(68), .end = @fromBackingInt(70) },
        .{ .tag = .keyword_else, .start = @fromBackingInt(71), .end = @fromBackingInt(75) },
        .{ .tag = .keyword_enum, .start = @fromBackingInt(76), .end = @fromBackingInt(80) },
        .{ .tag = .keyword_export, .start = @fromBackingInt(81), .end = @fromBackingInt(87) },
        .{ .tag = .keyword_extends, .start = @fromBackingInt(88), .end = @fromBackingInt(95) },
        .{ .tag = .keyword_false, .start = @fromBackingInt(96), .end = @fromBackingInt(101) },
        .{ .tag = .keyword_finally, .start = @fromBackingInt(102), .end = @fromBackingInt(109) },
        .{ .tag = .keyword_for, .start = @fromBackingInt(110), .end = @fromBackingInt(113) },
        .{ .tag = .keyword_function, .start = @fromBackingInt(114), .end = @fromBackingInt(122) },
        .{ .tag = .keyword_if, .start = @fromBackingInt(123), .end = @fromBackingInt(125) },
        .{ .tag = .keyword_import, .start = @fromBackingInt(126), .end = @fromBackingInt(132) },
        .{ .tag = .keyword_in, .start = @fromBackingInt(133), .end = @fromBackingInt(135) },
        .{ .tag = .keyword_instanceof, .start = @fromBackingInt(136), .end = @fromBackingInt(146) },
        .{ .tag = .keyword_new, .start = @fromBackingInt(147), .end = @fromBackingInt(150) },
        .{ .tag = .keyword_null, .start = @fromBackingInt(151), .end = @fromBackingInt(155) },
        .{ .tag = .keyword_return, .start = @fromBackingInt(156), .end = @fromBackingInt(162) },
        .{ .tag = .keyword_super, .start = @fromBackingInt(163), .end = @fromBackingInt(168) },
        .{ .tag = .keyword_switch, .start = @fromBackingInt(169), .end = @fromBackingInt(175) },
        .{ .tag = .keyword_this, .start = @fromBackingInt(176), .end = @fromBackingInt(180) },
        .{ .tag = .keyword_throw, .start = @fromBackingInt(181), .end = @fromBackingInt(186) },
        .{ .tag = .keyword_true, .start = @fromBackingInt(187), .end = @fromBackingInt(191) },
        .{ .tag = .keyword_try, .start = @fromBackingInt(192), .end = @fromBackingInt(195) },
        .{ .tag = .keyword_typeof, .start = @fromBackingInt(196), .end = @fromBackingInt(202) },
        .{ .tag = .keyword_var, .start = @fromBackingInt(203), .end = @fromBackingInt(206) },
        .{ .tag = .keyword_void, .start = @fromBackingInt(207), .end = @fromBackingInt(211) },
        .{ .tag = .keyword_while, .start = @fromBackingInt(212), .end = @fromBackingInt(217) },
        .{ .tag = .keyword_with, .start = @fromBackingInt(218), .end = @fromBackingInt(222) },
        .{ .tag = .keyword_yield, .start = @fromBackingInt(223), .end = @fromBackingInt(228) },
    });
}

test "punctuators" {
    try testTokenizer("?. { } ( ) [ ] . ... ; , < > <= >= == != === !== + - * % ** ++ -- << >> " ++
        ">>> & | ^ ! ~ && || ?? ? : = += -= *= %= **= <<= >>= >>>= &= |= ^= &&= ||= ??= =>", &.{
        .{ .tag = .question_mark_period, .start = @fromBackingInt(0), .end = @fromBackingInt(2) },
        .{ .tag = .left_curly_bracket, .start = @fromBackingInt(3), .end = @fromBackingInt(4) },
        .{ .tag = .right_curly_bracket, .start = @fromBackingInt(5), .end = @fromBackingInt(6) },
        .{ .tag = .left_parenthesis, .start = @fromBackingInt(7), .end = @fromBackingInt(8) },
        .{ .tag = .right_parenthesis, .start = @fromBackingInt(9), .end = @fromBackingInt(10) },
        .{ .tag = .left_square_bracket, .start = @fromBackingInt(11), .end = @fromBackingInt(12) },
        .{ .tag = .right_square_bracket, .start = @fromBackingInt(13), .end = @fromBackingInt(14) },
        .{ .tag = .period, .start = @fromBackingInt(15), .end = @fromBackingInt(16) },
        .{ .tag = .ellipsis, .start = @fromBackingInt(17), .end = @fromBackingInt(20) },
        .{ .tag = .semicolon, .start = @fromBackingInt(21), .end = @fromBackingInt(22) },
        .{ .tag = .comma, .start = @fromBackingInt(23), .end = @fromBackingInt(24) },
        .{ .tag = .less_than, .start = @fromBackingInt(25), .end = @fromBackingInt(26) },
        .{ .tag = .greater_than, .start = @fromBackingInt(27), .end = @fromBackingInt(28) },
        .{ .tag = .less_than_equals, .start = @fromBackingInt(29), .end = @fromBackingInt(31) },
        .{ .tag = .greater_than_equals, .start = @fromBackingInt(32), .end = @fromBackingInt(34) },
        .{ .tag = .double_equals, .start = @fromBackingInt(35), .end = @fromBackingInt(37) },
        .{ .tag = .exclamation_mark_equals, .start = @fromBackingInt(38), .end = @fromBackingInt(40) },
        .{ .tag = .triple_equals, .start = @fromBackingInt(41), .end = @fromBackingInt(44) },
        .{ .tag = .exclamation_mark_double_equals, .start = @fromBackingInt(45), .end = @fromBackingInt(48) },
        .{ .tag = .plus, .start = @fromBackingInt(49), .end = @fromBackingInt(50) },
        .{ .tag = .minus, .start = @fromBackingInt(51), .end = @fromBackingInt(52) },
        .{ .tag = .asterisk, .start = @fromBackingInt(53), .end = @fromBackingInt(54) },
        .{ .tag = .percent, .start = @fromBackingInt(55), .end = @fromBackingInt(56) },
        .{ .tag = .double_asterisk, .start = @fromBackingInt(57), .end = @fromBackingInt(59) },
        .{ .tag = .double_plus, .start = @fromBackingInt(60), .end = @fromBackingInt(62) },
        .{ .tag = .double_minus, .start = @fromBackingInt(63), .end = @fromBackingInt(65) },
        .{ .tag = .double_less_than, .start = @fromBackingInt(66), .end = @fromBackingInt(68) },
        .{ .tag = .double_greater_than, .start = @fromBackingInt(69), .end = @fromBackingInt(71) },
        .{ .tag = .triple_greater_than, .start = @fromBackingInt(72), .end = @fromBackingInt(75) },
        .{ .tag = .ampersand, .start = @fromBackingInt(76), .end = @fromBackingInt(77) },
        .{ .tag = .pipe, .start = @fromBackingInt(78), .end = @fromBackingInt(79) },
        .{ .tag = .caret, .start = @fromBackingInt(80), .end = @fromBackingInt(81) },
        .{ .tag = .exclamation_mark, .start = @fromBackingInt(82), .end = @fromBackingInt(83) },
        .{ .tag = .tilde, .start = @fromBackingInt(84), .end = @fromBackingInt(85) },
        .{ .tag = .double_ampersand, .start = @fromBackingInt(86), .end = @fromBackingInt(88) },
        .{ .tag = .double_pipe, .start = @fromBackingInt(89), .end = @fromBackingInt(91) },
        .{ .tag = .double_question_mark, .start = @fromBackingInt(92), .end = @fromBackingInt(94) },
        .{ .tag = .question_mark, .start = @fromBackingInt(95), .end = @fromBackingInt(96) },
        .{ .tag = .colon, .start = @fromBackingInt(97), .end = @fromBackingInt(98) },
        .{ .tag = .equals, .start = @fromBackingInt(99), .end = @fromBackingInt(100) },
        .{ .tag = .plus_equals, .start = @fromBackingInt(101), .end = @fromBackingInt(103) },
        .{ .tag = .minus_equals, .start = @fromBackingInt(104), .end = @fromBackingInt(106) },
        .{ .tag = .asterisk_equals, .start = @fromBackingInt(107), .end = @fromBackingInt(109) },
        .{ .tag = .percent_equals, .start = @fromBackingInt(110), .end = @fromBackingInt(112) },
        .{ .tag = .double_asterisk_equals, .start = @fromBackingInt(113), .end = @fromBackingInt(116) },
        .{ .tag = .double_less_than_equals, .start = @fromBackingInt(117), .end = @fromBackingInt(120) },
        .{ .tag = .double_greater_than_equals, .start = @fromBackingInt(121), .end = @fromBackingInt(124) },
        .{ .tag = .triple_greater_than_equals, .start = @fromBackingInt(125), .end = @fromBackingInt(129) },
        .{ .tag = .ampersand_equals, .start = @fromBackingInt(130), .end = @fromBackingInt(132) },
        .{ .tag = .pipe_equals, .start = @fromBackingInt(133), .end = @fromBackingInt(135) },
        .{ .tag = .caret_equals, .start = @fromBackingInt(136), .end = @fromBackingInt(138) },
        .{ .tag = .double_ampersand_equals, .start = @fromBackingInt(139), .end = @fromBackingInt(142) },
        .{ .tag = .double_pipe_equals, .start = @fromBackingInt(143), .end = @fromBackingInt(146) },
        .{ .tag = .double_question_mark_equals, .start = @fromBackingInt(147), .end = @fromBackingInt(150) },
        .{ .tag = .equals_greater_than, .start = @fromBackingInt(151), .end = @fromBackingInt(153) },
    });
    // `/` and `/=` need a division context, otherwise `/` starts a regexp
    try testTokenizer("a / b", &.{
        .{ .tag = .identifier, .start = @fromBackingInt(0), .end = @fromBackingInt(1) },
        .{ .tag = .slash, .start = @fromBackingInt(2), .end = @fromBackingInt(3) },
        .{ .tag = .identifier, .start = @fromBackingInt(4), .end = @fromBackingInt(5) },
    });
    try testTokenizer("a /= b", &.{
        .{ .tag = .identifier, .start = @fromBackingInt(0), .end = @fromBackingInt(1) },
        .{ .tag = .slash_equals, .start = @fromBackingInt(2), .end = @fromBackingInt(4) },
        .{ .tag = .identifier, .start = @fromBackingInt(5), .end = @fromBackingInt(6) },
    });
    // `?.` is not allowed to be followed by a digit
    try testTokenizer("a?.1", &.{
        .{ .tag = .identifier, .start = @fromBackingInt(0), .end = @fromBackingInt(1) },
        .{ .tag = .question_mark, .start = @fromBackingInt(1), .end = @fromBackingInt(2) },
        .{ .tag = .number_literal, .start = @fromBackingInt(2), .end = @fromBackingInt(4) },
    });
}

test "number literals" {
    try testTokenizer("0 1.5 1. .5 1e3 1.5e3 1E+3 1e-3 0x1f 0o17 0b101 1_000 1_000.5 1_000e3 " ++
        "1_0.5e1 0x1_f 010 017 08 09 019 08.5 08e2 019.5", &.{
        .{ .tag = .number_literal, .start = @fromBackingInt(0), .end = @fromBackingInt(1) },
        .{ .tag = .number_literal, .start = @fromBackingInt(2), .end = @fromBackingInt(5) },
        .{ .tag = .number_literal, .start = @fromBackingInt(6), .end = @fromBackingInt(8) },
        .{ .tag = .number_literal, .start = @fromBackingInt(9), .end = @fromBackingInt(11) },
        .{ .tag = .number_literal, .start = @fromBackingInt(12), .end = @fromBackingInt(15) },
        .{ .tag = .number_literal, .start = @fromBackingInt(16), .end = @fromBackingInt(21) },
        .{ .tag = .number_literal, .start = @fromBackingInt(22), .end = @fromBackingInt(26) },
        .{ .tag = .number_literal, .start = @fromBackingInt(27), .end = @fromBackingInt(31) },
        .{ .tag = .number_literal, .start = @fromBackingInt(32), .end = @fromBackingInt(36) },
        .{ .tag = .number_literal, .start = @fromBackingInt(37), .end = @fromBackingInt(41) },
        .{ .tag = .number_literal, .start = @fromBackingInt(42), .end = @fromBackingInt(47) },
        .{ .tag = .number_literal, .start = @fromBackingInt(48), .end = @fromBackingInt(53) },
        .{ .tag = .number_literal, .start = @fromBackingInt(54), .end = @fromBackingInt(61) },
        .{ .tag = .number_literal, .start = @fromBackingInt(62), .end = @fromBackingInt(69) },
        .{ .tag = .number_literal, .start = @fromBackingInt(70), .end = @fromBackingInt(77) },
        .{ .tag = .number_literal, .start = @fromBackingInt(78), .end = @fromBackingInt(83) },
        .{ .tag = .number_literal, .start = @fromBackingInt(84), .end = @fromBackingInt(87) },
        .{ .tag = .number_literal, .start = @fromBackingInt(88), .end = @fromBackingInt(91) },
        .{ .tag = .number_literal, .start = @fromBackingInt(92), .end = @fromBackingInt(94) },
        .{ .tag = .number_literal, .start = @fromBackingInt(95), .end = @fromBackingInt(97) },
        .{ .tag = .number_literal, .start = @fromBackingInt(98), .end = @fromBackingInt(101) },
        .{ .tag = .number_literal, .start = @fromBackingInt(102), .end = @fromBackingInt(106) },
        .{ .tag = .number_literal, .start = @fromBackingInt(107), .end = @fromBackingInt(111) },
        .{ .tag = .number_literal, .start = @fromBackingInt(112), .end = @fromBackingInt(117) },
    });
    try testTokenizer("0b 0o 0x 1x 1_ 0x1_ 1.0_ 1e1_ 0_1 01_2 08_5 1e 1e+ 1e- " ++
        "1.0_0n 1e1_0n 1e1_0e2 1.0n 1e2n 0b12", &.{
        .{ .tag = .invalid, .start = @fromBackingInt(0), .end = @fromBackingInt(2) },
        .{ .tag = .invalid, .start = @fromBackingInt(3), .end = @fromBackingInt(5) },
        .{ .tag = .invalid, .start = @fromBackingInt(6), .end = @fromBackingInt(8) },
        .{ .tag = .invalid, .start = @fromBackingInt(9), .end = @fromBackingInt(11) },
        .{ .tag = .invalid, .start = @fromBackingInt(12), .end = @fromBackingInt(14) },
        .{ .tag = .invalid, .start = @fromBackingInt(15), .end = @fromBackingInt(19) },
        .{ .tag = .invalid, .start = @fromBackingInt(20), .end = @fromBackingInt(24) },
        .{ .tag = .invalid, .start = @fromBackingInt(25), .end = @fromBackingInt(29) },
        .{ .tag = .invalid, .start = @fromBackingInt(30), .end = @fromBackingInt(33) },
        .{ .tag = .invalid, .start = @fromBackingInt(34), .end = @fromBackingInt(38) },
        .{ .tag = .invalid, .start = @fromBackingInt(39), .end = @fromBackingInt(43) },
        .{ .tag = .invalid, .start = @fromBackingInt(44), .end = @fromBackingInt(46) },
        .{ .tag = .invalid, .start = @fromBackingInt(47), .end = @fromBackingInt(50) },
        .{ .tag = .invalid, .start = @fromBackingInt(51), .end = @fromBackingInt(54) },
        .{ .tag = .invalid, .start = @fromBackingInt(55), .end = @fromBackingInt(61) },
        .{ .tag = .invalid, .start = @fromBackingInt(62), .end = @fromBackingInt(68) },
        .{ .tag = .invalid, .start = @fromBackingInt(69), .end = @fromBackingInt(76) },
        .{ .tag = .invalid, .start = @fromBackingInt(77), .end = @fromBackingInt(81) },
        .{ .tag = .invalid, .start = @fromBackingInt(82), .end = @fromBackingInt(86) },
        .{ .tag = .invalid, .start = @fromBackingInt(87), .end = @fromBackingInt(91) },
    });
    try testTokenizer("1__0 0x1__0", &.{
        .{ .tag = .invalid, .start = @fromBackingInt(0), .end = @fromBackingInt(2) },
        .{ .tag = .identifier, .start = @fromBackingInt(2), .end = @fromBackingInt(4) },
        .{ .tag = .invalid, .start = @fromBackingInt(5), .end = @fromBackingInt(9) },
        .{ .tag = .identifier, .start = @fromBackingInt(9), .end = @fromBackingInt(11) },
    });
    try testTokenizer("1.0_0.5 0x1_0.5", &.{
        .{ .tag = .number_literal, .start = @fromBackingInt(0), .end = @fromBackingInt(5) },
        .{ .tag = .number_literal, .start = @fromBackingInt(5), .end = @fromBackingInt(7) },
        .{ .tag = .number_literal, .start = @fromBackingInt(8), .end = @fromBackingInt(13) },
        .{ .tag = .number_literal, .start = @fromBackingInt(13), .end = @fromBackingInt(15) },
    });

    const gpa = std.testing.allocator;
    const test_cases = [_]struct { []const u8, f64 }{
        // DecimalIntegerLiteral
        .{ "0", 0 },
        // DecimalLiteral
        .{ "1.5", 1.5 },
        .{ "1.", 1 },
        .{ ".5", 0.5 },
        .{ "1e3", 1000 },
        .{ "1.5e3", 1500 },
        .{ "1E+3", 1000 },
        .{ "1e-3", 0.001 },
        // HexIntegerLiteral
        .{ "0x1f", 31 },
        // OctalIntegerLiteral
        .{ "0o17", 15 },
        // BinaryIntegerLiteral
        .{ "0b101", 5 },
        // DecimalIntegerLiteral
        .{ "1_000", 1000 },
        .{ "1_000.5", 1000.5 },
        .{ "1_000e3", 1_000_000 },
        .{ "1_0.5e1", 105 },
        .{ "0x1_f", 31 },
        // LegacyOctalIntegerLiteral
        .{ "010", 8 },
        .{ "017", 15 },
        // NonOctalDecimalIntegerLiteral
        .{ "08", 8 },
        .{ "09", 9 },
        .{ "019", 19 },
        .{ "08.5", 8.5 },
        .{ "08e2", 800 },
        .{ "019.5", 19.5 },
    };
    for (test_cases) |test_case| {
        const text, const expected = test_case;
        var consumed: u32 = undefined;
        const literal = NumericLiteral.parse(text, &consumed).?;
        const value = try literal.numberValue(gpa);
        try std.testing.expectEqual(expected, value);
    }
}

test "bigint literals" {
    try testTokenizer("1n 0x1fn 0o17n 0b101n", &.{
        .{ .tag = .bigint_literal, .start = @fromBackingInt(0), .end = @fromBackingInt(2) },
        .{ .tag = .bigint_literal, .start = @fromBackingInt(3), .end = @fromBackingInt(8) },
        .{ .tag = .bigint_literal, .start = @fromBackingInt(9), .end = @fromBackingInt(14) },
        .{ .tag = .bigint_literal, .start = @fromBackingInt(15), .end = @fromBackingInt(21) },
    });
    try testTokenizer("0bn 0on 0xn", &.{
        .{ .tag = .invalid, .start = @fromBackingInt(0), .end = @fromBackingInt(2) },
        .{ .tag = .identifier, .start = @fromBackingInt(2), .end = @fromBackingInt(3) },
        .{ .tag = .invalid, .start = @fromBackingInt(4), .end = @fromBackingInt(6) },
        .{ .tag = .identifier, .start = @fromBackingInt(6), .end = @fromBackingInt(7) },
        .{ .tag = .invalid, .start = @fromBackingInt(8), .end = @fromBackingInt(10) },
        .{ .tag = .identifier, .start = @fromBackingInt(10), .end = @fromBackingInt(11) },
    });

    const gpa = std.testing.allocator;
    const test_cases = [_]struct { []const u8, u64 }{
        // DecimalBigIntegerLiteral
        .{ "1n", 1 },
        .{ "1_000n", 1000 },
        // NonDecimalIntegerLiteral[+Sep] BigIntLiteralSuffix
        .{ "0x1fn", 31 },
        .{ "0o17n", 15 },
        .{ "0b101n", 5 },
    };
    for (test_cases) |test_case| {
        const text, const expected = test_case;
        var consumed: u32 = undefined;
        const literal = NumericLiteral.parse(text, &consumed).?;
        var value = try literal.bigIntValue(gpa);
        defer value.deinit();
        try std.testing.expectEqual(expected, try value.toInt(u64));
    }
}

test "string literals" {
    try testTokenizer("\"abc\" 'd' \"\" ''", &.{
        .{ .tag = .string_literal, .start = @fromBackingInt(0), .end = @fromBackingInt(5) },
        .{ .tag = .string_literal, .start = @fromBackingInt(6), .end = @fromBackingInt(9) },
        .{ .tag = .string_literal, .start = @fromBackingInt(10), .end = @fromBackingInt(12) },
        .{ .tag = .string_literal, .start = @fromBackingInt(13), .end = @fromBackingInt(15) },
    });
    // Escape sequences
    try testTokenizer("\"\\n\" \"\\x41\" \"\\u{1F600}\" \"\\0\" \"\\101\" \"\\8\" \"\\\"c\" 'd\\''", &.{
        .{ .tag = .string_literal, .start = @fromBackingInt(0), .end = @fromBackingInt(4) },
        .{ .tag = .string_literal, .start = @fromBackingInt(5), .end = @fromBackingInt(11) },
        .{ .tag = .string_literal, .start = @fromBackingInt(12), .end = @fromBackingInt(23) },
        .{ .tag = .string_literal, .start = @fromBackingInt(24), .end = @fromBackingInt(28) },
        .{ .tag = .string_literal, .start = @fromBackingInt(29), .end = @fromBackingInt(35) },
        .{ .tag = .string_literal, .start = @fromBackingInt(36), .end = @fromBackingInt(40) },
        .{ .tag = .string_literal, .start = @fromBackingInt(41), .end = @fromBackingInt(46) },
        .{ .tag = .string_literal, .start = @fromBackingInt(47), .end = @fromBackingInt(52) },
    });
    // Line continuation (`\` followed by a line terminator sequence)
    try testTokenizer("\"a\\\nb\" \"a\\\r\nb\"", &.{
        .{ .tag = .string_literal, .start = @fromBackingInt(0), .end = @fromBackingInt(6) },
        .{ .tag = .string_literal, .start = @fromBackingInt(7), .end = @fromBackingInt(14) },
    });
    // Unterminated string is a single invalid token
    try testTokenizer("\"abc", &.{
        .{ .tag = .invalid, .start = @fromBackingInt(0), .end = @fromBackingInt(4) },
    });
    // A <CR>/<LF> line terminator inside a string is invalid, this gets tokenized
    // as two unterminated strings
    try testTokenizer("\"abc\n\"", &.{
        .{ .tag = .invalid, .start = @fromBackingInt(0), .end = @fromBackingInt(4) },
        .{ .tag = .invalid, .start = @fromBackingInt(5), .end = @fromBackingInt(6) },
    });
    try testTokenizer("\"abc\r\n\"", &.{
        .{ .tag = .invalid, .start = @fromBackingInt(0), .end = @fromBackingInt(4) },
        .{ .tag = .invalid, .start = @fromBackingInt(6), .end = @fromBackingInt(7) },
    });
    // <LS> and <PS> are permitted
    try testTokenizer("\"abc\u{2028}\" \"abc\u{2029}\"", &.{
        .{ .tag = .string_literal, .start = @fromBackingInt(0), .end = @fromBackingInt(8) },
        .{ .tag = .string_literal, .start = @fromBackingInt(9), .end = @fromBackingInt(17) },
    });

    const gpa = std.testing.allocator;
    const test_cases = [_]struct { []const u8, []const u8 }{
        .{ "\"abc\"", "abc" },
        // HexEscapeSequence
        .{ "\"\\x61b\"", "ab" },
        .{ "\"\\xff\"", "\u{FF}" },
        // UnicodeEscapeSequence
        .{ "\"\\u0061b\"", "ab" },
        .{ "\"\\u{61}b\"", "ab" },
        // LineContinuation
        .{ "\"a\\\nb\"", "ab" },
        .{ "\"a\\\r\nb\"", "ab" },
        // SingleEscapeCharacter
        .{ "\"\\b\\t\\n\\v\\f\\r\"", "\x08\x09\x0a\x0b\x0c\x0d" },
        .{ "\"\\\"\\'\\\\\"", "\"'\\" },
        // NonEscapeCharacter
        .{ "\"\\a\"", "a" },
        // NonOctalDecimalEscapeSequence
        .{ "\"\\8\\9\"", "89" },
        // LegacyOctalEscapeSequence
        .{ "\"\\0\"", "\x00" },
        .{ "\"\\101\"", "A" },
        .{ "\"\\377\"", "\u{FF}" },
        .{ "\"\\01\"", "\x01" },
        .{ "\"\\400\"", " 0" },
        // A lone surrogate is preserved as a code unit
        .{ "\"\\uD800\"", "\xed\xa0\x80" },
        .{ "\"\\u{1F600}\"", "\u{1F600}" },
        .{ "\"é\"", "é" },
    };
    for (test_cases) |test_case| {
        const source, const expected = test_case;
        var consumed: u32 = undefined;
        const literal = StringLiteral.parse(source, &consumed).?;
        var aw: std.Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        const valid = literal.value(&aw.writer) catch unreachable;
        try std.testing.expect(valid);
        try std.testing.expectEqualStrings(expected, aw.written());
    }

    const invalid_test_cases = [_][]const u8{
        "\"\\x\"",         "\"\\x1\"",         "\"\\u\"", "\"\\u{\"",
        "\"\\u{110000}\"", "\"\\u{1234567}\"",
    };
    for (invalid_test_cases) |source| {
        var consumed: u32 = undefined;
        const literal = StringLiteral.parse(source, &consumed).?;
        try std.testing.expect(!literal.validate());
    }
}

test "regexp literals" {
    try testTokenizer("/ab+c\\/d[/]]\x00/gi", &.{
        .{ .tag = .regexp_literal, .start = @fromBackingInt(0), .end = @fromBackingInt(16) },
    });
    // A regexp is allowed after tokens that cannot end an expression, after a statement paren,
    // after a function declaration body, and after `of` in a `for...of` loop.
    try testTokenizer("( /re/ ) x = /re/ { /re/ } , /re/ => /re/ [ /re/ ] if (x) /re/ function f() {} /re/ for (x) /re/ for await (x) /re/ for (x of /foo/)", &.{
        .{ .tag = .left_parenthesis, .start = @fromBackingInt(0), .end = @fromBackingInt(1) },
        .{ .tag = .regexp_literal, .start = @fromBackingInt(2), .end = @fromBackingInt(6) },
        .{ .tag = .right_parenthesis, .start = @fromBackingInt(7), .end = @fromBackingInt(8) },
        .{ .tag = .identifier, .start = @fromBackingInt(9), .end = @fromBackingInt(10) },
        .{ .tag = .equals, .start = @fromBackingInt(11), .end = @fromBackingInt(12) },
        .{ .tag = .regexp_literal, .start = @fromBackingInt(13), .end = @fromBackingInt(17) },
        .{ .tag = .left_curly_bracket, .start = @fromBackingInt(18), .end = @fromBackingInt(19) },
        .{ .tag = .regexp_literal, .start = @fromBackingInt(20), .end = @fromBackingInt(24) },
        .{ .tag = .right_curly_bracket, .start = @fromBackingInt(25), .end = @fromBackingInt(26) },
        .{ .tag = .comma, .start = @fromBackingInt(27), .end = @fromBackingInt(28) },
        .{ .tag = .regexp_literal, .start = @fromBackingInt(29), .end = @fromBackingInt(33) },
        .{ .tag = .equals_greater_than, .start = @fromBackingInt(34), .end = @fromBackingInt(36) },
        .{ .tag = .regexp_literal, .start = @fromBackingInt(37), .end = @fromBackingInt(41) },
        .{ .tag = .left_square_bracket, .start = @fromBackingInt(42), .end = @fromBackingInt(43) },
        .{ .tag = .regexp_literal, .start = @fromBackingInt(44), .end = @fromBackingInt(48) },
        .{ .tag = .right_square_bracket, .start = @fromBackingInt(49), .end = @fromBackingInt(50) },
        .{ .tag = .keyword_if, .start = @fromBackingInt(51), .end = @fromBackingInt(53) },
        .{ .tag = .left_parenthesis, .start = @fromBackingInt(54), .end = @fromBackingInt(55) },
        .{ .tag = .identifier, .start = @fromBackingInt(55), .end = @fromBackingInt(56) },
        .{ .tag = .right_parenthesis, .start = @fromBackingInt(56), .end = @fromBackingInt(57) },
        .{ .tag = .regexp_literal, .start = @fromBackingInt(58), .end = @fromBackingInt(62) },
        .{ .tag = .keyword_function, .start = @fromBackingInt(63), .end = @fromBackingInt(71) },
        .{ .tag = .identifier, .start = @fromBackingInt(72), .end = @fromBackingInt(73) },
        .{ .tag = .left_parenthesis, .start = @fromBackingInt(73), .end = @fromBackingInt(74) },
        .{ .tag = .right_parenthesis, .start = @fromBackingInt(74), .end = @fromBackingInt(75) },
        .{ .tag = .left_curly_bracket, .start = @fromBackingInt(76), .end = @fromBackingInt(77) },
        .{ .tag = .right_curly_bracket, .start = @fromBackingInt(77), .end = @fromBackingInt(78) },
        .{ .tag = .regexp_literal, .start = @fromBackingInt(79), .end = @fromBackingInt(83) },
        .{ .tag = .keyword_for, .start = @fromBackingInt(84), .end = @fromBackingInt(87) },
        .{ .tag = .left_parenthesis, .start = @fromBackingInt(88), .end = @fromBackingInt(89) },
        .{ .tag = .identifier, .start = @fromBackingInt(89), .end = @fromBackingInt(90) },
        .{ .tag = .right_parenthesis, .start = @fromBackingInt(90), .end = @fromBackingInt(91) },
        .{ .tag = .regexp_literal, .start = @fromBackingInt(92), .end = @fromBackingInt(96) },
        .{ .tag = .keyword_for, .start = @fromBackingInt(97), .end = @fromBackingInt(100) },
        .{ .tag = .keyword_await, .start = @fromBackingInt(101), .end = @fromBackingInt(106) },
        .{ .tag = .left_parenthesis, .start = @fromBackingInt(107), .end = @fromBackingInt(108) },
        .{ .tag = .identifier, .start = @fromBackingInt(108), .end = @fromBackingInt(109) },
        .{ .tag = .right_parenthesis, .start = @fromBackingInt(109), .end = @fromBackingInt(110) },
        .{ .tag = .regexp_literal, .start = @fromBackingInt(111), .end = @fromBackingInt(115) },
        .{ .tag = .keyword_for, .start = @fromBackingInt(116), .end = @fromBackingInt(119) },
        .{ .tag = .left_parenthesis, .start = @fromBackingInt(120), .end = @fromBackingInt(121) },
        .{ .tag = .identifier, .start = @fromBackingInt(121), .end = @fromBackingInt(122) },
        .{ .tag = .identifier, .start = @fromBackingInt(123), .end = @fromBackingInt(125) },
        .{ .tag = .regexp_literal, .start = @fromBackingInt(126), .end = @fromBackingInt(131) },
        .{ .tag = .right_parenthesis, .start = @fromBackingInt(131), .end = @fromBackingInt(132) },
    });
    // Otherwise it's a division operator
    try testTokenizer("a / b / c ( /ab\ncd ) /ab\\ (function() {} / 2) await (x) / 2", &.{
        .{ .tag = .identifier, .start = @fromBackingInt(0), .end = @fromBackingInt(1) },
        .{ .tag = .slash, .start = @fromBackingInt(2), .end = @fromBackingInt(3) },
        .{ .tag = .identifier, .start = @fromBackingInt(4), .end = @fromBackingInt(5) },
        .{ .tag = .slash, .start = @fromBackingInt(6), .end = @fromBackingInt(7) },
        .{ .tag = .identifier, .start = @fromBackingInt(8), .end = @fromBackingInt(9) },
        .{ .tag = .left_parenthesis, .start = @fromBackingInt(10), .end = @fromBackingInt(11) },
        .{ .tag = .slash, .start = @fromBackingInt(12), .end = @fromBackingInt(13) },
        .{ .tag = .identifier, .start = @fromBackingInt(13), .end = @fromBackingInt(15) },
        .{ .tag = .identifier, .start = @fromBackingInt(16), .end = @fromBackingInt(18) },
        .{ .tag = .right_parenthesis, .start = @fromBackingInt(19), .end = @fromBackingInt(20) },
        .{ .tag = .slash, .start = @fromBackingInt(21), .end = @fromBackingInt(22) },
        .{ .tag = .identifier, .start = @fromBackingInt(22), .end = @fromBackingInt(24) },
        .{ .tag = .invalid, .start = @fromBackingInt(24), .end = @fromBackingInt(25) },
        .{ .tag = .left_parenthesis, .start = @fromBackingInt(26), .end = @fromBackingInt(27) },
        .{ .tag = .keyword_function, .start = @fromBackingInt(27), .end = @fromBackingInt(35) },
        .{ .tag = .left_parenthesis, .start = @fromBackingInt(35), .end = @fromBackingInt(36) },
        .{ .tag = .right_parenthesis, .start = @fromBackingInt(36), .end = @fromBackingInt(37) },
        .{ .tag = .left_curly_bracket, .start = @fromBackingInt(38), .end = @fromBackingInt(39) },
        .{ .tag = .right_curly_bracket, .start = @fromBackingInt(39), .end = @fromBackingInt(40) },
        .{ .tag = .slash, .start = @fromBackingInt(41), .end = @fromBackingInt(42) },
        .{ .tag = .number_literal, .start = @fromBackingInt(43), .end = @fromBackingInt(44) },
        .{ .tag = .right_parenthesis, .start = @fromBackingInt(44), .end = @fromBackingInt(45) },
        .{ .tag = .keyword_await, .start = @fromBackingInt(46), .end = @fromBackingInt(51) },
        .{ .tag = .left_parenthesis, .start = @fromBackingInt(52), .end = @fromBackingInt(53) },
        .{ .tag = .identifier, .start = @fromBackingInt(53), .end = @fromBackingInt(54) },
        .{ .tag = .right_parenthesis, .start = @fromBackingInt(54), .end = @fromBackingInt(55) },
        .{ .tag = .slash, .start = @fromBackingInt(56), .end = @fromBackingInt(57) },
        .{ .tag = .number_literal, .start = @fromBackingInt(58), .end = @fromBackingInt(59) },
    });
}

test "template literals" {
    // NoSubstitutionTemplate
    try testTokenizer("`abc` `a$b` `a\\`b` `a\nb`", &.{
        .{ .tag = .template_literal, .start = @fromBackingInt(0), .end = @fromBackingInt(5) },
        .{ .tag = .template_literal, .start = @fromBackingInt(6), .end = @fromBackingInt(11) },
        .{ .tag = .template_literal, .start = @fromBackingInt(12), .end = @fromBackingInt(18) },
        .{ .tag = .template_literal, .start = @fromBackingInt(19), .end = @fromBackingInt(24) },
    });
    // TemplateHead, TemplateMiddle, TemplateTail
    try testTokenizer("`a${b}c${d}e`", &.{
        .{ .tag = .template_literal_head, .start = @fromBackingInt(0), .end = @fromBackingInt(4) },
        .{ .tag = .identifier, .start = @fromBackingInt(4), .end = @fromBackingInt(5) },
        .{ .tag = .template_literal_middle, .start = @fromBackingInt(5), .end = @fromBackingInt(9) },
        .{ .tag = .identifier, .start = @fromBackingInt(9), .end = @fromBackingInt(10) },
        .{ .tag = .template_literal_tail, .start = @fromBackingInt(10), .end = @fromBackingInt(13) },
    });
    // Nested template literals
    try testTokenizer("`a${`b${c}d`}e`", &.{
        .{ .tag = .template_literal_head, .start = @fromBackingInt(0), .end = @fromBackingInt(4) },
        .{ .tag = .template_literal_head, .start = @fromBackingInt(4), .end = @fromBackingInt(8) },
        .{ .tag = .identifier, .start = @fromBackingInt(8), .end = @fromBackingInt(9) },
        .{ .tag = .template_literal_tail, .start = @fromBackingInt(9), .end = @fromBackingInt(12) },
        .{ .tag = .template_literal_tail, .start = @fromBackingInt(12), .end = @fromBackingInt(15) },
    });
    // Object literal inside a template literal
    try testTokenizer("`${{a:1}}`", &.{
        .{ .tag = .template_literal_head, .start = @fromBackingInt(0), .end = @fromBackingInt(3) },
        .{ .tag = .left_curly_bracket, .start = @fromBackingInt(3), .end = @fromBackingInt(4) },
        .{ .tag = .identifier, .start = @fromBackingInt(4), .end = @fromBackingInt(5) },
        .{ .tag = .colon, .start = @fromBackingInt(5), .end = @fromBackingInt(6) },
        .{ .tag = .number_literal, .start = @fromBackingInt(6), .end = @fromBackingInt(7) },
        .{ .tag = .right_curly_bracket, .start = @fromBackingInt(7), .end = @fromBackingInt(8) },
        .{ .tag = .template_literal_tail, .start = @fromBackingInt(8), .end = @fromBackingInt(10) },
    });
    // Unterminated template literal is a single invalid token
    try testTokenizer("`abc `a${b}c", &.{
        .{ .tag = .template_literal, .start = @fromBackingInt(0), .end = @fromBackingInt(6) },
        .{ .tag = .identifier, .start = @fromBackingInt(6), .end = @fromBackingInt(8) },
        .{ .tag = .left_curly_bracket, .start = @fromBackingInt(8), .end = @fromBackingInt(9) },
        .{ .tag = .identifier, .start = @fromBackingInt(9), .end = @fromBackingInt(10) },
        .{ .tag = .right_curly_bracket, .start = @fromBackingInt(10), .end = @fromBackingInt(11) },
        .{ .tag = .identifier, .start = @fromBackingInt(11), .end = @fromBackingInt(12) },
    });

    const gpa = std.testing.allocator;
    const test_cases = [_]struct { []const u8, []const u8, []const u8 }{
        .{ "`abc`", "abc", "abc" },
        // HexEscapeSequence
        .{ "`\\x61b`", "ab", "\\x61b" },
        // UnicodeEscapeSequence
        .{ "`\\u0061b`", "ab", "\\u0061b" },
        .{ "`\\u{61}b`", "ab", "\\u{61}b" },
        // LineContinuation
        .{ "`a\\\nb`", "ab", "a\\\nb" },
        .{ "`a\\\r\nb`", "ab", "a\\\nb" },
        // SingleEscapeCharacter
        .{ "`a\\nb`", "a\nb", "a\\nb" },
        // <CR> and <CR><LF> are normalized to <LF>
        .{ "`a\rb`", "a\nb", "a\nb" },
        .{ "`a\r\nb`", "a\nb", "a\nb" },
        // A lone surrogate is preserved as a code unit
        .{ "`\\uD800`", "\xed\xa0\x80", "\\uD800" },
        .{ "`\\u{1F600}`", "\u{1F600}", "\\u{1F600}" },
    };
    for (test_cases) |test_case| {
        const source, const expected, const expected_raw = test_case;
        var consumed: u32 = undefined;
        const template = Template.parse(source, &consumed).?;
        var aw: std.Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        const valid = template.value(&aw.writer) catch unreachable;
        try std.testing.expect(valid);
        try std.testing.expectEqualStrings(expected, aw.written());
        aw.clearRetainingCapacity();
        const valid_raw = template.rawValue(&aw.writer) catch unreachable;
        try std.testing.expect(valid_raw);
        try std.testing.expectEqualStrings(expected_raw, aw.written());
    }

    // TemplateCharacter :: \ NotEscapeSequence
    const invalid_test_cases = [_][]const u8{
        "`\\1`",  "`\\8`", "`\\01`", "`\\x`",
        "`\\x1`", "`\\u`", "`\\u{`", "`\\u{110000}`",
    };
    for (invalid_test_cases) |source| {
        var consumed: u32 = undefined;
        const template = Template.parse(source, &consumed).?;
        try std.testing.expect(!template.validate());
    }
}

test "multi-byte identifier start" {
    // U+1E00 (LATIN CAPITAL LETTER A WITH RING BELOW) shares its leading byte with the multi-byte
    // whitespace/line-terminator prefixes but must be recognized as an identifier.
    try testTokenizer("\u{1E00}foo", &.{
        .{ .tag = .identifier, .start = @fromBackingInt(0), .end = @fromBackingInt(6) },
    });
}

test "fuzz" {
    try std.testing.fuzz({}, fuzzTokenizer, .{});
}

fn fuzzTokenizer(_: void, smith: *std.testing.Smith) !void {
    const gpa = std.testing.allocator;

    var buffer: [256:0]u8 = undefined;
    const len = smith.sliceWeightedBytes(buffer[0..buffer.len], &.{
        .rangeAtMost(u8, '\x00', '\x08', 1),
        .rangeAtMost(u8, '\t', '\n', 8),
        .rangeAtMost(u8, '\x0B', '\x0C', 1),
        .rangeAtMost(u8, '\r', '\r', 8),
        .rangeAtMost(u8, '\x0E', '\x1F', 1),
        .rangeAtMost(u8, ' ', '~', 16),
        .rangeAtMost(u8, '\x7F', '\xFF', 1),
    });
    buffer[len] = 0;
    const source = buffer[0..len :0];

    var t: Tokenizer = .init(gpa, source);
    defer t.deinit();

    var prev_end: Token.ByteOffset = @fromBackingInt(0);
    while (try t.next()) |token| {
        try std.testing.expect(@backingInt(token.start) <= @backingInt(token.end));
        try std.testing.expect(@backingInt(token.end) <= source.len);
        try std.testing.expect(@backingInt(prev_end) <= @backingInt(token.start));
        prev_end = token.end;
    }
}
